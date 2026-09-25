--!strict
-- Conquest :: Structures  (client)
-- Everything drawn ON the map that is not territory: cities, ports, the rails
-- between them, and the boats and trains running on them.
--
-- All of it is parented to the MAP CONTAINER, not the ScreenGui, for the same
-- reason the nation labels are: the camera already sizes and moves that
-- container, so pan and zoom carry every marker for free and nothing here
-- writes a position on the camera's behalf.
--
-- POSITION IS SCALE, EVERYWHERE AND ALWAYS: it pins a thing to its tile
-- through any zoom, and nothing here writes a position on the camera's behalf.
--
-- SIZE IS SCALE FOR EVERYTHING THAT STANDS ON THE GROUND -- the rails, and
-- since 2026-09-02 the buildings too (owner: "use scale for all the buildings
-- on the map instead of offset"). Camera2D sizes the container to exactly
-- (W*zoom, H*zoom), so a Frame of Scale size (w/W, h/H) renders as
-- (w*zoom, h*zoom) pixels: its size is written in TILES and the camera does
-- the rest. A city now covers the same patch of GROUND at every zoom instead
-- of being a constant-size sticker that shrinks against the land as you go in.
--
-- DEFAULT_ZOOM is 1.0 -- one pixel per tile -- so every number below that used
-- to be pixels is now tiles and the default view is unchanged to the pixel.
-- What changed is every other zoom, and it changed in both directions:
--   * A level 10 city is 31 tiles across, so at MAX_ZOOM (12x) it draws 372px.
--     If that ever needs a lid the fix is a pixel clamp on the size here, not
--     a return to offset.
--   * A base chip is 13 tiles against the 15-tile minimum spacing, so two
--     structures at that spacing CLEAR each other at every zoom. Sized in
--     offset they overlapped below 1.73x and separated above it.
--
-- Rotation happens in pixel space, which is why the scale trick works at all:
-- if the container's aspect did not match the map's, a rotated scale-sized
-- frame would shear.
--
-- THE VEHICLES ARE STILL PINS, sized in offset. A boat is a moving chip you
-- have to be able to find across an ocean, not a piece of ground.

local TweenService = game:GetService("TweenService")

local Config = require(script.Parent.Config)
local Palette = require(script.Parent.Palette)
local Icons = require(script.Parent.Icons)
local Sfx = require(script.Parent.Sfx)

local Structures = {}
Structures.__index = Structures

export type Structures = typeof(setmetatable({} :: any, Structures))

local W = Config.MAP_W
local H = Config.MAP_H
-- Sim ticks a second. The construction event carries a tick count and the
-- fill above has to run for that many seconds of real time.
local TICK_RATE = Config.TICK_RATE

Structures.CITY = 1
Structures.PORT = 2
-- Structure kinds are Units type ids on the wire, so this is 6 and not 3.
-- A factory turns the cities and ports within STATION_MAX_RANGE of it into
-- train stations and is the only building that dispatches trains.
Structures.FACTORY = 6
-- Vehicle kinds, a separate numbering from the structure kinds above. They
-- collide numerically, which is exactly why they are named.
Structures.TRADING_BOAT = 1
Structures.TRAIN = 2
-- A transport boat carrying an invasion. Drawn large: it is the only vehicle
-- whose arrival changes who owns territory, so it has to be findable at a
-- glance from across an ocean.
Structures.TRANSPORT_BOAT = 3
-- A gunboat is the BIGGEST vehicle marker -- bigger than the transport it
-- hunts, because it is the thing that decides whether that transport ever
-- arrives. A shell is the smallest, and the only marker on this map drawn in
-- nobody's colour: see SHELL_HOT.
Structures.GUNBOAT = 4
Structures.SHELL = 5

-- Below this the map is zoomed far enough out that a structure is smaller than
-- the 15-tile spacing rule guarantees between them, so the markers stop being
-- separate objects and become a rash over the territory colours.
--
-- ONE GATE, AND IT SITS BELOW THE ZOOM A PHONE OPENS AT (owner, 2026-09-14:
-- "the items on the map like railways and buildings seem to be moving at a
-- different rate than the map"). These were 0.7 for the markers and 0.9 for
-- the rails, both picked against a desktop window. But the fit zoom is the
-- viewport's clear strip over 550 tiles, which is 0.50 on 844x390 and 0.55 on
-- 932x430 -- so a PHONE SPAWNED BELOW BOTH OF THEM. The opening view of the
-- round had no cities, no boats, no wakes and no rails anywhere on it, and an
-- ordinary pinch then crossed two different thresholds and popped two
-- different sets of things on and off. Two staggered pops over a map that is
-- scaling smoothly is what "moving at a different rate" looks like from the
-- outside, and neither pop is a fade.
--
-- 0.45 clears both phone fit zooms and still leaves the far overview (down to
-- MIN_ZOOM 0.35) uncluttered, which is what the paragraph above protects.
-- Rails share the number rather than leading it by 0.2: a hairline that
-- arrives on a different frame from the city it runs to reads as a bug, and a
-- rail at 0.45 is the same hairline it already was at 0.9.
local MIN_VISIBLE_ZOOM = 0.45
local MIN_RAIL_ZOOM = MIN_VISIBLE_ZOOM

-- Eleven pixels was a pin, not a building. At that size the marker was a
-- coloured speck with something smudged in the middle of it -- you could see
-- THAT there was a city there but never WHICH kind, which is the only question
-- a map marker exists to answer. Eighteen is the smallest that gives the glyph
-- room to be a shape instead of a stain.
--
-- THAT FLOOR WAS AN ARGUMENT ABOUT OFFSET SIZING, and it died with it. The
-- numbers halved on the owner's call the day after they were converted to
-- tiles (2026-09-02, "this is way too big, reduce the radius by 50%"):
-- 26 -> 13, 4 -> 2, and the digit 16 -> 8 -- the whole ladder at once, the way
-- the +30% pass of 2026-09-01 moved 20 -> 26 and 3 -> 4 together rather than
-- letting the base rung creep up on the rest.
--
-- The paragraph above was written for a marker with ONE size for the whole
-- game, which therefore had to be legible in the widest view a player ever
-- uses. A chip measured in tiles is 13px only in THAT view; it is 26px at 2x
-- and 52px at 4x, which is where anything actually gets built. What used to be
-- the minimum is now the bottom of a range.
--
-- WHAT IT BUYS is the anti-blob margin, and more of it than the offset version
-- ever had: 13 tiles against a 15-tile minimum spacing means two structures at
-- that spacing clear each other by 2 tiles at EVERY zoom.
--
-- IN TILES, NOT PIXELS, since the scale conversion: DEFAULT_ZOOM is one pixel
-- per tile, so 13 tiles is 13px in the default view and grows from there.
local BASE_SIZE = 13
local PER_LEVEL = 2
-- The level digit, also in tiles, and CONSTANT across levels -- as a fraction
-- of the chip it was illegible on a level 2 and covered half the house on a
-- level 10. It is a child of the chip, so holding it constant means dividing
-- by the chip's own size every time that size changes: see sizeChip.
local LEVEL_SIZE = 8
-- ONE SIZE FOR EVERY SHIP (2026-09-02, owner: "why are ships different sizes
-- in the game, make them all same size"). A trading boat drew at 7, a transport
-- at 11 and a gunboat at 20, so the same stretch of sea carried boats at 12, 19
-- and 39 pixels and SIZE was saying what the sprites already say -- which is
-- which. The number kept is the transport's: the middle of the three, and the
-- one marker whose arrival takes territory, so the invasion is untouched and
-- the sea gets calmer rather than busier.
--
-- WHAT THIS SPENDS is the gunboat paragraph that used to live here. At 20 the
-- TURRET -- three rows of a sixteen-row grid, and the one thing that tells a
-- gunboat from a transport at a glance -- drew about eight pixels; it now draws
-- about four. If gunboats stop being findable in a sea fight the fix is to
-- raise this ONE number for every ship, or to separate them by something that
-- is not size. It is not to give the gunboat its own again.
local BOAT_SIZE = 11

-- A LOCOMOTIVE, AND THE ONLY MARKER ON THIS MAP MEASURED IN TILES (2026-09-02,
-- owner: "i dont see trains on the new railway anymore"). They were still
-- running; they had been swallowed. A train was a 6px square sized in OFFSET,
-- which was legible on the tan hairline the rails used to be and is not legible
-- at all on the sleepered track that replaced it: the ties are 4 TILES across
-- and creosote-dark, so at any zoom past 1 the chip was smaller than a single
-- sleeper and no brighter than the gap between two.
--
-- The fix is to measure the engine against the thing it runs on rather than
-- against the screen. A rail is RAIL_THICK thick with ties every TIE_GAP, so an
-- engine 6 tiles long and 3.6 wide is one and a half sleeper bays of solid
-- colour lying ALONG the track, and it stays that at every zoom because the
-- track does too. At DEFAULT_ZOOM it covers about what the old square did --
-- this is not a size increase, it is the same mark tied to the right ruler.
--
-- WIDER THAN THE RAIL, NARROWER THAN THE TIES, deliberately: the sleeper ends
-- stay visible either side of the engine, which is what makes it read as
-- something ON the track rather than as a break in it.
local TRAIN_LEN = 6.0
local TRAIN_WIDE = 3.6

-- A SHIP'S HEALTH, DRAWN AS A LENGTH (2026-09-02, owner: "give all the ships
-- small health bars with red and green"). Green is what is left, red is what is
-- gone, and the bar is the same width on every hull so two ships in a duel can
-- be compared at a glance without reading anything.
--
-- ON GUNBOATS ONLY (owner, 2026-09-03). A gunboat is the only hull with real
-- hit points (Units.INFO maxHealth 1000, plus 20% a veterancy level); a
-- transport and a trading boat carry the default 1, so their bar could only
-- ever be full. A readout that cannot move is not a readout -- it is a second
-- row of pixels over a 16-cell sprite, and it makes a hull that one shell
-- takes look like one that can stand and fight. No bar says it better.
--
-- In OFFSET, like the hull it sits over, so it is the same size at every zoom.
local HP_BAR_W = 15
local HP_BAR_H = 3
-- Air between the bar and the tallest cell of the sprite. See makeVehicle,
-- which works out where that is per boat rather than guessing one gap for all.
local HP_BAR_LIFT = 3
-- Never quite empty: a bar showing a sliver has to keep that sliver, or the
-- last few percent round away to nothing and a ship still afloat reads as dead.
local HP_BAR_MIN = 0.08
local HP_GREEN = Color3.fromRGB(88, 206, 98)
local HP_RED = Color3.fromRGB(202, 54, 46)
-- Small, but never a speck: three pixels of flat chip was indistinguishable
-- from a stray pixel of somebody's territory that had got out to sea. It is
-- drawn as ordnance rather than as a marker -- see makeVehicle.
local SHELL_SIZE = 7
-- Tiles a shell crosses a second, taken from the sim's own figure rather than
-- guessed: three tiles a tick at ten ticks. It is the speed the TERMINAL
-- FLIGHT flies at, so a shell that finishes its run after leaving the wire
-- covers ground at exactly the rate it was doing on it.
local SHELL_TILES_PER_SEC = (Config.SHELL_SPEED or 3) * TICK_RATE

local INK = Color3.fromRGB(246, 249, 255)
local DARK = Color3.fromRGB(10, 14, 24)
-- ORDNANCE, and after the rails the only thing here drawn in nobody's colour.
-- A shell used to take its owner's tint, which is information you can already
-- read off the gunboat that fired it, and which at this size just made it a
-- coloured speck. A hot core inside a red casing is an explosive at any size,
-- and the burst it leaves is the same two colours in the same order.
local SHELL_HOT = Color3.fromRGB(255, 226, 122)
local SHELL_CASE = Color3.fromRGB(214, 58, 30)
-- Rails belong to neither end of the line they join, so they are the one thing
-- on this map drawn in nobody's colour.
--
-- WHAT MAKES A LINE READ AS A RAILWAY IS THE TIES, NOT THE RAIL (2026-09-02,
-- owner: "make railroads look more like railroads"). This was a single tan
-- hairline, which is the same mark a road, a border or a pipeline would get.
-- It is now the cartographer's railway: a continuous rail with dark sleepers
-- crossing it at a fixed spacing and overhanging both sides. The ties are what
-- carry the reading -- at DEFAULT_ZOOM they are 1px ticks every 4px on a 1.5px
-- line, which is a hatched line and not a plain one; zoomed in they separate
-- into a ladder.
local RAIL_INK = Color3.fromRGB(168, 154, 128)
local RAIL_T = 0.12
local RAIL_THICK = 1.5 -- in TILES; renders as 1.5 * zoom pixels
-- Creosoted sleeper. Dark, because it has to hold against pale territory
-- colours AND against the tan rail lying across it.
local TIE_INK = Color3.fromRGB(58, 46, 36)
local TIE_T = 0.18
-- Across the line, so a tie overhangs the rail by 1.25 tiles on each side.
-- The overhang IS the signal: a dash the same width as the line is a dashed
-- line, and this map already uses dashes for nothing.
local TIE_ACROSS = 4.0
-- Along the line, and the spacing between tie centres.
local TIE_ALONG = 1.1
local TIE_GAP = 4.0
-- TIES ARE DRAWN BY A GRADIENT, NOT ONE FRAME EACH, and this number is why: a
-- NumberSequence takes 20 keypoints, a hard-edged tie costs 4 of them, and the
-- two ends cost one each. So one Frame carries four ties, and a rail that used
-- to be one Frame per straight run is now that run's rail plus a strip per
-- four ties -- on the order of twice the instances, against sixteen times for
-- a frame per tie. There are hundreds of rails on a late map; this is the
-- whole reason the design is a gradient.
local TIES_PER_STRIP = 4

function Structures.new(container: Frame): Structures
	local root = Instance.new("Frame")
	root.Name = "Economy"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	-- ABOVE THE MAP IMAGE, and this line is the whole reason anything here
	-- is visible at all. The ScreenGui is ZIndexBehavior.Sibling, so a
	-- sibling's ENTIRE SUBTREE is placed by the ROOT's ZIndex -- the 4/5/6
	-- on the layers below only order them against each other. The
	-- renderer's opaque map tiles are siblings of this frame at the default
	-- ZIndex 1 and are created LATER (Renderer.new runs on `init`, this runs
	-- at load), and equal ZIndex breaks in favour of the later child -- so
	-- at the default the map painted over every marker, rail and boat and
	-- NOTHING IN THIS MODULE HAS EVER BEEN VISIBLE IN GAME. 3 clears the
	-- map (1) and the paper/shadow (0) while staying under the nation
	-- labels (their root is 5) and the click pings (6), which is the
	-- stacking every other map overlay already assumes.
	root.ZIndex = 3
	root.Parent = container

	-- Four layers, in reading order: foam is on the water, a station sits ON
	-- its lines, and a train runs OVER both.
	local function layer(name: string, z: number): Frame
		local f = Instance.new("Frame")
		f.Name = name
		f.BackgroundTransparency = 1
		f.Size = UDim2.fromScale(1, 1)
		f.ZIndex = z
		f.Parent = root
		return f
	end

	return setmetatable({
		root = root,
		-- Under everything else here, and NAMED FOR WHAT IT NO LONGER HOLDS:
		-- the transports' route lines are painted into the map's water pixels
		-- now (see the wake section), so what is left in this layer is the foam
		-- a sinking hull opens -- which is on the water the boats are on.
		wakeLayer = layer("Wakes", 3),
		railLayer = layer("Rails", 4),
		markLayer = layer("Marks", 5),
		vehicleLayer = layer("Vehicles", 6),
		-- ABOVE EVERYTHING ELSE HERE, and outside the zoom gate below: what
		-- you are about to place has to be visible while you are placing it,
		-- including while you zoom out to find somewhere to put it.
		ghostLayer = layer("Ghost", 7),
		ghost = nil :: any,
		ghostChip = nil :: any,
		ghostBlast = nil :: any,
		ghostT = 0,
		-- Last zoom seen by `step`. The blast radius is measured in TILES and
		-- drawn in PIXELS, so it is the one thing here that needs it.
		zoom = 1,
		-- tile -> { frame, stroke, label, level, ownerId, kind }
		byTile = {} :: { [number]: any },
		-- "a:b" -> { segments = { Frame } }
		railByKey = {} :: { [string]: any },
		-- vehicle id -> { frame, x, y, p0..p3, ownerId, kind }
		vehicleById = {} :: { [number]: any },
		-- Shells that have left the wire and are flying their last stretch at
		-- what they were fired at. Off vehicleById on purpose: nothing on the
		-- stream can name them any more, and leaving them in it would have every
		-- send re-run the removal branch that put them here. See beginTerminal.
		shellsLanding = {} :: { any },
		-- The vehicle stream's clock. `packetDt` is the measured interval
		-- between sends and `packetT` how far into the current one we are;
		-- together they are the parameter every marker is drawn at. Seeded at
		-- the server's nominal 2 Hz so the first send after joining is drawn
		-- at a sane speed rather than instantly.
		packetDt = 0.5,
		packetT = 0,
		lastPacket = nil :: number?,
		myId = 0,
		visible = true,
		railsVisible = true,
		-- The map the transports' routes are painted into, which does not exist
		-- yet: this runs at load and the Renderer is built per round. See
		-- Structures.setRenderer, and note every stamp site tests it for nil.
		renderer = nil :: any,
		-- Routes whose boat has gone, draining a prefix a frame. See fadeTrail.
		fading = {} :: { any },
		-- Whether those routes are currently ON the map. False while the view is
		-- zoomed out past the markers; the tile lists stay either way.
		wakesShown = true,
	}, Structures)
end

-- THE MAP THE ROUTES ARE PAINTED INTO. A wake is pixels in the renderer's
-- EditableImage rather than a Frame over it, and the renderer is destroyed and
-- rebuilt every round while this module is not, so the client hands the new one
-- over in `init` right after Renderer.new -- immediately after structures:clear,
-- which is what puts the previous round's stamps back to open water first.
function Structures.setRenderer(self: Structures, renderer: any)
	self.renderer = renderer
end

function Structures.setLocalId(self: Structures, id: number)
	if self.myId == id then
		return
	end
	self.myId = id
	-- A player's own colour is derived against their id, so every marker has to
	-- be re-inked when the local player changes -- which happens once a round.
	for _, m in self.byTile do
		m.frame.BackgroundColor3 = Palette.playerColor3(m.ownerId, id)
	end
	for _, v in self.vehicleById do
		local colour = Palette.playerColor3(v.ownerId, id)
		if v.body then
			v.body.ImageColor3 = colour
		else
			v.frame.BackgroundColor3 = colour
		end
	end
end

-- ============================================================== structures ==

-- THE CHIP'S SIZE, IN TILES, AND THE ONLY PLACE IT IS WRITTEN. Three call
-- sites set it -- the chip is born at level 1, a level change re-sizes it, and
-- the placement ghost previews the level it would BE -- and the level digit
-- has to be re-fitted at every one of them: it is a child of the chip, so a
-- constant Scale would make the digit grow with the building. Dividing
-- LEVEL_SIZE by the chip's own size is what holds it still.
--
-- The chip is square in pixels even though its Scale is not: the container is
-- (W*zoom, H*zoom), so (s/W, s/H) comes out (s*zoom, s*zoom). That is also why
-- the digit can take the same fraction on both axes.
local function sizeChip(m: any, level: number)
	local s = BASE_SIZE + PER_LEVEL * (level - 1)
	m.frame.Size = UDim2.fromScale(s / W, s / H)
	m.label.Size = UDim2.fromScale(LEVEL_SIZE / s, LEVEL_SIZE / s)
end

-- THE CHIP, WITH NO TILE AND NO HOME. Both the finished building and the
-- PLACEMENT GHOST are this object, and they have to be the same one: the
-- ghost's entire job is to be the thing you are about to place, so a second
-- hand-built copy of the sprite would drift from it the first time either was
-- touched. `makeMarker` gives it a tile and the marker layer; the ghost gets
-- neither.
local function buildChip(): any
	local f = Instance.new("Frame")
	f.Name = "Structure"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BorderSizePixel = 0
	f.ZIndex = 5

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.35, 0)
	corner.Parent = f

	-- Dark ring, not a light one. The marker sits on top of its owner's own
	-- territory colour, and a light outline vanishes against the pale nations
	-- while the dark one separates it from every colour in the palette.
	local stroke = Instance.new("UIStroke")
	stroke.Color = DARK
	stroke.Thickness = 1.75
	stroke.Transparency = 0
	stroke.Parent = f

	-- A DARK PLATE, inset far enough to leave the owner's colour showing as a
	-- ring around it. This is the piece that was missing, and everything below
	-- depends on it: the sticker now has one constant background instead of
	-- twenty different nation colours, so it can be drawn in its own colours
	-- and still read the same on every empire. Ownership moves out to the ring,
	-- which is a saturated band against pale territory rather than a fill the
	-- glyph has to survive being printed on.
	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.BackgroundColor3 = DARK
	plate.BorderSizePixel = 0
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.Position = UDim2.fromScale(0.5, 0.5)
	-- WHAT IS LEFT OVER IS THE OWNER'S COLOUR, and at level 1 -- which is most
	-- cities on the map, most of the time -- that leftover ring is the ENTIRE
	-- ownership signal. So the plate's size IS the ring's thickness, inverted:
	-- (1 - 0.796) / 2 = 10.2% of the chip on each side, or 2.65px at the
	-- 26px base.
	--
	-- THINNED 40% ON THE OWNER'S CALL (2026-09-01, "reduce the thickness of
	-- the coloured ring by 40%"): the plate was 0.66, a 17% band, 3.4px on the
	-- 20px chip it was tuned for. Read the two together and it is nearly a
	-- wash in absolute pixels -- the +30% above put back most of what the 40%
	-- took -- but be honest about the direction: an earlier pass measured a
	-- 2.6px ring (a 0.74 plate at 20px) and called it "a colour you have to go
	-- looking for". This lands at 2.65px. It is a longer band around a bigger
	-- chip, which is not the same read, and it is what was asked for; if it
	-- turns out to be too little colour the number to move is this one.
	plate.Size = UDim2.fromScale(0.796, 0.796)
	-- So a construction fill rising inside it stops at the plate's edge. Corner
	-- clipping is rectangular, which costs two square pixels on a 20px chip that
	-- the glyph is drawn over anyway.
	plate.ClipsDescendants = true
	plate.ZIndex = 6
	plate.Parent = f
	local plateCorner = Instance.new("UICorner")
	plateCorner.CornerRadius = UDim.new(0.35, 0)
	plateCorner.Parent = plate

	-- The house / the port / the factory IN ITS OWN COLOURS, which is the whole
	-- reason these sprites were drawn as stickers with a dark outline baked in.
	-- They used to be tinted flat DARK, and ImageColor3 MULTIPLIES: tinting a
	-- sticker black collapses its outline and its interior into one silhouette,
	-- so an orange house and a blue sailboat arrived at the same seven-pixel
	-- black blob and the marker's ring was carrying the entire message. This is
	-- the same mistake the BOATS already fixed by splitting ink from body; here
	-- the fix is simpler, because on a dark plate the sticker needs no tint at
	-- all. Icons.FACTORY is a white silhouette rather than a colour drawing and
	-- comes out white, which is exactly right on black.
	local glyph = Instance.new("ImageLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.ScaleType = Enum.ScaleType.Fit
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	-- Slightly WIDER than the plate on purpose: the sticker's own dark outline
	-- lands on the coloured ring, which costs nothing (it is dark on either
	-- side of that boundary) and buys the building a couple more pixels of
	-- actual drawing.
	--
	-- SO IT MOVES WITH THE PLATE, and it has to: it was 0.70 against a 0.66
	-- plate, and left at 0.70 against 0.796 it would sit INSIDE the plate --
	-- a dark margin between the building and the ring, which is a third band
	-- nobody asked for. Same 6% overhang, measured off the new plate.
	glyph.Size = UDim2.fromScale(0.84, 0.84)
	glyph.ZIndex = 7
	glyph.Parent = f

	-- The level moved OFF the middle of the marker when the glyph moved
	-- into it: a digit on top of a house is neither. It overhangs the
	-- bottom-right corner instead, which is also why the stroke is now
	-- opaque -- outside the chip it is over raw territory colour.
	local lvl = Instance.new("TextLabel")
	lvl.Name = "Level"
	lvl.BackgroundTransparency = 1
	lvl.AnchorPoint = Vector2.new(0, 0.5)
	lvl.Position = UDim2.fromScale(0.92, 1.0)
	-- Size comes from sizeChip at the bottom of this function: it is LEVEL_SIZE
	-- tiles at every level, which as a child of a chip that grows with the
	-- level means a fraction that shrinks. Constant is the rule, not the number.
	lvl.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	lvl.TextScaled = true
	lvl.TextColor3 = INK
	lvl.TextStrokeTransparency = 0
	lvl.TextStrokeColor3 = DARK
	lvl.Text = ""
	lvl.Visible = false
	lvl.ZIndex = 8
	lvl.Parent = f

	local m = {
		frame = f,
		stroke = stroke,
		corner = corner,
		plate = plate,
		plateCorner = plateCorner,
		glyph = glyph,
		label = lvl,
		level = 0,
		ownerId = 0,
		kind = 0,
		-- Explicitly false, not nil: Structures.set compares against it, and
		-- nil ~= false would run the finished-building path on every marker the
		-- moment it is created.
		site = false,
	}
	-- The chip is born at level 1, which is also what sizes the digit.
	sizeChip(m, 1)
	return m
end

-- Kind decides the silhouette AND the corner radius, and the ghost has to
-- reach both -- pulled out of Structures.set for that and nothing else.
local function applyKind(m: any, kind: number)
	local radius
	if kind == Structures.PORT then
		radius = UDim.new(0.5, 0)
		m.glyph.Image = Icons.PORT
	elseif kind == Structures.FACTORY then
		radius = UDim.new(0.12, 0)
		m.glyph.Image = Icons.FACTORY
	else
		radius = UDim.new(0.35, 0)
		m.glyph.Image = Icons.HOUSE
	end
	-- The house and the sailboat are 16x16 grids; without this the engine
	-- filters them back into the smudges they were drawn to replace.
	Icons.resample(m.glyph)
	m.corner.CornerRadius = radius
	-- The plate follows the chip, or a circular port gets a square hole.
	m.plateCorner.CornerRadius = radius
end

local function makeMarker(self: Structures, tile: number): any
	local m = buildChip()
	local x = tile % W
	local y = (tile - x) / W
	m.frame.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)
	m.frame.Parent = self.markLayer
	self.byTile[tile] = m
	return m
end

-- ------------------------------------------------------ under construction --
--
-- A BUILDING SITE IS DRAWN NOW, AND IT USED NOT TO BE. Economy.drainStructEvents
-- dropped the event a site fires, so the first thing a player saw was the
-- FINISHED building -- 2s after the click for a city, 5 for a port, 10 for a
-- missile silo, 30 for a SAM. See the note on that function; this is the other
-- half of the fix.
--
-- IT IS NOT A SECOND KIND OF MARKER. It is the chip it is about to become,
-- ghosted, with the owner's colour flooding up behind the glyph as it goes up
-- -- so completion is a POP rather than one object being swapped for another,
-- and the ghost already tells you WHAT is being built and WHOSE it is.
local SITE_FRAME_T = 0.55
local SITE_PLATE_T = 0.35
local SITE_GLYPH_T = 0.6
local SITE_STROKE_T = 0.45
local SITE_FILL_T = 0.25

local function siteLook(m: any, on: boolean)
	m.frame.BackgroundTransparency = on and SITE_FRAME_T or 0
	m.plate.BackgroundTransparency = on and SITE_PLATE_T or 0
	m.glyph.ImageTransparency = on and SITE_GLYPH_T or 0
	m.stroke.Transparency = on and SITE_STROKE_T or 0
end

-- ONE TWEEN, running for exactly the ticks the server said were left. No clock
-- to keep and no per-frame work for a marker that may sit there thirty seconds,
-- and a site destroyed mid-build takes its tween down with it.
local function beginSite(m: any, left: number?)
	siteLook(m, true)
	local fill = m.fill
	if fill == nil then
		-- Built lazily. Most markers on a late map are finished buildings that
		-- will never need one, and this is a per-structure instance.
		fill = Instance.new("Frame")
		fill.Name = "Building"
		fill.BorderSizePixel = 0
		fill.AnchorPoint = Vector2.new(0.5, 1)
		fill.Position = UDim2.fromScale(0.5, 1)
		fill.BackgroundTransparency = SITE_FILL_T
		-- Inside the plate and UNDER the glyph (7), so the building is drawn ON
		-- the rising fill instead of being buried by it.
		fill.ZIndex = 6
		fill.Parent = m.plate
		m.fill = fill
	end
	fill.BackgroundColor3 = m.frame.BackgroundColor3
	fill.Size = UDim2.fromScale(1, 0)
	local secs = (left ~= nil and left > 0) and (left / TICK_RATE) or 0
	if secs <= 0 then
		fill.Size = UDim2.fromScale(1, 1)
		return
	end
	-- Linear, deliberately: this is a clock, and easing a clock makes it lie
	-- about how much is left.
	TweenService:Create(fill, TweenInfo.new(secs, Enum.EasingStyle.Linear), {
		Size = UDim2.fromScale(1, 1),
	}):Play()
end

local function endSite(m: any)
	siteLook(m, false)
	if m.fill ~= nil then
		m.fill:Destroy()
		m.fill = nil
	end
end

-- One structure, created or updated in place. `level` 0 means it is gone: a
-- razed structure and a captured one arrive on the same channel, so the caller
-- never has to know which kind of event it is holding. `uc` marks a site that
-- is still going up and `left` is how many ticks it has to run.
function Structures.set(self: Structures, tile: number, ownerId: number, level: number, kind: number, uc: boolean?, left: number?)
	if level <= 0 or ownerId == 0 then
		local m = self.byTile[tile]
		if m then
			m.frame:Destroy()
			self.byTile[tile] = nil
		end
		return
	end

	local m = self.byTile[tile] or makeMarker(self, tile)
	if m.ownerId ~= ownerId then
		m.ownerId = ownerId
		m.frame.BackgroundColor3 = Palette.playerColor3(ownerId, self.myId)
	end
	if m.kind ~= kind then
		m.kind = kind
		-- Silhouette FIRST, outline second. A port is a blue sailboat, a city an
		-- orange house, a factory a white sawtooth roof -- three different
		-- objects in three different colours, which is a distinction you can
		-- make at a glance and across a continent. The corner radius still
		-- backs it up (round / rounded / square) for the same reason a road
		-- sign is a shape as well as a picture, but the ring no longer has to
		-- carry the meaning on its own, so it goes back to being DARK on
		-- everything: one consistent edge against twenty territory colours.
		applyKind(m, kind)
	end
	if m.level ~= level then
		m.level = level
		sizeChip(m, level)
		-- The number only appears once it is telling you something a size
		-- comparison cannot: at level 1 every structure is the same and the
		-- digit is noise on an eleven-pixel dot.
		m.label.Visible = level > 1
		m.label.Text = level > 1 and tostring(level) or ""
	end

	-- LAST, because beginSite reads the owner colour off the frame and the
	-- block above is what puts it there.
	local site = uc == true
	if m.site ~= site then
		m.site = site
		if site then
			beginSite(m, left)
		else
			endSite(m)
		end
	end
end

-- The absolute list a joining client gets. Anything not in it is stale from
-- the previous round and has to go, or last round's cities haunt this one.
function Structures.setAll(self: Structures, list: { any })
	local keep = {}
	for _, c in list do
		keep[c.tile] = true
		Structures.set(self, c.tile, c.ownerId, c.level, c.kind or Structures.CITY, c.uc, c.left)
	end
	for tile, m in self.byTile do
		if not keep[tile] then
			m.frame:Destroy()
			self.byTile[tile] = nil
		end
	end
end

-- ========================================================= placement ghost ==
--
-- WHAT YOU ARE ABOUT TO PLACE, DRAWN WHERE IT WOULD LAND. Everything a build
-- click can be refused for is knowable on the client -- who owns the tile,
-- what the terrain is, where every other building already stands, what is in
-- the treasury -- so the answer does not have to be a round trip and a
-- sentence after the fact. The ghost is the SAME chip the finished building
-- uses, ghosted the way a construction site is, in one of three states:
--
--   ok       pale ring   this is where it goes
--   upgrade  amber ring  one of yours is already here; this levels it up
--   bad      red ring    it cannot go here, and the click exits placing
--
-- The three inks are deliberately NOT nation colours. A crimson team's own
-- shade against a red refusal is the one pair that must never be ambiguous,
-- and the ghost is read at the exact moment the player is committing gold.
local GHOST_INK = {
	ok = Color3.fromRGB(238, 244, 255),
	upgrade = Color3.fromRGB(255, 196, 96),
	bad = Color3.fromRGB(236, 92, 84),
}
-- A GHOST BREATHES AND A BUILDING DOES NOT, which is the whole reason a
-- half-transparent chip is not mistaken for a real one two tiles away. Same
-- rate as the spawn pick ring, for the same reason: it is a thing you are
-- holding, not a thing that is there.
local GHOST_PULSE_RATE = 4.2
-- The blast disc covers thousands of tiles, so it is far fainter than the
-- chip -- it has to say "this much" without hiding the map it is measuring.
local BLAST_FILL_T = 0.9
local BLAST_RING_T = 0.3

local function ghostChip(self: Structures): any
	local g = self.ghostChip
	if g == nil then
		g = buildChip()
		g.frame.Name = "Ghost"
		g.frame.Parent = self.ghostLayer
		self.ghostChip = g
	end
	return g
end

local function makeDisc(self: Structures, name: string, z: number): any
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundTransparency = BLAST_FILL_T
	f.BorderSizePixel = 0
	f.ZIndex = z
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = f
	local s = Instance.new("UIStroke")
	s.Thickness = 2
	s.Transparency = BLAST_RING_T
	s.Parent = f
	f.Parent = self.ghostLayer
	return { frame = f, stroke = s }
end

-- TWO RINGS, NOT ONE. Upstream's warheads have an inner radius that is
-- annihilation and an outer one that is falloff, and a single circle would be
-- lying about whichever of the two it drew.
local function ghostBlast(self: Structures): any
	local b = self.ghostBlast
	if b == nil then
		b = { outer = makeDisc(self, "Blast", 1), inner = makeDisc(self, "BlastCore", 2) }
		self.ghostBlast = b
	end
	return b
end

-- The blast is measured in TILES and drawn in PIXELS, so it is re-sized on
-- every zoom -- the same rule the rails follow, and the only thing in this
-- module besides them with a width in tiles.
local function sizeBlast(self: Structures)
	local g = self.ghost
	local b = self.ghostBlast
	if g == nil or b == nil or g.outer == nil then
		return
	end
	local o = math.max(8, g.outer * 2 * self.zoom)
	local i = math.max(4, (g.inner or g.outer * 0.4) * 2 * self.zoom)
	b.outer.frame.Size = UDim2.fromOffset(o, o)
	b.inner.frame.Size = UDim2.fromOffset(i, i)
end

local function hideGhost(self: Structures)
	if self.ghostChip ~= nil then
		self.ghostChip.frame.Visible = false
	end
	if self.ghostBlast ~= nil then
		self.ghostBlast.outer.frame.Visible = false
		self.ghostBlast.inner.frame.Visible = false
	end
	self.ghost = nil
end

-- `g` is nil to hide the ghost, or a table:
--   tile   where it is DRAWN. For a port that is the SNAPPED coast tile and
--          not the one under the cursor -- the jump IS the feedback.
--   state  "ok" | "upgrade" | "bad"
--   kind   a structure kind, to draw the chip. Absent for a warhead.
--   level  the level the chip would BE, so an upgrade preview is the size of
--          the building it is about to become rather than the one there now.
--   inner  blast radii IN TILES. Absent for a building.
--   outer
function Structures.setGhost(self: Structures, g: any?)
	if g == nil then
		hideGhost(self)
		return
	end
	self.ghost = g
	local ink = GHOST_INK[g.state] or GHOST_INK.ok
	local x = g.tile % W
	local y = (g.tile - x) / W
	local pos = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)

	if g.kind ~= nil then
		local m = ghostChip(self)
		m.frame.Visible = true
		m.frame.Position = pos
		if m.kind ~= g.kind then
			m.kind = g.kind
			applyKind(m, g.kind)
		end
		local level = math.max(1, g.level or 1)
		if m.level ~= level then
			m.level = level
			sizeChip(m, level)
			m.label.Visible = level > 1
			m.label.Text = level > 1 and tostring(level) or ""
		end
		-- THE RING CARRIES THE STATE AND NOTHING ELSE DOES. The plate and the
		-- sprite stay the building's own colours, or the preview stops being a
		-- preview of anything -- a red house is not what gets built.
		m.frame.BackgroundColor3 = ink
		siteLook(m, true)
		-- A refusal dims the sprite too. A red ring around a full-strength
		-- house reads as "here it is"; the point is that it is not.
		m.glyph.ImageTransparency = g.state == "bad" and 0.72 or SITE_GLYPH_T
	elseif self.ghostChip ~= nil then
		self.ghostChip.frame.Visible = false
	end

	if g.outer ~= nil then
		local b = ghostBlast(self)
		b.outer.frame.Visible = true
		b.inner.frame.Visible = true
		b.outer.frame.Position = pos
		b.inner.frame.Position = pos
		b.outer.frame.BackgroundColor3 = ink
		b.inner.frame.BackgroundColor3 = ink
		b.outer.stroke.Color = ink
		b.inner.stroke.Color = ink
		sizeBlast(self)
	elseif self.ghostBlast ~= nil then
		self.ghostBlast.outer.frame.Visible = false
		self.ghostBlast.inner.frame.Visible = false
	end
end

local function stepGhost(self: Structures, dt: number)
	if self.ghost == nil then
		return
	end
	sizeBlast(self)
	self.ghostT += dt
	local k = 0.5 + 0.5 * math.sin(self.ghostT * GHOST_PULSE_RATE)
	local m = self.ghostChip
	if m ~= nil and m.frame.Visible then
		m.stroke.Transparency = SITE_STROKE_T * (0.35 + 0.65 * k)
		m.frame.BackgroundTransparency = SITE_FRAME_T * (0.5 + 0.5 * k)
	end
	local b = self.ghostBlast
	if b ~= nil and b.outer.frame.Visible then
		b.outer.stroke.Transparency = BLAST_RING_T + 0.35 * k
		b.inner.stroke.Transparency = BLAST_RING_T + 0.35 * k
	end
end

-- THE CROWDING AND UPGRADE TESTS, ON THE CLIENT. Twin of Economy.nearby ->
-- Units.closest (Units:1158), which walks the server's unit grid; there is no
-- grid here, so this walks the markers -- which IS every structure on the
-- map, sites included, because that is exactly what the client is sent.
--
-- Called for ONE tile a few times a second while a build is armed, so a
-- linear pass over a few hundred chips is the right shape and a spatial index
-- would be a second thing to keep correct in exchange for nothing.
--
-- `finishedOnly` is the difference between the server's two calls and it is
-- load-bearing: the CROWDING test counts sites (two sites half a tile apart
-- are as illegal as two finished buildings), the UPGRADE test must not, or a
-- click would level a building that is not standing yet.
--
-- Euclidean and squared, exactly as the server does it.
function Structures.nearest(
	self: Structures,
	tile: number,
	radius: number,
	ownerId: number?,
	kind: number?,
	finishedOnly: boolean?
): (any?, number?)
	local qx = tile % W
	local qy = (tile - qx) / W
	local r2 = radius * radius
	local best: any, bestTile: number?, bestD = nil, nil, math.huge
	for t, m in self.byTile do
		if
			(ownerId == nil or m.ownerId == ownerId)
			and (kind == nil or m.kind == kind)
			and (finishedOnly ~= true or m.site ~= true)
		then
			local ux = t % W
			local dx = ux - qx
			local dy = (t - ux) / W - qy
			local d = dx * dx + dy * dy
			if d <= r2 and d < bestD then
				best, bestTile, bestD = m, t, d
			end
		end
	end
	return best, bestTile
end

-- =================================================================== rails ==

local function railKey(a: number, b: number): string
	-- Order-independent: the server may name the same line either way round.
	return a < b and (a .. ":" .. b) or (b .. ":" .. a)
end

-- ONE STRIP HOLDS n TIES, EACH CENTRED IN ITS OWN CELL OF TIE_GAP. Because the
-- cells are equal the pattern is the same for every strip with the same n, so
-- these five sequences are every tie pattern the game will ever draw and they
-- are built once at load.
--
-- Hard edges cost two keypoints each -- a tie is (just before, opaque),
-- (start, solid), (end, solid), (just after, opaque) -- and Roblox rejects two
-- keypoints at the same time, hence the epsilon. Interpolate instead and a
-- "tie" becomes a triangular smear the width of the gap, which reads as a
-- pulsing band rather than as sleepers.
local TIE_SEQ: { NumberSequence } = {}
do
	local EPS = 1 / 512
	for n = 1, TIES_PER_STRIP do
		local half = (TIE_ALONG / 2) / (n * TIE_GAP)
		local kp = { NumberSequenceKeypoint.new(0, 1) }
		for k = 1, n do
			local c = (k - 0.5) / n
			table.insert(kp, NumberSequenceKeypoint.new(c - half - EPS, 1))
			table.insert(kp, NumberSequenceKeypoint.new(c - half, 0))
			table.insert(kp, NumberSequenceKeypoint.new(c + half, 0))
			table.insert(kp, NumberSequenceKeypoint.new(c + half + EPS, 1))
		end
		table.insert(kp, NumberSequenceKeypoint.new(1, 1))
		TIE_SEQ[n] = NumberSequence.new(kp)
	end
end

-- One rotated rectangle of track, sized in TILES and centred on (cx, cy) in
-- tile coordinates. The +0.5 is the tile's own centre, the same convention
-- every marker position here uses.
local function railPiece(
	parent: Frame,
	name: string,
	cx: number,
	cy: number,
	along: number,
	across: number,
	deg: number,
	colour: Color3,
	transparency: number
): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = colour
	f.BackgroundTransparency = transparency
	f.BorderSizePixel = 0
	f.ZIndex = 4
	f.Position = UDim2.fromScale((cx + 0.5) / W, (cy + 0.5) / H)
	-- Length along the map's X scale and thickness along its Y scale: the
	-- container is (W*zoom, H*zoom) px, so this renders as (along*zoom,
	-- across*zoom) and the rotation is a pixel-space rotation of a
	-- correctly-proportioned rectangle.
	f.Size = UDim2.fromScale(along / W, across / H)
	f.Rotation = deg
	f.Parent = parent
	return f
end

function Structures.setRail(self: Structures, a: number, b: number, pts: { number }?)
	local key = railKey(a, b)
	local existing = self.railByKey[key]
	if existing then
		for _, seg in existing.segments do
			seg:Destroy()
		end
		self.railByKey[key] = nil
	end
	if not pts or #pts < 2 then
		return
	end

	-- The straight runs first, because the ties are laid along them and the
	-- rails are laid over the ties -- two passes, in that order, so the rail
	-- crosses every sleeper it runs on rather than disappearing under the
	-- next run's. Equal ZIndex breaks in favour of the later child, which is
	-- the whole ordering mechanism here.
	local runs = {}
	for i = 1, #pts - 1 do
		local t0, t1 = pts[i], pts[i + 1]
		local x0, x1 = t0 % W, t1 % W
		local y0 = (t0 - x0) / W
		local y1 = (t1 - x1) / W
		local dx, dy = x1 - x0, y1 - y0
		local len = math.sqrt(dx * dx + dy * dy)
		if len > 0 then
			table.insert(runs, {
				x = x0, y = y0,
				ux = dx / len, uy = dy / len,
				len = len,
				deg = math.deg(math.atan2(dy, dx)),
			})
		end
	end

	local segments = {}
	for _, r in runs do
		-- WHOLE CELLS ONLY, CENTRED ON THE RUN. A run shorter than one cell
		-- gets no sleeper at all -- it is a couple of tiles of corner between
		-- two long legs, and a tie there would land on top of the tie the leg
		-- either side already has. The leftover is split between the two ends,
		-- so the spacing never bunches up against a corner.
		local cells = math.floor(r.len / TIE_GAP)
		local head = (r.len - cells * TIE_GAP) / 2
		local done = 0
		while done < cells do
			local n = math.min(TIES_PER_STRIP, cells - done)
			local along = n * TIE_GAP
			local mid = head + done * TIE_GAP + along / 2
			local strip = railPiece(
				self.railLayer, "Ties",
				r.x + r.ux * mid, r.y + r.uy * mid,
				along, TIE_ACROSS, r.deg, TIE_INK, TIE_T
			)
			local grad = Instance.new("UIGradient")
			grad.Transparency = TIE_SEQ[n]
			grad.Parent = strip
			table.insert(segments, strip)
			done += n
		end
	end
	for _, r in runs do
		table.insert(segments, railPiece(
			self.railLayer, "Rail",
			r.x + r.ux * r.len / 2, r.y + r.uy * r.len / 2,
			r.len, RAIL_THICK, r.deg, RAIL_INK, RAIL_T
		))
	end
	self.railByKey[key] = { segments = segments }
end

function Structures.setAllRails(self: Structures, list: { any })
	for key, r in self.railByKey do
		for _, seg in r.segments do
			seg:Destroy()
		end
		self.railByKey[key] = nil
	end
	for _, r in list do
		Structures.setRail(self, r.a, r.b, r.pts)
	end
end

-- ================================================================ vehicles ==

-- Which pixel sprite a vehicle kind draws with, or nil for the ones that stay
-- coloured chips: a train runs on a rail and a shell is in flight for five
-- seconds, and neither is a boat.
local BOAT_ART = {
	[Structures.TRADING_BOAT] = "trade",
	[Structures.TRANSPORT_BOAT] = "transport",
	[Structures.GUNBOAT] = "gunboat",
}

-- The sprite is square and 16x16, but the boat inside it is not: it occupies
-- the middle band, so a marker sized to the old chip's diameter would draw a
-- boat about half that. Scaled up to compensate, per boat.
local BOAT_SCALE = 2.1

-- HOW TALL EACH DRAWING ACTUALLY IS INSIDE ITS 16x16 CANVAS, measured off the
-- ink layer's alpha bounding box rather than trusted from the art notes. This
-- is the other half of "ships of the same type are the same size": the frame is
-- square and ScaleType.Fit maps the whole canvas into it, so a heading whose
-- drawing is 9 cells tall renders 12% bigger than the same boat's 8-cell side
-- view -- one boat, visibly two sizes, changing every time it turns a corner.
-- Every heading is fitted to the SIDE view, which is the one two of the four
-- headings already use.
--
-- Height and not width, deliberately: a hull seen bow-on IS shorter than the
-- same hull seen side-on, and normalising the long axis would blow the vertical
-- views up into blobs. A boat does not change HEIGHT when it turns.
local HULL_H: { [string]: { [string]: number } } = {
	trade = { r = 14, l = 14, u = 15, d = 14 },
	transport = { r = 15, l = 15, u = 15, d = 14 },
	gunboat = { r = 8, l = 8, u = 8, d = 8 },
}
local function hullFit(art: string?, facing: string): number
	local h = art ~= nil and HULL_H[art] or nil
	if h == nil then
		return 1
	end
	return h.r / h[facing]
end

-- THERE WAS A ROLL HERE -- every boat rocking three and a half degrees off its
-- own beat, so that a boat becalmed at a blockade still read as AFLOAT -- AND
-- THE OWNER CUT IT (2026-09-02, "turn off the ship wobbling as if its on a
-- wave, i dont like it"). Do not put it back. It is the second idle-motion
-- effect to go the same way after the white wave trails, and the rule the two
-- add up to is worth keeping: motion on this map is allowed to carry
-- information -- the heading swap, the list of a sinking hull -- and nothing
-- moves for atmosphere.

-- Tiles a marker may jump between two sends before it is treated as a
-- different vehicle rather than a moving one. The fastest thing here covers
-- fifteen; anything past sixty is an id reused or a client that has been
-- asleep in a background tab.
local TELEPORT_TILES = 60

-- How far a flying shell may be from the newest position the server sent for it
-- before the client stops believing its own integration and puts it back on the
-- line. A shell is the one marker the client flies itself (see flyShell), and in
-- steady state it sits about ONE send -- fifteen tiles -- behind that newest
-- position, so three sends out is not drift, it is a client that joined mid
-- flight or woke up in a background tab.
local SHELL_SNAP_TILES = 45

-- ================================================================== wake ====
--
-- A TROOP TRANSPORT DRAGS ITS WHOLE ROUTE BEHIND IT -- from the coast it
-- sailed off to wherever it is now -- and the line dies with the transport boat: it
-- lands, or it is shelled, and the wake drains away after it.
--
-- NOTHING ELSE AFLOAT GETS ONE, on purpose. A trading boat shuttles the same two
-- ports all game and a train runs a rail that is already drawn on the map, so
-- a line behind either is a line you already knew about. A transport is the
-- one vehicle whose ORIGIN is information: it is an invasion, and the coast it
-- came from is the empire that launched it and the direction the answer has to
-- go. Before this you saw a transport boat appear off your shore with no idea whose it
-- was until it landed.
--
-- IT IS PAINTED INTO THE WATER PIXELS THEMSELVES (2026-09-01, owner: "draw
-- them into the water pixels instead of something overlaying on top"), which
-- replaced a chain of rotated Frames laid over the map. Every tile the hull
-- crosses is stamped into the renderer's map image the way fallout stamps
-- irradiated ground -- Renderer.setWake -- so the route is part of the sea
-- rather than a thing standing on it. What that buys:
--   * It sits UNDER every marker, rail and boat by construction, with no
--     ZIndex ordering to keep in step.
--   * It cannot cut a corner or shear. The old line was a chord between two
--     sends and needed a bend tolerance, a subdivision count and a re-laid
--     head frame to stop it crossing headlands; a stamped tile is on the
--     route or it is not.
--   * A route up a river is exactly as wide as the river.
-- THE COST is that a wake is ONE TILE wide at every zoom -- one screen pixel
-- at DEFAULT_ZOOM -- where the old frame was three screen pixels at any zoom.
-- That is what sets the tint strength in the renderer: a hairline has to win
-- its pixel outright or it reads as noise on the water.
--
-- Tiles one transport's route may hold. The longest crossing that can exist is
-- the diagonal of the largest map here (1600x1000 -> 1,887 tiles), so 2,000
-- never truncates a real route and only bounds a transport that somehow never
-- lands: Config.TRANSPORT_BOAT_MAX_PER_PLAYER is 3 and a full roster is 72
-- empires, so one that sails forever must not be able to allocate for the rest
-- of the round. Past it the OLDEST tile is erased, which leaves a long tail
-- rather than a frozen line.
local WAKE_MAX_TILES = 2000
-- How long the route takes to go once the boat has, and it drains from the FAR
-- END -- the coast it left -- toward where the crossing ended, so the last
-- thing on screen is the landing.
local WAKE_FADE = 0.45

-- THERE WAS A SECOND TRAIL HERE -- a short white one, on every boat, meant to
-- read as the water the hull is pushing -- AND THE OWNER CUT IT (2026-09-01,
-- "remove wave trails behind ships"). Do not put it back. The route line above
-- survives because it is INFORMATION: whose invasion this is and which coast
-- it sailed from. Decoration behind a ten-pixel marker is not.
--
-- The colour stays because the sinking ring below is drawn in it.
local FOAM = Color3.fromRGB(232, 244, 255)

-- The Catmull-Rom the MARKER is drawn along, evaluated at `a` across the
-- middle stretch. Shared with Structures.step rather than written twice: a
-- wake is only worth drawing if it is the line the boat was seen to take, and
-- two copies of this expression are two chances for it not to be.
local function curveAt(v: any, a: number): (number, number)
	local a2 = a * a
	local a3 = a2 * a
	local x = 0.5 * (2 * v.p1x
		+ (v.p2x - v.p0x) * a
		+ (2 * v.p0x - 5 * v.p1x + 4 * v.p2x - v.p3x) * a2
		+ (3 * v.p1x - v.p0x - 3 * v.p2x + v.p3x) * a3)
	local y = 0.5 * (2 * v.p1y
		+ (v.p2y - v.p0y) * a
		+ (2 * v.p0y - 5 * v.p1y + 4 * v.p2y - v.p3y) * a2
		+ (3 * v.p1y - v.p0y - 3 * v.p2y + v.p3y) * a3)
	return x, y
end

-- A ROUTE IS A LIST OF TILES, in the order the hull crossed them, and the
-- OWNER is fixed at launch -- a transport is the one boat here that cannot
-- change hands (piracy captures trading boats and SINKS transports,
-- Gunboats.shellImpact), so a stamped tile never needs re-tinting.
--
-- The list is what the pixels cannot tell you afterwards: which tiles are
-- THIS route's, so it can be erased without touching anybody else's, drained
-- from the old end, or put back after a zoom-out wiped it. `first` is where
-- the live part starts -- erasing from the old end moves it forward instead
-- of shifting two thousand entries down one -- and `last` is the tile stamped
-- most recently, so a boat that has not left its tile this frame costs a
-- comparison. `tx, ty` is where the stamp got to, which is what lets the gap
-- between two frames be filled in rather than dotted.
local function newTrail(v: any): any
	return {
		tiles = {},
		first = 1,
		n = 0,
		ownerId = v.ownerId,
		last = -1,
		tx = -1,
		ty = -1,
	}
end

-- One tile of route. LAND IS REFUSED BY THE RENDERER, not here -- a crossing
-- ends ON a beach and a landing must not leave a coloured pixel on the coast
-- -- but the tile still goes in the list, because the list is also what a
-- zoom-out erases and a zoom-in puts back, and it has to describe the route
-- rather than what happened to be paintable when the boat passed.
local function stampTile(self: Structures, tr: any, tx: number, ty: number)
	local i = ty * W + tx
	if i == tr.last then
		return
	end
	tr.last = i
	local n = tr.n + 1
	tr.n = n
	tr.tiles[n] = i
	local r = self.renderer
	if r ~= nil and self.wakesShown then
		r:setWake(i, tr.ownerId)
	end
	if n - tr.first + 1 > WAKE_MAX_TILES then
		local oldest = tr.tiles[tr.first]
		tr.tiles[tr.first] = nil
		tr.first += 1
		if r ~= nil then
			r:clearWake(oldest, tr.ownerId)
		end
	end
end

-- EVERY TILE BETWEEN WHERE THE STAMP GOT TO AND WHERE THE HULL IS NOW. A boat
-- covers a fraction of a tile per frame and several after a stall, so the line
-- between the two is walked rather than its endpoints stamped: stamping the
-- ends alone leaves a dotted route the moment anything hurries. Bresenham, so
-- the tiles are 8-connected and a diagonal has no holes in it.
local function stampTo(self: Structures, tr: any, x: number, y: number)
	local tx = math.clamp(math.floor(x + 0.5), 0, W - 1)
	local ty = math.clamp(math.floor(y + 0.5), 0, H - 1)
	if tr.tx < 0 then
		tr.tx, tr.ty = tx, ty
		stampTile(self, tr, tx, ty)
		return
	end
	local x0, y0 = tr.tx, tr.ty
	local dx = math.abs(tx - x0)
	local dy = -math.abs(ty - y0)
	local sx = x0 < tx and 1 or -1
	local sy = y0 < ty and 1 or -1
	local err = dx + dy
	while x0 ~= tx or y0 ~= ty do
		local e2 = err * 2
		if e2 >= dy then
			err += dy
			x0 += sx
		end
		if e2 <= dx then
			err += dx
			y0 += sy
		end
		stampTile(self, tr, x0, y0)
	end
	tr.tx, tr.ty = tx, ty
end

-- Every tile this route still holds goes back to open water. The list is
-- emptied with it, so this is also how a route is retired.
local function eraseTrail(self: Structures, tr: any)
	local r = self.renderer
	if r ~= nil then
		for k = tr.first, tr.n do
			r:clearWake(tr.tiles[k], tr.ownerId)
		end
	end
	table.clear(tr.tiles)
	tr.first, tr.n, tr.last = 1, 0, -1
end

-- A marker that jumped further than anything afloat could is a reused id, not
-- a transport boat, so the line it inherited is somebody else's route. The
-- stamp position goes too, or the next frame draws a line from the old boat's
-- water to the new one's.
local function clearTrail(self: Structures, tr: any)
	eraseTrail(self, tr)
	tr.tx, tr.ty = -1, -1
end

-- The transport boat is gone: it landed, or it was shelled. The wire does not say which
-- and the line means the same either way -- this crossing is over -- so the
-- whole route goes. Draining rather than popping, because a route that has just
-- delivered an invasion is worth the half second it takes to see where it came
-- from.
--
-- IT CANNOT BE A TWEEN ANY MORE: there is no instance to fade, only pixels in
-- the map image, so the route is handed to `self.fading` and Structures.step
-- erases a prefix of it per frame. Oldest tile first, which is both what a
-- wake actually does and what leaves the landing on screen longest.
local function fadeTrail(self: Structures, tr: any)
	if tr.n < tr.first then
		return
	end
	tr.age = 0
	tr.origin = tr.first
	tr.total = tr.n - tr.first + 1
	local list = self.fading
	list[#list + 1] = tr
end

local function stepFades(self: Structures, dt: number)
	local list = self.fading
	for k = #list, 1, -1 do
		local tr = list[k]
		tr.age += dt
		local a = tr.age / WAKE_FADE
		if a >= 1 then
			eraseTrail(self, tr)
			table.remove(list, k)
		else
			-- Where the drain has got to, measured from where the route started
			-- rather than from wherever the last frame left `first`, so a long
			-- route and a short one both take WAKE_FADE.
			local target = tr.origin + math.floor(tr.total * a)
			local r = self.renderer
			while tr.first < target do
				if r ~= nil then
					r:clearWake(tr.tiles[tr.first], tr.ownerId)
				end
				tr.tiles[tr.first] = nil
				tr.first += 1
			end
		end
	end
end

-- ZOOMED OUT PAST THE MARKERS, THE ROUTES GO WITH THEM -- and since they are
-- pixels in the map now, going means being erased. The tile lists survive, so
-- zooming back in stamps every one of them again. Worth the pass: below
-- MIN_VISIBLE_ZOOM a one-tile line is a subpixel sample, which the map image
-- draws as a dotted rash of colour on the sea, under boats that are no longer
-- being drawn at all.
local function showWakes(self: Structures, on: boolean)
	if self.wakesShown == on then
		return
	end
	self.wakesShown = on
	local r = self.renderer
	if r == nil then
		return
	end
	local function apply(tr: any)
		for k = tr.first, tr.n do
			if on then
				r:setWake(tr.tiles[k], tr.ownerId)
			else
				r:clearWake(tr.tiles[k], tr.ownerId)
			end
		end
	end
	for _, v in self.vehicleById do
		if v.trail ~= nil then
			apply(v.trail)
		end
	end
	for _, tr in self.fading do
		apply(tr)
	end
end

local function makeVehicle(self: Structures, id: number, kind: number, ownerId: number, x: number, y: number): any
	-- THE GUN, NOT THE SHELL. A shell marker is born on the frame the round was
	-- fired and at the muzzle, so the report belongs here rather than anywhere
	-- along the flight -- and the burst at the far end is a separate event that
	-- may never happen at all (see beginTerminal). Attenuated like everything
	-- else on the map, so a duel two screens away is a distant thud.
	if kind == Structures.SHELL then
		Sfx.playAt("Cannon", x, y)
	end

	local art = BOAT_ART[kind]
	-- Every ship is BOAT_SIZE and a shell is SHELL_SIZE. The train is not on
	-- this ladder at all any more: it is the one marker measured in tiles
	-- rather than in pixels, so it has nothing to take from a pixel size. See
	-- TRAIN_LEN.
	local size = (art ~= nil and BOAT_SIZE) or SHELL_SIZE

	if art then
		-- A BOAT. Two stacked ImageLabels: the dark silhouette, which is never
		-- tinted and is what keeps the boat readable against the sea whatever
		-- colour its owner is, and the interior, which is. See Icons.BOATS.
		local set = Icons.BOATS[art]
		local ink = Instance.new("ImageLabel")
		ink.Name = art
		ink.BackgroundTransparency = 1
		ink.AnchorPoint = Vector2.new(0.5, 0.5)
		-- The side view is the reference every other heading is fitted to, so
		-- a boat born facing right is the plain size. See hullFit.
		local px = size * BOAT_SCALE * hullFit(art, "r")
		ink.Size = UDim2.fromOffset(px, px)
		ink.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)
		ink.Image = set.ink.r
		ink.ScaleType = Enum.ScaleType.Fit
		ink.ResampleMode = Enum.ResamplerMode.Pixelated
		ink.ZIndex = 6

		local body = Instance.new("ImageLabel")
		body.Name = "Body"
		body.BackgroundTransparency = 1
		body.Size = UDim2.fromScale(1, 1)
		body.Image = set.body.r
		body.ImageColor3 = Palette.playerColor3(ownerId, self.myId)
		body.ScaleType = Enum.ScaleType.Fit
		body.ResampleMode = Enum.ResamplerMode.Pixelated
		body.ZIndex = 7
		body.Parent = ink

		-- HER HEALTH, over the hull and clear of the sprite's tallest cell --
		-- and on a GUNBOAT only, because she is the only hull that can lose
		-- any (see the HP_BAR header). The lift is DERIVED from the art rather
		-- than guessed: ScaleType.Fit maps the whole 16x16 canvas into a square
		-- frame, and hullFit has already scaled that frame so every heading
		-- draws the same content height -- so the drawing is HULL_H[art].r
		-- sixteenths of the frame tall whichever way she is pointing, and half
		-- of that clears the deck.
		local bar: Frame? = nil
		local fill: Frame? = nil
		if kind == Structures.GUNBOAT then
			local deck = BOAT_SIZE * BOAT_SCALE * HULL_H[art].r / 32
			local track = Instance.new("Frame")
			track.Name = "Health"
			track.AnchorPoint = Vector2.new(0.5, 0.5)
			-- The TRACK is the red: what is missing is the bar showing through
			-- behind what is left, so damage costs a step of green and gains
			-- the same step of red with nothing to keep in sync.
			track.BackgroundColor3 = HP_RED
			track.BorderSizePixel = 0
			track.Size = UDim2.fromOffset(HP_BAR_W, HP_BAR_H)
			-- Offset from the frame's CENTRE, not from its top edge: the frame
			-- is re-fitted whenever she turns (see hullFit) and an edge-relative
			-- bar would hop every time she did.
			track.Position = UDim2.new(0.5, 0, 0.5, -(deck + HP_BAR_LIFT))
			track.ZIndex = 8

			local barEdge = Instance.new("UIStroke")
			barEdge.Color = DARK
			barEdge.Thickness = 1
			barEdge.Transparency = 0.25
			barEdge.Parent = track

			-- What is left, anchored LEFT so it drains toward one end instead
			-- of shrinking about its own middle. Sized in scale inside a bar
			-- sized in offset, so the fraction is the only thing that ever
			-- has to be written.
			local green = Instance.new("Frame")
			green.Name = "Fill"
			green.AnchorPoint = Vector2.new(0, 0.5)
			green.Position = UDim2.fromScale(0, 0.5)
			green.Size = UDim2.fromScale(1, 1)
			green.BackgroundColor3 = HP_GREEN
			green.BorderSizePixel = 0
			green.ZIndex = 9
			green.Parent = track

			track.Parent = ink
			bar, fill = track, green
		end

		ink.Parent = self.vehicleLayer
		local v = {
			id = id,
			frame = ink, body = body, art = set, artName = art, facing = "r",
			bar = bar, fill = fill, hp = 1,
			x = x, y = y, ownerId = ownerId, kind = kind,
			p0x = x, p0y = y, p1x = x, p1y = y, p2x = x, p2y = y, p3x = x, p3y = y,
		}
		-- A ROUTE LINE for a transport and nothing else (see the wake header).
		-- Absent, not empty, on every other kind: `v.trail ~= nil` is the whole
		-- test, and the first tile is stamped by the first step rather than
		-- here, from where the boat is actually being drawn.
		if kind == Structures.TRANSPORT_BOAT then
			v.trail = newTrail(v)
		end
		self.vehicleById[id] = v
		return v
	end

	if kind == Structures.SHELL then
		-- ORDNANCE, AND DRAWN THE WAY THE REST OF THIS MAP IS DRAWN (2026-09-02,
		-- owner: "dont match the style of the rest of the game").
		--
		-- Every boat here is a pixel sprite -- ResamplerMode.Pixelated, a hard
		-- dark outline, no antialiasing anywhere -- and the territory under them
		-- is literally an image of pixels. The shell was two UICorner discs with
		-- a smoothly breathing core: a perfect circle with a soft edge, which is
		-- the one thing on screen that could not have come from the same
		-- spritesheet as everything else. It made the marker that is MEANT to
		-- read as violent read as a rendering artefact instead.
		--
		-- So: squares, no corner radius, one hard dark edge -- and a fuse that
		-- STEPS between two sizes rather than easing between them (see
		-- Structures.step). The two colours and their order are kept, because a
		-- hot core inside a red casing is still what an explosive looks like at
		-- seven pixels, and the burst it leaves is now the same family again.
		local shell = Instance.new("Frame")
		shell.Name = "Shell"
		shell.AnchorPoint = Vector2.new(0.5, 0.5)
		shell.BackgroundColor3 = SHELL_CASE
		shell.BorderSizePixel = 0
		-- Over the boats. A shell is the thing you are meant to be watching, and
		-- it spends its last few frames crossing the boat it was fired at.
		shell.ZIndex = 7
		shell.Size = UDim2.fromOffset(size, size)
		shell.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)

		local edge = Instance.new("UIStroke")
		edge.Color = DARK
		edge.Thickness = 1
		edge.Transparency = 0.15
		edge.Parent = shell

		local core = Instance.new("Frame")
		core.Name = "Core"
		core.AnchorPoint = Vector2.new(0.5, 0.5)
		core.Position = UDim2.fromScale(0.5, 0.5)
		core.Size = UDim2.fromScale(0.5, 0.5)
		core.BackgroundColor3 = SHELL_HOT
		core.BorderSizePixel = 0
		core.ZIndex = 8
		core.Parent = shell

		shell.Parent = self.vehicleLayer
		local v = {
			id = id,
			frame = shell, core = core, x = x, y = y, ownerId = ownerId, kind = kind,
			p0x = x, p0y = y, p1x = x, p1y = y, p2x = x, p2y = y, p3x = x, p3y = y,
			-- Off its id, exactly like a boat's roll: a volley whose shells all
			-- flicker in lockstep reads as one object rather than several. In
			-- WHOLE FLICKER PERIODS rather than radians now -- the fuse is a
			-- two-state blink and its phase is which half of one it starts in.
			burn = (id % 17) / 17 * 2,
			coreHot = -1,
			-- WHAT IT WAS FIRED AT, filled in by the send that carries it. Only
			-- the terminal flight reads it -- see beginTerminal.
			targetId = 0,
		}
		self.vehicleById[id] = v
		return v
	end

	-- A TRAIN, and the whole of what makes it visible on the new track is that
	-- it is built the way the track is. See TRAIN_LEN.
	local f = Instance.new("Frame")
	f.Name = "Train"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = Palette.playerColor3(ownerId, self.myId)
	f.BorderSizePixel = 0
	f.ZIndex = 6
	-- Length along the map's X scale and width along its Y, then rotated onto
	-- the line: the container is (W*zoom, H*zoom) px, so this renders as
	-- (TRAIN_LEN*zoom, TRAIN_WIDE*zoom) at every zoom -- exactly the arithmetic
	-- railPiece does for the rails underneath it, which is the point.
	f.Size = UDim2.fromScale(TRAIN_LEN / W, TRAIN_WIDE / H)
	f.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.15, 0)
	corner.Parent = f

	-- LIGHT, AND IT IS THE ONE OUTLINE ON THIS MAP THAT IS NOT DARK. Every
	-- other marker is a coloured shape standing on pale territory and wants a
	-- dark edge to cut it out; a train is a coloured shape lying on creosoted
	-- sleepers, and a dark edge there is a dark line drawn on a dark line.
	local stroke = Instance.new("UIStroke")
	stroke.Color = INK
	stroke.Thickness = 1
	stroke.Transparency = 0.15
	stroke.Parent = f

	f.Parent = self.vehicleLayer
	local v = {
		id = id,
		frame = f, x = x, y = y, ownerId = ownerId, kind = kind,
		p0x = x, p0y = y, p1x = x, p1y = y, p2x = x, p2y = y, p3x = x, p3y = y,
	}
	self.vehicleById[id] = v
	return v
end

-- WHERE THE SHELL WENT. A shell leaves the vehicle stream on the tick it
-- lands, on the tick its target sinks under somebody else's fire, and on the
-- tick it times out -- and nothing on the wire separates those three, so all
-- three get the same puff. That is the honest reading anyway: something
-- happened here and the shell is gone. Without it a naval duel was two gunboats
-- drifting past each other while their health silently went down.
--
-- Sized in OFFSET like every other marker, so a burst is the same size on
-- screen at any zoom, and parented to the vehicle layer so pan and zoom carry
-- it for free. It is in NO table and nothing owns it but its own tween: the
-- tween grows it, the delay destroys it, and Structures.clear sweeps whatever
-- was still in the air when a round ended.
-- A PIXEL EXPLOSION, IN FRAMES (2026-09-02, the same style note as the shell
-- above). It used to be one antialiased circle easing outward over a third of a
-- second, which on a map drawn entirely in hard pixels read as a soft ripple
-- rather than a detonation. Four hard-edged squares shown in sequence instead:
-- a hot core, a hot square inside a red edge, a cooling red square, then the
-- red edge alone opening and fading. That is how an explosion is drawn in the
-- art everything else here is drawn in, and it is SNAPPIER too -- 0.22 s
-- against 0.34 -- because a stepped burst does not need the tail a tween does
-- to stop looking abrupt.
local BURST_STEP = 0.055
local BURST_FRAMES = {
	{ size = 9, colour = SHELL_HOT, fill = 0, edge = 1 },
	{ size = 17, colour = SHELL_HOT, fill = 0.05, edge = 0.1 },
	{ size = 25, colour = SHELL_CASE, fill = 0.35, edge = 0.25 },
	{ size = 31, colour = SHELL_CASE, fill = 1, edge = 0.55 },
}
-- WHAT A SINKING HULL GETS. A gunboat leaves the vehicle stream on exactly one
-- occasion -- it was destroyed -- so unlike a transport (which also leaves it
-- by LANDING, successfully, on the beach it was aimed at) and unlike a trading
-- boat (which leaves it by reaching a port and paying out), its disappearance
-- is unambiguous and can be drawn as a death. That is why ONLY gunboats sink:
-- for the other two the same animation would be a lie half the time.
--
-- AND IT IS A SINKING, NOT AN EXPLOSION. The burst is kept, because something
-- did detonate, but cut to a shade over a shell's; then the hull LISTS, shrinks
-- and fades under while two rings of foam open where she was. The old version
-- was the burst alone at 1.8, which read as a bomb going off on open water and
-- left the hull itself vanishing between one frame and the next.
local SINK_BURST = 1.15
local SINK_TIME = 0.62
-- Degrees she rolls onto her side on the way down.
local SINK_LIST_DEG = 26
-- The swell closing over her: two rings, the second a beat behind the first, so
-- the water is still moving after the hull has gone.
local RING_SIZE = 34
local RING_TIME = 0.55
local RING_LAG = 0.14

local function spawnBurst(self: Structures, x: number, y: number, scale: number)
	local first = BURST_FRAMES[1]
	local ring = Instance.new("Frame")
	ring.Name = "Burst"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundColor3 = first.colour
	ring.BackgroundTransparency = first.fill
	ring.BorderSizePixel = 0
	ring.ZIndex = 8
	ring.Size = UDim2.fromOffset(first.size * scale, first.size * scale)
	ring.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)

	-- Yellow to red as it grows, which is the order a fireball actually cools
	-- in. The edge is a square stroke, so the last frame is a hard ring rather
	-- than a soft halo.
	local edge = Instance.new("UIStroke")
	edge.Color = SHELL_CASE
	edge.Thickness = 2
	edge.Transparency = first.edge
	edge.Parent = ring

	ring.Parent = self.vehicleLayer

	-- NO TWEEN. The frames are the animation, and stepping them is the whole
	-- point -- a tween between them would put the smooth edge back in the one
	-- axis (time) it had been taken out of. `ring.Parent` going nil is
	-- Structures.clear having swept it mid-burst at the end of a round.
	task.spawn(function()
		for i = 2, #BURST_FRAMES do
			task.wait(BURST_STEP)
			if ring.Parent == nil then
				return
			end
			local f = BURST_FRAMES[i]
			ring.Size = UDim2.fromOffset(f.size * scale, f.size * scale)
			ring.BackgroundColor3 = f.colour
			ring.BackgroundTransparency = f.fill
			edge.Transparency = f.edge
		end
		task.wait(BURST_STEP)
		ring:Destroy()
	end)
end

-- ================================================== a shell's last stretch ==
--
-- WHY A SHELL FINISHES ITS RUN AFTER IT HAS LEFT THE WIRE (2026-09-02, owner:
-- "they dont hit the right, explode too early").
--
-- Every marker on this map is drawn ONE SEND BEHIND the server -- see
-- setVehicles, where that lag is bought deliberately to make boats move
-- smoothly. For a boat it is invisible. For a shell it was the entire bug: a
-- shell covers FIFTEEN TILES A SEND (it is the fastest thing here, and
-- TELEPORT_TILES is sized off exactly that figure), so at the moment it left
-- the stream the client was still drawing it one to two sends short of the
-- hull it had just hit -- and the burst went off in open water fifteen to
-- thirty tiles behind the target, while the shell itself simply vanished
-- without ever arriving.
--
-- NO AMOUNT OF INTERPOLATION FIXES THAT. At 2 Hz the impact point is not
-- knowable to better than half a send in either direction, so guessing it
-- forward just swaps undershoot for overshoot. The shell therefore carries the
-- unit id of WHAT IT WAS FIRED AT (Gunboats.vehicles -> Net.packVehicles, four
-- bytes on shell records only), and when it drops off the stream it flies the
-- rest of the way to wherever that target is being DRAWN and detonates there.
--
-- What that buys: the burst lands exactly on the hull the player is watching,
-- in the same lagged frame that hull is drawn in. What it costs: the burst is
-- about three quarters of a second later than the tick the server applied the
-- damage on -- which is the lag every other marker on this map already has,
-- and which nothing on screen contradicts, because the damage itself is only
-- ever seen through the health bar of a boat that is also drawn a send behind.
--
-- The cap is for the case the geometry cannot happen: a target that stops
-- being drawn while the shell is still closing leaves the shell chasing a
-- frozen point, and one that somehow never gets reached would otherwise fly
-- forever.
local TERMINAL_MAX = 1.4

-- `v.tgt` is the target's vehicle entry, resolved by the caller BEFORE the
-- removal sweep nilled anything -- see setVehicles for why that ordering is
-- load-bearing. It may already be off the stream itself (a transport dies to
-- one shell, so the shot that lands takes both markers out in the same send);
-- the table is still a table, it simply stops being stepped, which is exactly
-- right -- the shell flies to where the hull was last seen and bursts on it.
local function beginTerminal(self: Structures, v: any)
	local tgt = v.tgt
	if tgt == nil then
		-- Nothing to fly at: the shell timed out, or its target changed hands.
		-- The puff happens where the shell is, which is the old behaviour and
		-- still the honest one when there was never an impact.
		spawnBurst(self, v.x, v.y, 1)
		v.frame:Destroy()
		return
	end
	v.terminalT = 0
	local list = self.shellsLanding
	list[#list + 1] = v
end

-- A SHELL DOES NOT INTERPOLATE. IT FLIES.
--
-- Everything else on this map is drawn by walking a Catmull-Rom between the
-- last two positions the server sent, which is right for a boat and was quietly
-- wrong for a shell in a third way (2026-09-02, with the two above): the spline
-- is evaluated on the stretch between the SECOND and THIRD of four known
-- points, and a brand new marker has all four seeded to where it was born. So a
-- shell sat perfectly still at the muzzle for its first two sends -- a FULL
-- SECOND, while the real one covered thirty tiles -- and then set off. Half of
-- a two-second flight was spent parked at the gun.
--
-- A shell does not need the spline anyway. Its whole path is one pursuit curve
-- at a constant speed toward a thing the client is already drawing, so the
-- client can simply fly it: from where it was first seen, at the sim's own
-- three tiles a tick, at whatever it was fired at. Both ends run the same
-- pursuit from the same start, and the target it chases is drawn a send behind
-- exactly as the shell is, so the two stay in step by construction rather than
-- by correction -- and the flight is continuous from the first frame the shell
-- exists.
--
-- CHEBYSHEV, not Euclidean, because that is the metric the sim flies in:
-- Gunboats.shellStep moves one tile on BOTH axes at once, so a diagonal run
-- covers three tiles a tick the same as a straight one. Closing a Euclidean
-- gap instead would make every diagonal shot arrive a third late.
local function shellAim(self: Structures, v: any): (number?, number?)
	-- `v.tgt` is set once the shell has left the wire and is flying its last
	-- stretch; before that the target is looked up live, so a shell tracks a
	-- boat that is still moving.
	local tgt = v.tgt or self.vehicleById[v.targetId]
	if tgt ~= nil then
		return tgt.x, tgt.y
	end
	-- NO TARGET ON THE WIRE -- it sank a send before the shell did, which the
	-- sim allows for exactly one send. Aim a send AHEAD along the line the
	-- server itself last moved the shell down, NOT at the shell's newest
	-- position: the newest position is roughly where the shell already is, so
	-- aiming there would count as "arrived" on the next frame and detonate it in
	-- open water. Nil when there is no line yet either -- a shell on its first
	-- send with no target simply holds, which is the one case where standing
	-- still is better than guessing.
	local dx, dy = v.p3x - v.p2x, v.p3y - v.p2y
	if dx == 0 and dy == 0 then
		return nil, nil
	end
	return v.p3x + dx, v.p3y + dy
end

-- Advances one shell a frame. Returns true once it is ON what it is aimed at.
local function flyShell(self: Structures, v: any, dt: number): boolean
	local ax, ay = shellAim(self, v)
	local there = false
	if ax ~= nil and ay ~= nil then
		local dx, dy = ax - v.x, ay - v.y
		local cheb = math.max(math.abs(dx), math.abs(dy))
		local reach = SHELL_TILES_PER_SEC * dt
		there = cheb <= reach
		if there then
			v.x, v.y = ax, ay
		else
			local k = reach / cheb
			v.x += dx * k
			v.y += dy * k
		end
		v.frame.Position = UDim2.fromScale((v.x + 0.5) / W, (v.y + 0.5) / H)
	end

	-- THE FUSE, AND IT BLINKS RATHER THAN BREATHES. This is the whole
	-- difference between a projectile and a dot that slid, and it used to be a
	-- sine -- a smooth analogue wobble on a sprite made of hard pixels, moving
	-- a sub-pixel most frames. Two states at 9 Hz reads as an ember at any zoom
	-- and writes the property only when it actually changes. It is on the CORE
	-- alone, so the casing keeps a fixed size and the thing still reads as one
	-- object.
	v.burn += dt * 9
	local hot = (v.burn % 2 < 1) and 0.34 or 0.62
	if v.coreHot ~= hot then
		v.coreHot = hot
		v.core.Size = UDim2.fromScale(hot, hot)
	end
	return there
end

local function stepLanding(self: Structures, dt: number)
	local list = self.shellsLanding
	local i = 1
	while i <= #list do
		local v = list[i]
		v.terminalT += dt
		local done = v.terminalT >= TERMINAL_MAX or flyShell(self, v, dt)
		if done then
			spawnBurst(self, v.x, v.y, 1)
			v.frame:Destroy()
			list[i] = list[#list]
			list[#list] = nil
		else
			i += 1
		end
	end
end

-- FOAM WHERE SHE WENT DOWN. A ring in the WAKE layer, not the vehicle layer:
-- this is water, and it belongs under the boats still sailing over it. It also
-- means Structures.clear sweeps it for free, since that empties the layer
-- wholesale.
local function spawnRing(self: Structures, x: number, y: number, size: number, lag: number)
	local ring = Instance.new("Frame")
	ring.Name = "Foam"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	ring.ZIndex = 4
	ring.Size = UDim2.fromOffset(4, 4)
	ring.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = ring

	-- The ring is the STROKE, not a fill: a solid white disc on the sea reads as
	-- an object, and a ring reads as a surface being pushed aside.
	local edge = Instance.new("UIStroke")
	edge.Color = FOAM
	edge.Thickness = 2
	edge.Transparency = 0.1
	edge.Parent = ring

	ring.Parent = self.wakeLayer

	local info = TweenInfo.new(RING_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, false, lag)
	TweenService:Create(ring, info, { Size = UDim2.fromOffset(size, size) }):Play()
	TweenService:Create(edge, info, { Transparency = 1, Thickness = 0.5 }):Play()
	task.delay(RING_TIME + lag, function()
		ring:Destroy()
	end)
end

-- SHE WENT DOWN. The marker's OWN frame is handed over to this. The caller has
-- already dropped her from vehicleById, so nothing steps her again: she stays
-- exactly where she sank -- a wreck does not keep sailing -- and destroys
-- herself at the bottom. In no table any more, so Structures.clear sweeps her
-- by name, the same way it sweeps a burst still in the air.
local function spawnSink(self: Structures, v: any)
	-- She is only ever here because she was destroyed -- see the note above --
	-- so this needs none of the qualification a transport leaving the stream
	-- does.
	Sfx.playAt("Sink", v.x, v.y)
	spawnBurst(self, v.x, v.y, SINK_BURST)
	spawnRing(self, v.x, v.y, RING_SIZE, 0)
	spawnRing(self, v.x, v.y, RING_SIZE * 0.7, RING_LAG)

	-- The bar goes NOW rather than listing and shrinking with the hull: it is a
	-- readout, and a readout on a wreck is a number nobody can act on. It is a
	-- child of the frame, so without this it would ride the whole animation
	-- down at full length.
	if v.bar ~= nil then
		v.bar:Destroy()
		v.bar, v.fill = nil, nil
	end

	local hull = v.frame
	hull.Name = "Sinking"
	-- Easing IN, not out: she holds for a moment and then goes. That is the
	-- shape of a hull losing buoyancy; easing out is the shape of something
	-- being deleted.
	local info = TweenInfo.new(SINK_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local under = BOAT_SIZE * BOAT_SCALE * 0.45
	TweenService:Create(hull, info, {
		-- Absolute, not relative: with the roll gone a hull is always square to
		-- the world when she starts down.
		Rotation = SINK_LIST_DEG,
		Size = UDim2.fromOffset(under, under),
		ImageTransparency = 1,
	}):Play()
	if v.body ~= nil then
		-- The tinted interior is a CHILD sized in scale, so it shrinks and rolls
		-- with the hull on its own. Transparency is the one thing that does not
		-- inherit.
		TweenService:Create(v.body, info, { ImageTransparency = 1 }):Play()
	end
	task.delay(SINK_TIME, function()
		hull:Destroy()
	end)
end

-- HOW A MARKER MOVES, AND WHY IT IS DRAWN ONE SEND BEHIND.
--
-- Positions arrive at 2 Hz. Between two of them either boat has covered five
-- tiles, so what the send rate buys on the wire the
-- client has to pay back in motion. It used to walk each marker toward the
-- newest position at an exponential rate, which closes almost all of the gap
-- in the first tenth of a second and then sits still for the rest of the
-- interval -- so every boat on the map lurched, together, twice a second.
-- That is the brickiness; it was never the simulation.
--
-- Instead each marker keeps the last FOUR positions and is drawn along the
-- stretch between the second and third with a Catmull-Rom spline, crossing it
-- in exactly one send interval. Constant speed, no lurch, and -- the part that
-- matters now that boats follow rivers -- the curve BENDS the way the route
-- bends, where a straight line between two sends cuts the corner and crosses
-- the bank. The cost is that a boat is drawn half a second behind the server,
-- which for a marker whose only mechanical event is announced separately (a
-- landing, a payout) nobody can see.
-- IS THERE LAND UNDER -- OR IMMEDIATELY BESIDE -- THIS POINT. Bit 128 of the
-- terrain byte is land, the same bit the renderer reads to decide whether a
-- tile can be irradiated, and the buffer is the renderer's own, borrowed
-- rather than copied. The four-neighbour reach is because a hull stops on the
-- WATER tile it landed from: one tile off a beach has arrived.
--
-- A client with no renderer (between rounds) answers false, which makes the
-- sound this gates simply not happen rather than throw.
local LANDFALL_STEPS = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

local function landfall(self: Structures, x: number, y: number): boolean
	local r = self.renderer
	local terrain = r and r.terrain
	if terrain == nil then
		return false
	end
	local n = buffer.len(terrain)
	local tx = math.floor(x + 0.5)
	local ty = math.floor(y + 0.5)
	for _, d in LANDFALL_STEPS do
		local px = tx + d[1]
		local py = ty + d[2]
		if px >= 0 and px < W and py >= 0 and py < H then
			local i = py * W + px
			if i < n and bit32.btest(buffer.readu8(terrain, i), 128) then
				return true
			end
		end
	end
	return false
end

function Structures.setVehicles(self: Structures, list: { any })
	-- MEASURED, not assumed to be VEHICLE_INTERVAL: the server sends on its
	-- own clock and what matters here is the interval this client is actually
	-- seeing. Smoothed, so one late packet does not slow every boat on the map
	-- for the next half second.
	local now = os.clock()
	local last = self.lastPacket
	if last ~= nil then
		local gap = now - last
		if gap > 0.05 and gap < 3 then
			self.packetDt = self.packetDt * 0.7 + gap * 0.3
		end
	end
	self.lastPacket = now
	self.packetT = 0

	local seen = {}
	for _, e in list do
		seen[e.id] = true
		local v = self.vehicleById[e.id]
		if not v then
			v = makeVehicle(self, e.id, e.kind, e.owner, e.x, e.y)
		elseif v.ownerId ~= e.owner then
			v.ownerId = e.owner
			local colour = Palette.playerColor3(e.owner, self.myId)
			if v.body then
				-- A captured trading boat keeps sailing under its captor's
				-- colours, which is the only notice anyone gets that piracy
				-- happened.
				v.body.ImageColor3 = colour
			else
				v.frame.BackgroundColor3 = colour
			end
		end

		-- HOW MUCH OF HER IS LEFT, as a fraction. Present on GUNBOAT records
		-- only (Net.packVehicles spends one byte a hull on it, and only on the
		-- hulls that have hit points) -- and `v.fill` is a gunboat-only field
		-- for the same reason, so the two halves of this test can never
		-- disagree about which ships carry a bar at all.
		if v.fill ~= nil and e.hp ~= nil and e.hp ~= v.hp then
			v.hp = e.hp
			v.fill.Size = UDim2.fromScale(math.max(e.hp, HP_BAR_MIN), 1)
		end

		-- WHAT A SHELL WAS FIRED AT. Present on shell records only, and refreshed
		-- every send rather than read once, so a client that missed a shell's
		-- first send still knows where that shell is going.
		if e.tid ~= nil then
			v.targetId = e.tid
		end

		-- NOTHING TO COMMIT HERE ANY MORE. The route used to gain a rectangle
		-- per send, laid along the stretch that had just finished being drawn;
		-- now every tile is stamped as the hull crosses it (Structures.step),
		-- so a packet landing is not an event the route cares about.
		v.p0x, v.p0y = v.p1x, v.p1y
		v.p1x, v.p1y = v.p2x, v.p2y
		v.p2x, v.p2y = v.p3x, v.p3y
		v.p3x, v.p3y = e.x, e.y
		-- A marker that has moved further than anything afloat could is not a
		-- boat that moved. Restart its history on the spot rather than drawing
		-- a boat sliding across the map to get there.
		if math.abs(v.p3x - v.p2x) > TELEPORT_TILES or math.abs(v.p3y - v.p2y) > TELEPORT_TILES then
			v.p0x, v.p0y = e.x, e.y
			v.p1x, v.p1y = e.x, e.y
			v.p2x, v.p2y = e.x, e.y
			if v.trail ~= nil then
				clearTrail(self, v.trail)
			end
		end

		-- THE ONE CORRECTION A FLYING SHELL GETS -- see SHELL_SNAP_TILES. Every
		-- other marker is pinned to the wire every frame by the spline; a shell
		-- is integrated, so it needs somewhere to be put back to.
		-- `spent` excluded: that shell has already gone off and its frame is
		-- destroyed, and it only sits here until the send that drops it.
		if v.kind == Structures.SHELL and not v.spent then
			if math.max(math.abs(v.x - v.p3x), math.abs(v.y - v.p3y)) > SHELL_SNAP_TILES then
				v.x, v.y = v.p3x, v.p3y
				v.frame.Position = UDim2.fromScale((v.x + 0.5) / W, (v.y + 0.5) / H)
			end
		end

		-- Which way it is pointing, decided ONCE for the stretch about to be
		-- drawn rather than every frame from a shrinking gap. The deadband is
		-- the whole trick: a route that runs almost due north crosses x by a
		-- hundredth of a tile, and without one the boat flips its sail several
		-- times a second. Half a tile of travel is a heading; less is noise.
		if v.art then
			-- FOUR HEADINGS WHEN THERE IS ART FOR FOUR. Boats move one axis at a
			-- time now (Navy's NEI4), so the heading of a stretch is one of four
			-- -- and a side-on sprite is only right for two of them. A hull
			-- running due north with its starboard side to the camera is exactly
			-- the "moves in an odd way" the rook steps were meant to fix, and no
			-- amount of movement work fixes it: it needs the other two views.
			--
			-- `u` and `d` are OPTIONAL, and this asks Icons rather than assuming.
			-- Until those views exist in Icons.BOATS it falls back to the
			-- horizontal-only rule, which holds the last facing through a vertical
			-- leg exactly as it always did -- so adding the ids IS the wiring.
			local dx = v.p2x - v.p1x
			local dy = v.p2y - v.p1y
			local want = v.facing
			-- The deadband survives the rewrite, and for the same reason: a leg
			-- that is very nearly axis-aligned crosses the other axis by a
			-- hundredth of a tile, and without one the boat flips several times a
			-- second. Half a tile of travel is a heading; less is noise.
			if v.art.ink.u ~= nil and math.abs(dy) > math.abs(dx) then
				if dy > 0.5 then
					want = "d"
				elseif dy < -0.5 then
					want = "u"
				end
			elseif dx > 0.5 then
				want = "r"
			elseif dx < -0.5 then
				want = "l"
			end
			if want ~= v.facing then
				v.facing = want
				v.frame.Image = v.art.ink[want]
				v.body.Image = v.art.body[want]
				-- AND THE FRAME IS RE-FITTED, which is the other half of the
				-- owner's "ships of the same type at least": the four drawings
				-- do not fill their canvases equally. See hullFit.
				local px = BOAT_SIZE * BOAT_SCALE * hullFit(v.artName, want)
				v.frame.Size = UDim2.fromOffset(px, px)
			end
		elseif v.kind == Structures.TRAIN then
			-- WHICH WAY THE ENGINE IS POINTING. A train cannot pick from four
			-- drawings the way a boat does -- it is one rectangle -- so it is
			-- ROTATED, and rotated once per send off the stretch about to be
			-- drawn rather than every frame off a shrinking gap. A rail is a
			-- chain of straight runs, so that is a steady angle down the whole
			-- leg and a hard swing at the corner, which is what a train does.
			-- The deadband is the same idea as the boats': a couple of
			-- hundredths of a tile of drift is not a heading.
			local dx = v.p2x - v.p1x
			local dy = v.p2y - v.p1y
			if dx * dx + dy * dy > 0.25 then
				v.frame.Rotation = math.deg(math.atan2(dy, dx))
			end
		end
	end
	-- TWO PASSES, AND THE ORDER IS LOAD-BEARING. A shell that CONNECTS leaves
	-- the stream in the same send as the thing it hit -- a transport dies to a
	-- single shell -- so a sweep that looked a shell's target up as it went
	-- would fail to find it on exactly the shots that landed, which is to say on
	-- the ones worth drawing. The first pass only COLLECTS, and resolves each
	-- shell's target while vehicleById is still whole.
	local gone = {}
	for id, v in self.vehicleById do
		if not seen[id] then
			if v.kind == Structures.SHELL then
				v.tgt = self.vehicleById[v.targetId]
			end
			gone[#gone + 1] = v
		end
	end
	for _, v in gone do
		if v.kind == Structures.SHELL then
			-- The one marker whose DISAPPEARANCE is an event rather than
			-- bookkeeping -- and the only one that does not end where it stopped
			-- being drawn, because where it stopped being drawn is a send and a
			-- half short of what it hit. See beginTerminal.
			--
			-- Unless it has already arrived and gone off under its own steam, in
			-- which case there is nothing left of it to fly.
			if not v.spent then
				beginTerminal(self, v)
			end
		elseif v.kind == Structures.GUNBOAT then
			-- SHE WENT DOWN. A gunboat is only ever dropped from the stream by
			-- being destroyed, so this needs no confirmation from the wire --
			-- and without it a duel simply ended with one of the two gunboats not
			-- being there any more. Fired from where she was last DRAWN, not from
			-- the server's last position, so the water opens under the hull the
			-- player was watching.
			spawnSink(self, v)
		elseif v.kind == Structures.TRANSPORT_BOAT then
			-- SHE MADE IT, OR SHE DID NOT. A transport leaves the stream on two
			-- occasions and the wire does not separate them -- the beach she was
			-- aimed at, or the bottom. The MAP separates them: a crossing that
			-- finished is drawn ON THE COAST and one that was sunk is drawn in
			-- open water, so the terrain under the last position she was seen at
			-- is the whole test.
			--
			-- It reads the wrong way in exactly one case: a transport shelled on
			-- the last tile of her run. That is a beach landing which also
			-- happens to be the shot that killed her, and there is no version of
			-- that moment where a keel on sand is the wrong sound to hear.
			if landfall(self, v.x, v.y) then
				Sfx.playAt("Landing", v.x, v.y)
			end
		end
		if v.trail ~= nil then
			-- Draining over the same half second the foam above takes to
			-- close, and from the coast end, so what is left last is where
			-- the crossing finished.
			fadeTrail(self, v.trail)
		end
		if v.kind ~= Structures.GUNBOAT and v.kind ~= Structures.SHELL then
			-- A sinking gunboat's frame belongs to spawnSink and a shell's to its
			-- terminal flight; everything else simply stops being drawn.
			v.frame:Destroy()
		end
		self.vehicleById[v.id] = nil
	end
end

-- ==================================================================== step ==

function Structures.step(self: Structures, dt: number, zoom: number)
	-- ABOVE THE ZOOM GATE. A placement preview that disappears when you zoom
	-- out to look for somewhere to put the thing is worse than no preview.
	self.zoom = zoom
	stepGhost(self, dt)
	local want = zoom >= MIN_VISIBLE_ZOOM
	if want ~= self.visible then
		self.visible = want
		self.markLayer.Visible = want
		self.vehicleLayer.Visible = want
		-- The layer still carries the foam a sinking gunboat leaves. The route
		-- lines are not in it any more -- they are pixels in the map image, and
		-- hiding them is a separate pass over their tiles.
		self.wakeLayer.Visible = want
		showWakes(self, want)
	end
	local wantRails = zoom >= MIN_RAIL_ZOOM
	if wantRails ~= self.railsVisible then
		self.railsVisible = wantRails
		self.railLayer.Visible = wantRails
	end

	-- ABOVE THE ZOOM GATE, unlike everything else here: a route whose boat is
	-- gone has to finish draining and let go of its tiles even while the map is
	-- zoomed out past the markers. The erases are no-ops in that state (the
	-- tiles are already back to open water), and what matters is that the
	-- entry leaves `self.fading` instead of waiting there for a zoom-in that
	-- would then stamp a dead route back onto the sea.
	stepFades(self, dt)
	-- ABOVE THE GATE for the same reason: a shell already off the wire has to
	-- finish its run and destroy itself even while the map is zoomed out past
	-- the markers, or it is a frame and a table left behind for the round.
	stepLanding(self, dt)

	if not want then
		return
	end

	-- One clock for the whole layer, because every marker was sent in the same
	-- packet and is therefore the same age. Clamped rather than extrapolated:
	-- a boat that has run out of route holds its last position for the few
	-- frames a late packet costs, which reads as a pause. Guessing past the
	-- end reads as a boat sailing into the beach and reversing.
	self.packetT += dt
	local a = math.clamp(self.packetT / self.packetDt, 0, 1)

	for _, v in self.vehicleById do
		if v.kind == Structures.SHELL then
			-- NOT ON THE SPLINE, and see flyShell for why: a shell flies its own
			-- pursuit at the sim's own speed, which is what stops it sitting at
			-- the muzzle through its first two sends. It drags no route and does
			-- not roll, so that call is the whole of a shell's frame.
			if not v.spent and flyShell(self, v, dt) then
				-- IT ARRIVED, so it goes off NOW rather than waiting for the send
				-- that drops it from the stream. The client's flight and the
				-- server's are the same pursuit offset by the same lag, so
				-- arrival IS the impact -- and holding a shell parked on top of
				-- the boat for the rest of the send was the last half second of
				-- "explodes at the wrong time" left in this.
				--
				-- `spent` rather than deleting the entry: it is still on the
				-- wire, and the send that finally drops it must not burst it a
				-- second time or destroy a frame that has already gone.
				v.spent = true
				spawnBurst(self, v.x, v.y, 1)
				v.frame:Destroy()
			end
			continue
		end
		-- Catmull-Rom through the four known positions, evaluated on the
		-- middle stretch. The tangent at each end comes from the position
		-- either side of it, which is what makes a turn a turn instead of a
		-- corner -- and it costs a handful of multiplies against the two
		-- math.exp calls the exponential smoother spent per marker per frame.
		local x, y = curveAt(v, a)
		if x ~= v.x or y ~= v.y then
			v.x, v.y = x, y
			v.frame.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)
		end
		if v.trail ~= nil then
			-- The water the hull is on RIGHT NOW, stamped into the map. A tile
			-- is written once and never touched again, so a route costs a
			-- handful of pixels a second however long it has got -- and the
			-- line ends exactly under the marker, with no head frame to keep
			-- re-laying and no send-long gap behind it.
			stampTo(self, v.trail, x, y)
		end
	end
end

function Structures.clear(self: Structures)
	hideGhost(self)
	for tile, m in self.byTile do
		m.frame:Destroy()
		self.byTile[tile] = nil
	end
	for key, r in self.railByKey do
		for _, seg in r.segments do
			seg:Destroy()
		end
		self.railByKey[key] = nil
	end
	for id, v in self.vehicleById do
		-- The route this boat had stamped into the sea. The renderer holding
		-- those pixels is destroyed and rebuilt a few lines later in the
		-- client's `init`, so this is belt and braces -- but a clear that left
		-- pixels behind would leave them for the whole of the next round.
		if v.trail ~= nil then
			eraseTrail(self, v.trail)
		end
		v.frame:Destroy()
		self.vehicleById[id] = nil
	end
	for _, tr in self.fading do
		eraseTrail(self, tr)
	end
	table.clear(self.fading)
	-- Shells still flying their last stretch. They are out of vehicleById, so
	-- the loop above did not reach them.
	for _, v in self.shellsLanding do
		v.frame:Destroy()
	end
	table.clear(self.shellsLanding)
	-- The bursts still fading. They are in no table, so they are swept by name;
	-- a round can end with half a dozen of them in the air.
	for _, c in self.vehicleLayer:GetChildren() do
		if c.Name == "Burst" or c.Name == "Sinking" then
			c:Destroy()
		end
	end
	-- The foam still spreading where a hull went down. Nothing else lives in
	-- that layer, so it can simply be emptied -- a pending fade's Destroy on an
	-- already-destroyed frame is a no-op. (The routes themselves are pixels and
	-- were erased above, with the boats that stamped them.)
	self.wakeLayer:ClearAllChildren()
	-- The stream's clock goes with them. A round ends and the next one's first
	-- send would otherwise be drawn against however far through the last
	-- interval this one happened to stop.
	self.lastPacket = nil
	self.packetT = 0
end

function Structures.count(self: Structures): (number, number, number)
	local s, r, v = 0, 0, 0
	for _ in self.byTile do
		s += 1
	end
	for _ in self.railByKey do
		r += 1
	end
	for _ in self.vehicleById do
		v += 1
	end
	return s, r, v
end

return Structures
