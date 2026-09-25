--!strict
-- Conquest :: PassShop  (client)
-- The pass cards: the lobby shop's GAMEPASSES tab, and the in-game "+" card's
-- page (PlusTabClient), which draws the same cards at its own size.
--
-- IT IS A PAGE, NOT A PANEL, on exactly FlagShop's contract. Whoever owns the
-- window -- PatternShop's panel, the extra-buildings panel -- hands over a
-- rectangle, and this owns that rectangle and nothing else. Same kit
-- (`LobbyUI.kit`), same one-way dependency: this requires the kit's source,
-- never a page.
--
-- HORIZONTAL ROWS (owner, 2026-09-22: "I want them to be completely
-- horizontal cards"). One row per pass, full width: the header chip on the
-- left -- gold with the owner's crown on VIP, the slab on the rest -- the
-- perk list across the middle in columns of three, the price pills on the
-- right. The lines are the catalogue's own (Products.perks), never a second
-- copy that would drift.
--
-- TWO WAYS TO PAY (owner, 2026-09-22: "make it two buttons, one to buy it
-- with robux with a gamepass, players can also buy it with the currency
-- Money that they earn"). Two pills stacked at the row's end: ROBUX above,
-- gold, the site's price, the prompt; MONEY below, the slab with a green
-- edge, the catalogue's price (Products.moneyPrice), settled by the server
-- on the spot. The Money pill reads its affordability off the balance the
-- page is told (setMoney): green within reach, grey short, plain ink until
-- the balance has arrived. Owned, the Robux pill says so alone and the Money
-- pill goes; a pass with no Money price never draws one.
--
-- TALL ROWS ON A SCROLLING SHEET (owner, 2026-09-22: "make the height 2x for
-- each card. also add space between each card"). A row is ROW_H, twice what
-- five rows were squeezed to when they all had to fit the lobby panel, with
-- ROW_GAP of clear panel between rows. Five of those no longer fit the
-- rectangle, and they are not meant to: the page is a ScrollingFrame, the
-- rows a sheet inside it, and the wheel or a finger brings the rest up.
--
-- THE CLIP LIVES INSIDE ITS OWN CARD (owner, 2026-09-22: "when example shows
-- up, it looks awkward overlapping with 2 cards"). The drawer used to be a
-- separate slab tucked under a row's edge and pushed over the row below, so
-- it read as a third thing wedged between two cards. Now the CARD ITSELF
-- grows: on hover its bottom edge slides down by CLIP_H and reveals the clip
-- window drawn inside its own border, and the rows beneath slide down with
-- it by the same amount (owner: "when i open up an animation, the tabs below
-- it should move down"). One card, taller, nothing across anything. A hover
-- decision is held until that slide has finished, so a row sliding under a
-- still pointer cannot open its own clip mid-slide and set off a see-saw.
-- On a touch screen there is no hover: the first tap on a row opens its
-- clip and the pill buys. If the opened card runs past the window's bottom
-- the sheet scrolls just far enough to show all of it.
--
-- PIXELS, NOT SCALE, FOR THE ROWS. A ScrollingFrame resolves a child's Scale
-- against the CANVAS, not the window, so a canvas that grew when a card
-- opened would re-size every row with it. The rows, their top bands and the
-- clip windows are laid out in offset pixels from ONE factor -- the fitted
-- page's absolute width over AUTH_W -- recomputed on every AbsoluteSize
-- change. Everything INSIDE a top band stays in the kit's Scale against the
-- band, and the band never changes size, so a card growing to show its clip
-- moves nothing on the band.
--
-- ONE AUTHORED SPACE, FITTED. The page is drawn against AUTH_W x AUTH_H --
-- the lobby panel's rectangle -- and scaled UNIFORMLY into whatever box it
-- is given, centred, so the in-game panel gets the same drawing smaller
-- rather than a stretched one.
--
-- NOTHING HERE DECIDES ANYTHING. Ownership is the site's, relayed by the
-- server; a press only ever asks the server to open the site's prompt, and
-- the card flips to OWNED when the server has re-asked the site and it said
-- yes. This checks ownership locally only so a press that cannot succeed is
-- never sent at all.

local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Products = require(script.Parent.Products)
local LobbyUI = require(script.Parent.LobbyUI)
local PassClips = require(script.Parent.PassClips)
local Sfx = require(script.Parent.Sfx)

local kit = LobbyUI.kit
local place, label, chip = kit.place, kit.label, kit.chip
local setText = kit.setText
local roundOff, grower, tween = kit.roundOff, kit.grower, kit.tween

local PassShop = {}
PassShop.__index = PassShop

-- The lobby tab's list, kept under the old name for its callers. A pass with
-- no id yet is skipped at build time (Products.isLive), the same way an
-- unconfigured product never reaches any other page -- a card that could
-- not be pressed sells nothing.
PassShop.ORDER = Products.LOBBY_PASSES

local HERO = "VIP"

-- ---------------------------------------------------------------- layout ---
-- Everything below is in the AUTHORED page space: AUTH_W wide (the lobby
-- panel's rectangle on the 16:9 reference), as tall as the rows make it.
-- AUTH_H is the window the page is fitted into, not a limit on the sheet.
local AUTH_W, AUTH_H = 1136, 476
-- The scroll bar's lane at the right edge, and the gap the rows keep from it.
local BAR_W, BAR_GAP = 8, 6
-- THE SHEET CLIPS, SO THE ROWS KEEP OFF ITS EDGES (owner, 2026-09-22: "edges
-- seem cropped off"). A ScrollingFrame cuts everything at its window, and a
-- card grows 2.5% on hover and wears a stroke outside its box: flush with
-- the window, both were sliced off. MARGIN_X is more than the grow on a
-- card this wide (14 px) plus the stroke; MARGIN_Y more than the grow on
-- its height plus the stroke, above the first row and below the last.
local MARGIN_X, MARGIN_Y = 18, 6
local CARD_W = AUTH_W - MARGIN_X * 2 - BAR_W - BAR_GAP
-- 132 is twice the 66 that five rows were squeezed to in the lobby (owner:
-- "2x"); the gap is clear panel between two cards, not a hairline.
local ROW_H, ROW_GAP = 132, 24
local ROW_PAD = 12

-- The header chip: the tab strip's own shape, floated inside the row's left
-- end. The name may take two lines in it at one size.
local HEAD_W = 270
local NAME_TEXT = 22
local CROWN = 44

-- The list: columns of three lines, left to right, after the header.
local LIST_COL_W = 290
local LIST_ROWS = 3
local PERK_TEXT = 20
local PERK_DOT = 9
local PERK_INDENT = 24

-- The two pills together fill the row's height inside its padding:
-- 48 + 10 + 48 = 106 in a 132 - 24 = 108 band.
local PILL_W, PILL_H, PILL_GAP = 200, 48, 10
-- The pills' rest edge, and how they answer the cursor (hoverPill): a touch
-- more lift than the card's 1.025 because the pill is small, and the edge
-- thickening with it.
local PILL_EDGE = 1.6
local PILL_HOVER_SCALE, PILL_HOVER_EDGE = 1.06, 2.6
local PILL_TEXT = 22
local MONEY_TEXT = 17
-- The Robux glyph, height-led and square, sits this far left of the price.
local GLYPH_H = 0.5
local GLYPH_GAP = 0.03

-- The clip window a card opens under its top band: this tall, inset from
-- the card's edges by CLIP_PAD, and CLIP_PAD of card under it. 170 is what
-- lets the SECOND row open without the sheet scrolling in a 476-tall window
-- (6 + 132 + 24 + 312 = 474): a scroll of a few pixels only cuts a sliver
-- off the top card, which reads as a crop and not as a scroll.
local CLIP_H, CLIP_PAD = 170, 10
local OPEN_H = ROW_H + CLIP_H + CLIP_PAD
local CLIP_OPEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLIP_CLOSE = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
-- Seconds the pointer may be in the gap between two rows before the page
-- decides what is hovered.
local HOVER_GRACE = 0.08

-- THE PALETTE. Rows are a slab a shade lighter than the panel they sit on;
-- the hero's is warmed a sixteenth toward gold; the header and the pill use
-- the tab strip's two fills outright, so "lit" means the same thing
-- everywhere on this panel. The clip window is a step darker than its row,
-- so it reads as something opened out of it.
local SLAB = Color3.fromRGB(23, 29, 45)
local SLAB_HERO = SLAB:Lerp(kit.GOLD, 0.07)
local CLIP_FILL = Color3.fromRGB(17, 22, 35)
local ON_INK = Color3.fromRGB(20, 22, 28)
local OFF_FILL = Color3.fromRGB(38, 43, 56)
-- The backdrop the owner's card renders are painted on (StarterGui.Images
-- ArtilleryBattery / Airbase / Mega Nuke Shop, 2026-09-22): a square head in
-- this fill shows a letterboxed 16:9 render with no visible bars.
local ART_FILL = Color3.fromRGB(76, 105, 112)
local SCRIM_ALPHA = 0.86

-- THE ARRIVAL. Rows come up from a step under full size when the page is
-- switched to, top first, with the ladder's own overshoot. Only on a real
-- switch: PatternShop.paintTabs also calls setVisible on every tab hover.
local ARRIVE_FROM = 0.9
local ARRIVE_STEP = 0.06
local ARRIVE = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- ------------------------------------------------------------------- art ---
-- CLONED OUT OF THE OWNER'S OWN ART, never built from an id typed in here: an
-- instance already drawing somewhere is proof the asset renders, and an id in
-- this file would be a guess (the same rule the tutorial deal card follows).
-- Either returns nil when the art is not there, and the card simply goes
-- without -- a missing crown is not a reason to break the shop.

local function findCrown(): ImageLabel?
	local images = StarterGui:FindFirstChild("Images")
	local crown = images and images:FindFirstChild("Crown")
	if crown and crown:IsA("ImageLabel") then
		return crown
	end
	return nil
end

-- A pass's card picture: the StarterGui.Images entry its Products `art`
-- names (owner, 2026-09-22: "use these images"), or nil for a pass without.
local function findArt(name: string?): ImageLabel?
	if name == nil then
		return nil
	end
	local images = StarterGui:FindFirstChild("Images")
	local art = images and images:FindFirstChild(name)
	if art and art:IsA("ImageLabel") and art.Image ~= "" then
		return art
	end
	return nil
end

-- THE BUY BUTTONS ANSWER THE CURSOR (owner, 2026-09-22: "give the buy buttons
-- hover effects too"): the card's own lift, a touch bigger on the small
-- pill, its edge thickening, and the "+" page's tick. A UIScale (grower),
-- not a Size tween: paint moves the Robux pill between two slots and must
-- not have to know whether the pointer is on it.
local function hoverPill(pill: GuiButton, scale: UIScale, edge: UIStroke)
	pill.MouseEnter:Connect(function()
		Sfx.play("Click", { volume = 0.12, pitch = 1.7 })
		tween(scale, kit.HOVER_IN, { Scale = PILL_HOVER_SCALE })
		tween(edge, kit.HOVER_IN, { Thickness = PILL_HOVER_EDGE })
	end)
	pill.MouseLeave:Connect(function()
		tween(scale, kit.HOVER_OUT, { Scale = 1 })
		tween(edge, kit.HOVER_OUT, { Thickness = PILL_EDGE })
	end)
end

local function findRobux(): ImageLabel?
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

-- A clean copy: no strokes (a stroke outlines the box, not the shape), no
-- children, square by height so it follows the text it sits beside.
local function cloneArt(src: ImageLabel, name: string): ImageLabel
	local g = src:Clone()
	g.Name = name
	for _, d in g:GetChildren() do
		d:Destroy()
	end
	g.BackgroundTransparency = 1
	g.ScaleType = Enum.ScaleType.Fit
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.DominantAxis = Enum.DominantAxis.Height
	ar.Parent = g
	return g
end

-- Pins a kit label to ONE type size. `kit.label` fits a UITextSizeConstraint
-- with MaxTextSize = h * 4; left alone, a short line balloons to fill its box
-- and a row reads in three sizes.
local function pin(t: TextLabel, size: number)
	local c = t:FindFirstChildOfClass("UITextSizeConstraint")
	if c then
		c.MaxTextSize = math.max(6, math.floor(size))
	end
end

-- 1234567 -> "1,234,567", the readout's own grouping.
local function comma(n: number): string
	local s = string.format("%.0f", math.max(0, n))
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, -4)
	end
	return s .. out
end

-- A phone or a pad with no pointer: the clip opens on a tap instead.
local function touchOnly(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

-- ------------------------------------------------------------------ build --

local function buildRow(self: any, parent: Instance, entryDef: any, index: number): any
	local hero = entryDef.key == HERO
	local ts = self.fit or 1

	-- THE CARD. Sized and placed in pixels by `layout`, never here; it clips
	-- its children so the clip window below the band is hidden until the
	-- card has grown down over it.
	local card = Instance.new("ImageButton")
	card.Name = "Pass_" .. entryDef.key
	card.Image = ""
	card.BackgroundColor3 = hero and SLAB_HERO or SLAB
	card.BackgroundTransparency = 0.04
	card.BorderSizePixel = 0
	card.AutoButtonColor = false
	card.ClipsDescendants = true
	card.ZIndex = 1
	card.Parent = parent
	roundOff(card, 12)

	-- The kit's grain, faint, so the slab is a surface and not a flat fill.
	local scrim = Instance.new("ImageLabel")
	scrim.Name = "Scrim"
	scrim.BackgroundTransparency = 1
	scrim.Image = kit.SCRIM
	scrim.ScaleType = Enum.ScaleType.Stretch
	scrim.ImageTransparency = SCRIM_ALPHA
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = card
	roundOff(scrim, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Color = kit.LINE
	stroke.Thickness = 1.6
	stroke.Transparency = 0.45
	stroke.Parent = card

	-- THE TOP BAND: the row as it reads closed -- header, list, pill -- in
	-- the kit's Scale against CARD_W x ROW_H. Its pixel size is `layout`'s
	-- and never follows the card's growth.
	local band = Instance.new("Frame")
	band.Name = "Band"
	band.BackgroundTransparency = 1
	band.BorderSizePixel = 0
	band.ZIndex = 1
	band.Parent = card

	-- THE HEADER CHIP. Gold with dark ink on the hero, the slab with light ink
	-- on an offer -- the tab strip's two states, on a row.
	local headH = ROW_H - ROW_PAD * 2
	-- THE PICTURE (owner, 2026-09-22: "instead of just having the names in
	-- the shop, i want the images ... put the name in the upper portion of
	-- the card"): a pass with `art` (Products: the name of a StarterGui.Images
	-- entry) wears it in a SQUARE head, on the renders' own backdrop so a
	-- letterboxed one shows no bars, and its name moves up to the top line
	-- of the middle column (the list below). A pass without art -- VIP with
	-- its crown, BARRACKS -- keeps the wide name box.
	local art = findArt(entryDef.art)
	local headW = if art then headH else HEAD_W
	local head = Instance.new("Frame")
	head.Name = "Head"
	head.BackgroundColor3 = if art then ART_FILL elseif hero then kit.GOLD else OFF_FILL
	head.BorderSizePixel = 0
	place(head, CARD_W, ROW_H, ROW_PAD, ROW_PAD, headW, headH)
	head.Parent = band
	roundOff(head, 10)
	local headStroke = Instance.new("UIStroke")
	headStroke.Color = hero and kit.GOLD or kit.LINE
	headStroke.Thickness = 1.6
	headStroke.Transparency = hero and 0 or 0.35
	headStroke.Parent = head
	local pic: ImageLabel? = nil
	if art then
		local p = cloneArt(art, "Art")
		p.AnchorPoint = Vector2.new(0.5, 0.5)
		p.Position = UDim2.fromScale(0.5, 0.5)
		p.Size = UDim2.fromScale(1, 1)
		p.ZIndex = 2
		roundOff(p, 10)
		p.Parent = head
		pic = p
	end

	local nameX = 16
	local crown: ImageLabel? = nil
	if hero then
		local src = findCrown()
		if src then
			crown = cloneArt(src, "Crown")
			local c = crown :: ImageLabel
			place(c, HEAD_W, headH, 14, (headH - CROWN) / 2, CROWN, CROWN)
			c.ZIndex = 2
			c.Parent = head
			nameX = 14 + CROWN + 14
		end
	end
	-- The name: in the head for a pass without art; with art it is made with
	-- the list below, on the band's top line.
	local name: TextLabel? = nil
	if art == nil then
		local n = label(head, "Name", HEAD_W, headH, nameX, 6, HEAD_W - nameX - 14, headH - 12, hero and ON_INK or kit.INK, Enum.TextXAlignment.Left, kit.FONT_BOLD)
		n.TextWrapped = true
		pin(n, NAME_TEXT * ts)
		setText(n, string.upper(entryDef.name))
		name = n
	end

	-- THE PILLS, the buy buttons, stacked at the row's right end: MONEY ON
	-- TOP, ROBUX UNDER IT (owner, 2026-09-22: "Money button on top, green
	-- robux right below it" -- the earned route first, the paid one beneath
	-- in the buy-green every Robux pill wears). Each a GuiButton of its own
	-- so a tap on it buys on every platform (see press / pressMoney).
	local pillX = CARD_W - ROW_PAD - PILL_W
	-- Where the stack starts, where the Robux pill sits under the Money one,
	-- and where a LONE Robux pill sits (the Money pill gone: owned, or no
	-- Money price) -- paint moves it between the last two.
	local pillsY = (ROW_H - (PILL_H * 2 + PILL_GAP)) / 2
	-- CENTRE-ANCHORED slots, because each pill grows from its middle on hover
	-- (grower re-anchors it below); paint moves the Robux pill between them.
	local pillBottom = UDim2.fromScale((pillX + PILL_W / 2) / CARD_W, (pillsY + PILL_H + PILL_GAP + PILL_H / 2) / ROW_H)
	local pillMid = UDim2.fromScale((pillX + PILL_W / 2) / CARD_W, 0.5)
	local pill = Instance.new("ImageButton")
	pill.Name = "Pill"
	pill.Image = ""
	pill.AutoButtonColor = false
	pill.BackgroundColor3 = OFF_FILL
	pill.BorderSizePixel = 0
	place(pill, CARD_W, ROW_H, pillX, pillsY + PILL_H + PILL_GAP, PILL_W, PILL_H)
	local pillScale = grower(pill)
	pill.Parent = band
	roundOff(pill, 10)
	local pillStroke = Instance.new("UIStroke")
	pillStroke.Color = kit.LINE
	pillStroke.Thickness = 1.6
	pillStroke.Transparency = 0.35
	pillStroke.Parent = pill
	local state = label(pill, "State", PILL_W, PILL_H, 0, (PILL_H - PILL_TEXT) / 2, PILL_W, PILL_TEXT, kit.INK, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	pin(state, PILL_TEXT * ts)
	local glyph: ImageLabel? = nil
	local src = findRobux()
	if src then
		glyph = cloneArt(src, "Robux")
		local g = glyph :: ImageLabel
		g.AnchorPoint = Vector2.new(1, 0.5)
		g.Size = UDim2.fromScale(1, GLYPH_H)
		g.Position = UDim2.fromScale(0.5, 0.5)
		g.ZIndex = 2
		g.Visible = false
		g.Parent = pill
	end

	-- THE MONEY PILL, on top of the Robux one: the same shape in the slab
	-- fill, its edge and its number green while the balance covers the price
	-- and grey while it does not (the pattern cards' affordability read).
	-- Hidden on a pass with no Money price, and once the pass is owned.
	local moneyPill = Instance.new("ImageButton")
	moneyPill.Name = "MoneyPill"
	moneyPill.Image = ""
	moneyPill.AutoButtonColor = false
	moneyPill.BackgroundColor3 = OFF_FILL
	moneyPill.BorderSizePixel = 0
	moneyPill.Visible = false
	place(moneyPill, CARD_W, ROW_H, pillX, pillsY, PILL_W, PILL_H)
	local moneyScale = grower(moneyPill)
	moneyPill.Parent = band
	roundOff(moneyPill, 10)
	local moneyStroke = Instance.new("UIStroke")
	moneyStroke.Color = kit.LINE
	moneyStroke.Thickness = 1.6
	moneyStroke.Transparency = 0.35
	moneyStroke.Parent = moneyPill
	local moneyState = label(moneyPill, "State", PILL_W, PILL_H, 0, (PILL_H - MONEY_TEXT) / 2, PILL_W, MONEY_TEXT, kit.INK, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	pin(moneyState, MONEY_TEXT * ts)

	-- WHAT IT GIVES, across the middle: one line per grant with a dot before
	-- it, in columns of three. A pass with no list falls back to its blurb.
	local copy = {}
	local dots = {}
	local perks = entryDef.perks
	-- The middle column starts after the head, whatever width the head is.
	local listX = ROW_PAD + headW + 28
	local listW = pillX - 16 - listX
	local pitch = (ROW_H - ROW_PAD * 2) / LIST_ROWS
	-- WITH ART THE NAME TAKES THE TOP LINE of this column (owner: "put the
	-- name in the upper portion of the card") and the perks stack under it.
	local firstRow = 0
	if art ~= nil then
		local n = label(band, "Name", CARD_W, ROW_H, listX, ROW_PAD, listW, pitch, kit.INK, Enum.TextXAlignment.Left, kit.FONT_BOLD)
		pin(n, NAME_TEXT * ts)
		setText(n, string.upper(entryDef.name))
		name = n
		firstRow = 1
	end
	if type(perks) == "table" and #perks > 0 then
		local rows = LIST_ROWS - firstRow
		for i, text in perks do
			local col, row = (i - 1) // rows, firstRow + (i - 1) % rows
			local x = listX + col * LIST_COL_W
			local ly = ROW_PAD + row * pitch
			local dot = chip(band, "Dot" .. i, CARD_W, ROW_H, x, ly + (pitch - PERK_DOT) / 2, PERK_DOT, PERK_DOT, kit.GAIN, 0)
			table.insert(dots, dot)
			local line = label(band, "Perk" .. i, CARD_W, ROW_H, x + PERK_INDENT, ly, LIST_COL_W - PERK_INDENT - 12, pitch, kit.INK, Enum.TextXAlignment.Left, kit.FONT_BOLD)
			pin(line, PERK_TEXT * ts)
			setText(line, text)
			table.insert(copy, line)
		end
	else
		local blurb = label(band, "Blurb", CARD_W, ROW_H, listX, ROW_PAD + firstRow * pitch, listW, ROW_H - ROW_PAD * 2 - firstRow * pitch, kit.INK_DIM, Enum.TextXAlignment.Left)
		blurb.TextWrapped = true
		pin(blurb, PERK_TEXT * ts)
		setText(blurb, entryDef.blurb)
		table.insert(copy, blurb)
	end

	-- THE CLIP WINDOW, for a pass with a clip: a darker inset under the band,
	-- inside the card's own border, hidden by the card's clipping until the
	-- card grows down over it. The clip is drawn at the window's aspect (its
	-- tile grid takes its width from it), so the scene runs edge to edge.
	local view: Frame? = nil
	local clip: any = nil
	if PassClips.KEYS[entryDef.key] then
		local v = Instance.new("Frame")
		v.Name = "Clip"
		v.BackgroundColor3 = CLIP_FILL
		v.BackgroundTransparency = 0.02
		v.BorderSizePixel = 0
		v.ClipsDescendants = true
		v.Visible = false
		v.ZIndex = 1
		v.Parent = card
		roundOff(v, 8)
		local vs = Instance.new("UIStroke")
		vs.Color = kit.LINE
		vs.Thickness = 1.6
		vs.Transparency = 0.2
		vs.Parent = v
		clip = PassClips.new(v, entryDef.key, (CARD_W - CLIP_PAD * 2) / CLIP_H)
		view = v
	end

	local scale = grower(card)
	local entry = {
		key = entryDef.key,
		def = entryDef,
		hero = hero,
		index = index,
		card = card,
		band = band,
		stroke = stroke,
		head = head,
		headStroke = headStroke,
		crown = crown,
		art = pic,
		name = name :: TextLabel,
		copy = copy,
		dots = dots,
		list = #dots > 0,
		pill = pill,
		pillStroke = pillStroke,
		state = state,
		glyph = glyph,
		pillBottom = pillBottom,
		pillMid = pillMid,
		moneyPill = moneyPill,
		moneyStroke = moneyStroke,
		moneyState = moneyState,
		moneyPrice = Products.moneyPrice(entryDef.key),
		scale = scale,
		hover = false,
		view = view,
		clip = clip,
		-- Where the row sits on the sheet and how tall it is right now, in
		-- authored units; `layout` writes both.
		top = 0,
		h = ROW_H,
	}

	-- The glyph follows the number: TextScaled keeps TextBounds in step with
	-- the label, so its rendered left edge is a ratio the pill can place
	-- against whatever the window does.
	state:GetPropertyChangedSignal("TextBounds"):Connect(function()
		PassShop.placeGlyph(entry)
	end)

	-- The clip window is inside the card, so hovering the picture is still
	-- hovering the card: one enter, one leave, no union to keep.
	card.MouseEnter:Connect(function()
		entry.hover = true
		tween(scale, kit.HOVER_IN, { Scale = kit.HOVER_SCALE })
		tween(stroke, kit.HOVER_IN, { Transparency = 0 })
		self.rowHover = entry.key
		PassShop.settleHover(self)
	end)
	card.MouseLeave:Connect(function()
		entry.hover = false
		tween(scale, kit.HOVER_OUT, { Scale = 1 })
		PassShop.paintCard(self, entry)
		if self.rowHover == entry.key then
			self.rowHover = nil
		end
		PassShop.settleHover(self)
	end)
	card.MouseButton1Down:Connect(function()
		tween(scale, kit.PRESS_IN, { Scale = kit.PRESS_SCALE })
	end)
	card.MouseButton1Up:Connect(function()
		tween(scale, kit.PRESS_OUT, { Scale = entry.hover and kit.HOVER_SCALE or 1 })
	end)
	-- A tap on the row: with a pointer it buys, like the pill; without one
	-- it opens the clip first (there was no hover to do it), and buys on
	-- the next tap once the clip is up.
	card.Activated:Connect(function()
		if touchOnly() and entry.view ~= nil and self.openKey ~= entry.key then
			PassShop.openDrawer(self, entry)
			return
		end
		PassShop.press(self, entry)
	end)
	pill.Activated:Connect(function()
		PassShop.press(self, entry)
	end)
	moneyPill.Activated:Connect(function()
		PassShop.pressMoney(self, entry)
	end)
	hoverPill(pill, pillScale, pillStroke)
	hoverPill(moneyPill, moneyScale, moneyStroke)
	return entry
end

-- `parent` is the window; `x, y, w, h` the rectangle on it this page owns, in
-- the parent's own authored pixel space `pw x ph`. The page is fitted into it
-- uniformly (see the header). `keys` picks the passes; nil is the lobby's.
function PassShop.new(parent: Instance, pw: number, ph: number, x: number, y: number, w: number, h: number, keys: { string }?): any
	local self = setmetatable({}, PassShop)
	-- Nothing is known until the server says so -- same rule as the other
	-- pages, and for the same reason: a page that priced everything while the
	-- profile was loading would offer to sell what is already owned.
	self.known = false
	self.owned = {} :: { [string]: boolean }
	self.prices = {} :: { [string]: number }
	-- What the site said about each pass being FOR SALE; nil until asked.
	self.forSale = {} :: { [string]: boolean }
	self.onPass = nil :: ((string) -> ())?
	-- The Money pill's press, by key; the server settles it (2026-09-22).
	self.onMoney = nil :: ((string) -> ())?
	self.onSay = nil :: ((string) -> ())?
	-- The balance the Money pills price against; nil until the page is told.
	self.money = nil :: number?
	self.entries = {}
	self.byKey = {} :: { [string]: any }
	-- Every delayed arrival belongs to the switch that scheduled it.
	self.showGen = 0
	-- The clip state: which row's is open, what the pointer is over, and
	-- until when the rows are still sliding (no hover decisions before then).
	self.openKey = nil :: string?
	self.rowHover = nil :: string?
	self.hoverGen = 0
	self.closeGen = 0
	self.canvasGen = 0
	self.reflowUntil = 0
	-- Pixels per authored unit, from the last layout; 0 until the page has
	-- a size.
	self.px = 0

	-- UNIFORM FIT: the largest AUTH_W x AUTH_H box that sits inside the
	-- rectangle, centred in it. The lobby hands over exactly that rectangle,
	-- so there the fit is one-to-one.
	local k = math.min(w / AUTH_W, h / AUTH_H)
	local rootW, rootH = AUTH_W * k, AUTH_H * k
	-- THE TYPE CAPS FOLLOW THE FIT, floored: a page drawn at two thirds size
	-- has boxes two thirds as tall, and a cap left at the lobby's size lets
	-- TextScaled pick a different size per line. Three quarters is as small
	-- as the caps go, so the in-game page stays readable at the reference.
	self.fit = math.max(0.75, k)

	-- THE SHEET. The window is the fitted box; the canvas is as tall as the
	-- rows make it (see layout) and scrolls when that is more. A plain bar in
	-- the kit's line colour, in the lane the rows leave for it.
	local root = Instance.new("ScrollingFrame")
	root.Name = "PassesPage"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Visible = false
	root.Selectable = false
	root.ScrollingDirection = Enum.ScrollingDirection.Y
	root.AutomaticCanvasSize = Enum.AutomaticSize.None
	root.CanvasSize = UDim2.fromOffset(0, 0)
	root.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	root.VerticalScrollBarPosition = Enum.VerticalScrollBarPosition.Right
	root.VerticalScrollBarInset = Enum.ScrollBarInset.None
	root.HorizontalScrollBarInset = Enum.ScrollBarInset.None
	root.ScrollBarImageColor3 = kit.INK_DIM
	root.ScrollBarImageTransparency = 0.55
	root.ScrollBarThickness = BAR_W
	root.TopImage = root.MidImage
	root.BottomImage = root.MidImage
	place(root, pw, ph, x + (w - rootW) / 2, y + (h - rootH) / 2, rootW, rootH)
	root.Parent = parent
	self.root = root

	local live = {}
	for _, key in (keys or Products.LOBBY_PASSES) do
		local def = Products.pass(key)
		if Products.isLive(def) then
			table.insert(live, def)
		end
	end
	for i, def in live do
		local entry = buildRow(self, root, def, i)
		table.insert(self.entries, entry)
		self.byKey[def.key] = entry
	end

	-- The rows are pixels off the window's real size, so a resize re-lays
	-- them; instantly, a window changing size is not an animation.
	root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		PassShop.layout(self, nil)
	end)
	PassShop.layout(self, nil)
	PassShop.repaint(self)
	return self
end

-- ---------------------------------------------------------------- layout ---

-- EVERY ROW TO ITS PLACE AND SIZE, given which clip is open: the open card is
-- OPEN_H tall, the rows under it sit CLIP_H + CLIP_PAD lower, and the canvas
-- is as long as the last row's bottom. One function, called after any
-- change, so opening B while A is closing cannot leave a row counted twice.
-- `info` tweens the cards there; nil puts them there at once (a resize, a
-- hidden page). The bands and clip windows are never tweened: a band does
-- not change, and a clip window is revealed by the card's edge, not by
-- moving.
function PassShop.layout(self: any, info: TweenInfo?)
	local root = self.root :: ScrollingFrame
	-- A page with no size yet (built under a hidden window) still gets its
	-- bookkeeping -- `top` and `h` are what scrollTo reads -- and the pixels
	-- land on the AbsoluteSize change that follows.
	local s = root.AbsoluteSize.X / AUTH_W
	self.px = s
	local openIdx = 0
	if self.openKey then
		local o = self.byKey[self.openKey]
		openIdx = o and o.index or 0
	end
	local animate = info ~= nil and root.Visible
	local y = MARGIN_Y
	local canvasH = 0
	for _, e in self.entries do
		local h = if e.index == openIdx then OPEN_H else ROW_H
		e.top = y
		e.h = h
		if s > 0 then
			local size = UDim2.fromOffset(CARD_W * s, h * s)
			local pos = UDim2.fromOffset((MARGIN_X + CARD_W / 2) * s, (y + h / 2) * s)
			if animate then
				tween(e.card, info :: TweenInfo, { Size = size, Position = pos })
			else
				e.card.Size = size
				e.card.Position = pos
			end
			e.band.Size = UDim2.fromOffset(CARD_W * s, ROW_H * s)
			e.band.Position = UDim2.fromOffset(0, 0)
			if e.view then
				local v = e.view :: Frame
				v.Size = UDim2.fromOffset((CARD_W - CLIP_PAD * 2) * s, CLIP_H * s)
				v.Position = UDim2.fromOffset(CLIP_PAD * s, ROW_H * s)
			end
		end
		canvasH = y + h + MARGIN_Y
		y += h + ROW_GAP
	end
	if s <= 0 then
		return
	end
	root.ScrollBarThickness = math.max(4, math.floor(BAR_W * s + 0.5))

	-- THE CANVAS. Longer at once, so an opening card has room to grow into;
	-- shorter only after the rows have slid up, and the view brought up with
	-- them, so nothing jumps when the scroll position is clamped.
	local canvasPx = canvasH * s
	self.canvasGen += 1
	local gen = self.canvasGen
	if animate and canvasPx < root.CanvasSize.Y.Offset then
		local maxY = math.max(0, canvasPx - root.AbsoluteSize.Y)
		if root.CanvasPosition.Y > maxY then
			tween(root, info :: TweenInfo, { CanvasPosition = Vector2.new(0, maxY) })
		end
		task.delay((info :: TweenInfo).Time, function()
			if self.canvasGen == gen then
				root.CanvasSize = UDim2.fromOffset(0, canvasPx)
			end
		end)
	else
		root.CanvasSize = UDim2.fromOffset(0, canvasPx)
	end
	self.reflowUntil = if animate then os.clock() + (info :: TweenInfo).Time else 0
end

-- The sheet scrolls just far enough that the whole of `entry` is in the
-- window -- an opened card whose clip would otherwise hang below the edge.
-- Never further: the pointer that opened it was on the top band, and a scroll
-- of at most the clip's height leaves it on the same, now taller, card.
function PassShop.scrollTo(self: any, entry: any, info: TweenInfo)
	local root = self.root :: ScrollingFrame
	local s = self.px
	if s <= 0 then
		return
	end
	-- The window is the frame's own height: the sheet scrolls one way, so
	-- no horizontal bar ever takes a strip of it.
	local windowH = root.AbsoluteSize.Y
	if windowH <= 0 then
		-- Not laid out yet (a window still coming up): a zero-tall window
		-- would put the card's top at the sheet's top for no reason.
		return
	end
	local top, bottom = (entry.top - MARGIN_Y) * s, (entry.top + entry.h + MARGIN_Y) * s
	local y = root.CanvasPosition.Y
	local target = y
	if bottom - y > windowH then
		target = bottom - windowH
	end
	if top < target then
		target = top
	end
	target = math.clamp(target, 0, math.max(0, root.CanvasSize.Y.Offset - windowH))
	if math.abs(target - y) > 0.5 then
		tween(root, info, { CanvasPosition = Vector2.new(0, target) })
	end
end

-- ----------------------------------------------------------------- clips ---

function PassShop.openDrawer(self: any, entry: any)
	if entry.view == nil or self.openKey == entry.key then
		return
	end
	PassShop.closeDrawer(self)
	self.openKey = entry.key
	local v = entry.view :: Frame
	v.Visible = true
	PassShop.layout(self, CLIP_OPEN)
	PassShop.scrollTo(self, entry, CLIP_OPEN)
	if entry.clip then
		entry.clip:play()
	end
end

function PassShop.closeDrawer(self: any)
	local key = self.openKey
	if key == nil then
		return
	end
	self.openKey = nil
	local entry = self.byKey[key]
	if entry == nil or entry.view == nil then
		PassShop.layout(self, CLIP_CLOSE)
		return
	end
	if entry.clip then
		entry.clip:stop()
	end
	-- The card's edge slides back up over the picture (the card clips), and
	-- the window is hidden once it is fully covered -- unless this same card
	-- was opened again in the meantime.
	self.closeGen += 1
	local gen = self.closeGen
	PassShop.layout(self, CLIP_CLOSE)
	task.delay(CLIP_CLOSE.Time, function()
		if self.closeGen == gen and self.openKey ~= key then
			(entry.view :: Frame).Visible = false
		end
	end)
end

-- AFTER A GRACE PERIOD, the open clip follows the pointer: the row it is over
-- wins, and no row means closed. The delay is what lets the pointer step
-- across the gap from one row to the next without the clip snapping shut in
-- between -- and while the rows are still SLIDING the decision waits for
-- them to stop, so a row passing under a still pointer cannot open its own
-- clip mid-slide.
function PassShop.settleHover(self: any)
	self.hoverGen += 1
	local gen = self.hoverGen
	local wait = math.max(HOVER_GRACE, self.reflowUntil - os.clock() + HOVER_GRACE)
	task.delay(wait, function()
		if self.hoverGen ~= gen or not self.root.Visible then
			return
		end
		local want = self.rowHover
		if want == self.openKey then
			return
		end
		if want == nil then
			PassShop.closeDrawer(self)
			return
		end
		local entry = self.byKey[want]
		if entry and entry.view then
			PassShop.openDrawer(self, entry)
		else
			PassShop.closeDrawer(self)
		end
	end)
end

-- ----------------------------------------------------------------- paint ---

-- The glyph's right edge lands a small gap left of where the number starts.
-- The number is centred, so its start is half its rendered width left of the
-- middle -- and the number is nudged right by half the glyph so the pair
-- reads centred as a group.
function PassShop.placeGlyph(entry: any)
	local g = entry.glyph
	if g == nil then
		return
	end
	local st = entry.state :: TextLabel
	local pw = math.max(1, entry.pill.AbsoluteSize.X)
	local ratio = math.clamp(st.TextBounds.X / pw, 0, 1)
	local half = GLYPH_H * (entry.pill.AbsoluteSize.Y / pw) / 2
	st.Position = UDim2.fromScale(half, st.Position.Y.Scale)
	g.Position = UDim2.fromScale(0.5 + half - ratio / 2 - GLYPH_GAP, 0.5)
end

function PassShop.paintCard(self: any, entry: any)
	local owned = self.known and self.owned[entry.key] == true
	local offSale = self.forSale[entry.key] == false
	local hero = entry.hero
	local showGlyph = false

	if owned then
		-- HELD. The pill stops being a button: a price on a thing you have
		-- already bought is an invitation to buy it twice.
		entry.stroke.Color = kit.GOLD
		entry.stroke.Thickness = 2.2
		entry.stroke.Transparency = 0.1
		entry.pill.BackgroundColor3 = OFF_FILL
		entry.pillStroke.Color = kit.GOLD
		entry.pillStroke.Transparency = 0.2
		setText(entry.state, "OWNED")
		entry.state.TextColor3 = kit.GOLD
	elseif not self.known then
		entry.stroke.Color = kit.LINE
		entry.stroke.Thickness = 1.6
		entry.stroke.Transparency = 0.45
		entry.pill.BackgroundColor3 = OFF_FILL
		entry.pillStroke.Color = kit.LINE
		entry.pillStroke.Transparency = 0.35
		setText(entry.state, "")
	elseif offSale then
		-- THE SITE SAYS NOT FOR SALE. Drawn, dimmed, and the press is refused
		-- below -- the same SOON a product with no id yet gets, because from
		-- the player's side it is the same thing: not buyable today.
		entry.stroke.Color = kit.LINE
		entry.stroke.Thickness = 1.6
		entry.stroke.Transparency = 0.55
		entry.pill.BackgroundColor3 = OFF_FILL
		entry.pillStroke.Color = kit.LINE
		entry.pillStroke.Transparency = 0.5
		setText(entry.state, "SOON")
		entry.state.TextColor3 = kit.INK_OFF
	else
		-- FOR SALE. The price is the site's, fetched once by the page's owner
		-- and handed down; until it lands the pill says what it is rather
		-- than a number it cannot vouch for -- same contract as a Robux skin.
		entry.stroke.Color = hero and kit.GOLD or kit.LINE
		entry.stroke.Thickness = hero and 2.2 or 1.6
		entry.stroke.Transparency = hero and 0.3 or 0.45
		-- BUY-GREEN, not gold (owner, 2026-09-22: "green robux right below
		-- it"): the kit's GAIN, the colour this UI already spends on money
		-- coming in, so the Robux pill reads as the buy button it is on
		-- every card -- gold stays the mark of a pass already HELD.
		entry.pill.BackgroundColor3 = kit.GAIN
		entry.pillStroke.Color = kit.GAIN
		entry.pillStroke.Transparency = 0
		-- "GET", NOT THE NUMBER (owner, 2026-09-22: "dont say the robux number
		-- on the buttons. say Get"): the Robux glyph beside it still says which
		-- currency, and the price is the purchase prompt's to show. The site
		-- is still asked (setPrice) because on-sale-or-not arrives with it.
		showGlyph = entry.glyph ~= nil
		setText(entry.state, showGlyph and "GET" or "GET R$")
		entry.state.TextColor3 = ON_INK
	end

	-- EVERYTHING ELSE FOLLOWS THE STATE: out while nothing is known or the
	-- pass is off sale, lit otherwise. The header keeps its own two fills but
	-- its ink dims with the rest; the list's dots go out with their lines.
	-- ...unless the Money route is open: a pass the site is not selling yet
	-- but the catalogue prices in Money (BARRACKS) is live on this page, so
	-- only its Robux pill reads SOON.
	local dim = not self.known or (offSale and not owned and entry.moneyPrice == nil)
	entry.name.TextColor3 = if dim then kit.INK_OFF elseif hero then ON_INK else kit.INK
	entry.head.BackgroundTransparency = dim and 0.5 or 0
	entry.headStroke.Transparency = if dim then 0.7 elseif hero then 0 else 0.35
	if entry.crown then
		entry.crown.ImageTransparency = dim and 0.5 or 0
	end
	if entry.art then
		entry.art.ImageTransparency = dim and 0.5 or 0
	end
	for _, t in entry.copy do
		t.TextColor3 = if dim then kit.INK_OFF elseif entry.list then kit.INK else kit.INK_DIM
	end
	for _, d in entry.dots do
		d.BackgroundTransparency = dim and 0.6 or 0
	end

	-- THE MONEY PILL follows the same state: gone when the pass is held or
	-- has no Money price, blank until the profile is known, otherwise the
	-- price -- green when the balance covers it, grey when it does not, and
	-- in plain ink until the balance itself has arrived. The Robux pill sits
	-- at the top of the stack while this one shows and in the middle alone.
	local mp = entry.moneyPill :: ImageButton
	local price = entry.moneyPrice
	if owned or price == nil then
		mp.Visible = false
	else
		mp.Visible = true
		if not self.known then
			setText(entry.moneyState, "")
			entry.moneyStroke.Color = kit.LINE
			entry.moneyStroke.Transparency = 0.35
		else
			setText(entry.moneyState, comma(price) .. " MONEY")
			local balance = self.money
			if balance == nil then
				entry.moneyState.TextColor3 = kit.INK
				entry.moneyStroke.Color = kit.LINE
				entry.moneyStroke.Transparency = 0.35
			elseif balance >= price then
				entry.moneyState.TextColor3 = kit.GAIN
				entry.moneyStroke.Color = kit.GAIN
				entry.moneyStroke.Transparency = 0.1
			else
				entry.moneyState.TextColor3 = kit.INK_OFF
				entry.moneyStroke.Color = kit.LINE
				entry.moneyStroke.Transparency = 0.5
			end
		end
	end
	entry.pill.Position = if mp.Visible then entry.pillBottom else entry.pillMid

	if entry.glyph then
		entry.glyph.Visible = showGlyph
		if showGlyph then
			PassShop.placeGlyph(entry)
		else
			entry.state.Position = UDim2.fromScale(0, entry.state.Position.Y.Scale)
		end
	end
end

function PassShop.repaint(self: any)
	for _, entry in self.entries do
		PassShop.paintCard(self, entry)
	end
end

-- Captured into a local before the call: `if self.onX then self.onX() end`
-- does not narrow the optional away under --!strict.
local function say(self: any, text: string)
	local fn = self.onSay
	if fn then
		fn(text)
	end
end

-- ---------------------------------------------------------------- presses --

function PassShop.press(self: any, entry: any)
	if not self.known then
		Sfx.play("Deny")
		say(self, "YOUR PROFILE HAS NOT LOADED YET.")
		return
	end

	if self.owned[entry.key] == true then
		-- Said out loud rather than silently refused, because a card that
		-- looks pressable and does nothing reads as broken.
		Sfx.play("Click")
		say(self, "YOU ALREADY OWN " .. string.upper(entry.def.name) .. ".")
		return
	end

	if not Products.isLive(Products.pass(entry.key)) or self.forSale[entry.key] == false then
		-- No Robux route today. If Money buys it, a press on the row takes
		-- that door instead of refusing (the pill itself still says SOON).
		if entry.moneyPrice ~= nil then
			PassShop.pressMoney(self, entry)
			return
		end
		Sfx.play("Deny")
		say(self, string.upper(entry.def.name) .. " IS NOT ON SALE YET.")
		return
	end

	-- THE PASS goes up the Shop remote's `pass` verb (PromptGamePassPurchase),
	-- never `buy` (PromptProductPurchase): a pass is not a developer product
	-- and the wrong verb prompts nothing whatsoever. Not painted
	-- optimistically -- the site decides, and the card flips to OWNED when
	-- the server has re-asked the site and pushed the answer back.
	Sfx.play("Coin")
	local fn = self.onPass
	if fn then
		fn(entry.key)
	end
end

-- THE MONEY PILL. Every refusal is said out loud for the same reason the
-- Robux one's are; the one this adds is the shortfall, in the pattern
-- cards' words. NOT PAINTED OPTIMISTICALLY: the balance is the server's to
-- move, and the card flips to OWNED when the server has settled it and the
-- lobby (or the attribute, in a match) has said so.
function PassShop.pressMoney(self: any, entry: any)
	if not self.known then
		Sfx.play("Deny")
		say(self, "YOUR PROFILE HAS NOT LOADED YET.")
		return
	end
	if self.owned[entry.key] == true then
		Sfx.play("Click")
		say(self, "YOU ALREADY OWN " .. string.upper(entry.def.name) .. ".")
		return
	end
	local price = entry.moneyPrice
	if price == nil or not Products.isLive(Products.pass(entry.key)) then
		Sfx.play("Deny")
		say(self, string.upper(entry.def.name) .. " IS NOT ON SALE FOR MONEY.")
		return
	end
	local balance = self.money
	if balance == nil then
		Sfx.play("Deny")
		say(self, "YOUR BALANCE HAS NOT LOADED YET.")
		return
	end
	if balance < price then
		Sfx.play("Deny")
		say(self, string.format(
			"%s COSTS %s MONEY -- YOU ARE %s SHORT.",
			string.upper(entry.def.name),
			comma(price),
			comma(price - balance)
		))
		return
	end
	Sfx.play("Coin")
	local fn = self.onMoney
	if fn then
		fn(entry.key)
	end
end

-- ------------------------------------------------------------------ state --

-- Which passes this account holds, straight off the server, which is also
-- what flips the page from "shut" to "for sale".
function PassShop.setState(self: any, owned: any)
	self.owned = type(owned) == "table" and owned or {}
	self.known = true
	PassShop.repaint(self)
end

-- What the site said: the price (nil when it gave none) and whether the pass
-- is for sale at all (nil = it did not say, taken as yes).
function PassShop.setPrice(self: any, key: string, robux: number?, forSale: boolean?)
	self.prices[key] = robux
	if forSale ~= nil then
		self.forSale[key] = forSale
	end
	PassShop.repaint(self)
end

-- The account's Money balance, whenever the page's owner learns it: the
-- lobby on load and every change, the "+" page when it opens and after a
-- buy. nil (a number that never came) leaves the pills in plain ink.
function PassShop.setMoney(self: any, amount: any)
	self.money = tonumber(amount)
	PassShop.repaint(self)
end

-- THE ARRIVAL, on a real switch only. PatternShop.paintTabs calls this on
-- every hover over the tab strip, so a page already showing is left as it is.
-- A real switch opens the sheet at its top. Hiding the page shuts its clip,
-- which stops the loop and puts every row back home at once: a clip stepping
-- under a closed shop would be a frame loop for nobody, and a page that
-- reopened mid-slide would open crooked.
function PassShop.setVisible(self: any, on: boolean)
	if on and not self.root.Visible then
		self.root.Visible = true
		PassShop.layout(self, nil)
		self.root.CanvasPosition = Vector2.new(0, 0)
		self.showGen += 1
		local gen = self.showGen
		for i, entry in self.entries do
			entry.scale.Scale = ARRIVE_FROM
			task.delay((i - 1) * ARRIVE_STEP, function()
				if self.showGen == gen and self.root.Visible and not entry.hover then
					tween(entry.scale, ARRIVE, { Scale = 1 })
				end
			end)
		end
	elseif not on then
		self.rowHover = nil
		self.root.Visible = false
		PassShop.closeDrawer(self)
	end
	self.root.Visible = on
end

return PassShop
