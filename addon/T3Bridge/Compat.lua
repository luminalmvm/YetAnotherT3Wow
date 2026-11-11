-- T3Bridge Compat: guarded wrappers for client APIs that differ between WoW flavors.
-- Nothing here assumes Retail-only APIs: every call checks first and has a fallback.
local addonName, ns = ...
ns.name = addonName
ns.version = "0.1.0"

local Compat = {}
ns.Compat = Compat

local _G = _G
local C_AddOns = _G.C_AddOns

---------------------------------------------------------------------------------------------
-- AddOns
---------------------------------------------------------------------------------------------
function Compat.LoadAddOn(name)
  if C_AddOns and C_AddOns.LoadAddOn then return C_AddOns.LoadAddOn(name) end
  return _G.LoadAddOn(name)
end

function Compat.GetNumAddOns()
  if C_AddOns and C_AddOns.GetNumAddOns then return C_AddOns.GetNumAddOns() end
  return _G.GetNumAddOns and _G.GetNumAddOns() or 0
end

--- name, title, notes, loadable, reason
function Compat.GetAddOnInfo(i)
  if C_AddOns and C_AddOns.GetAddOnInfo then return C_AddOns.GetAddOnInfo(i) end
  return _G.GetAddOnInfo(i)
end

function Compat.IsAddOnLoaded(name)
  if C_AddOns and C_AddOns.IsAddOnLoaded then
    local loadedOrLoading, loaded = C_AddOns.IsAddOnLoaded(name)
    return (loaded ~= nil) and loaded or loadedOrLoading
  end
  return _G.IsAddOnLoaded and _G.IsAddOnLoaded(name)
end

function Compat.EnableAddOn(name)
  local who = _G.UnitName and _G.UnitName("player") or nil
  if C_AddOns and C_AddOns.EnableAddOn then return pcall(C_AddOns.EnableAddOn, name, who) end
  if _G.EnableAddOn then return pcall(_G.EnableAddOn, name, who) end
  return false
end

function Compat.GetAddOnMetadata(name, field)
  if C_AddOns and C_AddOns.GetAddOnMetadata then return C_AddOns.GetAddOnMetadata(name, field) end
  return _G.GetAddOnMetadata and _G.GetAddOnMetadata(name, field)
end

--- Call fn with the global error handler temporarily replaced by one that only records.
--- Returns pcallOk, r1, r2, caughtMessages (table).
function Compat.CallSwallowing(fn, ...)
  local caught = {}
  local geh, seh = _G.geterrorhandler, _G.seterrorhandler
  local prev = geh and geh()
  if seh then seh(function(msg) caught[#caught + 1] = tostring(msg); return msg end) end
  local ok, r1, r2 = pcall(fn, ...)
  if seh and prev then seh(prev) end
  if not ok then caught[#caught + 1] = tostring(r1); r1 = nil end
  return ok, r1, r2, caught
end

---------------------------------------------------------------------------------------------
-- Timers
---------------------------------------------------------------------------------------------
function Compat.After(sec, fn)
  if _G.C_Timer and _G.C_Timer.After then return _G.C_Timer.After(sec, fn) end
  -- fallback: OnUpdate countdown
  local f = CreateFrame("Frame")
  local left = sec
  f:SetScript("OnUpdate", function(self, e)
    left = left - e
    if left <= 0 then self:SetScript("OnUpdate", nil); fn() end
  end)
end

function Compat.NewTicker(sec, fn)
  if _G.C_Timer and _G.C_Timer.NewTicker then return _G.C_Timer.NewTicker(sec, fn) end
  local f = CreateFrame("Frame")
  local acc = 0
  f:SetScript("OnUpdate", function(_, e)
    acc = acc + e
    if acc >= sec then acc = 0; fn() end
  end)
  return { Cancel = function() f:SetScript("OnUpdate", nil) end }
end

function Compat.ProfileMs()
  if _G.debugprofilestop then return _G.debugprofilestop() end
  return (_G.GetTime() or 0) * 1000
end

---------------------------------------------------------------------------------------------
-- Templates
---------------------------------------------------------------------------------------------
local TEMPLATE_TYPE = {
  ScrollFrameTemplate = "ScrollFrame", UIPanelScrollFrameTemplate = "ScrollFrame",
  InputScrollFrameTemplate = "ScrollFrame", T3BridgeInputScrollTemplate = "ScrollFrame",
  UIPanelButtonTemplate = "Button", UIPanelCloseButton = "Button",
  WowStyle1DropdownTemplate = "DropdownButton", MinimalScrollBar = "EventFrame",
  WowScrollBox = "Frame", WowScrollBoxList = "Frame",
}
local templateCache = {}
local probeParent

function Compat.TemplateExists(name)
  local cached = templateCache[name]
  if cached ~= nil then return cached end
  local exists
  if _G.C_XMLUtil and _G.C_XMLUtil.GetTemplateInfo then
    local ok, info = pcall(_G.C_XMLUtil.GetTemplateInfo, name)
    exists = ok and info ~= nil
  else
    probeParent = probeParent or CreateFrame("Frame")
    probeParent:Hide()
    local ok = pcall(CreateFrame, TEMPLATE_TYPE[name] or "Frame", nil, probeParent, name)
    exists = ok
  end
  templateCache[name] = exists and true or false
  return templateCache[name]
end

--- First template in the list that exists, or nil.
function Compat.FirstTemplate(list)
  for _, t in ipairs(list) do if Compat.TemplateExists(t) then return t end end
  return nil
end

--- CreateFrame that never raises. Returns frame or nil.
function Compat.TryCreateFrame(ftype, name, parent, template)
  local ok, f = pcall(CreateFrame, ftype, name, parent, template)
  if ok then return f end
  return nil
end

function Compat.BackdropTemplate()
  return _G.BackdropTemplateMixin and "BackdropTemplate" or nil
end

---------------------------------------------------------------------------------------------
-- Screen
---------------------------------------------------------------------------------------------
--- Physical pixel size of the game's render surface. Returns w, h, method.
function Compat.PhysicalScreenSize()
  if _G.GetPhysicalScreenSize then
    local ok, w, h = pcall(_G.GetPhysicalScreenSize)
    if ok and w and h and h > 0 then return w, h, "GetPhysicalScreenSize" end
  end
  if _G.GetCVar then
    for _, cv in ipairs({ "gxWindowedResolution", "gxFullscreenResolution", "gxResolution" }) do
      local ok, v = pcall(_G.GetCVar, cv)
      local w, h = ok and v and v:match("^(%d+)x(%d+)$")
      if w then return tonumber(w), tonumber(h), "CVar " .. cv end
    end
  end
  return 1920, 1080, "assumed"
end

function Compat.SetResizeBounds(frame, minW, minH, maxW, maxH)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(minW, minH, maxW or 2000, maxH or 1600)
  elseif frame.SetMinResize then
    frame:SetMinResize(minW, minH)
    if frame.SetMaxResize then frame:SetMaxResize(maxW or 2000, maxH or 1600) end
  end
end

---------------------------------------------------------------------------------------------
-- Text
---------------------------------------------------------------------------------------------
--- Escape WoW UI codes (|c, |T, |H, ...) in untrusted text so it shows literally.
function Compat.Escape(s)
  if s == nil then return "" end
  return (tostring(s):gsub("|", "||"))
end

--- Mouse motion without eating clicks or wheel, where supported.
function Compat.EnableMotionOnly(frame)
  if frame.SetMouseMotionEnabled then
    frame:SetMouseMotionEnabled(true)
    if frame.SetMouseClickEnabled then frame:SetMouseClickEnabled(false) end
  else
    frame:EnableMouse(true)
  end
end

return Compat
