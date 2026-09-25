--!strict
-- Conquest :: server entry
-- Owns the simulation, drives it at a fixed tick rate, and replicates
-- ownership deltas. Terrain is never sent -- clients rebuild it from the seed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")
-- For one thing only: decoding the clan tags a Studio round leaves on an
-- attribute, since that path has no teleport data to read them out of.
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Modes = require(Shared.Modes)
-- Predrawn maps for the historical mode (Modes.historical): the World's 1938
-- borders, keyed by map. startRound loads one instead of its bot loop.
local Scenarios = require(Shared.Scenarios)
local Net = require(Shared.Net)
local Sim = require(Shared.Sim)
local Gunboats = require(Shared.Gunboats)
local Nukes = require(Shared.Nukes)
-- The airfield's sorties (2026-09-21): one intent, validated there.
local Airstrikes = require(Shared.Airstrikes)
local Units = require(Shared.Units)
local Products = require(Shared.Products)
-- DIPLOMACY (2026-09-18). The upstream port that sat unwired until the owner
-- asked for an alliance system. This file is its only server caller: the
-- intent handler files requests, stepDiplomacy runs its clock and tells the
-- two people each event happened to, and the private `fronts` beat carries
-- each player's own standing. What an alliance DOES to the map is still the
-- owner's call -- Sim does not read it yet.
local Alliances = require(Shared.Alliances)
-- Required for ONE assignment, `Economy.tutorialPricing` in startRound. The
-- structure cost ladder's cheap opening rungs are a real-match rule and this
-- script is the only place that knows which kind of round is starting.
local Economy = require(Shared.Economy)
-- FAUX PLAYERS (see the block under BOT_NAMES) and THE TUTORIAL. Tutorial owns
-- the identity roster -- the owner's account and his friends' -- and, when the
-- match record says `tutorial`, the round's shape and its lesson track as
-- well. It requires Sim lazily and is otherwise a table of strings, so this
-- costs nothing at boot.
local Tutorial = require(Shared.Tutorial)
local Faces = require(Shared.Faces)
-- MONEY -- the between-rounds currency. `Money` is pure: it owns the payout
-- rates and a tracker that watches the sim without writing to it, so nothing
-- in this feature can move the balance of a round. `ConquestData` is the
-- profile store the balance is banked in; it was built inert and this is the
-- first thing to switch it on (`Data.install`, at the foot of this file).
local Money = require(Shared.Money)
local Patterns = require(Shared.Patterns)
local Data = require(script.Parent:WaitForChild("ConquestData"))
-- PURCHASES. `Monetization.install()` at the foot of this file has replaced the
-- bare `Data.install()` that used to sit there -- it calls it underneath, so
-- the position and its ordering guarantee are unchanged and what is added is a
-- ProcessReceipt handler. `Names` is required for one line: handing it the bot
-- pool, which is the AI-name collision check's only source of truth.
local Monetization = require(script.Parent:WaitForChild("ConquestMonetization"))
local Names = require(script.Parent:WaitForChild("ConquestNames"))

-- THE FUNNELS. Every player-facing thing this file already computes -- the
-- lesson card that just cleared, the homeland that was picked, the round that
-- ended, the minute somebody left on -- is also the answer to "where does this
-- game lose people", and the only reason that was not being asked is that
-- nobody was writing it down. Analytics depends on nothing, pcalls everything
-- it sends, and is installed at the foot of this file BEFORE ConquestData.
local Analytics = require(script.Parent:WaitForChild("ConquestAnalytics"))

-- CROSS-SERVER MATCHMAKING (2026-08-31). A PUBLIC server of this place is a
-- lobby: it shows the matchmaking page and runs no simulation at all. A
-- RESERVED server -- one MatchmakerServer reserved when a lobby launched -- is
-- a match, and this file only comes alive there. `game.PrivateServerId` is the
-- whole test. There is no second place; a second place would mean two copies
-- of all 28 modules kept in step by hand, and this project has no disk mirror.
local Matchmaker = require(Shared.Matchmaker)
local IS_MATCH = Matchmaker.isMatchServer()
ReplicatedStorage:SetAttribute(Matchmaker.ROLE_ATTR, IS_MATCH and "match" or "lobby")

local netFolder = Net.build(ReplicatedStorage)
local StateRE = netFolder:WaitForChild("State") :: RemoteEvent
local DeltaRE = netFolder:WaitForChild("Delta") :: RemoteEvent
local IntentRE = netFolder:WaitForChild("Intent") :: RemoteEvent

local SNAPSHOT_CHUNK = 16384

-- How often the summaries go out. Every number on the client -- garrisons,
-- armies in the field, the standings table, the team bar -- is repainted
-- straight off this, so its period IS how fast the numbers move. Two ticks
-- at TICK_RATE 10; the delta stream is already an order of magnitude more
-- traffic than these summaries, so the cost is noise.
local STATS_INTERVAL = 0.2

-- One name per AI empire with NONE left over to be numbered. The roster is
-- 72 empires now (24 players + 48 AI at a full server, all 72 AI when it is
-- empty), and the old list of 30 meant two thirds of the map was labelled
-- "Ostmark 41" -- a nation you cannot name is a nation you cannot talk about.
local BOT_NAMES = {
	"Aurelia", "Bastion", "Cindral", "Dunmoor", "Eskaria", "Fenwick",
	"Gallowmere", "Halcyon", "Ironvale", "Jorvik", "Kesselring", "Lorwyn",
	"Mordania", "Northreach", "Ostmark", "Pellucid", "Quillon", "Ravenhold",
	"Sablewood", "Tarnhelm", "Ulster", "Verdania", "Westmarch", "Xanthe",
	"Ysolde", "Zephyria", "Ashfall", "Brightwater", "Caldera", "Dunhollow",
	"Emberfell", "Farlight", "Grimsby", "Highmarch", "Isenford", "Jarrowdale",
	"Kettering", "Lanthorn", "Marrowick", "Nethermoor", "Oakhaven", "Pinebluff",
	"Quarrenden", "Redfen", "Stormgard", "Thornwick", "Umberlyn", "Valebrook",
	"Wolfsden", "Yarrowmere", "Alderhold", "Blackmere", "Coldharbour",
	"Draywood", "Elmsgate", "Foxglove", "Greywater", "Hollowmere", "Ivorhold",
	"Jessamy", "Kilbraith", "Larkspur", "Mistvale", "Norhollow", "Orenthal",
	"Palisade", "Quintmark", "Rookswood", "Silverthane", "Tallowgate",
	"Undermere", "Vantsholm", "Whitecliff", "Xerath", "Yewbourne", "Zarnoth",
	"Amberhelm", "Bellweather", "Cragmoor", "Duskwater",
}

-- A HUMAN MAY NOT WEAR A BOT'S NAME, and this line is the whole of that rule
-- being switched on. ConquestNames deliberately keeps no copy of the list --
-- two copies of eighty names drift, and a collision check against a stale list
-- is worse than no check because it still looks like it works -- so without
-- this call the check warns once and does nothing. It matters because people
-- play differently against AI: a human named Ravenhold is buying a tactical
-- advantage for the price of a rename.
Names.setBotPool(BOT_NAMES)

-- THE HUMAN NAMES, which are no longer just the account's. A player who has
-- bought a rename has one stored on their profile, and ConquestShop -- which
-- owns the filtering and the token -- hands the ACCEPTED string over on a
-- player attribute rather than through a require, because one Script cannot
-- require another. Unset covers everybody who has never bought one, a name
-- that has stopped passing the filter, and a profile that failed to load;
-- all three fall back to the display name, which is what this used to be
-- unconditionally.
local function nationNameFor(player: Player): string
	local stored = player:GetAttribute("ConquestNation")
	if type(stored) == "string" and stored ~= "" then
		return stored
	end
	return player.DisplayName
end

-- =========================================================== faux players ==
--
-- EVERY ROUND CARRIES A FEW EMPIRES WEARING A PERSON'S NAME AND FACE. A match
-- with one human in it and forty nations called Ostmark reads as a practice
-- range. The same match with five of those nations called Jezza, Mekski and
-- Sail reads as a game with people in it -- and the standings rows, the map
-- labels and the headshots all come out right with no other change, because
-- every one of them is already driven by the roster's user id.
--
-- A FAUX PLAYER IS AN ORDINARY BOT. `p.isBot` stays true: Sim's AI loop is
-- gated on exactly that field and an empire flagged human would sit still for
-- the whole round. So the halved income, the transport-boat prey split and the
-- neutral-cost deviation all still apply and the match stays balanced like the
-- one it replaces. Only the three places that TELL A CLIENT about the roster
-- lie -- `botIdList`, `roster` and `playerSummary`, each marked below. The
-- trick was worked out in Tutorial; its header is the long version.
--
-- THEY REPLACE BOTS RATHER THAN ADDING TO THEM, so the roster size, the
-- per-tick cost and the team split are all exactly what they were.
-- THE ONE MECHANICAL DIFFERENCE (2026-09-21): a faux empire's troop growth is
-- scaled by Config.FAUX_GROWTH_SCALE in Sim's income pass, so a "player" no
-- longer out-grows the nations it stands among. Sim.addPlayer stamps `p.faux`
-- from the last argument of the addPlayer call below; nothing here has to.
local FAUX_MAX = 6
-- The middle AI class. A tribe razes what it captures and never builds, which
-- is not how any person plays; a nation expands, builds cities and ports, and
-- behaves like the player it is pretending to be.
local FAUX_TIER = Config.TIER_NATION
-- Empire id -> true, rebuilt every round. The three lies read this.
local fauxIds: { [number]: boolean } = {}
-- ...and the identity each one is wearing, kept beside it so a session can be
-- asked WHO an empire is pretending to be and not merely whether it is
-- pretending. Written in the same two places `fauxIds` is.
local fauxIdentity: { [number]: any } = {}

local sim
local roundId = 0
-- os.clock() the current round began. Wall-clock rather than sim ticks because
-- everything it feeds is a duration a person would recognise: how long they
-- played before quitting, how long the round they saw out actually took.
local roundStartedAt = 0

-- ------------------------------------------------------------- clan tags ---
--
-- WHO IS IN WHOSE CLAN, which decides only one thing: same tag, same team
-- (Sim.addPlayer). It is typed on the lobby page, normalised there and again on
-- the lobby server, and carried here in the teleport data of the batch that
-- brought this player -- MatchmakerServer.sendToMatch. Never drawn for anybody
-- but its author; see Matchmaker.normaliseTag for why that matters.
--
-- READ ONCE PER PLAYER AND CACHED. GetJoinData is a call into the join payload
-- and this runs inside the round-start loop, which already walks every player.
local tagCache: { [number]: string } = {}

local function localTags(): { [string]: string }
	local raw = ReplicatedStorage:GetAttribute(Matchmaker.LOCAL_TAGS_ATTR)
	if type(raw) ~= "string" or raw == "" then
		return {}
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return {}
end

local function tagFor(player: Player): string
	local hit = tagCache[player.UserId]
	if hit ~= nil then
		return hit
	end
	local key = tostring(player.UserId)
	local t = ""
	-- The live path: this player was teleported here, and their batch's data
	-- carries the tags of everyone in it. Keyed by userId as a STRING because
	-- teleport data is JSON and a numeric key never survives as one.
	local ok, data = pcall(function()
		return player:GetJoinData().TeleportData
	end)
	if ok and type(data) == "table" and type(data.tags) == "table" then
		t = Matchmaker.normaliseTag(data.tags[key])
	end
	if t == "" then
		-- ...and the Studio path, where the round started in the session it was
		-- queued in and nobody was teleported anywhere, so the lobby left the
		-- same map on an attribute. Decoded per lookup rather than cached: it
		-- is written once per round start and read once per player.
		t = Matchmaker.normaliseTag(localTags()[key])
	end
	tagCache[player.UserId] = t
	return t
end

-- THE TUTORIAL, present only on a server whose match record asked for one.
-- The session holds the lesson track; the user id is kept beside it because
-- the cards go to ONE client and Players:GetPlayerByUserId is the only way
-- back to that client from an empire.
local tutorialSession: any = nil
local tutorialUserId = 0
-- THE LITE LESSONS: userId -> a Tutorial session with `lite` set, one per
-- follower who took command of a bot beside a friend without having done the
-- tutorial (followTakeover). Advanced beside the singleton above; nothing
-- round-wide keys off these.
local lessons: { [number]: any } = {}

-- THE LESSON, AS A FUNNEL. `advance` returns true both when a card is replaced
-- and when the ring it is pointing at moves, so "something changed" is not
-- enough to say a step was cleared -- the card INDEX is. These three are the
-- reporting cursor: how many cards have been reported cleared, when the track
-- started, and whether an ending has been logged already, so a student who is
-- knocked out and then leaves is not counted as two separate losses.
local tutorialStepSeen = 0
local tutorialStartedAt = 0
local tutorialEnded = false
-- WHEN THE TRACK ENDED, or 0 while it is still running. The student goes back
-- to the matchmaking page a beat after this -- see the exit block in the loop.
--
-- Set ONLY by noteTutorial, never by the player-leaving path that also raises
-- `tutorialEnded`: somebody who has already quit does not need teleporting.
local tutorialOverAt = 0
-- HOW LONG THE LAST CARD STAYS UP before they are taken back. Long enough to
-- read it and look at the map it was earned on; short enough that it does not
-- read as the game having frozen. The win screen holds twelve, and this is not
-- a win -- it is the end of a lesson.
local TUTORIAL_EXIT_SECONDS = 8

-- ============================================================== broadcast ==

-- Everything about a player that cannot change inside a round. Sent once
-- with `init` (and again if someone joins during the spawn phase) instead
-- of five times a second: names are strings, and the per-tick summary was
-- re-transmitting the whole roster to carry three integers per empire.
-- WHICH PATTERN AN EMPIRE IS WEARING, as an index into the shared catalogue,
-- written onto the empire itself rather than looked up per send. It moves at
-- most twice for a player -- once when they are added, once when their profile
-- lands -- and the roster is read far more often than that.
--
-- A PROFILE ARRIVES AFTER ITS OWNER DOES, always: the lobby server has to let
-- go of the session lock before a match server can open the same profile, and
-- that is seconds. So this is called twice on purpose (from the add, and again
-- from `Data.onReady` at the foot of this file) and reports whether the answer
-- actually MOVED -- because the second call is what pays for a repaint on
-- every client, and a round where nobody wears one must not pay it.
--
-- BOTS NEVER WEAR ONE. The AI paints as a single monotone mass so that a
-- glance answers "which of these is a person"; a patterned bot would read as
-- a player, which is the read the whole palette is built around.
local function applyPattern(player: Player): boolean
	if not sim then
		return false
	end
	local p = sim:playerByUserId(player.UserId)
	if not p or p.isBot then
		return false
	end
	local idx = Patterns.indexOf(Data.patternKey(player))
	-- VIP'S +10% RIDES THE SAME TERM A PATTERN'S DOES (2026-09-15), and it is
	-- ADDED rather than maxed: somebody who paid for the pass AND a boosted
	-- skin gets both. That tops out at 20%, which is still a lead and not a
	-- wall -- no combat constant moves and Sim.maxTroops is untouched, so the
	-- army arrives sooner and never gets bigger.
	local vip = if player:GetAttribute("ConquestVip") == true then Config.VIP_GROWTH_BOOST else 0
	local growth = Patterns.boost(idx) + vip
	local gold = Patterns.goldBoost(idx)
	-- ...and the FAST_RELOAD pass (2026-09-25), which lands the same late way
	-- VIP does and so rides the same idempotent re-run (watchVip below).
	local reload = if Monetization.holdsPass(player, "FAST_RELOAD") then Config.FAST_RELOAD_MULT else nil
	-- THE EARLY RETURN HAS TO TEST ALL THREE, not just the index, and that is
	-- not a tidy-up: VIP is confirmed by a web call that lands AFTER the
	-- profile does, so the second call for a VIP wearing no pattern moves the
	-- boost while the index sits still at 1. An index-only test returned false
	-- there and dropped the entire +10% on the floor.
	if p.pattern == idx and p.growthBoost == growth and p.goldBoost == gold and p.reloadMult == reload then
		return false
	end
	p.pattern = idx
	-- ...and what the pattern is WORTH, if anything: the boosted tier's tenth
	-- on troop growth, read by Sim's income loop. Tied to the index so the two
	-- can never disagree -- an empire wearing Compass is boosted, one wearing
	-- Checker is not, and there is no third field to get out of step.
	p.growthBoost = growth
	p.goldBoost = gold
	p.reloadMult = reload
	return true
end

-- THE FLAG AN EMPIRE FLIES. Deliberately the same shape as applyPattern above,
-- for the same reason: a profile lands a second or two after its owner, so this
-- must be re-runnable and must say whether anything actually moved.
--
-- Data.flagKey returns Flags.NONE ("") for an account flying nothing; that
-- becomes nil here so the roster row simply omits the field, exactly as `p`
-- does for an empire wearing no pattern.
local function applyFlag(player: Player): boolean
	if not sim then
		return false
	end
	local p = sim:playerByUserId(player.UserId)
	if not p or p.isBot then
		return false
	end
	local key: string? = Data.flagKey(player)
	if key == "" then
		key = nil
	end
	if p.flag == key then
		return false
	end
	p.flag = key
	return true
end

local function roster()
	local list = {}
	for _, id in sim.playerOrder do
		local p = sim.players[id]
		if p then
			-- `u` is the Roblox user id: the standings board draws a headshot
			-- from it (rbxthumb, resolved client-side). Bots have none and
			-- fall back to a lettered badge in their nation colour.
			-- LIE #2 IS THIS LINE UNCHANGED. A faux empire simply HAS a user
			-- id, so it gets a real face here for free.
			-- `p` is the tile pattern, and it is ABSENT rather than 1 on the
			-- empires wearing none -- which is nearly all of them on a
			-- 72-empire map, since the AI never wears one. A nil costs
			-- nothing on the wire; a byte per bot would make this the
			-- roster's largest field while carrying no information at all.
			local pat = p.pattern
			local name, uid = p.name, p.userId
			-- A CLAIMED NATION WEARS ITS CLAIMER for as long as the spawn phase
			-- lasts (owner, 2026-09-11). The land is still its AI's until the
			-- phase ends (Sim.commitHistorical), but the label and the
			-- standings row carry the person's name and face from the moment
			-- they click -- what an ordinary round shows when you drop your dot.
			local taker = sim.phase == "spawn" and p.nation ~= nil and sim.nationTaker
				and sim.players[sim.nationTaker[p.nation] or 0]
			if taker and taker ~= p then
				name, uid = taker.name, taker.userId
			end
			-- A PLAIN AI NATION GETS A FACE TOO (owner, 2026-09-25): a random
			-- rendered avatar dealt by empire id -- see Faces.NPC. Sent on the
			-- wire only; `p.userId` stays nil, because every "is this a plain
			-- bot?" rule on the server reads that field.
			if uid == nil and p.isBot then
				uid = -(Faces.NPC_BASE + p.id)
			end
			table.insert(list, {
				i = p.id,
				n = name,
				u = uid,
				p = (pat and pat > 1) and pat or nil,
				-- The flag rides the CLAIM, exactly as the name and face above do:
				-- on a predrawn map the person holding a nation during the spawn
				-- phase is `taker`, and theirs is the flag that belongs over it.
				f = (taker and taker ~= p) and taker.flag or p.flag,
			})
		end
	end
	return list
end

local function playerSummary()
	local list = {}
	for _, id in sim.playerOrder do
		local p = sim.players[id]
		if p and p.spawned then
			table.insert(list, {
				id = p.id,
				name = p.name,
				tiles = p.tileCount,
				troops = math.floor(p.troops),
				alive = p.alive,
				-- LIE #3. The twice-a-second flag behind Palette's bot/player
				-- colour split and the standings' own rows.
				isBot = p.isBot and not fauxIds[p.id],
				team = sim.teamOf[p.id],
			})
		end
	end
	return list
end

-- Who this player is pushing into, and who is pushing into them. Sent per
-- client because it is the one piece of state that is genuinely private.
-- The size buttons are the whitelist. Anything else -- a crafted intent, an
-- old client, a NaN -- lands on the NEAREST legal preset rather than being
-- refused: an attack that does nothing because a number was wrong reads to
-- the player as the attack button being broken.
local function snapPreset(v: any): number
	if typeof(v) ~= "number" or v ~= v then
		return Config.DEFAULT_ATTACK_RATIO
	end
	local best, bestD = Config.DEFAULT_ATTACK_RATIO, math.huge
	for _, preset in Config.ATTACK_PRESETS or { Config.DEFAULT_ATTACK_RATIO } do
		local d = math.abs(preset - v)
		if d < bestD then
			best, bestD = preset, d
		end
	end
	return best
end

local function frontsFor(p)
	local outgoing, incoming = {}, {}
	for _, atk in sim.attacks do
		if atk.active then
			if atk.attackerId == p.id then
				local target = atk.targetId ~= 0 and sim.players[atk.targetId]
				table.insert(outgoing, {
					id = atk.targetId,
					troops = math.floor(atk.troops),
				})
			elseif atk.targetId == p.id then
				local from = sim.players[atk.attackerId]
				table.insert(incoming, {
					id = atk.attackerId,
					troops = math.floor(atk.troops),
				})
			end
		end
	end
	return outgoing, incoming
end

local function sendSnapshot(player: Player)
	-- Run-length encoded. Raw, this is one byte per tile -- 1.6 MB -- and it
	-- goes to every client at every round start AND every join, which was by
	-- far the largest thing on the wire. A fresh round packs to FOUR bytes
	-- (the map is one unclaimed run); a three-minute-old map to about 17 KB.
	-- packOwners returns nil if it would not beat the raw bytes, so the
	-- fallback can never be worse than what this replaced.
	local packed = Net.packOwners(sim.map.owner)
	local data = packed or sim.map.owner
	local total = buffer.len(data)
	local chunks = math.max(1, math.ceil(total / SNAPSHOT_CHUNK))
	for c = 0, chunks - 1 do
		local offset = c * SNAPSHOT_CHUNK
		local size = math.min(SNAPSHOT_CHUNK, total - offset)
		local part = buffer.create(size)
		buffer.copy(part, 0, data, offset, size)
		StateRE:FireClient(player, "snapshot", {
			round = roundId,
			index = c,
			count = chunks,
			offset = offset,
			bytes = total,
			raw = packed == nil,
			data = part,
		})
	end
end

-- Which empires are AI, as a plain array of ids. This has to ride along with
-- `init` rather than wait for the first `players` summary: the client paints
-- every tile the moment the snapshot lands, which is BEFORE that summary
-- arrives, and a bot drawn in a player colour for that instant costs a full
-- 1.6M-tile repaint to correct.
local function botIdList(): { number }
	local ids = {}
	for _, id in sim.playerOrder do
		local q = sim.players[id]
		-- LIE #1. A faux id in here paints its territory in a bot colour the
		-- instant the snapshot lands, and putting that right afterwards costs
		-- the full 1.6M-tile repaint this list exists to avoid.
		-- A PERSON WHO LEFT is isBot but still TIER_HUMAN, and keeps their
		-- colour -- so a spectator who joins later sees it as everyone else does.
		if q and q.isBot and q.tier ~= Config.TIER_HUMAN and not fauxIds[id] then
			table.insert(ids, id)
		end
	end
	return ids
end

-- THE PREDRAWN MAP'S COLOURS, or nil on every ordinary round. Empire id ->
-- { r, g, b } for the PLAYABLE nations only (a minor paints in the AI ramp,
-- which is what makes the ten you may pick readable at a glance), keyed by
-- whoever holds the nation right now -- so it is sent again after the phase
-- ends, when the people have taken their seats. See Palette.setNations.
local function historicalPayload(): any?
	local scn = sim and sim.scenario
	if not scn then
		return nil
	end
	local colors = {}
	for k, nation in ipairs(scn.NATIONS) do
		local id = sim.nationPlayer[k]
		if id and nation.playable and nation.color then
			colors[id] = nation.color
		end
	end
	return {
		id = scn.ID,
		name = scn.NAME,
		year = scn.YEAR,
		playable = scn.PLAYABLE_COUNT,
		colors = colors,
		-- The opening truce, in seconds from the round start, for the banner.
		grace = (sim.immunityTicks or 0) * Config.TICK_DT,
	}
end

local function sendInit(player: Player)
	local p = sim:playerByUserId(player.UserId)
	StateRE:FireClient(player, "init", {
		round = roundId,
		seed = sim.seed,
		mapId = sim.mapId,
		mapName = Maps.name(sim.mapId),
		mapBlurb = Maps.get(sim.mapId).BLURB,
		modeId = sim.modeId,
		modeName = Modes.name(sim.modeId),
		modeShort = Modes.get(sim.modeId).SHORT,
		modeBlurb = Modes.get(sim.modeId).BLURB,
		-- A special mode's flat troop ceiling (Modes.SPECIAL troopCapBonus), or
		-- nil: the client mirrors Sim.maxTroops and has to add the same figure.
		troopCapBonus = sim.troopCapBonus,
		teamCount = sim.teamCount,
		-- The WHOLE roster, bots included -- the client paints every empire on
		-- the map by team, not just the ones the standings table lists.
		teams = sim.teamCount > 0 and sim.teamOf or nil,
		botIds = botIdList(),
		yourId = p and p.id or 0,
		roster = roster(),
		phase = sim.phase,
		playableLand = sim.playableLand,
		phaseRemaining = sim.phase == "spawn"
				and (Config.SPAWN_PHASE_SECONDS - sim.phaseTick * Config.TICK_DT)
			or 0,
		-- The predrawn map's name and colours; absent on every ordinary round.
		historical = historicalPayload(),
		-- The lesson card, in a tutorial round and to the student alone. It
		-- rides with `init` so a client that reloads or arrives late gets the
		-- card it was on rather than an empty corner until the next one lands
		-- -- and cards can be minutes apart.
		tutorial = (tutorialSession ~= nil and player.UserId == tutorialUserId)
				and Tutorial.state(tutorialSession)
			or (lessons[player.UserId] ~= nil and Tutorial.state(lessons[player.UserId]))
			or nil,
	})
	sendSnapshot(player)
	StateRE:FireClient(player, "players", Net.packPlayers(playerSummary()))
	-- Every structure and rail standing right now, as absolute lists. The
	-- streams after this are incremental, so a joiner that missed the events
	-- needs the state they add up to -- and `reset` tells the client to drop
	-- what it had rather than merge a new round's map into the last one's.
	StateRE:FireClient(player, "structs", sim:snapshotStructures(), true)
	StateRE:FireClient(player, "rails", sim:snapshotRails(), true)
end

-- =================================================================== money ==
--
-- WHAT A ROUND WAS WORTH, paid once, kept forever. Gold is the in-match
-- economy and dies with the map; Money is the only thing that leaves the
-- round. The rates and the reasoning are in `Conquest.Money`; this is just
-- when it is paid, to whom, and where it is banked.
--
-- IT IS PAID AT THE MOMENT THE RESULT IS FINAL, NOT AT THE END OF THE ROUND.
-- An empire eliminated at minute four cannot finish anywhere but where it
-- already is -- nobody still playing can place below it -- so its payout is
-- banked there and then. That is what lets a knocked-out player leave straight
-- away with their money instead of spectating twelve minutes to collect it,
-- and it is the difference between a currency and a punishment.
local moneyTracker: any = nil
-- By USER ID, and it is the whole guard against paying twice: the tick loop,
-- the end-of-round sweep and the leave handler can all reach the same player,
-- and two of them firing in the same frame is ordinary rather than rare.
local moneyPaid: { [number]: boolean } = {}

-- Settles one player. `partial` is the leave path -- see Money.award for which
-- terms an unfinished round withholds and why.
local function settleMoney(plr: Player, partial: boolean?)
	if moneyTracker == nil or moneyPaid[plr.UserId] then
		return
	end
	local p = sim and sim:playerByUserId(plr.UserId)
	if p == nil then
		return
	end
	local stats = moneyTracker:statsFor(p.id, partial)
	if stats == nil then
		return
	end
	local award = Money.award(stats)
	-- 2x MONEY (2026-09-08): a paid, permanent doubling of every payout. The
	-- breakdown is built FIRST so the bonus prints as its own row equal to
	-- everything above it, and the card's rows still sum to its total. It
	-- doubles the whole award, partial payouts included -- the pass buys twice
	-- what a round is worth, whatever that turns out to be.
	local lines = Money.lines(stats, award)
	if award.total > 0 and Data.hasMoney2x(plr) then
		table.insert(lines, { label = "2x MONEY", value = "", amount = award.total })
		award.total *= 2
	end
	moneyPaid[plr.UserId] = true
	-- PLACEMENT, logged here and not at the end of the round, because HERE is
	-- where it is known exactly -- the tracker settles each empire on the tick
	-- it fell, which is the whole reason a knocked-out player can leave with
	-- their money instead of spectating for it.
	Analytics.event("match_result", plr, stats.place, {
		field = stats.field,
		result = stats.won and "won" or "lost",
	})
	if award.total <= 0 then
		return
	end

	-- BANKED FIRST, TOLD SECOND. A profile that failed to load returns nil from
	-- addMoney, which per ConquestData's header means "write nothing" -- but the
	-- card is still shown, because the round really did earn that and a silent
	-- zero would read as the game losing it. `balance` nil is how the client
	-- knows to print the award without a running total it cannot vouch for.
	local balance = Data.addMoney(plr, award.total)
	-- Through Roblox's economy report rather than as a bare count: that report
	-- already knows how to draw a currency's sources against its sinks, and the
	-- sinks are the half of Money that has not shipped yet.
	Analytics.moneyEarned(plr, award.total, balance, partial and "partial" or "round")
	if balance ~= nil then
		local profile = Data.get(plr)
		if profile ~= nil and type(profile.stats) == "table" then
			profile.stats.matches = (tonumber(profile.stats.matches) or 0) + 1
			if stats.won then
				profile.stats.wins = (tonumber(profile.stats.wins) or 0) + 1
			end
			local peak = math.floor(stats.shares * (sim.playableLand / math.max(1, stats.field)))
			if peak > (tonumber(profile.stats.tilesPeak) or 0) then
				profile.stats.tilesPeak = peak
			end
		end
		-- Durable NOW rather than at the next autosave. A match server is
		-- shut down by Roblox the moment the last player teleports out, and
		-- thirty seconds is longer than the twelve this round has left.
		task.spawn(Data.flush, plr)
	end

	StateRE:FireClient(plr, "money", {
		total = award.total,
		balance = balance,
		lines = lines,
		place = stats.place,
		field = stats.field,
		won = stats.won,
		final = stats.final,
	})
end

-- ================================================================= revive ==
--
-- A KNOCKED-OUT PLAYER BUYS THEIR WAY BACK IN BY TAKING OVER AN AI EMPIRE
-- (owner, 2026-09-08). Nothing is added to the map: an empire that was already
-- there stops being driven by the AI and starts being driven by a person --
-- which is exactly what happens in reverse every time somebody disconnects
-- (PlayerRemoving hands their land to the bots). The roster, the land and the
-- troops are what they were a tick earlier, so the round's balance is
-- untouched; what the purchase buys is being in the game again.
--
-- WHICH EMPIRE: the BIGGEST pure bot still standing (owner, 2026-09-17: "when a
-- player revives, also make them revive as the biggest AI still alive"). This
-- used to be the MEDIAN of the pack, on the argument that the biggest bot on a
-- late map can be a quarter of it and selling that is selling the round. The
-- owner's call overrides that: what somebody pays to come back for is a seat
-- they can actually play from, and a median bot late in a round is often just a
-- second death ten minutes later. The old risk is real and unchanged -- a late
-- revive can hand over the strongest empire on the map -- and what holds it in
-- check is that it costs Robux and that REVIVE_PER_ROUND is one.
--
-- Excluded, as before: faux empires (wearing a real person's name and face),
-- and anything that ever had a user id -- a disconnected player's land, whose
-- id is still on the roster.
--
-- IN A TEAM ROUND the taken-over empire joins the player's OLD side, because a
-- neutral empire can attack and be attacked by anybody -- including the people
-- it was on a team with a minute ago. That is a small gift of land to the team
-- (a median bot is about a seventieth of the map), accepted as the price of
-- the revived player still being in the game they were in. The client learns
-- of it from the next 5 Hz summary, which already carries every empire's team
-- and bot flag and repaints when either moves (it is the disconnect path).
--
-- ONCE PER ROUND. The second death is final, whatever is in hand; tokens
-- carry to the next round.
local REVIVE_PER_ROUND = 1
-- A candidate holds at least this much land, so a purchase never lands
-- somebody on an empire that is already collapsing.
local REVIVE_MIN_TILES = 40
local revivedThisRound: { [number]: number } = {}
-- One takeover in flight per player: the receipt hook and the button can both
-- reach tryRevive inside the same second.
local reviving: { [number]: boolean } = {}

local function canRevive(player: Player): (boolean, string)
	if sim == nil or sim.phase ~= "playing" then
		return false, "the round is not running"
	end
	if tutorialSession ~= nil then
		return false, "not in the tutorial"
	end
	if (revivedThisRound[player.UserId] or 0) >= REVIVE_PER_ROUND then
		return false, "one revive a round"
	end
	local p = sim:playerByUserId(player.UserId)
	if p == nil or not p.spawned then
		return false, "never held land this round"
	end
	if p.alive and p.tileCount > 0 then
		return false, "still standing"
	end
	return true, ""
end

local function reviveCandidate(): any
	-- One pass for a maximum, where this used to build a list and sort it: the
	-- median needed the whole order, the biggest does not.
	local best: any = nil
	for _, id in sim.playerOrder do
		local q = sim.players[id]
		if q and q.isBot and q.alive and q.spawned and q.userId == nil
			and not fauxIds[id] and q.tileCount >= REVIVE_MIN_TILES
		then
			-- Ties broken by the LOWER id, as the old sort did, so two bots on
			-- the same tile count cannot make the pick depend on roster order.
			if best == nil
				or q.tileCount > best.tileCount
				or (q.tileCount == best.tileCount and q.id < best.id)
			then
				best = q
			end
		end
	end
	-- nil when every surviving bot is under REVIVE_MIN_TILES, which is what
	-- offerRevive reads to grey the button out: coming back onto an empire
	-- already collapsing is not a second chance, however big it is relatively.
	return best
end

-- What the HUD's button should show: whether one is possible right now, and
-- how many are already in hand (a token skips the purchase prompt).
local function offerRevive(player: Player)
	local ok = canRevive(player)
	StateRE:FireClient(player, "revive", {
		allowed = ok and reviveCandidate() ~= nil,
		tokens = Data.reviveTokens(player),
	})
end

-- THE HAND-OVER ITSELF, shared by the two ways a person comes to own an empire
-- mid-round: a REVIVE (takeover, below) and a FOLLOWER arriving beside a friend
-- (followTakeover). `team` is the side to put a neutral bot on, or nil.
local function adoptEmpire(player: Player, q: any, team: number?)
	-- The old empire, if any, keeps its name and face for the standings' dead
	-- row; the user-id lookup is the one thing that moves, and it is what every
	-- "which empire is this player" question in this file goes through.
	sim.byUserId[player.UserId] = q.id
	q.userId = player.UserId
	q.name = nationNameFor(player)
	q.isBot = false
	q.tier = Config.TIER_HUMAN
	q.killedBy = nil
	q.lastHitBy = nil
	if sim.teamCount > 0 and team ~= nil and sim.teamOf[q.id] == nil then
		sim.teamOf[q.id] = team
		sim.teamSizes[team] = (sim.teamSizes[team] or 0) + 1
	end
	-- MONEY: this life is paid on its own terms. The tracker is handed an
	-- empire whose peak and kills start from here rather than from the bot's
	-- history, and the "already paid" latch is lifted for a second life.
	moneyPaid[player.UserId] = nil
	if moneyTracker ~= nil then
		moneyTracker:adopt(q.id)
	end
	-- Their pattern and, with it, any boost it carries -- and their flag.
	applyPattern(player)
	applyFlag(player)
	-- Everyone: the name, face and pattern now on this empire.
	StateRE:FireAllClients("roster", roster())
	-- The player: a fresh init -- their id changed, and so did every "yours"
	-- on their screen -- then the camera onto the middle of their new land.
	sendInit(player)
	local centre = q.spawnTile or 0
	if q.tileCount > 0 then
		centre = math.floor(q.sumY / q.tileCount) * Config.MAP_W + math.floor(q.sumX / q.tileCount)
	end
	StateRE:FireClient(player, "spawned", { tile = centre })
	StateRE:FireClient(player, "revive", { allowed = false, tokens = Data.reviveTokens(player) })
end

-- The takeover itself. Returns ok, reason.
local function takeover(player: Player): (boolean, string)
	local ok, why = canRevive(player)
	if not ok then
		return false, why
	end
	local old = sim:playerByUserId(player.UserId)
	local q = reviveCandidate()
	if q == nil then
		return false, "no empire is free to take"
	end
	revivedThisRound[player.UserId] = (revivedThisRound[player.UserId] or 0) + 1
	adoptEmpire(player, q, if old ~= nil then sim.teamOf[old.id] else nil)
	Analytics.event("revive", player, 1, { empire = q.id, tiles = q.tileCount })
	print(("[Conquest] %s revived as empire %d (%d tiles)"):format(player.Name, q.id, q.tileCount))
	return true, ""
end

-- ================================================================= follow ==
--
-- A FRIEND WHO PRESSED JOIN LANDS MID-WAR. MatchmakerServer.followFriend sends
-- them here with `follow = <the friend's userId>` in their own teleport data,
-- and the round is usually well past its spawn phase by the time they arrive.
-- Rather than have them spectate, they take command of the bot nearest their
-- friend -- a nation with land and an army already on the map -- through the
-- same hand-over a REVIVE uses. Before the war starts the ordinary late-arrival
-- path in PlayerAdded seats them instead, and in a tutorial they only watch.
--
-- THE FRIEND HAS TO BE STANDING. Somebody who followed a player already knocked
-- out has nobody to fight beside; they spectate like any other late joiner and
-- go home with the survivors.
local FOLLOW_MAX_RATIO = 2 -- a follower's nation is at most this much bigger than the friend's, if a smaller one exists

local function followedUserId(player: Player): number?
	local ok, data = pcall(function()
		return player:GetJoinData().TeleportData
	end)
	if ok and type(data) == "table" and type(data.follow) == "number" and data.follow > 0 then
		return data.follow
	end
	return nil
end

-- The living bot nearest a point on the map, by centroid. Faux empires,
-- empires already wearing a person and anything under REVIVE_MIN_TILES are
-- passed over, and in a team round so is any nation already on another side.
-- A nation over `maxTiles` is passed over while a smaller one exists: a
-- follower arrives as reinforcements, not as the leading power. `maxTiles` is
-- math.huge when there is no living friend to measure against.
local function followCandidate(fx: number, fy: number, maxTiles: number, team: number?, excludeId: number?): any
	local best: any, bestD = nil, math.huge
	local fallback: any, fallbackD = nil, math.huge
	for _, id in sim.playerOrder do
		local q = sim.players[id]
		if q and q.isBot and q.alive and q.spawned and q.userId == nil
			and not fauxIds[id] and q.tileCount >= REVIVE_MIN_TILES and q.id ~= excludeId
			and (sim.teamCount == 0 or sim.teamOf[id] == nil or sim.teamOf[id] == team)
		then
			local dx = q.sumX / q.tileCount - fx
			local dy = q.sumY / q.tileCount - fy
			local d = dx * dx + dy * dy
			if q.tileCount <= maxTiles then
				if best == nil or d < bestD or (d == bestD and q.id < best.id) then
					best, bestD = q, d
				end
			elseif fallback == nil or d < fallbackD then
				fallback, fallbackD = q, d
			end
		end
	end
	return best or fallback
end

-- THE BASICS, FOR SOMEBODY WHO SKIPPED THE LESSON TO GET HERE. The three cards
-- that teach the taps -- open land, a rival, a city -- on a session of their
-- own with none of the tutorial's round-wide dials (see Tutorial.attach, lite).
-- Decided off the profile, which lands seconds after they do; the flag itself
-- stays unset, so the full tutorial still runs on their next visit alone.
-- `force` skips the profile question (the Studio probe).
-- `allyId` is the friend's empire: the lesson never points a card at them.
local function startLiteLesson(player: Player, empireId: number, force: boolean?, allyId: number?)
	local why: string? = nil
	if not force then
		if Data.wait(player, 15) == nil or player.Parent == nil then
			why = "no profile"
		elseif Data.tutorialSeen(player) then
			why = "tutorial already seen"
		end
	end
	if why == nil then
		local mine = if sim ~= nil then sim:playerByUserId(player.UserId) else nil
		if sim == nil or sim.phase ~= "playing" then
			why = "round not running"
		elseif mine == nil or mine.id ~= empireId then
			why = "no longer holds that empire"
		elseif lessons[player.UserId] ~= nil then
			why = "already on a lesson"
		end
	end
	if why ~= nil then
		print(("[Conquest] no lite lesson for %s: %s"):format(player.Name, why))
		return false, why
	end
	local lesson = Tutorial.attach(sim, empireId, nil, true)
	lesson.allyId = allyId
	lessons[player.UserId] = lesson
	StateRE:FireClient(player, "tutorial", Tutorial.state(lesson))
	Analytics.event("follow_lesson", player, 1, { result = "start" })
	print(("[Conquest] lite lesson started for %s on empire %d"):format(player.Name, empireId))
	return true, ""
end

-- Returns ok, reason. Safe to call for anybody: it refuses rather than throws.
-- `lessonMode`: nil lets the profile decide the lite lesson (production), true
-- forces it, false skips it (the /testmidjoin "vet" run).
local function followTakeover(player: Player, friendUserId: number, lessonMode: boolean?): (boolean, string)
	if sim == nil or sim.phase ~= "playing" then
		return false, "the round is not running"
	end
	if tutorialSession ~= nil then
		return false, "not in the tutorial"
	end
	if sim:playerByUserId(player.UserId) ~= nil then
		return false, "already holds an empire"
	end
	-- THE FRIEND, IF THEY ARE STILL STANDING. A follower whose friend has been
	-- knocked out -- or who has already left -- still gets a nation, because
	-- watching somebody else's war is the worst thing this could hand them:
	-- the free bot nearest the friend's last ground, or the biggest free bot
	-- when there is no friend on the board at all (reviveCandidate).
	local friendEmpire = sim:playerByUserId(friendUserId)
	local friendTeam = if sim.teamCount > 0 and friendEmpire ~= nil then sim.teamOf[friendEmpire.id] else nil
	local q: any = nil
	if friendEmpire ~= nil and friendEmpire.alive and friendEmpire.spawned and friendEmpire.tileCount > 0 then
		q = followCandidate(friendEmpire.sumX / friendEmpire.tileCount, friendEmpire.sumY / friendEmpire.tileCount,
			friendEmpire.tileCount * FOLLOW_MAX_RATIO, friendTeam, friendEmpire.id)
	elseif friendEmpire ~= nil and type(friendEmpire.deathTile) == "number" then
		q = followCandidate(friendEmpire.deathTile % Config.MAP_W, math.floor(friendEmpire.deathTile / Config.MAP_W),
			math.huge, friendTeam, friendEmpire.id)
	else
		q = reviveCandidate()
	end
	if q == nil then
		return false, "no empire is free to take"
	end
	local wasName = q.name
	local friendName = if friendEmpire ~= nil then friendEmpire.name else "a friend who has left"
	-- Whatever the bot had in flight comes home first: nobody should take
	-- command mid-way through a war they did not start.
	sim:cancelAttacks(q.id)
	adoptEmpire(player, q, friendTeam)
	Analytics.matchStarted(player, sim.mapId, sim.modeId, false)
	Analytics.matchSpawned(player)
	Analytics.event("follow_takeover", player, 1, { empire = q.id, tiles = q.tileCount, friend = friendUserId })
	print(("[Conquest] %s followed %s in and took command of %s (empire %d, %d tiles)"):format(
		player.Name, friendName, wasName, q.id, q.tileCount))
	-- THE BASICS, FOR SOMEBODY WHO SKIPPED THE LESSON TO GET HERE. The three
	-- cards that teach the taps -- open land, a rival, a city -- on a session
	-- of their own with none of the tutorial's round-wide dials (see
	-- Tutorial.attach, lite). Decided off the profile, which lands seconds
	-- after they do; the flag itself stays unset, so the full tutorial still
	-- runs on their next visit alone.
	if lessonMode ~= false then
		task.spawn(startLiteLesson, player, q.id, lessonMode == true, if friendEmpire ~= nil then friendEmpire.id else nil)
	end
	return true, wasName
end

-- /testmidjoin (ConquestMidJoinTest): what a follower sees, on ONE client.
-- Your own empire is handed to a bot wearing a stand-in friend's name and
-- face, you get the spectator init a late arrival gets, and a beat later the
-- takeover runs through exactly the code PlayerAdded runs for a follower --
-- the fresh init, the camera onto the new land, the lesson cards when
-- `newbie`. `report` is told how it went once that deferred half has run.
-- What this cannot replay is the lobby's toast and the teleport in front.
_G.ConquestTestMidJoin = function(player: Player, newbie: boolean, report: ((string) -> ())?): (boolean, string)
	if sim == nil or sim.phase ~= "playing" then
		return false, "no war running -- /world first, and wait for the spawn phase to end."
	end
	if tutorialSession ~= nil then
		return false, "not in the tutorial."
	end
	local mine = sim:playerByUserId(player.UserId)
	if mine == nil or not mine.spawned or not mine.alive or mine.tileCount <= 0 then
		return false, "you need a living empire to hand to the stand-in friend."
	end
	-- THE STAND-IN FRIEND wears user id 1 for a face. A previous run's
	-- stand-in gives the id back first.
	local FRIEND_ID = 1
	local prev = sim.byUserId[FRIEND_ID]
	if prev ~= nil and prev ~= mine.id and sim.players[prev] ~= nil then
		sim.players[prev].userId = nil
	end
	sim.byUserId[player.UserId] = nil
	sim.byUserId[FRIEND_ID] = mine.id
	mine.userId = FRIEND_ID
	mine.name = "Your Friend"
	mine.isBot = true
	mine.tier = Config.DEFAULT_BOT_TIER
	lessons[player.UserId] = nil
	StateRE:FireAllClients("roster", roster())
	-- The arrival, in the order PlayerAdded does it: the spectator init...
	sendInit(player)
	-- ...then the takeover a beat later.
	task.defer(function()
		if player.Parent == nil then
			return
		end
		local ok, res = followTakeover(player, FRIEND_ID, newbie)
		if report == nil then
			return
		end
		if ok then
			local q = sim and sim:playerByUserId(player.UserId)
			report(("you took command of %s (%d tiles) beside Your Friend%s"):format(
				res, q and q.tileCount or 0,
				newbie and " -- the three lesson cards follow in a second." or " -- cards off."))
		else
			report("the takeover stood down: " .. res)
		end
	end)
	return true, "handing your empire to a stand-in friend and arriving beside them..."
end

-- STUDIO ONLY: a probe the plugin bridge can invoke during a playtest, since
-- `_G` is not shared with it there. Never exists on a live server. Ops:
--   "follow", userId, friendUserId  -> followTakeover for that player
--   "fakefriend", userId            -> hands the player's own empire to a bot
--                                      wearing userId 1, so a one-client
--                                      session has a "friend" to follow
--   "state", userId                 -> which empire the player holds now
if game:GetService("RunService"):IsStudio() then
	local probe = Instance.new("BindableFunction")
	probe.Name = "__ConquestFollowProbe"
	probe.OnInvoke = function(op: string, userId: number, friendUserId: number?)
		local player = Players:GetPlayerByUserId(userId)
		if sim == nil then
			return false, "no round"
		end
		if op == "follow" and player ~= nil and friendUserId ~= nil then
			return followTakeover(player, friendUserId)
		elseif op == "fakefriend" and player ~= nil then
			local p = sim:playerByUserId(userId)
			if p == nil then
				return false, "no empire to hand over"
			end
			sim.byUserId[userId] = nil
			sim.byUserId[1] = p.id
			p.userId = 1
			p.name = "FakeFriend"
			p.isBot = true
			p.tier = Config.DEFAULT_BOT_TIER
			StateRE:FireAllClients("roster", roster())
			return true, p.id
		elseif op == "lesson" and player ~= nil then
			local p = sim:playerByUserId(userId)
			return true, {
				ready = Data.isReady(player),
				seen = Data.tutorialSeen(player),
				memoryOnly = Data.isMemoryOnly(),
				phase = sim.phase,
				empire = p and p.id or 0,
				onLesson = lessons[userId] ~= nil,
				step = lessons[userId] and lessons[userId].stepIndex or 0,
			}
		elseif op == "forcelesson" and player ~= nil then
			local p = sim:playerByUserId(userId)
			if p == nil then
				return false, "no empire"
			end
			return startLiteLesson(player, p.id, true)
		elseif op == "state" then
			local p = sim:playerByUserId(userId)
			return true, {
				phase = sim.phase,
				empire = p and p.id or 0,
				name = p and p.name or "",
				isBot = p and p.isBot or nil,
				tiles = p and p.tileCount or 0,
				troops = p and math.floor(p.troops) or 0,
				tier = p and p.tier or nil,
				team = p and sim.teamOf[p.id] or nil,
			}
		end
		return false, "bad op"
	end
	probe.Parent = game:GetService("ServerStorage")
end

-- THE BUTTON AND THE RECEIPT BOTH LAND HERE. A token in hand is spent; none in
-- hand prompts the purchase, and the grant's hook comes back through this same
-- function carrying the token it just added. `fromReceipt` stops the hook from
-- prompting a second purchase when the first cannot be honoured yet.
local function tryRevive(player: Player, fromReceipt: boolean?)
	if reviving[player.UserId] then
		return
	end
	reviving[player.UserId] = true
	local ok, why = canRevive(player)
	if ok and Data.reviveTokens(player) > 0 then
		local done, reason = takeover(player)
		if done then
			if not Data.spendReviveToken(player) then
				warn("[Conquest] revive token vanished under " .. player.Name)
			end
			task.spawn(Data.flush, player)
		else
			print(("[Conquest] revive refused for %s: %s"):format(player.Name, reason))
			offerRevive(player)
		end
	elseif ok and not fromReceipt then
		-- Nothing in hand: the site's prompt. Refused silently by Monetization
		-- while the product has no id, which is a deploy fact and not news.
		Monetization.promptProduct(player, "REVIVE")
	elseif not ok then
		print(("[Conquest] revive not possible for %s: %s"):format(player.Name, why))
		if not fromReceipt then
			offerRevive(player)
		end
	end
	reviving[player.UserId] = nil
end

-- THE DEV ROUTE, beside /endgame's: the same function the button reaches,
-- exposed so a test can drive a takeover without a receipt. Read from _G every
-- call, never cached, for the reason ConquestEndRound gives.
_G.ConquestRevive = function(player: Player)
	tryRevive(player, false)
end

-- A REVIVE BOUGHT MID-MATCH IS HONOURED THE MOMENT THE RECEIPT IS DURABLE. On
-- a lobby server (no sim) or after the round, canRevive says no and the token
-- simply waits on the profile.
Monetization.onGranted(function(player, entry)
	if entry.key == "REVIVE" and player.Parent ~= nil then
		tryRevive(player, true)
	end
end)

-- ======================================================= the tutorial four ==
-- "+1 Nuke!", "+1 Million Army Size!", "+1 Million Gold!" and "Special Forces
-- (2x Attack Speed)!" (owner, 2026-09-12). Bought as developer products,
-- banked as tokens by ConquestMonetization, and spent HERE.
--
-- TUTORIAL ONLY. This is the gate the whole design rests on rather than a
-- nicety -- MONETIZATION.txt section 0 says troops, gold, warheads and
-- expansion rate are the four things this game must never sell, because in a
-- zero-sum territory game each one is taken out of somebody else's round. In a
-- tutorial there is nobody else: bots for a roster, the student protected for
-- the grace window. So the refusal below is not a policy, it is what makes
-- these four legal to sell at all. `canRevive` refuses while a tutorial is
-- running; this refuses while one is NOT -- and also refuses a player who is
-- on a tutorial server without being its student.
--
-- The effects that live on the sim player (ceiling, attack speed, free shot)
-- die with the round, which is correct: the lesson is what was bought. Tokens
-- outlive it, so nothing is lost buying on the way out.
-- BOTH STARTER PACKS OUT OF ONE FUNCTION. #1 and #2 differ in three numbers,
-- and two of those three are the same number -- so writing the grant twice
-- would only be creating somewhere for them to drift apart. What differs is in
-- Config; what happens is here.
--
-- `troopOverflow` is borrowed from TUTORIAL_ARMY and means here what it means
-- there: this army may sit above the cap until it is spent, and the flag
-- clears itself in Sim's growth loop the first tick the troops fall back
-- under. Without it the very next tick snaps the purchase away.
--
-- THE TOWERS ARE NOT PLACED HERE, because a structure needs a tile and a
-- redeem has no idea which one the player wants. What is granted is the RIGHT
-- to place them, spent at the build itself (Economy.build) -- the same shape
-- the free warhead uses, which is spent at the launch. One post per free
-- build, so a count of three is three buildings whenever the player likes.
local function starterPack(gold: number, army: number, posts: number, cities: number?, sams: number?): (any) -> ()
	return function(p)
		p.gold += gold
		-- The overflow flag only when there are troops to overflow with: #2
		-- grants none, and a flag set for nothing is a flag someone reads later.
		if army > 0 then
			p.troops += army
			p.troopOverflow = true
		end
		p.freePosts = (p.freePosts or 0) + posts
		-- Starter Pack #2's buildings (2026-09-17 evening): a city and an
		-- anti-nuke tower, granted as the RIGHT to place one each and spent at
		-- the build -- the posts' shape, one field per kind (Economy.FREE_FIELD).
		p.freeCities = (p.freeCities or 0) + (cities or 0)
		p.freeSams = (p.freeSams or 0) + (sams or 0)
	end
end

-- WHAT THE PLAYER WAS TRYING TO BUILD WHEN THE GOLD RAN OUT, per user id.
--
-- A top-up is bought at a refused build click, and by the time the receipt is
-- durable that click is long gone -- so the tile and the kind are parked here
-- the moment the client offers, and the redeem spends them. Keyed by USER ID
-- and stamped with the ROUND: an intent from a previous round names a tile on a
-- map that no longer exists, and replaying it would drop a city in the sea.
local pendingBuild: { [number]: { tile: number, kind: number, round: number } } = {}

-- THE AIRFIELD A "SKIP" WILL REARM, parked at the refusal that offered it
-- (offerSkipRearm, below the redeem), and WHEN each player was last asked.
-- Same shape as pendingBuild for the same reason: the receipt is seconds
-- behind the press, on a server that no longer knows which field was tapped.
-- `unit` is the unit's id (2026-09-25): the park can name a railgun too, and
-- a railgun SITE, so the redeem looks the unit up rather than re-deriving it.
local pendingRearm: { [number]: { tile: number, unit: number?, round: number } } = {}
local rearmAskedAt: { [number]: number } = {}

-- THE TOP-UP REDEEM, and it is NOT a gold grant (owner, 2026-09-17: "it should
-- place the building down where the user wanted it. and set the players gold to
-- 0"). The product finishes the transaction the player was already making.
--
-- THE GOLD IS SET TO THE PRICE AND THE ORDINARY BUILD PATH IS RUN. That is the
-- whole trick and it is why this is short: `sim:buildStructure` already owns
-- spacing, terrain, ownership, the max-level rule, the port's coast snap and
-- the charge itself, so funding exactly the cost and letting it charge normally
-- lands the treasury on zero by arithmetic rather than by a second write. NO
-- LEGALITY CHECK IS SKIPPED -- a top-up cannot put a city anywhere a click
-- could not, which is what keeps this from being a way to buy past the spacing
-- rule.
--
-- AND IF IT CANNOT BE PLACED, THE MONEY IS NOT LOST. The tile goes stale
-- easily -- somebody else builds there, the land changes hands, the round ends
-- -- and a purchase that silently evaporates is the worst outcome available
-- here. Every failure falls back to the plain gold grant this product used to
-- be, which is also what a receipt landing with no pending build at all gets.
local function topUp(amount: number): (any) -> ()
	return function(p)
		local pend = p.userId and pendingBuild[p.userId]
		-- Spent whether or not it works: a stale intent must never be retried
		-- against the next purchase. Cleared BEFORE the freshness test, so a park
		-- that has gone stale is thrown away rather than left to ambush the
		-- purchase after this one.
		if pend ~= nil then
			pendingBuild[p.userId] = nil
		end
		-- A PARK GOES STALE. It used to be cleared only by a redeem, so a player
		-- who was refused a city at minute two, cancelled the prompt, and bought
		-- gold for a NUKE at minute eight had that eight-minute-old park spend
		-- the purchase on the city instead -- a building they no longer wanted,
		-- and the warhead they were saving for still unbought. The prompt itself
		-- is one press and a dialog; three minutes is generous for that.
		local fresh = pend ~= nil
			and pend.round == roundId
			and (os.clock() - (pend.at or 0)) <= 180
		if fresh and sim ~= nil and sim.phase == "playing" then
			local before = p.gold
			local price = sim.structureCost(p, pend.kind)
			-- WHAT THEY HAD PLUS WHAT THEY JUST BOUGHT has to cover the building.
			-- This used to fund the treasury to the structure's PRICE whatever
			-- pack was bought, so a 9 Robux top-up (100,000 gold) completed a
			-- 3,000,000 gold anti-nuke tower -- and it is not only an exploit:
			-- GoldTopUpClient offers the largest pack for every shortfall above
			-- the middle rung, "including shortfalls it cannot actually close",
			-- so honest players were being handed buildings they underpaid for.
			local funds = before + amount
			if price <= funds then
				p.gold = funds
				local ok, _why, landed = sim:buildStructure(p.id, pend.tile, pend.kind)
				if ok then
					-- ...AND THE CHANGE IS THEIRS. buildStructure has already
					-- charged the price, so what is left is exactly the gold they
					-- walked in with plus the pack, minus the building. Zeroing it
					-- confiscated a treasury they had saved for something else.
					--
					-- The same message an ordinary build sends, so the client pings
					-- the tile and repaints the treasury exactly as it would have.
					local plr = Players:GetPlayerByUserId(p.userId)
					if plr ~= nil then
						StateRE:FireClient(plr, "built", {
							tile = landed or pend.tile,
							kind = pend.kind,
							gold = math.floor(p.gold),
							cost = math.floor(price),
						})
					end
					return
				end
				p.gold = before
			end
		end
		p.gold += amount
	end
end

-- THE SKIP REDEEM (owner, 2026-09-22: the "skip time" product on a refused
-- sortie). What is sold is THE REST OF THIS REARM: the field the player was
-- refused on, parked at the offer, has its launch tick popped -- Units.reload,
-- the very call Airstrikes.step makes when the clock runs out, so every
-- client's chip bar clears through the same unit event it always has.
--
-- AND IF THAT FIELD CANNOT TAKE IT, THE MONEY IS NOT LOST. The parked field
-- may have rearmed on its own while the dialog was up, been razed, changed
-- hands, or belong to a round that has ended. Then it is the buyer's field
-- with the LONGEST rearm left instead; and with no field of theirs rearming
-- at all, the purchase becomes the NEXT sortie's rearm -- `p.rearmSkips`,
-- which Airstrikes.order (and Railgun.order) spends the moment one flies.
-- One unit per purchase, never all of them: the prompt was for one.
--
-- THE RAILGUN BUYS THE SAME SKIP (owner, 2026-09-25: "for railgun build and
-- reload, sell reload thingy"): its reload pops exactly like a field's rearm,
-- and a railgun still GOING UP has its build finished instead -- buildDoneTick
-- set to now, so Units.stepConstruction completes it on the next tick with
-- the ordinary completion event. Only the railgun's build is for sale; every
-- other site keeps its clock.
local function skipRearm(p: any)
	local pend = p.userId and pendingRearm[p.userId]
	if p.userId then
		-- Spent whether or not it lands: a stale park must never be retried
		-- against the next purchase.
		pendingRearm[p.userId] = nil
	end
	-- Ticks a unit of the buyer's still owes, or nil if a skip can't touch it.
	local function owed(u: any): number?
		if u == nil or not u.active or u.ownerId ~= p.id then
			return nil
		end
		if u.underConstruction then
			return if u.utype == Units.RAILGUN then u.buildDoneTick - sim.tick else nil
		end
		return Units.reloadLeft(sim, u)
	end
	local pick = nil
	if pend ~= nil and pend.round == roundId and pend.unit ~= nil then
		local u = sim.units[pend.unit]
		if (owed(u) or 0) > 0 then
			pick = u
		end
	end
	if pick == nil then
		local best = 0
		for _, kind in { Units.AIRFIELD, Units.RAILGUN } do
			for _, u in Units.ofType(sim, kind) or {} do
				local left = owed(u) or 0
				if left > best then
					best, pick = left, u
				end
			end
		end
	end
	local plr = p.userId and Players:GetPlayerByUserId(p.userId)
	if pick ~= nil then
		local built = pick.underConstruction == true
		if built then
			pick.buildDoneTick = sim.tick
		else
			Units.reload(sim, pick)
		end
		-- The sentence to go with the bar clearing: a purchase with no
		-- acknowledgement reads as one that failed.
		if plr ~= nil then
			StateRE:FireClient(plr, "rearmed", { tile = pick.tile, kind = pick.utype, built = built })
		end
		return
	end
	p.rearmSkips = (p.rearmSkips or 0) + 1
	if plr ~= nil then
		StateRE:FireClient(plr, "rearmed", { next = true })
	end
end

local BOOSTS: { [string]: (any) -> () } = {
	TUTORIAL_NUKE = function(p)
		p.freeNukes = (p.freeNukes or 0) + 1
	end,
	-- THE MEN, NOT THE CEILING (owner, 2026-09-12: "+1 M army should give the
	-- troops all at once, can beat the capacity"). It raised maxTroops first,
	-- so the purchase arrived as permission to refill slowly rather than as an
	-- army -- and a refill is the one thing a student in a lesson has no time
	-- for. The troops land whole now, above the cap, and `troopOverflow` is
	-- what stops Sim's growth loop snapping them back on the very next tick.
	-- See the note there for why that snap exists and why this cannot abuse
	-- it: the flag is set nowhere else and clears itself once the army is
	-- spent back under its ceiling.
	TUTORIAL_ARMY = function(p)
		p.troops += Config.TUTORIAL_ARMY_BONUS
		p.troopOverflow = true
	end,
	TUTORIAL_GOLD = function(p)
		p.gold += Config.TUTORIAL_GOLD_BONUS
	end,
	-- SET, not multiplied: "2x" is the product, and a second one stacking to
	-- 4x would be selling a number the name does not say. The redeem refuses
	-- before it spends when it is already on, so the token stays in hand.
	TUTORIAL_FORCES = function(p)
		p.attackSpeed = Config.TUTORIAL_ATTACK_SPEED
	end,
	-- THE STARTER PACKS (2026-09-17): the only entries here that grant three
	-- things at once, and the only ones that deliberately STACK. There is no
	-- "already on" guard like FORCES' above because every part of a pack is a
	-- quantity rather than a switch, and the owner sells them repeatably.
	--
	-- #2 IS BUILDINGS, NOT NUMBERS (owner, 2026-09-17 evening): no troops, no
	-- gold -- three defence posts, one city and one anti-nuke tower, every one
	-- a free build in hand. Nothing here checks for #1 -- they are two
	-- independent goods that happen to be numbered, and buying both grants
	-- both.
	STARTER_PACK = starterPack(
		Config.STARTER_PACK_GOLD_BONUS,
		Config.STARTER_PACK_ARMY_BONUS,
		Config.STARTER_PACK_POSTS
	),
	STARTER_PACK2 = starterPack(
		Config.STARTER_PACK2_GOLD_BONUS,
		Config.STARTER_PACK2_ARMY_BONUS,
		Config.STARTER_PACK2_POSTS,
		Config.STARTER_PACK2_CITIES,
		Config.STARTER_PACK2_SAMS
	),

	-- THE GOLD TOP-UPS (2026-09-17). What they hand over is not gold: it is THE
	-- BUILDING THE PLAYER WAS REFUSED, on the tile they picked, with the treasury
	-- emptied. The amount passed here is only the FALLBACK for when that cannot
	-- be honoured -- see `topUp` above.
	GOLD_SMALL = topUp(Config.TOPUP_SMALL),
	GOLD_MEDIUM = topUp(Config.TOPUP_MEDIUM),
	GOLD_BIG = topUp(Config.TOPUP_BIG),

	-- THE AIRFIELD'S SKIP (2026-09-22): the rest of one rearm. See skipRearm.
	SKIP_REARM = skipRearm,
}

-- Returns ok and a reason a player can read, like takeover(). The refusal
-- order matters: everything that can turn a redeem down is checked BEFORE
-- Data.spendBoost, so a refused redeem never costs a token.
local function redeemBoost(player: Player, key: string): (boolean, string)
	local apply = BOOSTS[key]
	if apply == nil then
		return false, "not a tutorial boost"
	end
	if sim == nil or sim.phase ~= "playing" then
		return false, "the round is not running"
	end
	-- THE TUTORIAL GATE IS GONE (owner, 2026-09-16: "make it do stuff for the
	-- other 3"). It read:
	--     if tutorialSession == nil or player.UserId ~= tutorialUserId then
	--         return false, "tutorial only"
	--     end
	-- and it was the whole reason a bought boost did nothing: the store shows all
	-- four cards in every round, `onGranted` fires the moment the receipt is
	-- durable, and this line turned every one of those redeems down. The token
	-- banked and nothing ever spent it -- redeemBoost has only two callers, this
	-- hook and _G.ConquestBoost, and neither runs at the start of a later lesson.
	-- So the money left the player and nothing arrived.
	--
	-- WHAT THIS CHANGES, STATED PLAINLY. MONETIZATION.txt section 0 holds that
	-- troops, gold and a warhead must never be sold, because this game is zero-sum
	-- over land and each of them is taken out of somebody else's round. That
	-- argument is why the gate existed. Removing it is the owner's call and it is
	-- deliberate, not an oversight -- but the products are no longer
	-- tutorial-only in effect, whatever their names say.
	--
	-- EVERY OTHER REFUSAL STAYS. A boost still needs a running round, a live
	-- empire belonging to the buyer, and a token in hand, and all of those are
	-- still checked before Data.spendBoost so a refused redeem never costs one.
	local p = sim:playerByUserId(player.UserId)
	if p == nil or not p.alive then
		return false, "no empire to give it to"
	end
	if key == "TUTORIAL_FORCES" and (p.attackSpeed or 1) >= Config.TUTORIAL_ATTACK_SPEED then
		return false, "already on"
	end
	if Data.boostTokens(player, key) <= 0 then
		return false, "none in hand"
	end
	if not Data.spendBoost(player, key) then
		return false, "none in hand"
	end
	apply(p)
	task.spawn(Data.flush, player)
	print(("[Conquest] %s redeemed %s"):format(player.Name, key))
	return true, ""
end

-- A BOOST BOUGHT DURING THE LESSON IS APPLIED THE MOMENT THE RECEIPT IS
-- DURABLE, the same way a mid-match revive is. Bought anywhere else -- the
-- lobby, after the track ended -- the redeem says no and the token simply
-- waits on the profile for the next lesson.
Monetization.onGranted(function(player, entry)
	if BOOSTS[entry.key] ~= nil and player.Parent ~= nil then
		redeemBoost(player, entry.key)
	end
end)

-- THE ROUTE FOR THE UI THAT IS NOT BUILT YET (owner, 2026-09-12: "you just
-- need the code for it rn, ill wire it up later"). A button, an intent or a
-- console line all land here; read from _G every call, never cached, for the
-- reason ConquestEndRound gives.
_G.ConquestBoost = function(player: Player, key: string): (boolean, string)
	return redeemBoost(player, key)
end

-- THE SKIP OFFER (owner, 2026-09-22: "if a player fires the airfield during
-- its rearm phase, if theyre nowehere close (less than 75% of the rearm time)
-- prompt this: 3714242483 skip time dev product"). Called from the airstrike
-- intent on its "cooldown" refusal and nowhere else, AFTER the "denied" has
-- gone out -- the banner still says why, and the prompt is what follows.
--
-- IT IS THE ROBLOX PURCHASE PROMPT, NOT A PAGE -- the top-ups' rule -- and it
-- is sent FROM THE SERVER, as the revive prompt above is: the server is what
-- knows how much of the rearm is left, so the judgement is made here rather
-- than shipped down for a client script to make. Analytics' prompt funnel is
-- inside promptProduct, so nothing is recorded twice.
--
-- NEARLY THERE: SAY NOTHING. Under Config.SKIP_REARM_OFFER_BELOW of the rearm
-- elapsed the offer goes out; past it the sortie is seconds away for free and
-- a prompt there would be charging for that wait. The ask clock is per player
-- in wall-clock seconds because a purchase dialog is a modal, and asking twice
-- inside one rearm is a wall, not a shop. The field is parked BEFORE the
-- prompt and un-parked if no prompt went out, so a refused prompt (product
-- not configured) neither burns the clock nor leaves a stale park behind.
--
-- `rail` (2026-09-25) makes it the railgun's: its reload against
-- RAILGUN_COOLDOWN, or -- pressed while still going up -- its build against
-- RAILGUN_BUILD_TICKS, same 75% rule and the same ask clock.
local function offerSkipRearm(player: Player, p: any, fromTile: number, rail: boolean?)
	local u = if rail then require(Shared.Railgun).gunAt(sim, p.id, fromTile) else Airstrikes.airfieldAt(sim, p.id, fromTile)
	if u == nil or (u.underConstruction and not rail) then
		return
	end
	local left, total
	if u.underConstruction then
		left = u.buildDoneTick - sim.tick
		total = Config.RAILGUN_BUILD_TICKS or 150
	else
		left = Units.reloadLeft(sim, u)
		total = Units.cooldown(sim, u, if rail then (Config.RAILGUN_COOLDOWN or 250) else (Config.AIRSTRIKE_COOLDOWN or 600))
	end
	if left == nil or left <= 0 or total - left >= total * Config.SKIP_REARM_OFFER_BELOW then
		return
	end
	local now = os.clock()
	local last = rearmAskedAt[player.UserId]
	if last ~= nil and now - last < Config.SKIP_REARM_ASK_COOLDOWN then
		return
	end
	pendingRearm[player.UserId] = { tile = u.tile, unit = u.id, round = roundId }
	if Monetization.promptProduct(player, "SKIP_REARM") then
		rearmAskedAt[player.UserId] = now
	else
		pendingRearm[player.UserId] = nil
	end
end

-- Everyone whose result went final on this tick. The faux-empire check is the
-- same one the conquest payout makes: an AI can be WEARING an absent player's
-- user id (see reidentifyFaux), so the id alone is not proof that this Roblox
-- player owns that empire.
local function settleIds(ids: { number })
	for _, id in ids do
		local p = sim.players[id]
		local plr = p and p.userId and Players:GetPlayerByUserId(p.userId)
		if plr and sim:playerByUserId(plr.UserId) == p then
			settleMoney(plr)
			-- ...and, mid-round, the way back in. Their empire just fell; the
			-- receipt and this offer arrive together.
			if sim.phase == "playing" then
				offerRevive(plr)
			end
		end
	end
end

-- ================================================================== round ==

-- Rotates one step per round rather than picking at random: random
-- selection repeats, and repeating the map two rounds running is the single
-- thing players notice most in a game whose whole variety is the map.
local mapId: string? = nil
local modeId: string? = nil

-- `opts` is a PRIVATE LOBBY'S SETTINGS and nothing else ever has one: the
-- public board picks a map and a mode and takes the sim's own numbers for
-- everything else, so a public launch passes its match record straight through
-- and every dial below reads absent.
local function startRound(forceMap: string?, forceMode: string?, opts: any?)
	roundId += 1
	-- A NEW ROUND IS A NEW SESSION. Without this a Studio session that rotates
	-- in place after a tutorial would go on serving the last round's lesson
	-- cards, tested against a sim they know nothing about.
	tutorialSession = nil
	tutorialUserId = 0
	tutorialStepSeen = 0
	tutorialEnded = false
	tutorialOverAt = 0
	table.clear(lessons)
	-- A NEW ROUND IS A NEW FUNNEL, for the same reason: the spawn and the first
	-- attack are once-a-round steps, and a Studio session that rotates in place
	-- would otherwise go on reporting the first round's forever.
	Analytics.roundReset()
	-- THE ROUND SHAPE THE LESSON NEEDS: a small fixed roster, a grace window
	-- and a starting treasury. Everything else about a tutorial -- the map
	-- generation, the phases, the tick loop, the faux players, the wire -- is
	-- the ordinary round this function already builds, which is the point.
	local tutorial = (opts and opts.tutorial) == true
	print("[Conquest] version " .. Config.VERSION .. " -- round " .. roundId .. (tutorial and " (TUTORIAL)" or ""))
	-- A match server is TOLD its map and mode -- the pair the card advertised
	-- when players queued for it -- so it must not rotate. The rotation below
	-- is the fallback: a reserved server whose match record expired, or a
	-- Studio session started by hand.
	mapId = forceMap or Maps.next(mapId)
	-- Map and mode rotate on coprime cycles (7 maps x 3 modes), so the pair a
	-- player sees does not repeat inside twenty-one rounds.
	modeId = forceMode or Modes.next(modeId)
	sim = Sim.new(mapId :: string, math.random(1, 1000000), modeId)

	-- THE HOST'S DIALS, applied in the one window where all three are still
	-- unread. `assignTeamAnchors` already ran inside Sim.new against the
	-- mode's own team count, so a count the mode did not choose needs it run
	-- again -- and `addPlayer` assigns a team the moment it is called, which
	-- is the next thing that happens.
	if opts then
		sim.troopScale = tonumber(opts.troopScale) or 1
		sim.startGold = tonumber(opts.startGold) or 0
		local teams = tonumber(opts.teams) or 0
		if teams >= 2 and teams ~= sim.teamCount then
			sim.teamCount = teams
			Sim.assignTeamAnchors(sim)
		end
	end
	-- ...AND THE ONE DIAL A TUTORIAL SETS FOR ITSELF. Every empire in the
	-- lesson opens on a treasury, bots included -- see Tutorial.START_GOLD.
	--
	-- AFTER the host's dials rather than inside them, because a tutorial is
	-- not a private room: it has no host, so there is no setting of anybody
	-- else's for this to be arguing with.
	if tutorial then
		sim.startGold = Tutorial.START_GOLD
	end
	-- ...AND A SPECIAL MODE'S OPENING OUTRANKS EVERY DIAL ABOVE (Modes.SPECIAL,
	-- 2026-09-18: GOLD RUSH, MEGA ARMY, NUCLEAR WAR). Sim.new already applied
	-- it; it is applied AGAIN here because the dial block just wrote a private
	-- room's STARTING GOLD over it -- and a host who picked GOLD RUSH and left
	-- the gold row on NONE picked GOLD RUSH. In any other mode the call touches
	-- nothing, the tutorial's treasury included.
	Sim.applySpecial(sim)
	-- ...AND THE ONE DIAL A TUTORIAL TURNS OFF. The cheap opening rungs on the
	-- structure ladder (Config.CITY_COST_STEPS) are a real-match rule: the
	-- lesson's treasuries are written to sit under the price of a city, so at
	-- 25k the roster opens holding three and the build cards teach nothing.
	--
	-- ASSIGNED ON EVERY ROUND, not only inside the `if` above, because one
	-- server goes on to run ordinary rounds after a lesson and a flag left
	-- true would quietly reprice every one of them.
	Economy.tutorialPricing = tutorial
	-- Published for the sibling server scripts that reach into the live
	-- round (ConquestGold). A round REPLACES the Sim outright, so anything
	-- that cached one would be writing into a dead match; readers take it
	-- from here every time. Server scripts share _G, which is already how
	-- ConquestSimulate holds the round still.
	_G.ConquestSim = sim

	-- A NEW ROUND IS A NEW LEDGER. Attached before anybody is added so the
	-- tracker sees the first tick of the spawn phase; a tracker carried over
	-- from the last round would be watching a dead sim, and `moneyPaid` left
	-- standing would refuse to pay anyone a second round.
	moneyTracker = Money.track(sim)
	table.clear(moneyPaid)
	table.clear(revivedThisRound)

	-- Humans first so they get the low ids (and the brighter colours) -- and, in
	-- a team mode, so the clans are placed before the bots start levelling the
	-- sides up. Same tag, same team; see Sim.addPlayer.
	for _, player in Players:GetPlayers() do
		sim:addPlayer(nationNameFor(player), false, player.UserId, nil, tagFor(player))
		-- Their pattern, if the profile is already here. When it is not -- the
		-- ordinary case on a match server -- the `Data.onReady` hook at the
		-- foot of this file catches it a second or two later.
		applyPattern(player)
		applyFlag(player)
	end

	-- A HISTORICAL ROUND'S ROSTER IS THE SCENARIO'S. Every nation on the
	-- predrawn map is an AI empire from this moment, standing on its borders
	-- with its buildings up (Sim.loadScenario), and the people claim one each
	-- during the spawn phase. So no bot loop, no phantoms and no land formula
	-- below: the map says who is on it. The mode on a map with no scenario
	-- drawn falls through to an ordinary round -- ConquestWorld refuses that
	-- combination before it gets here, so this is belt and braces.
	local scenario = if Modes.isHistorical(modeId) and not tutorial then Scenarios.forMap(mapId :: string, modeId) else nil
	if scenario then
		sim:loadScenario(scenario)
	elseif Modes.isHistorical(modeId) then
		warn("[Conquest] historical mode on " .. tostring(mapId) .. " has no scenario -- running it as an ordinary round")
	end

	-- THE BOT COUNT NO LONGER EVENS THE SIDES, because a bot is not on one.
	-- A full AI is neutral (Sim.addPlayer), so a team mode's sides are the
	-- humans plus the phantom seats and nothing else -- padding the AI filler
	-- out to a whole number of sides would move the roster size and level
	-- nothing. Sides can now come out uneven by one, which the
	-- least-populated placement in Sim.addPlayer already keeps to a minimum.
	-- Bots FILL the roster instead of stacking on top of it. Every empire
	-- costs per-tick work all round -- income, an AI border sample, a row in
	-- every summary, a slot in the attack list -- so a full 24-player server
	-- adding a flat 12 bots ran 36 of them and cost roughly what 36 cost.
	local humans = #sim.playerOrder
	-- Roster scales with THIS map's playable land instead of being flat, so an
	-- empire's share of the map is the same whichever map came up. Upstream
	-- does exactly this and scales nothing else (MapPlaylist.ts:812-825).
	-- See Config.LAND_PER_EMPIRE.
	--
	-- A TUTORIAL STATES ITS ROSTER OUTRIGHT. That formula puts sixty-nine
	-- empires on the US and a lesson wants far fewer (`Tutorial.rosterSize`,
	-- which states its own figure): the pressure a tutorial
	-- needs is a NEIGHBOUR ARRIVING, and on a map divided sixty-nine ways the
	-- land grab is over before the third card. See Tutorial.rosterSize.
	local roster = tutorial
			and Tutorial.rosterSize()
		or math.clamp(
			math.floor(sim.playableLand / Config.LAND_PER_EMPIRE + 0.5),
			Config.MIN_EMPIRES,
			Config.TARGET_EMPIRES
		)
	-- A MAP MAY CAP THE ROSTER OUTRIGHT (Maps.MapData.MAX_EMPIRES). Korea is a
	-- 1v1: two empires INCLUDING the humans, and the second seat is a person if
	-- one is here and an AI wearing a person's name if not. A CEILING, not a
	-- figure -- it binds the tutorial's stated roster and the land formula
	-- alike, and it is applied before botCount so the fill sees the real number.
	local maxEmpires = tonumber((Maps.get(mapId :: string) :: any).MAX_EMPIRES)
	if maxEmpires then
		roster = math.min(roster, maxEmpires)
	end
	local botCount = if scenario then 0 else math.clamp(roster - humans, 0, Config.NUM_BOTS)
	-- A MAP MAY STATE ITS OWN AI COUNT (Maps.MapData.BOTS). The World map is
	-- 97,638 playable tiles, which the formula above reads as 26 empires --
	-- one per subcontinent and a slow start -- and the owner wants fifty AI
	-- on a planet. BOTS is a FIXED bot count, not a roster: humans come on
	-- top of it, and only TARGET_EMPIRES, the ceiling the sim was sized for,
	-- cuts it back. A tutorial keeps its own figure, exactly as above.
	local mapBots = tonumber((Maps.get(mapId :: string) :: any).BOTS)
	if mapBots and not tutorial and not scenario then
		botCount = math.clamp(math.min(mapBots, Config.TARGET_EMPIRES - humans), 0, Config.NUM_BOTS)
	end
	-- MAX_EMPIRES OUTRANKS BOTS. No map states both today; if one ever does, the
	-- cap is the thing that has to hold.
	if maxEmpires then
		botCount = math.min(botCount, math.max(0, maxEmpires - humans))
	end

	-- HOW MANY OF THOSE BOTS WEAR A NAME: exactly the number of PHANTOM SEATS
	-- the lobby card was advertising when it launched, and no more. The card
	-- said 3 / 6 with one real person in it, so this round owes two people --
	-- and it makes those two, rather than inventing a full lobby nobody was
	-- ever shown. `Matchmaker.phantoms` decided the figure; it travels in the
	-- match record (or on LOCAL_PHANTOMS_ATTR in Studio).
	--
	-- Absent means NONE: a private room promised nobody, and a match server
	-- whose record expired has no card to make good on. FAUX_MAX is only a
	-- ceiling in case the phantom range is ever widened.
	--
	-- A TUTORIAL PROMISED ITS OWN. There is no lobby card behind it -- you
	-- pressed LEARN TO PLAY and were sent to a server of your own -- so the
	-- figure comes from Tutorial.FAUX_COUNT instead, and the first round a new
	-- player ever sees has three people in it rather than fifteen nations
	-- called Ostmark.
	table.clear(fauxIds)
	table.clear(fauxIdentity)
	local promised = tonumber(opts and opts.phantoms)
		or (tutorial and Tutorial.FAUX_COUNT)
		or 0
	local fauxCount = math.clamp(promised, 0, math.min(FAUX_MAX, botCount))
	-- A MAP MAY STATE ITS OWN FAUX COUNT (Maps.MapData.FAUX, 2026-09-25): the
	-- owner wants Eurasia's 72 empires to be 60 "players". That is a share of
	-- the bots like every other faux seat -- humans are seated first and the
	-- figure shrinks to fit -- and it is not a lobby promise, so FAUX_MAX (the
	-- phantom ceiling) does not bind it. Past the nine cleared friends the
	-- draw hands out invented crowd identities; see Faces.
	local mapFaux = tonumber((Maps.get(mapId :: string) :: any).FAUX)
	if mapFaux and not tutorial and not scenario then
		fauxCount = math.clamp(mapFaux, 0, botCount)
	end
	if fauxCount > 0 then
		-- Nobody actually in the room may be impersonated: two rows wearing
		-- one face is the single thing that reads as fake.
		local taken: { [number]: boolean } = {}
		for _, player in Players:GetPlayers() do
			taken[player.UserId] = true
		end
		for _, identity in Tutorial.drawIdentities(sim.seed, fauxCount, taken) do
			-- THE USER ID GOES ON AFTER addPlayer, NEVER THROUGH IT. addPlayer
			-- registers `byUserId`, which is how a joining Roblox player is
			-- matched to their empire -- so a faux empire holding a real
			-- friend's id would hand that friend the BOT if they ever joined
			-- this server.
			local p = sim:addPlayer(identity.display, true, nil, FAUX_TIER, nil, true)
			if p then
				p.userId = identity.userId
				fauxIds[p.id] = true
				fauxIdentity[p.id] = identity
				botCount -= 1
			end
		end
	end

	local names = table.clone(BOT_NAMES)
	for i = #names, 2, -1 do
		local j = math.random(1, i)
		names[i], names[j] = names[j], names[i]
	end
	for i = 1, botCount do
		sim:addPlayer(names[((i - 1) % #names) + 1] .. (i > #names and (" " .. i) or ""), true, nil)
	end

	sim.phase = "spawn"
	sim.phaseTick = 0

	-- THE LESSON TRACK, laid over a round that is otherwise exactly like every
	-- other one. The student is the one human, and humans are added first, so
	-- they hold the first slot in playerOrder. A tutorial server nobody reached
	-- has no student and simply runs as a small match, which is the right thing
	-- for it to do rather than erroring on a nil.
	if tutorial and humans > 0 then
		local student = sim.players[sim.playerOrder[1]]
		if student then
			-- NOTHING IS WRITTEN TO `student.gold` HERE, and a session that tried
			-- would be wasting its time: the student has not picked a homeland
			-- yet, and `Sim.spawnPlayer` overwrites the treasury with
			-- `sim.startGold` when they do. The student's own float is a GRANT on
			-- the second lesson card instead -- the first moment after the spawn.
			-- `sim.startGold` is set for this round too, further up, but it is a
			-- different statement: it opens the WHOLE roster on a treasury and is
			-- applied where the other round-shape dials are.
			tutorialSession = Tutorial.attach(sim, student.id, fauxIdentity)
			tutorialUserId = student.userId or 0
			-- Nobody may attack them for GRACE_SECONDS. Sim owns the refusal;
			-- this is what turns it on.
			Tutorial.protect(tutorialSession)
			tutorialStartedAt = os.clock()
			local studentPlayer = tutorialUserId ~= 0
					and Players:GetPlayerByUserId(tutorialUserId)
				or nil
			if studentPlayer then
				-- The map goes with it: this server knows what it built,
				-- and the per-map tutorial funnel is keyed on exactly that.
				Analytics.tutorialStarted(studentPlayer, #Tutorial.STEPS, mapId)
			end
		end
	end

	for _, player in Players:GetPlayers() do
		sendInit(player)
	end

	-- IN THE MATCH -- the funnel step that says the teleport chain worked. It
	-- is logged from HERE rather than from PlayerAdded so that it means "a
	-- round exists and they are in it", which is also true in Studio, where
	-- nobody was teleported anywhere.
	roundStartedAt = os.clock()
	for _, player in Players:GetPlayers() do
		Analytics.matchStarted(player, mapId, modeId, tutorial)
	end

	print(
		"[Conquest] round " .. roundId .. " -- " .. Maps.name(sim.mapId)
			.. " / " .. Modes.name(sim.modeId) .. " "
			.. Config.MAP_W .. "x" .. Config.MAP_H
			.. ", playable land " .. sim.playableLand .. " tiles"
			.. ", tile budget " .. sim.tileBudget
	)
end

-- ================================================================ intents ==

local lastIntent: { [number]: number } = {}
-- Separate from lastIntent because "hello" is answered BEFORE the intent rate
-- limit (a client asking for init has no empire yet) and sendInit ships the
-- whole owner snapshot -- which is not something to let anyone ask for eight
-- times a second.
local lastHello: { [number]: number } = {}
-- Who is already mid-teleport out. TeleportAsync is a yielding web call and the
-- button is two presses on a client we do not control, so without this a
-- doubled press stacks a second request on a player who is already going.
local leaving: { [number]: boolean } = {}

-- ONE PLAYER HOME, on their own. `returnToLobby` further down is the end of a
-- ROUND -- it takes everybody at once and latches the whole server -- and this
-- is the other exit: somebody who wants out of a match that is still running.
-- Same destination and the same reason for it (a public server of this place IS
-- the matchmaking page), and the same visit payload, so a player who leaves
-- early still reports as one session rather than as two short ones.
--
-- NOTHING IS SETTLED HERE. The teleport fires PlayerRemoving, which is where
-- settleMoney and matchQuit already live and where every other exit is paid --
-- doing it twice would pay the round twice.
-- `bounced`: a follower this server had no bot for, sent back so the lobby
-- opens the tutorial instead (MatchmakerServer reads it off the teleport data).
local function leaveToLobby(player: Player, bounced: boolean?)
	if leaving[player.UserId] then
		return
	end
	leaving[player.UserId] = true
	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({ cq = Analytics.teleportData({ player }), bounced = if bounced then true else nil })
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if not ok then
		-- Let them try again rather than stranding them in a match they have
		-- asked to leave -- which is exactly the state this button exists to
		-- fix, so failing into it silently would be the worst outcome.
		warn("[Conquest] leave teleport failed: " .. tostring(err))
		Analytics.hopCancelled(player)
		leaving[player.UserId] = nil
	end
end

-- DIPLOMACY: the AI's pending answers, { at = tick, from = asker, to = bot }.
-- Written by the intent handler below, read by stepDiplomacy at the foot of
-- the file -- so it is declared HERE, above both. (Declared beside its reader
-- first, which left the handler writing to a nil global: the live test's
-- "attempt to get length of a nil value".)
local allyAnswers: { any } = {}

IntentRE.OnServerEvent:Connect(function(player, payload)
	if typeof(payload) ~= "table" then
		return
	end

	-- A client that has finished building its view asks for its own init.
	-- Normally the broadcast from startRound is what it gets -- on a match
	-- server everybody arrives by teleport BEFORE the round begins -- but a
	-- client still assembling the renderer when that fired would otherwise
	-- sit on an empty map for a whole round.
	if payload.t == "hello" then
		local hnow = os.clock()
		-- -1e9, NOT 0. `os.clock()` counts from this VM's start, so for the first
		-- five seconds of a server's life `hnow - 5` is negative and a player
		-- nobody has seen before failed this test -- the one moment the message
		-- exists for. The client sends `hello` exactly once and never retries, so
		-- a client that finished building its view in that window got no init and
		-- sat on a blank map for the whole round. Every sibling limiter in this
		-- codebase already uses a far-past sentinel.
		if sim and (lastHello[player.UserId] or -1e9) < hnow - 5 then
			lastHello[player.UserId] = hnow
			sendInit(player)
		end
		return
	end

	-- ABOVE THE EMPIRE LOOKUP AND ABOVE THE TILE CHECK, both deliberately. A
	-- player who has been wiped off the map has no `p` and is the one most
	-- likely to want this; and leaving names no tile, so the validation below
	-- would throw it away. `leaving` is the rate limit -- the ordinary one is
	-- keyed on actions you repeat, and this is an action you take once.
	if payload.t == "leave" then
		-- ONLY A MATCH HAS SOMETHING TO LEAVE. Unguarded, a crafted client on the
		-- LOBBY page could fire this and teleport itself to another public server
		-- of the place, abandoning any queued board seat without going through
		-- leaveAll. Self-inflicted, but it is not a thing the lobby offers.
		if IS_MATCH and sim ~= nil then
			leaveToLobby(player)
		end
		return
	end

	-- REVIVE, above the empire lookup for the same reason: the person asking
	-- has just been wiped off the map. Its own, slower floor -- a purchase
	-- prompt is a web call, and nobody presses this eight times a second.
	if payload.t == "revive" then
		local rnow = os.clock()
		if (lastIntent[player.UserId] or 0) > rnow - 1.5 then
			return
		end
		lastIntent[player.UserId] = rnow
		tryRevive(player, false)
		return
	end

	local p = sim and sim:playerByUserId(player.UserId)
	if not p then
		return
	end

	local now = os.clock()
	if (lastIntent[player.UserId] or 0) > now - 0.12 then
		return
	end
	lastIntent[player.UserId] = now

	-- DIPLOMACY, above the tile check: an alliance intent names an EMPIRE, not
	-- a tile. Real games only (owner: "NOT tutorials") -- a lesson has nobody
	-- to ally with, and its client never shows the tab. Everything about
	-- whether the ask is legal (phase, alive, already allied, the 30 s
	-- cooldown) is Alliances.handleIntent's, and a refusal goes back on the
	-- same "ally" channel the outcomes ride so the row can say why.
	if Alliances.INTENT_KINDS[payload.t] ~= nil then
		if tutorialSession ~= nil then
			return
		end
		-- PLAYERS ONLY (owner, 2026-09-18: "players shouldnt be able to send
		-- alliance to AIs"). A faux player is a person as far as the whole
		-- game is concerned -- the wire calls it one -- so it stays askable
		-- and the AI answers for it below; an ordinary AI empire is refused
		-- with a reason the row can show.
		if payload.t == "ally" then
			local other = sim.players[math.floor(tonumber(payload.id) or 0)]
			if other and other.isBot and not fauxIds[other.id] then
				-- ...unless the AI asked FIRST. Answering an ask is not an ask
				-- (upstream: sending back is how you accept), and without this
				-- the cards /gotrequest files could never be accepted.
				local asked = false
				for _, r in Alliances.incomingRequests(sim, p.id) do
					if r.from == other.id then
						asked = true
						break
					end
				end
				if not asked then
					StateRE:FireClient(player, "ally", { k = "refused", id = other.id, why = "notaplayer" })
					return
				end
			end
		end
		local okCall, ok, why = pcall(Alliances.handleIntent, sim, p, payload)
		if not okCall then
			warn("[Conquest] diplomacy intent failed: " .. tostring(ok))
			return
		end
		if not ok then
			StateRE:FireClient(player, "ally", { k = "refused", id = payload.id, why = why })
			return
		end
		-- AN AI RECIPIENT ANSWERS LIKE A PERSON WOULD: after a beat, and by its
		-- own lights (NationAllianceBehavior's decision, run when the beat
		-- lands), never on the same tick the ask arrived. Faux players are
		-- bots here too, which is what keeps them convincing -- a row whose
		-- button could never be answered would give them away.
		if payload.t == "ally" then
			local other = sim.players[math.floor(payload.id)]
			if other and other.isBot and not Alliances.allied(sim, p.id, other.id) then
				allyAnswers[#allyAnswers + 1] = {
					at = sim.tick + sim.rng:NextInteger(20, 60),
					from = p.id,
					to = other.id,
				}
			end
		end
		return
	end

	-- REINFORCEMENTS (2026-09-21), above the tile check for the reason the
	-- diplomacy block is: the intent names NO tile, and the validation below
	-- would throw it away. Rate-limited by the ordinary 120 ms floor above,
	-- like every other intent. The sim owns the whole rule -- the share of the
	-- ceiling, the price, the room under the cap, the cooldown -- and re-quotes
	-- on this tick rather than trusting a figure; this branch only carries the
	-- answer back. `cost` is what was (or would have been) charged and
	-- `troops` what arrived, so the client can bump its own army figure and
	-- punch the readout on the same frame the reply lands. Refusals go on the
	-- same "denied" channel a build's do, with reasons the client already
	-- words: "full" (army at its ceiling), "cooldown", "gold".
	if payload.t == "reinforce" then
		-- THE BARRACKS BUNDLE'S CARD (2026-09-22, owner: "I only want people who
		-- have the gamepass to have access to it"). The rail puts the card up only
		-- for a holder (HUD, RAIL_ACTIONS.pass) and ConquestClient's `arm` shuts
		-- the E key; this is the half a crafted client cannot skip. The check is
		-- the attribute this server wrote when the site -- or a Money sale on the
		-- "+" page -- said yes (Monetization.holdsPass), so it costs no web call
		-- between the press and the men, and a Money buy mid-round opens the card
		-- at once. "pass" is the refusal the client already words; no kind rides
		-- with it, which is how buildRefusalText tells it from a building's.
		if not Monetization.holdsPass(player, "BARRACKS") then
			StateRE:FireClient(player, "denied", { reason = "pass" })
			return
		end
		local ok, why, troops, gold = sim:reinforce(p.id)
		StateRE:FireClient(player, ok and "reinforced" or "denied", {
			reason = why,
			troops = troops,
			gold = math.floor(p.gold),
			cost = gold,
		})
		return
	end

	local kind = payload.t
	local tile = payload.tile
	if typeof(tile) ~= "number" or tile ~= tile or tile < 0 or tile >= Config.NUM_TILES then
		return
	end
	tile = math.floor(tile)

	if kind == "spawn" then
		-- A CLICK PLACES THE DOT OR MOVES IT, as often as the phase lasts.
		-- This used to take the first click and silently refuse every one
		-- after it, so somebody who picked badly in the opening second of a
		-- round was stuck with that ground for the whole match.
		if sim.phase == "spawn" and not p.spawned then
			local ok, why, claim = sim:previewSpawn(p, tile)
			if ok then
				-- ON A PREDRAWN MAP the click claimed a COUNTRY (Sim.pickNation):
				-- the ring goes on its capital, and the client is told which
				-- nation and which empire to flash, not the tile under the finger.
				StateRE:FireClient(player, "spawned", {
					tile = if claim then claim.tile else tile,
					preview = true,
					nation = claim and claim.name or nil,
					owner = claim and claim.owner or nil,
				})
				-- ...and everybody sees the claim land: the claimed nation now
				-- wears this person's name and face (see roster), and the one
				-- they let go of, if any, gets its own back.
				if claim then
					StateRE:FireAllClients("roster", roster())
				end
			else
				StateRE:FireClient(player, "denied", { reason = why })
			end
		end
	elseif kind == "attack" then
		-- The player chooses the size, but only from Config.ATTACK_PRESETS:
		-- the payload is SNAPPED to the nearest one rather than trusted, so
		-- the three buttons are also the whitelist.
		local ratio = snapPreset(payload.ratio)
		local ok, why = sim:launchAttack(p.id, tile, ratio)
		if ok then
			-- AttackExecution.init's diplomacy half: attacking somebody who has
			-- asked you to ally answers the question, and lays down the
			-- temporary trade embargo (five minutes) that a war carries.
			pcall(Alliances.onAttack, sim, p.id, buffer.readu8(sim.map.owner, tile))
		end
		-- UPSTREAM'S RULE, AND THE WHOLE POINT OF HAVING A NAVY: tapping land
		-- you cannot walk to sends a transport boat instead
		-- (`AiAttackBehavior.sendAttack`,
		-- src/core/execution/utils/AiAttackBehavior.ts:760-778,
		-- picks land vs sea the same way). No second button and no mode
		-- switch -- you point at a country and the game works out whether
		-- that means marching or sailing.
		--
		-- ...AND WALKING IS TRIED FIRST. A tap at a country you do not border
		-- is an order to go and fight them, and the ground in between is how
		-- you get there: Sim.landBridge finds the crossing where the two
		-- empires come closest along the land, and the march is seeded there.
		-- Open land was always attackable -- it just had no button and no
		-- name, so it had to be found and tapped by hand.
		local marchedTo: number? = nil
		if not ok and why == "notadjacent" then
			local mouth, shore = sim:landBridge(p.id, tile)
			if mouth ~= nil then
				ok, why = sim:launchAttack(p.id, mouth, ratio, nil, shore)
				if ok then
					marchedTo = mouth
				end
			end
			if not ok then
				local okTransportBoat, whyTransportBoat = sim:launchTransportBoat(p.id, tile)
				if okTransportBoat then
					ok, why = true, nil
				elseif mouth == nil then
					-- Report the SEA refusal, not the land one. "Your land does
					-- not touch them" is not the useful sentence when the player
					-- can see perfectly well that there is an ocean in the way.
					--
					-- When there WAS a way to walk and the march itself was
					-- refused, the land reason stands instead, for the same
					-- reason: "too many fronts" is the thing that player can act
					-- on, and the sea has nothing to do with it.
					why = whyTransportBoat
				end
			end
		end
		-- THE STEP THAT SAYS THEY UNDERSTOOD THE GAME. Everything before it can
		-- be reached by somebody who is lost -- you are teleported in and the
		-- spawn ring is placed for you -- and this cannot. It counts the ATTEMPT
		-- rather than the hit: a refused tap is still a person reaching for the
		-- control, and only the first one a round is reported.
		Analytics.matchAttacked(player)
		-- THE TUTORIAL COUNTS TAPS, NOT GROUND (Tutorial.ATTACK_TAPS). Only a
		-- tap that LAUNCHED counts, which is the opposite of the analytics line
		-- above: that one wants the reach, this one wants the deed.
		if ok and tutorialSession ~= nil and player.UserId == tutorialUserId then
			Tutorial.noteAttack(tutorialSession, p.id)
		end
		-- ...and a lite lesson counts its own student's taps the same way.
		if ok and lessons[player.UserId] ~= nil then
			Tutorial.noteAttack(lessons[player.UserId], p.id)
		end
		-- THE ARMY SETS OFF A COUNTRY AWAY FROM THE FINGER. The press has
		-- already rung the tile it landed on and said "Attacking NAME", and
		-- both are now pointing at the wrong place -- so the client is told
		-- where the march actually starts. `owner` carries the empire that was
		-- TAPPED, the same key and the same meaning "denied" gives it.
		if marchedTo ~= nil then
			StateRE:FireClient(player, "march", {
				tile = marchedTo,
				owner = buffer.readu8(sim.map.owner, tile),
			})
		end
		if not ok then
			-- Answer the tap. A refusal that says nothing reads as a broken
			-- control rather than as an illegal move.
			StateRE:FireClient(player, "denied", {
				reason = why,
				owner = buffer.readu8(sim.map.owner, tile),
			})
		end
	elseif kind == "topup" then
		-- THE BUILD A TOP-UP WILL FINISH, parked before the purchase prompt opens
		-- (GoldTopUpClient). It places nothing and charges nothing -- it only
		-- remembers, so a receipt landing seconds later still knows which tile the
		-- player was pointing at.
		--
		-- THE KIND IS WHITELISTED HERE, exactly as the build branch below does it,
		-- rather than trusted: this is a client-supplied number that a later
		-- `buildStructure` will act on, so only the kinds a person may actually
		-- raise are accepted.
		local want = nil
		if payload.kind == Sim.CITY or payload.kind == Sim.PORT or payload.kind == Sim.FACTORY
			or payload.kind == Sim.DEFENSE_POST or payload.kind == Sim.SAM_LAUNCHER
			or payload.kind == Sim.ARTILLERY or payload.kind == Sim.AIRFIELD
			or payload.kind == Sim.RAILGUN
		then
			want = payload.kind
		end
		-- ...AND THE TWO PASS-GATED KINDS ONLY FROM A HOLDER (2026-09-22). A park
		-- is redeemed by buying gold, and the redeem calls buildStructure directly
		-- rather than coming back through the build intent -- so a kind refused
		-- there has to be refused here as well, or a top-up is the way around the
		-- pass. Dropping the park is the whole refusal: nothing was charged and
		-- the prompt that follows buys gold, which is still gold.
		if (want == Sim.ARTILLERY and not Monetization.holdsPass(player, "ARTILLERY"))
			or (want == Sim.AIRFIELD and not Monetization.holdsPass(player, "AIRSTRIKE"))
			or (want == Sim.RAILGUN and not Monetization.holdsPass(player, "RAILGUN"))
		then
			want = nil
		end
		if want ~= nil and sim.phase == "playing" then
			-- STAMPED, so the redeem can tell a park made seconds ago from one
			-- left behind by a prompt the player cancelled eight minutes back.
			pendingBuild[player.UserId] = {
				tile = tile,
				kind = want,
				round = roundId,
				at = os.clock(),
			}
		end
	elseif kind == "build" then
		-- Cities and ports are what gold buys. The refusal reasons come
		-- straight back so the HUD can say WHICH rule was broken -- "too close
		-- to another one" and "not enough gold" look identical from the
		-- outside, and a build that silently does nothing reads as a bug.
		local what = Sim.CITY
		if payload.kind == Sim.PORT then
			what = Sim.PORT
		elseif payload.kind == Sim.FACTORY then
			what = Sim.FACTORY
		elseif payload.kind == Sim.DEFENSE_POST then
			-- A WALL IS A PURCHASE LIKE ANY OTHER from here: Economy owns its
			-- price ladder, its spacing rule and its build timer, so this branch
			-- is the whole of the player's route to one. There is no button on
			-- the action rail yet -- the AI is the only thing building posts
			-- today -- and this is deliberately open first, so the rail can be a
			-- client change on its own.
			what = Sim.DEFENSE_POST
		elseif payload.kind == Sim.SAM_LAUNCHER then
			-- THE ANTI-NUKE TOWER, and the same rule as the wall above: Economy
			-- owns its price ladder, its spacing rule and its thirty-second build
			-- timer, so this branch is the whole of a player's route to one. The
			-- AI has been building these since the nuclear layer landed; what is
			-- new is that a person can.
			what = Sim.SAM_LAUNCHER
		elseif payload.kind == Sim.ARTILLERY then
			-- THE ARTILLERY BATTERY (2026-09-21): Economy owns its ladder, spacing
			-- and build timer, so this branch is the whole of a player's route.
			what = Sim.ARTILLERY
		elseif payload.kind == Sim.AIRFIELD then
			-- THE AIRFIELD (2026-09-21), same rule.
			what = Sim.AIRFIELD
		elseif payload.kind == Sim.RAILGUN then
			-- THE RAILGUN (2026-09-24), same rule; the RAILGUN pass's building.
			what = Sim.RAILGUN
		end
		-- THE TWO BUNDLES' BUILDINGS (2026-09-22, owner: "I only want people who
		-- have the gamepass to have access to it"). The battery and the airfield
		-- are the Artillery Battery / Air Strike passes', held from the site or
		-- bought with Money -- the rail hides both cards otherwise -- and this is
		-- the button-is-the-whitelist rule the nuke branch below spells out, with
		-- the pass as the button. Nothing else about the build changes, so the
		-- refusal rides home on the same reply with the same price quote.
		--
		-- THE AI IS UNTOUCHED: bots raise theirs inside Sim (botBuild), never
		-- through this remote, so a gate here cannot quiet the map.
		local needPass = (what == Sim.ARTILLERY and "ARTILLERY")
			or (what == Sim.AIRFIELD and "AIRSTRIKE")
			or (what == Sim.RAILGUN and "RAILGUN")
			or nil
		local ok, why, landed
		if needPass ~= nil and not Monetization.holdsPass(player, needPass) then
			ok, why = false, "pass"
		else
			ok, why, landed = sim:buildStructure(p.id, tile, what)
		end
		StateRE:FireClient(player, ok and "built" or "denied", {
			reason = why,
			-- A port SNAPS to the nearest coast it owns, so the tile that was
			-- clicked and the tile that was built on are not the same thing.
			-- The client pings the one that was built on.
			tile = landed or tile,
			kind = what,
			gold = math.floor(p.gold),
			cost = math.floor(sim.structureCost(p, what)),
		})
	elseif kind == "nuke" then
		-- payload.kind selects atom / hydrogen / MIRV. Gold is taken and the
		-- silo committed on the execution's FIRST TICK, not here, so a silo
		-- that goes on cooldown between the tap and the launch cancels the
		-- shot rather than silently retargeting.
		local what = payload.kind
		local ok, why
		-- THE BUTTON IS ALSO THE WHITELIST, the same rule snapPreset follows
		-- for attack size. Only the ATOM BOMB is on the action rail, so only
		-- the atom bomb is accepted here. This used to be enforced for free by
		-- the silo requirement -- a client asking for a hydrogen bomb had no
		-- silo to fire it from -- and Config.NUKE_REQUIRES_SILO now waives
		-- that, so a crafted intent would otherwise buy a 5M gold hydrogen
		-- bomb (31,000 tiles, about eight average empires) or a MIRV from a
		-- treasury a long game hands out. The AI still fires all three:
		-- Nukes.aiThink calls launchNuke and launchMirv directly and does not
		-- come through this remote. Put a warhead on the rail and add its id
		-- here in the same commit, never one without the other.
		--
		-- THE MEGA NUKE LANDED ON THE RAIL 2026-09-22 (owner: "a seperate card
		-- called Mega Nuke") -- Units.MEGA_NUKE, 3,000,000 gold, twice the atom
		-- bomb's radii -- and its button is the MEGA NUKE PASS'S: the HUD puts
		-- the card up only for a holder (RAIL_ACTIONS.pass), so this accepts the
		-- type only from one. That is the button-is-the-whitelist rule above
		-- with the pass as the button: a crafted client without it gets "pass",
		-- a refusal the rail never lets an honest one reach. The check is the
		-- attribute this server wrote when the site (or a Money sale) said yes
		-- (Monetization.holdsPass) -- never a web call between a tap and a
		-- launch. Everything past this line is table-driven off the type.
		if what == Units.ATOM_BOMB then
			ok, why = Nukes.launchNuke(sim, p.id, what, tile)
		elseif what == Units.MEGA_NUKE then
			if Monetization.holdsPass(player, "MEGANUKE") then
				ok, why = Nukes.launchNuke(sim, p.id, what, tile)
			else
				ok, why = false, "pass"
			end
		elseif what == Units.SCATTERSHOT then
			-- THE SCATTERSHOT CARD (2026-09-24): a main warhead and 4-6 small
			-- ones in one order -- the SCATTERSHOT pass's, the mega nuke's rule.
			if Monetization.holdsPass(player, "SCATTERSHOT") then
				ok, why = Nukes.launchScattershot(sim, p.id, tile)
			else
				ok, why = false, "pass"
			end
		else
			ok, why = false, "notanuke"
		end
		if not ok then
			StateRE:FireClient(player, "denied", { reason = why, tile = tile, kind = what })
		end
	elseif kind == "airstrike" then
		-- THE AIRFIELD'S SORTIE (owner, 2026-09-21: "when you click it again, it
		-- allows you to bomb an area you'd like in its larger radius"). `tile`
		-- is the target and passed the range check above; `from` is the tile
		-- the airfield was tapped on and is checked the same way here, because
		-- it is a second tile on the wire and nothing above looked at it. The
		-- rest -- is it yours, is it finished, is it rearmed, is the target
		-- inside AIRFIELD_RANGE, can you pay -- is Airstrikes.order's, and its
		-- refusal comes straight back so the banner can say which.
		local from = payload.from
		-- A SORTIE IS THE AIR STRIKE BUNDLE'S, NOT JUST THE FIELD'S (2026-09-22).
		-- The build gate above is what stops a non-holder ever having a field --
		-- but an empire taken over from a bot (the REVIVE product, followTakeover)
		-- can come with one already standing, and this chip is the one route from
		-- it to a bomber. Bots fly theirs through Sim.botAirstrike, not here.
		if not Monetization.holdsPass(player, "AIRSTRIKE") then
			StateRE:FireClient(player, "denied", { reason = "pass", tile = tile, kind = Sim.AIRFIELD })
			return
		end
		if typeof(from) == "number" and from == from and from >= 0 and from < Config.NUM_TILES and sim.phase == "playing" then
			local ok, why = Airstrikes.order(sim, p.id, math.floor(from), tile)
			if not ok then
				StateRE:FireClient(player, "denied", { reason = why, tile = tile, kind = Sim.AIRFIELD })
				-- ...AND THE ONE MOMENT THE SKIP MEANS ANYTHING (2026-09-22): a
				-- sortie ordered into the rearm. Whether to offer at all -- the
				-- 75% rule, the ask clock -- is offerSkipRearm's.
				if why == "cooldown" then
					offerSkipRearm(player, p, math.floor(from))
				end
			end
		end
	elseif kind == "railgun" then
		-- THE RAILGUN'S SHOT (owner, 2026-09-24: "controllable like the
		-- airbase, with no range limit"). `from` is the tile the gun was
		-- tapped on, typed here as the airstrike's is; the rest -- is it yours,
		-- is it finished, is it reloaded -- is Railgun.order's. There is no
		-- range refusal: any tile on the map is a target. Required inline, not
		-- as a file local, so this chunk spends no register on it.
		local from = payload.from
		-- THE PASS'S SHOT TOO, not only its building (the airstrike's rule): an
		-- empire taken over from a bot could come with a railgun standing.
		if not Monetization.holdsPass(player, "RAILGUN") then
			StateRE:FireClient(player, "denied", { reason = "pass", tile = tile, kind = Sim.RAILGUN })
			return
		end
		if typeof(from) == "number" and from == from and from >= 0 and from < Config.NUM_TILES and sim.phase == "playing" then
			local ok, why = require(Shared.Railgun).order(sim, p.id, math.floor(from), tile)
			if not ok then
				StateRE:FireClient(player, "denied", { reason = why, tile = tile, kind = Sim.RAILGUN })
				-- THE SKIP, as the airfield's (2026-09-25): a shot into the reload.
				if why == "cooldown" then
					offerSkipRearm(player, p, math.floor(from), true)
				end
			end
		end
	elseif kind == "railsite" then
		-- A PRESS ON YOUR RAILGUN WHILE IT IS GOING UP (2026-09-25). The client
		-- can't aim a site, so this is the press's only meaning: offer the
		-- SKIP for the rest of the build. offerSkipRearm owns the 75% rule and
		-- the ask clock; the pass gate is the shot's.
		local from = payload.from
		if Monetization.holdsPass(player, "RAILGUN") and typeof(from) == "number" and from == from
			and from >= 0 and from < Config.NUM_TILES and sim.phase == "playing" then
			offerSkipRearm(player, p, math.floor(from), true)
		end
	-- NO "gunboat" BUILD INTENT. Gunboats are not purchased in this game.
	-- DELIBERATE DEVIATION FROM UPSTREAM, by the owner's design call: upstream
	-- sells gunboats from the build menu at min(1e6, (n+1)*250,000), and here
	-- PORTS ARE THE ONLY NAVAL PURCHASE. A port produces and sustains its own
	-- squadron, so the naval lever is how many ports you own and how far you
	-- have upgraded them -- see Gunboats.stepPortProduction. Trading boats were
	-- already automatic (Economy spawns them on nextTradeTick and picks the
	-- partner itself), so the whole navy is now hands-off.
	--
	-- Re-stationing a fleet SURVIVES, because it is a command rather than a
	-- purchase and costs nothing.
	--
	-- "cancel" IS GONE (owner, 2026-09-03: "pc players shouldnt be able to
	-- either"). It called off every attack a player had running and refunded the
	-- survivors less RETREAT_PENALTY. It was bound to X and to nothing else, so
	-- it had been a keyboard-only ability since the day it was written -- and
	-- committing troops is meant to be a decision you live with. Being able to
	-- take it back made every attack provisional.
	--
	-- Sim.cancelAttacks STAYS, and is still called twice: collapsePlayer disarms
	-- an empire the moment it is conquered, and the elimination sweep does the
	-- same for one that has run out of tiles. What is removed is the PLAYER's
	-- route to it -- the handler as well as the key, because a branch left
	-- listening here is an ability a modified client keeps and an honest one
	-- does not.
	elseif kind == "movegunboat" then
		-- MoveWarshipExecution: re-station the listed gunboats, silently skipping
		-- any that cannot swim to the tile.
		local ids = payload.ids
		if typeof(ids) == "table" then
			-- Hull ids come off the wire as anything: whole numbers only, and
			-- no more of them than a fleet can hold, so a hostile client cannot
			-- hand the loop a thousand entries or a NaN table key.
			local clean: { number } = {}
			for i = 1, math.min(#ids, 16) do
				local id = ids[i]
				if typeof(id) == "number" and id == id and id % 1 == 0 then
					clean[#clean + 1] = id
				end
			end
			-- ANSWER THE PRESS (2026-09-18, the day a player could give this
			-- order at all). Gunboats.move skips a hull that cannot swim to the
			-- tile -- a lake, or a sea the other side of a land bridge -- and
			-- skipping silently reads as a broken control. The client rang the
			-- tile white on the press; "denied" paints it red and says why.
			if #clean > 0 and Gunboats.move(sim, p.id, clean, tile) == 0 then
				StateRE:FireClient(player, "denied", { reason = "nosea", tile = tile })
			end
		end
	end
end)

-- ============================================================== lifecycle ==

-- Moves any faux empire that is wearing `userId` onto a different name and
-- face, and reports whether it moved anything. There is one caller: the person
-- being impersonated joining this very server. Everything else about the
-- empire -- its id, its colour, its territory -- is left alone, because this
-- is a change of costume and not of empire.
local function reidentifyFaux(userId: number): boolean
	local changed = false
	for id in fauxIds do
		local p = sim.players[id]
		if p and p.userId == userId then
			local taken: { [number]: boolean } = {}
			for other in fauxIds do
				local q = sim.players[other]
				if q and q.userId then
					taken[q.userId] = true
				end
			end
			for _, other in Players:GetPlayers() do
				taken[other.UserId] = true
			end
			-- Seeded off the empire's own id so two collisions in one round
			-- cannot draw the same replacement.
			local swap = Tutorial.drawIdentities(sim.seed + id, 1, taken)[1]
			if swap then
				p.name = swap.display
				p.userId = swap.userId
				fauxIdentity[p.id] = swap
				changed = true
			end
		end
	end
	return changed
end

Players.PlayerAdded:Connect(function(player)
	if not sim then
		return
	end
	local rosterMoved = reidentifyFaux(player.UserId)
	if sim.phase == "spawn" or sim.phase == "lobby" then
		if not sim:playerByUserId(player.UserId) then
			-- THE MAP'S CEILING APPLIES HERE TOO (Maps.MapData.MAX_EMPIRES).
			-- Every other roster path honours it -- startRound caps the roster
			-- and the AI fill by it, and both join paths check it -- but this one
			-- seated anyone who arrived while the spawn phase was still running,
			-- which is exactly where a follow-a-friend teleport lands. On Korea
			-- (two empires) the third person got no nation from commitHistorical
			-- and no ground from autoSpawn, because the scenario already owns
			-- every playable tile, and then sat out the whole match unable even
			-- to be eliminated -- elimination needs a spawned empire.
			local cap = tonumber((Maps.get(mapId :: string) :: any).MAX_EMPIRES)
			local empires = 0
			if cap ~= nil then
				for _, q in pairs(sim.players) do
					if q ~= nil then
						empires += 1
					end
				end
			end
			if cap ~= nil and empires >= cap then
				-- No seat on this map. They stay a spectator, which is what the
				-- client already draws for somebody with no empire -- and unlike
				-- the old behaviour, they are not a phantom in the roster.
				warn(("[Conquest] %s arrived during spawn but %s is full (%d/%d) -- spectating")
					:format(player.Name, tostring(mapId), empires, cap))
			else
				-- A LATE ARRIVAL STILL JOINS THEIR CLAN. They came through the
				-- same teleport their friends did, so their tag is in the batch
				-- data exactly as it was for everyone added at round start.
				sim:addPlayer(nationNameFor(player), false, player.UserId, nil, tagFor(player))
				applyPattern(player)
				rosterMoved = true
			end
		end
	elseif sim.phase == "playing" then
		-- A FOLLOWER ARRIVING MID-WAR takes command of a bot beside their
		-- friend -- see followTakeover. Deferred behind the spectator init
		-- below so its own fresh init lands second, not first.
		local friendId = followedUserId(player)
		if friendId ~= nil then
			task.defer(function()
				if player.Parent == nil then
					return
				end
				local ok, why = followTakeover(player, friendId)
				if not ok then
					print(("[Conquest] %s followed %d in but takes no empire: %s"):format(player.Name, friendId, why))
					-- NO ROOM. Rather than leave a newcomer watching a war they
					-- cannot join, send them back to the page, marked, and the
					-- lobby opens the standard tutorial for them instead.
					if why == "no empire is free to take" then
						leaveToLobby(player, true)
					end
				end
			end)
		end
	end
	-- Names ride with the roster now, so everyone else needs the new one.
	if rosterMoved then
		StateRE:FireAllClients("roster", roster())
	end
	-- Mid-round joiners spectate until the next round.
	task.defer(sendInit, player)
end)

-- THE NAME CAN ARRIVE AFTER THE PLAYER DOES, and usually will. A profile load
-- waits on the session lock still held by the server they just left, so it
-- lands seconds behind PlayerAdded -- comfortably after a round has finished
-- building its roster with the display name. Rather than have startRound yield
-- for a DataStore, take the late answer here.
--
-- SPAWN AND LOBBY PHASES ONLY. The roster is a list of strings sent whole, so
-- correcting one entry and re-sending costs nothing at all before the war
-- starts -- but a nation that renames itself mid-round is a different feature,
-- and one nobody asked for.
local function watchNation(player: Player)
	player:GetAttributeChangedSignal("ConquestNation"):Connect(function()
		if not sim or (sim.phase ~= "spawn" and sim.phase ~= "lobby") then
			return
		end
		local entry = sim:playerByUserId(player.UserId)
		if entry == nil then
			return
		end
		local name = nationNameFor(player)
		if entry.name ~= name then
			entry.name = name
			StateRE:FireAllClients("roster", roster())
		end
	end)
end

Players.PlayerAdded:Connect(watchNation)
-- Anyone already here when this line runs. A reserved server fills by teleport
-- after boot so the connection above catches almost everybody, but a Studio
-- session starts with a player already standing in it.
for _, player in Players:GetPlayers() do
	watchNation(player)
end

Players.PlayerRemoving:Connect(function(player)
	if not sim then
		return
	end
	-- PAID ON THE WAY OUT, and BEFORE the empire is handed to the bots. A
	-- player who is knocked out has already been settled and this is a no-op
	-- for them; this is for the other two exits -- a disconnect, and someone
	-- closing the game while still alive -- and it pays only the part of the
	-- round they actually built. It has to run ahead of ConquestData's own
	-- PlayerRemoving (which releases the profile), and it does, because
	-- `Data.install` is called at the foot of this file: connection order is
	-- registration order.
	settleMoney(player, true)
	lessons[player.UserId] = nil
	-- LEAVING IS A DATA POINT, and it is the one that stops existing the moment
	-- they are gone. A student who quits mid-lesson names the card that lost
	-- them; a player who quits mid-round names the minute.
	if tutorialSession ~= nil and player.UserId == tutorialUserId and not tutorialEnded then
		tutorialEnded = true
		local index = math.clamp(tonumber(tutorialSession.stepIndex) or 1, 1, #Tutorial.STEPS)
		local card = Tutorial.STEPS[index]
		Analytics.tutorialQuit(player, index, card and card.id or "?")
	end
	if sim.phase == "spawn" or sim.phase == "playing" then
		Analytics.matchQuit(player, (os.clock() - roundStartedAt) / 60, sim.phase)
	end
	local p = sim:playerByUserId(player.UserId)
	if p then
		-- Leave their territory on the map for the bots to carve up; just
		-- stop the empire from acting. The paid growth boost does not stay
		-- with the land -- it was bought by a person who has gone.
		p.isBot = true
		p.growthBoost = nil
		p.goldBoost = nil
		p.reloadMult = nil
	end
	lastIntent[player.UserId] = nil
	lastHello[player.UserId] = nil
	leaving[player.UserId] = nil
end)

-- =================================================================== loop ==

-- ============================================================ matchmaking ==

local LobbyRE = netFolder:WaitForChild("Lobby") :: RemoteEvent

local returning = false
local function returnToLobby()
	if returning then
		return
	end
	returning = true
	local list = Players:GetPlayers()
	if #list == 0 then
		-- Nobody to send -- but do NOT stay latched, or a straggler arriving
		-- after this is stranded in a finished match with no way out.
		returning = false
		return
	end
	-- Back to a PUBLIC server of this same place, which is the matchmaking
	-- page. This instance then empties and Roblox shuts it down: a reserved
	-- server exists for exactly one match.
	-- THE VISIT RIDES HOME WITH THEM. Without this payload the hop back to the
	-- page reads as one visit ending and another starting, which would report
	-- every player as two short sessions instead of one real one -- and the
	-- match half, the half that actually holds the game, as the shorter of the
	-- two.
	local options = Instance.new("TeleportOptions")
	options:SetTeleportData({ cq = Analytics.teleportData(list) })
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, list, options)
	end)
	if not ok then
		warn("[Conquest] return teleport failed: " .. tostring(err))
		Analytics.hopsCancelled(list)
		returning = false
	end
end

-- A STRAGGLER INTO A FINISHED ROUND: a follower whose teleport was in flight
-- while everyone went home. `returnToLobby` has latched by then and will not
-- fire again, so without this they would sit in a dead round until they
-- pressed LEAVE. Anyone arriving BEFORE the group leaves rides with it.
if IS_MATCH then
	Players.PlayerAdded:Connect(function(player)
		if sim ~= nil and sim.phase == "ended" and returning then
			task.defer(leaveToLobby, player)
		end
	end)
end

-- WHERE THIS SERVER'S PEOPLE ARE, for a friend who presses JOIN on one of them.
-- The platform cannot put anybody into a reserved server, so the lobby they
-- land in finishes the join off this record (MatchmakerServer.followFriend):
-- one entry per person, keyed by userId, holding this match's access code.
-- Written on arrival, cleared on leaving. `matchAccess` is read off the match
-- record in bootMatch; a Studio round has none and publishes nothing. A
-- tutorial publishes with `tutorial = true`, which the lobby refuses to follow.
local whereStore = MemoryStoreService:GetHashMap(Matchmaker.WHERE_STORE)
local matchAccess: string? = nil
local matchIsTutorial = false
local matchIsPrivate = false

local function publishWhere(player: Player)
	local code = matchAccess
	if code == nil or code == "" then
		return
	end
	-- ONLY WHAT THE READER USES (2026-09-20). MatchmakerServer.followFriend
	-- reads `code` and `tutorial` and nothing else; `psid`, `at` and `private`
	-- were dead weight on one entry per player in a match, and the store's
	-- memory quota is what this game runs out of first (see
	-- Matchmaker.MATCH_RECORD_TTL). Add a field here only with a reader.
	local entry = {
		code = code,
		tutorial = matchIsTutorial,
	}
	task.spawn(function()
		local ok, err = pcall(function()
			whereStore:SetAsync(tostring(player.UserId), entry, Matchmaker.MATCH_TTL)
		end)
		if not ok then
			warn("[Conquest] could not publish where " .. player.Name .. " is: " .. tostring(err))
		end
	end)
end

local function unpublishWhere(player: Player)
	if matchAccess == nil then
		return
	end
	task.spawn(function()
		pcall(function()
			whereStore:RemoveAsync(tostring(player.UserId))
		end)
	end)
end

if IS_MATCH then
	Players.PlayerAdded:Connect(function(player)
		publishWhere(player)
		-- A LATE ARRIVAL'S CURTAIN. MatchIntro waits for "go", which went out
		-- once when the round began; somebody arriving after it -- a follower
		-- -- would sit behind "commanders are still arriving" until the
		-- intro's safety timer. The round exists, so say so, deferred behind
		-- the init the handler above sends so the map is there when it lifts.
		if sim ~= nil then
			task.defer(function()
				if player.Parent ~= nil then
					LobbyRE:FireClient(player, "go")
				end
			end)
		end
	end)
	Players.PlayerRemoving:Connect(unpublishWhere)
end

-- The round this server exists to run is TOLD to it by the lobby that reserved
-- it: MatchmakerServer writes a match record keyed by PrivateServerId before
-- it teleports anybody. Deliberately NOT the joining players' TeleportData --
-- that belongs to whichever client happened to arrive first, and the map a
-- match is played on must not depend on who loaded fastest.
local function bootMatch()
	-- A reserved server has a PrivateServerId to key the record by; a Studio
	-- session forced to "match" has an EMPTY one, and MemoryStore refuses an
	-- empty key. Skip the lookup rather than throwing into a pcall and warning
	-- about a record that was never going to exist.
	local cfg: any = nil
	if game.PrivateServerId ~= "" then
		local ok, res = pcall(function()
			return MemoryStoreService:GetHashMap(Matchmaker.MATCH_STORE):GetAsync(game.PrivateServerId)
		end)
		if ok and type(res) == "table" then
			cfg = res
			-- READ ONCE, THEN GONE (2026-09-20). Nothing reads this record
			-- again, and a delete always succeeds -- even when the store is at
			-- its memory quota, which is exactly when it matters (see
			-- Matchmaker.MATCH_RECORD_TTL). The TTL is only the net for a
			-- match server that never got this far.
			task.spawn(function()
				local okDel, errDel = pcall(function()
					MemoryStoreService:GetHashMap(Matchmaker.MATCH_STORE):RemoveAsync(game.PrivateServerId)
				end)
				if not okDel then
					warn("[Conquest] could not delete the match record: " .. tostring(errDel))
				end
			end)
			-- The access code the lobby reserved this server with, for the
			-- where-index above. Anybody who beat this read here is published
			-- now; everybody after is published by PlayerAdded.
			matchAccess = if type(cfg.access) == "string" then cfg.access else nil
			matchIsTutorial = cfg.tutorial == true
			matchIsPrivate = cfg.private == true
			for _, player in Players:GetPlayers() do
				publishWhere(player)
			end
		else
			warn("[Conquest] no match record for this reserved server -- using the rotation instead")
		end
	end

	-- Players arrive from up to three different lobby servers and do not land
	-- together, so hold the start open until the roster the lobby promised has
	-- turned up -- and never longer than BOARD_GRACE, because somebody who
	-- quit during the teleport is never going to arrive at all.
	local expected = (cfg and tonumber(cfg.expected)) or 1
	-- THE PHANTOM SEATS COUNT ON THE CURTAIN TOO (2026-09-24). The card the
	-- player joined showed `expected + phantoms` commanders, so "3 of 3" here
	-- would give the faux empires away. They are shown as already seated --
	-- they never have a teleport to wait on -- and the same clamp startRound
	-- applies keeps the figure equal to the empires that will wear a face.
	-- Only the COUNT changes; the wait still ends when the real roster lands.
	local phantoms = math.clamp(tonumber(cfg and cfg.phantoms) or 0, 0, FAUX_MAX)
	local t0 = os.clock()
	while os.clock() - t0 < Matchmaker.BOARD_GRACE do
		local here = #Players:GetPlayers()
		if here >= expected then
			break
		end
		LobbyRE:FireAllClients("wait", here + phantoms, expected + phantoms)
		task.wait(0.5)
	end

	-- NOBODY ARRIVED AT ALL. Every teleport into this reserved server must
	-- have failed, so there is no match here to run -- and starting one anyway
	-- would generate a map and simulate the whole roster for an empty room.
	-- Wait instead: a straggler still gets a real round, and if none comes
	-- Roblox reaps the empty server and takes this thread with it.
	while #Players:GetPlayers() == 0 do
		task.wait(1)
	end

	-- The whole record goes in as `opts`: a public match's has none of the
	-- private fields and every dial reads absent, which is the default.
	startRound(cfg and cfg.map or nil, cfg and cfg.mode or nil, cfg)
	-- "go" comes AFTER the round exists, not before. `startRound` generates
	-- the map and sends every client its init; dismissing the intro first drops
	-- the player onto a blank desk for as long as all of that takes.
	LobbyRE:FireAllClients("go")
end

if IS_MATCH then
	task.spawn(bootMatch)
else
	-- A LOBBY server does not simulate. It sits here with `sim` nil -- the
	-- heartbeat below and every handler above already guard on that -- until
	-- the role flips, which only happens in STUDIO, where there are no
	-- reserved servers and the alternative would be a page whose countdown
	-- reaches zero and then does nothing at all.
	task.spawn(function()
		Matchmaker.awaitRole("match")
		-- STUDIO ONLY, and the attributes are the whole channel: there is no
		-- reserved server here to key a match record by, so whatever started
		-- this round wrote its settings onto ReplicatedStorage on the way out.
		-- See MatchmakerServer.startLocally.
		startRound(
			ReplicatedStorage:GetAttribute(Matchmaker.LOCAL_MAP_ATTR) :: any,
			ReplicatedStorage:GetAttribute(Matchmaker.LOCAL_MODE_ATTR) :: any,
			{
				teams = ReplicatedStorage:GetAttribute(Matchmaker.LOCAL_TEAMS_ATTR),
				troopScale = ReplicatedStorage:GetAttribute(Matchmaker.LOCAL_TROOPS_ATTR),
				startGold = ReplicatedStorage:GetAttribute(Matchmaker.LOCAL_GOLD_ATTR),
				phantoms = ReplicatedStorage:GetAttribute(Matchmaker.LOCAL_PHANTOMS_ATTR),
				tutorial = ReplicatedStorage:GetAttribute(Matchmaker.LOCAL_TUTORIAL_ATTR),
			}
		)
	end)
end

-- ONE CARD CLEARED IS ONE FUNNEL STEP, and the cursor above is what makes that
-- true. Two things in the track would otherwise put a fake cliff in the middle
-- of the onboarding funnel: `advance` also fires when the ring moves, and a card
-- that does not apply to this round -- the port, on a landlocked empire -- is
-- stepped over without ever being current. So the step is derived from how far
-- the INDEX has moved, and every card it stepped over is reported as cleared:
-- the FIRST of a batch is the one they did, the rest are ones the track skipped
-- for them. A skip reading as a wall is not a chart you can act on.
local function noteTutorial()
	if tutorialSession == nil or tutorialUserId == 0 then
		return
	end
	local student = Players:GetPlayerByUserId(tutorialUserId)
	if student == nil then
		return
	end
	local total = #Tutorial.STEPS
	local reached = math.clamp(tonumber(tutorialSession.stepIndex) or 1, 1, total)
	-- Finishing does NOT advance the index -- the last card is cleared in place
	-- -- so `finished` is what says that card counts.
	local cleared = tutorialSession.finished and total or (reached - 1)
	local firstOfBatch = tutorialStepSeen + 1
	while tutorialStepSeen < cleared do
		tutorialStepSeen += 1
		local card = Tutorial.STEPS[tutorialStepSeen]
		Analytics.tutorialCard(
			student,
			tutorialStepSeen,
			card and card.id or "?",
			tutorialStepSeen > firstOfBatch
		)
	end
	if tutorialEnded then
		return
	end
	if tutorialSession.finished then
		tutorialEnded = true
		tutorialOverAt = os.clock()
		Analytics.tutorialDone(student, total, os.clock() - tutorialStartedAt)
	elseif tutorialSession.failed then
		tutorialEnded = true
		-- BOTH ENDS OF THE TRACK GO HOME, not just the happy one. A student who
		-- was knocked out has no empire and no lesson left; leaving them to
		-- spectate a bot war until somebody wins it is the worse of the two.
		tutorialOverAt = os.clock()
		local card = Tutorial.STEPS[reached]
		Analytics.tutorialFailed(student, reached, card and card.id or "?")
	end
end

-- ================================================================ /endgame ==

-- THE ONE ROUTE OUT OF A ROUND, exposed so the /endgame test command can
-- borrow it instead of reaching into this file's locals from another script.
-- Same reasoning MatchmakerServer's /start gives for dragging the deadline
-- into the past rather than launching directly: a second way to end a round is
-- a second thing that can drift from the first, and then the shortcut tests
-- something the real path does not do.
--
-- `mode` is "tutorial" | "fail" | "round", or nil for WHATEVER IS ACTUALLY
-- RUNNING -- the lesson track if there is one, the match otherwise. Returns
-- ok plus the line to tell the player, in the shape /gold's replies use.
--
-- Read out of _G every call, never cached: every round builds a new sim and a
-- cached one would be a shortcut writing into last round's dead match.
_G.ConquestEndRound = function(mode: string?): (boolean, string)
	if sim == nil then
		return false, "no round is running yet."
	end
	if mode == nil then
		mode = (tutorialSession ~= nil and not tutorialEnded) and "tutorial" or "round"
	end

	if mode == "tutorial" or mode == "fail" then
		if tutorialSession == nil then
			return false, "this round has no tutorial in it -- try /endgame round."
		end
		if tutorialEnded then
			return false, "the tutorial has already ended -- you are on your way out."
		end
		if mode == "fail" then
			tutorialSession.failed = true
		else
			tutorialSession.finished = true
		end
		-- The last card, then the ordinary end-of-track bookkeeping. noteTutorial
		-- is what logs the funnel step AND stamps tutorialOverAt, so going
		-- through it is what makes this a test of the real exit rather than of a
		-- teleport called by hand.
		local student = tutorialUserId ~= 0 and Players:GetPlayerByUserId(tutorialUserId) or nil
		if student ~= nil then
			StateRE:FireClient(student, "tutorial", Tutorial.state(tutorialSession))
		end
		noteTutorial()
		return true, string.format(
			"tutorial marked %s -- back to the lobby in %ds.",
			mode == "fail" and "failed" or "finished",
			TUTORIAL_EXIT_SECONDS
		)
	end

	if sim.phase == "ended" then
		return false, "the round has already ended."
	end
	-- No winner is invented. The win broadcast already says "nobody" for a nil
	-- winnerId, and naming one would be the shortcut telling a lie the real
	-- path never tells.
	sim.phase = "ended"
	return true, "round ended -- back to the lobby in 12s."
end

local accumulator = 0
local statsTimer = 0
local endedTimer = 0
-- THE ONE-TIME HALF OF THE END OF A ROUND, latched separately from the clock.
-- It used to be keyed on `endedTimer == 0`, which the 12-second rotation below
-- resets while the phase is still "ended" -- so the win packet went out again,
-- and Analytics.matchFinished (which, unlike matchSpawned, has no `once` guard)
-- logged the match again, every 12 seconds. Bounded only by the server emptying,
-- and not bounded at all if the return teleport failed.
local endedSettled = false
local vehicleTimer = 0
-- Kept so the ONE empty list that follows the last boat home is still sent:
-- without it the client keeps drawing a boat that no longer exists.
local lastVehicleCount = 0
local VEHICLE_INTERVAL = 0.5

-- ========================================================== diplomacy ==
-- Runs inside the tick loop, so it is pcall'd as one unit: a fault in here
-- must never take the sim's tick with it (a per-frame error freezes every
-- readout in the game -- see the frame-loop note in ConquestClient).
local function stepDiplomacy()
	local okStep, err = pcall(function()
		Alliances.step(sim)

		for i = #allyAnswers, 1, -1 do
			local a = allyAnswers[i]
			if sim.tick >= a.at then
				table.remove(allyAnswers, i)
				local me, asker = sim.players[a.to], sim.players[a.from]
				local standing = false
				if me and asker and me.alive and asker.alive and not Alliances.allied(sim, a.to, a.from) then
					for _, r in Alliances.incomingRequests(sim, a.to) do
						if r.from == a.from then
							standing = true
							break
						end
					end
				end
				-- The request may have timed out or been withdrawn by a death
				-- while the bot was "thinking"; then there is nothing to answer.
				if standing then
					-- A FAUX PLAYER ANSWERS LIKE A FRIEND (owner, 2026-09-18: "allow
					-- players to ally with npcs acting as players"): yes, unless
					-- the asker is a marked traitor. The nation AI's decision was
					-- refusing a small player nearly every time past the first
					-- three minutes ("similarly strong"), and a faux friend who
					-- turns you down reads as a real person snubbing you.
					-- Ordinary AI never gets asked (the gate above), so the
					-- decision below now only ever answers a /gotrequest reply.
					local okD, yes
					if fauxIds[a.to] then
						okD, yes = true, not Alliances.isTraitor(sim, a.from)
					else
						okD, yes = pcall(Alliances.getAllianceDecision, sim, me, asker, true)
					end
					if okD and yes then
						-- Meeting a request is how it is accepted (one intent
						-- for both halves, upstream's rule).
						Alliances.sendRequest(sim, a.to, a.from)
					else
						Alliances.rejectFrom(sim, a.from, a.to)
					end
				end
			end
		end

		-- WHAT HAPPENED, TO THE TWO PEOPLE IT HAPPENED TO. Every event names
		-- (a, b) = (requestor, recipient). The same "ally" message on the
		-- client draws the request card, flips a row to SENT / ALLIED /
		-- DECLINED, and clears a card the other side has answered.
		local events = Alliances.drainEvents(sim)
		if events == nil then
			return
		end
		for _, e in events do
			local a, b = sim.players[e.a], sim.players[e.b]
			local pa = a and a.userId and Players:GetPlayerByUserId(a.userId) or nil
			local pb = b and b.userId and Players:GetPlayerByUserId(b.userId) or nil
			-- A faux empire can be wearing an absent player's userId (see
			-- reidentifyFaux), so the id alone is not proof -- the same guard
			-- every private send in this file applies.
			if pa and sim:playerByUserId(pa.UserId) ~= a then
				pa = nil
			end
			if pb and sim:playerByUserId(pb.UserId) ~= b then
				pb = nil
			end
			if e.k == "request" then
				if pb then
					StateRE:FireClient(pb, "ally", { k = "request", id = e.a, name = a and a.name })
				end
				if pa then
					StateRE:FireClient(pa, "ally", { k = "sent", id = e.b, name = b and b.name })
				end
			elseif e.k == "traitor" then
				-- PUBLIC, the one thing here that is: everybody sees who
				-- betrayed whom, which is the entire point of the mark.
				StateRE:FireAllClients("ally", { k = "traitor", id = e.a, name = a and a.name, n = e.n })
			elseif
				e.k == "allied" or e.k == "rejected" or e.k == "expired" or e.k == "broke"
				or e.k == "renewed" or e.k == "wantsrenew"
				or e.k == "embargo" or e.k == "unembargo" or e.k == "target"
			then
				if pa then
					StateRE:FireClient(pa, "ally", { k = e.k, id = e.b, name = b and b.name, mine = true })
				end
				if pb then
					StateRE:FireClient(pb, "ally", { k = e.k, id = e.a, name = a and a.name })
				end
			end
		end
	end)
	if not okStep then
		warn("[Conquest] diplomacy step failed: " .. tostring(err))
		table.clear(allyAnswers)
	end
end

RunService.Heartbeat:Connect(function(dt)
	if not sim then
		return
	end
	-- /simulate freezes the live round while it benchmarks. Its harness runs
	-- a whole second sim on this same thread, so leaving this loop running
	-- would put the thing being measured in competition with the measurement.
	if _G.ConquestBenchPause then
		accumulator = 0
		return
	end
	accumulator += dt

	-- Bounded catch-up: never try to make up more than half a second at once.
	local steps = 0
	while accumulator >= Config.TICK_DT and steps < 5 do
		accumulator -= Config.TICK_DT
		steps += 1

		-- Whether this is the tick the round starts on. Every dot becomes an
		-- empire inside `step`, and there is no other moment at which to put a
		-- person's camera on the ground they just took: the phase broadcast
		-- below runs at 5 Hz and carries nobody's tile.
		local phaseWas = sim.phase

		sim:step()
		-- Diplomacy on the sim's own beat: request timeouts, alliance expiry,
		-- the AI's answers coming due, and the events the two sides are told.
		stepDiplomacy()

		-- MONEY, sampled on the same beat the sim runs at rather than on the
		-- 5 Hz summary loop, so an elimination's placement is read from the
		-- exact tick it happened on. Four field reads per empire per tick and
		-- no allocation on a tick where nothing died.
		if moneyTracker ~= nil then
			local settled = moneyTracker:sample()
			if #settled > 0 then
				settleIds(settled)
			end
		end

		if phaseWas == "spawn" and sim.phase == "playing" then
			for _, plr in Players:GetPlayers() do
				local placed = sim:playerByUserId(plr.UserId)
				if placed and placed.spawned and placed.spawnTile then
					StateRE:FireClient(plr, "spawned", { tile = placed.spawnTile })
					Analytics.matchSpawned(plr)
				end
			end
			-- ON A PREDRAWN MAP the people have just taken their nations
			-- (Sim.commitHistorical): the land and the nations' colours are
			-- now under THEIR ids, and the claimers' names and faces were
			-- riding the AI's ids until now (see roster). Once, on this
			-- tick, for everybody.
			if sim.scenario ~= nil then
				StateRE:FireAllClients("roster", roster())
				StateRE:FireAllClients("historical", historicalPayload())
			end
		end

		-- A TUTORIAL DOES NOT WAIT OUT THE SPAWN CLOCK. The student is the only
		-- human here, so once they have picked a homeland the rest of the
		-- countdown is dead air -- see Tutorial.SPAWN_GRACE_SECONDS. This only
		-- moves `phaseTick`; Sim.step still ends the phase in its own order.
		-- Nothing to send: the countdown the client draws is rebuilt from
		-- `phaseTick` in the "phase" broadcast below every STATS_INTERVAL, so
		-- moving the clock here shows up within 200 ms on a channel that is
		-- already running.
		if tutorialSession ~= nil then
			Tutorial.hurrySpawn(tutorialSession)
		end

		-- The lesson track. `advance` is a handful of integer reads and returns
		-- true on the tick a card is replaced OR the tick the ring it is
		-- pointing at moves -- the guided track names a tile and the map keeps
		-- taking it away, so the client has to be told about both on the same
		-- channel. Measured over a full 244-second run: 186 sends, 0.76 a
		-- second, to the ONE player a tutorial server holds.
		if tutorialSession ~= nil and Tutorial.advance(tutorialSession) then
			local student = Players:GetPlayerByUserId(tutorialUserId)
			if student then
				StateRE:FireClient(student, "tutorial", Tutorial.state(tutorialSession))
			end
			noteTutorial()
		end

		-- THE LITE LESSONS, on the same channel: a follower's three cards, one
		-- session per person. An ended one is dropped here and its card taken
		-- down a beat later -- there is no exit teleport, this is a real match
		-- and they stay in it.
		for uid, lesson in lessons do
			if Tutorial.advance(lesson) then
				local plr = Players:GetPlayerByUserId(uid)
				if plr ~= nil then
					StateRE:FireClient(plr, "tutorial", Tutorial.state(lesson))
				end
				if lesson.finished or lesson.failed then
					lessons[uid] = nil
					if plr ~= nil then
						Analytics.event("follow_lesson", plr, lesson.stepIndex, {
							result = lesson.failed and "failed" or "done",
						})
						task.delay(TUTORIAL_EXIT_SECONDS, function()
							if plr.Parent ~= nil and lessons[uid] == nil then
								StateRE:FireClient(plr, "tutorial", nil)
							end
						end)
					end
				end
			end
		end

		if sim.changeCount > 0 then
			-- Sliced: a collapse can flip thousands of tiles in one tick and
			-- a single 36 KB frame is a bad neighbour on the wire.
			local sent = 0
			while sent < sim.changeCount do
				local n = math.min(Net.MAX_DELTA_PAIRS, sim.changeCount - sent)
				DeltaRE:FireAllClients(Net.packDelta(sim.changes, n, sent))
				sent += n
			end
			sim:drainChanges()
		end

		-- Structures and rails, on the same "only when it changed" principle
		-- as the tile delta. One appearing, levelling, changing hands or being
		-- razed is a few events a MINUTE across the whole roster, so these are
		-- sent as plain tables rather than earning a packed format.
		local structEvents = sim:drainStructEvents()
		if structEvents then
			StateRE:FireAllClients("structs", structEvents)
		end
		-- Missiles are sent ONCE, at launch: (src, dst, speed, startTick, up).
		-- The client rebuilds the same integer Bezier and derives every frame
		-- itself, so there is no per-tick missile traffic at any salvo size.
		-- A blast is six numbers the client expands into a crater locally --
		-- the PRNG and the BFS visit order are ported bit-for-bit precisely so
		-- that regeneration is exact.
		-- THE TICK RIDES ALONG, and it is what makes the replay above possible:
		-- every event in the batch is timestamped in sim ticks, so a client
		-- with no clock of its own cannot tell how far through a flight a
		-- missile launched two seconds ago is. One number a packet, and packets
		-- only happen when something launches or lands.
		local nukeEvents = Nukes.drainEvents(sim)
		if nukeEvents then
			StateRE:FireAllClients("missiles", nukeEvents, sim.tick)
		end
		local railEvents = sim:drainRailEvents()
		if railEvents then
			StateRE:FireAllClients("rails", railEvents)
		end

		-- A TRADING BOAT CAME IN, and what it paid is drawn on the port that earned
		-- it. Trade is the one income in this game with no click behind it -- a boat
		-- you did not steer docks at a harbour you built minutes ago -- so without
		-- this the entire loop is a treasury figure moving while you are looking at
		-- the map. Private, exactly like the treasury: one client is told, and only
		-- when the owner is a person.
		local payouts = sim:drainTradePayouts()
		if payouts then
			local byPlayer = {}
			for _, e in payouts do
				local p = sim.players[e.id]
				local plr = p and p.userId and Players:GetPlayerByUserId(p.userId)
				-- A faux empire can be wearing an absent player's userId (see
				-- reidentifyFaux), so the id alone is not proof -- the same guard the
				-- elimination loot below applies.
				if plr and sim:playerByUserId(plr.UserId) == p then
					local list = byPlayer[plr]
					if list == nil then
						list = {}
						byPlayer[plr] = list
					end
					list[#list + 1] = { t = e.tile, g = e.gold }
				end
			end
			-- One send per PLAYER rather than per payout: two of your ports can be
			-- paid on the same tick, and each is a table of five bytes' worth.
			for plr, list in byPlayer do
				StateRE:FireClient(plr, "portgold", list)
			end
		end

		-- Elimination loot. That an empire FELL is public -- everyone watched
		-- its colour leave the map -- but the sum is the captor's own treasury,
		-- which this game deliberately keeps private. So it goes to exactly one
		-- client, and only when the captor is a person: a bot takes the gold
		-- just the same, it simply has nobody to tell.
		local conquests = sim:drainConquests()
		if conquests then
			for _, e in conquests do
				-- PUBLIC first: that an empire DIED is the loudest thing that
				-- happens on this map and everyone watches its colour go. The
				-- skull is planted where it died, on every client, whether or not
				-- anybody was credited with the kill.
				-- An empire wiped off the map has betrayed nobody: its
				-- alliances and open asks simply go (upstream removeOnDeath).
				Alliances.onPlayerDeath(sim, e.victimId)
				local fallen = sim.players[e.victimId]
				StateRE:FireAllClients("fell", {
					id = e.victimId,
					name = fallen and fallen.name or "That empire",
					tile = e.tile,
				})
				local captor = sim.players[e.captorId]
				local plr = captor and captor.userId
					and Players:GetPlayerByUserId(captor.userId)
				-- A faux empire can be WEARING an absent player's userId (see
				-- reidentifyFaux), so the id alone is not proof. Ask the sim who
				-- that Roblox player actually is and require it to be this one.
				if plr and sim:playerByUserId(plr.UserId) == captor then
					local victim = sim.players[e.victimId]
					StateRE:FireClient(plr, "conquered", {
						name = victim and victim.name or "That empire",
						gold = e.gold,
					})
				end
			end
		end
	end

	if steps == 0 then
		return
	end

	-- The time the SIMULATION advanced, not the frame's. Both timers below
	-- are only reached on the frames a tick fired -- about one in six at
	-- 60fps against a 10Hz tick -- so feeding them the frame dt ran them at
	-- a sixth of real time: the "half second" summary actually went out
	-- every three seconds, and the numbers on screen crawled.
	local simDt = steps * Config.TICK_DT

	-- Boats and trains move every tick, so they are the only part of the
	-- economy that needs a continuous stream -- and at the 5 Hz summary rate a
	-- late map's traffic would be the largest thing on the wire after the tile
	-- delta. Sent at 2 Hz and interpolated by the client instead: a boat is
	-- read as "roughly there", never as a coordinate.
	vehicleTimer += simDt
	if vehicleTimer >= VEHICLE_INTERVAL then
		vehicleTimer = 0
		local vehicles = sim:vehicles()
		if #vehicles > 0 or lastVehicleCount > 0 then
			StateRE:FireAllClients("vehicles", Net.packVehicles(vehicles))
		end
		lastVehicleCount = #vehicles
	end

	statsTimer += simDt
	if statsTimer >= STATS_INTERVAL then
		statsTimer = 0
		StateRE:FireAllClients("players", Net.packPlayers(playerSummary()))
		-- The armies in the field, drawn on the fronts they are fighting on.
		-- Public: every player can already see the territory change, and
		-- hiding the size of a visible push only makes the map unreadable.
		StateRE:FireAllClients("armies", Net.packArmies(sim:armies()))

		for _, plr in Players:GetPlayers() do
			local p = sim:playerByUserId(plr.UserId)
			if p and p.spawned then
				local outgoing, incoming = frontsFor(p)
				local reinforceTroops, reinforceGold, _, reinforceLeft = sim:reinforceQuote(p)
				reinforceTroops, reinforceGold, reinforceLeft =
					math.floor(reinforceTroops), math.floor(reinforceGold), math.floor(reinforceLeft)
				-- Your treasury rides with your fronts because both are
				-- genuinely private and both already cost one send per client.
				-- Nobody else's gold goes out at all: the reference shows it on
				-- the leaderboard, but this standings table dropped the column
				-- on purpose, and a figure nothing reads is pure bandwidth.
				StateRE:FireClient(plr, "fronts", {
					out = outgoing,
					-- Your own diplomacy -- allies, asks in and out -- on the
					-- private beat, so a client that connected late or missed an
					-- event converges inside 200 ms.
					diplo = Alliances.snapshotFor(sim, p.id),
					inc = incoming,
					gold = math.floor(p.gold),
					-- THE SKIN'S GROWTH BONUS, so the client's income readout can
					-- match the curve the server actually integrates. Sim multiplies
					-- growth by 1 + p.growthBoost (set from the equipped boosted
					-- pattern) and the client mirrored only the base curve, so a
					-- player wearing one was shown less income than they were
					-- getting. Private, like the treasury it rides beside.
					boost = p.growthBoost or 0,
					cost = math.floor(sim.structureCost(p, Sim.CITY)),
					portCost = math.floor(sim.structureCost(p, Sim.PORT)),
					-- FREE WARHEADS IN HAND ("+1 Nuke!", tutorial only). Rides
					-- here for the reason the treasury does -- it is private,
					-- and it is a PRICE the client has to know to draw the
					-- launch button honestly: without it the client refuses
					-- the shot for gold the buyer never has to pay. Sent every
					-- summary rather than on the grant, so a client that
					-- joined late or missed the message still converges.
					freeNukes = p.freeNukes or 0,
					-- Free defence towers in hand, sent for the reason the warheads
					-- above are: the rail prices whatever is armed, and a tower
					-- already paid for must not be quoted at 50,000. `or 0` and not
					-- "keep the last value", because it is a COUNT that goes DOWN.
					freePosts = p.freePosts or 0,
					freeCities = p.freeCities or 0,
					freeSams = p.freeSams or 0,
					-- Ports and factories share one ladder, so these two are
					-- always equal -- sent anyway, because the client prices
					-- whatever build mode is armed and should not have to know
					-- that.
					factoryCost = math.floor(sim.structureCost(p, Sim.FACTORY)),
					-- The defence post climbs a linear ladder of its own
					-- (50k/100k/.../250k), so the client cannot derive it from
					-- either of the two above and is sent the figure like
					-- every other price.
					postCost = math.floor(sim.structureCost(p, Sim.DEFENSE_POST)),
					-- The anti-nuke tower climbs a linear ladder of its own too (1.5M
					-- then 3M), so it is sent for the reason the post is: the client
					-- cannot derive it from any other price on this message.
					samCost = math.floor(sim.structureCost(p, Sim.SAM_LAUNCHER)),
					-- The two guns climb linear ladders of their own (2026-09-21).
					artilleryCost = math.floor(sim.structureCost(p, Sim.ARTILLERY)),
					airfieldCost = math.floor(sim.structureCost(p, Sim.AIRFIELD)),
					railgunCost = math.floor(sim.structureCost(p, Sim.RAILGUN)),
					-- REINFORCEMENTS (2026-09-21): what one purchase costs right now,
					-- how many men it brings, and how many ticks of cooldown are left.
					-- All three from one quote so they cannot disagree. The button
					-- prints the price while it may be pressed and the countdown
					-- while it may not; a cost of 0 means the army is at its ceiling
					-- and there is nothing to sell.
					reinforceCost = reinforceGold,
					reinforceTroops = reinforceTroops,
					reinforceLeft = reinforceLeft,
					cities = p.cityCount,
					ports = p.portCount,
					factories = p.factoryCount,
					-- EVERY city level, sites still going up included (p.cityLevels
					-- counts completed ones only). The client's ceiling takes a
					-- city the moment it is placed (owner, 2026-09-11), and this
					-- keeps the next message agreeing with it instead of taking
					-- the level back for the two seconds it takes to build.
					levels = Units.count(sim, p.id, Units.CITY),
				})
			end
		end

		StateRE:FireAllClients("phase", {
			phase = sim.phase,
			remaining = sim.phase == "spawn"
					and math.max(0, Config.SPAWN_PHASE_SECONDS - sim.phaseTick * Config.TICK_DT)
				or 0,
			threshold = sim:winThreshold(),
			playableLand = sim.playableLand,
			-- The win check's OWN denominator (land minus fallout), so the finish
			-- line the HUD draws is the line the sim actually tests against, and
			-- not one a nuke has quietly moved.
			contested = Nukes.contestableLand(sim),
			-- nil in a free-for-all, which is how the HUD knows to hide the bar.
			teams = sim:teamStats(),
			-- IS A LESSON RUNNING, on a message that REPEATS. The "tutorial"
			-- message carries the lesson card and is FireClient to the student on
			-- card advance; `init` carries it once at round start. Both are fine
			-- for drawing a card and useless as a GATE, because a listener that
			-- connects late -- any client script that yields through its own setup
			-- -- misses `init` and then waits on an advance that may be a long way
			-- off. This flag rides the STATS_INTERVAL broadcast instead, so a late
			-- listener converges inside 200 ms. A boolean, not the card: anything
			-- wanting the card still reads the message that carries it.
			tutorial = tutorialSession ~= nil and not tutorialEnded,
		})
	end

	-- THE TRACK IS OVER, SO THIS ROUND IS (owner, 2026-09-04: "after the
	-- tutorial, player should return to main lobby where they can play the next
	-- game"). It used to play on as an ordinary match -- see the note on
	-- Tutorial.DONE, which argued for exactly that -- and the cost was that a
	-- student who had just been taught the game was left alone in a bot war with
	-- no way to reach a real one short of quitting the experience.
	--
	-- SAFE TO SEND EVERYONE: a tutorial server holds one player by construction
	-- (the matchmaker reserves it for the one student, which is why `advance`
	-- above fires at a single client). returnToLobby is the same primitive the
	-- end of an ordinary match uses and it latches, so the win path below firing
	-- as well is harmless.
	if tutorialOverAt ~= 0 and os.clock() - tutorialOverAt >= TUTORIAL_EXIT_SECONDS then
		tutorialOverAt = 0
		if IS_MATCH then
			returnToLobby()
		else
			-- A Studio session has nowhere to teleport to, so it does what the
			-- end of a round does there: rotate in place.
			startRound()
		end
	end

	if sim.phase == "ended" then
		if not endedSettled then
			endedSettled = true
			local winner = sim.winnerId and sim.players[sim.winnerId]
			local stats = sim:teamStats()
			StateRE:FireAllClients("win", {
				id = sim.winnerId,
				name = winner and winner.name or "nobody",
				tiles = winner and winner.tileCount or 0,
				team = sim.winnerTeam,
				teamTiles = (stats and sim.winnerTeam) and stats[sim.winnerTeam].tiles or 0,
			})
			-- ...and everyone still standing is paid. `finish` places the
			-- survivors by the land they ended on, above every empire that
			-- died, so the top of the board is settled here and the rest of it
			-- was settled tick by tick as each empire fell.
			if moneyTracker ~= nil then
				settleIds(moneyTracker:finish())
			end
			-- ...and the funnel's last step, for everyone still in the room to
			-- see it. `won` reads the TEAM when there is one: being on the
			-- winning side is winning, whether or not the winning empire was
			-- yours.
			local roundMinutes = (os.clock() - roundStartedAt) / 60
			for _, plr in Players:GetPlayers() do
				local p = sim:playerByUserId(plr.UserId)
				local won = false
				if p ~= nil then
					won = (sim.winnerId ~= nil and sim.winnerId == p.id)
						or (sim.winnerTeam ~= nil and sim.teamOf[p.id] == sim.winnerTeam)
				end
				Analytics.matchFinished(plr, {
					minutes = roundMinutes,
					won = won,
					alive = p ~= nil and (p.tileCount or 0) > 0,
					map = mapId,
					mode = modeId,
				})
			end
		end
		endedTimer += simDt
		if endedTimer >= 12 then
			endedTimer = 0
			-- A reserved server exists for ONE match. When it is over everyone
			-- goes back to the matchmaking page and this instance shuts down;
			-- only a Studio session, which has nowhere to teleport to, rotates
			-- in place the way this used to.
			if IS_MATCH then
				returnToLobby()
			else
				startRound()
			end
		end
	else
		endedTimer = 0
		endedSettled = false
	end
end)

-- PERSISTENCE ON. This is the one line ConquestData was written to wait for,
-- and it is deliberately the LAST thing this file does: `install` connects its
-- own PlayerRemoving, which releases the profile, and the money settlement
-- above has to have banked the round before that happens. Connection order is
-- registration order, so "last" is the whole guarantee.
--
-- It runs on a LOBBY server too. Nothing there earns anything, but the balance
-- has to be loaded for the page to print it, and `install` is idempotent, so
-- both roles calling it is free.
-- THE FUNNELS ON, and it has to be THIS side of the line below. Analytics
-- banks lifetime playtime onto the profile from its own PlayerRemoving, and
-- `Data.install` connects the handler that RELEASES that profile: connection
-- order is registration order, so installing after it would write the playtime
-- into a table nobody saves.
-- A PROFILE LANDING IS WHEN A PATTERN ARRIVES. Everything else about an empire
-- is known the moment its owner walks in; this one waits on a DataStore read,
-- and that read waits on the lobby server releasing the session lock.
--
-- Registered ahead of `Data.install` for the same reason everything else here
-- is: `onReady` replays for profiles that are ALREADY loaded, so ordering
-- cannot make it miss one.
Data.onReady(function(player, _profile)
	-- BOTH MUST RUN. `applyPattern(player) or applyFlag(player)` would
	-- short-circuit and skip the flag on every profile that also moved a
	-- pattern, which is most of them.
	local moved = applyPattern(player)
	if applyFlag(player) then
		moved = true
	end
	if moved then
		StateRE:FireAllClients("roster", roster())
	end
end)

-- ...AND AGAIN WHEN VIP LANDS. The pass is confirmed by a web call
-- (Monetization.settleVip) that finishes AFTER the profile does, so the +10%
-- is not knowable at the load above -- and this is also how a pass bought in
-- the middle of a round reaches the empire without a rejoin. The attribute is
-- the moment it becomes knowable, and applyPattern is idempotent, so a
-- redundant fire costs one comparison.
local function watchVip(player: Player)
	player:GetAttributeChangedSignal("ConquestVip"):Connect(function()
		if applyPattern(player) then
			StateRE:FireAllClients("roster", roster())
		end
	end)
	-- The FAST_RELOAD pass settles the same way (2026-09-25); the empire's
	-- reloadMult is not on the roster, so there is nothing to repaint.
	player:GetAttributeChangedSignal(Products.PASS_ATTR .. "FAST_RELOAD"):Connect(function()
		applyPattern(player)
	end)
end
for _, player in Players:GetPlayers() do
	watchVip(player)
end
Players.PlayerAdded:Connect(watchVip)

Analytics.install({
	role = IS_MATCH and "match" or "lobby",
	profile = Data.get,
	markDirty = Data.markDirty,
})

-- ARMED. This is the line `Data.install()` used to be: `Monetization.install`
-- calls it underneath and adds a ProcessReceipt handler, so the POSITION is
-- unchanged -- and the position is the part that matters, for the reason
-- written above it. Idempotent, and it runs in both roles because a receipt
-- can land in either: a player who buys on the lobby page and teleports before
-- it arrives gets the grant on the match server, and the session lock is what
-- makes that safe.
Monetization.install()

-- The version leads the line on purpose. This is the answer to "is my edit
-- actually running?", which a stale editor tab, the plugin VM's module cache
-- and a parallel session editing the same file can each make unanswerable.
print(
	"[Conquest] version " .. Config.VERSION
		.. " -- " .. (IS_MATCH and "MATCH" or "LOBBY") .. " server up ("
		.. #Maps.ORDER .. " maps x " .. #Modes.ORDER .. " modes in rotation)"
)
