-------------------------------------------------------------------------------
--  TightLines: the journal. Every fishing event is written down twice:
--
--  1. Raw events (TightLinesDB.journal.events) for the creel analyzer, a
--     separate app that reads this addon's SavedVariables file, keeps
--     everything in a database and writes Generated.lua back into this folder.
--     One event is one string of key=value pairs joined by "^":
--         s=412^e=catch^ts=1731500000^c=1^tr=7^m=1444^sz=Verdantis River^
--         x=31.25^y=43.5^sk=230^md=75^h=20^it=13758:1,6358:2^src=35591^cs=411
--       s   sequence number (never reused)     e   event kind
--       ts  unix time                          c   character (index in chars)
--       tr  trip id                            m   zone uiMapID
--       sz  subzone                            x,y position, map percent
--       sk  Fishing rank    md  lure and gear  h   server hour
--     and per kind:
--       cast      a cast went out
--       catch     it  item:count,...   src  what gave the loot (a pool's
--                 object id; 35591 is the bobber: open water)   cs  its cast
--       away      the fish got away    cs
--       nohook    reeled in with nothing on the line    cs
--       lowskill  need  the Fishing skill the game asked for here
--       skillup   from, to
--       trip      a trip began
--       error     text  an error inside TightLines
--     Events creel has already stored are dropped at the next login.
--
--  2. Trips, per character (TightLinesDB.chars["Name-Realm"].trips): a trip
--     starts with a cast and ends after 15 minutes without fishing. These
--     stay in the addon and are what the Trips tab shows.
--
--  The per-zone catch log (TightLinesDB.catches) is kept here too.
-------------------------------------------------------------------------------
local _, TL = ...
local D = TL.Data
local J = {}
TL.Journal = J

local MAX_EVENTS = 20000
local TRIP_IDLE = 900         -- seconds without fishing that end a trip
local MAX_TRIPS = 200         -- per character
local MAX_TRIP_SPOTS = 80
local MAX_ZONE_SPOTS = 400
local MAX_ERRORS = 30         -- per session
local BOBBER = 35591
local FISHING_SPELLS = { [7620] = true, [7731] = true, [7732] = true, [18248] = true }

local charIndex, char
local lastCast            -- { seq, at }: the cast now in the water
local lootLogged = false
local errorsLogged, errorSeen = 0, {}
local lastLowSkill = {}

J.TRIP_IDLE = TRIP_IDLE

local function Secret(v)
  return issecretvalue ~= nil and issecretvalue(v)
end

local function Clean(v)
  return (tostring(v):gsub("[%^=|%c]", " "))
end

-------------------------------------------------------------------------------
--  Raw events
-------------------------------------------------------------------------------
function J.Log(kind, fields)
  local db = TL.db
  if not db then return nil end
  local j = db.journal
  j.seq = (j.seq or 0) + 1
  local parts = { "s=" .. j.seq, "e=" .. kind, "ts=" .. time() }
  if charIndex then parts[#parts + 1] = "c=" .. charIndex end
  for k, v in pairs(fields or {}) do
    parts[#parts + 1] = k .. "=" .. Clean(v)
  end
  local events = j.events
  events[#events + 1] = table.concat(parts, "^")
  if #events > MAX_EVENTS then
    -- Full: drop the oldest tenth in one pass
    local drop, kept = math.floor(MAX_EVENTS / 10), {}
    for i = drop + 1, #events do kept[#kept + 1] = events[i] end
    j.events = kept
    j.dropped = (j.dropped or 0) + drop
  end
  return j.seq
end

-- Where and how the player is fishing right now, as event fields.
local function Where()
  local f = {}
  local map = TL.PlayerZone()
  if map then
    f.m = map
    TL.db.journal.names.m[map] = TL.MapName(map)
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
    if ok and pos then
      local x, y = pos:GetXY()
      if x and y and not Secret(x) and not Secret(y) and x > 0 and y > 0 then
        f.x = math.floor(x * 10000 + 0.5) / 100
        f.y = math.floor(y * 10000 + 0.5) / 100
      end
    end
  end
  local sub = GetSubZoneText and GetSubZoneText()
  if type(sub) == "string" and not Secret(sub) and sub ~= "" then f.sz = sub end
  local s = TL.skill
  if s then f.sk, f.md = s.rank, s.mod or 0 end
  local hour = GetGameTime and GetGameTime()
  if type(hour) == "number" then f.h = hour end
  if TL.trip then f.tr = TL.trip.id end
  return f, map
end

function J.LogError(err)
  if not TL.db or errorsLogged >= MAX_ERRORS then return end
  local text = tostring(err)
  if errorSeen[text] then return end
  errorSeen[text] = true
  errorsLogged = errorsLogged + 1
  J.Log("error", { text = text:sub(1, 400), v = TL.version })
end

-------------------------------------------------------------------------------
--  Trips
-------------------------------------------------------------------------------
function J.TripValue(trip)
  local value = 0
  for id, n in pairs(trip.items or {}) do value = value + TL.Prices.Value(id) * n end
  return value
end

local function CloseTrip(trip)
  trip.open = nil
  trip.stop = trip.last or trip.start
  trip.value = J.TripValue(trip)
  if TL.trip == trip then TL.trip = nil end
end

-- The trip in progress, or nil (one left idle too long is closed here).
function J.CurrentTrip()
  local trip = TL.trip
  if trip and time() - (trip.last or trip.start) > TRIP_IDLE then
    CloseTrip(trip)
    trip = nil
  end
  return trip
end

-- The trip in progress, starting one when there is none.
local function Trip()
  local trip = J.CurrentTrip()
  local now = time()
  if not trip then
    trip = {
      id = char.nextTrip, start = now, last = now, open = true,
      casts = 0, catches = 0, away = 0, items = {}, zones = {}, spots = {},
      skill0 = TL.skill and TL.skill.rank or nil,
    }
    char.nextTrip = char.nextTrip + 1
    char.trips[#char.trips + 1] = trip
    char.totals.trips = (char.totals.trips or 0) + 1
    while #char.trips > MAX_TRIPS do table.remove(char.trips, 1) end
    TL.trip = trip
    J.Log("trip", { tr = trip.id })
  end
  trip.last = now
  return trip
end

-- This character's trips, oldest first.
function J.Trips()
  return char and char.trips or {}
end

function J.DeleteTrip(id)
  if not char then return end
  for i, trip in ipairs(char.trips) do
    if trip.id == id then
      if TL.trip == trip then TL.trip = nil end
      table.remove(char.trips, i)
      break
    end
  end
  TL:Fire("TRIP")
end

-------------------------------------------------------------------------------
--  Casts
-------------------------------------------------------------------------------
local function IsFishingCast(spellID)
  if Secret(spellID) then spellID = nil end
  if spellID and FISHING_SPELLS[spellID] then return true end
  local want = TL.FishingName()
  if spellID and C_Spell and C_Spell.GetSpellName then
    local name = C_Spell.GetSpellName(spellID)
    if name and not Secret(name) then return name == want end
  end
  local name = UnitChannelInfo and UnitChannelInfo("player")
  return name ~= nil and not Secret(name) and name == want
end

local function OnCast()
  if not (char and TL.db.settings.logCatches) then return end
  local trip = Trip()
  trip.casts = trip.casts + 1
  char.totals.casts = (char.totals.casts or 0) + 1
  local f = Where()
  f.tr = trip.id
  lastCast = { seq = J.Log("cast", f), at = time() }
  TL:Fire("TRIP")
end

-------------------------------------------------------------------------------
--  Catches
-------------------------------------------------------------------------------
-- "GameObject-0-4170-0-41-180712-00001A2B3C" -> 180712
local function ObjectID(guid)
  if type(guid) ~= "string" or Secret(guid) then return nil end
  local kind, _, _, _, _, id = strsplit("-", guid)
  if kind == "GameObject" then return tonumber(id) end
end

local function OnLoot()
  if lootLogged or not (TL.db and char) then return end
  if not (IsFishingLoot and IsFishingLoot()) then return end
  if not TL.db.settings.logCatches then return end

  local f, map = Where()
  local names = TL.db.journal.names
  local items, got, src = {}, {}, nil
  for slot = 1, (GetNumLootItems and GetNumLootItems() or 0) do
    local link = GetLootSlotLink(slot)
    local id = type(link) == "string" and not Secret(link) and tonumber(link:match("item:(%d+)"))
    if id then
      local _, _, qty = GetLootSlotInfo(slot)
      qty = (type(qty) == "number" and not Secret(qty) and qty > 0) and qty or 1
      got[#got + 1] = { id = id, qty = qty }
      items[#items + 1] = id .. ":" .. qty
      if not names.i[id] then names.i[id] = TL.ItemName(id, true) end
      if not src and GetLootSourceInfo then src = ObjectID((GetLootSourceInfo(slot))) end
    end
  end
  if #got == 0 then return end -- not filled in yet: LOOT_OPENED follows LOOT_READY
  lootLogged = true

  -- The raw event
  f.it = table.concat(items, ",")
  if src then
    f.src = src
    if src ~= BOBBER and not names.o[src] then
      local pool = D.POOLS[src]
      local lib = _G.LibForeverData
      names.o[src] = (pool and pool.name) or (type(lib) == "table" and lib.Name and lib.Name("object", src)) or nil
    end
  end
  if lastCast and time() - lastCast.at < 60 then f.cs = lastCast.seq end
  lastCast = nil

  -- The trip
  local trip = Trip()
  f.tr = trip.id
  J.Log("catch", f)
  trip.catches = trip.catches + 1
  char.totals.catches = (char.totals.catches or 0) + 1
  if map then trip.zones[map] = (trip.zones[map] or 0) + 1 end
  if TL.skill then trip.skill1 = TL.skill.rank end

  -- The zone's catch log
  local log = map and TL.db.catches[map]
  if map and not log then
    log = { items = {}, spots = {}, total = 0 }
    TL.db.catches[map] = log
  end
  local newKind = false
  for _, item in ipairs(got) do
    trip.items[item.id] = (trip.items[item.id] or 0) + item.qty
    if log then
      if not log.items[item.id] then newKind = true end
      log.items[item.id] = (log.items[item.id] or 0) + item.qty
      log.total = (log.total or 0) + item.qty
      if f.x and f.y then
        log.spots[#log.spots + 1] = { f.x, f.y, item.id }
        while #log.spots > MAX_ZONE_SPOTS do table.remove(log.spots, 1) end
      end
    end
    if f.x and f.y and map and #trip.spots < MAX_TRIP_SPOTS then
      trip.spots[#trip.spots + 1] = { f.x, f.y, item.id, map }
    end
  end
  if log then log.last = time() end
  if newKind then TL.index = nil end
  TL:Fire("CATCH", map)
  TL:Fire("TRIP")
end

-------------------------------------------------------------------------------
--  The game's messages: got away, nothing hooked, skill too low
-------------------------------------------------------------------------------
-- A format string such as "Requires Fishing %d" as a pattern capturing the number.
local function PatternOf(fmt)
  if type(fmt) ~= "string" or not fmt:find("%d", 1, true) then return nil end
  local p = fmt:gsub("[%(%)%.%+%-%*%?%[%]%^%$]", "%%%0")
  p = p:gsub("%%d", "(%%d+)"):gsub("%%s", ".+")
  return "^" .. p .. "$"
end

local lowPattern

local function OnUIError(_, message)
  if not (char and TL.db.settings.logCatches) then return end
  if type(message) ~= "string" or Secret(message) then return end
  local recent = lastCast and time() - lastCast.at < 60
  if message == ERR_FISH_ESCAPED then
    if not recent then return end
    local f = Where()
    f.cs = lastCast.seq
    lastCast = nil
    local trip = Trip()
    f.tr = trip.id
    trip.away = trip.away + 1
    char.totals.away = (char.totals.away or 0) + 1
    J.Log("away", f)
    TL:Fire("TRIP")
  elseif message == ERR_FISH_NOT_HOOKED then
    if not recent then return end
    local f = Where()
    f.cs = lastCast.seq
    lastCast = nil
    J.Log("nohook", f)
  else
    if lowPattern == nil then lowPattern = PatternOf(SPELL_FAILED_FISHING_TOO_LOW) or false end
    local need = lowPattern and tonumber(message:match(lowPattern))
    if not need then return end
    local f, map = Where()
    -- Once a minute per place is enough
    local key = tostring(map) .. "/" .. tostring(f.sz) .. "/" .. need
    if lastLowSkill[key] and time() - lastLowSkill[key] < 60 then return end
    lastLowSkill[key] = time()
    f.need = need
    J.Log("lowskill", f)
  end
end

TL:On("SKILL", function(old, new)
  if not (char and old and new and TL.db.settings.logCatches) then return end
  if new.rank > old.rank then
    local f = Where()
    f.from, f.to = old.rank, new.rank
    J.Log("skillup", f)
    if TL.trip then TL.trip.skill1 = new.rank end
  end
end)

-------------------------------------------------------------------------------
--  Login: this character, the guide's snapshot for creel, and house-keeping
-------------------------------------------------------------------------------
local function InitChar()
  local db = TL.db
  local j = db.journal
  local name = UnitName and UnitName("player")
  if type(name) ~= "string" or Secret(name) then name = "Unknown" end
  local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName and GetRealmName()) or "Realm"
  if type(realm) ~= "string" or Secret(realm) then realm = "Realm" end
  local key = name .. "-" .. realm
  for i, k in ipairs(j.chars) do
    if k == key then charIndex = i break end
  end
  if not charIndex then
    j.chars[#j.chars + 1] = key
    charIndex = #j.chars
  end
  -- One id per install, so creel can tell two accounts' journals apart
  if not j.id then j.id = string.format("%08x%04x", time(), math.random(0, 65535)) end

  char = db.chars[key]
  if not char then
    char = { trips = {}, nextTrip = 1, totals = { trips = 0, casts = 0, catches = 0, away = 0 } }
    db.chars[key] = char
  end
  char.trips = char.trips or {}
  char.nextTrip = char.nextTrip or 1
  char.totals = char.totals or { trips = 0, casts = 0, catches = 0, away = 0 }
  if UnitClass then char.class = select(2, UnitClass("player")) end
  char.seen = time()
  TL.charKey, TL.char = key, char

  -- A trip left open by the last session: carry on with it, or close it
  local last = char.trips[#char.trips]
  if last and last.open then
    if time() - (last.last or last.start) > TRIP_IDLE then CloseTrip(last) else TL.trip = last end
  end
end

-- Events creel has stored (Generated.lua says up to which) leave the journal.
local function TrimIngested()
  local j = TL.db.journal
  local upTo = TL.Generated and TL.Generated.ingested and j.id and TL.Generated.ingested[j.id]
  if type(upTo) ~= "number" or #j.events == 0 then return end
  local kept = {}
  for _, e in ipairs(j.events) do
    local seq = tonumber(e:match("^s=(%d+)"))
    if not seq or seq > upTo then kept[#kept + 1] = e end
  end
  j.events = kept
end

-- What the guide itself says, so creel can compare your logs against it
-- without reading the addon's code.
local function WriteGuideSnapshot()
  local guide = { v = TL.version, zoneSkill = {}, fish = {}, pools = {} }
  for map, base in pairs(D.ZONE_SKILL) do guide.zoneSkill[map] = base end
  for _, fish in ipairs(D.FISH) do
    if not fish.discovered then guide.fish[fish.id] = table.concat(fish.zones, ",") end
  end
  for id, pool in pairs(D.POOLS) do guide.pools[id] = pool.name end
  TL.db.guide = guide
end

TL:On("LOGIN", function()
  InitChar()
  TrimIngested()
  WriteGuideSnapshot()
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("LOOT_OPENED")
ev:RegisterEvent("LOOT_READY")
ev:RegisterEvent("LOOT_CLOSED")
ev:RegisterEvent("UI_ERROR_MESSAGE")
ev:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
ev:SetScript("OnEvent", function(_, event, a, b, c)
  local ok, err
  if event == "LOOT_OPENED" or event == "LOOT_READY" then
    ok, err = pcall(OnLoot)
  elseif event == "LOOT_CLOSED" then
    lootLogged, ok = false, true
  elseif event == "UI_ERROR_MESSAGE" then
    ok, err = pcall(OnUIError, a, b)
  elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
    if a ~= "player" then return end
    ok, err = pcall(function() if IsFishingCast(c) then OnCast() end end)
  end
  if ok == false then TL.Error(err) end
end)
