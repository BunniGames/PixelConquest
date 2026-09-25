--!strict
-- Conquest :: /endgame  (server half)
--
-- A test shortcut to the END of a round, so the walk back to the matchmaking
-- page can be exercised without playing a match out to a win -- or a tutorial
-- out to its last card.
--
--   /endgame            end whatever is actually running
--   /endgame tutorial   mark the lesson track FINISHED
--   /endgame fail       mark it FAILED -- the other exit, same destination
--   /endgame round      end the MATCH, even with a tutorial still running
--   /endgame help
--
-- IT DOES NOT TELEPORT ANYBODY ITSELF. Every branch goes through
-- _G.ConquestEndRound, which is ConquestServer's own exit -- see the note
-- there. A shortcut that called the teleport directly would prove the teleport
-- works and nothing else; the thing worth testing is the path in front of it.
--
-- Owner-only on a live server, open season in Studio: the same gate /gold,
-- /simulate and /start use.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local HELP = {
	"/endgame -- owner-only shortcut to the end of a round",
	"  /endgame           end whatever is running",
	"  /endgame tutorial  finish the lesson track",
	"  /endgame fail      fail it instead",
	"  /endgame round     end the match itself",
}

-- ================================================================ plumbing ==

local folder = ReplicatedStorage:FindFirstChild("ConquestCheats")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "ConquestCheats"
	folder.Parent = ReplicatedStorage
end

-- ITS OWN PAIR, not /gold's. That script answers every Request it sees, so
-- sharing the remote would have it try to read "tutorial" as an amount of gold
-- and scold the player for it.
local function remote(name: string): RemoteEvent
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	return r :: RemoteEvent
end

local ReportRE = remote("EndReport")
local RequestRE = remote("EndRequest")

local cmd = TextChatService:FindFirstChild("EndGameCommand")
if not cmd then
	local c = Instance.new("TextChatCommand")
	c.Name = "EndGameCommand"
	c.PrimaryAlias = "/endgame"
	c.SecondaryAlias = "/endround"
	c.Parent = TextChatService
	cmd = c
end

local function tell(player: Player?, line: string)
	print("[endgame] " .. line)
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

local MODES = { tutorial = true, fail = true, round = true }
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
		tell(player, "/endgame is for the owner only.")
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

	local exit = _G.ConquestEndRound
	if type(exit) ~= "function" then
		-- The lobby page runs no round, so this is the likely answer there
		-- rather than a fault.
		tell(player, "no round on this server to end.")
		return
	end

	local mode: string? = nil
	if first ~= "" then
		if not MODES[first] then
			tell(player, "'" .. first .. "' is not a mode -- try /endgame help.")
			return
		end
		mode = first
	end

	local ok, line = exit(mode)
	tell(player, line)
	-- ONLY IN STUDIO. On a live server the teleport is the whole point of the
	-- test, and saying this there would describe the opposite of what happens.
	if ok and RunService:IsStudio() then
		tell(player, "  (Studio has nowhere to teleport to, so it rotates in place instead)")
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
		if string.match(lower, "^/endgame") or string.match(lower, "^/endround") then
			dispatch(player, message)
		end
	end)
end

Players.PlayerAdded:Connect(watch)
for _, player in Players:GetPlayers() do
	watch(player)
end

print("[endgame] /endgame ready -- chat /endgame help")
