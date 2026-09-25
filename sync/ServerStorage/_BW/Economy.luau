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
-- Warships and piracy ARE ported now (Conquest.Warships); a trade ship can
-- be captured, and the captor takes the whole payout.
-- NOT ported:
-- factories (the reference gates stations behind one; here every structure is
-- a station), and the cosmetic carriages behind a train's engine.

local Config = require(script.Parent.Config)
local Heap = require(script.Parent.Heap)
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
Economy.CITY = 1
Economy.PORT = 2

Economy.SHIP = 1
Economy.TRAIN = 2

export type Structure = {
	tile: number,
	ownerId: number,
	level: number,
	kind: number,
	-- Rails leaving this structure. Every structure is a station; the
	-- reference gates that behind a nearby Factory, which this game has no
	-- equivalent of.
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

-- Forward-declared: the sea grid is built during init, which is defined here
-- and implemented several hundred lines below with the rest of the water
-- code. Without the declaration the call reads a nil upvalue.
local buildSeaGrid: (any) -> buffer

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

	sim.seaOpen = nil :: buffer?
	sim.seaPaths = {} :: { [number]: { number } }
	sim.seaPathCount = 0
	-- At most one UNCACHED sea route may be searched per tick. Measured: with
	-- the search running on demand, one tick hit 229 ms against a 100 ms
	-- budget. A skipped spawn is invisible -- the port rolls again in
	-- TRADE_CHECK_TICKS -- whereas a blown tick is felt by everyone.
	sim.seaPathBudget = 0

	sim.trainStopGold = 0
	sim.tradeGold = 0

	-- Paid here, off the tick loop, alongside the map generation this round
	-- has already budgeted for.
	buildSeaGrid(sim)
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
local COUNT_FIELD = { "cityCount", "portCount" }
local BUILT_FIELD = { "cityBuilt", "portBuilt" }

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
function Economy.cost(p: any, kind: number): number
	local n = math.min(p[COUNT_FIELD[kind]], p[BUILT_FIELD[kind]])
	if kind == Economy.PORT then
		return math.min(Config.PORT_COST_CAP, Config.PORT_COST_GROWTH ^ n * Config.PORT_COST_BASE)
	end
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
		if other ~= s then
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
	connectStation(sim, s)
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
		if holder == 0 or sim.structAt[u.tile] ~= nil then
			Units.delete(sim, u)
		else
			if holder ~= u.ownerId then
				Units.setOwner(sim, u, holder)
			end
			Economy.add(sim, u.tile, holder, u.utype, u.level, u)
		end
	end
end

-- ============================================================ trade ships ==

local SEA_STRIDE = 8
local CW = math.ceil(W / SEA_STRIDE)
local CH = math.ceil(H / SEA_STRIDE)

-- One byte per coarse cell: navigable if ANY tile inside it is water. "Any"
-- rather than "the centre" on purpose -- a centre sample closes every strait
-- narrower than the stride, and the maps in this game are deliberately full of
-- straits with land bridges over them.
--
-- BUILT AT ROUND SETUP, not on demand. It is a scan of all 1.6M terrain bytes,
-- and doing that lazily put the whole cost on whichever gameplay tick the
-- first trade ship happened to sail on. Sim.new already spends ~400 ms
-- generating the map, so a one-off pass there is free; the same pass inside
-- the tick loop is a visible hitch for every player at once.
function buildSeaGrid(sim: any): buffer
	if sim.seaOpen then
		return sim.seaOpen
	end
	local open = buffer.create(CW * CH)
	local terrain = sim.map.terrain
	for cy = 0, CH - 1 do
		for cx = 0, CW - 1 do
			local found = 0
			local y1 = math.min(H - 1, cy * SEA_STRIDE + SEA_STRIDE - 1)
			local x1 = math.min(W - 1, cx * SEA_STRIDE + SEA_STRIDE - 1)
			for y = cy * SEA_STRIDE, y1 do
				local row = y * W
				for x = cx * SEA_STRIDE, x1 do
					if not TileMap.isLandByte(buffer.readu8(terrain, row + x)) then
						found = 1
						break
					end
				end
				if found == 1 then
					break
				end
			end
			buffer.writeu8(open, cy * CW + cx, found)
		end
	end
	sim.seaOpen = open
	return open
end

local SEA_HEAP = Heap.new()
local SEA_DX = { 1, -1, 0, 0, 1, 1, -1, -1 }
local SEA_DY = { 0, 0, 1, -1, 1, -1, 1, -1 }

-- A* across the coarse water grid, 8-connected. Ships are drawn as markers and
-- their only mechanical output is a DISTANCE, so tile-exact routing would be
-- paying full price for something nothing reads.
local function seaPath(sim: any, fromCell: number, toCell: number): { number }?
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

	local open = buildSeaGrid(sim)
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
					if buffer.readu8(open, nc) == 1 then
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

	-- Cached including the failures: an unreachable pair stays unreachable all
	-- round, and re-running a 20,000-pop search to rediscover that is the
	-- worst thing this module could do per tick.
	if sim.seaPathCount > 4000 then
		sim.seaPaths = {}
		sim.seaPathCount = 0
	end
	sim.seaPaths[key] = path or false :: any
	sim.seaPathCount += 1
	return path
end

-- The water cell a port puts to sea from: its own cell if that is navigable,
-- otherwise the nearest one that is.
local function portCell(sim: any, tile: number): number?
	local open = buildSeaGrid(sim)
	local cx = tx(tile) // SEA_STRIDE
	local cy = ty(tile) // SEA_STRIDE
	for r = 0, 3 do
		for dy = -r, r do
			for dx = -r, r do
				if math.max(math.abs(dx), math.abs(dy)) == r then
					local nx, ny = cx + dx, cy + dy
					if nx >= 0 and nx < CW and ny >= 0 and ny < CH then
						local c = ny * CW + nx
						if buffer.readu8(open, c) == 1 then
							return c
						end
					end
				end
			end
		end
	end
	return nil
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
			if owner and owner.alive then
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
	return math.floor(base)
end

local function spawnShip(sim: any, src: Structure, dst: Structure)
	local a = portCell(sim, src.tile)
	local b = portCell(sim, dst.tile)
	if not a or not b then
		return
	end
	local path = seaPath(sim, a, b)
	if not path or #path < 2 then
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
			path = path,
			-- Progress along the coarse path, in CELLS. Ships advance one TILE
			-- per tick like the reference, and a cell is SEA_STRIDE tiles wide.
			progress = 0,
			x = tx(src.tile),
			y = ty(src.tile),
		},
	})
end

-- Float tile-space position -> the integer tile the unit is indexed at. A
-- trade ship is in the spatial grid so a warship can find it; without this it
-- would sit on its home port's cell for the whole crossing.
local function moveTo(sim: any, u: any, x: number, y: number)
	local ix = math.clamp(math.floor(x), 0, W - 1)
	local iy = math.clamp(math.floor(y), 0, H - 1)
	Units.move(sim, u, iy * W + ix)
end

local function stepShips(sim: any)
	local perCell = Config.TRADE_SHIP_SPEED / SEA_STRIDE
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
			e.progress += perCell
			local idx = math.floor(e.progress) + 1
			if idx >= #e.path then
				-- Arrived. Both ends are paid, which is the whole reason a port
				-- is worth building next to a busy neighbour.
				local travelled = (#e.path - 1) * SEA_STRIDE
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
				-- Linear between the two coarse cells either side of progress,
				-- so the marker slides instead of hopping eight tiles a second.
				local c0 = e.path[idx]
				local c1 = e.path[idx + 1]
				local f = e.progress - math.floor(e.progress)
				local x0 = (c0 % CW + 0.5) * SEA_STRIDE
				local y0 = ((c0 - c0 % CW) / CW + 0.5) * SEA_STRIDE
				local x1 = (c1 % CW + 0.5) * SEA_STRIDE
				local y1 = ((c1 - c1 % CW) / CW + 0.5) * SEA_STRIDE
				e.x = x0 + (x1 - x0) * f
				e.y = y0 + (y1 - y0) * f
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

local function stepPorts(sim: any)
	local numShips = #Units.ofType(sim, Units.TRADE_SHIP)
	local rng = sim.rng
	for _, s in sim.structList do
		if s.kind == Economy.PORT and sim.tick >= s.nextTradeTick then
			s.nextTradeTick = sim.tick + Config.TRADE_CHECK_TICKS
			local hit = false
			-- The rejection counter is PER PORT and is re-read inside the loop,
			-- because each miss shortens the next roll's odds -- that is what
			-- makes it a pity timer rather than a flat rate.
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
				if partner then
					spawnShip(sim, s, partner)
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
local function trainSpawnRate(): number
	return (Config.TRAIN_SPAWN_FACTORIES + Config.TRAIN_SPAWN_BASE)
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
	local available = {}
	for _, m in members do
		if m ~= station then
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
				local stationOwner = sim.players[to.ownerId]
				local trainOwner = sim.players[train.ownerId]
				local base
				if to.ownerId == train.ownerId then
					base = Config.TRAIN_GOLD_SELF
				elseif sim:sameTeam(to.ownerId, train.ownerId) then
					base = Config.TRAIN_GOLD_TEAM
				else
					base = Config.TRAIN_GOLD_OTHER
				end
				-- The first few stops are free; past that each one is worth
				-- less, so a train circling a big network stops paying for it.
				local over = math.max(0, (t.stops or 0) - Config.TRAIN_GOLD_FREE_STOPS)
				local bonus = math.max(Config.TRAIN_GOLD_FLOOR,
					base - over * Config.TRAIN_GOLD_DECAY)
				t.stops = (t.stops or 0) + 1
				if to.ownerId ~= train.ownerId and stationOwner and stationOwner.alive then
					stationOwner.gold += bonus
					sim.trainStopGold += bonus
				end
				if trainOwner and trainOwner.alive then
					trainOwner.gold += bonus
					sim.trainStopGold += bonus
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

local function stepStations(sim: any)
	local rng = sim.rng
	for _, s in sim.structList do
		if #s.rails > 0 and sim.tick >= s.nextTrainTick then
			-- The rate uses the CACHED cluster size rather than the
			-- trade-filtered one the reference uses. The two differ by however
			-- many members are dead, and re-filtering every station every tick
			-- to move a log-ish rate by one is not worth the walk.
			local size = #cluster(sim, s)
			if size > 1 then
				local rate = trainSpawnRate()
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
