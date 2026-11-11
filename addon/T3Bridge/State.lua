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
State.MAX_SUBS = 64           -- subagent rows (rev 1.4: subs + subagents listed in threads)
State.MAX_KIDS = 20           -- focus.kids (rev 1.4)
State.MAX_PATH = 4            -- focus.path (rev 1.4)
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

State.IMG_CANVAS = 512   -- image slot textures are 512x512 (PROTOCOL rev 1.3, D16)
local IMG_ST = { load = true, full = true, off = true, err = true, old = true }

--- Image fields of an "img" segment or a staged item: { s, w, h, alt, aid, st }. s = slot (0 = none).
local function normImg(s)
  local slot = int(s.s)
  if not slot or slot < 0 or slot > 9999 then slot = 0 end
  local w, h = int(s.w), int(s.h)
  if not (w and h and w >= 1 and h >= 1 and w <= State.IMG_CANVAS and h <= State.IMG_CANVAS) then w, h = nil, nil end
  if slot > 0 and not w then slot = 0 end
  local aid = (type(s.aid) == "string" and s.aid:find("^[%w_-]+$") and #s.aid <= 16) and s.aid or nil
  return { s = slot, w = w, h = h, alt = str(s.alt or s.name, 64) or "image", aid = aid,
    st = (slot == 0) and (IMG_ST[s.st] and s.st or "load") or nil }
end
State.NormImage = normImg

local function normMsg(m)
  if type(m) ~= "table" then return nil end
  local i = int(m.i)
  if not i or i < 1 then return nil end
  local segs = {}
  local total = 0
  local imgsig = ""
  if type(m.segs) == "table" then
    for _, s in ipairs(m.segs) do
      if type(s) == "table" then
        local text = str(s[2])
        if s[1] == "img" then
          -- { "img", "[image: name]", s=, w=, h=, alt=, aid=, st= } (rev 1.3). [2] is the 1.2 text fallback.
          if #segs < 40 then
            local img = normImg(s)
            segs[#segs + 1] = { "img", text or ("[image: " .. img.alt .. "]"), img = img }
            imgsig = imgsig .. img.s .. (img.st or "") .. ","
          end
        elseif s[1] == "tl" and text and text ~= "" and isId(s.id) then
          -- { "tl", "<label>", id="<tid>" } (rev 1.4): a link to another thread (a subagent, a t3-thread link).
          segs[#segs + 1] = { "tl", str(text, 200), id = s.id }
          total = total + #text
        elseif text and text ~= "" then
          local kind = (s[1] == "c") and "c" or "p"
          segs[#segs + 1] = { kind, text }
          total = total + #text
        end
      end
    end
  end
  return {
    i = i, r = ROLES[m.r] and m.r or "s", ts = int(m.ts), segs = segs, more = (m.more == true),
    size = total, imgsig = imgsig,
  }
end

local function count(v)
  local n = int(v)
  if n and n > 0 then return math.min(n, 9999) end
  return nil
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
    -- rev 1.4: subagent threads name their parent; parents count their subagents.
    parent = (isId(t.parent) and t.parent ~= t.id) and t.parent or nil,
    kids = count(t.kids), kidsRunning = count(t.kidsRunning), kidsNeed = count(t.kidsNeed),
  }
end
State.NormThread = normThread

--- { id=, title= } reference (focus.parent, focus.path entries).
local function normRef(r)
  if type(r) ~= "table" or not isId(r.id) then return nil end
  return { id = r.id, title = str(r.title, 120) or r.id }
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
  -- Optional (rev 1.3, D17/D18): staged attachments and a short notice for the focused thread.
  if type(f.staged) == "table" then
    out.staged = {}
    for _, s in ipairs(f.staged) do
      if type(s) == "table" and #out.staged < 4 then
        local img = normImg(s)
        if img.aid then out.staged[#out.staged + 1] = img end
      end
    end
  end
  if type(f.notice) == "string" and f.notice ~= "" then
    out.notice = str(f.notice, 200)
    out.nid = int(f.nid) or 0
  end
  -- Optional (rev 1.4): the focused thread's parent, subagents and breadcrumb (root -> focused).
  out.parent = normRef(f.parent)
  if out.parent and out.parent.id == out.id then out.parent = nil end
  if type(f.kids) == "table" then
    out.kids = {}
    local seen = {}
    for _, k in ipairs(f.kids) do
      local nk = normThread(k)
      if nk and not seen[nk.id] and nk.id ~= out.id and #out.kids < State.MAX_KIDS then
        seen[nk.id] = true
        nk.parent = out.id
        out.kids[#out.kids + 1] = nk
      end
    end
    out.nkids = math.max(#out.kids, int(f.nkids) or 0)
    if #out.kids == 0 then out.kids, out.nkids = nil, nil end
  end
  if type(f.path) == "table" then
    local path = {}
    for _, r in ipairs(f.path) do
      local nr = normRef(r)
      if nr and #path < State.MAX_PATH then path[#path + 1] = nr end
    end
    if #path >= 2 and path[#path].id == out.id then out.path = path end
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
  -- threads: top-level rows. A thread with `parent` (rev 1.4: the focused subagent and its ancestors)
  -- goes to subs with the subagent rows of `raw.subs`, so it never becomes a top-level tracker row.
  snap.subs = {}
  local seen = {}
  local function addSub(nt)
    if nt and nt.parent and not seen[nt.id] and #snap.subs < State.MAX_SUBS then
      seen[nt.id] = true
      snap.subs[#snap.subs + 1] = nt
    end
  end
  if type(raw.threads) == "table" then
    for _, t in ipairs(raw.threads) do
      local nt = normThread(t)
      if nt and nt.parent then
        addSub(nt)
      elseif nt and not seen[nt.id] and #snap.threads < State.MAX_THREADS then
        seen[nt.id] = true
        snap.threads[#snap.threads + 1] = nt
      end
    end
  end
  if type(raw.subs) == "table" then
    for _, t in ipairs(raw.subs) do addSub(normThread(t)) end
  end
  snap.focus = normFocus(raw.focus)
  -- Optional (rev 1.3, D16): image slots left/total and what frees them.
  if type(raw.imgslots) == "table" and int(raw.imgslots.total) then
    local total = math.max(0, int(raw.imgslots.total))
    snap.imgslots = { total = total, left = math.max(0, math.min(total, int(raw.imgslots.left) or 0)),
      reset = (raw.imgslots.reset == "reload") and "reload" or "restart" }
  end
  return snap
end

---------------------------------------------------------------------------------------------
-- Model
---------------------------------------------------------------------------------------------
function State.New()
  return { lastSid = nil, lastSeq = 0, snap = nil, acceptedAt = nil, cache = { tid = nil, byI = {}, n = 0 },
    known = {}, knownN = 0,
    stats = { accepted = 0, stale = 0, torn = 0, missing = 0, version = 0, reset = 0 } }
end

--- rev 1.4: titles and parent links seen in any snapshot of this UI session (kept across companion
--- restarts), so Up and the breadcrumb still work for a subagent the current snapshot does not list.
--- known[tid] = { title, parent = <tid> | false (top-level) }. In memory only; capped at 400 entries.
local function remember(st, snap)
  local k = st.known
  if not k or (st.knownN or 0) > 400 then k = {}; st.known = k; st.knownN = 0 end
  local function put(id, title, parent)
    local e = k[id]
    if not e then e = {}; k[id] = e; st.knownN = st.knownN + 1 end
    if title then e.title = title end
    if parent ~= nil then e.parent = parent end
  end
  for _, t in ipairs(snap.threads) do put(t.id, t.title, false) end
  for _, t in ipairs(snap.subs or {}) do put(t.id, t.title, t.parent) end
  local f = snap.focus
  if f then
    if f.parent then put(f.parent.id, f.parent.title, nil); put(f.id, nil, f.parent.id) end
    for _, t in ipairs(f.kids or {}) do put(t.id, t.title, f.id) end
    for i, r in ipairs(f.path or {}) do put(r.id, r.title, i > 1 and f.path[i - 1].id or nil) end
  end
end

--- A thread seen in an earlier snapshot of this session (rev 1.4), or nil.
function State.Known(st, tid) return st.known and tid and st.known[tid] or nil end

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
  remember(st, snap)
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

--- A listed thread: a top-level row, a subagent row (rev 1.4), or a subagent / ancestor named only by
--- the focused thread's kids or breadcrumb (then only id, title and, for kids, the run state are known).
function State.Thread(st, tid)
  local snap = st.snap
  if not snap or not tid then return nil end
  for _, t in ipairs(snap.threads) do if t.id == tid then return t end end
  for _, t in ipairs(snap.subs or {}) do if t.id == tid then return t end end
  local f = snap.focus
  if f then
    for _, t in ipairs(f.kids or {}) do if t.id == tid then return t end end
    if f.parent and f.parent.id == tid then return { id = tid, title = f.parent.title, st = "idle", ref = true } end
    for k, r in ipairs(f.path or {}) do
      if r.id == tid then return { id = tid, title = r.title, st = "idle", ref = true, parent = k > 1 and f.path[k - 1].id or nil } end
    end
  end
  return nil
end

--- Parent tid of a thread (rev 1.4), or nil for a top-level thread.
function State.ParentOf(st, tid)
  local f = st.snap and st.snap.focus
  if f and f.id == tid and f.parent then return f.parent.id end
  local t = State.Thread(st, tid)
  if t then return t.parent end
  local k = State.Known(st, tid)
  return k and k.parent or nil
end

--- Subagents of a thread: focus.kids when it is the focused thread (complete, up to 20), else the
--- subagent rows naming it as parent. Returns list, total (focus.nkids or the row's kids count).
function State.Kids(st, tid)
  local snap = st.snap
  if not snap or not tid then return {}, 0 end
  local f = snap.focus
  if f and f.id == tid and f.kids then return f.kids, f.nkids or #f.kids end
  local out = {}
  for _, t in ipairs(snap.subs or {}) do if t.parent == tid then out[#out + 1] = t end end
  local row = State.Thread(st, tid)
  return out, math.max(#out, row and row.kids or 0)
end

--- Breadcrumb root -> tid: focus.path when tid is focused, else walked up through parent links.
function State.Path(st, tid)
  local f = st.snap and st.snap.focus
  if f and f.id == tid and f.path then return f.path end
  local path, seen, cur = {}, {}, tid
  while cur and not seen[cur] and #path < 8 do
    seen[cur] = true
    local t = State.Thread(st, cur)
    local k = (not t) and State.Known(st, cur) or nil
    if not t and not (k and k.title) then break end
    table.insert(path, 1, { id = cur, title = t and t.title or k.title })
    cur = t and t.parent or (k and k.parent) or nil
  end
  while #path > State.MAX_PATH do table.remove(path, 2) end
  return path
end

--- Counts for a subagent list: total, running, needs you.
function State.KidCounts(list)
  local n = { total = #list, running = 0, needs = 0 }
  for _, t in ipairs(list) do
    if t.need then n.needs = n.needs + 1 elseif t.st == "running" then n.running = n.running + 1 end
  end
  return n
end

--- "Subagents (3 · 1 running · 1 needs you)" for the chat strip and the tracker badge tooltip.
function State.KidsLabel(total, running, needs)
  local p = { tostring(total) }
  if (running or 0) > 0 then p[#p + 1] = running .. " running" end
  if (needs or 0) > 0 then p[#p + 1] = needs .. " needs you" end
  return "Subagents (" .. table.concat(p, State.DOT) .. ")"
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
    parts[k] = m.i .. ":" .. m.size .. ":" .. #m.segs .. ":" .. (last and last[2]:sub(-8) or "") .. (m.more and "+" or "") .. (m.imgsig or "")
  end
  return table.concat(parts, "|")
end

---------------------------------------------------------------------------------------------
-- Images (rev 1.3): display size, texture coordinates and placeholder text
---------------------------------------------------------------------------------------------
--- Fit w x h inside maxW x maxH keeping the aspect ratio, never upscaling (same rule as the companion's displaySize).
function State.ImageSize(w, h, maxW, maxH)
  if not (w and h and w > 0 and h > 0) then return maxW, maxH end
  local s = math.min(1, maxW / w, maxH / h)
  return math.max(1, floor(w * s + 0.5)), math.max(1, floor(h * s + 0.5))
end

--- Texture coordinates (left, right, top, bottom) of an image placed at the top-left of a slot texture.
function State.ImageTexCoords(w, h)
  return 0, w / State.IMG_CANVAS, 0, h / State.IMG_CANVAS
end

--- Text for an image without a slot. reset = "reload" | "restart" (what frees slots).
function State.ImagePlaceholder(img, reset)
  local st = img and img.st
  if st == "full" then
    return "No image slots left: " .. ((reset == "reload") and "/reload" or "restart WoW") .. " to free them"
  elseif st == "err" then return "Image could not be loaded"
  elseif st == "old" then return "Image (older message, open T3 Code to view)"
  elseif st == "off" then return "[image: " .. (img.alt or "image") .. "]"
  end
  return "Loading image..."
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
  if (t.kidsNeed or 0) > 0 then return "kids:need" end -- rev 1.4: a subagent needs you
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
  for _, t in ipairs(st.snap.threads) do if t.need or (t.kidsNeed or 0) > 0 then return true end end
  return false
end

function State.AnyActive(st)
  if not st.snap then return false end
  for _, t in ipairs(st.snap.threads) do
    if t.need or t.st == "running" or (t.kidsRunning or 0) > 0 or (t.kidsNeed or 0) > 0 then return true end
  end
  for _, t in ipairs(st.snap.subs or {}) do if t.need or t.st == "running" then return true end end
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

--- Thread menu (rev 1.4): ThreadGroups with each thread's subagents listed under it.
--- Returns groups { title, items = { { t = thread, depth = 0|1|2 }, ... } }. Subagents come from the
--- subagent rows (and the focused thread's kids); depth is capped at 2, each list at maxKids per parent.
function State.ThreadMenu(st, maxKids)
  maxKids = maxKids or 8
  local groups = State.ThreadGroups(st)
  local out = {}
  for _, g in ipairs(groups) do
    local items, seen = {}, {}
    local function add(t, depth)
      if seen[t.id] then return end
      seen[t.id] = true
      items[#items + 1] = { t = t, depth = depth }
      if depth >= 2 then return end
      local kids = State.Kids(st, t.id)
      for k = 1, math.min(#kids, maxKids) do add(kids[k], depth + 1) end
    end
    for _, t in ipairs(g.items) do add(t, 0) end
    out[#out + 1] = { title = g.title, items = items }
  end
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
  if e.notice then return e.notice, "warn", false end
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
  local slots = st.snap and st.snap.imgslots
  if slots and slots.total > 0 and slots.left < 20 then
    return "Linked" .. State.DOT .. State.Age(st, now) .. "s" .. State.DOT .. "Images: " .. slots.left .. " left", "ok", false
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
