-- T3Bridge Spike: in-game PASS/FAIL checks for the Phase 0 unknowns that only the real client can answer.
--   /t3 spike s1         live-file reload via load-on-demand slots (variants A and B), growth, torn files
--   /t3 spike s1 combat  the same load while in combat
--   /t3 spike s2         outbound matrix geometry + test frames for the capture helper
--   /t3 spike fonts      does the bundled monospace font load?
--   /t3 spike templates  which UI templates / APIs exist on this client
--   /t3 spike img        image slot textures (rev 1.3), see the IMG section at the end
local _, ns = ...
local Compat, Codec = ns.Compat, ns.Codec

local Spike = {}
ns.Spike = Spike

ns.MONO_FONT = "Interface\\AddOns\\T3Bridge\\Media\\mono.ttf"

local function out(msg) ns.Print(msg) end
local function pass(label, detail) out("|cff20ff20PASS|r " .. label .. (detail and ("  |cffaaaaaa" .. detail .. "|r") or "")) end
local function fail(label, detail) out("|cffff3030FAIL|r " .. label .. (detail and ("  |cffaaaaaa" .. detail .. "|r") or "")) end
local function info(label, detail) out("|cffffd100INFO|r " .. label .. (detail and ("  |cffaaaaaa" .. detail .. "|r") or "")) end

--- Wrap a timer/event callback so a Lua error prints a FAIL line instead of vanishing
--- (WoW hides Lua errors by default).
local function guarded(label, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then
      ns.Debug(label .. " error: " .. tostring(err))
      fail(label .. " (Lua error)", Compat.Escape(tostring(err):sub(1, 160)))
    end
  end
end
Spike.guarded = guarded

---------------------------------------------------------------------------------------------
-- S1: inbound live file
---------------------------------------------------------------------------------------------
local function freeSlots(pattern)
  local list = {}
  for i = 1, Compat.GetNumAddOns() do
    local name = Compat.GetAddOnInfo(i)
    local n = name and name:match(pattern)
    if n and not Compat.IsAddOnLoaded(name) then list[#list + 1] = { name = name, n = tonumber(n) } end
  end
  table.sort(list, function(a, b) return a.n < b.n end)
  local names = {}
  for k, s in ipairs(list) do names[k] = s.name end
  return names
end

local SPIKE_GLOBALS = { "T3B_SPIKE", "T3B_SPIKE_TAIL" }
local GROW_MIN = 65536 -- the -Spike -Loop writer grows the file past this size; the install-time file is ~1 KB

local function newResult(slots)
  return { slots = slots, next = 1, loads = 0, loadFail = 0, reason = nil, swallowed = 0, good = 0,
    corrupt = 0, empty = 0, seqs = {}, minSeq = nil, maxSeq = nil, maxSize = 0, ms = 0, firstErr = nil }
end

local function loadOne(res)
  local name = res.slots[res.next]
  if not name then return false end
  res.next = res.next + 1
  local r = ns.Inbound.LoadSlot(name, SPIKE_GLOBALS)
  res.loads, res.ms = res.loads + 1, res.ms + r.ms
  if not r.loaded then res.loadFail, res.reason = res.loadFail + 1, r.reason end
  res.swallowed = res.swallowed + #r.caught
  if #r.caught > 0 and not res.firstErr then res.firstErr = r.caught[1] end
  local sp, tail = r.values.T3B_SPIKE, r.values.T3B_SPIKE_TAIL
  if type(sp) == "table" and type(sp.seq) == "number" and tail == sp.seq then
    res.good = res.good + 1
    res.minSeq = math.min(res.minSeq or sp.seq, sp.seq)
    res.maxSeq = math.max(res.maxSeq or sp.seq, sp.seq)
    res.maxSize = math.max(res.maxSize, tonumber(sp.size) or 0)
  elseif #r.caught > 0 or type(sp) == "table" then
    res.corrupt = res.corrupt + 1
  else
    res.empty = res.empty + 1
  end
  return true
end

local function reportVariant(tag, res)
  if #res.slots == 0 and res.loads == 0 then
    fail("S1-" .. tag .. " slots installed", "no free T3Bridge_T" .. tag .. "## addons (install-addon.ps1 creates them; /reload frees used ones)")
    return
  end
  local avg = res.loads > 0 and string.format("%.1f ms avg", res.ms / res.loads) or ""
  if res.good > 0 then
    pass("S1-" .. tag .. " load works", string.format("%d loads, %d good, %s", res.loads, res.good, avg))
  else
    fail("S1-" .. tag .. " load works", string.format("%d loads, 0 good (load failures %d%s; errors %d%s)", res.loads,
      res.loadFail, res.reason and (", reason " .. tostring(res.reason)) or "", res.swallowed,
      res.firstErr and (": " .. Compat.Escape(res.firstErr:sub(1, 90))) or ""))
    return
  end
  if res.maxSeq and res.maxSeq > res.minSeq then
    pass("S1-" .. tag .. " edits after login are picked up", string.format("seq %d -> %d", res.minSeq, res.maxSeq))
  elseif res.maxSeq == 0 then
    fail("S1-" .. tag .. " edits after login are picked up", "still the install-time file (seq 0): is 'set-live-file.ps1 -Spike -Loop' running?")
  else
    fail("S1-" .. tag .. " edits after login are picked up", "seq never changed (" .. tostring(res.maxSeq) .. "): is the -Loop writer running?")
  end
  if res.maxSize >= GROW_MIN then
    pass("S1-" .. tag .. " file can grow after login", string.format("read a %d KB file", math.floor(res.maxSize / 1024)))
  elseif res.corrupt > 0 and res.maxSeq and res.maxSeq > 0 then
    fail("S1-" .. tag .. " file can grow after login", "large files never read cleanly: keep the companion's fixed-size padding ON")
  else
    info("S1-" .. tag .. " file growth", "inconclusive (largest clean read " .. res.maxSize .. " bytes)")
  end
end

local s1
function Spike.S1(arg)
  if arg == "combat" then return Spike.S1Combat() end
  if s1 and s1.running then info("S1", "already running, wait for its result lines") return end
  local A = freeSlots("^T3Bridge_TA(%d%d)$")
  local B = freeSlots("^T3Bridge_TB(%d%d)$")
  out(string.format("S1: started. %d variant-A and %d variant-B spike slots free. Running for ~20 s...", #A, #B))
  if #A == 0 and #B == 0 then
    fail("S1 spike slots", "none free. Close WoW, run scripts\\install-addon.ps1, start WoW (or /reload if they were used up).")
    return
  end
  s1 = { running = true, A = newResult(A), B = newResult(B), round = 0 }
  local ticker, step
  ticker = Compat.NewTicker(2, function()
    local ok, err = pcall(step)
    if not ok then
      ticker:Cancel()
      s1.running = false
      fail("S1 (Lua error)", Compat.Escape(tostring(err):sub(1, 160)))
    end
  end)
  step = function()
    s1.round = s1.round + 1
    local a = loadOne(s1.A)
    local b = loadOne(s1.B)
    if s1.round >= 10 or (not a and not b) then
      ticker:Cancel()
      s1.running = false
      out("S1 results:")
      reportVariant("A", s1.A)
      reportVariant("B", s1.B)
      local corrupt = s1.A.corrupt + s1.B.corrupt
      if corrupt > 0 then
        pass("S1 torn/corrupt file handled silently", string.format("%d torn read(s) caught by the error handler. If a red Lua error window appeared, report FAIL.", corrupt))
      else
        info("S1 torn file", "no torn read happened this run (the -Loop writer makes one every 4th write); run again to see one")
      end
      local function ok(r) return r.good > 0 and r.maxSeq ~= nil and r.maxSeq > r.minSeq end
      if ok(s1.A) or ok(s1.B) then
        pass("S1 overall", "working variant(s): " .. (ok(s1.A) and "A " or "") .. (ok(s1.B) and "B" or ""))
      else
        fail("S1 overall", "no variant picked up live edits (see lines above)")
      end
      out("S1 done. Next: '/t3 spike s1 combat' (needs a fresh slot: /reload first if all were used).")
    end
  end
end

local combatArmed = false
function Spike.S1Combat()
  combatArmed = true
  out("S1 combat: started (armed). Now start a fight (for example attack a training dummy or any enemy creature).")
  out("The check runs automatically when combat starts.")
end

ns.On("combat", guarded("S1 combat load", function()
  if not combatArmed then return end
  combatArmed = false
  local inLockdown = InCombatLockdown and InCombatLockdown() or false
  -- Try the variant that worked in the last S1 run first, then the other one.
  local order = { "A", "B" }
  if s1 and s1.A and s1.B and s1.A.good == 0 and s1.B.good > 0 then order = { "B", "A" } end
  local res, used
  for _, v in ipairs(order) do
    local r = newResult(freeSlots("^T3Bridge_T" .. v .. "(%d%d)$"))
    if #r.slots > 0 then
      loadOne(r)
      res, used = r, v
      if r.good > 0 then break end
    end
  end
  if not res then fail("S1 combat load", "no free spike slots (/reload, then try again)") return end
  if res.good > 0 then
    pass("S1 combat load", string.format("variant %s loaded in combat (lockdown=%s, %.1f ms)", used, tostring(inLockdown), res.ms))
  else
    fail("S1 combat load", string.format("lockdown=%s, reason=%s, errors=%d%s", tostring(inLockdown), tostring(res.reason),
      res.swallowed, res.firstErr and (": " .. Compat.Escape(res.firstErr:sub(1, 90))) or ""))
  end
end))

---------------------------------------------------------------------------------------------
-- S2: outbound matrix
---------------------------------------------------------------------------------------------
-- Same messages as addon/T3Bridge/test/vectors_spec.lua, so the capture helper can compare its
-- decode against protocol/vectors/<name>.json.
local SID = "9f3a01c2"
local function s2Cases()
  local cmd = Codec.BuildCommand
  return {
    { name = "hello_c1", seq = 1, cell = 1, msg = cmd("hello", "1", "0.1.0", "1", "8") },
    { name = "focus_c2", seq = 2, cell = 2, msg = cmd("focus", "a1b2c3d4") },
    { name = "intr_c4", seq = 7, cell = 4, msg = cmd("intr", "b2c3d4e5") },
    { name = "boundary_207_c2", seq = 10, cell = 2,
      msg = cmd("send", "a1b2c3d4", SID .. "-10", string.rep("b", 207 - #("send\ta1b2c3d4\t" .. SID .. "-10\t"))) },
  }
end

function Spike.S2(holdMs)
  out("S2: started")
  if not ns.Outbound then fail("S2", "outbound module missing") return end
  if ns.Outbound.IsBusy() then fail("S2", "a send is in progress, try again in a moment") return end
  holdMs = tonumber(holdMs) or 3000
  local cases = s2Cases()
  local k = 0
  local allGeom = true
  local nextCase
  nextCase = guarded("S2", function()
    k = k + 1
    local c = cases[k]
    if not c then
      if allGeom then pass("S2 geometry (all sizes)") else fail("S2 geometry", "see lines above") end
      out("S2 done. The capture helper should have decoded: hello_c1, focus_c2, intr_c4, boundary_207_c2.")
      out("Compare with protocol\\vectors\\*.json. Current outbound cell size: " .. ns.db.cell .. " (change with /t3 cell 1||2||4).")
      return
    end
    local frames, rows = Codec.FramesForMessage(Codec.FromHex(SID), c.seq, c.msg, 0)
    local selfOk = true
    for _, fr in ipairs(frames) do
      local p = Codec.ParseFrame(Codec.CellsToBytes(Codec.CellStrings(fr, rows)))
      selfOk = selfOk and p ~= nil
    end
    out(string.format("S2 showing %s: cell %d px, %d rows, %d frame(s), %.1f s each...", c.name, c.cell, rows, #frames, holdMs / 1000))
    ns.Outbound.ShowTest(frames, rows, c.cell, holdMs, function() Compat.After(0.5, nextCase) end)
    Compat.After(0.3, guarded("S2 " .. c.name, function()
      local m = ns.Outbound.Matrix()
      local g = ns.Outbound.geometry
      local es = m:GetEffectiveScale()
      local ppu = es * g.h / 768
      local left, top, w, h = m:GetLeft(), m:GetTop(), m:GetWidth(), m:GetHeight()
      local okScale = math.abs(ppu - 1) < 0.002
      local okPos = left and top and math.abs(left) < 0.01 and math.abs(top - g.h) < 0.01
      local okSize = math.abs(w - 256 * c.cell) < 0.01 and math.abs(h - rows * c.cell) < 0.01
      local detail = string.format("screen %dx%d via %s; 1 unit = %.4f px; left=%.2f top=%.2f (want 0, %d); %dx%d px",
        g.w, g.h, g.method, ppu, left or -1, top or -1, g.h, w, h)
      if okScale and okPos and okSize and selfOk then pass("S2 " .. c.name, detail) else
        allGeom = false
        fail("S2 " .. c.name, detail .. (selfOk and "" or "; self-decode failed"))
      end
    end))
  end)
  info("S2", "test matrices will flash in the top-left corner (start the bridge first to test decoding).")
  nextCase()
end

---------------------------------------------------------------------------------------------
-- Fonts
---------------------------------------------------------------------------------------------
-- Root cause of "/t3 spike fonts does nothing" (Phase 1): the probe FontString was created
-- without a font object. When SetFont(mono.ttf) fails on the client, the FontString has no font
-- at all and SetText() raises "Font not set". That error escaped the slash handler, and WoW's
-- chat edit box then aborts its Enter handling silently (Lua errors are hidden by default):
-- the line stays in the box and nothing prints. Every font string here now starts from a
-- working font object and every client call is protected.
local function newProbe()
  local fs = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if fs.SetFontObject and _G.GameFontNormal then pcall(fs.SetFontObject, fs, _G.GameFontNormal) end
  fs:Hide()
  return fs
end

local function monoCheck(fs)
  local ok, w1, w2 = pcall(function()
    fs:SetText("iiiiiiiiiiiiiiii")
    local a = fs:GetStringWidth() or 0
    fs:SetText("MMMMMMMMMMMMMMMM")
    return a, fs:GetStringWidth() or 0
  end)
  if not ok then return false, 0, 0, w1 end
  return w1 > 0 and math.abs(w1 - w2) < 0.75, w1, w2
end

local probe
--- Returns setFontOk (pcall), setFontReturn, GetFont path, mono, w1, w2, err
local function probeFont()
  probe = probe or newProbe()
  local okSet, ret = pcall(probe.SetFont, probe, ns.MONO_FONT, 13, "")
  local okGet, got = pcall(probe.GetFont, probe)
  -- Only a font string that really uses mono.ttf counts (a failed SetFont keeps the old font).
  local usesMono = okSet and ret ~= false and okGet and type(got) == "string" and got:lower():find("mono%.ttf") ~= nil
  local mono, w1, w2, err = monoCheck(probe)
  if not okSet then err = ret; ret = nil end
  return okSet, ret, okGet and got or nil, (usesMono and mono) and true or false, w1, w2, err
end

--- Silent check used at login: code blocks use the bundled font only if it really renders monospace.
function Spike.DetectMono()
  local ok, _, _, _, mono = pcall(probeFont)
  ns.monoFontOk = (ok and mono) and true or false
  return ns.monoFontOk
end

function Spike.Fonts()
  out("fonts: started (checks the bundled monospace font used for code blocks)")
  local badRet, badOk
  do
    local bad = newProbe()
    badOk, badRet = pcall(bad.SetFont, bad, "Interface\\AddOns\\T3Bridge\\Media\\no-such-font.ttf", 13, "")
    if not badOk then badRet = "error" end
  end
  local okSet, ret, got, mono, w1, w2, err = probeFont()
  info("fonts", string.format("SetFont(missing file) -> %s; SetFont(mono.ttf) -> %s; GetFont = %s",
    tostring(badRet), okSet and tostring(ret) or "error", Compat.Escape(tostring(got))))
  if err then info("fonts", "client error: " .. Compat.Escape(tostring(err):sub(1, 120))) end
  local function verdict(when, m, a, b)
    if m then
      pass("fonts: bundled monospace font loads (" .. when .. ")", string.format("widths %.1f vs %.1f", a, b))
    else
      fail("fonts: bundled monospace font (" .. when .. ")",
        string.format("not used (widths %.1f vs %.1f). Not serious: code blocks use the normal chat font.", a or 0, b or 0))
    end
  end
  verdict("now", mono, w1, w2)
  Compat.After(2, function()
    local ok, r = pcall(function()
      local _, _, _, m2, a2, b2 = probeFont()
      verdict("after 2 s", m2, a2, b2)
      Spike.DetectMono()
    end)
    if not ok then fail("fonts (after 2 s)", Compat.Escape(tostring(r):sub(1, 120))) end
    out("fonts: done")
  end)
end

---------------------------------------------------------------------------------------------
-- Templates / APIs
---------------------------------------------------------------------------------------------
function Spike.Templates()
  out("templates: started")
  local templates = {
    "PortraitFrameTemplate", "BasicFrameTemplateWithInset", "BackdropTemplate", "InsetFrameTemplate",
    "ScrollFrameTemplate", "UIPanelScrollFrameTemplate", "WowScrollBox", "MinimalScrollBar",
    "InputScrollFrameTemplate", "T3BridgeInputScrollTemplate", "UIPanelButtonTemplate", "UIPanelCloseButton",
    "WowStyle1DropdownTemplate", "UIDropDownMenuTemplate",
  }
  local have = {}
  for _, t in ipairs(templates) do
    have[t] = Compat.TemplateExists(t)
    out(string.format("  %s %s", have[t] and "|cff20ff20yes|r" or "|cffff3030no |r", t))
  end
  local apis = {
    { "C_AddOns.LoadAddOn", _G.C_AddOns and _G.C_AddOns.LoadAddOn },
    { "LoadAddOn (global)", _G.LoadAddOn },
    { "GetPhysicalScreenSize", _G.GetPhysicalScreenSize },
    { "Frame:SetIgnoreParentScale", UIParent.SetIgnoreParentScale },
    { "C_XMLUtil.GetTemplateInfo", _G.C_XMLUtil and _G.C_XMLUtil.GetTemplateInfo },
    { "MenuUtil", _G.MenuUtil },
    { "AddonCompartmentFrame", _G.AddonCompartmentFrame },
    { "C_Timer.NewTicker", _G.C_Timer and _G.C_Timer.NewTicker },
    { "bit library", _G.bit and _G.bit.bxor },
    { "seterrorhandler", _G.seterrorhandler },
    { "debugprofilestop", _G.debugprofilestop },
    { "SetResizeBounds", UIParent.SetResizeBounds },
  }
  for _, a in ipairs(apis) do out(string.format("  %s %s", a[2] and "|cff20ff20yes|r" or "|cffff3030no |r", a[1])) end
  info("codec", "CRC backend: " .. tostring(Codec.bitMode) .. ", self-test " .. (Codec.selfTestOk and "ok" or "FAILED"))
  local chat, input, dropdown = ns.UI.ChatDiagnostics and ns.UI.ChatDiagnostics()
  if chat then info("chat window uses", tostring(chat) .. ", input " .. tostring(input) .. ", dropdown " .. tostring(dropdown)) end
  -- every UI element has at least one working option
  local chains = {
    { "chat window", { "PortraitFrameTemplate", "BasicFrameTemplateWithInset", "BackdropTemplate" } },
    { "history scroll", { "ScrollFrameTemplate", "UIPanelScrollFrameTemplate" } },
    { "buttons", { "UIPanelButtonTemplate" } },
    { "dropdowns", { "WowStyle1DropdownTemplate", "UIDropDownMenuTemplate" } },
  }
  local allOk = true
  for _, c in ipairs(chains) do
    local okAny = false
    for _, t in ipairs(c[2]) do okAny = okAny or have[t] or (t == "BackdropTemplate") end
    allOk = allOk and okAny
    if not okAny then fail("templates: " .. c[1], "none of " .. table.concat(c[2], ", ")) end
  end
  if allOk then pass("templates: every UI element has a usable template")
  else fail("templates", "some UI element has no usable template (see above)") end
end

ns.On("login", function() Compat.After(2, Spike.DetectMono) end)

---------------------------------------------------------------------------------------------
-- IMG: image slot textures (PROTOCOL rev 1.3, D16). The addon cannot read pixels, so it shows
-- swatches labelled with the colour each SHOULD have and the user confirms by eye.
--   /t3 spike img            step 1: show s2 (loads it into the texture cache), then run the script
--   /t3 spike img 2          step 2: s1 new-before-first-load, s2 overwrite-after-load, s3 orientation,
--                            n1 new file after start, t1 folder with a TOC, load time
--   /t3 spike img 3          after "spike-image-slots.ps1 -Step 2" and /reload: does /reload free textures?
--   /t3 spike img ok|fail    record whether inline images work (fail = images shown as text)
--   /t3 spike img reload yes|no   record the /reload result
-- scripts\spike-image-slots.ps1 writes the colours while WoW runs (the files exist since install).
---------------------------------------------------------------------------------------------
local IMG_DIR = "Interface\\AddOns\\T3Bridge_Img\\"
local IMGT_DIR = "Interface\\AddOns\\T3Bridge_ImgT\\"
local ICON = "Interface\\AddOns\\T3Bridge\\Media\\icon"
local SW = 88
local imgFrame, imgCells = nil, {}

local function imgWindow()
  if imgFrame then return imgFrame end
  local tmpl = Compat.FirstTemplate({ "BasicFrameTemplateWithInset" })
  imgFrame = CreateFrame("Frame", "T3BridgeImgSpike", UIParent, tmpl or Compat.BackdropTemplate())
  imgFrame:SetSize(6 * (SW + 12) + 20, SW + 96)
  imgFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  imgFrame:SetFrameStrata("DIALOG")
  imgFrame:SetMovable(true)
  imgFrame:EnableMouse(true)
  imgFrame:SetScript("OnMouseDown", function(self) self:StartMoving() end)
  imgFrame:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)
  table.insert(UISpecialFrames, "T3BridgeImgSpike")
  if not tmpl and imgFrame.SetBackdrop then
    imgFrame:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    local close = CreateFrame("Button", nil, imgFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
  end
  imgFrame.title = imgFrame.TitleText or imgFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if not imgFrame.TitleText then imgFrame.title:SetPoint("TOP", 0, -10) end
  for k = 1, 6 do
    local c = CreateFrame("Frame", nil, imgFrame)
    c:SetSize(SW, SW)
    c:SetPoint("TOPLEFT", imgFrame, "TOPLEFT", 14 + (k - 1) * (SW + 12), -34)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetColorTexture(0.15, 0.15, 0.15, 1)   -- an "empty" (transparent) texture looks like this
    c.bg:SetAllPoints(c)
    c.tex = c:CreateTexture(nil, "ARTWORK")
    c.tex:SetAllPoints(c)
    c.name = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.name:SetPoint("TOP", c, "BOTTOM", 0, -3)
    c.want = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    c.want:SetPoint("TOP", c.name, "BOTTOM", 0, -2)
    c.want:SetWidth(SW + 10)
    imgCells[k] = c
  end
  return imgFrame
end

--- cells = { { name, path, want, coords = {l,r,t,b}, time }, ... }. Returns ms spent in the timed SetTexture calls.
local function showSwatches(title, cells)
  local f = imgWindow()
  f.title:SetText(title)
  local ms = 0
  for k, c in ipairs(imgCells) do
    local d = cells[k]
    if d then
      c.name:SetText(d.name)
      c.want:SetText(d.want)
      local t0 = Compat.ProfileMs()
      c.tex:SetTexture(d.path)
      c.tex:SetTexCoord(unpack(d.coords or { 0, 1, 0, 1 }))
      local dt = Compat.ProfileMs() - t0
      if d.time then ms = ms + dt end
      c:Show()
    else
      c:Hide()
    end
  end
  f:Show()
  return ms
end
Spike.ShowSwatches = showSwatches

--- Frame times of the next rendered frames (a 1 MB texture load may hitch the first one).
local function measureFrames(report)
  local mf = CreateFrame("Frame")
  local times, last = {}, Compat.ProfileMs()
  mf:SetScript("OnUpdate", guarded("spike img timing", function(self)
    local now = Compat.ProfileMs()
    times[#times + 1] = now - last
    last = now
    if #times >= 3 then
      self:SetScript("OnUpdate", nil)
      report(times)
    end
  end))
end

local function saveImg(k, v)
  ns.db.img = ns.db.img or {}
  ns.db.img[k] = v
end

function Spike.Img(arg)
  arg = (arg or ""):lower()
  local step = arg:match("^(%S*)")
  if step == "" or step == "1" then
    out("|cff69ccf0spike img|r step 1/3: loading swatch s2 into the texture cache")
    showSwatches("T3Bridge image slots: step 1", {
      { name = "control", path = ICON, want = "T3 icon" },
      { name = "s2", path = IMG_DIR .. "s2", want = "GREY (installed)" },
    })
    ns.spikeImgStep1 = true
    info("If the control shows the T3 icon and s2 is grey, the slot folder is found.")
    info("Now in PowerShell (keep WoW running):", "scripts\\spike-image-slots.ps1")
    info("then type:", "/t3 spike img 2")
    return
  elseif step == "2" then
    if not ns.spikeImgStep1 then info("step 1 was not run in this session", "the s2 cache check below is not meaningful") end
    out("|cff69ccf0spike img|r step 2/3: compare each swatch with the colour under it")
    local ms = showSwatches("T3Bridge image slots: step 2", {
      { name = "control", path = ICON, want = "T3 icon" },
      { name = "s1 (new)", path = IMG_DIR .. "s1", want = "RED = PASS", time = true },
      { name = "s2 (cached)", path = IMG_DIR .. "s2", want = "GREY = cached\nGREEN = no cache" },
      { name = "s3 (crop)", path = IMG_DIR .. "s3", want = "white square\nTOP-LEFT on blue", coords = { 0, 256 / 512, 0, 128 / 512 } },
      { name = "n1 (new file)", path = IMG_DIR .. "n1", want = "EMPTY expected" },
      { name = "t1 (TOC dir)", path = IMGT_DIR .. "t1", want = "RED = TOC ok" },
    })
    measureFrames(function(times)
      local typical = (times[2] + times[3]) / 2
      info(string.format("load time: SetTexture %.1f ms, next frame %.1f ms (typical %.1f ms)", ms, times[1], typical))
      ns.spikeImgLastMs = times[1]
    end)
    info("1) s1 RED: new content shows on first load (required).", "If s1 is red, type /t3 spike img ok")
    info("   If s1 is grey, empty or the control is missing:", "/t3 spike img fail (images then show as text; attaching still works)")
    info("2) s2 GREY means a loaded slot keeps its first image (expected: each slot is single-use per session).")
    info("3) s3: the white square must be at the top-left. n1 should stay empty (new files are not seen).")
    info("Optional /reload test:", "scripts\\spike-image-slots.ps1 -Step 2, then /reload, then /t3 spike img 3")
    return
  elseif step == "3" then
    out("|cff69ccf0spike img|r step 3/3 (after /reload)")
    showSwatches("T3Bridge image slots: after /reload", {
      { name = "control", path = ICON, want = "T3 icon" },
      { name = "s1", path = IMG_DIR .. "s1", want = "YELLOW = freed\nRED = cached" },
      { name = "s2", path = IMG_DIR .. "s2", want = "YELLOW = freed\nGREY/GREEN = cached" },
    })
    info("YELLOW: /reload frees cached textures:", "/t3 spike img reload yes")
    info("Otherwise (old colours):", "/t3 spike img reload no")
    return
  elseif step == "ok" or step == "fail" then
    saveImg("works", step == "ok")
    if step == "ok" then pass("image slots", "inline images on")
    else fail("image slots", "inline images off: shown as [image: name]; attaching still works") end
    -- Tell the companion: the next hello carries the image flag.
    if ns.outbox and not ns.demo then
      ns.outbox.helloSent = true
      ns.outbox:Enqueue("hello", { "1", ns.version, tostring(ns.db.cell or 2), "8", ns.ImagesWork() and "1" or "0" })
      if ns.Outbound then ns.Outbound.Kick() end
    end
    ns.Fire("model", "img")
    return
  elseif step == "reload" then
    local yes = arg:match("^reload%s+(%S+)")
    if yes ~= "yes" and yes ~= "no" then out("usage: /t3 spike img reload yes||no") return end
    saveImg("reloadFrees", yes == "yes")
    if yes == "yes" then
      pass("/reload frees image textures", "to reuse slots after /reload set images.resetOnReload = true in %LOCALAPPDATA%\\T3Bridge\\config.json and restart the bridge")
    else
      info("/reload keeps image textures", "slots are freed only by restarting WoW (the default)")
    end
    return
  elseif step == "status" then
    local img = ns.db.img or {}
    info("image slots: works " .. tostring(img.works) .. ", /reload frees " .. tostring(img.reloadFrees))
    local s = ns.state.snap and ns.state.snap.imgslots
    info("companion: " .. (s and (s.left .. " of " .. s.total .. " slots left") or "no image slot info"))
    return
  end
  out("usage: /t3 spike img [2||3||ok||fail||reload yes||no||status]")
end
