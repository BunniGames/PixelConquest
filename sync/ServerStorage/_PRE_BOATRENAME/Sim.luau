--!strict
-- Conquest :: Sim  (server only)
-- The whole simulation: players, territory, attacks, AI, win condition.
--
-- Runs at Config.TICK_RATE on the server, which is authoritative. Clients
-- receive only owner deltas; they regenerate terrain from the seed themselves.

local Config = require(script.Parent.Config)
-- Structures, ports, trade ships, rails and trains. Kept out of this file
-- because none of it needs to interleave with the attack loop -- it needs
-- the map, the players and the tick, and nothing else.
local Economy = require(script.Parent.Economy)
local Heap = require(script.Parent.Heap)
local MapGen = require(script.Parent.MapGen)
local Maps = require(script.Parent.Maps)
local Modes = require(script.Parent.Modes)
local TileMap = require(script.Parent.TileMap)
local Navy = require(script.Parent.Navy)
-- Silos, launchers, missiles, warheads and the fallout bit. Requires Units and
-- Economy; requires nothing that requires Sim.
local Nukes = require(script.Parent.Nukes)
-- Every structure, ship, boat and warhead as ONE record, with the spatial
-- index, the per-player counters and the once-per-tick territory-capture
-- sweep over them.
local Units = require(script.Parent.Units)
-- Warships, shells, and the piracy verbs applied to Economy's trade ships and
-- this file's transports. Hulls come from PORTS, not from the treasury -- see
-- that module's header; it is a deliberate deviation from upstream.
local Warships = require(script.Parent.Warships)

local W = Config.MAP_W
local H = Config.MAP_H
local N = Config.NUM_TILES

local Sim = {}
Sim.__index = Sim

export type Player = {
	id: number,
	name: string,
	userId: number?,
	isBot: boolean,
	troops: number,
	-- ECONOMY (ported from upstream openfrontio/OpenFrontIO,
	-- src/core/configuration/Config.ts -- see the economy block in Config).
	-- Gold is flat income, so it is the only quantity in the game that does
	-- not compound with territory.
	gold: number,
	-- Cities OWNED (capture included), the sum of their levels, and how many
	-- construct events this empire has paid for. The reference prices the next
	-- city off min(owned, built), so losing cities makes rebuilding cheaper and
	-- capturing them never makes it dearer.
	cityCount: number,
	cityLevels: number,
	cityBuilt: number,
	-- Running coordinate sums over owned tiles, maintained in Sim.conquer.
	-- Only the bot city placer reads them; O(1) beats a scan of a territory
	-- that can be a quarter of the map.
	sumX: number,
	sumY: number,
	tileCount: number,
	border: { [number]: true },
	-- Kept in step with `border` at every mutation point. Counting a set is a
	-- full walk, and the AI needs the size every time it thinks -- on a late
	-- round that was tens of thousands of iterations per bot per think, for a
	-- number the mutation sites already know.
	borderCount: number,
	alive: boolean,
	spawned: boolean,
	spawnTile: number?,
	thinkOffset: number,
	-- Per-bot personality, rolled once in addPlayer. Optional so a Player
	-- built by anything that predates this still runs on the Config means.
	aiThink: number?,
	aiIdle: number?,
	aiExpandReserve: number?,

	aiWarReserve: number?,
	aiTrigger: number?,
	-- Ports were never listed in this type even though addPlayer has always
	-- set them.
	portCount: number,
	portLevels: number,
	portBuilt: number,
	-- Factories. They give no troops and are never a paying train stop; what
	-- they do is turn the cities and ports around them into stations and
	-- dispatch the trains. Counted separately because they share the PORT cost
	-- ladder (Economy.cost) while being their own thing everywhere else.
	factoryCount: number,
	factoryLevels: number,
	factoryBuilt: number,
	-- WHICH AI CLASS: Config.TIER_HUMAN / _TRIBE / _NATION / _LEGACY.
	-- `isBot` keeps its exact old meaning (tier is not TIER_HUMAN), so
	-- Net.packSummary and Palette.isBot are untouched and the wire does not
	-- move.
	tier: number,
	-- TribeExecution.ts:12 -- a TRIBE stops testing for unclaimed ground for
	-- good once its frontier is all other empires (:115-121). A NATION
	-- re-tests it on every think (AiAttackBehavior.ts:89-95), so this is set
	-- only on the tribe path.
	tnLatched: boolean?,
	-- TribeExecution.ts:47-60 / NationExecution.ts:175-179: the FIRST think is
	-- a special case in both upstream classes and was one in neither here.
	aiSeeded: boolean?,

	-- Where the last border sample stopped, so the next think resumes
	-- instead of walking the set from the front to reach a fresh window.
	scanCursor: number?,
	killedBy: number?,
}

-- A transport ship in flight is a Units.TRANSPORT_SHIP. The id, the owner,
-- the tile, the grid cell and the troops aboard are the unit's own fields;
-- the crossing state -- targetId, dst, path, pathIdx, leg -- sits in ext, the
-- same split every other unit type uses. `path` is a list of coarse waypoints
-- from Navy.path and `leg` the fine water route to the current one from
-- Navy.channel; the boat walks the leg and advances the waypoint index when it
-- arrives. Troops are OUT of the owner's pool from the moment it
-- sails, exactly as a land attack's are -- so an empire that ships half its
-- army away is visibly weaker at home while the crossing happens, which is
-- the whole risk of an invasion.
--
-- self.boats survives as an ORDERED list beside Units' type index, and that
-- is not redundancy. Two boats landing on the same tick spawn two attacks,
-- and attack ids fix the order the global tile budget is handed out in the
-- following tick -- so the order boats are stepped in is part of the
-- simulation. Units' lists swap-remove; this one does not.
export type Boat = any

export type Attack = {
	attackerId: number,
	targetId: number,
	troops: number,
	-- Set only for an amphibious landing. A boat attack seeds its frontier
	-- from the beachhead alone and never merges with a land push on the same
	-- target -- upstream keys both behaviours off exactly this being non-nil
	-- (`AttackExecution.sourceTile`). Merging one in would teleport the
	-- landing's troops back to the home front the moment it touched down.
	sourceTile: number?,
	frontier: Heap.Heap,
	-- Distinct tiles currently on the front. Tracked separately from the heap
	-- because the heap deliberately holds duplicates (lazy decrease-key).
	borderSet: { [number]: true },
	borderCount: number,
	-- This attack's own clock, in the delay units enqueue works in, and
	-- the reason a strong push still advances faster than a weak one now
	-- that readiness gates the front. See Config.FRONTIER_PACE.
	clock: number,
	-- Best (lowest) priority currently in the heap for each front tile. This
	-- is what makes the lazy decrease-key lazy instead of a leak.
	prio: { [number]: number },
	-- Tick this attack's frontier was last seeded from the whole border.
	seedTick: number,
	-- Running sums of the front's tile coordinates, kept in step with
	-- borderSet. The army's position on the map is then O(1) rather than
	-- a scan of a front that can be thousands of tiles wide.
	sumX: number,
	sumY: number,
	-- Stable across reinforcement, so a client label follows one army
	-- instead of flickering as the summary list is rebuilt each send.
	id: number,
	active: boolean,
}

-- A built city. `level` is what the troop bonus is multiplied by, and it is
-- what transfers when the tile changes hands -- a captured city is worth
-- exactly what it was worth to the empire that paid for it.
export type City = {
	tile: number,
	ownerId: number,
	level: number,
}

export type Sim = typeof(setmetatable({} :: any, Sim))

-- =========================================================== construction ==

-- `mapId` indexes the Maps roster ("us", "europe", ...) and `modeId` the
-- Modes roster ("ffa", "duo", "trio"). The server picks both per round and
-- ships them to clients, which regenerate the same terrain and paint the same
-- teams.
function Sim.new(mapId: string, seed: number, modeId: string?)
	local mapData = Maps.get(mapId)
	local terrain, landCount = MapGen.generate(mapId, seed)
	local map = TileMap.new(terrain, landCount)
	local candidates, playable = MapGen.analyze(terrain, mapData.MIN_LANDMASS or 1500)

	local self = setmetatable({
		mapId = mapId,
		seed = seed,
		-- Per-round "how hard is this ground" field (0 soft .. 255 hard).
		-- Never drawn and never replicated; it exists only to make fronts
		-- bulge through soft country instead of advancing as a straight line.
		rough = MapGen.roughness(seed),
		map = map,
		-- Coarse water-connectivity graph, built once per map and cached
		-- across rounds (the land mask is data, not noise, so it does not
		-- vary by seed). See Navy.
		nav = Navy.build(map, mapId),
		boats = {} :: { Boat },
		candidates = candidates,
		playableLand = math.max(playable, 1),
		-- Tiles conquerable per tick across all attacks, scaled with this
		-- map's size so every map fills in comparable time.
		tileBudget = math.max(
			Config.TILE_BUDGET_MIN,
			math.floor(
				Config.GLOBAL_TILE_BUDGET
					* math.max(playable, 1)
					/ Config.TILE_BUDGET_REFERENCE_LAND
			)
		),
		-- Upstream's absolute bar (AttackExecution.ts:428). NOT scaled by map
		-- size, because upstream does not scale it. Left on the sim table so
		-- ConquestSimulate's collapse= / collapseshare= sweep still works.
		collapseTiles = Config.DEAD_DEFENDER_TILES,

		-- Mode. teamCount 0 is a free-for-all and every team path below is
		-- inert, so the free-for-all balance is bit-for-bit what it was.
		modeId = modeId or "ffa",
		teamCount = Modes.get(modeId).TEAMS,
		teamOf = {} :: { [number]: number },
		teamSizes = {} :: { [number]: number },
		teamAnchors = {} :: { [number]: number },

		players = {} :: { [number]: Player },
		playerOrder = {} :: { number },
		byUserId = {} :: { [number]: number },
		nextId = 1,

		attacks = {} :: { Attack },
		nextAttackId = 1,

		phase = "lobby", -- lobby | spawn | playing | ended
		tick = 0,
		phaseTick = 0,
		winnerId = nil :: number?,
		winnerTeam = nil :: number?,

		changes = table.create(4096),
		changeCount = 0,

		rng = Random.new(seed),
		-- TWO neighbour scratch buffers, and the split is load-bearing.
		-- Callers iterate nbuf while calling enqueue(), which needs its own
		-- neighbour lookup; sharing one buffer let enqueue overwrite the list
		-- being walked, so neighbours after the first were read from the
		-- wrong tile. Every other column went unclaimed forever and territory
		-- came out as a comb (26.6% of tiles disagreed with their left
		-- neighbour vs 5.4% above).
		nbuf = table.create(4),
		nbuf2 = table.create(4),
		nbuf3 = table.create(4),
		-- nbuf4 belongs to the conquest loop alone. Nothing it calls touches
		-- it, so one neighbour lookup can serve all three passes over the
		-- same tile instead of three.
		nbuf4 = table.create(4),

		-- Empires waiting to be absorbed, a slice at a time.
		collapses = {} :: { { victimId: number, captorId: number, cursor: number } },

		-- ------------------------------------------------------- structures --
		-- Nothing here. cityAt, cityList, cityCells, sites and cityEvents were
		-- superseded by Economy and then by Units, and every one of them had
		-- been dead for longer than it looked: the live tables are sim.units,
		-- sim.unitsByType, sim.unitCells and sim.unitStats (Units.init, called
		-- just below) plus sim.structAt and sim.structList (Economy.init).
	}, Sim)

	-- The unit tables first: Economy writes into them from its own init.
	Units.init(self)
	-- Structures, rails, ships and trains. Everything gold touches lives in
	-- Economy and hangs off the sim table from here.
	Economy.init(self)
	Warships.init(self)
	-- Fallout buffer, execution list and event queue. After Economy because it
	-- reads sim.structList to reach the structures Economy still owns.
	Nukes.init(self)

	Sim.assignTeamAnchors(self)

	return self
end

-- ================================================================ players ==

function Sim.addPlayer(self: Sim, name: string, isBot: boolean, userId: number?, tier: number?): Player?
	if self.nextId > 255 then
		return nil
	end
	local id = self.nextId
	self.nextId += 1

	local p: Player = {
		id = id,
		name = name,
		userId = userId,
		isBot = isBot,
		troops = 0,
		gold = 0,
		cityCount = 0,
		cityLevels = 0,
		cityBuilt = 0,
		-- Ports give NO troops, so these feed only the cost curve and the
		-- trade-ship bonus. Counted separately from cities for exactly that
		-- reason: one of the two is in the maxTroops formula and one is not.
		portCount = 0,
		portLevels = 0,
		portBuilt = 0,
		factoryCount = 0,
		factoryLevels = 0,
		factoryBuilt = 0,
		sumX = 0,
		sumY = 0,
		tileCount = 0,
		border = {},
		borderCount = 0,
		alive = true,
		spawned = false,
		spawnTile = nil,
		thinkOffset = id * 3,

		scanCursor = nil,
		killedBy = nil,
		-- Which upstream AI class this empire is. A human is TIER_HUMAN; a bot
		-- takes what the caller asked for, or Config.DEFAULT_BOT_TIER when the
		-- caller predates the split (ConquestServer, ConquestSimulate).
		tier = if isBot then (tier or Config.DEFAULT_BOT_TIER) else Config.TIER_HUMAN,
	}
	-- Roll this bot's personality. See the BOT VARIANCE block in Config for
	-- why these are per-bot rather than shared: with one set of constants the
	-- entire roster attacks on the same beat.
	if isBot then
		local rng = self.rng
		local function spread(base: number, s: number): number
			return base * (1 - s + rng:NextNumber() * 2 * s)
		end
		-- Upstream rolls the attack rate once per AI and per CLASS: a tribe
		-- nextInt(40, 80) (TribeExecution.ts:23), a Medium nation
		-- nextInt(55, 70) (NationExecution.ts:80). nextInt's upper bound is
		-- EXCLUSIVE (PseudoRandom.ts:45-50), hence THINK_MAX - 1.
		--
		-- TIER_LEGACY keeps the symmetric base+spread form this file shipped
		-- with, and that is NOT cosmetic: NextInteger(-20, 20) has 41 outcomes
		-- and NextInteger(40, 79) has 40, so they are different draws off the
		-- same generator. Swapping one for the other reseeds every bot's think
		-- period and the entire match diverges. Both shapes exist for that
		-- reason alone.
		local tcfg = Config.TIER[p.tier]
		if tcfg.THINK_BASE ~= nil then
			p.aiThink = math.max(4, tcfg.THINK_BASE
				+ rng:NextInteger(-tcfg.THINK_SPREAD, tcfg.THINK_SPREAD))
		else
			p.aiThink = math.max(4, rng:NextInteger(tcfg.THINK_MIN, tcfg.THINK_MAX - 1))
		end
		p.aiIdle = rng:NextNumber() * Config.BOT_IDLE_CHANCE_MAX
		-- Upstream rolls these ONCE per AI in its constructor and never
		-- re-rolls them (TribeExecution.ts:25-27, NationExecution.ts:57-59):
		--   expandRatio  nextInt(10,20)/100 -> 0.10 .. 0.19
		--   reserveRatio nextInt(30,40)/100 -> 0.30 .. 0.39
		--   triggerRatio nextInt(50,60)/100 -> 0.50 .. 0.59
		-- (nextInt's upper bound is EXCLUSIVE -- PseudoRandom.ts:45-50.)
		-- A nation has to behave CONSISTENTLY or the roster reads as one
		-- erratic AI rather than as seventy-two.
		p.aiExpandReserve = math.clamp(spread(Config.BOT_EXPAND_RESERVE_RATIO,
			Config.BOT_EXPAND_RESERVE_SPREAD or Config.BOT_RESERVE_SPREAD), 0.02, 0.9)
		p.aiWarReserve = math.clamp(spread(Config.BOT_WAR_RESERVE_RATIO,
			Config.BOT_WAR_RESERVE_SPREAD or Config.BOT_RESERVE_SPREAD), 0.05, 0.95)
		p.aiTrigger = math.clamp(spread(Config.BOT_TRIGGER_RATIO or 0.55,
			Config.BOT_TRIGGER_SPREAD or 0.1), 0.1, 0.99)
	end

	self.players[id] = p
	table.insert(self.playerOrder, id)
	if userId then
		self.byUserId[userId] = id
	end

	if self.teamCount > 0 then
		-- Least-populated team, ties to the lowest index. The server adds every
		-- human before any bot each round, so this spreads the humans across
		-- the sides first and then lets the bots even the numbers out.
		local best, bestN = 1, math.huge
		for t = 1, self.teamCount do
			local n = self.teamSizes[t] or 0
			if n < bestN then
				bestN = n
				best = t
			end
		end
		self.teamOf[id] = best
		self.teamSizes[best] = bestN + 1
	end

	return p
end

function Sim.playerByUserId(self: Sim, userId: number): Player?
	local id = self.byUserId[userId]
	return id and self.players[id] or nil
end

-- ================================================================== teams ==
-- A mode with TEAMS > 0 partitions every empire into blocs that cannot attack
-- each other. Everything else -- growth, attrition, collapse, the frontier
-- ordering -- is untouched, so the per-empire balance still holds; only
-- spawn placement and the win condition are measured per bloc.

function Sim.sameTeam(self: Sim, a: number, b: number): boolean
	if a == b then
		return true
	end
	if self.teamCount <= 0 then
		return false
	end
	local ta = self.teamOf[a]
	return ta ~= nil and ta == self.teamOf[b]
end

-- One anchor per team, used to group that team's spawns. The anchors have to
-- give every team an EQUAL SHARE of the land, which is a stronger condition
-- than "far apart" and the old greedy farthest-point walk did not meet it.
--
-- Why it matters far more at a 72 roster than it did at 16: a team is now
-- 24-36 empires, so the land grab is not a prelude to the match, it very
-- nearly IS the match -- three dozen empires fanning out from one anchor
-- claim everything within reach before anybody fights, and whatever the
-- anchors carve up is what the teams own. Picking anchor 1 at random and
-- anchor 2 as far from it as possible reliably put both on opposite RIMS of
-- the map, and the side nearer the bulk of the land simply took more of it.
-- Measured at 72 empires: duo/us ended at 4.9 minutes with 53 of 72 empires
-- still alive and the winning bloc already past the 78% bar, with no war
-- having been fought. Two teams being far apart says nothing whatever about
-- their halves being the same size.
--
-- So: sample whole anchor SETS and keep the one whose nearest-anchor
-- partition of the map is most even. That partition is the shape the grab
-- actually takes, which makes the spread of its cell sizes a direct measure
-- of the starting advantage. The distance term is the k-means objective and
-- is only there to break ties, so an even split cannot be bought by stacking
-- the teams on top of each other.
local ANCHOR_TRIALS = 60
local ANCHOR_PROBES = 600

function Sim.assignTeamAnchors(self: Sim)
	table.clear(self.teamAnchors)
	if self.teamCount <= 0 then
		return
	end
	local candidates = self.candidates
	if #candidates == 0 then
		return
	end

	-- One sample of the playable land, reused as the yardstick for every
	-- trial: the trials have to be scored against the same ground, or the
	-- winner is whichever of them drew the kinder sample.
	local px, py = table.create(ANCHOR_PROBES), table.create(ANCHOR_PROBES)
	for i = 1, ANCHOR_PROBES do
		local c = candidates[self.rng:NextInteger(1, #candidates)]
		px[i] = c % W
		py[i] = (c - c % W) / W
	end

	local diag = W * W + H * H
	local set = table.create(self.teamCount)
	local ax = table.create(self.teamCount)
	local ay = table.create(self.teamCount)
	local counts = table.create(self.teamCount)
	local bestSet, bestCost = nil, math.huge

	for _ = 1, ANCHOR_TRIALS do
		for t = 1, self.teamCount do
			local c = candidates[self.rng:NextInteger(1, #candidates)]
			set[t] = c
			ax[t] = c % W
			ay[t] = (c - c % W) / W
			counts[t] = 0
		end

		local sumD = 0
		for i = 1, ANCHOR_PROBES do
			local cx, cy = px[i], py[i]
			local bestT, bestD = 1, math.huge
			for t = 1, self.teamCount do
				local dx, dy = cx - ax[t], cy - ay[t]
				local d = dx * dx + dy * dy
				if d < bestD then
					bestD = d
					bestT = t
				end
			end
			counts[bestT] += 1
			sumD += bestD
		end

		local lo, hi = math.huge, 0
		for t = 1, self.teamCount do
			lo = math.min(lo, counts[t])
			hi = math.max(hi, counts[t])
		end
		local cost = ((hi - lo) / ANCHOR_PROBES) * 4 + sumD / (ANCHOR_PROBES * diag)
		if cost < bestCost then
			bestCost = cost
			bestSet = table.clone(set)
		end
	end

	for t = 1, self.teamCount do
		self.teamAnchors[t] = (bestSet :: { number })[t]
	end
end

-- Per-team totals, for the HUD share bar and the win check. nil in a
-- free-for-all, which is how every caller knows which mode it is in.
function Sim.teamStats(self: Sim): { { tiles: number, troops: number, alive: number } }?
	if self.teamCount <= 0 then
		return nil
	end
	local out = {}
	for t = 1, self.teamCount do
		out[t] = { tiles = 0, troops = 0, alive = 0 }
	end
	for _, id in self.playerOrder do
		local p = self.players[id]
		local t = self.teamOf[id]
		if p and t and out[t] then
			out[t].tiles += p.tileCount
			out[t].troops += math.floor(p.troops)
			if p.alive and p.spawned then
				out[t].alive += 1
			end
		end
	end
	return out
end

-- ============================================================== territory ==

local function refreshBorder(self: Sim, tile: number)
	local map = self.map
	local o = buffer.readu8(map.owner, tile)
	if o == 0 then
		return
	end
	local p = self.players[o]
	if not p then
		return
	end
	if TileMap.isBorder(map, tile) then
		if not p.border[tile] then
			p.border[tile] = true
			p.borderCount += 1
		end
	elseif p.border[tile] then
		p.border[tile] = nil
		p.borderCount -= 1
	end
end

-- The single mutation point for tile ownership. Everything else routes here
-- so the border sets, tile counts and the network delta can never drift.
function Sim.conquer(self: Sim, tile: number, newOwner: number)
	local map = self.map
	local old = buffer.readu8(map.owner, tile)
	if old == newOwner then
		return
	end

	buffer.writeu8(map.owner, tile, newOwner)

	-- Conquering a tile CLEARS its fallout (GameImpl.ts:766). Nothing else
	-- clears the bit -- fallout does not decay. The counter guard keeps this
	-- free for every round in which nobody nukes.
	if newOwner ~= 0 and self.falloutCount > 0 then
		Nukes.setFallout(self, tile, false)
	end

	-- Coordinate sums for the owned-tile centroid. Four arithmetic ops on the
	-- hottest path in the sim, which is why the bot city placer gets to ask
	-- "where is the middle of my country" for free.
	local tx = tile % W
	local ty = (tile - tx) / W

	if old ~= 0 then
		local p = self.players[old]
		if p then
			p.tileCount -= 1
			p.sumX -= tx
			p.sumY -= ty
			if p.border[tile] then
				p.border[tile] = nil
				p.borderCount -= 1
			end
		end
	end
	if newOwner ~= 0 then
		local p = self.players[newOwner]
		if p then
			p.tileCount += 1
			p.sumX += tx
			p.sumY += ty
		end
	end

	-- NOTHING ABOUT UNITS HAPPENS HERE, and that is deliberate. What stood
	-- here asked "is there a structure on this tile" once per conquered tile,
	-- four to sixteen thousand times a tick at full budget. Upstream's
	-- GameImpl.conquer (GameImpl.ts:749-768) touches no units at all: a
	-- building changes hands in Units.stepCapture, once per player per tick,
	-- at a cost bounded by unit count instead of by conquest rate.

	refreshBorder(self, tile)
	local nbuf = self.nbuf
	local n = TileMap.neighbors4(tile, nbuf)
	for k = 1, n do
		refreshBorder(self, nbuf[k])
	end

	local c = self.changeCount
	self.changes[c * 2 + 1] = tile
	self.changes[c * 2 + 2] = newOwner
	self.changeCount = c + 1
end

-- ============================================================== structures ==
-- Cities, ports, the rails between them and the ships and trains that use
-- them all live in `Conquest.Economy`. What stays here is the surface the
-- server and the AI call, so neither has to know which module owns what --
-- and, more to the point, so the attack loop below is not sharing a file with
-- a pathfinder.

Sim.CITY = Economy.CITY
Sim.PORT = Economy.PORT
Sim.FACTORY = Economy.FACTORY

-- What the next structure of this kind costs this empire.
function Sim.structureCost(p: Player, kind: number): number
	return Economy.cost(p, kind)
end

-- Returns ok, a reason code the HUD turns into a sentence, and the tile the
-- build actually landed on (a port snaps to the nearest coast it owns).
function Sim.buildStructure(self: Sim, playerId: number, tile: number, kind: number): (boolean, string?, number?)
	return Economy.build(self, playerId, tile, kind)
end

function Sim.snapshotStructures(self: Sim): { any }
	return Economy.snapshotStructures(self)
end

function Sim.snapshotRails(self: Sim): { any }
	return Economy.snapshotRails(self)
end

function Sim.drainStructEvents(self: Sim): { any }?
	return Economy.drainStructEvents(self)
end

function Sim.drainRailEvents(self: Sim): { any }?
	return Economy.drainRailEvents(self)
end

-- Transport ships ride the SAME wire stream as trade ships and trains: one
-- format, one client renderer, one interpolation clock, and one 2 Hz budget.
-- Adding a parallel "boats" channel would have duplicated all four.
--
-- THE ID OFFSET IS GONE. It existed because boats were numbered from
-- Sim.nextBoatId and trade ships and trains from sim.nextVehicleId, two
-- counters that collide -- and the client keys its markers by id, so a shared
-- id read as a boat teleporting between a train and itself. All three are
-- units now and draw from the one id space, so there is nothing to offset.
Sim.VEHICLE_TRANSPORT = 3

function Sim.vehicles(self: Sim): { any }
	local out = Economy.vehicles(self)
	-- Warships (kind 4) ride the one unit id space like everything else here;
	-- shells (kind 5) are not units and carry their own offset.
	Warships.vehicles(self, out)
	for _, b in self.boats do
		if b.active then
			table.insert(out, {
				id = b.id,
				kind = 3,
				owner = b.ownerId,
				x = b.tile % W,
				y = (b.tile - b.tile % W) / W,
			})
		end
	end
	return out
end

-- =================================================================== spawn ==

function Sim.isValidSpawn(self: Sim, tile: number): boolean
	if tile < 0 or tile >= N then
		return false
	end
	if not TileMap.isPassable(self.map, tile) then
		return false
	end
	if buffer.readu8(self.map.owner, tile) ~= 0 then
		return false
	end
	local tx, ty = tile % W, (tile - tile % W) / W
	local minD = Config.MIN_SPAWN_DISTANCE
	for _, id in self.playerOrder do
		local other = self.players[id]
		if other and other.spawnTile then
			local ot = other.spawnTile
			local ox, oy = ot % W, (ot - ot % W) / W
			-- Upstream uses manhattanDist (SpawnExecution.ts:163), not
			-- Euclidean. The metric has to change with the number.
			if math.abs(tx - ox) + math.abs(ty - oy) < minD then
				return false
			end
		end
	end
	return true
end

function Sim.spawnPlayer(self: Sim, p: Player, tile: number): boolean
	if p.spawned or not Sim.isValidSpawn(self, tile) then
		return false
	end

	p.spawnTile = tile
	p.spawned = true
	-- startManpower (Config.ts:893-912): Bot 10,000, Nation/Medium 18,750,
	-- human 25,000.
	--
	-- A PRIVATE LOBBY'S HOST CAN SCALE ALL OF THEM TOGETHER, and it is a
	-- multiplier rather than a flat figure precisely so the tier ladder
	-- survives the dial: a host reaching for "double troops" must not also,
	-- invisibly, hand the bots a 39% buff by flattening 18,000 up to 25,000.
	-- Absent it is 1 and a Sim built the old way is bit-for-bit what it was,
	-- exactly as `incomePace` is.
	p.troops = Config.TIER[p.tier].SPAWN_TROOPS * (self.troopScale or 1)
	-- Nothing else in the sim grants opening gold -- every empire starts on
	-- zero -- so this is zero unless a host asked otherwise. Flat, not scaled:
	-- there is no gold ladder to preserve.
	p.gold = self.startGold or 0

	local r = Config.SPAWN_RADIUS
	local cx, cy = tile % W, (tile - tile % W) / W
	for dy = -r, r do
		for dx = -r, r do
			if dx * dx + dy * dy <= r * r then
				local x, y = cx + dx, cy + dy
				if TileMap.inBounds(x, y) then
					local i = y * W + x
					if TileMap.isPassable(self.map, i) and buffer.readu8(self.map.owner, i) == 0 then
						Sim.conquer(self, i, p.id)
					end
				end
			end
		end
	end
	return true
end

function Sim.autoSpawn(self: Sim, p: Player)
	local candidates = self.candidates
	if #candidates == 0 then
		return
	end

	-- In a team mode, drop members near their team's anchor. Scattering allies
	-- uniformly gives every player a ring of enemies and the round then plays
	-- exactly like a free-for-all with the attack button disabled against a
	-- third of the map -- grouping is what produces a shared front, which is
	-- the only reason to have teams at all.
	local anchor = self.teamCount > 0 and self.teamAnchors[self.teamOf[p.id] or 1] or nil
	if anchor then
		local ax, ay = anchor % W, (anchor - anchor % W) / W
		local best, bestScore = nil, math.huge
		for _ = 1, 500 do
			local tile = candidates[self.rng:NextInteger(1, #candidates)]
			local tx, ty = tile % W, (tile - tile % W) / W
			local dx, dy = tx - ax, ty - ay
			-- Jittered, so members ring the anchor instead of every one of
			-- them stacking on the single closest legal tile.
			local score = (dx * dx + dy * dy) * (0.7 + self.rng:NextNumber() * 0.6)
			-- Score BEFORE validating, and validate only a candidate that is
			-- already winning. isValidSpawn walks every empire placed so far,
			-- so at a 72 roster it IS the cost of this loop: 500 samples x up
			-- to 72 distance checks, for each of 72 empires, all inside the
			-- single tick the spawn phase ends on. Measured at 92-97 ms of a
			-- 100 ms tick on every team round.
			--
			-- The result is unchanged -- this still returns the lowest-scoring
			-- legal candidate -- because a candidate that loses on score could
			-- never have been chosen whether it was legal or not. Only about
			-- H(500) ~= 7 of the 500 samples are ever a running minimum, so
			-- the validation count falls ~70x.
			if score < bestScore and Sim.isValidSpawn(self, tile) then
				bestScore = score
				best = tile
			end
		end
		if best and Sim.spawnPlayer(self, p, best) then
			return
		end
	end

	for _ = 1, 400 do
		local tile = candidates[self.rng:NextInteger(1, #candidates)]
		if Sim.spawnPlayer(self, p, tile) then
			return
		end
	end
	-- Map is crowded; drop the spacing rule rather than leave them unspawned.
	for _ = 1, 400 do
		local tile = candidates[self.rng:NextInteger(1, #candidates)]
		if TileMap.isPassable(self.map, tile) and buffer.readu8(self.map.owner, tile) == 0 then
			p.spawnTile = tile
			p.spawned = true
			-- The crowded-map fallback places by hand instead of going
			-- through spawnPlayer, so it has to pay out the same opening.
			p.troops = Config.TIER[p.tier].SPAWN_TROOPS * (self.troopScale or 1)
			p.gold = self.startGold or 0
			Sim.conquer(self, tile, p.id)
			return
		end
	end
end

-- ================================================================ attacks ==

-- Reference maxTroops(): 2 * (tiles^0.6 * 1000 + 50000), HALVED for an AI
-- empire. The halving is not a difficulty knob -- it is what decides whether
-- a nation is something you fight or something you eat, and therefore what
-- makes another person the most dangerous thing on your border.
local function maxTroops(p: Player): number
	local m = Config.MAX_TROOPS_MULT
		* ((p.tileCount ^ Config.TROOPS_TILE_EXPONENT) * Config.TROOPS_PER_TILE_COEF
			+ Config.BASE_MAX_TROOPS)
	-- Cities, from the same reference function: `+ sum(cityLevel) * 250000`.
	--
	-- CORRECTED. The comment that stood here said the city term sits OUTSIDE
	-- the AI scale, "which is what the reference does". It is not, and it does
	-- not. Upstream Config.ts:914-928 forms the whole sum first --
	--     maxTroops = 2*(tiles^0.6*1000 + 50000) + sum(cityLevel)*250000
	-- -- and THEN returns maxTroops/3 for a Bot (:926-927) or maxTroops*0.75
	-- for a Medium Nation (:937-938). The class scale covers the city term.
	--
	-- This was invisible while the AI scale was 1.0 and is a live divergence
	-- the moment tiers land: it is the difference between a captured city
	-- being worth 250,000 of ceiling to a tribe and being worth 83,333.
	-- Upstream stops a tribe banking a ceiling it should not have twice over
	-- -- by scaling the term AND by having the tribe raze what it captures
	-- (TribeExecution.ts:86-94) -- and this game has neither yet.
	m += p.cityLevels * (Config.CITY_TROOP_INCREASE or 0)
	return m * Config.TIER[p.tier or Config.TIER_HUMAN].MAX_TROOPS_SCALE
end

Sim.maxTroops = maxTroops
-- nukeDeathFactor for a MIRV warhead is a curve against the troop CEILING
-- (Config.ts:1071-1078), so the nuclear layer needs this function and cannot
-- require Sim back.
Nukes.maxTroopsFn = maxTroops

-- NOTE: deliberately allows the same tile in the heap more than once.
-- Priority depends on how many of the tile's neighbours the attacker owns,
-- and that improves as the advance wraps around it -- but a heap has no
-- decrease-key, so de-duplicating pinned every tile to the priority it had
-- when first seen (usually 1 neighbour). Nothing could ever overtake anything
-- and holes were never preferentially filled, which is what made frontiers
-- come out as speckle. Re-pushing with the better priority is the standard
-- lazy-decrease-key; stale copies cost one pop and fail the ownership check
-- below.
-- The disc the wrap count is measured over: every offset with
-- dx^2 + dy^2 <= 5, twenty tiles. Counting only the four cardinal
-- neighbours makes the METRIC axis-aligned -- its unit ball is a diamond --
-- and the limit shape of a flow that minimises it is a rectangle however
-- much noise is piled on top. Isotropic noise cannot beat an anisotropic
-- metric. The disc also makes one tile a twentieth of the term's range
-- instead of a quarter, so the random factor can actually reorder a front
-- rather than being swamped by a single neighbour flipping.
local WRAP_OFFSETS = {
	-2, -1, -2, 0, -2, 1,
	-1, -2, -1, -1, -1, 0, -1, 1, -1, 2,
	0, -2, 0, -1, 0, 1, 0, 2,
	1, -2, 1, -1, 1, 0, 1, 1, 1, 2,
	2, -1, 2, 0, 2, 1,
}
local WRAP_TILES = 20

local DELAY_MIN = Config.FRONTIER_DELAY_MIN or 3
local DELAY_SPREAD = Config.FRONTIER_DELAY_SPREAD or 20
local WRAP_RELIEF = Config.FRONTIER_WRAP_RELIEF or 0.85
local TERRAIN_PENALTY = Config.FRONTIER_TERRAIN_PENALTY or 0.5
local ROUGH_STRETCH = Config.FRONTIER_ROUGH_STRETCH or 0.34
local BASE_MIN = Config.FRONTIER_BASE_MIN or 0.12
local PACE = Config.FRONTIER_PACE or 0.56

-- The reference frontier rule, from AttackExecution.addNeighbors. See
-- Config.FRONTIER_MODE for what the two modes are and why both exist.
local FRONTIER_MODE = Config.FRONTIER_MODE or "wave"
local REF_MAG = Config.FRONTIER_REF_MAG or { 1, 1.5, 2 }
local REF_SPAN_MIN = Config.FRONTIER_REF_SPAN_MIN or 10
local REF_SPAN_SPREAD = Config.FRONTIER_REF_SPAN_SPREAD or 7
local REF_RELIEF = Config.FRONTIER_REF_WRAP_RELIEF or 0.5

-- White noise keyed to the TILE rather than to the visit. It scrambles the
-- order tiles become ready in exactly as a per-push roll would, but a
-- re-push can then only improve a tile by WRAPPING it, never by rolling
-- again -- which is what keeps the decrease-key bound in enqueue exact.
-- High bits of one LCG step; tile stays under 2^21 so the product is exact.
local function tileRoll(tile: number): number
	local h = (tile * 1103515245 + 12345) % 2147483648
	return (h // 32768) / 65536
end

local function enqueue(self: Sim, atk: Attack, tile: number)
	local map = self.map
	if buffer.readu8(map.owner, tile) ~= atk.targetId then
		return
	end
	if not TileMap.isPassable(map, tile) then
		return
	end

	if FRONTIER_MODE == "reference" then
		-- priority = (rand(0,7) + 10) * (1 - ownedCardinal * 0.5 + mag / 2) + tick
		--
		-- Three things here are load-bearing and none of them is the
		-- randomness. The wrap is counted over the FOUR CARDINAL neighbours,
		-- so one neighbour is a quarter of the term's whole range. The time
		-- base is the WORLD tick, shared by every attack on the map. And
		-- there is no readiness gate at all -- processAttack pops until its
		-- budget is gone (see the gate there, which this mode skips).
		--
		-- ONE deliberate difference: the roll is keyed to the TILE instead of
		-- being drawn per push. It scrambles the order identically, but it
		-- means a re-push can only ever improve a tile by WRAPPING it, which
		-- is what keeps the lazy decrease-key bound below exact. The
		-- reference re-pushes unconditionally and carries the dead copies;
		-- at 1.6M tiles and 72 empires that was ~3 corpses per conquered tile
		-- and ticks in the 60 ms range.
		local rType = TileMap.terrainType(map, tile)
		local rMag = REF_MAG[rType] or REF_MAG[1]
		local rSpan = REF_SPAN_MIN + tileRoll(tile) * REF_SPAN_SPREAD
		local rBest = atk.prio[tile]
		local rTick = self.tick
		if rBest ~= nil and rTick + rSpan * (1 - 4 * REF_RELIEF + rMag / 2) >= rBest then
			return
		end

		local rx = tile % W
		local ry = (tile - rx) / W
		local rOwner = map.owner
		local me = atk.attackerId
		local owned = 0
		if rx > 0 and buffer.readu8(rOwner, tile - 1) == me then
			owned += 1
		end
		if rx < W - 1 and buffer.readu8(rOwner, tile + 1) == me then
			owned += 1
		end
		if ry > 0 and buffer.readu8(rOwner, tile - W) == me then
			owned += 1
		end
		if ry < H - 1 and buffer.readu8(rOwner, tile + W) == me then
			owned += 1
		end

		local rPriority = rSpan * (1 - owned * REF_RELIEF + rMag / 2) + rTick

		if not atk.borderSet[tile] then
			atk.borderSet[tile] = true
			atk.borderCount += 1
			atk.sumX += rx
			atk.sumY += ry
		end
		if rBest == nil or rPriority < rBest then
			atk.prio[tile] = rPriority
			Heap.push(atk.frontier, tile, rPriority)
		end
		return
	end

	-- Everything that depends only on the TILE and not on how much of it we
	-- have surrounded. All cheap, and doing them first is what lets the bound
	-- below reject a re-push without touching twenty neighbours.
	local tType = TileMap.terrainType(map, tile)
	-- Normalised against plains: 1.00 / 1.25 / 1.50.
	local cost = (Config.TERRAIN_MAG[tType] or Config.TERRAIN_MAG[1]) / Config.TERRAIN_MAG[1]
	local terrain = (cost - 1) * TERRAIN_PENALTY
	local rough = (buffer.readu8(self.rough, tile) / 255 - 0.5) * ROUGH_STRETCH
	local span = DELAY_MIN + tileRoll(tile) * DELAY_SPREAD

	-- Prove the push cannot improve BEFORE the disc scan: the best this tile
	-- could ever manage is fully wrapped, and if even that loses to the entry
	-- it already holds there is nothing to do. Re-enqueueing known frontier
	-- is the common case, four times per conquest.
	--
	-- Without a bound every conquest leaves roughly three dead copies behind
	-- for the life of the attack, a push over 50k tiles drags a 150k-entry
	-- heap, and since a stale pop consumes no budget a tick can spend itself
	-- popping nothing but corpses -- that is where 58-73 ms ticks came from.
	local best = atk.prio[tile]
	if best ~= nil then
		local floorBase = 1 - WRAP_RELIEF + terrain + rough
		if floorBase < BASE_MIN then
			floorBase = BASE_MIN
		end
		if atk.clock + span * floorBase >= best then
			return
		end
	end

	-- How much of this tile's surroundings we already hold.
	local tx = tile % W
	local ty = (tile - tx) / W
	local owner = map.owner
	local owned = 0
	for k = 1, #WRAP_OFFSETS, 2 do
		local x = tx + WRAP_OFFSETS[k]
		local y = ty + WRAP_OFFSETS[k + 1]
		if x >= 0 and x < W and y >= 0 and y < H then
			if buffer.readu8(owner, y * W + x) == atk.attackerId then
				owned += 1
			end
		end
	end

	local base = 1 - (owned / WRAP_TILES) * WRAP_RELIEF + terrain + rough
	if base < BASE_MIN then
		base = BASE_MIN
	end
	-- A ready TIME on this attack's own clock, not a score.
	local priority = atk.clock + span * base

	if not atk.borderSet[tile] then
		atk.borderSet[tile] = true
		atk.borderCount += 1
		atk.sumX += tx
		atk.sumY += ty
	end

	-- Lazy decrease-key: re-push only at a BETTER time. This is not the
	-- de-duplication that once broke this -- a tile may still be re-pushed
	-- when wrapping improves it, it just is not pushed again at a worse one.
	if best == nil or priority < best then
		atk.prio[tile] = priority
		Heap.push(atk.frontier, tile, priority)
	end
end

local function seedFrontier(self: Sim, atk: Attack)
	local attacker = self.players[atk.attackerId]
	if not attacker then
		return
	end
	local map = self.map
	local nbuf = self.nbuf

	-- Walk whichever of the two borders is SHORTER. Contact is symmetric, so
	-- seeding from the defender's side finds exactly the same tiles -- and
	-- when a large empire opens on a small neighbour, which is most of the
	-- endgame, that is the difference between thirty thousand iterations and
	-- eight hundred. enqueue() uses nbuf2, so iterating nbuf here is safe.
	-- A landing has a beachhead, not a border. Seeding from the attacker's
	-- whole territory would open the front back home instead of on the beach.
	if atk.sourceTile ~= nil then
		local n = TileMap.neighbors4(atk.sourceTile, nbuf)
		for k = 1, n do
			enqueue(self, atk, nbuf[k])
		end
		return
	end

	local defender = atk.targetId ~= 0 and self.players[atk.targetId] or nil
	if defender and defender.borderCount < attacker.borderCount then
		for tile in defender.border do
			local n = TileMap.neighbors4(tile, nbuf)
			for k = 1, n do
				if buffer.readu8(map.owner, nbuf[k]) == atk.attackerId then
					enqueue(self, atk, tile)
					break
				end
			end
		end
		return
	end

	for tile in attacker.border do
		local n = TileMap.neighbors4(tile, nbuf)
		for k = 1, n do
			local nb = nbuf[k]
			if buffer.readu8(map.owner, nb) == atk.targetId then
				enqueue(self, atk, nb)
			end
		end
	end
end

local function endAttack(self: Sim, atk: Attack, refund: boolean, penalty: number)
	if not atk.active then
		return
	end
	atk.active = false
	if refund and atk.troops > 0 then
		local attacker = self.players[atk.attackerId]
		if attacker and attacker.alive then
			attacker.troops += atk.troops * (1 - penalty)
		end
	end
	atk.troops = 0
	Heap.clear(atk.frontier)
	table.clear(atk.borderSet)
	table.clear(atk.prio)
	atk.borderCount = 0
	atk.clock = 0
	atk.sumX = 0
	atk.sumY = 0
end

-- Returns ok, and a REASON CODE when it refuses. The reason exists so that a
-- tap on enemy land that cannot become an attack can say why: refusing
-- silently is indistinguishable from the tap never having registered, which
-- is the most confusing thing this game can do to someone holding a phone.
function Sim.launchAttack(
	self: Sim,
	playerId: number,
	targetTile: number,
	ratio: number,
	absTroops: number?
): (boolean, string?)
	local attacker = self.players[playerId]
	if not attacker or not attacker.alive or not attacker.spawned then
		return false, "notready"
	end
	if self.phase ~= "playing" then
		return false, "notplaying"
	end
	if targetTile < 0 or targetTile >= N then
		return false, "offmap"
	end

	local map = self.map
	if not TileMap.isPassable(map, targetTile) then
		return false, "water"
	end

	local targetId = buffer.readu8(map.owner, targetTile)
	if targetId == playerId then
		return false, "own"
	end
	-- No friendly fire. Rejected here rather than filtered on the client, so a
	-- crafted intent cannot open a front on an ally either.
	if targetId ~= 0 and Sim.sameTeam(self, playerId, targetId) then
		return false, "ally"
	end

	-- Reference: nobody may be attacked until the spawn phase plus the
	-- immunity window has elapsed. phaseTick restarts at 0 when the round
	-- begins, so this is measured from the end of spawn selection. Unclaimed
	-- land is never immune.
	if targetId ~= 0
		and self.phaseTick < (Config.SPAWN_IMMUNITY_SECONDS or 0) * Config.TICK_RATE
	then
		return false, "immunity"
	end

	-- The AI commits an ABSOLUTE number -- everything above its reserve --
	-- rather than a fraction of what it is holding (upstream
	-- src/core/execution/utils/AiAttackBehavior.ts:951-1019,
	-- `calculateAttackTroops` / `sendLandAttack`:
	-- troops = player.troops() - maxTroops * reserveRatio).
	-- A fraction of a small army is a small army,
	-- which is why AI pushes used to arrive already spent.
	local committed: number
	if absTroops then
		committed = math.floor(math.min(absTroops, attacker.troops))
		if committed < 1 then
			return false, "troops"
		end
	else
		ratio = math.clamp(ratio, Config.MIN_ATTACK_RATIO, Config.MAX_ATTACK_RATIO)
		committed = math.floor(attacker.troops * ratio)
		if committed < Config.MIN_ATTACK_TROOPS then
			return false, "troops"
		end
	end

	-- TWO ARMIES POINTED AT EACH OTHER ANNIHILATE, one for one, before either
	-- takes a single tile (reference AttackExecution.init). This is the piece
	-- that makes a player-versus-player front read as a war rather than as
	-- two independent land grabs: counter-attacking into an incoming push is
	-- a real defensive move, and what both sides spend on it is simply gone.
	-- `paid` is what leaves the attacker's pool either way -- the men are
	-- committed whether they end up taking ground or cancelling somebody out.
	local paid = committed
	if targetId ~= 0 and Config.OPPOSING_ATTACKS_CANCEL then
		for _, other in self.attacks do
			if other.active and other.attackerId == targetId and other.targetId == playerId then
				local absorbed = math.min(other.troops, committed)
				other.troops -= absorbed
				committed -= absorbed
				if other.troops < 1 then
					endAttack(self, other, false, 0)
				end
				if committed < 1 then
					break
				end
			end
		end
		if committed < 1 then
			attacker.troops -= paid
			return true
		end
	end

	-- Reinforce an existing push on the same target rather than opening a
	-- second front that would fight for the same frontier tiles.
	for _, atk in self.attacks do
		if atk.active and atk.attackerId == playerId and atk.targetId == targetId then
			attacker.troops -= paid
			atk.troops += committed
			-- NOT on every reinforcement: see Config.RESEED_TICKS. The front
			-- maintains itself as it advances, so this only has to catch a
			-- drained heap or contact somebody else's conquest opened up.
			if Heap.size(atk.frontier) == 0 or self.tick - atk.seedTick >= Config.RESEED_TICKS then
				atk.seedTick = self.tick
				seedFrontier(self, atk)
			end
			return true
		end
	end

	-- A new front seeds from scratch, which is the one attack path the
	-- reinforcement throttle cannot cover. Cap how many an empire may hold
	-- open at once so alternating targets at the intent rate limit cannot
	-- force a fresh border scan several times a second.
	local open = 0
	for _, a in self.attacks do
		if a.active and a.attackerId == playerId then
			open += 1
		end
	end
	if open >= Config.MAX_FRONTS_PER_PLAYER then
		return false, "toomanyfronts"
	end

	attacker.troops -= paid

	local atk: Attack = {
		attackerId = playerId,
		targetId = targetId,
		troops = committed,
		frontier = Heap.new(),
		borderSet = {},
		borderCount = 0,
		clock = 0,
		prio = {},
		seedTick = self.tick,
		sumX = 0,
		sumY = 0,
		id = self.nextAttackId,
		active = true,
	}
	self.nextAttackId += 1
	seedFrontier(self, atk)

	if Heap.size(atk.frontier) == 0 then
		-- Not adjacent to anything of the target's: no attack is possible.
		attacker.troops += committed
		return false, "notadjacent"
	end

	table.insert(self.attacks, atk)
	return true
end

-- Cancel every attack this player owns, refunding the survivors.
function Sim.cancelAttacks(self: Sim, playerId: number)
	for _, atk in self.attacks do
		if atk.active and atk.attackerId == playerId then
			-- The malus is charged only when the target is a PLAYER.
			-- Upstream AttackExecution.ts:244-249 calls retreat(25) against a
			-- player and retreat() -- zero -- against terra nullius, and
			-- Config.RETREAT_PENALTY's own comment already said so. The code
			-- was charging a quarter of the army for calling off a land grab.
			endAttack(self, atk, true, atk.targetId ~= 0 and Config.RETREAT_PENALTY or 0)
		end
	end
end
-- ================================================================== navy ==

-- A landing. Upstream (`TransportShipExecution`, PathStatus.COMPLETE) does
-- three things in this order and all three matter: conquer the beachhead
-- outright, spawn an attack rooted at it, delete the boat.
--
-- THE FREE BEACHHEAD IS NOT A GIFT, IT IS LOAD-BEARING. An attack only ever
-- takes a tile that already touches the attacker, so a landing with no tile
-- ashore pops its whole frontier, fails the adjacency test on every one, and
-- dies without firing a shot. Conquering `dst` is what gives it something to
-- be adjacent to.
local function landBoat(self: Sim, boat: Boat)
	local attacker = self.players[boat.ownerId]
	if not attacker or not attacker.alive or boat.troops < 1 then
		return
	end
	local map = self.map
	local dst = boat.ext.dst
	local targetId = buffer.readu8(map.owner, dst)

	-- The coast changed hands during the crossing and it is ours or an
	-- ally's now. The men come home, less the retreat malus -- upstream pays
	-- the same 25% for a boat that arrives somewhere friendly.
	if targetId == boat.ownerId or (targetId ~= 0 and Sim.sameTeam(self, boat.ownerId, targetId)) then
		attacker.troops += boat.troops * (1 - Config.RETREAT_PENALTY)
		return
	end
	if not TileMap.isPassable(map, dst) then
		attacker.troops += boat.troops * (1 - Config.RETREAT_PENALTY)
		return
	end

	Sim.conquer(self, dst, boat.ownerId)

	local atk: Attack = {
		attackerId = boat.ownerId,
		targetId = targetId,
		troops = boat.troops,
		sourceTile = dst,
		frontier = Heap.new(),
		borderSet = {},
		borderCount = 0,
		clock = 0,
		prio = {},
		seedTick = self.tick,
		sumX = 0,
		sumY = 0,
		id = self.nextAttackId,
		active = true,
	}
	self.nextAttackId += 1
	seedFrontier(self, atk)
	if Heap.size(atk.frontier) == 0 then
		-- Landed on an isolated tile with nothing of the target's beside it.
		-- The beachhead is still ours; the army just has nowhere to go.
		attacker.troops += atk.troops
		return
	end
	table.insert(self.attacks, atk)
end

-- Send a transport ship at `targetTile`. Returns ok plus a REASON, same
-- contract as launchAttack, because every one of these refusals is otherwise
-- indistinguishable from the tap not registering.
function Sim.launchBoat(self: Sim, playerId: number, targetTile: number): (boolean, string?)
	local p = self.players[playerId]
	if not p or not p.alive or not p.spawned then
		return false, "notready"
	end
	if self.phase ~= "playing" then
		return false, "notplaying"
	end
	if targetTile < 0 or targetTile >= N then
		return false, "offmap"
	end

	local map = self.map
	local nbuf = self.nbuf
	local owner = map.owner

	local aimedAt = buffer.readu8(owner, targetTile)
	if aimedAt == playerId then
		return false, "own"
	end
	if aimedAt ~= 0 and Sim.sameTeam(self, playerId, aimedAt) then
		return false, "ally"
	end
	if aimedAt ~= 0
		and self.phaseTick < (Config.SPAWN_IMMUNITY_SECONDS or 0) * Config.TICK_RATE
	then
		return false, "immunity"
	end

	if (self.boatBudget or 0) <= 0 then
		return false, "busy"
	end
	local afloat = 0
	for _, b in self.boats do
		if b.active and b.ownerId == playerId then
			afloat += 1
		end
	end
	if afloat >= Config.BOAT_MAX_PER_PLAYER then
		return false, "toomanyboats"
	end

	local dst = Navy.landingTile(map, targetTile, nbuf)
	if dst == nil then
		return false, "nobeach"
	end
	-- Pick the WATER first. Since rivers, an empire can hold coast on several
	-- bodies of water at once, and the nearest stretch of its own shoreline to
	-- the target is regularly a river bank with no way out to the target's
	-- sea. Constraining the embark point to water the landing site actually
	-- touches is what keeps a sea invasion launchable from a country that has
	-- a river running through it.
	local dstComps = Navy.compsNear(self.nav, dst, {})
	local src = Navy.spawnTile(map, p.border, dst, nbuf, nil, self.nav, dstComps)
	if src == nil then
		return false, "nocoast"
	end
	if not Navy.reachable(self.nav, map, src, dst) then
		return false, "nosearoute"
	end

	local troops = math.floor(p.troops / Config.BOAT_TROOP_DIVISOR)
	if troops < Config.BOAT_MIN_TROOPS then
		return false, "troops"
	end

	local path = Navy.path(self.nav, map, src, dst)
	if path == nil or #path == 0 then
		return false, "nosearoute"
	end

	self.boatBudget = (self.boatBudget or 1) - 1
	p.troops -= troops
	table.insert(self.boats, Units.spawn(self, Units.TRANSPORT_SHIP, playerId, src, {
		troops = troops,
		ext = {
			targetId = aimedAt,
			dst = dst,
			path = path,
			pathIdx = 1,
			-- The fine water route to the CURRENT waypoint, bought a leg at a
			-- time in stepBoats and thrown away at each one. Nil is a legal
			-- state and means "steer straight at it this tick".
			leg = nil :: { number }?,
			legIdx = 1,
			legTo = nil :: number?,
		},
	}))
	return true
end
-- Move every boat. Between two coarse waypoints it follows a CHANNEL -- the
-- tile-level water route Navy.channel finds inside a window around the leg --
-- and falls back to steering straight at the waypoint when there is no
-- channel to be had: no window solution, or the tick's allowance of searches
-- already spent. The fallback still PREFERS water without requiring it,
-- because the coarse grid calls a cell navigable if any tile in it is water,
-- so a route legitimately clips headlands, and refusing to move on land there
-- would strand boats on coastlines forever.
-- What a land step costs a boat's fine route, in water steps. Same figure
-- Economy portages a trade lane with, and for the same reason.
local PORTAGE_COST = 25
-- Cells one leg may expand. A leg is a single coarse cell long, so a window
-- of 30-odd tiles a side is the whole search space and this is generous for
-- it; it exists to bound the case where there is NO route and the search
-- fills the window before giving up. Tighter than the module default because
-- this one runs inside the tick, several times over, every tick.
local BOAT_CHANNEL_CAP = 600

local function stepBoats(self: Sim)
	local speed = Config.BOAT_SPEED
	local map = self.map
	local live = {}
	for _, b in self.boats do
		if not b.active then
			continue
		end
		local e = b.ext
		local p = self.players[b.ownerId]
		if not p or not p.alive then
			Units.delete(self, b)
			continue
		end

		-- Walked in a LOCAL and written back once. Nothing reads the boat's
		-- tile between steps, and every write to it now costs a grid cell
		-- test (Units.move), so paying that BOAT_SPEED times a tick instead
		-- of once would be buying nothing.
		local tile = b.tile
		for _ = 1, speed do
			local wp = e.path[e.pathIdx]
			if wp == nil then
				break
			end
			if tile == wp then
				e.pathIdx += 1
				e.leg = nil
				continue
			end

			-- FOLLOW THE CHANNEL. One fine water route per waypoint, bought
			-- off the tick's allowance and then walked a tile at a time for
			-- nothing. This is what puts a transport IN a river rather than
			-- across the fields beside it: the coarse route only ever
			-- promised that water is somewhere near the line it drew.
			local leg = e.leg
			if e.legTo ~= wp then
				leg = nil
				if (self.channelBudget or 0) > 0 then
					-- ONE search per waypoint, and a failure is remembered as
					-- `legTo` set with no leg: a leg the window cannot solve
					-- must not re-buy the same dead search three times a tick
					-- for as long as the boat is aiming at it. A search the
					-- BUDGET refused leaves legTo alone, so it is retried next
					-- tick, which is the difference between the two.
					self.channelBudget -= 1
					-- Water first; failing that, the shortest crossing that
					-- steps over land. A leg with no water route is normally
					-- a land bridge -- Dover, Gibraltar, the Danish belts,
					-- all of them in the generated masks -- and a transport
					-- has to be able to make that crossing. What the portage
					-- buys is that it steps over the isthmus at its neck
					-- rather than cutting a diagonal across the county.
					e.leg = Navy.channel(map, tile, wp, BOAT_CHANNEL_CAP)
						or Navy.channel(map, tile, wp, BOAT_CHANNEL_CAP, nil, PORTAGE_COST)
					e.legIdx = 1
					e.legTo = wp
					leg = e.leg
				end
			end
			if leg ~= nil then
				local nxt = leg[e.legIdx]
				if nxt ~= nil then
					e.legIdx += 1
					tile = nxt
					if tile == wp then
						e.pathIdx += 1
						e.leg = nil
					end
					continue
				end
			end
			-- No channel for this leg. Steer straight at the waypoint, and hug.

			local x, y = tile % W, (tile - tile % W) / W
			local wx, wy = wp % W, (wp - wp % W) / W
			-- Chebyshev step: one tile toward the waypoint, diagonals allowed.
			local sx = (wx > x and 1 or (wx < x and -1 or 0))
			local sy = (wy > y and 1 or (wy < y and -1 or 0))
			local nx, ny = x + sx, y + sy
			-- HUG THE WATER. The coarse route only ever promised that water is
			-- NEAR the straight line between two waypoints, and since rivers
			-- turned half of every cell grid navigable, the line itself lands
			-- on land far more often -- 27-39% of a boat's steps, measured,
			-- against 13-18% before. Trying the two headings 45 degrees either
			-- side and taking one that floats puts that back to 9-13%, for
			-- three tile reads. Costs nothing and needs no larger search.
			--
			-- The guard is that the alternative must strictly REDUCE Chebyshev
			-- distance to the waypoint. Without it a boat one tile from a
			-- waypoint on a spit sidesteps, comes back, and never arrives --
			-- and nothing downstream would ever time it out.
			if TileMap.isLand(map, ny * W + nx) then
				local cur = math.max(math.abs(wx - x), math.abs(wy - y))
				local ax, ay, bx, by
				if sx == 0 or sy == 0 then
					ax, ay, bx, by = sx + sy, sy + sx, sx - sy, sy - sx
				else
					ax, ay, bx, by = sx, 0, 0, sy
				end
				for _ = 1, 2 do
					local cx, cy = x + ax, y + ay
					if cx >= 0 and cx < W and cy >= 0 and cy < H
						and math.max(math.abs(wx - cx), math.abs(wy - cy)) < cur
						and not TileMap.isLand(map, cy * W + cx)
					then
						nx, ny = cx, cy
						break
					end
					ax, ay, bx, by = bx, by, ax, ay
				end
			end
			if nx < 0 or nx >= W or ny < 0 or ny >= H then
				break
			end
			tile = ny * W + nx
			if math.abs(nx - wx) <= 0 and math.abs(ny - wy) <= 0 then
				e.pathIdx += 1
			end
		end
		Units.move(self, b, tile)

		-- Close enough to the beach: land. The last waypoint is a WATER tile
		-- beside `dst`, never `dst` itself, so arrival is a proximity test
		-- rather than an equality one.
		local x, y = tile % W, (tile - tile % W) / W
		local dx0, dy0 = e.dst % W, (e.dst - e.dst % W) / W
		local far = math.max(math.abs(x - dx0), math.abs(y - dy0))
		if far <= speed or e.pathIdx > #e.path then
			if far <= (Config.BOAT_LAND_RADIUS or 12) then
				landBoat(self, b)
			else
				-- Ran out of route short of the target (the coast moved, or
				-- the coarse path ended in a pocket). Bring them home rather
				-- than deleting an army.
				p.troops += b.troops * (1 - Config.RETREAT_PENALTY)
			end
			Units.delete(self, b)
			continue
		end
		table.insert(live, b)
	end
	self.boats = live
end

-- Every boat at sea, for the client to draw. Same shape discipline as
-- Sim.armies: ids and numbers only, no names, no tables per field.
function Sim.boatSnapshot(self: Sim): { any }
	local out = {}
	for _, b in self.boats do
		if b.active then
			table.insert(out, {
				b = b.id,
				id = b.ownerId,
				t = b.ext.targetId,
				troops = math.floor(b.troops),
				x = b.tile % W,
				y = (b.tile - b.tile % W) / W,
			})
		end
	end
	return out
end

-- How upstream decides WHERE an attack's number goes. The centroid of the
-- whole front is not it: a front that wraps a coast or splits at a
-- chokepoint has no single middle, and the average of its two halves lands
-- in open sea -- or, while a nation is still expanding into empty land,
-- dead on top of its own capital, because that front wraps the country.
-- Upstream partitions the border into connected segments and labels the
-- largest two: AttackImpl.clusteredPositions / clusterBorderTiles,
-- src/core/game/AttackImpl.ts:102-183.
local ARMY_CLUSTER_MIN = 30
local ARMY_CLUSTER_MAX = 2

-- Read once, with a floor, because `nil ~= nil` is FALSE: if this key
-- ever went missing the tribe test below would quietly answer "tribe"
-- for every attacker on the map and delete every incoming number --
-- which looks like a rendering bug and is actually a Config rollback.
local ARMY_TIER_TRIBE = Config.TIER_TRIBE or -1

-- 8-connected BFS over the attack's border set (upstream walks
-- forEachNeighborWithDiag), one representative tile per segment: the tile
-- of that segment NEAREST its own centroid, so the number always sits on a
-- real front-line tile rather than in the middle of the arc it spans.
-- Cost is one pass over the border, and a busy front is thousands of
-- tiles -- see the budget on Sim.armies for why that is not paid in full
-- on every broadcast.
local function clusterFront(atk: Attack): { { tile: number, size: number } }
	local visited: { [number]: true } = {}
	local queue: { number } = {}
	local clusters = {}

	for start in atk.borderSet do
		if visited[start] then
			continue
		end
		visited[start] = true
		queue[1] = start
		local qi, size = 1, 1
		local sumX, sumY = 0, 0

		while qi <= size do
			local t = queue[qi]
			qi += 1
			local tx = t % W
			local ty = (t - tx) / W
			sumX += tx
			sumY += ty
			-- Bounds hoisted out of the neighbourhood. The interior of the
			-- map is every tile but four edges, so eight edge tests per tile
			-- to catch a case that essentially never happens is most of the
			-- loop. The centre tile needs no skip either: it is always
			-- already visited, so the test below rejects it for free.
			local y0 = if ty > 0 then -1 else 0
			local y1 = if ty < H - 1 then 1 else 0
			local x0 = if tx > 0 then -1 else 0
			local x1 = if tx < W - 1 then 1 else 0
			for dy = y0, y1 do
				local base = (ty + dy) * W + tx
				for dx = x0, x1 do
					local nb = base + dx
					-- `visited` first: well inside a blob most neighbours
					-- are already taken, so it short-circuits far more often
					-- than the membership test does.
					if not visited[nb] and atk.borderSet[nb] then
						visited[nb] = true
						size += 1
						queue[size] = nb
					end
				end
			end
		end

		local cx, cy = sumX / size, sumY / size
		local best, bestD = queue[1], math.huge
		for i = 1, size do
			local t = queue[i]
			local tx = t % W
			local dx = tx - cx
			local dy = (t - tx) / W - cy
			local d = dx * dx + dy * dy
			if d < bestD then
				bestD = d
				best = t
			end
		end
		table.insert(clusters, { tile = best, size = size })
	end

	table.sort(clusters, function(a, b)
		return a.size > b.size
	end)

	if #clusters <= 1 then
		return clusters
	end
	-- Segments below the floor are dropped as label clutter -- except that
	-- the largest is always kept, so an attack ground down to five tiles
	-- still carries its number.
	local keep = {}
	for _, c in clusters do
		if c.size >= ARMY_CLUSTER_MIN and #keep < ARMY_CLUSTER_MAX then
			table.insert(keep, c)
		end
	end
	if #keep == 0 then
		keep[1] = clusters[1]
	end
	return keep
end

-- Upstream pays for clustering PER CLIENT, in a worker, for the one
-- player's own attacks. We pay it once on the server for every attack any
-- human is in, five times a second, which is a different bill entirely: a
-- single 4000-tile front is about 2 ms, and a full roster's worth would be
-- tens of milliseconds out of every broadcast. So a call spends a fixed
-- number of tiles starting where the last one stopped, and an attack whose
-- turn has not come reuses the fronts it already had. A front does not
-- move far in a fraction of a second and the client eases toward whatever
-- it is sent; what matters is that the cost per broadcast is a constant
-- instead of a function of how many people are playing.
local ARMY_CLUSTER_BUDGET = 12000

-- Every army whose number a HUMAN is entitled to see. Upstream draws
-- attack troop counts ONLY for attacks the viewer is personally in: its
-- controller walks myPlayer's own outgoing and incoming attack lists and
-- nothing else (src/client/controllers/AttackingTroopsController.ts:112-132).
-- That is the whole reason its map does not read as a field of numbers --
-- across a roster this size, a number over every war on the continent
-- buries the one or two that are yours. The server cannot tell one client
-- from another inside a single broadcast, so it ships the UNION over every
-- human and each client keeps the rows addressed to it.
--
-- Two upstream filters ride along. An outgoing attack into UNOWNED land
-- carries no number at all (`if (!attack.targetID) continue`) -- expansion
-- is not a battle, and that front wraps the whole country, so its label
-- would sit on the nation's own name. And an incoming attack from a
-- PlayerType.Bot -- our TIER_TRIBE -- is ignored as noise.
--
-- These troops were taken out of their nation's pool by launchAttack and
-- are NOT in p.troops, so the garrison on the territory and the army on
-- the border never double-count: an empire that sends half its men away
-- visibly halves at home, which is the point of committing them.
function Sim.armies(self: Sim): { any }
	local out = {}
	local cache = self.armyCache
	if cache == nil then
		cache = {}
		self.armyCache = cache
	end

	-- The eligible attacks, in a stable order, so the rotating cursor walks
	-- the same list twice running rather than skipping wars at random.
	local live = {}
	for _, atk in self.attacks do
		if not (atk.active and atk.borderCount > 0 and atk.troops >= 1) then
			continue
		end
		local attacker = self.players[atk.attackerId]
		local target = if atk.targetId ~= 0 then self.players[atk.targetId] else nil
		if attacker == nil or target == nil then
			continue
		end
		local outgoing = not attacker.isBot
		local incoming = (not target.isBot) and attacker.tier ~= ARMY_TIER_TRIBE
		if outgoing or incoming then
			table.insert(live, atk)
		end
	end
	table.sort(live, function(a, b)
		return a.id < b.id
	end)

	local n = #live
	local cursor = 0
	if n == 0 then
		table.clear(cache)
	else
		local start = (self.armyCursor or 0) % n
		local budget = ARMY_CLUSTER_BUDGET
		local seen = {}

		for k = 0, n - 1 do
			local atk = live[(start + k) % n + 1]
			seen[atk.id] = true
			local fronts = cache[atk.id]

			if fronts == nil then
				-- An attack seen for the first time is clustered whatever
				-- the budget says: it has no fronts to fall back on, and a
				-- war that started this second should not wait its turn for
				-- a number. It does not move the cursor, so it cannot make
				-- the rotation skip anybody.
				fronts = clusterFront(atk)
				cache[atk.id] = fronts
				budget -= atk.borderCount
			elseif budget > 0 then
				budget -= atk.borderCount
				fronts = clusterFront(atk)
				cache[atk.id] = fronts
				cursor = start + k + 1
			end

			local troops = math.floor(atk.troops)
			for i, c in fronts do
				local x = c.tile % W
				table.insert(out, {
					a = atk.id,
					c = i - 1,
					id = atk.attackerId,
					t = atk.targetId,
					troops = troops,
					x = x,
					y = (c.tile - x) / W,
					n = c.size,
				})
			end
		end

		for id in cache do
			if not seen[id] then
				cache[id] = nil
			end
		end
	end
	self.armyCursor = cursor

	return out
end

-- A crippled empire collapses outright: whoever broke it absorbs everything
-- still flying its colours, wherever on the map that is. Scans the owner
-- buffer once, which is affordable because it fires at most once per
-- elimination -- and without it, wounded players linger as scattered pockets
-- and no one ever reaches the win threshold.
local function collapsePlayer(self: Sim, victim: Player, captorId: number)
	victim.alive = false
	victim.troops = 0
	Sim.cancelAttacks(self, victim.id)
	victim.killedBy = captorId

	-- The treasury goes with the country. Upstream `GameImpl.conquerPlayer`
	-- (src/core/game/GameImpl.ts), whose payout is `Config.conquerGoldAmount`
	-- (src/core/configuration/Config.ts:621-630). It is the
	-- only large lump of gold in a game whose income is flat, so finishing
	-- somebody off is what actually pays for a city -- and their cities come
	-- across too, tile by tile, as the absorption walks the map.
	-- Upstream `conquerGoldAmount`: an AI empire hands over its whole
	-- treasury, a HUMAN only half. Killing a person is already the most
	-- valuable thing on the map -- taking their land, their cities and their
	-- ports -- and paying full price for the treasury on top made hunting the
	-- one human in reach strictly better than any other war.
	local captor = self.players[captorId]
	if captor and captor.alive and victim.gold > 0 then
		-- conquerGoldAmount (Config.ts:621-630): a Bot and a Nation both hand
		-- over the whole treasury, a HUMAN only half. Branch rather than a
		-- flat multiply, because trade and rail payouts make gold fractional
		-- and `math.floor(gold * 1.0)` is not the same number as `gold`.
		local share = Config.TIER[victim.tier].CONQUER_GOLD_SHARE
		if share >= 1 then
			captor.gold += victim.gold
		else
			captor.gold += math.floor(victim.gold * share)
		end
	end
	victim.gold = 0

	-- The empire is finished HERE -- dead, disarmed, out of the win check.
	-- Only the land transfer is deferred, because finding every tile still
	-- flying its colours is a scan of all 1.6M and there is no reason to pay
	-- for it inside one tick. See COLLAPSE_SCAN_PER_TICK.
	table.insert(self.collapses, {
		victimId = victim.id,
		captorId = captorId,
		cursor = 0,
	})
end

-- Absorb a slice of one broken empire. Bounded twice over: by how far it may
-- SCAN (the cost when the remnant is scattered) and by how many tiles it may
-- flip (the cost on the wire when the remnant is one solid block).
local function stepCollapses(self: Sim)
	local job = self.collapses[1]
	if not job then
		return
	end

	-- If the captor died inside the transfer window, the remnant goes back to
	-- open land rather than to a corpse: a dead owner's tiles can never be
	-- attacked (every attack on a dead defender ends at once), so they would
	-- otherwise be frozen out of the map for the rest of the round.
	local captor = self.players[job.captorId]
	local to = (captor and captor.alive) and job.captorId or 0

	local owner = self.map.owner
	local victimId = job.victimId
	local i = job.cursor
	local scanEnd = math.min(N, i + Config.COLLAPSE_SCAN_PER_TICK)
	local flips = Config.COLLAPSE_TILES_PER_TICK

	while i < scanEnd and flips > 0 do
		if buffer.readu8(owner, i) == victimId then
			Sim.conquer(self, i, to)
			flips -= 1
		end
		i += 1
	end
	job.cursor = i

	if i >= N then
		local victim = self.players[victimId]
		if victim then
			table.clear(victim.border)
			victim.borderCount = 0
			victim.tileCount = 0
			-- Zeroed alongside tileCount: the centroid is sumX/tileCount, and
			-- leaving a stale numerator against a forced-zero denominator is
			-- the kind of thing that only shows up as a division by zero
			-- somewhere else entirely.
			victim.sumX = 0
			victim.sumY = 0
		end
		table.remove(self.collapses, 1)
	end
end

local LN2 = math.log(2)

local function sigmoid(v: number, decay: number, mid: number): number
	return 1 / (1 + math.exp(-decay * (v - mid)))
end

-- Tick budget for one attack, from the width of its own front. Uses the
-- tracked border COUNT, not the heap size: the heap holds duplicates by
-- design (lazy decrease-key) and would wildly overstate the front.
local function tilesPerTick(self: Sim, atk: Attack, defender: Player?, border: number): number
	if defender then
		return math.clamp(
			(Config.SPEED_RATIO_DIV * atk.troops / math.max(defender.troops, 1)) * 2,
			Config.BUDGET_RATIO_MIN,
			Config.BUDGET_RATIO_MAX
		) * border * Config.BUDGET_PLAYER_MULT
	end
	return border * Config.BUDGET_NEUTRAL_MULT
end

-- Resolves one contested tile. Returns attacker troop loss, defender troop
-- loss, and the tick-budget cost of taking it. See the ATTRITION block in
-- Config for the shape and why defenderLoss is plain density.
-- sizeDebuff / lossPenalty / speedPenalty are passed in rather than derived
-- here: they depend only on the two empires' SIZES, which move by a handful
-- of tiles across a single tick, and deriving them cost an exp and two pows
-- FOR EVERY CONQUERED TILE. See the hoist in processAttack.
local function attackLogic(
	self: Sim,
	atk: Attack,
	attacker: Player,
	defender: Player?,
	tile: number,
	sizeDebuff: number,
	lossPenalty: number,
	speedPenalty: number,
	magScale: number,
	borderSize: number
): (number, number, number)
	local tType = TileMap.terrainType(self.map, tile)
	local mag = Config.TERRAIN_MAG[tType] or Config.TERRAIN_MAG[1]
	local speed = Config.TERRAIN_SPEED[tType] or Config.TERRAIN_SPEED[1]

	-- Upstream Config.ts:775-779. A fallout tile multiplies BOTH the troop cost
	-- and the tick cost by falloutDefenseModifier(ratio) = 5 - ratio*2, i.e. 5x
	-- while the world is clean falling to 2.5x once half of it is glass. This
	-- is the whole reason nuking DENIES ground instead of donating it, and it
	-- has to sit ABOVE the terra-nullius branch: a fresh crater is unowned.
	-- NOTE the denominator: upstream's falloutRatio is over numLandTiles(),
	-- NOT numLandTiles - numTilesWithFallout (AttackExecution.ts:361-363),
	-- while the WIN CHECK uses the other one. That asymmetry is deliberate
	-- upstream and is not a typo to fix.
	if self.falloutCount > 0 and Nukes.hasFallout(self, tile) then
		local fallout = Nukes.falloutDefenseModifier(Nukes.falloutRatio(self))
		mag *= fallout
		speed *= fallout
	end

	if defender == nil then
		-- Config.ts:785 -- `mag / (attacker.type === PlayerType.Bot ? 10 : 5)`.
		-- A NATION pays the same 5 a human pays; only the filler Bot class gets
		-- the halved cost of unclaimed ground.
		local div = Config.TIER[attacker.tier].NEUTRAL_DIVISOR
		-- TERRAIN AFFECTS HOW FAST YOU EXPAND, and getting that to actually
		-- happen needs a DELIBERATE DEVIATION from upstream.
		--
		-- Upstream's neutral cost is
		--     clamp(2000 * speed / attackTroops, 5, 100)
		-- and the terrain speeds are 16.5 / 20 / 25. The floor binds the moment
		-- `troops > 2000 * 25 / 5 = 10,000` -- and an empire STARTS with 18,000
		-- (AI) or 25,000 (human). So in upstream, and in this file until now,
		-- plains / highland / mountain all cost exactly 5 from the first tick of
		-- the land grab and terrain has NO effect whatever on expansion rate.
		-- It only re-appears against a player, where `speed` multiplies with no
		-- clamp over it. Measured on a solo expansion before this change:
		-- relative uptake 0.93x plains, 1.28x highland, 1.05x mountain -- i.e.
		-- if anything, slightly INVERTED.
		--
		-- Fix: clamp on PLAINS, then scale by the terrain ratio outside the
		-- clamp. Plains keep exactly the rate every balance number was measured
		-- against; highland costs 1.21x and mountain 1.52x, which are upstream's
		-- own ratios rather than invented ones. NEUTRAL_TERRAIN_FACTOR
		-- exaggerates the spread if 1.5x does not read strongly enough on the
		-- map (1.0 = upstream's ratios, 0 = terrain-blind, the old behaviour).
		local plainsSpeed = Config.TERRAIN_SPEED[1]
		local base = math.clamp(
			Config.NEUTRAL_TILE_NUM * math.max(10, plainsSpeed) / math.max(atk.troops, 1),
			Config.NEUTRAL_TILE_MIN,
			Config.NEUTRAL_TILE_MAX
		)
		local ratio = speed / plainsSpeed
		local shaped = 1 + (ratio - 1) * (Config.NEUTRAL_TERRAIN_FACTOR or 1)
		return mag / div, 0,
			base * shaped / math.max(tilesPerTick(self, atk, nil, borderSize), 1e-6)
	end

	-- Upstream `openfrontio/OpenFrontIO`, Config.ts `attackLogic`, defender-
	-- is-a-player branch. Written there as
	--   attackerTroopLoss = mag * traitorLossMod
	--                       * (0.48 * ratioTerm + 0.0052 * defenderTroopLoss)
	--     ratioTerm       = within(defTroops/atkTroops, 0.6, 2)
	--                       * largeDefenderDebuff * largeAttackerLossBonus
	--   defenderTroopLoss = defTroops / defTiles
	--   tickFraction      = within(defTroops/atkTroops, 1, 7.5) / 5 * tileCost
	--                       * largeDefenderDebuff * largeAttackerCostBonus
	--                       / tickBudget
	-- and the form below expands to exactly it: BLEND * MAG_SCALE = 0.48,
	-- (1-BLEND) * ALT_COEF / 100 = 0.0052, and `sizeDebuff` with FLOOR 0.7 is
	-- `1 - 0.3 * sigmoid(...)`. BOTH TERMS ARE UPSTREAM'S -- an earlier build
	-- of this file deleted the density term and the defender-size term on the
	-- belief that they were local inventions. They are not: upstream declares
	-- ATTACKER_LOSS_DENSITY_WEIGHT at src/core/configuration/Config.ts:114 and
	-- builds largeDefenderDebuff at Config.ts:810-817. Read that file before
	-- touching either.
	-- `magScale` is upstream's BOT_DEFENDER_LOSS_MULT, hoisted in
	-- processAttack because it cannot change between tiles.
	local density = defender.troops / math.max(defender.tileCount, 1)
	local ratioTerm = math.clamp(
		defender.troops / math.max(atk.troops, 1),
		Config.ATTACK_RATIO_MIN,
		Config.ATTACK_RATIO_MAX
	)

	-- magScale multiplies `mag` ITSELF, which is what upstream does
	-- (Config.ts:805 scales mag before the loss expression). It used to sit on
	-- the ratio term only -- harmless while it was 1.0, but wrong the moment it
	-- is turned on: ATTACK_LOSS_BLEND is 0.6, so the DENSITY half carries 40%
	-- of the loss and would have escaped the discount entirely, delivering
	-- about 45% of an advertised 50% bonus.
	mag *= magScale
	local pressure = ratioTerm * mag * Config.ATTACK_MAG_SCALE * sizeDebuff * lossPenalty
	local blend = Config.ATTACK_LOSS_BLEND
	local attackerLoss = pressure
	if blend < 1 then
		-- THE LIVE PATH: ATTACK_LOSS_BLEND is 0.6, so both terms are in play.
		-- (An earlier comment here claimed this branch was unreachable. It was
		-- written while the blend was believed to be a local invention; it is
		-- upstream's, and it is what runs.)
		attackerLoss = blend * pressure
			+ (1 - blend) * (Config.ATTACK_ALT_COEF * density * (mag / 100))
	end

	local cost = math.clamp(
		defender.troops / (Config.SPEED_RATIO_DIV * math.max(atk.troops, 1)),
		Config.SPEED_RATIO_MIN,
		Config.SPEED_RATIO_MAX
	) * speed * sizeDebuff * speedPenalty

	-- The tick budget is recomputed HERE, per tile, from the attack's CURRENT
	-- troop count -- upstream holds `tickBudget = 1` in AttackExecution.tick
	-- and subtracts a fraction per tile for exactly this reason. A push that
	-- bleeds badly slows down inside the same tick instead of coasting on the
	-- width and strength it started the tick with. Only `borderSize` is fixed
	-- for the tick (jitter included), which is upstream's behaviour too.
	return attackerLoss, density,
		cost / math.max(tilesPerTick(self, atk, defender, borderSize), 1e-6)
end

function Sim.processAttack(self: Sim, atk: Attack, globalBudget: number): number
	local attacker = self.players[atk.attackerId]
	if not attacker or not attacker.alive then
		endAttack(self, atk, false, 0)
		return globalBudget
	end

	local defender: Player? = nil
	if atk.targetId ~= 0 then
		defender = self.players[atk.targetId]
		if not defender or not defender.alive then
			endAttack(self, atk, true, 0)
			return globalBudget
		end
	end

	-- The large-attacker penalty now lives inside attackLogic, applied per
	-- tile to both troop cost and budget cost.
	-- One tick's worth of conquest, spent as fractions -- see attackLogic.
	-- The front width is sampled ONCE and reused for every tile this tick.
	-- Upstream AttackExecution.ts:269 is `random.nextInt(0, 5)` and its
	-- nextInt is documented "max (exclusive)" (PseudoRandom.ts:45-50), so the
	-- roll is 0..4. Luau's NextInteger is inclusive at BOTH ends, so a
	-- literal transcription gave 0..5 -- a mean of 2.5 against upstream's
	-- 2.0, i.e. every attack drew ~25% more jitter budget per tick than it
	-- should. Check every ported nextInt for this; the bound is max - 1.
	local borderSize = atk.borderCount + self.rng:NextInteger(0, 4)
	local budget = 1

	-- Advance this attack's clock in proportion to the rate its budget
	-- already grants it, so a push with three times the army really does
	-- come due three times as often. Per front tile, so the clock does not
	-- race ahead simply because the front got wider.
	-- Reference mode has no per-attack clock and no readiness gate: an attack
	-- pops its heap until the budget runs out, and the ordering is carried
	-- entirely by the priority the tile was enqueued with.
	if FRONTIER_MODE ~= "reference" then
		atk.clock += tilesPerTick(self, atk, defender, borderSize)
			/ math.max(atk.borderCount, 1) * PACE
	end

	local map = self.map
	local owner = map.owner
	local nbuf = self.nbuf

	-- Hoisted out of the per-tile loop -- see attackLogic.
	local sizeDebuff, lossPenalty, speedPenalty, magScale = 1, 1, 1, 1
	if defender then
		local floor = Config.DEFENSE_DEBUFF_FLOOR
		if floor < 1 then
			sizeDebuff = floor
				+ (1 - floor)
					* (1 - sigmoid(
						defender.tileCount,
						LN2 / Config.DEFENSE_DEBUFF_HALFLIFE,
						Config.DEFENSE_DEBUFF_MIDPOINT
					))
		end
		-- Upstream uses ONE threshold with two exponents, and both are a
		-- BONUS to a huge attacker: past LARGE_ATTACKER_TILES its tiles cost
		-- fewer troops (exp 0.35) and less tick budget (exp 0.6).
		if attacker.tileCount > Config.LARGE_ATTACKER_TILES then
			lossPenalty = (Config.LARGE_ATTACKER_TILES / attacker.tileCount)
				^ Config.LARGE_ATTACKER_LOSS_EXP
		end
		local speedTiles = Config.LARGE_ATTACKER_SPEED_TILES or Config.LARGE_ATTACKER_TILES
		if attacker.tileCount > speedTiles then
			speedPenalty = (speedTiles / attacker.tileCount) ^ Config.LARGE_ATTACKER_SPEED_EXP
		end
		-- Upstream's BOT_DEFENDER_LOSS_MULT: cheaper to attack when the
		-- DEFENDER is its weak filler `Bot` class. Off (1.0) here, because
		-- our AI are tuned as upstream's `Nation`. See Config.
		-- Config.ts:800-806: `(attacker is Human || attacker is Nation) &&
		-- defender is Bot -> mag *= BOT_DEFENDER_LOSS_MULT` (0.7,
		-- Config.ts:104). A TRIBE attacker does NOT get the discount, so
		-- tribe-on-tribe stays full price -- which is what stops the filler
		-- layer cannibalising itself in the first minute.
		if not attacker.isBot and defender.isBot then
			-- CONQUEST DEVIATION: a real player invading ANY AI pays
			-- Config.HUMAN_VS_BOT_MAG per tile. Keys on the ATTACKER being a
			-- person; AI attacking AI never gets it, so this cannot be laundered
			-- through a nation.
			magScale = Config.HUMAN_VS_BOT_MAG or 1
		elseif attacker.tier ~= Config.TIER_TRIBE then
			-- Upstream's own rule survives underneath for AI attackers: the weak
			-- filler tier is cheaper to attack, and a TRIBE attacker gets no
			-- discount so the filler layer does not cannibalise itself.
			magScale = Config.TIER[defender.tier].DEFENDER_MULT
		end
	end

	-- Hard ceiling on pops for this attack this tick. A pop that turns out to
	-- be stale consumes no BUDGET -- it is not a conquest -- so without a cap
	-- the loop's only exit is an empty heap, and one tick could drain a heap
	-- with six figures in it. Whatever is left is stale by definition and
	-- costs nothing to leave for the next tick.
	local maxPops = atk.borderCount * 6 + 512
	local pops = 0

	while budget > 0 and globalBudget > 0 do
		if atk.troops < 1 then
			endAttack(self, atk, false, 0)
			break
		end

		-- The heap holds ready TIMES, and a tile whose time has not come is
		-- not available however much budget is left. THIS GATE IS WHAT MAKES
		-- THE DELAY MEAN ANYTHING: without it a budget wide enough to swallow
		-- a large share of the front every tick averages the per-tile
		-- randomness straight out, and the front advances as a flat wave --
		-- measured as a dead-straight edge over 46 rows, and territory that
		-- came out as discs no matter how the delays were weighted.
		local ready = Heap.peek(atk.frontier)
		if ready == nil then
			-- Nothing left adjacent: the push is spent, survivors go home.
			endAttack(self, atk, true, 0)
			break
		end
		if FRONTIER_MODE ~= "reference" and ready > atk.clock then
			-- The front is not due yet. The attack stays alive and waits.
			break
		end

		local tile = Heap.pop(atk.frontier)
		if tile == nil then
			endAttack(self, atk, true, 0)
			break
		end
		-- Duplicate copies of an already-processed tile find it absent and
		-- simply fall through the validity checks below.
		pops += 1
		if pops > maxPops then
			break
		end
		if atk.borderSet[tile] then
			atk.borderSet[tile] = nil
			atk.borderCount -= 1
			atk.prio[tile] = nil
			atk.sumX -= tile % W
			atk.sumY -= (tile - tile % W) / W
		end

		if buffer.readu8(owner, tile) ~= atk.targetId or not TileMap.isPassable(map, tile) then
			continue
		end

		-- ONE neighbour lookup, held in nbuf4 for the rest of the iteration.
		-- The same four tiles are needed three times per conquest -- to prove
		-- adjacency, to enqueue the newly exposed front, and to mop up
		-- pockets -- and this is the hottest loop in the tick. nbuf4 is
		-- private to this loop: Sim.conquer re-uses nbuf and enqueue uses
		-- nbuf2, which is exactly why the list had to be rebuilt each time.
		local nbuf4 = self.nbuf4
		local n = TileMap.neighbors4(tile, nbuf4)

		-- Must still touch our own territory, or an attack could teleport
		-- across a gap opened by someone else's conquest.
		local adjacent = false
		for k = 1, n do
			if buffer.readu8(owner, nbuf4[k]) == atk.attackerId then
				adjacent = true
				break
			end
		end
		if not adjacent then
			continue
		end

		local attackerLoss, defenderLoss, tileCost =
			attackLogic(self, atk, attacker, defender, tile, sizeDebuff, lossPenalty,
				speedPenalty, magScale, borderSize)

		budget -= tileCost
		atk.troops -= attackerLoss
		if defender then
			defender.troops = math.max(0, defender.troops - defenderLoss)
		end
		Sim.conquer(self, tile, atk.attackerId)

		-- Newly exposed frontier.
		for k = 1, n do
			local nb = nbuf4[k]
			if buffer.readu8(owner, nb) == atk.targetId then
				enqueue(self, atk, nb)
			end
		end

		-- Mop up anything this advance has just cut off. A tile whose every
		-- passable neighbour now belongs to the attacker is absorbed on the
		-- spot: without it the front leaves isolated pixels behind and
		-- territory renders as speckle rather than solid nations. Bounded
		-- work -- at most four neighbours of four neighbours per conquest.
		local nbuf2 = self.nbuf2
		for k = 1, n do
			local nb = nbuf4[k]
			if buffer.readu8(owner, nb) == atk.targetId and TileMap.isPassable(map, nb) then
				local q = TileMap.neighbors4(nb, nbuf2)
				local enclosed = true
				for j = 1, q do
					local n2 = nbuf2[j]
					-- Water and impassable terrain count as walls.
					if TileMap.isPassable(map, n2) and buffer.readu8(owner, n2) ~= atk.attackerId then
						enclosed = false
						break
					end
				end
				if enclosed then
					Sim.conquer(self, nb, atk.attackerId)
				end
			end
		end

		globalBudget -= 1

		-- Upstream AttackExecution.ts:428 -- strictly BELOW the bar, tested
		-- after every conquered tile (AttackExecution.ts:319).
		if defender and defender.tileCount < self.collapseTiles then
			collapsePlayer(self, defender, atk.attackerId)
			endAttack(self, atk, true, 0)
			break
		end
	end

	return globalBudget
end

-- ================================================================== bot AI ==

-- A reserve gate, jittered per think on top of the per-bot roll.
local function gate(self: Sim, base: number): number
	local j = Config.BOT_GATE_JITTER
	return base * (1 - j + self.rng:NextNumber() * 2 * j)
end

-- Bots have to SPEND, or the gold economy is something only humans interact
-- with: every AI empire would sit on a treasury it never converts, and a human
-- who buys three cities out-caps the entire roster by 750,000 troops for no
-- reason the map explains.
--
-- Deliberately dumb, and that is the right amount of clever here: a city is
-- worth the same 250,000 wherever it stands, so the only placement decision
-- that matters is "not on the frontier", and aiming at the middle of the
-- country gets that for one divide.
-- Upstream `NationStructureBehavior`, reduced to the part Conquest has an
-- analogue for: `doHandleStructures` (:430-530) and `shouldBuildStructure`
-- (:552-590). The ratios and the ORDER are the AI economy -- an empire's next
-- purchase is decided by how many cities it already owns, not by a coin flip.
--
-- What the old rule did instead was roll a kind at fixed odds, which meant a
-- bot bought ports it had nothing to trade with and never bought the two
-- things that actually consume a treasury. Measured before this: 30-minute
-- match, 3.3 BILLION gold created and the richest empire sitting on 250M
-- against a 1M cost cap -- gold was a number, not a decision.
local STRUCTURE_RATIO_PER_CITY: { [number]: number } = {
	[Economy.PORT] = 0.75,
	[Economy.FACTORY] = 0.75,
	[Units.SAM_LAUNCHER] = 0.20, -- SAM_RATIO_BY_DIFFICULTY[Medium]
	[Units.MISSILE_SILO] = 0.20,
}
-- A coastal empire wants far fewer factories, because its ports are already
-- earning and a factory only unlocks the rail beside them.
local FACTORY_COASTAL_RATIO_MULT = 0.33
local MAX_MISSILE_SILOS = 3
-- The FIRST silo comes at a lower bar than the ones after it, so a nation
-- starts nuking while the game is still going.
local FIRST_MISSILE_SILO_RATIO = 0.4
local BUILD_ORDER = { Economy.PORT, Economy.FACTORY, Units.SAM_LAUNCHER, Units.MISSILE_SILO }

-- upstream `unitsOwned` is the SUM OF LEVELS, which is what Units.count
-- returns -- a level-3 city counts as three.
local function shouldBuildStructure(self: Sim, p: Player, utype: number, cityCount: number, coastal: boolean): boolean
	local ratio = STRUCTURE_RATIO_PER_CITY[utype]
	if ratio == nil then
		return false
	end
	if utype == Economy.FACTORY and coastal then
		ratio *= FACTORY_COASTAL_RATIO_MULT
	end
	local owned = Units.count(self, p.id, utype)
	if utype == Units.MISSILE_SILO then
		if owned >= MAX_MISSILE_SILOS then
			return false
		end
		if owned == 0 then
			ratio = FIRST_MISSILE_SILO_RATIO
		end
	end
	local target = math.floor(cityCount * ratio)
	if utype == Economy.PORT then
		-- CONQUEST DEVIATION, and a deliberate one. floor(1 * 0.75) is zero, so
		-- upstream's rule makes an empire wait for its SECOND city before it
		-- wants a port -- measured at eight minutes into a 69-empire match, with
		-- no trade ship on the map before then. Naval trade is the thing ports
		-- exist for; an empire that owns a city wants one. A landlocked empire
		-- asks for it too and simply fails every placement probe, which costs a
		-- few thousand tile reads and falls through to the next kind.
		target = math.max(1, target)
	end
	return owned < target
end

local function structureGold(self: Sim, p: Player, utype: number): number
	if utype == Economy.CITY or utype == Economy.PORT or utype == Economy.FACTORY then
		return Economy.cost(p, utype)
	end
	return Units.cost(self, p.id, utype)
end

-- The centroid is a GUESS, never an answer: a crescent or a ring puts it in
-- open water (an empire wrapped round the Mediterranean does exactly this),
-- so every candidate is still read back out of the owner buffer. The floor
-- on the spread is what lets a SECOND city exist -- a spread narrower than
-- STRUCTURE_MIN_DIST puts every probe inside the first city's exclusion
-- zone, and the bot spends the rest of the round levelling one building.
local function tryPlace(self: Sim, p: Player, utype: number): boolean
	local rng = self.rng
	local cx = p.sumX / p.tileCount
	local cy = p.sumY / p.tileCount
	local spread = math.max(Config.STRUCTURE_MIN_DIST * 2, math.sqrt(p.tileCount) * 0.6)
	-- Cities, ports and factories are STATIONS and go through Economy, which
	-- owns the rail graph. A silo or a SAM is a plain unit -- putting one in
	-- structList would make it a train stop and a trade partner.
	local station = utype == Economy.CITY or utype == Economy.PORT or utype == Economy.FACTORY
	for _ = 1, Config.BOT_BUILD_PROBES do
		local x = math.floor(cx + rng:NextNumber(-1, 1) * spread)
		local y = math.floor(cy + rng:NextNumber(-1, 1) * spread)
		if TileMap.inBounds(x, y) then
			local tile = y * W + x
			if buffer.readu8(self.map.owner, tile) == p.id then
				if station then
					-- Economy.build re-checks gold, ground, crowding and pending
					-- sites, so a probe that survives the ownership test is allowed
					-- to be optimistic about the rest. A PORT probe also snaps to
					-- the nearest coast it owns, which is what lets a bot aiming at
					-- the middle of its country still find the sea.
					if (Economy.build(self, p.id, tile, utype)) then
						return true
					end
				elseif Units.canPlaceStructure(self, p.id, utype, tile) then
					local cost = Units.cost(self, p.id, utype)
					if p.gold >= cost then
						-- Gold leaves NOW and the building finishes later, which
						-- is the order Economy.build and upstream's
						-- ConstructionExecution both use: paying on completion
						-- would let one treasury fund unlimited simultaneous sites.
						p.gold -= cost
						local info = Units.info(utype)
						Units.spawn(self, utype, p.id, tile, {
							underConstruction = true,
							buildTicks = (info and info.buildTicks) or Config.STRUCTURE_BUILD_TICKS,
						})
						return true
					end
				end
			end
		end
	end
	return false
end

-- Bots have to SPEND, or the gold economy is something only humans interact
-- with: every AI empire would sit on a treasury it never converts, and a human
-- who buys three cities out-caps the entire roster by 750,000 troops for no
-- reason the map explains.
local function botBuild(self: Sim, p: Player)
	if p.tileCount <= 0 then
		return
	end
	if self.rng:NextNumber() > Config.BOT_BUILD_CHANCE then
		return
	end

	local cityCount = Units.count(self, p.id, Units.CITY)
	-- Owning a port IS the coastal test here. Upstream asks the map for the
	-- water components the empire touches; this is the same answer for the one
	-- decision that reads it (how badly a factory is wanted) and costs nothing.
	local coastal = p.portCount > 0
	local defences = Config.BOT_BUILDS_DEFENCES ~= false
	for _, utype in BUILD_ORDER do
		local isDefence = utype == Units.SAM_LAUNCHER or utype == Units.MISSILE_SILO
		if (defences or not isDefence)
			and shouldBuildStructure(self, p, utype, cityCount, coastal)
			and p.gold >= structureGold(self, p, utype)
			and tryPlace(self, p, utype)
		then
			return
		end
	end
	-- Cities are the fallback and the thing every other ratio is measured
	-- against, so an empire that wants nothing else always widens its base.
	if p.gold >= Economy.cost(p, Economy.CITY) then
		tryPlace(self, p, Economy.CITY)
	end
end

-- TribeExecution.deleteNextStructure (src/core/execution/TribeExecution.ts:
-- 86-94): a tribe razes ONE captured structure per think. It is why upstream
-- can let filler overrun your cities without handing it your economy, and it
-- is half of why a tribe never banks a troop ceiling it should not have (the
-- other half is that the class scale covers the city term -- see maxTroops).
--
-- Upstream also gates this on canDeleteUnit(), a 30-tick cooldown; a tribe
-- thinks every 40-80 ticks, so the think cadence already clears it.
--
-- COST: the structList walk is skipped entirely unless the tribe owns
-- something, which is an O(1) counter test and false for almost every tribe.
local function tribeRaze(self: Sim, p: Player)
	if (p.cityCount + p.portCount + p.factoryCount) <= 0 then
		return
	end
	local list = self.structList
	for i = 1, #list do
		local s = list[i]
		if s.ownerId == p.id then
			Economy.remove(self, s)
			return
		end
	end
end

-- Upstream src/core/execution/TribeExecution.ts, whose whole targeting is
-- AiAttackBehavior.attackRandomTarget (:703-736) and nothing else.
--
-- A TRIBE IS NOT A SMALL NATION. TribeExecution builds its AiAttackBehavior
-- with six arguments (:48-55), leaving allianceBehavior undefined, and
-- maybeAttack THROWS without one (AiAttackBehavior.ts:53-56). So a tribe has
-- no bordering-player scan (:60-87), no reserve gate, no boat roll, no
-- alliance offers and no strategy ladder. That is exactly why upstream can
-- afford 400 of them, and why this function is a fifth of botThink's cost.
local function tribeThink(self: Sim, p: Player)
	local rng = self.rng
	local map = self.map
	local owner = map.owner
	local nbuf = self.nbuf
	local tier = Config.TIER[Config.TIER_TRIBE]
	local poolMax = maxTroops(p)

	-- The border window. Upstream reads a cached nearby() list instead
	-- (:722); this is the analogue, at a fifth of a nation's sample.
	local neutralTile: number? = nil
	local rivals = {}
	local seen: { [number]: boolean } = {}
	local scanned = 0
	local tile = p.scanCursor
	if tile ~= nil and p.border[tile] == nil then
		tile = nil
	end
	if tile == nil then
		tile = next(p.border)
	end
	local wrapped = false
	while tile ~= nil do
		scanned += 1
		if scanned > tier.BORDER_SAMPLE then
			break
		end
		local n = TileMap.neighbors4(tile, nbuf)
		for k = 1, n do
			local nb = nbuf[k]
			if TileMap.isPassable(map, nb) then
				local o = buffer.readu8(owner, nb)
				if o == 0 then
					if neutralTile == nil then
						neutralTile = nb
					end
				elseif o ~= p.id and not seen[o] and not Sim.sameTeam(self, p.id, o) then
					seen[o] = true
					table.insert(rivals, { id = o, tile = nb })
				end
			end
		end
		tile = next(p.border, tile)
		if tile == nil then
			wrapped = true
			tile = next(p.border)
		end
	end
	p.scanCursor = tile

	local function send(targetTile: number): boolean
		local tid = buffer.readu8(owner, targetTile)
		if tid == p.id then
			return false
		end
		if tid ~= 0 and Sim.sameTeam(self, p.id, tid) then
			return false
		end
		-- calculateAttackTroops :962-964 -- the reserve is chosen from the
		-- TARGET: expandRatio for unowned ground, reserveRatio for a player.
		-- What is committed is everything ABOVE it (:1005).
		local reserve = (tid == 0)
			and (p.aiExpandReserve or Config.BOT_EXPAND_RESERVE_RATIO)
			or (p.aiWarReserve or Config.BOT_WAR_RESERVE_RATIO)
		local troops = p.troops - poolMax * reserve
		if troops < 1 then
			return false
		end
		return (Sim.launchAttack(self, p.id, targetTile, 0, troops))
	end

	-- TribeExecution.ts:47-60 -- the FIRST think sends one attack at unclaimed
	-- ground and returns before anything else exists.
	if p.aiSeeded ~= true then
		p.aiSeeded = true
		if neutralTile ~= nil then
			send(neutralTile)
		end
		return
	end

	-- TribeExecution.ts:115-121 -- unclaimed ground first, and PERMANENTLY
	-- LATCHED off once the frontier has none. The latch belongs to this class
	-- and to nothing else: a nation re-tests every think (:89-95). It is only
	-- safe to set when the window covered the WHOLE border, or a sampling miss
	-- would convert an expander into a combatant for good.
	if p.tnLatched ~= true then
		if neutralTile ~= nil then
			if send(neutralTile) then
				return
			end
		elseif wrapped then
			p.tnLatched = true
		end
	end

	-- attackRandomTarget (:703-736). TRIGGER GATE ONLY -- there is no reserve
	-- gate on this path (:705).
	if p.troops < poolMax * (p.aiTrigger or Config.BOT_TRIGGER_RATIO) then
		return
	end

	-- :708-711 -- retaliate against the LARGEST incoming attack. A tribe
	-- applies no attacker filter: :409-414 drops Bot attackers only when the
	-- defender is not itself a Bot.
	local biggest, biggestTroops = 0, 0
	for _, atk in self.attacks do
		if atk.active and atk.targetId == p.id and atk.troops > biggestTroops
			and not Sim.sameTeam(self, p.id, atk.attackerId)
		then
			biggestTroops = atk.troops
			biggest = atk.attackerId
		end
	end
	if biggest ~= 0 then
		local t = nil
		for _, r in rivals do
			if r.id == biggest then
				t = r.tile
				break
			end
		end
		if t == nil then
			local e = self.players[biggest]
			t = e and next(e.border) or nil
		end
		if t ~= nil and send(t) then
			return
		end
	end

	-- :721-735 -- a SHUFFLED neighbour list, and a Nation or Human neighbour is
	-- skipped 1 time in 2 (:726-733). There is no human-hesitation roll:
	-- shouldAttack is unconditionally true for a Bot attacker (:856).
	for i = #rivals, 2, -1 do
		local j = rng:NextInteger(1, i)
		rivals[i], rivals[j] = rivals[j], rivals[i]
	end
	for _, r in rivals do
		local o = self.players[r.id]
		if o ~= nil and o.alive then
			local peer = o.tier ~= Config.TIER_TRIBE
			if not (peer and rng:NextNumber() < tier.PEER_SKIP_CHANCE) then
				if send(r.tile) then
					return
				end
			end
		end
	end
end

-- Upstream NPC combat, ported from src/core/execution/utils/AiAttackBehavior.ts
-- (`maybeAttack` :53-111 and `attackBestTarget` :232-258), driven by
-- src/core/execution/TribeExecution.ts and src/core/execution/NationExecution.ts.
--
-- THE SHAPE, in upstream's order: terra nullius first and UNLATCHED; then a
-- boat roll; then a reserve gate, a trigger gate, and a per-difficulty list of
-- strategies run until one commits. Target choice is the FIRST entry of a list
-- sorted ASCENDING BY ABSOLUTE TROOPS, which is why every strategy below means
-- "the weakest one that qualifies".
--
-- Three things an earlier build of this file had are NOT upstream and are gone:
--   * a remembered enemy with a forget timer. Upstream HEAD has no enemy
--     memory of any kind -- AiAttackBehavior carries exactly one field
--     (botAttackTroopsSent, :40). Sustained pressure is structural instead:
--     the ascending sort keeps picking the same weakest neighbour, and a
--     repeat attack MERGES into the running one (AttackExecution.ts:155-165,
--     mirrored by launchAttack's "reinforce an existing push").
--   * target choice by troop DENSITY with a per-bot exponent. Density appears
--     in upstream exactly once (:447) and only to order filler tribes.
--   * a permanent expansion latch. That belongs to the weak TRIBE class
--     (TribeExecution.ts:12, :115-121); a Nation re-tests unclaimed ground on
--     every think (:89-95).
function Sim.botThink(self: Sim, p: Player)
	if not p.spawned or not p.alive then
		return
	end

	-- CONQUEST-ONLY, and deliberately before every gate below. Upstream runs
	-- structure spending from NationExecution.tick on the same beat as the
	-- attack think (NationExecution.ts:204) and TWICE MORE between beats
	-- (:181-197), precisely so gold never outruns spending. We get one think
	-- per bot, so building rides on it: hesitating about an attack is no
	-- reason to leave the treasury idle.
	-- TribeExecution has no structure spending at all -- it RAZES what it
	-- captures (TribeExecution.ts:86-94) -- and its targeting is a different
	-- function entirely, not a cheaper configuration of this one. Split here,
	-- before anything below runs.
	if p.tier == Config.TIER_TRIBE then
		tribeRaze(self, p)
		tribeThink(self, p)
		return
	end

	botBuild(self, p)

	-- CONQUEST-ONLY decorrelation. Upstream gives each AI its own PseudoRandom
	-- seeded from its id hash (TribeExecution.ts:22) and a distinct attackRate,
	-- so the roster never phase-locks. We share one Random across every empire
	-- and income here is deterministic, so without this the map visibly pulses.
	if self.rng:NextNumber() < (p.aiIdle or 0) then
		return
	end

	local map = self.map
	local owner = map.owner
	local nbuf = self.nbuf
	local rng = self.rng

	-- Upstream config.maxTroops(player). EVERY gate below is a share of this,
	-- never of the army on hand: hasReserveRatioTroops (:393-397),
	-- hasTriggerRatioTroops (:399-403), calculateAttackTroops (:964).
	local poolMax = maxTroops(p)

	-- Upstream isFFA(): gameConfig().gameMode === GameMode.FFA (:692-694).
	local ffa = self.teamCount <= 0

	-- Upstream gates troopSendCap (:910-919) and isAttackTooWeak (:885-889) to
	-- Hard and above, and reorders the strategy list per difficulty (:363-378).
	-- Conquest has no difficulty, so one flag picks the projection.
	local myTier = Config.TIER[p.tier]
	local hardTier = myTier.RESTRAINT == true

	-- The three ratios, jittered once per think. Upstream does not jitter at
	-- all -- they are rolled ONCE per AI in its constructor
	-- (TribeExecution.ts:25-27) and never move. Conquest keeps a small jitter
	-- because income here is deterministic and a fixed gate makes one bot's
	-- attacks fire on an exact period. Hoisted out of the commit path so the
	-- border scan below can exit early on an EXACT affordability test.
	local expandReserve = gate(self, p.aiExpandReserve or Config.BOT_EXPAND_RESERVE_RATIO)
	local warReserve = gate(self, p.aiWarReserve or Config.BOT_WAR_RESERVE_RATIO)
	local triggerLevel = gate(self, p.aiTrigger or Config.BOT_TRIGGER_RATIO)

	-- ONE walk of the attack list feeds five upstream queries that each walk
	-- their own per-player list: findIncomingAttackPlayer (:405-426), the
	-- incoming floor in troopSendCap (:942-946), the "under attack may
	-- retaliate freely" exemption in isAttackTooWeak (:883), findVictim's
	-- incoming sum (:586-590), and outgoingAttacks() for the sustain set.
	-- Upstream affords five walks because every Player carries its own
	-- incoming/outgoing arrays; Conquest has one flat self.attacks.
	local incomingTotal = 0
	-- 0 is the no-owner sentinel throughout Sim (ids start at 1), so
	-- retaliation needs no optional and no refinement.
	local biggestAttacker = 0
	local biggestTroops = 0
	-- AiAttackBehavior.ts:409-414 -- a defender that is NOT itself a Bot drops
	-- attacks whose attacker IS a Bot before choosing whom to retaliate
	-- against. Tracked alongside rather than replacing, because a tribe
	-- defender applies no such filter.
	local biggestPeerAttacker = 0
	local biggestPeerTroops = 0
	local incomingFrom: { [number]: number } = {}
	local pressureOn: { [number]: number } = {}
	local ourTargets: { [number]: boolean } = {}
	for _, atk in self.attacks do
		if atk.active then
			local tid = atk.targetId
			if tid ~= 0 then
				pressureOn[tid] = (pressureOn[tid] or 0) + atk.troops
			end
			if atk.attackerId == p.id and tid ~= 0 then
				ourTargets[tid] = true
			end
			if tid == p.id then
				incomingTotal += atk.troops
				local aid = atk.attackerId
				incomingFrom[aid] = (incomingFrom[aid] or 0) + atk.troops
				if atk.troops > biggestTroops and not Sim.sameTeam(self, p.id, aid) then
					biggestTroops = atk.troops
					biggestAttacker = aid
				end
				if atk.troops > biggestPeerTroops and not Sim.sameTeam(self, p.id, aid) then
					local a = self.players[aid]
					if a ~= nil and a.tier ~= Config.TIER_TRIBE then
						biggestPeerTroops = atk.troops
						biggestPeerAttacker = aid
					end
				end
			end
		end
	end

	-- ---- the border window -------------------------------------------------
	-- Upstream walks the WHOLE border every think and unions in nearby()
	-- (:60-78), so its bordering-player set is exact. A late-game frontier
	-- here is tens of thousands of tiles across up to 72 empires, so we read
	-- BOT_BORDER_SAMPLE tiles and resume from where the last think stopped
	-- (`next` from a stored key is O(1)). Successive thinks still sweep the
	-- whole frontier; they just take several thinks to get round.
	local neutralTile: number? = nil
	local tileByRival: { [number]: number } = {}
	local rivalCount = 0
	local scanned = 0
	local sample = myTier.BORDER_SAMPLE
	-- Exact, not a heuristic: if the Terra Nullius commit is already
	-- affordable, the branch below returns before anything reads tileByRival.
	local expandAffordable = (p.troops - poolMax * expandReserve) >= 1

	local tile = p.scanCursor
	if tile ~= nil and p.border[tile] == nil then
		tile = nil
	end
	if tile == nil then
		tile = next(p.border)
	end
	while tile ~= nil do
		scanned += 1
		if scanned > sample then
			break
		end
		local n = TileMap.neighbors4(tile, nbuf)
		for k = 1, n do
			local nb = nbuf[k]
			if TileMap.isPassable(map, nb) then
				local o = buffer.readu8(owner, nb)
				if o == 0 then
					if neutralTile == nil then
						neutralTile = nb
					end
				elseif o ~= p.id then
					-- One touching tile per rival and nothing else: upstream
					-- scores WHO a rival is, never which of their tiles the
					-- scan happened to brush.
					if tileByRival[o] == nil then
						rivalCount += 1
					end
					tileByRival[o] = nb
				end
			end
		end
		if neutralTile ~= nil and expandAffordable then
			break
		end
		tile = next(p.border, tile)
		if tile == nil then
			tile = next(p.border)
		end
	end
	p.scanCursor = tile

	-- Anyone we already have a live push against joins this think's candidate
	-- set even if the window missed them.
	--
	-- Upstream needs nothing like this: its bordering set is exact, so "the
	-- weakest neighbour" is the SAME player think after think and the repeated
	-- sendAttack folds into the running attack. Our window is a few hundred
	-- tiles of a frontier that can be 27,000, so consecutive thinks see
	-- near-disjoint rival sets and the choice would thrash -- a war would be an
	-- occasional coincidence, and an unreinforced push always loses to the
	-- defender's regrowth. Keying the carry off a LIVE ATTACK rather than a
	-- timer needs no policy: it lasts exactly as long as the push does, and the
	-- target is still re-chosen from scratch every think.
	for id in ourTargets do
		if tileByRival[id] == nil then
			local e = self.players[id]
			if e and e.alive and e.spawned and not Sim.sameTeam(self, p.id, id) then
				local t = next(e.border)
				if t ~= nil then
					tileByRival[id] = t
					rivalCount += 1
				end
			end
		end
	end

	-- ---- upstream gates, as closures ---------------------------------------

	-- Upstream shouldAttack (:849-871): always true for Terra Nullius, for any
	-- non-Human target, and whenever the ATTACKER is a Bot. PseudoRandom
	-- .chance(odds) is 1/odds, so Medium's `chance(4)` REFUSAL (:867) means an
	-- AI attacks a human 3 times in 4, while Easy's `nextInt(0,4) ~= 0` (:864)
	-- means 1 time in 4. Conquest has ONE AI class, so mapping our AI onto
	-- "the attacker is a Bot" would delete the rule; it hesitates instead.
	local function shouldAttack(otherId: number): boolean
		if otherId == 0 then
			return true
		end
		local other = self.players[otherId]
		if other == nil or other.isBot then
			return true
		end
		-- The hesitation is a property of the ATTACKER's class and
		-- difficulty, not a global: a Bot short-circuits to true (:856), an
		-- Easy nation attacks 1 time in 4 (:864), a Medium nation 3 in 4
		-- (:867), Hard and above always.
		return rng:NextNumber() <= myTier.ATTACK_HUMAN_CHANCE
	end

	-- Upstream isAttackTooWeak (:878-890). Bot attackers and team games are
	-- exempt, a defender already under attack may retaliate freely, and it
	-- only applies on Hard and above.
	local function isAttackTooWeak(troops: number, otherId: number): boolean
		if not hardTier or not ffa or incomingTotal > 0 then
			return false
		end
		local other = self.players[otherId]
		return other ~= nil and troops < other.troops * Config.BOT_TOO_WEAK_RATIO
	end

	-- Upstream troopSendCap (:903-949): never let our own troops fall below a
	-- fraction of the strongest non-allied, non-Bot neighbour -- Hard 0.75
	-- (:912), Impossible 0.9. Under attack the cap is raised to at least the
	-- total incoming (:941-946). Upstream reads player.nearby(); our sampled
	-- rivals are the analogue. "non-Bot" here means a human, which is exactly
	-- the threat upstream means by it.
	local function troopSendCap(): number
		if not hardTier or not ffa then
			return math.huge
		end
		local worst = 0
		for id in tileByRival do
			local other = self.players[id]
			-- AiAttackBehavior.ts:922-931 excludes only PlayerType.Bot from
			-- the threat set -- a NATION neighbour counts. Reading
			-- `not other.isBot` excluded every AI, so the cap almost never
			-- bound. (Unreachable on TIER_LEGACY: RESTRAINT is false and the
			-- function returns math.huge above.)
			if other and other.tier ~= Config.TIER_TRIBE and not Sim.sameTeam(self, p.id, id) then
				if other.troops > worst then
					worst = other.troops
				end
			end
		end
		local cap = math.huge
		if worst > 0 then
			cap = math.max(0, p.troops - math.ceil(worst * Config.BOT_RETAIN_FRACTION))
		end
		if incomingTotal > 0 and cap < incomingTotal then
			cap = incomingTotal
		end
		return cap
	end

	-- Upstream sendAttack (:760-778) -> calculateAttackTroops (:951-1000) ->
	-- sendLandAttack (:1002-1019). The reserve is chosen from the TARGET, not
	-- the caller: expandRatio for unowned ground, reserveRatio for a player
	-- (:962-964). What is committed is everything ABOVE that reserve (:1005),
	-- never a fraction of the army on hand.
	local function commit(targetTile: number, force: boolean, absTroops: number?): boolean
		local tid = buffer.readu8(owner, targetTile)
		if tid == p.id then
			return false
		end
		if tid ~= 0 and Sim.sameTeam(self, p.id, tid) then
			return false
		end
		if not force and not shouldAttack(tid) then
			return false
		end

		-- calculateAttackTroops :956-963 drops to the EXPAND reserve against
		-- a Bot that owns structures, to take them back before the tribe razes
		-- them (TribeExecution.ts:86-94). Now expressible: cityCount and
		-- portCount make "owns structures" an O(1) test.
		local reserve = expandReserve
		if tid ~= 0 then
			local t = self.players[tid]
			local razer = t ~= nil
				and t.tier == Config.TIER_TRIBE
				and (t.cityCount + t.portCount + t.factoryCount) > 0
			if not razer then
				reserve = warReserve
			end
		end

		local troops = p.troops - poolMax * reserve
		-- attackBots sizes its own commitment (calculateBotAttackTroops
		-- :1053-1072) and passes it in; everything else uses the reserve above.
		if absTroops ~= nil then
			troops = absTroops
		end
		if tid ~= 0 then
			local cap = troopSendCap()
			if troops > cap then
				troops = cap
			end
		end
		if troops < 1 then
			return false
		end
		if tid ~= 0 and isAttackTooWeak(troops, tid) then
			return false
		end

		-- CONQUEST-ONLY. Upstream has no such refusal: its only nod to mutual
		-- annihilation (AttackExecution.ts:141-154, mirrored in
		-- Sim.launchAttack) is troopSendCap raising the cap to the incoming
		-- total and isAttackTooWeak exempting a defender under attack -- i.e.
		-- it commits HARDER, never less. Committing into a larger opposing
		-- push here spends the army and moves no ground at all, and with both
		-- sides doing it every think that is a stable cold war rather than a
		-- battle. Measured without it: 30% of every troop committed in the
		-- match went to cancelling somebody out, and the round ran to the
		-- 30-minute limit with a 20% leader.
		if Config.OPPOSING_ATTACKS_CANCEL and tid ~= 0 then
			local against = incomingFrom[tid] or 0
			if against >= troops then
				return false
			end
		end

		local ok, why = Sim.launchAttack(self, p.id, targetTile, 0, troops)
		if ok then
			return true
		end

		-- Upstream picks land vs boat with sharesBorderWith(target) (:764-767),
		-- an exact adjacency query we do not have: a carried target, or one
		-- whose contact tile fell outside this window, may not touch us at
		-- all. seedFrontier answers it for free and refunds when it cannot, so
		-- the cascade is "try land; if the engine says notadjacent, boat".
		if why == "notadjacent" and tid ~= 0 then
			-- Upstream sendBoatAttack commits troops/5 capped by troopSendCap
			-- (:1039-1045). launchBoat fixes the amount internally, so a cap
			-- can only be honoured by refusing outright.
			local boatTroops = p.troops / Config.BOAT_TROOP_DIVISOR
			if isAttackTooWeak(boatTroops, tid) then
				return false
			end
			if boatTroops > troopSendCap() then
				return false
			end
			return (Sim.launchBoat(self, p.id, targetTile))
		end
		return false
	end

	-- Upstream attackWithRandomBoat (:113-161): a random shore tile of ours,
	-- then up to 500 random probes across a 300x300 box (:163-229) looking
	-- first for UNOWNED or BOT-owned land and only then for any non-friendly
	-- owner, skipping anyone we already share a land border with and, in FFA,
	-- anyone stronger than us. We cannot afford 500 map probes, and launchBoat
	-- already does the beach-finding, embarkation and sea route -- most of what
	-- that loop approximates. So the DESTINATION is chosen from the player list
	-- and upstream's three probe filters are applied to the player instead,
	-- which is what they were really filtering for.
	local function tryBoat(chance: number): boolean
		if rng:NextNumber() >= chance then
			return false
		end
		if (self.boatBudget or 0) <= 0 then
			return false
		end
		local high = {}
		local low = {}
		for _, id in self.playerOrder do
			local other = self.players[id]
			if
				other
				and other.alive
				and other.spawned
				and id ~= p.id
				and not Sim.sameTeam(self, p.id, id)
				and tileByRival[id] == nil
				and (not ffa or other.troops < p.troops)
			then
				-- findRandomBoatTarget :207-209: the high-interest pass wants
				-- unowned land or land owned by PlayerType.Bot -- the filler
				-- tier, not every AI.
				if Config.TIER[other.tier].BOAT_PREY then
					table.insert(high, id)
				else
					table.insert(low, id)
				end
			end
		end
		local poolIds = high
		if #poolIds == 0 then
			poolIds = low
		end
		if #poolIds == 0 then
			return false
		end
		local chosen = poolIds[rng:NextInteger(1, #poolIds)]
		local other = self.players[chosen]
		local t = other and next(other.border) or nil
		if t == nil then
			return false
		end
		if isAttackTooWeak(p.troops / Config.BOAT_TROOP_DIVISOR, chosen) then
			return false
		end
		return (Sim.launchBoat(self, p.id, t))
	end

	-- Upstream findNearestIslandEnemy (:610-687): non-friendly players that in
	-- FFA have fewer troops than us, sorted by manhattan distance between
	-- territory centres, keep the first two a transport can reach, and take
	-- the second 1 time in 3. Conquest maintains p.sumX/p.sumY, so the centre
	-- is O(1) and the sort is faithful; reachability is not testable without
	-- launching, so the two candidates are simply tried in order.
	local function islandAttack(): boolean
		if (self.boatBudget or 0) <= 0 or p.tileCount <= 0 then
			return false
		end
		local cx = p.sumX / p.tileCount
		local cy = p.sumY / p.tileCount
		local cands = {}
		for _, id in self.playerOrder do
			local other = self.players[id]
			if
				other
				and other.alive
				and other.spawned
				and id ~= p.id
				and other.tileCount > 0
				and not Sim.sameTeam(self, p.id, id)
				and (not ffa or other.troops < p.troops)
			then
				local ox = other.sumX / other.tileCount
				local oy = other.sumY / other.tileCount
				table.insert(cands, { id = id, d = math.abs(ox - cx) + math.abs(oy - cy) })
			end
		end
		if #cands == 0 then
			return false
		end
		table.sort(cands, function(a, b)
			if a.d == b.d then
				return a.id < b.id
			end
			return a.d < b.d
		end)
		local order = { 1, 2 }
		if #cands >= 2 and rng:NextNumber() < Config.BOT_ISLAND_SECOND_CHANCE then
			order = { 2, 1 }
		end
		for _, idx in order do
			local entry = cands[idx]
			if entry ~= nil then
				local other = self.players[entry.id]
				local t = other and next(other.border) or nil
				if t ~= nil and not isAttackTooWeak(p.troops / Config.BOAT_TROOP_DIVISOR, entry.id) then
					if (Sim.launchBoat(self, p.id, t)) then
						return true
					end
				end
			end
		end
		return false
	end

	-- ======================================================================
	-- maybeAttack, in upstream's order (:53-111)
	-- ======================================================================

	-- ---- 0. the first think ------------------------------------------------
	-- NationExecution.ts:175-179 -> AiAttackBehavior.forceSendAttack
	-- (:750-758): once its behaviours exist, a nation's first act is to commit
	-- exactly HALF its army at unclaimed ground -- force, bypassing
	-- shouldAttack and the reserve maths entirely. This game had no first-think
	-- case at all, so an AI's opening was an ordinary gated expand.
	if myTier.SEED_ATTACK and p.aiSeeded ~= true then
		p.aiSeeded = true
		if neutralTile ~= nil then
			Sim.launchAttack(self, p.id, neutralTile, 0, p.troops / 2)
			return
		end
	end

	-- ---- 1. Terra Nullius, first and UNLATCHED -----------------------------
	-- Upstream :89-95 attacks unclaimed ground before considering anything
	-- else and re-tests it on EVERY think. The permanent latch an earlier
	-- build carried belongs to the weak TRIBE class (TribeExecution.ts:12,
	-- :115-121), and with a SAMPLED border it was actively wrong: one unlucky
	-- window that missed the last sliver of open ground permanently converted
	-- an empire from an expander into a combatant. Sampling can only produce
	-- FALSE NEGATIVES here -- a neutral tile that was found is genuinely
	-- neutral -- so no hysteresis is needed.
	if neutralTile ~= nil then
		if commit(neutralTile, false) then
			return
		end
	end

	-- ---- 2. boats ----------------------------------------------------------
	if rivalCount == 0 then
		-- Upstream :97-100 -- 1 in 5, and NO return: an AI with no land enemy
		-- falls through to attackBestTarget, where `island` is its only move.
		tryBoat(Config.BOT_BOAT_CHANCE_ISOLATED)
	else
		-- Upstream :101-105 -- 1 in 10, and it DOES return.
		if tryBoat(Config.BOT_BOAT_CHANCE) then
			return
		end
		-- Upstream :107 then offers alliances to those same enemies.
		-- REQUIRES SYSTEM: alliances. Omitted, not faked.
	end

	-- ---- 3. attackBestTarget (:232-258) ------------------------------------

	-- attackBots (:431-467) behind hasNeighboringBotWithStructures
	-- (:381-391), and it runs BEFORE the reserve and trigger gates (:239-241):
	-- a tribe that has captured your buildings is about to raze them, so it is
	-- worth breaking the saving-up rule for.
	--
	-- COST. Each commit that opens a NEW front is a full border walk in
	-- seedFrontier, and a late-game border runs to tens of thousands of tiles.
	-- It is bounded three ways: it only fires when a bordering tribe actually
	-- holds a structure, TRIBE_PARALLEL caps the targets (Medium is 1 or 2,
	-- :474-475), and MAX_FRONTS_PER_PLAYER = 3 is the hard ceiling underneath.
	-- Inert on TIER_LEGACY, whose TRIBE_PARALLEL is 0, so not one random number
	-- is drawn here.
	if myTier.TRIBE_PARALLEL > 0 then
		local prey = {}
		for id, t in tileByRival do
			local o = self.players[id]
			if o ~= nil and o.alive and o.tier == Config.TIER_TRIBE
				and o.tileCount > 0 and not Sim.sameTeam(self, p.id, id)
			then
				-- :447-457 -- structure owners first, then ASCENDING DENSITY.
				table.insert(prey, {
					id = id,
					tile = t,
					s = ((o.cityCount + o.portCount + o.factoryCount) > 0) and 0 or 1,
					d = o.troops / o.tileCount,
				})
			end
		end
		table.sort(prey, function(a, b)
			if a.s ~= b.s then
				return a.s < b.s
			end
			if a.d == b.d then
				return a.id < b.id
			end
			return a.d < b.d
		end)
		if prey[1] ~= nil and prey[1].s == 0 then
			local n = myTier.TRIBE_PARALLEL
			if n > 1 and rng:NextNumber() < 0.5 then
				n = 1
			end
			local sent = 0
			for i = 1, math.min(n, #prey) do
				local o = self.players[prey[i].id]
				if o ~= nil then
					-- calculateBotAttackTroops (:1053-1072): commit 4x the
					-- target's army out of whatever sits above the EXPAND
					-- reserve, and skip outright if what is left is under 2x --
					-- a half-sized bite only feeds them.
					local avail = p.troops - poolMax * expandReserve - sent
					local want = o.troops * 4
					if want > avail then
						want = (avail >= o.troops * 2) and avail or 0
					end
					if want >= 1 and commit(prey[i].tile, true, want) then
						sent += want
					end
				end
			end
			if sent > 0 then
				return
			end
		end
	end

	-- Reserve gate (:243-244, hasReserveRatioTroops :393-397).
	if p.troops < poolMax * warReserve then
		return
	end
	-- Trigger gate with upstream's 1-in-10 bypass, so a stalemated border is
	-- never perfectly quiet (:246-247, hasTriggerRatioTroops :399-403).
	if p.troops < poolMax * triggerLevel and rng:NextNumber() > Config.BOT_TRIGGER_BYPASS_CHANCE then
		return
	end

	-- retaliate. Upstream :267-273 with findIncomingAttackPlayer (:405-426):
	-- whoever has the LARGEST army pointed at us, and sendAttack(attacker,
	-- TRUE) -- retaliation bypasses shouldAttack entirely. Upstream also drops
	-- attacks FROM Bots when the defender is not itself a Bot (:409-414);
	-- omitted, because that filter needs the two-class distinction and with
	-- one class it would make an AI ignore every attacker in the game.
	-- A nation ignores tribe pokes when choosing whom to hit back at; a tribe
	-- keeps the unfiltered choice. Identical on TIER_LEGACY, where no tribe
	-- exists and the two trackers agree.
	if p.tier ~= Config.TIER_TRIBE then
		biggestAttacker = biggestPeerAttacker
	end
	if Config.BOT_RETALIATE and biggestAttacker ~= 0 then
		local t = tileByRival[biggestAttacker]
		if t == nil then
			local e = self.players[biggestAttacker]
			t = e and next(e.border) or nil
		end
		if t ~= nil and commit(t, true) then
			return
		end
	end

	-- Upstream sorts borderingPlayers ASCENDING BY ABSOLUTE TROOPS (:79-81)
	-- and every strategy takes the FIRST match, so "first match" always means
	-- "weakest". Its tie-break is border-discovery order (:58-59), which a
	-- hash map cannot reproduce; player id is the deterministic stand-in.
	local ranked = {}
	for id, t in tileByRival do
		local other = self.players[id]
		if other and other.alive and not Sim.sameTeam(self, p.id, id) then
			table.insert(ranked, { id = id, tile = t, troops = other.troops })
		end
	end
	table.sort(ranked, function(a, b)
		if a.troops == b.troops then
			return a.id < b.id
		end
		return a.troops < b.troops
	end)

	if hardTier then
		-- veryWeak (:329-335, findVeryWeakEnemy :597-608): under 15% of their
		-- OWN maxTroops, and in FFA not much stronger than us -- the point is
		-- to finish players somebody else has already broken.
		for _, entry in ranked do
			local other = self.players[entry.id]
			if other ~= nil then
				local otherMax = maxTroops(other)
				if
					other.troops < otherMax * Config.BOT_VERY_WEAK_RATIO
					and (not ffa or other.troops < p.troops * Config.BOT_FFA_STRENGTH_MARGIN)
				then
					if commit(entry.tile, false) then
						return
					end
				end
			end
		end

		-- victim (:310-316, findVictim :578-593): somebody already absorbing
		-- incoming attacks worth more than half their army.
		for _, entry in ranked do
			local other = self.players[entry.id]
			if other ~= nil and (not ffa or other.troops <= p.troops * Config.BOT_FFA_STRENGTH_MARGIN) then
				local pressure = pressureOn[entry.id] or 0
				if pressure > other.troops * Config.BOT_VICTIM_PRESSURE_RATIO then
					if commit(entry.tile, false) then
						return
					end
				end
			end
		end
	end

	-- weakest (:337-347): the FIRST entry of the ascending list and nothing
	-- else -- if that one attack is refused, the think is over. In FFA it is
	-- skipped when they hold more troops than we do.
	local best = ranked[1]
	if best ~= nil then
		local other = self.players[best.id]
		if other ~= nil and (not ffa or other.troops < p.troops) then
			if commit(best.tile, false) then
				return
			end
		end
	end

	-- island (:349-357): only when there is no land enemy at all.
	if rivalCount == 0 then
		if islandAttack() then
			return
		end
	end

	-- donate (:359, donateTroops :1074-1172). REQUIRES SYSTEM: troop donation
	-- between teammates. Omitted.
end

-- ==================================================================== tick ==

-- Marks the pending ownership changes as sent. Call this only after the delta
-- has actually gone out on the wire.
function Sim.drainChanges(self: Sim)
	self.changeCount = 0
end

-- The share of playable land that ends the round, and its overtime decay.
-- Both endpoints come from the MODE, not from Config: a lone empire and a
-- six-strong bloc do not start from remotely the same baseline, so one pair
-- of numbers cannot serve both.
function Sim.winThreshold(self: Sim): number
	-- Upstream Config.percentageTilesOwnedToWin(elapsedGameSeconds)
	-- (src/core/configuration/Config.ts:713-732). Base 80% free-for-all /
	-- 95% team; the bar falls in WHOLE POINTS, one step every
	-- 60 / dropPercentPerMinute seconds, from startMinutes onward, floored at
	-- ZERO. There is no per-mode floor upstream, and that is precisely why a
	-- stalled game is guaranteed to end -- a floor above an even split is the
	-- one thing that can make a round unwinnable.
	local base = if self.teamCount > 0 then Config.WIN_PERCENT_TEAM else Config.WIN_PERCENT_FFA
	if not Config.OVERTIME_ENABLED then
		return base
	end
	-- Whole seconds only, like upstream: the bar is an integer percentage.
	local past = math.floor(self.tick * Config.TICK_DT) - Config.OVERTIME_START_MINUTES * 60
	if past <= 0 then
		return base
	end
	local points = math.floor(past * (Config.OVERTIME_DROP_PER_MINUTE * 100) / 60)
	return math.max(0, base - points / 100)
end

local function checkElimination(self: Sim)
	for _, id in self.playerOrder do
		local p = self.players[id]
		if p and p.alive and p.spawned and p.tileCount <= 0 then
			p.alive = false
			p.troops = 0
			-- Nobody claimed this one, so nobody inherits the treasury. The
			-- reference does the same in PlayerExecution: a player with no
			-- tiles has their gold removed outright.
			p.gold = 0
			table.clear(p.border)
			p.borderCount = 0
			Sim.cancelAttacks(self, id)
		end
	end
end

function Sim.step(self: Sim)
	self.tick += 1
	self.phaseTick += 1
	-- NOTE: changeCount is deliberately NOT reset here. Ownership also changes
	-- between ticks -- a player choosing their spawn runs from the intent
	-- handler -- and clearing at the top of the tick threw those tiles away
	-- before they were ever broadcast, so a player's starting territory never
	-- appeared on any client. The transport clears it after sending instead
	-- (see Sim.drainChanges).

	if self.phase == "spawn" then
		if self.phaseTick >= Config.SPAWN_PHASE_SECONDS * Config.TICK_RATE then
			-- Anyone who never picked gets placed, then bots fill the map.
			for _, id in self.playerOrder do
				local p = self.players[id]
				if p and not p.spawned then
					Sim.autoSpawn(self, p)
				end
			end
			self.phase = "playing"
			self.phaseTick = 0
		end
		return
	end

	if self.phase ~= "playing" then
		return
	end

	-- Income. Troops and gold are collected in the same pass the reference
	-- collects them in (`PlayerExecution.tick`: troopIncreaseRate then
	-- goldAdditionRate), and gold is FLAT -- see the economy block in Config
	-- for why it is deliberately not scaled by territory.
	for _, id in self.playerOrder do
		local p = self.players[id]
		if p and p.alive and p.spawned then
			-- Upstream halves a BOT's income (`goldAdditionRate`: 50n vs
			-- 100n, src/core/configuration/Config.ts:982-991). An earlier
			-- build of this file paid everyone the same, which quietly handed
			-- the AI roster the same treasury a person has.
			local tier = Config.TIER[p.tier]
			p.gold += tier.GOLD_PER_TICK * (Config.GOLD_MULTIPLIER or 1)
			local max = maxTroops(p)
			-- An army ABOVE its ceiling snaps back to it. Upstream gets this
			-- for free: troopIncreaseRate returns `min(troops + toAdd, max) -
			-- troops`, which is NEGATIVE when troops > max, and addTroops
			-- routes negatives into removeTroops (PlayerImpl.ts:1263-1268).
			-- Gating growth behind `troops < max` silently dropped that half,
			-- leaving an illegal army in place forever -- and a city level is
			-- a flat +CITY_TROOP_INCREASE of ceiling, so it was bankable:
			-- build cities, bank the ceiling, lose the cities, keep the men.
			if p.troops > max then
				p.troops = max
			elseif p.troops < max then
				local growth = (Config.GROWTH_BASE + (p.troops ^ Config.GROWTH_EXPONENT) / Config.GROWTH_DIVISOR)
					* (1 - p.troops / max)
				-- Per-map pacing. Income is the ONE lever that changes how long a
				-- match runs without changing how a battle feels: every combat
				-- constant is untouched, armies simply arrive sooner or later.
				-- Defaults to 1 when unset, so a Sim built the old way is
				-- bit-for-bit what it was.
				growth *= tier.GROWTH_SCALE * (self.incomePace or 1)
				p.troops = math.min(max, p.troops + growth)
			end
		end
	end

	-- One route search per tick across the whole server; see Config.
	self.boatBudget = Config.BOAT_LAUNCHES_PER_TICK
	-- And an allowance of FINE water routes -- the tile-level channel between
	-- two coarse waypoints, which is what keeps a hull in the river instead of
	-- on the bank. A leg lasts a boat three ticks, so this is a ceiling on how
	-- many boats may be rounding a corner at once, not a per-boat rate. Over
	-- budget, a boat steers straight for a tick exactly as it always did.
	self.channelBudget = Config.BOAT_CHANNEL_PER_TICK or 8

	-- Attacks.
	local globalBudget = self.tileBudget
	for _, atk in self.attacks do
		if atk.active then
			globalBudget = Sim.processAttack(self, atk, globalBudget)
			if globalBudget <= 0 then
				break
			end
		end
	end

	-- Compact the attack list.
	local live = {}
	for _, atk in self.attacks do
		if atk.active then
			table.insert(live, atk)
		end
	end
	self.attacks = live

	stepBoats(self)
	stepCollapses(self)
	-- Territory-bound units settle with the ground BEFORE anything reads them:
	-- Economy.step's trade and rail passes both go by structure ownership, and
	-- a construction site finishing this tick has to know whose it is.
	-- Upstream's equivalent is the head of PlayerExecution.tick (:45-67).
	Units.stepCapture(self)
	Economy.step(self)
	-- Silos reload, launchers fire, missiles fly. After Economy so a silo that
	-- finished building this tick is fireable next tick, and before
	-- checkElimination so a strike that empties a player is seen the same tick.
	Nukes.step(self)
	-- After Economy.step so a warship reads THIS tick's trade-ship positions,
	-- and after stepCapture so a port that just changed hands produces for
	-- whoever holds it now.
	Warships.step(self)
	checkElimination(self)

	-- Bots.
	for _, id in self.playerOrder do
		local p = self.players[id]
		if p and p.isBot and p.alive then
			local rate = p.aiThink or Config.BOT_THINK_TICKS
			local offset = (self.tick + p.thinkOffset) % rate
			if offset == 0 then
				Sim.botThink(self, p)
				Warships.botThink(self, p)
				-- NationNukeBehavior / NationMIRVBehavior run on the attack beat.
				if Config.TIER[p.tier].BUILDS then
					Nukes.aiThink(self, p)
				end
			elseif p.spawned and Config.TIER[p.tier].BUILD_SUBTICKS then
				-- NationExecution.ts:181-197 runs handleStructures TWICE MORE
				-- between attack beats, at 1/3 and 2/3 of the interval, and
				-- says why: "Otherwise it is possible that we earn more gold
				-- than we can spend". It matters at the nation tier because
				-- that tier doubles gold income (Config.ts:987-988).
				--
				-- COST: one extra modulo per bot per tick, and botBuild itself
				-- returns on a gold check long before it probes anything, so
				-- this is free until a bot can actually afford a building.
				-- Off on TIER_LEGACY, which called botBuild once a think -- and
				-- botBuild rolls BOT_BUILD_CHANCE on every call, so switching
				-- it on is not a neutral change.
				local third = rate // 3
				if offset == third or offset == third * 2 then
					botBuild(self, p)
				end
			end
		end
	end

	-- Win check.
	if self.tick % 10 == 0 then
		local elapsed = self.tick * Config.TICK_DT
		local threshold = Sim.winThreshold(self)
		local timeUp = elapsed >= Config.HARD_TIME_LIMIT_SECONDS

		if self.teamCount > 0 then
			local stats = Sim.teamStats(self) :: { any }
			local bestT, bestTiles = nil, -1
			local liveTeams, lastLive = 0, nil
			for t = 1, self.teamCount do
				local s = stats[t]
				if s.tiles > bestTiles then
					bestTiles = s.tiles
					bestT = t
				end
				if s.alive > 0 then
					liveTeams += 1
					lastLive = t
				end
			end

			if
				bestT
				-- Strict > , as upstream (WinCheckExecution.ts:109-115). The
				-- denominator is upstream's numLandTiles - numTilesWithFallout;
				-- playableLand is the exact analogue only while Conquest has no
				-- fallout, so revisit this if DoomsdayClock rot is ever enabled.
				and (bestTiles / Nukes.contestableLand(self) > threshold or liveTeams <= 1 or timeUp)
			then
				-- A wipeout is decided by who is still standing, not by whoever
				-- happens to hold the most land at that instant.
				local winTeam = (liveTeams <= 1 and lastLive) or bestT
				self.winnerTeam = winTeam
				local topId, topTiles = nil, -1
				for _, id in self.playerOrder do
					local p = self.players[id]
					if p and p.alive and self.teamOf[id] == winTeam and p.tileCount > topTiles then
						topTiles = p.tileCount
						topId = id
					end
				end
				self.winnerId = topId
				self.phase = "ended"
			end
			return
		end

		local bestId, bestTiles = nil, 0
		for _, id in self.playerOrder do
			local p = self.players[id]
			if p and p.alive and p.tileCount > bestTiles then
				bestTiles = p.tileCount
				bestId = id
			end
		end

		local aliveCount = 0
		for _, id in self.playerOrder do
			local p = self.players[id]
			if p and p.alive and p.spawned then
				aliveCount += 1
			end
		end

		-- Denominator is numLandTiles - numTilesWithFallout: glassed ground is
		-- out of the contest, so a nuke must not move the finish line toward
		-- whoever is already ahead (WinCheckExecution.ts:165-166).
		if bestId and (bestTiles / Nukes.contestableLand(self) > threshold or aliveCount <= 1 or timeUp) then
			self.winnerId = bestId
			self.phase = "ended"
		end
	end
end

return Sim