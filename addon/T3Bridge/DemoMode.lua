-- T3Bridge DemoMode: `/t3 demo` renders everything from the bundled fixture (Demo.lua) with no
-- companion. Commands are handled locally: focus switches threads, send/ans stream a fake reply,
-- model/intr/hist change the demo snapshot. Nothing is drawn on screen or written to disk.
local _, ns = ...
local State, Compat = ns.State, ns.Compat

local DemoMode = {}
ns.DemoMode = DemoMode

local snap, fixtureFocus, heartbeat, streamTicker

local function push()
  snap.seq = snap.seq + 1
  snap.ts = ns.Now()
  ns.ApplySnapshot(snap, snap.seq, "demo")
end

local function thread(tid)
  for _, t in ipairs(snap.threads) do if t.id == tid then return t end end
  for _, t in ipairs(snap.subs or {}) do if t.id == tid then return t end end -- rev 1.4 subagents
end

--- rev 1.4: the subagents of tid ({ id, title, st, t0, t1 }) and the breadcrumb root -> tid.
local function kidsOf(tid)
  local out = {}
  for _, t in ipairs(snap.subs or {}) do
    if t.parent == tid then out[#out + 1] = { id = t.id, title = t.title, st = t.st, need = t.need, t0 = t.t0, t1 = t.t1 } end
  end
  return out
end

local function pathTo(tid)
  local path, cur, guard = {}, thread(tid), 0
  while cur and guard < 8 do
    table.insert(path, 1, { id = cur.id, title = cur.title })
    cur = cur.parent and thread(cur.parent)
    guard = guard + 1
  end
  return path
end

local function lastIndex()
  local m = snap.focus and snap.focus.msgs
  return (m and m[#m] and m[#m].i) or 0
end

local function addMsg(r, text, kind)
  local f = snap.focus
  f.msgs[#f.msgs + 1] = { i = lastIndex() + 1, r = r, ts = ns.Now(), segs = { { kind or "p", text } }, more = false }
  while #f.msgs > 120 do table.remove(f.msgs, 1) end
  return f.msgs[#f.msgs]
end

local REPLY = "Demo reply: in the real setup the T3Bridge companion relays this to T3 Code and the answer "
  .. "streams back here about once per second while this window is open. Nothing left your PC in demo mode."

local function streamReply(tid)
  if streamTicker then streamTicker:Cancel(); streamTicker = nil end
  local t = thread(tid)
  if t then t.st, t.t0, t.t1 = "running", ns.Now(), nil end
  snap.focus.streaming = true
  local m = addMsg("a", "")
  m.segs[1][2] = "..."
  local words, k = {}, 0
  for w in REPLY:gmatch("%S+") do words[#words + 1] = w end
  push()
  streamTicker = Compat.NewTicker(0.4, function()
    k = k + 3
    m.segs[1][2] = table.concat(words, " ", 1, math.min(k, #words))
    if k >= #words then
      m.segs[2] = { "c", "-- example code block\nlocal ok = true\nprint(\"demo\", ok)" }
      snap.focus.streaming = false
      if t then t.st, t.t1 = "completed", ns.Now() end
      streamTicker:Cancel()
      streamTicker = nil
    end
    push()
  end)
end

local function focusFor(tid)
  if tid == fixtureFocus.id then return fixtureFocus end
  local t = thread(tid)
  local title = t and t.title or tid
  local kids = kidsOf(tid)
  local parent = t and t.parent and thread(t.parent)
  local msgs = nil
  if #kids > 0 then
    -- a parent: its history mentions its subagents as links (like T3's subagent items)
    msgs = { { i = 3, r = "t", ts = (t and t.t0 or ns.Now()) + 8, segs = {}, more = false } }
    for _, k in ipairs(kids) do msgs[1].segs[#msgs[1].segs + 1] = { "tl", "Subagent: " .. k.title, id = k.id } end
  end
  local f = {
    id = tid, model = fixtureFocus.model, effort = fixtureFocus.effort, models = fixtureFocus.models, streaming = false,
    pending = (t and t.need == "input") and { kind = "input", rid = "req-demo-" .. tid,
      text = "Which branch should the workflow deploy from?", options = {} } or nil,
    msgs = {
      { i = 1, r = "u", ts = (t and t.t0) or ns.Now(), segs = { { "p", title } }, more = false },
      { i = 2, r = "a", ts = (t and t.t0 or ns.Now()) + 5, segs = { { "p", parent
        and "(Demo) A subagent thread. Use the Up arrow, the breadcrumb or /t3 up to go back to its parent."
        or "(Demo) Only the first thread has a full history; this one is a placeholder." } }, more = false },
    },
  }
  for _, m in ipairs(msgs or {}) do f.msgs[#f.msgs + 1] = m end
  if #kids > 0 then f.kids, f.nkids = kids, #kids end
  if parent then
    f.parent = { id = parent.id, title = parent.title }
    f.path = pathTo(tid)
  end
  return f
end

function DemoMode.Handle(kind, args)
  if not snap then return end
  if kind == "focus" then
    snap.focus = focusFor(args[1])
  elseif kind == "send" then
    if snap.focus.id ~= args[1] then snap.focus = focusFor(args[1]) end
    addMsg("u", args[2] or "")
    streamReply(args[1])
    return
  elseif kind == "ans" then
    local t = thread(args[1])
    if t then t.need = nil end
    snap.focus.pending = nil
    addMsg("t", "Answer: " .. tostring(args[3]))
    streamReply(args[1])
    return
  elseif kind == "model" then
    -- like the companion (PROTOCOL D14): the requested effort, else the current one, else the model's default
    snap.focus.model = args[2]
    local t = thread(args[1])
    local want = args[3] or snap.focus.effort
    snap.focus.effort = nil
    for _, m in ipairs(snap.focus.models or {}) do
      if m.id == args[2] then
        if t then t.model = m.name end
        for _, o in ipairs(m.opts or {}) do
          if o.id == "effort" then
            snap.focus.effort = o.def
            for _, v in ipairs(o.vals or {}) do if v == want then snap.focus.effort = want end end
          end
        end
      end
    end
  elseif kind == "intr" then
    if streamTicker then streamTicker:Cancel(); streamTicker = nil end
    local t = thread(args[1])
    if t then t.st, t.t1, t.need = "stopped", ns.Now(), nil end
    snap.focus.streaming = false
    snap.focus.pending = nil
    addMsg("s", "Stopped by user.")
  elseif kind == "hist" then
    local before = tonumber(args[2]) or 1
    local older = {}
    for i = math.max(1, before - 10), before - 1 do
      older[#older + 1] = { i = i, r = (i % 2 == 0) and "a" or "u", ts = ns.Now() - (before - i) * 60,
        segs = { { "p", "(Demo) older message #" .. i } }, more = false }
    end
    for k = #older, 1, -1 do table.insert(snap.focus.msgs, 1, older[k]) end
    while #snap.focus.msgs > 120 do table.remove(snap.focus.msgs) end
  end
  push()
end

function DemoMode.Start()
  local raw = ns.DemoSnapshot()
  local delta = ns.Now() - raw.ts
  for _, list in ipairs({ raw.threads, raw.subs or {}, raw.focus.kids or {} }) do
    for _, t in ipairs(list) do
      if t.t0 then t.t0 = t.t0 + delta end
      if t.t1 then t.t1 = t.t1 + delta end
    end
  end
  for _, m in ipairs(raw.focus.msgs) do if m.ts then m.ts = m.ts + delta end end
  raw.sid, raw.seq, raw.asid, raw.ack = "demo", 0, "", 0
  snap, fixtureFocus = raw, raw.focus
  ns.demo = true
  ns.state = State.New()
  push()
  heartbeat = heartbeat or Compat.NewTicker(10, function() if ns.demo and snap then push() end end)
  ns.Print("Demo mode on: showing sample threads (no companion). Type /t3 demo again to leave.")
  if ns.UI and ns.UI.OpenChat then ns.UI.OpenChat(fixtureFocus.id) end
end

function DemoMode.Stop()
  if streamTicker then streamTicker:Cancel(); streamTicker = nil end
  ns.demo = false
  snap = nil
  ns.state = State.New()
  ns.selected = nil
  ns.Print("Demo mode off.")
  ns.Fire("model", "demo-off")
  if ns.Inbound then ns.Inbound.Reschedule() end
end

function DemoMode.Toggle()
  if ns.demo then DemoMode.Stop() else DemoMode.Start() end
end
