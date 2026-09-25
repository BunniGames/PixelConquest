--!strict
-- Conquest :: Demand  (shared)
--
-- WHAT PEOPLE ACTUALLY JOINED IN THE LAST HOUR, and the one thing that reads
-- it: the EXTRA lobbies the board hosts beyond its fixed three -- two at
-- first, four since 2026-09-19 (2026-09-17,
-- owner: "see in the past hour, which one do people like joining the most of
-- the 3 available to them -- that way we can start a lobby people actually
-- want"). Slots 4 to 7 are not a second ladder somebody chose; they are a
-- copy of whatever the last hour says this population turns up for.
--
-- ONE KEY PER TEN MINUTES, HOLDING THE WHOLE TALLY. The obvious shape -- a key
-- per thing counted -- is 40-odd pairings times six buckets, and a SortedMap
-- range read caps at 200 items, so the window could not be read in one call
-- and would silently start truncating the day a map was added. A bucket is one
-- small table instead: six keys, one GetRangeAsync, and a join is ONE
-- UpdateAsync rather than one per axis.
--
-- WHY BUCKETS AND NOT A SINGLE HOUR-LONG COUNTER. A counter with a 3600s TTL
-- expires all at once: the board would run on an hour of evidence, then on
-- none, then on an hour again. Six ten-minute buckets summed is a window that
-- ROLLS -- it loses its oldest tenth at a time, which is what "the past hour"
-- means to somebody reading the page.
--
-- PURE, except for the store name. MatchmakerServer does every read and write;
-- everything here is arithmetic that both halves can agree on.

local RunService = game:GetService("RunService")

local Demand = {}

-- The same reason Matchmaker.STORE carries one: a Studio session polls the
-- live universe's MemoryStore, and a playtest's joins must not steer the real
-- board (nor the real board a playtest).
local STORE_SUFFIX = RunService:IsStudio() and "_studio" or ""
Demand.STORE = "ConquestDemand_v1" .. STORE_SUFFIX

Demand.BUCKET = 600 -- ten minutes to a bucket
Demand.WINDOW = 6 -- ...and six of them is the hour
-- One spare bucket of life beyond the window, so the oldest bucket still being
-- summed is never one that expired mid-read.
Demand.TTL = Demand.BUCKET * (Demand.WINDOW + 1)

-- HOW MUCH EVIDENCE IS ENOUGH TO STEER A CARD. Under this the extras fall back
-- to their fixed defaults, because an hour holding four joins is noise, and a
-- board that reshapes itself around noise is worse than one that does not move:
-- it teaches a small population that the page is random.
Demand.MIN_JOINS = 20

export type Tally = {
	size: { [string]: number }, -- cap, as a string, -> joins
	pair: { [string]: number }, -- "map|mode" -> joins
	joins: number,
}

function Demand.bucketOf(now: number): number
	return math.floor(now / Demand.BUCKET)
end

-- ZERO-PADDED, because the store is SORTED and reads back in string order.
-- Unpadded, bucket 9 would sort after bucket 10 and a range read would hand
-- back a window with a hole in it.
function Demand.key(bucket: number): string
	return string.format("t|%012d", bucket)
end

-- The oldest bucket still inside the window. Anything below it is a straggler
-- whose TTL has not caught up yet, and summing it would stretch the hour.
function Demand.oldest(now: number): number
	return Demand.bucketOf(now) - (Demand.WINDOW - 1)
end

local function blank(): Tally
	return { size = {}, pair = {}, joins = 0 }
end

Demand.blank = blank

-- One join, folded into a bucket's table. Run INSIDE the UpdateAsync transform
-- so two servers counting the same second cannot lose one of the two.
function Demand.add(bucket: any, cap: number, pairKey: string): any
	local t = if type(bucket) == "table" then bucket else {}
	local size = if type(t.size) == "table" then t.size else {}
	local pair = if type(t.pair) == "table" then t.pair else {}
	local capKey = tostring(cap)
	size[capKey] = (tonumber(size[capKey]) or 0) + 1
	pair[pairKey] = (tonumber(pair[pairKey]) or 0) + 1
	t.size, t.pair = size, pair
	return t
end

-- Every live bucket, summed into one tally. `items` is whatever GetRangeAsync
-- handed back -- key/value pairs, in key order, possibly including a straggler
-- the TTL has not swept.
function Demand.merge(items: { any }, now: number): Tally
	local out = blank()
	local floor = Demand.oldest(now)
	for _, item in items do
		local key = (item :: any).key
		local value = (item :: any).value
		local bucket = tonumber(string.match(tostring(key), "^t|(%d+)$"))
		if bucket and bucket >= floor and type(value) == "table" then
			for capKey, n in (value.size or {}) do
				if tonumber(n) then
					out.size[capKey] = (out.size[capKey] or 0) + (tonumber(n) :: number)
					out.joins += (tonumber(n) :: number)
				end
			end
			for pairKey, n in (value.pair or {}) do
				if tonumber(n) then
					out.pair[pairKey] = (out.pair[pairKey] or 0) + (tonumber(n) :: number)
				end
			end
		end
	end
	return out
end

-- WHICH SIZE PEOPLE WANT, AND IT IS NOT THE ONE WITH THE MOST JOINS.
--
-- WORLD WAR holds 24 seats to SKIRMISH's 6, so it can absorb four times the
-- joins while being no more popular: raw counts crown the biggest card by
-- construction, every hour, forever. What "people want this" actually means is
-- how fast the seats offered fill -- so the count is divided by the SEATS
-- OFFERED, which is the cap times the number of cards currently showing it.
--
-- That second factor is not decoration. The extras DUPLICATE a size, so the
-- moment this function picks 6 there are three 6-seat cards on the board taking
-- three cards' worth of joins between them -- and without dividing by that, the
-- size it picked would look more popular tomorrow BECAUSE it picked it. The
-- feedback loop is the failure mode here, and this is what closes it.
--
-- `offers` is cap -> how many cards are offering that cap right now.
function Demand.bestSize(tally: Tally, offers: { [number]: number }): number?
	if tally.joins < Demand.MIN_JOINS then
		return nil
	end
	local bestCap, bestScore = nil, -1
	for capKey, joins in tally.size do
		local cap = tonumber(capKey)
		if cap and cap > 0 then
			local seats = cap * math.max(1, offers[cap] or 1)
			local score = joins / seats
			-- Ties break on the SMALLER card, which is the one that turns into
			-- a real match sooner. A tie here is two sizes with identical fill
			-- rates, so there is nothing else to separate them on.
			if score > bestScore or (score == bestScore and bestCap and cap < bestCap) then
				bestCap, bestScore = cap, score
			end
		end
	end
	return bestCap
end

-- WHICH PAIRING, given what is already on the board. No normalising here: every
-- pairing is dealt by the same uniform draw (Matchmaker.drawPair), so they are
-- equally exposed and raw joins is the honest figure.
--
-- `exclude` is the pairings the board is showing NOW. Copying one of those is
-- the one outcome to avoid: two identical cards do not double the interest in a
-- map, they split one queue across two lobbies and neither fills.
--
-- `excludeMaps` is the harder rule that came later (2026-09-17, owner: "for the
-- 2 extra games, make sure they're never the same Map. they can be the same
-- mode"), and it is applied HERE rather than only at the mint so that the
-- demand signal SURVIVES it. Filtering afterwards would mean the top pairing
-- landing on a taken map threw the whole pick away and the card fell back to a
-- random draw; skipping those inside the search returns the most-joined pairing
-- that is actually allowed, which is the answer the question was asking for.
--
-- Mode is deliberately not excluded: two extras on the same mode is fine, and
-- with three modes in the rotation forbidding it would leave almost nothing.
function Demand.bestPair(tally: Tally, exclude: { [string]: boolean }?, excludeMaps: { [string]: boolean }?): string?
	if tally.joins < Demand.MIN_JOINS then
		return nil
	end
	local skip = exclude or {}
	local skipMap = excludeMaps or {}
	local bestKey, bestJoins = nil, 0
	for pairKey, joins in tally.pair do
		local map = string.match(pairKey, "^(.-)|")
		if not skip[pairKey] and not (map ~= nil and skipMap[map]) and joins > bestJoins then
			bestKey, bestJoins = pairKey, joins
		end
	end
	return bestKey
end

return Demand
