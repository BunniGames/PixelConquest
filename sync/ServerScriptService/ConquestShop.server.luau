--!strict
-- Conquest :: ConquestShop  (server)
--
-- The rename product, end to end: the prompt, the claim, and the one attribute
-- that carries an accepted name into the round.
--
-- Everything underneath it was built inert (MONETIZATION.txt section 7) and
-- this is the first thing to call in, so it is also where the traps that only
-- appear once money actually moves get handled.
--
-- IT RUNS IN BOTH ROLES, with nothing conditional on the role attribute. A
-- lobby server is where the name is typed and a match server is where it is
-- drawn -- but a RECEIPT can arrive at either, since a player who buys on the
-- page and teleports before it lands gets the grant on the far side, and the
-- session lock is what makes that safe.
--
-- FOUR THINGS THAT ARE NOT OBVIOUS:
--
--   1. THE CLAIM IS GUARDED PER PLAYER, BECAUSE `Names.claim` YIELDS. It reads
--      the token count, waits on FilterStringAsync, and only then spends. Two
--      claims in flight from one client both pass the token check before
--      either decrements: one purchase, two renames, and a token count of -1.
--      A client decides how often it fires a remote, so that is reachable on
--      purpose and not merely by bad luck.
--
--   2. THE ACCEPTED NAME TRAVELS AS A PLAYER ATTRIBUTE. ConquestServer builds
--      the roster and this file owns the name; one Script cannot require
--      another, and the name is public the moment it is drawn across a
--      territory, so an attribute is both the cheapest channel available and
--      no kind of leak. ConquestServer falls back to DisplayName whenever it
--      is unset, which is what makes every failure path below safe by default.
--
--   3. A FILTER OUTAGE MUST NOT ERASE A PAID-FOR NAME. Rule 4 in ConquestNames
--      says re-filter after a load, because Roblox's block list moves and a
--      name bought last month can become disallowed. But `recheck` returns nil
--      for a service outage exactly as it does for a refusal, and treating
--      those the same would delete a purchase every time the filter has a bad
--      minute. So a failed recheck leaves `profile.nationName` alone and
--      simply does not set the attribute: the player is their display name for
--      that session and has their nation back on the next join.
--
--   4. NOTHING HERE INSTALLS ANYTHING. `Monetization.install()` is called at
--      the foot of ConquestServer, in the position `Data.install()` already
--      held, because that position is load-bearing: Analytics registers a
--      PlayerRemoving that banks playtime onto the profile and Data's own
--      PlayerRemoving releases it. Connection order is registration order, so
--      arming the receipt handler from HERE -- a different Script, with no
--      ordering guarantee against that one -- could put the release ahead of
--      the write.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Net = require(Shared.Net)
local Products = require(Shared.Products)

local Data = require(script.Parent:WaitForChild("ConquestData"))
local Names = require(script.Parent:WaitForChild("ConquestNames"))
local Monetization = require(script.Parent:WaitForChild("ConquestMonetization"))

-- READ BY ConquestServer WHEN IT BUILDS THE ROSTER. Set only to a string that
-- has been through both filter layers THIS SESSION; unset means "use the
-- display name", which is the answer for everyone who has never bought a
-- rename and for every failure below.
local NATION_ATTR = "ConquestNation"

local ShopRE = Net.build(ReplicatedStorage):WaitForChild("Shop") :: RemoteEvent

-- ONE CLAIM AT A TIME PER PLAYER -- see note 1. Cleared immediately after the
-- pcall returns, so a throw inside the claim cannot wedge somebody out of ever
-- renaming again for the rest of the session.
local claiming: { [Player]: boolean } = {}

-- A floor on how often one client can make this server do something expensive.
-- Both routes behind it cost a web call -- FilterStringAsync one way, the
-- purchase prompt the other -- and neither is a thing a person does twice in a
-- second.
local GAP = 1.5
local lastAt: { [Player]: number } = {}

local function tooSoon(player: Player): boolean
	local now = os.clock()
	if now - (lastAt[player] or -1e9) < GAP then
		return true
	end
	lastAt[player] = now
	return false
end

-- =================================================================== state ==

-- What the page needs in order to draw the field: what is left to spend, and
-- the name it is showing. The ATTRIBUTE is sent rather than
-- `profile.nationName`, so a name which failed its recheck is not printed back
-- as though it were live.
--
-- THE TOKEN COUNT GOES FIRST AND THE NAME LAST, which is not cosmetic. The
-- name is nil for everyone who has never bought a rename, and a nil in the
-- MIDDLE of a remote's arguments is the kind of thing that is fine until one
-- day it is not -- and the way it would fail here is that the count after it
-- arrives as nil, reads as zero, and locks the field of somebody who has
-- already paid. Last position, where a nil costs nothing.
local function push(player: Player)
	local profile = Data.get(player)
	if profile == nil then
		return
	end
	ShopRE:FireClient(player, "nation", tonumber(profile.renameTokens) or 0, player:GetAttribute(NATION_ATTR))
end

-- ================================================================= on load ==

Data.onReady(function(player, profile)
	local stored = profile.nationName
	if type(stored) == "string" and stored ~= "" then
		-- Rule 4; note 3 for why a nil here is not a deletion. This runs in
		-- ConquestData's own spawned thread, so the yield costs the load
		-- pipeline nothing.
		local safe = Names.recheck(stored, player.UserId)
		if safe ~= nil then
			player:SetAttribute(NATION_ATTR, safe)
		else
			warn(("[ConquestShop] %s's stored nation name did not pass a recheck; using their display name this session."):format(player.Name))
		end
	end
	push(player)
end)

Players.PlayerRemoving:Connect(function(player)
	claiming[player] = nil
	lastAt[player] = nil
end)

-- ================================================================ requests ==

ShopRE.OnServerEvent:Connect(function(player, kind, a)
	if kind == "buy" then
		if tooSoon(player) then
			return
		end
		-- WHICH PRODUCT (2026-09-08). Absent means the rename, which is what
		-- this remote carried before the shop sold anything else. Anything
		-- named has to be a developer product this build knows -- a pass, or a
		-- made-up key, falls back to the rename rather than to an error --
		-- and Monetization refuses the ones with no id yet.
		local key = (type(a) == "string" and Products.product(a) ~= nil) and a or "RENAME"
		-- Already pcall'd inside Monetization, and a false back only means the
		-- product is not configured -- which is a deploy fact, not something to
		-- tell the player about.
		Monetization.promptProduct(player, key)
	elseif kind == "pass" then
		if tooSoon(player) then
			return
		end
		-- A ROOM DIAL'S PASS (2026-09-11): the room panel's dimmed arrows ask
		-- for HOST or ADVANCED. Only a pass this build knows. Buying grants
		-- nothing here -- ownership IS the grant, and Monetization re-asks the
		-- site when the prompt closes.
		if type(a) == "string" and Products.pass(a) ~= nil then
			Monetization.promptPass(player, a)
		end
	elseif kind == "passmoney" then
		-- THE SAME PASS, PAID IN MONEY (2026-09-22). Settled here and now --
		-- there is no site prompt to wait on -- and answered on this remote,
		-- balance included, so the page that asked can print the reason or
		-- the new number at once. The OWNED flip follows on the lobby's own
		-- "passes" push, or the attribute in a match.
		if tooSoon(player) then
			return
		end
		if type(a) ~= "string" or Products.pass(a) == nil then
			return
		end
		local ok, why = Monetization.buyPassWithMoney(player, a)
		if player.Parent ~= nil then
			ShopRE:FireClient(player, "passmoney", a, ok, why, Data.money(player))
		end
	elseif kind == "money" then
		-- THE BALANCE, ASKED FOR. The lobby is told on load and on every change
		-- (MatchmakerServer); a match server's "+" page has no such push and
		-- asks when it opens. Not rate-limited: one number off a table that is
		-- already in memory.
		if player.Parent ~= nil then
			ShopRE:FireClient(player, "money", Data.money(player))
		end
	elseif kind == "name" then
		if tooSoon(player) then
			ShopRE:FireClient(player, "denied", "One at a time.")
			return
		end
		if claiming[player] then
			-- A second commit while the first is still filtering. Silent on
			-- purpose: the claim in flight will push the real answer in a
			-- moment, and two messages about one name is one too many.
			return
		end
		claiming[player] = true
		local ok, granted, detail = pcall(Names.claim, player, a)
		claiming[player] = nil
		if not ok then
			warn(("[ConquestShop] claim threw for %s: %s"):format(player.Name, tostring(granted)))
			ShopRE:FireClient(player, "denied", "Couldn't do that right now -- try again in a moment.")
			push(player)
			return
		end
		if granted then
			-- `detail` is the ACCEPTED name on this path -- the filtered string,
			-- not the one that was typed. See Names.claim.
			player:SetAttribute(NATION_ATTR, detail)
		else
			ShopRE:FireClient(player, "denied", tostring(detail))
		end
		-- BOTH WAYS. A refusal has to repaint too, or a field still holding a
		-- rejected name reads as though it had been accepted.
		push(player)
	end
end)
