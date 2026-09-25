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

-- Two faces, on purpose. The blocky arcade face is the game's voice and is
-- kept for the few display numbers; it is genuinely hard to read at 11-13px,
-- which is most of a HUD, so tabular and label text uses a UI face instead.
local FONT_DISPLAY = Font.fromEnum(Enum.Font.Arcade)
local FONT_UI = Font.fromEnum(Enum.Font.GothamMedium)

-- Neutrals carry all the structure; every one of these clears 4.5:1 on PANEL
-- except INK_OFF, which is only ever used for text that is genuinely inactive.
local INK = Color3.fromRGB(234, 240, 250)
local INK_DIM = Color3.fromRGB(156, 170, 194)
local INK_OFF = Color3.fromRGB(110, 122, 148)
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
	-- Slightly translucent: the map is the game, and a HUD that blacks out
	-- part of it costs more than the contrast it buys.
	f.BackgroundTransparency = 0.12
	f.BorderSizePixel = 0
	f.Active = true
	place(f, REF_W, REF_H, x, y, w, h)
	f.Parent = parent
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

local BOARD_X, BOARD_Y, BOARD_W = 14, 14, 286
-- FOUR ROWS, ALWAYS: the podium and you. At a 72-empire roster a full ladder
-- is not something anyone reads -- the only rows acted on are the leaders'
-- and the reader's own -- so the board shows the top three, a rule, and the
-- client's own row at its real rank. Rows are tall enough to carry a headshot,
-- which is what turns a name on this board into a PERSON rather than a string.
local ROW_H, ROW_GAP, TOP_ROWS = 32, 3, 3
local ROW_SPLIT = 9
-- 8 pad + 12 title + 8 gap + 10 column header + 9 rule and gap.
local BOARD_HEAD = 47
local BOARD_H = BOARD_HEAD + (TOP_ROWS + 1) * (ROW_H + ROW_GAP) + ROW_SPLIT + 8

local ALERT_W = 520
local ALERT_X = (REF_W - ALERT_W) / 2

local BAR_W, BAR_H = 560, 124
local BAR_X = (REF_W - BAR_W) / 2
local BAR_Y = REF_H - 14 - BAR_H

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
	{ "Rank", 4, 26, false },
	{ "Name", 68, 114, false },
	{ "Land", 186, 84, true },
}
local AVATAR_X, AVATAR_D = 34, 26

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
	self.rowInfo = {}
	self.order = {}

	-- ============================================== top-left: standings ====
	local board = panel(screen, "Board", BOARD_X, BOARD_Y, BOARD_W, BOARD_H)

	local title = label(board, "Title", BOARD_W, BOARD_H, 10, 8, 120, 11, INK_OFF)
	title.Text = "STANDINGS"
	local lobby = label(board, "Lobby", BOARD_W, BOARD_H, 156, 8, 120, 11, INK_OFF, Enum.TextXAlignment.Right)
	self.lobbyCode = lobby

	local headerY = 8 + 12 + 8
	for _, c in COLS do
		local h = label(
			board, "H" .. c[1], BOARD_W, BOARD_H,
			c[2] + ROW_INSET, headerY, c[3], 10, INK_OFF,
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

	-- ===================================== top-left: fronts (under board) ==
	local fronts = panel(screen, "Fronts", BOARD_X, BOARD_Y + BOARD_H + 8, BOARD_W, 30)
	fronts.BackgroundTransparency = 0.3
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
	local bar = panel(screen, "Bar", BAR_X, BAR_Y, BAR_W, BAR_H)

	-- The word ARMY, replaced by the thing itself. The sword means fighting
	-- power everywhere else on this screen, so the one place the figure is
	-- largest is the last place it needs spelling out.
	icon(bar, "IconArmy", Icons.SWORD, BAR_W, BAR_H, 14, 1, 24, 24)
	local capLand = label(bar, "CapLand", BAR_W, BAR_H, 424, 10, 120, 11, INK_OFF, Enum.TextXAlignment.Right)
	capLand.Text = "LAND"

	-- The hero. Everything else on screen is smaller than this on purpose.
	self.armyText = label(bar, "Army", BAR_W, BAR_H, 16, 26, 168, 34, INK, Enum.TextXAlignment.Left, FONT_DISPLAY)
	self.armyCap = label(bar, "Cap", BAR_W, BAR_H, 192, 28, 120, 12, INK_DIM)
	self.incomeText = label(bar, "Income", BAR_W, BAR_H, 192, 44, 120, 12, GAIN)
	self.gainText = label(bar, "Gain", BAR_W, BAR_H, 192, 60, 120, 12, GAIN)

	self.landText = label(bar, "Land", BAR_W, BAR_H, 360, 26, 184, 28, INK, Enum.TextXAlignment.Right, FONT_DISPLAY)

	-- Gold, tucked into the gap between LAND and the troop bar at y 78. Half
	-- the type size of LAND on purpose: the economy is a secondary loop, and
	-- the moment it competes with the army for the eye it has been given more
	-- weight than the game gives it.
	icon(bar, "IconGold", Icons.GOLD, BAR_W, BAR_H, 330, 53, 22, 22)
	self.goldText = label(bar, "Gold", BAR_W, BAR_H, 356, 57, 96, 14, GOLD, Enum.TextXAlignment.Left, FONT_DISPLAY)
	self.goldCost = label(bar, "GoldCost", BAR_W, BAR_H, 474, 60, 70, 10, INK_DIM, Enum.TextXAlignment.Right)
	-- What the price is FOR. The word (CITY / PORT) used to lead the cost
	-- string; the icon says it in the same strip and swaps with the build
	-- mode, so the line reads as a price tag instead of a sentence.
	self.goldKind = icon(bar, "IconBuild", Icons.HOUSE, BAR_W, BAR_H, 452, 53, 19, 19)
	self.goldKindImg = Icons.HOUSE
	self.goldStr, self.goldCostStr, self.goldAfford = nil, nil, nil

	local troopBack = box(bar, "TroopBar", TRACK, BAR_W, BAR_H, 16, 78, 528, 6)
	self.troopFill = box(troopBack, "Fill", INK, 528, 6, 0, 0, 0, 6)

	local capCommit = label(bar, "CapCommit", BAR_W, BAR_H, 16, 92, 140, 11, INK_OFF)
	capCommit.Text = "COMMIT"
	self.commitText = label(bar, "Commit", BAR_W, BAR_H, 340, 91, 204, 12, INK, Enum.TextXAlignment.Right)

	local track = box(bar, "Track", TRACK, BAR_W, BAR_H, 16, 106, 528, 12)
	track.Active = true
	self.track = track
	self.ratioFill = box(track, "Fill", INK, 528, 12, 0, 0, 528 * Config.DEFAULT_ATTACK_RATIO, 12)
	self.ratioKnob = box(track, "Knob", INK, 528, 12, 528 * Config.DEFAULT_ATTACK_RATIO - 3, -3, 6, 18)
	self.ratioKnob.ZIndex = 3

	self.bar = bar

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

	local hint = label(screen, "Hint", REF_W, REF_H, 14, REF_H - 20, 520, 10, INK_OFF)
	hint.Text = "DRAG PAN   ·   SCROLL ZOOM   ·   CLICK ATTACK   ·   1-9 COMMIT   ·   X RECALL   ·   B BUILD (C CITY / P PORT)"

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
	self.ratioFill.BackgroundColor3 = color
end

-- The treasury, and what the next city costs out of it. ONE line, under LAND,
-- because that is the whole economy: an income you cannot change and a single
-- thing to spend it on.
--
-- Design note 3 above bans gold-the-colour, and it applied for as long as
-- there was no gold-the-resource -- the objection was that it meant currency,
-- "your row" and the commit slider at once. It now means currency and nothing
-- else, which is the rule being satisfied rather than broken.
--
-- The cost half turns THREAT-red while it is out of reach, so the answer to
-- "can I build" is a colour rather than a subtraction.
function HUD.setGold(self: HUD, amount: number?, cityCost: number?, cities: number?, label: string?)
	if amount == nil then
		self.goldText.Text = ""
		self.goldCost.Text = ""
		self.goldKind.Visible = false
		return
	end
	local gold = math.floor(amount)
	local str = formatCount(gold)
	if str ~= self.goldStr then
		self.goldStr = str
		self.goldText.Text = str
	end

	local cost = cityCost or 0
	local costStr = cost > 0
		and (formatCount(cost) .. ((cities or 0) > 0 and ("  x" .. cities) or ""))
		or ""
	-- The kind used to be the first word of that string.
	local kindImg = if label == "PORT" then Icons.SHIP else Icons.HOUSE
	if kindImg ~= self.goldKindImg then
		self.goldKindImg = kindImg
		self.goldKind.Image = kindImg
	end
	self.goldKind.Visible = cost > 0
	if costStr ~= self.goldCostStr then
		self.goldCostStr = costStr
		self.goldCost.Text = costStr
	end
	local afford = cost > 0 and gold >= cost
	if afford ~= self.goldAfford then
		self.goldAfford = afford
		self.goldCost.TextColor3 = afford and INK_DIM or THREAT
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

function HUD.setRatio(self: HUD, ratio: number, troops: number?)
	self.ratioFill.Size = UDim2.fromScale(ratio, 1)
	self.ratioKnob.Position = UDim2.fromScale(ratio - 3 / 528, -3 / 12)
	self.commitText.Text = string.format(
		"%d%%   ·   %s TROOPS",
		math.floor(ratio * 100 + 0.5),
		formatTroops((troops or 0) * ratio)
	)
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

	-- The alert line reports the front that matters most right now, and being
	-- invaded outranks anything you are doing. Chosen HERE rather than in the
	-- client, so the figure it quotes is the same smoothed one the list
	-- underneath shows -- computed separately the two could disagree by an
	-- update.
	self.frontLead = nil
	local function lead(list, isIn)
		local best = list[1]
		for _, e in list do
			if e.troops > best.troops then
				best = e
			end
		end
		self.frontLead = { key = (isIn and "<" or ">") .. best.name, name = best.name, isIn = isIn }
	end
	if #incoming > 0 then
		lead(incoming, true)
	elseif #outgoing > 0 then
		lead(outgoing, false)
	end

	local total = #outgoing + #incoming
	self.fronts.Visible = total > 0
	local h = 8 + math.max(total, 1) * 16 + 6
	if total > 0 then
		place(self.fronts, REF_W, REF_H, BOARD_X, BOARD_Y + BOARD_H + 8, BOARD_W, h)
	end

	local index = 0
	local function emit(e: any, isIn: boolean)
		index += 1
		local row = self.frontPool[index]
		if not row then
			row = label(self.fronts, "F" .. index, BOARD_W, h, 12, 0, BOARD_W - 24, 11)
			self.frontPool[index] = row
		end
		row.Visible = true
		-- Re-placed every call: the panel's height changes with the number of
		-- fronts, and Scale is read against it.
		place(row, BOARD_W, h, 12, 8 + (index - 1) * 16 + 2, BOARD_W - 24, 11)
		row.TextColor3 = isIn and THREAT or INK_DIM

		-- Keyed by side and opponent, not by row: the rows re-order as fronts
		-- open and close, and a per-row tween would slide one opponent's army
		-- toward another's.
		local key = (isIn and "<" or ">") .. e.name
		self.frontTarget[key] = e.troops
		if self.frontShown[key] == nil then
			self.frontShown[key] = e.troops
		end
		self.frontRowInfo[index] = { row = row, key = key, name = e.name, isIn = isIn }
	end
	for _, e in incoming do
		emit(e, true)
	end
	for _, e in outgoing do
		emit(e, false)
	end
	for i = index + 1, #self.frontPool do
		self.frontPool[i].Visible = false
	end

	-- A front that has closed must not keep its smoothing state, or reopening
	-- it later would count up from a figure many minutes old.
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
			"%s  %s  %s",
			info.isIn and "◀" or "▶",
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
			seg.Parent = self.teamTrack
			local lbl = Instance.new("TextLabel")
			lbl.Name = "V"
			lbl.BackgroundTransparency = 1
			lbl.FontFace = FONT_UI
			lbl.TextScaled = true
			lbl.Size = UDim2.fromScale(1, 0.75)
			lbl.Position = UDim2.fromScale(0, 0.125)
			lbl.TextXAlignment = Enum.TextXAlignment.Center
			lbl.ZIndex = 2
			local c = Instance.new("UITextSizeConstraint")
			c.MaxTextSize = 40
			c.MinTextSize = 6
			c.Parent = lbl
			lbl.Parent = seg
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

		-- Dark ink on the flat team fill, the same rule the map uses: the
		-- label has to stay readable on all three hues.
		local lbl = seg:FindFirstChild("V") :: TextLabel
		lbl.TextColor3 = Color3.fromRGB(14, 18, 28)
		if share < 0.07 then
			lbl.Text = ""
		elseif not self.teamAlive[t] then
			lbl.Text = Palette.teamTag(t) .. " OUT"
		else
			lbl.Text = string.format(
				"%s%s %d%%",
				t == self.teamMine and "▸ " or "",
				Palette.teamTag(t),
				math.floor(share * 100 + 0.5)
			)
		end
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
			ini.Parent = av

			for _, c in COLS do
				local cell = label(
					row, c[1], rowW, ROW_H,
					c[2], (ROW_H - 13) / 2, c[3], 13, INK,
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

		local ink = e.alive and INK or INK_OFF
		local function set(k: string, v: string, colour: Color3?)
			local c = row:FindFirstChild(k) :: TextLabel
			c.Text = v
			c.TextColor3 = colour or ink
		end
		set("Rank", "#" .. rank, e.alive and INK_DIM or INK_OFF)
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
	-- The last row is ALWAYS the client's own, at whatever rank they hold --
	-- including when that rank is already on the podium above. A board whose
	-- final row moves depending on how well you are doing is a board you have
	-- to search; this one answers "where am I" in the same place every time.
	if myEntry and myRank then
		slot += 1
		fill(slot, myRank, myEntry, true)
	elseif #list > TOP_ROWS then
		-- Spectating, or not yet spawned: show the next rank down rather than
		-- leave the slot empty and the panel visibly short.
		slot += 1
		fill(slot, TOP_ROWS + 1, list[TOP_ROWS + 1], true)
	end
	self.split.Visible = slot > TOP_ROWS
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
