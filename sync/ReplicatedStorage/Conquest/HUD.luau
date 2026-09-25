--!strict
-- Conquest :: HUD  (client only)
--
-- REDESIGN 2026-08-30. The previous HUD drew seven equally-weighted bordered
-- panels and printed the army three times; nothing on screen said where to
-- look. This version rests on four decisions:
--
--   1. ONE HOME PER FACT. The army lives in the command bar and nowhere else.
--      Land share sits beside it. The standings answer "who is winning" and
--      stop there.
--   2. HIERARCHY BY SIZE, NOT BY BOX. One 36px number -- your army -- carries
--      the screen, and everything else steps down 30 / 16 / 13 / 11. Panels
--      lost their bright 2px strokes: seven outlined boxes all shout at the
--      same volume, which is what made this read as noise.
--   3. COLOUR MEANS ONE THING EACH. Your own map colour = you (troop bar,
--      commit fill, your row). Green = gain, red = threat. Nothing else is
--      coloured. Gold used to mean "currency", "your row" and "commit slider"
--      simultaneously, so it meant nothing.
--   4. NOTHING ON SCREEN FOR SYSTEMS THAT DO NOT EXIST. The gold readouts,
--      structure counters and build buttons were UI over an empty simulation,
--      and they made the game read as far more complex than it is.
--      `setGold` / `setStructures` stay as no-ops so wiring them back later is
--      a layout change, not an API change.
--
-- Layout is authored in pixels against a 1280x720 reference and converted to
-- UDim2 SCALE on the way out (see `place`), so the HUD stays proportional to
-- the viewport instead of being a fixed pixel size that turns into a postage
-- stamp on a large monitor. Text is TextScaled inside a box whose height IS
-- the type size, capped by a UITextSizeConstraint. There is deliberately no
-- UIScale any more: that machinery exists to rescue offset layouts, and it
-- would shrink a scale layout a second time.

local Faces = require(script.Parent.Faces)
local Config = require(script.Parent.Config)
local Palette = require(script.Parent.Palette)
local Numbers = require(script.Parent.Numbers)
local Icons = require(script.Parent.Icons)
local Sfx = require(script.Parent.Sfx)
-- For the REVIVE button's price and whether it is on sale at all.
local Products = require(script.Parent.Products)
-- For the lesson card's pop, and nothing else here: everything that moves
-- every frame (the armed rail's breathing, the ping) rides the HUD's own
-- clock -- see the notes beside them. A one-shot on a card that changes a
-- few times a round is what TweenService is for.
local TweenService = game:GetService("TweenService")
-- For the pad legend, which hangs under Roblox's own topbar and has to ask
-- how tall that is: the inset is a pixel count on every screen, not a share.
local GuiService = game:GetService("GuiService")
-- For the pass-gated rail cards (RAIL_ACTIONS.pass): which gamepasses this
-- account holds is read off the local player's ConquestPass_<KEY> attributes.
local Players = game:GetService("Players")

local HUD = {}
HUD.__index = HUD

export type HUD = typeof(setmetatable({} :: any, HUD))

-- ONE TYPEFACE, TWO WEIGHTS (2026-08-31). There were two FACES here: a
-- blocky arcade display font for the handful of big numbers and a UI face
-- for everything else. Mixing them meant the hero army figure and the
-- caption directly under it did not look like they belonged to the same
-- panel -- and the arcade face disagreed with the map's own labels, which
-- Conquest.NationLabels has always drawn in this family.
--
-- Hierarchy is carried by SIZE and WEIGHT, which is what design note 2
-- above already says; a second face was doing that job a second time and
-- doing it inconsistently. Same family throughout, so the weights are the
-- only difference and the two never fight over rhythm or x-height.
local FAMILY = Font.fromEnum(Enum.Font.GothamMedium).Family
local FONT_DISPLAY = Font.new(FAMILY, Enum.FontWeight.Bold)
local FONT_UI = Font.new(FAMILY, Enum.FontWeight.Medium)

-- ------------------------------------------------------------- the kit -----
-- ONE PIECE of the game's own UI set (StarterGui.INDEX) is used here: its
-- panel art, a flat 50% black. It goes OVER a dark frame rather than instead
-- of one, because on its own half the map still read through it and the
-- nation labels ghosted across the rows.
--
-- ONLY the panel art is used. The rest of that kit -- its buttons as the rows,
-- its LuckiestGuy face -- was tried on this board and taken straight back off
-- (owner, 2026-08-31: "do not use the buttons in the leaderboards, display the
-- name without the buttons"). The standings are a TABLE you read down, and a
-- stack of arcade buttons reads as four things to press. Everything on this
-- board is the HUD's own type again.
local KIT_SCRIM = "rbxassetid://120540791544567"
-- The kit panel's own transparency, named rather than inlined because the
-- action rail wears the same art and `setActions` has to repaint its buttons
-- back to exactly this value every time one disarms.
local SCRIM_T = 0.45

-- Neutrals carry all the structure; every one of these clears 4.5:1 on PANEL
-- except INK_OFF, which is only ever used for text that is genuinely inactive.
local INK = Color3.fromRGB(234, 240, 250)
local INK_DIM = Color3.fromRGB(178, 190, 212)
-- CAPTION INK, RAISED 2026-08-31 (owner: "some texts are hard to see").
-- Every cap on this HUD -- ARMY / GOLD / LAND, ATTACK SIZE, the phase line,
-- the key hints -- was drawn in the same grey as a DEAD PLAYER'S ROW. At the
-- 9-11px those caps run at that measured 4.3:1 on PANEL, under the 4.5 floor
-- before the map showing through the panel takes its own bite out of it --
-- and a cap is the label that says what the figure above it MEANS, so it is
-- the last thing on the bar that should be at the edge of legible.
local INK_OFF = Color3.fromRGB(146, 160, 186)
-- ...and the old value keeps its one honest job: text that is genuinely dead.
local INK_MUTE = Color3.fromRGB(110, 122, 148)
local PANEL = Color3.fromRGB(15, 20, 32)
local PANEL_HI = Color3.fromRGB(30, 39, 58)
local TRACK = Color3.fromRGB(9, 12, 20)
local LINE = Color3.fromRGB(52, 66, 94)

-- The only two accents. Everything else is neutral or the player's own colour.
local GAIN = Color3.fromRGB(111, 217, 138)
local THREAT = Color3.fromRGB(232, 97, 90)
-- ...and one currency colour, which is allowed to exist now that there is a
-- currency. It appears on exactly one readout. Kept in step with the same
-- constant in ConquestClient, which inks the build-mode ping and banner.
local GOLD = Color3.fromRGB(232, 196, 110)
-- WHICH BUTTON THE LESSON IS ASKING FOR. Green, and a harder green than the
-- GAIN above (owner: "a stronger green highlight"). It went gold first and
-- that was the wrong read on this surface: the price printed INSIDE every one
-- of these buttons is gold, so a gold ring around one of them said something
-- about its cost rather than about pressing it.
--
-- DELIBERATELY NOT THE COLOUR OF THE RING ON THE MAP, which is white. Same
-- instruction, two surfaces, and the surfaces do not agree about what green
-- means: on a dark control green is the oldest "press this" there is, while
-- on the map green is LAND and a green ring drawn on ground reads as a
-- property of that ground. See GUIDE in ConquestClient.
local TUT_POINT = Color3.fromRGB(60, 230, 110)

local REF_W, REF_H = 1280, 720

-- ------------------------------------------------------------- geometry ----

-- Authored pixels -> Scale. `pw`/`ph` are the REFERENCE footprint of the
-- direct parent, because Scale is read against the direct parent: passing the
-- screen's size for a child of a panel is the one mistake here that silently
-- shrinks something instead of erroring.
local function place(inst: GuiObject, pw: number, ph: number, x: number, y: number, w: number, h: number)
	inst.Size = UDim2.fromScale(w / pw, h / ph)
	inst.Position = UDim2.fromScale(x / pw, y / ph)
end

-- ------------------------------------------------------------ primitives ---

local function panel(parent: Instance, name: string, x: number, y: number, w: number, h: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = PANEL
	-- ALL BUT OPAQUE (2026-08-31). At 0.12 the map read straight THROUGH the
	-- panels: a nation label is up to 400px of near-white text and it ghosted
	-- across four rows of standings figures, which is what actually made the
	-- board hard to read -- not the type size. The map is the game, but a
	-- panel that cannot be read is not worth the sliver of map it buys.
	f.BackgroundTransparency = 0.04
	f.BorderSizePixel = 0
	f.Active = true
	place(f, REF_W, REF_H, x, y, w, h)
	f.Parent = parent
	return f
end

-- Lays the kit's panel art (StarterGui.INDEX) over a panel. The frame stays
-- underneath as the backing rather than being replaced: the scrim is a flat
-- 50% black, and on its own the map's nation labels read straight through the
-- figures printed on top of it.
--
-- ZIndex 0 is load-bearing. This ScreenGui is ZIndexBehavior.Global, so a
-- child does NOT draw above its parent by virtue of being one -- art meant to
-- sit BETWEEN a panel and its contents has to lose to every other child, and
-- every other child here is the default 1.
local function scrim(f: GuiObject, corner: number?): GuiObject
	f.BackgroundTransparency = SCRIM_T
	local img = Instance.new("ImageLabel")
	img.Name = "Scrim"
	img.BackgroundTransparency = 1
	img.Image = KIT_SCRIM
	img.ScaleType = Enum.ScaleType.Stretch
	img.Size = UDim2.fromScale(1, 1)
	img.ZIndex = 0
	-- UICorner does not clip a frame's CHILDREN, and this art is a plain
	-- rectangle, so a rounded host has to hand its radius down or the corners
	-- of the panel art poke out past the thing they belong to.
	if corner then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, corner)
		c.Parent = img
	end
	img.Parent = f
	return f
end

-- `h` is the type size: the box is exactly one line tall and TextScaled fills
-- it, so the authored number is what actually renders at the reference size.
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
	t.TextXAlignment = align or Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Center
	t.Text = ""
	local c = Instance.new("UITextSizeConstraint")
	-- Room to grow with the viewport, but not without limit; without a cap
	-- TextScaled ignores the design entirely on a very tall window.
	c.MaxTextSize = math.floor(h * 4)
	c.MinTextSize = 6
	c.Parent = t

	-- EVERY LABEL IS OUTLINED (2026-08-31, owner: "add UI strokes to
	-- everything in the game"). It lives here rather than at the call sites
	-- because every piece of text this HUD draws is built by this function --
	-- one rule, and nothing new can be added without it.
	--
	-- Thickness comes from the AUTHORED TYPE SIZE, never a constant.
	-- `UIStroke.Thickness` is in fixed pixels while the text scales with the
	-- viewport (TextScaled inside a Scale-authored box), so a single number is
	-- a smear on the 9px captions and nearly invisible on the 30px army
	-- figure. The clamp keeps both ends sane.
	--
	-- Small text also gets a LIGHTER stroke. Below about 16px a
	-- full-strength outline closes up the counters of the glyphs and the word
	-- gets harder to read, not easier -- which is the opposite of the point.
	local s = Instance.new("UIStroke")
	s.Color = Color3.new()
	s.Thickness = math.clamp(h / 14, 0.9, 2.4)
	s.Transparency = if h >= 16 then 0.25 else 0.45
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = t

	place(t, pw, ph, x, y, w, h)
	t.Parent = parent
	return t
end

-- A BLOCK of text where `label` draws a line of one. Same authored-pixel
-- geometry, but wrapped and top-aligned inside a box several lines tall.
--
-- TextScaled is kept for the reason every other label here keeps it: the box
-- is authored in Scale, so a fixed TextSize would be a different apparent size
-- on every monitor. The consequence, which does not apply to a one-line label,
-- is that a SHORT paragraph is drawn a point or two larger than a long one
-- because it has fewer lines to fill the box with. The one caller is the
-- tutorial card, whose copy is written to a similar length for that reason.
local function paragraph(
	parent: Instance,
	name: string,
	pw: number,
	ph: number,
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3?
): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.FontFace = FONT_UI
	t.TextScaled = true
	t.TextWrapped = true
	t.TextColor3 = color or INK
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Top
	t.Text = ""
	local c = Instance.new("UITextSizeConstraint")
	-- Room to grow with the viewport; the floor matters more here than on a
	-- caption, because an unreadable paragraph is the lesson itself going
	-- missing rather than a label under a number. The lesson card raises
	-- this for its own body -- see buildTutorial.
	c.MaxTextSize = 44
	c.MinTextSize = 8
	c.Parent = t
	local s = Instance.new("UIStroke")
	s.Color = Color3.new()
	s.Thickness = 1
	s.Transparency = 0.45
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = t
	place(t, pw, ph, x, y, w, h)
	t.Parent = parent
	return t
end

-- Thousands separators, for the payout card alone. Numbers.format's K/M
-- banding is right for troops and gold -- figures that move every tick and are
-- read as magnitudes -- but a payout is read as an exact sum and "1.24K" is
-- not one. Kept in step with Money.comma, which does the same job server-side.
local function commas(n: number): string
	local s = string.format("%.0f", math.abs(n))
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, -4)
	end
	return (n < 0 and "-" or "") .. s .. out
end

local function box(parent: Instance, name: string, color: Color3, pw: number, ph: number, x: number, y: number, w: number, h: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	place(f, pw, ph, x, y, w, h)
	f.Parent = parent
	return f
end

-- An icon in the same authored-pixel space as `label`. The box need not be
-- square: ScaleType.Fit letterboxes the sprite inside it, which is what keeps
-- the baked-in outline from being stretched on a viewport that is not 16:9 --
-- the reason the avatar disc next door needs a UIAspectRatioConstraint and
-- this does not.
local function icon(parent: Instance, name: string, id: string, pw: number, ph: number, x: number, y: number, d: number): ImageLabel
	local img = Instance.new("ImageLabel")
	img.Name = name
	img.BackgroundTransparency = 1
	img.Image = id
	img.ScaleType = Enum.ScaleType.Fit
	-- The rail's HOUSE and SHIP are pixel grids; every other icon on this bar
	-- is a smooth sticker, so the filter is chosen per image, not per site.
	Icons.resample(img)
	place(img, pw, ph, x, y, d, d)
	img.Parent = parent
	return img
end

-- The one formatter, shared with the map labels through Conquest.Numbers. A
-- second implementation here once printed "5.4K" for the same troops the
-- nation's own territory labelled "5.43K", which is exactly the comparison a
-- player makes.
local formatCount = Numbers.format
-- Every TROOP figure goes through formatTroops (upstream renderTroops, which
-- is renderNumber(t / 10)). Gold, costs and TILE counts stay on formatCount,
-- because upstream calls renderNumber raw for those.
local formatTroops = Numbers.formatTroops

-- Figures arrive five times a second. Nothing is written straight to a label:
-- step() walks each one toward its target at this rate, so the numbers count
-- rather than jump.
local COUNT_RATE = 9

HUD.formatCount = formatCount

-- A name that has to shrink to fit its column breaks the row rhythm, so long
-- names are cut in Lua and every row renders at the same type size.
local function clip(s: string, n: number): string
	if #s <= n then
		return s
	end
	return string.sub(s, 1, n - 1) .. "-"
end

-- ------------------------------------------------------------- constants ---

-- WHERE A LEADERBOARD GOES (owner, 2026-09-03: "disable roblox's built in
-- leaderboard and put our leaderboard where its supposed to go"). This board
-- was top-LEFT while Roblox's own player list sat top-RIGHT, so the screen
-- carried two ladders and the one that meant anything was in the corner
-- nobody checks. The core list is switched off in ConquestClient -- nothing
-- in this game has ever set `leaderstats`, so it was printing usernames and
-- nothing else -- and the standings take the slot it leaves. The clock, which
-- used to hold this corner, is at the foot of the same edge now: see CLOCK_X.
local BOARD_W = 300
local BOARD_X, BOARD_Y = REF_W - 14 - BOARD_W, 14
-- FOUR ROWS, ALWAYS: the podium and you. At a 72-empire roster a full ladder
-- is not something anyone reads -- the only rows acted on are the leaders'
-- and the reader's own -- so the board shows the top three, a rule, and the
-- client's own row at its real rank -- unless that rank is already on the
-- podium, in which case the fourth row shows rank four rather than printing
-- you twice. Rows are tall enough to carry a headshot,
-- which is what turns a name on this board into a PERSON rather than a string.
-- Two pixels taller than the original 32, which is room around a headshot
-- rather than around a pill -- kept after the button experiment came off.
local ROW_H, ROW_GAP, TOP_ROWS = 34, 4, 3
local ROW_SPLIT = 10
-- 5 pad + 17 title + 6 gap + 10 column header + 12 rule and gap.
local BOARD_HEAD = 50
local BOARD_H = BOARD_HEAD + (TOP_ROWS + 1) * (ROW_H + ROW_GAP) + ROW_SPLIT + 8

local ALERT_W = 520
local ALERT_X = (REF_W - ALERT_W) / 2
-- THE SAME STRIP AT THE END OF THE ROUND (owner, 2026-09-06: "when a player
-- wins, dont show the notification ui at the top, instead just display the
-- win banner we currently have but bigger"). Twice the height, so the type
-- inside -- authored in Scale against the strip -- comes out at twice the
-- size; wider so a sixteen-letter name and WINS still sit in one line at it.
local WIN_W, WIN_H = 640, 64

-- WHAT THIS HUD COVERS OF THE MAP, in reference px: the band across the top
-- (Roblox's own topbar, then the alert line and the team strip under it) and
-- the band across the foot (the command bar, with the clock on its baseline).
-- The camera reads both through `HUD.insets` and hands itself that much
-- overscroll, so no band the HUD stands on is map a player can never reach.
local TOP_BAND = 72

-- ------------------------------------------------------- the payout card ---
-- Six rows is the whole payout and it can never be seven: Money.lines emits
-- one per term and there are six terms.
local PAY_ROWS = 6
local PAY_ROW_H = 17
local PAY_W = 300
local PAY_PAD = 16
local PAY_INNER = PAY_W - PAY_PAD * 2
-- Cap, total and the hairline above the rows; then the rows; then the banked
-- line under them. The card's real height is TOP + rows x ROW_H + FOOT, and it
-- is recomputed per payout -- a leaver's three rows and a winner's six are not
-- the same card. PAY_H is the six-row maximum and is what every child inside is
-- authored against.
local PAY_TOP = 88
local PAY_FOOT = 34
local PAY_H = PAY_TOP + PAY_ROWS * PAY_ROW_H + PAY_FOOT
local PAY_X = (REF_W - PAY_W) / 2
-- Above centre, not on it. The map's own nation labels cluster at the middle
-- of the viewport and the eye reads a receipt from its top line anyway.
local PAY_Y = 120
-- Seconds at full opacity, then PAY_FADE seconds going. Long enough to read
-- six rows twice; short enough that a spectator gets the map back.
local PAY_HOLD = 9
local PAY_FADE = 1.2

local BAR_W, BAR_H = 560, 124
local BAR_X = (REF_W - BAR_W) / 2
local BAR_Y = REF_H - 14 - BAR_H

-- THE CLOCK, BOTTOM RIGHT (owner, 2026-09-03: "move clock to the bottom
-- right"). It held the top-right corner until the standings took that slot
-- off Roblox's player list -- see BOARD_X. Its bottom margin is 14, the same
-- as the command bar's, so the two sit on one baseline across the foot of the
-- screen instead of the clock floating at some third height.
-- BIGGER (owner, 2026-09-05). 132x44 with the time at 20px was sized for the
-- top-right corner it used to live in, where it was the only thing there; at
-- the foot of the screen it sits opposite a 44px-tall button and under a 124px
-- command bar, and at that scale it read as a caption rather than as the clock.
--
-- IT GROWS UPWARD, NOT DOWNWARD. The 14px bottom margin is what puts it on one
-- baseline with the command bar and the way out, and that baseline is the
-- reason the foot of the screen reads as a row instead of three things at three
-- heights -- so the height goes up and CLOCK_Y follows it.
local CLOCK_W, CLOCK_H = 176, 60
local CLOCK_X = REF_W - 14 - CLOCK_W
local CLOCK_Y = REF_H - 14 - CLOCK_H

-- THE WAY OUT, BOTTOM LEFT (owner, 2026-09-05: "a button to go back to the
-- lobby"). Until this there was none: a match server holds you until the round
-- ends and teleports everybody home together, so somebody who wanted out had
-- to leave the experience entirely and come back through the front door.
--
-- The clock's footprint exactly, on the opposite corner of the same baseline:
-- the foot of the screen already reads as one row (bar centred, clock right),
-- and a control that is a different height there reads as something that fell
-- off rather than as the third member of the set.
--
-- FAR from the map controls on purpose. Everything that acts on the map lives
-- in the middle -- the bar, the rail, the size buttons -- and this is the one
-- press on screen you cannot take back, so it does not sit within a slip of
-- them. The two-stage arm below is the other half of that.
local LEAVE_W, LEAVE_H = 132, 44
local LEAVE_X = 14
local LEAVE_Y = REF_H - 14 - LEAVE_H
-- How long the armed state stands before it forgets. Long enough to be a
-- deliberate second press, short enough that a button left armed and wandered
-- away from is not a trap waiting under the next stray click.
local LEAVE_ARM = 3
-- RED STANDING, NOT ONLY WHEN ARMED (owner, 2026-09-05: "make the leave button
-- red"). It wore the HUD's own PANEL until the first press, which made the one
-- control that ends your match look like the readouts either side of it.
--
-- The two-stage arm still has to READ as two stages, so red is a ladder rather
-- than a switch: a dark red at rest, near the panel's weight so the corner is
-- not shouting through the whole match, and the full THREAT fill only once it
-- is armed. Same relationship the rail's buttons have between idle and lit.
local LEAVE_FILL = Color3.fromRGB(74, 22, 20)
local LEAVE_HOVER = Color3.fromRGB(104, 30, 26)
-- The caption at rest. Full THREAT on the dark fill is a vibrating red-on-red;
-- this is the same hue carried up toward the HUD's ink so it reads as type.
local LEAVE_INK = Color3.fromRGB(248, 176, 170)

-- THE WAY BACK IN (2026-09-08), directly above the way out and the same size:
-- the two are the only controls a knocked-out player has left, and they read
-- as a pair. GREEN because that is what green means on this HUD -- gain -- and
-- the same dark-at-rest ladder as LOBBY so the corner is quiet until it is
-- hovered. Shown only when the server says a takeover is possible (see
-- HUD.setRevive); the rest of the match it does not exist.
local REVIVE_FILL = Color3.fromRGB(20, 62, 34)
local REVIVE_HOVER = Color3.fromRGB(28, 88, 48)
local REVIVE_INK = Color3.fromRGB(178, 240, 194)
local REVIVE_Y = LEAVE_Y - LEAVE_H - 10

-- WHERE THE WAY OUT GOES ONCE YOU ARE OUT (owner, 2026-09-17: "once a person
-- loses, remove all the ui at the bottom. Keep revive in bottom left. and the
-- leave button where the bottom ui originally was with a pulsating tween").
-- A knocked-out player has no army to commit, no gold to spend and nothing to
-- build: the command bar and the rail become a row of controls asking to be
-- pressed and refusing, which is worse than an empty foot of screen. They come
-- down, and the one press that still does something takes their place.
--
-- THE BAR'S CENTRE LINE, NOT ITS BOX. The bar is 560x124 and a button that size
-- would be a slab; this sits centred on the same 14px bottom margin the clock
-- and the revive card already use, so the foot of the screen still reads as one
-- row rather than as one enormous thing -- see CLOCK_Y.
--
-- THE REVIVE CARD DOES NOT MOVE. It is the other half of the same decision, and
-- a pair that both jumps and separates reads as new UI rather than as the two
-- buttons that were already in that corner.
local DEFEAT_LEAVE_W, DEFEAT_LEAVE_H = 260, 64
-- THE BUTTON BREATHES AND THE CAPTION BREATHES WITH IT (owner, 2026-09-17:
-- "make the text grow/shirnk with it"). The labels ride inside the button, so
-- one tween on its Size carries the whole control.
--
-- THE TYPE WILL STEP, AND NOTHING HERE CAN STOP IT. Roblox rasterises text at
-- WHOLE PIXEL SIZES only -- measured all three ways on 2026-09-17 against a 10%
-- ramp: TextScaled gave bounds 17 -> 18 -> 19, an explicit fractional TextSize
-- gave 36 -> 37.5 -> 39, and a UIScale moved the BOX continuously (AbsoluteSize
-- 17.9 -> 19.7, smooth) while the glyphs still landed on 17 / 18 / 19. There is
-- no continuous path, so a pulse that includes the words costs two or three
-- one-pixel snaps per breath. The knobs that decide how much that shows are the
-- two below; the type is bigger than the reference on any real monitor (this
-- layout is authored in Scale), which is what makes each snap a smaller share of
-- the glyph than the numbers above suggest.
--
-- WHAT WAS ACTUALLY WRONG THE FIRST TIME was not only the snapping. The button
-- was anchored at its BOTTOM edge, so it grew upward only and the caption slid
-- across it as well as stepping -- two motions at once, which is what read as
-- "moving slightly weirdly". Anchored at the CENTRE it grows evenly in all four
-- directions and the words stay put while they scale.
--
-- Slower than a flash on purpose: the snaps are unavoidable, so they are spaced
-- out rather than run together into a flicker.
local DEFEAT_PULSE = TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
local DEFEAT_PULSE_SCALE = 1.07

-- THE TYPE HOLDS ONE SIZE while the body breathes (owner, 2026-09-17, after
-- trying it both ways: "nvm, just keep the text size the same"). It cannot be
-- left to TextScaled to achieve that -- the labels are children of the button
-- and everything in here is sized in Scale, so a growing button IS a growing
-- box, and TextScaled would faithfully re-fit the words to it on every frame.
--
-- So TextScaled goes OFF for the defeated layout and the size is set once, in
-- REAL PIXELS -- the one thing this Scale-authored HUD otherwise never touches.
-- The number is derived from the viewport the way TextScaled would have derived
-- it (authored px x the height factor), and HUD.layout re-derives it on every
-- resize: that exception is the whole reason `layout` is no longer a no-op.
--
-- The boxes still grow with the button, so the words drift by a fraction of a
-- pixel over a breath -- measured under 1px for both lines at this geometry,
-- which is less than the button's own edges move.
--
-- What the two caption boxes are placed at, and the size the type is pinned to.
-- Named rather than repeated so the placement and the pinned size cannot drift.
local DEFEAT_TITLE_PX, DEFEAT_HINT_PX = 19, 12

-- THE FRONTS STRIP IS OFF (2026-09-02, owner: "the notification thing at the
-- bottom listing troop movements -- turn it off"). It was a dark two-column
-- panel sitting on the command bar, printing "Redfen [sword] 362" for the two
-- fronts that mattered. Everything on it was already on screen twice: every
-- army in the field carries its own number ON the map where it is fighting,
-- and the alert line across the top names the one front that matters most --
-- so the strip's only real effect was to spend the band of screen directly
-- above the army readout, which is the band the eye is already in.
--
-- WHAT SURVIVES IS THE RANKING. `setFronts` still sorts invasions before
-- advances and biggest army first, because the alert line is drawn from the
-- top of that order and still counts its number up and down. The panel and
-- its geometry are gone; the space is where the action buttons live now.

-- Row columns, in ROW pixels: { key, x, w, rightAligned }. The header labels
-- are drawn at the same x plus ROW_INSET, because the rows frame is inset
-- inside the board and Scale is read against the DIRECT parent -- the header
-- and its column were six pixels out of step before.
--
-- ARMY is gone from the board. The army has one home (the command bar), and
-- the question this table answers is "who is winning", which land share
-- answers on its own. The avatar is not a text column, so it is not listed
-- here; it sits in the gap between rank and name.
local ROW_INSET = 6
local COLS = {
	{ "Rank", 10, 30, false },
	{ "Name", 76, 128, false },
	{ "Land", 208, 72, true },
}
local AVATAR_X, AVATAR_D = 42, 26

-- ------------------------------------------------------- the action rail ---
-- The three things you SPEND on, in a row across the top of the command bar.
-- Everything you can buy in this game was on a hotkey and nothing else -- B
-- then C / P / F, and for a nuke not even that -- which is a control surface
-- you cannot find by
-- looking at the screen. The rail is the opposite of a hidden mode: three
-- targets that name themselves and carry their own price, so "can I afford
-- this" is answered ON the thing you press. That is also why re-adding the
-- price here does not undo the owner's cut of the build-price line from the
-- command bar: the bar is a readout of what you HAVE, and a price belongs
-- next to the decision, not next to the treasury.
--
-- HORIZONTAL, ON THE BAR (2026-09-02, owner: "replace it with the 3 abilities
-- (house port nuke) instead in a horizontal manner"). It was a vertical rail
-- down the right edge, put there because the bar's bottom strip is the attack
-- -- one press a second in a fight against one press a minute here -- and
-- neighbours get pressed by mistake. What the fronts strip proved by failing
-- in this exact band is the other half of that: this is the piece of screen a
-- player is ALREADY reading, because it is where the army readout is, and the
-- right edge is somewhere you have to go and find. The mis-press it was
-- guarding against still cannot happen -- the attack row is at the BOTTOM of
-- the bar with the whole army block between, 124px away, not 8.
local RAIL_BTN_W, RAIL_BTN_H, RAIL_GAP = 84, 68, 8
local RAIL_CORNER = 4
-- How far the tutorial halo stands off the button it is pointing at.
-- NARROWED from 7 (owner, 2026-09-03: "its also a bit too thick"), in the
-- same pass that made it far more opaque. 7px of near-solid green around an
-- 84px tile is a BORDER, and a border reads as part of the button rather than
-- as something lit up on top of it. Thin and bright beats wide and washy.
local RAIL_GLOW = 4
-- THE PING (owner, 2026-09-03: "give it some sort of tween visual effect to
-- make it more obious where hte user has to click"). A ring that starts at the
-- tile's edge, travels outward and dies. It is the one motion on this HUD that
-- is not a breathe, which is exactly why it catches an eye that has stopped
-- noticing the breathe -- expansion reads as something ARRIVING, where a
-- brightness cycle reads as a state.
--
-- TWO of them, half a period apart: a single ripple leaves a silent gap in
-- every cycle, and a gap reads as a glitch rather than as a beat.
local RAIL_PING = 26
local RAIL_PING_TIME = 1.1
local RAIL_PING_COUNT = 2
-- NAMED FOR WHAT THEY ARE, NOT FOR WHAT THEY LOOK LIKE (2026-09-01, owner:
-- "rename the 3 buildings to 1. City 2. Port 3. Nuke"). HOUSE and SHIP
-- described the icon, which the player can already see; the words a player has
-- to match against a price, a hotkey and everything else this game calls them
-- -- the command bar's own readout says CITY and PORT -- are these.
local RAIL_ACTIONS = {
	-- `tip` is the one line the small box over a hovered button says (owner,
	-- 2026-09-11): what the building DOES, which no icon, price or name on the
	-- rail can. `tipW` is the box's authored width, sized to that line.
	-- LEFTMOST, before city/port/nuke (owner, 2026-09-12). It is the only one of
	-- the four that is bought in answer to somebody else's move rather than to
	-- grow, so it reads first on a row the eye crosses left to right.
	-- The tip is what it DOES, in the tip convention's terms: an attack inside
	-- its radius pays five times the troops per tile and moves at a third of the
	-- speed. "Slows" and "bleeds" are the two halves of that, in the player's
	-- words rather than the multipliers'.
	-- NOT IN A LESSON ROUND (owner, 2026-09-12: "defence tower should not be in
	-- tutorial"). The track teaches five controls and this is not one of them --
	-- it never names the post, never rings a tile for it and never funds it --
	-- so on a rail that already hides everything the student cannot afford, a
	-- button for an untaught building is the one tile up there answering no
	-- question the lesson asked. `setActions` reads this flag; the T key and the
	-- pad's LB are shut off beside it, in ConquestClient's `arm`.
	{ id = "post", icon = Icons.TOWER, name = "DEFENSE", key = "T", tip = "Slows and Bleeds Attackers Nearby", tipW = 210, tutHide = true },
	-- THE BATTERY (2026-09-21), beside the post on the post's rule: it is
	-- bought in answer to somebody else's move -- an enemy line inside its
	-- ring -- rather than to grow. The tip is what it does: shells whoever is
	-- an enemy inside the ring the ghost draws, on its own, every 4-7 s.
	-- R, because C / P / N / T / G are the other builds, B is build mode,
	-- W / A / S / D the camera. On a pad it is the virtual cursor pressing
	-- this tile, like every card (see setActionKeys).
	-- NOT IN A LESSON ROUND, for the reason the post is not: the track never
	-- names it, never rings a tile for it and never funds it.
	-- THE BUNDLE'S CARD (2026-09-22, owner: "I only want people who have the
	-- gamepass to have access to it"). `pass` is the flag the mega nuke card
	-- brought in: setActions keeps the tile off the rail until the
	-- ConquestPass_ARTILLERY attribute says yes -- which it does for a Robux
	-- purchase of the Artillery Battery Bundle AND for a Money one, since
	-- buyPassWithMoney writes the same attribute. ConquestServer's build
	-- intent refuses kind 18 from anyone else and ConquestClient's `arm`
	-- shuts the R key, so hiding the tile hides every route.
	{ id = "artillery", icon = Icons.ARTILLERY, name = "ARTILLERY", key = "R", tip = "Shells Enemies in Its Ring", tipW = 175, tutHide = true, pass = "ARTILLERY" },
	{ id = "city", icon = Icons.HOUSE, name = "CITY", key = "C", tip = "+ Army Size", tipW = 80 },
	{ id = "port", icon = Icons.PORT, name = "PORT", key = "P", tip = "Spawns Trade Ships and Battleships", tipW = 200 },
	-- REINFORCEMENTS (owner, 2026-09-21: "another card that allows players to
	-- call in reinforcements. They use gold to get X amount of troops"). Sits
	-- with the city and the port because it is the third GROW purchase: the
	-- city raises the ceiling, this fills it. NOT A BUILDING, and `instant` is
	-- the flag that says so -- pressing it acts at once, arms nothing, and
	-- leaves whatever building was armed exactly as it was. setActions never
	-- lights it and ConquestClient's `arm` fires the intent instead of a mode.
	-- The caption is the price while it may be pressed and the seconds of
	-- cooldown while it may not (see setActions). E, because C / P / N / T / G
	-- are the other actions, B is build mode, W / A / S / D the camera.
	-- NOT IN A LESSON ROUND, for the reason the post is not: the track never
	-- names it and never funds it.
	-- THE TIP IS THE LIVE FIGURE (owner, 2026-09-21: "instead of buy troops now,
	-- make it display how much troops"): setReinforce rewrites it from every
	-- `fronts` quote, so the line reads "+62.5K Troops" for THIS empire's
	-- ceiling. The string here is only the first frame's.
	-- THE BARRACKS BUNDLE'S CARD (2026-09-22), on the artillery card's rule:
	-- the pass is what puts it on the rail, bought with Robux or with Money.
	-- ConquestServer's reinforce intent is the other half.
	{ id = "reinforce", icon = Icons.REINFORCE, name = "REINFORCE", key = "E", tip = "+20% Army", tipW = 120, tutHide = true, instant = true, pass = "BARRACKS" },
	-- `price` IS NOT THE PRINTED PRICE -- it is the gate. ConquestClient fills
	-- ACTION_COSTS for the city and the port only (they scale with how many you
	-- already hold), so the warhead reaches setActions with no cost at all and
	-- prints none. The tutorial's show-when-affordable rule still needs a number
	-- for it, and the warhead's is flat, so it comes off Config here.
	-- THE AIRFIELD (owner, 2026-09-21), between the port and the warhead: the
	-- one building on this row that is pressed AGAIN once it stands -- tap the
	-- chip, tap a spot inside its ring, and a bomber goes -- so the tip says
	-- the two taps rather than what a bomb does, which the disc the pointer
	-- carries says on its own. F: free since the factory left the rail
	-- (2026-09-18). On a controller it is the virtual cursor pressing this
	-- tile, like every card since 2026-09-21 (see setActionKeys).
	-- NOT IN A LESSON ROUND, for the reason the post and the anti-nuke are
	-- not: the track never names it, rings it or funds it; ConquestClient's
	-- `arm` is the other half of that, as for the post.
	-- THE AIR STRIKE BUNDLE'S CARD (2026-09-22), on the artillery card's rule.
	-- The pass key is AIRSTRIKE, not AIRFIELD: the catalogue names the bundle,
	-- not the building (Products.PASSES.AIRSTRIKE).
	{ id = "airfield", icon = Icons.AIRFIELD, name = "AIRFIELD", key = "F", tip = "Tap It, Then Tap a Spot to Bomb", tipW = 215, tutHide = true, pass = "AIRSTRIKE" },
	-- THE RAILGUN (owner, 2026-09-24): the airfield's two taps with no ring at
	-- all -- tap the gun, tap anywhere on the map. Beside the airfield because
	-- it is pressed the same way. The RAILGUN pass's card (2026-09-24). L
	-- for raiL: every nearer letter is taken (see the mega nuke's note).
	{ id = "railgun", icon = Icons.RAILGUN, name = "RAILGUN", key = "L", tip = "Tap It, Then Tap Anywhere to Fire", tipW = 225, tutHide = true, pass = "RAILGUN" },
	{ id = "nuke", icon = Icons.NUKE, name = "NUKE", key = "N", price = Config.ATOM_BOMB_COST },
	-- THE MEGA NUKE CARD (owner, 2026-09-22: "I dont want it to be an upgrade
	-- of the Nuke, I want it to be a seperate card called Mega Nuke"): a
	-- second warhead beside the first -- Units.MEGA_NUKE, twice the atom
	-- bomb's radii, four times its ground, 2.5M gold (Config.MEGA_NUKE_COST).
	-- Beside NUKE so the two warheads read as a pair, and the anti-nuke keeps
	-- the row's right end as the answer to both.
	--
	-- THE PASS'S CARD. `pass` names the gamepass (a Products.PASSES key) an
	-- account must hold for the tile to be on the rail at all. setActions
	-- reads it off `self.passes`, which HUD.new fills from the
	-- ConquestPass_<KEY> attribute the server writes and keeps filled as it
	-- changes -- so a Money buy on the "+" page mid-round puts the card up on
	-- the spot. ConquestServer's nuke intent is the other half and accepts
	-- the type from a holder only; the M key and B's re-arm are shut in
	-- ConquestClient's `arm` off HUD.passHeld, so hiding the tile hides every
	-- route.
	--
	-- `price` is the tutorial latch's number, as the nuke's is; `tutHide`
	-- because no lesson teaches it. M was free (C P F N T G E R are the other
	-- actions, B build mode, W A S D the camera, 1 2 3 the attack sizes).
	{ id = "meganuke", icon = Icons.MEGA_NUKE, name = "MEGA NUKE", key = "M", price = Config.MEGA_NUKE_COST, tip = "Four Times a Nuke's Blast Area", tipW = 205, tutHide = true, pass = "MEGANUKE" },
	-- THE SCATTERSHOT (owner, 2026-09-24): a nuke that brings 4-6 smaller
	-- warheads with it, landing on a ring around the aimpoint. Beside the two
	-- warheads; the SCATTERSHOT pass's card (2026-09-24). X was free.
	{ id = "scattershot", icon = Icons.SCATTERSHOT, name = "SCATTERSHOT", key = "X", price = Config.SCATTERSHOT_COST, tip = "A Nuke + 4-6 Smaller Warheads", tipW = 200, tutHide = true, pass = "SCATTERSHOT" },
	-- RIGHTMOST, past the warhead (owner, 2026-09-15). It used to sit beside
	-- the defence post, on the reasoning that both are bought in answer to
	-- somebody else's move rather than to grow. That grouping is real, but it
	-- is not what the eye wants from this row: the anti-nuke is the ANSWER TO
	-- THE BUTTON ON ITS LEFT, and side by side the two read as a threat and
	-- its reply. The post keeps the left end on the older rule.
	--
	-- THE TIP IS THE RULE, and the rule is the part players get wrong: it does
	-- not guard a radius around the thing it protects, it fires at anything
	-- crossing ITS OWN radius -- including a warhead merely passing overhead on
	-- its way somewhere else entirely.
	--
	-- G, because C / P / F / N / T are taken by the other builds, B is build
	-- mode and W / A / S / D are the camera.
	--
	-- NOT IN A LESSON ROUND, for the reason the post is not: the track never
	-- names it, never rings a tile for it and never funds it -- and at 1M (3M
	-- from the second) it is the dearest thing on the rail.
	{ id = "sam", icon = Icons.DOME, name = "ANTI-NUKE", key = "G", tip = "Shoots Down Nukes Crossing Its Range", tipW = 245, tutHide = true },
	-- THE EXTRA BUILDINGS CARD -- the codebase's name for the "+" card (owner,
	-- 2026-09-21: "name it the extra buildings card", "only in the codebase so
	-- i can refer to it"). The name is for comments and notes only: the face
	-- is a bare "+", no caption, no tip. Its page is PlusTabClient.
	--
	-- THE "+" CARD, LAST ON THE RIGHT (owner, 2026-09-21: "one more card
	-- always on the right side that just has a + sign"). It is a DOOR, not a
	-- build: pressing it opens a page, and PlusTabClient -- a side-car
	-- LocalScript, the shop's pattern -- listens on this button's Activated
	-- for that. bindActions skips it, so nothing here ever arms it.
	--
	-- NO PRICE AND NO GATE, which is what keeps it on the rail in every round
	-- including a lesson: setActions reads a priceless button as reachable
	-- from the first frame, and the latch never lets it go. `key` is "" and
	-- not nil because setActionKeys writes a.key.Text straight from it.
	{ id = "plus", plus = true, name = "", key = "" },
}
-- The row is the buttons plus the gutters between them, centred on the same
-- line as the bar and sitting 8px above it -- the gap the fronts strip used to
-- hold, measured from the bar's own top edge so the two move together.
-- TEN BUTTONS ARE 912 OF THE 1280 (2026-09-22) with every card up, which is
-- an account holding all four extra-buildings passes, outside a lesson; four
-- of the ten are pass-gated now (artillery, reinforce, airfield, mega nuke),
-- so a new player's row is six. layoutRail centres whichever set is showing,
-- so the row is as wide as its visible cards and no wider.
local RAIL_W = #RAIL_ACTIONS * RAIL_BTN_W + (#RAIL_ACTIONS - 1) * RAIL_GAP
local RAIL_H = RAIL_BTN_H
local RAIL_X = (REF_W - RAIL_W) / 2
local RAIL_Y = BAR_Y - 8 - RAIL_H
-- "You cannot afford this", drawn on the ARMED fill rather than on the panel.
-- THREAT is tuned to sit on near-black; the armed fill is the player's own
-- colour and always a bright one, so the warning has to go dark to stay red.
local RAIL_THREAT_INK = Color3.fromRGB(92, 14, 10)
-- The rail's hover lift. It cannot be PANEL_HI any more: these buttons carry
-- the kit's panel art like the standings and the command bar, so their own
-- fill sits at SCRIM_T instead of all but opaque, and the same colour step
-- read through a 45% translucent fill lands at just over half the contrast it
-- had. Same ramp (PANEL -> PANEL_HI -> LINE), stepped far enough along it that
-- the lift survives the transparency.
local RAIL_HOVER = Color3.fromRGB(44, 57, 84)

-- ------------------------------------------------------- the pad legend ---
-- WHAT A CONTROLLER IS TOLD, and where (owner, 2026-09-21: "in the top left
-- you should have the commands for attacking, and zooming in and out"). Two
-- rows, each a button chip and a word: A ATTACK, LB RB ZOOM. Nothing else --
-- the rail's cards are pressed with the cursor like any other button and
-- print NO key on a pad (see setActionKeys), so the legend is exactly the two
-- things a pad does that no button on screen shows it. Shown only while a
-- pad is the last thing touched (ConquestClient's gp.step, via setPadHints),
-- and it hangs under Roblox's own topbar rather than at the 14px the board
-- keeps, because that corner is where the engine draws its menu button --
-- see HUD.layout. The chips are sized for two glyphs (LB, R1); a lone A
-- sits centred in the same box so the column lines up.
local PAD_X = 14
local PAD_GAP = 8 -- between the topbar's foot and the legend, reference px
local PAD_W = 132
local PAD_ROW = 18
local PAD_CHIP = 26
local PAD_H = 8 + PAD_ROW + 4 + PAD_ROW + 8

-- ------------------------------------------------------- the lesson text ---
-- TEXT ACROSS THE TOP, AND NOTHING ELSE (2026-09-01, owner: "i dont want the
-- card, quite literally just the text"). There were two panels before it: a
-- 300px one in the left gutter under the standings, on the theory that a
-- centred panel would be a modal over the tile the lesson is asking you to
-- tap, and then the same panel widened and moved up here. Both were a BOX,
-- and a box across the top of the screen is a second HUD arguing with the one
-- already on it. What is left is the type: the step count and the safe clock
-- on one line, the lesson, and the aside under it.
--
-- The 560 is BAR_W -- the measure the copy is set to, matching the command
-- bar at the bottom, so the two things a new player is being told about sit
-- in one column.
--
-- The alert banner lives in this column too, ABOVE the card (owner,
-- 2026-09-18: "swap the bar notification with the tutorial instruction"):
-- the card sits under the banner's slot -- see restackTop.
--
-- Built LAZILY, on the first card that arrives, so an ordinary round pays
-- nothing for it.
--
-- 35% BIGGER (2026-09-11, owner: "make the text 35% bigger too"). The copy
-- is still AUTHORED against the 560x108 block below -- every label in
-- buildTutorial is placed against TUT_REF_W/TUT_REF_H, so its Scale fractions
-- are what they always were -- and the block itself is drawn larger. TALLER
-- BY THE FULL TUT_SCALE, which is what grows the type: every line on the card
-- is TextScaled inside a box whose height is its size.
--
-- WIDER BY LESS, ON PURPOSE. At 1.35x across as well, the block ran from 262
-- to 1018 of the 1280 frame, and the standings board starts at 966: the end
-- card's one-line body ("Back to the lobby for a real match.") was measured
-- running 47px under the board. 620 is the widest the block can be, centred,
-- and still stop 16px short of it. Every lesson title is short and
-- height-bound, so all of them still grow the full 35%; only a line long
-- enough to fill the width stops at the width.
local TUT_SCALE = 1.35
local TUT_REF_W, TUT_REF_H = BAR_W, 108
local TUT_W = 620
local TUT_H = TUT_REF_H * TUT_SCALE
local TUT_X = (REF_W - TUT_W) / 2
-- Where the card is BUILT; restackTop moves it under the banner's slot the
-- moment it is shown, so this is only ever a starting value.
local TUT_Y = 14
-- How fast the armed rail button breathes while a card is asking for it, in
-- radians a second.
local TUT_PULSE_RATE = 5
-- THE CARD POPS (2026-09-11, owner: "make it tween pop in and out so its more
-- noticable"). Type that simply appears at the top of a moving map is
-- furniture -- it was there when you looked up. Type that lands is an event.
-- In: the block grows from TUT_POP_FROM of its size with a Back overshoot
-- while the ink fades up. Out: it shrinks a little and the ink fades off --
-- to nothing rather than to a dot, because a 560px paragraph collapsing to a
-- point reads as a glitch, not an exit. The size is tweened, not a UIScale:
-- see the note at the top of this file on why there is none.
local TUT_POP_IN = TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TUT_POP_OUT = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local TUT_INK_IN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TUT_POP_FROM = 0.55
local TUT_POP_TO = 0.8
-- What the four hand-set strokes on the card sit at (see buildTutorial): the
-- fade-in has to land them back there, not at the `label` default.
local TUT_STROKE_T = 0.1

-- =================================================================== build ==

function HUD.new(screen: ScreenGui): HUD
	local self = setmetatable({ screen = screen }, HUD)

	self.myColor = INK
	self.bannerStr = nil :: string?
	self.bannerColor = nil :: Color3?
	self.bannerBig = false
	self.targetStr = nil :: string?
	self.targetColor = nil :: Color3?

	-- Smoothing state for every figure this HUD draws, keyed by PLAYER (or
	-- team, or front) rather than by label, because the rows are pooled and a
	-- row can change owner between updates -- tweening per label would slide
	-- one nation's number toward another's.
	self.troopsShown, self.troopsTarget = {}, {}
	self.pctShown, self.pctTarget = {}, {}
	self.teamShown, self.teamTarget, self.teamAlive = {}, {}, {}
	self.tilesShown, self.tilesTarget = {}, {}
	self.frontShown, self.frontTarget = {}, {}
	self.rowInfo = {}
	self.order = {}

	-- ============================================== top-left: standings ====
	local board = scrim(panel(screen, "Board", BOARD_X, BOARD_Y, BOARD_W, BOARD_H))

	local title = label(board, "Title", BOARD_W, BOARD_H, 12, 7, 200, 13, INK_DIM, nil, FONT_DISPLAY)
	title.Text = "STANDINGS"

	local headerY = 8 + 12 + 8
	for _, c in COLS do
		local h = label(
			board, "H" .. c[1], BOARD_W, BOARD_H,
			c[2] + ROW_INSET, headerY, c[3], 11, INK_DIM,
			c[4] and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left
		)
		h.Text = c[1] == "Rank" and "#" or string.upper(c[1])
	end

	-- Hairline under the header rather than a filled header bar: the rule
	-- separates, the bar would compete with the rows for attention.
	box(board, "Rule", LINE, BOARD_W, BOARD_H, 10, headerY + 14, BOARD_W - 20, 1).BackgroundTransparency = 0.4

	local rowsY = BOARD_HEAD
	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.BackgroundTransparency = 1
	place(rows, BOARD_W, BOARD_H, 6, rowsY, BOARD_W - 12, BOARD_H - rowsY - 8)
	rows.Parent = board
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(ROW_GAP / (BOARD_H - rowsY - 8), 0)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = rows

	-- The rule that separates the podium from the client's own row. It is a
	-- child of the list rather than a decoration drawn over it, so it takes
	-- its own slice of the layout and the rows never have to know it exists.
	local rowsH = BOARD_H - rowsY - 8
	local split = Instance.new("Frame")
	split.Name = "Split"
	split.BackgroundTransparency = 1
	split.Size = UDim2.fromScale(1, ROW_SPLIT / rowsH)
	split.LayoutOrder = TOP_ROWS + 1
	split.Visible = false
	split.Parent = rows
	local splitLine = box(split, "Line", LINE, 1, ROW_SPLIT, 0, (ROW_SPLIT - 1) / 2, 1, 1)
	splitLine.BackgroundTransparency = 0.3
	self.split = split

	self.board, self.rows, self.rowPool = board, rows, {}
	self.rowsH = rowsH

	-- ============================================= top-centre: alert line ==
	-- One channel, not three. `setBanner` (phase / result) outranks
	-- `setTarget` (who you are fighting); when neither has anything to say the
	-- strip disappears entirely instead of printing "PLAYER".
	local alert = panel(screen, "Banner", ALERT_X, 14, ALERT_W, 32)
	alert.Visible = false
	self.alertText = label(alert, "Text", ALERT_W, 32, 12, 10, ALERT_W - 24, 14, INK, Enum.TextXAlignment.Center)
	self.alert = alert

	-- team share bar (team modes only)
	local teamPanel = panel(screen, "Teams", ALERT_X, 14, ALERT_W, 22)
	teamPanel.Visible = false
	local teamTrack = box(teamPanel, "Track", TRACK, ALERT_W, 22, 5, 5, ALERT_W - 10, 12)
	teamTrack.ClipsDescendants = true
	self.teamPanel, self.teamTrack, self.teamSegs = teamPanel, teamTrack, {}

	-- THE FINISH LINE. The segments say who holds what; on their own they never
	-- said how close that is to the end of the round, which is the only reason to
	-- watch a share bar at all. It MOVES: the win bar decays through overtime, so
	-- a deadlocked round visibly walks its own finish line back toward the
	-- empires instead of sitting there.
	--
	-- ZIndex 2 explicitly. ZIndexBehavior.Global, so being the last child of the
	-- track buys this nothing against the segments drawn inside it.
	local winLine = box(teamTrack, "WinLine", GOLD, ALERT_W - 10, 12, 0, 0, 3, 12)
	winLine.ZIndex = 2
	winLine.Visible = false
	self.winLine = winLine

	-- ================================================ bottom-left: leave ==
	-- A real TextButton for the same reason the rail's are: it eats its own
	-- click, so a press that lands here can never fall through to the map and
	-- start a war in the corner of the screen.
	local leave = Instance.new("TextButton")
	leave.Name = "Leave"
	leave.BackgroundColor3 = LEAVE_FILL
	leave.BackgroundTransparency = 0.04
	leave.BorderSizePixel = 0
	leave.AutoButtonColor = false
	leave.Text = ""
	leave.Active = true
	leave.Visible = false
	place(leave, REF_W, REF_H, LEAVE_X, LEAVE_Y, LEAVE_W, LEAVE_H)
	scrim(leave)
	local leaveEdge = Instance.new("UIStroke")
	leaveEdge.Color = THREAT
	leaveEdge.Thickness = 1
	leaveEdge.Transparency = 0.35
	leaveEdge.Parent = leave
	leave.Parent = screen

	-- ZIndex 2 on the type, explicitly: ZIndexBehavior.Global, so being a child
	-- of the button buys it nothing against a sibling panel drawn later.
	local leaveText = label(leave, "Title", LEAVE_W, LEAVE_H, 12, 11, LEAVE_W - 24, 14, LEAVE_INK, Enum.TextXAlignment.Left, FONT_DISPLAY)
	leaveText.ZIndex = 2
	leaveText.Text = "LOBBY"
	local leaveHint = label(leave, "Hint", LEAVE_W, LEAVE_H, 12, 28, LEAVE_W - 24, 10, LEAVE_INK, Enum.TextXAlignment.Left)
	leaveHint.ZIndex = 2
	leaveHint.Text = "LEAVE MATCH"
	self.leave, self.leaveText, self.leaveHint = leave, leaveText, leaveHint
	self.leaveEdge = leaveEdge
	self.leaveArmed = 0


	-- Knocked out, and the pulse that runs while it is true. See setDefeated.
	self.defeated = false
	self.leavePulse = nil :: Tween?
	leave.MouseEnter:Connect(function()
		if self.leaveArmed <= 0 then
			leave.BackgroundColor3 = LEAVE_HOVER
		end
	end)
	leave.MouseLeave:Connect(function()
		if self.leaveArmed <= 0 then
			leave.BackgroundColor3 = LEAVE_FILL
		end
	end)

	-- ============================================== bottom-left: revive ==
	-- Same construction as LOBBY under it. See REVIVE_FILL.
	local revive = Instance.new("TextButton")
	revive.Name = "Revive"
	revive.BackgroundColor3 = REVIVE_FILL
	revive.BackgroundTransparency = 0.04
	revive.BorderSizePixel = 0
	revive.AutoButtonColor = false
	revive.Text = ""
	revive.Active = true
	revive.Visible = false
	place(revive, REF_W, REF_H, LEAVE_X, REVIVE_Y, LEAVE_W, LEAVE_H)
	scrim(revive)
	local reviveEdge = Instance.new("UIStroke")
	reviveEdge.Color = GAIN
	reviveEdge.Thickness = 1
	reviveEdge.Transparency = 0.35
	reviveEdge.Parent = revive
	revive.Parent = screen
	local reviveText = label(revive, "Title", LEAVE_W, LEAVE_H, 12, 11, LEAVE_W - 24, 14, REVIVE_INK, Enum.TextXAlignment.Left, FONT_DISPLAY)
	reviveText.ZIndex = 2
	reviveText.Text = "REVIVE"
	local reviveHint = label(revive, "Hint", LEAVE_W, LEAVE_H, 12, 28, LEAVE_W - 24, 10, REVIVE_INK, Enum.TextXAlignment.Left)
	reviveHint.ZIndex = 2
	reviveHint.Text = ""
	self.revive, self.reviveText, self.reviveHint = revive, reviveText, reviveHint
	self.reviveTokens = 0
	self.revivePrice = nil :: number?
	-- Whether the product exists on the site yet. Without an id the button
	-- can only honestly show for somebody already holding a token.
	self.reviveLive = Products.isLive(Products.product("REVIVE"))
	revive.MouseEnter:Connect(function()
		revive.BackgroundColor3 = REVIVE_HOVER
	end)
	revive.MouseLeave:Connect(function()
		revive.BackgroundColor3 = REVIVE_FILL
	end)
	-- THE PRICE, ASKED OF THE SITE rather than read off the catalogue: managed
	-- pricing varies it by region. Spawned and pcall'd; a hint that keeps
	-- reading BUY is a far smaller failure than a HUD that never finishes.
	if self.reviveLive then
		task.spawn(function()
			local entry = Products.product("REVIVE") :: any
			local ok, info = pcall(function()
				return game:GetService("MarketplaceService"):GetProductInfo(entry.id, Enum.InfoType.Product)
			end)
			if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
				self.revivePrice = tonumber(info.PriceInRobux)
				HUD.paintRevive(self)
			end
		end)
	end

	-- =============================================== bottom-right: clock ==
	local clock = panel(screen, "Clock", CLOCK_X, CLOCK_Y, CLOCK_W, CLOCK_H)
	-- Kept on the instance because setTimer hides the whole panel once the
	-- clock is only counting up (see there).
	self.clockPanel = clock
	-- The figure carries most of the growth (20 -> 30) and its caption barely
	-- any (10 -> 11): what was too small to read at a glance is the TIME, and
	-- scaling the whole block evenly would have spent the extra pixels on the
	-- word underneath it.
	self.clockText = label(clock, "Time", CLOCK_W, CLOCK_H, 16, 10, 144, 30, INK, Enum.TextXAlignment.Left, FONT_DISPLAY)
	-- ANCHORED AT ITS LEFT-CENTRE, so the countdown punch (see setTimer and
	-- the clock section of step) grows the figure out from where the digits
	-- start and about their own middle, rather than from the top-left corner
	-- of the box. Same place on screen at rest: the anchor moved down by half
	-- the box and so did the position.
	self.clockText.AnchorPoint = Vector2.new(0, 0.5)
	self.clockText.Position = UDim2.fromScale(16 / CLOCK_W, (10 + 30 / 2) / CLOCK_H)
	self.clockSize = self.clockText.Size
	self.phaseText = label(clock, "Phase", CLOCK_W, CLOCK_H, 16, 43, 144, 11, INK_OFF)

	-- ============================================ bottom: command bar =====
	-- REDESIGN 2026-08-31. The bar printed seven figures with two captions
	-- between them, on five different baselines, and finished with two
	-- identical full-width bars -- one a readout, one a control. Read cold it
	-- was a scatter of numbers. Three rules fix it:
	--
	--   a. EVERY FIGURE IS UNDER A CAP THAT NAMES IT. The captions cost nine
	--      pixels each and are the difference between "0" and "GOLD 0".
	--   b. AN ICON SITS BESIDE WHAT IT LABELS. The sword was pinned to the
	--      panel's top edge two rows above the army, where it read as
	--      decoration.
	--   c. THERE IS NOTHING LEFT TO DRAG. Attack size is three buttons now,
	--      not a slider, so every control on this bar is a target you press
	--      rather than a value you aim at -- and everything on it, readout
	--      and control alike, is flat and sharp.
	local bar = scrim(panel(screen, "Bar", BAR_X, BAR_Y, BAR_W, BAR_H))

	local function cap(name: string, x: number, y: number, w: number, align: Enum.TextXAlignment?): TextLabel
		return label(bar, name, BAR_W, BAR_H, x, y, w, 10, INK_OFF, align)
	end

	-- --------------------------------------------------------- army ------
	cap("CapArmy", 16, 8, 90).Text = "ARMY"
	icon(bar, "IconArmy", Icons.SWORD, BAR_W, BAR_H, 14, 22, 26, 26)

	-- The hero. Everything else on screen is smaller than this on purpose.
	self.armyText = label(bar, "Army", BAR_W, BAR_H, 46, 20, 100, 30, INK, Enum.TextXAlignment.Left, FONT_DISPLAY)
	-- ANCHORED AT ITS LEFT-CENTRE, the clock's trick, so the city punch (see
	-- ARMY_PUNCH) grows the figure out from where its digits start and about
	-- its own middle. Same place on screen at rest.
	self.armyText.AnchorPoint = Vector2.new(0, 0.5)
	self.armyText.Position = UDim2.fromScale(46 / BAR_W, (20 + 30 / 2) / BAR_H)
	self.armySize = self.armyText.Size

	-- THE GREEN UP ARROW (owner, 2026-09-12: "add a green up arrow near the
	-- number to communicate this"). The punch flashes the figure green and
	-- bounces it, which says SOMETHING HAPPENED but not which WAY -- and to
	-- anyone who looks up a beat late it says nothing at all, because by then
	-- it is only a number in an odd colour. An arrow is the direction, which
	-- is the entire content of the event: the ceiling went UP.
	--
	-- TWO ROTATED BARS, NOT A SPRITE OR A GLYPH. There is no arrow in Icons --
	-- the tutorial's off-screen chevron is built this way for the same reason
	-- and says so -- and FONT_DISPLAY cannot be trusted to carry an arrow
	-- codepoint. Each bar wears the dark outline every glyph on this HUD has,
	-- which matters more here than anywhere: it sits beside a figure that is
	-- itself changing colour.
	--
	-- IT EXISTS ONLY INSIDE THE PUNCH. `step` shows it, fades it on the same
	-- green ramp as the figure and takes it away again -- a green arrow
	-- standing next to the army all match long would be a claim about the
	-- army rather than an event, and the one thing it must not become is
	-- furniture.
	--
	-- The resting x is the gap between the figure's box (ends at 146) and the
	-- army cap (starts at 176); `step` slides it along that gap to hug however
	-- many digits the figure currently has.
	--
	-- SQUARE BY CONSTRAINT, like the standings avatar: this HUD is laid out in
	-- Scale, so an authored square is a rectangle on any viewport that is not
	-- the 16:9 reference, and a skewed chevron reads as a tick.
	local up = Instance.new("Frame")
	up.Name = "ArmyUp"
	up.BackgroundTransparency = 1
	up.BorderSizePixel = 0
	up.Active = false
	up.Visible = false
	place(up, BAR_W, BAR_H, 150, 26, 18, 18)
	local upRatio = Instance.new("UIAspectRatioConstraint")
	upRatio.AspectRatio = 1
	upRatio.DominantAxis = Enum.DominantAxis.Height
	upRatio.Parent = up
	-- Both bars pivot on the APEX -- the left one from its right end, the
	-- right one from its left -- so the two meet there whatever their length,
	-- and the chevron can be retuned by changing one Size.
	for i, side in { -1, 1 } do
		local b = Instance.new("Frame")
		b.Name = "Bar" .. i
		b.AnchorPoint = Vector2.new(side < 0 and 1 or 0, 0.5)
		b.Position = UDim2.fromScale(0.5, 0.3)
		b.Size = UDim2.fromScale(0.62, 0.2)
		b.Rotation = 45 * side
		b.BackgroundColor3 = GAIN
		b.BorderSizePixel = 0
		b.Active = false
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0.5, 0)
		bc.Parent = b
		local bs = Instance.new("UIStroke")
		bs.Color = Color3.fromRGB(14, 18, 26)
		bs.Thickness = 1.2
		bs.Transparency = 0.25
		bs.Parent = b
		b.Parent = up
	end
	up.Parent = bar
	self.armyUp = up

	-- The ceiling, RIGHT-aligned to the far end of the bar beneath it, so the
	-- three together read the way a health bar does: value at one end, cap at
	-- the other, fill between them explaining both. Left-aligned at a fixed x
	-- it floated in the gap after a hero number whose width changes with the
	-- figure, which is why it looked unrelated to anything.
	self.armyCap = label(bar, "Cap", BAR_W, BAR_H, 176, 36, 88, 12, INK_DIM, Enum.TextXAlignment.Right)
	-- ...and the cap from its RIGHT-centre, the end of the bar it is pinned to.
	self.armyCap.AnchorPoint = Vector2.new(1, 0.5)
	self.armyCap.Position = UDim2.fromScale((176 + 88) / BAR_W, (36 + 12 / 2) / BAR_H)
	self.capSize = self.armyCap.Size

	-- Flat, sharp, and only as wide as the army column. The slider below is
	-- rounded, notched and knobbed. Two identical full-width bars was the
	-- single most confusing thing on this panel -- and that is the ceiling on
	-- what LAND leaving can hand the army: 248 px of the strip's 528, grown
	-- from 222 but still visibly short of the attack row underneath it.
	local troopBack = box(bar, "TroopBar", TRACK, BAR_W, BAR_H, 16, 54, 248, 7)
	self.troopFill = box(troopBack, "Fill", INK, 248, 7, 0, 0, 0, 7)

	self.incomeText = label(bar, "Income", BAR_W, BAR_H, 16, 65, 108, 11, GAIN)
	-- Right edge on the troop bar's, like the cap above it: these three are
	-- one column and it ends where the bar ends, at 264.
	self.gainText = label(bar, "Gain", BAR_W, BAR_H, 154, 65, 110, 11, GAIN, Enum.TextXAlignment.Right)

	-- --------------------------------------------------------- gold ------
	-- The treasury, and nothing else. This column used to carry a second
	-- line pricing the next city -- a caption, a swapping icon and a
	-- number that turned red when it was out of reach -- which made the
	-- economy read as the busiest thing on the bar when it is the
	-- secondary loop. One coin, one figure, the full height of the block.
	--
	-- TWO COLUMNS NOW, NOT THREE (owner, 2026-09-12: "remove the land
	-- information on the right and fill the space" -- the readout itself is
	-- gone; see HUD.setArmy for why). LAND held 404..544 and gold sat hard up
	-- against it at 248, so simply deleting it would have left the bar's
	-- right third empty with everything crowded into the left two. Instead
	-- the two survivors split the 16..544 strip in half: army 16..264, gold
	-- 296..544, a 32 px gutter between them.
	--
	-- The gold figure keeps its LEFT edge fixed and its box runs on to the
	-- margin. Centring it in its half would move the number every time the
	-- treasury changed width -- the mistake the army cap above was moved off
	-- a fixed x to avoid -- and the slack to its right is now room a
	-- six-figure balance never had at 106 px wide.
	cap("CapGold", 296, 8, 90).Text = "GOLD"
	icon(bar, "IconGold", Icons.GOLD, BAR_W, BAR_H, 294, 28, 36, 36)
	self.goldText = label(bar, "Gold", BAR_W, BAR_H, 338, 33, 206, 26, GOLD, Enum.TextXAlignment.Left, FONT_DISPLAY)
	self.goldStr = nil

	-- ------------------------------------------------------ control ------
	-- A rule, because everything above it is the game telling you something
	-- and everything below it is you telling the game something.
	box(bar, "Rule", LINE, BAR_W, BAR_H, 16, 78, 528, 1).BackgroundTransparency = 0.55

	local capCommit = label(bar, "CapCommit", BAR_W, BAR_H, 16, 83, 224, 11, INK_OFF)
	-- Names the figure, and nothing else. It used to read "ATTACK SIZE  1 2 3"
	-- to advertise the hotkeys, but the three buttons directly under it already
	-- read 25% / 50% / 75% -- so the caption was printing a second, differently
	-- shaped list of the same three choices, right where the eye lands to find
	-- out what the row IS. The hotkeys still work regardless.
	capCommit.Text = "ATTACK SIZE"
	-- The troop count is the only figure here, because it is the only one the
	-- row does not already draw: the lit button underneath IS the percentage,
	-- so a "50%" caption floating above a button reading "50%" was the same
	-- number twice, three inches apart.
	self.commitText = label(bar, "Commit", BAR_W, BAR_H, 386, 83, 158, 13, INK, Enum.TextXAlignment.Right)

	-- THREE BUTTONS, where the slider (and briefly an automatic ladder) used
	-- to be. Same strip, same 528 px -- but every pixel of it is now a target,
	-- where the slider put the whole decision inside a 22 px knob.
	--
	-- Real TextButtons rather than Frames plus a hit test: a button consumes
	-- its own click, so a press that lands here can never fall through to the
	-- map and open a war where the player meant to change a setting.
	local presets = Config.ATTACK_PRESETS or { 0.25, 0.5, 0.75 }
	local btnGap = 6
	local btnW = (528 - btnGap * (#presets - 1)) / #presets
	self.presets = {}
	for i, ratio in presets do
		local b = Instance.new("TextButton")
		b.Name = "Preset" .. i
		b.BackgroundColor3 = TRACK
		b.BorderSizePixel = 0
		-- The three states below carry this; Roblox's own tint would fight
		-- with the selected button being drawn in the player's map colour.
		b.AutoButtonColor = false
		b.FontFace = FONT_UI
		b.TextScaled = true
		b.TextColor3 = INK_DIM
		b.Text = string.format("%d%%", math.floor(ratio * 100 + 0.5))
		local tsc = Instance.new("UITextSizeConstraint")
		tsc.MaxTextSize = 48
		tsc.MinTextSize = 6
		tsc.Parent = b
		-- A TextButton is not built by `label`, so it needs the outline rule
		-- applied by hand. Same reasoning, one size: the caption is ~13px.
		local pstroke = Instance.new("UIStroke")
		pstroke.Name = "PresetStroke"
		pstroke.Color = Color3.new()
		pstroke.Thickness = 1
		pstroke.Transparency = 0.4
		pstroke.LineJoinMode = Enum.LineJoinMode.Round
		pstroke.Parent = b
		-- Padding in SCALE, not offset: TextScaled fills the padded box, and a
		-- pixel pad would be a different share of the button on every viewport.
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.2, 0)
		pad.PaddingBottom = UDim.new(0.2, 0)
		pad.Parent = b
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 3)
		corner.Parent = b
		place(b, BAR_W, BAR_H, 16 + (btnW + btnGap) * (i - 1), 96, btnW, 22)
		b.Parent = bar
		-- Hover is the only thing that says "pressable" BEFORE the press. The
		-- selected one is skipped: it is already lit, and dimming it on hover
		-- would read as deselecting it.
		b.MouseEnter:Connect(function()
			if self.presetIndex ~= i then
				b.BackgroundColor3 = PANEL_HI
			end
		end)
		b.MouseLeave:Connect(function()
			if self.presetIndex ~= i then
				b.BackgroundColor3 = TRACK
			end
		end)
		self.presets[i] = { button = b, ratio = ratio }
	end
	-- 0, not 1: selectPreset short-circuits on an unchanged index, and the
	-- first real call legitimately selects a button.
	self.presetIndex = 0
	self.bar = bar

	-- ========================================================= right rail ==
	-- Real TextButtons, for the reason the size buttons are: a button eats its
	-- own click, so a press that lands here can never fall through to the map
	-- and start a war where the player meant to place a house. The rail FRAME
	-- is Active too, which is what stops a press in the 8px gutter between two
	-- buttons doing the same thing.
	local rail = Instance.new("Frame")
	rail.Name = "Rail"
	rail.BackgroundTransparency = 1
	rail.Active = true
	rail.Visible = false
	place(rail, REF_W, REF_H, RAIL_X, RAIL_Y, RAIL_W, RAIL_H)
	rail.Parent = screen
	self.rail = rail

	self.actions = {}
	for i, a in RAIL_ACTIONS do
		local b = Instance.new("TextButton")
		b.Name = "Act" .. a.id
		b.BackgroundColor3 = PANEL
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.Text = ""
		place(b, RAIL_W, RAIL_H, (RAIL_BTN_W + RAIL_GAP) * (i - 1), 0, RAIL_BTN_W, RAIL_BTN_H)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, RAIL_CORNER)
		corner.Parent = b
		-- THE SAME BACKGROUND AS THE REST OF THE HUD (owner, 2026-08-31).
		-- The standings board and the command bar both wear the kit's panel
		-- art; the rail was a flat near-black fill, so the one permanent
		-- control cluster on the right read as a different piece of UI laid
		-- over the game rather than as part of the same set. `scrim` sets the
		-- fill transparency, which is why the line above it is gone.
		scrim(b, RAIL_CORNER)
		local stroke = Instance.new("UIStroke")
		-- A GOLD RING ON THE "+" CARD (owner, 2026-09-21: "for the + button,
		-- id prefer a gold ring around it too"). The builds wear the HUD's
		-- hairline; this one wears the price colour, solid and twice as
		-- thick, so the one tile on the row that is not a purchase is the
		-- one ringed in the colour of one. setActions keeps it: its unarmed
		-- repaint writes LINE / 0.35 to every other stroke and leaves this.
		if a.plus then
			stroke.Color = GOLD
			stroke.Thickness = 2
			stroke.Transparency = 0
		else
			stroke.Color = LINE
			stroke.Thickness = 1
			stroke.Transparency = 0.35
		end
		-- ON THE BORDER, SAID OUT LOUD (2026-09-22). A UIStroke's default mode
		-- is Contextual, which on a TEXT button strokes the text -- and these
		-- buttons have no text, so every ring above, the hairline and the gold
		-- one, was drawn around nothing. The owner asked for the "+" ring a
		-- second time before this was found.
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = b
		b.Parent = rail

		-- THE HALO, and it is lit for one moment only: a lesson card asking
		-- for THIS button. The stroke below used to carry that alone, and a
		-- green hairline on an 84px tile reads only to somebody already
		-- looking at the rail -- which is exactly the player who did not need
		-- telling. This is a BRIGHT ring OUTSIDE the tile, so the pulse is
		-- visible from wherever on the map the eye happens to be.
		--
		-- ZIndex 0, because ZIndexBehavior.Global sorts on the number and not
		-- on tree order: the button sits at the default 1 and the halo has to
		-- be under it, or it washes the icon out.
		local glow = Instance.new("Frame")
		glow.Name = "Glow"
		glow.BackgroundColor3 = TUT_POINT
		glow.BackgroundTransparency = 1
		glow.BorderSizePixel = 0
		glow.Visible = false
		glow.ZIndex = 0
		place(
			glow, RAIL_W, RAIL_H,
			(RAIL_BTN_W + RAIL_GAP) * (i - 1) - RAIL_GLOW, -RAIL_GLOW,
			RAIL_BTN_W + RAIL_GLOW * 2, RAIL_BTN_H + RAIL_GLOW * 2
		)
		local glowCorner = Instance.new("UICorner")
		glowCorner.CornerRadius = UDim.new(0, RAIL_CORNER + RAIL_GLOW)
		glowCorner.Parent = glow
		glow.Parent = rail

		-- ...and the rings that travel out of it. A stroke and NO fill: an
		-- expanding solid would wipe across the map, and what is wanted is the
		-- outline arriving and leaving. AnchorPoint centre so growing one is a
		-- single Size write -- pinned by a corner it would crawl sideways as it
		-- grew. ZIndex 0 with the halo, under the tile's own contents.
		local pings: { any } = {}
		for r = 1, RAIL_PING_COUNT do
			local ping = Instance.new("Frame")
			ping.Name = "Ping" .. r
			ping.BackgroundTransparency = 1
			ping.BorderSizePixel = 0
			ping.AnchorPoint = Vector2.new(0.5, 0.5)
			ping.Visible = false
			ping.ZIndex = 0
			ping.Position = UDim2.fromScale(
				((RAIL_BTN_W + RAIL_GAP) * (i - 1) + RAIL_BTN_W / 2) / RAIL_W,
				(RAIL_BTN_H / 2) / RAIL_H
			)
			local pingCorner = Instance.new("UICorner")
			pingCorner.CornerRadius = UDim.new(0, RAIL_CORNER + RAIL_GLOW)
			pingCorner.Parent = ping
			local pingEdge = Instance.new("UIStroke")
			pingEdge.Color = TUT_POINT
			pingEdge.Thickness = 2
			pingEdge.Transparency = 1
			pingEdge.Parent = ping
			ping.Parent = rail
			pings[r] = { frame = ping, edge = pingEdge }
		end

		-- ZIndex 2 on every child, explicitly. This ScreenGui is
		-- ZIndexBehavior.Global, where being a child buys you nothing -- the
		-- comparison is across the whole gui and a sibling panel drawn later
		-- at the same ZIndex would cover these.
		-- THE "+" CARD DRAWS ONE GLYPH AND NOTHING ELSE: no icon, no key, no
		-- price. Its key and cost labels are still BUILT, because setActions
		-- repaints key, title and cost on every state change and wants the
		-- same record for every button -- the two it must not show are
		-- hidden, and the title IS the plus, set in a box that fills the tile.
		if a.icon then
			local img = icon(b, "Icon", a.icon, RAIL_BTN_W, RAIL_BTN_H, (RAIL_BTN_W - 30) / 2, 5, 30)
			img.ZIndex = 2
		end
		local key = label(b, "Key", RAIL_BTN_W, RAIL_BTN_H, 6, 5, 14, 9, INK_MUTE)
		key.ZIndex = 2
		key.Text = a.key
		key.Visible = not a.plus
		-- "Title", not "Name": a child called Name is shadowed by the
		-- instance's own Name property at every call site that goes looking
		-- for it, and this rail is exactly the kind of thing a later session
		-- reads back out of the tree to check.
		local nameLbl: TextLabel
		if a.plus then
			nameLbl = label(b, "Title", RAIL_BTN_W, RAIL_BTN_H, 4, (RAIL_BTN_H - 40) / 2, RAIL_BTN_W - 8, 40, INK, Enum.TextXAlignment.Center)
			nameLbl.Text = "+"
		else
			nameLbl = label(b, "Title", RAIL_BTN_W, RAIL_BTN_H, 4, 39, RAIL_BTN_W - 8, 11, INK, Enum.TextXAlignment.Center)
			nameLbl.Text = a.name
		end
		nameLbl.ZIndex = 2
		local costLbl = label(b, "Cost", RAIL_BTN_W, RAIL_BTN_H, 4, 53, RAIL_BTN_W - 8, 10, GOLD, Enum.TextXAlignment.Center)
		costLbl.ZIndex = 2
		costLbl.Visible = not a.plus

		-- THE TIP, lit while the pointer rests on the button. A CHILD of the
		-- button, anchored bottom-centre just above it, so layoutRail moving
		-- the button carries it along. ZIndex 20/21 because this ScreenGui is
		-- Global: it has to clear the neighbouring buttons, not just its own.
		local tip: Frame? = nil
		if a.tip then
			local tw, th = a.tipW or 120, 22
			local t = Instance.new("Frame")
			t.Name = "Tip"
			t.BackgroundColor3 = PANEL
			t.BackgroundTransparency = 0.05
			t.BorderSizePixel = 0
			t.AnchorPoint = Vector2.new(0.5, 1)
			t.Position = UDim2.fromScale(0.5, -6 / RAIL_BTN_H)
			t.Size = UDim2.fromScale(tw / RAIL_BTN_W, th / RAIL_BTN_H)
			t.Visible = false
			t.ZIndex = 20
			local tc = Instance.new("UICorner")
			tc.CornerRadius = UDim.new(0, RAIL_CORNER)
			tc.Parent = t
			local te = Instance.new("UIStroke")
			te.Color = LINE
			te.Thickness = 1
			te.Transparency = 0.35
			te.Parent = t
			local tl = label(t, "Text", tw, th, 8, (th - 11) / 2, tw - 16, 11, INK, Enum.TextXAlignment.Center)
			tl.ZIndex = 21
			tl.Text = a.tip
			t.Parent = b
			tip = t
		end

		local rec = {
			id = a.id, button = b, name = nameLbl, cost = costLbl,
			stroke = stroke, key = key, glow = glow, pings = pings, hover = false,
			price = a.price,
			-- Hidden for the whole of a lesson round -- see RAIL_ACTIONS. This
			-- record is assembled field by field rather than copied from the
			-- spec, so a new flag reaches setActions only if it is carried here.
			tutHide = a.tutHide,
			-- Acts on the press and never arms -- see RAIL_ACTIONS.reinforce.
			instant = a.instant,
			tip = tip,
			-- The keyboard's letter, kept so setActionKeys can put it back
			-- after a controller has had the caption.
			hotkey = a.key,
			-- A door, not a build -- bindActions leaves it to PlusTabClient.
			plus = a.plus,
			-- The gamepass this tile belongs to, or nil -- see
			-- RAIL_ACTIONS.meganuke. setActions hides the tile while it is
			-- not held.
			pass = a.pass,
		}
		self.actions[i] = rec
		-- Hover is REMEMBERED, not just painted. setActions repaints an
		-- unarmed button back to PANEL whenever its state changes, and with
		-- the cursor resting on it that silently cancels the hover until the
		-- pointer leaves and comes back.
		b.MouseEnter:Connect(function()
			rec.hover = true
			if rec.tip then
				rec.tip.Visible = true
			end
			if self.armed ~= a.id then
				b.BackgroundColor3 = RAIL_HOVER
			end
		end)
		b.MouseLeave:Connect(function()
			rec.hover = false
			if rec.tip then
				rec.tip.Visible = false
			end
			if self.armed ~= a.id then
				b.BackgroundColor3 = PANEL
			end
		end)
	end
	self.armed = nil :: string?

	-- WHICH PASSES THIS ACCOUNT HOLDS, for the pass-gated cards (2026-09-22,
	-- RAIL_ACTIONS.meganuke). Read off the local player's ConquestPass_<KEY>
	-- attributes -- the server's own write once the site has answered
	-- (ConquestMonetization.settlePass), true or false, nil until then -- and
	-- nil counts as not held: a card that showed before the answer would be a
	-- warhead the server is about to refuse. Kept live: a Money buy on the "+"
	-- page mid-round flips the attribute, and the rail re-keys itself so the
	-- next setActions puts the card up. Here and not in ConquestClient because
	-- that file has no local register left, and this is the HUD's own state.
	-- No LocalPlayer (an edit-mode probe) leaves the table empty; setPassHeld
	-- is the probe's way in.
	self.passes = {} :: { [string]: boolean }
	local lp = Players.LocalPlayer
	if lp ~= nil then
		local prefix = Products.PASS_ATTR
		for _, a in RAIL_ACTIONS do
			if a.pass then
				self.passes[a.pass] = lp:GetAttribute(prefix .. a.pass) == true
			end
		end
		lp.AttributeChanged:Connect(function(name: string)
			if string.sub(name, 1, #prefix) == prefix then
				local key = string.sub(name, #prefix + 1)
				self.passes[key] = lp:GetAttribute(name) == true
				-- Force the visible-set walk in setActions to re-lay the rail.
				self.railKey = nil
			end
		end)
	end

	-- ========================================================= pad legend ==
	-- See PAD_X. Built hidden; setPadHints shows it and writes the chips in
	-- the pad's own family (A or the cross, LT or L2). The chip frames and
	-- the type sit above the panel's scrim on purpose: this ScreenGui is
	-- ZIndexBehavior.Global, so a child at the default 1 does not outdraw
	-- its parent's fill by being one.
	local legend = scrim(panel(screen, "PadHints", PAD_X, 62, PAD_W, PAD_H))
	legend.Visible = false
	local function chip(name: string, x: number, y: number): TextLabel
		local c = Instance.new("Frame")
		c.Name = name
		c.BackgroundColor3 = PANEL_HI
		c.BorderSizePixel = 0
		c.ZIndex = 2
		place(c, PAD_W, PAD_H, x, y, PAD_CHIP, PAD_ROW)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 3)
		corner.Parent = c
		local stroke = Instance.new("UIStroke")
		stroke.Color = LINE
		stroke.Thickness = 1
		stroke.Transparency = 0.35
		stroke.Parent = c
		c.Parent = legend
		local g = label(c, "Glyph", PAD_CHIP, PAD_ROW, 0, 3.5, PAD_CHIP, 11, INK, Enum.TextXAlignment.Center, FONT_DISPLAY)
		g.ZIndex = 3
		return g
	end
	local rowA, rowB = 8, 8 + PAD_ROW + 4
	self.padHints = {
		frame = legend,
		attack = chip("Attack", 10, rowA),
		zoomOut = chip("ZoomOut", 10, rowB),
		zoomIn = chip("ZoomIn", 10 + PAD_CHIP + 4, rowB),
	}
	local wordA = label(legend, "AttackWord", PAD_W, PAD_H, 10 + PAD_CHIP + 8, rowA + 3.5, PAD_W - (10 + PAD_CHIP + 8) - 8, 11, INK_DIM)
	wordA.ZIndex = 2
	wordA.Text = "ATTACK"
	local wordB = label(legend, "ZoomWord", PAD_W, PAD_H, 10 + PAD_CHIP * 2 + 12, rowB + 3.5, PAD_W - (10 + PAD_CHIP * 2 + 12) - 8, 11, INK_DIM)
	wordB.ZIndex = 2
	wordB.Text = "ZOOM"

	-- ========================================================= hover card ==
	local hover = panel(screen, "Hover", 0, 0, 190, 56)
	hover.BackgroundTransparency = 0.05
	hover.Visible = false
	hover.ZIndex = 20
	self.hoverName = label(hover, "Name", 190, 56, 10, 9, 170, 14)
	self.hoverStats = label(hover, "Stats", 190, 56, 10, 27, 170, 11, INK_DIM)
	self.hoverTerrain = label(hover, "Terrain", 190, 56, 10, 42, 170, 10, INK_OFF)
	for _, d in hover:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = 21
		end
	end
	self.hover = hover

	-- ================================================ centre: the payout ====
	-- Built once and parked invisible, like the lesson card: it appears at the
	-- one moment the player has nothing else to do -- their empire has just
	-- fallen, or the map has just been taken -- so it is allowed the middle of
	-- the screen, which nothing else on this HUD ever occupies.
	--
	-- A CANVASGROUP, not a Frame, and that is the whole reason the card can
	-- leave gracefully: twenty labels, a stroke and a piece of panel art fade
	-- as ONE surface off a single GroupTransparency, where tweening each of
	-- them separately would go out of step the moment one of them is hidden.
	local wrap = Instance.new("CanvasGroup")
	wrap.Name = "Payout"
	wrap.BackgroundTransparency = 1
	wrap.Visible = false
	-- A CANVASGROUP IS NOT ACTIVE BY DEFAULT, where every other top-level child
	-- of this HUD comes from `panel()` and is. Without this a press on the card
	-- -- which sits dead centre, over the map -- fell through to the map's own
	-- InputBegan and was sent as an attack or a build on whatever tile happened
	-- to be behind it.
	wrap.Active = true
	-- CLIPPED, and that is how the card gets to be a different height for a
	-- winner (six rows) and for somebody who quit (three). `Body` below keeps
	-- its full authored height whatever the wrap does, so every label holds the
	-- scale position it was authored at instead of stretching; the wrap simply
	-- shows less of it. Resizing the wrap alone would squash the type.
	wrap.ClipsDescendants = true
	place(wrap, REF_W, REF_H, PAY_X, PAY_Y, PAY_W, PAY_H)
	wrap.Parent = screen

	local pay = Instance.new("Frame")
	pay.Name = "Card"
	pay.BackgroundColor3 = PANEL
	pay.BorderSizePixel = 0
	pay.Size = UDim2.fromScale(1, 1)
	pay.Parent = wrap
	scrim(pay, 8)
	local payStroke = Instance.new("UIStroke")
	payStroke.Color = GOLD
	payStroke.Thickness = 1.4
	payStroke.Transparency = 0.55
	payStroke.Parent = pay
	local payCorner = Instance.new("UICorner")
	payCorner.CornerRadius = UDim.new(0, 8)
	payCorner.Parent = pay

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.fromScale(1, 1)
	body.Parent = wrap
	self.payBody = body

	label(body, "Cap", PAY_W, PAY_H, PAY_PAD, 14, PAY_INNER, 11, INK_OFF, Enum.TextXAlignment.Center).Text =
		"MONEY EARNED"
	-- The hero figure, at the same 36px the army wears on the command bar:
	-- this is the one number the card exists to deliver, and everything under
	-- it is the receipt.
	self.payTotal = label(body, "Total", PAY_W, PAY_H, PAY_PAD, 30, PAY_INNER, 36, GOLD, Enum.TextXAlignment.Center, FONT_DISPLAY)
	box(body, "Rule", LINE, PAY_W, PAY_H, PAY_PAD, 78, PAY_INNER, 1).BackgroundTransparency = 0.4

	self.payRows = {}
	for i = 1, PAY_ROWS do
		local y = PAY_TOP + (i - 1) * PAY_ROW_H
		local row = {
			label = label(body, "L" .. i, PAY_W, PAY_H, PAY_PAD, y, 118, 11, INK_DIM),
			value = label(body, "V" .. i, PAY_W, PAY_H, PAY_PAD + 118, y, 74, 11, INK_OFF),
			amount = label(body, "A" .. i, PAY_W, PAY_H, PAY_PAD + 118 + 74, y, PAY_INNER - 118 - 74, 11, INK, Enum.TextXAlignment.Right),
		}
		row.label.Visible = false
		row.value.Visible = false
		row.amount.Visible = false
		self.payRows[i] = row
	end
	self.payBalance = label(body, "Balance", PAY_W, PAY_H, PAY_PAD, PAY_H - 26, PAY_INNER, 11, INK_OFF, Enum.TextXAlignment.Center)
	self.payout, self.payStroke = wrap, payStroke
	self.payHold = 0

	HUD.setArmy(self, 0, 0, 0)
	-- `or` default deliberately: a Config without the economy block must leave
	-- the HUD printing a wrong price, not fail to build the command bar at all.
	-- FIRST, not BASE: the two diverged when the opening rungs went in.
	HUD.setGold(self, 0, Config.CITY_COST_FIRST or Config.CITY_COST_BASE or 125000, 0)
	HUD.setRatio(self, Config.DEFAULT_ATTACK_RATIO, 0)
	return self
end

-- ============================================================== the payout ==
--
-- What the round was worth, once, at the moment it stopped being undecided.
-- `data` is the server's `money` message verbatim; nil takes the card away.
--
-- IT IS NOT PERMANENT. A player knocked out at minute four goes on watching
-- the rest of the round, and a receipt parked over the middle of the map for
-- the next ten minutes is a receipt they come to resent. It holds, then fades,
-- and the running balance lives on the lobby page where there is room for it.
function HUD.setPayout(self: HUD, data: any?)
	if not self.payout then
		return
	end
	if data == nil then
		self.payout.Visible = false
		self.payHold = 0
		return
	end
	self.payTotal.Text = "+" .. commas(data.total or 0)
	local lines = data.lines or {}
	local n = 0
	for i, row in self.payRows do
		local line = lines[i]
		local on = line ~= nil
		row.label.Visible = on
		row.value.Visible = on
		row.amount.Visible = on
		if line then
			n = i
			row.label.Text = line.label
			row.value.Text = line.value or ""
			row.amount.Text = "+" .. commas(line.amount)
		end
	end

	-- The card is exactly as tall as it has rows. `Body` keeps its authored
	-- height and the wrap crops to the used part, so nothing stretches.
	local used = PAY_TOP + n * PAY_ROW_H + PAY_FOOT
	place(self.payout, REF_W, REF_H, PAY_X, PAY_Y, PAY_W, used)
	self.payBody.Size = UDim2.fromScale(1, PAY_H / used)
	place(self.payBalance, PAY_W, PAY_H, PAY_PAD, used - 24, PAY_INNER, 11)
	-- A nil balance is a profile that did not load, not a balance of zero --
	-- see ConquestServer.settleMoney. Say nothing rather than print a total
	-- the server could not vouch for.
	self.payBalance.Text = data.balance and ("BANKED  " .. commas(data.balance)) or ""
	self.payout.Visible = true
	self.payout.GroupTransparency = 0
	self.payHold = PAY_HOLD
end

-- ============================================================= the lesson ==

-- Forward-declared: the card and the alert banner share the top-centre
-- column, so putting one up has to restack the other, and restackTop is
-- written further down beside the banner it belongs to.
local restackTop: (HUD) -> ()

-- The lines themselves. One caller (`setTutorial`, below) and it runs at most
-- once a round, so everything here is authored straight rather than pooled.
--
-- The frame is a COORDINATE SPACE AND A SWITCH -- somewhere to author four
-- labels against and one Visible to hide them all -- and draws nothing. The
-- progress bar went with the panel: a green bar floating over open water is a
-- panel by another name, and "STEP 2 OF 7" already answers the only question
-- it was there to answer.
local function buildTutorial(self: HUD)
	local card = Instance.new("Frame")
	card.Name = "Tutorial"
	card.BackgroundTransparency = 1
	-- NOT Active, and ConquestClient's refreshHudPanels skips this frame BY
	-- NAME. An invisible rect that stops the map panning under it is worse than
	-- the panel it replaced -- there is nothing on screen to explain why the
	-- drag died.
	card.Active = false
	card.Visible = false
	place(card, REF_W, REF_H, TUT_X, TUT_Y, TUT_W, TUT_H)
	-- ANCHORED AT ITS OWN CENTRE, so the pop grows out of the middle of the
	-- block rather than out of its top-left corner. Same footprint `place`
	-- just gave it -- the position is the centre of that rect. restackTop
	-- re-places it under the banner's slot on every pop-in.
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale((TUT_X + TUT_W / 2) / REF_W, (TUT_Y + TUT_H / 2) / REF_H)
	card.Parent = self.screen

	-- The step count and the round clock read as ONE line, either side of the
	-- centre. Ranged to the far corners -- where the panel used to put them --
	-- they were two scraps of type floating unattached to anything, because
	-- there is no longer a card edge under them to belong to.
	-- AUTHORED AGAINST THE REFERENCE BLOCK, drawn on the scaled one: see
	-- TUT_SCALE. Nothing in these calls knows the card is bigger.
	local mid = TUT_REF_W / 2
	-- 10px -> 14, and the title 15 -> 28 (owner: "make these texts bigger").
	-- The card has the room now that the body and hint lines are gone: it is
	-- three short strings on an otherwise empty 560x108 block, read over a
	-- moving map from whatever distance the player happens to be sitting at.
	self.tutStep = label(
		card, "Step", TUT_REF_W, TUT_REF_H,
		mid - 148, 2, 140, 14, INK_OFF, Enum.TextXAlignment.Right, FONT_DISPLAY
	)
	-- THE ROUND CLOCK, in the slot the SAFE countdown used to hold (owner,
	-- 2026-09-03: "remove the SAFE thing, thats not needed, instead display the
	-- game time"). The grace window itself is untouched and still refuses every
	-- attack on the student -- it just does not need a clock of its own, and a
	-- reassurance nobody asked for was crowding out the one figure a new player
	-- does want: when does this start, and then how long have I been at it.
	-- Written by setTimer, which owns the same figure top-right.
	self.tutClock = label(card, "Clock", TUT_REF_W, TUT_REF_H, mid + 8, 2, 140, 14, INK_OFF)
	-- The card is built LAZILY, on the first lesson, so the clock has been
	-- running a while by the time this label exists: it opens on the last
	-- string setTimer wrote rather than sitting blank until the next second.
	self.tutClock.Text = self.clockStr or ""
	-- ...and it is hidden outright once that clock is only counting up (see
	-- setTimer). The card is built LAZILY, so it has to ask now rather than
	-- wait for the next phase change, which in a tutorial round has already
	-- happened and will not come again.
	self.tutClock.Visible = self.tutClockOn == true

	self.tutTitle = label(card, "Title", TUT_REF_W, TUT_REF_H, 0, 24, TUT_REF_W, 28, INK, Enum.TextXAlignment.Center, FONT_DISPLAY)
	-- FULL INK, where inside the panel this was the caption grey. The scrim was
	-- doing half the contrast work; the map does none of it.
	self.tutBody = paragraph(card, "Body", TUT_REF_W, TUT_REF_H, 0, 40, TUT_REF_W, 44, INK)
	self.tutBody.TextXAlignment = Enum.TextXAlignment.Center
	-- Centred VERTICALLY too, which `paragraph` does not do: half this copy is
	-- one line and half is two, and top-aligned the short ones sat high.
	self.tutBody.TextYAlignment = Enum.TextYAlignment.Center
	-- ...and its cap goes up WITH the card (see TUT_SCALE). `paragraph` caps
	-- at 44, the authored box; at 1.35x a one-line body sits in a 59px box
	-- and 44 would have held it at the old size -- the one line on the card
	-- the 35% would not have reached. Scaled, not lifted: a cap left loose
	-- let the body outgrow the title on a big monitor.
	local bodyCap = self.tutBody:FindFirstChildOfClass("UITextSizeConstraint")
	if bodyCap then
		bodyCap.MaxTextSize = math.floor(44 * TUT_SCALE)
	end
	self.tutHint = label(card, "Hint", TUT_REF_W, TUT_REF_H, 0, 89, TUT_REF_W, 13, INK_DIM, Enum.TextXAlignment.Center)

	-- THE ONLY STROKES ON THIS HUD SET BY HAND. `label` and `paragraph` outline
	-- for text sitting on a panel, where the scrim under it is doing most of
	-- the work; these four lines are read over ocean, snow and every nation
	-- colour there is, and the outline is all the separation they get. The body
	-- gets a real edge, the small type only a firmer version of its own -- past
	-- about 1.2px a 10px caption fills its own counters in and gets harder to
	-- read, not easier.
	--
	-- Times TUT_SCALE: Thickness is fixed pixels and the type under it is
	-- now 35% taller, so the numbers below stay the same mark on the bigger
	-- letter rather than a thinner one.
	for gui, thick in {
		[self.tutBody] = 2,
		[self.tutTitle] = 2.4,
		[self.tutStep] = 1.5,
		[self.tutClock] = 1.5,
		[self.tutHint] = 1.2,
	} do
		local edge = gui:FindFirstChildOfClass("UIStroke")
		if edge then
			edge.Thickness = thick * TUT_SCALE
			edge.Transparency = 0.1
		end
	end

	self.tutorial = card
end

-- The card's footprint at `k` of its authored size, about its centre.
local function tutSize(k: number): UDim2
	return UDim2.fromScale(TUT_W * k / REF_W, TUT_H * k / REF_H)
end

-- Every tween the card has running, so the next pop can cancel the last one
-- mid-flight instead of fighting it. `tutGen` is bumped by every pop for the
-- same reason: a Completed that arrives for a pop already superseded must do
-- nothing, and Cancel() fires Completed too.
local function tutCancel(self: HUD)
	for _, tw in (self.tutTweens or {}) :: { Tween } do
		tw:Cancel()
	end
	self.tutTweens = {}
	self.tutGen = (self.tutGen or 0) + 1
	return self.tutGen
end

local function tutTween(self: HUD, inst: Instance, info: TweenInfo, goal: { [string]: any }): Tween
	local tw = TweenService:Create(inst, info, goal)
	table.insert(self.tutTweens, tw)
	tw:Play()
	return tw
end

-- The ink on the card, and its outlines: `t` 1 is gone, 0 is full. Set
-- outright with no `info`, tweened with one. The clock and hint have their
-- own Visible, owned elsewhere; a fade on a hidden label is harmless.
local function tutInk(self: HUD, t: number, info: TweenInfo?)
	for _, gui in { self.tutStep, self.tutClock, self.tutTitle, self.tutBody, self.tutHint } do
		local edge = gui:FindFirstChildOfClass("UIStroke")
		local edgeT = t + (1 - t) * TUT_STROKE_T
		if info then
			tutTween(self, gui, info, { TextTransparency = t })
			if edge then
				tutTween(self, edge, info, { Transparency = edgeT })
			end
		else
			gui.TextTransparency = t
			if edge then
				edge.Transparency = edgeT
			end
		end
	end
end

-- The card lands: from TUT_POP_FROM of its size and no ink, to full size
-- with a Back overshoot. The words are already written when this is called.
local function tutPopIn(self: HUD)
	local card = self.tutorial :: Frame
	tutCancel(self)
	self.tutLeaving = false
	card.Size = tutSize(TUT_POP_FROM)
	tutInk(self, 1)
	card.Visible = true
	restackTop(self)
	tutTween(self, card, TUT_POP_IN, { Size = tutSize(1) })
	tutInk(self, 0, TUT_INK_IN)
end

-- The card leaves, then `andThen` runs -- which is how a REPLACED card gets
-- its new words written only once the old ones are off the screen. A card
-- that is not up leaves instantly. The banner under it restacks when the
-- card has actually gone, not when it starts to.
local function tutPopOut(self: HUD, andThen: (() -> ())?)
	local card = self.tutorial
	if card == nil or not card.Visible then
		if andThen then
			andThen()
		end
		return
	end
	local gen = tutCancel(self)
	self.tutLeaving = true
	local tw = tutTween(self, card, TUT_POP_OUT, { Size = tutSize(TUT_POP_TO) })
	tutInk(self, 1, TUT_POP_OUT)
	tw.Completed:Once(function(ps: Enum.PlaybackState)
		if ps ~= Enum.PlaybackState.Completed or gen ~= self.tutGen then
			return
		end
		self.tutLeaving = false
		card.Visible = false
		restackTop(self)
		if andThen then
			andThen()
		end
	end)
end

-- The whole tutorial surface: one card, replaced when the server says a lesson
-- is done. `state` is `Tutorial.state` verbatim; nil takes the card away.
--
-- WHAT POPS AND WHAT DOES NOT. The server re-sends the SAME card whenever the
-- ring moves (see the `tutorial` handler in ConquestClient), and a card that
-- popped on every one of those would be a nervous tic, not a signal. So the
-- words are the identity: a card whose words match the one already up is
-- rewritten in place; anything else -- first card, next card, a card coming
-- back after `hidden` -- pops.
local function applyTutorial(self: HUD, state: any?)
	-- IS THIS A TUTORIAL ROUND AT ALL -- a different question from whether a
	-- card is on screen, and the two came apart when `hidden` arrived. The
	-- readouts a first-timer is spared (the front line, the share bar) key
	-- off THIS, so a five-second gap between two lessons does not pop them
	-- in and straight back out.
	-- ...UNLESS THE CARD IS A LITE ONE (Tutorial.attach, lite): a follower's
	-- three cards inside a real match. The card draws, the ring rings, the
	-- rail button points -- and nothing is stripped back, hidden or held,
	-- because the round is not a lesson; only this person's next tap is.
	self.inTutorial = state ~= nil and state.lite ~= true
	-- THE RING GOES WITH THE CARD. ConquestClient draws the ring the card is
	-- pointing at and installs this to be told what to ring -- from HERE, on
	-- the state actually being applied, so a card held back by setTutorialHold
	-- holds its ring back with it (see Tutorial.enterStep on why the two
	-- must never come apart). nil and `hidden` both ring nothing.
	if self.onTutorial then
		self.onTutorial(state)
	end
	-- THE TRACK IS WAITING, NOT TEACHING (`hidden`). The card the student was
	-- on is answered and the next one is not ready yet, so there is nothing
	-- true to print -- see Tutorial.state. Same exit as no tutorial at all,
	-- except `inTutorial` stays true above.
	if state == nil or state.hidden then
		self.tutSig = nil
		tutPopOut(self, nil)
		HUD.setTutorialArm(self, nil)
		return
	end
	if not self.tutorial then
		buildTutorial(self)
	end
	local card = self.tutorial :: Frame

	local sig = table.concat({
		tostring(state.id), tostring(state.index), tostring(state.title),
		tostring(state.body), tostring(state.hint),
		tostring(state.finished), tostring(state.failed),
	}, "\1")

	local function write()
		local index = math.clamp(tonumber(state.index) or 1, 1, math.max(1, tonumber(state.count) or 1))
		local count = math.max(1, tonumber(state.count) or 1)
		-- An ENDED track does not print a step number: "7 OF 7" beside a
		-- card that says you are finished is the same fact twice, and beside
		-- a card that says you were knocked out it is simply wrong.
		if state.failed then
			self.tutStep.Text = "TUTORIAL"
			self.tutStep.TextColor3 = THREAT
		elseif state.finished then
			self.tutStep.Text = "TUTORIAL"
			self.tutStep.TextColor3 = GAIN
		else
			self.tutStep.Text = string.format("STEP %d OF %d", index, count)
			self.tutStep.TextColor3 = INK_OFF
		end

		self.tutTitle.Text = tostring(state.title or "")
		self.tutBody.Text = tostring(state.body or "")
		local hint = tostring(state.hint or "")
		self.tutHint.Text = hint
		self.tutHint.Visible = hint ~= ""

		HUD.setTutorialArm(self, not (state.finished or state.failed) and state.arm or nil)
	end

	if card.Visible and not self.tutLeaving and sig == self.tutSig then
		-- The same card again -- the ring moved. Words refreshed, no pop.
		write()
		return
	end
	self.tutSig = sig
	if card.Visible then
		-- A different card while one is up: the old one leaves first, and
		-- the new words are written in the gap so they are never seen on the
		-- old card's way out.
		tutPopOut(self, function()
			write()
			tutPopIn(self)
		end)
	else
		write()
		tutPopIn(self)
	end
end

-- NO CARD FOR THE NEXT `seconds` (2026-09-11, owner: "show the first
-- instruction 1 second after a player loads in"). Stamped by ConquestClient's
-- `init` handler: that message lands while the map is still being painted,
-- and a card already up when the world appears is furniture -- it was there
-- when you looked. One that pops in a beat later is an event, which is what
-- the pop above was built for. Lives here rather than in the client because
-- ConquestClient is at Luau's 200-local ceiling (see [[conquest-tile-patterns]]
-- in the owner's notes) and three more locals there failed to compile.
function HUD.setTutorialHold(self: HUD, seconds: number)
	self.tutHoldUntil = os.clock() + seconds
end

-- Every card comes through here. A card that lands inside the hold waits it
-- out rather than jumping the queue; a newer card arriving inside the hold
-- replaces the waiting one (the generation check). nil and `hidden` never
-- wait -- taking a card away is not the thing being delayed -- and the round
-- is a tutorial from its first frame either way: the HUD keeps its war
-- readouts off the screen now, only the words wait.
function HUD.setTutorial(self: HUD, state: any?)
	self.tutShowGen = (self.tutShowGen or 0) + 1
	local gen = self.tutShowGen
	local wait = (self.tutHoldUntil or 0) - os.clock()
	if state ~= nil and not state.hidden and wait > 0 then
		applyTutorial(self, { hidden = true })
		task.delay(wait, function()
			if gen == self.tutShowGen then
				applyTutorial(self, state)
			end
		end)
		return
	end
	applyTutorial(self, state)
end

-- PUTTING ONE BUTTON'S POINTING OUT -- ALL OF IT, in one place.
--
-- THE BUG THIS EXISTS FOR (owner, 2026-09-03: "sometimes when you make it
-- disappear, some of the green is still there"). The pointing is three
-- things -- the halo, the RAIL_PING_COUNT rings travelling out of it, and a
-- thickened stroke -- and the teardown only ever cleared the halo. The rings
-- were left `Visible` at whatever size and transparency the frame they died
-- on had given them, which on the rail is a green outline sitting around a
-- button that is no longer being asked for. Nothing came back to sweep it up
-- either: the stepper that drives all of this is gated on `tutorialArm`, so
-- clearing the arm is exactly what stops anything from ever clearing them.
local function unpoint(a: any)
	a.glow.Visible = false
	for _, ping in a.pings do
		ping.frame.Visible = false
		-- The stroke as well as the frame. A ping is put back on screen by
		-- `Visible` alone, so one that died at 0.1 would flash solid for the
		-- frame before the phase catches up with it.
		ping.edge.Transparency = 1
	end
	-- setActions repaints the stroke's COLOUR and TRANSPARENCY off `styleKey`,
	-- but it never writes Thickness -- that belongs to the pulse, so putting it
	-- back belongs here. Guarded because this runs per button per frame.
	if a.stroke.Thickness ~= 1 then
		a.stroke.Thickness = 1
	end
end

-- Which action-rail button this card is asking for, if any. This is now the
-- ONLY thing that says which button -- the cards used to spell it out in a
-- hint line as well, which was the same instruction twice for the player who
-- reads and no help at all to the one who does not.
function HUD.setTutorialArm(self: HUD, id: string?)
	if self.tutorialArm == id then
		return
	end
	self.tutorialArm = id
	self.tutorialPulse = 0
	-- Hand the rail back. `setActions` only repaints a button whose drawn
	-- state changed, so a stroke left mid-pulse would stay mid-pulse forever;
	-- clearing the cached key is what asks for that repaint.
	for _, a in self.actions or {} do
		a.styleKey = nil
		unpoint(a)
	end
end

-- ================================================================ updates ==

-- Your colour is the one accent the HUD borrows from the map: the bar you
-- spend and the row that is you are the colour your territory is.
function HUD.setIdentity(self: HUD, name: string, color: Color3)
	self.myColor = color
	self.troopFill.BackgroundColor3 = color
	-- The selected size button is drawn in your own colour, so it cannot be
	-- styled until that colour is known. Pushing the current selection
	-- through again is what applies it.
	local sel = self.presets and self.presets[self.presetIndex]
	self.presetIndex = 0
	HUD.selectPreset(self, sel and sel.ratio or Config.DEFAULT_ATTACK_RATIO)
end

-- The treasury. `cityCost`, `cities` and `label` are still ACCEPTED and
-- ignored: the build price no longer has a home on the bar, and keeping the
-- signature means ConquestClient's two call sites did not have to move.
--
-- Design note 3 above bans gold-the-colour, and it applied for as long as
-- there was no gold-the-resource -- the objection was that it meant currency,
-- "your row" and the commit slider at once. It now means currency and nothing
-- else, which is the rule being satisfied rather than broken.
function HUD.setGold(self: HUD, amount: number?, cityCost: number?, cities: number?, label: string?)
	if amount == nil then
		self.goldText.Text = ""
		return
	end
	local str = formatCount(math.floor(amount))
	if str ~= self.goldStr then
		self.goldStr = str
		self.goldText.Text = str
	end
end

-- Structures have a home on screen now (the line above), so this is left only
-- so that anything still calling it is a no-op rather than an error.
function HUD.setStructures(self: HUD, counts: { [string]: number }?) end

-- A LESSON CARD IS ON SCREEN. What the banner reads to keep the top of the
-- screen to ONE set of words (owner, 2026-09-18: "2 sets of text is really
-- cluttered") -- see refreshAlert.
local function tutorialUp(self: HUD): boolean
	return self.tutorial ~= nil and self.tutorial.Visible
end

-- ...and whether this is a LESSON ROUND, card up or not. This one is what the
-- STRIPPING-BACK needs, because a gap between two lessons is not a moment to
-- hand a first-time player the readouts the whole tutorial has been keeping
-- off their screen.
local function tutorialRound(self: HUD): boolean
	return self.inTutorial == true
end

-- Read by ConquestClient, which keeps its own copy of the spawn-phase
-- instructions and has to know when the card is already saying it.
function HUD.isTutorial(self: HUD): boolean
	return tutorialRound(self)
end

function restackTop(self: HUD)
	-- THE STRIPS OWN THE TOP (owner, 2026-09-18: "swap the bar notification
	-- with the tutorial instruction"). The team panel and the alert banner
	-- stack from the margin, and the lesson card sits UNDER the banner's slot
	-- -- a slot that is reserved whether or not a banner is up, so the card
	-- never jumps when one comes or goes.
	local y = 14
	if self.teamPanel.Visible then
		place(self.teamPanel, REF_W, REF_H, ALERT_X, y, ALERT_W, 22)
		y += 26
	end
	-- The end of the round is the one time the strip changes size -- see
	-- WIN_W. Centred either way, so the two sizes share a spine.
	local w, h = ALERT_W, 32
	if self.bannerBig == true and self.bannerStr ~= nil then
		w, h = WIN_W, WIN_H
	end
	place(self.alert, REF_W, REF_H, (REF_W - w) / 2, y, w, h)
	y += h + 8
	-- Centre-anchored (buildTutorial), so the position is the middle of the
	-- rect that starts at `y`. Only the y moves; the pop tweens Size alone.
	local card = self.tutorial
	if card ~= nil then
		card.Position = UDim2.fromScale((TUT_X + TUT_W / 2) / REF_W, (y + TUT_H / 2) / REF_H)
	end
end

-- Reached once a frame through refreshFronts, so it writes only when the
-- printed line actually changes: a settled alert costs one string compare.
local function refreshAlert(self: HUD)
	local str, color = self.bannerStr, self.bannerColor
	-- The banner still speaks during a lesson -- build prices, refused clicks,
	-- the spawn clock are all answers to something the player just did. The
	-- front line is not: it is a running commentary on a war they have not
	-- been taught yet -- and while a CARD is up, in any round, it is a second
	-- set of words over the one that matters (owner, 2026-09-18: "2 sets of
	-- text is really cluttered"), so it waits for the card to go.
	if str == nil and not tutorialRound(self) and not tutorialUp(self) then
		str, color = self.targetStr, self.targetColor
	end
	-- Size is part of what is shown: a banner that keeps its words and
	-- changes its size still has to be re-placed.
	local big = self.bannerBig == true and self.bannerStr ~= nil
	if str == self.alertShown and color == self.alertShownColor and big == self.alertShownBig then
		return
	end
	self.alertShown, self.alertShownColor, self.alertShownBig = str, color, big
	if str == nil then
		self.alert.Visible = false
		return
	end
	self.alert.Visible = true
	self.alertText.Text = str
	self.alertText.TextColor3 = color or INK
	restackTop(self)
end

-- `big` asks for the end-of-round size (WIN_W x WIN_H) instead of the strip's
-- own. Same panel, same label: nothing is built for it.
function HUD.setBanner(self: HUD, str: string?, color: Color3?, big: boolean?)
	self.bannerStr, self.bannerColor, self.bannerBig = str, color, big == true
	refreshAlert(self)
end

-- "PLAYER" is the client's idle value; an idle state is not news, so it
-- clears the strip instead of parking a word on screen for the whole match.
function HUD.setTarget(self: HUD, str: string, color: Color3?)
	if str == nil or str == "" or str == "PLAYER" then
		self.targetStr, self.targetColor = nil, nil
	else
		self.targetStr, self.targetColor = str, color
	end
	refreshAlert(self)
end

-- THE COUNTDOWN PUNCH (owner, 2026-09-06: "during spawn phase, when the
-- countdown is counting down from 15, can you give a more noticeable
-- animation tween"). The figure used to just change: one digit swapped for
-- another, in a corner, in the same grey as the caption under it -- and a
-- clock that changes without moving is a clock nobody is watching. Now every
-- second LANDS: the figure jumps up in size and flashes white the frame the
-- digit changes, then eases back to its resting colour over half a second.
-- The resting colour is GOLD while it counts down (an instruction, the same
-- rule the lesson card's copy of this clock already follows) and INK once the
-- war is on (a record). The last five seconds hit harder -- twice the growth,
-- and the STARTS IN caption lights up with each one -- and the flip to WAR
-- gets the biggest hit of all, because that is the frame the whole round has
-- been counting toward.
--
-- Driven off the HUD's own frame clock rather than TweenService, like the
-- lesson ping: a tween per second would have to be created and cancelled
-- against the next one, and a cancelled tween leaves the label frozen at
-- whatever size it died on.
local CLOCK_PUNCH_LIFE = 0.5
local CLOCK_PUNCH_GROW = 0.45
local CLOCK_LAST_SECONDS = 5
local CLOCK_FLASH = Color3.new(1, 1, 1)

local function punchClock(self: HUD, amp: number)
	self.clockPunchT = 0
	self.clockPunchAmp = amp
end

-- THE ROUND CLOCK, and it means two different things either side of the first
-- shot: while the map is still being claimed it counts DOWN to the start, and
-- once the war is on it counts UP. Running up through the placement window
-- answered a question nobody asks -- how long have I been picking -- and left
-- the one they do ask to a banner.
--
-- WRITES THE LESSON'S CLOCK TOO. One figure in two places: the corner, for a
-- player who knows where to look, and the lesson card for one who does not.
function HUD.setTimer(self: HUD, seconds: number, phase: string, countdown: boolean?)
	-- CEIL on the way down so the clock reads 0:00 at the moment the round
	-- starts rather than a second before it, FLOOR on the way up so the first
	-- second of the war reads 0:00 rather than being skipped.
	local whole = countdown and math.ceil(seconds) or math.floor(seconds)
	local str = string.format("%d:%02d", whole // 60, whole % 60)
	if str ~= self.clockStr then
		self.clockStr = str
		self.clockText.Text = str
		if self.tutClock then
			self.tutClock.Text = str
		end
		-- A second of the countdown just landed. See CLOCK_PUNCH_LIFE.
		if countdown then
			punchClock(self, if whole <= CLOCK_LAST_SECONDS then 1 else 0.5)
			-- ...AND IT IS NOW AUDIBLE FOR THE LAST FIVE (owner, 2026-09-15).
			-- Same threshold the big punch already uses, so the sound and the
			-- animation are the same event rather than two that nearly agree.
			--
			-- THE PITCH RISES 5 -> 1 so the run has a direction: five identical
			-- beeps say "a clock is running", a rising five says "this is about
			-- to happen". ZERO drops BELOW the start pitch instead of continuing
			-- up -- a countdown that resolves downward reads as arrival, and it
			-- is the one tick that means the waiting is over rather than that
			-- another second went by.
			--
			-- Gated on the digit CHANGING (this whole block is), so it is once a
			-- second however often setTimer is called -- it runs every frame.
			if whole <= CLOCK_LAST_SECONDS and whole >= 0 then
				-- A NARROW RAMP, because the sample is now a PURPOSE-MADE beep
				-- and not the borrowed click this was first tuned against.
				-- Pitch is playback speed here, so it STRETCHES as well as
				-- transposes: the old 1.0 -> 1.45 turned a 1.02s recording into
				-- a 0.70s one, which is no longer the sound that was chosen.
				-- This keeps the direction and leaves the sample itself.
				--
				-- NO TICK ON ZERO (owner, 2026-09-15: "the final beep before the
				-- round start returns to the first note. that doesnt sound good").
				-- It played at 0.9 -- BELOW the 1.0 the ramp starts from -- so the
				-- last thing you heard was the sequence falling back underneath its
				-- own opening note. That was deliberate once ("resolves downward =
				-- arrival") and it simply does not sound like arrival. The round
				-- starting is its own event and announces itself.
				--
				-- NO VOLUME MULTIPLIER: the level is the slider on the instance
				-- in SoundService, which is where this game keeps its mix.
				if whole > 0 then
					local k = (CLOCK_LAST_SECONDS - whole) / CLOCK_LAST_SECONDS
					Sfx.play("Tick", { pitch = 1 + 0.15 * k })
				end
			end
		end
	end
	local cap = countdown and "STARTS IN" or string.upper(phase)
	if cap ~= self.phaseStr then
		local wasCounting = self.phaseStr == "STARTS IN"
		self.phaseStr = cap
		self.phaseText.Text = cap
		-- The corner figure's resting colour: an instruction while it counts
		-- down, a record once it counts up. The punch eases back to this.
		self.clockRest = if countdown then GOLD else INK
		if wasCounting then
			-- 0:00 became WAR. The biggest hit of the sequence.
			punchClock(self, 1.4)
		elseif self.clockPunchT == nil then
			self.clockText.TextColor3 = self.clockRest
		end
		-- THE CORNER CLOCK ONLY EXISTS WHILE IT COUNTS DOWN (owner, 2026-09-18:
		-- "once the game actually starts, theres no more need to display the
		-- match timer as it counts up") -- the same rule the lesson card's copy
		-- has carried since 2026-09-03, now applied to the corner too. Counting
		-- down it is an instruction; counting up it is only a record of how
		-- long you have been playing, and nobody asked. It stays a beat and a
		-- half so the 0:00 -> WAR punch above is still seen, then goes; a new
		-- countdown (the next round) brings it straight back. The generation
		-- counter is what stops a stale delay hiding a clock that has since
		-- started counting down again.
		self.clockGen = (self.clockGen or 0) + 1
		local gen = self.clockGen
		if countdown then
			self.clockPanel.Visible = true
		else
			task.delay(1.5, function()
				if self.clockGen == gen and self.clockPanel then
					self.clockPanel.Visible = false
				end
			end)
		end
		-- GOLD while it counts down, because a clock running out is an
		-- instruction; the grey of the step count beside it once it is only a
		-- record of how long you have been playing.
		if self.tutClock then
			self.tutClock.TextColor3 = countdown and GOLD or INK_OFF
		end
		-- ...AND IT ONLY EXISTS WHILE IT COUNTS DOWN (owner, 2026-09-03: "no
		-- need for the time elapsed at the top after the game starts"). Counting
		-- DOWN it is an instruction -- how long until this begins -- and worth a
		-- second home on the card a new player is already reading. Counting UP it
		-- is only a record of how long they have been playing, which the corner
		-- already keeps: two copies of one figure, neither of them asked for.
		-- See ONE HOME PER FACT at the top of this file.
		self.tutClockOn = countdown == true
		if self.tutClock then
			self.tutClock.Visible = self.tutClockOn
		end
	end
end

-- The ratio IS the state: which button reads as selected is derived from it
-- rather than tracked separately, so the lit button is never out of step with
-- the troop count beside it. Runs every frame off the render loop, so only the
-- FORMATTED string is compared and the buttons are restyled only when the
-- selection actually moves.
function HUD.setRatio(self: HUD, ratio: number, troops: number?)
	local str = formatTroops((troops or 0) * ratio) .. " TROOPS"
	if str ~= self.commitStr then
		self.commitStr = str
		self.commitText.Text = str
	end
	HUD.selectPreset(self, ratio)
end

-- Selected is your own map colour -- the same "this is yours" the troop bar
-- and your standings row use. NEAREST rather than equality: the ratio may
-- arrive clamped or off a float, and a selection that silently vanishes
-- because 0.7499999 is not 0.75 is the worst possible bug here.
function HUD.selectPreset(self: HUD, ratio: number)
	if not self.presets then
		return
	end
	local best, bestD = 0, math.huge
	for i, p in self.presets do
		local d = math.abs(p.ratio - ratio)
		if d < bestD then
			best, bestD = i, d
		end
	end
	if best == self.presetIndex then
		return
	end
	self.presetIndex = best
	for i, p in self.presets do
		if i == best then
			p.button.BackgroundColor3 = self.myColor or INK
			p.button.TextColor3 = PANEL
		else
			p.button.BackgroundColor3 = TRACK
			p.button.TextColor3 = INK_DIM
		end
	end
end

-- The HUD owns what a press LOOKS like; the client owns what it MEANS (it is
-- the thing holding the intent remote). One connection per button, made once.
function HUD.bindPresets(self: HUD, fn: (number) -> ())
	for _, p in self.presets do
		p.button.Activated:Connect(function()
			-- The press SOUNDS here for the same reason it LOOKS pressed here:
			-- this module owns what a press is, and the client owns what it
			-- means. A preset that the client then ignores still clicked.
			Sfx.play("Click")
			fn(p.ratio)
		end)
	end
end

-- ------------------------------------------------------------ action rail --

-- Same split as the size buttons: the HUD owns what a press LOOKS like, the
-- client owns what it MEANS. `fn` is handed the action id ("city" / "port" /
-- "nuke") and decides whether that arms, disarms or is refused -- which is
-- why nothing here toggles `self.armed` itself. The armed state is pushed
-- back in through setActions, so the lit button and the mode the next click
-- will actually run cannot drift apart.
-- ----------------------------------------------------------------- leave --

-- The one press on this HUD that cannot be taken back, so it is TWO presses.
-- The first arms the button -- red, and it says what the second one does --
-- and the second inside LEAVE_ARM leaves; anything else lets it forget. A
-- modal would be the other answer and is worse here: this is a corner control
-- during a live match, and a dialog over the map to confirm a corner control
-- costs the player more attention than the mistake it prevents.
--
-- Same split as every other control in this file: the HUD owns what a press
-- looks like, the client owns what it means.
function HUD.bindLeave(self: HUD, fn: () -> ())
	if not self.leave then
		return
	end
	self.leave.Activated:Connect(function()
		Sfx.play("Click")
		if self.leaveArmed > 0 then
			HUD.disarmLeave(self)
			fn()
			return
		end
		self.leaveArmed = LEAVE_ARM
		self.leave.BackgroundColor3 = THREAT
		self.leaveEdge.Transparency = 0
		-- Light type on the loud fill: at rest the button is dark red with pale
		-- red type, armed it is the reverse, so the two states are not two
		-- shades of one picture.
		self.leaveText.TextColor3 = INK
		self.leaveHint.TextColor3 = INK
		self.leaveText.Text = "LEAVE?"
		self.leaveHint.Text = "TAP AGAIN"
	end)
end

function HUD.disarmLeave(self: HUD)
	if not self.leave or self.leaveArmed <= 0 then
		return
	end
	self.leaveArmed = 0
	self.leave.BackgroundColor3 = LEAVE_FILL
	self.leaveEdge.Transparency = 0.35
	self.leaveText.TextColor3 = LEAVE_INK
	self.leaveHint.TextColor3 = LEAVE_INK
	self.leaveText.Text = "LOBBY"
	self.leaveHint.Text = "LEAVE MATCH"
end

-- Hidden until there is a match to leave. On the lobby page this whole HUD is
-- down anyway, but a client that has not been told which phase it is in must
-- not offer a way out of a round that has not started.
function HUD.showLeave(self: HUD, on: boolean)
	if not self.leave then
		return
	end
	if not on then
		HUD.disarmLeave(self)
	end
	self.leave.Visible = on
end

-- Where the two exits sit, and whether the way out breathes. Two states only:
-- stacked in their own corner while the match is still yours, and -- once it is
-- not -- REVIVE alone in that corner with the way out in the middle of the foot
-- of the screen.
--
-- REVIVE DROPS TO THE BASELINE when it is alone there. It is authored ABOVE
-- LOBBY (REVIVE_Y), so with LOBBY gone it would hang 54px off the bottom margin
-- while the clock and the moved button sit on it -- the one corner not on the
-- row the foot of this screen is built as. Same corner either way; it simply
-- takes the slot the button it was stacked on just vacated.
function HUD.layoutExits(self: HUD)
	local leave = self.leave
	if not leave then
		return
	end
	if self.revive then
		place(self.revive, REF_W, REF_H, LEAVE_X, self.defeated and LEAVE_Y or REVIVE_Y, LEAVE_W, LEAVE_H)
	end
	if self.leavePulse then
		self.leavePulse:Cancel()
		self.leavePulse = nil
	end

	if self.defeated then
		-- ANCHORED AT THE CENTRE, on the 14px baseline the clock and the revive
		-- card sit on, less half a button. The anchor is what makes the pulse
		-- grow evenly in all four directions: from an edge it would grow one
		-- way only and drag the caption across itself. See DEFEAT_PULSE.
		leave.AnchorPoint = Vector2.new(0.5, 0.5)
		leave.Position = UDim2.fromScale(0.5, (REF_H - 14 - DEFEAT_LEAVE_H / 2) / REF_H)
		leave.Size = UDim2.fromScale(DEFEAT_LEAVE_W / REF_W, DEFEAT_LEAVE_H / REF_H)
		-- Re-authored for this box rather than carried over: the words were laid
		-- out for a 132x44 corner button, and the scales that put them there land
		-- in the wrong place on a 260x64 one -- the two are not the same shape.
		-- They stay CHILDREN of the button, which is the whole point: everything
		-- inside it is sized in Scale, so one tween on the button carries the
		-- type with it.
		place(self.leaveText, DEFEAT_LEAVE_W, DEFEAT_LEAVE_H, 12, 15, DEFEAT_LEAVE_W - 24, DEFEAT_TITLE_PX)
		place(self.leaveHint, DEFEAT_LEAVE_W, DEFEAT_LEAVE_H, 12, 39, DEFEAT_LEAVE_W - 24, DEFEAT_HINT_PX)
		-- ...and the type is PINNED, so the body can breathe without it (see
		-- DEFEAT_TITLE_PX). The screen may not have been measured yet on the
		-- first frame of a round, so the reference height stands in rather than
		-- collapsing every caption to nothing.
		local viewH = self.screen.AbsoluteSize.Y
		local k = (viewH > 0 and viewH or REF_H) / REF_H
		for _, row in { { self.leaveText, DEFEAT_TITLE_PX }, { self.leaveHint, DEFEAT_HINT_PX } } do
			local lbl: TextLabel, px: number = row[1] :: any, row[2] :: any
			lbl.TextScaled = false
			lbl.TextSize = px * k
		end
		-- Centred type, because the button is now centred. Left-aligned was right
		-- in the corner, where the caption lined up with the revive card above it.
		self.leaveText.TextXAlignment = Enum.TextXAlignment.Center
		self.leaveHint.TextXAlignment = Enum.TextXAlignment.Center
		local tween = TweenService:Create(leave, DEFEAT_PULSE, {
			Size = UDim2.fromScale(
				DEFEAT_LEAVE_W * DEFEAT_PULSE_SCALE / REF_W,
				DEFEAT_LEAVE_H * DEFEAT_PULSE_SCALE / REF_H
			),
		})
		tween:Play()
		self.leavePulse = tween
	else
		leave.AnchorPoint = Vector2.new(0, 0)
		place(leave, REF_W, REF_H, LEAVE_X, LEAVE_Y, LEAVE_W, LEAVE_H)
		-- ...and the words go back to the geometry HUD.new authored them at.
		place(self.leaveText, LEAVE_W, LEAVE_H, 12, 11, LEAVE_W - 24, 14)
		place(self.leaveHint, LEAVE_W, LEAVE_H, 12, 28, LEAVE_W - 24, 10)
		self.leaveText.TextXAlignment = Enum.TextXAlignment.Left
		self.leaveHint.TextXAlignment = Enum.TextXAlignment.Left
		-- The size goes back to TextScaled, which is what every other label on
		-- this HUD uses and what the corner button was authored against.
		self.leaveText.TextScaled = true
		self.leaveHint.TextScaled = true
	end
end

-- KNOCKED OUT. Takes the bottom of the HUD away and moves the way out into the
-- space it leaves. See DEFEAT_LEAVE_W for why, and layoutExits for what happens
-- to the revive card left alone in the corner.
--
-- Called off the standings summary five times a second, so the unchanged case
-- has to cost one comparison.
function HUD.setDefeated(self: HUD, on: boolean)
	on = on == true
	if self.defeated == on then
		return
	end
	self.defeated = on
	if self.bar then
		self.bar.Visible = not on
	end
	-- Down on THIS frame rather than on the client's next showActions call:
	-- that is a frame away, and a rail still standing under a button that has
	-- just landed on top of it is exactly the frame somebody screenshots.
	if on and self.rail then
		self.rail.Visible = false
	end
	HUD.layoutExits(self)
end

-- ---------------------------------------------------------------- revive --

-- The hint under REVIVE: a token in hand skips the purchase and says so; none
-- in hand prices the purchase, or says BUY until the site has answered.
function HUD.paintRevive(self: HUD)
	if not self.revive then
		return
	end
	local n = self.reviveTokens or 0
	if n > 0 then
		self.reviveHint.Text = n == 1 and "1 IN HAND" or (n .. " IN HAND")
	else
		self.reviveHint.Text = self.revivePrice and ("R$ " .. self.revivePrice) or "BUY"
	end
end

-- The server's answer to "can this player come back": `allowed` is a live
-- round, a dead empire and an AI one free to take, and `tokens` is what they
-- already hold. nil (a new round, the round ending) takes the button down.
function HUD.setRevive(self: HUD, state: any?)
	if not self.revive then
		return
	end
	local tokens = state and tonumber(state.tokens) or 0
	local allowed = state ~= nil and state.allowed == true
	self.reviveTokens = tokens
	-- Without an id on the product the button cannot lead anywhere, so it
	-- shows only for somebody who already owns a token.
	local on = allowed and (tokens > 0 or self.reviveLive == true)
	self.revive.Visible = on
	if on then
		HUD.paintRevive(self)
	end
end

function HUD.bindRevive(self: HUD, fn: () -> ())
	if not self.revive then
		return
	end
	self.revive.Activated:Connect(function()
		Sfx.play("Click")
		fn()
	end)
end

-- FREE WARHEADS IN HAND ("+1 Nuke!", tutorial only -- see Products).
--
-- IT LIVES HERE BECAUSE THE CLIENT HAS NO ROOM FOR IT, and that is a hard
-- constraint rather than a preference: a single `local myFreeNukes = 0` in
-- ConquestClient's main chunk took it over Luau's limit -- "Out of local
-- registers when trying to allocate shaking: exceeded limit 200" -- and the
-- whole file stopped compiling. Sfx holds the at-war set and the pop curve for
-- exactly this reason; this is the third time that ceiling has decided where a
-- piece of state lives.
--
-- The HUD is also where it belongs on the merits: what this number changes is
-- what the launch button is allowed to say. The server stays the authority --
-- it re-checks at the order AND at the charge (Nukes) -- so a client that
-- lies to itself here buys nothing but a refusal.
function HUD.setFreeNukes(self: HUD, n: number)
	self.freeNukeCount = math.max(0, math.floor(tonumber(n) or 0))
end

function HUD.freeNukes(self: HUD): number
	return self.freeNukeCount or 0
end

-- THE CEILING A SPECIAL MODE ADDS (MEGA ARMY, 2026-09-18: Modes.SPECIAL
-- troopCapBonus), here for the reason every register around it is: the
-- client has no local left, and it mirrors Sim.maxTroops on every summary and
-- has to add the same flat figure the server does. Sent once, on `init`.
function HUD.setCapBonus(self: HUD, n: number)
	self.capBonusN = math.max(0, math.floor(tonumber(n) or 0))
end

function HUD.capBonus(self: HUD): number
	return self.capBonusN or 0
end

-- FREE DEFENCE TOWERS IN HAND (Starter Pack #1, 2026-09-17), here for the
-- same reason the warheads above are: ConquestClient has no local register
-- left -- see the note over setFreeNukes -- and what this number does is
-- decide what one rail button is allowed to say. The server prices every
-- build and re-checks it at canBuild AND at the charge, so a client that
-- lies to itself here buys nothing but a refusal.
function HUD.setFreePosts(self: HUD, n: number)
	self.freePostCount = math.max(0, math.floor(tonumber(n) or 0))
end

function HUD.freePosts(self: HUD): number
	return self.freePostCount or 0
end

-- Starter Pack #2's two other buildings (2026-09-17 evening), registers of
-- the same shape for the same reason: ConquestClient has no local left, and
-- all either number does is decide what one rail button may say.
function HUD.setFreeCities(self: HUD, n: number)
	self.freeCityCount = math.max(0, math.floor(tonumber(n) or 0))
end

function HUD.freeCities(self: HUD): number
	return self.freeCityCount or 0
end

function HUD.setFreeSams(self: HUD, n: number)
	self.freeSamCount = math.max(0, math.floor(tonumber(n) or 0))
end

function HUD.freeSams(self: HUD): number
	return self.freeSamCount or 0
end

-- THE ONE PLACE THAT MAPS A RAIL BUTTON TO WHAT IS IN HAND. Three separate
-- readers below ask this -- the unlock latch, the `tutHide` rule and the
-- caption -- and they MUST agree: a button that unlocks but still prints a
-- price, or prints a count but stays hidden, is worse than either failure
-- on its own. Adding a third free-something later means one line here.
local function freeFor(self: HUD, id: string): number
	if id == "nuke" then
		return HUD.freeNukes(self)
	elseif id == "post" then
		return HUD.freePosts(self)
	elseif id == "city" then
		return HUD.freeCities(self)
	elseif id == "sam" then
		return HUD.freeSams(self)
	end
	return 0
end

-- THE ANTI-NUKE TOWER'S PRICE, kept here for exactly the reason the count
-- above is: ConquestClient has no local register left (see the note over
-- setFreeNukes -- this is the FOURTH time that ceiling has decided where a
-- piece of state lives), and what this number does is decide what one rail
-- button is allowed to say. The server prices every build and re-checks it;
-- a client that lies to itself here buys nothing but a refusal.
function HUD.setSamCost(self: HUD, n: number)
	self.samCostValue = math.max(0, math.floor(tonumber(n) or 0))
end

function HUD.samCost(self: HUD): number
	return self.samCostValue or 0
end

-- THE REINFORCEMENT QUOTE (2026-09-21), kept here for the SAM price's reason
-- and one more: ConquestClient's `fronts` handler is defined ~1,900 lines
-- ABOVE its ACTION_COSTS table, so a write to that table from the handler
-- resolves to a nil GLOBAL and takes the whole handler down on the first
-- summary. `cost` is what one purchase costs now (0 = the army is at its
-- ceiling, nothing to sell); `left` is the cooldown in ticks. The feed line in
-- ConquestClient copies both into ACTION_COSTS every frame.
function HUD.setReinforce(self: HUD, cost: number?, left: number?, troops: number?)
	if cost ~= nil then
		self.reinforceCostValue = math.max(0, math.floor(tonumber(cost) or 0))
	end
	if left ~= nil then
		self.reinforceLeftValue = math.max(0, math.floor(tonumber(left) or 0))
	end
	-- The men the next press brings, printed on the button's tip. Written
	-- only when the figure moves: this arrives five times a second.
	if troops ~= nil then
		local n = math.max(0, math.floor(tonumber(troops) or 0))
		if n ~= self.reinforceTroopsValue then
			self.reinforceTroopsValue = n
			if self.actions then
				for _, a in self.actions do
					if a.id == "reinforce" and a.tip then
						local tl = a.tip:FindFirstChild("Text")
						if tl then
							-- A TROOP figure: formatTroops (t / 10), like the army
							-- readout it lands in -- formatCount printed ten times
							-- the men (owner, 2026-09-21: "reinforce troop number
							-- should be divided by 10").
							tl.Text = "+" .. formatTroops(n) .. " Troops"
						end
					end
				end
			end
		end
	end
end

function HUD.reinforceTroops(self: HUD): number
	return self.reinforceTroopsValue or 0
end

function HUD.reinforceCost(self: HUD): number
	return self.reinforceCostValue or 0
end

function HUD.reinforceLeft(self: HUD): number
	return self.reinforceLeftValue or 0
end

-- THE BATTERY'S PRICE, here for the reason the tower's is -- and it could not
-- have gone in ConquestClient's ACTION_COSTS even with a register to spare:
-- the "fronts" handler that receives it is compiled two thousand lines before
-- that table is declared, so a write to it from there is a global.
function HUD.setArtilleryCost(self: HUD, n: number)
	self.artilleryCostValue = math.max(0, math.floor(tonumber(n) or 0))
end

function HUD.artilleryCost(self: HUD): number
	return self.artilleryCostValue or 0
end

-- THE AIRFIELD'S PRICE, beside the tower's and for the same reason: the
-- client's "fronts" handler runs long before ACTION_COSTS or `place` are
-- declared and has no register of its own to spare, so the number is parked
-- here and read back on the frame. The server prices every build and
-- re-checks it; this only decides what one rail button says.
function HUD.setAirfieldCost(self: HUD, n: number)
	self.airfieldCostValue = math.max(0, math.floor(tonumber(n) or 0))
end

function HUD.airfieldCost(self: HUD): number
	return self.airfieldCostValue or 0
end

-- THE RAILGUN'S PRICE (2026-09-24), parked here for the airfield's reason.
function HUD.setRailgunCost(self: HUD, n: number)
	self.railgunCostValue = math.max(0, math.floor(tonumber(n) or 0))
end

function HUD.railgunCost(self: HUD): number
	return self.railgunCostValue or 0
end

-- Does this account hold the gamepass `key` (a Products.PASSES key), as far
-- as the rail knows (2026-09-22)? ConquestClient's `arm` asks this before
-- opening a pass-gated mode from a key or B's re-arm, so a hidden card has
-- no back door. The answer is the attribute mirror HUD.new keeps.
function HUD.passHeld(self: HUD, key: string): boolean
	return self.passes ~= nil and self.passes[key] == true
end

-- Writes the mirror by hand and re-keys the rail. For an edit-mode probe,
-- where there is no LocalPlayer to read attributes from; the live client
-- never needs it -- the AttributeChanged listener in HUD.new does this.
function HUD.setPassHeld(self: HUD, key: string, held: boolean)
	if self.passes == nil then
		self.passes = {}
	end
	self.passes[key] = held == true
	self.railKey = nil
end

function HUD.bindActions(self: HUD, fn: (string) -> ())
	if not self.actions then
		return
	end
	for _, a in self.actions do
		-- THE "+" CARD IS A DOOR, NOT A BUILD MODE. Its press belongs to
		-- PlusTabClient, which listens on the button directly; routed through
		-- here it would hand ConquestClient's `arm` an id with no building
		-- behind it and light the tile as if one were armed.
		if a.plus then
			continue
		end
		a.button.Activated:Connect(function()
			Sfx.play("Click")
			fn(a.id)
		end)
	end
end

-- WHERE THE VISIBLE BUTTONS SIT. Called only when the visible SET changes,
-- which in a tutorial is twice, because the alternative -- leaving hidden
-- buttons' slots empty -- puts the survivors off-centre under a bar that is
-- centred, and off-centre reads as broken rather than as deliberate.
--
-- The rail frame keeps its full width and only its contents move, so every
-- `place` here is still against RAIL_W/RAIL_H and nothing else has to know.
local function layoutRail(self: HUD, shown: { any })
	local total = #shown * RAIL_BTN_W + math.max(0, #shown - 1) * RAIL_GAP
	local x0 = (RAIL_W - total) / 2
	for j, a in shown do
		local x = x0 + (j - 1) * (RAIL_BTN_W + RAIL_GAP)
		place(a.button, RAIL_W, RAIL_H, x, 0, RAIL_BTN_W, RAIL_BTN_H)
		-- The halo and the pings are SIBLINGS of the button, not children of
		-- it (they draw under it at ZIndex 0), so they do not come along on
		-- their own and have to be moved by hand.
		place(
			a.glow, RAIL_W, RAIL_H,
			x - RAIL_GLOW, -RAIL_GLOW,
			RAIL_BTN_W + RAIL_GLOW * 2, RAIL_BTN_H + RAIL_GLOW * 2
		)
		for _, ping in a.pings do
			ping.frame.Position = UDim2.fromScale(
				(x + RAIL_BTN_W / 2) / RAIL_W,
				(RAIL_BTN_H / 2) / RAIL_H
			)
		end
	end
end

function HUD.showActions(self: HUD, on: boolean)
	-- BEING OUT OUTRANKS THE CALLER. The client asks for the rail every frame
	-- off `phase == "playing" and hasSpawned`, and hasSpawned stays true after
	-- an empire falls -- so without this the rail is back one frame after
	-- setDefeated took it down.
	if self.defeated then
		on = false
	end
	-- A rail hidden under the pointer never hears MouseLeave, so its tip
	-- would be waiting, lit, the next time the rail came back.
	if not on and self.actions then
		for _, a in self.actions do
			if a.tip and a.tip.Visible then
				a.hover = false
				a.tip.Visible = false
			end
		end
	end
	if self.rail then
		self.rail.Visible = on
	end
end

-- WHICH HOTKEY THE RAIL PRINTS. The letter is the keyboard's; a controller
-- has no C, and while a pad is the last thing touched the rail prints NOTHING
-- (ConquestClient swaps them as the device changes -- the cards are pressed
-- with the cursor, and the pad's own two commands are the legend, see PAD_X).
-- nil puts the letters back. Compared before written: the client calls this
-- on change, but a caption is a caption and rewriting an equal one is a relayout.
function HUD.setActionKeys(self: HUD, keys: { [string]: string }?)
	if not self.actions then
		return
	end
	for _, a in self.actions do
		-- A table is the pad's, and an action it does not name prints
		-- NOTHING. It used to fall back to the keyboard's letter, which is how
		-- the rail once told a console player to press "G" -- and since
		-- 2026-09-21 no pad button arms a card at all (owner: the cards are
		-- pressed with the cursor like any other button), so the table comes
		-- in empty and every caption goes blank while a pad is in use.
		local text = if keys then (keys[a.id] or "") else a.hotkey
		if a.key.Text ~= text then
			a.key.Text = text
		end
	end
end

-- THE PAD LEGEND (see PAD_X). `keys` are the chips in the pad's own family --
-- { attack = "A", zoomOut = "LB", zoomIn = "RB" }, or the cross / L1 / R1 --
-- and nil takes the legend away, which is what happens the moment a mouse
-- moves. Compared before written, like setActionKeys: the client calls this
-- on device change only, but a caption is a caption.
function HUD.setPadHints(self: HUD, keys: { attack: string, zoomOut: string, zoomIn: string }?)
	local h = self.padHints
	if not h then
		return
	end
	if keys then
		for name, lbl in { attack = h.attack, zoomOut = h.zoomOut, zoomIn = h.zoomIn } do
			if lbl.Text ~= keys[name] then
				lbl.Text = keys[name]
			end
		end
	end
	local on = keys ~= nil
	if h.frame.Visible ~= on then
		h.frame.Visible = on
	end
end

-- Called every frame off the render loop, so nothing is written unless the
-- FORMATTED price or the drawn state actually changed. `costs` is keyed by
-- action id; a nil entry leaves that button priceless rather than printing 0.
function HUD.setActions(self: HUD, armed: string?, costs: { [string]: number }?, gold: number?)
	if not self.actions then
		return
	end
	self.armed = armed
	local g = gold or 0
	-- ONLY THE BUTTONS THE PLAYER CAN ACTUALLY PRESS, and only in a lesson
	-- round (owner, 2026-09-03: "make city, port, and nuke buttons show up
	-- only once the player has enough to interact with them. otherwise its
	-- too confusing"). Outside the tutorial all three stay put: an ordinary
	-- player reads an unaffordable price as a goal, where a first-timer reads
	-- a button that does nothing as a broken control.
	--
	-- LATCHED. Affordability comes and goes with every purchase, and a button
	-- that vanishes the moment you spend the gold you just used on it is a
	-- worse lesson than one that was never there. Once a button has been
	-- reachable in this round it stays.
	local shown = {}
	local key = ""
	for _, a in self.actions do
		local cost = costs and costs[a.id]
		-- The DISPLAY price stays exactly as it was -- see RAIL_ACTIONS.price,
		-- which is the gate's number and never printed.
		local need = cost or a.price
		-- A FREE WARHEAD IS REACHABILITY (owner, 2026-09-12: "buying +1nuke
		-- should instantly unhide the nuke card in tutorial"). The rule above
		-- asks whether the player can PAY for the button, and "+1 Nuke!" hands
		-- over a shot rather than the 750,000 it would have cost -- so a
		-- student who had just bought one watched the card stay hidden and had
		-- no way to reach the thing they had paid for.
		--
		-- IT UNLOCKS THROUGH THE SAME LATCH rather than beside it, which is
		-- what makes "instantly" true and keeps it true: the count drops back
		-- to zero the moment the shot is fired, and a button that vanished on
		-- the press would be the exact disappearing-control problem the latch
		-- was written for.
		if need == nil or g >= need or freeFor(self, a.id) > 0 then
			a.unlockedOnce = true
		end
		-- `tutHide` OUTRANKS THE LATCH: an untaught building does not become
		-- teachable by becoming affordable, so this one never unlocks in a
		-- lesson round however rich the student gets.
		-- A TOWER IN HAND OUTRANKS `tutHide`. The rule above still holds for
		-- everyone else and for every other reason -- an untaught building does
		-- not become teachable by becoming affordable -- but Starter Pack #1 is
		-- sold INSIDE the lesson and hands over a defence tower, and a lesson
		-- that takes the money and then hides the thing bought is the one case
		-- the 2026-09-12 rule was never written against. Only a BOUGHT tower
		-- opens it, and only while it is unspent.
		-- A PASS'S CARD IS ON THE RAIL ONLY WHILE THE PASS IS HELD (2026-09-22,
		-- RAIL_ACTIONS.meganuke): `self.passes` is the attribute mirror HUD.new
		-- keeps, and a key it does not know is not held.
		local vis = not (a.tutHide and tutorialRound(self) and freeFor(self, a.id) == 0)
			and (a.unlockedOnce == true or not tutorialRound(self))
			and (a.pass == nil or self.passes[a.pass] == true)
		if vis then
			shown[#shown + 1] = a
		end
		key ..= vis and "1" or "0"
	end
	if key ~= self.railKey then
		self.railKey = key
		for _, a in self.actions do
			a.button.Visible = false
			a.glow.Visible = false
			for _, ping in a.pings do
				ping.frame.Visible = false
			end
		end
		for _, a in shown do
			a.button.Visible = true
		end
		layoutRail(self, shown)
	end
	for _, a in self.actions do
		local cost = costs and costs[a.id]
		-- A SHOT IN HAND PRINTS A COUNT, NOT A PRICE (owner, 2026-09-12: "after
		-- i buy it, say (1) in green instead of the price tag"). The figure
		-- under a rail button answers one question -- what does pressing this
		-- cost me -- and for a warhead already paid for, 750,000 is the one
		-- answer that is untrue. How many are in hand is the true one.
		local free = freeFor(self, a.id)
		-- AN INSTANT ACTION COOLING DOWN PRINTS THE SECONDS LEFT, NOT THE PRICE
		-- (reinforcements, 2026-09-21). The figure under a rail button answers
		-- "what does pressing this cost me", and while the button cannot be
		-- pressed at all the true answer is how long until it can. The client
		-- passes the ticks left beside the price, keyed `<id>Left`, off the same
		-- server quote the price came from. A cost of 0 on an instant action
		-- means there is nothing to sell -- the army is at its ceiling -- and
		-- the button says so rather than printing a free purchase.
		local left = a.instant and costs and costs[a.id .. "Left"] or 0
		local cooling = a.instant and (left > 0 or (cost ~= nil and cost <= 0))
		local str
		if free > 0 then
			str = "(" .. free .. ")"
		elseif cooling then
			str = left > 0 and (math.ceil(left / (Config.TICK_RATE or 10)) .. "s") or "FULL"
		else
			str = cost and formatCount(math.floor(cost)) or ""
		end
		if str ~= a.costStr then
			a.costStr = str
			a.cost.Text = str
		end
		-- Affordability is drawn on the PRICE, not on the whole button: a
		-- greyed-out button reads as broken, and the thing that is temporarily
		-- untrue is the number.
		-- An instant action is never the armed one -- it has no mode to be in.
		local sel = armed == a.id and not a.instant
		-- A free shot IS affordable -- at nothing -- so it must never be drawn
		-- in the cannot-pay colour on the way to being drawn green.
		local afford = free > 0 or cost == nil or g >= cost
		-- `free` JOINS THE STYLE KEY, and it has to: the colour below is only
		-- written when this string changes, so buying the first shot (or
		-- firing the last one) would otherwise repaint nothing and leave the
		-- count sitting in gold. `cooling` joins it for the same reason: the
		-- countdown is drawn MUTED, not in the cannot-pay red -- "wait" and
		-- "cannot afford" are different news and want different colours.
		local key = (sel and "S" or "-") .. (afford and "A" or "-") .. (free > 0 and "F" or "-") .. (cooling and "C" or "-")
		if key ~= a.styleKey or self.myColor ~= a.styleColor then
			a.styleKey, a.styleColor = key, self.myColor
			if sel then
				-- Armed is your own map colour, the same "this is yours" the
				-- troop bar and the selected size button use.
				a.button.BackgroundColor3 = self.myColor or INK
				a.button.BackgroundTransparency = 0
				a.name.TextColor3 = PANEL
				a.key.TextColor3 = PANEL
				-- NOT GAIN ON THE ARMED FILL. That fill is the player's own
				-- colour and always a bright one -- the same reason THREAT has
				-- to become RAIL_THREAT_INK here -- and a light green on it
				-- reads worse than the dark ink the name and key already use.
				-- A free shot is `afford`, so this lands on PANEL by itself.
				a.cost.TextColor3 = afford and PANEL or RAIL_THREAT_INK
				a.stroke.Transparency = 0
				a.stroke.Color = self.myColor or INK
			else
				a.button.BackgroundColor3 = a.hover and RAIL_HOVER or PANEL
				a.button.BackgroundTransparency = SCRIM_T
				a.name.TextColor3 = INK
				a.key.TextColor3 = INK_MUTE
				-- GAIN, the green this HUD already spends on "you gained
				-- something" -- the income line and the city punch. A count of
				-- free shots is the same news.
				a.cost.TextColor3 = free > 0 and GAIN or (cooling and INK_MUTE) or (afford and GOLD or THREAT)
				-- The "+" card keeps its gold ring (see the rail builder); the
				-- hairline is every other tile's rest state.
				a.stroke.Transparency = a.plus and 0 or 0.35
				a.stroke.Color = a.plus and GOLD or LINE
			end
		end
	end
end

-- THE CITY PUNCH (owner, 2026-09-11: "everytime i add a city, the troop count
-- should tween up rapidly and light up green and tween slightly big and
-- small ... like the army size is being upgraded"). A city level is a flat
-- +CITY_TROOP_INCREASE of ceiling, so building or upgrading one IS the army
-- being upgraded: the ARMY block flashes GAIN and bounces while "/ max"
-- counts up to its new value (the client's own smoother does the counting).
--
-- The bounce is a damped sine, exactly 1 at both ends: up to +grow, a dip a
-- quarter as deep below rest, settled. Green holds for `hold` of the life,
-- then eases out. One table, not four locals -- this file is a big chunk.
--
-- 40% SLOWER (owner, 2026-09-12: "want it to be 40% slower the effect"): 0.7
-- -> 0.98 s. `life` is the only clock in here -- the bounce, the green hold
-- and the ease off it are all read off k = t / life -- so this one number
-- stretches the whole gesture and every other figure in the table still
-- means what it says.
local ARMY_PUNCH = { life = 0.98, grow = 0.25, hold = 0.3, peak = 1 }
do
	-- The sine's own first crest, so `grow` is the true peak scale.
	local k = math.atan(3 * math.pi / 4) / (3 * math.pi)
	ARMY_PUNCH.peak = math.exp(-4 * k) * math.sin(3 * math.pi * k)
end

-- Fired by ConquestClient the moment the server accepts a city or a city
-- upgrade -- PLACEMENT, not completion (owner, 2026-09-11: "make it play when
-- i place the city down, not when it finishes building"). The client adds the
-- level to its ceiling on the same frame, so the cap counts up under the
-- punch rather than two seconds later.
function HUD.punchArmy(self: HUD)
	self.armyPunchT = 0
end

-- LAND IS OFF THIS BAR (owner, 2026-09-12: "remove the land information on the
-- right and fill the space"). It held the bar's right-hand third -- a share of
-- the map over a tile count -- and the standings board prints that same share
-- for every empire including yours, so the bar was carrying a second copy of a
-- figure already on screen, in the widest slot on the panel. `tiles` and
-- `playableLand` arrived for those two lines only and leave with them.
function HUD.setArmy(self: HUD, troops: number, maxTroops: number, incomePerSec: number)
	local frac = maxTroops > 0 and math.clamp(troops / maxTroops, 0, 1) or 0
	self.troopFill.Size = UDim2.fromScale(frac, 1)
	self.armyText.Text = formatTroops(troops)
	self.armyCap.Text = "/ " .. formatTroops(maxTroops)
	self.incomeText.Text = string.format("+%s / sec", formatTroops(incomePerSec))
end

function HUD.setGain(self: HUD, delta: number)
	if delta > 1 then
		self.gainText.Text = "+" .. formatTroops(delta) .. " taken"
		self.gainText.TextColor3 = GAIN
	elseif delta < -1 then
		-- Numbers.format clamps negatives to zero, as upstream does, so a
		-- loss must pass its MAGNITUDE and carry its own sign.
		self.gainText.Text = "-" .. formatTroops(-delta) .. " lost"
		self.gainText.TextColor3 = THREAT
	else
		self.gainText.Text = ""
	end
end

function HUD.setHover(self: HUD, info: any)
	if not info then
		self.hover.Visible = false
		self.hoverInfo = nil
		return
	end
	self.hover.Visible = true
	self.hoverInfo = info
	self.hoverName.Text = clip(info.name, 18)
	self.hoverName.TextColor3 = info.color or INK
	self.hoverTerrain.Text = string.upper(info.terrain or "")
	HUD.refreshHover(self)
end

-- The card quotes the SAME smoothed numbers the standings do, by player id,
-- rather than the raw figures off the last packet: hovering a nation and
-- reading its row must not show two different armies.
function HUD.refreshHover(self: HUD)
	local info = self.hoverInfo
	if not info then
		return
	end
	-- A card about a UNIT rather than a tile -- a gunboat under the pointer,
	-- ConquestClient.updateHover -- says what it is on the stats line and has
	-- no troops or tiles to quote. `hoverText` is overwritten on BOTH fixed
	-- lines, not only the nation one: the nation branch below skips its write
	-- when the text has not changed, so a fixed line left in the box with a
	-- stale cache would stay there under the next nation with the same figures.
	if info.stats ~= nil then
		self.hoverText = info.stats
		self.hoverStats.Text = string.upper(info.stats)
		return
	end
	if info.unclaimed then
		self.hoverText = "UNCLAIMED"
		self.hoverStats.Text = "UNCLAIMED"
		return
	end
	local id = info.id
	local troops = (id and self.troopsShown[id]) or info.troops or 0
	local tiles = (id and self.tilesShown[id]) or info.tiles or 0
	-- Troops divide by ten; TILES do not.
	local t = string.format("%s troops   ·   %s tiles", formatTroops(troops), formatCount(tiles))
	if t ~= self.hoverText then
		self.hoverText = t
		self.hoverStats.Text = t
	end
end

-- The layout is pure Scale, so a resize needs nothing done to it -- with ONE
-- exception, and it is the reason this is no longer an empty function. The
-- defeated caption pins TextSize in REAL PIXELS (see
-- DEFEAT_TITLE_PX), derived once from the viewport height, and a resize is
-- exactly the event that makes that derivation stale: without this, resizing
-- the window while knocked out leaves the words at the old window's size.
-- Re-running the whole defeated layout is the cheap and honest fix -- it is a
-- handful of property writes and it cannot drift from the real thing.
function HUD.layout(self: HUD, viewW: number, viewH: number)
	if self.defeated then
		HUD.layoutExits(self)
	end
	-- The pad legend hangs PAD_GAP under Roblox's topbar. This screen ignores
	-- the inset and the inset is a pixel count (58 here, whatever the
	-- viewport), so the corner the board's 14px would put it in is the
	-- engine's own menu button. Written as Scale against the viewport, like
	-- everything else on this HUD, so it still rides a resize.
	if self.padHints then
		local inset = GuiService:GetGuiInset().Y
		self.padHints.frame.Position = UDim2.fromScale(PAD_X / REF_W, inset / math.max(viewH, 1) + PAD_GAP / REF_H)
	end
end

-- The two bands above, in VIEWPORT px. Everything on this HUD is authored in
-- Scale against REF_H, so one factor converts. Read by ConquestClient on every
-- viewport change and handed straight to Camera2D.setInsets.
function HUD.insets(self: HUD, viewW: number, viewH: number): (number, number)
	local s = viewH / REF_H
	return TOP_BAND * s, (REF_H - BAR_Y) * s
end

function HUD.moveHover(self: HUD, x: number, y: number, viewW: number, viewH: number)
	local w, h = self.hover.AbsoluteSize.X, self.hover.AbsoluteSize.Y
	local px, py = x + 16, y + 16
	if px + w > viewW - 8 then
		px = x - w - 16
	end
	if py + h > viewH - 8 then
		py = y - h - 16
	end
	self.hover.Position = UDim2.fromScale(px / math.max(viewW, 1), py / math.max(viewH, 1))
end

-- Incoming first and in red: the one thing here you may have to act on. The
-- strip this fed is gone (see FRONTS, above) and the ranking is what is left:
-- being invaded outranks anything you are doing, at any size, and after that
-- it is the biggest army. The alert line across the top prints the top of that
-- order, so there is exactly one place the war outside your own borders is
-- reported, and it cannot disagree with itself.
function HUD.setFronts(self: HUD, outgoing: { any }, incoming: { any })
	table.clear(self.frontTarget)

	local ranked = {}
	for _, e in incoming do
		table.insert(ranked, { e = e, isIn = true })
	end
	for _, e in outgoing do
		table.insert(ranked, { e = e, isIn = false })
	end
	table.sort(ranked, function(x, y)
		if x.isIn ~= y.isIn then
			return x.isIn
		end
		return x.e.troops > y.e.troops
	end)

	local top = ranked[1]
	self.frontLead = top
		and { key = (top.isIn and "<" or ">") .. top.e.name, name = top.e.name, isIn = top.isIn }
		or nil

	-- Keyed by side and opponent, never by position: the lead changes hands the
	-- moment a bigger invasion opens, and a fixed key would count one
	-- opponent's army toward another's on the way past.
	if top then
		local key = self.frontLead.key
		self.frontTarget[key] = top.e.troops
		if self.frontShown[key] == nil then
			self.frontShown[key] = top.e.troops
		end
	end

	-- A front that has closed -- or lost the lead -- must not keep its
	-- smoothing state, or showing it again later would count up from a figure
	-- many minutes old.
	for key in self.frontShown do
		if self.frontTarget[key] == nil then
			self.frontShown[key] = nil
		end
	end

	HUD.refreshFronts(self)
end

-- Draws the alert line from the SMOOTHED figure, once a frame.
function HUD.refreshFronts(self: HUD)
	local lead = self.frontLead
	if not lead then
		HUD.setTarget(self, "PLAYER")
		return
	end
	HUD.setTarget(self, string.format(
		"%s   %s   %s",
		lead.isIn and "UNDER ATTACK" or "ADVANCING",
		clip(lead.name, 16),
		formatTroops(self.frontShown[lead.key] or 0)
	), lead.isIn and THREAT or GAIN)
end

-- stats = { [team] = { tiles, troops, alive } }, or nil for no bar at all.
--
-- `threshold` is the share of the map that ENDS THE ROUND, drawn as a line
-- across the track; nil leaves the line off. `segColor` overrides the team
-- colouring, and it is what lets a free-for-all borrow this bar for a single
-- segment -- the LEADER, in the leader's own colour. Seventy-two slivers is not
-- a bar anybody can read, and a free-for-all has exactly one number worth one:
-- how close the empire in front is to taking the map.
function HUD.setTeamBar(
	self: HUD,
	stats: { any }?,
	playableLand: number,
	myTeam: number?,
	threshold: number?,
	segColor: Color3?
)
	if tutorialRound(self) or not stats or #stats == 0 then
		self.teamPanel.Visible = false
		-- The line goes with it.
		self.winLine.Visible = false
		-- Free-for-all. Drop the smoothing state too, or the next team round
		-- would animate its segments out of the LAST team round's shares.
		table.clear(self.teamTarget)
		table.clear(self.teamShown)
		restackTop(self)
		return
	end
	self.teamPanel.Visible = true
	restackTop(self)

	local land = math.max(playableLand, 1)
	self.teamMine = myTeam
	for t, s in ipairs(stats) do
		local seg = self.teamSegs[t]
		if not seg then
			seg = Instance.new("Frame")
			seg.Name = "T" .. t
			seg.BorderSizePixel = 0
			-- NO LABEL. A segment is a colour and a length, and both are
			-- already the answer: whose side it is, and how much of the map
			-- they hold. A tag printed inside it was a third copy of the first
			-- fact. A team that is out dims to 0.6 in setTeamBar, which is the
			-- only other state this bar has to show.
			seg.Parent = self.teamTrack
			self.teamSegs[t] = seg
		end

		-- Share is a TARGET; the segment slides to it in step(). A bar that
		-- snaps five times a second reads as a stutter, and the whole point of
		-- the bar is that you watch it move.
		local share = math.clamp(s.tiles / land, 0, 1)
		self.teamTarget[t] = share
		if self.teamShown[t] == nil then
			self.teamShown[t] = share
		end
		self.teamAlive[t] = s.alive > 0
		seg.BackgroundColor3 = segColor or Palette.teamColor3(t)
		seg.BackgroundTransparency = s.alive > 0 and 0 or 0.6
	end

	-- Retiring a segment has to drop its SHOWN share as well as its target.
	-- layoutTeamBar walks teamShown and stops at the first nil, so a stale
	-- entry here would re-inflate the frame this loop just zeroed -- which is
	-- exactly what happens when a free-for-all borrows this bar for one
	-- segment after a team round has filled three.
	for t = #stats + 1, #self.teamSegs do
		self.teamSegs[t].Size = UDim2.fromScale(0, 1)
		self.teamTarget[t] = nil
		self.teamShown[t] = nil
	end

	-- Not smoothed, unlike the segments. The bar only moves in overtime, and then
	-- by a whole point every half-minute; a finish line that slides is a finish
	-- line nobody can measure themselves against.
	if threshold and threshold > 0 then
		self.winLine.Visible = true
		self.winLine.Position = UDim2.fromScale(math.clamp(threshold, 0, 1), 0)
	else
		self.winLine.Visible = false
	end

	HUD.layoutTeamBar(self)
end

-- Segments are laid end to end from the SMOOTHED shares, so the cursor has to
-- be re-run over all of them whenever any one moves.
function HUD.layoutTeamBar(self: HUD)
	local cursor = 0
	for t, seg in ipairs(self.teamSegs) do
		local share = self.teamShown[t]
		if share == nil then
			break
		end
		seg.Position = UDim2.fromScale(cursor, 0)
		seg.Size = UDim2.fromScale(share, 1)
		cursor += share
	end
end

function HUD.setStandings(self: HUD, list: { any }, myId: number)
	-- Ordered with HYSTERESIS, not by an exact sort. A dozen nations sit
	-- within a few tiles of each other for most of a round, and at five
	-- updates a second an exact sort has them swapping rows continuously -- a
	-- table that reshuffles five times a second cannot be read at all. Start
	-- from last update's order and let a nation overtake only once it is
	-- clearly ahead: an insertion sort with a margin, free on 13 rows.
	local byId = {}
	for _, e in list do
		byId[e.id] = e
	end
	local order = {}
	for _, id in self.order do
		local e = byId[id]
		if e then
			table.insert(order, e)
			byId[id] = nil
		end
	end
	-- Anyone new (or newly above the size cut) joins on their real standing.
	local fresh = {}
	for _, e in list do
		if byId[e.id] then
			table.insert(fresh, e)
		end
	end
	table.sort(fresh, function(a, b)
		return a.tiles > b.tiles
	end)
	for _, e in fresh do
		table.insert(order, e)
	end
	for i = 2, #order do
		local j = i
		while j > 1 and order[j].tiles > order[j - 1].tiles * 1.04 + 2 do
			order[j], order[j - 1] = order[j - 1], order[j]
			j -= 1
		end
	end
	table.clear(self.order)
	for i, e in order do
		self.order[i] = e.id
	end
	list = order

	-- Targets for everyone, not just the visible rows: a nation that drops off
	-- the bottom and comes back must not snap in from a stale figure.
	local live = {}
	for _, e in list do
		live[e.id] = true
		self.troopsTarget[e.id] = e.troops
		self.pctTarget[e.id] = e.landPercent or 0
		self.tilesTarget[e.id] = e.tiles
		if self.troopsShown[e.id] == nil then
			self.troopsShown[e.id] = e.troops
			self.pctShown[e.id] = e.landPercent or 0
			self.tilesShown[e.id] = e.tiles
		end
	end
	for id in self.troopsTarget do
		if not live[id] then
			self.troopsTarget[id], self.troopsShown[id] = nil, nil
			self.pctTarget[id], self.pctShown[id] = nil, nil
			self.tilesTarget[id], self.tilesShown[id] = nil, nil
		end
	end

	local myRank, myEntry
	for i, e in ipairs(list) do
		if e.id == myId then
			myRank, myEntry = i, e
			break
		end
	end

	local rowsH = self.rowsH
	local rowW = BOARD_W - 12

	local function fill(slot: number, rank: number, e: any, pinned: boolean)
		local row = self.rowPool[slot]
		if not row then
			row = Instance.new("Frame")
			row.Name = "R" .. slot
			row.BorderSizePixel = 0
			row.BackgroundTransparency = 1
			row.Size = UDim2.fromScale(1, ROW_H / rowsH)
			row.Parent = self.rows
			box(row, "Swatch", INK, rowW, ROW_H, 0, 0, 3, ROW_H)

			-- The avatar. A UIAspectRatioConstraint is not optional here: the
			-- whole board is laid out in Scale, so on any viewport that is not
			-- the 16:9 reference a "square" in scale units is a rectangle and
			-- the disc renders as an egg.
			local av = Instance.new("Frame")
			av.Name = "Avatar"
			av.BorderSizePixel = 0
			av.BackgroundColor3 = INK
			place(av, rowW, ROW_H, AVATAR_X, (ROW_H - AVATAR_D) / 2, AVATAR_D, AVATAR_D)
			av.Parent = row
			local ar = Instance.new("UIAspectRatioConstraint")
			ar.AspectRatio = 1
			ar.DominantAxis = Enum.DominantAxis.Height
			ar.Parent = av
			local avr = Instance.new("UICorner")
			avr.CornerRadius = UDim.new(1, 0)
			avr.Parent = av

			-- Inset inside the disc, so the nation's own colour survives as a
			-- ring around the headshot: the colour on the map and the face are
			-- one identity and should not be two separate things to look up.
			local pic = Instance.new("ImageLabel")
			pic.Name = "Pic"
			pic.BackgroundColor3 = TRACK
			pic.BorderSizePixel = 0
			pic.ScaleType = Enum.ScaleType.Crop
			pic.Size = UDim2.fromScale(0.84, 0.84)
			pic.Position = UDim2.fromScale(0.08, 0.08)
			-- This ScreenGui is ZIndexBehavior.Global, so a child does NOT
			-- inherit its parent's layer: anything ever drawn across a whole
			-- row -- a background image, a highlight -- covers the headshot
			-- unless the headshot outranks it by its own number. Nothing in
			-- the tree says so, only the render does, and it swallowed every
			-- face on this board once. Cost a bug once; the 4 stays.
			pic.ZIndex = 4
			pic.Parent = av
			local picr = Instance.new("UICorner")
			picr.CornerRadius = UDim.new(1, 0)
			picr.Parent = pic

			-- An AI has no face. It gets its initial on a filled disc in its
			-- own colour, which reads as a flag rather than a broken image.
			local ini = Instance.new("TextLabel")
			ini.Name = "Initial"
			ini.BackgroundTransparency = 1
			ini.FontFace = FONT_DISPLAY
			ini.TextScaled = true
			ini.TextColor3 = PANEL
			ini.Size = UDim2.fromScale(0.6, 0.6)
			ini.Position = UDim2.fromScale(0.2, 0.2)
			ini.Text = ""
			-- Dark glyph on a bright disc, so this outline is nearly invisible
			-- by design -- it exists so the disc obeys the same rule as the
			-- rest, and it thickens the letter very slightly at small sizes.
			local istroke = Instance.new("UIStroke")
			istroke.Name = "InitialStroke"
			istroke.Color = Color3.new()
			istroke.Thickness = 0.9
			istroke.Transparency = 0.5
			istroke.LineJoinMode = Enum.LineJoinMode.Round
			istroke.Parent = ini
			ini.ZIndex = 4
			ini.Parent = av

			for _, c in COLS do
				local cell = label(
					row, c[1], rowW, ROW_H,
					c[2], (ROW_H - 14) / 2, c[3], 14, INK,
					c[4] and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left
				)
				cell.TextTruncate = Enum.TextTruncate.AtEnd
			end
			-- Land share is the figure the board exists to compare, so it is
			-- the one thing in a row wearing the display face.
			local landCell = row:FindFirstChild("Land") :: TextLabel
			landCell.FontFace = FONT_DISPLAY
			self.rowPool[slot] = row
		end

		row.Visible = true
		-- The pinned row sits BELOW the split, which owns order TOP_ROWS + 1.
		row.LayoutOrder = pinned and (TOP_ROWS + 2) or slot
		local isMe = e.id == myId
		-- Only one row on the board is filled: yours. A zebra pattern over
		-- every row is texture, not information.
		row.BackgroundColor3 = PANEL_HI
		row.BackgroundTransparency = isMe and 0 or 1

		local tint = Palette.playerColor3(e.id, myId)
		local sw = row:FindFirstChild("Swatch") :: Frame
		sw.BackgroundColor3 = tint
		sw.BackgroundTransparency = e.alive and 0 or 0.6

		local av = row:FindFirstChild("Avatar") :: Frame
		local pic = av:FindFirstChild("Pic") :: ImageLabel
		local ini = av:FindFirstChild("Initial") :: TextLabel
		av.BackgroundColor3 = tint
		av.BackgroundTransparency = e.alive and 0 or 0.55
		-- A headshot for an account, a rendered crowd face for an invented
		-- faux player (negative id), nil for an NPC nation -- see Faces.
		local url = Faces.url(e.userId, 100)
		if url then
			-- rbxthumb resolves on the client with no web call of our own, so
			-- a pooled row may change owner five times a second for free. A
			-- yielding GetUserThumbnailAsync here would be a request per fill.
			if pic.Image ~= url then
				pic.Image = url
			end
			pic.Visible = true
			pic.ImageTransparency = e.alive and 0 or 0.5
			ini.Visible = false
		else
			pic.Visible = false
			ini.Visible = true
			ini.Text = string.upper(string.sub(e.name, 1, 1))
			ini.TextTransparency = e.alive and 0 or 0.5
		end

		local ink = e.alive and INK or INK_MUTE
		local function set(k: string, v: string, colour: Color3?)
			local c = row:FindFirstChild(k) :: TextLabel
			c.Text = v
			c.TextColor3 = colour or ink
		end
		set("Rank", "#" .. rank, e.alive and INK_DIM or INK_MUTE)
		-- In a team round the side a row belongs to has to be readable without
		-- cross-referencing, so the name carries the team colour.
		set("Name", clip(e.name, 14), e.team and e.alive and Palette.teamColor3(e.team) or nil)
		-- The one figure that moves every update is drawn from its SMOOTHED
		-- value and kept current by step().
		set("Land", string.format("%.1f%%", self.pctShown[e.id] or 0))
		if isMe then
			local nameCell = row:FindFirstChild("Name") :: TextLabel
			nameCell.TextColor3 = INK
		end

		-- Rows are pooled and change owner as the order shifts, so step() has
		-- to be told which player each slot is currently showing.
		local info = self.rowInfo[slot]
		if not info then
			info = {}
			self.rowInfo[slot] = info
		end
		info.id = e.id
		info.pct = row:FindFirstChild("Land")
		info.pctText = nil
	end

	local slot = 0
	for rank = 1, math.min(#list, TOP_ROWS) do
		slot += 1
		fill(slot, rank, list[rank], false)
	end
	-- The last row is the client's own, at whatever rank they hold -- but only
	-- when that rank is BELOW the podium. Printed under a podium you are
	-- already standing on, your row says nothing and spends a quarter of the
	-- board saying it. When you can see yourself the only question left is who
	-- is next, so the slot goes to the rank under the podium and the split
	-- rule disappears: four ranks in a row, no pin. The board keeps its height
	-- either way, which is the property that made the pinned row worth having.
	if myEntry and myRank and myRank > TOP_ROWS then
		slot += 1
		fill(slot, myRank, myEntry, true)
		self.split.Visible = true
	elseif #list > TOP_ROWS then
		-- Either you are on the podium already, or you are spectating / not
		-- yet spawned. Same row either way: the next rank down, unpinned.
		slot += 1
		fill(slot, TOP_ROWS + 1, list[TOP_ROWS + 1], false)
		self.split.Visible = false
	else
		self.split.Visible = false
	end
	for i = slot + 1, #self.rowPool do
		self.rowPool[i].Visible = false
		if self.rowInfo[i] then
			self.rowInfo[i].id = nil
		end
	end
end

-- Called every frame by the client. Walks every smoothed figure toward its
-- target and rewrites only the labels whose PRINTED text actually changed, so
-- a settled table costs a handful of comparisons and no property writes.
function HUD.step(self: HUD, dt: number)
	-- An armed exit forgets itself. See HUD.bindLeave.
	if self.leaveArmed and self.leaveArmed > 0 then
		self.leaveArmed -= dt
		if self.leaveArmed <= 0 then
			-- Put it back through the shared path rather than by hand, or the
			-- stroke and the two captions drift out of step with the fill.
			self.leaveArmed = 1
			HUD.disarmLeave(self)
		end
	end

	-- ------------------------------------------------------ the countdown ---
	-- See CLOCK_PUNCH_LIFE. Cubic ease-out from the peak: biggest on the frame
	-- the second lands, most of the way back within a third of the life, and
	-- settled -- size, colour and caption all written back exactly -- by the
	-- end, so a punch cut short by the next one never leaves a residue.
	local pt = self.clockPunchT
	if pt ~= nil then
		pt += dt
		local k = math.min(pt / CLOCK_PUNCH_LIFE, 1)
		local e = (1 - k) ^ 3
		local amp = self.clockPunchAmp or 0.5
		local rest = self.clockRest or INK
		local base = self.clockSize
		if k >= 1 then
			self.clockPunchT = nil
			self.clockText.Size = base
			self.clockText.TextColor3 = rest
			self.phaseText.TextColor3 = INK_OFF
		else
			self.clockPunchT = pt
			local s = 1 + CLOCK_PUNCH_GROW * amp * e
			self.clockText.Size = UDim2.fromScale(base.X.Scale * s, base.Y.Scale * s)
			self.clockText.TextColor3 = CLOCK_FLASH:Lerp(rest, 1 - e)
			if amp >= 1 then
				-- The caption joins in for the last few seconds and the flip.
				self.phaseText.TextColor3 = GOLD:Lerp(INK_OFF, 1 - e)
			end
		end
	end

	-- ------------------------------------------------------ the city punch ---
	-- See ARMY_PUNCH. Written back exactly at the end, like the clock's.
	local ap = self.armyPunchT
	if ap ~= nil then
		ap += dt
		local k = math.min(ap / ARMY_PUNCH.life, 1)
		local fill = self.myColor or INK
		if k >= 1 then
			self.armyPunchT = nil
			self.armyText.Size = self.armySize
			self.armyCap.Size = self.capSize
			self.armyText.TextColor3 = INK
			self.armyCap.TextColor3 = INK_DIM
			self.troopFill.BackgroundColor3 = fill
			-- The arrow does not fade to nothing and stay there: it leaves.
			self.armyUp.Visible = false
		else
			self.armyPunchT = ap
			local s = 1 + ARMY_PUNCH.grow * math.exp(-4 * k) * math.sin(3 * math.pi * k) / ARMY_PUNCH.peak
			local g = if k < ARMY_PUNCH.hold then 1 else (1 - (k - ARMY_PUNCH.hold) / (1 - ARMY_PUNCH.hold)) ^ 2
			local a, c = self.armySize, self.capSize
			self.armyText.Size = UDim2.fromScale(a.X.Scale * s, a.Y.Scale * s)
			self.armyCap.Size = UDim2.fromScale(c.X.Scale * s, c.Y.Scale * s)
			self.armyText.TextColor3 = INK:Lerp(GAIN, g)
			self.armyCap.TextColor3 = INK_DIM:Lerp(GAIN, g)
			self.troopFill.BackgroundColor3 = fill:Lerp(GAIN, g)
			-- THE ARROW RIDES THE SAME GREEN RAMP, so the two read as one
			-- gesture rather than as a flash with a sticker stuck on it. It
			-- stays full GAIN the whole way and only its opacity moves: the
			-- figure can lerp INK -> GAIN and back because it has a resting
			-- colour to return to, while an arrow half-way to green is just a
			-- grey arrow.
			self.armyUp.Visible = true
			for _, b in self.armyUp:GetChildren() do
				if b:IsA("Frame") then
					b.BackgroundTransparency = 1 - g
					local bs = b:FindFirstChildOfClass("UIStroke")
					if bs then
						-- Back to the outline's authored 0.25 at full green.
						bs.Transparency = 1 - 0.75 * g
					end
				end
			end
			-- HUGGING THE DIGITS. The figure is left-aligned in a fixed box,
			-- so where its last glyph lands is a function of how many glyphs
			-- there are -- "940" ends near 100 and "1.24M" near 141 -- and an
			-- arrow parked at one x would either crowd the long figure or
			-- float 40 px clear of the short one. TextBounds is in RENDERED
			-- pixels, so it is converted back into this bar's authored
			-- 560-wide frame before being added to the figure's own x. It
			-- widens under the bounce, which is right: the arrow is being
			-- pushed out by the number swelling. The ceiling is what keeps it
			-- out of the army cap's box, which starts at 176.
			local bw = self.bar.AbsoluteSize.X
			if bw > 0 then
				local digits = self.armyText.TextBounds.X * BAR_W / bw
				self.armyUp.Position =
					UDim2.fromScale(math.clamp(46 + digits + 8, 100, 158) / BAR_W, 26 / BAR_H)
			end
		end
	end

	for id, target in self.troopsTarget do
		self.troopsShown[id] = Numbers.approach(self.troopsShown[id] or target, target, dt, COUNT_RATE)
	end
	for id, target in self.pctTarget do
		self.pctShown[id] = Numbers.approach(self.pctShown[id] or target, target, dt, COUNT_RATE)
	end
	for _, info in self.rowInfo do
		if info.id then
			local p = string.format("%.1f%%", self.pctShown[info.id] or 0)
			if p ~= info.pctText then
				info.pctText = p
				info.pct.Text = p
			end
		end
	end

	local moved = false
	for t, target in self.teamTarget do
		local shown = Numbers.approach(self.teamShown[t] or target, target, dt, COUNT_RATE)
		if shown ~= self.teamShown[t] then
			moved = true
		end
		self.teamShown[t] = shown
	end
	if moved then
		HUD.layoutTeamBar(self)
	end

	for id, target in self.tilesTarget do
		self.tilesShown[id] = Numbers.approach(self.tilesShown[id] or target, target, dt, COUNT_RATE)
	end
	for key, target in self.frontTarget do
		self.frontShown[key] = Numbers.approach(self.frontShown[key] or target, target, dt, COUNT_RATE)
	end
	HUD.refreshFronts(self)
	HUD.refreshHover(self)

	-- ------------------------------------------------------- the payout ---
	if self.payout and self.payout.Visible then
		self.payHold -= dt
		if self.payHold <= -PAY_FADE then
			self.payout.Visible = false
		elseif self.payHold <= 0 then
			self.payout.GroupTransparency = math.clamp(-self.payHold / PAY_FADE, 0, 1)
		end
	end

	-- ------------------------------------------------------- the lesson ---
	if self.tutorialArm and self.actions then
		self.tutorialPulse = (self.tutorialPulse or 0) + dt
		local k = 0.5 + 0.5 * math.sin(self.tutorialPulse * TUT_PULSE_RATE)
		for _, a in self.actions do
			-- Stops the instant the button is ARMED: the pointing is done, and
			-- a halo still breathing under the armed fill would be arguing
			-- with `setActions` about what that button is currently saying.
			-- Written for EVERY button, not just the lit one, because that is
			-- what puts the halo out on the frame the player presses it.
			-- `a.button.Visible` is in here because a button can be HIDDEN now (see
			-- setActions): a halo breathing over an empty slot would be pointing at
			-- nothing. In practice the armed button is always affordable -- each
			-- card's `ready` sees to that -- so this is a guard, not a case.
			local point = a.id == self.tutorialArm and self.armed ~= a.id and a.button.Visible
			-- Stopping is a CALL now rather than `Visible = point`, because the
			-- two places that stop pointing must not disagree about what stopping
			-- means -- see unpoint. This path is the one that fires when the player
			-- ARMS the button the card is pointing at, which left a fat stroke
			-- behind on the button they had just pressed.
			if not point then
				unpoint(a)
			else
				a.glow.Visible = true
				for _, ping in a.pings do
					ping.frame.Visible = true
				end
				-- BRIGHTER AND THINNER (owner, 2026-09-03: "the green ... is not
				-- opaque enough, make it more opaque and more notasible, its also
				-- a bit too thick").
				--
				-- THE TROUGH MATTERS MORE THAN THE PEAK, which is what was
				-- actually wrong here. At 0.3 stroke / 0.8 glow the ring spent
				-- half of every cycle all but invisible, so the one thing on
				-- screen meant to catch the eye was missing exactly whenever the
				-- eye happened to arrive. It breathes between bright and
				-- brighter now, never between bright and gone.
				a.stroke.Color = TUT_POINT
				a.stroke.Transparency = 0.12 - 0.12 * k
				a.stroke.Thickness = 1 + 1.2 * k
				-- The halo sits UNDER a button whose own fill is 45% transparent
				-- (see scrim), so this green washes THROUGH the tile as well as
				-- standing off it -- which is most of why it reads as lit rather
				-- than merely outlined. The icon and both labels are opaque at
				-- ZIndex 2 and stay legible through it.
				a.glow.BackgroundTransparency = 0.45 - 0.3 * k

				-- THE PING, driven off the same clock rather than TweenService: a
				-- tween would have to be created when the arm moves and cancelled
				-- when it moves again, and a cancelled tween leaves the ring frozen
				-- at whatever size it died on. Phase is pure arithmetic, so putting
				-- the ring out is one write and there is nothing to clean up.
				--
				-- EASED OUT, 1 - (1-t)^2: it leaves the tile fast and coasts to a
				-- stop, which is the shape of something thrown off rather than
				-- inflated.
				for r, ping in a.pings do
					local phase = (self.tutorialPulse / RAIL_PING_TIME + (r - 1) / RAIL_PING_COUNT) % 1
					local grow = 1 - (1 - phase) * (1 - phase)
					ping.frame.Size = UDim2.fromScale(
						(RAIL_BTN_W + RAIL_PING * grow) / RAIL_W,
						(RAIL_BTN_H + RAIL_PING * grow) / RAIL_H
					)
					-- Fades on the SQUARE, so it is still solid through the first
					-- third of its travel; linear, it is half gone before it has even
					-- cleared the tile it is pointing at.
					ping.edge.Transparency = phase * phase
					ping.edge.Thickness = 0.5 + 2 * (1 - phase)
				end
			end
		end
	end
end

return HUD
