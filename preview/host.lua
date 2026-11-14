-- The preview's host: runs the addon's real files against a model of the game's
-- UI (frames, textures, font strings and the anchor layout) and prints what
-- would be on screen as JSON for preview/index.html to draw.
--
--   luajit host.lua <addon dir> <game AddOns dir or -> <request.json> [SavedVariables file or -]
--
-- Every render starts from nothing: the addon loads, the window opens, and the
-- request's actions (clicks, wheel, typing) are replayed in order. That makes a
-- render repeatable, so the page can re-render after any file change and land
-- on the same view.
--
-- This is a model, not the game: it knows the widget API the addon uses, lays
-- frames out by the game's anchor rules, and estimates text sizes. The game's
-- art, fonts and behaviour are not here.
local ADDON_DIR, GAME_ADDONS, REQUEST_FILE, SAVED_FILE = arg[1], arg[2], arg[3], arg[4]
local started = os.clock()

-------------------------------------------------------------------------------
-- JSON
-------------------------------------------------------------------------------
local ARRAY = {}
local function arr(t) return setmetatable(t or {}, ARRAY) end

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function encode(v, out)
  local t = type(v)
  if t == "table" then
    if getmetatable(v) == ARRAY or #v > 0 then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encode(v[i], out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      for k, x in pairs(v) do
        if not first then out[#out + 1] = "," end
        first = false
        encode(tostring(k), out)
        out[#out + 1] = ":"
        encode(x, out)
      end
      out[#out + 1] = "}"
    end
  elseif t == "string" then
    out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return ESCAPES[c] or string.format("\\u%04x", c:byte()) end) .. '"'
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then v = 0 end
    out[#out + 1] = tostring(math.floor(v * 100 + 0.5) / 100)
  elseif t == "boolean" then
    out[#out + 1] = tostring(v)
  else
    out[#out + 1] = "null"
  end
end

local function decode(s)
  local pos = 1
  local value
  local function ws() pos = s:find("%S", pos) or #s + 1 end
  local function str()
    local out = {}
    pos = pos + 1
    while true do
      local e = s:find('["\\]', pos)
      if not e then error("bad json string") end
      out[#out + 1] = s:sub(pos, e - 1)
      if s:sub(e, e) == '"' then pos = e + 1 break end
      local c = s:sub(e + 1, e + 1)
      if c == "u" then
        local code = tonumber(s:sub(e + 2, e + 5), 16) or 63
        out[#out + 1] = code < 128 and string.char(code) or "?"
        pos = e + 6
      else
        out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "", f = "" })[c] or c
        pos = e + 2
      end
    end
    return table.concat(out)
  end
  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      local t = {}
      pos = pos + 1
      ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return t end
      while true do
        ws()
        local k = str()
        ws()
        pos = pos + 1
        t[k] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d ~= "," then break end
      end
      return t
    elseif c == "[" then
      local t = {}
      pos = pos + 1
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1 return t end
      while true do
        t[#t + 1] = value()
        ws()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d ~= "," then break end
      end
      return t
    elseif c == '"' then
      return str()
    elseif s:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif s:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif s:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    end
    local num = s:match("^-?[%d%.]+[eE]?[+-]?%d*", pos)
    if not num then error("bad json at " .. pos) end
    pos = pos + #num
    return tonumber(num)
  end
  return value()
end

local request = {}
do
  local f = REQUEST_FILE and io.open(REQUEST_FILE, "rb")
  if f then
    local text = f:read("*a")
    f:close()
    if text ~= "" then request = decode(text) or {} end
  end
end
local options = request.options or {}

-------------------------------------------------------------------------------
-- The UI model
-------------------------------------------------------------------------------
local SCREEN_W, SCREEN_H = 1366, 768
local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
local LAYER = { BACKGROUND = 1, BORDER = 2, ARTWORK = 3, OVERLAY = 4, HIGHLIGHT = 5 }
local FONT_OBJECTS = {
  GameFontNormal = { 12, { 1, 0.82, 0 } }, GameFontNormalSmall = { 10, { 1, 0.82, 0 } },
  GameFontNormalLarge = { 16, { 1, 0.82, 0 } }, GameFontHighlight = { 12, { 1, 1, 1 } },
  GameFontHighlightSmall = { 10, { 1, 1, 1 } }, GameFontDisableSmall = { 10, { 0.5, 0.5, 0.5 } },
}

local objects, generation = {}, 0
local missing, errors, chat = {}, arr(), arr()
local UIParent

local function touch() generation = generation + 1 end
local function noop() end

local function new(kind, parent)
  local o = { id = #objects + 1, kind = kind, parent = parent, points = {}, shown = true, alpha = 1 }
  objects[o.id] = o
  return o
end

-- Text ------------------------------------------------------------------------
local function plainText(text)
  text = tostring(text or "")
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", "\n"):gsub("|T.-|t", "\1"):gsub("||", "|")
  return text
end

-- Widths in ems, roughly the game's default font.
local function charWidth(ch)
  if ch == "\1" then return 1.1 end
  if ch == " " then return 0.3 end
  if ch:find("[il%.,:;!'|I]") then return 0.3 end
  if ch:find("[mwMW]") then return 0.86 end
  if ch:find("[ftjr%(%)%[%]%-]") then return 0.38 end
  if ch:find("%u") then return 0.68 end
  if ch:find("%d") then return 0.56 end
  if ch:byte() >= 128 then return 0.3 end
  return 0.53
end

local function measure(text, size)
  local best, w = 0, 0
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == "\n" then
      best, w = math.max(best, w), 0
    else
      w = w + charWidth(ch)
    end
  end
  return math.max(best, w) * size
end

local function lineCount(text, size, width)
  local n = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local lines, w = 1, 0
    if width and width > 0 then
      for word, space in line:gmatch("(%S+)(%s*)") do
        local ww = measure(word, size)
        if w > 0 and w + ww > width then
          lines, w = lines + 1, 0
        end
        w = w + ww + measure(space, size)
      end
    end
    n = n + lines
  end
  return math.max(n, 1)
end

local function lineHeight(fs) return (fs.size or 12) * 1.18 + (fs.spacing or 0) end

-- Layout ------------------------------------------------------------------------
-- Rectangles are in screen pixels, y down from the top.
local cache, cacheGeneration, computing = {}, -1, {}

local function effectiveScale(o)
  local s = 1
  while o do
    if o.scale then s = s * o.scale end
    o = o.parent
  end
  return s
end

local function anchor(rect, point)
  local x, y = (rect.l + rect.r) / 2, (rect.t + rect.b) / 2
  if point:find("LEFT", 1, true) then x = rect.l elseif point:find("RIGHT", 1, true) then x = rect.r end
  if point:find("TOP", 1, true) then y = rect.t elseif point:find("BOTTOM", 1, true) then y = rect.b end
  return x, y
end

local rectOf

-- One axis by the game's rules: two edges; an edge and the centre (the size
-- is twice the distance); or one of them and a size.
local function axis(lo, hi, centre, size)
  if lo and hi then return lo, hi end
  if lo and centre then return lo, 2 * centre - lo end
  if hi and centre then return 2 * centre - hi, hi end
  if not size then return nil end
  if lo then return lo, lo + size end
  if hi then return hi - size, hi end
  if centre then return centre - size / 2, centre + size / 2 end
end

function rectOf(o)
  if o == UIParent then return { l = 0, t = 0, r = SCREEN_W, b = SCREEN_H } end
  if cacheGeneration ~= generation then cache, cacheGeneration = {}, generation end
  local hit = cache[o]
  if hit ~= nil then return hit or nil end
  if computing[o] then return nil end
  computing[o] = true

  local scale = effectiveScale(o)
  local L, R, T, B, CX, CY
  for _, p in ipairs(o.points) do
    local rel = p.rel or o.parent
    local rr = rel and rectOf(rel)
    if rr then
      local ax, ay = anchor(rr, p.relPoint)
      ax, ay = ax + p.x * scale, ay - p.y * scale
      if p.point:find("LEFT", 1, true) then L = ax elseif p.point:find("RIGHT", 1, true) then R = ax else CX = ax end
      if p.point:find("TOP", 1, true) then T = ay elseif p.point:find("BOTTOM", 1, true) then B = ay else CY = ay end
    end
  end
  local w, h = o.w and o.w * scale, o.h and o.h * scale
  local hx, vy -- which anchor a font string's own size hangs from
  if o.kind == "FontString" then
    local text = plainText(o.text)
    local size = o.size or 12
    local boundW = ((L and R) and (R - L)) or ((L and CX) and 2 * (CX - L)) or ((R and CX) and 2 * (R - CX)) or w
    if not boundW then
      w = (measure(text, size) + 2) * scale
      hx = L and "l" or R and "r" or "c"
    end
    local boundH = (T and B) or (T and CY) or (B and CY) or h
    if not boundH then
      local wrapWidth = (o.wrap ~= false) and boundW and (boundW / scale) or nil
      local lines = lineCount(text, size, wrapWidth)
      if o.maxLines and o.maxLines > 0 then lines = math.min(lines, o.maxLines) end
      h = lines * lineHeight(o) * scale
      vy = T and "t" or B and "b" or "m"
    end
  end
  local l, r = axis(L, R, CX, w)
  local t, b = axis(T, B, CY, h)
  local rect = false
  if l and r and t and b then rect = { l = l, t = t, r = r, b = b, hx = hx, vy = vy } end
  cache[o] = rect
  computing[o] = nil
  return rect or nil
end

-- Methods -------------------------------------------------------------------------
local Region, FrameM, TextureM, FontM = {}, {}, {}, {}
-- Methods that change nothing a still picture shows.
local HARMLESS = {}
for name in ("EnableMouseWheel RegisterForDrag RegisterForClicks SetAutoFocus SetClampedToScreen SetMovable SetToplevel "
  .. "StartMoving StopMovingOrSizing ClearFocus SetFocus SetSnapToPixelGrid SetTexelSnappingBias SetID"):gmatch("%S+") do
  HARMLESS[name] = true
end

local function class(name, methods, base)
  return { __index = function(_, k)
    local m = methods[k]
    if m == nil and base then m = base[k] end
    if m ~= nil then return m end
    if type(k) == "string" and k:match("^%u") then
      if not HARMLESS[k] then missing[name .. ":" .. k] = true end
      return noop
    end
  end }
end
local frameMT, textureMT, fontMT = class("Frame", FrameM, Region), class("Texture", TextureM, Region), class("FontString", FontM, Region)

function Region:SetPoint(point, a, b, c, d)
  local rel, relPoint, x, y
  if type(a) == "number" then
    rel, relPoint, x, y = nil, point, a, b or 0
  else
    rel = a
    if type(rel) == "string" then rel = _G[rel] end
    if type(b) == "string" then relPoint, x, y = b, c or 0, d or 0 else relPoint, x, y = point, b or 0, c or 0 end
  end
  for i, p in ipairs(self.points) do
    if p.point == point then table.remove(self.points, i) break end
  end
  self.points[#self.points + 1] = { point = point, rel = rel, relPoint = relPoint, x = x, y = y }
  touch()
end
function Region:ClearAllPoints() self.points = {} touch() end
function Region:SetAllPoints(rel)
  if type(rel) ~= "table" then rel = nil end
  self.points = {
    { point = "TOPLEFT", rel = rel, relPoint = "TOPLEFT", x = 0, y = 0 },
    { point = "BOTTOMRIGHT", rel = rel, relPoint = "BOTTOMRIGHT", x = 0, y = 0 },
  }
  touch()
end
function Region:GetPoint(i)
  local p = self.points[i or 1]
  if p then return p.point, p.rel or self.parent, p.relPoint, p.x, p.y end
end
function Region:SetSize(w, h) self.w, self.h = w, h touch() end
function Region:SetWidth(w) self.w = w touch() end
function Region:SetHeight(h) self.h = h touch() end
function Region:GetWidth()
  if self.w then return self.w end
  local r = rectOf(self)
  return r and (r.r - r.l) / effectiveScale(self) or 0
end
function Region:GetHeight()
  if self.h then return self.h end
  local r = rectOf(self)
  return r and (r.b - r.t) / effectiveScale(self) or 0
end
function Region:GetSize() return self:GetWidth(), self:GetHeight() end
function Region:GetLeft() local r = rectOf(self) return r and r.l end
function Region:GetRight() local r = rectOf(self) return r and r.r end
function Region:GetTop() local r = rectOf(self) return r and SCREEN_H - r.t end
function Region:GetBottom() local r = rectOf(self) return r and SCREEN_H - r.b end
function Region:GetCenter()
  local r = rectOf(self)
  if r then return (r.l + r.r) / 2, SCREEN_H - (r.t + r.b) / 2 end
end
function Region:Show()
  if self.shown then return end
  self.shown = true
  touch()
  local s = self.scripts and self.scripts.OnShow
  if s then s(self) end
end
function Region:Hide()
  if not self.shown then return end
  self.shown = false
  touch()
  local s = self.scripts and self.scripts.OnHide
  if s then s(self) end
end
function Region:SetShown(v) if v then self:Show() else self:Hide() end end
function Region:IsShown() return self.shown end
function Region:IsVisible()
  local o = self
  while o do
    if not o.shown then return false end
    o = o.parent
  end
  return true
end
function Region:SetAlpha(a) self.alpha = a end
function Region:GetAlpha() return self.alpha end
function Region:GetParent() return self.parent end
function Region:GetObjectType() return self.kind end
function Region:IsObjectType(kind) return self.kind == kind end
function Region:IsForbidden() return false end
function Region:SetDrawLayer(layer, sub) self.layer, self.sub = layer, sub or 0 end
function Region:GetEffectiveScale() return effectiveScale(self) end

-- A stand-in for animation groups: every method does nothing and chains.
local animation
animation = setmetatable({}, { __index = function() return function() return animation end end })
function Region:CreateAnimationGroup() return animation end

-- Frames
function FrameM:SetParent(parent)
  if self.parent and self.parent.children then
    for i, c in ipairs(self.parent.children) do
      if c == self then table.remove(self.parent.children, i) break end
    end
  end
  self.parent = parent
  if parent and parent.children then parent.children[#parent.children + 1] = self end
  touch()
end
function FrameM:CreateTexture(_, layer, _, sub)
  local t = setmetatable(new("Texture", self), textureMT)
  t.layer, t.sub, t.vertex = layer or "ARTWORK", sub or 0, { 1, 1, 1, 1 }
  self.regions[#self.regions + 1] = t
  return t
end
function FrameM:CreateFontString(_, layer, template)
  local fs = setmetatable(new("FontString", self), fontMT)
  local font = FONT_OBJECTS[template or ""]
  fs.layer, fs.sub, fs.text = layer or "ARTWORK", 0, ""
  fs.size, fs.color = font and font[1] or 12, font and { font[2][1], font[2][2], font[2][3], 1 } or { 1, 1, 1, 1 }
  fs.justifyH, fs.justifyV = "CENTER", "MIDDLE"
  self.regions[#self.regions + 1] = fs
  return fs
end
function FrameM:SetScript(name, fn) self.scripts[name] = fn end
function FrameM:GetScript(name) return self.scripts[name] end
function FrameM:HasScript() return true end
function FrameM:HookScript(name, fn)
  local old = self.scripts[name]
  self.scripts[name] = old and function(...) old(...) return fn(...) end or fn
end
function FrameM:RegisterEvent(e) self.events[e] = true end
function FrameM:UnregisterEvent(e) self.events[e] = nil end
function FrameM:EnableMouse(v) self.mouse = v and true or false end
function FrameM:SetFrameStrata(s) self.strata = s end
function FrameM:GetFrameStrata()
  local f = self
  while f do
    if f.strata then return f.strata end
    f = f.parent
  end
  return "MEDIUM"
end
function FrameM:SetFrameLevel(n) self.level = n end
function FrameM:GetFrameLevel() return self.level or 0 end
function FrameM:SetScale(s) self.scale = s touch() end
function FrameM:GetScale() return self.scale or 1 end
function FrameM:SetBackdrop(def) self.backdrop = def and { bg = { 0, 0, 0, 0 }, border = { 1, 1, 1, 1 }, edge = def.edgeSize or 1 } or nil end
function FrameM:SetBackdropColor(r, g, b, a) if self.backdrop then self.backdrop.bg = { r, g, b, a or 1 } end end
function FrameM:SetBackdropBorderColor(r, g, b, a) if self.backdrop then self.backdrop.border = { r, g, b, a or 1 } end end
function FrameM:Enable() self.disabled = nil end
function FrameM:Disable() self.disabled = true end
function FrameM:IsEnabled() return not self.disabled end
function FrameM:SetEnabled(v) self.disabled = not v or nil end
local function fill(self, layer, file)
  local t = self:CreateTexture(nil, layer)
  t:SetAllPoints()
  if type(file) == "table" then return file end
  t:SetTexture(file)
  return t
end
function FrameM:SetHighlightTexture(file) self.highlightTexture = fill(self, "HIGHLIGHT", file) end
function FrameM:SetNormalTexture(file) self.normalTexture = fill(self, "ARTWORK", file) end
function FrameM:GetHighlightTexture() return self.highlightTexture end
function FrameM:GetNormalTexture() return self.normalTexture end
-- Edit boxes
function FrameM:SetText(text)
  self.text = tostring(text or "")
  local s = self.scripts.OnTextChanged
  if s then s(self, false) end
end
function FrameM:GetText() return self.text or "" end
function FrameM:SetFont(font, size) self.font, self.size = font, size end
function FrameM:SetTextColor(r, g, b, a) self.color = { r, g, b, a or 1 } end
function FrameM:SetTextInsets(l) self.inset = l end
function FrameM:HasFocus() return false end

-- Textures
function TextureM:SetTexture(file) self.file, self.solid = file, nil end
function TextureM:GetTexture() return self.file end
function TextureM:SetColorTexture(r, g, b, a) self.solid, self.file = { r, g, b, a or 1 }, nil end
function TextureM:SetAtlas(name) self.file, self.solid = "atlas:" .. tostring(name), nil end
function TextureM:SetVertexColor(r, g, b, a) self.vertex = { r, g, b, a or 1 } end
function TextureM:SetBlendMode(mode) self.blend = mode end
function TextureM:SetDesaturated(v) self.desaturated = v and true or nil end
function TextureM:SetRotation(r) self.rotation = r end
function TextureM:SetTexCoord(l, r, t, b) self.coords = { l, r, t, b } end

-- Font strings
function FontM:SetFont(font, size) self.font, self.size = font, size touch() return true end
function FontM:GetFont() return self.font, self.size, "" end
function FontM:SetText(text) self.text = tostring(text or "") touch() end
function FontM:SetFormattedText(fmt, ...) self:SetText(string.format(fmt, ...)) end
function FontM:GetText() return self.text end
function FontM:SetTextColor(r, g, b, a) self.color = { r, g, b, a or 1 } end
function FontM:SetJustifyH(j) self.justifyH = j end
function FontM:SetJustifyV(j) self.justifyV = j end
function FontM:SetWordWrap(v) self.wrap = v and true or false touch() end
function FontM:SetMaxLines(n) self.maxLines = n touch() end
function FontM:SetSpacing(n) self.spacing = n touch() end
function FontM:SetShadowOffset(x, y) self.shadow = (x ~= 0 or y ~= 0) end
function FontM:SetShadowColor() end
function FontM:GetStringWidth() return measure(plainText(self.text), self.size or 12) end
function FontM:GetUnboundedStringWidth() return self:GetStringWidth() end
function FontM:GetStringHeight()
  local r = rectOf(self)
  return r and (r.b - r.t) / effectiveScale(self) or lineHeight(self)
end

function CreateFrame(kind, name, parent, template)
  local f = setmetatable(new(kind or "Frame", parent), frameMT)
  f.isFrame, f.children, f.regions, f.scripts, f.events = true, {}, {}, {}, {}
  f.level = parent and ((parent.level or 0) + 1) or 0
  if parent and parent.children then parent.children[#parent.children + 1] = f end
  if name then
    f.name = name
    _G[name] = f
  end
  template = template or ""
  if template:find("UIPanelCloseButton", 1, true) then
    f.w, f.h, f.template = 24, 24, "close"
  end
  if kind == "EditBox" then f.text, f.mouse = "", true end
  return f
end

UIParent = CreateFrame("Frame", "UIParent")
UIParent.w, UIParent.h = SCREEN_W, SCREEN_H

-- The tooltip: not laid out here, the page draws it beside its owner.
local tooltip = { lines = {}, shown = false }
local tooltipHooks = {}
GameTooltip = setmetatable({}, { __index = function(_, k)
  if type(k) == "string" and k:match("^%u") then return noop end
end })
function GameTooltip:SetOwner(owner, where) tooltip = { lines = {}, shown = false, owner = owner, where = where or "ANCHOR_RIGHT" } end
function GameTooltip:ClearLines() tooltip.lines = {} end
function GameTooltip:AddLine(text, r, g, b)
  tooltip.lines[#tooltip.lines + 1] = { l = tostring(text or ""), lc = { r or 1, g or 0.82, b or 0 } }
end
function GameTooltip:AddDoubleLine(l, r, lr, lg, lb, rr, rg, rb)
  tooltip.lines[#tooltip.lines + 1] = { l = tostring(l or ""), r = tostring(r or ""), lc = { lr or 1, lg or 0.82, lb or 0 }, rc = { rr or 1, rg or 1, rb or 1 } }
end
function GameTooltip:Show() tooltip.shown = true end
function GameTooltip:Hide() tooltip.shown = false end
function GameTooltip:IsShown() return tooltip.shown end
function GameTooltip:HasScript() return false end
ItemRefTooltip = {}

-------------------------------------------------------------------------------
-- The game's API, as far as the addon uses it
-------------------------------------------------------------------------------
local clock = os.time()
time = function() return clock end
date = os.date
function GetTime() return clock end
tinsert = table.insert
function strtrim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
function strsplit(sep, s)
  local out = {}
  for part in (s .. sep):gmatch("(.-)%" .. sep) do out[#out + 1] = part end
  return unpack(out)
end
function geterrorhandler()
  return function(err) errors[#errors + 1] = tostring(err) end
end
UISpecialFrames, SlashCmdList = {}, {}
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
ITEM_QUALITY_COLORS = {
  [0] = { r = 0.62, g = 0.62, b = 0.62 }, [1] = { r = 1, g = 1, b = 1 }, [2] = { r = 0.12, g = 1, b = 0 },
  [3] = { r = 0, g = 0.44, b = 0.87 }, [4] = { r = 0.64, g = 0.21, b = 0.93 },
}
ERR_FISH_ESCAPED, ERR_FISH_NOT_HOOKED, SPELL_FAILED_FISHING_TOO_LOW = "Your fish got away!", "No fish are hooked.", "Requires Fishing %d"
DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) chat[#chat + 1] = tostring(text) end }
C_Timer = { After = function(_, fn) fn() end }
C_AddOns = { GetAddOnMetadata = function() return "preview" end }
C_Spell = { GetSpellName = function() return "Fishing" end }
C_QuestLog = { IsQuestFlaggedCompleted = function(id) return id == 1141 or id == 8194 end }
function IsShiftKeyDown() return false end
function GetCursorPosition() return 0, 0 end
function InCombatLockdown() return false end
function GetPlayerFacing() return 0.6 end
function GetGameTime() return tonumber(os.date("%H")), tonumber(os.date("%M")) end
function UnitFactionGroup() return options.faction == "Horde" and "Horde" or "Alliance" end
function UnitName() return "Previewer" end
function UnitClass() return "Hunter", "HUNTER" end
function GetNormalizedRealmName() return "Preview" end
local subzone = ""
function GetSubZoneText() return subzone end

local skillRank = tonumber(options.skill)
if options.skill == nil then skillRank = 230 end
local skillModifier = tonumber(options.lure) or 0
function GetProfessions() if skillRank then return 1, 2, nil, 9, 10 end end
function GetProfessionInfo() return "Fishing", 1, skillRank, math.min(300, math.ceil((skillRank + 1) / 75) * 75), 0, 0, 356, skillModifier end

local KALIMDOR = {}
for _, id in ipairs({ 1411, 1412, 1438, 1439, 1413, 1454, 1456, 1457, 1442, 1440, 1441, 1443, 1445, 1444, 1446, 1447, 1448,
  1449, 1450, 1451, 1452, 2482, 2652 }) do KALIMDOR[id] = true end
local playerMap, playerX, playerY = tonumber(options.zone) or 1444, 0.31, 0.43
C_Map = {
  GetMapInfo = function(id)
    if id == 1414 then return { mapID = id, name = "Kalimdor", mapType = 2, parentMapID = 947 } end
    if id == 1415 then return { mapID = id, name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 } end
    if id == 947 or id == 1463 or id == 1464 then return { mapID = id, name = "Azeroth", mapType = 1, parentMapID = 0 } end
    return { mapID = id, mapType = 3, parentMapID = KALIMDOR[id] and 1414 or 1415 }
  end,
  GetBestMapForUnit = function() return playerMap end,
  GetPlayerMapPosition = function(map)
    if map ~= playerMap then return nil end
    return { GetXY = function() return playerX, playerY end }
  end,
  GetMapArtLayers = function() return { { layerWidth = 1002, layerHeight = 668, tileWidth = 256, tileHeight = 256 } } end,
  GetMapArtLayerTextures = function(map)
    local tiles = {}
    for i = 1, 12 do tiles[i] = "maptile:" .. map .. ":" .. i end
    return tiles
  end,
  GetMapRectOnMap = function() return 0.2, 0.4, 0.3, 0.5 end,
}

-- Items: names from LibForeverData when it is there, else the addon's own.
local itemNames = {}
local QUALITY = { [19970] = 3, [19022] = 2, [19972] = 2, [19969] = 2, [19971] = 2, [19979] = 3, [6367] = 2, [6366] = 2,
  [6365] = 1, [12225] = 2, [6533] = 1, [21228] = 2, [21150] = 2, [13918] = 2, [13875] = 2 }
local function itemName(id)
  if itemNames[id] ~= nil then return itemNames[id] or nil end
  local name
  if LibForeverData then name = LibForeverData.Name("item", id) end
  itemNames[id] = name or false
  return name
end
C_Item = {
  GetItemInfo = function(id)
    local name = itemName(id)
    if not name then return nil end
    local quality = QUALITY[id] or ((name:find("Pound") or name:find("Crate")) and 0) or 1
    return name, "|Hitem:" .. id .. "|h[" .. name .. "]|h", quality, 1, 1, "", "", 20, "", "item:" .. id, (id % 40 + 1) * 3
  end,
  GetItemIconByID = function(id) return "item:" .. id .. ":" .. (itemName(id) or "") end,
  RequestLoadItemDataByID = noop,
  GetItemCount = function(id) return (id == 6256 or id == 6530) and 1 or 0 end,
}
function GameTooltip:SetItemByID(id)
  local name, _, quality = C_Item.GetItemInfo(id)
  local c = ITEM_QUALITY_COLORS[quality or 1]
  tooltip.lines = { { l = name or ("Item #" .. id), lc = { c.r, c.g, c.b } }, { l = "(the game's own item tooltip goes here)", lc = { 0.5, 0.5, 0.5 } } }
  for _, hook in ipairs(tooltipHooks) do pcall(hook, GameTooltip, { id = id }) end
end
Enum = { TooltipDataType = { Item = 0 } }
TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) tooltipHooks[#tooltipHooks + 1] = fn end }

-- Prices: made up, but the same every render.
if options.auctionator ~= false then
  Auctionator = { API = { v1 = {
    GetAuctionPriceByItemID = function(_, id)
      if id % 7 == 0 then return nil end
      return (id * 7919) % 28000 + 40
    end,
    GetAuctionAgeByItemID = function(_, id) return id % 4 end,
    GetVendorPriceByItemID = function(_, id) return id % 60 + 2 end,
    RegisterForDBUpdate = noop,
    ConvertToSearchString = function(_, term) return term.searchString end,
    CreateShoppingList = noop,
    MultiSearchExact = noop,
  } } }
end

-- LibForeverData: the real one, from the game folder, when it is installed.
if options.lfd ~= false and GAME_ADDONS and GAME_ADDONS ~= "-" then
  local ns, ok = {}, true
  for _, file in ipairs({ "LuaChunks.lua", "Core.lua", "Data/Quests.lua", "Data/Npcs.lua", "Data/Objects.lua",
    "Data/Items.lua", "Data/Spawns.lua", "Data/Steps.lua" }) do
    local chunk = loadfile(GAME_ADDONS .. "/LibForeverData/" .. file)
    if not chunk then ok = false break end
    chunk("LibForeverData", ns)
  end
  if not ok then LibForeverData = nil end
end

-- EllesmereUI: an approximation of what its skin does to a window (flat dark
-- panels, thin grey borders, its accent colour and font). Not its real code.
local skinCallback
if options.theme == "eui" then
  local function fade(frame)
    for _, r in ipairs(frame.regions) do
      if r.kind == "Texture" and not r.skin then r.alpha = 0 end
    end
  end
  local function paint(frame, bg) frame.backdrop = { bg = bg, border = { 0.2, 0.2, 0.2, 1 }, edge = 1 } end
  local S = setmetatable({ apiVersion = 4 }, { __index = function() return noop end })
  function S.Shell(frame) fade(frame) paint(frame, { 0.067, 0.067, 0.067, 0.97 }) end
  function S.Panel(frame, opts) fade(frame) paint(frame, opts and opts.inset and { 0.04, 0.04, 0.04, 0.85 } or { 0.08, 0.08, 0.08, 0.92 }) end
  function S.Button(button)
    fade(button)
    paint(button, { 0.08, 0.08, 0.08, 0.92 })
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover.skin = true
    hover:SetColorTexture(1, 1, 1, 0.1)
    hover:SetAllPoints()
  end
  function S.EditBox(box) fade(box) paint(box, { 0.02, 0.02, 0.02, 1 }) end
  function S.CloseButton(button) button.template = "close-eui" end
  function S.Font(fs) fs.font = "eui" end
  function S.GetAccentColor() return 0.047, 0.824, 0.616 end
  function S.GetFont() return "eui", "" end
  function S.GetStyle() return "modern" end
  function S.IsEnabled() return true end
  EllesmereUI = {
    RegisterSkin = function(_, fn) skinCallback = function() fn(S) end return true end,
    RegisterPlugin = function() return true end,
  }
end

-------------------------------------------------------------------------------
-- Load the addon, log in, fish a little, open the window, replay the actions
-------------------------------------------------------------------------------
local function fire(event, ...)
  for _, o in ipairs(objects) do
    if o.isFrame and o.events[event] and o.scripts.OnEvent then o.scripts.OnEvent(o, event, ...) end
  end
end

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function run()
  -- Saved data: the real file when asked for, else a made-up history below
  local useSaved = options.saved == true and SAVED_FILE and SAVED_FILE ~= "-"
  if useSaved then
    local chunk = loadfile(SAVED_FILE)
    if chunk then chunk() else useSaved = false end
  end

  local toc = assert(readFile(ADDON_DIR .. "/TightLines.toc"), "no TightLines.toc in " .. tostring(ADDON_DIR))
  local ns = {}
  for line in toc:gsub("\r", ""):gmatch("[^\n]+") do
    if not line:match("^%s*#") and line:match("%S") then
      local file = line:gsub("\\", "/"):gsub("%s+$", "")
      local chunk, err = loadfile(ADDON_DIR .. "/" .. file)
      if not chunk then error(err, 0) end
      chunk("TightLines", ns)
    end
  end
  fire("ADDON_LOADED", "TightLines")
  fire("PLAYER_LOGIN")
  if skinCallback then skinCallback() end

  -- A few made-up trips, so the Trips tab and the catch spots have something
  if not useSaved and options.sample ~= false then
    local loot, source = {}, ""
    IsFishingLoot = function() return true end
    GetNumLootItems = function() return #loot end
    GetLootSlotLink = function(i) return "|Hitem:" .. loot[i][1] .. "::|h[x]|h" end
    GetLootSlotInfo = function(i) return 1, "x", loot[i][2] end
    GetLootSourceInfo = function() return source, 1 end
    local function cast(items, away)
      fire("UNIT_SPELLCAST_CHANNEL_START", "player", "Cast-1", 7620)
      clock = clock + 14
      if away then
        fire("UI_ERROR_MESSAGE", 50, ERR_FISH_ESCAPED)
      else
        loot, source = items, "GameObject-0-1-0-1-35591-0000000001"
        fire("LOOT_READY")
        fire("LOOT_CLOSED")
      end
      clock = clock + 6
    end
    local now, here = clock, playerMap
    local history = {
      { ago = 3 * 86400, map = 1447, sub = "Bay of Storms", casts = 60, fish = { 13422, 13893, 13888, 13754 } },
      { ago = 26 * 3600, map = 1434, sub = "The Savage Coast", casts = 45, fish = { 6359, 4603, 6362, 13754 } },
      { ago = 5 * 3600, map = 1444, sub = "Verdantis River", casts = 70, fish = { 13758, 13759, 13758, 8365 } },
      { ago = 400, map = here, sub = "", casts = 18, fish = { 13758, 13760, 13758 } },
    }
    for _, trip in ipairs(history) do
      clock = now - trip.ago
      playerMap, subzone = trip.map, trip.sub
      fire("ZONE_CHANGED_NEW_AREA")
      for i = 1, trip.casts do
        playerX, playerY = 0.3 + ((i * 37) % 23) / 100, 0.4 + ((i * 53) % 17) / 100
        cast({ { trip.fish[i % #trip.fish + 1], 1 } }, i % 11 == 0)
      end
    end
    clock, playerMap, subzone, playerX, playerY = now, here, "", 0.31, 0.43
    fire("ZONE_CHANGED_NEW_AREA")
    IsFishingLoot = function() return false end
  end

  SlashCmdList.TIGHTLINES("")

  for _, action in ipairs(request.actions or {}) do
    local o = objects[action.id or 0]
    if o and o.isFrame then
      if action.type == "click" then
        local s = o.scripts.OnClick
        if s then s(o, action.button or "LeftButton", false) end
      elseif action.type == "wheel" then
        local s = o.scripts.OnMouseWheel
        if s then s(o, action.delta or -1) end
      elseif action.type == "text" then
        o:SetText(action.value or "")
      end
    end
  end
  if request.hover then
    local o = objects[request.hover]
    local s = o and o.isFrame and o.scripts.OnEnter
    if s then s(o) end
  end
  -- One pass of the timers the window runs (the player's arrow on the map)
  for _, o in ipairs(objects) do
    if o.isFrame and o.scripts.OnUpdate and o:IsVisible() then o.scripts.OnUpdate(o, 1) end
  end
end

-------------------------------------------------------------------------------
-- What is on screen, back to front
-------------------------------------------------------------------------------
local function alphaOf(o)
  local a = 1
  while o do
    a = a * (o.alpha or 1)
    o = o.parent
  end
  return a
end

local function dump()
  local frames = {}
  local function walk(f)
    for _, child in ipairs(f.children) do
      if child.shown then
        frames[#frames + 1] = child
        walk(child)
      end
    end
  end
  walk(UIParent)
  for _, f in ipairs(frames) do f.strataIndex = STRATA[f:GetFrameStrata()] or 3 end
  table.sort(frames, function(a, b)
    if a.strataIndex ~= b.strataIndex then return a.strataIndex < b.strataIndex end
    if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) < (b.level or 0) end
    return a.id < b.id
  end)

  local nodes = arr()
  for _, f in ipairs(frames) do
    local rect = rectOf(f)
    if rect then
      local alpha = alphaOf(f)
      local s = f.scripts
      local node = {
        k = "f", id = f.id, x = rect.l, y = rect.t, w = rect.r - rect.l, h = rect.b - rect.t, a = alpha,
        click = s.OnClick and true or nil, enter = s.OnEnter and true or nil, wheel = s.OnMouseWheel and true or nil,
        template = f.template, name = f.name,
      }
      if f.backdrop then node.bg, node.bd, node.edge = f.backdrop.bg, f.backdrop.border, f.backdrop.edge end
      if f.kind == "EditBox" then
        node.edit = { text = f.text or "", size = f.size or 12, color = f.color or { 1, 1, 1, 1 }, inset = f.inset or 0, font = f.font }
      end
      local regions = {}
      for _, r in ipairs(f.regions) do
        if r.shown then regions[#regions + 1] = r end
      end
      table.sort(regions, function(a, b)
        local la, lb = LAYER[a.layer] or 3, LAYER[b.layer] or 3
        if la ~= lb then return la < lb end
        if (a.sub or 0) ~= (b.sub or 0) then return (a.sub or 0) < (b.sub or 0) end
        return a.id < b.id
      end)
      local interactive = node.click or node.enter or node.wheel or node.edit
      if node.bg or interactive or node.template or #regions > 0 then nodes[#nodes + 1] = node end
      for _, r in ipairs(regions) do
        local rr = rectOf(r)
        local ra = alpha * (r.alpha or 1)
        if rr and ra > 0 then
          local n = { id = r.id, f = f.id, x = rr.l, y = rr.t, w = rr.r - rr.l, h = rr.b - rr.t, a = ra,
            hl = r.layer == "HIGHLIGHT" or nil }
          if r.kind == "Texture" then
            n.k = "t"
            n.solid, n.file, n.vc, n.blend, n.rot, n.gray = r.solid, r.file, r.vertex, r.blend, r.rotation, r.desaturated
            n.tc = r.coords
            if n.solid or n.file then nodes[#nodes + 1] = n end
          elseif (r.text or "") ~= "" then
            n.k = "s"
            n.text, n.size, n.color, n.font = r.text, (r.size or 12) * effectiveScale(r), r.color, r.font
            n.jh, n.jv, n.wrap, n.max, n.sp = r.justifyH, r.justifyV, r.wrap ~= false, r.maxLines, r.spacing
            n.hx, n.vy, n.shadow = rr.hx, rr.vy, r.shadow
            nodes[#nodes + 1] = n
          end
        end
      end
    end
  end

  local tip
  if tooltip.shown and tooltip.owner and #tooltip.lines > 0 then
    local rect = rectOf(tooltip.owner)
    if rect then
      tip = { x = rect.l, y = rect.t, w = rect.r - rect.l, h = rect.b - rect.t, where = tooltip.where, lines = arr(tooltip.lines) }
    end
  end
  local missingList = arr()
  for name in pairs(missing) do missingList[#missingList + 1] = name end
  table.sort(missingList)
  return {
    screen = { w = SCREEN_W, h = SCREEN_H }, nodes = nodes, tooltip = tip, chat = chat, errors = errors,
    missing = missingList, objects = #objects, ms = math.floor((os.clock() - started) * 1000),
    lfd = LibForeverData and LibForeverData.version or false,
  }
end

local ok, err = xpcall(run, function(e) return debug.traceback(tostring(e), 2) end)
local out = {}
if ok then
  local okDump, result = xpcall(dump, function(e) return debug.traceback(tostring(e), 2) end)
  if okDump then encode(result, out) else encode({ error = result }, out) end
else
  encode({ error = err, errors = errors, chat = chat }, out)
end
io.write(table.concat(out))
