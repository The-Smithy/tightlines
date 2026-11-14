-------------------------------------------------------------------------------
--  TightLines: the guide window. A header (your skill, your zone), tabs, a
--  searchable list on the left and a detail page with a zone map on the
--  right. What each tab lists and shows is in Tabs.lua.
--
--  The window's own art lives on child frames: the main frame and the panels
--  carry nothing but their backdrop, so EllesmereUI's skin (which fades a
--  skinned frame's own textures) replaces exactly that and nothing else.
-------------------------------------------------------------------------------
local _, TL = ...
local C = TL.C
local UI = { buttons = {}, accents = {}, mapChoice = {}, selected = {}, rowsData = {}, offset = 0 }
TL.UI = UI

local W, H = 980, 660
local PAD = 10
local HEADER_H, TABS_H, FOOTER_H = 48, 30, 30
local LIST_W = 320
local ROW_H = 32
local LIST_TOP = 42
local MAP_H = 280
local LIST_H = H - HEADER_H - TABS_H - FOOTER_H - 14
local NUM_ROWS = math.floor((LIST_H - LIST_TOP - 6) / ROW_H) -- the most rows the list ever shows
local SORT_H = 20 -- the sort bar, on tabs that have one: the rows start that much lower
local DETAIL_W = W - LIST_W - PAD * 3
local MAP_W = math.floor(MAP_H * 1.5)
local CHIP_W = DETAIL_W - 24 - MAP_W - 8
local CHIP_H = 22
local CHIP_ROWS = math.floor((MAP_H - 18) / CHIP_H)

local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local fonts = {}

local function FontPath()
  local S = TL.skin
  if S and S.GetFont then
    local ok, path, flag = pcall(S.GetFont)
    if ok and path then return path, flag or "" end
  end
  return FONT, ""
end

-------------------------------------------------------------------------------
--  Building blocks
-------------------------------------------------------------------------------
function UI.Text(parent, size, color, justify, layer)
  local fs = parent:CreateFontString(nil, layer or "OVERLAY")
  local path, flag = FontPath()
  fs:SetFont(path, size or 12, flag)
  fs:SetShadowOffset(1, -1)
  fs:SetShadowColor(0, 0, 0, 0.85)
  local c = color or C.text
  fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
  fs:SetJustifyH(justify or "LEFT")
  fs.tlSize = size or 12
  fonts[#fonts + 1] = fs
  return fs
end

function UI.RefreshFonts()
  local path, flag = FontPath()
  for _, fs in ipairs(fonts) do fs:SetFont(path, fs.tlSize, flag) end
end

function UI.Backdrop(f, bg, border)
  f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
  local b = border or C.border
  f:SetBackdropBorderColor(b[1], b[2], b[3], b[4] or 1)
end

-- A texture that follows the accent color (EllesmereUI's when it skins us).
function UI.Accent(tex, alpha)
  UI.accents[#UI.accents + 1] = { tex, alpha or 1 }
  local r, g, b = TL.Accent()
  tex:SetColorTexture(r, g, b, alpha or 1)
  return tex
end

function UI.Tip(owner, title, lines, anchor)
  GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
  GameTooltip:AddLine(title, 1, 1, 1)
  for _, line in ipairs(lines or {}) do
    GameTooltip:AddLine(line, 0.72, 0.74, 0.78, true)
  end
  GameTooltip:Show()
end

function UI.Button(parent, text, width, height, onClick)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b:SetSize(width, height or 22)
  UI.Backdrop(b, { 0.11, 0.13, 0.17, 1 })
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetColorTexture(1, 1, 1, 0.08)
  hl:SetAllPoints()
  b.label = UI.Text(b, 11, C.text, "CENTER")
  b.label:SetPoint("CENTER", 0, 0)
  b.label:SetText(text or "")
  b.fn = onClick
  b:SetScript("OnClick", function(self) if self.fn then self.fn(self) end end)
  b:SetScript("OnEnter", function(self)
    if self.tip then UI.Tip(self, self.tipTitle or self.label:GetText(), { self.tip }, "ANCHOR_TOP") end
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  function b:SetLabel(t) self.label:SetText(t or "") end
  UI.buttons[#UI.buttons + 1] = b
  if UI.skinned and TL.skin then pcall(TL.skin.Button, b) end
  return b
end

-------------------------------------------------------------------------------
--  The window
-------------------------------------------------------------------------------
local function CreateRow(parent, i)
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(ROW_H)
  r:SetPoint("TOPLEFT", 5, -(LIST_TOP + (i - 1) * ROW_H))
  r:SetPoint("TOPRIGHT", -13, -(LIST_TOP + (i - 1) * ROW_H))

  r.stripe = r:CreateTexture(nil, "BACKGROUND")
  r.stripe:SetAllPoints()
  r.stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.022 or 0)
  r.sel = UI.Accent(r:CreateTexture(nil, "BORDER"), 0.16)
  r.sel:SetAllPoints()
  r.bar = UI.Accent(r:CreateTexture(nil, "ARTWORK"), 1)
  r.bar:SetPoint("TOPLEFT")
  r.bar:SetPoint("BOTTOMLEFT")
  r.bar:SetWidth(2)
  r.hl = r:CreateTexture(nil, "HIGHLIGHT")
  r.hl:SetAllPoints()
  r.hl:SetColorTexture(1, 1, 1, 0.06)

  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetSize(24, 24)
  r.icon:SetPoint("LEFT", 7, 0)
  r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  r.text = UI.Text(r, 12, C.text)
  r.text:SetPoint("TOPLEFT", r, "TOPLEFT", 38, -3)
  r.text:SetPoint("TOPRIGHT", r, "TOPRIGHT", -78, -3)
  r.text:SetWordWrap(false)
  r.sub = UI.Text(r, 10, C.dim)
  r.sub:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 38, 3)
  r.sub:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -78, 3)
  r.sub:SetWordWrap(false)
  r.right = UI.Text(r, 11, C.text, "RIGHT")
  r.right:SetPoint("TOPRIGHT", -6, -4)
  r.rightSub = UI.Text(r, 10, C.dim, "RIGHT")
  r.rightSub:SetPoint("BOTTOMRIGHT", -6, 4)

  -- Section header look
  r.head = UI.Text(r, 11, C.gold)
  r.head:SetPoint("BOTTOMLEFT", 6, 6)
  -- The plus or minus of a heading that folds (data.collapseKey)
  r.fold = r:CreateTexture(nil, "ARTWORK")
  r.fold:SetSize(12, 12)
  r.fold:SetPoint("BOTTOMLEFT", 5, 6)
  r.headCount = UI.Text(r, 10, C.faint, "RIGHT")
  r.headCount:SetPoint("BOTTOMRIGHT", -6, 6)
  r.headLine = r:CreateTexture(nil, "ARTWORK")
  r.headLine:SetColorTexture(1, 0.82, 0, 0.22)
  r.headLine:SetHeight(1)
  r.headLine:SetPoint("BOTTOMLEFT", 4, 2)
  r.headLine:SetPoint("BOTTOMRIGHT", -4, 2)

  r:SetScript("OnClick", function(self)
    local data = self.data
    if not data then return end
    if not data.header then
      UI:Select(data.key)
    elseif data.collapseKey then
      UI:ToggleCollapse(data.collapseKey, data.collapsed)
    end
  end)
  r:SetScript("OnEnter", function(self)
    local d = self.data
    if not d or d.header then return end
    if d.itemID then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(d.itemID)
      GameTooltip:Show()
    elseif d.tip then
      UI.Tip(self, d.plain or d.text, d.tip)
    end
  end)
  r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  r:EnableMouseWheel(true)
  r:SetScript("OnMouseWheel", function(_, delta) UI:Scroll(-delta * 3) end)
  return r
end

function UI:Create()
  if self.frame then return self.frame end

  local f = CreateFrame("Frame", "TightLinesFrame", UIParent, "BackdropTemplate")
  self.frame = f
  f:SetSize(W, H)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  UI.Backdrop(f, C.bg)
  f:SetScale(TL.db.scale or 1)
  local pos = TL.db.pos
  if pos then
    f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
  else
    f:SetPoint("CENTER")
  end
  tinsert(UISpecialFrames, "TightLinesFrame")
  f:Hide()

  local function SavePos()
    f:StopMovingOrSizing()
    local point, _, rel, x, y = f:GetPoint(1)
    TL.db.pos = { point, rel, x, y }
  end

  ---------------------------------------------------------------------------
  -- Header
  ---------------------------------------------------------------------------
  local head = CreateFrame("Frame", nil, f)
  head:SetPoint("TOPLEFT", 1, -1)
  head:SetPoint("TOPRIGHT", -1, -1)
  head:SetHeight(HEADER_H)
  head:EnableMouse(true)
  head:RegisterForDrag("LeftButton")
  head:SetScript("OnDragStart", function() f:StartMoving() end)
  head:SetScript("OnDragStop", SavePos)
  self.head = head
  head.bg = head:CreateTexture(nil, "BACKGROUND")
  head.bg:SetAllPoints()
  head.bg:SetColorTexture(0, 0, 0, 0.35)
  head.line = UI.Accent(head:CreateTexture(nil, "ARTWORK"), 0.55)
  head.line:SetHeight(1)
  head.line:SetPoint("BOTTOMLEFT")
  head.line:SetPoint("BOTTOMRIGHT")

  local icon = head:CreateTexture(nil, "ARTWORK")
  icon:SetSize(30, 30)
  icon:SetPoint("LEFT", 10, 0)
  icon:SetTexture("Interface\\Icons\\Trade_Fishing")
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  local title = UI.Text(head, 18, C.text)
  title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 9, 4)
  title:SetText(TL.LOGO)
  local subtitle = UI.Text(head, 10, C.dim)
  subtitle:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 9, -3)
  subtitle:SetText("Fishing guide for WoW Forever")

  local close = CreateFrame("Button", nil, head, "UIPanelCloseButton")
  close:SetPoint("RIGHT", -4, 0)
  close:SetScript("OnClick", function() f:Hide() end)
  self.close = close

  self.skillText = UI.Text(head, 13, C.text, "RIGHT")
  self.skillText:SetPoint("TOPRIGHT", head, "TOPRIGHT", -42, -8)
  self.zoneText = UI.Text(head, 10, C.dim, "RIGHT")
  self.zoneText:SetPoint("BOTTOMRIGHT", head, "BOTTOMRIGHT", -42, 8)

  ---------------------------------------------------------------------------
  -- Tabs
  ---------------------------------------------------------------------------
  self.tabButtons = {}
  local x = PAD
  for _, tab in ipairs(TL.Tabs.list) do
    local b = CreateFrame("Button", nil, f)
    b.tab = tab
    b:SetSize(104, TABS_H - 4)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -(HEADER_H + 5))
    b.on = b:CreateTexture(nil, "BACKGROUND")
    b.on:SetAllPoints()
    b.on:SetColorTexture(1, 1, 1, 0.05)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.05)
    b.under = UI.Accent(b:CreateTexture(nil, "OVERLAY"), 1)
    b.under:SetHeight(2)
    b.under:SetPoint("BOTTOMLEFT")
    b.under:SetPoint("BOTTOMRIGHT")
    b.label = UI.Text(b, 12, C.dim, "CENTER")
    b.label:SetPoint("CENTER", 0, 1)
    b.label:SetText(tab.label)
    b:SetScript("OnClick", function(self) UI:SelectTab(self.tab.key) end)
    self.tabButtons[#self.tabButtons + 1] = b
    x = x + 108
  end

  ---------------------------------------------------------------------------
  -- List (left)
  ---------------------------------------------------------------------------
  local top = -(HEADER_H + TABS_H + 8)
  local list = CreateFrame("Frame", nil, f, "BackdropTemplate")
  list:SetPoint("TOPLEFT", PAD, top)
  list:SetPoint("BOTTOMLEFT", PAD, FOOTER_H + 6)
  list:SetWidth(LIST_W)
  UI.Backdrop(list, C.panel)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta) UI:Scroll(-delta * 3) end)
  self.list = list

  local search = CreateFrame("EditBox", nil, list, "BackdropTemplate")
  search:SetPoint("TOPLEFT", 8, -8)
  search:SetPoint("TOPRIGHT", -100, -8)
  search:SetHeight(26)
  UI.Backdrop(search, { 0.02, 0.025, 0.035, 1 })
  search:SetAutoFocus(false)
  search:SetTextInsets(8, 8, 0, 0)
  local path, flag = FontPath()
  search:SetFont(path, 12, flag)
  search.tlSize = 12
  fonts[#fonts + 1] = search
  search:SetTextColor(C.text[1], C.text[2], C.text[3])
  search.hint = UI.Text(search, 12, C.faint)
  search.hint:SetPoint("LEFT", 8, 0)
  search:SetScript("OnTextChanged", function(self)
    self.hint:SetShown(self:GetText() == "")
    UI.offset = 0
    UI:RefreshList()
  end)
  search:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
  end)
  search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  self.search = search

  self.filterBtn = UI.Button(list, "", 86, 26, function()
    UI.filterOn = not UI.filterOn
    UI:UpdateFilterButton()
    UI.offset = 0
    UI:RefreshList()
  end)
  self.filterBtn:SetPoint("TOPRIGHT", -8, -8)

  -- Sort bar (the tab's `sorts`); UI:UpdateSortBar fills it
  local sortBar = CreateFrame("Frame", nil, list)
  sortBar:SetPoint("TOPLEFT", 8, -(LIST_TOP - 3))
  sortBar:SetPoint("TOPRIGHT", -8, -(LIST_TOP - 3))
  sortBar:SetHeight(SORT_H)
  sortBar.label = UI.Text(sortBar, 10, C.faint)
  sortBar.label:SetPoint("LEFT", 2, 0)
  sortBar.label:SetText("Sort")
  sortBar.buttons = {}
  sortBar:Hide()
  self.sortBar = sortBar

  self.rows = {}
  for i = 1, NUM_ROWS do self.rows[i] = CreateRow(list, i) end
  self.numRows, self.listTop = NUM_ROWS, LIST_TOP

  self.emptyList = UI.Text(list, 11, C.dim, "CENTER")
  self.emptyList:SetPoint("TOP", 0, -(LIST_TOP + 40))
  self.emptyList:SetWidth(LIST_W - 40)

  -- Scroll bar: a track and a thumb, shaped like the game's minimal bar
  local bar = CreateFrame("Frame", nil, list)
  bar:SetPoint("TOPRIGHT", -4, -LIST_TOP)
  bar:SetSize(6, NUM_ROWS * ROW_H)
  bar.bg = bar:CreateTexture(nil, "BACKGROUND")
  bar.bg:SetAllPoints()
  bar.bg:SetColorTexture(1, 1, 1, 0.04)
  local thumb = CreateFrame("Button", nil, bar)
  thumb:SetWidth(6)
  thumb.tex = thumb:CreateTexture(nil, "ARTWORK")
  thumb.tex:SetAllPoints()
  thumb.tex:SetColorTexture(1, 1, 1, 0.3)
  thumb:SetScript("OnMouseDown", function(self)
    local _, cy = GetCursorPosition()
    self.dragY, self.dragOffset = cy / self:GetEffectiveScale(), UI.offset
    self:SetScript("OnUpdate", function(t)
      local _, y = GetCursorPosition()
      y = y / t:GetEffectiveScale()
      local maxOff = math.max(0, #UI.rowsData - UI.numRows)
      local travel = bar:GetHeight() - t:GetHeight()
      if travel > 0 and maxOff > 0 then
        UI.offset = math.floor(t.dragOffset + (t.dragY - y) / travel * maxOff + 0.5)
        UI:UpdateRows()
      end
    end)
  end)
  thumb:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)
  thumb:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)
  self.scrollBar, self.thumb = bar, thumb

  ---------------------------------------------------------------------------
  -- Detail (right)
  ---------------------------------------------------------------------------
  local d = CreateFrame("Frame", nil, f, "BackdropTemplate")
  d:SetPoint("TOPLEFT", list, "TOPRIGHT", PAD, 0)
  d:SetPoint("BOTTOMRIGHT", -PAD, FOOTER_H + 6)
  UI.Backdrop(d, C.panel)
  self.detail = d

  d.icon = CreateFrame("Button", nil, d, "BackdropTemplate")
  d.icon:SetSize(42, 42)
  d.icon:SetPoint("TOPLEFT", 12, -12)
  UI.Backdrop(d.icon, { 0, 0, 0, 1 }, { 0, 0, 0, 1 })
  d.icon.tex = d.icon:CreateTexture(nil, "ARTWORK")
  d.icon.tex:SetPoint("TOPLEFT", 1, -1)
  d.icon.tex:SetPoint("BOTTOMRIGHT", -1, 1)
  d.icon.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  d.icon:SetScript("OnEnter", function(self)
    if not self.itemID then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(self.itemID)
    GameTooltip:Show()
  end)
  d.icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
  d.icon:SetScript("OnClick", function(self)
    local link = self.itemID and TL.ItemLink(self.itemID)
    if link and IsModifiedClick and IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then
      ChatEdit_InsertLink(link)
    end
  end)

  d.actions = {}
  for i = 1, 3 do
    local b = UI.Button(d, "", 92, 24)
    if i == 1 then
      b:SetPoint("TOPRIGHT", -12, -14)
    else
      b:SetPoint("RIGHT", d.actions[i - 1], "LEFT", -6, 0)
    end
    d.actions[i] = b
  end

  d.title = UI.Text(d, 17, C.text)
  d.title:SetPoint("TOPLEFT", d.icon, "TOPRIGHT", 11, -2)
  d.title:SetWidth(DETAIL_W - 42 - 36 - 3 * 98)
  d.title:SetWordWrap(false)
  d.sub = UI.Text(d, 11, C.dim)
  d.sub:SetPoint("BOTTOMLEFT", d.icon, "BOTTOMRIGHT", 11, 3)
  d.sub:SetWidth(DETAIL_W - 42 - 36)
  d.sub:SetWordWrap(false)

  d.info = UI.Text(d, 11, C.text)
  d.info:SetPoint("TOPLEFT", 12, -64)
  d.info:SetWidth(DETAIL_W - 24)
  d.info:SetJustifyV("TOP")
  d.info:SetSpacing(3)
  if d.info.SetMaxLines then d.info:SetMaxLines(10) end

  self.mapView = TL.CreateMapView(d, MAP_W, MAP_H)
  self.mapView.frame:SetPoint("BOTTOMLEFT", 12, 12)

  -- Filter bar above the map (a page's `filters`: a zone's kinds of catch)
  d.filterBar = CreateFrame("Frame", nil, d)
  d.filterBar:SetPoint("BOTTOMLEFT", self.mapView.frame, "TOPLEFT", 0, 5)
  d.filterBar:SetSize(DETAIL_W - 24, 20)
  d.filterBar.label = UI.Text(d.filterBar, 10, C.faint)
  d.filterBar.label:SetPoint("LEFT", 1, 0)
  d.filterBar.buttons = {}
  d.filterBar:Hide()

  -- Chips: a column beside the map (the zones a fish is in, a zone's catches...)
  d.chips = CreateFrame("Frame", nil, d)
  d.chips:SetPoint("TOPLEFT", self.mapView.frame, "TOPRIGHT", 8, 0)
  d.chips:SetSize(CHIP_W, MAP_H)
  d.chips:EnableMouseWheel(true)
  d.chips:SetScript("OnMouseWheel", function(_, delta) UI:ScrollChips(-delta) end)
  d.chipLabel = UI.Text(d.chips, 10, C.faint)
  d.chipLabel:SetPoint("TOPLEFT", 1, -2)
  self.chipPool = {}
  self.chipOffset = 0

  ---------------------------------------------------------------------------
  -- Footer
  ---------------------------------------------------------------------------
  local foot = CreateFrame("Frame", nil, f)
  foot:SetPoint("BOTTOMLEFT", PAD, 3)
  foot:SetPoint("BOTTOMRIGHT", -PAD, 3)
  foot:SetHeight(FOOTER_H - 4)
  self.foot = foot
  self.status = UI.Text(foot, 10, C.dim)
  self.status:SetPoint("LEFT", 2, 0)

  local help = UI.Button(foot, "Help", 60, 20, function() TL.PrintHelp() end)
  help:SetPoint("RIGHT", 0, 0)
  help.tip = "Lists the /tl commands in chat."
  local scan = UI.Button(foot, "Fish list for Auctionator", 170, 20, function() TL.Prices.SendAllFish() end)
  scan:SetPoint("RIGHT", help, "LEFT", -6, 0)
  scan.tip = "Saves every fish as the Auctionator shopping list \"TightLines Fish\". Search it at the Auction House to refresh every price in the guide."
  self.trackBtn = UI.Button(foot, "Stop tracking", 100, 20, function() TL.WorldMap.SetTrack(nil) end)
  self.trackBtn:SetPoint("RIGHT", scan, "LEFT", -6, 0)
  self.trackBtn.tip = "Clears TightLines' pins from the world map."

  f:SetScript("OnShow", function()
    TL:UpdateSkill()
    UI:Refresh()
  end)

  self.offset = 0
  if TL.skin then self:ApplySkin() end
  return f
end

-------------------------------------------------------------------------------
--  EllesmereUI skin (Integrations.lua hands us the facade as TL.skin)
-------------------------------------------------------------------------------
function UI:ApplySkin()
  local S = TL.skin
  if not (S and self.frame) or self.skinned then return end
  self.skinned = true
  pcall(S.Shell, self.frame, { noTopBar = true })
  pcall(S.Panel, self.list, { inset = true })
  pcall(S.Panel, self.detail, { inset = true })
  pcall(S.CloseButton, self.close)
  pcall(S.EditBox, self.search)
  for _, b in ipairs(self.buttons) do pcall(S.Button, b) end
  UI.RefreshFonts()
  self:ApplyAccent()
end

function UI:ApplyAccent()
  local r, g, b = TL.Accent()
  for _, a in ipairs(self.accents) do a[1]:SetColorTexture(r, g, b, a[2]) end
  if self.frame and self.frame:IsShown() then self:QueueRefresh() end
end

-------------------------------------------------------------------------------
--  Header and footer
-------------------------------------------------------------------------------
function UI:UpdateHeader()
  local s = TL.skill
  if s then
    self.skillText:SetText(("Fishing %s%d|r%s |cff777777/ %d|r"):format(TL.Hex(C.gold), s.rank,
      s.mod > 0 and (" |cff59ff73+" .. s.mod .. "|r") or "", s.max))
  else
    self.skillText:SetText("|cffff5555No Fishing skill|r |cff888888(see Trainers)|r")
  end
  local zone = TL.PlayerZone()
  local state, low, high = TL.ZoneState(zone)
  local text = "You are in " .. TL.MapName(zone)
  if low then
    text = text .. ":  " .. TL.Hex(TL.STATE_COLORS[state]) .. "Fishing " .. low .. "-" .. high
      .. (state ~= "none" and ("  " .. TL.STATE_TEXT[state]) or "") .. "|r"
  end
  self.zoneText:SetText(text)
end

local READY = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t"
local NOT_READY = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12:12|t"

function UI:UpdateFooter()
  local src = TL.Sources.Status()
  local parts = {
    (TL.Prices.Available() and READY or NOT_READY) .. " Auctionator prices",
    (src.lfd and READY or NOT_READY) .. " LibForeverData",
    (src.questie and READY or NOT_READY) .. " QuestieDB",
  }
  local t = TL.db.track
  if t then parts[#parts + 1] = TL.AccentHex() .. "Tracking: " .. (TL.TrackName(t) or "") .. "|r" end
  self.status:SetText(table.concat(parts, "     "))
  self.trackBtn:SetShown(t ~= nil)
end

-------------------------------------------------------------------------------
--  List
-------------------------------------------------------------------------------
function UI:UpdateFilterButton()
  local tab = self.tab
  self.filterBtn:SetShown(tab ~= nil and tab.filterLabel ~= nil)
  if tab and tab.filterLabel then
    self.filterBtn:SetLabel(tab.filterLabel)
    local r, g, b = TL.Accent()
    if self.filterOn then
      self.filterBtn.label:SetTextColor(r, g, b)
    else
      self.filterBtn.label:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
    end
    self.filterBtn.tipTitle = tab.filterLabel
    self.filterBtn.tip = (tab.filterTip or "") .. (self.filterOn and "\n\nOn: click to show everything." or "\n\nOff: click to turn on.")
  end
end

-- The list's sort on this tab: { key, desc }, remembered between sessions.
function UI:SortState()
  local tab = self.tab
  if not (tab and tab.sorts) then return nil end
  TL.db.sort = TL.db.sort or {}
  local state = TL.db.sort[tab.key]
  local known = false
  for _, sort in ipairs(tab.sorts) do
    if state and state.key == sort.key then known = true end
  end
  if not known then
    state = { key = tab.sorts[1].key, desc = tab.sorts[1].desc and true or false }
    TL.db.sort[tab.key] = state
  end
  return state
end

-- A sort button was clicked: sort by it, or reverse it when it is the sort already.
function UI:SetSort(sort)
  local state = self:SortState()
  if not state then return end
  if state.key == sort.key then
    if not sort.fixed then state.desc = not state.desc end
  else
    state.key, state.desc = sort.key, sort.desc and true or false
  end
  self.offset = 0
  self:UpdateSortBar()
  self:RefreshList()
end

local function SortButton(bar, i)
  local b = bar.buttons[i]
  if b then return b end
  b = CreateFrame("Button", nil, bar)
  b:SetSize(62, SORT_H - 2)
  b:SetPoint("LEFT", bar, "LEFT", 32 + (i - 1) * 66, 0)
  b.hl = b:CreateTexture(nil, "HIGHLIGHT")
  b.hl:SetAllPoints()
  b.hl:SetColorTexture(1, 1, 1, 0.06)
  b.label = UI.Text(b, 10, C.dim)
  b.label:SetPoint("LEFT", 6, 0)
  b.arrow = b:CreateTexture(nil, "ARTWORK")
  b.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
  b.arrow:SetSize(9, 9)
  b.arrow:SetPoint("LEFT", b.label, "RIGHT", 3, -1)
  b:SetScript("OnClick", function(self) UI:SetSort(self.sort) end)
  b:SetScript("OnEnter", function(self)
    local lines = { self.sort.tip }
    if not self.sort.fixed then lines[#lines + 1] = "Click again to reverse the order." end
    UI.Tip(self, "Sort by " .. self.sort.label:lower(), lines, "ANCHOR_TOP")
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  bar.buttons[i] = b
  return b
end

-- The sort bar for this tab, and the rows moved down to make room for it.
function UI:UpdateSortBar()
  local tab, bar = self.tab, self.sortBar
  local sorts = tab and tab.sorts
  local state = self:SortState()
  bar:SetShown(sorts ~= nil)
  local r, g, b = TL.Accent()
  for i, sort in ipairs(sorts or {}) do
    local button = SortButton(bar, i)
    button.sort = sort
    button.label:SetText(sort.label)
    local on = state.key == sort.key
    if on then
      button.label:SetTextColor(r, g, b)
    else
      button.label:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
    end
    button.arrow:SetShown(on and not sort.fixed)
    button.arrow:SetVertexColor(r, g, b)
    -- The art points down: flipped for ascending
    if state.desc then
      button.arrow:SetTexCoord(0, 0.5625, 0, 1)
    else
      button.arrow:SetTexCoord(0, 0.5625, 1, 0)
    end
    button:Show()
  end
  for i = #(sorts or {}) + 1, #bar.buttons do bar.buttons[i]:Hide() end

  local top = LIST_TOP + (sorts and SORT_H or 0)
  if top ~= self.listTop or not self.listLaidOut then
    self.listTop, self.listLaidOut = top, true
    self.numRows = math.min(NUM_ROWS, math.floor((LIST_H - top - 6) / ROW_H))
    for i, row in ipairs(self.rows) do
      row:ClearAllPoints()
      row:SetPoint("TOPLEFT", 5, -(top + (i - 1) * ROW_H))
      row:SetPoint("TOPRIGHT", -13, -(top + (i - 1) * ROW_H))
    end
    self.scrollBar:ClearAllPoints()
    self.scrollBar:SetPoint("TOPRIGHT", -4, -top)
    self.scrollBar:SetSize(6, self.numRows * ROW_H)
    self.emptyList:ClearAllPoints()
    self.emptyList:SetPoint("TOP", 0, -(top + 40))
  end
end

function UI:RefreshList()
  if not (self.frame and self.tab) then return end
  local query = strtrim(self.search:GetText() or ""):lower()
  local ok, rows = pcall(self.tab.rows, query, self.filterOn and true or false, self:SortState())
  if not ok then
    TL.Error(rows)
    rows = {}
  end
  self.rowsData = rows or {}
  self:UpdateRows()
end

-- Fold or unfold a list heading (remembered between sessions).
-- collapsed: how the heading is now. What is stored is the new state, true or
-- false, so a tab can have its headings folded or open until you choose.
function UI:ToggleCollapse(key, collapsed)
  TL.db.collapsed = TL.db.collapsed or {}
  TL.db.collapsed[key] = not collapsed
  self:RefreshList()
end

function UI:Scroll(delta)
  self.offset = (self.offset or 0) + delta
  self:UpdateRows()
end

function UI:UpdateRows()
  local total = #self.rowsData
  local shown = self.numRows
  local maxOff = math.max(0, total - shown)
  self.offset = math.min(math.max(self.offset or 0, 0), maxOff)
  local selected = self.tab and self.selected[self.tab.key]
  local ar, ag, ab = TL.Accent()
  for i = 1, NUM_ROWS do
    local r, data = self.rows[i], (i <= shown) and self.rowsData[self.offset + i] or nil
    r.data = data
    if not data then
      r:Hide()
    elseif data.header then
      r.icon:Hide(); r.text:Hide(); r.sub:Hide(); r.right:Hide(); r.rightSub:Hide()
      r.sel:Hide(); r.bar:Hide(); r.stripe:Hide()
      r.hl:SetAlpha(data.collapseKey and 1 or 0)
      r.fold:SetShown(data.collapseKey ~= nil)
      r.fold:SetTexture(data.collapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
      r.head:ClearAllPoints()
      r.head:SetPoint("BOTTOMLEFT", data.collapseKey and 22 or 6, 6)
      r.head:SetText(data.text:upper())
      r.headCount:SetText(data.count or "")
      r.head:Show(); r.headCount:Show(); r.headLine:Show()
      r:Show()
    else
      r.head:Hide(); r.headCount:Hide(); r.headLine:Hide(); r.fold:Hide()
      r.stripe:Show(); r.hl:SetAlpha(1)
      r.icon:SetTexture(data.icon or 134400)
      r.icon:SetDesaturated(data.faded and true or false)
      r.icon:Show()
      r.text:SetText(data.text or "")
      local c = data.color or C.text
      r.text:SetTextColor(c[1], c[2], c[3], data.faded and 0.6 or 1)
      r.sub:SetText(data.sub or "")
      r.right:SetText(data.right or "")
      r.rightSub:SetText(data.rightSub or "")
      r.text:Show(); r.sub:Show(); r.right:Show(); r.rightSub:Show()
      local on = data.key == selected
      r.sel:SetShown(on)
      r.bar:SetShown(on)
      r:Show()
    end
  end
  self.emptyList:SetShown(total == 0)
  if total == 0 then
    self.emptyList:SetText((self.tab and self.tab.emptyText) or "Nothing matches.")
  end
  local bar, thumb = self.scrollBar, self.thumb
  if maxOff == 0 then
    thumb:Hide()
  else
    local height = bar:GetHeight()
    local th = math.max(24, height * shown / total)
    thumb:SetHeight(th)
    thumb:ClearAllPoints()
    thumb:SetPoint("TOP", bar, "TOP", 0, -(height - th) * self.offset / maxOff)
    thumb:Show()
  end
  thumb.tex:SetColorTexture(ar, ag, ab, 0.55)
end

local function FindRow(rows, key)
  for i, data in ipairs(rows) do
    if not data.header and data.key == key then return i end
  end
end

-------------------------------------------------------------------------------
--  Detail
-------------------------------------------------------------------------------
local function Chip(pool, parent, i)
  local chip = pool[i]
  if chip then return chip end
  chip = CreateFrame("Button", nil, parent, "BackdropTemplate")
  chip:SetHeight(20)
  UI.Backdrop(chip, { 0.1, 0.12, 0.16, 1 })
  chip.hl = chip:CreateTexture(nil, "HIGHLIGHT")
  chip.hl:SetAllPoints()
  chip.hl:SetColorTexture(1, 1, 1, 0.08)
  chip.label = UI.Text(chip, 10, C.text, "LEFT")
  chip.label:SetPoint("LEFT", 7, 0)
  chip.label:SetPoint("RIGHT", -7, 0)
  chip.label:SetWordWrap(false)
  chip:EnableMouseWheel(true)
  chip:SetScript("OnMouseWheel", function(_, delta) UI:ScrollChips(-delta) end)
  chip:SetScript("OnClick", function(self)
    local data = self.data
    if not data then return end
    if data.onClick then
      data.onClick()
    elseif data.mapID then
      UI:ChooseMap(data.mapID)
    end
  end)
  chip:SetScript("OnEnter", function(self)
    local data = self.data
    if not data then return end
    if data.itemID then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetItemByID(data.itemID)
      GameTooltip:Show()
    elseif data.tip then
      UI.Tip(self, data.plain or data.text, data.tip, "ANCHOR_TOP")
    end
  end)
  chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
  pool[i] = chip
  return chip
end

function UI:ScrollChips(delta)
  self.chipOffset = (self.chipOffset or 0) + delta
  self:LayoutChips()
end

-- The chips, one per line beside the map. More than fit: the wheel scrolls them.
function UI:LayoutChips()
  local spec = self.spec
  local chips = (spec and spec.chips) or {}
  local d = self.detail
  local maxOffset = math.max(0, #chips - CHIP_ROWS)
  self.chipOffset = math.min(math.max(self.chipOffset or 0, 0), maxOffset)
  local first = self.chipOffset + 1
  local last = math.min(#chips, self.chipOffset + CHIP_ROWS)
  local label = (#chips > 0 and spec.chipLabel) or ""
  if maxOffset > 0 then label = label .. "  " .. first .. "-" .. last .. " of " .. #chips .. " (scroll)" end
  d.chipLabel:SetText(label)
  local ar, ag, ab = TL.Accent()
  local used = 0
  for i = first, last do
    local data = chips[i]
    used = used + 1
    local chip = Chip(self.chipPool, d.chips, used)
    chip.data = data
    chip.label:SetText(data.text)
    chip:SetWidth(CHIP_W)
    chip:ClearAllPoints()
    chip:SetPoint("TOPLEFT", d.chips, "TOPLEFT", 0, -(18 + (used - 1) * CHIP_H))
    local c = data.color or C.text
    chip.label:SetTextColor(c[1], c[2], c[3])
    if data.mapID ~= nil and data.mapID == self.mapShown then
      chip:SetBackdropBorderColor(ar, ag, ab, 1)
      chip:SetBackdropColor(ar * 0.25, ag * 0.25, ab * 0.25, 1)
    else
      chip:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
      chip:SetBackdropColor(0.1, 0.12, 0.16, 1)
    end
    chip:Show()
  end
  for i = used + 1, #self.chipPool do self.chipPool[i]:Hide() end
end

local function FilterButton(bar, i)
  local b = bar.buttons[i]
  if b then return b end
  b = CreateFrame("Button", nil, bar, "BackdropTemplate")
  b:SetHeight(18)
  UI.Backdrop(b, { 0.1, 0.12, 0.16, 1 })
  b.hl = b:CreateTexture(nil, "HIGHLIGHT")
  b.hl:SetAllPoints()
  b.hl:SetColorTexture(1, 1, 1, 0.08)
  b.label = UI.Text(b, 10, C.text, "CENTER")
  b.label:SetPoint("CENTER", 0, 0)
  b:SetScript("OnClick", function(self)
    local spec = UI.spec
    if not (spec and spec.onFilter) then return end
    spec.onFilter(self.key)
    UI.chipOffset = 0
    UI:Select(UI.selected[UI.tab.key])
  end)
  b:SetScript("OnEnter", function(self)
    if self.tip then UI.Tip(self, self.tipTitle, { self.tip }, "ANCHOR_TOP") end
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  bar.buttons[i] = b
  return b
end

-- The page's filter buttons (spec.filters, the active one in spec.filter).
-- One choice is no choice: the bar only shows with two or more.
function UI:LayoutFilters()
  local spec, bar = self.spec, self.detail.filterBar
  local filters = spec and spec.filters
  local show = filters ~= nil and #filters > 1
  bar:SetShown(show)
  if not show then return end
  bar.label:SetText(spec.filterLabel or "Show")
  local x = bar.label:GetStringWidth() + 8
  local ar, ag, ab = TL.Accent()
  for i, filter in ipairs(filters) do
    local b = FilterButton(bar, i)
    b.key, b.tip, b.tipTitle = filter.key, filter.tip, filter.label
    b.label:SetText(filter.label .. (filter.count and ("  |cff7c8088" .. filter.count .. "|r") or ""))
    local w = b.label:GetStringWidth() + 16
    b:SetWidth(w)
    b:ClearAllPoints()
    b:SetPoint("LEFT", bar, "LEFT", x, 0)
    if filter.key == spec.filter then
      b:SetBackdropBorderColor(ar, ag, ab, 1)
      b:SetBackdropColor(ar * 0.25, ag * 0.25, ab * 0.25, 1)
      b.label:SetTextColor(1, 1, 1)
    else
      b:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
      b:SetBackdropColor(0.1, 0.12, 0.16, 1)
      b.label:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
    end
    b:Show()
    x = x + w + 4
  end
  for i = #filters + 1, #bar.buttons do bar.buttons[i]:Hide() end
end

-- Show a map in the detail page with the current page's points on it.
function UI:ShowMap(mapID)
  local spec = self.spec
  local mv = self.mapView
  self.mapShown = mapID
  if not (spec and mapID) then
    mv:SetMap(nil, spec and spec.noMapText)
    mv:SetPoints(nil)
    self:LayoutChips()
    return
  end
  mv:SetMap(mapID)
  local points, note = {}, nil
  if spec.points then
    local ok, pts, n = pcall(spec.points, mapID)
    if ok then
      points, note = pts or {}, n
    else
      TL.Error(pts)
    end
  end
  mv:SetPoints(points, note)
  self:LayoutChips()
end

-- A zone chip was clicked: remember it for this page.
function UI:ChooseMap(mapID)
  if self.spec and self.spec.key then self.mapChoice[self.spec.key] = mapID end
  self:ShowMap(mapID)
end

function UI:ShowDetail(spec)
  if not (spec and self.spec and spec.key == self.spec.key) then self.chipOffset = 0 end
  self.spec = spec
  local d = self.detail
  self:LayoutFilters()
  if not spec then
    d.icon:Hide()
    d.title:SetText("")
    d.sub:SetText("")
    d.info:SetText("")
    for _, b in ipairs(d.actions) do b:Hide() end
    self:ShowMap(nil)
    return
  end
  d.icon:Show()
  d.icon.tex:SetTexture(spec.icon or 134400)
  d.icon.itemID = spec.itemID
  d.title:SetText(spec.title or "")
  local c = spec.titleColor or C.text
  d.title:SetTextColor(c[1], c[2], c[3])
  d.sub:SetText(spec.sub or "")
  d.info:SetText(table.concat(spec.info or {}, "\n"))
  for i, b in ipairs(d.actions) do
    local a = spec.actions and spec.actions[i]
    if a then
      b:SetLabel(a.text)
      b.fn, b.tip, b.tipTitle = a.onClick, a.tip, a.text
      b:Show()
    else
      b:Hide()
    end
  end
  local mapID = spec.key and self.mapChoice[spec.key]
  if mapID and spec.maps and not spec.maps[mapID] then mapID = nil end
  self:ShowMap(mapID or spec.map)
end

-------------------------------------------------------------------------------
--  Tabs and selection
-------------------------------------------------------------------------------
function UI:Select(key, reveal)
  local tab = self.tab
  if not tab then return end
  local spec
  if key ~= nil then
    local ok, result = pcall(tab.select, key)
    if ok then
      spec = result
    else
      TL.Error(result)
    end
  end
  if spec then
    self.selected[tab.key] = key
    spec.key = tab.key .. ":" .. tostring(key)
  end
  self:ShowDetail(spec)
  if reveal and key ~= nil then
    local at = FindRow(self.rowsData, key)
    if at and (at <= self.offset or at > self.offset + self.numRows) then
      self.offset = math.max(0, at - 3)
    end
  end
  self:UpdateRows()
end

function UI:SelectTab(key, wantKey)
  local tab = TL.Tabs.byKey[key] or TL.Tabs.list[1]
  self.tab = tab
  for _, b in ipairs(self.tabButtons) do
    local on = b.tab == tab
    b.under:SetShown(on)
    b.on:SetShown(on)
    if on then
      b.label:SetTextColor(1, 1, 1)
    else
      b.label:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
    end
  end
  self.search.hint:SetText(tab.placeholder or "Search")
  self.offset = 0
  if self.search:GetText() ~= "" then
    self.search:SetText("") -- refreshes the list
  end
  self:UpdateFilterButton()
  self:UpdateSortBar()
  self:RefreshList()
  local sel = wantKey
  if sel == nil or not FindRow(self.rowsData, sel) then sel = self.selected[tab.key] end
  if sel == nil or not FindRow(self.rowsData, sel) then sel = tab.default and tab.default() end
  if sel == nil or not FindRow(self.rowsData, sel) then
    sel = nil
    for _, data in ipairs(self.rowsData) do
      if not data.header then sel = data.key break end
    end
  end
  self:Select(sel, true)
end

-- Redraw everything in place (prices, skill, items or the log changed).
function UI:Refresh()
  if not (self.frame and self.frame:IsShown()) then return end
  self:UpdateHeader()
  self:UpdateFooter()
  if not self.tab then
    self:SelectTab(TL.Tabs.list[1].key)
    return
  end
  self:UpdateFilterButton()
  self:RefreshList()
  self:Select(self.selected[self.tab.key])
end

function UI:QueueRefresh()
  if self.pending or not (self.frame and self.frame:IsShown()) then return end
  self.pending = true
  C_Timer.After(0.15, function()
    self.pending = false
    self:Refresh()
  end)
end

function UI:Toggle()
  if not TL.db then return end
  local f = self:Create()
  if f:IsShown() then f:Hide() else f:Show() end
end

-- Open on a tab, optionally on one of its entries or with a search typed in.
function UI:Open(tabKey, key, search)
  if not TL.db then return end
  local f = self:Create()
  if not f:IsShown() then f:Show() end
  if tabKey then self:SelectTab(tabKey, key) end
  if search and search ~= "" then
    self.search:SetText(search)
    for _, data in ipairs(self.rowsData) do
      if not data.header then
        self:Select(data.key, true)
        break
      end
    end
  end
end

for _, msg in ipairs({ "PRICES", "ITEMS", "SKILL", "CATCH", "ZONE", "TRACK", "TRIP" }) do
  TL:On(msg, function() UI:QueueRefresh() end)
end
