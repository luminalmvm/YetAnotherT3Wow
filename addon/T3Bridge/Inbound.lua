-- T3Bridge Inbound: reads companion snapshots by loading the next load-on-demand slot addon
-- (T3Bridge_S0001...). Each slot can be loaded once per UI session. See PROTOCOL.md section 2.
local _, ns = ...
local Compat, State = ns.Compat, ns.State

local Inbound = {}
ns.Inbound = Inbound

Inbound.slots = {}      -- names of slots not yet loaded, in order
Inbound.next = 1
Inbound.total = 0       -- slots installed (loaded or not)
Inbound.burstUntil = 0
Inbound.nextPollAt = nil
Inbound.lastPollAt = 0
Inbound.quickRetry = false
Inbound.stats = { polls = 0, loadFail = 0, swallowed = 0, lastMs = 0 }

local SLOT_PATTERN = "^T3Bridge_S(%d%d%d%d)$"

--- Find installed slot addons. Called at PLAYER_LOGIN (and by /t3 status).
function Inbound.Discover()
  local found = {}
  for i = 1, Compat.GetNumAddOns() do
    local name = Compat.GetAddOnInfo(i)
    local n = name and name:match(SLOT_PATTERN)
    if n then found[#found + 1] = { name = name, n = tonumber(n) } end
  end
  table.sort(found, function(a, b) return a.n < b.n end)
  local free = {}
  for _, s in ipairs(found) do
    if not Compat.IsAddOnLoaded(s.name) then free[#free + 1] = s.name end
  end
  Inbound.slots, Inbound.next, Inbound.total = free, 1, #found
  ns.Debug(string.format("slots: %d installed, %d free", #found, #free))
  return #found, #free
end

function Inbound.SlotsLeft()
  return math.max(0, #Inbound.slots - Inbound.next + 1)
end

--- Load one slot-style addon and capture what its file assigned. Errors (torn or corrupt file)
--- are swallowed. Used by polling and by /t3 spike s1.
--- Returns { loaded, reason, caught = {msgs}, ms, globals = {name = value...} }.
function Inbound.LoadSlot(name, globals)
  globals = globals or { "T3B_IN", "T3B_IN_END" }
  for _, g in ipairs(globals) do _G[g] = nil end
  local t0 = Compat.ProfileMs()
  local ok, loaded, reason, caught = Compat.CallSwallowing(Compat.LoadAddOn, name)
  if ok and not loaded and reason == "DISABLED" then
    Compat.EnableAddOn(name)
    local ok2, l2, r2, c2 = Compat.CallSwallowing(Compat.LoadAddOn, name)
    ok, loaded, reason = ok2, l2, r2
    for _, m in ipairs(c2) do caught[#caught + 1] = m end
  end
  local out = { loaded = ok and loaded and true or false, reason = reason, caught = caught,
    ms = Compat.ProfileMs() - t0, values = {} }
  for _, g in ipairs(globals) do
    out.values[g] = _G[g]
    _G[g] = nil
  end
  return out
end

function Inbound.Poll()
  if ns.demo then return end
  if Inbound.SlotsLeft() <= 0 then
    ns.Fire("link")
    return
  end
  local name = Inbound.slots[Inbound.next]
  Inbound.next = Inbound.next + 1
  Inbound.lastPollAt = GetTime()
  local r = Inbound.LoadSlot(name)
  local s = Inbound.stats
  s.polls, s.lastMs = s.polls + 1, r.ms
  if #r.caught > 0 then
    s.swallowed = s.swallowed + #r.caught
    ns.Debug(name .. ": swallowed " .. #r.caught .. " error(s): " .. r.caught[1]:sub(1, 120))
  end
  if not r.loaded then
    s.loadFail = s.loadFail + 1
    ns.Debug(name .. ": LoadAddOn failed: " .. tostring(r.reason))
  end
  local result = ns.ApplySnapshot(r.values.T3B_IN, r.values.T3B_IN_END, name)
  if result == "torn" or result == "missing" then Inbound.quickRetry = true end
  ns.Fire("link")
end

local function chatStreaming()
  local tid = ns.selected
  local f = tid and State.Focus(ns.state, tid)
  return f and f.streaming or false
end

function Inbound.Interval()
  local now = GetTime()
  return State.Cadence({
    now = now,
    slotsLeft = (Inbound.total > 0) and Inbound.SlotsLeft() or 0,
    awaitingAck = ns.outbox ~= nil and ns.outbox:Busy(),
    burstUntil = Inbound.burstUntil,
    offline = State.IsOffline(ns.state, ns.Now()),
    chatOpen = ns.UI and ns.UI.ChatIsOpen and ns.UI.ChatIsOpen() or false,
    streaming = chatStreaming(),
    anyActive = State.AnyActive(ns.state),
  })
end

function Inbound.Schedule()
  local interval = Inbound.Interval()
  if not interval then Inbound.nextPollAt = nil; return end
  if Inbound.quickRetry then interval, Inbound.quickRetry = 0.5, false end
  Inbound.nextPollAt = GetTime() + interval
end

--- Re-evaluate the cadence now (chat opened, thread changed); never delays a poll.
function Inbound.Reschedule()
  local interval = Inbound.Interval()
  if not interval then Inbound.nextPollAt = nil; return end
  local candidate = math.max(GetTime() + 0.2, Inbound.lastPollAt + interval)
  if not Inbound.nextPollAt or candidate < Inbound.nextPollAt then Inbound.nextPollAt = candidate end
end

--- Poll at 1 s for `sec` seconds (after an outbound send).
function Inbound.Burst(sec)
  Inbound.burstUntil = math.max(Inbound.burstUntil, GetTime() + (sec or 10))
  Inbound.Reschedule()
end

ns.On("world", function()
  if Inbound.ticker then return end
  Inbound.nextPollAt = GetTime() + 1.0
  Inbound.ticker = Compat.NewTicker(0.25, function()
    if not ns.inWorld or ns.demo or not Inbound.nextPollAt then return end
    if GetTime() >= Inbound.nextPollAt then
      Inbound.Poll()
      Inbound.Schedule()
    end
  end)
end)

ns.On("login", function()
  if Inbound.total == 0 then
    ns.Debug("no T3Bridge_S#### slot addons found: reload-only mode (Inbox.lua)")
  end
end)
