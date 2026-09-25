--!strict
-- Conquest :: Tutorial  (shared)
-- The first round a new player is ever put into: a short match on a small
-- roster against THREE AI EMPIRES WEARING REAL PLAYER IDENTITIES -- a name and
-- a Roblox headshot -- so the tutorial reads as a game with people in it rather
-- than as a practice range. The rest of the map is ordinary NPC nations, the
-- same ones every other round runs.
--
-- NOTHING REQUIRES THIS YET. It is the backend only. Everything a caller has
-- to do to wire it up is marked `-- WIRING:` next to the function that serves
-- it; there are five of those and they are the whole integration.
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
-- Everything else stays on the bot path -- halved income, the boat-prey split,
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
Tutorial.FRIENDS = {
	{ name = "4Jezza", display = "Jezza", userId = 420199601 },
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
	{ name = "cabotjohn", display = "cabot", userId = 1615479753 },
	{ name = "LoadingL0n3ly", display = "Fedor", userId = 1045324707 },
	{ name = "BrokenRainer", display = "NotPengu", userId = 155739726 },
	{ name = "Cheesemill03", display = "Cheesemill", userId = 260425604 },
	{ name = "TIGERFIST36000", display = "Hypno", userId = 248757795 },
} :: { Identity }

-- The NPC nations. A DUPLICATE of ConquestServer's BOT_NAMES, deliberately:
-- that list is a local inside a server Script and this module is shared, so the
-- alternative is either a require of a Script (impossible) or moving the list
-- into Config, which two sessions have already fought over. Keep them in the
-- same house style -- an NPC that is named differently from every other round's
-- NPCs is a tell that this round is not a real one.
Tutorial.NPC_NAMES = {
	"Draywood", "Elmsgate", "Foxglove", "Greywater", "Hollowmere", "Ivorhold",
	"Jessamy", "Kilbraith", "Larkspur", "Mistvale", "Norhollow", "Orenthal",
	"Palisade", "Quintmark", "Rookswood", "Silverthane",
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

Tutorial.FAUX_COUNT = 3
-- Enough NPCs that the land grab converges in a few minutes instead of the
-- fifteen a full-size round takes: the pressure a tutorial needs is a
-- NEIGHBOUR ARRIVING, and on a sparse map nobody arrives.
Tutorial.NPC_COUNT = 12

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

-- The student's opening treasury. A city is the fifth lesson and gold accrues
-- at 100/tick; without a float the build steps are a three-minute wait with
-- nothing to do, which is where a tutorial loses people.
Tutorial.STARTING_GOLD = 300000

-- What counts as "you have won the tutorial". NOT the mode's own 0.8 -- an
-- 80% conquest is a fifteen-minute match and this is a lesson. The lesson
-- track ends here and hands back to the caller; the sim's own win check is
-- untouched and still runs underneath.
Tutorial.WIN_SHARE = 0.15

-- ============================================================== the session ==

export type Session = {
	sim: any,
	studentId: number,
	-- Player ids wearing an identity, in roster order.
	faux: { number },
	identityOf: { [number]: Identity },
	graceUntilTick: number,

	stepIndex: number,
	stepEnteredTick: number,
	-- Counters snapshotted when the current step began, so a step can ask
	-- "since this card went up" instead of "since the round began".
	mark: { [string]: number },
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

-- Deterministic in the seed, so the same tutorial run always faces the same
-- three faces -- which is what lets a bug report name them.
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

-- A faux empire: a bot in every mechanical sense, wearing a person's name and
-- face. The user id is attached AFTER addPlayer rather than passed to it --
-- see the header. `tier` is passed through because addPlayer rolls a bot's
-- whole personality (think period, reserve ratios) off it at creation.
local function addFaux(sim: any, identity: Identity, tier: number): any
	local p = sim:addPlayer(identity.display, true, nil, tier)
	if p == nil then
		return nil
	end
	p.userId = identity.userId
	return p
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
-- WIRING: this replaces the `Sim.new` + roster block in ConquestServer's
-- startRound for a tutorial server. Nothing else in that function changes.
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
	student.gold = Tutorial.STARTING_GOLD

	local identities = Tutorial.pickIdentities(seed, fauxCount, studentUserId)
	local faux: { number } = {}
	local identityOf: { [number]: Identity } = {}
	for _, identity in identities do
		local p = addFaux(sim, identity, Tutorial.FAUX_TIER)
		if p ~= nil then
			table.insert(faux, p.id)
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

	local session: Session = {
		sim = sim,
		studentId = student.id,
		faux = faux,
		identityOf = identityOf,
		graceUntilTick = math.floor(Tutorial.GRACE_SECONDS / Config.TICK_DT),
		stepIndex = 1,
		stepEnteredTick = 0,
		mark = {},
		finished = false,
		failed = false,
	}
	Tutorial.enterStep(session, 1)
	return session
end

function Tutorial.student(session: Session): any
	return session.sim.players[session.studentId]
end

function Tutorial.isFaux(session: Session, playerId: number): boolean
	return session.identityOf[playerId] ~= nil
end

-- ================================================================= disguise ==
-- The three lies, in one place. Each one replaces a call in ConquestServer.

-- WIRING: replaces `botIdList()` in sendInit. A faux id must NOT be in here or
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

-- WIRING: replaces `roster()` in sendInit. Identical shape ({i, n, u}); the
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

-- WIRING: run over `playerSummary()` before Net.packPlayers. Mutates in place
-- and returns the same list, so the call site is one wrapper.
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
-- WIRING: one condition in `Sim.botThink`'s target choice, or a refusal in
-- `Sim.launchAttack`. Reading it here rather than baking a flag into Sim keeps
-- the tutorial out of the file every session touches.
function Tutorial.mayAttackStudent(session: Session): boolean
	return session.sim.tick >= session.graceUntilTick
end

function Tutorial.graceRemaining(session: Session): number
	return math.max(0, (session.graceUntilTick - session.sim.tick) * Config.TICK_DT)
end

-- ============================================================== the lessons ==
-- Every step completes on a fact about the SIM, never on a button press: the
-- point of a step is that the player did the thing, and a "next" button is a
-- player who tapped through it. `done` is a pure read -- no side effects --
-- because `advance` may call it several times a second.

export type Step = {
	id: string,
	title: string,
	body: string,
	-- One line under the card. Says how, where the body says what.
	hint: string,
	-- Which action-rail button to light while this card is up, if any:
	-- "city" | "port" | "factory" | "nuke". Matches ConquestClient's `arm`.
	arm: string?,
	-- Gold handed over as the card goes up. A lesson the treasury cannot pay
	-- for is a wait, not a lesson.
	grant: number?,
	done: (Session) -> boolean,
}

local function land(session: Session): number
	local p = Tutorial.student(session)
	return p and p.tileCount or 0
end

Tutorial.STEPS = {
	{
		id = "spawn",
		title = "PICK YOUR HOMELAND",
		body = "Click any land on the map to start your empire there.",
		hint = "Inland is safer than the coast -- fewer ways in.",
		done = function(s: Session): boolean
			local p = Tutorial.student(s)
			return p ~= nil and p.spawned == true
		end,
	},
	{
		id = "army",
		title = "YOUR ARMY GROWS ON ITS OWN",
		body = "Troops arrive every second. The bar by your name is how close "
			.. "you are to your ceiling -- more land and more cities raise it.",
		hint = "Nothing to do here. Watch the number climb.",
		-- The ONE step with a dwell, and it needs one: a spawn blob hands over
		-- a starting army on the tick it lands, so any absolute troop bar is
		-- already met before the card has finished appearing. Measured: the
		-- student was on 25,000 troops the instant they spawned. What the card
		-- is teaching is that the number MOVES, so it waits for six seconds of
		-- it moving.
		--
		-- The dwell is measured from the LATER of "card went up" and "the
		-- round started", which is what `phaseTick` is once the phase is
		-- playing (Sim:3393 zeroes it on the transition). Without that, the
		-- card spends the whole 20-second spawn countdown telling someone to
		-- watch a number that cannot move yet, and clears the moment it can.
		done = function(s: Session): boolean
			local p = Tutorial.student(s)
			if p == nil or s.sim.phase ~= "playing" then
				return false
			end
			local dwell = math.min(s.sim.tick - s.stepEnteredTick, s.sim.phaseTick)
				* Config.TICK_DT
			return dwell >= 6 and p.troops >= (s.mark.troops or 0) + 250
		end,
	},
	{
		id = "expand",
		title = "TAKE THE OPEN LAND",
		body = "Unclaimed ground is cheap and nobody is defending it. Click "
			.. "empty land next to your own to march into it.",
		hint = "The slider sets how much of your army goes. Half is plenty here.",
		-- Counted from the mark, not from zero: a spawn blob is already ~80
		-- tiles and the lesson is the tiles taken SINCE the card went up.
		done = function(s: Session): boolean
			return land(s) >= (s.mark.tiles or 0) + 250
		end,
	},
	{
		id = "war",
		title = "NOW TAKE SOMEBODY ELSE'S",
		body = "Click a NEIGHBOUR'S territory to invade it. Their troops fight "
			.. "back, so send more than you would at open ground.",
		hint = "Attacking a big empire with a small army just feeds them.",
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
		title = "CITIES PAY FOR THE WAR",
		body = "A city raises your gold income and your troop ceiling. Build "
			.. "them well apart -- they refuse to sit on top of each other.",
		hint = "Press the house on the right, then click your own land.",
		arm = "city",
		grant = 200000,
		done = function(s: Session): boolean
			local p = Tutorial.student(s)
			return p ~= nil and p.cityCount >= 1
		end,
	},
	{
		id = "port",
		title = "PORTS OPEN THE SEA",
		body = "A port trades with every other port on the map and pays you for "
			.. "it. It also lets your transport boats cross water.",
		hint = "Press the ship, then click your coast -- it snaps to the nearest one.",
		arm = "port",
		grant = 200000,
		done = function(s: Session): boolean
			local p = Tutorial.student(s)
			return p ~= nil and p.portCount >= 1
		end,
	},
	{
		id = "win",
		title = "TAKE THE MAP",
		body = "That is the whole game. Grow, build, and take ground off the "
			.. "people around you until the map is yours.",
		hint = "",
		done = function(s: Session): boolean
			if s.sim.phase == "ended" then
				return true
			end
			return land(s) >= s.sim.playableLand * Tutorial.WIN_SHARE
		end,
	},
} :: { Step }

function Tutorial.enterStep(session: Session, index: number)
	local step = Tutorial.STEPS[index]
	session.stepIndex = index
	session.stepEnteredTick = session.sim.tick
	local p = Tutorial.student(session)
	session.mark = {
		tiles = p and p.tileCount or 0,
		troops = p and p.troops or 0,
		gold = p and p.gold or 0,
	}
	if step ~= nil and step.grant ~= nil and p ~= nil then
		p.gold += step.grant
	end
end

function Tutorial.currentStep(session: Session): Step?
	return Tutorial.STEPS[session.stepIndex]
end

-- Call once per tick (or once per summary broadcast -- it is a handful of
-- integer reads either way). Returns true on the tick a card is replaced, so
-- the caller can fire one message instead of polling.
--
-- WIRING: one line in ConquestServer's Heartbeat loop, beside drainStructEvents.
function Tutorial.advance(session: Session): boolean
	if session.finished then
		return false
	end

	local p = Tutorial.student(session)
	-- Knocked out. Not a step: a dead student has nothing left to do in this
	-- round and the caller should offer a restart rather than a next card.
	if p ~= nil and p.spawned and not p.alive then
		if not session.failed then
			session.failed = true
			return true
		end
		return false
	end

	local step = Tutorial.STEPS[session.stepIndex]
	if step == nil then
		session.finished = true
		return true
	end
	if not step.done(session) then
		return false
	end

	if session.stepIndex >= #Tutorial.STEPS then
		session.finished = true
		return true
	end
	Tutorial.enterStep(session, session.stepIndex + 1)
	return true
end

-- Everything the client needs to draw the current card, and nothing else.
-- WIRING: fire this on the same StateRE the rest of the game uses, under a
-- "tutorial" kind, whenever `advance` returns true (plus once inside `init`).
function Tutorial.state(session: Session): any
	local step = Tutorial.STEPS[session.stepIndex]
	return {
		index = session.stepIndex,
		count = #Tutorial.STEPS,
		id = step and step.id or "done",
		title = step and step.title or "",
		body = step and step.body or "",
		hint = step and step.hint or "",
		arm = step and step.arm or nil,
		finished = session.finished,
		failed = session.failed,
		grace = Tutorial.graceRemaining(session),
	}
end

return Tutorial
