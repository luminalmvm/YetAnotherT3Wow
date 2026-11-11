-- T3Bridge Messages: scrolling chat history with pooled rows, word-wrapped text, code blocks,
-- light markdown styling (PROTOCOL D14), inline images (rev 1.3, D16), thread links (rev 1.4), per-message Copy,
-- "Earlier messages", a sticky header for the message at the top edge, and a "jump to latest" button.
local _, ns = ...
local Compat, Codec = ns.Compat, ns.Codec

ns.UI = ns.UI or {}
local Messages = {}
ns.UI.Messages = Messages

local CHUNK = 2000         -- max characters per FontString
local PAD_X = 6
local HEADER_H = 16
local IMG_MAX_W, IMG_MAX_H = 240, 160   -- inline image size limit (keeps the aspect ratio)
local PLACEHOLDER_H = 26
Messages.IMG_MAX_W, Messages.IMG_MAX_H = IMG_MAX_W, IMG_MAX_H

--- Texture path of image slot n (installer: T3Bridge_Img\i0001.tga ...; no extension, like the icon).
function Messages.SlotTexture(n) return string.format("Interface\\AddOns\\T3Bridge_Img\\i%04d", n) end

local ROLE = {
  u = { label = "You", color = { 1, 0.82, 0 }, body = { 1, 1, 1 } },
  a = { label = "|cff69ccf0Assistant|r", color = { 0.41, 0.8, 0.94 }, body = { 1, 1, 1 } },
  t = { label = "Tool", color = { 0.62, 0.62, 0.62 }, body = { 0.72, 0.72, 0.72 } },
  s = { label = "System", color = { 0.62, 0.62, 0.62 }, body = { 0.72, 0.72, 0.72 } },
}

--- Split text into pieces of <= CHUNK bytes, preferring newlines, then spaces.
function Messages.Chunk(text)
  local out = {}
  local pos, n = 1, #text
  while pos <= n do
    if n - pos + 1 <= CHUNK then out[#out + 1] = text:sub(pos); break end
    local window = text:sub(pos, pos + CHUNK - 1)
    local cut = nil
    for k = #window, math.floor(CHUNK / 2), -1 do
      if window:byte(k) == 10 then cut = k; break end
    end
    if not cut then
      for k = #window, math.floor(CHUNK / 2), -1 do
        if window:byte(k) == 32 then cut = k; break end
      end
    end
    if not cut then cut = #(Codec.Utf8Truncate(window, CHUNK)) end
    if cut < 1 then cut = CHUNK end
    out[#out + 1] = text:sub(pos, pos + cut - 1)
    pos = pos + cut
  end
  return out
end

---------------------------------------------------------------------------------------------
-- Light markdown (user and assistant text only; PROTOCOL D14). The companion keeps `**bold**`,
-- inline `code`, "# heading" lines and "- " / "1. " list items in "p" segments. Everything is
-- escaped first (Compat.Escape doubles every "|"), so only the colour codes added here are live.
---------------------------------------------------------------------------------------------
local BOLD = "|cffffd866"      -- gold-ish highlight
local CODE = "|cffaad4ff"      -- pale blue
local HEADING_COLOR = { 1, 0.82, 0 }
local BULLET = "\194\183"      -- U+00B7 middle dot (Latin-1; the status bar already shows it)
local INDENT = 12               -- px per nesting level

local function boldify(escaped)
  return (escaped:gsub("%*%*([^*\n]-[^%s*])%*%*", function(inner)
    if inner:find("^%S") then return BOLD .. inner .. "|r" end
    return nil
  end))
end

--- Inline styling of raw (unescaped) text: `code` spans pale blue, **bold** gold-ish. Unmatched
--- markers stay literal. Returns text safe for FontString:SetText.
function Messages.StyleInline(s)
  local out, pos = {}, 1
  while true do
    local a, b = s:find("`[^`\n]+`", pos)
    if not a then break end
    out[#out + 1] = boldify(Compat.Escape(s:sub(pos, a - 1)))
    out[#out + 1] = CODE .. Compat.Escape(s:sub(a + 1, b - 1)) .. "|r"
    pos = b + 1
  end
  out[#out + 1] = boldify(Compat.Escape(s:sub(pos)))
  return table.concat(out)
end

--- Split a paragraph segment into blocks: { kind = "text"|"head"|"item", text, indent, bullet }.
--- An item continues on following lines indented by 2+ spaces; a blank line ends it.
function Messages.Blocks(text)
  local blocks, cur = {}, nil
  local function push(b) blocks[#blocks + 1] = b; cur = b end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local head = line:match("^#%s+(.+)$")
    local ind, rest = line:match("^(%s*)[-*+]%s+(.+)$")
    local nind, num, nrest = line:match("^(%s*)(%d+[.)])%s+(.+)$")
    if head then
      push({ kind = "head", text = head })
      cur = nil
    elseif rest then
      push({ kind = "item", text = rest, indent = math.min(3, math.floor(#ind / 2)), bullet = BULLET })
    elseif nrest then
      push({ kind = "item", text = nrest, indent = math.min(3, math.floor(#nind / 2)), bullet = num })
    elseif cur and cur.kind == "item" and line:find("^%s%s+%S") then
      cur.text = cur.text .. " " .. line:gsub("^%s+", "")
    elseif cur and cur.kind == "text" then
      cur.text = cur.text .. "\n" .. line
    else
      push({ kind = "text", text = line })
    end
  end
  -- drop blank text blocks and trailing newlines
  local out = {}
  for _, b in ipairs(blocks) do
    if b.kind ~= "text" then
      out[#out + 1] = b
    else
      b.text = b.text:gsub("^\n+", ""):gsub("\n+$", "")
      if b.text:find("%S") then out[#out + 1] = b end
    end
  end
  return out
end

local function monoFont(size)
  if ns.monoFontOk then return ns.MONO_FONT, size end
  local path = ChatFontNormal:GetFont()
  return path, size
end

---------------------------------------------------------------------------------------------
-- View
---------------------------------------------------------------------------------------------
local View = {}
View.__index = View

function Messages.Create(parent)
  local v = setmetatable({ rows = {}, texts = {}, codes = {}, usedTexts = 0, usedCodes = 0 }, View)
  local tmpl = Compat.FirstTemplate({ "ScrollFrameTemplate", "UIPanelScrollFrameTemplate" })
  v.scroll = CreateFrame("ScrollFrame", nil, parent, tmpl)
  v.scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4)
  v.scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -24, 4)
  v.child = CreateFrame("Frame", nil, v.scroll)
  v.child:SetSize(300, 10)
  v.scroll:SetScrollChild(v.child)
  if not tmpl then
    v.scroll:EnableMouseWheel(true)
    v.scroll:SetScript("OnMouseWheel", function(self, d)
      local cur, max = self:GetVerticalScroll(), self:GetVerticalScrollRange()
      self:SetVerticalScroll(math.max(0, math.min(max, cur - d * 40)))
    end)
  end
  v.scroll:HookScript("OnVerticalScroll", function() v:UpdateJump(); v:UpdateSticky(); v:UpdateImages() end)
  v.scroll:HookScript("OnSizeChanged", function()
    if v.relayoutPending then return end
    v.relayoutPending = true
    Compat.After(0.05, function()
      v.relayoutPending = false
      local bottom = v:IsAtBottom()
      v:Relayout()
      if bottom then v:ScrollToBottom() end
    end)
  end)

  v.earlier = CreateFrame("Button", nil, v.child, "UIPanelButtonTemplate")
  v.earlier:SetSize(150, 20)
  v.earlier:SetText("Earlier messages")
  v.earlier:Hide()
  v.earlier:SetScript("OnClick", function()
    if v.opts and v.opts.onEarlier then
      v.earlier:Disable()
      v.earlier:SetText("Loading...")
      v.opts.onEarlier()
    end
  end)

  -- Sticky header: when the top message's header has scrolled out of view (a long message with
  -- the view stuck to the bottom), its role/time are shown on a strip at the top edge instead of
  -- a half-clipped header line.
  v.sticky = CreateFrame("Frame", nil, parent)
  v.sticky:SetPoint("TOPLEFT", v.scroll, "TOPLEFT", 0, 0)
  v.sticky:SetPoint("TOPRIGHT", v.scroll, "TOPRIGHT", 0, 0)
  v.sticky:SetHeight(HEADER_H + 2)
  v.sticky:SetFrameLevel(v.scroll:GetFrameLevel() + 8)
  v.sticky.bg = v.sticky:CreateTexture(nil, "BACKGROUND")
  v.sticky.bg:SetColorTexture(0.06, 0.05, 0.04, 0.92)
  v.sticky.bg:SetAllPoints(v.sticky)
  v.sticky.line = v.sticky:CreateTexture(nil, "BORDER")
  v.sticky.line:SetColorTexture(1, 0.82, 0, 0.25)
  v.sticky.line:SetHeight(1)
  v.sticky.line:SetPoint("BOTTOMLEFT")
  v.sticky.line:SetPoint("BOTTOMRIGHT")
  v.sticky.role = v.sticky:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  v.sticky.role:SetPoint("LEFT", PAD_X, 0)
  v.sticky.time = v.sticky:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  v.sticky.time:SetPoint("LEFT", v.sticky.role, "RIGHT", 6, 0)
  v.sticky.more = v.sticky:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  v.sticky.more:SetPoint("LEFT", v.sticky.time, "RIGHT", 6, 0)
  v.sticky.more:SetText("(continued)")
  v.sticky:Hide()
  v.rowTops = {}

  v.empty = v.scroll:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
  v.empty:SetPoint("CENTER", v.scroll, "CENTER", 0, 0)
  v.empty:SetWidth(300)

  v.jump = CreateFrame("Button", nil, parent)
  v.jump:SetSize(28, 28)
  v.jump:SetPoint("BOTTOMRIGHT", v.scroll, "BOTTOMRIGHT", -4, 4)
  v.jump:SetFrameLevel(v.scroll:GetFrameLevel() + 10)
  v.jump:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollEnd-Up")
  v.jump:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollEnd-Down")
  v.jump:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  v.jump:Hide()
  v.jump:SetScript("OnClick", function() v:ScrollToBottom() end)
  v.jump:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Jump to latest")
    GameTooltip:Show()
  end)
  v.jump:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return v
end

function View:Width()
  local w = self.scroll:GetWidth()
  if not w or w < 50 then w = 400 end
  return w
end

function View:IsAtBottom()
  local range = self.scroll:GetVerticalScrollRange() or 0
  return range - (self.scroll:GetVerticalScroll() or 0) <= 4
end

function View:ScrollToBottom()
  local s = self.scroll
  local function go()
    if s.UpdateScrollChildRect then s:UpdateScrollChildRect() end
    s:SetVerticalScroll(s:GetVerticalScrollRange() or 0)
    self.jump:Hide()
    self:UpdateSticky()
    self:UpdateImages()
  end
  go()
  Compat.After(0, go) -- the range updates after layout
end

function View:UpdateJump()
  if self:IsAtBottom() then self.jump:Hide() end
end

--- Show the sticky header when the message at the top edge has its header scrolled away.
function View:UpdateSticky()
  local tops, list = self.rowTops, self.opts and self.opts.list
  if not list or #list == 0 or not tops[1] then self.sticky:Hide(); return end
  local off = self.scroll:GetVerticalScroll() or 0
  local k = nil
  for i = #list, 1, -1 do
    if tops[i] and tops[i] <= off + 1 then k = i; break end
  end
  local bottom = k and (tops[k + 1] or (tops.last or 0)) or 0
  if k and tops[k] < off - 1 and bottom - off > HEADER_H + 10 then
    local m = list[k]
    local role = ROLE[m.r] or ROLE.s
    self.sticky.role:SetText(role.label)
    self.sticky.role:SetTextColor(role.color[1], role.color[2], role.color[3])
    self.sticky.time:SetText(m.ts and date("%H:%M", m.ts) or "")
    self.sticky.msg = m
    self.sticky:Show()
  else
    self.sticky.msg = nil
    self.sticky:Hide()
  end
end
Messages.View = View

-- pools ---------------------------------------------------------------------------------------
function View:AcquireText()
  self.usedTexts = self.usedTexts + 1
  local fs = self.texts[self.usedTexts]
  if not fs then
    fs = self.child:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    if fs.SetNonSpaceWrap then fs:SetNonSpaceWrap(true) end
    self.texts[self.usedTexts] = fs
  end
  fs:SetFontObject(ChatFontNormal)
  fs:ClearAllPoints()
  fs:Show()
  return fs
end

function View:AcquireCode()
  self.usedCodes = self.usedCodes + 1
  local c = self.codes[self.usedCodes]
  if not c then
    c = CreateFrame("Frame", nil, self.child)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    c.bg:SetVertexColor(0, 0, 0, 0.35)
    c.bg:SetAllPoints(c)
    c.edge = c:CreateTexture(nil, "BORDER")
    c.edge:SetTexture("Interface\\Buttons\\WHITE8X8")
    c.edge:SetVertexColor(0.41, 0.8, 0.94, 0.5)
    c.edge:SetWidth(2)
    c.edge:SetPoint("TOPLEFT")
    c.edge:SetPoint("BOTTOMLEFT")
    c.text = c:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    c.text:SetJustifyH("LEFT")
    c.text:SetJustifyV("TOP")
    c.text:SetWordWrap(true)
    if c.text.SetNonSpaceWrap then c.text:SetNonSpaceWrap(true) end
    c.text:SetPoint("TOPLEFT", 8, -4)
    self.codes[self.usedCodes] = c
  end
  local _, size = ChatFontNormal:GetFont()
  local path, sz = monoFont(math.max(9, math.floor((size or 14) - 1)))
  -- Protected: some clients raise instead of returning false when a font cannot be loaded.
  local okSet, ret = pcall(c.text.SetFont, c.text, path, sz, "")
  if not okSet or ret == false then c.text:SetFontObject(ChatFontNormal) end
  c.text:SetTextColor(0.72, 0.86, 1)
  c:ClearAllPoints()
  c:Show()
  return c
end

--- Thin gold frame + dark backing around an image (native tooltip-like look).
function Messages.AddImageFrame(b)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetColorTexture(0, 0, 0, 0.6)
  b.bg:SetAllPoints(b)
  b.edges = {}
  for k, pts in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local e = b:CreateTexture(nil, "BORDER")
    e:SetColorTexture(1, 0.82, 0, 0.7)
    e:SetPoint(pts[1], b, pts[1], 0, 0)
    e:SetPoint(pts[2], b, pts[2], 0, 0)
    if k <= 2 then e:SetHeight(1) else e:SetWidth(1) end
    b.edges[k] = e
  end
end

local function imageOnEnter(self)
  local img = self.img
  if not img then return end
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  if img.s > 0 then
    GameTooltip:SetText("Click to enlarge")
    GameTooltip:AddLine(Compat.Escape(img.alt or "image"), 0.8, 0.8, 0.8)
  else
    GameTooltip:SetText(Compat.Escape(img.alt or "image"))
  end
  GameTooltip:Show()
end

function View:AcquireImage()
  self.usedImages = (self.usedImages or 0) + 1
  self.images = self.images or {}
  local b = self.images[self.usedImages]
  if not b then
    b = CreateFrame("Button", nil, self.child)
    Messages.AddImageFrame(b)
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetPoint("TOPLEFT", 1, -1)
    b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b.label:SetPoint("LEFT", 8, 0)
    b.label:SetPoint("RIGHT", -8, 0)
    b.label:SetJustifyH("LEFT")
    b:SetScript("OnEnter", imageOnEnter)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self)
      if self.img and self.img.s > 0 and ns.UI.ImageViewer then ns.UI.ImageViewer.Show(self.img) end
    end)
    self.images[self.usedImages] = b
  end
  b:ClearAllPoints()
  b:Show()
  return b
end

--- Lay out one image segment at (x, y + ry); returns the new ry. Images that cannot be shown (slots
--- not working on this client, or the companion has none) become a text line "[image: name]".
function View:LayoutImage(seg, W, y, ry)
  local img = seg.img
  local textOnly = (not ns.ImagesWork or not ns.ImagesWork()) or img.st == "off"
  if textOnly then
    local fs = self:AcquireText()
    fs:SetWidth(W - 2 * PAD_X)
    fs:SetText(Compat.Escape("[image: " .. (img.alt or "image") .. "]"))
    fs:SetTextColor(0.6, 0.6, 0.6)
    fs:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD_X, -(y + ry))
    return ry + (fs:GetStringHeight() or 12) + 2
  end
  local b = self:AcquireImage()
  b.img = img
  local w, h
  if img.s > 0 then
    w, h = ns.State.ImageSize(img.w, img.h, math.min(IMG_MAX_W, W - 2 * PAD_X - 2), IMG_MAX_H)
    w, h = w + 2, h + 2
    b.tex:SetTexCoord(ns.State.ImageTexCoords(img.w, img.h))
    b.label:SetText("")
    b.label:Hide()
    if b.slot ~= img.s then b.slot = img.s; b.textured = false; b.tex:SetTexture(nil) end
    b.tex:Show()
  else
    w, h = math.min(W - 2 * PAD_X, 260), PLACEHOLDER_H
    b.slot, b.textured = nil, false
    b.tex:Hide()
    local reset = ns.state and ns.state.snap and ns.state.snap.imgslots and ns.state.snap.imgslots.reset
    b.label:SetText(Compat.Escape(ns.State.ImagePlaceholder(img, reset)))
    b.label:Show()
  end
  b:SetSize(w, h)
  b:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD_X, -(y + ry))
  b.top, b.bottom = y + ry, y + ry + h
  return ry + h + 4
end

--- Lazy loading: a slot texture is set only once its image is (nearly) visible, so slots the user
--- never scrolls to are not loaded (texture memory; the slot itself is single-use either way).
function View:UpdateImages()
  if not self.images then return end
  local off = self.scroll:GetVerticalScroll() or 0
  local viewH = self.scroll:GetHeight() or 300
  for k = 1, self.usedImages or 0 do
    local b = self.images[k]
    if b.slot and not b.textured and b.bottom and b.bottom >= off - 40 and b.top <= off + viewH + 40 then
      b.tex:SetTexture(Messages.SlotTexture(b.slot))
      b.textured = true
      self.texturesSet = (self.texturesSet or 0) + 1
    end
  end
end

---------------------------------------------------------------------------------------------
-- Thread links (rev 1.4): { "tl", "<label>", id = "<tid>" } segments, e.g. the 'Delegated task "X"
-- finished' line or a subagent in a tool run. Link-coloured text; hover underlines it; click opens
-- that thread in this window.
---------------------------------------------------------------------------------------------
Messages.LINK_COLOR = { 0.41, 0.8, 0.94 }       -- |cff69ccf0, the colour of the "Assistant" label
Messages.LINK_HOVER = { 0.75, 0.93, 1 }
local LINK_ARROW = "\194\187 "                  -- U+00BB, Latin-1 (the WoW fonts have it)

local function linkOnEnter(self)
  local c = Messages.LINK_HOVER
  self.text:SetTextColor(c[1], c[2], c[3])
  self.line:Show()
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:SetText("Open this thread")
  local t = ns.state and self.tid and ns.State.Thread(ns.state, self.tid)
  if t and not t.ref then
    local info = ns.State.STATUS[ns.State.StatusKey(t)]
    GameTooltip:AddLine(Compat.Escape(t.title), 1, 1, 1, true)
    GameTooltip:AddLine(info.label, info.color[1], info.color[2], info.color[3])
  end
  GameTooltip:Show()
end

local function linkOnLeave(self)
  local c = Messages.LINK_COLOR
  self.text:SetTextColor(c[1], c[2], c[3])
  self.line:Hide()
  GameTooltip:Hide()
end

--- Click on a thread link: open that thread (the companion focuses it; Up / the breadcrumb lead back).
function Messages.OpenLink(tid)
  if not tid then return false end
  ns.SelectThread(tid)
  return true
end

function View:AcquireLink()
  self.usedLinks = (self.usedLinks or 0) + 1
  self.links = self.links or {}
  local b = self.links[self.usedLinks]
  if not b then
    b = CreateFrame("Button", nil, self.child)
    b.text = b:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    b.text:SetJustifyH("LEFT")
    b.text:SetJustifyV("TOP")
    b.text:SetWordWrap(true)
    b.text:SetPoint("TOPLEFT", 0, 0)
    b.line = b:CreateTexture(nil, "ARTWORK")
    b.line:SetColorTexture(Messages.LINK_HOVER[1], Messages.LINK_HOVER[2], Messages.LINK_HOVER[3], 0.8)
    b.line:SetHeight(1)
    b.line:SetPoint("BOTTOMLEFT", b.text, "BOTTOMLEFT", 0, -1)
    b.line:SetPoint("BOTTOMRIGHT", b.text, "BOTTOMRIGHT", 0, -1)
    b.line:Hide()
    b:SetScript("OnEnter", linkOnEnter)
    b:SetScript("OnLeave", linkOnLeave)
    b:SetScript("OnClick", function(self) Messages.OpenLink(self.tid) end)
    self.links[self.usedLinks] = b
  end
  b:ClearAllPoints()
  b:Show()
  return b
end

--- Lay out one thread link segment; returns the new row-relative y.
function View:LayoutLink(seg, W, y, ry)
  local b = self:AcquireLink()
  b.tid = seg.id
  local c = Messages.LINK_COLOR
  b.text:SetFontObject(ChatFontNormal)
  b.text:SetWidth(0)
  b.text:SetText(LINK_ARROW .. Compat.Escape(seg[2]))
  local natural = b.text:GetStringWidth() or 0
  local w = math.max(20, math.min(W - 2 * PAD_X, math.floor(natural + 2)))
  b.text:SetWidth(w)
  b.text:SetTextColor(c[1], c[2], c[3])
  b.line:Hide()
  local h = (b.text:GetStringHeight() or 12)
  b:SetSize(w, h + 2)
  b:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD_X, -(y + ry))
  return ry + h + 4
end

local function rowOnEnter(self) self.copy:Show() end
local function rowOnLeave(self) if not self:IsMouseOver() then self.copy:Hide() end end

function View:AcquireRow(k)
  local r = self.rows[k]
  if not r then
    r = CreateFrame("Frame", nil, self.child)
    Compat.EnableMotionOnly(r)
    r.role = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.role:SetPoint("TOPLEFT", PAD_X, -2)
    r.time = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.time:SetPoint("LEFT", r.role, "RIGHT", 6, 0)
    r.copy = CreateFrame("Button", nil, r)
    r.copy:SetSize(16, 16)
    r.copy:SetPoint("TOPRIGHT", -2, 0)
    r.copy:SetNormalTexture("Interface\\Buttons\\UI-GuildButton-PublicNote-Up")
    r.copy:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    r.copy:Hide()
    r.copy:SetScript("OnClick", function() if r.msg and ns.UI.CopyDialog then ns.UI.CopyDialog.Show(r.msg) end end)
    r.copy:SetScript("OnEnter", function(b)
      GameTooltip:SetOwner(b, "ANCHOR_LEFT")
      GameTooltip:SetText("Copy message")
      GameTooltip:Show()
    end)
    r.copy:SetScript("OnLeave", function() GameTooltip:Hide(); rowOnLeave(r) end)
    r:SetScript("OnEnter", rowOnEnter)
    r:SetScript("OnLeave", rowOnLeave)
    self.rows[k] = r
  end
  r:ClearAllPoints()
  r:Show()
  return r
end

---------------------------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------------------------
--- opts = { list = messages, canLoadEarlier, emptyText, onEarlier, forceBottom }
function View:SetMessages(opts)
  local wasAtBottom = self:IsAtBottom() or self.opts == nil
  local sig = ns.State.MessagesSignature(opts.list or {}) .. (opts.canLoadEarlier and "E" or "")
    .. ((ns.ImagesWork and not ns.ImagesWork()) and "T" or "") -- images shown as text after /t3 spike img fail
  local changed = sig ~= self.sig
  self.opts, self.sig = opts, sig
  if not changed and not opts.forceBottom and self.laidOutWidth == self:Width() then return end
  self:Relayout()
  if wasAtBottom or opts.forceBottom then
    self:ScrollToBottom()
  elseif changed then
    self.jump:Show()
  end
end

function View:Relayout()
  local opts = self.opts
  if not opts then return end
  local list = opts.list or {}
  local W = self:Width()
  self.laidOutWidth = W
  self.child:SetWidth(W)
  self.usedTexts, self.usedCodes, self.usedImages, self.usedLinks = 0, 0, 0, 0
  local y = 6

  if opts.canLoadEarlier then
    self.earlier:ClearAllPoints()
    self.earlier:SetPoint("TOP", self.child, "TOP", 0, -y)
    self.earlier:Show()
    if self.earlierFor ~= (list[1] and list[1].i) then
      self.earlierFor = list[1] and list[1].i
      self.earlier:Enable()
      self.earlier:SetText("Earlier messages")
    end
    y = y + 28
  else
    self.earlier:Hide()
  end

  for k, m in ipairs(list) do
    local r = self:AcquireRow(k)
    r.msg = m
    local role = ROLE[m.r] or ROLE.s
    r.role:SetText(role.label)
    r.role:SetTextColor(role.color[1], role.color[2], role.color[3])
    r.time:SetText(m.ts and date("%H:%M", m.ts) or "")
    r:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, -y)
    r:SetWidth(W)
    self.rowTops[k] = y
    local ry = HEADER_H
    local styled = (m.r == "a" or m.r == "u")
    for _, seg in ipairs(m.segs) do
      if seg[1] == "img" and seg.img then
        ry = self:LayoutImage(seg, W, y, ry)
      elseif seg[1] == "tl" and seg.id then
        ry = self:LayoutLink(seg, W, y, ry)
      elseif seg[1] == "p" and styled then
        ry = self:LayoutStyled(seg[2], role, W, y, ry)
      elseif seg[1] == "c" then
        local c = self:AcquireCode()
        c.text:SetWidth(W - 2 * PAD_X - 12)
        c.text:SetText(Compat.Escape(seg[2]))
        local h = (c.text:GetStringHeight() or 12) + 8
        c:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD_X, -(y + ry))
        c:SetSize(W - 2 * PAD_X, h)
        ry = ry + h + 4
      else
        for _, piece in ipairs(Messages.Chunk(seg[2])) do
          local fs = self:AcquireText()
          fs:SetWidth(W - 2 * PAD_X)
          fs:SetText(Compat.Escape(piece))
          fs:SetTextColor(role.body[1], role.body[2], role.body[3])
          fs:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD_X, -(y + ry))
          ry = ry + (fs:GetStringHeight() or 12) + 2
        end
      end
    end
    if m.more then
      local fs = self:AcquireText()
      fs:SetFontObject(GameFontDisableSmall)
      fs:SetWidth(W - 2 * PAD_X)
      fs:SetText("(truncated - full text in T3 Code)")
      fs:SetTextColor(0.6, 0.6, 0.6)
      fs:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD_X, -(y + ry))
      ry = ry + (fs:GetStringHeight() or 10) + 2
    end
    r:SetHeight(ry + 4)
    y = y + ry + 8
  end

  for k = #list + 1, #self.rows do self.rows[k]:Hide(); self.rows[k].msg = nil end
  for k = #list + 1, #self.rowTops do self.rowTops[k] = nil end
  self.rowTops.last = y
  for k = self.usedTexts + 1, #self.texts do self.texts[k]:Hide() end
  for k = self.usedCodes + 1, #self.codes do self.codes[k]:Hide() end
  for k = self.usedImages + 1, #(self.images or {}) do self.images[k]:Hide(); self.images[k].img = nil end
  for k = self.usedLinks + 1, #(self.links or {}) do self.links[k]:Hide(); self.links[k].tid = nil end

  self.child:SetHeight(math.max(y, 1))
  if #list == 0 then
    self.empty:SetText(opts.emptyText or "No messages yet")
    self.empty:Show()
  else
    self.empty:Hide()
  end
  self:UpdateSticky()
  self:UpdateImages()
end

--- One styled paragraph segment (headings, list items with a hanging indent, inline bold/code).
--- Returns the new row-relative y.
function View:LayoutStyled(text, role, W, y, ry)
  for _, b in ipairs(Messages.Blocks(text)) do
    if b.kind == "head" then
      ry = ry + 2
      local fs = self:AcquireText()
      fs:SetWidth(W - 2 * PAD_X)
      fs:SetText(Messages.StyleInline(b.text))
      fs:SetTextColor(HEADING_COLOR[1], HEADING_COLOR[2], HEADING_COLOR[3])
      fs:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD_X, -(y + ry))
      ry = ry + (fs:GetStringHeight() or 12) + 3
    elseif b.kind == "item" then
      local x = PAD_X + b.indent * INDENT
      local bullet = self:AcquireText()
      bullet:SetWidth(0)
      bullet:SetText(Compat.Escape(b.bullet))
      bullet:SetTextColor(role.body[1] * 0.8, role.body[2] * 0.8, role.body[3] * 0.8)
      bullet:SetPoint("TOPLEFT", self.child, "TOPLEFT", x + 2, -(y + ry))
      local bw = math.max(10, math.floor((bullet:GetStringWidth() or 6) + 6))
      local itemH = 0
      for _, piece in ipairs(Messages.Chunk(b.text)) do
        local fs = self:AcquireText()
        fs:SetWidth(math.max(40, W - PAD_X - x - bw))
        fs:SetText(Messages.StyleInline(piece))
        fs:SetTextColor(role.body[1], role.body[2], role.body[3])
        fs:SetPoint("TOPLEFT", self.child, "TOPLEFT", x + bw, -(y + ry + itemH))
        itemH = itemH + (fs:GetStringHeight() or 12)
      end
      ry = ry + itemH + 2
    else
      for _, piece in ipairs(Messages.Chunk(b.text)) do
        local fs = self:AcquireText()
        fs:SetWidth(W - 2 * PAD_X)
        fs:SetText(Messages.StyleInline(piece))
        fs:SetTextColor(role.body[1], role.body[2], role.body[3])
        fs:SetPoint("TOPLEFT", self.child, "TOPLEFT", PAD_X, -(y + ry))
        ry = ry + (fs:GetStringHeight() or 12) + 2
      end
    end
  end
  return ry
end
