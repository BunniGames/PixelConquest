--!strict
-- Conquest :: Matchmaker  (shared)
--
-- The rules half of cross-server matchmaking. Every server of this experience
-- shows the SAME three lobbies, and players sitting in three different servers
-- queue into one of them and are then teleported into a single match server.
--
-- WHY THIS MODULE IS SHARED. The server owns the lobby records, but the client
-- has to render them -- the card's map, its mode, its countdown -- and the two
-- must never disagree about what a record means. Everything here is pure: no
-- MemoryStore, no TeleportService, no instances. `MatchmakerServer` is the
-- only thing that touches the network; this is what it and the page both read.
--
-- THE TOPOLOGY, because it is not obvious from any one file:
--   * A PUBLIC server of this place is a LOBBY. It runs the matchmaking page
--     and no simulation at all.
--   * A RESERVED server of this SAME place is a MATCH. `MatchmakerServer`
--     reserves it when a lobby launches, and `ConquestServer` runs the round.
--   * `game.PrivateServerId ~= ""` is the whole test, and it costs nothing.
-- There is no second place. A second place would mean two copies of all 27
-- modules kept in sync by hand, and this project has no disk mirror to do that
-- with.

local Maps = require(script.Parent.Maps)
local Modes = require(script.Parent.Modes)

local RunService = game:GetService("RunService")

local Matchmaker = {}

-- ------------------------------------------------------------- constants ---

-- Bump this and every live server starts a fresh set of lobbies, because the
-- store name changes with it. That is the migration path for any change to the
-- record shape: old servers keep talking to the old store until they die.
Matchmaker.VERSION = 1

-- STUDIO GETS ITS OWN BOARD, and this is not a nicety. A Studio session polls
-- the same universe's MemoryStore as every live server, so without the suffix
-- it could win the race to claim a REAL lobby full of REAL players and then
-- fail at ReserveServer (which does not exist in Studio) -- stranding them.
-- Two Studio instances still share the studio board, which is what makes the
-- cross-server test possible without shipping anything.
local STORE_SUFFIX = RunService:IsStudio() and "_studio" or ""
Matchmaker.STORE = "ConquestLobbies_v1" .. STORE_SUFFIX
Matchmaker.MATCH_STORE = "ConquestMatches_v1" .. STORE_SUFFIX

-- Attribute on ReplicatedStorage. The client cannot be trusted to work its own
-- role out from `game.PrivateServerId` in the one case that matters (a Studio
-- session, where it is always empty), so the server states it.
Matchmaker.ROLE_ATTR = "ConquestRole"
Matchmaker.LOCAL_MAP_ATTR = "ConquestLocalMap"
Matchmaker.LOCAL_MODE_ATTR = "ConquestLocalMode"
-- A STUDIO SESSION HAS NO RESERVED SERVER AND THEREFORE NO MATCH RECORD, so a
-- round started in place is told a private lobby's dials through these instead
-- of through MemoryStore. Attributes rather than one packed string because
-- every one of them is a number and the reader is two lines away.
Matchmaker.LOCAL_TEAMS_ATTR = "ConquestLocalTeams"
Matchmaker.LOCAL_TROOPS_ATTR = "ConquestLocalTroopScale"
Matchmaker.LOCAL_GOLD_ATTR = "ConquestLocalStartGold"

Matchmaker.COUNTDOWN = 120 -- 2:00, and it starts on the FIRST JOIN (see below)
Matchmaker.RECORD_TTL = 900 -- an abandoned record evaporates rather than lingering
Matchmaker.MATCH_TTL = 3600 -- a match config outlives the longest possible round
Matchmaker.CLAIM_STALE = 15 -- a claim older than this may be stolen
Matchmaker.READY_HOLD = 10 -- how long the access code stays readable
Matchmaker.MEMBER_STALE = 20 -- a server that has not checked in this long is gone
Matchmaker.HEARTBEAT = 5 -- how often a server refreshes its own entry
Matchmaker.POLL = 1 -- how often a server reads the board
Matchmaker.PUSH = 5 -- ...and pushes it to clients even when nothing changed
Matchmaker.BOARD_GRACE = 25 -- how long a match server waits for arrivals
Matchmaker.LAUNCH_MIN = 1 -- one human plus the bot roster is a real game

-- WHAT A STUDIO SESSION IS. `game.PrivateServerId` is empty in Studio, so
-- without this every playtest would be a lobby server whose countdown reaches
-- zero and then fails at ReserveServer, which does not exist in Studio either.
-- Instead the lobby STARTS THE ROUND IN PLACE: you get the page, you join a
-- card, the timer runs out and the game begins in the same session. Set this
-- to "match" to skip the page and boot straight into a round, as before.
Matchmaker.STUDIO_ROLE = "lobby"

-- ----------------------------------------------------------------- slots ---

-- THE THREE CARDS ARE SIZE TIERS AND THE MAP AND MODE VARY UNDERNEATH. A card
-- whose identity was "Europe Duos" would be a different card every rotation
-- and players could not form a habit around it; a card that is always "the
-- small fast one" can carry any of the twenty-one pairings without moving.
--
-- 6 / 12 / 24 IS NOT AN ARBITRARY LADDER: they are the sizes divisible by 1,
-- 2 AND 3, so free-for-all, two teams and three teams can all appear on any
-- card with even sides. `Sim` rounds the BOT count up to a whole number of
-- sides anyway, but a human roster that cannot divide evenly hands one team a
-- spare member, and across six headless matches the team with the spare member
-- won every single one.
export type Slot = {
	key: string,
	name: string,
	cap: number,
	blurb: string,
}

Matchmaker.SLOTS = {
	{
		key = "slot1",
		name = "SKIRMISH",
		cap = 6,
		blurb = "Fills fast. First war of the evening.",
	},
	{
		key = "slot2",
		name = "BATTLE",
		cap = 12,
		blurb = "A full board without the wait.",
	},
	{
		key = "slot3",
		name = "WORLD WAR",
		cap = 24,
		blurb = "Every commander the map will hold.",
	},
} :: { Slot }

-- ---------------------------------------------------------------- record ---

-- One of these per slot, living in a MemoryStore SortedMap under `slot.key`.
-- It must stay JSON-serialisable: arrays and primitives only, no mixed tables,
-- no Instances, nothing keyed by a value that is not a string.
--
-- `servers` is an ARRAY, not a dictionary keyed by JobId, so its ordering is
-- stable through a round trip and a pruning pass is an ordinary reverse loop.
export type ServerEntry = {
	j: string, -- JobId (or a Studio stand-in)
	t: number, -- last heartbeat, os.time()
	u: { number }, -- the userIds this server is holding in this lobby
}

export type Record = {
	id: string, -- this LOBBY GENERATION; a reset mints a new one
	slot: number,
	map: string,
	mode: string,
	cap: number,
	state: string, -- "open" | "claim" | "ready"
	deadline: number, -- 0 until the first player joins
	claimedAt: number,
	host: string,
	code: string,
	psid: string,
	readyAt: number,
	servers: { ServerEntry },
}

-- ------------------------------------------------------------------ role ---

-- Server-side truth. In Studio there is no reserved server, so the constant
-- above decides -- see STUDIO_ROLE.
function Matchmaker.isMatchServer(): boolean
	if game.PrivateServerId ~= "" then
		return true
	end
	if RunService:IsStudio() then
		return Matchmaker.STUDIO_ROLE == "match"
	end
	return false
end

-- Client-side. Yields until the server has declared the role, then until it
-- is the one asked for. It is a yield rather than a one-shot read because a
-- Studio lobby FLIPS to "match" the moment its countdown fires, and the game
-- client has to start building at exactly that point.
function Matchmaker.awaitRole(want: string): ()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	while ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) ~= want do
		ReplicatedStorage:GetAttributeChangedSignal(Matchmaker.ROLE_ATTR):Wait()
	end
end

-- -------------------------------------------------------------- pairings ---

-- All twenty-one (map, mode) pairs, in a fixed order so every server
-- enumerates
-- them identically.
function Matchmaker.allPairs(): { { map: string, mode: string } }
	local out = {}
	for _, m in Maps.ORDER do
		for _, g in Modes.ORDER do
			table.insert(out, { map = m, mode = g })
		end
	end
	return out
end

function Matchmaker.pairKey(map: string, mode: string): string
	return map .. "|" .. mode
end

-- Draws a pairing for a new lobby, given whatever the other slots are showing.
--
-- It prefers a card that shares NEITHER its map NOR its mode with the others,
-- not merely a distinct pair: two adjacent cards both reading THREE TEAMS is
-- technically two different lobbies and reads as a page that has run out of
-- ideas. Four maps and three modes always admit three fully-distinct cards, so
-- the strong rule is satisfiable -- but it falls back to merely-distinct and
-- then to anything, because a draw that can fail is a page that can go blank.
--
-- Rejecting costs nothing: the caller has just read all three records.
function Matchmaker.drawPair(used: { { map: string, mode: string } }?): (string, string)
	local pairSeen, mapSeen, modeSeen = {}, {}, {}
	for _, u in used or {} do
		pairSeen[Matchmaker.pairKey(u.map, u.mode)] = true
		mapSeen[u.map] = true
		modeSeen[u.mode] = true
	end
	local all = Matchmaker.allPairs()
	local distinct, fresh = {}, {}
	for _, p in all do
		if not pairSeen[Matchmaker.pairKey(p.map, p.mode)] then
			table.insert(distinct, p)
			if not mapSeen[p.map] and not modeSeen[p.mode] then
				table.insert(fresh, p)
			end
		end
	end
	local pool = #fresh > 0 and fresh or (#distinct > 0 and distinct or all)
	local pick = pool[math.random(1, #pool)]
	return pick.map, pick.mode
end

-- ------------------------------------------------------------ lifecycle ----

local idCounter = 0

function Matchmaker.newRecord(slotIndex: number, used: { { map: string, mode: string } }?): Record
	local slot = Matchmaker.SLOTS[slotIndex]
	local map, mode = Matchmaker.drawPair(used)
	idCounter += 1
	return {
		-- The id has to be unique across SERVERS, not just within one, because
		-- two servers can mint a replacement for the same slot in the same
		-- second and every later write is guarded by "is this still my
		-- generation". os.time alone is not enough for that.
		id = string.format("%s-%d-%d-%d", slot.key, os.time(), idCounter, math.random(1, 1000000)),
		slot = slotIndex,
		map = map,
		mode = mode,
		cap = slot.cap,
		state = "open",
		deadline = 0,
		claimedAt = 0,
		host = "",
		code = "",
		psid = "",
		readyAt = 0,
		servers = {},
	}
end

function Matchmaker.count(rec: Record): number
	local n = 0
	for _, s in rec.servers do
		n += #s.u
	end
	return n
end

-- Drops server entries that have stopped checking in. A server that crashes
-- takes its players' membership with it and nothing else notices, so without
-- this a dead server's ghosts hold seats in the lobby until the record's TTL
-- expires -- which is 15 minutes.
function Matchmaker.prune(rec: Record, now: number): boolean
	local changed = false
	for i = #rec.servers, 1, -1 do
		local s = rec.servers[i]
		if #s.u == 0 or (now - (s.t or 0)) > Matchmaker.MEMBER_STALE then
			table.remove(rec.servers, i)
			changed = true
		end
	end
	-- An emptied lobby stops counting down. Otherwise a lobby someone joined
	-- and left keeps its deadline and launches at zero with nobody in it.
	if changed and Matchmaker.count(rec) == 0 and rec.deadline ~= 0 then
		rec.deadline = 0
	end
	return changed
end

function Matchmaker.entryFor(rec: Record, jobId: string): ServerEntry?
	for _, s in rec.servers do
		if s.j == jobId then
			return s
		end
	end
	return nil
end

function Matchmaker.hasMember(rec: Record, userId: number): boolean
	for _, s in rec.servers do
		if table.find(s.u, userId) then
			return true
		end
	end
	return false
end

-- THE LAUNCH RULE. Full, or the clock ran out with at least one human in it.
-- Note the second half is the reason the deadline is 0 on an empty lobby: an
-- always-running clock would reserve an empty match server every two minutes,
-- for each of three slots, forever.
function Matchmaker.shouldLaunch(rec: Record, now: number): boolean
	local n = Matchmaker.count(rec)
	if n <= 0 then
		return false
	end
	if n >= rec.cap then
		return true
	end
	return rec.deadline ~= 0 and now >= rec.deadline and n >= Matchmaker.LAUNCH_MIN
end

function Matchmaker.remaining(rec: Record, now: number): number
	if rec.deadline == 0 then
		return Matchmaker.COUNTDOWN
	end
	return math.max(0, rec.deadline - now)
end

-- ------------------------------------------------------------------ wire ---

-- The board goes out to every client on the page once a second. Roblox sends a
-- table's KEYS AS STRINGS on every send, which is what made the old summary
-- streams in this project cost more in field names than in data, so the wire
-- form is arrays only: nothing here is keyed.
--
--   { { mapIndex, modeIndex, cap, remaining, stateCode, { userId... } }, ... }
--
-- A client works out its OWN membership from the userId list, so this is one
-- broadcast rather than a packet per player.
local STATE_CODE = { open = 1, claim = 2, ready = 3 }
local CODE_STATE = { "open", "claim", "ready" }

function Matchmaker.wire(recs: { [string]: Record }, now: number): { any }
	local out = {}
	for i, slot in Matchmaker.SLOTS do
		local rec = recs[slot.key]
		if rec then
			local users = {}
			for _, s in rec.servers do
				-- SKIP SERVERS THAT HAVE STOPPED CHECKING IN, without waiting
				-- for somebody to write the prune. A crashed server's players
				-- are already gone, and a card reading "5 / 6" at nobody is
				-- worse than any staleness: it can make an empty lobby look
				-- full and refuse real joins.
				if (now - (s.t or 0)) <= Matchmaker.MEMBER_STALE then
					for _, u in s.u do
						table.insert(users, u)
					end
				end
			end
			out[i] = {
				table.find(Maps.ORDER, rec.map) or 1,
				table.find(Modes.ORDER, rec.mode) or 1,
				rec.cap,
				Matchmaker.remaining(rec, now),
				STATE_CODE[rec.state] or 1,
				users,
			}
		else
			out[i] = { 1, 1, slot.cap, Matchmaker.COUNTDOWN, 1, {} }
		end
	end
	return out
end

export type CardView = {
	slot: number,
	name: string,
	blurb: string,
	map: string,
	mode: string,
	mapName: string,
	mapBlurb: string,
	modeName: string,
	modeBlurb: string,
	cap: number,
	count: number,
	remaining: number,
	state: string,
	users: { number },
	mine: boolean,
}

function Matchmaker.readWire(wire: { any }, myUserId: number): { CardView }
	local out = {}
	for i, slot in Matchmaker.SLOTS do
		local e = wire[i]
		if type(e) == "table" then
			local map = Maps.ORDER[e[1]] or Maps.ORDER[1]
			local mode = Modes.ORDER[e[2]] or Modes.ORDER[1]
			local users = e[6] or {}
			out[i] = {
				slot = i,
				name = slot.name,
				blurb = slot.blurb,
				map = map,
				mode = mode,
				mapName = Maps.get(map).NAME,
				mapBlurb = Maps.get(map).BLURB,
				modeName = Modes.get(mode).NAME,
				modeBlurb = Modes.get(mode).BLURB,
				cap = e[3] or slot.cap,
				count = #users,
				remaining = e[4] or Matchmaker.COUNTDOWN,
				state = CODE_STATE[e[5]] or "open",
				users = users,
				mine = table.find(users, myUserId) ~= nil,
			}
		end
	end
	return out
end

-- mm:ss, and it never shows a negative -- a lobby past its deadline is waiting
-- on a reservation, not counting backwards.
function Matchmaker.clock(seconds: number): string
	local s = math.max(0, math.floor(seconds + 0.5))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

return Matchmaker
