-------------------------------------------------------------------------------
--  TightLines: the map inside the guide window. Draws a zone's map art from
--  the client's own tiles and lays the guide's points over it.
-------------------------------------------------------------------------------
local _, TL = ...
local MV = {}
MV.__index = MV

local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

-- How each kind of point is drawn.
local KIND = {
  -- Soft highlights without a marker: a kind of water, or where a fish's pools are
  coast    = { size = 0, hit = 18, glow = 44, glowA = 0.2, color = { 0.3, 0.72, 1 }, level = 1, area = true },
  inland   = { size = 0, hit = 18, glow = 44, glowA = 0.22, color = { 0.45, 0.95, 0.5 }, level = 1, area = true },
  poolarea = { size = 0, hit = 18, glow = 46, glowA = 0.26, level = 1, area = true },
  -- Markers
  pool     = { size = 9, glow = 34, glowA = 0.34, pulse = true, level = 3 },
  catch    = { size = 6, glow = 16, glowA = 0.25, color = { 1, 0.82, 0 }, level = 2 },
  spot     = { size = 7, glow = 22, glowA = 0.3, color = { 1, 0.6, 0.2 }, level = 2 },
  quest    = { icon = "Interface\\GossipFrame\\AvailableQuestIcon", size = 18, glow = 30, glowA = 0.35, color = { 1, 0.82, 0 }, level = 5 },
  questEnd = { icon = "Interface\\GossipFrame\\ActiveQuestIcon", size = 18, glow = 30, glowA = 0.35, color = { 1, 0.82, 0 }, level = 5 },
  npc      = { icon = "Interface\\Icons\\Trade_Fishing", crop = 0.08, size = 16, ring = true, glow = 32, glowA = 0.35, level = 5 },
  zone     = { icon = "Interface\\Icons\\Trade_Fishing", crop = 0.08, size = 20, ring = true, glow = 46, glowA = 0.4, pulse = true, level = 5 },
}
TL.PIN_KINDS = KIND

local LEGEND = {
  { "coast", "coastal water" }, { "inland", "inland water" }, { "poolarea", "its pools" },
  { "pool", "pool spawn" }, { "spot", "logged spot" }, { "catch", "your catch", "your catches" },
  { "quest", "quest start" }, { "questEnd", "turn in" }, { "npc", "NPC" },
}

-- Shared with the world map overlay: p has .glow, .ring, .dot (textures) and
-- optionally .label (font string).
function TL.StylePin(p, pt)
  local k = KIND[pt.kind] or KIND.pool
  local c = (pt.state and TL.STATE_COLORS[pt.state]) or pt.color or k.color
  if not c then c = { TL.Accent() } end
  if k.icon then
    local crop = k.crop or 0
    p.dot:SetTexture(k.icon)
    p.dot:SetTexCoord(crop, 1 - crop, crop, 1 - crop)
    p.dot:SetVertexColor(1, 1, 1, 1)
  else
    p.dot:SetTexture(CIRCLE)
    p.dot:SetTexCoord(0, 1, 0, 1)
    p.dot:SetVertexColor(c[1], c[2], c[3], k.a or 1)
  end
  p.dot:SetSize(math.max(k.size, 1), math.max(k.size, 1))
  p.dot:SetShown(k.size > 0)
  local ring = k.size > 0 and ((not k.icon) or k.ring)
  p.ring:SetShown(ring and true or false)
  p.ring:SetSize(k.size + 3, k.size + 3)
  if k.glow and k.glow > 0 then
    p.glow:SetSize(k.glow, k.glow)
    p.glow:SetVertexColor(c[1], c[2], c[3], k.glowA or 0.3)
    p.glow:Show()
  else
    p.glow:Hide()
  end
  local s = k.hit or math.max(k.size + 4, 12)
  p:SetSize(s, s)
  if p.label then
    if pt.label then
      p.label:SetText(pt.label)
      p.label:SetTextColor(c[1], c[2], c[3])
      p.label:Show()
    else
      p.label:Hide()
    end
  end
  if k.pulse then
    if not p.anim then
      p.anim = p.glow:CreateAnimationGroup()
      p.anim:SetLooping("BOUNCE")
      local a = p.anim:CreateAnimation("Alpha")
      a:SetFromAlpha(1)
      a:SetToAlpha(0.35)
      a:SetDuration(1.1)
    end
    if not p.anim:IsPlaying() then p.anim:Play() end
  elseif p.anim then
    p.anim:Stop()
    p.glow:SetAlpha(1)
  end
  p.pt = pt
  return k
end

function TL.PinTooltip(self)
  local pt = self.pt
  if not pt then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(pt.tip or "Fishing spot", 1, 1, 1)
  if pt.sub then GameTooltip:AddLine(pt.sub, 0.7, 0.72, 0.76, true) end
  if pt.kind ~= "zone" then
    GameTooltip:AddLine(("%.1f, %.1f"):format(pt.x, pt.y), 0.5, 0.5, 0.5)
  end
  GameTooltip:Show()
end

function TL.NewPin(parent, withLabel)
  local p = CreateFrame("Button", nil, parent)
  p.glow = p:CreateTexture(nil, "BACKGROUND")
  p.glow:SetTexture(CIRCLE)
  p.glow:SetBlendMode("ADD")
  p.glow:SetPoint("CENTER")
  p.ring = p:CreateTexture(nil, "BORDER")
  p.ring:SetTexture(CIRCLE)
  p.ring:SetVertexColor(0, 0, 0, 0.9)
  p.ring:SetPoint("CENTER")
  p.dot = p:CreateTexture(nil, "ARTWORK")
  p.dot:SetPoint("CENTER")
  if withLabel then
    p.label = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    p.label:SetPoint("TOP", p, "BOTTOM", 0, -2)
  end
  p:SetScript("OnEnter", TL.PinTooltip)
  p:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return p
end

-------------------------------------------------------------------------------
--  The widget
-------------------------------------------------------------------------------
function TL.CreateMapView(parent, w, h)
  local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  f:SetSize(w, h)
  TL.UI.Backdrop(f, { 0.015, 0.02, 0.03, 1 }, TL.C.border)

  local self = setmetatable({ frame = f, w = w - 2, h = h - 2, tiles = {}, pins = {}, used = 0 }, MV)

  self.art = CreateFrame("Frame", nil, f)
  self.art:SetPoint("TOPLEFT", 1, -1)
  self.art:SetPoint("BOTTOMRIGHT", -1, 1)

  self.pinLayer = CreateFrame("Frame", nil, f)
  self.pinLayer:SetAllPoints(self.art)
  self.pinLayer:SetFrameLevel(f:GetFrameLevel() + 4)

  self.overlay = CreateFrame("Frame", nil, f)
  self.overlay:SetAllPoints(self.art)
  self.overlay:SetFrameLevel(f:GetFrameLevel() + 12)

  self.empty = TL.UI.Text(self.overlay, 12, TL.C.dim, "CENTER")
  self.empty:SetPoint("CENTER")
  self.empty:SetWidth(w - 80)

  -- Zone name, top left
  self.labelBg = self.overlay:CreateTexture(nil, "BACKGROUND")
  self.labelBg:SetColorTexture(0, 0, 0, 0.6)
  self.label = TL.UI.Text(self.overlay, 12, TL.C.text)
  self.label:SetPoint("TOPLEFT", 8, -7)
  self.labelBg:SetPoint("TOPLEFT", self.label, "TOPLEFT", -6, 4)
  self.labelBg:SetPoint("BOTTOMRIGHT", self.label, "BOTTOMRIGHT", 6, -4)

  -- Legend, bottom left; a hint line, bottom right
  self.legendBg = self.overlay:CreateTexture(nil, "BACKGROUND")
  self.legendBg:SetColorTexture(0, 0, 0, 0.6)
  self.legend = TL.UI.Text(self.overlay, 10, TL.C.text)
  self.legend:SetPoint("BOTTOMLEFT", 8, 7)
  self.legendBg:SetPoint("TOPLEFT", self.legend, "TOPLEFT", -6, 4)
  self.legendBg:SetPoint("BOTTOMRIGHT", self.legend, "BOTTOMRIGHT", 6, -4)

  self.note = TL.UI.Text(self.overlay, 10, TL.C.dim, "CENTER")
  self.note:SetPoint("BOTTOM", 0, 26)
  self.note:SetWidth(w - 60)
  self.noteBg = self.overlay:CreateTexture(nil, "BACKGROUND")
  self.noteBg:SetColorTexture(0, 0, 0, 0.6)
  self.noteBg:SetPoint("TOPLEFT", self.note, "TOPLEFT", -6, 4)
  self.noteBg:SetPoint("BOTTOMRIGHT", self.note, "BOTTOMRIGHT", 6, -4)

  self.player = self.overlay:CreateTexture(nil, "OVERLAY")
  self.player:SetTexture("Interface\\Minimap\\MinimapArrow")
  self.player:SetSize(26, 26)
  self.player:Hide()

  -- Pool spawn points are off by default; this box turns them on, on every map
  local toggle = CreateFrame("Button", nil, self.overlay)
  toggle:SetSize(104, 20)
  toggle:SetPoint("TOPRIGHT", -6, -5)
  toggle.bg = toggle:CreateTexture(nil, "BACKGROUND")
  toggle.bg:SetAllPoints()
  toggle.bg:SetColorTexture(0, 0, 0, 0.6)
  toggle.hl = toggle:CreateTexture(nil, "HIGHLIGHT")
  toggle.hl:SetAllPoints()
  toggle.hl:SetColorTexture(1, 1, 1, 0.08)
  toggle.box = CreateFrame("Frame", nil, toggle, "BackdropTemplate")
  toggle.box:SetSize(12, 12)
  toggle.box:SetPoint("LEFT", 5, 0)
  TL.UI.Backdrop(toggle.box, { 0.02, 0.03, 0.04, 1 }, { 0.45, 0.48, 0.54, 1 })
  toggle.check = toggle.box:CreateTexture(nil, "OVERLAY")
  toggle.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  toggle.check:SetSize(18, 18)
  toggle.check:SetPoint("CENTER", 0, 0)
  toggle.text = TL.UI.Text(toggle, 10, TL.C.text)
  toggle.text:SetPoint("LEFT", toggle.box, "RIGHT", 5, 0)
  toggle.text:SetText("Pool locations")
  toggle:SetScript("OnClick", function()
    TL.db.settings.showPools = not TL.db.settings.showPools
    TL.WorldMap.Refresh(true)
    TL:Fire("TRACK")
  end)
  toggle:SetScript("OnEnter", function(button)
    TL.UI.Tip(button, "Pool locations", {
      "On: every spot a fishing pool can spawn at is marked, here and on the world map.",
      "Off: the maps only highlight the water each fish is found in.",
    }, "ANCHOR_TOP")
  end)
  toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
  self.toggle = toggle

  f:SetScript("OnUpdate", function(_, elapsed) self:OnUpdate(elapsed) end)
  self:SetMap(nil)
  return self
end

-- Draws mapID's art, fitted and centered. nil (or a map without art) shows
-- `emptyText` instead.
function MV:SetMap(mapID, emptyText)
  self.mapID, self.dw = nil, nil
  for _, t in ipairs(self.tiles) do t:Hide() end
  self.player:Hide()

  local layer, textures
  if mapID and C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures then
    local ok, layers = pcall(C_Map.GetMapArtLayers, mapID)
    layer = ok and type(layers) == "table" and layers[1] or nil
    local okT, list = pcall(C_Map.GetMapArtLayerTextures, mapID, 1)
    textures = okT and type(list) == "table" and #list > 0 and list or nil
  end
  local lw, lh = layer and layer.layerWidth, layer and layer.layerHeight
  local tw, th = layer and layer.tileWidth, layer and layer.tileHeight
  if not (textures and lw and lh and tw and th and lw > 0 and lh > 0 and tw > 0 and th > 0) then
    self.empty:SetText(emptyText or (mapID and "No map art for this area." or "Pick something on the left to see where it is."))
    self.empty:Show()
    self.label:SetText("")
    self.labelBg:Hide()
    self.toggle:Hide()
    return false
  end

  self.empty:Hide()
  local scale = math.min(self.w / lw, self.h / lh)
  local dw, dh = lw * scale, lh * scale
  self.mapID, self.dw, self.dh = mapID, dw, dh
  self.ox, self.oy = (self.w - dw) / 2, (self.h - dh) / 2
  local cols = math.ceil(lw / tw)
  for i, file in ipairs(textures) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local x0, y0 = col * tw, row * th
    local pw, ph = math.min(tw, lw - x0), math.min(th, lh - y0)
    if pw > 0 and ph > 0 then
      local t = self.tiles[i]
      if not t then
        t = self.art:CreateTexture(nil, "ARTWORK")
        if t.SetSnapToPixelGrid then t:SetSnapToPixelGrid(false) end
        if t.SetTexelSnappingBias then t:SetTexelSnappingBias(0) end
        self.tiles[i] = t
      end
      t:SetTexture(file)
      t:SetTexCoord(0, pw / tw, 0, ph / th)
      t:SetVertexColor(0.82, 0.84, 0.88)
      t:SetSize(pw * scale, ph * scale)
      t:ClearAllPoints()
      t:SetPoint("TOPLEFT", self.art, "TOPLEFT", self.ox + x0 * scale, -(self.oy + y0 * scale))
      t:Show()
    end
  end

  local state, low, high = TL.ZoneState(mapID)
  local text = TL.MapName(mapID)
  if low then
    text = text .. "  " .. TL.Hex(TL.STATE_COLORS[state]) .. "Fishing " .. low .. "-" .. high .. "|r"
  end
  self.label:SetText(text)
  self.labelBg:Show()
  self.toggle:Show()
  return true
end

function MV:SetPoints(points, note)
  self.used = 0
  local counts, colors = {}, {}
  if self.dw then
    for _, pt in ipairs(points or {}) do
      self.used = self.used + 1
      local p = self.pins[self.used]
      if not p then
        p = TL.NewPin(self.pinLayer)
        self.pins[self.used] = p
      end
      local k = TL.StylePin(p, pt)
      p:ClearAllPoints()
      p:SetPoint("CENTER", self.art, "TOPLEFT", self.ox + pt.x / 100 * self.dw, -(self.oy + pt.y / 100 * self.dh))
      p:SetFrameLevel(self.pinLayer:GetFrameLevel() + (k.level or 2))
      p:Show()
      counts[pt.kind] = (counts[pt.kind] or 0) + 1
      colors[pt.kind] = colors[pt.kind] or pt.color
    end
  end
  for i = self.used + 1, #self.pins do self.pins[i]:Hide() end

  -- The legend: highlights by name, markers with how many there are
  local parts = {}
  for _, entry in ipairs(LEGEND) do
    local n = counts[entry[1]]
    if n then
      local k = KIND[entry[1]]
      local c = colors[entry[1]] or k.color or { TL.Accent() }
      if k.area then
        parts[#parts + 1] = TL.Dot(c) .. " " .. entry[2]
      else
        parts[#parts + 1] = TL.Dot(c) .. " " .. n .. " " .. (n == 1 and entry[2] or (entry[3] or (entry[2] .. "s")))
      end
    end
  end
  self.legend:SetText(table.concat(parts, "    "))
  self.legendBg:SetShown(#parts > 0)
  self.toggle.check:SetShown(TL.db ~= nil and TL.db.settings.showPools == true)

  local showNote = self.dw and note and note ~= ""
  self.note:SetText(showNote and note or "")
  self.note:SetShown(showNote and true or false)
  self.noteBg:SetShown(showNote and true or false)
end

-- The player's arrow, when they are on the map shown.
function MV:OnUpdate(elapsed)
  self.elapsed = (self.elapsed or 0) + elapsed
  if self.elapsed < 0.1 then return end
  self.elapsed = 0
  if not (self.mapID and self.dw) then return end
  local ok, pos = pcall(C_Map.GetPlayerMapPosition, self.mapID, "player")
  local x, y
  if ok and pos then x, y = pos:GetXY() end
  if issecretvalue and (issecretvalue(x) or issecretvalue(y)) then x = nil end
  if not (x and y) or x <= 0 or y <= 0 or x >= 1 or y >= 1 then
    self.player:Hide()
    return
  end
  self.player:ClearAllPoints()
  self.player:SetPoint("CENTER", self.art, "TOPLEFT", self.ox + x * self.dw, -(self.oy + y * self.dh))
  local facing = GetPlayerFacing and GetPlayerFacing()
  if facing and not (issecretvalue and issecretvalue(facing)) then self.player:SetRotation(facing) end
  self.player:Show()
end
