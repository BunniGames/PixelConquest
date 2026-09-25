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

local Config = require(script.Parent.Config)
local Palette = require(script.Parent.Palette)
local Numbers = require(script.Parent.Numbers)
local Icons = require(script.Parent.Icons)

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

local BOARD_X, BOARD_Y, BOARD_W = 14, 14, 300
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

local BAR_W, BAR_H = 560, 124
local BAR_X = (REF_W - BAR_W) / 2
local BAR_Y = REF_H - 14 - BAR_H

-- The fronts strip sits directly ABOVE the command bar, not under the
-- standings board. It is the one panel here reporting something you may have
-- to act on this second, and at the top left it was two thirds of a screen
-- away from the army readout it is talking about -- you cannot read "Redfen
-- 362 coming at you" and your own troop count in one glance. Anchored by its
-- BOTTOM edge, because its height grows with the number of open fronts and it
-- has to grow upward, away from the bar, rather than slide underneath it.
-- TWO, SIDE BY SIDE. The strip grew a row per open front and stacked them
-- upward into the map; at six fronts it was a wall of small text sitting
-- exactly where the eye goes for the army readout, and none of it was read.
-- It prints the two fronts that matter across ONE row now -- invasions
-- before advances, biggest army first -- so the panel is a FIXED height the
-- map can be composed around, and the rest of the war stays on the map,
-- where it is already drawn.
local FRONTS_GAP = 8
local FRONTS_MAX = 2
local FRONTS_H = 30
local FRONTS_PAD = 12
local FRONT_COL_W = 176
local FRONTS_W = FRONTS_PAD * 2 + FRONTS_MAX * FRONT_COL_W
local FRONTS_X = (REF_W - FRONTS_W) / 2

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
-- The three things you SPEND on, down the right-hand edge. Everything you can
-- buy in this game was on a hotkey and nothing else -- B then C / P / F, and
-- for a nuke not even that -- which is a control surface you cannot find by
-- looking at the screen. The rail is the opposite of a hidden mode: three
-- targets that name themselves and carry their own price, so "can I afford
-- this" is answered ON the thing you press. That is also why re-adding the
-- price here does not undo the owner's cut of the build-price line from the
-- command bar: the bar is a readout of what you HAVE, and a price belongs
-- next to the decision, not next to the treasury.
--
-- RIGHT EDGE, not the bar: the bar's bottom strip is the attack, which is one
-- press per second in a fight, and these are one press per minute. Putting
-- them next to each other is how a build lands on a front.
local RAIL_W, RAIL_BTN_H, RAIL_GAP = 84, 68, 8
local RAIL_CORNER = 4
local RAIL_X = REF_W - 14 - RAIL_W
-- Clear of the clock panel (14 + 44 tall) with a gap.
local RAIL_Y = 70
local RAIL_ACTIONS = {
	{ id = "city", icon = Icons.HOUSE, name = "HOUSE", key = "C" },
	{ id = "port", icon = Icons.SHIP, name = "SHIP", key = "P" },
	{ id = "nuke", icon = Icons.NUKE, name = "NUKE", key = "N" },
}
local RAIL_H = #RAIL_ACTIONS * RAIL_BTN_H + (#RAIL_ACTIONS - 1) * RAIL_GAP
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

-- =================================================================== build ==

function HUD.new(screen: ScreenGui): HUD
	local self = setmetatable({ screen = screen }, HUD)

	self.myColor = INK
	self.bannerStr = nil :: string?
	self.bannerColor = nil :: Color3?
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
	self.frontShown, self.frontTarget, self.frontRowInfo = {}, {}, {}
	self.frontIconPool = {}
	self.rowInfo = {}
	self.order = {}

	-- ============================================== top-left: standings ====
	local board = scrim(panel(screen, "Board", BOARD_X, BOARD_Y, BOARD_W, BOARD_H))

	local title = label(board, "Title", BOARD_W, BOARD_H, 12, 7, 200, 13, INK_DIM, nil, FONT_DISPLAY)
	title.Text = "STANDINGS"
	local lobby = label(board, "Lobby", BOARD_W, BOARD_H, BOARD_W - 130, 9, 118, 11, INK_DIM, Enum.TextXAlignment.Right)
	self.lobbyCode = lobby

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

	-- ==================================== bottom-centre: fronts (over bar) ==
	local fronts = panel(screen, "Fronts", FRONTS_X, BAR_Y - FRONTS_GAP - FRONTS_H, FRONTS_W, FRONTS_H)
	fronts.BackgroundTransparency = 0.1
	fronts.Visible = false
	self.fronts, self.frontPool = fronts, {}

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

	-- ================================================== top-right: clock ==
	local clock = panel(screen, "Clock", REF_W - 14 - 132, 14, 132, 44)
	self.clockText = label(clock, "Time", 132, 44, 12, 9, 108, 20, INK, Enum.TextXAlignment.Left, FONT_DISPLAY)
	self.phaseText = label(clock, "Phase", 132, 44, 12, 30, 108, 10, INK_OFF)

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

	-- The ceiling, RIGHT-aligned to the far end of the bar beneath it, so the
	-- three together read the way a health bar does: value at one end, cap at
	-- the other, fill between them explaining both. Left-aligned at a fixed x
	-- it floated in the gap after a hero number whose width changes with the
	-- figure, which is why it looked unrelated to anything.
	self.armyCap = label(bar, "Cap", BAR_W, BAR_H, 150, 36, 88, 12, INK_DIM, Enum.TextXAlignment.Right)

	-- Flat, sharp, and only as wide as the army column. The slider below is
	-- rounded, notched and knobbed. Two identical full-width bars was the
	-- single most confusing thing on this panel.
	local troopBack = box(bar, "TroopBar", TRACK, BAR_W, BAR_H, 16, 54, 222, 7)
	self.troopFill = box(troopBack, "Fill", INK, 222, 7, 0, 0, 0, 7)

	self.incomeText = label(bar, "Income", BAR_W, BAR_H, 16, 65, 108, 11, GAIN)
	self.gainText = label(bar, "Gain", BAR_W, BAR_H, 128, 65, 110, 11, GAIN, Enum.TextXAlignment.Right)

	-- --------------------------------------------------------- gold ------
	-- The treasury, and nothing else. This column used to carry a second
	-- line pricing the next city -- a caption, a swapping icon and a
	-- number that turned red when it was out of reach -- which made the
	-- economy read as the busiest thing on the bar when it is the
	-- secondary loop. One coin, one figure, the full height of the block.
	cap("CapGold", 250, 8, 90).Text = "GOLD"
	icon(bar, "IconGold", Icons.GOLD, BAR_W, BAR_H, 248, 28, 36, 36)
	self.goldText = label(bar, "Gold", BAR_W, BAR_H, 292, 33, 106, 26, GOLD, Enum.TextXAlignment.Left, FONT_DISPLAY)
	self.goldStr = nil

	-- --------------------------------------------------------- land ------
	cap("CapLand", 424, 8, 120, Enum.TextXAlignment.Right).Text = "LAND"
	self.landText = label(bar, "Land", BAR_W, BAR_H, 404, 20, 140, 30, INK, Enum.TextXAlignment.Right, FONT_DISPLAY)
	-- A percentage of nothing in particular is not a quantity. "0.1%" reads
	-- as a rounding error until the tile count underneath gives it a size.
	self.landTiles = label(bar, "LandTiles", BAR_W, BAR_H, 404, 56, 140, 11, INK_DIM, Enum.TextXAlignment.Right)

	-- ------------------------------------------------------ control ------
	-- A rule, because everything above it is the game telling you something
	-- and everything below it is you telling the game something.
	box(bar, "Rule", LINE, BAR_W, BAR_H, 16, 78, 528, 1).BackgroundTransparency = 0.55

	local capCommit = label(bar, "CapCommit", BAR_W, BAR_H, 16, 83, 224, 11, INK_OFF)
	-- Names the figure, and nothing else. It used to read "ATTACK SIZE  1 2 3"
	-- to advertise the hotkeys, but the three buttons directly under it already
	-- read 25% / 50% / 75% -- so the caption was printing a second, differently
	-- shaped list of the same three choices, right where the eye lands to find
	-- out what the row IS. The hotkeys still work and the key hint bottom-left
	-- still says so.
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
		place(b, RAIL_W, RAIL_H, 0, (RAIL_BTN_H + RAIL_GAP) * (i - 1), RAIL_W, RAIL_BTN_H)
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
		stroke.Color = LINE
		stroke.Thickness = 1
		stroke.Transparency = 0.35
		stroke.Parent = b
		b.Parent = rail

		-- ZIndex 2 on every child, explicitly. This ScreenGui is
		-- ZIndexBehavior.Global, where being a child buys you nothing -- the
		-- comparison is across the whole gui and a sibling panel drawn later
		-- at the same ZIndex would cover these.
		local img = icon(b, "Icon", a.icon, RAIL_W, RAIL_BTN_H, (RAIL_W - 30) / 2, 5, 30)
		img.ZIndex = 2
		local key = label(b, "Key", RAIL_W, RAIL_BTN_H, 6, 5, 14, 9, INK_MUTE)
		key.ZIndex = 2
		key.Text = a.key
		-- "Title", not "Name": a child called Name is shadowed by the
		-- instance's own Name property at every call site that goes looking
		-- for it, and this rail is exactly the kind of thing a later session
		-- reads back out of the tree to check.
		local nameLbl = label(b, "Title", RAIL_W, RAIL_BTN_H, 4, 39, RAIL_W - 8, 11, INK, Enum.TextXAlignment.Center)
		nameLbl.ZIndex = 2
		nameLbl.Text = a.name
		local costLbl = label(b, "Cost", RAIL_W, RAIL_BTN_H, 4, 53, RAIL_W - 8, 10, GOLD, Enum.TextXAlignment.Center)
		costLbl.ZIndex = 2

		local rec = { id = a.id, button = b, name = nameLbl, cost = costLbl, stroke = stroke, key = key, hover = false }
		self.actions[i] = rec
		-- Hover is REMEMBERED, not just painted. setActions repaints an
		-- unarmed button back to PANEL whenever its state changes, and with
		-- the cursor resting on it that silently cancels the hover until the
		-- pointer leaves and comes back.
		b.MouseEnter:Connect(function()
			rec.hover = true
			if self.armed ~= a.id then
				b.BackgroundColor3 = RAIL_HOVER
			end
		end)
		b.MouseLeave:Connect(function()
			rec.hover = false
			if self.armed ~= a.id then
				b.BackgroundColor3 = PANEL
			end
		end)
	end
	self.armed = nil :: string?

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

	-- THREE SHORT LINES IN THE BOTTOM-LEFT GUTTER, not one long one straight
	-- across the screen. The single 520px line started at x=14 and ran to x=534
	-- while the command bar starts at x=360 -- so its whole tail was printed ON
	-- TOP of the attack-size controls, and that costs legibility twice over:
	-- once for the hint, once for the buttons it crossed. The gutter left of the
	-- bar is 332px wide and empty below the standings board, so the hints live
	-- there, split three ways, at their full type size -- TextScaled was silently
	-- shrinking one 118-character string to fit and nothing said so.
	local D = "   " .. utf8.char(0xB7) .. "   "
	local hintW = BAR_X - 28
	for i, line in {
		"WASD / DRAG PAN" .. D .. "SCROLL ZOOM" .. D .. "CLICK ATTACK",
		"1-3 ATTACK SIZE" .. D .. "X RECALL",
		"C HOUSE" .. D .. "P SHIP" .. D .. "F FACTORY" .. D .. "N NUKE",
	} do
		label(screen, "Hint" .. i, REF_W, REF_H, 14, REF_H - 51 + (i - 1) * 15, hintW, 11, INK_OFF).Text = line
	end

	HUD.setArmy(self, 0, 0, 0, 1, 0)
	-- `or` default deliberately: a Config without the economy block must leave
	-- the HUD printing a wrong price, not fail to build the command bar at all.
	HUD.setGold(self, 0, Config.CITY_COST_BASE or 125000, 0)
	HUD.setRatio(self, Config.DEFAULT_ATTACK_RATIO, 0)
	return self
end

-- ================================================================ updates ==

function HUD.setLobbyCode(self: HUD, code: string)
	self.lobbyCode.Text = code
end

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

local function restackTop(self: HUD)
	local y = 14
	if self.teamPanel.Visible then
		place(self.teamPanel, REF_W, REF_H, ALERT_X, y, ALERT_W, 22)
		y += 26
	end
	place(self.alert, REF_W, REF_H, ALERT_X, y, ALERT_W, 32)
end

-- Reached once a frame through refreshFronts, so it writes only when the
-- printed line actually changes: a settled alert costs one string compare.
local function refreshAlert(self: HUD)
	local str, color = self.bannerStr, self.bannerColor
	if str == nil then
		str, color = self.targetStr, self.targetColor
	end
	if str == self.alertShown and color == self.alertShownColor then
		return
	end
	self.alertShown, self.alertShownColor = str, color
	if str == nil then
		self.alert.Visible = false
		return
	end
	self.alert.Visible = true
	self.alertText.Text = str
	self.alertText.TextColor3 = color or INK
	restackTop(self)
end

function HUD.setBanner(self: HUD, str: string?, color: Color3?)
	self.bannerStr, self.bannerColor = str, color
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

function HUD.setTimer(self: HUD, seconds: number, phase: string)
	self.clockText.Text = string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
	self.phaseText.Text = string.upper(phase)
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
function HUD.bindActions(self: HUD, fn: (string) -> ())
	if not self.actions then
		return
	end
	for _, a in self.actions do
		a.button.Activated:Connect(function()
			fn(a.id)
		end)
	end
end

function HUD.showActions(self: HUD, on: boolean)
	if self.rail then
		self.rail.Visible = on
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
	for _, a in self.actions do
		local cost = costs and costs[a.id]
		local str = cost and formatCount(math.floor(cost)) or ""
		if str ~= a.costStr then
			a.costStr = str
			a.cost.Text = str
		end
		-- Affordability is drawn on the PRICE, not on the whole button: a
		-- greyed-out button reads as broken, and the thing that is temporarily
		-- untrue is the number.
		local sel = armed == a.id
		local afford = cost == nil or g >= cost
		local key = (sel and "S" or "-") .. (afford and "A" or "-")
		if key ~= a.styleKey or self.myColor ~= a.styleColor then
			a.styleKey, a.styleColor = key, self.myColor
			if sel then
				-- Armed is your own map colour, the same "this is yours" the
				-- troop bar and the selected size button use.
				a.button.BackgroundColor3 = self.myColor or INK
				a.button.BackgroundTransparency = 0
				a.name.TextColor3 = PANEL
				a.key.TextColor3 = PANEL
				a.cost.TextColor3 = afford and PANEL or RAIL_THREAT_INK
				a.stroke.Transparency = 0
				a.stroke.Color = self.myColor or INK
			else
				a.button.BackgroundColor3 = a.hover and RAIL_HOVER or PANEL
				a.button.BackgroundTransparency = SCRIM_T
				a.name.TextColor3 = INK
				a.key.TextColor3 = INK_MUTE
				a.cost.TextColor3 = afford and GOLD or THREAT
				a.stroke.Transparency = 0.35
				a.stroke.Color = LINE
			end
		end
	end
end

function HUD.setArmy(
	self: HUD,
	troops: number,
	maxTroops: number,
	tiles: number,
	playableLand: number,
	incomePerSec: number
)
	local frac = maxTroops > 0 and math.clamp(troops / maxTroops, 0, 1) or 0
	self.troopFill.Size = UDim2.fromScale(frac, 1)
	self.armyText.Text = formatTroops(troops)
	self.armyCap.Text = "/ " .. formatTroops(maxTroops)
	self.incomeText.Text = string.format("+%s / sec", formatTroops(incomePerSec))
	self.landText.Text = string.format("%.1f%%", tiles / math.max(playableLand, 1) * 100)
	self.landTiles.Text = formatCount(tiles) .. " TILES"
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
	if info.unclaimed then
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

-- The layout is pure Scale, so a resize needs nothing done to it. Kept
-- because the client calls it on every viewport change.
function HUD.layout(self: HUD, viewW: number, viewH: number) end

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

-- Incoming first and in red: the one thing here you may have to act on.
function HUD.setFronts(self: HUD, outgoing: { any }, incoming: { any })
	table.clear(self.frontTarget)
	table.clear(self.frontRowInfo)

	-- ONE ranking, used twice. The alert line reports the front that matters
	-- most right now and the strip prints the top two of the same order, so
	-- the headline and the row underneath it can never disagree -- and being
	-- invaded outranks anything you are doing, at any size.
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

	-- The panel shrinks to one column when there is one front, rather than
	-- printing a half-empty box the width of two.
	local shown = math.min(#ranked, FRONTS_MAX)
	self.fronts.Visible = shown > 0
	local panelW = FRONTS_PAD * 2 + math.max(shown, 1) * FRONT_COL_W
	if shown > 0 then
		place(
			self.fronts, REF_W, REF_H,
			(REF_W - panelW) / 2, BAR_Y - FRONTS_GAP - FRONTS_H, panelW, FRONTS_H
		)
	end

	for slot = 1, shown do
		local entry = ranked[slot]
		local e, isIn = entry.e, entry.isIn
		local row = self.frontPool[slot]
		local mark = self.frontIconPool[slot]
		if not row then
			row = label(self.fronts, "F" .. slot, panelW, FRONTS_H, 0, 0, 10, 11)
			self.frontPool[slot] = row
		end
		if not mark then
			-- The arrow glyph this replaces said the same thing, and read as
			-- punctuation. A shield and a sword are the same two words the
			-- map pops when the war opens, so the list and the map agree.
			mark = icon(self.fronts, "FI" .. slot, Icons.SWORD, panelW, FRONTS_H, 0, 0, 13)
			self.frontIconPool[slot] = mark
		end
		row.Visible = true
		mark.Visible = true
		mark.Image = if isIn then Icons.SHIELD else Icons.SWORD
		-- Re-placed every call: the panel's WIDTH changes with the number of
		-- fronts shown, and Scale is read against it.
		local colX = FRONTS_PAD + (slot - 1) * FRONT_COL_W
		place(mark, panelW, FRONTS_H, colX, (FRONTS_H - 13) / 2, 13, 13)
		place(row, panelW, FRONTS_H, colX + 18, (FRONTS_H - 11) / 2, FRONT_COL_W - 26, 11)
		row.TextColor3 = isIn and THREAT or INK_DIM

		-- Keyed by side and opponent, not by slot: the two shown re-order as
		-- fronts open and close, and a per-slot tween would slide one
		-- opponent's army toward another's.
		local key = (isIn and "<" or ">") .. e.name
		self.frontTarget[key] = e.troops
		if self.frontShown[key] == nil then
			self.frontShown[key] = e.troops
		end
		self.frontRowInfo[slot] = { row = row, key = key, name = e.name, isIn = isIn }
	end
	for i = shown + 1, #self.frontPool do
		self.frontPool[i].Visible = false
		local m = self.frontIconPool[i]
		if m then
			m.Visible = false
		end
	end

	-- A front that has closed -- or dropped off the top two -- must not keep
	-- its smoothing state, or showing it again later would count up from a
	-- figure many minutes old.
	for key in self.frontShown do
		if self.frontTarget[key] == nil then
			self.frontShown[key] = nil
		end
	end

	HUD.refreshFronts(self)
end

-- Draws the fronts list and the alert line from the SMOOTHED figures.
function HUD.refreshFronts(self: HUD)
	for _, info in self.frontRowInfo do
		local t = string.format(
			"%s  %s",
			clip(info.name, 14),
			formatTroops(self.frontShown[info.key] or 0)
		)
		if t ~= info.text then
			info.text = t
			info.row.Text = t
		end
	end

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

-- stats = { [team] = { tiles, troops, alive } }, or nil in a free-for-all --
-- which is also how the bar knows to hide itself.
function HUD.setTeamBar(self: HUD, stats: { any }?, playableLand: number, myTeam: number?)
	if not stats or #stats == 0 then
		self.teamPanel.Visible = false
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
		seg.BackgroundColor3 = Palette.teamColor3(t)
		seg.BackgroundTransparency = s.alive > 0 and 0 or 0.6
	end

	for t = #stats + 1, #self.teamSegs do
		self.teamSegs[t].Size = UDim2.fromScale(0, 1)
		self.teamTarget[t] = nil
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
		if e.userId and e.userId > 0 then
			-- rbxthumb resolves on the client with no web call of our own, so
			-- a pooled row may change owner five times a second for free. A
			-- yielding GetUserThumbnailAsync here would be a request per fill.
			local url = "rbxthumb://type=AvatarHeadShot&id=" .. e.userId .. "&w=100&h=100"
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
end

return HUD
