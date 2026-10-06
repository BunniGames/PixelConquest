--!strict
-- Conquest :: RankedLobby  (server, lobby side)
--
-- Parties, the ranked queue and the launch. The pure rules (ladder, rating,
-- the team-forming search) are Conquest.Ranked; the match server's half is
-- RankedMatch. Nothing here touches MatchmakerServer's board: a ranked match
-- is reserved and recorded the same way a public card's is (MATCH_STORE keyed
-- by PrivateServerId), so ConquestServer.bootMatch boots it unchanged.
--
-- PARTIES are per lobby server: a leader invites players in the same server
-- (friends come over with Roblox's own join / the panel's INVITE button),
-- up to Ranked.MAX_PARTY. Only the leader queues. A party queues as ONE entry
-- and is never split across sides.
--
-- THE QUEUE is cross-server: one MemoryStore sorted map per queue size, every
-- lobby server with somebody queued polls it. The server that owns the OLDEST
-- party in a candidate match drives it:
--   1. formMatch picks parties (Ranked.formMatch)
--   2. CLAIM each entry (open -> claim, by this server) -- any refusal rolls
--      the claimed ones back to open and the attempt is dropped
--   3. ReserveServer + write the match record
--   4. mark every entry GO with the access code and the sides
-- Each owning server sees GO on its own entries in its heartbeat and teleports
-- its own players. A claim nobody finished goes back to open after CLAIM_STALE.
--
-- STUDIO has no reserved servers and one player: the queue is an in-memory
-- table, a lone queuer is matched against GHOST seats (faux AI empires on the
-- other side, RankedMatch.ghosts) after STUDIO_GHOST_AFTER, and the round
-- starts in this session through the same attributes MatchmakerServer's
-- startLocally uses.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local TeleportService = game:GetService("TeleportService")
local MessagingService = game:GetService("MessagingService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Ranked = require(Shared.Ranked)
local Matchmaker = require(Shared.Matchmaker)
local Data = require(script.Parent:WaitForChild("ConquestData"))
local okA, Analytics = pcall(function()
	return require(script.Parent:WaitForChild("ConquestAnalytics", 5) :: any)
end)
if not okA then
	Analytics = nil
end

-- Lobby servers only. In Studio the role starts "lobby" and flips to "match"
-- when a round starts in-session; this script just stops mattering then.
while ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) == nil do
	ReplicatedStorage:GetAttributeChangedSignal(Matchmaker.ROLE_ATTR):Wait()
end
if ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) ~= "lobby" then
	return
end

local IS_STUDIO = RunService:IsStudio()
local SERVER = game.JobId ~= "" and game.JobId or ("studio-" .. tostring(math.random(1, 1e9)))

local STORE_PREFIX = "ConquestRankedQ_v1_"
local ENTRY_TTL = 60 -- seconds; refreshed by the owner's heartbeat
local HEARTBEAT = 2
local MATCH_TICK = 3
local FRESH = 15 -- an entry whose heartbeat is older than this is ignored
local CLAIM_STALE = 20
local INVITE_TTL = 60
-- FRIEND INVITES ACROSS SERVERS (2026-10-05, owner: no Roblox invite sheet;
-- list the friends who are in the game and invite them directly). The client
-- finds them (Player:GetFriendsOnlineAsync -- its own web call, nothing shared);
-- an invite to a friend on another server is ONE MessagingService message,
-- delivered by whichever lobby server holds them. Accepting teleports them
-- into the leader's server, where they join the party on arrival.
local INVITE_TOPIC = "ConquestRankedInvite_v1"
local REMOTE_INVITES_PER_MIN = 20
local STUDIO_GHOST_AFTER = 4
local SEND_TIMEOUT = 30
local ARRIVAL_GRACE = 30 -- match server waits this long for everyone
-- For this long after queueing, a party defers to an OLDER compatible party on
-- another server (it will probably build the match). After it, everyone
-- drives; two servers racing for the same parties is settled by the claims.
local DEFER = 8

-- ================================================================ remotes ==

local folder = ReplicatedStorage:FindFirstChild("ConquestRanked") or Instance.new("Folder")
folder.Name = "ConquestRanked"
folder.Parent = ReplicatedStorage
local RE = folder:FindFirstChild("Ranked") :: RemoteEvent? or Instance.new("RemoteEvent")
;(RE :: RemoteEvent).Name = "Ranked"
;(RE :: RemoteEvent).Parent = folder
local RankedRE = RE :: RemoteEvent

-- ============================================================ queue store ==
-- One interface, two backends: MemoryStore in a live game, a table in Studio
-- (Studio's MemoryStore is its own sandbox anyway, and a table needs no quota).

type Entry = {
	u: { number },
	n: number,
	r: number,
	t: number,
	h: number,
	j: string,
	s: string, -- "open" | "claim" | "go"
	by: string?,
	ct: number?,
	code: string?,
	map: string?,
	side: { [string]: number }?,
	rs: { [string]: number }?,
	ghost: boolean?,
	size: number?,
	rs: { [string]: number }?, -- each member's MMR, so a far server rates them exactly
}

type Store = {
	range: (self: Store) -> { { key: string, value: Entry } },
	-- (new value or nil, ok). `ok` false = the CALL failed (throttled, down),
	-- which must never be read as "the key is gone" (prod review 2026-10-05).
	update: (self: Store, key: string, fn: (Entry?) -> Entry?) -> (Entry?, boolean),
	remove: (self: Store, key: string) -> (),
}

local localQueues: { [string]: { [string]: Entry } } = {}

local function localStore(qid: string): Store
	local t = localQueues[qid] or {}
	localQueues[qid] = t
	local s = {}
	function s.range(_self)
		local out = {}
		for k, v in t do
			table.insert(out, { key = k, value = v })
		end
		return out
	end
	function s.update(_self, key, fn)
		local nv = fn(t[key] and table.clone(t[key]) or nil)
		if nv ~= nil then
			t[key] = nv
		end
		return nv, true
	end
	function s.remove(_self, key)
		t[key] = nil
	end
	return (s :: any) :: Store
end

local function memoryStore(qid: string): Store
	local map = MemoryStoreService:GetSortedMap(STORE_PREFIX .. qid)
	local s = {}
	function s.range(_self)
		local ok, items = pcall(function()
			return map:GetRangeAsync(Enum.SortDirection.Ascending, 200)
		end)
		return ok and items or {}
	end
	function s.update(_self, key, fn)
		local result: Entry? = nil
		local ok, err = pcall(function()
			map:UpdateAsync(key, function(old)
				result = fn(old)
				return result
			end, ENTRY_TTL)
		end)
		if not ok then
			warn("[Ranked] queue update failed: " .. tostring(err))
			return nil, false
		end
		return result, true
	end
	function s.remove(_self, key)
		pcall(function()
			map:RemoveAsync(key)
		end)
	end
	return (s :: any) :: Store
end

local stores: { [string]: Store } = {}
for _, q in Ranked.QUEUES do
	stores[q.id] = if IS_STUDIO then localStore(q.id) else memoryStore(q.id)
end

-- ================================================================ parties ==

type Party = {
	leader: number,
	members: { number },
	queue: string?,
	key: string?,
	since: number,
	sending: boolean,
	beating: boolean?,
}

local parties: { [number]: Party } = {} -- by leader
local partyOf: { [number]: number } = {} -- member -> leader
-- target -> from -> invite. `job` is set on an invite from ANOTHER server:
-- the leader's lobby JobId, which accepting teleports to.
type Invite = { t: number, name: string, job: string? }
local invites: { [number]: { [number]: Invite } } = {}
local remoteSent: { [number]: { number } } = {} -- inviter -> recent send times
-- invitee -> the cross-server invite THIS server sent them (joinOnArrival).
local sentInvites: { [number]: { from: number, t: number } } = {}

local function blockOf(player: Player): any?
	local profile = Data.get(player)
	return profile and Ranked.ensure(profile) or nil
end

local function publish(player: Player)
	local b = blockOf(player)
	if b then
		player:SetAttribute(Ranked.RANK_ATTR, b.rank)
		player:SetAttribute(Ranked.RANK_ID_ATTR, Ranked.rung(b.rank).id)
		player:SetAttribute(Ranked.RATING_ATTR, math.floor(b.rating))
		player:SetAttribute(Ranked.RR_ATTR, b.rr)
	end
end

local function partyFor(uid: number): Party
	local leader = partyOf[uid]
	if leader and parties[leader] then
		return parties[leader]
	end
	local p: Party = { leader = uid, members = { uid }, queue = nil, key = nil, since = 0, sending = false }
	parties[uid] = p
	partyOf[uid] = uid
	return p
end

local function avgRating(p: Party): number
	local sum, n = 0, 0
	for _, uid in p.members do
		local plr = Players:GetPlayerByUserId(uid)
		local b = plr and blockOf(plr)
		sum += b and b.rating or Ranked.START
		n += 1
	end
	return n > 0 and sum / n or Ranked.START
end

local function memberView(uid: number)
	local plr = Players:GetPlayerByUserId(uid)
	local b = plr and blockOf(plr)
	return {
		id = uid,
		name = plr and plr.DisplayName or "?",
		rank = b and b.rank or 1,
		rating = b and math.floor(b.rating) or Ranked.START,
		rr = b and b.rr or 0,
	}
end

local function push(player: Player)
	local b = blockOf(player)
	local p = partyFor(player.UserId)
	local members = {}
	for _, uid in p.members do
		table.insert(members, memberView(uid))
	end
	local pending = {}
	for from, inv in invites[player.UserId] or {} do
		local here = Players:GetPlayerByUserId(from) ~= nil
		if (here or inv.job) and os.time() - inv.t < INVITE_TTL then
			table.insert(pending, { id = from, name = inv.name })
		end
	end
	RankedRE:FireClient(player, "state", {
		me = b and Ranked.view(b) or nil,
		leader = p.leader,
		members = members,
		queue = p.queue,
		since = p.since,
		invites = pending,
	})
end

local function pushParty(p: Party)
	for _, uid in p.members do
		local plr = Players:GetPlayerByUserId(uid)
		if plr then
			push(plr)
		end
	end
end

local function toast(player: Player, msg: string)
	RankedRE:FireClient(player, "toast", msg)
end

-- ================================================================== queue ==

local function leaveQueue(p: Party, why: string?)
	if p.queue and p.key then
		local store = stores[p.queue]
		local key = p.key
		task.spawn(function()
			-- Never pull an entry another server has already sent to a match:
			-- the rest of that match is on its way and the match server sorts
			-- out who did not arrive.
			local wasGo = false
			store:update(key, function(old)
				wasGo = old ~= nil and old.s == "go"
				return nil
			end)
			if not wasGo then
				store:remove(key)
			end
		end)
	end
	p.queue, p.key, p.since = nil, nil, 0
	if why then
		for _, uid in p.members do
			local plr = Players:GetPlayerByUserId(uid)
			if plr then
				toast(plr, why)
			end
		end
	end
end

-- Writes (or re-writes, same key) this party's queue entry.
local function writeEntry(p: Party)
	local qid, key = p.queue, p.key
	if not qid or not key then
		return
	end
	local rs: { [string]: number } = {}
	for _, uid in p.members do
		local plr = Players:GetPlayerByUserId(uid)
		local b = plr and blockOf(plr)
		rs[tostring(uid)] = b and math.floor(b.rating) or Ranked.START
	end
	local now = os.time()
	local entry: Entry = {
		u = table.clone(p.members),
		n = #p.members,
		r = avgRating(p),
		rs = rs,
		t = p.since,
		h = now,
		j = SERVER,
		s = "open",
	}
	task.spawn(function()
		stores[qid]:update(key, function()
			return entry
		end)
	end)
end

local function enterQueue(p: Party, qid: string)
	local q = Ranked.queue(qid)
	if not q then
		return
	end
	local now = os.time()
	p.queue = q.id
	p.since = now
	-- TIME FIRST, so the sorted map lists the OLDEST parties first and a
	-- GetRangeAsync page always holds the ones that should drive (keys sort as
	-- strings; userId-first sorted by user and could hide a party past 200).
	p.key = string.format("%010d_%d", now, p.leader)
	writeEntry(p)
end

-- ============================================================= membership ==

local function removeMember(uid: number)
	local leader = partyOf[uid]
	local p = leader and parties[leader]
	partyOf[uid] = nil
	if not p then
		return
	end
	leaveQueue(p, if p.queue then "A party member left, so the queue was cancelled." else nil)
	local i = table.find(p.members, uid)
	if i then
		table.remove(p.members, i)
	end
	parties[p.leader] = nil
	if #p.members > 0 then
		-- The longest-standing member leads.
		p.leader = p.members[1]
		parties[p.leader] = p
		for _, m in p.members do
			partyOf[m] = p.leader
		end
		pushParty(p)
	end
end

-- ================================================================= launch ==

local function teleportParty(p: Party, entry: Entry)
	if p.sending then
		return
	end
	p.sending = true
	local list = {}
	for _, uid in p.members do
		local plr = Players:GetPlayerByUserId(uid)
		if plr then
			table.insert(list, plr)
		end
	end
	for _, plr in list do
		RankedRE:FireClient(plr, "found", { map = entry.map, queue = p.queue, size = entry.size })
	end
	if #list == 0 then
		p.sending = false
		p.queue, p.key, p.since = nil, nil, 0
		return
	end
	-- A teleport that fails LATER (TeleportInitFailed, below) or never lands
	-- must not leave the party flagged as sending forever (prod review).
	task.delay(SEND_TIMEOUT, function()
		if p.sending then
			for _, uid in p.members do
				if Players:GetPlayerByUserId(uid) then
					p.sending = false
					pushParty(p)
					break
				end
			end
		end
	end)
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = entry.code :: string
	options:SetTeleportData({
		ranked = true,
		cq = Analytics and (Analytics :: any).teleportData(list) or nil,
	})
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, list, options)
	end)
	if not ok then
		task.wait(1)
		ok, err = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, list, options)
		end)
	end
	if not ok then
		warn("[Ranked] teleport failed: " .. tostring(err))
		p.sending = false
		for _, plr in list do
			toast(plr, "Could not reach the match. Queue again.")
		end
	end
	p.queue, p.key, p.since = nil, nil, 0
end

-- STUDIO: start the round right here, the way MatchmakerServer.startLocally
-- does for a board card.
local function startLocally(q: Ranked.Queue, map: string, sides: { [string]: number }, rs: { [string]: number }, ghosts: number, size: number)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MAP_ATTR, map)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MODE_ATTR, Ranked.MODE)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TEAMS_ATTR, 2)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_PHANTOMS_ATTR, 0)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TUTORIAL_ATTR, false)
	ReplicatedStorage:SetAttribute(Ranked.STUDIO_ATTR, HttpService:JSONEncode({
		q = q.id,
		size = size,
		side = sides,
		r = rs,
		ghosts = ghosts > 0,
	}))
	print(("[Ranked] STUDIO: %s on %s starts in this session (%d ghost seats)"):format(q.id, map, ghosts))
	ReplicatedStorage:SetAttribute(Matchmaker.ROLE_ATTR, "match")
end

local matchStore = MemoryStoreService:GetHashMap(Matchmaker.MATCH_STORE)

-- Drives one match attempt for `p` (owned here). Returns true if it launched.
-- ONE READ PER QUEUE PER TICK. GetRangeAsync costs a request unit per item
-- returned, and a sorted map is one partition (~30k units/min before it
-- throttles), so every queued party reading the whole queue every tick grew
-- with the SQUARE of the queue. The match loop hands each tick a fresh cache;
-- every party on this server shares its reads.
type RangeCache = { [string]: { any } }
local function rangeOf(cache: RangeCache, qid: string): { any }
	local hit = cache[qid]
	if hit == nil then
		hit = stores[qid]:range()
		cache[qid] = hit
	end
	return hit
end

local function tryMatch(p: Party, cache: RangeCache): boolean
	local qid = p.queue
	local key = p.key
	if not qid or not key then
		return false
	end
	local q = Ranked.queue(qid) :: Ranked.Queue
	local store = stores[qid]
	local now = os.time()
	local items = rangeOf(cache, qid)

	local byKey: { [string]: Entry } = {}
	-- Which queue's store each candidate lives in: a loosened 4v4 can pull
	-- entries from the 2v2 queue, and every claim must go to the right map.
	local storeOf: { [string]: Store } = {}
	local function collect(fromQ: string, list: { any }, maxN: number?): { Ranked.Party }
		local out: { Ranked.Party } = {}
		for _, it in list do
			local e = it.value
			if type(e) == "table" and (maxN == nil or e.n <= maxN) then
				local stale = (e.s == "claim" and now - (e.ct or 0) > CLAIM_STALE)
				if (e.s == "open" or stale) and now - (e.h or 0) <= FRESH then
					byKey[it.key] = e
					storeOf[it.key] = stores[fromQ]
					table.insert(out, { key = it.key, n = e.n, r = e.r, t = e.t })
				end
			end
		end
		return out
	end
	local open = collect(qid, items)
	local anchor: Ranked.Party? = nil
	for _, o in open do
		if o.key == key then
			anchor = o
		end
	end
	if not anchor then
		return false
	end
	-- Past RELAX_AFTER, the extra pools a loosened match may draw on.
	local relaxed = Ranked.RELAX[qid] ~= nil and now - anchor.t >= Ranked.RELAX_AFTER
	local pulled: { [string]: { Ranked.Party } } = {}
	if relaxed then
		for _, step in Ranked.RELAX[qid] do
			if step.pull and stores[step.pull] and not pulled[step.pull] then
				pulled[step.pull] = collect(step.pull, rangeOf(cache, step.pull), step.size)
			end
		end
	end

	-- HOW CLOSE (owner, 2026-10-05: "show a X/4 or X/8 ... so players can see
	-- how close they are to finding a match"). Players in this queue, on any
	-- server, near enough in MMR to be matched with this party right now, you
	-- included. Capped one short of full: a full count that still cannot form
	-- sides (party sizes that do not split) would read as stuck, and the
	-- moment it really is full the "found" message replaces it.
	-- Loosened (4v4 past RELAX_AFTER): the smallest match it will now take is
	-- the target, and the pulled queue's players count toward it.
	do
		local need = q.size * 2
		local pool = open
		if relaxed then
			local steps = Ranked.RELAX[qid]
			need = steps[#steps].size * 2
			pool = table.clone(open)
			for _, list in pulled do
				for _, o in list do
					table.insert(pool, o)
				end
			end
		end
		local count = 0
		for _, o in pool do
			if o.n <= q.size and math.abs(o.r - anchor.r) <= math.max(Ranked.window(now - anchor.t), Ranked.window(now - o.t)) then
				count += o.n
			end
		end
		local shown = math.clamp(count, #p.members, need - 1)
		for _, uid in p.members do
			local plr = Players:GetPlayerByUserId(uid)
			if plr then
				RankedRE:FireClient(plr, "searching", { queue = qid, count = shown, need = need })
			end
		end
	end

	-- Only the OLDEST open party drives, so two servers do not both try to
	-- build the same match every tick.
	for _, o in open do
		if now - anchor.t < DEFER and o.t < anchor.t and byKey[o.key] and byKey[o.key].j ~= SERVER then
			-- An older party elsewhere can drive -- unless it is far away in
			-- rating, in which case it would not pick us anyway.
			if math.abs(o.r - anchor.r) <= Ranked.window(now - o.t) then
				return false
			end
		end
	end

	local size = q.size
	local sideA, sideB = Ranked.formMatch(anchor, open, size, now)
	-- LOOSENED: smaller sides, in RELAX order, until one forms.
	if not sideA and relaxed then
		for _, step in Ranked.RELAX[qid] do
			local pool = open
			if step.pull and pulled[step.pull] then
				pool = table.clone(open)
				for _, o in pulled[step.pull] do
					table.insert(pool, o)
				end
			end
			sideA, sideB = Ranked.formMatch(anchor, pool, step.size, now)
			if sideA then
				size = step.size
				break
			end
		end
	end

	-- STUDIO GHOSTS: alone in Studio for a few seconds, fight AI seats.
	local ghosts = 0
	if not sideA and IS_STUDIO and now - anchor.t >= STUDIO_GHOST_AFTER then
		sideA, sideB = { anchor.key }, {}
		ghosts = q.size * 2 - anchor.n
	end
	if not sideA or not sideB then
		return false
	end

	-- 2. CLAIM every entry.
	local claimed: { string } = {}
	local all = table.clone(sideA)
	for _, k in sideB do
		table.insert(all, k)
	end
	-- One global order, so two servers racing for overlapping parties cannot
	-- each hold half and roll back forever.
	table.sort(all)
	local okAll = true
	for _, k in all do
		local got = (storeOf[k] or store):update(k, function(old)
			if old == nil then
				return nil
			end
			local stale = old.s == "claim" and now - (old.ct or 0) > CLAIM_STALE
			if old.s ~= "open" and not stale then
				return nil
			end
			old.s = "claim"
			old.by = SERVER
			old.ct = now
			return old
		end)
		if got and got.by == SERVER and got.s == "claim" then
			table.insert(claimed, k)
		else
			okAll = false
			break
		end
	end
	local function rollback()
		for _, k in claimed do
			(storeOf[k] or store):update(k, function(old)
				if old and old.s == "claim" and old.by == SERVER then
					old.s = "open"
					old.by = nil
					return old
				end
				return nil
			end)
		end
	end
	if not okAll then
		rollback()
		return false
	end

	-- Sides and ratings, keyed by user id STRING (JSON).
	local sides: { [string]: number } = {}
	local rs: { [string]: number } = {}
	local count = 0
	for s, keys in { sideA, sideB } do
		for _, k in keys do
			local e = byKey[k]
			for _, uid in e.u do
				sides[tostring(uid)] = s
				rs[tostring(uid)] = math.floor((e.rs and e.rs[tostring(uid)]) or e.r)
				count += 1
			end
		end
	end
	-- Per-player ratings where this server knows them (its own players);
	-- other servers' players are matched on their party's average.
	for uidStr in sides do
		local plr = Players:GetPlayerByUserId(tonumber(uidStr) :: number)
		local b = plr and blockOf(plr)
		if b then
			rs[uidStr] = math.floor(b.rating)
		end
	end
	local maps = Ranked.mapsFor(size)
	local map = maps[math.random(1, #maps)]

	-- 3. RESERVE.
	local okR, code, psid = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not okR then
		if IS_STUDIO then
			for _, k in claimed do
				(storeOf[k] or store):remove(k)
			end
			p.queue, p.key, p.since = nil, nil, 0
			for _, uid in p.members do
				local plr = Players:GetPlayerByUserId(uid)
				if plr then
					RankedRE:FireClient(plr, "found", { map = map, queue = q.id, size = size })
				end
			end
			startLocally(q, map, sides, rs, ghosts, size)
			return true
		end
		warn("[Ranked] ReserveServer failed: " .. tostring(code))
		rollback()
		return false
	end
	local wrote = pcall(function()
		matchStore:SetAsync(psid, {
			access = code,
			map = map,
			mode = Ranked.MODE,
			teams = 2,
			cap = count,
			slot = 0,
			id = ("ranked-%dv%d"):format(size, size),
			expected = count,
			phantoms = 0,
			grace = ARRIVAL_GRACE,
			ranked = { q = ("%dv%d"):format(size, size), size = size, side = sides, r = rs },
		}, Matchmaker.MATCH_RECORD_TTL)
	end)
	if not wrote then
		warn("[Ranked] could not write the match record")
		rollback()
		return false
	end

	-- 4. GO.
	for _, k in claimed do
		(storeOf[k] or store):update(k, function(old)
			-- Only an entry still under OUR claim goes; a stale claim taken
			-- over by another server is theirs now.
			if old == nil or old.s ~= "claim" or old.by ~= SERVER then
				return nil
			end
			old.s = "go"
			old.code = code
			old.map = map
			old.side = sides
			old.size = size
			return old
		end)
	end
	print(("[Ranked] %dv%d match (from the %s queue) on %s: %d players"):format(size, size, q.id, map, count))
	return true
end

-- The owner's side of every queued party: keep the entry alive, notice GO.
local function heartbeat(p: Party)
	local qid, key = p.queue, p.key
	if not qid or not key or p.sending or p.beating then
		return
	end
	p.beating = true
	local now = os.time()
	local e, ok = stores[qid]:update(key, function(old)
		if old == nil then
			return nil
		end
		old.h = now
		return old
	end)
	p.beating = false
	if not ok then
		-- The CALL failed: the entry is probably still there. Try next beat.
		return
	end
	if e == nil then
		-- Confirmed gone (TTL): put it back under the SAME key, so a match
		-- that already claimed it still reaches this party.
		if p.queue == qid and p.key == key then
			writeEntry(p)
		end
		return
	end
	if e.s == "go" and e.code then
		stores[qid]:remove(key)
		teleportParty(p, e)
	end
end

task.spawn(function()
	while true do
		task.wait(HEARTBEAT)
		for _, p in parties do
			if p.queue then
				task.spawn(heartbeat, p)
			end
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(MATCH_TICK + math.random() * 0.8)
		if ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) ~= "lobby" then
			return
		end
		-- Oldest of this server's queued parties first.
		local mine = {}
		for _, p in parties do
			if p.queue and p.key and not p.sending then
				table.insert(mine, p)
			end
		end
		table.sort(mine, function(a, b)
			return a.since < b.since
		end)
		local cache: RangeCache = {}
		for _, p in mine do
			local ok, res = pcall(tryMatch, p, cache)
			if not ok then
				warn("[Ranked] tryMatch: " .. tostring(res))
			elseif res then
				break
			end
		end
	end
end)

-- ================================================================ intents ==

-- Puts `player` into the party led by (or containing) `from`. Shared by an
-- accepted local invite and an arrival from a remote one.
local function joinParty(player: Player, from: number): boolean
	local uid = player.UserId
	local hp = parties[partyOf[from] or 0]
	if not hp or not Players:GetPlayerByUserId(from) then
		toast(player, "That party is gone.")
		push(player)
		return false
	end
	if #hp.members >= Ranked.MAX_PARTY then
		toast(player, "That party is full.")
		push(player)
		return false
	end
	if hp.sending or table.find(hp.members, uid) then
		return false
	end
	removeMember(uid)
	-- Joining changes the party's size and rating, so its queue (if any)
	-- starts over.
	leaveQueue(hp, if hp.queue then "The party changed, so the queue was cancelled." else nil)
	table.insert(hp.members, uid)
	partyOf[uid] = hp.leader
	parties[uid] = nil
	pushParty(hp)
	return true
end

-- INVITES FROM OTHER SERVERS. Every lobby server hears every invite; the one
-- holding the invitee delivers it.
task.spawn(function()
	local ok, err = pcall(function()
		MessagingService:SubscribeAsync(INVITE_TOPIC, function(msg)
			local d = msg.Data
			if type(d) ~= "table" then
				return
			end
			local target = Players:GetPlayerByUserId(tonumber(d.to) or 0)
			local from = tonumber(d.from)
			if not target or not from or type(d.job) ~= "string" or d.job == game.JobId then
				return
			end
			local name = string.sub(tostring(d.name or "A friend"), 1, 40)
			invites[target.UserId] = invites[target.UserId] or {}
			invites[target.UserId][from] = { t = os.time(), name = name, job = d.job }
			RankedRE:FireClient(target, "invite", { id = from, name = name })
			push(target)
		end)
	end)
	if not ok then
		warn("[Ranked] could not subscribe to invites: " .. tostring(err))
	end
end)

local lastIntent: { [number]: number } = {}

RankedRE.OnServerEvent:Connect(function(player: Player, action: any, arg: any)
	if type(action) ~= "string" then
		return
	end
	local now = os.clock()
	if action ~= "view" and now - (lastIntent[player.UserId] or 0) < 0.4 then
		return
	end
	lastIntent[player.UserId] = now
	local uid = player.UserId
	local p = partyFor(uid)

	if action == "view" then
		push(player)

	elseif action == "queue" then
		local q = Ranked.queue(arg)
		if not q then
			return
		end
		if p.leader ~= uid then
			toast(player, "Only the party leader can queue.")
			return
		end
		if #p.members > q.size then
			toast(player, ("Your party is too big for %s."):format(q.name))
			return
		end
		for _, m in p.members do
			local mp = Players:GetPlayerByUserId(m)
			if not (mp and Data.get(mp)) then
				toast(player, "Still loading your party's profiles. Try again in a moment.")
				return
			end
		end
		if p.queue then
			leaveQueue(p)
		end
		enterQueue(p, q.id)
		pushParty(p)

	elseif action == "cancel" then
		if p.queue and p.key and not p.sending then
			-- NOT ONCE A MATCH IS FORMING (prod review, 2026-10-05). A claimed
			-- or GO entry is already in somebody's match record; pulling it
			-- now would launch that match a party short.
			local qid, key = p.queue, p.key
			local busy = false
			local _, ok = stores[qid]:update(key, function(old)
				busy = old ~= nil and (old.s == "go"
					or (old.s == "claim" and os.time() - (old.ct or 0) <= CLAIM_STALE))
				return nil
			end)
			if ok and busy then
				toast(player, "Match found -- it is already being set up.")
				return
			end
			if p.queue == qid and p.key == key then
				leaveQueue(p)
				pushParty(p)
			end
		end

	elseif action == "invite" then
		local targetId = tonumber(arg) or 0
		if targetId <= 0 or targetId == uid then
			return
		end
		if p.leader ~= uid then
			toast(player, "Only the party leader can invite.")
			return
		end
		if #p.members >= Ranked.MAX_PARTY then
			toast(player, "Your party is full.")
			return
		end
		if table.find(p.members, targetId) then
			return
		end
		local target = Players:GetPlayerByUserId(targetId)
		if target then
			-- Same server: delivered right here.
			invites[targetId] = invites[targetId] or {}
			invites[targetId][uid] = { t = os.time(), name = player.DisplayName }
			RankedRE:FireClient(target, "invite", { id = uid, name = player.DisplayName })
			push(target)
			toast(player, "Invited " .. target.DisplayName .. ".")
			return
		end
		-- Another server: friends only (checked here, not trusted from the
		-- client), rate-capped, then one message.
		local now = os.time()
		local sent = remoteSent[uid] or {}
		for i = #sent, 1, -1 do
			if now - sent[i] > 60 then
				table.remove(sent, i)
			end
		end
		if #sent >= REMOTE_INVITES_PER_MIN then
			toast(player, "Slow down -- too many invites.")
			return
		end
		table.insert(sent, now)
		remoteSent[uid] = sent
		task.spawn(function()
			local okF, friends = pcall(function()
				return player:IsFriendsWith(targetId)
			end)
			if not (okF and friends) then
				toast(player, "You can only invite friends.")
				return
			end
			local okP, err = pcall(function()
				MessagingService:PublishAsync(INVITE_TOPIC, {
					to = targetId,
					from = uid,
					name = player.DisplayName,
					job = game.JobId,
				})
			end)
			if okP then
				-- Remembered HERE, so an arrival claiming this party is only let
				-- in if this server really invited them (joinOnArrival).
				sentInvites[targetId] = { from = uid, t = os.time() }
				toast(player, "Invite sent.")
			else
				warn("[Ranked] invite publish failed: " .. tostring(err))
				toast(player, "Could not send that invite.")
			end
		end)

	elseif action == "accept" then
		local from = tonumber(arg) or 0
		local inv = invites[uid] and invites[uid][from]
		if invites[uid] then
			invites[uid][from] = nil
		end
		if not inv or os.time() - inv.t > INVITE_TTL then
			toast(player, "That invite has expired.")
			push(player)
			return
		end
		if inv.job and not Players:GetPlayerByUserId(from) then
			-- The leader is on another lobby server: go there. They join the
			-- party on arrival (joinOnArrival), the acceptance travelling in
			-- the teleport data.
			if p.queue then
				leaveQueue(p)
			end
			RankedRE:FireClient(player, "found", { joining = inv.name })
			local options = Instance.new("TeleportOptions")
			options.ServerInstanceId = inv.job
			options:SetTeleportData({
				rparty = from,
				cq = Analytics and (Analytics :: any).teleportData({ player }) or nil,
			})
			local okT, err = pcall(function()
				TeleportService:TeleportAsync(game.PlaceId, { player }, options)
			end)
			if not okT then
				warn("[Ranked] party teleport failed: " .. tostring(err))
				toast(player, "Could not reach " .. inv.name .. "'s server.")
				push(player)
			end
			return
		end
		joinParty(player, from)

	elseif action == "decline" then
		if invites[uid] then
			invites[uid][tonumber(arg) or 0] = nil
		end
		push(player)

	elseif action == "leave" then
		if #p.members > 1 and not p.sending then
			removeMember(uid)
			partyFor(uid)
			push(player)
		end

	elseif action == "kick" then
		local target = tonumber(arg) or 0
		if p.leader == uid and target ~= uid and table.find(p.members, target) and not p.sending then
			removeMember(target)
			local tp = Players:GetPlayerByUserId(target)
			if tp then
				partyFor(target)
				push(tp)
				toast(tp, "You were removed from the party.")
			end
		end
	end
end)

-- ARRIVED FROM AN ACCEPTED INVITE: the teleport data names the leader, and
-- the player joins that party as soon as their profile is here.
local function joinOnArrival(player: Player)
	local ok, data = pcall(function()
		return player:GetJoinData().TeleportData
	end)
	local leaderId = ok and type(data) == "table" and tonumber(data.rparty) or nil
	-- TELEPORT DATA IS CLIENT-WRITABLE, so it is only a claim: the arrival
	-- joins only if THIS server sent them an invite from that party, recently.
	local sent = sentInvites[player.UserId]
	sentInvites[player.UserId] = nil
	local leaderNow = leaderId and (partyOf[leaderId] or leaderId)
	local invited = sent ~= nil and os.time() - sent.t <= INVITE_TTL * 2
		and (sent.from == leaderId or partyOf[sent.from] == leaderNow)
	if leaderId and leaderId ~= player.UserId and invited then
		if joinParty(player, leaderId) then
			toast(player, "You joined the party.")
		end
	end
end

Data.onReady(function(player: Player)
	publish(player)
	push(player)
	joinOnArrival(player)
end)

-- A TELEPORT THAT FAILS AFTER TeleportAsync RETURNED (GameFull, Flooded...)
-- arrives here. The party is un-flagged so it can queue again.
TeleportService.TeleportInitFailed:Connect(function(player)
	local leader = partyOf[player.UserId]
	local p = leader and parties[leader]
	if p and p.sending then
		p.sending = false
		p.queue, p.key, p.since = nil, nil, 0
		toast(player, "Could not reach the match. Queue again.")
		pushParty(p)
	end
end)

-- ENTERING A BOARD MATCH OR A ROOM LEAVES THE RANKED QUEUE. MatchmakerServer
-- fires this on join/create/pjoin/tutorial, so one player can never be pulled
-- into two matches at once (prod review, 2026-10-05).
do
	local ServerStorage = game:GetService("ServerStorage")
	local be = ServerStorage:FindFirstChild("RankedCancel") :: BindableEvent?
	if not be then
		local made = Instance.new("BindableEvent")
		made.Name = "RankedCancel"
		made.Parent = ServerStorage
		be = made
	end
	(be :: BindableEvent).Event:Connect(function(player: Player)
		local leader = partyOf[player.UserId]
		local p = leader and parties[leader]
		if p and p.queue and not p.sending then
			leaveQueue(p, "You joined another game, so the ranked queue was cancelled.")
			pushParty(p)
		end
	end)
end

Players.PlayerRemoving:Connect(function(player)
	removeMember(player.UserId)
	parties[player.UserId] = nil
	invites[player.UserId] = nil
	remoteSent[player.UserId] = nil
	sentInvites[player.UserId] = nil
	lastIntent[player.UserId] = nil
end)
