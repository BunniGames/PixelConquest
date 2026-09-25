--!strict
-- Conquest :: Tutorial  (shared)
-- The first round a new player is ever put into: a short match on a small
-- roster against THREE AI EMPIRES WEARING REAL PLAYER IDENTITIES -- a name and
-- a Roblox headshot -- so the tutorial reads as a game with people in it rather
-- than as a practice range. The rest of the map is ordinary NPC nations, the
-- same ones every other round runs.
--
-- WIRED 2026-09-01. LEARN TO PLAY on the lobby page reserves a solo match
-- server whose match record carries `tutorial = true`; ConquestServer's
-- `startRound` reads that, builds an ORDINARY round at this file's shape
-- (`Tutorial.rosterSize`), hands the sim to `Tutorial.attach`, arms the grace
-- with `Tutorial.protect`, and drives `advance`/`state` from the same
-- Heartbeat everything else rides on. There is no second round-construction
-- path: `Tutorial.build` below still exists, but only for headless harnesses.
--
-- THE TRACK IS SHOWN, NOT READ (rewritten 2026-09-01, owner: "I don't want one
-- where the player just reads everything, I want active guidance"). Every card
-- that asks for a tap NAMES THE TILE TO TAP -- worked out from the live map,
-- refreshed as the map moves -- and the client rings that tile and points an
-- arrow at it when it is off screen. Cards that ask for a building PAY FOR IT
-- as they go up, and the card that asks for a port is SKIPPED ENTIRELY unless
-- the student holds a coast. What is left for the copy is one short line
-- saying what the tap means. See `the targets` and `the lessons` below.
--
-- THE PHANTOM PLAYERS ARE THE SERVER'S OWN. The wired tutorial does not use
-- `botIds`/`rosterEntries`/`dressSummary` -- ConquestServer already implements
-- those same three lies against its own `fauxIds`, because every ordinary
-- round carries faux players too now. The tutorial is simply a round whose
-- phantom count is fixed at FAUX_COUNT instead of drawn from a lobby card.
-- Editing the identity roster below therefore changes who turns up in live
-- matches as well, not just in the tutorial.
--
-- ============================================================================
-- THE DISGUISE IS A PRESENTATION LAYER, NOT A SIM CONCEPT
-- ============================================================================
-- A faux player is an ORDINARY BOT in the simulation -- `p.isBot` is true,
-- because `Sim.step`'s AI loop is gated on exactly that field (Sim:3485) and an
-- empire flagged human would sit still for the whole round. Only the three
-- places that TELL A CLIENT about the roster lie:
--
--   1. `init.botIds`      -- ConquestServer.botIdList, which decides the colour
--                            every tile is painted before the first summary
--   2. `init.roster[].u`  -- the Roblox user id the headshot is drawn from,
--                            in the standings, on the map label and in the
--                            lobby card. This is the ONLY thing a pfp needs.
--   3. `players[].isBot`  -- the twice-a-second summary flag, which feeds
--                            Palette's bot/player colour split
--
-- Everything else stays on the bot path -- halved income, the transport-boat prey split,
-- the neutral-cost deviation, alliance handling -- which is what keeps a
-- tutorial round balanced like the game it is teaching. `Tutorial.botIds` and
-- `Tutorial.dressSummary` below are those three lies, in one place.
--
-- A FAUX PLAYER'S USER ID IS DELIBERATELY NOT REGISTERED IN `sim.byUserId`.
-- That table is how `Sim.playerByUserId` maps a joining Roblox player to their
-- empire, so a faux empire holding a real friend's id would hand that friend
-- the bot's empire if they ever joined the same server. `addPlayer` writes the
-- lookup whenever it is given an id, so the id goes on AFTERWARDS, by hand.
-- See `addFaux`.

local Config = require(script.Parent.Config)
local Faces = require(script.Parent.Faces)

-- Sim is required LAZILY, inside `Tutorial.build` alone. This module is in the
-- shared folder because the client needs the lesson copy and the identities,
-- and Sim is a 3,500-line server-side module the client has never required and
-- should not start requiring for a table of strings.
local SimModule: any = nil
local function simModule(): any
	if SimModule == nil then
		SimModule = require(script.Parent.Sim) :: any
	end
	return SimModule
end

local Tutorial = {}

-- =============================================================== identities ==

export type Identity = {
	-- The @username. Not drawn anywhere today; kept because a name a player
	-- can look up is what makes the roster survive scrutiny.
	name: string,
	-- What actually appears on the standings row, the map label and the lobby
	-- card. Real players are added by `DisplayName` (ConquestServer:259), so a
	-- faux player has to be too or the two read as different kinds of thing.
	display: string,
	userId: number,
	-- IN THE LIVE ROSTER. `drawIdentities` -- the pool ordinary matches draw
	-- from -- takes only the rows carrying this, so narrowing who turns up in
	-- real games is a flag to move rather than people to delete. The tutorial's
	-- own draw ignores it and still uses everybody.
	live: boolean?,
}

-- The owner's own account. Used for the STUDENT slot whenever the tutorial is
-- run without a real player behind it -- a Studio session, a headless harness,
-- a preview render -- so every screenshot of the tutorial shows the owner's own
-- name and face where a player's would be.
Tutorial.OWNER = {
	name = "8Yoonie",
	display = "8Yoonie",
	userId = 8129406063,
} :: Identity

-- Real accounts, so the headshots are real faces rather than the grey default.
-- Every id here was resolved from the owner's own friends list, which is what
-- makes the roster read as a lobby of people instead of a list of usernames.
-- Ordered roughly by how well the name reads at standings size.
--
-- ONLY THE `live = true` ROWS APPEAR IN ORDINARY MATCHES (owner's call,
-- 2026-09-01): the names he is happy to see on a public standings board --
-- four at first, eight since 2026-09-09 -- plus his own account, which
-- `drawIdentities` adds unconditionally. The rest
-- stay here because the tutorial still draws from all of them and because
-- re-widening the live pool should not mean hunting down user ids again.
Tutorial.FRIENDS = {
	{ name = "4Jezza", display = "Jezza", userId = 420199601 , live = true },
	{ name = "Mekski", display = "Mekski", userId = 677090788 },
	{ name = "Staysail", display = "Sail", userId = 312028889 },
	{ name = "iclipss", display = "iclipse", userId = 385626222 },
	{ name = "Aven_FX", display = "ave", userId = 1937758292 },
	{ name = "catchitoo", display = "catch", userId = 2212463087 },
	{ name = "rTenkel", display = "Tenkel", userId = 296115168 },
	{ name = "kornelek09", display = "Korn", userId = 159671173 },
	{ name = "FlingBlock", display = "FlingBlock", userId = 84041065 },
	{ name = "BaconyPie", display = "BaconyPie", userId = 236404556 },
	{ name = "IamReevox", display = "Reevox", userId = 135038601 },
	{ name = "iiKaritaki", display = "Kari", userId = 152235817 },
	{ name = "ReposedDev", display = "Reposed", userId = 582759237 },
	{ name = "cabotjohn", display = "cabot", userId = 1615479753 , live = true },
	{ name = "LoadingL0n3ly", display = "Fedor", userId = 1045324707 },
	{ name = "BrokenRainer", display = "NotPengu", userId = 155739726 , live = true },
	{ name = "Cheesemill03", display = "Cheesemill", userId = 260425604 , live = true },
	{ name = "TIGERFIST36000", display = "Hypno", userId = 248757795 , live = true },
	-- Added 2026-09-09 (owner: "add my friend CabotJohn, we arephamily,
	-- notbigsurpsie, babypotatoz as potential real player looking AIs"). The
	-- typed names are not the account names: the friend is `wearephamily1`
	-- (not `wearephamily`, a stranger), and NotBigSurprise is the DISPLAY name
	-- of `robloxplayermoneyguy`. All three resolved off the owner's friends
	-- list, like every row above.
	{ name = "wearephamily1", display = "wearephamily1", userId = 9584589144 , live = true },
	{ name = "robloxplayermoneyguy", display = "NotBigSurprise", userId = 139806268 , live = true },
	{ name = "BABYpotatoZ", display = "robby", userId = 286914400 , live = true },
} :: { Identity }

-- The NPC nations. A DUPLICATE of ConquestServer's BOT_NAMES, deliberately:
-- that list is a local inside a server Script and this module is shared, so the
-- alternative is either a require of a Script (impossible) or moving the list
-- into Config, which two sessions have already fought over. Keep them in the
-- same house style -- an NPC that is named differently from every other round's
-- NPCs is a tell that this round is not a real one.
--
-- ONE NAME PER NPC SEAT, NONE LEFT OVER TO BE NUMBERED -- the same rule the
-- server's list states, and `build` falls back to "Draywood 17" the moment it
-- runs out. This is now the WHOLE of BOT_NAMES rather than a slice of it,
-- copied across byte for byte, so it covers any NPC_COUNT up to 80 and the two
-- lists cannot quietly drift apart. Past 80, grow BOT_NAMES and re-copy.
Tutorial.NPC_NAMES = {
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
} :: { string }

-- The one string a pfp needs anywhere in this game. Matches HUD:1436 and
-- NationLabels:343 exactly; `rbxthumb` resolves on the client with no web call
-- and no yield, which is why a faux identity costs nothing but its user id.
function Tutorial.headshot(userId: number, size: number?): string
	local s = size or 150
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=%d&h=%d", userId, s, s)
end

-- ============================================================== match shape ==

-- The US, free-for-all. The tutorial teaches the game every other round plays,
-- so it uses a real map and a real mode rather than a bespoke arena -- and the
-- US is the map whose coastline is legible at a glance, which matters when the
-- lesson is "that blue bit is where a port goes".
Tutorial.MAP_ID = "us"
Tutorial.MODE_ID = "ffa"

-- ======================================================= the map experiment ==
-- WHICH MAP A NEW PLAYER LEARNS ON (owner, 2026-09-08: "create funnels to test
-- the same tutorial on America Map, Europe Map, and World Map, so I can see
-- which one has the highest completion rate"). MAP_ID above is the DEFAULT --
-- what the headless harness builds on and what a player gets if this list is
-- ever emptied -- and this list is the experiment: every player who enters
-- the tutorial is dealt one of these, and ConquestAnalytics names a funnel
-- after it (`tutorial_us`, `tutorial_europe`, `tutorial_world`, plus a
-- `playtime_<map>` ladder beside each).
--
-- DEALT BY USER ID, NOT BY DICE. A player who quits the lesson and types
-- /tutorial must land on the SAME map, or their second attempt counts against
-- a different arm than their first and the completion rates end up measuring
-- who retried rather than which map teaches. `userId % 3` is deterministic,
-- needs no storage, and Roblox ids are handed out sequentially, so it splits
-- three ways evenly.
--
-- THE REST OF THIS FILE DOES NOT KNOW THIS EXISTS. Every card finds its own
-- tile off the live map, the port card already steps itself over on a
-- landlocked start, and the roster is stated outright (rosterSize) -- so the
-- same track runs unchanged on any map in Maps.ORDER. What DOES change with
-- the map is elbow room: 72 empires on the US is ~3,600 tiles each, on the
-- World map ~1,350. See NPC_COUNT for why that is the first dial if a map
-- turns out to drown its students.
--
-- To end the experiment, leave the winner alone in this list (or empty it and
-- set MAP_ID). The funnels keep their names, so the old rows stay readable.
--
-- PAUSED 2026-09-09 (owner, after playing all three: "only keep the US one.
-- just turn off the other ones for now"). Every new player is dealt the US;
-- "europe" and "world" are switched off, not removed -- put them back in this
-- list to resume the deal. `/tutorial europe` / `/tutorial world` still work
-- for the owner and in Studio (MatchmakerServer.tutorialMapFor reads the
-- token off Maps, not off this list), so the other two can still be played
-- by hand without counting anyone else into their funnels.
Tutorial.MAPS = { "us" }

function Tutorial.mapFor(userId: number): string
	local n = #Tutorial.MAPS
	if n == 0 then
		return Tutorial.MAP_ID
	end
	local id = math.floor(math.abs(tonumber(userId) or 0))
	return Tutorial.MAPS[(id % n) + 1]
end

Tutorial.FAUX_COUNT = 3
-- Enough NPCs that the land grab converges in a few minutes instead of the
-- fifteen a full-size round takes: the pressure a tutorial needs is a
-- NEIGHBOUR ARRIVING, and on a sparse map nobody arrives.
--
-- TWELVE -> SIXTY-EIGHT over one afternoon (owner, 2026-09-04: "add more npcs
-- in the tutorial", then "bump npcs to 30", then "yea do 72 then"). The roster
-- is now 72 -- `Config.TARGET_EMPIRES`, THE FULL-SERVER SHAPE -- so the
-- tutorial is played on exactly the board every other round is played on,
-- which is what this file always claimed to want. The paragraph above is kept
-- because it is still the reason a number lives here at all.
--
-- SIXTY-EIGHT, NOT SEVENTY-TWO, and that is not a rounding choice.
-- `startRound` clamps `botCount` to `Config.NUM_BOTS` (72), so an NPC_COUNT of
-- 72 asks for a roster of 76, gets 73, and leaves `rosterSize` telling
-- everyone 76. 1 student + FAUX_COUNT + 68 is the largest roster this file can
-- state truthfully.
--
-- THE COST IS NOT CPU, AND THAT WAS WORTH MEASURING (that is what /simulate is
-- for). Headless on the US, 1 student + filler, mean ms per 100 ms tick:
-- 16 empires 0.77, 34 empires 1.17, 72 empires 1.37, with no tick over 50 ms
-- in thousands. Step cost tracks BORDER LENGTH, not head count, and a tutorial
-- server holds one client, so this is cheaper than the live round it imitates.
--
-- THE COST IS ELBOW ROOM, AND IT IS STEEP. Land already claimed when
-- `GRACE_SECONDS` expires at 90 s: 23% at 16 empires, 42% at 34, **71% at 72**
-- -- the student comes off protection onto a map that is three-quarters spoken
-- for. And the last card asks for 90% of it (`STEPS`, "conquer"): a
-- full-income student took ~8 sim-minutes to finish a 34-empire board and
-- ~29 on a 72-empire one, so that card is now a long war rather than a lesson.
-- IF A NEW PLAYER EVER REPORTS DROWNING, THIS CONSTANT IS THE FIRST DIAL, and
-- `GRACE_SECONDS` is the second -- not the cards, which are all still
-- reachable.
Tutorial.NPC_COUNT = 68

-- Faux players are NATIONS -- the middle AI class. A tribe razes what it
-- captures and never builds, which is the wrong thing to be watching while
-- someone is teaching you to build; a nation expands, builds cities and ports,
-- and behaves like the player it is pretending to be.
Tutorial.FAUX_TIER = Config.TIER_NATION
-- The filler is whatever the live game runs, so the tutorial is not quietly
-- easier or harder than the thing it precedes.
Tutorial.NPC_TIER = Config.DEFAULT_BOT_TIER

-- How long nobody may attack the student. Long enough to read three lesson
-- cards and take some open land; short enough that the first war still happens
-- inside the tutorial rather than after it.
Tutorial.GRACE_SECONDS = 90

-- HOW LONG THE ROUND WAITS ONCE THE STUDENT HAS PICKED THEIR HOMELAND (owner,
-- 2026-09-04: "start the game within 5 seconds of a player choosing a place to
-- start at the beginning for the tutorial").
--
-- A LIVE ROUND HOLDS THE FULL `Config.SPAWN_PHASE_SECONDS` BECAUSE IT IS
-- WAITING FOR OTHER PEOPLE. A tutorial is waiting for nobody: the student is
-- the only human on the server and the other seventy-one empires are placed by
-- `Sim.autoSpawn` on the tick the phase ends, whenever that is. So the rest of
-- the countdown is dead air spent staring at a committed decision -- and it is
-- the very first thing a new player experiences.
--
-- NOT ZERO. The pick has to be seen to land: the preview blob, the tile the
-- map scrolls to, and the first card clearing all need a beat, and a round
-- that starts on the same frame as the tap reads as a misclick.
Tutorial.SPAWN_GRACE_SECONDS = 5

-- THE STUDENT'S OPENING FLOAT. 150,000 -> 0 -> 50,000 over one afternoon
-- (owner, 2026-09-03: "let user start with 50k gold"), and the number is the
-- whole point: it is DELIBERATELY less than a city (Config.CITY_COST_BASE is
-- 125,000), so it is money in the bank while the first cards are about
-- attacking, and not the price of the lesson after them. The build cards
-- still make the student earn their own buildings.
--
-- A PER-STUDENT GRANT, ON TOP OF Tutorial.START_GOLD rather than instead of
-- it. startGold reaches the whole roster and this reaches the student, and
-- since START_GOLD is the larger of the two this top-up is now usually a
-- no-op -- it survives as the floor under a student who has already spent
-- everything by the time the card comes up.
--
-- HANDED OVER AS THE SECOND CARD GOES UP, NOT AT ROUND START, and that is
-- not a preference either. `Sim.spawnPlayer` writes `p.gold = self.startGold
-- or 0` when a homeland is picked, so any float granted before the first
-- card clears is silently wiped by the act of completing it. The second card
-- is the first moment after the spawn, so the grant lives there -- see the
-- `fund` on STEPS.attack.
Tutorial.OPENING_GOLD = 50000

-- WHAT EVERY EMPIRE IN A TUTORIAL OPENS ON -- the student, the faux players
-- and the NPC filler alike (owner, 2026-09-04: "let all ai and players start
-- with 100k in coins during the tutorial").
--
-- THIS ONE IS `sim.startGold`, which is the opposite of the note above it and
-- deliberately so: startGold is the single dial that reaches the WHOLE roster,
-- because Sim.spawnPlayer writes it over an empire's treasury as that empire
-- picks a homeland. That is precisely the reach the student's own float had to
-- avoid and precisely the reach this one needs.
--
-- STILL UNDER THE PRICE OF A CITY (Config.CITY_COST_BASE is 125,000), so the
-- roster does not simply open with a city each and the build lessons still
-- mean something. Read by ConquestServer.startRound, next to the host dials.
Tutorial.START_GOLD = 100000

-- HOW MANY TAPS THE ATTACK CARD ASKS FOR (owner, 2026-09-03: "tap to attack
-- should only show up for 3 taps"). It measured 150 tiles taken instead,
-- which is a fine measure of an attack LANDING and a poor one for the thing
-- the card teaches -- where the control is. Somebody who has used it three
-- times knows where it is; somebody whose three taps happened to bounce off
-- a strong neighbour was still doing it right.
Tutorial.ATTACK_TAPS = 3

-- A BEAT BETWEEN THE TWO BUILDING LESSONS (owner, 2026-09-03: "add some time
-- between placing first city and placing first port"). The city card clears
-- the instant the city lands and the port card was arriving on the same
-- second, so two build prompts back to back read as one long instruction
-- rather than as two things learned. Measured from when the card before was
-- SATISFIED (session.doneTick), not from when it went up, so a fast student
-- waits the same beat as a slow one.
Tutorial.STEP_GAP_SECONDS = 5

-- HOW MUCH STRONGER THE STUDENT IS THAN EVERY OTHER EMPIRE ON THE MAP
-- (owner, 2026-09-04: "in the tutorial, buff the player playing the tutorial
-- by 35% compared to everyone else"). 0.35 -> a multiplier of 1.35, armed by
-- `attach` and enforced by Sim at the two points an empire's strength is
-- actually decided:
--   * 1.35x the ground per army when the student attacks -- open land and
--     enemy land alike (Sim.attackLogic, both branches)
--   * 1.35x the troops it costs ANYBODY to invade the student
--   * 1.35x their gold and troop growth (Sim.step's income pass)
-- One number, because "35% stronger" is one statement about an empire and
-- not three dials to drift apart.
--
-- IT IS NOT THE GRACE AND IT DOES NOT EXPIRE. GRACE_SECONDS is a WINDOW that
-- keeps the first three cards readable; this is a standing tilt that keeps
-- the round winnable for somebody still learning where the controls are,
-- after the window shuts and fifteen empires start playing properly. The
-- measured baseline it answers: a student who does nothing is knocked out
-- about 66 s after the grace ends, and the sim's OWN nation AI -- a better
-- player than any beginner -- finishes only 2nd or 3rd of 16.
--
-- DELIBERATELY NOT A SMALLER ROSTER OR A DUMBER AI. The tutorial teaches the
-- game every other match runs, and an opponent that behaves differently
-- teaches the wrong game; a student who is simply stronger meets the real
-- one. Set this to 0 and a tutorial is an ordinary round again.
Tutorial.STUDENT_BUFF = 0.35

-- ============================================================== the session ==

export type Session = {
	sim: any,
	studentId: number,
	-- Player ids wearing an identity, in roster order.
	faux: { number },
	identityOf: { [number]: Identity },
	graceUntilTick: number,
	-- THE LITE TRACK: a follower's three cards inside a real match. No buff,
	-- no funding, no grace, and the track ends after LITE_LAST. See attach.
	lite: boolean?,
	-- THE FRIEND'S EMPIRE, on a lite session (ConquestServer.startLiteLesson):
	-- never a rival, never the war card's ring, never the neighbour that opens
	-- it, and not what TAP TO ATTACK steers toward. Nil on the full track.
	allyId: number?,

	stepIndex: number,
	stepEnteredTick: number,
	-- Counters snapshotted when the current step began, so a step can ask
	-- "since this card went up" instead of "since the round began".
	mark: { [string]: number },
	-- Taps of the attack control this student has actually landed. The one
	-- counter here that cannot be read back off the sim: reinforcing a front
	-- does not add a second entry to `sim.attacks`, so three taps at one
	-- target are indistinguishable from one. Written by Tutorial.noteAttack.
	attacks: number,
	-- The tick the CURRENT card's `done` first came back true, or nil while
	-- it has not. Only a `ready` on the next card reads it -- "how long since
	-- the thing before me was finished", which is a different question from
	-- how long this card has been up. Cleared by enterStep.
	doneTick: number?,
	-- THE TILE THE CURRENT CARD IS POINTING AT, or nil on a card that is not
	-- asking for a tap. Re-asked every TARGET_REFRESH_TICKS; the finder hands
	-- back the same tile while it is still legal, so this only moves when the
	-- map has made it move.
	target: number?,
	targetTick: number,
	-- Latched the first tick a nuke of the student's is in the air. A launch
	-- cannot be read back off the sim once the warhead has landed -- the
	-- execution is pruned -- so the card that asked for it would forget it had
	-- been obeyed. See `observe`.
	launched: boolean,
	finished: boolean,
	failed: boolean,
}

local function shuffled<T>(list: { T }, rng: Random): { T }
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = rng:NextInteger(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- Deterministic in the seed, so the same run always faces the same three
-- faces -- which is what lets a bug report name them.
--
-- HEADLESS ONLY. The live tutorial's faux players are drawn by
-- ConquestServer through `drawIdentities` like every other round's, so a
-- public tutorial shows the same four names the owner cleared for public
-- standings rather than all eighteen. This one ignores `live` and is what
-- `build` uses.
function Tutorial.pickIdentities(seed: number, count: number, excludeUserId: number?): { Identity }
	local rng = Random.new(seed)
	local pool = {}
	for _, id in Tutorial.FRIENDS do
		-- Never hand a faux empire the identity of the person playing. Two
		-- rows with the same face is the one way this trick reads as fake.
		if id.userId ~= excludeUserId then
			table.insert(pool, id)
		end
	end
	local picked = shuffled(pool, rng)
	local out = {}
	for i = 1, math.min(count, #picked) do
		out[i] = picked[i]
	end
	return out
end

-- THE LIVE ROUND'S POOL: the `live` friends PLUS the owner. The tutorial's own
-- draw above excludes him because he is the STUDENT there; in an ordinary match
-- there is no reason his name should be the one name that never appears.
--
-- `taken` is a SET of user ids that are spoken for -- everybody actually in
-- the server, and every identity already handed out. An empire wearing the
-- face of somebody sitting in the same match is the single thing that gives
-- the whole trick away.
function Tutorial.drawIdentities(
	seed: number,
	count: number,
	taken: { [number]: boolean }?
): { Identity }
	local rng = Random.new(seed)
	local pool = {}
	if not (taken and taken[Tutorial.OWNER.userId]) then
		table.insert(pool, Tutorial.OWNER)
	end
	for _, id in Tutorial.FRIENDS do
		if id.live and not (taken and taken[id.userId]) then
			table.insert(pool, id)
		end
	end
	local picked = shuffled(pool, rng)
	-- ...AND THE CROWD WHEN THE FRIENDS RUN OUT (2026-09-25). An ordinary card
	-- promises one or two faux seats and never reaches here; the Eurasia map
	-- promises sixty (EurasiaMap.FAUX) against nine cleared faces. The friends
	-- still come first so every one of them is in a big round, and the rest
	-- are invented names with negative ids -- see Faces.
	if #picked < count then
		local crowd = {}
		for _, id in Faces.CROWD do
			if not (taken and taken[id.userId]) then
				table.insert(crowd, id)
			end
		end
		for _, id in shuffled(crowd, rng) do
			table.insert(picked, id)
		end
	end
	local out = {}
	for i = 1, math.min(count, #picked) do
		out[i] = picked[i]
	end
	return out
end

-- A faux empire: a bot in every mechanical sense, wearing a person's name and
-- face. The user id is attached AFTER addPlayer rather than passed to it --
-- see the header. `tier` is passed through because addPlayer rolls a bot's
-- whole personality (think period, reserve ratios) off it at creation.
local function addFaux(sim: any, identity: Identity, tier: number): any
	local p = sim:addPlayer(identity.display, true, nil, tier, nil, true)
	if p == nil then
		return nil
	end
	p.userId = identity.userId
	return p
end

-- How many empires a tutorial round holds, all in: the student, the faux
-- players and the NPC filler. ConquestServer's roster maths is a share of the
-- map's playable land (69 empires on the US) and this is a lesson, so the
-- tutorial states its roster outright instead.
function Tutorial.rosterSize(): number
	return 1 + Tutorial.FAUX_COUNT + Tutorial.NPC_COUNT
end

-- Wraps a Session around a sim SOMEBODY ELSE BUILT, which is how the live
-- tutorial runs. `startRound` already owns roster construction, the init
-- broadcast, `_G.ConquestSim` and the tick loop; a tutorial that built its own
-- sim beside all that would be a second copy of a round, quietly diverging
-- from the one every other player is in.
--
-- `identityOf` is the id -> Identity map the caller already has (ConquestServer
-- keeps `fauxIds` for the same three lies). It is read by `isFaux` and by
-- nothing else, so passing nothing costs the session only that answer.
function Tutorial.attach(sim: any, studentId: number, identityOf: { [number]: Identity }?, lite: boolean?): Session
	local known = identityOf or {}
	local faux: { number } = {}
	for _, id in sim.playerOrder do
		if known[id] ~= nil then
			table.insert(faux, id)
		end
	end
	local session: Session = {
		sim = sim,
		studentId = studentId,
		faux = faux,
		identityOf = known,
		graceUntilTick = if lite then 0 else math.floor(Tutorial.GRACE_SECONDS / Config.TICK_DT),
		lite = lite == true,
		stepIndex = 1,
		stepEnteredTick = 0,
		mark = {},
		attacks = 0,
		doneTick = nil,
		target = nil,
		targetTick = 0,
		launched = false,
		finished = false,
		failed = false,
	}
	-- THE STUDENT'S TILT, ARMED HERE RATHER THAN BESIDE `protect`. The grace
	-- is a window ConquestServer chooses to open and could reasonably choose
	-- not to; the buff is a property of a sim HAVING a student in it at all.
	-- Arming it where the session is built means there is no second call site
	-- to forget, and the headless harness (`Tutorial.build`, which comes
	-- through here) measures the same round the live tutorial plays.
	if not lite then
		session.sim.buffId = studentId
		session.sim.buffMult = 1 + Tutorial.STUDENT_BUFF
	end

	-- A lite student already holds land, so the track opens on the attack
	-- card rather than the spawn one.
	Tutorial.enterStep(session, if lite then Tutorial.LITE_FIRST else 1)
	return session
end

-- CUTS THE SPAWN COUNTDOWN SHORT ONCE THE STUDENT HAS CHOSEN. Called every
-- tick of the spawn phase by ConquestServer; returns true on the tick it
-- actually moved the clock, which is the tick the client needs to be told
-- about (the countdown it draws is `SPAWN_PHASE_SECONDS - phaseTick * TICK_DT`
-- off the ordinary summary, so this jump rides a channel that already exists).
--
-- MOVES THE CLOCK, DOES NOT END THE PHASE, and that is the whole reason this
-- is three lines rather than a second spawn path. `Sim.step` still ends the
-- phase itself, in its own order -- everyone who chose gets `commitSpawn`
-- first, THEN the unplaced roster is dropped into what is left -- so a
-- tutorial that ended the phase by hand would be reimplementing that order and
-- would eventually disagree with it.
--
-- IDEMPOTENT AND ONE-WAY: it can only ever bring the clock forward, so it can
-- run every tick, and a student who picks with less than SPAWN_GRACE_SECONDS
-- left keeps the shorter wait they already had.
function Tutorial.hurrySpawn(session: Session): boolean
	local sim = session.sim
	if sim.phase ~= "spawn" then
		return false
	end
	local p = Tutorial.student(session)
	-- `spawnPreview` is the pick, not `spawned` -- the tile is only committed
	-- when the phase ends, which is the thing being hurried.
	if p == nil or p.spawnPreview == nil then
		return false
	end
	local target = math.max(
		0,
		(Config.SPAWN_PHASE_SECONDS - Tutorial.SPAWN_GRACE_SECONDS) * Config.TICK_RATE
	)
	if sim.phaseTick >= target then
		return false
	end
	sim.phaseTick = target
	return true
end

-- Arms the sim's own refusal for this session's student, and it is the only
-- thing that ever sets those two fields. The RULE lives in Sim (a refusal
-- inside launchAttack and launchTransportBoat, exactly where the spawn
-- immunity lives); the WINDOW is this file's number.
function Tutorial.protect(session: Session)
	session.sim.protectId = session.studentId
	session.sim.protectUntil = session.graceUntilTick
end

-- ONE TAP OF THE ATTACK CONTROL. Called from ConquestServer's attack intent,
-- and only for a tap that actually LAUNCHED something: a refusal is somebody
-- reaching for the control and missing, and a card that clears on three
-- misses has taught nothing.
--
-- Guarded on the student here rather than trusting the caller. This is the
-- only thing a step reads that does not come off the sim, so another player's
-- tap must not be able to advance the student's track.
function Tutorial.noteAttack(session: Session, playerId: number)
	if playerId ~= session.studentId then
		return
	end
	session.attacks += 1
end

-- Builds the whole round: the sim, the student, the three faux players and the
-- NPC filler, left in the SPAWN phase with nobody placed. The caller drives it
-- exactly like a normal round from here (`sim:step()` on the tick loop).
--
-- opts (all optional):
--   seed        integer; also picks which three friends turn up
--   name        the student's display name   (default: the owner's)
--   userId      the student's Roblox user id (default: the owner's)
--   mapId, modeId, fauxCount, npcCount
--
-- HEADLESS ONLY -- see the header. A live tutorial goes through `attach`,
-- because the round it teaches has to be built by the thing that builds every
-- other round.
function Tutorial.build(opts: any?): Session
	local o: any = opts or {}
	local Sim = simModule()

	local seed = o.seed or math.random(1, 1000000)
	local mapId = o.mapId or Tutorial.MAP_ID
	local modeId = o.modeId or Tutorial.MODE_ID
	local fauxCount = o.fauxCount or Tutorial.FAUX_COUNT
	local npcCount = o.npcCount or Tutorial.NPC_COUNT

	local studentName = o.name or Tutorial.OWNER.display
	local studentUserId = o.userId or Tutorial.OWNER.userId

	local sim = Sim.new(mapId, seed, modeId)

	-- The student FIRST, for the same reason ConquestServer adds humans first:
	-- low ids get the brighter, more separable colours.
	local student = sim:addPlayer(studentName, false, studentUserId)
	-- No opening float, exactly as a live round: Sim.spawnPlayer writes
	-- `self.startGold or 0` over the student's treasury the moment a homeland
	-- is picked, so anything set here would be wiped anyway.

	local identities = Tutorial.pickIdentities(seed, fauxCount, studentUserId)
	local identityOf: { [number]: Identity } = {}
	for _, identity in identities do
		local p = addFaux(sim, identity, Tutorial.FAUX_TIER)
		if p ~= nil then
			identityOf[p.id] = identity
		end
	end

	-- NPC filler, named and shuffled the way a live round names its bots.
	local names = shuffled(Tutorial.NPC_NAMES, Random.new(seed + 1))
	for i = 1, npcCount do
		local nth = ((i - 1) % #names) + 1
		local suffix = i > #names and (" " .. tostring(i)) or ""
		sim:addPlayer(names[nth] .. suffix, true, nil, Tutorial.NPC_TIER)
	end

	sim.phase = "spawn"
	sim.phaseTick = 0

	return Tutorial.attach(sim, student.id, identityOf)
end

function Tutorial.student(session: Session): any
	return session.sim.players[session.studentId]
end

function Tutorial.isFaux(session: Session, playerId: number): boolean
	return session.identityOf[playerId] ~= nil
end

-- ================================================================= disguise ==
-- The three lies, in one place, for a session built by `build`.
--
-- THE LIVE SERVER DOES NOT CALL THESE. Faux players outgrew the tutorial --
-- every ordinary round carries a few now -- so ConquestServer implements the
-- same three against its own `fauxIds` and the tutorial gets them for free by
-- being an ordinary round. These stay because a headless session built by
-- `build` has no server to do it, and because this is where the trick is
-- written down.

-- The `botIdList()` of a headless session. A faux id must NOT be in here or
-- the client paints its territory in a bot colour the instant the snapshot
-- lands -- and correcting that later costs a full-map repaint.
function Tutorial.botIds(session: Session): { number }
	local ids = {}
	for _, id in session.sim.playerOrder do
		local p = session.sim.players[id]
		if p and p.isBot and not Tutorial.isFaux(session, id) then
			table.insert(ids, id)
		end
	end
	return ids
end

-- The `roster()` of a headless session. Identical shape ({i, n, u}); the
-- only difference is that a faux entry HAS a `u`, which is the whole pfp.
function Tutorial.rosterEntries(session: Session): { any }
	local list = {}
	for _, id in session.sim.playerOrder do
		local p = session.sim.players[id]
		if p then
			table.insert(list, { i = p.id, n = p.name, u = p.userId })
		end
	end
	return list
end

-- Run over a headless `playerSummary()` before Net.packPlayers. Mutates in
-- place and returns the same list, so the call site is one wrapper.
function Tutorial.dressSummary(session: Session, list: { any }): { any }
	for _, e in list do
		if Tutorial.isFaux(session, e.id) then
			e.isBot = false
		end
	end
	return list
end

-- ==================================================================== grace ==

-- Whether an AI is allowed to attack the student yet. A tutorial that opens
-- with a nation walking into you before the third card is a tutorial nobody
-- finishes -- and on a small roster with the student holding the brightest
-- colour, somebody always does.
--
-- The sim enforces this itself once `Tutorial.protect` has armed it -- a
-- refusal in `launchAttack` and `launchTransportBoat`, beside the spawn
-- immunity. This is the READ, for anything that wants to say so on screen.
function Tutorial.mayAttackStudent(session: Session): boolean
	return session.sim.tick >= session.graceUntilTick
end

function Tutorial.graceRemaining(session: Session): number
	return math.max(0, (session.graceUntilTick - session.sim.tick) * Config.TICK_DT)
end

-- ============================================================== the targets ==
-- WHAT MAKES THIS TUTORIAL GUIDED RATHER THAN READ. Every card that asks for a
-- tap also names THE TILE TO TAP, worked out from the live map each time it is
-- refreshed, and the client draws a ring on that tile plus an arrow to it when
-- it is off screen. The copy then only has to say what the tap MEANS -- the
-- ring is what says where, and a ring is not something anybody has to read.
--
-- EVERY FINDER TAKES THE TILE IT GAVE LAST AND RETURNS IT UNCHANGED WHILE IT IS
-- STILL A LEGAL ANSWER. The map moves constantly -- ground is taken, coasts
-- change hands -- and a ring that hops to a different tile every couple of
-- seconds is harder to follow than no ring at all. So a target only moves when
-- the one before it stopped being true.
--
-- All of them are cheap and none of them yield: they walk the student's OWN
-- border (a set the sim already maintains, a few hundred tiles even late on)
-- or spiral out from the student's own centroid (`sumX`/`sumY`, which the sim
-- keeps for the bot city placer). Nothing here scans the map.

-- TileMap and Economy are required LAZILY, for the same reason Sim is: this
-- module sits in the shared folder so the client can be handed its lesson copy,
-- and only a server ever asks for a target. Economy is the one that matters --
-- it drags Units in behind it.
local TileMapModule: any = nil
local EconomyModule: any = nil
-- The LAST card's denominator. The win check divides by contestable land, so
-- the final lesson has to complete on exactly the number the round ends on.
local NukesModule: any = nil
local function tileMap(): any
	if TileMapModule == nil then
		TileMapModule = require(script.Parent.TileMap) :: any
	end
	return TileMapModule
end
local function economy(): any
	if EconomyModule == nil then
		EconomyModule = require(script.Parent.Economy) :: any
	end
	return EconomyModule
end
local function nukes(): any
	if NukesModule == nil then
		NukesModule = require(script.Parent.Nukes) :: any
	end
	return NukesModule
end
-- The build cards' "is it down yet" read. p.cityCount / p.portCount are the
-- COMPLETED mirror (Units.statAdd writes n - uc), which is the right number
-- for the cost curve and the wrong one for a lesson: the button went on
-- pulsing green for the whole construction time after the student had done
-- exactly what it asked (owner, 2026-09-11: "it stops lighting up green after
-- the building finished building instead of when its placed down").
-- Units.structureCount is `n` -- placed, finished or not.
local UnitsModule: any = nil
local function units(): any
	if UnitsModule == nil then
		UnitsModule = require(script.Parent.Units) :: any
	end
	return UnitsModule
end

local W = Config.MAP_W
-- Wanted by nearMe's box scan below, which is the only thing in this file
-- that walks in two dimensions rather than over a border set.
local H = Config.MAP_H

-- How often a target is re-asked. HALF A SECOND, and it is deliberately short:
-- a ring pointing at ground the student took two seconds ago is a ring whose
-- tap the server REFUSES, which is worse than no ring -- measured, at two
-- seconds, as an "own" refusal on the grow card. The cost of the check is
-- nothing, because every finder's first move is to hand back the tile it gave
-- last if that is still legal, which is a handful of buffer reads; the border
-- walk only runs on a target that has genuinely died.
Tutorial.TARGET_REFRESH_TICKS = 5

-- Ceiling on how much of the border one search walks. Generous on purpose:
-- `next` order is arbitrary, so a SHORT cap does not sample the border evenly,
-- it truncates it -- and "is anybody next to me yet", which gates the war card,
-- is a question a truncated walk answers WRONG. Measured: a student holding
-- 6,353 tiles had a 554-tile border, so this is a full walk for any round a
-- tutorial lasts, with a bound left in for the pathological case.
local BORDER_SAMPLE = 2500
-- The same ceiling for the "nobody is next to me yet" sweep, which is per
-- RIVAL rather than per student -- fifteen empires deep, so it is kept
-- shorter. It only runs while the student has no neighbour at all, i.e. in the
-- opening minutes when every border is small anyway.
local FAR_SAMPLE = 120

-- Two scratch neighbour lists, because the outer walk and the inner scoring
-- walk are live at the same time and one shared list would have the inner one
-- overwrite the tile the outer one is standing on.
local nbA: { number } = {}
local nbB: { number } = {}

local function ownerAt(sim: any, tile: number): number
	return buffer.readu8(sim.map.owner, tile)
end

-- Is any ground this player holds within `r` tiles of `tile`? A plain
-- adjacency test used to live beside this and was the thing every ring was
-- judged by; it is gone because NO ring sits on the frontier any more --
-- neither the enemy one nor, since 2026-09-04, the open-ground one: a target ENEMY_DEPTH tiles inside an empire is never adjacent
-- to the student, so the plain adjacency test would judge every good ring
-- stale and move it on every refresh -- twice a second, which is the exact
-- jitter the "hand back the tile you gave last" rule above exists to prevent.
--
-- A box scan, not a walk: (2r+1)^2 buffer reads, a few dozen at the radius
-- this is called with, which is what keeps the fast path fast.
local function nearMe(sim: any, tile: number, playerId: number, r: number): boolean
	local x = tile % W
	local y = (tile - x) / W
	for dy = -r, r do
		local yy = y + dy
		if yy >= 0 and yy < H then
			for dx = -r, r do
				local xx = x + dx
				if xx >= 0 and xx < W and ownerAt(sim, yy * W + xx) == playerId then
					return true
				end
			end
		end
	end
	return false
end

-- HOW FAR PAST THE SEAM THE ENEMY RING SITS (owner, 2026-09-03: "tap to
-- attack, the circle for it is always right on the border, make a slightly
-- more in enemy territory" -- said twice, because two tiles did not do it).
--
-- FOURTEEN, AND IT IS MEASURED rather than reasoned. The client draws the ring
-- at max(18, 14 * zoom) PIXELS across and one tile is exactly `zoom` pixels, so
-- that circle is FOURTEEN TILES WIDE at every zoom -- radius seven. A centre
-- seven tiles in is therefore only just TANGENT to the seam, and tangent still
-- reads as a ring ON the border. Which is what the owner kept saying: three
-- times, 2026-09-03, the third time with a screenshot.
--
-- `deepen` searches a BALL of this radius and keeps the most inland tile in
-- it, so this is a search budget rather than a distance -- what comes back is
-- always less. Measured against discs of radius 12 / 20 / 35 tiles, seeded on
-- the border, the tile it hands back sits this far from the empire's own edge:
--   depth  7 ->  5,  6,  6 tiles  (0.06 ms)  the ring still pokes out
--   depth 10 ->  7,  8,  8 tiles  (0.15 ms)  it only just fits
--   depth 14 ->  8, 10, 11 tiles  (0.30 ms)  three tiles of margin
--   depth 18 ->  8, 13, 14 tiles  (0.77 ms)  2.5x the cost for 3 more tiles
-- Fourteen is where that curve stops paying. The cost is charged only when a
-- target has actually died -- at most twice a second -- so 0.3 ms is nothing.
--
-- A radius-12 empire saturates at 8 whatever the budget, because there is no
-- deeper tile in it to find. That is the honest answer, and it is why deepen
-- MAXIMISES a score instead of requiring a depth -- see its own note.
local ENEMY_DEPTH = 14

-- How far the student's ground may drift from a ring ALREADY PLACED before it
-- is recomputed. See enemyTarget for why this cannot be ENEMY_DEPTH + 1.
local ENEMY_KEEP = ENEMY_DEPTH * 2
-- THE RING'S OWN RADIUS IN TILES. The client draws it max(18, 14 * zoom)
-- PIXELS across and one tile is exactly `zoom` pixels, so the circle is
-- fourteen tiles wide at every zoom. A target this far in is a circle sitting
-- entirely over enemy ink, which is the whole ask.
local RING_TILES = 7

-- THE OPEN-GROUND TWINS. Same numbers as the enemy pair and for the same
-- reason -- the ring the client draws is fourteen tiles wide whichever side of
-- the seam it is on -- but named separately because they are read by different
-- code and one may want to move without the other.
local OPEN_DEPTH = ENEMY_DEPTH
local OPEN_KEEP = OPEN_DEPTH * 2

-- EXACT distance from `tile` to the nearest tile this empire does NOT hold,
-- capped. Rings outward and stops at the first foreign tile, so a border tile
-- costs eight reads and only a genuinely deep one pays the cap.
--
-- This JUDGES two finished candidates. It is never used to search -- doing
-- that was measured at 3 ms a call, ten times the budget, for an answer worse
-- than the cheap aim below.
local function tileDepth(sim: any, tile: number, owner: number, cap: number): number
	local buf = sim.map.owner
	local x = tile % W
	local y = (tile - x) / W
	for r = 1, cap do
		if x < r or y < r or x >= W - r or y >= H - r then
			return r - 1
		end
		for dy = -r, r do
			local row = (y + dy) * W + x
			if dy == -r or dy == r then
				for dx = -r, r do
					if buffer.readu8(buf, row + dx) ~= owner then
						return r - 1
					end
				end
			elseif buffer.readu8(buf, row - r) ~= owner
				or buffer.readu8(buf, row + r) ~= owner
			then
				return r - 1
			end
		end
	end
	return cap
end

-- HOW FAR THIS EMPIRE'S GROUND RUNS FROM `tile` IN EACH OF THE FOUR
-- DIRECTIONS, smallest of the four, capped at `cap`. Zero on a border tile.
-- A cheap, MONOTONE stand-in for tileDepth -- four short rays instead of a
-- ring walk -- and it exits the moment one ray hits zero, which is the common
-- case and costs four reads. Good enough to SEARCH with, too noisy on a jagged
-- border to trust as the final word; that is what tileDepth is for.
local function inset(sim: any, tile: number, owner: number, cap: number): number
	local buf = sim.map.owner
	local x = tile % W
	local y = (tile - x) / W
	local function ray(stride: number, room: number): number
		local lim = math.min(cap, room)
		for k = 1, lim do
			if buffer.readu8(buf, tile + stride * k) ~= owner then
				return k - 1
			end
		end
		return lim
	end
	local best = math.min(ray(1, W - 1 - x), ray(-1, x))
	if best == 0 then
		return 0
	end
	return math.min(best, ray(W, H - 1 - y), ray(-W, y))
end

-- STEP `depth` TILES FROM THE SEAM TOWARD THE EMPIRE'S OWN CENTRE OF MASS,
-- then snap to the nearest ground it actually holds.
--
-- THE CENTROID IS FREE -- the sim already keeps the coordinate sums -- and on
-- any ordinary blobby country this beats searching. Measured over 317 border
-- seeds of a lumpy 22-tile empire: a mean of 9.2 tiles from the edge, where a
-- breadth-first search on the same budget managed 6.5 and an EXACTLY scored
-- one managed 8.0 for ten times the cost. A straight line at the middle is
-- also immune to the jagged coast that defeats every per-tile score.
--
-- What it cannot do is the CONCAVE case: a crescent's centre of mass lies in
-- the bite, so the snap comes back to a border. That is the only reason the
-- ball below still exists.
local function aimInland(s: Session, tile: number, owner: number, depth: number): number
	local sim = s.sim
	local q = sim.players[owner]
	if q == nil or q.tileCount <= 0 then
		return tile
	end
	local x = tile % W
	local y = (tile - x) / W
	local dx = q.sumX / q.tileCount - x
	local dy = q.sumY / q.tileCount - y
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1 then
		return tile
	end
	-- NEVER PAST THE MIDDLE: a small country would otherwise be overshot and
	-- the snap would drag the ring out the far side.
	local step = math.min(depth, len)
	local ax = math.floor(x + dx / len * step + 0.5)
	local ay = math.floor(y + dy / len * step + 0.5)
	local buf = sim.map.owner
	for r = 0, depth do
		for dyy = -r, r do
			local yy = ay + dyy
			if yy >= 0 and yy < H then
				local row = yy * W
				for dxx = -r, r do
					if math.max(math.abs(dxx), math.abs(dyy)) == r then
						local xx = ax + dxx
						if xx >= 0 and xx < W and buffer.readu8(buf, row + xx) == owner then
							return row + xx
						end
					end
				end
			end
		end
	end
	return tile
end

-- The most inland tile of this empire within `depth` STEPS of the seed, by
-- breadth-first walk over its own ground scored with `inset`. Slower and
-- shallower than the aim above on an ordinary country, and the only thing that
-- works on a crescent -- it cannot leave the empire, so it cannot fall in a
-- bite. Kept purely as deepen's fallback.
local function ballInland(s: Session, tile: number, owner: number, depth: number): number
	local sim = s.sim
	local TileMap = tileMap()
	local frontier = { tile }
	local seen: { [number]: boolean } = { [tile] = true }
	local best = tile
	local bestIn = inset(sim, tile, owner, depth)
	for _ = 1, depth do
		local nxt: { number } = {}
		for _, t in frontier do
			local n = TileMap.neighbors4(t, nbB)
			for i = 1, n do
				local u = nbB[i]
				if not seen[u] and ownerAt(sim, u) == owner then
					seen[u] = true
					nxt[#nxt + 1] = u
					local d = inset(sim, u, owner, depth)
					if d > bestIn then
						best, bestIn = u, d
					end
				end
			end
		end
		if #nxt == 0 then
			break
		end
		frontier = nxt
	end
	return best
end

-- MOVE A RING OFF THE SEAM AND INTO THE COUNTRY. Two candidates, judged by
-- the same exact measure, best one wins.
--
-- AIM FIRST AND USUALLY STOP THERE: if the straight line at the centre of mass
-- already clears the ring's own radius, the ball is never walked and the whole
-- call is about 0.15 ms. The fallback is for the crescent, which is the one
-- shape the aim gets wrong.
--
-- Three earlier versions of this shipped ON THE SEAM and each was measured
-- only by eye. The rule this file now follows: the answer is whatever the
-- harness says, not whatever the reasoning says.
local function deepen(s: Session, tile: number, depth: number): number
	local sim = s.sim
	local owner = ownerAt(sim, tile)
	if owner == 0 then
		return tile
	end
	local a = aimInland(s, tile, owner, depth)
	local da = tileDepth(sim, a, owner, depth)
	if da >= RING_TILES then
		return a
	end
	local b = ballInland(s, tile, owner, depth)
	if tileDepth(sim, b, owner, depth) > da then
		return b
	end
	return a
end

-- ============================================================ open ground ==
--
-- THE SAME RULE ON THE OTHER SIDE OF THE SEAM (owner, 2026-09-04: "you know
-- how attack a rival is more inland than on the border, i want it to be the
-- same for the first 3 attacks, the open land at the beginning too").
--
-- The open ring had exactly the fault the enemy ring had, and for exactly the
-- same reason: `openTarget` finds its tile by walking the NEIGHBOURS OF THE
-- STUDENT'S OWN BORDER, so what it returns is always a tile touching them.
-- Measured over 92 seam tiles of a real round: mean clearance 0.0 tiles, 0% of
-- rings clearing their own radius. Every single one sat on the line.
--
-- AFTER, over three seeds of a real tutorial, sampled every tick the attack
-- card was up: 0% of rings still touching the student (was 100%), mean
-- clearance 3.3 / 5.2 / 5.4 tiles, and the ring moved 1-3 times in hundreds of
-- ticks -- 0.02-0.06 a second, i.e. the OPEN_KEEP test above is doing its job
-- and the ring is not walking around the field.
--
-- IT DOES NOT REACH RING_TILES AT THE CURRENT ROSTER, AND THAT IS THE
-- ROSTER'S DOING, NOT THIS CODE'S. Searching EVERY open tile reachable from
-- every seam tile -- the exhaustive ceiling, not a heuristic -- finds a best
-- possible clearance of 1.8 tiles at 72 empires, with NO tile anywhere on the
-- student's frontier able to clear the ring's radius. The corridors between
-- seventy-two starting blobs are two to four tiles wide; there is nowhere
-- deeper to put it. The same measurement at a 16-empire roster: ceiling 7.7,
-- and 94% of seams with a tile that clears the ring. So this function is
-- already at the ceiling, and the number that would move it is
-- `Tutorial.NPC_COUNT`.
--
-- THE MEASUREMENT THAT MATTERS MORE, found while taking the one above: at 72
-- empires the student's starting blob comes out at 79 tiles rather than the
-- ~377 a SPAWN_RADIUS of 11 describes (the neighbours' blobs truncate it), and
-- by 42 SECONDS they have NO open ground adjacent at all -- the open-land card
-- is still up and there is no longer a ring for it to draw. See NPC_COUNT.
--
-- THE WATER TRAP IS WHY NONE OF THE GEOMETRY ABOVE IS REUSED AS-IS. `ownerAt`
-- reads 0 for every OCEAN tile as well as every unclaimed field, so
-- `tileDepth` / `inset` / `ballInland` called with owner 0 would score the open
-- Atlantic as the most inland ground on the map and put the ring out at sea.
-- Every test down here reads the TERRAIN buffer as well as the owner one.

-- EXACT clearance from `tile` to the nearest tile that is not open ground.
-- The openDepth twin of tileDepth, and it JUDGES two finished candidates --
-- never used to search.
local function openDepth(sim: any, TileMap: any, tile: number, cap: number): number
	local map = sim.map
	local buf = map.owner
	local x = tile % W
	local y = (tile - x) / W
	local function free(i: number): boolean
		return buffer.readu8(buf, i) == 0 and TileMap.isPassable(map, i)
	end
	for r = 1, cap do
		if x < r or y < r or x >= W - r or y >= H - r then
			return r - 1
		end
		for dy = -r, r do
			local row = (y + dy) * W + x
			if dy == -r or dy == r then
				for dx = -r, r do
					if not free(row + dx) then
						return r - 1
					end
				end
			elseif not free(row - r) or not free(row + r) then
				return r - 1
			end
		end
	end
	return cap
end

-- Four short rays, smallest of the four. The `inset` twin: monotone, cheap,
-- too noisy on a ragged coast to be the final word, which is what the ball
-- below searches with and openDepth judges with.
local function openInset(sim: any, TileMap: any, tile: number, cap: number): number
	local map = sim.map
	local buf = map.owner
	local x = tile % W
	local y = (tile - x) / W
	local function ray(stride: number, room: number): number
		local lim = math.min(cap, room)
		for k = 1, lim do
			local i = tile + stride * k
			if buffer.readu8(buf, i) ~= 0 or not TileMap.isPassable(map, i) then
				return k - 1
			end
		end
		return lim
	end
	local best = math.min(ray(1, W - 1 - x), ray(-1, x))
	if best == 0 then
		return 0
	end
	return math.min(best, ray(W, H - 1 - y), ray(-W, y))
end

-- STEP `depth` TILES FROM THE SEAM DIRECTLY AWAY FROM THE STUDENT'S OWN CENTRE
-- OF MASS, then snap to the nearest open ground.
--
-- The open-ground mirror of `aimInland`, and the direction is the whole idea:
-- out here there is no empire to aim INTO, and the way that leads off your own
-- ink is the way the free land is. The centroid is free -- the sim keeps the
-- coordinate sums -- so this is a few dozen buffer reads.
local function openAim(s: Session, TileMap: any, tile: number, depth: number): number
	local sim = s.sim
	local map = sim.map
	local p = Tutorial.student(s)
	if p == nil or p.tileCount <= 0 then
		return tile
	end
	local x = tile % W
	local y = (tile - x) / W
	local dx = x - p.sumX / p.tileCount
	local dy = y - p.sumY / p.tileCount
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1 then
		return tile
	end
	local ax = math.floor(x + dx / len * depth + 0.5)
	local ay = math.floor(y + dy / len * depth + 0.5)
	local buf = map.owner
	for r = 0, depth do
		for dyy = -r, r do
			local yy = ay + dyy
			if yy >= 0 and yy < H then
				local row = yy * W
				for dxx = -r, r do
					if math.max(math.abs(dxx), math.abs(dyy)) == r then
						local xx = ax + dxx
						if xx >= 0
							and xx < W
							and buffer.readu8(buf, row + xx) == 0
							and TileMap.isPassable(map, row + xx)
						then
							return row + xx
						end
					end
				end
			end
		end
	end
	return tile
end

-- The most open tile within `depth` steps of the seed, by breadth-first walk
-- over open ground scored with openInset. The `ballInland` twin: it cannot
-- leave the open region, so it is the one that survives a bay or a valley the
-- straight aim above would step across. Kept purely as the fallback.
local function openBall(s: Session, TileMap: any, tile: number, depth: number): number
	local sim = s.sim
	local map = sim.map
	local buf = map.owner
	local frontier = { tile }
	local seen: { [number]: boolean } = { [tile] = true }
	local best = tile
	local bestIn = openInset(sim, TileMap, tile, depth)
	for _ = 1, depth do
		local nxt: { number } = {}
		for _, t in frontier do
			local n = TileMap.neighbors4(t, nbB)
			for i = 1, n do
				local u = nbB[i]
				if not seen[u] and buffer.readu8(buf, u) == 0 and TileMap.isPassable(map, u) then
					seen[u] = true
					nxt[#nxt + 1] = u
					local d = openInset(sim, TileMap, u, depth)
					if d > bestIn then
						best, bestIn = u, d
					end
				end
			end
		end
		if #nxt == 0 then
			break
		end
		frontier = nxt
	end
	return best
end

-- MOVE THE FIRST RING OFF THE SEAM AND OUT INTO THE FREE LAND. Same shape as
-- `deepen`: aim first and usually stop there, walk the ball only when the aim
-- fails to clear the ring's own radius, judge both by the same exact measure.
--
-- SAFE FOR THE SAME REASON THE ENEMY RING IS. Sim.launchAttack reads the
-- tapped tile for its OWNER and its passability and nothing else, and
-- seedFrontier for an unclaimed target walks the ATTACKER's border enqueuing
-- every open tile beside it -- so a ring fourteen tiles out into the field
-- launches precisely the expansion a ring on the seam launches. The seed still
-- comes from a tile that genuinely touches the student, so "there is open
-- ground next to you" stays a fact the search proved rather than one this
-- assumes.
local function deepenOpen(s: Session, tile: number, depth: number): number
	local sim = s.sim
	local TileMap = tileMap()
	if ownerAt(sim, tile) ~= 0 or not TileMap.isPassable(sim.map, tile) then
		return tile
	end
	local a = openAim(s, TileMap, tile, depth)
	local da = openDepth(sim, TileMap, a, depth)
	if da >= RING_TILES then
		return a
	end
	local b = openBall(s, TileMap, tile, depth)
	if openDepth(sim, TileMap, b, depth) > da then
		return b
	end
	return a
end

-- The centre of mass of the nearest empire that is not the student's, or nil
-- before anybody else has ground. O(roster) off sums the sim already keeps --
-- no walk at all -- which is what makes it affordable inside a target search.
local function nearestRivalCentre(s: Session): (number?, number?)
	local sim = s.sim
	local p = Tutorial.student(s)
	if p == nil or p.tileCount <= 0 then
		return nil, nil
	end
	local cx, cy = p.sumX / p.tileCount, p.sumY / p.tileCount
	local bx, by, bd = nil, nil, math.huge
	for _, id in sim.playerOrder do
		local q = sim.players[id]
		if q ~= nil and q.alive and q.spawned and id ~= s.studentId and id ~= s.allyId
			and q.tileCount > 0
			and not sim:sameTeam(s.studentId, id)
		then
			local qx, qy = q.sumX / q.tileCount, q.sumY / q.tileCount
			local dx, dy = qx - cx, qy - cy
			local d = dx * dx + dy * dy
			if d < bd then
				bx, by, bd = qx, qy, d
			end
		end
	end
	return bx, by
end

-- Land nobody owns, next to land the student does.
--
-- SCORED BY HOW CLOSE IT IS TO THE NEAREST RIVAL, and that is the fix for a
-- measured failure rather than a preference. Scoring by open space instead --
-- which is the obvious thing, and what this did first -- walks the player into
-- the emptiest quarter of the map, i.e. AWAY from everybody: on seed 20260901
-- the student took 6,353 tiles in 75 seconds and still had nobody within
-- eleven tiles, so the card that asks them to invade a neighbour had no
-- neighbour to offer. Steering toward the nearest empire expands exactly as
-- fast and arrives somewhere.
--
-- Open space is still a FILTER, just not the objective: a tile with no
-- unclaimed ground behind it is a one-tile notch, and a first attack that
-- gains one tile does not look like it worked.
local function openTarget(s: Session, current: number?): number?
	local sim = s.sim
	local p = Tutorial.student(s)
	if p == nil or not p.spawned or not p.alive then
		return nil
	end
	local TileMap = tileMap()
	local map = sim.map

	-- NEAR, not ADJACENT, for the reason enemyTarget gives at length: the ring
	-- is placed OPEN_DEPTH tiles out in the field now, so it does not touch the
	-- student, and the old adjacency test here would judge every good ring
	-- stale and recompute it twice a second -- which is the exact jitter the
	-- "hand back the tile you gave last" rule exists to prevent.
	--
	-- Still open and still passable, though: ground somebody has since claimed
	-- is no longer the lesson, and re-targeting is the right answer there.
	local function stillGood(t: number?): boolean
		return t ~= nil
			and ownerAt(sim, t) == 0
			and TileMap.isPassable(map, t)
			and nearMe(sim, t, s.studentId, OPEN_KEEP)
	end
	if stillGood(current) then
		return current
	end

	local rx, ry = nearestRivalCentre(s)
	-- Two answers carried at once: the one nearest a rival among tiles with
	-- somewhere to go, and the most open tile of any kind. The second is only
	-- reached before anybody else has spawned, or on a frontier where every
	-- direction is a notch.
	local near, nearD = nil, math.huge
	local open_, openN = nil, -1
	local seen = 0
	for tile in p.border do
		seen += 1
		if seen > BORDER_SAMPLE then
			break
		end
		local n = TileMap.neighbors4(tile, nbA)
		for i = 1, n do
			local t = nbA[i]
			if ownerAt(sim, t) == 0 and TileMap.isPassable(map, t) then
				local m = TileMap.neighbors4(t, nbB)
				local free = 0
				for j = 1, m do
					local u = nbB[j]
					if ownerAt(sim, u) == 0 and TileMap.isPassable(map, u) then
						free += 1
					end
				end
				if free > openN then
					open_, openN = t, free
				end
				if free >= 2 and rx ~= nil then
					local x = t % W
					local dx, dy = x - rx, (t - x) / W - (ry :: number)
					local d = dx * dx + dy * dy
					if d < nearD then
						near, nearD = t, d
					end
				end
			end
		end
	end
	-- OFF THE SEAM -- see deepenOpen. The walk above can only ever hand back a
	-- tile touching the student, because it is reading the neighbours of their
	-- own border.
	local best = near or open_
	if best == nil then
		return nil
	end
	return deepenOpen(s, best, OPEN_DEPTH)
end

-- HOW MUCH SHARED BORDER COUNTS AS BORDERING SOMEBODY (owner, 2026-09-03:
-- "attack a rival stage in the tutorial shouldnt even show until a player
-- physically by land borders someone to attack"). ONE touching tile already
-- satisfied this, and one tile is technically a border that reads as nothing:
-- it is usually a corner of an empire the student is not looking at, with no
-- frontage to march through. Counted PER EMPIRE, so six separate one-tile
-- brushes against six different bots still do not open the card.
--
-- It can only ever DELAY the war card, never bring it forward.
local INVADE_CONTACT = 6

-- Is anybody's ground properly touching the student's yet? The question the
-- war card exists on the far side of, and it is asked several times a second,
-- so it exits the moment one empire clears the bar rather than scoring them
-- all.
local function hasHostileNeighbour(s: Session): boolean
	local sim = s.sim
	local p = Tutorial.student(s)
	if p == nil or not p.spawned or not p.alive then
		return false
	end
	local TileMap = tileMap()
	local contact: { [number]: number } = {}
	local seen = 0
	for tile in p.border do
		seen += 1
		if seen > BORDER_SAMPLE then
			break
		end
		local n = TileMap.neighbors4(tile, nbA)
		for i = 1, n do
			local o = ownerAt(sim, nbA[i])
			if o ~= 0 and o ~= s.studentId and o ~= s.allyId then
				local q = sim.players[o]
				if q ~= nil and q.alive and not sim:sameTeam(s.studentId, o) then
					local c = (contact[o] or 0) + 1
					if c >= INVADE_CONTACT then
						return true
					end
					contact[o] = c
				end
			end
		end
	end
	return false
end

-- Somebody else's ground. Prefers the WEAKEST empire ADJACENT to the student --
-- a first war against the biggest neighbour on the map is a lesson in losing,
-- and the student cannot yet tell the difference by looking.
--
-- FALLS BACK TO THE NEAREST RIVAL WHEN NOBODY IS TOUCHING YET, which stops the
-- war card from ever going up over a map with no ring on it. Measured before
-- this existed: on seed 20260901 the card appeared at t=16 s, a full three
-- minutes before the student met anybody, and spent all of it pointing at
-- nothing. A far ring is still a true instruction -- tapping ground you cannot
-- march to launches a transport boat, which is what the card's hint says.
local function enemyTarget(s: Session, current: number?): number?
	local sim = s.sim
	local p = Tutorial.student(s)
	if p == nil or not p.spawned or not p.alive then
		return nil
	end
	local TileMap = tileMap()

	local function hostile(o: number): boolean
		if o == 0 or o == s.studentId or o == s.allyId then
			return false
		end
		local q = sim.players[o]
		if q == nil or not q.alive then
			return false
		end
		return not sim:sameTeam(s.studentId, o)
	end
	-- A far target stays good only while it is still theirs; a near one has to
	-- stay NEAR, or the ring would sit on a tile the student has walked past.
	-- Both are a few buffer reads, which is what makes a half-second refresh
	-- affordable.
	--
	-- NEAR, not ADJACENT (2026-09-03). The ring is placed ENEMY_DEPTH tiles
	-- inside the empire now, so it never touches the student, and the old
	-- adjacency test here would have judged every good ring stale.
	if current ~= nil and hostile(ownerAt(sim, current)) then
		-- THE KEEP RADIUS IS LOOSER THAN THE DEPTH, and deliberately not one tile
		-- wider than it. `deepen` hands back a tile with NO student ground within
		-- ENEMY_DEPTH, so a test at ENEMY_DEPTH + 1 is an annulus one tile thick
		-- and fails for nearly every ring it just placed -- which recomputes the
		-- target twice a second and walks the ring around the enemy's interior.
		if nearMe(sim, current, s.studentId, ENEMY_KEEP) or not hasHostileNeighbour(s) then
			return current
		end
	end

	local best, bestTroops = nil, math.huge
	local seen = 0
	for tile in p.border do
		seen += 1
		if seen > BORDER_SAMPLE then
			break
		end
		local n = TileMap.neighbors4(tile, nbA)
		for i = 1, n do
			local t = nbA[i]
			local o = ownerAt(sim, t)
			if hostile(o) then
				local q = sim.players[o]
				local troops = q.troops or 0
				if troops < bestTroops then
					best, bestTroops = t, troops
				end
			end
		end
	end
	if best ~= nil then
		-- OFF THE SEAM. The walk above can only ever return a tile TOUCHING the
		-- student -- it is reading the neighbours of the student's own border --
		-- so the ring landed exactly on the line between the two empires, where
		-- it is ambiguous about which side of it is being pointed at.
		--
		-- SAFE BECAUSE THE CLICKED TILE IS ONLY READ FOR ITS OWNER.
		-- Sim.launchAttack resolves targetId from targetTile and then seeds the
		-- front from wherever the two empires touch ANYWHERE (seedFrontier);
		-- "notadjacent" comes back only when they touch nowhere at all. So a ring
		-- two tiles inside launches exactly the same attack as one on the seam --
		-- it is a different picture, not a different move.
		--
		return deepen(s, best, ENEMY_DEPTH)
	end

	-- Nobody adjacent. The nearest rival border tile to the student's own
	-- centre of mass -- "go and meet your neighbour", which is the right
	-- instruction at this point in a round and the one the map cannot give.
	if p.tileCount <= 0 then
		return nil
	end
	local cx = p.sumX / p.tileCount
	local cy = p.sumY / p.tileCount
	local bestD = math.huge
	for _, id in sim.playerOrder do
		local q = sim.players[id]
		if q ~= nil and q.alive and q.spawned and id ~= s.studentId
			and not sim:sameTeam(s.studentId, id)
		then
			local n = 0
			for tile in q.border do
				n += 1
				if n > FAR_SAMPLE then
					break
				end
				local x = tile % W
				local dx = x - cx
				local dy = (tile - x) / W - cy
				local d = dx * dx + dy * dy
				if d < bestD then
					best, bestD = tile, d
				end
			end
		end
	end
	-- DEEPENED TOO, and this used to be left on the rival's own border on the
	-- grounds that a tap with no land route becomes a transport boat and a boat
	-- needs a beach. It does not: Navy.landingTile spirals out from whatever was
	-- tapped to the nearest coastal tile with the SAME OWNER, precisely so that
	-- aiming at a country's interior works. So the far ring was sitting on a
	-- seam for a reason that was never true, and this is the case the student
	-- spends most of the tutorial looking at.
	if best == nil then
		return nil
	end
	return deepen(s, best, ENEMY_DEPTH)
end

-- Where a city would actually be allowed. Asked of `Economy.canBuild` rather
-- than reimplemented, so the ring can never point somewhere the server would
-- refuse -- which is the one way a guided tutorial breaks a player's trust in
-- it. A "gold" refusal counts as a legal SITE: it means placement passed and
-- only the treasury was short, and the card hands the treasury over anyway.
local function buildableAt(sim: any, playerId: number, tile: number, kind: number): boolean
	local ok, why = economy().canBuild(sim, playerId, tile, kind)
	return ok or why == "gold"
end

-- WHERE THE NATION'S NAME IS, IN TILES -- because the city ring kept being
-- drawn underneath it (owner, 2026-09-12: "the white bubble dot on the map
-- should not always be centered, sometimes its under the text and looks
-- clustered, place it more in an open space within the clients territory").
--
-- NationLabels draws a nation's name and its troop figure in a box `cr * 2.3`
-- wide by `cr * 1.15` tall (NationLabels:628) centred on Renderer.nationAnchor,
-- and that anchor STARTS AT THE CENTROID (Renderer:1076), only climbing away
-- from it when the centroid is not the roomiest ground the nation holds. The
-- spiral below started at that same centroid and took the FIRST legal tile,
-- which on any ordinary blobby empire IS the centroid. The ring and the label
-- were landing on one spot by construction, not by bad luck.
--
-- `cr` is Renderer's own `min(roomAt, sqrt(count) * 0.62)` and BOTH HALVES ARE
-- NEEDED. A first version of this took the sqrt half alone, on the reasoning
-- that it binds on a blobby empire. Measured over eight live empires it does
-- not: the real `cr` came back 21 where the sqrt half predicted 30, and 15
-- where it predicted 19 -- `roomAt` is the binding half most of the time. The
-- over-estimate demanded a clearance wider than the empire's own radius, so
-- nothing cleared, every ring fell back to the centre tile, and 11 of 12 were
-- still drawn under the name. `roomAt` is measured here at the CENTROID only,
-- without Renderer's hill climb: the climb moves the anchor 0-8 tiles (also
-- measured), which is what LABEL_PAD covers.
local LABEL_CR_PER_TILE = 0.62
-- The box is `cr * 2.3` by `cr * 1.15` (NationLabels:628), so these are its
-- halves. IT IS A WIDE FLAT BOX, NOT A CIRCLE -- the first version used one
-- radius for both and that is the other half of why it failed.
local LABEL_HALF_W = 1.15
local LABEL_HALF_H = 0.575
-- Under this a nation carries no label at all (NationLabels.MIN_TILES), so
-- there is no text to clear and the plain centre-of-mass answer is the right
-- one -- which is also why the owner saw this "sometimes".
local LABEL_MIN_TILES = 900
-- Slack on the box, so what clears the text is the CIRCLE and not merely the
-- tile at its centre. THE RING'S RADIUS AND NOTHING MORE: a first version also
-- padded by the anchor's 0-8 tile drift, which on a 900-tile empire made the
-- box wider than the country's own radius -- the only ground that escaped it
-- was the fringe, so 7 of 12 rings came back on a BORDER tile (room 0), which
-- is both the opposite of "an open space" and a city site that gets captured.
-- The drift is absorbed by preferring a bigger escape instead.
local LABEL_PAD = RING_TILES
-- A tile whose own ground runs a ring-width in all four directions is "open"
-- for a ring of that width. Measuring past it buys a bigger number and not a
-- better picture.
local CITY_ROOM_CAP = RING_TILES * 2
-- THERE IS NO ROOM FLOOR, AND THAT IS MEASURED, NOT CONCEDED. Two versions of
-- this carried one and both were wrong, in opposite directions. Counting every
-- legal city site that clears the label, over twelve live empires:
--
--   room >= 7 outside the box   7 of 12 empires have any at all
--   room >= 3 outside the box   9 of 12
--   room >= 1 outside the box  10 of 12
--
-- A floor of 7 therefore threw five empires onto the fallback below and drew
-- their ring back under the name; a floor of 0 took a BORDER tile, which is
-- open ground by no definition and a city that gets captured. So the rule is
-- an ORDER, not a threshold: of the sites that clear the text, the roomiest
-- one wins, whatever that room turns out to be. On a 1,200-tile empire the
-- label's half-width is about 20 tiles against a country radius of 20, so
-- "deep inside" and "off the text" genuinely cannot both be had -- and this
-- takes the best of what is actually there instead of pretending otherwise.
--
-- ROOM 1 IS THE LINE between a tile with ground around it and a tile on the
-- edge. Below it the two empires in twelve whose name covers everything they
-- hold fall through to the roomiest ground anywhere -- see the fallback.
local CITY_ROOM_MIN = 1
-- How far past the empire's own radius the walk may go before giving up. The
-- search is bounded by the territory rather than by a fixed 60: a ring can
-- only be placed on ground the student actually holds.
local CITY_SEARCH_MARGIN = 24

-- The label's room measure, at ONE point rather than Renderer's hill climb.
-- Faithful to Renderer's ROOM_STEP / ROOM_MAX (Renderer:1019-1064) because it
-- has to produce the same `cr` the client will draw with.
local LABEL_ROOM_STEP = 3
local LABEL_ROOM_MAX = 190
local function ownedXY(sim: any, x: number, y: number, id: number): boolean
	if x < 0 or x >= W or y < 0 or y >= H then
		return false
	end
	return buffer.readu8(sim.map.owner, y * W + x) == id
end
local function labelReach(sim: any, x: number, y: number, dx: number, dy: number, id: number): number
	local d = LABEL_ROOM_STEP
	while d <= LABEL_ROOM_MAX do
		if not ownedXY(sim, x + dx * d, y + dy * d, id) then
			return d
		end
		d += LABEL_ROOM_STEP
	end
	return LABEL_ROOM_MAX
end
local function labelRoom(sim: any, x: number, y: number, id: number): number
	if not ownedXY(sim, x, y, id) then
		return -1
	end
	local a = labelReach(sim, x, y, 1, 0, id)
	local b = labelReach(sim, x, y, -1, 0, id)
	if b < a then
		a = b
	end
	b = labelReach(sim, x, y, 0, 1, id)
	if b < a then
		a = b
	end
	b = labelReach(sim, x, y, 0, -1, id)
	if b < a then
		a = b
	end
	return a
end

-- WHERE THE LABEL ACTUALLY IS, hill climb and all -- a faithful port of
-- Renderer.nationAnchor (Renderer:1069-1136), because an approximation of it
-- was measured and found to be the whole remaining fault. Centring the box on
-- the CENTROID instead left 6 of 30 rings inside the real label, and every one
-- of those six had a clear legal tile available that the code could not see:
-- the anchor drifts from the centroid by 4.0 tiles on average and 20.0 at
-- worst, against a LABEL_PAD of 7. Nought of the six was a country with
-- nowhere better to go. The climb costs 0.1 ms, measured, against a 4 ms call
-- that is paid once a card -- so the honest box is simply affordable.
--
-- The anchor is the roomiest ground the nation has, which is exactly why the
-- ring keeps colliding with it: `inset` and `roomAt` are hunting the same
-- thing. Knowing precisely where it landed is what lets the ring stand beside
-- it rather than guess.
local LABEL_ANCHOR_STRIDE = 6
local LABEL_ANCHOR_MAX_R = 300
-- Eight directions, as (dx, dy) pairs, for the climb.
local LABEL_CLIMB = { 1, 0, -1, 0, 0, 1, 0, -1, 1, 1, 1, -1, -1, 1, -1, -1 }
local function labelAnchor(sim: any, cx: number, cy: number, id: number, count: number): (number?, number?, number?)
	local ax, ay
	if ownedXY(sim, cx, cy, id) then
		ax, ay = cx, cy
	else
		-- The centroid is not theirs (a crescent, a ring): nearest owned tile,
		-- sampled on a stride, exactly as the renderer does it.
		for r = LABEL_ANCHOR_STRIDE, LABEL_ANCHOR_MAX_R, LABEL_ANCHOR_STRIDE do
			for d = -r, r, LABEL_ANCHOR_STRIDE do
				if ownedXY(sim, cx + d, cy - r, id) then
					ax, ay = cx + d, cy - r
					break
				elseif ownedXY(sim, cx + d, cy + r, id) then
					ax, ay = cx + d, cy + r
					break
				elseif ownedXY(sim, cx - r, cy + d, id) then
					ax, ay = cx - r, cy + d
					break
				elseif ownedXY(sim, cx + r, cy + d, id) then
					ax, ay = cx + r, cy + d
					break
				end
			end
			if ax then
				break
			end
		end
	end
	if not ax then
		return nil, nil, nil
	end
	local best = labelRoom(sim, ax, ay, id)
	local step = 64
	local budget = 40
	while step >= 4 and budget > 0 do
		local moved = false
		for k = 1, 15, 2 do
			local nx = ax + LABEL_CLIMB[k] * step
			local ny = ay + LABEL_CLIMB[k + 1] * step
			local r = labelRoom(sim, nx, ny, id)
			if r > best then
				best, ax, ay = r, nx, ny
				moved = true
			end
		end
		budget -= 1
		if not moved then
			step //= 2
		end
	end
	-- Capped by sqrt(area) as the renderer caps it, or a narrow nation that
	-- happens to be locally fat gets a name bigger than the ground carrying it.
	return ax, ay, math.min(best, LABEL_CR_PER_TILE * math.sqrt(count))
end

-- Spirals out from the student's own centre of mass, which the sim already
-- keeps as running coordinate sums. A city wants to be INSIDE the empire --
-- out on the border it is captured by whoever arrives -- and the centroid is
-- the cheapest honest answer to "inside". It is NOT the answer to "where does
-- the RING go", which is what the clearance above exists to say.
local function cityTarget(s: Session, current: number?): number?
	local sim = s.sim
	local p = Tutorial.student(s)
	if p == nil or not p.spawned or not p.alive or p.tileCount <= 0 then
		return nil
	end
	local Economy = economy()
	local TileMap = tileMap()
	local cx = math.floor(p.sumX / p.tileCount)
	local cy = math.floor(p.sumY / p.tileCount)

	-- THE LABEL BOX, in tiles, on the anchor the client will really draw it on.
	local halfW, halfH = 0, 0
	local lx, ly = cx, cy
	if p.tileCount >= LABEL_MIN_TILES then
		local ax, ay, cr = labelAnchor(sim, cx, cy, s.studentId, p.tileCount)
		if ax ~= nil and ay ~= nil and cr ~= nil then
			lx, ly = ax, ay
			halfW = LABEL_HALF_W * cr + LABEL_PAD
			halfH = LABEL_HALF_H * cr + LABEL_PAD
		end
	end
	-- HOW FAR OUT OF THE TEXT A TILE IS, in box-widths: 1 is the edge of the
	-- label, more is clear of it. A ratio rather than a distance because the
	-- box is twice as wide as it is tall, so "clear" means something different
	-- along each axis -- which is exactly what the circular test got wrong.
	local function esc(t: number): number
		if halfW <= 0 then
			return math.huge
		end
		local x = t % W
		local dx = math.abs(x - lx)
		local dy = math.abs((t - x) / W - ly)
		local ex = dx / halfW
		local ey = dy / halfH
		return ex > ey and ex or ey
	end

	-- Hand back the tile given last while it is still legal AND still clear of
	-- the name -- the same stickiness every other finder has, with the new rule
	-- folded into it so a ring already sitting under the text moves ONCE and
	-- then stays where it is put.
	-- The second clause is what the fallback empires stick on: their answer is
	-- the roomiest ground they have and it sits under their own name, so a test
	-- that only accepted an escape would re-run this whole walk twice a second
	-- and hand back the same tile every time (measured at 4-5 ms a refresh).
	if current ~= nil and buildableAt(sim, s.studentId, current, Economy.CITY) then
		local room = inset(sim, current, s.studentId, CITY_ROOM_CAP)
		if (esc(current) >= 1 and room >= CITY_ROOM_MIN) or room >= CITY_ROOM_CAP then
			return current
		end
	end
	-- A square spiral rather than rings of exact radius: the point is to try
	-- tiles in roughly increasing distance from the middle, and the ordering
	-- inside one ring does not matter. BOUNDED BY THE TERRITORY, not by a fixed
	-- 60 and not by the clearance: a ring can only go on ground the student
	-- holds, and walking further than that is the cost with none of the answer.
	--
	-- BEST EFFORT, NEVER A GATE. Between a third and three fifths of an
	-- empire's legal sites sit outside its own label (measured over eight live
	-- empires), so there is nearly always somewhere good -- but the label is
	-- anchored on the ROOMIEST ground the nation has, which means "most open"
	-- and "under the text" are the same place by construction. When nothing at
	-- all clears the name the least-covered legal tile is still a better ring
	-- than the centre one, so `under` keeps the best of a bad set rather than
	-- the first of it.
	-- OUT OF THE TEXT FIRST, AND THEN THE ROOMIEST OF THOSE. `best` is the
	-- roomiest tile that clears the label; `open` is the roomiest tile anywhere,
	-- kept for the country whose name covers everything it holds.
	local best, bestRoom = nil, -1
	local open, openRoom = nil, -1
	local R = math.ceil(math.sqrt(p.tileCount / math.pi)) + CITY_SEARCH_MARGIN
	for r = 0, R do
		for dy = -r, r do
			for dx = -r, r do
				-- Only the rim of this square is new; the inside was covered by
				-- a smaller r.
				if r == 0 or math.abs(dx) == r or math.abs(dy) == r then
					local x, y = cx + dx, cy + dy
					if TileMap.inBounds(x, y) then
						local t = y * W + x
						if ownerAt(sim, t) == s.studentId
							and buildableAt(sim, s.studentId, t, Economy.CITY)
						then
							-- `inset` is the cheap interior measure the enemy
							-- ring is placed with: four rays, smallest of the
							-- four, so the belly of the territory beats a spur
							-- off it without anything here walking a border.
							local room = inset(sim, t, s.studentId, CITY_ROOM_CAP)
							if room > openRoom then
								open, openRoom = t, room
							end
							if room > bestRoom and esc(t) >= 1 then
								best, bestRoom = t, room
								-- Ground running a full ring-width every way AND
								-- clear of the name: nothing later can beat it,
								-- and the spiral got here first, so it is also the
								-- nearest such tile to the middle of the country.
								if room >= CITY_ROOM_CAP then
									return best
								end
							end
						end
					end
				end
			end
		end
	end
	-- Clear of the name and not a border tile, if the country has such a place;
	-- otherwise the roomiest ground it has, which is the honest answer for the
	-- two empires in twelve whose label covers all of it. A ring under the name
	-- is a worse picture than one beside it, but a ring on the frontier is a
	-- worse CITY -- it is taken by whoever arrives -- and the card is teaching
	-- what a city is for.
	if best ~= nil and bestRoom >= CITY_ROOM_MIN then
		return best
	end
	return open or best
end

-- A land tile of the student's with open water beside it. This is `isCoast`
-- from Economy, which is a local there; four buffer reads is not worth
-- widening that module's surface for.
local function isMyCoast(s: Session, tile: number): boolean
	local sim = s.sim
	if ownerAt(sim, tile) ~= s.studentId then
		return false
	end
	local TileMap = tileMap()
	if not TileMap.isPassable(sim.map, tile) then
		return false
	end
	local n = TileMap.neighbors4(tile, nbB)
	for i = 1, n do
		if not TileMap.isLand(sim.map, nbB[i]) then
			return true
		end
	end
	return false
end

-- THE WATER PATHWAY THE PORT CARD IS CONDITIONAL ON. Walks the border only --
-- a coast tile has water beside it, water is owner 0, and every tile with a
-- differently-owned neighbour is in the border set by definition, so a coast
-- tile the student holds is always in there.
local function coastTarget(s: Session, current: number?): number?
	local p = Tutorial.student(s)
	if p == nil or not p.spawned or not p.alive then
		return nil
	end
	if current ~= nil and isMyCoast(s, current)
		and buildableAt(s.sim, s.studentId, current, economy().PORT)
	then
		return current
	end
	local seen = 0
	local fallback = nil
	for tile in p.border do
		seen += 1
		if seen > BORDER_SAMPLE then
			break
		end
		if isMyCoast(s, tile) then
			-- Prefer a stretch of coast a port is actually allowed on. A
			-- shoreline crowded by an existing port still counts as "has a
			-- water pathway", so it is kept as the fallback rather than
			-- collapsing the whole answer to nil.
			if buildableAt(s.sim, s.studentId, tile, economy().PORT) then
				return tile
			end
			fallback = fallback or tile
		end
	end
	return fallback
end

-- Does the student hold any coast at all? What decides whether the port lesson
-- is taught or stepped over -- the owner's rule is that a port is offered once
-- there is water to put it on.
function Tutorial.hasSeaAccess(session: Session): boolean
	local p = Tutorial.student(session)
	if p == nil or not p.spawned then
		return false
	end
	local seen = 0
	for tile in p.border do
		seen += 1
		if seen > BORDER_SAMPLE then
			break
		end
		if isMyCoast(session, tile) then
			return true
		end
	end
	return false
end

-- The heartland of the biggest empire that is not the student's. A nuke is
-- worth its 750,000 only against somewhere dense, and the centroid of the
-- largest rival is the densest thing that can be found without a scan. Falls
-- back to any tile they hold when the centroid itself has changed hands.
local function nukeTarget(s: Session, current: number?): number?
	local sim = s.sim
	local p = Tutorial.student(s)
	if p == nil or not p.spawned or not p.alive then
		return nil
	end

	local function hostileTile(t: number?): boolean
		if t == nil then
			return false
		end
		local o = ownerAt(sim, t)
		if o == 0 or o == s.studentId then
			return false
		end
		local q = sim.players[o]
		return q ~= nil and q.alive and not sim:sameTeam(s.studentId, o)
	end
	if hostileTile(current) then
		return current
	end

	local biggest, bestTiles = nil, 0
	for _, id in sim.playerOrder do
		local q = sim.players[id]
		if q ~= nil and q.alive and q.spawned and id ~= s.studentId
			and not sim:sameTeam(s.studentId, id)
			and q.tileCount > bestTiles
		then
			biggest, bestTiles = q, q.tileCount
		end
	end
	if biggest == nil or bestTiles <= 0 then
		return nil
	end

	local TileMap = tileMap()
	local cx = math.floor(biggest.sumX / biggest.tileCount)
	local cy = math.floor(biggest.sumY / biggest.tileCount)
	for r = 0, 40 do
		for dy = -r, r do
			for dx = -r, r do
				if r == 0 or math.abs(dx) == r or math.abs(dy) == r then
					local x, y = cx + dx, cy + dy
					if TileMap.inBounds(x, y) then
						local t = y * W + x
						if ownerAt(sim, t) == biggest.id then
							return t
						end
					end
				end
			end
		end
	end
	-- Centroid nowhere near anything they still hold (a horseshoe empire, or
	-- one that has just been cut in half). Their border is a guaranteed answer.
	for tile in biggest.border do
		return tile
	end
	return nil
end

-- A homeland worth suggesting, during the spawn phase only. Sampled rather
-- than searched: the US has a quarter of a million playable tiles and the
-- question is "somewhere legal", not "the best place". Deterministic in the
-- seed and the tick so two calls a moment apart do not fight over it.
local function spawnTarget(s: Session, current: number?): number?
	local sim = s.sim
	if sim.phase ~= "spawn" then
		return nil
	end
	local p = Tutorial.student(s)
	if p == nil or p.spawned then
		return nil
	end
	-- The student has already put their dot down. That IS the suggestion now,
	-- and moving the ring off it would read as the game arguing with them.
	if p.spawnPreview ~= nil then
		return nil
	end
	if current ~= nil and sim:isValidSpawn(current, s.studentId) then
		return current
	end
	local rng = Random.new((sim.seed or 1) * 7919 + 13)
	local TileMap = tileMap()
	for _ = 1, 400 do
		local t = rng:NextInteger(0, Config.NUM_TILES - 1)
		if TileMap.isPassable(sim.map, t) and sim:isValidSpawn(t, s.studentId) then
			return t
		end
	end
	return nil
end

-- ============================================================== the lessons ==
-- SEVEN CARDS, EACH ONE A THING TO DO. Every step completes on a FACT ABOUT
-- THE SIM -- never on a "next" button, because a next button is a player
-- tapping through a tutorial rather than playing one -- and every step that
-- wants a tap RINGS THE TILE and PAYS FOR ITSELF. `done` is a pure read: no
-- side effects, because `advance` calls it several times a second.
--
-- THE ORDER IS THE RAMP, and it is the owner's: land first (tap to attack),
-- then a neighbour, then the money buildings, then -- once there is an empire
-- big enough to be worth defending -- the nuke. Nothing is introduced before
-- the thing it is built on.

export type Step = {
	id: string,
	title: string,
	-- ONE SHORT LINE. The ring says where and the armed button says which
	-- control; all the body has to add is what the tap means. Long copy here is
	-- the failure this track was rewritten to fix.
	body: string,
	-- A second line under the rule, and USUALLY EMPTY -- an empty string
	-- hides the label entirely. Only earns its place when it names a control
	-- nothing on screen shows: "drag to pan" does, "press the house" does not,
	-- because the house lights up on its own.
	hint: string,
	-- Which action-rail button to light while this card is up, if any:
	-- "city" | "port" | "factory" | "nuke". Matches ConquestClient's `arm`.
	arm: string?,
	-- The tile this card is pointing at, recomputed off the live map. Returns
	-- the tile it was given while that is still a legal answer -- see the
	-- targets section.
	target: ((Session, number?) -> number?)?,
	-- HOW MUCH GOLD THE TREASURY MUST HOLD for this card to be doable, topped
	-- up as the card goes up. A lesson the treasury cannot pay for is a wait,
	-- not a lesson -- and it is a top-up rather than a gift so a student who
	-- has been earning is not handed a second fortune on top.
	fund: ((Session) -> number)?,
	-- CAN THIS CARD BE ACTED ON YET (owner: "the next step shouldn't show
	-- until the player is capable of doing it"). Checked BEFORE the card is
	-- entered, and while it answers no the track holds on the card before it
	-- -- which is always the one that earns whatever this one is waiting for.
	--
	-- Different from `skip`, and the difference is permanence: `skip` says
	-- this round can NEVER answer this card, `ready` says not yet.
	ready: ((Session) -> boolean)?,
	-- Cards that do not apply to the round this student is actually in. The
	-- port is the one: a landlocked empire has nowhere to put one, and being
	-- told to build one anyway is the tutorial visibly not looking at the map.
	skip: ((Session) -> boolean)?,
	done: (Session) -> boolean,
}

local function land(session: Session): number
	local p = Tutorial.student(session)
	return p and p.tileCount or 0
end

-- THE LITE TRACK. A follower who skipped the tutorial to join a friend gets
-- the three cards that teach the taps -- open land, a rival, a city -- inside
-- the friend's real match, on a session of their own (`attach` with `lite`).
-- Nothing round-wide comes with it: no growth buff, no gold top-ups, no
-- grace, and the track ends after LITE_LAST instead of at the conquest.
-- Indices into STEPS: 2 = attack, 4 = city.
Tutorial.LITE_FIRST = 2
Tutorial.LITE_LAST = 4

Tutorial.STEPS = {
	{
		id = "spawn",
		title = "PICK YOUR LAND",
		body = "",
		hint = "",
		target = spawnTarget,
		done = function(s: Session): boolean
			local p = Tutorial.student(s)
			return p ~= nil and p.spawned == true
		end,
	},
	{
		id = "attack",
		title = "TAP TO ATTACK",
		body = "",
		hint = "",
		target = openTarget,
		-- THE OPENING FLOAT, granted here because this is the first card after
		-- the spawn -- see Tutorial.OPENING_GOLD for why it cannot be earlier
		-- and cannot be sim.startGold. fundStep tops UP rather than sets, so a
		-- student who somehow arrives richer keeps what they have.
		fund = function(): number
			return Tutorial.OPENING_GOLD
		end,
		-- THREE TAPS, counted from the mark -- see Tutorial.ATTACK_TAPS for why
		-- this is no longer 150 tiles taken since the card went up.
		--
		-- It used to carry a second condition -- hold until there is somebody
		-- to invade -- because the card after it asks for exactly that. That
		-- belongs to the card that needs it and is now `invade.ready`, which
		-- is the same wait without a timeout attached to it. NOTE that gate,
		-- not this one, is what decides how long this card is on SCREEN: three
		-- taps satisfy it, and `advance` then holds here until ATTACK A RIVAL
		-- is ready, because there is nothing else it could honestly show.
		done = function(s: Session): boolean
			return s.attacks >= (s.mark.attacks or 0) + Tutorial.ATTACK_TAPS
		end,
	},
	{
		id = "invade",
		title = "ATTACK A RIVAL",
		body = "",
		hint = "",
		target = enemyTarget,
		-- A BORDER, not a boat ride. Measured on seed 20260901 with this card
		-- ungated: it went up at t=16 s and the student did not meet a living
		-- soul until t=218 s -- three minutes of a card asking for something
		-- the map could not supply. Expanding is the right play in that window
		-- and the card before this one already teaches it, ring and all.
		ready = hasHostileNeighbour,
		done = function(s: Session): boolean
			for _, atk in s.sim.attacks do
				if atk.active and atk.attackerId == s.studentId and atk.targetId ~= 0 then
					return true
				end
			end
			return false
		end,
	},
	{
		id = "city",
		title = "BUILD A CITY",
		body = "",
		hint = "",
		arm = "city",
		target = cityTarget,
		-- EARNED, NOT HANDED OVER. `fund` below still exists and still tops
		-- the treasury up, but with this gate in front of it there is nothing
		-- left to top up: the student arrives at the card already holding the
		-- price, and the top-up is reduced to the margin it was written for --
		-- the tick or two in which a price ladder can move under them.
		ready = function(s: Session): boolean
			local p = Tutorial.student(s)
			return p ~= nil and p.gold >= economy().cost(p, economy().CITY)
		end,
		fund = function(s: Session): number
			local p = Tutorial.student(s)
			return p and economy().cost(p, economy().CITY) or Config.CITY_COST_BASE
		end,
		-- PLACED, NOT FINISHED. The lesson is the tap; the site going up is
		-- the game's business. See the `units` requirer for why not cityCount.
		done = function(s: Session): boolean
			return units().structureCount(s.sim, s.studentId, units().CITY) >= 1
		end,
	},
	{
		id = "port",
		title = "BUILD A PORT",
		body = "",
		hint = "",
		arm = "port",
		target = coastTarget,
		ready = function(s: Session): boolean
			local p = Tutorial.student(s)
			if p == nil or p.gold < economy().cost(p, economy().PORT) then
				return false
			end
			-- ...AND A BEAT AFTER THE CITY WENT DOWN. See STEP_GAP_SECONDS: the
			-- city card clears on the tick the site is PLACED (not finished),
			-- and this one arriving in the same breath makes the two read as
			-- one instruction.
			return s.doneTick ~= nil
				and s.sim.tick - s.doneTick >= Tutorial.STEP_GAP_SECONDS / Config.TICK_DT
		end,
		fund = function(s: Session): number
			local p = Tutorial.student(s)
			return p and economy().cost(p, economy().PORT) or Config.PORT_COST_BASE
		end,
		-- THE OWNER'S CONDITION, and the reason this field exists at all: the
		-- port is taught once there is water to put it on. A landlocked student
		-- steps straight over it rather than being asked for something the map
		-- will not let them do.
		skip = function(s: Session): boolean
			return not Tutorial.hasSeaAccess(s)
		end,
		-- PLACED, NOT FINISHED -- same rule as the city card.
		done = function(s: Session): boolean
			return units().structureCount(s.sim, s.studentId, units().PORT) >= 1
		end,
	},
	-- TAKE MORE LAND WAS THE SIXTH CARD AND IT IS GONE (owner, 2026-09-03:
	-- "step 6 of the tutorial is useless"). It taught nothing: it asked for a
	-- minute of ordinary play so the nuke would land late in the round, which
	-- from the student's side is the tutorial stalling rather than teaching.
	-- The nuke follows the port directly now, and its own `fund` buys the
	-- warhead the way the city and port cards buy theirs.
	{
		id = "nuke",
		title = "FIRE A NUKE",
		body = "",
		hint = "",
		arm = "nuke",
		target = nukeTarget,
		-- THE GATE IS BACK (owner, 2026-09-03: "fire a nuke shouldnt show up in
		-- the tutorial till the player has enough money for it"). It was taken
		-- out when TAKE MORE LAND was deleted, on the grounds that the warhead
		-- would then have nothing in front of it earning the price and the track
		-- would sit on BUILD A PORT instead.
		--
		-- THAT COST IS ACCEPTED DELIBERATELY. A card that names a price the
		-- treasury cannot pay is the tutorial handing over a button that does
		-- nothing, and being shown the nuke before you can afford one teaches
		-- the wrong thing about the economy. The wait is softer than it was:
		-- Tutorial.state stops arming the port's button the moment its own
		-- `done` is true, so a held card no longer pulses green at a lesson
		-- already finished.
		ready = function(s: Session): boolean
			local p = Tutorial.student(s)
			return p ~= nil and p.gold >= (Config.ATOM_BOMB_COST or 750000)
		end,
		-- Still here for the margin the gate cannot cover: the price is read
		-- once to open the card and again when the shot is paid for.
		fund = function(): number
			return Config.ATOM_BOMB_COST or 750000
		end,
		done = function(s: Session): boolean
			return s.launched
		end,
	},
	-- THE LAST CARD IS THE WHOLE GAME (owner, 2026-09-03: "final stage of
	-- tutorial should be to capture 90% of the map"). Every card above teaches
	-- a CONTROL; this one asks for the thing all of them are for, and it is the
	-- game's own win condition rather than a tutorial-shaped substitute --
	-- Config.WIN_PERCENT_FFA is 0.90, and the win check divides by exactly the
	-- denominator used here (Nukes.contestableLand: land that has not been
	-- glassed). KEEP THE 90 IN THE TITLE IN STEP WITH THAT CONSTANT.
	--
	-- NO RING AND NO ARMED BUTTON. There is no one tile to point at: the
	-- answer is the map, and every control it takes has already been taught.
	{
		id = "conquer",
		title = "TAKE 90% OF THE MAP",
		body = "",
		hint = "",
		done = function(s: Session): boolean
			local sim = s.sim
			-- ALREADY SETTLED IN THEIR FAVOUR. Overtime walks the real bar down
			-- from 90% (Sim.winThreshold), so a student can take this round on
			-- 80% -- and would otherwise be left holding an unfinished card over
			-- a finished game, which is the one way this card could become a
			-- wall rather than a lesson.
			if sim.winnerId == s.studentId then
				return true
			end
			local p = Tutorial.student(s)
			if p == nil then
				return false
			end
			local total = nukes().contestableLand(sim)
			return total > 0 and p.tileCount / total >= Config.WIN_PERCENT_FFA
		end,
	},
} :: { Step }

-- THE TWO ENDS OF THE TRACK. Neither is a Step -- neither can be completed and
-- `advance` never enters them -- but the card has to go on saying something
-- after the last lesson clears, and this copy belongs beside the copy it
-- follows rather than in the client that draws it.
--
-- NEITHER ENDS THE ROUND, and the sim's own win check is untouched -- but the
-- ROUND no longer outlives the track (owner, 2026-09-04: "after the tutorial,
-- player should return to main lobby where they can play the next game").
-- ConquestServer takes the student back to the page a few seconds after either
-- of these goes up. The old argument here was that the match should play on as
-- any other does, because the lesson is taught inside a real game; what that
-- missed is that the real game it is taught inside has no other people in it.
--
-- BOTH CARDS SAY WHERE YOU ARE GOING. A teleport nothing warned you about
-- reads as a crash, and this is the one thing on screen that can warn you --
-- which is what earns the body line on cards that had none.
Tutorial.DONE = {
	id = "done",
	title = "THAT IS THE WHOLE GAME",
	body = "Back to the lobby for a real match.",
	hint = "",
}
Tutorial.FAILED = {
	id = "failed",
	title = "YOUR EMPIRE IS GONE",
	body = "Back to the lobby for another go.",
	hint = "",
}

-- ================================================================ the track ==

-- Tops the treasury up to what this card needs. A TOP-UP, NOT A GIFT: a
-- student who has been earning well is not handed a second fortune on top of
-- the first, and one who has been spending is never left staring at a card
-- asking for a building they cannot buy. Never takes anything away.
-- The lite track's two endings. The full track's send the student home;
-- these do not, because there is a match on and a friend in it.
Tutorial.LITE_DONE = {
	id = "done",
	title = "YOU KNOW THE BASICS",
	body = "",
	hint = "",
}
Tutorial.LITE_FAILED = {
	id = "failed",
	title = "YOUR EMPIRE IS GONE",
	body = "Your friend fights on -- stay and watch.",
	hint = "",
}

local function fundStep(session: Session, step: Step?)
	-- A LITE session is never funded: it is inside a real match.
	if step == nil or step.fund == nil or session.lite then
		return
	end
	local p = Tutorial.student(session)
	if p == nil then
		return
	end
	-- The margin covers the tick or two between the card going up and the
	-- player pressing the button, during which a price ladder can move under
	-- them -- being one gold short of the thing you were just told to build is
	-- the worst version of this bug.
	local need = step.fund(session) * 1.05
	if p.gold < need then
		p.gold = need
	end
end

function Tutorial.enterStep(session: Session, index: number)
	local step = Tutorial.STEPS[index]
	session.stepIndex = index
	session.stepEnteredTick = session.sim.tick
	session.doneTick = nil
	local p = Tutorial.student(session)
	session.mark = {
		tiles = p and p.tileCount or 0,
		troops = p and p.troops or 0,
		gold = p and p.gold or 0,
		-- ...so taps made on an EARLIER card cannot pay for this one.
		attacks = session.attacks,
	}
	fundStep(session, step)
	-- The ring arrives WITH the card, not up to two seconds after it. A card
	-- that says "tap the ring" beside a map with no ring on it is the tutorial
	-- lying for as long as the refresh takes.
	session.targetTick = session.sim.tick
	session.target = step ~= nil and step.target ~= nil and step.target(session, nil) or nil
end

function Tutorial.currentStep(session: Session): Step?
	return Tutorial.STEPS[session.stepIndex]
end

-- Walks forward off `index` over every card that does not apply to this round,
-- and returns where the track actually lands. Kept separate from `enterStep`
-- because a skipped card must not be funded or entered at all -- only looked at
-- and stepped over.
local function nextLiveStep(session: Session, index: number): number
	local i = index
	while true do
		local step = Tutorial.STEPS[i]
		if step == nil or step.skip == nil or not step.skip(session) then
			return i
		end
		i += 1
	end
end

-- LATCHES THE LAUNCH. A nuke is an execution in a list that is pruned when the
-- warhead lands, so a `done` that read the list directly would answer "no"
-- again the moment the flight ended -- and the card would sit there having
-- watched the student do exactly what it asked. Called every tick from
-- `advance`, and the one thing in this file that writes while reading.
local function observe(session: Session)
	if session.launched then
		return
	end
	local list = session.sim.nukeExecs
	if list == nil then
		return
	end
	for _, ex in list do
		if ex.active and ex.playerId == session.studentId then
			session.launched = true
			return
		end
	end
end

-- Call once per tick. Returns true when the client needs a fresh card -- which
-- is a lesson completing OR the ring moving, since both change what is on
-- screen and the client is only ever told on this channel.
--
-- Called from ConquestServer's Heartbeat loop, beside drainStructEvents.
function Tutorial.advance(session: Session): boolean
	if session.finished then
		return false
	end

	observe(session)

	local p = Tutorial.student(session)
	-- Knocked out. Not a step: a dead student has nothing left to do in this
	-- round and the caller should offer a restart rather than a next card.
	if p ~= nil and p.spawned and not p.alive then
		if not session.failed then
			session.failed = true
			session.target = nil
			return true
		end
		return false
	end

	local step = Tutorial.STEPS[session.stepIndex]
	if step == nil then
		session.finished = true
		session.target = nil
		return true
	end

	-- HAS THIS CARD JUST BEEN ANSWERED? That is a change the client has to
	-- hear about even when the TRACK cannot move, and missing it was a real
	-- bug (owner, 2026-09-03: "it keeps prompting for you to build a city
	-- after you build one in the tutorial"). `Tutorial.state` computes
	-- `hidden` off exactly this -- but ConquestServer only fires the state
	-- when `advance` returns true, so a card that was answered while the
	-- next one was not ready returned FALSE, nothing went out, and the
	-- client went on drawing the card, its ring and its armed button for a
	-- lesson already carried out.
	--
	-- The city card hid itself SOMETIMES, which is what made this look like
	-- a UI fault rather than a wire one: `cityTarget` moving after the build
	-- would return true below and carry the new state out with it.
	local flipped = false
	if step.done(session) then
		-- WHEN THIS CARD WAS SATISFIED, latched on the first tick it answered
		-- true so it survives the ticks spent held here. A `ready` on the next
		-- card reads it to ask how long ago that was -- see the port's gap.
		if session.doneTick == nil then
			session.doneTick = session.sim.tick
			flipped = true
		end
		local nextIndex = nextLiveStep(session, session.stepIndex + 1)
		local nextStep = Tutorial.STEPS[nextIndex]
		if nextStep == nil or (session.lite and nextIndex > Tutorial.LITE_LAST) then
			session.finished = true
			session.target = nil
			return true
		end
		-- HELD, NOT SKIPPED. A card the student cannot act on is not a lesson,
		-- it is a wall -- so the track stays on the one behind it and asks
		-- again next tick. That card is always the thing that earns whatever
		-- the next one is waiting for: TAP TO ATTACK takes the ground that
		-- borders a rival, ATTACK A RIVAL and TAKE MORE LAND pay for the
		-- buildings and the warhead. Falling through rather than returning is
		-- what keeps the held card's ring following the map while it waits.
		if nextStep.ready == nil or nextStep.ready(session) then
			Tutorial.enterStep(session, nextIndex)
			return true
		end
	elseif session.doneTick ~= nil then
		-- ...AND BACK AGAIN. `done` is a live read, not a latch: lose the city
		-- and BUILD A CITY is a true instruction once more. The card returning
		-- is as much a change as it going away -- and the port's gap should
		-- then run from the SECOND city rather than the first.
		session.doneTick = nil
		flipped = true
	end

	-- THE RING FOLLOWS THE MAP. Ground gets taken while a card is up, so the
	-- tile this card is pointing at has to be re-asked -- and the finder hands
	-- back the same tile while it is still a legal answer, so this only reports
	-- a change when there genuinely is one.
	if step.target ~= nil
		and session.sim.tick - session.targetTick >= Tutorial.TARGET_REFRESH_TICKS
	then
		session.targetTick = session.sim.tick
		local t = step.target(session, session.target)
		if t ~= session.target then
			session.target = t
			return true
		end
	end
	return flipped
end

-- Everything the client needs to draw the current card, and nothing else.
-- Fired on the same StateRE the rest of the game uses, under a "tutorial"
-- kind, whenever `advance` returns true -- plus once inside `init`, so a
-- client that rejoins mid-lesson gets the card it was on.
function Tutorial.state(session: Session): any
	local step: any = Tutorial.STEPS[session.stepIndex]
	-- Knocked out outranks finished: a student who took the map and was then
	-- wiped out has done both, and the one they need told about is the one
	-- that just happened to them.
	if session.failed then
		step = if session.lite then Tutorial.LITE_FAILED else Tutorial.FAILED
	elseif session.finished then
		step = if session.lite then Tutorial.LITE_DONE else Tutorial.DONE
	end
	-- IS THIS CARD ALREADY ANSWERED? Asked once here and used three times
	-- below. A card whose own `done` is true is still the CURRENT card only
	-- because the next one is not ready yet -- see the HELD, NOT SKIPPED
	-- note in `advance`, which holds here rather than putting up a card the
	-- student cannot act on.
	local answered = not (session.finished or session.failed)
		and step ~= nil
		and step.done ~= nil
		and step.done(session)
	return {
		-- A lite track numbers its own three cards, not the full seven.
		index = if session.lite then session.stepIndex - (Tutorial.LITE_FIRST - 1) else session.stepIndex,
		count = if session.lite then Tutorial.LITE_LAST - Tutorial.LITE_FIRST + 1 else #Tutorial.STEPS,
		-- Read by the HUD, the diplomacy tab and the tutorial shop: a lite card
		-- is a card and nothing more -- not a lesson round.
		lite = session.lite == true,
		id = step and step.id or "done",
		title = step and step.title or "",
		body = step and step.body or "",
		hint = step and step.hint or "",
		-- NOTHING TRUE LEFT TO SAY, SO SAY NOTHING (owner, 2026-09-03: "tap to
		-- attack still keeps showing up after i tap 3 times. i want the
		-- instructions to disappear after i do it 3 times"). Holding the
		-- answered card on screen for the whole wait reads as the tutorial
		-- repeating an instruction already carried out three times.
		--
		-- THE WAIT ITSELF IS NOT A BUG AND IS NOT BEING REMOVED: it is
		-- invade.ready holding until there is somebody to invade, and the
		-- warhead's price gate holding until there is a nuke to fire. Only the
		-- card goes. The round stays a tutorial -- see HUD.setTutorial, which
		-- keeps the HUD stripped back rather than popping the war readouts in
		-- for the gap and back out again.
		hidden = answered,
		-- Nor does an answered card go on pointing. No armed rail button...
		arm = (not answered) and step and step.arm or nil,
		-- ...and no ring: the tile the client rings, and points an arrow at
		-- when it is off screen. nil on any card that is not asking for a tap.
		target = (not answered)
			and not (session.finished or session.failed)
			and session.target
			or nil,
		finished = session.finished,
		failed = session.failed,
		grace = Tutorial.graceRemaining(session),
	}
end

return Tutorial
