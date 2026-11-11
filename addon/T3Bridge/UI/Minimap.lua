-- T3Bridge Minimap button: a self-contained 31x31 button (no LibDBIcon). Left and right click
-- both toggle the in-game chat window. Never opens the external app.
--
-- Placement: drag it around the minimap ring (the angle is saved in T3BridgeDB.minimap). Until
-- the user drags it, the button picks a free spot by itself: it looks at the other minimap
-- buttons (Questie, Spoken, ...) and takes the first angle near the top-right of the ring that is
-- clear of them. `/t3 minimap reset` forgets a dragged position and picks a free spot again.
-- Square and other minimap shapes (GetMinimapShape) are respected.
local _, ns = ...
local Compat, State = ns.Compat, ns.State

ns.UI = ns.UI or {}
local MinimapButton = {}
ns.UI.Minimap = MinimapButton

local ICON = "Interface\\AddOns\\T3Bridge\\Media\\icon"
local RING_OFFSET = 5          -- px outside the minimap edge (LibDBIcon uses the same)
local MIN_GAP = 26             -- degrees between button centres that count as "free"
-- Preferred angles, best first: top-right of the ring, then fanning out. 0 = right, 90 = top.
local PREFERRED = { 40, 30, 50, 20, 60, 10, 70, 0, 80, 350, 135, 145, 125, 155, 340, 330, 165, 110, 100, 320, 310, 300, 290, 280, 270, 260, 180, 250 }

local btn
local dragStoppedAt = 0

-- Which quadrants are round for each minimap shape (1 = bottom-right, 2 = bottom-left,
-- 3 = top-right, 4 = top-left). Same table LibDBIcon uses.
local SHAPES = {
  ["ROUND"] = { true, true, true, true },
  ["SQUARE"] = { false, false, false, false },
  ["CORNER-TOPLEFT"] = { false, false, false, true },
  ["CORNER-TOPRIGHT"] = { false, false, true, false },
  ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
  ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
  ["SIDE-LEFT"] = { false, true, false, true },
  ["SIDE-RIGHT"] = { true, false, true, false },
  ["SIDE-TOP"] = { false, false, true, true },
  ["SIDE-BOTTOM"] = { true, true, false, false },
  ["TRICORNER-TOPLEFT"] = { false, true, true, true },
  ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
  ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
  ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local function minimapShape()
  local fn = _G.GetMinimapShape
  local ok, shape = false, nil
  if fn then ok, shape = pcall(fn) end
  return (ok and SHAPES[shape]) and shape or "ROUND"
end

--- Offset (x, y) from the minimap centre for an angle in degrees.
function MinimapButton.Offset(angle)
  local a = math.rad(angle or 40)
  local x, y = math.cos(a), math.sin(a)
  local q = 1
  if x < 0 then q = q + 1 end
  if y > 0 then q = q + 2 end
  local w = (Minimap:GetWidth() or 140) / 2 + RING_OFFSET
  local h = (Minimap:GetHeight() or 140) / 2 + RING_OFFSET
  if SHAPES[minimapShape()][q] then
    return x * w, y * h
  end
  local dw, dh = math.sqrt(2 * w * w) - 10, math.sqrt(2 * h * h) - 10
  return math.max(-w, math.min(x * dw, w)), math.max(-h, math.min(y * dh, h))
end

local function place()
  if not btn then return end
  local x, y = MinimapButton.Offset(ns.db.minimap.angle)
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function angleDiff(a, b)
  local d = math.abs((a - b) % 360)
  return d > 180 and 360 - d or d
end

--- Angles (degrees) of the other buttons sitting on or near the minimap ring.
function MinimapButton.OccupiedAngles()
  local out = {}
  local mx, my = Minimap:GetCenter()
  if not mx then return out end
  local mes = Minimap:GetEffectiveScale() or 1
  local r = (Minimap:GetWidth() or 140) / 2
  local seen = {}
  local function scan(parent)
    if not parent or not parent.GetChildren then return end
    for _, c in ipairs({ parent:GetChildren() }) do
      if c ~= btn and not seen[c] and c.IsShown and c:IsShown() and c.GetCenter then
        seen[c] = true
        local okT, otype = pcall(c.GetObjectType, c)
        local w = c.GetWidth and c:GetWidth() or 0
        if okT and (otype == "Button" or otype == "Frame" or otype == "CheckButton") and w >= 12 and w <= 60 then
          local cx, cy = c:GetCenter()
          if cx then
            local ces = c:GetEffectiveScale() or mes
            local dx, dy = cx * ces / mes - mx, cy * ces / mes - my
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist >= r * 0.7 and dist <= r * 1.6 then
              out[#out + 1] = math.deg(math.atan2(dy, dx)) % 360
            end
          end
        end
      end
    end
  end
  scan(Minimap)
  scan(_G.MinimapBackdrop)
  scan(_G.MinimapCluster)
  return out
end

--- Pick the first preferred angle clear of the other buttons (or the most open one).
function MinimapButton.FreeAngle(occupied)
  occupied = occupied or MinimapButton.OccupiedAngles()
  local function gap(a)
    local g = 360
    for _, o in ipairs(occupied) do g = math.min(g, angleDiff(a, o)) end
    return g
  end
  for _, a in ipairs(PREFERRED) do
    if gap(a) >= MIN_GAP then return a end
  end
  local best, bestGap = PREFERRED[1], -1
  for a = 0, 355, 5 do
    local g = gap(a)
    if g > bestGap then best, bestGap = a, g end
  end
  return best
end

--- Move to a free spot unless the user has dragged the button somewhere.
function MinimapButton.AutoPlace(force)
  if not btn then return end
  local m = ns.db.minimap
  if m.moved and not force then return end
  local ok, a = pcall(MinimapButton.FreeAngle)
  if ok and a then m.angle = a end
  place()
end

function MinimapButton.Reset()
  ns.db.minimap.moved = false
  ns.db.minimap.hide = false
  MinimapButton.Create()
  MinimapButton.AutoPlace(true)
  MinimapButton.Refresh()
end

local function onDragUpdate(self)
  local mx, my = Minimap:GetCenter()
  if not mx then return end
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  px, py = px / scale, py / scale
  ns.db.minimap.angle = math.deg(math.atan2(py - my, px - mx)) % 360
  place()
end

local function tooltip(self)
  if self.dragging then return end
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("T3 Code")
  GameTooltip:AddLine(State.Summary(ns.state, ns.Now(), ns.UI.Tracker and ns.UI.Tracker.CollapsedMap() or nil), 1, 1, 1)
  local text = ns.LinkStatus()
  GameTooltip:AddLine(text, 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Click: open / close chat", 0.5, 0.8, 1)
  GameTooltip:AddLine("Drag: move around the minimap", 0.5, 0.8, 1)
  GameTooltip:Show()
end

local function baseLevel()
  local ok, l = pcall(Minimap.GetFrameLevel, Minimap)
  return math.max(8, ((ok and l) or 0) + 10)
end

function MinimapButton.Create()
  if btn or not Minimap then return btn end
  btn = CreateFrame("Button", "T3BridgeMinimapButton", Minimap)
  btn:SetSize(31, 31)
  -- Above other minimap buttons so it is never hidden under them and can always be grabbed.
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(baseLevel())
  if btn.SetClampedToScreen then btn:SetClampedToScreen(true) end
  btn:EnableMouse(true)
  btn:SetMovable(true)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  btn:RegisterForDrag("LeftButton", "RightButton")
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local overlay = btn:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")

  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)

  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetSize(20, 20)
  icon:SetTexture(ICON)
  icon:SetPoint("TOPLEFT", 6, -5)
  if btn.CreateMaskTexture then
    local ok, mask = pcall(btn.CreateMaskTexture, btn)
    if ok and mask then
      mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      mask:SetAllPoints(icon)
      icon:AddMaskTexture(mask)
    end
  end
  btn.icon = icon

  local badge = btn:CreateTexture(nil, "OVERLAY", nil, 7)
  badge:SetSize(10, 10)
  badge:SetTexture("Interface\\COMMON\\Indicator-Yellow")
  badge:SetVertexColor(1, 0.55, 0)
  badge:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -3, -3)
  badge:Hide()
  btn.badge = badge

  btn:SetScript("OnClick", function()
    if GetTime() - dragStoppedAt < 0.3 then return end -- the mouse-up that ended a drag
    if ns.UI.ToggleChat then ns.UI.ToggleChat() end
  end)
  btn:SetScript("OnDragStart", function(self)
    self.dragging = true
    GameTooltip:Hide()
    self:LockHighlight()
    self:SetFrameLevel(baseLevel() + 5)
    self:SetScript("OnUpdate", onDragUpdate)
  end)
  btn:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    self.dragging = false
    self:UnlockHighlight()
    self:SetFrameLevel(baseLevel())
    ns.db.minimap.moved = true
    dragStoppedAt = GetTime()
    place()
  end)
  btn:SetScript("OnEnter", tooltip)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  place()
  MinimapButton.Refresh()
  return btn
end

function MinimapButton.Refresh()
  if not btn then return end
  btn:SetShown(not ns.db.minimap.hide)
  btn.badge:SetShown(State.AnyNeedsYou(ns.state))
end

function MinimapButton.SetHidden(hide)
  ns.db.minimap.hide = hide and true or false
  MinimapButton.Create()
  MinimapButton.Refresh()
end

local function registerCompartment()
  local acf = _G.AddonCompartmentFrame
  if not acf or not acf.RegisterAddon then return end
  pcall(acf.RegisterAddon, acf, {
    text = "T3 Code",
    icon = ICON,
    notCheckable = true,
    func = function() if ns.UI.ToggleChat then ns.UI.ToggleChat() end end,
    funcOnEnter = function(button)
      GameTooltip:SetOwner(button, "ANCHOR_LEFT")
      GameTooltip:AddLine("T3 Code")
      GameTooltip:AddLine(State.Summary(ns.state, ns.Now(), ns.UI.Tracker and ns.UI.Tracker.CollapsedMap() or nil), 1, 1, 1)
      GameTooltip:Show()
    end,
    funcOnLeave = function() GameTooltip:Hide() end,
  })
end

ns.On("login", function()
  MinimapButton.Create()
  registerCompartment()
  -- Other addons create their minimap buttons around login too: choose a free spot once they
  -- exist, and check again a little later (Questie and friends can be slow).
  Compat.After(3, function() MinimapButton.AutoPlace() end)
  Compat.After(12, function() MinimapButton.AutoPlace() end)
end)
ns.On("model", function() MinimapButton.Refresh() end)
