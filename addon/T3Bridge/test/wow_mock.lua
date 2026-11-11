-- A small WoW API mock for smoke tests (Lua 5.1). It is NOT a faithful client: it exists to catch
-- Lua errors (nil indexing, bad arithmetic, wrong load order) and to check behaviour end to end
-- (events, timers, slot loading, the drawn matrix). Methods it does not model are recorded in
-- M.unknown so they can be reviewed against the real API.
local M = { unknown = {}, chat = {}, errors = {}, frames = {}, now = 1000, epoch = 1794393000,
  templates = {}, addons = {}, addonOrder = {}, timers = {}, shift = false, combat = false, reloads = 0 }

local function noop() end

---------------------------------------------------------------------------------------------
-- Object model
---------------------------------------------------------------------------------------------
local Obj = {}
Obj.__index = function(t, k)
  local v = rawget(Obj, k)
  if v ~= nil then return v end
  if type(k) == "string" and k:match("^%u") then
    M.unknown[(rawget(t, "_otype") or "?") .. ":" .. k] = true
  end
  return nil
end

local function new(otype, parent, name)
  local o = setmetatable({ _otype = otype, _parent = parent, _shown = true, _w = 0, _h = 0, _points = {},
    _scripts = {}, _hooks = {}, _scale = 1, _children = {}, _name = name, _alpha = 1 }, Obj)
  if parent and parent._children then table.insert(parent._children, o) end
  if name then _G[name] = o end
  table.insert(M.frames, o)
  return o
end
M.new = new

function Obj:GetName() return self._name end
function Obj:GetObjectType() return self._otype end
function Obj:GetParent() return self._parent end
function Obj:SetParent(p) self._parent = p end
function Obj:Show() self._shown = true; M.fire(self, "OnShow") end
function Obj:Hide() local was = self._shown; self._shown = false; if was then M.fire(self, "OnHide") end end
function Obj:SetShown(v) if v then self:Show() else self:Hide() end end
function Obj:IsShown() return self._shown end
function Obj:IsVisible()
  local o = self
  while o do if not o._shown then return false end o = o._parent end
  return true
end
function Obj:SetSize(w, h) self._w, self._h = w, h; M.fire(self, "OnSizeChanged", w, h) end
function Obj:SetWidth(w) self._w = w end
function Obj:SetHeight(h) self._h = h end
function Obj:GetWidth() return self._w > 0 and self._w or 300 end
function Obj:GetHeight() return self._h > 0 and self._h or 200 end
function Obj:GetSize() return self:GetWidth(), self:GetHeight() end
function Obj:SetPoint(p, rel, rp, x, y)
  if type(rel) == "number" then rel, rp, x, y = nil, p, rel, rp end
  table.insert(self._points, { p, rel, rp or p, x or 0, y or 0 })
end
function Obj:ClearAllPoints() self._points = {} end
function Obj:GetPoint(i) local pt = self._points[i or 1]; if pt then return pt[1], pt[2], pt[3], pt[4], pt[5] end end
function Obj:GetNumPoints() return #self._points end
function Obj:SetAllPoints() end
function Obj:SetScale(s) self._scale = s end
function Obj:GetScale() return self._scale end
function Obj:SetIgnoreParentScale(v) self._ignoreParentScale = v end
function Obj:GetEffectiveScale()
  if self._ignoreParentScale or not self._parent or not self._parent.GetEffectiveScale then return self._scale end
  return self._scale * self._parent:GetEffectiveScale()
end
function Obj:GetLeft()
  local pt = self._points[1]
  if pt and pt[1] == "TOPLEFT" and pt[3] == "TOPLEFT" then return pt[4] end
  return 400
end
function Obj:GetTop()
  local pt = self._points[1]
  if pt and pt[1] == "TOPLEFT" and pt[3] == "TOPLEFT" and pt[2] == _G.UIParent then return 768 / self:GetEffectiveScale() + pt[5] end
  return 600
end
function Obj:GetBottom() return 300 end
function Obj:GetRight() return 700 end
function Obj:GetCenter() return 500, 400 end
function Obj:SetAlpha(a) self._alpha = a end
function Obj:GetAlpha() return self._alpha end
function Obj:SetScript(n, fn) self._scripts[n] = fn end
function Obj:GetScript(n) return self._scripts[n] end
function Obj:HookScript(n, fn) self._hooks[n] = self._hooks[n] or {}; table.insert(self._hooks[n], fn) end
function Obj:HasScript() return true end
for _, n in ipairs({ "SetFrameStrata", "SetFrameLevel", "SetToplevel", "SetClampedToScreen", "SetMovable",
  "SetResizable", "EnableMouse", "EnableMouseWheel", "RegisterForDrag", "RegisterForClicks", "StartMoving",
  "StopMovingOrSizing", "StartSizing", "SetResizeBounds", "SetMinResize", "SetMaxResize", "Raise", "LockHighlight",
  "UnlockHighlight", "SetMouseMotionEnabled", "SetMouseClickEnabled", "SetBackdrop", "SetBackdropColor",
  "SetBackdropBorderColor", "SetHitRectInsets", "SetClipsChildren", "SetDrawLayer", "SetBlendMode", "SetVertexColor",
  "SetTexCoord", "SetDesaturated", "SetSnapToPixelGrid", "SetTexelSnappingBias", "AddMaskTexture",
  "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetNonSpaceWrap", "SetSpacing", "SetTextColor",
  "SetAutoFocus", "SetMultiLine", "SetMaxBytes", "SetMaxLetters", "SetTextInsets", "SetIndentedWordWrap",
  "UpdateScrollChildRect", "SetHorizontalScroll", "RegisterEvent", "UnregisterEvent", "SetMouseMotionEnabled" }) do
  Obj[n] = Obj[n] or noop
end
function Obj:GetFrameLevel() return self._level or 5 end
function Obj:SetFrameLevel(l) self._level = l end
function Obj:GetChildren()
  local out = {}
  for _, c in ipairs(self._children) do
    if c._otype ~= "Texture" and c._otype ~= "FontString" and c._otype ~= "MaskTexture"
      and c._otype ~= "AnimationGroup" and c._otype ~= "Animation" then out[#out + 1] = c end
  end
  return unpack(out)
end
function Obj:IsMouseOver() return false end
function Obj:GetFrameStrata() return "MEDIUM" end
function Obj:IsMenuOpen() return false end
function Obj:GetFrameType() return self._otype end

-- regions
function Obj:CreateTexture(name, layer)
  local t = new("Texture", self, name)
  t._layer = layer
  return t
end
function Obj:CreateMaskTexture() return new("MaskTexture", self) end
function Obj:SetTexture(path) self._texture = path; return true end
function Obj:GetTexture() return self._texture end
function Obj:SetColorTexture(r, g, b, a) self._color = { r, g, b, a } end
-- Like the real client: a FontString created without an inherited font object has NO font, and
-- SetText on it raises "Font not set". SetFont on a file the client cannot load returns false
-- (or raises, with M.fontRaise = true); M.brokenFonts[path] = true makes a real path fail.
local function fontOf(fo)
  if type(fo) == "string" then fo = _G[fo] end
  return type(fo) == "table" and fo._font or nil
end
function Obj:CreateFontString(name, layer, inherits)
  local fs = new("FontString", self, name)
  fs._text = ""
  local f = inherits and fontOf(inherits)
  fs._font = f and { f[1], f[2], f[3] } or nil
  return fs
end
function Obj:SetFontObject(fo)
  local f = fontOf(fo)
  if f then self._font = { f[1], f[2], f[3] } end
end
function Obj:SetText(t)
  if self._otype == "FontString" and not self._font then error("FontString:SetText(): Font not set", 2) end
  t = t == nil and "" or tostring(t)
  self._text = t
  if self._otype == "EditBox" then M.fire(self, "OnTextChanged", false) end
end
function Obj:GetText() return self._text end
function Obj:SetFormattedText(fmt, ...) self:SetText(string.format(fmt, ...)) end
M.brokenFonts = {}
function Obj:SetFont(path, size, flags)
  if type(path) ~= "string" or path:find("no%-such") or M.brokenFonts[path] then
    if M.fontRaise then error("SetFont(): could not load font file " .. tostring(path), 2) end
    return false
  end
  self._font = { path, size, flags }
  return true
end
function Obj:GetFont() return self._font and self._font[1], self._font and self._font[2], self._font and self._font[3] end
function Obj:GetStringWidth() return #(self._text or "") * 7 end
function Obj:GetStringHeight()
  local w = self._w > 0 and self._w or 300
  local perLine = math.max(1, math.floor(w / 7))
  local lines = 0
  for line in ((self._text or "") .. "\n"):gmatch("(.-)\n") do lines = lines + math.max(1, math.ceil(#line / perLine)) end
  return lines * 14
end
function Obj:GetFontString() self._fs = self._fs or self:CreateFontString(nil, nil, "GameFontNormal"); return self._fs end
function Obj:SetNormalTexture(p) self._normal = p end
function Obj:SetPushedTexture() end
function Obj:SetHighlightTexture() end
function Obj:SetDisabledTexture() end
function Obj:GetNormalTexture() return self:CreateTexture() end
function Obj:Enable() self._enabled = true end
function Obj:Disable() self._enabled = false end
function Obj:IsEnabled() return self._enabled ~= false end
function Obj:Click(button) M.fire(self, "OnClick", button or "LeftButton") end

-- scroll frames
function Obj:SetScrollChild(c) self._child = c end
function Obj:GetScrollChild() return self._child end
function Obj:GetVerticalScroll() return self._vscroll or 0 end
function Obj:SetVerticalScroll(v) self._vscroll = v; M.fire(self, "OnVerticalScroll", v) end
function Obj:GetVerticalScrollRange()
  local c = self._child
  if not c then return 0 end
  return math.max(0, (c._h or 0) - self:GetHeight())
end

-- edit boxes
function Obj:Insert(s) self:SetText((self._text or "") .. s) end
function Obj:GetCursorPosition() return #(self._text or "") end
function Obj:SetCursorPosition() end
function Obj:HighlightText() end
function Obj:SetFocus() self._focus = true end
function Obj:ClearFocus() self._focus = false end
function Obj:HasFocus() return self._focus end

-- animations
function Obj:CreateAnimationGroup()
  local g = new("AnimationGroup", self)
  g._playing = false
  return g
end
function Obj:CreateAnimation() return new("Animation", self) end
function Obj:Play() self._playing = true end
function Obj:Stop() self._playing = false end
function Obj:IsPlaying() return self._playing end
for _, n in ipairs({ "SetFromAlpha", "SetToAlpha", "SetDuration", "SetSmoothing", "SetLooping" }) do Obj[n] = noop end

-- modern dropdown (WowStyle1DropdownTemplate)
local function menuRoot(log)
  local r = {}
  function r:CreateTitle(t) log[#log + 1] = "title:" .. t; return r end
  function r:CreateRadio(text, isSel, onSel, data) log[#log + 1] = { text = text, isSel = isSel, onSel = onSel, data = data }; return r end
  function r:CreateButton(text, fn) log[#log + 1] = { text = text, onSel = fn }; return r end
  function r:CreateDivider() return r end
  return r
end
function Obj:SetupMenu(fn) self._menuFn = fn; self:GenerateMenu() end
function Obj:GenerateMenu()
  self._menu = {}
  if self._menuFn then self._menuFn(self, menuRoot(self._menu)) end
end
function Obj:SetDefaultText(t) self._default = t end
function Obj:OpenMenu() self._menuOpen = true; self:GenerateMenu() end

---------------------------------------------------------------------------------------------
-- Scripts / events
---------------------------------------------------------------------------------------------
function M.fire(o, name, ...)
  local fn = o._scripts[name]
  if fn then fn(o, ...) end
  for _, h in ipairs(o._hooks[name] or {}) do h(o, ...) end
end

local eventFrames = {}
local origRegister = function(self, ev) self._events = self._events or {}; self._events[ev] = true; eventFrames[self] = true end
Obj.RegisterEvent = origRegister
function M.event(ev, ...)
  for f in pairs(eventFrames) do
    if f._events[ev] and f._scripts.OnEvent then f._scripts.OnEvent(f, ev, ...) end
  end
end

---------------------------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------------------------
local function applyTemplate(f, template)
  if not template then return end
  for t in tostring(template):gmatch("[^,%s]+") do
    if t == "PortraitFrameTemplate" then
      f.CloseButton = new("Button", f)
      f.Bg = f:CreateTexture()
      f.PortraitContainer = new("Frame", f)
      f.PortraitContainer.portrait = f:CreateTexture()
      f.SetTitle = function(self, s) self._title = s end
      f.SetPortraitTextureRaw = function(self, p) self._portrait = p end
    elseif t == "BasicFrameTemplateWithInset" then
      f.TitleText = f:CreateFontString(nil, nil, "GameFontNormal")
      f.CloseButton = new("Button", f)
    elseif t == "ScrollFrameTemplate" or t == "UIPanelScrollFrameTemplate" then
      f.ScrollBar = new("Slider", f)
    elseif t == "T3BridgeInputScrollTemplate" or t == "InputScrollFrameTemplate" then
      f.ScrollBar = new("Slider", f)
      f.EditBox = new("EditBox", f)
      f.EditBox._text = ""
      f.EditBox.Instructions = f.EditBox:CreateFontString(nil, nil, "GameFontDisable")
      f.CharCount = f:CreateFontString(nil, nil, "GameFontDisableSmall")
      f:SetScrollChild(f.EditBox)
    elseif t == "UIPanelButtonTemplate" then
      f:GetFontString()
    end
  end
end

---------------------------------------------------------------------------------------------
-- Globals
---------------------------------------------------------------------------------------------
function M.install(opts)
  opts = opts or {}
  M.templates = {}
  for _, t in ipairs(opts.templates or {}) do M.templates[t] = true end

  _G.CreateFrame = function(ftype, name, parent, template)
    if template then
      for t in tostring(template):gmatch("[^,%s]+") do
        if not M.templates[t] and t ~= "BackdropTemplate" then error("unknown template " .. t, 2) end
      end
    end
    if ftype == "DropdownButton" and not M.templates.WowStyle1DropdownTemplate then error("unknown frame type", 2) end
    local f = new(ftype, parent, name)
    if ftype == "EditBox" then f._text = "" end
    applyTemplate(f, template)
    return f
  end
  _G.UIParent = new("Frame", nil, "UIParent")
  _G.UIParent._w, _G.UIParent._h = 1365, 768
  _G.WorldFrame = new("Frame", nil, "WorldFrame")
  _G.Minimap = new("Frame", _G.UIParent, "Minimap")
  _G.Minimap._w = 140
  _G.GameTooltip = new("GameTooltip", _G.UIParent, "GameTooltip")
  for _, n in ipairs({ "SetOwner", "AddLine", "AddDoubleLine", "SetText", "ClearLines" }) do _G.GameTooltip[n] = noop end
  _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) table.insert(M.chat, msg) end }
  _G.ChatFrame1 = _G.DEFAULT_CHAT_FRAME
  local function fontObj(name)
    local fo = new("Font", nil, name)
    fo._font = { "Fonts\\ARIALN.TTF", 14, "" }
    return fo
  end
  for _, n in ipairs({ "ChatFontNormal", "GameFontNormal", "GameFontNormalSmall", "GameFontHighlight",
    "GameFontHighlightSmall", "GameFontDisable", "GameFontDisableSmall", "GameFontDisableLarge" }) do fontObj(n) end
  _G.UISpecialFrames = {}
  _G.SlashCmdList = {}
  _G.GetTime = function() return M.now end
  _G.time = function() return math.floor(M.epoch) end
  _G.date = function(fmt, t) return os.date(fmt, t) end
  _G.GetBuildInfo = function() return "1.60.1", "70862", "Nov 1 2026", opts.interface or 16001 end
  _G.debugprofilestop = function() return M.now * 1000 end
  _G.IsShiftKeyDown = function() return M.shift end
  _G.InCombatLockdown = function() return M.combat end
  _G.ReloadUI = function() M.reloads = M.reloads + 1 end
  _G.GetPhysicalScreenSize = opts.noPhysical and nil or function() return 2560, 1440 end
  _G.GetCVar = function(k) if k == "gxWindowedResolution" then return "1920x1080" end end
  M.cursor = { 0, 0 }
  _G.GetCursorPosition = function() return M.cursor[1], M.cursor[2] end
  M.minimapShape = nil
  _G.GetMinimapShape = function() return M.minimapShape end
  _G.UnitName = function() return "Tester" end
  _G.BackdropTemplateMixin = opts.noBackdrop and nil or {}
  _G.C_XMLUtil = opts.noXMLUtil and nil or { GetTemplateInfo = function(n) return M.templates[n] and { type = "Frame" } or nil end }
  _G.UIDropDownMenu_SetWidth = noop
  _G.UIDropDownMenu_Initialize = function(dd, fn) dd._init = fn; fn(dd, 1) end
  _G.UIDropDownMenu_CreateInfo = function() return {} end
  _G.UIDropDownMenu_AddButton = function(info) M.lastDropdownInfo = info end
  _G.UIDropDownMenu_SetText = function(dd, t) dd._ddtext = t end
  _G.CloseDropDownMenus = noop
  _G.AddonCompartmentFrame = opts.compartment and { RegisterAddon = function(_, d) M.compartment = d end } or nil

  -- timers
  _G.C_Timer = {
    After = function(sec, fn) table.insert(M.timers, { at = M.now + sec, fn = fn }) end,
    NewTicker = function(sec, fn)
      local tk = { cancelled = false }
      function tk:Cancel() self.cancelled = true end
      local function arm() table.insert(M.timers, { at = M.now + sec, fn = function() if not tk.cancelled then fn(tk); arm() end end, ticker = tk }) end
      arm()
      return tk
    end,
  }

  -- error handler (default = "red popup")
  local handler = function(msg) table.insert(M.errors, tostring(msg)) end
  _G.geterrorhandler = function() return handler end
  _G.seterrorhandler = function(fn) handler = fn end

  -- addons
  M.addons, M.addonOrder = {}, {}
  _G.C_AddOns = {
    GetNumAddOns = function() return #M.addonOrder end,
    GetAddOnInfo = function(i)
      local a = M.addons[M.addonOrder[i]]
      if not a then return nil end
      return a.name, a.name, "", true, a.disabled and "DISABLED" or nil
    end,
    IsAddOnLoaded = function(name) local a = M.addons[name]; local l = a and a.loaded or false; return l, l end,
    EnableAddOn = function(name) if M.addons[name] then M.addons[name].disabled = false end end,
    LoadAddOn = function(name)
      local a = M.addons[name]
      if not a then return false, "MISSING" end
      if a.disabled then return false, "DISABLED" end
      if a.loaded then return true end
      a.loaded = true
      M.loads = (M.loads or 0) + 1
      local chunk, err = loadfile(a.file())
      if not chunk then geterrorhandler()(err); return true end
      local ok, e = pcall(chunk)
      if not ok then geterrorhandler()(e) end
      return true
    end,
  }
end

--- Type a chat line and press Enter, like ChatEdit_ParseText: the slash handler runs UNPROTECTED,
--- so an error aborts the rest of the Enter handling (the edit box keeps its text, nothing prints)
--- exactly as in game. Returns true when handled, or false + the error.
function M.typeChat(line)
  local cmd, rest = line:match("^(/%S+)%s*(.-)$")
  if not cmd then return false, "not a slash command" end
  cmd = cmd:upper()
  for key, fn in pairs(_G.SlashCmdList) do
    for i = 1, 9 do
      local alias = _G["SLASH_" .. key .. i]
      if not alias then break end
      if alias:upper() == cmd then
        local ok, err = pcall(fn, rest)
        if not ok then return false, err end
        return true
      end
    end
  end
  return false, "unknown command"
end

function M.addAddon(name, fileFn, disabled)
  M.addons[name] = { name = name, file = fileFn, loaded = false, disabled = disabled }
  table.insert(M.addonOrder, name)
end

--- Advance the clock, run due timers and OnUpdate of visible frames, at ~60 fps.
function M.advance(sec, fps)
  fps = fps or 60
  local steps = math.max(1, math.floor(sec * fps + 0.5))
  for _ = 1, steps do
    M.now = M.now + 1 / fps
    M.epoch = M.epoch + 1 / fps
    local due, keep = {}, {}
    for _, t in ipairs(M.timers) do if t.at <= M.now then due[#due + 1] = t else keep[#keep + 1] = t end end
    M.timers = keep
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do t.fn() end
    local snapshot = {}
    for _, f in ipairs(M.frames) do if f._scripts.OnUpdate and f:IsVisible() then snapshot[#snapshot + 1] = f end end
    for _, f in ipairs(snapshot) do if f._scripts.OnUpdate and f:IsVisible() then f._scripts.OnUpdate(f, 1 / fps) end end
  end
end

return M
