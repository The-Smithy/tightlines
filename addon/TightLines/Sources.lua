-------------------------------------------------------------------------------
--  TightLines: live data from other addons, read through their public APIs.
--    LibForeverData  where pools and NPCs stand, quest records, item sources
--    QuestieDB       the same, as a fallback when LibForeverData is missing
--  Nothing is copied out of them; without either the guide still lists fish,
--  zones and prices, only the map points and quest details are missing.
-------------------------------------------------------------------------------
local _, TL = ...
local D = TL.Data
local S = {}
TL.Sources = S

local objCache, npcCache, questCache = {}, {}, {}

local function LFD()
  local lib = _G.LibForeverData
  if type(lib) == "table" and type(lib.Get) == "function" then return lib end
end

-------------------------------------------------------------------------------
--  QuestieDB (fallback)
-------------------------------------------------------------------------------
local qdb, qzones

local function Questie()
  if qdb ~= nil then return qdb or nil end
  local db = _G.LibQuestieDB
  if type(db) ~= "table" then return nil end -- may still load: ask again later
  qdb = false
  if type(db.RequireContract) == "function" then
    local ok, fits = pcall(db.RequireContract, 4)
    if not (ok and fits) then ok, fits = pcall(db.RequireContract, 2) end
    if not (ok and fits) then return nil end
  end
  qdb = db
  return db
end

-- QuestieDB keeps its zone tables as the Lua source of a table.
local function LoadTable(src)
  if type(src) == "table" then return src end
  if type(src) ~= "string" then return nil end
  local chunk = loadstring(src)
  if not chunk then return nil end
  setfenv(chunk, {})
  local ok, value = pcall(chunk)
  return ok and type(value) == "table" and value or nil
end

local function QZones()
  if qzones ~= nil then return qzones or nil end
  qzones = false
  local db = Questie()
  if not db then return nil end
  local ok, zoneDB = pcall(function()
    return db.Support and db.Support.Get and db.Support.Get("ZoneDB")
  end)
  local p = ok and type(zoneDB) == "table" and zoneDB.private
  if type(p) ~= "table" then return nil end
  local area = LoadTable(p.areaIdToUiMapId)
  if not area then return nil end
  qzones = {
    area = area,
    parent = LoadTable(p.subZoneToParentZone) or {},
    areaOverride = LoadTable(p.areaIdToUiMapIdOverride) or {},
    parentOverride = LoadTable(p.subZoneToParentZoneOverride) or {},
  }
  return qzones
end

local function AreaToMap(area)
  local z = QZones()
  if not z then return nil end
  local map = z.areaOverride[area] or z.area[area]
  if not map then
    local parent = z.parentOverride[area] or z.parent[area]
    map = parent and (z.areaOverride[parent] or z.area[parent])
  end
  return type(map) == "number" and map or nil
end

-- QuestieDB spawns { [areaId] = { { x, y }, ... } } as { [uiMapID] = { x1, y1, ... } }
local function QuestieSpawns(kind, id)
  local db = Questie()
  local entity = db and db[kind]
  if not (type(entity) == "table" and type(entity.Get) == "function") then return nil end
  local ok, spawns = pcall(entity.Get, id, "spawns")
  if not ok or type(spawns) ~= "table" then return nil end
  local out
  for area, list in pairs(spawns) do
    local map = type(area) == "number" and AreaToMap(area)
    if map and type(list) == "table" then
      out = out or {}
      local l = out[map] or {}
      out[map] = l
      for _, xy in ipairs(list) do
        local x, y = type(xy) == "table" and tonumber(xy[1]), type(xy) == "table" and tonumber(xy[2])
        if x and y and x >= 0 and y >= 0 then
          l[#l + 1] = x
          l[#l + 1] = y
        end
      end
    end
  end
  return out
end

local function QuestieField(kind, id, field)
  local db = Questie()
  local entity = db and db[kind]
  if not (type(entity) == "table" and type(entity.Get) == "function") then return nil end
  local ok, value = pcall(entity.Get, id, field)
  if ok then return value end
end

function S.Status()
  return { lfd = LFD() ~= nil, questie = Questie() ~= nil }
end

function S.HasSpawnData()
  return LFD() ~= nil or QZones() ~= nil
end

-------------------------------------------------------------------------------
--  World position -> zone map. LibForeverData places a point on the smallest
--  map rectangle that holds it, and zone rectangles overlap, so a point near
--  a border can land in the neighbour. The client knows the real zone shapes:
--  ask it (continent position, then the zone under that position), and keep
--  the library's answer for whatever the client can't place.
-------------------------------------------------------------------------------
local function ResolveWorld(instance, wx, wy)
  if not (C_Map and C_Map.GetMapPosFromWorldPos and C_Map.GetMapInfoAtPosition and CreateVector2D) then return nil end
  local vec = CreateVector2D(wx, wy)
  local ok, map, pos = pcall(C_Map.GetMapPosFromWorldPos, instance, vec)
  if not (ok and map and pos) then return nil end
  local px, py = pos:GetXY()
  if not (px and py) then return nil end
  for _ = 1, 3 do
    local info = TL.MapInfo(map)
    if info and info.mapType and info.mapType >= 3 then break end
    local okChild, child = pcall(C_Map.GetMapInfoAtPosition, map, px, py)
    if not (okChild and child and child.mapID and child.mapID ~= map) then break end
    local okPos, _, cpos = pcall(C_Map.GetMapPosFromWorldPos, instance, vec, child.mapID)
    if not (okPos and cpos) then break end
    local cx, cy = cpos:GetXY()
    if not (cx and cy and cx >= 0 and cx <= 1 and cy >= 0 and cy <= 1) then break end
    map, px, py = child.mapID, cx, cy
  end
  local info = TL.MapInfo(map)
  if info and info.mapType and info.mapType >= 3 and px >= 0 and px <= 1 and py >= 0 and py <= 1 then
    return map, math.floor(px * 10000 + 0.5) / 100, math.floor(py * 10000 + 0.5) / 100
  end
end

-- LibForeverData's spawns of an object or NPC as { [uiMapID] = { x1, y1, ... } }
local function LFDSpawns(lib, kind, id)
  if type(lib.Spawns) ~= "function" then return nil end
  local ok, list = pcall(lib.Spawns, kind, id)
  if not ok or type(list) ~= "table" or #list == 0 then return nil end
  local out
  for _, p in ipairs(list) do
    local map, x, y
    if p.map and p.x and p.y then
      map, x, y = ResolveWorld(p.map, p.x, p.y)
      if not map and lib.ToUiMap then map, x, y = lib.ToUiMap(p.map, p.x, p.y) end
    end
    if map and x and y then
      out = out or {}
      local l = out[map] or {}
      out[map] = l
      l[#l + 1] = x
      l[#l + 1] = y
    end
  end
  return out
end

-------------------------------------------------------------------------------
--  Objects (pools), NPCs, quests
-------------------------------------------------------------------------------
-- { [uiMapID] = { x1, y1, x2, y2, ... } } in map percent, or nil
function S.ObjectSpawns(id)
  local cached = objCache[id]
  if cached ~= nil then return cached or nil end
  local out
  local lib = LFD()
  if lib then
    out = LFDSpawns(lib, "object", id)
    if not out then
      local ok, rec = pcall(lib.Get, "object", id)
      if ok and type(rec) == "table" and type(rec.spawns) == "table" then out = rec.spawns end
    end
  end
  if not out then out = QuestieSpawns("Object", id) end
  objCache[id] = out or false
  return out
end

-- { id, name, sub, spawns } or nil
function S.NPC(id)
  local cached = npcCache[id]
  if cached ~= nil then return cached or nil end
  local rec
  local lib = LFD()
  if lib then
    local ok, r = pcall(lib.Get, "npc", id)
    if ok and type(r) == "table" and r.name then
      rec = { id = id, name = r.name, sub = r.subName, spawns = LFDSpawns(lib, "npc", id) or r.spawns }
    end
  end
  if not rec then
    local name = QuestieField("Npc", id, "name")
    if type(name) == "string" then
      rec = { id = id, name = name, sub = QuestieField("Npc", id, "subName"), spawns = QuestieSpawns("Npc", id) }
    end
  end
  local fallback = D.NPC_FALLBACK[id]
  if not rec and fallback then rec = { id = id, name = fallback[2] } end
  if rec and fallback and not rec.sub then rec.sub = fallback[3] end
  npcCache[id] = rec or false
  return rec
end

local function IDs(list)
  local out = {}
  for _, v in ipairs(type(list) == "table" and list or {}) do
    if type(v) == "number" then out[#out + 1] = v end
  end
  return out
end

-- A quest in one shape whichever database it came from:
-- { id, name, level, minLevel, side (1 Alliance, 2 Horde, nil both), starters,
--   starterObjects, finishers, objectives { { kind, id, count } },
--   rewards { { kind, id, count } }, money }
function S.Quest(id)
  local cached = questCache[id]
  if cached ~= nil then return cached or nil end
  local q
  local lib = LFD()
  if lib and lib.Quest then
    local ok, r = pcall(lib.Quest, id)
    if ok and type(r) == "table" and r.name then
      q = {
        id = id, name = r.name, level = r.level, minLevel = r.minLevel, money = r.money,
        side = (r.side == 1 or r.side == 2) and r.side or nil,
        starters = {}, starterObjects = {}, finishers = {}, objectives = {}, rewards = {},
      }
      for _, e in ipairs(r.start or {}) do
        if e.kind == "npc" then q.starters[#q.starters + 1] = e.id
        elseif e.kind == "object" then q.starterObjects[#q.starterObjects + 1] = e.id end
      end
      for _, e in ipairs(r.finish or {}) do
        if e.kind == "npc" then q.finishers[#q.finishers + 1] = e.id end
      end
      for _, o in ipairs(r.objectives or {}) do
        if o.target then q.objectives[#q.objectives + 1] = { kind = o.kind, id = o.target, count = o.count or 1 } end
      end
      for _, o in ipairs(r.rewards or {}) do
        if o.id and (o.kind == "item" or o.kind == "choice") then
          q.rewards[#q.rewards + 1] = { kind = o.kind, id = o.id, count = o.count or 1 }
        end
      end
    end
  end
  if not q then
    local name = QuestieField("Quest", id, "name")
    if type(name) == "string" then
      local startedBy, finishedBy = QuestieField("Quest", id, "startedBy"), QuestieField("Quest", id, "finishedBy")
      q = {
        id = id, name = name,
        level = tonumber(QuestieField("Quest", id, "questLevel")),
        minLevel = tonumber(QuestieField("Quest", id, "requiredLevel")),
        starters = IDs(type(startedBy) == "table" and startedBy[1]),
        starterObjects = IDs(type(startedBy) == "table" and startedBy[2]),
        finishers = IDs(type(finishedBy) == "table" and finishedBy[1]),
        objectives = {}, rewards = {},
      }
      local objectives = QuestieField("Quest", id, "objectives")
      local items = type(objectives) == "table" and objectives[3]
      for _, o in ipairs(type(items) == "table" and items or {}) do
        if type(o) == "table" and type(o[1]) == "number" then
          q.objectives[#q.objectives + 1] = { kind = "item", id = o[1], count = 1 }
        end
      end
      local races = tonumber(QuestieField("Quest", id, "requiredRaces")) or 0
      local db = Questie()
      local masks = db and db.Enum and db.Enum.factionRaceMasks
      if races ~= 0 and masks and bit then
        local alliance = bit.band(races, masks.Alliance or 0) ~= 0
        local horde = bit.band(races, masks.Horde or 0) ~= 0
        if alliance ~= horde then q.side = alliance and 1 or 2 end
      end
    end
  end
  questCache[id] = q or false
  return q
end

-- Pools an item is caught from, as the item database knows it.
function S.ItemPools(itemID)
  local out = {}
  local lib = LFD()
  if lib then
    local ok, rec = pcall(lib.Get, "item", itemID)
    if ok and type(rec) == "table" then
      for _, src in ipairs(rec.sources or {}) do
        if src.kind == "object" and D.POOLS[src.id] then out[#out + 1] = src.id end
      end
    end
  end
  return out
end

-------------------------------------------------------------------------------
--  Maps
-------------------------------------------------------------------------------
local function IsZone(mapID)
  local info = TL.MapInfo(mapID)
  if not info or info.mapType == nil then return true end
  return info.mapType >= 3
end
S.IsZone = IsZone

-- The map most of the spawns are on, and one spot there.
function S.Location(spawns)
  local best, n
  for map, list in pairs(spawns or {}) do
    if IsZone(map) and #list >= 2 and (not n or #list > n) then best, n = map, #list end
  end
  if not best then
    for map, list in pairs(spawns or {}) do
      if #list >= 2 then best = map break end
    end
  end
  local list = best and spawns[best]
  if list then return best, list[1], list[2] end
end

function S.LocationText(spawns)
  local map, x, y = S.Location(spawns)
  if not map then return nil end
  return ("%s (%.0f, %.0f)"):format(TL.MapName(map), x, y), map
end

local function ZoneSort(a, b)
  local la, lb = TL.ZoneSkill(a), TL.ZoneSkill(b)
  if (la or 999) ~= (lb or 999) then return (la or 999) < (lb or 999) end
  return TL.MapName(a) < TL.MapName(b)
end
S.ZoneSort = ZoneSort

-------------------------------------------------------------------------------
--  The index: which fish is found where, from the guide's data, the pools'
--  spawns and your own catch log. Built on first use, rebuilt when the log
--  learns something new.
-------------------------------------------------------------------------------
function TL:Index()
  if self.index then return self.index end
  local idx = { byZone = {}, zones = {} }
  local catches = (TL.db and TL.db.catches) or {}
  -- Catches your logs found that the guide does not list (creel, Generated.lua)
  local gen = (TL.Generated and TL.Generated.fish) or {}
  for id, g in pairs(gen) do
    if not D.FISH_BY_ID[id] then
      local f = { id = id, name = g.name or ("Item #" .. id), cat = "new", water = "any", zones = {}, discovered = true }
      D.FISH[#D.FISH + 1] = f
      D.FISH_BY_ID[id] = f
      D.NAMES[id] = f.name
    end
  end
  for _, fish in ipairs(D.FISH) do
    local zoneSet, poolSet = {}, {}
    for _, z in ipairs(fish.zones) do zoneSet[z] = true end
    for _, p in ipairs(fish.pools or {}) do poolSet[p] = true end
    for _, p in ipairs(S.ItemPools(fish.id)) do poolSet[p] = true end
    for p in pairs(poolSet) do
      for map, list in pairs(S.ObjectSpawns(p) or {}) do
        if #list >= 2 and IsZone(map) then zoneSet[map] = true end
      end
    end
    for map, log in pairs(catches) do
      if log.items and log.items[fish.id] then zoneSet[map] = true end
    end
    for map in pairs((gen[fish.id] and gen[fish.id].zones) or {}) do zoneSet[map] = true end
    fish.zoneSet, fish.poolSet, fish.zoneList, fish.req = zoneSet, poolSet, {}, nil
    for z in pairs(zoneSet) do
      fish.zoneList[#fish.zoneList + 1] = z
      idx.byZone[z] = idx.byZone[z] or {}
      idx.byZone[z][fish.id] = true
      local low = TL.ZoneSkill(z)
      if low and (not fish.req or low < fish.req) then fish.req = low end
    end
    table.sort(fish.zoneList, ZoneSort)
  end
  for z in pairs(D.ZONE_SKILL) do idx.zones[z] = true end
  for z in pairs(idx.byZone) do idx.zones[z] = true end
  for _, z in ipairs(D.EXTRA_ZONES) do idx.zones[z] = true end
  for z in pairs(catches) do idx.zones[z] = true end
  for z in pairs((TL.Generated and TL.Generated.zones) or {}) do idx.zones[z] = true end
  self.index = idx
  return idx
end

-- Pools that spawn on a map: { { pool, count }, ... } by name, most first.
function TL.ZonePools(mapID)
  local byName, out = {}, {}
  for id, pool in pairs(D.POOLS) do
    local list = (S.ObjectSpawns(id) or {})[mapID]
    if list and #list >= 2 then
      local e = byName[pool.name]
      if not e then
        e = { pool = pool, count = 0 }
        byName[pool.name] = e
        out[#out + 1] = e
      end
      e.count = e.count + #list / 2
    end
  end
  table.sort(out, function(a, b) return a.count > b.count end)
  return out
end

-------------------------------------------------------------------------------
--  Map points: { x, y (map percent), kind, color, tip, sub }
--    pool      a school or wreckage spawn point
--    hint      a pool spawn of the same kind of water: fish bite there too
--    catch     where you landed one (catch log)
--    quest / questEnd / npc
-------------------------------------------------------------------------------
local function AddSpawnPoints(out, spawns, mapID, base, cap)
  local list = spawns and spawns[mapID]
  if type(list) ~= "table" then return 0 end
  local n = 0
  for i = 1, #list - 1, 2 do
    local x, y = list[i], list[i + 1]
    if x and y and x >= 0 and x <= 100 and y >= 0 and y <= 100 then
      local pt = { x = x, y = y }
      for k, v in pairs(base) do pt[k] = v end
      out[#out + 1] = pt
      n = n + 1
      if cap and n >= cap then break end
    end
  end
  return n
end

function TL.PoolPoints(out, poolID, mapID, kind, cap)
  local pool = D.POOLS[poolID]
  return AddSpawnPoints(out, S.ObjectSpawns(poolID), mapID, {
    kind = kind, color = kind == "pool" and pool and pool.color or nil,
    tip = pool and pool.name or "Fishing pool",
    sub = kind == "hint" and "Pools spawn in this water: a good place to cast." or "Pool spawn point",
  }, cap)
end

local function AddCatchPoints(out, mapID, itemID)
  local log = TL.db and TL.db.catches[mapID]
  for _, s in ipairs(log and log.spots or {}) do
    if not itemID or s[3] == itemID then
      out[#out + 1] = { x = s[1], y = s[2], kind = "catch", tip = TL.ItemName(s[3]), sub = "You caught this here." }
    end
  end
end

local HINT_CAP = 70

-- Spots creel worked out from your logs: { x, y, count, x, y, count, ... }
local function AddSpots(out, list, tip, kind, color)
  local n = 0
  for i = 1, #(list or {}) - 2, 3 do
    local count = list[i + 2]
    out[#out + 1] = {
      x = list[i], y = list[i + 1], kind = kind or "spot", color = color, tip = tip,
      sub = count .. (count == 1 and " catch" or " catches") .. " logged around here.",
    }
    n = n + 1
  end
  return n
end

local function GeneratedFish(id)
  return TL.Generated and TL.Generated.fish and TL.Generated.fish[id] or nil
end

-- Where a fish is found on a map. Returns the points and how many are pools.
function TL.FishPoints(fish, mapID)
  TL:Index()
  local out, pools = {}, 0
  for p in pairs(fish.poolSet or {}) do
    pools = pools + TL.PoolPoints(out, p, mapID, "pool")
  end
  local g = GeneratedFish(fish.id)
  local logged = AddSpots(out, g and g.zones and g.zones[mapID] and g.zones[mapID].spots, (TL.ItemName(fish.id)))
  local water = fish.water == "inland" and "inland" or (fish.water ~= "any" and "coastal") or nil
  if pools == 0 and logged == 0 and water and fish.zoneSet[mapID] and TL.db and TL.db.settings.hints then
    local n = 0
    for _, p in ipairs(D.WATER_POOLS[water]) do
      n = n + TL.PoolPoints(out, p, mapID, "hint", HINT_CAP - n)
      if n >= HINT_CAP then break end
    end
  end
  AddCatchPoints(out, mapID, fish.id)
  return out, pools
end

-- Every pool on a map and everything you caught there.
function TL.ZonePoints(mapID)
  local out = {}
  for id in pairs(D.POOLS) do TL.PoolPoints(out, id, mapID, "pool") end
  local G = TL.Generated or {}
  for id, pool in pairs(G.pools or {}) do
    local known = D.POOLS[id]
    AddSpots(out, pool.spots and pool.spots[mapID], (known and known.name) or pool.name or "Fishing pool", "pool", known and known.color)
  end
  for id, g in pairs(G.fish or {}) do
    AddSpots(out, g.zones and g.zones[mapID] and g.zones[mapID].spots, (TL.ItemName(id)))
  end
  AddCatchPoints(out, mapID)
  return out
end

function TL.NPCPoints(npcID, mapID, kind, sub)
  local out = {}
  local npc = S.NPC(npcID)
  if npc then
    AddSpawnPoints(out, npc.spawns, mapID, { kind = kind or "npc", tip = npc.name, sub = sub or npc.sub })
  end
  return out
end

function TL.QuestPoints(q, mapID)
  local out, isStarter = {}, {}
  for _, id in ipairs(q.starters) do
    isStarter[id] = true
    for _, pt in ipairs(TL.NPCPoints(id, mapID, "quest", "Starts: " .. q.name)) do out[#out + 1] = pt end
  end
  for _, id in ipairs(q.starterObjects) do
    AddSpawnPoints(out, S.ObjectSpawns(id), mapID, { kind = "quest", tip = q.name, sub = "Starts here" })
  end
  for _, id in ipairs(q.finishers) do
    if not isStarter[id] then
      for _, pt in ipairs(TL.NPCPoints(id, mapID, "questEnd", "Turn in: " .. q.name)) do out[#out + 1] = pt end
    end
  end
  for _, o in ipairs(q.objectives) do
    local fish = o.kind == "item" and D.FISH_BY_ID[o.id]
    if fish then
      for _, pt in ipairs(TL.FishPoints(fish, mapID)) do out[#out + 1] = pt end
    end
  end
  return out
end

local function AddMaps(set, list, spawns)
  for map, pts in pairs(spawns or {}) do
    if #pts >= 2 and IsZone(map) and not set[map] then
      set[map] = true
      list[#list + 1] = map
    end
  end
end

function TL.QuestMaps(q)
  local set, list = {}, {}
  for _, id in ipairs(q.starters) do AddMaps(set, list, (S.NPC(id) or {}).spawns) end
  for _, id in ipairs(q.starterObjects) do AddMaps(set, list, S.ObjectSpawns(id)) end
  for _, id in ipairs(q.finishers) do AddMaps(set, list, (S.NPC(id) or {}).spawns) end
  TL:Index()
  for _, o in ipairs(q.objectives) do
    local fish = o.kind == "item" and D.FISH_BY_ID[o.id]
    for _, z in ipairs(fish and fish.zoneList or {}) do
      if not set[z] then set[z] = true; list[#list + 1] = z end
    end
  end
  return list
end

-- What is being tracked on the world map: { kind = fish|zone|quest|npc, id }
function TL.TrackPoints(t, mapID)
  if t.kind == "fish" then
    local fish = D.FISH_BY_ID[t.id]
    return fish and TL.FishPoints(fish, mapID) or {}
  elseif t.kind == "zone" then
    return t.id == mapID and TL.ZonePoints(mapID) or {}
  elseif t.kind == "quest" then
    local q = S.Quest(t.id)
    return q and TL.QuestPoints(q, mapID) or {}
  elseif t.kind == "npc" then
    return TL.NPCPoints(t.id, mapID)
  end
  return {}
end

function TL.TrackMaps(t)
  if t.kind == "fish" then
    TL:Index()
    local fish = D.FISH_BY_ID[t.id]
    return fish and fish.zoneList or {}
  elseif t.kind == "zone" then
    return { t.id }
  elseif t.kind == "quest" then
    local q = S.Quest(t.id)
    return q and TL.QuestMaps(q) or {}
  elseif t.kind == "npc" then
    local set, list = {}, {}
    AddMaps(set, list, (S.NPC(t.id) or {}).spawns)
    return list
  end
  return {}
end

function TL.TrackName(t)
  if not t then return nil end
  if t.kind == "fish" then return (TL.ItemName(t.id)) end
  if t.kind == "zone" then return TL.MapName(t.id) .. " pools" end
  if t.kind == "quest" then
    local q = S.Quest(t.id)
    return q and q.name or ("quest " .. t.id)
  end
  if t.kind == "npc" then
    local npc = S.NPC(t.id)
    return npc and npc.name or ("NPC " .. t.id)
  end
end
