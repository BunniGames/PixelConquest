--!strict
-- Conquest :: ConquestMonetization  (server)
-- ProcessReceipt, pass ownership, and the prompt wrappers. This is the file
-- that turns Robux into a row in a DataStore; nothing else may grant anything.
--
-- IT IS NOT WIRED UP. `Monetization.install()` is the one line that arms it,
-- and it is deliberately not called anywhere yet. Until then ProcessReceipt is
-- unset, which is the correct state for a game with no products configured.
--
-- ==========================================================================
-- THE RULE THAT THE WHOLE FILE IS BUILT AROUND
-- ==========================================================================
--
-- ROBLOX RE-SENDS A RECEIPT UNTIL THE HANDLER RETURNS PurchaseGranted. Every
-- consequence below follows from that one sentence:
--
--   * The retry can arrive at a DIFFERENT SERVER, days later, at a process
--     with no memory of the first attempt. So "have I already granted this"
--     cannot be answered from memory -- it is answered from the profile's
--     receipt table, which is why receipts are stored per player.
--
--   * PurchaseGranted MUST NOT be returned until the grant is DURABLY SAVED.
--     Returning it after merely applying the grant in memory means a server
--     crash one second later loses the item and Roblox never sends the receipt
--     again -- the player paid and has nothing, which is a refund ticket.
--
--   * NotProcessedYet is the SAFE answer to everything that went wrong. It
--     costs a retry. The unsafe answer is PurchaseGranted, which is final.
--
--   * Nothing here ever returns PurchaseDecision.Undefined or throws. A throw
--     inside ProcessReceipt is treated by the engine as "not processed", but
--     it also means whatever happened after the throw did not happen -- so the
--     receipt gets recorded without the grant, or the other way round,
--     depending on where it blew up. Everything fallible is pcall'd.
--
-- THE ROLLBACK. A grant mutates the profile in memory and then the save can
-- still fail. Leaving it there would mean the retry sees no receipt, grants a
-- SECOND time, and a later successful save writes both. So the profile is
-- snapshotted before the grant and restored on any failure. The snapshot is a
-- deep copy and the restore replaces sub-tables, so nothing may hold a
-- long-lived reference to `profile.stats` or `profile.passes` across a
-- purchase -- always index from the profile.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Products = require(game.ReplicatedStorage:WaitForChild("Conquest"):WaitForChild("Products"))
-- The pattern catalogue names the product that unlocks each boosted skin, and
-- the grants for those are built off that list rather than written by hand.
local Patterns = require(game.ReplicatedStorage:WaitForChild("Conquest"):WaitForChild("Patterns"))
-- VIP's two numbers (the Money grant and the growth bonus) live in Config with
-- everything else the game runs on; this file only spends them.
local Config = require(game.ReplicatedStorage:WaitForChild("Conquest"):WaitForChild("Config"))
local Data = require(script.Parent:WaitForChild("ConquestData"))
local Analytics = require(script.Parent:WaitForChild("ConquestAnalytics"))

local Monetization = {}

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet

local installed = false

-- ================================================================== grants ==
--
-- One function per product key. It receives the loaded profile and mutates it;
-- it must NOT save (the caller owns the save, because only the caller knows
-- whether the receipt goes with it) and it must NOT yield (a yield inside
-- ProcessReceipt widens the window in which the server can die between grant
-- and save). Return false, or throw, to refuse the grant and get a retry.

export type Grant = (player: Player, profile: any, entry: any) -> boolean?

local grants: { [string]: Grant } = {}

-- Register a grant for a product key. Features add themselves here rather than
-- this file growing a branch per feature, which is what keeps the receipt path
-- readable enough to audit.
function Monetization.setGrant(key: string, fn: Grant)
	grants[key] = fn
end

local function countPurchase(profile: any, entry: any)
	profile.purchases = profile.purchases or {}
	profile.purchases[entry.key] = (profile.purchases[entry.key] or 0) + 1
end

-- The two default grants. Both hand out a TOKEN rather than performing the
-- action, because the action needs a name typed and a filter round trip and
-- neither belongs inside a receipt handler. Spending the token is a separate,
-- retryable, free operation -- and if the player closes the game between
-- buying and spending, they still own what they paid for.
Monetization.setGrant("RENAME", function(_player, profile, entry)
	profile.renameTokens = (profile.renameTokens or 0) + 1
	countPurchase(profile, entry)
	return true
end)

Monetization.setGrant("TITLE", function(_player, profile, entry)
	profile.titleTokens = (profile.titleTokens or 0) + 1
	countPurchase(profile, entry)
	return true
end)

-- ---- 2026-09-08: the three the owner asked for -----------------------------
--
-- A ONE-TIME UNLOCK SOLD AS A CONSUMABLE. Roblox will happily sell the same
-- developer product twice, so the grant is a flag and not a counter: a second
-- receipt sets true to true and is acknowledged like any other. The shop
-- stops offering it the moment the profile says it is owned, which is what
-- keeps that second receipt from ever being an honest player's.
Monetization.setGrant("MONEY2X", function(_player, profile, entry)
	profile.money2x = true
	countPurchase(profile, entry)
	return true
end)

-- A TOKEN, like a rename. The takeover itself needs a live round, a free
-- empire and a dead player, none of which belongs inside a receipt handler;
-- ConquestServer spends the token through the `onGranted` hook below the
-- instant one can be honoured, and it carries to the next round when it
-- cannot -- the player still owns what they paid for.
Monetization.setGrant("REVIVE", function(_player, profile, entry)
	profile.reviveTokens = (profile.reviveTokens or 0) + 1
	countPurchase(profile, entry)
	return true
end)

-- ---- 2026-09-12: the tutorial four -----------------------------------------
--
-- "+1 Nuke!", "+1 Million Army Size!", "+1 Million Gold!" and "Special Forces
-- (2x Attack Speed)!" -- sold only inside the tutorial, for the reason set out
-- over their entries in Products. One loop rather than four near-identical
-- grants: all four bank a token under their own key and differ only in what
-- ConquestServer.redeemBoost does with it.
--
-- A TOKEN, NEVER THE EFFECT, and here that is not a stylistic choice. Three of
-- these four only mean anything against a live sim player, and a receipt
-- routinely lands where there is none: on the lobby server, between rounds, or
-- after the lesson has ended. REVIVE established the shape -- bank it, spend it
-- when it can be honoured -- and it is the only shape that cannot lose a
-- purchase.
-- STARTER_PACK and STARTER_PACK2 joined this list 2026-09-17 and bank exactly
-- the same way. They are the only BUNDLES here, which changes nothing at this
-- layer: the grant's whole job is to be durable, and what a token unpacks into
-- is the redeem's business (ConquestServer.BOOSTS). The two packs bank under
-- SEPARATE keys rather than sharing one, because a token is spent by key --
-- one pooled counter could not tell three defence towers from one.
-- THE THREE GOLD TOP-UPS joined on 2026-09-17 as well, and they are the
-- clearest case for the token shape in the whole file: the offer is made at a
-- refused BUILD CLICK, so the receipt lands while the player is mid-round with
-- a specific thing they were trying to place -- and Roblox may still take a
-- second or two to make it durable, by which time the round can have ended, the
-- server rotated, or the player left. Banked, it is spent whenever a round can
-- honour it and never lost.
for _, key in {
	"TUTORIAL_NUKE",
	"TUTORIAL_ARMY",
	"TUTORIAL_GOLD",
	"TUTORIAL_FORCES",
	"STARTER_PACK",
	"STARTER_PACK2",
	"GOLD_SMALL",
	"GOLD_MEDIUM",
	"GOLD_BIG",
	-- THE AIRFIELD'S SKIP (2026-09-22) banks the same way and for the same
	-- reason as the top-ups: the offer is made at a refused sortie, the
	-- receipt lands seconds later, and by then the field it was for may have
	-- rearmed on its own, been razed, or belong to a round that has ended.
	-- ConquestServer.BOOSTS.SKIP_REARM spends it.
	"SKIP_REARM",
} do
	Monetization.setGrant(key, function(_player, profile, entry)
		if type(profile.tutorialBoosts) ~= "table" then
			profile.tutorialBoosts = {}
		end
		profile.tutorialBoosts[key] = (profile.tutorialBoosts[key] or 0) + 1
		countPurchase(profile, entry)
		return true
	end)
end

-- ---- 2026-09-15: the flag --------------------------------------------------
--
-- A TOKEN, for the reason every other token in this file is one: a receipt can
-- land on a server that never saw the press that caused it -- a lobby, a match,
-- or a session days later -- and the flag the player actually wanted is known
-- only to the page they pressed it on. So the product banks an unlock and
-- Data.buyFlag spends it on whichever flag is pressed, whenever that happens.
-- Nothing is lost if they close the game between buying and choosing.
Monetization.setGrant("FLAG", function(_player, profile, entry)
	profile.flagTokens = (profile.flagTokens or 0) + 1
	countPurchase(profile, entry)
	return true
end)

-- BOOSTED SKINS: one grant per def that names a product. Own it AND wear it,
-- in that order, for the same reason Data.buyPattern does -- a purchase that
-- does not put the thing on reads as a purchase that failed.
for _, def in Patterns.LIST do
	if def.product ~= nil then
		local key = def.key
		Monetization.setGrant(def.product, function(_player, profile, entry)
			if type(profile.patterns) ~= "table" then
				profile.patterns = {}
			end
			profile.patterns[key] = true
			profile.pattern = key
			countPurchase(profile, entry)
			return true
		end)
	end
end

-- ============================================================ after grant ==
--
-- WHO WANTS TO KNOW WHEN SOMETHING WAS BOUGHT. Called AFTER the durable save
-- and outside the receipt's own thread, so a hook may yield and may fail
-- without touching the decision Roblox was given. This is how a purchase made
-- in a match reaches the round (the revive takeover) and how one made on the
-- page reaches the page (a repaint of the shop) without either of those
-- Scripts being required from here.
local grantedHooks: { (Player, any) -> () } = {}

function Monetization.onGranted(fn: (Player, any) -> ())
	table.insert(grantedHooks, fn)
end

-- WHO WANTS TO KNOW WHEN VIP WAS ACTUALLY PAID (2026-09-16). Deliberately NOT
-- `onGranted`: that one fires the moment the SITE confirms the pass, which is
-- two yields before the money and the pattern are in the profile -- settleVip
-- still has UserOwnsGamePassAsync and a DataStore flush to get through. A page
-- repainted off onGranted therefore draws the balance from BEFORE the grant,
-- which is exactly what a buyer sees as "nothing happened". This fires after
-- the flush, so what a listener pushes is what was actually banked.
local vipSettledHooks: { (Player) -> () } = {}

function Monetization.onVipSettled(fn: (Player) -> ())
	table.insert(vipSettledHooks, fn)
end

-- ================================================================ rollback ==

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, val in v do
		out[k] = deepCopy(val)
	end
	return out
end

-- In place, so the profile's identity survives -- Data holds this exact table
-- and handing it a different one would orphan every other reference.
local function restoreInto(dst: any, src: any)
	for k in dst do
		dst[k] = nil
	end
	for k, v in src do
		dst[k] = v
	end
end

-- ========================================================== ProcessReceipt ==

local function processReceipt(info: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(info.PlayerId)
	if player == nil then
		-- They left before the receipt landed. Roblox will deliver it again the
		-- next time they play; granting to an absent player is not possible
		-- without a second write path, and a second write path is a second
		-- chance to double-grant.
		return NOT_YET
	end

	local profile = Data.get(player)
	if profile == nil then
		-- Their load is probably still in flight (the receipt can arrive within
		-- a second of joining). Wait briefly, then give up and take the retry.
		profile = Data.wait(player, 8)
	end
	if profile == nil then
		Analytics.event("purchase_no_profile", player, 1, { productId = info.ProductId })
		return NOT_YET
	end

	local purchaseId = tostring(info.PurchaseId)

	-- FIRST, always. This is the whole idempotency guarantee, and it has to run
	-- before the product is even looked up: a retry for a product that has
	-- since been removed from the catalogue must still be acknowledged, or it
	-- retries forever.
	if Data.hasReceipt(profile, purchaseId) then
		return GRANTED
	end

	local entry = Products.byProductId(info.ProductId)
	if entry == nil then
		-- A receipt for an id this build does not know. NOT granted: a later
		-- deploy that adds the id will grant it on the next retry, whereas
		-- acknowledging it now would take the money and lose the purchase
		-- permanently.
		Analytics.unknownProduct(player, info.ProductId)
		return NOT_YET
	end

	local grant = grants[entry.key]
	if grant == nil then
		Analytics.grantFailed(player, entry, "no grant registered")
		return NOT_YET
	end

	local before = deepCopy(profile)
	Data.recordReceipt(profile, purchaseId)

	local ok, result = pcall(grant, player, profile, entry)
	if not ok or result == false then
		restoreInto(profile, before)
		Analytics.grantFailed(player, entry, ok and "grant returned false" or tostring(result))
		return NOT_YET
	end

	-- DURABLE OR NOTHING. Everything above this line is memory.
	if not Data.flush(player) then
		restoreInto(profile, before)
		Analytics.grantFailed(player, entry, "save failed")
		return NOT_YET
	end

	Analytics.promptCompleted(player, entry, info.CurrencySpent)
	-- Durable, acknowledged, and only now told about. See `onGranted`.
	for _, fn in grantedHooks do
		task.spawn(fn, player, entry)
	end
	return GRANTED
end

-- ============================================================ pass ownership ==
--
-- Cached in the profile, but ONLY the `true`. Caching a false would mean a
-- player who buys the pass mid-session is told they do not own it until they
-- rejoin. The negative side gets a short in-memory TTL instead, which is
-- purely a rate limit on UserOwnsGamePassAsync.

local NEGATIVE_TTL = 60
local negativeCache: { [string]: number } = {}

-- STUDIO ONLY: passes a TEST purchase in this session "bought". Studio's test
-- prompt completes but never makes UserOwnsGamePassAsync say yes, so without
-- this a pass-gated feature could not be unlocked in a playtest at all.
-- Session-only, and never written to the profile.
local studioPasses: { [string]: boolean } = {}

-- THE CACHED ANSWER, NO YIELD (2026-09-22): does this account hold `key`,
-- as the ConquestPass_<KEY> attribute says. The attribute is THIS module's
-- own write -- settlePass once the site has answered, buyPassWithMoney the
-- moment a Money sale settles -- never the client's, so a server gate may
-- trust it. nil (not asked yet) reads as not held. For gates on a hot path
-- -- the nuke intent's MEGA NUKE check -- where ownsPass's cold-cache web
-- call must not sit between a tap and a launch.
function Monetization.holdsPass(player: Player, key: string): boolean
	return player:GetAttribute(Products.PASS_ATTR .. key) == true
end

function Monetization.ownsPass(player: Player, key: string): boolean
	local entry = Products.pass(key)
	if not Products.isLive(entry) then
		return false
	end
	local e = entry :: any

	if studioPasses[tostring(player.UserId) .. ":" .. key] then
		return true
	end

	-- BOUGHT WITH MONEY (2026-09-22): the game's own sale, recorded on the
	-- profile, answers before the site is asked -- so every gate a pass opens
	-- (hostTier, the VIP boost, the settlements below) opens for a Money buyer
	-- exactly as for a Robux one.
	if Data.ownsMoneyPass(player, key) then
		return true
	end

	local profile = Data.get(player)
	if profile ~= nil and profile.passes ~= nil and profile.passes[key] == true then
		return true
	end

	local cacheKey = tostring(player.UserId) .. ":" .. key
	local seenAt = negativeCache[cacheKey]
	if seenAt ~= nil and (os.clock() - seenAt) < NEGATIVE_TTL then
		return false
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, e.id)
	end)
	if not ok then
		-- The service is down. Say no rather than yes: a wrongly-granted
		-- capability is harder to take back than a wrongly-denied one is to
		-- retry, and the caller sees the same answer either way.
		warn(("[ConquestMonetization] UserOwnsGamePassAsync failed for %s: %s"):format(key, tostring(owns)))
		return false
	end

	if owns == true then
		negativeCache[cacheKey] = nil
		if profile ~= nil then
			profile.passes = profile.passes or {}
			profile.passes[key] = true
			Data.markDirty(player)
		end
		return true
	end

	negativeCache[cacheKey] = os.clock()
	return false
end

-- ========================================================= buy with money ==
--
-- THE SECOND WAY TO OWN A PASS (2026-09-22, owner: "players can also buy it
-- with the currency Money that they earn"). No site, no receipt: the price is
-- the catalogue's (Products.moneyPrice), the debit is Data.buyMoneyPass, and
-- the record is the profile's `moneyPasses` -- which ownsPass reads first, so
-- from here on the pass is owned in every sense the Robux one is. What a pass
-- pays out on top (its `grant`; VIP's Money, pattern and tag) still lands
-- through the same settlement the site route uses: the granted hooks run
-- settlePass / settleVip, which ask ownsPass and find a yes.
--
-- YIELDS (ownsPass on a cold cache, then the flush). Returns whether it sold
-- and a line the player can read either way.
local buyingWithMoney: { [string]: boolean } = {}

function Monetization.buyPassWithMoney(player: Player, key: string): (boolean, string)
	local entry = Products.pass(key)
	if not Products.isLive(entry) then
		return false, "That is not on sale."
	end
	local e = entry :: any
	local price = Products.moneyPrice(key)
	if price == nil then
		return false, "That cannot be bought with Money."
	end
	-- ONE AT A TIME PER PLAYER AND PASS: ownsPass and the flush both yield,
	-- and two presses in flight would both pass the balance check.
	local lock = tostring(player.UserId) .. ":" .. key
	if buyingWithMoney[lock] then
		return false, "One at a time."
	end
	buyingWithMoney[lock] = true

	local sold = false
	local why = ""
	local ok, err = pcall(function()
		if Monetization.ownsPass(player, key) then
			why = "You already own " .. e.name .. "."
			return
		end
		if Data.get(player) == nil then
			why = "Your profile has not loaded yet."
			return
		end
		local bought, reason = Data.buyMoneyPass(player, key, price)
		if not bought then
			why = reason
			return
		end
		-- DURABLE BEFORE IT IS TRUE. A pass that flipped on screen and then did
		-- not save would be taken back on the next join with the Money gone
		-- with it, so the flag and the debit go to the store together and come
		-- back together if that fails.
		if not Data.flush(player) then
			Data.unbuyMoneyPass(player, key, price)
			why = "Couldn't save that right now -- try again in a moment."
			Analytics.event("pass_money_failed", player, price, { key = key })
			warn(("[ConquestMonetization] %s's Money purchase of %s did not save; refunded."):format(player.Name, key))
			return
		end
		sold = true
	end)
	buyingWithMoney[lock] = nil
	if not ok then
		warn("[ConquestMonetization] buyPassWithMoney threw for " .. player.Name .. " / " .. key .. ": " .. tostring(err))
		return false, "Couldn't do that right now -- try again in a moment."
	end
	if not sold then
		return false, why
	end

	if player.Parent ~= nil then
		player:SetAttribute(Products.PASS_ATTR .. key, true)
	end
	Analytics.event("pass_money_bought", player, price, { key = key })
	print(("[ConquestMonetization] %s bought %s for %d Money."):format(player.Name, key, price))
	-- THE SAME ANNOUNCEMENTS A SITE PURCHASE MAKES: the granted hooks (the
	-- lobby re-sends which passes are held; install's own hook settles the
	-- pass's grant) and the settled hooks, so the balance that just moved is
	-- repainted even for a pass that pays nothing on top.
	for _, fn in grantedHooks do
		task.spawn(fn, player, entry)
	end
	for _, fn in vipSettledHooks do
		task.spawn(fn, player)
	end
	return true, e.name .. " is yours."
end

-- ================================================================= prompts ==
--
-- Every marketplace call is pcall'd. PromptProductPurchase throws on network
-- trouble, and an unhandled throw in a purchase button takes the whole calling
-- script down with it -- which in practice means the shop stops responding and
-- the player thinks the game froze.

local function promptGuard(player: Player, entry: any, fn: () -> ()): boolean
	if not Products.isLive(entry) then
		warn(("[ConquestMonetization] %s is not configured (id is 0); prompt suppressed."):format(entry and entry.key or "?"))
		return false
	end
	Analytics.promptShown(player, entry)
	local ok, err = pcall(fn)
	if not ok then
		Analytics.event("purchase_prompt_error", player, 1, { key = entry.key, err = tostring(err) })
		warn(("[ConquestMonetization] prompt failed for %s: %s"):format(entry.key, tostring(err)))
	end
	return ok
end

function Monetization.promptProduct(player: Player, key: string): boolean
	local entry = Products.product(key)
	return promptGuard(player, entry, function()
		MarketplaceService:PromptProductPurchase(player, (entry :: any).id)
	end)
end

function Monetization.promptPass(player: Player, key: string): boolean
	local entry = Products.pass(key)
	return promptGuard(player, entry, function()
		MarketplaceService:PromptGamePassPurchase(player, (entry :: any).id)
	end)
end

-- ===================================================================== VIP ==
--
-- THE ONE PASS THAT GRANTS SOMETHING (2026-09-15). HOST and ADVANCED are pure
-- capability: owning them IS the product and there is nothing to hand over.
-- VIP carries two things that have to be PAID once -- Config.VIP_MONEY_GRANT
-- in Money, and the Rainbow pattern -- plus two that are simply true of anyone
-- holding it: the chat tag and the +10% troop growth.
--
-- WHY THIS IS NOT A ProcessReceipt GRANT. A game pass has no receipt. The only
-- two signals that an account owns one are the prompt closing
-- (PromptGamePassPurchaseFinished, wired in `install`) and asking the site on
-- join -- and the second is true forever afterwards. So the grant cannot be
-- keyed on a signal at all; it is keyed on a LATCH in the profile
-- (Data.creditVip), and both signals do nothing but call this.
--
-- DURABLE OR ROLLED BACK, the rule the whole file runs on: the latch and the
-- money are applied in memory, flushed, and undone if the flush fails.
-- Without the undo a failed save leaves the latch set on a profile that never
-- banked the money, and the player has paid for nothing with no way back.

-- Read by the chat tag (VipChatClient) and by ConquestServer's applyPattern.
-- An attribute rather than a remote for the same reason the nation name is
-- one: it replicates to every client on its own, and what it carries is public
-- the moment a tag is drawn beside somebody's name.
local VIP_ATTR = "ConquestVip"
local VIP_PATTERN = "rainbow"

-- ONE SETTLEMENT AT A TIME PER PLAYER. `settleVip` yields twice -- ownsPass on
-- a cold cache, then the flush -- and the join path and a purchase landing can
-- both call it inside that window. Two in flight would both pass the latch
-- check before either wrote it.
local settling: { [number]: boolean } = {}

function Monetization.isVip(player: Player): boolean
	return Monetization.ownsPass(player, "VIP")
end

-- Called on every profile load and again after any pass purchase. YIELDS, so
-- every caller runs it on its own thread. Returns whether it actually paid,
-- which is false for the overwhelmingly common case of a VIP who was already
-- settled rounds ago.
function Monetization.settleVip(player: Player): boolean
	if settling[player.UserId] then
		return false
	end
	settling[player.UserId] = true

	local paid = false
	local ok, err = pcall(function()
		if not Monetization.ownsPass(player, "VIP") then
			return
		end
		-- THE TAG AND THE BOOST DO NOT WAIT ON THE GRANT. They are true of
		-- anyone who owns the pass, in every session, whether or not the
		-- one-time settlement still has anything left to do -- so the attribute
		-- is set before the latch is even looked at.
		player:SetAttribute(VIP_ATTR, true)

		-- A FAILED LOAD IS NOT A NEW PROFILE. Per ConquestData's header the
		-- correct response to a nil profile is to write nothing at all; the
		-- settlement simply waits for a session that can load one.
		if Data.get(player) == nil or Data.vipCredited(player) then
			return
		end
		if not Data.creditVip(player, Config.VIP_MONEY_GRANT, VIP_PATTERN) then
			return
		end
		if not Data.flush(player) then
			Data.uncreditVip(player, Config.VIP_MONEY_GRANT, VIP_PATTERN)
			Analytics.event("vip_grant_failed", player, 1, {})
			warn(("[ConquestMonetization] VIP settlement for %s did not save; it will retry on their next join."):format(player.Name))
			return
		end
		paid = true
		Analytics.event("vip_granted", player, 1, { money = Config.VIP_MONEY_GRANT })
		print(("[ConquestMonetization] VIP settled for %s: +%d Money and the %s pattern."):format(
			player.Name, Config.VIP_MONEY_GRANT, VIP_PATTERN))
	end)

	settling[player.UserId] = nil
	if not ok then
		warn("[ConquestMonetization] settleVip threw for " .. player.Name .. ": " .. tostring(err))
	end
	-- ONLY ON THE LOAD THAT ACTUALLY PAID. Every later one returns false at the
	-- latch above, so a settled VIP costs these hooks nothing on any join after
	-- the first. See Monetization.onVipSettled.
	if paid then
		for _, fn in vipSettledHooks do
			task.spawn(fn, player)
		end
	end
	return paid
end

-- ======================================================= the other passes ==
--
-- THE EXTRA BUILDINGS PASSES (2026-09-22; Products.PLUS_PASSES). Each is
-- VIP's shape in miniature: an attribute saying whether the account holds it,
-- and -- for the ones that carry Money (`Products.Entry.grant`) -- a one-time
-- grant behind a latch (Data.creditPass), durable or rolled back.
--
-- THE ATTRIBUTE IS WRITTEN TRUE *OR FALSE* once the site has answered, never
-- left unset. The in-game page reads "known" off the attribute's presence --
-- a nil means "not asked yet", so a non-owner whose attribute was simply
-- never written would sit at a shut page forever.
local settlingPass: { [string]: boolean } = {}

-- YIELDS (ownsPass on a cold cache, then the flush); every caller spawns it.
-- Returns whether it paid, which is false on every join after the first.
function Monetization.settlePass(player: Player, key: string): boolean
	local entry = Products.pass(key)
	if not Products.isLive(entry) then
		return false
	end
	local lock = tostring(player.UserId) .. ":" .. key
	if settlingPass[lock] then
		return false
	end
	settlingPass[lock] = true

	local paid = false
	local ok, err = pcall(function()
		local owns = Monetization.ownsPass(player, key)
		if player.Parent ~= nil then
			player:SetAttribute(Products.PASS_ATTR .. key, owns)
		end
		if not owns then
			return
		end
		local grant = (entry :: any).grant
		local money = if type(grant) == "table" then math.floor(tonumber(grant.money) or 0) else 0
		if money <= 0 then
			return
		end
		-- A FAILED LOAD IS NOT A NEW PROFILE (ConquestData's header): write
		-- nothing, and let a session that can load one settle it.
		if Data.get(player) == nil or Data.passCredited(player, key) then
			return
		end
		if not Data.creditPass(player, key, money) then
			return
		end
		if not Data.flush(player) then
			Data.uncreditPass(player, key, money)
			Analytics.event("pass_grant_failed", player, 1, { key = key })
			warn(("[ConquestMonetization] %s settlement for %s did not save; it will retry on their next join."):format(key, player.Name))
			return
		end
		paid = true
		Analytics.event("pass_granted", player, 1, { key = key, money = money })
		print(("[ConquestMonetization] %s settled for %s: +%d Money."):format(key, player.Name, money))
	end)

	settlingPass[lock] = nil
	if not ok then
		warn("[ConquestMonetization] settlePass threw for " .. player.Name .. " / " .. key .. ": " .. tostring(err))
	end
	-- The same repaint VIP's grant asks for: the lobby page re-sends the
	-- balance so the Money lands on screen without a rejoin. The hooks are
	-- named for VIP because it was the first; what they do is "a pass just
	-- paid out", and that is what happened.
	if paid then
		for _, fn in vipSettledHooks do
			task.spawn(fn, player)
		end
	end
	return paid
end

-- Every extra-buildings pass, each on its own thread: a cold ownsPass is a
-- web call apiece and none of them should wait on another.
function Monetization.settlePlusPasses(player: Player)
	for _, key in Products.PLUS_PASSES do
		task.spawn(Monetization.settlePass, player, key)
	end
end

-- ================================================================= install ==

function Monetization.isInstalled(): boolean
	return installed
end

-- THE ONE LINE THAT ARMS THIS. Also installs Data, because a receipt handler
-- without a persistence layer under it can only ever return NotProcessedYet.
function Monetization.install()
	if installed then
		return
	end
	installed = true

	Data.install()

	-- VIP IS SETTLED ON EVERY LOAD, not only on a purchase. A pass is owned
	-- forever once bought, so a join is the ONLY signal an account that bought
	-- it last week ever gives -- and `onReady` replays for profiles that are
	-- already loaded, so registering here cannot miss one. The latch inside
	-- settleVip is what makes "every load" cost nothing after the first.
	Data.onReady(function(player, _profile)
		task.spawn(Monetization.settleVip, player)
		-- ...and the extra-buildings passes, for the same reason and on the
		-- same latch shape: their attributes and their Money (2026-09-22).
		Monetization.settlePlusPasses(player)
	end)

	-- ...and the moment it is bought, without waiting for a rejoin. The pass
	-- branch of PromptGamePassPurchaseFinished below only fires these hooks
	-- once the SITE has confirmed ownership, which is exactly the condition
	-- settleVip re-tests.
	Monetization.onGranted(function(player, entry)
		if entry ~= nil and entry.key == "VIP" then
			task.spawn(Monetization.settleVip, player)
		elseif entry ~= nil and entry.kind == "pass" then
			-- Any other pass: its attribute flips, and its grant (if it has
			-- one) is paid, without a rejoin.
			task.spawn(Monetization.settlePass, player, entry.key)
		end
	end)

	MarketplaceService.ProcessReceipt = processReceipt

	-- ANALYTICS ONLY. A pass bought here is granted by re-querying ownership,
	-- not by trusting this signal: it fires on the client's prompt closing and
	-- is not an authority on whether money changed hands.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		local entry = Products.byPassId(passId)
		if entry == nil then
			return
		end
		if purchased then
			-- Clear the negative cache so the next ownsPass re-asks instead of
			-- serving a stale "no" for the rest of the minute.
			negativeCache[tostring(player.UserId) .. ":" .. entry.key] = nil
			Analytics.promptCompleted(player, entry, entry.robux)
			task.spawn(function()
				if RunService:IsStudio() then
					studioPasses[tostring(player.UserId) .. ":" .. entry.key] = true
				end
				-- CONFIRMED, THEN ANNOUNCED (2026-09-11). The onGranted hooks
				-- hear about a pass only once the site agrees it is owned --
				-- MatchmakerServer lights the room's arrows off this. Asked a
				-- few times, because ownership can take a moment to reach
				-- UserOwnsGamePassAsync after the prompt closes, and a "no"
				-- here would leave the arrows dim until the next join.
				for attempt = 1, 4 do
					if player.Parent == nil then
						return
					end
					if Monetization.ownsPass(player, entry.key) then
						for _, fn in grantedHooks do
							task.spawn(fn, player, entry)
						end
						return
					end
					negativeCache[tostring(player.UserId) .. ":" .. entry.key] = nil
					task.wait(2 * attempt)
				end
			end)
		else
			Analytics.promptCancelled(player, entry)
		end
	end)

	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		local entry = Products.byProductId(productId)
		if entry == nil then
			return
		end
		local player = Players:GetPlayerByUserId(userId)
		if player == nil then
			return
		end
		if not purchased then
			-- The completion side is recorded in ProcessReceipt, which is the
			-- only place that knows the grant actually happened.
			Analytics.promptCancelled(player, entry)
		end
	end)

	local live = #Products.live()
	print(("[ConquestMonetization] armed. %d product%s configured.%s"):format(
		live,
		live == 1 and "" or "s",
		live == 0 and " Nothing can be bought until Products has real ids." or ""
	))
end

return Monetization
