--!strict
-- Conquest :: MatchmakerServer  (lobby servers only)
--
-- Runs the cross-server lobby board. Every public server of this place polls
-- the same three MemoryStore records, shows them to its own players, and --
-- when one of them is ready to launch -- races every other server for the
-- right to reserve the match server.
--
-- THERE IS NO BACKEND ON ROBLOX, so the board is a distributed data structure
-- whose only consensus primitive is `UpdateAsync`, an atomic read-modify-write
-- on one key. Every hard thing in this file is a race, and each is handled
-- INSIDE a transform rather than around it:
--
--   * TWO SERVERS BOTH DECIDE TO LAUNCH. Only one can flip `open -> claim`,
--     because the flip happens inside the transform and the loser sees
--     `state ~= "open"` on its own attempt.
--   * THE WINNER DIES MID-RESERVATION. A claim older than CLAIM_STALE may be
--     stolen, so a crashed host costs 15 seconds rather than wedging the slot
--     until its TTL expires.
--   * A PLAYER JOINS AS THE LOBBY CLOSES. The join is refused in the same
--     transform that would have added them, and they are told why.
--   * A SERVER DIES HOLDING MEMBERS. Every server refreshes a heartbeat on its
--     own entry; entries that stop are pruned by whoever writes next.
--
-- AND ONE THING THAT IS NOT A RACE BUT LOOKS LIKE ONE: a server can only
-- teleport ITS OWN players, so the reservation is published back to the record
-- and all three servers independently teleport their own people with the same
-- access code. Nobody teleports anybody else's.

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Matchmaker = require(Shared.Matchmaker)
local PrivateLobby = require(Shared.PrivateLobby)
local Net = require(Shared.Net)

type Record = Matchmaker.Record

-- Built here as well as in ConquestServer: whichever script runs first creates
-- the folder, and `Net.build` is idempotent. Without this a lobby server would
-- have no remotes at all, because ConquestServer is the only other builder and
-- it is inert here.
local netFolder = Net.build(ReplicatedStorage)
local LobbyRE = netFolder:WaitForChild("Lobby") :: RemoteEvent
local LobbyIntentRE = netFolder:WaitForChild("LobbyIntent") :: RemoteEvent

local IS_MATCH = Matchmaker.isMatchServer()
ReplicatedStorage:SetAttribute(Matchmaker.ROLE_ATTR, IS_MATCH and "match" or "lobby")

-- A match server has nothing to do here. It does not poll, it does not write,
-- and it costs the MemoryStore quota nothing.
if IS_MATCH then
	return
end

-- ------------------------------------------------------------- identity ----

-- `game.JobId` is EMPTY IN STUDIO, and two Studio sessions sharing one id
-- would each think the other's members were their own -- which is exactly the
-- case the two-instance test exists to exercise. A random stand-in makes them
-- distinct servers as far as the board is concerned.
local SERVER_ID = game.JobId
if SERVER_ID == "" then
	SERVER_ID = "studio-" .. HttpService:GenerateGUID(false)
end

local lobbyStore = MemoryStoreService:GetSortedMap(Matchmaker.STORE)
local matchStore = MemoryStoreService:GetHashMap(Matchmaker.MATCH_STORE)

-- userId -> slot key. The authoritative copy lives in MemoryStore; this is the
-- local index that says who to teleport and whose heartbeat to refresh.
local mine: { [number]: string } = {}
local busy: { [number]: boolean } = {}
local cooldown: { [number]: number } = {}
local INTENT_COOLDOWN = 1

-- One warning a minute, not one a second, when API access is off. Without the
-- throttle a Studio session with the setting unticked prints a wall of
-- identical errors and buries everything else; without the expiry a genuine
-- transient failure hours later would be silent.
local complained = -1e9
local function report(what: string, err: any)
	if os.clock() - complained > 60 then
		complained = os.clock()
		warn(
			"[Matchmaker] "
				.. what
				.. " failed: "
				.. tostring(err)
				.. "  -- if this is Studio, tick Game Settings > Security > Enable Studio Access to API Services."
		)
	end
end

local function toast(player: Player, text: string)
	LobbyRE:FireClient(player, "toast", text)
end

-- ------------------------------------------------------------- broadcast ---

-- THE LAST BOARD THIS SERVER READ, kept so a join can be SHOWN the moment it
-- lands instead of whenever the poll next comes round.
--
-- WHY THAT MATTERED. The only push used to be the poll's, so pressing JOIN
-- bought you one MemoryStore write, then up to POLL seconds of waiting for the
-- next tick, then that tick's own GetRangeAsync -- a card that did not move
-- for one to two seconds, with no press state, no colour change and nothing
-- else on the page to look at. A button that does nothing for that long gets
-- pressed again, and the second press is exactly what the intent cooldown
-- throws away. Writing the transform's own result back into the cache and
-- broadcasting it costs one RemoteEvent and no quota at all.
local boardCache: { [string]: Record } = {}
local lastWire: { any }? = nil
local lastSignature = ""
local lastPush = 0

local function signature(wire: { any }): string
	-- Deliberately EXCLUDES the countdown: the client ticks that down itself
	-- between updates, so including it would make every second a change and
	-- there would be no idle state at all.
	local parts = {}
	for _, e in wire do
		table.insert(parts, string.format("%d.%d.%d.%d.%d", e[1], e[2], e[3], e[5], #e[6]))
	end
	return table.concat(parts, "/")
end

-- Idle servers send one packet every PUSH seconds rather than one a second,
-- because nothing on a card moves except a clock the client runs on its own.
-- `force` is the press path: somebody is waiting on this exact packet.
local function pushBoard(force: boolean)
	local wire = Matchmaker.wire(boardCache, os.time())
	lastWire = wire
	local sig = signature(wire)
	if force or sig ~= lastSignature or (os.clock() - lastPush) >= Matchmaker.PUSH then
		lastSignature = sig
		lastPush = os.clock()
		LobbyRE:FireAllClients("board", wire)
	end
end

-- ---------------------------------------------------------------- store ----

local function readBoard(): { [string]: Record }
	local out: { [string]: Record } = {}
	local ok, items = pcall(function()
		-- The slot keys are the ONLY keys in this sorted map (match configs
		-- live in a separate hash map on purpose -- mixed in here they would
		-- sort ahead of "slotN" and a bounded range read could return nothing
		-- but match configs).
		return lobbyStore:GetRangeAsync(Enum.SortDirection.Ascending, 10)
	end)
	if not ok then
		report("GetRangeAsync", items)
		return out
	end
	for _, item in items :: any do
		local key = item.key
		local value = item.value
		if type(key) == "string" and type(value) == "table" then
			out[key] = value
		end
	end
	return out
end

-- What the OTHER cards are currently offering, so a fresh draw can avoid all
-- of it -- map, mode and pair. See Matchmaker.drawPair.
local function shownElsewhere(board: { [string]: Record }, exceptKey: string?): { { map: string, mode: string } }
	local out = {}
	for key, rec in board do
		if key ~= exceptKey and rec.map and rec.mode then
			table.insert(out, { map = rec.map, mode = rec.mode })
		end
	end
	return out
end

-- Writes a record back under the guard that our generation is still the one in
-- the store. Every write in this file goes through here, because the whole
-- family of bugs it prevents is the same one: a slot that reset while we were
-- yielding, and a stale write that un-resets it.
local function commit(key: string, generation: string, mutate: (Record) -> boolean): boolean
	local applied = false
	local ok, err = pcall(function()
		lobbyStore:UpdateAsync(key, function(rec: any)
			applied = false
			if type(rec) ~= "table" then
				return nil
			end
			if generation ~= "" and rec.id ~= generation then
				return nil
			end
			if not mutate(rec) then
				return nil
			end
			applied = true
			return rec
		end, Matchmaker.RECORD_TTL)
	end)
	if not ok then
		report("UpdateAsync(" .. key .. ")", err)
		return false
	end
	return applied
end

local function ensureSlot(index: number, board: { [string]: Record })
	local slot = Matchmaker.SLOTS[index]
	if board[slot.key] then
		return
	end
	local fresh = Matchmaker.newRecord(index, shownElsewhere(board))
	local actual = nil
	local ok, err = pcall(function()
		lobbyStore:UpdateAsync(slot.key, function(rec: any)
			-- Somebody else got there first while we were yielding. Theirs is
			-- as good as ours and has the same shape; take it -- and take it
			-- LITERALLY, because assuming our own draw won would leave this
			-- server broadcasting a map the store does not have and guarding
			-- its writes with a generation nobody else knows.
			if type(rec) == "table" then
				actual = rec
				return nil
			end
			actual = fresh
			return fresh
		end, Matchmaker.RECORD_TTL)
	end)
	if ok and actual then
		board[slot.key] = actual
	elseif not ok then
		report("create " .. slot.key, err)
	end
end

-- ------------------------------------------------------- private lobbies ---
--
-- A ROOM YOU MAKE, keyed by its own four digits, configured by whoever made
-- it and started when they say so. Everything below is the same distributed
-- data structure as the public board above -- one record, `UpdateAsync` as the
-- only consensus primitive, every hard case handled INSIDE a transform -- and
-- it is deliberately a separate store and a separate code path rather than a
-- fourth slot, because almost nothing about it is the same: no countdown, no
-- rotation, no claim race between strangers' servers, and a host.
--
-- WHAT IS THE SAME, and had to be: a room spans SERVERS. Four friends who
-- clicked the game from four different places land in four different public
-- servers, and the whole point of a code is that it reaches across them. So
-- each server holds its own entry in the record, heartbeats it, and teleports
-- only its own people once the host's server has published a reservation.

local privStore = MemoryStoreService:GetHashMap(PrivateLobby.STORE)

-- userId -> code. Same shape and the same reason as `mine`: MemoryStore is
-- authoritative and this is the local index that says whose heartbeat to
-- refresh and who to teleport.
local room: { [number]: string } = {}
local roomCache: { [string]: any } = {}

-- The room this server has already sent its people to. A single string for the
-- reason `teleportedGeneration` is one: the only code that can matter is the
-- one being launched right now.
local sentRoom = ""

local function playersInRoom(code: string): { Player }
	local list = {}
	for userId, c in room do
		if c == code then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(list, player)
			end
		end
	end
	return list
end

-- The distinct codes this server is holding anybody in. Usually zero, which is
-- what makes the feature free for every server nobody is using it in.
local function heldCodes(): { string }
	local seen, out = {}, {}
	for userId, code in room do
		if not seen[code] and Players:GetPlayerByUserId(userId) then
			seen[code] = true
			table.insert(out, code)
		end
	end
	return out
end

-- The room goes only to the people in it. A public server can hold members of
-- several unrelated rooms at once and none of them is entitled to the others'
-- roster, so this is per-player rather than FireAllClients.
local function pushRoom(code: string)
	local rec = roomCache[code]
	if not rec then
		return
	end
	local wire = PrivateLobby.wire(rec, os.time())
	for _, player in playersInRoom(code) do
		LobbyRE:FireClient(player, "room", wire)
	end
end

-- `false` is "you are not in a room", and it is what closes the panel. Sent
-- explicitly rather than inferred from silence, because silence is also what
-- an unreachable MemoryStore looks like.
local function pushNoRoom(player: Player)
	LobbyRE:FireClient(player, "room", false)
end

-- Every write to a room goes through here, and every one of them broadcasts
-- the transform's OWN result the instant it lands -- see pushBoard for why
-- waiting for the next poll is not an option on a page with a button on it.
local function commitRoom(code: string, mutate: (any) -> boolean): (boolean, any)
	local applied, updated = false, nil
	local ok, err = pcall(function()
		privStore:UpdateAsync(code, function(rec: any)
			applied = false
			updated = nil
			if type(rec) ~= "table" or type(rec.servers) ~= "table" then
				return nil
			end
			if not mutate(rec) then
				return nil
			end
			applied = true
			updated = rec
			return rec
		end, PrivateLobby.TTL)
	end)
	if not ok then
		report("room " .. code, err)
		return false, nil
	end
	if applied and updated then
		roomCache[code] = updated
		pushRoom(code)
	end
	return applied, updated
end

-- Takes one member out of this server's entry. Shared by the LEAVE button and
-- by PlayerRemoving, which must do exactly the same thing -- a player who quits
-- the game and one who presses leave are the same event to the record.
local function dropMember(code: string, userId: number)
	commitRoom(code, function(rec)
		local entry = PrivateLobby.entryFor(rec, SERVER_ID)
		if not entry then
			return false
		end
		local at = table.find(entry.u, userId)
		if not at then
			return false
		end
		table.remove(entry.u, at)
		entry.t = os.time()
		PrivateLobby.prune(rec, os.time())
		-- THE HOST WALKING OUT must not leave a room nobody can start. See
		-- PrivateLobby.reseat: lowest userId still in it, which every server
		-- derives identically from the same record.
		PrivateLobby.reseat(rec)
		return true
	end)
end

local function leaveRoom(player: Player)
	local userId = player.UserId
	local code = room[userId]
	if not code then
		return
	end
	room[userId] = nil
	pushNoRoom(player)
	dropMember(code, userId)
end

local function createRoom(player: Player, settings: any)
	local userId = player.UserId
	-- One room at a time. Leaving first also means the room being left has its
	-- correct roster before the new one exists.
	if room[userId] then
		leaveRoom(player)
	end

	local now = os.time()
	-- FOUR DIGITS IS TEN THOUSAND ROOMS, so a draw can collide -- and with the
	-- birthday bound it collides far sooner than "ten thousand rooms" suggests.
	-- The claim happens INSIDE the transform: seeing a record at that code
	-- means somebody else got there first and this draw is spent, which is the
	-- only test that cannot race a concurrent create.
	for _ = 1, PrivateLobby.TRIES do
		local code = PrivateLobby.newCode()
		local fresh = PrivateLobby.newRecord(code, userId, settings)
		table.insert(fresh.servers, { j = SERVER_ID, t = now, u = { userId } })
		local won = false
		local ok, err = pcall(function()
			privStore:UpdateAsync(code, function(rec: any)
				won = false
				if type(rec) == "table" then
					return nil
				end
				won = true
				return fresh
			end, PrivateLobby.TTL)
		end)
		if not ok then
			report("create room", err)
			toast(player, "The lobby service is unreachable right now.")
			return
		end
		if won then
			room[userId] = code
			roomCache[code] = fresh
			pushRoom(code)
			return
		end
	end
	toast(player, "Could not find a free code -- try again.")
end

local function joinRoom(player: Player, code: string)
	local userId = player.UserId
	if room[userId] and room[userId] ~= code then
		leaveRoom(player)
	end

	local now = os.time()
	local refusal, joined = "", false
	local updated: any = nil
	local ok, err = pcall(function()
		privStore:UpdateAsync(code, function(rec: any)
			refusal, joined, updated = "", false, nil
			if type(rec) ~= "table" or type(rec.servers) ~= "table" then
				refusal = "No lobby with that code."
				return nil
			end
			PrivateLobby.prune(rec, now)
			-- THE CLOSING RACE, same as the public board's: refusing inside
			-- the transform is what makes it impossible to be added to a match
			-- that has already reserved its server and left without you.
			if rec.state ~= "open" then
				refusal = "That lobby has already started."
				return nil
			end
			if PrivateLobby.hasMember(rec, userId) then
				joined = true
				return nil
			end
			if PrivateLobby.members(rec) >= PrivateLobby.CAP then
				refusal = "That lobby is full."
				return nil
			end
			local entry = PrivateLobby.entryFor(rec, SERVER_ID)
			if not entry then
				entry = { j = SERVER_ID, t = now, u = {} }
				table.insert(rec.servers, entry)
			end
			;(entry :: any).t = now
			table.insert((entry :: any).u, userId)
			joined = true
			updated = rec
			return rec
		end, PrivateLobby.TTL)
	end)

	if not ok then
		report("join room " .. code, err)
		toast(player, "The lobby service is unreachable right now.")
		return
	end
	if joined then
		room[userId] = code
		if updated then
			roomCache[code] = updated
			pushRoom(code)
		elseif roomCache[code] then
			pushRoom(code)
		end
	elseif refusal ~= "" then
		toast(player, refusal)
	end
end

-- HOST ONLY, and enforced inside the transform rather than against this
-- server's copy of the record: the host can change while a settings packet is
-- in flight, and the record is the only thing that knows.
local function setRoom(player: Player, settings: any)
	local code = room[player.UserId]
	if not code then
		return
	end
	local want = PrivateLobby.clampSettings(settings)
	commitRoom(code, function(rec)
		if rec.host ~= player.UserId or rec.state ~= "open" then
			return false
		end
		local same = true
		for i, v in want do
			if rec.s[i] ~= v then
				same = false
			end
		end
		-- Cancelling an unchanged write is not an optimisation, it is what
		-- stops a client that resends its whole settings block on every
		-- keystroke from spending the universe's write budget.
		if same then
			return false
		end
		rec.s = want
		return true
	end)
end

-- STUDIO HAS NO RESERVED SERVERS, so a room started there begins in the
-- session it is already in -- the same trick `startLocally` plays for the
-- public board, and the only way to play a private match without shipping.
local function startRoomLocally(code: string, st: any)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MAP_ATTR, st.map)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MODE_ATTR, st.mode)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TEAMS_ATTR, st.teams)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TROOPS_ATTR, st.troopScale)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_GOLD_ATTR, st.startGold)
	ReplicatedStorage:SetAttribute(Matchmaker.ROLE_ATTR, "match")
	-- DELETE THE ROOM. This session stops polling the moment the role flips,
	-- so a record left in "claim" would sit there for its whole TTL and the
	-- next playtest that typed the same code would be told it had started.
	pcall(function()
		privStore:RemoveAsync(code)
	end)
	print(string.format(
		"[Matchmaker] STUDIO: no reserved servers here, so room %s (%s / %s, %d teams, x%.2g troops, %d gold) starts in this session.",
		code, st.map, st.mode, st.teams, st.troopScale, st.startGold
	))
end

local function sendRoomToMatch(rec: any)
	if not rec or rec.access == "" or sentRoom == rec.code then
		return
	end
	local list = playersInRoom(rec.code)
	if #list == 0 then
		return
	end
	sentRoom = rec.code

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = rec.access
	-- Carried for convenience only, exactly as the public path does: the match
	-- server reads its settings from the match record keyed by
	-- PrivateServerId, never from teleport data, which belongs to whichever
	-- client happens to arrive first.
	options:SetTeleportData({ private = true, code = rec.code })

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, list, options)
	end)
	if not ok then
		task.wait(1)
		-- Re-take the list: TeleportAsync throws on a player who has since
		-- left, which would fail the retry for the whole batch.
		list = playersInRoom(rec.code)
		if #list == 0 then
			sentRoom = ""
			return
		end
		ok = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, list, options)
		end)
	end

	if ok then
		for _, player in list do
			room[player.UserId] = nil
		end
		commitRoom(rec.code, function(r)
			local entry = PrivateLobby.entryFor(r, SERVER_ID)
			if not entry then
				return false
			end
			entry.u = {}
			entry.t = os.time()
			return true
		end)
	else
		sentRoom = ""
		warn("[Matchmaker] room teleport failed: " .. tostring(err))
		for _, player in list do
			room[player.UserId] = nil
			toast(player, "Could not start that match. Try again.")
			pushNoRoom(player)
		end
	end
end

local function launchRoom(code: string, expected: number)
	local st = PrivateLobby.settings(roomCache[code] and roomCache[code].s)

	local ok, access, psid = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not ok then
		if RunService:IsStudio() then
			startRoomLocally(code, st)
			return
		end
		warn("[Matchmaker] ReserveServer failed for room " .. code .. ": " .. tostring(access))
		-- Hand the room back OPEN rather than leaving it claimed until the
		-- stale-steal timer notices. The host can simply press start again.
		commitRoom(code, function(r)
			if r.state ~= "claim" then
				return false
			end
			r.state = "open"
			r.hostServer = ""
			r.claimedAt = 0
			return true
		end)
		return
	end

	-- THE SETTINGS TRAVEL WITH THE RESERVATION, not with the players. This is
	-- the record ConquestServer reads on the far side to know what round to
	-- build, and it is the only thing that decides it.
	local wrote = pcall(function()
		matchStore:SetAsync(psid, {
			map = st.map,
			mode = st.mode,
			teams = st.teams,
			troopScale = st.troopScale,
			startGold = st.startGold,
			cap = PrivateLobby.CAP,
			slot = 0,
			id = code,
			expected = expected,
			private = true,
		}, Matchmaker.MATCH_TTL)
	end)
	if not wrote then
		warn("[Matchmaker] could not publish room " .. code .. "'s match record; it will use the rotation.")
	end

	local now = os.time()
	local published = commitRoom(code, function(r)
		if r.state ~= "claim" then
			return false
		end
		r.state = "ready"
		r.access = access
		r.psid = psid
		r.readyAt = now
		return true
	end)
	if published then
		print(string.format("[Matchmaker] launching room %s -- %s / %s, %d players", code, st.map, st.mode, expected))
		sendRoomToMatch(roomCache[code])
	end
end

-- HOST PRESSES START. There is no countdown here: the room launches when the
-- one player who made it says so, and the claim is still a transform because
-- the host's own two servers -- a rejoin mid-press -- can both be holding a
-- copy of the record that says "open".
local function startRoom(player: Player)
	local code = room[player.UserId]
	if not code then
		return
	end
	local now = os.time()
	local won, expected = false, 0
	local refusal = ""
	local claimed: any = nil
	local ok, err = pcall(function()
		privStore:UpdateAsync(code, function(r: any)
			won, refusal, claimed = false, "", nil
			if type(r) ~= "table" or type(r.servers) ~= "table" then
				refusal = "That lobby is gone."
				return nil
			end
			if r.host ~= player.UserId then
				refusal = "Only the host can start this lobby."
				return nil
			end
			PrivateLobby.prune(r, now)
			local stale = r.state == "claim" and (now - (r.claimedAt or 0)) > PrivateLobby.CLAIM_STALE
			if r.state ~= "open" and not stale then
				refusal = "That lobby is already starting."
				return nil
			end
			if PrivateLobby.members(r) <= 0 then
				refusal = "There is nobody in that lobby."
				return nil
			end
			r.state = "claim"
			r.hostServer = SERVER_ID
			r.claimedAt = now
			won = true
			-- Counted AFTER the prune and INSIDE the transform, for the reason
			-- tryClaim spells out: a count taken from a stale copy promises
			-- arrivals that are ghosts, and every real player then watches
			-- PREPARING THE MAP for the whole grace period waiting for them.
			expected = PrivateLobby.members(r)
			claimed = r
			return r
		end, PrivateLobby.TTL)
	end)
	if not ok then
		report("start room " .. code, err)
		toast(player, "The lobby service is unreachable right now.")
		return
	end
	if not won then
		if refusal ~= "" then
			toast(player, refusal)
		end
		return
	end
	-- THE SETTINGS THE MATCH IS BUILT FROM COME FROM THE RECORD THE CLAIM
	-- ACTUALLY SAW, never from this server's cached copy. They are not always
	-- the same record: a host can inherit a room by reseat (see
	-- PrivateLobby.reseat) and press START on a server whose last poll predates
	-- the previous host's final settings write -- and the match would then be
	-- played on the wrong map with nothing anywhere reporting a problem.
	roomCache[code] = claimed
	launchRoom(code, expected)
end

-- Polled only for the codes this server actually holds somebody in, so a
-- server with no private lobbies in it does no work and spends no quota.
local lastRoomBeat = 0

local function tickRooms()
	local codes = heldCodes()
	if #codes == 0 then
		return
	end
	local beat = (os.clock() - lastRoomBeat) >= PrivateLobby.HEARTBEAT
	if beat then
		lastRoomBeat = os.clock()
	end

	for _, code in codes do
		local ok, rec = pcall(function()
			return privStore:GetAsync(code)
		end)
		if not ok then
			report("room read " .. code, rec)
		elseif type(rec) ~= "table" or type((rec :: any).servers) ~= "table" then
			-- THE ROOM IS GONE -- its TTL ran out, or a Studio host started it
			-- and deleted it. Say so once rather than leaving everybody
			-- staring at a panel that will never change again.
			for _, player in playersInRoom(code) do
				room[player.UserId] = nil
				pushNoRoom(player)
			end
			roomCache[code] = nil
		else
			roomCache[code] = rec
			pushRoom(code)

			if beat then
				commitRoom(code, function(r)
					local entry = PrivateLobby.entryFor(r, SERVER_ID)
					if not entry then
						-- Our entry is GONE while we still hold members: a
						-- pruning pass beat our heartbeat. Re-create it rather
						-- than leaving people believing they are in a room
						-- that has never heard of them.
						if r.state ~= "open" then
							return false
						end
						entry = { j = SERVER_ID, t = os.time(), u = {} }
						table.insert(r.servers, entry)
					end
					-- Reconcile against who is actually still here, the same
					-- way the public heartbeat does.
					local live = {}
					for userId, c in room do
						if c == code and Players:GetPlayerByUserId(userId) then
							table.insert(live, userId)
						end
					end
					local others = PrivateLobby.members(r) - #(entry :: any).u
					while #live > math.max(0, PrivateLobby.CAP - others) do
						table.remove(live)
					end
					;(entry :: any).u = live
					;(entry :: any).t = os.time()
					PrivateLobby.prune(r, os.time())
					PrivateLobby.reseat(r)
					return true
				end)
			end

			-- Somebody else's server reserved it. Send our own people after
			-- them; nobody teleports anybody else's.
			if (rec :: any).state == "ready" then
				sendRoomToMatch(rec)
			end
		end
	end
end

-- ----------------------------------------------------------- join / leave --

local function removeMember(key: string, userId: number)
	local updated: Record? = nil
	local applied = commit(key, "", function(rec)
		local entry = Matchmaker.entryFor(rec, SERVER_ID)
		if not entry then
			return false
		end
		local at = table.find(entry.u, userId)
		if not at then
			return false
		end
		table.remove(entry.u, at)
		entry.t = os.time()
		Matchmaker.prune(rec, os.time())
		-- Last one out stops the clock, so the next joiner gets a full two
		-- minutes rather than the tail of somebody else's.
		if Matchmaker.count(rec) == 0 then
			rec.deadline = 0
		end
		updated = rec
		return true
	end)
	if mine[userId] == key then
		mine[userId] = nil
	end
	-- Show it now, from the transform's own result -- see pushBoard.
	if applied and updated then
		boardCache[key] = updated
		pushBoard(true)
	end
end

local function leaveAll(userId: number)
	local key = mine[userId]
	if key then
		removeMember(key, userId)
	end
end

local function joinSlot(player: Player, key: string)
	local userId = player.UserId
	local now = os.time()
	local refusal = ""
	local okJoin = false
	local updated: Record? = nil

	local ok, err = pcall(function()
		lobbyStore:UpdateAsync(key, function(rec: any)
			okJoin = false
			refusal = ""
			updated = nil
			if type(rec) ~= "table" then
				refusal = "That lobby is not open yet."
				return nil
			end
			Matchmaker.prune(rec, now)
			-- THE CLOSING RACE. The player pressed JOIN while this lobby was
			-- being claimed. Refusing inside the transform is what makes it
			-- impossible for them to be added to a match that has already
			-- reserved its server and left without them.
			if rec.state ~= "open" then
				refusal = "That match just started -- try the next one."
				return nil
			end
			if Matchmaker.hasMember(rec, userId) then
				okJoin = true
				return nil
			end
			if Matchmaker.count(rec) >= rec.cap then
				refusal = "That lobby just filled up."
				return nil
			end
			local entry = Matchmaker.entryFor(rec, SERVER_ID)
			if not entry then
				entry = { j = SERVER_ID, t = now, u = {} }
				table.insert(rec.servers, entry)
			end
			;(entry :: Matchmaker.ServerEntry).t = now
			table.insert((entry :: Matchmaker.ServerEntry).u, userId)
			-- THE COUNTDOWN STARTS HERE, on the first join, and nowhere else.
			if rec.deadline == 0 then
				rec.deadline = now + Matchmaker.COUNTDOWN
			end
			okJoin = true
			updated = rec
			return rec
		end, Matchmaker.RECORD_TTL)
	end)

	if not ok then
		report("join " .. key, err)
		toast(player, "The matchmaker is unreachable right now.")
		return
	end
	if okJoin then
		mine[userId] = key
		-- Straight out to every client, without waiting for the poll. This is
		-- the whole difference between a card that answers the press and one
		-- that sits there looking broken.
		if updated then
			boardCache[key] = updated
			pushBoard(true)
		end
	elseif refusal ~= "" then
		toast(player, refusal)
	end
end

LobbyIntentRE.OnServerEvent:Connect(function(player, action, key)
	if typeof(action) ~= "string" then
		return
	end
	local userId = player.UserId
	-- One in flight per player. Both paths yield on MemoryStore, and a player
	-- mashing JOIN could otherwise have two transforms racing to add the same
	-- id twice.
	if busy[userId] then
		return
	end
	-- ...and a COOLDOWN on top of that, because `busy` only serialises: every
	-- join and leave is a MemoryStore WRITE, and the universe's whole budget is
	-- 1000 + 100 x CCU per MINUTE. One bored player alternating JOIN and LEAVE
	-- as fast as the round trip allows is a few writes a second on its own;
	-- sixty of them would take the board down for everybody.
	local now = os.clock()
	if (cooldown[userId] or 0) > now - INTENT_COOLDOWN then
		return
	end
	cooldown[userId] = now
	busy[userId] = true
	task.spawn(function()
		local ok = pcall(function()
			-- ---------------------------------------- private lobbies --
			-- These share the busy guard and the one-a-second cooldown with
			-- the public board's intents, because they are the same kind of
			-- thing: every one of them is a MemoryStore write.
			if action == "create" then
				-- A PRIVATE ROOM AND A PUBLIC SLOT ARE EXCLUSIVE, and this is
				-- not tidiness: they are two independent things that can each
				-- teleport you, so being in both means whichever fires first
				-- decides which game you were in and the other one launches
				-- without you.
				leaveAll(userId)
				createRoom(player, key)
				return
			elseif action == "pjoin" then
				local code = PrivateLobby.normalise(key)
				if not code then
					toast(player, "A lobby code is four digits.")
					return
				end
				leaveAll(userId)
				joinRoom(player, code)
				return
			elseif action == "pleave" then
				leaveRoom(player)
				return
			elseif action == "pset" then
				setRoom(player, key)
				return
			elseif action == "pstart" then
				startRoom(player)
				return
			end

			if action == "join" then
				if typeof(key) ~= "string" then
					return
				end
				local slot
				for _, s in Matchmaker.SLOTS do
					if s.key == key then
						slot = s
					end
				end
				if not slot then
					return
				end
				-- A player is in at most one lobby. Leaving first also means
				-- the count they just left is correct before they appear in
				-- the new one.
				if mine[userId] and mine[userId] ~= key then
					removeMember(mine[userId] :: string, userId)
				end
				-- ...and out of any private room, for the reason above.
				if room[userId] then
					leaveRoom(player)
				end
				joinSlot(player, key)
			elseif action == "leave" then
				leaveAll(userId)
			elseif action == "start" then
				-- /start -- skip the countdown on the lobby you are in. It does
				-- NOT start anything itself: it drags the deadline into the
				-- past and lets the ordinary launch path notice, so there is no
				-- second route into a match that could drift from the first.
				--
				-- GATED, because on a live server this would otherwise let any
				-- player cut short everybody else's two minutes. Studio is open
				-- season; a real server allows only the owner.
				local allowed = RunService:IsStudio()
					or (game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId)
				if not allowed then
					toast(player, "/start is for the owner only.")
					return
				end
				local key = mine[userId]
				if not key then
					toast(player, "Join a lobby first, then /start it.")
					return
				end
				local started: Record? = nil
				local pulled = commit(key, "", function(rec)
					if rec.state ~= "open" then
						return false
					end
					rec.deadline = os.time() - 1
					started = rec
					return true
				end)
				-- Forced, because `signature` ignores the countdown and this
				-- changes nothing else -- without it the shortcut would not
				-- show up until something unrelated moved.
				if pulled and started then
					boardCache[key] = started
					pushBoard(true)
				end
				toast(player, pulled and "Starting that lobby now." or "That lobby is already starting.")
			end
		end)
		if not ok then
			toast(player, "Something went wrong -- try again.")
		end
		busy[userId] = false
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	local userId = player.UserId
	local key = mine[userId]
	local code = room[userId]
	mine[userId] = nil
	room[userId] = nil
	busy[userId] = nil
	if key then
		task.spawn(removeMember, key, userId)
	end
	-- Quitting the game and pressing LEAVE are the same event to the record,
	-- and the seat has to pass on either one.
	if code then
		task.spawn(dropMember, code, userId)
	end
end)

-- -------------------------------------------------------------- teleport ---

-- The lobby generation this server has already sent its players to. A SINGLE
-- string, not a set: a set keyed by generation is only ever appended to, so it
-- grows by one entry per launched lobby for the life of the server, and the
-- only generation that can matter is the one the tick is looking at right now.
local teleportedGeneration = ""

local function myPlayersIn(key: string): { Player }
	local list = {}
	for userId, slotKey in mine do
		if slotKey == key then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(list, player)
			end
		end
	end
	return list
end

local function sendToMatch(rec: Record)
	local key = Matchmaker.SLOTS[rec.slot].key
	if teleportedGeneration == rec.id then
		return
	end
	local list = myPlayersIn(key)
	if #list == 0 then
		return
	end
	teleportedGeneration = rec.id

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = rec.code
	-- Carried for convenience only. The match server reads its map and mode
	-- from the match record keyed by PrivateServerId, NOT from this -- teleport
	-- data belongs to whichever client arrives first, which is not a thing the
	-- round should depend on.
	options:SetTeleportData({ slot = rec.slot, map = rec.map, mode = rec.mode, id = rec.id })

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, list, options)
	end)
	if not ok then
		-- One retry, then give up and put them back on the page. The match
		-- still runs for everyone whose server managed it.
		task.wait(1)
		-- Re-take the list: anyone who left during that second is not ours to
		-- send any more, and TeleportAsync throws on a player who is not in
		-- this server -- which would fail the retry for EVERYONE in the batch,
		-- not just for the one who quit.
		list = myPlayersIn(key)
		if #list == 0 then
			teleportedGeneration = ""
			return
		end
		ok = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, list, options)
		end)
	end
	if ok then
		for _, player in list do
			mine[player.UserId] = nil
		end
		commit(key, rec.id, function(r)
			local entry = Matchmaker.entryFor(r, SERVER_ID)
			if not entry then
				return false
			end
			entry.u = {}
			entry.t = os.time()
			return true
		end)
	else
		teleportedGeneration = ""
		warn("[Matchmaker] teleport failed: " .. tostring(err))
		for _, player in list do
			mine[player.UserId] = nil
			toast(player, "Could not join that match. Pick another.")
		end
	end
end

TeleportService.TeleportInitFailed:Connect(function(player, result, message)
	warn("[Matchmaker] TeleportInitFailed " .. tostring(result) .. ": " .. tostring(message))
	if player and player.Parent then
		mine[player.UserId] = nil
		toast(player, "Could not join that match. Pick another.")
	end
end)

-- ---------------------------------------------------------------- launch ---

-- STUDIO HAS NO RESERVED SERVERS, so a Studio lobby starts the round in the
-- session it is already in: it flips the role attribute, which both
-- ConquestServer and ConquestClient are waiting on. That is what makes the
-- whole page testable in Studio -- join a card, watch the clock run out, and
-- the game begins -- with only the teleport itself left for a live test.
local function startLocally(rec: Record)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MAP_ATTR, rec.map)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MODE_ATTR, rec.mode)
	ReplicatedStorage:SetAttribute(Matchmaker.ROLE_ATTR, "match")
	-- Hand the slot back OPEN. This session stops polling the moment the role
	-- flips, so without a reset the record sits in "claim" for its whole
	-- 15-minute TTL and the next Studio playtest finds that card unjoinable --
	-- every join refused with "that match just started".
	local key = Matchmaker.SLOTS[rec.slot].key
	commit(key, rec.id, function(r)
		local fresh = Matchmaker.newRecord(r.slot, nil)
		for k, v in fresh do
			(r :: any)[k] = v
		end
		return true
	end)
	print(
		string.format(
			"[Matchmaker] STUDIO: no reserved servers here, so %s (%s / %s) starts in this session.",
			Matchmaker.SLOTS[rec.slot].name,
			rec.map,
			rec.mode
		)
	)
end

local function launch(rec: Record, key: string, expected: number)
	local ok, code, psid = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)

	if not ok then
		if RunService:IsStudio() then
			startLocally(rec)
			return
		end
		warn("[Matchmaker] ReserveServer failed: " .. tostring(code))
		-- Hand the slot back so another server can try, rather than leaving it
		-- claimed until the stale-steal timer notices.
		commit(key, rec.id, function(r)
			if r.state ~= "claim" then
				return false
			end
			r.state = "open"
			r.host = ""
			r.claimedAt = 0
			return true
		end)
		return
	end

	local wrote = pcall(function()
		matchStore:SetAsync(psid, {
			map = rec.map,
			mode = rec.mode,
			cap = rec.cap,
			slot = rec.slot,
			id = rec.id,
			expected = expected,
		}, Matchmaker.MATCH_TTL)
	end)
	if not wrote then
		-- Not fatal: the match server falls back to its own rotation, and a
		-- round on the wrong map beats no round at all.
		warn("[Matchmaker] could not publish the match record; that server will pick its own map.")
	end

	local now = os.time()
	local published = commit(key, rec.id, function(r)
		if r.state ~= "claim" then
			return false
		end
		r.state = "ready"
		r.code = code
		r.psid = psid
		r.readyAt = now
		return true
	end)
	if published then
		rec.state = "ready"
		rec.code = code
		rec.psid = psid
		rec.readyAt = now
		print(
			string.format(
				"[Matchmaker] launching %s -- %s / %s, %d players",
				Matchmaker.SLOTS[rec.slot].name,
				rec.map,
				rec.mode,
				expected
			)
		)
		sendToMatch(rec)
	end
end

-- Returns whether we won the claim AND how many players the record actually
-- held at the moment we won it. The second value matters: it is what the match
-- server waits for, and the caller's copy of the record is up to a second old
-- and has not been pruned, so counting it there can promise arrivals that were
-- ghosts -- and every real player then stares at PREPARING THE MAP for the
-- whole 25-second grace waiting for somebody who does not exist.
local function tryClaim(rec: Record, key: string, now: number): (boolean, number)
	local won = false
	local claimed = 0
	local ok, err = pcall(function()
		lobbyStore:UpdateAsync(key, function(r: any)
			won = false
			if type(r) ~= "table" or r.id ~= rec.id then
				return nil
			end
			Matchmaker.prune(r, now)
			-- THE STALE-CLAIM STEAL. A host that crashed between claiming and
			-- publishing leaves the slot in "claim" forever, and its players
			-- would sit watching a dead clock. After CLAIM_STALE anybody may
			-- take it over.
			local stale = r.state == "claim" and (now - (r.claimedAt or 0)) > Matchmaker.CLAIM_STALE
			if r.state ~= "open" and not stale then
				return nil
			end
			if not Matchmaker.shouldLaunch(r, now) then
				return nil
			end
			r.state = "claim"
			r.host = SERVER_ID
			r.claimedAt = now
			won = true
			claimed = Matchmaker.count(r)
			return r
		end, Matchmaker.RECORD_TTL)
	end)
	if not ok then
		report("claim " .. key, err)
		return false, 0
	end
	return won, claimed
end

-- ------------------------------------------------------------------ tick ---

local lastBeat = 0

-- A joiner must not wait up to PUSH seconds for an idle board to be pushed
-- again, so they get the last one immediately and the periodic push stays rare.
Players.PlayerAdded:Connect(function(player)
	if lastWire then
		task.defer(function()
			LobbyRE:FireClient(player, "board", lastWire)
		end)
	end
end)

local function tick()
	local now = os.time()
	local board = readBoard()
	for i in Matchmaker.SLOTS do
		ensureSlot(i, board)
	end

	-- 1. Show it. The press paths have usually pushed this already; this is
	--    the catch-up for everything a press here did NOT cause -- another
	--    server's joins, a prune, a slot resetting between rounds.
	boardCache = board
	pushBoard(false)

	-- 2. Heartbeat + prune, but only for slots we actually hold people in.
	local beat = (os.clock() - lastBeat) >= Matchmaker.HEARTBEAT
	if beat then
		lastBeat = os.clock()
	end

	for _, slot in Matchmaker.SLOTS do
		local rec = board[slot.key]
		if rec then
			local held = #myPlayersIn(slot.key) > 0

			if beat and held then
				commit(slot.key, rec.id, function(r)
					local entry = Matchmaker.entryFor(r, SERVER_ID)
					if not entry then
						-- Our entry is GONE while we still hold members: a
						-- pruning pass beat our heartbeat, or a join landed
						-- while another server's stale copy of us was being
						-- swept. Re-create it rather than leaving the player
						-- believing they are queued for a lobby that has never
						-- heard of them.
						if r.state ~= "open" then
							return false
						end
						entry = { j = SERVER_ID, t = os.time(), u = {} }
						table.insert(r.servers, entry)
					end
					-- Reconcile against who is actually still here. A player
					-- who left the SERVER is removed by PlayerRemoving, but a
					-- crash-and-restart of this script would not be, so the
					-- heartbeat rewrites the list from the truth.
					local live = {}
					for userId, k in mine do
						if k == slot.key and Players:GetPlayerByUserId(userId) then
							table.insert(live, userId)
						end
					end
					-- Never let a re-created entry push the lobby over its cap.
					local others = Matchmaker.count(r) - #(entry :: Matchmaker.ServerEntry).u
					while #live > math.max(0, r.cap - others) do
						table.remove(live)
					end
					;(entry :: Matchmaker.ServerEntry).u = live
					;(entry :: Matchmaker.ServerEntry).t = os.time()
					Matchmaker.prune(r, os.time())
					return true
				end)
			end

			-- Housekeeping, and it is not cosmetic. Pruning only ever ran
			-- inside a write, and a slot whose members ALL belonged to servers
			-- that have since died gets no writes at all -- so the ghosts would
			-- sit there for the record's whole 15-minute TTL, and once its
			-- deadline passed every server would retry a claim it can never win
			-- (the transform prunes, the count drops to zero, shouldLaunch goes
			-- false, the update cancels, nothing is saved, repeat next second).
			-- Prune the local copy first, which is free, and only write when
			-- there is genuinely something to clean.
			if Matchmaker.prune(rec, now) then
				commit(slot.key, rec.id, function(r)
					return Matchmaker.prune(r, os.time())
				end)
			end

			if rec.state == "open" or rec.state == "claim" then
				if Matchmaker.shouldLaunch(rec, now) then
					local won, claimed = tryClaim(rec, slot.key, now)
					if won then
						rec.state = "claim"
						launch(rec, slot.key, claimed)
					end
				end
			elseif rec.state == "ready" then
				-- Somebody else reserved it. Send our own people after them.
				if held and rec.code ~= "" then
					sendToMatch(rec)
				end
				-- ...and once the window has passed, whoever is still looking
				-- resets the slot so the page has three open lobbies again.
				if (now - (rec.readyAt or 0)) > Matchmaker.READY_HOLD then
					local elsewhere = shownElsewhere(board, slot.key)
					commit(slot.key, rec.id, function(r)
						if r.state ~= "ready" then
							return false
						end
						local fresh = Matchmaker.newRecord(r.slot, elsewhere)
						for k, v in fresh do
							(r :: any)[k] = v
						end
						return true
					end)
				end
			end
		end
	end
end

task.spawn(function()
	while true do
		task.wait(Matchmaker.POLL)
		-- STOP once this session stops being a lobby. Only Studio can get here
		-- (`startLocally` flips the role in place), and without the break this
		-- server would keep polling the board all through the match it just
		-- started -- and could claim a SECOND lobby that nothing would ever run.
		if ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) ~= "lobby" then
			print("[Matchmaker] this session is a match now -- lobby polling stopped.")
			break
		end
		-- An empty server costs the universe's MemoryStore quota nothing.
		if #Players:GetPlayers() > 0 then
			local ok, err = pcall(tick)
			if not ok then
				warn("[Matchmaker] tick error: " .. tostring(err))
			end
			-- Separate pcall: a private room that throws must not take the
			-- public board's poll down with it, and vice versa.
			local okRoom, errRoom = pcall(tickRooms)
			if not okRoom then
				warn("[Matchmaker] room tick error: " .. tostring(errRoom))
			end
		end
	end
end)

print("[Matchmaker] lobby server ready (" .. SERVER_ID .. ")")
