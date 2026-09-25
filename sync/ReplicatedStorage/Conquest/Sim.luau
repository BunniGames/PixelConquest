--!strict
-- Conquest :: Sim  (server only)
-- The whole simulation: players, territory, attacks, AI, win condition.
--
-- Runs at Config.TICK_RATE on the server, which is authoritative. Clients
-- receive only owner deltas; they regenerate terrain from the seed themselves.

local Config = require(script.Parent.Config)
-- Structures, ports, trading transport boats, rails and trains. Kept out of this file
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
-- The battery's firing loop (2026-09-21). Requires Alliances, Config, Nukes
-- and Units; nothing that requires Sim.
local Artillery = require(script.Parent.Artillery)
-- The airfield's sorties (2026-09-21). Requires Nukes for the event queue,
-- never Sim -- see its header.
local Airstrikes = require(script.Parent.Airstrikes)
-- The railgun's slugs (2026-09-24), Airstrikes' shape and requires.
local Railgun = require(script.Parent.Railgun)
-- Every structure, boat and warhead as ONE record, with the spatial
-- index, the per-player counters and the once-per-tick territory-capture
-- sweep over them.
local Units = require(script.Parent.Units)
-- DIPLOMACY (2026-09-18). Read in exactly four places: `friendly` (under
-- sameTeam), the two attack refusals, the mid-push retreat and the traitor
-- penalty hoisted in processAttack. Alliances requires Config and TileMap
-- only, so there is no cycle.
local Alliances = require(script.Parent.Alliances)
-- Gunboats, shells, and the piracy verbs applied to Economy's trading transport boats and
-- this file's transports. Gunboats come from PORTS, not from the treasury -- see
-- that module's header; it is a deliberate deviation from upstream.
local Gunboats = require(script.Parent.Gunboats)
-- Predrawn maps for the historical mode: which nation holds every tile at
-- the start, and its buildings. Read only by the historical block below.
local Scenarios = require(script.Parent.Scenarios)

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
	-- Where their dot is standing while the round has not started, and nil the
	-- moment it becomes an empire. Separate from spawnTile because spawnTile is
	-- what the spacing rule reads and has to hold for both -- but only a preview
	-- may be picked up and put down somewhere else.
	spawnPreview: number?,
	-- THE TUTORIAL FOUR, spent into this record by ConquestServer.redeemBoost
	-- and worth nothing anywhere else: they are set only on a tutorial server,
	-- for the student, and they die with the round. See the block over the
	-- TUTORIAL_* entries in Products for why those are the only conditions
	-- under which this game sells any of them.
	--
	-- Optional, like the AI fields above: every empire in an ordinary round
	-- carries none of these, and every site that reads them (the growth loop's
	-- snap, tilesPerTick, Nukes' order and charge) reads them defensively.
	--
	-- `troopOverflow` is not a quantity -- it is permission for the army to
	-- stand above maxTroops, which is what "+1 Million Army Size!" buys. It
	-- clears itself in the growth loop the moment the army is spent back under
	-- the ceiling, so an empire gets exactly one bought overflow.
	troopOverflow: boolean?,
	attackSpeed: number?,
	freeNukes: number?,
	-- Free defence posts in hand -- the twin of freeNukes above, set by a
	-- Starter Pack redeem and spent in Economy.build. Optional for the same
	-- reason every field around it is: a Player built by an older sim has no
	-- such field, and nil arithmetic would take the build path down with it.
	freePosts: number?,
	-- Free cities and free anti-nuke towers in hand -- Starter Pack #2's
	-- buildings (2026-09-17), the same shape as freePosts and spent at the same
	-- line in Economy.build. Optional for the same reason.
	freeCities: number?,
	freeSams: number?,
	-- A SPECIAL MODE'S FLAT CEILING (MEGA ARMY, 2026-09-18: Modes.SPECIAL
	-- troopCapBonus), added to maxTroops outside the tier scale. On the PLAYER
	-- because maxTroops takes a player and no sim; set once, in payOpening,
	-- and nil on every empire of an ordinary round.
	capBonus: number?,
	-- THE TICK THE LAST REINFORCEMENT PURCHASE LANDED ON (2026-09-21). nil
	-- until the first one, which is what lets a fresh empire buy at once, and
	-- read only by Sim.reinforceQuote, which turns it into the
	-- REINFORCE_COOLDOWN countdown the rail button prints. Optional for the
	-- reason every field around it is.
	reinforceTick: number?,
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
	-- Defense posts. Count and levels are the same number -- a post has no
	-- levels, it is not upgradable -- and `defensePostBuilt` is what this empire
	-- has PAID for. Economy.cost reads the pair to price the next one, which is
	-- why they live on the player at all: the server's build reply asks for a
	-- price with a player and no sim.
	defensePostCount: number,
	defensePostLevels: number,
	defensePostBuilt: number,
	-- SAM launchers -- the anti-nuke tower. Same three fields and the same
	-- reason (Economy.cost is called with a PLAYER and no sim), with one
	-- difference from the post: a launcher IS upgradable, so count and levels
	-- are different numbers and the level is what sets its radius.
	samCount: number,
	samLevels: number,
	samBuilt: number,
	-- The two guns (2026-09-21): same three fields, same reason as the post.
	artilleryCount: number,
	artilleryLevels: number,
	artilleryBuilt: number,
	airfieldCount: number,
	airfieldLevels: number,
	airfieldBuilt: number,
	railgunCount: number,
	railgunLevels: number,
	railgunBuilt: number,
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
	-- Who last took ground from this empire, or last landed a warhead on
	-- it. The kill credit for a death with NO conqueror -- see
	-- checkElimination -- and nothing else reads it.
	lastHitBy: number?,
	-- The tile that emptied them, stamped by Sim.conquer the moment their
	-- count reaches zero. By then the centroid is 0/0, so this is the only
	-- record of WHERE they died.
	deathTile: number?,
	-- A PAID INCOME BONUS (2026-09-08): fraction added to troop growth while
	-- this empire wears a boosted pattern. Written by ConquestServer's
	-- applyPattern, cleared when the empire is handed to the AI, nil for every
	-- bot and every empire wearing nothing. See Patterns.boost.
	growthBoost: number?,
	-- The same for gold: fraction added to per-tick gold income while wearing
	-- a pattern that carries one. Written and cleared beside growthBoost.
	goldBoost: number?,
	-- A BOT PRETENDING TO BE A PERSON: one of the phantom seats a lobby card
	-- promised, wearing a real display name (ConquestServer's faux block,
	-- Tutorial.addFaux). Stamped once by addPlayer from its `faux` argument,
	-- nil for every other empire. The income pass reads it and scales a faux
	-- empire's troop growth by Config.FAUX_GROWTH_SCALE; nothing else does.
	faux: boolean?,
	-- AI DOCTRINE (2026-09-21, "make AI spawn airbase and artillery strike
	-- relatively rarely"): rolled ONCE per empire, the first time it could want
	-- the kind, against Config.BOT_ARTILLERY_SHARE / BOT_AIRFIELD_SHARE; nil is
	-- "not rolled yet". Only shouldBuildStructure reads or writes them.
	gunner: boolean?,
	flier: boolean?,
	-- HISTORICAL MODE ONLY (Sim.loadScenario). `nation` is the scenario index
	-- of the country this empire IS -- set on the AI that opens the round
	-- holding it, and handed to the person it is transferred to. `nationPick`
	-- is a person's claim during the spawn phase, nil once it has become a
	-- transfer or was never made.
	nation: number?,
	nationPick: number?,
}

-- A transport transport boat in flight is a Units.TRANSPORT_BOAT. The id, the owner,
-- the tile, the grid cell and the troops aboard are the unit's own fields;
-- the crossing state -- targetId, dst, path, pathIdx, leg -- sits in ext, the
-- same split every other unit type uses. `path` is a list of coarse waypoints
-- from Navy.path and `leg` the fine water route to the current one from
-- Navy.channel; the transport boat walks the leg and advances the waypoint index when it
-- arrives. Troops are OUT of the owner's pool from the moment it
-- sails, exactly as a land attack's are -- so an empire that ships half its
-- army away is visibly weaker at home while the crossing happens, which is
-- the whole risk of an invasion.
--
-- self.transportBoats survives as an ORDERED list beside Units' type index, and that
-- is not redundancy. Two transport boats landing on the same tick spawn two attacks,
-- and attack ids fix the order the global tile budget is handed out in the
-- following tick -- so the order transport boats are stepped in is part of the
-- simulation. Units' lists swap-remove; this one does not.
export type TransportBoat = any

export type Attack = {
	attackerId: number,
	targetId: number,
	troops: number,
	-- Set only for an amphibious landing. A transport boat attack seeds its frontier
	-- from the beachhead alone and never merges with a land push on the same
	-- target -- upstream keys both behaviours off exactly this being non-nil
	-- (`AttackExecution.sourceTile`). Merging one in would teleport the
	-- landing's troops back to the home front the moment it touched down.
	--
	-- A LAND BRIDGE sets it too, to the tile of OURS at the crossing. The
	-- march into the open ground between two empires that do not touch has
	-- exactly the shape of a landing -- one named place to start from, and a
	-- front that must not open back home instead -- so it is the same field
	-- and the same seeding rule. See Sim.landBridge.
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
		transportBoats = {} :: { TransportBoat },
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
		-- Clan tag -> the team its first member landed on. See addPlayer: this
		-- is the whole of "same tag, same side", and it is per-round because a
		-- round is a new Sim.
		teamByTag = {} :: { [string]: number },
		teamSizes = {} :: { [number]: number },
		teamAnchors = {} :: { [number]: number },

		-- THE OPENING (2026-09-18). Flat figures every empire is handed at
		-- spawn (payOpening), all optional and all absent on an ordinary
		-- round: `startTroops` REPLACES the tier's spawn army (troopScale
		-- included), `troopCapBonus` is added to every ceiling (Player.capBonus
		-- -> maxTroops) and `startNukes` lands in freeNukes. `startGold` and
		-- `troopScale` are the two a private room's dials have always set from
		-- ConquestServer. applySpecial writes the new three when the MODE
		-- states them (Modes.SPECIAL); listed here so a reader knows the sim
		-- has them, not because a nil in a constructor does anything.
		startTroops = nil :: number?,
		troopCapBonus = nil :: number?,
		startNukes = nil :: number?,
		-- ...and BLITZ's: every empire's attackSpeed (tilesPerTick), the field
		-- the tutorial's 2x product sets for one student, set here for all.
		startAttackSpeed = nil :: number?,

		-- HISTORICAL MODE (Modes.historical). Nothing here until the server
		-- calls Sim.loadScenario; `historical` alone is decided by the mode,
		-- so the spawn-phase paths below know which shape of round this is
		-- even on a tick before the scenario is loaded.
		historical = Modes.isHistorical(modeId),
		scenario = nil :: any,
		nationMask = nil :: buffer?,
		-- Nation index -> the empire holding it right now (the AI at first,
		-- the person after a transfer).
		nationPlayer = {} :: { [number]: number },
		-- Nation index -> the person who has CLAIMED it this spawn phase. A
		-- claim is exclusive and movable, exactly as a spawn dot is.
		nationTaker = {} :: { [number]: number },

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

		-- ONE EMPIRE NOBODY MAY ATTACK, UNTIL A TICK. This is the tutorial's
		-- grace window and nothing else sets it (ConquestServer, from
		-- Tutorial.GRACE_SECONDS). It is deliberately the same SHAPE as the
		-- spawn immunity a few hundred lines down -- a refusal inside
		-- launchAttack and launchTransportBoat, checked against a tick -- rather
		-- than a condition inside botThink's target choice: the AI reaches the
		-- map through those two functions and no other, so a rule stated here
		-- cannot be walked around by a targeting path that forgot about it.
		-- 0 is the no-player sentinel, as everywhere else in this file.
		protectId = 0,
		protectUntil = 0,

		-- ONE EMPIRE THAT FIGHTS AND EARNS AT A MULTIPLE OF EVERYONE ELSE.
		-- The tutorial's student, and nothing else sets these two fields
		-- (Tutorial.attach, from Tutorial.STUDENT_BUFF). Deliberately the same
		-- SHAPE as the grace above -- a pair of fields read at the point the
		-- rule bites -- for the same reason: an empire's strength is decided
		-- in attackLogic and its income in one loop in `step`, so stating it
		-- at those two points cannot be walked around by a caller that forgot
		-- about it. UNLIKE the grace it does not expire; see Tutorial.
		-- 0 / 1 is "nobody, no tilt", which is every ordinary round.
		buffId = 0,
		buffMult = 1,

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

		-- Who took whose treasury. Filled by collapsePlayer, drained once a
		-- tick by the transport. A handful of entries a MINUTE across the
		-- whole roster, so a plain table costs nothing.
		conquestEvents = {} :: { { captorId: number, victimId: number, gold: number } },

		-- ------------------------------------------------------- structures --
		-- Nothing here. cityAt, cityList, cityCells, sites and cityEvents were
		-- superseded by Economy and then by Units, and every one of them had
		-- been dead for longer than it looked: the live tables are sim.units,
		-- sim.unitsByType, sim.unitCells and sim.unitStats (Units.init, called
		-- just below) plus sim.structAt and sim.structList (Economy.init).
	}, Sim)

	-- The unit tables first: Economy writes into them from its own init.
	Units.init(self)
	-- Structures, rails, trading transport boats and trains. Everything gold touches lives in
	-- Economy and hangs off the sim table from here.
	Economy.init(self)
	Gunboats.init(self)
	-- Fallout buffer, execution list and event queue. After Economy because it
	-- reads sim.structList to reach the structures Economy still owns.
	Nukes.init(self)
	-- Shell list and sequence. After Nukes, because its events ride Nukes'
	-- queue.
	Artillery.init(self)
	-- The sortie list and its id counter (2026-09-21).
	Airstrikes.init(self)
	-- The railgun's slug list and its id counter (2026-09-24).
	Railgun.init(self)

	Sim.assignTeamAnchors(self)

	-- The mode's opening, if it states one (Modes.SPECIAL). Here so a Sim
	-- built anywhere -- the headless harness included -- opens the way the
	-- mode says; ConquestServer calls it again after a room's dials.
	Sim.applySpecial(self)

	return self
end

-- THE MODE'S OPENING, from Modes.SPECIAL onto the sim's own fields. A mode
-- with no SPECIAL touches nothing, which is what keeps every ordinary round
-- bit-for-bit what it was. Called by Sim.new, and AGAIN by
-- ConquestServer.startRound after a private room's dials have been applied,
-- because a host's STARTING GOLD: NONE must not quietly switch GOLD RUSH off.
function Sim.applySpecial(self: Sim)
	local special = Modes.special(self.modeId)
	if special == nil then
		return
	end
	if special.startGold then
		self.startGold = special.startGold
	end
	if special.startTroops then
		self.startTroops = special.startTroops
	end
	if special.troopCapBonus then
		self.troopCapBonus = special.troopCapBonus
	end
	if special.startNukes then
		self.startNukes = special.startNukes
	end
	if special.attackSpeed then
		self.startAttackSpeed = special.attackSpeed
	end
end

-- ================================================================ players ==

-- `tag` is a CLAN TAG and it does exactly one thing: everybody who arrives
-- carrying the same one is put on the same team. Optional, empty for every bot
-- and for anyone who left the box blank, and inert in a free-for-all -- see the
-- team block at the end of this function.
--
-- `faux` marks a bot that is PRETENDING TO BE A PERSON: one of the phantom
-- seats a lobby card promised, wearing a real display name and reported to
-- the client as a player rather than as AI. It is the only kind of AI a
-- team mode puts on a side -- see that same block.
function Sim.addPlayer(
	self: Sim,
	name: string,
	isBot: boolean,
	userId: number?,
	tier: number?,
	tag: string?,
	faux: boolean?
): Player?
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
		-- trading-transport boat bonus. Counted separately from cities for exactly that
		-- reason: one of the two is in the maxTroops formula and one is not.
		portCount = 0,
		portLevels = 0,
		portBuilt = 0,
		factoryCount = 0,
		factoryLevels = 0,
		factoryBuilt = 0,
		defensePostCount = 0,
		defensePostLevels = 0,
		defensePostBuilt = 0,
		samCount = 0,
		samLevels = 0,
		samBuilt = 0,
		artilleryCount = 0,
		artilleryLevels = 0,
		artilleryBuilt = 0,
		airfieldCount = 0,
		airfieldLevels = 0,
		airfieldBuilt = 0,
		railgunCount = 0,
		railgunLevels = 0,
		railgunBuilt = 0,
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
		lastHitBy = nil,
		deathTile = nil,
		spawnPreview = nil,
		-- Which upstream AI class this empire is. A human is TIER_HUMAN; a bot
		-- takes what the caller asked for, or Config.DEFAULT_BOT_TIER when the
		-- caller predates the split (ConquestServer, ConquestSimulate).
		tier = if isBot then (tier or Config.DEFAULT_BOT_TIER) else Config.TIER_HUMAN,
		-- See the type block: only the phantom seats carry this.
		faux = if faux == true then true else nil,
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
		-- HUNTER (see Config). Hashed from the id so no rng draw moves.
		if faux ~= true and p.tier ~= Config.TIER_TRIBE
			and ((id * 2654435761) % 1000) / 1000 < (Config.BOT_HUNTER_FRACTION or 0)
		then
			p.aiHunter = true
		end
	end

	self.players[id] = p
	table.insert(self.playerOrder, id)
	if userId then
		self.byUserId[userId] = id
	end

	-- A FULL AI IS NEUTRAL AND STAYS NEUTRAL. Teams are for people and for
	-- the phantom seats pretending to be people (`faux`); every other empire
	-- on the map is a third party that both sides may eat and neither side
	-- owns. The whole roster used to partition into two or three blocs, which
	-- left nothing on the map that was not already an ally or an enemy.
	--
	-- `teamOf[id] == nil` is the single fact that says so: `sameTeam` answers
	-- false for a neutral against everyone, `teamStats` counts its land for no
	-- side, `autoSpawn` gives it no anchor to cluster around, and the client
	-- paints it in the ordinary grey AI ramp because `setTeams` never hands it
	-- a team colour.
	if self.teamCount > 0 and (not isBot or faux == true) then
		local best: number? = nil

		-- SAME CLAN TAG, SAME SIDE (2026-09-01, owner: "ensure players with the
		-- same tag are on the same team"). The first person wearing a tag picks
		-- a team the ordinary way below and the tag remembers it; everyone
		-- after them is placed with them, whatever the sizes say. That order is
		-- the reason this is only three lines: a clan never has to be MOVED,
		-- because it is only ever built forwards.
		--
		-- BOTS EVEN THE NUMBERS UP AFTERWARDS, which is what makes an unbounded
		-- guarantee safe here: ConquestServer adds every human first and then
		-- fills the roster with bots, and each of those bots takes the
		-- least-populated side. So a five-strong clan does not leave a side
		-- five members heavy -- it leaves it five HUMANS heavy, and the counts
		-- come out level. If clans ever need a cap, it goes here.
		if tag ~= nil and tag ~= "" then
			best = self.teamByTag[tag]
		end

		if best == nil then
			-- Least-populated team, ties to the lowest index. The server adds
			-- every human before any bot each round, so this spreads the
			-- unaffiliated humans across the sides first and then lets the bots
			-- even the numbers out.
			local bestN = math.huge
			best = 1
			for t = 1, self.teamCount do
				local n = self.teamSizes[t] or 0
				if n < bestN then
					bestN = n
					best = t
				end
			end
		end

		local team = best :: number
		self.teamOf[id] = team
		self.teamSizes[team] = (self.teamSizes[team] or 0) + 1
		if tag ~= nil and tag ~= "" then
			self.teamByTag[tag] = team
		end
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

-- FRIENDLY = same team OR allied (upstream PlayerImpl.isFriendly, composed in
-- Alliances.isFriendly). Every "may I attack this" and "is this a rival" test
-- in the AI reads THIS; sameTeam keeps the jobs that are genuinely about
-- teams -- the win bar, spawn anchors, colours. An ally is not a teammate: it
-- shares no win condition, only the rule that you may not shoot at it.
function Sim.friendly(self: Sim, a: number, b: number): boolean
	if Sim.sameTeam(self, a, b) then
		return true
	end
	return Alliances.allied(self, a, b)
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
			-- The tile that emptied them. Testing a counter that was just
			-- decremented is the whole cost, which is what makes it payable on
			-- the one path in this file that cannot afford a lookup.
			if p.tileCount == 0 then
				p.deathTile = tile
			end
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
-- Cities, ports, the rails between them and the trading transport boats and trains that use
-- them all live in `Conquest.Economy`. What stays here is the surface the
-- server and the AI call, so neither has to know which module owns what --
-- and, more to the point, so the attack loop below is not sharing a file with
-- a pathfinder.

Sim.CITY = Economy.CITY
Sim.PORT = Economy.PORT
Sim.FACTORY = Economy.FACTORY
Sim.DEFENSE_POST = Economy.DEFENSE_POST
-- THE ANTI-NUKE TOWER. It is a Units type rather than an Economy one -- a
-- launcher is never a station and Economy did not own it until a player could
-- buy one -- so this alias is what the server's build intent names, exactly as
-- the four above are.
Sim.SAM_LAUNCHER = Units.SAM_LAUNCHER
-- The two guns (2026-09-21); the server's build intent names these too.
Sim.ARTILLERY = Units.ARTILLERY
Sim.AIRFIELD = Units.AIRFIELD
-- The railgun (2026-09-24).
Sim.RAILGUN = Units.RAILGUN

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

function Sim.drainTradePayouts(self: Sim): { any }?
	return Economy.drainTradePayouts(self)
end

-- Eliminations since the last drain. Nil rather than an empty table, so the
-- caller skips the send on the ordinary tick -- the same contract as every
-- other drain above.
function Sim.drainConquests(self: Sim): { any }?
	if #self.conquestEvents == 0 then
		return nil
	end
	local out = self.conquestEvents
	self.conquestEvents = {}
	return out
end

-- Transport transport boats ride the SAME wire stream as trading transport boats and trains: one
-- format, one client renderer, one interpolation clock, and one 2 Hz budget.
-- Adding a parallel "boats" channel would have duplicated all four.
--
-- THE ID OFFSET IS GONE. It existed because transport boats were numbered from
-- Sim.nextTransportBoatId and trading transport boats and trains from sim.nextVehicleId, two
-- counters that collide -- and the client keys its markers by id, so a shared
-- id read as a transport boat teleporting between a train and itself. All three are
-- units now and draw from the one id space, so there is nothing to offset.
Sim.VEHICLE_TRANSPORT = 3

function Sim.vehicles(self: Sim): { any }
	local out = Economy.vehicles(self)
	-- Gunboats (kind 4) ride the one unit id space like everything else here;
	-- shells (kind 5) are not units and carry their own offset.
	Gunboats.vehicles(self, out)
	for _, b in self.transportBoats do
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

-- `ignoreId` is the empire whose own dot does not count against it: during
-- the spawn phase it is standing on the ground it is about to leave, so both
-- the owner test and the spacing rule -- measured from its own spawnTile --
-- would otherwise forbid it every tile within thirty of where it already is,
-- which is to say forbid it from moving at all. Absent, this is exactly what
-- it always was: nil can never equal an owner byte or a player id.
function Sim.isValidSpawn(self: Sim, tile: number, ignoreId: number?): boolean
	if tile < 0 or tile >= N then
		return false
	end
	if not TileMap.isPassable(self.map, tile) then
		return false
	end
	local owner = buffer.readu8(self.map.owner, tile)
	if owner ~= 0 and owner ~= ignoreId then
		return false
	end
	local tx, ty = tile % W, (tile - tile % W) / W
	local minD = Config.MIN_SPAWN_DISTANCE
	for _, id in self.playerOrder do
		local other = self.players[id]
		if other and other.spawnTile and other.id ~= ignoreId then
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

-- THE OPENING, paid at the three places an empire is put on the map
-- (spawnPlayer, autoSpawn's crowded-map fallback, loadScenario) so they cannot
-- drift. `troops` is the site's own figure -- the tier's spawn army under the
-- host's scale, or a nation's share of its ceiling -- and a special mode's
-- flat `startTroops` replaces it outright (Modes.SPECIAL: "Starting 1 Million
-- Army" is a number, not a multiplier). Gold is flat and zero unless a host
-- or a mode asked otherwise: nothing else in the sim grants any. The cap
-- bonus rides on the PLAYER because maxTroops takes a player and no sim; the
-- warheads land in the same freeNukes the "+1 Nuke!" token uses, so the
-- order, the charge and the rail button already know what to do with them.
local function payOpening(self: Sim, p: Player, troops: number)
	p.troops = self.startTroops or troops
	p.gold = self.startGold or 0
	if (self.troopCapBonus or 0) > 0 then
		p.capBonus = self.troopCapBonus
	end
	if (self.startNukes or 0) > 0 then
		p.freeNukes = (p.freeNukes or 0) + self.startNukes
	end
	-- BLITZ. Set, not multiplied, exactly as the tutorial product sets it:
	-- "2x" is the mode, and nothing else in the sim writes this field.
	if self.startAttackSpeed then
		p.attackSpeed = self.startAttackSpeed
	end
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
	-- ...and the treasury, the ceiling and the warheads with it: payOpening.
	payOpening(self, p, Config.TIER[p.tier].SPAWN_TROOPS * (self.troopScale or 1))

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

-- ================================================ the dot before the round ==
-- A click during the spawn phase does not place you. It puts a small disc of
-- your colour on the map, and the next click MOVES it -- the old one is
-- relinquished tile by tile and a new one taken -- right up until the phase
-- ends, when every dot on the map blooms into its empire at once.
--
-- THE DOT IS REAL TERRITORY, not an overlay, which is the whole reason this
-- is cheap: the ordinary owner delta already carries it, the renderer already
-- draws it in that empire's own colour, and `isValidSpawn` already refuses an
-- owned tile, so two people cannot stand on the same ground without a single
-- line of new arbitration.
local function clearPreview(self: Sim, p: Player)
	local tile = p.spawnPreview
	if not tile then
		return
	end
	local r = Config.SPAWN_PREVIEW_RADIUS
	local cx, cy = tile % W, (tile - tile % W) / W
	for dy = -r, r do
		for dx = -r, r do
			if dx * dx + dy * dy <= r * r then
				local x, y = cx + dx, cy + dy
				if TileMap.inBounds(x, y) then
					local i = y * W + x
					-- Only what is still OURS. Nothing else can have taken a tile
					-- during a spawn phase, but the map is the authority on who
					-- holds what and reading it costs one byte.
					if buffer.readu8(self.map.owner, i) == p.id then
						Sim.conquer(self, i, 0)
					end
				end
			end
		end
	end
	p.spawnPreview = nil
	p.spawnTile = nil
end

Sim.clearSpawnPreview = clearPreview

-- Place the dot, or move it. Returns ok plus the reason the HUD says out
-- loud: in the one phase where clicking the map IS the entire interface, a
-- click that silently does nothing reads as a broken game rather than as an
-- illegal move.
function Sim.previewSpawn(self: Sim, p: Player, tile: number): (boolean, string?, any?)
	-- ON A PREDRAWN MAP THE CLICK CLAIMS A COUNTRY, not a square yard. Same
	-- entry point so the server's intent handler and the tutorial need no
	-- second path; see the historical block further down.
	if self.historical then
		return Sim.pickNation(self, p, tile)
	end
	if p.spawned then
		return false, "already"
	end
	if tile < 0 or tile >= N or not TileMap.isPassable(self.map, tile) then
		return false, "water"
	end
	-- Judged against everybody ELSE -- see isValidSpawn's ignoreId.
	if not Sim.isValidSpawn(self, tile, p.id) then
		return false, "toonear"
	end

	-- Only after the new spot is known to be legal. Dropping the old dot first
	-- and then failing would leave a player who mis-clicked with nothing on the
	-- map and no way to tell that anything had happened.
	clearPreview(self, p)

	local r = Config.SPAWN_PREVIEW_RADIUS
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

	p.spawnPreview = tile
	-- The spacing rule reads spawnTile, so a dot has to occupy one: without it
	-- two people are both "unplaced" and can pick the same square yard.
	p.spawnTile = tile
	return true
end

-- The dot becomes an empire. The disc goes back to nobody first, so
-- spawnPlayer sees exactly the map an unplaced player would have seen -- it
-- refuses an owned tile, and the tile it is being sent to is the middle of
-- our own dot.
function Sim.commitSpawn(self: Sim, p: Player): boolean
	local tile = p.spawnPreview
	if not tile or p.spawned then
		return false
	end
	clearPreview(self, p)
	if Sim.spawnPlayer(self, p, tile) then
		return true
	end
	-- Anywhere beats nowhere. A player who chose a spot and then spectated the
	-- whole round because of a tie-break is the worst outcome this function
	-- has, and it is worth two hundred random samples to avoid it.
	Sim.autoSpawn(self, p)
	return p.spawned
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
	-- A NEUTRAL AI HAS NO ANCHOR. `teamOf` is nil for every full AI now, and
	-- the old `or 1` fallback would have dropped all of them on the FIRST
	-- team's anchor -- burying one side under the neutrals it is supposed to
	-- be eating. No anchor means the ordinary scatter below.
	local myTeam = self.teamOf[p.id]
	local anchor = myTeam ~= nil and self.teamAnchors[myTeam] or nil
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
			payOpening(self, p, Config.TIER[p.tier].SPAWN_TROOPS * (self.troopScale or 1))
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
	-- NOTHING PURCHASED TOUCHES THIS FUNCTION. "+1 Million Army Size!" briefly
	-- added a bought term here; it hands over the TROOPS instead now (owner,
	-- 2026-09-12), which is a different thing entirely -- the ceiling is what
	-- an empire may hold, and the product is an army that is allowed to stand
	-- above it. The exemption that lets it lives in the growth loop's snap,
	-- not here, so this stays the pure territory-and-cities formula it was.
	-- ...THE ONE ADDITION OUTSIDE THE SCALE, and it is a MODE, not a purchase:
	-- MEGA ARMY's flat ceiling (Modes.SPECIAL troopCapBonus, paid onto the
	-- player in payOpening). Outside the tier scale on purpose -- "everyone +1
	-- million" is the same million for a bot -- and nil, adding nothing, on
	-- every empire of an ordinary round.
	return m * Config.TIER[p.tier or Config.TIER_HUMAN].MAX_TROOPS_SCALE + (p.capBonus or 0)
end

Sim.maxTroops = maxTroops
-- nukeDeathFactor for a MIRV warhead is a curve against the troop CEILING
-- (Config.ts:1071-1078), so the nuclear layer needs this function and cannot
-- require Sim back.
Nukes.maxTroopsFn = maxTroops

-- ======================================================== reinforcements ==
-- CALL IN REINFORCEMENTS (owner, 2026-09-21: "another card that allows
-- players to call in reinforcements. They use gold to get X amount of
-- troops"). NOT UPSTREAM -- OpenFront sells no troops for gold anywhere; the
-- only route to men there is time and cities. Constants and the balance
-- measurement live in Config's REINFORCE block.
--
-- ONE FLAT PRICE, A FIFTH OF THE CEILING since 2026-09-22 (owner, later the same day:
-- "reinforce should always cost the same amount (100k gold)" and "always give
-- 25% of a players max troop size"): REINFORCE_COST buys REINFORCE_FRACTION of
-- maxTroops(p). The men land WHOLE, above the cap if that is where they land --
-- the purchase grants the bought-overflow permission "+1 Million Army Size!"
-- uses (troopOverflow, honoured by the `p.troops > max` branch in Sim.step and
-- cleared the moment the army is spent back under its cap), because a flat
-- price for a bundle the next tick would snap away is a bill for nothing.
--
-- Two refusals, in this order: "cooldown" (REINFORCE_COOLDOWN ticks since the
-- last purchase have not passed), "gold". The figures come back with every
-- refusal anyway, so the rail button can print an honest price and countdown.
--
-- BOTS NEVER BUY. Nothing in Sim.botThink calls this and nothing should: the
-- AI's troop income is already an eighth of a person's (BOT_GROWTH_SCALE) by
-- two deliberate nerfs, and a roster that bought men back with its treasury
-- would undo both from the gold side. Sim.reinforce refuses isBot outright
-- so no later caller can route one through by accident.
--
-- Returns troops, gold, why (nil when the purchase would go through), and
-- the cooldown ticks left.
function Sim.reinforceQuote(self: Sim, p: Player): (number, number, string?, number)
	local last = p.reinforceTick
	local left = if last ~= nil
		then math.max(0, last + (Config.REINFORCE_COOLDOWN or 300) - self.tick)
		else 0
	-- NEVER MORE THAN THE ROOM UNDER THE CEILING. The card hands over MEN, not
	-- ceiling, so a bundle that overshoots has to be either snapped away on the
	-- next tick or exempted from the snap -- and the exemption is what this used
	-- to take (p.troopOverflow, the tutorial boost's flag). That stalled income
	-- outright: growth lives only in the `troops < max` arm below, so an empire
	-- parked above its cap earned nothing for the rest of the round, and the
	-- purchases stacked without bound (measured: 20 buys reached 4.6x the
	-- ceiling). Capping the QUOTE is what makes both impossible, and the tip on
	-- the button quotes this same figure, so the card never promises more than
	-- it gives.
	local room = math.max(0, math.floor(maxTroops(p)) - math.floor(p.troops))
	local troops = math.min(math.floor(maxTroops(p) * (Config.REINFORCE_FRACTION or 0.25)), room)
	local gold = Config.REINFORCE_COST or 100000
	if left > 0 then
		return troops, gold, "cooldown", left
	end
	-- "full" is a refusal ConquestServer's own comment and the client's wording
	-- have always named; until now nothing ever returned it, so an army at its
	-- ceiling paid full price for nothing.
	if room <= 0 then
		return troops, gold, "full", left
	end
	if p.gold < gold then
		return troops, gold, "gold", left
	end
	return troops, gold, nil, left
end

-- The purchase. RE-QUOTES rather than trusting anything the client sent, so
-- the price paid is the price the server saw on this tick -- the same rule
-- Economy.build follows for a city.
function Sim.reinforce(self: Sim, playerId: number): (boolean, string?, number, number)
	local p = self.players[playerId]
	if not p or not p.alive or not p.spawned then
		return false, "notready", 0, 0
	end
	if self.phase ~= "playing" then
		return false, "notplaying", 0, 0
	end
	if p.isBot then
		return false, "bot", 0, 0
	end
	local troops, gold, why = Sim.reinforceQuote(self, p)
	if why ~= nil then
		return false, why, troops, gold
	end
	p.gold -= gold
	p.troops += troops
	p.reinforceTick = self.tick
	-- NO OVERFLOW FLAG HERE. reinforceQuote caps the bundle at the room under
	-- the ceiling, so this purchase cannot stand the army above its cap.
	-- p.troopOverflow belongs to the tutorial's "+1 Million Army" boost alone --
	-- the one thing in the game allowed above the ceiling -- and borrowing it
	-- here is what stopped troop income dead and let the card stack.
	return true, nil, troops, gold
end

-- ============================================================= historical ==
-- A PREDRAWN MAP (Modes.historical, 2026-09-11). Every nation in the scenario
-- is an AI empire from the first tick, standing on its borders with its cities
-- and ports already built; the spawn phase is "pick a nation" -- a click on a
-- playable country claims it, another click moves the claim -- and at the
-- phase's end each claim becomes a TRANSFER: the person takes the nation's
-- land, buildings, army and treasury, and the AI that was holding the seat
-- retires. Nothing about attacks, boats, structures or the win check knows
-- the mode exists; the ordinary owner delta carries a transfer exactly as it
-- carries a spawn burst.
--
-- THE TRANSFER GOES TO THE PERSON'S OWN EMPIRE, not the other way round.
-- Rebinding the nation's empire to the person would move no tiles, but every
-- client already knows `yourId`, and the money ledger, alliances and the
-- analytics are all keyed on the human's id. A transfer of the Soviet Union
-- is ~16k tiles through Sim.conquer, on the same phase-end tick that already
-- carries a 26k-tile spawn burst on an ordinary round.
--
-- Sits below maxTroops because an opening army is sized off it.

-- Share of the troop ceiling a nation opens with. An ordinary spawn opens on
-- 25k troops in a 377-tile blob; a country of six thousand tiles opening on
-- 25k would be an empty shell for the first ten minutes, and a hollow major
-- next to you is a free lunch rather than a neighbour.
--
-- MEASURED 2026-09-11 (headless, seed 4242, 57 nations): the share barely
-- moves the death rate -- what does is the AI TIER. On TIER_NATION (growth
-- 0.95x a person's) forty nations were dead inside 100 s at ANY share, with
-- or without a single building; on the game's default tier (growth 0.125x)
-- the same 200 s cost 21 deaths at 0.40 and 4 at 0.15. So the nations run on
-- Config.DEFAULT_BOT_TIER like every other AI, and this sits between.
local SCENARIO_START_TROOPS = 0.25

-- Nobody may be attacked for this long after the round starts, in place of
-- Config.SPAWN_IMMUNITY_SECONDS (5). ZERO: NO TRUCE (owner, 2026-09-11:
-- "remove the truce in historical mode") -- the war starts on the tick the
-- spawn phase ends. It was 60 s, for a person to find their country before it
-- was a war. A scenario may still state its own GRACE_SECONDS; 0 is truthy in
-- Luau, so a stated 0 is honoured and never falls through to Config.
local SCENARIO_GRACE_SECONDS = 0

-- One AI empire per nation, painted onto the map, buildings and all. Called
-- by the server from startRound INSTEAD of its bot loop, after the humans are
-- added and before anyone holds ground.
function Sim.loadScenario(self: Sim, scn: any)
	local mask = Scenarios.nationMask(scn)
	self.scenario = scn
	self.nationMask = mask
	self.historical = true
	self.immunityTicks = math.floor((tonumber(scn.GRACE_SECONDS) or SCENARIO_GRACE_SECONDS) * Config.TICK_RATE)
	-- A NAVAL SCENARIO'S FLEET RULES (2026-09-24, the Pacific War): the
	-- per-empire gunboat ceiling and the port replacement timer. Gunboats reads
	-- both off the sim and falls back to Config, so every other round is as it was.
	local navy = scn.NAVY
	self.gunboatMax = navy and tonumber(navy.maxPerPlayer) or nil
	self.gunboatSpawnTicks = navy and tonumber(navy.spawnTicks) or nil
	local map = self.map
	local owner = map.owner
	local byNation: { [number]: Player } = {}
	for k, nation in ipairs(scn.NATIONS) do
		-- THE DEFAULT TIER, not TIER_NATION. See SCENARIO_START_TROOPS: the
		-- nation class regrows an army at a person's rate, and fifty-seven of
		-- them on touching borders ate each other in two minutes.
		local p = Sim.addPlayer(self, nation.name, true, nil, Config.DEFAULT_BOT_TIER)
		if not p then
			warn("[Conquest] scenario " .. tostring(scn.ID) .. ": roster full at nation " .. k)
			break
		end
		p.nation = k
		byNation[k] = p
		self.nationPlayer[k] = p.id
	end

	-- PAINT STRAIGHT INTO THE OWNER BUFFER rather than through Sim.conquer: a
	-- hundred thousand tiles through the change list would go out as a delta
	-- on top of the init snapshot that already carries them, and the border
	-- sets are cheaper built once at the end than maintained tile by tile.
	local painted = 0
	for i = 0, N - 1 do
		local k = buffer.readu8(mask, i)
		if k ~= 0 then
			local p = byNation[k]
			if p and buffer.readu8(owner, i) == 0 and TileMap.isPassable(map, i) then
				buffer.writeu8(owner, i, p.id)
				p.tileCount += 1
				local tx = i % W
				p.sumX += tx
				p.sumY += (i - tx) / W
				painted += 1
			end
		end
	end
	for i = 0, N - 1 do
		if buffer.readu8(owner, i) ~= 0 then
			refreshBorder(self, i)
		end
	end

	-- BUILDINGS, at their stated levels. Economy.add is the path a structure
	-- placed by anything but the construction queue takes: the unit, the
	-- counters, the station and the client event all come from it. A stated
	-- tile that is not this nation's ground (the generator and the map can
	-- disagree by a tile at a coast) is skipped and counted, not moved.
	local built, skipped = 0, 0
	for k, nation in ipairs(scn.NATIONS) do
		local p = byNation[k]
		if p then
			for _, s in ipairs(nation.structures) do
				local t = s.t
				if
					t >= 0 and t < N
					and buffer.readu8(owner, t) == p.id
					and TileMap.isPassable(map, t)
					and self.structAt[t] == nil
				then
					Economy.add(self, t, p.id, s.k, s.l)
					built += 1
				else
					skipped += 1
				end
			end
		end
	end

	-- Everybody is on the map: spawned, with an army sized to the country
	-- rather than to a dot, and the capital as the tile the camera lands on.
	-- After the buildings, because a city raises the ceiling the army is
	-- sized from.
	for k, nation in ipairs(scn.NATIONS) do
		local p = byNation[k]
		if p then
			p.spawned = true
			p.spawnTile = nation.capital
			payOpening(self, p, math.floor(maxTroops(p) * SCENARIO_START_TROOPS * (self.troopScale or 1)))
		end
	end
	print(string.format(
		"[Conquest] scenario %s: %d nations, %d tiles painted, %d structures placed, %d skipped",
		tostring(scn.ID), #scn.NATIONS, painted, built, skipped
	))
end

-- A click during the spawn phase, in place of previewSpawn. Returns ok, the
-- reason the HUD says out loud, and on success what was claimed -- the
-- nation's index and name, the AI holding it and its capital -- so the client
-- can ring the capital and flash the country rather than the square yard.
function Sim.pickNation(self: Sim, p: Player, tile: number): (boolean, string?, any?)
	if p.spawned then
		return false, "already"
	end
	local mask = self.nationMask
	local scn = self.scenario
	if mask == nil or scn == nil then
		return false, "nonation"
	end
	if tile < 0 or tile >= N or not TileMap.isPassable(self.map, tile) then
		return false, "water"
	end
	local k = buffer.readu8(mask, tile)
	local nation = k ~= 0 and scn.NATIONS[k] or nil
	if not nation then
		return false, "nonation"
	end
	if not nation.playable then
		return false, "notplayable"
	end
	local taker = self.nationTaker[k]
	if taker ~= nil and taker ~= p.id then
		return false, "taken"
	end
	-- Only after the new claim is known to be legal, the same order the dot
	-- follows: a refused click must leave the old claim standing.
	local prev = p.nationPick
	if prev ~= nil and prev ~= k and self.nationTaker[prev] == p.id then
		self.nationTaker[prev] = nil
	end
	p.nationPick = k
	self.nationTaker[k] = p.id
	return true, nil, {
		nation = k,
		name = nation.name,
		owner = self.nationPlayer[k],
		tile = nation.capital,
	}
end

-- The nation becomes the person's. Land through the one mutation point, so
-- the border sets, the counts and the delta all move together; buildings
-- through Units.setOwner, which keeps the counters and the station in step
-- and emits the event the client repaints from.
local function transferNation(self: Sim, p: Player, k: number): boolean
	local scn = self.scenario
	local nation = scn and scn.NATIONS[k]
	local botId = self.nationPlayer[k]
	local bot = botId and self.players[botId]
	if not nation or not bot or bot.id == p.id then
		return false
	end
	local owner = self.map.owner
	for i = 0, N - 1 do
		if buffer.readu8(owner, i) == bot.id then
			Sim.conquer(self, i, p.id)
		end
	end
	-- Cloned: setOwner swap-removes from the very list being walked.
	for _, u in ipairs(table.clone(Units.ofPlayer(self, bot.id))) do
		if u.active then
			Units.setOwner(self, u, p.id)
		end
	end
	p.troops = bot.troops
	p.gold = bot.gold
	p.spawned = true
	p.spawnTile = nation.capital
	p.nation = k
	p.nationPick = nil
	-- THE PERSON KEEPS THEIR OWN NAME (owner, 2026-09-11: "display their pfp
	-- and name as usual"). Their name and face went up on the nation the
	-- moment they claimed it (ConquestServer's roster), so renaming them
	-- "Germany" here would swap the label out from under them as the war
	-- starts. The colour still says which country it is.
	self.nationPlayer[k] = p.id

	-- The AI retires. `spawned = false` takes it out of every summary and out
	-- of the elimination sweep, `alive = false` out of the AI loop; it holds
	-- no ground, so nothing can ever put it back.
	bot.troops = 0
	bot.gold = 0
	bot.spawned = false
	bot.alive = false
	bot.nation = nil
	table.clear(bot.border)
	bot.borderCount = 0
	Sim.cancelAttacks(self, bot.id)
	return true
end

-- The phase ends: every claim becomes a transfer, then whoever never clicked
-- is handed the biggest nation still under the AI -- playable first, then
-- any minor -- because nobody should spectate a round they queued for.
function Sim.commitHistorical(self: Sim)
	local scn = self.scenario
	if scn == nil then
		return
	end
	-- Claims first, so nobody's choice is handed to somebody who never made one.
	for _, id in self.playerOrder do
		local p = self.players[id]
		if p and not p.spawned and p.nation == nil and p.nationPick ~= nil then
			if not transferNation(self, p, p.nationPick) then
				-- ...AND RELEASE THE CLAIM. `nationTaker` is what the fallback
				-- below tests for "is this nation spoken for", so a failed
				-- transfer that left the mark standing withheld that nation from
				-- everyone -- this player included.
				if self.nationTaker[p.nationPick] == p.id then
					self.nationTaker[p.nationPick] = nil
				end
				p.nationPick = nil
			end
		end
	end
	-- PEOPLE ONLY -- by tier, not by isBot: a person who left mid-phase is
	-- isBot already and still owed a seat (their empire is AI-run either way,
	-- exactly as on an ordinary round), while an AI that just retired is
	-- unspawned with no nation and would otherwise be re-seated on the next
	-- biggest country, retiring THAT AI, and so on down the roster.
	for _, id in self.playerOrder do
		local p = self.players[id]
		if p and not p.spawned and p.nation == nil and p.tier == Config.TIER_HUMAN then
			local best, bestTiles, bestPlayable = nil, -1, false
			for k, nation in ipairs(scn.NATIONS) do
				local holder = self.players[self.nationPlayer[k] or 0]
				if holder and holder.nation == k and self.nationTaker[k] == nil then
					local playable = nation.playable == true
					if (playable and not bestPlayable) or (playable == bestPlayable and holder.tileCount > bestTiles) then
						best, bestTiles, bestPlayable = k, holder.tileCount, playable
					end
				end
			end
			if best ~= nil then
				self.nationTaker[best] = p.id
				transferNation(self, p, best)
			else
				-- More people than nations. Anywhere beats nowhere.
				Sim.autoSpawn(self, p)
			end
		end
	end
end

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

-- ---------------------------------------------------------- land bridge --

-- THE OPEN GROUND BETWEEN TWO EMPIRES THAT DO NOT TOUCH.
--
-- Tapping a country you do not border is the commonest mis-aimed order in
-- the game, and refusing it ("your land does not touch them yet") answers a
-- question nobody asked: the player can see they do not touch, what they
-- wanted was to set off. There is no button for open land -- you take it by
-- tapping it -- so the refusal made them find the gap and aim into it by
-- hand, one tap at a time.
--
-- So walk out from the TAPPED tile instead, through open ground and through
-- the target's own territory (a tap in the middle of a country has to work
-- too), until the walk touches something of ours. That crossing is where the
-- two empires are closest ALONG THE GROUND rather than as the crow flies, so
-- a lake, a river or a third empire in the way moves the march rather than
-- breaking it -- and an impassable tile is never stepped through, which is
-- what keeps "you cross water by boat" true.
--
-- Returns the open tile at the crossing -- the first tile the march takes --
-- and OUR tile beside it, which is what the front is seeded from. nil when
-- there is no route through open land: an island, a country walled off by
-- somebody else, or simply further than LAND_BRIDGE_SCAN. Every one of those
-- falls through to the navy, which is the behaviour that was there before.
--
-- THE AI DOES NOT COME THROUGH HERE. Bots take open land already -- it is
-- their first phase and they consider nothing else while any of it touches
-- them (BOT_EXPAND_RESERVE_RATIO) -- and they only ever pick a rival out of
-- a sample of their own frontier, so a bot with a gap in front of it is a
-- bot that is already filling the gap. This is a control, not a rule.
local function landBridge(self: Sim, playerId: number, targetTile: number): (number?, number?)
	local map = self.map
	local owner = map.owner
	local targetId = buffer.readu8(owner, targetTile)
	if targetId == 0 or targetId == playerId then
		return nil, nil
	end

	local limit = Config.LAND_BRIDGE_SCAN or 12000
	local queue = table.create(1024)
	local seen: { [number]: true } = {}
	local nbuf = table.create(4)
	queue[1] = targetTile
	seen[targetTile] = true
	local head, count = 1, 1

	while head <= count do
		local t = queue[head]
		head += 1
		-- Only OPEN ground can be the place the march starts: what this seeds
		-- is an attack on nobody, and an attack only ever takes tiles
		-- belonging to the id it was opened against. A tile of THEIRS beside
		-- us would have meant the ordinary attack was legal and this was
		-- never called -- but the front still has to be seeded on land the
		-- push is allowed to have.
		local open = buffer.readu8(owner, t) == 0
		local n = TileMap.neighbors4(t, nbuf)
		for k = 1, n do
			local nb = nbuf[k]
			if not seen[nb] then
				local o = buffer.readu8(owner, nb)
				if o == playerId then
					if open then
						return t, nb
					end
				elseif (o == 0 or o == targetId) and TileMap.isPassable(map, nb) then
					seen[nb] = true
					count += 1
					queue[count] = nb
				end
			end
		end
		if count >= limit then
			return nil, nil
		end
	end
	return nil, nil
end
Sim.landBridge = landBridge

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
--
-- `sourceTile` names a tile of OURS to start the front from, instead of
-- seeding it everywhere the two empires touch. Two callers set it and both
-- mean the same thing -- this push begins HERE and must not open back home:
-- a beachhead (landTransportBoat) and a land bridge (Sim.landBridge).
function Sim.launchAttack(
	self: Sim,
	playerId: number,
	targetTile: number,
	ratio: number,
	absTroops: number?,
	sourceTile: number?
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
	-- ...nor on an ALLY. Its own reason, because the way out is different:
	-- a teammate is for the round, an alliance can be broken first.
	if targetId ~= 0 and Alliances.allied(self, playerId, targetId) then
		return false, "allied"
	end

	-- Reference: nobody may be attacked until the spawn phase plus the
	-- immunity window has elapsed. phaseTick restarts at 0 when the round
	-- begins, so this is measured from the end of spawn selection. Unclaimed
	-- land is never immune. A predrawn map states a longer window of its own
	-- (immunityTicks, Sim.loadScenario); nil on every ordinary round.
	if targetId ~= 0
		and self.phaseTick < (self.immunityTicks or (Config.SPAWN_IMMUNITY_SECONDS or 0) * Config.TICK_RATE)
	then
		return false, "immunity"
	end

	-- THE TUTORIAL'S GRACE. Same rule, one empire, a longer clock. The
	-- protected player may still attack out -- the third lesson is "take
	-- somebody else's land" and it would be unplayable otherwise -- so this
	-- reads the ATTACKER as well as the target. See Sim.new.
	if self.protectId ~= 0
		and targetId == self.protectId
		and playerId ~= self.protectId
		and self.tick < self.protectUntil
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
				-- CLAMPED: a negative `other.troops` would make `absorbed`
				-- negative, which GROWS `committed` -- free troops for the
				-- counter-attacker, paid for by nobody. processAttack no longer
				-- produces one; this is the belt to that braces.
				local absorbed = math.max(0, math.min(other.troops, committed))
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
			-- A NAMED STARTING POINT ALWAYS SEEDS, and pays four tiles to do
			-- it -- this is not the whole-border walk RESEED_TICKS exists to
			-- throttle. Without it a land bridge folded into an expansion the
			-- player already had running would pour the men into whichever
			-- direction that push was already facing, which is exactly the
			-- order they were trying to give.
			if sourceTile ~= nil then
				local sn = TileMap.neighbors4(sourceTile, self.nbuf)
				for k = 1, sn do
					enqueue(self, atk, self.nbuf[k])
				end
			end
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
		sourceTile = sourceTile,
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
-- outright, spawn an attack rooted at it, delete the transport boat.
--
-- THE FREE BEACHHEAD IS NOT A GIFT, IT IS LOAD-BEARING. An attack only ever
-- takes a tile that already touches the attacker, so a landing with no tile
-- ashore pops its whole frontier, fails the adjacency test on every one, and
-- dies without firing a shot. Conquering `dst` is what gives it something to
-- be adjacent to.
local function landTransportBoat(self: Sim, transportBoat: TransportBoat)
	local attacker = self.players[transportBoat.ownerId]
	if not attacker or not attacker.alive or transportBoat.troops < 1 then
		return
	end
	local map = self.map
	local dst = transportBoat.ext.dst
	local targetId = buffer.readu8(map.owner, dst)

	-- The coast changed hands during the crossing and it is ours or an
	-- ally's now. The men come home, less the retreat malus -- upstream pays
	-- the same 25% for a transport boat that arrives somewhere friendly.
	if targetId == transportBoat.ownerId or (targetId ~= 0 and Sim.friendly(self, transportBoat.ownerId, targetId)) then
		attacker.troops += transportBoat.troops * (1 - Config.RETREAT_PENALTY)
		return
	end
	if not TileMap.isPassable(map, dst) then
		attacker.troops += transportBoat.troops * (1 - Config.RETREAT_PENALTY)
		return
	end

	Sim.conquer(self, dst, transportBoat.ownerId)

	local atk: Attack = {
		attackerId = transportBoat.ownerId,
		targetId = targetId,
		troops = transportBoat.troops,
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

-- Send a transport transport boat at `targetTile`. Returns ok plus a REASON, same
-- contract as launchAttack, because every one of these refusals is otherwise
-- indistinguishable from the tap not registering.
function Sim.launchTransportBoat(self: Sim, playerId: number, targetTile: number): (boolean, string?)
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
	if aimedAt ~= 0 and Alliances.allied(self, playerId, aimedAt) then
		return false, "allied"
	end
	if aimedAt ~= 0
		and self.phaseTick < (self.immunityTicks or (Config.SPAWN_IMMUNITY_SECONDS or 0) * Config.TICK_RATE)
	then
		return false, "immunity"
	end
	-- ...and the tutorial's grace, which has to be refused on the SEA route as
	-- well: a coastal student would otherwise be landed on by the first bot
	-- whose land attack this window turned away.
	if self.protectId ~= 0
		and aimedAt == self.protectId
		and playerId ~= self.protectId
		and self.tick < self.protectUntil
	then
		return false, "immunity"
	end

	if (self.transportBoatBudget or 0) <= 0 then
		return false, "busy"
	end
	local afloat = 0
	for _, b in self.transportBoats do
		if b.active and b.ownerId == playerId then
			afloat += 1
		end
	end
	if afloat >= Config.TRANSPORT_BOAT_MAX_PER_PLAYER then
		return false, "toomanytransportboats"
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

	local troops = math.floor(p.troops / Config.TRANSPORT_BOAT_TROOP_DIVISOR)
	if troops < Config.TRANSPORT_BOAT_MIN_TROOPS then
		return false, "troops"
	end

	local path = Navy.path(self.nav, map, src, dst)
	if path == nil or #path == 0 then
		return false, "nosearoute"
	end

	self.transportBoatBudget = (self.transportBoatBudget or 1) - 1
	p.troops -= troops
	table.insert(self.transportBoats, Units.spawn(self, Units.TRANSPORT_BOAT, playerId, src, {
		troops = troops,
		ext = {
			targetId = aimedAt,
			dst = dst,
			path = path,
			pathIdx = 1,
			-- The fine water route to the CURRENT waypoint, bought a leg at a
			-- time in stepTransportBoats and thrown away at each one. Nil is a legal
			-- state and means "steer straight at it this tick".
			leg = nil :: { number }?,
			legIdx = 1,
			legTo = nil :: number?,
			-- The waypoint whose only fine route was a WALK, as opposed to one
			-- whose search simply came back empty. Both are retried; this one
			-- waits ten times as long, because its answer changes that much
			-- more slowly.
			legWalk = nil :: number?,
			-- Give-up bookkeeping: the waypoint being closed on, the closest this
			-- transport has ever come to it, and how long since that improved.
			idleWp = nil :: number?,
			bestD = nil :: number?,
			idle = 0,
		},
	}))
	return true
end
-- Move every transport boat. Between two coarse waypoints it follows a CHANNEL -- the
-- tile-level water route Navy.channel finds inside a window around the leg --
-- and falls back to steering straight at the waypoint when there is no
-- channel to be had: no window solution, or the tick's allowance of searches
-- already spent. The fallback still PREFERS water without requiring it,
-- because the coarse grid calls a cell navigable if any tile in it is water,
-- so a route legitimately clips headlands, and refusing to move on land there
-- would strand transport boats on coastlines forever.
-- What a land step costs a transport boat's fine route, in water steps. Same figure
-- Economy portages a trade lane with, and for the same reason.
local PORTAGE_COST = 25
-- Consecutive land tiles a portage may contain before the crossing stops
-- being a land bridge and starts being a walk across a county.
--
-- THIS ONE IS A TRADE AND THERE IS NO FREE VALUE, so the measurements are
-- here rather than a justification. One us/ffa match, 72 empires, 3600 ticks,
-- seed 424242, against a control with the portage unbounded:
--
--   cap    land time   longest walk   invasions landed
--    6       0.68%          6 tiles          52
--    8       0.97%          8               46
--   12       2.11%         12               88
--   16       3.02%         16              114
--   none     3.59%         23-31           123
--
-- Landings fall with the cap because the coarse grid genuinely lays legs
-- across wide land -- a cell counts as navigable when any tile in it is wet --
-- so a real fraction of amphibious invasions only ever arrived by marching
-- twenty-odd tiles inland, which IS the artefact this pass exists to remove.
-- 12 halved the time ashore and capped a walk at 1.2 seconds of it, for 28%
-- fewer landings; the troops come home rather than dying, so the cost is a
-- slower war, not a lost army.
--
-- THEN THE FINE ROUTE BECAME 4-CONNECTED (Navy's NEI4) AND THIS HAD TO MOVE
-- WITH IT. A rook-stepped crossing of the same isthmus is a staircase and so
-- costs up to 1.41x the tiles -- the cap did not change but its MEANING did,
-- and landings fell from 88 to 56 with give-ups up from 38 to 62. Re-swept on
-- the same seed with rook steps:
--
--   cap    land time   longest walk   landed   gave up
--    12       1.77%         20            56       62
--    14       2.26%         15            59       46
--    17       3.29%         18            85        5
--    20       3.29%         20            85        5
--
-- 17 and 20 are the SAME run, so 17 is where it saturates -- no crossing on
-- this map needs more. Taken, because the rook-step change was asked for to
-- fix how boats LOOK and it must not quietly halve the amphibious game as a
-- side effect: landings are back at the pre-rook 88 and give-ups are better
-- than they were. The bill is land time, 2.11% -> 3.29%, still well under the
-- 4.34% this pass started at. 14 is the setting if the look matters more than
-- the invasions; it is one constant either way.
--
-- Fixing this properly means the COARSE grid, not this cap: if a route never
-- crossed land there would be nothing to portage. That is NAVY_GRID_STRIDE
-- and its any-tile-is-wet rule, and it touches every map's balance.
--
-- 2026-09-03: SEVENTEEN BECAME SIX, and nothing was paid for it. The number
-- above was a bound on a symptom -- the coarse grid handing out legs that no
-- water could serve -- and that cause is gone: Navy's components are measured
-- on WATER TILES now and a coarse step is only taken where the two cells'
-- water actually touches (Navy.canStep), so a route that crosses land is not
-- laid in the first place. What is left for a portage to do is the job it was
-- named for: stepping over a BRIDGE. Dover, Gibraltar, Messina and the three
-- Danish belts are three to five pixels of land stamped across a real strait,
-- and a transport has to be able to cross one.
--
-- Re-swept on three seeds, 60 crossings a map, with everything else in:
--
--   cap    land time         longest walk    invasions landed (of 180)
--    17    0.01-0.70%           1-16                    180
--     6    0.01-0.65%           1-9                     177
--     0    0.00-0.20%           0-10                    113
--
-- 6 and 17 are the same crossing on almost every seed; what 6 buys is the
-- tail, where 17 still allowed a sixteen-tile march inland. 0 is not
-- available: refusing the bridges outright costs a third of every invasion,
-- and a transport that gives up is a worse artefact than one that spends six
-- ticks on a causeway.
local PORTAGE_MAX_RUN = 6
-- Consecutive ticks WITHOUT CLOSING ON ITS WAYPOINT before a transport gives
-- up and brings its men home, less the retreat malus -- thirty seconds.
-- Upstream gets this for free: its pathfinder answers NOT_FOUND and
-- TransportShipExecution hands the troops straight back. Here nothing ever
-- timed out a crossing, so refusing a route that does not exist would leave a
-- transport hugging a coastline for the rest of the round, immortal, because
-- only arrival deletes one.
--
-- KEYED ON PROGRESS, NOT ON HAVING A ROUTE, and that is not a detail: a first
-- draft counted ticks spent on the fallback instead, and sent home 81-107
-- transports a match that were steering themselves along a coast perfectly
-- well and getting closer every tick. Having no fine route is a reason to buy
-- another one. Not getting any nearer is the thing worth giving up over.
local STUCK_GIVEUP = 300

-- Longest run of consecutive land tiles in a fine route. Cheap: a leg is a
-- few dozen tiles and this is paid once, when the route is bought.
local function longestLandRun(map: TileMap.TileMap, route: { number }): number
	local best, cur = 0, 0
	for _, t in route do
		if TileMap.isLand(map, t) then
			cur += 1
			if cur > best then
				best = cur
			end
		else
			cur = 0
		end
	end
	return best
end
-- Cells one leg may expand. A leg is a single coarse cell long, so a window
-- of 30-odd tiles a side is the whole search space and this is generous for
-- it; it exists to bound the case where there is NO route and the search
-- fills the window before giving up. Tighter than the module default because
-- this one runs inside the tick, several times over, every tick.
-- THE CAP MUST EXCEED THE WINDOW, and at 600 against a ~780-tile window it
-- did not. That one relationship is most of this pass. Instrumenting
-- Navy.channel over a full us/ffa match, 1,898 of 10,794 leg searches failed
-- outright -- and a failed leg is exactly when a transport falls back to
-- steering itself, which is the only way it ever ends up on land. They were
-- not failing for want of a route: with `landCost` set EVERY tile in the
-- window is passable, so the portage attempt cannot fail for any reason
-- except running out of expansions first.
--
-- Sized against the window deliberately, not tuned: a leg is one coarse cell,
-- so the box its ends span is at most 8 tiles across and the window is
-- (8 + 2*PAD)^2 = 1,024 tiles. A cap above that can never be the thing that
-- stops the search, which makes the portage attempt a guarantee -- every leg
-- gets a fine route, and the greedy fallback below becomes the rare case it
-- was always meant to be rather than one leg in six.
--
-- Raising the pad WITHOUT raising the cap past the new window is the trap
-- here, and it was measured: pad 16 with cap 1500 gives a 1,600-tile window,
-- the cap starts binding again, and the water hit rate fell from 89% to 81%.
-- Move the two together or not at all. The tick cost is bounded by
-- TRANSPORT_BOAT_CHANNEL_PER_TICK legs, not by this.
local TRANSPORT_BOAT_CHANNEL_CAP = 1500
-- Slightly wider than Navy's own CHANNEL_PAD of 10: the water route round a
-- headland regularly bends further out than ten tiles, and every tile it
-- bends past the window reads as "no route".
local TRANSPORT_BOAT_CHANNEL_PAD = 12
-- Consecutive fallback ticks before a transport re-buys the channel search
-- this leg already failed. One second at TICK_RATE 10. It exists because the
-- failure cached in `legTo` is permanent for as long as the transport aims at
-- that waypoint, and the map underneath is not: a tick later the search
-- starts from a different tile, and from there the window may well solve.
local STUCK_REPATH = 10
-- The same, for a leg whose only route was refused as a walk. Ten times as
-- long, because that answer changes far more slowly than a failed search's.
local STUCK_REWALK = 100
-- The four rook steps the greedy fallback may take -- same order, same flat
-- layout and same reason as Navy's NEI4.
local FALLBACK_STEPS = { -1, 0, 0, -1, 0, 1, 1, 0 }
-- Waypoints one straight jump may skip. The route is cell anchors eight
-- tiles apart, so 64 is about five hundred tiles of open water -- past
-- Navy's own JUMP_MAX_TILES, which is the bound that actually binds.
local JUMP_AHEAD = 64

local function stepTransportBoats(self: Sim)
	local speed = Config.TRANSPORT_BOAT_SPEED
	local map = self.map
	local live = {}
	for _, b in self.transportBoats do
		if not b.active then
			continue
		end
		local e = b.ext
		local p = self.players[b.ownerId]
		if not p or not p.alive then
			Units.delete(self, b)
			continue
		end

		-- Walked in a LOCAL and written back once. Nothing reads the transport boat's
		-- tile between steps, and every write to it now costs a grid cell
		-- test (Units.move), so paying that TRANSPORT_BOAT_SPEED times a tick instead
		-- of once would be buying nothing.
		local tile = b.tile
		-- Whether this tick was spent following a fine route or steering by
		-- hand. Read once after the loop, to maintain `e.stuck`.
		local usedLeg = false
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
			-- LINE OF SIGHT OWNS THE OPEN WATER, the local A* owns the coast.
			-- The coarse waypoints are cell anchors EIGHT TILES APART, so a
			-- transport crossing open sea used to buy a fine route to each one
			-- in turn and draw a staircase with an eight-tile step -- every leg
			-- individually straight and the whole crossing a zigzag. This asks
			-- the only question that matters out there: how far along the route
			-- can it get in two straight runs? Answer that and an ocean crossing
			-- is two lines. It is upstream's arrangement exactly (its
			-- SmoothingWaterTransformer runs before anything sails), and it is
			-- CHEAPER than what it replaces -- measured over 60 crossings a map,
			-- turns per crossing 128/80/166/51 -> 114/51/160/24 on
			-- us/europe/china/medit and fine searches 62/71/59/47 -> 25/9/35/4.
			--
			-- THE TRAP: the run ends at a waypoint FURTHER along e.path, so
			-- e.pathIdx AND the local `wp` this loop tests arrival against both
			-- have to move. Leaving `wp` behind lets the route advance twice the
			-- moment the run passes through it.
			if e.leg == nil and (self.jumpBudget or 0) > 0 then
				local idx, run = Navy.straightJump(map, tile, e.path, e.pathIdx, JUMP_AHEAD)
				if run ~= nil and #run > 0 then
					self.jumpBudget -= 1
					e.pathIdx = idx
					e.leg = run
					e.legIdx = 1
					e.legTo = e.path[idx]
					e.legWalk = nil
					wp = e.path[idx]
				end
			end

			local leg = e.leg
			-- A NEW WAYPOINT, or a second chance at one this transport has been
			-- steering itself towards for a whole second. Caching the failure in
			-- `legTo` is what stops a dead search being re-bought several times a
			-- tick; without the retry beside it that cache is also a life
			-- sentence, and a transport that never gets a route is a transport
			-- hugging a coastline for the rest of the crossing. Zeroing `stuck`
			-- on the attempt is what spaces the retries out, and it does that
			-- whatever the speed -- an `== STUCK_REPATH` test would fire once per
			-- STEP rather than once per tick the moment speed rises above 1.
			--
			-- `legWalk` is what keeps that retry affordable, and it separates the
			-- two ways of having no route. A search that found NOTHING is worth
			-- repeating a second later: the window travels with the transport and
			-- the next one may well solve. A search that found a route and had it
			-- REFUSED for being a walk usually finds the same walk again from one
			-- tile away, so it waits ten times as long -- retrying those on the
			-- fast timer saturated the tick's allowance and took the mean tick
			-- from 1.35 ms to 5.3 ms.
			--
			-- It waits rather than stopping, and that distinction was measured
			-- too: never retrying a walk sent 81-107 transports a match home
			-- instead of 0-5. The retry is not redundant -- from a few tiles
			-- along the coast the window often does solve -- it was only ever
			-- too frequent.
			local rebuy = e.legTo ~= wp
			local wait = (e.legWalk == wp) and STUCK_REWALK or STUCK_REPATH
			if not rebuy and e.leg == nil and (e.stuck or 0) >= wait then
				rebuy = true
				e.stuck = 0
			end
			if rebuy then
				leg = nil
				if (self.channelBudget or 0) > 0 then
					-- ONE search per waypoint, and a failure is remembered as
					-- `legTo` set with no leg: a leg the window cannot solve
					-- must not re-buy the same dead search three times a tick
					-- for as long as the transport boat is aiming at it. A search the
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
					--
					-- AND THE PORTAGE IS WHERE ALL THE REMAINING OVERLAND
					-- SAILING WAS. Instrumented over a full us/ffa match once
					-- the fallback below stopped stepping ashore: of 2,930
					-- transport-ticks on land, 2,683 were a transport dutifully
					-- FOLLOWING its fine route, and ZERO were the fallback.
					-- Every one of them was a portage, and the longest ran 23
					-- tiles -- which is not an isthmus, it is a coarse route
					-- laid across a county that the search then dutifully
					-- walked. PORTAGE_MAX_RUN is the line between the two.
					-- Past it the leg is refused and the transport hugs the
					-- coast instead, which is water by construction, and
					-- STUCK_GIVEUP sends it home if that never resolves.
					e.legWalk = nil
					e.leg = Navy.channel(map, tile, wp, TRANSPORT_BOAT_CHANNEL_CAP, TRANSPORT_BOAT_CHANNEL_PAD)
					if e.leg == nil then
						local portage = Navy.channel(map, tile, wp, TRANSPORT_BOAT_CHANNEL_CAP, TRANSPORT_BOAT_CHANNEL_PAD, PORTAGE_COST)
						if portage ~= nil then
							if longestLandRun(map, portage) <= PORTAGE_MAX_RUN then
								e.leg = portage
							else
								e.legWalk = wp
							end
						end
					end
					e.legIdx = 1
					e.legTo = wp
					leg = e.leg
				end
			end
			if leg ~= nil then
				local nxt = leg[e.legIdx]
				if nxt ~= nil then
					e.legIdx += 1
					usedLeg = true
					tile = nxt
					if tile == wp then
						e.pathIdx += 1
						e.leg = nil
					end
					continue
				end
			end
			-- No channel for this leg. Steer at the waypoint, hugging the water.
			--
			-- WATER FIRST, ALWAYS. This is the greedy fallback and it is the
			-- one place a transport can end up on dry land, so it is the whole
			-- of the "boats sail through the ground" problem. Upstream's
			-- equivalent refuses land outright -- WarshipExecution's
			-- `bestNeighborToward` skips any neighbour failing `isWater`, and
			-- its pathfinder answers NOT_FOUND rather than routing over a
			-- field. Conquest cannot refuse outright, because the coarse grid
			-- calls a cell navigable when ANY tile in it is water, so a route
			-- legitimately crosses a land bridge -- Dover, Gibraltar, the
			-- Danish belts, all of them in the generated masks -- and refusing
			-- strands the crossing rather than fixing it. MEASURED, because it
			-- was tried: holding station instead of stepping ashore took land
			-- time from 4.34% of transport ticks to 2.91% and left transports
			-- becalmed on 72% of them, average crossing 63 seconds. A boat
			-- parked at sea is a worse artefact than a boat on a beach.
			--
			-- So land is ranked LAST rather than forbidden: any floating
			-- neighbour beats any dry one, INCLUDING one that does not close
			-- the distance, and that is exactly what makes this go round a
			-- headland instead of over it. Nearest the waypoint among equals.
			--
			-- `prevTile` is the anti-oscillation story. The rule this replaces
			-- demanded a sidestep strictly REDUCE Chebyshev distance, which
			-- did keep a transport off a two-tile loop -- but it also forbade
			-- going the long way round anything, which is the manoeuvre a
			-- coast asks for. Refusing to step straight back where it came
			-- from buys the same guarantee and allows the detour. A three-tile
			-- loop in a blind bay is still possible; `stuck` buys a fresh
			-- search out of it.
			local x, y = tile % W, (tile - tile % W) / W
			local wx, wy = wp % W, (wp - wp % W) / W
			--
			-- ROOK STEPS ONLY, matching Navy.channel's NEI4: one axis at a time,
			-- so a transport steering itself moves the way one following a fine
			-- route does. A fallback that still cut diagonals would be the one
			-- place a hull crabbed across the map.
			--
			-- 2026-09-03: WATER OR NOTHING. Land used to be RANKED last rather
			-- than forbidden, and while a hull is afloat those are the same
			-- rule -- a floating neighbour always exists, so it always wins.
			-- They come apart the moment a hull is ASHORE, which a portage puts
			-- it, and then "last" means "the whole county": measured in a live
			-- 70-empire europe match, a transport that stepped over a six-tile
			-- isthmus walked SIXTY-EIGHT more tiles inland in a dead straight
			-- line, because every candidate was land and the Manhattan
			-- tie-break marched it at the waypoint. That is the complaint this
			-- pass exists to fix and no cap on the portage can reach it -- the
			-- route was six tiles; the other sixty-two were here.
			--
			-- Refusing outright was tried in 2026-09-01 and measured WORSE
			-- (transports becalmed on 72% of their ticks). The premise has
			-- since gone: the coarse grid used to hand out legs that no water
			-- could serve, and Navy's tile-level components mean it no longer
			-- does, so a hull that runs out of route now has water beside it
			-- almost always. Re-measured below rather than assumed.
			local bestT, bestD = nil, math.huge
			for k = 1, #FALLBACK_STEPS, 2 do
				local cx, cy = x + FALLBACK_STEPS[k], y + FALLBACK_STEPS[k + 1]
				if cx >= 0 and cx < W and cy >= 0 and cy < H then
					local t = cy * W + cx
					if t ~= e.prevTile and not TileMap.isLand(map, t) then
						-- MANHATTAN, because the steps are now rook steps and
						-- it is exact for them: every correct step strictly
						-- reduces it, where Chebyshev leaves the two axes of a
						-- diagonal approach tied and picks between them by
						-- scan order.
						local d = math.abs(wx - cx) + math.abs(wy - cy)
						if d < bestD then
							bestT, bestD = t, d
						end
					end
				end
			end
			if bestT == nil then
				break
			end
			e.prevTile = tile
			tile = bestT
			if tile == wp then
				e.pathIdx += 1
			end
		end
		-- Consecutive ticks with no fine route to follow. It counts FALLBACK
		-- ticks rather than ticks spent standing still, and that is the point:
		-- a transport hugging its way round a bay is moving the whole time and
		-- is precisely the one that needs another search bought for it.
		if usedLeg then
			e.stuck = 0
		else
			e.stuck = (e.stuck or 0) + 1
		end
		-- CLOSING, OR NOT. The best Chebyshev distance this transport has ever
		-- managed to the waypoint it is currently steering for; reaching a new
		-- waypoint resets it, since that is progress by definition. Anything
		-- that improves on the record is progress too, however slowly, and a
		-- transport working its way round a headland improves on it constantly.
		local wpNow = e.path[e.pathIdx]
		if wpNow == nil then
			e.idle = 0
		else
			local wnx = wpNow % W
			local wny = (wpNow - wnx) / W
			local tnx = tile % W
			local tny = (tile - tnx) / W
			local d = math.max(math.abs(wnx - tnx), math.abs(wny - tny))
			if e.idleWp ~= wpNow or d < (e.bestD or math.huge) then
				e.idleWp = wpNow
				e.bestD = d
				e.idle = 0
			else
				e.idle = (e.idle or 0) + 1
			end
		end
		-- Half a minute without getting any nearer is not a crossing that is
		-- about to work. Same disposal as running out of route short of the
		-- beach below: the men come home less the retreat malus, because
		-- deleting an army outright is the one outcome nobody can read.
		if (e.idle or 0) >= STUCK_GIVEUP then
			p.troops += b.troops * (1 - Config.RETREAT_PENALTY)
			Units.delete(self, b)
			continue
		end
		Units.move(self, b, tile)

		-- Close enough to the beach: land. The last waypoint is a WATER tile
		-- beside `dst`, never `dst` itself, so arrival is a proximity test
		-- rather than an equality one.
		local x, y = tile % W, (tile - tile % W) / W
		local dx0, dy0 = e.dst % W, (e.dst - e.dst % W) / W
		local far = math.max(math.abs(x - dx0), math.abs(y - dy0))
		if far <= speed or e.pathIdx > #e.path then
			if far <= (Config.TRANSPORT_BOAT_LAND_RADIUS or 12) then
				landTransportBoat(self, b)
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
	self.transportBoats = live
end

-- Every transport boat at sea, for the client to draw. Same shape discipline as
-- Sim.armies: ids and numbers only, no names, no tables per field.
function Sim.transportBoatSnapshot(self: Sim): { any }
	local out = {}
	for _, b in self.transportBoats do
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
-- human and each client keeps the rows addressed to its SIDE -- its own
-- wars and, in a team game, every teammate's (NationLabels.setArmies).
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
		-- A faux teammate is a bot in every mechanical sense, but it sits on
		-- a human's side, and that side sees every war it is in -- so a seat
		-- on a team is entitled to a number exactly as a person is.
		local outgoing = not attacker.isBot
			or (self.teamCount > 0 and self.teamOf[atk.attackerId] ~= nil)
		local incoming = (not target.isBot or (self.teamCount > 0 and self.teamOf[atk.targetId] ~= nil))
			and attacker.tier ~= ARMY_TIER_TRIBE
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

-- Where an empire died, as a tile. While it still holds ground that is the
-- centroid of what is left; once the last tile is gone the centroid is 0/0
-- and meaningless, so Sim.conquer's stamp is used instead.
local function deathTile(p: Player): number
	if p.tileCount > 0 then
		local x = math.clamp(math.floor(p.sumX / p.tileCount), 0, W - 1)
		local y = math.clamp(math.floor(p.sumY / p.tileCount), 0, H - 1)
		return y * W + x
	end
	return p.deathTile or 0
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
	local taken = 0
	if captor and captor.alive and victim.gold > 0 then
		-- conquerGoldAmount (Config.ts:621-630): a Bot and a Nation both hand
		-- over the whole treasury, a HUMAN only half. Branch rather than a
		-- flat multiply, because trade and rail payouts make gold fractional
		-- and `math.floor(gold * 1.0)` is not the same number as `gold`.
		local share = Config.TIER[victim.tier].CONQUER_GOLD_SHARE
		if share >= 1 then
			taken = victim.gold
		else
			taken = math.floor(victim.gold * share)
		end
		captor.gold += taken
	end
	victim.gold = 0

	-- This is the single largest payment in the game and it used to land in
	-- SILENCE -- the treasury readout jumped while the player was looking at
	-- the front they were pushing, so the one moment worth celebrating was
	-- the one moment with no feedback. Recorded here rather than sent from
	-- here because the sim owns no remotes.
	table.insert(self.conquestEvents, {
		captorId = captorId,
		victimId = victim.id,
		gold = taken,
		tile = deathTile(victim),
	})

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

-- ============================================================== elimination ==

-- END AN EMPIRE ON DEMAND, through the same door a conqueror sends one
-- through. The /lose test command is this call and nothing else, so the losing
-- sequence -- the skull on the death tile, the payout receipt, the revive
-- offer, and a tutorial's fail card -- can be watched without being ground
-- down for ten minutes first.
--
-- IT GOES THROUGH collapsePlayer. A shortcut that zeroed tileCount by hand
-- would prove that a number can be set to zero; what is worth testing is the
-- path in front of it -- the treasury changing hands, the attacks cancelling,
-- the conquest event the server turns into a skull, and the land walking away
-- a bounded slice per tick instead of flipping every tile it owns inside one
-- frame.
--
-- `captorId` nil, 0, or an empire that is not standing is the death with NO
-- CLAIMANT: the land goes back to open ground and the treasury is destroyed
-- rather than paid. `killedBy` is cleared to match -- collapsePlayer stamps it
-- unconditionally, and Money reads that field to decide who is credited with
-- the kill. Empire 0 is not an empire.
function Sim.eliminate(self: Sim, id: number, captorId: number?): boolean
	local victim = self.players[id]
	if victim == nil or not victim.alive or not victim.spawned then
		return false
	end
	local by = captorId or 0
	if by ~= 0 then
		local captor = self.players[by]
		if captor == nil or not captor.alive or by == id then
			by = 0
		end
	end
	collapsePlayer(self, victim, by)
	if by == 0 then
		victim.killedBy = nil
	end
	return true
end

local LN2 = math.log(2)

local function sigmoid(v: number, decay: number, mid: number): number
	return 1 / (1 + math.exp(-decay * (v - mid)))
end

-- Tick budget for one attack, from the width of its own front. Uses the
-- tracked border COUNT, not the heap size: the heap holds duplicates by
-- design (lazy decrease-key) and would wildly overstate the front.
local function tilesPerTick(self: Sim, atk: Attack, defender: Player?, border: number): number
	-- "Special Forces (2x Attack Speed)!" (Products) scales the budget and
	-- NOTHING ELSE about the push. This function is what "attack speed" means
	-- in this sim -- how many tiles one attack may take in a tick -- while the
	-- troop cost of each tile is settled per tile in the attrition block
	-- below. So the land arrives twice as fast and costs exactly what it
	-- always cost, which is the whole of what the product's name promises.
	--
	-- AFTER THE CLAMP, not before. The clamp is upstream's shape for how a
	-- push's strength converts into ground; scaling its INPUT would be a
	-- different effect and a silently capped one -- an attacker already at
	-- BUDGET_RATIO_MAX would have bought nothing at all.
	--
	-- One array read per tile, deliberately not hoisted the way sizeDebuff and
	-- lossPenalty were: those cost an exp and two pows each, this is an index
	-- into a dense array. Reading it live rather than stamping it on the
	-- attack also means a boost bought mid-push applies to the push already
	-- running, which is the answer somebody who has just paid expects.
	local attacker = self.players[atk.attackerId]
	local speed = (attacker ~= nil and attacker.attackSpeed) or 1
	if defender then
		return math.clamp(
			(Config.SPEED_RATIO_DIV * atk.troops / math.max(defender.troops, 1)) * 2,
			Config.BUDGET_RATIO_MIN,
			Config.BUDGET_RATIO_MAX
		) * border * Config.BUDGET_PLAYER_MULT * speed
	end
	return border * Config.BUDGET_NEUTRAL_MULT * speed
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
	borderSize: number,
	defenderPosts: boolean
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
		-- `magScale` is 1 for every ordinary attacker on unclaimed ground --
		-- upstream's bot-defender discount needs a defender and there is none
		-- here -- so this term is a no-op except for the TUTORIAL BUFF, which
		-- processAttack folds into it. A buffed student takes OPEN LAND at the
		-- same multiple it takes an enemy's; leaving it off would have made
		-- the buff invisible for the whole land-grab, which is most of the
		-- tutorial.
		return mag * magScale / div, 0,
			base * shaped / math.max(tilesPerTick(self, atk, nil, borderSize), 1e-6)
	end

	-- DEFENSE POSTS. Upstream Config.ts `attackLogic`:
	--     if (defender !== null && input.defenderHasDefensePost) {
	--         mag *= this.defensePostDefenseBonus();    // 5
	--         tileCost *= this.defensePostSpeedBonus(); // 3
	--     }
	-- where `defenderHasDefensePost` is hasUnitNearby(tile, defensePostRange(),
	-- DefensePost, defender) (AttackExecution.ts:331-340): the DEFENDER'S own
	-- posts, FINISHED ones only, within 30 tiles of the tile being taken. Both
	-- multipliers land on these two locals because `mag` is the attacker's troop
	-- cost per tile and `speed` is what multiplies into the tick-budget cost
	-- below -- the two halves of upstream's mag and tileCost.
	--
	-- BELOW THE terra-nullius RETURN ON PURPOSE. A post defends YOUR ground;
	-- open land beside it is still open land, and upstream guards this with
	-- `defender !== null` for the same reason.
	--
	-- AND IT DOES NOT TOUCH defenderTroopLoss, which stays plain density. A post
	-- buys time and makes ground expensive; it never saves the men standing on
	-- it.
	--
	-- THE ZERO-POST CASE COSTS NOTHING. `defenderPosts` is hoisted once per
	-- attack per tick in processAttack (one counter read), so an empire that owns
	-- no post never walks the unit grid -- which is what makes this affordable on
	-- a loop that conquers up to Config.GLOBAL_TILE_BUDGET tiles a tick.
	-- Units.hasNearby is the early-exit, zero-allocation form written for exactly
	-- this call site; upstream's nearbyUnits-then-filter shape allocates an array
	-- per conquered tile and is not an option here.
	if
		defenderPosts
		and Units.hasNearby(self, tile, Config.DEFENSE_POST_RANGE, Units.DEFENSE_POST, defender.id)
	then
		mag *= Config.DEFENSE_POST_DEFENSE_BONUS
		speed *= Config.DEFENSE_POST_SPEED_BONUS
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
		-- Who is doing this to them. Once per attack per TICK, not per tile,
		-- and a plain store on a table already in hand. If they go on to die
		-- to something that cannot claim them -- a crater, a boat landing --
		-- checkElimination pays whoever this names.
		defender.lastHitBy = atk.attackerId
	end

	-- AN ALLIANCE MADE MID-PUSH ENDS THE PUSH (upstream AttackExecution.tick:
	-- a target that has become friendly retreats the attack). The men come
	-- home less the retreat malus, as a transport boat's do.
	if defender and Sim.friendly(self, atk.attackerId, atk.targetId) then
		endAttack(self, atk, true, Config.RETREAT_PENALTY)
		return globalBudget
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
	-- Does the defender own a FINISHED defense post anywhere at all? One counter
	-- read, and it is what keeps the per-tile grid query off the hot loop for
	-- every empire that owns none -- which is most of them for most of a round.
	-- Completed only: a half-built post does not defend (upstream's
	-- hasUnitNearby skips units under construction, UnitGrid.ts:140) and
	-- Units.hasNearby defaults to the same rule, so the two agree.
	local defenderPosts = false
	if defender then
		defenderPosts = Units.completedCount(self, defender.id, Units.DEFENSE_POST) > 0
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

	-- THE TRAITOR PENALTY (Alliances; upstream Config.ts:828-829). A defender
	-- who broke an alliance inside the last 30 s costs the attacker HALF the
	-- troops per tile and four fifths of the tick budget, so a betrayal is
	-- answered by everyone on that border being able to eat you for a while.
	-- Hoisted here for the reason the post flag is: constant for the tick.
	-- MULTIPLIED, not assigned, so it stacks on the tier scale above.
	if defender then
		magScale *= Alliances.traitorLossMod(self, defender.id)
		speedPenalty *= Alliances.traitorCostMod(self, defender.id)
		-- HUNTER AIs take AI ground cheaper (see Config.BOT_HUNTER_MAG).
		-- isBot on the defender, so a person is never cheaper to hunt.
		if attacker.aiHunter and defender.isBot then
			magScale *= Config.BOT_HUNTER_MAG
		end
	end

	-- CONQUEST DEVIATION (tutorial): ONE EMPIRE FIGHTS AT A MULTIPLE OF
	-- EVERYONE ELSE. `buff` is 1 + Tutorial.STUDENT_BUFF for the student of a
	-- tutorial round and exactly 1 in every other round, so an ordinary match
	-- is bit-for-bit what it was.
	--
	-- IT RIDES ON `magScale` because that is already "the multiplier on mag,
	-- hoisted because it cannot change between tiles", and `mag` is the
	-- ATTACKER'S TROOP COST PER TILE. So DIVIDING it is the same "more ground
	-- per army" that Config's HUMAN_VS_BOT_MAG comment describes -- 1.35x the
	-- ground for the same men -- and MULTIPLYING it when the student is the
	-- one being invaded makes them 1.35x dearer to take. Both halves are the
	-- same number because "35% stronger" is one statement, not two dials.
	--
	-- DELIBERATELY NOT ON `speed`/`cost`: that is the tick budget, i.e. how
	-- fast a front is allowed to move. Buffing it would change the PACE of
	-- the round -- the one lever Config reserves for map pacing -- rather
	-- than the strength of an empire, and the student would watch a front
	-- crawl at the same rate while the numbers said they were winning.
	local buff = self.buffMult or 1
	if buff ~= 1 and self.buffId ~= 0 then
		if atk.attackerId == self.buffId then
			magScale /= buff
		elseif atk.targetId == self.buffId then
			magScale *= buff
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
			-- PUT IT BACK. `tile` has already left the heap, and breaking with
			-- its borderSet/prio/sum bookkeeping still standing left a tile the
			-- attack counts but can never pop again -- borderCount then drifts up
			-- for the life of the attack, and it feeds tilesPerTick and the army
			-- label's position. Re-pushing at its stored priority is exact.
			local pr = atk.prio[tile]
			if pr ~= nil then
				Heap.push(atk.frontier, tile, pr)
			end
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
				speedPenalty, magScale, borderSize, defenderPosts)

		budget -= tileCost
		-- NEVER BELOW ZERO. The `troops < 1` test that ends an attack sits at the
		-- TOP of this loop, so the last tile of a tick can overshoot and leave a
		-- negative standing for the next one -- where launchAttack's annihilation
		-- loop reads it as min(other.troops, committed) and hands the
		-- counter-attacker free men. It also corrupts the AI's incoming and
		-- pressure sums, which add these figures up raw.
		atk.troops = math.max(0, atk.troops - attackerLoss)
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

-- ---------------------------------------------------------------- sorties --
--
-- AN AI AIRFIELD FLIES, RARELY (owner, 2026-09-21: "make AI spawn airbase and
-- artillery strike relatively rarely"). Only a flier owns one (see
-- shouldBuildStructure), and a rearmed field rolls Config.BOT_AIRSTRIKE_CHANCE
-- on each think beat before it flies at all, so a bot sortie is something a
-- neighbour sees every couple of minutes, not the metronome a person's field
-- can be. The order goes through Airstrikes.order -- the person's route, with
-- its cooldown, range and gold checks -- so a bot can do nothing a person
-- cannot.
--
-- THE AIMPOINT: the nearest hostile building inside AIRFIELD_RANGE (the disc
-- around a city is ~300 enemy tiles, which already saturates the troop kill,
-- and the 600 off the building is the part only a building gives); with none,
-- the heaviest front this empire is on, pushed a few tiles past the line onto
-- the enemy's side; with neither, the nearest hostile ground the battery's
-- sampler finds. Never friendly ground, never nobody's, never out of range: a
-- bomb on empty land is a sortie spent for nothing.
local sortieScratch: { any } = {}
local sortieD2: { number } = {}

-- The tile at (fx, fy) if it is hostile to `p` and inside `range` of the
-- field at `u`, else nil.
local function hostileTileFor(self: Sim, p: Player, u: any, fx: number?, fy: number?, range: number): number?
	if fx == nil or fy == nil then
		return nil
	end
	local x, y = math.floor(fx + 0.5), math.floor(fy + 0.5)
	if not TileMap.inBounds(x, y) then
		return nil
	end
	local t = y * W + x
	local o = buffer.readu8(self.map.owner, t)
	if o == 0 or o == p.id or self.players[o] == nil or Sim.friendly(self, p.id, o) then
		return nil
	end
	local ux = u.tile % W
	local uy = (u.tile - ux) / W
	local dx, dy = x - ux, y - uy
	if dx * dx + dy * dy > range * range then
		return nil
	end
	return t
end

-- Declared ahead of botAirstrike (2026-09-21): heaviestFront and
-- nearestEnemyGround are DEFINED below, past the sortie code that calls
-- them, and a later `local function` is not in scope up here -- so each call
-- resolved to a nil global and every bot sortie that fell back to the front
-- threw "attempt to call a nil value" (seen at Sim:3900 in a Tokyo round).
-- Two forward declarations; the definitions below assign them.
local heaviestFront: (Sim, Player, boolean?) -> (number?, number?)
local nearestEnemyGround: (Sim, Player) -> (number?, number?)

local function botAirstrike(self: Sim, p: Player)
	if Units.count(self, p.id, Units.AIRFIELD) <= 0 then
		return
	end
	local fields = Units.ofType(self, Units.AIRFIELD)
	if fields == nil then
		return
	end
	local chance = Config.BOT_AIRSTRIKE_CHANCE or 0.1
	local range = Config.AIRFIELD_RANGE or 120
	for _, u in fields do
		if u.active and u.ownerId == p.id and not u.underConstruction and not Units.inCooldown(u) then
			if self.rng:NextNumber() >= chance then
				continue
			end
			-- Nearest hostile building in range, sites included.
			local dst: number? = nil
			local bestD = math.huge
			local n = Units.nearby(self, u.tile, range, Units.STRUCTURE_TYPES, sortieScratch, sortieD2, nil, true)
			for i = 1, n do
				local s = sortieScratch[i]
				sortieScratch[i] = nil
				if
					s.active
					and s.ownerId ~= 0
					and s.ownerId ~= p.id
					and self.players[s.ownerId] ~= nil
					and not Sim.friendly(self, p.id, s.ownerId)
					and sortieD2[i] < bestD
				then
					bestD = sortieD2[i]
					dst = s.tile
				end
			end
			if dst == nil then
				local fx, fy = heaviestFront(self, p, true)
				if fx ~= nil and fy ~= nil then
					-- The front's centroid sits ON the line; step it a few
					-- tiles further from home so it reads as the enemy's ground.
					local cx = p.sumX / math.max(p.tileCount, 1)
					local cy = p.sumY / math.max(p.tileCount, 1)
					local dx, dy = fx - cx, fy - cy
					local len = math.sqrt(dx * dx + dy * dy)
					if len > 1 then
						fx += dx / len * 4
						fy += dy / len * 4
					end
					dst = hostileTileFor(self, p, u, fx, fy, range)
				end
			end
			if dst == nil then
				local gx, gy = nearestEnemyGround(self, p)
				dst = hostileTileFor(self, p, u, gx, gy, range)
			end
			if dst ~= nil then
				Airstrikes.order(self, p.id, u.tile, dst)
			end
		end
	end
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
	-- Only consulted when BOTS_BUILD_SAMS is true; see it for why it is not.
	[Units.SAM_LAUNCHER] = 0.20, -- SAM_RATIO_BY_DIFFICULTY[Medium]
	[Units.MISSILE_SILO] = 0.20,
	-- A gun per two city levels (FIRST_ARTILLERY_RATIO puts the first at the
	-- same bar), Config.BOT_MAX_ARTILLERY at most, only ever placed facing an
	-- enemy (botArtillery) -- and only by the BOT_ARTILLERY_SHARE of empires
	-- that rolled gunner. See shouldBuildStructure.
	[Units.ARTILLERY] = 0.5,
	-- One airfield (MAX_AIRFIELD), for the BOT_AIRFIELD_SHARE that rolled
	-- flier, at floor(levels * 0.34) >= 1: the third city level.
	[Units.AIRFIELD] = 0.34,
}
-- A coastal empire wants far fewer factories, because its ports are already
-- earning and a factory only unlocks the rail beside them.
local FACTORY_COASTAL_RATIO_MULT = 0.33
local MAX_MISSILE_SILOS = 3
-- The same ceiling for batteries, and for the silo's reason: the ratio is a
-- SUM OF LEVELS, so without a cap a big empire's gun count tracks its city
-- growth forever.
local MAX_ARTILLERY = Config.BOT_MAX_ARTILLERY or 2
-- See shouldBuildStructure. WAS 1.0 -- one city level bought the first gun --
-- until the owner asked for AI guns "relatively rarely" (2026-09-21): at 0.5
-- the first gun waits for the second city level, about five minutes in on
-- the measurement there, and only a gunner (Config.BOT_ARTILLERY_SHARE) wants
-- it at all.
local FIRST_ARTILLERY_RATIO = 0.5
-- One field per flier, ever (2026-09-21). See botAirstrike for the sorties.
local MAX_AIRFIELD = 1
-- BOTS DO NOT BUILD ANTI-NUKE TOWERS (owner, 2026-09-16: "make bots unable to
-- build anti nukes"). Unlike the silo above, the SAM had NO ceiling at all: its
-- bar is floor(cityCount * ratio) and cityCount is a SUM OF LEVELS, so bot
-- anti-nuke coverage tracked city growth upward forever. Against
-- Nukes.CFG.INTERCEPT_ANYWHERE -- which lets a tower engage every tile of an
-- arc rather than only its middle -- that ends in a late game where no nuke
-- ever lands. That is a weapon deleted, not a defence added.
--
-- TO BRING THEM BACK RARELY instead: set this true and drop the ratio above to
-- about 0.02, which is one tower per fifty city levels rather than one per
-- five. A cap in the shape of MAX_MISSILE_SILOS would be the other half.
local BOTS_BUILD_SAMS = false
-- The FIRST silo comes at a lower bar than the ones after it, so a nation
-- starts nuking while the game is still going.
local FIRST_MISSILE_SILO_RATIO = 0.4
-- AND THE FIRST FACTORY COMES AT A LOWER BAR THAN THE ONES AFTER IT, the same
-- shape as the silo above and for a harder reason: a factory is the ONLY door
-- to the rail network, so an empire without one has no railway and dispatches
-- no trains at all. The ratio above needs floor(cityCount * 0.75) to clear 1 --
-- and 0.2475 once the empire is coastal, which nearly every one is, since PORT
-- is first in BUILD_ORDER and is always wanted -- so the first factory waits on
-- the FIFTH city level.
--
-- MEASURED, 72 bots on us, seed 777: the first factory anywhere on the map
-- landed at 8.8 minutes and the whole map still held THREE of them at ten,
-- i.e. a match of ordinary length ended with no railway on it and no train
-- ever drawn. At 0.5 the first one needs two city levels: same run, 8
-- factories and 93 rails at 8.6 minutes, 32 and 231 at ten.
--
-- It moves the rail curve EARLIER, it does not steepen it. The same run
-- unpatched reaches 43 factories / 354 rails / 73% of all gold created by
-- minute 25; patched it reaches 51 / 435 / 83% by minute 15. Rail overtaking
-- trade late is the payout curve's doing and predates this line -- see
-- Config.TRAIN_GOLD_SELF if that is what wants cutting.
local FIRST_FACTORY_RATIO = 0.5
local BUILD_ORDER = { Economy.PORT, Economy.FACTORY, Units.SAM_LAUNCHER, Units.MISSILE_SILO, Units.ARTILLERY, Units.AIRFIELD }

-- upstream `unitsOwned` is the SUM OF LEVELS, which is what Units.count
-- returns -- a level-3 city counts as three.
local function shouldBuildStructure(self: Sim, p: Player, utype: number, cityCount: number, coastal: boolean): boolean
	-- See BOTS_BUILD_SAMS. This is the single authority on it; the ratio entry
	-- is left at upstream's figure so that re-enabling them is one word.
	if utype == Units.SAM_LAUNCHER and not BOTS_BUILD_SAMS then
		return false
	end
	-- THE FACTORY IS DISABLED (Config.FACTORIES_ENABLED, 2026-09-18). Economy.canBuild
	-- would refuse it anyway; this skips the placement probes so a bot does not
	-- spend its build pass failing to raise one.
	if utype == Economy.FACTORY and not Config.FACTORIES_ENABLED then
		return false
	end
	local ratio = STRUCTURE_RATIO_PER_CITY[utype]
	if ratio == nil then
		return false
	end
	if utype == Economy.FACTORY and coastal then
		ratio *= FACTORY_COASTAL_RATIO_MULT
	end
	local owned = Units.count(self, p.id, utype)
	-- See FIRST_FACTORY_RATIO. Applied AFTER the coastal multiplier on purpose,
	-- so it replaces that bar rather than being cut by it: the point is that
	-- every empire gets on the rails once, and only the SECOND factory onward
	-- is a question about how coastal it is.
	if utype == Economy.FACTORY and owned == 0 then
		ratio = FIRST_FACTORY_RATIO
	end
	if utype == Units.MISSILE_SILO then
		if owned >= MAX_MISSILE_SILOS then
			return false
		end
		if owned == 0 then
			ratio = FIRST_MISSILE_SILO_RATIO
		end
	end
	if utype == Units.ARTILLERY then
		-- RARELY (owner, 2026-09-21: "make AI spawn airbase and artillery
		-- strike relatively rarely"). Most empires never want one: the roll
		-- against Config.BOT_ARTILLERY_SHARE is made once, the first time
		-- this empire reaches the gun on BUILD_ORDER, and kept for the round.
		if p.gunner == nil then
			p.gunner = self.rng:NextNumber() < (Config.BOT_ARTILLERY_SHARE or 0.3)
		end
		if not p.gunner or owned >= MAX_ARTILLERY then
			return false
		end
		-- Measured, 20 bots on us/20260921: at 5.3 minutes eighteen empires
		-- hold two city levels and four hold four, so a bar of
		-- floor(levels * 0.25) would have put the first bot gun past the
		-- length of most rounds. FIRST_ARTILLERY_RATIO 0.5 is the second
		-- level; it was 1.0 (the first) before the owner asked for rare.
		if owned == 0 then
			ratio = FIRST_ARTILLERY_RATIO
		end
	end
	if utype == Units.AIRFIELD then
		-- The same once-per-empire roll for the field (Config.BOT_AIRFIELD_SHARE),
		-- and one field is all a flier ever raises. botAirstrike flies it.
		if p.flier == nil then
			p.flier = self.rng:NextNumber() < (Config.BOT_AIRFIELD_SHARE or 0.2)
		end
		if not p.flier or owned >= MAX_AIRFIELD then
			return false
		end
	end
	local target = math.floor(cityCount * ratio)
	if utype == Economy.PORT then
		-- CONQUEST DEVIATION, and a deliberate one. floor(1 * 0.75) is zero, so
		-- upstream's rule makes an empire wait for its SECOND city before it
		-- wants a port -- measured at eight minutes into a 69-empire match, with
		-- no trading transport boat on the map before then. Naval trade is the thing ports
		-- exist for; an empire that owns a city wants one. A landlocked empire
		-- asks for it too and simply fails every placement probe, which costs a
		-- few thousand tile reads and falls through to the next kind.
		target = math.max(1, target)
	end
	return owned < target
end

local function structureGold(self: Sim, p: Player, utype: number): number
	if
		utype == Economy.CITY
		or utype == Economy.PORT
		or utype == Economy.FACTORY
		or utype == Economy.DEFENSE_POST
		or utype == Economy.ARTILLERY
		or utype == Economy.AIRFIELD
	then
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
-- `atX`/`atY`/`atSpread` aim the probes somewhere other than the middle of the
-- country, which is what a DEFENSE POST needs: a wall belongs on the front the
-- army is coming down, not in the capital. Omitted, this is the centroid placer
-- it has always been, bit for bit.
local function tryPlace(
	self: Sim,
	p: Player,
	utype: number,
	atX: number?,
	atY: number?,
	atSpread: number?
): boolean
	local rng = self.rng
	local cx = atX or p.sumX / p.tileCount
	local cy = atY or p.sumY / p.tileCount
	local spread = atSpread
		or math.max(Config.STRUCTURE_MIN_DIST * 2, math.sqrt(p.tileCount) * 0.6)
	-- Cities, ports and factories are STATIONS and go through Economy, which
	-- owns the rail graph. A silo or a SAM is a plain unit -- putting one in
	-- structList would make it a train stop and a trade partner.
	--
	-- A DEFENSE POST is neither, and still comes through Economy: it is never
	-- promoted to a station (stepSites promotes only the three station kinds),
	-- but its PRICE and its paid-for counter live in Economy, and the server's
	-- build reply reads that same ladder. Pricing the bot's post off Units.cost
	-- instead would give one building two prices on two different bases.
	-- ...AND SO DOES A SAM LAUNCHER, since 2026-09-14: a player can buy one
	-- now, the server prices that build off Economy.cost, and a bot pricing the
	-- same tower off Units.cost would give ONE BUILDING TWO PRICES ON TWO
	-- DIFFERENT BASES -- Units.cost counts the sum of levels (sites included)
	-- where Economy counts min(owned, built). That is the trap the paragraph
	-- above records for the post; this is the same trap, avoided the same way.
	local viaEconomy = utype == Economy.CITY
		or utype == Economy.PORT
		or utype == Economy.FACTORY
		or utype == Economy.DEFENSE_POST
		or utype == Units.SAM_LAUNCHER
		-- ...AND THE BATTERY (2026-09-21), same trap, same way out.
		or utype == Units.ARTILLERY
		-- ...AND THE AIRFIELD, priced on Economy's ladder like the battery.
		or utype == Units.AIRFIELD
	-- UP BEFORE OUT (Config.BOT_UPGRADE_BIAS). Only for the centroid placer:
	-- a post or a battery aimed at a front is a new building by nature. Aiming
	-- Economy.build at one of our own stations' tiles IS the upgrade path --
	-- canBuild finds it in range and answers "upgrade". A random pick among the
	-- ones below max level, so levels spread across the country.
	if atX == nil and (utype == Economy.CITY or utype == Economy.PORT)
		and rng:NextNumber() < (Config.BOT_UPGRADE_BIAS or 0)
	then
		local pick, seen = nil, 0
		for _, s in self.structList do
			if s.ownerId == p.id and s.kind == utype and s.unit.level < Config.STRUCTURE_MAX_LEVEL then
				seen += 1
				if rng:NextInteger(1, seen) == 1 then
					pick = s
				end
			end
		end
		if pick ~= nil and (Economy.build(self, p.id, pick.tile, utype)) then
			return true
		end
	end
	for _ = 1, Config.BOT_BUILD_PROBES do
		local x = math.floor(cx + rng:NextNumber(-1, 1) * spread)
		local y = math.floor(cy + rng:NextNumber(-1, 1) * spread)
		if TileMap.inBounds(x, y) then
			local tile = y * W + x
			if buffer.readu8(self.map.owner, tile) == p.id then
				if viaEconomy then
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

-- ---------------------------------------------------------- defense posts --
--
-- Upstream `NationStructureBehavior.handleStructures` tries a defense post
-- BEFORE anything on the ratio ladder and outside it: a post does not increment
-- placementsCount or move lastStructureTick, so being invaded never costs an
-- empire its next port. The gate is THREAT rather than how many cities it owns,
-- because that is the only question a wall answers.

-- The troops committed to every live attack pointed at this empire -- upstream's
-- incomingTroops(). Walking the attack list is the dearest thing in this block,
-- so it runs LAST, after the count and gold checks have already refused every
-- empire that could not have built one anyway.
local function incomingTroops(self: Sim, p: Player): number
	local sum = 0
	for _, atk in self.attacks do
		if atk.active and atk.targetId == p.id then
			sum += atk.troops
		end
	end
	return sum
end

-- The centre of the heaviest front pointed at this empire. Upstream samples
-- tiles near the attacking front (sampleTilesNearFront); the running coordinate
-- sums an Attack already keeps make the same answer O(1).
--
-- `outgoingToo` also counts the fronts this empire is PUSHING (its own
-- attacks on somebody, never on empty land) -- what a battery wants and a
-- wall does not. Omitted, this is the incoming-only answer the post has
-- always had.
function heaviestFront(self: Sim, p: Player, outgoingToo: boolean?): (number?, number?)
	local best = 0
	local bx: number?, by: number? = nil, nil
	for _, atk in self.attacks do
		if
			atk.active
			and atk.borderCount > 0
			and atk.troops > best
			and (atk.targetId == p.id or (outgoingToo == true and atk.attackerId == p.id and atk.targetId ~= 0))
		then
			best = atk.troops
			bx = atk.sumX / atk.borderCount
			by = atk.sumY / atk.borderCount
		end
	end
	return bx, by
end

-- True if a post was placed, in which case this think is spent.
local function botDefensePost(self: Sim, p: Player): boolean
	local maxPosts = Config.BOT_MAX_DEFENSE_POSTS or 0
	if maxPosts <= 0 then
		return false
	end
	-- NEVER THE FIRST STRUCTURE, which upstream states outright. Without a city
	-- there is no economy to defend and the gold is better spent starting one.
	if Units.count(self, p.id, Units.CITY) == 0 then
		return false
	end
	local mine = Units.count(self, p.id, Units.DEFENSE_POST)
	if mine >= maxPosts then
		return false
	end
	if p.gold < Economy.cost(p, Economy.DEFENSE_POST) then
		return false
	end
	local ratio = incomingTroops(self, p) / math.max(p.troops, 1)
	if ratio < (Config.BOT_DEFENSE_POST_THREAT_RATIO or 0.35) then
		return false
	end
	-- How bad it is decides how many are allowed -- upstream's ceil(ratio / 0.4):
	-- one post at the threshold, and another for every further 40% of your own
	-- army marching at you.
	local allowed = math.ceil(ratio / (Config.BOT_DEFENSE_POST_RATIO_PER_POST or 0.4))
	if mine >= math.min(maxPosts, allowed) then
		return false
	end
	-- On the front when there is one to find, in the middle of the country when
	-- the attack has no border left to name. The spread is half the post's own
	-- radius, so the probes land inside the ground it will actually cover instead
	-- of scattered across the whole war.
	local fx, fy = heaviestFront(self, p)
	local spread = nil
	if fx ~= nil and fy ~= nil then
		-- STEP BACK OFF THE LINE. The front's centroid sits ON the border, so
		-- half of a probe box centred there is enemy ground and fails the
		-- ownership test before canBuild is ever reached. Upstream samples tiles
		-- 0.75-1.5x its border spacing BEHIND the front for the same reason.
		-- Walking half the post's own radius toward the middle of the country
		-- keeps the wall on our ground and still comfortably in range of the line
		-- it exists to hold.
		local back = (Config.DEFENSE_POST_RANGE or 30) * 0.5
		local cx = p.sumX / math.max(p.tileCount, 1)
		local cy = p.sumY / math.max(p.tileCount, 1)
		local dx, dy = cx - fx, cy - fy
		local len = math.sqrt(dx * dx + dy * dy)
		if len > 1 then
			local k = math.min(len, back) / len
			fx += dx * k
			fy += dy * k
		end
		spread = back
	end
	return tryPlace(self, p, Economy.DEFENSE_POST, fx, fy, spread)
end

-- --------------------------------------------------------------- artillery --
--
-- A BATTERY GOES WHERE THE FIGHTING IS (2026-09-21). It sits on the ratio
-- ladder like a silo (STRUCTURE_RATIO_PER_CITY, MAX_ARTILLERY), but the
-- centroid placer would put it in the middle of the country, where a 45-tile
-- ring covers nothing but its own ground. So it aims the way the defence post
-- does, at the heaviest front -- and unlike the post it counts the fronts this
-- empire is PUSHING as well as the ones pushing it: a gun behind an advance
-- shells the ground the advance is about to take. Stepped back a third of the
-- ring's radius and probed over the same spread, so the enemy line ends up
-- between a third and two thirds of the way across the ring.
--
-- WITH NO WAR ON, THE NEAREST ENEMY GROUND. Measured, 20 bots on
-- us/20260921: at 800, 1600 and 3200 ticks NOT ONE bot had an attack on a
-- real empire in flight (two did at 2400) -- the roster spends its first
-- minutes eating empty land, and a gun that waited for a war would wait out
-- most rounds. So with no front the aim falls back to a sampled ring just
-- past the empire's own radius, and the nearest hostile tile found is the
-- target. Two dozen byte reads, and only once a gun is wanted and paid for.
-- No enemy anywhere near: no gun, the gold waits.
function nearestEnemyGround(self: Sim, p: Player): (number?, number?)
	local rng = self.rng
	local owner = self.map.owner
	local cx = p.sumX / math.max(p.tileCount, 1)
	local cy = p.sumY / math.max(p.tileCount, 1)
	local reach = math.sqrt(p.tileCount / math.pi) + (Config.ARTILLERY_RANGE or 45) * 0.6
	local bx: number?, by: number? = nil, nil
	local bestD = math.huge
	for _ = 1, 24 do
		local r = reach * math.sqrt(rng:NextNumber())
		local a = rng:NextNumber() * 2 * math.pi
		local x = math.floor(cx + r * math.cos(a) + 0.5)
		local y = math.floor(cy + r * math.sin(a) + 0.5)
		if TileMap.inBounds(x, y) and r < bestD then
			local o = buffer.readu8(owner, y * W + x)
			if o ~= 0 and o ~= p.id and self.players[o] ~= nil and not Sim.friendly(self, p.id, o) then
				bestD = r
				bx, by = x, y
			end
		end
	end
	return bx, by
end

local function botArtillery(self: Sim, p: Player): boolean
	local fx, fy = heaviestFront(self, p, true)
	if fx == nil or fy == nil then
		fx, fy = nearestEnemyGround(self, p)
	end
	if fx == nil or fy == nil then
		return false
	end
	local back = (Config.ARTILLERY_RANGE or 45) / 3
	local cx = p.sumX / math.max(p.tileCount, 1)
	local cy = p.sumY / math.max(p.tileCount, 1)
	local dx, dy = cx - fx, cy - fy
	local len = math.sqrt(dx * dx + dy * dy)
	if len > 1 then
		local k = math.min(len, back) / len
		fx += dx * k
		fy += dy * k
	end
	return tryPlace(self, p, Units.ARTILLERY, fx, fy, back)
end

-- Bots have to SPEND, or the gold economy is something only humans interact
-- with: every AI empire would sit on a treasury it never converts, and a human
-- who buys three cities out-caps the entire roster by 750,000 troops for no
-- reason the map explains.
local function botBuild(self: Sim, p: Player)
	if p.tileCount <= 0 then
		return
	end
	local defences = Config.BOT_BUILDS_DEFENCES ~= false
	-- FIRST, AND ABOVE THE SPEND ROLL -- see botDefensePost. Upstream tries a
	-- post ahead of everything else and outside the structure pacing entirely,
	-- and BOT_BUILD_CHANCE is Conquest's own pacing on top of that pacing.
	--
	-- MEASURED, 24 bots on us/777 over twelve minutes: ten empires cross the
	-- threat threshold at some point in a round, but only for about 850 ticks of
	-- threatened time between them -- and with the post under the spend roll a
	-- bot had to be threatened, be on its think beat AND win the roll, which
	-- produced ONE post in a whole match. The gates that are supposed to be
	-- doing the work are the threat ratio and the cap, and both live in
	-- botDefensePost.
	if defences and botDefensePost(self, p) then
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
	for _, utype in BUILD_ORDER do
		local isDefence = utype == Units.SAM_LAUNCHER or utype == Units.MISSILE_SILO or utype == Units.ARTILLERY or utype == Units.AIRFIELD
		if (defences or not isDefence)
			and shouldBuildStructure(self, p, utype, cityCount, coastal)
			and p.gold >= structureGold(self, p, utype)
			-- The battery is the one kind that is not placed at the centroid.
			and (if utype == Units.ARTILLERY then botArtillery(self, p) else tryPlace(self, p, utype))
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
-- no bordering-player scan (:60-87), no reserve gate, no transport boat roll, no
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
				elseif o ~= p.id and not seen[o] and not Sim.friendly(self, p.id, o) then
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
		if tid ~= 0 and Sim.friendly(self, p.id, tid) then
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
			and not Sim.friendly(self, p.id, atk.attackerId)
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
-- transport boat roll; then a reserve gate, a trigger gate, and a per-difficulty list of
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
	-- A rearmed AI airfield rolls for a sortie on the same beat (2026-09-21).
	botAirstrike(self, p)

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
	-- HUNTER (see Config): attacks more often, and only ever picks AI.
	-- A person who quit is isBot from that tick, so their land is prey.
	local hunter = p.aiHunter == true
	if hunter then
		triggerLevel *= Config.BOT_HUNTER_TRIGGER_SCALE
	end
	local function prey(id: number): boolean
		if not hunter then
			return true
		end
		local o = self.players[id]
		return o ~= nil and o.isBot == true
	end

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
				if atk.troops > biggestTroops and not Sim.friendly(self, p.id, aid) then
					biggestTroops = atk.troops
					biggestAttacker = aid
				end
				if atk.troops > biggestPeerTroops and not Sim.friendly(self, p.id, aid) then
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
			if e and e.alive and e.spawned and not Sim.friendly(self, p.id, id) then
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
			if other and other.tier ~= Config.TIER_TRIBE and not Sim.friendly(self, p.id, id) then
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
		if tid ~= 0 and Sim.friendly(self, p.id, tid) then
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

		-- Upstream picks land vs transport boat with sharesBorderWith(target) (:764-767),
		-- an exact adjacency query we do not have: a carried target, or one
		-- whose contact tile fell outside this window, may not touch us at
		-- all. seedFrontier answers it for free and refunds when it cannot, so
		-- the cascade is "try land; if the engine says notadjacent, transport boat".
		if why == "notadjacent" and tid ~= 0 then
			-- Upstream sendBoatAttack commits troops/5 capped by troopSendCap
			-- (:1039-1045). launchTransportBoat fixes the amount internally, so a cap
			-- can only be honoured by refusing outright.
			local transportBoatTroops = p.troops / Config.TRANSPORT_BOAT_TROOP_DIVISOR
			if isAttackTooWeak(transportBoatTroops, tid) then
				return false
			end
			if transportBoatTroops > troopSendCap() then
				return false
			end
			return (Sim.launchTransportBoat(self, p.id, targetTile))
		end
		return false
	end

	-- Upstream attackWithRandomBoat (:113-161): a random shore tile of ours,
	-- then up to 500 random probes across a 300x300 box (:163-229) looking
	-- first for UNOWNED or BOT-owned land and only then for any non-friendly
	-- owner, skipping anyone we already share a land border with and, in FFA,
	-- anyone stronger than us. We cannot afford 500 map probes, and launchTransportBoat
	-- already does the beach-finding, embarkation and sea route -- most of what
	-- that loop approximates. So the DESTINATION is chosen from the player list
	-- and upstream's three probe filters are applied to the player instead,
	-- which is what they were really filtering for.
	local function tryTransportBoat(chance: number): boolean
		if rng:NextNumber() >= chance then
			return false
		end
		if (self.transportBoatBudget or 0) <= 0 then
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
				and not Sim.friendly(self, p.id, id)
				and tileByRival[id] == nil
				and prey(id)
				and (not ffa or other.troops < p.troops)
			then
				-- findRandomBoatTarget :207-209: the high-interest pass wants
				-- unowned land or land owned by PlayerType.Bot -- the filler
				-- tier, not every AI.
				if Config.TIER[other.tier].TRANSPORT_BOAT_PREY then
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
		if isAttackTooWeak(p.troops / Config.TRANSPORT_BOAT_TROOP_DIVISOR, chosen) then
			return false
		end
		return (Sim.launchTransportBoat(self, p.id, t))
	end

	-- Upstream findNearestIslandEnemy (:610-687): non-friendly players that in
	-- FFA have fewer troops than us, sorted by manhattan distance between
	-- territory centres, keep the first two a transport can reach, and take
	-- the second 1 time in 3. Conquest maintains p.sumX/p.sumY, so the centre
	-- is O(1) and the sort is faithful; reachability is not testable without
	-- launching, so the two candidates are simply tried in order.
	local function islandAttack(): boolean
		if (self.transportBoatBudget or 0) <= 0 or p.tileCount <= 0 then
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
				and not Sim.friendly(self, p.id, id)
				and prey(id)
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
				if t ~= nil and not isAttackTooWeak(p.troops / Config.TRANSPORT_BOAT_TROOP_DIVISOR, entry.id) then
					if (Sim.launchTransportBoat(self, p.id, t)) then
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

	-- ---- 2. transport boats ----------------------------------------------------------
	if rivalCount == 0 then
		-- Upstream :97-100 -- 1 in 5, and NO return: an AI with no land enemy
		-- falls through to attackBestTarget, where `island` is its only move.
		tryTransportBoat(Config.BOT_TRANSPORT_BOAT_CHANCE_ISOLATED)
	else
		-- Upstream :101-105 -- 1 in 10, and it DOES return.
		if tryTransportBoat(Config.BOT_TRANSPORT_BOAT_CHANCE) then
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
				and o.tileCount > 0 and not Sim.friendly(self, p.id, id)
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
		if other and other.alive and not Sim.friendly(self, p.id, id) and prey(id) then
			table.insert(ranked, { id = id, tile = t, troops = other.troops })
		end
	end
	table.sort(ranked, function(a, b)
		if a.troops == b.troops then
			return a.id < b.id
		end
		return a.troops < b.troops
	end)

	-- A hunter runs the finisher passes whatever its tier: breaking an AI
	-- somebody else has already worn down is how the roster thins out.
	if hardTier or hunter then
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
		local margin = if hunter then Config.BOT_HUNTER_STRENGTH_MARGIN else 1
		if other ~= nil and (not ffa or other.troops < p.troops * margin) then
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
-- Both endpoints come from CONFIG, and both modes now share them:
-- 90% in every mode. See Config's win block for why that is a deliberate
-- deviation from upstream rather than a lost distinction.
function Sim.winThreshold(self: Sim): number
	-- Upstream Config.percentageTilesOwnedToWin(elapsedGameSeconds)
	-- (src/core/configuration/Config.ts:713-732). Upstream bases it 80%
	-- free-for-all / 95% team; the bar falls in WHOLE POINTS, one step every
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
			-- THE DEATH WITH NO CONQUEROR. Their last ground went to a crater or
			-- to open land rather than to an attack that could claim it, so
			-- collapsePlayer never ran -- and upstream (PlayerExecution) simply
			-- deletes the treasury at this point.
			--
			-- CONQUEST DEVIATION: somebody still did this to them. `lastHitBy`
			-- names whoever last took ground from them or landed a warhead, and
			-- they are paid the same tier share a conqueror would be. This
			-- CREATES NOTHING -- it only redirects gold that was about to be
			-- destroyed -- and it closes the hole where finishing an empire with
			-- the nuke you paid 750,000 for was the one kill that paid nothing.
			local killer = p.lastHitBy and self.players[p.lastHitBy]
			local taken = 0
			if killer and killer.alive and killer.id ~= p.id then
				if p.gold > 0 then
					local share = Config.TIER[p.tier].CONQUER_GOLD_SHARE
					taken = if share >= 1 then p.gold else math.floor(p.gold * share)
					killer.gold += taken
				end
				p.killedBy = killer.id
			else
				killer = nil
			end
			p.gold = 0
			-- Emitted even when nobody was credited: the death itself is public
			-- and the client plants a skull on it. captorId 0 means no claimant.
			table.insert(self.conquestEvents, {
				captorId = killer and killer.id or 0,
				victimId = p.id,
				gold = taken,
				tile = deathTile(p),
			})
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
			-- THE DOTS BECOME EMPIRES FIRST. Everybody who chose a spot gets
			-- the spot they chose; only then are the unplaced -- people who
			-- never clicked, and the whole AI roster -- dropped into what is
			-- left. The other order lets a bot's random blob land on ground
			-- somebody spent the entire phase deciding on.
			--
			-- ON A PREDRAWN MAP there are no dots: every nation is already
			-- standing, and what ends the phase is each CLAIM becoming a
			-- transfer. See Sim.commitHistorical.
			if self.historical and self.scenario ~= nil then
				Sim.commitHistorical(self)
			else
				for _, id in self.playerOrder do
					local p = self.players[id]
					if p and not p.spawned and p.spawnPreview then
						Sim.commitSpawn(self, p)
					end
				end
				-- Anyone who never picked gets placed, then bots fill the map.
				for _, id in self.playerOrder do
					local p = self.players[id]
					if p and not p.spawned then
						Sim.autoSpawn(self, p)
					end
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
			-- CONQUEST DEVIATION (tutorial): the student EARNS at the same
			-- multiple they fight at (see Sim.processAttack), so "stronger"
			-- means an army that arrives sooner as well as one that goes
			-- further. The CEILING is untouched: this changes how fast an
			-- empire refills, not how big its army may ever get -- the same
			-- split BOT_GROWTH_SCALE is documented with in Config.
			local buff = (self.buffId ~= 0 and id == self.buffId)
				and (self.buffMult or 1)
				or 1
			local tier = Config.TIER[p.tier]
			p.gold += tier.GOLD_PER_TICK * (Config.GOLD_MULTIPLIER or 1) * buff
				* (1 + (p.goldBoost or 0))
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
				-- ...UNLESS THE OVERFLOW WAS BOUGHT (owner, 2026-09-12: "+1 M
				-- army should give the troops all at once, can beat the
				-- capacity"). "+1 Million Army Size!" hands over the men
				-- themselves rather than raising the ceiling, so the army
				-- legitimately stands above its cap and this snap would erase
				-- the entire purchase on the next tick.
				--
				-- IT DOES NOT REOPEN WHAT THE SNAP IS FOR. The exploit above
				-- is banking CEILING from cities and keeping the men after the
				-- cities are gone; this flag is set nowhere but the redeem
				-- (ConquestServer's BOOSTS, tutorial only) and is cleared the
				-- moment the army is spent back under its cap, below -- so an
				-- empire gets exactly one bought overflow and normal rules
				-- resume the instant it is used up.
				if not p.troopOverflow then
					p.troops = max
				end
			elseif p.troops < max then
				-- Back under the ceiling: the bought overflow is spent and the
				-- exemption goes with it.
				p.troopOverflow = nil
				local growth = (Config.GROWTH_BASE + (p.troops ^ Config.GROWTH_EXPONENT) / Config.GROWTH_DIVISOR)
					* (1 - p.troops / max)
				-- Per-map pacing. Income is the ONE lever that changes how long a
				-- match runs without changing how a battle feels: every combat
				-- constant is untouched, armies simply arrive sooner or later.
				-- Defaults to 1 when unset, so a Sim built the old way is
				-- bit-for-bit what it was.
				growth *= tier.GROWTH_SCALE * (self.incomePace or 1) * buff
				-- A FAUX PLAYER GROWS SLOWER THAN ITS TIER (owner, 2026-09-21:
				-- "nerf ai posing as player npcs troop spawn rate by 40%"). It
				-- is a TIER_NATION bot, so until now it earned at a nation's
				-- 0.95 -- near a person's rate -- while the roster around it
				-- earns an eighth. Inside the same min(max, ...) as the rest,
				-- so the ceiling stays exactly where it was.
				if p.faux then
					growth *= Config.FAUX_GROWTH_SCALE or 1
				end
				-- ...and the boosted-skin bonus, a flat tenth on top for a
				-- person wearing one (Patterns.boost). Inside the SAME
				-- min(max, ...) as everything else, so it changes how fast an
				-- army refills and never how big it may get.
				if p.growthBoost ~= nil and p.growthBoost > 0 then
					growth *= 1 + p.growthBoost
				end
				p.troops = math.min(max, p.troops + growth)
			end
		end
	end

	-- One route search per tick across the whole server; see Config.
	self.transportBoatBudget = Config.TRANSPORT_BOAT_LAUNCHES_PER_TICK
	-- And an allowance of FINE water routes -- the tile-level channel between
	-- two coarse waypoints, which is what keeps a transport transport boat in the river instead of
	-- on the bank. A leg lasts a transport boat three ticks, so this is a ceiling on how
	-- many transport boats may be rounding a corner at once, not a per-transport boat rate. Over
	-- budget, a transport boat steers straight for a tick exactly as it always did.
	self.channelBudget = Config.TRANSPORT_BOAT_CHANNEL_PER_TICK or 8
	-- And an allowance of STRAIGHT JUMPS, rationed separately because a
	-- jump is two orders of magnitude cheaper than a channel search, and
	-- sharing one budget would let the dear answer starve the cheap one.
	self.jumpBudget = Config.TRANSPORT_BOAT_JUMP_PER_TICK or 12

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

	stepTransportBoats(self)
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
	-- Batteries pick targets and shells land. Before Nukes.step so a shell's
	-- events sit ahead of the same tick's launches in the one packet, and
	-- before checkElimination for the reason Nukes gives.
	Artillery.step(self)
	-- Airfields rearm and bombers land (2026-09-21), before the warheads for the
	-- same reason and so a razed field never fires on the tick it falls.
	Airstrikes.step(self)
	-- Railguns rearm and slugs land (2026-09-24), the airfield's slot.
	Railgun.step(self)
	Nukes.step(self)
	-- After Economy.step so a gunboat reads THIS tick's trading-transport boat positions,
	-- and after stepCapture so a port that just changed hands produces for
	-- whoever holds it now.
	Gunboats.step(self)
	checkElimination(self)

	-- Bots.
	for _, id in self.playerOrder do
		local p = self.players[id]
		if p and p.isBot and p.alive then
			local rate = p.aiThink or Config.BOT_THINK_TICKS
			local offset = (self.tick + p.thinkOffset) % rate
			if offset == 0 then
				Sim.botThink(self, p)
				Gunboats.botThink(self, p)
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

			-- A WIPEOUT IS NOT "ONE TEAM LEFT" ANY MORE. Every empire used to be
			-- on a side, so one live team meant one live group and the round was
			-- over. Most of the map is neutral now, so a duo round with one person
			-- a side would have ended the instant either of them fell -- winner
			-- holding two percent of the map. Ask it directly instead: one side
			-- standing, and nothing neutral left alive to take.
			local neutralAlive = false
			for _, id in self.playerOrder do
				local q = self.players[id]
				if q and q.alive and q.spawned and self.teamOf[id] == nil then
					neutralAlive = true
					break
				end
			end
			local wipeout = liveTeams == 1 and not neutralAlive

			if
				bestT
				-- A side with nobody alive cannot win one. Reachable only when
				-- every team is wiped out and the neutrals inherit the map, which
				-- is handled just below.
				and liveTeams > 0
				-- Strict > , as upstream (WinCheckExecution.ts:109-115). The
				-- denominator is upstream's numLandTiles - numTilesWithFallout;
				-- playableLand is the exact analogue only while Conquest has no
				-- fallout, so revisit this if DoomsdayClock rot is ever enabled.
				and (bestTiles / Nukes.contestableLand(self) > threshold or wipeout or timeUp)
			then
				-- A wipeout is decided by who is still standing, not by whoever
				-- happens to hold the most land at that instant.
				local winTeam = (wipeout and lastLive) or bestT
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
			-- EVERY SIDE IS DEAD. Nobody who could win a team mode is left --
			-- reachable now that most of the roster is neutral and none of it is
			-- on a side -- so the round is settled the free-for-all way below, by
			-- whichever empire is standing on the most ground. Without this the
			-- block above would hand the win to a wiped-out team at the hard time
			-- limit, with no living member to name as the winner.
			if liveTeams > 0 then
				return
			end
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
		elseif self.phase == "playing" and bestId == nil and aliveCount == 0 then
			-- EVERY SPAWNED EMPIRE IS DEAD. `bestId` needs a LIVING player, so
			-- with nobody left the test above can never fire: the round sat in
			-- "playing" for ever and ConquestServer's loop has no other way out
			-- of it. Nobody won -- winnerId stays nil, which the server already
			-- words as "nobody" -- but the phase still has to end.
			--
			-- GUARDED ON "playing" because this check also runs during the SPAWN
			-- phase, where nobody has committed yet and aliveCount is
			-- legitimately 0.
			self.winnerId = nil
			self.phase = "ended"
		end
	end
end

return Sim