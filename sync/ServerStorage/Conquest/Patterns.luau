--!strict
-- Conquest :: Patterns
-- The tile pattern a player wears on their own territory: a small repeating
-- grid of lightness steps, laid over their empire's colour AFTER that colour
-- has been composited over the terrain.
--
-- WHY TEXTURE AND NOT COLOUR. On this map colour is DATA. It is read at one
-- pixel per tile with up to 72 empires on screen and the palette is tuned for
-- exactly that separation (Palette has the measurements), so a cosmetic that
-- moved anybody's hue would degrade every other player's read of the board.
-- The one axis a player may customise is therefore TEXTURE, spent strictly
-- inside their own colour. Four rules make that safe, and none of them is
-- decoration:
--
--  1. HUE IS NEVER TOUCHED. A cell adds the SAME signed amount to all three
--     channels, which leaves every channel difference exactly as it was and
--     therefore leaves the hue exactly as it was. What a pattern spends is
--     lightness, and a little saturation with it.
--  2. EVERY PATTERN IS ZERO-MEAN, IN COLOUR AND NOT ONLY IN WEIGHT. `compile`
--     centres the grid, and because the step above is LINEAR in the weight and
--     the same size in both directions, a zero-mean grid is a zero-mean shift
--     on the actual pixels. The average colour of a patterned empire is the
--     average colour of an unpatterned one, so "which empire is that" is
--     answered by the same signal it was before patterns existed -- which is
--     what lets one player wear a pattern without costing everyone else.
--
--     THIS IS NOT A DETAIL, and getting it wrong is invisible in a swatch.
--     The first version lifted toward white and darkened by multiplying --
--     both hue-safe, neither the same SIZE -- and measured on real composited
--     map pixels it moved a nation's mean blue by 7/255. Human colours on this
--     map sit 3.7 apart and AI colours 1.3 (Palette has the table), so a
--     "cosmetic" was shifting empires nearly twice as far as the palette
--     separates them. Any future change here has to be re-measured the same
--     way: paint a block, mean it over a whole number of pattern periods,
--     and check the shift is under a tenth of a level.
--  3. BORDERS ARE NEVER PATTERNED (see Renderer). The outline is the layer
--     that says where one nation stops and the next begins; texture stays
--     inside it, and the amplitude below stays well under the border's own
--     darkening so a pattern can never be mistaken for an edge.
--  4. AI EMPIRES NEVER WEAR ONE. The bot ramp is deliberately monotone so
--     that a glance answers "which of these is a person" -- a patterned bot
--     would read as a player.
--
-- ----------------------------------------------------------------- ladder --
-- Six steps, and the ordering is meant to be legible without reading a word:
-- the tier colour, the price and the amount of geometry on the swatch all
-- move together, worst to best.
--
--   STARTER    free       no pattern at all
--   COMMON     500        one sparse mark on an otherwise plain field
--   UNCOMMON   2,000      a regular grid you could name
--   RARE       8,000      directional -- it runs across the territory
--   EPIC       32,000     two-tone: a light AND a dark, so it has a figure
--   LEGENDARY  128,000    a 16x16 ornament rather than a texture
--   EARNED     not sold   won, or given by the free-rewards sheet
--
-- EVERY STEP IS EXACTLY 4x THE ONE BELOW IT (2026-09-04, owner). The first
-- ladder ran 500 / 2,000 / 5,000 / 12,000 / 25,000 -- which is 4x, then 2.5x,
-- 2.4x, 2.1x, so it FLATTENED exactly where it was supposed to steepen and the
-- top three steps ended up costing roughly the same as each other. A constant
-- multiplier is also the only ladder a player can read straight off the
-- prices: meeting the 4x once tells you what every step after it costs.
--
-- PRICED IN HOURS OF PLAY, NOT IN GAMES, because a game is not a fixed amount
-- of anything here -- the rotation runs 4.9 to 67.5 minutes and Money banks at
-- the moment your empire falls, so two players in the same round can be paid
-- an hour apart. The measured rate is 1,868 to 5,129 Money per hour of play
-- across the 21 map/mode pairs, mean 3,308 (MONEYBALANCE.txt, section 7).
-- Against that mean:
--
--   COMMON     ~9 min     bought before a first long game has finished
--   UNCOMMON   ~35 min    one sitting
--   RARE       ~2.4 h
--   EPIC       ~10 h
--   LEGENDARY  ~39 h      an hour a day for a month; the top of the shop
--
-- Patterns are still the ONLY sink this currency has, so the ceiling is set by
-- how long the game should keep having something left to want, not by
-- competition with another thing to spend on. Revisit it the day a second sink
-- ships. The EARNED patterns sit outside that ladder deliberately: no number of
-- hours reaches them. Two are won; the third is the free-rewards grant, which
-- is a different door again and still not a price.

-- For the SWATCH at the bottom of this file, and for nothing above it. Both
-- are safe on a server that requires this module for the catalogue alone:
-- GetService always resolves, Palette is pure arithmetic with no requires of
-- its own (so there is no cycle), and the one call that would actually fail
-- off a client -- CreateEditableImage -- happens only inside Patterns.swatch.
local AssetService = game:GetService("AssetService")
local Palette = require(script.Parent.Palette)

local Patterns = {}

-- ------------------------------------------------------------ amplitude ----
-- A full step moves every channel by the same amount, and that amount is a
-- fraction of the fill's SYMMETRIC HEADROOM -- how far all three channels can
-- travel together, in either direction, before any of them would clip.
--
-- HEADROOM RATHER THAN A FLAT NUMBER, because clipping is how the zero-mean
-- guarantee above dies: one channel pinned at 255 on the light cells and free
-- on the dark ones is exactly the asymmetry rule 2 exists to forbid. Deriving
-- the step from the room actually available means it never happens, at the
-- price of a slightly quieter pattern on the very brightest fills -- and the
-- cap below is what stops the darker two thirds of the palette from getting a
-- LOUDER one than anybody wanted.
--
-- The ceiling is set by the border. `Renderer`'s BORDER_DARKEN_L is 0.125 of
-- LIGHTNESS, about 32/255 on a mid colour; a pattern topping out at 26 is
-- plainly visible at one pixel a tile -- the terrain's own detail noise shows
-- through an owned tile at about 6/255, so this is four times the map's
-- natural grain -- and still weaker than an outline, so texture can never be
-- mistaken for an edge.
Patterns.AMPLITUDE = 0.55
Patterns.MAX_STEP = 26

-- Compiled weights are stored as i8 with 64 = one full step, so the grids keep
-- their fractional means without needing a float buffer.
local UNIT = 64
local AMP = Patterns.AMPLITUDE
local MAX_STEP = Patterns.MAX_STEP
local INV_UNIT = 1 / UNIT

-- Applies a sampled weight to an already-composited fill. ONE definition,
-- called by both the map renderer and the shop's preview swatches -- a preview
-- that composites its own way is a preview that lies, and for a cosmetic this
-- deliberately quiet the preview IS the product.
function Patterns.apply(r: number, g: number, b: number, k: number): (number, number, number)
	if k == 0 then
		return r, g, b
	end
	local lo = r < g and r or g
	if b < lo then
		lo = b
	end
	local hi = r > g and r or g
	if b > hi then
		hi = b
	end
	local head = 255 - hi
	if lo < head then
		head = lo
	end
	local d = head * AMP
	if d > MAX_STEP then
		d = MAX_STEP
	end
	d = d * k * INV_UNIT
	return r + d, g + d, b + d
end

-- ------------------------------------------------------------- rainbow ----
-- A LITERAL RAINBOW (owner, 2026-09-15: "i meant in colour it should literally
-- be rainbow in colour").
--
-- THIS IS THE ONE PATTERN THAT SPENDS HUE, and it is a deliberate EXCEPTION to
-- rule 1 at the top of this file rather than a loosening of it. `apply` above
-- is untouched, so the other twenty patterns keep the zero-mean, hue-safe
-- guarantee that was measured on real composited pixels -- everything in this
-- section runs for exactly one def, and the renderer reaches it through a
-- different door.
--
-- WHAT IT COSTS, said plainly because the header promises this is never spent:
-- a VIP empire is no longer identified by its palette colour. It is identified
-- by being the rainbow one, which on a board of flat fills is the least
-- ambiguous thing on the map -- but the read is different in kind, and a
-- second wearer would look like the first. That is survivable only because the
-- pass is the one thing that grants it.
--
-- WHAT IT DOES NOT COST IS THE BORDER. The sweep is laid in the renderer's
-- INTERIOR branch with every other pattern, so the outline that says where one
-- nation stops and the next begins is still drawn in the empire's own colour.
-- Rule 3 is the one rule here that genuinely cannot bend.
--
-- STILL NOT ANIMATED, and that part of MONETIZATION.txt section 3 has not
-- changed: the territory layer repaints off a 5 Hz broadcast, and a per-tile
-- animation is a performance problem and a legibility problem at once. The
-- sweep is a pure function of POSITION, so it costs one array read.
--
-- 45 DEGREES, SIXTEEN TILES TO THE CYCLE, which is the sweep the lightness
-- version was already drawing: (x + y) is the diagonal its rotated rows made,
-- and the period matches its grid, so the SCALE of the thing is unchanged and
-- only the currency is different. Hue is cyclic, so the wrap at the end of a
-- period is seamless -- which the old triangular ramp could never be.
--
-- A POWER OF TWO, like every grid width here, because the sampler wraps with a
-- bitwise AND inside the per-tile recolour.
local RAINBOW_STEPS = 16

-- HOW MUCH OF THE FILL THE SWEEP TAKES, and THE DIAL if this reads too loud on
-- the map: 1 is pure spectrum with nothing of the empire's colour left, and 0
-- leaves the fill alone -- at which point the def's `cells` (still compiled,
-- still a valid lightness grid) are what you see instead, which is exactly the
-- pattern this one used to be.
local RAINBOW_MIX = 0.85

-- Precomputed, because this is read once per owned tile of a wearer's
-- territory inside the renderer's recolour. THREE FLAT ARRAYS rather than a
-- table of triples or a Color3 per tile: one index, three array reads, no
-- allocation in the hot loop.
--
-- Full saturation is the entire point -- these are deliberately not the map's
-- muted fills -- and the value sits just under 1 so the bright end of the
-- spectrum has somewhere to go before it clips.
local RAINBOW_R = table.create(RAINBOW_STEPS)
local RAINBOW_G = table.create(RAINBOW_STEPS)
local RAINBOW_B = table.create(RAINBOW_STEPS)
for i = 1, RAINBOW_STEPS do
	local c = Color3.fromHSV((i - 1) / RAINBOW_STEPS, 1, 0.95)
	RAINBOW_R[i] = c.R * 255
	RAINBOW_G[i] = c.G * 255
	RAINBOW_B[i] = c.B * 255
end

-- The finished fill, swept toward the spectrum.
--
-- TAKES THE TILE, NOT A SAMPLED WEIGHT, which is why this is a second entry
-- point beside `apply` instead of another branch inside it: a hue is a
-- property of WHERE a tile is, and there is no zero cell to skip -- every tile
-- of a rainbow territory is coloured.
function Patterns.rainbow(r: number, g: number, b: number, x: number, y: number): (number, number, number)
	local i = bit32.band(x + y, RAINBOW_STEPS - 1) + 1
	return r + (RAINBOW_R[i] - r) * RAINBOW_MIX,
		g + (RAINBOW_G[i] - g) * RAINBOW_MIX,
		b + (RAINBOW_B[i] - b) * RAINBOW_MIX
end

-- ---------------------------------------------------------------- tiers ----
-- The rarity colours are the kit's own ladder, which this page already speaks:
-- the lobby's JOIN pills are green / blue / magenta for common / rare / ultra.

export type Tier = {
	key: string,
	name: string,
	color: Color3,
	price: number,
	blurb: string,
}

Patterns.TIERS = {
	{
		key = "starter",
		name = "STARTER",
		color = Color3.fromRGB(150, 163, 186),
		price = 0,
		blurb = "Yours from the start.",
	},
	{
		key = "common",
		name = "COMMON",
		color = Color3.fromRGB(126, 205, 133),
		price = 500,
		blurb = "A quiet mark on open ground.",
	},
	{
		key = "uncommon",
		name = "UNCOMMON",
		color = Color3.fromRGB(92, 173, 245),
		price = 2000,
		blurb = "A grid you can name from across the map.",
	},
	{
		key = "rare",
		name = "RARE",
		color = Color3.fromRGB(157, 133, 247),
		price = 8000,
		blurb = "Runs across the territory it covers.",
	},
	{
		key = "epic",
		name = "EPIC",
		color = Color3.fromRGB(228, 118, 214),
		price = 32000,
		blurb = "Two tones, so the weave has a figure.",
	},
	{
		key = "legendary",
		name = "LEGENDARY",
		color = Color3.fromRGB(232, 196, 110),
		price = 128000,
		blurb = "An ornament, not a texture.",
	},
	{
		key = "earned",
		name = "EARNED",
		color = Color3.fromRGB(240, 244, 252),
		price = 0,
		blurb = "Not for sale. Win for it.",
	},
} :: { Tier }

local tierByKey: { [string]: Tier } = {}
local tierRank: { [string]: number } = {}
for i, t in Patterns.TIERS do
	tierByKey[t.key] = t
	tierRank[t.key] = i
end

function Patterns.tier(key: string): Tier
	return tierByKey[key] or Patterns.TIERS[1]
end

function Patterns.tierRank(key: string): number
	return tierRank[key] or 1
end

-- ------------------------------------------------------------- the grids ---
-- One character per tile:  '#' -2   '-' -1   '.' 0   '+' +1   '*' +2
-- Both dimensions MUST be powers of two -- the sampler wraps with a bitwise
-- AND rather than a modulo, because it runs inside the per-tile recolour.
--
-- Values are relative and get centred and normalised by `compile`, so what
-- matters in a grid is the SHAPE and the relative weight of its parts, never
-- the absolute numbers.

export type Def = {
	key: string,
	name: string,
	tier: string,
	-- Wins on the account before this can be worn. Only the earned tier sets
	-- it; everything else is bought.
	wins: number?,
	-- ROBUX SKINS (2026-09-08). `product` is the developer product that
	-- unlocks this pattern -- named HERE so the catalogue and the receipt
	-- handler cannot drift (ConquestMonetization registers a grant per def
	-- that carries one), and it is also what makes a def Robux-only: Money
	-- cannot buy it at any price.
	product: string?,
	-- WHAT WEARING IT DOES: the fraction added to troop growth. Independent
	-- of `product` -- the EPIC tier carries +5% for Money and the Robux
	-- legendaries +10%. Sim reads it off the empire, where
	-- ConquestServer.applyPattern put it, and the card prints it in green
	-- between the name and the price. Deliberately SMALL: a tenth more
	-- income is a lead and not a wall, every combat constant is untouched,
	-- and the ceiling (maxTroops) does not move -- the army arrives sooner,
	-- it never gets bigger.
	boost: number?,
	-- ...and the same for GOLD income (owner, 2026-09-08: "give the remaining
	-- legendary ones +10% gold, and change 1 epic one to +5% gold"). Gold is
	-- flat per tick, so this is a tenth more treasury a minute -- cities and
	-- ports sooner, never bigger armies.
	goldBoost: number?,
	-- INCLUDED WITH THE VIP PASS (2026-09-15), and not for sale at any price.
	-- A THIRD OWNERSHIP AXIS beside `wins` and `product`: Money cannot buy it
	-- (mayBuy refuses), the shop draws it as VIP instead of as a price, and the
	-- grant is ConquestMonetization's, made the moment the site confirms the
	-- pass. It is still recorded in `profile.patterns` like everything else, so
	-- the renderer, the equip path and Data.patternKey need to know nothing
	-- about VIP at all.
	vip: boolean?,
	-- GRANTED BY THE FREE REWARDS SHEET (2026-09-17), and a FOURTH ownership
	-- axis beside `wins`, `product` and `vip`. It exists because the earned
	-- tier's PRICE IS ZERO: a def in that tier with no `wins` on it satisfies
	-- `money >= price` for every account at every balance, so without this
	-- flag the shop would hand the skin to everybody for nothing. mayBuy
	-- refuses it and `standing` is never affordable; the only way in is
	-- Data.claimFreeReward.
	reward: boolean?,
	-- SPENDS HUE INSTEAD OF LIGHTNESS, and exactly one def may set it. The
	-- renderer and the shop swatch both branch to `Patterns.rainbow` for this
	-- one and never call `apply` on it. See the rainbow section above for what
	-- that exception costs and what it is not allowed to touch.
	rainbow: boolean?,
	cells: { string },
}

-- ORDER IS THE WIRE FORMAT. A pattern's INDEX in this list is the byte that
-- rides in the roster, so entries may be appended and renamed but never
-- reordered or removed -- and ownership is recorded by KEY, so that a
-- reordering (or a mistake) can never hand somebody a pattern they did not
-- buy. Index 1 is "no pattern" and is what every account starts on.
Patterns.LIST = {
	{
		key = "solid",
		name = "Solid",
		tier = "starter",
		cells = {},
	},

	-- ------------------------------------------------------------ common --
	{
		key = "speckle",
		name = "Speckle",
		tier = "common",
		cells = {
			"..#.....",
			".....#..",
			"#.......",
			"...#..#.",
			"......#.",
			".#......",
			"....#...",
			"#.....#.",
		},
	},
	{
		key = "pinstripe",
		name = "Pinstripe",
		tier = "common",
		-- One column in four, and only one row of grid to say it: a stripe
		-- that does not vary down the map does not need to be stored twice.
		cells = { "#..." },
	},
	{
		key = "furrows",
		name = "Furrows",
		tier = "common",
		cells = {
			"##..##..",
			"........",
			"..##..##",
			"........",
		},
	},

	-- ---------------------------------------------------------- uncommon --
	{
		key = "checker",
		name = "Checker",
		tier = "uncommon",
		-- FOUR tiles to a square, not two. At one screen pixel a tile a 2x2
		-- check is a dither -- it reads as noise rather than as squares.
		cells = {
			"####++++",
			"####++++",
			"####++++",
			"####++++",
			"++++####",
			"++++####",
			"++++####",
			"++++####",
		},
	},
	{
		key = "brick",
		name = "Brick",
		tier = "uncommon",
		cells = {
			"########",
			"...#...#",
			"...#...#",
			"...#...#",
			"########",
			"#...#...",
			"#...#...",
			"#...#...",
		},
	},
	{
		key = "grid",
		name = "Grid",
		tier = "uncommon",
		cells = {
			"########",
			"#.......",
			"#.......",
			"#.......",
			"#.......",
			"#.......",
			"#.......",
			"#.......",
		},
	},

	-- -------------------------------------------------------------- rare --
	{
		key = "twill",
		name = "Twill",
		tier = "rare",
		cells = {
			"##..##..",
			".##..##.",
			"..##..##",
			"#..##..#",
		},
	},
	{
		key = "lattice",
		name = "Lattice",
		tier = "rare",
		cells = {
			"#......#",
			".#....#.",
			"..#..#..",
			"...##...",
			"...##...",
			"..#..#..",
			".#....#.",
			"#......#",
		},
	},
	-- CHEVRON LEFT THE RARE TIER (2026-09-17, owner: "maybe just use chevron
	-- for now. and move chevron out of rare"). It is the FREE REWARDS skin --
	-- it replaced one drawn for the job that did not read at map size -- so it
	-- is earned-tier, granted, and carries the +3%.
	--
	-- IT STAYS AT THIS POSITION IN THE LIST, which is why it is still sitting
	-- among the rare patterns it no longer belongs with. Its index is the wire
	-- byte the roster carries; moving it down into the earned block would
	-- renumber every pattern after it and hand people cosmetics they never
	-- bought. `tier` is the only thing that moved.
	--
	-- WHO ALREADY BOUGHT IT KEEPS IT. Ownership is recorded by key, so the
	-- 8,000 Money spent on a Chevron before today still owns a Chevron -- and
	-- now gets the +3% with it.
	{
		key = "chevron",
		name = "Chevron",
		tier = "earned",
		reward = true,
		boost = 0.03,
		cells = {
			"#..##..#",
			"##....##",
			".##..##.",
			"..####..",
		},
	},

	-- -------------------------------------------------------------- epic --
	-- +5% ARMY ON ALL THREE (owner, 2026-09-08: "make epic ones give +5%") --
	-- the first Money pattern that does anything, half the Robux skins' figure.
	{
		key = "waves",
		name = "Waves",
		tier = "epic",
		boost = 0.05,
		-- Sixteen wide: a swell needs a long enough period to read as one
		-- curve rather than as a zigzag, and the light band under each crest
		-- is what turns a line into a rolling surface.
		cells = {
			"..+++++.........",
			"...+++.....###..",
			"..........#####.",
			".........##+++##",
			"##.....###+++++#",
			"###...###++...++",
			"++#####+++.....+",
			"+++###+++.......",
		},
	},
	{
		key = "weave",
		name = "Weave",
		tier = "epic",
		boost = 0.05,
		cells = {
			".##.#..#",
			"#..#.##.",
			"#..#.##.",
			".##.#..#",
		},
	},
	{
		key = "argyle",
		name = "Argyle",
		tier = "epic",
		-- The one epic that pays in GOLD rather than troops.
		goldBoost = 0.05,
		cells = {
			"...#....",
			"..#+#...",
			".#+++#..",
			"#+++++#.",
			".#+++#..",
			"..#+#...",
			"...#....",
			"........",
		},
	},

	-- --------------------------------------------------------- legendary --
	{
		key = "mosaic",
		name = "Mosaic",
		tier = "legendary",
		goldBoost = 0.10,
		cells = {
			"################",
			"#..............#",
			"#..............#",
			"#..##########..#",
			"#..#........#..#",
			"#..#........#..#",
			"#..#.######.#..#",
			"#..#.#....#.#..#",
			"#..#.#....#.#..#",
			"#..#.######.#..#",
			"#..#........#..#",
			"#..#........#..#",
			"#..##########..#",
			"#..............#",
			"#..............#",
			"################",
		},
	},
	{
		key = "imperial",
		name = "Imperial",
		tier = "legendary",
		goldBoost = 0.10,
		-- A square and a diamond overlaid: the square's corners stand out of
		-- the diamond and the diamond's points out of the square, which is
		-- what makes an eight-pointed star instead of an octagon.
		cells = {
			"................",
			".......##.......",
			"......#++#......",
			"...###++++###...",
			"...#++++++++#...",
			"...#++++++++#...",
			"..#++++++++++#..",
			".#++++++++++++#.",
			".#++++++++++++#.",
			"..#++++++++++#..",
			"...#++++++++#...",
			"...#++++++++#...",
			"...###++++###...",
			"......#++#......",
			".......##.......",
			"................",
		},
	},

	-- ------------------------------------------------------------ earned --
	-- NOT FOR SALE AT ANY PRICE. Money can reach the tier below this one; the
	-- only way past it is to have won. Ordered by the win count, so the top of
	-- the whole ladder is the one number nobody can shortcut.
	{
		key = "crown",
		name = "Crown",
		tier = "earned",
		wins = 3,
		cells = {
			"#..#..#.",
			"#.###.#.",
			"#######.",
			"#######.",
			".#####..",
			"........",
			"........",
			"........",
		},
	},
	{
		key = "marble",
		name = "Marble",
		tier = "earned",
		wins = 15,
		-- The only pattern here that is not geometry. Five levels of an
		-- organic mottle -- which is what makes it read, instantly and from
		-- any distance, as a different KIND of thing from everything below.
		cells = {
			"#######------###",
			"#######-------##",
			"--######---....-",
			"+..######--.....",
			"++.-#####-..++++",
			"**+..---#-.++++*",
			"***+++.---.+++**",
			"*****++.--.+++**",
			"******+.-..++***",
			"******+.-..+++**",
			"*****++....+++**",
			"****+++.....+++*",
			"**++++.......++*",
			"+++............+",
			"..----------....",
			"#######-------##",
		},
	},

	-- ------------------------------------------------- legendary, robux --
	-- LEGENDARY TOO (owner, 2026-09-08: "i dont want +10% troops to be its own
	-- category, i want it to be legendary"), so the column holds five and the
	-- shop draws it two wide. APPENDED, never inserted above: the index is the
	-- wire byte and every profile that ever equipped Crown or Marble is keyed
	-- on the positions above. Each names the product that sells it and carries
	-- its own +10%; the card prints that between the name and the price.
	{
		key = "compass",
		name = "Compass",
		tier = "legendary",
		product = "SKIN_COMPASS",
		boost = 0.10,
		-- Eight spokes about a two-tile hub: read as a rose at any zoom, and
		-- the spokes meet their neighbours' at the tile edge so the whole
		-- territory reads as one lattice rather than as stamped badges.
		cells = {
			"#......##......#",
			".#.....##.....#.",
			"..#....##....#..",
			"...#...##...#...",
			"....#..##..#....",
			".....#.##.#.....",
			"......####......",
			"################",
			"################",
			"......####......",
			".....#.##.#.....",
			"....#..##..#....",
			"...#...##...#...",
			"..#....##....#..",
			".#.....##.....#.",
			"#......##......#",
		},
	},
	{
		key = "scales",
		name = "Scales",
		tier = "legendary",
		product = "SKIN_SCALES",
		boost = 0.10,
		-- Overlapping arcs. Each band is offset half a period from the one
		-- above, which is what makes the rings read as scales rather than
		-- as a row of coins.
		cells = {
			"...##...",
			"..#..#..",
			".#....#.",
			"#......#",
			"#......#",
			".#....#.",
			"..#..#..",
			"...##...",
		},
	},
	{
		key = "serpent",
		name = "Serpent",
		tier = "legendary",
		product = "SKIN_SERPENT",
		boost = 0.10,
		-- A light band three tiles wide winding through a full sine period,
		-- outlined dark: two-tone like the epic tier, but the figure is a
		-- curve, which nothing below it has.
		cells = {
			"................",
			"................",
			"...........###..",
			"..........#+++#.",
			".........#+++++#",
			".........+++++++",
			"#.......#++###++",
			"+.......+++#..#+",
			"+#.....#+#.....#",
			"++#...#++.......",
			"#++###++#.......",
			".+++++++........",
			".#+++++#........",
			"..#+++#.........",
			"...###..........",
			"................",
		},
	},

	-- --------------------------------------------------- legendary, VIP --
	-- THE VIP PATTERN (2026-09-15). Included with the pass and never for sale:
	-- `vip` is what says so, and mayBuy refuses it for Money at any balance.
	-- APPENDED, like everything before it -- the index is the wire byte.
	--
	-- IT IS A LITERAL RAINBOW, IN HUE (owner, 2026-09-15: "does this vip rainbow
	-- skin look rainbow to you. i meant in colour it should literally be rainbow
	-- in colour").
	--
	-- IT WAS NOT, AND COULD NOT HAVE BEEN. The first build spent LIGHTNESS --
	-- the only currency `apply` has, since it adds the same signed amount to all
	-- three channels and therefore cannot move a hue by construction -- so the
	-- cells below rendered as a diagonal light-to-dark sweep in the empire's own
	-- single colour. Correct to the letter of rule 1 at the top of this file,
	-- and not a rainbow by any reading of the word.
	--
	-- `rainbow = true` is what sends it down the hue path instead; see the
	-- rainbow section beside `apply` for the exception it makes, what that
	-- costs, and the one rule it still may not touch (the border).
	--
	-- THE CELLS BELOW ARE KEPT, and they are not dead: at RAINBOW_MIX = 0 they
	-- are exactly what draws again. They are still compiled, still zero-mean,
	-- still a legal lightness grid -- so the old pattern is one constant away
	-- rather than one revert away.
	--
	-- NO `boost` ON THE DEF. The pass already carries +10%
	-- (Config.VIP_GROWTH_BOOST, added in ConquestServer.applyPattern); a perk
	-- here as well would pay the same tenth twice.
	{
		key = "rainbow",
		name = "Rainbow",
		tier = "legendary",
		vip = true,
		rainbow = true,
		cells = {
			"**++..--##--..++",
			"*++..--##--..++*",
			"++..--##--..++**",
			"+..--##--..++**+",
			"..--##--..++**++",
			".--##--..++**++.",
			"--##--..++**++..",
			"-##--..++**++..-",
			"##--..++**++..--",
			"#--..++**++..--#",
			"--..++**++..--##",
			"-..++**++..--##-",
			"..++**++..--##--",
			".++**++..--##--.",
			"++**++..--##--..",
			"+**++..--##--..+",
		},
	},
} :: { Def }

Patterns.DEFAULT_KEY = "solid"
Patterns.COUNT = #Patterns.LIST

-- --------------------------------------------------------------- compile ---

local CHAR = { ["."] = 0, ["-"] = -1, ["#"] = -2, ["+"] = 1, ["*"] = 2 }

type Compiled = { data: buffer, w: number, wm: number, hm: number }

local compiled: { [number]: Compiled } = {}
local indexByKey: { [string]: number } = {}

-- CENTRED THEN NORMALISED, in that order, and both halves matter:
--   * centring is what makes the pattern free to everyone else's read of the
--     map (rule 2 at the top of this file);
--   * normalising to a peak of exactly one step is what puts every pattern on
--     the SAME contrast budget, so the ladder is a progression in geometry
--     rather than a progression in how loud a thing is allowed to be. A
--     sparse speckle and a checkerboard cost the map the same amount.
local function compile(index: number, def: Def)
	local rows = def.cells
	local h = #rows
	if h == 0 then
		return
	end
	local w = #rows[1]
	assert(w > 0 and bit32.band(w, w - 1) == 0, `pattern {def.key}: width {w} is not a power of two`)
	assert(bit32.band(h, h - 1) == 0, `pattern {def.key}: height {h} is not a power of two`)

	local raw = table.create(w * h)
	local sum = 0
	for y = 1, h do
		local row = rows[y]
		assert(#row == w, `pattern {def.key}: row {y} is {#row} wide, expected {w}`)
		for x = 1, w do
			local v = CHAR[string.sub(row, x, x)]
			assert(v ~= nil, `pattern {def.key}: unknown cell '{string.sub(row, x, x)}'`)
			raw[(y - 1) * w + x] = v
			sum += v
		end
	end

	local mean = sum / (w * h)
	local peak = 0
	for i = 1, w * h do
		local v = math.abs(raw[i] - mean)
		if v > peak then
			peak = v
		end
	end
	if peak <= 0 then
		return -- a grid with no contrast at all is the same as no pattern
	end

	local data = buffer.create(w * h)
	for i = 1, w * h do
		buffer.writei8(data, i - 1, math.round((raw[i] - mean) / peak * UNIT))
	end
	compiled[index] = { data = data, w = w, wm = w - 1, hm = h - 1 }
end

-- WHICH INDEX WEARS THE HUE SWEEP. Resolved from the def's own flag rather
-- than hard-coded, because the index is the wire byte and appending anything
-- above it would move the number. Stays 0 in a build with no rainbow def,
-- which no call site can match: the renderer's `pat` is never below 1.
Patterns.RAINBOW_INDEX = 0

-- WHICH KEY THE FREE REWARDS SHEET GRANTS, resolved from the def's own flag
-- for the reason RAINBOW_INDEX is: the server grants it, the sheet draws it
-- and the shop refuses to sell it, and three files naming a string literal is
-- three files that can disagree. "" in a build with no reward def, which
-- Patterns.byKey answers nil for.
Patterns.REWARD_KEY = ""

for i, def in Patterns.LIST do
	indexByKey[def.key] = i
	compile(i, def)
	if def.rainbow then
		Patterns.RAINBOW_INDEX = i
	end
	if def.reward then
		Patterns.REWARD_KEY = def.key
	end
end

-- The weight at a map tile, in 64ths of a full step. 0 for "no pattern",
-- which is both index 1 and any index this client has never heard of.
function Patterns.sample(index: number, x: number, y: number): number
	local c = compiled[index]
	if not c then
		return 0
	end
	return buffer.readi8(c.data, bit32.band(y, c.hm) * c.w + bit32.band(x, c.wm))
end

function Patterns.indexOf(key: string?): number
	return (key and indexByKey[key]) or 1
end

function Patterns.get(index: number): Def?
	return Patterns.LIST[index]
end

function Patterns.byKey(key: string?): Def?
	local i = key and indexByKey[key]
	return i and Patterns.LIST[i] or nil
end

-- Whether a pattern is sold for Robux rather than Money. The shop routes the
-- press to a purchase prompt; `mayBuy` refuses it for Money.
function Patterns.isRobux(def: Def): boolean
	return def.product ~= nil
end

-- Whether a pattern comes with the VIP pass rather than being bought at all.
-- The grant path for one is ConquestMonetization.settleVip, never a price.
function Patterns.isVip(def: Def): boolean
	return def.vip == true
end

-- Whether a pattern is GRANTED rather than bought or won. The grant path is
-- Data.claimFreeReward and there is no other one.
function Patterns.isReward(def: Def): boolean
	return def.reward == true
end

-- The MONEY price. Zero for a Robux skin, whatever its tier says: the tier
-- price is what the tier's Money patterns cost, and a Robux skin sitting in
-- that column is not for Money at all.
function Patterns.price(def: Def): number
	if Patterns.isRobux(def) then
		return 0
	end
	return Patterns.tier(def.tier).price
end

-- The troop-growth bonus a pattern INDEX carries: 0 for everything without
-- one, and for any index this build has never heard of. Read by
-- ConquestServer when it applies a pattern to an empire, and by nothing else.
function Patterns.boost(index: number?): number
	local def = index and Patterns.LIST[index] or nil
	if def == nil then
		return 0
	end
	return def.boost or 0
end

-- The GOLD-income bonus a pattern INDEX carries, on the same terms as boost.
function Patterns.goldBoost(index: number?): number
	local def = index and Patterns.LIST[index] or nil
	if def == nil then
		return 0
	end
	return def.goldBoost or 0
end

-- The card's green line: what wearing this does, or nil for a pattern that
-- does nothing. One string, so a def carrying both reads as one fact.
function Patterns.perkText(def: Def): string?
	local parts = {}
	if def.boost ~= nil and def.boost > 0 then
		table.insert(parts, string.format("+%d%% ARMY", math.floor(def.boost * 100 + 0.5)))
	end
	if def.goldBoost ~= nil and def.goldBoost > 0 then
		table.insert(parts, string.format("+%d%% GOLD", math.floor(def.goldBoost * 100 + 0.5)))
	end
	if #parts == 0 then
		return nil
	end
	return "(" .. table.concat(parts, ", ") .. ")"
end

-- ---------------------------------------------------------------- owners ---
-- Which empire is wearing which pattern, installed by the client exactly the
-- way Palette.setBots and Palette.setTeams are: BEFORE the renderer paints
-- anything, because every owned pixel is coloured through this.
--
-- A plain array over the whole id space rather than a sparse map: the renderer
-- reads it once per owned tile, and an array read beats a hash miss.

local owners = table.create(255, 1)
for i = 1, 255 do
	owners[i] = 1
end
Patterns.OWNER = owners

-- ONE EMPIRE AT A TIME, and there is no bulk form on purpose: the caller
-- reading a roster would have to build a map to pass to one, and the client
-- that does the reading is one local short of Luau's 200-per-scope ceiling.
-- This way the module's own array IS the state and nobody else keeps a copy.
--
-- Returns whether the answer actually MOVED, which is what decides a repaint.
-- The common case -- a profile landing a second after its owner joined --
-- moves exactly one id, and repainting that empire's own tiles beats
-- repainting all 1.6M of them by three orders of magnitude.
function Patterns.setOwner(id: number, index: number?): boolean
	if id < 1 or id > 255 then
		return false
	end
	local want = 1
	if type(index) == "number" and index >= 1 and index <= Patterns.COUNT then
		want = index
	end
	if owners[id] == want then
		return false
	end
	owners[id] = want
	return true
end

-- A new round. Called before the roster is read, so an empire id reused by a
-- different player cannot inherit the last round's pattern.
function Patterns.clearOwners()
	for id = 1, 255 do
		owners[id] = 1
	end
end

function Patterns.ownerOf(id: number): number
	return owners[id] or 1
end

-- --------------------------------------------------------------- account ---
-- What an account may wear, decided in ONE place because the server has to
-- enforce it and the shop has to draw it, and the two disagreeing is a button
-- that lies. `owned` is the profile's own { [key] = true }.

export type Standing = {
	owned: boolean,
	affordable: boolean,
	-- nil when nothing is missing; otherwise how many more wins are needed.
	winsShort: number?,
	price: number,
	-- Sold for Robux: the price above is 0 and means nothing, and `affordable`
	-- is always false because Money is not the currency.
	robux: boolean,
	-- Comes with the VIP pass. Same consequence as `robux` -- the price means
	-- nothing and `affordable` is always false -- but a different card and a
	-- different door, so the shop has to be able to tell them apart.
	vip: boolean,
	-- Granted by the free-rewards sheet. Same consequence as the two above --
	-- the price means nothing and `affordable` is always false -- and a card
	-- of its own, so the shop has to be able to tell all three apart.
	reward: boolean,
}

function Patterns.standing(def: Def, owned: { [string]: boolean }?, money: number, wins: number): Standing
	local price = Patterns.price(def)
	local need = def.wins
	local robux = Patterns.isRobux(def)
	local vip = Patterns.isVip(def)
	local reward = Patterns.isReward(def)
	return {
		owned = def.key == Patterns.DEFAULT_KEY or (owned ~= nil and owned[def.key] == true),
		-- A VIP pattern is NEVER affordable, whatever the balance. Without that
		-- term its tier price of 0 satisfies `money >= price` for everybody and
		-- the shop draws the top of the ladder as free.
		-- ...and NEVER affordable for a reward skin either, for a sharper
		-- version of the VIP reason above: its tier price is 0, so without
		-- this term `money >= price` is true at a balance of nothing and the
		-- shop draws a free skin with a +3% boost on it.
		affordable = need == nil and not robux and not vip and not reward and money >= price,
		winsShort = (need ~= nil and wins < need) and (need - wins) or nil,
		price = price,
		robux = robux,
		vip = vip,
		reward = reward,
	}
end

-- The single gate. Returns false plus a reason a player can read.
function Patterns.mayBuy(def: Def, owned: { [string]: boolean }?, money: number, wins: number): (boolean, string)
	if def.key == Patterns.DEFAULT_KEY then
		return false, "You already have that."
	end
	if owned and owned[def.key] then
		return false, "You already have that."
	end
	if def.wins ~= nil then
		if wins < def.wins then
			return false, `{def.name} is earned, not bought -- {def.wins - wins} more wins.`
		end
		return true, ""
	end
	-- INCLUDED WITH VIP, and not for sale at any price -- the pass is the only
	-- way in. Checked AHEAD of the Robux branch because a VIP def names no
	-- product, so isRobux falls straight through to the Money price below and a
	-- legendary's 128,000 would read as an offer.
	-- GRANTED, NEVER SOLD. Checked ahead of everything below it for the same
	-- reason VIP is, only more urgently: a reward def names no product and
	-- sits in a tier priced at 0, so every branch after this one would let it
	-- through -- the Money check at the bottom reads `0 >= 0` and returns true.
	if Patterns.isReward(def) then
		return false, `{def.name} comes from Free Rewards.`
	end
	if Patterns.isVip(def) then
		return false, `{def.name} comes with VIP.`
	end
	-- Not for Money at any price. The grant path for these is a receipt
	-- (ConquestMonetization), never this function.
	if Patterns.isRobux(def) then
		return false, `{def.name} is bought with Robux.`
	end
	local price = Patterns.price(def)
	if money < price then
		return false, `Not enough Money -- {price - money} short.`
	end
	return true, ""
end

-- ================================================================ swatch ==
--
-- WHAT A PATTERN LOOKS LIKE ON THE GROUND, as one small EditableImage. It
-- lives HERE rather than in the shop that used to own it because a second
-- caller appeared (LobbyUI's free-rewards plate) and the rule at the top of
-- this file applies to previews as hard as it applies to the map: a preview
-- that composites its own way is a preview that LIES, and for a cosmetic this
-- deliberately quiet the preview is the whole of the product.
--
-- ONE PIXEL PER TILE, scaled up whole and drawn Pixelated by the caller, so it
-- is the map at a readable zoom rather than a smoothed impression of it. 40 is
-- deliberately not a multiple of 16: the biggest patterns are cut off mid-motif
-- at the edge, which is what they look like on a real border.
Patterns.SWATCH_TILES = 40

-- The terrain underneath is flat plains at a middling elevation. The real map
-- also carries the renderer's detail noise, but that noise is there to make
-- TERRAIN look like ground; on a hundred-pixel swatch it would only add grain
-- over the thing being judged.
local TERRAIN_MAG = 6

-- Built once per pattern and kept. A shop page builds seventeen of these in its
-- constructor and the lobby sheet asks for one more; none of them ever changes,
-- so a second ask is a table read rather than a second image.
local swatches: { [number]: EditableImage } = {}

function Patterns.swatch(index: number): EditableImage
	local hit = swatches[index]
	if hit then
		return hit
	end
	local n = Patterns.SWATCH_TILES
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(n, n) })
	local px = buffer.create(n * n * 4)

	local tr, tg, tb = Palette.terrainSample(1, TERRAIN_MAG, false)
	-- YOUR colour, which in a free-for-all is the fixed bright one every player
	-- sees themselves in. Asking Palette for it (rather than repeating the
	-- constant) means a retune of the local colour reaches every preview for
	-- free -- `colorFor` returns it for any id that equals the local id.
	local pr, pg, pb = Palette.colorFor(1, 1)
	local sr, sg, sb = Palette.desaturate(pr, pg, pb, Palette.TERRITORY_SATURATION)
	local br = tr + (sr - tr) * Palette.TERRITORY_ALPHA
	local bg = tg + (sg - tg) * Palette.TERRITORY_ALPHA
	local bb = tb + (sb - tb) * Palette.TERRITORY_ALPHA

	-- WHICH ENTRY POINT THIS SWATCH USES is a property of the pattern and not of
	-- the pixel, so it is asked once rather than sixteen hundred times. The
	-- rainbow spends hue and takes the tile; everything else spends lightness and
	-- takes a sampled weight.
	local isRainbow = index == Patterns.RAINBOW_INDEX

	for y = 0, n - 1 do
		for x = 0, n - 1 do
			local r, g, b
			if isRainbow then
				r, g, b = Patterns.rainbow(br, bg, bb, x, y)
			else
				r, g, b = Patterns.apply(br, bg, bb, Patterns.sample(index, x, y))
			end
			local o = (y * n + x) * 4
			buffer.writeu8(px, o, math.clamp(r, 0, 255))
			buffer.writeu8(px, o + 1, math.clamp(g, 0, 255))
			buffer.writeu8(px, o + 2, math.clamp(b, 0, 255))
			buffer.writeu8(px, o + 3, 255)
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(n, n), px)
	swatches[index] = img
	return img
end

return Patterns
