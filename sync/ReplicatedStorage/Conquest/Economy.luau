--!strict
-- Conquest :: Economy  (server only)
--
-- Everything gold touches: structures (cities and ports), the trading-boat
-- routes between ports, the rail network that grows between structures, and
-- the trains that run on it. Ported from upstream
-- (github.com/openfrontio/OpenFrontIO, src/core/configuration/Config.ts) --
-- see the economy block in Config for the upstream function behind each number.
--
-- WHY THIS IS NOT IN Sim: Sim is 79 KB and is the file every other change to
-- this game touches. None of what follows needs to be interleaved with the
-- attack loop -- it needs the map, the players and the tick, and nothing else
-- -- so it lives here and Sim keeps five hook lines.
--
-- Reference mapping, honestly stated:
--   Port           unitInfo(Port) + PortExecution + PlayerImpl.portSpawn
--   Trading boat     TradeShipExecution + tradeShipGold + tradeShipSpawnRate
--                  + PlayerImpl.tradingPorts (the level/proximity weighting)
--   Rail           RailNetworkImpl.connectToNearbyStations
--   Train          TrainStationExecution + TrainExecution + TrainStation's
--                  stop handlers (trainGold * (level + 1))
--   Factory        unitInfo(Factory) + FactoryExecution + the station gate in
--                  CityExecution/PortExecution.createStation
-- Gunboats and piracy ARE ported now (Conquest.Gunboats); a trading boat can
-- be captured, and the captor takes the whole payout. Factories ARE ported
-- now too, and with them the rule that made rail an economy rather than a
-- fountain -- see stepStations.
-- NOT ported: the cosmetic carriages behind a train's engine.

local Config = require(script.Parent.Config)
-- DIPLOMACY (2026-09-18): the ally stop rate and the trade embargo.
local Alliances = require(script.Parent.Alliances)
local Heap = require(script.Parent.Heap)
local Navy = require(script.Parent.Navy)
local TileMap = require(script.Parent.TileMap)
-- ONE record for every structure, boat and vehicle in the game, plus
-- the spatial index over them, the per-player counters and the
-- territory-capture rule. Ported from upstream's Unit; see Units for the
-- migration plan this file is the far end of.
local Units = require(script.Parent.Units)

local W = Config.MAP_W
local H = Config.MAP_H
local N = Config.NUM_TILES

local Economy = {}

-- Structure kinds. Numbers rather than strings because they cross the wire in
-- a single byte and index straight into the per-kind counters below.
--
-- THESE ARE Units TYPE IDS, not a separate numbering: Economy.build passes
-- `kind` straight into Units.spawn, and Economy.add reads it back off
-- `unit.utype`. So a new kind here has to BE its Units type.
Economy.CITY = 1 -- Units.CITY
Economy.PORT = 2 -- Units.PORT
-- The only building that generates trains. Everything else is a station only
-- if a factory stands within STATION_MAX_RANGE of it, which is upstream's
-- rule (FactoryExecution.createStation :44-58, CityExecution :34-42,
-- PortExecution :86-95) and the single reason rail is a decision rather than
-- free money -- see the note on stepStations.
Economy.FACTORY = 6 -- Units.FACTORY
-- The one structure that is never a station and never upgradable. It comes
-- through this module anyway -- canBuild, the cost ladder, the paid-for
-- counter, Units.spawn -- because a SECOND price for one building is the bug
-- that follows from the obvious alternative: the server's build reply prices
-- off Economy.cost, and a Units.cost placer would price the same post off a
-- different basis (sum of levels, sites included).
Economy.DEFENSE_POST = 3 -- Units.DEFENSE_POST
-- The anti-nuke tower. Like the post it is NEVER a station (stepSites promotes
-- only city/port/factory), and it is here for the same one reason: its PRICE
-- and its paid-for counter have to be readable off the player, because
-- Sim.structureCost is called as (player, kind) with no sim.
Economy.SAM_LAUNCHER = 5 -- Units.SAM_LAUNCHER
-- The two guns (2026-09-21). Never stations, never upgradable, razed on
-- capture; Economy owns their price ladders and build timers like the post's.
Economy.ARTILLERY = 18 -- Units.ARTILLERY
Economy.AIRFIELD = 19 -- Units.AIRFIELD
-- The railgun (2026-09-24), the airfield's rules on its own ladder.
Economy.RAILGUN = 21 -- Units.RAILGUN

Economy.TRADING_BOAT = 1
Economy.TRAIN = 2

export type Structure = {
	tile: number,
	ownerId: number,
	level: number,
	kind: number,
	-- Whether this building is on the rail network at all. A FACTORY always
	-- is; a city or port only once a factory has stood within
	-- STATION_MAX_RANGE of it. Upstream carries the same flag on the unit
	-- (UnitImpl._hasTrainStation) and never clears it: a station outlives the
	-- factory that promoted it, and survives being captured.
	hasStation: boolean,
	-- Rails leaving this structure. Empty until it is a station.
	rails: { any },
	-- On sim.stationQueue and not yet linked. Set when it is queued so one
	-- structure is queued once, cleared when the queue is done with it.
	queued: boolean,
	-- Land searches spent and rails laid since it was last queued. The queue
	-- hands a station a few searches a tick and keeps it at the head until
	-- these hit their caps -- see connectStation.
	linkTries: number,
	linkMade: number,
	nextTrainTick: number,
	nextTradeTick: number,
	-- Cached cluster membership, valid while sim.railEpoch has not moved.
	clusterEpoch: number,
	cluster: { Structure }?,
	-- The Unit this structure IS. Identity, ownership, level, the spatial
	-- index, the per-kind counters and the capture rule all live on the unit
	-- from here; what stays on the Structure is the rail and trade state a
	-- station carries and a unit does not. Set in Economy.add, never nil after.
	unit: any,
}

-- ------------------------------------------------------------- geometry ----

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

local function sigmoid(v: number, decay: number, mid: number): number
	return 1 / (1 + math.exp(-decay * (v - mid)))
end

-- Shared "match anything" predicate for the crowding test, so the build path
-- does not allocate a closure per probe -- a bot fires BOT_BUILD_PROBES of
-- them per build roll.
local function ALWAYS(_u: any): boolean
	return true
end

-- ================================================================== state ==

function Economy.init(sim: any)
	sim.structAt = {} :: { [number]: Structure }
	-- ORDERED. Not a set and not Units' per-type list: three of the passes
	-- below consume RNG in list order (the trade roll, the train roll), so the
	-- order structures are visited in is part of the simulation and has to
	-- survive a removal in the middle of the list. Units' own lists swap-remove.
	sim.structList = {} :: { Structure }

	sim.rails = {} :: { any }
	sim.railEvents = {} :: { any }
	-- Bumped whenever the rail GRAPH changes, which is what invalidates every
	-- station's cached cluster. Ownership changes do not bump it: who may
	-- trade with whom is filtered at the moment a train is dispatched, not
	-- baked into the cluster.
	sim.railEpoch = 1

	-- No sim.ships, no sim.trains, no nextVehicleId. A trading boat is a
	-- Units.TRADING_BOAT and a train is a Units.TRAIN, they draw their ids from
	-- the one unit counter, and their per-type lists ARE the iteration order
	-- this file used to keep by hand -- Units appends on spawn and swap-removes
	-- on delete, which is exactly what stepTradingBoats and stepTrains did with
	-- sim.ships[i] = sim.ships[last]. Same order, same evolution, one list.

	-- Routes between two port cells, coarse cells plus the fine water polyline
	-- a trading boat actually sails. Keyed by the pair, so every trading boat that ever runs
	-- that lane pays for the search once. See seaRoute.
	sim.seaPaths = {} :: { [number]: any }
	sim.seaPathCount = 0
	-- At most one UNCACHED sea route may be searched per tick. Measured: with
	-- the search running on demand, one tick hit 229 ms against a 100 ms
	-- budget. A skipped spawn is invisible -- the port rolls again in
	-- TRADE_CHECK_TICKS -- whereas a blown tick is felt by everyone.
	sim.seaPathBudget = 0

	sim.trainStopGold = 0
	sim.tradeGold = 0

	-- The ports paid by a trading boat that has just come in, waiting for the one
	-- client that owns each of them. PEOPLE ONLY -- a bot earns exactly the same
	-- and has nobody to tell -- which is also what keeps this empty in a headless
	-- benchmark, where nothing ever drains it.
	sim.tradePayouts = {} :: { any }

	-- Structures promoted to stations and still waiting for their rails. See
	-- promoteStations for why the connection is deferred.
	sim.stationQueue = {} :: { Structure }
	-- Where the rail sweep's cursor is in structList, the pairs the land
	-- search has given up on, and the id the last rail took. See sweepRails
	-- and addRail.
	sim.railSweepAt = 0
	sim.railFailed = {} :: { [number]: boolean }
	sim.railSeq = 0
end

-- ------------------------------------------------------- per-kind counters --
-- `cityLevels` is load-bearing outside this module: Sim.maxTroops adds it to
-- the troop ceiling. The port counters exist only so the cost curve and the
-- trading-boat bonus can read them.

-- cityCount / cityLevels / portCount / portLevels are no longer maintained
-- here. Units.statAdd writes them -- on every spawn, capture, upgrade, level
-- loss and razing -- as a mirror of its own per-(player, type) counters. This
-- file kept four numbers by hand across five call sites plus the capture
-- path; there is one writer now.
--
-- cityBuilt / portBuilt stay. They count what an empire has PAID for, which
-- is a fact about Economy.build rather than about any unit. Units keeps its
-- own `built` on the same basis and the two agree; the cost curve reads this
-- one because Sim.structureCost is called as (player, kind) with no sim.
-- Keyed by Units type id, so the table is sparse: 1 city, 2 port, 6 factory.
local COUNT_FIELD = { [1] = "cityCount", [2] = "portCount", [3] = "defensePostCount", [5] = "samCount", [6] = "factoryCount",
	[18] = "artilleryCount", [19] = "airfieldCount", [21] = "railgunCount" }
local BUILT_FIELD = { [1] = "cityBuilt", [2] = "portBuilt", [3] = "defensePostBuilt", [5] = "samBuilt", [6] = "factoryBuilt",
	[18] = "artilleryBuilt", [19] = "airfieldBuilt", [21] = "railgunBuilt" }
-- The kinds a click inside one of your own is CROWDED rather than an upgrade
-- (see canBuild). Upstream's unitInfo carries no `upgradable` for the post; the
-- two guns follow it.
local NOT_UPGRADABLE = { [3] = true, [18] = true, [19] = true, [21] = true }

-- What the NEXT structure of this kind costs. `min(owned, built)` is the
-- reference's basis (`min(unitsOwned, unitsConstructed)`), and it has two
-- consequences worth keeping: an empire that has LOST structures rebuilds at
-- the cheaper tier, and one that has CAPTURED them does not pay for somebody
-- else's spending. It also means an upgrade -- which raises `built` but not
-- `owned` -- never raises the price of your next building.
--
-- DIVERGES FROM Units.cost ON PURPOSE, and this is the one number in the
-- migration that is a balance decision rather than a port. `owned` here is
-- the STRUCTURE COUNT; upstream's unitsOwned, which Units.cost uses, is the
-- SUM OF LEVELS, so upstream DOES make an upgrade raise the price of your
-- next building. Pointing this function at Units.cost reprices every city and
-- port in the game. Until somebody decides to take that change, this reads
-- the mirror Units maintains, which is Units.structureCount by another name.
--
-- PORT AND FACTORY SHARE ONE LADDER, which is upstream's (Config.ts:418-428
-- lists Port then Factory in the port's cost pool, :508-518 the reverse) and
-- is what stops a factory being a cheap bolt-on to a port network: your first
-- factory costs whatever your next port would have, and it doubles the price
-- of the port after it. A city's ladder is its own.
--
-- THE HEAD OF THE LADDER IS STATED RUNG BY RUNG (Config.CITY_COST_STEPS /
-- PORT_COST_STEPS) AND THE DOUBLING CURVE TAKES OVER FROM ITS OWN BASE.
-- Subtracting `#steps - 1` is the whole of the join: the last stated rung is
-- written to equal the base, so the rung after the list is base * growth and
-- every price above the list is the one that always ran.
--
-- A TUTORIAL PRICES OFF THE PLAIN LADDER and skips the list entirely --
-- Tutorial.START_GOLD (100k) and OPENING_GOLD (50k) are both written to sit
-- under the price of a city, and cheap opening rungs hand the whole lesson
-- roster a city each. A MODULE FIELD rather than a field on the sim, and for
-- the reason stated over COUNT_FIELD: Economy.cost is called as (player, kind)
-- with no sim, because Sim.structureCost is. ConquestServer.startRound is the
-- one writer and it assigns on every round, not only on a lesson.
Economy.tutorialPricing = false

local function rung(steps: { number }?, n: number, base: number, growth: number, cap: number): number
	if steps ~= nil and not Economy.tutorialPricing then
		local stated = steps[n + 1]
		if stated ~= nil then
			return stated
		end
		n -= #steps - 1
	end
	return math.min(cap, growth ^ n * base)
end

function Economy.cost(p: any, kind: number): number
	-- A LINEAR ladder of its own and a pool holding only itself:
	-- min(CAP, (n + 1) * STEP), upstream Config.ts:534-536. `min(owned, built)`
	-- is the same basis every other kind uses, so an empire whose posts were
	-- RAZED rebuilds at the cheaper rung -- which is precisely the situation a
	-- post is bought in, since taking the ground is what destroys it.
	if kind == Economy.DEFENSE_POST then
		local n = math.min(p.defensePostCount or 0, p.defensePostBuilt or 0)
		return math.min(Config.DEFENSE_POST_COST_CAP, (n + 1) * Config.DEFENSE_POST_COST_STEP)
	end
	-- THE TWO GUNS (2026-09-21), each on a linear ladder of its own like the
	-- post: min(CAP, (n + 1) * STEP). Read here AND by Units.INFO (the AI's
	-- Units.cost path) off the same Config numbers, so the two cannot drift.
	if kind == Economy.ARTILLERY then
		local n = math.min(p.artilleryCount or 0, p.artilleryBuilt or 0)
		return math.min(Config.ARTILLERY_COST_CAP or 750000, (n + 1) * (Config.ARTILLERY_COST_STEP or 150000))
	end
	if kind == Economy.AIRFIELD then
		local n = math.min(p.airfieldCount or 0, p.airfieldBuilt or 0)
		return math.min(Config.AIRFIELD_COST_CAP or 1500000, (n + 1) * (Config.AIRFIELD_COST_STEP or 500000))
	end
	if kind == Economy.RAILGUN then
		local n = math.min(p.railgunCount or 0, p.railgunBuilt or 0)
		return math.min(Config.RAILGUN_COST_CAP or 7500000, (n + 1) * (Config.RAILGUN_COST_STEP or 2500000))
	end
	-- THE ANTI-NUKE TOWER, on a linear ladder of its own like the post but an
	-- order of magnitude up: upstream is min(3M, (n + 1) * 1.5M), 1.5M then 3M
	-- forever (Config.ts:541-553). The FIRST rung is its own number since
	-- 2026-09-18 (owner: 1M, not 1.5M); the rest are unchanged. The three
	-- numbers live in Config now, read here AND by Units.INFO[SAM_LAUNCHER] (the
	-- ladder the AI's Units.cost path uses), so the two copies cannot drift.
	-- This is the copy the build reply and the rail button read.
	if kind == Economy.SAM_LAUNCHER then
		local n = math.min(p.samCount or 0, p.samBuilt or 0)
		if n == 0 then
			return Config.SAM_COST_FIRST or 1500000
		end
		return math.min(Config.SAM_COST_CAP or 3000000, (n + 1) * (Config.SAM_COST_STEP or 1500000))
	end
	if kind == Economy.PORT or kind == Economy.FACTORY then
		local n = math.min(p.portCount, p.portBuilt)
			+ math.min(p.factoryCount or 0, p.factoryBuilt or 0)
		return rung(Config.PORT_COST_STEPS, n, Config.PORT_COST_BASE,
			Config.PORT_COST_GROWTH, Config.PORT_COST_CAP)
	end
	local n = math.min(p[COUNT_FIELD[kind]], p[BUILT_FIELD[kind]])
	return rung(Config.CITY_COST_STEPS, n, Config.CITY_COST_BASE,
		Config.CITY_COST_GROWTH, Config.CITY_COST_CAP)
end

-- ============================================================== structures ==
--
-- WHAT IS LEFT OF THIS SECTION. Economy.add, Economy.remove and Economy.nearby
-- are the three entry points the rest of the game still calls, and all three
-- are now thin: add promotes a unit to a station, remove deletes the unit and
-- lets the onDelete hook unlink the station, and nearby forwards to the unit
-- grid. Economy.transfer and Economy.onTileOwnerChanged are gone outright --
-- capture is Units.stepCapture, once per tick, off the conquest path.
--
-- The Structure record is no longer a parallel copy of the unit. tile, kind
-- and level are read from it for convenience and never diverge (tile and kind
-- never change; level and ownerId are written through the unit's hooks), and
-- what only it holds is the station state: rails, cluster cache, the trade
-- pity counter and the two cooldown ticks.

-- Structure events are no longer minted here. Units.emit fires the SAME four
-- fields (tile, ownerId, level, kind) off the unit itself, on the same four
-- occasions -- appear, level up, change hands, be razed -- and one stream is
-- what stops the client ever seeing a structure and a unit disagree.

-- The nearest structure to `tile` within `radius`, or nil.
--
-- FORWARDS TO THE UNIT GRID, and that is the change the rest of the weapon
-- systems were waiting on. What stood here scanned a fixed 3x3 block of
-- 16-tile cells, which covers a query radius of 15 and NOTHING LARGER: ask it
-- for 16 and it silently misses everything two cells out. A defense post
-- needs 30, a gunboat 130, a SAM 600. Units.closest walks the exact cell
-- rectangle the radius spans, so every one of those works off one index.
--
-- includeUC: the CROWDING test wants sites counted (two sites half a tile
-- apart are as illegal as two finished buildings -- upstream passes true for
-- exactly that, PlayerImpl.ts:1637); the UPGRADE test must not, or a build
-- click would level a building that is not standing yet.
--
-- The kindless form is kept for callers that want the nearest structure of
-- ANY kind. It returns the Structure, so it can only see units that have one
-- -- a site does not until it completes. Use Units.anyNearby for the
-- existence test that has to include them; Economy.canBuild does.
function Economy.nearby(
	sim: any,
	tile: number,
	radius: number,
	ownerFilter: number?,
	kindFilter: number?,
	includeUC: boolean?
): Structure?
	if kindFilter ~= nil then
		local u = Units.closest(sim, tile, radius, kindFilter, ownerFilter, includeUC)
		if u == nil or u.ext == nil then
			return nil
		end
		return u.ext.struct
	end
	local best: Structure? = nil
	local bestD = math.huge
	for _, t in Units.STRUCTURE_TYPES do
		local u, d2 = Units.closest(sim, tile, radius, t, ownerFilter, includeUC)
		if u ~= nil and d2 < bestD and u.ext ~= nil and u.ext.struct ~= nil then
			bestD = d2
			best = u.ext.struct
		end
	end
	return best
end

-- ------------------------------------------------------------------ rail ---
-- Rails are built ONCE, when a station joins the network, and never move. A
-- rail is a list of land tiles; trains walk it, the client draws it.

local RAIL_HEAP = Heap.new()

-- Heading index -> step. 0 east, 1 west, 2 south (+y), 3 north (-y); the
-- reverse of d is d xor 1.
local DIR_DX = { [0] = 1, [1] = -1, [2] = 0, [3] = 0 }
local DIR_DY = { [0] = 0, [1] = 0, [2] = 1, [3] = -1 }

-- Walks (x, y) to the goal's coordinate on ONE axis, appending every tile
-- crossed, and stops at the first tile that is not land. Returns whether it
-- got there and where it stopped.
local function walkAxis(
	map: any,
	path: { number },
	x: number,
	y: number,
	gx: number,
	gy: number,
	alongX: boolean
): (boolean, number, number)
	if alongX then
		local sx = gx > x and 1 or -1
		while x ~= gx do
			x += sx
			local t = y * W + x
			if not TileMap.isPassable(map, t) then
				return false, x, y
			end
			path[#path + 1] = t
		end
	else
		local sy = gy > y and 1 or -1
		while y ~= gy do
			y += sy
			local t = y * W + x
			if not TileMap.isPassable(map, t) then
				return false, x, y
			end
			path[#path + 1] = t
		end
	end
	return true, x, y
end

-- CAN LAND BE WALKED FROM `from` TO `to` INSIDE THE BOX IN UNDER maxSteps? A
-- plain breadth-first flood over tiles: no heap, no headings, one byte a tile.
-- It exists because the SEARCH BELOW IS EXPENSIVE WHEN IT FAILS -- a pair with
-- a bay between them explores everything reachable in the box, 16 ms at the
-- pop cap -- and on a coastline most candidate pairs are exactly that.
-- Measured on us/777 at 15 min: 1,826 failed pairs against 580 rails laid,
-- and those failures were most of the economy's tick. This answers the same
-- question in a tenth of the time, so the A* only ever runs on a pair it can
-- join.
--
-- The visited mark is a GENERATION STAMP in a buffer kept across calls:
-- clearing 1.6 MB per search would cost more than the search, so a byte is
-- "seen" when it equals this call's stamp, and the buffer is wiped only when
-- the stamp wraps.
local REACH_SEEN: buffer? = nil
local REACH_GEN = 0
local REACH_Q: { number } = {}

local function landReachable(
	map: any,
	from: number,
	to: number,
	minX: number,
	maxX: number,
	minY: number,
	maxY: number,
	maxSteps: number
): boolean
	local seen = REACH_SEEN
	if seen == nil or buffer.len(seen) < N then
		seen = buffer.create(N)
		REACH_SEEN = seen
		REACH_GEN = 0
	end
	REACH_GEN += 1
	if REACH_GEN > 255 then
		buffer.fill(seen, 0, 0)
		REACH_GEN = 1
	end
	local gen = REACH_GEN
	local q = REACH_Q
	q[1] = from
	buffer.writeu8(seen, from, gen)
	local head, tail = 1, 1
	local depth, levelEnd = 0, 1
	while head <= tail do
		local cur = q[head]
		head += 1
		if cur == to then
			return true
		end
		local cx, cy = tx(cur), ty(cur)
		for d = 0, 3 do
			local nx, ny = cx + DIR_DX[d], cy + DIR_DY[d]
			if nx >= minX and nx <= maxX and ny >= minY and ny <= maxY then
				local nb = ny * W + nx
				if buffer.readu8(seen, nb) ~= gen and TileMap.isPassable(map, nb) then
					buffer.writeu8(seen, nb, gen)
					tail += 1
					q[tail] = nb
				end
			end
		end
		if head > levelEnd then
			depth += 1
			if depth >= maxSteps then
				return false
			end
			levelEnd = tail
		end
	end
	return false
end

-- One axis and then the other: the cheapest rail there is, a single corner,
-- and what most pairs on open ground get. Nil if any tile of it is not land.
local function elbow(map: any, from: number, to: number, xFirst: boolean): { number }?
	local x, y = tx(from), ty(from)
	local gx, gy = tx(to), ty(to)
	local path = { from }
	local ok
	ok, x, y = walkAxis(map, path, x, y, gx, gy, xFirst)
	if not ok then
		return nil
	end
	ok, x, y = walkAxis(map, path, x, y, gx, gy, not xFirst)
	if not ok then
		return nil
	end
	return path
end

-- A RAIL RUNS STRAIGHT AND TURNS AT CORNERS (owner, 2026-09-06: "trains should
-- move in a purely X or Y coordinate pattern, should never move diagonally.
-- make it turn when needed on corners"). The search here used to be a plain
-- 4-connected A* with a Euclidean heuristic, and the route that wins under
-- that is a STAIRCASE -- east, north, east, north -- which is a shortest
-- Manhattan path but reads as a diagonal, and a train stepping along it
-- wobbles the whole way. Measured on us/777 at 15 min: 9,082 corners on
-- 22,860 tiles of track, one every 2.5 tiles.
--
-- Two changes. The ELBOW is tried first: one leg along each axis, which is
-- the fewest corners a rail can have and is what open ground gets without a
-- search at all. Where the elbow crosses water or rock, the A* runs over
-- (tile, heading) states and charges RAIL_TURN_COST tiles for every change of
-- heading, so among routes of similar length it returns the one with the
-- fewest corners rather than the one it happened to pop first. A rail may not
-- reverse along itself.
--
-- Bounded as before: by the padded box of the two endpoints, so a rail never
-- wanders across the map, and by a pop budget -- larger than the old 2,500,
-- because a tile is now four states. Returns nil rather than a long path; the
-- reference likewise refuses any route at or past `railroadMaxSize`.
local function landPath(sim: any, from: number, to: number): { number }?
	local map = sim.map
	local fx, fy = tx(from), ty(from)
	local gx, gy = tx(to), ty(to)

	-- Long leg first, so the one corner sits near the far end and two rails
	-- leaving a station on similar bearings share their first stretch.
	local xFirst = math.abs(gx - fx) >= math.abs(gy - fy)
	local direct = elbow(map, from, to, xFirst) or elbow(map, from, to, not xFirst)
	if direct ~= nil then
		return direct
	end

	local pad = 24
	local minX = math.max(0, math.min(fx, gx) - pad)
	local maxX = math.min(W - 1, math.max(fx, gx) + pad)
	local minY = math.max(0, math.min(fy, gy) - pad)
	local maxY = math.min(H - 1, math.max(fy, gy) + pad)
	local turnCost = Config.RAIL_TURN_COST or 0
	local maxTiles = Config.RAIL_MAX_TILES

	-- The cheap no first. See landReachable.
	if not landReachable(map, from, to, minX, maxX, minY, maxY, maxTiles) then
		return nil
	end

	-- A state is tile * 4 + heading. The start carries heading 0 and is
	-- exempt from the turn charge on its first step.
	local heap = RAIL_HEAP
	Heap.clear(heap)
	local START = from * 4
	local gScore: { [number]: number } = { [START] = 0 }
	local walked: { [number]: number } = { [START] = 0 }
	local cameFrom: { [number]: number } = {}
	Heap.push(heap, START, 0)

	-- Measured on us/777: a rail that needs the search at all averages
	-- ~500 pops. Running to the cap used to be the price of every pair with
	-- water between them; landReachable now turns those away first, so the
	-- cap only bounds a route that is real but very bent. At 6,000 that is
	-- ~20 ms, and RAIL_SEARCHES_PER_TICK of them is the economy's worst tick.
	local pops = 0
	local MAX_POPS = 6000
	local goal: number? = nil

	while true do
		local key = Heap.pop(heap)
		if key == nil then
			return nil
		end
		pops += 1
		if pops > MAX_POPS then
			return nil
		end
		local cur = key // 4
		if cur == to then
			goal = key
			break
		end
		local dir = key - cur * 4
		local g = gScore[key]
		local steps = walked[key]
		local cx, cy = tx(cur), ty(cur)
		for d = 0, 3 do
			-- No doubling back along the line just laid.
			if key ~= START and d == bit32.bxor(dir, 1) then
				continue
			end
			local nx, ny = cx + DIR_DX[d], cy + DIR_DY[d]
			if nx < minX or nx > maxX or ny < minY or ny > maxY then
				continue
			end
			local nb = ny * W + nx
			if not TileMap.isPassable(map, nb) then
				continue
			end
			local ns = steps + 1
			if ns >= maxTiles then
				continue
			end
			local ng = g + 1
			if key ~= START and d ~= dir then
				ng += turnCost
			end
			local nk = nb * 4 + d
			local old = gScore[nk]
			if old == nil or ng < old then
				gScore[nk] = ng
				walked[nk] = ns
				cameFrom[nk] = key
				-- Manhattan distance plus the corners still owed, both of
				-- which every completion must pay: none if the goal lies dead
				-- ahead, one if it is off to the side or on the other axis,
				-- two if it is behind.
				local ddx, ddy = gx - nx, gy - ny
				local h = math.abs(ddx) + math.abs(ddy)
				if ddx ~= 0 or ddy ~= 0 then
					local ahead = if d <= 1 then ddx * DIR_DX[d] else ddy * DIR_DY[d]
					if ahead < 0 then
						h += 2 * turnCost
					elseif ahead == 0 or (ddx ~= 0 and ddy ~= 0) then
						h += turnCost
					end
				end
				Heap.push(heap, nk, ng + h)
			end
		end
	end

	local path = {}
	local k = goal :: number
	while k ~= START do
		path[#path + 1] = k // 4
		k = cameFrom[k]
	end
	path[#path + 1] = from
	-- Reversed so tiles[1] is the `from` station: a train reading the list
	-- forwards is travelling a -> b, and backwards is travelling b -> a.
	local out = table.create(#path)
	for i = #path, 1, -1 do
		out[#out + 1] = path[i]
	end
	return out
end

-- Hops through the rail graph from `a` to `b`, capped. The reference refuses a
-- new rail between two stations already within `maxConnectionDistance` of each
-- other -- otherwise every station in a cluster ends up joined to every other
-- and the network is a mesh rather than a railway.
local function graphHops(from: Structure, to: Structure, cap: number): number
	if from == to then
		return 0
	end
	local seen = { [from] = true }
	local frontier = { from }
	for depth = 1, cap do
		local nextFrontier = {}
		for _, s in frontier do
			for _, rail in s.rails do
				local other = rail.from == s and rail.to or rail.from
				if other == to then
					return depth
				end
				if not seen[other] then
					seen[other] = true
					table.insert(nextFrontier, other)
				end
			end
		end
		if #nextFrontier == 0 then
			return -1
		end
		frontier = nextFrontier
	end
	return -1
end

-- Every station reachable from this one, cached against the rail epoch. The
-- cache is what makes a per-station, per-tick train check affordable: without
-- it every station walks its whole network every tick.
local function cluster(sim: any, s: Structure): { Structure }
	if s.cluster and s.clusterEpoch == sim.railEpoch then
		return s.cluster
	end
	local seen = { [s] = true }
	local out = { s }
	local i = 1
	while i <= #out do
		local cur = out[i]
		i += 1
		for _, rail in cur.rails do
			local other = rail.from == cur and rail.to or rail.from
			if not seen[other] then
				seen[other] = true
				table.insert(out, other)
			end
		end
	end
	-- Shared by the whole cluster, so one BFS serves every member.
	for _, m in out do
		m.cluster = out
		m.clusterEpoch = sim.railEpoch
	end
	return out
end

-- Straight runs collapsed to their endpoints. A rail is a grid staircase, so
-- the raw tile list is up to 100 points; the client draws one Frame per
-- segment and there are hundreds of rails on a late map.
local function decimate(tiles: { number }): { number }
	local out = { tiles[1] }
	local n = #tiles
	if n < 3 then
		if n == 2 then
			table.insert(out, tiles[2])
		end
		return out
	end
	local ax, ay = tx(tiles[1]), ty(tiles[1])
	for i = 2, n - 1 do
		local bx, by = tx(tiles[i]), ty(tiles[i])
		local cx, cy = tx(tiles[i + 1]), ty(tiles[i + 1])
		-- Cross product of the two step vectors: zero means still straight.
		if (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) ~= 0 then
			table.insert(out, tiles[i])
			ax, ay = bx, by
		end
	end
	table.insert(out, tiles[n])
	return out
end

-- One number for an unordered pair of tiles. Both are below NUM_TILES, so the
-- product stays an exact integer.
local function pairKey(a: number, b: number): number
	if a > b then
		a, b = b, a
	end
	return a * N + b
end

local function addRail(sim: any, a: Structure, b: Structure, tiles: { number })
	-- IDS ARE 1..65535 AND WRAP. A train names the rail it is on by this id in
	-- two bytes of the vehicle stream (Net.packVehicles), and the client draws
	-- the train along that rail's own corners -- see Structures.planTrain.
	-- Zero means "no rail" on the wire, so the sequence skips it.
	sim.railSeq = sim.railSeq % 65535 + 1
	local rail = { from = a, to = b, tiles = tiles, id = sim.railSeq }
	table.insert(sim.rails, rail)
	table.insert(a.rails, rail)
	table.insert(b.rails, rail)
	sim.railEpoch += 1
	table.insert(sim.railEvents, { a = a.tile, b = b.tile, pts = decimate(tiles), id = rail.id })
end

local function removeRail(sim: any, rail: any)
	local at = table.find(sim.rails, rail)
	if at then
		table.remove(sim.rails, at)
	end
	for _, s in { rail.from, rail.to } do
		local k = table.find(s.rails, rail)
		if k then
			table.remove(s.rails, k)
		end
	end
	sim.railEpoch += 1
	table.insert(sim.railEvents, { a = rail.from.tile, b = rail.to.tile })
end

-- Join a new station to the network. Nearest first, and only where the two are
-- not already close together THROUGH the rails -- that pair of rules is what
-- makes the result look like a railway rather than a complete graph.
local function connectStation(sim: any, s: Structure, budget: number): boolean
	local candidates = {}
	local maxR2 = Config.STATION_MAX_RANGE * Config.STATION_MAX_RANGE
	local minR2 = Config.STATION_MIN_RANGE * Config.STATION_MIN_RANGE
	for _, other in sim.structList do
		-- Only stations are on the network. A city with no factory near it is
		-- a building, not a stop, and a rail must never terminate at one.
		if other ~= s and other.hasStation then
			local d = dist2(other.tile, s.tile)
			if d <= maxR2 and d > minR2 then
				table.insert(candidates, { s = other, d = d })
			end
		end
	end
	table.sort(candidates, function(p, q)
		return p.d < q.d
	end)

	-- THE SEARCH IS THE UNIT OF WORK, NOT THE STATION. This is the only
	-- expensive thing the economy does: a search that fails -- two buildings
	-- with a bay between them -- runs to its pop cap, and a station can have a
	-- dozen candidates within range. Six of those in one tick measured 170 ms
	-- against a 100 ms budget. So a call spends at most `budget` searches and
	-- says whether it is finished; the queue keeps an unfinished station at
	-- its head and calls again next tick. Candidates are re-derived each call
	-- rather than remembered, because the two tests above already skip what
	-- an earlier call settled: a pair it linked is now one hop away, a pair it
	-- could not link is in railFailed. The two caps -- six searches, three
	-- rails -- are per queueing (enqueueStation resets them), and the nearest
	-- few are also the only ones that make a sensible railway.
	--
	-- 2026-09-23: AND RAIL_MAX_LINKS, WHICH IS THE LIFETIME ONE. The pair
	-- above reset every time sweepRails re-queued the station -- once a
	-- minute, forever -- so "at most three rails" was really "three more
	-- rails a minute" and a station reached nine of them inside seven
	-- minutes. This one counts what the station is actually holding.
	local failed = sim.railFailed
	local searched = 0
	-- RELATIVE RANGE. STATION_MAX_RANGE is 110 tiles on an 880-wide map, and
	-- the hop test below rejects every NEAR candidate -- a neighbour twenty
	-- tiles away is already within RAIL_MAX_CONNECTION_HOPS through the rails
	-- -- so "nearest first" ended at the only candidates that survive it: the
	-- far ones. Measured on us/777 at 7.5 min, the average rail spanned 67
	-- tiles while the average station's nearest neighbour sat 20 tiles away,
	-- and 40% of the ground under track carried two or more lines. So a rail
	-- may be at most RAIL_RELATIVE_RANGE times the distance to this station's
	-- nearest neighbour OF ALL, linked or not -- which is a local rule, so a
	-- station out on its own still reaches as far as it has to. The list is
	-- sorted, so the walk simply stops at the first candidate past the limit.
	--
	-- THE BASELINE SKIPS PAIRS THE LAND SEARCH HAS ALREADY REFUSED, and that
	-- is what keeps an island map working. A station on a coast usually has a
	-- neighbour a few tiles away ACROSS WATER; if that one set the limit, the
	-- only station this one can actually reach would sit outside it and the
	-- building would never get a line at all. Because a refused pair goes in
	-- railFailed, the baseline steps outwards on each sweep until it lands on
	-- something reachable -- the station widens its own search, once a minute,
	-- rather than being stranded.
	local rel = Config.RAIL_RELATIVE_RANGE
	local base = nil
	for _, c in candidates do
		if not failed[pairKey(s.tile, c.s.tile)] then
			base = c.d
			break
		end
	end
	local limit = if rel and base then base * rel * rel else math.huge
	for _, c in candidates do
		if s.linkTries >= 6 or s.linkMade >= 3 or #s.rails >= Config.RAIL_MAX_LINKS then
			return true
		end
		if c.d > limit then
			break
		end
		if searched >= budget then
			return false
		end
		local pk = pairKey(s.tile, c.s.tile)
		if not failed[pk] and graphHops(c.s, s, Config.RAIL_MAX_CONNECTION_HOPS) == -1 then
			s.linkTries += 1
			searched += 1
			local path = landPath(sim, s.tile, c.s.tile)
			if path and #path > 1 and #path < Config.RAIL_MAX_TILES then
				addRail(sim, s, c.s, path)
				s.linkMade += 1
			else
				-- No land route inside a rail's reach, and there never will be:
				-- the search reads terrain and nothing else. Remembered so the
				-- sweep does not pay for this pair again every minute.
				failed[pk] = true
			end
		end
	end
	return true
end

-- Puts a station on the queue once, with fresh caps. A structure already
-- waiting is left where it is.
local function enqueueStation(sim: any, s: Structure)
	if s.queued then
		return
	end
	s.queued = true
	s.linkTries = 0
	s.linkMade = 0
	table.insert(sim.stationQueue, s)
end

-- Upstream's station gate, in one place. A FACTORY becomes a station the tick
-- it finishes and takes every city, port and factory within STATION_MAX_RANGE
-- onto the network with it (FactoryExecution.createStation :44-58); anything
-- else becomes a station only if a factory is already standing that close
-- (CityExecution :34-42, PortExecution :86-95).
--
-- THIS IS THE IMMEDIATE PATH, and it is upstream's. The periodic one is
-- sweepRails, which every RAIL_SWEEP_TICKS makes a station of everything
-- standing and links whatever is in range and unlinked -- so a city with no
-- factory near it is a stop within a minute rather than never. Upstream never
-- DEMOTES a station, and neither does this: a razed factory leaves the network
-- it created standing.
--
-- THE FLAG IS SET IMMEDIATELY, THE RAIL IS BUILT LATER. connectStation runs a
-- land A* per candidate and was measured at 28 ms for ONE station; a factory
-- promoting eight neighbours in a single tick would be a quarter-second
-- freeze. So promotion queues, and Economy.step lays STATION_LINKS_PER_TICK
-- of them. A station with no rail yet simply has no route, which is what it
-- would have had anyway.
local function promoteStations(sim: any, s: Structure)
	local maxR2 = Config.STATION_MAX_RANGE * Config.STATION_MAX_RANGE
	if s.kind == Economy.FACTORY then
		s.hasStation = true
		enqueueStation(sim, s)
		for _, other in sim.structList do
			if other ~= s and not other.hasStation and dist2(other.tile, s.tile) <= maxR2 then
				other.hasStation = true
				enqueueStation(sim, other)
			end
		end
		return
	end
	for _, other in sim.structList do
		if other.kind == Economy.FACTORY and dist2(other.tile, s.tile) <= maxR2 then
			s.hasStation = true
			enqueueStation(sim, s)
			return
		end
	end
end

-- Lay the rails for whatever is queued, RAIL_SEARCHES_PER_TICK land searches
-- a tick. A station that needs more than that stays at the head and carries
-- on next tick -- see connectStation. A structure that died while it waited
-- is dropped: the queue holds references, and unlinkStructure has no reason
-- to walk it.
local function stepStationQueue(sim: any)
	local q = sim.stationQueue
	local budget = Config.RAIL_SEARCHES_PER_TICK or 2
	local spent = 0
	while #q > 0 and spent < budget do
		local s = q[1] :: Structure
		if sim.structAt[s.tile] ~= s or not s.hasStation then
			table.remove(q, 1)
			s.queued = false
		else
			local before = s.linkTries
			local done = connectStation(sim, s, budget - spent)
			spent += s.linkTries - before
			if done then
				table.remove(q, 1)
				s.queued = false
			end
		end
	end
end

-- THE RAILWAY LAYS ITS OWN TRACK, ON A CLOCK (owner, 2026-09-06: "i want them
-- to automatically be built every X minute or so by the game to connect
-- everything"). Every structure is looked at once every RAIL_SWEEP_TICKS: if
-- it has a neighbour inside STATION_MAX_RANGE it cannot reach through the
-- rails within RAIL_MAX_CONNECTION_HOPS, it goes on the station queue, which
-- lays its links over the following ticks at the usual rate. Upstream links a
-- station once, when it is built; this is the pass that goes back for the
-- ones that were missed, the pairs that came into range later, and every city
-- and port that had no factory near it and so was never linked at all.
--
-- A SLICE A TICK, NOT THE WHOLE LIST AT ONCE. The first cut of this walked
-- every structure on one tick a minute, and on a 300-building map that tick
-- measured 100 ms -- a dist2 per pair and a bounded BFS per pair in range add
-- up. So a cursor walks structList at whatever pace covers it once per
-- sweep interval, and the cost is a fraction of a millisecond a tick. The
-- player sees the same thing either way: a building's line appears within a
-- minute of it going up, because the queue was already draining at
-- RAIL_SEARCHES_PER_TICK rather than all at once.
--
-- What keeps this cheap over a whole match is railFailed: a pair the land
-- search could not join is remembered and never asked again, because the
-- ground between two buildings does not change.
local function sweepRails(sim: any)
	local list = sim.structList
	local n = #list
	if n == 0 then
		return
	end
	local maxR2 = Config.STATION_MAX_RANGE * Config.STATION_MAX_RANGE
	local minR2 = Config.STATION_MIN_RANGE * Config.STATION_MIN_RANGE
	local cap = Config.RAIL_MAX_CONNECTION_HOPS
	local failed = sim.railFailed
	local per = math.ceil(n / (Config.RAIL_SWEEP_TICKS or 600))
	local at = sim.railSweepAt
	for _ = 1, per do
		at = at % n + 1
		local s = list[at]
		-- A station already holding its share is not looked at again: without
		-- this the sweep re-queues it every minute for the rest of the match
		-- and connectStation walks its candidates again to refuse them.
		if not s.queued and #s.rails < Config.RAIL_MAX_LINKS then
			for _, other in list do
				if other ~= s then
					local d = dist2(other.tile, s.tile)
					if d <= maxR2 and d > minR2
						and not failed[pairKey(s.tile, other.tile)]
						and graphHops(other, s, cap) == -1
					then
						enqueueStation(sim, s)
						break
					end
				end
			end
		end
	end
	sim.railSweepAt = at
end

-- ------------------------------------------------------------ structures ---

-- The two notifications Units sends a structure about its own unit. They are
-- what let Units.stepCapture raze and capture buildings without Economy being
-- on the tile-flip path at all.
--
-- unlinkStructure does NOT touch the unit: it is called FROM Units.delete.
local function unlinkStructure(sim: any, s: Structure)
	sim.structAt[s.tile] = nil
	local at = table.find(sim.structList, s)
	if at then
		-- ORDER-PRESERVING, not a swap-remove: three passes below consume RNG
		-- in structList order.
		table.remove(sim.structList, at)
	end
	-- Copied first: removeRail mutates the list being walked.
	for _, rail in table.clone(s.rails) do
		removeRail(sim, rail)
	end
	table.clear(s.rails)
end

local function onUnitDeleted(sim: any, u: any)
	local e = u.ext
	local s = e ~= nil and e.struct or nil
	if s ~= nil then
		e.struct = nil
		unlinkStructure(sim, s)
	end
end

-- Owner and level are the only two fields a Structure mirrors off its unit,
-- and Units fires this on every writer of either: capture (setOwner), a build
-- click that levels a building (upgrade) and a nuke taking a level off one
-- (decreaseLevel). tile and kind never change, so they are simply copied once.
local function onUnitSync(u: any)
	local e = u.ext
	local s = e ~= nil and e.struct or nil
	if s ~= nil then
		s.ownerId = u.ownerId
		s.level = u.level
	end
end

local function bind(u: any, s: Structure)
	local e = u.ext
	if e == nil then
		e = {}
		u.ext = e
	end
	e.struct = s
	e.onDelete = onUnitDeleted
	e.onSync = onUnitSync
end

-- Promote a finished unit to a STATION: give it the rail and trade state a
-- Unit does not carry, put it in the ordered station list and join it to the
-- network. Everything a structure IS -- id, owner, level, tile, grid cell,
-- counters, capture, the client event -- already belongs to the unit by the
-- time this runs.
--
-- `unit` is the site that just finished, if there was one: it has been
-- standing since the gold was spent, so it keeps its id, its counters and
-- whatever ownership the ground gave it while it was going up. Passing nil
-- creates the unit here instead, which is the path a structure placed by
-- anything other than the construction queue takes.
function Economy.add(sim: any, tile: number, ownerId: number, kind: number, level: number, unit: any?): Structure
	local s: Structure = {
		tile = tile,
		ownerId = ownerId,
		level = level,
		kind = kind,
		-- EVERYTHING IS A STATION (owner, 2026-09-06: "connect everything").
		-- Upstream's gate -- a factory within range -- used to decide this, and
		-- the rail sweep would flip it within a minute anyway; setting it here
		-- means the sweep can trust the flag on a neighbour it has not reached
		-- yet. What the flag no longer decides is who DISPATCHES: that is still
		-- the factory alone (stepStations), and that is the gate that matters.
		hasStation = true,
		rails = {},
		queued = false,
		linkTries = 0,
		linkMade = 0,
		nextTrainTick = 0,
		nextTradeTick = 0,
		-- Consecutive failed trade rolls, for the pity timer.
		tradeRejections = 0,
		clusterEpoch = 0,
		cluster = nil,
	}
	-- The unit owns the id, the grid cell, the counters and every event the
	-- client will see about this building.
	if unit ~= nil then
		s.unit = unit
	else
		s.unit = Units.spawn(sim, kind, ownerId, tile, { level = level })
	end
	bind(s.unit, s)
	sim.structAt[tile] = s
	table.insert(sim.structList, s)
	promoteStations(sim, s)
	return s
end

-- Raze a standing structure. A THIN FORWARDER now: deleting the unit is the
-- whole operation, and the onDelete hook unlinks the station, its rails and
-- its tile entry on the way through. Called by TribeExecution's razing of a
-- captured building (Sim.tribeRaze) and by nothing else -- ground falling to
-- nobody is Units.stepCapture's business.
function Economy.remove(sim: any, s: Structure)
	Units.delete(sim, s.unit)
end

-- Economy.transfer and Economy.onTileOwnerChanged are GONE, and their
-- deletion is the point of this migration step.
--
-- onTileOwnerChanged ran from Sim.conquer, on EVERY tile flip: Sim.
-- processAttack conquers up to Config.GLOBAL_TILE_BUDGET tiles a tick, plus
-- pocket mop-up, plus COLLAPSE_TILES_PER_TICK during an absorption -- four to
-- sixteen thousand hash lookups a tick to notice the handful of them that had
-- a building on. Upstream's GameImpl.conquer touches no units at all
-- (GameImpl.ts:749-768); capture is a once-per-player-per-tick sweep of that
-- player's own unit list (PlayerExecution.ts:45-67), whose cost is bounded by
-- how many units exist rather than by how fast the map is changing hands.
-- That sweep is Units.stepCapture, and Sim.step calls it.

-- ------------------------------------------------------------- placement ---

-- Land tile with at least one water 4-neighbour. Derived rather than read off
-- the terrain byte's shore bit, because that bit is set by MapGen for its own
-- purposes and a port standing one tile inland is a port with no sea.
local function isCoast(sim: any, tile: number): boolean
	if not TileMap.isPassable(sim.map, tile) then
		return false
	end
	local x, y = tx(tile), ty(tile)
	for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
		local nx, ny = x + d[1], y + d[2]
		if TileMap.inBounds(nx, ny) and not TileMap.isLand(sim.map, ny * W + nx) then
			return true
		end
	end
	return false
end

-- A port has to stand on the coast, and the coast is a line the player cannot
-- click precisely at low zoom. The reference searches outward from the click
-- for an owned ocean-shore tile (`radiusPortSpawn`); snapping is the feature,
-- not a convenience -- without it building a port is a pixel-hunt.
local function snapToCoast(sim: any, tile: number, playerId: number): number?
	if buffer.readu8(sim.map.owner, tile) == playerId and isCoast(sim, tile) then
		return tile
	end
	local r = Config.PORT_SPAWN_RADIUS
	local x0, y0 = tx(tile), ty(tile)
	local best, bestD = nil, math.huge
	for dy = -r, r do
		for dx = -r, r do
			local d = dx * dx + dy * dy
			if d <= r * r and d < bestD then
				local x, y = x0 + dx, y0 + dy
				if TileMap.inBounds(x, y) then
					local t = y * W + x
					if buffer.readu8(sim.map.owner, t) == playerId and isCoast(sim, t) then
						best, bestD = t, d
					end
				end
			end
		end
	end
	return best
end

-- Returns ok, reason, the structure an upgrade would land on, and the tile the
-- build would actually happen at (ports snap to the coast).
-- A DEFENCE POST THE PLAYER HAS ALREADY PAID FOR, in Robux, through Starter
-- Pack #1. It is asked in TWO places and it has to be the same question in
-- both: the affordability refusal in canBuild, and the charge in build.
-- Splitting that into two inline tests is exactly how the free warhead ended
-- up exempt at the charge while still being refused at the order -- it took
-- three sites to find. This is that lesson applied in advance.
--
-- ONE FIELD PER KIND (2026-09-17 evening): Starter Pack #2 sells a city and an
-- anti-nuke tower alongside the posts, so the predicate is asked per kind and
-- answers off this table. A fourth free building is one row here; the charge
-- below reads the same row. On Economy, not a local: this file has no
-- register to spare either.
Economy.FREE_FIELD = {
	[Economy.DEFENSE_POST] = "freePosts",
	[Economy.CITY] = "freeCities",
	[Economy.SAM_LAUNCHER] = "freeSams",
}
function Economy.freeBuild(p: any, kind: number): boolean
	local field = Economy.FREE_FIELD[kind]
	return field ~= nil and (p[field] or 0) > 0
end

function Economy.canBuild(sim: any, playerId: number, tile: number, kind: number): (boolean, string?, Structure?, number?)
	local p = sim.players[playerId]
	if not p or not p.alive or not p.spawned then
		return false, "dead"
	end
	if sim.phase ~= "playing" then
		return false, "phase"
	end

	-- THE FACTORY IS DISABLED (owner, 2026-09-18: "disable factories for now").
	-- Cities dispatch the trains it used to, so it would be a building that does
	-- nothing. One gate for everyone: the player's remote and the bots' build
	-- pass both come through here. Config.FACTORIES_ENABLED brings it back.
	if kind == Economy.FACTORY and not Config.FACTORIES_ENABLED then
		return false, "disabled"
	end

	local target = tile
	if kind == Economy.PORT then
		local snapped = snapToCoast(sim, tile, playerId)
		if not snapped then
			return false, "coast"
		end
		target = snapped
	else
		if buffer.readu8(sim.map.owner, target) ~= playerId then
			return false, "land"
		end
		if not TileMap.isPassable(sim.map, target) then
			return false, "terrain"
		end
	end

	-- Own structure of the SAME KIND in range: this is an upgrade, not a
	-- refusal. Checked before the crowding rule, because the two would
	-- otherwise contradict -- everything close enough to upgrade is also too
	-- close to build.
	-- A DEFENSE POST IS NOT UPGRADABLE (upstream's unitInfo carries no
	-- `upgradable`), so a click inside the spacing radius of one of your own is
	-- CROWDED and refused, not an upgrade. Economy.nearby would answer nil for
	-- one anyway -- a post is never promoted to a station, so nothing hangs a
	-- Structure off its unit -- but leaving the rule to be an accident of which
	-- index the lookup happens to use is how it comes back.
	local mine = not NOT_UPGRADABLE[kind]
		and Economy.nearby(sim, target, Config.STRUCTURE_MIN_DIST, playerId, kind)
		or nil
	-- NOT EVERY UPGRADABLE BUILDING IS A STATION. `Economy.nearby` answers with
	-- `u.ext.struct`, and only a city, a port and a factory are ever promoted to
	-- one (see stepSites) -- so for a MISSILE SILO or a SAM LAUNCHER, both of
	-- which Units.INFO marks upgradable and Units.upgrade has explicit code for,
	-- the lookup came back nil and the click fell through to the crowding rule.
	-- Measured: a finished tower answered "crowded" to its own upgrade tap and
	-- stayed at level 1 for ever, holding radius 70 of a possible 102 and one
	-- launch tube. The upgrade branch below only ever reads `.level` and
	-- `.unit`, so standing the unit in for the missing station is enough.
	if mine == nil and not NOT_UPGRADABLE[kind] then
		local u = Units.closest(sim, target, Config.STRUCTURE_MIN_DIST, kind, playerId, false)
		if u ~= nil and not u.underConstruction then
			mine = { unit = u, level = u.level } :: any
		end
	end
	if mine then
		if mine.level >= Config.STRUCTURE_MAX_LEVEL then
			return false, "maxlevel", mine, target
		end
		if p.gold < Economy.cost(p, kind) then
			return false, "gold", mine, target
		end
		return true, "upgrade", mine, target
	end

	-- Any structure of any kind and any owner inside the spacing radius blocks
	-- the build. ONE multi-type walk with an early exit rather than six
	-- closest-searches: this runs on every build click and, for a bot, on every
	-- one of BOT_BUILD_PROBES probes per roll.
	-- `true` is what folds the separate scan of the pending-sites list into
	-- this one walk: a site is a unit under construction, and two sites half a
	-- tile apart are as illegal as two finished buildings.
	if Units.anyNearby(sim, target, Config.STRUCTURE_MIN_DIST, Units.STRUCTURE_TYPES, ALWAYS, nil, true) then
		return false, "crowded", nil, target
	end
	-- The upgrade branch above is NOT given this exemption, ON PURPOSE: a free
	-- token buys a PLACEMENT. A post is never an upgrade; a city or a SAM can
	-- be (FREE_FIELD grew those two on 2026-09-17), and an upgrade is paid in
	-- gold like anyone else's. Economy.build spends the token only on a
	-- "build" result for the same reason -- see the note there.
	if not Economy.freeBuild(p, kind) and p.gold < Economy.cost(p, kind) then
		return false, "gold", nil, target
	end
	return true, "build", nil, target
end

-- Gold leaves the treasury NOW and the structure appears BUILD_TICKS later,
-- which is the reference's order (ConstructionExecution deducts on the tick it
-- places the site). Paying on completion instead would let one treasury fund
-- an unlimited number of simultaneous sites.
function Economy.build(sim: any, playerId: number, tile: number, kind: number): (boolean, string?, number?)
	local ok, why, existing, target = Economy.canBuild(sim, playerId, tile, kind)
	if not ok then
		return false, why, target
	end
	local p = sim.players[playerId]
	-- THE TOKEN IS SPENT HERE, NOT THE GOLD. This is the only line either
	-- leaves the player by, so a build refused anywhere upstream costs neither
	-- -- the same property the nuke's charge has.
	--
	-- ...AND ONLY A PLACEMENT SPENDS A TOKEN (2026-09-17 review). canBuild's
	-- upgrade branch prices an upgrade in gold and never reads the token, but
	-- this charge used to spend it on ANY accepted click: a Starter Pack #2
	-- holder who tapped inside their own city's radius upgraded it and lost
	-- the free city -- and when they were poor, the "gold" refusal fired the
	-- top-up, the receipt replayed the tap as an upgrade, and the token went
	-- with it. The two branches now agree: "build" may be free, "upgrade" is
	-- gold, and canBuild has already checked the gold is there.
	if why == "build" and Economy.freeBuild(p, kind) then
		local field = Economy.FREE_FIELD[kind]
		p[field] = (p[field] or 0) - 1
	else
		p.gold -= Economy.cost(p, kind)
	end
	-- `or 0` because a SAM launcher's counters arrived after the fields it
	-- prices off did: a Player built by an older sim has no samBuilt, and a
	-- nil arithmetic here would take the build path down with it.
	p[BUILT_FIELD[kind]] = (p[BUILT_FIELD[kind]] or 0) + 1

	if why == "upgrade" and existing then
		-- Upgrades land immediately. The reference charges a construction
		-- timer only for PLACING a structure, and a wait on a building that is
		-- already standing reads as a bug rather than as work.
		-- Units.upgrade writes the level, the counters, the client event and,
		-- through onSync, the station's copy. One writer.
		local s = existing :: Structure
		Units.upgrade(sim, s.unit)
		return true, "upgrade", target
	end

	-- A site is a UNIT UNDER CONSTRUCTION from here, not an entry in a
	-- parallel list. Upstream creates it on the tick the gold is spent and
	-- counts the construction immediately (PlayerImpl.ts:1307), so it occupies
	-- its tile against the spacing rule, changes hands with the ground under
	-- it, and is razed if that ground falls to nobody -- none of which the
	-- sites list could do.
	--
	-- Upstream gives a port a FIVE second build against a city's two.
	Units.spawn(sim, kind, playerId, target :: number, {
		underConstruction = true,
		-- A SAM takes TEN SECONDS to raise (Units.INFO, off Config.SAM_BUILD_TICKS
			-- since 2026-09-15), which is still the longest build in the game and
			-- is the whole balance of the thing: an anti-nuke tower is not an
			-- answer to a warhead already in the air. Read off Units.info rather
			-- than restated, because that is the table the AI's path reads too.
		buildTicks = (kind == Economy.PORT) and Config.PORT_BUILD_TICKS
			or (kind == Economy.DEFENSE_POST) and Config.DEFENSE_POST_BUILD_TICKS
			or (kind == Economy.SAM_LAUNCHER or kind == Economy.ARTILLERY or kind == Economy.AIRFIELD or kind == Economy.RAILGUN)
				and Units.info(kind).buildTicks
			or Config.CITY_BUILD_TICKS,
	})
	return true, "build", target
end

-- Construction. Upstream spends one ConstructionExecution object per site
-- and counts it down in tick() (ConstructionExecution.ts:46-98); Units keeps
-- one list of the units that are still going up and this drains whatever
-- finished. What is left here is only the part that is Economy's: turning a
-- finished unit into a STATION, which means a rail connection.
local DONE_BUF: { any } = {}

local function stepSites(sim: any)
	local n = Units.stepConstruction(sim, DONE_BUF)
	if n == 0 then
		return
	end
	if n > 1 then
		-- stepConstruction walks its list backwards, because a swap-remove
		-- cannot skip an entry that way -- so two sites finishing on the same
		-- tick come out newest first. Unit ids are spawn order, and spawn order
		-- is the order the old sites list completed in. That order is the order
		-- connectStation runs in, which fixes the rail graph, which fixes every
		-- train roll after it: it is part of the simulation, not a detail.
		table.sort(DONE_BUF, function(a, b)
			return a.id < b.id
		end)
	end
	for i = 1, n do
		local u = DONE_BUF[i]
		DONE_BUF[i] = nil
		-- A site whose ground was taken while it was being built completes for
		-- whoever holds it now; one whose ground fell back to open land is
		-- abandoned. The gold is already spent either way. Units.stepCapture
		-- has normally settled both by the time this runs, but it is one byte
		-- read and it is the difference between a wrong owner and a right one.
		local holder = buffer.readu8(sim.map.owner, u.tile)
		-- Only a city, port or factory becomes a STATION. A missile silo or a
		-- SAM launcher is a plain unit and has no business in structList: it
		-- would become a train stop, a trade partner and a rail endpoint. It
		-- still has to settle its ownership here, because the ground under it
		-- may have changed hands while it was going up.
		local station = u.utype == Economy.CITY
			or u.utype == Economy.PORT
			or u.utype == Economy.FACTORY
		if holder == 0 or (station and sim.structAt[u.tile] ~= nil) then
			Units.delete(sim, u)
		else
			if holder ~= u.ownerId then
				Units.setOwner(sim, u, holder)
			end
			if station then
				Economy.add(sim, u.tile, holder, u.utype, u.level, u)
			end
		end
	end
end

-- ============================================================ trading boats ==

-- ONE WATER GRID FOR THE WHOLE GAME, and it is Navy's. This module used to
-- build its own byte buffer with the same stride and the same "navigable if
-- ANY tile inside is water" rule -- a second 484k-tile scan at round setup,
-- and a second answer to "is there water here" that could drift from the one
-- the navy steers by. Navy.build already owns it, is cached per MAP across
-- rounds (the land mask is data, not noise), and now carries a channel ANCHOR
-- per cell: the water tile nearest the cell's centre, which is the tile a
-- trading boat actually steers for.
local SEA_STRIDE = Navy.STRIDE
local CW = Navy.GW
local CH = Navy.GH

local SEA_HEAP = Heap.new()
local SEA_DX = { 1, -1, 0, 0, 1, 1, -1, -1 }
local SEA_DY = { 0, 0, 1, -1, 1, -1, 1, -1 }

-- A* across the coarse water grid, 8-connected. It decides which way round
-- the continent; which WATER the trading boat is on is the fine pass below.
local function seaPath(sim: any, fromCell: number, toCell: number): { number }?
	-- WHICH BODY OF WATER THIS LANE IS ON, decided once and held for the whole
	-- search. A coarse step never changes body -- linked water is the same
	-- component on both sides -- so a route that starts in the North Sea stays
	-- in it, and the "no route" answer for a port on the wrong side of a
	-- continent costs one table walk instead of a 4,000-pop search that fails.
	local comp = Navy.sharedCellComp(sim.nav, fromCell, toCell)
	if comp == nil then
		return nil
	end
	local rep = sim.nav.rep
	local heap = SEA_HEAP
	Heap.clear(heap)
	local g: { [number]: number } = { [fromCell] = 0 }
	local cameFrom: { [number]: number } = {}
	Heap.push(heap, fromCell, 0)

	local gx = toCell % CW
	local gy = (toCell - gx) / CW
	local pops = 0
	local found = false
	while true do
		local cur = Heap.pop(heap)
		if cur == nil then
			break
		end
		pops += 1
		if pops > 4000 then
			break
		end
		if cur == toCell then
			found = true
			break
		end
		local cg = g[cur]
		if cg ~= nil then
			local x = cur % CW
			local y = (cur - x) / CW
			for k = 1, 8 do
				local nx, ny = x + SEA_DX[k], y + SEA_DY[k]
				if nx >= 0 and nx < CW and ny >= 0 and ny < CH then
					local nc = ny * CW + nx
					-- THE WATER HAS TO JOIN UP -- the same test Navy.path takes,
					-- and for the same reason. A cell is navigable on a single
					-- wet tile, so "both cells hold water" let a LANE be laid
					-- straight over a headland, and everything the fine pass
					-- below does after that is damage control: it fails to find
					-- a water route between two points no water joins, and ends
					-- up portaging a trading boat across a county. See
					-- Navy.canStep.
					if Navy.canStep(sim.nav, cur, comp, SEA_DX[k], SEA_DY[k]) then
						local step = (k <= 4) and 1 or 1.414
						local ng = cg + step
						if g[nc] == nil or ng < g[nc] then
							g[nc] = ng
							cameFrom[nc] = cur
							local ddx, ddy = nx - gx, ny - gy
							Heap.push(heap, nc, ng + math.sqrt(ddx * ddx + ddy * ddy))
						end
					end
				end
			end
		end
	end

	local path: { number }? = nil
	if found then
		local rev = { toCell }
		local cur = toCell
		while cur ~= fromCell do
			cur = cameFrom[cur]
			table.insert(rev, cur)
		end
		path = table.create(#rev)
		for i = #rev, 1, -1 do
			table.insert(path :: { number }, rev[i])
		end
	end

	return path
end

-- The line a trading boat actually sails, in TILES: every coarse leg refined into the
-- water route between the two cells' anchors, then reduced to the points
-- where it changes direction.
--
-- Refining once per LANE rather than per trading boat is the whole reason this is
-- affordable. A coarse route is cached per port-cell pair and reused by every
-- trading boat that ever runs it, so the fine pass rides the same cache entry and the
-- same one-search-a-tick allowance; hundreds of trading boats then sail it for free.
-- Open water costs almost nothing to refine (A* with an octile heuristic runs
-- straight down the line), and the legs that DO cost -- a bend in a river, a
-- strait, a bay to be rounded -- are exactly the ones worth paying for.
--
-- A LEG THAT FAILS IS THE WHOLE REMAINING PROBLEM, so it gets three chances
-- before it is allowed to draw a straight line over a headland. Measured on a
-- six-minute us/ffa match: hops were 5.5% of the time a trading boat was drawn and
-- 82% of them were over land, which is most of what is left.
--   1. the ordinary search, cheap and narrow;
--   2. a wider, deeper one -- affordable because this happens once per LANE,
--      not once per tick, and only on the legs that failed;
--   3. SKIP the anchor and aim at the next one. A cell counts as navigable
--      when any tile in it is wet, so its anchor can be a pond or a stretch
--      of river the route has no way into. It is a hint, not a waypoint.
--   4. PORTAGE: search again with land passable at a heavy cost. Measured on
--      a us/ffa match, 56 of 70 lanes carry at least one leg with no water
--      route -- the coarse grid is permissive on purpose and lays routes over
--      the land bridges these maps are drawn with (Dover, Gibraltar, the
--      Danish belts) -- so refusing them would have deleted four fifths of
--      all trade. A portage keeps the lane and makes the crossing as short as
--      the ground allows: over the isthmus at its neck, not across the county.
-- Chained from the last point actually reached rather than from the anchor,
-- so a skip does not leave the line starting from water we never got to.
local WIDE_CAP = 3000
local WIDE_PAD = 28
local MAX_SKIPS = 2
-- Cells this whole refinement may expand, across every leg of the lane. A
-- lane is refined in ONE tick, so without this a route round a ragged coast
-- pays for a wide retry and a portage on every one of forty legs and owns the
-- frame: measured at 90 ms against a 100 ms budget, where the same match's
-- next worst tick was 33. Past the budget the legs still get their ordinary
-- search, they just stop being retried, which costs a few tiles of accuracy
-- on the far end of the longest lanes on the map and nothing anywhere else.
local REFINE_BUDGET = 10000
-- Land steps cost this many water steps. High enough that a portage is always
-- the last few tiles of an otherwise wet route, low enough that the search
-- does not exhaust its cap crawling along the shore looking for a better one.
local PORTAGE_COST = 25

local function finePolyline(sim: any, cells: { number }): ({ number }, number)
	local nav = sim.nav
	local rep = nav.rep
	local map = sim.map
	local n = #cells
	-- Start on the anchor of the body the SECOND cell shares, not the first
	-- cell's nearest-to-centre water: a port whose cell holds a river as well
	-- as the sea would otherwise begin its lane in the river.
	local first = Navy.sharedCellComp(nav, cells[1], cells[2])
	local from = (first ~= nil and Navy.anchorIn(nav, cells[1], first))
		or (rep[cells[1] + 1] - 1)
	local pts = { from }
	local i = 2
	local skips = 0
	local hops = 0
	local budget = REFINE_BUDGET
	while i <= n do
		-- AIM AT AN ANCHOR ON THE WATER THIS BOAT IS ALREADY ON. A cell's `rep`
		-- is its nearest-to-centre water tile of ANY body, so on a cell where a
		-- river runs beside the sea the lane was being asked for a route from
		-- the sea to a point in the river -- which no water serves, so the leg
		-- failed and the fallbacks below drew a line over the bank. Reading the
		-- component off the tile the boat is standing on and taking that body's
		-- own anchor makes the leg answerable. Falls back to `rep` when the cell
		-- holds nothing of this body, which is what the skip below is for.
		local body = buffer.readi32(nav.tcomp, from * 4)
		local target = Navy.anchorIn(nav, cells[i], body) or (rep[cells[i] + 1] - 1)
		local leg = Navy.channel(map, from, target)
		budget -= Navy.lastExpanded
		if leg == nil and budget > 0 then
			leg = Navy.channel(map, from, target, WIDE_CAP, WIDE_PAD)
			budget -= Navy.lastExpanded
		end
		if leg ~= nil then
			for _, t in leg do
				pts[#pts + 1] = t
			end
			from = target
			skips = 0
			i += 1
		elseif skips < MAX_SKIPS and i < n then
			skips += 1
			i += 1
		else
			local portage = nil
			if budget > 0 then
				portage = Navy.channel(map, from, target, WIDE_CAP, WIDE_PAD, PORTAGE_COST)
				budget -= Navy.lastExpanded
			end
			if portage ~= nil then
				for _, t in portage do
					pts[#pts + 1] = t
				end
			else
				pts[#pts + 1] = target
			end
			from = target
			skips = 0
			hops += 1
			i += 1
		end
	end

	-- Straight runs collapse to their endpoints. Consecutive channel tiles are
	-- neighbours, so a run of identical steps IS a straight segment and
	-- dropping its interior changes nothing about where the trading boat goes -- it
	-- just makes an ocean crossing a dozen points instead of six hundred.
	local out = { pts[1] }
	local pdx, pdy = 0, 0
	for i = 2, #pts do
		local prev, cur = pts[i - 1], pts[i]
		local px, cx = prev % W, cur % W
		local dx = cx - px
		local dy = ((cur - cx) - (prev - px)) / W
		if dx ~= pdx or dy ~= pdy then
			out[#out + 1] = cur
			pdx, pdy = dx, dy
		else
			out[#out] = cur
		end
	end
	return out, hops
end

-- One lane, coarse and fine, found once and kept: `cells` for the distance
-- the trade payout is priced off, `pts` for where the trading boat is drawn.
local function seaRoute(sim: any, fromCell: number, toCell: number): any
	local key = fromCell * 100000 + toCell
	local cached = sim.seaPaths[key]
	if cached ~= nil then
		return cached or nil
	end
	-- Not cached, and this tick has already paid for one search. The caller
	-- treats nil as "no route today" and the port simply rolls again.
	if sim.seaPathBudget <= 0 then
		return nil
	end
	sim.seaPathBudget -= 1

	local cells = seaPath(sim, fromCell, toCell)
	local route: any = false
	if cells ~= nil and #cells >= 2 then
		local pts, hops = finePolyline(sim, cells)
		route = { cells = cells, pts = pts, hops = hops }
	end

	-- Cached including the failures: an unreachable pair stays unreachable all
	-- round, and re-running a 4,000-pop search to rediscover that is the worst
	-- thing this module could do per tick.
	if sim.seaPathCount > 4000 then
		sim.seaPaths = {}
		sim.seaPathCount = 0
	end
	sim.seaPaths[key] = route
	sim.seaPathCount += 1
	return route or nil
end

-- The water cell a port puts to sea from: its own cell if that is navigable,
-- otherwise the nearest one that is. Navy's spiral, which searches the same
-- three rings this used to walk by hand.
local function portCell(sim: any, tile: number): number?
	return Navy.waterCellNear(sim.nav, sim.map, tile)
end

-- Upstream `PortExecution.tradingPorts` (src/core/execution/PortExecution.ts:
-- 99-141): OTHER players' ports only, each entered
-- once per LEVEL, doubled if it is among the nearest few, doubled again if the
-- owner is friendly. Trade is a thing you do with your neighbours, never with
-- yourself -- which is what stops a corner of the map from being a closed
-- economy.
local function pickTradePartner(sim: any, port: Structure): Structure?
	local mine = port.ownerId
	local candidates = {}
	for _, s in sim.structList do
		if s.kind == Economy.PORT and s.ownerId ~= mine then
			local owner = sim.players[s.ownerId]
			-- REACHABLE BY SEA, tested before anything else. Upstream's
			-- tradingPorts filters on a shared water component
			-- (PortExecution.ts:97-118) and so does this; without it the
			-- weighting happily picks a port on the far side of a continent,
			-- the spawn roll is spent, and spawnTradingBoat then fails on a sea A*
			-- that finds nothing. Navy.reachable is an O(1) component test --
			-- the whole reason the answer "no" is cheap.
			if owner and owner.alive
				and Navy.reachable(sim.nav, sim.map, port.tile, s.tile)
				-- PlayerImpl.canTrade: an embargo from EITHER side closes the
				-- lane in both directions.
				and Alliances.canTrade(sim, mine, s.ownerId)
			then
				table.insert(candidates, s)
			end
		end
	end
	if #candidates == 0 then
		return nil
	end
	table.sort(candidates, function(a, b)
		return dist2(a.tile, port.tile) < dist2(b.tile, port.tile)
	end)

	-- The reference's `within(v, min, max)` is max(min, min(max, v)), which
	-- silently returns `min` when the bounds cross. `math.clamp` THROWS on
	-- that, and the bounds do cross constantly here -- any time the world
	-- holds fewer than PROXIMITY_PORTS_MIN ports, which is most of a round.
	local proximity = math.max(Config.PROXIMITY_PORTS_MIN, math.min(#candidates, #candidates / 3))
	local weighted = {}
	for i, other in candidates do
		local reps = other.level
		-- Upstream withholds BOTH bonuses from a port that is too close, using
		-- the same 300-tile figure the payout sigmoid turns on. Without it the
		-- weighting would keep steering trading boats onto exactly the short hops the
		-- gold curve is built to punish.
		local ax, bx = port.tile % W, other.tile % W
		local ay = (port.tile - ax) / W
		local by = (other.tile - bx) / W
		local tooClose = math.abs(ax - bx) + math.abs(ay - by) < Config.TRADE_SHORT_RANGE_DEBUFF
		if not tooClose and i <= proximity then
			reps += other.level
		end
		if not tooClose and (sim:sameTeam(mine, other.ownerId) or Alliances.allied(sim, mine, other.ownerId)) then
			reps += other.level
		end
		for _ = 1, reps do
			table.insert(weighted, other)
		end
	end
	if #weighted == 0 then
		return nil
	end
	return weighted[sim.rng:NextInteger(1, #weighted)]
end

-- OpenFrontIO `tradeShipSpawnRate(rejections, numTradeShips)`. A 1-in-N
-- chance rolled once per port LEVEL, where N grows as the sea fills up -- and
-- a PITY TIMER that shortens the odds every time a port rolls and misses. The
-- pity term is what stops a lone port on a quiet map from never trading: the
-- global brake alone would leave it rolling 1-in-100 forever.
local function tradeSpawnRate(rejections: number, numTradingBoats: number): number
	local base = 1 - sigmoid(numTradingBoats, Config.TRADE_SPAWN_DECAY, Config.TRADE_SPAWN_MID)
	if base <= 0.0001 then
		return 1000000
	end
	local rejectionMod = 1 / (rejections + 1)
	return math.max(1, math.min(1000000,
		math.floor(Config.TRADE_SPAWN_SCALE * rejectionMod / base)))
end

-- OpenFrontIO `tradeShipGold(dist, player)`. A SIGMOID, not a line, and there
-- is no longer any bonus for owning many ports:
--
--   75000 / (1 + e^(-0.03 * (dist - 300)))  +  50 * dist
--
-- The midpoint is TRADE_SHORT_RANGE_DEBUFF, so a hop under ~300 tiles earns a
-- small fraction of the plateau and a long crossing earns nearly all of it.
-- That is the whole design: trade is supposed to be worth crossing an ocean
-- for, and shuttling between two ports of your own on the same bay is not.
local function tradeGold(tilesTravelled: number): number
	local base = Config.TRADE_GOLD_SIG_MAX
		/ (1 + math.exp(-Config.TRADE_GOLD_SIG_K
			* (tilesTravelled - Config.TRADE_SHORT_RANGE_DEBUFF)))
		+ Config.TRADE_GOLD_PER_TILE * tilesTravelled
	-- Upstream multiplies the finished figure by the lobby's gold multiplier,
	-- here and in trainGold and goldAdditionRate and nowhere else.
	return math.floor(base * (Config.GOLD_MULTIPLIER or 1))
end

local function spawnTradingBoat(sim: any, src: Structure, dst: Structure)
	local a = portCell(sim, src.tile)
	local b = portCell(sim, dst.tile)
	if not a or not b then
		return
	end
	local route = seaRoute(sim, a, b)
	if not route then
		return
	end
	-- The route, the progress and the two ports are per-TYPE behaviour, so they
	-- live in ext; the id, the owner, the tile and the grid cell are the
	-- unit's. Upstream does the same by duck-typing the construction params
	-- into optional sub-objects (UnitImpl.ts:66-102).
	Units.spawn(sim, Units.TRADING_BOAT, src.ownerId, src.tile, {
		ext = {
			src = src,
			dst = dst,
			-- The lane, shared with every other trading boat on it and never written
			-- to: `cells` is the coarse route the payout is priced off,
			-- `pts` the water line this trading boat is drawn along.
			route = route,
			-- Where along `pts` it has got to: the segment, and how far into
			-- it in tiles. Trading boats advance one TILE per tick like the reference
			-- -- along the real water now, so a route that hugs a coast takes
			-- longer than the straight line it used to be drawn on, which is
			-- the honest answer and costs the payout nothing (see below).
			seg = 1,
			segD = 0,
			-- Drawn from the first point of the water line, not from the port.
			-- A port is a LAND tile: starting there put the trading boat on the quay
			-- for one send and then jumped it into the water.
			x = tx(route.pts[1]),
			y = ty(route.pts[1]),
		},
	})
	-- Reported so the caller's per-owner tally counts only trading boats that really
	-- sailed. The two early returns above are ordinary, not errors -- a port
	-- whose coast has no reachable sea cell -- and counting one of those would
	-- silently hold a slot of the owner's fleet open forever.
	return true
end

-- Float tile-space position -> the integer tile the unit is indexed at. A
-- trading boat is in the spatial grid so a gunboat can find it; without this it
-- would sit on its home port's cell for the whole crossing.
--
-- ROUNDED, NOT FLOORED, and that is not a rounding preference -- an integer
-- coordinate here IS a tile's centre (the client draws at (x + 0.5) / W), so
-- flooring answers with the tile down and left of where the trading boat is. On a
-- DIAGONAL run that tile is the corner between the two the line actually
-- passes through, which is exactly the corner Navy.channel refuses to cut
-- because it is usually land: measured on a us/ffa match, 9.7% of all
-- trading-boat ticks were reported ashore purely by this, on trading boats whose route was
-- water end to end.
local function moveTo(sim: any, u: any, x: number, y: number)
	local ix = math.clamp(math.round(x), 0, W - 1)
	local iy = math.clamp(math.round(y), 0, H - 1)
	Units.move(sim, u, iy * W + ix)
end

-- Walk a trading boat `speed` tiles along its lane, in tile space. Returns false once
-- the line runs out, which is arrival: the last point of `pts` is the
-- destination port's own water.
local function advance(e: any, speed: number): boolean
	local pts = e.route.pts
	local remaining = speed
	while remaining > 0 do
		local a = pts[e.seg]
		local b = pts[e.seg + 1]
		if b == nil then
			return false
		end
		local ax = a % W
		local ay = (a - ax) / W
		local bx = b % W
		local by = (b - bx) / W
		local dx, dy = bx - ax, by - ay
		local len = math.sqrt(dx * dx + dy * dy)
		if len <= 0 then
			e.seg += 1
			e.segD = 0
			continue
		end
		local left = len - e.segD
		if remaining < left then
			e.segD += remaining
			remaining = 0
			local f = e.segD / len
			e.x = ax + dx * f
			e.y = ay + dy * f
		else
			remaining -= left
			e.seg += 1
			e.segD = 0
			e.x = bx
			e.y = by
		end
	end
	return true
end

-- A PORT THAT JUST EARNED, queued for the one client that owns it. The cap is
-- not a bandwidth guard -- a person owns a handful of ports and a crossing
-- takes hundreds of ticks -- it is for the harnesses that step this sim with no
-- transport attached (ConquestSimulate), where nothing would ever drain the
-- list and it would grow for the whole benchmark.
local PAYOUT_QUEUE_MAX = 64

local function notePayout(sim: any, owner: any, tile: number, gold: number)
	-- The PLAYER ID, not the userId: a faux empire can be WEARING an absent
	-- person's userId, so the sender re-checks that this id is still the empire
	-- that Roblox player is playing before telling them anything.
	if owner.userId == nil then
		return
	end
	local q = sim.tradePayouts
	if q == nil or #q >= PAYOUT_QUEUE_MAX then
		return
	end
	q[#q + 1] = { id = owner.id, tile = tile, gold = gold }
end

local function stepTradingBoats(sim: any)
	local speed = Config.TRADING_BOAT_SPEED
	local list = Units.ofType(sim, Units.TRADING_BOAT)
	local i = 1
	while i <= #list do
		local tradingBoat = list[i]
		local e = tradingBoat.ext
		local src, dst = e.src, e.dst
		local dead = false

		-- The destination stopped being a trade partner: its port is gone, or
		-- it changed hands to the sender. The reference deletes the trading boat.
		if sim.structAt[dst.tile] ~= dst or sim.structAt[src.tile] ~= src
			or dst.ownerId == src.ownerId
		then
			dead = true
		else
			if not advance(e, speed) then
				-- Arrived. Both ends are paid, which is the whole reason a port
				-- is worth building next to a busy neighbour.
				--
				-- Priced off the COARSE route, not the water line the trading boat
				-- sailed. The payout curve was tuned against cell distance and
				-- following the real channel would have quietly raised every
				-- long trade by however much its coast wanders.
				local travelled = (#e.route.cells - 1) * SEA_STRIDE
				local gold = tradeGold(travelled)
				-- PIRACY. A trading boat taken by a gunboat pays its CAPTOR and nobody
				-- else: upstream credits addGold/addPiracyGold to the captor
				-- alone (TradeShipExecution.ts:171-181) and the two ports that
				-- arranged the trade get nothing, which is the whole cost of
				-- losing one.
				local pirate = e.wPirate and sim.players[e.wPirate]
				if pirate then
					if pirate.alive then
						pirate.gold += gold
					end
					sim.tradeGold += gold
				else
					local owner = sim.players[src.ownerId]
					if owner and owner.alive then
						owner.gold += gold
						notePayout(sim, owner, src.tile, gold)
					end
					local other = sim.players[dst.ownerId]
					if other and other.alive then
						other.gold += gold
						notePayout(sim, other, dst.tile, gold)
					end
					sim.tradeGold += gold * 2
				end
				dead = true
			else
				moveTo(sim, tradingBoat, e.x, e.y)
			end
		end

		-- Units.delete swap-removes from this very list, exactly as the manual
		-- sim.ships[i] = sim.ships[last] did, so the index does not advance.
		if dead then
			Units.delete(sim, tradingBoat)
		else
			i += 1
		end
	end
end

-- ONE TRADING BOAT AT SEA PER COMPLETED PORT -- the same ceiling the navy uses
-- (Gunboats.fleetCap), read off the same counter, so both fleets answer to the
-- one number a player can see on the map. `n - uc`, so a harbour still going
-- up does not yet carry a trading boat.
function Economy.tradeFleetCap(sim: any, playerId: number): number
	return Units.completedCount(sim, playerId, Units.PORT)
		* (Config.TRADING_BOATS_PER_PORT or 1)
end

local function stepPorts(sim: any)
	local tradingBoats = Units.ofType(sim, Units.TRADING_BOAT)
	local numTradingBoats = #tradingBoats
	-- Live trading boats per owner, tallied off the list this function already had to
	-- fetch for the crowding term. A counter on the player would be the O(1)
	-- answer and would also be the fragile one: a trading boat is deleted on ARRIVAL,
	-- deep inside stepTradingBoats, and every other way one can end (its port razed,
	-- its partner captured) would have to remember to decrement it. A tally
	-- over ~200 trading boats costs nothing next to the structure walk below.
	local afloat: { [number]: number } = {}
	for _, tradingBoat in tradingBoats do
		afloat[tradingBoat.ownerId] = (afloat[tradingBoat.ownerId] or 0) + 1
	end
	local rng = sim.rng
	for _, s in sim.structList do
		if s.kind == Economy.PORT and sim.tick >= s.nextTradeTick then
			s.nextTradeTick = sim.tick + Config.TRADE_CHECK_TICKS
			-- A port whose owner is already at the ceiling does not roll, and
			-- therefore banks NO PITY: being full is not a rejection, and
			-- letting it accumulate would hand a fleet that finally loses a
			-- trading boat an instant replacement. Same reasoning as the gunboat yard,
			-- which idles without banking its timer.
			if (afloat[s.ownerId] or 0) < Economy.tradeFleetCap(sim, s.ownerId) then
				local hit = false
				-- The rejection counter is PER PORT and is re-read inside the
				-- loop, because each miss shortens the next roll's odds --
				-- that is what makes it a pity timer rather than a flat rate.
				-- Rolling once per LEVEL is what a port upgrade buys now.
				for _ = 1, s.level do
					local rate = tradeSpawnRate(s.tradeRejections, numTradingBoats)
					if rng:NextInteger(1, rate) == 1 then
						s.tradeRejections = 0
						hit = true
						break
					end
					s.tradeRejections += 1
				end
				if hit then
					local partner = pickTradePartner(sim, s)
					if partner and spawnTradingBoat(sim, s, partner) then
						afloat[s.ownerId] = (afloat[s.ownerId] or 0) + 1
					end
				end
			end
		end
	end
end

-- ================================================================= trains ==

-- Upstream `trainSpawnRate(numPlayerFactories) = (factories + 10) * 15`
-- (src/core/configuration/Config.ts:383-387). An earlier build of this file
-- keyed N to the size of the rail CLUSTER instead; that is not upstream's.
-- It is keyed on the owner's FACTORY count, not on the size of the network --
-- so a sprawling rail map does not generate traffic in proportion to itself.
-- With the factory disabled (2026-09-18) the term is zero and the rate is the
-- flat BASE * MULT = 1,500 (base 100 since 2026-09-23): a level-1 city sends
-- a train about every 2 min 30 s, a level-5 city about every 30 s. Cities are
-- the dispatchers now.
-- Upstream `trainSpawnRate(numPlayerFactories) = (factories + 10) * 15`
-- (Config.ts:321-325), where `numPlayerFactories` is unitCount(Factory) --
-- the SUM OF LEVELS, not the number of buildings (PlayerImpl.ts:474-482).
-- More factories make each roll LESS likely; what raises an empire's output
-- is that it rolls once per level of every factory it owns.
local function trainSpawnRate(sim: any, ownerId: number): number
	return (Units.count(sim, ownerId, Units.FACTORY) + Config.TRAIN_SPAWN_BASE)
		* Config.TRAIN_SPAWN_MULT
end

-- Hops from `from` to `to` through the rail graph, as the list of stations.
local function stationPath(from: Structure, to: Structure): { Structure }?
	if from == to then
		return nil
	end
	local prev: { [any]: any } = { [from] = false }
	local queue = { from }
	local i = 1
	while i <= #queue do
		local cur = queue[i]
		i += 1
		for _, rail in cur.rails do
			local other = rail.from == cur and rail.to or rail.from
			if prev[other] == nil then
				prev[other] = cur
				if other == to then
					local out = { to }
					local walk: any = to
					while prev[walk] do
						walk = prev[walk]
						table.insert(out, 1, walk)
					end
					return out
				end
				table.insert(queue, other)
			end
		end
	end
	return nil
end

local function railBetween(a: Structure, b: Structure): any
	for _, rail in a.rails do
		if rail.from == b or rail.to == b then
			return rail
		end
	end
	return nil
end

local function spawnTrain(sim: any, station: Structure)
	local members = cluster(sim, station)
	if #members <= 1 then
		return
	end
	-- A TRADE destination is a city or a port, never another factory:
	-- upstream's Cluster keeps `tradeStations` filtered to City|Port
	-- (TrainStation.ts:163-166) and FactoryStopHandler.onStop pays nothing
	-- (:41-47). A factory is where trains come FROM.
	local available = {}
	for _, m in members do
		if m ~= station and m.kind ~= Economy.FACTORY then
			local owner = sim.players[m.ownerId]
			if owner and owner.alive then
				table.insert(available, m)
			end
		end
	end
	if #available == 0 then
		return
	end
	local dest = available[sim.rng:NextInteger(1, #available)]
	local path = stationPath(station, dest)
	if not path or #path < 2 then
		return
	end
	Units.spawn(sim, Units.TRAIN, station.ownerId, station.tile, {
		ext = {
			stations = path,
			leg = 1,
			tileIdx = 1,
			-- Stops made so far. Upstream decays the payout past the ninth, so
			-- a train that keeps going has to be counted, not just its
			-- destination.
			stops = 0,
			x = tx(station.tile),
			y = ty(station.tile),
		},
	})
end

local function stepTrains(sim: any)
	local list = Units.ofType(sim, Units.TRAIN)
	local i = 1
	while i <= #list do
		local train = list[i]
		local t = train.ext
		local dead = false
		local arrived = false
		local from = t.stations[t.leg]
		local to = t.stations[t.leg + 1]
		local rail = (from and to) and railBetween(from, to) or nil

		if not rail or sim.structAt[from.tile] ~= from or sim.structAt[to.tile] ~= to then
			-- The line was cut under the train, or one of its stops was razed.
			dead = true
		else
			t.tileIdx += Config.TRAIN_SPEED
			local tiles = rail.tiles
			local n = #tiles
			-- A rail's tiles run from `rail.from` to `rail.to`; a train going
			-- the other way reads the same list backwards.
			local forward = rail.from == from
			-- Which line the client should draw this train along. Held through
			-- the parked tick at a stop too: the station is an end of both the
			-- line just finished and the next, so either names the spot.
			t.railId = rail.id
			if t.tileIdx >= n then
				-- Stop reached. Gold is paid at EVERY station on the route,
				-- not only the last one, exactly as the reference does.
				-- OpenFrontIO `trainGold(rel, stopsVisited, player)` plus the
				-- payout split in TrainStation's stop handler. THREE changes
				-- from an earlier build of this file, all of them
				-- cutting rail income hard:
				--   * a stop on your OWN network pays 10,000, not 25,000;
				--   * there is NO (level + 1) multiplier any more;
				--   * the station owner is paid only when it is somebody
				--     else, so a self-stop pays once rather than twice.
				-- What is left is an incentive to run trains into a
				-- NEIGHBOUR's stations, which is the point of the mechanic.
				-- A FACTORY STOP PAYS NOTHING and does not count against the
				-- free-stop allowance: upstream routes City/Port to
				-- TradeStationStopHandler and Factory to a handler with an
				-- empty body, and only increments tradeStopsVisited for the
				-- first two (TrainStation.ts:15-47, TrainExecution.ts:264-273).
				-- Trains pass through factories on the way somewhere.
				local stationOwner = sim.players[to.ownerId]
				local trainOwner = sim.players[train.ownerId]
				local base
				if to.kind == Economy.FACTORY then
					base = nil
				elseif to.ownerId == train.ownerId then
					base = Config.TRAIN_GOLD_SELF
				elseif sim:sameTeam(to.ownerId, train.ownerId) then
					base = Config.TRAIN_GOLD_TEAM
				elseif Alliances.allied(sim, to.ownerId, train.ownerId) then
					-- TrainStation.ts:15-40 -- an ALLY'S station pays the most
					-- of all, which is the economic reason to keep one.
					base = Config.TRAIN_GOLD_ALLY
				else
					base = Config.TRAIN_GOLD_OTHER
				end
				if base ~= nil then
					-- The first few stops are free; past that each one is worth
					-- less, so a train circling a big network stops paying for it.
					local over = math.max(0, (t.stops or 0) - Config.TRAIN_GOLD_FREE_STOPS)
					local bonus = math.max(Config.TRAIN_GOLD_FLOOR,
						base - over * Config.TRAIN_GOLD_DECAY)
						* (Config.GOLD_MULTIPLIER or 1)
					t.stops = (t.stops or 0) + 1
					if to.ownerId ~= train.ownerId and stationOwner and stationOwner.alive then
						stationOwner.gold += bonus
						sim.trainStopGold += bonus
						-- The "+gold" pop the trading boats draw on their port, drawn on
						-- the station the train just paid at: rail is the other income
						-- with no click behind it, and until 2026-09-18 it was the one
						-- that moved the treasury with nothing on the map to show why.
						notePayout(sim, stationOwner, to.tile, bonus)
					end
					if trainOwner and trainOwner.alive then
						trainOwner.gold += bonus
						sim.trainStopGold += bonus
						notePayout(sim, trainOwner, to.tile, bonus)
					end
				end

				t.leg += 1
				t.tileIdx = t.tileIdx - n
				if t.leg + 1 > #t.stations then
					dead = true
				else
					-- Park AT the station for this tick. The position update
					-- below is written against `rail`, which is still the leg
					-- just finished, so letting it run would snap the train
					-- back to the start of the line it has just left.
					t.x = tx(to.tile)
					t.y = ty(to.tile)
					Units.move(sim, train, to.tile)
					arrived = true
				end
			end
			if not dead and not arrived then
				-- TRAIN_SPEED is fractional (1.6 since 2026-09-21), so the progress
				-- is floored before it indexes the tile list; the fraction rides
				-- along in t.tileIdx and carries across a stop in `t.tileIdx - n`.
				local whole = math.floor(t.tileIdx)
				local idx = forward and math.clamp(whole, 1, n)
					or math.clamp(n - whole + 1, 1, n)
				local tile = rail.tiles[idx]
				t.x = tx(tile)
				t.y = ty(tile)
				Units.move(sim, train, tile)
			end
		end

		-- Units.delete swap-removes from this very list, exactly as the manual
		-- sim.trains[i] = sim.trains[last] did, so the index does not advance.
		if dead then
			Units.delete(sim, train)
		else
			i += 1
		end
	end
end

-- ONLY A CITY DISPATCHES TRAINS (owner, 2026-09-18). Upstream gives the job
-- to the factory alone -- `spawnTrains = true` for exactly one caller,
-- FactoryExecution.ts:52 -- and this file did the same until the factory was
-- disabled (Config.FACTORIES_ENABLED). Ports are stops; a factory, should
-- one ever stand again, is a stop that pays nothing.
--
-- WHY THE DISPATCH KIND IS A GATE AT ALL, measured 2026-09-18 on the 72-bot
-- harness (us/777, 15 min): cities dispatching at the old spawn base of 10
-- paid 2.66B from rail against the factory build's 603M and every empire
-- banked 9x the gold. TRAIN_SPAWN_BASE 85 puts cities back on the factory
-- build's curve (2,518 trains vs 2,557; 661M vs 603M).
--
-- This is the single biggest economy finding in this file, so it is worth
-- stating what it was worth. With every structure dispatching, a measured
-- 30-minute 69-empire match on us/101 ran 3,570 trains at once and created
-- 35.3 BILLION gold from rail against 49 million from base income -- 96% of
-- all the money in the game, and 10.5 ms of tick time. Gold stopped being a
-- decision about five minutes in. The gate is not a detail of the port; it
-- is the mechanic.
local function stepStations(sim: any)
	local rng = sim.rng
	for _, s in sim.structList do
		if s.kind == Economy.CITY and #s.rails > 0 and sim.tick >= s.nextTrainTick then
			-- The rate uses the CACHED cluster size rather than the
			-- trade-filtered one the reference uses. The two differ by however
			-- many members are dead, and re-filtering every station every tick
			-- to move a log-ish rate by one is not worth the walk.
			local size = #cluster(sim, s)
			if size > 1 then
				local rate = trainSpawnRate(sim, s.ownerId)
				for _ = 1, s.level do
					if rng:NextInteger(1, rate) == 1 then
						s.nextTrainTick = sim.tick + Config.TRAIN_COOLDOWN_TICKS
						spawnTrain(sim, s)
						break
					end
				end
			end
		end
	end
end

-- =================================================================== tick ==

function Economy.step(sim: any)
	sim.seaPathBudget = 1
	stepSites(sim)
	sweepRails(sim)
	stepStationQueue(sim)
	stepPorts(sim)
	stepTradingBoats(sim)
	stepStations(sim)
	stepTrains(sim)
end

-- ============================================================== transport ==

-- SITES RIDE ALONG WITH THE FINISHED BUILDINGS. structList holds only what has
-- been PROMOTED (Economy.add runs on completion), so a snapshot built from it
-- alone leaves a joiner blind to everything currently going up -- for up to
-- thirty seconds on a SAM. sim.buildingUnits is already the exact list, kept by
-- Units.spawn and emptied by Units.stepConstruction, so this is a second walk
-- and no new state.
--
-- The two lists cannot collide: a tile holds one building, and a unit leaves
-- buildingUnits on the same tick it enters structList.
-- The three structure types that are never promoted to a station and so are
-- never in structList: a defense post, a missile silo and a SAM launcher.
-- Shared and never mutated.
local NON_STATION_STRUCTURES = { Units.DEFENSE_POST, Units.MISSILE_SILO, Units.SAM_LAUNCHER, Units.ARTILLERY, Units.AIRFIELD, Units.RAILGUN }

function Economy.snapshotStructures(sim: any): { any }
	local out = {}
	for _, s in sim.structList do
		-- `hp` (a fraction, nil when unhurt) so a joiner sees a shelled city's
		-- bar too -- see Units.emit.
		table.insert(out, { tile = s.tile, ownerId = s.ownerId, level = s.level, kind = s.kind, hp = Units.hpOf(s.unit) })
	end
	local building = sim.buildingUnits
	if building ~= nil then
		for _, u in building do
			-- Boats and nukes have no construction timer, so nothing else can be
			-- in here -- but this is the same guard drainStructEvents applies, and
			-- the snapshot must not be the one place a non-structure slips through.
			if u.active and Units.isStructure(u.utype) then
				table.insert(out, {
					tile = u.tile,
					ownerId = u.ownerId,
					level = u.level,
					kind = u.utype,
					uc = true,
					-- Ticks left AS OF NOW, not the full duration: a joiner arriving
					-- four seconds into a five-second port must see the fill nearly
					-- done, not restarting.
					left = u.buildDoneTick - sim.tick,
					hp = Units.hpOf(u),
				})
			end
		end
	end
	-- ...AND SO DO THE STRUCTURES THAT ARE NOT STATIONS. structList holds only
	-- what Economy.add promoted -- cities, ports, factories -- so a FINISHED
	-- defense post, missile silo or SAM launcher is in neither list above, and a
	-- joiner never hears about it. The live event stream carries them
	-- (drainStructEvents passes everything with utype <= STRUCTURE_LAST), which
	-- is exactly why this stayed invisible: everybody present when one went up
	-- could see it and nobody arriving afterwards could.
	for _, t in NON_STATION_STRUCTURES do
		for _, u in Units.ofType(sim, t) do
			if u.active and not u.underConstruction then
				-- `rl` so a JOINER sees a reloading tower's bar too. Without it a
				-- launcher that fired just before someone arrived would read as
				-- ready to them for the rest of its cooldown.
				table.insert(out, {
					tile = u.tile,
					ownerId = u.ownerId,
					level = u.level,
					kind = u.utype,
					rl = Units.reloadLeft(sim, u),
					rt = Units.reloadTotal(sim, u),
					hp = Units.hpOf(u),
				})
			end
		end
	end
	return out
end

function Economy.snapshotRails(sim: any): { any }
	local out = {}
	for _, r in sim.rails do
		table.insert(out, { a = r.from.tile, b = r.to.tile, pts = decimate(r.tiles), id = r.id })
	end
	return out
end

-- The STRUCTURE slice of the unit event stream. Trading boats, trains and transport boats ride
-- the same stream and are filtered out here rather than being given a second
-- one.
--
-- UNDER-CONSTRUCTION EVENTS USED TO BE FILTERED OUT HERE TOO, on the grounds
-- that a building site is not a thing the client draws. It was the wrong call,
-- and it was the single worst piece of feedback in the game: the client learned
-- about a building only when it FINISHED, so a click cost gold, changed nothing
-- on the map, and paid out two seconds later for a city, five for a port, ten
-- for a missile silo and TEN for a SAM launcher. From the player's seat that
-- is indistinguishable from a click that never registered, and the natural
-- response -- click again -- spends the gold twice.
--
-- Both events now go through and the client draws the site (Structures.set's
-- `uc` argument). The snapshot a JOINER gets is still completed structures
-- only, because it is built from sim.structList and a site is not in it yet:
-- someone joining mid-build sees the building appear when it finishes, which
-- is what everyone used to see.
function Economy.drainStructEvents(sim: any): { any }?
	local ev = Units.drainEvents(sim)
	if ev == nil then
		return nil
	end
	local out: { any }? = nil
	for _, e in ev do
		if Units.isStructure(e.kind) then
			if out == nil then
				out = {}
			end
			local o = out :: { any }
			o[#o + 1] = e
		end
	end
	return out
end

-- The ports paid since the last drain. Nil rather than an empty table, so the
-- caller skips the send on the ordinary tick -- the same contract as every
-- other drain here.
function Economy.drainTradePayouts(sim: any): { any }?
	local q = sim.tradePayouts
	if q == nil or #q == 0 then
		return nil
	end
	sim.tradePayouts = {}
	return q
end

function Economy.drainRailEvents(sim: any): { any }?
	if #sim.railEvents == 0 then
		return nil
	end
	local out = sim.railEvents
	sim.railEvents = {}
	return out
end

-- Trading boats and trains, in one list. Positions are floats in tile space; the
-- client tweens between broadcasts rather than being sent every tick.
-- Ids come from the ONE unit counter now, so a trading boat, a train and a transport boat
-- can never collide on the wire and the client's per-id marker map needs no
-- offsets. See Sim.vehicles, which used to add one.
function Economy.vehicles(sim: any): { any }
	local out = {}
	for _, s in Units.ofType(sim, Units.TRADING_BOAT) do
		local e = s.ext
		table.insert(out, { id = s.id, kind = Economy.TRADING_BOAT, owner = s.ownerId, x = e.x, y = e.y })
	end
	for _, t in Units.ofType(sim, Units.TRAIN) do
		local e = t.ext
		table.insert(out, { id = t.id, kind = Economy.TRAIN, owner = t.ownerId, x = e.x, y = e.y, rail = e.railId or 0 })
	end
	return out
end

-- The land search, exposed for the harness that measures it and for nothing
-- in the game: every caller in here goes through connectStation.
Economy.landPath = landPath

return Economy
