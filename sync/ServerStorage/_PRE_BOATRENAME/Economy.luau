--!strict
-- Conquest :: Economy  (server only)
--
-- Everything gold touches: structures (cities and ports), the trade-ship
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
--   Trade ship     TradeShipExecution + tradeShipGold + tradeShipSpawnRate
--                  + PlayerImpl.tradingPorts (the level/proximity weighting)
--   Rail           RailNetworkImpl.connectToNearbyStations
--   Train          TrainStationExecution + TrainExecution + TrainStation's
--                  stop handlers (trainGold * (level + 1))
--   Factory        unitInfo(Factory) + FactoryExecution + the station gate in
--                  CityExecution/PortExecution.createStation
-- Warships and piracy ARE ported now (Conquest.Warships); a trade ship can
-- be captured, and the captor takes the whole payout. Factories ARE ported
-- now too, and with them the rule that made rail an economy rather than a
-- fountain -- see stepStations.
-- NOT ported: the cosmetic carriages behind a train's engine.

local Config = require(script.Parent.Config)
local Heap = require(script.Parent.Heap)
local Navy = require(script.Parent.Navy)
local TileMap = require(script.Parent.TileMap)
-- ONE record for every structure, ship, boat and vehicle in the game, plus
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

Economy.SHIP = 1
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

	-- No sim.ships, no sim.trains, no nextVehicleId. A trade ship is a
	-- Units.TRADE_SHIP and a train is a Units.TRAIN, they draw their ids from
	-- the one unit counter, and their per-type lists ARE the iteration order
	-- this file used to keep by hand -- Units appends on spawn and swap-removes
	-- on delete, which is exactly what stepShips and stepTrains did with
	-- sim.ships[i] = sim.ships[last]. Same order, same evolution, one list.

	-- Routes between two port cells, coarse cells plus the fine water polyline
	-- a hull actually sails. Keyed by the pair, so every ship that ever runs
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

	-- Structures promoted to stations and still waiting for their rails. See
	-- promoteStations for why the connection is deferred.
	sim.stationQueue = {} :: { Structure }
end

-- ------------------------------------------------------- per-kind counters --
-- `cityLevels` is load-bearing outside this module: Sim.maxTroops adds it to
-- the troop ceiling. The port counters exist only so the cost curve and the
-- trade-ship bonus can read them.

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
local COUNT_FIELD = { [1] = "cityCount", [2] = "portCount", [6] = "factoryCount" }
local BUILT_FIELD = { [1] = "cityBuilt", [2] = "portBuilt", [6] = "factoryBuilt" }

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
function Economy.cost(p: any, kind: number): number
	if kind == Economy.PORT or kind == Economy.FACTORY then
		local n = math.min(p.portCount, p.portBuilt)
			+ math.min(p.factoryCount or 0, p.factoryBuilt or 0)
		return math.min(Config.PORT_COST_CAP, Config.PORT_COST_GROWTH ^ n * Config.PORT_COST_BASE)
	end
	local n = math.min(p[COUNT_FIELD[kind]], p[BUILT_FIELD[kind]])
	return math.min(Config.CITY_COST_CAP, Config.CITY_COST_GROWTH ^ n * Config.CITY_COST_BASE)
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
-- needs 30, a warship 130, a SAM 600. Units.closest walks the exact cell
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

-- A* over land tiles inside the bounding box of the two endpoints, padded.
-- Bounded twice: by the box (so a rail can never wander across the map) and by
-- a pop budget. Returns nil rather than a long path -- the reference likewise
-- refuses any route at or past `railroadMaxSize`.
local function landPath(sim: any, from: number, to: number): { number }?
	local map = sim.map
	local fx, fy = tx(from), ty(from)
	local gx, gy = tx(to), ty(to)
	local pad = 24
	local minX = math.max(0, math.min(fx, gx) - pad)
	local maxX = math.min(W - 1, math.max(fx, gx) + pad)
	local minY = math.max(0, math.min(fy, gy) - pad)
	local maxY = math.min(H - 1, math.max(fy, gy) + pad)

	local heap = RAIL_HEAP
	Heap.clear(heap)
	local gScore: { [number]: number } = { [from] = 0 }
	local cameFrom: { [number]: number } = {}
	Heap.push(heap, from, 0)

	-- A rail is capped at RAIL_MAX_TILES anyway, and this search is 4-connected
	-- with an admissible Euclidean heuristic inside a padded box -- if it has
	-- not arrived in this many pops the route it is hunting for is longer than
	-- a rail is allowed to be, so giving up early costs nothing and bounds the
	-- spike. Measured: connectStation's worst call was 47.6 ms at 6000.
	local pops = 0
	local MAX_POPS = 2500
	local nbuf = table.create(4)

	while true do
		local cur = Heap.pop(heap)
		if cur == nil then
			return nil
		end
		pops += 1
		if pops > MAX_POPS then
			return nil
		end
		if cur == to then
			break
		end
		local g = gScore[cur]
		if g ~= nil then
			local n = TileMap.neighbors4(cur, nbuf)
			for k = 1, n do
				local nb = nbuf[k]
				local nx, ny = tx(nb), ty(nb)
				if nx >= minX and nx <= maxX and ny >= minY and ny <= maxY
					and TileMap.isPassable(map, nb)
				then
					local ng = g + 1
					if ng < Config.RAIL_MAX_TILES and (gScore[nb] == nil or ng < gScore[nb]) then
						gScore[nb] = ng
						cameFrom[nb] = cur
						local dx = nx - gx
						local dy = ny - gy
						Heap.push(heap, nb, ng + math.sqrt(dx * dx + dy * dy))
					end
				end
			end
		end
	end

	local path = { to }
	local cur = to
	while cur ~= from do
		cur = cameFrom[cur]
		table.insert(path, cur)
	end
	-- Reversed so tiles[1] is the `from` station: a train reading the list
	-- forwards is travelling a -> b, and backwards is travelling b -> a.
	local out = table.create(#path)
	for i = #path, 1, -1 do
		table.insert(out, path[i])
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

local function addRail(sim: any, a: Structure, b: Structure, tiles: { number })
	local rail = { from = a, to = b, tiles = tiles, id = #sim.rails + 1 }
	table.insert(sim.rails, rail)
	table.insert(a.rails, rail)
	table.insert(b.rails, rail)
	sim.railEpoch += 1
	table.insert(sim.railEvents, { a = a.tile, b = b.tile, pts = decimate(tiles) })
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
local function connectStation(sim: any, s: Structure)
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

	-- BOTH of these caps exist because this is the only expensive thing the
	-- economy does, and it runs on a tick that is already the busiest one --
	-- a structure completing. Late in a match a new station can have a dozen
	-- candidates within 80 tiles, and each one that survives the hop test
	-- costs a land A*: measured at 47.6 ms for a single connectStation call.
	-- The nearest few are also the only ones that make a sensible railway.
	local tried, links = 0, 0
	for _, c in candidates do
		if tried >= 6 or links >= 3 then
			break
		end
		local hops = graphHops(c.s, s, Config.RAIL_MAX_CONNECTION_HOPS)
		if hops == -1 or hops > Config.RAIL_MAX_CONNECTION_HOPS then
			tried += 1
			local path = landPath(sim, s.tile, c.s.tile)
			if path and #path > 1 and #path < Config.RAIL_MAX_TILES then
				addRail(sim, s, c.s, path)
				links += 1
			end
		end
	end
end

-- Upstream's station gate, in one place. A FACTORY becomes a station the tick
-- it finishes and takes every city, port and factory within STATION_MAX_RANGE
-- onto the network with it (FactoryExecution.createStation :44-58); anything
-- else becomes a station only if a factory is already standing that close
-- (CityExecution :34-42, PortExecution :86-95).
--
-- No periodic sweep, and none is needed: between those two rules every
-- ordering is covered -- a factory built first promotes the buildings that
-- arrive around it, a building built first is promoted by the factory that
-- arrives later -- and upstream never DEMOTES a station, so a razed factory
-- leaves the network it created standing.
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
		table.insert(sim.stationQueue, s)
		for _, other in sim.structList do
			if other ~= s and not other.hasStation and dist2(other.tile, s.tile) <= maxR2 then
				other.hasStation = true
				table.insert(sim.stationQueue, other)
			end
		end
		return
	end
	for _, other in sim.structList do
		if other.kind == Economy.FACTORY and dist2(other.tile, s.tile) <= maxR2 then
			s.hasStation = true
			table.insert(sim.stationQueue, s)
			return
		end
	end
end

-- Lay the rails for whatever was promoted, a bounded number per tick. A
-- structure that died while it waited is dropped: the queue holds references,
-- and unlinkStructure has no reason to walk it.
local function stepStationQueue(sim: any)
	local q = sim.stationQueue
	local laid = 0
	while #q > 0 and laid < (Config.STATION_LINKS_PER_TICK or 1) do
		local s = table.remove(q, 1) :: Structure
		if sim.structAt[s.tile] == s and s.hasStation then
			connectStation(sim, s)
			laid += 1
		end
	end
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
		hasStation = false,
		rails = {},
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
function Economy.canBuild(sim: any, playerId: number, tile: number, kind: number): (boolean, string?, Structure?, number?)
	local p = sim.players[playerId]
	if not p or not p.alive or not p.spawned then
		return false, "dead"
	end
	if sim.phase ~= "playing" then
		return false, "phase"
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
	local mine = Economy.nearby(sim, target, Config.STRUCTURE_MIN_DIST, playerId, kind)
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
	if p.gold < Economy.cost(p, kind) then
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
	p.gold -= Economy.cost(p, kind)
	p[BUILT_FIELD[kind]] += 1

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
		buildTicks = (kind == Economy.PORT) and Config.PORT_BUILD_TICKS
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

-- ============================================================ trade ships ==

-- ONE WATER GRID FOR THE WHOLE GAME, and it is Navy's. This module used to
-- build its own byte buffer with the same stride and the same "navigable if
-- ANY tile inside is water" rule -- a second 484k-tile scan at round setup,
-- and a second answer to "is there water here" that could drift from the one
-- the navy steers by. Navy.build already owns it, is cached per MAP across
-- rounds (the land mask is data, not noise), and now carries a channel ANCHOR
-- per cell: the water tile nearest the cell's centre, which is the tile a
-- trade ship actually steers for.
local SEA_STRIDE = Navy.STRIDE
local CW = Navy.GW
local CH = Navy.GH

local SEA_HEAP = Heap.new()
local SEA_DX = { 1, -1, 0, 0, 1, 1, -1, -1 }
local SEA_DY = { 0, 0, 1, -1, 1, -1, 1, -1 }

-- A* across the coarse water grid, 8-connected. It decides which way round
-- the continent; which WATER the hull is on is the fine pass below.
local function seaPath(sim: any, fromCell: number, toCell: number): { number }?
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
					if rep[nc + 1] ~= 0 then
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

-- The line a hull actually sails, in TILES: every coarse leg refined into the
-- water route between the two cells' anchors, then reduced to the points
-- where it changes direction.
--
-- Refining once per LANE rather than per ship is the whole reason this is
-- affordable. A coarse route is cached per port-cell pair and reused by every
-- ship that ever runs it, so the fine pass rides the same cache entry and the
-- same one-search-a-tick allowance; hundreds of hulls then sail it for free.
-- Open water costs almost nothing to refine (A* with an octile heuristic runs
-- straight down the line), and the legs that DO cost -- a bend in a river, a
-- strait, a bay to be rounded -- are exactly the ones worth paying for.
--
-- A LEG THAT FAILS IS THE WHOLE REMAINING PROBLEM, so it gets three chances
-- before it is allowed to draw a straight line over a headland. Measured on a
-- six-minute us/ffa match: hops were 5.5% of the time a hull was drawn and
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
	local rep = sim.nav.rep
	local map = sim.map
	local n = #cells
	local from = rep[cells[1] + 1] - 1
	local pts = { from }
	local i = 2
	local skips = 0
	local hops = 0
	local budget = REFINE_BUDGET
	while i <= n do
		local target = rep[cells[i] + 1] - 1
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
	-- dropping its interior changes nothing about where the hull goes -- it
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
-- the trade payout is priced off, `pts` for where the hull is drawn.
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
			-- the spawn roll is spent, and spawnShip then fails on a sea A*
			-- that finds nothing. Navy.reachable is an O(1) component test --
			-- the whole reason the answer "no" is cheap.
			if owner and owner.alive
				and Navy.reachable(sim.nav, sim.map, port.tile, s.tile)
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
		-- weighting would keep steering ships onto exactly the short hops the
		-- gold curve is built to punish.
		local ax, bx = port.tile % W, other.tile % W
		local ay = (port.tile - ax) / W
		local by = (other.tile - bx) / W
		local tooClose = math.abs(ax - bx) + math.abs(ay - by) < Config.TRADE_SHORT_RANGE_DEBUFF
		if not tooClose and i <= proximity then
			reps += other.level
		end
		if not tooClose and sim:sameTeam(mine, other.ownerId) then
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
local function tradeSpawnRate(rejections: number, numShips: number): number
	local base = 1 - sigmoid(numShips, Config.TRADE_SPAWN_DECAY, Config.TRADE_SPAWN_MID)
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

local function spawnShip(sim: any, src: Structure, dst: Structure)
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
	Units.spawn(sim, Units.TRADE_SHIP, src.ownerId, src.tile, {
		ext = {
			src = src,
			dst = dst,
			-- The lane, shared with every other hull on it and never written
			-- to: `cells` is the coarse route the payout is priced off,
			-- `pts` the water line this hull is drawn along.
			route = route,
			-- Where along `pts` it has got to: the segment, and how far into
			-- it in tiles. Ships advance one TILE per tick like the reference
			-- -- along the real water now, so a route that hugs a coast takes
			-- longer than the straight line it used to be drawn on, which is
			-- the honest answer and costs the payout nothing (see below).
			seg = 1,
			segD = 0,
			-- Drawn from the first point of the water line, not from the port.
			-- A port is a LAND tile: starting there put the hull on the quay
			-- for one send and then jumped it into the water.
			x = tx(route.pts[1]),
			y = ty(route.pts[1]),
		},
	})
	-- Reported so the caller's per-owner tally counts only hulls that really
	-- sailed. The two early returns above are ordinary, not errors -- a port
	-- whose coast has no reachable sea cell -- and counting one of those would
	-- silently hold a slot of the owner's fleet open forever.
	return true
end

-- Float tile-space position -> the integer tile the unit is indexed at. A
-- trade ship is in the spatial grid so a warship can find it; without this it
-- would sit on its home port's cell for the whole crossing.
--
-- ROUNDED, NOT FLOORED, and that is not a rounding preference -- an integer
-- coordinate here IS a tile's centre (the client draws at (x + 0.5) / W), so
-- flooring answers with the tile down and left of where the hull is. On a
-- DIAGONAL run that tile is the corner between the two the line actually
-- passes through, which is exactly the corner Navy.channel refuses to cut
-- because it is usually land: measured on a us/ffa match, 9.7% of all
-- ship-ticks were reported ashore purely by this, on hulls whose route was
-- water end to end.
local function moveTo(sim: any, u: any, x: number, y: number)
	local ix = math.clamp(math.round(x), 0, W - 1)
	local iy = math.clamp(math.round(y), 0, H - 1)
	Units.move(sim, u, iy * W + ix)
end

-- Walk a hull `speed` tiles along its lane, in tile space. Returns false once
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

local function stepShips(sim: any)
	local speed = Config.TRADE_SHIP_SPEED
	local list = Units.ofType(sim, Units.TRADE_SHIP)
	local i = 1
	while i <= #list do
		local ship = list[i]
		local e = ship.ext
		local src, dst = e.src, e.dst
		local dead = false

		-- The destination stopped being a trade partner: its port is gone, or
		-- it changed hands to the sender. The reference deletes the ship.
		if sim.structAt[dst.tile] ~= dst or sim.structAt[src.tile] ~= src
			or dst.ownerId == src.ownerId
		then
			dead = true
		else
			if not advance(e, speed) then
				-- Arrived. Both ends are paid, which is the whole reason a port
				-- is worth building next to a busy neighbour.
				--
				-- Priced off the COARSE route, not the water line the hull
				-- sailed. The payout curve was tuned against cell distance and
				-- following the real channel would have quietly raised every
				-- long trade by however much its coast wanders.
				local travelled = (#e.route.cells - 1) * SEA_STRIDE
				local gold = tradeGold(travelled)
				-- PIRACY. A hull taken by a warship pays its CAPTOR and nobody
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
					end
					local other = sim.players[dst.ownerId]
					if other and other.alive then
						other.gold += gold
					end
					sim.tradeGold += gold * 2
				end
				dead = true
			else
				moveTo(sim, ship, e.x, e.y)
			end
		end

		-- Units.delete swap-removes from this very list, exactly as the manual
		-- sim.ships[i] = sim.ships[last] did, so the index does not advance.
		if dead then
			Units.delete(sim, ship)
		else
			i += 1
		end
	end
end

-- ONE TRADE SHIP AT SEA PER COMPLETED PORT -- the same ceiling the navy uses
-- (Warships.fleetCap), read off the same counter, so both fleets answer to the
-- one number a player can see on the map. `n - uc`, so a harbour still going
-- up does not yet carry a ship.
function Economy.tradeFleetCap(sim: any, playerId: number): number
	return Units.completedCount(sim, playerId, Units.PORT)
		* (Config.TRADE_SHIPS_PER_PORT or 1)
end

local function stepPorts(sim: any)
	local ships = Units.ofType(sim, Units.TRADE_SHIP)
	local numShips = #ships
	-- Live hulls per owner, tallied off the list this function already had to
	-- fetch for the crowding term. A counter on the player would be the O(1)
	-- answer and would also be the fragile one: a ship is deleted on ARRIVAL,
	-- deep inside stepShips, and every other way one can end (its port razed,
	-- its partner captured) would have to remember to decrement it. A tally
	-- over ~200 hulls costs nothing next to the structure walk below.
	local afloat: { [number]: number } = {}
	for _, ship in ships do
		afloat[ship.ownerId] = (afloat[ship.ownerId] or 0) + 1
	end
	local rng = sim.rng
	for _, s in sim.structList do
		if s.kind == Economy.PORT and sim.tick >= s.nextTradeTick then
			s.nextTradeTick = sim.tick + Config.TRADE_CHECK_TICKS
			-- A port whose owner is already at the ceiling does not roll, and
			-- therefore banks NO PITY: being full is not a rejection, and
			-- letting it accumulate would hand a fleet that finally loses a
			-- ship an instant replacement. Same reasoning as the warship yard,
			-- which idles without banking its timer.
			if (afloat[s.ownerId] or 0) < Economy.tradeFleetCap(sim, s.ownerId) then
				local hit = false
				-- The rejection counter is PER PORT and is re-read inside the
				-- loop, because each miss shortens the next roll's odds --
				-- that is what makes it a pity timer rather than a flat rate.
				-- Rolling once per LEVEL is what a port upgrade buys now.
				for _ = 1, s.level do
					local rate = tradeSpawnRate(s.tradeRejections, numShips)
					if rng:NextInteger(1, rate) == 1 then
						s.tradeRejections = 0
						hit = true
						break
					end
					s.tradeRejections += 1
				end
				if hit then
					local partner = pickTradePartner(sim, s)
					if partner and spawnShip(sim, s, partner) then
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
-- This game has no factories, so the term is zero and the rate is the constant
-- floor of 150: a level-1 station sends a train roughly every fifteen seconds.
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
					end
					if trainOwner and trainOwner.alive then
						trainOwner.gold += bonus
						sim.trainStopGold += bonus
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
				local idx = forward and math.clamp(t.tileIdx, 1, n)
					or math.clamp(n - t.tileIdx + 1, 1, n)
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

-- ONLY A FACTORY DISPATCHES TRAINS. Upstream builds every station with
-- `new TrainStationExecution(unit)` and passes `spawnTrains = true` for
-- exactly one caller -- the factory that created the station
-- (FactoryExecution.ts:52). Cities and ports are stops.
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
		if s.kind == Economy.FACTORY and #s.rails > 0 and sim.tick >= s.nextTrainTick then
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
	stepStationQueue(sim)
	stepPorts(sim)
	stepShips(sim)
	stepStations(sim)
	stepTrains(sim)
end

-- ============================================================== transport ==

function Economy.snapshotStructures(sim: any): { any }
	local out = {}
	for _, s in sim.structList do
		table.insert(out, { tile = s.tile, ownerId = s.ownerId, level = s.level, kind = s.kind })
	end
	return out
end

function Economy.snapshotRails(sim: any): { any }
	local out = {}
	for _, r in sim.rails do
		table.insert(out, { a = r.from.tile, b = r.to.tile, pts = decimate(r.tiles) })
	end
	return out
end

-- The STRUCTURE slice of the unit event stream. Ships, trains and boats ride
-- the same stream and are filtered out here rather than being given a second
-- one; so are the events an UNDER-CONSTRUCTION unit fires, because a building
-- site is not a thing the client draws.
function Economy.drainStructEvents(sim: any): { any }?
	local ev = Units.drainEvents(sim)
	if ev == nil then
		return nil
	end
	local out: { any }? = nil
	for _, e in ev do
		if e.kind <= Units.STRUCTURE_LAST and not e.uc then
			if out == nil then
				out = {}
			end
			local o = out :: { any }
			o[#o + 1] = e
		end
	end
	return out
end

function Economy.drainRailEvents(sim: any): { any }?
	if #sim.railEvents == 0 then
		return nil
	end
	local out = sim.railEvents
	sim.railEvents = {}
	return out
end

-- Ships and trains, in one list. Positions are floats in tile space; the
-- client tweens between broadcasts rather than being sent every tick.
-- Ids come from the ONE unit counter now, so a ship, a train and a transport
-- can never collide on the wire and the client's per-id marker map needs no
-- offsets. See Sim.vehicles, which used to add one.
function Economy.vehicles(sim: any): { any }
	local out = {}
	for _, s in Units.ofType(sim, Units.TRADE_SHIP) do
		local e = s.ext
		table.insert(out, { id = s.id, kind = Economy.SHIP, owner = s.ownerId, x = e.x, y = e.y })
	end
	for _, t in Units.ofType(sim, Units.TRAIN) do
		local e = t.ext
		table.insert(out, { id = t.id, kind = Economy.TRAIN, owner = t.ownerId, x = e.x, y = e.y })
	end
	return out
end

return Economy
