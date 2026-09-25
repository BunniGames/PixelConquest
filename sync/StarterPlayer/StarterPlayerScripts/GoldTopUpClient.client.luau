--!strict
-- Conquest :: GoldTopUpClient  (client)
--
-- THE ROBLOX PURCHASE PROMPT, AND NOTHING ELSE (owner, 2026-09-17: "it should
-- just be a roblox prompt. you decide which one to send"). A player arms a
-- building, picks a tile, and is turned down for gold -- and the answer to that
-- is the platform's own purchase dialog, not a shop page of this game's making.
-- There is no art in this file, no panel, no open and close: a refused build
-- goes in, a prompt comes out.
--
-- WHICH OF THE THREE, decided here rather than asked of the player -- that is
-- what "you decide which one to send" buys, and the rule is the SMALLEST TIER
-- THAT ACTUALLY CLEARS THE SHORTFALL. Two ways to get that wrong, and both are
-- worse than not prompting at all:
--   * Too small, and the purchase goes through and the building is STILL
--     refused. That is the one outcome money must never produce, and it is why
--     every tier's grant has to cover its own boundary (Config asserts the
--     numbers in prose; the harness asserts them in fact).
--   * Too big, and the game is upselling somebody who is 20,000 short into a
--     two-million-gold pack. They notice.
-- Where each rung hands over to the next is Config's TOPUP_UPTO_*, not the pack
-- sizes: the owner tunes the two independently.
-- Short by more than the biggest tier, and the biggest is what gets sent: it is
-- the most that can be done in one press, and it is honest about being partial.
--
-- ...AND NOT WHEN THEY ARE NEARLY THERE (owner: "Only show it when theyre less
-- than 90% of the way there"). `Config.TOPUP_OFFER_BELOW` is that fraction.
-- Somebody at 92% of a city's price already has it -- a few seconds of income
-- away -- so a prompt there charges for a wait that was about to end on its
-- own, and reads as the game holding the door shut to sell the key.
--
-- IT IS ITS OWN SCRIPT RATHER THAN CODE IN ConquestClient, and the reason has
-- not changed even now that the file is small: ConquestClient sits at Luau's
-- 200-local ceiling and a single `local` at its main chunk has broken it
-- before. The cooldown clock and the tier table below are exactly the sort of
-- state that cannot live there. What that file carries is a hook INSIDE an
-- existing function, declaring no new local at all.
--
-- THE PROMPT GOES THROUGH THE SERVER (ShopRE "buy"), never MarketplaceService
-- from here. ConquestShop hands the key to Monetization.promptProduct, which
-- keeps the `isLive` gate and the pcall around the prompt in ONE place -- the
-- same route every other purchase in this game takes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Config = require(Shared.Config)
local Matchmaker = require(Shared.Matchmaker)
local Net = require(Shared.Net)
local Products = require(Shared.Products)

-- A lobby server runs no round, so nobody can fail to afford a building on it.
-- YIELDING rather than returning is deliberate and is what ConquestClient does:
-- a Studio lobby FLIPS to "match" when its own countdown fires, and a file that
-- returned early would stay gone for the round that follows.
Matchmaker.awaitRole("match")

local netFolder = Net.await(ReplicatedStorage)
local StateRE = netFolder:WaitForChild("State") :: RemoteEvent
local ShopRE = netFolder:WaitForChild("Shop") :: RemoteEvent
-- The channel the refused build is parked on before the prompt opens. Same
-- remote ordinary builds ride, with its own verb.
local IntentRE = netFolder:WaitForChild("Intent") :: RemoteEvent

-- ============================================================= the channel ==
--
-- A BindableEvent, created HERE and found BY NAME over in ConquestClient at the
-- refusal itself. Two things make that the right shape rather than a lazy one:
--
--   * ConquestClient cannot afford to HOLD it. A `local goldShort = ...` at its
--     main chunk is exactly the line that has broken that file before ("Out of
--     local registers ... exceeded limit 200"), so the hook looks the instance
--     up inline. A refused build happens at human speed, so one FindFirstChild
--     per refusal costs nothing measurable.
--   * It never leaves this client. A BindableEvent does not replicate, and an
--     instance a CLIENT parents into ReplicatedStorage is local to that client,
--     so this is a private wire between two of that player's own scripts.
--
-- Missing at the moment of a refusal -- the first frames of a round, before
-- this file has run -- and ConquestClient's `if ev then` simply skips it. A
-- missed prompt is the correct failure; a broken build click is not.
local SIGNAL_NAME = "ConquestGoldShort"
local signal = ReplicatedStorage:FindFirstChild(SIGNAL_NAME) :: BindableEvent?
if signal == nil then
	local s = Instance.new("BindableEvent")
	s.Name = SIGNAL_NAME
	s.Parent = ReplicatedStorage
	signal = s
end

-- ================================================================ the tiers ==
--
-- SMALLEST FIRST, and the order is load-bearing: the search below takes the
-- first tier whose boundary answers the shortfall, so this list being sorted IS
-- the "don't upsell" rule.
--
-- `upTo` IS THE BIGGEST SHORTFALL A TIER WILL BE SENT FOR, and it is NOT the
-- same number as what that tier grants. It was, once: the first version simply
-- sent the smallest pack that covered the gap, which pinned the Small/Medium
-- boundary to the size of the small pack with no way to move it. Both numbers
-- live in Config now -- see the block there for the invariant that ties them
-- (a tier's grant must cover its own boundary) and for why the owner moved this
-- boundary to 60,000.
--
-- THE LAST RUNG HAS NO BOUNDARY. `math.huge` is what makes BIG the answer to
-- everything above MEDIUM's, including shortfalls it cannot actually close.
local TIERS = {
	{ key = "GOLD_SMALL", upTo = Config.TOPUP_UPTO_SMALL },
	{ key = "GOLD_MEDIUM", upTo = Config.TOPUP_UPTO_MEDIUM },
	{ key = "GOLD_BIG", upTo = math.huge },
}

-- HOW OFTEN IT MAY ASK. Without this a prompt opens on every refused click, and
-- a player hunting for a legal tile refuses a dozen in a row -- which would put
-- the platform's purchase dialog over the map again and again while they are
-- trying to do something else. That is not a shop, it is a wall. One prompt per
-- this many seconds, however many builds are refused in between.
--
-- A PURCHASE DIALOG IS A MODAL, which is what makes this stricter than a
-- cooldown on a card: the player cannot keep playing while it is up, so the
-- cost of asking too often is the game itself stopping.
local ASK_COOLDOWN = 45

-- ============================================================== the trigger ==

local phase = ""
local askedAt = -1e9

-- WHAT TO SEND, or nil if nothing can be. `short` is how much more gold the
-- refused building needed.
--
-- AN UNCONFIGURED PRODUCT IS SKIPPED, NEVER PROMPTED -- Products' header rule,
-- and here it is load-bearing rather than tidy: PromptProductPurchase on id 0
-- throws on the client. So the search walks past any tier without a real asset
-- behind it and settles for the next one up; with none configured it returns
-- nil and this file does nothing at all, which is why it is silent today.
local function tierFor(short: number): string?
	local fallback: string? = nil
	for _, t in TIERS do
		if Products.isLive(Products.product(t.key)) then
			-- The biggest live tier, kept in case none of them covers the gap.
			fallback = t.key
			if short <= t.upTo then
				return t.key
			end
		end
	end
	return fallback
end

-- FIRED BY ConquestClient at the refusal itself, with the price of the thing
-- that was refused and the treasury it was refused against.
;(signal :: BindableEvent).Event:Connect(function(cost: number, gold: number, tile: number?, kind: number?, wasNuke: boolean?)
	if type(cost) ~= "number" or type(gold) ~= "number" or cost <= 0 or gold < 0 then
		return
	end
	if phase ~= "playing" then
		return
	end
	-- Nearly there: say nothing. See the header.
	if gold >= cost * Config.TOPUP_OFFER_BELOW then
		return
	end
	local now = os.clock()
	if now - askedAt < ASK_COOLDOWN then
		return
	end
	local key = tierFor(cost - gold)
	if key == nil then
		return
	end
	-- PARK THE BUILD BEFORE THE PROMPT, never after. A top-up finishes THIS
	-- build on THIS tile (owner, 2026-09-17), and the receipt can land seconds
	-- later on a server that has no idea what was clicked -- so the intent goes
	-- up first and waits there for the grant to spend it.
	--
	-- A WARHEAD HAS NOTHING TO PLACE, so a refused nuke parks nothing and the
	-- grant falls back to plain gold, which is exactly what a warhead needs: it
	-- is bought with gold at the launch, not built on a tile.
	if not wasNuke and type(tile) == "number" and type(kind) == "number" then
		IntentRE:FireServer({ t = "topup", tile = tile, kind = kind })
	end
	-- STAMPED ONLY ONCE A PROMPT IS ACTUALLY GOING OUT, never on a refusal that
	-- chose nothing -- otherwise a round played before the products exist would
	-- burn the cooldown on prompts that never happened.
	askedAt = now
	ShopRE:FireServer("buy", key)
end)

-- READ OFF THE REPEATING BROADCAST, not off `init`. `init` is sent once at
-- round start and this file finishes its own setup after that, so it is
-- routinely missed -- the trap the sticker's gate fell into. "phase" repeats
-- every STATS_INTERVAL to every client, so a late listener converges in 200 ms
-- instead of waiting on a message that may never come again.
StateRE.OnClientEvent:Connect(function(kind, payload)
	local p: any = payload
	if kind == "init" then
		phase = (if type(p) == "table" then tostring(p.phase) else "")
	elseif kind == "phase" then
		if type(p) == "table" and p.phase ~= nil then
			phase = tostring(p.phase)
		end
	elseif kind == "win" then
		phase = "ended"
	end
end)
