--!strict
-- Conquest :: RankedMatch  (server, match side)
--
-- The half of Ranked that lives on a MATCH server. ConquestServer calls in at
-- five places and nothing else here reaches into the round:
--
--   RankedMatch.configure(cfg)    bootMatch / the Studio local start: is this
--                                 round ranked, and who is on which side.
--   RankedMatch.tagFor(player)    startRound's addPlayer: the side, carried as
--                                 a clan tag, so Sim.packTeams seats each side
--                                 together (Sim.addPlayer's same-tag rule).
--   RankedMatch.rankOf(uid)       roster(): the rank index the client draws as
--                                 an emblem beside the nation's name.
--   RankedMatch.finish(sim)       the round's "ended" block: every player still
--                                 here is rated, win or loss by SIDE.
--   RankedMatch.abandon(player)   PlayerRemoving: leaving a live ranked round
--                                 is a loss, settled on the way out (before
--                                 ConquestData releases the profile).
--
-- The rating each player is matched AGAINST is the other side's average as it
-- was when the lobby formed the match (cfg.ranked.r) -- a leaver's rating
-- still counts, and nobody's result depends on who settled first.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Ranked = require(Shared.Ranked)
local Patterns = require(Shared.Patterns)
local Products = require(Shared.Products)
local Net = require(Shared.Net)
local Data = require(script.Parent:WaitForChild("ConquestData"))

local RankedMatch = {}

-- The side of each user id (1 or 2), their rating when matched, and the queue.
type Ctx = {
	queue: string,
	side: { [number]: number },
	rating: { [number]: number },
	settled: { [number]: boolean },
	size: number,
	ghosts: boolean,
	over: boolean,
	-- os.clock() at configure, and when each player LEFT (abandon).
	startedAt: number,
	leftAt: { [number]: number },
	void: boolean,
}

local ctx: Ctx? = nil

local stateRE: RemoteEvent? = nil
local function state(): RemoteEvent
	if stateRE == nil then
		stateRE = Net.await(ReplicatedStorage):WaitForChild("State") :: RemoteEvent
	end
	return stateRE :: RemoteEvent
end

-- Every server the player is on mirrors their stored rank onto attributes, so
-- any later feature can read `player:GetAttribute(Ranked.RANK_ATTR)` without
-- touching the profile.
function RankedMatch.publish(player: Player, block: any)
	player:SetAttribute(Ranked.RANK_ATTR, block.rank)
	player:SetAttribute(Ranked.RANK_ID_ATTR, Ranked.rung(block.rank).id)
	player:SetAttribute(Ranked.RATING_ATTR, math.floor(block.rating))
	player:SetAttribute(Ranked.RR_ATTR, block.rr)
end

Data.onReady(function(player: Player, profile: any)
	RankedMatch.publish(player, Ranked.ensure(profile))
end)

-- `cfg.ranked` is a table on a reserved server (it rode the match record) and
-- a JSON string in Studio (it rode an attribute). Keys are user ids as
-- STRINGS on both, because JSON never keeps a numeric key.
function RankedMatch.configure(cfg: any): boolean
	ctx = nil
	local raw = cfg and cfg.ranked
	if type(raw) == "string" and raw ~= "" then
		local ok, decoded = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		raw = ok and decoded or nil
	end
	if type(raw) ~= "table" or type(raw.side) ~= "table" then
		return false
	end
	local c: Ctx = {
		queue = tostring(raw.q or "?"),
		side = {},
		rating = {},
		settled = {},
		size = math.clamp(tonumber(raw.size) or 1, 1, Ranked.MAX_PARTY),
		-- Studio only: seats nobody is in become AI seats (see ghosts()).
		ghosts = raw.ghosts == true and RunService:IsStudio(),
		over = false,
		void = false,
		startedAt = os.clock(),
		leftAt = {},
	}
	for k, s in raw.side do
		local uid = tonumber(k)
		local side = tonumber(s)
		if uid and (side == 1 or side == 2) then
			c.side[uid] = side
			c.rating[uid] = tonumber(type(raw.r) == "table" and raw.r[k]) or Ranked.START
		end
	end
	ctx = c
	print(("[Ranked] %s match configured"):format(c.queue))
	return true
end

-- STUDIO: the config a ranked round started in-session left on
-- ReplicatedStorage (RankedLobby.startLocally). nil when there is none.
function RankedMatch.studioConfig(): string?
	local v = ReplicatedStorage:GetAttribute(Ranked.STUDIO_ATTR)
	return if type(v) == "string" and v ~= "" then v else nil
end

function RankedMatch.active(): boolean
	return ctx ~= nil
end

-- How many players the lobby promised, for bootMatch's arrival wait.
function RankedMatch.expected(): number
	local n = 0
	if ctx then
		for _ in ctx.side do
			n += 1
		end
	end
	return n
end

-- How many of the promised players are in the room -- the arrival wait
-- counts these, never a stranger who followed somebody in.
function RankedMatch.presentCount(): number
	local n = 0
	if ctx then
		for _, plr in Players:GetPlayers() do
			if ctx.side[plr.UserId] then
				n += 1
			end
		end
	end
	return n
end

-- A SERVER GOING DOWN IS NOT A FORFEIT (prod review, 2026-10-05). A publish's
-- shutdown, or ConquestServer's tick-failure bail, empties the room with the
-- round still live; without this every player in it took a loss.
game:BindToClose(function()
	if ctx and not ctx.over then
		ctx.void = true
		ctx.over = true
	end
end)

-- Both sides have somebody in the room. A ranked round with an empty side is
-- not a match -- the side that showed up would take the map uncontested -- so
-- bootMatch voids it instead of starting it.
function RankedMatch.bothSidesPresent(): boolean
	if not ctx then
		return true
	end
	if ctx.ghosts then
		return true
	end
	local seen = { false, false }
	for _, plr in Players:GetPlayers() do
		local s = ctx.side[plr.UserId]
		if s then
			seen[s] = true
		end
	end
	return seen[1] and seen[2]
end

-- STUDIO GHOSTS: one AI seat per empty place on each side, as clan tags, so
-- a lone tester gets a real two-sided round. Empty outside Studio.
function RankedMatch.ghosts(): { string }
	local out = {}
	if not ctx or not ctx.ghosts then
		return out
	end
	local humans = { 0, 0 }
	for _, s in ctx.side do
		humans[s] += 1
	end
	for s = 1, 2 do
		for _ = humans[s] + 1, ctx.size do
			table.insert(out, "~R" .. s)
		end
	end
	return out
end

-- Called when bootMatch gives up on the round: nothing is rated.
function RankedMatch.void()
	if ctx then
		ctx.void = true
		ctx.over = true
	end
end

-- The side as a clan tag. A prefix no typed tag can carry (tags are
-- normalised to letters and digits), so a real clan can never collide.
function RankedMatch.tagFor(player: Player): string?
	local s = ctx and ctx.side[player.UserId]
	return s and ("~R" .. s) or nil
end

-- A ranked round's emblem for one empire; nil outside ranked.
function RankedMatch.rankOf(uid: number?): number?
	if not ctx or uid == nil or uid <= 0 then
		return nil
	end
	local plr = Players:GetPlayerByUserId(uid)
	local profile = plr and Data.get(plr)
	if profile then
		return Ranked.ensure(profile).rank
	end
	return nil
end

local function opposingAverage(c: Ctx, side: number): number
	local sum, n = 0, 0
	for uid, s in c.side do
		if s ~= side then
			sum += c.rating[uid] or Ranked.START
			n += 1
		end
	end
	return n > 0 and sum / n or Ranked.START
end

-- Rates one player. Idempotent per user id. Pays every rank's reward the
-- first time that rank is reached, and tells the player's client.
local function settle(player: Player, won: boolean, why: string, unrated: boolean?)
	local c = ctx
	if not c or c.void or c.settled[player.UserId] then
		return
	end
	local side = c.side[player.UserId]
	if not side then
		return
	end
	c.settled[player.UserId] = true
	local profile = Data.get(player)
	if not profile then
		warn("[Ranked] no profile for " .. player.Name .. " -- result not banked")
		return
	end
	local b = Ranked.ensure(profile)
	-- UNRATED WIN: every opponent quit early, so there was no game to rate
	-- (and no alt to farm). The card says so; nothing on the profile moves.
	if unrated then
		state():FireClient(player, "ranked", { void = true, forfeit = true })
		return
	end
	local oldRating, oldRank, oldBest, oldRR = b.rating, b.rank, b.best, b.rr
	local d = Ranked.delta(oldRating, opposingAverage(c, side), won, b.games)
	b.rating = math.max(Ranked.FLOOR, oldRating + d)
	b.games += 1
	if won then
		b.wins += 1
	else
		b.losses += 1
	end
	-- THE VISIBLE RANK MOVES BY RR, pulled toward where the new MMR says
	-- this player belongs (Ranked.applyRR).
	local rrDelta = Ranked.applyRR(b, won)

	-- FIRST TIME AT A RANK PAYS ITS REWARD. One rank per match at most now
	-- (RR carries over at 100), but the loop still pays every rank skipped.
	local rewards = {}
	if b.rank > oldBest then
		if type(profile.patterns) ~= "table" then
			profile.patterns = {}
		end
		for i = oldBest + 1, b.rank do
			local rung = Ranked.rung(i)
			local money = rung.money
			local patternName: string? = nil
			if rung.pattern then
				local def = Patterns.byKey(rung.pattern)
				if def then
					if profile.patterns[def.key] == true then
						money += math.floor(Patterns.price(def) * Ranked.OWNED_REFUND)
					else
						profile.patterns[def.key] = true
						patternName = def.name
					end
				end
			end
			-- A PASS lands as a Money purchase (profile.moneyPasses), which
			-- Monetization.ownsPass reads first; its card shows from the next
			-- server the player joins, where the pass attributes are rebuilt.
			local passName: string? = nil
			if rung.pass then
				if type(profile.moneyPasses) ~= "table" then
					profile.moneyPasses = {}
				end
				-- The pass attribute is Monetization's answer for THIS server
				-- (Robux owners included), and needs no yield inside the tick.
				local owned = profile.moneyPasses[rung.pass] == true
					or (type(profile.passes) == "table" and profile.passes[rung.pass] == true)
					or player:GetAttribute(Products.PASS_ATTR .. rung.pass) == true
				if owned then
					money += math.floor((Products.moneyPrice(rung.pass) or 0) * Ranked.OWNED_REFUND)
				else
					profile.moneyPasses[rung.pass] = true
					passName = rung.passName or rung.pass
				end
			end
			if money > 0 then
				Data.addMoney(player, money)
			end
			table.insert(rewards, { rank = i, money = money, pattern = patternName, pass = passName })
		end
		b.best = b.rank
	end
	Data.markDirty(player)
	task.spawn(Data.flush, player)
	RankedMatch.publish(player, b)

	state():FireClient(player, "ranked", {
		won = won,
		why = why,
		-- What the card shows is RR; the MMR stays hidden.
		oldRR = oldRR,
		rr = b.rr,
		delta = rrDelta,
		oldRank = oldRank,
		rank = b.rank,
		rewards = rewards,
		money = profile.money,
	})
	print(("[Ranked] %s %s mmr %d -> %d (%+d), rank %d %dRR -> %d %dRR (%+d)")
		:format(player.Name, won and "WON" or "LOST", oldRating, b.rating, d, oldRank, oldRR, b.rank, b.rr, rrDelta))
end

-- The round is over: rate everyone still here by their side's result.
function RankedMatch.finish(sim: any)
	local c = ctx
	if not c or c.over then
		return
	end
	c.over = true
	for _, plr in Players:GetPlayers() do
		local side = c.side[plr.UserId]
		if side then
			local p = sim:playerByUserId(plr.UserId)
			local myTeam = p and sim.teamOf[p.id]
			-- The winning SIDE: the sim's winnerTeam, or the side of the
			-- winning empire when only that is named (an owner's /win does
			-- this).
			local winTeam = sim.winnerTeam
			if winTeam == nil and sim.winnerId ~= nil then
				winTeam = sim.teamOf[sim.winnerId]
			end
			local won = myTeam ~= nil and winTeam ~= nil and myTeam == winTeam
			-- Nobody named at all cannot be told apart from a loss on the
			-- board, so the side holding more land takes it.
			if winTeam == nil and p ~= nil and myTeam ~= nil then
				local stats = sim:teamStats()
				-- The OTHER TEAM, by team index: packTeams numbers teams by
				-- seat order, so a side number is not a team number.
				local other = if myTeam == 1 then 2 else 1
				local mine = stats and stats[myTeam]
				local theirs = stats and stats[other]
				won = mine ~= nil and theirs ~= nil and mine.tiles > theirs.tiles
			end
			-- A win over a side that ALL quit inside EARLY_FORFEIT is unrated.
			-- Needs at least one real opponent: a side of Studio ghosts has no
			-- user ids, and "all of nobody quit" must not read as a forfeit.
			local unrated = false
			if won then
				local opponents, quitEarly = 0, 0
				for uid, s in c.side do
					if s ~= side then
						opponents += 1
						local left = c.leftAt[uid]
						if left ~= nil and left - c.startedAt <= RankedMatch.EARLY_FORFEIT then
							quitEarly += 1
						end
					end
				end
				unrated = opponents > 0 and quitEarly == opponents
			end
			settle(plr, won, "end", unrated)
		end
	end
end

-- Leaving a live ranked round is a loss. Runs from ConquestServer's
-- PlayerRemoving, which is registered before ConquestData's release.
-- `seated` is whether this player held an empire in the round. Somebody who
-- arrived too late to be seated (and was sent home) never played, so leaving
-- costs them nothing (prod review, 2026-10-05).
function RankedMatch.abandon(player: Player, phase: string?, seated: boolean?)
	local c = ctx
	if not c or c.over or c.void then
		return
	end
	if phase ~= "spawn" and phase ~= "playing" then
		return
	end
	if not seated or not c.side[player.UserId] then
		return
	end
	c.leftAt[player.UserId] = os.clock()
	settle(player, false, "left")
end

-- Seconds from the round's start inside which a side that ALL leaves hands
-- the other side an UNRATED win (spawn phase included).
RankedMatch.EARLY_FORFEIT = 180

return RankedMatch
