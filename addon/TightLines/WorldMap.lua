-------------------------------------------------------------------------------
--  TightLines: tracking on the game's world map. Whatever the guide tracks (a
--  fish, a zone's pools, a quest, an NPC) is drawn on the world map: its
--  points on a zone map, a marker per zone on a continent map (click one to
--  open that zone).
--
--  The pins are plain frames of our own on the map's canvas; nothing of
--  Blizzard's is hooked beyond OnShow / OnHide, and nothing is protected.
-------------------------------------------------------------------------------
local _, TL = ...
local WM = {}
TL.WorldMap = WM

local overlay, status, ticker
local pins, last = {}, {}

local function Track()
  return TL.db and TL.db.track
end

function WM.IsTracking(kind, id)
  local t = Track()
  return t ~= nil and t.kind == kind and t.id == id
end

local function Canvas()
  if not WorldMapFrame then return nil end
  if type(WorldMapFrame.GetCanvas) == "function" then
    local ok, canvas = pcall(WorldMapFrame.GetCanvas, WorldMapFrame)
    if ok and canvas then return canvas end
  end
  return WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

local function CanvasScale()
  local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
  if sc and type(sc.GetCanvasScale) == "function" then
    local ok, s = pcall(sc.GetCanvasScale, sc)
    if ok and type(s) == "number" and s > 0 then return s end
  end
  return 1
end

local function CurrentMap()
  if not (WorldMapFrame and type(WorldMapFrame.GetMapID) == "function") then return nil end
  local ok, id = pcall(WorldMapFrame.GetMapID, WorldMapFrame)
  return ok and id or nil
end

-- The points for the map the world map shows.
local function PointsFor(t, mapID)
  local info = TL.MapInfo(mapID)
  if not info or not info.mapType or info.mapType >= 3 then
    return TL.TrackPoints(t, mapID)
  end
  -- A continent (or the world): one marker per zone
  local out = {}
  if not (C_Map and C_Map.GetMapRectOnMap) then return out end
  for _, zone in ipairs(TL.TrackMaps(t)) do
    local ok, minX, maxX, minY, maxY = pcall(C_Map.GetMapRectOnMap, zone, mapID)
    if ok and minX and maxX and maxX > minX and maxX <= 1.001 and minX >= -0.001 then
      local state, low, high = TL.ZoneState(zone)
      out[#out + 1] = {
        x = (minX + maxX) * 50, y = (minY + maxY) * 50, kind = "zone", zone = zone, state = state,
        label = TL.MapName(zone), tip = TL.MapName(zone),
        sub = (low and ("Fishing " .. low .. "-" .. high .. ". ") or "") .. "Click to open this zone.",
      }
    end
  end
  return out
end

local function HidePins()
  for _, p in ipairs(pins) do p:Hide() end
end

function WM.Refresh(force)
  if not overlay then return end
  local t = Track()
  if not (t and TL.db.settings.worldMapPins and WorldMapFrame:IsShown()) then
    HidePins()
    status:Hide()
    last = {}
    return
  end
  local canvas = Canvas()
  if not canvas then return end
  local mapID = CurrentMap()
  local w, h = canvas:GetSize()
  local scale = CanvasScale()
  if not (mapID and w and h and w > 1 and h > 1) then return end
  if not force and last.map == mapID and last.w == w and last.h == h and last.scale == scale and last.track == t then
    return
  end
  last = { map = mapID, w = w, h = h, scale = scale, track = t }

  if overlay:GetParent() ~= canvas then overlay:SetParent(canvas) end
  overlay:ClearAllPoints()
  overlay:SetAllPoints(canvas)
  overlay:SetFrameLevel(math.min(canvas:GetFrameLevel() + 2000, 9000))
  overlay:Show()

  -- Pins keep their size on screen whatever the map's zoom: they are scaled
  -- against the canvas, and offsets are given in the pin's own scale.
  local k = 1 / scale
  local points = PointsFor(t, mapID)
  for i, pt in ipairs(points) do
    local p = pins[i]
    if not p then
      p = TL.NewPin(overlay, true)
      p:SetScript("OnClick", function(self)
        local zone = self.pt and self.pt.zone
        if zone and WorldMapFrame.SetMapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, zone) end
      end)
      pins[i] = p
    end
    local kind = TL.StylePin(p, pt)
    p:SetScale(k)
    p:ClearAllPoints()
    p:SetPoint("CENTER", overlay, "TOPLEFT", (pt.x / 100 * w) / k, -(pt.y / 100 * h) / k)
    p:SetFrameLevel(overlay:GetFrameLevel() + (kind.level or 2))
    p:Show()
  end
  for i = #points + 1, #pins do pins[i]:Hide() end

  status.text:SetText(TL.LOGO .. "  |cffffffff" .. (TL.TrackName(t) or "") .. "|r"
    .. (#points == 0 and "  |cff999999nothing on this map|r" or ""))
  status:SetWidth(status.text:GetStringWidth() + 54)
  status:Show()
end

local function Build()
  if overlay or not WorldMapFrame then return end
  overlay = CreateFrame("Frame", nil, Canvas() or WorldMapFrame)
  overlay:Hide()

  -- What is tracked, with a button to stop, at the map's bottom left.
  local host = WorldMapFrame.ScrollContainer or WorldMapFrame
  status = CreateFrame("Frame", nil, host, "BackdropTemplate")
  status:SetHeight(24)
  status:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 8, 8)
  status:SetFrameLevel(host:GetFrameLevel() + 9500)
  status:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
  status:SetBackdropColor(0.03, 0.04, 0.06, 0.88)
  status:SetBackdropBorderColor(0.2, 0.24, 0.3, 1)
  status.icon = status:CreateTexture(nil, "ARTWORK")
  status.icon:SetTexture("Interface\\Icons\\Trade_Fishing")
  status.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  status.icon:SetSize(16, 16)
  status.icon:SetPoint("LEFT", 5, 0)
  status.text = status:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status.text:SetPoint("LEFT", status.icon, "RIGHT", 6, 0)
  status.close = CreateFrame("Button", nil, status)
  status.close:SetSize(18, 18)
  status.close:SetPoint("RIGHT", -3, 0)
  status.close.x = status.close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  status.close.x:SetPoint("CENTER", 0, 1)
  status.close.x:SetText("x")
  status.close.x:SetTextColor(0.8, 0.8, 0.8)
  status.close:SetScript("OnEnter", function(self)
    self.x:SetTextColor(1, 0.3, 0.3)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Stop tracking", 1, 1, 1)
    GameTooltip:Show()
  end)
  status.close:SetScript("OnLeave", function(self)
    self.x:SetTextColor(0.8, 0.8, 0.8)
    GameTooltip:Hide()
  end)
  status.close:SetScript("OnClick", function() WM.SetTrack(nil) end)
  status:EnableMouse(true)
  status:SetScript("OnMouseUp", function() TL.UI:Open() end)
  status:Hide()

  -- While the map is open, follow its map changes and zoom.
  ticker = CreateFrame("Frame")
  ticker:Hide()
  ticker:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < 0.1 then return end
    self.elapsed = 0
    WM.Refresh()
  end)
  WorldMapFrame:HookScript("OnShow", function()
    last = {}
    ticker:Show()
    WM.Refresh(true)
  end)
  WorldMapFrame:HookScript("OnHide", function()
    ticker:Hide()
    HidePins()
  end)
  if WorldMapFrame:IsShown() then ticker:Show() end
end

function WM.Init()
  if overlay then return true end
  if WorldMapFrame then
    Build()
    return true
  end
  return false
end

-- kind nil stops tracking.
function WM.SetTrack(kind, id)
  if not TL.db then return end
  TL.db.track = kind and { kind = kind, id = id } or nil
  WM.Init()
  WM.Refresh(true)
  TL:Fire("TRACK")
end

-- Track and open the world map on a zone that has it.
function WM.ShowOnMap(kind, id, mapID)
  WM.SetTrack(kind, id)
  if not WM.Init() then return end
  if InCombatLockdown and InCombatLockdown() and not WorldMapFrame:IsShown() then
    TL:Print("Tracking " .. (TL.TrackName(Track()) or "") .. ". Open your map after combat.")
    return
  end
  if not WorldMapFrame:IsShown() then
    if type(ToggleWorldMap) == "function" then
      pcall(ToggleWorldMap)
    else
      pcall(ShowUIPanel, WorldMapFrame)
    end
  end
  if mapID and WorldMapFrame.SetMapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, mapID) end
  WM.Refresh(true)
end

TL:On("LOGIN", function()
  if WM.Init() then return end
  -- The world map loads on demand on some clients.
  local waiter = CreateFrame("Frame")
  waiter:RegisterEvent("ADDON_LOADED")
  waiter:SetScript("OnEvent", function(self, _, name)
    if name == "Blizzard_WorldMap" or WorldMapFrame then
      if WM.Init() then self:UnregisterEvent("ADDON_LOADED") end
    end
  end)
end)

TL:On("CATCH", function() if overlay then WM.Refresh(true) end end)
