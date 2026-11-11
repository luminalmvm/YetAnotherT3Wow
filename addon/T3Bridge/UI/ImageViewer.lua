-- T3Bridge ImageViewer: a movable window that shows one image slot larger (PROTOCOL rev 1.3, D16).
-- The slot texture holds at most 512x512 pixels, so the viewer shows the image at about one texture
-- pixel per screen pixel (at most 1.5x), shrunk to fit the screen. Esc closes it.
local _, ns = ...
local Compat, State = ns.Compat, ns.State

ns.UI = ns.UI or {}
local Viewer = {}
ns.UI.ImageViewer = Viewer

local PAD_X, PAD_TOP, PAD_BOTTOM = 12, 32, 12
local f, L = nil, {}

--- Display size of a w x h image: ~1 texture pixel per physical pixel, at most 1.5x, at most maxW x maxH.
function Viewer.FitSize(w, h, effScale, maxW, maxH)
  local k = math.min(1.5, 1 / math.max(0.1, effScale or 1))
  local s = math.min(k, maxW / w, maxH / h)
  return math.max(1, math.floor(w * s + 0.5)), math.max(1, math.floor(h * s + 0.5))
end

local function create()
  -- No portrait here: it would cover the image's corner. Same chrome family as the chat window.
  local tmpl = Compat.FirstTemplate({ "BasicFrameTemplateWithInset", "PortraitFrameTemplate" })
  f = CreateFrame("Frame", "T3BridgeImageViewer", UIParent, tmpl or Compat.BackdropTemplate())
  L.template = tmpl or "BackdropTemplate"
  f:SetSize(300, 200)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:Hide()
  table.insert(UISpecialFrames, "T3BridgeImageViewer")
  if tmpl == "PortraitFrameTemplate" then
    local icon = "Interface\\AddOns\\T3Bridge\\Media\\icon"
    if f.SetPortraitTextureRaw then f:SetPortraitTextureRaw(icon)
    elseif f.SetPortraitToAsset then f:SetPortraitToAsset(icon)
    elseif f.PortraitContainer and f.PortraitContainer.portrait then f.PortraitContainer.portrait:SetTexture(icon) end
  elseif not tmpl then
    if f.SetBackdrop then
      f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    end
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
  end
  L.title = (f.TitleText) or f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  if not f.TitleText then L.title:SetPoint("TOP", 0, -10) end

  local drag = CreateFrame("Frame", nil, f)
  drag:SetPoint("TOPLEFT", f, "TOPLEFT", 55, 0)
  drag:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, 0)
  drag:SetHeight(24)
  drag:EnableMouse(true)
  drag:SetScript("OnMouseDown", function(_, b) if b == "LeftButton" then f:StartMoving(); f.moving = true end end)
  drag:SetScript("OnMouseUp", function() if f.moving then f:StopMovingOrSizing(); f.moving = false end end)
  f:HookScript("OnHide", function() if f.moving then f:StopMovingOrSizing(); f.moving = false end end)

  L.box = CreateFrame("Frame", nil, f)
  if ns.UI.Messages and ns.UI.Messages.AddImageFrame then ns.UI.Messages.AddImageFrame(L.box) end
  L.tex = L.box:CreateTexture(nil, "ARTWORK")
  L.tex:SetPoint("TOPLEFT", 1, -1)
  L.tex:SetPoint("BOTTOMRIGHT", -1, 1)
  return f
end

--- img = { s = slot, w, h, alt }.
function Viewer.Show(img)
  if not img or not img.s or img.s < 1 or not img.w then return end
  if not f then create() end
  local uiW, uiH = UIParent:GetWidth() or 1024, UIParent:GetHeight() or 768
  local w, h = Viewer.FitSize(img.w, img.h, UIParent:GetEffectiveScale(), uiW * 0.9 - 2 * PAD_X, uiH * 0.85 - PAD_TOP - PAD_BOTTOM)
  local top = (L.template == "PortraitFrameTemplate") and 62 or PAD_TOP
  f:SetSize(math.max(220, w + 2 * PAD_X + 2), h + top + PAD_BOTTOM + 2)
  L.box:ClearAllPoints()
  L.box:SetPoint("TOP", f, "TOP", 0, -top)
  L.box:SetSize(w + 2, h + 2)
  L.tex:SetTexture(ns.UI.Messages.SlotTexture(img.s))
  L.tex:SetTexCoord(State.ImageTexCoords(img.w, img.h))
  local title = Compat.Escape(img.alt or "Image")
  if f.SetTitle then f:SetTitle(title) elseif L.title then L.title:SetText(title) end
  L.current = img
  f:Show()
  if f.Raise then f:Raise() end
end

function Viewer.Hide() if f then f:Hide() end end
function Viewer.IsShown() return f ~= nil and f:IsShown() end
--- Test access.
function Viewer.Current() return L.current, L.box, L.tex, f end
