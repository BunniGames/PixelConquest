--!strict
-- Conquest :: Sim  (server only)
-- The whole simulation: players, territory, attacks, AI, win condition.
--
-- Runs at Config.TICK_RATE on the server, which is authoritative. Clients
-- receive only owner deltas; they regenerate terrain from the seed themselves.

local Config = require(script.Parent.Config)
local Heap = require(script.Parent.Heap)
local MapGen = require(script.Parent.MapGen)
local Maps = require(script.Parent.Maps)
local Modes = require(script.Parent.Modes)
local TileMap = require(script.Parent.TileMap)

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
	-- Bot AI phase state. `boxedScans` counts consecutive border samples that
	-- turned up no open ground, which is the hysteresis on the land-grab ->
	-- war switch; `warReadyTick` is the earliest tick this bot may declare on
	-- a neighbour again.
	boxedScans: number,
	warReadyTick: number,
	-- Where the last border scan stopped, so the next one resumes instead of
	-- walking the set from the front to reach a fresh window.
	scanCursor: number?,
	killedBy: number?,
}

export type Attack = {
	attackerId: number,
	targetId: number,
	troops: number,
	frontier: Heap.Heap,
	-- Distinct tiles currently on the front. Tracked separately from the heap
	-- because the heap deliberately holds duplicates (lazy decrease-key).
	borderSet: { [number]: true },
	borderCount: number,
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
		-- Absolute tile count at which a broken empire is absorbed whole.
		collapseTiles = math.max(
			Config.COLLAPSE_MIN_TILES,
			math.floor(math.max(playable, 1) * Config.COLLAPSE_FRACTION)
		),

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
	}, Sim)

	Sim.assignTeamAnchors(self)

	return self
end

-- ================================================================ players ==

function Sim.addPlayer(self: Sim, name: string, isBot: boolean, userId: number?): Player?
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
		tileCount = 0,
		border = {},
		borderCount = 0,
		alive = true,
		spawned = false,
		spawnTile = nil,
		thinkOffset = id * 3,
		boxedScans = 0,
		warReadyTick = 0,
		scanCursor = nil,
		killedBy = nil,
	}
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

-- One anchor per team, placed far apart, used to group that team's spawns.
-- Greedy farthest-point over a random sample: exact maximisation is not worth
-- the work when the candidate list is tens of thousands of tiles and the
-- result only has to be "clearly a different part of the map".
function Sim.assignTeamAnchors(self: Sim)
	table.clear(self.teamAnchors)
	if self.teamCount <= 0 then
		return
	end
	local candidates = self.candidates
	if #candidates == 0 then
		return
	end

	self.teamAnchors[1] = candidates[self.rng:NextInteger(1, #candidates)]
	for t = 2, self.teamCount do
		local best, bestD = nil, -1
		for _ = 1, 400 do
			local c = candidates[self.rng:NextInteger(1, #candidates)]
			local cx, cy = c % W, (c - c % W) / W
			local minD = math.huge
			for k = 1, t - 1 do
				local a = self.teamAnchors[k]
				local ax, ay = a % W, (a - a % W) / W
				local dx, dy = cx - ax, cy - ay
				local d = dx * dx + dy * dy
				if d < minD then
					minD = d
				end
			end
			if minD > bestD then
				bestD = minD
				best = c
			end
		end
		self.teamAnchors[t] = best
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

	if old ~= 0 then
		local p = self.players[old]
		if p then
			p.tileCount -= 1
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
		end
	end

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
	local minD2 = Config.MIN_SPAWN_DISTANCE * Config.MIN_SPAWN_DISTANCE
	for _, id in self.playerOrder do
		local other = self.players[id]
		if other and other.spawnTile then
			local ot = other.spawnTile
			local ox, oy = ot % W, (ot - ot % W) / W
			local dx, dy = tx - ox, ty - oy
			if dx * dx + dy * dy < minD2 then
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
	p.troops = p.isBot and Config.BOT_SPAWN_TROOPS or Config.SPAWN_TROOPS

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
			if Sim.isValidSpawn(self, tile) then
				local tx, ty = tile % W, (tile - tile % W) / W
				local dx, dy = tx - ax, ty - ay
				-- Jittered, so members ring the anchor instead of every one of
				-- them stacking on the single closest legal tile.
				local score = (dx * dx + dy * dy) * (0.7 + self.rng:NextNumber() * 0.6)
				if score < bestScore then
					bestScore = score
					best = tile
				end
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
			p.troops = p.isBot and Config.BOT_SPAWN_TROOPS or Config.SPAWN_TROOPS
			Sim.conquer(self, tile, p.id)
			return
		end
	end
end

-- ================================================================ attacks ==

local function maxTroops(p: Player): number
	return Config.MAX_TROOPS_MULT
		* ((p.tileCount ^ Config.TROOPS_TILE_EXPONENT) * Config.TROOPS_PER_TILE_COEF
			+ Config.BASE_MAX_TROOPS)
end

Sim.maxTroops = maxTroops

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
		if self.tick + span * floorBase >= best then
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
	-- A ready TIME, not a score.
	local priority = self.tick + span * base

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
	atk.sumX = 0
	atk.sumY = 0
end

-- Returns ok, and a REASON CODE when it refuses. The reason exists so that a
-- tap on enemy land that cannot become an attack can say why: refusing
-- silently is indistinguishable from the tap never having registered, which
-- is the most confusing thing this game can do to someone holding a phone.
function Sim.launchAttack(self: Sim, playerId: number, targetTile: number, ratio: number): (boolean, string?)
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

	ratio = math.clamp(ratio, Config.MIN_ATTACK_RATIO, Config.MAX_ATTACK_RATIO)
	local committed = math.floor(attacker.troops * ratio)
	if committed < Config.MIN_ATTACK_TROOPS then
		return false, "troops"
	end

	-- Reinforce an existing push on the same target rather than opening a
	-- second front that would fight for the same frontier tiles.
	for _, atk in self.attacks do
		if atk.active and atk.attackerId == playerId and atk.targetId == targetId then
			attacker.troops -= committed
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

	attacker.troops -= committed

	local atk: Attack = {
		attackerId = playerId,
		targetId = targetId,
		troops = committed,
		frontier = Heap.new(),
		borderSet = {},
		borderCount = 0,
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
			endAttack(self, atk, true, Config.RETREAT_PENALTY)
		end
	end
end

-- Every army currently in the field, for the number the client draws on
-- the front it is fighting on. These troops were taken out of their
-- nation's own pool by launchAttack and are NOT in p.troops, so the
-- garrison number on the territory and the army number on the border
-- never double-count -- an empire that sends half its men away visibly
-- halves at home, which is the whole point of committing them.
--
-- Position is the centroid of the attack's live front, maintained
-- incrementally; `n` is the width of that front, which is what the
-- client sizes the label from.
function Sim.armies(self: Sim): { any }
	local out = {}
	for _, atk in self.attacks do
		if atk.active and atk.borderCount > 0 and atk.troops >= 1 then
			table.insert(out, {
				a = atk.id,
				id = atk.attackerId,
				t = atk.targetId,
				troops = math.floor(atk.troops),
				x = atk.sumX / atk.borderCount,
				y = atk.sumY / atk.borderCount,
				n = atk.borderCount,
			})
		end
	end
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
local function tilesPerTick(self: Sim, atk: Attack, defender: Player?): number
	local border = atk.borderCount + self.rng:NextInteger(0, 5)
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
	speedPenalty: number
): (number, number, number)
	local tType = TileMap.terrainType(self.map, tile)
	local mag = Config.TERRAIN_MAG[tType] or Config.TERRAIN_MAG[1]
	local speed = Config.TERRAIN_SPEED[tType] or Config.TERRAIN_SPEED[1]

	if defender == nil then
		local div = attacker.isBot and Config.NEUTRAL_LOSS_DIVISOR_BOT
			or Config.NEUTRAL_LOSS_DIVISOR
		return mag / div, 0, math.clamp(
			Config.NEUTRAL_TILE_NUM * math.max(10, speed) / math.max(atk.troops, 1),
			Config.NEUTRAL_TILE_MIN,
			Config.NEUTRAL_TILE_MAX
		)
	end

	local density = defender.troops / math.max(defender.tileCount, 1)
	local ratioTerm = math.clamp(
		defender.troops / math.max(atk.troops, 1),
		Config.ATTACK_RATIO_MIN,
		Config.ATTACK_RATIO_MAX
	)

	local pressure = ratioTerm * mag * Config.ATTACK_MAG_SCALE * sizeDebuff * lossPenalty
	local densityLoss = Config.ATTACK_ALT_COEF * density * (mag / 100)
	local blend = Config.ATTACK_LOSS_BLEND
	local attackerLoss = blend * pressure + (1 - blend) * densityLoss

	local cost = math.clamp(
		defender.troops / (Config.SPEED_RATIO_DIV * math.max(atk.troops, 1)),
		Config.SPEED_RATIO_MIN,
		Config.SPEED_RATIO_MAX
	) * speed * sizeDebuff * speedPenalty

	return attackerLoss, density, cost
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
	local budget = tilesPerTick(self, atk, defender)
	local map = self.map
	local owner = map.owner
	local nbuf = self.nbuf

	-- Hoisted out of the per-tile loop -- see attackLogic.
	local sizeDebuff, lossPenalty, speedPenalty = 1, 1, 1
	if defender then
		local floor = Config.DEFENSE_DEBUFF_FLOOR
		sizeDebuff = floor
			+ (1 - floor)
				* (1 - sigmoid(
					defender.tileCount,
					LN2 / Config.DEFENSE_DEBUFF_HALFLIFE,
					Config.DEFENSE_DEBUFF_MIDPOINT
				))
		if attacker.tileCount > Config.LARGE_ATTACKER_TILES then
			local r = Config.LARGE_ATTACKER_TILES / attacker.tileCount
			lossPenalty = r ^ Config.LARGE_ATTACKER_LOSS_EXP
			speedPenalty = r ^ Config.LARGE_ATTACKER_SPEED_EXP
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

		local tile = Heap.pop(atk.frontier)
		if tile == nil then
			-- Nothing left adjacent: the push is spent, survivors go home.
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
			attackLogic(self, atk, attacker, defender, tile, sizeDebuff, lossPenalty, speedPenalty)

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

		if defender and defender.tileCount <= self.collapseTiles then
			collapsePlayer(self, defender, atk.attackerId)
			endAttack(self, atk, true, 0)
			break
		end
	end

	return globalBudget
end

-- ================================================================== bot AI ==

-- Bots run in two phases, and the switch between them IS the behaviour:
--
--   1. LAND GRAB -- while any unclaimed tile still touches the empire, take
--      it, and consider nothing else. Open ground is far cheaper than a war
--      (bots pay half of an already-small NEUTRAL_LOSS_DIVISOR for it), so a
--      bot that stops to fight a neighbour while the map is still open has
--      thrown the round away. Expansion re-commits on EVERY think --
--      launchAttack merges into the running push rather than opening a second
--      front -- so a bot keeps feeding troops into empty country for as long
--      as there is any left to take.
--   2. BOXED IN -- its whole frontier is other empires. Now it stockpiles to
--      a much higher share of its pool and then only occasionally commits,
--      one war at a time, against someone it is already sitting beside.
--
-- The border scan is a sample, so the switch is guarded by BOT_BOXED_CONFIRMS
-- consecutive empty looks: one unlucky sample that misses the last sliver of
-- open ground must not start a war.
function Sim.botThink(self: Sim, p: Player)
	if not p.spawned or not p.alive then
		return
	end

	-- Don't stack a third front; bots commit to at most two pushes.
	local ongoing = 0
	for _, atk in self.attacks do
		if atk.active and atk.attackerId == p.id then
			ongoing += 1
		end
	end
	if ongoing >= Config.BOT_MAX_FRONTS then
		return
	end

	local map = self.map
	local owner = map.owner
	local nbuf = self.nbuf

	-- Sample the border rather than walking all of it: a large empire's
	-- border is tens of thousands of tiles and this runs every few ticks.
	-- Counting it first is one cheap `next` walk with no per-tile work, and it
	-- buys a RANDOM window into the set: starting at the front every time
	-- would show a bot the same few hundred tiles of its own frontier forever,
	-- and a boxed-in empire's border hardly changes.
	local sample = Config.BOT_BORDER_SAMPLE

	local neutralTile: number? = nil
	-- One touching tile per rival, so a war already under way can be fed
	-- without re-scanning for its front specifically.
	local tileByRival: { [number]: number } = {}
	local bestPlayerTile: number? = nil
	local bestScore = -math.huge
	local scanned = 0

	-- Resume where the last think stopped rather than skipping forward from
	-- the front of the set: `next` from a stored key is O(1), while walking
	-- `skip` entries to reach a random window was the most expensive thing
	-- the AI did -- an empire with a 20k-tile border paid ten thousand
	-- iterations before it read its first tile, and that was 6.4 ms a tick
	-- across the roster. Successive thinks still sweep the whole frontier,
	-- they just do it in order instead of by lottery. Nothing in this loop
	-- mutates p.border, which is what makes resuming from a key safe.
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
					-- Open ground ends the scan outright: phase 1 takes it and
					-- never consults the rivals, so there is nothing left to
					-- look for. The cursor walks this around the frontier
					-- think by think, which is what spreads the pushes.
					neutralTile = nb
					break
				elseif o ~= p.id then
					-- Remember ONE touching tile per rival, and nothing else.
					-- The score depends on the rival, not on which of their
					-- tiles the scan happened to brush, so doing it here meant
					-- a Random call and a team lookup for every neighbour of
					-- every sampled border tile -- thousands of engine calls
					-- per think, which was most of what the AI cost.
					tileByRival[o] = nb
				end
			end
		end
		if neutralTile ~= nil then
			break
		end

		tile = next(p.border, tile)
		if tile == nil then
			-- Wrapped past the end of the set; the sample cap above is what
			-- stops this from spinning on a small border.
			tile = next(p.border)
		end
	end
	p.scanCursor = tile

	-- ---- phase 1: there is still open ground, so take it -------------------
	if neutralTile then
		p.boxedScans = 0
		if p.troops >= maxTroops(p) * Config.BOT_EXPAND_RESERVE_RATIO then
			Sim.launchAttack(self, p.id, neutralTile, Config.BOT_EXPAND_ATTACK_RATIO)
		end
		return
	end

	-- ---- already at war: keep feeding it -----------------------------------
	-- Declaring is the occasional part; sustaining is not. A push that is not
	-- reinforced peters out long before it breaks anyone, because the
	-- defender regrows what it lost while the attacker's committed army is
	-- spent on ground. So a bot that has picked its fight pours income into
	-- that same target until the war is over.
	for _, atk in self.attacks do
		if atk.active and atk.attackerId == p.id and atk.targetId ~= 0 then
			local tile = tileByRival[atk.targetId]
			if tile and p.troops >= maxTroops(p) * Config.BOT_WAR_SUSTAIN_RATIO then
				Sim.launchAttack(self, p.id, tile, Config.BOT_ATTACK_RATIO)
			end
			return
		end
	end

	-- Score the rivals we are touching, ONCE each. Reached only when there is
	-- no open ground left and no war already running, so it is the rarest of
	-- the three paths and the only one that needs a choice made.
	for id, nb in tileByRival do
		local other = self.players[id]
		if other and other.alive and not Sim.sameTeam(self, p.id, id) then
			-- Pick the WEAKEST neighbour, not the biggest. Scoring by
			-- tileCount made every bot pile onto whoever was ahead, which is
			-- a stable equilibrium: the leader is pinned around 15% and
			-- nobody ever reaches the win threshold. Measured on the US map,
			-- 13 bots -- by size: 30 min, no winner, 11 alive. By weakness:
			-- 15.2 min, 9 dead, winner at 53%. Jittered, or every bot along a
			-- border picks the same victim and keeps picking it.
			local score = (1 / (other.troops + 1)) * (0.75 + self.rng:NextNumber() * 0.5)
			if score > bestScore then
				bestScore = score
				bestPlayerTile = nb
			end
		end
	end

	-- ---- phase 2: boxed in, so occasionally pick on a neighbour ------------
	p.boxedScans += 1
	if p.boxedScans < Config.BOT_BOXED_CONFIRMS or bestPlayerTile == nil then
		return
	end
	-- One war at a time. A stockpile that took a minute to build is wasted if
	-- it is split across two neighbours, and the leftover expansion push has
	-- to have finished before any of this counts as "bordered up" at all.
	if ongoing > 0 or self.tick < p.warReadyTick then
		return
	end
	if p.troops < maxTroops(p) * Config.BOT_WAR_RESERVE_RATIO then
		return
	end
	if self.rng:NextNumber() > Config.BOT_ENGAGE_CHANCE then
		return
	end

	if Sim.launchAttack(self, p.id, bestPlayerTile, Config.BOT_DECLARE_ATTACK_RATIO) then
		p.warReadyTick = self.tick + Config.BOT_WAR_COOLDOWN_TICKS
	end
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
	local def = Modes.get(self.modeId)
	local elapsed = self.tick * Config.TICK_DT
	if elapsed <= Config.OVERTIME_START_SECONDS then
		return def.WIN
	end
	local minutesPast = (elapsed - Config.OVERTIME_START_SECONDS) / 60
	return math.max(def.FLOOR, def.WIN - minutesPast * Config.OVERTIME_DROP_PER_MINUTE)
end

local function checkElimination(self: Sim)
	for _, id in self.playerOrder do
		local p = self.players[id]
		if p and p.alive and p.spawned and p.tileCount <= 0 then
			p.alive = false
			p.troops = 0
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

	-- Income.
	for _, id in self.playerOrder do
		local p = self.players[id]
		if p and p.alive and p.spawned then
			local max = maxTroops(p)
			if p.troops < max then
				local growth = (Config.GROWTH_BASE + (p.troops ^ Config.GROWTH_EXPONENT) / Config.GROWTH_DIVISOR)
					* (1 - p.troops / max)
				if p.isBot then
					growth *= Config.BOT_GROWTH_SCALE
				end
				p.troops = math.min(max, p.troops + growth)
			end
		end
	end

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

	stepCollapses(self)
	checkElimination(self)

	-- Bots.
	for _, id in self.playerOrder do
		local p = self.players[id]
		if p and p.isBot and p.alive then
			if (self.tick + p.thinkOffset) % Config.BOT_THINK_TICKS == 0 then
				Sim.botThink(self, p)
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
				and (bestTiles / self.playableLand >= threshold or liveTeams <= 1 or timeUp)
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

		if bestId and (bestTiles / self.playableLand >= threshold or aliveCount <= 1 or timeUp) then
			self.winnerId = bestId
			self.phase = "ended"
		end
	end
end

return Sim
