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
local AssetService = game:GetService("AssetService")

local Gamepad = require(script.Parent.Gamepad)
local Matchmaker = require(script.Parent.Matchmaker)
local PrivateLobby = require(script.Parent.PrivateLobby)
local Sfx = require(script.Parent.Sfx)
-- For the free-rewards plate: which skin is being given away, what it does,
-- and its swatch. Named off the catalogue rather than spelled out here, so
-- the sheet cannot promise something the grant does not hand over.
local Patterns = require(script.Parent.Patterns)

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

-- THE GAME'S WORDMARK, drawn in the top bar where the name used to be typed
-- out in the kit font. 1023x341 with the letters inked 19,56..1007,296 -- so
-- roughly 30% of the asset's HEIGHT is transparent margin, which is what the
-- brand box below is sized around rather than the 3:1 of the file.
local BRAND_LOGO = "rbxassetid://75232735772850"

-- THE MAPS THEMSELVES, keyed by `CardView.map`. These are card renders --
-- `mapgen/card.py` -> `mapgen/out/card/<Name>Map.png`, 880x550 -- uploaded to
-- the creator account and then RESOLVED FROM DECAL TO IMAGE: the upload hands
-- back a Decal id, and a Decal id does not render in an ImageLabel. What is
-- stored here is the underlying image, read off `Decal.Texture` after a
-- LoadAsset.
--
-- NOT the same picture as the map preview. A card is a third of this size
-- under a scrim, a caption band and two chips, so it drops the sea to one flat
-- navy and spends everything on the coastline. card.py is fitted to the seven
-- that shipped on 2026-08-31, whose own script is gone.
--
-- Every id here is a map the rotation can serve; a map with no entry draws an
-- empty card, which is what the Pacific did until 2026-09-04.
local MAP_ART = {
	us = "rbxassetid://89598223345921",
	europe = "rbxassetid://74345634359792",
	china = "rbxassetid://103392032511171",
	medit = "rbxassetid://106256329253516",
	tokyo = "rbxassetid://138545822485390",
	istanbul = "rbxassetid://81959508092943",
	venice = "rbxassetid://90363138911437",
	-- Pacific card REMADE 2026-09-08, for the culled islands (specs.py
	-- `island_keep`). The old art was the 465-disc speckle: at card size --
	-- a third of this image, behind a scrim -- it was the one busy picture in
	-- a row of nine silhouettes, which is the thing card.py exists to avoid.
	-- card.py -> out/card/PacificMap.png -> uploaded through the Studio proxy.
	pacific = "rbxassetid://98168630684251",
	-- World card (2026-09-08): card.py -> out/card/WorldMap.png, uploaded
	-- through the Studio proxy, which hands back an image id directly.
	world = "rbxassetid://124482758399640",
	-- New York card (2026-09-11): card.py -> out/card/NewYorkMap.png, uploaded
	-- through the Studio proxy. New Jersey and Nassau sink into the navy like
	-- every card's out-of-bounds ground, so it shows the five boroughs only.
	nyc = "rbxassetid://74433227708835",
	-- Japan card (2026-09-11): card.py -> out/card/JapanMap.png, uploaded through
	-- the Studio proxy. Korea, China and Russia sink into the navy.
	japan = "rbxassetid://74063939091109",
	-- Korea and Africa cards (2026-09-13): card.py -> out/card/<Name>Map.png,
	-- uploaded through the Studio proxy. Both maps draw most of their frame as
	-- out-of-bounds neighbours -- China, Japan and Russia on one, Europe and
	-- Arabia on the other -- and all of it sinks into the navy on a card, so
	-- what is left is the peninsula and the continent on their own.
	korea = "rbxassetid://134729541757873",
	africa = "rbxassetid://83456234266051",
	-- Philippines card (2026-09-21): card.py -> out/card/PhilippinesMap.png,
	-- uploaded through the Studio proxy. Sabah sinks into the navy, so what
	-- is left is the archipelago on its own. (A sideways 2.0 km/px build was
	-- tried the same day and reverted by the owner; its cards were
	-- 89778100239474 and 111336404869345.)
	philippines = "rbxassetid://136853399830772",
	eurasia = "rbxassetid://118726158878043",
	-- Mars card (2026-09-13). The one card in the row that is not Earth: a
	-- northern ocean, the southern highlands under it, and Tharsis with
	-- Olympus Mons beside it right of centre.
	mars = "rbxassetid://132092241836422",
}

local INK = Color3.fromRGB(234, 240, 250)
local INK_DIM = Color3.fromRGB(178, 190, 212)
local INK_OFF = Color3.fromRGB(146, 160, 186)
local PANEL = Color3.fromRGB(15, 20, 32)
local LINE = Color3.fromRGB(52, 66, 94)
local GAIN = Color3.fromRGB(111, 217, 138)
local GOLD = Color3.fromRGB(232, 196, 110)
-- THE SHOP'S RED. Every other pill on this page is the same dark panel, which
-- is right for two buttons that do the same kind of thing -- and wrong for the
-- one that does not lead to a game. Colour says that before the caption is
-- read. Deep rather than bright: it sits on the page instead of shouting over
-- the cards, which are the thing the page is for.
local RED = Color3.fromRGB(168, 40, 46)
local RED_LINE = Color3.fromRGB(232, 96, 96)
-- FREE REWARDS' GREEN, argued exactly as the shop's red was: the one button
-- in its row that is not a way into a match says so in colour, before the
-- caption is read. Deep fill, bright edge -- and the bright one is GAIN
-- itself, already this page's word for "you gained something", so the pair
-- costs one new colour rather than two.
local FREE_FILL = Color3.fromRGB(28, 112, 62)
local FREE_LINE = GAIN
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

-- WHAT A PRESS ON THIS PAGE SOUNDS LIKE (owner, 2026-09-15: the map cards,
-- then "do it for all buttons in the lobby").
--
-- The mouth pop the map itself uses for ground taken, borrowed: it is already
-- this game's "yes", it costs no new asset, and it makes the page sound like
-- the round it opens.
--
-- Sfx.play AND NOT Sfx.pop. The two share a cue and share nothing else: pop
-- carries a tile debt and a smoothed front speed for the map's own pops, and a
-- button feeding either of them would set the rate of the first pops of a
-- round off a player tapping CANCEL.
--
-- TWO NOTES, SEPARATED ONLY BY PITCH. Bright for a press that commits -- join,
-- create, start, step up -- and flat, at the recording's own pitch, for one
-- that backs out or steps down. A rise against a fall is read without being
-- taught, so the page says which of the two happened with one sample.
local POP_GO = 1.35
local POP_BACK = 1.0
local POP_VOL = 1.15

local function popPress(pitch: number?)
	Sfx.play("Pop", { pitch = pitch or POP_GO, volume = POP_VOL })
end

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
-- ...and it stops three quarters of the way across (2026-09-17, owner:
-- "the bar on the top, make it left aligned, and then make it only take up
-- 75% of the horizontal"). The LEFT edge is the one that does not move: it
-- stays on the page margin every other block on this page starts from, so
-- the bar reads as the top of that column rather than as a banner of its
-- own. Its children are authored against CONTENT_W and stay that way, which
-- is what makes this ONE number -- the whole rhythm inside the bar rides the
-- new width together instead of the name field alone paying for it.
local BAR_W = math.floor(CONTENT_W * 0.75 + 0.5)
-- ...and FREE REWARDS takes what the bar stopped short of. It is the only
-- thing in the header row that is not identity, so it sits BESIDE the bar
-- rather than inside it: a button among readouts reads as one more readout.
local FREE_GAP = 24
local FREE_X = PAGE_M + BAR_W + FREE_GAP
-- THE CREDITS BUTTON, at the row's right edge (2026-09-25, owner: "Add a (i)
-- looking button on the right side of reward, so i can put my credits"). The
-- bar's full height, like everything else in the header row, and narrow
-- because it carries one glyph -- a footnote to FREE REWARDS, not a rival.
local INFO_W = 52
local INFO_GAP = 12
local INFO_X = PAGE_M + CONTENT_W - INFO_W
local FREE_W = CONTENT_W - BAR_W - FREE_GAP - INFO_GAP - INFO_W
-- The balance readout, in the gap between the name field (which ends at 728)
-- and the brand. Right-aligned against the brand rather than left-aligned off
-- the name, so a five-digit balance grows away from the field it would
-- otherwise crowd. The -300 is where the brand USED to start, kept as the
-- anchor because the wordmark that replaced it is narrower and would pull the
-- balance rightwards into it for no reason.
local MONEY_W = 132
local MONEY_X = CONTENT_W - 300 - 16 - MONEY_W

-- The card block: one big card and a column of THREE, at the reference's own
-- 65.1 / 2.6 / 32.3 split of the content width.
--
-- THE THIRD BOX IS NOT A CARD (2026-09-17, owner: "there's 2 games on the
-- right. I want it to have slots for 3, so split it into thirds ... the bottom
-- one to display SEE ALL GAMES"). The board holds five lobbies now and the page
-- still shows the best three of them; what the new box adds is the way to the
-- other two, and to every public room somebody is hosting. So the column reads
-- as two games and a door rather than three games, which is what it is.
local BLOCK_Y = BAR_Y + BAR_H + 33
local BTN_H = 76
local BTN_Y = REF_H - 24 - BTN_H
local BLOCK_H = BTN_Y - 22 - BLOCK_Y
local BIG_W = math.floor(CONTENT_W * 0.6512 + 0.5)
local COL_GAP = math.floor(CONTENT_W * 0.0256 + 0.5)
local SMALL_W = CONTENT_W - BIG_W - COL_GAP
local SMALL_GAP = 23

-- THE DOOR IS SHORTER THAN A CARD (2026-09-17, owner: "reduce the height of the
-- see all games tab so the other two tabs' map is more visible"). It went in as
-- an exact third and that spent a third of the column on a box with no map in
-- it: a card is mostly coastline, which is the thing a player recognises, and
-- the door is two lines of text that need about eighty pixels between them.
--
-- So the door takes a FIXED height and the two cards split whatever is left --
-- 176 each rather than 142, which is 23% more card and all of it map. Anything
-- that changes the block's height now feeds the cards automatically, which is
-- the right way round: the door's needs are fixed and a card's are not.
--
-- BTN_H IS THE FLOOR, and it is not a coincidence (owner asked for it shorter
-- twice: 142 -> 88 -> here). The door is a PILL, not a card -- the same control
-- as SHOP, CREATE LOBBY and JOIN LOBBY sitting directly under it -- so the
-- honest height for it is the height those are, and a door shorter than the
-- pills it is a sibling of would just be a smaller odd one out. Anything below
-- this stops being "less wasted column" and starts being a cramped button.
local DOOR_H = BTN_H
local SMALL_H = (BLOCK_H - SMALL_GAP * 2 - DOOR_H) / 2

-- THREE buttons across the span the reference gives its three -- SHOP,
-- CREATE LOBBY and JOIN LOBBY. LEARN TO PLAY sat first here for as long as the
-- tutorial needed a door; it does not need one any more, because a player's
-- first ever join is carried into the lesson before this page ever draws for
-- them. The shop took the vacated slot when Money finally got something to
-- buy, and it went LAST because it is the one button here that does not lead
-- to a game.
--
-- 2026-09-04, owner: it goes FIRST instead, and in red. Same argument, better
-- answer -- putting the odd one out at the end still left three identical
-- pills in a line, so which two belonged together had to be read. Off to the
-- side and a different colour, CREATE and JOIN are adjacent and read as the
-- pair they are, and the shop is plainly not part of that pair.
local BTN_GAP = 32
local BTN_N = 3
local BTN_W = (CONTENT_W - BTN_GAP * (BTN_N - 1)) / BTN_N

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
	underline: boolean,
	apostrophe: boolean
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
	-- A CONTROLLER'S CURSOR DOES NOT PUT A CARET IN A BOX ON ITS OWN. The
	-- virtual cursor emulates a mouse for buttons, hover and drag and stops
	-- short of text entry, so the press is caught here and the box asked to
	-- take focus itself -- which on a console is also what raises the
	-- on-screen keyboard. A real mouse has focused it by the time this runs,
	-- and the call is a no-op.
	box.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and Gamepad.cursorOn() then
			box:CaptureFocus()
		end
	end)

	box:GetPropertyChangedSignal("Text"):Connect(function()
		local s = box.Text
		if upper then
			s = string.upper(s)
		end
		-- Letters, digits, space, underscore and hyphen. A clan tag full of
		-- punctuation is how you get a nation label nobody can read.
		--
		-- THE NAME FIELD ALSO TAKES AN APOSTROPHE, because ConquestNames does:
		-- "O'Hara" and "Kings' Landing" are names, and a client that strips a
		-- character the server would have accepted is a field fighting the
		-- person typing in it for a reason they cannot see.
		s = string.gsub(s, apostrophe and "[^%w '_%-]" or "[^%w _%-]", "")
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
-- THE MODE PILL'S TWO COLOURS. Light blue is the owner's for HISTORICAL
-- (2026-09-11); gold is a SPECIAL mode's (Modes.SPECIAL, 2026-09-18), so a
-- card that is only there now and then reads as one at a glance. One table,
-- not two locals: this chunk is near Luau's register ceiling.
local MODE_PILL = {
	historical = Color3.fromRGB(150, 206, 255),
	special = Color3.fromRGB(255, 205, 92),
}

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


-- ROUNDING IS PER-OBJECT, NOT INHERITED (2026-09-02, owner: "image goes out
-- the corner"). A UICorner rounds only the thing it is parented to, and
-- ClipsDescendants clips to its object's RECTANGLE -- the corner radius plays
-- no part in the region children are clipped into. So every child that reaches
-- a rounded parent's edge -- map art, scrim, caption band, press flash -- has
-- to carry the same radius itself, or it draws four square corners standing
-- proud of the panel and of the border tracing it.
--
-- Radius matches the parent's, so the two stay concentric.
local function roundOff(obj: Instance, radius: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 10)
	c.Parent = obj
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
	text: string,
	-- Optional, because the default IS the design: three identical dark pills.
	-- Only a button that means something different may take a different fill.
	fill: Color3?,
	edge: Color3?,
	-- The note it presses at. POP_GO unless this button is a way back OUT of
	-- something, which is the only reason to pass it. See popPress.
	pitch: number?
): ImageButton
	local b = Instance.new("ImageButton")
	b.Name = name
	b.Image = ""
	b.BackgroundColor3 = fill or PANEL
	b.BackgroundTransparency = 0.06
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	place(b, pw, ph, x, y, w, h)
	b.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = b
	local stroke = Instance.new("UIStroke")
	stroke.Color = edge or LINE
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
	roundOff(scrim, 10)

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
		-- ON THE DOWN, WITH THE FLASH, not on Activated. A press is a physical
		-- event and the ear expects it at the moment the finger lands; waiting
		-- for the release puts the sound after the animation that is already
		-- acknowledging it.
		popPress(pitch)
	end)
	b.MouseButton1Up:Connect(function()
		held = false
		paint(PRESS_OUT)
	end)
	return b
end


-- ------------------------------------------------------------------ gift ---

-- The sprites this page paints for itself, PAINTED RATHER THAN UPLOADED -- the
-- same route
-- Flags takes for fifty-seven nations: an EditableImage and a buffer of
-- pixels. Nothing to upload, nothing to moderate, and the drawing stays text
-- in this file that anybody can change one square of.
--
-- 16x16 and rendered Pixelated, for the reason every pixel sprite in this
-- game is: at forty-odd pixels on screen a soft-edged sticker spends half its
-- edge on grey. The dark outline is baked into the art the way Icons' are, so
-- it survives the green plate it lands on without a stroke of its own.
local PIX_P: { [string]: { number } } = {
	["."] = { 0, 0, 0, 0 },
	["k"] = { 20, 22, 28, 255 }, -- the outline
	["y"] = { 232, 196, 110, 255 }, -- the page's own GOLD, lit
	["o"] = { 186, 150, 74, 255 }, -- and in shade, which is what makes it a box
	["r"] = { 214, 60, 66, 255 }, -- ribbon
}
local GIFT_ART = {
	"................",
	"...kkkk..kkkk...",
	"...krrk..krrk...",
	"...krrrrrrrrk...",
	".kkkkkkkkkkkkkk.",
	".kyyyyyrryyyyyk.",
	".kooooorroooook.",
	"..kkkkkkkkkkkk..",
	"..kyyyyrryyyyk..",
	"..kyyyyrryyyyk..",
	"..kyyyyrryyyyk..",
	"..koooorrooook..",
	"..koooorrooook..",
	"..koooorrooook..",
	"..kkkkkkkkkkkk..",
	"................",
}
-- PLACEHOLDER ART for the two reward steps, and the first thing to replace
-- when real art exists: swap a table here for an uploaded id on an ImageLabel
-- that takes `Image` instead, and nothing else in this file moves.
--
-- 32 A SIDE WHERE THE GIFT IS 16 (2026-09-17, owner: "thumbs up and star look
-- ass, use smaller pixel sizes if you have to"). A box and a ribbon survive a
-- sixteen-a-side grid because they are made of straight lines; a thumb and a
-- five-pointed star are made of DIAGONALS, and at 16 every one of those is a
-- staircase three pixels wide. Doubling the grid is what buys the star its
-- points and the hand its knuckles. So the grid is a property of each sprite
-- now rather than one constant for all of them -- pixelImage reads it off the
-- art itself, and a sprite can be redrawn at whatever size it needs.
local LIKE_ART = {
	"................................",
	"................................",
	"............kkk.................",
	"..........kkkykkk...............",
	".........kkyyyyykk..............",
	".........kyyyyyyyk..............",
	"........kkyyyyyyykk.............",
	"........kyyyyyyyyyk.............",
	"........kyyyyyyyyyk.............",
	"........kyyyyyyyyyk.............",
	"........kyyyyyyyyyk.............",
	"........kyyyyyyyyykkkkkk........",
	"........kyyyyyyyyykyyyykkkk.....",
	".......kkyyyyyyyyykyyyyyyykk....",
	"......kkyyyyyyyyyykyyyyyoookk...",
	"......kyyyyyyyyyyykyyyooooook...",
	"......kyyyyyyyyyyykyyoooooook...",
	".....kkyyyyyyyyyyykoooooooookk..",
	".....kyyyyyyyyyyyooooooooooook..",
	".....kyyyyyyyyyooooooooookkkkk..",
	".....kyyyyyyyooooooooooooooook..",
	".....kyyyyyooooooooooooooooook..",
	".....kyyyyoooooooooooooooooook..",
	".....kyyoooooooooooooooooooook..",
	".....kkooooooooooooooooookkkkk..",
	"......koooooooooooooooooooook...",
	"......koooooooooooooooooooook...",
	"......kkoooooooooooooooooookk...",
	".......kkoooooooooooooooookk....",
	"........kkkkoooooooooookkkk.....",
	"...........kkkkkkkkkkkkk........",
	"................................",
}
local STAR_ART = {
	"................................",
	"................................",
	"..............kkk...............",
	"..............kyk...............",
	".............kkykk..............",
	".............kyyyk..............",
	"............kkyyykk.............",
	"............kyyyyyk.............",
	"...........kkyyyyykk............",
	"...........kyyyyyyyk............",
	".........kkkyyyyyyykkk..........",
	"..kkkkkkkkyyyyyyyyyyykkkkkkkk...",
	"..kyyyyyyyyyyyyyyyyyyyyyyyook...",
	"..kyyyyyyyyyyyyyyyyyyyyyooook...",
	"..kkkyyyyyyyyyyyyyyyyyooookkk...",
	"....kkyyyyyyyyyyyyyyyooookk.....",
	".....kkyyyyyyyyyyyyoooookk......",
	"......kkyyyyyyyyyooooookk.......",
	".......kkyyyyyyoooooookk........",
	"........kyyyyoooooooook.........",
	"........kyyoooooooooook.........",
	".......kkyooooooooooookk........",
	".......koooooooooooooook........",
	".......koooooooooooooook........",
	".......kooooookkkooooook........",
	".......kooookkk.kkkooook........",
	".......kookkk.....kkkook........",
	".......kkkk.........kkkk........",
	"................................",
	"................................",
	"................................",
	"................................",
}

-- ...and the one step this sheet can actually CHECK (2026-09-17, owner:
-- "lets use groups instead, use this group 207353550"). Three figures, the
-- front one lit and the two behind it in shade, on the same grid as the two
-- above.
local GROUP_ART = {
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	"......kkkkk...........kkkk......",
	".....kkoookk........kkkookkk....",
	"....kkoooookkkkkkkkkkooooookk...",
	"...kkoooooookkyyyykkkoooooook...",
	"...koooooookkyyyyyyykkooooook...",
	"...kooooookkyyyyyyyyykooooook...",
	"...kooooookyyyyyyyyyykkoooook...",
	"...kkoooookyyyyyyyyyyykoooook...",
	"....kkooookyyyyyyyyyyykooookk...",
	".....kkoookyyyyyyyyyyykookkk....",
	"...kkkkoookyyyyyyyyyykkookkkk...",
	"..kkooooookkyyyyyyyyykooooookk..",
	"..kooooooookkyyyyyyykkoooooook..",
	"..kooooookkkkkyyyykkkkkooooook..",
	".kkoooookkooooooooooookkoooookk.",
	".kooooookooooooooooooookooooook.",
	".kkoooookooooooooooooookoooookk.",
	"..kooookkooooooooooooookkooook..",
	"..kooookooooooooooooooookooook..",
	"..kkoookkooooooooooooookkoookk..",
	"...kkkkokooooooooooooookokkkk...",
	"......kkkooooooooooooookkk......",
	"........kkooooooooooookk........",
	".........kkooooooooookk.........",
	"..........kkkkooookkkk..........",
	".............kkkkkk.............",
}

-- ...and the step that asks a player to bring somebody. A figure and a plus,
-- on the same grid as the rest.
local INVITE_ART = {
	"................................",
	"................................",
	"................................",
	"................................",
	"................................",
	".......kkkkkk...................",
	"......kkyyyykk..................",
	".....kkyyyyyykk.......kkkkkkk...",
	".....kyyyyyyyyk.......kyyyyyk...",
	"....kkyyyyyyyykk......kyyyyyk...",
	"....kyyyyyyyyyyk......kyyyyyk...",
	"....kkyyyyyyyykk...kkkkyyyyykkkk",
	".....kyyyyyyyyk....kyyyyyyyyyyyk",
	".....kkyyyyyykk....kyyyyyyyyyyyk",
	"......kkyyyykk.....kyyyyyyyyyyyk",
	".......kkkkkk......kyyyyyyyyyyyk",
	"....kkkkooookkkk...kyyyyyyyyyyyk",
	"...kkooooooooookk..kkkkyyyyykkkk",
	"..kkooooooooooookk....kyyyyyk...",
	"..kooooooooooooook....kyyyyyk...",
	"..kooooooooooooook....kyyyyyk...",
	".kkooooooooooooookk...kkkkkkk...",
	".kooooooooooooooook.............",
	".kkooooooooooooookk.............",
	"..kooooooooooooook..............",
	"..kooooooooooooook..............",
	"..kkooooooooooookk..............",
	"...kkooooooooookk...............",
	"....kkkkooookkkk................",
	".......kkkkkk...................",
	"................................",
	"................................",
}

local function pixelImage(parent: Instance, name: string, art: { string }): ImageLabel
	-- Width off the first row, height off the table.
	local w, h = #art[1], #art
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	local buf = buffer.create(w * h * 4)
	for y = 1, h do
		local row = art[y]
		for x = 1, w do
			local rgba = PIX_P[string.sub(row, x, x)]
			local o = ((y - 1) * w + (x - 1)) * 4
			buffer.writeu8(buf, o + 0, rgba[1])
			buffer.writeu8(buf, o + 1, rgba[2])
			buffer.writeu8(buf, o + 2, rgba[3])
			buffer.writeu8(buf, o + 3, rgba[4])
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), buf)

	local lbl = Instance.new("ImageLabel")
	lbl.Name = name
	lbl.BackgroundTransparency = 1
	lbl.BorderSizePixel = 0
	lbl.ImageContent = Content.fromObject(img)
	-- Fit, not Stretch: the box is square and the button is not.
	lbl.ScaleType = Enum.ScaleType.Fit
	-- The one property that makes this pixel art instead of a blur.
	lbl.ResampleMode = Enum.ResamplerMode.Pixelated
	-- Over the pill's scrim, under its press flash.
	lbl.ZIndex = 3
	lbl.Parent = parent
	return lbl
end


-- ------------------------------------------------------------------ card ---

-- A card's corner radius. Its children repeat it through `roundOff`.
local CARD_R = 10


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
	corner.CornerRadius = UDim.new(0, CARD_R)
	corner.Parent = card

	-- THE BORDER IS A CHILD, NOT THE CARD'S OWN STROKE (2026-09-01, owner:
	-- "the green border is cut off at the corners").
	--
	-- A UIStroke grows OUTWARD from its object's edge, and this card is the one
	-- control on the page with ClipsDescendants -- it needs it, because the clip
	-- is what rounds the map art off at the corners. The clip then takes the
	-- card's OWN stroke with it: the straight runs survive (they are a hair over
	-- the edge) and the four corner arcs, which bow furthest out, are cut. The
	-- JOINED ring came out as four green dashes with rounded gaps.
	--
	-- The bottom-row buttons are the control case that proves it -- identical
	-- UICorner 10, identical 1.6px stroke, same UIScale from `grower`, no clip,
	-- corners perfect.
	--
	-- So the stroke moves onto a frame INSET far enough that its outward growth
	-- lands inside the clip instead of under it. The inset exceeds the
	-- thickness, and the radius drops by the same inset so the curve stays
	-- CONCENTRIC with the card's -- otherwise the border and the art it traces
	-- bow apart at exactly the corners this is fixing.
	local BORDER_INSET = 2
	local border = Instance.new("Frame")
	border.Name = "Border"
	border.BackgroundTransparency = 1
	border.Size = UDim2.new(1, -BORDER_INSET * 2, 1, -BORDER_INSET * 2)
	border.Position = UDim2.fromOffset(BORDER_INSET, BORDER_INSET)
	-- Over the art, the scrim and the caption band, under the press flash.
	border.ZIndex = 7
	border.Parent = card
	local borderCorner = Instance.new("UICorner")
	borderCorner.CornerRadius = UDim.new(0, CARD_R - BORDER_INSET)
	borderCorner.Parent = border

	local stroke = Instance.new("UIStroke")
	stroke.Color = LINE
	stroke.Thickness = 1.6
	stroke.Transparency = 0.35
	stroke.Parent = border

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
	-- EVERY FULL-BLEED CHILD ROUNDS ITSELF (2026-09-02, owner: "image goes out
	-- the corner"). ClipsDescendants clips to the card's RECTANGLE -- UICorner
	-- rounds an object's own drawing and does nothing to the clip region it
	-- hands its children. So the comment above was half right: the clip keeps
	-- the art inside the card's sides, but the four corners came out square,
	-- sitting proud of the rounded panel and the border tracing it.
	--
	-- The Flash frame below has always carried its own UICorner for exactly
	-- this reason; the art, the scrim and the caption band are the three that
	-- reach an edge and did not.
	--
	-- Radius 10 on all of them, matching the card's, so they stay concentric.
	roundOff(art, CARD_R)

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
	roundOff(scrim, CARD_R)

	-- The caption band. A gradient, not a flat fill: the reference fades the
	-- art out under the text instead of cutting it with an edge.
	local band = Instance.new("Frame")
	band.Name = "Band"
	band.BackgroundColor3 = Color3.fromRGB(6, 9, 16)
	band.BorderSizePixel = 0
	place(band, w, h, 0, h - CAP_H, w, CAP_H)
	band.Parent = card
	-- The band only touches the card's BOTTOM two corners, but rounding all
	-- four costs nothing: its gradient is fully transparent at the top edge,
	-- so the upper pair has nothing to round off.
	roundOff(band, CARD_R)
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

	-- THE HISTORICAL PILL (2026-09-11, owner: "when a player sees it in the
	-- lobby, the game should have a text label with the game mode name and
	-- then a light blue background behind the text"). In the mode line's own
	-- place and INSTEAD of it on a historical card -- the same word twice on
	-- one card is the thing to avoid -- so the band still reads map, then mode.
	-- Hidden on every other card; setBoard flips the two.
	local modeChip = chip(card, "ModeChip", w, h, 16, h - CAP_H + 50, 116, 22, Color3.fromRGB(150, 206, 255), 0)
	modeChip.Visible = false
	local modeChipText = label(modeChip, "ModeText", 116, 22, 0, 4, 116, 14, Color3.fromRGB(8, 12, 20), Enum.TextXAlignment.Center, FONT_BOLD)

	-- Timer, top-right.
	local clockChip = chip(card, "ClockChip", w, h, w - 104, 12, 92, PILL_H, ACCENT, 0)
	local clock = label(clockChip, "Clock", 92, PILL_H, 0, 5, 92, 16, Color3.fromRGB(255, 255, 255), Enum.TextXAlignment.Center, FONT_BOLD)

	-- State, top-left -- the reference's "RANDOM SPAWN" slot.
	local statePill = chip(card, "StateChip", w, h, 12, 12, 104, PILL_H, ACCENT, 0)
	local stateText = label(statePill, "State", 104, PILL_H, 0, 5, 104, 16, Color3.fromRGB(8, 12, 20), Enum.TextXAlignment.Center, FONT_BOLD)

	-- Player count, sitting just above the band on the right.
	--
	-- FLOORED, because the small cards are a third of the column now rather
	-- than a half (2026-09-17). The caption band is an absolute 78 whatever the
	-- card's height, so on a 142-tall card "just above the band" is 30px down --
	-- directly under the timer chip at 12, which is the same corner. The floor
	-- drops it clear of that; on the big card the maximum never binds and the
	-- chip is exactly where it has always been.
	local countY = math.max(h - CAP_H - 34, 44)
	local countChip = chip(card, "CountChip", w, h, w - 108, countY, 96, 24, Color3.fromRGB(6, 9, 16), 0.12)
	local countText = label(countChip, "Count", 96, 24, 0, 5, 96, 14, INK, Enum.TextXAlignment.Center, FONT_BOLD)

	-- Kept, hidden: `paintFaces` still writes into it and the reference has no
	-- face row. Deleting it would mean touching that function too.
	local faces = Instance.new("Frame")
	faces.Name = "Faces"
	faces.BackgroundTransparency = 1
	faces.Visible = false
	place(faces, w, h, 16, countY, 120, 24)
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
	roundOff(flash, CARD_R)

	-- LAST, because `grower` reads the position `place` gave the card.
	local scale = grower(card)

	return {
		slot = index,
		key = slot.key,
		card = card,
		art = art,
		mapName = mapName,
		modeName = modeName,
		modeChip = modeChip,
		modeChipText = modeChipText,
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
	-- THE CLOCK IS LEFT ALONE. It used to restart here on the first join, back
	-- when a record's countdown did not begin until somebody was in it; every
	-- record is born counting down now (Matchmaker.newRecord), so the figure on
	-- the card is already the real one and a local restart would only make it
	-- jump to 1:00 and snap back on the next board.
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
-- 604 rather than 560 since the WHO CAN JOIN row (2026-09-17): six rows of
-- 44 on an 8 gap put the roster at 442, and at the old height it would have
-- been drawn through the START and LEAVE buttons.
local PANEL_W, PANEL_H = 720, 604
local PANEL_X = (REF_W - PANEL_W) / 2
local PANEL_Y = (REF_H - PANEL_H) / 2

-- One settings row, authored against its own 640x44 box.
local ROW_W, ROW_H = 640, 44
local ROW_X = (PANEL_W - ROW_W) / 2
local ROW_TOP = 122
local ROW_GAP = 8 -- 12 at four rows; the MODE row (2026-09-11) needed the room

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
	roundOff(pscrim, 12) -- the panel's radius, not a card's

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
	-- The same catch the name and tag fields carry: a controller's cursor
	-- does not focus a box on its own, so a press on it asks for the caret.
	box.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and Gamepad.cursorOn() then
			box:CaptureFocus()
		end
	end)

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
	-- CANCEL is the way out, so it takes the flat note against JOIN's bright one.
	local joinBack = pillButton(jv, "Back", PANEL_W, PANEL_H, PBTN_R, PBTN_Y, PBTN_W, PBTN_H, "CANCEL", nil, nil, POP_BACK)

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

	-- THE CLOCK A PUBLIC ROOM RUNS ON (2026-09-17). It is the board card's clock
	-- chip, in the card's own colour and in the same corner, because it means
	-- exactly what that one means: this starts by itself when the number runs
	-- out. A room that is PRIVATE has no such promise to make and the chip is
	-- simply not there -- see PrivateLobby.PUBLIC_START.
	--
	-- NOTHING ANYWHERE SAYS "STARTS IN". The chip is a countdown in the corner
	-- of a lobby panel; a caption under it would be reading the number out.
	self.roomClockChip = chip(rv, "ClockChip", PANEL_W, PANEL_H, PANEL_W - ROW_X - 104, 48, 104, PILL_H, ACCENT, 0)
	self.roomClock = label(self.roomClockChip, "Clock", 104, PILL_H, 0, 5, 104, 16,
		Color3.fromRGB(255, 255, 255), Enum.TextXAlignment.Center, FONT_BOLD)
	self.roomClockChip.Visible = false

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
		-- THE ARROW'S DIRECTION, IN THE PITCH. These are the two presses on the
		-- page that come in a matched pair and are held down in runs, and the
		-- note is free information about which way the dial just went -- worth
		-- more here than on any single button, because a stepper is used with
		-- the eyes on the value rather than on the arrow.
		local dec = pillButton(row, "Dec", ROW_W, ROW_H, 300, 2, 40, 40, "<", nil, nil, POP_BACK)
		local inc = pillButton(row, "Inc", ROW_W, ROW_H, 584, 2, 40, 40, ">", nil, nil, POP_GO)

		-- WRAPS, because a four-option menu with a dead end at each side makes
		-- you learn which way is shorter. `PrivateLobby.step` is the only
		-- thing that knows how long a menu is -- and which maps a mode may
		-- land on -- on both sides of the wire.
		local function stepper(delta: number)
			return function()
				local view = self.room
				if not view or not view.isHost or view.state ~= "open" then
					return
				end
				-- A LOCKED ROW SELLS ITSELF (2026-09-11). Its arrows stay put,
				-- dimmed, and a press asks for the pass that opens it: HOST for
				-- the dials, ADVANCED for the mode. MatchmakerServer enforces
				-- the same rule; this is only the page agreeing with it.
				local need = PrivateLobby.tierFor(f.key)
				if self.passTier < need then
					if self.onPassBuy then
						self.onPassBuy(if need >= PrivateLobby.TIER_ADVANCED then "ADVANCED" else "HOST")
					end
					return
				end
				self.roomSettings = PrivateLobby.step(self.roomSettings, f.key, delta)
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
	-- LEAVE backs out of the room, so it answers flat where START does not.
	local leave = pillButton(rv, "Leave", PANEL_W, PANEL_H, PBTN_R, PBTN_Y, PBTN_W, PBTN_H, "LEAVE", nil, nil, POP_BACK)

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


-- ------------------------------------------------------------- all games ---
--
-- EVERY GAME CURRENTLY LOOKING FOR PLAYERS, as one sheet over the page
-- (2026-09-17, owner: "the bottom one to display SEE ALL GAMES, which will then
-- show all games currently actively looking for players ... and show
-- individually created games on public setting also there").
--
-- IT HOLDS TWO KINDS OF THING AND DOES NOT SAY SO IN WORDS. A row is either one
-- of the five lobbies the game hosts or a room somebody made and set to PUBLIC,
-- and the difference is drawn rather than labelled: a hosted lobby has a CLOCK,
-- because it starts on its own whether or not anybody presses anything, and a
-- room has its host's FACE, because it starts when that person says so. Naming
-- them in a caption as well would be saying the same thing twice.
--
-- THE PAGE BEHIND IT IS THE SAME PAGE. This is a modal over the board, not a
-- second screen -- the three cards keep their clocks and keep filling while it
-- is up, and closing it puts you back exactly where you were.
local LIST_W, LIST_H = 1000, 604
local LIST_X = (REF_W - LIST_W) / 2
local LIST_Y = (REF_H - LIST_H) / 2
local LIST_PAD = 28
local LIST_TOP = 104
local LIST_BOT = 120

-- The scroll WINDOW, in the panel's own authored pixels.
local WIN_W = LIST_W - LIST_PAD * 2
local WIN_H = LIST_H - LIST_TOP - LIST_BOT

-- A row, authored against its own box the way a card's internals are.
local ROW_PX_W, ROW_PX_H = WIN_W - 14, 78
local ROW_PX_GAP = 10

-- ...as a fraction of the scroll window, which is what a row is actually worth.
--
-- THE ONE AXIS ON THIS PAGE THAT IS NOT AUTHORED IN SCALE, and it has to be.
-- A ScrollingFrame's children resolve their SCALE against the CANVAS, not
-- against the window -- so sizing a row as a fraction of the window and then
-- sizing the canvas from the rows is circular, and it resolves by making every
-- row as much too tall as the canvas is long. The first build of this sheet put
-- one and a half rows on screen for exactly that reason.
--
-- AutomaticCanvasSize is not the way out either: it reads a scale-sized row as
-- zero and stops the canvas short of the last row, which is what went wrong in
-- the tutorial store.
--
-- So the height of a row is computed in PIXELS from the scroll window's own
-- measured size (`fitRows`), which makes the canvas ordinary arithmetic and
-- breaks the loop. Every fraction INSIDE a row is still scale against the row,
-- so the whole thing still scales with the screen -- see `place`.
local ROW_FRAC = ROW_PX_H / WIN_H
local GAP_FRAC = ROW_PX_GAP / WIN_H

-- Pooled. Five hosted lobbies plus PrivateLobby.PUBLIC_MAX rooms is more than
-- anybody scrolls, and rebuilding a dozen ImageLabels on every board that
-- arrives is the one thing on this page that would actually cost frames.
local LIST_ROWS = 24

local SCROLLBAR = 6

-- A row's corner, and how far its border sits inside it. Both are the card's
-- numbers scaled to a row: see the border block in buildRow.
local ROW_R = 8
local ROW_INSET = 2

-- A row's own hover/press, which is the card's, scaled down: the row IS the
-- button, exactly as the card is.
local function buildRow(self: any, parent: Instance, index: number): any
	local row = Instance.new("ImageButton")
	row.Name = "Row" .. index
	row.Image = ""
	row.BackgroundColor3 = Color3.fromRGB(9, 13, 22)
	row.BackgroundTransparency = 0.25
	row.BorderSizePixel = 0
	row.AutoButtonColor = false
	row.ClipsDescendants = true
	row.Visible = false
	row.LayoutOrder = index
	-- Height written by `fitRows`; width is the canvas's, less the scrollbar
	-- the UIPadding holds back.
	row.Size = UDim2.new(1, 0, 0, 1)
	row.Parent = parent
	roundOff(row, ROW_R)

	-- THE BORDER IS A CHILD, NOT THE ROW'S OWN STROKE -- the same rule, and the
	-- same bug, as the cards (2026-09-17, owner: "the card borders are cut off
	-- in some places"; see buildCard, where it was 2026-09-01).
	--
	-- A UIStroke grows OUTWARD from its object's edge and this row clips its
	-- descendants, so the row's own stroke loses its four corner arcs to the
	-- clip. A row has a SECOND clip on top of that one: it spans the whole
	-- canvas width, so its left edge sits exactly on the ScrollingFrame's own
	-- boundary and the entire left run was cut as well, not just the corners --
	-- which is why the rows read as three-sided boxes.
	--
	-- Inset far enough that the outward growth lands inside both clips, with
	-- the radius dropped by the same inset so the curve stays CONCENTRIC with
	-- the row's.
	local border = Instance.new("Frame")
	border.Name = "Border"
	border.BackgroundTransparency = 1
	border.Size = UDim2.new(1, -ROW_INSET * 2, 1, -ROW_INSET * 2)
	border.Position = UDim2.fromOffset(ROW_INSET, ROW_INSET)
	-- Over the art and the chips, which both reach the row's edge.
	border.ZIndex = 7
	border.Parent = row
	local borderCorner = Instance.new("UICorner")
	borderCorner.CornerRadius = UDim.new(0, ROW_R - ROW_INSET)
	borderCorner.Parent = border

	local stroke = Instance.new("UIStroke")
	stroke.Color = LINE
	stroke.Thickness = 1.6
	stroke.Transparency = 0.45
	stroke.Parent = border

	-- The map, as the card draws it: CROP, so a coastline is never squashed.
	local art = Instance.new("ImageLabel")
	art.Name = "Art"
	art.BackgroundColor3 = Color3.fromRGB(6, 9, 16)
	art.BorderSizePixel = 0
	art.Image = ""
	art.ScaleType = Enum.ScaleType.Crop
	place(art, ROW_PX_W, ROW_PX_H, 10, 8, 112, 62)
	art.Parent = row
	roundOff(art, 6)

	local name = label(row, "Name", ROW_PX_W, ROW_PX_H, 136, 13, 420, 24, INK, Enum.TextXAlignment.Left, FONT_BOLD)
	local mode = label(row, "Mode", ROW_PX_W, ROW_PX_H, 136, 44, 420, 15, INK_DIM, Enum.TextXAlignment.Left)
	-- The historical pill, in the mode line's own place and instead of it --
	-- the same swap the cards make.
	local modeChip = chip(row, "ModeChip", ROW_PX_W, ROW_PX_H, 136, 41, 120, 21, Color3.fromRGB(150, 206, 255), 0)
	modeChip.Visible = false
	local modeChipText = label(modeChip, "ModeText", 120, 21, 0, 4, 120, 13, Color3.fromRGB(8, 12, 20), Enum.TextXAlignment.Center, FONT_BOLD)

	-- WHOSE ROOM THIS IS, and the only thing that says a row is somebody's
	-- room rather than one of the game's own lobbies. Hidden on a hosted
	-- lobby, which has no host.
	local face = Instance.new("ImageLabel")
	face.Name = "Host"
	face.BackgroundColor3 = PANEL
	face.BorderSizePixel = 0
	face.Image = ""
	face.Visible = false
	place(face, ROW_PX_W, ROW_PX_H, ROW_PX_W - 292, 15, 48, 48)
	face.Parent = row
	local faceRound = Instance.new("UICorner")
	faceRound.CornerRadius = UDim.new(0.5, 0)
	faceRound.Parent = face

	local countChip = chip(row, "CountChip", ROW_PX_W, ROW_PX_H, ROW_PX_W - 228, 27, 96, 24, Color3.fromRGB(6, 9, 16), 0.12)
	local countText = label(countChip, "Count", 96, 24, 0, 5, 96, 14, INK, Enum.TextXAlignment.Center, FONT_BOLD)

	-- THE COUNTDOWN, and it is on BOTH kinds of row (2026-09-17). It used to be
	-- hidden on a player's room, on the grounds that a room had no clock to
	-- show -- which stopped being true the moment a PUBLIC room got a two-minute
	-- ceiling (PrivateLobby.PUBLIC_START), and every room in this list is
	-- public. Either kind borrows the chip to say JOINED or FULL instead, which
	-- nothing else on the row says.
	local stateChip = chip(row, "StateChip", ROW_PX_W, ROW_PX_H, ROW_PX_W - 116, 26, 100, 26, ACCENT, 0)
	local stateText = label(stateChip, "State", 100, 26, 0, 5, 100, 16, Color3.fromRGB(255, 255, 255), Enum.TextXAlignment.Center, FONT_BOLD)

	local scale = grower(row)
	local entry = {
		row = row, art = art, name = name, mode = mode,
		modeChip = modeChip, modeChipText = modeChipText,
		face = face, count = countText, stateChip = stateChip, stateText = stateText,
		stroke = stroke, scale = scale,
		-- What this row is currently drawing, and the local half of its clock.
		item = nil :: any, remaining = 0, at = 0, live = false, hover = false,
	}

	row.MouseEnter:Connect(function()
		entry.hover = true
		tween(scale, HOVER_IN, { Scale = entry.live and HOVER_SCALE or 1 })
		tween(stroke, HOVER_IN, { Transparency = entry.live and 0.05 or 0.45 })
	end)
	row.MouseLeave:Connect(function()
		entry.hover = false
		tween(scale, HOVER_OUT, { Scale = 1 })
		tween(stroke, HOVER_OUT, { Transparency = entry.item and entry.item.mine and 0.1 or 0.45 })
	end)
	row.MouseButton1Down:Connect(function()
		tween(scale, PRESS_IN, { Scale = PRESS_SCALE })
		-- The card's rule: on this page a pop means something happened, and a
		-- press that will do nothing gets the plain click instead.
		if entry.live then
			popPress(POP_GO)
		else
			Sfx.play("Click")
		end
	end)
	row.MouseButton1Up:Connect(function()
		tween(scale, PRESS_OUT, { Scale = entry.hover and HOVER_SCALE or 1 })
	end)
	row.Activated:Connect(function()
		local item = entry.item
		if not item or not entry.live then
			return
		end
		-- A ROW IS NOT EXEMPT FROM THE CARD'S RULE. The card's press opens with
		-- the same test; this one checked only `live`, which is forced true for
		-- any lobby you are already in -- so pressing a row for a lobby that had
		-- moved to claim/ready fired a fresh join, which the server refuses with
		-- "that match just started" to somebody who is in fact about to be
		-- teleported into it. The toast then wipes every optimistic paint.
		if item.kind ~= "room" and item.state ~= nil and item.state ~= "open" then
			Sfx.play("Deny")
			return
		end
		-- COMMITTING, so the sheet goes. Whichever kind of game this is, the
		-- answer to the press appears on the page behind it -- a card turning
		-- JOINED, or the room panel opening -- and a list left up over either
		-- is a list the player has to dismiss to see what they just did.
		LobbyUI.closeList(self)
		if item.kind == "room" then
			if self.onRoomJoin then
				self.onRoomJoin(item.code)
			end
			return
		end
		-- A HOSTED LOBBY IS THE CARD'S OWN PRESS, borrowed. Painting the page's
		-- card from here keeps the two views agreeing during the round trip --
		-- and leaving the OTHER cards is the same rule the cards enforce among
		-- themselves: a player is in at most one lobby.
		for _, card in self.cards do
			if card.key == item.key then
				press(card, true)
				flashCard(card)
			elseif card.shownMine then
				press(card, false)
			end
		end
		if self.onJoin then
			self.onJoin(item.key)
		end
	end)
	return entry
end

-- THE SHEET'S ONE MEASUREMENT. Re-run when the list changes length and when
-- the window changes size, which are the only two things that can move it.
local function fitRows(self: any)
	local windowPx = self.listScroll.AbsoluteSize.Y
	if windowPx <= 0 then
		-- The frame has not been laid out yet -- a page built and painted in
		-- the same frame, which is exactly what happens on a cold join. The
		-- AbsoluteSize signal below fires the moment it has, so this is a wait
		-- rather than a failure.
		return
	end
	local rowPx = math.max(1, math.floor(windowPx * ROW_FRAC + 0.5))
	local gapPx = math.max(1, math.floor(windowPx * GAP_FRAC + 0.5))
	for _, entry in self.listRows do
		entry.row.Size = UDim2.new(1, 0, 0, rowPx)
	end
	self.listFlow.Padding = UDim.new(0, gapPx)
	local shown = self.listShown or 0
	self.listScroll.CanvasSize = UDim2.fromOffset(0, math.max(0, shown * (rowPx + gapPx) - gapPx))
end

-- --------------------------------------------------------------- rewards ---
--
-- THE FREE REWARDS SHEET, on the same modal frame as ALL GAMES: same shade,
-- same panel, same corner radius, and the board behind it keeps its clocks and
-- keeps filling. A second sheet over one page, not a second screen.
--
-- TWO COLUMNS, AND THE ORDER IS THE ARGUMENT. What you get is on the LEFT and
-- is read first; what it costs you is on the right, and reads as its price.
-- The other way round the page opens with a chore.
--
-- THE EXIT IS A CORNER X AND THE BOTTOM SLOT IS CLAIM (2026-09-17, owner).
-- The sheet's one action takes the place every other sheet here gives its one
-- button, and the way out goes to the shape every player already knows. Which
-- also means the backdrop can be a way out too -- see the shade below.
--
-- IT ARRIVES THE WAY THE SHOP DOES (same owner note: "the same tweens/sfx my
-- other ui in the game has"). The two curves are PatternShop's own, for
-- PatternShop's own reason: the backdrop fades up, and the panel lifts the
-- last three and a half percent of its size WITHOUT overshooting, because it
-- is the table and a table that bounces steals the landing from what is on it.
-- The three things on the right DO spring, one after another, which is that
-- page's card sweep at a tenth of the size.
local RW_W, RW_H = 1000, 604
local RW_X = (REF_W - RW_W) / 2
local RW_Y = (REF_H - RW_H) / 2
local RW_PAD = 28
local RW_TOP = 104
local RW_LEFT_W = 360
local RW_GAP = 32
local RW_COL_X = RW_PAD + RW_LEFT_W + RW_GAP
local RW_COL_W = RW_W - RW_PAD * 2 - RW_LEFT_W - RW_GAP
-- TWO STEPS. The count drives the row height and the left plate's, so both
-- follow a step being added or taken away rather than being re-chosen.
local RW_TASK_N = 2
local RW_TASK_H = 150
local RW_TASK_GAP = 24
-- The two columns end on the SAME LINE. The left plate is sized off the rows
-- beside it rather than chosen, so the sheet stays square if a step is ever
-- added or a row changes height.
local RW_BODY_H = RW_TASK_H * RW_TASK_N + RW_TASK_GAP * (RW_TASK_N - 1)
-- CLAIM sits exactly where every other sheet on this page puts its one button,
-- which is the whole point of moving it here: same box, same place, so the two
-- sheets are the same piece of furniture.
local RW_CLAIM_W, RW_CLAIM_H = 240, 64
local RW_CLOSE = 44

local RW_SHADE_ALPHA = 0.25
local RW_OPEN_SHADE = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RW_OPEN_PANEL = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local RW_SHUT = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local RW_PANEL_FROM = 0.965
local RW_ROW_IN = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local RW_ROW_FROM = 0.86
local RW_ROW_LEAD = 0.06
local RW_ROW_STEP = 0.05
-- WHAT LANDING LOOKS LIKE. The gold flash is PatternShop's landFlash, which
-- is what this game already does when a prize arrives; the punch is that
-- page's card sweep at one object.
local RW_LAND_FLASH = TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RW_LAND_PUNCH = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- The steps, in order. Both are asked for and NEITHER is checked, and that is
-- the platform rather than a shortcut:
--
--  * A game's LIKES have no per-player endpoint anywhere in the engine --
--    votes are a public count and nothing else.
--  * An INVITE can be PROMPTED (SocialService:PromptGameInvite) but not
--    confirmed from here: the only proof one was taken is the INVITED
--    player's join carrying ReferredByPlayerId, which lands in a different
--    session, possibly on a different server, minutes or days later.
--
-- So this sheet asks, and the SERVER owns the only thing that has to be true:
-- that the grant is taken once per account (MatchmakerServer, Data.claimFreeReward).
--
-- TWO STEPS HAVE COME AND GONE HERE and their glyphs are kept above rather
-- than deleted, because redrawing one is the expensive half and putting a step
-- back is one line in this table: FAVOURITE THE GAME (STAR_ART) went on
-- 2026-09-17 -- owner, "remove favourite game for now" -- and JOIN THE GROUP
-- (GROUP_ART) the same evening, once it was established that Roblox has no
-- in-experience join prompt for a community at all (checked against the live
-- API dump: there is no Prompt* member for groups on any service).
-- `button` puts a pill on the row. Exactly one step has one, and it is the
-- one Roblox gives a real dialog for: SocialService:PromptGameInvite. The
-- like has no prompt and no check, so its row stays a sentence.
local RW_TASKS = {
	{ words = "LIKE THE GAME", art = LIKE_ART },
	{ words = "INVITE A FRIEND", art = INVITE_ART, button = "INVITE" },
}

local function buildTaskRow(self: any, parent: Instance, index: number): any
	local spec = RW_TASKS[index]
	local y = RW_TOP + (index - 1) * (RW_TASK_H + RW_TASK_GAP)
	-- A FRAME, NOT A BUTTON, AND NO TICK BOX (2026-09-17, owner: "the done on
	-- this reward page is not necesary, just have the claim button light up ...
	-- they dont need to click on each individual card").
	--
	-- These are three INSTRUCTIONS, not three controls. Two of them cannot be
	-- checked by anything (see RW_TASKS), so a row that answered a press would
	-- only have been the player ticking their own box and the page agreeing --
	-- and the third is checked on the SERVER, where a row cannot reach anyway.
	-- CLAIM lighting up is the whole of the feedback, and CLAIM is the whole of
	-- the interface.
	local row = Instance.new("Frame")
	row.Name = "Task" .. index
	row.BackgroundColor3 = PANEL
	row.BackgroundTransparency = 0.06
	row.BorderSizePixel = 0
	place(row, RW_W, RW_H, RW_COL_X, y, RW_COL_W, RW_TASK_H)
	row.Parent = parent
	roundOff(row, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Color = LINE
	stroke.Thickness = 1.6
	stroke.Transparency = 0.35
	stroke.Parent = row
	local scrim = Instance.new("ImageLabel")
	scrim.Name = "Scrim"
	scrim.BackgroundTransparency = 1
	scrim.Image = KIT_SCRIM
	scrim.ScaleType = Enum.ScaleType.Stretch
	scrim.ImageTransparency = 0.25
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = row
	roundOff(scrim, 10)

	-- The step NUMBER. It is the one thing here that is pure order, so it is
	-- gold and small rather than another white word competing with the caption.
	setText(label(row, "Num", RW_COL_W, RW_TASK_H, 20, 63, 26, 24, GOLD), tostring(index) .. ".")
	place(pixelImage(row, "Art", spec.art), RW_COL_W, RW_TASK_H, 56, 35, 80, 80)
	-- The words stop short of the pill when there is one, rather than running
	-- under it: a caption clipped by a button reads as a layout fault.
	local capW = if spec.button then RW_COL_W - 154 - 140 else RW_COL_W - 170
	local cap = label(row, "Caption", RW_COL_W, RW_TASK_H, 154, 65, capW, 20, INK, Enum.TextXAlignment.Left, FONT_BOLD)
	setText(cap, spec.words)

	-- THE ONE CONTROL ON A ROW, and it is not a tick box: it opens Roblox's own
	-- invite dialog. Blue, because on this page blue is the colour of a press
	-- that starts something (the board's JOIN pills) and green is the colour of
	-- the thing at the end of the flow.
	if spec.button then
		local go = pillButton(row, "Action", RW_COL_W, RW_TASK_H,
			RW_COL_W - 132, (RW_TASK_H - 46) / 2, 112, 46, spec.button, ACCENT)
		go.ZIndex = 3
		go.Activated:Connect(function()
			if self.onInvite then
				self.onInvite()
			end
		end)
	end

	-- Its own UIScale, because pillButton is no longer hanging one here and the
	-- opening sweep drives every row the same way.
	return { row = row, cap = cap, scale = grower(row) }
end

local function buildRewardsPanel(self: any, parent: Instance)
	-- A BUTTON, NOT A FRAME, and that is the whole of "click the background to
	-- close": the backdrop already ate every press that missed the panel, and
	-- now it answers one. The panel below is `Active`, so a press that LANDS on
	-- the sheet is absorbed there and never reaches this.
	local shade = Instance.new("ImageButton")
	shade.Name = "RewardShade"
	shade.Image = ""
	shade.AutoButtonColor = false
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(4, 6, 11)
	shade.BackgroundTransparency = 1
	shade.BorderSizePixel = 0
	shade.Visible = false
	shade.ZIndex = 20
	shade.Parent = parent
	self.rewardShade = shade

	-- AS CLOSE TO A BLUR AS A GUI GETS. Roblox's BlurEffect is a 3D
	-- post-process and everything behind this sheet is opaque GUI -- the lobby
	-- page's own wash over the camera -- so a blur hung on Lighting would have
	-- nothing to act on and would render exactly nothing. What does read as
	-- depth is a deeper wash with the kit's own grain over it: texture rather
	-- than a flat sheet of black.
	local frost = Instance.new("ImageLabel")
	frost.Name = "Frost"
	frost.BackgroundTransparency = 1
	frost.Image = KIT_SCRIM
	frost.ScaleType = Enum.ScaleType.Stretch
	frost.ImageTransparency = 0.72
	frost.Size = UDim2.fromScale(1, 1)
	frost.ZIndex = 0
	frost.Parent = shade

	local panel = Instance.new("Frame")
	panel.Name = "RewardPanel"
	panel.BackgroundColor3 = PANEL
	panel.BackgroundTransparency = 0.02
	panel.BorderSizePixel = 0
	-- ...and this is the other half of the backdrop press: an Active frame
	-- absorbs the input that lands on it, so a click on the sheet itself is
	-- never a click on the backdrop behind it.
	panel.Active = true
	place(panel, REF_W, REF_H, RW_X, RW_Y, RW_W, RW_H)
	panel.Parent = shade
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 12)
	pc.Parent = panel
	-- Scaled as a whole on open, so the title, the plate and the rows all
	-- arrive with it and only the right-hand column has a sweep of its own.
	self.rewardScale = grower(panel)
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
	roundOff(pscrim, 12)

	kitSet(kitLabel(panel, "RewardTitle", RW_W, RW_H, 0, 34, RW_W, 46, GOLD), "FREE REWARDS")

	-- THE REWARD, on its own plate. It is a placeholder and it says so: the
	-- gift is the button's own glyph at size, which is what makes the sheet
	-- read as the thing that button opened.
	local plate = Instance.new("Frame")
	plate.Name = "Reward"
	plate.BackgroundColor3 = Color3.fromRGB(11, 15, 25)
	plate.BackgroundTransparency = 0.1
	plate.BorderSizePixel = 0
	place(plate, RW_W, RW_H, RW_PAD, RW_TOP, RW_LEFT_W, RW_BODY_H)
	plate.Parent = panel
	roundOff(plate, 12)
	local plateStroke = Instance.new("UIStroke")
	plateStroke.Color = LINE
	plateStroke.Thickness = 1.6
	plateStroke.Transparency = 0.45
	plateStroke.Parent = plate
	self.rewardPlateStroke = plateStroke
	-- THE SKIN ITSELF, NOT THE BOX IT COMES IN (2026-09-17, owner). The gift is
	-- still on the button that opens this sheet, which is where a wrapped present
	-- belongs -- inside, the thing being offered is a tile pattern, and the only
	-- honest way to offer one is to show what it looks like on the ground.
	--
	-- Patterns.swatch, which is the SHOP'S own preview and the map's own
	-- arithmetic. A second compositing path here would be a preview that lies,
	-- and for a cosmetic this deliberately quiet the preview IS the product.
	local art = Instance.new("ImageLabel")
	art.Name = "Art"
	art.BackgroundColor3 = Color3.fromRGB(24, 30, 44)
	art.BorderSizePixel = 0
	-- One pixel per TILE blown up whole, exactly as the shop draws it.
	art.ResampleMode = Enum.ResamplerMode.Pixelated
	-- Fit, not Stretch: the second of the two guards below. It letterboxes the
	-- square image inside whatever box it is given rather than distorting it.
	art.ScaleType = Enum.ScaleType.Fit
	place(art, RW_LEFT_W, RW_BODY_H, (RW_LEFT_W - 132) / 2, 26, 132, 132)
	-- Centred from the middle, because the constraint below takes width away
	-- from a corner-anchored box and would leave it hard left.
	-- CENTRED ON BOTH AXES, not just across. The constraint below takes width
	-- from a corner-anchored box and would leave it hard left -- and the punch
	-- on a claim scales about the anchor, so a top-anchored swatch would grow
	-- downward out of its plate instead of swelling in place.
	art.AnchorPoint = Vector2.new(0.5, 0.5)
	art.Position = UDim2.fromScale(0.5, art.Position.Y.Scale + art.Size.Y.Scale / 2)
	art.Parent = plate
	roundOff(art, 10)
	self.rewardArtScale = Instance.new("UIScale")
	self.rewardArtScale.Name = "Scale"
	self.rewardArtScale.Parent = art
	-- SQUARE, WHATEVER SHAPE THE WINDOW IS. This page authors in Scale against a
	-- 16:9 reference, so on a letterboxed client every box is stretched by the
	-- same amount -- fine for a panel, and not fine for this one, because the
	-- geometry inside it IS the product and a stretched cross is not a cross.
	local square = Instance.new("UIAspectRatioConstraint")
	square.AspectRatio = 1
	square.DominantAxis = Enum.DominantAxis.Height
	square.Parent = art
	local artStroke = Instance.new("UIStroke")
	artStroke.Color = LINE
	artStroke.Thickness = 1.6
	artStroke.Transparency = 0.4
	artStroke.Parent = art
	-- Guarded, because REWARD_KEY is "" in a build with no reward def and
	-- indexOf would answer 1 -- the plate would quietly preview Solid, which is
	-- no pattern at all, and look like a rendering fault rather than a missing
	-- catalogue entry.
	if Patterns.REWARD_KEY ~= "" then
		art.ImageContent = Content.fromObject(Patterns.swatch(Patterns.indexOf(Patterns.REWARD_KEY)))
	end
	-- WHAT IS ACTUALLY IN THE BOX, read off the catalogue so this can never
	-- promise something the grant does not hand over. Three lines, in the order
	-- they matter: the skin's name, the one thing wearing it does, and the
	-- Money that comes with it.
	local reward = Patterns.byKey(Patterns.REWARD_KEY)
	setText(label(plate, "Words", RW_LEFT_W, RW_BODY_H, 0, 170, RW_LEFT_W, 26, INK, Enum.TextXAlignment.Center, FONT_BOLD),
		if reward then string.upper(reward.name) .. " SKIN" else "FREE REWARD")
	-- GREEN, because green on this page means gain -- the same colour the shop
	-- prints a skin's perk in, and the same words, off the same function.
	local perk = if reward then Patterns.perkText(reward) else nil
	setText(label(plate, "Perk", RW_LEFT_W, RW_BODY_H, 0, 202, RW_LEFT_W, 18, GAIN, Enum.TextXAlignment.Center, FONT_BOLD),
		if perk then string.gsub(string.gsub(perk, "%(", ""), "%)", "") else "")
	setText(label(plate, "Money", RW_LEFT_W, RW_BODY_H, 0, 232, RW_LEFT_W, 22, GOLD, Enum.TextXAlignment.Center, FONT_BOLD),
		"+ 1,000 MONEY")

	self.rewardRows = {}
	for i = 1, #RW_TASKS do
		self.rewardRows[i] = buildTaskRow(self, panel, i)
	end

	-- GREEN, the same green as the button that opened this sheet: it is the end
	-- of the one flow on this page that gives rather than asks.
	self.claimButton = pillButton(panel, "Claim", RW_W, RW_H,
		(RW_W - RW_CLAIM_W) / 2, RW_H - 34 - RW_CLAIM_H, RW_CLAIM_W, RW_CLAIM_H,
		"CLAIM", FREE_FILL, FREE_LINE)
	self.claimButton.Activated:Connect(function()
		if self.rewardClaimed then
			Sfx.play("Deny")
			LobbyUI.rewardSay(self, "YOU HAVE ALREADY CLAIMED THIS")
			return
		end
		if not self.rewardReady then
			-- The button is plainly dimmed, so this is for the player who pressed
			-- it anyway: silence there reads as a broken button. Deny is the same
			-- note the shop refuses a purchase with.
			--
			-- IT REPEATS BOTH STEPS rather than naming the one gate. Only the invite
			-- is actually holding the button -- the like cannot be checked by
			-- anything -- but a player who pressed CLAIM early has not followed the
			-- instructions, and the useful answer is the instructions, not a
			-- technically-precise note about which half the game can see.
			Sfx.play("Deny")
			LobbyUI.rewardSay(self, "LIKE THE GAME & INVITE A FRIEND")
			return
		end
		-- NO SOUND ON THE PRESS. The grant is the server's and can still be
		-- refused; the cheer belongs to the moment it actually lands, which is
		-- rewardLanded below.
		if self.onClaim then
			self.onClaim()
		end
	end)

	-- THE ONE LINE THIS SHEET SAYS OUT LOUD, and it is INSIDE the panel for a
	-- reason that was a plain bug: LobbyUI.toast writes to a label on the PAGE
	-- root, and this sheet's shade covers the page at ZIndex 20 -- so every
	-- refusal the claim button gave was rendered behind the modal that asked
	-- for it. PatternShop has had its own message line for exactly this reason.
	self.rewardMsg = label(panel, "Message", RW_W, RW_H, 0, RW_H - 34 - RW_CLAIM_H - 30, RW_W, 16, GOLD)
	self.rewardMsgUntil = 0

	-- THE WAY OUT, in the corner and in the shop's red, which on this page is
	-- already the colour of the one button that does not lead to a game.
	local close = pillButton(panel, "Close", RW_W, RW_H,
		RW_W - 16 - RW_CLOSE, 16, RW_CLOSE, RW_CLOSE, "X", RED, RED_LINE, POP_BACK)
	close.Activated:Connect(function()
		LobbyUI.closeRewards(self)
	end)

	shade.Activated:Connect(function()
		popPress(POP_BACK)
		LobbyUI.closeRewards(self)
	end)

	-- WHAT SPRINGS IN UNDER THE PANEL, in the order it is read. These are the
	-- pills' OWN UIScale (pillButton hangs one on every button it makes) and not
	-- a second one: only the first UIScale on an object does anything, so a
	-- second would be dead and the hover would look broken.
	self.rewardSprings = {}
	for _, entry in self.rewardRows do
		table.insert(self.rewardSprings, entry.scale)
	end
	-- CLAIM lands last, after every row it is waiting on.
	table.insert(self.rewardSprings, self.claimButton:FindFirstChildOfClass("UIScale"))
end

-- --------------------------------------------------------------- credits ---
--
-- THE CREDITS SHEET, and it is not decoration: it is where the licences this
-- game is built on are honoured. OpenFront's AGPL additional terms require
-- "© OpenFront and Contributors" somewhere reasonably visible; the AGPL itself
-- asks for the licence, the absence of warranty and how to get the source. See
-- LICENSING.md at the repo root.
--
-- NO URLS, ON PURPOSE. Roblox forbids off-platform links anywhere in an
-- experience except the Social Links on its page, so the source is pointed to
-- by way of those rather than spelled out.
--
-- Same modal furniture as FREE REWARDS -- shade, panel, corner X, backdrop
-- press to close, the same open and shut curves -- so it is the same piece of
-- furniture with different words on it.
local CR_W, CR_H = 760, 380

-- One line per entry, each one line tall, so every line of a kind renders at
-- one size. A wrapped paragraph under TextScaled picks its own size per box,
-- and three paragraphs would come out at three different sizes.
local CR_LINES: { { y: number, h: number, color: Color3, bold: boolean, text: string } } = {
	{ y = 104, h = 14, color = GOLD, bold = true, text = "BASED ON OPENFRONT" },
	{ y = 126, h = 22, color = INK, bold = true, text = "© OpenFront and Contributors" },
	{ y = 154, h = 16, color = INK_DIM, bold = false, text = "Modified by Bunni Games" },

	{ y = 196, h = 14, color = GOLD, bold = true, text = "LICENSE" },
	{ y = 218, h = 16, color = INK_DIM, bold = false, text = "This game's code is free software, licensed under the GNU Affero" },
	{ y = 242, h = 16, color = INK_DIM, bold = false, text = "General Public License v3 (AGPL). You may copy, modify and share it" },
	{ y = 266, h = 16, color = INK_DIM, bold = false, text = "under that license. It comes with NO WARRANTY." },
	{ y = 298, h = 16, color = INK, bold = false, text = "The full license and source code are available through the" },
	{ y = 322, h = 16, color = INK, bold = false, text = "community links on this game's page." },
}

local function buildCreditsPanel(self: any, parent: Instance)
	local shade = Instance.new("ImageButton")
	shade.Name = "CreditsShade"
	shade.Image = ""
	shade.AutoButtonColor = false
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(4, 6, 11)
	shade.BackgroundTransparency = 1
	shade.BorderSizePixel = 0
	shade.Visible = false
	shade.ZIndex = 20
	shade.Parent = parent
	self.creditsShade = shade

	local frost = Instance.new("ImageLabel")
	frost.Name = "Frost"
	frost.BackgroundTransparency = 1
	frost.Image = KIT_SCRIM
	frost.ScaleType = Enum.ScaleType.Stretch
	frost.ImageTransparency = 0.72
	frost.Size = UDim2.fromScale(1, 1)
	frost.ZIndex = 0
	frost.Parent = shade

	local panel = Instance.new("Frame")
	panel.Name = "CreditsPanel"
	panel.BackgroundColor3 = PANEL
	panel.BackgroundTransparency = 0.02
	panel.BorderSizePixel = 0
	panel.Active = true
	place(panel, REF_W, REF_H, (REF_W - CR_W) / 2, (REF_H - CR_H) / 2, CR_W, CR_H)
	panel.Parent = shade
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 12)
	pc.Parent = panel
	self.creditsScale = grower(panel)
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
	roundOff(pscrim, 12)

	kitSet(kitLabel(panel, "CreditsTitle", CR_W, CR_H, 0, 34, CR_W, 46, GOLD), "CREDITS")

	for i, line in CR_LINES do
		setText(label(panel, "Line" .. i, CR_W, CR_H, 40, line.y, CR_W - 80, line.h, line.color,
			Enum.TextXAlignment.Center, if line.bold then FONT_BOLD else FONT_UI), line.text)
	end

	local close = pillButton(panel, "Close", CR_W, CR_H,
		CR_W - 16 - RW_CLOSE, 16, RW_CLOSE, RW_CLOSE, "X", RED, RED_LINE, POP_BACK)
	close.Activated:Connect(function()
		LobbyUI.closeCredits(self)
	end)

	shade.Activated:Connect(function()
		popPress(POP_BACK)
		LobbyUI.closeCredits(self)
	end)
end

local function buildListPanel(self: any, parent: Instance)
	-- `Active`, so a press that misses the sheet cannot reach a card under it.
	local shade = Instance.new("Frame")
	shade.Name = "ListShade"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(4, 6, 11)
	shade.BackgroundTransparency = 0.35
	shade.BorderSizePixel = 0
	shade.Active = true
	shade.Visible = false
	shade.ZIndex = 20
	shade.Parent = parent
	self.listShade = shade

	local panel = Instance.new("Frame")
	panel.Name = "ListPanel"
	panel.BackgroundColor3 = PANEL
	panel.BackgroundTransparency = 0.02
	panel.BorderSizePixel = 0
	place(panel, REF_W, REF_H, LIST_X, LIST_Y, LIST_W, LIST_H)
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
	roundOff(pscrim, 12)

	kitSet(kitLabel(panel, "ListTitle", LIST_W, LIST_H, 0, 34, LIST_W, 46, GOLD), "ALL GAMES")

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Scroll"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	place(scroll, LIST_W, LIST_H, LIST_PAD, LIST_TOP, WIN_W, WIN_H)
	scroll.ScrollBarThickness = SCROLLBAR
	scroll.ScrollBarImageColor3 = LINE
	scroll.ScrollBarImageTransparency = 0.3
	scroll.CanvasSize = UDim2.new()
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	scroll.Parent = panel
	self.listScroll = scroll

	local flow = Instance.new("UIListLayout")
	flow.FillDirection = Enum.FillDirection.Vertical
	flow.SortOrder = Enum.SortOrder.LayoutOrder
	flow.Padding = UDim.new(0, 1)
	flow.Parent = scroll
	self.listFlow = flow

	-- The scrollbar's own lane, so the last column of a row is not under it.
	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, SCROLLBAR + 2)
	pad.Parent = scroll

	self.listRows = {}
	self.listShown = 0
	for i = 1, LIST_ROWS do
		self.listRows[i] = buildRow(self, scroll, i)
	end
	-- THE WINDOW TELLING US HOW BIG IT IS. It is zero on the frame the page is
	-- built in and correct on the next one, and it changes again whenever the
	-- player resizes the window or turns their phone.
	scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		fitRows(self)
	end)

	-- The one line the sheet needs words for: an empty list and a list that has
	-- not arrived yet look identical, and both look like a broken panel.
	self.listEmpty = label(panel, "Empty", LIST_W, LIST_H, 0, LIST_TOP + WIN_H / 2 - 12, LIST_W, 18, INK_OFF)
	setText(self.listEmpty, "NOTHING ELSE IS OPEN RIGHT NOW")
	self.listEmpty.Visible = false

	local close = pillButton(panel, "Close", LIST_W, LIST_H,
		(LIST_W - 240) / 2, LIST_H - 34 - 64, 240, 64, "BACK", nil, nil, POP_BACK)
	close.Activated:Connect(function()
		LobbyUI.closeList(self)
	end)
end

-- CLOSEST TO FILLING UP, FIRST -- the same rule the three cards are ranked by
-- (see fillRank), for the same reason, and a total order for the same reason
-- too: table.sort is not stable, so any pair this called equal would be free to
-- swap places on every board that arrives.
local function listRank(a: any, b: any): boolean
	if a.live ~= b.live then
		return a.live
	end
	local aLeft, bLeft = a.cap - a.count, b.cap - b.count
	if aLeft ~= bLeft then
		return aLeft < bLeft
	end
	local aFill = a.count / math.max(1, a.cap)
	local bFill = b.count / math.max(1, b.cap)
	if aFill ~= bFill then
		return aFill > bFill
	end
	-- Hosted lobbies before rooms, then by their own unique key: a slot key and
	-- a four-digit code are both unique and neither can collide with the other.
	if (a.kind == "slot") ~= (b.kind == "slot") then
		return a.kind == "slot"
	end
	return (a.key or a.code) < (b.key or b.code)
end

-- Everything the sheet knows how to show, as one array. The board's own views
-- arrive already decoded (`setBoard`); the rooms are decoded here because this
-- is the only thing that reads them.
--
-- WHAT IS ALREADY ON THE PAGE IS NOT IN HERE (2026-09-17, owner: "the three
-- already being displayed don't need to be displayed here"). The sheet is the
-- REST of the board -- it is reached through a door that says SEE ALL GAMES and
-- counts what is behind it, and repeating the three cards the player was
-- looking at a moment ago pushes the things they came here for below the fold.
--
-- Read off the CARDS rather than off the ranking, because the cards are what is
-- actually drawn: `rankBoard` can force the lobby you are in onto the last card
-- out of rank order, and the sheet must not then list it as well.
local function listItems(self: any): { any }
	local out = {}
	local onPage = {}
	for _, card in self.cards do
		onPage[card.slot] = true
	end
	for _, view in self.board or {} do
		if not onPage[view.slot] then
			local live = view.state == "open" and view.count < view.cap
			table.insert(out, {
				kind = "slot",
				key = Matchmaker.SLOTS[view.slot].key,
				art = MAP_ART[view.map] or "",
				name = string.upper(view.mapName),
				mode = string.upper(view.modeName),
				historical = view.historical == true,
				special = view.special == true,
				count = view.count,
				cap = view.cap,
				remaining = view.remaining,
				state = view.state,
				mine = view.mine,
				live = live or view.mine,
			})
		end
	end
	for _, room in self.rooms or {} do
		local s = room.settings
		-- RESOLVED, exactly as the room panel and the seat count already are.
		-- The MAP row KEEPS its index when a host steps the MODE past CLASSIC
		-- (see PrivateLobby.resolve), so a HISTORICAL room can still be carrying
		-- TOKYO while the round it launches is played on WORLD -- historical has
		-- two maps and resolve pins the rest to the first. Listing the raw index
		-- put the wrong name AND the wrong card art on a public room, and left
		-- the row disagreeing with its own cap, which resolves.
		local idx = PrivateLobby.resolve(s)
		local mapId = PrivateLobby.MAP[idx[1]] or PrivateLobby.MAP[1]
		local opt = PrivateLobby.modeOption(idx)
		table.insert(out, {
			kind = "room",
			code = room.code,
			art = MAP_ART[mapId] or "",
			name = PrivateLobby.label("map", idx[1], s),
			mode = if opt.id == "classic"
				then PrivateLobby.label("teams", s[2], s)
				else opt.label,
			historical = opt.id ~= "classic",
			special = opt.special == true,
			count = room.count,
			cap = room.cap,
			-- EVERY ROOM IN THIS LIST IS PUBLIC, and every public room starts
			-- on its own (PrivateLobby.PUBLIC_START) -- so a room's row carries
			-- a real countdown, same as a hosted lobby's.
			remaining = room.remaining,
			state = "open",
			-- A room you are already in is not in this list's business: the
			-- room panel is up over the page for you anyway.
			mine = false,
			live = room.count < room.cap,
			host = room.host,
		})
	end
	table.sort(out, listRank)
	return out
end

local function paintRow(entry: any, item: any)
	entry.item = item
	entry.live = item.live
	entry.row.Visible = true

	if entry.art.Image ~= item.art then
		entry.art.Image = item.art
	end
	setText(entry.name, item.name)
	-- The pill for any mode past the rotation: light blue for historical,
	-- gold for a special (see setBoard).
	local pill = item.historical == true or item.special == true
	entry.modeChip.Visible = pill
	entry.mode.Visible = not pill
	if pill then
		entry.modeChip.BackgroundColor3 = if item.special then MODE_PILL.special else MODE_PILL.historical
		setText(entry.modeChipText, item.mode)
	else
		setText(entry.mode, item.mode)
	end

	entry.face.Visible = item.kind == "room"
	if item.kind == "room" then
		local want = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", item.host)
		if entry.face.Image ~= want then
			entry.face.Image = want
		end
	end

	setText(entry.count, string.format("%d / %d", item.count, item.cap))

	-- The card's four states, in the card's own colours.
	local word, tint = nil, ACCENT
	if item.mine then
		word, tint = "JOINED", GAIN
	elseif item.state ~= "open" then
		word, tint = "GO", INK_OFF
	elseif item.count >= item.cap then
		word, tint = "FULL", INK_OFF
	else
		-- THE EMPTY ACCENT CHIP IS THE CLOCK'S. `step` fills it once a frame;
		-- what is set here is only its existence and its colour. Both kinds of
		-- row get one: a hosted lobby has always had a countdown, and a room in
		-- this list is public and therefore has one too.
		word, tint = "", ACCENT
	end
	entry.stateChip.Visible = word ~= nil
	if word ~= nil then
		entry.stateChip.BackgroundColor3 = tint
		setText(entry.stateText, word)
	end
	-- The clock, kept locally between boards exactly as a card's is.
	entry.remaining = item.remaining
	entry.at = os.clock()

	entry.stroke.Color = if item.mine then GAIN else LINE
	entry.stroke.Transparency = if item.mine then 0.1 else 0.45
	-- A row that cannot be pressed says so by not lighting up, and by going
	-- quiet: the same "will this do anything" answer the cards give.
	entry.name.TextColor3 = if item.live then INK else INK_OFF
	entry.row.BackgroundTransparency = if item.live then 0.25 else 0.5
end

local function paintList(self: any)
	if not self.listShade or not self.listShade.Visible then
		return
	end
	local items = listItems(self)
	local shown = math.min(#items, LIST_ROWS)
	for i, entry in self.listRows do
		if i <= shown then
			paintRow(entry, items[i])
		else
			entry.row.Visible = false
			entry.item = nil
			entry.live = false
		end
	end
	self.listEmpty.Visible = shown == 0
	self.listShown = shown
	fitRows(self)
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
	-- The room panel's clock, kept locally between records the way a card's is.
	self.roomRemaining = 0
	self.roomAt = 0
	-- The LEAVE guard, and the placeholder panel's clock. See setRoom.
	self.leftCode = nil :: string?
	self.leftAt = 0
	self.pendingAt = 0
	self.onJoin = nil :: ((string) -> ())?
	self.onLeave = nil :: (() -> ())?
	-- Which lobby each card position is drawing, fullest first. nil until the
	-- first board arrives, which is also what makes that first board rank: see
	-- rankBoard.
	self.order = nil :: { number }?
	-- THE PRIVATE-LOBBY HALF. LobbyClient assigns all five, and every one of
	-- them is a MemoryStore write on the far side -- which is why they go out
	-- through its one-a-second gate rather than straight down the remote.
	self.onCreate = nil :: ((...any) -> ())?
	self.onPatterns = nil :: (() -> ())?
	-- The CLAIM press. It goes out to LobbyClient for the same reason
	-- onPatterns does: this file draws, and the grant is the server's.
	self.onClaim = nil :: (() -> ())?
	-- THE INVITE PILL. LobbyClient owns what it opens, for the reason every
	-- other hook here exists: this file draws, and PromptGameInvite is a
	-- service call that belongs with the rest of the wiring.
	self.onInvite = nil :: (() -> ())?
	-- WHETHER THE GROUP STEP IS SATISFIED, and nothing here ever decides it:
	-- the server checks membership and pushes the answer down (setRewardState).
	-- A page that lit its own button would be a page that hands out the skin.
	self.rewardReady = false
	self.rewardsOpen = false
	self.creditsOpen = false
	-- Whether this account has already taken the one grant. The SERVER owns
	-- it (Data.freeReward) and pushes it down beside the patterns; nothing
	-- here ever sets it from a press. nil until that push has landed, which
	-- the button draws as "not yet" rather than as claimed -- a page that
	-- guessed CLAIMED while a profile was loading would be a page that hid a
	-- reward somebody still had coming.
	self.rewardClaimed = false
	-- THE SEE ALL GAMES SHEET. `board` is every lobby the last board carried --
	-- five now, of which the page draws three -- and `rooms` is the public
	-- rooms the server last read. Both are kept whole here rather than folded
	-- into the cards, because the sheet needs the ones the cards did not get.
	self.board = {} :: { any }
	self.rooms = {} :: { any }
	self.listOpen = false
	-- When this client last told the server it is looking. The server polls
	-- MemoryStore for the room list only while somebody says they are, so the
	-- sheet has to keep saying it -- see step.
	self.browseAt = 0
	self.onBrowse = nil :: ((boolean) -> ())?
	self.onRoomJoin = nil :: ((string) -> ())?
	self.onRoomLeave = nil :: (() -> ())?
	self.onRoomSettings = nil :: ((...any) -> ())?
	self.onRoomStart = nil :: (() -> ())?
	-- What this account's passes open in a room -- 0, PrivateLobby.TIER_HOST or
	-- TIER_ADVANCED -- as the server last said (setPassTier), and the way out
	-- to the pass prompt a locked arrow opens.
	self.passTier = 0
	self.onPassBuy = nil :: ((string) -> ())?

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
	place(bar, REF_W, REF_H, PAGE_M, BAR_Y, BAR_W, BAR_H)
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
	roundOff(barScrim, 10)

	setText(label(bar, "TagCap", CONTENT_W, BAR_H, 24, 32, 84, 13, INK_OFF, Enum.TextXAlignment.Left), "CLAN TAG")
	self.tagBox = field(bar, "Tag", CONTENT_W, BAR_H, 124, 20, 118, 34, "TAG", TAG_MAX, true, Enum.TextXAlignment.Center, true, false)
	self.nameBox = field(bar, "Name", CONTENT_W, BAR_H, 268, 20, 460, 36, "COMMANDER", NAME_MAX, false, Enum.TextXAlignment.Left, false, true)

	-- THE WORDMARK, in the slot the typed-out name held. Same right edge, so
	-- the bar's rhythm is unchanged; only the ink is the real logo now.
	--
	-- ScaleType.Fit, not Stretch. This page authors in Scale against a 16:9
	-- reference and the window is not always 16:9, so a Stretch would squash
	-- the mark on anything letterboxed -- the one thing here a player would
	-- read as a bug rather than a style. Fit keeps its proportions and
	-- letterboxes inside the box instead.
	--
	-- The box is 210x70 against a 78-tall bar: bigger than the 34 the text
	-- needed, because a third of the asset is transparent margin, so the
	-- letters themselves land about 49 tall and sit centred in the bar.
	local brand = Instance.new("ImageLabel")
	brand.Name = "Brand"
	brand.BackgroundTransparency = 1
	brand.Image = BRAND_LOGO
	brand.ScaleType = Enum.ScaleType.Fit
	brand.ZIndex = 5
	place(brand, CONTENT_W, BAR_H, CONTENT_W - 234, 4, 210, 70)
	brand.Parent = bar

	-- MONEY, in the gap the reference leaves between the name field and the
	-- brand. It goes HERE rather than on a card or a panel of its own for the
	-- same reason the clan tag does: it is a property of the account, not of
	-- any one lobby, and the bar is where this page keeps those.
	--
	-- Nothing spends it yet, so it is a readout and not a button, and it stays
	-- hidden until the server has actually said what the balance is -- a "0"
	-- printed while the profile is still loading is a worse answer than no
	-- number at all.
	self.moneyCap = label(bar, "MoneyCap", CONTENT_W, BAR_H, MONEY_X, 22, MONEY_W, 11, INK_OFF, Enum.TextXAlignment.Right)
	setText(self.moneyCap, "MONEY")
	self.moneyText = label(bar, "Money", CONTENT_W, BAR_H, MONEY_X, 36, MONEY_W, 24, GOLD, Enum.TextXAlignment.Right)
	self.moneyCap.Visible = false
	self.moneyText.Visible = false

	-- ------------------------------------------------------ free rewards --
	-- In the strip the bar stops short of, and GREEN for the reason the shop
	-- at the other end of the page is red: it is the one button up here that
	-- gives rather than asks, and colour says so before the caption is read.
	--
	-- THE GIFT COMES FIRST, LEFT OF THE WORDS. The glyph is what is spotted
	-- from across the page -- a caption this size is read only once the eye
	-- has already stopped here -- so it leads, and the caption centres in what
	-- is left rather than in the whole pill, which would slide it under the
	-- box.
	self.rewardsButton = pillButton(root, "FreeRewards", REF_W, REF_H,
		FREE_X, BAR_Y, FREE_W, BAR_H, "FREE REWARDS", FREE_FILL, FREE_LINE)
	-- The gift is 46 rather than 52 and sits tighter to the edge since the
	-- credits dot took a slice of this pill's width: the caption needed that
	-- room more than the glyph did.
	local gift = pixelImage(self.rewardsButton, "Gift", GIFT_ART)
	place(gift, FREE_W, BAR_H, 12, 16, 46, 46)
	local rewardsCap = self.rewardsButton:FindFirstChild("Caption") :: TextLabel
	place(rewardsCap, FREE_W, BAR_H, 64, (BAR_H - 20) / 2, FREE_W - 72, 20)
	self.rewardsButton.Activated:Connect(function()
		LobbyUI.openRewards(self)
	end)

	-- ----------------------------------------------------------- credits --
	-- The same dark pill every neutral button here is, same 10px corners,
	-- and as tall as the bar and FREE REWARDS beside it (owner, 2026-09-25:
	-- "it doesnt have to be a square, it can be rectangular to fill the
	-- space").
	self.creditsButton = pillButton(root, "Credits", REF_W, REF_H,
		INFO_X, BAR_Y, INFO_W, BAR_H, "i")
	local infoCap = self.creditsButton:FindFirstChild("Caption") :: TextLabel
	place(infoCap, INFO_W, BAR_H, 0, (BAR_H - 34) / 2, INFO_W, 34)
	self.creditsButton.Activated:Connect(function()
		LobbyUI.openCredits(self)
	end)

	-- ------------------------------------------------------------ nation --
	--
	-- THE FIELD IS THE PRODUCT, and it was already here: prefilled, sitting in
	-- the bar beside the clan tag, and going nowhere. What it gains is a server
	-- behind it -- the name is stored on the profile, survives the teleport
	-- into a match, and is what gets drawn across the player's own territory.
	--
	-- LOCKED IS THE RESTING STATE, because most visits have nothing to spend.
	-- A field you can type in and are then refused is worse than one that says
	-- up front what typing in it costs: the refusal AFTER the typing is the
	-- shape people read as the game having eaten their input.
	--
	-- Still prefilled with the Roblox display name, which is the answer for
	-- almost everyone and is exactly what the round falls back to if nothing
	-- has been bought (ConquestServer, off the ConquestNation attribute).
	local me = Players.LocalPlayer
	self.defaultName = me and string.sub(me.DisplayName, 1, NAME_MAX) or ""
	self.nationName = nil
	self.renameTokens = 0
	self.renamePrice = nil
	-- WHETHER A NATION PUSH HAS LANDED YET. The first one is not a purchase
	-- -- it is the account saying what it already owns -- and setNation
	-- reads this to tell the two apart.
	self.nationKnown = false
	self.nameBox.TextEditable = false

	-- Takes the press while the field is locked. A TextBox is not a GuiButton
	-- and has no Activated, so the affordance has to be a real button sitting
	-- over it rather than an input handler hung off the box.
	self.nameLock = Instance.new("TextButton")
	self.nameLock.Name = "NameLock"
	self.nameLock.BackgroundTransparency = 1
	self.nameLock.Text = ""
	self.nameLock.AutoButtonColor = false
	self.nameLock.ZIndex = 6
	place(self.nameLock, CONTENT_W, BAR_H, 268, 20, 460, 36)
	self.nameLock.Parent = bar

	-- The one line under the field. It says what pressing the field will cost,
	-- or how many renames are in hand -- both of which are facts the field
	-- itself cannot show. There is no caption for "this is your name": the name
	-- is sitting right there already saying it.
	self.nameCap = label(bar, "NameCap", CONTENT_W, BAR_H, 268, 60, 460, 11, GOLD, Enum.TextXAlignment.Left)

	-- THE ONE PRESS ON THIS PAGE THAT IS NOT A PILL, and it still has to
	-- answer like one -- see popPress. On the DOWN with all of them: what it
	-- opens is a purchase prompt a round trip away, and a silent press in
	-- front of that reads as a button that missed.
	self.nameLock.MouseButton1Down:Connect(function()
		popPress()
	end)
	self.nameLock.Activated:Connect(function()
		if self.onRenameBuy then
			self.onRenameBuy()
		end
	end)

	-- COMMITTED ON ENTER OR ON LOOKING AWAY, never per keystroke: a claim is a
	-- text-filter round trip and a DataStore write, so it happens once, when the
	-- player has decided.
	self.nameBox.FocusLost:Connect(function()
		-- Same unlock as paintNation: a token, or a name already worn.
		if self.renameTokens <= 0 and self.nationName == nil then
			return
		end
		local typed = string.gsub(self.nameBox.Text, "^%s*(.-)%s*$", "%1")
		-- Nothing typed, or nothing CHANGED. Spending a rename on the name you
		-- already have is the one refusal the server should never have to make.
		if typed == "" or typed == (self.nationName or self.defaultName) then
			LobbyUI.paintNation(self)
			return
		end
		if self.onRename then
			self.onRename(typed)
		end
	end)

	LobbyUI.paintNation(self)


	-- ONE BIG CARD AND TWO SMALL ONES, which is the reference's whole layout
	-- and the thing a row of three equal cards was not.
	--
	-- THREE FRAMES, NOT ONE PER SLOT (2026-09-17). The board holds five lobbies
	-- now and will hold more; the page shows the best THREE of whatever it is
	-- handed -- see rankBoard, which was already written that way, and setBoard,
	-- which walks these frames rather than the slot table. Building one card per
	-- slot would have stacked slots 4 and 5 on top of slot 3 in the same corner.
	local GEOM = {
		{ PAGE_M, BLOCK_Y, BIG_W, BLOCK_H },
		{ PAGE_M + BIG_W + COL_GAP, BLOCK_Y, SMALL_W, SMALL_H },
		{ PAGE_M + BIG_W + COL_GAP, BLOCK_Y + SMALL_H + SMALL_GAP, SMALL_W, SMALL_H },
	}
	self.cards = {}
	for i, g in GEOM do
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
				-- LEAVE THE OTHER ONE FIRST, HERE AS WELL AS ON THE SERVER.
				-- A player is in at most one lobby and the "join" intent
				-- enforces that by removing them from the old slot before
				-- adding them to the new one -- but the page only learned
				-- about it when the next board landed, and until then the
				-- card you just left kept its green JOINED stroke and its
				-- seat. For that moment the page said you were queued for
				-- two matches at once, which is the one thing it must never
				-- say. Painted before the new card so the counts never both
				-- hold you.
				for _, other in self.cards do
					if other ~= entry and other.shownMine then
						press(other, false)
					end
				end
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
			-- ONE SOUND PER PRESS, ON THE DOWN, like every pill on the page --
			-- and the card is where that rule is worth stating, because it is
			-- the one control whose press has two opposite meanings. WHICH note
			-- is the same question the Activated handler above asks, answered
			-- here because this is the instant the finger lands rather than the
			-- instant it lifts.
			--
			-- A press that will do NOTHING -- a full card, or a round already
			-- starting -- still gets an answer, and the plain click is it: on
			-- this page a pop means something happened.
			if entry.state ~= "open" or (entry.shownFull and not entry.shownMine) then
				Sfx.play("Click")
			else
				popPress(if entry.shownMine then POP_BACK else POP_GO)
			end
		end)
		entry.card.MouseButton1Up:Connect(function()
			entry.held = false
			motion(entry, PRESS_OUT)
		end)
	end


	-- THE DOOR, in the third of the right column (2026-09-17). Built from the
	-- page's own pill so it hovers, presses and sounds like everything else
	-- here -- it is not a card and must not pretend to be one, because pressing
	-- it joins nothing.
	--
	-- The caption is re-placed bigger than a pill's: a 20px word centred in a
	-- 142-tall panel reads as a label that lost its button.
	self.moreButton = pillButton(root, "MoreGames", REF_W, REF_H,
		PAGE_M + BIG_W + COL_GAP, BLOCK_Y + (SMALL_H + SMALL_GAP) * 2, SMALL_W, DOOR_H,
		"SEE ALL GAMES")
	local moreCap = self.moreButton:FindFirstChild("Caption") :: TextLabel
	-- The pair is centred as a BLOCK: 30 of caption, 4 of air and 14 of count is
	-- 48, so it starts 14 down in a 76-tall pill. Centring each line on its own
	-- half would leave the caption riding high with a gap under the number.
	place(moreCap, SMALL_W, DOOR_H, 0, DOOR_H / 2 - 24, SMALL_W, 30)
	-- HOW MANY, under it. This is not a caption explaining the button -- the
	-- button already says what it opens; it is the one fact that decides
	-- whether opening it is worth doing, and no shape on the page carries it.
	-- Blank until a board has actually arrived: "0 GAMES OPEN" printed over a
	-- page that has not loaded is a worse answer than nothing.
	self.moreCount = label(self.moreButton, "Count", SMALL_W, DOOR_H,
		0, DOOR_H / 2 + 10, SMALL_W, 14, INK_DIM, Enum.TextXAlignment.Center)
	self.moreCount.ZIndex = 3
	self.moreButton.Activated:Connect(function()
		LobbyUI.openList(self)
	end)

	-- SHOP / CREATE LOBBY / JOIN LOBBY, across the span the reference gives
	-- its three. Still no SOLO and no RANKED: a solo button on a page whose whole
	-- point is filling a lobby is a way out of the thing you came for, and
	-- there is no ranked ladder to enter. And no LEARN TO PLAY: a player who
	-- has never been here is already inside the tutorial by the time this page
	-- would first draw for them, so the button could only ever have offered
	-- them the thing they had just finished. /tutorial is the way back in.
	self.patternButton = pillButton(root, "Shop", REF_W, REF_H,
		PAGE_M, BTN_Y, BTN_W, BTN_H, "SHOP", RED, RED_LINE)
	self.createButton = pillButton(root, "CreateLobby", REF_W, REF_H,
		PAGE_M + BTN_W + BTN_GAP, BTN_Y, BTN_W, BTN_H, "CREATE LOBBY")
	self.joinButton = pillButton(root, "JoinLobby", REF_W, REF_H,
		PAGE_M + (BTN_W + BTN_GAP) * 2, BTN_Y, BTN_W, BTN_H, "JOIN LOBBY")

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
	-- The shop is a page of its own (`PatternShop`) rather than another view
	-- of the room panel: it has nothing to do with lobbies, and the room
	-- panel's two views are already two things that are never both true.
	-- LobbyClient owns the wiring, the same way it owns every other press.
	self.patternButton.Activated:Connect(function()
		if self.onPatterns then
			self.onPatterns()
		end
	end)

	-- Only ever visible while a toast is up; the reference has nothing here.
	self.toastLabel = label(root, "Toast", REF_W, REF_H, PAGE_M, BTN_Y - 22, CONTENT_W, 16, GOLD)
	self.toastUntil = 0

	-- LAST, so they are the last siblings in `root` and therefore already above
	-- everything even before their ZIndex is considered. The room panel goes
	-- second because a room press made from the sheet opens it OVER the sheet
	-- for the moment before the sheet closes.
	buildListPanel(self, root)
	buildRewardsPanel(self, root)
	buildCreditsPanel(self, root)
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

-- WHICH LOBBY GETS THE BIG CARD (2026-09-01, owner: "for every new player that
-- comes onto the find games page, always have the game closest to filling up as
-- the biggest one on the left").
--
-- The three cards are FIXED FRAMES -- one big on the left, two small down the
-- right -- and what moves between them is which lobby each one draws. Nothing
-- on a card is tied to its position any more except `key`, which is the slot a
-- press joins and is therefore written from the view alongside everything else.
--
-- CLOSEST TO FILLING UP IS SEATS LEFT, NOT PERCENTAGE. A card needing two more
-- players is nearer to a full game than one that is 80% of the way through
-- twenty-four, and seats left is also what a player is actually reading when
-- they pick: how many more before this is a real match. Percentage only breaks
-- the tie, so 9/12 outranks 3/6 -- both need three -- and after that the sooner
-- clock, and after that the slot, which is unique and makes this a TOTAL order.
-- That last part matters more than it looks: table.sort is not stable, and any
-- pair the comparator called equal would be free to swap places on every board
-- that arrives, which is a page that shuffles itself once a second.
--
-- A LOBBY YOU CANNOT JOIN SINKS, however full it is. Full is the extreme of
-- "closest to filling up" and also the one card a press does nothing on, and a
-- lobby mid-launch (claim / ready) is the same: giving either the big slot
-- spends the best position on the page on a dead end.
local function fillRank(a: Matchmaker.CardView, b: Matchmaker.CardView): boolean
	local aOpen = a.state == "open" and a.count < a.cap
	local bOpen = b.state == "open" and b.count < b.cap
	if aOpen ~= bOpen then
		return aOpen
	end
	local aLeft, bLeft = a.cap - a.count, b.cap - b.count
	if aLeft ~= bLeft then
		return aLeft < bLeft
	end
	local aFill = a.count / math.max(1, a.cap)
	local bFill = b.count / math.max(1, b.cap)
	if aFill ~= bFill then
		return aFill > bFill
	end
	if a.remaining ~= b.remaining then
		return a.remaining < b.remaining
	end
	return a.slot < b.slot
end

-- The card positions, in order, holding the index of the view each one draws.
--
-- RANKED ONCE, THEN REPLACED ONLY WHEN A CARD IS SPENT (2026-09-17). The first
-- board a client sees is sorted by fillRank -- the page's argument for what to
-- join, made for somebody who has just walked onto it. After that a card KEEPS
-- its lobby until that lobby can no longer be joined (full, mid-launch, gone),
-- and only then does the best lobby not already on the page take its place.
-- Counts moving on other cards, a fresh mint overtaking a shown card, leaving a
-- lobby: none of these move anything. The old rule re-sorted on every board,
-- so under load the three cards swapped maps under the reader's cursor with
-- nearly every join ("the maps reindex themselves a lot when there are a lot
-- of players").
--
-- Two moves are still made for you. A press in flight holds everything -- a
-- page that rearranges itself between the press starting and landing joins
-- you to the wrong lobby. And the lobby you are IN is always on the page,
-- taking the LAST card if it was not already drawn (a join from the SEE ALL
-- GAMES sheet is very often one the page had no room for); it is kept there
-- even once it is full, because that card wears your JOINED stroke and its
-- launch is the thing you are waiting on.
local function joinable(view: Matchmaker.CardView?): boolean
	return view ~= nil and view.state == "open" and view.count < view.cap
end

local function rankBoard(self: LobbyUI, cards: { Matchmaker.CardView }): { number }
	local seats = #self.cards
	local held = self.order
	if held == nil then
		local order = {}
		for i in cards do
			order[#order + 1] = i
		end
		table.sort(order, function(x, y)
			return fillRank(cards[x], cards[y])
		end)
		local mineAt = nil
		for pos, index in order do
			if cards[index].mine then
				mineAt = pos
			end
		end
		if mineAt and mineAt > seats then
			table.insert(order, seats, table.remove(order, mineAt))
		end
		-- A PRESS MADE BEFORE THE FIRST BOARD CANNOT BE HONOURED. There is no
		-- previous order to pin it to, so the sort above may point the pressed
		-- slot at a different lobby -- and the optimistic JOINED paint and the
		-- frozen countdown would then belong to a lobby the player never pressed
		-- (the reconcile refuses to clear a pending that disagrees, so it holds
		-- for PENDING_HOLD). Drop the mark and let the board speak.
		for _, entry in self.cards do
			entry.pending = nil
		end
		self.order = order
		return order
	end

	for _, entry in self.cards do
		if entry.pending ~= nil then
			return held
		end
	end

	-- Only the drawn positions are pinned; the first board's tail is dropped.
	for pos = #held, seats + 1, -1 do
		held[pos] = nil
	end
	local onPage = {}
	for pos = 1, seats do
		if held[pos] then
			onPage[held[pos]] = true
		end
	end

	local mineIndex = nil
	for i, view in cards do
		if view.mine then
			mineIndex = i
		end
	end
	if mineIndex and not onPage[mineIndex] then
		local was = held[seats]
		if was then
			onPage[was] = nil
		end
		held[seats] = mineIndex
		onPage[mineIndex] = true
	end

	-- The bench: every joinable lobby the page is not drawing, best first.
	local bench = {}
	for i, view in cards do
		if not onPage[i] and joinable(view) then
			bench[#bench + 1] = i
		end
	end
	table.sort(bench, function(x, y)
		return fillRank(cards[x], cards[y])
	end)

	local take = 1
	for pos = 1, seats do
		local view = cards[held[pos]]
		local spent = not joinable(view) and not (view ~= nil and view.mine)
		if spent and bench[take] then
			held[pos] = bench[take]
			take += 1
		end
	end

	-- A LOBBY THAT IS GONE (its slot retired past the live count, 2026-09-19)
	-- cannot stay on a card the way a spent one can: there is nothing left to
	-- draw, and setBoard would leave the card frozen on its last paint. With
	-- the bench empty, take the best of what is left, joinable or not -- a
	-- STARTING card is a real lobby, a frozen one is a lie.
	local drawn = {}
	for pos = 1, seats do
		if held[pos] then
			drawn[held[pos]] = true
		end
	end
	for pos = 1, seats do
		if held[pos] ~= nil and cards[held[pos]] == nil then
			local best = nil
			for i, view in cards do
				if not drawn[i] and (best == nil or fillRank(view, cards[best])) then
					best = i
				end
			end
			if best then
				drawn[held[pos]] = nil
				held[pos] = best
				drawn[best] = true
			end
		end
	end
	return held
end

function LobbyUI.setBoard(self: LobbyUI, cards: { Matchmaker.CardView })
	-- KEPT WHOLE, not just the three the page draws. The board carries every
	-- lobby the game is running and the sheet is the only thing that shows all
	-- of them; the cards take the top three out of the same array below.
	self.board = cards
	local order = rankBoard(self, cards)
	for pos, entry in self.cards do
		local view = cards[order[pos]]
		if view then
			-- WHICH LOBBY THIS CARD IS. Everything the card draws already came
			-- from the view; this is the one thing that used to come from the
			-- card's position, and a press reads it to say what it is joining.
			entry.slot = view.slot
			entry.key = Matchmaker.SLOTS[view.slot].key

			-- Written every update because a slot's map changes between
			-- rounds; the compare keeps it from re-fetching the same image.
			local art = MAP_ART[view.map] or ""
			if entry.art.Image ~= art then
				entry.art.Image = art
			end
			setText(entry.mapName, string.upper(view.mapName))
			setText(entry.modeName, string.upper(view.modeName))
			-- A historical card wears its mode as the light-blue pill and not
			-- as the plain line (see buildCard); a SPECIAL card (Modes.SPECIAL,
			-- 2026-09-18) wears the same pill in gold, so a card that is only
			-- there now and then reads as one at a glance.
			local pill = view.historical == true or view.special == true
			entry.modeChip.Visible = pill
			entry.modeName.Visible = not pill
			if pill then
				entry.modeChip.BackgroundColor3 = if view.special then MODE_PILL.special else MODE_PILL.historical
				setText(entry.modeChipText, string.upper(view.modeName))
			end
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
			end

			paintCard(entry)
		end
	end

	LobbyUI.paintDoor(self)
	paintList(self)
end

-- The public rooms, as the server last read them. Only ever sent to a client
-- that said it was looking -- see MatchmakerServer's `browse`.
function LobbyUI.setRooms(self: LobbyUI, wire: any)
	local out = {}
	if type(wire) == "table" then
		for _, w in wire do
			local room = PrivateLobby.readListing(w)
			-- NOT THE ROOM YOU ARE IN. It is public, so it is in the list the
			-- server sent everybody -- but your own room is already open on the
			-- page in front of you, and a row offering to join it again is a
			-- row that does nothing.
			if room and (not self.room or self.room.code ~= room.code) then
				table.insert(out, room)
			end
		end
	end
	self.rooms = out
	LobbyUI.paintDoor(self)
	paintList(self)
end

-- WHAT IS BEHIND THE DOOR, as the one number that decides whether opening it is
-- worth doing. It counts what this client can PROVE: every lobby on the board
-- the three cards did not get, plus every public room it has been told about.
--
-- The rooms are only pushed while the sheet is open (the server reads them for
-- nobody otherwise), so before the first look this is the lobbies alone -- an
-- UNDERCOUNT, never an overcount, which is the right way round for a number
-- offering more than you can see. Blank until a board has actually arrived.
function LobbyUI.paintDoor(self: LobbyUI)
	-- COUNTED, NOT MEASURED WITH #. The board is indexed by slot, and a slot
	-- past the live count with nothing in it is a hole (Matchmaker.readWire);
	-- # over a table with holes is whichever border Luau finds first.
	local lobbies = 0
	for _ in self.board do
		lobbies += 1
	end
	local extra = math.max(0, lobbies - #self.cards) + #self.rooms
	setText(self.moreCount, if lobbies == 0 then "" else "+" .. extra .. " MORE")
end

function LobbyUI.openList(self: LobbyUI)
	self.listOpen = true
	self.listShade.Visible = true
	self.listScroll.CanvasPosition = Vector2.new(0, 0)
	-- SAY SO AT ONCE. The server polls MemoryStore for the room list only while
	-- somebody has this open, so the first thing the sheet does is ask -- and
	-- the answer to that ask is the previous poll's list, immediately, with a
	-- fresh one a moment behind it.
	self.browseAt = os.clock()
	if self.onBrowse then
		self.onBrowse(true)
	end
	paintList(self)
end

function LobbyUI.closeList(self: LobbyUI)
	self.listOpen = false
	self.listShade.Visible = false
	if self.onBrowse then
		self.onBrowse(false)
	end
end


-- --------------------------------------------------------------- rewards ---

function LobbyUI.openRewards(self: LobbyUI)
	self.rewardsOpen = true
	LobbyUI.paintRewards(self)
	-- EVERYTHING SET TO ITS "NOT HERE YET" STATE BEFORE THE SHEET IS SHOWN, so
	-- no frame of the finished panel is ever on screen first.
	self.rewardShade.BackgroundTransparency = 1
	self.rewardScale.Scale = RW_PANEL_FROM
	for _, s in self.rewardSprings do
		s.Scale = RW_ROW_FROM
	end
	self.rewardShade.Visible = true
	tween(self.rewardShade, RW_OPEN_SHADE, { BackgroundTransparency = RW_SHADE_ALPHA })
	tween(self.rewardScale, RW_OPEN_PANEL, { Scale = 1 })
	for i, s in self.rewardSprings do
		task.delay(RW_ROW_LEAD + (i - 1) * RW_ROW_STEP, function()
			-- A sheet shut before its own sweep finished must not have the rest
			-- of that sweep land on it afterwards.
			if self.rewardsOpen then
				tween(s, RW_ROW_IN, { Scale = 1 })
			end
		end)
	end
	setText(self.rewardMsg, "")
	self.rewardMsgUntil = 0
end

function LobbyUI.closeRewards(self: LobbyUI)
	if not self.rewardsOpen then
		return
	end
	self.rewardsOpen = false
	setText(self.rewardMsg, "")
	self.rewardMsgUntil = 0
	tween(self.rewardShade, RW_SHUT, { BackgroundTransparency = 1 })
	tween(self.rewardScale, RW_SHUT, { Scale = RW_PANEL_FROM })
	-- HIDDEN AFTER THE FADE, and only if nothing reopened it in the meantime:
	-- a sheet shut and reopened inside those twelve hundredths would otherwise
	-- be hidden by the close it had already outlived.
	task.delay(0.12, function()
		if not self.rewardsOpen then
			self.rewardShade.Visible = false
		end
	end)
end

-- --------------------------------------------------------------- credits ---

-- The rewards sheet's arrival, minus the row sweep: this sheet has nothing
-- that springs, only words.
function LobbyUI.openCredits(self: LobbyUI)
	self.creditsOpen = true
	self.creditsShade.BackgroundTransparency = 1
	self.creditsScale.Scale = RW_PANEL_FROM
	self.creditsShade.Visible = true
	tween(self.creditsShade, RW_OPEN_SHADE, { BackgroundTransparency = RW_SHADE_ALPHA })
	tween(self.creditsScale, RW_OPEN_PANEL, { Scale = 1 })
end

function LobbyUI.closeCredits(self: LobbyUI)
	if not self.creditsOpen then
		return
	end
	self.creditsOpen = false
	tween(self.creditsShade, RW_SHUT, { BackgroundTransparency = 1 })
	tween(self.creditsScale, RW_SHUT, { Scale = RW_PANEL_FROM })
	task.delay(0.12, function()
		if not self.creditsOpen then
			self.creditsShade.Visible = false
		end
	end)
end

-- BOTH FACTS AT ONCE, and both are the SERVER'S: whether this account has
-- already taken the grant, and whether it is in the group that opens it. They
-- arrive on one push because a claim moves both of them in the same instant.
function LobbyUI.setRewardState(self: LobbyUI, claimed: boolean?, ready: boolean?)
	local was = self.rewardClaimed == true
	self.rewardClaimed = claimed == true
	self.rewardReady = ready == true
	LobbyUI.paintRewards(self)
	-- ON THE TRANSITION AND NOWHERE ELSE. Every patterns push carries this
	-- state, so a celebration keyed on the VALUE rather than the CHANGE would
	-- replay itself every few seconds for the rest of the session -- and would
	-- fire once on arrival for somebody who claimed a week ago.
	if self.rewardClaimed and not was and self.rewardsOpen then
		LobbyUI.rewardLanded(self)
	end
end

-- WHAT LANDING LOOKS LIKE. The PLATE takes the flourish rather than the
-- button: the button has just become a dead word, and the thing worth looking
-- at is what arrived on the left.
function LobbyUI.rewardLanded(self: LobbyUI)
	Sfx.play("Cheer")
	local s = self.rewardPlateStroke
	s.Color = GOLD
	s.Thickness = 4
	s.Transparency = 0
	tween(s, RW_LAND_FLASH, { Color = LINE, Thickness = 1.6, Transparency = 0.45 })
	self.rewardArtScale.Scale = 1.18
	tween(self.rewardArtScale, RW_LAND_PUNCH, { Scale = 1 })
	-- The one thing the sheet cannot show: where the skin went.
	LobbyUI.rewardSay(self, "CLAIMED -- WEAR IT IN THE SHOP")
end

-- The sheet's own message line. Four seconds, cleared in `step`.
function LobbyUI.rewardSay(self: LobbyUI, text: string)
	setText(self.rewardMsg, text)
	self.rewardMsgUntil = os.clock() + 4
end


function LobbyUI.paintRewards(self: LobbyUI)
	-- ONE GATE: the group, as the server last answered it. The other two steps
	-- are unverifiable (see RW_TASKS) so they are drawn the same whatever the
	-- player has done -- a row that changed state off nothing would be the page
	-- inventing a fact.
	local ready = self.rewardReady == true
	-- The claim button carries the whole state of the sheet: green and lit
	-- once both steps are in, the page's dead panel until then. It stays
	-- PRESSABLE either way -- a button that cannot be pressed cannot say why.
	-- ALREADY TAKEN BEATS READY. Both steps stay ticked for somebody who has
	-- claimed -- they did do them -- so without this the button would sit
	-- green and inviting over a reward that is gone.
	local taken = self.rewardClaimed == true
	local cap = self.claimButton:FindFirstChild("Caption") :: TextLabel
	setText(cap, if taken then "CLAIMED" else "CLAIM")
	self.claimButton.BackgroundColor3 = if ready and not taken then FREE_FILL else PANEL
	cap.TextColor3 = if ready and not taken then INK else INK_OFF
	ready = ready and not taken
	local stroke = self.claimButton:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if ready then FREE_LINE else LINE
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
	-- The values drawn are the RESOLVED ones -- what the round will actually
	-- be -- while the steppers go on holding the raw indexes. See
	-- PrivateLobby.resolve.
	local shown = PrivateLobby.resolve(self.roomSettings)
	for i, f in PrivateLobby.FIELDS do
		local row = self.rows[i]
		setText(row.value, PrivateLobby.label(f.key, shown[f.slot] or 1, self.roomSettings))
		-- GUESTS SEE THE SETTINGS AND NOT THE ARROWS. Hiding the control is
		-- the honest version of disabling it: there is no press to refuse.
		-- The same goes for a row the MODE has decided (HISTORICAL's map and
		-- teams).
		local arrows = host and open and not PrivateLobby.fixed(f.key, self.roomSettings)
		row.dec.Visible = arrows
		row.inc.Visible = arrows
		-- ...but a row a PASS would open keeps its arrows, dimmed: the arrow
		-- is the offer. See the stepper.
		local dim = if self.passTier < PrivateLobby.tierFor(f.key) then 0.6 else 0
		for _, b in { row.dec, row.inc } do
			local cap: any = b:FindFirstChild("Caption")
			if cap then
				cap.TextTransparency = dim
			end
		end
	end

	paintFaces(self.roomRoster, view.users, self.myUserId)
	-- THE ROOM'S OWN CEILING, which the MAP may lower -- a Korea room holds two
	-- and must not advertise 24 (see PrivateLobby.capFor). The join is refused
	-- at the real number server-side either way; this is what stops the panel
	-- promising seats that would be turned away.
	setText(self.roomCount, string.format("%d / %d", view.count, PrivateLobby.capFor(view.settings)))

	-- READ OFF THE RECORD, not off `self.roomSettings`. A host's own stepper is
	-- believed locally for two seconds (see setRoom), and believing the PUBLIC
	-- flip that way would put the chip up a beat before the server had written
	-- the deadline -- so it would read 0s, which is the one thing a countdown
	-- must never say while there is time left. The flip's own commit pushes the
	-- record back immediately, so the honest version is not slower by anything
	-- anyone can see.
	local counting = open and PrivateLobby.isPublic(view.settings)
	self.roomClockChip.Visible = counting
	if counting then
		-- Two numbers and the page runs the clock itself, exactly as a card
		-- does: what the server last said, and when it said it. The text is
		-- written once a frame in `step`.
		self.roomRemaining = view.remaining or 0
		self.roomAt = os.clock()
	end

	self.startButton.Visible = host and not pending
	self.waitLabel.Visible = pending or not host
	-- WAITING FOR THE HOST IS A LIE IN A PUBLIC ROOM -- it starts whether or
	-- not the host does anything, and the chip above already says when. So the
	-- line goes rather than being reworded into a second copy of the clock.
	setText(self.waitLabel, pending and "CREATING LOBBY"
		or (open and (counting and "" or "WAITING FOR THE HOST") or "STARTING"))
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
		remaining = 0,
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


-- ---------------------------------------------------------------- nation ---

-- The two states the name field can be in, and the only place that chooses
-- between them. `nationName` is what the SERVER has accepted -- never what was
-- typed -- and `renameTokens` is what is left to spend.
--
-- A NAME ALREADY WORN UNLOCKS THE FIELD ON ITS OWN, with no token needed:
-- the product buys the right to be named and the edits after it are free
-- (see ConquestNames.claim, which is where that rule is actually enforced --
-- this only has to agree with it).
function LobbyUI.paintNation(self: LobbyUI)
	local named = self.nationName ~= nil
	local owned = self.renameTokens > 0 or named
	self.nameBox.TextEditable = owned
	self.nameLock.Visible = not owned
	-- NEVER WHILE THEY ARE TYPING. A push landing mid-edit would swap the
	-- half-typed name for the old one out from under the caret.
	if not self.nameBox:IsFocused() then
		local s = string.sub(self.nationName or self.defaultName or "", 1, NAME_MAX)
		if self.nameBox.Text ~= s then
			self.nameBox.Text = s
		end
	end
	-- THE COUNT, NOT THE UNLOCK. These two came apart the moment a name could
	-- unlock the field by itself: a free editor holds zero tokens, and "0
	-- RENAMES" under a field they can type in is the page contradicting
	-- itself. Nothing under the field is the right answer there -- being
	-- able to type in it is already the whole message.
	if self.renameTokens > 0 then
		-- AN INVENTORY, NOT A LABEL. The count is the part worth saying; "you
		-- may type here" is already said by a field that takes a caret.
		setText(self.nameCap, self.renameTokens == 1 and "1 RENAME" or (self.renameTokens .. " RENAMES"))
		self.nameCap.TextColor3 = GAIN
		self.nameCap.Visible = true
	else
		-- NOTHING UNDER THE FIELD WHEN THERE IS NOTHING IN HAND (2026-09-04,
		-- owner). It used to price the purchase here -- "RENAME  16 R$" --
		-- which put a price tag in the top bar of a page whose job is to get
		-- you into a game, and it was there on EVERY visit, since not owning a
		-- rename is the resting state. The affordance survives without it: the
		-- field is still pressable and the purchase prompt still names the
		-- price, which is the only place the region-correct number was ever
		-- authoritative anyway. `renamePrice` is still tracked for it.
		self.nameCap.Visible = false
	end
end

-- The account's nation name and its remaining renames, straight off the wire.
-- `name` is nil for anyone who has never bought one -- which is not the same as
-- an empty string, and is what falls the field back to the display name.
function LobbyUI.setNation(self: LobbyUI, name: any, tokens: any)
	local had = self.renameTokens
	self.nationName = (type(name) == "string" and name ~= "") and name or nil
	self.renameTokens = math.max(0, tonumber(tokens) or 0)
	LobbyUI.paintNation(self)
	-- THE CARET IS THE RECEIPT. A purchase that quietly unlocks a field reads
	-- as nothing having happened at all, and this is the one moment where
	-- taking the player's focus is precisely what they just paid for.
	-- ...but only for a purchase made WHILE THE PAGE IS OPEN. The first push
	-- is the standing balance, and taking the caret there dropped anyone who
	-- joined holding a spare rename straight into the text field on boot,
	-- typing their first keys into their own name (2026-09-17, owner).
	if self.nationKnown and had == 0 and self.renameTokens > 0 then
		self.nameBox:CaptureFocus()
	end
	self.nationKnown = true
end

function LobbyUI.setRenamePrice(self: LobbyUI, robux: any)
	self.renamePrice = tonumber(robux)
	LobbyUI.paintNation(self)
end


-- What the two fields hold right now, trimmed. The NAME is now server-owned --
-- `setNation` writes it and the round reads it off the profile -- so this is
-- the clan tag's route out and nothing should send the name back from here.
function LobbyUI.identity(self: LobbyUI): (string, string)
	local name = string.gsub(self.nameBox.Text, "^%s*(.-)%s*$", "%1")
	local tag = string.gsub(self.tagBox.Text, "^%s*(.-)%s*$", "%1")
	return name, tag
end

-- The account's Money balance. nil is "not known yet", which is not the same
-- as zero and is drawn as nothing at all.
function LobbyUI.setMoney(self: LobbyUI, amount: number?)
	local known = type(amount) == "number"
	self.moneyCap.Visible = known
	self.moneyText.Visible = known
	if known then
		local s = string.format("%.0f", math.max(0, amount :: number))
		local out = ""
		while #s > 3 do
			out = "," .. string.sub(s, -3) .. out
			s = string.sub(s, 1, -4)
		end
		setText(self.moneyText, s .. out)
	end
end

-- Which room dials this account's passes open (see `passTier`). Repaints a room
-- that is up, so a pass bought from a dimmed arrow lights the arrows the moment
-- the server has confirmed it.
function LobbyUI.setPassTier(self: LobbyUI, tier: number)
	self.passTier = tier
	if self.room then
		LobbyUI.paintRoom(self)
	end
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
	-- The rewards sheet's own line, on the same clock as the page's toast.
	if self.rewardMsgUntil > 0 and os.clock() > self.rewardMsgUntil then
		self.rewardMsgUntil = 0
		setText(self.rewardMsg, "")
	end
	local now = os.clock()
	for _, entry in self.cards do
		local left = math.max(0, entry.remaining - (now - entry.at))
		if entry.state ~= "open" then
			setText(entry.clock, "GO")
		else
			-- AN EMPTY CARD SHOWS THE LIVE CLOCK TOO. A frozen 1:00 used to
			-- stand in for "nobody has joined yet"; every record has been born
			-- counting down since the phantom seats went in, which made that
			-- branch dead -- until Korea's card (no phantom seats, 2026-09-17)
			-- could read 0 / 2 and would have sat under a stopped clock, which
			-- is exactly the page the phantoms exist to prevent.
			setText(entry.clock, longClock(left))
		end
	end
	-- THE SHEET'S OWN CLOCKS, and only while it is up. A board arrives about
	-- once a second while something is moving and only every few seconds when
	-- nothing is, so a row that waited for one would tick in five-second jumps.
	-- Same two numbers as a card: what the server last said, and when.
	if self.listOpen then
		for _, entry in self.listRows do
			local item = entry.item
			if entry.row.Visible and item and item.state == "open" and not item.mine and item.count < item.cap then
				setText(entry.stateText, longClock(math.max(0, entry.remaining - (now - entry.at))))
			end
		end
		-- KEEPING THE SERVER LOOKING. It drops a browser that has stopped
		-- saying so (BROWSE_STALE), which is what makes a disconnected client
		-- cost nothing -- so an open sheet has to keep saying it.
		if now - self.browseAt > 10 then
			self.browseAt = now
			if self.onBrowse then
				self.onBrowse(true)
			end
		end
	end

	-- THE ROOM PANEL'S OWN CLOCK, on the same two numbers as everything else
	-- here. Only a public room has one, and `paintRoom` is what decides that.
	if self.roomClockChip and self.roomClockChip.Visible then
		setText(self.roomClock, longClock(math.max(0, self.roomRemaining - (now - self.roomAt))))
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


-- ------------------------------------------------------------------- kit ---
-- PUBLISHED, so the pattern shop can be drawn in this page's own vocabulary
-- instead of a second one that looks nearly the same. Everything here is what
-- the page above already uses -- the same panel colour, the same stroke, the
-- same kit scrim, the same hover and press timings -- and the alternative was
-- either a copy of two hundred lines that drifts, or moving the shop into this
-- file, which is long enough.
--
-- ONE-WAY. `PatternShop` requires this module; nothing here may ever require
-- it back.
LobbyUI.kit = {
	place = place,
	label = label,
	kitLabel = kitLabel,
	kitSet = kitSet,
	setText = setText,
	chip = chip,
	roundOff = roundOff,
	pillButton = pillButton,
	grower = grower,
	tween = tween,
	SCRIM = KIT_SCRIM,
	INK = INK,
	INK_DIM = INK_DIM,
	INK_OFF = INK_OFF,
	PANEL = PANEL,
	LINE = LINE,
	GOLD = GOLD,
	GAIN = GAIN,
	ACCENT = ACCENT,
	FONT_UI = FONT_UI,
	FONT_BOLD = FONT_BOLD,
	FONT_KIT = FONT_KIT,
	HOVER_IN = HOVER_IN,
	HOVER_OUT = HOVER_OUT,
	PRESS_IN = PRESS_IN,
	PRESS_OUT = PRESS_OUT,
	HOVER_SCALE = HOVER_SCALE,
	PRESS_SCALE = PRESS_SCALE,
	REF_W = REF_W,
	REF_H = REF_H,
}

return LobbyUI
