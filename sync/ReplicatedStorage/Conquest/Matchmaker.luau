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
Matchmaker.VERSION = 2

-- STUDIO GETS ITS OWN BOARD, and this is not a nicety. A Studio session polls
-- the same universe's MemoryStore as every live server, so without the suffix
-- it could win the race to claim a REAL lobby full of REAL players and then
-- fail at ReserveServer (which does not exist in Studio) -- stranding them.
-- Two Studio instances still share the studio board, which is what makes the
-- cross-server test possible without shipping anything.
local STORE_SUFFIX = RunService:IsStudio() and "_studio" or ""
-- The lobby board's shape CHANGED with the always-running clock (`deadline` is
-- now set at birth rather than on the first join), so the store name carries
-- VERSION and a v1 record can never be read by a v2 server. The MATCH store is
-- deliberately left at v1: nothing about a match record moved, and bumping it
-- would strand any launch already in flight during a rolling update.
Matchmaker.STORE = "ConquestLobbies_v" .. Matchmaker.VERSION .. STORE_SUFFIX
Matchmaker.MATCH_STORE = "ConquestMatches_v1" .. STORE_SUFFIX
-- HOW BIG THE BOARD IS RIGHT NOW, and when it last grew: one record shared by
-- every server -- see paceBoard. Three days of life, refreshed by every step.
Matchmaker.BOARD_STORE = "ConquestBoard_v1" .. STORE_SUFFIX
Matchmaker.BOARD_KEY = "size"
Matchmaker.BOARD_TTL = 3 * 86400
-- WHERE EVERY PERSON IN A MATCH IS: userId (as a string) -> the access code of
-- the reserved server they are playing in, plus `tutorial`/`private` flags.
-- Written by the match server on arrival and cleared on leaving
-- (ConquestServer.publishWhere), read by a lobby that received somebody who
-- pressed JOIN on a friend (MatchmakerServer.followFriend). The platform's own
-- join cannot enter a reserved server; this is what lets the game finish it.
Matchmaker.WHERE_STORE = "ConquestWhere_v1" .. STORE_SUFFIX

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
-- ...and how many of that card's seats were PHANTOM, which is exactly how many
-- empires the round then has to make look like people. See ConquestServer's
-- faux roster: the card promised these, so the match owes them.
Matchmaker.LOCAL_PHANTOMS_ATTR = "ConquestLocalPhantoms"
-- ...and whether this round is the TUTORIAL, which is a round shape (a small
-- fixed roster, a grace window, a starting treasury) plus a lesson track. On a
-- reserved server it rides in the match record as `tutorial`; in Studio, where
-- there is no reserved server to key a record by, it rides here.
Matchmaker.LOCAL_TUTORIAL_ATTR = "ConquestLocalTutorial"
-- ...and the CLAN TAGS of the people who queued here, as a JSON object keyed by
-- userId. Same reason as every attribute above it: on a reserved server the
-- tags ride in the teleport data, and a Studio round that starts in the session
-- it was queued in has no teleport to ride in.
Matchmaker.LOCAL_TAGS_ATTR = "ConquestLocalTags"

-- THE WHOLE WAIT HAS A TWO-MINUTE CEILING (owner, 2026-09-03: "no game should
-- take more than 2 minutes to start"), and this is the dial that decides it.
--
-- The budget, worst case, from joining a card to the round beginning:
--   COUNTDOWN + MIN_FRESH   the longest clock nextDeadline can mint
--   + ~20s                  claim, ReserveServer, teleport and load
--   + BOARD_GRACE           the match server holding for late arrivals
-- At 120 + 40 that came to 2:40 before a single teleport had happened, and
-- about 3:25 end to end. At 60 + 20 it is 80 + 20 + 15 = 1:55, inside the
-- ceiling with the spawn-placement window (Config.SPAWN_PHASE_SECONDS) landing
-- after the round has begun rather than inside the wait.
--
-- SHORTENING THIS COSTS HUMAN ROSTER SIZE, not matches: `shouldLaunch` already
-- fires the instant a card is full, and LAUNCH_MIN is 1, so a short clock never
-- blocks a launch -- it just gathers fewer people per card before going. That
-- is the trade the ceiling buys.
Matchmaker.COUNTDOWN = 60 -- 1:00, and a record is born already counting down
Matchmaker.RECORD_TTL = 900 -- an abandoned record evaporates rather than lingering
Matchmaker.MATCH_TTL = 3600 -- a WHERE entry outlives the longest possible round
-- THE MATCH RECORD ITSELF LIVES TEN MINUTES, NOT AN HOUR (2026-09-20). The
-- match server reads it exactly once, at boot, ten to thirty seconds after the
-- lobby wrote it -- and then deletes it (ConquestServer.bootMatch). It used to
-- share MATCH_TTL, so every launch of the past hour sat in the store as dead
-- weight: public cards, private rooms and every tutorial, each carrying the
-- long access code. At 2k CCU the Memory Stores dashboard put the store at
-- 91% of its MEMORY quota (64 KB + 1.2 KB per concurrent user) and climbing,
-- and at 100% every write that grows a record fails -- including the one that
-- puts the access code on a launching card, which froze every card at 0:00.
-- Ten minutes is the safety net for a match server that never booted.
Matchmaker.MATCH_RECORD_TTL = 600
Matchmaker.CLAIM_STALE = 15 -- a claim older than this may be stolen
Matchmaker.READY_HOLD = 10 -- how long the access code stays readable, AT MOST
-- ...AND THE FLOOR UNDER THE EARLY RESET. A launched card used to sit on the
-- page reading STARTING for the whole hold (owner, 2026-09-17: "these cards
-- [stay] for a decent long time before actually disappearing" -- about 15 s
-- from filling to the fresh card). Every server clears its own players from
-- the record the moment their teleport succeeds (sendToMatch), so a real count
-- of zero is a positive acknowledgement that everybody has been sent, and
-- `readyDone` resets the slot on it. The floor is the one hole that signal
-- has: a server whose record entry was swept while it still held people sends
-- them off `mine`, not off the record, and reaches the code on its next 1 s
-- poll -- three polls is the margin. READY_HOLD stays as the fallback for a
-- server that died or whose teleport failed twice (its entry is never cleared).
Matchmaker.READY_MIN = 3
Matchmaker.MEMBER_STALE = 20 -- a server that has not checked in this long is gone
Matchmaker.HEARTBEAT = 5 -- how often a server refreshes its own entry
Matchmaker.POLL = 1 -- how often a server reads the board
Matchmaker.PUSH = 5 -- ...and pushes it to clients even when nothing changed
-- A CEILING, NOT A WAIT: the match server breaks out the moment the roster the
-- lobby promised has landed, so this is only paid when somebody quit during
-- their own teleport. Trimmed with COUNTDOWN above -- it is the last thing
-- standing between the player and the map.
Matchmaker.BOARD_GRACE = 15 -- how long a match server waits for arrivals
Matchmaker.LAUNCH_MIN = 1 -- one human plus the bot roster is a real game

-- ------------------------------------------------------------- clan tags ---
--
-- A CLAN TAG IS A TEAM KEY AND NOTHING ELSE (2026-09-01, owner: "ensure players
-- with the same tag are on the same team"). Type the same four characters as
-- your friends on the lobby page and the match puts you on the same side --
-- Sim.addPlayer reads it, and nothing else in the game does.
--
-- IT IS NEVER DRAWN FOR ANYONE BUT ITS AUTHOR, and that is deliberate rather
-- than unfinished: the only place the string appears is the box the person
-- typed it into. An arbitrary player-authored string on somebody ELSE'S screen
-- is the thing that has to go through TextService first (see ConquestNames,
-- which exists for exactly that reason on the empire name), and a key nobody
-- can see needs no filtering at all. If a tag ever becomes visible -- a bloc
-- label on the map, a column in the standings -- it has to be filtered on that
-- day, and this comment is the warning.
--
-- NORMALISED ON BOTH SIDES OF THE WIRE. The page uppercases and strips
-- punctuation as you type; this runs again on the server, because a client can
-- send whatever it likes and "ab", " AB " and "A.B" must be one clan and not
-- three. Spaces and hyphens go here (the page allows them) so that a tag which
-- LOOKS the same to two friends who typed it slightly differently still is.
Matchmaker.TAG_MAX = 4

function Matchmaker.normaliseTag(raw: any): string
	if typeof(raw) ~= "string" then
		return ""
	end
	local s = string.gsub(string.upper(raw), "[^%w]", "")
	return string.sub(s, 1, Matchmaker.TAG_MAX)
end

-- --------------------------------------------------------------- phantoms ---

-- A CARD IS NEVER EMPTY AND ITS CLOCK NEVER STOPS. Three lobbies reading
-- 0 / 6 over a frozen 2:00 is a page that says nobody plays this, and the only
-- thing a new arrival does with a page like that is leave. Every lobby
-- generation is therefore born already counting down and already holding one
-- or two PHANTOM seats.
--
-- A PHANTOM IS A SEAT, NOT A PERSON. It occupies the card's cap and it is
-- counted in what the card displays; it is counted by NOTHING that decides
-- whether to reserve a server. `count` is real players, `seats` is what the
-- card shows, and having those two the wrong way round is the one dangerous
-- mistake available here: an empty lobby that believes it holds a player
-- reserves a match server every two minutes, for each of three slots, forever.
--
-- The number is derived from the record's OWN id, so every server of the
-- experience draws the same card with no extra byte in the store and no write
-- to agree on -- and it is redrawn when the lobby rolls over, which is what
-- makes an idle page look like it is breathing rather than stuck.
Matchmaker.PHANTOM_MIN = 1
Matchmaker.PHANTOM_MAX = 2

-- djb2 over the id. Hand-rolled because this has to agree BETWEEN SERVERS and
-- across sessions, and no hash Roblox exposes promises that; byte arithmetic
-- does.
local function hashOf(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 4294967296
	end
	return h
end

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
-- `flex` is a slot whose SIZE is not written here. See SLOTS below: the last
-- nine are dealt by Demand out of what the past hour actually joined, so their
-- cap, their name and their blurb all come off the record they are minted with
-- rather than off this table. The three fixed slots are the ladder the extras
-- choose from, which is why the ladder lives in the first three entries and
-- nowhere else.
export type Slot = {
	key: string,
	name: string,
	cap: number,
	blurb: string,
	flex: boolean?,
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
	-- THE EXTRAS (2026-09-17, owner: "that way we can start a lobby people
	-- actually want"; 2026-09-19, "add 2 more games for everyone to
	-- potentially join", then "if traffic demands it, add even more games").
	-- Everything above this line is a fixed rung of the ladder; these are
	-- whatever the last hour says this population turns up for -- see Demand,
	-- and `newRecord`'s `want`.
	--
	-- THEY ARE NOT ON THE PAGE, and that is what makes them safe. The page has
	-- three card frames and draws the best three of whatever the board holds
	-- (LobbyUI.rankBoard), so a badly-chosen extra costs a row in the SEE ALL
	-- GAMES list and nothing on the front page. It is also why the board can
	-- change size without layout work: every loop runs off this table, the
	-- wire carries one entry per slot, and the sheet lists whatever the cards
	-- did not take.
	--
	-- FOUR ARE THE FLOOR AND FIVE MORE ARE ELASTIC. Slots 4-7 are always
	-- minted (MIN_SLOTS); slots 8-12 exist only while the hour's traffic asks
	-- for them (slotsFor, one step an hour: paceBoard) and retire at their next
	-- EMPTY rollover when
	-- it stops -- never out from under a player. Twelve is the ceiling because
	-- NO TWO LOBBIES SHARE A MAP (drawPair's `freshMap`) and the rotation
	-- holds fourteen: twelve lobbies is twelve distinct maps with two to
	-- spare. Trim the rotation below the ceiling and the rule falls back.
	--
	-- The caps here are only the COLD START -- the first hour of a fresh
	-- universe, and any hour too quiet to read (Demand.MIN_JOINS). Sixes and
	-- twelves on the floor, because the small cards are the ones that fill,
	-- and a list whose extra rows never reach a roster is a longer list, not
	-- a better one; the elastic five carry one twenty-four, because they only
	-- exist under the kind of traffic that fills one. With evidence,
	-- `Demand.bestSize` divides joins by the seats each size is already
	-- offering, so the extras do not all copy one size: each one minted at a
	-- size makes that size look less under-served to the next.
	{
		key = "slot4",
		name = "SKIRMISH",
		cap = 6,
		blurb = "Fills fast. First war of the evening.",
		flex = true,
	},
	{
		key = "slot5",
		name = "BATTLE",
		cap = 12,
		blurb = "A full board without the wait.",
		flex = true,
	},
	{
		key = "slot6",
		name = "SKIRMISH",
		cap = 6,
		blurb = "Fills fast. First war of the evening.",
		flex = true,
	},
	{
		key = "slot7",
		name = "BATTLE",
		cap = 12,
		blurb = "A full board without the wait.",
		flex = true,
	},
	-- The elastic five. Cold-start caps only, like the four above.
	{
		key = "slot8",
		name = "SKIRMISH",
		cap = 6,
		blurb = "Fills fast. First war of the evening.",
		flex = true,
	},
	{
		key = "slot9",
		name = "BATTLE",
		cap = 12,
		blurb = "A full board without the wait.",
		flex = true,
	},
	{
		key = "slot10",
		name = "WORLD WAR",
		cap = 24,
		blurb = "Every commander the map will hold.",
		flex = true,
	},
	{
		key = "slot11",
		name = "SKIRMISH",
		cap = 6,
		blurb = "Fills fast. First war of the evening.",
		flex = true,
	},
	{
		key = "slot12",
		name = "BATTLE",
		cap = 12,
		blurb = "A full board without the wait.",
		flex = true,
	},
} :: { Slot }

-- HOW MANY OF THOSE SLOTS ARE LIVE (2026-09-19, owner: "if traffic demands
-- it, add even more games"). The first MIN_SLOTS are always minted; the rest
-- are minted only while the past hour's joins justify them, and a slot the
-- hour no longer justifies is RETIRED at its next empty rollover -- never
-- while anybody is in it (MatchmakerServer.tick).
--
-- THE UNIT IS JOINS PER LOBBY PER COUNTDOWN. A lobby taking LOAD_PER_SLOT
-- joins every clock is a lobby that is being used, and the board is sized so
-- that every lobby on it is: the hour's joins, divided by what one lobby
-- should carry in an hour, is how many lobbies this traffic wants. Clamped to
-- the floor and to the table above. It reads the same tally Demand steers
-- the extras with, so every server of the experience sizes the board the
-- same way within a minute of each other (MatchmakerServer.DEMAND_POLL) --
-- and an unreachable store reads as zero joins, which is the floor.
--
-- At COUNTDOWN 60 and LOAD_PER_SLOT 2 that is one lobby per 120 joins an
-- hour: the eighth slot is justified at 960 joins an hour, the twelfth at
-- 1,440. Below 960 the four extras are still there -- the floor never moves.
-- This is what the traffic JUSTIFIES; how fast the board is allowed to get
-- there is paceBoard's business, below.
Matchmaker.MIN_SLOTS = 7
Matchmaker.LOAD_PER_SLOT = 2

function Matchmaker.slotsFor(joinsPerHour: number): number
	local perSlot = Matchmaker.LOAD_PER_SLOT * (3600 / Matchmaker.COUNTDOWN)
	local wanted = math.floor(math.max(0, joinsPerHour) / perSlot)
	return math.clamp(wanted, Matchmaker.MIN_SLOTS, #Matchmaker.SLOTS)
end

-- ONE MORE LOBBY PER HOUR, AT MOST (2026-09-19, owner: "each additional hour
-- can only +1 the # of lobbies"). slotsFor says how many lobbies the traffic
-- justifies; this says how far the board may move towards that number right
-- now. UP is a step of one, and no sooner than GROW_EVERY after the last
-- step; DOWN is not paced -- the board drops to what the hour justifies and
-- the surplus slots retire at their next empty rollover (MatchmakerServer.
-- tick). So a universe that is suddenly busy opens its eighth lobby the
-- minute the tally says so, its ninth an hour after that, and all twelve
-- four hours later still -- and one that goes quiet is back at the floor
-- within the hour the tally takes to empty.
--
-- `old` is the shared record (MatchmakerServer.boardStore) or nil; anything
-- that does not parse reads as the floor with no step on record, which is
-- the state a fresh universe is in. A step down KEEPS `grewAt`: the hour is
-- measured from the last step up, so a board hovering around a threshold can
-- climb at most once an hour however often it falls.
--
-- Returns the record as it should now be, and whether that differs from
-- `old` -- the caller writes only on true, and re-runs this INSIDE the write.
Matchmaker.GROW_EVERY = 3600

export type BoardSize = { live: number, grewAt: number }

function Matchmaker.paceBoard(old: any, wanted: number, now: number): (BoardSize, boolean)
	local floor, ceiling = Matchmaker.MIN_SLOTS, #Matchmaker.SLOTS
	local live = if type(old) == "table" and type(old.live) == "number" then old.live else floor
	local grewAt = if type(old) == "table" and type(old.grewAt) == "number" then old.grewAt else 0
	live = math.clamp(math.floor(live), floor, ceiling)
	wanted = math.clamp(math.floor(wanted), floor, ceiling)
	if wanted > live then
		if now - grewAt >= Matchmaker.GROW_EVERY then
			return { live = live + 1, grewAt = now }, true
		end
		return { live = live, grewAt = grewAt }, false
	elseif wanted < live then
		return { live = wanted, grewAt = grewAt }, true
	end
	return { live = live, grewAt = grewAt }, false
end

-- THE LADDER, WHICH IS THE FIXED SLOTS AND NOTHING ELSE. A flex slot minted at
-- twelve seats has to read BATTLE, not "slot5" and not the name its table entry
-- happens to be carrying from last hour's pick -- so the name is looked up from
-- the size, against the three rungs, every time it is drawn.
--
-- Falls back to the slot's own name for a size that is on no rung, which is
-- what a map cap does (Korea is a 1v1). That case cannot reach here -- `size`
-- is the INTENDED size and the map cap lowers `cap` only -- but a lookup that
-- can return nil into a card's title is not worth the saving.
function Matchmaker.ladder(): { number }
	local out = {}
	for _, slot in Matchmaker.SLOTS do
		if not slot.flex then
			table.insert(out, slot.cap)
		end
	end
	return out
end

function Matchmaker.rungFor(size: number): Slot?
	for _, slot in Matchmaker.SLOTS do
		if not slot.flex and slot.cap == size then
			return slot
		end
	end
	return nil
end

-- ------------------------------------------------------------ staggering ---

-- THE THREE CLOCKS MUST NEVER READ THE SAME TIME. All three records are minted
-- in one pass of one tick, so a plain `now + COUNTDOWN` gave them the same
-- deadline to the second: three cards reading 1min 52s, all reaching zero
-- together, all rolling over into a fresh 2:00 together, forever. A page like
-- that has one clock on it, and somebody who walks on during the shared lull
-- finds nothing about to start anywhere.
--
-- Each slot instead counts on its OWN lattice -- a COUNTDOWN-second grid,
-- offset by an equal share of the countdown per slot. Twelve slots in the
-- table now (live or not -- a lattice belongs to the SLOT, so a slot that
-- retires and comes back keeps its place), so the clocks sit permanently a
-- TWELFTH OF THE COUNTDOWN apart -- five seconds at the current minute (a
-- third, twenty seconds, when there were three): whichever three the page
-- shows, no two of them read the same time.
--
-- SNAPPING TO A GRID, rather than subtracting an offset once at birth, is what
-- makes the spread SURVIVE. A launch, an emptied lobby and a rollover each
-- reset a deadline at an arbitrary second; a one-time offset is lost at the
-- first of them, and two slots that ever landed on the same second would stay
-- together for the life of the server. Every deadline in this project is set
-- through here, so the spacing is a property of the SLOT and not of its
-- history.
--
-- MIN_FRESH is why this never hands somebody a two-second lobby: a reset that
-- lands just short of its own grid point takes the next one instead. A fresh
-- clock is therefore between MIN_FRESH and MIN_FRESH + COUNTDOWN -- 0:20 to
-- 1:19 now -- and the slots are still a twelfth of the countdown apart.
--
-- IT IS ALSO HALF THE CEILING. The longest wait anybody can be handed is this
-- plus COUNTDOWN, so the two move together; raising this alone would quietly
-- put the worst case back over two minutes. See COUNTDOWN for the budget.
Matchmaker.MIN_FRESH = 20

function Matchmaker.nextDeadline(slotIndex: number?, now: number): number
	local n = #Matchmaker.SLOTS
	local span = Matchmaker.COUNTDOWN
	local phase = math.floor(span * (((slotIndex or 1) - 1) % n) / n)
	return math.ceil((now + Matchmaker.MIN_FRESH - phase) / span) * span + phase
end

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
	-- THE SIZE THIS CARD MEANT TO BE, which is not always the size it is. `cap`
	-- is what the card advertises and a MAP may lower it (Korea is a 1v1, so a
	-- WORLD WAR card on Korea caps at two); `size` is the rung of the ladder
	-- the slot was minted at, and it is what names the card. Without the two
	-- being separate, a flex slot that drew Korea would read SKIRMISH for a
	-- round and then change its name when the map rolled over.
	size: number,
	cap: number,
	state: string, -- "open" | "claim" | "ready" | "retired" (a tombstone -- see `wire`)
	deadline: number, -- os.time() the clock runs out; ALWAYS running
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

-- Every (map, mode) pair, in a fixed order so every server enumerates them
-- identically: each rotation map in each rotation mode, then the HISTORICAL
-- pairing on each rotation map that has a scenario drawn (2026-09-11, owner:
-- "wire up historcal mode into the game"). Never historical on a map without
-- one -- that would be a free-for-all wearing the wrong name.
--
-- SERVER-ONLY, which is why Scenarios is required here and not at the top:
-- it pulls in the generated scenario data (WW2Scenario, 42 KB), and this
-- module is also loaded by the lobby CLIENT, which only decodes the wire.
function Matchmaker.allPairs(): { { map: string, mode: string } }
	local out = {}
	for _, m in Maps.ORDER do
		for _, g in Modes.ORDER do
			table.insert(out, { map = m, mode = g })
		end
	end
	-- Every scenario on a rotation map, whatever its mode (2026-09-24: WW1 on
	-- the World, the Napoleonic Wars on Europe, the Pacific War on the Pacific
	-- joined 1938 and Korea). Scenarios.pairs is already in a fixed order.
	local Scenarios = require(script.Parent.Scenarios)
	for _, p in Scenarios.pairs() do
		if table.find(Maps.ORDER, p.map) then
			table.insert(out, p)
		end
	end
	return out
end

-- THE MODE A CARD COUNTS AS for drawPair's "a mode nobody else is showing"
-- rule. Every scenario is its own mode id, but they are ONE kind of card: left
-- as four separate modes, four scenario pairings would each look "fresh" beside
-- a board of free-for-alls and the page would fill with history. Folded into
-- one bucket, a second scenario card is exactly as fresh as a second historical
-- card was when there was only one scenario mode.
local function modeBucket(mode: string): string
	return if Modes.isHistorical(mode) then "historical" else mode
end

-- HOW OFTEN A HISTORICAL CARD IS DEALT: this many entries in the draw pool,
-- against one for every other pairing. ONE, and measured rather than
-- reasoned: drawPair already prefers a card whose MODE is on no other card,
-- and historical is a mode of its own, so once two cards are up it is one of
-- the few "fresh" choices left. A steady-state board (one card redrawn at a
-- time against the other two, 30,000 redraws) had a historical card up 21.7%
-- of the time at 1 -- about as often as any one map is (the US: 25%) --
-- then 34.4% at 2 and 45.3% at 3. Raise it to push the mode.
-- Re-measured 2026-09-19 (fourteen maps, the special draw in front of the
-- ordinary pool, and drawPair's newMap fallback tier): 27.8% at 1, with a
-- special up 16.2% of the time. Same harness, same three rungs.
Matchmaker.HISTORICAL_WEIGHT = 1

-- THE SPECIAL PAIRINGS (2026-09-18, owner: "special modes that occasionally
-- appear ... Starting 1 Million Gold. Starting 1 Million Army ... Everyone
-- starts with 10 Nukes"): every special mode (Modes.SPECIAL) on every rotation
-- map. Kept OUT of allPairs, so the ordinary draw and the historical weighting
-- above are untouched; drawPair reaches for this list on its own terms.
function Matchmaker.specialPairs(): { { map: string, mode: string } }
	local out = {}
	for _, g in Modes.specialIds() do
		for _, m in Maps.ORDER do
			table.insert(out, { map = m, mode = g })
		end
	end
	return out
end

-- HOW OFTEN A SPECIAL CARD IS DEALT: the chance, per fresh card, that the draw
-- is taken from specialPairs instead of the ordinary pool -- and never while a
-- special is already up (drawPair). Set by the measured share of the time the
-- board shows one, not by this figure; see the note under drawPair.
Matchmaker.SPECIAL_CHANCE = 0.06

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
--
-- `freshMap` turns the map half of that preference into a RULE (2026-09-17,
-- owner: "for the 2 extra games, make sure they're never the same Map. they can
-- be the same mode"). The flex slots pass it; the three fixed rungs do not, so
-- nothing about the original three changed.
--
-- A PREFERENCE AND A RULE ARE NOT THE SAME THING, which is the whole reason
-- this argument exists. `fresh` below has always preferred a card sharing
-- neither map nor mode -- but it FALLS BACK to merely-distinct and then to
-- anything, because a draw that can fail is a page that can go blank. That
-- fallback is exactly how two extras could land on one map. With `freshMap` the
-- fallback is taken INSIDE the set of unused maps instead of outside it, and
-- only an empty set of those -- which needs every map in the rotation already
-- on a card -- gives the old behaviour back.
function Matchmaker.drawPair(used: { { map: string, mode: string } }?, freshMap: boolean?): (string, string)
	local pairSeen, mapSeen, modeSeen = {}, {}, {}
	local specialUp = false
	for _, u in used or {} do
		pairSeen[Matchmaker.pairKey(u.map, u.mode)] = true
		mapSeen[u.map] = true
		modeSeen[modeBucket(u.mode)] = true
		specialUp = specialUp or Modes.isSpecial(u.mode)
	end
	-- A SPECIAL CARD, NOW AND THEN (2026-09-18). ONE at a time -- a special
	-- anywhere on the board rules them all out of this draw -- and otherwise a
	-- coin at SPECIAL_CHANCE. The special pool keeps the nesting the ordinary
	-- one has below (a map nobody is showing first, then merely a pair nobody
	-- is showing), and under `freshMap` it never falls back outside the unused
	-- maps: an empty set there hands the draw to the ordinary pool rather than
	-- breaking the map rule for a special.
	--
	-- A COIN, NOT A WEIGHT, because the weight above cannot go below one copy
	-- and one copy of 42 special pairings against 44 ordinary ones would be a
	-- board that is special half the time. MEASURED the way HISTORICAL_WEIGHT
	-- was (five slots, one redrawn at a time against the other four, 30,000
	-- redraws): the share of the time a special is somewhere on the board is
	-- 13.5% at 0.03, 25.2% at 0.06 and 35.3% at 0.10 -- and on the three
	-- fixed rungs, which are the front page, 7.9% / 15.7% / 21.0%. Never two
	-- at once. The closed form for a board of n slots, n*c / (1 + (n-1)*c),
	-- lands within a point of all three, so the next dial can be reasoned
	-- rather than re-measured: 0.06 is a special on the page about one board
	-- in six, each of the three about one in twelve.
	if not specialUp and math.random() < Matchmaker.SPECIAL_CHANCE then
		local sDistinct, sNewMap = {}, {}
		for _, p in Matchmaker.specialPairs() do
			if not pairSeen[Matchmaker.pairKey(p.map, p.mode)] then
				table.insert(sDistinct, p)
				if not mapSeen[p.map] then
					table.insert(sNewMap, p)
				end
			end
		end
		local sPool = if freshMap then sNewMap else (#sNewMap > 0 and sNewMap or sDistinct)
		if #sPool > 0 then
			local pick = sPool[math.random(1, #sPool)]
			return pick.map, pick.mode
		end
	end
	local all = Matchmaker.allPairs()
	-- `newMap` is every pairing on a map nobody is showing; `fresh` is the
	-- subset of those whose mode is also unused. Nesting them is what lets a
	-- freshMap draw fall back on the MODE without ever falling back on the map.
	local distinct, newMap, fresh = {}, {}, {}
	for _, p in all do
		if not pairSeen[Matchmaker.pairKey(p.map, p.mode)] then
			-- Weighted by repetition: see HISTORICAL_WEIGHT.
			local copies = if Modes.isHistorical(p.mode) then Matchmaker.HISTORICAL_WEIGHT else 1
			for _ = 1, copies do
				table.insert(distinct, p)
				if not mapSeen[p.map] then
					table.insert(newMap, p)
					if not modeSeen[modeBucket(p.mode)] then
						table.insert(fresh, p)
					end
				end
			end
		end
	end
	local pool
	if freshMap and #newMap > 0 then
		pool = #fresh > 0 and fresh or newMap
	else
		-- THE MAP OUTRANKS THE MODE IN THE FALLBACK TOO (2026-09-19). This used
		-- to drop from `fresh` straight to `distinct`, which was fine on a board
		-- of three and wrong on a board of seven or more: with all three modes
		-- in use `fresh` is always empty, and a fixed rung rolled onto a map an
		-- extra was already showing most of the time (two TOKYOs, two JAPANs and
		-- two USes on one ten-lobby board). A repeated mode on a new map is the
		-- lesser evil, so that tier comes first; `distinct` is reached only once
		-- every map in the rotation is up.
		pool = #fresh > 0 and fresh or (#newMap > 0 and newMap or (#distinct > 0 and distinct or all))
	end
	local pick = pool[math.random(1, #pool)]
	return pick.map, pick.mode
end

-- ------------------------------------------------------------ lifecycle ----

local idCounter = 0

-- WHAT A FLEX SLOT WAS TOLD TO BE. Both fields are optional and both are only
-- ever read for a slot marked `flex`: `size` is a rung of the ladder and `pair`
-- is "map|mode". A nil either way falls through to exactly the behaviour every
-- card had before demand existed -- the slot's own cap, and a fresh draw -- so
-- an unreachable MemoryStore costs the board nothing but its steering.
export type Want = { size: number?, pair: string? }

function Matchmaker.newRecord(slotIndex: number, used: { { map: string, mode: string } }?, want: Want?): Record
	local slot = Matchmaker.SLOTS[slotIndex]
	local map, mode = Matchmaker.drawPair(used, slot.flex)
	-- THE DEMAND PICK, AND ONLY FOR A FLEX SLOT. A pairing that does not parse
	-- into a real map and a real mode is dropped rather than repaired: the draw
	-- above already ran and is a perfectly good card.
	local size = slot.cap
	if slot.flex and want then
		if want.size and Matchmaker.rungFor(want.size) then
			size = want.size
		end
		if want.pair then
			-- ...AND THE MAP RULE OUTRANKS THE DEMAND. `Demand.bestPair` is
			-- already told which maps are taken, so this is the backstop for a
			-- pick made against a board that has moved since -- a lobby can
			-- roll over between the read and the mint. Dropping the pick costs
			-- one card's worth of steering; honouring it would put two extras
			-- on one map, which is the thing being ruled out.
			--
			-- ...AND SO DOES THE ONE-SPECIAL RULE (drawPair). Demand may bring a
			-- special BACK -- people queued for it, which is the whole signal --
			-- but never a second one beside the first.
			local taken, specialUp = {}, false
			for _, u in used or {} do
				taken[u.map] = true
				specialUp = specialUp or Modes.isSpecial(u.mode)
			end
			local m, g = string.match(want.pair, "^(.-)|(.+)$")
			if m and g and table.find(Maps.ORDER, m) and Modes.exists(g) and not taken[m]
				and not (Modes.isSpecial(g) and specialUp) then
				map, mode = m, g
			end
		end
	end
	-- A MAP MAY CAP THE CARD (Maps.MapData.MAX_EMPIRES). Korea is a 1v1, so a
	-- SKIRMISH, BATTLE or WORLD WAR slot that draws it advertises TWO seats
	-- rather than 6, 12 or 24 -- and, since 2026-09-17, NO phantom seats (see
	-- Matchmaker.phantoms): both chairs are for people. A solo joiner waits for
	-- the clock like anyone else and then meets an ordinary bot, because a
	-- round makes faux empires only for the phantoms its card advertised. The
	-- figure already travels the wire -- `wire` writes rec.cap and `readWire`
	-- reads it back as e[3].
	local mapCap = Matchmaker.mapCap(map)
	local cap = if mapCap then math.min(size, mapCap) else size
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
		size = size,
		cap = cap,
		state = "open",
		-- BORN COUNTING DOWN, AND BORN ON ITS OWN CLOCK. It used to be 0 --
		-- "no clock until somebody joins" -- and a page of three stopped
		-- clocks is the thing this replaced; then it was `os.time() +
		-- COUNTDOWN`, which handed all three slots the same second. See
		-- nextDeadline. An empty lobby that reaches zero rolls over into a
		-- fresh generation instead of launching; see MatchmakerServer's tick.
		deadline = Matchmaker.nextDeadline(slotIndex, os.time()),
		claimedAt = 0,
		host = "",
		code = "",
		psid = "",
		readyAt = 0,
		servers = {},
	}
end

-- REAL PLAYERS. Everything that decides whether there is a match worth
-- reserving reads this and not `seats`.
function Matchmaker.count(rec: Record): number
	local n = 0
	for _, s in rec.servers do
		n += #s.u
	end
	return n
end

-- The seat ceiling a map puts on any card that draws it, or nil. Korea states
-- one (KoreaMap.MAX_EMPIRES = 2, a 1v1) and so does the Philippines (6, an
-- archipelago of eleven island homelands; owner, 2026-09-22).
function Matchmaker.mapCap(map: string?): number?
	if type(map) ~= "string" then
		return nil
	end
	return tonumber((Maps.get(map) :: any).MAX_EMPIRES)
end

-- How many of this lobby's seats are held by nobody. Clamped against the real
-- roster so the phantoms give way as the card fills rather than pushing it
-- over its own cap.
--
-- A MAP-CAPPED CARD HOLDS NONE (owner, 2026-09-17: "Korea one should have 0
-- phantom seats"). Korea caps the card at two, and a phantom draw of two made
-- half of all empty Korea cards read "2 / 2 FULL" at nobody -- measured 95 of
-- 200 minted records. shouldLaunch counts humans only, so such a card could
-- never start, and the join path refused every press on it until the clock
-- ran out and it rolled over. To anyone on the page that was a full game that
-- never began. On a two-seat card a phantom is not decoration; it is the board.
--
-- A CAP THE PHANTOMS CANNOT FILL ON THEIR OWN KEEPS THEM (the Philippines
-- holds six, 2026-09-22): a draw of at most PHANTOM_MAX on a six-seat card can
-- never read FULL at nobody, and shouldLaunch still counts humans only, so the
-- card breathes like any other six-seat card. The rule is the cap against the
-- draw, not the presence of a cap.
function Matchmaker.phantoms(rec: Record): number
	local cap = Matchmaker.mapCap(rec.map)
	if cap ~= nil and cap <= Matchmaker.PHANTOM_MAX then
		return 0
	end
	local span = Matchmaker.PHANTOM_MAX - Matchmaker.PHANTOM_MIN + 1
	local n = Matchmaker.PHANTOM_MIN + hashOf(rec.id or "") % span
	return math.clamp(n, 0, math.max(0, rec.cap - Matchmaker.count(rec)))
end

-- WHAT THE CARD SAYS: real players plus phantom seats. Everything that decides
-- whether the lobby is FULL reads this.
function Matchmaker.seats(rec: Record): number
	return Matchmaker.count(rec) + Matchmaker.phantoms(rec)
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
	-- An emptied lobby RESTARTS its clock rather than stopping it: the page
	-- has to keep counting down with nobody in it -- that is the whole point
	-- of the phantom seats above -- and the next person to press JOIN gets a
	-- fresh clock rather than the tail of somebody else's. Onto this slot's
	-- own grid point, so an emptying lobby cannot walk into step with the
	-- card beside it.
	if changed and Matchmaker.count(rec) == 0 then
		rec.deadline = Matchmaker.nextDeadline(rec.slot, now)
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
	-- REAL PLAYERS ONLY, and this is the load-bearing line of the phantom
	-- feature. The clock now runs on an empty lobby, so if a phantom seat
	-- could satisfy this every idle slot would reserve a match server every
	-- two minutes for as long as the experience is up. An empty lobby that
	-- runs out of time is rolled over by the caller instead.
	local n = Matchmaker.count(rec)
	if n <= 0 then
		return false
	end
	if Matchmaker.seats(rec) >= rec.cap then
		return true
	end
	return rec.deadline ~= 0 and now >= rec.deadline and n >= Matchmaker.LAUNCH_MIN
end

-- WHEN A LAUNCHED SLOT MAY BE HANDED BACK. Everyone sent (after READY_MIN, see
-- it), or the hold ran out. Pure, so the tick can test its second-old copy for
-- whether to bother writing and the store transform can test the truth.
function Matchmaker.readyDone(rec: Record, now: number): boolean
	local age = now - (rec.readyAt or 0)
	if age > Matchmaker.READY_HOLD then
		return true
	end
	return age >= Matchmaker.READY_MIN and Matchmaker.count(rec) == 0
end

function Matchmaker.remaining(rec: Record, now: number): number
	if rec.deadline == 0 then
		return Matchmaker.COUNTDOWN
	end
	-- AN EXPIRED EMPTY LOBBY IS about to roll over, not stuck, so it shows the
	-- fresh countdown rather than 0:00. Without this the second or two between
	-- a clock running out and some server winning the rollover is visible --
	-- and it is visible exactly when somebody has just arrived on the page,
	-- which is the worst possible moment to look broken. A lobby with real
	-- people in it still shows 0:00: there it means "waiting on a server",
	-- which is true and worth saying.
	if now >= rec.deadline and rec.state == "open" and Matchmaker.count(rec) == 0 then
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
--   { { mapIndex, modeIndex, cap, remaining, stateCode, { userId... },
--     phantoms }, ... }
--
-- The phantom seats ride as a COUNT rather than as invented ids in the user
-- list, because that list is also how a client recognises ITSELF -- and the
-- phantoms are drawn from the owner's own friends, so a made-up id in there
-- would eventually be a real one and light up somebody's card as JOINED.
--
-- A client works out its OWN membership from the userId list, so this is one
-- broadcast rather than a packet per player.
-- THE MODE ON THE WIRE IS AN INDEX INTO THIS, NOT INTO Modes.ORDER. ORDER is
-- the ROTATION and the historical mode is deliberately not in it (see Modes),
-- so an ORDER index cannot carry a historical card: it would arrive as index
-- 1 and the card would read FREE FOR ALL over a historical round. The rotation
-- first, so every index it has ever had is unchanged, then every mode outside
-- it, sorted, which both ends compute identically from the same module.
local WIRE_MODES = table.clone(Modes.ORDER)
do
	local extra = {}
	for id in Modes.BY_ID do
		if not table.find(WIRE_MODES, id) then
			table.insert(extra, id)
		end
	end
	table.sort(extra)
	for _, id in extra do
		table.insert(WIRE_MODES, id)
	end
end

local STATE_CODE = { open = 1, claim = 2, ready = 3 }
local CODE_STATE = { "open", "claim", "ready" }

function Matchmaker.wire(recs: { [string]: Record }, now: number, active: number?): { any }
	local live = active or #Matchmaker.SLOTS
	-- THE WIRE IS DENSE AND INDEX = SLOT: LobbyUI.rankBoard pins a card to a
	-- lobby by that index, and a remote will not carry an array with holes.
	-- A slot past the live count that still holds a lobby (retirement waits
	-- for an empty rollover) is sent as usual; a slot past it with nothing --
	-- or with a RETIRED tombstone -- is sent as a bare 0 so nothing after it
	-- shifts, and readWire skips it. Nothing is sent beyond the last slot
	-- that matters, so an idle board is the floor's seven entries.
	local top = live
	for i, slot in Matchmaker.SLOTS do
		local rec = recs[slot.key]
		if rec and rec.state ~= "retired" and i > top then
			top = i
		end
	end
	local out = {}
	for i = 1, top do
		local slot = Matchmaker.SLOTS[i]
		local rec = recs[slot.key]
		if rec and rec.state ~= "retired" then
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
				table.find(WIRE_MODES, rec.mode) or 1,
				rec.cap,
				Matchmaker.remaining(rec, now),
				STATE_CODE[rec.state] or 1,
				users,
				Matchmaker.phantoms(rec),
				-- EIGHTH, because it came eighth (2026-09-17). A record written
				-- before flex slots existed has no `size` and reads back as its
				-- cap, which for every fixed slot is the same number.
				rec.size or rec.cap,
			}
		elseif i <= live then
			-- No record yet -- the first board of a cold server. Staggered even
			-- here, so the page does not open on three identical clocks and
			-- then snap a second later.
			local blank = Matchmaker.nextDeadline(i, now) - now
			out[i] = { 1, 1, slot.cap, blank, 1, {}, Matchmaker.PHANTOM_MIN, slot.cap }
		else
			out[i] = 0
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
	-- The predrawn-borders mode, which the card draws as a light-blue pill.
	historical: boolean,
	-- A special opening (Modes.SPECIAL), which the card draws as the same pill
	-- in gold.
	special: boolean,
	-- The rung this card was minted at, which is what named it. See Record.
	size: number,
	cap: number,
	count: number,
	remaining: number,
	state: string,
	users: { number },
	mine: boolean,
}

-- "3 TEAMS OF 8", never "THREE TEAMS". The number of teams on its own does
-- not say what a player is actually deciding, which is how many people will be
-- on their side: three teams on a 24-seat card and three teams on a six-seat
-- one are different games, and the card already has the second number. FREE
-- FOR ALL has no side to be on and keeps its name.
function Matchmaker.modeLabel(mode: string, cap: number): string
	local teams = Modes.teams(mode)
	if teams <= 0 then
		return Modes.name(mode)
	end
	return string.format("%d TEAMS OF %d", teams, math.max(1, math.floor(cap / teams)))
end

function Matchmaker.readWire(wire: { any }, myUserId: number): { CardView }
	local out = {}
	-- INDEXED BY SLOT, WITH HOLES. A bare 0 on the wire (a slot past the live
	-- count with nothing in it -- see `wire`) leaves out[i] nil, and so does
	-- a wire shorter than the table. Nothing that reads this may take its #;
	-- LobbyUI counts and iterates instead.
	for i, slot in Matchmaker.SLOTS do
		local e = wire[i]
		if type(e) == "table" then
			local map = Maps.ORDER[e[1]] or Maps.ORDER[1]
			local mode = WIRE_MODES[e[2]] or Modes.ORDER[1]
			local users = e[6] or {}
			-- Hoisted out of the literal below because `modeName` reads it and
			-- a table cannot refer to a field it is still being built with.
			local cap = e[3] or slot.cap
			-- A FLEX SLOT IS NAMED BY ITS SIZE, NOT BY ITS TABLE ENTRY. Those
			-- two agree for slots 1-3 and are unrelated for 4 to 12, whose
			-- entry only ever held a cold-start default -- so the rung the
			-- record was minted at is what the card reads.
			local size = e[8] or cap
			local rung = if slot.flex then Matchmaker.rungFor(size) else nil
			out[i] = {
				slot = i,
				name = (rung or slot).name,
				blurb = (rung or slot).blurb,
				size = size,
				map = map,
				mode = mode,
				mapName = Maps.get(map).NAME,
				mapBlurb = Maps.get(map).BLURB,
				modeName = Matchmaker.modeLabel(mode, cap),
				modeBlurb = Modes.get(mode).BLURB,
				historical = Modes.isHistorical(mode),
				special = Modes.isSpecial(mode),
				cap = cap,
				-- The phantoms are counted, never listed -- see `wire`. `mine`
				-- below is therefore still decided by the REAL roster alone.
				count = #users + (e[7] or 0),
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
