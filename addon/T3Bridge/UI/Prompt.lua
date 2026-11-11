-- T3Bridge Prompt: approval / input request panel shown above the input box when focus.pending exists.
local _, ns = ...
local Compat = ns.Compat

ns.UI = ns.UI or {}
local Prompt = {}
ns.UI.Prompt = Prompt

local Panel = {}
Panel.__index = Panel

function Prompt.Create(parent)
  local p = setmetatable({ buttons = {} }, Panel)
  local f = CreateFrame("Frame", nil, parent, Compat.BackdropTemplate())
  p.frame = f
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 14,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.12, 0.07, 0.02, 0.92)
    f:SetBackdropBorderColor(1, 0.5, 0, 0.9)
  end
  p.icon = f:CreateTexture(nil, "ARTWORK")
  p.icon:SetSize(28, 28)
  p.icon:SetPoint("TOPLEFT", 8, -8)
  p.icon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
  p.kind = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  p.kind:SetPoint("TOPLEFT", p.icon, "TOPRIGHT", 8, -1)
  p.kind:SetTextColor(1, 0.5, 0)
  p.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  p.text:SetPoint("TOPLEFT", p.kind, "BOTTOMLEFT", 0, -4)
  p.text:SetJustifyH("LEFT")
  p.text:SetJustifyV("TOP")
  p.text:SetWordWrap(true)
  p.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  p.hint:SetJustifyH("LEFT")
  f:Hide()
  return p
end

function Panel:Button(k)
  local b = self.buttons[k]
  if not b then
    b = CreateFrame("Button", nil, self.frame, "UIPanelButtonTemplate")
    b:SetHeight(22)
    b:SetScript("OnClick", function(btn)
      if not self.pending or self.sent then return end
      self.sent = btn.optLabel
      ns.Send("ans", { self.tid, self.pending.rid, btn.optId }, { label = btn.optLabel })
      self:Layout(self.width)
    end)
    self.buttons[k] = b
  end
  return b
end

--- Show the request for `tid`, or hide when pending is nil. Returns the panel height (0 = hidden).
function Panel:Update(pending, tid, width)
  if not pending then
    self.pending, self.sent = nil, nil
    self.frame:Hide()
    return 0
  end
  if not self.pending or self.pending.rid ~= pending.rid or self.tid ~= tid then
    self.sent = nil -- a new request
  end
  self.pending, self.tid = pending, tid
  return self:Layout(width)
end

--- Called when the user answers with free text from the input box.
function Panel:MarkSent(label)
  if self.pending then
    self.sent = label
    self:Layout(self.width)
  end
end

function Panel:Layout(width)
  local p = self.pending
  if not p then return 0 end
  width = width or self.width or 400
  self.width = width
  local f = self.frame
  f:SetWidth(width)
  self.kind:SetText(p.kind == "input" and "Input needed" or "Approval needed")
  self.text:SetWidth(width - 60)
  self.text:SetText(Compat.Escape(p.text))
  local y = 8 + 14 + 4 + math.max(self.text:GetStringHeight() or 12, 12) + 8
  -- option buttons, wrapped into rows
  local x, rowY = 44, y
  for k, opt in ipairs(p.options) do
    local b = self:Button(k)
    b.optId, b.optLabel = opt.id, opt.label
    b:SetText(Compat.Escape(opt.label))
    local bw = math.max(80, (b:GetFontString() and b:GetFontString():GetStringWidth() or 60) + 28)
    b:SetWidth(bw)
    if x + bw > width - 8 and x > 44 then x, rowY = 44, rowY + 26 end
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -rowY)
    if self.sent then b:Disable() else b:Enable() end
    b:Show()
    x = x + bw + 6
  end
  for k = #p.options + 1, #self.buttons do self.buttons[k]:Hide() end
  if #p.options > 0 then y = rowY + 26 end
  self.hint:ClearAllPoints()
  self.hint:SetPoint("TOPLEFT", f, "TOPLEFT", 44, -y)
  self.hint:SetWidth(width - 52)
  if self.sent then
    self.hint:SetText("Sent: " .. Compat.Escape(self.sent) .. " \226\128\148 waiting for T3 Code...")
  elseif p.kind == "input" or #p.options == 0 then
    self.hint:SetText("Type your answer in the box below and press Enter.")
  else
    self.hint:SetText("Or type a different answer below and press Enter.")
  end
  y = y + 16
  f:SetHeight(y)
  f:Show()
  return y
end
