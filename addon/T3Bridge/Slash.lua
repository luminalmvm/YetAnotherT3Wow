-- T3Bridge slash commands: /t3 (and /t3bridge).
--
-- Every command runs inside a protected call. WoW hides Lua errors by default, and an error that
-- escapes a slash handler aborts the chat box's Enter handling: the typed line just stays there
-- and nothing prints (that is how the Phase 0 "/t3 spike fonts does nothing" bug looked). Errors
-- are therefore caught here and printed in chat.
local _, ns = ...
local State = ns.State

-- "|" starts a UI escape code in chat ("|r" resets colour and swallows the "r"), so help text
-- writes a literal bar as "||".
local HELP = {
  "/t3 - open or close the chat window",
  "/t3 demo - sample threads, no companion needed (again to leave)",
  "/t3 status - link details",
  "/t3 spike s1 || s1 combat || s2 || fonts || templates || img - in-game checks",
  "Images: Attach button next to Send, or Ctrl+V in the message box after copying an image (e.g. Win+Shift+S)",
  function() return "/t3 cell 1||2||4 - outbound cell size in pixels (now " .. ns.db.cell .. ")" end,
  function() return "/t3 hold 100-500 - ms each outbound frame stays visible (now " .. ns.db.hold .. ")" end,
  function()
    return "/t3 tracker on||off||reset||auto||below||above||free - tracker placement (now " .. (ns.db.tracker.mode or "auto") .. ")"
  end,
  "/t3 minimap on||off||reset - minimap button (drag it around the minimap to move it)",
  "/t3 reset - reset window, tracker and minimap button positions",
  "/t3 debug - toggle debug messages, /t3 log - recent debug lines",
}

local function status()
  local I = ns.Inbound
  local text = ns.LinkStatus()
  ns.Print("Link: " .. text)
  ns.Print(string.format("Slots: %d free of %d installed; polls %d, load failures %d, swallowed errors %d, last load %.1f ms",
    I.SlotsLeft(), I.total, I.stats.polls, I.stats.loadFail, I.stats.swallowed, I.stats.lastMs or 0))
  local interval = I.Interval()
  ns.Print("Next poll interval: " .. (interval and (interval .. " s") or "stopped"))
  local snap = ns.state.snap
  if snap then
    ns.Print(string.format("Snapshot: sid %s seq %d, age %ds, %d threads, ack %d for %s",
      ns.Compat.Escape(snap.sid), snap.seq, State.Age(ns.state, ns.Now()) or -1, #snap.threads, snap.ack,
      ns.Compat.Escape(tostring(snap.asid))))
  else
    ns.Print("Snapshot: none yet")
  end
  local s = ns.state.stats
  ns.Print(string.format("Results: accepted %d, stale %d, torn %d, missing %d, reset %d",
    s.accepted or 0, s.stale or 0, s.torn or 0, s.missing or 0, s.reset or 0))
  local ob = ns.outbox
  ns.Print(string.format("Outbound: session %s, next seq %d, queued %d, cell %d px, hold %d ms",
    ob and ob:SidHex() or "-", ob and ob.nextSeq or 1, ob and ob:Pending() or 0, ns.db.cell, ns.db.hold))
  local slots = snap and snap.imgslots
  local img = ns.db.img or {}
  ns.Print(string.format("Images: %s; slots %s; spike: works %s, /reload frees %s",
    ns.ImagesWork() and "on" or "off (shown as text)", slots and (slots.left .. " of " .. slots.total .. " left") or "unknown",
    tostring(img.works), tostring(img.reloadFrees)))
end

local TRACKER_MODES = { auto = true, below = true, above = true, free = true }

local function handler(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  rest = rest or ""
  if cmd == "" then
    ns.UI.ToggleChat()
  elseif cmd == "help" or cmd == "?" then
    for _, l in ipairs(HELP) do ns.Print(type(l) == "function" and l() or l) end
  elseif cmd == "demo" then
    ns.DemoMode.Toggle()
  elseif cmd == "status" then
    status()
  elseif cmd == "spike" then
    local which, arg = rest:match("^(%S*)%s*(.-)$")
    which = (which or ""):lower()
    if which == "s1" then ns.Spike.S1(arg ~= "" and arg:lower() or nil)
    elseif which == "s2" then ns.Spike.S2(arg)
    elseif which == "fonts" or which == "font" then ns.Spike.Fonts()
    elseif which == "templates" or which == "template" then ns.Spike.Templates()
    elseif which == "img" or which == "image" or which == "images" then ns.Spike.Img(arg)
    else ns.Print("usage: /t3 spike s1 || s1 combat || s2 || fonts || templates || img") end
  elseif cmd == "cell" then
    local n = tonumber(rest)
    if n == 1 or n == 2 or n == 4 then ns.db.cell = n; ns.Print("Outbound cell size: " .. n .. " px")
    else ns.Print("usage: /t3 cell 1||2||4 (now " .. ns.db.cell .. ")") end
  elseif cmd == "hold" then
    local n = tonumber(rest)
    if n and n >= 100 and n <= 500 then ns.db.hold = math.floor(n); ns.Print("Outbound hold: " .. ns.db.hold .. " ms")
    else ns.Print("usage: /t3 hold 100-500 (now " .. ns.db.hold .. ")") end
  elseif cmd == "debug" then
    ns.db.debug = not ns.db.debug
    ns.Print("Debug " .. (ns.db.debug and "on" or "off"))
  elseif cmd == "log" then
    for k = math.max(1, #ns.log - 30), #ns.log do ns.Print(ns.Compat.Escape(ns.log[k])) end
  elseif cmd == "tracker" then
    rest = rest:lower()
    if rest == "reset" then
      ns.UI.Tracker.ResetPosition()
      ns.Print("Tracker: position reset (mode auto).")
    elseif TRACKER_MODES[rest] then
      ns.UI.Tracker.SetMode(rest)
      ns.Print("Tracker mode: " .. rest .. (rest == "free" and " (Shift-drag the T3 Code header to move it)" or ""))
    elseif rest == "on" or rest == "off" or rest == "" then
      ns.db.tracker.hide = (rest == "off")
      ns.Print("Tracker " .. (ns.db.tracker.hide and "hidden" or "shown"))
    else
      ns.Print("usage: /t3 tracker on||off||reset||auto||below||above||free")
    end
    ns.UI.Tracker.Refresh()
  elseif cmd == "minimap" then
    rest = rest:lower()
    if rest == "reset" then
      ns.UI.Minimap.Reset()
      ns.Print("Minimap button: moved to a free spot on the minimap ring.")
    elseif rest == "off" or rest == "on" or rest == "" then
      ns.UI.Minimap.SetHidden(rest == "off")
    else
      ns.Print("usage: /t3 minimap on||off||reset")
    end
  elseif cmd == "reset" then
    ns.UI.ResetChatPosition()
    ns.UI.Tracker.ResetPosition()
    ns.UI.Minimap.Reset()
    ns.Print("Window, tracker and minimap button positions reset.")
  elseif cmd == "reload" then
    ns.ReloadForLink()
  else
    ns.Print("Unknown command. /t3 help")
  end
end

local function traceback(err)
  local stack = _G.debugstack and _G.debugstack(2, 4, 0) or (debug and debug.traceback and debug.traceback("", 2)) or ""
  return tostring(err) .. "\n" .. tostring(stack)
end

--- Run a slash command; never lets an error escape (see the note at the top of this file).
function ns.RunSlash(msg)
  local ok, err = xpcall(function() handler(msg) end, traceback)
  if not ok then
    local first = tostring(err):match("^[^\n]*") or tostring(err)
    ns.Debug("slash error in '/t3 " .. tostring(msg) .. "': " .. tostring(err))
    ns.Print("|cffff3030Lua error|r in '/t3 " .. ns.Compat.Escape(msg) .. "': " .. ns.Compat.Escape(first:sub(1, 200)))
    ns.Print("Details: /t3 log. Please report this line.")
  end
  return ok
end

SLASH_T3BRIDGE1 = "/t3"
SLASH_T3BRIDGE2 = "/t3bridge"
SlashCmdList["T3BRIDGE"] = ns.RunSlash
