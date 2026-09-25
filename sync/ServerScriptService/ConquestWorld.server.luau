--!strict
-- Conquest :: /world  (server half)
--
-- The owner's shortcut to a round on a NAMED MAP, without waiting for the
-- rotation to come round to it. Built 2026-09-08 for the World map, which is
-- ninth in a nine-map rotation and would otherwise take a while to see.
--
--   /world                 the World map, free-for-all
--   /world duo             the World map, in a mode (ffa / duo / trio)
--   /world pacific         any map by id -- /map reads the same
--   /world pacific trio    map and mode, either order
--   /pacific [mode]        the Pacific map, straight to it
--   /nyc [mode]            the New York map, straight to it
--   /japan [mode]          the Japan map, straight to it
--   /world historical      the World map with its 1938 borders predrawn:
--                          pick a nation in the spawn phase (Scenarios)
--   /world help
--   /spawn historical      a World / historical CARD on the lobby page instead
--                          of a round (any pairing: /spawn pacific trio) --
--                          _G.ConquestSpawnCard in MatchmakerServer
--
-- THE ALIAS NAMES THE MAP, which is the whole of what /pacific is. It is not
-- a second command: it is this one with a different word typed in front of
-- it, and `dispatch` reads the default map back out of that word. So an
-- alias that spells a map id starts that map, everything after it still
-- reads as map-or-mode in either order (/pacific duo), and adding /venice
-- later is one row in ALIASES plus one name in the client half -- no remote,
-- no gate, no launch code. The client forwards the raw text and nothing
-- else, so this file is the only place that still knows what was typed.
--
-- IT DOES NOT LAUNCH ANYTHING ITSELF. The launch is _G.ConquestStartMap,
-- which MatchmakerServer owns -- the reserved server, the match record, the
-- clan tags and the Studio fallback are all that script's locals. Same split
-- as /endgame and _G.ConquestEndRound.
--
-- Owner-only on a live server, open season in Studio: the same gate /gold,
-- /endgame and /simulate use. Only meaningful on the LOBBY page; a match
-- server has no matchmaker to ask.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Maps = require(Shared:WaitForChild("Maps"))
local Modes = require(Shared:WaitForChild("Modes"))
local Scenarios = require(Shared:WaitForChild("Scenarios"))

local HELP = {
	"/world -- owner-only: start a round on a named map, right now",
	"  /world               World, free-for-all",
	"  /world duo           World, in a mode (" .. table.concat(Modes.ORDER, " / ") .. ")",
	"  /world historical    World, 1938 -- borders predrawn, pick a nation (maps: "
		.. table.concat(Scenarios.mapIds(), ", ") .. ")",
	"  /world ww1 | /europe ww1 | /europe napoleonic | /pacific pacificwar   the other scenarios",
	"  /world rich          any map in a SPECIAL mode (" .. table.concat(Modes.specialIds(), " / ")
		.. ") -- the occasional cards; see Modes.SPECIAL",
	"  /world <map> [mode]  any map: " .. table.concat(Maps.ORDER, " "),
	"  /map is the same command",
	"  /pacific [mode]      straight to the Pacific",
	"  /nyc [mode]          straight to New York",
	"  /japan [mode]        straight to Japan",
	"  /korea [mode]        straight to Korea",
	"  /africa [mode]       straight to Africa",
	"  /philippines [mode]  straight to the Philippines (/phillipines too)",
	"  /eurasia [mode]      straight to Eurasia (72 empires, 60 faux players)",
	"  /mars [mode]         straight to Mars",
	"  /spawn historical    put a World / historical CARD on the lobby page, no round",
	"  /spawn <map> [mode]  any pairing on a card",
}

-- ================================================================ plumbing ==

local folder = ReplicatedStorage:FindFirstChild("ConquestCheats")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "ConquestCheats"
	folder.Parent = ReplicatedStorage
end

-- ITS OWN PAIR, like /endgame's: the other cheat scripts answer every Request
-- they see, so sharing a remote would have them parse a map id as gold.
local function remote(name: string): RemoteEvent
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	return r :: RemoteEvent
end

local ReportRE = remote("MapReport")
local RequestRE = remote("MapRequest")

-- ONE ROW PER CHAT COMMAND. The aliases are re-stated on every boot rather
-- than only on creation, so an instance somebody edited by hand in the
-- explorer repairs itself instead of quietly answering to the wrong word.
local ALIASES = {
	{ name = "WorldCommand", primary = "/world", secondary = "/map" },
	{ name = "PacificCommand", primary = "/pacific", secondary = "" },
	{ name = "NycCommand", primary = "/nyc", secondary = "" },
	{ name = "JapanCommand", primary = "/japan", secondary = "" },
	{ name = "MarsCommand", primary = "/mars", secondary = "" },
	{ name = "KoreaCommand", primary = "/korea", secondary = "" },
	{ name = "AfricaCommand", primary = "/africa", secondary = "" },
	-- The secondary is the owner's own spelling (2026-09-21), so the word
	-- they type reaches the map; dispatch folds a secondary onto its primary.
	{ name = "PhilippinesCommand", primary = "/philippines", secondary = "/phillipines" },
	-- Not a map alias: the same words, put on a lobby CARD instead of started.
	-- `dispatch` branches on the word. "spawn" is no map id, so the default
	-- map stays the World.
	{ name = "EurasiaCommand", primary = "/eurasia", secondary = "" },
	{ name = "SpawnCommand", primary = "/spawn", secondary = "" },
}

local commands: { TextChatCommand } = {}
for _, a in ALIASES do
	local found = TextChatService:FindFirstChild(a.name)
	local c: TextChatCommand
	if found and found:IsA("TextChatCommand") then
		c = found
	else
		c = Instance.new("TextChatCommand")
		c.Name = a.name
		c.Parent = TextChatService
	end
	c.PrimaryAlias = a.primary
	c.SecondaryAlias = a.secondary
	table.insert(commands, c)
end

local function tell(player: Player?, line: string)
	print("[world] " .. line)
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
		tell(player, "that command is for the owner only.")
		return
	end
	if not player then
		return
	end

	local args = string.gsub(text, "^%s*/%a+%s*", "")
	-- /pacific defaults to pacific, /world to world, /map to neither so it
	-- keeps world. An explicit map in the arguments still wins below.
	local slash = string.lower(string.match(text, "^%s*/(%a+)") or "")
	-- A SECONDARY ALIAS ANSWERS AS ITS PRIMARY. Without this a secondary that
	-- is not itself a map id (/phillipines) would fall through to "world"
	-- below and start the wrong map without a word. /map -> world is what it
	-- always was.
	for _, a in ALIASES do
		if a.secondary ~= "" and "/" .. slash == a.secondary then
			slash = string.sub(a.primary, 2)
		end
	end
	local mapId, modeId = (if Maps.exists(slash) then slash else "world"), Modes.ORDER[1]
	for word in string.gmatch(args, "%S+") do
		local w = string.lower(word)
		if w == "help" or w == "?" then
			for _, line in HELP do
				tell(player, line)
			end
			return
		elseif Maps.exists(w) then
			mapId = w
		elseif Modes.exists(w) then
			-- `exists`, not ORDER: the historical mode is kept OUT of the
			-- rotation on purpose (Modes), and this command is its only door.
			modeId = w
		else
			tell(player, "'" .. w .. "' is neither a map nor a mode -- try /world help.")
			return
		end
	end

	-- A HISTORICAL ROUND NEEDS A SCENARIO DRAWN FOR THAT MAP. The mode on a map
	-- without one would be an ordinary free-for-all wearing the wrong name, so
	-- it is refused here rather than started.
	if Modes.isHistorical(modeId) and not Scenarios.exists(mapId, modeId) then
		tell(player, Maps.name(mapId) .. " has no " .. Modes.name(modeId) .. " scenario -- maps that do: "
			.. table.concat(Scenarios.mapIds(modeId), ", "))
		return
	end

	-- /spawn PUTS THE PAIRING ON A LOBBY CARD instead of starting it (owner,
	-- 2026-09-11: "make /spawn historical, so i can see what it looks like in
	-- the homepage"). Same words, same checks above, a different door.
	if slash == "spawn" then
		local spawnCard = _G.ConquestSpawnCard
		if type(spawnCard) ~= "function" then
			tell(player, "no matchmaker on this server -- /spawn works from the lobby page.")
			return
		end
		local ok, line = spawnCard(player, mapId, modeId)
		tell(player, (ok and "" or "could not spawn: ") .. line)
		return
	end

	local start = _G.ConquestStartMap
	if type(start) ~= "function" then
		-- A match server runs no matchmaker, so this is the likely answer
		-- there rather than a fault.
		tell(player, "no matchmaker on this server -- /world works from the lobby page.")
		return
	end
	local ok, line = start(player, mapId, modeId)
	tell(player, (ok and "" or "could not start: ") .. line)
end

RequestRE.OnServerEvent:Connect(function(player, text)
	if typeof(text) == "string" and #text < 200 then
		dispatch(player, text)
	end
end)

for _, c in commands do
	c.Triggered:Connect(function(source, text)
		local player = source and Players:GetPlayerByUserId(source.UserId)
		dispatch(player, text)
	end)
end

-- WORD, NOT PREFIX. The old test was `^/world`, which also caught /worlds
-- and anything else beginning with it; asking for the alias exactly, or the
-- alias followed by a space, is the same intent stated correctly -- and it
-- now covers every row of ALIASES without naming any of them twice.
local function isCommand(lower: string): boolean
	for _, a in ALIASES do
		for _, word in { a.primary, a.secondary } do
			if word ~= "" and (lower == word or string.sub(lower, 1, #word + 1) == word .. " ") then
				return true
			end
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

print("[world] /world, /map, /pacific, /nyc, /japan, /korea, /africa, /philippines, /eurasia, /mars and /spawn ready -- chat /world help")
