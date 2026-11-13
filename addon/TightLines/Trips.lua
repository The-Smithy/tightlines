-------------------------------------------------------------------------------
--  TightLines: the Trips tab. This character's fishing trips (Journal.lua),
--  the trip in progress, the all-time catch log by zone, and your other
--  characters.
-------------------------------------------------------------------------------
local _, TL = ...
local D, C = TL.Data, TL.C
local Tabs = TL.Tabs
local Match = Tabs.Match

local LABEL, MUTED = "|cff9aa0a8", "|cff7c8088"
local FISHING_ICON = "Interface\\Icons\\Trade_Fishing"
local TRIP_ICON = "Interface\\Icons\\INV_Misc_Book_08"
local ZONE_ICON = "Interface\\Icons\\INV_Misc_Map_01"
local CHAR_ICON = "Interface\\Icons\\INV_Misc_Head_Human_01"

local function Duration(seconds)
  local minutes = math.max(1, math.floor(seconds / 60 + 0.5))
  if minutes < 60 then return minutes .. " min" end
  return math.floor(minutes / 60) .. " h " .. (minutes % 60) .. " min"
end

-- An item breakdown, most valuable first: text parts, value, count, the list.
local function Breakdown(items, limit)
  local list, value, count = {}, 0, 0
  for id, n in pairs(items or {}) do
    local each = TL.Prices.Value(id)
    list[#list + 1] = { id = id, n = n, value = each * n }
    value = value + each * n
    count = count + n
  end
  table.sort(list, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    if a.n ~= b.n then return a.n > b.n end
    return a.id < b.id
  end)
  local parts = {}
  for i = 1, math.min(limit, #list) do
    local name, quality = TL.ItemName(list[i].id)
    parts[#parts + 1] = list[i].n .. " " .. TL.Hex(TL.QualityColor(quality)) .. name .. "|r"
      .. (list[i].value > 0 and (" " .. MUTED .. "(" .. TL.Money(list[i].value, true, true) .. ")|r") or "")
  end
  if #list > limit then parts[#parts + 1] = "+" .. (#list - limit) .. " more" end
  return parts, value, count, list
end

local function FishChips(list, mapID)
  local chips = {}
  for _, item in ipairs(list) do
    if D.FISH_BY_ID[item.id] then
      local name, quality = TL.ItemName(item.id)
      chips[#chips + 1] = {
        text = name, itemID = item.id, color = TL.QualityColor(quality),
        onClick = function()
          if mapID then TL.UI.mapChoice["fish:" .. item.id] = mapID end
          TL.UI:Open("fish", item.id)
        end,
      }
    end
  end
  return chips
end

-- The zone a trip mostly happened in, and every zone it touched.
local function TripZones(trip)
  local best, bestN, zones = nil, 0, {}
  for map, n in pairs(trip.zones or {}) do
    zones[#zones + 1] = map
    if n > bestN then best, bestN = map, n end
  end
  table.sort(zones, function(a, b) return (trip.zones[a] or 0) > (trip.zones[b] or 0) end)
  return best, zones
end

local function TripLength(trip)
  return math.max(60, (trip.stop or trip.last or trip.start) - trip.start)
end

local function FindTrip(id)
  for _, trip in ipairs(TL.Journal.Trips()) do
    if trip.id == id then return trip end
  end
end

-------------------------------------------------------------------------------
--  Rows
-------------------------------------------------------------------------------
local function TripRow(trip, key, title)
  local zone = TripZones(trip)
  local value = TL.Journal.TripValue(trip)
  return {
    key = key, icon = trip.open and FISHING_ICON or TRIP_ICON, text = title,
    color = trip.open and C.gold or C.text,
    sub = (zone and TL.MapName(zone) or "No catches") .. ", " .. Duration(TripLength(trip)),
    right = value > 0 and TL.Money(value, true) or "",
    rightSub = MUTED .. trip.catches .. (trip.catches == 1 and " catch|r" or " catches|r"),
  }
end

local function Rows(query)
  local rows = {}
  local current = TL.Journal.CurrentTrip()

  if Match("trip in progress now", query) then
    rows[#rows + 1] = { header = true, text = "Now" }
    if current then
      rows[#rows + 1] = TripRow(current, "now", "Trip in progress")
    else
      rows[#rows + 1] = {
        key = "now", icon = FISHING_ICON, text = "No trip in progress", color = C.dim,
        sub = "Cast a line to start one", right = "", rightSub = "",
      }
    end
  end

  -- This character's trips, newest first
  local trips, list = TL.Journal.Trips(), {}
  for i = #trips, 1, -1 do
    local trip = trips[i]
    if trip ~= current then
      local zone = TripZones(trip)
      if Match(zone and TL.MapName(zone) or "", query) or Match(date("%d %b %Y", trip.start), query) then
        list[#list + 1] = trip
      end
    end
  end
  if #list > 0 then
    local name = (TL.charKey or "Your"):match("^[^-]+") or "Your"
    rows[#rows + 1] = { header = true, text = name .. "'s trips", count = tostring(#list) }
    for _, trip in ipairs(list) do
      rows[#rows + 1] = TripRow(trip, "trip:" .. trip.id, date("%a %d %b, %H:%M", trip.start))
    end
  end

  -- All-time catch log by zone (every character)
  local zones = {}
  for mapID, log in pairs(TL.db.catches) do
    if (log.total or 0) > 0 and Match(TL.MapName(mapID), query) then zones[#zones + 1] = mapID end
  end
  table.sort(zones, function(a, b) return (TL.db.catches[a].total or 0) > (TL.db.catches[b].total or 0) end)
  if #zones > 0 then
    rows[#rows + 1] = { header = true, text = "All-time by zone", count = tostring(#zones) }
    for _, mapID in ipairs(zones) do
      local log = TL.db.catches[mapID]
      local _, value = Breakdown(log.items, 0)
      rows[#rows + 1] = {
        key = "zone:" .. mapID, icon = ZONE_ICON, text = TL.MapName(mapID),
        color = TL.STATE_COLORS[TL.ZoneState(mapID)],
        sub = log.total .. " catches", right = TL.Money(value, true),
        rightSub = MUTED .. TL.Money(value / log.total, true, true) .. " each|r",
      }
    end
  end

  -- Your other characters
  local others = {}
  for key, other in pairs(TL.db.chars) do
    if key ~= TL.charKey and Match(key, query) then others[#others + 1] = key end
  end
  table.sort(others)
  if #others > 0 then
    rows[#rows + 1] = { header = true, text = "Other characters", count = tostring(#others) }
    for _, key in ipairs(others) do
      local totals = TL.db.chars[key].totals or {}
      rows[#rows + 1] = {
        key = "char:" .. key, icon = CHAR_ICON, text = key, color = C.text,
        sub = (totals.trips or 0) .. " trips", right = "",
        rightSub = MUTED .. (totals.catches or 0) .. " catches|r",
      }
    end
  end
  return rows
end

-------------------------------------------------------------------------------
--  Detail pages
-------------------------------------------------------------------------------
local function TripDetail(trip, inProgress)
  local parts, value, _, list = Breakdown(trip.items, 8)
  local length = TripLength(trip)
  local hours = length / 3600
  local info = {}
  info[#info + 1] = LABEL .. "When:|r " .. date("%a %d %b %Y, %H:%M", trip.start)
    .. (inProgress and "  |cff59ff73still going|r" or (" to " .. date("%H:%M", trip.stop or trip.last or trip.start)))
    .. "  " .. MUTED .. "(" .. Duration(length) .. ")|r"
  local line = LABEL .. "Casts:|r " .. trip.casts .. "     " .. LABEL .. "Catches:|r " .. trip.catches
  if trip.casts > 0 then line = line .. " " .. MUTED .. "(" .. math.floor(trip.catches / trip.casts * 100 + 0.5) .. "%)|r" end
  if (trip.away or 0) > 0 then line = line .. "     " .. LABEL .. "Got away:|r |cffff5555" .. trip.away .. "|r" end
  info[#info + 1] = line .. "     " .. MUTED .. math.floor(trip.catches / hours + 0.5) .. " catches an hour|r"
  info[#info + 1] = LABEL .. "Worth:|r " .. TL.Money(value) .. "  " .. MUTED .. "(" .. TL.Money(value / hours, true, true)
    .. " an hour at today's prices)|r"
  if trip.skill0 and trip.skill1 and trip.skill1 > trip.skill0 then
    info[#info + 1] = LABEL .. "Fishing:|r " .. trip.skill0 .. " to " .. trip.skill1 .. "  |cff59ff73+" .. (trip.skill1 - trip.skill0) .. "|r"
  end
  if #parts > 0 then info[#info + 1] = table.concat(parts, ", ") end

  local zone, zones = TripZones(trip)
  local chips = FishChips(list, zone)
  if #zones > 1 then
    for _, chip in ipairs(Tabs.ZoneChips(zones)) do chips[#chips + 1] = chip end
  end
  local maps = {}
  for _, z in ipairs(zones) do maps[z] = true end

  local actions = {}
  if not inProgress then
    actions[#actions + 1] = { text = "Delete trip", tip = "Shift-click to delete this trip from your history.", onClick = function()
      if not IsShiftKeyDown() then
        TL:Print("Shift-click to delete this trip.")
        return
      end
      TL.UI.selected.trips = nil
      TL.Journal.DeleteTrip(trip.id)
    end }
  end
  if zone then
    actions[#actions + 1] = { text = "Open zone", tip = "This zone's fishing page.", onClick = function() TL.UI:Open("zones", zone) end }
  end

  return {
    icon = inProgress and FISHING_ICON or TRIP_ICON,
    title = inProgress and "Trip in progress" or ("Trip on " .. date("%d %b", trip.start)),
    titleColor = C.gold,
    sub = (zone and TL.MapName(zone) or "No catches yet") .. "  |  " .. Duration(length),
    info = info, chipLabel = "Caught", chips = chips,
    map = zone or TL.PlayerZone(), maps = next(maps) and maps or nil,
    points = function(m)
      local out = {}
      for _, s in ipairs(trip.spots or {}) do
        if s[4] == m then
          out[#out + 1] = { x = s[1], y = s[2], kind = "catch", tip = TL.ItemName(s[3]), sub = "Caught on this trip." }
        end
      end
      return out
    end,
    actions = actions,
  }
end

local function NoTripDetail()
  local totals = (TL.char and TL.char.totals) or {}
  local info = {
    "A trip starts with your first cast and ends after " .. math.floor(TL.Journal.TRIP_IDLE / 60) .. " minutes without fishing.",
    MUTED .. "Each trip keeps its casts, catches, the ones that got away, what it was worth and where you stood. Trips are kept per character.|r",
  }
  if (totals.catches or 0) > 0 then
    info[#info + 1] = LABEL .. "This character so far:|r " .. (totals.trips or 0) .. " trips, " .. (totals.casts or 0)
      .. " casts, " .. (totals.catches or 0) .. " catches, " .. (totals.away or 0) .. " got away."
  end
  return {
    icon = FISHING_ICON, title = "No trip in progress", titleColor = C.dim,
    sub = "Cast a line to start one", info = info, map = TL.PlayerZone(),
    points = function(m)
      local out = {}
      for _, pt in ipairs(TL.ZonePoints(m)) do
        if pt.kind == "catch" then out[#out + 1] = pt end
      end
      return out
    end,
    actions = {},
  }
end

local function ZoneLogDetail(mapID)
  local log = TL.db.catches[mapID]
  if not log then return nil end
  local parts, value, count, list = Breakdown(log.items, 8)
  local info = {
    LABEL .. "Caught:|r " .. count .. (log.last and ("  " .. MUTED .. "last on " .. date("%d %b %Y", log.last) .. "|r") or ""),
    LABEL .. "Worth:|r " .. TL.Money(value) .. "  " .. MUTED .. "(" .. TL.Money(value / math.max(1, count), true, true) .. " a catch)|r",
    table.concat(parts, ", "),
  }
  return {
    icon = ZONE_ICON, title = TL.MapName(mapID), titleColor = TL.STATE_COLORS[TL.ZoneState(mapID)],
    sub = "All-time catch log, every character", info = info, chipLabel = "Fish", chips = FishChips(list, mapID), map = mapID,
    points = function(m)
      local out = {}
      for _, pt in ipairs(TL.ZonePoints(m)) do
        if pt.kind == "catch" then out[#out + 1] = pt end
      end
      return out
    end,
    actions = {
      { text = "Clear log", tip = "Shift-click to delete this zone's catch log.", onClick = function()
        if not IsShiftKeyDown() then
          TL:Print("Shift-click to delete the catch log for " .. TL.MapName(mapID) .. ".")
          return
        end
        TL.db.catches[mapID] = nil
        TL.index = nil
        TL.UI.selected.trips = nil
        TL:Fire("CATCH", mapID)
      end },
      { text = "Open zone", tip = "This zone's fishing page.", onClick = function() TL.UI:Open("zones", mapID) end },
    },
  }
end

local function CharDetail(key)
  local other = TL.db.chars[key]
  if not other then return nil end
  local totals = other.totals or {}
  local items, best, bestValue = {}, nil, 0
  for _, trip in ipairs(other.trips or {}) do
    for id, n in pairs(trip.items or {}) do items[id] = (items[id] or 0) + n end
    local value = TL.Journal.TripValue(trip)
    if value > bestValue then best, bestValue = trip, value end
  end
  local parts, value = Breakdown(items, 8)
  local info = {
    LABEL .. "Trips:|r " .. (totals.trips or 0) .. "     " .. LABEL .. "Casts:|r " .. (totals.casts or 0)
      .. "     " .. LABEL .. "Catches:|r " .. (totals.catches or 0) .. "     " .. LABEL .. "Got away:|r " .. (totals.away or 0),
    LABEL .. "Kept trips are worth:|r " .. TL.Money(value),
  }
  if best then
    info[#info + 1] = LABEL .. "Best trip:|r " .. date("%d %b %Y", best.start) .. ", " .. TL.Money(bestValue)
  end
  if #parts > 0 then info[#info + 1] = table.concat(parts, ", ") end
  info[#info + 1] = MUTED .. "Log in on this character to see each of its trips.|r"
  return {
    icon = CHAR_ICON, title = key, titleColor = C.gold,
    sub = other.seen and ("Last seen " .. date("%d %b %Y", other.seen)) or "",
    info = info, noMapText = "Log in on this character to see where it fished.", actions = {},
  }
end

local function Detail(key)
  if key == "now" then
    local current = TL.Journal.CurrentTrip()
    return current and TripDetail(current, true) or NoTripDetail()
  end
  local kind, id = tostring(key):match("^(%a+):(.+)$")
  if kind == "trip" then
    local trip = FindTrip(tonumber(id))
    return trip and TripDetail(trip, false) or nil
  elseif kind == "zone" then
    return ZoneLogDetail(tonumber(id))
  elseif kind == "char" then
    return CharDetail(id)
  end
end

Tabs.Add({
  key = "trips", label = "Trips", placeholder = "Search a zone or a date",
  emptyText = "Nothing logged yet. Go fishing!",
  rows = Rows, select = Detail,
  default = function() return "now" end,
})
