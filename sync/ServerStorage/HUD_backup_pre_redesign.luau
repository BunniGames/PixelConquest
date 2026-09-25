--!strict
-- Conquest :: HUD  (client only)
--
-- Layout mirrors the genre-standard territory-game HUD:
--   top-left     standings table (toolbar + 7 columns + pinned own row)
--   top-centre   player status: gold, name, worker/troop split, structures
--   top-right    clock and window controls
--   bottom-centre control bar: income, troop bar, gold, commit slider, builds
--
-- Styling matches the map: square corners, hard 2px strokes, flat fills,
-- blocky fonts. Anything soft fights the dithered pixel terrain.
--
-- HONESTY NOTE: gold, structures and units are not implemented in the
-- simulation yet, so those readouts render as "-" or 0 and their buttons are
-- dimmed. They are laid out for real so the systems can be wired straight in,
-- but nothing here invents a number the sim does not have.

local Config = require(script.Parent.Config)
local Palette = require(script.Parent.Palette)

local HUD = {}
HUD.__index = HUD

export type HUD = typeof(setmetatable({} :: any, HUD))

local FONT_PIXEL = Font.fromEnum(Enum.Font.Arcade)
local FONT_MONO = Font.fromEnum(Enum.Font.Code)

local INK = Color3.fromRGB(236, 242, 250)
local INK_DIM = Color3.fromRGB(138, 154, 182)
local INK_OFF = Color3.fromRGB(88, 98, 120)
local PANEL = Color3.fromRGB(21, 27, 43)
local PANEL_HI = Color3.fromRGB(33, 42, 64)
local ROW_A = Color3.fromRGB(24, 31, 49)
local ROW_B = Color3.fromRGB(29, 38, 58)
local EDGE = Color3.fromRGB(74, 94, 132)
local GREEN = Color3.fromRGB(120, 214, 130)
local GOLD = Color3.fromRGB(244, 204, 92)
local RED = Color3.fromRGB(234, 94, 86)
local BLUE = Color3.fromRGB(86, 150, 236)
local ORANGE = Color3.fromRGB(238, 150, 76)

-- ------------------------------------------------------------- primitives --

local function stroke(inst: GuiObject, color: Color3, thick: number?)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thick or 2
	s.Transparency = 0.15
	s.Parent = inst
	return s
end

local function panel(parent: Instance, name: string): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = PANEL
	f.BackgroundTransparency = 0.05
	f.BorderSizePixel = 0
	f.Active = true
	f.Parent = parent
	stroke(f, EDGE)
	return f
end

local function text(parent: Instance, name: string, size: number, pixel: boolean?): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.FontFace = (pixel ~= false) and FONT_PIXEL or FONT_MONO
	t.TextSize = size
	t.TextColor3 = INK
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.RichText = true
	t.Parent = parent
	return t
end

-- Small bordered readout: [ label ] in an accent colour.
local function chip(parent: Instance, name: string, color: Color3, w: number, h: number): TextLabel
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = Color3.fromRGB(13, 18, 30)
	f.BorderSizePixel = 0
	f.Size = UDim2.fromOffset(w, h)
	f.Parent = parent
	stroke(f, color)
	local t = text(f, "V", 15)
	t.Size = UDim2.new(1, -6, 1, 0)
	t.Position = UDim2.fromOffset(3, 0)
	t.TextXAlignment = Enum.TextXAlignment.Center
	t.TextColor3 = color
	return t
end

-- Square icon button. `glyph` is short text, not an image, so nothing depends
-- on an asset that might not load.
local function iconButton(parent: Instance, name: string, glyph: string, size: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = UDim2.fromOffset(size, size)
	b.BackgroundColor3 = PANEL_HI
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.FontFace = FONT_PIXEL
	b.TextSize = math.floor(size * 0.55)
	b.TextColor3 = INK_DIM
	b.Text = glyph
	b.Parent = parent
	stroke(b, EDGE, 1)
	return b
end

-- The one formatter, shared with the map labels through Conquest.Numbers.
-- This used to be a second, DIFFERENT implementation: the same 5,432 troops
-- printed "5.4K" here and "5.43K" on the nation's own territory, which is
-- exactly the comparison a player makes.
local Numbers = require(script.Parent.Numbers)
local formatCount = Numbers.format

-- Figures arrive five times a second. Nothing is written straight to a
-- label; step() walks each one to its new value at this rate.
local COUNT_RATE = 9

HUD.formatCount = formatCount

-- The buildable roster, in hotkey order. `have` is wired to real counts once
-- the unit systems exist; until then every entry reports 0 and stays dimmed.
-- Buildable roster. Deliberately TWO entries: the other seven were UI with
-- no simulation behind them, which made the game read as far more complex
-- than it is. Add a row here only when the mechanic actually exists.
local BUILDS = {
	{ key = "1", tag = "CITY" },
	{ key = "2", tag = "SHIP" },
}

local STRUCTS = { "CITY", "SHIP" }

local ROW_H = 22
local TOP_ROWS = 6
local BOARD_W = 336

-- =================================================================== build ==

function HUD.new(screen: ScreenGui): HUD
	local self = setmetatable({ screen = screen }, HUD)

	-- Smoothing state for every figure this HUD draws, keyed by PLAYER (or
	-- team) rather than by label, because the rows are pooled and a row can
	-- change owner between updates -- tweening per label would slide one
	-- nation's number toward another's.
	self.troopsShown, self.troopsTarget = {}, {}
	self.pctShown, self.pctTarget = {}, {}
	self.teamShown, self.teamTarget, self.teamAlive = {}, {}, {}
	self.tilesShown, self.tilesTarget = {}, {}
	self.frontShown, self.frontTarget, self.frontRowInfo = {}, {}, {}
	self.rowInfo = {}
	self.order = {}

	-- The layout is authored at 1440x900 in fixed pixels. On anything
	-- narrower the centred status bar collides with the left-hand board, so
	-- the whole HUD scales down instead of overlapping.
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = screen
	self.uiScale = uiScale

	-- =========================================== top-left: standings table ==
	local board = panel(screen, "Board")
	board.Size = UDim2.fromOffset(BOARD_W, 8 + 26 + 24 + (TOP_ROWS + 1) * ROW_H + 8)
	board.Position = UDim2.fromOffset(12, 12)

	-- toolbar: two toggles on the left, lobby code on the right
	local btnStats = iconButton(board, "Stats", "|||", 22)
	btnStats.Position = UDim2.fromOffset(6, 6)
	local btnPlayers = iconButton(board, "Players", "oo", 22)
	btnPlayers.Position = UDim2.fromOffset(32, 6)
	self.btnStats, self.btnPlayers = btnStats, btnPlayers

	local lobbyCode = text(board, "Lobby", 12)
	lobbyCode.Size = UDim2.fromOffset(220, 22)
	lobbyCode.Position = UDim2.fromOffset(BOARD_W - 228, 6)
	lobbyCode.TextXAlignment = Enum.TextXAlignment.Right
	lobbyCode.TextColor3 = INK_OFF
	self.lobbyCode = lobbyCode

	-- header
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundColor3 = PANEL_HI
	header.BorderSizePixel = 0
	header.Size = UDim2.new(1, -12, 0, 24)
	header.Position = UDim2.fromOffset(6, 32)
	header.Parent = board

	-- { key, x, width, rightAligned }
	-- { key, x, width, rightAligned }. Widths must fit formatCount output
	-- ("606.2K" needs ~54px at 13pt) or the numbers silently truncate.
	local COLS = {
		{ "#", 4, 20, false },
		{ "TAG", 26, 42, false },
		{ "NAME", 70, 92, false },
		{ "PCT", 164, 44, true },
		{ "GOLD", 210, 50, true },
		{ "ARMY", 262, 56, true },
	}
	for _, c in COLS do
		local h = text(header, c[1], 12)
		h.Size = UDim2.fromOffset(c[3], 24)
		h.Position = UDim2.fromOffset(c[2], 0)
		h.TextColor3 = INK_DIM
		h.Text = c[1] == "PCT" and "LAND" or c[1] -- headers, not instance names
		h.TextXAlignment = c[4] and Enum.TextXAlignment.Right or Enum.TextXAlignment.Left
	end
	local gear = iconButton(header, "Gear", "*", 18)
	gear.Position = UDim2.fromOffset(BOARD_W - 36, 3)
	self.boardGear = gear

	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.BackgroundTransparency = 1
	rows.Size = UDim2.new(1, -12, 1, -62)
	rows.Position = UDim2.fromOffset(6, 58)
	rows.Parent = board
	local lay = Instance.new("UIListLayout")
	lay.Padding = UDim.new(0, 1)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = rows

	self.board, self.rows, self.cols, self.rowPool = board, rows, COLS, {}

	-- ======================================== top-centre: player status bar ==
	local status = panel(screen, "Status")
	status.Size = UDim2.fromOffset(680, 96)
	status.Position = UDim2.new(0.5, -340, 0, 8)

	self.statusGold = chip(status, "Gold", GOLD, 104, 26)
	;(self.statusGold.Parent :: Frame).Position = UDim2.fromOffset(8, 8)

	local delta = text(status, "Delta", 13)
	delta.Size = UDim2.fromOffset(70, 26)
	delta.Position = UDim2.fromOffset(120, 8)
	delta.TextXAlignment = Enum.TextXAlignment.Center
	delta.TextColor3 = INK_DIM
	self.statusDelta = delta

	local pname = text(status, "Name", 22)
	pname.Size = UDim2.fromOffset(360, 26)
	pname.Position = UDim2.fromOffset(196, 6)
	pname.TextColor3 = GREEN
	self.statusName = pname

	local prole = text(status, "Role", 12)
	prole.Size = UDim2.fromOffset(110, 26)
	prole.Position = UDim2.fromOffset(BOARD_W + 220, 8)
	prole.TextColor3 = INK_OFF
	prole.Text = "PLAYER"
	self.statusRole = prole

	-- split bar: left half workers, right half troops
	local split = Instance.new("Frame")
	split.Name = "Split"
	split.BackgroundColor3 = Color3.fromRGB(13, 18, 30)
	split.BorderSizePixel = 0
	split.Size = UDim2.fromOffset(220, 26)
	split.Position = UDim2.fromOffset(8, 40)
	split.Parent = status
	stroke(split, BLUE)
	local splitFill = Instance.new("Frame")
	splitFill.Name = "Fill"
	splitFill.BackgroundColor3 = BLUE
	splitFill.BorderSizePixel = 0
	splitFill.Size = UDim2.fromScale(0.5, 1)
	splitFill.Parent = split
	self.splitFill = splitFill
	local splitL = text(split, "L", 14)
	splitL.Size = UDim2.new(0.5, -8, 1, 0)
	splitL.Position = UDim2.fromOffset(6, 0)
	splitL.ZIndex = 2
	self.splitLeft = splitL
	local splitR = text(split, "R", 14)
	splitR.Size = UDim2.new(0.5, -8, 1, 0)
	splitR.Position = UDim2.new(0.5, 2, 0, 0)
	splitR.TextXAlignment = Enum.TextXAlignment.Right
	splitR.ZIndex = 2
	self.splitRight = splitR

	-- structure counters
	self.structLabels = {}
	for i, tag in STRUCTS do
		local t = chip(status, "S" .. tag, INK_DIM, 74, 24)
		;(t.Parent :: Frame).Position = UDim2.fromOffset(238 + (i - 1) * 78, 41)
		t.Text = tag .. " 0"
		t.TextSize = 13
		self.structLabels[tag] = t
	end

	self.status = status

	-- =========================================== top-centre: team share bar ==
	-- Team modes only. One segmented bar answers "which bloc is winning" at a
	-- glance, which seven rows of a per-player table do not: in a team round
	-- the individual standings are the wrong unit of account entirely.
	local teamPanel = panel(screen, "Teams")
	teamPanel.Size = UDim2.fromOffset(680, 32)
	teamPanel.Position = UDim2.new(0.5, -340, 0, 108)
	teamPanel.Visible = false
	local teamTrack = Instance.new("Frame")
	teamTrack.Name = "Track"
	teamTrack.BackgroundColor3 = Color3.fromRGB(13, 18, 30)
	teamTrack.BorderSizePixel = 0
	teamTrack.Size = UDim2.new(1, -12, 0, 22)
	teamTrack.Position = UDim2.fromOffset(6, 5)
	teamTrack.ClipsDescendants = true
	teamTrack.Parent = teamPanel
	self.teamPanel, self.teamTrack, self.teamSegs = teamPanel, teamTrack, {}

	-- ================================================ top-right: clock etc ==
	local clock = panel(screen, "Clock")
	clock.Size = UDim2.fromOffset(196, 40)
	clock.Position = UDim2.new(1, -208, 0, 8)

	local clockText = text(clock, "Time", 20)
	clockText.Size = UDim2.fromOffset(80, 40)
	clockText.Position = UDim2.fromOffset(10, 0)
	self.clockText = clockText

	local bSettings = iconButton(clock, "Settings", "*", 26)
	bSettings.Position = UDim2.fromOffset(98, 7)
	local bExpand = iconButton(clock, "Expand", "[]", 26)
	bExpand.Position = UDim2.fromOffset(128, 7)
	local bExit = iconButton(clock, "Exit", "->", 26)
	bExit.Position = UDim2.fromOffset(158, 7)
	self.btnSettings, self.btnExpand, self.btnExit = bSettings, bExpand, bExit

	local phaseText = text(clock, "Phase", 11)
	phaseText.Size = UDim2.fromOffset(80, 14)
	phaseText.Position = UDim2.fromOffset(10, 24)
	phaseText.TextColor3 = INK_OFF
	self.phaseText = phaseText

	-- =============================================== bottom: control bar ====
	local bar = panel(screen, "Bar")
	bar.Size = UDim2.fromOffset(700, 122)
	bar.Position = UDim2.new(0.5, -350, 1, -134)

	self.incomeText = chip(bar, "Income", ORANGE, 124, 30)
	;(self.incomeText.Parent :: Frame).Position = UDim2.fromOffset(8, 10)

	local troopBack = Instance.new("Frame")
	troopBack.Name = "TroopBar"
	troopBack.BackgroundColor3 = Color3.fromRGB(13, 18, 30)
	troopBack.BorderSizePixel = 0
	troopBack.Size = UDim2.fromOffset(410, 30)
	troopBack.Position = UDim2.fromOffset(140, 10)
	troopBack.Parent = bar
	stroke(troopBack, EDGE)
	local troopFill = Instance.new("Frame")
	troopFill.Name = "Fill"
	troopFill.BackgroundColor3 = BLUE
	troopFill.BorderSizePixel = 0
	troopFill.Size = UDim2.fromScale(0, 1)
	troopFill.Parent = troopBack
	self.troopFill = troopFill
	local troopText = text(troopBack, "T", 17)
	troopText.Size = UDim2.fromScale(1, 1)
	troopText.TextXAlignment = Enum.TextXAlignment.Center
	troopText.ZIndex = 2
	self.troopText = troopText

	-- floating "+N" gain, above the right end of the bar
	local gain = text(bar, "Gain", 13)
	gain.Size = UDim2.fromOffset(120, 16)
	gain.Position = UDim2.fromOffset(438, -6)
	gain.TextXAlignment = Enum.TextXAlignment.Right
	gain.TextColor3 = GREEN
	gain.Text = ""
	self.gainText = gain

	self.barGold = chip(bar, "Gold", GOLD, 124, 30)
	;(self.barGold.Parent :: Frame).Position = UDim2.fromOffset(560, 10)

	self.commitChip = chip(bar, "Commit", GOLD, 150, 26)
	;(self.commitChip.Parent :: Frame).Position = UDim2.fromOffset(8, 46)

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BackgroundColor3 = Color3.fromRGB(13, 18, 30)
	track.BorderSizePixel = 0
	track.Size = UDim2.fromOffset(518, 20)
	track.Position = UDim2.fromOffset(166, 49)
	track.Active = true
	track.Parent = bar
	stroke(track, EDGE)
	self.track = track
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = BLUE
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(Config.DEFAULT_ATTACK_RATIO, 1)
	fill.Parent = track
	self.ratioFill = fill
	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.BackgroundColor3 = INK
	knob.BorderSizePixel = 0
	knob.Size = UDim2.fromOffset(8, 24)
	knob.Position = UDim2.new(Config.DEFAULT_ATTACK_RATIO, -4, 0, -2)
	knob.ZIndex = 3
	knob.Parent = track
	self.ratioKnob = knob

	-- build row
	self.buildButtons = {}
	for i, b in BUILDS do
		local btn = Instance.new("TextButton")
		btn.Name = "B" .. b.tag
		btn.Size = UDim2.fromOffset(72, 34)
		btn.Position = UDim2.fromOffset(8 + (i - 1) * 76, 80)
		btn.BackgroundColor3 = Color3.fromRGB(15, 20, 33)
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = false
		btn.FontFace = FONT_PIXEL
		btn.TextSize = 13
		btn.TextColor3 = INK_OFF
		btn.Text = b.tag .. " 0"
		btn.Parent = bar
		stroke(btn, EDGE, 1)

		local key = text(btn, "Key", 10)
		key.Size = UDim2.fromOffset(10, 10)
		key.Position = UDim2.fromOffset(3, 1)
		key.TextColor3 = INK_OFF
		key.Text = b.key

		self.buildButtons[b.tag] = btn
	end

	self.bar = bar

	-- ======================================================= fronts, banner ==
	local fronts = panel(screen, "Fronts")
	fronts.Size = UDim2.fromOffset(BOARD_W, 30)
	fronts.Position = UDim2.fromOffset(12, 12 + board.Size.Y.Offset + 8)
	fronts.Visible = false
	local frontRows = Instance.new("Frame")
	frontRows.Name = "Rows"
	frontRows.BackgroundTransparency = 1
	frontRows.Size = UDim2.new(1, -16, 1, -10)
	frontRows.Position = UDim2.fromOffset(8, 5)
	frontRows.Parent = fronts
	local fl = Instance.new("UIListLayout")
	fl.Padding = UDim.new(0, 1)
	fl.SortOrder = Enum.SortOrder.LayoutOrder
	fl.Parent = frontRows
	self.fronts, self.frontRows, self.frontPool = fronts, frontRows, {}

	local banner = panel(screen, "Banner")
	banner.Size = UDim2.fromOffset(600, 44)
	-- Clears the team share bar, which sits directly under the status panel.
	banner.Position = UDim2.new(0.5, -300, 0, 146)
	banner.Visible = false
	local bannerText = text(banner, "Text", 18)
	bannerText.Size = UDim2.new(1, -20, 1, 0)
	bannerText.Position = UDim2.fromOffset(10, 0)
	bannerText.TextXAlignment = Enum.TextXAlignment.Center
	self.banner, self.bannerText = banner, bannerText

	-- ========================================================== hover card ==
	local hover = panel(screen, "Hover")
	hover.Size = UDim2.fromOffset(200, 62)
	hover.Visible = false
	hover.ZIndex = 20
	for _, d in hover:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = 20
		end
	end
	local hoverName = text(hover, "Name", 15)
	hoverName.Size = UDim2.new(1, -16, 0, 20)
	hoverName.Position = UDim2.fromOffset(8, 5)
	hoverName.ZIndex = 21
	self.hoverName = hoverName
	local hoverStats = text(hover, "Stats", 13, false)
	hoverStats.Size = UDim2.new(1, -16, 0, 16)
	hoverStats.Position = UDim2.fromOffset(8, 24)
	hoverStats.TextColor3 = INK_DIM
	hoverStats.ZIndex = 21
	self.hoverStats = hoverStats
	local hoverTerrain = text(hover, "Terrain", 12, false)
	hoverTerrain.Size = UDim2.new(1, -16, 0, 16)
	hoverTerrain.Position = UDim2.fromOffset(8, 40)
	hoverTerrain.TextColor3 = INK_OFF
	hoverTerrain.ZIndex = 21
	self.hoverTerrain = hoverTerrain
	self.hover = hover

	local hint = text(screen, "Hint", 12, false)
	hint.Size = UDim2.fromOffset(700, 16)
	hint.Position = UDim2.new(0, 12, 1, -18)
	hint.TextColor3 = INK_OFF
	hint.Text = "DRAG PAN  ·  SCROLL ZOOM  ·  CLICK ATTACK  ·  1-9 COMMIT  ·  X RECALL"

	-- sensible defaults so nothing reads as blank before the first update
	HUD.setGold(self, nil)
	HUD.setStructures(self, nil)
	return self
end

-- ================================================================ updates ==

function HUD.setLobbyCode(self: HUD, code: string)
	self.lobbyCode.Text = code
end

function HUD.setIdentity(self: HUD, name: string, color: Color3)
	self.statusName.Text = name
	self.statusName.TextColor3 = color
end

-- Gold is not simulated yet; nil renders as "-" rather than a fake number.
function HUD.setGold(self: HUD, amount: number?)
	local s = amount and formatCount(amount) or "-"
	self.statusGold.Text = s
	self.barGold.Text = s
end

-- counts = { CITY = n, ... } or nil while the unit systems do not exist.
function HUD.setStructures(self: HUD, counts: { [string]: number }?)
	for tag, lbl in self.structLabels do
		local n = counts and counts[tag] or 0
		lbl.Text = tag .. " " .. n
		lbl.TextColor3 = n > 0 and INK or INK_OFF
	end
	for tag, btn in self.buildButtons do
		local n = counts and counts[tag] or 0
		btn.Text = tag .. " " .. n
		btn.TextColor3 = n > 0 and INK or INK_OFF
	end
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
		return
	end
	self.teamPanel.Visible = true

	local land = math.max(playableLand, 1)
	self.teamMine = myTeam
	for t, s in ipairs(stats) do
		local seg = self.teamSegs[t]
		if not seg then
			seg = Instance.new("Frame")
			seg.Name = "T" .. t
			seg.BorderSizePixel = 0
			seg.Parent = self.teamTrack
			local lbl = text(seg, "V", 13)
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.TextXAlignment = Enum.TextXAlignment.Center
			lbl.ZIndex = 2
			self.teamSegs[t] = seg
		end

		-- Share is a TARGET; the segment slides to it in step(). A bar that
		-- snaps five times a second reads as a stutter, and the whole point
		-- of the bar is that you watch it move.
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

-- Segments are laid end to end from the SMOOTHED shares, so the cursor has
-- to be re-run over all of them whenever any one moves.
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
		lbl.TextColor3 = Color3.fromRGB(16, 20, 30)
		if share < 0.06 then
			lbl.Text = ""
		elseif not self.teamAlive[t] then
			lbl.Text = Palette.teamTag(t) .. " OUT"
		else
			lbl.Text = string.format(
				"%s%s %d%%",
				t == self.teamMine and "> " or "",
				Palette.teamTag(t),
				math.floor(share * 100 + 0.5)
			)
		end
	end
end

function HUD.setBanner(self: HUD, str: string?, color: Color3?)
	if str == nil then
		self.banner.Visible = false
		return
	end
	self.banner.Visible = true
	self.bannerText.Text = str
	self.bannerText.TextColor3 = color or INK
end

function HUD.setTimer(self: HUD, seconds: number, phase: string)
	self.clockText.Text = string.format("%d:%02d", math.floor(seconds / 60), math.floor(seconds % 60))
	self.phaseText.Text = string.upper(phase)
end

-- The line beside your name: normally "PLAYER", but it reports the most
-- urgent front when there is one.
function HUD.setTarget(self: HUD, str: string, color: Color3?)
	self.statusRole.Text = str
	self.statusRole.TextColor3 = color or INK_OFF
end

function HUD.setRatio(self: HUD, ratio: number, troops: number?)
	self.ratioFill.Size = UDim2.fromScale(ratio, 1)
	self.ratioKnob.Position = UDim2.new(ratio, -4, 0, -2)
	self.commitChip.Text = string.format(
		"%d%% (%s)",
		math.floor(ratio * 100 + 0.5),
		formatCount((troops or 0) * ratio)
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
	self.troopText.Text = string.format("%s / %s", formatCount(troops), formatCount(maxTroops))
	self.incomeText.Text = string.format("+%s/s", formatCount(incomePerSec))

	-- The split bar has no worker/troop split to show yet, so it reports the
	-- same army against its ceiling rather than inventing a second resource.
	self.splitFill.Size = UDim2.fromScale(frac, 1)
	self.splitLeft.Text = formatCount(troops)
	self.splitRight.Text = formatCount(maxTroops)

	self.statusDelta.Text = formatCount(tiles) .. "\nTILES"
end

function HUD.setGain(self: HUD, delta: number)
	if delta > 1 then
		self.gainText.Text = "+" .. formatCount(delta)
		self.gainText.TextColor3 = GREEN
	elseif delta < -1 then
		self.gainText.Text = formatCount(delta)
		self.gainText.TextColor3 = RED
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
	self.hoverName.Text = info.name
	self.hoverName.TextColor3 = info.color or INK
	self.hoverTerrain.Text = info.terrain or ""
	HUD.refreshHover(self)
end

-- The card quotes the SAME smoothed numbers the standings do, by player
-- id, rather than the raw figures off the last packet: hovering a nation
-- and reading its row must not show two different armies.
function HUD.refreshHover(self: HUD)
	local info = self.hoverInfo
	if not info then
		return
	end
	if info.unclaimed then
		self.hoverStats.Text = "unclaimed"
		return
	end
	local id = info.id
	local troops = (id and self.troopsShown[id]) or info.troops or 0
	local tiles = (id and self.tilesShown[id]) or info.tiles or 0
	local t = string.format("%s troops   %s tiles", formatCount(troops), formatCount(tiles))
	if t ~= self.hoverText then
		self.hoverText = t
		self.hoverStats.Text = t
	end
end

-- Call on viewport resize. Scales the whole HUD rather than letting fixed
-- pixel panels collide on small windows.
function HUD.layout(self: HUD, viewW: number, viewH: number)
	self.uiScale.Scale = math.clamp(math.min(viewW / 1440, viewH / 900), 0.55, 1)
end

function HUD.moveHover(self: HUD, x: number, y: number, viewW: number, viewH: number)
	-- AbsoluteSize is post-scale, but Position offsets are pre-scale, so the
	-- final placement has to be divided back out.
	local s = self.uiScale.Scale
	local w, h = self.hover.AbsoluteSize.X, self.hover.AbsoluteSize.Y
	local px, py = x + 18, y + 18
	if px + w > viewW - 8 then
		px = x - w - 18
	end
	if py + h > viewH - 8 then
		py = y - h - 18
	end
	self.hover.Position = UDim2.fromOffset(px / s, py / s)
end

function HUD.setFronts(self: HUD, outgoing: { any }, incoming: { any })
	table.clear(self.frontTarget)
	table.clear(self.frontRowInfo)

	-- The status line above this list reports the front that matters most
	-- right now, and being invaded outranks anything you are doing. Chosen
	-- HERE rather than in the client, so the figure it quotes is the same
	-- smoothed one the list underneath is showing -- the two used to be
	-- computed separately and could disagree by an update.
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
	if total > 0 then
		self.fronts.Size = UDim2.fromOffset(BOARD_W, 12 + total * 17)
	end

	local index = 0
	local function emit(e: any, isIn: boolean)
		index += 1
		local row = self.frontPool[index]
		if not row then
			row = text(self.frontRows, "F" .. index, 13)
			row.Size = UDim2.new(1, 0, 0, 16)
			self.frontPool[index] = row
		end
		row.Visible = true
		row.LayoutOrder = index
		row.TextColor3 = isIn and RED or GREEN

		-- Keyed by side and opponent, not by row: the rows re-order as
		-- fronts open and close, and a per-row tween would slide one
		-- opponent's army toward another's.
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

	-- A front that has closed must not keep its smoothing state, or
	-- re-opening it later would count up from a figure months old.
	for key in self.frontShown do
		if self.frontTarget[key] == nil then
			self.frontShown[key] = nil
		end
	end

	HUD.refreshFronts(self)
end

-- Draws the fronts list and its status line from the SMOOTHED figures.
function HUD.refreshFronts(self: HUD)
	for _, info in self.frontRowInfo do
		local t = string.format(
			"%s %s  %s",
			info.isIn and "<<" or ">>",
			info.name,
			formatCount(self.frontShown[info.key] or 0)
		)
		if t ~= info.text then
			info.text = t
			info.row.Text = t
		end
	end

	local lead = self.frontLead
	if not lead then
		HUD.setTarget(self, "PLAYER", INK_OFF)
		return
	end
	HUD.setTarget(self, string.format(
		"%s  %s  %s  %s",
		lead.isIn and "UNDER ATTACK" or "ADVANCING",
		lead.isIn and "<<" or ">>",
		lead.name,
		formatCount(self.frontShown[lead.key] or 0)
	), lead.isIn and RED or GREEN)
end

function HUD.setStandings(self: HUD, list: { any }, myId: number)
	-- Ordered with HYSTERESIS, not by an exact sort. A dozen nations sit
	-- within a few tiles of each other for most of a round, and at five
	-- updates a second an exact sort has them swapping rows continuously --
	-- a table that reshuffles five times a second cannot be read at all.
	-- Start from last update's order and let a nation overtake only once it
	-- is clearly ahead: an insertion sort with a margin, free on 13 rows.
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

	-- Targets for everyone, not just the visible rows: a nation that drops
	-- off the bottom and comes back must not snap in from a stale figure.
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

	local function fill(slot: number, rank: number, e: any, pinned: boolean)
		local row = self.rowPool[slot]
		if not row then
			row = Instance.new("Frame")
			row.Name = "R" .. slot
			row.BorderSizePixel = 0
			row.Size = UDim2.new(1, 0, 0, ROW_H - 1)
			row.Parent = self.rows
			local sw = Instance.new("Frame")
			sw.Name = "Swatch"
			sw.Size = UDim2.fromOffset(3, ROW_H - 1)
			sw.BorderSizePixel = 0
			sw.Parent = row
			for _, c in self.cols do
				local cell = text(row, c[1], 13)
				cell.Size = UDim2.fromOffset(c[3], ROW_H - 1)
				cell.Position = UDim2.fromOffset(c[2], 0)
				cell.TextTruncate = Enum.TextTruncate.AtEnd
				cell.TextXAlignment = c[4] and Enum.TextXAlignment.Right
					or Enum.TextXAlignment.Left
			end
			self.rowPool[slot] = row
		end

		row.Visible = true
		row.LayoutOrder = slot
		local isMe = e.id == myId
		row.BackgroundColor3 = pinned and Color3.fromRGB(48, 42, 24)
			or (slot % 2 == 0 and ROW_A or ROW_B)

		local sw = row:FindFirstChild("Swatch") :: Frame
		sw.BackgroundColor3 = Palette.playerColor3(e.id, myId)
		sw.BackgroundTransparency = e.alive and 0 or 0.6

		local ink = e.alive and (isMe and GOLD or INK) or INK_OFF
		local function set(k: string, v: string)
			local c = row:FindFirstChild(k) :: TextLabel
			c.Text = v
			c.TextColor3 = ink
		end
		set("#", tostring(rank))
		set("TAG", e.tag or "")
		set("NAME", e.name)
		-- The two figures that move every update are drawn from their
		-- SMOOTHED values and kept current by step(); the rest are static
		-- enough to write straight through.
		set("PCT", string.format("%.1f%%", self.pctShown[e.id] or 0))
		set("GOLD", e.gold and formatCount(e.gold) or "-")
		set("ARMY", formatCount(self.troopsShown[e.id] or e.troops))

		-- Rows are pooled and change owner as the order shifts, so step()
		-- has to be told which player each slot is currently showing.
		local info = self.rowInfo[slot]
		if not info then
			info = {}
			self.rowInfo[slot] = info
		end
		info.id = e.id
		info.army = row:FindFirstChild("ARMY")
		info.pct = row:FindFirstChild("PCT")
		info.armyText, info.pctText = nil, nil

		-- The otherwise unused TAG column carries the team, in the team's own
		-- colour: with allies scattered through the rankings by size, the side
		-- a row belongs to has to be readable without cross-referencing.
		if e.team then
			local tagCell = row:FindFirstChild("TAG") :: TextLabel
			tagCell.TextColor3 = e.alive and Palette.teamColor3(e.team) or INK_OFF
		end
	end

	local slot = 0
	for rank = 1, math.min(#list, TOP_ROWS) do
		slot += 1
		fill(slot, rank, list[rank], false)
	end
	if myEntry and myRank and myRank > TOP_ROWS then
		slot += 1
		fill(slot, myRank, myEntry, true)
	end
	for i = slot + 1, #self.rowPool do
		self.rowPool[i].Visible = false
		if self.rowInfo[i] then
			self.rowInfo[i].id = nil
		end
	end
end

-- Called every frame. Walks every smoothed figure toward its target and
-- rewrites only the labels whose PRINTED text actually changed, so a
-- settled table costs a handful of comparisons and no property writes.
function HUD.step(self: HUD, dt: number)
	for id, target in self.troopsTarget do
		self.troopsShown[id] = Numbers.approach(self.troopsShown[id] or target, target, dt, COUNT_RATE)
	end
	for id, target in self.pctTarget do
		self.pctShown[id] = Numbers.approach(self.pctShown[id] or target, target, dt, COUNT_RATE)
	end
	for _, info in self.rowInfo do
		if info.id then
			local a = formatCount(self.troopsShown[info.id] or 0)
			if a ~= info.armyText then
				info.armyText = a
				info.army.Text = a
			end
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
