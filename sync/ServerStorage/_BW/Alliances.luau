--!strict
-- Conquest :: Alliances  (server only)
--
-- Diplomacy. Relations, alliance requests, alliances and their renewal, the
-- traitor mark, embargo, and targeting -- plus the AI that uses all of it.
--
-- Ported from upstream openfrontio/OpenFrontIO:
--   src/core/game/Game.ts:326-331          Relation enum
--   src/core/game/Game.ts:406-433          AllianceRequest / Alliance surface
--   src/core/game/AllianceImpl.ts          the alliance object and extension
--   src/core/game/AllianceRequestImpl.ts   request status, accept, reject
--   src/core/game/GameImpl.ts:372-450      create / accept / reject a request
--   src/core/game/GameImpl.ts:819-876      break, expire, detach
--   src/core/game/PlayerImpl.ts:652-786    the alliance and traitor surface
--   src/core/game/PlayerImpl.ts:838-922    relations and targeting
--   src/core/game/PlayerImpl.ts:1096-1198  embargo, isFriendly, isOnSameTeam
--   src/core/execution/alliance/*.ts       the four alliance executions
--   src/core/execution/EmbargoExecution.ts, EmbargoAllExecution.ts
--   src/core/execution/TargetPlayerExecution.ts
--   src/core/execution/PlayerExecution.ts:46, :93-108, :488-506
--   src/core/execution/AttackExecution.ts:85-107, :167-186, :368-375
--   src/core/execution/nation/NationAllianceBehavior.ts  (all of it)
--   src/core/execution/NationExecution.ts:294-360        embargo diplomacy
--   src/core/execution/TribeExecution.ts:62-84, :96-113  the tribe's version
--   src/core/execution/utils/AiAttackBehavior.ts:485-552, :738-748
--
-- WHY THIS IS A MODULE AND NOT PART OF Sim. Every function here takes the sim
-- table and reads it through its metatable (sim.players, sim.tick, sim.rng,
-- sim.maxTroops, sim:sameTeam). Nothing in here requires Sim, so there is no
-- cycle, and Sim's attack loop -- the hot path -- gains exactly two multiplies
-- and one table lookup from all of it.
--
-- SERVER AUTHORITY. Upstream runs the whole simulation on every client and
-- resolves diplomacy as Executions queued into a shared turn stream. Conquest
-- runs it once, on the server, so every entry point here is called either from
-- Sim's tick or from ConquestServer's Intent handler. The client is told the
-- outcome and never computes one.

local Config = require(script.Parent.Config)
local TileMap = require(script.Parent.TileMap)

local Alliances = {}

-- ============================================================ constants ==
-- Every default below is upstream's literal, and it transfers 1:1 because
-- both games tick at 10 Hz (Config.TICK_RATE = 10 here,
-- src/core/configuration/Config.ts uses `n * 10` throughout for seconds).
-- Written as `Config.X or <upstream default>` in the house style of Sim's
-- FRONTIER_* block, so this module runs whether or not Config carries the
-- diplomacy section yet.

-- Game.ts:326-331. ORDERED, and the order is load-bearing: upstream compares
-- relations with < and >= against Relation.Neutral and Relation.Friendly.
Alliances.HOSTILE = 0
Alliances.DISTRUSTFUL = 1
Alliances.NEUTRAL = 2
Alliances.FRIENDLY = 3

-- Config.ts:699-705. Five minutes. A HOST-configurable number upstream
-- (customAllianceDuration, 1-15 minutes, 0 disables alliances entirely).
local ALLIANCE_DURATION = Config.ALLIANCE_DURATION_TICKS or 3000
-- Config.ts:693-695. A request nobody answers inside 20 seconds is rejected.
local REQUEST_DURATION = Config.ALLIANCE_REQUEST_DURATION or 200
-- Config.ts:696-698. 30 seconds before the same pair may be asked again.
local REQUEST_COOLDOWN = Config.ALLIANCE_REQUEST_COOLDOWN or 300
-- Config.ts:1168-1170. The renewal prompt opens 30 seconds before expiry.
local EXTEND_OFFSET = Config.ALLIANCE_EXTEND_OFFSET or 300

-- Config.ts:228-236. THE TRAITOR PENALTY. Both are penalties on the traitor
-- as a DEFENDER and neither touches its own attacks: attacking a traitor
-- costs the attacker half the troops it otherwise would (0.5) and each tile
-- costs four fifths of the tick budget (0.8), so a betrayal is answered by
-- everyone on that border being able to eat you for thirty seconds.
local TRAITOR_DEFENSE_DEBUFF = Config.TRAITOR_DEFENSE_DEBUFF or 0.5
local TRAITOR_SPEED_DEBUFF = Config.TRAITOR_SPEED_DEBUFF or 0.8
-- Config.ts:234-236 is `30 * 10` -- 300 TICKS, i.e. thirty seconds, not
-- three hundred.
local TRAITOR_DURATION = Config.TRAITOR_DURATION or 300

-- Config.ts:687-692.
local TARGET_DURATION = Config.TARGET_DURATION or 100
local TARGET_COOLDOWN = Config.TARGET_COOLDOWN or 150
-- Config.ts:668-670 and :706-708.
local EMBARGO_ALL_COOLDOWN = Config.EMBARGO_ALL_COOLDOWN or 100
local TEMP_EMBARGO_DURATION = Config.TEMPORARY_EMBARGO_DURATION or 3000

-- PlayerImpl.ts:869-888. The band edges and the per-tick pull toward zero.
local RELATION_MIN = -100
local RELATION_MAX = 100
local RELATION_DECAY = Config.RELATION_DECAY or 0.05

-- AttackExecution.ts:167-186. Opening an attack costs you relation WITH THE
-- DEFENDER, by difficulty: Easy -60, Medium -70, Hard -80, Impossible -100.
local ATTACK_RELATION_MEDIUM = Config.ATTACK_RELATION_MEDIUM or -70
local ATTACK_RELATION_HARD = Config.ATTACK_RELATION_HARD or -80
-- NationExecution.ts:303. A standing embargo against you is worth -20, and
-- it is applied ONCE and reversed once (embargoMalusApplied), never per tick.
local EMBARGO_MALUS = Config.EMBARGO_MALUS or -20
-- AiAttackBehavior.ts:508. Answering an ally's call costs you a little
-- relation with them: you spent your army, they owe you nothing.
local ASSIST_RELATION = Config.ASSIST_RELATION or -20

-- The spawn phase, in ticks. Upstream numSpawnPhaseTurns() (Config.ts:742-750)
-- is 100/150/300 depending on lobby type; Conquest's is one number.
local SPAWN_TICKS = (Config.SPAWN_PHASE_SECONDS or 20) * (Config.TICK_RATE or 10)

-- How much border a nearby() substitute is allowed to read. See borderRivals.
local NEARBY_SAMPLE = Config.ALLIANCE_NEARBY_SAMPLE or 240

-- UPSTREAM DIFFICULTY, PROJECTED ONTO CONQUEST'S TIERS.
-- NationAllianceBehavior branches on Difficulty in all nine of its private
-- helpers. Conquest has no difficulty setting; it has tiers, and Config's own
-- strategy-ladder block already fixes the projection -- TIER[tier].RESTRAINT
-- false is upstream MEDIUM, true is upstream HARD. Reading the same flag here
-- is what stops diplomacy and targeting from disagreeing about what an AI is.
-- EASY and IMPOSSIBLE are unreachable, so their legs are not ported; each
-- helper below says which two legs it kept.
local MEDIUM = 2
local HARD = 3

local function difficultyOf(p: any): number
	local t = Config.TIER[p.tier or Config.TIER_HUMAN]
	return (t ~= nil and t.RESTRAINT == true) and HARD or MEDIUM
end

-- Alliances can be switched off wholesale, exactly as upstream's
-- disableAlliances() (Config.ts:347-355) does. Every public entry point below
-- that creates or advances a relationship checks it.
local function disabled(): boolean
	return Config.DISABLE_ALLIANCES == true or ALLIANCE_DURATION <= 0
end

-- ============================================================== random ==
-- PseudoRandom.nextInt(min, max) has an EXCLUSIVE upper bound
-- (src/core/PseudoRandom.ts:45-49) and chance(odds) is nextInt(0, odds) == 0,
-- i.e. 1 in `odds` (:93-95). Luau's NextInteger is inclusive at BOTH ends, so
-- a literal transcription of either is off by one outcome -- the same trap
-- Sim documents at its borderSize jitter and at the tier think rates. Both
-- shapes are wrapped here once so no call site has to remember.

local function nextInt(sim: any, min: number, max: number): number
	if max - 1 < min then
		return min
	end
	return sim.rng:NextInteger(min, max - 1)
end

local function chance(sim: any, odds: number): boolean
	return nextInt(sim, 0, odds) == 0
end

-- ================================================================ state ==
-- One table hung off the sim, so a new round gets fresh diplomacy for free:
-- Sim.new builds a new sim table and this is rebuilt with it.

local function state(sim: any)
	local s = sim.diplo
	if s == nil then
		s = {
			-- [a][b] = number in [-100, 100]. Sparse: a pair that has never
			-- interacted has no entry and reads as 0 (Neutral).
			relations = {},
			-- Array of live alliances, plus a two-level index so
			-- allianceWith is O(1) rather than a walk.
			alliances = {},
			allianceOf = {},
			nextAllianceId = 1,
			-- Pending requests, as an array (upstream keeps one flat list on
			-- the Game and filters it -- GameImpl.ts:91).
			requests = {},
			-- pastOutgoingAllianceRequests, reduced to what the cooldown
			-- actually reads: the tick of the most recent one per pair.
			lastRequestAt = {},
			-- [a][b] = { createdAt = tick, temporary = bool }
			embargo = {},
			lastEmbargoAll = {},
			-- NationExecution.embargoMalusApplied (:39): the -20 is applied
			-- once and reversed once, never accumulated per tick.
			embargoMalus = {},
			-- [id] = tick the mark was set. isTraitor is derived.
			traitorAt = {},
			betrayals = {},
			-- [a] = { { tick = n, id = n }, ... }
			targets = {},
			-- Resumable border cursor for borderRivals, same trick as
			-- Sim's p.scanCursor.
			cursor = {},
			-- What the client is told happened. Drained by the transport.
			events = {},
		}
		sim.diplo = s
	end
	return s
end

Alliances.state = state

-- Called from Sim.new. Optional -- state() builds on demand -- but explicit
-- init keeps the shape of a fresh sim table honest.
function Alliances.init(sim: any)
	sim.diplo = nil
	state(sim)
end

local function note(sim: any, kind: string, a: number, b: number, extra: number?)
	local s = state(sim)
	if #s.events > 256 then
		return
	end
	table.insert(s.events, { k = kind, a = a, b = b, n = extra })
end

-- Drained by ConquestServer on the summary beat, exactly as struct and rail
-- events are. Returns nil when there is nothing, so the caller can skip the
-- send rather than push an empty table five times a second.
function Alliances.drainEvents(sim: any): { any }?
	local s = state(sim)
	if #s.events == 0 then
		return nil
	end
	local out = s.events
	s.events = {}
	return out
end

-- ============================================================ relations ==
-- PlayerImpl.ts:838-888.

local function relationValue(sim: any, a: number, b: number): number
	local row = state(sim).relations[a]
	if row == nil then
		return 0
	end
	return row[b] or 0
end

Alliances.relationValue = relationValue

-- PlayerImpl.ts:846-857. The bands are half-open and asymmetric on purpose:
-- zero is Neutral, and it takes a full -50 to become Hostile but only -1 to
-- become Distrustful.
local function relationFromValue(v: number): number
	if v < -50 then
		return Alliances.HOSTILE
	end
	if v < 0 then
		return Alliances.DISTRUSTFUL
	end
	if v < 50 then
		return Alliances.NEUTRAL
	end
	return Alliances.FRIENDLY
end

function Alliances.relation(sim: any, a: number, b: number): number
	return relationFromValue(relationValue(sim, a, b))
end

-- PlayerImpl.ts:869-877. Clamped, and NOT symmetric: A's opinion of B and B's
-- opinion of A are separate numbers, which is what lets one side be ready to
-- ally while the other is still furious.
function Alliances.updateRelation(sim: any, a: number, b: number, delta: number)
	if a == b then
		return
	end
	local s = state(sim)
	local row = s.relations[a]
	if row == nil then
		row = {}
		s.relations[a] = row
	end
	row[b] = math.clamp((row[b] or 0) + delta, RELATION_MIN, RELATION_MAX)
end

-- PlayerImpl.ts:878-888, called once per player per tick from
-- PlayerExecution.ts:46. Everything crawls back toward zero, so an insult is
-- forgotten in about twenty seconds of quiet and a war in about three
-- minutes. Walks only pairs that HAVE an entry, so a round that has seen no
-- diplomacy costs nothing.
function Alliances.decayRelations(sim: any)
	for _, row in state(sim).relations do
		for other, r in row do
			local sign = 0
			if r > 0 then
				sign = -1
			elseif r < 0 then
				sign = 1
			end
			local v = r + sign * RELATION_DECAY
			if math.abs(v) < RELATION_DECAY * 2 then
				v = 0
			end
			row[other] = v
		end
	end
end

-- ============================================================ alliances ==
-- AllianceImpl.ts plus GameImpl.ts:402-450 and :819-876.

function Alliances.allianceWith(sim: any, a: number, b: number): any
	if a == b then
		return nil
	end
	local row = state(sim).allianceOf[a]
	return row ~= nil and row[b] or nil
end

function Alliances.allied(sim: any, a: number, b: number): boolean
	return Alliances.allianceWith(sim, a, b) ~= nil
end

-- PlayerImpl.ts:1190-1198. THE COMPOSITION RULE, and the whole reason this
-- file exists beside Sim.sameTeam rather than inside it: friendly is
-- "same team OR allied". An ally is not a teammate -- it shares no win
-- condition, no team bar and no colour -- it is simply someone you may not
-- shoot at.
--
-- One deliberate difference from upstream. isOnSameTeam returns FALSE for
-- self (PlayerImpl.ts:1177-1180) while isFriendly returns TRUE for self
-- (:1191-1193); Conquest's Sim.sameTeam already returns true for self, so
-- this composes to upstream's isFriendly exactly.
function Alliances.isFriendly(sim: any, a: number, b: number): boolean
	if sim.sameTeam(sim, a, b) then
		return true
	end
	return Alliances.allied(sim, a, b)
end

function Alliances.alliesOf(sim: any, id: number): { number }
	local out = {}
	local row = state(sim).allianceOf[id]
	if row ~= nil then
		for other in row do
			table.insert(out, other)
		end
		table.sort(out)
	end
	return out
end

function Alliances.count(sim: any, id: number): number
	local n = 0
	local row = state(sim).allianceOf[id]
	if row ~= nil then
		for _ in row do
			n += 1
		end
	end
	return n
end

-- GameImpl.ts:871-876. Removes the pair from both sides' indexes and from the
-- flat list. Silent by itself: every caller decides what to announce.
local function detach(sim: any, al: any)
	local s = state(sim)
	local ra = s.allianceOf[al.a]
	if ra ~= nil then
		ra[al.b] = nil
	end
	local rb = s.allianceOf[al.b]
	if rb ~= nil then
		rb[al.a] = nil
	end
	for i = #s.alliances, 1, -1 do
		if s.alliances[i] == al then
			table.remove(s.alliances, i)
			break
		end
	end
end

local function attach(sim: any, a: number, b: number): any
	local s = state(sim)
	local al = {
		id = s.nextAllianceId,
		-- `a` is the REQUESTOR and `b` the recipient, kept apart because the
		-- extension flags are per-role (AllianceImpl.ts:43-53).
		a = a,
		b = b,
		createdAt = sim.tick,
		expiresAt = sim.tick + ALLIANCE_DURATION,
		extA = false,
		extB = false,
	}
	s.nextAllianceId += 1
	table.insert(s.alliances, al)
	local ra = s.allianceOf[a]
	if ra == nil then
		ra = {}
		s.allianceOf[a] = ra
	end
	ra[b] = al
	local rb = s.allianceOf[b]
	if rb == nil then
		rb = {}
		s.allianceOf[b] = rb
	end
	rb[a] = al
	return al
end

function Alliances.other(al: any, id: number): number
	return al.a == id and al.b or al.a
end

-- AllianceImpl.ts:71-76.
function Alliances.agreedToExtend(al: any, id: number): boolean
	return (al.a == id and al.extA) or (al.b == id and al.extB)
end

-- AllianceImpl.ts:62-69. TRUE only when exactly one side has asked, which is
-- the state the other side's prompt is driven off.
function Alliances.onlyOneAgreedToExtend(al: any): boolean
	return al.extA ~= al.extB
end

-- ================================================== alliance requests ==
-- AllianceRequestImpl.ts plus GameImpl.ts:372-450.

function Alliances.incomingRequests(sim: any, id: number): { any }
	local out = {}
	for _, r in state(sim).requests do
		if r.to == id then
			table.insert(out, r)
		end
	end
	return out
end

function Alliances.outgoingRequests(sim: any, id: number): { any }
	local out = {}
	for _, r in state(sim).requests do
		if r.from == id then
			table.insert(out, r)
		end
	end
	return out
end

local function findRequest(sim: any, from: number, to: number): any
	for _, r in state(sim).requests do
		if r.from == from and r.to == to then
			return r
		end
	end
	return nil
end

local function dropRequest(sim: any, req: any)
	local s = state(sim)
	for i = #s.requests, 1, -1 do
		if s.requests[i] == req then
			table.remove(s.requests, i)
			break
		end
	end
	-- GameImpl.ts:427-430 and :442-445 push the request onto the sender's
	-- pastOutgoingAllianceRequests on BOTH outcomes, which is what makes the
	-- cooldown apply to a rejection as well as an acceptance.
	local row = s.lastRequestAt[req.from]
	if row == nil then
		row = {}
		s.lastRequestAt[req.from] = row
	end
	if (row[req.to] or -math.huge) < req.createdAt then
		row[req.to] = req.createdAt
	end
end

-- PlayerImpl.ts:714-759. Note the third branch: an INCOMING request from the
-- same player always makes this true, because sending back is how you accept.
function Alliances.canSendRequest(sim: any, a: number, b: number): boolean
	if disabled() then
		return false
	end
	if a == b then
		return false
	end
	local pa, pb = sim.players[a], sim.players[b]
	if pa == nil or pb == nil then
		return false
	end
	-- Upstream also refuses when either side is DISCONNECTED (:722-730).
	-- Conquest has no disconnected state -- ConquestServer turns a leaver's
	-- empire into a bot -- so that branch has nothing to test and is dropped
	-- rather than faked.
	if Alliances.isFriendly(sim, a, b) or not pa.alive then
		return false
	end
	if findRequest(sim, a, b) ~= nil then
		return false
	end
	if findRequest(sim, b, a) ~= nil then
		return true
	end
	local row = state(sim).lastRequestAt[a]
	local last = row ~= nil and row[b] or nil
	if last == nil then
		return true
	end
	return sim.tick - last >= REQUEST_COOLDOWN
end

-- GameImpl.acceptAllianceRequest (:402-436). Creates the alliance and clears
-- the request. NOTE what this does NOT do: it does not touch relations. Only
-- the MUTUAL path in AllianceRequestExecution.init (:46-48) sets both sides
-- to +100, so a normal accept leaves the two exactly as suspicious of each
-- other as they were. That asymmetry is upstream's and is kept.
function Alliances.acceptRequest(sim: any, req: any): boolean
	if Alliances.allied(sim, req.from, req.to) then
		return false
	end
	dropRequest(sim, req)
	attach(sim, req.from, req.to)
	note(sim, "allied", req.from, req.to)
	return true
end

function Alliances.rejectRequest(sim: any, req: any)
	dropRequest(sim, req)
	note(sim, "rejected", req.from, req.to)
end

-- AllianceRequestExecution.init (:22-62) folded together with
-- GameImpl.createAllianceRequest (:372-400): a request that MEETS an
-- outstanding one from the same player is not a second request, it is an
-- acceptance -- and on that path only, both sides jump to +100 and any
-- automatic embargo between them is lifted (:46-54).
--
-- Returns the pending request, or nil if it resolved immediately or was
-- refused.
function Alliances.sendRequest(sim: any, from: number, to: number): any
	if disabled() then
		return nil
	end
	if not Alliances.canSendRequest(sim, from, to) then
		return nil
	end

	local incoming = findRequest(sim, to, from)
	if incoming ~= nil then
		Alliances.acceptRequest(sim, incoming)
		Alliances.updateRelation(sim, from, to, 100)
		Alliances.updateRelation(sim, to, from, 100)
		-- "Automatically remove embargoes only if they were automatically
		-- created" (:50-54). The automatic ones are the temporary embargo an
		-- attack lays down (AttackExecution.ts:104); a deliberate embargo
		-- survives the alliance.
		Alliances.endTemporaryEmbargo(sim, from, to)
		Alliances.endTemporaryEmbargo(sim, to, from)
		-- Upstream also cancels every in-flight nuke between the two
		-- (:89-171). Conquest has no nukes, so there is nothing to cancel.
		return nil
	end

	local req = { from = from, to = to, createdAt = sim.tick }
	table.insert(state(sim).requests, req)
	note(sim, "request", from, to)
	return req
end

-- AllianceRejectExecution (:11-38). Refuses when the two are ALREADY friendly
-- -- there is nothing to reject -- and otherwise rejects the outstanding one.
function Alliances.rejectFrom(sim: any, requestorId: number, recipientId: number): boolean
	if Alliances.isFriendly(sim, requestorId, recipientId) then
		return false
	end
	local req = findRequest(sim, requestorId, recipientId)
	if req == nil then
		return false
	end
	Alliances.rejectRequest(sim, req)
	return true
end

-- AttackExecution.ts:368-375. Opening an attack on somebody who has asked you
-- to ally answers the question.
function Alliances.rejectIncomingFrom(sim: any, meId: number, fromId: number)
	local req = findRequest(sim, fromId, meId)
	if req ~= nil then
		Alliances.rejectRequest(sim, req)
	end
end

-- ================================================ break, expire, renew ==

-- Upstream's nearby(). Conquest maintains no adjacency list, so this is the
-- same sampled border walk Sim's AI uses, with the same resumable cursor: at
-- most `sample` border tiles per call, resuming where the last call stopped.
-- It can MISS a neighbour, and both callers tolerate that -- the betrayal
-- malus reaches fewer bystanders, and the "do we already have enough
-- alliances" test sees a smaller neighbourhood.
local function borderRivals(sim: any, p: any, sample: number): { number }
	local out = {}
	local seen: { [number]: boolean } = {}
	local map = sim.map
	local owner = map.owner
	local nbuf = table.create(4)
	local s = state(sim)

	local tile = s.cursor[p.id]
	if tile ~= nil and p.border[tile] == nil then
		tile = nil
	end
	if tile == nil then
		tile = next(p.border)
	end
	local scanned = 0
	while tile ~= nil and scanned <= sample do
		scanned += 1
		local n = TileMap.neighbors4(tile, nbuf)
		for k = 1, n do
			local nb = nbuf[k]
			if TileMap.isPassable(map, nb) then
				local o = buffer.readu8(owner, nb)
				if o ~= 0 and o ~= p.id and not seen[o] then
					seen[o] = true
					table.insert(out, o)
				end
			end
		end
		tile = next(p.border, tile)
		if tile == nil then
			tile = next(p.border)
		end
	end
	s.cursor[p.id] = tile
	return out
end

Alliances.borderRivals = borderRivals

-- GameImpl.breakAlliance (:819-843) followed by BreakAllianceExecution.tick
-- (:25-51), which is where the social cost lives.
--
-- THE TRAITOR RULE (:832-834): you are marked only if the person you are
-- betraying is NOT themselves a traitor. Breaking with a traitor is free,
-- which is what stops the mark from being a life sentence -- somebody has to
-- be able to cut them loose.
function Alliances.breakAlliance(sim: any, breakerId: number, otherId: number): boolean
	local al = Alliances.allianceWith(sim, breakerId, otherId)
	if al == nil then
		return false
	end

	if not Alliances.isTraitor(sim, otherId) then
		Alliances.markTraitor(sim, breakerId)
	end
	detach(sim, al)
	note(sim, "broke", breakerId, otherId)

	-- BreakAllianceExecution.ts:38 -- the betrayed party's opinion bottoms
	-- out, and :40-48 -- every neighbour of the traitor who is not on the
	-- BETRAYED player's team loses 40. Bystanders punish treachery, which is
	-- the mechanism that makes the mark cost more than one relationship.
	Alliances.updateRelation(sim, otherId, breakerId, -100)
	local breaker = sim.players[breakerId]
	if breaker ~= nil then
		for _, nid in borderRivals(sim, breaker, NEARBY_SAMPLE) do
			if nid ~= breakerId and not sim.sameTeam(sim, nid, otherId) then
				Alliances.updateRelation(sim, nid, breakerId, -40)
			end
		end
	end
	return true
end

-- PlayerExecution.ts:93-98 by way of AllianceImpl.expire (:39-41) and
-- GameImpl.expireAlliance (:845-862). An alliance running out is NOT a
-- betrayal: nobody is marked, nobody's relation moves.
function Alliances.expireAlliance(sim: any, al: any)
	detach(sim, al)
	note(sim, "expired", al.a, al.b)
end

-- AllianceExtensionExecution (:15-79). Each side registers its intent
-- separately; the clock is only reset when BOTH have. The middle state --
-- exactly one side asked -- is what the other side's "renew?" prompt reads.
function Alliances.requestExtension(sim: any, fromId: number, toId: number): boolean
	local al = Alliances.allianceWith(sim, fromId, toId)
	if al == nil then
		return false
	end
	local pa, pb = sim.players[fromId], sim.players[toId]
	if pa == nil or pb == nil or not pa.alive or not pb.alive then
		return false
	end

	local wasOnlyOne = Alliances.onlyOneAgreedToExtend(al)
	if al.a == fromId then
		al.extA = true
	elseif al.b == fromId then
		al.extB = true
	end

	if al.extA and al.extB then
		al.extA = false
		al.extB = false
		al.expiresAt = sim.tick + ALLIANCE_DURATION
		note(sim, "renewed", fromId, toId)
		return true
	elseif Alliances.onlyOneAgreedToExtend(al) and not wasOnlyOne then
		-- :66-78 -- tell the other side, and only on the transition, so
		-- holding the button does not spam them.
		note(sim, "wantsrenew", fromId, toId)
	end
	return false
end

-- Is this alliance close enough to expiry that the client should offer the
-- renew button? PlayerImpl.allianceInfo (:690-712).
function Alliances.inExtensionWindow(sim: any, al: any): boolean
	return al.expiresAt <= sim.tick + EXTEND_OFFSET
end

-- PlayerImpl.removeAllAlliances (:765-767) -> GameImpl (:864-869), called
-- from PlayerExecution.removeOnDeath (:488-506). SILENT: an empire that has
-- been wiped off the map has not betrayed anybody.
function Alliances.onPlayerDeath(sim: any, id: number)
	local s = state(sim)
	local row = s.allianceOf[id]
	if row ~= nil then
		local removed = {}
		for _, al in row do
			table.insert(removed, al)
		end
		for _, al in removed do
			detach(sim, al)
		end
	end
	s.allianceOf[id] = nil
	for i = #s.requests, 1, -1 do
		local r = s.requests[i]
		if r.from == id or r.to == id then
			table.remove(s.requests, i)
		end
	end
	s.embargo[id] = nil
	for _, e in s.embargo do
		e[id] = nil
	end
	s.targets[id] = nil
	s.cursor[id] = nil
end

-- ============================================================== traitor ==
-- PlayerImpl.ts:769-786.

function Alliances.traitorTicksLeft(sim: any, id: number): number
	local at = state(sim).traitorAt[id]
	if at == nil then
		return 0
	end
	local remaining = TRAITOR_DURATION - (sim.tick - at)
	return remaining > 0 and remaining or 0
end

function Alliances.isTraitor(sim: any, id: number): boolean
	return Alliances.traitorTicksLeft(sim, id) > 0
end

function Alliances.markTraitor(sim: any, id: number)
	local s = state(sim)
	s.traitorAt[id] = sim.tick
	s.betrayals[id] = (s.betrayals[id] or 0) + 1
	note(sim, "traitor", id, 0, TRAITOR_DURATION)
end

function Alliances.betrayals(sim: any, id: number): number
	return state(sim).betrayals[id] or 0
end

-- Config.ts:828-829, consumed by attackLogic. Both are keyed off the
-- DEFENDER and are constant for the whole tick, which is why Sim hoists them
-- out of the per-tile loop instead of asking per tile.
function Alliances.traitorLossMod(sim: any, defenderId: number): number
	return Alliances.isTraitor(sim, defenderId) and TRAITOR_DEFENSE_DEBUFF or 1
end

function Alliances.traitorCostMod(sim: any, defenderId: number): number
	return Alliances.isTraitor(sim, defenderId) and TRAITOR_SPEED_DEBUFF or 1
end

-- ============================================================== embargo ==
-- PlayerImpl.ts:1096-1165, EmbargoExecution, EmbargoAllExecution.

function Alliances.hasEmbargoAgainst(sim: any, a: number, b: number): boolean
	local row = state(sim).embargo[a]
	return row ~= nil and row[b] ~= nil
end

-- PlayerImpl.ts:1120-1126. Trade needs BOTH sides willing, so one embargo
-- kills the route in both directions -- which is what makes it a weapon and
-- not just an opinion.
function Alliances.canTrade(sim: any, a: number, b: number): boolean
	if a == b then
		return false
	end
	return not Alliances.hasEmbargoAgainst(sim, a, b)
		and not Alliances.hasEmbargoAgainst(sim, b, a)
end

-- PlayerImpl.ts:1132-1148. A DELIBERATE embargo already in place is never
-- downgraded to a temporary one by a later attack -- that is what the early
-- return is for.
function Alliances.addEmbargo(sim: any, a: number, b: number, temporary: boolean)
	if a == b then
		return
	end
	local s = state(sim)
	local row = s.embargo[a]
	if row == nil then
		row = {}
		s.embargo[a] = row
	end
	local e = row[b]
	if e ~= nil and not e.temporary then
		return
	end
	row[b] = { createdAt = sim.tick, temporary = temporary }
	note(sim, "embargo", a, b)
end

function Alliances.stopEmbargo(sim: any, a: number, b: number)
	local row = state(sim).embargo[a]
	if row == nil or row[b] == nil then
		return
	end
	row[b] = nil
	note(sim, "unembargo", a, b)
end

-- PlayerImpl.ts:1160-1166. Only lifts one it laid down itself.
function Alliances.endTemporaryEmbargo(sim: any, a: number, b: number)
	local row = state(sim).embargo[a]
	local e = row ~= nil and row[b] or nil
	if e == nil or not e.temporary then
		return
	end
	Alliances.stopEmbargo(sim, a, b)
end

function Alliances.canEmbargoAll(sim: any, id: number): boolean
	local last = state(sim).lastEmbargoAll[id]
	return last == nil or sim.tick - last >= EMBARGO_ALL_COOLDOWN
end

-- EmbargoAllExecution (:9-27). Skips the filler tier -- upstream skips
-- PlayerType.Bot with the comment "bots can't trade anyway" -- and skips
-- teammates, whose trade you want.
function Alliances.embargoAll(sim: any, id: number, stop: boolean): boolean
	if not Alliances.canEmbargoAll(sim, id) then
		return false
	end
	for _, other in sim.playerOrder do
		if other ~= id then
			local o = sim.players[other]
			if o ~= nil and o.tier ~= Config.TIER_TRIBE and not sim.sameTeam(sim, id, other) then
				if stop then
					if Alliances.hasEmbargoAgainst(sim, id, other) then
						Alliances.stopEmbargo(sim, id, other)
					end
				else
					if not Alliances.hasEmbargoAgainst(sim, id, other) then
						Alliances.addEmbargo(sim, id, other, false)
					end
				end
			end
		end
	end
	state(sim).lastEmbargoAll[id] = sim.tick
	return true
end

-- ============================================================ targeting ==
-- PlayerImpl.ts:890-922 plus TargetPlayerExecution (:23-29). Marking somebody
-- is a PUBLIC request for help: your allies read it and may pile on
-- (assistAllies), and it costs you relation with the person you named.

function Alliances.canTarget(sim: any, a: number, b: number): boolean
	if a == b then
		return false
	end
	if Alliances.isFriendly(sim, a, b) then
		return false
	end
	local list = state(sim).targets[a]
	if list ~= nil then
		for _, t in list do
			if sim.tick - t.tick < TARGET_COOLDOWN then
				return false
			end
		end
	end
	return true
end

function Alliances.target(sim: any, a: number, b: number): boolean
	if not Alliances.canTarget(sim, a, b) then
		return false
	end
	local s = state(sim)
	local list = s.targets[a]
	if list == nil then
		list = {}
		s.targets[a] = list
	end
	table.insert(list, { tick = sim.tick, id = b })
	Alliances.updateRelation(sim, b, a, -40)
	note(sim, "target", a, b)
	return true
end

function Alliances.targetsOf(sim: any, id: number): { number }
	local out = {}
	local list = state(sim).targets[id]
	if list ~= nil then
		for _, t in list do
			if sim.tick - t.tick < TARGET_DURATION then
				table.insert(out, t.id)
			end
		end
	end
	return out
end

-- PlayerImpl.ts:918-923. Your allies' marks are your marks.
function Alliances.transitiveTargets(sim: any, id: number): { number }
	local seen: { [number]: boolean } = {}
	local out = {}
	local function add(list: { number })
		for _, t in list do
			if not seen[t] then
				seen[t] = true
				table.insert(out, t)
			end
		end
	end
	for _, ally in Alliances.alliesOf(sim, id) do
		add(Alliances.targetsOf(sim, ally))
	end
	add(Alliances.targetsOf(sim, id))
	return out
end

-- ========================================================== attack hook ==
-- AttackExecution.init, the diplomacy half. Called from Sim.launchAttack once
-- per attack COMMAND (upstream builds one AttackExecution per command and
-- merges afterwards, so the counts line up).

function Alliances.onAttack(sim: any, attackerId: number, targetId: number)
	if targetId == 0 or attackerId == targetId then
		return
	end
	local a, d = sim.players[attackerId], sim.players[targetId]
	if a == nil or d == nil then
		return
	end

	-- :96-107. The filler tier is exempt in BOTH directions -- upstream's
	-- reason is that bots cannot trade, so an embargo against them is
	-- meaningless -- and the automatic embargo is TEMPORARY, so allying later
	-- clears it.
	if a.tier ~= Config.TIER_TRIBE and d.tier ~= Config.TIER_TRIBE then
		Alliances.addEmbargo(sim, targetId, attackerId, true)
		Alliances.rejectIncomingFrom(sim, targetId, attackerId)
	end

	-- :167-186. Being attacked is the largest single relation event in the
	-- game and it is one-directional: the DEFENDER's opinion of the attacker
	-- collapses, the attacker's opinion of the defender does not move.
	local delta = (difficultyOf(a) == HARD) and ATTACK_RELATION_HARD or ATTACK_RELATION_MEDIUM
	Alliances.updateRelation(sim, targetId, attackerId, delta)
end

-- ================================================================= tick ==
-- Everything upstream spreads across PlayerExecution.tick and the alliance
-- executions' own tick(), in one pass. Called once per sim tick.

function Alliances.step(sim: any)
	local s = state(sim)
	local tick = sim.tick

	-- PlayerExecution.ts:93-98.
	for i = #s.alliances, 1, -1 do
		local al = s.alliances[i]
		if al.expiresAt <= tick then
			Alliances.expireAlliance(sim, al)
		end
	end

	-- AllianceRequestExecution.tick (:64-79). Timing out is a REJECTION, so
	-- the sender's cooldown starts either way and a spurned player cannot
	-- simply ask again next tick.
	for i = #s.requests, 1, -1 do
		local r = s.requests[i]
		if tick - r.createdAt > REQUEST_DURATION then
			Alliances.rejectRequest(sim, r)
		end
	end

	-- PlayerExecution.ts:100-108.
	for a, row in s.embargo do
		for b, e in row do
			if e.temporary and tick - e.createdAt > TEMP_EMBARGO_DURATION then
				Alliances.stopEmbargo(sim, a, b)
			end
		end
	end

	-- PlayerExecution.ts:46.
	Alliances.decayRelations(sim)
end

-- ======================================================= nation AI: core ==
-- NationAllianceBehavior.ts in full. Every private helper keeps its upstream
-- name so the two files can be read side by side.

-- :150-169. Hard and Impossible only: refuse anyone who is already allied
-- with a large share of the roster, so there are always enough non-friendly
-- players left to stop a runaway leader. `totalPlayers` counts NON-FILLER
-- empires, i.e. everyone but the tribes.
local function hasTooManyAlliances(sim: any, p: any, other: any): boolean
	if difficultyOf(p) ~= HARD then
		return false
	end
	local total = 0
	for _, id in sim.playerOrder do
		local q = sim.players[id]
		if q ~= nil and q.tier ~= Config.TIER_TRIBE then
			total += 1
		end
	end
	return Alliances.count(sim, other.id) >= total * 0.5
end

-- :171-185. Medium 1 in 20, Hard 1 in 40. A confused nation flips a coin
-- instead of thinking, which is what keeps the roster from reading as one
-- deterministic policy wearing seventy-two names.
local function isConfused(sim: any, p: any): boolean
	return chance(sim, difficultyOf(p) == HARD and 40 or 20)
end

-- :187-218. Medium: accept 70% inside the first three minutes. Hard: 50%.
local function isEarlygame(sim: any, p: any): boolean
	if sim.tick >= 1800 + SPAWN_TICKS then
		return false
	end
	local bar = (difficultyOf(p) == HARD) and 50 or 30
	return nextInt(sim, 0, 100) >= bar
end

-- :220-252. Medium sees a threat only in someone with 2.5x the army. Hard
-- also reads the CEILING, so it can tell a big empire holding a small army
-- from a small one -- and it ALLIES with threats rather than fighting them,
-- which is why this returns true meaning "yes, accept".
local function isAlliancePartnerThreat(sim: any, p: any, other: any): boolean
	if difficultyOf(p) == HARD then
		return other.troops > p.troops
			and sim.maxTroops(other) > sim.maxTroops(p) * 2
	end
	return other.troops > p.troops * 2.5
end

-- :254-272. Allying across a team game makes less sense, so it is refused
-- half the time on Medium and three quarters on Hard.
local function shouldRejectInTeamGame(sim: any, p: any): boolean
	if sim.teamCount <= 0 then
		return false
	end
	return nextInt(sim, 0, 100) < ((difficultyOf(p) == HARD) and 75 or 50)
end

-- :274-306. Medium: a flat cap of 4 or 5. Hard: never ally with EVERY
-- neighbour -- keep at least one border hostile -- and otherwise cap at 3-4.
local function checkAlreadyEnoughAlliances(sim: any, p: any, other: any): boolean
	local mine = Alliances.count(sim, p.id)
	if difficultyOf(p) ~= HARD then
		return mine >= nextInt(sim, 4, 6)
	end
	local bordering = {}
	for _, id in borderRivals(sim, p, NEARBY_SAMPLE) do
		local q = sim.players[id]
		if q ~= nil and q.tier ~= Config.TIER_TRIBE then
			table.insert(bordering, id)
		end
	end
	local friends = 0
	local includesOther = false
	for _, id in bordering do
		if Alliances.isFriendly(sim, p.id, id) then
			friends += 1
		end
		if id == other.id then
			includesOther = true
		end
	end
	if #bordering >= 2 and includesOther then
		return #bordering <= friends + 1
	end
	return mine >= nextInt(sim, 3, 5)
end

-- :308-327.
local function isAlliancePartnerFriendly(sim: any, p: any, other: any): boolean
	if Alliances.relation(sim, p.id, other.id) ~= Alliances.FRIENDLY then
		return false
	end
	if difficultyOf(p) == HARD then
		return nextInt(sim, 0, 100) >= 17
	end
	return true
end

-- :330-369. "Similarly strong" counts troops IN THE FIELD as well as at home,
-- because an empire that has just committed its whole army is not weak, it is
-- busy. Both bands are randomised per call so the bar is not a hard edge.
local function isAlliancePartnerSimilarlyStrong(sim: any, p: any, other: any): boolean
	local hard = difficultyOf(p) == HARD
	local troopLo, troopHi = 70, 80
	local tileLo, tileHi = 80, 90
	if hard then
		troopLo, troopHi = 75, 85
		tileLo, tileHi = 85, 95
	end

	local mineOut, otherOut = 0, 0
	for _, atk in sim.attacks do
		if atk.active then
			if atk.attackerId == p.id then
				mineOut += atk.troops
			elseif atk.attackerId == other.id then
				otherOut += atk.troops
			end
		end
	end
	local mineTotal = p.troops + mineOut
	local otherTotal = other.troops + otherOut

	local troopThreshold = mineTotal * (nextInt(sim, troopLo, troopHi) / 100)
	local tileThreshold = p.tileCount * (nextInt(sim, tileLo, tileHi) / 100)

	local comparableTroops = otherTotal > troopThreshold
	local comparableTiles = other.tileCount > tileThreshold
		and otherTotal > mineTotal * 0.5
	return comparableTroops or comparableTiles
end

-- :88-148. THE DECISION, and the order of its clauses is the whole character
-- of the AI: fear beats grudges (a threat is accepted even when the relation
-- is bad), grudges beat opportunism, and everything loses to being a traitor.
-- `isResponse` distinguishes answering a request from offering one; upstream
-- only uses it to pick which emoji to send, which Conquest has no channel for.
local function getAllianceDecision(sim: any, p: any, other: any, isResponse: boolean): boolean
	if isConfused(sim, p) then
		return chance(sim, 2)
	end
	-- :96-102 -- a traitor is refused 90 times in 100, whatever else is true.
	if Alliances.isTraitor(sim, other.id) and nextInt(sim, 0, 100) >= 10 then
		return false
	end
	if hasTooManyAlliances(sim, p, other) then
		return false
	end
	if isAlliancePartnerThreat(sim, p, other) then
		return true
	end
	if shouldRejectInTeamGame(sim, p) then
		return false
	end
	if Alliances.relation(sim, p.id, other.id) < Alliances.NEUTRAL then
		return false
	end
	if isAlliancePartnerFriendly(sim, p, other) then
		return true
	end
	if checkAlreadyEnoughAlliances(sim, p, other) then
		return false
	end
	if isEarlygame(sim, p) then
		return true
	end
	return isAlliancePartnerSimilarlyStrong(sim, p, other)
end

Alliances.getAllianceDecision = getAllianceDecision

-- :29-46. Answer everything waiting. Requests made DURING the spawn phase are
-- rejected outright: upstream's reason is that spawn-phase intents all
-- execute on the first live tick, so accepting them would hand out alliances
-- before anybody has seen the map.
function Alliances.handleAllianceRequests(sim: any, p: any)
	if disabled() then
		return
	end
	for _, req in Alliances.incomingRequests(sim, p.id) do
		if req.createdAt <= SPAWN_TICKS + 1 then
			Alliances.rejectRequest(sim, req)
		else
			local other = sim.players[req.from]
			if other == nil or not other.alive then
				Alliances.rejectRequest(sim, req)
			elseif getAllianceDecision(sim, p, other, true) then
				Alliances.acceptRequest(sim, req)
			else
				Alliances.rejectRequest(sim, req)
			end
		end
	end
end

-- :48-63. Only ever answers -- a nation never opens a renewal itself, so the
-- decision to keep an alliance alive stays with whoever cared enough to ask.
function Alliances.handleExtensionRequests(sim: any, p: any)
	if disabled() then
		return
	end
	local row = state(sim).allianceOf[p.id]
	if row == nil then
		return
	end
	local pending = {}
	for _, al in row do
		if Alliances.onlyOneAgreedToExtend(al) and not Alliances.agreedToExtend(al, p.id) then
			table.insert(pending, al)
		end
	end
	for _, al in pending do
		local otherId = Alliances.other(al, p.id)
		local other = sim.players[otherId]
		if other ~= nil and getAllianceDecision(sim, p, other, true) then
			Alliances.requestExtension(sim, p.id, otherId)
		end
	end
end

-- :65-86. Offer to whoever we are standing across a border from, 1 time in
-- 30. `isAcceptablePlayerType` (:69-72) lets only EASY nations approach the
-- filler tier, and Conquest projects onto Medium and Hard, so a tribe is
-- never asked.
--
-- `rivalIds` is the caller's bordering set. Sim's AI already has one -- the
-- sampled `tileByRival` window -- and rebuilding it here would double the
-- most expensive thing a think does.
function Alliances.maybeSendAllianceRequests(sim: any, p: any, rivalIds: { number })
	if disabled() then
		return
	end
	for _, id in rivalIds do
		local other = sim.players[id]
		if
			other ~= nil
			and other.alive
			and other.tier ~= Config.TIER_TRIBE
			and chance(sim, 30)
			and Alliances.canSendRequest(sim, p.id, id)
			and getAllianceDecision(sim, p, other, false)
		then
			Alliances.sendRequest(sim, p.id, id)
		end
	end
end

-- :371-434. FOUR reasons to stab an ally, and each one is a different kind of
-- opportunism. Returns true when the alliance was actually broken, which is
-- the caller's signal to follow it with an attack.
function Alliances.maybeBetray(sim: any, p: any, otherId: number, borderingCount: number): boolean
	if not Alliances.allied(sim, p.id, otherId) then
		return false
	end
	local other = sim.players[otherId]
	if other == nil or not other.alive then
		return false
	end
	local hard = difficultyOf(p) == HARD

	local function betray(): boolean
		return Alliances.breakAlliance(sim, p.id, otherId)
	end

	-- :376-390, Hard and above. Somebody already broken -- army far under
	-- their own ceiling and under ours.
	if hard then
		local otherOut = 0
		for _, atk in sim.attacks do
			if atk.active and atk.attackerId == otherId then
				otherOut += atk.troops
			end
		end
		if
			other.troops + otherOut < sim.maxTroops(other) * 0.2
			and other.troops < p.troops
		then
			return betray()
		end
	end

	-- :392-405, Easy and Medium. Cruder -- ten times their army and nothing
	-- else -- and upstream keeps it deliberately dumb: "it makes nations
	-- vulnerable, but that's intended".
	if not hard and p.troops >= other.troops * 10 then
		return betray()
	end

	-- :407-415. A traitor who is not much stronger than us is fair game, and
	-- betraying one costs nothing (breakAlliance does not mark you for it).
	if Alliances.isTraitor(sim, otherId) and other.troops < p.troops * 1.2 then
		return betray()
	end

	-- :417-425. Our ONLY neighbour, and we are three times their size. There
	-- is nothing else on this border to fight.
	if borderingCount == 1 and other.troops * 3 < p.troops then
		return betray()
	end

	return false
end

-- TribeExecution.ts:67-84. A TRIBE HAS NO NationAllianceBehavior AT ALL --
-- it builds its AiAttackBehavior with six arguments and leaves the alliance
-- behaviour undefined (:48-55) -- so it does not decide anything: it accepts
-- every request and every renewal it is offered. That is what makes tribes
-- worth talking to and worth betraying, and why they are the cheapest ally
-- on the map.
function Alliances.acceptAll(sim: any, p: any)
	if disabled() then
		return
	end
	for _, req in Alliances.incomingRequests(sim, p.id) do
		Alliances.acceptRequest(sim, req)
	end
	local row = state(sim).allianceOf[p.id]
	if row == nil then
		return
	end
	local pending = {}
	for _, al in row do
		if Alliances.onlyOneAgreedToExtend(al) and not Alliances.agreedToExtend(al, p.id) then
			table.insert(pending, al)
		end
	end
	for _, al in pending do
		Alliances.requestExtension(sim, p.id, Alliances.other(al, p.id))
	end
end

-- ==================================================== nation AI: embargo ==

-- NationExecution.ts:294-313. The malus is applied ONCE while an embargo
-- stands against us and reversed ONCE when it lifts, never accumulated -- a
-- per-tick -20 would floor every relation in the game inside a second.
function Alliances.updateRelationsFromEmbargos(sim: any, p: any)
	local s = state(sim)
	local applied = s.embargoMalus[p.id]
	if applied == nil then
		applied = {}
		s.embargoMalus[p.id] = applied
	end
	for _, id in sim.playerOrder do
		if id ~= p.id then
			local against = Alliances.hasEmbargoAgainst(sim, id, p.id)
			if against and not applied[id] then
				Alliances.updateRelation(sim, p.id, id, EMBARGO_MALUS)
				applied[id] = true
			elseif not against and applied[id] then
				Alliances.updateRelation(sim, p.id, id, -EMBARGO_MALUS)
				applied[id] = nil
			end
		end
	end
end

-- NationExecution.ts:315-360. Hostility becomes a trade embargo and stays one
-- until the relation is neutral again -- so a war has an economic tail that
-- outlasts the fighting.
function Alliances.handleEmbargoesToHostileNations(sim: any, p: any)
	local hard = difficultyOf(p) == HARD
	local teamGame = sim.teamCount > 0
	for _, id in sim.playerOrder do
		if id ~= p.id then
			local other = sim.players[id]
			if other ~= nil then
				local sameTeam = sim.sameTeam(sim, p.id, id)
				if teamGame and hard and other.tier ~= Config.TIER_TRIBE and not sameTeam then
					-- :325-337 -- on a higher difficulty a team game means
					-- refusing to trade with anyone outside the bloc.
					if not Alliances.hasEmbargoAgainst(sim, p.id, id) then
						Alliances.addEmbargo(sim, p.id, id, false)
					end
				else
					local rel = Alliances.relation(sim, p.id, id)
					if
						rel <= Alliances.HOSTILE
						and not Alliances.hasEmbargoAgainst(sim, p.id, id)
						and not sameTeam
					then
						Alliances.addEmbargo(sim, p.id, id, false)
					elseif
						rel >= Alliances.NEUTRAL
						and Alliances.hasEmbargoAgainst(sim, p.id, id)
						and not hard
					then
						-- :351-357 -- Hard and above never soften at merely
						-- neutral; they hold the embargo until Friendly.
						Alliances.stopEmbargo(sim, p.id, id)
					elseif
						rel >= Alliances.FRIENDLY
						and Alliances.hasEmbargoAgainst(sim, p.id, id)
					then
						Alliances.stopEmbargo(sim, p.id, id)
					end
				end
			end
		end
	end
end

-- ================================================= nation AI: strategies ==
-- The three entries of upstream's strategy ladder that need this system.
-- Each takes Sim's own `commit` closure so troop sizing, the send cap, the
-- weak-attack refusal and the land-or-boat cascade stay in one place.

-- AiAttackBehavior.assistAllies (:485-511). An ally who has MARKED somebody
-- is asking for help; answering costs a little relation with them, because
-- you spent your army and they did not.
function Alliances.assistAllies(sim: any, p: any, commit: any): boolean
	if disabled() then
		return false
	end
	for _, allyId in Alliances.alliesOf(sim, p.id) do
		local marks = Alliances.targetsOf(sim, allyId)
		if #marks > 0 then
			if Alliances.relation(sim, p.id, allyId) < Alliances.FRIENDLY then
				continue
			end
			for _, targetId in marks do
				if targetId ~= p.id and not Alliances.isFriendly(sim, p.id, targetId) then
					local t = sim.players[targetId]
					local tile = t ~= nil and next(t.border) or nil
					if tile ~= nil and commit(tile, false) then
						Alliances.updateRelation(sim, p.id, allyId, ASSIST_RELATION)
						return true
					end
				end
			end
		end
	end
	return false
end

-- AiAttackBehavior.findTraitor (:513-526). `ranked` is Sim's ascending-troops
-- list, so the first match is the weakest traitor on our border.
function Alliances.findTraitor(sim: any, p: any, ranked: { any }, ffa: boolean): any
	if disabled() then
		return nil
	end
	for _, entry in ranked do
		local other = sim.players[entry.id]
		if
			other ~= nil
			and Alliances.isTraitor(sim, entry.id)
			and (not ffa or other.troops < p.troops * 1.2)
		then
			return entry
		end
	end
	return nil
end

-- AiAttackBehavior.maybeBetrayAndAttack (:530-552). Walks our bordering
-- FRIENDS, and the first one worth stabbing is stabbed and then attacked with
-- force -- bypassing the hesitation roll, because the decision was already
-- made.
function Alliances.betrayAndAttack(
	sim: any,
	p: any,
	tileByRival: { [number]: number },
	rivalCount: number,
	commit: any
): boolean
	if disabled() then
		return false
	end
	local friends = {}
	for id in tileByRival do
		if Alliances.allied(sim, p.id, id) then
			table.insert(friends, id)
		end
	end
	table.sort(friends)
	for _, id in friends do
		if Alliances.maybeBetray(sim, p, id, rivalCount) then
			local tile = tileByRival[id]
			if tile ~= nil then
				return commit(tile, true)
			end
		end
	end
	return false
end

-- AiAttackBehavior.getNeighborTraitorToAttack (:738-748), the TRIBE path.
-- Note it does NOT exclude allies: TribeExecution.maybeAttack (:100-113)
-- breaks the alliance first and attacks anyway, at 1 in 6 instead of 1 in 3.
function Alliances.neighborTraitor(sim: any, p: any, rivalIds: { number }): number?
	if disabled() then
		return nil
	end
	local traitors = {}
	for _, id in rivalIds do
		local o = sim.players[id]
		if o ~= nil and o.alive and Alliances.isTraitor(sim, id) then
			table.insert(traitors, id)
		end
	end
	if #traitors == 0 then
		return nil
	end
	table.sort(traitors)
	return traitors[sim.rng:NextInteger(1, #traitors)]
end

-- ============================================================== intents ==
-- The wire. Every diplomacy intent arrives on the existing Intent
-- RemoteEvent with `tile = 0` (which passes ConquestServer's range check
-- unchanged, exactly as the existing "cancel" intent does) and the target in
-- `id`. Returns ok plus a reason code, in the same shape Sim.launchAttack
-- uses, so the server can answer a refusal with a sentence.

local INTENT_KINDS = {
	ally = true,
	allyno = true,
	unally = true,
	renew = true,
	embargo = true,
	embargoall = true,
	target = true,
}

Alliances.INTENT_KINDS = INTENT_KINDS

function Alliances.handleIntent(sim: any, p: any, payload: any): (boolean, string?)
	local kind = payload.t
	if INTENT_KINDS[kind] == nil then
		return false, "unknown"
	end
	if disabled() then
		return false, "nodiplomacy"
	end
	if sim.phase ~= "playing" then
		return false, "notplaying"
	end

	if kind == "embargoall" then
		if not Alliances.embargoAll(sim, p.id, payload.stop == true) then
			return false, "cooldown"
		end
		return true
	end

	local id = payload.id
	if typeof(id) ~= "number" or id ~= id then
		return false, "noplayer"
	end
	id = math.floor(id)
	local other = sim.players[id]
	if other == nil or id == p.id then
		return false, "noplayer"
	end
	if not other.alive then
		return false, "dead"
	end

	if kind == "ally" then
		-- One button for both halves. Asking somebody who has already asked
		-- YOU is how you accept (PlayerImpl.ts:740-746 and
		-- AllianceRequestExecution.ts:37-57), so the client needs no separate
		-- accept intent and cannot get the two out of order.
		if not Alliances.canSendRequest(sim, p.id, id) then
			if Alliances.isFriendly(sim, p.id, id) then
				return false, "alreadyallied"
			end
			return false, "allycooldown"
		end
		Alliances.sendRequest(sim, p.id, id)
		return true
	elseif kind == "allyno" then
		if not Alliances.rejectFrom(sim, id, p.id) then
			return false, "norequest"
		end
		return true
	elseif kind == "unally" then
		if not Alliances.breakAlliance(sim, p.id, id) then
			return false, "notallied"
		end
		return true
	elseif kind == "renew" then
		if Alliances.allianceWith(sim, p.id, id) == nil then
			return false, "notallied"
		end
		Alliances.requestExtension(sim, p.id, id)
		return true
	elseif kind == "embargo" then
		if payload.stop == true then
			Alliances.stopEmbargo(sim, p.id, id)
		else
			Alliances.addEmbargo(sim, p.id, id, false)
		end
		return true
	elseif kind == "target" then
		if not Alliances.target(sim, p.id, id) then
			return false, "targetcooldown"
		end
		return true
	end
	return false, "unknown"
end

-- ============================================================= snapshot ==
-- What one player is told. Rides on the existing per-client `fronts` message
-- rather than earning a channel of its own: it is the same 5 Hz beat, the
-- same recipient, and the same reason -- this is private state.
--
-- Traitors are the one PUBLIC field here. Everybody can see who betrayed
-- whom, which is the entire point of the mark.

function Alliances.snapshotFor(sim: any, id: number): any
	local s = state(sim)
	local allies, expiring = {}, {}
	local row = s.allianceOf[id]
	if row ~= nil then
		for other, al in row do
			table.insert(allies, other)
			if Alliances.inExtensionWindow(sim, al) then
				table.insert(expiring, {
					id = other,
					left = math.max(0, al.expiresAt - sim.tick),
					mine = Alliances.agreedToExtend(al, id),
					theirs = Alliances.agreedToExtend(al, other),
				})
			end
		end
		table.sort(allies)
	end

	local incoming, outgoing = {}, {}
	for _, r in s.requests do
		if r.to == id then
			table.insert(incoming, r.from)
		elseif r.from == id then
			table.insert(outgoing, r.to)
		end
	end

	local embargoes = {}
	local mine = s.embargo[id]
	if mine ~= nil then
		for other in mine do
			table.insert(embargoes, other)
		end
		table.sort(embargoes)
	end

	local traitors = {}
	for other in s.traitorAt do
		if Alliances.isTraitor(sim, other) then
			table.insert(traitors, other)
		end
	end
	table.sort(traitors)

	return {
		allies = allies,
		expiring = expiring,
		inreq = incoming,
		outreq = outgoing,
		embargo = embargoes,
		traitors = traitors,
		targets = Alliances.targetsOf(sim, id),
	}
end

return Alliances
