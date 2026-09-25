--!strict
-- Conquest :: ConquestAnalytics  (server)
-- The purchase funnel, THE PLAYER FUNNELS, and a ring buffer of the recent
-- events for debugging.
--
-- WHY THIS EXISTS AT ALL, given nothing is being sold yet: the event you can
-- never add retroactively is PROMPT SHOWN. Without it, a product that earns
-- nothing is indistinguishable between "the price is wrong" and "nobody ever
-- found the button", and those two need opposite fixes. Shipping the funnel
-- with the plumbing costs a morning; adding it after a month of bad numbers
-- costs the month.
--
-- THE PURCHASE FUNNEL IS THREE EVENTS, and all three matter:
--     shown     -> the prompt was put in front of someone
--     completed -> they paid
--     cancelled -> they saw the price and said no
-- shown/completed is conversion. shown/(completed+cancelled) tells you whether
-- the prompt is even rendering. cancelled on its own is the price signal.
--
-- ============================ THE PLAYER FUNNELS (2026-09-01) ==============
-- The same argument, one level up: the shop funnel says whether the shop
-- works, and these say whether the GAME works on people.
--
--   ONBOARDING -- one ladder, joined -> pressed LEARN TO PLAY -> each lesson
--                 card -> finished. Logged through Roblox's own onboarding
--                 funnel, so it lands in a report that already exists on the
--                 dashboard instead of a custom one somebody has to build.
--                 "How many complete the tutorial" is the last row over the
--                 first; every row in between says where they stopped, which
--                 is the part that tells you what to fix.
--
--   match      -- lobby -> queued -> launched -> in the match -> picked a
--                 homeland -> attacked something -> saw the round end ->
--                 CAME HOME -> QUEUED AGAIN. The core loop's own drop-off,
--                 and since 2026-09-17 the loop's own CLOSE: `requeued` over
--                 `returned` is the REPLAY RATE and the rest of `returned`
--                 is the leave rate. A cliff between "queued" and "in the
--                 match" is a matchmaking bug; a cliff between "spawned" and
--                 "attacked" is a game nobody understands; a cliff between
--                 "finished" and "returned" is an end screen losing people
--                 before they ever see the page again.
--
--   playtime   -- a step at 1/3/5/10/15/30/60 minutes in the experience.
--                 AN AVERAGE ON ITS OWN IS A TRAP: "everyone plays eight
--                 minutes" and "half leave inside a minute and half play half
--                 an hour" have the same mean and need opposite fixes, and
--                 only a distribution can tell them apart. The mean is still
--                 reported (`session_end`); this is its shape.
--
--   tutorial_<map> / playtime_<map>  (2026-09-08) -- the two ladders above,
--                 once per map the tutorial is dealt on (us / europe / world),
--                 so the owner can read three completion rates and three
--                 engagement curves side by side. See the tutorial section.
--
-- THE FOUR RULES THIS FILE IS BUILT ON
--  1. EVERY EXTERNAL CALL IS pcall'd. AnalyticsService's signatures are
--     versioned by Roblox and its custom-field keys are an enum, not free-form
--     strings -- a change on their side must degrade to "the local ring buffer
--     still works", never to a server error inside a purchase handler or the
--     tick loop.
--  2. IT DEPENDS ON NOTHING IN THIS GAME. No Config, no ConquestData, no
--     Products: analytics must never be the reason something fails to load.
--     The profile that lifetime playtime is banked in arrives as two functions
--     handed to `install`, so this file can be dropped into a place with no
--     data layer at all and still work.
--  3. CUSTOM FIELDS ARE DIMENSIONS, NOT MEASURES. Three per event, and each
--     one becomes a column you filter by -- so they hold LOW-CARDINALITY
--     strings (a role, a map id, a card id, why somebody left). A duration or
--     a tile count in a custom field makes a column with one value per event,
--     which is useless to filter by and expensive to store. Numbers go in
--     `value`, which is the thing the dashboard aggregates.
--  4. NOTHING HERE READS THE CLOCK FOR MONEY OR FOR RULES. A wrong number in
--     this file makes a chart wrong; it must never make a round wrong.
--
-- WHAT STUDIO DOES AND DOES NOT MEASURE: AnalyticsService discards everything
-- sent from a Studio session, so the printed `[analytics]` line is the whole
-- output here. That is the point of `verbose` -- it is how you check a funnel
-- is wired before it ships, and the counts are still real locally.

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Analytics = {}

-- Printed to the server output as well as sent. On in Studio always, because
-- that is where the funnel gets checked; off in production, where it would be
-- one line per prompt per player.
Analytics.verbose = RunService:IsStudio()

local RING = 200
local ring: { any } = {}
local ringNext = 1
local counts: { [string]: number } = {}

-- AnalyticsService takes at most three custom fields and they must be keyed by
-- its own enum names, not by whatever the caller happened to call them. Build
-- the mapping once and defensively: if the enum is not what this file expects,
-- the local record is still complete and only the remote send loses detail.
local FIELD_KEYS: { string } = {}
pcall(function()
	FIELD_KEYS = {
		Enum.AnalyticsCustomFieldKeys.CustomField01.Name,
		Enum.AnalyticsCustomFieldKeys.CustomField02.Name,
		Enum.AnalyticsCustomFieldKeys.CustomField03.Name,
	}
end)

local function remoteFields(props: { [string]: any }?): { [string]: string }?
	if props == nil or #FIELD_KEYS == 0 then
		return nil
	end
	-- Sorted, so the same three properties always land in the same three slots
	-- across sessions. Unsorted, `next` order decides which field a value goes
	-- to and the dashboard column means something different every deploy.
	local keys = {}
	for k in props do
		table.insert(keys, k)
	end
	table.sort(keys)
	local out = {}
	for i, k in keys do
		if i > #FIELD_KEYS then
			break
		end
		out[FIELD_KEYS[i]] = tostring(props[k])
	end
	return out
end

-- Names and ids go over the wire as strings and every one of them becomes a
-- row label somewhere. Clamped rather than trusted: a step name built from a
-- map id or a card id is fine, and a step name built from something unexpected
-- must not be the reason a whole event is dropped.
local function short(text: any, limit: number?): string
	local s = tostring(text)
	local n = limit or 40
	if #s > n then
		s = string.sub(s, 1, n)
	end
	return s
end

-- ================================================================== record ==

-- LOCAL ONLY -- the ring buffer, the counter and the printed line, with nothing
-- sent anywhere. Funnel steps use this: they are already going out through
-- LogFunnelStepEvent, and sending each one a second time as a custom event
-- would double the traffic and burn a custom event name per step.
function Analytics.note(name: string, player: Player?, value: number?, props: { [string]: any }?)
	counts[name] = (counts[name] or 0) + 1

	local record = {
		name = name,
		t = os.time(),
		clock = os.clock(),
		user = player and player.UserId or 0,
		who = player and player.Name or "-",
		value = value or 1,
		props = props,
	}
	ring[ringNext] = record
	ringNext = (ringNext % RING) + 1

	if Analytics.verbose then
		local extra = ""
		if props ~= nil then
			local parts = {}
			for k, v in props do
				table.insert(parts, ("%s=%s"):format(k, tostring(v)))
			end
			table.sort(parts)
			extra = "  " .. table.concat(parts, " ")
		end
		print(("[analytics] %-24s %-16s %s%s"):format(name, record.who, tostring(record.value), extra))
	end
end

-- The one entry point for a CUSTOM EVENT. `value` is the numeric the dashboard
-- aggregates on -- Robux for a purchase, minutes for a session, 1 for a count.
function Analytics.event(name: string, player: Player?, value: number?, props: { [string]: any }?)
	Analytics.note(name, player, value, props)

	if player ~= nil then
		pcall(function()
			AnalyticsService:LogCustomEvent(player, short(name), value or 1, remoteFields(props))
		end)
	end
end

-- ================================================================= funnels ==
--
-- Roblox's rules, which the shape of everything below depends on:
--   * steps do NOT have to arrive in order -- logging step 5 completes 1..4;
--   * a step logged twice for the same funnel session counts ONCE.
-- Together they mean a skipped lesson card (the port card, on a landlocked
-- empire) cannot read as a wall, and that a retry after a teleport is free.

Analytics.MATCH_FUNNEL = "match"
Analytics.PLAY_FUNNEL = "playtime"

-- The match funnel's ladder. Named rather than numbered at the call sites so
-- inserting a step is one edit here.
local MATCH_LOBBY = 1
local MATCH_QUEUED = 2
local MATCH_LAUNCHED = 3
local MATCH_IN = 4
local MATCH_SPAWNED = 5
local MATCH_ATTACKED = 6
local MATCH_ENDED = 7
-- THE LOOP CLOSING (owner, 2026-09-17: "how many players go back to lobby
-- after finishing a game, so i can see the leave vs replay rate"). TWO MORE
-- ROWS ON THE SAME LADDER rather than a funnel of their own, because a rate is
-- only a rate against the people it is measured on: `returned` over `finished`
-- and `requeued` over `returned` are read straight down the same column as
-- everything else that round did to them. A separate funnel would have its own
-- top, and the two tops would not be the same set of people.
local MATCH_RETURNED = 8
local MATCH_REQUEUED = 9

-- The onboarding ladder. Card `i` is ONB_CARD + i, and "finished" is the step
-- after the last card -- computed from the live card count rather than fixed,
-- so the ladder always ends where the lesson does. THE CONSEQUENCE, worth
-- knowing before adding a card: the finish step's NUMBER moves, so the
-- dashboard renumbers. Its NAME does not, which is why the name carries the
-- meaning and the number is only an ordering.
local ONB_JOINED = 1
local ONB_PRESSED = 2
local ONB_STARTED = 3
local ONB_CARD = 3

-- THE TUTORIAL MAP EXPERIMENT'S TWO LADDERS (2026-09-08; the why is in the
-- tutorial section below). `tutorial_<map>`: entered, started, then card `i`
-- at ARM_CARD + i, then complete after the last card. `playtime_<map>`:
-- entered, then milestone `k` at ARM_PLAY_ENTERED + k. Declared up here
-- because the playtime ticker, which is defined above the tutorial section,
-- logs the second one.
Analytics.TUTORIAL_ARM_PREFIX = "tutorial_"
Analytics.PLAY_ARM_PREFIX = "playtime_"
local ARM_ENTERED = 1
local ARM_STARTED = 2
local ARM_CARD = 2
local ARM_PLAY_ENTERED = 1

-- Per user, per step. Roblox already counts a repeated step once; this is to
-- keep the local ring buffer readable when somebody replays the tutorial.
local onboarded: { [number]: { [number]: boolean } } = {}

function Analytics.funnel(
	player: Player?,
	funnelName: string,
	sessionKey: string,
	step: number,
	stepName: string,
	props: { [string]: any }?
)
	if player == nil then
		return
	end
	Analytics.note(funnelName .. ":" .. stepName, player, step, props)
	pcall(function()
		AnalyticsService:LogFunnelStepEvent(
			player,
			short(funnelName, 32),
			short(sessionKey, 40),
			math.max(1, math.floor(step)),
			short(stepName, 32),
			remoteFields(props)
		)
	end)
end

function Analytics.onboarding(player: Player?, step: number, stepName: string, props: { [string]: any }?)
	if player == nil then
		return
	end
	local seen = onboarded[player.UserId]
	if seen == nil then
		seen = {}
		onboarded[player.UserId] = seen
	end
	if seen[step] then
		return
	end
	seen[step] = true

	Analytics.note("onboarding:" .. stepName, player, step, props)
	pcall(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(
			player,
			math.max(1, math.floor(step)),
			short(stepName, 32),
			remoteFields(props)
		)
	end)
end

-- ================================================================ sessions ==
--
-- A SESSION IS THE VISIT, NOT THE SERVER. This game teleports: lobby ->
-- reserved match server -> lobby, and each hop is a PlayerRemoving followed by
-- a PlayerAdded somewhere else. Measured per server, "average playtime" would
-- report the length of a lobby wait and the length of one round as two
-- separate visits and quietly halve the number that matters.
--
-- So the entry time and the funnel session id RIDE THE TELEPORT, in the same
-- teleport data the clan tags already use (`teleportPayload`), and the far
-- side picks them back up in `begin`. A player who arrives with none -- the
-- first hop of a visit, or somebody who joined a reserved server directly --
-- simply starts a new one.

type Session = {
	userId: number,
	-- os.clock() when they arrived on THIS server. Monotonic, so it is the
	-- right clock for a duration; os.time() is the right one for the visit,
	-- because that is the one that survives a teleport.
	server: number,
	entered: number,
	fsid: string,
	role: string,
	-- Set the moment a teleport payload is built for them, so the leave that
	-- follows is understood as a hop rather than as somebody quitting.
	hop: boolean,
	hopAt: number,
	-- Highest playtime milestone already logged for this VISIT.
	mark: number,
	-- THE TUTORIAL MAP EXPERIMENT (2026-09-08). Which map this visit's
	-- tutorial was dealt on, or nil on a visit that never entered the lesson.
	-- `armAt` is when it was dealt -- os.time(), so it rides the teleport the
	-- way `entered` does -- and `armMark` is the highest milestone of that
	-- map's own playtime funnel already logged. See the tutorial section.
	arm: string?,
	armAt: number,
	armMark: number,
	-- THE REPLAY DECISION (2026-09-17). `fin` is os.time() when this visit
	-- last saw a round END, 0 when there is no finished round behind them;
	-- `res` is how that round went for them. Both RIDE THE TELEPORT, because
	-- the server that gets to ask "did they play again" is never the server
	-- the round finished on. `again` is whether the requeue has already been
	-- counted for that round, so a player mashing JOIN is one replay.
	fin: number,
	res: string?,
	again: boolean,
}

local sessions: { [number]: Session } = {}

-- THE TUTORIAL MAP OUTLIVES THE SESSION BY ONE LEAVE. ConquestServer's own
-- PlayerRemoving -- the one that logs tutorial_quit and match_quit -- runs
-- AFTER `finish` below has released the session (measured 2026-09-09:
-- server_end printed before tutorial_quit), so a quit that read the map
-- through the session alone came back "?". `finish` parks it here; `armOf`
-- falls back to it; a minute later it is gone.
local armAfter: { [number]: string } = {}

-- How long a "we are about to teleport you" flag stays believable. A teleport
-- that failed leaves the player right here, and after this they are an
-- ordinary session again -- otherwise one failed teleport would silently
-- delete that player's whole visit from the playtime numbers.
local HOP_WINDOW = 45

local PLAY_MINUTES = { 1, 3, 5, 10, 15, 30, 60 }
local MILESTONE_PERIOD = 20

local installed = false
local role = "lobby"
local getProfile: ((Player) -> any)? = nil
local markDirty: ((Player) -> ())? = nil

-- Per ROUND, not per session: the two steps a player can reach more than once
-- in a round and should only be counted for once.
local roundSeen: { [number]: { [string]: boolean } } = {}

local function once(player: Player, what: string): boolean
	local seen = roundSeen[player.UserId]
	if seen == nil then
		seen = {}
		roundSeen[player.UserId] = seen
	end
	if seen[what] then
		return false
	end
	seen[what] = true
	return true
end

-- Called by the match server when a round is built. Without it a Studio
-- session that rotates in place would report one spawn per player forever.
function Analytics.roundReset()
	roundSeen = {}
end

local function keyFor(player: Player, now: number): string
	return tostring(player.UserId) .. "-" .. tostring(now)
end

function Analytics.sessionKey(player: Player): string
	local s = sessions[player.UserId]
	if s ~= nil then
		return s.fsid
	end
	return keyFor(player, os.time())
end

-- KEYED BY USER ID AS A STRING, exactly as the clan tags beside it are, and
-- for the same reason: teleport data belongs to a BATCH, while an entry time
-- belongs to a person. (A numeric key would not survive the JSON round trip
-- either -- see ConquestServer's tagFor, which learned this first.)
local function joinPayload(player: Player): any
	local ok, data = pcall(function()
		return player:GetJoinData().TeleportData
	end)
	if ok and type(data) == "table" and type(data.cq) == "table" then
		local mine = data.cq[tostring(player.UserId)]
		if type(mine) == "table" then
			return mine
		end
	end
	return nil
end

-- THEY CAME HOME. The row the leave-vs-replay rate is read against: of
-- everyone who saw a round end, this is who made it back to the page. Logged
-- by `begin` when a visit lands on a LOBBY server carrying a finished round,
-- and only there -- arriving at a MATCH server carrying one is the replay
-- itself, which `requeued` already counted on the way out.
local function noteReturn(player: Player, s: Session, result: string?)
	local res = result or s.res or "?"
	Analytics.funnel(player, Analytics.MATCH_FUNNEL, s.fsid, MATCH_RETURNED, "returned", { result = res })
	-- PER ROUND, where the funnel step is per visit. Roblox counts a step once
	-- per funnel session and a visit can hold three matches, so the funnel
	-- answers "what share of players came back" and this answers "what share of
	-- ROUNDS ended with somebody coming back". Value 1: the number wanted here
	-- is the count, and it is the denominator `match_replay` is read against.
	Analytics.event("match_return", player, 1, { result = res })
end

local function begin(player: Player)
	if sessions[player.UserId] ~= nil then
		return
	end
	local now = os.time()
	local cq = joinPayload(player)

	-- SANITY, NOT TRUST. The payload is written by a server of this same
	-- place, so this is not a security check -- it is a clock check. An entry
	-- time from the future or from last week would poison every session-length
	-- figure the game reports, and the failure would look like a game people
	-- play for eleven hours.
	local entered = cq and tonumber(cq.entered) or nil
	if entered == nil or entered > now or now - entered > 12 * 3600 then
		entered = now
	end
	local fsid = keyFor(player, entered)
	if cq ~= nil and type(cq.fsid) == "string" and #cq.fsid > 0 and #cq.fsid <= 40 then
		fsid = cq.fsid
	end

	-- Milestones already passed on the server they came from are NOT re-logged
	-- (Roblox would count them once anyway; this is to keep the local record
	-- honest about where each step actually happened).
	local elapsed = (now - entered) / 60
	local mark = 0
	while mark < #PLAY_MINUTES and elapsed >= PLAY_MINUTES[mark + 1] do
		mark += 1
	end

	-- The tutorial map this visit was dealt, if a lobby dealt one before the
	-- hop. Same clock check as `entered`, for the same reason: a bad `tmapAt`
	-- would read as a map that kept somebody for eleven hours.
	local arm: string? = nil
	local armAt = now
	if cq ~= nil and type(cq.tmap) == "string" and #cq.tmap > 0 and #cq.tmap <= 16 then
		arm = cq.tmap
		local at = tonumber(cq.tmapAt)
		if at ~= nil and at <= now and now - at <= 12 * 3600 then
			armAt = at
		end
	end
	local armMark = 0
	if arm ~= nil then
		local since = (now - armAt) / 60
		while armMark < #PLAY_MINUTES and since >= PLAY_MINUTES[armMark + 1] do
			armMark += 1
		end
	end

	-- THE ROUND THEY ARE COMING BACK FROM, if this arrival is a trip home
	-- rather than a first landing. Same clock check as `entered` and for the
	-- same reason: a `fin` from the future would report a replay decision that
	-- took minus five minutes.
	local fin = 0
	local res: string? = nil
	if cq ~= nil then
		local at = tonumber(cq.fin)
		if at ~= nil and at <= now and now - at <= 12 * 3600 then
			fin = at
			if type(cq.res) == "string" and #cq.res > 0 and #cq.res <= 16 then
				res = cq.res
			end
		end
	end

	local session: Session = {
		userId = player.UserId,
		server = os.clock(),
		entered = entered,
		fsid = fsid,
		role = role,
		hop = false,
		hopAt = 0,
		mark = mark,
		arm = arm,
		armAt = armAt,
		armMark = armMark,
		fin = fin,
		res = res,
		again = false,
	}
	sessions[player.UserId] = session

	Analytics.note("session_start", player, 1, { role = role, arrived = cq ~= nil and "hop" or "new" })
	-- THE DENOMINATOR. Every other onboarding row is read against this one, so
	-- it is logged for everybody, on either kind of server, before anything
	-- else can go wrong.
	Analytics.onboarding(player, ONB_JOINED, "joined")
	if role ~= "match" then
		Analytics.funnel(player, Analytics.MATCH_FUNNEL, fsid, MATCH_LOBBY, "lobby")
		-- ...and if they arrived off the back of a round, the same landing is
		-- also the step after "finished". One event, two meanings, and both of
		-- them true of this exact moment.
		if fin > 0 then
			noteReturn(player, session, res)
		end
	end
end

local function finish(player: Player, why: string)
	local s = sessions[player.UserId]
	sessions[player.UserId] = nil
	onboarded[player.UserId] = nil
	roundSeen[player.UserId] = nil
	if s == nil then
		return
	end
	if s.arm ~= nil then
		local uid = player.UserId
		armAfter[uid] = s.arm
		task.delay(60, function()
			if armAfter[uid] == s.arm and sessions[uid] == nil then
				armAfter[uid] = nil
			end
		end)
	end

	local serverSeconds = math.max(0, os.clock() - s.server)
	local hop = s.hop and (os.clock() - s.hopAt) < HOP_WINDOW
	-- The visit is at least as long as this server has had them: os.time() can
	-- be adjusted under a long-running server, and a negative session length is
	-- worse than a slightly short one.
	local visitSeconds = math.max(serverSeconds, os.time() - s.entered)

	-- TWO EVENTS BECAUSE THEY ANSWER TWO QUESTIONS. `server_end` is time on
	-- THIS server and is filtered by role -- lobby dwell is a matchmaking
	-- problem, match dwell is a game problem. `session_end` is the whole visit
	-- and only fires when the visit actually ended, which is what makes it the
	-- average playtime rather than an average of fragments.
	Analytics.event("server_end", player, serverSeconds / 60, { role = s.role, exit = hop and "hop" or why })
	if not hop then
		Analytics.event("session_end", player, visitSeconds / 60, { role = s.role, exit = why })
		-- THE EXPERIMENT'S MEAN: minutes played from the moment the lesson
		-- was dealt, filed under the map it was dealt on. The `playtime_<map>`
		-- funnel is this number's shape; this is the one figure that gets
		-- quoted, and it is only worth quoting per map. A NEW event rather
		-- than a `map` field on session_end, because a fourth key there would
		-- shuffle `role` into a different dashboard column (remoteFields
		-- assigns slots in sorted key order).
		if s.arm ~= nil then
			local armSeconds = math.max(0, os.time() - s.armAt)
			Analytics.event("tutorial_visit", player, armSeconds / 60, { map = s.arm, exit = why })
		end
		-- THE LEAVE HALF OF "LEAVE VS REPLAY". A visit that ended with a
		-- finished round behind it and no requeue in front of it is somebody
		-- the game finished with. `where` says which screen lost them -- match
		-- is a quit from the end-of-round screen without ever coming home,
		-- lobby is a player who came back to the page and then closed the game
		-- -- and those are different fixes. The value is the minutes they sat
		-- there first: a long one is a player who considered it.
		--
		-- `exit` IS LOAD-BEARING, not decoration: this fires from BindToClose
		-- as well, so a SHUTDOWN -- every publish shuts every server down, and
		-- a return teleport that failed then un-armed the hop leaves its
		-- players here too -- would otherwise be counted as people who chose
		-- to walk away. exit=left is the leave rate; exit=shutdown is the
		-- server. Same labelling as server_end above, and it is why this event
		-- spends all three custom fields.
		if s.fin > 0 and not s.again then
			Analytics.event("match_left", player, math.max(0, os.time() - s.fin) / 60, {
				exit = why,
				result = s.res or "?",
				where = s.role,
			})
		end
	end

	-- LIFETIME PLAYTIME, banked on the profile. Per server rather than per
	-- visit, because this runs on both ends of a hop and each end knows only
	-- its own share -- added up, they are the visit. `markDirty` rather than a
	-- save: ConquestData's own PlayerRemoving is registered AFTER this one
	-- (see the install order at the foot of ConquestServer) and writes it out.
	if getProfile ~= nil then
		local ok, profile = pcall(getProfile :: any, player)
		if ok and type(profile) == "table" and type(profile.stats) == "table" then
			local st = profile.stats
			st.playSeconds = (tonumber(st.playSeconds) or 0) + math.floor(serverSeconds)
			st.lastSeen = os.time()
			if not hop then
				st.sessions = (tonumber(st.sessions) or 0) + 1
			end
			if markDirty ~= nil then
				pcall(markDirty :: any, player)
			end
		end
	end
end

-- THE VISIT SO FAR, in minutes. Public because the match server prints it and
-- because a session length is the one figure worth having in a support reply.
function Analytics.minutes(player: Player): number
	local s = sessions[player.UserId]
	if s == nil then
		return 0
	end
	return math.max(os.clock() - s.server, os.time() - s.entered) / 60
end

-- What to merge into TeleportData under `cq` so the visit survives the hop.
-- Arming the hop flag HERE rather than after the teleport is deliberate: the
-- player can be gone before TeleportAsync returns, and a leave that arrives
-- first would be recorded as them quitting the game.
function Analytics.teleportData(list: { Player }): { [string]: any }
	local out: { [string]: any } = {}
	local now = os.time()
	for _, player in list do
		local s = sessions[player.UserId]
		if s == nil then
			out[tostring(player.UserId)] = { entered = now, fsid = keyFor(player, now) }
		else
			s.hop = true
			s.hopAt = os.clock()
			-- The tutorial map rides too, with its own clock, so the lesson
			-- server files its card rows under the right funnel and the lobby
			-- it comes home to keeps that map's playtime ladder running.
			out[tostring(player.UserId)] = {
				entered = s.entered,
				fsid = s.fsid,
				tmap = s.arm,
				tmapAt = s.arm ~= nil and s.armAt or nil,
				-- THE ROUND THAT JUST ENDED rides home too, which is the
				-- whole reason the lobby can tell a player coming back from
				-- one apart from a player arriving for the first time. Sent
				-- only while it is armed, so an ordinary hop carries nothing
				-- extra.
				fin = s.fin > 0 and s.fin or nil,
				res = s.fin > 0 and s.res or nil,
			}
		end
	end
	return out
end

-- The teleport did not happen. They are still here and still playing.
function Analytics.hopCancelled(player: Player)
	local s = sessions[player.UserId]
	if s ~= nil then
		s.hop = false
		s.hopAt = 0
	end
	Analytics.note("launch_failed", player, 1, { role = s and s.role or role })
end

function Analytics.hopsCancelled(list: { Player })
	for _, player in list do
		Analytics.hopCancelled(player)
	end
end

local function milestones()
	while true do
		task.wait(MILESTONE_PERIOD)
		local now = os.time()
		for _, player in Players:GetPlayers() do
			local s = sessions[player.UserId]
			if s ~= nil then
				local minutes = (now - s.entered) / 60
				while s.mark < #PLAY_MINUTES and minutes >= PLAY_MINUTES[s.mark + 1] do
					s.mark += 1
					Analytics.funnel(
						player,
						Analytics.PLAY_FUNNEL,
						s.fsid,
						s.mark,
						"min_" .. tostring(PLAY_MINUTES[s.mark]),
						{ role = s.role }
					)
				end
				-- THE SAME LADDER PER TUTORIAL MAP, clocked from the moment
				-- the lesson was dealt rather than from the join, so a map is
				-- credited only with the time it actually kept them. Step 1
				-- ("entered") went out when the map was dealt, which is what
				-- gives every one of these funnels its top.
				if s.arm ~= nil then
					local since = (now - s.armAt) / 60
					while s.armMark < #PLAY_MINUTES and since >= PLAY_MINUTES[s.armMark + 1] do
						s.armMark += 1
						Analytics.funnel(
							player,
							Analytics.PLAY_ARM_PREFIX .. s.arm,
							s.fsid,
							ARM_PLAY_ENTERED + s.armMark,
							"min_" .. tostring(PLAY_MINUTES[s.armMark]),
							{ map = s.arm, role = s.role }
						)
					end
				end
			end
		end
	end
end

-- `role` is "lobby" or "match" and decides which end of the match funnel this
-- server logs. `profile`/`markDirty` are ConquestData's, handed in rather than
-- required, per rule 2 in the header.
--
-- MUST BE CALLED BEFORE `Data.install()`. Connection order is registration
-- order, and the profile this file writes playtime into is released by
-- ConquestData's own PlayerRemoving.
function Analytics.install(opts: any?)
	if installed then
		return
	end
	installed = true
	if type(opts) == "table" then
		role = tostring(opts.role or role)
		getProfile = opts.profile
		markDirty = opts.markDirty
	end

	-- Anyone already here -- a Studio session where this file loaded a frame
	-- late, or a player who arrived during the require chain.
	for _, player in Players:GetPlayers() do
		begin(player)
	end
	Players.PlayerAdded:Connect(begin)
	Players.PlayerRemoving:Connect(function(player)
		finish(player, "left")
	end)
	-- A MATCH SERVER'S LAST MOMENT. Roblox shuts a reserved server down as
	-- soon as the last player teleports out, and a shutdown is not obliged to
	-- fire PlayerRemoving for everyone -- so the longest sessions, the ones
	-- that played to the end, are exactly the ones that would go missing.
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			finish(player, "shutdown")
		end
	end)
	task.spawn(milestones)
end

-- ================================================================ tutorial ==
--
-- The lesson track is the onboarding funnel. ConquestServer owns the track and
-- calls these; nothing in here knows what a card is.

-- STEP 2 IS "THE TUTORIAL WAS ENTERED", not "a button was pressed". There is
-- no button any more: a first join is carried straight into the lesson and
-- everybody else types /tutorial, so a step only an old build could reach
-- would read on the dashboard as every new player dropping out here. `how` is
-- what tells the two routes apart. The STEP NAME is frozen at "pressed_learn"
-- on purpose -- the number is only an ordering, the name is what the existing
-- funnel rows are keyed by, and renaming it would orphan every one of them.
function Analytics.tutorialEntered(player: Player, how: string?)
	Analytics.onboarding(player, ONB_PRESSED, "pressed_learn", {
		how = short(how or "auto", 16),
	})
end

-- ================================================ the tutorial map experiment ==
-- (owner, 2026-09-08: "create funnels to test the same tutorial on America
-- Map, Europe Map, and World Map, so I can see which one has the highest
-- completion rate -- also have time players as a second funnel, so I can
-- roughly benchmark which of the tutorial maps keeps players engaged for the
-- longest"). Every player who enters the tutorial is DEALT a map
-- (Tutorial.mapFor: one of Tutorial.MAPS, fixed per account) and from then on
-- TWO EXTRA FUNNELS carry that map's name:
--
--   tutorial_<map>   entered -> started -> one row per card -> complete.
--                    The onboarding ladder, once per map, so the dashboard
--                    shows the three completion rates side by side. "entered"
--                    is the top -- every player dealt this map -- which is
--                    what the rate is read against.
--   playtime_<map>   entered -> min_1 -> ... -> min_60, clocked from the
--                    moment the map was dealt rather than from the join, so a
--                    map is credited only with the time it actually kept
--                    them: through the lesson, home to the lobby, and into
--                    whatever they played next.
--
-- SEPARATE FUNNELS, NOT A CUSTOM-FIELD BREAKDOWN. The dashboard can break a
-- funnel down by custom field, but a field's COLUMN is decided by sorted key
-- order per event (remoteFields), and the card rows already carry `card` and
-- `how` -- so `map` would land in a different column on different rows of
-- the same funnel. A funnel per map cannot be read wrong. The dashboard shows
-- up to ten funnel tabs; with these six this game uses eight.
--
-- The ONBOARDING funnel above is untouched and still counts everybody: it is
-- still "how many finish the tutorial", and these are "on which map".

-- DEALT. Called by the lobby the moment a map is chosen for this player --
-- BEFORE the teleport, so the payload built after it carries the map. Puts
-- the map on the visit, opens both of its funnels, and banks it on the
-- profile (`stats.tutorialMap`) so a later retention pass can ask "who
-- learned on which map" from inside the game.
function Analytics.tutorialArm(player: Player, mapId: string)
	local s = sessions[player.UserId]
	if s == nil then
		begin(player)
		s = sessions[player.UserId]
	end
	if s == nil then
		return
	end
	local arm = short(mapId, 16)
	-- A REPLAY ON THE SAME MAP KEEPS ITS CLOCK. /tutorial twice in one visit
	-- is one arm, and the minutes between the two are minutes that map kept
	-- them. (Roblox counts a funnel step once per session id anyway, so the
	-- replay's card rows fold into the first attempt's.)
	if s.arm ~= arm then
		s.arm = arm
		s.armAt = os.time()
		s.armMark = 0
	end
	Analytics.note("tutorial_arm", player, 1, { map = arm })
	Analytics.funnel(player, Analytics.TUTORIAL_ARM_PREFIX .. arm, s.fsid, ARM_ENTERED, "entered", { map = arm })
	Analytics.funnel(player, Analytics.PLAY_ARM_PREFIX .. arm, s.fsid, ARM_PLAY_ENTERED, "entered", { map = arm })
	if getProfile ~= nil then
		local ok, profile = pcall(getProfile :: any, player)
		if ok and type(profile) == "table" and type(profile.stats) == "table" then
			profile.stats.tutorialMap = arm
			if markDirty ~= nil then
				pcall(markDirty :: any, player)
			end
		end
	end
end

local function armOf(player: Player): string?
	local s = sessions[player.UserId]
	if s ~= nil then
		return s.arm
	end
	-- Already released by `finish` -- this is the quit path. See armAfter.
	return armAfter[player.UserId]
end

-- `mapId` is the map the lesson round was actually built on. It OUTRANKS
-- whatever rode the teleport: a match server knows what it built. Normally
-- the two agree; a visit that arrived carrying nothing (a Studio session
-- where the lobby never dealt, a reserved server joined directly) gets its
-- map from here instead, and Roblox back-fills the funnel's "entered" row
-- when "started" arrives.
function Analytics.tutorialStarted(player: Player, cards: number, mapId: string?)
	Analytics.onboarding(player, ONB_STARTED, "tutorial_started")
	Analytics.note("tutorial_start", player, cards, { map = mapId or "?" })
	local s = sessions[player.UserId]
	if s ~= nil and mapId ~= nil then
		local arm = short(mapId, 16)
		if s.arm ~= arm then
			s.arm = arm
			s.armAt = os.time()
			s.armMark = 0
			Analytics.funnel(player, Analytics.PLAY_ARM_PREFIX .. arm, s.fsid, ARM_PLAY_ENTERED, "entered", { map = arm })
		end
	end
	local arm = armOf(player)
	if arm ~= nil then
		Analytics.funnel(player, Analytics.TUTORIAL_ARM_PREFIX .. arm, Analytics.sessionKey(player), ARM_STARTED, "started", { map = arm })
	end
end

-- One card cleared -- either done or skipped as inapplicable. Both are "the
-- player got past it", which is what a funnel step means: a card that does not
-- apply to their round must not read as a wall they hit.
function Analytics.tutorialCard(player: Player, index: number, id: string, skipped: boolean?)
	local props = {
		card = id,
		how = skipped and "skipped" or "done",
	}
	Analytics.onboarding(player, ONB_CARD + index, "card_" .. short(id, 20), props)
	local arm = armOf(player)
	if arm ~= nil then
		Analytics.funnel(
			player,
			Analytics.TUTORIAL_ARM_PREFIX .. arm,
			Analytics.sessionKey(player),
			ARM_CARD + index,
			"card_" .. short(id, 20),
			props
		)
	end
end

function Analytics.tutorialDone(player: Player, cards: number, seconds: number)
	Analytics.onboarding(player, ONB_CARD + cards + 1, "tutorial_complete")
	local arm = armOf(player)
	if arm ~= nil then
		Analytics.funnel(
			player,
			Analytics.TUTORIAL_ARM_PREFIX .. arm,
			Analytics.sessionKey(player),
			ARM_CARD + cards + 1,
			"complete",
			{ map = arm }
		)
	end
	-- Minutes, because that is the number you compare against how long the
	-- track is MEANT to take (measured at 3-3.5 minutes when it shipped). A
	-- completion time drifting up is a card that stopped being obvious.
	-- `map` is the SECOND column here and on the two endings below -- `cards`
	-- and `card` sort ahead of it, so the column they always had is unmoved.
	Analytics.event("tutorial_done", player, seconds / 60, { cards = cards, map = arm or "?" })
	if getProfile ~= nil then
		local ok, profile = pcall(getProfile :: any, player)
		if ok and type(profile) == "table" and type(profile.stats) == "table" then
			profile.stats.tutorials = (tonumber(profile.stats.tutorials) or 0) + 1
			if markDirty ~= nil then
				pcall(markDirty :: any, player)
			end
		end
	end
end

-- THE TWO ENDINGS THAT ARE NOT A FINISH, and they are different problems.
-- `failed` is the game killing them mid-lesson -- the grace window is too
-- short or the round is too hard. `quit` is them closing the game -- the card
-- they were on is boring, confusing or impossible. The card id is the whole
-- point of both, so it is the custom field.
function Analytics.tutorialFailed(player: Player, index: number, id: string)
	Analytics.event("tutorial_failed", player, index, { card = id, map = armOf(player) or "?" })
end

function Analytics.tutorialQuit(player: Player, index: number, id: string)
	Analytics.event("tutorial_quit", player, index, { card = id, map = armOf(player) or "?" })
end

-- =================================================================== match ==

-- A press on the page. Only the three that put you in a queue advance the
-- funnel; the rest are recorded locally, which is enough to tell "nobody
-- presses anything" from "everybody presses LEAVE".
function Analytics.lobbyPress(player: Player, action: string)
	Analytics.note("lobby_press", player, 1, { action = short(action, 16) })
	if action == "tutorial" then
		Analytics.tutorialEntered(player, "command")
	elseif action == "join" or action == "create" or action == "pjoin" then
		Analytics.funnel(
			player,
			Analytics.MATCH_FUNNEL,
			Analytics.sessionKey(player),
			MATCH_QUEUED,
			"queued",
			{ press = action }
		)
		-- THE REPLAY. The same three presses asked a second question, and it
		-- is only asked when there is a finished round behind them: `requeued`
		-- over `returned` is the share who chose to go again, and the rest of
		-- `returned` is the share who left. Once per round -- a player mashing
		-- JOIN is one decision, not six.
		local s = sessions[player.UserId]
		if s ~= nil and s.fin > 0 and not s.again then
			s.again = true
			Analytics.funnel(player, Analytics.MATCH_FUNNEL, s.fsid, MATCH_REQUEUED, "requeued", { press = action })
			-- The minutes between the round ending and the press: how long the
			-- decision took, which is the part of the end-of-round flow you can
			-- actually shorten.
			Analytics.event("match_replay", player, math.max(0, os.time() - s.fin) / 60, {
				press = action,
				result = s.res or "?",
			})
		end
	end
end

-- The teleport went out. `kind` is "public" | "private" | "tutorial".
function Analytics.launched(list: { Player }, kind: string)
	for _, player in list do
		Analytics.funnel(
			player,
			Analytics.MATCH_FUNNEL,
			Analytics.sessionKey(player),
			MATCH_LAUNCHED,
			"launched",
			{ kind = short(kind, 16) }
		)
	end
end

function Analytics.matchStarted(player: Player, map: string?, mode: string?, tutorial: boolean?)
	-- A NEW ROUND ANSWERS THE LAST ONE'S QUESTION. They are here, so they
	-- replayed -- and leaving `fin` armed would make the next mid-round quit
	-- report as somebody who walked out after a finish, which is the opposite
	-- kind of player.
	local s = sessions[player.UserId]
	if s ~= nil then
		s.fin = 0
		s.res = nil
		s.again = false
	end
	Analytics.funnel(player, Analytics.MATCH_FUNNEL, Analytics.sessionKey(player), MATCH_IN, "in_match", {
		map = short(map or "?", 16),
		mode = short(mode or "?", 16),
		kind = tutorial and "tutorial" or "match",
	})
end

function Analytics.matchSpawned(player: Player)
	if not once(player, "spawned") then
		return
	end
	Analytics.funnel(player, Analytics.MATCH_FUNNEL, Analytics.sessionKey(player), MATCH_SPAWNED, "spawned")
end

-- THE STEP THAT SAYS THEY UNDERSTOOD THE GAME. Everything before it can be
-- done by a player who is lost -- you are teleported in and the spawn ring is
-- placed for you -- and this one cannot.
function Analytics.matchAttacked(player: Player)
	if not once(player, "attacked") then
		return
	end
	Analytics.funnel(player, Analytics.MATCH_FUNNEL, Analytics.sessionKey(player), MATCH_ATTACKED, "attacked")
end

function Analytics.matchFinished(player: Player, info: any)
	local minutes = tonumber(info and info.minutes) or 0
	local place = tonumber(info and info.place) or 0
	local result = (info and info.won) and "won" or ((info and info.alive) and "survived" or "out")
	Analytics.funnel(player, Analytics.MATCH_FUNNEL, Analytics.sessionKey(player), MATCH_ENDED, "finished", {
		map = short(info and info.map or "?", 16),
		mode = short(info and info.mode or "?", 16),
		result = result,
	})
	Analytics.event("match_minutes", player, minutes, {
		map = short(info and info.map or "?", 16),
		mode = short(info and info.mode or "?", 16),
		result = result,
	})
	if place > 0 then
		Analytics.event("match_result", player, place, { mode = short(info and info.mode or "?", 16) })
	end
	-- ARMED FOR THE TWO STEPS AFTER THIS ONE. Everything from here is about
	-- what they do NEXT, and the server that sees it is a different one -- so
	-- the end time and the outcome go on the VISIT and ride the teleport home
	-- (see teleportData). Re-armed on every round, so a visit that plays four
	-- matches makes the decision four times.
	local s = sessions[player.UserId]
	if s ~= nil then
		s.fin = os.time()
		s.res = result
		s.again = false
	end
end

-- THE STEP AFTER "finished", exposed because STUDIO HAS NO TELEPORT and a
-- funnel step that can only be reached by one is a funnel step that ships
-- unverified. The live path is `begin` on the lobby, off the payload above;
-- this is the same call by hand.
function Analytics.matchReturned(player: Player, result: string?)
	local s = sessions[player.UserId]
	if s ~= nil then
		noteReturn(player, s, result)
	end
end

-- Left with the round still running. The minutes are the point: quitting at
-- forty seconds and quitting at eleven minutes are not the same event.
function Analytics.matchQuit(player: Player, minutes: number, phase: string?)
	Analytics.event("match_quit", player, minutes, { phase = short(phase or "?", 16) })
end

-- MONEY EARNED, through Roblox's economy report rather than as a bare custom
-- event -- that report already knows how to draw a currency's sources and
-- sinks, and Money is about to have both. `balance` nil means the profile
-- never loaded, and an economy event with a balance this server cannot vouch
-- for is worse than no event at all.
function Analytics.moneyEarned(player: Player, amount: number, balance: number?, source: string?)
	Analytics.event("money_earned", player, amount, { source = short(source or "round", 16) })
	if balance == nil or amount <= 0 then
		return
	end
	pcall(function()
		AnalyticsService:LogEconomyEvent(
			player,
			Enum.AnalyticsEconomyFlowType.Source,
			"Money",
			amount,
			balance,
			Enum.AnalyticsEconomyTransactionType.Gameplay.Name,
			nil,
			remoteFields({ source = short(source or "round", 16) })
		)
	end)
end

-- ================================================================== funnel ==
--
-- `entry` is a Products.Entry. Taken as `any` rather than by importing the
-- type, because this module is deliberately below Products in the dependency
-- order: analytics must never be the reason something fails to load.

local function entryProps(entry: any, extra: { [string]: any }?): { [string]: any }
	local props: { [string]: any } = {
		key = entry and entry.key or "?",
		kind = entry and entry.kind or "?",
	}
	if extra ~= nil then
		for k, v in extra do
			props[k] = v
		end
	end
	return props
end

function Analytics.promptShown(player: Player, entry: any)
	Analytics.event("purchase_prompt_shown", player, 1, entryProps(entry))
end

function Analytics.promptCancelled(player: Player, entry: any)
	Analytics.event("purchase_cancelled", player, 1, entryProps(entry))
end

function Analytics.promptCompleted(player: Player, entry: any, robux: number?)
	Analytics.event("purchase_completed", player, robux or (entry and entry.robux) or 0, entryProps(entry))
end

-- The two failure events worth separating. A grant that failed is a support
-- ticket waiting to happen; an UNKNOWN product means a receipt arrived for
-- something this build has no id for, which is a deploy problem and should be
-- loud.
function Analytics.grantFailed(player: Player, entry: any, why: string)
	Analytics.event("purchase_grant_failed", player, 1, entryProps(entry, { why = why }))
	warn(("[ConquestAnalytics] grant failed for %s: %s (%s)"):format(player.Name, entry and entry.key or "?", why))
end

function Analytics.unknownProduct(player: Player, productId: number)
	Analytics.event("purchase_unknown_product", player, 1, { productId = productId })
	warn(("[ConquestAnalytics] receipt for UNKNOWN product %d from %s -- it is not in Products."):format(productId, player.Name))
end

-- ================================================================= readout ==

function Analytics.counts(): { [string]: number }
	return table.clone(counts)
end

-- Oldest first. For pasting into the output when a purchase went wrong and
-- nobody can remember what happened before it.
function Analytics.recent(n: number?): { any }
	local want = math.min(n or 25, RING)
	local out = {}
	for i = 0, RING - 1 do
		local idx = ((ringNext - 1 + i) % RING) + 1
		if ring[idx] ~= nil then
			table.insert(out, ring[idx])
		end
	end
	while #out > want do
		table.remove(out, 1)
	end
	return out
end

function Analytics.dump(n: number?)
	for _, r in Analytics.recent(n) do
		print(("[analytics] %s %-24s %-16s %s"):format(os.date("!%H:%M:%S", r.t), r.name, r.who, tostring(r.value)))
	end
end

-- EVERY EVENT NAME AND HOW MANY OF IT, sorted. The Studio check: play a round,
-- run this, and read the funnel top to bottom -- the numbers should only ever
-- go down as you walk the ladder, and a step that reads zero is a step that is
-- not wired to anything.
function Analytics.report()
	local names = {}
	for name in counts do
		table.insert(names, name)
	end
	table.sort(names)
	print(("[analytics] ---- %d event kinds, %d players tracked ----"):format(#names, (function()
		local n = 0
		for _ in sessions do
			n += 1
		end
		return n
	end)()))
	for _, name in names do
		print(("[analytics] %-32s %d"):format(name, counts[name]))
	end
end

return Analytics
