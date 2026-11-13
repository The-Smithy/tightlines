-------------------------------------------------------------------------------
--  TightLines: the guide's own data. Game facts only (ids, zone skills, which
--  water a fish lives in). Where things stand on the map is read at runtime
--  from LibForeverData / QuestieDB (Sources.lua), and what you actually catch
--  is learned by the catch log, so zones WoW Forever added fill in as you fish.
-------------------------------------------------------------------------------
local _, TL = ...
local D = {}
TL.Data = D

-- Fish stop getting away this many points above a zone's base skill.
D.NO_GETAWAY = 95

-- uiMapID = the zone's base fishing skill (fish bite from it, at least 1).
D.ZONE_SKILL = {
  -- Eastern Kingdoms
  [1426] = -70, [1429] = -70, [1420] = -70,                 -- Dun Morogh, Elwynn Forest, Tirisfal Glades
  [1432] = -20, [1436] = -20, [1421] = -20,                 -- Loch Modan, Westfall, Silverpine Forest
  [1453] = -20, [1455] = -20, [1458] = -20,                 -- Stormwind City, Ironforge, Undercity
  [1433] = 55, [1431] = 55, [1437] = 55, [1424] = 55,       -- Redridge, Duskwood, Wetlands, Hillsbrad
  [1416] = 130, [1417] = 130, [1434] = 130, [1435] = 130,   -- Alterac, Arathi, Stranglethorn, Swamp of Sorrows
  [1425] = 205, [1422] = 205,                               -- The Hinterlands, Western Plaguelands
  [1423] = 330, [1428] = 330, [1430] = 330,                 -- Eastern Plaguelands, Burning Steppes, Deadwind Pass
  -- Kalimdor
  [1411] = -70, [1412] = -70, [1438] = -70,                 -- Durotar, Mulgore, Teldrassil
  [1439] = -20, [1413] = -20,                               -- Darkshore, The Barrens
  [1454] = -20, [1456] = -20, [1457] = -20,                 -- Orgrimmar, Thunder Bluff, Darnassus
  [1442] = 55, [1440] = 55,                                 -- Stonetalon Mountains, Ashenvale
  [1441] = 130, [1443] = 130, [1445] = 130,                 -- Thousand Needles, Desolace, Dustwallow Marsh
  [1444] = 205, [1446] = 205, [1447] = 205, [1448] = 205,   -- Feralas, Tanaris, Azshara, Felwood
  [1449] = 205, [1450] = 205,                               -- Un'Goro Crater, Moonglade
  [1451] = 330, [1452] = 330,                               -- Silithus, Winterspring
}

-- Zones WoW Forever added: their fishing skill isn't known yet. They are
-- listed so pools and your own catches there still show.
D.EXTRA_ZONES = { 2548, 2482, 2652, 2521 }

-- Names used only until the client answers C_Map.GetMapInfo.
D.ZONE_NAMES = {
  [1426] = "Dun Morogh", [1429] = "Elwynn Forest", [1420] = "Tirisfal Glades", [1432] = "Loch Modan",
  [1436] = "Westfall", [1421] = "Silverpine Forest", [1453] = "Stormwind City", [1455] = "Ironforge",
  [1458] = "Undercity", [1433] = "Redridge Mountains", [1431] = "Duskwood", [1437] = "Wetlands",
  [1424] = "Hillsbrad Foothills", [1416] = "Alterac Mountains", [1417] = "Arathi Highlands",
  [1434] = "Stranglethorn Vale", [1435] = "Swamp of Sorrows", [1425] = "The Hinterlands",
  [1422] = "Western Plaguelands", [1423] = "Eastern Plaguelands", [1428] = "Burning Steppes",
  [1430] = "Deadwind Pass", [1411] = "Durotar", [1412] = "Mulgore", [1438] = "Teldrassil",
  [1439] = "Darkshore", [1413] = "The Barrens", [1454] = "Orgrimmar", [1456] = "Thunder Bluff",
  [1457] = "Darnassus", [1442] = "Stonetalon Mountains", [1440] = "Ashenvale", [1441] = "Thousand Needles",
  [1443] = "Desolace", [1445] = "Dustwallow Marsh", [1444] = "Feralas", [1446] = "Tanaris",
  [1447] = "Azshara", [1448] = "Felwood", [1449] = "Un'Goro Crater", [1450] = "Moonglade",
  [1451] = "Silithus", [1452] = "Winterspring", [1414] = "Kalimdor", [1415] = "Eastern Kingdoms",
  [2548] = "Riverglades", [2482] = "Mount Hyjal", [2652] = "Shen'dralas", [2521] = "Zephras Isle",
}

-------------------------------------------------------------------------------
--  Fish
--    cat     fish | reagent | event | quest | treasure
--    water   inland | coastal | pool (only from schools)
--    zones   uiMapIDs it is fished in open water (pool zones are added at
--            runtime from where the pools spawn)
--    cooked  what Cooking turns it into
--    time    day | night        season  summer | winter
-------------------------------------------------------------------------------
D.FISH, D.FISH_BY_ID, D.NAMES = {}, {}, {}

local function Fish(id, name, cat, water, zones, extra)
  local f = { id = id, name = name, cat = cat, water = water, zones = zones or {} }
  if extra then
    for k, v in pairs(extra) do f[k] = v end
  end
  D.FISH[#D.FISH + 1] = f
  D.FISH_BY_ID[id] = f
  D.NAMES[id] = name
  return f
end

local STARTER = { 1429, 1426, 1420, 1411, 1412, 1438, 1432, 1436, 1421, 1439, 1413, 1453, 1455, 1458, 1454, 1456, 1457 }
local MUD_SNAPPER = { 1429, 1426, 1420, 1412, 1438, 1432, 1421, 1439, 1413, 1436, 1453, 1458, 1456, 1457 }
local CATFISH = { 1433, 1431, 1437, 1424, 1440, 1442, 1436, 1432, 1421, 1413, 1439 }
local TROUT = { 1417, 1416, 1434, 1435, 1443, 1445, 1441, 1424 }
local REDGILL = { 1425, 1444, 1449, 1448, 1447, 1422, 1450 }
local HIGH_INLAND = { 1448, 1422, 1423, 1452, 1449, 1447, 1444, 1450, 1425 }
local SALMON = { 1423, 1452, 1451, 1428, 1430 }
local HIGH_COAST = { 1434, 1446, 1444, 1447, 1425, 1445 }

-- Cooking and trade fish
Fish(6291, "Raw Brilliant Smallfish", "fish", "inland", STARTER, { cooked = 6290 })
Fish(6289, "Raw Longjaw Mud Snapper", "fish", "inland", MUD_SNAPPER, { cooked = 4592 })
Fish(6303, "Raw Slitherskin Mackerel", "fish", "coastal", { 1411, 1436, 1438, 1439, 1413, 1420, 1421 }, { cooked = 787 })
Fish(6317, "Raw Loch Frenzy", "fish", "inland", { 1432, 1426, 1455 }, { cooked = 6316 })
Fish(6361, "Raw Rainbow Fin Albacore", "fish", "coastal", { 1436, 1439, 1413, 1421, 1437, 1424 }, { cooked = 5095 })
Fish(6308, "Raw Bristle Whisker Catfish", "fish", "inland", CATFISH, { cooked = 4593 })
Fish(21071, "Raw Sagefish", "fish", "pool", {}, { cooked = 21072,
  note = "Only from Sagefish Schools in rivers and lakes. Smoked Sagefish restores mana: popular with casters." })
Fish(6358, "Oily Blackmouth", "fish", "coastal", { 1436, 1439, 1413, 1437, 1421, 1424, 1440 },
  { note = "Alchemy: Blackmouth Oil (Free Action and Swiftness potions). Schools give far more than open water." })
Fish(6359, "Firefin Snapper", "fish", "coastal", { 1437, 1417, 1434, 1443, 1445, 1424, 1440 },
  { note = "Alchemy: Fire Oil. Schools give far more than open water." })
Fish(6362, "Raw Rockscale Cod", "fish", "coastal", { 1437, 1424, 1417, 1434, 1443, 1445, 1440 }, { cooked = 4594 })
Fish(8365, "Raw Mithril Head Trout", "fish", "inland", TROUT, { cooked = 8364 })
Fish(21153, "Raw Greater Sagefish", "fish", "pool", {}, { cooked = 21217,
  note = "Only from Greater Sagefish Schools. Sagefish Delight is strong mana food." })
Fish(4603, "Raw Spotted Yellowtail", "fish", "coastal", HIGH_COAST, { cooked = 6887 })
Fish(13754, "Raw Glossy Mightfish", "fish", "coastal", HIGH_COAST, { cooked = 13927 })
Fish(13758, "Raw Redgill", "fish", "inland", REDGILL, { cooked = 13930 })
Fish(13756, "Raw Summer Bass", "fish", "inland", { 1425, 1444, 1449, 1448, 1422, 1452, 1423 },
  { cooked = 13929, season = "summer" })
Fish(13755, "Winter Squid", "fish", "coastal", { 1446, 1447, 1444, 1434, 1425 },
  { cooked = 13928, season = "winter", note = "Grilled Squid gives Agility: always in demand with raiders." })
Fish(13759, "Raw Nightfin Snapper", "fish", "inland", HIGH_INLAND,
  { cooked = 13931, time = "night", note = "Nightfin Soup restores mana over time: a raid staple." })
Fish(13760, "Raw Sunscale Salmon", "fish", "inland", HIGH_INLAND, { cooked = 13932, time = "day" })
Fish(13889, "Raw Whitescale Salmon", "fish", "inland", SALMON, { cooked = 13935 })
Fish(13893, "Large Raw Mightfish", "fish", "coastal", { 1447, 1444, 1446 }, { cooked = 13934 })
Fish(13888, "Darkclaw Lobster", "fish", "coastal", { 1447, 1444, 1446 }, { cooked = 13933 })
Fish(13422, "Stonescale Eel", "fish", "pool", { 1447, 1444, 1446 },
  { note = "Alchemy: Stonescale Oil (Flask of the Titans, Greater Stoneshield). Best from Stonescale Eel Swarms." })
Fish(13757, "Lightning Eel", "fish", "coastal", { 1447 }, { note = "Turn-in for the Argent Dawn Craftsman's Writ." })
Fish(13890, "Plated Armorfish", "fish", "inland", { 1447, 1423, 1452 }, { note = "Turn-in for the Argent Dawn Craftsman's Writ." })
Fish(6522, "Deviate Fish", "fish", "pool", { 1413 },
  { cooked = 6657, note = "The oases of the Barrens and inside Wailing Caverns. Savory Deviate Delight sells well." })

-- Reagents
Fish(7070, "Elemental Water", "reagent", "pool", {}, { note = "From Patches of Elemental Water." })
Fish(3820, "Stranglekelp", "reagent", "coastal", { 1437, 1434, 1436, 1439, 1440, 1443, 1445, 1413 },
  { note = "The herb also comes up on the hook in coastal water." })
Fish(7973, "Big-mouth Clam", "reagent", "coastal", {}, { note = "Open it for clam meat and the odd pearl." })

-- Rare and event fish
local EXTRAVAGANZA = "Stranglethorn Fishing Extravaganza: caught from Schools of Tastyfish along the Stranglethorn coast."
Fish(19807, "Speckled Tastyfish", "event", "pool", { 1434 }, { note = EXTRAVAGANZA })
Fish(19805, "Keefer's Angelfish", "event", "pool", { 1434 }, { note = EXTRAVAGANZA .. " Rare: turn it in for a reward." })
Fish(19806, "Dezian Queenfish", "event", "pool", { 1434 }, { note = EXTRAVAGANZA .. " Rare: turn it in for a reward." })
Fish(19803, "Brownell's Blue Striped Racer", "event", "pool", { 1434 }, { note = EXTRAVAGANZA .. " Rare: turn it in for a reward." })

-- Quest fish
Fish(16967, "Feralas Ahi", "quest", "inland", { 1444 }, { note = "Nat Pagle, Angler Extreme: the Verdantis River in Feralas." })
Fish(16968, "Sar'theris Striker", "quest", "coastal", { 1443 }, { note = "Nat Pagle, Angler Extreme: Sar'theris Strand in Desolace." })
Fish(16969, "Savage Coast Blue Sailfin", "quest", "coastal", { 1434 }, { note = "Nat Pagle, Angler Extreme: the Savage Coast of Stranglethorn Vale." })
Fish(16970, "Misty Reed Mahi Mahi", "quest", "coastal", { 1435 }, { note = "Nat Pagle, Angler Extreme: Misty Reed Strand in the Swamp of Sorrows." })
Fish(12238, "Darkshore Grouper", "quest", "coastal", { 1439 }, { note = "The Family and the Fishing Pole: the coast of Darkshore." })
Fish(6717, "Gaffer Jack", "quest", "coastal", { 1413 }, { note = "Gaffer Jacks: fished from the water off Ratchet." })
Fish(6718, "Electropeller", "quest", "coastal", { 1413 }, { note = "Electropellers: fished from the water off Ratchet." })
Fish(13546, "Bloodbelly Fish", "quest", "coastal", { 1443 }, { note = "Catch of the Day (Horde): the coast of Desolace." })

-- Treasure and bloated fish
local TREASURE = { 6351, 6352, 6353, 6354, 6355, 6357, 13874, 13875, 13918, 21113, 21150, 21228, 7973, 6307 }
Fish(6351, "Dented Crate", "treasure", "pool")
Fish(6352, "Waterlogged Crate", "treasure", "pool")
Fish(6353, "Small Chest", "treasure", "pool")
Fish(6354, "Small Locked Chest", "treasure", "pool")
Fish(6355, "Sturdy Locked Chest", "treasure", "pool")
Fish(6357, "Sealed Crate", "treasure", "pool")
Fish(13874, "Heavy Crate", "treasure", "pool")
Fish(13875, "Ironbound Locked Chest", "treasure", "pool")
Fish(13918, "Reinforced Locked Chest", "treasure", "pool")
Fish(21113, "Watertight Trunk", "treasure", "pool")
Fish(21150, "Iron Bound Trunk", "treasure", "pool")
Fish(21228, "Mithril Bound Trunk", "treasure", "pool")
Fish(6307, "Message in a Bottle", "treasure", "coastal", {}, { note = "A rare catch from wreckage and coastal water." })
Fish(6643, "Bloated Smallfish", "treasure", "inland", STARTER, { note = "Open it: there may be something inside." })
Fish(6645, "Bloated Mud Snapper", "treasure", "inland", MUD_SNAPPER, { note = "Open it: there may be something inside." })
Fish(6647, "Bloated Catfish", "treasure", "inland", CATFISH, { note = "Open it: there may be something inside." })
Fish(8366, "Bloated Trout", "treasure", "inland", TROUT, { note = "Open it: there may be something inside." })
Fish(13881, "Bloated Redgill", "treasure", "inland", REDGILL, { note = "Open it: there may be something inside." })
Fish(13891, "Bloated Salmon", "treasure", "inland", SALMON, { note = "Open it: there may be something inside." })

-------------------------------------------------------------------------------
--  Pools (game object ids of fishing holes). Where each one spawns comes from
--  LibForeverData / QuestieDB at runtime.
-------------------------------------------------------------------------------
D.POOLS = {}
D.WATER_POOLS = { coastal = {}, inland = {} }

local function Pool(ids, name, water, color, fish, noHint)
  for _, id in ipairs(ids) do
    D.POOLS[id] = { id = id, name = name, water = water, color = color, fish = fish }
    if not noHint then table.insert(D.WATER_POOLS[water], id) end
    for _, fishID in ipairs(fish) do
      local f = D.FISH_BY_ID[fishID]
      if f then
        f.pools = f.pools or {}
        table.insert(f.pools, id)
      end
    end
  end
end

Pool({ 180582, 180664, 180682, 180750, 180900 }, "Oily Blackmouth School", "coastal", { 0.55, 0.62, 0.9 }, { 6358 })
Pool({ 180657, 180683, 180752, 180902 }, "Firefin Snapper School", "coastal", { 1, 0.5, 0.2 }, { 6359 })
Pool({ 180656, 180663 }, "Sagefish School", "inland", { 0.5, 0.95, 0.45 }, { 21071 })
Pool({ 180684 }, "Greater Sagefish School", "inland", { 0.2, 0.9, 0.7 }, { 21153 })
Pool({ 180658 }, "School of Deviate Fish", "inland", { 0.8, 0.45, 1 }, { 6522 })
Pool({ 180712 }, "Stonescale Eel Swarm", "coastal", { 0.9, 0.9, 0.35 }, { 13422 })
Pool({ 180655 }, "Floating Debris", "coastal", { 0.82, 0.66, 0.45 }, TREASURE)
Pool({ 180662, 180685, 180751, 180901 }, "Floating Wreckage", "coastal", { 0.82, 0.66, 0.45 }, TREASURE)
Pool({ 180661 }, "Oil Spill", "coastal", { 0.5, 0.5, 0.56 }, { 6358, 6359 })
Pool({ 180753 }, "Patch of Elemental Water", "coastal", { 0.55, 0.85, 1 }, { 7070 }, true)
Pool({ 180248 }, "School of Tastyfish", "coastal", { 1, 0.55, 0.8 }, { 19807, 19805, 19806, 19803, 13422 }, true)
Pool({ 180184 }, "School of Fish", "inland", { 0.6, 0.85, 0.95 }, {}, true)

-------------------------------------------------------------------------------
--  Fishing quests (names, levels, givers and rewards come from the databases)
-------------------------------------------------------------------------------
D.QUESTS = {
  { id = 95065, group = "WoW Forever", note = "A first fishing errand in Stormwind." },
  { id = 96050, group = "WoW Forever" }, { id = 97904, group = "WoW Forever" }, { id = 97920, group = "WoW Forever" },
  { id = 97932, group = "WoW Forever" }, { id = 97943, group = "WoW Forever" }, { id = 97956, group = "WoW Forever" },
  { id = 97967, group = "WoW Forever" },
  { id = 97065, group = "WoW Forever" }, { id = 97066, group = "WoW Forever" }, { id = 97067, group = "WoW Forever" },

  { id = 1141, group = "Quest Fish", note = "Fish Darkshore Grouper from the coast. Rewards the Blump Family Fishing Pole." },
  { id = 1579, group = "Quest Fish", note = "Gaffer Jacks come up on the hook in the water off Ratchet." },
  { id = 1580, group = "Quest Fish", note = "Electropellers too. Rewards Aquadynamic Fish Lenses (+50 lure)." },
  { id = 5386, group = "Quest Fish", note = "Bloodbelly Fish from the coast of Desolace." },

  { id = 6608, group = "Artisan Fishing", note = "The Horde's pointer to Nat Pagle." },
  { id = 6609, group = "Artisan Fishing", note = "The Alliance's pointer to Nat Pagle." },
  { id = 6607, group = "Artisan Fishing", note = "Needs Fishing 225. Catch one rare fish in each of four zones; Nat then teaches Artisan Fishing (to 300)." },
  { id = 7815, group = "Artisan Fishing", note = "Rewards Nat Pagle's Extreme Angler FC-5000 (+25 pole)." },
  { id = 7816, group = "Artisan Fishing" },

  { id = 8228, group = "Fishing Extravaganza" }, { id = 8229, group = "Fishing Extravaganza" },
  { id = 8193, group = "Fishing Extravaganza", note = "Be the first to hand in 40 Speckled Tastyfish. Rewards the Arcanite Fishing Pole (+35) or the Hook of the Master Angler." },
  { id = 8194, group = "Fishing Extravaganza", note = "Hand in Speckled Tastyfish after a winner is called." },
  { id = 8221, group = "Fishing Extravaganza", note = "Rewards the Lucky Fishing Hat (+5)." },
  { id = 8224, group = "Fishing Extravaganza", note = "Rewards High Test Eternium Fishing Line (+5 on a pole)." },
  { id = 8225, group = "Fishing Extravaganza", note = "Rewards Nat Pagle's Extreme Anglin' Boots (+5)." },

  { id = 9205, group = "Argent Dawn Writs", note = "30 Plated Armorfish." },
  { id = 9206, group = "Argent Dawn Writs", note = "30 Lightning Eel." },
}
D.QUEST_GROUPS = { "WoW Forever", "Quest Fish", "Artisan Fishing", "Fishing Extravaganza", "Argent Dawn Writs" }

-------------------------------------------------------------------------------
--  Gear: poles, lures and the rest
-------------------------------------------------------------------------------
D.GEAR = {
  { id = 6256, kind = "Poles", bonus = 0, source = "Sold by fishing trainers and suppliers." },
  { id = 12225, kind = "Poles", bonus = 3, source = "Reward: The Family and the Fishing Pole (Darkshore).", quest = 1141 },
  { id = 6365, kind = "Poles", bonus = 5, source = "Sold by fishing suppliers." },
  { id = 6366, kind = "Poles", bonus = 15, source = "Sold in limited supply by a few fishing suppliers; watch the Auction House." },
  { id = 6367, kind = "Poles", bonus = 20, source = "Uncommon: watch the Auction House." },
  { id = 19022, kind = "Poles", bonus = 25, source = "Reward: Snapjaws, Mon! in The Hinterlands.", quest = 7815 },
  { id = 19970, kind = "Poles", bonus = 35, source = "Reward: Master Angler (Stranglethorn Fishing Extravaganza).", quest = 8193 },

  { id = 6529, kind = "Lures", bonus = 25, source = "Sold by fishing suppliers. Lasts 10 minutes." },
  { id = 6530, kind = "Lures", bonus = 50, source = "Sold by fishing suppliers. Lasts 10 minutes." },
  { id = 6811, kind = "Lures", bonus = 50, source = "Reward: Electropellers (Ratchet). Lasts 10 minutes.", quest = 1580 },
  { id = 6532, kind = "Lures", bonus = 75, source = "Sold by fishing suppliers. Lasts 10 minutes." },
  { id = 7307, kind = "Lures", bonus = 75, source = "Watch the Auction House. Lasts 10 minutes." },
  { id = 6533, kind = "Lures", bonus = 100, source = "Made by Engineers. Lasts 5 minutes." },

  { id = 19972, kind = "Worn Gear", bonus = 5, source = "Reward: Rare Fish - Keefer's Angelfish.", quest = 8221 },
  { id = 19969, kind = "Worn Gear", bonus = 5, source = "Reward: Rare Fish - Brownell's Blue Striped Racer.", quest = 8225 },
  { id = 19971, kind = "Worn Gear", bonus = 5, source = "Reward: Rare Fish - Dezian Queenfish. Use it on a fishing pole.", quest = 8224 },
  { id = 19979, kind = "Worn Gear", source = "Choice reward: Master Angler.", quest = 8193 },
  { id = 11152, kind = "Worn Gear", bonus = 2, source = "Enchanting formula: Enchant Gloves - Fishing." },

  { id = 16083, kind = "Training", source = "Expert Fishing (to 225). Sold by Old Man Heming in Booty Bay." },
  { id = 16082, kind = "Training", source = "Artisan Fishing (to 300): finish Nat Pagle, Angler Extreme in Dustwallow Marsh.", quest = 6607 },
}
D.GEAR_KINDS = { "Poles", "Lures", "Worn Gear", "Training" }
D.GEAR_BY_ID = {}
for _, g in ipairs(D.GEAR) do D.GEAR_BY_ID[g.id] = g end

-------------------------------------------------------------------------------
--  Fishing NPCs: { npcID, name, title }. Names here are only a fallback; the
--  databases supply the live name and where each one stands.
-------------------------------------------------------------------------------
D.NPCS = {
  { 1680, "Matthew Hooper", "Fishing Trainer" }, { 3028, "Kah Mistrunner", "Fishing Trainer" },
  { 3179, "Harold Riggs", "Fishing Trainer" }, { 3332, "Lumak", "Fishing Trainer" },
  { 4156, "Astaia", "Fishing Trainer" }, { 4573, "Armand Cromwell", "Fishing Trainer" },
  { 5161, "Grimnur Stonebrand", "Fishing Trainer" }, { 5493, "Arnold Leland", "Fishing Trainer" },
  { 1651, "Lee Brown", "Fisherman" }, { 1700, "Paxton Ganter", "Fisherman" },
  { 1683, "Warg Deepwater", "Fisherman" }, { 2367, "Donald Rabonne", "Fisherman" },
  { 2626, "Old Man Heming", "Fisherman" }, { 3178, "Stuart Fleming", "Fisherman" },
  { 3497, "Kilxx", "Fisherman" }, { 3572, "Zizzek", "Fisherman" },
  { 3607, "Androl Oakhand", "Fisherman" }, { 4305, "Kriggon Talsone", "Fisherman" },
  { 4307, "Heldan Galesong", "Fisherman" }, { 5690, "Clyde Kellen", "Fisherman" },
  { 5748, "Killian Sanatha", "Fisherman" }, { 5938, "Uthan Stillwater", "Fisherman" },
  { 5941, "Lau'Tiki", "Fisherman" }, { 7946, "Brannock", "Fisherman" },
  { 8137, "Gikkix", "Fisherman" }, { 12032, "Lui'Mala", "Fisherman" },
  { 12961, "Kil'Hiwana", "Fisherman" }, { 251992, "Fenn Fairweather", "Fisherman" },
  { 255877, "Hunter Moore", "Fisherman" }, { 260487, "Gritta Chumwater", "Fisherman" },
  { 1678, "Vernon Hale", "Bait and Tackle Supplier" }, { 1684, "Khara Deepwater", "Fishing Supplies" },
  { 3029, "Sewa Mistrunner", "Fishing Supplier" }, { 3333, "Shankys", "Fishing Supplies" },
  { 3550, "Martine Tramblay", "Fishing Supplies" }, { 4222, "Voloren", "Fishing Supplier" },
  { 4574, "Lizbeth Cromwell", "Fishing Supplier" }, { 5162, "Tansy Puddlefizz", "Fishing Supplier" },
  { 5494, "Catherine Leland", "Fishing Supplier" }, { 5940, "Harn Longcast", "Fishing Supplies" },
  { 5942, "Zansoa", "Fishing Supplies" }, { 7945, "Savanne", "Fishing Supplies" },
  { 10118, "Nessa Shadowsong", "Fishing Supplies" }, { 12031, "Mai'Lahii", "Fishing Supplies" },
  { 383, "Jason Mathers", "Fishmonger" }, { 3540, "Hal McAllister", "Fish Merchant" },
  { 4200, "Laird", "Fish Vendor" }, { 4221, "Talaelar", "Fish Vendor" }, { 7943, "Harklane", "Fish Vendor" },
}
D.NPC_FALLBACK = {}
for _, n in ipairs(D.NPCS) do D.NPC_FALLBACK[n[1]] = n end
