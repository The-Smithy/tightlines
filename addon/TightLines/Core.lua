-------------------------------------------------------------------------------
--  TightLines: core (namespace, palette, saved variables, helpers, events,
--  fishing skill, catch log, slash commands)
-------------------------------------------------------------------------------
local ADDON, TL = ...
_G.TightLines = TL

TL.name = ADDON
TL.CALLER = "TightLines"
TL.LOGO = "|cff3fc7ebTight|r|cffffd100Lines|r"
local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
TL.version = (GetMeta and GetMeta(ADDON, "Version")) or "0.1.0"

-------------------------------------------------------------------------------
--  Palette: deep water blues with the game's gold. When EllesmereUI skins the
--  window its accent color replaces the water blue (TL.Accent).
-------------------------------------------------------------------------------
TL.C = {
  gold   = { 1, 0.82, 0 },
  water  = { 0.25, 0.78, 0.92 },
  text   = { 0.93, 0.93, 0.93 },
  dim    = { 0.6, 0.63, 0.68 },
  faint  = { 0.42, 0.44, 0.48 },
  bg     = { 0.035, 0.045, 0.06, 0.97 },
  panel  = { 0.065, 0.08, 0.105, 0.94 },
  border = { 0.17, 0.2, 0.25, 1 },
  red    = { 1, 0.33, 0.33 },
  yellow = { 1, 0.82, 0.1 },
  green  = { 0.35, 1, 0.45 },
  gray   = { 0.55, 0.55, 0.55 },
}
TL.STATE_COLORS = { red = TL.C.red, yellow = TL.C.yellow, green = TL.C.green, none = TL.C.text, unknown = TL.C.gray }
TL.STATE_TEXT = {
  red = "Skill too low", yellow = "Some get away", green = "Mastered",
  none = "No Fishing skill", unknown = "Skill unknown",
}

function TL.Hex(r, g, b)
  if type(r) == "table" then r, g, b = r[1], r[2], r[3] end
  return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

function TL.Accent()
  local S = TL.skin
  if S and S.GetAccentColor then
    local ok, r, g, b = pcall(S.GetAccentColor)
    if ok and r then return r, g, b end
  end
  return TL.C.water[1], TL.C.water[2], TL.C.water[3]
end

function TL.AccentHex() return TL.Hex(TL.Accent()) end

-- A colored dot as inline text (the game fonts have no round glyph).
local DOT = "|TInterface\\CHARACTERFRAME\\TempPortraitAlphaMask:%d:%d:0:0:64:64:0:64:0:64:%d:%d:%d|t"
function TL.Dot(c, size)
  size = size or 9
  return DOT:format(size, size, math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
end

function TL:Print(msg)
  local f = DEFAULT_CHAT_FRAME or ChatFrame1
  if f then f:AddMessage(TL.LOGO .. ": " .. tostring(msg)) end
end

-------------------------------------------------------------------------------
--  A tiny message bus between the files
-------------------------------------------------------------------------------
local listeners = {}
function TL:On(msg, fn)
  listeners[msg] = listeners[msg] or {}
  table.insert(listeners[msg], fn)
end

-- An error inside TightLines: kept in the journal (so it can be fixed from the
-- log), then handed to the game's error handler as usual.
function TL.Error(err)
  if TL.Journal and TL.Journal.LogError then pcall(TL.Journal.LogError, err) end
  geterrorhandler()(err)
end

function TL:Fire(msg, ...)
  for _, fn in ipairs(listeners[msg] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then TL.Error(err) end
  end
end

-------------------------------------------------------------------------------
--  Money, items, maps
-------------------------------------------------------------------------------
local GOLD, SILVER, COPPER = "|cffffd100g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"

-- short: drop copper once there is gold, and silver past 100 gold.
-- plain: no colors (for grayed-out prices).
function TL.Money(copper, short, plain)
  if not copper then return "|cff666666-|r" end
  copper = math.floor(copper + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local G, S, C = GOLD, SILVER, COPPER
  if plain then G, S, C = "g", "s", "c" end
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. G end
  if s > 0 and not (short and g >= 100) then parts[#parts + 1] = s .. S end
  if c > 0 and not (short and g > 0) then parts[#parts + 1] = c .. C end
  if #parts == 0 then parts[1] = "0" .. C end
  return table.concat(parts, " ")
end

local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- The item's name and quality. gameOnly: only the client's own name (for
-- exact Auction House searches), nil while the client is still loading it.
function TL.ItemName(id, gameOnly)
  if not id then return nil end
  local name, _, quality = GetInfo(id)
  if name then return name, quality end
  if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  if gameOnly then return nil end
  local known = TL.Data and TL.Data.NAMES[id]
  if known then return known end
  local lib = _G.LibForeverData
  if type(lib) == "table" and lib.Name then
    local ok, n = pcall(lib.Name, "item", id)
    if ok and n then return n end
  end
  return "Item #" .. id
end

function TL.ItemIcon(id)
  local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)) or (GetItemIcon and GetItemIcon(id))
  return icon or 134400
end

function TL.ItemLink(id)
  local _, link = GetInfo(id)
  return link
end

function TL.QualityColor(q)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if c then return { c.r, c.g, c.b } end
  return TL.C.text
end

local mapNames = {}
function TL.MapName(id)
  if not id then return "Unknown" end
  local n = mapNames[id]
  if n then return n end
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
  n = (info and info.name) or (TL.Data and TL.Data.ZONE_NAMES[id]) or ("Map " .. id)
  mapNames[id] = n
  return n
end

function TL.MapInfo(id)
  return id and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id) or nil
end

-- The zone the player is in (climbs out of micro maps such as caves).
function TL.PlayerZone()
  local id = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local guard = 0
  while id and guard < 6 do
    local info = C_Map.GetMapInfo(id)
    if not info or not info.mapType or info.mapType <= 4 then return id end
    if not info.parentMapID or info.parentMapID == 0 then return id end
    id = info.parentMapID
    guard = guard + 1
  end
  return id
end

-------------------------------------------------------------------------------
--  Fishing skill
-------------------------------------------------------------------------------
local function FishingName()
  return (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(7620))
    or (GetSpellInfo and GetSpellInfo(7620)) or "Fishing"
end

function TL:UpdateSkill()
  local rank, maxRank, mod
  if GetProfessions and GetProfessionInfo then
    local ok, _, _, _, fishing = pcall(GetProfessions)
    if ok and fishing then
      local _, _, r, m, _, _, _, modifier = GetProfessionInfo(fishing)
      rank, maxRank, mod = r, m, modifier
    end
  end
  if not rank and GetNumSkillLines and GetSkillLineInfo then
    local want = FishingName()
    for i = 1, GetNumSkillLines() do
      local name, isHeader, _, r, _, modifier, m = GetSkillLineInfo(i)
      if not isHeader and name == want then
        rank, maxRank, mod = r, m, modifier
        break
      end
    end
  end
  local old = TL.skill
  TL.skill = rank and { rank = rank, max = maxRank or 0, mod = mod or 0 } or nil
  if not old or not TL.skill or old.rank ~= TL.skill.rank or old.mod ~= TL.skill.mod or old.max ~= TL.skill.max then
    TL:Fire("SKILL", old, TL.skill)
  end
end

TL.FishingName = FishingName

-- Rank plus lures and gear, or nil without Fishing.
function TL.EffectiveSkill()
  local s = TL.skill
  return s and (s.rank + (s.mod or 0)) or nil
end

-- A zone's fishing: the skill fish start biting at (at least 1) and the skill
-- where none get away any more (95 above the zone's base). nil: not known.
function TL.ZoneSkill(mapID)
  local base = mapID and TL.Data.ZONE_SKILL[mapID]
  if base == nil then
    -- Not in the guide: the skill your own logs measured (creel, Generated.lua)
    local g = TL.Generated and TL.Generated.zones and TL.Generated.zones[mapID]
    if g and g.need and g.need > 1 then return g.need, g.need + TL.Data.NO_GETAWAY end
    return nil
  end
  return math.max(1, base), base + TL.Data.NO_GETAWAY
end

function TL.StateFor(low, high)
  if not low then return "unknown" end
  local s = TL.EffectiveSkill()
  if not s then return "none" end
  if s < low then return "red" end
  if s < high then return "yellow" end
  return "green"
end

function TL.ZoneState(mapID)
  local low, high = TL.ZoneSkill(mapID)
  return TL.StateFor(low, high), low, high
end

-------------------------------------------------------------------------------
--  Saved variables
-------------------------------------------------------------------------------
local DEFAULTS = {
  minimap = { angle = 215, hide = false },
  settings = { worldMapPins = true, tooltip = true, logCatches = true, hints = true },
  catches = {},
  -- The event journal (Journal.lua): raw fishing events for the creel analyzer
  journal = { v = 1, seq = 0, events = {}, chars = {}, names = { i = {}, m = {}, o = {} } },
  -- Each character's fishing trips, by "Name-Realm"
  chars = {},
  scale = 1,
}

local function Merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      Merge(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
local itemsPending, skillPending = false, false

ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 ~= ADDON then return end
    TightLinesDB = TightLinesDB or {}
    Merge(TightLinesDB, DEFAULTS)
    TL.db = TightLinesDB
    ev:UnregisterEvent("ADDON_LOADED")
  elseif event == "PLAYER_LOGIN" then
    TL:UpdateSkill()
    TL:Fire("LOGIN")
  elseif event == "SKILL_LINES_CHANGED" or (event == "UNIT_INVENTORY_CHANGED" and arg1 == "player") then
    if skillPending then return end
    skillPending = true
    C_Timer.After(0.25, function() skillPending = false; TL:UpdateSkill() end)
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if itemsPending then return end
    itemsPending = true
    C_Timer.After(0.4, function() itemsPending = false; TL:Fire("ITEMS") end)
  elseif event == "ZONE_CHANGED_NEW_AREA" then
    TL:Fire("ZONE")
  end
end)

for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "SKILL_LINES_CHANGED", "UNIT_INVENTORY_CHANGED",
  "GET_ITEM_INFO_RECEIVED", "ZONE_CHANGED_NEW_AREA" }) do
  ev:RegisterEvent(e)
end

-------------------------------------------------------------------------------
--  Slash commands
-------------------------------------------------------------------------------
local HELP = {
  "|cffffd100/tl|r  open or close the guide",
  "|cffffd100/tl <fish name>|r  look a fish up",
  "|cffffd100/tl zone|r  the zone you are in",
  "|cffffd100/tl quests|r, |cffffd100gear|r, |cffffd100trainers|r, |cffffd100trips|r  open that page",
  "|cffffd100/tl clear|r  stop tracking on the world map",
  "|cffffd100/tl scan|r  put every fish on an Auctionator shopping list",
  "|cffffd100/tl minimap|r  show or hide the minimap button",
  "|cffffd100/tl scale <0.6-1.5>|r, |cffffd100/tl reset|r  window size and position",
}

function TL.PrintHelp()
  TL:Print("commands")
  for _, line in ipairs(HELP) do TL:Print(line) end
end

SLASH_TIGHTLINES1 = "/tl"
SLASH_TIGHTLINES2 = "/tightlines"
SlashCmdList.TIGHTLINES = function(msg)
  msg = strtrim(msg or "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if cmd == "" then
    TL.UI:Toggle()
  elseif cmd == "help" or cmd == "?" then
    TL.PrintHelp()
  elseif cmd == "zone" or cmd == "here" then
    TL.UI:Open("zones", TL.PlayerZone())
  elseif cmd == "fish" or cmd == "zones" or cmd == "quests" or cmd == "gear" or cmd == "trainers" or cmd == "trips" then
    TL.UI:Open(cmd)
  elseif cmd == "log" or cmd == "trip" then
    TL.UI:Open("trips")
  elseif cmd == "clear" or cmd == "untrack" then
    TL.WorldMap.SetTrack(nil)
    TL:Print("Stopped tracking.")
  elseif cmd == "scan" then
    TL.Prices.SendAllFish()
  elseif cmd == "minimap" then
    TL.db.minimap.hide = not TL.db.minimap.hide
    TL:Fire("MINIMAP")
  elseif cmd == "scale" then
    local n = tonumber(rest)
    if n then
      TL.db.scale = math.min(1.5, math.max(0.6, n))
      if TL.UI.frame then TL.UI.frame:SetScale(TL.db.scale) end
    end
  elseif cmd == "reset" then
    TL.db.pos, TL.db.scale = nil, 1
    if TL.UI.frame then
      TL.UI.frame:SetScale(1)
      TL.UI.frame:ClearAllPoints()
      TL.UI.frame:SetPoint("CENTER")
    end
  else
    TL.UI:Open("fish", nil, msg)
  end
end
