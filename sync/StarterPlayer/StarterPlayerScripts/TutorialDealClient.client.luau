--!strict
-- Conquest :: TutorialDealClient  (client)
--
-- ONE CARD ON THE RIGHT EDGE OF THE HUD: Starter Pack #1, sold off the owner's
-- own sticker art at StarterGui.Images.HudShopTutorial (owner, 2026-09-17:
-- "im talking about HUD shop tutorial").
--
-- WHY THIS IS A NEW FILE AND NOT AN EDIT TO TutorialShopClient. That file drives
-- a DIFFERENT drawing -- StarterGui.Store, a full centre-screen panel behind a
-- left-edge tab -- and this art is a sticker stack pinned to the right edge.
-- They are two shops, not two versions of one, and the owner has asked for this
-- one INSTEAD of that one. Keeping them in separate files is what makes that
-- reversible: TutorialShopClient is switched off at its `Disabled` property, not
-- deleted, so putting the panel back is one checkbox.
--
-- THE ART HAD NEVER BEEN ON SCREEN. Nothing in the place referenced
-- HudShopTutorial except a comment recording that it was once the wrong choice,
-- so it was authored, left Enabled, and never cloned into anybody's PlayerGui.
-- That -- not a gate, not a purchase state, not the tutorial -- is why the owner
-- could not find it.
--
-- IT IS ITS OWN SCRIPT RATHER THAN A HUD PANEL, for the reasons the other shop
-- gives and which have not changed: ConquestClient sits at Luau's 200-local
-- ceiling, and the HUD is one class every readout already shares. A RemoteEvent
-- fans out to EVERY listener on the client, so this file reads the same "State"
-- channel ConquestClient reads without either knowing about the other.
--
-- THE ART IS CLONED OUT OF StarterGui, NOT PlayerGui. `Players.CharacterAutoLoads`
-- is FALSE in this place: nobody ever spawns, so StarterGui is never copied into
-- a PlayerGui and the folder there does not exist at all. StarterGui itself
-- replicates, so the template is readable from here either way.
--
-- THIS STICKER IS TUTORIAL-ONLY (owner, 2026-09-17), and it still is: see
-- `gui.Enabled = lessonLive and phase == "playing"` at the foot of this file.
--
-- THE PACK IS NOT, ANY MORE. Later the same day the owner asked for the kit's
-- Starter Pack card back in the main store ("add the startpack card back to the
-- shop card. it had it when i first uploaded it"), and THAT store's tab sits on
-- the HUD in every round -- so both packs are now buyable, and redeemable, in a
-- live PvP match. This note used to warn that a second buy button elsewhere
-- would reopen the decision; it has been reopened, deliberately, by the owner.
--
-- WHAT WAS DECIDED, STATED PLAINLY. MONETIZATION.txt section 0 holds that troops
-- and gold are two of the four things a zero-sum territory game must never sell,
-- because each is taken straight out of another player's round. The tutorial --
-- bots for a roster, a protected student, nobody else's round touched -- was the
-- one place that argument did not apply, and the packs are sold outside it now.
-- The SERVER gate on boosts went the same way on 2026-09-16; see the long note
-- over ConquestServer.redeemBoost, which records the same trade.
--
-- THE PROMPT GOES THROUGH THE SERVER (ShopRE "buy"), never MarketplaceService
-- from here. ConquestShop hands the key to Monetization.promptProduct, which
-- keeps the `isLive` gate and the pcall around the prompt in ONE place. The verb
-- is `buy` and not `pass` because Starter Pack #1 is a DEVELOPER PRODUCT -- its
-- GamePass InfoType fails, which is the check that proves it.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Matchmaker = require(Shared.Matchmaker)
local Net = require(Shared.Net)
local Products = require(Shared.Products)
local Sfx = require(Shared.Sfx)

-- A lobby server runs no round and so sells nothing here. YIELDING rather than
-- returning is deliberate and is what ConquestClient does: a Studio lobby FLIPS
-- to "match" when its own countdown fires, and a file that returned early would
-- stay gone for the round that follows.
Matchmaker.awaitRole("match")

local netFolder = Net.await(ReplicatedStorage)
local StateRE = netFolder:WaitForChild("State") :: RemoteEvent
local ShopRE = netFolder:WaitForChild("Shop") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local PRODUCT_KEY = "STARTER_PACK"

-- WHERE THE STACK SITS, AND IT IS NOT WHERE THE ART PUTS IT. The template parks
-- the frame at y 0.446, which runs straight through the standings board. The
-- HUD's right edge has exactly ONE free band, measured in a live round: the
-- board holds the top down to 0.325 and the clock takes 0.897 downward, so
-- 0.325..0.897 is all there is. The card is centred in it.
--
-- FRACTIONS, NOT PIXEL ROWS: the HUD places its own panels by scale off a
-- reference frame, so the board and the clock keep these fractions at any
-- window size.
local STACK_Y = 0.611

-- THE CARD IS PINNED SQUARE, and this is a correctness fix rather than a taste
-- one. The art scales width off the viewport's WIDTH and height off its HEIGHT,
-- so without a constraint one card measures 84x75 on a wide window and 137x145
-- at 16:9 -- a different SHAPE per player. The icon, the burst and both captions
-- are all scaled off the card, so they inherit the fix.
local CARD_ASPECT = 1

-- THE BURST GOES SQUARE TOO. A rectangle rotating about its centre sweeps a
-- bigger circle than it occupies and visibly breathes; the template's 3 x 1.5 is
-- a rectangle. 1.8 is the size the owner signed off when this art was last
-- driven -- it was cut to 1.5 then only to stop TWO cards' bursts colliding, and
-- with a single card that constraint is gone. (Cut to 1.0 for twenty minutes on
-- 2026-09-17 on a misread of "make them smaller to fit the card" -- that was the
-- STORE page's bursts, not this one -- and put back.)
--
-- IT STILL HAS TO CLEAR THE BAND AT FULL PRESS, which is the check a resting
-- measurement misses: 1.8 * 1.16 = 2.09 card-heights, and the card is 0.134 of
-- the screen tall, so the grown burst spans 0.28 -- 0.471..0.751 around STACK_Y,
-- inside 0.325..0.897 with room to spare.
local BURST_SCALE = 1.8
local BURST_SPIN = 14

local ART_BOB, ART_BOB_HZ = 0.02, 0.6
local ART_SWAY, ART_SWAY_HZ = 3, 0.35
local HOVER_GROW, PRESS_PUNCH = 0.08, 0.08
local HOVER_EASE, PUNCH_DECAY = 9, 6

-- ConquestShop throttles EVERY message on the Shop channel to one per 1.5s per
-- player, silently. Matching it here is the difference between a second press
-- doing nothing visible and a second press being eaten with no explanation.
local COOLDOWN = 1.5

-- WHAT A PRESS ON THIS PAGE LOOKS AND SOUNDS LIKE: the lobby's own numbers
-- (LobbyUI -- HOVER_IN/OUT, PRESS_IN/OUT, HOVER_SCALE 1.025, PRESS_SCALE 0.97,
-- and the Pop cue at POP_GO 1.35 for a press that commits, POP_BACK 1.0 for
-- one that backs out). Copied rather than required: LobbyUI is the lobby page
-- and a match client has no business loading it for six constants. If the
-- lobby's feel changes, change these with it.
local HOVER_IN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_OUT = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_IN = TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_OUT = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local HOVER_SCALE, PRESS_SCALE = 1.025, 0.97
local POP_GO, POP_BACK, POP_VOL = 1.35, 1.0, 1.15

-- THE CONTENTS ARRIVE AFTER THE PAGE. The tile row and then the pill spring
-- up from POP_FROM on the page's own Back ease, one after the other, so an
-- open reads as three beats rather than one frame. The ROW pops as a unit:
-- the tiles sit in a UIListLayout, and a scale on one tile re-flows its
-- neighbours mid-spring.
local POP_FROM, POP_STAGGER = 0.6, 0.07
local POP_IN = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- A RAY BURST BEHIND EACH ITEM ON OFFER (owner, 2026-09-17: "I need 3 rays
-- behind each of the items being offered in each starter pack"). The burst is
-- the kit's own -- the one behind the store's square cards -- so the pack page
-- and the store are lit the same way. TILE_RAYS matches the store's
-- SQUARE_BURST (1.5 of the tile, clipped by the tile), RAY_SPIN its BURST_SPIN,
-- and no two turn alike for the store's reason: three identical bursts in
-- lockstep read as one object with three holes in it.
local TILE_RAYS, RAY_SPIN = 1.5, 5

-- ============================================================== the art ======

local images = StarterGui:FindFirstChild("Images")

-- The owner's own art, read off the ImageLabels in StarterGui.Images rather
-- than pasted as ids, for the reason the Robux glyph is cloned: an id typed in
-- here is a guess, an instance already drawing is proof. Used by the sticker's
-- own picture below and by the pack page's three reward tiles.
local function imageOf(name: string): string
	local l = images and images:FindFirstChild(name)
	if l ~= nil and l:IsA("ImageLabel") then
		return l.Image
	end
	return ""
end

local template = images and images:FindFirstChild("HudShopTutorial")
if template == nil or not template:IsA("ScreenGui") then
	warn("[TutorialDeal] StarterGui.Images.HudShopTutorial is missing; no deal offered.")
	return
end

local entry = Products.product(PRODUCT_KEY)
-- AN UNCONFIGURED PRODUCT NEVER APPEARS IN A SHOP -- Products' header rule. With
-- one card and one product, that means no ScreenGui at all rather than an empty
-- frame sitting on the HUD.
if not Products.isLive(entry) then
	warn("[TutorialDeal] " .. PRODUCT_KEY .. " is not configured; no deal offered.")
	return
end
local product = entry :: any

local gui = (template :: ScreenGui):Clone()
gui.Name = "ConquestDeal"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
-- ABOVE THE HUD, EXPLICITLY. The template ships at DisplayOrder 0 and so does
-- the HUD's ScreenGui, and a tie is broken by whichever was parented LAST --
-- which is ConquestClient's, because both files wait on the same
-- awaitRole("match") and this one has a few lines of setup against its
-- 3,500. So the full-screen map viewport painted over a card that was
-- enabled, positioned and invisible. 2 is what the old store used; the
-- match intro's curtain is 20 and must stay on top of everything.
gui.DisplayOrder = 2
-- STARTS DOWN, AND THAT IS NOT CAUTION. A ScreenGui parented Enabled is on
-- screen from the frame it is parented, which is before the match intro's
-- curtain is up -- that is exactly how the other shop came to flash at the start
-- of every round. It is raised in `refresh` once a phase is known.
gui.Enabled = false

local stack = gui:FindFirstChild("Buttons")
local card = stack and stack:FindFirstChild("Deal1")
local other = stack and stack:FindFirstChild("Deal2")
if stack == nil or card == nil or not card:IsA("ImageButton") then
	warn("[TutorialDeal] HudShopTutorial is not the expected shape; no deal offered.")
	gui:Destroy()
	return
end
local stackFrame = stack :: GuiObject
local deal = card :: ImageButton

-- ONE OFFER (owner, 2026-09-17). Deal2 is the kit's second sticker and there is
-- no second product behind it; hidden rather than destroyed, so putting a PRO
-- pack in it later is a slot that still exists.
if other ~= nil and other:IsA("GuiObject") then
	other.Visible = false
end

-- Centre the frame on the free band. The centre of a GuiObject is
-- Position + Size * (0.5 - AnchorPoint), which is the only formula that holds
-- whatever anchor the template happens to carry -- so this reads the art rather
-- than assuming it.
do
	local a = stackFrame.AnchorPoint
	local s = stackFrame.Size
	stackFrame.Position = UDim2.new(
		stackFrame.Position.X.Scale,
		stackFrame.Position.X.Offset,
		STACK_Y - s.Y.Scale * (0.5 - a.Y),
		0
	)
end

if deal:FindFirstChildOfClass("UIAspectRatioConstraint") == nil then
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = CARD_ASPECT
	ar.DominantAxis = Enum.DominantAxis.Height
	ar.Parent = deal
end

local burst: GuiObject? = nil
local decor = deal:FindFirstChild("Decor")
if decor ~= nil then
	local b = decor:FindFirstChild("Starbust")
	if b ~= nil and b:IsA("GuiObject") then
		burst = b
		b.Size = UDim2.fromScale(BURST_SCALE, BURST_SCALE)
	end
end

local artChild = deal:FindFirstChild("Icon")
local art: ImageLabel? = if artChild ~= nil and artChild:IsA("ImageLabel") then artChild else nil

-- THE PICTURE ON THE BUTTON IS THE REWARD (owner, 2026-09-17: "for starter pack
-- can you use the image of the reward"). The sticker template ships the kit's
-- own mascot -- a little black blocky character that means nothing here -- and
-- this card is a shop button, so the one job its picture has is to say what is
-- inside. StarterGui.Images.Reward is the owner's gift box.
--
-- WRITTEN ONLY IF THE IMAGE IS ACTUALLY THERE. A missing name comes back as ""
-- from imageOf, and assigning that would leave the button with NO picture at
-- all -- strictly worse than the wrong one -- so an empty answer keeps whatever
-- the art shipped with.
if art ~= nil then
	local reward = imageOf("Reward")
	if reward ~= "" then
		art.Image = reward
		-- The kit's mascot was drawn to fill its box; a parcel is squarer than the
		-- slot it is going into, and Fit is what keeps it from being stretched into
		-- a different-shaped present on a wide window.
		art.ScaleType = Enum.ScaleType.Fit
	end
end

-- ============================================================ the words ======

-- WRITES EVERY child of the name that carries text. The owner's cards elsewhere
-- draw their captions twice as drop-shadow pairs, and FindFirstChild picks one
-- of a twin arbitrarily -- leaving the other reading the placeholder forever.
local function setAll(parent: Instance, name: string, text: string)
	for _, c in parent:GetChildren() do
		if c.Name == name and (c:IsA("TextLabel") or c:IsA("TextButton")) then
			c.Text = text
		end
	end
end

setAll(deal, "Name", "STARTER PACK")

local priceLabel: TextLabel? = nil
for _, c in deal:GetChildren() do
	if c.Name == "Price" and c:IsA("TextLabel") then
		priceLabel = c
		break
	end
end

-- THE ROBUX GLYPH IS CLONED OUT OF THE OWNER'S OWN ART, never built from an id
-- typed in here. Two different hexagons exist in this place and
-- ContentProvider:PreloadAsync reports Failure for BOTH of them plus an id that
-- is visibly rendering on screen -- so that check cannot tell them apart and an
-- id in this file would be a guess. An instance already drawing somewhere is
-- proof by construction.
local function findGlyph(): ImageLabel?
	local store = StarterGui:FindFirstChild("Store")
	if store == nil then
		return nil
	end
	for _, d in store:GetDescendants() do
		if d:IsA("ImageLabel") and d.Parent ~= nil and d.Parent.Name == "Info" then
			return d
		end
	end
	return nil
end

local glyph: ImageLabel? = nil
if priceLabel ~= nil then
	local src = findGlyph()
	if src ~= nil then
		local g = src:Clone()
		g.Name = "RobuxGlyph"
		-- NEVER A UIStroke ON THIS: a stroke outlines the ImageLabel's BOX, not
		-- the shape inside it, so it draws a square frame around the hexagon that
		-- reads as a button around the price.
		for _, d in g:GetDescendants() do
			if d:IsA("UIStroke") then
				d:Destroy()
			end
		end
		g.ZIndex = priceLabel.ZIndex + 1
		-- SQUARE, HEIGHT-LED. The kit's 0.0496 x 1.188 is square only inside the
		-- strip it was drawn on; against this label it was a sliver (owner: "the
		-- robux is flatten").
		g.Size = UDim2.fromScale(1, 0.8)
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = 1
		ar.DominantAxis = Enum.DominantAxis.Height
		ar.Parent = g
		g.Parent = priceLabel
		glyph = g
	end
end

-- ============================================================ the press ======

local lastPress = -1e9
local punch, hover, hovered = 0, 0, false

-- THE PURCHASE, which now lives on the PANEL's pill rather than on the
-- sticker. No card punch here: the thing being pressed is in the panel.
local function buy(): boolean
	local now = os.clock()
	if now - lastPress < COOLDOWN then
		return false
	end
	lastPress = now
	-- Nothing here reports success: the receipt's own effect is the feedback.
	-- The return says only whether the press was HONOURED, so the button's own
	-- Pop can stay silent for one the cooldown ate.
	ShopRE:FireServer("buy", PRODUCT_KEY)
	return true
end

-- THE STICKER IS A DOOR, NOT A TILL (owner, 2026-09-17: "i want the
-- hudshoptutorialbutton to open up shop2 frame") -- AND A DOOR SWINGS BOTH WAYS
-- (owner, the same day: "allow me to close it by pressing the hud again").
--
-- Forward-declared because what it opens is built below, while the button it
-- hangs off is up here. It answers TRUE when the press OPENED the page, which is
-- the only thing this end needs to know.
local togglePanel: (() -> boolean)? = nil
local function press()
	punch = 1
	-- THE TWO DIRECTIONS MUST NOT SOUND ALIKE, or shutting the page is
	-- indistinguishable from opening it -- and on this card they are the same
	-- press, so the sound is the only thing telling them apart. Opening keeps the
	-- bright Pop the lobby commits with; closing takes the flat one the page's own
	-- X already uses.
	--
	-- The toggle runs FIRST because it is what decides the pitch. The `or`
	-- short-circuits, so in a session where no panel was built nothing is called
	-- and the press still answers brightly rather than sounding like a close.
	local opening = togglePanel == nil or togglePanel()
	Sfx.play("Pop", { pitch = if opening then POP_GO else POP_BACK, volume = POP_VOL })
end

-- `Active = false` IS HOW THIS ART FAILED LAST TIME, and it fails silently:
-- GuiButton.Activated does not fire on an inactive button, so every press is
-- dropped and no prompt ever appears. An inactive TRANSPARENT button is worse
-- still -- it does not even register as a hit target, so a hit test at the
-- card's own centre returns the map layers behind it, exactly as if the shop
-- were not on screen. Setting it also makes the card eat its own click, so a
-- press can no longer fall through and start a war behind the card.
for _, b in deal:GetDescendants() do
	if b:IsA("GuiButton") then
		b.Active = true
		b.Selectable = true
		b.Activated:Connect(press)
	end
end
deal.Active = true
deal.Selectable = true
deal.Activated:Connect(press)

deal.MouseEnter:Connect(function()
	if not hovered then
		hovered = true
		Sfx.play("Click", { volume = 0.18, pitch = 1.6 })
	end
end)
deal.MouseLeave:Connect(function()
	hovered = false
end)

-- ============================================================ the panel =====
--
-- SHOP1 SHIPS EMPTY: its Container is a ScrollingFrame holding nothing but a
-- UIListLayout and a UIPadding. What goes into it is the owner's OWN product
-- card, cloned out of the store kit (Container.StarterPack) -- three reward
-- tiles and a buy pill, drawn to sit together. Building rows by hand here
-- would be inventing a second visual language for one product.
local panelTemplate = StarterGui:FindFirstChild("Store")
local panel: ScreenGui? = nil
local shop2: GuiObject? = nil
local panelFrames: GuiObject? = nil
local panelScale: UIScale? = nil
local panelPrice: TextLabel? = nil

if panelTemplate ~= nil and panelTemplate:IsA("ScreenGui") then
	local p = (panelTemplate :: ScreenGui):Clone()
	p.Name = "ConquestDealPanel"
	p.ResetOnSpawn = false
	p.IgnoreGuiInset = true
	-- The Store template ships at DisplayOrder -10, which is UNDER the HUD:
	-- opened as-is, the map draws over the whole panel. One above the sticker
	-- so the panel covers the card it was opened from.
	p.DisplayOrder = 3
	p.Enabled = false
	local frames = p:FindFirstChild("Frames")
	local s1 = frames and frames:FindFirstChild("Shop2")
	local kitStore = frames and frames:FindFirstChild("Store")
	if frames ~= nil and frames:IsA("GuiObject") and s1 ~= nil and s1:IsA("GuiObject") then
		panel, shop2, panelFrames = p, s1, frames
		-- THE KIT'S OWN STORE PAGE GOES. Shop2 is its SIBLING inside the same
		-- holder and both ship Visible, so without this the brainrot store is on
		-- screen behind the panel that replaced it.
		if kitStore ~= nil and kitStore:IsA("GuiObject") then
			kitStore.Visible = false
		end
		s1.Visible = true
		-- Down until asked for, same reason the sticker is: a holder parented
		-- Visible is on screen from that frame.
		frames.Visible = false
		local sc = s1:FindFirstChildOfClass("UIScale")
		if sc == nil then
			sc = Instance.new("UIScale")
			;(sc :: UIScale).Parent = s1
		end
		panelScale = sc
	else
		warn("[TutorialDeal] Store.Frames.Shop2 is missing; the card cannot open a panel.")
		p:Destroy()
	end
end

local PACK_ROWS = {
	-- "+25K" AND NOT "+250,000": troops reach the screen as troops/10
	-- (Numbers.formatTroops), so the card prints what the player's own readout
	-- will print. Config.STARTER_PACK_ARMY_BONUS holds the raw figure.
	{ image = "Sword", name = "Army", amount = "+25K" },
	-- Gold is not divided on the way out, so this figure is literal.
	{ image = "Gold", name = "Gold", amount = "+100K" },
	{ image = "Tower", name = "Defence", amount = "x1" },
}

-- THE PAGE IS THREE TILES AND A BUTTON, NOT A CARD (owner, 2026-09-17: "I
-- literally just want the 3 smaller boxes showing the 3 items. on the bigger
-- startpack frame, the middle frame is unnecesary. then put the green button in
-- the middle of the bottom"). The kit's own Starter Pack card is a wide strip --
-- its own title on the left, the tiles in the middle, the pill bottom-left --
-- and dropped whole into a page whose header already says Starter Pack it read
-- as a card inside a card, titled twice. So the strip is not cloned. Its
-- Rewards row and its BuyButtons are lifted out of it and put on the page
-- directly; the strip's title, timer, stud and starburst stay behind.
--
-- GEOMETRY, IN FRACTIONS OF THE PAGE. Shop2 is 1.335 wide to 1 tall (its own
-- constraint) and its Header takes the top 0.155. Both lifted frames are square
-- in pixels in the kit ONLY because the strip is 4.22:1 -- 0.188 x 0.78 of
-- 420 x 100 is 79 x 78 -- so on this page the square is spelled out with a
-- constraint. A UIAspectRatioConstraint in its default FitWithinMaxSize mode
-- treats Size as a CEILING on both axes, so the width is left at 1 and the
-- height is the axis that binds -- a width of 0 is a 0 x 0 box (measured in
-- the edit-mode rig, 2026-09-17). Each tile is 1 x 1 of the Rewards frame and the row is
-- three tiles with 0.15-tile gaps, 3.3 tiles wide: at TILE 0.35 of a 403 px page
-- that is 141 px tiles and a 465 px row on a 538 px page, 36 px clear each side.
-- 0.37 measured at 14 px a side on the editor's page -- cramped against the
-- tiles' own strokes.
local TILE, TILE_Y = 0.35, 0.46
local PILL, PILL_Y = 0.135, 0.93

-- ONE FAMILY FOR EVERY WORD ON THE PAGE (owner, 2026-09-17: "the text font
-- pattern isnt good here. make it more consistent with everything else in the
-- game"). The Store kit is set in GothamSSm Heavy; the sticker that opens this
-- page, the owner's other art and the lobby's pills are LuckiestGuy. The kit
-- also hangs a UIGradient off one tile's Amount -- the "$1M/s" flourish -- so
-- one of three identical labels came out patterned. Family is unified to the
-- sticker's and the gradients go; strokes are the kit's own and stay.
local PAGE_FONT = Font.new("rbxasset://fonts/families/LuckiestGuy.json")
local function restyle(root: Instance)
	local list = root:GetDescendants()
	table.insert(list, root)
	for _, x in list do
		if x:IsA("TextLabel") or x:IsA("TextButton") then
			x.FontFace = PAGE_FONT
			for _, c in x:GetChildren() do
				if c:IsA("UIGradient") then
					c:Destroy()
				end
			end
		end
	end
end

-- THE ROBUX GLYPH IS PINNED SQUARE. The kit draws it at 0.0496 x 1.188 of a
-- frame that is only square by the strip's proportions; anywhere else those
-- two scales give a hexagon squeezed to a sliver (owner: "the robux is
-- flatten"). The height is the binding axis, so it follows the text it sits
-- beside; the width ceiling stays at whatever the kit set.
local function squareGlyph(g: GuiObject)
	if g:FindFirstChildOfClass("UIAspectRatioConstraint") == nil then
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = 1
		ar.DominantAxis = Enum.DominantAxis.Height
		ar.Parent = g
	end
end

-- EVERY BUTTON ON THE PAGE PRESSES THE SAME WAY, and it is the lobby's way: a
-- lift on hover, a dent on the down, a spring past rest on the up, and the
-- Pop -- bright for the pill, flat for the X. One UIScale per button, tweened
-- and written by nothing else; the sticker's own motion loop never touches
-- these, so the two cannot fight. The pad gets the hover through
-- SelectionGained/Lost, so the virtual cursor lifts a button the way the mouse
-- does. The Pop plays only when the press was HONOURED -- a buy eaten by the
-- cooldown stays silent, so a silent press means "not yet", not "broken".
local function juice(button: GuiButton, pitch: number, onPress: () -> boolean)
	local scale = Instance.new("UIScale")
	scale.Parent = button
	local hovered, held = false, false
	local function settle(info: TweenInfo)
		local target = if held then PRESS_SCALE elseif hovered then HOVER_SCALE else 1
		TweenService:Create(scale, info, { Scale = target }):Play()
	end
	local function enter()
		if not hovered then
			hovered = true
			Sfx.play("Click", { volume = 0.18, pitch = 1.6 })
			settle(HOVER_IN)
		end
	end
	local function leave()
		hovered, held = false, false
		settle(HOVER_OUT)
	end
	button.Active = true
	button.Selectable = true
	button.MouseEnter:Connect(enter)
	button.MouseLeave:Connect(leave)
	button.SelectionGained:Connect(enter)
	button.SelectionLost:Connect(leave)
	button.MouseButton1Down:Connect(function()
		held = true
		settle(PRESS_IN)
	end)
	button.MouseButton1Up:Connect(function()
		held = false
		settle(PRESS_OUT)
	end)
	button.Activated:Connect(function()
		if onPress() then
			Sfx.play("Pop", { pitch = pitch, volume = POP_VOL })
		end
	end)
end

-- The frames that spring in when the page opens, in the order they arrive.
local poppers: { UIScale } = {}
-- The rays behind the pack's items, each with its own turn.
local tileRays: { { rays: GuiObject, spin: number } } = {}
local function popper(frame: GuiObject)
	local sc = Instance.new("UIScale")
	sc.Parent = frame
	table.insert(poppers, sc)
end

if shop2 ~= nil then
	local page = shop2 :: GuiObject
	local kitCard: Instance? = panelTemplate
	for _, step in { "Frames", "Store", "StoreFrame", "Container", "StarterPack" } do
		kitCard = kitCard and kitCard:FindFirstChild(step)
	end
	local kitRewards = kitCard and kitCard:FindFirstChild("Rewards")
	local kitPill = kitCard and kitCard:FindFirstChild("BuyButtons")
	local raysSrc: Instance? = panelTemplate
	for _, step in { "Frames", "Store", "StoreFrame", "Container", "Gamepasses", "2xCash", "Decor", "Starbust" } do
		raysSrc = raysSrc and raysSrc:FindFirstChild(step)
	end
	
	local header = page:FindFirstChild("Header")
	if header ~= nil then
		restyle(header)
	end
	
	-- THE REWARD TILES, named "1".."3" and ordered by their own list layout,
	-- so the Nth row here is the Nth tile on screen. setAll being
	-- DIRECT-CHILDREN-ONLY is what keeps each tile's `Name` label its own.
	if kitRewards ~= nil and kitRewards:IsA("GuiObject") then
		local box = (kitRewards :: GuiObject):Clone()
		box.Name = "Rewards"
		box.AnchorPoint = Vector2.new(0.5, 0.5)
		box.Position = UDim2.fromScale(0.5, TILE_Y)
		box.Size = UDim2.fromScale(1, TILE)
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = 1
		ar.DominantAxis = Enum.DominantAxis.Height
		ar.Parent = box
		for i, r in PACK_ROWS do
			local tile = box:FindFirstChild(tostring(i))
			if tile ~= nil then
				setAll(tile, "Name", r.name)
				setAll(tile, "Amount", r.amount)
				-- THE AMOUNT IS CENTRED, LIKE THE NAME ABOVE IT. The kit right-aligns
				-- it -- its own placeholder was "$1M/s" running to the corner -- so
				-- "+25K" hugged the bottom-right while "Army" sat centred at the top:
				-- two labels on one tile, hung two different ways.
				for _, c in tile:GetChildren() do
					if c:IsA("TextLabel") then
						c.TextXAlignment = Enum.TextXAlignment.Center
					end
				end
				local ti = tile:FindFirstChild("Icon")
				if ti ~= nil and ti:IsA("ImageLabel") then
					ti.Image = imageOf(r.image)
					ti.ScaleType = Enum.ScaleType.Fit
				end
				-- The burst sits under the icon (ZIndex 0) and the words (3); the tile
				-- clips it, the way the store's square cards clip theirs.
				if raysSrc ~= nil and raysSrc:IsA("ImageLabel") and tile:IsA("GuiObject") then
					local rays = (raysSrc :: ImageLabel):Clone()
					rays.Name = "Rays"
					rays.AnchorPoint = Vector2.new(0.5, 0.5)
					rays.Position = UDim2.fromScale(0.5, 0.5)
					rays.Size = UDim2.fromScale(TILE_RAYS, TILE_RAYS)
					rays.ZIndex = -1
					rays.Rotation = i * 37
					rays.Parent = tile
					tile.ClipsDescendants = true
					table.insert(tileRays, {
						rays = rays,
						spin = RAY_SPIN * (1 + 0.22 * (i % 3)) * (if i % 2 == 0 then 1 else -1),
					})
				end
			end
		end
		restyle(box)
		popper(box)
		box.Parent = page
	end
	
	-- THE TILL, centred on the bottom edge. The pill inside is 3 x 1 of this
	-- frame, so the frame is the square the pill's height is measured from.
	if kitPill ~= nil and kitPill:IsA("GuiObject") then
		local pill = (kitPill :: GuiObject):Clone()
		pill.Name = "BuyButtons"
		pill.AnchorPoint = Vector2.new(0.5, 1)
		pill.Position = UDim2.fromScale(0.5, PILL_Y)
		pill.Size = UDim2.fromScale(1, PILL)
		local ar = Instance.new("UIAspectRatioConstraint")
		ar.AspectRatio = 1
		ar.DominantAxis = Enum.DominantAxis.Height
		ar.Parent = pill
		for _, x in pill:GetDescendants() do
			if x:IsA("TextLabel") and x.Name == "Price" then
				panelPrice = x
			elseif x:IsA("ImageLabel") and x.Parent ~= nil and x.Parent.Name == "Info" then
				squareGlyph(x)
			elseif x:IsA("GuiButton") then
				juice(x, POP_GO, buy)
			end
		end
		restyle(pill)
		popper(pill)
		pill.Parent = page
	end
end
local OPEN_TIME, CLOSE_TIME, OPEN_FROM = 0.18, 0.14, 0.86

-- THE BACKGROUND DIMS BEHIND THE PAGE (owner, 2026-09-17: "when i open up the
-- starter pack, it should have the same background blur my store does").
--
-- WHAT "BLUR" MEANS IN THIS GAME, AND IT IS NOT THE BlurEffect. The map is not
-- 3D -- Renderer paints tiles into EditableImages on ImageLabels, so there is
-- nothing in the 3D scene for a post-process to work on, and Roblox has no GUI
-- blur. TutorialShopClient found that out the hard way, with a BlurEffect that
-- was running correctly the whole time and blurring an empty world. The visible
-- half is a full-screen black SCRIM. The BlurEffect is raised alongside it
-- anyway, exactly as the store does, so the two stay in step for any 3D content
-- ever put behind the interface.
--
-- BOTH NUMBERS ARE THE STORE'S, copied and not required: these are two separate
-- shop files by design and neither loads the other (the same call the feel
-- constants above make). They are ONE effect as far as a player is concerned,
-- so if TutorialShopClient's move, these move with them.
local SCRIM_ALPHA = 0.68
local BLUR_MAX = 28

-- Inside the panel's own `Frames`, so it arrives and leaves with the page, and
-- ZIndex 0 so every part of the page draws over it -- this ScreenGui is
-- ZIndexBehavior Sibling and the kit's pages sit at 1 and above (measured, not
-- assumed: Shop2 is 1, the kit store 111).
--
-- WHAT IS DELIBERATELY NOT UNDER IT: the SHOP tab, which TutorialShopClient
-- moved to DisplayOrder 4 for this (owner, 2026-09-17: "tab itself got blurred
-- too"). A scrim dims a whole ScreenGui or none of it, so anything that must
-- stay lit while this page is up has to live ABOVE 3 -- there is no way to
-- exempt it from here. The sticker at 2 stays under, and should: it is the
-- control that was just pressed, and dimming it is what says so.
local scrim: TextButton? = nil
if panelFrames ~= nil then
	local pf = panelFrames :: GuiObject
	local found = pf:FindFirstChild("ConquestScrim")
	if found ~= nil and found:IsA("TextButton") then
		scrim = found
	else
		local sc = Instance.new("TextButton")
		sc.Name = "ConquestScrim"
		sc.Text = ""
		sc.AutoButtonColor = false
		sc.BackgroundColor3 = Color3.new(0, 0, 0)
		sc.BackgroundTransparency = 1
		sc.BorderSizePixel = 0
		sc.Size = UDim2.fromScale(1, 1)
		sc.Position = UDim2.fromScale(0.5, 0.5)
		sc.AnchorPoint = Vector2.new(0.5, 0.5)
		sc.ZIndex = 0
		sc.Parent = pf
		scrim = sc
	end
end

-- MADE ON FIRST OPEN and living in Lighting only while the page does: a
-- BlurEffect parked in the tree blurs the game for everybody from the moment it
-- boots, whether or not anyone ever opens a shop.
local blur: BlurEffect? = nil
local function ensureBlur(): BlurEffect
	local b = blur
	if b == nil or b.Parent == nil then
		b = Instance.new("BlurEffect")
		local nb = b :: BlurEffect
		nb.Name = "ConquestDealBlur"
		nb.Size = 0
		nb.Parent = game:GetService("Lighting")
		blur = nb
	end
	return blur :: BlurEffect
end

-- A BLUR THAT OUTLIVES ITS PAGE IS A BUG THE PLAYER CANNOT FIX -- a teleport or
-- a rebuild would leave the world permanently out of focus with nothing on
-- screen to explain it.
if panel ~= nil then
	local pn = panel :: ScreenGui
	pn.Destroying:Connect(function()
		if blur ~= nil then
			blur:Destroy()
			blur = nil
		end
	end)
end

local open = false
local openToken = 0

-- HIDDEN ONLY AFTER THE FADE, and only if this is still the newest request:
-- a close that lands while a reopen is in flight would blank the panel that
-- was just asked for.
local function setOpen(v: boolean)
	if open == v or panel == nil or panelFrames == nil then
		return
	end
	open = v
	openToken += 1
	local token = openToken
	if open then
		local pn = panel :: ScreenGui
		local pf = panelFrames :: GuiObject
		pn.Enabled = true
		pf.Visible = true
		-- The contents follow the page in, one beat apart. Each spring is
		-- skipped if the page was shut again before its turn came.
		for i, sc in poppers do
			sc.Scale = POP_FROM
			task.delay(0.05 + (i - 1) * POP_STAGGER, function()
				if open and token == openToken then
					TweenService:Create(sc, POP_IN, { Scale = 1 }):Play()
				end
			end)
		end
		if panelScale ~= nil then
			local ps = panelScale :: UIScale
			ps.Scale = OPEN_FROM
			TweenService:Create(ps, TweenInfo.new(OPEN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
		-- The background goes down on the page's own curve, not the store's: this
		-- panel opens in 0.18 where the store takes 0.22, and a dim that lags the
		-- thing it is backing reads as a second, slower animation.
		TweenService:Create(ensureBlur(), TweenInfo.new(OPEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = BLUR_MAX,
		}):Play()
		if scrim ~= nil then
			TweenService:Create(scrim, TweenInfo.new(OPEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				BackgroundTransparency = 1 - SCRIM_ALPHA,
			}):Play()
		end
	else
		if panelScale ~= nil then
			TweenService:Create(panelScale, TweenInfo.new(CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = OPEN_FROM }):Play()
		end
		if blur ~= nil then
			TweenService:Create(blur, TweenInfo.new(CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = 0 }):Play()
		end
		if scrim ~= nil then
			TweenService:Create(scrim, TweenInfo.new(CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				BackgroundTransparency = 1,
			}):Play()
		end
		task.delay(CLOSE_TIME, function()
			if token == openToken and not open and panelFrames ~= nil then
				local pf = panelFrames :: GuiObject
				pf.Visible = false
			end
		end)
	end
end
-- THE SCRIM IS A BUTTON, AND THAT IS THE TOGGLE'S DOING. The store's scrim is an
-- inert Frame that only EATS the click -- the other half of a modal, so a press
-- that misses the panel cannot land on the map and order an attack. Copied
-- verbatim it would break the one thing the owner asked for on THIS panel: that
-- pressing the sticker again shuts it (togglePanel). The sticker's ScreenGui is
-- DisplayOrder 2 and this panel is 3, so a full-screen scrim sits ON TOP of the
-- sticker and swallows that press with no way to leave a hole for it.
--
-- So the scrim's own press is routed to setOpen(false). Pressing where the
-- sticker is still closes the page -- the behaviour is intact, it is simply this
-- layer answering instead -- and every other miss dismisses too, which is what a
-- backdrop does everywhere else.
if scrim ~= nil then
	local sc = scrim :: TextButton
	sc.Activated:Connect(function()
		setOpen(false)
	end)
end

togglePanel = function(): boolean
	-- A SECOND PRESS SHUTS IT (owner, 2026-09-17: "allow me to close it by
	-- pressing the hud again"). The sticker is the only way IN, so it has to be a
	-- way out as well: without this the X in the page's header is the single exit,
	-- and the sticker goes on sitting there lit and clickable doing nothing.
	--
	-- THE PRESS NO LONGER REACHES THE STICKER, AND THE TOGGLE STILL WORKS. The
	-- page's own `Frames` is a full-screen Frame that is Active = false and fully
	-- transparent, so it never took the click -- but the SCRIM inside it is a
	-- full-screen button at DisplayOrder 3, over the sticker's 2, and it does.
	-- That press arrives as the scrim's own Activated and is routed to
	-- setOpen(false), so pressing the sticker a second time shuts the page exactly
	-- as before; this function is now the way IN and the keyboard/pad route out.
	--
	-- `setOpen` ignores a call that does not change `open`, and owns the
	-- open/close race with its own token, so a press landing mid-tween is already
	-- handled. This only has to name the direction and report which way it went.
	setOpen(not open)
	return open
end

-- THE CLOSE BUTTON, the one players reach for first: a panel with an X on it
-- that does not shut is the most obvious thing that can be wrong with a shop.
if shop2 ~= nil then
	local header = shop2:FindFirstChild("Header")
	local btns = header and header:FindFirstChild("Buttons")
	local close = btns and btns:FindFirstChild("Close")
	if close ~= nil and close:IsA("GuiButton") then
		juice(close, POP_BACK, function()
			setOpen(false)
			return true
		end)
	end
end

-- THE PRICE IS ASKED OF THE SITE: managed pricing varies it by region, so the
-- catalogue's `robux` is only what to draw until the answer lands. BOTH labels
-- are written from one place -- the sticker's and the panel's -- because two
-- writers for one number is how they come to disagree.
local function paintPrice(n: number)
	if priceLabel ~= nil then
		priceLabel.Text = tostring(n)
	end
	if panelPrice ~= nil then
		local pp = panelPrice :: TextLabel
		pp.Text = tostring(n)
	end
end
paintPrice(product.robux)
task.spawn(function()
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(product.id, Enum.InfoType.Product)
	end)
	if ok and type(info) == "table" then
		local real = tonumber((info :: any).PriceInRobux)
		if real ~= nil then
			paintPrice(real)
		end
	end
end)

-- ============================================================ the motion =====

-- ALL MOTION IN ONE LOOP AND NOTHING ELSE WRITES THESE PROPERTIES. A tween
-- writing Size while a loop writes Size is the classic fight where one silently
-- wins -- so the press is an IMPULSE the loop spends, hover is a value the loop
-- eases, and the spin and the bob are computed in the same place.
local artBase = if art ~= nil then art.Size else nil
local artX = if art ~= nil then art.Position.X.Scale else 0
local artY = if art ~= nil then art.Position.Y.Scale else 0

RunService.RenderStepped:Connect(function(dt)
	-- Returns immediately while the card is down, which is most of a session.
	if not gui.Enabled then
		return
	end
	local clock = os.clock()

	hover += ((if hovered then 1 else 0) - hover) * math.min(1, dt * HOVER_EASE)
	punch = math.max(0, punch - dt * PUNCH_DECAY)

	-- The rays behind the pack's items turn only while the page is up.
	if open then
		for _, r in tileRays do
			r.rays.Rotation = (r.rays.Rotation + dt * r.spin) % 360
		end
	end

	if burst ~= nil then
		burst.Rotation = (clock * BURST_SPIN) % 360
		local k = BURST_SCALE * (1 + HOVER_GROW * hover + PRESS_PUNCH * punch)
		burst.Size = UDim2.fromScale(k, k)
	end

	if art ~= nil and artBase ~= nil then
		local k = 1 + HOVER_GROW * hover + PRESS_PUNCH * punch
		art.Size = UDim2.fromScale(artBase.X.Scale * k, artBase.Y.Scale * k)
		local bob = math.sin(clock * ART_BOB_HZ * math.pi * 2) * (ART_BOB + 0.01 * hover)
		art.Position = UDim2.fromScale(artX, artY + bob)
		art.Rotation = math.sin(clock * ART_SWAY_HZ * math.pi * 2) * ART_SWAY * (1 - 0.6 * hover)
	end

	-- THE GLYPH IS PLACED AGAINST THE RENDERED TEXT, re-measured every frame.
	-- The price label is centre-aligned and TextScaled, so where its first digit
	-- starts moves BOTH with the number's width (the site's real price replaces
	-- the fallback) and with the card's size.
	if glyph ~= nil and priceLabel ~= nil then
		local w = priceLabel.AbsoluteSize.X
		if w > 0 then
			local half = priceLabel.TextBounds.X / w * 0.5
			glyph.AnchorPoint = Vector2.new(1, 0.5)
			glyph.Position = UDim2.fromScale(0.5 - half - 0.04, 0.5)
		end
	end
end)

-- ========================================================= when it shows =====

local phase = ""
local lessonLive = false

-- SHOWN ONLY DURING THE TUTORIAL (owner, 2026-09-17: "i want hud shop tutorial
-- to only be shown during the tutorial"), and gated on the PHASE as well as on
-- the lesson -- which is not belt-and-braces, it is the difference between
-- taking money and giving nothing.
--
-- ConquestServer.redeemBoost refuses unless `sim.phase == "playing"` AND the
-- buyer has a live empire. `onGranted` redeems ONCE, for the key just bought,
-- the moment the receipt is durable -- there is no sweep on round start, no
-- retry, and nothing else in the codebase calls redeemBoost. So a token banked
-- while the round is still in its SPAWN phase is stranded on the profile
-- permanently, and a later purchase does not flush it. A card shown one phase
-- too early is a card that charges 9 R$ for nothing.
--
-- `finished` / `failed` come off the lesson state itself: a student who has
-- completed or washed out of the track is no longer in a tutorial, whatever the
-- round still says.
local function refresh()
	gui.Enabled = lessonLive and phase == "playing"
	-- THE PANEL GOES WITH THE CARD. If the lesson ends while the shop is open,
	-- a full-screen panel would otherwise stay up over a round it can no longer
	-- sell into.
	if not gui.Enabled then
		setOpen(false)
		if panel ~= nil then
			local pn = panel :: ScreenGui
			pn.Enabled = false
		end
	end
	-- READABLE FROM OUTSIDE. "The card is not on screen" has two causes and
	-- they need telling apart without a print into a console already flooded by
	-- the string table's warnings. Attributes replicate and can be read off the
	-- instance at any moment, including from a probe in another session.
	gui:SetAttribute("dbgPhase", phase)
	gui:SetAttribute("dbgLesson", lessonLive)
end

local function lessonFrom(state: any?): boolean
	-- A lite card -- a follower's three cards inside a real match -- is not
	-- a lesson round, so it opens none of the tutorial's deals.
	return type(state) == "table" and state.lite ~= true and not state.finished and not state.failed
end

StateRE.OnClientEvent:Connect(function(kind, payload)
	local p: any = payload
	if kind == "init" then
		phase = (if type(p) == "table" then tostring(p.phase) else "")
		lessonLive = lessonFrom(if type(p) == "table" then p.tutorial else nil)
	elseif kind == "tutorial" then
		lessonLive = lessonFrom(p)
	elseif kind == "phase" then
		if type(p) == "table" then
			if p.phase ~= nil then
				phase = tostring(p.phase)
			end
			-- THE DURABLE HALF, and the reason the first version of this gate never
			-- opened. `init` is sent once at round start and this file finishes its
			-- own setup after that, so it is routinely missed; the "tutorial"
			-- message then only arrives when a card or a ring moves. Reading the
			-- flag off THIS broadcast -- which repeats every STATS_INTERVAL to every
			-- client -- means a late listener converges in 200 ms rather than
			-- waiting on a lesson event that may never come while the card is
			-- wanted. A BOOLEAN here; `init` carries the lesson TABLE, which is why
			-- the two are read in separate branches.
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
if panel ~= nil then
	local pn = panel :: ScreenGui
	pn.Parent = playerGui
end
gui.Parent = playerGui
