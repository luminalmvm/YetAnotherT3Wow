-- T3Bridge Outbound: draws the black/white cell matrix at physical pixel (0,0) for a few frames.
-- The companion reads it through Windows.Graphics.Capture, which only reads. No Screenshot(), no
-- input injection. Spec: PROTOCOL.md section 3.
local _, ns = ...
local Compat, Codec = ns.Compat, ns.Codec

local Outbound = {}
ns.Outbound = Outbound

local matrix, backing, driver
local pool = {}
local phase            -- nil | "show" | "hold" | "gap"
local item             -- current outbox item while transmitting
local partIdx, frameCount, tMark = 0, 0, 0
local testJob          -- /t3 spike s2: { frames, rows, cell, holdMs, onDone }

Outbound.geometry = nil

local function ensureMatrix()
  if matrix then return end
  -- No parent: stays visible when the UI is hidden (Alt+Z) and ignores UIParent scale.
  matrix = CreateFrame("Frame", "T3BridgeMatrix", nil)
  matrix:SetFrameStrata("TOOLTIP")
  pcall(matrix.SetFrameLevel, matrix, 9000)
  if matrix.SetIgnoreParentScale then matrix:SetIgnoreParentScale(true) end
  matrix:EnableMouse(false)
  matrix:Hide()
  backing = matrix:CreateTexture(nil, "BACKGROUND")
  backing:SetColorTexture(0, 0, 0, 1)
  backing:SetPoint("TOPLEFT", matrix, "TOPLEFT", 0, 0)
end

--- Make one UI unit equal one physical pixel and pin the frame to the top-left corner.
function Outbound.ApplyGeometry(cell, rows)
  ensureMatrix()
  local w, h, method = Compat.PhysicalScreenSize()
  local scale = 768 / h
  matrix:SetScale(scale)
  matrix:ClearAllPoints()
  matrix:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
  matrix:SetSize(256 * cell, rows * cell)
  backing:SetSize(256 * cell, rows * cell)
  Outbound.geometry = { w = w, h = h, method = method, scale = scale, cell = cell, rows = rows }
  return Outbound.geometry
end

local function drawFrame(frame, rows, cell)
  Outbound.ApplyGeometry(cell, rows)
  local runs = Codec.WhiteRuns(frame, rows)
  for i, run in ipairs(runs) do
    local t = pool[i]
    if not t then
      t = matrix:CreateTexture(nil, "ARTWORK")
      t:SetColorTexture(1, 1, 1, 1)
      pool[i] = t
    end
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", matrix, "TOPLEFT", run[2] * cell, -run[1] * cell)
    t:SetSize(run[3] * cell, cell)
    t:Show()
  end
  for i = #runs + 1, #pool do pool[i]:Hide() end
  matrix:Show()
  frameCount = 0
  phase = "show"
end

local function holdSeconds(ms)
  ms = tonumber(ms) or 200
  if ms < 100 then ms = 100 elseif ms > 5000 then ms = 5000 end
  return ms / 1000
end

local function handle(ev)
  if not ev then return end
  if ev.type == "done" then
    ns.notRespondingAt = nil
    if ev.err then ns.Print("Companion: " .. Compat.Escape(ev.err)) end
    ns.Fire("sent", ev)
  elseif ev.type == "failed" then
    ns.notRespondingAt = ns.Now()
    ns.Debug("command " .. ev.item.kind .. " #" .. ev.item.seq .. " not acknowledged after " .. ev.item.attempts .. " tries")
    ns.Fire("sendFailed", ev.item)
  elseif ev.type == "retransmit" then
    ns.Debug("retransmit " .. ev.item.kind .. " #" .. ev.item.seq .. " (attempt " .. ev.item.attempts .. ")")
  end
  ns.Fire("outbox")
end

local function frameDone(now)
  if testJob then
    local job = testJob
    partIdx = partIdx + 1
    if partIdx <= #job.frames then drawFrame(job.frames[partIdx], job.rows, job.cell); return end
    testJob, phase = nil, nil
    if job.onDone then job.onDone() end
    return
  end
  partIdx = partIdx + 1
  if item and partIdx <= #item.frames then
    drawFrame(item.frames[partIdx], item.rows, ns.db.cell)
    ns.Fire("outbox")
    return
  end
  phase = nil
  local ob = ns.Outbox()
  handle(ob:TransmitDone(now))
  item = nil
  if ns.Inbound then ns.Inbound.Burst(10) end
  ns.Fire("outbox")
end

local function onUpdate(self)
  local now = GetTime()
  if phase == "show" then
    frameCount = frameCount + 1            -- one more frame has rendered since Show()
    if frameCount >= 2 then phase, tMark = "hold", now end
    return
  elseif phase == "hold" then
    local hold = testJob and testJob.hold or holdSeconds(ns.db.hold)
    if now - tMark >= hold then
      matrix:Hide()
      phase, frameCount, tMark = "gap", 0, now
    end
    return
  elseif phase == "gap" then
    frameCount = frameCount + 1
    if frameCount >= 2 and now - tMark >= 0.05 then frameDone(now) end
    return
  end

  -- idle: drive the outbox
  if ns.demo or not ns.inWorld then return end
  local ob = ns.Outbox()
  handle(ob:Update(now))
  local cur = ob.cur or ob:Start(now)
  if cur and cur.state == "sending" then
    item, partIdx = cur, 1
    drawFrame(cur.frames[1], cur.rows, ns.db.cell)
    ns.Fire("outbox")
  elseif not cur then
    self:Hide() -- nothing queued, nothing awaiting an ack
  end
end

local function ensureDriver()
  if driver then return end
  driver = CreateFrame("Frame")
  driver:SetScript("OnUpdate", onUpdate)
  driver:Hide()
end

--- Wake the sender (after Enqueue).
function Outbound.Kick()
  ensureDriver()
  driver:Show()
end

--- {part, parts} while a message is being sent or awaits its ack, else nil.
function Outbound.Progress()
  local ob = ns.outbox
  if not ob or not ob.cur then return nil end
  local n = #ob.cur.frames
  if phase and item == ob.cur then return { math.min(partIdx, n), n } end
  return { n, n }
end

function Outbound.IsBusy() return phase ~= nil end

--- /t3 spike s2: show raw frames (not via the outbox). Refuses while a real send is running.
function Outbound.ShowTest(frames, rows, cell, holdMs, onDone)
  if phase then return false, "busy" end
  ensureDriver()
  testJob = { frames = frames, rows = rows, cell = cell, hold = holdSeconds(holdMs), onDone = onDone }
  partIdx = 1
  drawFrame(frames[1], rows, cell)
  driver:Show()
  return true
end

function Outbound.Matrix()
  ensureMatrix()
  return matrix
end
