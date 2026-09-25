--!strict
-- Conquest :: /lose  (server half)
--
-- Owner-only: end YOUR OWN empire where it stands, so the losing sequence can
-- be watched without being ground down for ten minutes first. Built
-- 2026-09-17, beside /endgame -- which ends the ROUND for everybody; this ends
-- only you, and the match plays on around you exactly as it does when a real
-- empire falls at minute four.
--
--   /lose         your empire falls to whoever holds the most of your border
--   /lose alone   nobody is credited -- your land goes back to open ground
--   /lose help
--
-- THE DEFAULT HANDS THE LAND TO A NEIGHBOUR because that is how a person
-- actually loses: somebody grinds you down and your colour becomes theirs,
-- your treasury becomes theirs, and they get the "has fallen  -  +gold" line
-- for it. `alone` is the sim's OTHER death -- the one a crater or a stray
-- retreat leaves, with no claimant -- and it reads completely differently on
-- the map, which is why both are reachable from here.
--
-- IT DRAWS NOTHING ITSELF. The skull on the tile you died on, the payout
-- receipt, the revive offer, a tutorial's fail card, the conqueror's payday --
-- every one of those comes out of Sim.eliminate along the path a real death
-- takes. A shortcut that put the card up by hand would prove the card exists
-- and nothing else; the thing worth testing is the path in front of it.
--
-- The live Sim is read out of `_G.ConquestSim` EVERY time rather than cached,
-- for the reason /gold spells out: every round builds a new one, and a cached
-- Sim is a cheat quietly writing into last round's dead match.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local TileMap = require(Shared:WaitForChild("TileMap"))

local HELP = {
	"/lose -- owner-only: knock your own empire out, to watch the losing sequence",
	"  /lose        fall to whoever holds the most of your border",
	"  /lose alone  fall to nobody -- your land goes back to open ground",
}

-- ================================================================ plumbing ==

local folder = ReplicatedStorage:FindFirstChild("ConquestCheats")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "ConquestCheats"
	folder.Parent = ReplicatedStorage
end

-- ITS OWN PAIR, like /endgame's and /attackme's: the other cheat scripts
-- answer every Request they see, so sharing a remote would have one of them
-- try to read "alone" as an amount of gold.
local function remote(name: string): RemoteEvent
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	return r :: RemoteEvent
end

local ReportRE = remote("LoseReport")
local RequestRE = remote("LoseRequest")

-- Re-stated on every boot rather than only on creation, so an instance edited
-- by hand in the explorer repairs itself instead of answering the wrong word.
local cmd: TextChatCommand
do
	local found = TextChatService:FindFirstChild("LoseCommand")
	if found and found:IsA("TextChatCommand") then
		cmd = found
	else
		cmd = Instance.new("TextChatCommand")
		cmd.Name = "LoseCommand"
		cmd.Parent = TextChatService
	end
	cmd.PrimaryAlias = "/lose"
	cmd.SecondaryAlias = "/surrender"
end

local function tell(player: Player?, line: string)
	print("[lose] " .. line)
	if player and player.Parent then
		ReportRE:FireClient(player, line)
	end
end

-- ================================================================== captor ==

-- Whoever holds the most ground along your border: the empire that would have
-- finished you had this been a war instead of a command. One pass over the
-- border set, which is thousands of tiles at worst and runs at most once per
-- typed command.
--
-- A TEAMMATE IS NOT A CAPTOR. Being absorbed by your own bloc is not what
-- losing looks like, and the fallback below would rather reach across the map
-- than hand your country to the people you were playing with.
local function borderFoe(sim: any, victim: any): any?
	local map = sim.map
	local nbuf = table.create(4)
	local counts: { [number]: number } = {}
	local best: any = nil
	local bestN = 0
	for tile in victim.border do
		local n = TileMap.neighbors4(tile, nbuf)
		for k = 1, n do
			local id = TileMap.ownerAt(map, nbuf[k])
			if id ~= 0 and id ~= victim.id then
				local other = sim.players[id]
				if
					other ~= nil
					and other.alive
					and not (sim.sameTeam ~= nil and sim:sameTeam(victim.id, id))
				then
					local c = (counts[id] or 0) + 1
					counts[id] = c
					if c > bestN then
						bestN = c
						best = other
					end
				end
			end
		end
	end
	return best
end

-- Nobody touches you -- an island, or a country whose whole frontier is open
-- land. The biggest empire on the map takes it instead: somebody has to be
-- credited or the death reads as the `alone` one, and the largest is the one a
-- long round was most likely to end with anyway.
local function biggestFoe(sim: any, victim: any): any?
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

-- ================================================================ dispatch ==

-- Studio is open season; a live server allows only the owner. Same gate as
-- /gold, /endgame, /world and /attackme.
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
		tell(player, "/lose is for the owner only.")
		return
	end
	if not player then
		tell(nil, "/lose has to know whose empire to end -- type it in the chat box.")
		return
	end

	local args = string.gsub(text, "^%s*/%a+%s*", "")
	local alone = false
	for word in string.gmatch(args, "%S+") do
		local w = string.lower(word)
		if w == "help" or w == "?" then
			for _, line in HELP do
				tell(player, line)
			end
			return
		elseif w == "alone" or w == "nobody" or w == "none" then
			alone = true
		else
			tell(player, "'" .. w .. "' is not 'alone' -- try /lose help.")
			return
		end
	end

	local sim = _G.ConquestSim
	if not sim then
		tell(player, "no round is running yet.")
		return
	end
	local p = sim:playerByUserId(player.UserId)
	if not p or not p.alive then
		tell(player, "you are not standing in this round.")
		return
	end
	if not p.spawned then
		-- Still the spawn phase, or they never picked a homeland. There is no
		-- empire yet to take away, and no receipt to pay for one.
		tell(player, "you have no empire yet -- pick a homeland first.")
		return
	end

	local tiles = p.tileCount or 0
	local captor = nil
	if not alone then
		captor = borderFoe(sim, p) or biggestFoe(sim, p)
	end

	if not sim:eliminate(p.id, captor and captor.id or 0) then
		tell(player, "the sim would not take the elimination -- nothing changed.")
		return
	end

	if captor then
		tell(
			player,
			string.format(
				"you have fallen to %s -- %d tiles change hands over the next few seconds.",
				tostring(captor.name or ("empire " .. tostring(captor.id))),
				tiles
			)
		)
	else
		tell(player, string.format("you have fallen to nobody -- %d tiles go back to open ground.", tiles))
	end
	-- WHAT TO WATCH FOR, because the whole point of the command is the thing
	-- that happens NEXT and it lands a tick later on channels of its own.
	tell(player, "  watch for: the skull, then the payout receipt and the revive offer.")
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

-- WORD, NOT PREFIX -- the same correction /world and /attackme carry, so
-- /loser is not caught by it.
local function isCommand(lower: string): boolean
	for _, word in { "/lose", "/surrender" } do
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

print("[lose] /lose ready -- chat /lose help")
