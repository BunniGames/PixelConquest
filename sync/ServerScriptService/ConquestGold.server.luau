--!strict
-- Conquest :: /gold  (server half)
--
-- An owner-only cheat that drops gold into your own treasury, so the half of
-- the game gold pays for -- cities, ports, factories, the atom bomb -- can be
-- exercised without first playing the twenty minutes of income that affords
-- it.
--
--   /gold              +1,000,000
--   /gold 250k         +250,000   (k / m / b / t suffixes, or 2.5e7)
--   /gold set 1b       set the treasury to exactly that
--   /gold broke        empty it, to see what an empty treasury does
--   /gold help
--
-- Nothing is pushed to the client. The treasury already rides on the private
-- `fronts` message ConquestServer sends each player five times a second, so
-- the HUD picks the new figure up on its own within a fifth of a second.
--
-- The live Sim is read out of `_G.ConquestSim` EVERY time rather than cached:
-- every round builds a new one, and a cached Sim would be a cheat quietly
-- writing into last round's dead match. Server scripts share _G, which is
-- already how ConquestSimulate holds the live round still.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local DEFAULT_GRANT = 1000000
-- Absurdly high on purpose -- a MIRV is 25,000,000 and the city ladder climbs
-- without limit -- but FINITE, because math.huge turns the first cost
-- subtraction into a NaN, and every gold comparison in Sim then fails.
local MAX_GOLD = 1e12

local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12 }

local HELP = {
	"/gold -- owner-only treasury cheat",
	"  /gold            +1,000,000",
	"  /gold 250k       +250,000  (k / m / b / t, or 2.5e7)",
	"  /gold set 1b     set the treasury to exactly that",
	"  /gold broke      empty it",
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

local ReportRE = remote("Report")
local RequestRE = remote("Request")

-- Registered so the CLIENT can catch the typed command, which is the one
-- place it is guaranteed to fire; Player.Chatted only reaches the server
-- under some chat configurations. All three routes are accepted and
-- de-duplicated below, exactly as /simulate does it.
local cmd = TextChatService:FindFirstChild("GoldCommand")
if not cmd then
	local c = Instance.new("TextChatCommand")
	c.Name = "GoldCommand"
	c.PrimaryAlias = "/gold"
	c.SecondaryAlias = "/money"
	c.Parent = TextChatService
	cmd = c
end

-- ================================================================== output ==

local function tell(player: Player?, line: string)
	print("[gold] " .. line)
	if player and player.Parent then
		ReportRE:FireClient(player, line)
	end
end

-- Thousands separators, and %.0f rather than tostring: a treasury runs into
-- the billions, and tostring hands back "1e+12" at the top of the range.
local function fmt(n: number): string
	local s = string.format("%.0f", math.abs(n))
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, -4)
	end
	return (n < 0 and "-" or "") .. s .. out
end

-- "250k", "2.5m", "1e9", "40000". Returns nil for anything else, so a typo is
-- refused rather than silently read as zero.
local function amount(word: string?): number?
	if not word then
		return nil
	end
	local body, suffix = string.match(string.lower(word), "^([%d%.eE+%-]+)([kmbt]?)$")
	if not body then
		return nil
	end
	local n = tonumber(body)
	-- n ~= n catches the NaN a string like "-.e" parses to.
	if not n or n ~= n then
		return nil
	end
	return n * (SUFFIX[suffix] or 1)
end

-- ================================================================ dispatch ==

-- Studio is open season; a live server allows only the owner. Same gate as
-- /simulate and /start.
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
		tell(player, "/gold is for the owner only.")
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

	local sim = _G.ConquestSim
	if not sim then
		tell(player, "no round is running yet.")
		return
	end
	if not player then
		tell(nil, "/gold has to know whose treasury -- type it in the chat box.")
		return
	end
	local p = sim:playerByUserId(player.UserId)
	if not p then
		tell(player, "you are not in this round.")
		return
	end

	local before = p.gold
	local after: number
	if first == "set" then
		local n = amount(string.match(args, "^%S+%s+(%S+)"))
		if not n then
			tell(player, "usage: /gold set 1b")
			return
		end
		after = n
	elseif first == "broke" or first == "reset" then
		after = 0
	else
		local n = if first == "" then DEFAULT_GRANT else amount(first)
		if not n then
			tell(player, "'" .. first .. "' is not an amount -- try /gold 5m, or /gold help.")
			return
		end
		after = before + n
	end

	after = math.clamp(after, 0, MAX_GOLD)
	p.gold = after

	local delta = after - before
	tell(player, ("gold %s -> %s  (%s%s)")
		:format(fmt(before), fmt(after), if delta >= 0 then "+" else "", fmt(delta)))
	-- The treasury only reaches the HUD on the private `fronts` message, and
	-- that message is only sent for a player who has SPAWNED. The gold is
	-- really there either way; say so rather than let it read as a no-op.
	if not p.spawned then
		tell(player, "  (it shows once you have picked a spawn)")
	end
end

RequestRE.OnServerEvent:Connect(function(player, text)
	if typeof(text) == "string" and #text < 200 then
		dispatch(player, text)
	end
end)

-- Fires here on some chat configurations and not others; harmless either way.
;(cmd :: TextChatCommand).Triggered:Connect(function(source, text)
	local player = source and Players:GetPlayerByUserId(source.UserId)
	dispatch(player, text)
end)

local function watch(player: Player)
	player.Chatted:Connect(function(message)
		local lower = string.lower(message)
		if string.match(lower, "^/gold") or string.match(lower, "^/money") then
			dispatch(player, message)
		end
	end)
end

Players.PlayerAdded:Connect(watch)
for _, player in Players:GetPlayers() do
	watch(player)
end

print("[gold] /gold ready -- chat /gold help")
