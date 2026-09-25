--!strict
-- Conquest :: /testmidjoin  (server half)
--
-- What a FRIEND WHO PRESSED JOIN ON YOU MID-MATCH sees, replayed on your own
-- client so the arrival can be judged without a second account:
--
--   /testmidjoin          arrive as a NEW player: the bot takeover, then the
--                         three lite lesson cards
--   /testmidjoin vet      the same with the cards off. Production never sends a
--                         veteran (MatchmakerServer.followFriend); this run is
--                         for judging the takeover on its own.
--   /testmidjoin help
--
-- Your own empire is handed to a bot wearing a stand-in friend's name and
-- face; you get the spectator init a late arrival gets, and a beat later the
-- takeover runs through the very code PlayerAdded runs for a follower
-- (ConquestServer.followTakeover) -- the fresh init, the camera onto the new
-- land, the lesson cards. What it cannot replay is the lobby's toast and the
-- teleport loading screen in front of all that.
--
-- IT DOES NOTHING ITSELF. Every branch goes through _G.ConquestTestMidJoin,
-- which ConquestServer owns -- the same split as /endgame and /world.
--
-- Owner-only on a live server, open season in Studio: the same gate the other
-- cheats use.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local HELP = {
	"/testmidjoin -- owner-only: replay a friend joining you mid-match, on your own client",
	"  /testmidjoin       arrive as a NEW player -- takeover, then the three lesson cards",
	"  /testmidjoin vet   the same with the cards off (production sends only NEW players; this is for judging the takeover alone)",
	"  needs a running war: /world first, then wait for the spawn phase to end",
}

-- ================================================================ plumbing ==

local folder = ReplicatedStorage:FindFirstChild("ConquestCheats")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "ConquestCheats"
	folder.Parent = ReplicatedStorage
end

-- ITS OWN PAIR, like /endgame's: the other cheat scripts answer every Request
-- they see, so sharing a remote would have them parse "vet" as gold.
local function remote(name: string): RemoteEvent
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	return r :: RemoteEvent
end

local ReportRE = remote("MidJoinReport")
local RequestRE = remote("MidJoinRequest")

local cmd = TextChatService:FindFirstChild("MidJoinCommand")
if not cmd then
	local c = Instance.new("TextChatCommand")
	c.Name = "MidJoinCommand"
	c.Parent = TextChatService
	cmd = c
end
;(cmd :: TextChatCommand).PrimaryAlias = "/testmidjoin"
;(cmd :: TextChatCommand).SecondaryAlias = "/midjoin"

local function tell(player: Player?, line: string)
	print("[midjoin] " .. line)
	if player and player.Parent then
		ReportRE:FireClient(player, line)
	end
end

-- ================================================================ dispatch ==

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
		tell(player, "/testmidjoin is for the owner only.")
		return
	end
	if player == nil then
		return
	end

	local args = string.gsub(text, "^%s*/%a+%s*", "")
	local first = string.lower(string.match(args, "^%S+") or "")

	if first == "help" or first == "?" then
		for _, line in HELP do
			tell(player, line)
		end
		return
	end

	local run = _G.ConquestTestMidJoin
	if type(run) ~= "function" then
		-- The lobby page runs no round, so this is the likely answer there
		-- rather than a fault.
		tell(player, "no round on this server -- /world first.")
		return
	end

	local newbie = true
	if first == "vet" or first == "veteran" or first == "old" then
		newbie = false
	elseif first ~= "" and first ~= "new" and first ~= "newbie" then
		tell(player, "'" .. first .. "' is not an option -- try /testmidjoin help.")
		return
	end

	local ok, line = run(player, newbie, function(later: string)
		tell(player, later)
	end)
	tell(player, line)
	if ok then
		tell(player, "  (what this cannot replay: the lobby's 'Joining your friend's game...' toast and the teleport in front)")
	end
end

RequestRE.OnServerEvent:Connect(function(player, text)
	if typeof(text) == "string" and #text < 200 then
		dispatch(player, text)
	end
end)

;(cmd :: TextChatCommand).Triggered:Connect(function(source, text)
	local player = source and Players:GetPlayerByUserId(source.UserId)
	dispatch(player, text)
end)

local function watch(player: Player)
	player.Chatted:Connect(function(message)
		local lower = string.lower(message)
		if string.match(lower, "^/testmidjoin") or string.match(lower, "^/midjoin") then
			dispatch(player, message)
		end
	end)
end

Players.PlayerAdded:Connect(watch)
for _, player in Players:GetPlayers() do
	watch(player)
end

print("[midjoin] /testmidjoin ready -- chat /testmidjoin help")
