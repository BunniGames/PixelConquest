--!strict
-- Conquest :: Ranked  (shared)
--
-- THE RANKED LADDER (2026-10-05, owner: "a new system called Ranked ... an ELO
-- system ... 1v1, 2v2 and 4v4 ... 9 ranks ... every new rank up should contain
-- some money reward or skin").
--
-- Owner's rulings, all on 2026-10-05:
--   * HUMANS ONLY, on SMALL maps -- no AI filler, no faux seats.
--   * ONE SHARED RATING across 1v1, 2v2 and 4v4.
--   * Rewards are Money plus EXISTING tile patterns (no ranked-only skins).
--   * Emblems are in-game art only (RankEmblems), no Roblox badges, and they
--     display IN RANKED MATCHES.
--   * The rank is STORED as a plain value so later features can read it:
--     profile.ranked.rank (index into LADDER) and the player attributes
--     RANK_ATTR / RANK_ID_ATTR, set on every server the player is on.
--
-- Everything here is pure: the ladder, the rating maths and the team-forming
-- search. The lobby half is ServerScriptService.RankedLobby, the match half is
-- ServerScriptService.RankedMatch, and both test against this file headless.

local Ranked = {}

-- ================================================================ the ladder ==

-- A new account starts here, at the bottom of Recruit, so the first climb is
-- a real rank-up rather than a placement nobody earned.
Ranked.START = 1000

-- TWO NUMBERS, THE VALORANT WAY (owner, 2026-10-05: "how does something like
-- valorant ... do it" -> "sure"). `rating` is the hidden MMR: the ELO below,
-- used ONLY for matchmaking and as the target the visible rank drifts toward.
-- What a player sees is their RANK and RR, a 0-100 bar inside it: a win adds
-- RR, a loss takes it, 100 ranks you up, below 0 ranks you down.
--
-- `min` IS THE MMR BAND each rank stands for, NOT a rating you must reach.
-- RR moves faster toward the rank your MMR says you belong at (RR_K), so the
-- visible rank tracks skill. The bands are MMR percentiles of ACTIVE players
-- (30+ games) from a simulated population: Soldier p10, Sergeant p25,
-- Lieutenant p45, Captain p65, Major p80, Colonel p90, General p97, Emperor
-- p99. Simulated outcome (mapgen sim, 2026-10-05): active players sit mostly at
-- Lieutenant/Captain, ~2% are Emperor, ~0.6% of everyone who ever plays
-- reaches it. RE-FIT THESE FROM REAL MMRs once the game has them.
--
-- Index is the rank number stored on the profile; `id` keys RankEmblems.ART.
-- Append-only, never reorder: an index is in saves.
--
-- REWARDS are paid ONCE, the first time a rank is reached (profile.ranked.best
-- is the latch), so falling and re-climbing pays nothing. Money is priced off
-- Money.ANCHOR (~1,000 an average game) and pattern tiers off Patterns' ladder
-- (uncommon 2k, rare 8k, epic 32k, legendary 128k). A reward pattern the
-- player already owns pays OWNED_REFUND of its shop price in Money instead.
--
-- PASS REWARDS (owner, 2026-10-05: "make the reward for captain Scatershot,
-- the reward for Emperor Airbase"). `pass` is a Products pass key, granted as
-- if bought with Money (profile.moneyPasses, the free-rewards sheet's route),
-- and `passName` is what the ladder and the result card call it. An account
-- that already owns the pass gets OWNED_REFUND of its Money price instead.
export type Rung = {
	id: string,
	name: string,
	min: number,
	rr: number, -- the RR TOTAL this rank starts at (see applyRR)
	money: number,
	pattern: string?,
	pass: string?,
	passName: string?,
	color: Color3,
}

Ranked.LADDER = {
	{ id = "recruit", name = "Recruit", min = 0, rr = 0, money = 0, color = Color3.fromRGB(196, 140, 92) },
	{ id = "soldier", name = "Soldier", min = 776, rr = 100, money = 2000, color = Color3.fromRGB(170, 180, 192) },
	{ id = "sergeant", name = "Sergeant", min = 890, rr = 200, money = 3000, pattern = "checker", color = Color3.fromRGB(236, 160, 96) },
	{ id = "lieutenant", name = "Lieutenant", min = 977, rr = 300, money = 5000, color = Color3.fromRGB(220, 226, 236) },
	{ id = "captain", name = "Captain", min = 1068, rr = 450, money = 7500, pass = "SCATTERSHOT", passName = "Scattershot", color = Color3.fromRGB(255, 214, 90) },
	{ id = "major", name = "Major", min = 1150, rr = 600, money = 10000, color = Color3.fromRGB(90, 220, 140) },
	{ id = "colonel", name = "Colonel", min = 1218, rr = 750, money = 15000, pattern = "waves", color = Color3.fromRGB(110, 170, 255) },
	{ id = "general", name = "General", min = 1328, rr = 900, money = 25000, color = Color3.fromRGB(255, 96, 110) },
	{ id = "emperor", name = "Emperor", min = 1415, rr = 1100, money = 50000, pass = "AIRSTRIKE", passName = "Airbase", color = Color3.fromRGB(200, 130, 255) },
} :: { Rung }

Ranked.OWNED_REFUND = 0.5

-- Player attributes, written by whichever server holds the profile.
Ranked.RANK_ATTR = "ConquestRank" -- number, 1..#LADDER
Ranked.RANK_ID_ATTR = "ConquestRankId" -- string, LADDER[i].id
Ranked.RATING_ATTR = "ConquestRating" -- number, the HIDDEN MMR (server use)
Ranked.RR_ATTR = "ConquestRR" -- number, 0-100 inside the rank

-- STUDIO ONLY: the ranked config of a round started in-session, on
-- ReplicatedStorage (there is no match record to carry it).
Ranked.STUDIO_ATTR = "ConquestLocalRanked"

function Ranked.rankOf(rating: number): number
	local idx = 1
	for i, rung in Ranked.LADDER do
		if rating >= rung.min then
			idx = i
		end
	end
	return idx
end

function Ranked.rung(index: number): Rung
	return Ranked.LADDER[math.clamp(math.floor(index), 1, #Ranked.LADDER)]
end

-- 0..1 progress through the current rank toward the next; 1 at the top rung.
-- The rank an RR TOTAL stands at.
function Ranked.rankOfRR(total: number): number
	local idx = 1
	for i, rung in Ranked.LADDER do
		if total >= rung.rr then
			idx = i
		end
	end
	return idx
end

-- The RR span of a rank: from its total to the next rank's (the top rank's
-- bar is drawn over TOP_SPAN).
Ranked.TOP_SPAN = 200
function Ranked.span(rank: number): (number, number)
	local lo = Ranked.LADDER[rank].rr
	local nxt = Ranked.LADDER[rank + 1]
	return lo, if nxt then nxt.rr else lo + Ranked.TOP_SPAN
end

-- 0..1 through the current rank's span, for the bars.
function Ranked.progress(block: any): number
	local lo, hi = Ranked.span(block.rank)
	return math.clamp(((tonumber(block.rr) or 0) - lo) / (hi - lo), 0, 1)
end

-- ====================================================================== RR ==
-- Tuned in mapgen's rr sim (2026-10-05). At a rank that matches your MMR a
-- win is +RR_WIN and a loss -RR_LOSS: a small tilt, so an average player
-- creeps up a little. Every rank of gap between where your MMR says you
-- belong and where you are moves both by RR_K -- climbing fast when you are
-- under-ranked, sinking when you are over. SHIELD losses after a rank-up
-- cannot rank you straight back down.
Ranked.RR_WIN = 24
Ranked.RR_LOSS = 20
Ranked.RR_K = 25
Ranked.RR_WIN_MIN = 5
Ranked.RR_WIN_MAX = 45
Ranked.RR_LOSS_MIN = 5
Ranked.RR_LOSS_MAX = 45
Ranked.SHIELD = 3
Ranked.OVER_CAP = 2

-- Where an MMR sits on the ladder as a continuous position: 0 at the bottom of
-- Recruit, 1 at the bottom of Soldier, ..., 8 at Emperor's band and up to 9.
function Ranked.mmrPos(mmr: number): number
	local i = Ranked.rankOf(mmr)
	local lo = Ranked.LADDER[i].min
	local nxt = Ranked.LADDER[i + 1]
	local hi = if nxt then nxt.min else lo + 100
	return (i - 1) + math.clamp((mmr - lo) / (hi - lo), 0, 1)
end

-- Applies one result to the visible rank/RR (after the MMR has moved).
-- Returns the RR change.
--
-- RR IS A RUNNING TOTAL (owner, 2026-10-05: "i dont want RR to reset to 0
-- after each rank up. I want it to be continually added"). It never resets:
-- the rank is whichever LADDER `rr` total it has reached. A loss below the
-- current rank's total ranks you down -- unless a rank-up's SHIELD is up, in
-- which case it stops at that total.
function Ranked.applyRR(block: any, won: boolean): number
	local lo, hi = Ranked.span(block.rank)
	local here = (block.rank - 1) + math.clamp((block.rr - lo) / (hi - lo), 0, 1)
	local gap = Ranked.mmrPos(block.rating) - here
	local d
	if won then
		d = math.clamp(Ranked.RR_WIN + Ranked.RR_K * gap, Ranked.RR_WIN_MIN, Ranked.RR_WIN_MAX)
		-- RANKED ABOVE YOUR MMR BY OVER_CAP RANKS OR MORE: a win pays no RR.
		-- Without it, wins that move no MMR (an alt, a stomp) still paid
		-- RR_WIN_MIN each and climbed forever.
		if gap <= -Ranked.OVER_CAP then
			d = 0
		end
	else
		d = -math.clamp(Ranked.RR_LOSS - Ranked.RR_K * gap, Ranked.RR_LOSS_MIN, Ranked.RR_LOSS_MAX)
	end
	d = math.floor(d + 0.5)
	local total = math.max(0, block.rr + d)
	local newRank = Ranked.rankOfRR(total)
	if newRank < block.rank and block.shield > 0 then
		-- Protected: held at the floor of the rank just earned.
		total = Ranked.LADDER[block.rank].rr
		newRank = block.rank
	end
	if newRank > block.rank then
		block.shield = Ranked.SHIELD
	elseif not won and block.shield > 0 then
		block.shield -= 1
	end
	d = total - block.rr
	block.rr = total
	block.rank = newRank
	return d
end

-- ================================================================== queues ==

-- One entry per queue. `size` is players per SIDE. `maps` are the small maps
-- this size plays on (owner: "humans only, small maps"); a map with a
-- MAX_EMPIRES under 2*size must never be listed for that size.
export type Queue = { id: string, name: string, size: number, maps: { string } }

Ranked.QUEUES = {
	{ id = "1v1", name = "1V1", size = 1, maps = { "korea", "japan", "uk" } },
	{ id = "2v2", name = "2V2", size = 2, maps = { "philippines", "japan", "uk" } },
	{ id = "4v4", name = "4V4", size = 4, maps = { "uk", "nyc", "africa", "mars" } },
} :: { Queue }

function Ranked.queue(id: any): Queue?
	for _, q in Ranked.QUEUES do
		if q.id == id then
			return q
		end
	end
	return nil
end

-- 4V4 LOOSENS AFTER A MINUTE (owner, 2026-10-05: "for 4v4, can you make it 1
-- minute max before it loosens up to make it so they almost certainly get
-- it"). Rating is already wide open by OPEN_AFTER; what holds a 4v4 back is
-- eight bodies. So from RELAX_AFTER a 4v4 party will take, in order, a 3v3 out
-- of its own queue, then a 2v2 that may also pull from the 2v2 queue (whose
-- players get exactly the 2v2 they asked for). Parties are still never split,
-- so a party of four only ever plays 4v4.
Ranked.RELAX_AFTER = 60
Ranked.RELAX = {
	["4v4"] = { { size = 3 }, { size = 2, pull = "2v2" } },
} :: { [string]: { { size: number, pull: string? } } }

-- The maps a match of `size` per side plays on: the queue of that size's
-- list, and the 4v4 list for a 3v3.
function Ranked.mapsFor(size: number): { string }
	for _, q in Ranked.QUEUES do
		if q.size == size then
			return q.maps
		end
	end
	return (Ranked.queue("4v4") :: Queue).maps
end

-- The mode every ranked round runs as (Modes.BY_ID.ranked): two sides, no
-- rotation. 1v1 is two sides of one.
Ranked.MODE = "ranked"

-- The largest party, which is the largest side.
Ranked.MAX_PARTY = 4

-- ============================================================ rating maths ==

-- Faster movement while a rating is still finding its level.
Ranked.K_NEW = 40
Ranked.K = 28
Ranked.NEW_GAMES = 10
-- Floor and ceiling on one match's movement, so an upset never moves a
-- settled rating by an absurd amount and a won match always pays something.
Ranked.MIN_GAIN = 4
Ranked.MIN_GAIN_BELOW = 0.85
Ranked.MAX_DELTA = 60
Ranked.FLOOR = 0

function Ranked.expected(mine: number, theirs: number): number
	return 1 / (1 + 10 ^ ((theirs - mine) / 400))
end

-- One player's rating change. `mine` is their own rating and `theirs` the
-- opposing side's AVERAGE: a player carried up by a strong teammate gains
-- less than the teammate does for the same win, and loses more for the same
-- loss. `games` is matches played before this one.
function Ranked.delta(mine: number, theirs: number, won: boolean, games: number): number
	local k = (games < Ranked.NEW_GAMES) and Ranked.K_NEW or Ranked.K
	local e = Ranked.expected(mine, theirs)
	local d = k * ((won and 1 or 0) - e)
	if won then
		-- The floor is for close games only. Beating someone you were all but
		-- certain to beat pays what it is worth -- usually nothing -- so a
		-- main farming its own alt gains no MMR (prod review, 2026-10-05).
		if e < Ranked.MIN_GAIN_BELOW then
			d = math.max(Ranked.MIN_GAIN, d)
		end
	else
		d = math.min(-1, d)
	end
	d = math.clamp(d, -Ranked.MAX_DELTA, Ranked.MAX_DELTA)
	return math.floor(d + 0.5)
end

-- ============================================================ matchmaking ==

-- How far apart (in rating) two parties may be and still be matched, widening
-- the longer the OLDEST of them has waited.
--
-- EVERYONE GETS A GAME WITHIN 45 s (owner, 2026-10-05: "ideally i want
-- everyone to get a match within 45 seconds"). The window opens at +-150,
-- widens 20 a second (+-750 at 30 s, +-930 at 39 s), and from OPEN_AFTER
-- on it is unlimited: whoever else is in the queue is a match. 40 and not 45
-- because the match tick (3-4 s) and the owner's heartbeat (2 s) come on top
-- before the teleport starts. What it cannot
-- do is invent players -- an empty queue, or a 4v4 short of eight, still
-- waits (ranked never fills with AI).
Ranked.WINDOW_BASE = 150
Ranked.WINDOW_PER_SEC = 20
Ranked.OPEN_AFTER = 40

function Ranked.window(waitedSeconds: number): number
	if waitedSeconds >= Ranked.OPEN_AFTER then
		return math.huge
	end
	return Ranked.WINDOW_BASE + Ranked.WINDOW_PER_SEC * math.max(0, waitedSeconds)
end

-- A queued party as the search sees it.
export type Party = {
	key: string,
	n: number, -- members
	r: number, -- average rating
	t: number, -- queued at (os.time)
}

-- THE SEARCH. Given the party that is driving (`anchor`, always included) and
-- every open party in the same queue, find parties that fill exactly two sides
-- of `size`, every party within the anchor's window, and split them into the
-- two sides with the smallest gap in average rating. Parties never split.
--
-- Returns sideA, sideB (lists of keys) or nil. Bounded: at most CANDIDATES
-- parties are considered (nearest rating first) and sides hold at most 4, so
-- the subset walk is tiny.
Ranked.CANDIDATES = 10

function Ranked.formMatch(anchor: Party, open: { Party }, size: number, now: number): ({ string }?, { string }?)
	local win = Ranked.window(now - anchor.t)
	local pool: { Party } = { anchor }
	local near: { Party } = {}
	for _, p in open do
		if p.key ~= anchor.key and p.n <= size and math.abs(p.r - anchor.r) <= math.max(win, Ranked.window(now - p.t)) then
			table.insert(near, p)
		end
	end
	table.sort(near, function(a, b)
		local da, db = math.abs(a.r - anchor.r), math.abs(b.r - anchor.r)
		if da ~= db then
			return da < db
		end
		return a.t < b.t
	end)
	for i = 1, math.min(#near, Ranked.CANDIDATES - 1) do
		table.insert(pool, near[i])
	end
	if anchor.n > size then
		return nil
	end

	-- Every way to pick parties totalling exactly 2*size that include the
	-- anchor, then every way to split that pick into two sides of `size`.
	local best: { any }? = nil
	local bestGap = math.huge
	local need = size * 2
	local pick: { Party } = { anchor }

	local function trySplit()
		-- Assign each picked party to side 1 or 2; the anchor is pinned to
		-- side 1 so mirror splits are not tried twice.
		local m = #pick
		for mask = 0, (2 ^ (m - 1)) - 1 do
			local n1, n2, s1, s2 = pick[1].n, 0, pick[1].r * pick[1].n, 0
			for j = 2, m do
				if bit32.band(mask, 2 ^ (j - 2)) ~= 0 then
					n2 += pick[j].n
					s2 += pick[j].r * pick[j].n
				else
					n1 += pick[j].n
					s1 += pick[j].r * pick[j].n
				end
			end
			if n1 == size and n2 == size then
				local gap = math.abs(s1 / n1 - s2 / n2)
				if gap < bestGap then
					bestGap = gap
					local a, b = { pick[1].key }, {}
					for j = 2, m do
						if bit32.band(mask, 2 ^ (j - 2)) ~= 0 then
							table.insert(b, pick[j].key)
						else
							table.insert(a, pick[j].key)
						end
					end
					best = { a, b }
				end
			end
		end
	end

	local function walk(from: number, total: number)
		if total == need then
			trySplit()
			return
		end
		for i = from, #pool do
			local p = pool[i]
			if total + p.n <= need then
				table.insert(pick, p)
				walk(i + 1, total + p.n)
				table.remove(pick)
			end
		end
	end
	walk(2, anchor.n)

	if best then
		return best[1], best[2]
	end
	return nil
end

-- =================================================================== wire ==

-- The lobby panel's state for one player, as the client draws it.
export type View = {
	rating: number,
	rr: number,
	rank: number,
	best: number,
	games: number,
	wins: number,
}

-- THE PROFILE BLOCK. Kept here so the lobby and the match server build it
-- identically; ConquestData's defaultProfile carries the same shape.
function Ranked.defaultBlock(): any
	-- No `rrv` here on purpose: ensure() fills defaults first, and a default
	-- rrv would skip the old-bar conversion below. ensure() sets it.
	return { rating = Ranked.START, rank = 1, rr = 0, shield = 0, best = 1, games = 0, wins = 0, losses = 0 }
end

-- Fills any missing field in place and returns the block. Additive only.
function Ranked.ensure(profile: any): any
	if type(profile.ranked) ~= "table" then
		profile.ranked = Ranked.defaultBlock()
	end
	local b = profile.ranked
	for k, v in Ranked.defaultBlock() do
		if type(b[k]) ~= type(v) then
			b[k] = v
		end
	end
	b.rank = math.clamp(math.floor(b.rank), 1, #Ranked.LADDER)
	-- RR used to be a 0-100 bar inside the rank; it is a running total now.
	-- `rrv` marks a converted block (additive: a missing key reads as old).
	if b.rrv ~= 2 then
		b.rr = Ranked.LADDER[b.rank].rr + math.clamp(b.rr, 0, 99)
		b.rrv = 2
	end
	-- `best` is NOT raised here: it is the reward latch, and RankedMatch pays
	-- every rank from best+1 up to the new one. A rating that moved without a
	-- match (an owner edit) is then still paid on the next result.
	return b
end

function Ranked.view(block: any): View
	return {
		rating = math.floor(block.rating),
		rank = block.rank,
		rr = block.rr,
		best = block.best,
		games = block.games,
		wins = block.wins,
	}
end

return Ranked
