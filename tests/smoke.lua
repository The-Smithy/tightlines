-- TightLines smoke test: simulates fishing sessions, exercises every tab,
-- then writes TightLinesDB the way the game writes SavedVariables.
--   luajit smoke2.lua <AddOns dir> <SavedVariables out> [Generated.lua to load] [previous SavedVariables to load]
local ADDONS, OUT, GENERATED, PREVIOUS = arg[1], arg[2], arg[3], arg[4]
if GENERATED == "-" then GENERATED = nil end

local errors = {}
local function fail(msg) errors[#errors + 1] = tostring(msg); print("ERROR: " .. tostring(msg)) end

-- Clock the test controls
local clock = 1794000000
time = function() return clock end
date = os.date
function GetTime() return clock end

-- Mock frames ----------------------------------------------------------------
local frames = {}
local NUMBERS = { GetStringWidth = 60, GetWidth = 200, GetHeight = 300, GetFrameLevel = 5, GetEffectiveScale = 1,
  GetScale = 1, GetStringHeight = 14, GetCanvasScale = 0.5, GetMapID = 1444, GetAlpha = 1 }
local Mock = {}
local function NewMock(kind)
  local o = { __kind = kind, __scripts = {}, __shown = true, __events = {} }
  frames[#frames + 1] = o
  return setmetatable(o, Mock)
end
Mock.__index = function(t, k)
  if type(k) ~= "string" then return nil end
  if k:sub(1, 6) == "Create" then return function() return NewMock(k) end end
  if NUMBERS[k] then return function() return NUMBERS[k] end end
  if k == "SetText" or k == "SetLabel" then return function(self, v) rawset(self, "__text", v) local s = self.__scripts.OnTextChanged if s then s(self) end end end
  if k == "GetText" then return function(self) return rawget(self, "__text") or "" end end
  if k == "Show" then return function(self) local was = self.__shown; self.__shown = true; local s = self.__scripts.OnShow; if s and not was then s(self) end end end
  if k == "Hide" then return function(self) self.__shown = false end end
  if k == "SetShown" then return function(self, v) self.__shown = v and true or false end end
  if k == "IsShown" or k == "IsVisible" then return function(self) return self.__shown end end
  if k == "SetScript" or k == "HookScript" then return function(self, name, fn) self.__scripts[name] = fn end end
  if k == "RegisterEvent" then return function(self, e) self.__events[e] = true end end
  if k == "UnregisterEvent" then return function(self, e) self.__events[e] = nil end end
  if k == "GetSize" then return function() return 1002, 668 end end
  if k == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
  if k == "GetCenter" then return function() return 100, 100 end end
  if k == "GetCanvas" then return function(self) rawset(self, "__canvas", rawget(self, "__canvas") or NewMock("canvas")) return self.__canvas end end
  if k == "IsPlaying" or k == "IsForbidden" or k == "HasScript" then return function() return false end end
  if k:match("^[A-Z]") then return function() end end
  return nil
end
function CreateFrame(kind, name) local f = NewMock(kind) if name then _G[name] = f end return f end
UIParent, Minimap, GameTooltip, ItemRefTooltip = NewMock("UIParent"), NewMock("Minimap"), NewMock("GameTooltip"), NewMock("ItemRefTooltip")
WorldMapFrame = NewMock("WorldMapFrame"); WorldMapFrame.ScrollContainer = NewMock("ScrollContainer"); WorldMapFrame.__shown = false
DEFAULT_CHAT_FRAME = { AddMessage = function() end }
UISpecialFrames, SlashCmdList = {}, {}
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
ITEM_QUALITY_COLORS = { [1] = { r = 1, g = 1, b = 1 } }
ERR_FISH_ESCAPED, ERR_FISH_NOT_HOOKED, SPELL_FAILED_FISHING_TOO_LOW = "Your fish got away!", "No fish are hooked.", "Requires Fishing %d"
tinsert = table.insert
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function strsplit(sep, s) local out = {} for part in (s .. sep):gmatch("(.-)%" .. sep) do out[#out + 1] = part end return unpack(out) end
function geterrorhandler() return function(e) fail(e) end end
function IsShiftKeyDown() return true end
function GetCursorPosition() return 0, 0 end
local hour = 20
function GetGameTime() return hour, 15 end
function UnitFactionGroup() return "Alliance" end
function UnitName() return "Fisherchar" end
function UnitClass() return "Hunter", "HUNTER" end
function GetNormalizedRealmName() return "TestRealm" end
function GetSubZoneText() return SUBZONE or "" end
function InCombatLockdown() return false end
function ToggleWorldMap() WorldMapFrame.__shown = true end
local rank, modifier = 230, 75
function GetProfessions() return 1, 2, nil, 9, 10 end
function GetProfessionInfo() return "Fishing", 1, rank, 300, 0, 0, 356, modifier end
C_Timer = { After = function(_, fn) fn() end }
C_QuestLog = { IsQuestFlaggedCompleted = function() return false end }
C_Spell = { GetSpellName = function() return "Fishing" end }
C_AddOns = { GetAddOnMetadata = function() return "0.1.0" end }
local curMap, px, py = 1444, 0.31, 0.43
C_Map = {
  GetMapInfo = function(id)
    if id == 1414 or id == 1415 then return { mapID = id, name = id == 1414 and "Kalimdor" or "Eastern Kingdoms", mapType = 2, parentMapID = 947 } end
    return { mapID = id, name = nil, mapType = 3, parentMapID = 1414 }
  end,
  GetBestMapForUnit = function() return curMap end,
  GetPlayerMapPosition = function() return { GetXY = function() return px, py end } end,
  GetMapArtLayers = function() return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } } end,
  GetMapArtLayerTextures = function() return { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } end,
  GetMapRectOnMap = function() return 0.2, 0.4, 0.3, 0.5 end,
}
local NAMES = { [13758] = "Raw Redgill", [13759] = "Raw Nightfin Snapper", [6358] = "Oily Blackmouth", [13422] = "Stonescale Eel",
  [99001] = "Forever Glimmerfin", [4603] = "Raw Spotted Yellowtail", [13754] = "Raw Glossy Mightfish" }
C_Item = {
  GetItemInfo = function(id) local n = NAMES[id] if n then return n, "|Hitem:" .. id .. "|h[" .. n .. "]|h", 1, 1, 1, "", "", 20, "", 1, 25 end end,
  GetItemIconByID = function(id) return id end, RequestLoadItemDataByID = function() end, GetItemCount = function() return 0 end,
}
Auctionator = { API = { v1 = {
  GetAuctionPriceByItemID = function(_, id) return id * 3 end, GetAuctionAgeByItemID = function() return 1 end,
  GetVendorPriceByItemID = function() return 5 end, RegisterForDBUpdate = function() end,
  ConvertToSearchString = function(_, t) return t.searchString end, CreateShoppingList = function() end, MultiSearchExact = function() end,
} } }

-- Loot the test controls
local loot, lootSource = {}, "GameObject-0-4170-0-41-35591-00001A2B3C"
function IsFishingLoot() return true end
function GetNumLootItems() return #loot end
function GetLootSlotLink(i) return "|Hitem:" .. loot[i][1] .. "::|h[x]|h" end
function GetLootSlotInfo(i) return 1, "x", loot[i][2] end
function GetLootSourceInfo() return lootSource, 1 end

-- The real LibForeverData, when TIGHTLINES_LFD names the game AddOns folder ------
local LFD_DIR = os.getenv("TIGHTLINES_LFD")
if LFD_DIR then
  local lfd = {}
  for _, file in ipairs({ "LuaChunks.lua", "Core.lua", "Data/Quests.lua", "Data/Npcs.lua", "Data/Objects.lua",
    "Data/Items.lua", "Data/Spawns.lua", "Data/Steps.lua" }) do
    assert(loadfile(LFD_DIR .. "/LibForeverData/" .. file))("LibForeverData", lfd)
  end
  for _, id in ipairs(LibForeverData.Ids("item")) do NAMES[id] = NAMES[id] or LibForeverData.Name("item", id) end
  print("LibForeverData " .. LibForeverData.version)
end

-- Load -------------------------------------------------------------------------
if PREVIOUS then
  local chunk = assert(loadfile(PREVIOUS))
  chunk()
  print("loaded previous SavedVariables: journal seq " .. tostring(TightLinesDB.journal.seq))
end
local ns = {}
for _, file in ipairs({ "Core.lua", "Data.lua", "Generated.lua", "Sources.lua", "Prices.lua", "Journal.lua", "MapView.lua",
  "WorldMap.lua", "UI.lua", "Tabs.lua", "Trips.lua", "Integrations.lua" }) do
  local path = ADDONS .. "/TightLines/" .. file
  if file == "Generated.lua" and GENERATED then path = GENERATED end
  local chunk, err = loadfile(path)
  if not chunk then fail(err) else
    local ok, e = pcall(chunk, "TightLines", ns)
    if not ok then fail(file .. ": " .. tostring(e)) end
  end
end
local TL = ns

local function Fire(event, ...)
  for _, f in ipairs(frames) do
    local s = f.__scripts.OnEvent
    if s and f.__events[event] then
      local ok, e = pcall(s, f, event, ...)
      if not ok then fail(event .. ": " .. tostring(e)) end
    end
  end
end
Fire("ADDON_LOADED", "TightLines")
Fire("PLAYER_LOGIN")

-- Fishing ------------------------------------------------------------------------
local function Cast() Fire("UNIT_SPELLCAST_CHANNEL_START", "player", "Cast-1", 7620); clock = clock + 15 end
local function Catch(items, source)
  loot, lootSource = items, source or "GameObject-0-4170-0-41-35591-00001A2B3C"
  Fire("LOOT_READY"); Fire("LOOT_OPENED"); Fire("LOOT_CLOSED")
  clock = clock + 5
end
local function Away() Fire("UI_ERROR_MESSAGE", 50, ERR_FISH_ESCAPED); clock = clock + 5 end

if not PREVIOUS then
  -- Trip 1: Feralas, open water at two spots plus a Stonescale Eel Swarm
  curMap, SUBZONE = 1444, "Verdantis River"
  for i = 1, 30 do
    px, py = 0.31 + (i % 3) * 0.002, 0.43 + (i % 2) * 0.003
    Cast()
    if i % 10 == 0 then Away()
    elseif i % 4 == 0 then Catch({ { 13759, 1 } })
    else Catch({ { 13758, 1 } }) end
    if i == 12 then rank = 231; Fire("SKILL_LINES_CHANGED") end
  end
  SUBZONE = "The Forgotten Coast"
  for i = 1, 8 do
    px, py = 0.452, 0.61
    Cast(); Catch({ { 13422, 2 } }, "GameObject-0-4170-0-41-180712-00001A2B3D")
  end
  for i = 1, 6 do
    px, py = 0.47, 0.64
    Cast(); Catch({ { i % 2 == 0 and 4603 or 13754, 1 } })
  end
  -- An hour later: trip 2, a zone the guide has no skill for, an item it does not know
  clock = clock + 3600
  curMap, SUBZONE, px, py = 2548, "Glimmer Shoals", 0.52, 0.38
  Fire("UI_ERROR_MESSAGE", 50, "Requires Fishing 180")
  for i = 1, 10 do Cast(); Catch({ { 99001, 1 } }) end
  Cast(); Fire("UI_ERROR_MESSAGE", 50, ERR_FISH_NOT_HOOKED)
  TL.Error("test: a deliberate error for the journal")
  errors = {} -- that one was deliberate
  curMap, SUBZONE = 1444, "Verdantis River"
else
  -- Second session: a little more fishing on top of what was saved
  curMap, SUBZONE, px, py = 1444, "Verdantis River", 0.312, 0.431
  clock = clock + 86400
  for i = 1, 5 do Cast(); Catch({ { 13758, 1 } }) end
end

-- The UI, every tab and row ----------------------------------------------------
local ui = TL.UI
local function try(label, fn) local ok, e = pcall(fn) if not ok then fail(label .. ": " .. tostring(e)) end end
try("open", function() ui:Open("trips") end)
for _, tab in ipairs(TL.Tabs.list) do
  try("tab " .. tab.key, function() ui:SelectTab(tab.key) end)
  local n, points = 0, 0
  for _, row in ipairs(ui.rowsData) do
    if not row.header then
      n = n + 1
      try(tab.key .. " " .. tostring(row.key), function()
        ui:Select(row.key, true)
        points = points + ui.mapView.used
        for _, chip in ipairs((ui.spec and ui.spec.chips) or {}) do
          if chip.mapID then ui:ChooseMap(chip.mapID) end
        end
      end)
    end
  end
  print(("tab %-9s rows %3d  map points %5d"):format(tab.key, n, points))
end
try("slash", function() SlashCmdList.TIGHTLINES("trips") SlashCmdList.TIGHTLINES("log") end)

local db = TightLinesDB
local char = db.chars["Fisherchar-TestRealm"]
print("journal: seq " .. db.journal.seq .. ", events kept " .. #db.journal.events .. ", id " .. tostring(db.journal.id))
print("trips: " .. #char.trips .. ", totals casts " .. char.totals.casts .. " catches " .. char.totals.catches .. " away " .. char.totals.away)
for _, t in ipairs(char.trips) do
  local zones = {} for m, n in pairs(t.zones) do zones[#zones + 1] = m .. "x" .. n end
  print(("  trip %d: casts %d catches %d away %d zones %s skill %s->%s open %s"):format(t.id, t.casts, t.catches, t.away,
    table.concat(zones, ","), tostring(t.skill0), tostring(t.skill1), tostring(t.open)))
end
print("first event: " .. tostring(db.journal.events[1]))
if TL.Generated and TL.Generated.built > 0 then
  TL.index = nil
  local idx = TL:Index()
  local low, high = TL.ZoneSkill(2548)
  print("generated: built " .. TL.Generated.built .. ", Riverglades skill " .. tostring(low) .. "-" .. tostring(high)
    .. ", discovered fish " .. tostring(TL.Data.FISH_BY_ID[99001] and TL.Data.FISH_BY_ID[99001].name)
    .. ", redgill points in Feralas " .. #TL.FishPoints(TL.Data.FISH_BY_ID[13758], 1444))
end

-- With a Generated.lua from creel: what it must have changed in the addon
if PREVIOUS and TL.Generated and TL.Generated.built > 0 then
  local upTo = TL.Generated.ingested[db.journal.id]
  local first = tonumber((db.journal.events[1] or ""):match("^s=(%d+)"))
  if not (upTo and first and first > upTo) then fail("stored events were not dropped from the journal") end
  if not TL.Data.FISH_BY_ID[99001] then fail("the catch creel discovered is missing from the guide") end
  if TL.ZoneSkill(2548) ~= 180 then fail("the zone skill creel measured is missing") end
  if #TL.FishPoints(TL.Data.FISH_BY_ID[13758], 1444) == 0 then fail("no logged spots for Raw Redgill in Feralas") end
end

-- SavedVariables, as the game writes them ------------------------------------------
local function Ser(v, indent, out)
  local t = type(v)
  if t == "table" then
    out[#out + 1] = "{\n"
    local n = #v
    for i = 1, n do
      out[#out + 1] = indent .. "\t"
      Ser(v[i], indent .. "\t", out)
      out[#out + 1] = ", -- [" .. i .. "]\n"
    end
    local keys = {}
    for k in pairs(v) do
      if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      out[#out + 1] = indent .. "\t[" .. (type(k) == "number" and tostring(k) or string.format("%q", k)) .. "] = "
      Ser(v[k], indent .. "\t", out)
      out[#out + 1] = ",\n"
    end
    out[#out + 1] = indent .. "}"
  elseif t == "string" then
    out[#out + 1] = string.format("%q", v):gsub("\\\n", "\\n")
  else
    out[#out + 1] = tostring(v)
  end
end
local out = { "\nTightLinesDB = " }
Ser(TightLinesDB, "", out)
out[#out + 1] = "\n"
local f = assert(io.open(OUT, "wb"))
f:write(table.concat(out))
f:close()
print("wrote " .. OUT)
print(#errors == 0 and "SMOKE TEST PASSED" or ("SMOKE TEST FAILED: " .. #errors))
os.exit(#errors == 0 and 0 or 1)
