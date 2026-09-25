--!strict
-- Conquest :: ConquestNames  (server)
-- Validating and filtering a player-chosen nation name. Two layers, and they
-- catch different things:
--
--   LAYER 1 (validate)  -- what is wrong with this name FOR THIS GAME.
--   LAYER 2 (filter)    -- what Roblox will not allow to be shown to anyone.
--
-- Neither is optional and neither substitutes for the other. Roblox's filter
-- catches profanity and personal information; it has no opinion about a name
-- 40 characters long that overflows the map label, or about a human calling
-- themselves exactly what one of the bots is called.
--
-- IT IS NOT WIRED UP. Nothing calls in here yet; there is no remote, no UI and
-- no product. `Names.claim` is the operation the eventual feature will call,
-- and it is written now so the filtering rules are decided once, in one place,
-- rather than inline at the call site later.
--
-- THE FOUR FILTERING RULES THAT ARE EASY TO GET WRONG:
--
--   1. IT MUST RUN ON THE SERVER. A client-side filter is not a filter -- it
--      is a suggestion to an attacker who controls the client.
--
--   2. GetNonChatStringForBroadcastAsync, not GetChatForUserAsync. The nation
--      label lives in the SHARED map container and is drawn once for everyone,
--      so it has to be ONE string. The per-viewer variant would require a
--      different label per client, which this renderer cannot do.
--
--   3. FILTERING CAN THROW -- service outage, rate limit. On any failure the
--      name is REJECTED. Never fall through to displaying the raw string; that
--      failure mode is exactly the one that gets an experience moderated.
--
--   4. RE-FILTER AT ROUND START, not only at purchase. Roblox's block list
--      changes, and a name bought last month can become disallowed. A stored
--      name is a cache, not a verdict.

local TextService = game:GetService("TextService")

local Names = {}

Names.MIN_LEN = 3
Names.MAX_LEN = 16

-- A filtered result comes back as hashes. An all-hash name is obviously
-- rejected, but a PARTIALLY hashed one has to go too -- "Th######ck" is not a
-- name, it is evidence that the name was mostly a slur.
local MAX_HASH_FRACTION = 0.25

-- Names that read as system text. Substring match, case-insensitive, because
-- "Admin_" and "TheAdmin" are the same attempt.
local IMPERSONATION = {
	"admin", "moderator", "mod team", "roblox", "system", "server",
	"official", "staff", "developer", "owner of", "support",
}

-- Words this game's own UI prints. A nation called OVERTIME turns every
-- banner into a sentence about a player. Keep this in step with the banner
-- copy in HUD -- it is a list of strings, so nothing enforces that but a
-- reader.
local RESERVED = {
	"overtime", "eliminated", "victory", "defeat", "spectating",
	"waiting", "spawning", "neutral", "unclaimed", "bot", "npc",
}

-- Set at wire time from ConquestServer's BOT_NAMES. Not copied into this file
-- on purpose: two copies of a 80-name list drift, and a collision check
-- against a stale list is worse than no check because it looks like it works.
local botPool: { [string]: boolean }? = nil
local warnedNoPool = false

function Names.setBotPool(list: { string })
	local set = {}
	for _, n in list do
		set[string.lower(n)] = true
	end
	botPool = set
end

-- ================================================================ layer 1 ==

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function containsAny(lower: string, list: { string }): string?
	for _, needle in list do
		if string.find(lower, needle, 1, true) ~= nil then
			return needle
		end
	end
	return nil
end

-- Returns the cleaned name, or nil plus a reason the player can be shown.
-- Reasons are written to be readable in a dialog, not logged jargon.
function Names.validate(raw: any): (string?, string?)
	if type(raw) ~= "string" then
		return nil, "That isn't a name."
	end

	-- Collapse runs of whitespace before measuring, so "A          B" is not
	-- accepted as 12 characters of nation.
	local s = trim((string.gsub(raw, "%s+", " ")))

	-- EVERY BYTE MUST BE ASCII, and this runs FIRST so that the length check
	-- below is measuring characters rather than bytes -- five emoji are twenty
	-- bytes, and "too long" is the wrong thing to tell someone about them.
	-- This single check is what stops Zalgo (stacked combining marks smear
	-- vertically across a map drawn at one pixel a tile), emoji, zero-width
	-- joiners, right-to-left overrides and full-width Latin lookalikes -- all
	-- the same class of attack: characters that render as something the length
	-- check did not measure.
	if string.find(s, "[\128-\255]") ~= nil then
		return nil, "Letters, spaces, apostrophes and hyphens only."
	end

	if #s < Names.MIN_LEN then
		return nil, ("Too short -- at least %d characters."):format(Names.MIN_LEN)
	end
	if #s > Names.MAX_LEN then
		return nil, ("Too long -- at most %d characters."):format(Names.MAX_LEN)
	end
	if string.find(s, "^[%a][%a '%-]*$") == nil then
		return nil, "Letters, spaces, apostrophes and hyphens only, starting with a letter."
	end
	if string.find(s, "[%a]$") == nil then
		return nil, "Names have to end with a letter."
	end
	-- "A--B", "O''Hara": punctuation is for inside a word, not a decoration.
	-- Deliberately NOT matching a punctuation mark followed by a space, or
	-- "Kings' Landing" would be refused.
	if string.find(s, "['%-]['%-]") ~= nil then
		return nil, "Names can't have two punctuation marks in a row."
	end

	local lower = string.lower(s)

	local hit = containsAny(lower, IMPERSONATION)
	if hit ~= nil then
		return nil, "That name isn't available."
	end
	if containsAny(lower, RESERVED) ~= nil then
		return nil, "That word is used by the game's own interface."
	end

	if botPool ~= nil then
		if botPool[lower] then
			-- A real gameplay deception, not a cosmetic one: people play
			-- differently against bots, and a human wearing a bot's name is
			-- buying a tactical advantage for the price of a rename.
			return nil, "That's one of the AI empire names."
		end
	elseif not warnedNoPool then
		warnedNoPool = true
		warn("[ConquestNames] no bot pool set -- the AI-name collision check is INACTIVE. Call Names.setBotPool(BOT_NAMES).")
	end

	return s, nil
end

-- ================================================================ layer 2 ==

local function hashFraction(s: string): number
	local hashes = 0
	local letters = 0
	for i = 1, #s do
		local c = string.sub(s, i, i)
		if c == "#" then
			hashes += 1
			letters += 1
		elseif c ~= " " then
			letters += 1
		end
	end
	if letters == 0 then
		return 1
	end
	return hashes / letters
end

-- Yields. Returns the filtered string, or nil plus a reason.
function Names.filter(clean: string, userId: number): (string?, string?)
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(clean, userId, Enum.TextFilterContext.PublicChat)
	end)
	if not ok or result == nil then
		-- Rule 3. The name is refused, not shown raw.
		warn("[ConquestNames] FilterStringAsync failed: " .. tostring(result))
		return nil, "Couldn't check that name right now -- try again in a moment."
	end

	local ok2, safe = pcall(function()
		return (result :: any):GetNonChatStringForBroadcastAsync()
	end)
	if not ok2 or type(safe) ~= "string" then
		warn("[ConquestNames] GetNonChatStringForBroadcastAsync failed: " .. tostring(safe))
		return nil, "Couldn't check that name right now -- try again in a moment."
	end

	if hashFraction(safe) > MAX_HASH_FRACTION then
		return nil, "That name isn't available."
	end

	return safe, nil
end

-- Both layers, in the order that costs least: the local rules are free and
-- reject most bad input, so the network round trip only happens for names that
-- could plausibly be accepted. Yields.
function Names.check(raw: any, userId: number): (string?, string?)
	local clean, why = Names.validate(raw)
	if clean == nil then
		return nil, why
	end
	return Names.filter(clean, userId)
end

-- Rule 4. Cheap to call at round start for every human in the roster; a name
-- that no longer passes falls back to the username rather than being shown.
function Names.recheck(stored: string?, userId: number): string?
	if stored == nil or stored == "" then
		return nil
	end
	local safe = Names.check(stored, userId)
	return safe
end

-- =================================================================== claim ==
--
-- The whole operation, so that the eventual remote handler is three lines and
-- has no policy in it. Spends a rename token IF ONE IS BEING SPENT -- the
-- first claim costs one and every later edit is free, see the gate below --
-- and whatever it takes is taken back if the save fails, the same durability
-- rule ProcessReceipt follows, for the same reason.

local Data = require(script.Parent:WaitForChild("ConquestData"))

function Names.claim(player: Player, raw: any): (boolean, string)
	local profile = Data.get(player)
	if profile == nil then
		return false, "Your profile isn't loaded yet."
	end
	-- WHAT UNLOCKS A CLAIM: a token in hand, OR having already renamed once
	-- (owner, 2026-09-04: "once a player renames once, they should be able
	-- to edit their name"). The purchase buys the RIGHT TO BE NAMED rather
	-- than one particular string, so every edit after the first is free --
	-- which also means a typo no longer costs what the name cost.
	--
	-- THE PROFILE'S OWN `nationName` IS THE RECORD OF THAT RIGHT, not a
	-- separate flag. It is set here and nowhere else, it is what the page
	-- already reads to draw the field, and a flag beside it could only ever
	-- disagree with it.
	local free = type(profile.nationName) == "string" and profile.nationName ~= ""
	if not free and (profile.renameTokens or 0) <= 0 then
		return false, "You don't have a rename."
	end

	local safe, why = Names.check(raw, player.UserId)
	if safe == nil then
		return false, why or "That name isn't available."
	end

	local previous = profile.nationName
	-- A FREE EDIT SPENDS NOTHING, and `spent` rather than a branch because
	-- the rollback below has to give back exactly what was taken. Somebody
	-- who has renamed once AND is holding tokens keeps them: they bought
	-- the right and already own it, and quietly eating a token they no
	-- longer need is the sort of thing that ends up in a refund request.
	local spent = free and 0 or 1
	profile.nationName = safe
	profile.renameTokens = (profile.renameTokens or 0) - spent
	-- THE ABUSE PATH THIS CLOSES: rename, do something reportable, rename
	-- again. Without a history, moderation has a report against a name that no
	-- longer exists on any account. It costs one string.
	profile.nameHistory = profile.nameHistory or {}
	table.insert(profile.nameHistory, { name = safe, t = os.time() })
	while #profile.nameHistory > 50 do
		table.remove(profile.nameHistory, 1)
	end

	if not Data.flush(player) then
		profile.nationName = previous
		profile.renameTokens = profile.renameTokens + spent
		table.remove(profile.nameHistory)
		return false, "Couldn't save that -- try again in a moment."
	end

	return true, safe
end

return Names
