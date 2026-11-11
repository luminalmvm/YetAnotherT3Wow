-- T3Bridge CopyDialog: shows a message in an EditBox with the text highlighted for Ctrl+C.
local _, ns = ...
local Compat = ns.Compat

ns.UI = ns.UI or {}
local CopyDialog = {}
ns.UI.CopyDialog = CopyDialog

local dlg

--- Plain text for a message: paragraphs as-is, code inside ``` fences.
function CopyDialog.PlainText(msg)
  local parts = {}
  for _, seg in ipairs(msg.segs or {}) do
    if seg[1] == "c" then parts[#parts + 1] = "```\n" .. seg[2] .. "\n```" else parts[#parts + 1] = seg[2] end
  end
  return table.concat(parts, "\n\n")
end

local function create()
  local tmpl = Compat.FirstTemplate({ "BasicFrameTemplateWithInset", "PortraitFrameTemplate" })
  local f = CreateFrame("Frame", "T3BridgeCopyDialog", UIParent, tmpl or Compat.BackdropTemplate())
  f:SetSize(480, 320)
  f:SetPoint("CENTER", 0, 60)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  if not tmpl and f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
  end
  local title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if f.SetTitle then f:SetTitle("Copy message") else
    title:SetPoint("TOP", 0, -6)
    title:SetText("Copy message")
  end

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 14, 10)
  hint:SetText("Press Ctrl+C to copy, then Esc to close.")

  local sTmpl = Compat.FirstTemplate({ "UIPanelScrollFrameTemplate", "ScrollFrameTemplate" })
  local scroll = CreateFrame("ScrollFrame", nil, f, sTmpl)
  scroll:SetPoint("TOPLEFT", 12, -30)
  scroll:SetPoint("BOTTOMRIGHT", -32, 28)
  local eb = CreateFrame("EditBox", nil, scroll)
  eb:SetMultiLine(true)
  eb:SetAutoFocus(false)
  eb:SetFontObject(ChatFontNormal)
  eb:SetWidth(420)
  eb:SetScript("OnEscapePressed", function() f:Hide() end)
  eb:SetScript("OnTextChanged", function(self, user)
    if user and f.text then self:SetText(f.text); self:HighlightText() end -- read-only
  end)
  scroll:SetScrollChild(eb)
  scroll:HookScript("OnSizeChanged", function(_, w) eb:SetWidth(math.max(100, (w or 420) - 4)) end)
  f.eb = eb
  f:Hide()
  table.insert(UISpecialFrames, "T3BridgeCopyDialog")
  return f
end

function CopyDialog.Show(msg)
  dlg = dlg or create()
  dlg.text = Compat.Escape(CopyDialog.PlainText(msg))
  dlg.eb:SetText(dlg.text)
  dlg:Show()
  dlg.eb:SetFocus()
  dlg.eb:HighlightText()
  dlg.eb:SetCursorPosition(0)
  dlg.eb:HighlightText()
end
