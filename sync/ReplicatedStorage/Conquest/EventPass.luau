--!strict
-- THE HALLOWEEN EVENT PASS (2026-10-09, owner: "make the halloween event pass.
-- have a good reward when the tier % 10 equals 3 5 8 and 10. make 10 a really
-- great reward. 5 good, 3 and 8 mid rewards, and the rest just filler").
--
-- ONE MODULE IS THE WHOLE PASS. The server grants off it (ConquestData
-- .claimEventTier), the lobby sheet draws off it (EventPassUI) and the match
-- server prices XP off it (ConquestData.addEventXp) -- three readers, one
-- source, so a retune is an edit here and nowhere else.
--
-- TWO TRACKS (2026-10-09, owner: "add these dev products into purchasing the
-- premium rewards and +1 +3 and +5 to skip items on the pass"). The FREE track
-- pays Money on every tier. The PREMIUM track -- the HALLOWEEN PASS developer
-- product, 199 R$ -- carries the owner's ladder below, and Money on its filler
-- tiers too. Buying premium late opens every premium tier already reached.
--
-- THE PREMIUM LADDER BY tier % 10, as the owner set it:
--   0  GREAT   10 and 20 a big Money haul with tokens on top; 30 the
--              Artillery Battery Bundle, handed over as if bought
--              (moneyPasses) -- the ONLY pass on the track (owner,
--              2026-10-09). Already held, it pays its shop Money price.
--   5  GOOD    a Halloween-only tile pattern (Patterns, tier "halloween")
--              plus Money -- never sold, the pass is the only door
--   3, 8 MID   a token the store sells for Robux: revive, rename, flag,
--              3x money round
--   rest       FILLER Money, the same as the free track's -- or a BOOST
--              COUPON on 4/7/12/17/22/27 (owner, 2026-10-09: "give coupons
--              for players to activate the boosts as some rewards")
--
-- A COUPON is a timed boost (Config.TIMED_BOOSTS: Gold Boost 2x gold, Special
-- Forces +50% speed vs AI) that has not started: it waits on the profile until
-- the player spends it on the in-match store's boost card, so its 15 minutes
-- run in a round of their choosing (Data.useCoupon). The free track gets one
-- on each of 10 / 20 / 30 as well.
--
-- TIER SKIPS: +1 / +3 / +5 TIER developer products move the account that many
-- tiers along (EventPass.skip), keeping how far into the current tier it was.
--
-- WHY NOT THE TIMED BOOSTS OR THE TUTORIAL FOUR. A timed boost is a
-- wall-clock deadline (profile.boostUntil), so one claimed in the lobby burns
-- down before a round starts; the tutorial four are troops/gold/warheads,
-- which MONETIZATION.txt section 0 keeps out of every real round.
local EventPass = {}

-- WHICH EVENT THIS IS. The profile block is keyed by it, so the next event is
-- a new ID and every account starts it from nothing.
EventPass.ID = "halloween2026"
EventPass.NAME = "HALLOWEEN EVENT PASS"
-- WHEN XP STOPS: 2026-11-03 00:00 PST (08:00 UTC). Claiming what was already
-- earned stays open after this.
EventPass.ENDS = 1793692800

-- XP ------------------------------------------------------------------------
-- Every settled round pays: a flat part for playing, a part for how high you
-- finished, and a bonus for the win. 25 at the bottom of a lost round, 100 for
-- a win. A round you LEAVE pays half (the money path's `partial`), and HORDE
-- -- the Halloween mode -- pays double.
EventPass.XP_PLAY = 25
EventPass.XP_PLACE = 35
EventPass.XP_WIN = 40
EventPass.HORDE_MULT = 2

function EventPass.xpFor(place: number, field: number, won: boolean, partial: boolean?, horde: boolean?): number
	local f = math.max(1, math.floor(field))
	local p = math.clamp(math.floor(place), 1, f)
	-- Share of the field you finished above, 1 for first, 0 for last.
	local above = if f <= 1 then 1 else (f - p) / (f - 1)
	local xp = EventPass.XP_PLAY + EventPass.XP_PLACE * above + (if won then EventPass.XP_WIN else 0)
	if partial then
		xp *= 0.5
	end
	if horde then
		xp *= EventPass.HORDE_MULT
	end
	return math.max(1, math.floor(xp + 0.5))
end

-- TIERS ---------------------------------------------------------------------
export type Grant = { kind: string, amount: number?, key: string? }
export type Tier = { cost: number, free: { Grant }, premium: { Grant } }

-- What each tier COSTS in XP, by decade: 80 / 120 / 160, 3,600 in all -- about
-- 70 rounds at a typical 50 XP, a little over three weeks of regular play.
local function cost(tier: number): number
	if tier <= 10 then
		return 80
	elseif tier <= 20 then
		return 120
	end
	return 160
end

-- THE FREE TRACK'S MONEY, rising by half-decade: 500 / 750 / 1,000 / 1,250 /
-- 1,500 / 2,000. The premium filler tiers pay the same again.
local BAND = { 500, 750, 1000, 1250, 1500, 2000 }
local function band(tier: number): number
	return BAND[math.clamp(math.floor((tier - 1) / 5) + 1, 1, #BAND)]
end

-- The premium track's special tiers; every other premium tier is band Money.
local SPECIAL: { [number]: { Grant } } = {
	[3] = { { kind = "revive", amount = 1 } },
	[5] = { { kind = "pattern", key = "pumpkins" }, { kind = "money", amount = 2500 } },
	[8] = { { kind = "rename", amount = 1 } },
	[4] = { { kind = "coupon", key = "BOOST_GOLD", amount = 1 } },
	[7] = { { kind = "coupon", key = "TUTORIAL_FORCES", amount = 1 } },
	[10] = { { kind = "money", amount = 10000 }, { kind = "revive", amount = 2 } },
	[12] = { { kind = "coupon", key = "BOOST_GOLD", amount = 1 } },
	[13] = { { kind = "money3x", amount = 1 } },
	[15] = { { kind = "pattern", key = "bats" }, { kind = "money", amount = 5000 } },
	[18] = { { kind = "flag", amount = 1 } },
	[17] = { { kind = "coupon", key = "TUTORIAL_FORCES", amount = 1 } },
	[20] = { { kind = "money", amount = 25000 }, { kind = "money3x", amount = 2 } },
	[22] = { { kind = "coupon", key = "BOOST_GOLD", amount = 2 } },
	[23] = { { kind = "revive", amount = 2 } },
	[25] = { { kind = "pattern", key = "ghosts" }, { kind = "money", amount = 7500 } },
	[28] = { { kind = "money3x", amount = 2 } },
	[27] = { { kind = "coupon", key = "TUTORIAL_FORCES", amount = 2 } },
	[30] = { { kind = "pass", key = "ARTILLERY" } },
}

-- THE FREE TRACK'S COUPONS, on top of its Money: a taste of each boost.
local FREE_EXTRA: { [number]: Grant } = {
	[10] = { kind = "coupon", key = "BOOST_GOLD", amount = 1 },
	[20] = { kind = "coupon", key = "TUTORIAL_FORCES", amount = 1 },
	[30] = { kind = "coupon", key = "BOOST_GOLD", amount = 2 },
}

EventPass.COUNT = 30
EventPass.TIERS = {} :: { Tier }
for i = 1, EventPass.COUNT do
	EventPass.TIERS[i] = {
		cost = cost(i),
		free = FREE_EXTRA[i] and { { kind = "money", amount = band(i) }, FREE_EXTRA[i] }
			or { { kind = "money", amount = band(i) } },
		premium = SPECIAL[i] or { { kind = "money", amount = band(i) } },
	}
end

-- THE PRODUCTS (Products: EVENT_PASS, EVENT_SKIP1/3/5). Keys only; the ids
-- and prices live in Products like every other product.
EventPass.PREMIUM_PRODUCT = "EVENT_PASS"
EventPass.SKIPS = { { key = "EVENT_SKIP1", tiers = 1 }, { key = "EVENT_SKIP3", tiers = 3 }, { key = "EVENT_SKIP5", tiers = 5 } }

-- A claimed-set key: "f7" is tier 7's free reward, "p7" its premium one.
function EventPass.claimKey(tier: number, premium: boolean): string
	return (if premium then "p" else "f") .. tostring(tier)
end

-- The owner's ladder, by tier % 10. The sheet colours each card by this.
function EventPass.classOf(tier: number): string
	local r = tier % 10
	if r == 0 then
		return "great"
	elseif r == 5 then
		return "good"
	elseif r == 3 or r == 8 then
		return "mid"
	end
	return "filler"
end

-- XP needed to REACH a tier (the sum of every cost up to and including it).
function EventPass.xpTo(tier: number): number
	local total = 0
	for i = 1, math.min(tier, EventPass.COUNT) do
		total += EventPass.TIERS[i].cost
	end
	return total
end

-- XP after skipping `n` tiers: that many tiers further on, keeping how far
-- into the current tier it was (clipped short of the next one), capped at the
-- end of the track.
function EventPass.skip(xp: number, n: number): number
	local reached, into = EventPass.progress(xp)
	local target = math.min(EventPass.COUNT, reached + math.max(0, math.floor(n)))
	if target >= EventPass.COUNT then
		return EventPass.xpTo(EventPass.COUNT)
	end
	return EventPass.xpTo(target) + math.min(into, EventPass.TIERS[target + 1].cost - 1)
end

-- How many tiers `xp` has reached, and how far into the next one it is.
-- Returns reached, xpInto, nextCost (nextCost 0 once the track is done).
function EventPass.progress(xp: number): (number, number, number)
	local left = math.max(0, math.floor(xp))
	for i, t in EventPass.TIERS do
		if left < t.cost then
			return i - 1, left, t.cost
		end
		left -= t.cost
	end
	return EventPass.COUNT, 0, 0
end

function EventPass.isLive(now: number?): boolean
	return (now or os.time()) < EventPass.ENDS
end

return EventPass
