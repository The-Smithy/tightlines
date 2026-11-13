-------------------------------------------------------------------------------
--  TightLines: prices, through Auctionator's public API (Auctionator.API.v1).
--  Auctionator keeps the price it last saw for each item at the Auction
--  House; TightLines reads those and refreshes when Auctionator updates them.
-------------------------------------------------------------------------------
local _, TL = ...
local P = {}
TL.Prices = P

local CALLER = TL.CALLER
local registered = false

local function API()
  local a = _G.Auctionator
  return type(a) == "table" and type(a.API) == "table" and a.API.v1 or nil
end

function P.Available()
  local api = API()
  return api ~= nil and type(api.GetAuctionPriceByItemID) == "function"
end

-- The last Auction House price Auctionator saw (copper) and its age in days.
function P.AH(id)
  local api = API()
  if not (api and id and api.GetAuctionPriceByItemID) then return nil end
  local ok, price = pcall(api.GetAuctionPriceByItemID, CALLER, id)
  if not ok or type(price) ~= "number" or price <= 0 then return nil end
  local age
  if api.GetAuctionAgeByItemID then
    local okAge, a = pcall(api.GetAuctionAgeByItemID, CALLER, id)
    if okAge and type(a) == "number" then age = a end
  end
  return price, age
end

function P.Vendor(id)
  local api = API()
  if api and api.GetVendorPriceByItemID then
    local ok, v = pcall(api.GetVendorPriceByItemID, CALLER, id)
    if ok and type(v) == "number" and v > 0 then return v end
  end
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local v = select(11, get(id))
  return type(v) == "number" and v > 0 and v or nil
end

-- What one is worth: the Auction House price, else what a vendor pays.
function P.Value(id)
  return P.AH(id) or P.Vendor(id) or 0
end

function P.AgeText(age)
  if age == nil then return "age unknown" end
  if age <= 0 then return "seen today" end
  if age == 1 then return "1 day old" end
  return age .. " days old"
end

-- Refresh the guide when Auctionator processes new prices.
function P.Register()
  if registered then return end
  local api = API()
  if api and type(api.RegisterForDBUpdate) == "function" then
    registered = pcall(api.RegisterForDBUpdate, CALLER, function() TL:Fire("PRICES") end)
  end
end

function P.AHOpen()
  return (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown()) or false
end

-- Replace (or create) an Auctionator shopping list with these items.
-- Returns whether it worked and how many items the client is still loading.
function P.ShoppingList(listName, ids)
  local api = API()
  if not (api and api.CreateShoppingList and api.ConvertToSearchString) then return false, 0 end
  local strings, missing, seen = {}, 0, {}
  for _, id in ipairs(ids) do
    local name = TL.ItemName(id, true)
    if not name then
      missing = missing + 1
    elseif not seen[name] then
      seen[name] = true
      local ok, s = pcall(api.ConvertToSearchString, CALLER, { searchString = name, isExact = true })
      if ok and s then strings[#strings + 1] = s end
    end
  end
  if #strings == 0 then return false, missing end
  return pcall(api.CreateShoppingList, CALLER, listName, strings), missing
end

-- Search now when the Auction House is open, else leave a shopping list.
function P.Search(ids)
  local api = API()
  if not api then
    TL:Print("Auctionator isn't loaded, so there is nothing to search with.")
    return
  end
  if P.AHOpen() and api.MultiSearchExact then
    local names = {}
    for _, id in ipairs(ids) do
      local name = TL.ItemName(id, true)
      if name then names[#names + 1] = name end
    end
    if #names > 0 and pcall(api.MultiSearchExact, CALLER, names) then return end
  end
  if P.ShoppingList("TightLines", ids) then
    TL:Print("Saved to the Auctionator shopping list |cffffd100TightLines|r. Open the Auction House and search it to refresh these prices.")
  else
    TL:Print("The game is still loading those items. Try again in a moment.")
  end
end

-- Every fish and what it cooks into, as one shopping list: searching it at
-- the Auction House refreshes every price the guide shows.
function P.SendAllFish()
  if not P.Available() then
    TL:Print("Auctionator isn't loaded.")
    return
  end
  local ids = {}
  for _, fish in ipairs(TL.Data.FISH) do
    if fish.cat ~= "treasure" and fish.cat ~= "quest" then
      ids[#ids + 1] = fish.id
      if fish.cooked then ids[#ids + 1] = fish.cooked end
    end
  end
  local ok, missing = P.ShoppingList("TightLines Fish", ids)
  if ok then
    TL:Print("Auctionator shopping list |cffffd100TightLines Fish|r is ready"
      .. ((missing or 0) > 0 and (" (" .. missing .. " items still loading: run it again in a moment for the rest)") or "")
      .. ". Search it at the Auction House to refresh every fish price.")
  else
    TL:Print("The game is still loading the fish. Try again in a moment.")
  end
end

TL:On("LOGIN", P.Register)
