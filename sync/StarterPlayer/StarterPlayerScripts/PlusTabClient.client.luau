--!strict
-- Conquest :: PlusTabClient  (client)
--
-- THE EXTRA BUILDINGS CARD'S PAGE. "The extra buildings card" is the CODEBASE
-- NAME for the "+" card and this tab (owner, 2026-09-21: "name it the extra
-- buildings card" -- "only in the codebase so i can refer to it"): the name
-- lives in comments and notes, never on screen. The face is a bare "+" and
-- the page's title is empty on purpose.
--
-- THE "+" CARD'S PAGE (owner, 2026-09-21: "one more card always on the right
-- side that just has a + sign, when you click it, it opens up an empty tab
-- that should have the same behaviour as all other tabs in the game
-- blur/sfx/hover effects wise. The tab can be blank for now" -- then: "id
-- prefer if the tab was in the style of the alliances tab" -- then: "i also
-- want the tab a lot bigger, taking up like 60% of the horizontal space of
-- the screen and 60% of the height. I want to blur the background when i
-- open the tab").
--
-- The CARD is the HUD's: HUD.RAIL_ACTIONS carries it as id "plus", so it is
-- drawn, laid out and hover-lit with city / port / nuke and sits last on the
-- right, ringed in gold. What it OPENS is here, and it is the ALLIANCE
-- PANEL'S DRAWING at the STORE'S SIZE AND WEIGHT: a code-built frame in the
-- HUD's own palette -- near-opaque PANEL navy, a gold edge, a bold title row
-- with an X, a hairline rule under it -- that pops open with a Size tween,
-- and behind it the store's full-screen scrim and blur.
--
-- 60% BY 60%, CENTRED. At 768 x 432 of the 1280 x 720 reference the page is
-- no longer a side panel that can stand beside its control; it is a modal,
-- and a modal sits in the middle of the screen the way the store does. The
-- pop grows from the centre for the same reason.
--
-- WHAT "BLUR" MEANS IN THIS GAME (TutorialShopClient's note, the long
-- version): the map is a GUI layer -- Renderer paints tiles into
-- EditableImages on ImageLabels -- so a BlurEffect, a post-process on the 3D
-- scene, blurs an empty world behind the interface. The visible half is a
-- full-screen black SCRIM at the store's 0.68; the BlurEffect is raised
-- beside it, at the store's 28, so the two pages stay in step for any 3D
-- content ever put behind the interface. THE SCRIM COVERS THE HUD, rail and
-- "+" card included, exactly as the store's does: the X is the way out.
--
-- ITS OWN SCRIPT, for the shop's and the alliance tab's reasons:
-- ConquestClient sits at Luau's 200-local ceiling and the HUD is one class
-- every readout already shares. HUD.bindActions skips the "+" record (it is a
-- door, not a build mode), so this file is the only listener on the button,
-- found in PlayerGui by name: Conquest.Rail.Actplus.
--
-- MIRRORS DiplomacyClient (palette, fonts, title/close/rule geometry, the
-- hover tick and grow, the open pop) and TutorialShopClient (scrim, blur,
-- close fade). Change a number there and here together.

local Lighting = game:GetService("Lighting")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Matchmaker = require(Shared.Matchmaker)
local Net = require(Shared.Net)
local Products = require(Shared.Products)
-- THE LOBBY SHOP'S PASS PAGE, drawn here at this panel's size (2026-09-22):
-- the same cards -- header, perk list, Robux pill, OWNED -- so the two doors
-- to the extra-buildings passes sell one thing one way.
local PassShop = require(Shared.PassShop)
local Sfx = require(Shared.Sfx)

-- A lobby server runs no round, so it has no rail. YIELDING rather than
-- returning is what every match-only client does: a Studio lobby FLIPS to
-- "match" when its own countdown fires.
Matchmaker.awaitRole("match")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ------------------------------------------------------------------ the look --
-- The HUD's constants, verbatim (DiplomacyClient carries the same list), so
-- a panel here reads as one of its own.
local FAMILY = Font.fromEnum(Enum.Font.GothamMedium).Family
local FONT_DISPLAY = Font.new(FAMILY, Enum.FontWeight.Bold)
local INK = Color3.fromRGB(234, 240, 250)
local INK_DIM = Color3.fromRGB(178, 190, 212)
local PANEL = Color3.fromRGB(15, 20, 32)
local LINE = Color3.fromRGB(52, 66, 94)
-- The HUD's price gold -- the ring the "+" card wears on the rail, so the
-- page and the card that opens it are ringed alike.
local GOLD = Color3.fromRGB(232, 196, 110)

local REF_W, REF_H = 1280, 720

-- ----------------------------------------------------------------- the panel --
-- 60% of the screen each way (owner), centred. The title row, its padding and
-- the X are the alliance panel's numbers, so the two pages are one drawing at
-- two sizes.
local PANEL_W = REF_W * 0.6
local PANEL_H = REF_H * 0.6
local PANEL_CX = REF_W / 2
local PANEL_CY = REF_H / 2
local TITLE_H = 40
local ROW_PAD = 12
local BTN_HOVER_GROW = 0.06
-- The pop: 94% -> 100% with a little overshoot, the alliance panel's numbers.
local OPEN_FROM = 0.94
local OPEN_TIME = 0.22
-- The way out gets out of the way: the store's close fade.
local CLOSE_TIME = 0.14
-- HOW DARK THE WORLD GOES BEHIND THE PAGE and how hard the (invisible) 3D
-- blur pulls -- the store's 0.68 and 28, so "blurred" means the same thing
-- behind every page in the game.
local SCRIM_ALPHA = 0.68
local BLUR_MAX = 28

-- ================================================================== helpers ==

-- Authored pixels -> Scale, read against the DIRECT parent's reference
-- footprint (the HUD's own primitive).
local function place(inst: GuiObject, pw: number, ph: number, x: number, y: number, w: number, h: number)
	inst.Size = UDim2.fromScale(w / pw, h / ph)
	inst.Position = UDim2.fromScale(x / pw, y / ph)
end

-- Text is TextScaled inside a box whose height IS the type size, capped so a
-- big window does not blow it up (the HUD's rule).
local function label(parent: Instance, name: string, font: Font, size: number, color: Color3): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.FontFace = font
	t.TextColor3 = color
	t.TextScaled = true
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Center
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = size
	cap.Parent = t
	t.Parent = parent
	return t
end

local function button(parent: Instance, name: string, size: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.FontFace = FONT_DISPLAY
	b.TextScaled = true
	b.Active = true
	b.Selectable = true
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = size
	cap.Parent = b
	b.Parent = parent
	return b
end

-- EVERY BUTTON ANSWERS THE CURSOR (owner: "buttons should all have hover
-- effects"). A short tween each way rather than an entry in a frame loop:
-- this is pressed a handful of times a round. The alliance panel's tick and
-- grow, to the number.
local function hoverable(b: GuiButton, base: UDim2)
	b.MouseEnter:Connect(function()
		if not b.Active then
			return
		end
		Sfx.play("Click", { volume = 0.12, pitch = 1.7 })
		TweenService:Create(b, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(base.X.Scale * (1 + BTN_HOVER_GROW), base.Y.Scale * (1 + BTN_HOVER_GROW)),
		}):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = base }):Play()
	end)
end

-- ==================================================================== build ==

local gui = Instance.new("ScreenGui")
gui.Name = "ConquestPlusTab"
gui.Enabled = false
gui.ResetOnSpawn = false
-- The same inset rule as the HUD and the two side tabs, so the page is
-- centred on the same screen the rail is drawn on.
gui.IgnoreGuiInset = true
-- 4, the store's layer: over the map and the HUD (0), the Starter Pack
-- sticker (2) and its panel (3), under the match intro's curtain (20). Each
-- page's scrim eats every press while it is up, so only one of them can be
-- opened at a time and they never need to know about each other.
gui.DisplayOrder = 4
-- SIBLING ORDERING, SAID OUT LOUD (2026-09-22). `Instance.new("ScreenGui")`
-- comes up GLOBAL, where every ZIndex on the screen competes with every
-- other: PassShop's cards (ZIndex 0-2, drawn for the lobby's Sibling screen)
-- landed UNDER this panel's 12 and the scrim's 11 and showed as ghosts
-- through the navy. Under Sibling a child always draws over its parent and
-- ZIndex only orders brothers, which is what the 11/12/13 below always meant.
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- THE SCRIM. Full-screen, under the panel (ZIndex 11 to its 12), and it EATS
-- THE CLICK -- the other half of a modal: without this a press that misses
-- the page lands on the map underneath and orders an attack. Shown and
-- faded with the page; see setOpen.
local scrim = Instance.new("Frame")
scrim.Name = "Scrim"
scrim.BackgroundColor3 = Color3.new(0, 0, 0)
scrim.BackgroundTransparency = 1
scrim.BorderSizePixel = 0
scrim.AnchorPoint = Vector2.new(0.5, 0.5)
scrim.Position = UDim2.fromScale(0.5, 0.5)
scrim.Size = UDim2.fromScale(1, 1)
scrim.Active = true
scrim.Visible = false
scrim.ZIndex = 11
scrim.Parent = gui
-- A PRESS ON THE SCRIM CLOSES THE PAGE (owner, 2026-09-22: "if i click in the
-- blurred out area, i can also close the tab"). The scrim still eats the
-- press -- it never reaches the map -- but the press is now also the way
-- out, the way a tap outside a phone sheet is. A BUTTON child, not
-- InputBegan on the frame: a button fires only when it is the frontmost thing
-- under the pointer, so a press on the panel (ZIndex 12, over this whole
-- subtree) can never close the page from underneath it. Wired in open/close.
local dismiss = Instance.new("TextButton")
dismiss.Name = "Dismiss"
dismiss.Text = ""
dismiss.BackgroundTransparency = 1
dismiss.AutoButtonColor = false
-- Never a gamepad selection target: a full-screen selectable would swallow
-- the pad's focus the moment the page opened (the pad points with the
-- virtual cursor here anyway, see Gamepad).
dismiss.Selectable = false
dismiss.Size = UDim2.fromScale(1, 1)
dismiss.Parent = scrim

local panel = Instance.new("Frame")
panel.Name = "PlusPanel"
panel.BackgroundColor3 = PANEL
-- All but opaque, the HUD's own reason: a nation label is 400 px of near-white
-- text and it ghosts straight through anything lighter.
panel.BackgroundTransparency = 0.04
panel.BorderSizePixel = 0
panel.Active = true
panel.Visible = false
-- Centre-anchored, so the pop grows from the middle of the screen the way
-- the store's does.
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.ZIndex = 12
place(panel, REF_W, REF_H, PANEL_CX, PANEL_CY, PANEL_W, PANEL_H)
panel.Parent = gui

-- NO STROKE ON THE BOX. The gold ring is the CARD's and only the card's
-- (owner, 2026-09-21: "When i said the gold stroke on the thing, i didnt
-- mean the tab, i meant the card"); the alliance panel this copies has no
-- edge either, so the page is the plain navy box.

-- The title row: an EMPTY title (the page shows no name on screen; "extra
-- buildings" is the codebase name only), the X at its right, and the hairline
-- under both -- the alliance panel's row, so a caption dropped into
-- `title.Text` later lands exactly where ALLIANCES does.
local title = label(panel, "Title", FONT_DISPLAY, 16, INK)
title.Text = ""
title.ZIndex = 13
place(title, PANEL_W, PANEL_H, ROW_PAD, 0, PANEL_W - ROW_PAD * 2 - 30, TITLE_H)

-- THE X IS A BUTTON YOU CAN SEE (owner, 2026-09-22: "make the x button more
-- obvious"): a filled chip with an edge and bright ink, not a bare dim letter
-- in the corner -- the page is a modal and this is its only way out. The
-- edge and the letter go gold when the cursor finds it, the rail's own lit
-- colour, on top of the grow every button here does.
local CLOSE_S = 30
local CLOSE_FILL = Color3.fromRGB(38, 43, 56)
local closeBtn = button(panel, "Close", 20)
closeBtn.Text = "X"
closeBtn.BackgroundTransparency = 0
closeBtn.BackgroundColor3 = CLOSE_FILL
closeBtn.TextColor3 = INK
closeBtn.ZIndex = 13
place(closeBtn, PANEL_W, PANEL_H, PANEL_W - ROW_PAD - CLOSE_S, (TITLE_H - CLOSE_S) / 2, CLOSE_S, CLOSE_S)
local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 8)
closeCorner.Parent = closeBtn
local closeEdge = Instance.new("UIStroke")
closeEdge.Color = LINE
closeEdge.Thickness = 1.6
closeEdge.Parent = closeBtn
closeBtn.MouseEnter:Connect(function()
	closeEdge.Color = GOLD
	closeBtn.TextColor3 = GOLD
end)
closeBtn.MouseLeave:Connect(function()
	closeEdge.Color = LINE
	closeBtn.TextColor3 = INK
end)

local rule = Instance.new("Frame")
rule.Name = "Rule"
rule.BackgroundColor3 = LINE
rule.BorderSizePixel = 0
rule.ZIndex = 13
place(rule, PANEL_W, PANEL_H, 0, TITLE_H - 1, PANEL_W, 1)
rule.Parent = panel

-- THE BODY. A named frame under the rule, laid out against
-- PANEL_W x (PANEL_H - TITLE_H); it was blank until 2026-09-22.
local body = Instance.new("Frame")
body.Name = "Body"
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ZIndex = 13
place(body, PANEL_W, PANEL_H, 0, TITLE_H, PANEL_W, PANEL_H - TITLE_H)
body.Parent = panel

-- THE EXTRA BUILDINGS PASSES (2026-09-22, owner: "when players press the +
-- Card in game and it opens up the tab ... Only these 3 should show up for
-- the + one in the game"). PassShop draws them exactly as the lobby's
-- GAMEPASSES tab does, fitted into this body with a line under the cards for
-- the one thing the page ever says out loud.
local BODY_H = PANEL_H - TITLE_H
local PAGE_PAD = 10
local MSG_H = 20
local page = PassShop.new(body, PANEL_W, BODY_H, PAGE_PAD, PAGE_PAD, PANEL_W - PAGE_PAD * 2, BODY_H - PAGE_PAD * 2 - MSG_H, Products.PLUS_PASSES)

-- A press goes up the Shop remote's `pass` verb -- PromptGamePassPurchase,
-- the route the VIP card and the room dials already take. The site decides;
-- the card flips to OWNED when the server has re-asked it and written the
-- attribute below.
local netFolder = Net.await(ReplicatedStorage)
local ShopRE = netFolder:WaitForChild("Shop") :: RemoteEvent
page.onPass = function(key: string)
	ShopRE:FireServer("pass", key)
end
-- ...and the Money half of the same card (2026-09-22): the server settles it
-- and answers on this remote, balance included.
page.onMoney = function(key: string)
	ShopRE:FireServer("passmoney", key)
end
-- WHAT THIS ACCOUNT HAS TO SPEND. A match server never pushes the balance
-- (the lobby's page is told on load; this one is not), so the page asks for
-- it when it opens (setOpen) and takes the answer here. The rename's "nation"
-- and "denied" ride the same remote and are somebody else's.
ShopRE.OnClientEvent:Connect(function(kind, a, b, c, d)
	if kind == "money" then
		page:setMoney(tonumber(a))
	elseif kind == "passmoney" then
		page:setMoney(tonumber(d))
		local fn = page.onSay
		if fn then
			fn(string.upper(tostring(c)))
		end
	end
end)

local message = label(body, "Message", FONT_DISPLAY, 14, GOLD)
message.Text = ""
message.TextXAlignment = Enum.TextXAlignment.Center
message.ZIndex = 13
place(message, PANEL_W, BODY_H, ROW_PAD, BODY_H - PAGE_PAD - MSG_H, PANEL_W - ROW_PAD * 2, MSG_H)
local sayToken = 0
page.onSay = function(text: string)
	message.Text = text
	sayToken += 1
	local token = sayToken
	task.delay(5, function()
		if token == sayToken then
			message.Text = ""
		end
	end)
end

-- WHAT THIS ACCOUNT HOLDS, off the ConquestPass_<KEY> attributes the server
-- writes once the site has answered -- true OR false, so a nil is "not asked
-- yet" and the page stays shut until every live key has landed. A pass with
-- no id is never asked and never waited on.
local function refreshOwned()
	local owned: { [string]: boolean } = {}
	for _, key in Products.PLUS_PASSES do
		if Products.isLive(Products.pass(key)) then
			local v = player:GetAttribute(Products.PASS_ATTR .. key)
			if v == nil then
				return
			end
			owned[key] = v == true
		end
	end
	page:setState(owned)
end
player.AttributeChanged:Connect(function(name: string)
	if string.sub(name, 1, #Products.PASS_ATTR) == Products.PASS_ATTR then
		refreshOwned()
	end
end)
refreshOwned()

-- THE PRICES, ASKED OF THE SITE (managed pricing varies them by region), one
-- pcall'd call per live pass on a thread of its own so a slow answer never
-- holds the page: until it lands a pill says ROBUX, which is true. Off sale
-- comes back on the same answer and draws the card as SOON.
task.spawn(function()
	for _, e in page.entries do
		local entry = Products.pass(e.key)
		if Products.isLive(entry) then
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo((entry :: any).id, Enum.InfoType.GamePass)
			end)
			if ok and type(info) == "table" then
				page:setPrice(e.key, tonumber(info.PriceInRobux), info.IsForSale ~= false)
			end
		end
	end
end)

-- ================================================================ open/close ==

local open = false
local openToken = 0
local blur: BlurEffect? = nil

-- MADE ON FIRST OPEN and living in Lighting only while this ScreenGui does; a
-- BlurEffect parked in the tree would blur the game for everybody from the
-- moment it booted, whether or not anyone ever pressed the card.
local function ensureBlur(): BlurEffect
	local b = blur
	if b == nil or b.Parent == nil then
		b = Instance.new("BlurEffect")
		local nb = b :: BlurEffect
		nb.Name = "ConquestPlusBlur"
		nb.Size = 0
		nb.Parent = Lighting
		blur = nb
	end
	return blur :: BlurEffect
end

gui.Destroying:Connect(function()
	if blur ~= nil then
		blur:Destroy()
		blur = nil
	end
end)

-- THE PAGE POPS AND THE WORLD DIMS, both off one token so a fast
-- open-close-open cannot leave a stale close holding the scrim hidden: every
-- call takes the next token, and the delayed hide runs only if it still holds
-- the newest one.
local function setOpen(on: boolean)
	if open == on then
		return
	end
	open = on
	openToken += 1
	local token = openToken
	local b = ensureBlur()
	if on then
		scrim.Visible = true
		panel.Visible = true
		-- The cards deal themselves in behind the pop (PassShop's arrival).
		page:setVisible(true)
		-- ...and price their Money pills against a fresh balance.
		ShopRE:FireServer("money")
		-- 94% -> 100% with a little overshoot, a Size tween and not a UIScale
		-- (the lesson card's rule, and the alliance panel's).
		local full = UDim2.fromScale(PANEL_W / REF_W, PANEL_H / REF_H)
		panel.Size = UDim2.fromScale(full.X.Scale * OPEN_FROM, full.Y.Scale * OPEN_FROM)
		TweenService:Create(panel, TweenInfo.new(OPEN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = full }):Play()
		TweenService:Create(scrim, TweenInfo.new(OPEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 1 - SCRIM_ALPHA,
		}):Play()
		TweenService:Create(b, TweenInfo.new(OPEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = BLUR_MAX,
		}):Play()
	else
		-- The page itself goes at once (the alliance panel's close); the
		-- world comes back over the store's short fade, so the dim does not
		-- snap off behind a page that has already gone.
		panel.Visible = false
		page:setVisible(false)
		TweenService:Create(scrim, TweenInfo.new(CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			BackgroundTransparency = 1,
		}):Play()
		TweenService:Create(b, TweenInfo.new(CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = 0,
		}):Play()
		task.delay(CLOSE_TIME, function()
			if token == openToken and not open then
				scrim.Visible = false
			end
		end)
	end
end

closeBtn.Activated:Connect(function()
	Sfx.play("Click")
	setOpen(false)
end)
hoverable(closeBtn, closeBtn.Size)
-- The scrim's own button (see the scrim): a press outside the panel is a
-- close too, with the close button's sound so the two ways out sound alike.
dismiss.Activated:Connect(function()
	Sfx.play("Click")
	setOpen(false)
end)

-- ============================================================= the + card ==
-- The HUD builds the rail during ConquestClient's boot, under
-- PlayerGui.Conquest. Waited for WITH A CEILING: if the rail never comes -- a
-- HUD rebuilt under another name -- this says so once rather than yielding
-- forever with a page nobody can reach.
local function findPlus(): GuiButton?
	local screen = playerGui:WaitForChild("Conquest", 60)
	local rail = screen and screen:WaitForChild("Rail", 60)
	local btn = rail and rail:WaitForChild("Actplus", 60)
	if btn ~= nil and btn:IsA("GuiButton") then
		return btn
	end
	return nil
end

local plusBtn = findPlus()
if plusBtn == nil then
	warn("[PlusTab] the HUD's + card (Conquest.Rail.Actplus) never appeared; the page cannot be opened.")
	gui:Destroy()
	return
end

-- The same Click every other rail card makes on its press: HUD.bindActions
-- plays it for the builds, and skips this one so it can be played here. A
-- toggle, though with the scrim over the rail the card cannot be reached
-- while the page is up -- the X is the way out; this half only matters if a
-- later change lifts the card above the scrim.
plusBtn.Activated:Connect(function()
	Sfx.play("Click")
	setOpen(not open)
end)

-- THE RAIL GOING DOWN TAKES THE PAGE WITH IT. The HUD hides the rail when the
-- round ends or the empire falls (HUD.showActions), and a page left standing
-- over the payout card would be arguing with it -- the button that owns the
-- page is gone, so the page goes too.
local rail = plusBtn.Parent :: GuiObject
rail:GetPropertyChangedSignal("Visible"):Connect(function()
	if not rail.Visible then
		setOpen(false)
	end
end)

gui.Enabled = true
gui.Parent = playerGui
