--!strict
-- Conquest :: TutorialShopClient  (client)
--
-- The tutorial's four deals -- VIP, "+1 Nuke!", "+1 Million Gold!" and
-- "+1 Million Army Size!" -- sold out of the owner's own store UI at
-- StarterGui.Store, opened by a shop tab on the left edge of the HUD.
--
-- WHICH ART, AND WHY THIS NOTE KEEPS GROWING. This file has now driven three
-- different drawings, and each move was the owner pointing at the right one:
--   1. StarterGui.Images.HudShopTutorial -- a two-card sticker stack. Wrong: it
--      was simply the only shop-shaped thing inside the Images FOLDER, and the
--      real UI was a sibling of that folder, not inside it.
--   2. StarterGui["shop frame"] -- a four-card panel. Right at the time, wrong
--      now.
--   3. StarterGui.Store -- THIS one (owner, 2026-09-15: "Added a new store. use
--      that one instead").
-- The lesson worth keeping: list StarterGui ITSELF before believing any folder
-- inside it holds the shop.
--
-- WHICH SLOT SELLS WHAT (owner: "only use straberry elephan to sell VIP. and the
-- 3 square boxes to sell the otehr 3 dev products"):
--
--     Container.Brainrot1            "Strawberry Elephant", 477x116  -> VIP
--     Container.Gamepasses.2xCash    151x151                         -> +1 Nuke
--     Container.Gamepasses.SuperLuck 151x151                         -> +1M Gold
--     Container.Gamepasses.MEGALuck  151x151                         -> +1M Army
--
-- "THE 3 SQUARE BOXES" WAS MEASURED, NOT GUESSED. Three groups in this store are
-- horizontal rows of three, and only one is square: Gamepasses renders 151x151
-- per child (w/h 1.00), against LuckyBlocks at 151x196 (0.77) and Cash at 151x257
-- (0.59). They are also the right shape for the job -- each ships a Name, an
-- Icon, a Des description and a BuyButtons/Price, which is exactly a product
-- card.
--
-- NOTE THE STORE SHIPS ITS OWN "VIP" SLOT (Container.VIP, "VIP RANK"). It is
-- deliberately NOT used: the owner named Brainrot1 for VIP, so the kit's own VIP
-- card is hidden with the rest of the unsold stock.
--
-- NOTHING IS RESIZED OR REPOSITIONED HERE, and that is a rule learned the hard
-- way. A previous pass forced each sticker to a centred square and the cards
-- stopped looking like the owner's drawing; the pass after that left the
-- template's own multipliers alone, and because those are tuned for WIDE art a
-- square sticker blew out to 1.94x its card and spilled over the borders (owner:
-- "does this shit look right to you"). This store needs neither fix: its icon
-- boxes are ALREADY square -- 66x66 in a square box, ~141x142 in the hero -- so
-- the image id is swapped and every rectangle is left exactly where the kit put
-- it.
--
-- IT IS ITS OWN SCRIPT RATHER THAN A HUD PANEL, for two reasons that are both
-- about pressure elsewhere: ConquestClient sits at Luau's 200-local ceiling, and
-- the HUD is one 2,700-line class that every readout in the game already shares.
-- A RemoteEvent fans out to EVERY listener on the client, so this file reads the
-- same "State" channel ConquestClient reads without either knowing about the
-- other, and adds nothing to either.
--
-- WHY THE ART IS CLONED OUT OF StarterGui, not PlayerGui. It cannot come from
-- PlayerGui because `Players.CharacterAutoLoads` is FALSE in this place: nobody
-- ever spawns a character, so StarterGui is never copied into anybody's
-- PlayerGui and the folder there does not exist at all. StarterGui itself
-- replicates to clients, so the template is readable either way.
--
-- THE PROMPT GOES THROUGH THE SERVER (ShopRE), never MarketplaceService from
-- here. ConquestShop already accepts any developer product key and hands it to
-- Monetization.promptProduct, which keeps the `isLive` gate and the pcall around
-- the prompt in ONE place -- the same route the lobby's rename takes.
--
-- ...AND A PASS IS A DIFFERENT VERB, which is the one thing about VIP that is
-- easy to get wrong: `buy` is PromptProductPurchase and VIP is a GAME PASS, so
-- sending it up the product route would prompt nothing at all -- ConquestShop's
-- `buy` branch falls back to the RENAME for any key that is not a developer
-- product, so a VIP card wired that way would quietly sell a rename. `pass` is
-- the branch that reaches Monetization.promptPass.
--
-- WHY THE THREE POWER ITEMS MAY ONLY BE REDEEMED INSIDE A LESSON.
-- MONETIZATION.txt section 0: this game is zero-sum over land, so troops, gold,
-- a warhead and expansion rate are the four things it must never sell -- each is
-- taken straight out of another player's game. ConquestServer.redeemBoost
-- enforces it. The CARDS still show in every round (owner: "i told you what i
-- wanted in each of the 4 slots"); what a press is worth at a given moment is the
-- server's business, not the layout's. VIP is exempt either way -- it is sold
-- everywhere and grants through settleVip.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Icons = require(Shared.Icons)
local Matchmaker = require(Shared.Matchmaker)
local Net = require(Shared.Net)
local Products = require(Shared.Products)
local Sfx = require(Shared.Sfx)

-- A lobby server runs no round, so it runs no lesson. YIELDING here rather than
-- returning is deliberate and is what ConquestClient does: a Studio lobby FLIPS
-- to "match" when its own countdown fires.
Matchmaker.awaitRole("match")

local netFolder = Net.await(ReplicatedStorage)
local StateRE = netFolder:WaitForChild("State") :: RemoteEvent
local ShopRE = netFolder:WaitForChild("Shop") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Set by ConquestMonetization.settleVip on every VIP's profile load, and again
-- the moment a purchase settles. A PLAYER ATTRIBUTE REPLICATES, so this is the
-- whole channel -- no remote, no request, and it changes under us live when the
-- card below is the thing that just sold the pass.
local VIP_ATTR = "ConquestVip"

-- The owner's crown, uploaded 2026-09-15 and read off StarterGui.Images.Crown.
-- It replaced the game LOGO, which stood in for a day and was the wrong shape:
-- a logo is a WORDMARK, and in a square icon box it shrank to a smear.
local CROWN = "rbxassetid://101324863778273"

-- THE TOP THREE THINGS VIP BUYS (owner: "Describe the top 3 benefits of VIP"),
-- taken from Products.VIP's blurb and ordered the way a purchase is decided: the
-- benefit that touches the map, then what you can host, then the currency. The
-- chat tag and the Rainbow pattern are real but cosmetic and lose their place.
--
-- KEEP IN STEP WITH Products.VIP.blurb -- one promise written twice, and a card
-- that disagrees with the product page it links to is worse than one saying less.
local VIP_BENEFITS = {
	"+10% TROOP GROWTH",
	"HOST ANY GAME",
	"10,000 MONEY",
}

-- WHERE THE VIP TEXT SITS (owner, 2026-09-16: "move the text to be stacked ... on
-- the right side in the open space of the red card").
--
-- THE SPACE IS REAL AND MEASURED. Every label the kit puts on this card is pinned
-- hard left -- Name at x 0.014, AmountLeft at 0.014, InfoFrame at 0.010, none wider
-- than 0.670 -- while the crown is centred at 0.500 and the buy pill sits at 0.885.
-- That leaves x 0.62..0.84 carrying nothing at all.
--
-- IT MUST CLEAR THE CROWN, which is the trap on this card: the crown bleeds to
-- y 237, far outside its own frame, so anything placed near the middle collides
-- with art rather than with a rectangle. Starting at 0.60 keeps the block right of
-- it. Drawn at ZIndex 12 to match the kit's own labels, one above the crown's 11,
-- so the lines read over the bleed rather than under it.
-- MEASURED OFF THE RENDERED RECTS, not the authored positions. On a card spanning
-- x 345..825, y 104..220, the live layout is:
--     Name   x 352..673  y 107..127
--     crown  x 514..656  y  91..233   <- bleeds far outside its own frame
--     pill   x 754..785  y 178..209
--
-- TWO WRONG TRIES, BOTH INSTRUCTIVE. Starting at 0.60 (x 633) clipped the crown
-- by 23 px, because 0.6 was chosen against the crown's AUTHORED centre and the
-- crown bleeds right to 656. Narrowing into the gap between crown and pill
-- (x 0.655..0.850) cleared every rectangle and was still wrong: that column is
-- 94 px, and the same lines measured TextSize 14 in a 177 px box, so TextScaled
-- would have shrunk them to about 7 px -- geometrically perfect and unreadable.
--
-- SO THE BLOCK GOES WIDE AND STOPS ABOVE THE PILL instead of squeezing beside it.
-- It starts past the crown's bleed (0.65) and runs to the card's edge (0.99),
-- keeping ~162 px of width; vertically it sits under Name and finishes above the
-- pill's top at y 0.638. Nothing is resized, nothing else moves.
local VIP_TEXT_X = 0.65
local VIP_TEXT_W = 0.34
local VIP_TEXT_TOP = 0.2
local VIP_TEXT_BOTTOM = 0.62

-- WHAT A PACK CARD PRINTS, TILE BY TILE. The kit's two bundle strips each carry
-- a three-tile `Rewards` row -- Icon, Name, Amount -- and three is exactly what
-- a pack grants, so nothing is added and nothing is hidden: the drawing already
-- had the right number of boxes.
--
-- "+25K" AND NOT "+250,000": troops reach the screen as troops/10 everywhere in
-- this game (Numbers.formatTroops), so the card prints the figure the player's
-- own readout will print. Gold is not divided on the way out, so that one is
-- literal. The raw numbers are Config's two Starter Pack blocks.
--
-- KEEP IN STEP WITH TutorialDealClient.PACK_ROWS, which prints these same three
-- tiles for #1 on the HUD sticker's page. Two drawings of one promise.
local PACK1_ROWS = {
	{ icon = Icons.SWORD, name = "Army", amount = "+25K" },
	{ icon = Icons.GOLD, name = "Gold", amount = "+100K" },
	{ icon = Icons.TOWER, name = "Defence", amount = "x1" },
}
-- #2 IS BUILDINGS (owner, 2026-09-17 evening: "3 defences. 1 City. and 1 Anti
-- Nuke defence"): no army, no gold. Three tiles, three kinds of free build,
-- each spent at its placement -- see Economy.FREE_FIELD.
local PACK2_ROWS = {
	{ icon = Icons.TOWER, name = "Defence", amount = "x3" },
	{ icon = Icons.HOUSE, name = "City", amount = "x1" },
	{ icon = Icons.DOME, name = "Anti-Nuke", amount = "x1" },
}

-- WHICH PRODUCT IS IN WHICH SLOT. `path` is walked from Container.
--
-- `kind` picks the verb and getting it wrong is silent rather than loud.
-- `desc` fills the kit's own description slot -- `Des` on a square box, and the
-- subtitle line on the hero -- so each card says what the thing DOES, which is
-- the one job the template left to whoever filled it in.
-- `rewards` is the bundle strips' own field: a pack card has no single sticker,
-- because its three reward tiles ARE its art.
local SLOTS = {
	{
		path = { "Brainrot1" },
		key = "VIP",
		kind = "pass",
		label = "VIP RANK",
		icon = CROWN,
		desc = VIP_BENEFITS,
	},
	{
		path = { "Gamepasses", "2xCash" },
		key = "TUTORIAL_NUKE",
		kind = "product",
		label = "+1 NUKE",
		icon = Icons.NUKE,
	},
	{
		path = { "Gamepasses", "SuperLuck" },
		key = "TUTORIAL_GOLD",
		kind = "product",
		label = "+1M GOLD",
		icon = Icons.GOLD,
	},
	{
		path = { "Gamepasses", "MEGALuck" },
		key = "TUTORIAL_ARMY",
		kind = "product",
		-- "+100K ARMY" (owner, 2026-09-17), because the grant came down from a
		-- million: Config.TUTORIAL_ARMY_BONUS is 1,000,000 raw and troops print
		-- raw/10, so the card now promises exactly what the treasury will show.
		-- A card quoting the old figure would be the only place in the game still
		-- selling a million.
		label = "+100K ARMY",
		icon = Icons.SWORD,
	},
	-- THE TWO BUNDLE STRIPS, back on the page 2026-09-17. They sort after the
	-- power-up row on the kit's own LayoutOrder (55 and 60 against 45), so the
	-- store now reads hero, three squares, then the two packs -- and with six
	-- cards it scrolls, which is what the ScrollingFrame is for.
	--
	-- `icon` IS EMPTY AND THAT IS NOT AN OVERSIGHT: these cards have no `Icon`
	-- child at all, so `wire` finds nothing to paint and every sticker rule
	-- below simply does not apply to them.
	{
		path = { "StarterPack" },
		key = "STARTER_PACK",
		kind = "product",
		label = "STARTER PACK",
		icon = "",
		rewards = PACK1_ROWS,
	},
	-- "PRO PACK" IS Starter Pack #2 ON THE SITE. The card wears the kit's name
	-- for this strip and the product page wears the owner's; they are the same
	-- purchase, and the label is one word to change if the receipt should match.
	{
		path = { "PROPack" },
		key = "STARTER_PACK2",
		kind = "product",
		label = "PRO PACK",
		icon = "",
		rewards = PACK2_ROWS,
	},
}

-- EVERY OTHER SLOT IN THE STORE IS HIDDEN. The kit advertises brainrots, luck
-- boosts and cash packs, none of which this game sells; a store listing four real
-- products and eleven imaginary ones is worse than a short store. The two
-- section headers go WITH them (owner, 2026-09-16: "remove vip and power ups
-- text"). They were briefly retexted to keep the kit's two-section rhythm; the
-- owner wants the page to speak through the cards alone, and four products do
-- not need to be told apart by a caption.
--
-- StarterPack AND PROPack CAME BACK OFF THIS LIST 2026-09-17 (owner: "add the
-- startpack card back to the shop card. it had it when i first uploaded it").
-- They went on it when there was nothing to put in them; there are two starter
-- packs now, and the kit's two bundle strips are the cards they were drawn for
-- -- a title, a three-tile Rewards row and a buy pill, which is exactly a pack.
local HIDE = {
	"Exclusive", "VIP", "ServerLuck", "LuckyBlocks",
	"Cash", "TextFrame1", "TextFrame3", "TextFrame4", "TextFrame5",
	-- The two that used to read VIP and POWER UPS.
	"TextFrame", "TextFrame2",
}

-- ConquestShop throttles EVERY message on the Shop channel to one per 1.5s per
-- player, silently. Matching it here is the difference between a second press
-- doing nothing visible and a second press being eaten by the server.
local COOLDOWN = 1.6

-- ------------------------------------------------------- opening and closing --
-- THE STORE TWEENS IN AND THE WORLD BLURS BEHIND IT (owner, 2026-09-16). Both
-- are the same idea: a shop that appears instantly reads as a screenshot pasted
-- over the map, and the map behind it keeps competing for the eye.
--
-- SCALE, NOT SIZE. `Frames.Store` is governed by a UIAspectRatioConstraint
-- (1.514, DominantAxis Width), so tweening Size would be a tug of war with the
-- constraint. A UIScale is a separate multiplier nothing else touches -- checked:
-- the panel ships without one -- so this file owns it outright.
--
-- AND THE FADE IS THE CANVASGROUP'S. `StoreFrame` is a CanvasGroup, so
-- GroupTransparency fades every card, label and button as ONE object; without it
-- this would mean walking a hundred children and putting each back afterwards.
local OPEN_TIME = 0.22
local CLOSE_TIME = 0.14
local OPEN_FROM = 0.86 -- the scale it grows from
-- Back-easing overshoots slightly on the way in, which is what makes a panel feel
-- like it ARRIVES rather than merely appearing. Out is plain Quad: a close should
-- get out of the way, not perform.
local OPEN_STYLE = Enum.EasingStyle.Back
local CLOSE_STYLE = Enum.EasingStyle.Quad

-- HOW HARD THE WORLD BLURS. 18 is enough to push the map out of focus while
-- leaving it legible as context -- a shop is not a scene change.
--
-- THE EFFECT IS BUILT AT RUNTIME, NEVER PARKED IN LIGHTING. There is no
-- BlurEffect anywhere in this place and no script references one (checked across
-- all 151), so this file owns the blur completely -- but a BlurEffect sitting in
-- Lighting in the tree would blur the game for everyone from the moment it
-- booted, whether or not anyone opened a shop.
-- Lifted with the scrim. It changes nothing on the current map (see SCRIM_ALPHA)
-- and costs nothing, but it keeps the two in step for any 3D content that is
-- ever added behind the interface.
local BLUR_MAX = 28
-- HOW DARK THE WORLD GOES BEHIND THE STORE, and why a blur was not enough on its
-- own (owner, 2026-09-16: "when i open up shop it doesnt open up the backgroun").
--
-- THE MAP IS NOT 3D. Conquest's Renderer paints tiles into EditableImages on
-- ImageLabels -- there is no Part, no SurfaceGui and no Workspace reference in
-- the whole module -- so the map is a 2D GUI layer. A BlurEffect is a POST
-- PROCESS on the 3D scene: it was running correctly the whole time and blurring
-- an empty world behind the interface. Roblox has no GUI blur.
--
-- So the background is DIMMED instead, with a full-screen scrim inside the
-- store's own ScreenGui. At DisplayOrder 4 that sits over the map and the HUD
-- (both 0), the Starter Pack sticker (2) and its panel (3), and the panel draws
-- above it on ZIndex. THE TAB DOES TOO -- ZIndex 10, see the order table above.
-- RAISED 0.45 -> 0.68 (owner, 2026-09-16: "i want it blurred more also, the
-- background when i open it up the shop"). Worth being precise about what this
-- number does: the map is a GUI layer, so the BlurEffect below contributes
-- nothing visible and this scrim is the whole of the effect. "More blur" on this
-- game means a darker scrim.
--
-- 0.68 still leaves the map legible underneath -- a shop is a panel over the
-- game, not a scene change -- but it is now unmistakably backgrounded.
local SCRIM_ALPHA = 0.68

-- ------------------------------------------------------------- card motion --
-- THE ICONS MOVE (owner: "give all the images animations in the shop"). Four
-- still stickers read as a screenshot; four that float read as stock you could
-- pick up. NO TWO MOVE TOGETHER -- ART_PHASE is seconds of offset times the
-- card's index, because stickers rising in lockstep read as one object.
local ART_BOB = 0.026 -- of the icon's own height
local ART_BOB_HZ = 0.5
local ART_SWAY = 1.8 -- degrees
local ART_SWAY_HZ = 0.33
local ART_PHASE = 1.7
-- THE RAY BURST BEHIND EACH ICON TURNS (owner, 2026-09-16: "make the background
-- ray spin"). Degrees per second, and deliberately slow: the owner has already
-- called one of these animations "way too much", and this one sits behind
-- everything else on the card, so it is the last thing that should pull the eye.
--
-- NO TWO TURN ALIKE. The speed is nudged per card and the direction alternates,
-- because four identical bursts rotating in lockstep read as one spinning object
-- with four holes cut in it rather than as four separate offers.
local BURST_SPIN = 5
local ART_HOVER_GROW = 0.09
local ART_PUNCH_DENT = 0.13
-- EVERY BUTTON ANSWERS THE CURSOR (owner: "buttons should all have hover
-- effects") -- the buy buttons, the close button and the HUD tab.
local PILL_HOVER_GROW = 0.08
local CLOSE_HOVER_GROW = 0.1
local HOVER_RATE = 12 -- how fast a hover eases in, per second

-- ------------------------------------------------------------- the shop tab --
-- THE DOOR, ON THE LEFT EDGE. Worked out in the HUD's own reference frame (it
-- authors in pixels against 1280x720), so these fractions hold at every window
-- size: down the left edge the HUD puts LOBBY at y 662..706 and REVIVE at
-- 608..652, the standings board and clock are both on the RIGHT, and the command
-- bar is centred from x 360. TOP_BAND is 72. So y 72..608 is clear from x 14, and
-- the tab is centred in THAT band: (72 + 608) / 2 = 340.
local TAB_X = 14 / 1280
local TAB_Y = 340 / 720
local TAB_SIZE = 88 / 720
local TAB_RATIO = 1
-- SUBTLE, DELIBERATELY (owner: "the shop HUD animation is way too much. i want
-- that one to be more subtle"). The first pass breathed 4.5% and swung 3.5
-- degrees at a beat a second, which on a quiet corner reads as a wobble
-- demanding attention. A third of that, at half the rate: it drifts.
local TAB_BREATHE = 0.016
local TAB_BREATHE_HZ = 0.55
local TAB_SWING = 1.1
local TAB_SWING_HZ = 0.3
local TAB_HOVER_GROW = 0.07
local TAB_PUNCH_DENT = 0.1
-- Open, the tab holds still: it has stopped being an invitation and become a
-- close button.
local TAB_OPEN_CALM = 0.25

-- ================================================================== build ==

local images = StarterGui:FindFirstChild("Images")

local storeArt = StarterGui:FindFirstChild("Store")
if storeArt == nil or not storeArt:IsA("ScreenGui") then
	warn("[TutorialShop] StarterGui.Store is missing; no deals offered.")
	return
end

local shop = storeArt:Clone() :: ScreenGui
shop.Name = "ConquestStore"
shop.Enabled = false
shop.ResetOnSpawn = false
shop.IgnoreGuiInset = true
-- THE KIT SHIPS DisplayOrder = -10, which draws the whole store BEHIND the HUD
-- (everything the HUD builds sits at 0).
--
-- THE WHOLE ORDER, because every one of these numbers is a tie somebody has
-- already lost an evening to:
--
--   0   the HUD and the map          20  the match intro's curtain
--   2   the Starter Pack sticker      5  the lobby page
--   3   the Starter Pack panel        4  THIS: the tab and the store
--
-- RAISED 2 -> 4 (owner, 2026-09-17: "tab itself got blurred too, dont want
-- that"). THE TAB IS NOT BACKGROUND. It lives in this ScreenGui at ZIndex 10,
-- above the store's own scrim, so opening the STORE has never dimmed it -- but
-- the Starter Pack panel's scrim is a whole DisplayOrder higher (3), and a
-- ScreenGui cannot be dimmed in part, so it took the tab with the map. At 4 the
-- tab keeps the one job it has in every round: it is the control that is always
-- available, and a dimmed control reads as a disabled one.
--
-- IT ALSO FIXES THE PRESS THAT FOLLOWS, which was already wrong before the
-- scrim existed: at 2 the tab opened this store UNDERNEATH the pack panel at 3.
-- Now whichever page was opened last is the one on top, and its scrim dims the
-- other -- so the two shops layer like windows instead of fighting.
shop.DisplayOrder = 4

-- `Frames` is the full-screen layer; `Frames.Store` is the window inside it.
-- Toggling the LAYER rather than the window means any backdrop or dimmer the kit
-- adds later goes with it.
local frames = shop:FindFirstChild("Frames")
local panel = frames and frames:FindFirstChild("Store")
local canvas = panel and panel:FindFirstChild("StoreFrame")
local container = canvas and canvas:FindFirstChild("Container")
if frames == nil or panel == nil or container == nil then
	warn("[TutorialShop] StarterGui.Store is not the expected shape; no deals offered.")
	shop:Destroy()
	return
end

-- THE KIT SHIPS `Frames` VISIBLE, and nothing here used to turn it off (fixed
-- 2026-09-16). The only write that hides it is the close branch of `applyOpen`,
-- which runs behind a task.delay(CLOSE_TIME) and so cannot possibly have fired
-- before the first open/close cycle. So from the moment `refresh()` sets
-- Enabled = true and this ScreenGui is parented -- the last two lines of this
-- file -- the whole full-screen store layer was on screen, and the match
-- intro's curtain is not up that early to cover it. That is the shop that
-- flashed at the start of every round.
--
-- The TAB is what belongs on the HUD for the whole match; the panel behind it
-- is opened by a press and by nothing else, so it starts hidden.
frames.Visible = false

-- THE WINDOW ITSELF IS RAISED EXPLICITLY, AND ITS NEW SIBLING PUT DOWN. The kit
-- gained a second page on 2026-09-17 -- `Frames.Shop2`, the Starter Pack panel
-- that TutorialDealClient drives off its OWN clone of this ScreenGui -- and the
-- owner's template now ships with `Frames.Store` hidden and Shop2 showing. Read
-- off the template, a press here raised the layer around an invisible store
-- with an empty Starter Pack page sitting in the middle of it.
if panel:IsA("GuiObject") then
	panel.Visible = true
end
for _, page in frames:GetChildren() do
	if page ~= panel and page:IsA("GuiObject") then
		page.Visible = false
	end
end

-- Writes EVERY child called `name` that carries text. The old panel drew its
-- captions twice as drop-shadow pairs; this kit mostly does not, but writing all
-- matches costs nothing and cannot pick the wrong twin.
local function setAll(parent: Instance, name: string, text: string): number
	local n = 0
	for _, c in parent:GetChildren() do
		if c.Name == name and (c:IsA("TextLabel") or c:IsA("TextButton")) then
			c.Text = text
			n += 1
		end
	end
	return n
end

-- The first descendant of a name, whatever depth the kit buried it at.
local function deep(root: Instance, name: string): Instance?
	for _, d in root:GetDescendants() do
		if d.Name == name then
			return d
		end
	end
	return nil
end

-- FIT THE CARD, AT THE BOTTOM (owner, 2026-09-17: "its still too big. for some of
-- them they look like theyre at the top layer, i want their z index to be at the
-- bottom layer"). The kit draws the square cards' burst at 2 x 2 -- clipped to
-- the card, so only a few fat rays showed -- and the hero's at 1.8 x 3.92 hung
-- above the card INSIDE Decor.CanvasGroup, which composites the whole group at
-- ITS ZIndex, 1: level with the buy pill, and a tie is settled by child order.
-- So a SQUARE card's burst is lifted out to the card itself, centred, SQUARE_BURST
-- of the card's shorter side (the card clips it), at -99: one above the stud
-- texture at -100 and under everything else. NOT under the stud -- its image is
-- half transparent but its BACKGROUND is opaque, and a burst put at -200 vanished
-- outright (owner, 2026-09-17: "rays are gone altogether"). The spin loop keeps
-- its handle; only the parent moved.
--
-- THE HERO IS LEFT EXACTLY AS THE KIT DREW IT (owner, 2026-09-17: "the vip ray
-- should be where it was originally") -- 1.8 x 3.92 hung above the card inside
-- Decor.CanvasGroup. The caller skips this for the VIP slot.
--
-- SQUARE_BURST: 1.0 showed the whole burst and read as too small (owner: "the
-- nuke +1M army +1M gold card ... is too small ray"); the kit's own 2.0 showed
-- only its fat inner rays. 1.5 is between, and it is the only dial.
local SQUARE_BURST = 1.5
local function fitBurst(card: Instance, burst: Instance?): Instance?
	if burst == nil or not burst:IsA("GuiObject") then
		return burst
	end
	local b = burst :: GuiObject
	b.Parent = card
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Position = UDim2.fromScale(0.5, 0.5)
	b.Size = UDim2.fromScale(SQUARE_BURST, SQUARE_BURST)
	b.ZIndex = -99
	if b:FindFirstChildOfClass("UIAspectRatioConstraint") == nil then
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = 1
		ar.Parent = b
	end
	return b
end

-- THREE RAYS BEHIND THE THREE ITEMS OF A BUNDLE STRIP (owner, 2026-09-17: "I
-- need 3 rays behind each of the items being offered in each starter pack",
-- then "still see just 1 ... need 3 rays. one behind each of the cards"). The
-- strip's own single burst is put away and each Rewards tile gets a clone of
-- the square cards' burst, taken from the TEMPLATE so it arrives as the kit
-- drew it -- the same picture, the same SQUARE_BURST, under the tile's icon (0)
-- and words (3), clipped by the tile. Each turns at its own speed and
-- direction, for the no-two-alike reason above BURST_SPIN.
local function tileRays(card: Instance, own: Instance?): { { rays: GuiObject, spin: number } }
	local list: { { rays: GuiObject, spin: number } } = {}
	local box = card:FindFirstChild("Rewards")
	local src: Instance? = storeArt
	for _, step in { "Frames", "Store", "StoreFrame", "Container", "Gamepasses", "2xCash", "Decor", "Starbust" } do
		src = src and src:FindFirstChild(step)
	end
	if box == nil or src == nil or not src:IsA("ImageLabel") then
		return list
	end
	if own ~= nil and own:IsA("GuiObject") then
		own.Visible = false
	end
	for i = 1, 3 do
		local tile = box:FindFirstChild(tostring(i))
		if tile ~= nil and tile:IsA("GuiObject") then
			local rays = (src :: ImageLabel):Clone()
			rays.Name = "Rays"
			rays.AnchorPoint = Vector2.new(0.5, 0.5)
			rays.Position = UDim2.fromScale(0.5, 0.5)
			rays.Size = UDim2.fromScale(SQUARE_BURST, SQUARE_BURST)
			rays.ZIndex = -1
			rays.Rotation = i * 37
			rays.Parent = tile
			tile.ClipsDescendants = true
			table.insert(list, {
				rays = rays,
				spin = BURST_SPIN * (1 + 0.22 * (i % 3)) * (if i % 2 == 0 then 1 else -1),
			})
		end
	end
	return list
end

for _, name in HIDE do
	for _, c in container:GetChildren() do
		if c.Name == name and c:IsA("GuiObject") then
			c.Visible = false
		end
	end
end
-- CLOSING THE GAP THE HIDDEN STOCK LEFT BEHIND, and the arithmetic matters here
-- because the obvious fix does not work.
--
-- Measured with the eleven dead slots hidden: the window is 283 px and the list
-- measures 369 -- an 86 px overflow that pushed the power-up row's descriptions
-- and its BUY BUTTONS below the fold (owner's screenshot, 2026-09-15).
--
-- MAKING THE PANEL TALLER FIXES NOTHING. Every slot is sized as a FRACTION of
-- this scrolling frame (the hero 0.410, the power-up row 0.536, the padding
-- 0.06), so a bigger window grows the children by the same factor and the
-- content-to-window ratio stays pinned at 1.304 forever.
--
-- The four cards alone sum to 283 -- exactly the window. THE WHOLE OVERFLOW IS
-- PADDING: five gaps between six children, and two of those children are the
-- kit's own zero-height SPACE spacers, each still costing a full gap. Dropping
-- the spacers and tightening the gap puts the buy buttons back on screen at
-- y ~273 of 283, and resizes no card -- which matters, because resizing the
-- owner's cards is the mistake this file has already made twice.
for _, c in container:GetChildren() do
	if c.Name == "SPACE" and c:IsA("GuiObject") then
		c.Visible = false
	end
end
-- THE LIST GAP GOES TO ZERO, and this number was measured on a LIVE CLONE rather
-- than reasoned about. It has to be: an edit-mode simulation of this same sweep
-- reported byte-identical content for every padding from 0.02 to 0.00 -- which
-- padding cannot do -- and then failed to restore what it had changed. On this
-- bridge, edit-mode writes are rolled back or reordered under the reads, so
-- layout numbers taken that way are worthless. In a playtest the clone is ours
-- and nothing rewinds it.
--
-- THE READING (window 283 px, three 17 px gaps between four slots):
--     pad 0.060  content 335   buy button bottom 428 vs 387   -41  CLIPPED
--     pad 0.030  content 310                       403        -16  CLIPPED
--     pad 0.020  content 301                       394         -8  CLIPPED
--     pad 0.010  content 293                       386         +1  visible, no margin
--     pad 0.000  content 284                       377         +9  VISIBLE
-- Monotonic, which is what a trustworthy measurement looks like. 0.010 clears by
-- a single pixel and would fail on any rounding; 0 clears by nine.
--
-- AND IT RESIZES NOTHING -- the squares measure 151x151 at every row above. That
-- is the point: the two earlier attempts at this panel both went wrong by
-- resizing the owner's cards, and the fix was never in the cards. It was in the
-- three dead gaps left behind when the unsold stock was hidden.
--
-- THE ZERO IS RETIRED (owner, 2026-09-17: "add a bit more space in between
-- these cards" ... "they still all border eachother"). The reading above was
-- taken with FOUR cards, to keep the buy buttons inside one window without
-- scrolling. The store now carries SIX -- the two bundle strips came back the
-- same day -- and scrolls whatever the gap is (canvas 468 in a 345 window,
-- live), so the only thing a zero gap still bought was cards touching.
-- CARD_GAP is the kit's own 0.06 of the container's height, ~21 px at the
-- owner's window; scale, not offset, so it keeps its proportion. This is the
-- ONE write to this padding -- an earlier one higher up the file ran first
-- and was silently undone here, which is how "still" happened. THE PIXEL FIT
-- at the bottom of this section re-expresses this same number in offsets
-- (CARD_GAP x the window) on every resize; this line stays the one place the
-- size of the gap is chosen.
local CARD_GAP = 0.06
local listLayout = container:FindFirstChildOfClass("UIListLayout")
if listLayout ~= nil then
	listLayout.Padding = UDim.new(CARD_GAP, 0)
end

-- ...AND AIR UNDER THE SCROLL WINDOW (owner, 2026-09-17: "add a bit more gap
-- always between the sliding window and the bottom of the tab. you see how its
-- literally touching the bottom of the tab"). The kit hangs StoreFrame off the
-- panel's bottom edge -- anchor (0.5, 1) at y 1, 0.847 tall -- so the scroll
-- window's last pixel row IS the panel's border. It is lifted by VIEW_GAP of the
-- panel and shortened by the same, so its top edge stays where the header left
-- it; and the canvas gets CARD_GAP of bottom padding so the last card, scrolled
-- to the end, keeps the air the cards have between them. A do-block for the
-- registers, as above.
do
	local VIEW_GAP = 0.03
	if canvas ~= nil and canvas:IsA("GuiObject") then
		local cs, cp = canvas.Size, canvas.Position
		canvas.Position = UDim2.new(cp.X.Scale, cp.X.Offset, cp.Y.Scale - VIEW_GAP, cp.Y.Offset)
		canvas.Size = UDim2.new(cs.X.Scale, cs.X.Offset, cs.Y.Scale - VIEW_GAP, cs.Y.Offset)
	end
	local pad = container:FindFirstChildOfClass("UIPadding")
	if pad == nil then
		local fresh = Instance.new("UIPadding")
		fresh.Parent = container
		pad = fresh
	end
	local up = pad :: UIPadding
	up.PaddingBottom = UDim.new(CARD_GAP, 0)
end

-- THE FOLD SHOWS THE NEXT CARD (owner, 2026-09-17: "shrink the height of vip
-- and the 3 cards below it slightly so i can see the top of the starter pack.
-- this way users know its scrollable"). The hero at 0.41 and the power-up row
-- at 0.536 plus one gap summed to 1.006 of the window -- a first screen that
-- ended exactly at its own edge, which reads as the whole store. At HERO_H and
-- ROW_H the two plus two gaps sum to 0.92, so the next strip's top 8% shows
-- under the fold.
--
-- HEIGHT ONLY -- the widths stay (owner: "dont shrink the width too"). The
-- kit's cards carry no aspect constraint, so a shorter card at the same width
-- would squash everything drawn inside it by scale. So the PARTS are pinned
-- to the shapes the kit drew them at, and the outlines are left to flatten:
-- on the 420 x 100 hero the elephant boxes are 124 x 123 and 173 x 171, the
-- pill's frame 27 x 27, the burst 756 x 392; on a 124 x 122 square the icon
-- is 54 x 53 and the pill's frame 26 x 26. FitWithinMaxSize keeps Size as a
-- ceiling on both axes, so the shrunken height is the one that binds.
do
	local HERO_H, ROW_H = 0.35, 0.45
	local function pin(root: Instance, parts: { { any } })
		for _, p in parts do
			local inst = deep(root, p[1])
			if inst ~= nil and inst:IsA("GuiObject") and inst:FindFirstChildOfClass("UIAspectRatioConstraint") == nil then
				local ar = Instance.new("UIAspectRatioConstraint")
				ar.AspectRatio = p[2]
				ar.Parent = inst
			end
		end
	end
	local heroCard = container:FindFirstChild("Brainrot1")
	if heroCard ~= nil and heroCard:IsA("GuiObject") then
		heroCard.Size = UDim2.new(heroCard.Size.X.Scale, 0, HERO_H, 0)
		pin(heroCard, { { "Icon", 1 }, { "Icon2", 1 }, { "BuyButtons", 1 }, { "Starbust", 1.93 } })
	end
	local squaresRow = container:FindFirstChild("Gamepasses")
	if squaresRow ~= nil and squaresRow:IsA("GuiObject") then
		squaresRow.Size = UDim2.new(squaresRow.Size.X.Scale, 0, ROW_H, 0)
		for _, sq in squaresRow:GetChildren() do
			if sq:IsA("GuiObject") then
				pin(sq, { { "Icon", 1 }, { "BuyButtons", 1 } })
			end
		end
	end
end

-- THE CANVAS IS MEASURED IN PIXELS, and it has to be: AutomaticCanvasSize
-- CANNOT MEASURE A PAGE OF SCALE-SIZED CARDS. The store was 65 px short of its
-- own last card (owner, 2026-09-17: "in the store, i cant scroll all the way
-- down") -- the PRO PACK's buy pill sat under a scroll that would not go
-- further. Measured live with the store open, window 387 px:
--     rows in SCALE     canvas 655   content needs 720   65 px UNREACHABLE
--     same rows in PX   canvas 717   content needs 717    0
-- The cards are the same size in both rows (136 / 174 / 159 / 159); only the
-- units changed. Fed a scale child, the engine's canvas pass and its layout
-- pass disagree about what that scale is measured against, and the canvas is
-- the one that loses. Fed pixels, AutomaticCanvasSize is exact -- which is why
-- it stays on rather than being replaced by arithmetic here: it keeps
-- measuring when a card comes or goes, and STARTER_PACK does exactly that
-- (tutorial-only, `refresh` below).
--
-- RESIZING NOTHING. `rows` remembers each child's ORIGINAL scale, because after
-- the first pass Size.Y.Scale is 0 and the number is gone; every pass rewrites
-- the height as that same fraction of the CURRENT window, so a card is the
-- exact fraction it has always been at every window size. The window changes
-- on every frame of the open tween -- that tween is a UIScale on the panel --
-- so this is driven by AbsoluteSize, not run once.
do
	local pad = container:FindFirstChildOfClass("UIPadding")
	local rows: { [Instance]: { number } } = {}
	local function fit()
		local win = container.AbsoluteSize.Y
		if win <= 0 then
			return
		end
		for _, ch in container:GetChildren() do
			if ch:IsA("GuiObject") then
				local row = rows[ch]
				if row == nil then
					row = { ch.Size.Y.Scale, ch.Size.Y.Offset }
					rows[ch] = row
				end
				local x = ch.Size.X
				ch.Size = UDim2.new(x.Scale, x.Offset, 0, row[1] * win + row[2])
			end
		end
		if listLayout ~= nil then
			listLayout.Padding = UDim.new(0, CARD_GAP * win)
		end
		if pad ~= nil then
			pad.PaddingBottom = UDim.new(0, CARD_GAP * win)
		end
	end
	fit()
	container:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
end

-- NOTE FOR WHOEVER BRINGS A HEADER BACK. A ZIndex lift used to live here,
-- because the hero's art bleeds far outside its own frame -- the crown measured
-- y 105..247 against a card at 113..229, and with ZIndexBehavior.Sibling and
-- every slot left at ZIndex 1 the later sibling wins, so the hero painted over
-- any label directly beneath it. With both headers gone there is nothing left to
-- rescue, so the lift went with them; put it back if a caption ever returns.

-- The Gift button has no backend in this game; a control that does nothing is
-- worse than no control.
local header = panel:FindFirstChild("Header")
local headerButtons = header and header:FindFirstChild("Buttons")
local gift = headerButtons and headerButtons:FindFirstChild("Gift")
if gift ~= nil and gift:IsA("GuiObject") then
	gift.Visible = false
end

-- THE SIDE TABS GO TOO, and they are a lesson in where a hide list reaches. The
-- kit hangs two quick-jump buttons -- "Limiteds" and "Lucky Blocks" -- off
-- Frames.Store.QuickButtons, which is a SIBLING of StoreFrame and therefore
-- nowhere near Container. Hiding Container's children left both of them sitting
-- on the right edge of the window, advertising two sections that no longer
-- exist. Hide the whole frame rather than the two buttons: it holds nothing else.
local quick = panel:FindFirstChild("QuickButtons")
if quick ~= nil and quick:IsA("GuiObject") then
	quick.Visible = false
end

local live: { any } = {}

type Slot = {
	path: { string },
	key: string,
	kind: string,
	label: string,
	icon: string,
	desc: ({ string } | string)?,
	rewards: { { icon: string, name: string, amount: string } }?,
}

-- THE PRICE IS ONE BOX (owner, 2026-09-17: "put the robux and the number in 1
-- text box"). The kit draws the hexagon and the number as SIBLINGS in `Info`'s
-- list layout, and each is sized off Info rather than off the other -- so the
-- glyph came out 33 px tall next to a 27 px digit, separated by a gap that knows
-- about neither. Live, on the pack strips: glyph 33 x 32, digit box 30 x 27.
--
-- So the glyph becomes a CHILD OF THE PRICE LABEL: as tall as the label's own
-- rendered height, parked in a strip of left padding exactly its own width, so
-- one box holds both and centres them as one thing at "9", at "40" and at "199".
--
-- IT SITS AT A NEGATIVE X, and that is the whole trick: UIPadding insets a
-- frame's CHILDREN as well as its text, so a glyph at x 0 lands on the first
-- digit. -strip puts it back at the outer edge, inside the strip the padding
-- just opened for it.
--
-- PIXELS, MEASURED, for the same reason the canvas is (see the note above):
-- both numbers come off the label's rendered height and are re-read whenever it
-- changes, which is what keeps the hexagon exactly as tall as the digits beside
-- it on every screen. OWNED closes the strip with the glyph -- a Robux hexagon
-- means nothing beside that word, and `repaint` below is what hides it.
local ROBUX_GLYPH = "rbxassetid://115923778456233"
local GLYPH_H, GLYPH_GAP = 0.86, 0.18

local function fusePrice(buyBox: Instance)
	for _, glyph in buyBox:GetDescendants() do
		if glyph:IsA("ImageLabel") and glyph.Image == ROBUX_GLYPH then
			local holder = glyph.Parent
			local price = holder ~= nil and holder:FindFirstChild("Price") or nil
			if price ~= nil and price:IsA("TextLabel") then
				local pad = price:FindFirstChildOfClass("UIPadding")
				if pad == nil then
					local fresh = Instance.new("UIPadding")
					fresh.Parent = price
					pad = fresh
				end
				local up = pad :: UIPadding
				glyph.Parent = price
				glyph.AnchorPoint = Vector2.new(0, 0.5)
				glyph.ZIndex = price.ZIndex
				local function room()
					local h = price.AbsoluteSize.Y
					if h <= 0 then
						return
					end
					local g = h * GLYPH_H
					local strip = g + h * GLYPH_GAP
					glyph.Size = UDim2.fromOffset(g, g)
					glyph.Position = UDim2.new(0, -strip, 0.5, 0)
					up.PaddingLeft = UDim.new(0, if glyph.Visible then strip else 0)
				end
				room()
				price:GetPropertyChangedSignal("AbsoluteSize"):Connect(room)
				glyph:GetPropertyChangedSignal("Visible"):Connect(room)
			end
		end
	end
end

local function wire(slot: Slot)
	local card: Instance? = container
	for _, step in slot.path do
		card = card and card:FindFirstChild(step)
	end
	if card == nil or not card:IsA("GuiObject") then
		warn(("[TutorialShop] no slot at %s; skipped."):format(table.concat(slot.path, ".")))
		return
	end

	local entry = if slot.kind == "pass" then Products.pass(slot.key) else Products.product(slot.key)
	-- AN UNCONFIGURED PRODUCT NEVER APPEARS IN A SHOP -- Products' header rule.
	if not Products.isLive(entry) then
		card.Visible = false
		return
	end
	local product = entry :: any
	card.Visible = true

	setAll(card, "Name", slot.label)

	-- A PACK CARD'S THREE TILES. The kit ships them as children "1".."3" of a
	-- `Rewards` frame, ordered by their own list layout, so the Nth row here is
	-- the Nth tile on screen.
	--
	-- setAll BEING DIRECT-CHILDREN-ONLY IS WHAT MAKES THIS SAFE, and it is the
	-- one thing to know before touching this block: every tile carries its own
	-- `Name` label, so a deep write would have stamped the card's title across
	-- all three of them.
	--
	-- NOTHING IS MOVED OR RESIZED -- this file's oldest rule, learned twice. The
	-- tiles are already three across the middle of the strip, drawn for exactly
	-- this; only the picture and the two words inside each one change.
	if slot.rewards ~= nil then
		local box = card:FindFirstChild("Rewards")
		for i, r in (if box ~= nil then slot.rewards else {}) do
			local tile = (box :: Instance):FindFirstChild(tostring(i))
			if tile ~= nil then
				setAll(tile, "Name", r.name)
				setAll(tile, "Amount", r.amount)
				local ti = tile:FindFirstChild("Icon")
				if ti ~= nil and ti:IsA("ImageLabel") then
					ti.Image = r.icon
					-- Fit, never Stretch: every sticker carries a baked dark
					-- outline, and a non-square box stretches that outline until
					-- it stops reading as one.
					ti.ScaleType = Enum.ScaleType.Fit
					Icons.resample(ti)
				end
				-- THE KIT PATTERNS ONE LABEL OUT OF THREE. It hangs a UIGradient
				-- off the third tile's Amount -- the "$1M/s" flourish -- so three
				-- identical rows came out with one of them coloured differently
				-- for no reason the player can see. A UIGradient MULTIPLIES the
				-- text colour, so it cannot be answered by setting TextColor3;
				-- the gradient itself has to go, the same way the sticker's own
				-- page drops it.
				local amt = tile:FindFirstChild("Amount")
				for _, g in (if amt ~= nil then (amt :: Instance):GetChildren() else {}) do
					if g:IsA("UIGradient") then
						g:Destroy()
					end
				end
			end
		end
	end

	-- THE COUNTDOWN IS A LIE, SO IT GOES. Both bundle strips ship a static
	-- "23h 59m left.." label. Nothing in this game expires, and a timer that
	-- never moves is worse than no timer: it is the one element on the card a
	-- player would come back and check.
	for _, c in card:GetChildren() do
		if c.Name == "Timer" and c:IsA("GuiObject") then
			c.Visible = false
		end
	end

	-- THE THREE SQUARES CARRY NO DESCRIPTION (owner, 2026-09-16: "remove the text
	-- in +1 nuke +1M army +1M gold"). `slot.desc` is nil for them, and the kit's
	-- `Des` label is hidden rather than blanked -- an empty TextLabel still holds
	-- its slot in the card and still draws its stroke.
	--
	-- THE HERO KEEPS ITS SUBTITLE: that line is where VIP's three benefits live,
	-- which the owner asked for, so only the `Des` form is dropped.
	if slot.desc ~= nil then
		-- THE HERO'S BENEFITS, STACKED DOWN THE RIGHT of the card. The kit's own
		-- subtitle slot (AmountLeft) is one left-aligned line and cannot hold three,
		-- so it is retired and the lines are built from CLONES OF IT -- that keeps
		-- the owner's face, stroke and gradient instead of an approximation.
		for _, c in card:GetChildren() do
			if c.Name == "AmountLeft" and c:IsA("GuiObject") then
				c.Visible = false
			end
		end
		local proto = nil
		for _, c in card:GetChildren() do
			if c.Name == "AmountLeft" and c:IsA("TextLabel") then
				proto = c
				break
			end
		end
		if proto ~= nil and typeof(slot.desc) == "table" then
			local lines = slot.desc :: { string }
			local n = #lines
			-- FILLS THE CLEAR BAND, so the stack cannot grow into the buy pill
			-- however many lines it is given: the band is fixed and the rows divide
			-- it, rather than each row being a fixed height that centres wherever
			-- it lands.
			local lineH = (VIP_TEXT_BOTTOM - VIP_TEXT_TOP) / n
			local top = VIP_TEXT_TOP
			for i, text in lines do
				local row = proto:Clone()
				-- NOT "AmountLeft": the loop above hides every child of that name,
				-- and a later repaint would take these with it.
				row.Name = "Benefit" .. tostring(i)
				row.Visible = true
				row.AnchorPoint = Vector2.new(0, 0)
				row.Position = UDim2.fromScale(VIP_TEXT_X, top + (i - 1) * lineH)
				row.Size = UDim2.fromScale(VIP_TEXT_W, lineH * 0.88)
				row.TextXAlignment = Enum.TextXAlignment.Left
				row.TextScaled = true
				row.ZIndex = 12
				-- WHITE, AND THE GRADIENT HAS TO GO WITH IT (owner, 2026-09-16).
				-- These rows are clones of the kit's AmountLeft, which carries an
				-- orange UIGradient (1,0.58,0 -> 1,0.15,0). A UIGradient MULTIPLIES
				-- the text colour, so setting TextColor3 white on its own leaves the
				-- line exactly as orange as it was -- the gradient wins. The stroke
				-- stays: it is the dark outline that keeps white legible on the pink
				-- card underneath.
				local rowGrad = row:FindFirstChildOfClass("UIGradient")
				if rowGrad ~= nil then
					rowGrad:Destroy()
				end
				row.TextColor3 = Color3.new(1, 1, 1)
				-- Dashed, every line (owner: "start it with a - every time").
				row.Text = "- " .. text
				row.Parent = card
			end
		end
	else
		for _, c in card:GetChildren() do
			if c.Name == "Des" and c:IsA("GuiObject") then
				c.Visible = false
			end
		end
		-- WITH THE WORDS GONE THE ICON IS OFF-CENTRE, because the kit parks it at
		-- x 0.253 to leave the right-hand two thirds for the description. Nothing
		-- is there now, so a sticker pinned to the left reads as a card missing
		-- half its contents. Centring is a position change and this file has been
		-- burned twice by moving the owner's art -- but the layout it was placed
		-- for no longer exists.
		local ic = card:FindFirstChild("Icon")
		if ic ~= nil and ic:IsA("GuiObject") then
			ic.Position = UDim2.new(0.5, 0, ic.Position.Y.Scale, ic.Position.Y.Offset)
		end
	end

	-- THE STICKER. Image only -- see the header on why nothing here is resized.
	local art = card:FindFirstChild("Icon")
	if art ~= nil and art:IsA("ImageLabel") then
		art.Image = slot.icon
		-- Fit, never Stretch: every sticker carries a baked dark outline, and a
		-- non-square box stretches that outline until it stops reading as one.
		art.ScaleType = Enum.ScaleType.Fit
		Icons.resample(art)
	else
		art = nil
	end
	-- The hero draws a SECOND, larger copy of its art behind the first as a glow.
	-- A crown behind a crown reads as a mistake, so the backing layer goes.
	-- SEARCHED DEEP, not among the direct children. An earlier probe reported
	-- `icon2vis=nil` -- meaning FindFirstChild came back empty -- while a later
	-- one found Icon2 alive and bleeding from y 80 to 278. Both are true: the kit
	-- buries it inside the hero's Decor/CanvasGroup, so a shallow lookup misses it
	-- and the layer was never actually hidden.
	local art2 = deep(card, "Icon2")
	if art2 ~= nil and art2:IsA("GuiObject") then
		art2.Visible = false
	end

	-- THE BUY BUTTON. `BuyButtons` holds the pill, its price and a Robux glyph;
	-- a player aiming at any of them means the same thing.
	local buyBox = card:FindFirstChild("BuyButtons")

	-- THE BADGE GOES AND THE BUY PILL TAKES ITS PLACE (owner, 2026-09-16: "remove
	-- best value text. move green button to where best value was").
	--
	-- MEASURED, NOT HARDCODED. The pill is placed at InfoFrame's own centre, read
	-- off the instance before it is hidden, so "where BEST VALUE was" stays true if
	-- that badge is ever moved in the template. The centre of a GuiObject is
	-- Position + Size * (0.5 - AnchorPoint), which is the only formula that works
	-- across the two different anchors involved here: the badge is anchored
	-- (0, 0.5) and the pill (0.5, 1).
	--
	-- THE WHOLE FRAME IS HIDDEN, not just its text. InfoFrame is the dark rounded
	-- plate the words sit on -- blanking the label alone would leave an empty
	-- badge behind.
	--
	-- NOT VIA deep(card, "Info"): this card carries TWO descendants called Info --
	-- the badge's TextLabel and a Frame inside BuyButtons -- and the old badge code
	-- only survived that by type-checking. InfoFrame is unambiguous.
	local badge = card:FindFirstChild("InfoFrame")
	if badge ~= nil and badge:IsA("GuiObject") then
		if buyBox ~= nil and buyBox:IsA("GuiObject") then
			local cx = badge.Position.X.Scale + badge.Size.X.Scale * (0.5 - badge.AnchorPoint.X)
			local cy = badge.Position.Y.Scale + badge.Size.Y.Scale * (0.5 - badge.AnchorPoint.Y)
			-- Centre anchor, so the pill sits ON that point rather than hanging
			-- below it the way its authored (0.5, 1) anchor would.
			buyBox.AnchorPoint = Vector2.new(0.5, 0.5)
			buyBox.Position = UDim2.fromScale(cx, cy)
		end
		badge.Visible = false
	end

	if buyBox ~= nil then
		-- The catalogue figure is drawn by state.repaint below, once the state
		-- table exists -- see the note over it for why nothing writes this label
		-- directly any more. The glyph moves into that label first, so the figure
		-- lands in a box that already has its strip of room.
		fusePrice(buyBox)
	end

	local state = {
		card = card,
		slot = slot,
		index = #live + 1,
		-- Found by depth rather than by path: the kit buries this one inside
		-- Decor on some cards and Decor/CanvasGroup on others.
		-- The VIP hero keeps the kit's own burst; the three square cards are
		-- fitted; a bundle strip (one with `rewards`) has NO single burst -- its
		-- three items carry one each, see `rays`.
		burst = if slot.kind == "pass" then deep(card, "Starbust") elseif slot.rewards ~= nil then nil else fitBurst(card, deep(card, "Starbust")),
		rays = if slot.rewards ~= nil then tileRays(card, deep(card, "Starbust")) else {},
		burstSpin = BURST_SPIN * (1 + 0.22 * (#live % 3)) * (if #live % 2 == 0 then 1 else -1),
		art = art,
		pill = buyBox,
		pillBase = (buyBox ~= nil and buyBox:IsA("GuiObject")) and buyBox.Size or nil,
		hover = 0,
		hovered = false,
		pillHover = 0,
		pillHovered = false,
		punch = 0,
		lastPress = -1e9,
		owned = false,
		sitePrice = nil,
	}

	-- THE ONLY WRITER OF THE PRICE LABEL. THREE things wanted to set it and they
	-- arrive in any order: the catalogue figure at build time, the OWNED state, and
	-- the site's regional price on its own thread. Left as three direct writes, the
	-- async one landed LAST on a VIP-owning account and replaced "OWNED" with a
	-- price -- an offer on a pass already held, whose button buy() then refuses.
	--
	-- Owned wins; otherwise the site's answer if it has arrived, else the
	-- catalogue. Every caller goes through here.
	function state.repaint()
		if buyBox == nil then
			return
		end
		local pr = deep(buyBox, "Price")
		if pr ~= nil and (pr:IsA("TextLabel") or pr:IsA("TextButton")) then
			pr.Text = if state.owned then "OWNED" else tostring(state.sitePrice or product.robux)
		end
		-- The Robux glyph means nothing beside the word OWNED.
		for _, d in buyBox:GetDescendants() do
			if d:IsA("ImageLabel") and d.Image == ROBUX_GLYPH then
				d.Visible = not state.owned
			end
		end
	end
	state.repaint()

	local function buy()
		if state.owned then
			return
		end
		local now = os.clock()
		if now - state.lastPress < COOLDOWN then
			return
		end
		state.lastPress = now
		state.punch = 1
		Sfx.play("Click")
		-- Nothing here reports success: the receipt's own effect is the feedback.
		-- The VERB is the header's trap -- a pass is not a product.
		ShopRE:FireServer(if slot.kind == "pass" then "pass" else "buy", slot.key)
	end

	if buyBox ~= nil then
		for _, b in buyBox:GetDescendants() do
			if b:IsA("GuiButton") then
				b.Active = true
				b.Selectable = true
				b.Activated:Connect(buy)
				b.MouseEnter:Connect(function()
					if not state.pillHovered then
						state.pillHovered = true
						Sfx.play("Click", { volume = 0.15, pitch = 1.7 })
					end
				end)
				b.MouseLeave:Connect(function()
					state.pillHovered = false
				end)
			end
		end
	end

	-- Hovering anywhere on the card lifts its sticker: the cursor crosses the
	-- picture long before it finds the price.
	card.MouseEnter:Connect(function()
		state.hovered = true
	end)
	card.MouseLeave:Connect(function()
		state.hovered = false
	end)

	-- A PASS YOU ALREADY HOLD MUST NOT PROMPT. Roblox answers a second purchase of
	-- an owned pass with its own "you already own this" dialog, which is a dead
	-- end wearing the clothes of an offer. WATCHED rather than read once, because
	-- this card is how the pass gets bought.
	if slot.kind == "pass" then
		local function paint()
			local owned = player:GetAttribute(VIP_ATTR) == true
			state.owned = owned
			setAll(card, "Name", slot.label)
			-- THE GREEN PILL STAYS (owner: "give the vip a green button too"). It was
			-- being HIDDEN when the pass was owned, which is why this card looked
			-- like the only one without a button -- the art was never wrong: the
			-- hero's pill is the same image and the same green gradient as the three
			-- squares, just 93x31 against their 97x32.
			--
			-- Owned, it reads OWNED instead of a price and `buy` refuses the press,
			-- so the card still answers the cursor without selling a pass twice.
			state.repaint()
		end
		paint()
		player:GetAttributeChangedSignal(VIP_ATTR):Connect(paint)
	end

	-- THE PRICE IS ASKED OF THE SITE: managed pricing varies it by region, so
	-- `robux` is only what to draw until the answer lands. A PASS AND A PRODUCT
	-- ARE DIFFERENT QUESTIONS -- asking for a pass id as a Product throws.
	task.spawn(function()
		local infoType = if slot.kind == "pass" then Enum.InfoType.GamePass else Enum.InfoType.Product
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(product.id, infoType)
		end)
		if not ok or type(info) ~= "table" then
			return
		end
		local real = tonumber((info :: any).PriceInRobux)
		if real ~= nil and buyBox ~= nil and buyBox.Parent ~= nil then
			-- PARKED, NOT PAINTED: state.repaint decides what the label says.
			state.sitePrice = real
			state.repaint()
		end
	end)

	-- Captured after everything above, so the loop animates around wherever the
	-- kit left the icon rather than around a constant this file invented.
	if state.art ~= nil then
		state.artBase = state.art.Size
		state.artX = state.art.Position.X.Scale
		state.artY = state.art.Position.Y.Scale
	end

	table.insert(live, state)
end

for _, slot in SLOTS do
	wire(slot :: Slot)
end

if #live == 0 then
	warn("[TutorialShop] no product is configured; the store stays down.")
	shop:Destroy()
	return
end

-- ================================================================== the tab ==

local open = false
local tabState: any = nil

-- THE PANEL GROWS IN AND THE WORLD BLURS OUT. Both run off one token so a fast
-- tab-close-tab cannot leave a half-finished tween holding the panel hidden: every
-- call takes the next token, and any tween that finishes holding a stale one just
-- returns without touching anything.
local TweenService = game:GetService("TweenService")

local panelScale = panel:FindFirstChildOfClass("UIScale")
if panelScale == nil then
	panelScale = Instance.new("UIScale")
	panelScale.Parent = panel
end

-- THE SCRIM. Full-screen, inside Frames so it disappears with the rest of the
-- store, and ZIndex 0 so every part of the panel draws over it -- the kit leaves
-- its own frames at 1 and above.
local scrim = frames:FindFirstChild("ConquestScrim") :: Frame?
if scrim == nil then
	local s = Instance.new("Frame")
	s.Name = "ConquestScrim"
	s.BackgroundColor3 = Color3.new(0, 0, 0)
	s.BackgroundTransparency = 1
	s.BorderSizePixel = 0
	s.Size = UDim2.fromScale(1, 1)
	s.Position = UDim2.fromScale(0.5, 0.5)
	s.AnchorPoint = Vector2.new(0.5, 0.5)
	s.ZIndex = 0
	-- IT EATS THE CLICK, which is the other half of a modal: without this a press
	-- that misses the panel lands on the map underneath and orders an attack.
	s.Active = true
	s.Parent = frames
	scrim = s
end

local blur: BlurEffect? = nil
local openToken = 0

local function applyOpen()
	openToken += 1
	local token = openToken

	-- THE BLUR IS MADE ON FIRST OPEN and lives in Lighting only while the store
	-- does. Parented here rather than left in the tree so a player who never opens
	-- the store never pays for it.
	if blur == nil then
		blur = Instance.new("BlurEffect")
		local b = blur :: BlurEffect
		b.Name = "ConquestStoreBlur"
		b.Size = 0
		b.Parent = game:GetService("Lighting")
	end
	local b = blur :: BlurEffect

	if open then
		frames.Visible = true
		;(panelScale :: UIScale).Scale = OPEN_FROM
		if canvas ~= nil and canvas:IsA("CanvasGroup") then
			canvas.GroupTransparency = 1
		end
		TweenService:Create(panelScale, TweenInfo.new(OPEN_TIME, OPEN_STYLE, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
		if canvas ~= nil and canvas:IsA("CanvasGroup") then
			TweenService:Create(canvas, TweenInfo.new(OPEN_TIME * 0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				GroupTransparency = 0,
			}):Play()
		end
		TweenService:Create(b, TweenInfo.new(OPEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = BLUR_MAX,
		}):Play()
		if scrim ~= nil then
			TweenService:Create(scrim, TweenInfo.new(OPEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				BackgroundTransparency = 1 - SCRIM_ALPHA,
			}):Play()
		end
	else
		TweenService:Create(panelScale, TweenInfo.new(CLOSE_TIME, CLOSE_STYLE, Enum.EasingDirection.In), {
			Scale = OPEN_FROM,
		}):Play()
		if canvas ~= nil and canvas:IsA("CanvasGroup") then
			TweenService:Create(canvas, TweenInfo.new(CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				GroupTransparency = 1,
			}):Play()
		end
		local fade = TweenService:Create(b, TweenInfo.new(CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = 0,
		})
		fade:Play()
		if scrim ~= nil then
			TweenService:Create(scrim, TweenInfo.new(CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				BackgroundTransparency = 1,
			}):Play()
		end
		-- HIDE ONLY AFTER THE FADE, and only if this is still the newest request.
		task.delay(CLOSE_TIME, function()
			if token == openToken and not open then
				frames.Visible = false
			end
		end)
	end
end

-- A BLUR THAT OUTLIVES ITS SHOP IS A BUG THE PLAYER CANNOT FIX. If the ScreenGui
-- is ever destroyed -- a teleport, a rebuild -- the effect goes with it, rather
-- than leaving the map permanently out of focus.
shop.Destroying:Connect(function()
	if blur ~= nil then
		blur:Destroy()
		blur = nil
	end
end)

-- ONLY THE IMAGE IS TAKEN FROM THE ART, never the instance: the owner swapped
-- this icon from an ImageButton to an ImageLabel once already, and the old
-- `:IsA("ImageButton")` test failed SHUT -- no error, just no tab on screen.
local tabArt = images and images:FindFirstChild("shop icon")
local tabImage: string? = nil
if tabArt ~= nil and (tabArt:IsA("ImageLabel") or tabArt:IsA("ImageButton")) then
	tabImage = (tabArt :: any).Image
end

if tabImage ~= nil and tabImage ~= "" then
	local tab = Instance.new("ImageButton")
	tab.Image = tabImage
	tab.Name = "ShopTab"
	tab.AnchorPoint = Vector2.new(0, 0.5)
	tab.Position = UDim2.fromScale(TAB_X, TAB_Y)
	tab.Size = UDim2.fromScale(TAB_SIZE, TAB_SIZE)
	tab.BackgroundTransparency = 1
	tab.ScaleType = Enum.ScaleType.Fit
	-- NO AutoButtonColor: it darkens the sticker on press, a second animation
	-- arguing with the dent the loop already spends.
	tab.AutoButtonColor = false
	tab.ZIndex = 10
	local tabRatio = Instance.new("UIAspectRatioConstraint")
	tabRatio.AspectRatio = TAB_RATIO
	tabRatio.DominantAxis = Enum.DominantAxis.Height
	tabRatio.Parent = tab
	tab.Active = true
	tab.Selectable = true
	tab.Parent = shop

	-- IT SAYS SHOP (owner: "make the shop button in the hud say shop"), lettered
	-- by the store's OWN header label so the tab and the page it opens are
	-- written in the same hand. Parented to the button, so it inherits the drift,
	-- the hover and the press dent without its own entry in the loop.
	--
	-- BARELY WIDER THAN THE ICON: the tab sits 14 reference px from the left edge,
	-- and at 1.6 icon-widths the word hung off the screen -- measured at -17 px,
	-- with the S cut in half.
	local wordSrc = header and header:FindFirstChild("Name")
	if wordSrc ~= nil and wordSrc:IsA("TextLabel") then
		local word = wordSrc:Clone()
		word.Name = "TabWord"
		word.AnchorPoint = Vector2.new(0.5, 0)
		word.Position = UDim2.fromScale(0.5, 0.9)
		word.Size = UDim2.fromScale(1.05, 0.3)
		word.TextXAlignment = Enum.TextXAlignment.Center
		word.TextScaled = true
		word.Visible = true
		word.ZIndex = 11
		word.Text = "SHOP"
		word.Parent = tab
	end

	tabState = { tab = tab, hover = 0, hovered = false, punch = 0, calm = 0 }

	tab.MouseEnter:Connect(function()
		if not tabState.hovered then
			tabState.hovered = true
			Sfx.play("Click", { volume = 0.18, pitch = 1.6 })
		end
	end)
	tab.MouseLeave:Connect(function()
		tabState.hovered = false
	end)
	tab.Activated:Connect(function()
		open = not open
		tabState.punch = 1
		Sfx.play("Click")
		applyOpen()
	end)
else
	-- NO TAB MEANS THE STORE STAYS OPEN, never hidden behind a door that was not
	-- built. A missing icon is a deploy fact; a shop nobody can reach is a bug.
	warn("[TutorialShop] StarterGui.Images['shop icon'] is missing; the store stays open.")
	open = true
end

-- THE CLOSE BUTTON, the one players reach for first: a panel with an X on it
-- that does not shut is the most obvious thing that can be wrong with a store.
local closeState: any = nil
local closeBtn = headerButtons and headerButtons:FindFirstChild("Close")
if closeBtn ~= nil then
	for _, b in closeBtn:GetDescendants() do
		if b:IsA("GuiButton") then
			closeState = closeState or { btn = b, base = b.Size, hover = 0, hovered = false }
		end
	end
	if closeBtn:IsA("GuiButton") then
		closeState = closeState or { btn = closeBtn, base = closeBtn.Size, hover = 0, hovered = false }
	end
	local target = closeState and closeState.btn
	if target ~= nil then
		target.Active = true
		target.Selectable = true
		target.MouseEnter:Connect(function()
			if not closeState.hovered then
				closeState.hovered = true
				Sfx.play("Click", { volume = 0.15, pitch = 1.7 })
			end
		end)
		target.MouseLeave:Connect(function()
			closeState.hovered = false
		end)
		target.Activated:Connect(function()
			open = false
			if tabState ~= nil then
				tabState.punch = 1
			end
			Sfx.play("Click")
			applyOpen()
		end)
	end
end

applyOpen()

-- ================================================================ motion ===
--
-- ONE loop, and it returns immediately while the store is down -- most of the
-- game. Everything animated is written here and nowhere else, so no two writers
-- can disagree about a size.
local clock = 0
RunService.RenderStepped:Connect(function(dt)
	if not shop.Enabled then
		return
	end
	clock += dt

	-- THE TAB is on screen for the whole match whether or not the store is open.
	if tabState ~= nil then
		local t = tabState
		t.hover += ((t.hovered and 1 or 0) - t.hover) * math.min(1, dt * HOVER_RATE)
		t.punch = math.max(0, t.punch - dt * 4)
		t.calm += ((open and 1 or 0) - t.calm) * math.min(1, dt * 6)

		local idle = 1 - t.calm * (1 - TAB_OPEN_CALM)
		local breathe = math.sin(clock * TAB_BREATHE_HZ * math.pi * 2) * TAB_BREATHE * idle
		local s = TAB_SIZE * (1 + breathe + TAB_HOVER_GROW * t.hover - TAB_PUNCH_DENT * t.punch)
		t.tab.Size = UDim2.fromScale(s, s)
		t.tab.Rotation = math.sin(clock * TAB_SWING_HZ * math.pi * 2) * TAB_SWING * idle * (1 - 0.7 * t.hover)
	end

	if closeState ~= nil then
		closeState.hover += ((closeState.hovered and 1 or 0) - closeState.hover) * math.min(1, dt * HOVER_RATE)
		local cb = closeState.base
		local ck = 1 + CLOSE_HOVER_GROW * closeState.hover
		closeState.btn.Size = UDim2.fromScale(cb.X.Scale * ck, cb.Y.Scale * ck)
	end

	-- ...and the cards, ONLY while the store is open. Four bobbing stickers and
	-- four easing buttons are the most expensive thing this file does, and with
	-- the store shut every one of them is invisible anyway.
	if not frames.Visible then
		return
	end

	for _, d in live do
		d.hover += ((d.hovered and 1 or 0) - d.hover) * math.min(1, dt * HOVER_RATE)
		d.pillHover += ((d.pillHovered and 1 or 0) - d.pillHover) * math.min(1, dt * HOVER_RATE)
		d.punch = math.max(0, d.punch - dt * 4)

		-- The ray burst, turning behind everything else on the card. Written here
		-- with the rest so no second writer can disagree about its Rotation.
		local burst = d.burst
		if burst ~= nil and burst:IsA("GuiObject") then
			burst.Rotation = (burst.Rotation + dt * d.burstSpin) % 360
		end
		-- A bundle strip's three rays, one per item, each on its own turn.
		for _, r in d.rays do
			r.rays.Rotation = (r.rays.Rotation + dt * r.spin) % 360
		end

		local art = d.art
		if art ~= nil and d.artBase ~= nil then
			local phase = d.index * ART_PHASE
			local k = 1 + ART_HOVER_GROW * d.hover - ART_PUNCH_DENT * d.punch
			art.Size = UDim2.fromScale(d.artBase.X.Scale * k, d.artBase.Y.Scale * k)
			local bob = math.sin(clock * ART_BOB_HZ * math.pi * 2 + phase) * (ART_BOB + 0.01 * d.hover)
			art.Position = UDim2.fromScale(d.artX, d.artY + bob)
			art.Rotation = math.sin(clock * ART_SWAY_HZ * math.pi * 2 + phase) * ART_SWAY * (1 - 0.6 * d.hover)
		end

		local pill, pb = d.pill, d.pillBase
		if pill ~= nil and pb ~= nil then
			local pk = 1 + PILL_HOVER_GROW * d.pillHover
			pill.Size = UDim2.fromScale(pb.X.Scale * pk, pb.Y.Scale * pk)
		end
	end
end)

-- ============================================================ when it shows ==

local lessonLive = false
local phase = ""

-- THE TAB IS ON THE HUD FOR THE WHOLE MATCH. It was gated on a running lesson
-- once, which meant that in an ordinary round -- nearly every round -- the
-- ScreenGui was disabled, so there was no shop button anywhere and nothing said
-- why (owner: "still dont see shop button in the HUD").
local function refresh()
	shop.Enabled = true
	-- Every card stays on the page in every round (owner: "i told you what i
	-- wanted in each of the 4 slots") -- EXCEPT STARTER PACK #1 (owner,
	-- 2026-09-17 evening: "dont display the starter pack in a real game. only
	-- display it in the tutorial"), which is gated exactly as its sticker is:
	-- a live lesson AND the "playing" phase, because redeemBoost refuses
	-- outside "playing" and a token banked in the spawn phase is stranded.
	-- Whether any other press is honoured right now is redeemBoost's business.
	for _, d in live do
		local vis = d.slot.key ~= "STARTER_PACK" or (lessonLive and phase == "playing")
		if d.card.Visible ~= vis then
			d.card.Visible = vis
		end
	end
end

local function lessonFrom(state: any?): boolean
	-- A lite card -- a follower's three cards inside a real match -- is not
	-- a lesson round, so it opens none of the tutorial's deals.
	return type(state) == "table" and state.lite ~= true and not state.finished and not state.failed
end

StateRE.OnClientEvent:Connect(function(kind, payload)
	local p: any = payload
	if kind == "init" then
		phase = (type(p) == "table" and tostring(p.phase)) or ""
		lessonLive = lessonFrom(type(p) == "table" and p.tutorial or nil)
	elseif kind == "tutorial" then
		lessonLive = lessonFrom(p)
	elseif kind == "phase" then
		if type(p) == "table" then
			if p.phase ~= nil then
				phase = tostring(p.phase)
			end
			-- THE DURABLE HALF: `init` is routinely missed by a listener that
			-- finishes its setup after it, and "tutorial" only arrives when a
			-- card or a ring moves. This broadcast repeats every STATS_INTERVAL,
			-- so the lesson flag converges here. A BOOLEAN; `init` carries the
			-- lesson TABLE, which is why the two are read in separate branches.
			if p.tutorial ~= nil then
				lessonLive = p.tutorial == true
			end
		end
	elseif kind == "win" then
		phase = "ended"
	else
		return
	end
	refresh()
end)

refresh()
shop.Parent = playerGui
