--!strict
-- Conquest :: /attackme  (server half)
--
-- Owner-only: point a warhead at your OWN empire, so the anti-nuke tower can be
-- watched doing its job. Built 2026-09-15, the day the tower got its iron-dome
-- icon -- until now the only way to see an interception was to wait for a bot to
-- build a silo, get rich enough to fire, and happen to fire at you.
--
--   /attackme            one atom bomb at the middle of your territory
--   /attackme 5          a salvo of five, spaced TIGHTER than the reload
--   /attackme 5 slow     the same salvo spaced PAST the reload instead
--   /attackme sam        aim at one of your own launchers, not your centre
--   /attackme mega       fire the MEGA NUKE instead of an atom bomb
--   /attackme help
--
-- A SALVO IS THE REAL TEST, and this is the whole reason the count exists. A
-- launcher engages ONE warhead at a time and reloads over SAM_COOLDOWN (90
-- ticks, 9s). A single shot therefore only ever proves the happy path. The
-- tight salvo is how you find the number that gets through; `slow` is the
-- CONTROL -- spaced past the reload, every one of them should die, and if they
-- do not the fault is the launcher rather than the spacing.
--
-- `mega` WAS THE ONLY ROUTE TO A MEGA NUKE until 2026-09-22, when the MEGA
-- NUKE card landed on the rail for holders of the Mega Nuke pass (HUD
-- RAIL_ACTIONS.meganuke; ConquestServer's nuke intent accepts Units.MEGA_NUKE
-- from a holder). This stays the route that needs no pass and no 3M gold, so
-- it is still how the weapon gets watched landing -- and, since the tower is
-- what this whole script is for, how it gets watched being stopped.
--
-- THE SHOT IS FREE, AND IT IS NOT YOURS. It is charged to a hostile empire
-- through `freeNukes` -- the same token the "+1 Nuke!" product spends, consumed
-- at the charge in nukeTick -- so a test never drains a bot's treasury or makes
-- it skip a real move. Unfired tokens are handed back below.
--
-- THE LAUNCH POINT IS FORCED FAR AWAY, via launchNuke's `src`. This matters
-- more than it looks: Config.NUKE_REQUIRES_SILO is false, so a silo-free shot
-- starts at Nukes.nearestOwnedTile -- the attacker's tile CLOSEST to the target,
-- which is the shortest arc on the map and the one least likely to cross your
-- ring. Forcing a long arc is what gives the launcher its chance, and with
-- CFG.INTERCEPT_ANYWHERE every tile of that arc is targetable.
--
-- The live Sim is read out of `_G.ConquestSim` EVERY time rather than cached,
-- for the reason /gold spells out: every round builds a new one, and a cached
-- Sim is a cheat quietly writing into last round's dead match.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Config = require(Shared:WaitForChild("Config"))
local Nukes = require(Shared:WaitForChild("Nukes"))
local Units = require(Shared:WaitForChild("Units"))

local W = Config.MAP_W
local H = Config.MAP_H

-- Enough warheads to saturate a belt, few enough that a slip of the keyboard
-- cannot erase the map. Ten atom bombs is about 300 tiles of crater.
local MAX_SHOTS = 12
-- A mega nuke erases four times an atom bomb's ground, so a mega salvo is
-- capped at a QUARTER of the count -- the same ceiling on how much of the map
-- one mistyped line can glass, which is the number MAX_SHOTS was chosen for.
local MAX_MEGA_SHOTS = 3
-- The arc has to be long enough to enter the ring well before the target. A
-- level-1 tower reaches 70 tiles, so this clears it with room even on a small
-- map -- and it is only a FLOOR: a genuinely distant enemy launches from where
-- they actually are.
local MIN_ARC = 180

local HELP = {
	"/attackme -- owner-only: nuke yourself, to test the anti-nuke tower",
	"  /attackme          one atom bomb at your territory centre",
	"  /attackme 5        a salvo of 5, spaced TIGHTER than the launcher reloads",
	"  /attackme 5 slow   spaced PAST the reload -- every one should be stopped",
	"  /attackme sam      aim at one of your own launchers instead",
	"  /attackme mega     a MEGA nuke -- twice the radius, four times the ground",
}

-- ================================================================ plumbing ==

local folder = ReplicatedStorage:FindFirstChild("ConquestCheats")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "ConquestCheats"
	folder.Parent = ReplicatedStorage
end

-- ITS OWN PAIR, like /world's and /endgame's: the other cheat scripts answer
-- every Request they see, so sharing a remote would have one of them read a
-- salvo count as an amount of gold.
local function remote(name: string): RemoteEvent
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	return r :: RemoteEvent
end

local ReportRE = remote("AttackReport")
local RequestRE = remote("AttackRequest")

-- Re-stated on every boot rather than only on creation, so an instance edited
-- by hand in the explorer repairs itself instead of answering the wrong word.
local cmd: TextChatCommand
do
	local found = TextChatService:FindFirstChild("AttackMeCommand")
	if found and found:IsA("TextChatCommand") then
		cmd = found
	else
		cmd = Instance.new("TextChatCommand")
		cmd.Name = "AttackMeCommand"
		cmd.Parent = TextChatService
	end
	cmd.PrimaryAlias = "/attackme"
	cmd.SecondaryAlias = "/nukeme"
end

local function tell(player: Player?, line: string)
	print("[attackme] " .. line)
	if player and player.Parent then
		ReportRE:FireClient(player, line)
	end
end

-- ================================================================== target ==

-- Every finished launcher this empire owns. `underConstruction` is excluded for
-- the reason Sim excludes it everywhere else: a tower still going up has no
-- aura yet, so counting it would promise cover that is not there.
local function launchersOf(sim: any, p: any): { any }
	local out = {}
	for _, u in Units.ofType(sim, Units.SAM_LAUNCHER) do
		if u.active and u.ownerId == p.id and not u.underConstruction then
			table.insert(out, u)
		end
	end
	return out
end

-- The biggest empire that is allowed to shoot at you. Biggest rather than
-- nearest on purpose: it is the one most likely to be far away, which is the
-- longer arc. A teammate is refused here rather than by nukeSpawn, so the
-- reason we hand back names the mode instead of saying "friendly".
local function hostileTo(sim: any, victim: any): any?
	local best: any = nil
	local bestTiles = -1
	for _, id in sim.playerOrder do
		local o = sim.players[id]
		if
			o ~= nil
			and o.alive
			and o.id ~= victim.id
			and o.tileCount > bestTiles
			and not (sim.sameTeam ~= nil and sim:sameTeam(victim.id, o.id))
		then
			bestTiles = o.tileCount
			best = o
		end
	end
	return best
end

-- Push the launch point out from the target along the line running to the
-- attacker, clamped to the map. `MIN_ARC` is a floor and never a cap, so a war
-- on the far side of the world still launches from the far side of the world.
local function launchPoint(dst: number, from: number): number
	local dx = dst % W
	local dy = (dst - dx) // W
	local ax = from % W
	local ay = (from - ax) // W
	local vx = ax - dx
	local vy = ay - dy
	local len = math.sqrt(vx * vx + vy * vy)
	if len < 1 then
		-- Attacker sitting on top of you (or no territory to read): due west is
		-- as good a bearing as any, and the clamp below keeps it on the map.
		vx, vy, len = 1, 0, 1
	end
	local d = math.max(MIN_ARC, len)
	local x = math.clamp(math.round(dx + (vx / len) * d), 0, W - 1)
	local y = math.clamp(math.round(dy + (vy / len) * d), 0, H - 1)
	return y * W + x
end

-- ================================================================ dispatch ==

-- Studio is open season; a live server allows only the owner. Same gate as
-- /gold, /world and /simulate.
local function allowed(player: Player?): boolean
	if RunService:IsStudio() then
		return true
	end
	if not player then
		return false
	end
	return game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
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
		tell(player, "/attackme is for the owner only.")
		return
	end
	if not player then
		tell(nil, "/attackme has to know who to shoot at -- type it in the chat box.")
		return
	end

	local args = string.gsub(text, "^%s*/%a+%s*", "")
	local shots, slow, atSam, mega = 1, false, false, false
	for word in string.gmatch(args, "%S+") do
		local w = string.lower(word)
		local n = tonumber(w)
		if w == "help" or w == "?" then
			for _, line in HELP do
				tell(player, line)
			end
			return
		elseif n then
			shots = math.clamp(math.floor(n), 1, MAX_SHOTS)
		elseif w == "slow" then
			slow = true
		elseif w == "sam" or w == "tower" or w == "dome" then
			atSam = true
		elseif w == "mega" or w == "meganuke" then
			mega = true
		else
			tell(player, "'" .. w .. "' is not a count, 'slow', 'sam' or 'mega' -- try /attackme help.")
			return
		end
	end

	if mega then
		shots = math.min(shots, MAX_MEGA_SHOTS)
	end

	local sim = _G.ConquestSim
	if not sim then
		tell(player, "no round is running yet.")
		return
	end
	if sim.phase ~= "playing" then
		-- A warhead ordered in the spawn phase would be charged against an
		-- empire that does not own ground yet.
		tell(player, "the round is not playing yet.")
		return
	end
	local p = sim:playerByUserId(player.UserId)
	if not p or not p.alive then
		tell(player, "you are not standing in this round.")
		return
	end

	local guns = launchersOf(sim, p)
	local dst: number?
	if atSam then
		if #guns == 0 then
			tell(player, "you own no anti-nuke tower to aim at -- build one (G) first.")
			return
		end
		dst = guns[1].tile
	else
		dst = Nukes.territoryCenter(sim, p)
	end
	if dst == nil then
		tell(player, "you hold no ground to aim at.")
		return
	end

	local foe = hostileTo(sim, p)
	if foe == nil then
		tell(player, "nobody on this map is allowed to shoot at you.")
		return
	end

	local from = Nukes.territoryCenter(sim, foe) or dst
	local src = launchPoint(dst, from)

	-- Tight enough to arrive inside the reload, so shot 2 meets a launcher that
	-- is still busy -- or, with `slow`, comfortably clear of it. Read off the
	-- module rather than restated, because SAM_COOLDOWN is the number this whole
	-- command is built to probe.
	local cd = (Nukes.CFG and Nukes.CFG.SAM_COOLDOWN) or 90
	local spacing = if slow then cd + 20 else math.max(5, cd // 3)

	local utype = if mega then Units.MEGA_NUKE else Units.ATOM_BOMB
	local price = Units.cost(sim, foe.id, utype)

	-- Tokens first, so no shot is ever refused for gold; the unfired ones are
	-- taken back below rather than left in a bot's pocket to surprise you later.
	--
	-- A MEGA NUKE CANNOT RIDE THE TOKEN, and must not be made to. freeNukes is
	-- spent on the atom bomb alone -- both at the order in launchNuke and at the
	-- charge in nukeTick -- and that whitelist is what stops the "+1 Nuke!"
	-- product quietly buying a warhead four times the size. So a mega salvo is
	-- LENT its gold instead and the loan is recalled a second later: ten ticks,
	-- by which time every shot has had the tick on which it charges, so what
	-- comes back is exactly the part the salvo did not spend. Either way the
	-- foe's treasury ends where it started, which is the rule above.
	local lent = 0
	if mega then
		lent = price * shots
		foe.gold += lent
	else
		foe.freeNukes = (foe.freeNukes or 0) + shots
	end

	local fired = 0
	local why: string? = nil
	for i = 1, shots do
		local ok, reason = Nukes.launchNuke(sim, foe.id, utype, dst, src, nil, (i - 1) * spacing)
		if ok then
			fired += 1
		else
			why = reason
		end
	end
	if mega then
		local spent = price * fired
		task.delay(1, function()
			foe.gold = math.max(0, foe.gold - lent + spent)
		end)
	else
		foe.freeNukes = math.max(0, (foe.freeNukes or 0) - (shots - fired))
	end

	if fired == 0 then
		tell(player, "no shot left the pad (" .. (why or "?") .. ").")
		return
	end

	local dt = Config.TICK_DT or 0.1
	tell(
		player,
		string.format(
			"%d %s%s inbound from %s, %d tiles out, %0.1fs apart%s",
			fired,
			mega and "MEGA nuke" or "warhead",
			fired == 1 and "" or "s",
			tostring(foe.name or ("empire " .. tostring(foe.id))),
			math.round(math.sqrt((src % W - dst % W) ^ 2 + ((src - src % W) // W - (dst - dst % W) // W) ^ 2)),
			spacing * dt,
			slow and "  (past the reload -- all should be stopped)" or ""
		)
	)
	-- THE HALF THAT MAKES A MISS LEGIBLE. Without this line, a tower-less empire
	-- watching a crater appear learns nothing about the launcher: the test looks
	-- like it failed when in truth it never ran.
	if #guns == 0 then
		tell(player, "you own NO anti-nuke tower -- nothing will try to stop it. Build one with G.")
	else
		local r = Nukes.samRangeNow(sim, guns[1])
		tell(player, string.format("%d launcher%s up, nearest reaches %d tiles.", #guns, #guns == 1 and "" or "s", math.round(r)))
	end
end

RequestRE.OnServerEvent:Connect(function(player, text)
	if typeof(text) == "string" and #text < 200 then
		dispatch(player, text)
	end
end)

cmd.Triggered:Connect(function(source, text)
	local player = source and Players:GetPlayerByUserId(source.UserId)
	dispatch(player, text)
end)

-- WORD, NOT PREFIX -- the same correction /world carries, so /attackmenow is
-- not caught by it.
local function isCommand(lower: string): boolean
	for _, word in { "/attackme", "/nukeme" } do
		if lower == word or string.sub(lower, 1, #word + 1) == word .. " " then
			return true
		end
	end
	return false
end

local function watch(player: Player)
	player.Chatted:Connect(function(message)
		if isCommand(string.lower(message)) then
			dispatch(player, message)
		end
	end)
end

Players.PlayerAdded:Connect(watch)
for _, player in Players:GetPlayers() do
	watch(player)
end

print("[attackme] /attackme ready -- chat /attackme help")
