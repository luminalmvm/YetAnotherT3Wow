-- End-to-end smoke test of the whole addon against wow_mock.lua. Run once per config
-- (SMOKE_CONFIG = "modern" | "legacy") in a fresh Lua state by run_tests.py.
local T = ...
local CONFIG = SMOKE_CONFIG or "modern"
local TMP = T3TEST_TMP or "."
local M = assert(loadfile(T.path("addon/T3Bridge/test/wow_mock.lua")))()

local MODERN = { "PortraitFrameTemplate", "BasicFrameTemplateWithInset", "InsetFrameTemplate", "ScrollFrameTemplate",
  "UIPanelScrollFrameTemplate", "InputScrollFrameTemplate", "T3BridgeInputScrollTemplate", "UIPanelButtonTemplate",
  "UIPanelCloseButton", "WowStyle1DropdownTemplate", "UIDropDownMenuTemplate" }
local LEGACY = { "UIPanelScrollFrameTemplate", "UIPanelButtonTemplate", "UIPanelCloseButton", "UIDropDownMenuTemplate" }

if CONFIG == "modern" then
  M.install({ templates = MODERN, compartment = true })
else
  M.install({ templates = LEGACY, noXMLUtil = true, noPhysical = true, noBackdrop = true })
end

-- The user's client: "/t3 spike fonts" + Enter did nothing. Reproduce a client where the bundled
-- font does not load (legacy config) so the fonts spike runs on a probe FontString without a font.
local MONO = "Interface\\AddOns\\T3Bridge\\Media\\mono.ttf"
if CONFIG == "legacy" then M.brokenFonts[MONO] = true end

---------------------------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------------------------
local LIVE = TMP .. "/smoke_live_" .. CONFIG .. ".lua"
local SPIKE = TMP .. "/smoke_spike_" .. CONFIG .. ".lua"

local function ser(v)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t ~= "table" then return "nil" end
  local parts = {}
  for k = 1, #v do parts[#parts + 1] = ser(v[k]) end
  for k, x in pairs(v) do
    if type(k) == "string" then parts[#parts + 1] = k .. "=" .. ser(x) end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function writeFile(path, text)
  local f = assert(io.open(path, "wb")); f:write(text); f:close()
end

local fixture = T.loadSnapshot(T.path("protocol/fixtures/live.sample.lua"))
local seq = 5000 -- must exceed the inbox fixture seq (4812): same companion sid
local function writeLive(mut)
  seq = seq + 1
  local s = T.loadSnapshot(T.path("protocol/fixtures/live.sample.lua"))
  s.seq, s.ts, s.asid, s.ack = seq, math.floor(M.epoch), "", 0
  if mut then mut(s) end
  writeFile(LIVE, "T3B_IN=" .. ser(s) .. "\nT3B_IN_END=" .. s.seq .. "\n")
  return s
end

local spikeSeq = 0
local function writeSpike(torn)
  spikeSeq = spikeSeq + 1
  local pad = string.rep("x", 70000)
  local text = string.format("T3B_SPIKE={seq=%d,size=%d,pad=%q}\nT3B_SPIKE_TAIL=%d\n", spikeSeq, 70100, pad, spikeSeq)
  if torn then text = text:sub(1, 3000) end
  writeFile(SPIKE, text)
end
writeFile(SPIKE, "T3B_SPIKE={seq=0,size=60}\nT3B_SPIKE_TAIL=0\n")

for k = 1, 200 do M.addAddon(string.format("T3Bridge_S%04d", k), function() return LIVE end, k == 3) end
for k = 1, 12 do M.addAddon(string.format("T3Bridge_TA%02d", k), function() return SPIKE end) end
for k = 1, 12 do M.addAddon(string.format("T3Bridge_TB%02d", k), function() return SPIKE end) end

-- Pre-load an inbox snapshot (as Inbox.lua would) before the addon's files run.
_G.T3B_IN, _G.T3B_IN_END = fixture, fixture.seq

-- load the addon in TOC order
local ns = {}
local tocText = T.readFile(T.path("addon/T3Bridge/T3Bridge.toc"))
local loaded = {}
for line in tocText:gmatch("[^\r\n]+") do
  if not line:match("^%s*#") and line:match("%S") then
    local file = line:gsub("\\", "/"):gsub("%s+$", "")
    if file:match("%.lua$") then
      local chunk = assert(loadfile(T.path("addon/T3Bridge/" .. file)))
      chunk("T3Bridge", ns)
      loaded[#loaded + 1] = file
    else
      T.ok(io.open(T.path("addon/T3Bridge/" .. file)), "TOC file exists: " .. file)
    end
  end
end

local function chatHas(pattern)
  for _, l in ipairs(M.chat) do if l:find(pattern) then return l end end
  return nil
end

-- Reconstruct the matrix from the mock textures and decode it.
local decoded = {}
local function captureMatrix()
  local mx = _G.T3BridgeMatrix
  if not mx or not mx._shown then return end
  local cell = ns.Outbound.geometry.cell
  local rows = math.floor(mx._h / cell + 0.5)
  local grid = {}
  for r = 1, rows do grid[r] = {} for x = 1, 256 do grid[r][x] = "0" end end
  for _, t in ipairs(mx._children) do
    if t._otype == "Texture" and t._shown and t._color and t._color[1] == 1 then
      local pt = t._points[1]
      local x0, r0 = pt[4] / cell, -pt[5] / cell
      for x = x0, x0 + t._w / cell - 1 do grid[r0 + 1][x + 1] = "1" end
    end
  end
  local cells = {}
  for r = 1, rows do cells[r] = table.concat(grid[r]) end
  local p = ns.Codec.ParseFrame(ns.Codec.CellsToBytes(cells))
  if p then
    local key = p.seq .. ":" .. p.part .. ":" .. p.flags
    if not decoded[key] then
      decoded[key] = p
      decoded[#decoded + 1] = p
    end
  else
    decoded.bad = (decoded.bad or 0) + 1
  end
  T.eq(cells[1], string.rep("10", 128), "sync row")
end

local function run(sec)
  local steps = math.floor(sec * 60 + 0.5)
  for _ = 1, steps do M.advance(1 / 60); captureMatrix() end
end

local function lastPayload() return decoded[#decoded] and decoded[#decoded].payload end
local function messagesFor(seqN)
  local parts = {}
  for _, p in ipairs(decoded) do if p.seq == seqN and p.flags == 0 then parts[p.part] = p.payload end end
  return table.concat(parts)
end

---------------------------------------------------------------------------------------------
-- tests
---------------------------------------------------------------------------------------------
T.test("[" .. CONFIG .. "] all TOC files load", function()
  T.ok(#loaded >= 15, "loaded " .. #loaded)
  T.ok(SlashCmdList.T3BRIDGE, "slash registered")
end)

T.test("[" .. CONFIG .. "] login: inbox snapshot, slots discovered, UI built", function()
  M.event("ADDON_LOADED", "T3Bridge")
  T.ok(_G.T3BridgeDB and _G.T3BridgeDB.cell == 2, "db defaults")
  T.eq(ns.state.snap and ns.state.snap.seq, fixture.seq, "inbox applied")
  M.event("PLAYER_LOGIN")
  M.event("PLAYER_ENTERING_WORLD")
  T.eq(ns.Inbound.total, 200)
  T.eq(ns.Inbound.SlotsLeft(), 200)
  T.ok(_G.T3BridgeTracker, "tracker exists")
  T.ok(_G.T3BridgeMinimapButton, "minimap exists")
  if CONFIG == "modern" then T.ok(M.compartment, "compartment registered") end
end)

T.test("[" .. CONFIG .. "] tracker anchors under a late Questie_BaseFrame, falls back, flips above", function()
  local tr = _G.T3BridgeTracker
  local q = M.new("Frame", UIParent, "Questie_BaseFrame")
  q._w = 280
  run(1.2) -- the 1 s poll finds and hooks it
  local p, rel, rp, _, y = tr:GetPoint(1)
  T.eq(rel, q, "anchored to Questie")
  T.eq(p, "TOPLEFT"); T.eq(rp, "BOTTOMLEFT"); T.eq(y, -4)
  q:Hide() -- OnHide hook re-anchors immediately
  _, rel = tr:GetPoint(1)
  T.ok(rel ~= q, "fell back when Questie hides")
  q.GetBottom = function() return 20 end
  q:Show()
  p, rel, rp, _, y = tr:GetPoint(1)
  T.eq(rel, q); T.eq(p, "BOTTOMLEFT"); T.eq(rp, "TOPLEFT"); T.eq(y, 4)
  q.GetBottom = function() return 400 end
  q._w = 150 -- narrower than 220: single anchor + min width
  q:Hide(); q:Show()
  T.eq(tr:GetNumPoints(), 1)
  T.eq(tr._w, 220)
  q._w = 280
  q:Hide(); q:Show()
end)

T.test("[" .. CONFIG .. "] inbound poll accepts a fresh snapshot; tracker shows rows", function()
  writeLive()
  run(2)
  T.eq(ns.state.snap.seq, seq, "accepted live seq")
  T.ok(_G.T3BridgeTracker:IsShown(), "tracker shown")
  T.ok(ns.Inbound.SlotsLeft() < 200, "slot used")
end)

T.test("[" .. CONFIG .. "] hello is sent over the matrix and decodes", function()
  run(1.5)
  local hello
  for _, p in ipairs(decoded) do if p.payload:find("^hello\t1\t0%.2%.0\t2\t8\t1$") then hello = p end end -- 5th field: images work (rev 1.3)
  T.ok(hello, "hello decoded (" .. #decoded .. " frames, bad " .. tostring(decoded.bad) .. ")")
  T.eq(ns.Codec.ToHex(hello.sid), ns.outbox:SidHex())
  -- ack it
  writeLive(function(s) s.asid, s.ack = ns.outbox:SidHex(), hello.seq end)
  run(2)
  T.eq(ns.outbox:Busy(), false, "hello acked")
end)

T.test("[" .. CONFIG .. "] torn and stale files are swallowed and ignored", function()
  local before = ns.state.snap.seq
  local errs = #M.errors
  writeFile(LIVE, T.readFile(T.path("protocol/fixtures/live.torn.lua")))
  ns.Inbound.Poll()
  T.eq(ns.state.snap.seq, before, "torn rejected")
  T.eq(#M.errors, errs, "no error reached the default handler")
  T.ok(ns.Inbound.stats.swallowed > 0, "error swallowed")
  T.ok(ns.Inbound.quickRetry, "quick retry armed")
  -- END mismatch (complete table, stale END)
  local s = T.loadSnapshot(T.path("protocol/fixtures/live.sample.lua"))
  s.seq, s.ts = before + 50, math.floor(M.epoch)
  writeFile(LIVE, "T3B_IN=" .. ser(s) .. "\nT3B_IN_END=" .. before .. "\n")
  ns.Inbound.Poll()
  T.eq(ns.state.snap.seq, before, "END mismatch rejected")
  -- stale: rewrite same seq
  s.seq = before
  writeFile(LIVE, "T3B_IN=" .. ser(s) .. "\nT3B_IN_END=" .. before .. "\n")
  ns.Inbound.Poll()
  T.ok(ns.state.stats.stale >= 1, "stale counted")
end)

T.test("[" .. CONFIG .. "] disabled slot is enabled and loaded", function()
  T.eq(M.addons.T3Bridge_S0003.loaded, true, "slot 3 (disabled) was enabled and loaded")
end)

T.test("[" .. CONFIG .. "] chat opens on a thread, renders history and the approval prompt", function()
  writeLive()
  ns.Inbound.Poll()
  ns.UI.OpenChat("a1b2c3d4")
  T.ok(_G.T3BridgeChatFrame:IsShown(), "chat shown")
  T.eq(ns.selected, "a1b2c3d4")
  local shownText = 0
  for _, f in ipairs(M.frames) do
    if f._otype == "FontString" and f._shown and f._text and f._text:find("Found it") then shownText = shownText + 1 end
  end
  T.ok(shownText >= 1, "message text rendered")
  -- pipes escaped
  local escaped = false
  for _, f in ipairs(M.frames) do
    if f._otype == "FontString" and f._text and f._text:find("||cffff0000", 1, true) then escaped = true end
  end
  T.ok(escaped, "UI codes escaped")
  local status = ns.LinkStatus()
  T.ok(status:find("^Linked") or status:find("^Sending"), "status: " .. status)
end)

T.test("[" .. CONFIG .. "] approval button sends ans; ack completes", function()
  local btn
  for _, f in ipairs(M.frames) do
    if f._otype == "Button" and f.optId == "allow" and f._shown then btn = f end
  end
  T.ok(btn, "Allow button exists")
  btn:Click()
  run(1.5)
  T.ok(lastPayload() == "ans\ta1b2c3d4\treq-77\tallow", "decoded ans: " .. tostring(lastPayload()))
  writeLive(function(s) s.asid, s.ack = ns.outbox:SidHex(), ns.outbox.nextSeq - 1; s.focus.pending = nil; s.threads[1].need = nil end)
  run(2)
  T.eq(ns.outbox:Busy(), false)
end)

local function editBox()
  for _, f in ipairs(M.frames) do
    if f._otype == "EditBox" and f._scripts.OnEnterPressed then return f end
  end
end

T.test("[" .. CONFIG .. "] Enter sends, Shift+Enter adds a newline", function()
  local eb = editBox()
  T.ok(eb, "edit box")
  eb:SetText("first line")
  M.shift = true
  eb._scripts.OnEnterPressed(eb)
  M.shift = false
  T.eq(eb:GetText(), "first line\n", "shift-enter newline")
  eb:Insert("second line")
  eb._scripts.OnEnterPressed(eb)
  T.eq(eb:GetText(), "", "cleared after send")
  run(1.5)
  local want = "send\ta1b2c3d4\t" .. ns.outbox:SidHex() .. "-" .. (ns.outbox.nextSeq - 1) .. "\tfirst line\nsecond line"
  T.eq(lastPayload(), want)
  -- client-inserted newline variant: text already has the newline when OnEnterPressed fires
  writeLive(function(s) s.asid, s.ack = ns.outbox:SidHex(), ns.outbox.nextSeq - 1; s.focus.pending = nil end)
  run(2)
  eb:SetText("abc")
  eb:SetText("abc\n")
  eb._scripts.OnEnterPressed(eb)
  run(1.5)
  T.ok(lastPayload():find("\tabc$"), "client newline stripped: " .. lastPayload())
  writeLive(function(s) s.asid, s.ack = ns.outbox:SidHex(), ns.outbox.nextSeq - 1; s.focus.pending = nil end)
  run(2)
end)

T.test("[" .. CONFIG .. "] 4000-byte message goes out as 5 frames and reassembles", function()
  local eb = editBox()
  local text = string.rep("\195\169", 2000)
  eb:SetText(text)
  eb._scripts.OnEnterPressed(eb)
  run(0.1)
  local s = ns.outbox.cur and ns.outbox.cur.seq
  T.ok(s, "in flight")
  run(3)
  local msg = messagesFor(s)
  T.eq(msg, "send\ta1b2c3d4\t" .. ns.outbox:SidHex() .. "-" .. s .. "\t" .. text)
  writeLive(function(x) x.asid, x.ack = ns.outbox:SidHex(), s; x.focus.pending = nil end)
  run(2)
end)

T.test("[" .. CONFIG .. "] no ack: 3 retransmits, then not responding and text restored", function()
  local eb = editBox()
  eb:SetText("will fail")
  eb._scripts.OnEnterPressed(eb)
  run(0.1)
  local s = ns.outbox.cur.seq
  run(16)
  local retrans = 0
  for _, l in ipairs(ns.log) do if l:find("retransmit send #" .. s .. " ", 1, true) then retrans = retrans + 1 end end
  T.eq(retrans, 3, "three retransmissions")
  T.ok(decoded[s .. ":1:1"], "a retransmitted frame (flags=1) was drawn and decoded")
  T.eq(ns.outbox:Busy(), false)
  T.eq(eb:GetText(), "will fail", "text restored")
  T.eq((ns.LinkStatus()), "Companion not responding")
end)

T.test("[" .. CONFIG .. "] offline after 30 s without fresh ts", function()
  run(35)
  T.eq((ns.LinkStatus()), "Companion offline")
  T.ok(ns.Inbound.Interval() == 15 or ns.Inbound.Interval() == nil, "slow polling while offline")
end)

T.test("[" .. CONFIG .. "] companion restart: the open chat re-sends focus once (throttled)", function()
  T.ok(ns.UI.ChatIsOpen(), "chat window still open")
  T.eq(ns.selected, "a1b2c3d4")
  local function restarted(mut)
    writeLive(function(s) s.sid = "newsid1"; s.focus = nil; s.asid, s.ack = "", 0; if mut then mut(s) end end)
    ns.Inbound.Poll()
  end
  local mark = #decoded
  restarted()                                   -- new companion sid: reset, hello + focus queued
  run(1.5)
  local hello = decoded[#decoded]
  T.ok(hello and hello.payload:find("^hello"), "hello first")
  restarted(function(s) s.asid, s.ack = ns.outbox:SidHex(), hello.seq end)
  run(1.5)
  local focus
  for k = mark + 1, #decoded do if decoded[k].payload == "focus\ta1b2c3d4" then focus = decoded[k] end end
  T.ok(focus, "focus re-sent for the open thread")
  restarted(function(s) s.asid, s.ack = ns.outbox:SidHex(), focus.seq end)
  run(1)
  T.eq(ns.outbox:Busy(), false)
  -- still no focus in the next snapshots: no second focus within 10 s (no repeated matrix flashes)
  restarted(function(s) s.asid, s.ack = ns.outbox:SidHex(), focus.seq end)
  T.eq(ns.outbox:Pending(), 0, "throttled")
  T.eq(ns.outbox:Busy(), false)
  -- once the companion focuses it, nothing more is sent
  restarted(function(s) s.asid, s.ack = ns.outbox:SidHex(), focus.seq; s.focus = fixture.focus end)
  run(11)
  restarted(function(s) s.asid, s.ack = ns.outbox:SidHex(), focus.seq; s.focus = fixture.focus end)
  T.eq(ns.outbox:Pending(), 0, "nothing when focus matches")
  T.eq(ns.outbox:Busy(), false)
end)

T.test("[" .. CONFIG .. "] link low -> click reloads; exhausted stops polling", function()
  writeLive()
  while ns.Inbound.SlotsLeft() > 10 do ns.Inbound.Poll() end
  local text, _, click = ns.LinkStatus()
  T.eq(text, "Link low: click to reload")
  T.ok(click, "clickable")
  local bar
  for _, f in ipairs(M.frames) do if f._otype == "Button" and f.clickable ~= nil then bar = f end end
  ns.UI.Chat.RefreshStatus()
  T.ok(bar and bar.clickable, "status bar clickable")
  bar:Click()
  T.eq(M.reloads, 1, "ReloadUI only on click")
  while ns.Inbound.SlotsLeft() > 0 do ns.Inbound.Poll() end
  T.eq((ns.LinkStatus()), "Link exhausted: click to reload")
  T.eq(ns.Inbound.Interval(), nil, "polling stopped")
end)

T.test("[" .. CONFIG .. "] demo mode end to end", function()
  SlashCmdList.T3BRIDGE("demo")
  T.ok(ns.demo, "demo on")
  T.eq((ns.LinkStatus()), "Demo mode (no companion)")
  T.ok(chatHas("Demo mode on"), "printed")
  local eb = editBox()
  -- approval pending in fixture: typed text becomes an answer
  eb:SetText("yes please")
  eb._scripts.OnEnterPressed(eb)
  run(6)
  local list = ns.State.Messages(ns.state, "a1b2c3d4")
  T.ok(list[#list].segs[1][2]:find("Demo reply"), "streamed reply")
  -- switch thread via the dropdown
  ns.SelectThread("c3d4e5f6")
  run(0.5)
  local fo = ns.State.Focus(ns.state, "c3d4e5f6")
  T.ok(fo and fo.pending and fo.pending.kind == "input", "input request on c3d4e5f6")
  eb:SetText("main")
  eb._scripts.OnEnterPressed(eb)
  run(6)
  -- model change, stop, history
  ns.Send("model", { "c3d4e5f6", "claude-haiku-5-5" })
  T.eq(ns.State.Focus(ns.state, "c3d4e5f6").model, "claude-haiku-5-5")
  ns.SelectThread("a1b2c3d4")
  local first = ns.State.Messages(ns.state, "a1b2c3d4")[1].i
  ns.Send("hist", { "a1b2c3d4", tostring(first) })
  T.ok(ns.State.Messages(ns.state, "a1b2c3d4")[1].i < first, "older messages merged")
  ns.Send("intr", { "a1b2c3d4" })
  T.eq(ns.State.Thread(ns.state, "a1b2c3d4").st, "stopped")
  SlashCmdList.T3BRIDGE("demo")
  T.eq(ns.demo, false)
end)

T.test("[" .. CONFIG .. "] thread dropdown menu builds (grouped radios)", function()
  SlashCmdList.T3BRIDGE("demo")
  ns.UI.Chat.Refresh()
  if CONFIG == "modern" then
    local dd
    for _, f in ipairs(M.frames) do if f._otype == "DropdownButton" and f._default == "Select a thread" then dd = f end end
    T.ok(dd, "modern dropdown")
    dd:GenerateMenu()
    T.eq(dd._menu[1], "title:Needs you")
    local radio = dd._menu[2]
    T.ok(type(radio) == "table" and radio.isSel ~= nil, "radio item")
    radio.onSel()
    T.eq(ns.selected, radio.data)
  else
    T.ok(M.lastDropdownInfo, "legacy dropdown initialised")
  end
  SlashCmdList.T3BRIDGE("demo")
end)

T.test("[" .. CONFIG .. "] spike commands run and print PASS lines", function()
  -- S1: simulate the -Loop writer between rounds
  M.chat = {}
  SlashCmdList.T3BRIDGE("spike s1")
  for round = 1, 11 do
    writeSpike(round == 4)
    run(2)
  end
  T.ok(chatHas("PASS.-S1%-A load works"), "S1-A load")
  T.ok(chatHas("PASS.-S1%-B edits after login"), "S1-B edits")
  T.ok(chatHas("PASS.-S1%-A file can grow"), "S1-A growth")
  T.ok(chatHas("PASS.-S1 torn"), "S1 torn")
  M.combat = true
  SlashCmdList.T3BRIDGE("spike s1 combat")
  M.event("PLAYER_REGEN_DISABLED")
  M.combat = false
  T.ok(chatHas("PASS.-S1 combat load"), "S1 combat")
  M.chat = {}
  SlashCmdList.T3BRIDGE("spike s2 500")
  run(6)
  T.ok(chatHas("PASS.-S2 hello_c1"), "S2 hello geometry: " .. tostring(chatHas("S2 hello")))
  T.ok(chatHas("PASS.-S2 geometry"), "S2 all")
  M.chat = {}
  local handled, err = M.typeChat("/t3 spike fonts")
  T.ok(handled, "'/t3 spike fonts' + Enter must not raise (it did nothing in game): " .. tostring(err))
  run(2.5)
  T.ok(chatHas("fonts: started"), "fonts started line")
  if CONFIG == "modern" then
    T.ok(chatHas("PASS.-fonts: bundled monospace font loads %(now%)"), "fonts")
    T.ok(chatHas("PASS.-fonts: bundled monospace font loads %(after 2 s%)"), "fonts after 2 s")
  else
    T.ok(chatHas("FAIL.-fonts"), "fonts FAIL line when the font does not load")
    T.eq(ns.monoFontOk, false, "code blocks fall back to the chat font")
  end
  SlashCmdList.T3BRIDGE("spike templates")
  T.ok(chatHas("templates:"), "templates")
  SlashCmdList.T3BRIDGE("status")
  T.ok(chatHas("Slots:"), "status")
  SlashCmdList.T3BRIDGE("help")
  SlashCmdList.T3BRIDGE("cell 4")
  T.eq(T3BridgeDB.cell, 4)
  SlashCmdList.T3BRIDGE("cell 3")
  T.eq(T3BridgeDB.cell, 4)
end)

T.test("[" .. CONFIG .. "] minimap clicks toggle chat (left and right)", function()
  local b = _G.T3BridgeMinimapButton
  local was = _G.T3BridgeChatFrame:IsShown()
  b:Click("LeftButton")
  T.eq(_G.T3BridgeChatFrame:IsShown(), not was)
  b:Click("RightButton")
  T.eq(_G.T3BridgeChatFrame:IsShown(), was)
end)

local function angleDiff(a, b) local d = math.abs((a - b) % 360); return d > 180 and 360 - d or d end

T.test("[" .. CONFIG .. "] minimap button: free spot away from other buttons, drag, reset, shapes", function()
  local b, mm, MM = _G.T3BridgeMinimapButton, _G.Minimap, ns.UI.Minimap
  mm._h = 140
  T.ok(b:GetFrameLevel() >= 8, "frame level above other minimap buttons")
  -- The user's minimap: Questie/Spoken buttons at ~204-225 deg (left), an icon at ~58 deg (top-right).
  local fakes, taken = {}, { 204, 216, 225, 58 }
  for _, a in ipairs(taken) do
    local f = M.new("Button", mm)
    f._w, f._h = 31, 31
    local x, y = 500 + 75 * math.cos(math.rad(a)), 400 + 75 * math.sin(math.rad(a))
    f.GetCenter = function() return x, y end
    fakes[#fakes + 1] = f
  end
  T.eq(#MM.OccupiedAngles(), 4, "found the four other buttons")
  -- an existing install saved the old default (215 = right among them) and never dragged
  T3BridgeDB.minimap.angle, T3BridgeDB.minimap.moved = 215, nil
  MM.AutoPlace()
  local a = T3BridgeDB.minimap.angle
  for _, o in ipairs(taken) do T.ok(angleDiff(a, o) >= 26, "clear of " .. o .. " (got " .. a .. ")") end
  T.eq(a, 30, "first free preferred angle, top-right")
  local p, rel, rp, x, y = b:GetPoint(1)
  T.eq(rel, mm); T.eq(p, "CENTER"); T.eq(rp, "CENTER")
  T.ok(math.abs(x - 75 * math.cos(math.rad(30))) < 0.01 and math.abs(y - 37.5) < 0.01, "on the ring: " .. x .. "," .. y)
  -- drag to the top-left (cursor at 135 deg from the minimap centre)
  M.cursor = { 500 - 100, 400 + 100 }
  b._scripts.OnDragStart(b)
  run(0.1)
  b._scripts.OnDragStop(b)
  T.ok(math.abs(T3BridgeDB.minimap.angle - 135) < 0.01, "dragged angle saved: " .. T3BridgeDB.minimap.angle)
  T.eq(T3BridgeDB.minimap.moved, true)
  local was = _G.T3BridgeChatFrame:IsShown()
  b:Click("LeftButton") -- the mouse-up that ends a drag must not toggle the chat
  T.eq(_G.T3BridgeChatFrame:IsShown(), was, "no toggle right after a drag")
  run(0.5)
  MM.AutoPlace()
  T.ok(math.abs(T3BridgeDB.minimap.angle - 135) < 0.01, "auto-place respects a dragged position")
  -- /t3 minimap reset forgets the drag and picks the free spot again
  M.chat = {}
  T.ok(M.typeChat("/t3 minimap reset"))
  T.eq(T3BridgeDB.minimap.angle, 30)
  T.eq(T3BridgeDB.minimap.moved, false)
  T.ok(chatHas("free spot"), "reset confirmed in chat")
  -- shapes: a square minimap puts a 45-deg button further out (into the corner)
  local rx = MM.Offset(45)
  M.minimapShape = "SQUARE"
  local sx = MM.Offset(45)
  M.minimapShape = nil
  T.ok(math.abs(rx - 75 * math.cos(math.rad(45))) < 0.01, "round")
  T.ok(sx > rx + 10, "square corner " .. sx .. " vs round " .. rx)
  -- every other button taken: still picks the most open angle
  local all = {}
  for k = 0, 350, 20 do all[#all + 1] = k end
  T.eq(MM.FreeAngle(all) % 20, 10, "falls back to the widest gap")
  for _, f in ipairs(fakes) do f:Hide() end
end)

T.test("[" .. CONFIG .. "] tracker placement: below (rows capped), side, above, free; never off-screen", function()
  local q, mm, TR = _G.Questie_BaseFrame, _G.Minimap, ns.UI.Tracker
  T.ok(q, "Questie frame from the earlier test")
  local saved = { q.GetTop, q.GetBottom, mm.GetBottom }
  -- The user's screen (2000x1125 px = 768 units): Questie from right under the minimap (top ~580)
  -- down to y~820 px (bottom ~208 units). The minimap sits directly above it.
  q.GetTop = function() return 580 end
  q.GetBottom = function() return 208 end
  mm.GetBottom = function() return 590 end
  q:Hide(); q:Show()
  local kind, target = TR.AnchorKind()
  T.eq(kind, "below"); T.eq(target, q)
  T.ok(TR.MaxRows() >= 3 and TR.MaxRows() <= 16, "rows fit below: " .. TR.MaxRows())
  -- 40 quests reaching near the bottom: no room for 3 rows below; above would cover the minimap
  q.GetBottom = function() return 40 end
  q:Hide(); q:Show()
  kind = TR.AnchorKind()
  T.eq(kind, "side", "left of the quest tracker, not over the minimap")
  local p, rel, rp = _G.T3BridgeTracker:GetPoint(1)
  T.eq(p, "TOPRIGHT"); T.eq(rel, q); T.eq(rp, "TOPLEFT")
  -- forced modes
  M.chat = {}
  T.ok(M.typeChat("/t3 tracker below"))
  T.eq(T3BridgeDB.tracker.mode, "below")
  kind = TR.AnchorKind()
  T.eq(kind, "below")
  T.eq(TR.MaxRows(), 1, "forced below with no room: capped to 1 row, never runs off-screen")
  T.ok(M.typeChat("/t3 tracker above"))
  kind = TR.AnchorKind()
  T.eq(kind, "above")
  T.ok(M.typeChat("/t3 tracker free"))
  kind, target = TR.AnchorKind()
  T.eq(kind, "free"); T.eq(target, false)
  T.ok(chatHas("Shift%-drag"), "free mode explains how to move it")
  T.ok(M.typeChat("/t3 tracker reset"))
  T.eq(T3BridgeDB.tracker.mode, "auto")
  -- Questie at the bottom of the screen with the minimap far away: above is fine
  mm.GetBottom = function() return 650 end
  q.GetTop = function() return 300 end
  q:Hide(); q:Show()
  T.eq((TR.AnchorKind()), "above")
  q.GetTop, q.GetBottom, mm.GetBottom = saved[1], saved[2], saved[3]
  q:Hide(); q:Show()
  T.eq((TR.AnchorKind()), "below")
end)

---------------------------------------------------------------------------------------------
-- Phase 2: effort picker, top bar layout, markdown styling, sticky header, tracker rules
---------------------------------------------------------------------------------------------
local p2seq = 90000
-- Snapshots fed directly (the link slots are used up by the "exhausted" test above).
local function applyFixture(mut)
  p2seq = p2seq + 1
  local s = T.loadSnapshot(T.path("protocol/fixtures/live.sample.lua"))
  s.sid, s.seq, s.ts = "p2sid", p2seq, math.floor(M.epoch)
  s.asid, s.ack = ns.outbox:SidHex(), ns.outbox.nextSeq - 1
  s.focus.pending = nil
  s.threads[1].need = nil
  if mut then mut(s) end
  return ns.ApplySnapshot(s, s.seq, "test")
end
local function settle(mut)
  -- deliver acks until nothing is queued or in flight (a companion sid change queues a hello)
  for _ = 1, 6 do
    run(1.5)
    applyFixture(mut)
    if not ns.outbox:Busy() and ns.outbox:Pending() == 0 then break end
  end
end

local function radios(dd)
  dd:GenerateMenu()
  local out = {}
  for _, it in ipairs(dd._menu) do if type(it) == "table" then out[#out + 1] = it end end
  return out
end

T.test("[" .. CONFIG .. "] effort picker: current value, model+effort command, fallback, hidden without effort", function()
  T.eq(ns.demo, false)
  ns.UI.OpenChat("a1b2c3d4")
  settle()
  T.eq(ns.selected, "a1b2c3d4")
  local C = ns.UI.Chat
  local tdd, mdd, edd = ns.UI.ChatTopBar()
  T.ok(edd.frame:IsShown(), "effort dropdown shown for Opus 5.5")
  local choice, cur = C.CurrentEffort()
  T.eq(cur, "high"); T.eq(#choice.vals, 6)
  T.eq(C.EffortLabel("xhigh"), "X-High"); T.eq(C.EffortLabel("ultrathink"), "Ultrathink"); T.eq(C.EffortLabel("max"), "Max")
  T.eq(C.EffortLabel("weird"), "Weird")
  T.eq(C.ShortModelName("Claude Sonnet 5.5"), "Sonnet 5.5"); T.eq(C.ShortModelName("GPT-5"), "GPT-5")
  local function pickEffort(v)
    if CONFIG == "modern" then
      edd.frame:GenerateMenu()
      T.eq(edd.frame._menu[1], "title:Reasoning effort")
      local hit
      for _, r in ipairs(radios(edd.frame)) do if r.data == v then hit = r end end
      T.ok(hit, "radio " .. v)
      hit.onSel()
    else
      C.ChooseEffort(v)
    end
  end
  local function pickModel(id)
    if CONFIG == "modern" then
      local hit
      for _, r in ipairs(radios(mdd.frame)) do if r.data == id then hit = r end end
      T.ok(hit, "model radio " .. id)
      hit.onSel()
    else
      C.ChooseModel(id)
    end
  end
  if CONFIG == "modern" then
    local rs = radios(edd.frame)
    T.eq(#rs, 6)
    local sel
    for _, r in ipairs(rs) do if r.isSel() then sel = r.text end end
    T.eq(sel, "High", "dropdown text is the pretty label")
    local names = {}
    for _, r in ipairs(radios(mdd.frame)) do names[#names + 1] = r.text end
    T.eq(names[1], "Opus 5.5", "short model names")
  end
  -- effort only: same model, new effort, one command
  pickEffort("low")
  T.eq(select(2, C.CurrentEffort()), "low", "optimistic")
  run(1.5)
  T.eq(lastPayload(), "model\ta1b2c3d4\tclaude-opus-5-5\tlow")
  settle(function(s) s.focus.effort = "low" end)
  T.eq(select(2, C.CurrentEffort()), "low")
  -- xhigh, then a model without xhigh: falls back to that model's default in the same command
  pickEffort("xhigh"); run(1.5)
  settle(function(s) s.focus.effort = "xhigh" end)
  pickModel("claude-opus-4-5")
  run(1.5)
  T.eq(lastPayload(), "model\ta1b2c3d4\tclaude-opus-4-5\thigh", "fallback to Opus 4.5 default")
  T.eq(select(2, C.CurrentEffort()), "high")
  settle(function(s) s.focus.model, s.focus.effort = "claude-opus-4-5", "high" end)
  -- a supported effort is kept across a switch
  pickModel("claude-sonnet-5-5"); run(1.5)
  T.eq(lastPayload(), "model\ta1b2c3d4\tclaude-sonnet-5-5\thigh")
  settle(function(s) s.focus.model, s.focus.effort = "claude-sonnet-5-5", "high" end)
  -- Haiku 4.5 has no effort option: no 4th field, picker hidden
  pickModel("claude-haiku-4-5"); run(1.5)
  T.eq(lastPayload(), "model\ta1b2c3d4\tclaude-haiku-4-5")
  settle(function(s) s.focus.model, s.focus.effort = "claude-haiku-4-5", nil end)
  T.eq(edd.frame:IsShown(), false, "effort picker hidden")
  T.eq(C.CurrentEffort(), nil)
  -- back to the fixture state
  pickModel("claude-opus-5-5"); run(1.5)
  T.eq(lastPayload(), "model\ta1b2c3d4\tclaude-opus-5-5\tmedium", "no current effort: the new model's default")
  settle()
  T.ok(edd.frame:IsShown())
end)

T.test("[" .. CONFIG .. "] top bar fits at the minimum window size (420) without overlapping the status", function()
  local C = ns.UI.Chat
  local keys = { "thread", "model", "effort" }
  local w, lim = C.FitTop(900, 60, 90, keys, 6)
  T.eq(w.thread, 210); T.eq(w.model, 130); T.eq(w.effort, 96); T.eq(lim, nil)
  for _, sw in ipairs({ 0, 60, 90, 150, 220 }) do
    w, lim = C.FitTop(420, 60, sw, keys, 6)
    local right = 60 + w.thread + w.model + w.effort + 12
    local statusLeft = 420 - 14 - math.min(lim or sw, math.min(sw, 150))
    local gap = (sw > 0) and 8 or 0
    T.ok(right + gap <= statusLeft or (lim ~= nil and right + 8 <= 420 - 14 - lim + 0.001),
      "status " .. sw .. ": dropdowns end at " .. right .. ", status starts at " .. statusLeft)
    T.ok(w.thread >= 76 and w.model >= 62 and w.effort >= 56, "minimum widths")
  end
  -- the real window at 420 x 360
  local f = _G.T3BridgeChatFrame
  f:SetSize(420, 360)
  ns.UI.Chat.Refresh()
  local _, _, _, status, widths, limit = ns.UI.ChatTopBar()
  T.ok(widths and widths.effort, "laid out")
  local right = 60 + widths.thread + widths.model + widths.effort + 12
  local sw = limit or status:GetStringWidth()
  if CONFIG == "modern" then T.ok(right + 8 <= 420 - 14 - sw + 0.001, "no overlap: " .. right .. " vs " .. (420 - 14 - sw)) end
  f:SetSize(520, 560)
  ns.UI.Chat.Refresh()
end)

T.test("[" .. CONFIG .. "] markdown: bold, inline code, headings, bullets with hanging indent; escapes hold", function()
  local Ms = ns.UI.Messages
  T.eq(Ms.StyleInline("a **b** c"), "a |cffffd866b|r c")
  T.eq(Ms.StyleInline("run `npm test` now"), "run |cffaad4ffnpm test|r now")
  T.eq(Ms.StyleInline("**|cffff0000x|r**"), "|cffffd866||cffff0000x||r|r", "no UI-code injection inside bold")
  T.eq(Ms.StyleInline("`a|Tb|t`"), "|cffaad4ffa||Tb||t|r", "no injection inside code")
  T.eq(Ms.StyleInline("a ** b and a lone ` tick"), "a ** b and a lone ` tick", "unmatched markers stay literal")
  T.eq(Ms.StyleInline("**`x`**"), "**|cffaad4ffx|r**", "code wins; no nested colours")
  local b = Ms.Blocks("# Title\ntext line\n- item one\n  continued\n  - nested\n1. first\n\nafter")
  T.eq(#b, 6)
  T.eq(b[1].kind, "head"); T.eq(b[1].text, "Title")
  T.eq(b[2].kind, "text"); T.eq(b[2].text, "text line")
  T.eq(b[3].kind, "item"); T.eq(b[3].text, "item one continued"); T.eq(b[3].indent, 0)
  T.eq(b[4].indent, 1); T.eq(b[4].text, "nested")
  T.eq(b[5].bullet, "1."); T.eq(b[6].text, "after")
  -- 2000-char FontString split still applies inside styled text
  local long = string.rep("word ", 900)
  local nb = Ms.Blocks(long)
  T.eq(#Ms.Chunk(nb[1].text), 3)
  -- rendered fixture message
  ns.UI.OpenChat("a1b2c3d4")
  ns.UI.Chat.Refresh()
  local heading, code, bold, bullet, nested
  for _, fr in ipairs(M.frames) do
    if fr._otype == "FontString" and fr._shown and fr._text then
      if fr._text == "Call sites of login()" then heading = fr end
      if fr._text:find("|cffaad4ffsrc/pages/Login.tsx|r", 1, true) then code = fr end
      if fr._text:find("|cffffd866safe|r", 1, true) then bold = fr end
      if fr._text == "\194\183" then bullet = (bullet or 0) + 1 end
      if fr._text:find("^nested: |cffffd866fire%-and%-forget|r") then nested = fr end
    end
  end
  T.ok(heading, "heading rendered on its own line"); T.ok(code, "inline code coloured"); T.ok(bold, "bold highlighted")
  T.ok((bullet or 0) >= 4, "bullet glyphs: " .. tostring(bullet))
  T.ok(nested, "nested item")
  local hx = select(4, heading:GetPoint(1))
  local nx = select(4, nested:GetPoint(1))
  T.ok(nx > hx + 12, "nested item indented (" .. nx .. " vs " .. hx .. ")")
  -- the pipes message is still escaped (UI codes shown literally)
  local escaped = false
  for _, fr in ipairs(M.frames) do
    if fr._otype == "FontString" and fr._shown and fr._text and fr._text:find("||cffff0000 this should NOT turn red||r", 1, true) then escaped = true end
  end
  T.ok(escaped, "pipes escaped")
end)

T.test("[" .. CONFIG .. "] sticky header replaces a header clipped at the top edge", function()
  local v = ns.UI.ChatView()
  T.ok(v and v.rowTops[1], "row tops recorded")
  local list = v.opts.list
  local k
  for i = 1, #list do if list[i].more then k = i end end -- the 5 KB message
  T.ok(k, "long message present")
  v.scroll:SetVerticalScroll(v.rowTops[k] + 40)
  T.ok(v.sticky:IsShown(), "sticky shown inside a long message")
  T.eq(v.sticky.msg, list[k])
  T.ok(v.sticky.role:GetText():find("Assistant"), "role shown")
  v.scroll:SetVerticalScroll(v.rowTops[k])
  T.eq(v.sticky:IsShown(), false, "header fully visible: no sticky")
  v.scroll:SetVerticalScroll(0)
  T.eq(v.sticky:IsShown(), false)
end)

local function trackerRowFor(tid)
  for _, fr in ipairs(M.frames) do
    if fr._otype == "Button" and fr._shown and fr.thread and fr.thread.id == tid and fr.toggle then return fr end
  end
end
local function shownText(pattern)
  for _, fr in ipairs(M.frames) do
    if fr._otype == "FontString" and fr._shown and fr._text and fr._text:find(pattern) then return fr end
  end
end

T.test("[" .. CONFIG .. "] tracker (screenshot geometry): header with 'no open threads', below Questie", function()
  local q, mm, TR = _G.Questie_BaseFrame, _G.Minimap, ns.UI.Tracker
  -- The user's screenshot: 2000x1125 px, Questie_BaseFrame right edge ~1990, top ~275 px, bottom ~820 px
  -- (768-unit UI: top ~580, bottom ~208), minimap directly above it.
  q.GetTop = function() return 580 end
  q.GetBottom = function() return 208 end
  mm.GetBottom = function() return 590 end
  q:Hide(); q:Show()
  applyFixture(function(s) s.threads = {}; s.focus = nil end)
  local tr = _G.T3BridgeTracker
  T.ok(tr:IsShown(), "tracker visible with zero threads (it used to hide itself)")
  T.ok(shownText("^no open threads$"), "single-line 'no open threads' summary")
  T.eq(tr:GetHeight(), 16 + 3 + 2, "header line only")
  T.eq((TR.AnchorKind()), "below", "below Questie: about 198 units free")
  T.ok(TR.MaxRows() >= 12, "room for 12+ rows: " .. TR.MaxRows())
end)

T.test("[" .. CONFIG .. "] tracker: opened and old finished rows stay; per-row collapse; collapse all", function()
  local TR = ns.UI.Tracker
  applyFixture(function(s) s.threads[4].t1 = math.floor(M.epoch) - 3 * 86400; s.threads[4].t0 = s.threads[4].t1 - 600 end)
  T.eq(TR.shown, 7, "all 7 open threads, idle and a 3-day-old completed one included")
  local row = trackerRowFor("d4e5f6a7")
  T.ok(row, "completed row")
  row:Click("LeftButton")
  T.eq(ns.selected, "d4e5f6a7", "click opened the chat on it")
  T.ok(ns.UI.ChatIsOpen())
  settle(function(s) s.threads[4].t1 = math.floor(M.epoch) - 3 * 86400; s.threads[4].t0 = s.threads[4].t1 - 600 end)
  run(2)
  T.ok(trackerRowFor("d4e5f6a7"), "row still listed after opening it")
  T.eq(TR.shown, 7)
  -- right-click collapses; compact line, sorted last, counted in the header
  trackerRowFor("d4e5f6a7"):Click("RightButton")
  T.eq(T3BridgeDB.tracker.rows.d4e5f6a7, true, "saved by thread id only")
  local r = trackerRowFor("d4e5f6a7")
  T.ok(r.collapsed and r:GetHeight() == 12, "compact row")
  T.eq(r.timer:GetText(), "", "no timer on a collapsed row")
  T.eq(select(5, r:GetPoint(1)), -(16 + 3 + 6 * 14), "after the six expanded rows")
  T.ok(shownText("1 collapsed"), "header summary counts it")
  -- the +/- button expands it again
  r.toggle:Click()
  T.eq(T3BridgeDB.tracker.rows.d4e5f6a7, nil)
  -- collapse all / expand all
  TR.ToggleAll()
  local n = 0
  for _ in pairs(T3BridgeDB.tracker.rows) do n = n + 1 end
  T.eq(n, 7, "all collapsed")
  T.ok(shownText("7 collapsed"))
  -- a collapsed thread that starts needing approval expands by itself
  applyFixture(function(s) s.threads[2].need = "approval" end)
  T.eq(T3BridgeDB.tracker.rows.b2c3d4e5, nil, "auto-expanded on needs-you")
  T.eq(trackerRowFor("b2c3d4e5").collapsed, false)
  TR.ToggleAll() -- some expanded -> collapse all
  TR.ToggleAll() -- all collapsed -> expand all
  n = 0
  for _ in pairs(T3BridgeDB.tracker.rows) do n = n + 1 end
  T.eq(n, 0, "all expanded")
  -- SavedVariables: thread ids and short state keys only
  for k, v in pairs(T3BridgeDB.tracker.rows) do T.ok(ns.State.IsId(k) and (v == true or #v < 24)) end
end)

T.test("[" .. CONFIG .. "] tracker: rows fit the space; 'N more...' opens the thread menu listing all 30", function()
  local q, TR = _G.Questie_BaseFrame, ns.UI.Tracker
  q.GetBottom = function() return 120 end -- ~110 units below Questie
  q:Hide(); q:Show()
  applyFixture(function(s)
    s.threads = {}
    for k = 1, 30 do s.threads[k] = { id = string.format("t%07d", k), title = "Thread number " .. k, st = (k <= 2) and "running" or "completed", t0 = 1000, t1 = (k > 2) and 2000 or nil } end
    s.focus = nil
  end)
  T.eq(#ns.state.snap.threads, 30)
  T.eq((TR.AnchorKind()), "below")
  T.ok(TR.shown >= 3 and TR.shown < 30, "rows capped by space: " .. tostring(TR.shown))
  T.eq(TR.more, 30 - TR.shown)
  local tr = _G.T3BridgeTracker
  T.ok(16 + 3 + TR.shown * 14 + 12 + 2 <= 110 - 4 + 0.001, "fits below Questie")
  local more = shownText("^%d+ more%.%.%.$")
  T.ok(more, "N more line")
  T.eq(more:GetText(), TR.more .. " more...")
  more:GetParent():Click()
  T.ok(ns.UI.ChatIsOpen(), "chat opened")
  local tdd = ns.UI.ChatTopBar()
  if CONFIG == "modern" then
    T.ok(tdd.frame._menuOpen, "thread menu opened")
    T.eq(#radios(tdd.frame), 30, "thread menu lists every thread")
  end
  -- collapsed rows are smaller, so more of them fit
  local before = TR.shown
  TR.ToggleAll()
  T.ok(TR.shown > before, "collapsed rows take less space: " .. before .. " -> " .. TR.shown)
  TR.ToggleAll()
  for k in pairs(T3BridgeDB.tracker.rows) do T3BridgeDB.tracker.rows[k] = nil end
  q.GetBottom = function() return 208 end
  q:Hide(); q:Show()
  applyFixture()
end)

T.test("[" .. CONFIG .. "] slash errors are caught and printed, never swallowed", function()
  M.chat = {}
  local orig = ns.Spike.Templates
  ns.Spike.Templates = function() error("boom from a test") end
  local handled, err = M.typeChat("/t3 spike templates")
  ns.Spike.Templates = orig
  T.ok(handled, "error did not escape the slash handler: " .. tostring(err))
  T.ok(chatHas("Lua error.-boom from a test"), "error printed in chat")
  -- spike timer callbacks too
  M.chat = {}
  local g = ns.Spike.guarded("S9", function() error("late boom") end)
  g()
  T.ok(chatHas("FAIL.-S9 %(Lua error%).-late boom"), "timer error printed as FAIL")
end)

T.test("[" .. CONFIG .. "] help text: correct values, no swallowed characters", function()
  M.chat = {}
  T3BridgeDB.cell, T3BridgeDB.hold = 2, 200
  T.ok(M.typeChat("/t3 help"))
  T.ok(chatHas("hold 100%-500.-%(now 200%)"), "hold shows its own value (was 'now 2')")
  T.ok(chatHas("cell 1||2||4.-%(now 2%)"), "cell")
  for _, l in ipairs(M.chat) do
    -- remove valid escapes; any bar left would start a UI code and eat the next character
    local rest = l:gsub("||", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    T.ok(not rest:find("|", 1, true), "stray UI escape in: " .. l)
  end
  T.ok(chatHas("on||off||reset"), "tracker line keeps 'reset' (was shown as 'offeset')")
end)

T.test("[" .. CONFIG .. "] every spike prints a started line and a final PASS/FAIL", function()
  M.chat = {}
  T.ok(M.typeChat("/t3 spike templates"))
  T.ok(chatHas("templates: started")); T.ok(chatHas("PASS.-templates") or chatHas("FAIL.-templates"))
  M.chat = {}
  T.ok(M.typeChat("/t3 spike s2 100"))
  run(3)
  T.ok(chatHas("S2: started")); T.ok(chatHas("PASS.-S2 geometry") or chatHas("FAIL.-S2 geometry"))
  M.chat = {}
  T.ok(M.typeChat("/t3 spike s1")) -- only 2 spike slots per variant are left after the earlier run
  run(8)
  T.ok(chatHas("S1: started")); T.ok(chatHas("FAIL.-S1") or chatHas("PASS.-S1"))
end)

T.test("[" .. CONFIG .. "] focus.older drives the Earlier messages button", function()
  local St = ns.State
  local fo = { msgs = { { i = 200001 } } }
  local list = { { i = 200001 } }
  T.eq(St.CanLoadEarlier(fo, list), true, "no flag: guess from i > 1")
  fo.older = false
  T.eq(St.CanLoadEarlier(fo, list), false, "older=false hides it even though i > 1")
  fo.older = true
  T.eq(St.CanLoadEarlier({ older = true, msgs = { { i = 1 } } }, { { i = 1 } }), true, "older=true wins")
  T.eq(St.CanLoadEarlier(nil, list), false)
  local snap = St.Validate({ v = 1, sid = "x", seq = 1, threads = {}, focus = { id = "a1", msgs = {}, older = false } }, 1)
  T.eq(snap.focus.older, false, "parsed")
  snap = St.Validate({ v = 1, sid = "x", seq = 1, threads = {}, focus = { id = "a1", msgs = {}, older = "yes" } }, 1)
  T.eq(snap.focus.older, nil, "wrong type dropped")
end)

---------------------------------------------------------------------------------------------
-- Images (PROTOCOL rev 1.3): inline images, viewer, placeholders, chips, attach menu, Ctrl+V
---------------------------------------------------------------------------------------------
local IMG_TID = "a1b2c3d4"
local function withImages(s, opts)
  opts = opts or {}
  local msgs = s.focus.msgs
  local last = msgs[#msgs]
  last.segs[#last.segs + 1] = { "img", "[image: red.png]", s = 3, w = 320, h = 180, alt = "red.png", aid = "abcd1234" }
  last.segs[#last.segs + 1] = { "img", "[image: full.png]", s = 0, st = "full", alt = "full.png", aid = "abcd5678" }
  s.imgslots = { left = opts.left or 5, total = 100, reset = "restart" }
  if opts.staged ~= false then s.focus.staged = { { aid = "k1", s = 4, w = 64, h = 32, name = "clip-1.png" } } end
  if opts.notice then s.focus.notice, s.focus.nid = opts.notice, opts.nid or 1 end
  s.focus.pending = nil
  s.threads[1].need = nil
end
-- The mock's 200 link slots are used up by now, so these tests hand snapshots to the addon directly.
local function ackImg(opts)
  seq = seq + 1
  local s = T.loadSnapshot(T.path("protocol/fixtures/live.sample.lua"))
  s.seq, s.ts = seq, math.floor(M.epoch)
  s.asid, s.ack = ns.outbox:SidHex(), ns.outbox.nextSeq - 1
  withImages(s, opts)
  ns.ApplySnapshot(s, s.seq, "test")
  run(0.3)
end
local function imageButtons()
  local out = {}
  for _, f in ipairs(M.frames) do
    if f._otype == "Button" and f._shown and f.img and f.tex and f.top then out[#out + 1] = f end
  end
  return out
end
local function chips()
  local _, _, _, row, list = ns.UI.ChatInputBar()
  local out = {}
  for _, c in ipairs(list or {}) do if c._shown and c.img then out[#out + 1] = c end end
  return out, row
end

T.test("[" .. CONFIG .. "] inline image: sized to 240x160 max, cropped with texcoords, texture set when visible", function()
  ns.UI.OpenChat(IMG_TID)
  ackImg()
  local view = ns.UI.ChatView()
  view:ScrollToBottom()
  run(0.2)
  local imgs = imageButtons()
  local real, ph
  for _, b in ipairs(imgs) do if b.img.s == 3 then real = b elseif b.img.s == 0 then ph = b end end
  T.ok(real, "image button for slot 3 (" .. #imgs .. " image buttons)")
  T.eq(real._w, 242); T.eq(real._h, 137, "320x180 -> 240x135 + 1 px border")
  T.eq(real.tex._texcoord[2], 0.625); T.eq(real.tex._texcoord[4], 180 / 512)
  T.eq(real.tex._texture, "Interface\\AddOns\\T3Bridge_Img\\i0003", "lazy texture set once visible")
  T.ok(ph and ph.label._text:find("restart WoW"), "full-pool placeholder: " .. tostring(ph and ph.label._text))
  T.ok(not ph.tex._texture, "no texture for a placeholder")
end)

T.test("[" .. CONFIG .. "] clicking an image opens the viewer; Esc-closable; texcoords match", function()
  local real
  for _, b in ipairs(imageButtons()) do if b.img.s == 3 then real = b end end
  real:Click()
  local cur, box, tex, vf = ns.UI.ImageViewer.Current()
  T.ok(vf and vf:IsShown(), "viewer shown")
  T.eq(cur.alt, "red.png")
  T.eq(tex._texture, "Interface\\AddOns\\T3Bridge_Img\\i0003")
  T.eq(tex._texcoord[2], 0.625)
  local found = false
  for _, n in ipairs(UISpecialFrames) do if n == "T3BridgeImageViewer" then found = true end end
  T.ok(found, "registered for Esc")
  T.ok(box._w >= 322 and box._h >= 182, "at least native size at UI scale 1: " .. box._w .. "x" .. box._h)
  local w, h = ns.UI.ImageViewer.FitSize(512, 512, 0.5, 2000, 2000)
  T.eq(w, 768, "capped at 1.5x"); T.eq(h, 768)
  w, h = ns.UI.ImageViewer.FitSize(512, 256, 1, 300, 300)
  T.eq(w, 300); T.eq(h, 150, "fits the screen")
  ns.UI.ImageViewer.Hide()
end)

T.test("[" .. CONFIG .. "] staged chips: shown above the input, history moves up, remove sends unstage", function()
  local list, row = chips()
  T.eq(#list, 1, "one chip")
  T.ok(row:IsShown(), "chip row shown")
  T.eq(list[1].tex._texture, "Interface\\AddOns\\T3Bridge_Img\\i0004")
  T.eq(list[1].tex._texcoord[2], (16 + 32) / 512, "square crop from the middle (64x32)")
  local _, _, _, _, _, _, chipsShown = ns.UI.ChatInputBar()
  T.ok(chipsShown, "layout accounts for the chip row")
  list[1].close:Click()
  run(1.5)
  T.eq(lastPayload(), "unstage\t" .. IMG_TID .. "\tk1")
  ackImg({ staged = false })
  list = chips()
  T.eq(#list, 0, "chip gone after the companion dropped it")
  T.ok(not row:IsShown(), "row hidden")
end)

T.test("[" .. CONFIG .. "] Ctrl+V in the input sends a quiet clip, debounced; plain V does nothing", function()
  local eb = editBox()
  local before = ns.outbox.nextSeq
  M.fire(eb, "OnKeyDown", "V")
  run(1.5)
  T.eq(ns.outbox.nextSeq, before, "no Ctrl: nothing sent")
  _G.IsControlKeyDown = function() return true end
  M.fire(eb, "OnKeyDown", "V")
  M.fire(eb, "OnKeyDown", "V") -- same second: debounced
  run(1.5)
  T.eq(lastPayload(), "clip\t" .. IMG_TID .. "\t1")
  T.eq(ns.outbox.nextSeq, before + 1, "exactly one clip")
  ackImg({ staged = false })
  M.fire(eb, "OnKeyDown", "V")
  run(1.5)
  T.eq(ns.outbox.nextSeq, before + 2, "accepted again after the debounce")
  _G.IsControlKeyDown = nil
  ackImg({ staged = false })
end)

T.test("[" .. CONFIG .. "] attach menu: MenuUtil, EasyMenu, UIDropDownMenu, or a direct clipboard paste", function()
  local _, attach = ns.UI.ChatInputBar()
  local Chat = ns.UI.Chat
  local built
  _G.MenuUtil = { CreateContextMenu = function(owner, gen)
    built = {}
    local root = { CreateTitle = function(_, t) built[#built + 1] = t end, CreateButton = function(_, t, fn) built[#built + 1] = t; built.fn = built.fn or fn end }
    gen(owner, root)
  end }
  T.eq(Chat.OpenAttachMenu(attach), "menuutil")
  T.eq(built[2], "Paste image from clipboard (Ctrl+V)"); T.eq(built[3], "Attach latest WoW screenshot")
  _G.MenuUtil = nil
  local easy
  _G.EasyMenu = function(items) easy = items end
  local path = Chat.OpenAttachMenu(attach)
  if CONFIG == "modern" or CONFIG == "legacy" then T.eq(path, "easymenu") end
  T.eq(easy[3].text, "Attach latest WoW screenshot")
  _G.EasyMenu = nil
  _G.ToggleDropDownMenu = function() M.toggled = true end
  T.eq(Chat.OpenAttachMenu(attach), "dropdown")
  T.ok(M.toggled)
  _G.ToggleDropDownMenu = nil
  M.advance(1.1)
  T.eq(Chat.OpenAttachMenu(attach), "direct")
  run(1.5)
  T.eq(lastPayload(), "clip\t" .. IMG_TID .. "\t0", "direct paste is not quiet")
  ackImg({ staged = false })
  -- the screenshot item
  built = nil
  _G.MenuUtil = { CreateContextMenu = function(owner, gen)
    local root = { CreateTitle = function() end, CreateButton = function(_, t, fn) if t:find("screenshot") then built = fn end end }
    gen(owner, root)
  end }
  Chat.OpenAttachMenu(attach)
  built()
  run(1.5)
  T.eq(lastPayload(), "shot\t" .. IMG_TID)
  _G.MenuUtil = nil
  ackImg()
end)

T.test("[" .. CONFIG .. "] send with only images staged sends an empty text", function()
  local eb = editBox()
  eb:SetText("")
  eb._scripts.OnEnterPressed(eb)
  run(1.5)
  T.eq(lastPayload(), "send\t" .. IMG_TID .. "\t" .. ns.outbox:SidHex() .. "-" .. (ns.outbox.nextSeq - 1) .. "\t")
  ackImg({ staged = false })
  local before = ns.outbox.nextSeq
  eb:SetText("")
  eb._scripts.OnEnterPressed(eb)
  run(1.5)
  T.eq(ns.outbox.nextSeq, before, "nothing staged + empty text: nothing sent")
end)

T.test("[" .. CONFIG .. "] status bar: 'Images: N left' and short notices", function()
  ackImg({ left = 12, staged = false })
  T.eq(ns.state.snap.imgslots.left, 12)
  local text = ns.State.LinkStatus(ns.state, ns.Now(), { slotsLeft = 100, slotsTotal = 200 })
  T.ok(text:find("Images: 12 left"), text)
  ackImg({ left = 12, staged = false, notice = "No image on the clipboard", nid = 7 })
  T.eq(ns.LinkStatus(), "No image on the clipboard")
  M.advance(ns.NOTICE_S + 0.5)
  T.ok(not ns.LinkStatus():find("clipboard"), "notice expires")
  ackImg({ left = 12, staged = false, notice = "No image on the clipboard", nid = 7 })
  T.ok(not ns.LinkStatus():find("clipboard"), "same notice id is not shown again")
end)

T.test("[" .. CONFIG .. "] /t3 spike img steps, and 'fail' turns images into text placeholders", function()
  M.chat = {}
  T.ok(M.typeChat("/t3 spike img"))
  T.ok(chatHas("step 1/3"))
  T.ok(_G.T3BridgeImgSpike and _G.T3BridgeImgSpike:IsShown(), "swatch window")
  M.chat = {}
  T.ok(M.typeChat("/t3 spike img 2"))
  run(0.2)
  T.ok(chatHas("load time"), "load time measured")
  T.ok(chatHas("spike img ok"), "tells the user what to type")
  local paths = {}
  for _, f in ipairs(M.frames) do if f._otype == "Texture" and f._shown and type(f._texture) == "string" and f._texture:find("T3Bridge_Img") then paths[f._texture] = true end end
  T.ok(paths["Interface\\AddOns\\T3Bridge_Img\\s1"] and paths["Interface\\AddOns\\T3Bridge_Img\\n1"], "swatches s1 and n1 shown")
  T.ok(M.typeChat("/t3 spike img fail"))
  T.eq(T3BridgeDB.img.works, false)
  run(1.5)
  T.eq(lastPayload(), "hello\t1\t0.2.0\t2\t8\t0", "companion told: images off")
  ackImg()
  -- images now render as text
  local textOnly = false
  for _, f in ipairs(M.frames) do if f._otype == "FontString" and f._shown and f._text == "[image: red.png]" then textOnly = true end end
  T.ok(textOnly, "[image: red.png] text placeholder")
  T.eq(#imageButtons(), 0, "no image buttons")
  T.ok(M.typeChat("/t3 spike img ok"))
  T.eq(T3BridgeDB.img.works, true)
  run(1.5)
  T.eq(lastPayload(), "hello\t1\t0.2.0\t2\t8\t1")
  T.ok(M.typeChat("/t3 spike img reload no"))
  T.eq(T3BridgeDB.img.reloadFrees, false)
  T.ok(M.typeChat("/t3 spike img 3"))
  _G.T3BridgeImgSpike:Hide()
  ackImg({ staged = false })
end)

T.test("[" .. CONFIG .. "] minimum window size 420x360: input, attach, send and chips fit", function()
  local f = _G.T3BridgeChatFrame
  f:SetSize(420, 360)
  ackImg()
  local eb, attach, send, row, _, holder, chipsShown = ns.UI.ChatInputBar()
  T.ok(chipsShown and row:IsShown(), "chips shown at minimum size")
  local _, rel, _, x = holder:GetPoint(2)
  T.eq(x, -128, "input leaves room for attach (24) + send (80)")
  T.eq(select(2, attach:GetPoint(1)), holder)
  T.eq(select(2, send:GetPoint(1)), attach)
  T.ok(420 - 12 - 128 >= 260, "input box keeps >= 260 px")
  f:SetSize(520, 560)
  ackImg({ staged = false })
end)

---------------------------------------------------------------------------------------------
-- rev 1.4: subagent threads (Up button, breadcrumb, Subagents strip, thread links, menu, tracker)
---------------------------------------------------------------------------------------------
local PARENT_TITLE = "Fix flaky login test in auth.spec.ts"
local CHILD_TITLE = "Check the other login() callers"

--- Snapshot mutation: the companion focuses subagent c1d2e3f4 of a1b2c3d4 (it is listed with parent=).
local function childFocus(s, extra)
  local base = s.focus
  s.threads[#s.threads + 1] = { id = "c1d2e3f4", title = CHILD_TITLE, st = "completed", t0 = 1000, t1 = 1060, parent = "a1b2c3d4" }
  s.focus = { id = "c1d2e3f4", model = base.model, effort = base.effort, models = base.models, streaming = false,
    parent = { id = "a1b2c3d4", title = PARENT_TITLE },
    path = { { id = "a1b2c3d4", title = PARENT_TITLE }, { id = "c1d2e3f4", title = CHILD_TITLE } },
    msgs = { { i = 1, r = "u", ts = 1000, segs = { { "p", "Find every caller of login()" } }, more = false } } }
  if extra then extra(s) end
end

local function subagentPieces() return ns.UI.ChatSubagents() end

local function linkButton(tid)
  for _, fr in ipairs(M.frames) do
    if fr._otype == "Button" and fr._shown and fr.tid == tid and fr.line then return fr end
  end
end

T.test("[" .. CONFIG .. "] subagents: strip lists the kids, a click opens one, Up and the breadcrumb lead back", function()
  ns.UI.OpenChat("a1b2c3d4")
  settle()
  T.eq(ns.selected, "a1b2c3d4")
  local up, crumb, crumbBtns, kids, kidRows, head = subagentPieces()
  T.ok(not up:IsShown(), "no Up button on a top-level thread")
  T.ok(not crumb:IsShown(), "no breadcrumb on a top-level thread")
  T.ok(kids:IsShown(), "Subagents strip shown")
  T.eq(head.text:GetText(), "Subagents (2)")
  T.ok(not (kidRows[1] and kidRows[1]:IsShown()), "collapsed by default")
  head:Click()
  T.eq(T3BridgeDB.chat.kidsOpen, true)
  T.ok(kidRows[1]:IsShown() and kidRows[2]:IsShown(), "two subagent rows")
  T.eq(kidRows[1].title:GetText(), CHILD_TITLE)
  T.eq(kidRows[1].icon._texture, ns.State.STATUS.completed.icon, "tracker icon for done")
  local _, insetRel, _, _, insetY = ns.UI.ChatView().scroll:GetParent():GetPoint(1)
  T.ok(insetY < -64, "history starts below the strip: " .. tostring(insetY))
  -- click a subagent: the chat switches to it and asks the companion to focus it
  kidRows[1]:Click()
  T.eq(ns.selected, "c1d2e3f4")
  settle(childFocus)
  T.eq(ns.state.snap.focus.id, "c1d2e3f4")
  T.ok(up:IsShown(), "Up button shown on a subagent")
  T.ok(crumb:IsShown(), "breadcrumb shown")
  T.eq(crumbBtns[1].tid, "a1b2c3d4"); T.eq(crumbBtns[2].tid, "c1d2e3f4")
  T.ok(crumbBtns[1].text:GetText():find("Fix flaky", 1, true))
  T.ok(not kids:IsShown(), "no strip: the subagent has no kids")
  local tdd = ns.UI.ChatTopBar()
  local _, _, _, ddx = tdd.frame:GetPoint(1)
  local diag = ns.UI.ChatDiagnostics()
  local left = (diag == "PortraitFrameTemplate") and 60 or ((diag == "BasicFrameTemplateWithInset") and 12 or 16)
  T.eq(ddx, left + 26 - (tdd.modern and 0 or 16), "thread dropdown moved right of the Up button")
  T.ok(ns.State.Thread(ns.state, "c1d2e3f4"), "the focused subagent is listed")
  T.eq(#ns.state.snap.threads, 7, "but not as a top-level tracker row")
  -- breadcrumb: the parent segment opens the parent
  crumbBtns[1]:Click()
  T.eq(ns.selected, "a1b2c3d4")
  settle()
  T.ok(not up:IsShown())
  -- Up button and /t3 up
  ns.SelectThread("c1d2e3f4")
  settle(childFocus)
  up:Click()
  T.eq(ns.selected, "a1b2c3d4", "Up = focus the parent")
  settle()
  M.chat = {}
  SlashCmdList.T3BRIDGE("up")
  T.ok(chatHas("not a subagent"), "/t3 up on a top-level thread explains")
  ns.SelectThread("c1d2e3f4")
  settle(childFocus)
  SlashCmdList.T3BRIDGE("up")
  T.eq(ns.selected, "a1b2c3d4", "/t3 up")
  settle()
  T3BridgeDB.chat.kidsOpen = nil
end)

T.test("[" .. CONFIG .. "] thread links: tl segments render link-coloured; click opens that thread", function()
  ns.UI.OpenChat("a1b2c3d4")
  settle()
  local b = linkButton("c2d3e4f5")
  T.ok(b, "link button for the 'Delegated task ... finished' line")
  T.ok(b.text:GetText():find("Delegated task", 1, true), b.text:GetText())
  T.ok(b.text:GetText():find("^\194\187 "), "starts with the link arrow")
  local c = ns.UI.Messages.LINK_COLOR
  T.eq(b.text._textColor and b.text._textColor[1], c[1], "link colour")
  b._scripts.OnEnter(b)
  T.ok(b.line:IsShown(), "hover underline")
  b._scripts.OnLeave(b)
  T.ok(not b.line:IsShown())
  T.ok(linkButton("c1d2e3f4"), "subagent link inside a tool message")
  b:Click()
  T.eq(ns.selected, "c2d3e4f5", "click opened the linked thread")
  settle(function(s)
    childFocus(s, function(x)
      x.threads[#x.threads].id, x.threads[#x.threads].title = "c2d3e4f5", "Write the regression test"
      x.focus.id = "c2d3e4f5"
      x.focus.path[2] = { id = "c2d3e4f5", title = "Write the regression test" }
    end)
  end)
  T.ok((ns.UI.ChatSubagents()):IsShown(), "Up button")
  ns.UI.Chat.Up()
  T.eq(ns.selected, "a1b2c3d4")
  settle()
end)

T.test("[" .. CONFIG .. "] thread menu: subagents are indented under their parent", function()
  ns.UI.OpenChat("a1b2c3d4")
  settle()
  local items = ns.State.ThreadMenu(ns.state)
  local seen = {}
  for _, g in ipairs(items) do for _, it in ipairs(g.items) do seen[it.t.id] = it.depth end end
  T.eq(seen.a1b2c3d4, 0); T.eq(seen.c1d2e3f4, 1, "kid of the focused thread"); T.eq(seen.d1e2f3a4, 1, "kid from subs")
  local label = ns.UI.Chat.ThreadLabel(ns.State.Thread(ns.state, "d1e2f3a4"), 1)
  T.ok(label:find(" - |r", 1, true), "ASCII indent marker: " .. label)
  T.ok(not label:find("\226\134\179", 1, true), "no U+21B3 arrow (missing from WoW fonts)")
  if CONFIG == "modern" then
    local tdd = ns.UI.ChatTopBar()
    local rs = radios(tdd.frame)
    local idx = {}
    for k, r in ipairs(rs) do idx[r.data] = k end
    T.ok(idx.c1d2e3f4 == idx.a1b2c3d4 + 1, "kid right under its parent")
    T.ok(idx.d1e2f3a4 > idx.b2c3d4e5, "subs under their parent")
    rs[idx.d1e2f3a4].onSel()
    T.eq(ns.selected, "d1e2f3a4")
    settle()
    ns.UI.OpenChat("a1b2c3d4")
    settle()
  end
end)

T.test("[" .. CONFIG .. "] tracker: subagent badge, badge lists child rows, child row opens, needs-you expands", function()
  local TR = ns.UI.Tracker
  applyFixture()
  T.eq(TR.shown, 7, "kids collapsed by default")
  local row = trackerRowFor("b2c3d4e5")
  T.ok(row.kidsBtn:IsShown(), "badge on a row with subagents")
  T.eq(row.kidsBtn.text:GetText(), "1 running")
  T.eq(trackerRowFor("a1b2c3d4").kidsBtn.text:GetText(), "+2")
  T.ok(not trackerRowFor("c3d4e5f6").kidsBtn:IsShown(), "no badge without subagents")
  row.kidsBtn:Click()
  T.eq(T3BridgeDB.tracker.kids.b2c3d4e5, true, "saved by thread id")
  T.eq(TR.shown, 10, "three child rows")
  local kid = trackerRowFor("d1e2f3a4")
  T.ok(kid and kid.child, "child row")
  T.eq(select(4, kid:GetPoint(1)), 14, "indented")
  T.ok(not kid.toggle:IsShown(), "no collapse toggle on a child row")
  T.eq(kid.icon._texture, ns.State.STATUS.running.icon)
  T.eq(trackerRowFor("d3e4f5a6").icon._texture, ns.State.STATUS.failed.icon)
  kid:Click("LeftButton")
  T.eq(ns.selected, "d1e2f3a4", "child row opens the subagent")
  settle()
  -- collapsing the parent row hides its kids
  trackerRowFor("b2c3d4e5"):Click("RightButton")
  T.eq(trackerRowFor("d1e2f3a4"), nil, "hidden under a collapsed row")
  trackerRowFor("b2c3d4e5").toggle:Click()
  trackerRowFor("b2c3d4e5").kidsBtn:Click()
  T.eq(T3BridgeDB.tracker.kids.b2c3d4e5, nil)
  T.eq(TR.shown, 7)
  -- a subagent that needs you shows its row by itself, and the badge says so
  applyFixture(function(s)
    s.threads[2].kidsNeed = 1
    s.subs[1].need = "approval"
  end)
  T.eq(trackerRowFor("b2c3d4e5").kidsBtn.text:GetText(), "- 1 needs you")
  T.ok(trackerRowFor("d1e2f3a4"), "auto-shown")
  T.ok(trackerRowFor("d1e2f3a4").pulse:IsPlaying(), "needs-you pulse")
  applyFixture()
  T.eq(TR.shown, 7)
end)

T.test("[" .. CONFIG .. "] subagents at the minimum window size 420x360: breadcrumb truncates, strip fits", function()
  local C = ns.UI.Chat
  -- pure breadcrumb fit
  local w = C.FitCrumbs({ 300, 280, 260 }, 14, 340, 30)
  local sum = w[1] + w[2] + w[3] + 2 * 14
  T.ok(sum <= 340, "fits: " .. sum)
  T.ok(w[3] >= 80, "current thread keeps room: " .. w[3])
  T.ok(w[1] >= 30 and w[2] >= 30, "ancestors >= 30 px")
  local same = C.FitCrumbs({ 50, 60 }, 14, 340, 30)
  T.eq(same[1], 50); T.eq(same[2], 60)
  T.eq(C.KidRowsFit(360, 16), 3)
  T.eq(C.KidRowsFit(560, 0), 8)
  local f = _G.T3BridgeChatFrame
  f:SetSize(420, 360)
  T3BridgeDB.chat.kidsOpen = true
  local long = string.rep("A very long thread title ", 4)
  local mut = function(s)
    childFocus(s, function(x)
      x.focus.path = { { id = "a1b2c3d4", title = long }, { id = "zz000001", title = long }, { id = "c1d2e3f4", title = long } }
      x.focus.parent = { id = "zz000001", title = long }
      x.focus.kids, x.focus.nkids = {}, 9
      for k = 1, 9 do x.focus.kids[k] = { id = string.format("k%07d", k), title = "Kid " .. k, st = (k == 1) and "running" or "completed", t0 = 1000 } end
    end)
  end
  ns.SelectThread("c1d2e3f4")
  settle(mut)
  C.Refresh()
  local up, crumb, crumbBtns, kids, kidRows, head, widths, kidsShown = subagentPieces()
  T.ok(up:IsShown() and crumb:IsShown() and kids:IsShown())
  T.eq(#widths, 3)
  local diag = ns.UI.ChatDiagnostics()
  local left = (diag == "PortraitFrameTemplate") and 60 or ((diag == "BasicFrameTemplateWithInset") and 12 or 16)
  local total = widths[1] + widths[2] + widths[3]
  T.ok(total <= 420 - left - 16, "breadcrumb fits 420 px: " .. total)
  T.eq(kidsShown, 3, "two kid rows + '7 more...' at 360 px")
  T.eq(kidRows[3].title:GetText(), "7 more...")
  T.eq(head.text:GetText(), "Subagents (9" .. ns.State.DOT .. "1 running)")
  -- the history keeps room between the strip and the input
  local _, _, _, _, insetY = ns.UI.ChatView().scroll:GetParent():GetPoint(1)
  local bottomUsed = 6 + 18 + 4 + 60 + 6
  T.ok(360 + insetY - bottomUsed >= 60, "history keeps >= 60 px: " .. (360 + insetY - bottomUsed))
  f:SetSize(520, 560)
  T3BridgeDB.chat.kidsOpen = nil
  ns.SelectThread("a1b2c3d4")
  settle()
end)

T.test("[" .. CONFIG .. "] demo mode: subagent threads, Up and the breadcrumb", function()
  SlashCmdList.T3BRIDGE("demo")
  T.eq(ns.demo, true)
  ns.UI.Tracker.ToggleKids("b2c3d4e5")
  local kid = trackerRowFor("d1e2f3a4")
  T.ok(kid, "demo subagent row")
  kid:Click("LeftButton")
  T.eq(ns.selected, "d1e2f3a4")
  local up, crumb, crumbBtns = subagentPieces()
  T.ok(up:IsShown() and crumb:IsShown(), "Up + breadcrumb in demo")
  T.eq(crumbBtns[1].tid, "b2c3d4e5")
  up:Click()
  T.eq(ns.selected, "b2c3d4e5")
  T.ok(linkButton("d1e2f3a4"), "demo parent history links its subagents")
  ns.UI.Tracker.ToggleKids("b2c3d4e5")
  SlashCmdList.T3BRIDGE("demo")
  T.eq(ns.demo, false)
end)

T.test("[" .. CONFIG .. "] saved variables hold no message text", function()
  local function scan(t, depth)
    for k, v in pairs(t) do
      if type(v) == "string" then T.ok(#v < 64, "short string in DB: " .. tostring(k)) end
      if type(v) == "table" and depth < 4 then scan(v, depth + 1) end
    end
  end
  scan(T3BridgeDB, 0)
end)

T.test("[" .. CONFIG .. "] no Lua error reached the default error handler", function()
  T.eq(#M.errors, 0, M.errors[1])
end)

T.test("[" .. CONFIG .. "] report unmodelled API methods (review list)", function()
  local list = {}
  for k in pairs(M.unknown) do list[#list + 1] = k end
  table.sort(list)
  SMOKE_UNKNOWN = table.concat(list, ", ")
end)
