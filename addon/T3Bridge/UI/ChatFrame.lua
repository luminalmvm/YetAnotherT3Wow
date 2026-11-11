-- T3Bridge ChatFrame: the in-game chat window (thread, model and effort pickers, history, prompt, input,
-- image attachments: Attach button + menu, Ctrl+V, staged chips; PROTOCOL rev 1.3; subagents: Up button,
-- breadcrumb and the Subagents strip; rev 1.4).
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
local UP_W = 26                       -- Up button left of the thread dropdown (rev 1.4)
local CRUMB_H = 16                    -- breadcrumb line under the top bar (rev 1.4)
local KIDS_HEAD_H, KID_H = 18, 16     -- Subagents strip header and rows (rev 1.4)
local CRUMB_SEP = " \194\187 "         -- " >> " as U+00BB (Latin-1; in the WoW fonts)
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
local function threadLabel(t, depth)
  local info = State.STATUS[State.StatusKey(t)]
  local c = info.color
  local title = t.title
  depth = depth or 0
  local max = 48 - depth * 4
  if #title > max then title = Codec.Utf8Truncate(title, max - 2) .. "..." end
  -- Subagents are indented under their parent with spaces and an ASCII "-" (every WoW font has it).
  local indent = depth > 0 and ("|cff808080" .. string.rep("   ", depth - 1) .. " - |r") or ""
  return indent .. string.format("|cff%02x%02x%02x%s|r", c[1] * 255, c[2] * 255, c[3] * 255, Compat.Escape(title))
end
Chat.ThreadLabel = threadLabel

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
  local groups = State.ThreadMenu(ns.state)
  if #groups == 0 then root:CreateTitle("No threads yet") return end
  -- Up to 30 threads (PROTOCOL D15) plus subagents: scroll instead of running off the screen, where supported.
  if root.SetScrollMode then pcall(root.SetScrollMode, root, 440) end
  for _, g in ipairs(groups) do
    root:CreateTitle(g.title)
    for _, it in ipairs(g.items) do
      local t = it.t
      root:CreateRadio(threadLabel(t, it.depth), function() return ns.selected == t.id end,
        function() ns.SelectThread(t.id) end, t.id)
    end
  end
end

local function buildThreadMenuLegacy(level)
  local groups = State.ThreadMenu(ns.state)
  if #groups == 0 then legacyAdd("No threads yet", { isTitle = true, notCheckable = true }, level) return end
  for _, g in ipairs(groups) do
    legacyAdd(g.title, { isTitle = true, notCheckable = true }, level)
    for _, it in ipairs(g.items) do
      local t = it.t
      legacyAdd(threadLabel(t, it.depth), { checked = (ns.selected == t.id), func = function()
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
-- Subagents (rev 1.4): Up button, breadcrumb, Subagents strip
---------------------------------------------------------------------------------------------
--- Go up one level: open the parent of the thread shown (a subagent). Returns the parent tid or nil.
function Chat.Up()
  local tid = ns.selected
  local parent = tid and State.ParentOf(ns.state, tid)
  if not parent then return nil end
  ns.SelectThread(parent)
  return parent
end

--- Breadcrumb widths (pure, for tests): naturals = natural widths root .. current, sepW = separator
--- width, avail = room. The current thread keeps up to 45 % (at least 80 px); ancestors share the rest
--- (the widest shrink first), none below minW. Returns widths.
function Chat.FitCrumbs(naturals, sepW, avail, minW)
  minW = minW or 30
  local n = #naturals
  local w = {}
  for k = 1, n do w[k] = naturals[k] end
  if n == 0 then return w end
  local total = (n - 1) * sepW
  for k = 1, n do total = total + w[k] end
  if total <= avail then return w end
  local room = avail - (n - 1) * sepW
  local last = math.min(naturals[n], math.max(80, math.floor(room * 0.45)))
  local anc = n - 1
  local budget = room - last
  if budget < anc * minW then
    for k = 1, anc do w[k] = math.min(naturals[k], minW) end
    local used = 0
    for k = 1, anc do used = used + w[k] end
    w[n] = math.max(minW, room - used)
    return w
  end
  -- water-fill the ancestors: find a cap c with sum(min(natural, c)) <= budget
  local lo, hi = minW, 0
  for k = 1, anc do hi = math.max(hi, naturals[k]) end
  for _ = 1, 30 do
    local mid = (lo + hi) / 2
    local sum = 0
    for k = 1, anc do sum = sum + math.min(naturals[k], mid) end
    if sum > budget then hi = mid else lo = mid end
  end
  local used = 0
  for k = 1, anc do w[k] = math.floor(math.min(naturals[k], lo)); used = used + w[k] end
  w[n] = math.min(naturals[n], math.max(last, room - used))
  return w
end

local function crumbOnEnter(self)
  self.text:SetTextColor(UI.Messages.LINK_HOVER[1], UI.Messages.LINK_HOVER[2], UI.Messages.LINK_HOVER[3])
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
  GameTooltip:SetText(Compat.Escape(self.title or ""), 1, 1, 1, true)
  GameTooltip:AddLine("Click: open this thread", 0.5, 0.8, 1)
  GameTooltip:Show()
end

local function crumbOnLeave(self)
  local c = UI.Messages.LINK_COLOR
  self.text:SetTextColor(c[1], c[2], c[3])
  GameTooltip:Hide()
end

local function crumbButton(i)
  local b = L.crumbBtns[i]
  if b then return b end
  b = CreateFrame("Button", nil, L.crumb)
  b:SetHeight(CRUMB_H)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("LEFT", 0, 0)
  b.text:SetJustifyH("LEFT")
  b.text:SetWordWrap(false)
  b:SetScript("OnEnter", crumbOnEnter)
  b:SetScript("OnLeave", crumbOnLeave)
  b:SetScript("OnClick", function(self) if self.tid and self.tid ~= ns.selected then ns.SelectThread(self.tid) end end)
  L.crumbBtns[i] = b
  return b
end

local function crumbSep(i)
  local s = L.crumbSeps[i]
  if s then return s end
  s = L.crumb:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  s:SetText(CRUMB_SEP)
  L.crumbSeps[i] = s
  return s
end

--- Show the breadcrumb (root .. shown thread) when the shown thread is a subagent. Returns its height.
function Chat.UpdateCrumbs(tid)
  local path = tid and State.Path(ns.state, tid) or {}
  local child = tid and State.ParentOf(ns.state, tid) ~= nil
  if not child or #path < 2 then
    L.crumb:Hide()
    L.crumbPath = nil
    return 0
  end
  L.crumb:Show()
  L.crumbPath = path
  local avail = math.max(60, (f:GetWidth() or 520) - (L.left or 12) - 16)
  local naturals, sepW = {}, 0
  for k, r in ipairs(path) do
    local b = crumbButton(k)
    b.text:SetWidth(0)
    b.text:SetText(Compat.Escape(r.title))
    naturals[k] = math.ceil(b.text:GetStringWidth() or (#r.title * 6)) + 2
  end
  local s1 = crumbSep(1)
  sepW = math.ceil(s1:GetStringWidth() or 10)
  local widths = Chat.FitCrumbs(naturals, sepW, avail, 30)
  local x = 0
  for k, r in ipairs(path) do
    local b = crumbButton(k)
    local last = (k == #path)
    b.tid, b.title = r.id, r.title
    b:ClearAllPoints()
    b:SetPoint("LEFT", L.crumb, "LEFT", x, 0)
    b:SetWidth(widths[k])
    b.text:SetWidth(widths[k])
    if last then
      b.text:SetTextColor(1, 1, 1)
      b:EnableMouse(false)
    else
      local c = UI.Messages.LINK_COLOR
      b.text:SetTextColor(c[1], c[2], c[3])
      b:EnableMouse(true)
    end
    b:Show()
    x = x + widths[k]
    if not last then
      local sp = crumbSep(k)
      sp:ClearAllPoints()
      sp:SetPoint("LEFT", L.crumb, "LEFT", x, 0)
      sp:Show()
      x = x + sepW
    end
  end
  for k = #path + 1, #L.crumbBtns do L.crumbBtns[k]:Hide(); L.crumbBtns[k].tid = nil end
  for k = #path, #L.crumbSeps do L.crumbSeps[k]:Hide() end
  L.crumbWidths = widths
  return CRUMB_H
end

local function kidRowOnEnter(self)
  local t = self.thread
  if not t then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(Compat.Escape(t.title), 1, 1, 1, true)
  local info = State.STATUS[State.StatusKey(t)]
  GameTooltip:AddDoubleLine("Status", info.label, 0.7, 0.7, 0.7, info.color[1], info.color[2], info.color[3])
  local e = State.Elapsed(t, ns.Now())
  if e then GameTooltip:AddDoubleLine(t.t1 and "Took" or "Elapsed", State.FormatElapsed(e), 0.7, 0.7, 0.7, 1, 0.82, 0) end
  if (t.kids or 0) > 0 then GameTooltip:AddDoubleLine("Subagents", tostring(t.kids), 0.7, 0.7, 0.7, 1, 1, 1) end
  GameTooltip:AddLine("Click: open this subagent", 0.5, 0.8, 1)
  GameTooltip:Show()
end

local function kidRow(i)
  local b = L.kidRows[i]
  if b then return b end
  b = CreateFrame("Button", nil, L.kids)
  b:SetHeight(KID_H)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(12, 12)
  b.icon:SetPoint("LEFT", 16, 0)
  b.timer = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.timer:SetPoint("RIGHT", -6, 0)
  b.timer:SetJustifyH("RIGHT")
  b.badge = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.badge:SetPoint("RIGHT", b.timer, "LEFT", -6, 0)
  b.title = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.title:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
  b.title:SetPoint("RIGHT", b.badge, "LEFT", -6, 0)
  b.title:SetJustifyH("LEFT")
  b.title:SetWordWrap(false)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  hl:SetBlendMode("ADD")
  hl:SetAllPoints(b)
  hl:SetAlpha(0.5)
  local ag = b:CreateAnimationGroup()
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(1)
  a:SetToAlpha(0.35)
  a:SetDuration(0.7)
  a:SetSmoothing("IN_OUT")
  ag:SetLooping("BOUNCE")
  b.pulse = ag
  b:SetScript("OnEnter", kidRowOnEnter)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function(self)
    if self.more then Chat.OpenThreadMenu() elseif self.thread then ns.SelectThread(self.thread.id) end
  end)
  L.kidRows[i] = b
  return b
end

--- Is the Subagents strip expanded? Saved per character-independent setting; a subagent that needs
--- you expands it by itself.
function Chat.KidsOpen(counts)
  if counts and counts.needs > 0 then return true end
  return ns.db and ns.db.chat and ns.db.chat.kidsOpen == true or false
end

function Chat.ToggleKids()
  if not ns.db then return end
  ns.db.chat.kidsOpen = not (ns.db.chat.kidsOpen == true)
  Chat.Refresh()
end

--- Rows the strip may use at the current window height (the 420x360 minimum keeps the history usable).
function Chat.KidRowsFit(frameH, crumbH)
  return math.max(1, math.min(8, math.floor(((frameH or 560) - 290 - (crumbH or 0)) / KID_H)))
end

--- Show the Subagents strip for thread tid. Returns its height (0 = hidden).
function Chat.UpdateKids(tid, crumbH)
  local list, total = {}, 0
  if tid then list, total = State.Kids(ns.state, tid) end
  if total == 0 then
    L.kids:Hide()
    for _, b in ipairs(L.kidRows) do b:Hide(); b.thread = nil; if b.pulse:IsPlaying() then b.pulse:Stop() end end
    L.kidsShown = 0
    return 0
  end
  local counts = State.KidCounts(list)
  local open = Chat.KidsOpen(counts)
  L.kids:Show()
  L.kidsHead.text:SetText(State.KidsLabel(total, counts.running, counts.needs))
  L.kidsHead.arrow:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
  L.kidsHead.open = open
  local shown = 0
  local h = KIDS_HEAD_H
  if open then
    local fit = Chat.KidRowsFit(f:GetHeight(), crumbH)
    local more = total - #list
    local n = #list
    if n > fit or more > 0 then n = math.min(n, math.max(0, fit - 1)) end
    local offline = State.IsOffline(ns.state, ns.Now()) and not ns.demo
    for k = 1, n do
      local t = list[k]
      local b = kidRow(k)
      local key = State.StatusKey(t)
      local info = State.STATUS[key]
      b.thread, b.more = t, nil
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", L.kids, "TOPLEFT", 0, -(KIDS_HEAD_H + (k - 1) * KID_H))
      b:SetPoint("TOPRIGHT", L.kids, "TOPRIGHT", 0, -(KIDS_HEAD_H + (k - 1) * KID_H))
      b.icon:SetTexture(info.icon)
      b.icon:Show()
      b.title:SetText(Compat.Escape(t.title))
      b.title:SetTextColor(info.color[1], info.color[2], info.color[3])
      b.badge:SetText((t.kids or 0) > 0 and ("+" .. t.kids) or "")
      local e = State.Elapsed(t, ns.Now())
      b.timer:SetText(e and State.FormatElapsed(e) or "")
      b.timer:SetTextColor(info.timer[1], info.timer[2], info.timer[3])
      b:SetAlpha(offline and 0.55 or 1)
      if info.pulse and not offline then
        if not b.pulse:IsPlaying() then b.pulse:Play() end
      elseif b.pulse:IsPlaying() then b.pulse:Stop() end
      b:Show()
    end
    shown = n
    local rest = total - n
    if rest > 0 then
      local b = kidRow(n + 1)
      b.thread, b.more = nil, true
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", L.kids, "TOPLEFT", 0, -(KIDS_HEAD_H + n * KID_H))
      b:SetPoint("TOPRIGHT", L.kids, "TOPRIGHT", 0, -(KIDS_HEAD_H + n * KID_H))
      b.icon:Hide()
      b.title:SetText(rest .. " more...")
      b.title:SetTextColor(0.6, 0.6, 0.6)
      b.badge:SetText("")
      b.timer:SetText("")
      if b.pulse:IsPlaying() then b.pulse:Stop() end
      b:SetAlpha(1)
      b:Show()
      shown = n + 1
    end
    h = KIDS_HEAD_H + shown * KID_H + 2
  end
  for k = shown + 1, #L.kidRows do
    local b = L.kidRows[k]
    b:Hide(); b.thread, b.more = nil, nil
    if b.pulse:IsPlaying() then b.pulse:Stop() end
  end
  L.kidsShown = shown
  L.kids:SetHeight(h)
  return h
end

--- Per-second timers of the strip rows.
function Chat.TickKids()
  if not L.kidRows then return end
  local now = ns.Now()
  for _, b in ipairs(L.kidRows) do
    if b:IsShown() and b.thread then
      local e = State.Elapsed(b.thread, now)
      b.timer:SetText(e and State.FormatElapsed(e) or "")
    end
  end
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

  -- rev 1.4: Up button (shown for a subagent) left of the thread dropdown, which then moves right.
  L.top = top
  L.up = CreateFrame("Button", nil, f)
  L.up:SetSize(UP_W, UP_W)
  L.up:SetPoint("TOPLEFT", f, "TOPLEFT", left - 4, top)
  L.up:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Up")
  L.up:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Down")
  L.up:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-PrevPage-Disabled")
  L.up:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  L.up:SetScript("OnClick", function() Chat.Up() end)
  L.up:SetScript("OnEnter", function(self)
    local parent = ns.selected and State.ParentOf(ns.state, ns.selected)
    local pt = parent and State.Thread(ns.state, parent)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:SetText("Up to the parent thread")
    if pt then GameTooltip:AddLine(Compat.Escape(pt.title), 1, 1, 1, true) end
    GameTooltip:AddLine("/t3 up does the same", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  L.up:SetScript("OnLeave", function() GameTooltip:Hide() end)
  L.up:Hide()

  -- rev 1.4: breadcrumb (root >> ... >> this subagent) under the top bar; ancestors are clickable.
  L.crumb = CreateFrame("Frame", nil, f)
  L.crumb:SetHeight(CRUMB_H)
  L.crumb:SetPoint("TOPLEFT", f, "TOPLEFT", left + 2, top - 30)
  L.crumb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, top - 30)
  L.crumb:Hide()
  L.crumbBtns, L.crumbSeps = {}, {}

  -- rev 1.4: Subagents strip above the history: header "Subagents (3 . 1 running)" + rows.
  L.kids = CreateFrame("Frame", nil, f)
  L.kids:SetHeight(KIDS_HEAD_H)
  L.kids:Hide()
  L.kids.bg = L.kids:CreateTexture(nil, "BACKGROUND")
  L.kids.bg:SetColorTexture(0, 0, 0, 0.25)
  L.kids.bg:SetAllPoints(L.kids)
  L.kidsHead = CreateFrame("Button", nil, L.kids)
  L.kidsHead:SetHeight(KIDS_HEAD_H)
  L.kidsHead:SetPoint("TOPLEFT")
  L.kidsHead:SetPoint("TOPRIGHT")
  L.kidsHead.arrow = L.kidsHead:CreateTexture(nil, "ARTWORK")
  L.kidsHead.arrow:SetSize(12, 12)
  L.kidsHead.arrow:SetPoint("LEFT", 2, 0)
  L.kidsHead.text = L.kidsHead:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  L.kidsHead.text:SetPoint("LEFT", L.kidsHead.arrow, "RIGHT", 4, 0)
  L.kidsHead.text:SetJustifyH("LEFT")
  L.kidsHead.line = L.kidsHead:CreateTexture(nil, "BORDER")
  L.kidsHead.line:SetColorTexture(1, 0.82, 0, 0.25)
  L.kidsHead.line:SetHeight(1)
  L.kidsHead.line:SetPoint("BOTTOMLEFT")
  L.kidsHead.line:SetPoint("BOTTOMRIGHT")
  local khl = L.kidsHead:CreateTexture(nil, "HIGHLIGHT")
  khl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  khl:SetBlendMode("ADD")
  khl:SetAllPoints(L.kidsHead)
  khl:SetAlpha(0.35)
  L.kidsHead:SetScript("OnClick", function() Chat.ToggleKids() end)
  L.kidsHead:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Subagent threads of this thread")
    GameTooltip:AddLine(self.open and "Click: hide the list" or "Click: show the list", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  L.kidsHead:SetScript("OnLeave", function() GameTooltip:Hide() end)
  L.kidRows = {}

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

--- Up button: shown for a subagent; the thread dropdown moves right to make room. Returns true if shown.
function Chat.UpdateUp(tid)
  local child = tid and State.ParentOf(ns.state, tid) ~= nil
  local shift = child and UP_W or 0
  if L.upShift ~= shift then
    L.upShift = shift
    L.threadDD.frame:ClearAllPoints()
    L.threadDD.frame:SetPoint("TOPLEFT", f, "TOPLEFT", (L.left or 12) + shift - (L.threadDD.modern and 0 or 16), (L.top or -30) - 2)
  end
  L.up:SetShown(child and true or false)
  return child and true or false
end

--- Place the history above the prompt (if shown), the staged chips (if any) or the input, and below
--- the breadcrumb and the Subagents strip (rev 1.4) when they are shown.
function Chat.Layout(promptH, chipsShown, crumbH, kidsH)
  L.inset:ClearAllPoints()
  local top = (L.template == "PortraitFrameTemplate") and -30 or (L.template == "BasicFrameTemplateWithInset" and -28 or -36)
  local y = top - 34 - (crumbH or 0)
  if (kidsH or 0) > 0 then
    L.kids:ClearAllPoints()
    L.kids:SetPoint("TOPLEFT", f, "TOPLEFT", 12, y + 2)
    L.kids:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, y + 2)
    y = y - kidsH - 2
  end
  L.inset:SetPoint("TOPLEFT", f, "TOPLEFT", 10, y)
  L.insetTop = y
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
  local w, statusLimit = Chat.FitTop(f:GetWidth() or 520, (L.left or 12) + (L.upShift or 0), statusW, keys, L.threadDD.modern and 6 or 4)
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

  -- Up button, breadcrumb and Subagents strip (rev 1.4)
  Chat.UpdateUp(tid)
  local crumbH = Chat.UpdateCrumbs(tid)
  local kidsH = Chat.UpdateKids(tid, crumbH)

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
  Chat.Layout(promptH, chipsShown, crumbH, kidsH)

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
--- Test/diagnostic access to the subagent pieces (rev 1.4).
function UI.ChatSubagents() return L.up, L.crumb, L.crumbBtns, L.kids, L.kidRows, L.kidsHead, L.crumbWidths, L.kidsShown end
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
ns.On("tick", function() if f and f:IsShown() then Chat.RefreshStatus(); Chat.TickKids() end end)
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
