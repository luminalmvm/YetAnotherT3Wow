local T = ...

local function fresh() return T.loadAddon({ "Codec.lua", "State.lua", "Demo.lua" }) end
local ns = fresh()
local S = ns.State

local FIXTURE = T.path("protocol/fixtures/live.sample.lua")
local NOW = 1794393000

local function snap(seq, extra)
  local t = { v = 1, sid = "k3f9", seq = seq, ts = NOW, ack = 0, asid = "", threads = {} }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

T.test("fixture loads in a Lua 5.1 sandbox and validates", function()
  local raw, rend = T.loadSnapshot(FIXTURE)
  T.ok(raw, tostring(rend))
  T.eq(rend, raw.seq)
  local s = assert(S.Validate(raw, rend))
  T.eq(#s.threads, 7)
  T.eq(s.focus.id, "a1b2c3d4")
  T.eq(#s.focus.msgs, 40)
  T.eq(s.focus.pending.rid, "req-77")
  T.eq(#s.focus.pending.options, 3)
  T.eq(#s.focus.models, 4)
  -- escapes survived: tab, pipe, backslash, unicode
  local found = { tab = false, pipe = false, bs = false, uni = false, code = false, more = false }
  for _, m in ipairs(s.focus.msgs) do
    if m.more then found.more = true end
    for _, sg in ipairs(m.segs) do
      if sg[1] == "c" then found.code = true end
      if sg[2]:find("\t", 1, true) then found.tab = true end
      if sg[2]:find("|cffff0000", 1, true) then found.pipe = true end
      if sg[2]:find("hunter2\\\\n", 1, true) then found.bs = true end
      if sg[2]:find("\230\151\165\230\156\172", 1, true) then found.uni = true end -- 日本
    end
  end
  for k, v in pairs(found) do T.ok(v, "fixture contains " .. k) end
end)

T.test("Demo.lua is the fixture (generator in sync)", function()
  local raw = T.loadSnapshot(FIXTURE)
  local d, dend = ns.DemoSnapshot()
  T.eq(dend, raw.seq)
  T.eq(#d.threads, #raw.threads)
  T.eq(#d.focus.msgs, #raw.focus.msgs)
  for k, m in ipairs(raw.focus.msgs) do
    for j, sg in ipairs(m.segs) do T.eq(d.focus.msgs[k].segs[j][2], sg[2], "msg " .. m.i) end
  end
end)

T.test("torn file: syntax error is caught by loader (missing)", function()
  local raw, err = T.loadSnapshot(T.path("protocol/fixtures/live.torn.lua"))
  T.eq(raw, nil)
  T.ok(err, "has error")
  local st = S.New()
  T.eq(S.Accept(st, nil, nil, NOW), "missing")
  T.eq(st.snap, nil)
end)

T.test("torn file: table complete but END stale/missing -> torn", function()
  local st = S.New()
  T.eq(S.Accept(st, snap(10), 10, NOW), "accepted")
  -- new table parsed, but the END line never ran (addon nils END before each load)
  T.eq(S.Accept(st, snap(11), nil, NOW), "torn")
  -- or END left over from an older file
  T.eq(S.Accept(st, snap(12), 10, NOW), "torn")
  T.eq(st.snap.seq, 10)
end)

T.test("stale seq rejected, newer accepted, sid change resets", function()
  local st = S.New()
  T.eq(S.Accept(st, snap(5), 5, NOW), "accepted")
  T.eq(S.Accept(st, snap(5), 5, NOW), "stale")
  T.eq(S.Accept(st, snap(4), 4, NOW), "stale")
  T.eq(S.Accept(st, snap(6), 6, NOW), "accepted")
  local s2 = snap(1); s2.sid = "zz99"
  T.eq(S.Accept(st, s2, 1, NOW), "reset")
  T.eq(st.lastSeq, 1)
  T.eq(S.Accept(st, snap(2, { sid = "zz99" }), 2, NOW), "accepted")
end)

T.test("version mismatch rejected", function()
  local st = S.New()
  local s = snap(1); s.v = 2
  T.eq(S.Accept(st, s, 1, NOW), "version")
end)

T.test("malformed fields are dropped, never raise", function()
  local st = S.New()
  local s = snap(1, {
    threads = { "junk", { id = "has space" }, { id = "ok1", title = 42, st = "weird", need = "maybe" },
      { id = "ok1", title = "dup" }, { id = string.rep("x", 70) } },
    focus = { id = "ok1", models = { { id = "m1" }, "x" }, pending = { rid = "r 1" },
      msgs = { { i = 2, r = "?", segs = { { "p", "b" } } }, { i = 1, segs = { { "z", "a" }, { "c" }, 5 } }, { i = -1 }, "x", { i = 2 } } },
    err = { seq = "x" },
  })
  T.eq(S.Accept(st, s, 1, NOW), "accepted")
  local sn = st.snap
  T.eq(#sn.threads, 1)
  T.eq(sn.threads[1].title, "42")
  T.eq(sn.threads[1].st, "idle")
  T.eq(sn.threads[1].need, nil)
  T.eq(sn.focus.pending, nil)
  T.eq(#sn.focus.models, 1)
  T.eq(#sn.focus.msgs, 2)
  T.eq(sn.focus.msgs[1].i, 1)
  T.eq(sn.focus.msgs[1].segs[1][1], "p") -- unknown kind -> p
  T.eq(sn.focus.msgs[2].r, "s")
  T.eq(sn.err, nil)
  -- 31 threads -> capped at 30 (PROTOCOL D15)
  local many = {}
  for k = 1, 31 do many[k] = { id = "t" .. k, st = "running" } end
  T.eq(S.Accept(st, snap(2, { threads = many }), 2, NOW), "accepted")
  T.eq(#st.snap.threads, 30)
end)

T.test("offline after 30s, age", function()
  local st = S.New()
  T.ok(S.IsOffline(st, NOW))
  S.Accept(st, snap(1), 1, NOW)
  T.ok(not S.IsOffline(st, NOW + 30))
  T.ok(S.IsOffline(st, NOW + 31))
  T.eq(S.Age(st, NOW + 2), 2)
end)

T.test("tracker lists every open thread: no 30-min cutoff, opening never hides (Phase 2)", function()
  local st = S.New()
  local raw, rend = T.loadSnapshot(FIXTURE)
  T.eq(S.Accept(st, raw, rend, NOW), "accepted")
  local rows, total, nc = S.TrackerRows(st, NOW)
  -- all 7 threads, idle included: needs(2) + running(1) + completed + failed + stopped + idle
  T.eq(total, 7); T.eq(#rows, 7); T.eq(nc, 0)
  T.eq(rows[1].info.group, "needs"); T.eq(rows[2].info.group, "needs")
  T.eq(rows[3].key, "running")
  T.eq(rows[3].elapsed, "3:12") -- 192 s
  T.eq(rows[1].elapsed, "1:02:05") -- c3d4e5f6, 3725 s (sorted by t0: longest-waiting first)
  T.eq(rows[2].elapsed, "12:34")   -- a1b2c3d4, 754 s
  -- the others keep the companion's order (most recently updated first)
  T.eq(rows[4].t.id, "d4e5f6a7"); T.eq(rows[7].t.id, "a7b8c9d0")
  T.eq(S.Summary(st, NOW), "1 running \194\183 2 needs you \194\183 1 failed")
  local done
  for _, r in ipairs(rows) do if r.key == "completed" then done = r end end
  T.eq(done.elapsed, "18:00") -- frozen: 1500-420 = 1080 s
  -- days later every finished thread is still listed (only settling it in T3 removes it)
  local _, later = S.TrackerRows(st, NOW + 3 * 86400)
  T.eq(later, 7)
  T.eq(S.MarkSeen, nil, "no 'seen' rule any more")
  -- cap
  local capped = S.TrackerRows(st, NOW, 2)
  T.eq(#capped, 2)
  -- zero threads
  local empty = S.New()
  S.Accept(empty, snap(1), 1, NOW)
  T.eq(select(2, S.TrackerRows(empty, NOW)), 0)
  T.eq(S.Summary(empty, NOW), "no open threads")
end)

T.test("collapsed rows: sorted last, counted, auto-expand on needs-you / failure, re-collapsible", function()
  local st = S.New()
  local raw, rend = T.loadSnapshot(FIXTURE)
  S.Accept(st, raw, rend, NOW)
  local col = {}
  local function thread(id) return S.Thread(st, id) end
  S.SetCollapsed(col, thread("b2c3d4e5"), true)   -- running
  S.SetCollapsed(col, thread("d4e5f6a7"), true)   -- completed
  S.SetCollapsed(col, thread("a1b2c3d4"), true)   -- needs approval: collapsed while showing it
  T.eq(col.b2c3d4e5, true); T.eq(col.a1b2c3d4, "approval")
  local rows, total, nc = S.TrackerRows(st, NOW, nil, col)
  T.eq(total, 7); T.eq(nc, 3)
  for k = 1, 4 do T.eq(rows[k].collapsed, false, "expanded first") end
  for k = 5, 7 do T.eq(rows[k].collapsed, true, "collapsed last") end
  T.eq(rows[5].t.id, "a1b2c3d4", "needs-you first within the collapsed part")
  T.ok(S.Summary(st, NOW, col):find("3 collapsed", 1, true), S.Summary(st, NOW, col))
  -- no new attention: nothing expands
  T.eq(S.ApplyAutoExpand(col, st), 0)
  -- the running thread now needs input -> expands by itself
  local function accept(mut)
    local r2 = T.loadSnapshot(FIXTURE)
    r2.seq = st.lastSeq + 1
    mut(r2)
    T.eq(S.Accept(st, r2, r2.seq, NOW), "accepted")
  end
  accept(function(r2) r2.threads[2].need = "input" end)
  T.eq(S.ApplyAutoExpand(col, st), 1)
  T.eq(col.b2c3d4e5, nil, "expanded on needs-you")
  -- the user collapses it again while it still needs input: it stays collapsed
  S.SetCollapsed(col, thread("b2c3d4e5"), true)
  T.eq(S.ApplyAutoExpand(col, st), 0)
  T.eq(col.b2c3d4e5, "input")
  -- input answered (attention over) -> remembered as plain collapsed; a later request expands again
  accept(function(r2) r2.threads[2].need = nil end)
  S.ApplyAutoExpand(col, st)
  T.eq(col.b2c3d4e5, true)
  accept(function(r2) r2.threads[2].need = "input" end)
  T.eq(S.ApplyAutoExpand(col, st), 1)
  T.eq(col.b2c3d4e5, nil)
  -- a collapsed completed thread that fails on its next run expands
  accept(function(r2) r2.threads[4].st = "failed"; r2.threads[4].t1 = NOW end)
  S.ApplyAutoExpand(col, st)
  T.eq(col.d4e5f6a7, nil, "expanded on failure")
  -- saved values are ids -> true or a short state key, never text
  for k, v in pairs(col) do T.ok(S.IsId(k) and (v == true or (type(v) == "string" and #v < 24)), k) end
  -- pruning keeps listed threads
  local big = {}
  for k = 1, 80 do big["gone" .. k] = true end
  big.a1b2c3d4 = true
  S.PruneCollapsed(big, st, 60)
  T.eq(big.gone1, nil); T.eq(big.a1b2c3d4, true)
end)

T.test("focus effort and per-model effort choices (PROTOCOL D14)", function()
  local raw, rend = T.loadSnapshot(FIXTURE)
  local s = assert(S.Validate(raw, rend))
  T.eq(s.focus.effort, "high")
  local opus = s.focus.models[1]
  T.eq(opus.effort.def, "medium")
  T.eq(table.concat(opus.effort.vals, ","), "low,medium,high,xhigh,max,ultrathink")
  T.ok(opus.effort.has.xhigh)
  T.eq(s.focus.models[3].effort.has.xhigh, nil, "Opus 4.5 has no xhigh")
  T.eq(s.focus.models[4].effort, nil, "Haiku 4.5 has no effort option")
  -- malformed: bad ids dropped, unknown default -> first value, wrong types ignored
  local st = S.New()
  S.Accept(st, snap(1, { threads = { { id = "t1" } }, focus = { id = "t1", effort = "bad value", msgs = {},
    models = { { id = "m1", opts = { { id = "effort", vals = { "low", "has space", 7, "low", "high" }, def = "nope" } } },
      { id = "m2", opts = "x" }, { id = "m3", opts = { { id = "other", vals = { "a" } } } } } } }), 1, NOW)
  local f = st.snap.focus
  T.eq(f.effort, nil)
  T.eq(table.concat(f.models[1].effort.vals, ","), "low,high")
  T.eq(f.models[1].effort.def, "low")
  T.eq(f.models[2].effort, nil); T.eq(f.models[3].effort, nil)
end)

T.test("thread groups for dropdown", function()
  local st = S.New()
  local raw, rend = T.loadSnapshot(FIXTURE)
  S.Accept(st, raw, rend, NOW)
  local g = S.ThreadGroups(st)
  T.eq(#g, 3)
  T.eq(g[1].title, "Needs you"); T.eq(#g[1].items, 2)
  T.eq(g[2].title, "Running"); T.eq(#g[2].items, 1)
  T.eq(g[3].title, "Other open threads"); T.eq(#g[3].items, 4)
end)

T.test("format elapsed", function()
  T.eq(S.FormatElapsed(0), "0:00")
  T.eq(S.FormatElapsed(59), "0:59")
  T.eq(S.FormatElapsed(61), "1:01")
  T.eq(S.FormatElapsed(3599), "59:59")
  T.eq(S.FormatElapsed(3600), "1:00:00")
  T.eq(S.FormatElapsed(-5), "0:00")
end)

T.test("message cache merges history pages and resets on focus/sid change", function()
  local st = S.New()
  local function m(i, txt) return { i = i, r = "a", segs = { { "p", txt or ("m" .. i) } } } end
  S.Accept(st, snap(1, { focus = { id = "t1", msgs = { m(50), m(51) } } }), 1, NOW)
  S.Accept(st, snap(2, { focus = { id = "t1", msgs = { m(10), m(11), m(51, "m51 grown") } } }), 2, NOW)
  local list = S.Messages(st, "t1")
  T.eq(#list, 4); T.eq(list[1].i, 10); T.eq(list[4].segs[1][2], "m51 grown")
  T.eq(#S.Messages(st, "other"), 0)
  S.Accept(st, snap(3, { focus = { id = "t2", msgs = { m(1) } } }), 3, NOW)
  T.eq(#S.Messages(st, "t1"), 0)
  T.eq(#S.Messages(st, "t2"), 1)
  local sig1 = S.MessagesSignature(S.Messages(st, "t2"))
  S.Accept(st, snap(4, { focus = { id = "t2", msgs = { m(1, "m1 longer") } } }), 4, NOW)
  T.ok(S.MessagesSignature(S.Messages(st, "t2")) ~= sig1, "signature changes on growth")
end)

T.test("cadence rules", function()
  local c = S.Cadence
  T.eq(c({ now = 0, slotsLeft = 0 }), nil)
  T.eq(c({ now = 0, awaitingAck = true, offline = true }), 1)
  T.eq(c({ now = 5, burstUntil = 10 }), 1)
  T.eq(c({ now = 11, burstUntil = 10, offline = true, chatOpen = true, streaming = true }), 15)
  T.eq(c({ now = 0, chatOpen = true, streaming = true }), 1)
  T.eq(c({ now = 0, chatOpen = false, streaming = true, anyActive = true }), 3)
  T.eq(c({ now = 0 }), 15)
end)

T.test("link status priorities", function()
  local st = S.New()
  S.Accept(st, snap(1), 1, NOW)
  T.eq((S.LinkStatus(st, NOW + 2, { slotsLeft = 400, slotsTotal = 500 })), "Linked \194\183 2s")
  local t, kind, click = S.LinkStatus(st, NOW, { slotsLeft = 40, slotsTotal = 500 })
  T.eq(t, "Link low: click to reload"); T.eq(kind, "warn"); T.eq(click, true)
  T.eq((S.LinkStatus(st, NOW, { slotsLeft = 0, slotsTotal = 500 })), "Link exhausted: click to reload")
  T.eq((S.LinkStatus(st, NOW, { slotsLeft = 400, slotsTotal = 500, sending = { 2, 3 } })), "Sending 2/3")
  T.eq((S.LinkStatus(st, NOW + 40, { slotsLeft = 400, slotsTotal = 500 })), "Companion offline")
  T.eq((S.LinkStatus(st, NOW, { slotsLeft = 400, slotsTotal = 500, notRespondingAt = NOW - 5 })), "Companion not responding")
  T.eq((S.LinkStatus(st, NOW, { demo = true })), "Demo mode (no companion)")
end)

---------------------------------------------------------------------------------------------
-- Outbox
---------------------------------------------------------------------------------------------
local function rndSeq(vals) local k = 0; return function() k = k + 1; return vals[(k - 1) % #vals + 1] end end

T.test("outbox: send -> wait -> ack -> done", function()
  local ob = S.NewOutbox({ rnd = rndSeq({ 0x9f, 0x3a, 0x01, 0xc2 }) })
  T.eq(ob:SidHex(), "9f3a01c2")
  ob:Enqueue("send", { "a1b2c3d4", "hi there" })
  local cur = ob:Start(100)
  T.eq(cur.seq, 1); T.eq(cur.state, "sending"); T.eq(cur.clientMsgId, "9f3a01c2-1")
  T.eq(cur.payload, "send\ta1b2c3d4\t9f3a01c2-1\thi there")
  T.eq(#cur.frames, 1); T.eq(cur.rows, 8)
  T.eq(ob:TransmitDone(100.5), nil)
  T.eq(cur.state, "wait")
  T.eq(ob:OnSnapshot({ asid = "9f3a01c2", ack = 0 }, 101), nil)
  T.eq(ob:OnSnapshot({ asid = "00000000", ack = 5 }, 101), nil) -- other session's ack ignored
  local ev = ob:OnSnapshot({ asid = "9f3a01c2", ack = 1 }, 101)
  T.eq(ev.type, "done"); T.eq(ob:Busy(), false)
end)

T.test("outbox: 3 retransmits then failed; retransmit sets flag bit", function()
  local ob = S.NewOutbox({ rnd = rndSeq({ 1, 2, 3, 4 }) })
  ob:Enqueue("intr", { "t1" })
  ob:Start(0)
  ob:TransmitDone(0)
  T.eq(ob:Update(2.9), nil)
  for attempt = 2, 4 do
    local ev = ob:Update(3 * (attempt - 1) + 0.01)
    T.eq(ev and ev.type, "retransmit", "attempt " .. attempt)
    T.eq(ev.item.attempts, attempt)
    T.eq(ev.item.frames[1]:byte(4), 1, "flags bit0 on retransmit")
    ob:TransmitDone(3 * (attempt - 1) + 0.01)
  end
  local ev = ob:Update(100)
  T.eq(ev.type, "failed"); T.eq(ob:Busy(), false)
end)

T.test("outbox: ack during transmission completes on TransmitDone; err counts as done", function()
  local ob = S.NewOutbox({ rnd = rndSeq({ 1, 2, 3, 4 }) })
  ob:Enqueue("focus", { "t1" })
  ob:Start(0)
  T.eq(ob:OnSnapshot({ asid = ob:SidHex(), ack = 1 }, 0.1), nil)
  local ev = ob:TransmitDone(0.2)
  T.eq(ev.type, "done")
  ob:Enqueue("model", { "t1", "m2" })
  ob:Start(1); ob:TransmitDone(1)
  ev = ob:OnSnapshot({ asid = ob:SidHex(), ack = 1, err = { seq = 2, text = "unknown model" } }, 2)
  T.eq(ev.type, "done"); T.eq(ev.err, "unknown model")
end)

T.test("outbox: focus/model coalesce, hello jumps the queue, seq increments", function()
  local ob = S.NewOutbox({ rnd = rndSeq({ 1, 2, 3, 4 }) })
  ob:Enqueue("focus", { "t1" })
  ob:Enqueue("model", { "t1", "a" })
  ob:Enqueue("focus", { "t2" })
  ob:Enqueue("model", { "t1", "b" })
  ob:Enqueue("model", { "t2", "c" })
  ob:Enqueue("hello", { "1" })
  T.eq(#ob.queue, 4)
  T.eq(ob.queue[1].kind, "hello")
  T.eq(ob.queue[2].kind, "focus"); T.eq(ob.queue[2].args[1], "t2")
  T.eq(ob.queue[3].args[2], "b")
  local a = ob:Start(0); T.eq(a.seq, 1)
  ob:OnSnapshot({ asid = ob:SidHex(), ack = 1 }, 0); ob:TransmitDone(0)
  local b = ob:Start(0); T.eq(b.seq, 2)
end)

T.test("outbox: seq wrap rotates sid", function()
  local ob = S.NewOutbox({ rnd = rndSeq({ 1, 2, 3, 4, 9, 9, 9, 9 }) })
  ob.nextSeq = 65536
  ob.helloSent = true
  local old = ob:SidHex()
  ob:Enqueue("intr", { "t" })
  local c = ob:Start(0)
  T.eq(c.seq, 1); T.ok(ob:SidHex() ~= old); T.eq(ob.helloSent, false)
end)

T.test("outbox: 4000-byte send becomes 5 long frames", function()
  local ob = S.NewOutbox({ rnd = rndSeq({ 1, 2, 3, 4 }) })
  ob:Enqueue("send", { "a1b2c3d4", string.rep("x", 4000) })
  local c = ob:Start(0)
  T.eq(c.rows, 32); T.eq(#c.frames, 5)
end)

---------------------------------------------------------------------------------------------
-- Images (PROTOCOL rev 1.3)
---------------------------------------------------------------------------------------------
T.test("img segments: parsed with slot/size, malformed values dropped, text fallback kept", function()
  local s = assert(S.Validate(snap(1, { focus = { id = "a1", msgs = { { i = 1, r = "u", ts = NOW, segs = {
    { "p", "look" },
    { "img", "[image: red.png]", s = 3, w = 320, h = 180, alt = "red.png", aid = "abcd1234" },
    { "img", "[image: x.png]", s = 0, st = "full", alt = "x.png" },
    { "img", nil, s = 5, w = 9999, h = 10, alt = "big.png" },          -- size out of range: no slot
    { "img", "[image: y]", s = "7", w = 10, h = 10, st = "weird" },     -- slot must be a number
  } } } } }), 1))
  local segs = s.focus.msgs[1].segs
  T.eq(#segs, 5)
  T.eq(segs[1][1], "p")
  T.eq(segs[2][1], "img"); T.eq(segs[2][2], "[image: red.png]")
  T.eq(segs[2].img.s, 3); T.eq(segs[2].img.w, 320); T.eq(segs[2].img.h, 180); T.eq(segs[2].img.alt, "red.png"); T.eq(segs[2].img.st, nil)
  T.eq(segs[3].img.s, 0); T.eq(segs[3].img.st, "full")
  T.eq(segs[4].img.s, 0, "oversize -> no slot"); T.eq(segs[4][2], "[image: big.png]", "fallback text built")
  T.eq(segs[5].img.s, 0); T.eq(segs[5].img.st, "load", "unknown state -> load")
end)

T.test("an addon that predates rev 1.3 would render the img text fallback (kind ~= c -> p)", function()
  local seg = { "img", "[image: red.png]", s = 3 }
  T.eq(seg[1] == "c" and "c" or "p", "p")
  T.eq(seg[2], "[image: red.png]")
end)

T.test("staged, notice and imgslots are parsed; signature changes when a slot is filled", function()
  local raw = snap(2, { imgslots = { left = 7, total = 100, reset = "reload" }, focus = { id = "a1", notice = "No image on the clipboard", nid = 4,
    staged = { { aid = "k1", s = 4, w = 64, h = 32, name = "clip-1.png" }, { aid = "bad aid!", s = 1 }, { aid = "k2", s = 0, name = "x.png" } },
    msgs = { { i = 1, r = "u", segs = { { "img", "[image: a]", s = 0, st = "load" } } } } } })
  local s = assert(S.Validate(raw, 2))
  T.eq(s.imgslots.left, 7); T.eq(s.imgslots.total, 100); T.eq(s.imgslots.reset, "reload")
  T.eq(#s.focus.staged, 2, "invalid aid dropped")
  T.eq(s.focus.staged[1].alt, "clip-1.png"); T.eq(s.focus.staged[1].s, 4)
  T.eq(s.focus.staged[2].s, 0)
  T.eq(s.focus.notice, "No image on the clipboard"); T.eq(s.focus.nid, 4)
  local sig1 = S.MessagesSignature(s.focus.msgs)
  raw.focus.msgs[1].segs[1] = { "img", "[image: a]", s = 9, w = 10, h = 10 }
  local s2 = assert(S.Validate(raw, 2))
  T.ok(S.MessagesSignature(s2.focus.msgs) ~= sig1, "relayout when the image becomes ready")
  T.eq(S.Validate(snap(3, { imgslots = { total = "x" } }), 3).imgslots, nil)
end)

local function eqList(got, want, msg)
  T.eq(#got, #want, msg)
  for k = 1, #want do T.eq(got[k], want[k], (msg or "") .. " [" .. k .. "]") end
end

T.test("image size, texture coordinates and placeholder texts", function()
  eqList({ S.ImageSize(512, 256, 240, 160) }, { 240, 120 })
  eqList({ S.ImageSize(100, 300, 240, 160) }, { 53, 160 })
  eqList({ S.ImageSize(50, 20, 240, 160) }, { 50, 20 }, "never upscaled")
  eqList({ S.ImageTexCoords(320, 180) }, { 0, 0.625, 0, 180 / 512 })
  T.ok(S.ImagePlaceholder({ st = "full" }, "restart"):find("restart WoW"))
  T.ok(S.ImagePlaceholder({ st = "full" }, "reload"):find("/reload"))
  T.eq(S.ImagePlaceholder({ st = "load" }), "Loading image...")
  T.eq(S.ImagePlaceholder({ st = "off", alt = "a.png" }), "[image: a.png]")
end)

T.test("status line: 'Images: N left' below 20 slots, notice wins for a moment", function()
  local st = S.New()
  S.Accept(st, snap(10, { imgslots = { left = 12, total = 100 } }), 10, NOW)
  local text = S.LinkStatus(st, NOW, { slotsLeft = 100, slotsTotal = 200 })
  T.ok(text:find("Images: 12 left"), text)
  S.Accept(st, snap(11, { imgslots = { left = 50, total = 100 } }), 11, NOW)
  T.ok(not S.LinkStatus(st, NOW, { slotsLeft = 100, slotsTotal = 200 }):find("Images"))
  T.eq(S.LinkStatus(st, NOW, { slotsLeft = 100, slotsTotal = 200, notice = "No image on the clipboard" }), "No image on the clipboard")
end)

---------------------------------------------------------------------------------------------
-- rev 1.4: subagent threads
---------------------------------------------------------------------------------------------
T.test("subagents (rev 1.4): fixture subs, focus.kids, thread links", function()
  local raw, rend = T.loadSnapshot(FIXTURE)
  local s = assert(S.Validate(raw, rend))
  T.eq(#s.threads, 7, "subagents are not top-level rows")
  T.eq(#s.subs, 5)
  T.eq(s.threads[2].kids, 3); T.eq(s.threads[2].kidsRunning, 1); T.eq(s.threads[1].kids, 2)
  T.eq(s.subs[1].parent, "b2c3d4e5")
  T.eq(#s.focus.kids, 2); T.eq(s.focus.nkids, 2); T.eq(s.focus.kids[1].parent, "a1b2c3d4")
  local links = {}
  for _, m in ipairs(s.focus.msgs) do
    for _, sg in ipairs(m.segs) do if sg[1] == "tl" then links[#links + 1] = sg end end
  end
  T.eq(#links, 2, "two thread links")
  T.eq(links[1].id, "c2d3e4f5")
  T.ok(links[1][2]:find("^Delegated task"), links[1][2])
end)

T.test("subagents: a thread with parent moves to subs; bad fields are dropped", function()
  local raw = snap(1, {
    threads = {
      { id = "p1", title = "Parent", st = "completed", kids = 2, kidsRunning = 1, kidsNeed = -3 },
      { id = "c1", title = "Child", st = "running", parent = "p1" },
      { id = "self", title = "Loop", st = "idle", parent = "self" },
    },
    subs = {
      { id = "c2", title = "Child 2", st = "completed", parent = "p1" },
      { id = "c1", title = "dup", st = "idle", parent = "p1" },
      { id = "x", title = "no parent", st = "idle" },
    },
    focus = { id = "c1", parent = { id = "p1", title = "Parent" },
      path = { { id = "p1", title = "Parent" }, { id = "c1", title = "Child" } },
      kids = { { id = "g1", title = "Grandchild", st = "running" }, { id = "c1", title = "itself" } }, nkids = 1,
      msgs = { { i = 1, r = "s", segs = { { "tl", "Open", id = "g1" }, { "tl", "bad id", id = "a b" }, { "tl", "", id = "g1" } } } } },
  })
  local s = assert(S.Validate(raw, 1))
  T.eq(#s.threads, 2, "p1 and the self-parented thread (parent dropped)")
  T.eq(s.threads[2].parent, nil)
  T.eq(s.threads[1].kidsNeed, nil, "negative count dropped")
  T.eq(#s.subs, 2); T.eq(s.subs[1].id, "c1"); T.eq(s.subs[2].id, "c2")
  T.eq(#s.focus.kids, 1, "the focused thread is not its own kid")
  T.eq(s.focus.kids[1].parent, "c1")
  T.eq(s.focus.parent.id, "p1")
  T.eq(#s.focus.path, 2)
  local segs = s.focus.msgs[1].segs
  T.eq(segs[1][1], "tl"); T.eq(segs[1].id, "g1")
  T.eq(segs[2][1], "p", "a link with a bad id renders as text")
  T.eq(#segs, 2, "empty link dropped")
  -- a breadcrumb that does not end at the focused thread is ignored
  local bad = snap(2, { focus = { id = "c1", path = { { id = "p1", title = "P" }, { id = "zz", title = "Z" } }, msgs = {} } })
  T.eq(S.Validate(bad, 2).focus.path, nil)
end)

T.test("subagents: Thread, ParentOf, Kids, Path, KidCounts, KidsLabel", function()
  local st = S.New()
  S.Accept(st, snap(1, {
    threads = { { id = "p1", title = "Parent", st = "completed", kids = 3 }, { id = "c1", title = "Child", st = "running", parent = "p1" } },
    subs = { { id = "c2", title = "Child 2", st = "completed", parent = "p1", need = "input" }, { id = "g1", title = "Grand", st = "idle", parent = "c1" } },
    focus = { id = "c1", parent = { id = "p1", title = "Parent" }, path = { { id = "p1", title = "Parent" }, { id = "c1", title = "Child" } },
      kids = { { id = "g1", title = "Grand", st = "running" }, { id = "g2", title = "Grand 2", st = "completed" } }, nkids = 5, msgs = {} },
  }), 1, NOW)
  T.eq(S.Thread(st, "c1").parent, "p1")
  T.eq(S.Thread(st, "g2").title, "Grand 2", "found through focus.kids")
  T.eq(S.ParentOf(st, "c1"), "p1"); T.eq(S.ParentOf(st, "p1"), nil); T.eq(S.ParentOf(st, "g1"), "c1")
  local kids, total = S.Kids(st, "c1")
  T.eq(#kids, 2); T.eq(total, 5, "focus.nkids")
  kids, total = S.Kids(st, "p1")
  T.eq(#kids, 2, "subs naming p1 (c1 from threads moved to subs, c2)"); T.eq(total, 3, "the row's kids count")
  local path = S.Path(st, "c1")
  T.eq(#path, 2); T.eq(path[1].id, "p1")
  path = S.Path(st, "g1")
  T.eq(#path, 3, "walked up through parent links"); T.eq(path[3].id, "g1")
  local n = S.KidCounts(S.Kids(st, "p1"))
  T.eq(n.running, 1); T.eq(n.needs, 1)
  T.eq(S.KidsLabel(3, 1, 1), "Subagents (3" .. S.DOT .. "1 running" .. S.DOT .. "1 needs you)")
  T.eq(S.KidsLabel(2, 0, 0), "Subagents (2)")
end)

T.test("subagents: parent links are remembered across snapshots and companion restarts", function()
  local st = S.New()
  S.Accept(st, snap(1, {
    threads = { { id = "p1", title = "Parent", st = "completed" }, { id = "c1", title = "Child", st = "idle", parent = "p1" } },
    focus = { id = "c1", parent = { id = "p1", title = "Parent" }, path = { { id = "p1", title = "Parent" }, { id = "c1", title = "Child" } }, msgs = {} },
  }), 1, NOW)
  -- a new companion (new sid) that does not list c1 yet
  S.Accept(st, { v = 1, sid = "new1", seq = 1, ts = NOW, ack = 0, asid = "", threads = { { id = "p1", title = "Parent", st = "completed" } } }, 1, NOW)
  T.eq(S.Thread(st, "c1"), nil)
  T.eq(S.ParentOf(st, "c1"), "p1", "remembered parent")
  local path = S.Path(st, "c1")
  T.eq(#path, 2); T.eq(path[1].id, "p1"); T.eq(path[2].title, "Child")
  T.ok(S.Known(st, "c1"))
  T.eq(S.ParentOf(st, "p1"), nil, "top-level stays top-level")
end)

T.test("subagents: thread menu indents kids, tracker rows stay top-level, attention and cadence", function()
  local st = S.New()
  S.Accept(st, snap(1, {
    threads = { { id = "p1", title = "Parent", st = "completed", kids = 2, kidsRunning = 1 }, { id = "q1", title = "Other", st = "idle" } },
    subs = { { id = "c1", title = "Child", st = "running", parent = "p1" }, { id = "c2", title = "Child 2", st = "completed", parent = "p1" },
      { id = "g1", title = "Grand", st = "idle", parent = "c1" } },
  }), 1, NOW)
  local rows, total = S.TrackerRows(st, NOW, nil, {})
  T.eq(total, 2, "only top-level rows")
  for _, r in ipairs(rows) do T.ok(not r.t.parent) end
  local menu = S.ThreadMenu(st)
  local flat = {}
  for _, g in ipairs(menu) do for _, it in ipairs(g.items) do flat[#flat + 1] = it.t.id .. ":" .. it.depth end end
  T.eq(table.concat(flat, ","), "p1:0,c1:1,g1:2,c2:1,q1:0")
  T.ok(S.AnyActive(st), "a running subagent keeps the 3 s cadence")
  -- a subagent needing you: the parent's attention signature changes, a collapsed row expands
  local collapsed = {}
  S.SetCollapsed(collapsed, S.Thread(st, "p1"), true)
  S.Accept(st, snap(2, { threads = { { id = "p1", title = "Parent", st = "completed", kids = 2, kidsNeed = 1 } } }), 2, NOW)
  T.ok(S.AnyNeedsYou(st))
  T.eq(S.ApplyAutoExpand(collapsed, st), 1)
  T.eq(collapsed.p1, nil)
end)
