-- T3Bridge Tracker: compact thread list under Questie's tracker (or Blizzard's, or a saved spot).
-- It never modifies Questie or Blizzard frames: it only anchors to them and hooks Questie's OnShow/OnHide.
--
-- Phase 2: every open (unsettled) T3 thread is listed until it is settled in T3 Code. Rows can be
-- collapsed one by one (the +/- button at a row's left, or right-click) or all at once (the [-]/[+]
-- button in the header, or right-click on the header). Collapsed rows are a compact line sorted after
-- the expanded ones and re-expand by themselves when the thread needs you or fails. When the rows do
-- not fit on screen, a "N more..." line opens the chat window's thread menu, which lists every thread.
--
-- rev 1.4: a row whose thread has subagents shows a badge ("+3", "1 running", "1 needs you"). Clicking the
-- badge lists the subagents as indented rows under it (collapsed by default, remembered per thread; shown
-- by themselves while a subagent needs you; hidden while the row itself is collapsed). Click a subagent
-- row to open it.
local _, ns = ...
local Compat, State = ns.Compat, ns.State

ns.UI = ns.UI or {}
local Tracker = {}
ns.UI.Tracker = Tracker

local HEADER_H, ROW_H, CROW_H, MORE_H, MIN_W = 16, 14, 12, 12, 220
local KID_H, KID_INDENT, MAX_KID_ROWS = 12, 14, 6   -- subagent rows (rev 1.4)
local MAX_ROWS = State.MAX_TRACKER_ROWS
local COLLAPSED_TITLE = 34      -- bytes of title shown on a collapsed row
local frame, header, rows, moreLine = nil, nil, {}, nil
local anchorTarget = nil       -- frame we are anchored under, or false for the saved position
local hooked = {}

local function questieFrame()
  local q = _G.Questie_BaseFrame
  if q and q.IsShown and q:IsShown() then return q end
  return nil
end

local function blizzardTracker()
  for _, n in ipairs({ "ObjectiveTrackerFrame", "QuestWatchFrame" }) do
    local f = _G[n]
    if f and f.IsShown and f:IsShown() and f.GetBottom and f:GetBottom() then return f end
  end
  return nil
end

local function trackerMode()
  local m = ns.db and ns.db.tracker.mode
  if m == "below" or m == "above" or m == "free" then return m end
  return "auto"
end

local function desiredAnchor()
  if trackerMode() == "free" then return false end
  return questieFrame() or blizzardTracker() or false
end

--- Subagent lists the user opened (rev 1.4): kidsOpen[tid] = true. Thread ids only, no titles.
local function kidsOpenMap()
  if not ns.db then return {} end
  if type(ns.db.tracker.kids) ~= "table" then ns.db.tracker.kids = {} end
  return ns.db.tracker.kids
end
Tracker.KidsOpenMap = kidsOpenMap

--- Are thread t's subagent rows shown? Open when the user opened them or a subagent needs you.
function Tracker.KidsShown(t)
  if not t or (t.kids or 0) == 0 then return false end
  if (t.kidsNeed or 0) > 0 then return true end
  return kidsOpenMap()[t.id] == true
end

function Tracker.ToggleKids(tid)
  local map = kidsOpenMap()
  map[tid] = (map[tid] ~= true) and true or nil
  Tracker.Refresh()
end

--- Badge for a row with subagents: text, colour. "1 needs you" > "2 running" > "+3".
function Tracker.KidsBadge(t)
  local n = t and t.kids or 0
  if n == 0 then return nil end
  if (t.kidsNeed or 0) > 0 then return t.kidsNeed .. " needs you", State.STATUS.input.color end
  if (t.kidsRunning or 0) > 0 then return t.kidsRunning .. " running", State.STATUS.running.timer end
  return "+" .. n, { 0.62, 0.62, 0.62 }
end

local function collapsedMap()
  if not ns.db then return {} end
  if type(ns.db.tracker.rows) ~= "table" then ns.db.tracker.rows = {} end
  return ns.db.tracker.rows
end
Tracker.CollapsedMap = collapsedMap

-- Vertical extent of a frame in UIParent units.
local function uiY(f, v) return v and (v * f:GetEffectiveScale() / UIParent:GetEffectiveScale()) or nil end
local function rowsHeight(n) return HEADER_H + 3 + n * ROW_H + 2 end
local MARGIN = 10

local function spaceBelow(target)
  local b = uiY(target, target:GetBottom())
  return b and (b - MARGIN) or 0
end
--- Room above the quest tracker, stopping at the minimap when it sits above it (the usual
--- top-right layout: Questie hangs right under the minimap, so "above" would cover the map).
local function spaceAbove(target)
  local t = uiY(target, target:GetTop())
  if not t then return 0 end
  local ceiling = UIParent:GetHeight()
  local mm = _G.Minimap
  if mm and mm.IsVisible and mm:IsVisible() and mm.GetBottom then
    local mb = uiY(mm, mm:GetBottom())
    local ml, mr = uiY(mm, mm:GetLeft()), uiY(mm, mm:GetRight())
    local tl, tr = uiY(target, target:GetLeft()), uiY(target, target:GetRight())
    local overlapX = ml and mr and tl and tr and ml < tr and mr > tl
    if mb and mb >= t and overlapX then ceiling = math.min(ceiling, mb) end
  end
  return ceiling - t - MARGIN
end

--- Where to put the tracker relative to the quest tracker:
---   "below" (default), "above" (when there is no room for 3 rows below, e.g. Questie at the bottom
---   of the screen), or "side" (left of the quest tracker's top, when it fills the whole height).
local function chooseKind(target)
  local mode = trackerMode()
  if mode == "below" then return "below" end
  if mode == "above" then return "above" end
  local need = rowsHeight(3)
  if spaceBelow(target) >= need then return "below" end
  if spaceAbove(target) >= need then return "above" end
  return "side"
end

local anchorKind = nil

local function applyAnchor(force)
  if not frame then return end
  local target = desiredAnchor()
  local kind = target and chooseKind(target) or "free"
  if not force and target == anchorTarget and kind == anchorKind then return end
  anchorTarget, anchorKind = target, kind
  frame:ClearAllPoints()
  if target and kind == "side" then
    frame:SetPoint("TOPRIGHT", target, "TOPLEFT", -8, 0)
    frame:SetWidth(MIN_W)
  elseif target then
    local w = target:GetWidth() or 0
    local p1, p2, r1, r2, dy = "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT", -4
    if kind == "above" then p1, p2, r1, r2, dy = "BOTTOMLEFT", "BOTTOMRIGHT", "TOPLEFT", "TOPRIGHT", 4 end
    if w >= MIN_W then
      frame:SetPoint(p1, target, r1, 0, dy)
      frame:SetPoint(p2, target, r2, 0, dy)
    else
      frame:SetPoint(p2, target, r2, 0, dy)
      frame:SetWidth(MIN_W)
    end
  else
    local p = ns.db.tracker.point
    if p then
      frame:SetPoint(p[1], UIParent, p[3], p[4], p[5])
    else
      frame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -90, -260)
    end
    frame:SetWidth(MIN_W + 20)
  end
  Tracker.Refresh()
end

local function hookQuestie()
  local q = _G.Questie_BaseFrame
  if q and not hooked[q] then
    hooked[q] = true
    q:HookScript("OnShow", function() applyAnchor() end)
    q:HookScript("OnHide", function() applyAnchor() end)
    q:HookScript("OnSizeChanged", function() applyAnchor(true) end)
  end
  return q ~= nil
end

---------------------------------------------------------------------------------------------
-- Collapse
---------------------------------------------------------------------------------------------
--- Collapse or expand one thread's row (nil = toggle).
function Tracker.SetRowCollapsed(tid, on)
  local t = State.Thread(ns.state, tid)
  if not t then return end
  local map = collapsedMap()
  if on == nil then on = not State.IsCollapsed(map, tid) end
  State.SetCollapsed(map, t, on)
  Tracker.Refresh()
end

--- Header control: collapse every listed row, or expand them all when all are collapsed.
function Tracker.ToggleAll()
  local map = collapsedMap()
  local threads = ns.state.snap and ns.state.snap.threads or {}
  local anyExpanded = false
  for _, t in ipairs(threads) do if not State.IsCollapsed(map, t.id) then anyExpanded = true break end end
  for _, t in ipairs(threads) do State.SetCollapsed(map, t, anyExpanded) end
  Tracker.Refresh()
end

---------------------------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------------------------
local function rowOnEnter(self)
  local t = self.thread
  if not t then return end
  if self.child then
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(Compat.Escape(t.title), 1, 1, 1, true)
    local info = State.STATUS[State.StatusKey(t)]
    GameTooltip:AddDoubleLine("Subagent", info.label, 0.7, 0.7, 0.7, info.color[1], info.color[2], info.color[3])
    local e = State.Elapsed(t, ns.Now())
    if e then GameTooltip:AddDoubleLine(t.t1 and "Took" or "Elapsed", State.FormatElapsed(e), 0.7, 0.7, 0.7, 1, 0.82, 0) end
    GameTooltip:AddLine("Click: open this subagent", 0.5, 0.8, 1)
    GameTooltip:Show()
    return
  end
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine(Compat.Escape(t.title), 1, 1, 1, true)
  local info = State.STATUS[State.StatusKey(t)]
  GameTooltip:AddDoubleLine("Status", info.label, 0.7, 0.7, 0.7, info.color[1], info.color[2], info.color[3])
  if t.proj then GameTooltip:AddDoubleLine("Project", Compat.Escape(t.proj), 0.7, 0.7, 0.7, 1, 1, 1) end
  if t.model then GameTooltip:AddDoubleLine("Model", Compat.Escape(t.model), 0.7, 0.7, 0.7, 1, 1, 1) end
  local e = State.Elapsed(t, ns.Now())
  if e then GameTooltip:AddDoubleLine(t.t1 and "Took" or "Elapsed", State.FormatElapsed(e), 0.7, 0.7, 0.7, 1, 0.82, 0) end
  if (t.kids or 0) > 0 then
    GameTooltip:AddDoubleLine("Subagents", State.KidsLabel(t.kids, t.kidsRunning, t.kidsNeed):match("%((.*)%)") or tostring(t.kids), 0.7, 0.7, 0.7, 1, 1, 1)
  end
  GameTooltip:AddLine("Click: open the chat", 0.5, 0.8, 1)
  GameTooltip:AddLine(self.collapsed and "Right-click: expand this row" or "Right-click: collapse this row", 0.5, 0.8, 1)
  GameTooltip:Show()
end

local function rowOnClick(self, button)
  if not self.thread then return end
  if self.child then
    if self.more then ns.UI.OpenChat(self.thread.parent) else ns.UI.OpenChat(self.thread.id) end
    return
  end
  if button == "RightButton" then
    Tracker.SetRowCollapsed(self.thread.id)
  else
    ns.UI.OpenChat(self.thread.id)
  end
end

local function makeRow(i)
  local b = CreateFrame("Button", nil, frame)
  b:SetHeight(ROW_H)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.toggle = CreateFrame("Button", nil, b)
  b.toggle:SetSize(10, 10)
  b.toggle:SetPoint("LEFT", b, "LEFT", 1, 0)
  b.toggle:SetScript("OnClick", function() if b.thread then Tracker.SetRowCollapsed(b.thread.id) end end)
  b.toggle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(b.collapsed and "Expand this row" or "Collapse this row")
    GameTooltip:Show()
  end)
  b.toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(12, 12)
  b.icon:SetPoint("LEFT", b.toggle, "RIGHT", 2, 0)
  b.timer = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.timer:SetPoint("RIGHT", b, "RIGHT", -2, 0)
  b.timer:SetJustifyH("RIGHT")
  -- rev 1.4: subagent badge ("+3" / "1 running" / "1 needs you"); click lists the subagents.
  b.kidsBtn = CreateFrame("Button", nil, b)
  b.kidsBtn:SetHeight(ROW_H)
  b.kidsBtn:SetPoint("RIGHT", b.timer, "LEFT", -4, 0)
  b.kidsBtn.text = b.kidsBtn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.kidsBtn.text:SetPoint("RIGHT", 0, 0)
  b.kidsBtn:SetScript("OnClick", function() if b.thread then Tracker.ToggleKids(b.thread.id) end end)
  b.kidsBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    local t = b.thread
    GameTooltip:SetText(t and State.KidsLabel(t.kids or 0, t.kidsRunning, t.kidsNeed) or "Subagents")
    GameTooltip:AddLine(b.kidsOpen and "Click: hide the subagents" or "Click: list the subagents here", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  b.kidsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b.kidsBtn:Hide()
  b.title = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.title:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
  b.title:SetPoint("RIGHT", b.timer, "LEFT", -6, 0)
  b.title:SetJustifyH("LEFT")
  b.title:SetWordWrap(false)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  hl:SetBlendMode("ADD")
  hl:SetAllPoints(b)
  hl:SetAlpha(0.5)
  -- pulse for "needs you"
  local ag = b:CreateAnimationGroup()
  local a = ag:CreateAnimation("Alpha")
  a:SetFromAlpha(1)
  a:SetToAlpha(0.35)
  a:SetDuration(0.7)
  a:SetSmoothing("IN_OUT")
  ag:SetLooping("BOUNCE")
  b.pulse = ag
  b:SetScript("OnEnter", rowOnEnter)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", rowOnClick)
  rows[i] = b
  return b
end

local function makeMoreLine()
  local b = CreateFrame("Button", nil, frame)
  b:SetHeight(MORE_H)
  b:RegisterForClicks("LeftButtonUp")
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  b.text:SetPoint("LEFT", b, "LEFT", 14, 0)
  b.text:SetJustifyH("LEFT")
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
  hl:SetBlendMode("ADD")
  hl:SetAllPoints(b)
  hl:SetAlpha(0.35)
  b:SetScript("OnClick", function() Tracker.OpenAllThreads() end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Show every thread in the T3 Code window")
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  moreLine = b
  return b
end

--- "N more..." line: open the chat window with its thread menu (which lists every thread).
function Tracker.OpenAllThreads()
  ns.UI.OpenChat(nil)
  if ns.UI.Chat and ns.UI.Chat.OpenThreadMenu then ns.UI.Chat.OpenThreadMenu() end
end

--- Vertical space for rows (UI units) where the tracker is anchored (never runs off the bottom/top).
local function rowSpace()
  local avail
  if anchorTarget and anchorKind == "above" then
    avail = spaceAbove(anchorTarget) - 4 - (HEADER_H + 5)
  elseif anchorTarget and anchorKind == "below" then
    avail = spaceBelow(anchorTarget) - 4 - (HEADER_H + 5)
  else
    local top = uiY(frame, frame:GetTop())
    if not top then return MAX_ROWS * ROW_H end
    avail = top - MARGIN - (HEADER_H + 5)
  end
  return math.max(ROW_H, avail)
end

--- Expanded rows that fit (at least 1, at most MAX_ROWS).
local function maxRowsOnScreen()
  return math.max(1, math.min(MAX_ROWS, math.floor(rowSpace() / ROW_H)))
end
Tracker.MaxRows = function() return frame and maxRowsOnScreen() or MAX_ROWS end
Tracker.AnchorKind = function() return anchorKind, anchorTarget end

--- How many of `list` fit in `space` (rows have different heights); leaves room for the
--- "N more..." line when some do not fit. Returns count, usedHeight.
function Tracker.Fit(list, space, maxRows)
  local function h(r) return r.child and KID_H or (r.collapsed and CROW_H or ROW_H) end
  local total = 0
  for k = 1, #list do total = total + h(list[k]) end
  if #list <= maxRows and total <= space then return #list, total end
  local used, n = 0, 0
  for k = 1, math.min(#list, maxRows) do
    if used + h(list[k]) + MORE_H > space then break end
    used = used + h(list[k])
    n = k
  end
  if n == 0 and #list > 0 then n, used = 1, h(list[1]) end -- always show at least one row
  return n, used
end

---------------------------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------------------------
local function linkDot()
  local _, kind = ns.LinkStatus()
  if kind == "ok" then return "Interface\\COMMON\\Indicator-Green" end
  if kind == "warn" or kind == "info" then return "Interface\\COMMON\\Indicator-Yellow" end
  return "Interface\\COMMON\\Indicator-Red"
end

local function shortTitle(s)
  if #s <= COLLAPSED_TITLE then return s end
  return ns.Codec.Utf8Truncate(s, COLLAPSED_TITLE - 3) .. "..."
end

local function hideRow(b)
  b:Hide()
  b.thread, b.child, b.more = nil, nil, nil
  if b.pulse:IsPlaying() then b.pulse:Stop() end
end

--- The tracker list with subagent rows (rev 1.4) inserted after each parent whose list is shown:
--- { child = true, t = subagent, key, info, elapsed } and, when the parent has more subagents than
--- rows, { child = true, more = n, t = { parent = tid } }.
function Tracker.WithKids(list, now)
  local out = {}
  for _, r in ipairs(list) do
    out[#out + 1] = r
    if not r.collapsed and Tracker.KidsShown(r.t) then
      local kids, total = State.Kids(ns.state, r.t.id)
      local n = math.min(#kids, MAX_KID_ROWS)
      for k = 1, n do
        local t = kids[k]
        local key = State.StatusKey(t)
        local e = State.Elapsed(t, now)
        out[#out + 1] = { child = true, t = t, key = key, info = State.STATUS[key], elapsed = e and State.FormatElapsed(e) or "" }
      end
      if total > n then
        out[#out + 1] = { child = true, more = total - n, t = { id = r.t.id .. ":more", parent = r.t.id, title = "", st = "idle" },
          key = "idle", info = State.STATUS.idle, elapsed = "" }
      end
    end
  end
  return out
end

function Tracker.Refresh()
  if not frame then return end
  if ns.db.tracker.hide then frame:Hide(); return end
  local st = ns.state
  local now = ns.Now()
  local map = collapsedMap()
  State.ApplyAutoExpand(map, st)
  State.PruneCollapsed(map, st)
  local top, total, ncollapsed = State.TrackerRows(st, now, nil, map)
  local list = Tracker.WithKids(top, now)
  frame:Show()
  local summary
  if not st.snap and not ns.demo then summary = "waiting for the companion" else summary = State.Summary(st, now, map) end
  header.summary:SetText(summary)
  header.dot:SetTexture(linkDot())
  local collapsed = ns.db.tracker.collapsed
  header.arrow:SetTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
  header.all:SetShown(total > 0 and not collapsed)
  header.all.text:SetText((total > 0 and ncollapsed == total) and "[+]" or "[-]")
  header.all.expandAll = (total > 0 and ncollapsed == total)
  local offline = State.IsOffline(st, now) and not ns.demo

  local shown, used = 0, 0
  if not collapsed then shown, used = Tracker.Fit(list, rowSpace(), MAX_ROWS) end
  local y = HEADER_H + 3
  local shownTop = 0
  for i = 1, shown do
    local r = list[i]
    local b = rows[i] or makeRow(i)
    if not r.child then shownTop = shownTop + 1 end
    if r.child then
      -- subagent row (rev 1.4): indented, small, no collapse toggle
      b.thread, b.collapsed, b.child, b.more = r.t, false, true, r.more
      b:ClearAllPoints()
      b:SetHeight(KID_H)
      b:SetPoint("TOPLEFT", frame, "TOPLEFT", KID_INDENT, -y)
      b:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -y)
      y = y + KID_H
      b.toggle:Hide()
      b.kidsBtn:Hide()
      b.icon:SetSize(10, 10)
      b.title:SetFontObject(GameFontHighlightSmall)
      if r.more then
        b.icon:Hide()
        b.title:SetText(r.more .. " more...")
        b.title:SetTextColor(0.6, 0.6, 0.6)
        b.timer:SetText("")
      else
        b.icon:SetTexture(r.info.icon)
        b.icon:Show()
        b.title:SetText(Compat.Escape(r.t.title))
        b.title:SetTextColor(r.info.color[1] * 0.9, r.info.color[2] * 0.9, r.info.color[3] * 0.9)
        b.timer:SetText(r.elapsed)
        b.timer:SetTextColor(r.info.timer[1], r.info.timer[2], r.info.timer[3])
      end
      b.title:ClearAllPoints()
      b.title:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
      b.title:SetPoint("RIGHT", b.timer, "LEFT", -6, 0)
      b:SetAlpha(offline and 0.55 or 1)
      if r.info.pulse and not offline and not r.more then
        if not b.pulse:IsPlaying() then b.pulse:Play() end
      elseif b.pulse:IsPlaying() then b.pulse:Stop() end
      b:Show()
    else
    local c = r.collapsed
    local attention = r.info.group == "needs" or r.key == "failed"
    b.thread, b.collapsed = r.t, c
    b:ClearAllPoints()
    b:SetHeight(c and CROW_H or ROW_H)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -y)
    b:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -y)
    y = y + (c and CROW_H or ROW_H)
    b.toggle:SetNormalTexture(c and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    b.icon:SetTexture(r.info.icon)
    b.icon:SetSize(c and 9 or 12, c and 9 or 12)
    b.title:SetFontObject(c and GameFontDisableSmall or GameFontHighlightSmall)
    b.title:SetText(Compat.Escape(c and shortTitle(r.t.title) or r.t.title))
    if c then
      b.title:SetTextColor(r.info.color[1] * 0.75, r.info.color[2] * 0.75, r.info.color[3] * 0.75)
    else
      b.title:SetTextColor(r.info.color[1], r.info.color[2], r.info.color[3])
    end
    -- collapsed rows show no timer unless the thread needs attention
    b.timer:SetText((c and not attention) and "" or r.elapsed)
    b.timer:SetTextColor(r.info.timer[1], r.info.timer[2], r.info.timer[3])
    b.child, b.more = nil, nil
    b.toggle:Show()
    b.icon:Show()
    -- subagent badge (rev 1.4)
    local badge, bc = Tracker.KidsBadge(r.t)
    b.title:ClearAllPoints()
    b.title:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
    if badge and not c then
      b.kidsOpen = Tracker.KidsShown(r.t)
      b.kidsBtn.text:SetText((b.kidsOpen and "- " or "") .. badge)
      b.kidsBtn.text:SetTextColor(bc[1], bc[2], bc[3])
      b.kidsBtn:SetWidth(math.max(14, math.ceil(b.kidsBtn.text:GetStringWidth() or 20) + 2))
      b.kidsBtn:Show()
      b.title:SetPoint("RIGHT", b.kidsBtn, "LEFT", -4, 0)
    else
      b.kidsBtn:Hide()
      b.title:SetPoint("RIGHT", b.timer, "LEFT", -6, 0)
    end
    b:SetAlpha(offline and 0.55 or 1)
    if r.info.pulse and not offline then
      if not b.pulse:IsPlaying() then b.pulse:Play() end
    elseif b.pulse:IsPlaying() then
      b.pulse:Stop()
    end
    b:Show()
    end
  end
  for i = shown + 1, #rows do hideRow(rows[i]) end

  local more = collapsed and 0 or (total - shownTop)
  if more > 0 then
    local m = moreLine or makeMoreLine()
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -y)
    m:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -y)
    m.text:SetText(more .. " more...")
    m:Show()
    y = y + MORE_H
  elseif moreLine then
    moreLine:Hide()
  end
  Tracker.shown, Tracker.more = shown, more
  frame:SetHeight(y + 2)
end

--- Cheap per-second update: only the timers.
function Tracker.Tick()
  if not frame or not frame:IsShown() then return end
  local now = ns.Now()
  for _, b in ipairs(rows) do
    if b:IsShown() and b.thread and not b.more then
      local t = b.thread
      local attention = t.need or t.st == "failed"
      if b.collapsed and not attention then
        b.timer:SetText("")
      else
        local e = State.Elapsed(t, now)
        b.timer:SetText(e and State.FormatElapsed(e) or "")
      end
    end
  end
  header.dot:SetTexture(linkDot())
end

---------------------------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------------------------
function Tracker.Create()
  if frame then return frame end
  frame = CreateFrame("Frame", "T3BridgeTracker", UIParent)
  frame:SetFrameStrata("MEDIUM")
  frame:SetSize(MIN_W, HEADER_H)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)

  header = CreateFrame("Button", nil, frame)
  header:SetHeight(HEADER_H)
  header:SetPoint("TOPLEFT")
  header:SetPoint("TOPRIGHT")
  header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  header.arrow = header:CreateTexture(nil, "ARTWORK")
  header.arrow:SetSize(12, 12)
  header.arrow:SetPoint("LEFT", 2, 0)
  header.title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  header.title:SetPoint("LEFT", header.arrow, "RIGHT", 4, 0)
  header.title:SetText("T3 Code")
  header.dot = header:CreateTexture(nil, "ARTWORK")
  header.dot:SetSize(10, 10)
  header.dot:SetPoint("RIGHT", -2, 0)
  -- collapse / expand every row
  header.all = CreateFrame("Button", nil, header)
  header.all:SetSize(18, HEADER_H)
  header.all:SetPoint("RIGHT", header.dot, "LEFT", -3, 0)
  header.all.text = header.all:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  header.all.text:SetPoint("CENTER", 0, 0)
  header.all.text:SetText("[-]")
  header.all:SetScript("OnClick", function() Tracker.ToggleAll() end)
  header.all:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(self.expandAll and "Expand all rows" or "Collapse all rows")
    GameTooltip:Show()
  end)
  header.all:SetScript("OnLeave", function() GameTooltip:Hide() end)
  header.summary = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  header.summary:SetPoint("LEFT", header.title, "RIGHT", 8, 0)
  header.summary:SetPoint("RIGHT", header.all, "LEFT", -2, 0)
  header.summary:SetJustifyH("RIGHT")
  header.summary:SetWordWrap(false)
  header.summary:SetTextColor(0.8, 0.8, 0.8)
  local divider = header:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(1, 0.82, 0, 0.6)
  divider:SetHeight(1)
  divider:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -1)
  divider:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -1)

  header:SetScript("OnClick", function(_, button)
    if IsShiftKeyDown() then return end
    if button == "RightButton" then Tracker.ToggleAll() return end
    ns.db.tracker.collapsed = not ns.db.tracker.collapsed
    Tracker.Refresh()
  end)
  -- Shift-drag moves the tracker, only when it is not anchored to another tracker.
  header:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" and IsShiftKeyDown() and not anchorTarget then
      frame:StartMoving()
      frame.moving = true
    end
  end)
  header:SetScript("OnMouseUp", function()
    if frame.moving then
      frame:StopMovingOrSizing()
      frame.moving = false
      local p, _, rp, x, y = frame:GetPoint(1)
      ns.db.tracker.point = { p, "UIParent", rp, x, y }
    end
  end)
  header:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("T3 Code")
    local text = ns.LinkStatus()
    GameTooltip:AddLine(text, 1, 1, 1)
    GameTooltip:AddLine("Click: hide / show the list", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Right-click: collapse / expand all rows", 0.7, 0.7, 0.7)
    if not anchorTarget then GameTooltip:AddLine("Shift-drag: move", 0.7, 0.7, 0.7) end
    GameTooltip:Show()
  end)
  header:SetScript("OnLeave", function() GameTooltip:Hide() end)

  applyAnchor(true)
  return frame
end

ns.On("login", function()
  Tracker.Create()
end)

-- Questie creates its base frame late: look for it every second for 30 s after entering the world.
ns.On("world", function()
  if Tracker.polling then return end
  Tracker.polling = true
  local tries = 0
  local ticker
  ticker = Compat.NewTicker(1, function()
    tries = tries + 1
    if hookQuestie() or tries >= 30 then
      if ticker and ticker.Cancel then ticker:Cancel() end
    end
    applyAnchor()
  end)
end)

ns.On("model", function() Tracker.Refresh() end)
ns.On("link", function() if frame and frame:IsShown() then header.dot:SetTexture(linkDot()) end end)

-- One shared 1 s ticker: tracker timers + anchor check (other modules hook "tick").
ns.On("login", function()
  Compat.NewTicker(1, function()
    if frame then
      applyAnchor()
      Tracker.Tick()
    end
    ns.Fire("tick")
  end)
end)

function Tracker.ResetPosition()
  ns.db.tracker.point = nil
  ns.db.tracker.mode = "auto"
  if frame then applyAnchor(true) end
end

--- /t3 tracker auto|below|above|free
function Tracker.SetMode(mode)
  ns.db.tracker.mode = mode
  if frame then applyAnchor(true) end
end
