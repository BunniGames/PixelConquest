--!strict
-- Conquest :: Products -- the catalogue, and nothing else.
--
-- SHARED, not server-only, because a purchase is prompted from wherever the
-- button is and an asset id is public information anyway (anyone can read it
-- off the product page). What is NOT in here is any grant logic: this module
-- knows what exists and what it costs, and ConquestMonetization knows what
-- buying it does. Keeping those apart is what lets the client show a shop
-- without shipping the client a copy of the rules.
--
-- EVERY ID IS 0 UNTIL THE ASSET EXISTS ON THE SITE, and 0 is not a valid
-- Roblox asset id. That is deliberate: `isLive` is the single gate the rest of
-- the code checks, so an unconfigured product never prompts, never grants and
-- never appears in a shop -- instead of prompting a purchase that throws on
-- the client and looks like the game is broken.
--
-- TO CONFIGURE ONE: create the pass or developer product on the experience,
-- paste its id below, done. Nothing else in the codebase needs touching.
--
-- PASS vs PRODUCT is not a style choice, it decides the revenue ceiling:
--   * A GAME PASS is owned forever, once. Right for a CAPABILITY -- being
--     allowed to host, being allowed to touch the advanced settings.
--   * A DEVELOPER PRODUCT is consumable and repeatable. Right for anything
--     someone does more than once. A rename sold as a pass caps at one
--     purchase per account for the life of the game, and people rename
--     constantly -- see MONETIZATION.txt section 1.

local Products = {}

export type Kind = "pass" | "product"

export type Entry = {
	key: string,
	kind: Kind,
	id: number,
	name: string,
	blurb: string,
	-- DISPLAY ONLY, and it is allowed to be wrong. The site is the authority on
	-- price; this is here so a shop can lay out a card before the async
	-- GetProductInfo comes back, not so anything can charge from it.
	robux: number,
	-- WHAT IT GIVES, ONE LINE EACH, for a card with room to list them (the
	-- shop's GAMEPASSES tab). Optional: an entry without one is drawn from
	-- its blurb, which says the same things as a sentence.
	perks: { string }?,
	-- WHAT OWNING IT PAYS OUT, ONCE. A pass has no receipt, so anything it
	-- hands over is settled behind a latch on the profile the first time the
	-- site says the account holds it (ConquestMonetization.settlePass). Absent
	-- on a pass that is pure capability.
	grant: { money: number? }?,
	-- THE MONEY PRICE (2026-09-22, owner: "players can also buy it with the
	-- currency Money that they earn, make the progression for this much
	-- harder"). Absent on a pass that is Robux-only. The number is what a
	-- press charges (ConquestMonetization.buyPassWithMoney) and what the card
	-- prints; see MONEY PRICES below for how they were set.
	money: number?,
}

-- ================================================================= passes ==
--
-- THREE OF THE FOUR are HOST CAPABILITY. Nothing here is ever required to JOIN
-- a match -- that is the rule the whole design rests on. VIP is the exception
-- and it is marked as one over its own entry: it bundles the host capability
-- and then adds a troop-growth bonus on top, which is the only thing in this
-- file that is taken out of somebody else's round. One host pays and
-- everyone in that lobby gets the game they wanted, which is the only product
-- in this document that makes other people's rounds better rather than worse.

local PASSES: { [string]: Entry } = {
	-- ARMED 2026-09-11 (owner: "wire up host and advanced game passes into the
	-- game"). Both are sold as CAPABILITY in a private room: HOST opens the
	-- room's dials, ADVANCED is everything HOST is plus the extra modes
	-- (PrivateLobby.MODES -- Historical, so far). Creating and joining a room
	-- stay free. The gate is MatchmakerServer's `hostTier`, on the server; the
	-- page only dims the arrows to agree with it. They sat at 0 from
	-- 2026-09-04 until then, because a pass with nothing behind it is a pass
	-- somebody buys and receives nothing for.
	--
	-- NOTE WHAT THIS DOES AND DOES NOT PROTECT. Holding the id at 0 stops the
	-- GAME offering them. It does NOT stop the SITE: a game pass has a public
	-- product page and anyone who finds it can still buy it, and this file has
	-- no say in that. The only thing that closes that door is taking the passes
	-- off sale on the creator dashboard.
	HOST = {
		key = "HOST",
		kind = "pass",
		id = 1969592603, -- 79 R$, managed pricing on
		name = "Host Games",
		blurb = "Unlock your private lobby's settings: map, teams, starting troops and gold.",
		robux = 79,
		-- The shop card's list (2026-09-21): the blurb, one thing to a line.
		-- Short on purpose: an offer card is narrow, and a line that has to
		-- shrink to fit reads in a different size from the line above it.
		perks = {
			"LOBBY SETTINGS",
			"MAP AND TEAMS",
			"TROOPS AND GOLD",
		},
	},
	ADVANCED = {
		key = "ADVANCED",
		kind = "pass",
		id = 1969906389, -- 99 R$
		name = "Advanced Host Settings",
		blurb = "Everything in Host Games, plus extra game modes for your lobby.",
		robux = 99,
		-- The shop card's list (2026-09-21): the blurb, one thing to a line.
		perks = {
			"ALL OF HOST GAMES",
			"EXTRA GAME MODES",
		},
	},
	-- ARMED 2026-09-15 with the owner's id, verified live as a for-sale game
	-- pass on this experience ("VIP", 120 R$). It is the only pass that GRANTS
	-- anything -- HOST and ADVANCED are pure capability, where owning them IS
	-- the product and there is nothing to hand over -- so it is also the only
	-- one with a settlement path (ConquestMonetization.settleVip).
	--
	-- WHAT IT BUNDLES, and how each half answers MONETIZATION.txt section 0:
	--   * ALL GAME CREATION -- everything HOST and ADVANCED open (the gate is
	--     MatchmakerServer.hostTier, which asks for this pass first). Host-pays
	--     is section 2's whole argument: one player buys and everyone in that
	--     lobby gets the game they wanted, so bundling it costs nobody.
	--   * +10% TROOP GROWTH -- the one benefit that IS taken out of another
	--     player's round, and it is sold at exactly the size the boosted skins
	--     have carried since 2026-09-08. A tenth more income is a lead and not
	--     a wall: no combat constant moves and Sim.maxTroops does not, so the
	--     army arrives sooner and never gets bigger.
	--   * 10,000 MONEY, ONCE -- Config.VIP_MONEY_GRANT. Money buys cosmetics
	--     and nothing else, so this is the one grant here that cannot reach the
	--     map at all.
	--   * A CHAT TAG and the Rainbow territory pattern, both cosmetic. The
	--     pattern spends lightness only, like every other one (Patterns).
	VIP = {
		key = "VIP",
		kind = "pass",
		id = 1983032307, -- 120 R$, confirmed on sale via GetProductInfo 2026-09-15
		name = "VIP",
		blurb = "All game creation, +10% troop growth, 10,000 Money, a chat tag and the Rainbow pattern.",
		robux = 120,
		-- THE LIST THE SHOP CARD DRAWS (2026-09-21, owner: "a card in the VIP
		-- that just lists out what it gives out"): the blurb's five things,
		-- one to a line, in the order they matter. Keep the two in step.
		perks = {
			"ALL GAME CREATION",
			"+10% TROOP GROWTH",
			"+10,000 MONEY",
			"VIP CHAT TAG",
			"RAINBOW PATTERN",
		},
		-- ROBUX ONLY (owner, 2026-09-22: "vip cant be bought" with Money): no
		-- `money` field, so the card draws no Money pill and the server refuses.
	},
	PERSISTENT_LOBBY = {
		key = "PERSISTENT_LOBBY",
		kind = "pass",
		id = 0,
		name = "Persistent Lobby",
		blurb = "Your lobby re-forms after each round instead of dissolving.",
		robux = 0,
	},
	-- THE EXTRA BUILDINGS PASSES (2026-09-22, owner: "Made 3 more gamepasses
	-- ... I want these shown both in the lobby and when players press the +
	-- Card in game"). Ids and names as the site has them (GetProductInfo with
	-- the GamePass InfoType); the site's descriptions are the blurbs. The two
	-- that carry Money settle it once through `grant` (settlePass, VIP's
	-- latch shape). Ownership is published as the `ConquestPass_<KEY>` player
	-- attribute for the in-game page (Products.PASS_ATTR).
	--
	-- AND THEY ARE THE GATE, since 2026-09-22 (owner: "currently everyone has
	-- access to airfield, megabomb, artillery, and shit. I only want people who
	-- have the gamepass to have access to it" -- then, asked about the barracks:
	-- "they should all be locked for new players, but players who unlock it with
	-- money or gamepass can use it"). Each of the four names a rail card, and
	-- the card is off the rail until the pass is held:
	--   ARTILLERY -> the ARTILLERY card (Units.ARTILLERY, kind 18)
	--   AIRSTRIKE -> the AIRFIELD card and its sorties (kind 19)
	--   MEGANUKE  -> the MEGA NUKE card (Units.MEGA_NUKE, kind 17)
	--   BARRACKS  -> the REINFORCE card (Sim.reinforce)
	--   RAILGUN     -> the RAILGUN card and its shots (Units.RAILGUN, kind 21)
	--   SCATTERSHOT -> the SCATTERSHOT card (Units.SCATTERSHOT, kind 20)
	-- Three halves apiece, and all three read the same ConquestPass_<KEY>
	-- attribute so a Money sale opens the card exactly as a Robux one does:
	-- HUD.RAIL_ACTIONS.pass hides the tile, ConquestClient's `arm` shuts the
	-- hotkey, and ConquestServer's intents refuse the kind (Monetization.
	-- holdsPass) for the crafted client that skips both. The AI is untouched --
	-- bots build and fly theirs inside Sim, never through a remote.
	ARTILLERY = {
		key = "ARTILLERY",
		kind = "pass",
		id = 1987550354, -- 80 R$, on sale (checked 2026-09-22)
		name = "Artillery Battery Bundle",
		-- THE CARD'S PICTURE (owner, 2026-09-22: "instead of just having the
		-- names in the shop, i want the images"): the StarterGui.Images entry
		-- PassShop draws in the card's head, the name moving up top.
		art = "ArtilleryBattery",
		blurb = "Target opponents with cannons, plus 5,000 Money.",
		robux = 80,
		perks = { "CANNON BATTERIES", "+5,000 MONEY" },
		grant = { money = 5000 },
		-- MONEY PRICES CUT TO A FIFTH across the "+" page (owner, 2026-09-22:
		-- "make everything cost 5x less money in that shop"): 250k -> 50k,
		-- 1M -> 200k, 100k -> 20k, 200k -> 40k. The Robux prices are the site's.
		money = 50000,
	},
	AIRSTRIKE = {
		key = "AIRSTRIKE",
		kind = "pass",
		id = 1988684354, -- 320 R$, on sale (checked 2026-09-22)
		name = "Air Strike Bundle",
		art = "Airbase", -- the shop card's picture (see ARTILLERY)
		blurb = "Spawn air strikes, plus 5,000 Money.",
		robux = 320,
		perks = { "AIR STRIKES", "+5,000 MONEY" },
		grant = { money = 5000 },
		money = 200000,
	},
	-- THE MEGA NUKE (2026-09-22, owner: "i also added a mega nuke gamepass
	-- 1989902339"). The site: "Mega Nuke", 32 R$, "Nuke 4X Damage" -- the
	-- warhead with twice an atom bomb's radius, four times its ground
	-- (Nukes.CFG.MAGNITUDE). Pure capability, no grant.
	--
	-- ITS OWN CARD, NOT AN UPGRADE (owner, 2026-09-22: "I dont want it to be
	-- an upgrade of the Nuke, I want it to be a seperate card called Mega
	-- Nuke"). Holding this puts a second warhead card, MEGA NUKE, on the
	-- action rail beside NUKE (HUD.RAIL_ACTIONS `meganuke`, `pass =
	-- "MEGANUKE"`), and ConquestServer's nuke intent accepts Units.MEGA_NUKE
	-- from a holder (Monetization.holdsPass). The atom bomb is untouched. The
	-- perk lines say the card and the radius, not a damage multiplier, so the
	-- shop and the rail describe the same thing.
	MEGANUKE = {
		key = "MEGANUKE",
		kind = "pass",
		id = 1989902339, -- 32 R$, on sale (checked 2026-09-22)
		name = "Mega Nuke",
		art = "Mega Nuke Shop", -- the shop card's picture (see ARTILLERY); Images["Mega Nuke"] stays the rail sticker
		-- SOLD AS AREA, NOT RADIUS (owner, 2026-09-22: "advertise it as 4x blast
		-- area instead of 2x blast radius"): the same warhead -- twice the radii
		-- IS four times the ground -- but the bigger number is the one a buyer
		-- feels. The rail tip (HUD.RAIL_ACTIONS.meganuke) says the same thing.
		blurb = "Adds the MEGA NUKE card to your rail: its own warhead, four times a nuke's blast area.",
		robux = 32,
		perks = { "MEGA NUKE CARD", "4X BLAST AREA" },
		money = 20000,
	},
	-- NOT FOR SALE on the site as of 2026-09-22 (IsForSale false, no price).
	-- The shop reads that off the site and draws the card as SOON until the
	-- owner puts it on sale; nothing here has to change when they do.
	BARRACKS = {
		key = "BARRACKS",
		kind = "pass",
		id = 1990256322,
		name = "Troop Barracks Bundle",
		art = "Barracks", -- the shop card's picture (see ARTILLERY)
		blurb = "Barracks let you call in more troops for gold.",
		robux = 0,
		perks = { "TROOP BARRACKS", "TROOPS FOR GOLD" },
		-- FOR MONEY (owner, 2026-09-22: "reinforcements can be tho"). The site
		-- has no Robux price for it yet, so today this is the only way in: the
		-- Robux pill says SOON and the Money pill sells it.
		money = 40000,
	},
	-- THE LATE-GAME PAIR (owner, 2026-09-24: "scattershot: 1999838282 railgun:
	-- 1998602304", the day both weapons shipped). Site: "Railgun Bundle" 800 R$
	-- and "Scattershot Bundle" 64 R$, both on sale, no descriptions -- so, like
	-- the mega nuke, pure capability and no grant. Money prices on the page's
	-- measured 625 Money a Robux (MEGANUKE 32 R$ = 20k, AIRSTRIKE 320 = 200k).
	-- `art` is a StarterGui.Images entry holding the rail's pixel icon until the
	-- owner drops a shop render on it.
	RAILGUN = {
		key = "RAILGUN",
		kind = "pass",
		id = 1998602304, -- 800 R$, on sale (checked 2026-09-24)
		name = "Railgun Bundle",
		art = "Railgun Shop",
		blurb = "Adds the RAILGUN: tap it, then tap anywhere on the map to snipe a building.",
		robux = 800,
		perks = { "RAILGUN CARD", "NO RANGE LIMIT" },
		money = 500000,
	},
	SCATTERSHOT = {
		key = "SCATTERSHOT",
		kind = "pass",
		id = 1999838282, -- 64 R$, on sale (checked 2026-09-24)
		name = "Scattershot Bundle",
		art = "Scattershot Shop",
		blurb = "Adds the SCATTERSHOT: a nuke that brings 4-6 smaller warheads with it.",
		robux = 64,
		perks = { "SCATTERSHOT CARD", "4-6 EXTRA WARHEADS" },
		money = 40000,
	},
	-- 2X RELOAD (2026-09-25, owner: "a gamepass for 2x reload for all my
	-- buildings"). Pure capability, no grant: a holder's airfields, railguns,
	-- batteries, anti-nuke towers and silos all rearm in half the time
	-- (Config.FAST_RELOAD_MULT, applied in Units.cooldown). Reaches the sim
	-- through ConquestServer.applyPattern off the ConquestPass_FAST_RELOAD
	-- attribute, like VIP's growth. ARMED 2026-09-25 with the owner's id.
	FAST_RELOAD = {
		key = "FAST_RELOAD",
		kind = "pass",
		id = 1998782486, -- 29 R$, on sale (checked 2026-09-25)
		name = "2x Reload Speed",
		blurb = "Every building you own reloads twice as fast.",
		robux = 29,
		perks = { "2X RELOAD SPEED", "ALL BUILDINGS" },
	},
}

-- =============================================================== products ==

local DEV_PRODUCTS: { [string]: Entry } = {
	RENAME = {
		key = "RENAME",
		kind = "product",
		id = 3711224017,
		name = "Rename Your Nation",
		blurb = "Choose the name drawn across your territory.",
		robux = 19,
	},
	-- HELD AT 0 for the same reason as the two passes above: the asset exists
	-- (created 2026-09-04) and the grant below hands out a titleTokens, but
	-- NOTHING SPENDS ONE -- there is no picker over `Products.TITLES`. Unlike a
	-- pass this one is genuinely unreachable while it sits here, because a
	-- developer product has no public page to buy it from; the only route in is
	-- a prompt this game does not make.
	TITLE = {
		key = "TITLE",
		kind = "product",
		id = 0, -- real id 3711224089, 9 R$, managed pricing on
		name = "Nation Title",
		blurb = "A prefix in front of your nation's name.",
		robux = 9,
	},

	-- ===================================================== 2026-09-08 ==
	-- FIVE MORE, all developer products by the owner's call ("implement all
	-- of these as dev products"). Two of them are one-time unlocks sold
	-- through a consumable: the grant is idempotent (owning 2x Money twice is
	-- owning it once) and the shop stops offering them the moment the profile
	-- says they are owned, so a second purchase can only come from a modified
	-- client -- and it grants nothing extra if it does.
	--
	-- ALL FIVE ARMED 2026-09-08 with the owner's ids (verified live: every one
	-- resolves as a for-sale developer product). Every button behind these
	-- checks `isLive`, so parking one at 0 again makes it vanish cleanly: the
	-- shop card reads SOON, the 2x MONEY pill hides, and the REVIVE button
	-- only shows for somebody already holding a token.
	MONEY2X = {
		key = "MONEY2X",
		kind = "product",
		id = 3711927247, -- created by the owner 2026-09-08, managed pricing on
		name = "2x Money",
		blurb = "Every round pays double, forever.",
		robux = 99,
	},
	-- Bought IN THE MATCH, at the moment of death, from the HUD's REVIVE
	-- button. The grant is a token; ConquestServer spends it the instant a
	-- takeover can be honoured and carries it to the next round when it
	-- cannot (round over, no empire free to take).
	REVIVE = {
		key = "REVIVE",
		kind = "product",
		id = 3711927296, -- created by the owner 2026-09-08, managed pricing on
		name = "Revive",
		blurb = "Knocked out? Take command of an AI empire and fight on.",
		robux = 29,
	},
	-- BOOSTED SKINS. Each is a territory pattern (Patterns, tier "boosted")
	-- that also grows troops 10% faster while worn. One product per skin so
	-- each is priced and tracked on its own; the def in Patterns.LIST names
	-- its product, and ConquestMonetization builds the grants off that list,
	-- so this file only has to know the ids.
	SKIN_COMPASS = {
		key = "SKIN_COMPASS",
		kind = "product",
		id = 3711927393, -- created by the owner 2026-09-08, managed pricing on
		name = "Compass Skin",
		blurb = "A territory pattern that grows your army 10% faster.",
		robux = 99,
	},
	SKIN_SCALES = {
		key = "SKIN_SCALES",
		kind = "product",
		id = 3711927444, -- created by the owner 2026-09-08, managed pricing on
		name = "Scales Skin",
		blurb = "A territory pattern that grows your army 10% faster.",
		robux = 99,
	},
	SKIN_SERPENT = {
		key = "SKIN_SERPENT",
		kind = "product",
		id = 3711927501, -- created by the owner 2026-09-08, managed pricing on
		name = "Serpent Skin",
		blurb = "A territory pattern that grows your army 10% faster.",
		robux = 99,
	},

	-- ===================================================== 2026-09-15: flags ==
	--
	-- THE FLAG a player flies beside their name. ONE product rather than
	-- fifty-seven: the grant banks a TOKEN and the shop spends it on whichever
	-- flag was pressed. That is the shape RENAME, TITLE and REVIVE already use,
	-- and per ConquestMonetization's header it is the only shape that cannot
	-- lose a purchase when a receipt lands on a server that has never heard of
	-- the press that caused it.
	--
	-- A flag may ALSO name its own product (Flags.PRODUCTS), exactly the way a
	-- boosted skin does, if one is ever sold on its own. Both routes are wired;
	-- this is the one the shop reaches for by default.
	--
	-- ARMED 2026-09-15 (owner handed over the id). Every button behind it checks
	-- `isLive`, which is what kept the flag cards reading SOON while the id was 0;
	-- they now price themselves off the site and prompt for real.
	FLAG = {
		key = "FLAG",
		kind = "product",
		-- ARMED 2026-09-15 with the owner's id, confirmed live the same minute:
		-- GetProductInfo returns developer product "Flag", 24 R$, IsForSale true.
		-- The GamePass InfoType FAILS on this id, which is the check that proves it
		-- is a product -- so it buys through promptProduct, never promptGamePass.
		id = 3712976913,
		name = "Nation Flag",
		blurb = "Fly a nation's flag beside your name.",
		-- What to DRAW until the site answers. Managed pricing varies it by region,
		-- so every shop re-asks GetProductInfo and overwrites this; it exists so a
		-- card can be laid out before the async answer lands.
		robux = 24,
	},

	-- ======================================== 2026-09-12: the tutorial four ==
	--
	-- FOUR POWER ITEMS, SOLD ONLY INSIDE THE TUTORIAL (owner: "all of these
	-- ones with a ! at the end are mono specifically for tutorial only"). The
	-- `!` is the owner's own mark on the Creator Dashboard; `name` below is
	-- that list verbatim, so the code and the product page say the same thing
	-- when a support ticket names one.
	--
	-- WHY THE GATE IS THE WHOLE DESIGN, and not a nicety: MONETIZATION.txt
	-- section 0 -- Conquest is zero-sum over land. Troops, gold, a warhead and
	-- expansion rate are exactly the four things it says must never be sold,
	-- because each one is taken directly out of another player's game. Inside
	-- a tutorial none of that holds: the roster is bots, the student is
	-- protected for the grace window, and no human's round is touched. So
	-- these four are not an exception to the ground rule, they are the one
	-- place the ground rule does not apply -- and the moment one of them can
	-- be redeemed in a live match, it is. ConquestServer refuses unless
	-- `tutorialSession` is live: the gate `canRevive` uses, inverted.
	--
	-- THE GRANT IS A TOKEN, NOT THE EFFECT. A receipt can land on a lobby
	-- server, between rounds, or after the lesson has ended -- REVIVE learned
	-- this the hard way -- so the grant banks a token on the profile and the
	-- redeem spends it the moment a tutorial round can honour it. Nothing is
	-- lost if the student buys on the way out.
	--
	-- PRICES ARE THE LIVE ONES, read off the site 2026-09-12. They are display
	-- only (see the Entry type) and the site stays the authority.
	TUTORIAL_NUKE = {
		key = "TUTORIAL_NUKE",
		kind = "product",
		id = 3712496973, -- created by the owner 2026-09-11
		name = "+1 Nuke!",
		-- A FREE SHOT, not 750,000 gold. Gold would buy cities instead, which
		-- is not what the product says -- so the token is spent at the launch
		-- itself (Nukes charges on the execution's first tick, not at order).
		blurb = "One atom bomb, on the house. Fires without paying the gold.",
		robux = 64,
	},
	TUTORIAL_ARMY = {
		key = "TUTORIAL_ARMY",
		kind = "product",
		id = 3712497058, -- created by the owner 2026-09-11
		-- THE SITE STILL SAYS A MILLION, THE GRANT IS NOW 100K (owner, 2026-09-17:
		-- "instead of giving 1 million army, only give 100K"). `name` mirrors the
		-- Creator Dashboard VERBATIM by the rule at the top of this block -- so a
		-- support ticket naming the product finds it -- which means this line is
		-- the record of a mismatch rather than a mistake. Renaming it on the site
		-- is the owner's call; when that happens, this string follows it.
		name = "+1 Million Army Size!",
		-- A MILLION AS THE HUD PRINTS IT (owner's call, 2026-09-12). Troop
		-- figures are drawn troops/10 everywhere in this game, so the ceiling
		-- moves by 10,000,000 raw for the readout to say what the product
		-- does. See Config.TUTORIAL_ARMY_BONUS.
		-- SAYS WHAT IT NOW DOES, and it has moved twice. It first described a
		-- raised ceiling you had to refill into, which the owner replaced with the
		-- men themselves (2026-09-12); the figure then came down from a million to
		-- 100,000 (2026-09-17). A blurb is a promise on a product page, so it
		-- moves with the behaviour every time -- see Config.TUTORIAL_ARMY_BONUS.
		blurb = "100,000 troops at once, even past your army cap.",
		robux = 32,
	},
	TUTORIAL_GOLD = {
		key = "TUTORIAL_GOLD",
		kind = "product",
		id = 3712497141, -- created by the owner 2026-09-11
		name = "+1 Million Gold!",
		-- Gold is NOT divided by ten on the way to the screen (only troops
		-- are -- see Numbers.formatTroops against Numbers.format), so a
		-- million here is a million on the readout.
		blurb = "A million gold, straight into the treasury.",
		robux = 24,
	},
	TUTORIAL_FORCES = {
		key = "TUTORIAL_FORCES",
		kind = "product",
		id = 3712497348, -- created by the owner 2026-09-11
		name = "Special Forces (2x Attack Speed)!",
		-- Doubles the TILE BUDGET an attack spends per tick, which is what
		-- "attack speed" is in this sim -- not troop loss, not damage. Land
		-- arrives twice as fast; what it costs in troops is untouched.
		blurb = "Your attacks take ground twice as fast for the rest of the lesson.",
		robux = 32,
	},

	-- ==================================== 2026-09-17: Starter Pack #1 ==
	--
	-- THE FIRST BUNDLE IN THIS FILE: 25,000 troops, 100,000 gold and one
	-- free defence tower, for 9 R$. That is BELOW what the gold and the army
	-- cost separately (24 + 32) and the gap is deliberate -- a starter pack's
	-- job is the first purchase, not the margin on it.
	--
	-- REPEATABLE (owner, 2026-09-17: "players can keep buying it in the
	-- tutorial"). Nothing in it is idempotent the way MONEY2X is, so a second
	-- purchase grants a second lot and the redeem stacks rather than refusing.
	STARTER_PACK = {
		key = "STARTER_PACK",
		kind = "product",
		-- ARMED 2026-09-17 with the owner's id, confirmed the same minute:
		-- GetProductInfo returns developer product "Starter Pack #1", 9 R$,
		-- IsForSale true. The GamePass InfoType FAILS on this id, which is the
		-- check that proves it is a product -- so it buys through promptProduct,
		-- never promptGamePass.
		id = 3713310449,
		name = "Starter Pack #1",
		blurb = "25,000 troops, 100,000 gold and a free defence tower.",
		robux = 9,
	},

	-- ==================================== 2026-09-17: Starter Pack #2 ==
	--
	-- THE SECOND RUNG (owner, 2026-09-17): 25,000 troops, 100,000 gold and
	-- THREE defence towers. Note what does NOT move -- the army and the gold
	-- are #1's figures exactly. The pack ladder is not "more of everything",
	-- it is the same opening bought with more ground to hold it on, which is
	-- also the only half of this bundle that costs another player nothing:
	-- a defence post is a wall, not an attack.
	--
	-- REPEATABLE, like #1 and for the same reason -- every part of it is a
	-- quantity rather than a switch, so a second purchase grants a second lot
	-- and the redeem stacks instead of refusing. Owning #1 is not a
	-- prerequisite and nothing checks for it; the two are independent goods
	-- that happen to be numbered.
	STARTER_PACK2 = {
		key = "STARTER_PACK2",
		kind = "product",
		-- ARMED 2026-09-17 with the owner's id, confirmed the same minute:
		-- GetProductInfo returns developer product "Starter Pack #2", 40 R$,
		-- IsForSale true. The GamePass InfoType FAILS on this id, which is the
		-- check that proves it is a product -- so it buys through promptProduct,
		-- never promptGamePass.
		id = 3713310550,
		name = "Starter Pack #2",
		blurb = "Three free defence towers, a free city and a free anti-nuke tower.",
		-- 40 R$ against #1's 9. The gap is the three towers and the fact that
		-- #1 is priced as a first purchase rather than for its margin.
		-- DISPLAY ONLY -- every shop re-asks GetProductInfo and overwrites this;
		-- it exists so a card can be laid out before that async answer lands.
		robux = 40,
	},

	-- ================================ 2026-09-17: the gold top-ups ==
	--
	-- THREE RUNGS OF GOLD, SOLD AT ONE MOMENT (owner, 2026-09-17: "implement
	-- small top up, medium top up, big top up, for when players try to build a
	-- building but they dont have enough money"). This is NOT a currency store:
	-- the offer appears on a build click that was refused for gold and nowhere
	-- else, and only while the player is under 90% of the price
	-- (Config.TOPUP_OFFER_BELOW). GoldTopUpClient owns that judgement and its
	-- header carries the reasoning.
	--
	-- THE FIGURES ARE PRICED OFF THE BUILD LADDER rather than chosen round.
	-- Against Config's city steps (25k / 75k / 125k, then 250k / 500k / 1M),
	-- the atom bomb at 750k and the anti-nuke tower at ~1.5M:
	--   SMALL  100k   clears a first city, a first port, or a second city
	--   MEDIUM 500k   clears the 250k and the 500k rungs
	--   BIG    2M     clears a 1M rung, a warhead or a tower, with change
	-- The amounts live in Config, because the sim is what spends them; this
	-- file only sells.
	--
	-- REPEATABLE, like every consumable here -- gold is a quantity, so a second
	-- purchase is simply more of it and the redeem stacks rather than refusing.
	--
	-- NOT TUTORIAL-ONLY, and that is worth stating rather than leaving to be
	-- discovered. MONETIZATION.txt section 0 holds that gold is one of the four
	-- things a zero-sum territory game must never sell. The server gate that
	-- kept such things inside a lesson came out 2026-09-16 at the owner's
	-- instruction and the starter packs followed it out on 2026-09-17; these
	-- are built on that same decision, not on a new one.
	GOLD_SMALL = {
		key = "GOLD_SMALL",
		kind = "product",
		-- ARMED 2026-09-17, all three confirmed the same minute: GetProductInfo
		-- returns them as for-sale developer products, and the GamePass InfoType
		-- FAILS on each -- the check that proves they buy through promptProduct
		-- and never promptGamePass.
		--
		-- THE IDS WERE FOUND, NOT GUESSED. The owner had already created all
		-- three on the dashboard; `MarketplaceService:GetDeveloperProductsAsync()`
		-- lists every product on the universe with its id, which is the way to
		-- settle "does this exist yet" rather than asking.
		id = 3713342565,
		name = "Small Top Up",
		blurb = "100,000 gold, straight into the treasury.",
		-- Display only -- the site is the authority and every prompt prices
		-- itself there. Read off the dashboard 2026-09-17.
		robux = 9,
	},
	GOLD_MEDIUM = {
		key = "GOLD_MEDIUM",
		kind = "product",
		id = 3713342585,
		name = "Medium Top Up",
		blurb = "500,000 gold, straight into the treasury.",
		robux = 24,
	},
	GOLD_BIG = {
		key = "GOLD_BIG",
		kind = "product",
		id = 3713342604,
		name = "Big Top Up",
		blurb = "2,000,000 gold, straight into the treasury.",
		robux = 40,
	},

	-- ================================= 2026-09-22: the airfield's skip ==
	--
	-- THE REST OF A REARM, SOLD AT ONE MOMENT (owner, 2026-09-22: "if a player
	-- fires the airfield during its rearm phase, if theyre nowehere close (less
	-- than 75% of the rearm time) prompt this: 3714242483 skip time dev
	-- product"). Offered by ConquestServer from the airstrike intent's
	-- "cooldown" refusal and nowhere else, and only while less than
	-- Config.SKIP_REARM_OFFER_BELOW of the rearm has elapsed -- the top-ups'
	-- restraint, for the top-ups' reason. What it grants is that field's timer
	-- popped (ConquestServer.skipRearm); a receipt that finds nothing rearming
	-- becomes the next sortie's rearm instead, so a purchase is never lost.
	--
	-- REPEATABLE, like every consumable here: every rearm is a new wait.
	SKIP_REARM = {
		key = "SKIP_REARM",
		kind = "product",
		-- ARMED 2026-09-22 with the id the owner gave, confirmed on the universe
		-- by GetDeveloperProductsAsync the same minute (listed as "Skip ", 9 R$).
		id = 3714242483,
		name = "Skip",
		blurb = "Rearm the airfield now.",
		-- Display only; the site is the authority. Read off the listing 2026-09-22.
		robux = 9,
	},
}

-- A FIXED LIST, which is the entire point of it. A chosen title costs nothing
-- to moderate because there is no user text in it, and "Empire of Ravenhold"
-- reads as a nation where a username never will. Indices are the wire format:
-- append only, never reorder, or every stored profile renames itself.
Products.TITLES = {
	"", -- 1 is "no title", so a cleared title is a value rather than a nil
	"Empire of",
	"Republic of",
	"Kingdom of",
	"The Free Cities of",
	"Duchy of",
	"Confederation of",
	"Dominion of",
} :: { string }

Products.PASSES = PASSES
Products.DEV_PRODUCTS = DEV_PRODUCTS

-- WHICH PASSES EACH SHOP PAGE OFFERS, in the order it draws them (2026-09-22).
-- The lobby's GAMEPASSES tab sells VIP and the extra-buildings passes (owner:
-- "No need to show game host cards in the lobby. just vip is fine" -- HOST and
-- ADVANCED are sold from the room panel's locked dials instead); the in-game
-- "+" card sells only the extra-buildings passes ("Only these 3 should show up
-- for the + one in the game"). A key with no live id is skipped by the page.
Products.LOBBY_PASSES = { "VIP", "ARTILLERY", "AIRSTRIKE", "MEGANUKE", "BARRACKS", "SCATTERSHOT", "RAILGUN", "FAST_RELOAD" } :: { string }
-- CHEAPEST FIRST (owner, 2026-09-22: "orient them in order of least to most
-- expensive"): the page's order is its Money prices, sorted here so a price
-- change re-orders the page by itself; a pass with no Money price goes last.
Products.PLUS_PASSES = (function(): { string }
	local keys = { "ARTILLERY", "AIRSTRIKE", "MEGANUKE", "BARRACKS", "RAILGUN", "SCATTERSHOT", "FAST_RELOAD" }
	table.sort(keys, function(a: string, b: string): boolean
		local pa = if type(PASSES[a].money) == "number" then PASSES[a].money else math.huge
		local pb = if type(PASSES[b].money) == "number" then PASSES[b].money else math.huge
		return pa < pb
	end)
	return keys
end)()

-- THE ATTRIBUTE PREFIX under which the server publishes whether an account
-- holds each extra-buildings pass (`ConquestPass_ARTILLERY` = true / false,
-- written by ConquestMonetization.settlePass once the site has answered).
-- Shared, because the in-game page reads what the server writes.
Products.PASS_ATTR = "ConquestPass_"

-- ================================================================ lookups ==

function Products.pass(key: string): Entry?
	return PASSES[key]
end

function Products.product(key: string): Entry?
	return DEV_PRODUCTS[key]
end

function Products.get(key: string): Entry?
	return PASSES[key] or DEV_PRODUCTS[key]
end

-- Configured, i.e. has a real asset behind it. Check this before prompting
-- ANYTHING; see the header.
function Products.isLive(entry: Entry?): boolean
	return entry ~= nil and entry.id > 0
end

-- MONEY PRICES (2026-09-22). What a pass costs in the earned currency, or nil
-- for a pass that is Robux-only: HOST / ADVANCED (sold off the room dials)
-- and VIP (owner: "vip cant be bought" -- it is the one pass that changes
-- another player's round, and it stays behind Robux). Read by the card and
-- charged by the server from this one field, so the two cannot disagree.
--
-- HOW THEY WERE SET, so the next change is made the same way. Money is
-- earned at a measured 1,868-5,129 an hour of play, mean ~3,300
-- (MONEYBALANCE.txt, section 7), and the dearest cosmetic -- a legendary
-- pattern -- is 128,000, about 39 hours. The owner asked for the passes to
-- be a much harder climb than that, so they are priced off their Robux at
-- ~3,125 Money per Robux, rounded to a number a player can hold in their
-- head:
--     MEGA NUKE     32 R$  ->    100,000   (~30 hours)
--     BARRACKS   (no R$)  ->    200,000   (~60 hours; owner: "reinforcements
--                                          can be" bought -- no site price to
--                                          anchor on, so it sits between the
--                                          nuke and the battery)
--     ARTILLERY     80 R$  ->    250,000   (~75 hours)
--     AIR STRIKE   320 R$  ->  1,000,000   (~300 hours)
-- A pass that pays Money on top (its `grant`) still pays it to a Money buyer
-- -- the card lists it, so the buyer gets what the card says -- which is a
-- 5,000 rebate on a 50,000 price, and priced in.
function Products.moneyPrice(key: string): number?
	local entry = PASSES[key]
	if entry == nil or type(entry.money) ~= "number" or entry.money <= 0 then
		return nil
	end
	return math.floor(entry.money)
end

-- The reverse direction, which is the one ProcessReceipt needs: Roblox hands
-- back a numeric ProductId and the server has to say what was bought. Built
-- lazily rather than at load because ids are edited by hand and a table built
-- from zeroes would key three products under 0.
local function lookup(source: { [string]: Entry }, id: number): Entry?
	if id <= 0 then
		return nil
	end
	for _, e in source do
		if e.id == id then
			return e
		end
	end
	return nil
end

function Products.byProductId(id: number): Entry?
	return lookup(DEV_PRODUCTS, id)
end

function Products.byPassId(id: number): Entry?
	return lookup(PASSES, id)
end

-- Everything that is actually purchasable right now. A shop iterates this, so
-- a shop with nothing configured renders empty instead of rendering broken.
function Products.live(): { Entry }
	local out = {}
	for _, e in PASSES do
		if e.id > 0 then
			table.insert(out, e)
		end
	end
	for _, e in DEV_PRODUCTS do
		if e.id > 0 then
			table.insert(out, e)
		end
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

function Products.titleText(index: number?): string
	if index == nil then
		return ""
	end
	return Products.TITLES[index] or ""
end

function Products.isValidTitle(index: number?): boolean
	return index == nil or (type(index) == "number" and Products.TITLES[index] ~= nil)
end

return Products
