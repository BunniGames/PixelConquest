--!strict
-- Conquest :: PatternShop  (client, lobby only)
-- The page where a tile pattern is bought and worn.
--
-- THE LADDER IS THE LAYOUT. One COLUMN per tier, worst on the left and best on
-- the right, so the progression is answered by where a thing sits before a
-- single word is read -- and the columns get SHORTER as they get better, which
-- is the second thing the eye picks up. A grid sorted by name, or a scrolling
-- list, would have made "which of these is the good one" a reading task.
--
-- Nothing here decides anything. The server owns what an account owns
-- (ConquestData) and refuses anything it did not authorise; this page checks
-- the same rules locally only so that a refusal is instant instead of a round
-- trip, and so a press that cannot succeed is never sent at all.
--
-- IT DRAWS IN THE LOBBY PAGE'S OWN KIT (`LobbyUI.kit`) rather than a second
-- vocabulary that looks nearly the same: same panel, same stroke, same scrim,
-- same hover and press timings. The dependency is ONE-WAY -- LobbyUI must
-- never require this file back.

local MarketplaceService = game:GetService("MarketplaceService")

local Products = require(script.Parent.Products)
local Palette = require(script.Parent.Palette)
local Patterns = require(script.Parent.Patterns)
local FlagShop = require(script.Parent.FlagShop)
local PassShop = require(script.Parent.PassShop)
local LobbyUI = require(script.Parent.LobbyUI)
local Sfx = require(script.Parent.Sfx)

local kit = LobbyUI.kit
local place, label, chip = kit.place, kit.label, kit.chip
local kitLabel, kitSet, setText = kit.kitLabel, kit.kitSet, kit.setText
local roundOff, pillButton, grower, tween = kit.roundOff, kit.pillButton, kit.grower, kit.tween

local REF_W, REF_H = kit.REF_W, kit.REF_H

local PatternShop = {}
PatternShop.__index = PatternShop

-- ---------------------------------------------------------------- layout ---
-- One screen, no scrolling. Seven tiers x three patterns is twenty-one slots
-- and the catalogue is seventeen, so the whole ladder fits at a size where a
-- swatch is still legible -- and a shop you have to scroll to reach the top of
-- is a shop where the best thing is the thing nobody sees.

local PANEL_W, PANEL_H = 1184, 648
local PANEL_X = (REF_W - PANEL_W) / 2
local PANEL_Y = (REF_H - PANEL_H) / 2

local MARGIN = 24
local COL_GAP = 8
-- ROWS PER COLUMN, and a tier with more patterns than that takes a second
-- column under the SAME heading and rule (2026-09-08: LEGENDARY holds the two
-- Money ornaments and the three Robux skins, five in all -- owner: "i dont
-- want +10% troops to be its own category, i want it to be legendary"). One
-- heading, one rule, one category; just wider. Cards fill DOWN a column and
-- then start the next, the way every other column reads.
local ROWS = 3
local tierCols: { [string]: number } = {}
local COLS = 0
for _, tier in Patterns.TIERS do
	local n = 0
	for _, def in Patterns.LIST do
		if def.tier == tier.key then
			n += 1
		end
	end
	tierCols[tier.key] = math.max(1, math.ceil(n / ROWS))
	COLS += tierCols[tier.key]
end
local COL_W = (PANEL_W - MARGIN * 2 - COL_GAP * (COLS - 1)) / COLS

-- THE TAB STRIP'S PALETTE. Dark ink on the gold chip, because gold is bright
-- enough that the kit's own INK would sit on it as grey mush.
local TAB_ON_INK = Color3.fromRGB(20, 22, 28)
local TAB_OFF_FILL = Color3.fromRGB(38, 43, 56)
local TAB_HOVER_FILL = Color3.fromRGB(55, 62, 78)

local HEAD_Y = 66
local RULE_Y = 88
local CARD_Y0 = 100
-- A card is three lines under its swatch now -- name, an optional green
-- "(+10% ARMY)" for a boosted skin, price -- so the swatch gave up four pixels
-- and the pitch took four more; three rows still end above the message line.
local CARD_PITCH = 152
local CARD_H = 147
local SWATCH = 100

local MSG_Y = 552
local BTN_W, BTN_H = 200, 50
local BTN_Y = 574


-- ---------------------------------------------------------------- arrival --
-- THE SHOP DEALS ITSELF OUT, LEFT TO RIGHT, and the sweep IS the ladder. The
-- starter column is on the table before the eye has found it; the last thing
-- to arrive, after everything else has settled, is the right hand end. The
-- columns already said which end is the good one -- this says it in the one
-- order nobody can read out of turn.
--
-- The weighting is carried by HOW a card lands and by nothing drawn on it: a
-- common card unfolds in a sixth of a second and is simply there, while a
-- legendary comes up from further down, takes three times as long, overshoots
-- its own place, and is lit in its tier colour for a moment as it settles.
-- No card is ever labelled important. They just behave like they weigh more.
local COL_DELAY = 0.055 -- one column to the next
local ROW_DELAY = 0.03 -- down a column, so it falls rather than snaps
local RULE_LEAD = 0.06 -- a tier's colour rule beats its own cards in

local SHADE_ALPHA = 0.35
local OPEN_SHADE = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- The panel lifts as one object and does NOT overshoot: it is the table, and
-- a table that bounces steals the landing from the things being dealt onto it.
local OPEN_PANEL = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local PANEL_FROM = 0.965
local RULE_WIPE = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- The rank at which a landing is worth marking: epic, legendary, earned --
-- the three a player is meant to be playing towards.
local FLASH_RANK = 5
local LAND_FLASH = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- How far a card travels and how long it takes, by tier rank. Rise is squared
-- so the bottom of the ladder stays nearly flat and the top pulls away, and
-- the overshoot only switches on halfway up -- which is where a card stops
-- being furniture and starts being a prize. Read off TIERS rather than a
-- number here, so a new tier is weighted correctly the day it is added.
local function arrival(rank: number): (number, number, TweenInfo)
	local t = (rank - 1) / math.max(1, #Patterns.TIERS - 1)
	local rise = 4 + 22 * t * t
	local dur = 0.16 + 0.26 * t
	local style = t >= 0.45 and Enum.EasingStyle.Back or Enum.EasingStyle.Quad
	return rise, dur, TweenInfo.new(dur, style, Enum.EasingDirection.Out)
end

-- --------------------------------------------------------------- swatches --
-- THE SWATCH MOVED TO `Patterns` (2026-09-17) the day a second caller appeared:
-- the free-rewards plate in LobbyUI previews the skin it is giving away, and
-- two functions compositing the same cosmetic is exactly the drift the rule at
-- the top of Patterns forbids. See Patterns.swatch; the constants and the
-- terrain sample went with it.

-- ----------------------------------------------------------------- money ---

local function comma(n: number): string
	local s = string.format("%.0f", math.max(0, n))
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, -4)
	end
	return s .. out
end

-- ----------------------------------------------------------------- build ---

local function buildCard(self: any, parent: Instance, index: number, def: any, x: number, y: number)
	local card = Instance.new("ImageButton")
	card.Name = "Card_" .. def.key
	card.Image = ""
	card.BackgroundTransparency = 1
	card.BorderSizePixel = 0
	card.AutoButtonColor = false
	place(card, PANEL_W, PANEL_H, x, y, COL_W, CARD_H)
	card.Parent = parent

	local swatch = Instance.new("ImageLabel")
	swatch.Name = "Swatch"
	swatch.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
	swatch.BorderSizePixel = 0
	swatch.ResampleMode = Enum.ResamplerMode.Pixelated
	-- FIT, NOT STRETCH -- see the constraint below. Fit is the second of the
	-- two guards: it letterboxes the (square) image inside whatever box it is
	-- given rather than distorting it, so even a window shape extreme enough to
	-- defeat the constraint cannot make a checker come out as a rectangle.
	swatch.ScaleType = Enum.ScaleType.Fit
	swatch.Active = false
	place(swatch, COL_W, CARD_H, (COL_W - SWATCH) / 2, 0, SWATCH, SWATCH)
	-- Centred in its slot from the middle, because the constraint below takes
	-- the width away from a corner-anchored box and would leave it hard left.
	swatch.AnchorPoint = Vector2.new(0.5, 0)
	swatch.Position = UDim2.fromScale(0.5, 0)
	swatch.Parent = card
	roundOff(swatch, 8)
	-- SQUARE, WHATEVER SHAPE THE WINDOW IS. This page authors in Scale against
	-- a 16:9 reference, like the lobby page whose kit it borrows, so on a
	-- letterboxed or windowed client every box is stretched by the same amount.
	-- That is fine for a card and NOT fine for this one: the geometry inside it
	-- IS the product, and a stretched checker is not a checker. Height is the
	-- dominant axis because the error runs the safe way -- a window wider than
	-- the reference shrinks the swatch inside its own column rather than
	-- growing it into the neighbouring one.
	local square = Instance.new("UIAspectRatioConstraint")
	square.AspectRatio = 1
	square.DominantAxis = Enum.DominantAxis.Height
	square.Parent = swatch
	-- The starter entry has no grid at all, and the flat fill IS what it
	-- previews: what your territory looks like with nothing on it.
	swatch.ImageContent = Content.fromObject(Patterns.swatch(index))

	local stroke = Instance.new("UIStroke")
	stroke.Color = kit.LINE
	stroke.Thickness = 1.6
	stroke.Transparency = 0.4
	stroke.Parent = swatch

	local name = label(card, "Name", COL_W, CARD_H, 0, SWATCH + 6, COL_W, 15, kit.INK, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	setText(name, string.upper(def.name))
	-- WHAT IT DOES, between the name and the price, and only on a card that
	-- does something: green because that is what green means on this page
	-- (gain), and a line of nothing on every other card so the prices in a
	-- row still sit on one baseline.
	local perk = Patterns.perkText(def)
	if perk ~= nil then
		local boost = label(card, "Boost", COL_W, CARD_H, 0, SWATCH + 22, COL_W, 11, kit.GAIN, Enum.TextXAlignment.Center, kit.FONT_BOLD)
		setText(boost, perk)
	end
	local state = label(card, "State", COL_W, CARD_H, 0, SWATCH + 34, COL_W, 13, kit.INK_OFF)

	local scale = grower(card)
	local entry = {
		def = def,
		index = index,
		card = card,
		swatch = swatch,
		stroke = stroke,
		name = name,
		state = state,
		scale = scale,
		hover = false,
		-- READ ONLY BY THE OPENING SWEEP. `home` is the centred position
		-- `grower` just converted this card to, kept because the card is
		-- tweened up to it from below; `rank` is how far up the ladder its
		-- tier sits, which is the whole of the weighting.
		home = card.Position,
		rank = Patterns.tierRank(def.tier),
	}

	card.MouseEnter:Connect(function()
		entry.hover = true
		tween(scale, kit.HOVER_IN, { Scale = kit.HOVER_SCALE })
		tween(stroke, kit.HOVER_IN, { Transparency = 0 })
	end)
	card.MouseLeave:Connect(function()
		entry.hover = false
		tween(scale, kit.HOVER_OUT, { Scale = 1 })
		PatternShop.paintCard(self, entry)
	end)
	card.MouseButton1Down:Connect(function()
		tween(scale, kit.PRESS_IN, { Scale = kit.PRESS_SCALE })
	end)
	card.MouseButton1Up:Connect(function()
		tween(scale, kit.PRESS_OUT, { Scale = entry.hover and kit.HOVER_SCALE or 1 })
	end)
	card.Activated:Connect(function()
		PatternShop.press(self, entry)
	end)
	return entry
end

function PatternShop.new(parent: Instance): any
	local self = setmetatable({}, PatternShop)
	-- Nothing is known until the server says so, and "not known" is drawn as
	-- a shut shop rather than as an empty one: a page that showed everything
	-- unowned while a profile was still loading would offer to sell somebody
	-- what they already had.
	self.known = false
	self.owned = {} :: { [string]: boolean }
	self.equipped = Patterns.DEFAULT_KEY
	self.wins = 0
	self.money = 0
	-- ROBUX (2026-09-08). `money2x` is the one unlock this page draws a
	-- control for; `prices` is what the site said each live product costs,
	-- keyed by product key, and absent until it has answered. A press on any
	-- of it goes out through `onRobux` to the purchase prompt -- the page
	-- never charges anything itself.
	self.money2x = false
	self.prices = {} :: { [string]: number }
	self.onRobux = nil :: ((string) -> ())?
	self.onIntent = nil :: ((string, string) -> ())?
	-- A GAME PASS, which is a different remote verb from a developer product
	-- (2026-09-15). `onRobux` goes up the Shop remote's `buy`, which is
	-- PromptProductPurchase; a pass has to go up `pass` to PromptGamePassPurchase
	-- or nothing happens at all. The VIP pattern is the only card that uses it.
	self.onPass = nil :: ((string) -> ())?
	-- ...and a pass paid in MONEY (2026-09-22): the pass page's second pill,
	-- forwarded the same way, to a verb of its own on the same remote.
	self.onMoneyPass = nil :: ((string) -> ())?
	self.entries = {}
	-- The tier rules, kept so they can wipe in ahead of their own columns.
	self.rules = {}
	-- EVERY DELAYED ARRIVAL BELONGS TO THE OPEN THAT SCHEDULED IT. A page shut
	-- and reopened inside a second would otherwise land two sweeps on top of
	-- each other, and the older one would finish by setting cards it no longer
	-- owns back to full size.
	self.openGen = 0

	local shade = Instance.new("Frame")
	shade.Name = "PatternShade"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(4, 6, 11)
	shade.BackgroundTransparency = 0.35
	shade.BorderSizePixel = 0
	-- Eats every click that misses the panel, so the board underneath cannot
	-- be pressed through a page that is covering it.
	shade.Active = true
	shade.Visible = false
	shade.ZIndex = 20
	shade.Parent = parent
	self.shade = shade

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.BackgroundColor3 = kit.PANEL
	panel.BackgroundTransparency = 0.02
	panel.BorderSizePixel = 0
	place(panel, REF_W, REF_H, PANEL_X, PANEL_Y, PANEL_W, PANEL_H)
	panel.Parent = shade
	roundOff(panel, 12)
	-- The panel is scaled as a whole on open, so everything on it -- title,
	-- balance, the pills along the bottom -- arrives with it and only the
	-- cards have a sweep of their own.
	self.panelScale = grower(panel)
	local ps = Instance.new("UIStroke")
	ps.Color = kit.LINE
	ps.Thickness = 1.6
	ps.Transparency = 0.25
	ps.Parent = panel
	local scrim = Instance.new("ImageLabel")
	scrim.Name = "Scrim"
	scrim.BackgroundTransparency = 1
	scrim.Image = kit.SCRIM
	scrim.ScaleType = Enum.ScaleType.Stretch
	scrim.ImageTransparency = 0.3
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = panel
	roundOff(scrim, 12)

	-- THE TABS WHERE THE TITLE USED TO BE (2026-09-15). This page was headed
	-- "PATTERNS" in the kit face; with a second tab under the same panel that
	-- heading says exactly what the tabs say, so the tabs ARE the heading. One
	-- is always lit, which is the only job the title was doing. A third,
	-- GAMEPASSES, joined 2026-09-21 (owner: "a 3rd tab that says gamepasses").
	self.tabs = {}
	self.tab = "patterns"
	local TAB_SPECS = {
		{ id = "patterns", text = "PATTERNS" },
		{ id = "flags", text = "FLAGS" },
		{ id = "passes", text = "GAMEPASSES" },
	}
	local TAB_W, TAB_H, TAB_GAP = 190, 36, 12
	local tabX = (PANEL_W - (TAB_W * #TAB_SPECS + TAB_GAP * (#TAB_SPECS - 1))) / 2
	-- NOT `pillButton`. That one owns its own hover paint -- it tweens the
	-- background and the caption back to its defaults on mouse-out -- so a tab
	-- painted to say "this one is live" lost that the first time a cursor
	-- crossed it. These carry their own paint, which paintTabs owns outright.
	for i, spec in TAB_SPECS do
		local b = Instance.new("ImageButton")
		b.Name = "Tab_" .. spec.id
		b.Image = ""
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.BackgroundColor3 = TAB_OFF_FILL
		place(b, PANEL_W, PANEL_H, tabX + (i - 1) * (TAB_W + TAB_GAP), 14, TAB_W, TAB_H)
		b.Parent = panel
		roundOff(b, 10)
		local st = Instance.new("UIStroke")
		st.Thickness = 1.8
		st.Color = kit.LINE
		st.Parent = b
		local cap = label(b, "Caption", TAB_W, TAB_H, 0, (TAB_H - 20) / 2, TAB_W, 20, kit.INK, Enum.TextXAlignment.Center, kit.FONT_BOLD)
		setText(cap, spec.text)
		local sc = grower(b)
		local t = { id = spec.id, button = b, caption = cap, stroke = st, scale = sc, hover = false }
		b.MouseEnter:Connect(function()
			t.hover = true
			tween(sc, kit.HOVER_IN, { Scale = kit.HOVER_SCALE })
			PatternShop.paintTabs(self)
		end)
		b.MouseLeave:Connect(function()
			t.hover = false
			tween(sc, kit.HOVER_OUT, { Scale = 1 })
			PatternShop.paintTabs(self)
		end)
		b.MouseButton1Down:Connect(function()
			tween(sc, kit.PRESS_IN, { Scale = kit.PRESS_SCALE })
		end)
		b.MouseButton1Up:Connect(function()
			tween(sc, kit.PRESS_OUT, { Scale = t.hover and kit.HOVER_SCALE or 1 })
		end)
		b.Activated:Connect(function()
			PatternShop.setTab(self, spec.id)
		end)
		table.insert(self.tabs, t)
	end

	-- THE PATTERN LADDER'S OWN PAGE, exactly the size of the panel -- so every
	-- coordinate the columns below are authored in still means what it meant
	-- when they were parented straight to the panel. A container with its own
	-- rectangle would have silently moved seventeen cards.
	local patternsPage = Instance.new("Frame")
	patternsPage.Name = "PatternsPage"
	patternsPage.BackgroundTransparency = 1
	patternsPage.BorderSizePixel = 0
	patternsPage.Size = UDim2.fromScale(1, 1)
	patternsPage.Parent = panel
	self.patternsPage = patternsPage

	self.moneyCap = label(panel, "MoneyCap", PANEL_W, PANEL_H, PANEL_W - MARGIN - 180, 16, 180, 11, kit.INK_OFF, Enum.TextXAlignment.Right)
	setText(self.moneyCap, "MONEY")
	self.moneyText = label(panel, "Money", PANEL_W, PANEL_H, PANEL_W - MARGIN - 180, 30, 180, 22, kit.GOLD, Enum.TextXAlignment.Right)

	-- One column per tier, in catalogue order, which IS the ladder -- or two
	-- for a tier that outgrew one; see ROWS.
	local x = MARGIN
	-- WHICH COLUMN THIS IS, counted across the whole page rather than within
	-- a tier, because the sweep is a sweep across the page -- a tier that
	-- takes two columns takes two beats of it.
	local colBase = 0
	for _, tier in Patterns.TIERS do
		local span = tierCols[tier.key]
		local w = span * COL_W + (span - 1) * COL_GAP
		local head = label(patternsPage, "Tier" .. tier.key, PANEL_W, PANEL_H, x, HEAD_Y, w, 15, tier.color, Enum.TextXAlignment.Center, kit.FONT_BOLD)
		setText(head, tier.name)
		-- The rule under a heading is the tier's colour at full strength --
		-- seven of them side by side are the ladder, and they are read as a
		-- row of colours long before any of the words are.
		-- WIPED IN FROM ITS LEFT EDGE on open, one beat ahead of its own
		-- cards, so the row of tier colours draws itself across the page in
		-- ladder order before a single card can be pressed. `full` is the
		-- authored width, kept because the wipe starts from nothing.
		local rule = chip(patternsPage, "Rule" .. tier.key, PANEL_W, PANEL_H, x, RULE_Y, w, 3, tier.color, 0.15)
		table.insert(self.rules, { chip = rule, head = head, col = colBase, full = rule.Size })

		local slot = 0
		for index, def in Patterns.LIST do
			if def.tier == tier.key then
				local col, row = slot // ROWS, slot % ROWS
				local entry = buildCard(self, patternsPage, index, def, x + col * (COL_W + COL_GAP), CARD_Y0 + row * CARD_PITCH)
				entry.col, entry.row = colBase + col, row
				table.insert(self.entries, entry)
				slot += 1
			end
		end
		x += w + COL_GAP
		colBase += span
	end

	-- THE FLAGS PAGE, in the rectangle the pattern columns occupy, so switching
	-- tab does not change the shape of anything around it.
	local flags = FlagShop.new(panel, PANEL_W, PANEL_H, MARGIN, HEAD_Y, PANEL_W - MARGIN * 2, MSG_Y - HEAD_Y - 10)
	self.flags = flags
	-- Forwarded rather than handed the caller's function directly, because
	-- LobbyClient assigns these AFTER this constructor has run.
	flags.onIntent = function(verb: string, id: string)
		local fn = self.onFlagIntent
		if fn then
			fn(verb, id)
		end
	end
	flags.onRobux = function(key: string)
		local fn = self.onRobux
		if fn then
			fn(key)
		end
	end
	flags.onSay = function(text: string)
		PatternShop.say(self, text)
	end

	-- THE GAMEPASSES PAGE (2026-09-21), in the same rectangle as the flags,
	-- for the same reason. A press goes up `onPass` -- the pass verb, never
	-- the product one -- exactly the way the VIP pattern card's does.
	local passes = PassShop.new(panel, PANEL_W, PANEL_H, MARGIN, HEAD_Y, PANEL_W - MARGIN * 2, MSG_Y - HEAD_Y - 10)
	self.passes = passes
	passes.onPass = function(key: string)
		local fn = self.onPass
		if fn then
			fn(key)
		end
	end
	passes.onMoney = function(key: string)
		local fn = self.onMoneyPass
		if fn then
			fn(key)
		end
	end
	passes.onSay = function(text: string)
		PatternShop.say(self, text)
	end

	-- The one line this page ever says out loud, and only when a press could
	-- not go through. Everything else is on the cards.
	self.message = label(panel, "Message", PANEL_W, PANEL_H, MARGIN, MSG_Y, PANEL_W - MARGIN * 2, 15, kit.GOLD)
	self.messageUntil = 0

	local close = pillButton(panel, "Close", PANEL_W, PANEL_H, (PANEL_W - BTN_W) / 2, BTN_Y, BTN_W, BTN_H, "DONE")
	close.Activated:Connect(function()
		PatternShop.close(self)
	end)

	-- 2x MONEY, bottom-left of the same row as DONE (2026-09-08). Hidden until
	-- the product has an id; once owned it says so instead of pricing itself,
	-- because a price on a thing you have already bought is an invitation to
	-- buy it twice.
	local boost = pillButton(panel, "Money2x", PANEL_W, PANEL_H, MARGIN, BTN_Y, 300, BTN_H, "2x MONEY")
	boost.Visible = false
	self.money2xButton = boost
	self.money2xCaption = boost:FindFirstChild("Caption") :: TextLabel
	boost.Activated:Connect(function()
		PatternShop.pressMoney2x(self)
	end)

	-- THE PRICES, ASKED OF THE SITE rather than read off the catalogue, because
	-- managed pricing varies them by region. One call per live product,
	-- spawned and pcall'd, so a slow or absent answer never holds the page:
	-- until it lands a card says ROBUX, which is true.
	task.spawn(function()
		local want = { "MONEY2X", "FLAG" }
		for _, def in Patterns.LIST do
			if def.product ~= nil then
				table.insert(want, def.product)
			end
		end
		local any = false
		for _, key in want do
			local entry = Products.product(key)
			if Products.isLive(entry) then
				local ok, info = pcall(function()
					return MarketplaceService:GetProductInfo((entry :: any).id, Enum.InfoType.Product)
				end)
				if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
					self.prices[key] = tonumber(info.PriceInRobux) :: number
					any = true
				end
			end
		end
		if any then
			PatternShop.repaint(self)
			-- The flag tab prices off the same fetch; it draws ROBUX until it
			-- lands and R$ n after, exactly like a skin card.
			local fp = self.prices["FLAG"]
			if fp then
				FlagShop.setPrice(self.flags, "FLAG", fp)
			end
		end
		-- THE PASSES, asked of the site the same way, with the GamePass
		-- InfoType -- a pass is not a product and the product lookup fails
		-- on it. Each lands on its own card as it answers. OFF SALE is read
		-- off the same answer (2026-09-22): the card says SOON and refuses
		-- the press, rather than opening a prompt the site will only
		-- apologise for.
		for _, e in self.passes.entries do
			local entry = Products.pass(e.key)
			if Products.isLive(entry) then
				local ok, info = pcall(function()
					return MarketplaceService:GetProductInfo((entry :: any).id, Enum.InfoType.GamePass)
				end)
				if ok and type(info) == "table" then
					PassShop.setPrice(self.passes, e.key, tonumber(info.PriceInRobux), info.IsForSale ~= false)
				end
			end
		end
	end)

	PatternShop.paintTabs(self)
	PatternShop.repaint(self)
	return self
end

-- ----------------------------------------------------------------- paint ---

function PatternShop.paintCard(self: any, entry: any)
	local def = entry.def
	local st = Patterns.standing(def, self.owned, self.money, self.wins)
	local worn = self.known and st.owned and self.equipped == def.key

	if worn then
		entry.stroke.Color = kit.GOLD
		entry.stroke.Thickness = 2.6
		entry.stroke.Transparency = 0
		setText(entry.state, "WEARING")
		entry.state.TextColor3 = kit.GOLD
		entry.swatch.ImageTransparency = 0
		entry.name.TextColor3 = kit.INK
	elseif not self.known then
		entry.stroke.Color = kit.LINE
		entry.stroke.Thickness = 1.6
		entry.stroke.Transparency = 0.4
		setText(entry.state, "")
		entry.swatch.ImageTransparency = 0.45
		entry.name.TextColor3 = kit.INK_OFF
	elseif st.owned then
		entry.stroke.Color = kit.LINE
		entry.stroke.Thickness = 1.6
		entry.stroke.Transparency = 0.15
		setText(entry.state, "EQUIP")
		entry.state.TextColor3 = kit.INK_DIM
		entry.swatch.ImageTransparency = 0
		entry.name.TextColor3 = kit.INK
	elseif st.winsShort then
		-- LOCKED, AND STILL DRAWN. The swatch is what the wins are for, and a
		-- padlock over a blank square is not a reason to keep playing.
		entry.stroke.Color = kit.LINE
		entry.stroke.Thickness = 1.6
		entry.stroke.Transparency = 0.55
		setText(entry.state, st.winsShort == 1 and "1 MORE WIN" or (st.winsShort .. " MORE WINS"))
		entry.state.TextColor3 = Patterns.tier(def.tier).color
		entry.swatch.ImageTransparency = 0.45
		entry.name.TextColor3 = kit.INK_OFF
	elseif def.wins ~= nil then
		-- Earned and unlocked, but not claimed yet.
		entry.stroke.Color = Patterns.tier(def.tier).color
		entry.stroke.Thickness = 2.2
		entry.stroke.Transparency = 0
		setText(entry.state, "CLAIM")
		entry.state.TextColor3 = kit.GAIN
		entry.swatch.ImageTransparency = 0
		entry.name.TextColor3 = kit.INK
	elseif st.reward then
		-- THE FREE REWARDS SKIN. Not for sale at any price and not earned by
		-- winning either, so it names its door instead of a number -- the same
		-- thing the VIP card below does for the pass.
		--
		-- FULL-OPACITY SWATCH even unowned, like the VIP card: what it looks
		-- like IS the pitch, and the thing it is pitching is free.
		entry.stroke.Color = kit.LINE
		entry.stroke.Thickness = 1.6
		entry.stroke.Transparency = 0.4
		setText(entry.state, "FREE REWARDS")
		entry.state.TextColor3 = kit.GAIN
		entry.swatch.ImageTransparency = 0
		entry.name.TextColor3 = kit.INK
	elseif st.vip then
		-- COMES WITH THE PASS. An owner never reaches this branch: the grant
		-- writes the pattern into the profile, so they arrive at `st.owned`
		-- above and the card reads EQUIP like anything else they own. This is
		-- the card a NON-owner sees, and it names the pass instead of a price
		-- because there is no price to name -- VIP is bought whole or not at
		-- all, and the figure belongs on the purchase prompt the site draws.
		--
		-- FULL-OPACITY SWATCH, unlike the locked earned tier: what the pattern
		-- actually looks like IS the pitch here.
		local live = Products.isLive(Products.pass("VIP"))
		local tint = Patterns.tier(def.tier).color
		entry.stroke.Color = live and tint or kit.LINE
		entry.stroke.Thickness = live and 2.2 or 1.6
		entry.stroke.Transparency = live and 0.1 or 0.55
		setText(entry.state, live and "VIP" or "SOON")
		entry.state.TextColor3 = live and kit.GOLD or kit.INK_OFF
		entry.swatch.ImageTransparency = live and 0 or 0.45
		entry.name.TextColor3 = live and kit.INK or kit.INK_OFF
	elseif st.robux then
		-- ROBUX, NOT MONEY. The price is the site's, fetched once, and printed
		-- in gold -- the readout colour, not the green a Money price turns when
		-- it is within reach, because "can I afford this" is not a question the
		-- balance answers here. Before it lands the card says what it is rather
		-- than a number it cannot vouch for. SOON is a product with no id yet --
		-- drawn, dimmed, unpressable.
		local live = Products.isLive(Products.product(def.product))
		local tint = Patterns.tier(def.tier).color
		entry.stroke.Color = live and tint or kit.LINE
		entry.stroke.Thickness = live and 2.2 or 1.6
		entry.stroke.Transparency = live and 0.1 or 0.55
		local price = self.prices[def.product]
		setText(entry.state, live and (price and ("R$ " .. price) or "ROBUX") or "SOON")
		entry.state.TextColor3 = live and kit.GOLD or kit.INK_OFF
		entry.swatch.ImageTransparency = live and 0 or 0.45
		entry.name.TextColor3 = live and kit.INK or kit.INK_OFF
	else
		entry.stroke.Color = kit.LINE
		entry.stroke.Thickness = 1.6
		entry.stroke.Transparency = st.affordable and 0.25 or 0.55
		setText(entry.state, comma(st.price))
		-- The price is the whole affordability read: green when it is within
		-- reach, grey when it is not. Nothing else on the card changes, so a
		-- pattern you cannot afford yet still shows you what it looks like.
		entry.state.TextColor3 = st.affordable and kit.GAIN or kit.INK_OFF
		entry.swatch.ImageTransparency = st.affordable and 0 or 0.45
		entry.name.TextColor3 = st.affordable and kit.INK or kit.INK_OFF
	end
end

function PatternShop.repaint(self: any)
	for _, entry in self.entries do
		PatternShop.paintCard(self, entry)
	end
	setText(self.moneyText, self.known and comma(self.money) or "")
	self.moneyCap.Visible = self.known
	-- The 2x MONEY pill: only once the profile is known, and only when there
	-- is something to press for -- a live product, or an owned one to report.
	if self.money2xButton then
		local live = Products.isLive(Products.product("MONEY2X"))
		self.money2xButton.Visible = self.known and (live or self.money2x)
		if self.money2x then
			setText(self.money2xCaption, "2x MONEY   OWNED")
		else
			local price = self.prices["MONEY2X"]
			setText(self.money2xCaption, price and ("2x MONEY   R$ " .. price) or "2x MONEY")
		end
	end
end

function PatternShop.pressMoney2x(self: any)
	if not self.known then
		Sfx.play("Deny")
		PatternShop.say(self, "YOUR PROFILE HAS NOT LOADED YET.")
		return
	end
	if self.money2x then
		Sfx.play("Click")
		PatternShop.say(self, "EVERY ROUND ALREADY PAYS YOU DOUBLE.")
		return
	end
	if not Products.isLive(Products.product("MONEY2X")) then
		Sfx.play("Deny")
		return
	end
	-- The site's prompt does the rest. The pill changes when the receipt
	-- lands and the profile comes back saying so.
	Sfx.play("Coin")
	if self.onRobux then
		self.onRobux("MONEY2X")
	end
end

function PatternShop.say(self: any, text: string)
	setText(self.message, text)
	self.messageUntil = os.clock() + 5
end

-- ---------------------------------------------------------------- presses --

function PatternShop.press(self: any, entry: any)
	local def = entry.def
	if not self.known then
		Sfx.play("Deny")
		PatternShop.say(self, "YOUR PROFILE HAS NOT LOADED YET.")
		return
	end
	local st = Patterns.standing(def, self.owned, self.money, self.wins)

	if st.owned then
		if self.equipped == def.key then
			return
		end
		-- PAINTED FIRST, THEN SENT, the same way the lobby's cards are:
		-- equipping is free and cannot be refused for anything except
		-- ownership, which was just checked, so waiting for the round trip
		-- would only make the page feel slow.
		self.equipped = def.key
		PatternShop.repaint(self)
		Sfx.play("Click")
		if self.onIntent then
			self.onIntent("equip", def.key)
		end
		return
	end

	if def.wins ~= nil then
		if st.winsShort then
			Sfx.play("Deny")
			PatternShop.say(self, string.format(
				"%s IS EARNED, NOT BOUGHT -- %d MORE %s.",
				string.upper(def.name),
				st.winsShort,
				st.winsShort == 1 and "WIN" or "WINS"
			))
			return
		end
		Sfx.play("Cheer")
		if self.onIntent then
			self.onIntent("buy", def.key)
		end
		return
	end

	if st.reward then
		-- There is no purchase to make here at all: the sheet in the lobby is
		-- the only door. Said out loud rather than silently refused, because a
		-- card that looks pressable and does nothing reads as broken.
		Sfx.play("Deny")
		PatternShop.say(self, string.upper(def.name) .. " COMES FROM FREE REWARDS.")
		return
	end

	if st.vip then
		-- THE PASS, NOT A PATTERN PURCHASE. It goes up the Shop remote's `pass`
		-- verb (ConquestShop -> promptPass), never `buy`: that one is
		-- PromptProductPurchase, and a game pass is not a developer product, so
		-- the wrong verb here prompts nothing whatsoever.
		if not Products.isLive(Products.pass("VIP")) then
			Sfx.play("Deny")
			PatternShop.say(self, string.upper(def.name) .. " IS NOT ON SALE YET.")
			return
		end
		-- Not painted optimistically, for the same reason the Robux branch is
		-- not: the site decides, and the card flips to EQUIP when the grant has
		-- landed and the profile has come back saying so.
		Sfx.play("Coin")
		if self.onPass then
			self.onPass("VIP")
		end
		return
	end

	if st.robux then
		if not Products.isLive(Products.product(def.product)) then
			Sfx.play("Deny")
			PatternShop.say(self, string.upper(def.name) .. " IS NOT ON SALE YET.")
			return
		end
		-- Not painted optimistically, for the same reason a Money buy is not:
		-- the site decides. The card flips when the receipt has landed and
		-- the profile has come back saying so.
		Sfx.play("Coin")
		if self.onRobux then
			self.onRobux(def.product)
		end
		return
	end

	if not st.affordable then
		Sfx.play("Deny")
		PatternShop.say(self, string.format(
			"%s COSTS %s -- YOU ARE %s SHORT.",
			string.upper(def.name),
			comma(st.price),
			comma(st.price - self.money)
		))
		return
	end

	-- NOT PAINTED OPTIMISTICALLY, unlike an equip: this one spends money, and
	-- the balance is the server's to move. The card changes when the profile
	-- comes back saying it did.
	Sfx.play("Coin")
	if self.onIntent then
		self.onIntent("buy", def.key)
	end
end

-- ------------------------------------------------------------------ state --

-- Everything the server knows about this account's cosmetics, in one call --
-- which is also what flips the page from "shut" to "open for business".
function PatternShop.setState(self: any, owned: any, equipped: any, wins: any, money2x: any?)
	self.owned = type(owned) == "table" and owned or {}
	self.equipped = type(equipped) == "string" and equipped or Patterns.DEFAULT_KEY
	self.wins = tonumber(wins) or 0
	self.money2x = money2x == true
	self.known = true
	PatternShop.repaint(self)
end

function PatternShop.setMoney(self: any, amount: any)
	self.money = tonumber(amount) or 0
	-- The pass page prices its Money pills against the same balance.
	if self.passes then
		PassShop.setMoney(self.passes, self.money)
	end
	PatternShop.repaint(self)
end

-- A CARD LIT IN ITS OWN TIER'S COLOUR AS IT LANDS, fading back to whatever the
-- paint says it should be. Painted FIRST, so the values it fades back to are
-- the real ones rather than a guess -- and so a repaint arriving mid-flash (a
-- Robux price landing, a hover) simply wins, which is the right way round for
-- a flourish that is over in half a second.
local function landFlash(self: any, entry: any)
	PatternShop.paintCard(self, entry)
	local s = entry.stroke
	local color, thick, clear = s.Color, s.Thickness, s.Transparency
	s.Color = Patterns.tier(entry.def.tier).color
	s.Thickness = thick + 2.4
	s.Transparency = 0
	tween(s, LAND_FLASH, { Color = color, Thickness = thick, Transparency = clear })
end

function PatternShop.open(self: any)
	setText(self.message, "")
	-- ALWAYS OPENS ON PATTERNS. The sweep below deals the pattern ladder out,
	-- and a shop that reopened onto the flag tab would run that sweep against a
	-- hidden page -- and would also hide the ladder from somebody who had
	-- browsed flags once and never gone back.
	self.tab = "patterns"
	PatternShop.paintTabs(self)
	self.openGen += 1
	local gen = self.openGen

	-- EVERYTHING SET TO ITS "NOT HERE YET" STATE BEFORE THE PAGE IS SHOWN, so
	-- no frame of the finished layout is ever on screen first.
	self.shade.BackgroundTransparency = 1
	self.panelScale.Scale = PANEL_FROM
	for _, rule in self.rules do
		rule.chip.Size = UDim2.fromScale(0, rule.full.Y.Scale)
		rule.head.TextTransparency = 1
	end
	for _, entry in self.entries do
		-- Nothing is drawn at zero scale, so a card genuinely is not there
		-- until its turn -- which is what makes the sweep read as an order
		-- rather than as seventeen things wobbling at once.
		entry.scale.Scale = 0
		local rise = arrival(entry.rank)
		entry.card.Position = entry.home + UDim2.fromScale(0, rise / PANEL_H)
	end

	self.shade.Visible = true
	tween(self.shade, OPEN_SHADE, { BackgroundTransparency = SHADE_ALPHA })
	tween(self.panelScale, OPEN_PANEL, { Scale = 1 })

	for _, rule in self.rules do
		task.delay(rule.col * COL_DELAY, function()
			if self.openGen ~= gen then
				return
			end
			tween(rule.chip, RULE_WIPE, { Size = rule.full })
			tween(rule.head, RULE_WIPE, { TextTransparency = 0 })
		end)
	end

	for _, entry in self.entries do
		local _, dur, info = arrival(entry.rank)
		task.delay(RULE_LEAD + entry.col * COL_DELAY + entry.row * ROW_DELAY, function()
			if self.openGen ~= gen then
				return
			end
			tween(entry.scale, info, { Scale = 1 })
			tween(entry.card, info, { Position = entry.home })
			if entry.rank >= FLASH_RANK then
				-- Halfway through the travel, so the colour is already up as
				-- the card arrives instead of blinking on after it has stopped.
				task.delay(dur * 0.45, function()
					if self.openGen == gen and self.shade.Visible then
						landFlash(self, entry)
					end
				end)
			end
		end)
	end
end

-- WHICH TAB IS LIT. One page is visible at a time and only the visible one's
-- button is drawn at full strength -- a strip where both look the same is two
-- buttons, not a tab strip.
function PatternShop.setTab(self: any, id: string)
	if self.tab == id then
		return
	end
	self.tab = id
	Sfx.play("Click")
	PatternShop.paintTabs(self)
end

function PatternShop.paintTabs(self: any)
	for _, t in self.tabs do
		local on = t.id == self.tab
		-- COLOUR IS WHAT SAYS "PRESS ME". Both tabs used to be the panel's own
		-- fill and differed only in how bright the caption was, which reads as
		-- one heading plus one dimmed heading rather than as two buttons. The
		-- live tab is a filled gold chip with dark ink on it; the other is a
		-- raised slab with a lit edge, and it BRIGHTENS under the cursor, so
		-- the thing you are about to click always answers back.
		t.button.BackgroundColor3 = if on then kit.GOLD elseif t.hover then TAB_HOVER_FILL else TAB_OFF_FILL
		t.button.BackgroundTransparency = 0
		if t.stroke then
			t.stroke.Color = if on then kit.GOLD elseif t.hover then kit.INK_DIM else kit.LINE
			t.stroke.Transparency = if on then 0 elseif t.hover then 0.1 else 0.35
		end
		if t.caption then
			t.caption.TextColor3 = if on then TAB_ON_INK elseif t.hover then Color3.new(1, 1, 1) else kit.INK
		end
	end
	self.patternsPage.Visible = self.tab == "patterns"
	FlagShop.setVisible(self.flags, self.tab == "flags")
	PassShop.setVisible(self.passes, self.tab == "passes")
end

-- The flag tab's state, straight off the server, on the same contract as
-- setState: the page never guesses at what an account owns.
function PatternShop.setFlagState(self: any, owned: any, equipped: any, tokens: any)
	FlagShop.setState(self.flags, owned, equipped, tokens)
end

-- The gamepasses tab's state, on the same contract: which passes this account
-- holds, by key, straight off the server.
function PatternShop.setPassState(self: any, owned: any)
	PassShop.setState(self.passes, owned)
end

function PatternShop.close(self: any)
	self.shade.Visible = false
	-- The pass page's clip drawer stops with the shop: a clip stepping
	-- under a hidden shade would be a frame loop for nobody (2026-09-22).
	PassShop.setVisible(self.passes, false)
end

function PatternShop.isOpen(self: any): boolean
	return self.shade.Visible
end

function PatternShop.step(self: any)
	if self.messageUntil > 0 and os.clock() > self.messageUntil then
		self.messageUntil = 0
		setText(self.message, "")
	end
end

return PatternShop
