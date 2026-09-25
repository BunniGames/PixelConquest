--!strict
-- Conquest.Artillery -- the battery's firing loop (server).
--
-- NOT UPSTREAM (owner, 2026-09-21: "Artillery Building. Has a circular zone
-- it shoots a barrage at every 5-10 seconds. Only shoots at enemies. Does a
-- bit of damage to the army count of the enemy and can destroy enemy
-- buildings over time."). OpenFront has no such unit; the nearest thing it
-- has is the warship's shell, and this is that shell fired from a building at
-- the ground instead of at a boat.
--
-- ONE NUMBER PER GUN, NOTHING PER TICK. A finished battery keeps
-- `ext.nextShotTick`; on that tick it picks a target inside
-- Config.ARTILLERY_RANGE and pushes a shell record onto sim.artilleryShells.
-- The shell is RESOLVED HERE AT ITS t1 -- whoever owns the aimpoint THEN
-- loses troops, whatever enemy building stands under it THEN takes damage --
-- so the burst the client draws at t1 is the hit the sim applied, not a
-- picture of one applied a second and a half earlier.
--
-- TARGETING, in order: the nearest enemy building in range (that is what a
-- gun is for; a site under construction counts, it is the cheapest one to
-- stop), else a random enemy-held tile in the disc. The disc is SAMPLED,
-- never walked: SAMPLES tiles drawn uniformly over it off sim.rng, first
-- enemy one wins. A 45-tile disc is 6,300 tiles and there can be sixty guns
-- on the map; reading two dozen bytes per shot is what keeps the whole loop
-- under a tenth of a millisecond a tick (measured: see the report in the
-- 2026-09-21 commit).
--
-- WHO IS AN ENEMY: not me, not nobody, not friendly -- same team OR allied,
-- Alliances.isFriendly, the test Sim.friendly composes. Empty land is never
-- shot at; a shell on nobody's ground is a shell that did nothing.
--
-- THE CLIENT hears about it on the "missiles" channel through Nukes.emit:
-- one "sh" at launch (src, dst, t0, t1 -- enough to fly the lob against the
-- shared tick clock) and one "si" at impact (what it did), the launch/blast
-- shape the warheads already use. "s" was NOT free: it is the SAM's launch.

local Alliances = require(script.Parent.Alliances)
local Config = require(script.Parent.Config)
local Nukes = require(script.Parent.Nukes)
local Units = require(script.Parent.Units)

local Artillery = {}

local W = Config.MAP_W
local H = Config.MAP_H

-- Tiles of the disc one shot reads looking for enemy ground before giving up
-- on this tick. Twenty-four uniform samples find a sliver that is 5% of the
-- disc 71% of the time and anything bigger near-certainly.
local SAMPLES = 24
-- Ticks before a gun with nothing in range looks again. Two seconds: a front
-- moves tiles per tick, and a gun that waited a whole cooldown to notice an
-- enemy arrive would sit out the first push.
local RETRY_TICKS = 20

-- Scratch for Units.nearby, module-level so a shot allocates nothing.
local unitScratch: { any } = {}
local d2Scratch: { number } = {}

-- Units.nearby's filter has no sim argument, so the shot's context sits here
-- for the length of the query -- the zero-allocation shape Nukes' blast scan
-- uses for the same reason.
local curSim: any = nil
local curMe = 0

local function hostile(sim: any, me: number, other: number): boolean
	if other == 0 or other == me then
		return false
	end
	if sim.players[other] == nil then
		return false
	end
	return not Alliances.isFriendly(sim, me, other)
end

local function hostileUnit(u: any, _d2: number): boolean
	return hostile(curSim, curMe, u.ownerId)
end

function Artillery.init(sim: any)
	sim.artilleryShells = sim.artilleryShells or {} :: { any }
	sim.artilleryShellSeq = sim.artilleryShellSeq or 0
	-- Round totals, for the harness and for whoever balances this next:
	-- shells fired, troops killed, building hits, buildings razed.
	sim.artilleryFired = sim.artilleryFired or 0
	sim.artilleryKilled = sim.artilleryKilled or 0
	sim.artilleryHits = sim.artilleryHits or 0
	sim.artilleryRazed = sim.artilleryRazed or 0
end

-- The aimpoint for one shot, or nil when nothing in range is an enemy.
-- Returns the tile and, when it was a building, the unit.
local function pickTarget(sim: any, u: any, range: number): (number?, any?)
	local me = u.ownerId
	curSim, curMe = sim, me
	local n = Units.nearby(sim, u.tile, range, Units.STRUCTURE_TYPES, unitScratch, d2Scratch, hostileUnit, true)
	curSim = nil
	local best: any = nil
	local bestD = math.huge
	for i = 1, n do
		local s = unitScratch[i]
		unitScratch[i] = nil
		if d2Scratch[i] < bestD then
			bestD = d2Scratch[i]
			best = s
		end
	end
	if best ~= nil then
		return best.tile, best
	end
	-- Uniform over the DISC: r = R * sqrt(u). Uniform in r would crowd the
	-- middle, which is the gun's own ground and never a target.
	local rng = sim.rng
	local owner = sim.map.owner
	local ux = u.tile % W
	local uy = (u.tile - ux) / W
	for _ = 1, SAMPLES do
		local r = range * math.sqrt(rng:NextNumber())
		local a = rng:NextNumber() * 6.283185307179586
		local x = math.floor(ux + r * math.cos(a) + 0.5)
		local y = math.floor(uy + r * math.sin(a) + 0.5)
		if x >= 0 and y >= 0 and x < W and y < H then
			local t = y * W + x
			if hostile(sim, me, buffer.readu8(owner, t)) then
				return t, nil
			end
		end
	end
	return nil, nil
end

local function fire(sim: any, u: any, dst: number, target: any?)
	local src = u.tile
	local sx = src % W
	local dx = dst % W - sx
	local dy = (dst - dst % W) / W - (src - sx) / W
	local speed = Config.ARTILLERY_SHELL_SPEED or 3
	local flight = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) / speed))
	sim.artilleryShellSeq += 1
	local id = sim.artilleryShellSeq
	local t0 = sim.tick
	local shell = {
		id = id,
		src = src,
		dst = dst,
		ownerId = u.ownerId,
		targetUnitId = target and target.id or nil,
		t0 = t0,
		t1 = t0 + flight,
	}
	local list = sim.artilleryShells
	list[#list + 1] = shell
	sim.artilleryFired += 1
	Nukes.emit(sim, { e = "sh", id = id, src = src, dst = dst, t0 = t0, t1 = shell.t1, owner = u.ownerId })
end

-- Impact. Read at t1, not at launch: the ground may have changed hands and
-- the building may already be rubble, and a shell that hurt whoever WAS there
-- would be the one desync between the burst on screen and the number on the
-- army readout.
local function land(sim: any, sh: any)
	local dst = sh.dst
	local me = sh.ownerId
	local kill, hit, razed = 0, 0, 0
	local victimId = buffer.readu8(sim.map.owner, dst)
	if hostile(sim, me, victimId) then
		local victim = sim.players[victimId]
		local troops = victim.troops
		if troops > 0 then
			-- A slice of the standing army, floored so a barrage on a tiny
			-- army still costs something and capped so a huge one is not
			-- shelled to nothing by a single gun. Never below zero.
			kill = math.floor(troops * (Config.ARTILLERY_TROOP_FRACTION or 0.01))
			kill = math.clamp(kill, Config.ARTILLERY_TROOP_MIN or 300, Config.ARTILLERY_TROOP_MAX or 4000)
			if kill > troops then
				kill = troops
			end
			victim.troops = troops - kill
			-- Blast credit, the way Nukes' detonate sets it: an empire this
			-- finishes has a conqueror for checkElimination to pay.
			victim.lastHitBy = me
			sim.artilleryKilled += kill
		end
	end
	-- Any enemy building under the shell, sites included. The targeted unit is
	-- at dst, so it is inside this disc whenever it is still standing.
	curSim, curMe = sim, me
	local n = Units.nearby(sim, dst, Config.ARTILLERY_SPLASH or 1.5, Units.STRUCTURE_TYPES, unitScratch, nil, hostileUnit, true)
	curSim = nil
	local dmg = Config.ARTILLERY_BUILDING_DAMAGE or 200
	for i = 1, n do
		local s = unitScratch[i]
		unitScratch[i] = nil
		if s.active then
			hit = 1
			sim.artilleryHits += 1
			if Units.damageStructure(sim, s, dmg, me) then
				razed = 1
				sim.artilleryRazed += 1
			end
		end
	end
	Nukes.emit(sim, { e = "si", id = sh.id, tile = dst, kill = kill, hit = hit, razed = razed, owner = me })
end

-- AN AI GUN FIRES SLOWER (owner, 2026-09-21: "make AI ... artillery strike
-- relatively rarely"): its gap between barrages is a person's times
-- Config.BOT_ARTILLERY_COOLDOWN_MULT. isBot is the test, the nuke rule's -- a
-- faux empire is AI and slows with the rest; an empire a person abandoned
-- turns isBot and its guns slow from then on.
local function gap(sim: any, u: any, rng: Random, cdMin: number, cdMax: number): number
	local p = sim.players[u.ownerId]
	local mult = (p ~= nil and p.isBot) and (Config.BOT_ARTILLERY_COOLDOWN_MULT or 1) or 1
	-- ...and a FAST_RELOAD holder's fires faster (2026-09-25; Units.cooldown).
	return Units.cooldown(sim, u, math.floor(rng:NextInteger(cdMin, cdMax) * mult))
end

-- THE REARM BAR (owner, 2026-09-22: "i want artillery to have a rearm bar as
-- well"). One event per barrage: `reloadUntil` / `reloadTotal` are what
-- Units.reloadLeft / reloadTotal read into the `rl` / `rt` of the structure
-- event the client draws Structures.setReload from -- the airfield's bar, on a
-- clock whose length is rolled per shot. Nothing per tick, same as the gun.
local function reload(sim: any, u: any, ext: any, tick: number, g: number)
	ext.nextShotTick = tick + g
	ext.reloadUntil = tick + g
	ext.reloadTotal = g
	Units.emit(sim, u, true)
end

function Artillery.step(sim: any)
	local list = sim.artilleryShells
	if list == nil then
		return
	end
	local tick = sim.tick
	local guns = Units.ofType(sim, Units.ARTILLERY)
	if guns ~= nil and #guns > 0 then
		local range = Config.ARTILLERY_RANGE or 45
		local rng = sim.rng
		local cdMin = Config.ARTILLERY_COOLDOWN_MIN or 40
		local cdMax = Config.ARTILLERY_COOLDOWN_MAX or 70
		for _, u in guns do
			if u.active and not u.underConstruction then
				local ext = u.ext
				if ext == nil then
					ext = {}
					u.ext = ext
				end
				local due = ext.nextShotTick
				if due == nil then
					-- A gun that just finished waits one cooldown, like one
					-- that just fired: the crew has to be told what to shoot.
					reload(sim, u, ext, tick, gap(sim, u, rng, cdMin, cdMax))
				elseif tick >= due then
					local dst, target = pickTarget(sim, u, range)
					if dst == nil then
						ext.nextShotTick = tick + RETRY_TICKS
						-- Loaded and waiting: the bar comes down (2026-09-22),
						-- once, and the retries that follow draw nothing.
						if ext.reloadUntil ~= nil then
							ext.reloadUntil = nil
							ext.reloadTotal = nil
							Units.emit(sim, u, true)
						end
					else
						fire(sim, u, dst, target)
						reload(sim, u, ext, tick, gap(sim, u, rng, cdMin, cdMax))
					end
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
		local sh = list[i]
		if tick >= sh.t1 then
			land(sim, sh)
			sh.done = true
			landed = true
		end
	end
	if landed then
		-- Compact, preserving order, the way Nukes compacts its executions.
		local live = {}
		for _, sh in list do
			if not sh.done then
				live[#live + 1] = sh
			end
		end
		sim.artilleryShells = live
	end
end

-- Every shell in the air, as launch events, for a joining client. Shells
-- live under two seconds, so nothing sends this yet; it is here so that the
-- day the joiner snapshot wants it, it is one line in ConquestServer.
function Artillery.snapshot(sim: any): { any }
	local out = {}
	local list = sim.artilleryShells
	if list ~= nil then
		for _, sh in list do
			out[#out + 1] = { e = "sh", id = sh.id, src = sh.src, dst = sh.dst, t0 = sh.t0, t1 = sh.t1, owner = sh.ownerId }
		end
	end
	return out
end

return Artillery
