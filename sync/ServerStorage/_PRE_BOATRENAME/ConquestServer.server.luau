--!strict
-- Conquest :: server entry
-- Owns the simulation, drives it at a fixed tick rate, and replicates
-- ownership deltas. Terrain is never sent -- clients rebuild it from the seed.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Modes = require(Shared.Modes)
local Net = require(Shared.Net)
local Sim = require(Shared.Sim)
local Warships = require(Shared.Warships)
local Nukes = require(Shared.Nukes)
local Units = require(Shared.Units)

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

local sim
local roundId = 0

-- ============================================================== broadcast ==

-- Everything about a player that cannot change inside a round. Sent once
-- with `init` (and again if someone joins during the spawn phase) instead
-- of five times a second: names are strings, and the per-tick summary was
-- re-transmitting the whole roster to carry three integers per empire.
local function roster()
	local list = {}
	for _, id in sim.playerOrder do
		local p = sim.players[id]
		if p then
			-- `u` is the Roblox user id: the standings board draws a headshot
			-- from it (rbxthumb, resolved client-side). Bots have none and
			-- fall back to a lettered badge in their nation colour.
			table.insert(list, { i = p.id, n = p.name, u = p.userId })
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
				isBot = p.isBot,
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
		if q and q.isBot then
			table.insert(ids, id)
		end
	end
	return ids
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
	print("[Conquest] version " .. Config.VERSION .. " -- round " .. roundId)
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
	-- Published for the sibling server scripts that reach into the live
	-- round (ConquestGold). A round REPLACES the Sim outright, so anything
	-- that cached one would be writing into a dead match; readers take it
	-- from here every time. Server scripts share _G, which is already how
	-- ConquestSimulate holds the round still.
	_G.ConquestSim = sim

	-- Humans first so they get the low ids (and the brighter colours).
	for _, player in Players:GetPlayers() do
		sim:addPlayer(player.DisplayName, false, player.UserId)
	end

	-- The bot count is rounded UP to a whole number of even sides. An uneven
	-- team is not a small unfairness in this game: the spare member is an
	-- extra front the other side has to hold all round, and across six
	-- headless matches the team holding it won every single one.
	-- Bots FILL the roster instead of stacking on top of it. Every empire
	-- costs per-tick work all round -- income, an AI border sample, a row in
	-- every summary, a slot in the attack list -- so a full 24-player server
	-- adding a flat 12 bots ran 36 of them and cost roughly what 36 cost.
	local humans = #sim.playerOrder
	-- Roster scales with THIS map's playable land instead of being flat, so an
	-- empire's share of the map is the same whichever map came up. Upstream
	-- does exactly this and scales nothing else (MapPlaylist.ts:812-825).
	-- See Config.LAND_PER_EMPIRE.
	local roster = math.clamp(
		math.floor(sim.playableLand / Config.LAND_PER_EMPIRE + 0.5),
		Config.MIN_EMPIRES,
		Config.TARGET_EMPIRES
	)
	local botCount = math.clamp(roster - humans, 0, Config.NUM_BOTS)
	if sim.teamCount > 0 then
		botCount = math.ceil((humans + botCount) / sim.teamCount) * sim.teamCount - humans
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

	for _, player in Players:GetPlayers() do
		sendInit(player)
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
		if sim and (lastHello[player.UserId] or 0) < hnow - 5 then
			lastHello[player.UserId] = hnow
			sendInit(player)
		end
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

	local kind = payload.t
	local tile = payload.tile
	if typeof(tile) ~= "number" or tile ~= tile or tile < 0 or tile >= Config.NUM_TILES then
		return
	end
	tile = math.floor(tile)

	if kind == "spawn" then
		if sim.phase == "spawn" and not p.spawned then
			if sim:spawnPlayer(p, tile) then
				StateRE:FireClient(player, "spawned", { tile = tile })
			end
		end
	elseif kind == "attack" then
		-- The player chooses the size, but only from Config.ATTACK_PRESETS:
		-- the payload is SNAPPED to the nearest one rather than trusted, so
		-- the three buttons are also the whitelist.
		local ratio = snapPreset(payload.ratio)
		local ok, why = sim:launchAttack(p.id, tile, ratio)
		-- UPSTREAM'S RULE, AND THE WHOLE POINT OF HAVING A NAVY: tapping land
		-- you cannot walk to sends a boat instead
		-- (`AiAttackBehavior.sendAttack`,
		-- src/core/execution/utils/AiAttackBehavior.ts:760-778,
		-- picks land vs sea the same way). No second button and no mode
		-- switch -- you point at a country and the game works out whether
		-- that means marching or sailing.
		if not ok and why == "notadjacent" then
			local okBoat, whyBoat = sim:launchBoat(p.id, tile)
			if okBoat then
				ok, why = true, nil
			else
				-- Report the SEA refusal, not the land one. "Your land does
				-- not touch them" is not the useful sentence when the player
				-- can see perfectly well that there is an ocean in the way.
				why = whyBoat
			end
		end
		if not ok then
			-- Answer the tap. A refusal that says nothing reads as a broken
			-- control rather than as an illegal move.
			StateRE:FireClient(player, "denied", {
				reason = why,
				owner = buffer.readu8(sim.map.owner, tile),
			})
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
		end
		local ok, why, landed = sim:buildStructure(p.id, tile, what)
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
		if what == Units.ATOM_BOMB then
			ok, why = Nukes.launchNuke(sim, p.id, what, tile)
		else
			ok, why = false, "notanuke"
		end
		if not ok then
			StateRE:FireClient(player, "denied", { reason = why, tile = tile, kind = what })
		end
	-- NO "warship" BUILD INTENT. Warships are not purchased in this game.
	-- DELIBERATE DEVIATION FROM UPSTREAM, by the owner's design call: upstream
	-- sells warships from the build menu at min(1e6, (n+1)*250,000), and here
	-- PORTS ARE THE ONLY NAVAL PURCHASE. A port produces and sustains its own
	-- squadron, so the naval lever is how many ports you own and how far you
	-- have upgraded them -- see Warships.stepPortProduction. Trade ships were
	-- already automatic (Economy spawns them on nextTradeTick and picks the
	-- partner itself), so the whole navy is now hands-off.
	--
	-- Re-stationing a fleet SURVIVES, because it is a command rather than a
	-- purchase and costs nothing.
	elseif kind == "movewarship" then
		-- MoveWarshipExecution: re-station the listed ships, silently skipping
		-- any that cannot swim to the tile.
		local ids = payload.ids
		if typeof(ids) == "table" then
			Warships.move(sim, p.id, ids, tile)
		end
	elseif kind == "cancel" then
		sim:cancelAttacks(p.id)
	end
end)

-- ============================================================== lifecycle ==

Players.PlayerAdded:Connect(function(player)
	if not sim then
		return
	end
	if sim.phase == "spawn" or sim.phase == "lobby" then
		if not sim:playerByUserId(player.UserId) then
			sim:addPlayer(player.DisplayName, false, player.UserId)
			-- Names ride with the roster now, so everyone else needs the new one.
			StateRE:FireAllClients("roster", roster())
		end
	end
	-- Mid-round joiners spectate until the next round.
	task.defer(sendInit, player)
end)

Players.PlayerRemoving:Connect(function(player)
	if not sim then
		return
	end
	local p = sim:playerByUserId(player.UserId)
	if p then
		-- Leave their territory on the map for the bots to carve up; just
		-- stop the empire from acting.
		p.isBot = true
	end
	lastIntent[player.UserId] = nil
	lastHello[player.UserId] = nil
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
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, list)
	end)
	if not ok then
		warn("[Conquest] return teleport failed: " .. tostring(err))
		returning = false
	end
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
		else
			warn("[Conquest] no match record for this reserved server -- using the rotation instead")
		end
	end

	-- Players arrive from up to three different lobby servers and do not land
	-- together, so hold the start open until the roster the lobby promised has
	-- turned up -- and never longer than BOARD_GRACE, because somebody who
	-- quit during the teleport is never going to arrive at all.
	local expected = (cfg and tonumber(cfg.expected)) or 1
	local t0 = os.clock()
	while os.clock() - t0 < Matchmaker.BOARD_GRACE do
		local here = #Players:GetPlayers()
		if here >= expected then
			break
		end
		LobbyRE:FireAllClients("wait", here, expected)
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
			}
		)
	end)
end

local accumulator = 0
local statsTimer = 0
local endedTimer = 0
local vehicleTimer = 0
-- Kept so the ONE empty list that follows the last ship home is still sent:
-- without it the client keeps drawing a boat that no longer exists.
local lastVehicleCount = 0
local VEHICLE_INTERVAL = 0.5

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

		sim:step()

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

	-- Ships and trains move every tick, so they are the only part of the
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
				-- Your treasury rides with your fronts because both are
				-- genuinely private and both already cost one send per client.
				-- Nobody else's gold goes out at all: the reference shows it on
				-- the leaderboard, but this standings table dropped the column
				-- on purpose, and a figure nothing reads is pure bandwidth.
				StateRE:FireClient(plr, "fronts", {
					out = outgoing,
					inc = incoming,
					gold = math.floor(p.gold),
					cost = math.floor(sim.structureCost(p, Sim.CITY)),
					portCost = math.floor(sim.structureCost(p, Sim.PORT)),
					-- Ports and factories share one ladder, so these two are
					-- always equal -- sent anyway, because the client prices
					-- whatever build mode is armed and should not have to know
					-- that.
					factoryCost = math.floor(sim.structureCost(p, Sim.FACTORY)),
					cities = p.cityCount,
					ports = p.portCount,
					factories = p.factoryCount,
					levels = p.cityLevels,
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
			-- nil in a free-for-all, which is how the HUD knows to hide the bar.
			teams = sim:teamStats(),
		})
	end

	if sim.phase == "ended" then
		if endedTimer == 0 then
			local winner = sim.winnerId and sim.players[sim.winnerId]
			local stats = sim:teamStats()
			StateRE:FireAllClients("win", {
				id = sim.winnerId,
				name = winner and winner.name or "nobody",
				tiles = winner and winner.tileCount or 0,
				team = sim.winnerTeam,
				teamTiles = (stats and sim.winnerTeam) and stats[sim.winnerTeam].tiles or 0,
			})
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
	end
end)

-- The version leads the line on purpose. This is the answer to "is my edit
-- actually running?", which a stale editor tab, the plugin VM's module cache
-- and a parallel session editing the same file can each make unanswerable.
print(
	"[Conquest] version " .. Config.VERSION
		.. " -- " .. (IS_MATCH and "MATCH" or "LOBBY") .. " server up ("
		.. #Maps.ORDER .. " maps x " .. #Modes.ORDER .. " modes in rotation)"
)
