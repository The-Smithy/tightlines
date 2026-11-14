-------------------------------------------------------------------------------
--  TightLines: what each tab lists and shows. A tab is
--    { key, label, placeholder, rows(query, filterOn), select(key), default() }
--  rows returns list entries: { key, icon, text, color, sub, right, rightSub,
--  itemID, tip } or { header = true, text, count }.
--  select returns the detail page: { icon, itemID, title, titleColor, sub,
--  info = { lines }, chipLabel, chips, map, maps, points(mapID), actions }.
-------------------------------------------------------------------------------
local _, TL = ...
local D, S, C = TL.Data, TL.Sources, TL.C
local Tabs = { list = {}, byKey = {} }
TL.Tabs = Tabs

local function Add(tab)
  Tabs.list[#Tabs.list + 1] = tab
  Tabs.byKey[tab.key] = tab
end

local function Match(text, query)
  return query == "" or (text ~= nil and text:lower():find(query, 1, true) ~= nil)
end

local LABEL = "|cff9aa0a8"   -- field labels in the detail text
local MUTED = "|cff7c8088"
local FISHING_ICON = "Interface\\Icons\\Trade_Fishing"

local function StateHex(state)
  return TL.Hex(TL.STATE_COLORS[state] or C.text)
end

local function Set(list)
  local set = {}
  for _, v in ipairs(list) do set[v] = true end
  return set
end

local function TrackAction(kind, id, mapID)
  if TL.WorldMap.IsTracking(kind, id) then
    return { text = "Stop tracking", tip = "Remove these pins from your world map.",
      onClick = function() TL.WorldMap.SetTrack(nil) end }
  end
  return { text = "Show on map", tip = "Pin this on your world map and open it. The pins stay until you stop tracking.",
    onClick = function() TL.WorldMap.ShowOnMap(kind, id, TL.UI.mapShown or mapID) end }
end

local function LinkAction(itemID)
  return { text = "Link", tip = "Put a link to this item in chat.", onClick = function()
    local link = TL.ItemLink(itemID)
    if not link then return end
    if not (ChatEdit_InsertLink and ChatEdit_InsertLink(link)) and ChatFrame_OpenChat then
      ChatFrame_OpenChat(link)
    end
  end }
end

local function SearchAction(ids)
  return { text = "Search AH", tip = "With the Auction House open: search it with Auctionator. Otherwise: save it to the \"TightLines\" shopping list.",
    onClick = function() TL.Prices.Search(ids) end }
end

-- "Auction House: 1g 20s (seen today)   Vendor: 6c"
local function PriceLine(id)
  local ah, age = TL.Prices.AH(id)
  local vendor = TL.Prices.Vendor(id)
  local line
  if ah then
    line = LABEL .. "Auction House:|r " .. TL.Money(ah) .. "  " .. MUTED .. "(" .. TL.Prices.AgeText(age) .. ")|r"
  elseif TL.Prices.Available() then
    line = LABEL .. "Auction House:|r " .. MUTED .. "not seen yet: search it at the Auction House with Auctionator|r"
  else
    line = LABEL .. "Auction House:|r " .. MUTED .. "Auctionator isn't loaded|r"
  end
  if vendor then line = line .. "     " .. LABEL .. "Vendor:|r " .. TL.Money(vendor) end
  return line
end

-- The short price for a list row: AH, else the vendor price grayed.
local function RowPrice(id)
  local ah = TL.Prices.AH(id)
  if ah then return TL.Money(ah, true) end
  local vendor = TL.Prices.Vendor(id)
  if vendor then return "|cff777777" .. TL.Money(vendor, true, true) .. "|r" end
  return "|cff555555-|r"
end

local function ServerHour()
  local hour = GetGameTime and GetGameTime()
  return type(hour) == "number" and hour or tonumber(date("%H"))
end

local function Month()
  local now = C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime and C_DateAndTime.GetCurrentCalendarTime()
  return (now and now.month) or tonumber(date("%m"))
end

-- Whether a fish with a time of day or a season bites right now.
local function BitesNow(fish)
  if fish.time then
    local hour = ServerHour()
    local night = hour < 6 or hour >= 18
    if (fish.time == "night") ~= night then return false end
  end
  if fish.season then
    local month = Month()
    local summer = month >= 4 and month <= 9
    if (fish.season == "summer") ~= summer then return false end
  end
  return true
end

local WATER = { inland = "Inland water", coastal = "Coastal water", pool = "Pools only" }

local function FishTraits(fish)
  local parts = { WATER[fish.water] or "Any water" }
  if fish.time == "night" then parts[#parts + 1] = "Night" end
  if fish.time == "day" then parts[#parts + 1] = "Day" end
  if fish.season == "summer" then parts[#parts + 1] = "Summer" end
  if fish.season == "winter" then parts[#parts + 1] = "Winter" end
  return table.concat(parts, ", ")
end

-------------------------------------------------------------------------------
--  Fish
-------------------------------------------------------------------------------
local CAT_ORDER = { fish = 1, reagent = 2, event = 3, quest = 4, treasure = 5, new = 6 }
local CAT_LABEL = {
  fish = "Cooking & trade fish", reagent = "Reagents", event = "Rare & event fish",
  quest = "Quest fish", treasure = "Treasure & bloated fish", new = "Other catches from your logs",
}

-- The kinds, in order, and their short names for the zone pages' filter
local CAT_LIST = { "fish", "reagent", "event", "quest", "treasure", "new" }
local CAT_SHORT = { fish = "Fish", reagent = "Reagents", event = "Rare", quest = "Quest", treasure = "Treasure", new = "Other" }

local function FishRows(query, catchable, sort)
  local idx = TL:Index()
  local skill = TL.EffectiveSkill()
  local here = idx.byZone[TL.PlayerZone() or -1] or {}
  local list = {}
  for _, fish in ipairs(D.FISH) do
    local ok = Match((TL.ItemName(fish.id)), query)
    if not ok then
      for _, z in ipairs(fish.zoneList) do
        if Match(TL.MapName(z), query) then ok = true break end
      end
    end
    if ok and catchable then
      ok = fish.req ~= nil and (skill or 0) >= fish.req and BitesNow(fish)
    end
    if ok then list[#list + 1] = fish end
  end
  -- By type: grouped under headings, easiest first. By anything else: one
  -- flat list, with what has no value for that sort at the end either way.
  local key, desc = (sort and sort.key) or "type", sort and sort.desc
  local grouped = key == "type"
  if grouped then
    table.sort(list, function(a, b)
      if a.cat ~= b.cat then return (CAT_ORDER[a.cat] or 9) < (CAT_ORDER[b.cat] or 9) end
      if (a.req or 999) ~= (b.req or 999) then return (a.req or 999) < (b.req or 999) end
      return a.name < b.name
    end)
  else
    local value = {}
    for _, fish in ipairs(list) do
      if key == "price" then
        value[fish] = TL.Prices.AH(fish.id) or TL.Prices.Vendor(fish.id)
      elseif key == "skill" then
        value[fish] = fish.req
      elseif key == "zones" then
        value[fish] = #fish.zoneList
      else
        value[fish] = (TL.ItemName(fish.id)):lower()
      end
    end
    table.sort(list, function(a, b)
      local va, vb = value[a], value[b]
      if va ~= vb then
        if va == nil then return false end
        if vb == nil then return true end
        if desc then return va > vb end
        return va < vb
      end
      return a.name < b.name
    end)
  end

  local rows, cat, header = {}, nil, nil
  local accent = TL.AccentHex()
  for _, fish in ipairs(list) do
    if grouped then
      if fish.cat ~= cat then
        cat = fish.cat
        header = { header = true, text = CAT_LABEL[cat] or cat, n = 0 }
        rows[#rows + 1] = header
      end
      header.n = header.n + 1
      header.count = tostring(header.n)
    end
    local name, quality = TL.ItemName(fish.id)
    local zones = #fish.zoneList
    local sub = FishTraits(fish) .. (zones > 0 and (", " .. zones .. (zones == 1 and " zone" or " zones")) or "")
    if here[fish.id] then sub = accent .. "Here|r  " .. sub end
    local rightSub
    if not fish.req then
      rightSub = MUTED .. "skill ?|r"
    elseif not skill then
      rightSub = "Fishing " .. fish.req
    elseif skill < fish.req then
      rightSub = StateHex("red") .. "need " .. fish.req .. "|r"
    elseif not BitesNow(fish) then
      rightSub = StateHex("yellow") .. "not now|r"
    else
      rightSub = StateHex("green") .. "Fishing " .. fish.req .. "|r"
    end
    rows[#rows + 1] = {
      key = fish.id, itemID = fish.id, icon = TL.ItemIcon(fish.id), text = name,
      color = TL.QualityColor(quality), sub = sub, right = RowPrice(fish.id), rightSub = rightSub,
    }
  end
  return rows
end

local function ZoneChips(zones)
  local chips = {}
  for _, z in ipairs(zones) do
    local state, low, high = TL.ZoneState(z)
    local name = TL.MapName(z)
    chips[#chips + 1] = {
      text = name .. (low and ("  " .. low) or ""), plain = name, mapID = z,
      color = TL.STATE_COLORS[state],
      tip = {
        low and ("Fish bite from Fishing " .. low .. "; none get away from " .. high .. ".") or "Fishing skill for this zone isn't known yet.",
        TL.STATE_TEXT[state] or "", "Click to show this zone on the map below.",
      },
    }
  end
  return chips
end

local function FishDetail(id)
  local fish = D.FISH_BY_ID[id]
  if not fish then return nil end
  TL:Index()
  local name, quality = TL.ItemName(id)
  local skill = TL.EffectiveSkill()
  local info = { PriceLine(id) }

  if fish.cooked then
    local cookedName = TL.ItemName(fish.cooked)
    local raw, cooked = TL.Prices.AH(id), TL.Prices.AH(fish.cooked)
    local line = LABEL .. "Cooks into:|r " .. cookedName
    if cooked then
      line = line .. "  " .. TL.Money(cooked)
      if raw then
        line = line .. (cooked > raw and "  |cff59ff73worth cooking|r" or "  |cffffd100sells better raw|r")
      end
    end
    info[#info + 1] = line
  end

  if fish.req then
    local line = LABEL .. "Fishing needed:|r " .. fish.req .. " in the easiest zone"
    if skill then
      line = line .. (skill >= fish.req and ("  |cff59ff73you have " .. skill .. "|r") or ("  |cffff5555you have " .. skill .. "|r"))
    end
    info[#info + 1] = line
  elseif #fish.zoneList == 0 then
    info[#info + 1] = MUTED .. (S.HasSpawnData() and "No known location yet: catch one and the guide learns where."
      or "Install LibForeverData or QuestieDB to see where its pools spawn.") .. "|r"
  end

  local g = TL.Generated and TL.Generated.fish and TL.Generated.fish[id]
  if g and (g.n or 0) > 0 then
    local best, share
    for map, z in pairs(g.zones or {}) do
      if z.share and (not share or z.share > share) then best, share = map, z.share end
    end
    info[#info + 1] = LABEL .. "Your logs:|r " .. g.n .. " caught"
      .. (best and (", " .. share .. "% of open-water catches in " .. TL.MapName(best)) or "")
  end

  if fish.time or fish.season then
    local parts = {}
    if fish.time then
      parts[#parts + 1] = fish.time == "night" and "bites from 18:00 to 06:00 server time" or "bites from 06:00 to 18:00 server time"
    end
    if fish.season then
      parts[#parts + 1] = fish.season == "summer" and "summer months only" or "winter months only"
    end
    local text = table.concat(parts, ", ")
    info[#info + 1] = LABEL .. "When:|r " .. text:sub(1, 1):upper() .. text:sub(2)
      .. (BitesNow(fish) and "  |cff59ff73biting now|r" or "  |cffff5555not biting now|r")
  end

  local poolNames, seen = {}, {}
  for p in pairs(fish.poolSet or {}) do
    local pool = D.POOLS[p]
    if pool and not seen[pool.name] then
      seen[pool.name] = true
      poolNames[#poolNames + 1] = pool.name
    end
  end
  if #poolNames > 0 then
    table.sort(poolNames)
    info[#info + 1] = LABEL .. "Pools:|r " .. table.concat(poolNames, ", ")
  end
  if fish.note then info[#info + 1] = "|cffd0d2d6" .. fish.note .. "|r" end

  -- The map to open on: where you are, else the best zone for your skill
  local map
  local here = TL.PlayerZone()
  if here and fish.zoneSet[here] then
    map = here
  else
    for _, z in ipairs(fish.zoneList) do
      local state = TL.ZoneState(z)
      if state == "green" or state == "yellow" then map = z end
    end
    map = map or fish.zoneList[1]
  end

  local searchIDs = { id }
  if fish.cooked then searchIDs[2] = fish.cooked end
  return {
    icon = TL.ItemIcon(id), itemID = id, title = name, titleColor = TL.QualityColor(quality),
    sub = (CAT_LABEL[fish.cat] or "") .. "  |  " .. FishTraits(fish),
    info = info, chipLabel = "Found in", chips = ZoneChips(fish.zoneList),
    map = map, maps = fish.zoneSet,
    noMapText = "No known location for this one yet.",
    points = function(mapID)
      local points, pools = TL.FishPoints(fish, mapID)
      local note
      if #points == 0 then
        note = "No pool data here. Cast into any " .. (fish.water == "inland" and "lake or river" or "coastal water")
          .. ": your catches will mark the map."
      elseif pools == 0 and fish.water ~= "pool" then
        note = "Bites in any " .. (fish.water == "inland" and "lake or river" or "coastal water") .. " in this zone."
      end
      return points, note
    end,
    actions = { TrackAction("fish", id, map), SearchAction(searchIDs), LinkAction(id) },
  }
end

Add({
  key = "fish", label = "Fish", placeholder = "Search a fish or a zone",
  filterLabel = "Catchable", filterTip = "Only fish your Fishing skill can catch right now (time of day and season included).",
  sorts = {
    { key = "type", label = "Type", fixed = true, tip = "Grouped by kind, the easiest to catch first." },
    { key = "name", label = "Name", tip = "Alphabetical." },
    { key = "skill", label = "Skill", tip = "The Fishing skill needed in the easiest zone." },
    { key = "price", label = "Price", desc = true, tip = "The Auction House price, or the vendor price when there is none." },
  },
  emptyText = "No fish match. Clear the search or turn off Catchable.",
  rows = FishRows, select = FishDetail,
  default = function()
    local idx = TL:Index()
    local here = idx.byZone[TL.PlayerZone() or -1]
    if not here then return nil end
    local best, bestValue
    for id in pairs(here) do
      local fish = D.FISH_BY_ID[id]
      if fish and fish.cat == "fish" then
        local value = TL.Prices.Value(id)
        if not bestValue or value > bestValue then best, bestValue = id, value end
      end
    end
    return best
  end,
})

-------------------------------------------------------------------------------
--  Zones
-------------------------------------------------------------------------------
local CONTINENT_ORDER = { [1415] = 1, [1414] = 2 }

local function Continent(mapID)
  local info = TL.MapInfo(mapID)
  local guard = 0
  while info and info.mapType and info.mapType > 2 and info.parentMapID and info.parentMapID ~= 0 and guard < 5 do
    info = TL.MapInfo(info.parentMapID)
    guard = guard + 1
  end
  if info and info.mapType == 2 then return info.mapID, info.name end
  return 0, "Elsewhere"
end

-- Fish of a zone, most valuable first.
local function ZoneFish(mapID)
  local idx = TL:Index()
  local list = {}
  for id in pairs(idx.byZone[mapID] or {}) do
    local fish = D.FISH_BY_ID[id]
    if fish then list[#list + 1] = fish end
  end
  table.sort(list, function(a, b)
    local va, vb = TL.Prices.Value(a.id), TL.Prices.Value(b.id)
    if va ~= vb then return va > vb end
    return a.name < b.name
  end)
  return list
end

-- What a catch is worth on average, from your own log (nil under 10 catches).
local function LogValue(mapID)
  local log = TL.db.catches[mapID]
  if not (log and (log.total or 0) >= 10) then return nil end
  local value = 0
  for id, n in pairs(log.items) do value = value + TL.Prices.Value(id) * n end
  return value / log.total, log.total
end

local function ZoneRow(mapID, here)
  local state, low, high = TL.ZoneState(mapID)
  local fish = ZoneFish(mapID)
  local perCatch = LogValue(mapID)
  local right, rightSub
  if perCatch then
    right, rightSub = TL.Money(perCatch, true), MUTED .. "per catch|r"
  elseif fish[1] and TL.Prices.AH(fish[1].id) then
    right, rightSub = TL.Money(TL.Prices.AH(fish[1].id), true), MUTED .. "top fish|r"
  else
    right, rightSub = "", ""
  end
  return {
    key = mapID, icon = FISHING_ICON, text = TL.MapName(mapID), color = TL.STATE_COLORS[state],
    sub = (mapID == here and (TL.AccentHex() .. "You are here|r  ") or "")
      .. (low and ("Fishing " .. low .. "-" .. high) or "Skill unknown") .. ", " .. #fish .. " catches",
    right = right, rightSub = rightSub,
    tip = { TL.STATE_TEXT[state] or "" },
  }
end

local RECENT_ZONES = 3

-- The zone you are in, the last few you were in, then every zone under its
-- continent. The continents start folded; a search shows every match instead.
local function ZoneRows(query)
  local idx = TL:Index()
  local here = TL.PlayerZone()
  local rows = {}

  if query == "" then
    if here and S.IsZone(here) then
      rows[#rows + 1] = { header = true, text = "You are here" }
      rows[#rows + 1] = ZoneRow(here, here)
    end
    local shown = 0
    for _, z in ipairs((TL.char and TL.char.recentZones) or {}) do
      if shown >= RECENT_ZONES then break end
      if z ~= here and idx.zones[z] and S.IsZone(z) then
        if shown == 0 then rows[#rows + 1] = { header = true, text = "Recently visited" } end
        rows[#rows + 1] = ZoneRow(z, here)
        shown = shown + 1
      end
    end
  end

  local list = {}
  for z in pairs(idx.zones) do
    if S.IsZone(z) and Match(TL.MapName(z), query) then
      local contID, contName = Continent(z)
      list[#list + 1] = { id = z, cont = contID, contName = contName }
    end
  end
  table.sort(list, function(a, b)
    if a.cont ~= b.cont then
      return (CONTINENT_ORDER[a.cont] or (a.cont == 0 and 99 or 50)) < (CONTINENT_ORDER[b.cont] or (b.cont == 0 and 99 or 50))
    end
    return S.ZoneSort(a.id, b.id)
  end)
  local cont, header
  for _, z in ipairs(list) do
    if z.cont ~= cont then
      cont = z.cont
      local foldKey = "zones:" .. z.cont
      local stored = TL.db.collapsed and TL.db.collapsed[foldKey]
      header = { header = true, text = z.contName, n = 0, collapseKey = foldKey,
        collapsed = query == "" and stored ~= false }
      rows[#rows + 1] = header
    end
    header.n = header.n + 1
    header.count = tostring(header.n)
    if not header.collapsed then rows[#rows + 1] = ZoneRow(z.id, here) end
  end
  return rows
end

local function ZoneDetail(mapID)
  local state, low, high = TL.ZoneState(mapID)
  local skill = TL.EffectiveSkill()
  local _, contName = Continent(mapID)
  local info = {}
  if low then
    info[#info + 1] = LABEL .. "Fishing:|r fish bite from " .. StateHex(state) .. low .. "|r, and none get away from "
      .. StateHex(state) .. high .. "|r."
    if skill then
      local line = LABEL .. "You:|r " .. skill .. "  " .. StateHex(state) .. (TL.STATE_TEXT[state] or "") .. "|r"
      if state == "red" then
        line = line .. MUTED .. "  (" .. (low - skill) .. " short: a lure can close the gap)|r"
      elseif state == "yellow" then
        line = line .. MUTED .. "  (" .. (high - skill) .. " more and nothing gets away)|r"
      end
      info[#info + 1] = line
    else
      info[#info + 1] = LABEL .. "You:|r " .. MUTED .. "no Fishing skill yet. The Trainers tab shows where to learn it.|r"
    end
  else
    info[#info + 1] = LABEL .. "Fishing:|r " .. MUTED .. "the skill this zone needs isn't known yet (new in WoW Forever).|r"
  end

  local pools = TL.ZonePools(mapID)
  if #pools > 0 then
    local parts = {}
    for i = 1, math.min(5, #pools) do
      parts[#parts + 1] = TL.Hex(pools[i].pool.color) .. pools[i].pool.name .. "|r x" .. pools[i].count
    end
    if #pools > 5 then parts[#parts + 1] = "+" .. (#pools - 5) .. " more" end
    info[#info + 1] = LABEL .. "Pools:|r " .. table.concat(parts, ", ")
  elseif not S.HasSpawnData() then
    info[#info + 1] = LABEL .. "Pools:|r " .. MUTED .. "install LibForeverData or QuestieDB to see pool spawns.|r"
  end

  local gz = TL.Generated and TL.Generated.zones and TL.Generated.zones[mapID]
  if gz and (gz.casts or 0) > 0 then
    info[#info + 1] = LABEL .. "Measured:|r " .. gz.casts .. " casts, " .. (gz.catches or 0) .. " catches, " .. (gz.away or 0) .. " got away"
      .. (gz.awayMax and (MUTED .. "  (fish still got away at skill " .. gz.awayMax .. ")|r") or "")
  end

  local perCatch, total = LogValue(mapID)
  local log = TL.db.catches[mapID]
  if perCatch then
    info[#info + 1] = LABEL .. "Your log:|r " .. total .. " catches, worth " .. TL.Money(perCatch) .. " each on average."
  elseif log and (log.total or 0) > 0 then
    info[#info + 1] = LABEL .. "Your log:|r " .. log.total .. " catches so far."
  end

  -- Every catch here, and the ones of the kind the page is filtered to
  local all = ZoneFish(mapID)
  local counts = {}
  for _, f in ipairs(all) do counts[f.cat] = (counts[f.cat] or 0) + 1 end
  local cat = TL.ZoneCat(mapID)
  local filters = { { key = "all", label = "All", count = #all, tip = "Every kind of catch in this zone." } }
  for _, c in ipairs(CAT_LIST) do
    if counts[c] then
      filters[#filters + 1] = { key = c, label = CAT_SHORT[c], count = counts[c],
        tip = "Only " .. CAT_LABEL[c]:lower() .. ": in the list beside the map, and on the map." }
    end
  end
  local fish = {}
  for _, f in ipairs(all) do
    if not cat or f.cat == cat then fish[#fish + 1] = f end
  end

  local chips = {}
  for _, f in ipairs(fish) do
    local ah = TL.Prices.AH(f.id)
    local name, quality = TL.ItemName(f.id)
    local g = TL.Generated and TL.Generated.fish and TL.Generated.fish[f.id]
    local share = g and g.zones and g.zones[mapID] and g.zones[mapID].share
    chips[#chips + 1] = {
      text = name .. (share and ("  " .. share .. "%") or "") .. (ah and ("  " .. TL.Money(ah, true)) or ""), plain = name, itemID = f.id,
      color = TL.QualityColor(quality),
      onClick = function()
        TL.UI.mapChoice["fish:" .. f.id] = mapID
        TL.UI:Open("fish", f.id)
      end,
    }
  end

  return {
    icon = FISHING_ICON, title = TL.MapName(mapID), titleColor = TL.STATE_COLORS[state],
    sub = contName .. "  |  " .. #all .. " kinds of catch",
    info = info, chipLabel = cat and CAT_SHORT[cat] or "Catches", chips = chips, map = mapID,
    filters = filters, filter = cat or "all", filterLabel = "Show",
    onFilter = function(key)
      TL.db.zoneFilter = (key ~= "all") and key or nil
      TL.WorldMap.Refresh(true)
    end,
    points = function(m)
      local points = TL.ZonePoints(m, TL.ZoneCat(m))
      return points, (#points == 0) and "No pool data for this zone yet. Your catches will mark the map as you fish." or nil
    end,
    actions = { TrackAction("zone", mapID, mapID) },
  }
end

Add({
  key = "zones", label = "Zones", placeholder = "Search a zone",
  emptyText = "No zone matches.",
  rows = ZoneRows, select = ZoneDetail,
  default = function() return TL.PlayerZone() end,
})

-------------------------------------------------------------------------------
--  Quests
-------------------------------------------------------------------------------
local QUEST_ICON = "Interface\\Icons\\INV_Misc_Note_01"

local function QuestVisible(q)
  if not q.side then return true end
  local mine = UnitFactionGroup and UnitFactionGroup("player")
  return (q.side == 1 and mine == "Alliance") or (q.side == 2 and mine == "Horde")
end

local function QuestDone(id)
  return C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) or false
end

local function QuestGiver(q)
  local id = q.starters[1]
  local npc = id and S.NPC(id)
  if not npc then return nil end
  local where, map = S.LocationText(npc.spawns)
  return npc, where, map
end

local function QuestRows(query)
  local byGroup = {}
  for _, entry in ipairs(D.QUESTS) do
    local q = S.Quest(entry.id)
    if q and QuestVisible(q) and Match(q.name, query) then
      byGroup[entry.group] = byGroup[entry.group] or {}
      table.insert(byGroup[entry.group], { entry = entry, q = q })
    end
  end
  local rows = {}
  for _, group in ipairs(D.QUEST_GROUPS) do
    local list = byGroup[group]
    if list then
      rows[#rows + 1] = { header = true, text = group, count = tostring(#list) }
      for _, item in ipairs(list) do
        local q = item.q
        local done = QuestDone(q.id)
        local _, _, map = QuestGiver(q)
        local parts = {}
        if q.level and q.level > 0 then parts[#parts + 1] = "Level " .. q.level end
        if map then parts[#parts + 1] = TL.MapName(map) end
        rows[#rows + 1] = {
          key = q.id, icon = QUEST_ICON, text = q.name, faded = done,
          color = done and C.dim or C.gold,
          sub = table.concat(parts, ", "),
          right = done and "|cff59ff73Done|r" or "",
          rightSub = q.side == 1 and "|cff5aa0ffAlliance|r" or q.side == 2 and "|cffff5a5aHorde|r" or "",
          tip = { item.entry.note or "" },
        }
      end
    end
  end
  return rows
end

local function QuestDetail(id)
  local q = S.Quest(id)
  if not q then return nil end
  local entry
  for _, e in ipairs(D.QUESTS) do
    if e.id == id then entry = e break end
  end
  local info = {}
  if QuestDone(id) then info[#info + 1] = "|cff59ff73You have completed this quest on this character.|r" end

  local npc, where, map = QuestGiver(q)
  if npc then
    info[#info + 1] = LABEL .. "Starts:|r " .. npc.name .. (where and ("  " .. MUTED .. where .. "|r") or "")
  end
  local finisher = q.finishers[1]
  if finisher and finisher ~= q.starters[1] then
    local fnpc = S.NPC(finisher)
    if fnpc then
      local fwhere = S.LocationText(fnpc.spawns)
      info[#info + 1] = LABEL .. "Turn in:|r " .. fnpc.name .. (fwhere and ("  " .. MUTED .. fwhere .. "|r") or "")
    end
  end

  local chips, objectives = {}, {}
  for _, o in ipairs(q.objectives) do
    if o.kind == "item" then
      local name, quality = TL.ItemName(o.id)
      objectives[#objectives + 1] = o.count .. " " .. name
      local isFish = D.FISH_BY_ID[o.id] ~= nil
      chips[#chips + 1] = {
        text = name, itemID = o.id, color = TL.QualityColor(quality),
        onClick = isFish and function() TL.UI:Open("fish", o.id) end or nil,
      }
    elseif o.kind == "kill" then
      local target = S.NPC(o.id)
      objectives[#objectives + 1] = o.count .. " " .. (target and target.name or "creatures")
    end
  end
  if #objectives > 0 then info[#info + 1] = LABEL .. "Needs:|r " .. table.concat(objectives, ", ") end

  local rewards = {}
  for _, r in ipairs(q.rewards) do
    local name, quality = TL.ItemName(r.id)
    rewards[#rewards + 1] = TL.Hex(TL.QualityColor(quality)) .. name .. "|r" .. (r.kind == "choice" and " (choice)" or "")
    if D.GEAR_BY_ID[r.id] then
      chips[#chips + 1] = {
        text = name, itemID = r.id, color = TL.QualityColor(quality),
        onClick = function() TL.UI:Open("gear", r.id) end,
      }
    end
  end
  if q.money and q.money > 0 then rewards[#rewards + 1] = TL.Money(q.money) end
  if #rewards > 0 then info[#info + 1] = LABEL .. "Rewards:|r " .. table.concat(rewards, ", ") end
  if entry and entry.note then info[#info + 1] = "|cffd0d2d6" .. entry.note .. "|r" end
  if not npc and not S.HasSpawnData() then
    info[#info + 1] = MUTED .. "Install LibForeverData or QuestieDB to see where this quest starts.|r"
  end

  local maps = TL.QuestMaps(q)
  local parts = {}
  if q.level and q.level > 0 then parts[#parts + 1] = "Level " .. q.level end
  if q.minLevel and q.minLevel > 0 then parts[#parts + 1] = "needs level " .. q.minLevel end
  parts[#parts + 1] = q.side == 1 and "Alliance" or q.side == 2 and "Horde" or "Both factions"

  -- Zone chips after the item chips, when the quest spans more than one map
  if #maps > 1 then
    for _, chip in ipairs(ZoneChips(maps)) do chips[#chips + 1] = chip end
  end

  return {
    icon = QUEST_ICON, title = q.name, titleColor = C.gold, sub = table.concat(parts, "  |  "),
    info = info, chipLabel = "Related", chips = chips,
    map = map or maps[1], maps = Set(maps),
    noMapText = "Where this quest starts isn't in the databases yet.",
    points = function(m) return TL.QuestPoints(q, m) end,
    actions = { TrackAction("quest", id, map or maps[1]) },
  }
end

Add({
  key = "quests", label = "Quests", placeholder = "Search a quest",
  emptyText = "No fishing quests found. LibForeverData or QuestieDB supplies them: is one of them enabled?",
  rows = QuestRows, select = QuestDetail,
})

-------------------------------------------------------------------------------
--  Gear
-------------------------------------------------------------------------------
local function GearBonus(g)
  if g.bonus == nil then return nil end
  if g.bonus == 0 then return "No bonus" end
  return "+" .. g.bonus .. " Fishing"
end

local function GearRows(query)
  local rows = {}
  for _, kind in ipairs(D.GEAR_KINDS) do
    local list = {}
    for _, g in ipairs(D.GEAR) do
      if g.kind == kind and Match((TL.ItemName(g.id)), query) then list[#list + 1] = g end
    end
    if #list > 0 then
      rows[#rows + 1] = { header = true, text = kind, count = tostring(#list) }
      for _, g in ipairs(list) do
        local name, quality = TL.ItemName(g.id)
        local owned = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(g.id, true))
          or (GetItemCount and GetItemCount(g.id, true)) or 0
        rows[#rows + 1] = {
          key = g.id, itemID = g.id, icon = TL.ItemIcon(g.id), text = name, color = TL.QualityColor(quality),
          sub = (GearBonus(g) or g.kind) .. (owned > 0 and "  |cff59ff73owned|r" or ""),
          right = RowPrice(g.id), rightSub = "",
        }
      end
    end
  end
  return rows
end

local function GearDetail(id)
  local g = D.GEAR_BY_ID[id]
  if not g then return nil end
  local name, quality = TL.ItemName(id)
  local info = { PriceLine(id) }
  local bonus = GearBonus(g)
  if bonus then info[#info + 1] = LABEL .. "Bonus:|r " .. bonus end
  info[#info + 1] = LABEL .. "Source:|r " .. g.source
  local skill = TL.skill
  if skill and g.bonus and g.bonus > 0 and (g.kind == "Lures" or g.kind == "Poles") then
    info[#info + 1] = MUTED .. "With it your " .. skill.rank .. " Fishing counts as " .. (skill.rank + g.bonus)
      .. (g.kind == "Lures" and " (lures and pole bonuses stack)." or ".") .. "|r"
  end
  local chips, map, questRec = {}, nil, nil
  if g.quest then
    questRec = S.Quest(g.quest)
    if questRec then
      chips[#chips + 1] = {
        text = "Quest: " .. questRec.name, color = C.gold,
        onClick = function() TL.UI:Open("quests", g.quest) end,
        tip = { "Click to open this quest." },
      }
      local _, _, questMap = QuestGiver(questRec)
      map = questMap
    end
  end
  return {
    icon = TL.ItemIcon(id), itemID = id, title = name, titleColor = TL.QualityColor(quality),
    sub = g.kind .. (bonus and ("  |  " .. bonus) or ""),
    info = info, chipLabel = "From", chips = chips, map = map,
    noMapText = "Sold by fishing suppliers: the Trainers tab shows where they stand.",
    points = questRec and function(m) return TL.QuestPoints(questRec, m) end or nil,
    actions = { SearchAction({ id }), LinkAction(id) },
  }
end

Add({
  key = "gear", label = "Gear", placeholder = "Search poles, lures, gear",
  emptyText = "Nothing matches.",
  rows = GearRows, select = GearDetail,
})

-------------------------------------------------------------------------------
--  Trainers and suppliers
-------------------------------------------------------------------------------
local TRAINER_ICON = "Interface\\Icons\\INV_Misc_Book_09"
local VENDOR_ICON = "Interface\\Icons\\INV_Misc_Bag_10"

local function IsTrainer(title)
  title = (title or ""):lower()
  return title:find("trainer", 1, true) ~= nil or title:find("fisherman", 1, true) ~= nil
end

local function NPCRows(query)
  local trainers, vendors = {}, {}
  local here = TL.PlayerZone()
  for _, entry in ipairs(D.NPCS) do
    local npc = S.NPC(entry[1])
    if npc then
      local where, map = S.LocationText(npc.spawns)
      local zone = map and TL.MapName(map) or nil
      if Match(npc.name, query) or Match(zone, query) or Match(npc.sub, query) then
        local row = {
          key = npc.id, text = npc.name, zone = zone or "~",
          sub = (npc.sub or "") .. (where and (", " .. where) or ""),
          right = map == here and (TL.AccentHex() .. "Here|r") or "", rightSub = "",
          tip = { npc.sub or "", where or "Location unknown" },
        }
        if IsTrainer(npc.sub) then
          row.icon = TRAINER_ICON
          trainers[#trainers + 1] = row
        else
          row.icon = VENDOR_ICON
          vendors[#vendors + 1] = row
        end
      end
    end
  end
  local function ByZone(a, b)
    if a.zone ~= b.zone then return a.zone < b.zone end
    return a.text < b.text
  end
  table.sort(trainers, ByZone)
  table.sort(vendors, ByZone)
  local rows = {}
  if #trainers > 0 then
    rows[#rows + 1] = { header = true, text = "Trainers", count = tostring(#trainers) }
    for _, r in ipairs(trainers) do rows[#rows + 1] = r end
  end
  if #vendors > 0 then
    rows[#rows + 1] = { header = true, text = "Supplies & fish vendors", count = tostring(#vendors) }
    for _, r in ipairs(vendors) do rows[#rows + 1] = r end
  end
  return rows
end

local function NPCDetail(id)
  local npc = S.NPC(id)
  if not npc then return nil end
  local where, map = S.LocationText(npc.spawns)
  local trainer = IsTrainer(npc.sub)
  local info = {
    LABEL .. "Where:|r " .. (where or (MUTED .. (S.HasSpawnData() and "not placed in the databases yet"
      or "install LibForeverData or QuestieDB to see where") .. "|r")),
  }
  if trainer then
    info[#info + 1] = "|cffd0d2d6Teaches Fishing. Apprentice and Journeyman come from any trainer; Expert is a book from Old Man Heming in Booty Bay, and Artisan is Nat Pagle's quest in Dustwallow Marsh.|r"
  else
    info[#info + 1] = "|cffd0d2d6Sells fishing supplies: poles, and lures such as Shiny Baubles and Nightcrawlers.|r"
  end
  info[#info + 1] = MUTED .. "Some of these NPCs only deal with one faction.|r"
  return {
    icon = trainer and TRAINER_ICON or VENDOR_ICON, title = npc.name, titleColor = C.gold,
    sub = npc.sub or "", info = info, map = map,
    noMapText = "This NPC isn't placed in the databases yet.",
    points = function(m) return TL.NPCPoints(id, m) end,
    actions = { TrackAction("npc", id, map) },
  }
end

Add({
  key = "trainers", label = "Trainers", placeholder = "Search a name or a zone",
  emptyText = "Nobody matches.",
  rows = NPCRows, select = NPCDetail,
  default = function()
    local here = TL.PlayerZone()
    for _, entry in ipairs(D.NPCS) do
      local npc = S.NPC(entry[1])
      local _, map = S.LocationText(npc and npc.spawns)
      if map and map == here then return entry[1] end
    end
  end,
})

-- For Trips.lua
Tabs.Add, Tabs.Match, Tabs.ZoneChips = Add, Match, ZoneChips
