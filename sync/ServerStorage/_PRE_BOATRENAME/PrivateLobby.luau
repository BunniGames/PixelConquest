--!strict
-- Conquest :: PrivateLobby  (shared)
--
-- The rules half of private lobbies: a room you make, hand a four-digit code
-- to your friends, configure, and start yourself. The public board next door
-- (see Matchmaker) is the opposite product -- fixed slots, a clock nobody
-- controls, whatever map the rotation drew -- and the two share nothing but
-- the MemoryStore idiom and the teleport at the end.
--
-- WHY THIS MODULE IS SHARED, and it is the same reason Matchmaker is: the
-- server owns the record, the client draws it, and neither may have its own
-- opinion about what a record MEANS. Everything here is pure -- no
-- MemoryStore, no TeleportService, no instances. `MatchmakerServer` is the
-- only thing that touches the network.
--
-- THE CODE IS THE KEY. A record lives in a MemoryStore hash map under its own
-- four digits, which is what makes "type 4821 and press join" a single
-- GetAsync from any server in the experience rather than a search. Four digits
-- is 10,000 rooms; see `TRIES` for what happens when two hosts draw the same
-- one in the same second.
--
-- SETTINGS ARE STORED AS OPTION INDEXES, never as values. The wire is then
-- four small integers instead of a map id, a float and two five-figure
-- numbers, and -- the part that actually matters -- a client cannot ask for a
-- starting-gold figure that is not on the menu, because there is no field to
-- put it in. Validation is `is this index in range`, which cannot be got
-- wrong. `settings()` is the only place indexes become values.

local Maps = require(script.Parent.Maps)

local RunService = game:GetService("RunService")

local PrivateLobby = {}

-- ------------------------------------------------------------- constants ---

-- Studio gets its own store for the same reason the public board does: a
-- playtest must not be able to reach a real room, and two Studio sessions
-- still share this one, which is what makes the cross-server test possible
-- without shipping anything.
local STORE_SUFFIX = RunService:IsStudio() and "_studio" or ""
PrivateLobby.STORE = "ConquestPrivate_v1" .. STORE_SUFFIX

PrivateLobby.CAP = 24 -- the biggest the sim is tuned for; see Matchmaker.SLOTS
PrivateLobby.TTL = 1800 -- an abandoned room evaporates after half an hour
PrivateLobby.MEMBER_STALE = 20 -- a server that has not checked in this long is gone
PrivateLobby.HEARTBEAT = 5 -- how often a server refreshes its own entry
PrivateLobby.CLAIM_STALE = 15 -- a claim older than this may be stolen
PrivateLobby.READY_HOLD = 10 -- how long the access code stays readable
PrivateLobby.TRIES = 8 -- code draws before giving up

-- ---------------------------------------------------------------- menus ----

-- THE FOUR THINGS A HOST PICKS. Order is the display order and the index order
-- on the wire, so appending is free and reordering is not.
PrivateLobby.MAP = Maps.ORDER

-- 0 IS FREE-FOR-ALL, and it is first because it is the default. Above two,
-- `modeFor` reuses the three-team mode's win threshold: what a team mode
-- changes in the sim is the 95% bar and friendly fire, and neither cares
-- whether there are three sides or four.
PrivateLobby.TEAMS = { 0, 2, 3, 4 }

-- A MULTIPLIER ON EVERY EMPIRE'S STARTING ARMY, not a flat figure. Bots spawn
-- with less than humans on purpose (Config.TIER[...].SPAWN_TROOPS: 25,000
-- human, 18,000 legacy bot) and a flat number would erase that -- so a host
-- reaching for "double troops" would also, invisibly, be handing the bots a
-- 39% buff. Scaling keeps the ladder.
PrivateLobby.TROOPS = { 0.5, 1, 2, 4 }

-- Flat, and the same for everyone including bots: gold is not tiered in the
-- sim (every empire starts on zero), so there is no ladder to preserve.
PrivateLobby.GOLD = { 0, 5000, 25000, 100000 }

local TEAM_LABEL = { "FREE FOR ALL", "2 TEAMS", "3 TEAMS", "4 TEAMS" }
local TROOP_LABEL = { "HALF", "NORMAL", "DOUBLE", "QUADRUPLE" }
local GOLD_LABEL = { "NONE", "5,000", "25,000", "100,000" }

-- Four rows, in the order the panel draws them.
export type Field = {
	key: string,
	label: string,
	slot: number, -- which index of `rec.s` this row owns
}

PrivateLobby.FIELDS = {
	{ key = "map", label = "MAP", slot = 1 },
	{ key = "teams", label = "TEAMS", slot = 2 },
	{ key = "troops", label = "STARTING TROOPS", slot = 3 },
	{ key = "gold", label = "STARTING GOLD", slot = 4 },
} :: { Field }

-- Defaults are the FIRST map, free-for-all and the sim's own numbers, so a
-- host who touches nothing gets exactly the game the public board serves.
function PrivateLobby.defaults(): { number }
	return { 1, 1, 2, 1 }
end

function PrivateLobby.count(field: string): number
	if field == "map" then
		return #PrivateLobby.MAP
	elseif field == "teams" then
		return #PrivateLobby.TEAMS
	elseif field == "troops" then
		return #PrivateLobby.TROOPS
	end
	return #PrivateLobby.GOLD
end

function PrivateLobby.label(field: string, index: number): string
	if field == "map" then
		return string.upper(Maps.get(PrivateLobby.MAP[index] or PrivateLobby.MAP[1]).NAME)
	elseif field == "teams" then
		return TEAM_LABEL[index] or TEAM_LABEL[1]
	elseif field == "troops" then
		return TROOP_LABEL[index] or TROOP_LABEL[2]
	end
	return GOLD_LABEL[index] or GOLD_LABEL[1]
end

-- Anything a client sends lands here first. Every entry is forced to a whole
-- number inside its own menu, so the worst a hostile client achieves is a
-- legal game it could have picked from the panel.
function PrivateLobby.clampSettings(s: any): { number }
	local out = PrivateLobby.defaults()
	if type(s) ~= "table" then
		return out
	end
	for i, f in PrivateLobby.FIELDS do
		local v = tonumber((s :: any)[f.slot])
		if v then
			out[i] = math.clamp(math.floor(v), 1, PrivateLobby.count(f.key))
		end
	end
	return out
end

-- INDEXES BECOME VALUES HERE AND NOWHERE ELSE.
export type Settings = {
	map: string,
	mode: string,
	teams: number,
	troopScale: number,
	startGold: number,
}

function PrivateLobby.modeFor(teams: number): string
	if teams <= 0 then
		return "ffa"
	elseif teams == 2 then
		return "duo"
	end
	return "trio"
end

function PrivateLobby.settings(s: { number }?): Settings
	local idx = PrivateLobby.clampSettings(s)
	local teams = PrivateLobby.TEAMS[idx[2]] or 0
	return {
		map = PrivateLobby.MAP[idx[1]] or PrivateLobby.MAP[1],
		mode = PrivateLobby.modeFor(teams),
		teams = teams,
		troopScale = PrivateLobby.TROOPS[idx[3]] or 1,
		startGold = PrivateLobby.GOLD[idx[4]] or 0,
	}
end

-- ---------------------------------------------------------------- record ---

export type ServerEntry = {
	j: string, -- JobId (or a Studio stand-in)
	t: number, -- last heartbeat, os.time()
	u: { number }, -- the userIds this server is holding in this room
}

export type Record = {
	code: string,
	host: number, -- userId. The one player who may change settings or start.
	s: { number }, -- settings, as menu indexes
	state: string, -- "open" | "claim" | "ready"
	claimedAt: number,
	hostServer: string,
	access: string, -- reserved-server access code, once there is one
	psid: string,
	readyAt: number,
	servers: { ServerEntry },
}

-- Four digits, zero-padded, as a STRING -- "0421" is a different room from
-- "421" and a number would lose the leading zero on the first round trip.
function PrivateLobby.newCode(): string
	return string.format("%04d", math.random(0, 9999))
end

function PrivateLobby.newRecord(code: string, hostUserId: number, s: { number }?): Record
	return {
		code = code,
		host = hostUserId,
		s = PrivateLobby.clampSettings(s),
		state = "open",
		claimedAt = 0,
		hostServer = "",
		access = "",
		psid = "",
		readyAt = 0,
		servers = {},
	}
end

function PrivateLobby.members(rec: Record): number
	local n = 0
	for _, e in rec.servers do
		n += #e.u
	end
	return n
end

function PrivateLobby.entryFor(rec: Record, jobId: string): ServerEntry?
	for _, e in rec.servers do
		if e.j == jobId then
			return e
		end
	end
	return nil
end

function PrivateLobby.hasMember(rec: Record, userId: number): boolean
	for _, e in rec.servers do
		if table.find(e.u, userId) then
			return true
		end
	end
	return false
end

-- Drops server entries that have stopped checking in. A server that crashes
-- takes its members' seats with it and nothing else notices, so without this
-- a dead server's ghosts hold a room open until its TTL expires -- half an
-- hour of a lobby reading "6 / 24" at an empty page.
function PrivateLobby.prune(rec: Record, now: number): boolean
	local changed = false
	for i = #rec.servers, 1, -1 do
		local e = rec.servers[i]
		if #e.u == 0 or (now - (e.t or 0)) > PrivateLobby.MEMBER_STALE then
			table.remove(rec.servers, i)
			changed = true
		end
	end
	return changed
end

-- THE HOST LEFT. Somebody has to be able to start the room or it is a dead
-- page with a countdown that never comes, so the seat passes to whoever is
-- still in it -- lowest userId, which every server computes identically from
-- the same record and therefore agrees on without another round trip.
function PrivateLobby.reseat(rec: Record): boolean
	if PrivateLobby.hasMember(rec, rec.host) then
		return false
	end
	local best: number? = nil
	for _, e in rec.servers do
		for _, u in e.u do
			if best == nil or u < best then
				best = u
			end
		end
	end
	rec.host = best or 0
	return true
end

-- ------------------------------------------------------------------ wire ---

-- One room, to the players in it. Arrays only, for the reason spelled out in
-- Matchmaker.wire: Roblox sends a table's KEYS AS STRINGS on every send, so a
-- keyed form pays for the field names every time.
--
--   { code, host, mapIdx, teamsIdx, troopsIdx, goldIdx, stateCode, { userId... } }
--
-- A client works out whether it is the host, and whether it is in the room at
-- all, from `host` and the userId list -- so this is one broadcast rather than
-- a packet per member.
local STATE_CODE = { open = 1, claim = 2, ready = 3 }
local CODE_STATE = { "open", "claim", "ready" }

function PrivateLobby.wire(rec: Record, now: number): { any }
	local users = {}
	for _, e in rec.servers do
		-- Skip servers that have stopped checking in without waiting for
		-- somebody to write the prune: a crashed server's members are already
		-- gone, and a room that reads full to a joiner who cannot see anybody
		-- is worse than any staleness.
		if (now - (e.t or 0)) <= PrivateLobby.MEMBER_STALE then
			for _, u in e.u do
				table.insert(users, u)
			end
		end
	end
	table.sort(users)
	local s = rec.s
	return { rec.code, rec.host, s[1], s[2], s[3], s[4], STATE_CODE[rec.state] or 1, users }
end

export type View = {
	code: string,
	host: number,
	settings: { number },
	state: string,
	users: { number },
	count: number,
	mine: boolean,
	isHost: boolean,
}

function PrivateLobby.readWire(w: { any }, myUserId: number): View?
	if type(w) ~= "table" or type(w[1]) ~= "string" then
		return nil
	end
	local users = w[8] or {}
	return {
		code = w[1],
		host = w[2] or 0,
		settings = PrivateLobby.clampSettings({ w[3], w[4], w[5], w[6] }),
		state = CODE_STATE[w[7]] or "open",
		users = users,
		count = #users,
		mine = table.find(users, myUserId) ~= nil,
		isHost = w[2] == myUserId,
	}
end

-- A typed code is whatever the player left in the box. Four digits or nothing.
function PrivateLobby.normalise(text: any): string?
	if typeof(text) ~= "string" then
		return nil
	end
	local digits = string.gsub(text, "%D", "")
	if #digits ~= 4 then
		return nil
	end
	return digits
end

return PrivateLobby
