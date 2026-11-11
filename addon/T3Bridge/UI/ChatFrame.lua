-- T3Bridge ChatFrame: the in-game chat window (thread, model and effort pickers, history, prompt, input,
-- image attachments: Attach button + menu, Ctrl+V, staged chips; PROTOCOL rev 1.3).
local _, ns = ...
local Compat, State, Codec = ns.Compat, ns.State, ns.Codec

ns.UI = ns.UI or {}
local UI = ns.UI
local Chat = {}
UI.Chat = Chat

local ICON = "Interface\\AddOns\\T3Bridge\\Media\\icon"
local MIN_W, MIN_H = 420, 360
local INPUT_H, STATUS_H = 60, 18
local CHIPS_H, CHIP = 40, 36          -- staged-attachment row above the input (rev 1.3)
local PASTE_DEBOUNCE = 1.0            -- s between two Ctrl+V-triggered "clip" commands

local f                    -- the window
local L = {}               -- layout pieces
local echo                 -- optimistic local copy of a message being sent: { tid, text, after }
local ddCounter = 0

local function isForever()
  local iface = select(4, GetBuildInfo())
  return iface and iface >= 16000 and iface < 17000
end

---------------------------------------------------------------------------------------------
-- Dropdowns: WowStyle1DropdownTemplate (menu API), fallback UIDropDownMenuTemplate
---------------------------------------------------------------------------------------------
local function threadLabel(t)
  local info = State.STATUS[State.StatusKey(t)]
  local c = info.color
  local title = t.title
  if #title > 48 then title = Codec.Utf8Truncate(title, 46) .. "..." end
  return string.format("|cff%02x%02x%02x%s|r", c[1] * 255, c[2] * 255, c[3] * 255, Compat.Escape(title))
end

local function createDropdown(parent, width, buildModern, buildLegacy, defaultText)
  local d = { width = width }
  if Compat.TemplateExists("WowStyle1DropdownTemplate") then
    local dd = Compat.TryCreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
    if dd and dd.SetupMenu then
      dd:SetWidth(width)
      if dd.SetDefaultText then dd:SetDefaultText(defaultText) end
      dd:SetupMenu(function(_, root) buildModern(root) end)
      d.frame, d.modern = dd, true
      function d.SetWidth(w) d.width = w; dd:SetWidth(w) end
      function d.Refresh()
        if dd.IsMenuOpen and dd:IsMenuOpen() then return end
        if dd.GenerateMenu then dd:GenerateMenu() end
      end
      return d
    end
  end
  ddCounter = ddCounter + 1
  local dd = CreateFrame("Frame", "T3BridgeDropDown" .. ddCounter, parent, "UIDropDownMenuTemplate")
  UIDropDownMenu_SetWidth(dd, width - 30)
  UIDropDownMenu_Initialize(dd, function(_, level) buildLegacy(level) end)
  d.frame, d.modern = dd, false
  function d.SetWidth(w) d.width = w; UIDropDownMenu_SetWidth(dd, math.max(20, w - 30)) end
  function d.Refresh(text) UIDropDownMenu_SetText(dd, text or defaultText) end
  return d
end

local function legacyAdd(text, opts, level)
  local info = UIDropDownMenu_CreateInfo()
  info.text = text
  for k, v in pairs(opts) do info[k] = v end
  UIDropDownMenu_AddButton(info, level)
end

local function buildThreadMenuModern(root)
  local groups = State.ThreadGroups(ns.state)
  if #groups == 0 then root:CreateTitle("No threads yet") return end
  -- Up to 30 threads (PROTOCOL D15): scroll instead of running off the screen, where supported.
  if root.SetScrollMode then pcall(root.SetScrollMode, root, 440) end
  for _, g in ipairs(groups) do
    root:CreateTitle(g.title)
    for _, t in ipairs(g.items) do
      root:CreateRadio(threadLabel(t), function() return ns.selected == t.id end,
        function() ns.SelectThread(t.id) end, t.id)
    end
  end
end

local function buildThreadMenuLegacy(level)
  local groups = State.ThreadGroups(ns.state)
  if #groups == 0 then legacyAdd("No threads yet", { isTitle = true, notCheckable = true }, level) return end
  for _, g in ipairs(groups) do
    legacyAdd(g.title, { isTitle = true, notCheckable = true }, level)
    for _, t in ipairs(g.items) do
      legacyAdd(threadLabel(t), { checked = (ns.selected == t.id), func = function()
        ns.SelectThread(t.id)
        CloseDropDownMenus()
      end }, level)
    end
  end
end

--- "Claude Sonnet 5.5" -> "Sonnet 5.5" (every model of a thread's provider shares the prefix).
local function shortModelName(name)
  local s = name and name:gsub("^Claude%s+", "") or ""
  return s ~= "" and s or name
end
Chat.ShortModelName = shortModelName

local EFFORT_LABEL = { low = "Low", medium = "Medium", high = "High", xhigh = "X-High", max = "Max",
  ultrathink = "Ultrathink", auto = "Auto", none = "None", minimal = "Minimal", off = "Off" }
--- Pretty label for an effort id (unknown ids: first letter upper-cased).
function Chat.EffortLabel(v)
  if not v then return "" end
  return EFFORT_LABEL[v] or (v:sub(1, 1):upper() .. v:sub(2))
end

local function currentModels()
  local fo = ns.selected and State.Focus(ns.state, ns.selected)
  return fo and fo.models or {}, fo and (L.pendingModel or fo.model)
end

local function modelById(models, id)
  for _, m in ipairs(models) do if m.id == id then return m end end
  return nil
end

--- The effort choices of the selected (or just picked) model and the effort to show, or nil.
local function currentEffort()
  local fo = ns.selected and State.Focus(ns.state, ns.selected)
  if not fo then return nil end
  local models, cur = currentModels()
  local m = modelById(models, cur)
  local choice = m and m.effort
  if not choice then return nil end
  local v = L.pendingEffort or fo.effort
  if not (v and choice.has[v]) then v = choice.def end
  return choice, v
end
Chat.CurrentEffort = currentEffort

--- Effort to send with a model switch: keep the current one if the new model offers it, else its default.
function Chat.EffortForModel(model, currentValue)
  local choice = model and model.effort
  if not choice then return nil end
  if currentValue and choice.has[currentValue] then return currentValue end
  return choice.def
end

local function chooseModel(id)
  if not ns.selected then return end
  local models = currentModels()
  local _, curEffort = currentEffort()
  local effort = Chat.EffortForModel(modelById(models, id), curEffort)
  L.pendingModel, L.pendingEffort = id, effort
  -- One command (one matrix flash) sets the model and, when it has one, the effort (PROTOCOL D14).
  ns.Send("model", { ns.selected, id, effort })
  Chat.Refresh()
end

local function chooseEffort(v)
  if not ns.selected then return end
  local _, cur = currentModels()
  if not cur then return end
  L.pendingEffort = v
  ns.Send("model", { ns.selected, cur, v })
  Chat.Refresh()
end

local function buildModelMenuModern(root)
  local models, cur = currentModels()
  for _, m in ipairs(models) do
    root:CreateRadio(Compat.Escape(shortModelName(m.name)), function() return cur == m.id end, function() chooseModel(m.id) end, m.id)
  end
end

local function buildModelMenuLegacy(level)
  local models, cur = currentModels()
  for _, m in ipairs(models) do
    legacyAdd(Compat.Escape(shortModelName(m.name)), { checked = (cur == m.id), func = function()
      chooseModel(m.id)
      CloseDropDownMenus()
    end }, level)
  end
end

local function buildEffortMenuModern(root)
  local choice, cur = currentEffort()
  if not choice then return end
  root:CreateTitle("Reasoning effort")
  for _, v in ipairs(choice.vals) do
    root:CreateRadio(Chat.EffortLabel(v), function() return cur == v end, function() chooseEffort(v) end, v)
  end
end

local function buildEffortMenuLegacy(level)
  local choice, cur = currentEffort()
  if not choice then return end
  legacyAdd("Reasoning effort", { isTitle = true, notCheckable = true }, level)
  for _, v in ipairs(choice.vals) do
    legacyAdd(Chat.EffortLabel(v), { checked = (cur == v), func = function()
      chooseEffort(v)
      CloseDropDownMenus()
    end }, level)
  end
end

---------------------------------------------------------------------------------------------
-- Input box
---------------------------------------------------------------------------------------------
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function submit()
  local eb = L.eb
  local text = trim(eb.t3sendText or eb:GetText() or "")
  eb.t3sendText = nil
  if not ns.selected then return end
  local fo0 = State.Focus(ns.state, ns.selected)
  local staged = (fo0 and fo0.staged and not fo0.pending) and #fo0.staged or 0
  if text == "" and staged == 0 then return end
  if #text > Codec.MAX_INPUT then
    text = Codec.Utf8Truncate(text, Codec.MAX_INPUT)
    ns.Print("Message cut to 4000 bytes.")
  end
  local tid = ns.selected
  local fo = State.Focus(ns.state, tid)
  if fo and fo.pending then
    ns.Send("ans", { tid, fo.pending.rid, text }, { text = text })
    L.prompt:MarkSent(text)
  else
    local list = State.Messages(ns.state, tid)
    -- Staged images go with this message (the companion attaches them); text may be empty then.
    local shown = text ~= "" and text or ""
    if staged > 0 then shown = shown .. (shown ~= "" and "\n" or "") .. "(+" .. staged .. (staged == 1 and " image)" or " images)") end
    echo = { tid = tid, text = shown, after = list[#list] and list[#list].i or 0 }
    ns.Send("send", { tid, text }, { text = text })
  end
  eb:SetText("")
  eb:ClearFocus()
  Chat.Refresh()
end

local function onEnterPressed(self)
  local cur = self:GetText() or ""
  local pos = self:GetCursorPosition() or #cur
  -- Some clients insert the newline into a multi-line EditBox before calling OnEnterPressed.
  local clientInserted = false
  if self.t3prev and pos >= 1 and cur:sub(pos, pos) == "\n" then
    clientInserted = (cur:sub(1, pos - 1) .. cur:sub(pos + 1)) == self.t3prev
  end
  if IsShiftKeyDown() then
    if not clientInserted then self:Insert("\n") end
    return
  end
  self.t3sendText = clientInserted and self.t3prev or cur
  submit()
end

local function createInput(parent)
  local holder = CreateFrame("Frame", nil, parent)
  local sf, eb
  if Compat.TemplateExists("InputScrollFrameTemplate") and Compat.TemplateExists("T3BridgeInputScrollTemplate") then
    sf = Compat.TryCreateFrame("ScrollFrame", nil, holder, "T3BridgeInputScrollTemplate")
    if sf and not sf.EditBox then sf:Hide(); sf = nil end
  end
  if sf then
    sf:SetPoint("TOPLEFT", 6, -6)
    sf:SetPoint("BOTTOMRIGHT", -6, 6)
    eb = sf.EditBox
    -- The template's OnLoad sized the EditBox from the frame width at creation time (0 when created
    -- from Lua), so keep it in sync with the real width.
    local function syncWidth(w)
      w = w or sf:GetWidth() or 0
      if w > 30 then
        eb:SetWidth(w - 18)
        if eb.Instructions and eb.Instructions.SetWidth then eb.Instructions:SetWidth(w - 18) end
      end
    end
    sf:HookScript("OnSizeChanged", function(_, w) syncWidth(w) end)
    syncWidth()
    L.inputKind = "InputScrollFrameTemplate"
  else
    local bg = CreateFrame("Frame", nil, holder, Compat.BackdropTemplate())
    bg:SetAllPoints(holder)
    if bg.SetBackdrop then
      bg:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
      bg:SetBackdropColor(0, 0, 0, 0.6)
      bg:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    sf = CreateFrame("ScrollFrame", nil, holder, Compat.FirstTemplate({ "UIPanelScrollFrameTemplate", "ScrollFrameTemplate" }))
    sf:SetPoint("TOPLEFT", 8, -6)
    sf:SetPoint("BOTTOMRIGHT", -28, 6)
    eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetFontObject(ChatFontNormal)
    eb:SetWidth(300)
    sf:SetScrollChild(eb)
    sf:HookScript("OnSizeChanged", function(_, w) eb:SetWidth(math.max(50, (w or 300) - 4)) end)
    if _G.ScrollingEdit_OnCursorChanged then
      eb:SetScript("OnCursorChanged", _G.ScrollingEdit_OnCursorChanged)
      eb:SetScript("OnUpdate", function(self, e) if _G.ScrollingEdit_OnUpdate then _G.ScrollingEdit_OnUpdate(self, e, sf) end end)
    end
    local hint = eb:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    hint:SetPoint("TOPLEFT", 2, 0)
    hint:SetText("Message T3 Code - Enter sends, Shift+Enter adds a line")
    eb.Instructions = hint
    eb:HookScript("OnTextChanged", function(self) hint:SetShown((self:GetText() or "") == "") end)
    holder:EnableMouse(true)
    holder:SetScript("OnMouseDown", function() eb:SetFocus() end)
    L.inputKind = "fallback"
  end
  eb:SetAutoFocus(false)
  if eb.SetMaxBytes then eb:SetMaxBytes(Codec.MAX_INPUT + 1) end
  if eb.SetMaxLetters then eb:SetMaxLetters(0) end
  eb:HookScript("OnTextChanged", function(self)
    self.t3prev = self.t3cur
    self.t3cur = self:GetText()
  end)
  eb:SetScript("OnEnterPressed", onEnterPressed)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  -- Ctrl+V: WoW pastes only text into an EditBox, so the user's own Ctrl+V in this box also asks the
  -- companion to attach the clipboard image, if there is one ("clip <tid> 1" = quiet). Text pastes
  -- still happen normally. This only observes our own EditBox; nothing is injected.
  eb:HookScript("OnKeyDown", function(_, key) Chat.OnKeyDown(key) end)
  return holder, eb
end

--- Ctrl+V in the input box (see createInput). Returns true when a clip command was queued.
function Chat.OnKeyDown(key)
  if key ~= "V" and key ~= "v" then return false end
  if not (_G.IsControlKeyDown and IsControlKeyDown()) then return false end
  return Chat.PasteImage(true)
end

--- Ask the companion to stage the clipboard image. quiet: no "no image" notice (Ctrl+V). Debounced.
function Chat.PasteImage(quiet)
  local tid = ns.selected
  if not tid or ns.demo then return false end
  local now = GetTime()
  if L.lastPaste and now - L.lastPaste < PASTE_DEBOUNCE then return false end
  L.lastPaste = now
  ns.Send("clip", { tid, quiet and "1" or "0" })
  return true
end

function Chat.AttachScreenshot()
  local tid = ns.selected
  if not tid or ns.demo then return false end
  ns.Send("shot", { tid })
  return true
end

local ATTACH_ITEMS = {
  { text = "Paste image from clipboard (Ctrl+V)", fn = function() Chat.PasteImage(false) end },
  { text = "Attach latest WoW screenshot", fn = function() Chat.AttachScreenshot() end },
}

--- Opens the attach menu with whatever menu API the client has. Returns the path used (tests):
--- "menuutil" (MenuUtil.CreateContextMenu), "easymenu", "dropdown" (UIDropDownMenu), or "direct"
--- (no menu API: paste from the clipboard right away).
function Chat.OpenAttachMenu(owner)
  if ns.demo then ns.Print("Demo mode: attachments need the companion."); return "demo" end
  local MU = _G.MenuUtil
  if MU and MU.CreateContextMenu then
    local ok = pcall(MU.CreateContextMenu, owner, function(_, root)
      root:CreateTitle("Attach an image")
      for _, it in ipairs(ATTACH_ITEMS) do root:CreateButton(it.text, it.fn) end
    end)
    if ok then return "menuutil" end
  end
  local items = { { text = "Attach an image", isTitle = true, notCheckable = true } }
  for _, it in ipairs(ATTACH_ITEMS) do items[#items + 1] = { text = it.text, func = it.fn, notCheckable = true } end
  if not L.attachMenu and (_G.EasyMenu or _G.UIDropDownMenu_Initialize) and Compat.TemplateExists("UIDropDownMenuTemplate") then
    L.attachMenu = Compat.TryCreateFrame("Frame", "T3BridgeAttachMenu", UIParent, "UIDropDownMenuTemplate")
  end
  if L.attachMenu and _G.EasyMenu then
    if pcall(EasyMenu, items, L.attachMenu, owner, 0, 0, "MENU") then return "easymenu" end
  end
  if L.attachMenu and _G.UIDropDownMenu_Initialize and _G.ToggleDropDownMenu then
    local ok = pcall(function()
      UIDropDownMenu_Initialize(L.attachMenu, function(_, level)
        for _, it in ipairs(items) do legacyAdd(it.text, { isTitle = it.isTitle, notCheckable = true, func = it.func }, level) end
      end, "MENU")
      ToggleDropDownMenu(1, nil, L.attachMenu, owner, 0, 0)
    end)
    if ok then return "dropdown" end
  end
  Chat.PasteImage(false)
  return "direct"
end

---------------------------------------------------------------------------------------------
-- Staged attachments: a row of 36x36 thumbnails with a remove button, above the input
---------------------------------------------------------------------------------------------
local function chipOnEnter(self)
  if not self.img then return end
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:SetText(Compat.Escape(self.img.alt or "image"))
  GameTooltip:AddLine("Sent with your next message. Click to enlarge.", 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

local function createChip(parent)
  local c = CreateFrame("Button", nil, parent)
  c:SetSize(CHIP, CHIP)
  UI.Messages.AddImageFrame(c)
  c.tex = c:CreateTexture(nil, "ARTWORK")
  c.tex:SetPoint("TOPLEFT", 1, -1)
  c.tex:SetPoint("BOTTOMRIGHT", -1, 1)
  c.label = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  c.label:SetPoint("CENTER")
  c.label:SetText("IMG")
  c.close = CreateFrame("Button", nil, c)
  c.close:SetSize(14, 14)
  c.close:SetPoint("TOPRIGHT", 5, 5)
  c.close:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
  c.close:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  c.close:SetScript("OnClick", function()
    if c.img and c.img.aid and ns.selected then ns.Send("unstage", { ns.selected, c.img.aid }) end
  end)
  c.close:SetScript("OnEnter", function(b) GameTooltip:SetOwner(b, "ANCHOR_TOP"); GameTooltip:SetText("Remove"); GameTooltip:Show() end)
  c.close:SetScript("OnLeave", function() GameTooltip:Hide() end)
  c:SetScript("OnEnter", chipOnEnter)
  c:SetScript("OnLeave", function() GameTooltip:Hide() end)
  c:SetScript("OnClick", function(self)
    if self.img and self.img.s > 0 and UI.ImageViewer then UI.ImageViewer.Show(self.img) end
  end)
  return c
end

--- Show the staged list (or hide the row). Returns true when the row is shown.
function Chat.UpdateChips(staged)
  local row = L.chips
  if not row then return false end
  if not staged or #staged == 0 then
    row:Hide()
    for _, c in ipairs(L.chipList) do c:Hide(); c.img = nil end
    return false
  end
  row:Show()
  local width = row:GetWidth() or 300
  local fit = math.max(1, math.floor((width - 40) / (CHIP + 8)))
  local shown = math.min(#staged, fit)
  for k = 1, shown do
    local img = staged[k]
    local c = L.chipList[k] or createChip(row)
    L.chipList[k] = c
    c.img = img
    c:ClearAllPoints()
    c:SetPoint("LEFT", row, "LEFT", 4 + (k - 1) * (CHIP + 8), 0)
    if img.s > 0 and ns.ImagesWork() then
      local slot = img.s
      if c.slot ~= slot then c.tex:SetTexture(UI.Messages.SlotTexture(slot)); c.slot = slot end
      -- a square crop of the middle of the image
      local w, h = img.w, img.h
      local side = math.min(w, h)
      local x0, y0 = (w - side) / 2, (h - side) / 2
      c.tex:SetTexCoord(x0 / State.IMG_CANVAS, (x0 + side) / State.IMG_CANVAS, y0 / State.IMG_CANVAS, (y0 + side) / State.IMG_CANVAS)
      c.tex:Show(); c.label:Hide()
    else
      c.slot = nil
      c.tex:Hide(); c.label:Show()
    end
    c:Show()
  end
  for k = shown + 1, #L.chipList do L.chipList[k]:Hide(); L.chipList[k].img = nil end
  L.chipMore:SetText(#staged > shown and ("+" .. (#staged - shown)) or "")
  L.chipHint:SetText(#staged == 1 and "1 image attached" or (#staged .. " images attached"))
  L.chipHint:SetShown(width - 4 - shown * (CHIP + 8) > 120)
  return true
end

---------------------------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------------------------
local function savePosition()
  local p, _, rp, x, y = f:GetPoint(1)
  ns.db.chat.point = { p, rp, x, y }
  ns.db.chat.w, ns.db.chat.h = math.floor(f:GetWidth() + 0.5), math.floor(f:GetHeight() + 0.5)
end

local function create()
  local tmpl = Compat.FirstTemplate({ "PortraitFrameTemplate", "BasicFrameTemplateWithInset" })
  f = CreateFrame("Frame", "T3BridgeChatFrame", UIParent, tmpl or Compat.BackdropTemplate())
  L.template = tmpl or "BackdropTemplate"
  f:SetSize(ns.db.chat.w or 520, ns.db.chat.h or 560)
  local p = ns.db.chat.point
  if p then f:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else f:SetPoint("CENTER", UIParent, "CENTER", 0, 40) end
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:SetResizable(true)
  Compat.SetResizeBounds(f, MIN_W, MIN_H)
  f:EnableMouse(true)
  f:Hide()
  table.insert(UISpecialFrames, "T3BridgeChatFrame")

  -- chrome
  local top = -30
  local left = 12
  if tmpl == "PortraitFrameTemplate" then
    if f.SetTitle then f:SetTitle("T3 Code") end
    if f.SetPortraitTextureRaw then
      f:SetPortraitTextureRaw(ICON)
    elseif f.SetPortraitToAsset then
      f:SetPortraitToAsset(ICON)
    elseif f.PortraitContainer and f.PortraitContainer.portrait then
      f.PortraitContainer.portrait:SetTexture(ICON)
    elseif f.portrait and SetPortraitToTexture then
      SetPortraitToTexture(f.portrait, ICON)
    end
    if isForever() and f.Bg and f.Bg.SetColorTexture then f.Bg:SetColorTexture(30 / 255, 23 / 255, 18 / 255, 0.92) end
    left = 60
  elseif tmpl == "BasicFrameTemplateWithInset" then
    if f.TitleText then f.TitleText:SetText("T3 Code") end
    top = -28
  else
    if f.SetBackdrop then
      f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    end
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -14)
    title:SetText("T3 Code")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    top = -36
    left = 16
  end

  -- drag bar along the title
  local drag = CreateFrame("Frame", nil, f)
  drag:SetPoint("TOPLEFT", f, "TOPLEFT", 55, 0)
  drag:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, 0)
  drag:SetHeight(24)
  drag:EnableMouse(true)
  drag:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then f:StartMoving(); f.moving = true end end)
  drag:SetScript("OnMouseUp", function() if f.moving then f:StopMovingOrSizing(); f.moving = false; savePosition() end end)
  f:HookScript("OnHide", function()
    if f.moving or f.sizing then f:StopMovingOrSizing(); f.moving, f.sizing = false, false end
    if ns.Inbound then ns.Inbound.Reschedule() end
  end)

  -- top bar: thread dropdown, model dropdown, effort dropdown, status (widths fitted by Chat.LayoutTop)
  L.left = left
  L.threadDD = createDropdown(f, 210, buildThreadMenuModern, buildThreadMenuLegacy, "Select a thread")
  L.threadDD.frame:SetPoint("TOPLEFT", f, "TOPLEFT", left - (L.threadDD.modern and 0 or 16), top - 2)
  L.modelDD = createDropdown(f, 130, buildModelMenuModern, buildModelMenuLegacy, "Model")
  L.modelDD.frame:SetPoint("LEFT", L.threadDD.frame, "RIGHT", L.threadDD.modern and 6 or -26, 0)
  L.effortDD = createDropdown(f, 96, buildEffortMenuModern, buildEffortMenuLegacy, "Effort")
  L.effortDD.frame:SetPoint("LEFT", L.modelDD.frame, "RIGHT", L.modelDD.modern and 6 or -26, 0)
  L.effortDD.frame:Hide()
  L.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  L.status:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, top - 8)
  L.status:SetJustifyH("RIGHT")
  L.status:SetWordWrap(false)

  -- bottom: status bar
  L.statusBar = CreateFrame("Button", nil, f)
  L.statusBar:SetHeight(STATUS_H)
  L.statusBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 6)
  L.statusBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, 6)
  L.statusBar.dot = L.statusBar:CreateTexture(nil, "ARTWORK")
  L.statusBar.dot:SetSize(10, 10)
  L.statusBar.dot:SetPoint("LEFT", 0, 0)
  L.statusBar.text = L.statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  L.statusBar.text:SetPoint("LEFT", L.statusBar.dot, "RIGHT", 4, 0)
  L.statusBar:SetScript("OnClick", function(self) if self.clickable then ns.ReloadForLink() end end)
  L.statusBar:SetScript("OnEnter", function(self)
    if not self.clickable then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Reload the UI to get a fresh set of link slots")
    GameTooltip:Show()
  end)
  L.statusBar:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- resize grip
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -4, 4)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT"); f.sizing = true end)
  grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing(); f.sizing = false; savePosition() end)

  -- input row
  L.inputHolder, L.eb = createInput(f)
  L.inputHolder:SetHeight(INPUT_H)
  L.inputHolder:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 6 + STATUS_H + 4)
  L.inputHolder:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -128, 6 + STATUS_H + 4)
  -- Attach button (rev 1.3): opens the attach menu (clipboard image, latest WoW screenshot).
  L.attach = CreateFrame("Button", nil, f)
  L.attach:SetSize(24, 24)
  L.attach:SetPoint("TOPLEFT", L.inputHolder, "TOPRIGHT", 4, -2)
  L.attach:SetNormalTexture("Interface\\Icons\\INV_Misc_Note_01")
  L.attach:SetPushedTexture("Interface\\Icons\\INV_Misc_Note_01")
  L.attach:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  L.attach.edge = L.attach:CreateTexture(nil, "OVERLAY")
  L.attach.edge:SetTexture("Interface\\Buttons\\UI-Quickslot2")
  L.attach.edge:SetPoint("TOPLEFT", -9, 9)
  L.attach.edge:SetPoint("BOTTOMRIGHT", 9, -9)
  L.attach:SetScript("OnClick", function(self) Chat.OpenAttachMenu(self) end)
  L.attach:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Attach an image")
    GameTooltip:AddLine("Copy an image (e.g. Win+Shift+S), then click here or press Ctrl+V in the message box.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
  end)
  L.attach:SetScript("OnLeave", function() GameTooltip:Hide() end)
  L.send = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  L.send:SetSize(80, 24)
  L.send:SetText("Send")
  L.send:SetPoint("TOPLEFT", L.attach, "TOPRIGHT", 6, 0)
  L.send:SetScript("OnClick", function() L.eb.t3sendText = nil; submit() end)
  L.stop = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  L.stop:SetSize(80, 24)
  L.stop:SetText("Stop")
  L.stop:SetPoint("TOPLEFT", L.send, "BOTTOMLEFT", 0, -6)
  L.stop:SetScript("OnClick", function() if ns.selected then ns.Send("intr", { ns.selected }) end end)

  -- staged attachments row (above input; shown only when images are staged)
  L.chips = CreateFrame("Frame", nil, f)
  L.chips:SetHeight(CHIPS_H)
  L.chips:SetPoint("BOTTOMLEFT", L.inputHolder, "TOPLEFT", 0, 4)
  L.chips:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 6 + STATUS_H + 4 + INPUT_H + 4)
  L.chips:Hide()
  L.chipList = {}
  L.chipMore = L.chips:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  L.chipMore:SetPoint("RIGHT", L.chips, "RIGHT", -4, 0)
  L.chipHint = L.chips:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  L.chipHint:SetPoint("RIGHT", L.chipMore, "LEFT", -6, 0)

  -- prompt panel (above input)
  L.prompt = UI.Prompt.Create(f)
  L.prompt.frame:SetPoint("BOTTOMLEFT", L.inputHolder, "TOPLEFT", 0, 6)

  -- history
  local inset = Compat.TemplateExists("InsetFrameTemplate") and Compat.TryCreateFrame("Frame", nil, f, "InsetFrameTemplate")
  if not inset then
    inset = CreateFrame("Frame", nil, f, Compat.BackdropTemplate())
    if inset.SetBackdrop then
      inset:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
      inset:SetBackdropColor(0, 0, 0, 0.5)
      inset:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    end
  end
  L.inset = inset
  inset:SetPoint("TOPLEFT", f, "TOPLEFT", 10, top - 34)
  inset:SetPoint("RIGHT", f, "RIGHT", -10, 0)
  L.view = UI.Messages.Create(inset)

  f:HookScript("OnSizeChanged", function()
    if L.refreshPending then return end
    L.refreshPending = true
    Compat.After(0.05, function() L.refreshPending = false; Chat.Refresh() end)
  end)
  f:HookScript("OnShow", function() Chat.Refresh() end)
  Chat.Layout(0)
  return f
end

--- Place the history above the prompt (if shown), the staged chips (if any) or the input.
function Chat.Layout(promptH, chipsShown)
  L.inset:ClearAllPoints()
  local top = (L.template == "PortraitFrameTemplate") and -30 or (L.template == "BasicFrameTemplateWithInset" and -28 or -36)
  L.inset:SetPoint("TOPLEFT", f, "TOPLEFT", 10, top - 34)
  local below = chipsShown and L.chips or L.inputHolder
  local extra = chipsShown and (CHIPS_H + 4) or 0
  if promptH > 0 then
    L.prompt.frame:ClearAllPoints()
    L.prompt.frame:SetPoint("BOTTOMLEFT", below, "TOPLEFT", 0, 6)
    L.inset:SetPoint("BOTTOMRIGHT", L.prompt.frame, "TOPRIGHT", 2, 6)
  else
    L.inset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 6 + STATUS_H + 4 + INPUT_H + 6 + extra)
  end
  L.chipsShown = chipsShown and true or false
end

---------------------------------------------------------------------------------------------
-- Refresh from the model
---------------------------------------------------------------------------------------------
local STATUS_DOT = { ok = "Interface\\COMMON\\Indicator-Green", warn = "Interface\\COMMON\\Indicator-Yellow",
  info = "Interface\\COMMON\\Indicator-Yellow", bad = "Interface\\COMMON\\Indicator-Red" }
local STATUS_COLOR = { ok = { 0.6, 1, 0.6 }, warn = { 1, 0.82, 0 }, info = { 0.8, 0.8, 0.8 }, bad = { 1, 0.4, 0.4 } }

function Chat.RefreshStatus()
  if not f then return end
  local text, kind, clickable = ns.LinkStatus()
  L.statusBar.text:SetText(text)
  local c = STATUS_COLOR[kind] or STATUS_COLOR.info
  L.statusBar.text:SetTextColor(c[1], c[2], c[3])
  L.statusBar.dot:SetTexture(STATUS_DOT[kind] or STATUS_DOT.info)
  L.statusBar.clickable = clickable
  -- thread status (top right)
  local t = ns.selected and State.Thread(ns.state, ns.selected)
  if t then
    local info = State.STATUS[State.StatusKey(t)]
    local e = State.Elapsed(t, ns.Now())
    L.status:SetText(info.label .. (e and (State.DOT .. State.FormatElapsed(e)) or ""))
    L.status:SetTextColor(info.color[1], info.color[2], info.color[3])
  else
    L.status:SetText("")
  end
  Chat.LayoutTop()
end

---------------------------------------------------------------------------------------------
-- Top bar layout: the dropdowns shrink (thread first, then model, then effort) so they never
-- overlap the status text, down to minimum widths; below that the status text is truncated.
---------------------------------------------------------------------------------------------
local DD_WANT = { thread = 210, model = 130, effort = 96 }
local DD_SOFT = { thread = 120, model = 92, effort = 74 }   -- first shrink step
local DD_MIN = { thread = 76, model = 62, effort = 56 }
local STATUS_MAX = 150

--- Pure width calculation (exposed for tests): returns widths by key and a status width limit
--- (nil = natural width).
function Chat.FitTop(windowW, left, statusW, keys, gap)
  local w, total = {}, 0
  for _, k in ipairs(keys) do w[k] = DD_WANT[k]; total = total + w[k] end
  local sw = math.min(statusW or 0, STATUS_MAX)
  local avail = windowW - 14 - (sw > 0 and (sw + 8) or 0) - left - gap * (#keys - 1)
  local excess = total - avail
  for _, floor in ipairs({ DD_SOFT, DD_MIN }) do
    for _, k in ipairs(keys) do
      if excess <= 0 then break end
      local cut = math.min(excess, w[k] - floor[k])
      if cut > 0 then w[k] = w[k] - cut; excess = excess - cut end
    end
  end
  local statusLimit
  if excess > 0 or (statusW or 0) > STATUS_MAX then
    local used = left
    for _, k in ipairs(keys) do used = used + w[k] end
    used = used + gap * (#keys - 1)
    statusLimit = math.max(0, windowW - 14 - used - 8)
  end
  return w, statusLimit
end

function Chat.LayoutTop()
  if not f or not L.threadDD then return end
  local keys = { "thread" }
  if L.modelDD.frame:IsShown() then keys[#keys + 1] = "model" end
  if L.effortDD.frame:IsShown() then keys[#keys + 1] = "effort" end
  L.status:SetWidth(0) -- natural width for measuring
  local statusW = (L.status:GetText() or "") ~= "" and (L.status:GetStringWidth() or 0) or 0
  local w, statusLimit = Chat.FitTop(f:GetWidth() or 520, L.left or 12, statusW, keys, L.threadDD.modern and 6 or 4)
  local dds = { thread = L.threadDD, model = L.modelDD, effort = L.effortDD }
  for _, k in ipairs(keys) do
    local d = dds[k]
    if d.width ~= w[k] then d.SetWidth(w[k]) end
  end
  if statusLimit then L.status:SetWidth(statusLimit) end
  L.topWidths, L.statusLimit = w, statusLimit
end

--- Open the thread menu (the tracker's "N more..." line uses it).
function Chat.OpenThreadMenu()
  if not f or not L.threadDD then return end
  local dd = L.threadDD.frame
  if L.threadDD.modern then
    if dd.OpenMenu then pcall(dd.OpenMenu, dd) end
  elseif _G.ToggleDropDownMenu then
    pcall(ToggleDropDownMenu, 1, nil, dd, dd, 0, 0)
  end
end

function Chat.Refresh()
  if not f or not f:IsShown() then return end
  local st, tid = ns.state, ns.selected
  local t = tid and State.Thread(st, tid)
  local fo = tid and State.Focus(st, tid)

  -- dropdowns
  L.threadDD.Refresh(t and threadLabel(t) or nil)
  if fo and L.pendingModel and fo.model == L.pendingModel then L.pendingModel = nil end
  if fo and L.pendingEffort and not L.pendingModel and fo.effort == L.pendingEffort then L.pendingEffort = nil end
  local models = fo and fo.models or {}
  if #models > 0 then
    local cur = L.pendingModel or (fo and fo.model)
    local name = cur
    for _, m in ipairs(models) do if m.id == cur then name = shortModelName(m.name) end end
    L.modelDD.Refresh(name and Compat.Escape(name) or nil)
    L.modelDD.frame:Show()
  else
    L.modelDD.frame:Hide()
  end
  local choice, effort = currentEffort()
  if choice and #models > 0 then
    L.effortDD.Refresh(Chat.EffortLabel(effort))
    L.effortDD.frame:Show()
  else
    L.effortDD.frame:Hide()
  end

  -- prompt
  local width = L.inputHolder:GetWidth() or 400
  if width < 100 then width = 400 end
  local promptH = L.prompt:Update(fo and fo.pending or nil, tid, f:GetWidth() - 22)
  local chipsShown = Chat.UpdateChips(fo and not fo.pending and fo.staged or nil)
  Chat.Layout(promptH, chipsShown)

  -- history
  local list = tid and State.Messages(st, tid) or {}
  if echo and echo.tid == tid then
    local delivered = false
    for k = #list, 1, -1 do
      local m = list[k]
      if m.i > echo.after and m.r == "u" then delivered = true break end
      if m.i <= echo.after then break end
    end
    if delivered then
      echo = nil
    else
      local copy = {}
      for k, m in ipairs(list) do copy[k] = m end
      copy[#copy + 1] = { i = (list[#list] and list[#list].i or 0) + 1, r = "u", ts = ns.Now(),
        segs = { { "p", echo.text } }, more = false, size = #echo.text, echo = true }
      list = copy
    end
  end
  local emptyText
  if not tid then
    emptyText = ns.state.snap and "Pick a thread from the menu above" or "Waiting for the T3Bridge companion..."
  elseif not fo then
    emptyText = State.IsOffline(st, ns.Now()) and not ns.demo and "Companion offline" or "Loading thread..."
  end
  L.view:SetMessages({
    list = list,
    emptyText = emptyText,
    canLoadEarlier = State.CanLoadEarlier(fo, list),
    onEarlier = function() if tid and list[1] then ns.Send("hist", { tid, tostring(list[1].i) }) end end,
  })

  -- buttons
  local running = t and t.st == "running"
  L.stop:SetShown(running and true or false)
  if tid then L.send:Enable() else L.send:Disable() end
  if tid and not ns.demo then L.attach:Enable(); L.attach:SetAlpha(1) else L.attach:Disable(); L.attach:SetAlpha(0.5) end
  if L.eb.Instructions then
    L.eb.Instructions:SetText((fo and fo.pending) and "Type an answer - Enter sends" or "Message T3 Code - Enter sends, Shift+Enter adds a line")
  end
  Chat.RefreshStatus()
end

---------------------------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------------------------
function UI.OpenChat(tid)
  if not f then create() end
  f:Show()
  if f.Raise then f:Raise() end
  local target = tid or ns.selected or ns.DefaultThread()
  if target then ns.SelectThread(target) end
  Chat.Refresh()
  if ns.Inbound then ns.Inbound.Reschedule() end
end

function UI.ToggleChat()
  if f and f:IsShown() then f:Hide() else UI.OpenChat(nil) end
end

function UI.ChatIsOpen() return f ~= nil and f:IsShown() end

function UI.ResetChatPosition()
  ns.db.chat.point, ns.db.chat.w, ns.db.chat.h = nil, 520, 560
  if f then
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetSize(520, 560)
  end
end

--- Test/diagnostic access to the top bar pieces.
function UI.ChatTopBar() return L.threadDD, L.modelDD, L.effortDD, L.status, L.topWidths, L.statusLimit end
function UI.ChatInputBar() return L.eb, L.attach, L.send, L.chips, L.chipList, L.inputHolder, L.chipsShown end
function UI.ChatView() return L.view end
Chat.ChooseModel = function(id) chooseModel(id) end
Chat.ChooseEffort = function(v) chooseEffort(v) end

function UI.ChatDiagnostics() return L.template, L.inputKind, L.threadDD and (L.threadDD.modern and "WowStyle1DropdownTemplate" or "UIDropDownMenuTemplate") end

ns.On("model", function() Chat.Refresh() end)
ns.On("selected", function(tid)
  if L.lastSelected ~= tid then L.pendingModel, L.pendingEffort = nil, nil end
  if echo and echo.tid ~= tid then echo = nil end
  L.lastSelected = tid
end)
ns.On("outbox", function() Chat.RefreshStatus() end)
ns.On("link", function() Chat.RefreshStatus() end)
ns.On("notice", function()
  Chat.RefreshStatus()
  Compat.After(ns.NOTICE_S + 0.1, function() Chat.RefreshStatus() end)
end)
ns.On("tick", function() if f and f:IsShown() then Chat.RefreshStatus() end end)
ns.On("sendFailed", function(item)
  if item.kind == "send" then
    echo = nil
    if f and L.eb and (L.eb:GetText() or "") == "" then L.eb:SetText(item.args[2] or "") end
    ns.Print("Message not delivered: companion not responding. Your text is back in the input box.")
  elseif item.kind == "ans" then
    if L.prompt then L.prompt.sent = nil end
    ns.Print("Answer not delivered: companion not responding.")
  elseif item.kind == "model" then
    L.pendingModel, L.pendingEffort = nil, nil
  end
  Chat.Refresh()
end)
ns.On("sent", function(ev)
  if ev and ev.err and ev.item and ev.item.kind == "send" then echo = nil end
  Chat.Refresh()
end)
