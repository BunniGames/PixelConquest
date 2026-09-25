--!strict
-- Conquest :: Railgun
-- NOT UPSTREAM (owner, 2026-09-24): "Railgun (its an artillery thats
-- controllable like the airbase, with no range limit) ... late game items.
-- balance it accordingly".
--
-- THE SHAPE OF IT. A railgun (Units.RAILGUN) is a building the owner TAPS,
-- then taps ANY tile on the map -- there is no range test anywhere. A slug
-- crosses in a straight line at Config.RAILGUN_SPEED tiles a tick and hits a
-- disc of Config.RAILGUN_RADIUS. It is the airfield's sortie with the numbers
-- turned toward buildings: a small disc and a small army bite, but every enemy
-- building under it takes RAILGUN_BUILDING_DAMAGE (1000 -- a whole health pool,
-- so a level off a city or a tower and a post, battery or airfield razed).
-- NO LAND CHANGES HANDS, NO FALLOUT, and the shooter's own and an ally's
-- ground and buildings are never touched. Nothing intercepts a slug.
--
-- WHY ITS OWN MODULE AND NOT A BRANCH OF Airstrikes: the airfield's order is
-- gated on the Air Strike pass, has a paid rearm-skip hung off its refusal and
-- a lesson ring hung off its first build; the railgun has none of those, and
-- sharing the order would have meant threading "unless it is a railgun"
-- through each. The record, the rearm and the impact are the airfield's
-- pattern, kept in step by hand:
--   { e = "rf", id, src, dst, t0, t1, owner }          the slug leaves the gun
--   { e = "ri", id, src, tile, r, kill, hit, razed, owner }  it lands
-- Both ride the "missiles" channel through Nukes.emit, like the bomber's.
--
-- THE GUN REARMS LIKE A SILO: Units.launch pushes the launch tick onto
-- missileTimers, Units.inCooldown reads it (level 1, never upgraded),
-- Units.reloadLeft draws the bar off Config.RAILGUN_COOLDOWN, and `step` below
-- pops the timer when the cooldown has run.

local Config = require(script.Parent.Config)
local Units = require(script.Parent.Units)
local Nukes = require(script.Parent.Nukes)
local Alliances = require(script.Parent.Alliances)

local W = Config.MAP_W
local H = Config.MAP_H
local NUM_TILES = Config.NUM_TILES

local Railgun = {}

-- How far from the chip a tap still names it, in tiles -- Airstrikes' number.
local PICK_RADIUS = 1.5

-- Sim.sameTeam + Alliances.allied, inlined the way Airstrikes inlines it: Sim
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

function Railgun.init(sim: any)
	sim.railShots = sim.railShots or {} :: { any }
	sim.railShotSeq = sim.railShotSeq or 0
end

-- The railgun of `playerId` a press at `tile` names, or nil. Sites included,
-- so a tap on one answers "notready" rather than "notyours".
function Railgun.gunAt(sim: any, playerId: number, tile: number): any
	return Units.closest(sim, tile, PICK_RADIUS, Units.RAILGUN, playerId, true)
end

-- THE ORDER. ConquestServer's "railgun" intent is the only caller; bots never
-- own one. Refusals are words the client's reason table prints:
--   notyours   no railgun of yours under the press
--   notready   the one under it is still going up
--   cooldown   it fired inside the last RAILGUN_COOLDOWN ticks
function Railgun.order(sim: any, playerId: number, fromTile: number, dstTile: number): (boolean, string?)
	local p = sim.players[playerId]
	if p == nil or not p.alive then
		return false, "dead"
	end
	if typeof(fromTile) ~= "number" or typeof(dstTile) ~= "number" then
		return false, "terrain"
	end
	if fromTile < 0 or fromTile >= NUM_TILES or dstTile < 0 or dstTile >= NUM_TILES then
		return false, "terrain"
	end
	local u = Railgun.gunAt(sim, playerId, fromTile)
	if u == nil then
		return false, "notyours"
	end
	if u.underConstruction then
		return false, "notready"
	end
	if Units.inCooldown(u) then
		return false, "cooldown"
	end

	Units.launch(sim, u)
	-- A BANKED SKIP (ConquestServer.skipRearm, 2026-09-25) reloads it at once,
	-- the airfield's launch-then-pop. Only a purchase sets the counter.
	if (p.rearmSkips or 0) > 0 then
		p.rearmSkips -= 1
		Units.reload(sim, u)
	end
	sim.railShotSeq += 1
	local t0 = sim.tick
	local t1 = t0 + math.max(1, math.ceil(dist(u.tile, dstTile) / (Config.RAILGUN_SPEED or 40)))
	local shot = {
		id = sim.railShotSeq,
		src = u.tile,
		dst = dstTile,
		ownerId = playerId,
		t0 = t0,
		t1 = t1,
		active = true,
	}
	local list = sim.railShots
	list[#list + 1] = shot
	Nukes.emit(sim, { e = "rf", id = shot.id, src = u.tile, dst = dstTile, t0 = t0, t1 = t1, owner = playerId })
	return true
end

-- ================================================================ impact ==

local unitScratch: { any } = {}

-- Airstrikes.detonate's walk with the railgun's numbers: whose ground is under
-- the disc, an army bite per empire capped at a fraction of its standing army
-- (bled off its attacks and transports by the same fraction), then one hit on
-- every enemy building inside it.
local function detonate(sim: any, s: any)
	local dst = s.dst
	local R = Config.RAILGUN_RADIUS or 5
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

	local perTile = Config.RAILGUN_KILL_PER_TILE or 150
	local fracMax = Config.RAILGUN_KILL_FRACTION_MAX or 0.04
	local killed = 0
	for pid, n in hits do
		local p = sim.players[pid]
		if p ~= nil and p.alive and not friendly(sim, s.ownerId, pid) then
			local before = p.troops
			local kill = math.floor(math.min(before, n * perTile, before * fracMax))
			if kill > 0 then
				p.troops = before - kill
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

	local hit, razed = 0, 0
	local n = Units.nearby(sim, dst, R, Units.STRUCTURE_TYPES, unitScratch, nil, nil, true)
	local dmg = Config.RAILGUN_BUILDING_DAMAGE or 1000
	for i = 1, n do
		local u = unitScratch[i]
		unitScratch[i] = nil
		if u.active and u.ownerId ~= 0 and u.ownerId ~= s.ownerId and not friendly(sim, s.ownerId, u.ownerId) then
			if Units.damageStructure(sim, u, dmg, s.ownerId) then
				razed = 1
			end
			hit += 1
		end
	end

	Nukes.emit(sim, {
		e = "ri", id = s.id, src = s.src, tile = dst, r = R, kill = killed, hit = hit, razed = razed, owner = s.ownerId,
	})
end

-- ================================================================== step ==

-- Called from Sim.step beside Airstrikes.step: the guns rearm, and every slug
-- whose arrival tick has come lands.
function Railgun.step(sim: any)
	local list = sim.railShots
	if list == nil then
		return
	end
	local tick = sim.tick

	local cd = Config.RAILGUN_COOLDOWN or 250
	local guns = Units.ofType(sim, Units.RAILGUN)
	if guns ~= nil then
		for _, u in guns do
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
		local live = {}
		for _, s in list do
			if s.active then
				live[#live + 1] = s
			end
		end
		sim.railShots = live
	end
end

return Railgun
