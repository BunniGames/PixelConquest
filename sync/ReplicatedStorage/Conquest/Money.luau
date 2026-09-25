--!strict
-- Conquest :: Money  (shared)
--
-- THE BETWEEN-ROUNDS CURRENCY. Gold is the in-match economy and it dies with
-- the round; Money is what a round is WORTH, paid once, kept forever. Nothing
-- spends it yet -- this file is the earn side only, and it is deliberately
-- complete on its own so that whatever spends it later inherits a number that
-- already means something.
--
-- ================================ WHAT IT PAYS FOR, AND WHY EACH ONE ========
--
-- Six inputs, and every one of them is a thing the player already watches on
-- the HUD during the round:
--
--   ROUND PLAYED   a flat floor for picking a homeland and playing it out.
--   SURVIVED       minutes your empire lasted.
--   TERRITORY      your PEAK land, measured in EVEN SHARES of the map.
--   EMPIRES TAKEN  how many empires you finished.
--   FINISHED       where you came on a board of `field`.
--   TOOK THE MAP   taking the map -- the whole surviving bloc, in a team mode.
--
-- Peak land is in SHARES, not tiles and not a percentage: 1.0 means "you held
-- exactly a fair slice of the map at your high-water mark". That is the one
-- normalisation that survives this game's two moving denominators -- the maps
-- range from 195k to 905k playable tiles and the roster scales with the map,
-- so a raw tile count pays four times as much on the US as on Tokyo for the
-- same achievement, and a raw percentage pays a 24-empire round three times a
-- 69-empire one. Sim.collapseTiles was moved onto exactly this footing for
-- exactly this reason; see ConquestSimulate's `collapseshare`.
--
-- ================================ HOW THE NUMBERS WERE CHOSEN ==============
--
-- Not by feel. Every coefficient below is fitted, and the fit is reproducible:
--
--   1. MEASURE. 21 headless matches -- the whole map x mode rotation, at a
--      full server's shape (24 human seats + a land-scaled bot roster) -- with
--      the tracker in this file, so the numbers fitted against are literally
--      the numbers that get paid. 1,301 empires, 504 paid seats. `/simulate`
--      prints the same block per match, which is how this stays re-runnable.
--   2. ANCHOR. One average game pays an average seat MONEY_ANCHOR. That is the
--      single judgement call, and it is the unit everything later gets priced
--      in: a 10,000 item is ten games.
--   3. BUDGET. Split the anchor across the six inputs by share (the per-line
--      percentages below). Second and last judgement call.
--   4. SOLVE. coefficient = share * anchor / measured mean of that input.
--      Nothing is guessed and nothing is round-numbered by hand.
--   5. CHECK THE RATE, NOT THE PAYOUT. The constraint that actually bit: the
--      rotation's matches run 4.9 to 67.5 minutes, so what a round pays says
--      nothing on its own -- the first fitted set, with flat outcome bonuses,
--      paid 17x more per HOUR on the fastest pair than on the slowest, and the
--      board would have been farmed for it. Everything below that is weighted
--      by minutes is weighted that way because of this check, not by taste.
--
-- See MONEYBALANCE.txt for the measured figures behind each constant.

local Config = require(script.Parent.Config)

local Money = {}

-- Returned by the tracker on the overwhelming majority of ticks, when nothing
-- settled. Shared and never written to, so a quiet tick allocates nothing.
local EMPTY: { number } = table.freeze({})

-- ==================================================================== dials ==

-- What one average game pays an average seat. Everything else is derived from
-- it, so this is the number to move if the whole economy is too rich or too
-- thin -- and moving it does NOT change the shape of the payout, only its
-- scale. Pricing anything later in units of this stays honest.
Money.ANCHOR = 1000

-- FITTED -- see the header. Do not hand-edit these without re-running the
-- measurement; they are a solved set and adjusting one in isolation silently
-- moves the anchor.
--
-- THE TWO THAT ARE PER-MINUTE AND LOOK LIKE THEY SHOULD NOT BE. Finishing
-- second and taking the map both pay by the MINUTE, not as a flat pot, and
-- that is the single change that made the economy safe to ship. Matches in
-- this rotation run from five minutes to sixty-eight, and money is banked the
-- moment an empire falls -- so with flat outcome bonuses, the fastest map/mode
-- pair paid SEVENTEEN TIMES what the slowest did per hour of play, and the
-- board would have been farmed for it. Paying the outcome by the minute closes
-- that to 2.8x, with no cap and no special case.
Money.FLOOR = 100 -- flat, per round played through            (10% of the anchor)
Money.PER_MINUTE = 15 -- per minute your empire survived       (30%)
Money.PER_SHARE = 30 -- per even share of the map at your peak (15%)
Money.PER_KILL = 54 -- per empire you finished                 (10%)
Money.PLACE_RATE = 14 -- x placeScore x minutes                (20%)
Money.WIN_RATE = 18 -- x minutes, to the winner or to every survivor of the winning bloc (15%)

-- Rounded to this so payouts read as designed figures rather than as the
-- output of a division. Applied per LINE, and the total is the sum of the
-- rounded lines, so the card always adds up.
local QUANTUM = 5

export type Stats = {
	spawned: boolean,
	-- Whether this empire's RESULT is settled: it died, or the round ended
	-- under it. False for one case only -- somebody who quit a round that is
	-- still running -- and it is what stops that from being an income. See
	-- `award`.
	final: boolean,
	minutes: number,
	shares: number,
	kills: number,
	place: number,
	field: number,
	won: boolean,
}

export type Award = {
	total: number,
	floor: number,
	time: number,
	land: number,
	kills: number,
	place: number,
	win: number,
}

-- ================================================================== payout ==

-- 1 at the top of the board, 0 at the foot, SQUARED. Linear would hand a
-- mid-table finish half the pot, and on a 69-empire board mid-table is where
-- the median player finishes by definition -- so the term would pay for
-- nothing but showing up, which is what FLOOR is already for.
function Money.placeScore(place: number, field: number): number
	if field <= 1 then
		return 1
	end
	local t = 1 - (place - 1) / (field - 1)
	return math.clamp(t, 0, 1) ^ 2
end

local function quantise(n: number): number
	if n <= 0 then
		return 0
	end
	return math.max(QUANTUM, math.floor(n / QUANTUM + 0.5) * QUANTUM)
end

-- The whole payout, and the breakdown the end-of-round card prints. Pure: same
-- stats in, same money out, on the server, in the harness and on the client.
function Money.award(s: Stats): Award
	if not s.spawned then
		-- Never picked a homeland, so there was no empire to pay. This is the
		-- only zero the function can return, and it is what stops an idle
		-- seat from being an income.
		return { total = 0, floor = 0, time = 0, land = 0, kills = 0, place = 0, win = 0 }
	end
	-- WHAT AN UNFINISHED ROUND PAYS, and why it is not everything.
	--
	-- Quitting mid-round has to be worth strictly less per hour than playing
	-- one out, or the board gets farmed by three-minute land grabs. The three
	-- terms below that DO pay a leaver -- minutes, peak land, kills -- can only
	-- grow by staying, so they are safe. The three that do not are the three
	-- that depend on how it ended: the placement pot (leave while leading and
	-- you would bank the whole thing for three minutes' work), the win bonus,
	-- and the flat floor (which is what makes a short cycle attractive at all).
	--
	-- The rule the player is told is one line: leave early and you keep what
	-- you built, not where you finished.
	local final = s.final
	local minutes = math.max(0, s.minutes)
	local a: Award = {
		total = 0,
		floor = final and quantise(Money.FLOOR) or 0,
		time = quantise(Money.PER_MINUTE * minutes),
		land = quantise(Money.PER_SHARE * math.max(0, s.shares)),
		kills = quantise(Money.PER_KILL * math.max(0, s.kills)),
		place = final and quantise(Money.PLACE_RATE * Money.placeScore(s.place, s.field) * minutes) or 0,
		win = (final and s.won) and quantise(Money.WIN_RATE * minutes) or 0,
	}
	a.total = a.floor + a.time + a.land + a.kills + a.place + a.win
	return a
end

-- The card's rows, in the order it prints them, skipping anything that paid
-- nothing. `value` is the achievement, `amount` is what it paid.
function Money.lines(s: Stats, a: Award): { { label: string, value: string, amount: number } }
	local out = {}
	local function add(label: string, value: string, amount: number)
		if amount > 0 then
			table.insert(out, { label = label, value = value, amount = amount })
		end
	end
	add("ROUND PLAYED", "", a.floor)
	add("SURVIVED", string.format("%d:%02d", math.floor(s.minutes), math.floor(s.minutes % 1 * 60)), a.time)
	add("TERRITORY", string.format("%.1f shares", s.shares), a.land)
	add("EMPIRES TAKEN", tostring(s.kills), a.kills)
	add("FINISHED", string.format("%d of %d", s.place, s.field), a.place)
	add("TOOK THE MAP", "", a.win)
	return out
end

-- Thousands separators. Numbers.format's K/M banding is right for troops and
-- gold, which move every tick and are read as magnitudes; a payout is read as
-- an exact figure and "1.24K" is not one.
function Money.comma(n: number): string
	local s = string.format("%.0f", math.abs(n))
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, -4)
	end
	return (n < 0 and "-" or "") .. s .. out
end

-- ================================================================= tracker ==
--
-- Watches a live Sim and produces the Stats above. It reads FOUR fields --
-- `alive`, `spawned`, `tileCount`, `killedBy` -- and writes none, which is the
-- whole design: the sim is a literal port of upstream's balance and an economy
-- feature has no business reaching into it. Nothing here can change the match.
--
-- ConquestServer samples it once per tick beside `sim:step()`; ConquestSimulate
-- samples it at the same cadence, which is what makes the harness's measured
-- payouts the same payouts a player receives rather than a model of them.

local Tracker = {}
Tracker.__index = Tracker

export type Tracker = typeof(setmetatable({} :: any, Tracker))

function Money.track(sim: any): Tracker
	return setmetatable({
		sim = sim,
		peak = {},
		kills = {},
		place = {},
		deathTick = {},
		-- The tick a PERSON took this empire over (adopt); absent for everyone
		-- who held theirs from the first tick. Minutes are counted from here.
		startTick = {},
		dead = {},
		settled = {},
		finished = false,
	}, Tracker)
end

-- Returns the ids whose result is now FINAL -- everyone eliminated on this
-- tick. Their placement cannot move afterwards: nobody still playing can
-- finish below an empire that is already out, so the payout can be banked at
-- the moment of death rather than making a dead player sit out the round to
-- collect it.
function Tracker.sample(self: Tracker): { number }
	local sim = self.sim
	local live = 0
	local justDied: { number } = nil :: any
	for _, id in sim.playerOrder do
		local p = sim.players[id]
		if p and p.spawned then
			if p.tileCount > (self.peak[id] or 0) then
				self.peak[id] = p.tileCount
			end
			if p.alive then
				live += 1
			elseif not self.dead[id] then
				justDied = justDied or {}
				table.insert(justDied, id)
			end
		end
	end
	if not justDied then
		return EMPTY
	end
	for _, id in justDied do
		self.dead[id] = true
		self.deathTick[id] = sim.tick
		-- `live` was counted BEFORE any of this tick's deaths were marked, so
		-- everyone dying together shares one bracket: the number of empires
		-- that outlast them, plus one.
		self.place[id] = live + 1
		local p = sim.players[id]
		local by = p and p.killedBy
		-- The conqueror is credited here rather than in the sim, off the one
		-- field that already records it. Both death paths set it -- absorbed at
		-- the collapse bar, and ground down to the last tile with `lastHitBy`
		-- standing in -- so a kill is a kill however it was delivered.
		if by and by ~= id then
			self.kills[by] = (self.kills[by] or 0) + 1
		end
		self.settled[id] = true
	end
	return justDied
end

-- The round is over. Places everyone still standing by the land they finished
-- on, above every empire that died, and returns them. Idempotent.
function Tracker.finish(self: Tracker): { number }
	if self.finished then
		return EMPTY
	end
	self.finished = true
	-- One last sample first, and its result is carried into the return: a
	-- caller that only paid the survivors would drop anybody eliminated on the
	-- very tick the round ended, which is a common way for one to end.
	local out: { number } = table.clone(Tracker.sample(self))
	local sim = self.sim
	local alive: { number } = {}
	for _, id in sim.playerOrder do
		local p = sim.players[id]
		if p and p.spawned and p.alive then
			table.insert(alive, id)
		end
	end
	table.sort(alive, function(a, b)
		return sim.players[a].tileCount > sim.players[b].tileCount
	end)
	for i, id in alive do
		self.place[id] = i
		self.settled[id] = true
		table.insert(out, id)
	end
	return out
end

-- A PERSON HAS TAKEN OVER THIS EMPIRE (ConquestServer's revive, 2026-09-08).
-- Its result is paid to them on its own terms, so the bot's history is not:
-- the peak restarts at the land they inherited and the kills at zero. Nothing
-- else is touched -- the empire was alive, so it was never dead, placed or
-- settled. The ONE write this tracker makes into its own memory on request.
--
-- AND THE CLOCK RESTARTS (2026-09-18). Minutes used to run from the round's
-- first tick whoever held the empire, which paid a follower who arrived at
-- minute twenty for twenty minutes of somebody else's war -- and paid a
-- revived player a second time for a first life already banked at its death.
function Tracker.adopt(self: Tracker, id: number)
	local p = self.sim.players[id]
	if p == nil then
		return
	end
	self.startTick[id] = self.sim.tick
	self.peak[id] = p.tileCount
	self.kills[id] = 0
	self.dead[id] = nil
	self.settled[id] = nil
	self.place[id] = nil
	self.deathTick[id] = nil
end

-- How many empires ever put a homeland down. The board a placement is read
-- against, and the divisor the fair share is measured in.
function Tracker.field(self: Tracker): number
	local n = 0
	for _, id in self.sim.playerOrder do
		local p = self.sim.players[id]
		if p and p.spawned then
			n += 1
		end
	end
	return math.max(1, n)
end

-- nil until this empire's result is final -- i.e. until it has died or the
-- round has ended. A caller that pays out on a nil is paying for a match that
-- is still running.
--
-- `partial` is the ONE exception and it has one caller: a player leaving a
-- round that has not finished. The stats come back with `final = false`, which
-- is what `award` reads to withhold the three terms that depend on an outcome
-- this empire no longer has.
function Tracker.statsFor(self: Tracker, id: number, partial: boolean?): Stats?
	local sim = self.sim
	local p = sim.players[id]
	if not p or not p.spawned then
		return nil
	end
	local settled = self.settled[id] == true
	if not settled and not partial then
		return nil
	end
	local field = Tracker.field(self)
	local fair = sim.playableLand / field
	local won = false
	if sim.teamCount > 0 then
		-- A team round is won by the BLOC. Every surviving member took the map;
		-- paying only the top one would make the bonus a lottery among people
		-- who did the same job.
		won = sim.winnerTeam ~= nil and sim.teamOf[id] == sim.winnerTeam and p.alive
	else
		won = sim.winnerId == id
	end
	return {
		spawned = true,
		final = settled,
		minutes = math.max(0, (self.deathTick[id] or sim.tick) - (self.startTick[id] or 0)) * Config.TICK_DT / 60,
		-- Peak land as an EVEN SHARE of the map. `fair` is the map divided by
		-- the field that actually spawned, not by the roster that was invited,
		-- so a round somebody no-showed does not quietly inflate everyone else.
		shares = (self.peak[id] or 0) / math.max(1, fair),
		kills = self.kills[id] or 0,
		place = self.place[id] or field,
		field = field,
		won = settled and won,
	}
end

return Money
