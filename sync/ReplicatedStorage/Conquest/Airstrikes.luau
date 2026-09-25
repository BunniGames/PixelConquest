--!strict
-- Conquest :: Airstrikes
-- NOT UPSTREAM (owner, 2026-09-21): "Air Field. When you click it again, it
-- allows you to bomb an area you'd like in its larger radius with a longer
-- cooldown time. Does damage to enemies and their buildings."
--
-- THE SHAPE OF IT. An airfield (Units.AIRFIELD) is a building the owner TAPS,
-- then taps a tile inside Config.AIRFIELD_RANGE of it; a bomber flies a
-- straight line there at Config.AIRSTRIKE_SPEED tiles a tick and drops on a
-- disc of Config.AIRSTRIKE_RADIUS. Every ENEMY-owned tile under the disc is a
-- share of the blow: that empire loses AIRSTRIKE_KILL_PER_TILE troops per tile
-- hit, capped at AIRSTRIKE_KILL_FRACTION_MAX of its standing army, and its
-- attacks in the field and troops at sea bleed the same fraction (the rule
-- Nukes.detonate applies, so an army parked in transit does not dodge a
-- bomb). Every enemy building inside the disc takes
-- AIRSTRIKE_BUILDING_DAMAGE off Units.damageStructure. That is the whole of
-- it: NO LAND CHANGES HANDS, NO FALLOUT, and the shooter's own ground and an
-- ally's are never touched -- an airstrike is a raid, not a nuke.
--
-- WHY IT IS NOT A NUKE EXECUTION. A warhead is a Unit with an arc, a SAM can
-- kill it, and its blast is a crater the client regenerates from a seed. A
-- sortie is none of those: nothing intercepts a plane (v1 -- see the report),
-- the flight is a straight line the client draws from four numbers, and the
-- disc is a fixed radius rather than a ragged crater. So it is a plain record
-- in `sim.airstrikes` -- { id, src, dst, ownerId, t0, t1 } -- stepped here,
-- and the two events it raises ride the existing "missiles" channel through
-- Nukes.emit so ConquestServer and Missiles.onEvents learn nothing new:
--   { e = "pl", id, src, dst, t0, t1, owner }   the bomber leaves the field
--   { e = "pb", id, tile, r, kill, hit, owner }   the bombs land
--
-- THE FIELD REARMS LIKE A SILO: Units.launch pushes the launch tick onto the
-- airfield's missileTimers, Units.inCooldown reads it (level is 1, an airfield
-- never upgrades, so one entry is "spent"), Units.reloadLeft draws the bar over
-- the chip off Config.AIRSTRIKE_COOLDOWN, and `step` below pops the timer when
-- the cooldown has run -- the exact pattern Nukes.stepSilos follows.

local Config = require(script.Parent.Config)
local Units = require(script.Parent.Units)
local Nukes = require(script.Parent.Nukes)
local Alliances = require(script.Parent.Alliances)

local W = Config.MAP_W
local H = Config.MAP_H
local NUM_TILES = Config.NUM_TILES

local Airstrikes = {}

-- How far from the chip a tap still names it, in tiles. 1.5 Euclidean takes
-- in all eight neighbours (the diagonal is sqrt 2) and nothing further, so a
-- press that lands a pixel off a thirteen-tile chip resolves and a press on
-- the next field over does not.
local PICK_RADIUS = 1.5

-- Sim.sameTeam + Alliances.allied, inlined the way Gunboats inlines it: Sim
-- requires this module, so this module cannot require Sim.
local function friendly(sim: any, a: number, b: number): boolean
	if a == b then
		return true
	end
	if Alliances.allied(sim, a, b) then
		return true
	end
	if (sim.teamCount or 0) <= 0 then
		return false
	end
	local ta = sim.teamOf[a]
	return ta ~= nil and ta == sim.teamOf[b]
end

local function dist(a: number, b: number): number
	local ax = a % W
	local bx = b % W
	local dx = ax - bx
	local dy = (a - ax) / W - (b - bx) / W
	return math.sqrt(dx * dx + dy * dy)
end

function Airstrikes.init(sim: any)
	sim.airstrikes = sim.airstrikes or {} :: { any }
	sim.airstrikeSeq = sim.airstrikeSeq or 0
end

-- The finished airfield of `playerId` a press at `tile` names, or nil. Sites
-- are looked up too so a tap on one can be told apart from a tap on nothing --
-- the caller reads `underConstruction` and answers "notready" rather than
-- "notyours".
local function airfieldAt(sim: any, playerId: number, tile: number): any
	local u = Units.closest(sim, tile, PICK_RADIUS, Units.AIRFIELD, playerId, true)
	return u
end

Airstrikes.airfieldAt = airfieldAt

-- THE ORDER. A person's route is ConquestServer's "airstrike" intent; an AI's
-- is Sim's botAirstrike (2026-09-21, rare by Config.BOT_AIRSTRIKE_CHANCE), and
-- both come through here so a bot can do nothing a person cannot. Refusals are
-- the words the client's reason table prints:
--   notyours   no finished airfield of yours under the press
--   notready   the one under it is still going up
--   cooldown   it flew inside the last AIRSTRIKE_COOLDOWN ticks
--   range      the target is further than AIRFIELD_RANGE from the field
--   gold       AIRSTRIKE_COST is more than the treasury (0 today)
function Airstrikes.order(sim: any, playerId: number, fromTile: number, dstTile: number): (boolean, string?)
	local p = sim.players[playerId]
	if p == nil or not p.alive then
		return false, "dead"
	end
	-- The intent handler already types both tiles; this is for every other
	-- caller (a cheat, a harness) so a nil never reaches the compare below.
	if typeof(fromTile) ~= "number" or typeof(dstTile) ~= "number" then
		return false, "terrain"
	end
	if fromTile < 0 or fromTile >= NUM_TILES or dstTile < 0 or dstTile >= NUM_TILES then
		return false, "terrain"
	end
	local u = airfieldAt(sim, playerId, fromTile)
	if u == nil then
		return false, "notyours"
	end
	if u.underConstruction then
		return false, "notready"
	end
	if Units.inCooldown(u) then
		return false, "cooldown"
	end
	local d = dist(u.tile, dstTile)
	if d > (Config.AIRFIELD_RANGE or 120) then
		return false, "range"
	end
	local cost = Config.AIRSTRIKE_COST or 0
	if p.gold < cost then
		return false, "gold"
	end
	p.gold -= cost

	-- Committed. The launch tick goes onto the field (and out to every client
	-- as the chip's reload bar, through Units.launch's own emit) before the
	-- sortie is queued, so a field is never seen ready with a plane in the air.
	Units.launch(sim, u)
	-- A BOUGHT SKIP THAT FOUND NOTHING REARMING (ConquestServer.skipRearm,
	-- 2026-09-22) waits on the empire for its next sortie and rearms it at
	-- once: launch, then pop, so the field is ready again on the tick it flew.
	-- Only a purchase sets the counter, so no bot ever has one.
	if (p.rearmSkips or 0) > 0 then
		p.rearmSkips -= 1
		Units.reload(sim, u)
	end
	sim.airstrikeSeq += 1
	local t0 = sim.tick
	local t1 = t0 + math.max(1, math.ceil(d / (Config.AIRSTRIKE_SPEED or 4)))
	local sortie = {
		id = sim.airstrikeSeq,
		src = u.tile,
		dst = dstTile,
		ownerId = playerId,
		t0 = t0,
		t1 = t1,
		active = true,
	}
	local list = sim.airstrikes
	list[#list + 1] = sortie
	Nukes.emit(sim, { e = "pl", id = sortie.id, src = u.tile, dst = dstTile, t0 = t0, t1 = t1, owner = playerId })
	return true
end

-- ================================================================ impact ==

local unitScratch: { any } = {}

-- Whose ground is under the disc, and how much of it. A plain bounded walk of
-- the (2R+1)^2 box -- 441 cells at R=10, once per sortie, not per tick -- so
-- it does not borrow Nukes.blastTiles, whose flood fill, coin flips and seed
-- exist to make a crater ragged; a bomb disc is a disc.
local function detonate(sim: any, s: any)
	local dst = s.dst
	local R = Config.AIRSTRIKE_RADIUS or 10
	local r2 = R * R
	local owner = sim.map.owner
	local cx = dst % W
	local cy = (dst - cx) / W
	local hits: { [number]: number } = {}
	local x0, x1 = math.max(0, cx - R), math.min(W - 1, cx + R)
	local y0, y1 = math.max(0, cy - R), math.min(H - 1, cy + R)
	for y = y0, y1 do
		local dy = y - cy
		local dy2 = dy * dy
		local base = y * W
		for x = x0, x1 do
			local dx = x - cx
			if dx * dx + dy2 <= r2 then
				local o = buffer.readu8(owner, base + x)
				if o ~= 0 and o ~= s.ownerId then
					hits[o] = (hits[o] or 0) + 1
				end
			end
		end
	end

	-- The population. Per empire: tiles hit times the per-tile kill, capped at
	-- a fraction of the standing army -- whichever is SMALLER -- and never
	-- more than the army itself. The same fraction comes off every attack that
	-- empire has in the field and every transport it has at sea, which is the
	-- rule that stops "my army is out marching, so the bomb found nobody home".
	local perTile = Config.AIRSTRIKE_KILL_PER_TILE or 40
	local fracMax = Config.AIRSTRIKE_KILL_FRACTION_MAX or 0.06
	local killed = 0
	for pid, n in hits do
		local p = sim.players[pid]
		if p ~= nil and p.alive and not friendly(sim, s.ownerId, pid) then
			local before = p.troops
			local kill = math.floor(math.min(before, n * perTile, before * fracMax))
			if kill > 0 then
				p.troops = before - kill
				-- BLAST CREDIT, the nuke's rule: an empire this empties has no
				-- conqueror, and checkElimination pays whoever this names.
				p.lastHitBy = s.ownerId
				killed += kill
				local f = kill / before
				if sim.attacks ~= nil then
					for _, atk in sim.attacks do
						if atk.active and atk.attackerId == pid then
							atk.troops = math.max(0, atk.troops - math.floor(atk.troops * f))
						end
					end
				end
				if sim.transportBoats ~= nil then
					for _, b in sim.transportBoats do
						if b.active and b.ownerId == pid then
							b.troops = math.max(0, b.troops - math.floor(b.troops * f))
						end
					end
				end
			end
		end
	end

	-- The hardware. Every enemy building inside the disc, sites included (a
	-- half-built city is as bombable as a finished one, the rule
	-- Units.damageStructure states), takes one hit; the shooter's own and an
	-- ally's are skipped, never damaged and never credited.
	local hit = 0
	local n = Units.nearby(sim, dst, R, Units.STRUCTURE_TYPES, unitScratch, nil, nil, true)
	local dmg = Config.AIRSTRIKE_BUILDING_DAMAGE or 600
	for i = 1, n do
		local u = unitScratch[i]
		unitScratch[i] = nil
		if u.active and u.ownerId ~= 0 and u.ownerId ~= s.ownerId and not friendly(sim, s.ownerId, u.ownerId) then
			Units.damageStructure(sim, u, dmg, s.ownerId)
			hit += 1
		end
	end

	Nukes.emit(sim, { e = "pb", id = s.id, tile = dst, r = R, kill = killed, hit = hit, owner = s.ownerId })
end

-- ================================================================== step ==

-- Called from Sim.step right before Nukes.step: the fields rearm, and every
-- sortie whose arrival tick has come drops its load.
function Airstrikes.step(sim: any)
	local list = sim.airstrikes
	if list == nil then
		return
	end
	local tick = sim.tick

	-- Rearm, the stepSilos pattern: the front timer is the launch tick, and
	-- popping it is what Units.inCooldown reads as "ready" again. A handful of
	-- fields a round, so the type list is walked whole.
	local cd = Config.AIRSTRIKE_COOLDOWN or 600
	local fields = Units.ofType(sim, Units.AIRFIELD)
	if fields ~= nil then
		for _, u in fields do
			if u.active and not u.underConstruction then
				local front = u.missileTimers[1]
				if front ~= nil and cd - (tick - front) <= 0 then
					Units.reload(sim, u)
				end
			end
		end
	end

	local n = #list
	if n == 0 then
		return
	end
	local landed = false
	for i = 1, n do
		local s = list[i]
		if s.active and tick >= s.t1 then
			detonate(sim, s)
			s.active = false
			landed = true
		end
	end
	if landed then
		-- Compact in order, the way Sim compacts its attack list.
		local live = {}
		for _, s in list do
			if s.active then
				live[#live + 1] = s
			end
		end
		sim.airstrikes = live
	end
end

-- Sorties in the air, for a joiner. Same records the launch event carried.
function Airstrikes.snapshot(sim: any): { any }
	local out = {}
	if sim.airstrikes ~= nil then
		for _, s in sim.airstrikes do
			if s.active then
				out[#out + 1] = { e = "pl", id = s.id, src = s.src, dst = s.dst, t0 = s.t0, t1 = s.t1, owner = s.ownerId }
			end
		end
	end
	return out
end

return Airstrikes
