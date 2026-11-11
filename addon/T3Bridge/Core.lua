-- T3Bridge Core: saved settings, event bus, snapshot application, command sending, login wiring.
local addonName, ns = ...
local Compat, State = ns.Compat, ns.State

-- The fallback inbox (Inbox.lua, loaded by the TOC just before this file) may have set these.
local inboxRaw, inboxEnd = _G.T3B_IN, _G.T3B_IN_END
_G.T3B_IN, _G.T3B_IN_END = nil, nil

---------------------------------------------------------------------------------------------
-- Settings. Only UI positions, minimap angle, last focused thread, debug flag and
-- outbound geometry/timing. No message text, no secrets.
---------------------------------------------------------------------------------------------
local DEFAULTS = {
  v = 1,
  debug = false,
  cell = 2,          -- outbound cell size in physical px: 1, 2 or 4
  hold = 200,        -- ms each outbound part stays visible after 2 rendered frames
  minimap = { angle = 40, hide = false, moved = false }, -- moved: the user dragged it (else auto-placed)
  -- mode: auto|below|above|free. rows: collapsed rows by thread id (tid -> true or an attention key; no text).
  tracker = { hide = false, collapsed = false, point = nil, mode = "auto", rows = {} },
  chat = { point = nil, w = 520, h = 560 },
  lastFocus = nil,
  -- Image slots (rev 1.3), set by /t3 spike img: works = true|false|nil (nil = not tested: try them),
  -- reloadFrees = true|false|nil (does /reload free cached textures?). No image data is stored.
  img = {},
}

local function applyDefaults(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      applyDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

---------------------------------------------------------------------------------------------
-- Event bus
---------------------------------------------------------------------------------------------
local listeners = {}
function ns.On(evt, fn)
  listeners[evt] = listeners[evt] or {}
  table.insert(listeners[evt], fn)
end
function ns.Fire(evt, ...)
  local l = listeners[evt]
  if not l then return end
  for _, fn in ipairs(l) do
    local ok, err = pcall(fn, ...)
    if not ok then ns.Debug("listener error (" .. evt .. "): " .. tostring(err)) end
  end
end

---------------------------------------------------------------------------------------------
-- Logging (in memory only; /t3 log shows it)
---------------------------------------------------------------------------------------------
ns.log = {}
local PREFIX = "|cff69ccf0T3Bridge|r: "
function ns.Print(msg)
  local frame = DEFAULT_CHAT_FRAME or ChatFrame1
  if frame then frame:AddMessage(PREFIX .. tostring(msg)) end
end
function ns.Debug(msg)
  local line = date("%H:%M:%S") .. " " .. tostring(msg)
  ns.log[#ns.log + 1] = line
  if #ns.log > 200 then table.remove(ns.log, 1) end
  if ns.db and ns.db.debug then ns.Print("|cff888888" .. Compat.Escape(msg) .. "|r") end
end

---------------------------------------------------------------------------------------------
-- Model + sending
---------------------------------------------------------------------------------------------
ns.state = State.New()
ns.demo = false
ns.selected = nil           -- thread the user is looking at in the chat window
ns.notRespondingAt = nil

function ns.Now() return time() end

function ns.Outbox()
  if not ns.outbox then
    ns.outbox = State.NewOutbox({ rnd = math.random })
  end
  return ns.outbox
end

--- Feed T3B_IN/T3B_IN_END into the model. Returns the State.Accept result.
function ns.ApplySnapshot(raw, rawEnd, source)
  local result = State.Accept(ns.state, raw, rawEnd, ns.Now())
  ns.lastInbound = { result = result, source = source, at = GetTime() }
  if result == "accepted" or result == "reset" then
    local snap = ns.state.snap
    if not ns.demo then
      local ob = ns.Outbox()
      local ev = ob:OnSnapshot(snap, GetTime())
      if ev then ns.Fire("sent", ev) end
      if result == "reset" then ob.helloSent = false end
      if not ob.helloSent and not State.IsOffline(ns.state, ns.Now()) and snap.asid ~= ob:SidHex() then
        ob.helloSent = true
        -- 5th field (rev 1.3): "0" = the user marked image slots as not working (/t3 spike img fail).
        ob:Enqueue("hello", { "1", ns.version, tostring(ns.db and ns.db.cell or 2), "8", ns.ImagesWork() and "1" or "0" })
        if ns.Outbound then ns.Outbound.Kick() end
      end
      ns.EnsureFocus()
    end
    ns.CheckNotice()
    ns.Fire("model", result)
  else
    ns.Debug("snapshot " .. tostring(source) .. ": " .. result)
  end
  return result
end

--- Image slots usable on this client? false only after "/t3 spike img fail" (then images show as text).
function ns.ImagesWork()
  return not (ns.db and ns.db.img and ns.db.img.works == false)
end

ns.NOTICE_S = 4
--- A new focus.notice (rev 1.3, D18) for the open thread is shown in the status bar for a few seconds.
function ns.CheckNotice()
  local f = ns.state.snap and ns.state.snap.focus
  if not f or not f.notice or f.id ~= ns.selected then return end
  if ns.lastNid == f.nid and ns.lastNoticeText == f.notice then return end
  ns.lastNid, ns.lastNoticeText = f.nid, f.notice
  ns.notice = { text = f.notice, untilT = GetTime() + ns.NOTICE_S }
  ns.Fire("notice", f.notice)
end

--- Send a command to the companion (or the demo backend). args as in State.Outbox:Enqueue.
function ns.Send(kind, args, meta)
  if ns.demo then
    if ns.DemoMode then ns.DemoMode.Handle(kind, args, meta) end
    return true
  end
  ns.Outbox():Enqueue(kind, args, meta)
  if ns.Outbound then ns.Outbound.Kick() end
  if ns.Inbound then ns.Inbound.Burst(10) end
  ns.Fire("outbox")
  return true
end

--- Select a thread for the chat window and tell the companion to focus it.
function ns.SelectThread(tid)
  if not tid then return end
  ns.selected = tid
  if ns.db then ns.db.lastFocus = tid end
  -- Opening a thread never hides its tracker row (Phase 2: rows stay until settled in T3).
  local f = ns.state.snap and ns.state.snap.focus
  if not f or f.id ~= tid then
    ns.lastFocusSendAt = GetTime()
    ns.Send("focus", { tid })
  end
  ns.Fire("selected", tid)
  ns.Fire("model", "select")
end

local FOCUS_RETRY_S = 10

--- The chat window shows a thread but the companion's snapshot has no focus for it: the
--- companion restarted (new sid) or the earlier focus command was lost. Ask again, at most every
--- 10 s, so the outbound matrix does not flash repeatedly.
function ns.EnsureFocus()
  local tid = ns.selected
  if ns.demo or not tid then return end
  if not (ns.UI and ns.UI.ChatIsOpen and ns.UI.ChatIsOpen()) then return end
  local snap = ns.state.snap
  if not snap or State.IsOffline(ns.state, ns.Now()) then return end
  if snap.focus and snap.focus.id == tid then return end
  -- rev 1.4: a subagent seen earlier counts too (a restarted companion may not list it yet).
  if not State.Thread(ns.state, tid) and not State.Known(ns.state, tid) then return end
  local now = GetTime()
  if ns.lastFocusSendAt and now - ns.lastFocusSendAt < FOCUS_RETRY_S then return end
  ns.lastFocusSendAt = now
  ns.Debug("re-sending focus " .. tid .. " (companion has no focus for the open thread)")
  ns.Send("focus", { tid })
end

--- Best default thread: remembered one if still listed, else first needing you / running.
function ns.DefaultThread()
  local st = ns.state
  if ns.selected and State.Thread(st, ns.selected) then return ns.selected end
  if ns.db and ns.db.lastFocus and State.Thread(st, ns.db.lastFocus) then return ns.db.lastFocus end
  local groups = State.ThreadGroups(st)
  if groups[1] then return groups[1].items[1].id end
  return nil
end

--- Status line pieces shared by the chat window and tracker.
function ns.LinkStatus()
  local I = ns.Inbound
  local e = {
    demo = ns.demo,
    slotsLeft = I and I.SlotsLeft() or 0,
    slotsTotal = I and I.total or 0,
    sending = ns.Outbound and ns.Outbound.Progress() or nil,
    notRespondingAt = ns.notRespondingAt,
    notice = (ns.notice and GetTime() < ns.notice.untilT) and ns.notice.text or nil,
  }
  return State.LinkStatus(ns.state, ns.Now(), e)
end

function ns.ReloadForLink()
  if InCombatLockdown and InCombatLockdown() then
    ns.Print("Reload after combat ends.")
    return
  end
  ReloadUI()
end

---------------------------------------------------------------------------------------------
-- Login wiring
---------------------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_LEAVING_WORLD")
pcall(ev.RegisterEvent, ev, "LOADING_SCREEN_ENABLED")
pcall(ev.RegisterEvent, ev, "LOADING_SCREEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")

ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == addonName then
    T3BridgeDB = type(T3BridgeDB) == "table" and T3BridgeDB or {}
    applyDefaults(T3BridgeDB, DEFAULTS)
    if T3BridgeDB.cell ~= 1 and T3BridgeDB.cell ~= 2 and T3BridgeDB.cell ~= 4 then T3BridgeDB.cell = 2 end
    ns.db = T3BridgeDB
    -- WoW's math.random is already seeded by the client; reseed only where allowed.
    if math.randomseed then pcall(math.randomseed, math.floor((GetTime() * 1000) % 2147483647) + time()) end
    if inboxRaw ~= nil then
      local r = ns.ApplySnapshot(inboxRaw, inboxEnd, "inbox")
      ns.Debug("inbox at load: " .. r)
      inboxRaw, inboxEnd = nil, nil
    end
  elseif event == "PLAYER_LOGIN" then
    if ns.Inbound then ns.Inbound.Discover() end
    ns.Fire("login")
  elseif event == "PLAYER_ENTERING_WORLD" or event == "LOADING_SCREEN_DISABLED" then
    ns.inWorld = true
    ns.Fire("world")
  elseif event == "PLAYER_LEAVING_WORLD" or event == "LOADING_SCREEN_ENABLED" then
    ns.inWorld = false
  elseif event == "PLAYER_REGEN_DISABLED" then
    ns.Fire("combat")
  end
end)

-- Key binding labels (Bindings.xml)
_G.BINDING_HEADER_T3BRIDGE = "T3Bridge"
_G.BINDING_NAME_T3BRIDGE_TOGGLE = "Toggle T3 Code chat"
function _G.T3Bridge_ToggleChat()
  if ns.UI and ns.UI.ToggleChat then ns.UI.ToggleChat() end
end
