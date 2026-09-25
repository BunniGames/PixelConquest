--!strict
-- Conquest :: Nukes  (shared)
--
-- The whole nuclear layer, ported from upstream
-- (github.com/openfrontio/OpenFrontIO):
--
--   src/core/execution/NukeExecution.ts        (528)  atom / hydrogen / warhead
--   src/core/execution/MIRVExecution.ts        (283)  the carrier and its salvo
--   src/core/execution/MissileSiloExecution.ts (47)   silo reload
--   src/core/execution/SAMLauncherExecution.ts (364)  interception planning
--   src/core/execution/SAMMissileExecution.ts  (98)   the interceptor itself
--   src/core/pathfinding/PathFinder.Parabola.ts       the arc a nuke flies
--   src/core/utilities/Line.ts                        the fixed-point Bezier
--   src/core/pathfinding/PathFinder.Air.ts            the SAM missile's walk
--   src/core/PseudoRandom.ts                          sfc32, for blast shape
--   the nuke / fallout / SAM surface of configuration/Config.ts and GameImpl.ts
--   src/core/execution/nation/NationNukeBehavior.ts   (1104) AI, in part
--   src/core/execution/nation/NationMIRVBehavior.ts   (306)  AI, in part
--
-- IT SITS ON Conquest.Units. Every missile, warhead, silo and launcher is a
-- Units.Unit; this file owns no entity storage and no spatial index. What it
-- adds is the FALLOUT bit, the flight curve, and five tick behaviours.
--
-- ================================================================ FALLOUT ==
--
-- Fallout does not exist in Conquest and it is load-bearing in three places:
--
--   1. Config.falloutDefenseModifier(ratio) = 5 - ratio*2 multiplies BOTH
--      `mag` and `tileCost` in attackLogic (upstream Config.ts:775-779), so a
--      crater costs 5x troops AND 5x tick budget to re-take, falling to 2.5x
--      once half the world is glass. This is the whole reason nuking is not
--      simply "delete territory" -- it denies ground rather than donating it.
--   2. The WIN denominator is numLandTiles() - numTilesWithFallout()
--      (WinCheckExecution.ts:107-108 and :165-166). Without it a nuke moves
--      the goalposts toward whoever is already ahead.
--   3. Conquering a tile CLEARS its fallout (GameImpl.ts:766).
--
-- WHERE THE BIT LIVES, AND WHY NOT IN THE OWNER WORD. Upstream packs it as
-- bit 13 of a Uint16 tile-state word whose low 12 bits are the owner
-- (GameMap.ts:133-136, PLAYER_ID_MASK = 0xfff). Conquest cannot copy that:
--
--   * Conquest's owner byte is SATURATED. Sim.addPlayer refuses id 256, so
--     all eight bits are in use. Upstream has three spare bits only because
--     it caps at 4095 in a sixteen-bit word.
--   * Both wire formats are byte-shaped. Net.packDelta writes the owner with
--     buffer.writeu8 and Net.packOwners is a byte run-length code. Widening
--     the owner to u16 rewrites both, doubles the delta stream, and buys
--     nothing -- the client needs fallout as a paint colour, not as an
--     attribute of the owner.
--   * The owner buffer is the hottest buffer in the game. Sim.processAttack
--     reads it four to twenty times per conquered tile (adjacency, frontier
--     seeding, pocket mop-up) at up to Config.GLOBAL_TILE_BUDGET tiles a
--     tick. Doubling its stride doubles the bytes that loop drags through
--     cache, for a flag that loop consults at most once per tile.
--
-- So fallout is its own BITSET: one bit per tile, buffer.create(N/8), which at
-- the current 880x550 frame is 60,500 bytes. Widening the owner buffer to u16
-- instead would cost 484,000 additional bytes AND both wire formats. One
-- readu8 plus one bit32.btest per query. A dedicated buffer is also what makes
-- the win-denominator change a counter read rather than a scan; upstream needs
-- no scan either, keeping _numTilesWithFallout incrementally
-- (GameMap.ts:107, :297-308), and so does this.
--
-- ============================================== WHAT SAM DETECTION COSTS ==
--
-- Upstream asks the spatial grid for every nuke within maxSamRange() * 4 =
-- 600 tiles of each SAM, every tick (SAMLauncherExecution.ts:216-223). The
-- map is 880x550 and its diagonal is 1038, so a 600-tile radius is more than
-- half the world: cellRange clamps to the ENTIRE Units grid, 28 x 18 = 504
-- cells at CELL 32, times three type buckets = 1,512 table lookups per SAM
-- per tick. It is the whole index, walked, per launcher, forever -- and it
-- does not get cheaper when the sky is empty.
--
-- THIS FILE DOES NOT DO THAT. Units already keeps one live array per type
-- (Units.ofType, backed by sim.unitsByType), so the same answer comes from
-- walking the three nuke arrays and applying the identical d2 <= 600*600
-- test: cost O(nukes in flight), no hashing, no allocation. The result set is
-- identical, because on this map the radius test is the only filter the grid
-- was applying.
--
--   grid form   504 hash lookups + 1,512 indexes per SAM per tick, always
--   array form  3 array walks, about 6 arithmetic ops per nuke per SAM
--
-- The crossover is around 1,500 nukes in flight at once, which cannot happen:
-- a MIRV salvo is capped at 350 and in practice self-limits to a few dozen
-- (see DETONATION COST). With 20 SAMs and 40 warheads up, the array form is
-- 800 distance tests a tick; the grid form would be 10,080 hash lookups a
-- tick for the same 800 answers, and 30,240 with nothing in the air at all.
--
-- The other half of the cost is computeIntercept, which walks a nuke's
-- trajectory looking for the first targetable tile inside range: O(trajectory
-- length), bounded by the increasing-distance break at
-- SAMLauncherExecution.ts:133, and already amortised upstream by a per-nuke
-- cache. That cache is ported. On top of it there is a per-SAM per-tick
-- budget (CFG.SAM_PLAN_BUDGET) on FRESH plans, because a MIRV salvo makes
-- every warhead visible to every SAM on the same tick. Deferred nukes keep
-- their lastSeen stamp, so nothing is evicted; a launcher merely notices some
-- warheads a tick or two later, invisible against flight times of dozens of
-- ticks. Set the budget to math.huge for bit-exact upstream scheduling.
--
-- Worst case with the budget in place: 20 SAMs x 48 plans x a trajectory walk
-- that the increasing-distance break usually ends inside 20 steps is about
-- 19,000 operations in the tick a salvo appears, then nothing until the
-- cached launch ticks come due.
--
-- =================================================== WHAT NUKE FLIGHT COSTS
--
-- Per nuke per tick: one curve step (an index bump), one tile computation,
-- Units.move (which re-buckets only on a cell crossing -- at speed 10 into
-- 32-tile cells, about once every three ticks), and two squared distances for
-- the targetable flag. Roughly twenty operations. Forty warheads in the air
-- is therefore about 800 operations a tick, which is nothing. The cost of a
-- MIRV is all in the blast; see DETONATION COST below.
--
-- The one allocation per missile is its curve, built once at launch: a
-- hydrogen bomb crossing the whole 1038-tile diagonal at speed 10 is ~104
-- points, a warhead at speed 22 is ~25.
--
-- ============================================ WHY THE CLIENT CAN REPLAY IT
--
-- The parabola is a cubic Bezier sampled at exactly `speed` pixels of arc
-- length, computed in 8-bit fixed point by integer De Casteljau subdivision
-- (Line.ts:55-104). Because NukeExecution always builds the curve with
-- increment == speed (NukeExecution.ts:42-48) and then steps it by speed, the
-- curve advances EXACTLY ONE cached point per tick. So
--
--     trajectory index == ticks since launch, after waitTicks
--
-- and a client given (src, dst, speed, startTick, directionUp) reproduces
-- every position bit for bit, with no per-tick replication at all. That is
-- upstream's recordMotionPlan (NukeExecution.ts:298-327) reduced to its
-- essence, and it is why this module is shared rather than server-only.

local Config = require(script.Parent.Config)
-- DIPLOMACY (2026-09-18): the alliance-break rule in detonate. Alliances
-- requires Config and TileMap only.
local Alliances = require(script.Parent.Alliances)
local TileMap = require(script.Parent.TileMap)
local Units = require(script.Parent.Units)
local Economy = require(script.Parent.Economy)

local W = Config.MAP_W
local H = Config.MAP_H
local N = Config.NUM_TILES

local Nukes = {}

-- =================================================================== config ==
--
-- Upstream's numbers with the Config.ts line beside each. They live here
-- rather than in Conquest.Config so this module is self-contained and can be
-- required and tested without touching a file another system owns. The
-- integration hunk that moves them across is a pure copy: nothing below reads
-- a literal twice.

local CFG = {
	-- Config.ts:993-1003.
	--
	-- BALANCE FLAG, NOT A BUG. These are upstream's radii and they were sized
	-- against upstream's maps. Conquest's frame moved to 880x550 on
	-- 2026-08-30 and LAND_PER_EMPIRE with it, so a hydrogen bomb's outer 100
	-- now erases about 31,400 tiles -- roughly eight average empires' worth of
	-- ground in one shot. Ported as-is because the brief is 1:1; if it plays
	-- badly the honest fix is to scale inner/outer by sqrt(area ratio), which
	-- is 0.55, giving atom 7/17 and hydrogen 44/55.
	MAGNITUDE = {
		[Units.ATOM_BOMB] = { inner = 12, outer = 30 },
		[Units.HYDROGEN_BOMB] = { inner = 80, outer = 100 },
		[Units.MIRV_WARHEAD] = { inner = 12, outer = 18 },

		-- NOT UPSTREAM. The owner's mega nuke, 2026-09-17: "2 times the blast
		-- radius a regular nuke does". BOTH radii are doubled off the atom
		-- bomb, which is what keeps it the same WEAPON rather than a new one --
		-- the inner:outer ratio is the shape of the crater (everything inside
		-- inner falls, the rim between the two is a coin flip per tile), so
		-- doubling only `outer` would have made a bigger bomb with a softer
		-- edge instead of a bigger version of the same bomb.
		--
		-- WHAT IT ACTUALLY ERASES, because a radius is not a size: the blast is
		-- a disc, so twice the radius is FOUR times the ground -- about 11,300
		-- tiles against the atom bomb's 2,800, roughly 2.3% of the 880x550
		-- frame or three average empires. That is also four times the conquers
		-- in the landing tick (see DETONATION COST above) and it lands in one
		-- tick like any other bomb: 11,300 is well under the hydrogen bomb's
		-- 31,400, which is the case that part of the header was written for, so
		-- nothing new is being asked of the tile budget or of the wire.
		[Units.MEGA_NUKE] = { inner = 24, outer = 60 },
		-- NOT UPSTREAM (2026-09-24). The scattershot's MAIN warhead is the atom
		-- bomb's crater exactly; what makes it a different weapon is the 4-6
		-- MIRV warheads that fly with it (Nukes.launchScattershot).
		[Units.SCATTERSHOT] = { inner = 12, outer = 30 },
	},

	-- Config.ts:1009-1020. Tiles of arc length per tick, and also the spacing
	-- the flight curve is sampled at -- the two are one number by construction
	-- (NukeExecution.ts:42-48).
	-- HALVED FROM UPSTREAM, owner's call 2026-09-02 ("make the nuke travel
	-- slower"). Upstream is 10 / 10 / 15 / 22 and every other number in this
	-- file is still a 1:1 port; this is the one that is not, so it is written
	-- down here rather than left to be rediscovered as a porting error.
	--
	-- WHY. A warhead crossing this map at ten tiles a tick is in the air for
	-- something like fifteen seconds, and the whole of that is spent on a
	-- streak the eye catches after it has already passed. The siren and the
	-- crater were the strike; the flight was not. At five it is a thing you
	-- can watch coming, which is the only window anybody has to react in.
	--
	-- WHAT ELSE IT MOVES, and it is not a side effect worth undoing: a slower
	-- warhead sits in a SAM's targetable window for twice as long, so
	-- interception gets meaningfully better without a single line of SAM code
	-- changing. The RATIOS are kept exactly -- a MIRV bus still outruns a
	-- plain bomb and its warheads still outrun the bus -- so nothing that
	-- reads relative speeds (the staging offsets, the arrival estimates)
	-- changes its mind.
	--
	-- These are also the spacing the flight curve is SAMPLED at, so halving
	-- them doubles the number of points in every trajectory. That is the cost:
	-- twice the path array per missile and twice the walk in
	-- trajectoryInterceptable. Both are tens of entries on a map this size.
	SPEED = {
		[Units.ATOM_BOMB] = 5,
		[Units.HYDROGEN_BOMB] = 5,
		[Units.MIRV] = 8,
		[Units.MIRV_WARHEAD] = 11,
		-- The atom bomb's speed exactly, and deliberately: a mega nuke is a
		-- bigger warhead and not a faster one, and the five that the owner
		-- asked for above is what makes a strike something you can watch
		-- coming. It is also what keeps the anti-nuke tower's odds against it
		-- the same as against an atom bomb -- time in the targetable window is
		-- the whole of a launcher's chance.
		[Units.MEGA_NUKE] = 5,
		-- The atom bomb's five, and its warheads are launched at the same five
		-- so the salvo crosses the map as one spread rather than a column.
		[Units.SCATTERSHOT] = 5,
	},

	-- Config.ts:1022-1024. Upstream makes a nuke shootable only while within
	-- this of either END of its flight, leaving the mid-course untargetable --
	-- which is precisely what lets a long shot sail over a SAM belt untouched.
	-- KEPT AT UPSTREAM'S NUMBER because it is what the flag below switches off,
	-- and because restoring upstream behaviour should be one word, not a
	-- reconstruction.
	TARGETABLE_RANGE = 150,
	-- ...AND CONQUEST DOES NOT DO THAT (owner, 2026-09-14: "shoots at any nukes
	-- that need to fly over the zone in the air. KEYWORD. FLY OVER. this
	-- includes nukes that need to hit the area").
	--
	-- With this true a warhead is targetable at EVERY point of its arc, so the
	-- only question a launcher asks is the one a player can see the answer to:
	-- does this thing cross my ring. The blind spot above is not a rule anybody
	-- could read off the map -- a tower would sit there watching a bomb pass
	-- directly overhead because the bomb was halfway through its flight -- and
	-- an anti-nuke tower whose behaviour you cannot predict from its drawn
	-- radius is worse than none.
	--
	-- WHAT IT COSTS, honestly: long-range nuclear war gets much harder against a
	-- defended map, because a SAM belt can no longer be overflown -- only
	-- out-ranged, out-numbered or out-waited (a launcher reloads on
	-- SAM_COOLDOWN and engages one warhead at a time). Both sides of the change
	-- read this one flag: nukeTargetable for the per-tile flags a launcher
	-- plans against, and Nukes.trajectoryInterceptable for the AI's own
	-- "will this shot survive" check, which must not keep believing in a gap
	-- the launchers no longer have.
	INTERCEPT_ANYWHERE = true,

	-- Config.ts:1030-1037. samRange(level) = MAX - K/(level+5): 70 at level 1,
	-- asymptotically 150.
	MAX_SAM_RANGE = 150,
	SAM_RANGE_K = 480,

	-- Config.ts:1058-1060.
	SAM_MISSILE_SPEED = 12,

	-- Config.ts:307-312. Ticks, so nine seconds at Config.TICK_RATE.
	-- Off Config since 2026-09-15, so Units can read the same number without
	-- requiring this module (which requires Units -- see Config.SAM_COOLDOWN).
	SAM_COOLDOWN = Config.SAM_COOLDOWN or 90,
	SILO_COOLDOWN = 90,

	-- Config.ts:1005-1007. Inert until Conquest has alliances; kept so the
	-- hook has its threshold when they land.
	ALLIANCE_BREAK_THRESHOLD = 100,

	-- MIRVExecution.ts:25-28. MIRV_RANGE 1500 exceeds this map's 1038-tile
	-- diagonal, so the range test never binds and the salvo is bounded purely
	-- by the target's own territory and MIRV_MIN_SPREAD. MIRV_WARHEADS is
	-- likewise a ceiling that is never reached here; see DETONATION COST.
	MIRV_RANGE = 1500,
	MIRV_MIN_SPREAD = 55,
	MIRV_WARHEADS = 350,
	-- MIRVExecution.ts:95 -- the carrier climbs to 500 above the target's
	-- latitude, clamped at the top of the map, before it splits.
	MIRV_SEPARATION_RISE = 500,

	-- Fresh interception plans one SAM may compute in a tick. Not upstream;
	-- see WHAT SAM DETECTION COSTS. math.huge restores upstream exactly.
	SAM_PLAN_BUDGET = 48,

	-- Line.ts:12 PARABOLA_MIN_HEIGHT.
	PARABOLA_MIN_HEIGHT = 50,
}

CFG.SAM_UPGRADE_DURATION = CFG.SAM_COOLDOWN // 2 -- Config.ts:1039-1041
Nukes.CFG = CFG

function Nukes.magnitude(utype: number): any
	return CFG.MAGNITUDE[utype]
end

function Nukes.speed(utype: number): number
	return CFG.SPEED[utype] or 5
end

-- Config.ts:1030-1033.
function Nukes.samRange(level: number): number
	return CFG.MAX_SAM_RANGE - CFG.SAM_RANGE_K / (level + 5)
end

-- Config.ts:299-303. falloutRatio is in [0,1], so the modifier is in [5,2.5]
-- and multiplies BOTH the troop cost and the tick cost of a tile.
function Nukes.falloutDefenseModifier(ratio: number): number
	return 5 - ratio * 2
end

-- Config.ts:1063-1079. Humans lost per impacted tile. The plain nukes kill a
-- flat share of the army per tile; a MIRV warhead kills on a saturating curve
-- against the ceiling instead, which is what stops 350 warheads deleting an
-- empire's population outright.
function Nukes.deathFactor(utype: number, humans: number, tilesOwned: number, maxTroops: number): number
	if utype ~= Units.MIRV_WARHEAD then
		return (5 * humans) / math.max(1, tilesOwned)
	end
	local targetTroops = 0.03 * maxTroops
	local excess = math.max(0, humans - targetTroops)
	local normalized = excess / math.max(1, maxTroops)
	return 500 * (1 - math.exp(-2 * normalized))
end

-- Sim owns maxTroops and Sim requires this file, so it cannot be required
-- back. The integration hunk assigns Sim's own function here; the fallback is
-- the same formula (Sim:795-816) and exists only so this module is correct
-- standing alone.
Nukes.maxTroopsFn = nil :: ((any) -> number)?

local function maxTroopsOf(p: any): number
	local fn = Nukes.maxTroopsFn
	if fn ~= nil then
		return fn(p)
	end
	local m = Config.MAX_TROOPS_MULT
		* ((p.tileCount ^ Config.TROOPS_TILE_EXPONENT) * Config.TROOPS_PER_TILE_COEF + Config.BASE_MAX_TROOPS)
	m += (p.cityLevels or 0) * (Config.CITY_TROOP_INCREASE or 0)
	-- ...and a special mode's flat ceiling, outside the scale, as Sim's has it.
	return m * Config.TIER[p.tier or Config.TIER_HUMAN].MAX_TROOPS_SCALE + (p.capBonus or 0)
end

-- ============================================================== PseudoRandom ==
--
-- src/core/PseudoRandom.ts: splitmix32 seeding into sfc32, twelve warm-up
-- draws. Ported exactly rather than using Random.new, because the blast SHAPE
-- is a function of the draw sequence and the client regenerates blasts from a
-- seed instead of being sent a third of a million tile deltas. Two machines
-- have to agree bit for bit.

local Rand = {}
Rand.__index = Rand

local TWO32 = 4294967296

local function imul(a: number, b: number): number
	local al = bit32.band(a, 0xffff)
	local ah = bit32.rshift(a, 16)
	local bl = bit32.band(b, 0xffff)
	local bh = bit32.rshift(b, 16)
	local lo = al * bl
	local mid = bit32.band(ah * bl + al * bh, 0xffff)
	return (lo + mid * 65536) % TWO32
end

function Rand.new(seed: number): any
	local self = setmetatable({ s0 = 0, s1 = 0, s2 = 0, s3 = 0 }, Rand)
	local h = math.floor(seed) % TWO32
	local function split(): number
		h = (h + 0x9e3779b9) % TWO32
		local t = bit32.bxor(h, bit32.rshift(h, 16))
		t = imul(t, 0x21f0aaad)
		t = bit32.bxor(t, bit32.rshift(t, 15))
		t = imul(t, 0x735a2d97)
		return bit32.bxor(t, bit32.rshift(t, 15))
	end
	self.s0 = split()
	self.s1 = split()
	self.s2 = split()
	self.s3 = split()
	for _ = 1, 12 do
		Rand.next(self)
	end
	return self
end

function Rand.next(self: any): number
	local t = (self.s0 + self.s1 + self.s3) % TWO32
	self.s3 = (self.s3 + 1) % TWO32
	self.s0 = bit32.bxor(self.s1, bit32.rshift(self.s1, 9))
	self.s1 = (self.s2 + bit32.lshift(self.s2, 3)) % TWO32
	self.s2 = bit32.lrotate(self.s2, 21)
	self.s2 = (self.s2 + t) % TWO32
	return t / TWO32
end

-- min inclusive, max EXCLUSIVE (PseudoRandom.ts:45-50). Luau's NextInteger is
-- inclusive at both ends; every ported nextInt has to lose one from the top.
function Rand.nextInt(self: any, lo: number, hi: number): number
	local a = math.floor(lo)
	local b = math.floor(hi)
	return math.floor(Rand.next(self) * (b - a)) + a
end

function Rand.nextFloat(self: any, lo: number, hi: number): number
	return Rand.next(self) * (hi - lo) + lo
end

-- True with probability 1/odds (PseudoRandom.ts:92-94).
function Rand.chance(self: any, odds: number): boolean
	return Rand.nextInt(self, 0, odds) == 0
end

Nukes.Rand = Rand

-- ================================================================= geometry ==

local function tx(tile: number): number
	return tile % W
end

local function ty(tile: number): number
	return (tile - tile % W) / W
end

local function dist2(a: number, b: number): number
	local ax = a % W
	local bx = b % W
	local dx = ax - bx
	local dy = (a - ax) / W - (b - bx) / W
	return dx * dx + dy * dy
end

local function manhattan(a: number, b: number): number
	local ax = a % W
	local bx = b % W
	return math.abs(ax - bx) + math.abs((a - ax) / W - (b - bx) / W)
end

Nukes.dist2 = dist2

-- ======================================================= who a bot may nuke ==
--
-- OWNER RULE, 2026-09-17: AN AI EMPIRE NEVER NUKES A PERSON. Only the AI half
-- of this module asks the question -- aiThink, considerMirv, the aimpoint
-- scorer and the MIRV warhead picker. A human orders their own shots through
-- ConquestServer's nuke intent and none of this restrains them.
--
-- `isBot` IS THE WHOLE TEST, and it is the right one at all three of its
-- edges:
--   * a connected person is isBot == false, and is untouchable;
--   * A FAUX EMPIRE IS STILL A LEGAL TARGET. The empires wearing a real
--     player's name and face keep isBot == true precisely so that Sim's AI
--     loop drives them (ConquestServer's faux block), so a match that reads
--     as a game with people in it still reads that way when warheads fly;
--   * a person who LEFT mid-round is isBot == true from that tick
--     (ConquestServer's PlayerRemoving) and their land is AI-run, so it is as
--     nukeable as the bot it has become.
local function nukeable(sim: any, p: any, other: any): boolean
	if other == nil or not other.alive or other.id == p.id then
		return false
	end
	if not other.isBot then
		return false
	end
	return not (sim.sameTeam ~= nil and sim:sameTeam(p.id, other.id))
end

-- THE BLAST IS THE WEAPON, NOT THE AIMPOINT, so the rule above is not enough
-- on its own. detonate's first pass hands EVERY tile the fireball covers back
-- to nobody and its third deletes every structure inside the outer radius,
-- whoever owns them -- and a hydrogen bomb's outer is 100 tiles. An aimpoint
-- on a bot's border with a person's cities twenty tiles behind it is a strike
-- on the person.
--
-- So an AI aimpoint is refused when a person's ground lies inside the blast.
-- TWO STAGES, because the exact answer is a disc of owner reads and the answer
-- is almost always no: the BOUNDING BOX of each person's territory, grown by
-- the blast radius, clears nearly every candidate in four comparisons, and
-- only one the box cannot clear pays for the disc (measured: 0.39 ms for a
-- hydrogen disc, 0.06 microseconds for a box reject). The disc is a superset
-- of blastTiles' ragged edge, so the test errs by refusing a shot that would
-- have missed, never by allowing one that lands.
local PERSON_SCAN_BUDGET = 8

local function personInfo(sim: any): any
	-- Rebuilt once a TICK and shared by every bot thinking on it: the box is an
	-- O(border) walk per person, and one tick can hold several nations with
	-- silos, each pricing dozens of candidates.
	local cached = sim.nukePersons
	if cached ~= nil and cached.tick == sim.tick then
		return cached.info
	end
	local boxes = {}
	local ids: { [number]: boolean } = {}
	for _, id in sim.playerOrder do
		local q = sim.players[id]
		if q ~= nil and q.alive and not q.isBot and q.tileCount > 0 then
			local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
			for tile in q.border do
				local x = tile % W
				local y = (tile - x) / W
				if x < minX then
					minX = x
				end
				if x > maxX then
					maxX = x
				end
				if y < minY then
					minY = y
				end
				if y > maxY then
					maxY = y
				end
			end
			if minX <= maxX then
				boxes[#boxes + 1] = { minX = minX, maxX = maxX, minY = minY, maxY = maxY }
				ids[q.id] = true
			end
		end
	end
	local info: any = if #boxes == 0 then false else { boxes = boxes, ids = ids }
	sim.nukePersons = { tick = sim.tick, info = info }
	return info
end

-- Would a warhead of this magnitude, landing here, touch anybody's ground?
local function blastTouchesPerson(sim: any, tile: number, outer: number): boolean
	local info = personInfo(sim)
	if info == false then
		return false
	end
	local x = tile % W
	local y = (tile - x) / W
	local near = false
	for _, box in info.boxes do
		if
			x >= box.minX - outer
			and x <= box.maxX + outer
			and y >= box.minY - outer
			and y <= box.maxY + outer
		then
			near = true
			break
		end
	end
	if not near then
		return false
	end

	local owner = sim.map.owner
	local ids = info.ids
	local r2 = outer * outer
	local y0 = math.max(0, y - outer)
	local y1 = math.min(H - 1, y + outer)
	local x0 = math.max(0, x - outer)
	local x1 = math.min(W - 1, x + outer)
	for yy = y0, y1 do
		local dy = yy - y
		local dy2 = dy * dy
		local row = yy * W
		for xx = x0, x1 do
			local dx = xx - x
			if dx * dx + dy2 <= r2 and ids[buffer.readu8(owner, row + xx)] then
				return true
			end
		end
	end
	return false
end

-- Upstream isImpassable = land whose magnitude is the impassable sentinel.
-- WATER IS NOT IMPASSABLE and is deliberately inside the blast set: a nuke
-- clears boats and its shockwave crosses a strait. Only LAND takes fallout.
local function notImpassable(map: any, tile: number): boolean
	local b = buffer.readu8(map.terrain, tile)
	if not bit32.btest(b, 128) then
		return true
	end
	return bit32.band(b, 63) < 63
end

-- ========================================================= the flight curve ==
--
-- src/core/utilities/Line.ts, DistanceBasedBezierCurve. Single-pass in-order
-- De Casteljau subdivision in 8-bit fixed point, emitting a point every
-- `pixelSpacing` units of accumulated integer arc length. Deterministic to
-- the bit on any machine, which is the whole point.
--
-- Points are two flat number arrays, not a table per point. A hydrogen bomb
-- crossing the map is about 190 points; a MIRV salvo is 350 curves at once,
-- and 350 * 68 point tables would be 24,000 allocations in one tick.

local Curve = {}
Curve.__index = Curve

local function subdivide(
	c: any,
	ax: number,
	ay: number,
	bx: number,
	by: number,
	cx: number,
	cy: number,
	dx: number,
	dy: number,
	depth: number,
	stepThreshold: number,
	st: any
)
	local d = math.abs(bx - ax)
		+ math.abs(by - ay)
		+ math.abs(cx - bx)
		+ math.abs(cy - by)
		+ math.abs(dx - cx)
		+ math.abs(dy - cy)
	if d <= 256 or depth >= 10 then
		local edx = ax - st.lastX
		local edy = ay - st.lastY
		st.accum += math.floor(math.sqrt(edx * edx + edy * edy))
		st.lastX = ax
		st.lastY = ay
		while st.accum >= stepThreshold do
			local n = #c.px + 1
			c.px[n] = (ax + 128) // 256
			c.py[n] = (ay + 128) // 256
			st.accum -= stepThreshold
		end
		return
	end

	local m01x = (ax + bx) // 2
	local m01y = (ay + by) // 2
	local m12x = (bx + cx) // 2
	local m12y = (by + cy) // 2
	local m23x = (cx + dx) // 2
	local m23y = (cy + dy) // 2

	local m012x = (m01x + m12x) // 2
	local m012y = (m01y + m12y) // 2
	local m123x = (m12x + m23x) // 2
	local m123y = (m12y + m23y) // 2

	local mx = (m012x + m123x) // 2
	local my = (m012y + m123y) // 2

	subdivide(c, ax, ay, m01x, m01y, m012x, m012y, mx, my, depth + 1, stepThreshold, st)
	subdivide(c, mx, my, m123x, m123y, m23x, m23y, dx, dy, depth + 1, stepThreshold, st)
end

local function newCurve(
	p0x: number,
	p0y: number,
	p1x: number,
	p1y: number,
	p2x: number,
	p2y: number,
	p3x: number,
	p3y: number,
	increment: number
): any
	local c = setmetatable({
		px = {} :: { number },
		py = {} :: { number },
		spacing = math.max(1, math.round(increment)),
		idx = 0, -- 0-based, as upstream's currentIndex
		accum = 0,
	}, Curve)

	local S = 256
	local a0x = math.round(p0x) * S
	local a0y = math.round(p0y) * S
	local a3x = math.round(p3x) * S
	local a3y = math.round(p3y) * S

	c.px[1] = (a0x + 128) // 256
	c.py[1] = (a0y + 128) // 256

	local st = { lastX = a0x, lastY = a0y, accum = 0 }
	subdivide(
		c,
		a0x,
		a0y,
		math.round(p1x) * S,
		math.round(p1y) * S,
		math.round(p2x) * S,
		math.round(p2y) * S,
		a3x,
		a3y,
		0,
		c.spacing * S,
		st
	)

	local lx = (a3x + 128) // 256
	local ly = (a3y + 128) // 256
	local last = #c.px
	if c.px[last] ~= lx or c.py[last] ~= ly then
		c.px[last + 1] = lx
		c.py[last + 1] = ly
	end
	return c
end

-- Line.ts:30-45. Returns false at the end of the curve, which is what the
-- caller reads as PathStatus.COMPLETE.
function Curve.step(self: any, distance: number): boolean
	self.accum += math.max(1, math.round(distance))
	local n = #self.px
	while self.idx < n - 1 and self.accum >= self.spacing do
		self.idx += 1
		self.accum -= self.spacing
	end
	return self.idx < n - 1
end

function Curve.tileAt(self: any, i: number): number
	return self.py[i + 1] * W + self.px[i + 1]
end

-- PathFinder.Parabola.ts:23-49. Control points a quarter and three quarters
-- along, lifted by max(distance/3, 50) and clamped to the map. x needs no
-- clamp: both control x values lie between the endpoints, so the whole convex
-- hull of the curve does too.
function Nukes.arc(src: number, dst: number, increment: number, directionUp: boolean?, flatHeight: boolean?): any
	local p0x, p0y = tx(src), ty(src)
	local p3x, p3y = tx(dst), ty(dst)
	local dx = p3x - p0x
	local dy = p3y - p0y
	local maxHeight = 0
	if flatHeight ~= true then
		maxHeight = math.max(math.sqrt(dx * dx + dy * dy) / 3, CFG.PARABOLA_MIN_HEIGHT)
	end
	local mult = (directionUp == false) and 1 or -1
	local p1y = math.clamp(p0y + dy / 4 + mult * maxHeight, 0, H - 1)
	local p2y = math.clamp(p0y + (dy * 3) / 4 + mult * maxHeight, 0, H - 1)
	return newCurve(p0x, p0y, p0x + dx / 4, p1y, p0x + (dx * 3) / 4, p2y, p3x, p3y, increment)
end

-- The sampled curve as a tile list. Index i is the missile's position i ticks
-- after launch, because sampling spacing and step size are the same number.
local function curveTiles(c: any, out: { number }?): { number }
	local res = out or {}
	local n = #c.px
	for i = 1, n do
		res[i] = c.py[i] * W + c.px[i]
	end
	for i = n + 1, #res do
		res[i] = nil
	end
	return res
end

function Nukes.arcTiles(src: number, dst: number, increment: number, directionUp: boolean?, out: { number }?): { number }
	return curveTiles(Nukes.arc(src, dst, increment, directionUp), out)
end

-- ================================================================== fallout ==

local function falloutInit(sim: any)
	if sim.fallout == nil then
		sim.fallout = buffer.create((N + 7) // 8)
		sim.falloutCount = 0
	end
end

function Nukes.hasFallout(sim: any, tile: number): boolean
	local f = sim.fallout
	if f == nil then
		return false
	end
	return bit32.btest(buffer.readu8(f, tile // 8), bit32.lshift(1, tile % 8))
end

-- GameImpl.ts:264-272 plus GameMap.ts:297-308. Setting keeps the counter in
-- step; clearing is what Sim.conquer must call so retaken ground stops being
-- a crater (GameImpl.ts:766).
function Nukes.setFallout(sim: any, tile: number, value: boolean)
	local f = sim.fallout
	if f == nil then
		return
	end
	local byteIdx = tile // 8
	local mask = bit32.lshift(1, tile % 8)
	local b = buffer.readu8(f, byteIdx)
	local had = bit32.btest(b, mask)
	if value then
		if not had then
			buffer.writeu8(f, byteIdx, bit32.bor(b, mask))
			sim.falloutCount += 1
		end
	elseif had then
		buffer.writeu8(f, byteIdx, bit32.band(b, bit32.bnot(mask)))
		sim.falloutCount -= 1
	end
end

-- AttackExecution.ts:361-363.
function Nukes.falloutRatio(sim: any): number
	local land = sim.playableLand or 1
	if land <= 0 then
		return 0
	end
	return math.clamp((sim.falloutCount or 0) / land, 0, 1)
end

-- The one call Sim.attackLogic needs: the multiplier for this tile, or 1 when
-- the tile is clean. One buffer read on the clean path.
function Nukes.tileDefenseMultiplier(sim: any, tile: number): number
	if not Nukes.hasFallout(sim, tile) then
		return 1
	end
	return Nukes.falloutDefenseModifier(Nukes.falloutRatio(sim))
end

-- The win-condition denominator: upstream numLandTiles() - numTilesWithFallout()
-- (WinCheckExecution.ts:107-108, :165-166).
function Nukes.contestableLand(sim: any): number
	return math.max(1, (sim.playableLand or 1) - (sim.falloutCount or 0))
end

-- ==================================================================== state ==

function Nukes.init(sim: any)
	-- Idempotent, and safe either side of Sim wiring Units in.
	if sim.units == nil then
		Units.init(sim)
	end
	falloutInit(sim)
	sim.nukeExecs = sim.nukeExecs or {} :: { any }
	sim.nukeEvents = sim.nukeEvents or {} :: { any }
	sim.mirvsLaunched = sim.mirvsLaunched or 0
	sim.nukeSeq = sim.nukeSeq or 0
end

local function emit(sim: any, ev: any)
	local list = sim.nukeEvents
	list[#list + 1] = ev
end

-- PUBLIC, for the artillery (2026-09-21). A battery's shell rides the same
-- "missiles" channel as a warhead -- one launch event, one impact event,
-- replayed against the same tick clock -- and this is the one door onto that
-- queue. Nothing else about the queue changes: ConquestServer drains it and
-- Missiles.onEvents dispatches on `e` exactly as before.
-- A PUBLIC DOOR ONTO THE SAME QUEUE (2026-09-21), for the airstrike layer: a
-- bomber's take-off ("pl") and its bombs landing ("pb") ride the "missiles"
-- channel a warhead's launch and blast do, so ConquestServer sends nothing new
-- and Missiles.onEvents hears both from one stream. Airstrikes is the only
-- caller; everything in this file still uses the local above.
function Nukes.emit(sim: any, ev: any)
	emit(sim, ev)
end

-- Everything the client needs to draw a missile for its whole life, sent once
-- at launch. There is no per-tick missile traffic at all: see WHY THE CLIENT
-- CAN REPLAY IT in the header.
function Nukes.drainEvents(sim: any): { any }?
	local list = sim.nukeEvents
	if list == nil or #list == 0 then
		return nil
	end
	sim.nukeEvents = {}
	return list
end

-- Absolute state for a joining client: every missile currently in the air.
function Nukes.snapshot(sim: any): { any }
	local out = {}
	if sim.nukeExecs == nil then
		return out
	end
	for _, ex in sim.nukeExecs do
		if ex.active and ex.launchEvent ~= nil then
			out[#out + 1] = ex.launchEvent
		end
	end
	return out
end

local function addExec(sim: any, ex: any): any
	ex.initTick = sim.tick
	local list = sim.nukeExecs
	list[#list + 1] = ex
	return ex
end

local function siloAt(sim: any, playerId: number, tile: number): any
	for _, s in Units.ofType(sim, Units.MISSILE_SILO) do
		if s.active and s.ownerId == playerId and s.tile == tile then
			return s
		end
	end
	return nil
end

-- =================================================================== spawn ==
--
-- PlayerImpl.nukeSpawn (PlayerImpl.ts:1518-1566): the nearest silo by
-- MANHATTAN distance that is active, off cooldown and finished building. The
-- AI's salvo planner mirrors this ordering exactly, so it must not change.

-- The launch site for a SILO-FREE shot (Config.NUKE_REQUIRES_SILO false): the
-- tile you own that is closest to the target, so the arc still starts on real
-- ground of yours and every SAM between the two still gets its chance.
--
-- A full sweep of the owner buffer, deliberately. There is no per-player tile
-- index in this game, and the obvious alternative -- walking rings outward
-- from the target until one of your tiles turns up -- is O(r^2) in the
-- distance, i.e. it degrades exactly in the case that matters, a shot fired
-- across the map. The row skip below prunes most of it: once a candidate is
-- found, a row whose y-offset alone already exceeds the best distance cannot
-- contain a better tile.
--
-- Memoised for a few ticks because every launch asks TWICE -- once when the
-- order is validated in launchNuke, and again on the execution's first tick,
-- which is the following tick.
local function nearestOwnedTile(sim: any, playerId: number, dst: number): (number | false, string?)
	local memo = sim.nukeSrcMemo
	if memo ~= nil and memo.player == playerId and memo.dst == dst and sim.tick - memo.tick <= 4 then
		return memo.tile
	end
	-- Own the target already? Then it IS the nearest owned tile. Only
	-- reachable once the game has ended, since nukeSpawn refuses a friendly
	-- target before this.
	if buffer.readu8(sim.map.owner, dst) == playerId then
		return dst
	end
	local owner = sim.map.owner
	local tx = dst % W
	local ty = (dst - tx) / W
	local best, bestD = -1, math.huge

	-- SCAN THE BORDER, NOT THE MAP, and that is exact rather than an
	-- approximation: if the closest owned tile T to a target OUTSIDE the
	-- territory had all four neighbours owned, the neighbour of T facing the
	-- target would be owned and strictly closer -- a contradiction. So the
	-- nearest owned tile to an external target is always a border tile.
	-- nukeSpawn rejects any target the player owns as "friendly" except once
	-- the game has ended, and the dst check above covers that case.
	--
	-- The full sweep this replaces cost 26 ms a call, and the AI asked for it
	-- ~45 times in a single tick (see the gate in aiThink): 1,175 ms, the
	-- worst tick in a 30-minute match. A late-game border is a few hundred
	-- tiles against 484,000.
	local pl = sim.players ~= nil and sim.players[playerId] or nil
	local border = pl ~= nil and pl.border or nil
	if border ~= nil then
		for tile in border do
			-- Verified against the owner buffer rather than trusted: a stale
			-- entry in the border set would otherwise aim a launch from a
			-- tile this player no longer holds.
			if buffer.readu8(owner, tile) == playerId then
				local x = tile % W
				local ddx = x - tx
				local ddy = (tile - x) / W - ty
				local d = ddx * ddx + ddy * ddy
				if d < bestD then
					bestD = d
					best = tile
				end
			end
		end
	end

	-- Fallback for the cases the border set cannot answer: no border at all
	-- (an empire holding every tile in its component) or a set that has gone
	-- empty. Same full sweep as before, with the row skip.
	if best < 0 then
		for y = 0, H - 1 do
			local ddy = y - ty
			local dy2 = ddy * ddy
			if dy2 < bestD then
				local base = y * W
				for x = 0, W - 1 do
					if buffer.readu8(owner, base + x) == playerId then
						local ddx = x - tx
						local d = ddx * ddx + dy2
						if d < bestD then
							bestD = d
							best = base + x
						end
					end
				end
			end
		end
	end
	if best < 0 then
		return false, "noland"
	end
	sim.nukeSrcMemo = { player = playerId, dst = dst, tick = sim.tick, tile = best }
	return best
end

-- Can this player fire at all right now? Exactly the condition nukeSpawn's
-- own silo loop applies, factored out because aiThink has to gate on the SAME
-- thing -- gating on anything weaker drops the AI into the silo-free branch.
local function hasReadySilo(sim: any, playerId: number): boolean
	for _, s in Units.ofType(sim, Units.MISSILE_SILO) do
		if s.active and s.ownerId == playerId and not s.underConstruction and not Units.inCooldown(s) then
			return true
		end
	end
	return false
end

function Nukes.nukeSpawn(sim: any, playerId: number, utype: number, dst: number): (number | false, string?)
	local map = sim.map
	if dst < 0 or dst >= N then
		return false, "offmap"
	end
	if not notImpassable(map, dst) then
		return false, "terrain"
	end
	local ownerId = buffer.readu8(map.owner, dst)
	local gameOver = sim.phase == "ended"
	if ownerId ~= 0 and not gameOver and sim.sameTeam ~= nil and sim:sameTeam(playerId, ownerId) then
		return false, "friendly"
	end
	-- A MIRV needs an owned target (PlayerImpl.ts:1485-1489).
	if utype == Units.MIRV and ownerId == 0 then
		return false, "unowned"
	end

	-- Team games refuse a shot whose blast would take a teammate's structure
	-- (PlayerImpl.ts:1537-1555). Units.anyNearby is the early-exit form.
	if sim.teamCount ~= nil and sim.teamCount > 0 and utype ~= Units.MIRV and not gameOver then
		local mag = CFG.MAGNITUDE[utype]
		if mag ~= nil then
			local hit = Units.anyNearby(sim, dst, mag.outer, Units.STRUCTURE_TYPES, function(u)
				return u.ownerId ~= 0 and u.ownerId ~= playerId and sim:sameTeam(playerId, u.ownerId)
			end, nil, true)
			if hit then
				return false, "teammate"
			end
		end
	end

	local best: any = nil
	local bestD = math.huge
	for _, s in Units.ofType(sim, Units.MISSILE_SILO) do
		if s.active and s.ownerId == playerId and not s.underConstruction and not Units.inCooldown(s) then
			local d = manhattan(s.tile, dst)
			if d < bestD then
				bestD = d
				best = s
			end
		end
	end
	if best == nil then
		if Config.NUKE_REQUIRES_SILO ~= false then
			return false, "nosilo"
		end
		-- Owner's call: a human cannot buy a silo in this game, so without
		-- this branch the launch button on the action rail is a dead control.
		-- The AI never reaches it -- aiThink gates on owning a silo before it
		-- ever orders a shot -- so this is the human path and nothing else.
		return nearestOwnedTile(sim, playerId, dst)
	end
	return best.tile
end

-- =========================================================== blast geometry ==
--
-- NukeExecution.tilesToDestroy (NukeExecution.ts:55-127), non-waterNukes
-- branch. A depth-first flood from the impact tile: inside the inner radius
-- everything falls, between inner and outer each tile is a coin flip, and the
-- flood cannot cross impassable terrain -- so a crater is one connected shape
-- with a ragged rim rather than a stencilled disc.
--
-- The traversal order is upstream's exactly (stack, pop from the end, visit
-- north, south, west, east) because the coin flips are drawn IN VISIT ORDER:
-- a different order is a different crater from the same seed, and the client
-- regenerates the crater rather than being sent it.
--
-- waterNukes (Config.ts:355-357, default false) is NOT ported. See the report.

function Nukes.blastTiles(
	sim: any,
	dst: number,
	inner: number,
	outer: number,
	seed: number,
	out: { number }?
): ({ number }, number)
	local map = sim.map
	local rand = Rand.new(seed)
	local inner2 = inner * inner
	local outer2 = outer * outer
	local res = out or {}
	local count = 0
	local seen: { [number]: boolean } = {}
	local stack: { number } = {}
	local top = 0

	local function accept(t: number): boolean
		local d2 = dist2(dst, t)
		if d2 > outer2 then
			return false
		end
		if d2 > inner2 and not Rand.chance(rand, 2) then
			return false
		end
		return notImpassable(map, t)
	end

	if accept(dst) then
		seen[dst] = true
		top += 1
		stack[top] = dst
		count += 1
		res[count] = dst
	end

	local southLimit = (H - 1) * W
	while top > 0 do
		local curr = stack[top]
		stack[top] = nil
		top -= 1
		local x = curr % W

		local n1 = curr - W
		if curr >= W and not seen[n1] and accept(n1) then
			seen[n1] = true
			top += 1
			stack[top] = n1
			count += 1
			res[count] = n1
		end
		local n2 = curr + W
		if curr < southLimit and not seen[n2] and accept(n2) then
			seen[n2] = true
			top += 1
			stack[top] = n2
			count += 1
			res[count] = n2
		end
		local n3 = curr - 1
		if x ~= 0 and not seen[n3] and accept(n3) then
			seen[n3] = true
			top += 1
			stack[top] = n3
			count += 1
			res[count] = n3
		end
		local n4 = curr + 1
		if x ~= W - 1 and not seen[n4] and accept(n4) then
			seen[n4] = true
			top += 1
			stack[top] = n4
			count += 1
			res[count] = n4
		end
	end

	for i = count + 1, #res do
		res[i] = nil
	end
	return res, count
end

-- ================================================================ detonation ==
--
-- NukeExecution.detonate (NukeExecution.ts:369-495).
--
-- DETONATION COST, stated plainly. The blast set is the dominant cost of the
-- whole layer, not the flight. Upstream's radii against an 880x550 frame:
--
--   atom      outer 30   about 2,800 tiles   0.6% of the map
--   warhead   outer 18   about 1,000 tiles
--   hydrogen  outer 100  about 31,400 tiles  6.5% of the map
--
-- Every OWNED tile in the set is one Sim.conquer, which refreshes five border
-- entries and appends a change pair. A hydrogen bomb landing wholly inside
-- one empire is therefore about 31,000 conquers in a single tick -- more than
-- two ticks of Config.GLOBAL_TILE_BUDGET -- and about 31,000 entries in
-- sim.changes, which ConquestServer slices into eleven 3,000-pair frames.
--
-- The MIRV is smaller than its 350 warheads suggest, and the reason is
-- minimumSpread: every warhead aimpoint must be at least 55 MANHATTAN from
-- every other AND inside the target's own territory
-- (MIRVExecution.ts:241-254). An average 880x550 empire cannot hold more than
-- a handful of points that far apart, so a salvo self-limits to roughly
-- (side/39)^2 warheads -- a few against a normal empire, forty or so against
-- one holding a third of the map. Forty warheads is 40,000 tiles arriving
-- over the salvo's ~30 staggered ticks, so about 1,300 conquers a tick.
--
-- That is survivable; the WIRE is the part that is not, and the blast event
-- emitted below exists so a client can regenerate a crater from a dozen bytes
-- instead of receiving it as tile deltas. See the report.

-- 18, 19 ARRIVED AFTER THIS LIST WAS WRITTEN (2026-09-21) and were never added
-- to it, so a warhead swept every building except the artillery battery and the
-- airfield. Those two died only when the ground under them changed hands, which
-- is a coin flip on the rim between `inner` and `outer` -- measured, a gun or a
-- field on a spared rim tile came through the blast still armed and still
-- firing. Units.STRUCTURE_TYPES has carried both since the day they shipped;
-- this is the same set.
local BLAST_UNIT_TYPES = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 18, 19 }

local blastScratch: { number } = {}
local unitScratch: { any } = {}

local function detonate(sim: any, ex: any)
	local u = ex.unit
	local mag = CFG.MAGNITUDE[ex.utype]
	local dst = ex.dst
	local map = sim.map

	local tiles, count = Nukes.blastTiles(sim, dst, mag.inner, mag.outer, ex.blastSeed, blastScratch)

	-- Pass one: relinquish, count per player, glass the ground.
	local perPlayer: { [number]: number } = {}
	for i = 1, count do
		local t = tiles[i]
		local ownerId = buffer.readu8(map.owner, t)
		if ownerId ~= 0 then
			sim:conquer(t, 0)
			perPlayer[ownerId] = (perPlayer[ownerId] or 0) + 1
		end
		if TileMap.isLand(map, t) then
			Nukes.setFallout(sim, t, true)
		end
	end

	-- Pass two: the population. Upstream applies deathFactor once per impacted
	-- tile against a shrinking denominator (NukeExecution.ts:399-444), so the
	-- marginal tile kills less than the first -- and it applies the same
	-- attrition to troops already committed to attacks and to troops at sea,
	-- which is what stops an empire parking its army in transit to dodge a
	-- strike.
	for playerId, impacted in perPlayer do
		local p = sim.players[playerId]
		if p ~= nil then
			-- NUKING AN ALLY IS A BETRAYAL (NukeExecution.ts; Config.ts:1005-1007).
			-- Past ALLIANCE_BREAK_THRESHOLD of their tiles glassed, the alliance
			-- breaks with the shooter marked the traitor. Under it, an edge of
			-- blast that clipped a friend is forgiven.
			if
				u ~= nil
				and u.ownerId ~= playerId
				and impacted > CFG.ALLIANCE_BREAK_THRESHOLD
				and Alliances.allied(sim, u.ownerId, playerId)
			then
				Alliances.breakAlliance(sim, u.ownerId, playerId)
			end
			-- BLAST CREDIT. A warhead can empty an empire outright, and that
			-- death has no conqueror to hand the treasury to -- Sim's
			-- checkElimination pays whoever this names rather than deleting it.
			-- Set for every empire the blast touched, not only the aimpoint's
			-- owner: collateral that finishes somebody still finished them.
			p.lastHitBy = u.ownerId
			local tilesBefore = p.tileCount + impacted
			local maxT = maxTroopsOf(p)

			local attacks = {}
			if sim.attacks ~= nil then
				for _, atk in sim.attacks do
					if atk.active and atk.attackerId == playerId then
						attacks[#attacks + 1] = atk
					end
				end
			end
			local transportBoats = {}
			if sim.transportBoats ~= nil then
				for _, b in sim.transportBoats do
					if b.active and b.ownerId == playerId then
						transportBoats[#transportBoats + 1] = b
					end
				end
			end

			local nAtk = #attacks
			local nTransportBoat = #transportBoats
			for i = 0, impacted - 1 do
				local left = tilesBefore - i
				p.troops = math.max(0, p.troops - Nukes.deathFactor(ex.utype, p.troops, left, maxT))
				for k = 1, nAtk do
					local atk = attacks[k]
					atk.troops = math.max(0, atk.troops - Nukes.deathFactor(ex.utype, atk.troops, left, maxT))
				end
				for k = 1, nTransportBoat do
					local b = transportBoats[k]
					b.troops = math.max(0, b.troops - Nukes.deathFactor(ex.utype, b.troops, left, maxT))
				end
			end
		end
	end

	-- Pass three: hardware. Everything inside the outer radius dies except
	-- other missiles (NukeExecution.ts:449-463) -- a nuke cannot shoot down a
	-- nuke, and a SAM missile in flight is not collateral.
	local nUnits = Units.nearby(sim, dst, mag.outer, BLAST_UNIT_TYPES, unitScratch, nil, nil, true)
	for i = 1, nUnits do
		local victim = unitScratch[i]
		unitScratch[i] = nil
		if victim.active and victim ~= u then
			Units.delete(sim, victim, ex.playerId)
		end
	end

	-- Economy still owns cities and ports until the Units migration lands, so
	-- the blast has to reach both stores. sim.structList is empty once it has.
	if sim.structList ~= nil and #sim.structList > 0 then
		local outer2 = mag.outer * mag.outer
		local doomed = {}
		for _, s in sim.structList do
			if dist2(dst, s.tile) < outer2 then
				doomed[#doomed + 1] = s
			end
		end
		for _, s in doomed do
			Economy.remove(sim, s)
		end
	end

	ex.active = false
	if u ~= nil then
		u.reachedTarget = true
		Units.delete(sim, u, nil)
	end

	emit(sim, {
		e = "b",
		id = ex.missileId,
		tile = dst,
		inner = mag.inner,
		outer = mag.outer,
		seed = ex.blastSeed,
		kind = ex.utype,
		owner = ex.playerId,
	})
end

-- ============================================================ NukeExecution ==
--
-- NukeExecution.ts:184-292.

local function nukeTargetable(ex: any, nukeTile: number): boolean
	-- EVERY TILE OF THE ARC, see CFG.INTERCEPT_ANYWHERE. This is the whole of
	-- the fly-over change on the launcher's side: computeIntercept already
	-- walks the entire trajectory looking for a tile inside range, and this
	-- flag is the only thing that was rejecting the ones in the middle.
	if CFG.INTERCEPT_ANYWHERE then
		return true
	end
	local r2 = CFG.TARGETABLE_RANGE * CFG.TARGETABLE_RANGE
	if dist2(nukeTile, ex.dst) < r2 then
		return true
	end
	return ex.src ~= nil and dist2(ex.src, nukeTile) < r2
end

local function nukeTick(sim: any, ex: any)
	if ex.unit == nil then
		-- A SCATTERSHOT'S SMALL WARHEADS FLY WITH THEIR MAIN ONE (2026-09-24).
		-- They were queued behind it (Nukes.launchScattershot), so on the tick
		-- the main warhead launches -- paid, silo picked, queue position known
		-- -- these read its source and its wait and go too. If it was refused
		-- (gold, silo), they are cancelled with it and cost nothing.
		local parent = ex.parent
		if parent ~= nil then
			if parent.unit == nil then
				if not parent.active then
					ex.active = false
					ex.why = parent.why
				end
				return
			end
			ex.parent = nil
			ex.src = parent.src
			ex.waitTicks += parent.waitTicks
		end
		local src = ex.src
		local isWarhead = ex.utype == Units.MIRV_WARHEAD

		if isWarhead then
			-- canSpawnUnitType returns the target tile for a warhead
			-- (PlayerImpl.ts:1493-1494): no silo, no cooldown, no gold, and
			-- no isAlive test (PlayerImpl.ts:1353-1355).
			src = src or ex.dst
		else
			-- Re-checked HERE and not at purchase, exactly as upstream re-runs
			-- canBuild inside tick(): a silo that went on cooldown between the
			-- order and the launch cancels the shot rather than teleporting it
			-- to a different silo.
			local spawn, why = Nukes.nukeSpawn(sim, ex.playerId, ex.utype, ex.dst)
			if spawn == false then
				ex.active = false
				ex.why = why
				return
			end
			local p = sim.players[ex.playerId]
			local cost = Units.cost(sim, ex.playerId, ex.utype)
			-- A FREE SHOT IS SPENT HERE, AT THE CHARGE -- not at the order.
			-- This is the only line where the gold actually leaves, so it is
			-- the only place that can honour the "+1 Nuke!" token (see
			-- Products) without opening a second route to a warhead nobody
			-- paid for: a shot cancelled between order and launch never
			-- reaches this tick and never spends the token.
			--
			-- ATOM BOMBS ONLY, which is the same whitelist ConquestServer's
			-- nuke intent applies. The MIRV block further down has its own
			-- charge and no token can reach it.
			local free = p ~= nil
				and p.alive
				and ex.utype == Units.ATOM_BOMB
				and (p.freeNukes or 0) > 0
			if free then
				p.freeNukes -= 1
			elseif p == nil or not p.alive or p.gold < cost then
				ex.active = false
				ex.why = "gold"
				return
			else
				p.gold -= cost
			end
			src = src or (spawn :: number)
		end
		ex.src = src

		-- Stacked purchases from one silo trail each other instead of
		-- overlapping. The WHOLE queue is walked, because several nukes bought
		-- on the same tick all see the same front entry
		-- (NukeExecution.ts:195-210).
		local silo: any = nil
		if not isWarhead then
			silo = siloAt(sim, ex.playerId, src :: number)
		end
		if silo ~= nil then
			local lastDep = 0
			for _, launchTick in silo.missileTimers do
				lastDep = math.max(launchTick + 1, lastDep + 1)
			end
			if lastDep > sim.tick then
				ex.waitTicks += lastDep - sim.tick
			end
		end

		local c = Nukes.arc(src :: number, ex.dst, ex.speed, ex.dirUp)
		ex.curve = c
		local traj = curveTiles(c)
		local trajT = table.create(#traj)
		for i = 1, #traj do
			trajT[i] = nukeTargetable(ex, traj[i])
		end

		local u = Units.spawn(sim, ex.utype, ex.playerId, src :: number, {
			targetTile = ex.dst,
			trajectory = traj,
			ext = { trajTargetable = trajT, waitTicks = ex.waitTicks, execId = ex.id },
		})
		ex.unit = u
		ex.missileId = u.id

		local ev = {
			e = "l",
			id = u.id,
			kind = ex.utype,
			owner = ex.playerId,
			src = src,
			dst = ex.dst,
			speed = ex.speed,
			wait = ex.waitTicks,
			tick = sim.tick,
			up = ex.dirUp ~= false,
		}
		ex.launchEvent = ev
		emit(sim, ev)

		if silo ~= nil then
			Units.launch(sim, silo)
		end
		return
	end

	local u = ex.unit
	if not u.active then
		-- Intercepted, or caught in somebody else's blast.
		ex.active = false
		return
	end

	if ex.waitTicks > 0 then
		ex.waitTicks -= 1
		if u.ext ~= nil then
			u.ext.waitTicks = ex.waitTicks
		end
		return
	end

	local more = Curve.step(ex.curve, ex.speed)
	if not more then
		-- Arrived. Move the sprite home first, then let a SAM missile already
		-- inside its own final step win the race: the launcher is the source
		-- of truth for interception, because missiles skip pixels and
		-- execution order is not a physical fact (NukeExecution.ts:270-285).
		Units.move(sim, u, ex.dst)
		local n = Units.nearby(sim, ex.dst, CFG.SAM_MISSILE_SPEED, Units.SAM_MISSILE, unitScratch, nil, function(m)
			return m.ownerId ~= u.ownerId and m.targetUnitId == u.id
		end, true)
		for i = 1, n do
			unitScratch[i] = nil
		end
		if n == 0 then
			detonate(sim, ex)
		end
		return
	end

	u.targetable = nukeTargetable(ex, u.tile)
	Units.move(sim, u, Curve.tileAt(ex.curve, ex.curve.idx))
	u.trajectoryIndex = ex.curve.idx
end

-- Order an atom or hydrogen bomb. Gold is taken and the silo committed on the
-- execution's FIRST TICK, not here, which is upstream's ordering; this call
-- only refuses obviously illegal orders so the HUD has a reason to show.
-- src/speed/waitTicks/dirUp exist for the MIRV salvo and the AI's staggered
-- anti-SAM salvo; a normal shot passes nil.
function Nukes.launchNuke(
	sim: any,
	playerId: number,
	utype: number,
	dst: number,
	src: number?,
	speed: number?,
	waitTicks: number?,
	dirUp: boolean?
): (boolean, string?)
	if CFG.MAGNITUDE[utype] == nil then
		return false, "notanuke"
	end
	if utype ~= Units.MIRV_WARHEAD then
		local spawn, why = Nukes.nukeSpawn(sim, playerId, utype, dst)
		if spawn == false then
			return false, why
		end
		local p = sim.players[playerId]
		-- A FREE SHOT PASSES THE PRICE CHECK AS WELL AS THE CHARGE. The token
		-- is spent in nukeTick (the only line where gold actually leaves), but
		-- the ORDER is refused here first -- so without this the "+1 Nuke!"
		-- buyer is told "not enough gold" for money they were never going to
		-- pay, and the product only works for somebody who could already
		-- afford a warhead. Atom bombs only, matching the charge.
		local free = p ~= nil
			and utype == Units.ATOM_BOMB
			and (p.freeNukes or 0) > 0
		if p == nil or (not free and p.gold < Units.cost(sim, playerId, utype)) then
			return false, "gold"
		end
	end

	sim.nukeSeq += 1
	addExec(sim, {
		kind = "nuke",
		id = sim.nukeSeq,
		utype = utype,
		playerId = playerId,
		dst = dst,
		src = src,
		speed = speed or Nukes.speed(utype),
		waitTicks = waitTicks or 0,
		dirUp = dirUp,
		blastSeed = sim.tick * 8191 + dst,
		unit = nil,
		active = true,
	})
	return true
end

-- ============================================================ SCATTERSHOT ==
--
-- NOT UPSTREAM (owner, 2026-09-24: "a MIRV but i wanna call it a scattershot,
-- it basically launches a main nuke, and 4-6 smaller ones"). One order puts
-- a MAIN warhead (Units.SCATTERSHOT, the atom bomb's crater, the whole price)
-- on the aimpoint and SCATTERSHOT_WARHEADS_MIN..MAX MIRV warheads on a ring
-- around it. The small ones are ordinary warhead executions -- targetable by
-- SAMs, the MIRV warhead's crater and death curve -- held back by `parent`
-- until the main one has launched (see nukeTick), then fired from the same
-- source a couple of ticks apart so the salvo fans out of one silo.
--
-- Their aimpoints: evenly spaced headings with a jitter, at a random distance
-- between SPREAD_MIN and SPREAD_MAX, kept on passable ground and off the
-- shooter's own side (a warhead that would land on an ally or a teammate is
-- re-rolled, and after a few tries dropped rather than fired). Rolled on
-- sim.rng, so a harness replay lands the same salvo.
function Nukes.launchScattershot(sim: any, playerId: number, dst: number): (boolean, string?)
	local ok, why = Nukes.launchNuke(sim, playerId, Units.SCATTERSHOT, dst)
	if not ok then
		return false, why
	end
	local list = sim.nukeExecs
	local main = list[#list]
	local map = sim.map
	local lo = Config.SCATTERSHOT_WARHEADS_MIN or 4
	local hi = math.max(lo, Config.SCATTERSHOT_WARHEADS_MAX or 6)
	local rmin = Config.SCATTERSHOT_SPREAD_MIN or 28
	local rmax = math.max(rmin, Config.SCATTERSHOT_SPREAD_MAX or 46)
	local rng = sim.rng
	local count = rng:NextInteger(lo, hi)
	local cx, cy = tx(dst), ty(dst)
	local base = rng:NextNumber() * math.pi * 2
	local speed = Nukes.speed(Units.SCATTERSHOT)
	local fired = 0
	for i = 1, count do
		local target: number? = nil
		for _ = 1, 6 do
			local a = base + (i - 1) / count * math.pi * 2 + (rng:NextNumber() - 0.5) * 0.6
			local r = rmin + rng:NextNumber() * (rmax - rmin)
			local x = math.floor(cx + math.cos(a) * r + 0.5)
			local y = math.floor(cy + math.sin(a) * r + 0.5)
			if x >= 0 and x < W and y >= 0 and y < H then
				local t = y * W + x
				local o = buffer.readu8(map.owner, t)
				local mine = o ~= 0 and (o == playerId or (sim.sameTeam ~= nil and sim:sameTeam(playerId, o)))
				if notImpassable(map, t) and not mine then
					target = t
					break
				end
			end
		end
		if target ~= nil then
			fired += 1
			sim.nukeSeq += 1
			addExec(sim, {
				kind = "nuke",
				id = sim.nukeSeq,
				utype = Units.MIRV_WARHEAD,
				playerId = playerId,
				dst = target,
				src = nil,
				speed = speed,
				-- Rippled off the main launch, two ticks apart.
				waitTicks = fired * 2,
				dirUp = nil,
				blastSeed = sim.tick * 8191 + target + fired,
				unit = nil,
				active = true,
				parent = main,
			})
		end
	end
	return true
end

-- =========================================================== MirvExecution ==
--
-- MIRVExecution.ts:80-270. The carrier climbs on its own arc to a separation
-- point 500 tiles above the target's latitude, and ten ticks before it gets
-- there it hands 350 independent NukeExecutions their destinations. The
-- carrier itself cannot be intercepted -- only the warheads can
-- (SAMMissileExecution.ts:44-49).

local function mirvTryTarget(sim: any, ex: any, taken: { number }, nTaken: number): number?
	local map = sim.map
	for _ = 1, 100 do
		local r1 = Rand.next(ex.rand)
		local r2 = (r1 * 15485863) % 1

		local x = math.round(r1 * ex.range * 2 - ex.range + ex.baseX)
		local y = math.round(r2 * ex.range * 2 - ex.range + ex.baseY)
		if x >= 0 and x < W and y >= 0 and y < H then
			local tile = y * W + x
			if TileMap.isLand(map, tile) then
				local ddx = x - ex.baseX
				local ddy = y - ex.baseY
				if ddx * ddx + ddy * ddy <= ex.rangeSquared then
					-- The salvo only ever lands on the TARGET's own tiles and the
					-- target is now always an AI (considerMirv) -- but a warhead's
					-- own outer radius is 18 tiles, so one aimed at a bot's edge can
					-- still cover a person standing behind it. Refused here, warhead
					-- by warhead, because each picks its tile in flight rather than
					-- at launch.
					--
					-- UNCONDITIONAL, and that is safe only because the MIRV is
					-- AI-ONLY: ConquestServer's nuke intent whitelists the atom bomb
					-- alone. Put a MIRV on the action rail and this has to become a
					-- test on the owner's isBot in the same commit.
					if
						buffer.readu8(map.owner, tile) == ex.targetId
						and not blastTouchesPerson(sim, tile, CFG.MAGNITUDE[Units.MIRV_WARHEAD].outer)
					then
						local clear = true
						for i = 1, nTaken do
							local t = taken[i]
							local ox = t % W
							if math.abs(x - ox) + math.abs(y - (t - ox) / W) < CFG.MIRV_MIN_SPREAD then
								clear = false
								break
							end
						end
						if clear then
							return tile
						end
					end
				end
			end
		end
	end
	return nil
end

local function mirvTick(sim: any, ex: any)
	if ex.unit == nil then
		local spawn, why = Nukes.nukeSpawn(sim, ex.playerId, Units.MIRV, ex.dst)
		if spawn == false then
			ex.active = false
			ex.why = why
			return
		end
		local p = sim.players[ex.playerId]
		local cost = Units.cost(sim, ex.playerId, Units.MIRV)
		if p == nil or not p.alive or p.gold < cost then
			ex.active = false
			ex.why = "gold"
			return
		end
		p.gold -= cost

		local src = spawn :: number
		ex.src = src

		local u = Units.spawn(sim, Units.MIRV, ex.playerId, src, {
			targetTile = ex.dst,
			targetPlayerId = ex.targetId,
		})
		ex.unit = u
		ex.missileId = u.id
		-- Priced off a GLOBAL counter (Config.ts:502-514): every MIRV ever
		-- launched makes the next one dearer for everybody. Bumped after the
		-- charge, so the launcher pays the price it was quoted.
		sim.mirvsLaunched += 1

		-- MIRVExecution.ts:94-96.
		local sepX = (ex.baseX + tx(src)) // 2
		local sepY = math.max(0, ex.baseY - CFG.MIRV_SEPARATION_RISE) + 50
		ex.separateDst = sepY * W + sepX

		-- fullPath is what next() yields, which is the sampled curve minus its
		-- first and last point (Line.ts:41-44), hence the minus two.
		ex.path = Nukes.arcTiles(src, ex.separateDst, ex.speed)
		ex.pathLen = math.max(0, #ex.path - 2)
		ex.pathIdx = 0

		local ev = {
			e = "l",
			id = u.id,
			kind = Units.MIRV,
			owner = ex.playerId,
			src = src,
			dst = ex.separateDst,
			speed = ex.speed,
			wait = 0,
			tick = sim.tick,
			up = true,
			target = ex.dst,
		}
		ex.launchEvent = ev
		emit(sim, ev)

		local silo = siloAt(sim, ex.playerId, src)
		if silo ~= nil then
			Units.launch(sim, silo)
		end
	end

	local u = ex.unit
	if not u.active then
		ex.active = false
		for _, w in ex.warheads do
			w.active = false
			if w.unit ~= nil and w.unit.active then
				Units.delete(sim, w.unit, nil)
			end
		end
		table.clear(ex.warheads)
		emit(sim, { e = "x", id = ex.missileId, hit = false })
		return
	end

	local remaining = ex.pathLen - ex.pathIdx

	-- Destination finding is spread over ticks 20 down to 11 so no single tick
	-- eats 350 rejection-sampled targets (MIRVExecution.ts:141-149).
	if remaining <= 20 and remaining > 10 then
		for _ = 1, 100 do
			if ex.nStaged >= CFG.MIRV_WARHEADS then
				break
			end
			local t = mirvTryTarget(sim, ex, ex.staged, ex.nStaged)
			if t ~= nil then
				ex.nStaged += 1
				ex.staged[ex.nStaged] = t
			end
		end
	end

	if remaining <= 10 and not ex.spawned then
		ex.spawned = true

		-- Re-check ownership: ground taken back while the carrier climbed is
		-- no longer a valid aimpoint (MIRVExecution.ts:171-174).
		local map = sim.map
		local kept = {}
		local nKept = 0
		for i = 1, ex.nStaged do
			local t = ex.staged[i]
			if t == ex.dst or buffer.readu8(map.owner, t) == ex.targetId then
				nKept += 1
				kept[nKept] = t
			end
		end
		ex.staged = kept
		ex.nStaged = nKept

		local extra = (10 - remaining) * 50
		for _ = 1, 500 + extra do
			if ex.nStaged >= CFG.MIRV_WARHEADS then
				break
			end
			local t = mirvTryTarget(sim, ex, ex.staged, ex.nStaged)
			if t ~= nil then
				ex.nStaged += 1
				ex.staged[ex.nStaged] = t
			end
		end

		-- Farthest first, so the salvo blooms from the rim inward
		-- (MIRVExecution.ts:183-187). The tile-id tiebreak is not upstream; it
		-- is here because table.sort is not stable and a MIRV must land the
		-- same way twice.
		local dstTile = ex.dst
		table.sort(ex.staged, function(a: number, b: number): boolean
			local da = manhattan(a, dstTile)
			local db = manhattan(b, dstTile)
			if da == db then
				return a > b
			end
			return da > db
		end)

		local waitBase = math.max(0, remaining)
		local warheadSpeed = Nukes.speed(Units.MIRV_WARHEAD)
		for i = 1, ex.nStaged do
			local offset = 4
			if i <= 70 then
				offset = 0
			elseif i <= 140 then
				offset = 1
			elseif i <= 210 then
				offset = 2
			elseif i <= 280 then
				offset = 3
			end
			sim.nukeSeq += 1
			local w = addExec(sim, {
				kind = "nuke",
				id = sim.nukeSeq,
				utype = Units.MIRV_WARHEAD,
				playerId = ex.playerId,
				dst = ex.staged[i],
				src = ex.separateDst,
				speed = warheadSpeed + offset,
				waitTicks = waitBase + Rand.nextInt(ex.rand, 0, 15),
				dirUp = true,
				blastSeed = sim.tick * 8191 + ex.staged[i] + i,
				unit = nil,
				active = true,
			})
			ex.warheads[#ex.warheads + 1] = w
		end
	end

	if ex.pathIdx < ex.pathLen then
		ex.pathIdx += 1
		Units.move(sim, u, ex.path[ex.pathIdx + 1])
	else
		Units.delete(sim, u, nil)
		ex.active = false
		emit(sim, { e = "x", id = ex.missileId, hit = true })
	end
end

function Nukes.launchMirv(sim: any, playerId: number, dst: number): (boolean, string?)
	local spawn, why = Nukes.nukeSpawn(sim, playerId, Units.MIRV, dst)
	if spawn == false then
		return false, why
	end
	local p = sim.players[playerId]
	if p == nil or p.gold < Units.cost(sim, playerId, Units.MIRV) then
		return false, "gold"
	end

	sim.nukeSeq += 1
	addExec(sim, {
		kind = "mirv",
		id = sim.nukeSeq,
		playerId = playerId,
		dst = dst,
		targetId = buffer.readu8(sim.map.owner, dst),
		speed = Nukes.speed(Units.MIRV),
		baseX = tx(dst),
		baseY = ty(dst),
		range = CFG.MIRV_RANGE,
		rangeSquared = CFG.MIRV_RANGE * CFG.MIRV_RANGE,
		rand = Rand.new(sim.tick + playerId * 2654435761),
		staged = { dst },
		nStaged = 1,
		warheads = {},
		spawned = false,
		pathIdx = 0,
		pathLen = 0,
		unit = nil,
		active = true,
	})
	return true
end

-- ================================================================ SAM range ==
--
-- Config.dynamicSamRange (Config.ts:1043-1056): an upgrading launcher's
-- radius INTERPOLATES to its new value over samUpgradeDuration instead of
-- snapping, so a nuke already in flight is not retroactively inside a bigger
-- bubble.
--
-- The live value is cached back onto ext.currentRange every tick. Units.upgrade
-- snapshots exactly that field when it records the pre-upgrade radius
-- (Units:1220) and nothing else writes it, so keeping it fresh here is what
-- makes that line correct.

function Nukes.samRangeNow(sim: any, u: any, tick: number?): number
	local ext = u.ext
	if ext == nil or ext.upgradeStartTick == nil then
		return Nukes.samRange(u.level)
	end
	local now = tick or sim.tick
	local duration = ext.duration or CFG.SAM_UPGRADE_DURATION
	local elapsed = now - ext.upgradeStartTick
	local target = Nukes.samRange(ext.targetLevel or u.level)
	if elapsed >= duration then
		return target
	end
	local startRange = ext.startRange or Nukes.samRange(u.level)
	return startRange + (target - startRange) * elapsed / duration
end

-- ==================================================== SAM interception plan ==
--
-- SAMLauncherExecution.ts:27-259, SAMTargetingSystem.

-- THE MEGA NUKE IS IN HERE, and it has to be: this list is what a launcher
-- looks for in the sky, so a type missing from it flies through a SAM belt
-- untouched -- which is exactly the blind spot INTERCEPT_ANYWHERE was written
-- to close, arriving by a different door. The MIRV carrier stays out (only its
-- warheads are interceptable, SAMMissileExecution.ts:44-49).
local NUKE_TARGET_TYPES = { Units.ATOM_BOMB, Units.HYDROGEN_BOMB, Units.MIRV_WARHEAD, Units.MEGA_NUKE, Units.SCATTERSHOT }

local function ticksToReach(from: number, to: number): number
	return math.ceil(manhattan(from, to) / CFG.SAM_MISSILE_SPEED)
end

-- The last-ditch shot: if the nuke's final tile is inside range and its
-- second-to-last tile is targetable, plan to meet it there
-- (SAMLauncherExecution.ts:63-89).
local function detonationIntercept(sim: any, sam: any, nuke: any, ticks: number): (number?, number?)
	local traj = nuke.trajectory
	local flags = nuke.ext and nuke.ext.trajTargetable
	if traj == nil or flags == nil then
		return nil, nil
	end
	local len = #traj
	if len < 2 or not flags[len] then
		return nil, nil
	end
	local curIdx = nuke.trajectoryIndex
	local waitTicks = (nuke.ext and nuke.ext.waitTicks) or 0
	local expTicks = len - 1 - curIdx + waitTicks
	local range = Nukes.samRangeNow(sim, sam, ticks + expTicks)
	if dist2(sam.tile, traj[len]) > range * range then
		return nil, nil
	end
	if not flags[len - 1] then
		return nil, nil
	end
	local nukeTicks = (len - 2) - curIdx + waitTicks
	local before = nukeTicks - ticksToReach(sam.tile, traj[len - 1])
	if before >= 0 then
		return before, traj[len - 1]
	end
	return nil, nil
end

-- Returns tick, tile, minDistSq. tick >= 0 is "fire in this many ticks";
-- -1 is "not reachable at this upgrade level"; -2 is "never".
local function computeIntercept(sim: any, sam: any, nuke: any, ticks: number): (number, number, number)
	local traj = nuke.trajectory
	local flags = nuke.ext and nuke.ext.trajTargetable
	if traj == nil or flags == nil then
		return -2, sam.tile, math.huge
	end
	local curIdx = nuke.trajectoryIndex
	local waitTicks = (nuke.ext and nuke.ext.waitTicks) or 0
	local maxIdx = #traj - 2
	local maxRangeSq = CFG.MAX_SAM_RANGE * CFG.MAX_SAM_RANGE
	local minDistSq = math.huge
	local samTile = sam.tile
	local closest = samTile
	local incSteps = 0
	local lastDistSq = -1

	for i = curIdx, maxIdx do
		local tile = traj[i + 1]
		local d2 = dist2(samTile, tile)
		if d2 < minDistSq then
			minDistSq = d2
			closest = tile
		end
		if lastDistSq ~= -1 and d2 > lastDistSq then
			incSteps += 1
		else
			incSteps = 0
		end
		lastDistSq = d2

		local nukeTicks = i - curIdx + waitTicks
		if flags[i + 1] then
			local allowed = Nukes.samRangeNow(sim, sam, ticks + nukeTicks)
			local samTicks = ticksToReach(samTile, tile)
			if d2 <= allowed * allowed and nukeTicks >= samTicks then
				return nukeTicks - samTicks, tile, minDistSq
			end
		end
		if incSteps > 3 and d2 > maxRangeSq then
			break
		end
	end

	local dt, dtile = detonationIntercept(sim, sam, nuke, ticks)
	if dt ~= nil then
		return dt, dtile :: number, minDistSq
	end
	return (minDistSq > maxRangeSq) and -2 or -1, closest, minDistSq
end

-- SAMLauncherExecution.ts:173-201. Hydrogen first, then whatever threatens
-- ground nearest the launcher, then whatever lands soonest.
local function targetScore(sam: any, nuke: any): number
	local traj = nuke.trajectory
	local len = traj and #traj or 0
	local timeToExplode = math.max(1, len - nuke.trajectoryIndex)
	local targetTile = nuke.targetTile
	if targetTile == nil then
		targetTile = (len > 0) and traj[len] or sam.tile
	end
	local typeBonus = (nuke.utype == Units.HYDROGEN_BOMB) and 70001 or 0
	local distanceBonus = math.max(0, 200000 - manhattan(sam.tile, targetTile) * 1000)
	local urgencyBonus = math.max(0, 10000 - timeToExplode * 100)
	return typeBonus + distanceBonus + urgencyBonus
end

-- Three parallel scratch arrays rather than a table per target: a full salvo
-- would otherwise allocate 350 tables per SAM per tick.
local tgtUnit: { any } = {}
local tgtTile: { number } = {}
local tgtScore: { number } = {}
local tgtOrder: { number } = {}

local function samValidTargets(sim: any, sam: any, ticks: number): number
	local cache = sam.ext.samCache
	local budget = CFG.SAM_PLAN_BUDGET
	local n = 0
	local samTile = sam.tile
	local ownerId = sam.ownerId
	-- maxSamRange * 4 (SAMLauncherExecution.ts:216-217).
	local detect = CFG.MAX_SAM_RANGE * 4
	local detect2 = detect * detect

	-- OFF THE LIST'S OWN LENGTH, not the 3 that used to be written here. The
	-- literal made the list above a lie the moment a type was added to it: a
	-- fourth entry was simply never walked, so a mega nuke crossed a launcher's
	-- ring without the launcher ever seeing it (measured, and it is silent --
	-- nothing errors, the warhead just arrives).
	for ti = 1, #NUKE_TARGET_TYPES do
		for _, nuke in Units.ofType(sim, NUKE_TARGET_TYPES[ti]) do
			if nuke.active and not nuke.targetedBySam and nuke.ownerId ~= ownerId then
				local friendly = sim.sameTeam ~= nil and sim:sameTeam(ownerId, nuke.ownerId)
				-- A friendly nuke is fair game only after the game is over
				-- (SAMLauncherExecution.ts:164-170).
				local eligible = (not friendly) or sim.phase == "ended"
				if eligible and dist2(samTile, nuke.tile) <= detect2 then
					local id = nuke.id
					local c = cache[id]
					local recompute = true
					if c ~= nil then
						c.lastSeen = ticks
						if c.tick == -1 or c.tick == -2 then
							recompute = false
						elseif c.tick == ticks or c.tick == ticks + 1 then
							n += 1
							tgtUnit[n] = nuke
							tgtTile[n] = c.tile
							cache[id] = nil
							recompute = false
						elseif c.tick > ticks then
							recompute = false
						else
							cache[id] = nil
						end
					end
					if recompute and budget > 0 then
						budget -= 1
						local tick, tile, minDistSq = computeIntercept(sim, sam, nuke, ticks)
						if tick >= 0 and tick <= 1 then
							n += 1
							tgtUnit[n] = nuke
							tgtTile[n] = tile
						else
							cache[id] = {
								tick = (tick >= 0) and (tick + ticks) or tick,
								tile = tile,
								minDistSq = minDistSq,
								lastSeen = ticks,
							}
						end
					end
				end
			end
		end
	end

	-- Drop nukes not seen this tick: gone, or outside the detection ring
	-- (SAMLauncherExecution.ts:49-55).
	for id, c in cache do
		if c.lastSeen ~= ticks then
			cache[id] = nil
		end
	end

	if n > 1 then
		for i = 1, n do
			tgtScore[i] = targetScore(sam, tgtUnit[i])
			tgtOrder[i] = i
		end
		for i = n + 1, #tgtOrder do
			tgtOrder[i] = nil
		end
		-- Sorted by permutation so the unit and its meeting tile stay paired.
		-- The id tiebreak is not upstream and is here because table.sort is
		-- not stable and two SAMs must agree on priority.
		table.sort(tgtOrder, function(a: number, b: number): boolean
			if tgtScore[a] == tgtScore[b] then
				return tgtUnit[a].id < tgtUnit[b].id
			end
			return tgtScore[a] > tgtScore[b]
		end)
		local u2 = table.create(n)
		local t2 = table.create(n)
		for i = 1, n do
			u2[i] = tgtUnit[tgtOrder[i]]
			t2[i] = tgtTile[tgtOrder[i]]
		end
		for i = 1, n do
			tgtUnit[i] = u2[i]
			tgtTile[i] = t2[i]
		end
	end
	return n
end

-- ======================================================= SAMMissileExecution ==
--
-- SAMMissileExecution.ts:36-90 over PathFinder.Air.ts. The interceptor walks a
-- random staircase to the PREDICTED tile and kills its target on arrival,
-- wherever the target actually is -- the launcher's plan is the source of
-- truth (NukeExecution.ts:270-274 says the same from the other side).

local function airPath(from: number, to: number, seed: number): { number }
	local rand = Rand.new(seed)
	local path = { from }
	local current = from
	local guard = 0
	while current ~= to do
		guard += 1
		if guard > 8192 then
			break
		end
		local x = current % W
		local y = (current - x) / W
		local dx = to % W
		local dy = (to - dx) / W
		if x == dx and y == dy then
			current = to
		else
			local nx, ny = x, y
			local ratio = math.floor(1 + math.abs(dy - y) / (math.abs(dx - x) + 1))
			if x == dx then
				ny += (y < dy) and 1 or -1
			elseif y == dy then
				nx += (x < dx) and 1 or -1
			elseif Rand.chance(rand, ratio) then
				nx += (x < dx) and 1 or -1
			else
				ny += (y < dy) and 1 or -1
			end
			local nxt = ny * W + nx
			if nxt == current then
				break
			end
			current = nxt
		end
		path[#path + 1] = current
	end
	return path
end

local function samMissileTick(sim: any, ex: any)
	if ex.unit == nil then
		local u = Units.spawn(sim, Units.SAM_MISSILE, ex.playerId, ex.src, {
			targetUnitId = ex.targetId,
		})
		ex.unit = u
		ex.path = airPath(ex.src, ex.dst, sim.tick * 131071 + u.id)
		ex.pathIdx = 1
		emit(sim, {
			e = "s",
			id = u.id,
			owner = ex.playerId,
			src = ex.src,
			dst = ex.dst,
			speed = CFG.SAM_MISSILE_SPEED,
			tick = sim.tick,
			target = ex.targetId,
		})
	end

	local u = ex.unit
	if not u.active then
		ex.active = false
		return
	end

	local target = Units.get(sim, ex.targetId)
	local launcher = Units.get(sim, ex.launcherId)
	local stillANuke = target ~= nil
		and (
			target.utype == Units.ATOM_BOMB
			or target.utype == Units.HYDROGEN_BOMB
			or target.utype == Units.MIRV_WARHEAD
			or target.utype == Units.MEGA_NUKE
			or target.utype == Units.SCATTERSHOT
		)
	if
		target == nil
		or not target.active
		or launcher == nil
		or not launcher.active
		or target.ownerId == u.ownerId
		or not stillANuke
	then
		-- Clear the flag so another launcher may re-engage
		-- (SAMMissileExecution.ts:56-59).
		if target ~= nil and target.active then
			target.targetedBySam = false
		end
		Units.delete(sim, u, nil)
		ex.active = false
		emit(sim, { e = "x", id = u.id, hit = false })
		return
	end

	local path = ex.path
	local len = #path
	for _ = 1, CFG.SAM_MISSILE_SPEED do
		if ex.pathIdx >= len then
			ex.active = false
			Units.delete(sim, target, ex.playerId)
			Units.delete(sim, u, nil)
			emit(sim, { e = "x", id = u.id, hit = true })
			emit(sim, { e = "x", id = target.id, hit = false })
			return
		end
		ex.pathIdx += 1
		Units.move(sim, u, path[ex.pathIdx])
	end
end

-- ============================================================ per-tick steps ==

-- MissileSiloExecution.ts:16-38. The front entry is when the earliest missile
-- left; once its cooldown is up, that tube comes back.
local function stepSilos(sim: any)
	local tick = sim.tick
	local list = Units.ofType(sim, Units.MISSILE_SILO)
	for i = 1, #list do
		local s = list[i]
		if s.active and not s.underConstruction then
			local front = s.missileTimers[1]
			if front ~= nil and CFG.SILO_COOLDOWN - (tick - front) <= 0 then
				Units.reload(sim, s)
			end
		end
	end
end

-- SAMLauncherExecution.ts:285-355.
local function stepSams(sim: any)
	local tick = sim.tick
	local list = Units.ofType(sim, Units.SAM_LAUNCHER)
	for li = 1, #list do
		local sam = list[li]
		if sam ~= nil and sam.active and not sam.underConstruction then
			local ext = sam.ext
			if ext == nil then
				ext = {}
				sam.ext = ext
			end
			-- Keep the live radius on the record. Units.upgrade snapshots this
			-- field, so it has to be fresh before any upgrade can land.
			ext.currentRange = Nukes.samRangeNow(sim, sam, tick)
			if ext.samCache == nil then
				ext.samCache = {}
			end
			if ext.samLevel ~= sam.level then
				-- On a level-up every "out of reach at this level" verdict is
				-- stale (SAMLauncherExecution.ts:41-47).
				if ext.samLevel ~= nil then
					for id, c in ext.samCache do
						if c.tick == -1 then
							ext.samCache[id] = nil
						end
					end
				end
				ext.samLevel = sam.level
			end

			while #sam.missileTimers > 0 do
				local front = sam.missileTimers[1]
				if CFG.SAM_COOLDOWN - (tick - front) > 0 then
					break
				end
				Units.reload(sim, sam)
			end

			if not Units.inCooldown(sam) then
				local n = samValidTargets(sim, sam, tick)
				for k = 1, n do
					local nuke = tgtUnit[k]
					local meetTile = tgtTile[k]
					if not Units.inCooldown(sam) and nuke.active and not nuke.targetedBySam then
						Units.launch(sim, sam)
						nuke.targetedBySam = true
						local ex = addExec(sim, {
							kind = "sammissile",
							playerId = sam.ownerId,
							launcherId = sam.id,
							targetId = nuke.id,
							src = sam.tile,
							dst = meetTile,
							unit = nil,
							pathIdx = 0,
							active = true,
						})
						-- SAMMissileExecution.init calls tick() at once, so an
						-- interceptor is already moving on its birth tick.
						samMissileTick(sim, ex)
					end
					tgtUnit[k] = nil
					tgtTile[k] = nil
					tgtScore[k] = nil
				end
			end
		end
	end
end

-- One tick of the whole nuclear layer.
--
-- ORDER MATTERS and this is upstream's. Executions run in creation order and a
-- launcher always exists before the missiles it fires, so: silos reload,
-- launchers decide and fire (each new interceptor moving on its birth tick),
-- then everything already in the air moves. A nuke that arrives this tick
-- therefore sees interceptors that have already taken their step, which is
-- what makes the close-range check in nukeTick mean anything.
function Nukes.step(sim: any)
	if sim.nukeExecs == nil then
		return
	end
	stepSilos(sim)
	stepSams(sim)

	local list = sim.nukeExecs
	local tick = sim.tick
	local n = #list
	for i = 1, n do
		local ex = list[i]
		if ex.active and ex.initTick ~= tick then
			if ex.kind == "nuke" then
				nukeTick(sim, ex)
			elseif ex.kind == "mirv" then
				mirvTick(sim, ex)
			elseif ex.kind == "sammissile" then
				samMissileTick(sim, ex)
			end
		end
	end

	-- Compact, preserving order, the way Sim compacts its attack list.
	local live = {}
	for _, ex in list do
		if ex.active then
			live[#live + 1] = ex
		end
	end
	sim.nukeExecs = live
end

-- ====================================================================== AI ==
--
-- NationNukeBehavior.ts (1104) and NationMIRVBehavior.ts (306), reduced to
-- what Conquest can express. Everything that reads the diplomacy layer is
-- gone: Conquest has no alliances, no relations, no targets() list and no
-- emoji channel, so retaliation-by-relation, ally assist, most-hated and the
-- whole alliance-break path have nothing to read. What survives is target
-- selection by threat and by share of the map, the tile scoring, the
-- SAM-outranging preference, and the trajectory-interception check, which is
-- pure geometry and ports whole.

local aiScratchTiles: { number } = {}
local aiScratchUnits: { any } = {}

-- NationNukeBehavior.ts:547-628. Could any enemy SAM shoot this shot down
-- anywhere along its arc, skipping the untargetable mid-course?
function Nukes.trajectoryInterceptable(
	sim: any,
	playerId: number,
	src: number,
	dst: number,
	excludeSamIds: { [number]: boolean }?
): boolean
	local traj = Nukes.arcTiles(src, dst, Nukes.speed(Units.ATOM_BOMB), true, aiScratchTiles)
	local len = #traj
	if len == 0 then
		return false
	end
	local r2 = CFG.TARGETABLE_RANGE * CFG.TARGETABLE_RANGE

	-- THE STRETCH NO SAM CAN TOUCH -- and with CFG.INTERCEPT_ANYWHERE there is
	-- no such stretch, so the window is never opened and the walk below tests
	-- every tile of the arc. Left standing rather than deleted: it is upstream's
	-- rule, it is one flag away, and an AI that skipped the middle of its own
	-- shot while the launchers covered it would be planning against a game that
	-- no longer exists -- firing over SAM belts that now answer.
	local untargetableStart = -1
	local untargetableEnd = -1
	if not CFG.INTERCEPT_ANYWHERE then
		for i = 1, len do
			local tile = traj[i]
			if untargetableStart == -1 then
				if dist2(tile, src) > r2 then
					if dist2(tile, dst) < r2 then
						break
					end
					untargetableStart = i
				end
			elseif dist2(tile, dst) < r2 then
				untargetableEnd = i
				break
			end
		end
	end

	local i = 1
	while i <= len do
		if untargetableStart ~= -1 and untargetableEnd ~= -1 and i == untargetableStart then
			i = untargetableEnd
			continue
		end
		local tile = traj[i]
		local n = Units.nearby(sim, tile, CFG.MAX_SAM_RANGE, Units.SAM_LAUNCHER, aiScratchUnits, nil, nil, false)
		local hit = false
		for k = 1, n do
			local sam = aiScratchUnits[k]
			aiScratchUnits[k] = nil
			if not hit and sam.ownerId ~= playerId then
				local friendly = sim.sameTeam ~= nil and sim:sameTeam(playerId, sam.ownerId)
				if not friendly and (excludeSamIds == nil or not excludeSamIds[sam.id]) then
					local range = Nukes.samRange(sam.level)
					if dist2(tile, sam.tile) <= range * range then
						hit = true
					end
				end
			end
		end
		if hit then
			return true
		end
		i += 1
	end
	return false
end

-- execution/Util.ts:234-282. Bounding-box centre of the border, falling back
-- to the nearest border tile when the centre is not actually owned.
function Nukes.territoryCenter(sim: any, p: any): number?
	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	local any = false
	for tile in p.border do
		any = true
		local x = tile % W
		local y = (tile - x) / W
		if x < minX then
			minX = x
		end
		if x > maxX then
			maxX = x
		end
		if y < minY then
			minY = y
		end
		if y > maxY then
			maxY = y
		end
	end
	if not any then
		return nil
	end
	local cx = (minX + maxX) // 2
	local cy = (minY + maxY) // 2
	local centre = cy * W + cx
	if buffer.readu8(sim.map.owner, centre) == p.id then
		return centre
	end
	local best: number? = nil
	local bestD = math.huge
	for tile in p.border do
		local x = tile % W
		local dx = x - cx
		local dy = (tile - x) / W - cy
		local d = dx * dx + dy * dy
		if d < bestD then
			bestD = d
			best = tile
		end
	end
	return best
end

-- NationNukeBehavior.ts:650-748, minus the difficulty branches Conquest has no
-- equivalent of. Structure value inside the blast, a penalty for distance from
-- the firing silo, a large bonus for a SAM this shot can outrange, and a veto
-- on ground somebody already nuked recently.
local function nukeTileScore(sim: any, p: any, tile: number, utype: number, recent: { any }): number
	local mag = CFG.MAGNITUDE[utype]
	local value = 0
	local n = Units.nearby(sim, tile, mag.outer, Units.STRUCTURE_TYPES, aiScratchUnits, nil, nil, false)
	for i = 1, n do
		local u = aiScratchUnits[i]
		aiScratchUnits[i] = nil
		-- A PERSON'S BUILDINGS ARE WORTH NOTHING TO AN AI AIMPOINT, so a bot
		-- never likes a tile BECAUSE a player's cities stand on it. The veto in
		-- aiThink is what stops the shot; this is what stops it being wanted.
		if u.ownerId ~= p.id and nukeable(sim, p, sim.players[u.ownerId]) then
			local t = u.utype
			if t == Units.CITY then
				value += 25000 * u.level
			elseif t == Units.DEFENSE_POST then
				value += 5000 * u.level
			elseif t == Units.MISSILE_SILO then
				value += 50000 * u.level
			elseif t == Units.PORT or t == Units.FACTORY then
				value += 15000 * u.level
			end
		end
	end
	-- Economy still owns cities and ports; same weights, same radius.
	if sim.structList ~= nil then
		local outer2 = mag.outer * mag.outer
		for _, s in sim.structList do
			if
				s.ownerId ~= p.id
				and dist2(tile, s.tile) < outer2
				and nukeable(sim, p, sim.players[s.ownerId])
			then
				value += ((s.kind == Economy.CITY) and 25000 or 15000) * s.level
			end
		end
	end

	if utype == Units.HYDROGEN_BOMB then
		local m = Units.nearby(sim, tile, mag.outer, Units.SAM_LAUNCHER, aiScratchUnits, nil, nil, false)
		for i = 1, m do
			local sam = aiScratchUnits[i]
			aiScratchUnits[i] = nil
			-- Nor is a person's anti-nuke tower a prize worth outranging.
			if
				sam.level < 5
				and sam.ownerId ~= p.id
				and nukeable(sim, p, sim.players[sam.ownerId])
			then
				local range = Nukes.samRange(sam.level)
				if dist2(tile, sam.tile) > range * range then
					value += 100000 * sam.level
				end
			end
		end
	end

	-- Closest own silo, from the silo list rather than the grid: a whole-map
	-- grid query would be 1,600 cell lookups per candidate tile, and an empire
	-- never has more than a handful of silos.
	local bestD2 = math.huge
	for _, s in Units.ofType(sim, Units.MISSILE_SILO) do
		if s.active and s.ownerId == p.id and not s.underConstruction then
			local d = dist2(tile, s.tile)
			if d < bestD2 then
				bestD2 = d
			end
		end
	end
	if bestD2 < math.huge then
		value = math.max(value * 0.2, value - math.sqrt(bestD2) * 30)
	end

	for _, r in recent do
		local inner = CFG.MAGNITUDE[r.utype].inner
		if dist2(tile, r.tile) <= inner * inner then
			value -= 1000000
		end
	end
	return value
end

local function aiState(p: any): any
	local s = p.nukeAi
	if s == nil then
		s = { recent = {}, atomCost = nil, hydroCost = nil, lastMirvTick = -100000 }
		p.nukeAi = s
	end
	return s
end

-- NationNukeBehavior.ts:166-260, in the part that has a Conquest analogue:
-- whoever is pressing us hardest, else whoever is closest to winning.
local function findNukeTarget(sim: any, p: any): any
	local worst: any = nil
	local worstTroops = 0
	if sim.attacks ~= nil then
		for _, atk in sim.attacks do
			if atk.active and atk.targetId == p.id and atk.troops > worstTroops then
				local a = sim.players[atk.attackerId]
				-- A PERSON INVADING A BOT DOES NOT GET NUKED FOR IT. This branch is
				-- upstream's whoever-is-pressing-us-hardest and it is the one most
				-- likely to name a player, so it is where the rule earns its keep.
				if nukeable(sim, p, a) then
					worstTroops = atk.troops
					worst = a
				end
			end
		end
	end
	if worst ~= nil then
		return worst
	end

	-- The crown, measured against CONTESTABLE land -- the same denominator the
	-- win check uses, so the AI reacts to the bar it is actually racing.
	local land = Nukes.contestableLand(sim)
	local best: any = nil
	local bestTiles = -1
	for _, id in sim.playerOrder do
		local o = sim.players[id]
		-- PEOPLE ARE SKIPPED INSIDE THE LOOP, not filtered after it. Letting a
		-- player hold `best` and refusing the launch later would retire every
		-- bot's arsenal for the rest of any round a human is leading -- so the
		-- crown here means the biggest empire a bot MAY hit, and the 0.2 share
		-- test below is against that empire.
		if o ~= nil and o.tileCount > bestTiles and nukeable(sim, p, o) then
			bestTiles = o.tileCount
			best = o
		end
	end
	if best == nil then
		return nil
	end
	if best.tileCount / land - p.tileCount / land > 0.2 then
		return best
	end
	return nil
end

-- NationNukeBehavior.ts:431-475. A nation quietly saves for a MIRV by
-- pretending each bomb costs more than it does, and each launch raises the
-- pretence -- 50 percent for an atom, 25 for a hydrogen.
local function perceivedCost(sim: any, p: any, utype: number): number
	local s = aiState(p)
	local real = Units.cost(sim, p.id, utype)
	if p.gold > Units.cost(sim, p.id, Units.MIRV) + Units.cost(sim, p.id, Units.HYDROGEN_BOMB) then
		return real
	end
	if utype == Units.ATOM_BOMB then
		s.atomCost = s.atomCost or real
		return s.atomCost
	end
	s.hydroCost = s.hydroCost or real
	return s.hydroCost
end

local MIRV_COOLDOWN_TICKS = 300 -- NationMIRVBehavior.ts:23-24

-- NationMIRVBehavior.considerMIRV (:118-153), keeping counter-MIRV and victory
-- denial. Steamroll-stop collapses into the same share test, because Conquest
-- has no per-player city count on the AI's side of the wire yet.
local function considerMirv(sim: any, p: any): boolean
	if Units.count(sim, p.id, Units.MISSILE_SILO) == 0 then
		return false
	end
	if p.gold < Units.cost(sim, p.id, Units.MIRV) then
		return false
	end
	local s = aiState(p)
	if sim.tick - s.lastMirvTick < MIRV_COOLDOWN_TICKS then
		return false
	end

	local land = Nukes.contestableLand(sim)
	local target: any = nil

	for _, mirv in Units.ofType(sim, Units.MIRV) do
		if mirv.active and mirv.ownerId ~= p.id and mirv.targetTile ~= nil then
			if buffer.readu8(sim.map.owner, mirv.targetTile) == p.id then
				-- A PERSON'S MIRV GOES UNANSWERED: the counter-MIRV is a
				-- retaliation AT ITS OWNER, and that is the one empire a bot may
				-- not fire at, so the salvo is simply taken. The loop keeps looking
				-- -- another carrier may be inbound, and that one is answerable.
				local mirvOwner = sim.players[mirv.ownerId]
				if nukeable(sim, p, mirvOwner) then
					target = mirvOwner
					break
				end
			end
		end
	end

	if target == nil then
		local bestShare = 0.55
		for _, id in sim.playerOrder do
			local o = sim.players[id]
			if nukeable(sim, p, o) then
				local share = o.tileCount / land
				if share > bestShare then
					bestShare = share
					target = o
				end
			end
		end
	end

	if target == nil then
		return false
	end
	local centre = Nukes.territoryCenter(sim, target)
	if centre == nil then
		return false
	end
	local ok = Nukes.launchMirv(sim, p.id, centre)
	if ok then
		s.lastMirvTick = sim.tick
	end
	return ok
end

-- The AI entry point. Call from the nation tier's think at whatever cadence
-- Sim already uses; it is cheap when the nation cannot afford anything.
function Nukes.aiThink(sim: any, p: any)
	if not p.alive or not p.spawned then
		return
	end
	-- READY, not merely OWNED. Units.count returns silo LEVELS and ignores
	-- active / underConstruction / cooldown, while nukeSpawn requires a silo
	-- that can actually fire right now. The mismatch was not cosmetic: an AI
	-- whose only silo was still building, or on cooldown from its own last
	-- launch, passed this gate and then priced ~45 candidate aimpoints, every
	-- one of which fell through nukeSpawn into the silo-free branch and paid
	-- a full 484,000-tile sweep of the owner buffer. Measured at 1,175 ms in
	-- ONE tick -- and it is exactly the case the comment beside that branch
	-- claimed could never happen.
	-- Cheap test first. Units.count is an O(1) stat lookup and hasReadySilo
	-- walks every silo on the map, and the overwhelming majority of nations
	-- own none at all -- so the count keeps its job as the early-out and the
	-- readiness scan only runs for a nation that actually has one.
	if Units.count(sim, p.id, Units.MISSILE_SILO) == 0 then
		return
	end
	if not hasReadySilo(sim, p.id) then
		return
	end
	if considerMirv(sim, p) then
		return
	end

	local target = findNukeTarget(sim, p)
	if target == nil then
		return
	end

	local utype: number
	if p.gold >= perceivedCost(sim, p, Units.HYDROGEN_BOMB) then
		utype = Units.HYDROGEN_BOMB
	-- A WARHEAD IN HAND IS AFFORDABLE (NUCLEAR WAR, 2026-09-18: Modes.SPECIAL
	-- startNukes puts ten atom bombs on every empire, bots included). Priced
	-- at gold it does not have, a bot would carry them to its grave. The order
	-- and the charge spend the token before any gold (see nukeTick), so this
	-- line only lets the AI ASK; the silo gate above still stands, because the
	-- silo-free branch of nukeSpawn is the 484,000-tile sweep noted there.
	elseif p.gold >= perceivedCost(sim, p, Units.ATOM_BOMB) or (p.freeNukes or 0) > 0 then
		utype = Units.ATOM_BOMB
	else
		return
	end

	local s = aiState(p)
	local cutoff = sim.tick - 600 -- NationNukeBehavior.ts:490-499
	local kept = {}
	for _, r in s.recent do
		if r.tick >= cutoff then
			kept[#kept + 1] = r
		end
	end
	s.recent = kept

	-- Candidate aimpoints: the target's structures, its centre, and a thin
	-- sample of its border (NationNukeBehavior.ts:102-113).
	local candidates: { number } = {}
	for _, u in Units.ofPlayer(sim, target.id) do
		if u.active and Units.isStructure(u.utype) then
			candidates[#candidates + 1] = u.tile
		end
	end
	if sim.structList ~= nil then
		for _, st in sim.structList do
			if st.ownerId == target.id then
				candidates[#candidates + 1] = st.tile
			end
		end
	end
	local centre = Nukes.territoryCenter(sim, target)
	if centre ~= nil then
		candidates[#candidates + 1] = centre
	end
	local sampled = 0
	for tile in target.border do
		sampled += 1
		if sampled % 7 == 0 then
			candidates[#candidates + 1] = tile
		end
		if sampled > 210 then
			break
		end
	end
	if #candidates == 0 then
		return
	end

	local bestTile: number? = nil
	local bestValue = -1
	local seen: { [number]: boolean } = {}
	-- Discs spent on the person check, capped -- see PERSON_SCAN_BUDGET. Running
	-- out refuses later candidates rather than trusting them, which costs a bot
	-- a better aimpoint and never costs a player a city.
	local scans = 0
	local blastMag = CFG.MAGNITUDE[utype]
	for _, tile in candidates do
		if not seen[tile] then
			seen[tile] = true
			local spawn = Nukes.nukeSpawn(sim, p.id, utype, tile)
			if spawn ~= false then
				if not Nukes.trajectoryInterceptable(sim, p.id, spawn :: number, tile) then
					local value = nukeTileScore(sim, p, tile, utype, s.recent)
					-- THE PERSON CHECK IS THE LAST GATE ON PURPOSE. It is the only
					-- one that can read a disc of the owner buffer, and asking it
					-- only of a tile that would actually become the shot keeps it
					-- off all but a handful of candidates.
					if value > bestValue and scans < PERSON_SCAN_BUDGET then
						scans += 1
						if not blastTouchesPerson(sim, tile, blastMag.outer) then
							bestValue = value
							bestTile = tile
						end
					end
				end
			end
		end
	end

	if bestTile ~= nil then
		local ok = Nukes.launchNuke(sim, p.id, utype, bestTile)
		if ok then
			s.recent[#s.recent + 1] = { tick = sim.tick, tile = bestTile, utype = utype }
			if utype == Units.ATOM_BOMB then
				s.atomCost = (s.atomCost or Units.cost(sim, p.id, utype)) * 1.5
			else
				s.hydroCost = (s.hydroCost or Units.cost(sim, p.id, utype)) * 1.25
			end
		end
	end
end

-- ============================================================ client replay ==
--
-- Given a launch event, where is that missile now? Index == ticks since
-- launch, after the wait, because the curve is sampled at exactly the speed it
-- is stepped at. Returns nil once the flight is over.
--
-- ev.tick is the tick the missile was SPAWNED, sitting on its source tile; it
-- sits there for ev.wait more ticks and first moves on tick + wait + 1, which
-- is curve index 1. So index 0 lands on tick + wait, and that is startTick.
-- Verified against the server's own stepping: 58 of 58 indices agree.

function Nukes.flight(ev: any): any
	local c = Nukes.arc(ev.src, ev.dst, ev.speed, ev.up ~= false)
	return {
		id = ev.id,
		kind = ev.kind,
		owner = ev.owner,
		curve = c,
		startTick = ev.tick + (ev.wait or 0),
		count = #c.px,
	}
end

function Nukes.flightPosition(flight: any, tick: number): (number?, number?)
	local i = tick - flight.startTick
	if i < 0 then
		i = 0
	end
	if i >= flight.count - 1 then
		return nil, nil
	end
	return flight.curve.px[i + 1], flight.curve.py[i + 1]
end

return Nukes
