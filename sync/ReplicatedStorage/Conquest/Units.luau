--!strict
-- Conquest :: Units  (shared)
--
-- ONE record for every structure, boat, missile and warhead in the game.
-- Ported from upstream (github.com/openfrontio/OpenFrontIO): the Unit
-- interface in src/core/game/Game.ts:471-564, its implementation in
-- src/core/game/UnitImpl.ts, the id map and spatial grid in
-- src/core/game/GameImpl.ts:104-105 + src/core/game/UnitGrid.ts, the
-- per-player list and counters in src/core/game/PlayerImpl.ts, and the
-- cost/duration table in src/core/configuration/Config.ts:447-588.
--
-- WHY THIS MODULE EXISTS. Upstream models City, Port, DefensePost,
-- MissileSilo, SAMLauncher, Factory, Warship, TransportShip, TradeShip,
-- Train, AtomBomb, HydrogenBomb, MIRV, MIRVWarhead, Shell and SAMMissile as
-- ONE type, and every rule it has -- capture on territory change,
-- construction timers, upgrade levels, deletion cooldowns, nearbyUnits,
-- unitCount, veterancy -- is written against that one type. Conquest instead
-- has four disjoint bespoke records (Economy.Structure, Sim.TransportBoat, and the
-- anonymous boat and train literals) across three id spaces, and only
-- structures are spatially indexed -- inside a fixed 3x3 block of 16-tile
-- cells (Economy.nearby), which is correct ONLY for radii <= 15. A defense
-- post needs 30, a gunboat 130, a SAM 600. Nothing above can be ported 1:1
-- until those live in one table with one index.
--
-- THIS FILE IS INERT. Nothing requires it yet. Step 0 of the migration is
-- "the module exists and is correct"; wiring Units.init into Sim.new, and
-- every dual-write into Economy, are later, separately-landed steps.
--
-- THREE DELIBERATE DEPARTURES FROM UPSTREAM, all measured against Luau
-- rather than against V8:
--
--   * utype is a NUMBER, not a string. Upstream's UnitType is a string enum
--     (Game.ts:193-210), which costs a string hash on every grid bucket
--     lookup and every type comparison. Conquest already numbers its kinds
--     (Economy.CITY = 1, Economy.PORT = 2) and puts them on the wire as a
--     byte, so the numbering here EXTENDS that one -- CITY and PORT keep
--     their existing values and the wire does not move.
--
--   * There is no lastTile. Upstream tracks it purely so UnitGrid.
--     updateUnitCell (UnitGrid.ts:67-82) can work out which cell to remove
--     from. Caching cellKey on the record does the same job for less.
--
--   * Cell buckets are ARRAYS with swap-remove, not Sets. Upstream deletes
--     from a JS Set in O(1) (UnitGrid.ts:59); Luau has no such thing, and
--     table.find + table.remove in the hot path is the trap. The bucket
--     index lives on the record so removal is O(1) too.

local Config = require(script.Parent.Config)
local TileMap = require(script.Parent.TileMap)

local W = Config.MAP_W
local H = Config.MAP_H

local Units = {}

-- ================================================================= types ==
--
-- CITY and PORT MUST keep the values Economy already uses (Economy.CITY = 1,
-- Economy.PORT = 2) -- they are the `kind` byte in the structure event
-- stream and the client switches on them in Structures.set. Everything else
-- is new and appended.
--
-- The ordering is not arbitrary. The six STRUCTURE types are 1..6 and
-- contiguous, so the territory-capture guard is an integer compare rather
-- than upstream's set membership test (Structures.has, Game.ts:232-239) --
-- and that guard runs once per unit per tick for every player alive. The
-- five NUKE types are 13..17 and contiguous for the same reason.

Units.CITY = 1
Units.PORT = 2
Units.DEFENSE_POST = 3
Units.MISSILE_SILO = 4
Units.SAM_LAUNCHER = 5
Units.FACTORY = 6

Units.TRANSPORT_BOAT = 7
Units.GUNBOAT = 8
Units.TRADING_BOAT = 9
Units.TRAIN = 10
Units.SHELL = 11
Units.SAM_MISSILE = 12

Units.ATOM_BOMB = 13
Units.HYDROGEN_BOMB = 14
Units.MIRV = 15
Units.MIRV_WARHEAD = 16

-- NOT UPSTREAM. Owner's call 2026-09-17: an atom bomb with twice the reach,
-- appended so the four ported ids keep the numbers upstream gave them.
-- Everything the nuclear layer does with it is table-driven off the utype
-- (Nukes.CFG.MAGNITUDE and CFG.SPEED, Units.INFO below), so being the fifth
-- nuke rather than one of upstream's four costs no branching anywhere.
Units.MEGA_NUKE = 17

-- NOT UPSTREAM. Two more buildings (owner, 2026-09-21): an artillery battery
-- that shells enemies inside its ring on its own, and an airfield the owner
-- taps to send a bomber at a tile inside its (larger) ring. Appended after the
-- warheads so no shipped id moves; the STRUCTURE group is therefore no longer
-- contiguous, and Units.isStructure / STRUCTURE_TYPES below are the only two
-- places that know which ids are buildings. Everything else asks them.
Units.ARTILLERY = 18
Units.AIRFIELD = 19

-- NOT UPSTREAM. The two late-game weapons (owner, 2026-09-24), appended so no
-- shipped id moves: SCATTERSHOT is a WARHEAD (a main bomb that brings 4-6
-- MIRV warheads with it, Nukes.launchScattershot) and RAILGUN a BUILDING
-- (Conquest.Railgun). Neither group is contiguous any more, so isNuke is a set
-- lookup like isStructure.
Units.SCATTERSHOT = 20
Units.RAILGUN = 21

Units.TYPE_COUNT = 21

-- Upstream `Structures` (Game.ts:232-239) = City, DefensePost, SAMLauncher,
-- MissileSilo, Port, Factory. It is the group that carries the
-- territory-bound rule (PlayerExecution.ts:48-50) and the nuke blast and
-- alliance checks (execution/Util.ts:63, :122).
Units.STRUCTURE_LAST = 6
-- Upstream `Nukes` (Game.ts:218-223) = AtomBomb, HydrogenBomb, MIRVWarhead,
-- MIRV.
Units.NUKE_FIRST = 13
Units.NUKE_LAST = 20

-- The same six as an ARRAY, for the multi-type grid queries that upstream
-- writes as `Structures.types` (PlayerImpl.ts:1548, :1635,
-- execution/Util.ts:63, :122). Shared, never mutated -- building it per
-- call would allocate on the build-click path.
Units.STRUCTURE_TYPES = { 1, 2, 3, 4, 5, 6, 18, 19, 21 }
Units.NUKE_TYPES = { 13, 14, 15, 16, 17, 20 }

-- The same set as a LOOKUP, for the per-unit test. `utype <= STRUCTURE_LAST`
-- was the test until the artillery and the airfield were appended past the
-- warheads; a table index is the same cost and does not care where the ids sit.
local STRUCTURE_SET: { [number]: boolean } = {}
for _, t in Units.STRUCTURE_TYPES do
	STRUCTURE_SET[t] = true
end
Units.STRUCTURE_SET = STRUCTURE_SET
local NUKE_SET: { [number]: boolean } = {}
for _, t in Units.NUKE_TYPES do
	NUKE_SET[t] = true
end

-- Buildings the ground under them DESTROYS rather than hands over when it
-- changes hands (upstream's rule for the defense post, PlayerExecution.ts:
-- 62-64, extended to the two guns: a captured battery or airfield would be a
-- weapon handed to the enemy that took the field it stands on).
Units.RAZED_ON_CAPTURE = { [Units.DEFENSE_POST] = true, [Units.ARTILLERY] = true, [Units.AIRFIELD] = true, [Units.RAILGUN] = true }

-- Shared "match anything" predicate for anyNearby, so the callers that only
-- want an existence test do not allocate a closure each time.
local ALWAYS_TRUE = function(_u: any): boolean
	return true
end

function Units.isStructure(utype: number): boolean
	return STRUCTURE_SET[utype] == true
end

function Units.isNuke(utype: number): boolean
	return NUKE_SET[utype] == true
end

-- A unit. Every field is present on every record so Luau assigns one hidden
-- shape and never rehashes -- 400 warheads in flight during an MIRV salvo
-- are 400 identically-shaped tables.
--
-- Per-TYPE behaviour state lives in `ext`, not here: rails, cluster and
-- tradeRejections for a station; path, pathIdx and dst for a trading boat; patrol
-- and retreat state for a gunboat; trainType and loaded for a train.
-- Upstream keeps those in optional sub-objects allocated by duck-typing the
-- construction params (UnitImpl.ts:66-102); one nested table is the same
-- idea with less branching. veterancy is the exception and sits on the
-- common record, because Units.maxHealth reads it for every unit.
export type Unit = {
	id: number,
	utype: number,
	ownerId: number, -- 0 = nobody
	tile: number,
	level: number,
	active: boolean,

	underConstruction: boolean,
	buildDoneTick: number, -- -1 when not building
	deletionAt: number, -- -1 when not marked for deletion

	health: number,
	troops: number,

	targetTile: number?,
	targetUnitId: number?,
	targetPlayerId: number?,
	trajectory: { number }?,
	trajectoryIndex: number,
	targetedBySam: boolean,
	targetable: boolean,
	reachedTarget: boolean,

	-- Launch ticks, one per missile in flight. #missileTimers == level means
	-- every tube is spent (UnitImpl.isInCooldown, UnitImpl.ts:528-530).
	missileTimers: { number },

	veterancy: number,
	veterancyProgress: number,
	hasTrainStation: boolean,

	-- Index positions, so every removal is a swap rather than a search.
	cellKey: number,
	cellIdx: number,
	typeIdx: number,
	ownerIdx: number,
	buildIdx: number,

	ext: { [string]: any }?,
}

-- ========================================================== unit info ======
--
-- Upstream Config.unitInfo (Config.ts:447-588), memoised per type
-- (Config.ts:210, :586). UnitInfo has exactly five fields there
-- (Game.ts:174-182): cost, maxHealth, damage, constructionDuration,
-- upgradable. There is no territoryBound and no maxLevel in the upstream
-- checkout this was ported from -- both were checked with grep over src/
-- and tests/ and neither exists. Territory binding is the hardcoded
-- Structures.has() guard in PlayerExecution.ts:48-50, and level is uncapped
-- (UnitImpl.increaseLevel, :699-715, has no ceiling).
--
-- Conquest DOES cap level, at Config.STRUCTURE_MAX_LEVEL, and that cap is
-- enforced today inside Economy.canBuild:602. It is carried here as
-- `maxLevel` on the entries that Conquest already caps, so the check can
-- move to Units.canUpgrade without changing behaviour. Types upstream never
-- caps leave it nil.
--
-- WHERE THE NUMBERS COME FROM. City and Port read Conquest.Config, which is
-- authoritative for them today and which Economy.cost already uses -- this
-- module must not quietly reprice anything that already ships. The types
-- Conquest has not built yet carry upstream's literals with the Config.ts
-- line beside them; they belong in Conquest.Config once those systems land,
-- and are here only so this module is self-contained and inert.

local TICK = Config.TICK_RATE -- 10 ticks per second, as upstream (Config.ts:304-306)

-- Config.ts:148 -- SAM_CONSTRUCTION_TICKS = 30 * 10, which Conquest no longer
-- runs: the tower raises in TEN seconds (owner, 2026-09-15, "200% faster").
-- The number lives in Conquest.Config beside the other build times, which is
-- where the build path reads it; the upstream literal stays as the fallback so
-- this module still answers correctly against an older Config -- the same shape
-- DEFENSE_POST_BUILD_TICKS and FACTORY_BUILD_TICKS below already take.
local SAM_BUILD_TICKS = Config.SAM_BUILD_TICKS or 30 * TICK
-- Config.ts:528 -- missile silo is 10 * 10.
local SILO_BUILD_TICKS = 10 * TICK
-- Config.ts:538 -- defense post is 5 * 10, the same as a port. The number now
-- lives in Conquest.Config beside CITY_BUILD_TICKS and PORT_BUILD_TICKS, which
-- is where the build path reads it; the literal stays as the fallback so this
-- module still answers correctly against an older Config.
local DEFENSE_POST_BUILD_TICKS = Config.DEFENSE_POST_BUILD_TICKS or 5 * TICK
-- Config.ts:573 -- a factory builds as fast as a city.
local FACTORY_BUILD_TICKS = Config.FACTORY_BUILD_TICKS or Config.CITY_BUILD_TICKS

-- Config.ts:671-673 deletionMarkDuration and :675-677 deleteUnitCooldown.
-- Deleting a unit ARMS a 30 second timer; it is not an instant delete
-- (UnitImpl.markForDeletion, :306-313).
Units.DELETION_MARK_TICKS = 30 * TICK
Units.DELETE_UNIT_COOLDOWN = 30 * TICK

-- Config.ts:1130-1153. Warship veterancy only.
Units.MAX_VETERANCY = 3
Units.VETERANCY_HEALTH_BONUS = 20 -- integer percent of base max health, per level
Units.VETERANCY_TRANSPORT_KILLS = 10
Units.VETERANCY_TRADE_CAPTURES = 25

-- Config.ts:1081-1083 structureMinDist. Also the radius findUnitToUpgrade
-- searches for something to upgrade instead of building (PlayerImpl.ts:
-- 1328-1339), which is why the two rules can never contradict.
Units.STRUCTURE_MIN_DIST = Config.STRUCTURE_MIN_DIST

local function flat(v: number)
	return function(_n: number, _sim: any): number
		return v
	end
end

-- Upstream's two cost shapes, named so the table below reads as the table
-- upstream is: a doubling curve with a cap (city, port, factory) and a
-- linear-with-cap curve (gunboat, defense post, SAM).
local function doubling(base: number, growth: number, cap: number)
	return function(n: number, _sim: any): number
		return math.min(cap, growth ^ n * base)
	end
end

local function linear(step: number, cap: number)
	return function(n: number, _sim: any): number
		return math.min(cap, (n + 1) * step)
	end
end

export type Info = {
	costFn: (number, any) -> number,
	costPool: { number }?,
	maxHealth: number?,
	damage: number?,
	buildTicks: number?,
	upgradable: boolean?,
	maxLevel: number?,
}

Units.INFO = {} :: { [number]: Info }

-- Config.ts:554-564. Pool is City alone.
Units.INFO[Units.CITY] = {
	costFn = doubling(Config.CITY_COST_BASE, Config.CITY_COST_GROWTH, Config.CITY_COST_CAP),
	costPool = { Units.CITY },
	buildTicks = Config.CITY_BUILD_TICKS,
	upgradable = true,
	maxLevel = Config.STRUCTURE_MAX_LEVEL,
	-- HIT POINTS (2026-09-21). Nothing chipped at a building before the
	-- artillery and the airfield; a nuke deletes outright. Read by
	-- Units.damageStructure only -- maxHealth 1 was the default and nothing
	-- else compares a building's health to anything.
	maxHealth = Config.STRUCTURE_HEALTH or 1000,
}

-- Config.ts:480-491. Port and Factory SHARE a cost pool -- each counts the
-- other (Config.ts:482-487 lists Port then Factory, :567-572 the reverse),
-- so building a factory raises the price of your next port. Factory does
-- not exist in Conquest yet, which makes its contribution zero and this
-- line harmless until it does.
Units.INFO[Units.PORT] = {
	costFn = doubling(Config.PORT_COST_BASE, Config.PORT_COST_GROWTH, Config.PORT_COST_CAP),
	costPool = { Units.PORT, Units.FACTORY },
	buildTicks = Config.PORT_BUILD_TICKS,
	upgradable = true,
	maxLevel = Config.STRUCTURE_MAX_LEVEL,
	maxHealth = Config.STRUCTURE_HEALTH or 1000,
}

-- Config.ts:565-576. Shares the PORT ladder both ways -- see Config's factory
-- block and Economy.cost, which is the function the build path actually reads.
Units.INFO[Units.FACTORY] = {
	costFn = doubling(Config.FACTORY_COST_BASE or 125000,
		Config.FACTORY_COST_GROWTH or 2, Config.FACTORY_COST_CAP or 1000000),
	costPool = { Units.FACTORY, Units.PORT },
	buildTicks = FACTORY_BUILD_TICKS,
	upgradable = true,
	maxLevel = Config.STRUCTURE_MAX_LEVEL,
	maxHealth = Config.STRUCTURE_HEALTH or 1000,
}

-- Config.ts:532-540. NOT upgradable, and the only structure that is razed
-- rather than captured when its ground changes hands
-- (PlayerExecution.ts:62-64).
Units.INFO[Units.DEFENSE_POST] = {
	costFn = linear(
		Config.DEFENSE_POST_COST_STEP or 50000,
		Config.DEFENSE_POST_COST_CAP or 250000
	),
	costPool = { Units.DEFENSE_POST },
	buildTicks = DEFENSE_POST_BUILD_TICKS,
	maxHealth = Config.DEFENSE_POST_HEALTH or 600,
}

-- NOT UPSTREAM (owner, 2026-09-21). Both guns climb a LINEAR ladder of their
-- own, like the post, priced in Config. Neither is upgradable and both are razed
-- rather than captured (Units.RAZED_ON_CAPTURE). `maxHealth` is what artillery
-- shells and bombs chip at -- see Config.STRUCTURE_HEALTH and Units.damageStructure.
Units.INFO[Units.ARTILLERY] = {
	costFn = linear(Config.ARTILLERY_COST_STEP or 150000, Config.ARTILLERY_COST_CAP or 750000),
	costPool = { Units.ARTILLERY },
	buildTicks = Config.ARTILLERY_BUILD_TICKS or 80,
	maxHealth = Config.ARTILLERY_HEALTH or 600,
}
Units.INFO[Units.AIRFIELD] = {
	costFn = linear(Config.AIRFIELD_COST_STEP or 500000, Config.AIRFIELD_COST_CAP or 1500000),
	costPool = { Units.AIRFIELD },
	buildTicks = Config.AIRFIELD_BUILD_TICKS or 100,
	maxHealth = Config.AIRFIELD_HEALTH or 800,
}
-- THE RAILGUN (2026-09-24): the airfield's shape -- one shot, then a rearm on
-- missileTimers -- on a steeper linear ladder. See Config's late-game block.
Units.INFO[Units.RAILGUN] = {
	costFn = linear(Config.RAILGUN_COST_STEP or 2500000, Config.RAILGUN_COST_CAP or 7500000),
	costPool = { Units.RAILGUN },
	buildTicks = Config.RAILGUN_BUILD_TICKS or 150,
	maxHealth = Config.RAILGUN_HEALTH or 1000,
}

-- Config.ts:525-531. Flat price, upgradable; each level is another tube
-- (UnitImpl.increaseLevel, :711-713).
Units.INFO[Units.MISSILE_SILO] = {
	costFn = flat(1000000),
	costPool = { Units.MISSILE_SILO },
	buildTicks = SILO_BUILD_TICKS,
	upgradable = true,
	maxHealth = Config.STRUCTURE_HEALTH or 1000,
}

-- Config.ts:541-553.
Units.INFO[Units.SAM_LAUNCHER] = {
	-- min(CAP, (n + 1) * STEP) with the FIRST rung its own number -- see the
	-- SAM_COST block in Config. Fallbacks are upstream's 1.5M / 3M.
	costFn = function(n: number, _sim: any): number
		if n <= 0 then
			return Config.SAM_COST_FIRST or 1500000
		end
		return math.min(Config.SAM_COST_CAP or 3000000, (n + 1) * (Config.SAM_COST_STEP or 1500000))
	end,
	costPool = { Units.SAM_LAUNCHER },
	buildTicks = SAM_BUILD_TICKS,
	upgradable = true,
	maxHealth = Config.STRUCTURE_HEALTH or 1000,
}

-- Config.ts:460-468. No construction timer: a gunboat is not a structure,
-- so ConstructionExecution charges once and hands off immediately
-- (ConstructionExecution.ts:50-56).
Units.INFO[Units.GUNBOAT] = {
	costFn = linear(250000, 1000000),
	costPool = { Units.GUNBOAT },
	maxHealth = 1000,
}

Units.INFO[Units.TRANSPORT_BOAT] = { costFn = flat(0) } -- Config.ts:455-459
Units.INFO[Units.TRADING_BOAT] = { costFn = flat(0) } -- Config.ts:520-524
Units.INFO[Units.TRAIN] = { costFn = flat(0) } -- Config.ts:577-581
Units.INFO[Units.SHELL] = { costFn = flat(0), damage = 250 } -- Config.ts:469-474
Units.INFO[Units.SAM_MISSILE] = { costFn = flat(0) } -- Config.ts:475-479

Units.INFO[Units.ATOM_BOMB] = { costFn = flat(Config.ATOM_BOMB_COST or 750000), costPool = { Units.ATOM_BOMB } } -- Config.ts:492-496
Units.INFO[Units.HYDROGEN_BOMB] = { costFn = flat(5000000), costPool = { Units.HYDROGEN_BOMB } } -- Config.ts:497-501

-- No upstream line to cite: see Config.MEGA_NUKE_COST for where the number
-- comes from. Flat, like both bombs it sits between, and priced in Config for
-- the same reason the atom bomb is -- whatever ends up pricing the button must
-- not carry a second copy of it.
Units.INFO[Units.MEGA_NUKE] = { costFn = flat(Config.MEGA_NUKE_COST or 2500000), costPool = { Units.MEGA_NUKE } }
-- The scattershot's main warhead carries the whole price; the MIRV warheads it
-- brings are free (their INFO below), as a MIRV's are.
Units.INFO[Units.SCATTERSHOT] = { costFn = flat(Config.SCATTERSHOT_COST or 3750000), costPool = { Units.SCATTERSHOT } }

-- Config.ts:502-514. The only cost that scales with a GLOBAL counter rather
-- than with what the buyer owns: every MIRV ever launched makes the next
-- one dearer for everybody. sim.mirvsLaunched does not exist yet; reading
-- it defensively keeps this inert.
Units.INFO[Units.MIRV] = {
	costFn = function(_n: number, sim: any): number
		return 25000000 + (sim and sim.mirvsLaunched or 0) * 15000000
	end,
}
Units.INFO[Units.MIRV_WARHEAD] = { costFn = flat(0) } -- Config.ts:515-519

function Units.info(utype: number): Info?
	return Units.INFO[utype]
end

-- ============================================================== geometry ==

local function tx(tile: number): number
	return tile % W
end

local function ty(tile: number): number
	return (tile - tile % W) / W
end

Units.tx = tx
Units.ty = ty

-- CELL SIZE. Upstream uses 100 (UnitGrid.ts:12). 32 here, and the reason is
-- the query that runs most: structure spacing at radius 15
-- (PlayerImpl.ts:1632-1638, and Economy.canBuild today). At 100 that query
-- scans up to four 100x100 blocks -- every unit in 40,000 tiles. At 32 it
-- touches at most 2x2 cells covering 64x64 tiles, and STRUCTURE_MIN_DIST
-- bounds that box to roughly sixteen structures.
--
-- 1600x1000 / 32 = 50 x 32 = 1600 cells. Query cost, per radius:
--   R=15  structure spacing        <= 4 cells
--   R=30  defense post (attack loop) <= 9 cells
--   R=110 train station            <= 64 cells
--   R=130 gunboat targeting        <= 81 cells
--   R=600 SAM detection            the whole grid
-- The SAM figure is the one to design against -- see Units.nearby.
local CELL = 32
local CW = math.ceil(W / CELL)
local CH = math.ceil(H / CELL)

Units.CELL = CELL
Units.GRID_W = CW
Units.GRID_H = CH

local function cellOf(tile: number): number
	local x = tile % W
	local y = (tile - x) / W
	return (y // CELL) * CW + (x // CELL)
end

Units.cellOf = cellOf

-- =============================================================== storage ==

-- Called once from Sim.new. Safe to call twice: it only fills in what is
-- missing, so a hot-reload during development does not wipe a live round.
function Units.init(sim: any)
	sim.units = sim.units or {} :: { [number]: Unit }
	sim.unitsByType = sim.unitsByType or {} :: { [number]: { Unit } }
	sim.unitsByPlayer = sim.unitsByPlayer or {} :: { [number]: { Unit } }
	sim.unitCells = sim.unitCells or {} :: { [number]: { [number]: { Unit } } }
	sim.unitStats = sim.unitStats or {} :: { [number]: { [number]: any } }
	sim.buildingUnits = sim.buildingUnits or {} :: { Unit }
	sim.unitEvents = sim.unitEvents or {} :: { any }
	sim.nextUnitId = sim.nextUnitId or 1

	for t = 1, Units.TYPE_COUNT do
		if sim.unitsByType[t] == nil then
			sim.unitsByType[t] = {}
		end
	end
end

-- Swap-remove with the index carried on the record. The `list[i] ~= u`
-- fallback is insurance, not the normal path: if an index ever went stale
-- the silent failure mode is corrupting somebody else's slot, which is far
-- worse than one linear scan.
local function listAdd(list: { any }, u: any, field: string)
	local n = #list + 1
	list[n] = u
	u[field] = n
end

local function listRemove(list: { any }, u: any, field: string)
	local i = u[field]
	if i == nil or i == 0 then
		return
	end
	if list[i] ~= u then
		i = table.find(list, u)
		if i == nil then
			u[field] = 0
			return
		end
	end
	local n = #list
	local last = list[n]
	list[i] = last
	last[field] = i
	list[n] = nil
	u[field] = 0
end

-- ------------------------------------------------------------ counters ---
--
-- Upstream recomputes these by walking the player's whole unit array every
-- time (PlayerImpl.unitCount :474-482, unitsOwned :485-497). Keeping them
-- incrementally is one of the few places the port can beat upstream for
-- free, and it matters: Units.cost calls them and the build menu calls
-- Units.cost for every buildable type, every time it opens.
--
-- Four numbers per (player, type):
--   n       structures of this type owned
--   levels  sum of their levels           == upstream unitCount / unitsOwned
--   uc      how many are under construction
--   built   construct events paid for     == upstream unitsConstructed
--
-- unitCount and unitsOwned are the same number in this build and share one
-- field. Upstream distinguishes them (levels vs "under construction counts
-- as 1"), but an under-construction unit is always level 1 -- upgrades are
-- refused while a unit is building (PlayerImpl.ts:1364-1366) -- so the two
-- can never disagree.
--
-- COMPLETED levels are levels - uc, again because every under-construction
-- unit is level 1. That is the number Config.maxTroops wants, since it
-- filters out under-construction cities (Config.ts:919-924), and it is what
-- Conquest's p.cityLevels holds today (Economy adds a structure only on
-- completion, Economy:673-675).

local function statOf(sim: any, playerId: number, utype: number): any
	local byPlayer = sim.unitStats[playerId]
	if byPlayer == nil then
		byPlayer = {}
		sim.unitStats[playerId] = byPlayer
	end
	local s = byPlayer[utype]
	if s == nil then
		s = { n = 0, levels = 0, uc = 0, built = 0 }
		byPlayer[utype] = s
	end
	return s
end

Units.stats = statOf

-- Upstream unitCount (PlayerImpl.ts:474-482) and unitsOwned (:485-497).
function Units.count(sim: any, playerId: number, utype: number): number
	return statOf(sim, playerId, utype).levels
end

Units.owned = Units.count

-- Upstream unitsConstructed (PlayerImpl.ts:469-471). Counts every build AND
-- every upgrade, and is never decremented -- losing a city does not refund
-- the fact that you paid for one.
function Units.constructed(sim: any, playerId: number, utype: number): number
	return statOf(sim, playerId, utype).built
end

-- Number of separate units, ignoring level. Upstream has no such call; it
-- is here because Economy.cost's basis is the STRUCTURE COUNT
-- (p.cityCount, Economy:157) rather than the sum of levels, so a
-- Conquest-compatible cost wrapper needs it. See Units.cost.
function Units.structureCount(sim: any, playerId: number, utype: number): number
	return statOf(sim, playerId, utype).n
end

-- Number of COMPLETED separate units, ignoring level: `n - uc`, the count twin
-- of levelSum. This is what "how many ports do you have" means anywhere a
-- harbour has to be FINISHED to do its job -- both fleet ceilings read it
-- (Gunboats.fleetCap, Economy.tradeFleetCap), and neither may count a port
-- that is still going up, because gold spent is not a harbour.
function Units.completedCount(sim: any, playerId: number, utype: number): number
	local s = statOf(sim, playerId, utype)
	return s.n - s.uc
end

-- Sum of the levels of COMPLETED units. Replaces p.cityLevels, which
-- Sim.maxTroops (Sim:767) adds to the troop ceiling.
function Units.levelSum(sim: any, playerId: number, utype: number): number
	local s = statOf(sim, playerId, utype)
	return s.levels - s.uc
end

-- The four legacy per-kind fields on Conquest's Player -- cityCount,
-- cityLevels, portCount, portLevels -- are a MIRROR of these counters from
-- here, rewritten on every mutation for the price of two stores. They cannot
-- simply be deleted: Sim.maxTroops reads p.cityLevels and ConquestServer puts
-- p.cityCount, p.portCount and p.cityLevels on the wire, and neither of those
-- is this module's to change. One writer, and it is the one the capture sweep
-- already goes through, replaces the five hand-maintained call sites Economy
-- had.
--
-- COMPLETED ONLY (n - uc, levels - uc), and that is deliberate. Upstream's
-- unitCount counts an under-construction unit; Conquest's cost curve does
-- not, and Economy.cost reads this mirror. Counting sites here would double
-- the price of a second city queued while the first is still going up, which
-- is a balance change and not a port. See the note on Units.cost.
local MIRROR: { [number]: { count: string, level: string } } = {
	[1] = { count = "cityCount", level = "cityLevels" },
	[2] = { count = "portCount", level = "portLevels" },
	-- Economy.cost is called as (player, kind) with no sim, so the factory
	-- needs the same mirror the other two have. factoryLevels is written for
	-- symmetry and is not read by anything -- the train rate reads
	-- Units.count, which is this counter's source.
	[6] = { count = "factoryCount", level = "factoryLevels" },
	-- A DEFENSE POST IS PRICED OFF THE MIRROR TOO, for the reason stated over
	-- COUNT_FIELD: the build reply in ConquestServer calls
	-- Sim.structureCost(p, kind) with a PLAYER and no sim, so the ladder has to
	-- be readable off the player. A post is never upgradable, so count and
	-- level are the same number here and defensePostLevels exists only so the
	-- mirror keeps one shape.
	[3] = { count = "defensePostCount", level = "defensePostLevels" },
	-- A SAM LAUNCHER IS PRICED OFF THE MIRROR TOO, for the reason stated over
	-- COUNT_FIELD, and it is the first non-station structure a PLAYER can buy
	-- that also UPGRADES -- a launcher's radius grows with its level
	-- (Nukes.samRange) -- so unlike a post these two are genuinely different
	-- numbers and both are read.
	[5] = { count = "samCount", level = "samLevels" },
	-- The two guns (2026-09-21), priced off the mirror for the reason the post
	-- is. Neither upgrades, so count and levels are the same number.
	[18] = { count = "artilleryCount", level = "artilleryLevels" },
	[19] = { count = "airfieldCount", level = "airfieldLevels" },
	[21] = { count = "railgunCount", level = "railgunLevels" },
}

local function statAdd(sim: any, playerId: number, utype: number, n: number, levels: number, uc: number)
	if playerId == 0 then
		return
	end
	local s = statOf(sim, playerId, utype)
	s.n += n
	s.levels += levels
	s.uc += uc
	local m = MIRROR[utype]
	if m ~= nil then
		local p = sim.players[playerId]
		if p ~= nil then
			local cf, lf = m.count, m.level
			p[cf] = s.n - s.uc
			p[lf] = s.levels - s.uc
		end
	end
end

-- =================================================================== cost ==

-- Upstream costWrapper (Config.ts:641-660):
--   n = SUM over the cost pool of min(unitsOwned(t), unitsConstructed(t))
--       + extraUnits
-- The min() is what makes an empire that LOST structures rebuild cheaper,
-- and one that CAPTURED them not pay for somebody else's spending.
-- `extra` prices the later steps of a bulk upgrade (PlayerImpl.ts:1438-1446).
--
-- DIVERGENCE, FLAGGED FOR WHOEVER WIRES STEP 3. This is upstream's basis:
-- unitsOwned is the sum of LEVELS, so an upgrade raises the price of your
-- next building. Economy.cost today uses p.cityCount, the number of
-- structures, and its own comment (Economy:153-155) states the opposite
-- intent -- "an upgrade never raises the price of your next building".
-- Pointing Economy.cost at this function therefore CHANGES CITY AND PORT
-- PRICING. That is the 1:1 behaviour and is almost certainly what the port
-- wants, but it is a balance change and must be a deliberate one; if the
-- current curve is to be preserved, wrap this with Units.structureCount
-- instead of calling it directly.
function Units.cost(sim: any, playerId: number, utype: number, extra: number?): number
	local info = Units.INFO[utype]
	if info == nil then
		return 0
	end
	local n = extra or 0
	local pool = info.costPool
	if pool ~= nil then
		for _, t in pool do
			local s = statOf(sim, playerId, t)
			local owned = s.levels
			local built = s.built
			n += (owned < built) and owned or built
		end
	end
	return info.costFn(n, sim)
end

-- ================================================================ events ==

-- Deliberately SHAPED LIKE Economy.noteStruct (Economy:166-173): tile,
-- ownerId, level, kind, with level 0 and ownerId 0 meaning "gone". The
-- client already reads exactly that in Structures.set (Structures:171-179),
-- where a razed structure and a captured one arrive on the same channel.
-- Keeping the field names identical makes the eventual single-stream
-- rewrite a filter rather than a translation.
-- The other half of the onDelete contract. Anything that hangs a satellite
-- record off a unit's ext -- Economy's station is the only one today -- gets
-- told whenever the two mutable fields it mirrors move: owner and level.
-- Fired from setOwner, upgrade and decreaseLevel, which is every writer of
-- either. Without it a nuke taking a level off a city (decreaseLevel) would
-- leave the station's copy a level high for the rest of the round.
local function sync(u: Unit)
	local e = u.ext
	if e == nil then
		return
	end
	local fn = e.onSync
	if fn ~= nil then
		fn(u)
	end
end

-- TICKS UNTIL THE FRONT TUBE IS READY, on an anti-nuke tower and nothing else,
-- or nil when none is reloading. It is what lets the client draw the reload bar
-- over the chip without keeping a clock: the two events that carry it are fired
-- by Units.launch and Units.reload, which are exactly the two moments it moves.
--
-- `#missileTimers` is how many tubes are busy and `level` is how many exist, so
-- the FRONT entry is the one that frees up first -- the same entry
-- Nukes.stepSams reloads against, and the same rule Units.inCooldown states.
local SAM_COOLDOWN = Config.SAM_COOLDOWN or 90

local function reloadLeft(sim: any, u: Unit): number?
	-- AN AIRFIELD REARMS LIKE A SILO (2026-09-21): one sortie, then
	-- Config.AIRSTRIKE_COOLDOWN ticks with the bar drawn over the chip. Its
	-- missileTimers carry the launch tick the way a launcher's do.
	if u.utype == Units.AIRFIELD then
		local front = u.missileTimers[1]
		if front == nil then
			return nil
		end
		local remaining = (Config.AIRSTRIKE_COOLDOWN or 600) - (sim.tick - front)
		return remaining > 0 and remaining or nil
	end
	-- THE RAILGUN RELOADS THE SAME WAY (2026-09-24), off its own cooldown.
	if u.utype == Units.RAILGUN then
		local front = u.missileTimers[1]
		if front == nil then
			return nil
		end
		local remaining = (Config.RAILGUN_COOLDOWN or 250) - (sim.tick - front)
		return remaining > 0 and remaining or nil
	end
	-- A BATTERY RELOADS BETWEEN BARRAGES (owner, 2026-09-22: "i want artillery
	-- to have a rearm bar as well"). Its clock is not a missileTimers entry but
	-- `ext.reloadUntil`, which Artillery.step sets when the gun FIRES and clears
	-- when it comes due with nothing to shoot -- so an idle gun waiting for a
	-- target draws no bar, only one that is actually between shots. The gap is
	-- rolled per shot (ARTILLERY_COOLDOWN_MIN..MAX, times the AI multiplier), so
	-- unlike the two kinds above the bar's full length is not a constant the
	-- client knows: reloadTotal below ships it alongside.
	if u.utype == Units.ARTILLERY then
		local e = u.ext
		local due = e and e.reloadUntil
		if due == nil then
			return nil
		end
		local remaining = due - sim.tick
		return remaining > 0 and remaining or nil
	end
	if u.utype ~= Units.SAM_LAUNCHER then
		return nil
	end
	-- A BUSY TUBE IS NOT A RELOADING TOWER (2026-09-16). `level` is how many
	-- tubes exist and `#missileTimers` how many are in flight, so a level-2
	-- launcher with one missile out is still ARMED and must draw no bar. That is
	-- the rule Units.inCooldown states, and until now this function contradicted
	-- it on every upgraded tower: nine seconds of `reloading` drawn over a
	-- launcher that would have fired, which both the owner and whoever was
	-- timing a strike off the bar read as the opposite of the truth.
	if #u.missileTimers < u.level then
		return nil
	end
	local front = u.missileTimers[1]
	if front == nil then
		return nil
	end
	local remaining = SAM_COOLDOWN - (sim.tick - front)
	return remaining > 0 and remaining or nil
end

Units.reloadLeft = reloadLeft

-- THE FULL LENGTH of the reload `rl` counts down, in ticks, and only where the
-- client cannot know it: a battery's per-shot gap. Nil on every other kind (the
-- client's setReload falls back to the kind's constant) and on a gun at rest.
local function reloadTotal(sim: any, u: Unit): number?
	if u.utype ~= Units.ARTILLERY then
		return nil
	end
	local e = u.ext
	if e == nil or e.reloadUntil == nil or e.reloadUntil <= sim.tick then
		return nil
	end
	return e.reloadTotal
end

Units.reloadTotal = reloadTotal

local function emit(sim: any, u: Unit, alive: boolean)
	local ev = sim.unitEvents
	ev[#ev + 1] = {
		id = u.id,
		kind = u.utype,
		tile = u.tile,
		ownerId = alive and u.ownerId or 0,
		level = alive and u.level or 0,
		uc = u.underConstruction,
		-- TICKS STILL TO RUN, and only on a site. It is what lets the client
		-- draw a build as a progress it can watch instead of a wait it cannot
		-- tell from a dropped click -- one number, on an event that fires twice
		-- in a building's life.
		left = u.underConstruction and (u.buildDoneTick - sim.tick) or nil,
		-- The reload, on a launcher that is reloading and nowhere else. Nil is
		-- the resting state and the client reads it as "no bar" -- see
		-- reloadLeft above, and Structures.setReload for what it draws.
		rl = reloadLeft(sim, u),
		-- ...and how long that reload is in full, ticks, only on a battery
		-- (reloadTotal): the bar's length where it is not a constant.
		rt = reloadTotal(sim, u),
		-- HIT POINTS LEFT, as a fraction, and only once some are gone (2026-09-21,
		-- owner: "add a health bar similar to how my ships health bar displays
		-- so i can see the damage to buildings"). Nil is "unhurt" and the client
		-- draws no bar for it -- a bar that cannot move is a second row of pixels
		-- on every city on the map. Units.damageStructure emits on every hit.
		hp = (alive and u.health < Units.maxHealth(u)) and (u.health / Units.maxHealth(u)) or nil,
	}
end

Units.emit = emit

-- The same fraction for the joiner snapshot (Economy.snapshotStructures).
function Units.hpOf(u: Unit?): number?
	if u == nil or not u.active then
		return nil
	end
	local maxH = Units.maxHealth(u)
	if u.health < maxH then
		return u.health / maxH
	end
	return nil
end

function Units.drainEvents(sim: any): { any }?
	if #sim.unitEvents == 0 then
		return nil
	end
	local out = sim.unitEvents
	sim.unitEvents = {}
	return out
end

-- ============================================================== indexing ==

local function gridAdd(sim: any, u: Unit)
	local key = cellOf(u.tile)
	local cell = sim.unitCells[key]
	if cell == nil then
		cell = {}
		sim.unitCells[key] = cell
	end
	local bucket = cell[u.utype]
	if bucket == nil then
		bucket = {}
		cell[u.utype] = bucket
	end
	u.cellKey = key
	listAdd(bucket, u, "cellIdx")
end

local function gridRemove(sim: any, u: Unit)
	local cell = sim.unitCells[u.cellKey]
	if cell == nil then
		return
	end
	local bucket = cell[u.utype]
	if bucket == nil then
		return
	end
	listRemove(bucket, u, "cellIdx")
end

-- Upstream UnitGrid.updateUnitCell (UnitGrid.ts:67-82): only re-bucket when
-- the CELL changed, not when the tile did. A transport boat moving one tile a
-- tick (Config.TRANSPORT_BOAT_SPEED) crosses a cell boundary about once every
-- thirty ticks.
function Units.reindex(sim: any, u: Unit)
	local key = cellOf(u.tile)
	if key == u.cellKey then
		return
	end
	gridRemove(sim, u)
	gridAdd(sim, u)
end

-- ============================================================= lifecycle ==

-- Upstream PlayerImpl.buildUnit (PlayerImpl.ts:1286-1314).
--
-- GOLD IS NOT DEDUCTED HERE. Upstream deducts inside buildUnit (:1308);
-- splitting it out lets the same call serve a paid build, a free spawn (a
-- shell, a trading boat, an MIRV warhead) and a test fixture without three
-- code paths. The caller pays.
--
-- Upstream records the construction the moment the unit is created, while
-- it is still under construction (:1307, and the comment at :465-468) --
-- so the cost curve already accounts for in-progress builds and must not
-- re-count them on completion. Matched here.
--
-- params (all optional): level, troops, underConstruction, buildTicks,
-- targetTile, targetUnitId, targetPlayerId, trajectory, ext.
function Units.spawn(sim: any, utype: number, ownerId: number, tile: number, params: any?): Unit
	local p = params or {}
	local info = Units.INFO[utype]
	local level = p.level or 1

	local u: Unit = {
		id = sim.nextUnitId,
		utype = utype,
		ownerId = ownerId,
		tile = tile,
		level = level,
		active = true,

		underConstruction = false,
		buildDoneTick = -1,
		deletionAt = -1,

		-- UnitImpl.ts:61 -- health starts at maxHealth, defaulting to 1 for
		-- the types that have none.
		health = (info and info.maxHealth) or 1,
		troops = p.troops or 0,

		targetTile = p.targetTile,
		targetUnitId = p.targetUnitId,
		targetPlayerId = p.targetPlayerId,
		trajectory = p.trajectory,
		trajectoryIndex = 0,
		targetedBySam = false,
		targetable = true,
		reachedTarget = false,

		missileTimers = {},

		veterancy = 0,
		veterancyProgress = 0,
		hasTrainStation = false,

		cellKey = -1,
		cellIdx = 0,
		typeIdx = 0,
		ownerIdx = 0,
		buildIdx = 0,

		ext = p.ext,
	}
	sim.nextUnitId += 1

	sim.units[u.id] = u
	listAdd(sim.unitsByType[utype], u, "typeIdx")

	if ownerId ~= 0 then
		local owned = sim.unitsByPlayer[ownerId]
		if owned == nil then
			owned = {}
			sim.unitsByPlayer[ownerId] = owned
		end
		listAdd(owned, u, "ownerIdx")
	end

	gridAdd(sim, u)

	statAdd(sim, ownerId, utype, 1, level, 0)
	if ownerId ~= 0 then
		statOf(sim, ownerId, utype).built += 1
	end

	-- ConstructionExecution.ts:70-75. A duration of 0 (or instantBuild,
	-- Config.ts:341-343) means the unit is finished the moment it is placed.
	local ticks = p.buildTicks
	if ticks == nil and p.underConstruction and info ~= nil then
		ticks = info.buildTicks
	end
	if p.underConstruction and ticks ~= nil and ticks > 0 then
		u.underConstruction = true
		u.buildDoneTick = sim.tick + ticks
		-- Through statAdd, NOT statOf: the legacy player mirror is written there
		-- and it subtracts uc, so a direct bump here would leave p.cityCount
		-- counting a site that has not been built yet -- and Economy.cost reads
		-- p.cityCount, so that is the price of the NEXT city.
		statAdd(sim, ownerId, utype, 0, 0, 1)
		listAdd(sim.buildingUnits, u, "buildIdx")
	end

	emit(sim, u, true)
	return u
end

-- Upstream UnitImpl.delete (UnitImpl.ts:322-362) plus GameImpl.removeUnit
-- (GameImpl.ts:1049-1056). destroyerId is 0 for a unit that arrived,
-- retreated or was voluntarily scrapped -- upstream distinguishes those
-- from a kill via wasDestroyedByEnemy (:328).
function Units.delete(sim: any, u: Unit, destroyerId: number?)
	if not u.active then
		return
	end
	u.active = false

	if u.underConstruction then
		statAdd(sim, u.ownerId, u.utype, 0, 0, -1)
		u.underConstruction = false
		listRemove(sim.buildingUnits, u, "buildIdx")
	end
	statAdd(sim, u.ownerId, u.utype, -1, -u.level, 0)

	gridRemove(sim, u)
	listRemove(sim.unitsByType[u.utype], u, "typeIdx")
	if u.ownerId ~= 0 then
		local owned = sim.unitsByPlayer[u.ownerId]
		if owned ~= nil then
			listRemove(owned, u, "ownerIdx")
		end
	end
	sim.units[u.id] = nil

	if u.ext ~= nil then
		u.ext.destroyerId = destroyerId
		-- Whoever gave this unit its ext is told it is gone, BEFORE the event
		-- goes out. A structure has a rail network, a station list and a
		-- tile index hanging off it that nothing else can unlink, and after
		-- Units.stepCapture lands this is the ONLY notice it gets that its
		-- ground fell to nobody. Upstream routes the same notification through
		-- GameImpl.removeUnit (GameImpl.ts:1049-1056).
		--
		-- The hook must not call back into Units.delete for this unit: active
		-- is already false, so it would return immediately, but the contract is
		-- "unlink, do not re-delete".
		local onDelete = u.ext.onDelete
		if onDelete ~= nil then
			onDelete(sim, u)
		end
	end
	emit(sim, u, false)
end

-- Upstream UnitImpl.setOwner (UnitImpl.ts:231-260).
--
-- IT DOES NO SPATIAL WORK, and that is the whole reason capture is cheap:
-- the grid is keyed by (cell, type) only and never by owner
-- (UnitGrid.ts:11), so changing hands cannot move a unit between buckets.
--
-- Capturing a unit also DISARMS its pending self-destruct
-- (clearPendingDeletion, UnitImpl.ts:232 + :298-300) -- taking somebody's
-- city should not inherit their decision to scrap it.
function Units.setOwner(sim: any, u: Unit, newOwnerId: number)
	if u.ownerId == newOwnerId then
		return
	end
	local old = u.ownerId

	u.deletionAt = -1

	local uc = u.underConstruction and 1 or 0
	statAdd(sim, old, u.utype, -1, -u.level, -uc)

	if old ~= 0 then
		local owned = sim.unitsByPlayer[old]
		if owned ~= nil then
			listRemove(owned, u, "ownerIdx")
		end
	end

	u.ownerId = newOwnerId

	if newOwnerId ~= 0 then
		local owned = sim.unitsByPlayer[newOwnerId]
		if owned == nil then
			owned = {}
			sim.unitsByPlayer[newOwnerId] = owned
		end
		listAdd(owned, u, "ownerIdx")
	end
	-- `built` is deliberately NOT transferred: it counts what an empire PAID
	-- for, so a captor does not inherit the seller's spending
	-- (Config.ts:652-657, and Economy:153-155 says the same).
	statAdd(sim, newOwnerId, u.utype, 1, u.level, uc)

	sync(u)

	emit(sim, u, true)
end

-- Upstream UnitImpl.move (UnitImpl.ts:194-201) -> GameImpl.onUnitMoved
-- (:596-599) -> updateUnitTile (:1057-1059).
function Units.move(sim: any, u: Unit, tile: number)
	u.tile = tile
	Units.reindex(sim, u)
end

function Units.get(sim: any, id: number): Unit?
	return sim.units[id]
end

-- ================================================================ queries ==

-- Upstream PlayerImpl.units() with no argument returns the LIVE array and
-- documents "do not mutate it" (Game.ts:650-653, PlayerImpl.ts:414-416).
-- Same contract here. Use collectPlayerType for a filtered view.
function Units.ofPlayer(sim: any, playerId: number): { Unit }
	local owned = sim.unitsByPlayer[playerId]
	if owned == nil then
		owned = {}
		sim.unitsByPlayer[playerId] = owned
	end
	return owned
end

-- Upstream GameImpl.units(type) walks every player and rebuilds an array
-- (GameImpl.ts:314-354). A per-type list makes it free, and the type of a
-- unit never changes, so the index never needs maintaining after spawn.
-- LIVE array; do not mutate.
function Units.ofType(sim: any, utype: number): { Unit }
	return sim.unitsByType[utype]
end

-- Filtered per-player view, written into a caller-supplied table. Upstream
-- allocates one right-sized array per call from a scratch buffer
-- (PlayerImpl.ts:422-453); handing the buffer in from outside means the
-- callers that run every tick allocate nothing at all.
function Units.collectPlayerType(sim: any, playerId: number, utype: number, out: { Unit }): number
	local owned = sim.unitsByPlayer[playerId]
	local n = 0
	if owned ~= nil then
		for _, u in owned do
			if u.utype == utype and u.active then
				n += 1
				out[n] = u
			end
		end
	end
	return n
end

-- The cell rectangle covering a query circle. Upstream computes the same
-- thing with a more roundabout formula (UnitGrid.getCellsInRange,
-- :94-117); floor-dividing the two extremes is exact and shorter. Luau's
-- // is floor division, so a negative left edge lands on -1 and clamps.
local function cellRange(tile: number, radius: number): (number, number, number, number)
	local x = tile % W
	local y = (tile - x) / W
	local x0 = (x - radius) // CELL
	local x1 = (x + radius) // CELL
	local y0 = (y - radius) // CELL
	local y1 = (y + radius) // CELL
	if x0 < 0 then
		x0 = 0
	end
	if y0 < 0 then
		y0 = 0
	end
	if x1 > CW - 1 then
		x1 = CW - 1
	end
	if y1 > CH - 1 then
		y1 = CH - 1
	end
	return x0, x1, y0, y1
end

-- Upstream UnitGrid.nearbyUnits (UnitGrid.ts:135-202).
--
-- TWO DIFFERENCES, both about allocation. Upstream pushes a fresh
-- { unit, distSquared } object per hit (:170, :195); at SAM detection range
-- (maxSamRange * 4 = 600, SAMLauncherExecution.ts:216-219) that is a table
-- per nuke per SAM per tick. Here `out` and `outD2` are caller-supplied
-- parallel arrays and the return value is the count. And upstream does not
-- sort -- neither does this; callers that want the nearest should use
-- Units.closest, which never builds a list at all.
--
-- `types` is a single utype or an array of them. `filter(u, d2)` runs after
-- the distance test, as upstream's predicate does (:171).
--
-- includeUnderConstruction defaults to FALSE, matching upstream (:140):
-- a half-built defense post does not defend, and a half-built structure is
-- invisible to everything EXCEPT the spacing and upgrade-target checks,
-- which pass true (PlayerImpl.ts:1334, :1637).
function Units.nearby(
	sim: any,
	tile: number,
	radius: number,
	types: any,
	out: { Unit },
	outD2: { number }?,
	filter: ((Unit, number) -> boolean)?,
	includeUnderConstruction: boolean?
): number
	local x0, x1, y0, y1 = cellRange(tile, radius)
	local qx = tile % W
	local qy = (tile - qx) / W
	local r2 = radius * radius
	local cells = sim.unitCells
	local includeUC = includeUnderConstruction == true
	local n = 0

	local single = (type(types) == "number")

	for cy = y0, y1 do
		local row = cy * CW
		for cx = x0, x1 do
			local cell = cells[row + cx]
			if cell ~= nil then
				local first, last = 1, 1
				if not single then
					last = #types
				end
				for ti = first, last do
					local bucket = cell[single and types or types[ti]]
					if bucket ~= nil then
						for _, u in bucket do
							if u.active and (includeUC or not u.underConstruction) then
								local ux = u.tile % W
								local uy = (u.tile - ux) / W
								local dx = ux - qx
								local dy = uy - qy
								local d2 = dx * dx + dy * dy
								if d2 <= r2 and (filter == nil or filter(u, d2)) then
									n += 1
									out[n] = u
									if outD2 ~= nil then
										outD2[n] = d2
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return n
end

-- Upstream UnitGrid.hasUnitNearby (UnitGrid.ts:227-259). Early exit, zero
-- allocation, and an optional owner filter applied INSIDE the loop
-- (unitIsInRange, :219-221) rather than after it.
--
-- THIS IS THE FORM THE ATTACK LOOP MUST USE. Upstream's defense-post check
-- calls nearbyUnits and filters afterwards (AttackExecution.ts:331-340),
-- allocating an array for every conquered tile. It survives that because
-- its per-attack budget is one tick spent in fractions (:271) -- a handful
-- of tiles. Conquest conquers thousands of tiles a tick
-- (Config.GLOBAL_TILE_BUDGET), so the allocating form is not an option.
function Units.hasNearby(
	sim: any,
	tile: number,
	radius: number,
	utype: number,
	playerId: number?,
	includeUnderConstruction: boolean?
): boolean
	local x0, x1, y0, y1 = cellRange(tile, radius)
	local qx = tile % W
	local qy = (tile - qx) / W
	local r2 = radius * radius
	local cells = sim.unitCells
	local includeUC = includeUnderConstruction == true

	for cy = y0, y1 do
		local row = cy * CW
		for cx = x0, x1 do
			local cell = cells[row + cx]
			if cell ~= nil then
				local bucket = cell[utype]
				if bucket ~= nil then
					for _, u in bucket do
						if
							u.active
							and (includeUC or not u.underConstruction)
							and (playerId == nil or u.ownerId == playerId)
						then
							local ux = u.tile % W
							local uy = (u.tile - ux) / W
							local dx = ux - qx
							local dy = uy - qy
							if dx * dx + dy * dy <= r2 then
								return true
							end
						end
					end
				end
			end
		end
	end
	return false
end

-- Upstream UnitGrid.anyUnitNearby (UnitGrid.ts:262-300). The many-types
-- early-exit form, used for the nuke-would-hit-an-ally checks
-- (PlayerImpl.ts:1545, execution/Util.ts:60).
function Units.anyNearby(
	sim: any,
	tile: number,
	radius: number,
	types: { number },
	pred: (Unit) -> boolean,
	playerId: number?,
	includeUnderConstruction: boolean?
): boolean
	local x0, x1, y0, y1 = cellRange(tile, radius)
	local qx = tile % W
	local qy = (tile - qx) / W
	local r2 = radius * radius
	local cells = sim.unitCells
	local includeUC = includeUnderConstruction == true

	for cy = y0, y1 do
		local row = cy * CW
		for cx = x0, x1 do
			local cell = cells[row + cx]
			if cell ~= nil then
				for _, t in types do
					local bucket = cell[t]
					if bucket ~= nil then
						for _, u in bucket do
							if
								u.active
								and (includeUC or not u.underConstruction)
								and (playerId == nil or u.ownerId == playerId)
							then
								local ux = u.tile % W
								local uy = (u.tile - ux) / W
								local dx = ux - qx
								local dy = uy - qy
								if dx * dx + dy * dy <= r2 and pred(u) then
									return true
								end
							end
						end
					end
				end
			end
		end
	end
	return false
end

-- The findClosestBy(nearbyUnits(...)) shape upstream writes out longhand at
-- PlayerImpl.ts:1328-1339 (which unit does this build upgrade) and
-- :1597-1607 (which port does this gunboat spawn from), as a primitive so
-- neither ever materialises a list. Returns the unit and its squared
-- distance.
function Units.closest(
	sim: any,
	tile: number,
	radius: number,
	utype: number,
	playerId: number?,
	includeUnderConstruction: boolean?
): (Unit?, number)
	local x0, x1, y0, y1 = cellRange(tile, radius)
	local qx = tile % W
	local qy = (tile - qx) / W
	local r2 = radius * radius
	local cells = sim.unitCells
	local includeUC = includeUnderConstruction == true
	local best: Unit? = nil
	local bestD = math.huge

	for cy = y0, y1 do
		local row = cy * CW
		for cx = x0, x1 do
			local cell = cells[row + cx]
			if cell ~= nil then
				local bucket = cell[utype]
				if bucket ~= nil then
					for _, u in bucket do
						if
							u.active
							and (includeUC or not u.underConstruction)
							and (playerId == nil or u.ownerId == playerId)
						then
							local ux = u.tile % W
							local uy = (u.tile - ux) / W
							local dx = ux - qx
							local dy = uy - qy
							local d2 = dx * dx + dy * dy
							if d2 <= r2 and d2 < bestD then
								bestD = d2
								best = u
							end
						end
					end
				end
			end
		end
	end
	return best, bestD
end

-- ================================================== build / upgrade / kill ==

-- The part of upstream's canBuild that every land structure shares:
-- validStructureSpawnTiles (PlayerImpl.ts:1625-1663) reduced to "is THIS
-- tile legal", which is what Conquest's UI actually asks.
--
-- The per-type rules that are NOT here stay with the systems that own them,
-- and are wired in later steps: a port snapping to owned coast
-- (PlayerImpl.portSpawn :1568-1589, already implemented as
-- Economy.snapToCoast :545-567), a gunboat spawning from a port in the same
-- water body (:1591-1608), a nuke spawning from the nearest ready silo
-- (:1518-1566), a transport boat (TransportShipUtils).
--
-- includeUnderConstruction is TRUE for the spacing test on purpose: two
-- sites half a tile apart are as illegal as two finished buildings, and
-- upstream passes true here for exactly that reason (:1637). It is what
-- replaces Economy's separate scan of sim.sites (Economy:614-618).
function Units.canPlaceStructure(sim: any, playerId: number, utype: number, tile: number): (boolean, string?)
	if tile < 0 or tile >= Config.NUM_TILES then
		return false, "offmap"
	end
	if buffer.readu8(sim.map.owner, tile) ~= playerId then
		return false, "land"
	end
	if not TileMap.isPassable(sim.map, tile) then
		return false, "terrain"
	end
	-- Any structure of any kind and any owner inside the spacing radius
	-- blocks the build. Upstream deletes every candidate tile within
	-- structureMinDist of ANY nearby structure (:1647-1655).
	--
	-- ONE multi-type walk, not six single-type ones. This runs on every
	-- build click and, once Units.canBuild grows the candidate-tile search
	-- upstream does (validStructureSpawnTiles walks a whole BFS disc,
	-- PlayerImpl.ts:1639-1655), once per candidate. ALWAYS_TRUE is a
	-- module-level upvalue rather than a fresh closure per call for the
	-- same reason.
	if
		Units.anyNearby(sim, tile, Units.STRUCTURE_MIN_DIST, Units.STRUCTURE_TYPES, ALWAYS_TRUE, nil, true)
	then
		return false, "crowded"
	end
	return true
end

-- Upstream PlayerImpl.findUnitToUpgrade (PlayerImpl.ts:1316-1340): the
-- closest unit of the SAME TYPE owned by the same player inside
-- structureMinDist. Checked BEFORE the crowding rule, because otherwise the
-- two contradict -- anything close enough to upgrade is also too close to
-- build (the same ordering Economy.canBuild:596-609 already uses).
function Units.findToUpgrade(sim: any, playerId: number, utype: number, tile: number): Unit?
	local u = Units.closest(sim, tile, Units.STRUCTURE_MIN_DIST, utype, playerId, true)
	return u
end

-- Upstream PlayerImpl.canUpgradeUnit (PlayerImpl.ts:1376-1387), which is
-- the AND of three checks: the TYPE is upgradable (:1359-1361), the player
-- can afford it and is alive (:1342-1357), and the UNIT is eligible --
-- not under construction, not marked for deletion, owned by us
-- (:1363-1374).
--
-- The maxLevel term is Conquest's, not upstream's: upstream has no level
-- cap at all. It moves here from Economy.canBuild:602 so that both the
-- build path and the upgrade path enforce it.
function Units.canUpgrade(sim: any, u: Unit, gold: number?): (boolean, string?)
	local info = Units.INFO[u.utype]
	if info == nil or not info.upgradable then
		return false, "notupgradable"
	end
	if not u.active or u.underConstruction then
		return false, "building"
	end
	if u.deletionAt >= 0 then
		return false, "deleting"
	end
	if info.maxLevel ~= nil and u.level >= info.maxLevel then
		return false, "maxlevel"
	end
	if gold ~= nil and gold < Units.cost(sim, u.ownerId, u.utype) then
		return false, "gold"
	end
	return true
end

-- Upstream PlayerImpl.upgradeUnit (:1389-1394) + UnitImpl.increaseLevel
-- (UnitImpl.ts:699-715). As with spawn, GOLD IS NOT DEDUCTED HERE.
--
-- Two things that look like details and are not:
--   * a SAM snapshots its range transition so the radius INTERPOLATES to
--     the new level over samUpgradeDuration instead of jumping
--     (Config.dynamicSamRange, Config.ts:1043-1056). The snapshot has to be
--     taken BEFORE level changes, since it records the range at the old one.
--   * a silo or SAM pushes a launch tick onto missileTimers, so a newly
--     bought tube starts RELOADING rather than arriving ready
--     (UnitImpl.ts:711-713).
function Units.upgrade(sim: any, u: Unit)
	if u.utype == Units.SAM_LAUNCHER then
		local ext = u.ext
		if ext == nil then
			ext = {}
			u.ext = ext
		end
		ext.upgradeStartTick = sim.tick
		ext.startRange = ext.currentRange
		ext.targetLevel = u.level + 1
	end

	u.level += 1
	statAdd(sim, u.ownerId, u.utype, 0, 1, 0)
	if u.ownerId ~= 0 then
		statOf(sim, u.ownerId, u.utype).built += 1
	end

	if u.utype == Units.MISSILE_SILO or u.utype == Units.SAM_LAUNCHER then
		u.missileTimers[#u.missileTimers + 1] = sim.tick
	end

	sync(u)
	emit(sim, u, true)
end

-- Upstream UnitImpl.decreaseLevel (UnitImpl.ts:717-730). A nuke knocks a
-- level off a structure rather than razing it; the structure only dies when
-- the last level goes.
function Units.decreaseLevel(sim: any, u: Unit, destroyerId: number?)
	u.level -= 1
	statAdd(sim, u.ownerId, u.utype, 0, -1, 0)

	if u.utype == Units.MISSILE_SILO or u.utype == Units.SAM_LAUNCHER then
		local timers = u.missileTimers
		if #timers > 0 then
			timers[#timers] = nil
		end
	end
	if u.utype == Units.SAM_LAUNCHER and u.ext ~= nil then
		u.ext.upgradeStartTick = nil
	end

	if u.level <= 0 then
		Units.delete(sim, u, destroyerId)
		return
	end
	sync(u)
	emit(sim, u, true)
end

-- Upstream UnitImpl.markForDeletion (UnitImpl.ts:306-313) and
-- isOverdueDeletion (:315-320). Deleting is an ARMED TIMER, not an action:
-- the unit lives for another deletionMarkDuration (30 s) and the mark is
-- cleared outright if somebody captures it (Units.setOwner).
function Units.markForDeletion(sim: any, u: Unit)
	if not u.active then
		return
	end
	u.deletionAt = sim.tick + Units.DELETION_MARK_TICKS
	emit(sim, u, true)
end

function Units.isOverdue(sim: any, u: Unit): boolean
	if not u.active then
		return false
	end
	return u.deletionAt >= 0 and sim.tick - u.deletionAt > 0
end

-- ========================================================= construction ===

-- Upstream spends one ConstructionExecution object per site and counts it
-- down in tick() (ConstructionExecution.ts:46-98). One list is the
-- Luau-shaped equivalent, and it preserves the behaviour that matters for
-- free: a site whose ground was taken mid-build completes for WHOEVER HOLDS
-- IT NOW, because the unit already changed hands with the tile. Upstream
-- gets there by re-reading this.structure.owner() every tick
-- (:87-92); Economy gets there by re-reading the owner byte at completion
-- (Economy:672-675). Here it is simply already true.
--
-- Completed units are written into `out` (caller-supplied) and the count
-- returned, so the caller can fire the per-type behaviour hooks that
-- ConstructionExecution.completeConstruction fires (:100-159). Iterated
-- backwards so a swap-remove cannot skip an entry.
function Units.stepConstruction(sim: any, out: { Unit }?): number
	local list = sim.buildingUnits
	local n = 0
	for i = #list, 1, -1 do
		local u = list[i]
		if not u.active then
			listRemove(list, u, "buildIdx")
		elseif sim.tick >= u.buildDoneTick then
			u.underConstruction = false
			u.buildDoneTick = -1
			statAdd(sim, u.ownerId, u.utype, 0, 0, -1)
			listRemove(list, u, "buildIdx")
			emit(sim, u, true)
			n += 1
			if out ~= nil then
				out[n] = u
			end
		end
	end
	return n
end

-- ============================================================== capture ===

-- THE territory-bound rule. Upstream PlayerExecution.tick:45-67.
--
-- READ THIS BEFORE MOVING IT. Upstream does NOT capture units inside
-- conquer(): GameImpl.conquer (GameImpl.ts:749-768) touches no units at
-- all. Capture is this ONCE-PER-PLAYER-PER-TICK sweep of the player's own
-- unit list, so its cost is O(units owned) and is bounded by how many units
-- exist -- NOT by how many tiles were conquered.
--
-- That distinction is the entire reason this function exists. Conquest
-- currently calls Economy.onTileOwnerChanged from Sim.conquer:550-552,
-- which runs on EVERY tile flip: Sim.processAttack conquers up to
-- Config.GLOBAL_TILE_BUDGET (14,000, floored at 4,000) tiles a tick, plus
-- pocket mop-up, plus COLLAPSE_TILES_PER_TICK (2,500) during an absorption
-- -- four to sixteen thousand hash lookups a tick for work upstream does in
-- a few hundred. Once this is called from Sim.step, that call comes out.
--
-- THREE RULES, and every one of them is load-bearing:
--
--   1. ONLY STRUCTURES. Upstream guards the whole loop with
--      Structures.has(u.type()) (:48-50). Without it this deletes every
--      nuke in flight over neutral ground and every boat at sea, because a
--      water tile has no player owner and rule 2 razes anything standing on
--      one.
--   2. Ground fallen to NOBODY razes the structure (:52-56). A city cannot
--      stand on land its empire no longer holds.
--   3. A DEFENSE POST IS DESTROYED, NEVER CAPTURED (:62-64). It is the one
--      structure that does not change hands -- taking the ground breaks it.
--
-- Iteration is a while loop rather than a for, because capturing or
-- deleting removes the unit from the very list being walked; the index only
-- advances when the slot still holds the same unit.
function Units.stepCapture(sim: any)
	local order = sim.playerOrder
	if order == nil then
		return
	end
	local owner = sim.map.owner

	-- BY TYPE, not by player, and that is the one place this deliberately
	-- leaves upstream's shape. Upstream walks player.units() and pays
	-- Structures.has(u.type()) on every unit an empire owns -- gunboats,
	-- warheads, trading boats and all -- because a JS Map is the only index it
	-- has. Conquest keeps a per-type index, and the STRUCTURE types are
	-- 1..STRUCTURE_LAST and contiguous, so walking those lists visits exactly
	-- the same set with no type test, no per-player indirection and nothing
	-- to skip. The set swept is identical; the cost is not.
	--
	-- NOT gated on p.alive, and upstream is not either: its capture loop sits
	-- ABOVE the isAlive early-return in PlayerExecution.tick (:44-67 vs :68).
	-- It matters here more than there. A Conquest empire that collapses keeps
	-- bleeding tiles to its captor for several ticks afterwards
	-- (COLLAPSE_TILES_PER_TICK at a time), and skipping the dead would strand
	-- every structure it still owned: owned by a corpse, standing on somebody
	-- else's ground, never swept again.
	--
	-- Iteration is a while loop, not a for: deleting swap-removes the unit
	-- from the very list being walked, so the slot has to be re-read and the
	-- length re-taken. Capturing does NOT touch this list -- the grid and the
	-- type index are keyed by (cell, type) and never by owner (UnitGrid.ts:11)
	-- -- which is the whole reason changing hands is cheap.
	local byType = sim.unitsByType
	local razed = Units.RAZED_ON_CAPTURE
	for _, t in Units.STRUCTURE_TYPES do
		local list = byType[t]
		local n = #list
		local i = 1
		while i <= n do
			local u = list[i]
			local pid = u.ownerId
			local holder = buffer.readu8(owner, u.tile)
			if holder ~= pid and pid ~= 0 and u.active then
				if holder == 0 then
					Units.delete(sim, u, nil)
					n = #list
				elseif razed[t] then
					-- A DEFENSE POST IS DESTROYED, NEVER CAPTURED
					-- (PlayerExecution.ts:62-64). Taking the ground breaks it.
					-- The artillery and the airfield follow it (Units.RAZED_ON_CAPTURE).
					Units.delete(sim, u, holder)
					n = #list
				else
					Units.setOwner(sim, u, holder)
					i += 1
				end
			else
				i += 1
			end
		end
	end
end

-- ============================================== health / combat / veterancy ==

-- Upstream Veterancy.maxHealthWithVeterancy (game/Veterancy.ts:11-23).
-- Integer percent math, deliberately, so the engine and the renderer derive
-- the same number. veterancy is 0 for everything that is not a gunboat, so
-- this returns the base for them.
function Units.maxHealth(u: Unit): number
	local info = Units.INFO[u.utype]
	local base = (info and info.maxHealth) or 1
	if u.veterancy <= 0 then
		return base
	end
	return base + (base * u.veterancy * Units.VETERANCY_HEALTH_BONUS) // 100
end

-- Upstream UnitImpl.modifyHealth (UnitImpl.ts:272-296). Reaching zero
-- deletes the unit and credits the attacker (:293-295).
function Units.modifyHealth(sim: any, u: Unit, delta: number, attackerId: number?)
	if not u.active then
		return
	end
	local maxH = Units.maxHealth(u)
	local next = u.health + delta
	if next < 0 then
		next = 0
	elseif next > maxH then
		next = maxH
	end
	if next == u.health then
		return
	end
	if attackerId ~= nil and delta < 0 and u.ext ~= nil then
		u.ext.lastCombatTick = sim.tick
	end
	u.health = next
	if next == 0 then
		Units.delete(sim, u, attackerId)
	end
end

-- A BUILDING TAKING FIRE (2026-09-21; artillery shells and airfield bombs are
-- the two callers). Shared so both weapons chip at the same number: `health`
-- starts at Units.INFO[kind].maxHealth (Config.STRUCTURE_HEALTH for the six
-- shipped kinds), credited to `attackerId` the way a captured post is. A site
-- under construction is as vulnerable as a finished one. Returns true when
-- this hit destroyed it.
--
-- ZERO TAKES A LEVEL, NOT THE BUILDING (owner, 2026-09-22: "if you destroy a
-- level 2 city, it should become a level 1 city"). A structure above level 1
-- drops one level at zero and starts the next with a FULL pool -- the nuke's
-- decreaseLevel rule, so the same counters, station sync and client event
-- move -- and is razed only when level 1 goes. Battery, airfield and post
-- never upgrade, so for them zero is still the end.
function Units.damageStructure(sim: any, u: Unit, damage: number, attackerId: number?): boolean
	if not u.active or damage <= 0 then
		return false
	end
	if u.health - damage <= 0 and u.level > 1 then
		if attackerId ~= nil and u.ext ~= nil then
			u.ext.lastCombatTick = sim.tick
		end
		-- Refill BEFORE the drop so decreaseLevel's one event already carries
		-- the new level with no health bar (hp nil is "unhurt").
		u.health = Units.maxHealth(u)
		Units.decreaseLevel(sim, u, attackerId)
		return false
	end
	Units.modifyHealth(sim, u, -damage, attackerId)
	-- Still standing: tell the clients how much of it is left (the razed case
	-- has already gone out through Units.delete).
	if u.active then
		emit(sim, u, true)
	end
	return not u.active
end

-- Upstream UnitImpl.addVeterancyProgress (UnitImpl.ts:663-688).
--
-- The integer trick is worth preserving exactly. One level costs
-- transportKills * tradeCaptures = 10 * 25 = 250 points; a transport kill
-- is worth 25 (the capture threshold) and a trade capture 10 (the transport
-- threshold). So ten transports OR twenty-five captures OR any mix fills
-- exactly one level, with no floats anywhere. Overflow carries.
local function addVeterancyProgress(sim: any, u: Unit, fromTransport: boolean)
	if u.utype ~= Units.GUNBOAT then
		return
	end
	if u.veterancy >= Units.MAX_VETERANCY then
		return
	end
	local perLevel = Units.VETERANCY_TRANSPORT_KILLS * Units.VETERANCY_TRADE_CAPTURES
	u.veterancyProgress += fromTransport and Units.VETERANCY_TRADE_CAPTURES
		or Units.VETERANCY_TRANSPORT_KILLS
	while u.veterancyProgress >= perLevel and u.veterancy < Units.MAX_VETERANCY do
		u.veterancyProgress -= perLevel
		u.veterancy += 1
	end
	if u.veterancy >= Units.MAX_VETERANCY then
		u.veterancyProgress = 0
	end
end

-- Upstream UnitImpl.recordKill (UnitImpl.ts:632-644). Sinking an enemy
-- GUNBOAT is an instant level and wipes the partial progress; a transport
-- is partial progress. The gunboat is NOT healed on promotion -- it heals
-- toward the higher cap normally (:616-618).
function Units.recordKill(sim: any, u: Unit, targetType: number)
	if u.utype ~= Units.GUNBOAT then
		return
	end
	if targetType == Units.GUNBOAT then
		u.veterancyProgress = 0
		if u.veterancy < Units.MAX_VETERANCY then
			u.veterancy += 1
		end
	elseif targetType == Units.TRANSPORT_BOAT then
		addVeterancyProgress(sim, u, true)
	end
end

-- Upstream UnitImpl.recordTradeCapture (UnitImpl.ts:646-651).
function Units.recordTradeCapture(sim: any, u: Unit)
	addVeterancyProgress(sim, u, false)
end

-- ============================================================= cooldowns ==

-- Upstream UnitImpl.launch / reloadMissile / isInCooldown
-- (UnitImpl.ts:519-543). The queue holds the tick each missile left, one
-- entry per tube in use; a launcher is spent when it has as many entries as
-- it has levels. MissileSiloExecution reads the FRONT entry to decide when
-- the earliest one has finished reloading (MissileSiloExecution.ts:26-37).
function Units.launch(sim: any, u: Unit)
	u.missileTimers[#u.missileTimers + 1] = sim.tick
	emit(sim, u, true)
end

function Units.reload(sim: any, u: Unit)
	table.remove(u.missileTimers, 1)
	emit(sim, u, true)
end

function Units.inCooldown(u: Unit): boolean
	return #u.missileTimers >= u.level
end

function Units.frontTimer(u: Unit): number?
	return u.missileTimers[1]
end

-- ============================================================== transport ==

-- The absolute list a joining client gets, in a deterministic order (type
-- ascending, then spawn order). Same discipline as Economy.
-- snapshotStructures (Economy:1265-1271) and Sim.armies: ids and numbers
-- only, no names, no nested tables.
--
-- Allocating is fine here -- this runs once per player joining, not per
-- tick.
function Units.snapshot(sim: any): { any }
	local out = {}
	for t = 1, Units.TYPE_COUNT do
		for _, u in sim.unitsByType[t] do
			if u.active then
				local x = u.tile % W
				out[#out + 1] = {
					id = u.id,
					kind = u.utype,
					tile = u.tile,
					ownerId = u.ownerId,
					level = u.level,
					x = x,
					y = (u.tile - x) / W,
					uc = u.underConstruction,
				}
			end
		end
	end
	return out
end

-- Order-stable full iteration. NEVER walk sim.units with pairs(): its order
-- is a hash order, it is not the same on two machines, and both the server
-- and ConquestSimClient run this simulation.
function Units.forEach(sim: any, fn: (Unit) -> ())
	for t = 1, Units.TYPE_COUNT do
		local list = sim.unitsByType[t]
		for i = #list, 1, -1 do
			local u = list[i]
			if u.active then
				fn(u)
			end
		end
	end
end

return Units
