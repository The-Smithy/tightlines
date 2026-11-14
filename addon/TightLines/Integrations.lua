-------------------------------------------------------------------------------
--  TightLines: the edges. EllesmereUI (skin and a settings page), the minimap
--  button, the addon compartment and item tooltips.
-------------------------------------------------------------------------------
local _, TL = ...

-------------------------------------------------------------------------------
--  EllesmereUI skin: its public RegisterSkin API (SKINNING_API.md). EUI calls
--  back at login when third-party skinning is on for TightLines, and hands us
--  the facade; without EllesmereUI the window keeps its own look.
-------------------------------------------------------------------------------
if EllesmereUI and EllesmereUI.RegisterSkin then
  EllesmereUI.RegisterSkin("TightLines", function(S)
    TL.skin = S
    if TL.UI.frame then TL.UI:ApplySkin() end
    if S.OnLooksChanged then
      S.OnLooksChanged(function()
        if TL.UI.frame then
          TL.UI.RefreshFonts()
          TL.UI:ApplyAccent()
        end
      end)
    end
  end)
end

-------------------------------------------------------------------------------
--  Settings. The same switches are on a page of TightLines' own in the
--  EllesmereUI options panel (its public RegisterPlugin API, PLUGINS_API.md).
-------------------------------------------------------------------------------
local SETTINGS = {
  { key = "worldMapPins", label = "Show tracked fish, pools and quests on the world map",
    apply = function() TL.WorldMap.Refresh(true) end },
  { key = "hints", label = "Mark good water for fish that have no pools",
    apply = function() TL:Fire("TRACK") end },
  { key = "showPools", label = "Mark every pool spawn point on the maps",
    apply = function() TL.WorldMap.Refresh(true) TL:Fire("TRACK") end },
  { key = "logCatches", label = "Log what I catch and where" },
  { key = "tooltip", label = "Show where a fish is found in its tooltip" },
}

if EllesmereUI and EllesmereUI.RegisterPlugin then
  EllesmereUI.RegisterPlugin("TightLines", {
    label = "TightLines",
    modules = {
      {
        key = "General",
        title = "TightLines",
        description = "The fishing guide. Open it with /tl or its minimap button.",
        pages = { "General" },
        buildPage = function(_, parent, yOffset)
          local W = EllesmereUI.Widgets
          local y = yOffset
          local _, h
          _, h = W:SectionHeader(parent, "FISHING GUIDE", y); y = y - h
          for _, setting in ipairs(SETTINGS) do
            _, h = W:Toggle(parent, setting.label, y,
              function() return TL.db and TL.db.settings[setting.key] and true or false end,
              function(v)
                if not TL.db then return end
                TL.db.settings[setting.key] = v and true or false
                if setting.apply then setting.apply() end
              end)
            y = y - h
          end
          _, h = W:Toggle(parent, "Show the minimap button", y,
            function() return TL.db and not TL.db.minimap.hide or false end,
            function(v)
              if not TL.db then return end
              TL.db.minimap.hide = not v
              TL:Fire("MINIMAP")
            end)
          y = y - h
          return math.abs(y)
        end,
      },
    },
  })
end

-------------------------------------------------------------------------------
--  Minimap button
-------------------------------------------------------------------------------
local button

local function Place()
  local angle = math.rad(TL.db.minimap.angle or 215)
  local radius = (Minimap:GetWidth() / 2) + 6
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function CreateMinimapButton()
  if button or not Minimap then return end
  button = CreateFrame("Button", "TightLinesMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:RegisterForClicks("AnyUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", 7, -5)
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\Trade_Fishing")
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  icon:SetSize(17, 17)
  icon:SetPoint("TOPLEFT", 7, -6)
  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")

  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      TL.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
      Place()
    end)
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnClick", function(_, mouse)
    if mouse == "RightButton" then
      TL.UI:Open("zones", TL.PlayerZone())
    else
      TL.UI:Toggle()
    end
  end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(TL.LOGO)
    local s = TL.skill
    if s then
      GameTooltip:AddLine(("Fishing %d%s / %d"):format(s.rank, s.mod > 0 and (" +" .. s.mod) or "", s.max), 1, 1, 1)
    end
    local zone = TL.PlayerZone()
    local state, low, high = TL.ZoneState(zone)
    if low then
      local c = TL.STATE_COLORS[state]
      GameTooltip:AddLine(("%s: Fishing %d-%d"):format(TL.MapName(zone), low, high), c[1], c[2], c[3])
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: open the guide", 0.7, 0.72, 0.76)
    GameTooltip:AddLine("Right-click: fishing in this zone", 0.7, 0.72, 0.76)
    GameTooltip:AddLine("Drag: move this button", 0.7, 0.72, 0.76)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  Place()
end

local function UpdateMinimapButton()
  if not TL.db then return end
  if TL.db.minimap.hide then
    if button then button:Hide() end
  else
    CreateMinimapButton()
    if button then button:Show() end
  end
end

TL:On("LOGIN", UpdateMinimapButton)
TL:On("MINIMAP", UpdateMinimapButton)

-- The addon compartment (## AddonCompartmentFunc in the TOC)
function TightLines_OnAddonCompartmentClick()
  TL.UI:Toggle()
end

-------------------------------------------------------------------------------
--  Item tooltips: where a fish is found and the skill it takes. (Auctionator
--  already adds its price to tooltips, so we don't repeat it.)
-------------------------------------------------------------------------------
local function AddFishLines(tooltip, id)
  if not (TL.db and TL.db.settings.tooltip) then return end
  local fish = TL.Data.FISH_BY_ID[id]
  if not fish then return end
  TL:Index()
  local zones = fish.zoneList
  if #zones == 0 then return end
  local names = {}
  for i = 1, math.min(3, #zones) do names[i] = TL.MapName(zones[i]) end
  local text = table.concat(names, ", ") .. (#zones > 3 and (" +" .. (#zones - 3) .. " more") or "")
  tooltip:AddLine(TL.LOGO .. "  |cffd0d2d6" .. text .. "|r", 1, 1, 1, true)
  if fish.req then
    local skill = TL.EffectiveSkill()
    local c = TL.C.text
    if skill then c = skill >= fish.req and TL.C.green or TL.C.red end
    tooltip:AddLine("Fishing " .. fish.req .. (skill and ("  (you: " .. skill .. ")") or ""), c[1], c[2], c[3])
  end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    if not data then return end
    local id = data.id
    if issecretvalue and issecretvalue(id) then return end
    if type(id) == "number" then pcall(AddFishLines, tooltip, id) end
  end)
elseif GameTooltip and GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetItem") then
  GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
    local _, link = tooltip:GetItem()
    local id = link and tonumber(link:match("item:(%d+)"))
    if id then pcall(AddFishLines, tooltip, id) end
  end)
end
