--!strict
-- Conquest :: LobbyUI  (client only)
--
-- The matchmaking page: three cards, one clock each, and a queue that spans
-- every server of the experience.
--
-- It is drawn in the HUD's language on purpose -- the same kit scrim and pills,
-- the same LuckiestGuy display face over GothamMedium, the same neutrals -- so
-- the page and the game read as one product rather than two. Layout is authored
-- in pixels against a 1280x720 reference and converted to UDim2 SCALE on the
-- way out (`place`), which is the standing rule for text in these games: an
-- offset layout is a postage stamp on a large monitor and unreadable on a
-- phone.
--
-- THE CLOCK RUNS LOCALLY. The server sends `remaining` whenever the board
-- changes and at most every few seconds otherwise; this module counts down
-- between updates. That is what keeps an idle page at roughly one packet every
-- five seconds instead of one a second per player.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Matchmaker = require(script.Parent.Matchmaker)
local PrivateLobby = require(script.Parent.PrivateLobby)

local LobbyUI = {}
LobbyUI.__index = LobbyUI

export type LobbyUI = typeof(setmetatable({} :: any, LobbyUI))

-- Same two weights as the HUD, and the kit's display face for anything big.
local FAMILY = Font.fromEnum(Enum.Font.GothamMedium).Family
local FONT_UI = Font.new(FAMILY, Enum.FontWeight.Medium)
local FONT_BOLD = Font.new(FAMILY, Enum.FontWeight.Bold)
local FONT_KIT = Font.new("rbxasset://fonts/families/LuckiestGuy.json", Enum.FontWeight.Regular)

-- The game's own UI kit, by the same asset ids HUD uses.
local KIT_SCRIM = "rbxassetid://120540791544567"
local PILL_JOIN = "rbxassetid://100019243626916" -- common  (green)
local PILL_LEAVE = "rbxassetid://75161385176215" -- rare    (blue)
local PILL_DEAD = "rbxassetid://96479235473118" -- ultra   (magenta), for FULL/STARTING

-- THE MAPS THEMSELVES, keyed by `CardView.map`. These are the generator's own
-- renders -- `mapgen/out/<Name>Map.png`, 880x550 -- uploaded to the creator
-- account and then RESOLVED FROM DECAL TO IMAGE: the upload hands back a
-- Decal id, and a Decal id does not render in an ImageLabel. What is stored
-- here is the underlying image, read off `Decal.Texture` after a LoadAsset.
--
-- tokyo / istanbul / venice have modules but are not in `Maps.BY_ID` yet, so
-- they are inert until the rotation picks them up, at which point they draw
-- with no further work.
local MAP_ART = {
	us = "rbxassetid://89598223345921",
	europe = "rbxassetid://74345634359792",
	china = "rbxassetid://103392032511171",
	medit = "rbxassetid://106256329253516",
	tokyo = "rbxassetid://138545822485390",
	istanbul = "rbxassetid://81959508092943",
	venice = "rbxassetid://90363138911437",
}

local INK = Color3.fromRGB(234, 240, 250)
local INK_DIM = Color3.fromRGB(178, 190, 212)
local INK_OFF = Color3.fromRGB(146, 160, 186)
local PANEL = Color3.fromRGB(15, 20, 32)
local LINE = Color3.fromRGB(52, 66, 94)
local GAIN = Color3.fromRGB(111, 217, 138)
local GOLD = Color3.fromRGB(232, 196, 110)
-- The game's desk. The page sits on the same wood the map lies on.
local DESK = Color3.fromRGB(76, 52, 36)

local KIT_SHADOW = 2

-- ---------------------------------------------------------------- motion ---

-- EVERYTHING PRESSABLE ON THIS PAGE MOVES, and the numbers are small on
-- purpose: a card is most of the screen and 2.5% of it is already a lot of
-- travel. What sells it is the asymmetry -- in fast, out slow, and the release
-- overshoots its resting size before settling. A press that eases politely
-- back to where it started reads as an animation; one that springs past reads
-- as a thing that was pushed.
local HOVER_IN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HOVER_OUT = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_IN = TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_OUT = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FLASH_OUT = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local HOVER_SCALE = 1.025
local PRESS_SCALE = 0.97

local REF_W, REF_H = 1280, 720

-- ALL OF THIS IS MEASURED OFF THE REFERENCE, not chosen. Its content column
-- runs x 60..1508 of 1546 and its rows are 20 / 113 bar / 48 / 689 cards /
-- 32 / 111 solo / 33 / 111 buttons / 35. The width fractions below reproduce
-- that exactly; the heights drop the solo band (owner: no solo, no ranked)
-- and scale what is left to 720. Both axes cannot be literal -- the reference
-- is a 1.30 window and this page is authored 16:9.
local PAGE_M = 48
local CONTENT_W = REF_W - PAGE_M * 2

local BAR_Y, BAR_H = 14, 78

-- The card block: one big card and a column of two, at the reference's own
-- 65.1 / 2.6 / 32.3 split of the content width.
local BLOCK_Y = BAR_Y + BAR_H + 33
local BTN_H = 76
local BTN_Y = REF_H - 24 - BTN_H
local BLOCK_H = BTN_Y - 22 - BLOCK_Y
local BIG_W = math.floor(CONTENT_W * 0.6512 + 0.5)
local COL_GAP = math.floor(CONTENT_W * 0.0256 + 0.5)
local SMALL_W = CONTENT_W - BIG_W - COL_GAP
local SMALL_GAP = 23
local SMALL_H = (BLOCK_H - SMALL_GAP) / 2

-- Two buttons across the same span the three occupy in the reference.
local BTN_GAP = 32
local BTN_W = (CONTENT_W - BTN_GAP) / 2

-- Card internals are in ABSOLUTE authored pixels, not fractions of the card:
-- the reference draws its map name at the same size on the big card and the
-- small ones, and a fraction would scale it with the card.
local CAP_H = 78
local PILL_H = 26

-- HOW LONG AN OPTIMISTIC PAINT OUTLIVES THE PRESS THAT MADE IT. The server
-- pushes the board the instant a join lands now, so the truth normally
-- arrives inside a couple of hundred milliseconds; this is only the ceiling
-- that stops an intent which never landed from leaving a card claiming you
-- are in a lobby you are not.
local PENDING_HOLD = 3

local MAX_FACES = 12
local TAG_MAX = 4
local NAME_MAX = 16

-- The reference's timer pill blue.
local ACCENT = Color3.fromRGB(59, 130, 246)

-- ------------------------------------------------------------- primitives --

-- Authored pixels -> Scale, against the DIRECT PARENT's reference footprint.
-- Passing the screen's size for a child of a card is the one mistake here that
-- silently shrinks something instead of erroring.
local function place(inst: GuiObject, pw: number, ph: number, x: number, y: number, w: number, h: number)
	inst.Size = UDim2.fromScale(w / pw, h / ph)
	inst.Position = UDim2.fromScale(x / pw, y / ph)
end

-- GROWING FROM THE MIDDLE. `place` authors from a top-left corner, so a
-- UIScale hung on the result would push the object down and to the right
-- instead of swelling out of its own centre -- which on a card the size of
-- half the page looks like it slid rather than lifted. Re-anchoring is one
-- conversion and nothing else on the page reads Position or AnchorPoint.
local function grower(inst: GuiObject): UIScale
	inst.AnchorPoint = Vector2.new(0.5, 0.5)
	inst.Position = UDim2.fromScale(
		inst.Position.X.Scale + inst.Size.X.Scale / 2,
		inst.Position.Y.Scale + inst.Size.Y.Scale / 2
	)
	local s = Instance.new("UIScale")
	s.Name = "Scale"
	s.Parent = inst
	return s
end

-- Starting a tween on a property cancels whatever was already running on that
-- same property, which is the whole reason these can be fired from signals
-- without any bookkeeping: a hover-out still in flight when the pointer comes
-- back is replaced rather than fought.
local function tween(inst: Instance, info: TweenInfo, props: { [string]: any })
	TweenService:Create(inst, info, props):Play()
end

-- `h` is the type size: the box is exactly one line tall and TextScaled fills
-- it, so the authored number is what renders at the reference size.
local function label(
	parent: Instance,
	name: string,
	pw: number,
	ph: number,
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3?,
	align: Enum.TextXAlignment?,
	font: Font?
): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.FontFace = font or FONT_UI
	t.TextScaled = true
	t.TextColor3 = color or INK
	t.TextXAlignment = align or Enum.TextXAlignment.Center
	t.TextYAlignment = Enum.TextYAlignment.Center
	t.Text = ""
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = math.floor(h * 4)
	c.MinTextSize = 6
	c.Parent = t
	place(t, pw, ph, x, y, w, h)
	t.Parent = parent
	return t
end

-- The kit's label: the same string twice, black first and two pixels lower,
-- white over it. SIBLINGS, not parent and child -- a child always draws above
-- its parent, so a nested shadow would cover the text it is shadowing.
local function kitLabel(
	parent: Instance,
	name: string,
	pw: number,
	ph: number,
	x: number,
	y: number,
	w: number,
	h: number,
	tint: Color3?
): TextLabel
	local sh = label(parent, name .. "Sh", pw, ph, x, y + KIT_SHADOW, w, h, Color3.new(), Enum.TextXAlignment.Center, FONT_KIT)
	sh.ZIndex = 4
	local top = label(parent, name, pw, ph, x, y, w, h, Color3.new(1, 1, 1), Enum.TextXAlignment.Center, FONT_KIT)
	top.ZIndex = 5
	if tint then
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Color = ColorSequence.new(Color3.new(1, 1, 1), tint)
		g.Parent = top
	end
	return top
end

-- Writes a kit label and its shadow together. Setting `.Text` directly leaves
-- the black copy reading whatever it said last update.
local function kitSet(t: TextLabel, s: string)
	if t.Text ~= s then
		t.Text = s
		local sh = t.Parent and t.Parent:FindFirstChild(t.Name .. "Sh")
		if sh then
			(sh :: TextLabel).Text = s
		end
	end
end

local function setText(t: TextLabel, s: string)
	if t.Text ~= s then
		t.Text = s
	end
end

-- An editable field. Clamped AS YOU TYPE rather than on focus-lost: a name
-- that silently truncates after you look away reads as the game eating your
-- input. Writing `.Text` from inside its own changed signal re-fires it once
-- and then stops, because the second pass has nothing left to change.
-- An editable field, drawn the way the reference draws them: no box at all.
-- The clan tag gets an underline and the name gets nothing -- both are
-- prefilled, so there is no empty target to discover. Clamped AS YOU TYPE:
-- a name that truncates after you look away reads as the game eating input.
-- Writing `.Text` from inside its own changed signal re-fires it once and
-- then stops, because the second pass has nothing left to change.
local function field(
	parent: Instance,
	name: string,
	pw: number,
	ph: number,
	x: number,
	y: number,
	w: number,
	h: number,
	placeholder: string,
	maxLen: number,
	upper: boolean,
	align: Enum.TextXAlignment,
	underline: boolean
): TextBox
	local box = Instance.new("TextBox")
	box.Name = name
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Text = ""
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = INK_OFF
	box.TextColor3 = INK
	box.FontFace = FONT_BOLD
	box.TextScaled = true
	box.TextXAlignment = align
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = math.floor(h * 1.1)
	c.MinTextSize = 6
	c.Parent = box
	place(box, pw, ph, x, y, w, h)
	box.Parent = parent

	-- THE UNDERLINE IS THE TARGET, and now it is also the affordance. The
	-- reference draws one under the clan tag and nothing under the name, and
	-- that stays true AT REST -- the name's rule sits at full transparency
	-- until the pointer or the caret finds it, so the page looks exactly as
	-- authored and still admits that both fields can be typed in.
	local rest = underline and 0.25 or 1
	local rule = Instance.new("Frame")
	rule.Name = name .. "Rule"
	rule.BackgroundColor3 = INK_OFF
	rule.BackgroundTransparency = rest
	rule.BorderSizePixel = 0
	place(rule, pw, ph, x, y + h + 2, w, 2)
	rule.Parent = parent

	local hovered, focused = false, false
	local function litRule(info: TweenInfo)
		tween(rule, info, {
			BackgroundColor3 = focused and ACCENT or INK_OFF,
			BackgroundTransparency = (focused or hovered) and 0 or rest,
		})
	end
	box.MouseEnter:Connect(function()
		hovered = true
		litRule(HOVER_IN)
	end)
	box.MouseLeave:Connect(function()
		hovered = false
		litRule(HOVER_OUT)
	end)
	box.Focused:Connect(function()
		focused = true
		litRule(HOVER_IN)
	end)
	box.FocusLost:Connect(function()
		focused = false
		litRule(HOVER_OUT)
	end)

	box:GetPropertyChangedSignal("Text"):Connect(function()
		local s = box.Text
		if upper then
			s = string.upper(s)
		end
		-- Letters, digits, space, underscore and hyphen. A clan tag full of
		-- punctuation is how you get a nation label nobody can read.
		s = string.gsub(s, "[^%w _%-]", "")
		if #s > maxLen then
			s = string.sub(s, 1, maxLen)
		end
		if s ~= box.Text then
			box.Text = s
		end
	end)
	return box
end

-- A rounded chip. The reference floats these over the map art: the timer at
-- top-right, the player count above the caption band, the state at top-left.
local function chip(
	parent: Instance,
	name: string,
	pw: number,
	ph: number,
	x: number,
	y: number,
	w: number,
	h: number,
	bg: Color3,
	alpha: number
): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = bg
	f.BackgroundTransparency = alpha
	f.BorderSizePixel = 0
	place(f, pw, ph, x, y, w, h)
	f.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = f
	return f
end


-- The kit's button with a caption, same shape as a card's JOIN.
-- The reference's bottom buttons are flat dark panels with a plain bold
-- caption -- the same panel the top bar is made of, at button size. The kit's
-- coloured pills belong to a card's JOIN, and there is no JOIN pill any more.
local function pillButton(
	parent: Instance,
	name: string,
	pw: number,
	ph: number,
	x: number,
	y: number,
	w: number,
	h: number,
	text: string
): ImageButton
	local b = Instance.new("ImageButton")
	b.Name = name
	b.Image = ""
	b.BackgroundColor3 = PANEL
	b.BackgroundTransparency = 0.06
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	place(b, pw, ph, x, y, w, h)
	b.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Color = LINE
	stroke.Thickness = 1.6
	stroke.Transparency = 0.35
	stroke.Parent = b
	local scrim = Instance.new("ImageLabel")
	scrim.Name = "Scrim"
	scrim.BackgroundTransparency = 1
	scrim.Image = KIT_SCRIM
	scrim.ScaleType = Enum.ScaleType.Stretch
	scrim.ImageTransparency = 0.25
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = b

	local caption = label(b, "Caption", w, h, 0, (h - 20) / 2, w, 20, INK, Enum.TextXAlignment.Center, FONT_BOLD)
	caption.ZIndex = 3
	setText(caption, text)

	-- The press's own light, over everything including the caption -- a flash
	-- that stops at the edge of the text is a rectangle, not a flash. It is
	-- the only feedback a button gets whose whole result is a toast.
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = 4
	flash.Parent = b
	local flashCorner = Instance.new("UICorner")
	flashCorner.CornerRadius = UDim.new(0, 10)
	flashCorner.Parent = flash

	local scale = grower(b)
	local hovered, held = false, false

	local function paint(info: TweenInfo)
		tween(scale, info, { Scale = held and PRESS_SCALE or (hovered and HOVER_SCALE or 1) })
		tween(stroke, info, { Transparency = hovered and 0.05 or 0.35 })
		tween(b, info, { BackgroundTransparency = hovered and 0 or 0.06 })
		tween(caption, info, { TextColor3 = hovered and Color3.new(1, 1, 1) or INK })
	end

	b.MouseEnter:Connect(function()
		hovered = true
		paint(HOVER_IN)
	end)
	-- The pointer leaving mid-press has to clear `held` too, or the button
	-- stays squashed with nothing left to release it.
	b.MouseLeave:Connect(function()
		hovered, held = false, false
		paint(HOVER_OUT)
	end)
	b.MouseButton1Down:Connect(function()
		held = true
		paint(PRESS_IN)
		flash.BackgroundTransparency = 0.86
		tween(flash, FLASH_OUT, { BackgroundTransparency = 1 })
	end)
	b.MouseButton1Up:Connect(function()
		held = false
		paint(PRESS_OUT)
	end)
	return b
end


-- ------------------------------------------------------------------ card ---

-- THE CARD IS THE BUTTON. In the reference there is no JOIN pill: the map art
-- fills the card, the name and mode sit in a gradient band across the bottom,
-- a timer chip floats top-right and the player count sits just above the band.
-- The top-LEFT chip is where the reference puts "RANDOM SPAWN"; this page uses
-- that same slot for the state word, which is the one thing the reference does
-- not have to say and this one does.
--
-- Sized by the caller, because the block is one big card and two small ones.
local function buildCard(root: Frame, index: number, x: number, y: number, w: number, h: number): any
	local slot = Matchmaker.SLOTS[index]

	local card = Instance.new("ImageButton")
	card.Name = "Card" .. index
	card.BackgroundColor3 = PANEL
	card.BackgroundTransparency = 0.06
	card.BorderSizePixel = 0
	card.AutoButtonColor = false
	card.Image = ""
	card.ClipsDescendants = true
	place(card, REF_W, REF_H, x, y, w, h)
	card.Parent = root

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = LINE
	stroke.Thickness = 1.6
	stroke.Transparency = 0.35
	stroke.Parent = card

	-- THE MAP, filling the card exactly as the reference does. CROP, not
	-- Stretch: the renders are 880x550 and no card is that shape, so stretching
	-- would squash the coastline -- the one thing on a lobby card a player
	-- actually recognises.
	local art = Instance.new("ImageLabel")
	art.Name = "Art"
	art.BackgroundTransparency = 1
	art.Image = ""
	art.ScaleType = Enum.ScaleType.Crop
	art.Size = UDim2.fromScale(1, 1)
	art.ZIndex = 0
	art.Parent = card

	-- The kit's panel art stays, but only just: it is a flat 50% black and at
	-- the old 0.25 it turned every map into mud. Over art it is a unifying
	-- tint; on a card with no art it is still the panel it always was.
	local scrim = Instance.new("ImageLabel")
	scrim.Name = "Scrim"
	scrim.BackgroundTransparency = 1
	scrim.Image = KIT_SCRIM
	scrim.ScaleType = Enum.ScaleType.Stretch
	scrim.ImageTransparency = 0.82
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = card

	-- The caption band. A gradient, not a flat fill: the reference fades the
	-- art out under the text instead of cutting it with an edge.
	local band = Instance.new("Frame")
	band.Name = "Band"
	band.BackgroundColor3 = Color3.fromRGB(6, 9, 16)
	band.BorderSizePixel = 0
	place(band, w, h, 0, h - CAP_H, w, CAP_H)
	band.Parent = card
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0.25),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	fade.Parent = band

	-- Map name big, mode small under it, both left-aligned against the band's
	-- own left edge -- the reference's exact arrangement.
	local mapName = label(card, "Map", w, h, 16, h - CAP_H + 22, w - 32, 26, INK, Enum.TextXAlignment.Left, FONT_BOLD)
	local modeName = label(card, "Mode", w, h, 16, h - CAP_H + 54, w - 32, 14, INK_DIM, Enum.TextXAlignment.Left)
	setText(mapName, string.upper(slot.name))

	-- Timer, top-right.
	local clockChip = chip(card, "ClockChip", w, h, w - 104, 12, 92, PILL_H, ACCENT, 0)
	local clock = label(clockChip, "Clock", 92, PILL_H, 0, 5, 92, 16, Color3.fromRGB(255, 255, 255), Enum.TextXAlignment.Center, FONT_BOLD)

	-- State, top-left -- the reference's "RANDOM SPAWN" slot.
	local statePill = chip(card, "StateChip", w, h, 12, 12, 104, PILL_H, ACCENT, 0)
	local stateText = label(statePill, "State", 104, PILL_H, 0, 5, 104, 16, Color3.fromRGB(8, 12, 20), Enum.TextXAlignment.Center, FONT_BOLD)

	-- Player count, sitting just above the band on the right.
	local countChip = chip(card, "CountChip", w, h, w - 108, h - CAP_H - 34, 96, 24, Color3.fromRGB(6, 9, 16), 0.12)
	local countText = label(countChip, "Count", 96, 24, 0, 5, 96, 14, INK, Enum.TextXAlignment.Center, FONT_BOLD)

	-- Kept, hidden: `paintFaces` still writes into it and the reference has no
	-- face row. Deleting it would mean touching that function too.
	local faces = Instance.new("Frame")
	faces.Name = "Faces"
	faces.BackgroundTransparency = 1
	faces.Visible = false
	place(faces, w, h, 16, h - CAP_H - 34, 120, 24)
	faces.Parent = card
	local flow = Instance.new("UIListLayout")
	flow.FillDirection = Enum.FillDirection.Horizontal
	flow.VerticalAlignment = Enum.VerticalAlignment.Center
	flow.SortOrder = Enum.SortOrder.LayoutOrder
	flow.Padding = UDim.new(0.012, 0)
	flow.Parent = faces

	-- Above everything the card draws, so the whole thing whitens at once.
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.ZIndex = 8
	flash.Parent = card
	local flashCorner = Instance.new("UICorner")
	flashCorner.CornerRadius = UDim.new(0, 10)
	flashCorner.Parent = flash

	-- LAST, because `grower` reads the position `place` gave the card.
	local scale = grower(card)

	return {
		slot = index,
		key = slot.key,
		card = card,
		art = art,
		mapName = mapName,
		modeName = modeName,
		clock = clock,
		count = countText,
		faces = faces,
		button = card,
		statePill = statePill,
		stateText = stateText,
		stroke = stroke,
		scrim = scrim,
		scale = scale,
		flash = flash,
		-- Local countdown state. `remaining` is the last figure the server
		-- sent and `at` is when it arrived; the display is the difference.
		remaining = Matchmaker.COUNTDOWN,
		at = os.clock(),
		state = "open",
		mine = false,
		full = false,
		faceKey = "",
		-- The board's own numbers, kept as numbers: `paintCard` has to be able
		-- to redraw the card from a PRESS, with no board in hand.
		n = 0,
		cap = slot.cap,
		-- What this client believes about its own membership between the press
		-- and the server's answer. nil means "the board is the truth".
		pending = nil,
		pendingUntil = 0,
		-- Pointer state. `lifted` is what the card is CURRENTLY doing, so a
		-- board arriving every second does not restart the hover tween.
		hover = false,
		held = false,
		lifted = false,
		shownLive = false,
		shownMine = false,
		shownFull = false,
	}
end


-- ----------------------------------------------------------------- paint ---

-- EVERYTHING ON A CARD THAT ANSWERS "what will pressing this do". Split out of
-- `setBoard` because the press itself draws it now: an intent is a round trip
-- to a MemoryStore write and back, and a button that does nothing for a round
-- trip is a button that gets pressed again.
--
-- `entry.pending` is this client's belief about its OWN membership -- true
-- straight after a press, nil once the board agrees or the hold runs out. It
-- moves exactly one seat, its own; everyone else's count is the server's.
-- THE CARD'S MOTION, which is deliberately not the same thing as what the card
-- SAYS. `paintCard` is called by every board that arrives; the lift and the
-- press spring must not restart once a second, so this is only called when the
-- state it draws has actually changed, or by the pointer itself.
--
-- A card that cannot be pressed does not lift. That is the page answering
-- "will this do anything" before you commit to finding out.
local function motion(entry: any, info: TweenInfo)
	local lift = entry.hover and entry.shownLive
	tween(entry.scale, info, {
		Scale = entry.held and PRESS_SCALE or (lift and HOVER_SCALE or 1),
	})
	-- The kit scrim is a flat black wash over the map art. Thinning it on
	-- hover is what makes the coastline under the pointer brighten.
	tween(entry.scrim, info, { ImageTransparency = lift and 0.92 or 0.82 })
	-- A lifted card overlaps its neighbours, so it has to be drawn over them.
	entry.card.ZIndex = lift and 2 or 1
end

-- Only ever fired by a press that DID something. A full card still moves under
-- the pointer -- the press happened -- but it does not flash, because nothing
-- came of it.
local function flashCard(entry: any)
	entry.flash.BackgroundTransparency = 0.86
	tween(entry.flash, FLASH_OUT, { BackgroundTransparency = 1 })
end

local function paintCard(entry: any)
	local mine, count = entry.mine, entry.n
	if entry.pending ~= nil and entry.pending ~= mine then
		mine = entry.pending
		count = math.max(0, count + (entry.pending and 1 or -1))
	end
	local full = count >= entry.cap and not mine
	entry.shownMine = mine
	entry.shownFull = full

	setText(entry.count, string.format("%d / %d", count, entry.cap))

	-- FOUR STATES, in the chip the reference uses for "RANDOM SPAWN". The card
	-- is the button now, so the word is the only thing left that says whether
	-- pressing it will do anything.
	local word, tint
	if entry.state ~= "open" then
		word, tint = "STARTING", INK_OFF
	elseif mine then
		word, tint = "JOINED", GAIN
	elseif full then
		word, tint = "FULL", INK_OFF
	else
		word, tint = "JOIN", ACCENT
	end
	setText(entry.stateText, word)
	entry.statePill.BackgroundColor3 = tint

	-- THE STROKE CARRIES TWO THINGS AT ONCE: green means you are in this one,
	-- and bright means the pointer is on it AND pressing would do something.
	-- A lobby that is full lights up for nobody.
	entry.shownLive = entry.state == "open" and (mine or not full)
	local base = mine and 0.1 or 0.35
	local lit = entry.hover and entry.shownLive
	tween(entry.stroke, entry.hover and HOVER_IN or HOVER_OUT, {
		Color = mine and GAIN or LINE,
		Transparency = lit and base * 0.25 or base,
	})

	-- Only when it CHANGES -- see motion.
	local lift = entry.hover and entry.shownLive
	if lift ~= entry.lifted then
		entry.lifted = lift
		motion(entry, lift and HOVER_IN or HOVER_OUT)
	end
end

-- The press, drawn before the server has heard about it.
local function press(entry: any, joining: boolean)
	entry.pending = joining
	entry.pendingUntil = os.clock() + PENDING_HOLD
	-- The countdown starts on the FIRST JOIN, server-side -- so start it here
	-- too. A clock that visibly begins moving is the loudest confirmation this
	-- page can give, and it costs nothing when the guess is wrong: the next
	-- board overwrites it.
	if joining and entry.waiting then
		entry.waiting = false
		entry.remaining = Matchmaker.COUNTDOWN
		entry.at = os.clock()
	end
	paintCard(entry)
end


-- ------------------------------------------------------------ room panel ---

-- THE PRIVATE LOBBY, as one modal over the page rather than a second screen.
-- The board behind it does not stop existing while you are in a room -- its
-- clocks keep running and its cards keep filling -- and a full-screen takeover
-- would make backing out of a room feel like leaving the game.
--
-- Two views in one panel: the code box you type into, and the room you end up
-- in. They never both make sense, so they are never both up.
local PANEL_W, PANEL_H = 720, 560
local PANEL_X = (REF_W - PANEL_W) / 2
local PANEL_Y = (REF_H - PANEL_H) / 2

-- One settings row, authored against its own 640x44 box.
local ROW_W, ROW_H = 640, 44
local ROW_X = (PANEL_W - ROW_W) / 2
local ROW_TOP = 122
local ROW_GAP = 12

-- HOW LONG A LEAVE OUTLIVES THE PRESS. It has to exceed the client's own
-- one-a-second intent gate plus the round trip behind it, or a room packet
-- already in flight when LEAVE was pressed re-opens the panel the press just
-- closed -- which reads as the button not working.
local LEAVE_HOLD = 3

-- ...and how long the placeholder panel a CREATE opens waits for its record
-- before giving up. The server toasts every failure it knows about; this is
-- for the ones it does not survive to report.
local CREATE_HOLD = 8

-- Two buttons across the panel, the same span the page's own pair occupies.
local PBTN_W, PBTN_H = 240, 64
local PBTN_Y = PANEL_H - 40 - PBTN_H
local PBTN_L = (PANEL_W - PBTN_W * 2 - 20) / 2
local PBTN_R = PBTN_L + PBTN_W + 20

local function buildRoomPanel(self: any, parent: Instance)
	-- The scrim is `Active`, which is the whole of its job besides dimming:
	-- it eats every click that misses the panel, so a card underneath cannot
	-- be pressed through a modal that is covering it.
	local shade = Instance.new("Frame")
	shade.Name = "RoomShade"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(4, 6, 11)
	shade.BackgroundTransparency = 0.35
	shade.BorderSizePixel = 0
	shade.Active = true
	shade.Visible = false
	shade.ZIndex = 20
	shade.Parent = parent
	self.shade = shade

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.BackgroundColor3 = PANEL
	panel.BackgroundTransparency = 0.02
	panel.BorderSizePixel = 0
	place(panel, REF_W, REF_H, PANEL_X, PANEL_Y, PANEL_W, PANEL_H)
	panel.Parent = shade
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 12)
	pc.Parent = panel
	local ps = Instance.new("UIStroke")
	ps.Color = LINE
	ps.Thickness = 1.6
	ps.Transparency = 0.25
	ps.Parent = panel
	local pscrim = Instance.new("ImageLabel")
	pscrim.Name = "Scrim"
	pscrim.BackgroundTransparency = 1
	pscrim.Image = KIT_SCRIM
	pscrim.ScaleType = Enum.ScaleType.Stretch
	pscrim.ImageTransparency = 0.3
	pscrim.Size = UDim2.fromScale(1, 1)
	pscrim.ZIndex = 0
	pscrim.Parent = panel

	-- ------------------------------------------------------- join view --

	local jv = Instance.new("Frame")
	jv.Name = "JoinView"
	jv.BackgroundTransparency = 1
	jv.Size = UDim2.fromScale(1, 1)
	jv.Visible = false
	jv.Parent = panel
	self.joinView = jv

	kitSet(kitLabel(jv, "JoinTitle", PANEL_W, PANEL_H, 0, 46, PANEL_W, 46, GOLD), "JOIN A LOBBY")

	-- THE BOX IS THE PAGE. Four digits at LuckiestGuy's size, with a rule
	-- under them and nothing else to look at -- there is exactly one thing to
	-- do here and a caption explaining it would be a caption explaining it.
	local box = Instance.new("TextBox")
	box.Name = "Code"
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Text = ""
	box.PlaceholderText = "0000"
	box.PlaceholderColor3 = INK_OFF
	box.TextColor3 = INK
	box.FontFace = FONT_KIT
	box.TextScaled = true
	box.TextXAlignment = Enum.TextXAlignment.Center
	local bc = Instance.new("UITextSizeConstraint")
	bc.MaxTextSize = 110
	bc.MinTextSize = 12
	bc.Parent = box
	place(box, PANEL_W, PANEL_H, 160, 152, 400, 104)
	box.Parent = jv
	self.codeBox = box

	local rule = Instance.new("Frame")
	rule.Name = "CodeRule"
	rule.BackgroundColor3 = INK_OFF
	rule.BackgroundTransparency = 0.4
	rule.BorderSizePixel = 0
	place(rule, PANEL_W, PANEL_H, 160, 266, 400, 3)
	rule.Parent = jv

	-- Clamped AS YOU TYPE, digits only. Writing `.Text` from inside its own
	-- changed signal re-fires it once and then stops, because the second pass
	-- has nothing left to change.
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local s = string.gsub(box.Text, "%D", "")
		if #s > 4 then
			s = string.sub(s, 1, 4)
		end
		if s ~= box.Text then
			box.Text = s
		end
		if self.joinErr then
			setText(self.joinErr, "")
		end
	end)

	self.joinErr = label(jv, "Err", PANEL_W, PANEL_H, 40, 300, PANEL_W - 80, 18, GOLD)

	local joinGo = pillButton(jv, "Go", PANEL_W, PANEL_H, PBTN_L, PBTN_Y, PBTN_W, PBTN_H, "JOIN")
	local joinBack = pillButton(jv, "Back", PANEL_W, PANEL_H, PBTN_R, PBTN_Y, PBTN_W, PBTN_H, "CANCEL")

	local function submit()
		local code = PrivateLobby.normalise(box.Text)
		if not code then
			setText(self.joinErr, "A LOBBY CODE IS FOUR DIGITS")
			return
		end
		setText(self.joinErr, "")
		if self.onRoomJoin then
			self.onRoomJoin(code)
		end
	end
	joinGo.Activated:Connect(submit)
	-- Enter submits. A four-digit field you have to reach for the mouse after
	-- is a four-digit field nobody finishes with the keyboard.
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			submit()
		end
	end)
	joinBack.Activated:Connect(function()
		LobbyUI.closePanel(self)
	end)

	-- ------------------------------------------------------- room view --

	local rv = Instance.new("Frame")
	rv.Name = "RoomView"
	rv.BackgroundTransparency = 1
	rv.Size = UDim2.fromScale(1, 1)
	rv.Visible = false
	rv.Parent = panel
	self.roomView = rv

	-- THE CODE IS THE HEADLINE and it carries no label. Four digits at the top
	-- of a lobby panel are the thing you read out loud to somebody; a line
	-- underneath saying SHARE THIS CODE would only be saying it again.
	self.roomCode = kitLabel(rv, "Code", PANEL_W, PANEL_H, 0, 28, PANEL_W, 66, GOLD)

	self.rows = {}
	for i, f in PrivateLobby.FIELDS do
		local y = ROW_TOP + (i - 1) * (ROW_H + ROW_GAP)
		local row = Instance.new("Frame")
		row.Name = "Row" .. f.key
		row.BackgroundColor3 = Color3.fromRGB(9, 13, 22)
		row.BackgroundTransparency = 0.35
		row.BorderSizePixel = 0
		place(row, PANEL_W, PANEL_H, ROW_X, y, ROW_W, ROW_H)
		row.Parent = rv
		local rc = Instance.new("UICorner")
		rc.CornerRadius = UDim.new(0, 8)
		rc.Parent = row

		setText(label(row, "Name", ROW_W, ROW_H, 18, 14, 260, 16, INK_DIM, Enum.TextXAlignment.Left), f.label)
		local value = label(row, "Value", ROW_W, ROW_H, 348, 13, 228, 18, INK, Enum.TextXAlignment.Center, FONT_BOLD)
		local dec = pillButton(row, "Dec", ROW_W, ROW_H, 300, 2, 40, 40, "<")
		local inc = pillButton(row, "Inc", ROW_W, ROW_H, 584, 2, 40, 40, ">")

		-- WRAPS, because a four-option menu with a dead end at each side makes
		-- you learn which way is shorter. `PrivateLobby.count` is the only
		-- thing that knows how long a menu is, on both sides of the wire.
		local function stepper(delta: number)
			return function()
				local view = self.room
				if not view or not view.isHost or view.state ~= "open" then
					return
				end
				local n = PrivateLobby.count(f.key)
				local cur = self.roomSettings[f.slot] or 1
				self.roomSettings[f.slot] = ((cur - 1 + delta) % n) + 1
				-- Believed locally for a moment -- see setRoom. A stepper that
				-- waits for a MemoryStore write before it moves is a stepper
				-- you press twice.
				self.setAt = os.clock()
				LobbyUI.paintRoom(self)
				if self.onRoomSettings then
					self.onRoomSettings(table.clone(self.roomSettings))
				end
			end
		end
		dec.Activated:Connect(stepper(-1))
		inc.Activated:Connect(stepper(1))

		self.rows[i] = { row = row, value = value, dec = dec, inc = inc }
	end

	-- The roster: the same avatar heads the board's cards were built to show,
	-- and the count beside them.
	local rosterY = ROW_TOP + #PrivateLobby.FIELDS * (ROW_H + ROW_GAP) + 8
	local faces = Instance.new("Frame")
	faces.Name = "Faces"
	faces.BackgroundTransparency = 1
	place(faces, PANEL_W, PANEL_H, ROW_X, rosterY, 420, 40)
	faces.Parent = rv
	-- `paintFaces` wants an entry-shaped table and nothing more of one.
	self.roomRoster = { faces = faces, faceKey = "" }
	self.roomCount = label(rv, "Count", PANEL_W, PANEL_H, PANEL_W - ROW_X - 160, rosterY + 11,
		160, 18, INK_DIM, Enum.TextXAlignment.Right, FONT_BOLD)

	self.startButton = pillButton(rv, "Start", PANEL_W, PANEL_H, PBTN_L, PBTN_Y, PBTN_W, PBTN_H, "START")
	self.waitLabel = label(rv, "Wait", PANEL_W, PANEL_H, PBTN_L, PBTN_Y + (PBTN_H - 18) / 2,
		PBTN_W, 18, INK_OFF, Enum.TextXAlignment.Center, FONT_BOLD)
	local leave = pillButton(rv, "Leave", PANEL_W, PANEL_H, PBTN_R, PBTN_Y, PBTN_W, PBTN_H, "LEAVE")

	self.startButton.Activated:Connect(function()
		local view = self.room
		if not view or not view.isHost or view.state ~= "open" then
			return
		end
		setText(self.startButton.Caption, "STARTING")
		if self.onRoomStart then
			self.onRoomStart()
		end
	end)
	leave.Activated:Connect(function()
		-- Closes on the press. The server's confirmation is a round trip away
		-- and there is nothing on this panel worth looking at while it lands.
		-- Which room, and when, so `setRoom` can tell a stale packet about
		-- THIS room from a fresh one about a different one.
		self.leftCode = self.room and self.room.code or nil
		self.leftAt = os.clock()
		LobbyUI.closePanel(self)
		if self.onRoomLeave then
			self.onRoomLeave()
		end
	end)
end


-- ------------------------------------------------------------------- new ---

function LobbyUI.new(parent: Instance, myUserId: number): LobbyUI
	local self = setmetatable({}, LobbyUI)
	self.myUserId = myUserId
	-- The settings the CREATE button will send, and the ones a host's steppers
	-- write into. Kept here rather than read off the record every frame so a
	-- press can be believed before the server has heard about it; `setAt` is
	-- when it was last touched locally. See setRoom.
	self.roomSettings = PrivateLobby.defaults()
	self.setAt = 0
	self.room = nil :: any
	-- The LEAVE guard, and the placeholder panel's clock. See setRoom.
	self.leftCode = nil :: string?
	self.leftAt = 0
	self.pendingAt = 0
	self.onJoin = nil :: ((string) -> ())?
	self.onLeave = nil :: (() -> ())?
	-- THE PRIVATE-LOBBY HALF. LobbyClient assigns all five, and every one of
	-- them is a MemoryStore write on the far side -- which is why they go out
	-- through its one-a-second gate rather than straight down the remote.
	self.onCreate = nil :: ((...any) -> ())?
	self.onRoomJoin = nil :: ((string) -> ())?
	self.onRoomLeave = nil :: (() -> ())?
	self.onRoomSettings = nil :: ((...any) -> ())?
	self.onRoomStart = nil :: (() -> ())?

	local root = Instance.new("Frame")
	root.Name = "Page"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = DESK
	root.BorderSizePixel = 0
	root.Parent = parent
	self.root = root

	-- A dark wash over the wood so the cards' own panels still read as panels.
	local wash = Instance.new("Frame")
	wash.Name = "Wash"
	wash.Size = UDim2.fromScale(1, 1)
	wash.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
	wash.BackgroundTransparency = 0.42
	wash.BorderSizePixel = 0
	wash.Parent = root

	-- ------------------------------------------------------------ top bar --
	-- The reference has no page title and no strapline: the bar IS the header.
	-- Left group is the identity (its "FLAG", the tag, then the name); the
	-- right of the same bar is where it puts Verified / COSMETICS, so the
	-- game's own name takes that slot rather than a heading nothing needs.
	local bar = Instance.new("Frame")
	bar.Name = "TopBar"
	bar.BackgroundColor3 = PANEL
	bar.BackgroundTransparency = 0.06
	bar.BorderSizePixel = 0
	place(bar, REF_W, REF_H, PAGE_M, BAR_Y, CONTENT_W, BAR_H)
	bar.Parent = root
	local barCorner = Instance.new("UICorner")
	barCorner.CornerRadius = UDim.new(0, 10)
	barCorner.Parent = bar
	local barStroke = Instance.new("UIStroke")
	barStroke.Color = LINE
	barStroke.Thickness = 1.6
	barStroke.Transparency = 0.35
	barStroke.Parent = bar
	local barScrim = Instance.new("ImageLabel")
	barScrim.Name = "Scrim"
	barScrim.BackgroundTransparency = 1
	barScrim.Image = KIT_SCRIM
	barScrim.ScaleType = Enum.ScaleType.Stretch
	barScrim.ImageTransparency = 0.25
	barScrim.Size = UDim2.fromScale(1, 1)
	barScrim.ZIndex = 0
	barScrim.Parent = bar

	setText(label(bar, "TagCap", CONTENT_W, BAR_H, 24, 32, 84, 13, INK_OFF, Enum.TextXAlignment.Left), "CLAN TAG")
	self.tagBox = field(bar, "Tag", CONTENT_W, BAR_H, 124, 20, 118, 34, "TAG", TAG_MAX, true, Enum.TextXAlignment.Center, true)
	self.nameBox = field(bar, "Name", CONTENT_W, BAR_H, 268, 20, 460, 36, "COMMANDER", NAME_MAX, false, Enum.TextXAlignment.Left, false)

	kitSet(kitLabel(bar, "Brand", CONTENT_W, BAR_H, CONTENT_W - 300, 20, 276, 34, GOLD), "CONQUEST")

	-- Prefilled with the Roblox display name, which is the answer for almost
	-- everyone -- an empty required field at the top of a menu is a chore.
	local me = Players.LocalPlayer
	if me then
		self.nameBox.Text = string.sub(me.DisplayName, 1, NAME_MAX)
	end


	-- ONE BIG CARD AND A COLUMN OF TWO, which is the reference's whole layout
	-- and the thing a row of three equal cards was not.
	local GEOM = {
		{ PAGE_M, BLOCK_Y, BIG_W, BLOCK_H },
		{ PAGE_M + BIG_W + COL_GAP, BLOCK_Y, SMALL_W, SMALL_H },
		{ PAGE_M + BIG_W + COL_GAP, BLOCK_Y + SMALL_H + SMALL_GAP, SMALL_W, SMALL_H },
	}
	self.cards = {}
	for i in Matchmaker.SLOTS do
		local g = GEOM[i] or GEOM[3]
		local entry = buildCard(root, i, g[1], g[2], g[3], g[4])
		self.cards[i] = entry
		-- PAINT FIRST, THEN TELL THE SERVER. Reading `shownMine` rather than
		-- `mine` is what makes a second press mean "leave" immediately instead
		-- of re-sending the join the page is already showing.
		entry.button.Activated:Connect(function()
			if entry.state ~= "open" then
				return
			end
			if entry.shownMine then
				press(entry, false)
				flashCard(entry)
				if self.onLeave then
					self.onLeave()
				end
			elseif not entry.shownFull then
				press(entry, true)
				flashCard(entry)
				if self.onJoin then
					self.onJoin(entry.key)
				end
			end
		end)

		-- Hover is the only thing that says "pressable" before the press, and
		-- the cards were the one control on this page without it.
		entry.card.MouseEnter:Connect(function()
			entry.hover = true
			paintCard(entry)
		end)
		-- Leaving mid-press clears the hold as well, or the card stays
		-- squashed with nothing left to release it.
		entry.card.MouseLeave:Connect(function()
			entry.hover = false
			entry.held = false
			paintCard(entry)
			motion(entry, HOVER_OUT)
		end)
		-- THE PRESS ITSELF MOVES THE CARD, whatever the card thinks about it.
		-- Pressing FULL is still a press and still gets an answer; it just
		-- does not get the flash.
		entry.card.MouseButton1Down:Connect(function()
			entry.held = true
			motion(entry, PRESS_IN)
		end)
		entry.card.MouseButton1Up:Connect(function()
			entry.held = false
			motion(entry, PRESS_OUT)
		end)
	end


	-- CREATE LOBBY / JOIN LOBBY, across the same span the reference gives its
	-- three. No SOLO and no RANKED: a solo button on a page whose whole point
	-- is filling a lobby is a way out of the thing you came for, and there is
	-- no ranked ladder to enter.
	self.createButton = pillButton(root, "CreateLobby", REF_W, REF_H,
		PAGE_M, BTN_Y, BTN_W, BTN_H, "CREATE LOBBY")
	self.joinButton = pillButton(root, "JoinLobby", REF_W, REF_H,
		PAGE_M + BTN_W + BTN_GAP, BTN_Y, BTN_W, BTN_H, "JOIN LOBBY")

	-- CREATE goes straight out with whatever settings this page is holding --
	-- there is nothing to configure until a room exists to configure, and a
	-- form in front of the button would be a form in front of the button. The
	-- room panel that opens on the way back is where the dials live.
	self.createButton.Activated:Connect(function()
		if not self.onCreate then
			return
		end
		-- OPEN BEFORE THERE IS A ROOM TO OPEN. Creating one is a MemoryStore
		-- write behind the same one-a-second gate everything else goes
		-- through, and a button that does nothing for that long is the exact
		-- complaint the board's cards were fixed for. Everything on the panel
		-- is already known except the code, which reads as blanks until the
		-- record comes back with it.
		LobbyUI.openPending(self)
		self.onCreate(table.clone(self.roomSettings))
	end)
	self.joinButton.Activated:Connect(function()
		LobbyUI.openJoin(self)
	end)

	-- Only ever visible while a toast is up; the reference has nothing here.
	self.toastLabel = label(root, "Toast", REF_W, REF_H, PAGE_M, BTN_Y - 22, CONTENT_W, 16, GOLD)
	self.toastUntil = 0

	-- LAST, so it is the last sibling in `root` and therefore already above
	-- everything even before its ZIndex is considered.
	buildRoomPanel(self, root)


	return self
end

-- ----------------------------------------------------------------- faces ---

local function paintFaces(entry: any, users: { number }, myUserId: number)
	-- Rebuilt only when the roster actually changes: this is a dozen
	-- ImageLabels and it is pointless work every time the clock ticks.
	local key = table.concat(users, ",")
	if key == entry.faceKey then
		return
	end
	entry.faceKey = key
	entry.faces:ClearAllChildren()

	local flow = Instance.new("UIListLayout")
	flow.FillDirection = Enum.FillDirection.Horizontal
	flow.HorizontalAlignment = Enum.HorizontalAlignment.Center
	flow.VerticalAlignment = Enum.VerticalAlignment.Center
	flow.SortOrder = Enum.SortOrder.LayoutOrder
	flow.Padding = UDim.new(0.012, 0)
	flow.Parent = entry.faces

	local shown = math.min(#users, MAX_FACES)
	for i = 1, shown do
		local userId = users[i]
		local face = Instance.new("ImageLabel")
		face.Name = "F" .. i
		face.LayoutOrder = i
		face.BackgroundColor3 = PANEL
		face.BorderSizePixel = 0
		-- No API call and no yield: the thumbnail is addressable by userId.
		face.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", userId)
		face.Size = UDim2.fromScale(0, 1)
		local ratio = Instance.new("UIAspectRatioConstraint")
		ratio.AspectRatio = 1
		ratio.Parent = face
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = face
		if userId == myUserId then
			local ring = Instance.new("UIStroke")
			ring.Color = GAIN
			ring.Thickness = 2
			ring.Parent = face
		end
		face.Parent = entry.faces
	end

	if #users > shown then
		local more = Instance.new("TextLabel")
		more.Name = "More"
		more.LayoutOrder = shown + 1
		more.BackgroundTransparency = 1
		more.FontFace = FONT_BOLD
		more.TextScaled = true
		more.TextColor3 = INK_DIM
		more.Text = "+" .. (#users - shown)
		more.Size = UDim2.fromScale(0, 1)
		local ratio = Instance.new("UIAspectRatioConstraint")
		ratio.AspectRatio = 1
		ratio.Parent = more
		local c = Instance.new("UITextSizeConstraint")
		c.MaxTextSize = 40
		c.MinTextSize = 6
		c.Parent = more
		more.Parent = entry.faces
	end
end

-- ----------------------------------------------------------------- board ---

function LobbyUI.setBoard(self: LobbyUI, cards: { Matchmaker.CardView })
	for i, view in cards do
		local entry = self.cards[i]
		if entry then
			-- Written every update because a slot's map changes between
			-- rounds; the compare keeps it from re-fetching the same image.
			local art = MAP_ART[view.map] or ""
			if entry.art.Image ~= art then
				entry.art.Image = art
			end
			setText(entry.mapName, string.upper(view.mapName))
			setText(entry.modeName, string.upper(view.modeName))
			paintFaces(entry, view.users, self.myUserId)

			entry.state = view.state
			entry.mine = view.mine
			entry.n = view.count
			entry.cap = view.cap
			entry.full = view.count >= view.cap

			-- THE RECONCILE. A pending press is dropped the moment the board
			-- AGREES with it, and only then -- a board that was already in
			-- flight when the press happened says "not you" about a join that
			-- is going to succeed, and honouring it would flash the card back
			-- to JOIN and then forward again. PENDING_HOLD is the backstop for
			-- an intent that never landed at all.
			if entry.pending ~= nil and (view.mine == entry.pending or os.clock() > entry.pendingUntil) then
				entry.pending = nil
			end

			-- The countdown the server sent belongs to the roster the server
			-- sent. A join that has not landed yet keeps the clock the press
			-- started locally, or the card would tick, stop, and tick again.
			if entry.pending == nil then
				entry.remaining = view.remaining
				entry.at = os.clock()
				entry.waiting = view.count == 0
			end

			paintCard(entry)
		end
	end
end


-- ------------------------------------------------------------------ room ---

function LobbyUI.paintRoom(self: LobbyUI)
	local view = self.room
	if not view then
		return
	end
	local host = view.isHost
	local open = view.state == "open"
	-- "pending" is a LOCAL state and never arrives on the wire: it is the
	-- panel a CREATE opens before its record exists. See openPending.
	local pending = view.state == "pending"

	kitSet(self.roomCode, view.code)
	for i, f in PrivateLobby.FIELDS do
		local row = self.rows[i]
		setText(row.value, PrivateLobby.label(f.key, self.roomSettings[f.slot] or 1))
		-- GUESTS SEE THE SETTINGS AND NOT THE ARROWS. Hiding the control is
		-- the honest version of disabling it: there is no press to refuse.
		row.dec.Visible = host and open
		row.inc.Visible = host and open
	end

	paintFaces(self.roomRoster, view.users, self.myUserId)
	setText(self.roomCount, string.format("%d / %d", view.count, PrivateLobby.CAP))

	self.startButton.Visible = host and not pending
	self.waitLabel.Visible = pending or not host
	setText(self.waitLabel, pending and "CREATING LOBBY"
		or (open and "WAITING FOR THE HOST" or "STARTING"))
	setText(self.startButton.Caption, open and "START" or "STARTING")
end

-- The room, straight off the wire. `false` -- or anything unreadable -- means
-- "you are not in a room", which is what closes the panel: a player whose room
-- expired underneath them must not be left looking at it.
function LobbyUI.setRoom(self: LobbyUI, wire: any)
	local view = wire and PrivateLobby.readWire(wire, self.myUserId) or nil

	-- THE LEAVE GUARD. A room packet sent before the leave landed still says
	-- you are in it, and honouring it would re-open the panel the press just
	-- closed. Matched on the CODE and not merely on the clock, so leaving one
	-- room and joining another straight away still opens the new one.
	if view and view.code == self.leftCode and os.clock() - self.leftAt < LEAVE_HOLD then
		return
	end

	if not view or not view.mine then
		self.room = nil
		self.shade.Visible = false
		return
	end

	self.room = view
	-- THE HOST'S OWN STEPS WIN FOR A MOMENT. A record that was already in
	-- flight when an arrow was pressed carries the settings from before it,
	-- and adopting those would snap the row back and then forward again. Two
	-- seconds is far longer than the round trip and far shorter than anyone's
	-- patience with a control that is lying.
	if not (view.isHost and os.clock() - self.setAt < 2) then
		self.roomSettings = table.clone(view.settings)
	end

	self.shade.Visible = true
	self.joinView.Visible = false
	self.roomView.Visible = true
	LobbyUI.paintRoom(self)
end

-- The panel a CREATE opens before there is a room to put in it. Every row is
-- drawn from what the page is already holding -- the settings it has just
-- sent -- because the only thing it genuinely cannot know yet is the code.
function LobbyUI.openPending(self: LobbyUI)
	self.pendingAt = os.clock()
	self.leftCode = nil
	self.room = {
		code = "- - - -",
		host = self.myUserId,
		settings = table.clone(self.roomSettings),
		state = "pending",
		users = { self.myUserId },
		count = 1,
		mine = true,
		isHost = true,
	}
	self.shade.Visible = true
	self.joinView.Visible = false
	self.roomView.Visible = true
	LobbyUI.paintRoom(self)
end

function LobbyUI.openJoin(self: LobbyUI)
	self.shade.Visible = true
	self.roomView.Visible = false
	self.joinView.Visible = true
	setText(self.joinErr, "")
	self.codeBox.Text = ""
	self.codeBox:CaptureFocus()
end

function LobbyUI.closePanel(self: LobbyUI)
	self.shade.Visible = false
	self.room = nil
end


-- What the two fields hold right now, trimmed. Nothing carries this into a
-- match yet; when something does, this is the one place it reads from.
function LobbyUI.identity(self: LobbyUI): (string, string)
	local name = string.gsub(self.nameBox.Text, "^%s*(.-)%s*$", "%1")
	local tag = string.gsub(self.tagBox.Text, "^%s*(.-)%s*$", "%1")
	return name, tag
end

function LobbyUI.toast(self: LobbyUI, text: string)
	-- A refusal arriving while the code box is up is ABOUT the code box --
	-- "no lobby with that code" belongs under the field it is about, not in
	-- the corner of a page the modal is covering.
	if self.joinView and self.joinView.Visible then
		setText(self.joinErr, string.upper(text))
		return
	end
	-- A toast arriving while a room is still being made IS the failure --
	-- "could not find a free code" -- so the placeholder goes with it, and
	-- the message lands on the page behind it where it can be read.
	if self.room and self.room.state == "pending" then
		LobbyUI.closePanel(self)
	end
	setText(self.toastLabel, text)
	self.toastUntil = os.clock() + 5
	-- REFUSALS ARRIVE AS TOASTS ("that lobby just filled up"), so a refusal is
	-- the page being told its optimistic paint is wrong RIGHT NOW rather than
	-- in PENDING_HOLD seconds. Dropping every pending guess is safe whatever
	-- the toast said: the board is the truth either way, and it is already on
	-- its way.
	for _, entry in self.cards do
		if entry.pending ~= nil then
			entry.pending = nil
			paintCard(entry)
		end
	end
end

-- The reference spells its countdown out -- "1min 17s", not "1:17". Local to
-- this page on purpose: `Matchmaker.clock` is the wire-level formatter and the
-- match HUD reads it too.
local function longClock(seconds: number): string
	local s = math.max(0, math.floor(seconds + 0.5))
	local m = math.floor(s / 60)
	if m > 0 then
		return string.format("%dmin %ds", m, s % 60)
	end
	return string.format("%ds", s)
end

-- Once a frame: the clocks, and nothing else. Everything else on a card is
-- written by `setBoard`, so a settled page does three string comparisons.
function LobbyUI.step(self: LobbyUI, _dt: number)
	local now = os.clock()
	for _, entry in self.cards do
		local left = math.max(0, entry.remaining - (now - entry.at))
		if entry.state ~= "open" then
			setText(entry.clock, "GO")
		elseif entry.waiting then
			-- The countdown does not start until somebody joins, so an empty
			-- lobby must not look like a clock that has stopped working.
			setText(entry.clock, longClock(Matchmaker.COUNTDOWN))
		else
			setText(entry.clock, longClock(left))
		end
	end
	-- A create whose record never returned. Closing it is the honest end: the
	-- alternative is a panel that says CREATING LOBBY until the round starts.
	if self.room and self.room.state == "pending" and now - self.pendingAt > CREATE_HOLD then
		LobbyUI.closePanel(self)
		LobbyUI.toast(self, "COULD NOT CREATE THAT LOBBY")
	end
	if self.toastUntil > 0 and now > self.toastUntil then
		self.toastUntil = 0
		setText(self.toastLabel, "")
	end
end


return LobbyUI
