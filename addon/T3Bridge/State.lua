-- T3Bridge State: snapshot validation, the data model, display rules, poll cadence, and the
-- outbound stop-and-wait state machine. Pure Lua 5.1 with no WoW API: every time value is passed in.
-- Spec: protocol/PROTOCOL.md sections 2.4-2.6 and 3.5.
local _, ns = ...
ns = ns or {}

local State = {}
ns.State = State

local floor, type, ipairs, pairs, tostring = math.floor, type, ipairs, pairs, tostring

State.OFFLINE_AFTER = 30      -- seconds since snapshot ts
State.MAX_THREADS = 30        -- PROTOCOL D15 (was 12)
State.MAX_MSGS = 120
State.MAX_CACHE = 400
State.MAX_TRACKER_ROWS = 16   -- upper bound; the tracker also fits rows to the space on screen
State.NOT_RESPONDING_SHOW = 30 -- seconds the "not responding" status stays up

local function codec() return ns.Codec end

---------------------------------------------------------------------------------------------
-- Field sanitisers. They never raise; bad input gives nil.
---------------------------------------------------------------------------------------------
local function str(v, max)
  if type(v) == "number" then v = tostring(v) end
  if type(v) ~= "string" then return nil end
  if max and #v > max then v = codec().Utf8Truncate(v, max) end
  return v
end

local function int(v)
  if type(v) == "number" and v == v and v > -1e15 and v < 1e16 then return floor(v) end
  return nil
end

local function isId(v)
  return type(v) == "string" and #v >= 1 and #v <= 64 and not v:find("[%c%s]")
end
State.IsId = isId

local THREAD_ST = { running = true, completed = true, failed = true, stopped = true, idle = true }
local NEEDS = { approval = true, input = true }
local ROLES = { u = true, a = true, t = true, s = true }

local function normPending(p)
  if type(p) ~= "table" then return nil end
  local kind = (p.kind == "input") and "input" or "approval"
  if not isId(p.rid) then return nil end
  local out = { kind = kind, rid = p.rid, text = str(p.text, 4000) or "", options = {} }
  if type(p.options) == "table" then
    for _, o in ipairs(p.options) do
      if type(o) == "table" and isId(o.id) and #out.options < 8 then
        out.options[#out.options + 1] = { id = o.id, label = str(o.label, 64) or o.id }
      end
    end
  end
  return out
end

local function normMsg(m)
  if type(m) ~= "table" then return nil end
  local i = int(m.i)
  if not i or i < 1 then return nil end
  local segs = {}
  local total = 0
  if type(m.segs) == "table" then
    for _, s in ipairs(m.segs) do
      if type(s) == "table" then
        local text = str(s[2])
        if text and text ~= "" then
          local kind = (s[1] == "c") and "c" or "p"
          segs[#segs + 1] = { kind, text }
          total = total + #text
        end
      end
    end
  end
  return {
    i = i, r = ROLES[m.r] and m.r or "s", ts = int(m.ts), segs = segs, more = (m.more == true),
    size = total,
  }
end

local function normThread(t)
  if type(t) ~= "table" or not isId(t.id) then return nil end
  return {
    id = t.id,
    title = str(t.title, 120) or t.id,
    st = THREAD_ST[t.st] and t.st or "idle",
    need = NEEDS[t.need] and t.need or nil,
    t0 = int(t.t0), t1 = int(t.t1),
    model = str(t.model, 64), proj = str(t.proj, 64),
  }
end

local function isOptId(v)
  return type(v) == "string" and #v >= 1 and #v <= 32 and v:find("^[%w_.:-]+$") ~= nil
end
State.IsOptId = isOptId

--- models[i].opts -> { vals = {...}, def = "..." } for the "effort" descriptor, or nil.
local function normEffortOpt(opts)
  if type(opts) ~= "table" then return nil end
  for _, o in ipairs(opts) do
    if type(o) == "table" and o.id == "effort" and type(o.vals) == "table" then
      local vals, has = {}, {}
      for _, v in ipairs(o.vals) do
        if isOptId(v) and not has[v] and #vals < 12 then vals[#vals + 1] = v; has[v] = true end
      end
      if #vals > 0 then return { vals = vals, def = has[o.def] and o.def or vals[1], has = has } end
    end
  end
  return nil
end

local function normFocus(f)
  if type(f) ~= "table" or not isId(f.id) then return nil end
  local out = { id = f.id, model = str(f.model, 64), models = {}, streaming = (f.streaming == true),
    pending = normPending(f.pending), msgs = {} }
  -- Optional (PROTOCOL 2.2): whether T3 holds messages older than this window. nil = unknown.
  if type(f.older) == "boolean" then out.older = f.older end
  -- Optional (PROTOCOL D14): the thread's reasoning effort and each model's effort choices.
  if isOptId(f.effort) then out.effort = f.effort end
  if type(f.models) == "table" then
    for _, m in ipairs(f.models) do
      if type(m) == "table" and isId(m.id) and #out.models < 24 then
        out.models[#out.models + 1] = { id = m.id, name = str(m.name, 64) or m.id, effort = normEffortOpt(m.opts) }
      end
    end
  end
  if type(f.msgs) == "table" then
    local seen = {}
    for _, m in ipairs(f.msgs) do
      local nm = normMsg(m)
      if nm and not seen[nm.i] and #out.msgs < State.MAX_MSGS then
        seen[nm.i] = true
        out.msgs[#out.msgs + 1] = nm
      end
    end
    table.sort(out.msgs, function(a, b) return a.i < b.i end)
  end
  return out
end

--- Validate and normalise a raw snapshot. Returns snap or nil, reason.
--- reason is one of "missing", "version", "torn".
function State.Validate(raw, rawEnd)
  if type(raw) ~= "table" then return nil, "missing" end
  if raw.v ~= 1 then return nil, "version" end
  local seq = int(raw.seq)
  if not seq or rawEnd ~= raw.seq then return nil, "torn" end
  local snap = {
    v = 1, sid = str(raw.sid, 16) or "?", seq = seq, ts = int(raw.ts) or 0, ack = int(raw.ack) or 0,
    asid = type(raw.asid) == "string" and raw.asid:lower() or nil, threads = {}, focus = nil, err = nil,
  }
  if type(raw.err) == "table" and int(raw.err.seq) then
    snap.err = { seq = int(raw.err.seq), text = str(raw.err.text, 200) or "error" }
  end
  if type(raw.threads) == "table" then
    local seen = {}
    for _, t in ipairs(raw.threads) do
      local nt = normThread(t)
      if nt and not seen[nt.id] and #snap.threads < State.MAX_THREADS then
        seen[nt.id] = true
        snap.threads[#snap.threads + 1] = nt
      end
    end
  end
  snap.focus = normFocus(raw.focus)
  return snap
end

---------------------------------------------------------------------------------------------
-- Model
---------------------------------------------------------------------------------------------
function State.New()
  return { lastSid = nil, lastSeq = 0, snap = nil, acceptedAt = nil, cache = { tid = nil, byI = {}, n = 0 },
    stats = { accepted = 0, stale = 0, torn = 0, missing = 0, version = 0, reset = 0 } }
end

local function mergeFocus(st, f)
  if not f then return end
  local c = st.cache
  if c.tid ~= f.id then
    c = { tid = f.id, byI = {}, n = 0 }
    st.cache = c
  end
  for _, m in ipairs(f.msgs) do
    if not c.byI[m.i] then c.n = c.n + 1 end
    c.byI[m.i] = m
  end
  if c.n > State.MAX_CACHE then -- drop the oldest
    local idx = {}
    for i in pairs(c.byI) do idx[#idx + 1] = i end
    table.sort(idx)
    for k = 1, c.n - State.MAX_CACHE do c.byI[idx[k]] = nil end
    c.n = State.MAX_CACHE
  end
end

--- Feed a raw snapshot (T3B_IN, T3B_IN_END). Returns one of:
--- "accepted", "reset" (accepted after a companion sid change), "stale", "torn", "missing", "version".
function State.Accept(st, raw, rawEnd, now)
  local snap, why = State.Validate(raw, rawEnd)
  if not snap then
    st.stats[why] = (st.stats[why] or 0) + 1
    return why
  end
  local result = "accepted"
  if snap.sid ~= st.lastSid then
    if st.lastSid ~= nil then result = "reset" end
    st.lastSid = snap.sid
    st.lastSeq = 0
    st.cache = { tid = nil, byI = {}, n = 0 }
  elseif snap.seq <= st.lastSeq then
    st.stats.stale = st.stats.stale + 1
    return "stale"
  end
  st.lastSeq = snap.seq
  st.snap = snap
  st.acceptedAt = now
  mergeFocus(st, snap.focus)
  st.stats[result] = (st.stats[result] or 0) + 1
  return result
end

function State.IsOffline(st, now)
  return (not st.snap) or (now - st.snap.ts > State.OFFLINE_AFTER)
end

function State.Age(st, now)
  if not st.snap then return nil end
  local a = now - st.snap.ts
  return a < 0 and 0 or a
end

function State.Thread(st, tid)
  if not st.snap then return nil end
  for _, t in ipairs(st.snap.threads) do if t.id == tid then return t end end
  return nil
end

--- Focus detail, only when the companion's focus is `tid`.
function State.Focus(st, tid)
  local f = st.snap and st.snap.focus
  if f and f.id == tid then return f end
  return nil
end

--- Cached messages of `tid`, oldest first.
function State.Messages(st, tid)
  local c = st.cache
  if c.tid ~= tid then return {} end
  local list = {}
  for _, m in pairs(c.byI) do list[#list + 1] = m end
  table.sort(list, function(a, b) return a.i < b.i end)
  return list
end

--- Offer "Earlier messages"? Uses focus.older when the companion sends it (message indexes are
--- sparse, so "first i > 1" is only a guess); falls back to that guess for older companions.
function State.CanLoadEarlier(fo, list)
  if not fo or not list or not list[1] then return false end
  local first = fo.msgs and fo.msgs[1]
  if fo.older ~= nil and (not first or list[1].i >= first.i) then return fo.older end
  return list[1].i > 1
end

--- Cheap change signature of a message list, used to skip relayouts.
function State.MessagesSignature(list)
  local parts = {}
  for k, m in ipairs(list) do
    local last = m.segs[#m.segs]
    parts[k] = m.i .. ":" .. m.size .. ":" .. #m.segs .. ":" .. (last and last[2]:sub(-8) or "") .. (m.more and "+" or "")
  end
  return table.concat(parts, "|")
end

---------------------------------------------------------------------------------------------
-- Display rules
---------------------------------------------------------------------------------------------
State.STATUS = {
  approval  = { label = "Needs approval", icon = "Interface\\GossipFrame\\AvailableQuestIcon", color = { 1, 0.5, 0 }, timer = { 1, 0.5, 0 }, pulse = true, order = 1, group = "needs" },
  input     = { label = "Needs input", icon = "Interface\\GossipFrame\\AvailableQuestIcon", color = { 1, 0.5, 0 }, timer = { 1, 0.5, 0 }, pulse = true, order = 1, group = "needs" },
  running   = { label = "Running", icon = "Interface\\COMMON\\Indicator-Yellow", color = { 1, 1, 1 }, timer = { 1, 0.82, 0 }, order = 2, group = "running" },
  completed = { label = "Completed", icon = "Interface\\RaidFrame\\ReadyCheck-Ready", color = { 0.1, 1, 0.1 }, timer = { 0.1, 1, 0.1 }, order = 3, group = "recent", done = true },
  failed    = { label = "Failed", icon = "Interface\\RaidFrame\\ReadyCheck-NotReady", color = { 1, 0.15, 0.15 }, timer = { 1, 0.15, 0.15 }, order = 3, group = "recent", done = true },
  stopped   = { label = "Stopped", icon = "Interface\\COMMON\\Indicator-Gray", color = { 0.62, 0.62, 0.62 }, timer = { 0.62, 0.62, 0.62 }, order = 3, group = "recent", done = true },
  idle      = { label = "Idle", icon = "Interface\\COMMON\\Indicator-Gray", color = { 0.62, 0.62, 0.62 }, timer = { 0.62, 0.62, 0.62 }, order = 4, group = "recent" },
}

function State.StatusKey(t)
  if t.need then return t.need end
  return t.st
end

function State.FormatElapsed(sec)
  sec = floor(sec or 0)
  if sec < 0 then sec = 0 end
  if sec < 3600 then return string.format("%d:%02d", floor(sec / 60), sec % 60) end
  return string.format("%d:%02d:%02d", floor(sec / 3600), floor(sec / 60) % 60, sec % 60)
end

--- Elapsed seconds: live for open runs, frozen at t1 - t0 for finished ones.
function State.Elapsed(t, now)
  if not t.t0 then return nil end
  local e = (t.t1 or now) - t.t0
  return e < 0 and 0 or e
end

---------------------------------------------------------------------------------------------
-- Tracker rules (Phase 2, PROTOCOL D15): every open (unsettled) thread the companion sends is
-- listed. Nothing is hidden by age or by being opened. Rows the user collapsed sort after the
-- expanded ones and render as a compact line. A collapsed thread re-expands by itself when it
-- needs approval/input or fails (a new "attention" state), and can be collapsed again.
---------------------------------------------------------------------------------------------

--- Attention signature: "" when nothing needs the user, else a short state key.
function State.AttentionSig(t)
  if t.need then return t.need end
  if t.st == "failed" then return "failed:" .. tostring(t.t1 or 0) end
  return ""
end

--- Collapse entries live in SavedVariables as collapsed[tid] = true (no attention when collapsed)
--- or = <attention signature> (collapsed while that attention state was showing). No titles/text.
function State.IsCollapsed(collapsed, tid) return collapsed ~= nil and collapsed[tid] ~= nil end

function State.SetCollapsed(collapsed, t, on)
  if on then
    local sig = State.AttentionSig(t)
    collapsed[t.id] = (sig == "") and true or sig
  else
    collapsed[t.id] = nil
  end
end

--- Auto-expand: a collapsed thread whose attention state is new expands. Returns the number of
--- threads expanded. Also forgets an old attention state once it is over, so the next approval of
--- the same kind expands the row again.
function State.ApplyAutoExpand(collapsed, st)
  if not collapsed or not st.snap then return 0 end
  local n = 0
  for _, t in ipairs(st.snap.threads) do
    local stored = collapsed[t.id]
    if stored ~= nil then
      local sig = State.AttentionSig(t)
      if sig ~= "" and sig ~= stored then
        collapsed[t.id] = nil
        n = n + 1
      elseif sig == "" and stored ~= true then
        collapsed[t.id] = true
      end
    end
  end
  return n
end

--- Keep SavedVariables small: when there are many entries, forget threads no longer listed.
function State.PruneCollapsed(collapsed, st, keep)
  if not collapsed or not st.snap then return end
  local count = 0
  for _ in pairs(collapsed) do count = count + 1 end
  if count <= (keep or 60) then return end
  local listed = {}
  for _, t in ipairs(st.snap.threads) do listed[t.id] = true end
  for tid in pairs(collapsed) do if not listed[tid] then collapsed[tid] = nil end end
end

local GROUP_RANK = { needs = 1, running = 2 }

--- All listed threads in tracker order: expanded first, then collapsed; within each part
--- needs you (longest waiting first), running (longest running first), then the others in the
--- companion's order (most recently updated first).
local function trackerCandidates(st, collapsed)
  local out = {}
  if not st.snap then return out end
  for idx, t in ipairs(st.snap.threads) do
    local key = State.StatusKey(t)
    local info = State.STATUS[key]
    out[#out + 1] = { t = t, key = key, info = info, idx = idx, collapsed = State.IsCollapsed(collapsed, t.id) }
  end
  table.sort(out, function(a, b)
    if a.collapsed ~= b.collapsed then return not a.collapsed end
    local ra, rb = GROUP_RANK[a.info.group] or 3, GROUP_RANK[b.info.group] or 3
    if ra ~= rb then return ra < rb end
    if ra < 3 and (a.t.t0 or 0) ~= (b.t.t0 or 0) then return (a.t.t0 or 0) < (b.t.t0 or 0) end
    return a.idx < b.idx
  end)
  return out
end

--- Rows for the tracker (at most maxRows, default all). Each row = { t, key, info, elapsed, collapsed }.
--- Returns rows, total, collapsedCount.
function State.TrackerRows(st, now, maxRows, collapsed)
  local c = trackerCandidates(st, collapsed)
  local rows, nc = {}, 0
  for _, r in ipairs(c) do if r.collapsed then nc = nc + 1 end end
  for k = 1, math.min(#c, maxRows or #c) do
    local r = c[k]
    local e = State.Elapsed(r.t, now)
    r.elapsed = e and State.FormatElapsed(e) or ""
    rows[k] = r
  end
  return rows, #c, nc
end

--- "2 running · 1 needs you · 1 failed · 3 collapsed"; "5 open"; "no open threads".
State.DOT = " \194\183 " -- U+00B7 middle dot, UTF-8
function State.Summary(st, now, collapsed)
  local n = { needs = 0, running = 0, done = 0, failed = 0, collapsed = 0, total = 0 }
  for _, r in ipairs(trackerCandidates(st, collapsed)) do
    n.total = n.total + 1
    if r.collapsed then n.collapsed = n.collapsed + 1 end
    if r.info.group == "needs" then n.needs = n.needs + 1
    elseif r.key == "running" then n.running = n.running + 1
    elseif r.key == "completed" then n.done = n.done + 1
    elseif r.key == "failed" then n.failed = n.failed + 1 end
  end
  local p = {}
  if n.running > 0 then p[#p + 1] = n.running .. " running" end
  if n.needs > 0 then p[#p + 1] = n.needs .. " needs you" end
  if n.failed > 0 then p[#p + 1] = n.failed .. " failed" end
  if n.collapsed > 0 then p[#p + 1] = n.collapsed .. " collapsed" end
  if #p == 0 then
    if n.total == 0 then return "no open threads", n end
    return n.total .. " open", n
  end
  return table.concat(p, State.DOT), n
end

function State.AnyNeedsYou(st)
  if not st.snap then return false end
  for _, t in ipairs(st.snap.threads) do if t.need then return true end end
  return false
end

function State.AnyActive(st)
  if not st.snap then return false end
  for _, t in ipairs(st.snap.threads) do if t.need or t.st == "running" then return true end end
  return false
end

--- Thread dropdown groups: Needs you / Running / Recent (empty groups left out).
function State.ThreadGroups(st)
  local g = { needs = {}, running = {}, recent = {} }
  if st.snap then
    for _, t in ipairs(st.snap.threads) do
      local info = State.STATUS[State.StatusKey(t)]
      local list = g[info.group]
      list[#list + 1] = t
    end
  end
  local out = {}
  if #g.needs > 0 then out[#out + 1] = { title = "Needs you", items = g.needs } end
  if #g.running > 0 then out[#out + 1] = { title = "Running", items = g.running } end
  if #g.recent > 0 then out[#out + 1] = { title = "Other open threads", items = g.recent } end
  return out
end

---------------------------------------------------------------------------------------------
-- Poll cadence (section 2.5). o = { now, slotsLeft, awaitingAck, burstUntil, offline,
--   chatOpen, streaming, anyActive }. Returns seconds, or nil = stop polling.
---------------------------------------------------------------------------------------------
function State.Cadence(o)
  if o.slotsLeft ~= nil and o.slotsLeft <= 0 then return nil end
  if o.awaitingAck or (o.burstUntil and o.now < o.burstUntil) then return 1 end
  if o.offline then return 15 end
  if o.chatOpen and o.streaming then return 1 end
  if o.anyActive then return 3 end
  return 15
end

--- Status line. e = { demo, slotsLeft, slotsTotal, sending = {part, parts} | nil,
---   notRespondingAt, now }. Returns text, kind ("ok","warn","bad","info"), clickable(bool).
function State.LinkStatus(st, now, e)
  e = e or {}
  if e.demo then return "Demo mode (no companion)", "info", false end
  if e.slotsTotal and e.slotsTotal > 0 and e.slotsLeft == 0 then
    return "Link exhausted: click to reload", "bad", true
  end
  if e.sending then return string.format("Sending %d/%d", e.sending[1], e.sending[2]), "info", false end
  if e.notRespondingAt and now - e.notRespondingAt < State.NOT_RESPONDING_SHOW then
    return "Companion not responding", "bad", false
  end
  if State.IsOffline(st, now) then return "Companion offline", "bad", false end
  if e.slotsTotal and e.slotsTotal > 0 and e.slotsLeft < e.slotsTotal * 0.10 then
    return "Link low: click to reload", "warn", true
  end
  if e.slotsTotal == 0 then
    return "Linked (reload-only) " .. State.DOT:sub(2) .. State.Age(st, now) .. "s", "warn", false
  end
  return "Linked" .. State.DOT .. State.Age(st, now) .. "s", "ok", false
end

---------------------------------------------------------------------------------------------
-- Outbox: stop-and-wait sender (section 3.5). Pure: the caller draws the frames and passes time.
---------------------------------------------------------------------------------------------
local Outbox = {}
Outbox.__index = Outbox
State.Outbox = Outbox

--- opt = { rnd = function(lo,hi), ackTimeout = 3, maxAttempts = 4 }
function State.NewOutbox(opt)
  opt = opt or {}
  local o = setmetatable({
    queue = {}, cur = nil, nextSeq = 1, rnd = opt.rnd,
    ackTimeout = opt.ackTimeout or 3, maxAttempts = opt.maxAttempts or 4,
    helloSent = false,
  }, Outbox)
  o.sid = codec().RandomSid(o.rnd)
  return o
end

function Outbox:SidHex() return codec().ToHex(self.sid) end
function Outbox:Pending() return #self.queue + (self.cur and 1 or 0) end
function Outbox:Busy() return self.cur ~= nil end

local COALESCE = { focus = true, model = true }

--- Queue a command. args = command fields, without clientMsgId for "send"
--- (send: {tid, text}; ans: {tid, rid, answer}). meta is kept on the item for the UI.
function Outbox:Enqueue(kind, args, meta)
  local item = { kind = kind, args = args or {}, meta = meta or {} }
  if COALESCE[kind] then
    for k = #self.queue, 1, -1 do
      local q = self.queue[k]
      if q.kind == kind and (kind == "focus" or q.args[1] == item.args[1]) then
        table.remove(self.queue, k)
      end
    end
  end
  if kind == "hello" then
    table.insert(self.queue, 1, item)
  else
    self.queue[#self.queue + 1] = item
  end
  return item
end

local function buildPayload(self, item)
  local C = codec()
  if item.kind == "send" then
    item.clientMsgId = self:SidHex() .. "-" .. item.seq
    return C.BuildCommand("send", item.args[1], item.clientMsgId, item.args[2])
  end
  return C.BuildCommand(item.kind, unpack(item.args))
end

--- Begin the next message if idle. Returns the current item (state "sending") or nil.
function Outbox:Start(now)
  if self.cur or #self.queue == 0 then return self.cur end
  if self.nextSeq > 65535 then
    self.sid = codec().RandomSid(self.rnd)
    self.nextSeq = 1
    self.helloSent = false
    self.rotated = true
  end
  local item = table.remove(self.queue, 1)
  item.seq = self.nextSeq
  self.nextSeq = self.nextSeq + 1
  item.payload = buildPayload(self, item)
  item.frames, item.rows = codec().FramesForMessage(self.sid, item.seq, item.payload, 0)
  item.attempts = 1
  item.state = "sending"
  item.startedAt = now
  self.cur = item
  return item
end

--- The last part of the current transmission has been shown and hidden.
--- Returns an event if an ack arrived during the transmission.
function Outbox:TransmitDone(now)
  local c = self.cur
  if not c or c.state ~= "sending" then return nil end
  if c.acked then
    self.cur = nil
    return { type = "done", item = c, err = c.errText }
  end
  c.state = "wait"
  c.deadline = now + self.ackTimeout
  return nil
end

--- Process a validated snapshot. Returns {type="done", item, err} or nil.
function Outbox:OnSnapshot(snap, now)
  local c = self.cur
  if not c or not snap or snap.asid ~= self:SidHex() then return nil end
  local acked = (snap.ack or 0) >= c.seq
  local errText = (snap.err and snap.err.seq == c.seq) and snap.err.text or nil
  if not acked and not errText then return nil end
  if c.state == "wait" then
    self.cur = nil
    return { type = "done", item = c, err = errText }
  end
  c.acked, c.errText = true, errText -- finish when the running transmission ends
  return nil
end

--- Timeouts. Returns {type="retransmit", item} / {type="failed", item} / nil.
function Outbox:Update(now)
  local c = self.cur
  if not c or c.state ~= "wait" or now < c.deadline then return nil end
  if c.attempts < self.maxAttempts then
    c.attempts = c.attempts + 1
    c.frames = codec().FramesForMessage(self.sid, c.seq, c.payload, 1)
    c.state = "sending"
    return { type = "retransmit", item = c }
  end
  self.cur = nil
  return { type = "failed", item = c }
end

--- Drop everything (used when leaving demo mode, etc.).
function Outbox:Clear()
  self.queue = {}
  self.cur = nil
end

return State
