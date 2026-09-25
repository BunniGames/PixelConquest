--!strict
-- Conquest :: /simulate  (server half)
--
-- A headless match harness you drive from the chat box. It builds a SECOND
-- Sim beside the live one, steps it as fast as the frame budget allows, and
-- reports what a round of this size actually costs -- both in milliseconds
-- and in whether it resolves at all.
--
-- Why it exists: the roster size is a performance decision and a balance
-- decision at the same time, and neither is observable by playing one round.
-- Config.TARGET_EMPIRES is 72 now (a full server is 24 players + 48 AI),
-- 4.5x the 16 it used to be; this is how you find out what that did.
--
--   /simulate                      one match at the full-server shape
--   /simulate 3                    three matches
--   /simulate china trio           positional map and mode
--   /simulate map=us mode=ffa      the same, spelled out
--   /simulate humans=0 bots=72     an empty server's roster
--   /simulate all                  one match on every map in the rotation
--   /simulate sweep                every map x every mode (12 matches)
--   /simulate stop                 abort a run in progress
--   /simulate help
--
-- Full detail goes to the server Output; the same lines go to the chat of
-- whoever asked, so it is readable without leaving the game.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Config = require(Shared.Config)
local Maps = require(Shared.Maps)
local Modes = require(Shared.Modes)
local Scenarios = require(Shared.Scenarios)
local Sim = require(Shared.Sim)
-- THE ECONOMY THAT OUTLIVES THE ROUND. Its coefficients were fitted against
-- this harness, so it reports its own payouts here as a matter of course: a
-- balance pass that cannot be re-run is a balance pass that goes stale the
-- first time anything else changes. The tracker attached below is the SAME one
-- ConquestServer runs, so these figures are the money players receive rather
-- than an estimate of it.
local Money = require(Shared.Money)

-- ================================================================ plumbing ==

local folder = ReplicatedStorage:FindFirstChild("ConquestSim")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "ConquestSim"
	folder.Parent = ReplicatedStorage
end

local function remote(name: string): RemoteEvent
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	return r :: RemoteEvent
end

local ReportRE = remote("Report")
local RequestRE = remote("Request")

-- Registered so the client can catch the typed command through an API that
-- is guaranteed to fire there. Parented to TextChatService so it replicates.
local cmd = TextChatService:FindFirstChild("SimulateCommand")
if not cmd then
	local c = Instance.new("TextChatCommand")
	c.Name = "SimulateCommand"
	c.PrimaryAlias = "/simulate"
	c.SecondaryAlias = "/sim"
	c.Parent = TextChatService
	cmd = c
end

-- ================================================================== output ==

local requester: Player? = nil

local function emit(line: string)
	print("[sim] " .. line)
	if requester and requester.Parent then
		ReportRE:FireClient(requester, line)
	end
end

-- Thousands separators. Every figure here is compared against another figure
-- on the line above it, and "88102" next to "9140" is not a comparison.
local function fmt(n: number): string
	local s = tostring(math.floor(n + 0.5))
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, -4)
	end
	return s .. out
end

local function pct(sorted: { number }, p: number): number
	if #sorted == 0 then
		return 0
	end
	return sorted[math.clamp(math.ceil(p * #sorted), 1, #sorted)]
end

-- =================================================================== state ==

local running = false
local cancelRun = false

-- ================================================================== match ==

export type Opts = {
	map: string,
	mode: string,
	humans: number,
	bots: number,
	seed: number,
	minutes: number,
	slice: number,
	hthink: number,
	collapse: number?,
	collapseShare: number?,
	-- False when the caller pinned the count with bots=. True means runMatch
	-- derives it from the map, exactly as the live server does.
	autoBots: boolean?,
}

-- One match, start to finish. Returns a plain table of measurements.
--
-- Human empires are modelled by running the SAME AI on them at a faster
-- cadence with `isBot` left false, which is the part that matters: the income
-- loop scales a bot's growth by BOT_GROWTH_SCALE, so an empire that is not
-- flagged as a bot earns at full rate and therefore attacks with a real
-- player's weight. It is not a model of how a person chooses targets -- it is
-- a model of the LOAD a person puts on the server, which is what this
-- measures.
local function runMatch(o: Opts): { [string]: any }
	local genStart = os.clock()
	local sim = Sim.new(o.map, o.seed, o.mode)
	local genMs = (os.clock() - genStart) * 1000

	local humanIds: { number } = {}
	for i = 1, o.humans do
		local p = sim:addPlayer("Player " .. i, false, nil)
		if p then
			table.insert(humanIds, p.id)
		end
	end
	-- Land-scaled roster, matching ConquestServer.startRound. Assigned back to
	-- o.bots so the collapseshare denominator, rosterSize and the result row
	-- all see the count that actually spawned. Re-derived per match, which is
	-- what `sweep` needs; bots= pins it and skips this.
	-- A HISTORICAL ROUND'S ROSTER IS THE SCENARIO'S, exactly as in
	-- ConquestServer.startRound: every nation is an AI from the first tick and
	-- the "humans" here, who never click, are handed the biggest nations at
	-- the end of the spawn phase (Sim.commitHistorical). bots= is ignored.
	local scenario = if Modes.isHistorical(o.mode) then Scenarios.forMap(o.map, o.mode) else nil
	if scenario then
		sim:loadScenario(scenario)
		o.bots = #scenario.NATIONS
	else
		if o.autoBots then
			local roster = math.clamp(
				math.floor(sim.playableLand / Config.LAND_PER_EMPIRE + 0.5),
				Config.MIN_EMPIRES,
				Config.TARGET_EMPIRES
			)
			o.bots = math.clamp(roster - o.humans, 0, Config.NUM_BOTS)
			-- A map that states its own AI count (Maps.MapData.BOTS -- the World
			-- map, 50) gets it here too, so /simulate measures the round the
			-- server actually runs. Same clamp as ConquestServer.startRound.
			local mapBots = tonumber((Maps.get(o.map) :: any).BOTS)
			if mapBots then
				o.bots = math.clamp(math.min(mapBots, Config.TARGET_EMPIRES - o.humans), 0, Config.NUM_BOTS)
			end
		end
		for i = 1, o.bots do
			sim:addPlayer("AI " .. i, true, nil)
		end
	end

	-- Override the absorb-a-broken-empire threshold without touching Config,
	-- so it can be swept in one run instead of one edit-and-restart per value.
	-- `collapseshare` expresses it the way it should be thought about: as a
	-- share of what ONE empire's land would be if the map were split evenly.
	-- The shipped constant is a share of the WHOLE map, which is the same
	-- thing only at a fixed roster size.
	if o.collapse then
		sim.collapseTiles = math.max(1, math.floor(o.collapse))
	elseif o.collapseShare then
		sim.collapseTiles = math.max(1,
			math.floor(sim.playableLand / math.max(1, o.humans + o.bots) * o.collapseShare))
	end
	local collapseTiles = sim.collapseTiles

	sim.phase = "spawn"
	sim.phaseTick = 0

	local maxTicks = math.floor(o.minutes * 60 * Config.TICK_RATE)
	local times: { number } = {}
	local changesSum, changesPeak = 0, 0
	local attackSum, attackPeak, samples = 0, 0, 0
	local borderPeak = 0
	local landGrabTick: number? = nil
	local firstDeathTick: number? = nil
	local rosterSize = o.humans + o.bots
	local liveNow = rosterSize
	-- The tick the spawn phase ends on is not a gameplay tick and it is by far
	-- the most expensive one in the match: it places every empire's starting
	-- blob at once, so it both costs real milliseconds and dumps tens of
	-- thousands of tiles into one delta. Folded into the distribution it would
	-- own "worst tick" and "peak delta" in every run and hide whatever the
	-- match itself did, so it is measured separately and reported on its own
	-- line. (This is the same figure that was once mistaken for a networking
	-- problem in play.)
	local spawnMs, spawnChanges = 0, 0

	-- Attached before the first step, exactly as ConquestServer attaches it in
	-- startRound, and sampled on the same beat. Its cost is inside the tick
	-- timings below on purpose: it runs on the live server too, and a
	-- measurement that excludes it would be measuring a different loop.
	local money = Money.track(sim)

	local wall0 = os.clock()
	local sliceStart = wall0
	local lastReport = wall0

	while sim.phase ~= "ended" and sim.tick < maxTicks and not cancelRun do
		local wasPlaying = sim.phase == "playing"
		local t = os.clock()
		sim:step()
		money:sample()
		-- Timed INSIDE the tick, because on the live server a human's attack
		-- lands in the same 100 ms slot the tick does.
		if sim.phase == "playing" then
			for _, id in humanIds do
				local p = sim.players[id]
				if p and p.alive and p.spawned and (sim.tick + p.thinkOffset) % o.hthink == 0 then
					Sim.botThink(sim, p)
				end
			end
		end
		local ms = (os.clock() - t) * 1000

		if wasPlaying then
			table.insert(times, ms)
			changesPeak = math.max(changesPeak, sim.changeCount)
			changesSum += sim.changeCount
		elseif sim.phase == "playing" then
			spawnMs = ms
			spawnChanges = sim.changeCount
		end
		-- The transport owns clearing this. Nothing is transporting anything
		-- here, so the harness has to, or `changes` grows without bound.
		sim:drainChanges()

		if wasPlaying and sim.tick % 10 == 0 then
			samples += 1
			local live, owned, border = 0, 0, 0
			for _, id in sim.playerOrder do
				local p = sim.players[id]
				if p then
					owned += p.tileCount
					border += p.borderCount
					if p.alive and p.spawned then
						live += 1
					end
				end
			end
			liveNow = live
			local atk = 0
			for _, k in sim.attacks do
				if k.active then
					atk += 1
				end
			end
			attackSum += atk
			attackPeak = math.max(attackPeak, atk)
			borderPeak = math.max(borderPeak, border)
			if not landGrabTick and owned >= sim.playableLand * 0.98 then
				landGrabTick = sim.tick
			end
			if not firstDeathTick and live < rosterSize then
				firstDeathTick = sim.tick
			end
		end

		if os.clock() - sliceStart >= o.slice then
			task.wait()
			sliceStart = os.clock()
			if sliceStart - lastReport >= 20 then
				lastReport = sliceStart
				local n = #times
				local from = math.max(1, n - 599)
				local s = 0
				for i = from, n do
					s += times[i]
				end
				emit(("    ... %.1f sim-min, %d/%d alive, %.2f ms/tick")
					:format(sim.tick * Config.TICK_DT / 60, liveNow, rosterSize,
						s / math.max(1, n - from + 1)))
			end
		end
	end

	local wall = os.clock() - wall0
	local n = #times
	local sum = 0
	for _, v in times do
		sum += v
	end
	table.sort(times)

	local winner = sim.winnerId and sim.players[sim.winnerId]
	local alive, eliminated, collapsed = 0, 0, 0
	for _, id in sim.playerOrder do
		local p = sim.players[id]
		if p and p.spawned then
			if p.alive then
				alive += 1
			else
				eliminated += 1
				-- killedBy is set by collapsePlayer and by nothing else, so it
				-- separates "absorbed whole the moment it dipped under the bar"
				-- from "ground down to the last tile". Which of the two is
				-- doing the killing is the difference between a war and a
				-- cascade, and the totals look identical either way.
				if p.killedBy then
					collapsed += 1
				end
			end
		end
	end

	-- In a team mode the number that ended the round is the TEAM's share, not
	-- the top member's -- printing the member's makes every team result look
	-- like a squeaker.
	local teamShare = 0
	if sim.teamCount > 0 then
		local stats = sim:teamStats()
		if stats then
			for _, s in stats do
				teamShare = math.max(teamShare, s.tiles / sim.playableLand)
			end
		end
	end

	-- ---- what the round paid ------------------------------------------------
	-- Over the HUMAN seats only: they are the ones with a profile to bank it
	-- in, and they are also the empires that earn at full rate, so folding the
	-- bot roster in would halve every figure and describe nobody.
	money:finish()
	local purses: { number } = {}
	local winPurse = 0
	for _, id in humanIds do
		local st = money:statsFor(id)
		if st then
			local a = Money.award(st)
			table.insert(purses, a.total)
			if st.won then
				winPurse = math.max(winPurse, a.total)
			end
		end
	end
	table.sort(purses)
	local purseSum = 0
	for _, v in purses do
		purseSum += v
	end
	local elapsed = sim.tick * Config.TICK_DT
	local purseMean = purseSum / math.max(1, #purses)

	return {
		money = purseMean,
		moneyP10 = pct(purses, 0.10),
		moneyP50 = pct(purses, 0.50),
		moneyP90 = pct(purses, 0.90),
		moneyWin = winPurse,
		-- THE FIGURE THE ECONOMY IS ACTUALLY BALANCED ON. Matches in this
		-- rotation run from five minutes to fifty, so what a round pays says
		-- nothing on its own -- if one map pays twice as much per HOUR, that is
		-- the map the board gets farmed for, and no amount of tuning the payout
		-- itself fixes it. Compare this column across maps, not the one above.
		moneyRate = purseMean / math.max(1 / 60, elapsed / 3600),

		map = o.map,
		mode = o.mode,
		seed = o.seed,
		humans = o.humans,
		bots = o.bots,
		playableLand = sim.playableLand,
		genMs = genMs,
		ticks = sim.tick,
		minutes = elapsed / 60,
		wall = wall,
		mean = sum / math.max(n, 1),
		p50 = pct(times, 0.5),
		p95 = pct(times, 0.95),
		p99 = pct(times, 0.99),
		worst = times[n] or 0,
		winnerName = winner and winner.name or "nobody",
		winnerShare = winner and (winner.tileCount / sim.playableLand) or 0,
		teams = sim.teamCount,
		teamShare = teamShare,
		alive = alive,
		eliminated = eliminated,
		collapsed = collapsed,
		collapseTiles = collapseTiles,
		cancelled = cancelRun,
		timedOut = elapsed >= Config.HARD_TIME_LIMIT_SECONDS or sim.tick >= maxTicks,
		meanChanges = changesSum / math.max(n, 1),
		peakChanges = changesPeak,
		spawnMs = spawnMs,
		spawnChanges = spawnChanges,
		meanAttacks = attackSum / math.max(samples, 1),
		peakAttacks = attackPeak,
		borderPeak = borderPeak,
		landGrab = landGrabTick and (landGrabTick * Config.TICK_DT / 60) or nil,
		firstDeath = firstDeathTick and (firstDeathTick * Config.TICK_DT / 60) or nil,
	}
end

-- ================================================================= report ==

local BUDGET = Config.TICK_DT * 1000

local function reportMatch(r: { [string]: any })
	-- A team round is decided on the BLOC's share; the winner's own share is
	-- a tenth of it and reads as a nail-biter when it was a rout.
	local share = r.teams > 0 and r.teamShare or r.winnerShare
	local whose = r.teams > 0
		and ("winning bloc on %.0f%% (top member %s, %.0f%%)")
			:format(share * 100, r.winnerName, r.winnerShare * 100)
		or ("%s wins on %.0f%%"):format(r.winnerName, r.winnerShare * 100)

	local outcome
	if r.cancelled then
		outcome = "ABORTED"
	elseif r.timedOut then
		outcome = ("TIMED OUT at %.1f min -- %s, %d still alive"):format(r.minutes, whose, r.alive)
	else
		outcome = ("resolved %.1f min -- %s, %d alive / %d out")
			:format(r.minutes, whose, r.alive, r.eliminated)
	end

	emit(("%s / %s  seed %d   %s playable tiles   mapgen %.0f ms")
		:format(r.map, r.mode, r.seed, fmt(r.playableLand), r.genMs))
	emit("  " .. outcome)
	emit(("  deaths    %d absorbed whole at the %s-tile collapse bar, %d ground out")
		:format(r.collapsed, fmt(r.collapseTiles), r.eliminated - r.collapsed))
	emit(("  phases    land grab closed %s   first elimination %s")
		:format(
			r.landGrab and ("%.1f min"):format(r.landGrab) or "never",
			r.firstDeath and ("%.1f min"):format(r.firstDeath) or "never"
		))
	emit(("  ms/tick   mean %.2f   p50 %.2f   p95 %.2f   p99 %.2f   worst %.1f   (budget %.0f)")
		:format(r.mean, r.p50, r.p95, r.p99, r.worst, BUDGET))
	emit(("  deltas    mean %s tiles/tick   peak %s  (%.0f KB frame)")
		:format(fmt(r.meanChanges), fmt(r.peakChanges), r.peakChanges * 4 / 1024))
	emit(("  load      attacks mean %.1f peak %d   border peak %s tiles")
		:format(r.meanAttacks, r.peakAttacks, fmt(r.borderPeak)))
	emit(("  round-start  the one spawn tick: %.1f ms, %s tiles (%.0f KB) -- excluded above")
		:format(r.spawnMs, fmt(r.spawnChanges), r.spawnChanges * 4 / 1024))
	emit(("  money     mean %s   p10 %s / p50 %s / p90 %s   winner %s")
		:format(fmt(r.money), fmt(r.moneyP10), fmt(r.moneyP50), fmt(r.moneyP90), fmt(r.moneyWin)))
	emit(("            %s an hour per seat  (anchor %s a game)")
		:format(fmt(r.moneyRate), fmt(Money.ANCHOR)))
	emit(("  cost      %d ticks in %.0f s wall  (%.0fx real time)")
		:format(r.ticks, r.wall, (r.ticks * Config.TICK_DT) / math.max(r.wall, 0.001)))
end

local function reportSummary(all: { { [string]: any } })
	if #all < 2 then
		return
	end
	local meanSum, worstMax, p95Max, minSum, resolved = 0, 0, 0, 0, 0
	local paySum, rateLo, rateHi = 0, math.huge, 0
	local lowRun, highRun = "", ""
	for _, r in all do
		meanSum += r.mean
		minSum += r.minutes
		worstMax = math.max(worstMax, r.worst)
		p95Max = math.max(p95Max, r.p95)
		if not r.timedOut and not r.cancelled then
			resolved += 1
		end
		paySum += r.money
		if r.moneyRate < rateLo then
			rateLo, lowRun = r.moneyRate, r.map .. "/" .. r.mode
		end
		if r.moneyRate > rateHi then
			rateHi, highRun = r.moneyRate, r.map .. "/" .. r.mode
		end
	end
	emit("----------------------------------------------------------------")
	emit(("ACROSS %d MATCHES   mean %.2f ms/tick   worst p95 %.2f   worst tick %.1f   (budget %.0f)")
		:format(#all, meanSum / #all, p95Max, worstMax, BUDGET))
	emit(("                   mean length %.1f min   resolved %d/%d")
		:format(minSum / #all, resolved, #all))
	-- THE FARM CHECK. If the spread is wide, players will work out which pair
	-- pays best per hour long before any of us do, and queue for nothing else.
	-- Under 1.5x is fine; past 2x the SURVIVED weight in Money is the dial.
	emit(("                   money mean %s a game   %s..%s an hour  (%.2fx: %s to %s)")
		:format(
			fmt(paySum / #all),
			fmt(rateLo),
			fmt(rateHi),
			rateHi / math.max(1, rateLo),
			lowRun,
			highRun
		))
end

-- The one line a benchmark owes you: is this shippable.
local function verdict(all: { { [string]: any } })
	local worst, p95, timeouts = 0, 0, 0
	for _, r in all do
		worst = math.max(worst, r.worst)
		p95 = math.max(p95, r.p95)
		if r.timedOut then
			timeouts += 1
		end
	end
	local notes = {}
	if worst > BUDGET then
		table.insert(notes, ("a tick BLEW the %.0f ms budget (worst %.1f)"):format(BUDGET, worst))
	elseif p95 > BUDGET * 0.5 then
		table.insert(notes, ("p95 is over half the budget (%.1f of %.0f)"):format(p95, BUDGET))
	end
	if timeouts > 0 then
		table.insert(notes, ("%d/%d matches never resolved"):format(timeouts, #all))
	end
	if #notes == 0 then
		emit(("VERDICT  fine: worst tick %.1f ms against a %.0f ms budget, every match resolved.")
			:format(worst, BUDGET))
	else
		emit("VERDICT  " .. table.concat(notes, "; "))
	end
end

-- =================================================================== args ==

local HELP = {
	"/simulate -- headless match benchmark",
	"  /simulate [n]                 n matches at the full-server shape",
	"  /simulate <map> <mode>        us | europe | china | medit  x  ffa | duo | trio",
	"  /simulate all                 one match on each map",
	"  /simulate sweep               every map x every mode",
	"  humans=24 bots=48             roster (default: a full server)",
	"  seed=101 minutes=30 hthink=3  match controls",
	"  collapseshare=0.16            absorb bar as a share of ONE empire's fair land",
	"  collapse=9051                 ...or as a flat tile count",
	"  slice=30                      ms of work between yields; lower is politer",
	"  /simulate stop                abort the run in progress",
}

local function isMap(w: string): boolean
	for _, m in Maps.ORDER do
		if m == w then
			return true
		end
	end
	return false
end

local function isMode(w: string): boolean
	-- `exists` rather than ORDER: the historical mode is a real mode that
	-- stays out of the rotation, and it is worth measuring headless too.
	return Modes.exists(w)
end

local function parse(text: string)
	local humans = 24
	local o = {
		map = nil :: string?,
		mode = nil :: string?,
		humans = nil :: number?,
		bots = nil :: number?,
		matches = 1,
		seed = nil :: number?,
		-- NOT Config.HARD_TIME_LIMIT_SECONDS / 60. That is upstream's
		-- 170-minute wall now, which would cap every simulated match at
		-- 102,000 ticks (~17 minutes of WALL CLOCK each) and turn `sweep`
		-- into hours. Pass minutes= to go longer.
		minutes = 80,
		slice = 0.030,
		hthink = 3,
		spread = nil :: string?,
		collapse = nil :: number?,
		collapseShare = nil :: number?,
	}
	for word in text:gmatch("%S+") do
		local lower = string.lower(word)
		local k, v = string.match(lower, "^(%a+)=(.+)$")
		if k then
			local num = tonumber(v)
			if k == "map" then
				o.map = v
			elseif k == "mode" then
				o.mode = v
			elseif k == "humans" or k == "players" then
				o.humans = num
			elseif k == "bots" or k == "npcs" or k == "ai" then
				o.bots = num
			elseif k == "matches" or k == "n" then
				o.matches = num or 1
			elseif k == "seed" then
				o.seed = num
			elseif k == "minutes" or k == "max" then
				o.minutes = num or o.minutes
			elseif k == "slice" then
				o.slice = (num or 30) / 1000
			elseif k == "hthink" then
				o.hthink = math.max(1, math.floor(num or 3))
			elseif k == "collapse" then
				o.collapse = num
			elseif k == "collapseshare" then
				o.collapseShare = num
			end
		elseif tonumber(lower) then
			o.matches = math.floor(tonumber(lower) :: number)
		elseif lower == "all" or lower == "sweep" then
			o.spread = lower
		elseif isMap(lower) then
			o.map = lower
		elseif isMode(lower) then
			o.mode = lower
		end
	end
	humans = o.humans or 24
	-- Same fill rule the live server uses, so the default shape of a
	-- /simulate run is the shape of a real full server and not a guess.
	-- The server's roster now depends on the MAP's playable land, which parse()
	-- cannot know -- o.map may still be nil here, and `sweep` reuses one
	-- options table across every map in the rotation. So the real fill happens
	-- per match in runMatch, and this only seeds a ceiling.
	o.autoBots = o.bots == nil
	local bots = o.bots or math.clamp(Config.TARGET_EMPIRES - humans, 0, Config.NUM_BOTS)
	o.humans = math.max(0, math.floor(humans))
	o.bots = math.max(0, math.floor(bots))
	o.matches = math.clamp(math.floor(o.matches), 1, 24)
	return o
end

-- ==================================================================== run ==

local function buildPlan(o): { { map: string, mode: string, seed: number } }
	local plan = {}
	local maps = o.map and { o.map } or Maps.ORDER
	local modes = o.mode and { o.mode } or Modes.ORDER

	if o.spread == "sweep" then
		for _, m in maps do
			for _, md in modes do
				table.insert(plan, { map = m, mode = md, seed = 0 })
			end
		end
	elseif o.spread == "all" then
		for _, m in maps do
			table.insert(plan, { map = m, mode = o.mode or "ffa", seed = 0 })
		end
	else
		for _ = 1, o.matches do
			table.insert(plan, { map = o.map or Maps.ORDER[1], mode = o.mode or "ffa", seed = 0 })
		end
	end
	for i, entry in plan do
		-- Deterministic when a seed is given, so a run can be repeated exactly
		-- after a Config change; otherwise spread so repeats are not clones.
		entry.seed = o.seed and (o.seed + i - 1) or math.random(1, 1000000)
	end
	return plan
end

local function run(text: string)
	local o = parse(text)
	local plan = buildPlan(o)

	-- Round the roster up to even sides. An uneven team is not a small
	-- unfairness in this game -- the side with the spare member has one fewer
	-- front to hold -- so measuring an uneven one measures the wrong game.
	--
	-- IT IS THE HUMANS THAT GET ROUNDED, NOT THE AI. A full AI is neutral and
	-- holds no team (Sim.addPlayer), so padding the bot count levels nothing;
	-- the sides in a team match are exactly the simulated humans.
	local perMatch = {}
	local perMatchHumans = {}
	for _, entry in plan do
		local teams = Modes.get(entry.mode).TEAMS
		local humans = o.humans
		if teams > 0 then
			-- At least one member a side, or a team match with no humans in it
			-- has no teams in it at all and would quietly measure a free-for-all.
			humans = math.max(teams, math.ceil(humans / teams) * teams)
		end
		table.insert(perMatch, o.bots)
		table.insert(perMatchHumans, humans)
	end

	emit("================================================================")
	emit(("Conquest /simulate -- %d match%s"):format(#plan, #plan == 1 and "" or "es"))
	emit(("roster %d empires = %d players + %d AI     (Config.TARGET_EMPIRES %d)")
		:format(perMatchHumans[1] + perMatch[1], perMatchHumans[1], perMatch[1], Config.TARGET_EMPIRES))
	emit(("humans act every %d ticks (%.1f/s); cap %.0f min/match; %.0f ms slices")
		:format(o.hthink, Config.TICK_RATE / o.hthink, o.minutes, o.slice * 1000))
	emit("the live round is held still for the duration")
	emit("----------------------------------------------------------------")

	local results = {}
	for i, entry in plan do
		if cancelRun then
			break
		end
		local r = runMatch({
			map = entry.map,
			mode = entry.mode,
			humans = perMatchHumans[i],
			bots = perMatch[i],
			seed = entry.seed,
			minutes = o.minutes,
			slice = o.slice,
			hthink = o.hthink,
			collapse = o.collapse,
			collapseShare = o.collapseShare,
		})
		table.insert(results, r)
		reportMatch(r)
		if i < #plan then
			emit("  ---")
		end
	end

	reportSummary(results)
	if #results > 0 then
		verdict(results)
	end
	emit("================================================================")
end

-- ================================================================ command ==

local function allowed(player: Player?): boolean
	if RunService:IsStudio() then
		return true
	end
	if not player then
		return false
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	return false
end

local lastFire: { [number]: number } = {}

local function dispatch(player: Player?, text: string)
	-- The command arrives by up to three routes depending on how chat is
	-- configured; whichever wins, the others must be no-ops.
	local key = player and player.UserId or 0
	local now = os.clock()
	if (lastFire[key] or 0) > now - 0.5 then
		return
	end
	lastFire[key] = now

	if not allowed(player) then
		return
	end

	local args = string.gsub(text, "^%s*/%a+%s*", "")
	local first = string.lower(string.match(args, "^%S+") or "")

	if first == "stop" then
		if running then
			cancelRun = true
			emit("stopping after the current match...")
		else
			emit("nothing running.")
		end
		return
	end
	if first == "help" or first == "?" then
		requester = player
		for _, line in HELP do
			emit(line)
		end
		return
	end
	if running then
		emit("already running -- /simulate stop to abort.")
		return
	end

	running = true
	cancelRun = false
	requester = player
	-- Hold the live round still. Its Heartbeat loop would otherwise be
	-- competing with the harness on the same thread, which is exactly the
	-- contention the measurement is trying to report on.
	_G.ConquestBenchPause = true

	task.spawn(function()
		local ok, err = pcall(run, args)
		_G.ConquestBenchPause = false
		running = false
		cancelRun = false
		if not ok then
			emit("ERROR: " .. tostring(err))
		end
		requester = nil
	end)
end

RequestRE.OnServerEvent:Connect(function(player, text)
	if typeof(text) == "string" and #text < 300 then
		dispatch(player, text)
	end
end)

-- Fires here on some chat configurations and not others; harmless either way.
;(cmd :: TextChatCommand).Triggered:Connect(function(source, text)
	local player = source and Players:GetPlayerByUserId(source.UserId)
	dispatch(player, text)
end)

Players.PlayerAdded:Connect(function(player)
	player.Chatted:Connect(function(message)
		if string.match(string.lower(message), "^/sim") then
			dispatch(player, message)
		end
	end)
end)
for _, player in Players:GetPlayers() do
	player.Chatted:Connect(function(message)
		if string.match(string.lower(message), "^/sim") then
			dispatch(player, message)
		end
	end)
end

-- Entry point for anything that is not a chat box: the command bar, a plugin,
-- an MCP call. It is a BindableFunction rather than a _G entry because those
-- callers do not share the server's global table -- only the data model.
--   ReplicatedStorage.ConquestSim.Run:Invoke("map=us humans=24 bots=48")
local runBF = folder:FindFirstChild("Run")
if not runBF then
	local b = Instance.new("BindableFunction")
	b.Name = "Run"
	b.Parent = folder
	runBF = b
end
;(runBF :: BindableFunction).OnInvoke = function(text: string?)
	dispatch(nil, "/simulate " .. (text or ""))
	return "started -- results print to the server Output"
end

print("[sim] /simulate ready -- chat /simulate help, or ReplicatedStorage.ConquestSim.Run:Invoke(args)")
