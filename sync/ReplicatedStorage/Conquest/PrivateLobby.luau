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
-- For the special modes' names on the MODE row, so the panel cannot call one
-- something the card does not. Tiny, and it requires nothing.
local Modes = require(script.Parent.Modes)

local RunService = game:GetService("RunService")

local PrivateLobby = {}

-- ------------------------------------------------------------- constants ---

-- Studio gets its own store for the same reason the public board does: a
-- playtest must not be able to reach a real room, and two Studio sessions
-- still share this one, which is what makes the cross-server test possible
-- without shipping anything.
local STORE_SUFFIX = RunService:IsStudio() and "_studio" or ""
PrivateLobby.STORE = "ConquestPrivate_v1" .. STORE_SUFFIX
-- WHERE A PUBLIC ROOM ADVERTISES ITSELF (2026-09-17). The room store is a
-- HASH map keyed by code and a hash map cannot be enumerated, so a list of
-- "every room open to strangers right now" cannot be read out of it at any
-- price. This is a SORTED map holding one small summary per public room, which
-- is a range read away.
--
-- IT IS A CACHE, NOT A RECORD. Nothing is ever deleted from it by leaving a
-- room or by a server dying: every entry carries a TTL of a few heartbeats and
-- the HOST's server rewrites its own while the room is still open and still
-- public. A room that stops being either simply stops being refreshed and falls
-- out on its own -- which is the only cleanup rule that survives a crash.
PrivateLobby.PUBLIC_STORE = "ConquestPublic_v1" .. STORE_SUFFIX
PrivateLobby.PUBLIC_TTL = 20 -- ...four heartbeats, so one missed beat is not a vanished room
PrivateLobby.PUBLIC_MAX = 40 -- the most rooms a list read will ask for

PrivateLobby.CAP = 24 -- the biggest the sim is tuned for; see Matchmaker.SLOTS
PrivateLobby.TTL = 1800 -- an abandoned room evaporates after half an hour
PrivateLobby.MEMBER_STALE = 20 -- a server that has not checked in this long is gone
PrivateLobby.HEARTBEAT = 5 -- how often a server refreshes its own entry
PrivateLobby.CLAIM_STALE = 15 -- a claim older than this may be stolen
PrivateLobby.READY_HOLD = 10 -- how long the access code stays readable

-- A PUBLIC ROOM STARTS ON ITS OWN AFTER TWO MINUTES (2026-09-17, owner: "when
-- players host games, if its public. give it a 2 minute time limit before it
-- starts"). A room that strangers can see is being ADVERTISED, and an advert
-- for a game that begins whenever one person feels like it is an advert for
-- nothing -- a stranger who presses JOIN on it has no idea whether they are
-- two seconds or twenty minutes from playing, and the ones who wait and find
-- out are the ones who stop pressing. So a listed room carries the same
-- promise the board's own cards carry: a clock, and it goes when the clock
-- does.
--
-- A PRIVATE ROOM KEEPS NO CLOCK AT ALL. Nothing is being advertised there and
-- everybody in it is somebody the host handed four digits to, so the host
-- deciding when to start is the whole product. See `deadlineFor`: the clock is
-- born when the room becomes public and dies when it stops being.
--
-- The host may still press START at any point before it -- the countdown is a
-- ceiling on the wait, never a floor.
PrivateLobby.PUBLIC_START = 120
PrivateLobby.TRIES = 8 -- code draws before giving up

-- ---------------------------------------------------------------- menus ----

-- THE THINGS A HOST PICKS. A menu's order is its index order on the wire, so
-- appending to one is free and reordering one is not.
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

-- THE MODE (2026-09-11), and the one row a HOST pass does not open: anything
-- past CLASSIC is sold as ADVANCED (Products; MatchmakerServer.hostTier is the
-- gate). CLASSIC is whichever of ffa / duo / trio the TEAMS row makes; every
-- other entry's `id` IS its Modes id.
--
-- `maps` is WHERE a mode can be played. A historical round needs a predrawn
-- scenario, and those live in Scenarios.BY_MAP -- restated here rather than
-- required, because Scenarios pulls in the generated WW2Scenario (42 KB) and
-- this module is loaded by the lobby CLIENT. The server re-checks the pair
-- against Scenarios at launch (MatchmakerServer.launchRoom), so a drift
-- between the two lists costs an ordinary round, never a broken one.
--
-- APPEND ONLY: the index is the wire.
export type ModeOption = { id: string, label: string, maps: { string }?, special: boolean? }

PrivateLobby.MODES = {
	{ id = "classic", label = "CLASSIC" },
	{ id = "historical", label = "HISTORICAL", maps = { "world", "korea" } },
	-- THE SPECIAL MODES (2026-09-18), appended because the index is the wire.
	-- Any map (no `maps`), a free-for-all whatever the TEAMS row says (see
	-- resolve), and sold with everything else past CLASSIC: ADVANCED. `special`
	-- is what the SEE ALL GAMES row reads to colour its pill gold; the names
	-- come from Modes so the row and the card agree.
	{ id = "rich", label = Modes.name("rich"), special = true },
	{ id = "horde", label = Modes.name("horde"), special = true },
	{ id = "nuclear", label = Modes.name("nuclear"), special = true },
	{ id = "blitz", label = Modes.name("blitz"), special = true },
	-- THE SCENARIOS AFTER THE FIRST (2026-09-24), appended for the same
	-- reason. `maps` restates Scenarios.BY_MODE for the client, as above.
	{ id = "ww1", label = Modes.name("ww1"), maps = { "world", "europe" } },
	{ id = "napoleonic", label = Modes.name("napoleonic"), maps = { "europe" } },
	{ id = "pacificwar", label = Modes.name("pacificwar"), maps = { "pacific" } },
} :: { ModeOption }

-- WHO CAN JOIN (2026-09-17, owner: "for private games, add a public/private
-- setting ... and show individually created games on public setting also
-- there"). PRIVATE is the default and is what every room made before this
-- existed reads as, because an absent index clamps to 1.
--
-- A PUBLIC ROOM STILL HAS ITS CODE. Public does not replace the four digits, it
-- adds a second way in: the room shows up in SEE ALL GAMES and a press there
-- joins it, while the code goes on working for the friends you read it out to.
--
-- IT IS SOLD WITH ADVANCED -- see tierFor, and see the note there for what
-- changed. Every other dial changes the GAME; this one changes who can find it,
-- which is the more valuable of the two and the one worth a pass. What it costs
-- is that the SEE ALL GAMES list is stocked with player rooms only by accounts
-- that bought in -- survivable, because the five lobbies the game itself hosts
-- are in that list for everybody and are most of it.
PrivateLobby.ACCESS = { "PRIVATE", "PUBLIC" }
PrivateLobby.ACCESS_SLOT = 6

-- Which slot of `rec.s` holds the mode: AFTER the four the wire has always
-- carried, so a record written before it existed reads as CLASSIC and an old
-- server reading a new record simply never looks.
PrivateLobby.MODE_SLOT = 5

-- FREE FOR ALL is the only one spelled out; the rest are built from CAP by
-- `label` below, as "3 TEAMS OF 8". A team count on its own does not say what
-- the host is actually choosing, which is how many people end up on a side --
-- and the room's own cap is the number that decides it. Kept in step with
-- Matchmaker.modeLabel, which does the same thing to the public board's cards.
local FFA_LABEL = "FREE FOR ALL"
local TROOP_LABEL = { "HALF", "NORMAL", "DOUBLE", "QUADRUPLE" }
local GOLD_LABEL = { "NONE", "5,000", "25,000", "100,000" }

-- Five rows, in the order the panel draws them. `slot` is where each one lives
-- in `rec.s`, which is NOT the draw order: MODE is drawn first because it
-- decides what the rows under it may hold, and stored fifth because the other
-- four were on the wire first.
export type Field = {
	key: string,
	label: string,
	slot: number, -- which index of `rec.s` this row owns
}

PrivateLobby.FIELDS = {
	-- FIRST, and it is a deliberate promotion: it decides whether the room can
	-- be FOUND at all, which is a bigger decision than any dial under it.
	--
	-- It went first partly because it was the one row never locked, and it is
	-- locked now (2026-09-17) -- but the order stands, because MODE was already
	-- ADVANCED and sat here before it: the panel has always opened on a row
	-- most players have to buy. The two gated rows being adjacent is the better
	-- arrangement anyway -- what a pass opens reads as one block rather than as
	-- locks scattered down the list.
	{ key = "access", label = "WHO CAN JOIN", slot = 6 },
	{ key = "mode", label = "MODE", slot = 5 },
	{ key = "map", label = "MAP", slot = 1 },
	{ key = "teams", label = "TEAMS", slot = 2 },
	{ key = "troops", label = "STARTING TROOPS", slot = 3 },
	{ key = "gold", label = "STARTING GOLD", slot = 4 },
} :: { Field }

-- Defaults are the FIRST map, free-for-all and the sim's own numbers, so a
-- host who touches nothing gets exactly the game the public board serves.
function PrivateLobby.defaults(): { number }
	return { 1, 1, 2, 1, 1, 1 }
end

function PrivateLobby.count(field: string): number
	if field == "map" then
		return #PrivateLobby.MAP
	elseif field == "teams" then
		return #PrivateLobby.TEAMS
	elseif field == "troops" then
		return #PrivateLobby.TROOPS
	elseif field == "mode" then
		return #PrivateLobby.MODES
	elseif field == "access" then
		return #PrivateLobby.ACCESS
	end
	return #PrivateLobby.GOLD
end

function PrivateLobby.label(field: string, index: number, s: any?): string
	if field == "access" then
		return PrivateLobby.ACCESS[index] or PrivateLobby.ACCESS[1]
	elseif field == "mode" then
		return (PrivateLobby.MODES[index] or PrivateLobby.MODES[1]).label
	elseif field == "map" then
		return string.upper(Maps.get(PrivateLobby.MAP[index] or PrivateLobby.MAP[1]).NAME)
	elseif field == "teams" then
		local teams = PrivateLobby.TEAMS[index] or PrivateLobby.TEAMS[1]
		if teams <= 0 then
			return FFA_LABEL
		end
		-- THE ROOM'S OWN CEILING, not the flat CAP: a map may lower it
		-- (Maps.MapData.MAX_EMPIRES -- Korea holds two), and a row reading
		-- "2 TEAMS OF 12" beside a counter reading "1 / 2" promises seats the
		-- join is refused at. capFor resolves `s` itself and falls back to the
		-- flat CAP when there is none, so a caller without settings is unchanged.
		-- Kept in step with Matchmaker.modeLabel, which divides the record's cap.
		local cap = PrivateLobby.capFor(s)
		return string.format("%d TEAMS OF %d", teams, math.max(1, math.floor(cap / teams)))
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
	for _, f in PrivateLobby.FIELDS do
		local v = tonumber((s :: any)[f.slot])
		if v then
			-- By SLOT, not by draw order. They were the same number until
			-- MODE was drawn first and stored fifth.
			out[f.slot] = math.clamp(math.floor(v), 1, PrivateLobby.count(f.key))
		end
	end
	return out
end

-- --------------------------------------------------------------- modes ----

-- The mode option a settings block has chosen.
function PrivateLobby.modeOption(s: { number }): ModeOption
	return PrivateLobby.MODES[s[PrivateLobby.MODE_SLOT] or 1] or PrivateLobby.MODES[1]
end

-- May the map at `mapIndex` be played in this mode? No `maps` list means anywhere.
local function mapAllowed(opt: ModeOption, mapIndex: number): boolean
	local maps = opt.maps
	return maps == nil or table.find(maps, PrivateLobby.MAP[mapIndex]) ~= nil
end

local function slotOf(field: string): number
	for _, f in PrivateLobby.FIELDS do
		if f.key == field then
			return f.slot
		end
	end
	return 1
end

-- THE MODE PINS WHAT IT CANNOT PLAY. Raw indexes in, the ones the round will
-- actually use out: a map the mode has no scenario for becomes the mode's
-- first map, and a predrawn-borders round is a free-for-all (Modes.historical
-- has TEAMS 0) whatever the TEAMS row was left on. The panel draws through
-- this and the launch builds through it, so a room can never show a game the
-- server would not start.
--
-- The RAW indexes are what a host's steppers keep, which is why switching back
-- to CLASSIC finds the map and teams exactly where they were left.
function PrivateLobby.resolve(s: any): { number }
	local idx = PrivateLobby.clampSettings(s)
	local opt = PrivateLobby.modeOption(idx)
	local maps = opt.maps
	if maps and not mapAllowed(opt, idx[slotOf("map")]) then
		idx[slotOf("map")] = table.find(PrivateLobby.MAP, maps[1]) or 1
	end
	-- EVERY MODE PAST CLASSIC IS A FREE-FOR-ALL -- Modes gives TEAMS 0 to
	-- historical and to every special -- so the TEAMS row is pinned for all of
	-- them, not only for the ones that carry a map list.
	if opt.id ~= "classic" then
		idx[slotOf("teams")] = 1
	end
	return idx
end

-- HOW MANY PEOPLE THIS ROOM MAY ACTUALLY HOLD (2026-09-16).
--
-- `CAP` is the ceiling the SIM is tuned for. A MAP may state a smaller one --
-- Maps.MapData.MAX_EMPIRES -- and Korea is a 1v1, so a room on Korea holds
-- TWO. Until this existed that number was read in only two places, the public
-- board's card (Matchmaker.newRecord) and the bot fill (ConquestServer), and
-- BOTH of those only ever cap the AI. Humans were added unconditionally, so a
-- private room on Korea admitted 24 people and built 24 empires on a map sized
-- and balanced for two.
--
-- On korea/HISTORICAL it was worse than unbalanced. The Korean War scenario
-- claims every playable tile and has exactly two nations, so the third person
-- onward got no nation from Sim.commitHistorical and no ground from
-- Sim.autoSpawn either -- both refuse a tile that is already owned -- and sat
-- through the whole match with no empire, unable even to be eliminated.
-- Refusing the third JOIN is what makes that unreachable.
--
-- Takes RAW settings (a record's `s`) and resolves them itself, so no caller
-- can forget to; nil settings fall through clampSettings to the defaults.
function PrivateLobby.capFor(s: any): number
	local idx = PrivateLobby.resolve(s)
	local mapId = PrivateLobby.MAP[idx[slotOf("map")]] or PrivateLobby.MAP[1]
	local mapCap = tonumber((Maps.get(mapId) :: any).MAX_EMPIRES)
	return if mapCap then math.min(PrivateLobby.CAP, mapCap) else PrivateLobby.CAP
end

-- Whether a row is the MODE's decision rather than the host's. The panel hides
-- its arrows exactly as it hides them from a guest: an arrow that can only land
-- back on the value it started from is not a control.
function PrivateLobby.fixed(field: string, s: any): boolean
	local opt = PrivateLobby.modeOption(PrivateLobby.clampSettings(s))
	if opt.id == "classic" then
		return false
	end
	-- Kept in step with resolve: teams for every mode past CLASSIC, the map
	-- only where the mode has a single one to play.
	return field == "teams" or (field == "map" and opt.maps ~= nil and #opt.maps <= 1)
end

-- One press of an arrow. WRAPS, and on the MAP row steps over whatever the mode
-- cannot play, so a mode with two scenario maps cycles between exactly those.
function PrivateLobby.step(s: any, field: string, delta: number): { number }
	local idx = PrivateLobby.clampSettings(s)
	local slot = slotOf(field)
	local n = PrivateLobby.count(field)
	local opt = PrivateLobby.modeOption(idx)
	local cur = idx[slot]
	for _ = 1, n do
		cur = ((cur - 1 + delta) % n) + 1
		if field ~= "map" or mapAllowed(opt, cur) then
			break
		end
	end
	idx[slot] = cur
	return idx
end

-- -------------------------------------------------------------- passes ----

-- WHICH PASS A ROW NEEDS (2026-09-11). 1 is HOST, 2 is ADVANCED, and a tier is
-- a floor: ADVANCED opens everything HOST does. Shared, so the page's dimmed
-- arrows and the server's refusal cannot disagree about a row.
PrivateLobby.TIER_HOST = 1
PrivateLobby.TIER_ADVANCED = 2

function PrivateLobby.tierFor(field: string): number
	-- ADVANCED OPENS BOTH OF THESE (2026-09-17, owner: "only advanced game join
	-- people can host public games"). ACCESS shipped free a few hours earlier
	-- on the argument that a list nobody without a pass can add to is a list
	-- with almost nothing in it -- which is true, and is the COST of this, not
	-- an objection to it: putting a room in front of strangers is reach, reach
	-- is worth selling, and the board's own five lobbies keep the list stocked
	-- for everybody regardless.
	if field == "mode" or field == "access" then
		return PrivateLobby.TIER_ADVANCED
	end
	return PrivateLobby.TIER_HOST
end

-- Is this room open to strangers? Takes RAW settings and clamps them itself,
-- so no caller can read index 6 off a record that predates it.
function PrivateLobby.isPublic(s: any): boolean
	return PrivateLobby.clampSettings(s)[PrivateLobby.ACCESS_SLOT] == 2
end

-- WHAT A RECORD'S DEADLINE SHOULD BE, given what it is now. Pure, and the only
-- place the rule lives: a public room that has no clock gets one, a room that
-- has stopped being public loses it, and a public room that already has one
-- KEEPS it -- otherwise every settings write (a map change, a troop step)
-- would silently push the start back another two minutes and a host fiddling
-- with the dials would never launch at all.
--
-- CLEARED rather than paused when a room goes private. Resuming a stale clock
-- is the worse of the two: a room that was public for ten seconds an hour ago
-- would go public again and launch instantly, with nobody in it having seen a
-- countdown at all. The cost is that flipping private and back restarts the
-- two minutes, which is a loophole that buys the host nothing they could not
-- get by making a new room.
function PrivateLobby.deadlineFor(rec: any, now: number): number
	if rec.state ~= "open" or not PrivateLobby.isPublic(rec.s) then
		return 0
	end
	local cur = tonumber(rec.deadline) or 0
	if cur > 0 then
		return cur
	end
	return now + PrivateLobby.PUBLIC_START
end

-- Is it time? Everything this asks is re-asked inside the claim transform
-- (MatchmakerServer.claimRoom), because a record read a second ago can have
-- been started, emptied or made private since.
function PrivateLobby.dueToStart(rec: any, now: number): boolean
	if rec.state ~= "open" or not PrivateLobby.isPublic(rec.s) then
		return false
	end
	local at = tonumber(rec.deadline) or 0
	return at > 0 and now >= at and PrivateLobby.members(rec) > 0
end

-- Seconds left, for the page. 0 is "any moment now" and NOT "no clock": a
-- reader tells the two apart from the settings, which already say whether the
-- room is public, so the wire does not need a second way to say it.
function PrivateLobby.remaining(rec: any, now: number): number
	local at = tonumber(rec.deadline) or 0
	if at <= 0 then
		return 0
	end
	return math.max(0, at - now)
end

-- WHAT A HOST MAY CHANGE. Every row this tier does not open keeps the value the
-- room already has -- `current` is the record's settings, or the defaults for a
-- room being created. KEPT rather than reset, so a HOST-only player who
-- inherits a room an ADVANCED host set to HISTORICAL (see `reseat`) can still
-- move the troops without taking the mode away from everybody in it.
function PrivateLobby.allow(want: any, current: any, tier: number): { number }
	local w = PrivateLobby.clampSettings(want)
	local c = PrivateLobby.clampSettings(current)
	for _, f in PrivateLobby.FIELDS do
		if tier < PrivateLobby.tierFor(f.key) then
			w[f.slot] = c[f.slot]
		end
	end
	return w
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
	-- Through `resolve`, so the round is the one the panel showed: a mode's
	-- pinned map and free-for-all win over whatever those rows were left on.
	local idx = PrivateLobby.resolve(s)
	local teams = PrivateLobby.TEAMS[idx[2]] or 0
	local opt = PrivateLobby.modeOption(idx)
	return {
		map = PrivateLobby.MAP[idx[1]] or PrivateLobby.MAP[1],
		mode = if opt.id == "classic" then PrivateLobby.modeFor(teams) else opt.id,
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
	-- WHEN THIS ROOM STARTS WITHOUT BEING TOLD TO, as an absolute os.time(),
	-- or 0 for a room that never does. See PUBLIC_START and `deadlineFor`.
	deadline: number,
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
		-- Born correct rather than born zero, so a room CREATED public is
		-- already counting down when its first wire goes out.
		deadline = 0,
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
--   { code, host, mapIdx, teamsIdx, troopsIdx, goldIdx, stateCode, { userId... }, modeIdx }
--
-- modeIdx is LAST because it came last (2026-09-11): every position before it
-- means what it always meant, so a page from before it still reads the rest.
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
	-- TENTH because it came tenth (2026-09-17), same rule as the mode at nine:
	-- every position before it still means what it always meant.
	-- ELEVENTH because it came eleventh (2026-09-17), same rule as the mode at
	-- nine and the access flag at ten. Sent as SECONDS LEFT rather than as the
	-- absolute deadline so the page never has to agree with the server about
	-- what time it is -- the card clocks next door have always worked this way.
	return { rec.code, rec.host, s[1], s[2], s[3], s[4], STATE_CODE[rec.state] or 1, users, s[5] or 1, s[6] or 1,
		PrivateLobby.remaining(rec, now) }
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
	-- Seconds until it starts by itself. Meaningless unless the room is public
	-- and open -- see PrivateLobby.remaining.
	remaining: number,
}

function PrivateLobby.readWire(w: { any }, myUserId: number): View?
	if type(w) ~= "table" or type(w[1]) ~= "string" then
		return nil
	end
	local users = w[8] or {}
	return {
		code = w[1],
		host = w[2] or 0,
		settings = PrivateLobby.clampSettings({ w[3], w[4], w[5], w[6], w[9], w[10] }),
		state = CODE_STATE[w[7]] or "open",
		users = users,
		count = #users,
		mine = table.find(users, myUserId) ~= nil,
		isHost = w[2] == myUserId,
		remaining = math.max(0, tonumber(w[11]) or 0),
	}
end

-- ------------------------------------------------------------- listing ----
--
-- ONE PUBLIC ROOM AS A STRANGER SEES IT, which is much less than its members
-- see. The room's own wire goes only to the people in it and carries their user
-- ids; this goes to anybody with SEE ALL GAMES open, so it carries the map, the
-- shape of the game, how full it is and the code that joins it -- and of the
-- people in it, only the HOST, whose avatar the row draws.
--
-- NO NAMES ANYWHERE IN IT. A display name is already filtered by the platform,
-- but a name in a cross-server store is a name this game would then have to
-- keep filtered forever; a user id costs nothing and the client turns it into
-- the same avatar head the lobby cards already draw.
export type Listing = {
	code: string,
	settings: { number },
	count: number,
	cap: number,
	host: number,
	-- A LISTED ROOM ALWAYS HAS A CLOCK, because a listed room is public by
	-- definition and every public room starts on its own. This is what lets
	-- the sheet draw a room's row with the same countdown it draws on the
	-- game's own lobbies.
	remaining: number,
}

function PrivateLobby.listing(rec: Record, now: number): { any }
	local s = PrivateLobby.clampSettings(rec.s)
	local live = 0
	for _, e in rec.servers do
		if (now - (e.t or 0)) <= PrivateLobby.MEMBER_STALE then
			live += #e.u
		end
	end
	return { rec.code, s[1], s[2], s[3], s[4], s[5], live, PrivateLobby.capFor(s), rec.host,
		PrivateLobby.remaining(rec, now) }
end

function PrivateLobby.readListing(w: any): Listing?
	if type(w) ~= "table" or type(w[1]) ~= "string" then
		return nil
	end
	return {
		code = w[1],
		-- Index 6 of the wire is the MODE and index 6 of the settings is
		-- ACCESS, which is not on this wire at all: a room that is listed is
		-- public by definition, so sending the flag would be sending a
		-- constant. Rebuilt as PUBLIC here so a reader that asks is not lied to.
		settings = PrivateLobby.clampSettings({ w[2], w[3], w[4], w[5], w[6], 2 }),
		count = tonumber(w[7]) or 0,
		cap = tonumber(w[8]) or PrivateLobby.CAP,
		host = tonumber(w[9]) or 0,
		remaining = math.max(0, tonumber(w[10]) or 0),
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
