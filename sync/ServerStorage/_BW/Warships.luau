--!strict
-- Conquest :: Warships  (shared module; the server drives it)
--
-- THE NAVAL COMBAT LAYER. Ported from upstream
-- (github.com/openfrontio/OpenFrontIO):
--
--   execution/WarshipExecution.ts            (825)  patrol, retreat, dock,
--                                                   target, shoot, hunt
--   execution/ShellExecution.ts              (107)  the shell in flight
--   execution/MoveWarshipExecution.ts        (53)   the player move order
--   execution/nation/NationWarshipBehavior.ts (465) when an AI buys a navy
--   game/Veterancy.ts (23) + game/UnitImpl.ts:612-688  promotion math, which
--                                                   already lives in
--                                                   Conquest.Units
--   configuration/Config.ts:1085-1162        every constant, cited on its line
--
-- WHAT THIS MODULE OWNS: warship units, shells in flight, and the two piracy
-- verbs applied to records it does not own (a transport sunk, a trade ship
-- captured). It owns no gold, no territory and no player state.
--
-- ============================ NOT A PORT ==================================
-- ONE DELIBERATE DESIGN CHANGE, AND IT IS NOT UPSTREAM. Read this before
-- comparing anything below against OpenFrontIO.
--
-- Upstream SELLS warships: ConstructionExecution charges
-- min(1,000,000, (n + 1) * 250,000) per hull (Config.ts:460-468), and that
-- escalating price is the only thing that bounds a fleet -- there is no cap
-- anywhere in upstream's warship code. Conquest's owner has taken warships off
-- the shopping list entirely: "you only need to buy ports; ships spawn on
-- their own and trading happens automatically". So:
--
--   * A PORT PRODUCES WARSHIPS, FREE, ON A TIMER. One hull every
--     WARSHIP_SPAWN_TICKS per port, spawned at the port and stationed near it.
--   * THE BRAKE IS STRUCTURAL, NOT ECONOMIC. A port sustains
--     WARSHIP_PER_PORT_LEVEL hulls per LEVEL, so the fleet ceiling is the sum
--     of an empire's port levels, hard-capped at WARSHIP_MAX_PER_PLAYER.
--     Upgrading ports IS the naval lever; there is nothing else to buy.
--   * THE AI USES THE IDENTICAL PATH. NationWarshipBehavior's purchases
--     (maybeSpawnWarship's 1-in-50 roll, the retaliation build, the
--     infestation counter-build) are all GONE. What survives of that file is
--     its judgement about WHERE a squadron should be, which is now the only
--     naval decision an AI makes.
--   * MOVING A FLEET IS STILL FREE AND STILL EXISTS (Warships.move). It is a
--     command, not a purchase, so it does not conflict with the brief.
--
-- Trade is untouched: Economy already spawns trade ships on its own timer and
-- picks partners itself, which is the same hands-off shape.
-- ==========================================================================
--
-- WHERE IT SITS. A warship is a Units record (Units.WARSHIP), so it lives in
-- the one spatial grid and gets health, maxHealth and veterancy for free --
-- see Conquest.Units. So does every one of its prey, now: Sim's transports
-- (Sim.launchBoat :1370) and Economy's trade ships (Economy:121-126, :1056)
-- have both moved into Units since this module landed, and findBestTarget is a
-- single nearbyUnits call over the three types as a result -- which is exactly
-- what upstream writes (WarshipExecution.ts:259-263). The 128-tile side index
-- this file used to keep for the two that were not Units is deleted.
--
-- THREE FIELDS ARE WRITTEN ONTO ext TABLES THIS MODULE DOES NOT OWN, every one
-- prefixed w so it is obviously foreign:
--   tradeShip.ext.wSafeUntil  tick this trade ship stops being safe from
--                             pirates (UnitImpl.isSafeFromPirates :601-606).
--                             Stamped when a warship considers it and finds it
--                             hugging a shoreline.
--   tradeShip.ext.wPirate     the player id that captured it. Economy pays the
--                             gold to this one instead of to the two ports --
--                             see the integration hunk.
--   transport.ext.wDealt      an AI has already answered this incoming
--                             transport (NationWarshipBehavior:27).
-- Writing a field is not editing a module, and it dies with the record it is
-- written on, which a side table keyed by id would not.
--
-- FIVE DELIBERATE DIVERGENCES, each measured against what Conquest already is
-- rather than against upstream's engine:
--
--   * A SHELL IS NOT A UNIT. Upstream builds a real Shell unit per shot
--     (ShellExecution.ts:29) so its renderer can draw one. Here a shell is a
--     plain record in sim.shells: nothing ever targets a shell, it has no
--     health, and a warship firing at a TRANSPORT does not reload at all
--     (WarshipExecution.ts:638-641), so the unit form would push a table, a
--     grid insert, a grid remove and two unit events through Units for a
--     projectile that lives twenty ticks. Damage, lifetime, the three steps a
--     tick and the veterancy bonus are ported exactly.
--
--   * PATHING IS GREEDY FIRST, COARSE A* SECOND. Upstream gives every warship
--     its own resumable tile-level WaterPathFinder (WarshipExecution.ts:35).
--     Conquest's water search is Navy's, over a stride-8 grid, and it is
--     expensive enough that transports are rationed to ONE launch a tick
--     (Config.BOAT_LAUNCHES_PER_TICK, Config:70-73). A patrol leg is at most
--     100 tiles of open water, which a greedy water step solves without any
--     search; the coarse path is the fallback for a step that is blocked, and
--     it draws from a global per-tick budget for exactly the reason boats do.
--
--   * A CAPTURED TRADE SHIP IS NOT RE-ROUTED. Upstream sends it to the
--     captor's nearest port and pays the captor on arrival
--     (TradeShipExecution.ts:102-127, :171-181). Re-routing costs a fresh sea
--     search per capture against a budget of one a tick (Economy:119-123), so
--     here the ship keeps its route and the PAYOUT moves instead: the pirate
--     collects, both ports collect nothing. Same economic transfer, no search.
--
--   * NO DOOMSDAY CLOCK. WarshipExecution.tick:77-82 and healWarship:138 both
--     branch on owner.inDoomsdayClock(). Conquest has no such mode, so those
--     branches are dropped rather than stubbed.
--
--   * NO RELATIONS, NO EMOJI. NationWarshipBehavior:253-254 sends an emoji and
--     moves a relation number by -7.5 (trade) or -15 (transport). Conquest has
--     neither system, so retaliation is the warship alone.

local Config = require(script.Parent.Config)
local TileMap = require(script.Parent.TileMap)
local Navy = require(script.Parent.Navy)
local Units = require(script.Parent.Units)
local Economy = require(script.Parent.Economy)

local W = Config.MAP_W
local H = Config.MAP_H
local N = Config.NUM_TILES

local Warships = {}

-- ================================================================ numbers ==
--
-- Read through cfg() so this module runs correctly BEFORE the Conquest.Config
-- hunk lands and picks the shared value up the moment it does. Every fallback
-- is upstream's literal, cited on its line.

local function cfg(name: string, fallback: number): number
	local v = (Config :: any)[name]
	if type(v) == "number" then
		return v
	end
	return fallback
end

local PATROL_RANGE = cfg("WARSHIP_PATROL_RANGE", 100) -- Config.ts:1089-1091
local TARGET_RANGE = cfg("WARSHIP_TARGET_RANGE", 130) -- Config.ts:1093-1095
local SHELL_RATE = cfg("WARSHIP_SHELL_ATTACK_RATE", 20) -- Config.ts:1097-1099
local DOCK_RANGE = cfg("WARSHIP_DOCKING_RANGE", 5) -- Config.ts:1101-1103
local PORT_HEAL_PER_LEVEL = cfg("WARSHIP_PORT_HEALING_PER_LEVEL", 5) -- :1105-1107
local RETREAT_PERCENT = cfg("WARSHIP_RETREAT_HEALTH_PERCENT", 75) -- :1109-1113
local PASSIVE_HEAL = cfg("WARSHIP_PASSIVE_HEALING", 1) -- Config.ts:1115-1117
local PASSIVE_HEAL_RANGE = cfg("WARSHIP_PASSIVE_HEALING_RANGE", 150) -- :1119-1121
local PORT_SWITCH = cfg("WARSHIP_PORT_SWITCH_THRESHOLD", 0.75) -- :1123-1125
local VET_DAMAGE_BONUS = cfg("WARSHIP_VETERANCY_SHELL_DAMAGE_BONUS", 20) -- :1142-1144
local SHELL_LIFETIME = cfg("SHELL_LIFETIME", 50) -- Config.ts:1085-1087
local PIRATE_SAFE_TICKS = cfg("SAFE_FROM_PIRATES_TICKS", 20) -- Config.ts:1160-1162

-- Upstream's warship covers one pathfinder step a tick on patrol
-- (WarshipExecution.patrol :725-742) and two while hunting (:661), and its
-- shell covers three (ShellExecution.ts:48). A Conquest trade ship covers
-- Config.TRADE_SHIP_SPEED = 1, so hunting at 2 still closes on one; a
-- transport covers Config.BOAT_SPEED = 3, which a warship cannot catch and is
-- not supposed to -- it shells transports, it does not chase them.
local WARSHIP_SPEED = cfg("WARSHIP_SPEED", 1)
local HUNT_SPEED = cfg("WARSHIP_HUNT_SPEED", 2)
local SHELL_SPEED = cfg("SHELL_SPEED", 3)

-- Coarse water searches a tick, across the whole server. Same rationing, and
-- the same reason, as Config.BOAT_LAUNCHES_PER_TICK.
local PATH_BUDGET = cfg("WARSHIP_PATH_BUDGET", 2)
-- How often the per-player port index is rebuilt. Ports are built in seconds
-- and captured in seconds; a one-second-stale list costs a warship one tick of
-- steering and saves a walk of sim.structList per warship per tick.
local PORT_CACHE_TICKS = cfg("WARSHIP_PORT_CACHE_TICKS", 10)

-- WarshipExecution.ts:184. A manual move order suppresses the repair retreat
-- for 50 ticks, so ordering a damaged ship somewhere is not silently undone.
local MANUAL_MOVE_BLOCK = 50

-- ---- PORT PRODUCTION. Conquest's own, not upstream's -- see the header. ----
--
-- WHY 600 TICKS (60 s), from arithmetic rather than taste:
--
--   * The old price was 500,000 gold. At Config.GOLD_PER_TICK = 100 that is
--     5,000 ticks of a human's entire income -- eight minutes of a match that
--     ends around sixteen. As a timer that is not a build rate, it is a
--     lifetime, so the price does not convert.
--   * The CAP, not the timer, sets how many hulls exist. The timer only sets
--     how fast a squadron FILLS and how fast a loss is REPLACED, so it has to
--     be read against the combat loop, not against the treasury.
--   * A duel is four to five shells at WARSHIP_SHELL_ATTACK_RATE 20, so 80 to
--     100 ticks, and a full retreat-and-repair cycle is 100 to 250 (measured:
--     200 health to full at a level-2 port is 70 ticks of healing plus the
--     sail home). Replacement MUST be dearer than repair or the whole
--     retreat/dock half of WarshipExecution becomes dead code -- you would
--     just let a hurt ship sink. 600 is 2.4x the repair cycle.
--   * It must be affordable inside one match: at 600 a level-3 port fills its
--     squadron in 1,800 ticks (3 min, ~19% of a 16-minute match) and a single
--     port emits at most 16 hulls all game, so attrition is possible but not
--     free.
--   * And a port has to feel like it did something: the first hull arrives
--     60 s after the port finishes (Config.PORT_BUILD_TICKS is 50).
local SPAWN_TICKS = cfg("WARSHIP_SPAWN_TICKS", 600)
-- Hulls per port LEVEL. Config.STRUCTURE_MAX_LEVEL is 10, so one maxed port
-- alone would reach the hard cap below.
local PER_PORT_LEVEL = cfg("WARSHIP_PER_PORT_LEVEL", 1)
-- The hard ceiling per empire, on top of the port-level sum. Upstream's AI
-- stops at ten (NationWarshipBehavior.ts:233, :333) and that is the only
-- number upstream ever puts on a fleet, so it is the one borrowed here.
local MAX_PER_PLAYER = cfg("WARSHIP_MAX_PER_PLAYER", 10)
-- How far from its home port a new hull is stationed. Half the patrol radius,
-- so a port's squadron spreads over its own approaches instead of stacking on
-- the harbour mouth.
local SPAWN_PATROL_RADIUS = cfg("WARSHIP_SPAWN_PATROL_RADIUS", 50)
-- How many un-answered piracy events an AI queues. Upstream keeps Sets of
-- every ship it has ever owned and re-walks them every think
-- (NationWarshipBehavior.ts:21-27); this module knows the exact moment a
-- transport dies or a trade ship changes hands, so it can push the event
-- instead of polling for it. Four is more than one think can act on.
local RETALIATE_QUEUE_MAX = 4

local SHELL_INFO = Units.INFO[Units.SHELL]
local SHELL_BASE_DAMAGE = (SHELL_INFO and SHELL_INFO.damage) or 250 -- Config.ts:469-474

Warships.PATROL_RANGE = PATROL_RANGE
Warships.TARGET_RANGE = TARGET_RANGE

-- Marker kind on the vehicle wire. 1 trade ship, 2 train (Economy), 3
-- transport (Sim), so a warship is 4 and a shell is 5.
Warships.VEHICLE_WARSHIP = 4
Warships.VEHICLE_SHELL = 5
-- A warship needs NO id offset: it is a unit, and trade ships, trains and
-- transports are units too now, so all four draw from the one counter and
-- cannot collide (Economy.vehicles :1439-1441, Sim.vehicles :638-642). A SHELL
-- is not a unit (see the header) and numbers itself from sim.nextShellId, so
-- that one counter does still have to be lifted clear of the unit ids.
local SHELL_VEHICLE_ID_BASE = 100000000

local PORT_KIND = Economy.PORT

-- =============================================================== geometry ==

local function tx(tile: number): number
	return tile % W
end

local function ty(tile: number): number
	return (tile - tile % W) / W
end

local function dist2(a: number, b: number): number
	local ax, bx = a % W, b % W
	local ay = (a - ax) / W
	local by = (b - bx) / W
	return (ax - bx) * (ax - bx) + (ay - by) * (ay - by)
end

local function manhattan(a: number, b: number): number
	local ax, bx = a % W, b % W
	local ay = (a - ax) / W
	local by = (b - bx) / W
	return math.abs(ax - bx) + math.abs(ay - by)
end

local function isWater(sim: any, tile: number): boolean
	return not TileMap.isLand(sim.map, tile)
end

-- Upstream mg.isShoreline(tile) for a WATER tile: water that touches land.
-- Derived from the 4-neighbours rather than read off the terrain byte's shore
-- bit for the reason Economy gives at :524-526 -- that bit is MapGen's and
-- means something slightly different.
local function isShoreWater(sim: any, tile: number): boolean
	local map = sim.map
	if TileMap.isLand(map, tile) then
		return false
	end
	local x = tile % W
	local y = (tile - x) / W
	if x > 0 and TileMap.isLand(map, tile - 1) then
		return true
	end
	if x < W - 1 and TileMap.isLand(map, tile + 1) then
		return true
	end
	if y > 0 and TileMap.isLand(map, tile - W) then
		return true
	end
	if y < H - 1 and TileMap.isLand(map, tile + W) then
		return true
	end
	return false
end

-- Upstream mg.getWaterComponent(tile) / hasWaterComponent(tile, comp), which
-- is what stops a warship being ordered into a lake it cannot reach and what
-- makes an unreachable target an O(1) refusal rather than an exhausted search.
-- Navy already holds exactly this, per coarse cell (Navy:34-44).
local function waterComp(sim: any, tile: number): number?
	local nav = sim.nav
	if nav == nil then
		return nil
	end
	local c = Navy.waterCellNear(nav, sim.map, tile)
	if c == nil then
		return nil
	end
	local comp = nav.comp[c + 1]
	if comp == 0 then
		return nil
	end
	return comp
end

-- Upstream warshipSpawnTile (NationWarshipBehavior.ts:68-89): probe a box
-- around a tile for anything wet, give up after fifty tries. Used for both a
-- new hull's patrol station and for the AI's re-stationing.
local function randomWaterNear(sim: any, tile: number, radius: number): number?
	local rng = sim.warshipRng
	local x0 = tile % W
	local y0 = (tile - x0) / W
	for _ = 1, 50 do
		local x = x0 + rng:NextInteger(-radius, radius)
		local y = y0 + rng:NextInteger(-radius, radius)
		if x >= 0 and x < W and y >= 0 and y < H then
			local t = y * W + x
			if not TileMap.isLand(sim.map, t) then
				return t
			end
		end
	end
	return nil
end

-- Sim.sameTeam (Sim:395-404), inlined so this module does not require Sim --
-- Sim requires Economy and Units, and a cycle through either would break the
-- load order. Upstream's test is owner.canAttackPlayer(other, true), which is
-- team plus alliance; Conquest has teams only.
local function friendly(sim: any, a: number, b: number): boolean
	if a == b then
		return true
	end
	if (sim.teamCount or 0) <= 0 then
		return false
	end
	local ta = sim.teamOf[a]
	return ta ~= nil and ta == sim.teamOf[b]
end

-- ================================================================== state ==

-- Safe to call twice, like Units.init (Units:393-394), so a hot reload during
-- development does not wipe a live round.
function Warships.init(sim: any)
	Units.init(sim)
	sim.shells = sim.shells or {}
	sim.nextShellId = sim.nextShellId or 1
	sim.warshipPorts = sim.warshipPorts or {}
	sim.warshipPortsTick = sim.warshipPortsTick or -1000000
	sim.warshipPathBudget = sim.warshipPathBudget or 0
	sim.warshipRetaliate = sim.warshipRetaliate or {}
	-- ITS OWN STREAM, deliberately. Drawing from sim.rng would shift every
	-- draw every other system makes and re-roll the whole match -- the same
	-- trap Config:841-846 documents for the think period. Seeded from the
	-- round seed so the server and a client-side sim still agree.
	sim.warshipRng = sim.warshipRng or Random.new((sim.seed or 0) * 31 + 977)
end

-- A warship's per-type state. Upstream keeps this in WarshipState on the unit
-- (UnitImpl.ts:90-96) plus five fields on the execution object
-- (WarshipExecution.ts:22-27); one ext table is the same idea in one place.
local function newExt(sim: any, patrolTile: number): any
	return {
		patrolTile = patrolTile,
		-- patrolling | retreating | docked (WarshipExecution.ts:80, :84, :347)
		state = "patrolling",
		retreatPort = nil :: number?,
		-- Upstream starts lastShellAttack at 0, which in a running match is
		-- always more than shellAttackRate ago: a fresh warship may fire at
		-- once. Written explicitly so a ship built on tick 3 can too.
		lastShellAttack = -SHELL_RATE - 1,
		-- Targets already sent a one-shot shell, so a second is not wasted
		-- (WarshipExecution.ts:650-655). Keyed by unit ID, not by the record,
		-- so a sunk transport is not kept alive by this table.
		shelled = {} :: { [number]: boolean },
		healRemainder = 0,
		lastManualMoveTick = -1000000,
		lastPatrolSeen = patrolTile,
		-- The prey unit itself. Upstream keeps it on the unit as targetUnit
		-- (UnitImpl.ts:175); here it stays in ext because Units' targetUnitId
		-- is a wire field and this is a live reference.
		target = nil :: any,
		inCombat = false,
		lastCombatTick = -1000000,
		-- Coarse route, only ever present when a greedy step failed.
		path = nil :: { number }?,
		pathIdx = 1,
		pathDst = nil :: number?,
		blocked = 0,
	}
end

-- ============================================================= port index ==
--
-- Upstream asks owner.units(UnitType.Port) inside eight different functions,
-- every one of them per warship per tick. Conquest's ports are Economy
-- structures in one flat sim.structList with no per-player view, so the walk
-- would be O(structures) eight times over. One index, rebuilt on a slow clock.

local EMPTY: { any } = {}

local function refreshPorts(sim: any)
	if sim.structList == nil then
		return
	end
	if sim.tick - sim.warshipPortsTick < PORT_CACHE_TICKS then
		return
	end
	sim.warshipPortsTick = sim.tick
	local byPlayer = sim.warshipPorts
	for _, list in byPlayer do
		table.clear(list)
	end
	for _, s in sim.structList do
		if s.kind == PORT_KIND then
			local list = byPlayer[s.ownerId]
			if list == nil then
				list = {}
				byPlayer[s.ownerId] = list
			end
			list[#list + 1] = s
		end
	end
end

-- The cached list can be up to PORT_CACHE_TICKS stale, so every read validates
-- against the live index. structAt is Economy's authority for "this structure
-- is still standing on this tile" (Economy:469, :479).
local function portsOf(sim: any, playerId: number): { any }
	return sim.warshipPorts[playerId] or EMPTY
end

local function portLives(sim: any, s: any): boolean
	return sim.structAt[s.tile] == s
end

-- =========================================================== production ====
--
-- CONQUEST'S OWN, NOT A PORT OF ANYTHING (see the header). Upstream has no
-- equivalent: there, a hull appears because somebody paid for it.
--
-- The ceiling is the sum of the empire's COMPLETED port levels, clamped by
-- MAX_PER_PLAYER so no amount of coastline produces an unbounded fleet. An
-- empire already over its ceiling -- it lost the port its squadron came from
-- -- simply stops producing; the hulls it has are not scuttled, exactly as
-- upstream never scuttles a fleet whose owner went broke.
--
-- READ OFF Units, NOT off the port cache below, and both halves of that matter.
-- levelSum is `levels - uc` (Units:508-511), so a port still going up does not
-- yet sustain a squadron -- gold spent is not a harbour. And it is LIVE, where
-- the cache is up to PORT_CACHE_TICKS stale: losing your last port has to shut
-- the yard on the tick it happens, not a second later. It is also O(1) against
-- a walk, and this runs once per empire per tick inside production.
local function fleetCap(sim: any, playerId: number): number
	local cap = Units.levelSum(sim, playerId, Units.PORT) * PER_PORT_LEVEL
	if cap > MAX_PER_PLAYER then
		return MAX_PER_PLAYER
	end
	return cap
end

Warships.fleetCap = fleetCap

-- One timer per PORT, carried on the port record as wNextWarship (the foreign
-- field convention from the header). Per port rather than per empire on
-- purpose: three level-1 ports fill a three-hull squadron three times faster
-- than one level-3 port does, while both ceilings are the same three. Spread
-- coastline buys tempo, concentrated coastline buys a fortress.
--
-- The port list is COMPLETED ports only, for free: Economy.add is called when
-- a construction site is promoted to a station, so a port that is still going
-- up is a Unit but not yet a Structure and never reaches this loop.
--
-- Iteration is over playerOrder, never over the port index with pairs(): this
-- both spends the shared warshipRng and creates units, and a hash order is not
-- the same on two machines.
local function stepPortProduction(sim: any)
	local order = sim.playerOrder
	if order == nil then
		return
	end
	for _, playerId in order do
		local ports = portsOf(sim, playerId)
		if #ports > 0 then
			local p = sim.players[playerId]
			if p ~= nil and p.alive and p.spawned then
				local have = Units.stats(sim, playerId, Units.WARSHIP).n
				local cap = fleetCap(sim, playerId)
				for _, s in ports do
					if portLives(sim, s) then
						local due = s.wNextWarship
						if due == nil then
							-- A port just built (or just captured) starts its
							-- clock now rather than emitting instantly.
							s.wNextWarship = sim.tick + SPAWN_TICKS
						elseif sim.tick >= due then
							if have >= cap then
								-- At the ceiling the yard idles but the clock
								-- does NOT bank: a loss is replaced a full
								-- SPAWN_TICKS later, never instantly.
								s.wNextWarship = sim.tick + SPAWN_TICKS
							else
								s.wNextWarship = sim.tick + SPAWN_TICKS
								local station = randomWaterNear(sim, s.tile, SPAWN_PATROL_RADIUS)
								if station ~= nil then
									-- Spawned ON the port tile, as upstream
									-- does (PlayerImpl.warshipSpawn :1591-1608
									-- returns the port's own tile), and
									-- stationed on open water near it.
									Units.spawn(sim, Units.WARSHIP, playerId, s.tile, {
										ext = newExt(sim, station),
									})
									have += 1
								end
							end
						end
					end
				end
			end
		end
	end
end

-- ============================================================= targeting ===

local TGT_OUT: { any } = {}
local TGT_D2: { number } = {}

-- Upstream's own type lists, in upstream's own order: the full one from
-- findTargetUnit (WarshipExecution.ts:238-240) and the retreat one from
-- findRetreatAggroTarget (:233). Shared upvalues, never mutated -- building
-- either per call would allocate once per warship per tick.
local PREY_ALL = { Units.TRANSPORT_SHIP, Units.WARSHIP, Units.TRADE_SHIP }
local PREY_NO_TRADE = { Units.TRANSPORT_SHIP, Units.WARSHIP }

-- Upstream's typePriority (:322-323). Lower wins; distance breaks the tie.
local function typePriority(utype: number): number
	if utype == Units.TRANSPORT_SHIP then
		return 0
	elseif utype == Units.WARSHIP then
		return 1
	end
	return 2
end

-- Upstream findBestTarget (WarshipExecution.ts:251-337), and now a straight
-- port of it: ONE nearbyUnits call over the three prey types.
--
-- This function used to be twice this long and carried its own 128-tile index
-- of transports and trade ships, because when the navy landed neither was a
-- Unit -- a transport was a Sim.Boat record and a trade ship was an anonymous
-- Economy table with float x/y and no tile. Both have since moved into Units
-- (Economy:121-126, Sim.launchBoat :1370), so all three prey sit in the one
-- spatial grid and the second index is deleted. Nothing about the SELECTION
-- RULE changed with it.
--
-- THAT DELETION IS NOT FREE, AND THE NUMBER IS ON RECORD. Measured in a live
-- 72-empire match at its busiest (33 hulls, 197 trade ships afloat):
--
--   one 3-type nearbyUnits per hull  (this)        0.749 ms/tick
--   1-type query + index rebuild + 3x3 scan (old)  0.384 ms/tick
--
-- so the simple shape costs 1.95x, or +0.37 ms against a 100 ms tick -- 0.4%
-- of the budget, next to Sim.step's 1.88 ms. It is paid deliberately: the
-- private index duplicated an index Units already maintains, it was the one
-- thing in this file that broke when Economy and Sim migrated their ships, and
-- without it this function is line-for-line upstream's.
--
-- THE COST IS DRIVEN BY TRADE TRAFFIC, not by fleet size: Units.CELL is 32, so
-- radius 130 is a 9x9 = 81-cell sweep and each of the three type buckets is
-- looked up in every cell. If trade traffic grows well past ~200 ships afloat,
-- or the tick budget tightens, re-reading those numbers is the first thing to
-- do -- the fix is a coarser cell for ship types in Units, which helps every
-- caller, not a second index here, which helped only this one.
--
-- includeTrade false is upstream's [TransportShip, Warship] call (:232-234),
-- used while retreating.
local function findBestTarget(sim: any, u: any, includeTrade: boolean): any
	local ext = u.ext
	local owner = u.ownerId
	local types = includeTrade and PREY_ALL or PREY_NO_TRADE
	local n = Units.nearby(sim, u.tile, TARGET_RANGE, types, TGT_OUT, TGT_D2)

	-- Trade-ship-only state, computed lazily exactly as upstream does
	-- (:265-269): the reachable-port test walks the owner's ports, and most
	-- warships never see a trade ship at all.
	local hasReachablePort: boolean? = nil
	local patrolTile = ext.patrolTile
	local patrolR2 = PATROL_RANGE * PATROL_RANGE

	local best: any = nil
	local bestPrio = 99
	local bestD2 = math.huge

	for i = 1, n do
		local other = TGT_OUT[i]
		local d2v = TGT_D2[i]
		local utype = other.utype
		local prio = typePriority(utype)
		if
			other ~= u
			and not friendly(sim, owner, other.ownerId)
			-- Upstream's alreadySentShell set (:650-655): a one-shot target
			-- already has a shell in the air.
			and not ext.shelled[other.id]
			and (prio < bestPrio or (prio == bestPrio and d2v < bestD2))
		then
			local ok = true
			if utype == Units.WARSHIP then
				-- A docked warship is not a target (:281-282): it is in a port
				-- healing, and shooting it would make the retreat pointless.
				local oext = other.ext
				ok = oext == nil or oext.state ~= "docked"
			elseif utype == Units.TRADE_SHIP then
				if hasReachablePort == nil then
					hasReachablePort = false
					local comp = waterComp(sim, u.tile)
					if comp ~= nil then
						for _, port in portsOf(sim, owner) do
							if portLives(sim, port) and waterComp(sim, port.tile) == comp then
								hasReachablePort = true
								break
							end
						end
					end
				end
				local oext = other.ext
				-- safeFromPirates. Upstream stamps this inside the trade
				-- ship's own movement, on every shoreline step
				-- (TradeShipExecution.ts:153-156). That movement is Economy's
				-- here and this module may not write it, so the test is
				-- applied to the ship actually being considered -- the only
				-- ship for which the answer can change anything -- and the
				-- 20-tick cooldown is then carried on its ext exactly as
				-- UnitImpl carries lastSetSafeFromPirates (:601-606).
				if oext ~= nil and isShoreWater(sim, other.tile) then
					oext.wSafeUntil = sim.tick + PIRATE_SAFE_TICKS
				end
				local safeUntil = oext and oext.wSafeUntil or nil
				local dstOwner = (oext and oext.dst and oext.dst.ownerId) or 0
				ok = hasReachablePort == true
					and patrolTile ~= nil
					and (safeUntil == nil or sim.tick >= safeUntil)
					-- Never pirate a ship on its way to one of our own or a
					-- friend's ports (:310-312).
					and not friendly(sim, owner, dstOwner)
					-- And never past the patrol radius of where this ship was
					-- told to sit (:315-319).
					and dist2(patrolTile, other.tile) <= patrolR2
			end
			if ok then
				best = other
				bestPrio = prio
				bestD2 = d2v
			end
		end
	end

	return best
end

-- =============================================================== movement ==

-- Upstream bestNeighborToward (WarshipExecution.ts:702-715): the neighbouring
-- WATER tile that reduces the manhattan distance most. Eight-connected rather
-- than upstream's four, because Conquest's boats already move that way
-- (Sim.stepBoats :1416-1418) and a four-connected navy next to eight-connected
-- transports visibly loses races it should win.
local function greedyStep(sim: any, u: any, dst: number): boolean
	local map = sim.map
	local ux = u.tile % W
	local uy = (u.tile - ux) / W
	local dx0 = dst % W
	local dy0 = (dst - dx0) / W
	local best = -1
	local bestD = math.abs(ux - dx0) + math.abs(uy - dy0)

	for oy = -1, 1 do
		for ox = -1, 1 do
			if ox ~= 0 or oy ~= 0 then
				local nx = ux + ox
				local ny = uy + oy
				if nx >= 0 and nx < W and ny >= 0 and ny < H then
					local t = ny * W + nx
					if not TileMap.isLand(map, t) then
						local d = math.abs(nx - dx0) + math.abs(ny - dy0)
						if d < bestD then
							bestD = d
							best = t
						end
					end
				end
			end
		end
	end

	if best < 0 then
		return false
	end
	Units.move(sim, u, best)
	return true
end

-- One coarse route, off the tick's global budget. Every caller treats a
-- refusal as "not this tick" and simply asks again next tick, exactly as
-- Economy treats a spent seaPathBudget.
local function requestPath(sim: any, u: any, dst: number): boolean
	if sim.warshipPathBudget <= 0 then
		return false
	end
	sim.warshipPathBudget -= 1
	local path = Navy.path(sim.nav, sim.map, u.tile, dst)
	local ext = u.ext
	ext.path = path
	ext.pathIdx = 1
	ext.pathDst = dst
	return path ~= nil and #path > 0
end

-- Move up to `steps` tiles toward `dst`. Returns true once the ship is on it
-- or beside it -- upstream's PathStatus.COMPLETE, which is also how it decides
-- a patrol leg is finished (:730-732).
local function sailToward(sim: any, u: any, dst: number, steps: number): boolean
	local ext = u.ext
	if ext.pathDst ~= dst then
		ext.path = nil
		ext.pathIdx = 1
		ext.pathDst = dst
		ext.blocked = 0
	end

	for _ = 1, steps do
		if u.tile == dst then
			return true
		end
		local aim = dst
		local path = ext.path
		if path ~= nil then
			local wp = path[ext.pathIdx]
			while wp ~= nil and manhattan(u.tile, wp) <= 2 do
				ext.pathIdx += 1
				wp = path[ext.pathIdx]
			end
			if wp == nil then
				ext.path = nil
			else
				aim = wp
			end
		end

		if greedyStep(sim, u, aim) then
			ext.blocked = 0
		else
			-- A headland. One wasted tick, then buy a route; if the budget is
			-- spent this tick, wait for the next one rather than thrashing.
			ext.blocked += 1
			if ext.blocked >= 2 then
				ext.blocked = 0
				if ext.path ~= nil then
					-- The route we are on is the thing that is stuck.
					ext.path = nil
					ext.pathDst = nil
				end
				if not requestPath(sim, u, dst) then
					return false
				end
			else
				return false
			end
		end
	end

	return manhattan(u.tile, dst) <= 1
end

-- ================================================================= shells ==

-- Upstream ShellExecution.effectOnTarget (:77-95). PseudoRandom.nextInt is
-- max-EXCLUSIVE (PseudoRandom.ts:44-49), so nextInt(1, 6) rolls 1..5 and the
-- multiplier is one of 200, 225, 250, 275, 300 -- NOT 200..325. Luau's
-- NextInteger is inclusive at both ends, so the port is (1, 5).
local function shellDamage(sim: any, shooter: any): number
	local roll = sim.warshipRng:NextInteger(1, 5)
	local mult = (roll - 1) * 25 + 200
	local vet = shooter and shooter.veterancy or 0
	if vet > 0 then
		mult = (mult * (100 + vet * VET_DAMAGE_BONUS)) // 100
	end
	return math.round(SHELL_BASE_DAMAGE / 250 * mult)
end

-- An AI answers a piracy event by MOVING a hull -- there is nothing to buy any
-- more (see the header). Queued rather than polled: upstream keeps Sets of
-- every ship it has ever owned and re-walks them on every think
-- (NationWarshipBehavior.ts:21-27), while this module knows the exact tick a
-- transport dies or a trade ship changes hands. Only bots read the queue, so
-- only bots get one.
local function queueRetaliation(sim: any, victimId: number, tile: number, enemyId: number, reason: string)
	if victimId == 0 or victimId == enemyId then
		return
	end
	local p = sim.players[victimId]
	if p == nil or not p.alive or not p.isBot then
		return
	end
	local q = sim.warshipRetaliate[victimId]
	if q == nil then
		q = {}
		sim.warshipRetaliate[victimId] = q
	end
	if #q >= RETALIATE_QUEUE_MAX then
		table.remove(q, 1)
	end
	q[#q + 1] = { tile = tile, enemy = enemyId, reason = reason }
end

local function fireShell(sim: any, u: any, target: any)
	local list = sim.shells
	list[#list + 1] = {
		id = sim.nextShellId,
		tile = u.tile,
		ownerId = u.ownerId,
		shooter = u,
		target = target,
		-- Set the moment the firing ship dies; the shell then has
		-- shellLifetime ticks to land (ShellExecution.ts:44-46).
		dieTick = -1,
	}
	sim.nextShellId += 1
end

local function shellImpact(sim: any, sh: any)
	local target = sh.target
	local shooter = sh.shooter
	local utype = target.utype

	if utype == Units.WARSHIP then
		Units.modifyHealth(sim, target, -shellDamage(sim, shooter), sh.ownerId)
		-- Upstream awards the level only when THIS shell landed the killing
		-- blow and the firing ship is still afloat (ShellExecution.ts:59-67).
		if not target.active and shooter.active then
			Units.recordKill(sim, shooter, Units.WARSHIP)
		end
		return
	end

	if utype == Units.TRANSPORT_SHIP and target.active then
		-- A transport has no maxHealth (Config.ts:455-459), so upstream's
		-- hasHealth() is false, its health is the default 1 (UnitImpl.ts:61)
		-- and one shell deletes it. The troops aboard are lost: upstream never
		-- lands them and Units.delete does not refund them either. Sim's own
		-- ordered boat list drops it on its next pass, which is keyed on
		-- exactly the active flag Units.delete clears (Sim.stepBoats :1389).
		local victim = target.ownerId
		local tile = target.tile
		Units.delete(sim, target, sh.ownerId)
		queueRetaliation(sim, victim, tile, sh.ownerId, "transport")
		if shooter.active then
			Units.recordKill(sim, shooter, Units.TRANSPORT_SHIP)
		end
	end
end

-- One tile toward the target, straight through anything. Upstream flies a
-- shell on PathFinding.Air (ShellExecution.ts:23), which ignores terrain
-- entirely, so a Chebyshev step is the whole of it.
local function shellStep(tile: number, dst: number): number
	local x = tile % W
	local y = (tile - x) / W
	local dx0 = dst % W
	local dy0 = (dst - dx0) / W
	local nx = x + (dx0 > x and 1 or (dx0 < x and -1 or 0))
	local ny = y + (dy0 > y and 1 or (dy0 < y and -1 or 0))
	return ny * W + nx
end

local function stepShells(sim: any)
	local list = sim.shells
	local i = 1
	while i <= #list do
		local sh = list[i]
		local target = sh.target
		local dead = false

		if not target.active or target.ownerId == sh.ownerId then
			-- Upstream deletes a shell whose target died or changed hands to
			-- the firing player (ShellExecution.ts:34-42).
			dead = true
		else
			if sh.dieTick < 0 and not sh.shooter.active then
				sh.dieTick = sim.tick + SHELL_LIFETIME
			end
			if sh.dieTick >= 0 and sim.tick >= sh.dieTick then
				dead = true
			else
				for _ = 1, SHELL_SPEED do
					local dst = target.tile
					if sh.tile == dst then
						shellImpact(sim, sh)
						dead = true
						break
					end
					sh.tile = shellStep(sh.tile, dst)
					if sh.tile == dst then
						shellImpact(sim, sh)
						dead = true
						break
					end
				end
			end
		end

		if dead then
			local last = #list
			list[i] = list[last]
			list[last] = nil
		else
			i += 1
		end
	end
end

-- ================================================== healing / repair / dock ==

local DOCK_OUT: { any } = {}

local function isFullyHealed(u: any): boolean
	return u.health >= Units.maxHealth(u)
end

-- Upstream dockedShipsAtPort (WarshipExecution.ts:512-526): our warships
-- inside the docking radius that are not patrolling and are not still on
-- their way in.
local function dockedShipsAtPort(sim: any, u: any, port: any, exclude: any): number
	local n = Units.nearby(sim, port.tile, DOCK_RANGE, Units.WARSHIP, DOCK_OUT)
	local keep = 0
	for i = 1, n do
		local ship = DOCK_OUT[i]
		local ext = ship.ext
		if
			ship ~= exclude
			and ship.ownerId == u.ownerId
			and ext ~= nil
			and ext.state ~= "patrolling"
			and ship.targetTile == nil
		then
			keep += 1
			DOCK_OUT[keep] = ship
		end
	end
	return keep
end

-- A port heals as many ships at once as it has levels (:507-510).
local function isPortFull(sim: any, u: any, port: any, exclude: any): boolean
	return dockedShipsAtPort(sim, u, port, exclude) >= port.level
end

local function currentRetreatPort(sim: any, u: any): any
	local tile = u.ext.retreatPort
	if tile == nil then
		return nil
	end
	for _, s in portsOf(sim, u.ownerId) do
		if s.tile == tile and portLives(sim, s) then
			return s
		end
	end
	return nil
end

-- Upstream applyActiveDockedHealing (:528-555). The pool is split between
-- every ship docked here and the fraction is CARRIED, so two ships sharing a
-- level-1 port heal at half rate rather than at zero.
local function applyActiveDockedHealing(sim: any, u: any)
	local port = currentRetreatPort(sim, u)
	if port == nil then
		return
	end
	local docked = dockedShipsAtPort(sim, u, port, nil)
	local present = false
	for i = 1, docked do
		if DOCK_OUT[i] == u then
			present = true
			break
		end
	end
	if not present or docked == 0 then
		return
	end
	local pool = port.level * PORT_HEAL_PER_LEVEL
	if pool <= 0 then
		return
	end
	local ext = u.ext
	ext.healRemainder += pool / docked
	local whole = math.floor(ext.healRemainder)
	if whole <= 0 then
		return
	end
	ext.healRemainder -= whole
	Units.modifyHealth(sim, u, whole)
end

-- Upstream healWarship (:133-164). Passive healing needs nothing but a port
-- within range; the docked bonus is on top of it.
local function healWarship(sim: any, u: any)
	local r2 = PASSIVE_HEAL_RANGE * PASSIVE_HEAL_RANGE
	for _, s in portsOf(sim, u.ownerId) do
		if portLives(sim, s) and dist2(u.tile, s.tile) <= r2 then
			Units.modifyHealth(sim, u, PASSIVE_HEAL)
			break
		end
	end
	if u.ext.state == "docked" then
		applyActiveDockedHealing(sim, u)
	end
end

-- Upstream nearestAvailablePortTile (:569-602): nearest port, in our water
-- component, that is not already full of healing.
local function nearestAvailablePort(sim: any, u: any, exclude: any): (number?, number)
	local comp = waterComp(sim, u.tile)
	local best: number? = nil
	local bestD = math.huge
	for _, s in portsOf(sim, u.ownerId) do
		if portLives(sim, s) and not isPortFull(sim, u, s, exclude) then
			if comp ~= nil and waterComp(sim, s.tile) == comp then
				local d = dist2(u.tile, s.tile)
				if d < bestD then
					bestD = d
					best = s.tile
				end
			end
		end
	end
	return best, bestD
end

-- Upstream findNearestPort (:205-230): nearest port in our water component,
-- full or not.
local function findNearestPort(sim: any, u: any): number?
	local comp = waterComp(sim, u.tile)
	if comp == nil then
		return nil
	end
	local best: number? = nil
	local bestD = math.huge
	for _, s in portsOf(sim, u.ownerId) do
		if portLives(sim, s) and waterComp(sim, s.tile) == comp then
			local d = dist2(u.tile, s.tile)
			if d < bestD then
				bestD = d
				best = s.tile
			end
		end
	end
	return best
end

local function clearTarget(u: any)
	u.ext.target = nil
end

local function startRepairRetreat(sim: any, u: any)
	local portTile = findNearestPort(sim, u)
	if portTile == nil then
		return
	end
	local ext = u.ext
	ext.retreatPort = portTile
	ext.state = "retreating"
	ext.healRemainder = 0
	clearTarget(u)
end

local function cancelRepairRetreat(u: any, clearTargetTile: boolean)
	local ext = u.ext
	ext.healRemainder = 0
	ext.state = "patrolling"
	ext.retreatPort = nil
	if clearTargetTile then
		u.targetTile = nil
	end
end

-- Upstream shouldStartRepairRetreat (:173-203). The bar is a percentage of the
-- VETERANCY-ADJUSTED max health, so a veteran retreats at the same relative
-- health as a fresh ship, and it is integer math on purpose.
local function shouldStartRepairRetreat(sim: any, u: any, healthBefore: number): boolean
	local ext = u.ext
	if ext.state ~= "patrolling" then
		return false
	end
	if sim.tick - ext.lastManualMoveTick < MANUAL_MOVE_BLOCK then
		return false
	end
	local threshold = (Units.maxHealth(u) * RETREAT_PERCENT) // 100
	if healthBefore >= threshold then
		return false
	end
	return #portsOf(sim, u.ownerId) > 0
end

-- Upstream refreshRetreatPortTile (:461-505): the port we are running to may
-- have been taken, filled up, or been overtaken by a much closer one.
local function refreshRetreatPortTile(sim: any, u: any): boolean
	local ports = portsOf(sim, u.ownerId)
	if #ports == 0 then
		return false
	end
	local ext = u.ext
	local current = ext.retreatPort

	local currentPort: any = nil
	if current ~= nil then
		for _, s in ports do
			if s.tile == current and portLives(sim, s) then
				currentPort = s
				break
			end
		end
	end

	if currentPort == nil then
		local newPort = nearestAvailablePort(sim, u, u)
		ext.retreatPort = newPort
		return newPort ~= nil
	end

	if isPortFull(sim, u, currentPort, nil) then
		local alt = nearestAvailablePort(sim, u, nil)
		if alt ~= nil then
			ext.retreatPort = alt
		end
		return ext.retreatPort ~= nil
	end

	-- A significantly closer port (:608-628). PORT_SWITCH is a ratio on the
	-- SQUARED distance, exactly as upstream applies it.
	local better, betterD = nearestAvailablePort(sim, u, nil)
	if better ~= nil and better ~= current then
		local currentD = dist2(u.tile, current)
		if betterD < currentD * PORT_SWITCH then
			ext.retreatPort = better
		end
	end
	return true
end

local shootTarget: (any, any) -> ()

-- Upstream handleRepairRetreat (:377-459). Returns true when the retreat owns
-- this tick.
local function handleRepairRetreat(sim: any, u: any): boolean
	local ext = u.ext
	if ext.state == "patrolling" then
		return false
	end

	-- Still shoots back on the way home (:382-387).
	local aggro = findBestTarget(sim, u, false)
	if aggro ~= nil then
		ext.target = aggro
		shootTarget(sim, u)
	end

	if not refreshRetreatPortTile(sim, u) then
		cancelRepairRetreat(u, true)
		return false
	end

	if aggro == nil then
		clearTarget(u)
	end

	local portTile = ext.retreatPort
	if portTile == nil then
		return false
	end

	if dist2(u.tile, portTile) <= DOCK_RANGE * DOCK_RANGE then
		local port: any = nil
		for _, s in portsOf(sim, u.ownerId) do
			if s.tile == portTile and portLives(sim, s) then
				port = s
				break
			end
		end
		if port ~= nil and not isPortFull(sim, u, port, u) then
			u.targetTile = nil
			ext.state = "docked"
			return true
		end
		-- The port is full: wait beside it, unless we are already whole.
		if isFullyHealed(u) then
			cancelRepairRetreat(u, true)
			return false
		end
		return true
	end

	-- Upstream's PathStatus.NOT_FOUND branch (:446-455): pick another port, and
	-- give the retreat up if there is none. Navy answers "no route" in O(1)
	-- from the component ids (Navy:153-162), which is the whole reason it
	-- keeps them -- upstream discovers the same thing by exhausting an A*.
	if not Navy.reachable(sim.nav, sim.map, u.tile, portTile) then
		local newPort = nearestAvailablePort(sim, u, u)
		ext.retreatPort = newPort
		if newPort == nil then
			cancelRepairRetreat(u, true)
		end
		return true
	end

	u.targetTile = portTile
	sailToward(sim, u, portTile, WARSHIP_SPEED)
	return true
end

-- ======================================================= combat and hunting ==

-- Upstream shootTarget (:634-657).
function shootTarget(sim: any, u: any)
	local ext = u.ext
	ext.inCombat = true
	ext.lastCombatTick = sim.tick

	if sim.tick - ext.lastShellAttack <= SHELL_RATE then
		return
	end
	local target = ext.target
	if target == nil or not target.active then
		return
	end
	-- Warships do not reload when shooting transports (:638-641).
	if target.utype ~= Units.TRANSPORT_SHIP then
		ext.lastShellAttack = sim.tick
	end
	fireShell(sim, u, target)
	if target.utype == Units.TRANSPORT_SHIP then
		-- One shell kills it, so do not spend a second (:650-655).
		ext.shelled[target.id] = true
		clearTarget(u)
	end
end

-- Upstream huntDownTradeShip (:659-700). Two movement steps a tick, capture at
-- five tiles, and a greedy step when close because a coarse route cannot
-- converge on something moving.
local function huntDownTradeShip(sim: any, u: any)
	local ext = u.ext
	ext.inCombat = true
	ext.lastCombatTick = sim.tick

	for _ = 1, HUNT_SPEED do
		local ship = ext.target
		if ship == nil or not ship.active then
			clearTarget(u)
			return
		end
		local shipTile = ship.tile
		if manhattan(u.tile, shipTile) <= 5 then
			-- Upstream captureUnit is setOwner and nothing else
			-- (PlayerImpl.ts:1279-1284): the hull changes hands here and the
			-- GOLD changes hands on arrival, in Economy.stepShips, keyed off
			-- the wPirate mark below.
			local victim = ship.ownerId
			Units.setOwner(sim, ship, u.ownerId)
			local se = ship.ext
			if se ~= nil then
				se.wPirate = u.ownerId
			end
			Units.recordTradeCapture(sim, u)
			queueRetaliation(sim, victim, shipTile, u.ownerId, "trade")
			clearTarget(u)
			return
		end
		if not sailToward(sim, u, shipTile, 1) then
			return
		end
	end
end

-- Upstream randomTile (:757-824): a water tile inside the patrol radius, in
-- our own water component, with the radius widening after enough failures.
--
-- The bail-out at :772-774 is load-bearing and is kept: a patrolTile that is
-- not a real tile makes every candidate NaN and the loop spins forever,
-- hanging the whole synchronous tick.
local function randomPatrolTile(sim: any, u: any, allowShore: boolean): number?
	local ext = u.ext
	local patrolTile = ext.patrolTile
	if patrolTile == nil or patrolTile < 0 or patrolTile >= N or patrolTile % 1 ~= 0 then
		return nil
	end

	local range = PATROL_RANGE
	local comp = waterComp(sim, u.tile)
	local rng = sim.warshipRng
	local px = patrolTile % W
	local py = (patrolTile - px) / W
	local attempts = 0
	local expands = 0

	while expands < 3 do
		local half = math.max(1, range // 2)
		local x = px + rng:NextInteger(-half, half - 1)
		local y = py + rng:NextInteger(-half, half - 1)
		if x >= 0 and x < W and y >= 0 and y < H then
			local tile = y * W + x
			local ok = isWater(sim, tile) and (allowShore or not isShoreWater(sim, tile))
			if ok and comp ~= nil and waterComp(sim, tile) ~= comp then
				ok = false
			end
			if ok then
				return tile
			end
			attempts += 1
			-- Upstream expands after 500 misses. Conquest's map is 484,000
			-- tiles against upstream's 3,000,000-odd, and this loop runs
			-- inside one synchronous tick, so the count is a quarter of
			-- upstream's -- it is a give-up threshold, not a rule.
			if attempts >= 125 then
				expands += 1
				attempts = 0
				range += range // 2
			end
		end
	end

	if not allowShore then
		return randomPatrolTile(sim, u, true)
	end
	return nil
end

-- Upstream patrol (:717-743).
local function patrol(sim: any, u: any)
	if u.targetTile == nil then
		u.targetTile = randomPatrolTile(sim, u, false)
		if u.targetTile == nil then
			return
		end
	end
	if sailToward(sim, u, u.targetTile, WARSHIP_SPEED) then
		u.targetTile = nil
	end
end

-- Upstream handleManualPatrolOverride (:363-375): a move order suppresses the
-- repair retreat for a while and aborts one already under way.
local function handleManualPatrolOverride(sim: any, u: any)
	local ext = u.ext
	local patrolTile = ext.patrolTile
	if ext.lastPatrolSeen ~= nil and patrolTile ~= ext.lastPatrolSeen then
		ext.lastManualMoveTick = sim.tick
		if ext.state ~= "patrolling" then
			cancelRepairRetreat(u, false)
		end
	end
	ext.lastPatrolSeen = patrolTile
end

-- ============================================================ the ship tick ==

-- Upstream WarshipExecution.tick (:59-131), in its order, minus the two
-- Doomsday Clock branches Conquest has no mode for.
local function tickWarship(sim: any, u: any)
	local ext = u.ext
	if u.health <= 0 then
		Units.delete(sim, u, nil)
		return
	end

	ext.inCombat = false
	local healthBefore = u.health

	healWarship(sim, u)
	handleManualPatrolOverride(sim, u)

	if ext.state == "docked" then
		if currentRetreatPort(sim, u) == nil then
			cancelRepairRetreat(u, true)
		end
		if isFullyHealed(u) then
			cancelRepairRetreat(u, true)
		end
		if ext.state == "docked" then
			return
		end
	end

	if handleRepairRetreat(sim, u) then
		return
	end

	if shouldStartRepairRetreat(sim, u, healthBefore) then
		startRepairRetreat(sim, u)
		if handleRepairRetreat(sim, u) then
			return
		end
	end

	local target = findBestTarget(sim, u, true)
	ext.target = target

	if target ~= nil then
		local utype = target.utype
		-- Priority 1 a transport, 2 an enemy warship: shoot, and keep
		-- patrolling while doing it. Priority 3 a trade ship: chase it down.
		if utype == Units.TRANSPORT_SHIP or utype == Units.WARSHIP then
			shootTarget(sim, u)
			patrol(sim, u)
			return
		end
		if utype == Units.TRADE_SHIP then
			huntDownTradeShip(sim, u)
			return
		end
	end

	patrol(sim, u)
end

-- =================================================================== tick ===

function Warships.step(sim: any)
	if sim.shells == nil then
		Warships.init(sim)
	end
	sim.warshipPathBudget = PATH_BUDGET
	refreshPorts(sim)
	-- Before the ship loop, which walks Units.ofType backwards from its end, so
	-- a hull launched this tick sails on the tick it appears instead of sitting
	-- inert for one.
	stepPortProduction(sim)

	-- Backwards, because deleting a warship swap-removes it from this very
	-- list (Units:750).
	local list = Units.ofType(sim, Units.WARSHIP)
	for i = #list, 1, -1 do
		local u = list[i]
		if u.active then
			local p = sim.players[u.ownerId]
			if p == nil or not p.alive then
				-- An empire that is gone has no navy. Sim.stepBoats does the
				-- same for transports (:1404-1408).
				Units.delete(sim, u, nil)
			else
				tickWarship(sim, u)
			end
		end
	end

	stepShells(sim)
end

-- ================================================================== orders ==
--
-- THERE IS NO Warships.build AND NO Warships.cost, deliberately. Both existed
-- and both are deleted rather than left dangling: a warship is not for sale
-- (see the header), so a canBuild/cost pair would be a second, half-wired way
-- to get one and the first thing a future reader would wire a button to.
-- Ports produce; stepPortProduction above is the only path to a hull.

-- Free-standing spawn, for a test fixture or a scripted event. Production
-- calls Units.spawn directly because it already holds the port record.
function Warships.spawn(sim: any, playerId: number, spawnTile: number, patrolTile: number): any
	return Units.spawn(sim, Units.WARSHIP, playerId, spawnTile, { ext = newExt(sim, patrolTile) })
end

-- Upstream MoveWarshipExecution (:11-42). THIS SURVIVES THE NO-PURCHASE RULE
-- unchanged: re-stationing a squadron is a command, not an acquisition, and it
-- costs nothing here exactly as it costs nothing upstream.
--
-- Ids are de-duplicated, a warship in
-- a DIFFERENT water component is skipped rather than sent somewhere it cannot
-- swim, and the current movement target is cleared so the new station takes
-- effect this tick.
function Warships.move(sim: any, playerId: number, unitIds: { number }, tile: number): number
	if tile < 0 or tile >= N then
		return 0
	end
	local comp = waterComp(sim, tile)
	if comp == nil then
		return 0
	end
	local moved = 0
	local seen: { [number]: boolean } = {}
	for _, id in unitIds do
		if not seen[id] then
			seen[id] = true
			local u = Units.get(sim, id)
			if u ~= nil and u.active and u.utype == Units.WARSHIP and u.ownerId == playerId then
				if waterComp(sim, u.tile) == comp then
					u.ext.patrolTile = tile
					u.targetTile = nil
					u.ext.path = nil
					u.ext.pathDst = nil
					moved += 1
				end
			end
		end
	end
	return moved
end

function Warships.count(sim: any, playerId: number): number
	return Units.stats(sim, playerId, Units.WARSHIP).n
end

-- ================================================================ AI owner ==
--
-- WHAT IS LEFT OF NationWarshipBehavior.ts (465 lines) AFTER THE NO-PURCHASE
-- RULE. Every one of its three acquisition paths is deleted, not stubbed:
--
--   maybeSpawnWarship (:36-66)             a 1-in-50 roll that BOUGHT the
--                                          nation's first hull
--   maybeRetaliateWithWarship (:222-256)   BOUGHT a hull where a ship was lost
--   counterWarshipInfestation (:286-460)   BOUGHT a hull on top of an enemy
--                                          fleet that had grown past ten
--
-- What survives is the JUDGEMENT each of them wrapped -- where a squadron
-- ought to be -- expressed through maybeMoveWarship (:258-282), which upstream
-- already used as its fallback whenever it could not afford or could not place
-- the hull it wanted. So this file now reads as upstream's behaviour with its
-- purchase branch permanently taken: the nation still notices its trade being
-- pirated, its coast being invaded and one empire monopolising the sea, and it
-- still answers all three -- with the fleet its ports have already given it.

local function aiWarshipCount(sim: any, playerId: number): number
	return Units.stats(sim, playerId, Units.WARSHIP).n
end

-- Upstream maybeMoveWarship (:258-282): re-station the nearest hull that is
-- not already crossing the map. Returns whether anything moved, which is now
-- load-bearing -- it is the ONLY thing an AI naval decision can do.
local function aiMoveWarship(sim: any, p: any, tile: number): boolean
	if not isWater(sim, tile) then
		-- Upstream insists the destination is wet; a station on land is a
		-- station no hull can ever reach. Probe outward before giving up.
		local wet = randomWaterNear(sim, tile, 30)
		if wet == nil then
			return false
		end
		tile = wet
	end
	local owned = sim.unitsByPlayer[p.id]
	if owned == nil then
		return false
	end
	local best: any = nil
	local bestD = math.huge
	for _, u in owned do
		if u.utype == Units.WARSHIP and u.active then
			local patrolTile = u.ext.patrolTile
			-- Do not send a ship that is already travelling (:263-270).
			if patrolTile ~= nil and manhattan(u.tile, patrolTile) < 130 then
				local d = manhattan(u.tile, tile)
				if d < bestD then
					bestD = d
					best = u
				end
			end
		end
	end
	if best == nil then
		return false
	end
	best.ext.patrolTile = tile
	best.targetTile = nil
	best.ext.path = nil
	best.ext.pathDst = nil
	return true
end

-- Upstream's per-difficulty retaliation odds (:238-244: never on Easy, 15% on
-- Medium, 50% on Hard, 80% on Impossible) become per-TIER odds, because
-- Conquest's tiers are its difficulty ladder (Config:847-956). They now gate a
-- MOVE rather than a purchase, so a miss means the squadron stays where it is.
local function aiRetaliateChance(p: any): number
	local tier = (Config.TIER :: any)[p.tier]
	if tier ~= nil and type(tier.WARSHIP_RETALIATE) == "number" then
		return tier.WARSHIP_RETALIATE
	end
	if p.tier == Config.TIER_NATION then
		return 0.5
	end
	if p.tier == Config.TIER_TRIBE then
		return 0.0
	end
	return 0.15
end

-- Upstream maybeRetaliateWithWarship (:222-256) with its build branch removed:
-- what is left is the branch upstream itself takes once it already has ten
-- hulls (:232-235).
local function aiRetaliate(sim: any, p: any, tile: number, enemyId: number)
	if enemyId == p.id then
		return
	end
	if sim.warshipRng:NextNumber() >= aiRetaliateChance(p) then
		return
	end
	aiMoveWarship(sim, p, tile)
end

-- Upstream trackIncomingTransportsAndRetaliate (:146-220): a nation that sees
-- an enemy transport heading for its coast, with no hull covering the landing
-- site, answers it. Upstream bought a hull for the beach; this sends one.
local function aiCoverIncoming(sim: any, p: any)
	local boats = sim.boats
	if boats == nil then
		return
	end
	if aiWarshipCount(sim, p.id) == 0 then
		-- Nothing to send. Upstream would have bought one here.
		return
	end
	local owner = sim.map.owner
	for _, b in boats do
		local be = b.ext
		if b.active and be ~= nil and not be.wDealt and not friendly(sim, p.id, b.ownerId) then
			local dst = be.dst
			if dst ~= nil and buffer.readu8(owner, dst) == p.id then
				if manhattan(b.tile, dst) < 20 then
					-- Too close to answer (:183-186).
					be.wDealt = true
				else
					local covered = Units.hasNearby(sim, dst, 90, Units.WARSHIP, p.id)
					if not covered then
						local owned = sim.unitsByPlayer[p.id]
						if owned ~= nil then
							for _, u in owned do
								if u.utype == Units.WARSHIP and u.active then
									local patrolTile = u.ext.patrolTile
									if patrolTile ~= nil and manhattan(dst, patrolTile) < 90 then
										covered = true
										break
									end
								end
							end
						end
					end
					if covered then
						be.wDealt = true
					else
						local station = randomWaterNear(sim, dst, 30)
						if station ~= nil then
							aiRetaliate(sim, p, station, b.ownerId)
							be.wDealt = true
							return
						end
					end
				end
			end
		end
	end
end

-- Upstream counterWarshipInfestation (:286-460): one empire trying to own the
-- whole ocean gets answered by the rich AIs. Upstream answered by BUYING a
-- hull on top of one of the infesting ships; this answers by SENDING one, so
-- the gold tests (:322-325) and the three-richest test (:341-350) are gone
-- with the purchase they guarded -- what is left is the shape of the threat
-- and the reply.
--
-- The early-outs are kept in upstream's order because the last test is the
-- expensive one.
local function aiCounterInfestation(sim: any, p: any)
	if p.tier ~= Config.TIER_NATION then
		-- Only the smart nations do this (:307-315).
		return
	end
	if #Units.ofType(sim, Units.WARSHIP) <= 10 then
		return
	end
	if aiWarshipCount(sim, p.id) == 0 then
		return
	end

	-- The free-for-all test (:421-440): any non-friendly empire with more than
	-- ten hulls, answered on top of one of them. Upstream's team-game branch
	-- (:360-419) is not ported -- see the header list.
	for _, id in sim.playerOrder do
		local other = sim.players[id]
		if other ~= nil and other.alive and not friendly(sim, p.id, id) then
			if aiWarshipCount(sim, id) > 10 then
				local owned = sim.unitsByPlayer[id]
				if owned ~= nil then
					for _, u in owned do
						if u.utype == Units.WARSHIP and u.active then
							aiMoveWarship(sim, p, u.tile)
							return
						end
					end
				end
			end
		end
	end
end

-- One AI think, at the bot's own think rate.
--
-- ACQUISITION IS NOT AN AI DECISION ANY MORE. A nation gets hulls from its
-- ports on the same timer a player's ports run on, so all this decides is
-- where the hulls it already has should sit.
function Warships.botThink(sim: any, p: any)
	if not p.alive or not p.spawned then
		return
	end
	if aiWarshipCount(sim, p.id) == 0 then
		-- No fleet, no naval decisions. Cheap early-out: most empires on a
		-- 72-empire roster never own a port at all.
		return
	end
	refreshPorts(sim)

	local queue = sim.warshipRetaliate[p.id]
	if queue ~= nil then
		for _, ev in queue do
			aiRetaliate(sim, p, ev.tile, ev.enemy)
		end
		table.clear(queue)
	end

	aiCoverIncoming(sim, p)
	aiCounterInfestation(sim, p)
end

-- ============================================================== transport ===

-- Markers for the vehicle stream, appended to whatever Sim.vehicles has
-- already built. Same shape as Economy.vehicles (:1442-1453) plus two fields
-- the HUD can grow into; the client ignores what it does not read.
function Warships.vehicles(sim: any, out: { any }): { any }
	for _, u in Units.ofType(sim, Units.WARSHIP) do
		if u.active then
			local x = u.tile % W
			out[#out + 1] = {
				id = u.id,
				kind = Warships.VEHICLE_WARSHIP,
				owner = u.ownerId,
				x = x,
				y = (u.tile - x) / W,
				hp = u.health,
				vet = u.veterancy,
			}
		end
	end
	local shells = sim.shells
	if shells ~= nil then
		for _, sh in shells do
			local x = sh.tile % W
			out[#out + 1] = {
				id = SHELL_VEHICLE_ID_BASE + sh.id,
				kind = Warships.VEHICLE_SHELL,
				owner = sh.ownerId,
				x = x,
				y = (sh.tile - x) / W,
			}
		end
	end
	return out
end

return Warships
