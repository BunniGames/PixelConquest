--!strict
-- Conquest :: /gotrequest  (server half)
--
-- Owner-only: have a bot ask YOU for an alliance, so the request card can be
-- looked at without waiting for a second person (owner, 2026-09-18: "give me a
-- /gotrequest command so i can see what the alliance request looks like").
--
--   /gotrequest          one bot asks you -- the card lands bottom-right
--   /gotrequest 3        three different bots ask, so the cards stack
--   /gotrequest help
--
-- IT IS A REAL REQUEST, not a drawing of one. It goes through the same
-- Alliances.sendRequest the intent handler uses, so the card's ACCEPT really
-- allies you with that bot, DECLINE really refuses, and the 20 s bar runs on
-- the server's own timeout. A fake "request" message would be reconciled away
-- inside 200 ms by the private snapshot (the client trusts the server's list of
-- open asks, not the message), which is exactly the trap the first attempt at
-- testing this fell into.
--
-- Same plumbing as /attackme: its own remote pair under ConquestCheats, a
-- TextChatCommand, the Chatted fallback, and a de-dupe across the three routes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Alliances = require(Shared.Alliances)

local MAX_ASKS = 5

local HELP = {
	"/gotrequest -- owner-only: a bot asks you for an alliance, to see the card",
	"  /gotrequest        one bot asks -- the card lands bottom-right",
	"  /gotrequest 3      three bots ask, so the cards stack",
}

-- ================================================================ plumbing ==

local folder = ReplicatedStorage:FindFirstChild("ConquestCheats")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "ConquestCheats"
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

local ReportRE = remote("AllyTestReport")
local RequestRE = remote("AllyTestRequest")

local cmd: TextChatCommand
do
	local found = TextChatService:FindFirstChild("GotRequestCommand")
	if found and found:IsA("TextChatCommand") then
		cmd = found
	else
		cmd = Instance.new("TextChatCommand")
		cmd.Name = "GotRequestCommand"
		cmd.Parent = TextChatService
	end
	cmd.PrimaryAlias = "/gotrequest"
	cmd.SecondaryAlias = "/allyme"
end

local function tell(player: Player?, line: string)
	print("[gotrequest] " .. line)
	if player and player.Parent then
		ReportRE:FireClient(player, line)
	end
end

-- ================================================================ dispatch ==

-- Studio is open season; a live server allows only the owner. Same gate as
-- /gold, /world, /attackme and /simulate.
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
	local key = player and player.UserId or 0
	local now = os.clock()
	if (lastFire[key] or 0) > now - 0.5 then
		return
	end
	lastFire[key] = now

	if not allowed(player) then
		tell(player, "/gotrequest is for the owner only.")
		return
	end
	if not player then
		tell(nil, "/gotrequest has to know who to ask -- type it in the chat box.")
		return
	end

	local args = string.gsub(text, "^%s*/%a+%s*", "")
	local asks = 1
	for word in string.gmatch(args, "%S+") do
		local w = string.lower(word)
		local n = tonumber(w)
		if w == "help" or w == "?" then
			for _, line in HELP do
				tell(player, line)
			end
			return
		elseif n ~= nil then
			asks = math.clamp(math.floor(n), 1, MAX_ASKS)
		else
			tell(player, "'" .. w .. "' is not a count -- try /gotrequest help.")
			return
		end
	end

	local sim = _G.ConquestSim
	if not sim then
		tell(player, "no round is running yet.")
		return
	end
	if sim.phase ~= "playing" then
		-- Alliances.handleIntent refuses outside "playing" and so does the
		-- module's own AI; a card in the spawn phase would be one you cannot
		-- answer.
		tell(player, "the round is not playing yet.")
		return
	end
	local p = sim:playerByUserId(player.UserId)
	if not p or not p.alive then
		tell(player, "you are not standing in this round.")
		return
	end
	-- The tab is hidden on a lesson server, so a card filed there would land
	-- on a ScreenGui that is switched off.
	if ReplicatedStorage:GetAttribute("ConquestLocalTutorial") == true then
		tell(player, "this is a tutorial round -- the alliance tab is hidden here. Try it in a real game.")
		return
	end

	-- Biggest first, so the name on the card is one you have seen on the
	-- standings. canSendRequest carries every reason a bot could not ask
	-- (already allied, an ask already open either way, the 30 s cooldown after
	-- a refusal), so the walk simply skips to the next one.
	local candidates = {}
	for _, id in sim.playerOrder do
		local o = sim.players[id]
		if o ~= nil and o.isBot and o.alive and o.spawned and o.id ~= p.id then
			table.insert(candidates, o)
		end
	end
	table.sort(candidates, function(a, b)
		return a.tileCount > b.tileCount
	end)

	local asked = {}
	for _, bot in candidates do
		if #asked >= asks then
			break
		end
		if Alliances.canSendRequest(sim, bot.id, p.id) then
			local req = Alliances.sendRequest(sim, bot.id, p.id)
			if req ~= nil then
				table.insert(asked, tostring(bot.name or ("empire " .. tostring(bot.id))))
			end
		end
	end

	if #asked == 0 then
		tell(player, "nobody could ask right now -- every bot is allied with you, already asking, or cooling down.")
		return
	end
	tell(
		player,
		string.format(
			"%s ask%s for an alliance -- the card is bottom-right. ACCEPT allies you, DECLINE refuses, 20 s to answer.",
			table.concat(asked, ", "),
			#asked == 1 and "s" or ""
		)
	)
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

-- WORD, NOT PREFIX -- the same correction /world carries.
local function isCommand(lower: string): boolean
	for _, word in { "/gotrequest", "/allyme" } do
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

print("[gotrequest] /gotrequest ready -- chat /gotrequest help")
