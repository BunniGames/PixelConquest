--!strict
-- Conquest :: Palette
-- Terrain and player colours, as plain RGB byte triples so the renderer can
-- write them straight into the pixel buffer without Color3 churn.

local Palette = {}

-- ------------------------------------------------------------- terrain -----
-- Ported from upstream openfrontio/OpenFrontIO,
-- `encodeTerrainTile` in src/client/render/gl/utils/ColorUtils.ts:102-180,
-- with its base colours in src/client/render/gl/render-settings.json:20-21.
-- The look is a
-- SMOOTH per-magnitude formula, not a quantised band table with dithering:
-- green lowland that darkens as it rises, tan highland that lightens as it
-- rises, near-white peaks -- and, the part that actually carries the style, a
-- flat sand SHORE on every land tile touching water with a bright rim on the
-- water beside it. Those two flat colours are what draw a coastline. Without
-- them the map reads as a heightfield; with them it reads as an atlas.
--
-- MapGen already flags shore tiles -- bit 6 of the terrain byte, set on BOTH
-- sides of every land/water edge, exactly the way the reference's own
-- generator does it. It was simply never read.
--
-- Conquest's magnitude bands sit one wider than the reference's (plains 0-10,
-- highland 11-20, mountain 21-30 against their 0-9 / 10-19 / 20-30) because
-- TileMap's gameplay thresholds are there -- but the arithmetic below is the
-- reference's own, so the colours land within a point or two of it.

local SHORE_R, SHORE_G, SHORE_B = 204, 203, 158 -- sand; #CCCB9E, flat, no ramp
local WATER_R, WATER_G, WATER_B = 71, 133, 181 -- #4785b5
local VOID_R, VOID_G, VOID_B = 60, 60, 60 -- #3c3c3c, impassable / off-map

-- Shoreline water is DERIVED, not a constant: 70% ocean + 30% white. Upstream
-- still carries a literal `shoreWater: [100, 143, 255]` in its terrain colour
-- table, but that entry is DEAD -- the water branch computes this blend
-- instead, and 100,143,255 is a hard periwinkle that no longer appears
-- anywhere on their map. Deriving it also means the rim tracks the ocean
-- colour if that is ever retuned, which a literal cannot.
local SHORE_WATER_R = math.round(0.7 * WATER_R + 76.5)
local SHORE_WATER_G = math.round(0.7 * WATER_G + 76.5)
local SHORE_WATER_B = math.round(0.7 * WATER_B + 76.5)

-- Depth barely ramps in the reference -- eleven steps on one base -- so the sea
-- reads as a single body with a hint of shelf rather than as a depth chart.
-- Conquest's water magnitude runs 0-26 (BFS coarse cells x 2.2) where theirs
-- runs 0-31, so this scale puts the ramp's knee a comparable distance offshore.
local WATER_DEPTH_SCALE = 1 / 2.6

-- terrainType: 0 water, 1 plains, 2 highland, 3 mountain, 4 impassable.
function Palette.terrainSample(
	terrainType: number,
	magnitude: number,
	shore: boolean
): (number, number, number)
	if terrainType == 4 then
		return VOID_R, VOID_G, VOID_B
	end
	if terrainType == 0 then
		if shore then
			return SHORE_WATER_R, SHORE_WATER_G, SHORE_WATER_B
		end
		local d = magnitude * WATER_DEPTH_SCALE
		if d > 10 then
			d = 10
		end
		-- The base colour is the SHALLOWEST shade and depth subtracts from it,
		-- so the sea is at its brightest against the coast.
		return WATER_R - d, WATER_G - d, WATER_B - d
	end
	if shore then
		return SHORE_R, SHORE_G, SHORE_B
	end
	if terrainType == 1 then
		return 190, 220 - 2 * magnitude, 138
	elseif terrainType == 2 then
		return 200 + 2 * magnitude, 183 + 2 * magnitude, 138 + 2 * magnitude
	end
	local v = 230 + magnitude * 0.5
	if v > 255 then
		v = 255
	end
	return v, v, v
end

-- Kept for callers that want a colour without knowing about the shore flag.
function Palette.terrainColor(terrainType: number, magnitude: number): (number, number, number)
	return Palette.terrainSample(terrainType, magnitude, false)
end

-- ------------------------------------------------------------ hsl utils ----
-- Border darkening is specified in LIGHTNESS, not as an RGB subtraction, and
-- the difference is not cosmetic. A flat "minus 40 per channel" costs a dark
-- nation a far larger share of its brightness than a bright one -- across our
-- bot ramp (value 100-190) it drives the darkest nations' outlines almost to
-- black while barely touching the pale ones. Scaling lightness is uniform.

local function rgbToHsl(r: number, g: number, b: number): (number, number, number)
	r, g, b = r / 255, g / 255, b / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local l = (mx + mn) / 2
	if mx == mn then
		return 0, 0, l
	end
	local d = mx - mn
	local s = l > 0.5 and d / (2 - mx - mn) or d / (mx + mn)
	local h
	if mx == r then
		h = (g - b) / d + (g < b and 6 or 0)
	elseif mx == g then
		h = (b - r) / d + 2
	else
		h = (r - g) / d + 4
	end
	return h / 6, s, l
end

local function hueToRgb(p: number, q: number, t: number): number
	if t < 0 then
		t += 1
	elseif t > 1 then
		t -= 1
	end
	if t < 1 / 6 then
		return p + (q - p) * 6 * t
	elseif t < 1 / 2 then
		return q
	elseif t < 2 / 3 then
		return p + (q - p) * (2 / 3 - t) * 6
	end
	return p
end

local function hslToRgb(h: number, s: number, l: number): (number, number, number)
	if s == 0 then
		return l * 255, l * 255, l * 255
	end
	local q = l < 0.5 and l * (1 + s) or l + s - l * s
	local p = 2 * l - q
	return hueToRgb(p, q, h + 1 / 3) * 255, hueToRgb(p, q, h) * 255, hueToRgb(p, q, h - 1 / 3) * 255
end

-- Drop lightness by `amount` (absolute, 0-1), holding hue and saturation.
function Palette.darken(r: number, g: number, b: number, amount: number): (number, number, number)
	local h, s, l = rgbToHsl(r, g, b)
	l -= amount
	if l < 0 then
		l = 0
	end
	return hslToRgb(h, s, l)
end

-- Pull saturation toward grey by `factor` (1 = unchanged).
function Palette.desaturate(r: number, g: number, b: number, factor: number): (number, number, number)
	local h, s, l = rgbToHsl(r, g, b)
	return hslToRgb(h, s * factor, l)
end

-- -------------------------------------------------------------- players ----
-- Generated by golden-angle hue rotation so any number of players stays
-- visually separable, with the local player forced to a fixed bright colour.

local PLAYER_COLORS: { { number } } = {}

local function hsvToRgb(h: number, s: number, v: number): (number, number, number)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p = v * (1 - s)
	local q = v * (1 - f * s)
	local t = v * (1 - (1 - f) * s)
	local r, g, b
	local m = i % 6
	if m == 0 then
		r, g, b = v, t, p
	elseif m == 1 then
		r, g, b = q, v, p
	elseif m == 2 then
		r, g, b = p, v, t
	elseif m == 3 then
		r, g, b = p, q, v
	elseif m == 4 then
		r, g, b = t, p, v
	else
		r, g, b = v, p, q
	end
	return math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)
end

do
	local GOLDEN = 0.6180339887
	local hue = 0.08
	for id = 1, 255 do
		hue = (hue + GOLDEN) % 1
		-- Saturated poster colours. Muted tones read as an atlas; this look
		-- wants bright flat nations separated by dark outlines. Still not
		-- FULL saturation -- that was the earlier neon failure -- and
		-- saturation/value alternate in bands so neighbouring hues differ in
		-- weight as well as hue, which is what separates them at 1px a tile.
		local band = id % 3
		local sat = 0.56 + band * 0.09
		local val = 0.93 - band * 0.07
		local r, g, b = hsvToRgb(hue, sat, val)
		PLAYER_COLORS[id] = { r, g, b }
	end
end

function Palette.playerColor(id: number): (number, number, number)
	local c = PLAYER_COLORS[id]
	if not c then
		return 200, 200, 200
	end
	return c[1], c[2], c[3]
end

-- ----------------------------------------------------------------- ai ------
-- ONLY HUMANS GET A COLOUR. AI empires paint in neutral whites and greys, so
-- the first thing a glance at the map answers is "which of these is a person".
-- They are still told apart from each other, but on two NEUTRAL axes --
-- lightness and a warm/cool cast -- because hue belongs to players now.

local botIds: { [number]: boolean } = {}

-- Kept clear of both ends of the terrain: below the snow band (245) so a pale
-- bot is not a mountain top, and well above the sea (53-70) so a dark one is
-- not a lake. Owned land is a FLAT fill, not a blend, so these are the exact
-- values that land on screen (times the 0.88-1.06 elevation step).
local BOT_LOW, BOT_HIGH = 104, 230

-- The same golden-angle walk the player hues use, applied to value instead:
-- consecutive ids land far apart, so the bots that spawn next to each other
-- are the ones most likely to be separable.
-- STILL USED BY THE TEAM PATH ONLY -- see botColor below for why free-for-all
-- cannot use it any more.
local function botGrey(id: number): (number, number, number)
	local t = (id * 0.6180339887) % 1
	local v = BOT_LOW + (BOT_HIGH - BOT_LOW) * t
	-- A whisper of cool cast -- not enough to be a colour, but enough that a
	-- mid grey never reads as the khaki/rock terrain band it sits beside.
	return v * 0.975, v * 0.99, math.min(v * 1.04, 255)
end

-- A ONE-AXIS ramp cannot carry 48 nations. The grey walk above spreads ids
-- over 126 levels of value and nothing else, which was ample at the old
-- 16-empire roster (12 bots sat 7.0/255 apart) and is nothing at all at 72:
-- measured, every one of the 70 adjacent pairs lands under 4/255 and the
-- minimum is 1.0. Two thirds of the map then paints as a single flat grey
-- field whose internal borders you can see but whose nations you cannot,
-- which is the whole map in an empty server.
--
-- The hue axis belongs entirely to players, so bots get a NEUTRAL ramp. That
-- is what this used to be and it failed, so the failure is worth restating: a
-- plain grey walk spreads ids over VALUE and nothing else, and between the sea
-- below and the snow band above there is only room for about eighteen steps a
-- player can tell apart. At 48 bots that is duplicates -- measured at 0.0
-- separation, i.e. literally the same colour twice.
--
-- The second axis therefore has to be one that stays neutral, and that is
-- TEMPERATURE: a warm/cool cast at low chroma, which reads as bone / paper /
-- ash / steel rather than as a colour. 18 values x 4 casts = 72 cells, sheared
-- so consecutive ids move on both axes.
--
-- THE RAMP MUST STOP BELOW THE ROCK. The MOUNTAIN band is itself neutral grey
-- (230-245), so a pale neutral bot painted over rock is invisible -- and
-- territory is a 0.588 alpha blend, which halves whatever difference survives.
-- The ladder stops at 212. An even number of casts matters for the same reason
-- (an odd count puts one band at exactly neutral; +-1, +-1/3 never passes
-- through zero), and on its own it is NOT enough: at a ceiling of 240 the
-- inner +-1/3 casts still came within 1.7 of bare rock.
--
-- THE BAND IS DELIBERATELY NARROW. The AI is meant to read as ONE monotone
-- mass rather than as a spread of tints, so the ladder spans 62 levels at
-- chroma 12 where it opened at 148 and 36. That trade is close to free in
-- every direction but one: compressing toward a mid grey moves the ramp AWAY
-- from both the green lowland and the white rock, so terrain clearance
-- IMPROVES (6.5 -> 9.5) and so does distance from the nearest player colour
-- (15.7 -> 19.5). The entire cost lands on telling one AI from the next.
--
-- WHAT MAKES THAT COST PAYABLE: borders are drawn at FULL OPACITY from the
-- nation's own colour darkened, so two adjacent AI nations are always outlined
-- even when their fills are indistinguishable. A monotone fill loses "WHICH AI
-- is this", never "is this two nations or one".
--
-- Measured over ALL 72 CELLS -- not over a window of ids, which is exactly the
-- mistake that once hid the rock collision, since the server assigns ids and
-- they land where they land. Taken on the COMPOSITED pixel: desaturate(0.85),
-- then alpha 0.588 over terrain, at the darker 0.88 end of the elevation
-- shading. That is ~0.43x the raw palette gap, so these are NOT comparable to
-- the pre-2026-08-30 figures above them:
--                        bot/bot   bot/human   bot/terrain
--   hued bots (older)        5.5        13.0           6.4
--   neutral, wide band       3.9        15.7           6.5
--   this, monotone           1.3        19.5           9.5
--   for scale: human/human 3.7, human/terrain 4.2
--
-- Band width and BOT_TEMP_AMP together are the monotone dial, and bot/bot is
-- near-linear in them: 80-228 amp 18 -> 3.9, 120-220 amp 12 -> 2.6,
-- 140-216 amp 8 -> 1.7, 150-212 amp 6 -> 1.3, 168-200 amp 3 -> 0.7. DO NOT
-- take the amplitude to zero: only ~18 lightness steps fit a band this narrow,
-- so 54 of the 72 cells collapse into exact DUPLICATES and two neighbouring
-- nations end up painted the identical colour.
local BOT_LEVELS, BOT_TEMPS = 18, 4
local BOT_VAL_LOW, BOT_VAL_HIGH = 150, 212
-- Chroma is twice this. At 6 the cast is barely perceptible and the ramp reads
-- as a single grey; the hued bots this replaced ran chroma 52, a player 149.
local BOT_TEMP_AMP = 6
-- 3 is coprime with 4, so (value, cast) is still a bijection over the 72 cells
-- and no two bots can draw the same pair.
local BOT_SHEAR = 3

local function botColor(id: number): (number, number, number)
	local k = (id - 1) % (BOT_LEVELS * BOT_TEMPS)
	local vi = k % BOT_LEVELS
	local ti = (math.floor(k / BOT_LEVELS) + vi * BOT_SHEAR) % BOT_TEMPS
	local v = BOT_VAL_LOW + (BOT_VAL_HIGH - BOT_VAL_LOW) * (vi / (BOT_LEVELS - 1))
	-- Symmetric about neutral and luminance-preserving: red up and blue down by
	-- the same amount, so a cast never reads as brighter than its neighbour and
	-- the value ladder stays the only lightness signal.
	local t = (ti / (BOT_TEMPS - 1)) * 2 - 1
	return math.clamp(v + t * BOT_TEMP_AMP, 0, 255),
		v,
		math.clamp(v - t * BOT_TEMP_AMP, 0, 255)
end

-- `map` is { [playerId] = true }. Mirrors `setTeams`: returns whether any id
-- that ALREADY had a colour now has a different one, so the client can skip
-- repainting 1.6M tiles when nothing on screen actually moved.
function Palette.setBots(map: { [number]: boolean }?): boolean
	local changed = false
	for id in botIds do
		if not (map and map[id]) then
			changed = true
			break
		end
	end
	if not changed and map then
		for id, v in map do
			if v and not botIds[id] then
				changed = true
				break
			end
		end
	end
	table.clear(botIds)
	if map then
		for id, v in map do
			if v then
				botIds[id] = true
			end
		end
	end
	return changed
end

function Palette.isBot(id: number): boolean
	return botIds[id] == true
end

-- ---------------------------------------------------------------- teams ----
-- In a team mode every member of a team paints in the SAME HUE, so the map
-- reads as two or three blocs at a glance -- that bloc read is the whole point
-- of the mode and it has to survive being seen at one pixel per tile. But
-- members still need telling apart when a front runs through their own colour,
-- so each gets a distinct value/saturation step inside the team hue. Hue
-- barely moves; value and saturation carry the separation.

-- In a team mode a bot cannot go fully grey: telling an ally from an enemy is
-- the entire mode. It keeps this fraction of its team colour -- enough to
-- place it in a bloc, far short of the humans' full-saturation fill.
local BOT_TEAM_TINT = 0.24

local TEAM_HSV = {
	{ 0.985, 0.74, 0.96 }, -- crimson
	{ 0.590, 0.72, 0.97 }, -- azure
	{ 0.335, 0.66, 0.86 }, -- verdant
}

Palette.TEAM_TAGS = { "RED", "BLU", "GRN" }
Palette.TEAM_NAMES = { "CRIMSON", "AZURE", "VERDANT" }
Palette.MAX_TEAMS = #TEAM_HSV

local MEMBER_HUE = { 0, 0.018, -0.018, 0.032, -0.032, 0.010, -0.010, 0.026 }
local MEMBER_SAT = { 1.00, 1.10, 0.84, 1.14, 0.92, 0.78, 1.05, 0.88 }
local MEMBER_VAL = { 1.00, 0.85, 1.06, 0.76, 0.94, 1.12, 0.81, 0.99 }

local teamOfId: { [number]: number } = {}
local teamRgb: { [number]: { number } } = {}
local activeTeamCount = 0

-- `map` is { [playerId] = teamIndex }; nil, or a count of 0, restores the
-- per-player golden-angle hues that free-for-all uses.
-- Returns whether any id that ALREADY had a colour now has a different one.
-- A mid-round joiner always takes the highest id, and variants are handed out
-- in id order, so it APPENDS to its team and shifts nobody -- yet the client
-- used to repaint all 1.6M tiles on every join because some team assignment
-- had changed. On a busy server that is a full-map repaint per join, for
-- everyone. Let the caller ask whether anything it has already drawn moved.
function Palette.setTeams(map: { [number]: number }?, count: number?): boolean
	local prev = table.clone(teamRgb)
	table.clear(teamOfId)
	table.clear(teamRgb)
	activeTeamCount = count or 0
	if not map or activeTeamCount <= 0 then
		activeTeamCount = 0
		return next(prev) ~= nil
	end

	-- Variants are handed out in ID ORDER, not iteration order: a hash walk is
	-- unordered, so the same round would shade the same player differently on
	-- two clients, and differently again on any later rebuild.
	local ids = {}
	for id in map do
		table.insert(ids, id)
	end
	table.sort(ids)

	local seen: { [number]: number } = {}
	for _, id in ids do
		local t = map[id]
		local hsv = TEAM_HSV[((t - 1) % #TEAM_HSV) + 1]
		local k = seen[t] or 0
		seen[t] = k + 1
		local vi = (k % #MEMBER_HUE) + 1
		local r, g, b = hsvToRgb(
			(hsv[1] + MEMBER_HUE[vi]) % 1,
			math.clamp(hsv[2] * MEMBER_SAT[vi], 0, 1),
			math.clamp(hsv[3] * MEMBER_VAL[vi], 0, 1)
		)
		teamOfId[id] = t
		teamRgb[id] = { r, g, b }
	end

	for id, old in prev do
		local now = teamRgb[id]
		if not now or now[1] ~= old[1] or now[2] ~= old[2] or now[3] ~= old[3] then
			return true
		end
	end
	return false
end

function Palette.activeTeams(): number
	return activeTeamCount
end

function Palette.teamOf(id: number): number?
	return teamOfId[id]
end

function Palette.teamTag(t: number?): string
	return t and Palette.TEAM_TAGS[((t - 1) % #Palette.TEAM_TAGS) + 1] or ""
end

function Palette.teamName(t: number?): string
	return t and Palette.TEAM_NAMES[((t - 1) % #Palette.TEAM_NAMES) + 1] or ""
end

function Palette.teamColor3(t: number): Color3
	local hsv = TEAM_HSV[((t - 1) % #TEAM_HSV) + 1]
	local r, g, b = hsvToRgb(hsv[1], hsv[2], hsv[3])
	return Color3.fromRGB(r, g, b)
end

-- The local player is always this, whatever id they drew, so "where am I" is
-- answerable at a glance. It was a warm near-white until 2026-08-30, which
-- worked only while the AI was dark and hued -- against a white/grey AI ramp
-- that colour is just one of the crowd (measured 12.6 from the nearest bot,
-- against 27.7 for this one). Vivid magenta is the far corner of the space
-- from everything else on screen: 27.7 from the nearest bot, 33.9 from any
-- terrain, and still 10.7 from the closest other player's colour.
local LOCAL_R, LOCAL_G, LOCAL_B = 255, 105, 210

function Palette.colorFor(id: number, localId: number): (number, number, number)
	local c = teamRgb[id]
	if c then
		if botIds[id] and id ~= localId then
			local gr, gg, gb = botGrey(id)
			return gr + (c[1] - gr) * BOT_TEAM_TINT,
				gg + (c[2] - gg) * BOT_TEAM_TINT,
				gb + (c[3] - gb) * BOT_TEAM_TINT
		end
		if id == localId and id ~= 0 then
			-- Still the TEAM's colour, lifted toward white rather than swapped
			-- for the free-for-all near-white: "where am I" has to be
			-- answerable at a glance without breaking the bloc read that the
			-- mode exists for.
			return c[1] + (255 - c[1]) * 0.52,
				c[2] + (255 - c[2]) * 0.52,
				c[3] + (255 - c[3]) * 0.52
		end
		return c[1], c[2], c[3]
	end
	if id == localId and id ~= 0 then
		return LOCAL_R, LOCAL_G, LOCAL_B
	end
	if botIds[id] then
		return botColor(id)
	end
	return Palette.playerColor(id)
end

function Palette.playerColor3(id: number, localId: number?): Color3
	local r, g, b = Palette.colorFor(id, localId or -1)
	return Color3.fromRGB(r, g, b)
end

return Palette
