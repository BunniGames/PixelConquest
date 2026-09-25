--!strict
-- Conquest :: Structures  (client)
-- Everything drawn ON the map that is not territory: cities, ports, the rails
-- between them, and the ships and trains running on them.
--
-- All of it is parented to the MAP CONTAINER, not the ScreenGui, for the same
-- reason the nation labels are: the camera already sizes and moves that
-- container, so pan and zoom carry every marker for free and nothing here
-- writes a position on the camera's behalf.
--
-- POSITION IS SCALE, SIZE IS OFFSET for the markers. That split is the whole
-- trick: scale pins a marker to its tile through any zoom, offset keeps it a
-- constant readable size on screen the way a pin on a map is. A marker sized
-- in scale would be a quarter of a pixel across at MIN_ZOOM and a dinner plate
-- at 12x.
--
-- RAILS ARE THE EXCEPTION AND ARE SIZED IN SCALE, because a rail is a piece of
-- the map rather than a pin on it -- it has to keep its endpoints. Camera2D
-- sizes the container to exactly (W*zoom, H*zoom), so a Frame of Scale size
-- (len/W, thickness/H) renders as (len*zoom, thickness*zoom) pixels, which is
-- the segment at the right length in any view. Rotation then happens in pixel
-- space, which is why this works at all: if the container's aspect did not
-- match the map's, a rotated scale-sized frame would shear.

local TweenService = game:GetService("TweenService")

local Config = require(script.Parent.Config)
local Palette = require(script.Parent.Palette)
local Icons = require(script.Parent.Icons)

local Structures = {}
Structures.__index = Structures

export type Structures = typeof(setmetatable({} :: any, Structures))

local W = Config.MAP_W
local H = Config.MAP_H

Structures.CITY = 1
Structures.PORT = 2
-- Structure kinds are Units type ids on the wire, so this is 6 and not 3.
-- A factory turns the cities and ports within STATION_MAX_RANGE of it into
-- train stations and is the only building that dispatches trains.
Structures.FACTORY = 6
-- Vehicle kinds, a separate numbering from the structure kinds above. They
-- collide numerically, which is exactly why they are named.
Structures.SHIP = 1
Structures.TRAIN = 2
-- A transport ship carrying an invasion. Drawn large: it is the only vehicle
-- whose arrival changes who owns territory, so it has to be findable at a
-- glance from across an ocean.
Structures.TRANSPORT = 3
-- A warship is the BIGGEST vehicle marker -- bigger than the transport it
-- hunts, because it is the thing that decides whether that transport ever
-- arrives. A shell is the smallest, and the only marker on this map drawn in
-- nobody's colour: see SHELL_HOT.
Structures.WARSHIP = 4
Structures.SHELL = 5

-- Below this the map is zoomed far enough out that a structure is smaller than
-- the 15-tile spacing rule guarantees between them, so the markers stop being
-- separate objects and become a rash over the territory colours.
local MIN_VISIBLE_ZOOM = 0.7
-- Rails are hairlines; below this they are aliasing rather than infrastructure.
local MIN_RAIL_ZOOM = 0.9

-- Eleven pixels was a pin, not a building. At that size the marker was a
-- coloured speck with something smudged in the middle of it -- you could see
-- THAT there was a city there but never WHICH kind, which is the only question
-- a map marker exists to answer. Eighteen is the smallest that gives the glyph
-- room to be a shape instead of a stain, and it still clears the 15-tile
-- spacing rule at DEFAULT_ZOOM so two neighbours never merge into one blob.
local BASE_SIZE = 20
local PER_LEVEL = 3
local SHIP_SIZE = 7
local TRAIN_SIZE = 6
local TRANSPORT_SIZE = 11
-- THE BIGGEST THING AFLOAT. At 9 a warship drew SMALLER than the transport it
-- hunts and barely larger than a trade ship, so a sea battle read as two chips
-- touching and the one vehicle that shoots was the one you could not find.
-- Sized so the hull and which way it is pointing are both legible at
-- DEFAULT_ZOOM without the marker covering the coast it is fighting over.
--
-- 20 and not 15 (owner, 2026-09-01): the TURRET is the difference between this
-- sprite and a transport, and it is three rows of a sixteen-row grid. At 15 it
-- came out around six pixels of superstructure, which is a bump on a hull
-- rather than a gun -- so the one ship that shoots still read as cargo. The
-- turret is what has to be legible here, not just the hull, and that sets the
-- floor for the whole sprite.
local WARSHIP_SIZE = 20
-- Small, but never a speck: three pixels of flat chip was indistinguishable
-- from a stray pixel of somebody's territory that had got out to sea. It is
-- drawn as ordnance rather than as a marker -- see makeVehicle.
local SHELL_SIZE = 7

local INK = Color3.fromRGB(246, 249, 255)
local DARK = Color3.fromRGB(10, 14, 24)
-- ORDNANCE, and after the rails the only thing here drawn in nobody's colour.
-- A shell used to take its owner's tint, which is information you can already
-- read off the ship that fired it, and which at this size just made it a
-- coloured speck. A hot core inside a red casing is an explosive at any size,
-- and the burst it leaves is the same two colours in the same order.
local SHELL_HOT = Color3.fromRGB(255, 226, 122)
local SHELL_CASE = Color3.fromRGB(214, 58, 30)
-- Rails belong to neither end of the line they join, so they are the one thing
-- on this map drawn in nobody's colour.
local RAIL_INK = Color3.fromRGB(168, 154, 128)
local RAIL_THICK = 1.6 -- in TILES; renders as 1.6 * zoom pixels

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

	-- Four layers, in reading order: a wake is on the water, a station sits ON
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
		-- Under everything else here: a wake is on the water the boats are on.
		wakeLayer = layer("Wakes", 3),
		railLayer = layer("Rails", 4),
		markLayer = layer("Marks", 5),
		vehicleLayer = layer("Vehicles", 6),
		-- tile -> { frame, stroke, label, level, ownerId, kind }
		byTile = {} :: { [number]: any },
		-- "a:b" -> { segments = { Frame } }
		railByKey = {} :: { [string]: any },
		-- vehicle id -> { frame, x, y, p0..p3, ownerId, kind }
		vehicleById = {} :: { [number]: any },
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
	}, Structures)
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

local function makeMarker(self: Structures, tile: number): any
	local x = tile % W
	local y = (tile - x) / W

	local f = Instance.new("Frame")
	f.Name = "Structure"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)
	f.Size = UDim2.fromOffset(BASE_SIZE, BASE_SIZE)
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
	-- 0.66 and not a hair more. What is left over is the owner's colour, and
	-- at level 1 -- which is most cities on the map, most of the time -- that
	-- leftover is the ENTIRE ownership signal: a 0.74 plate left a ring under
	-- two pixels wide, which is a colour you have to go looking for.
	plate.Size = UDim2.fromScale(0.66, 0.66)
	plate.ZIndex = 6
	plate.Parent = f
	local plateCorner = Instance.new("UICorner")
	plateCorner.CornerRadius = UDim.new(0.35, 0)
	plateCorner.Parent = plate

	-- The house / the ship / the factory IN ITS OWN COLOURS, which is the whole
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
	glyph.Size = UDim2.fromScale(0.70, 0.70)
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
	-- A CONSTANT size, not a fraction of the chip: as a fraction it was
	-- illegible on a level 2 and covered half the house on a level 10,
	-- and the chip's own size already says how big the place is.
	lvl.Size = UDim2.fromOffset(12, 12)
	lvl.FontFace = Font.fromEnum(Enum.Font.GothamBold)
	lvl.TextScaled = true
	lvl.TextColor3 = INK
	lvl.TextStrokeTransparency = 0
	lvl.TextStrokeColor3 = DARK
	lvl.Text = ""
	lvl.Visible = false
	lvl.ZIndex = 8
	lvl.Parent = f

	f.Parent = self.markLayer

	local m = {
		frame = f,
		stroke = stroke,
		corner = corner,
		plateCorner = plateCorner,
		glyph = glyph,
		label = lvl,
		level = 0,
		ownerId = 0,
		kind = 0,
	}
	self.byTile[tile] = m
	return m
end

-- One structure, created or updated in place. `level` 0 means it is gone: a
-- razed structure and a captured one arrive on the same channel, so the caller
-- never has to know which kind of event it is holding.
function Structures.set(self: Structures, tile: number, ownerId: number, level: number, kind: number)
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
		local radius
		if kind == Structures.PORT then
			radius = UDim.new(0.5, 0)
			m.glyph.Image = Icons.SHIP
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
	if m.level ~= level then
		m.level = level
		local size = BASE_SIZE + PER_LEVEL * (level - 1)
		m.frame.Size = UDim2.fromOffset(size, size)
		-- The number only appears once it is telling you something a size
		-- comparison cannot: at level 1 every structure is the same and the
		-- digit is noise on an eleven-pixel dot.
		m.label.Visible = level > 1
		m.label.Text = level > 1 and tostring(level) or ""
	end
end

-- The absolute list a joining client gets. Anything not in it is stale from
-- the previous round and has to go, or last round's cities haunt this one.
function Structures.setAll(self: Structures, list: { any })
	local keep = {}
	for _, c in list do
		keep[c.tile] = true
		Structures.set(self, c.tile, c.ownerId, c.level, c.kind or Structures.CITY)
	end
	for tile, m in self.byTile do
		if not keep[tile] then
			m.frame:Destroy()
			self.byTile[tile] = nil
		end
	end
end

-- =================================================================== rails ==

local function railKey(a: number, b: number): string
	-- Order-independent: the server may name the same line either way round.
	return a < b and (a .. ":" .. b) or (b .. ":" .. a)
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

	local segments = {}
	for i = 1, #pts - 1 do
		local t0, t1 = pts[i], pts[i + 1]
		local x0, x1 = t0 % W, t1 % W
		local y0 = (t0 - x0) / W
		local y1 = (t1 - x1) / W
		local dx, dy = x1 - x0, y1 - y0
		local len = math.sqrt(dx * dx + dy * dy)
		if len > 0 then
			local seg = Instance.new("Frame")
			seg.Name = "Rail"
			seg.AnchorPoint = Vector2.new(0.5, 0.5)
			seg.BackgroundColor3 = RAIL_INK
			seg.BackgroundTransparency = 0.25
			seg.BorderSizePixel = 0
			seg.ZIndex = 4
			seg.Position = UDim2.fromScale(((x0 + x1) / 2 + 0.5) / W, ((y0 + y1) / 2 + 0.5) / H)
			-- Length along the map's X scale and thickness along its Y scale:
			-- the container is (W*zoom, H*zoom) px, so this renders as
			-- (len*zoom, RAIL_THICK*zoom) and the rotation is a pixel-space
			-- rotation of a correctly-proportioned rectangle.
			seg.Size = UDim2.fromScale(len / W, RAIL_THICK / H)
			seg.Rotation = math.deg(math.atan2(dy, dx))
			seg.Parent = self.railLayer
			table.insert(segments, seg)
		end
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
	[Structures.SHIP] = "trade",
	[Structures.TRANSPORT] = "transport",
	[Structures.WARSHIP] = "warship",
}

-- The sprite is square and 16x16, but the boat inside it is not: it occupies
-- the middle band, so a marker sized to the old chip's diameter would draw a
-- boat about half that. Scaled up to compensate, per vessel.
local BOAT_SCALE = 2.1

-- Degrees of roll, and how fast. Small on purpose: these are side-on sprites
-- on a map, not a sea, and past about five degrees a boat reads as capsizing
-- rather than floating. What it buys is that a hull becalmed at a blockade or
-- waiting out its last few tiles is still visibly AFLOAT.
local ROCK_DEG = 3.5
-- Below this the hull is a dozen pixels and a three-degree roll is a
-- sub-pixel wobble on hundreds of markers -- all cost, no read. Just above
-- the zoom markers appear at, because DEFAULT_ZOOM is 1.0 and a roll nobody
-- sees in the opening view is not worth writing.
local MIN_ROCK_ZOOM = 0.9

-- Tiles a marker may jump between two sends before it is treated as a
-- different vehicle rather than a moving one. The fastest thing here covers
-- fifteen; anything past sixty is an id reused or a client that has been
-- asleep in a background tab.
local TELEPORT_TILES = 60

-- ================================================================== wake ====
--
-- A TROOP TRANSPORT DRAGS ITS WHOLE ROUTE BEHIND IT -- from the coast it
-- sailed off to wherever it is now -- and the line dies with the boat: it
-- lands, or it is shelled, and the wake fades out after it.
--
-- NOTHING ELSE AFLOAT GETS ONE, on purpose. A trade ship shuttles the same two
-- ports all game and a train runs a rail that is already drawn on the map, so
-- a line behind either is a line you already knew about. A transport is the
-- one vehicle whose ORIGIN is information: it is an invasion, and the coast it
-- came from is the empire that launched it and the direction the answer has to
-- go. Before this you saw a boat appear off your shore with no idea whose it
-- was until it landed.
--
-- MIXED SIZING, which is NEITHER of the two conventions at the top of this
-- file. The LENGTH is scale, like a rail, because both ends are map positions
-- and have to stay on them through any zoom. The THICKNESS is offset, like a
-- marker, because a line 1.4 tiles thick is a hairline at the zoom people
-- actually play at. Rotation is then a pixel-space rotation of a rectangle
-- that is correct in both axes -- the same trick setRail documents, and it
-- works for the same reason: the container's aspect matches the map's.
local WAKE_PX = 3
local WAKE_TRANSPARENCY = 0.45
-- Stretches of wake one transport may hold, one per send. At BOAT_SPEED 3 a
-- send is fifteen tiles, so this is 1,800 tiles of sailing -- longer than the
-- diagonal of the largest map here, and therefore longer than any crossing
-- that can exist. It is a bound, not a length: Config.BOAT_MAX_PER_PLAYER is
-- 3 and a full roster is 72 empires, so a boat that somehow never lands must
-- not be able to allocate for the rest of the round. Past it the oldest
-- stretch is dropped, which leaves a long tail rather than a frozen line.
local WAKE_MAX = 120
local WAKE_FADE = 0.45

local function layWake(seg: Frame, x0: number, y0: number, x1: number, y1: number)
	local dx, dy = x1 - x0, y1 - y0
	seg.Position = UDim2.fromScale(((x0 + x1) / 2 + 0.5) / W, ((y0 + y1) / 2 + 0.5) / H)
	seg.Size = UDim2.new(math.sqrt(dx * dx + dy * dy) / W, 0, 0, WAKE_PX)
	seg.Rotation = math.deg(math.atan2(dy, dx))
end

local function newWakeSeg(self: Structures, v: any): Frame
	local seg = Instance.new("Frame")
	seg.Name = "Wake"
	seg.AnchorPoint = Vector2.new(0.5, 0.5)
	seg.BackgroundColor3 = v.wakeColour
	seg.BackgroundTransparency = WAKE_TRANSPARENCY
	seg.BorderSizePixel = 0
	seg.ZIndex = 3
	seg.Parent = self.wakeLayer
	return seg
end

-- In the OWNER'S colour, fixed at launch. A transport is the one ship here
-- that cannot change hands -- piracy captures trade ships and sinks
-- transports (Warships.shellImpact) -- so this never needs re-tinting.
local function startWake(self: Structures, v: any)
	v.wakeColour = Palette.playerColor3(v.ownerId, self.myId)
	v.wake = {}
	-- THE HEAD IS ONE FRAME, RE-LAID EVERY RENDER, and it is the whole reason
	-- the line has no gap in it. Committed stretches only ever reach p1 -- where
	-- the boat STARTED the stretch currently being drawn -- so without a head
	-- the wake would trail a send's travel behind the hull and snap forward
	-- twice a second, which is the exact lurch the spline was written to kill.
	v.wakeHead = newWakeSeg(self, v)
	layWake(v.wakeHead, v.x, v.y, v.x, v.y)
end

-- The stretch p1 -> p2 has just finished being drawn, so it stops being the
-- head's business and becomes a permanent piece of line.
local function commitWake(self: Structures, v: any)
	local dx, dy = v.p2x - v.p1x, v.p2y - v.p1y
	if dx * dx + dy * dy < 0.25 then
		-- Becalmed at a blockade, or the first send after launch when all four
		-- positions are still the launch tile. A zero-length rectangle is a dot
		-- of colour sitting on the sea.
		return
	end
	local segs = v.wake
	if #segs >= WAKE_MAX then
		local oldest = table.remove(segs, 1)
		if oldest ~= nil then
			oldest:Destroy()
		end
	end
	local seg = newWakeSeg(self, v)
	layWake(seg, v.p1x, v.p1y, v.p2x, v.p2y)
	segs[#segs + 1] = seg
end

-- A marker that jumped further than anything afloat could is a reused id, not
-- a boat, so the line it inherited is somebody else's route.
local function clearWake(v: any)
	for _, seg in v.wake do
		seg:Destroy()
	end
	table.clear(v.wake)
end

-- The boat is gone: it landed, or it was shelled. The wire does not say which
-- and the line means the same either way -- this crossing is over -- so the
-- whole route goes. Fading rather than popping, because a route that has just
-- delivered an invasion is worth the half second it takes to see where it came
-- from. One delayed sweep for the lot rather than one per stretch.
local function fadeWake(v: any)
	local segs = v.wake
	if v.wakeHead ~= nil then
		segs[#segs + 1] = v.wakeHead
		v.wakeHead = nil
	end
	local info = TweenInfo.new(WAKE_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, seg in segs do
		TweenService:Create(seg, info, { BackgroundTransparency = 1 }):Play()
	end
	task.delay(WAKE_FADE, function()
		for _, seg in segs do
			seg:Destroy()
		end
	end)
end

local function makeVehicle(self: Structures, id: number, kind: number, ownerId: number, x: number, y: number): any
	local art = BOAT_ART[kind]
	local size = kind == Structures.TRANSPORT and TRANSPORT_SIZE
		or (kind == Structures.WARSHIP and WARSHIP_SIZE)
		or (kind == Structures.SHELL and SHELL_SIZE)
		or (kind == Structures.SHIP and SHIP_SIZE or TRAIN_SIZE)

	if art then
		-- A BOAT. Two stacked ImageLabels: the dark silhouette, which is never
		-- tinted and is what keeps the hull readable against the sea whatever
		-- colour its owner is, and the interior, which is. See Icons.BOATS.
		local set = Icons.BOATS[art]
		local ink = Instance.new("ImageLabel")
		ink.Name = art
		ink.BackgroundTransparency = 1
		ink.AnchorPoint = Vector2.new(0.5, 0.5)
		ink.Size = UDim2.fromOffset(size * BOAT_SCALE, size * BOAT_SCALE)
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

		ink.Parent = self.vehicleLayer
		local v = {
			frame = ink, body = body, art = set, facing = "r",
			x = x, y = y, ownerId = ownerId, kind = kind,
			p0x = x, p0y = y, p1x = x, p1y = y, p2x = x, p2y = y, p3x = x, p3y = y,
			-- Every hull on its own beat, off its id: a convoy rolling in
			-- unison is a worse artefact than not rolling at all.
			rock = (id % 23) / 23 * 6.2831853,
			rockRate = 1.7 + (id % 7) * 0.13,
		}
		if kind == Structures.TRANSPORT then
			startWake(self, v)
		end
		self.vehicleById[id] = v
		return v
	end

	if kind == Structures.SHELL then
		-- ORDNANCE, NOT A UNIT MARKER. Two concentric discs -- a hot yellow core
		-- inside a red casing -- because that reads as an explosive at seven
		-- pixels where a flat owner-coloured chip read as a rendering artefact.
		-- UIGradient is linear only, so the glow IS the second disc rather than a
		-- radial fill; two frames for a thing that lives about two seconds is
		-- cheaper than an image and needs nothing uploaded.
		local shell = Instance.new("Frame")
		shell.Name = "Shell"
		shell.AnchorPoint = Vector2.new(0.5, 0.5)
		shell.BackgroundColor3 = SHELL_CASE
		shell.BorderSizePixel = 0
		-- Over the hulls. A shell is the thing you are meant to be watching, and
		-- it spends its last few frames crossing the ship it was fired at.
		shell.ZIndex = 7
		shell.Size = UDim2.fromOffset(size, size)
		shell.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)

		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(0.5, 0)
		round.Parent = shell

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
		local coreRound = Instance.new("UICorner")
		coreRound.CornerRadius = UDim.new(0.5, 0)
		coreRound.Parent = core
		core.Parent = shell

		shell.Parent = self.vehicleLayer
		local v = {
			frame = shell, core = core, x = x, y = y, ownerId = ownerId, kind = kind,
			p0x = x, p0y = y, p1x = x, p1y = y, p2x = x, p2y = y, p3x = x, p3y = y,
			-- Off its id, exactly like a hull's roll: a volley whose shells all
			-- flicker in lockstep reads as one object rather than several.
			burn = (id % 17) / 17 * 6.2831853,
		}
		self.vehicleById[id] = v
		return v
	end

	local f = Instance.new("Frame")
	f.Name = "Train"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = Palette.playerColor3(ownerId, self.myId)
	f.BorderSizePixel = 0
	f.ZIndex = 6
	f.Size = UDim2.fromOffset(size, size)
	f.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.15, 0)
	corner.Parent = f

	local stroke = Instance.new("UIStroke")
	stroke.Color = DARK
	stroke.Thickness = 1
	stroke.Transparency = 0.25
	stroke.Parent = f

	f.Parent = self.vehicleLayer
	local v = {
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
-- happened here and the shell is gone. Without it a naval duel was two hulls
-- drifting past each other while their health silently went down.
--
-- Sized in OFFSET like every other marker, so a burst is the same size on
-- screen at any zoom, and parented to the vehicle layer so pan and zoom carry
-- it for free. It is in NO table and nothing owns it but its own tween: the
-- tween grows it, the delay destroys it, and Structures.clear sweeps whatever
-- was still in the air when a round ended.
local BURST_SIZE = 26
local BURST_TIME = 0.34
-- What a SINKING HULL gets, against a shell's 1. A warship leaves the vehicle
-- stream on exactly one occasion -- it was destroyed -- so unlike a transport
-- (which also leaves it by landing, successfully, on the beach it was aimed
-- at) its disappearance is unambiguous, and it is the loudest thing that
-- happens at sea. Nearly twice the shell's burst and nearly twice as long.
local SINK_SCALE = 1.8

local function spawnBurst(self: Structures, x: number, y: number, scale: number)
	local ring = Instance.new("Frame")
	ring.Name = "Burst"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundColor3 = SHELL_HOT
	ring.BorderSizePixel = 0
	ring.ZIndex = 8
	ring.Size = UDim2.fromOffset(SHELL_SIZE * scale, SHELL_SIZE * scale)
	ring.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)

	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = ring

	local edge = Instance.new("UIStroke")
	edge.Color = SHELL_CASE
	edge.Thickness = 2
	edge.Parent = ring

	ring.Parent = self.vehicleLayer

	-- Yellow to red as it grows, which is the order a fireball actually cools
	-- in and what keeps a third of a second of expanding circle reading as heat
	-- rather than as a ripple.
	local life = BURST_TIME * scale
	local info = TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ring, info, {
		Size = UDim2.fromOffset(BURST_SIZE * scale, BURST_SIZE * scale),
		BackgroundColor3 = SHELL_CASE,
		BackgroundTransparency = 1,
	}):Play()
	TweenService:Create(edge, info, { Transparency = 1, Thickness = 0.5 }):Play()
	task.delay(life, function()
		ring:Destroy()
	end)
end

-- HOW A MARKER MOVES, AND WHY IT IS DRAWN ONE SEND BEHIND.
--
-- Positions arrive at 2 Hz. Between two of them a trade ship has covered five
-- tiles and a transport fifteen, so what the send rate buys on the wire the
-- client has to pay back in motion. It used to walk each marker toward the
-- newest position at an exponential rate, which closes almost all of the gap
-- in the first tenth of a second and then sits still for the rest of the
-- interval -- so every hull on the map lurched, together, twice a second.
-- That is the brickiness; it was never the simulation.
--
-- Instead each marker keeps the last FOUR positions and is drawn along the
-- stretch between the second and third with a Catmull-Rom spline, crossing it
-- in exactly one send interval. Constant speed, no lurch, and -- the part that
-- matters now that ships follow rivers -- the curve BENDS the way the route
-- bends, where a straight line between two sends cuts the corner and crosses
-- the bank. The cost is that a hull is drawn half a second behind the server,
-- which for a marker whose only mechanical event is announced separately (a
-- landing, a payout) nobody can see.
function Structures.setVehicles(self: Structures, list: { any })
	-- MEASURED, not assumed to be VEHICLE_INTERVAL: the server sends on its
	-- own clock and what matters here is the interval this client is actually
	-- seeing. Smoothed, so one late packet does not slow every ship on the map
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
				-- A captured trade ship keeps sailing under its captor's
				-- colours, which is the only notice anyone gets that piracy
				-- happened.
				v.body.ImageColor3 = colour
			else
				v.frame.BackgroundColor3 = colour
			end
		end

		if v.wake ~= nil then
			-- BEFORE the shift, while p1 -> p2 is still the stretch that has just
			-- finished being drawn. After it, that stretch is p0 -> p1 and the head
			-- has already moved on.
			commitWake(self, v)
		end
		v.p0x, v.p0y = v.p1x, v.p1y
		v.p1x, v.p1y = v.p2x, v.p2y
		v.p2x, v.p2y = v.p3x, v.p3y
		v.p3x, v.p3y = e.x, e.y
		-- A marker that has moved further than anything afloat could is not a
		-- hull that moved. Restart its history on the spot rather than drawing
		-- a boat sliding across the map to get there.
		if math.abs(v.p3x - v.p2x) > TELEPORT_TILES or math.abs(v.p3y - v.p2y) > TELEPORT_TILES then
			v.p0x, v.p0y = e.x, e.y
			v.p1x, v.p1y = e.x, e.y
			v.p2x, v.p2y = e.x, e.y
			if v.wake ~= nil then
				clearWake(v)
			end
		end

		-- Which way it is pointing, decided ONCE for the stretch about to be
		-- drawn rather than every frame from a shrinking gap. The deadband is
		-- the whole trick: a route that runs almost due north crosses x by a
		-- hundredth of a tile, and without one the boat flips its sail several
		-- times a second. Half a tile of travel is a heading; less is noise.
		if v.art then
			local dx = v.p2x - v.p1x
			if dx > 0.5 and v.facing ~= "r" then
				v.facing = "r"
				v.frame.Image = v.art.ink.r
				v.body.Image = v.art.body.r
			elseif dx < -0.5 and v.facing ~= "l" then
				v.facing = "l"
				v.frame.Image = v.art.ink.l
				v.body.Image = v.art.body.l
			end
		end
	end
	for id, v in self.vehicleById do
		if not seen[id] then
			if v.kind == Structures.SHELL then
				-- The one marker whose DISAPPEARANCE is an event rather than
				-- bookkeeping. Fired from where the shell was last DRAWN, not from
				-- where the server last put it, so the burst lands under the shell
				-- the player was actually watching.
				spawnBurst(self, v.x, v.y, 1)
			elseif v.kind == Structures.WARSHIP then
				-- SHE WENT DOWN. A warship is only ever dropped from the stream by
				-- being destroyed, so this needs no confirmation from the wire --
				-- and without it a duel simply ended with one of the two hulls not
				-- being there any more.
				spawnBurst(self, v.x, v.y, SINK_SCALE)
			end
			if v.wake ~= nil then
				fadeWake(v)
			end
			v.frame:Destroy()
			self.vehicleById[id] = nil
		end
	end
end

-- ==================================================================== step ==

function Structures.step(self: Structures, dt: number, zoom: number)
	local want = zoom >= MIN_VISIBLE_ZOOM
	if want ~= self.visible then
		self.visible = want
		self.markLayer.Visible = want
		self.vehicleLayer.Visible = want
		self.wakeLayer.Visible = want
	end
	local wantRails = zoom >= MIN_RAIL_ZOOM
	if wantRails ~= self.railsVisible then
		self.railsVisible = wantRails
		self.railLayer.Visible = wantRails
	end

	if not want then
		return
	end

	-- One clock for the whole layer, because every marker was sent in the same
	-- packet and is therefore the same age. Clamped rather than extrapolated:
	-- a hull that has run out of route holds its last position for the few
	-- frames a late packet costs, which reads as a pause. Guessing past the
	-- end reads as a boat sailing into the beach and reversing.
	self.packetT += dt
	local a = math.clamp(self.packetT / self.packetDt, 0, 1)
	local a2 = a * a
	local a3 = a2 * a
	local rock = zoom >= MIN_ROCK_ZOOM

	for _, v in self.vehicleById do
		-- Catmull-Rom through the four known positions, evaluated on the
		-- middle stretch. The tangent at each end comes from the position
		-- either side of it, which is what makes a turn a turn instead of a
		-- corner -- and it costs a handful of multiplies against the two
		-- math.exp calls the exponential smoother spent per marker per frame.
		local x = 0.5 * (2 * v.p1x
			+ (v.p2x - v.p0x) * a
			+ (2 * v.p0x - 5 * v.p1x + 4 * v.p2x - v.p3x) * a2
			+ (3 * v.p1x - v.p0x - 3 * v.p2x + v.p3x) * a3)
		local y = 0.5 * (2 * v.p1y
			+ (v.p2y - v.p0y) * a
			+ (2 * v.p0y - 5 * v.p1y + 4 * v.p2y - v.p3y) * a2
			+ (3 * v.p1y - v.p0y - 3 * v.p2y + v.p3y) * a3)
		if x ~= v.x or y ~= v.y then
			v.x, v.y = x, y
			v.frame.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)
		end
		if v.wakeHead ~= nil then
			-- From where the boat started this stretch to where it is being drawn
			-- RIGHT NOW. One frame re-laid; every stretch behind it is committed
			-- and never touched again, so a transport costs one rectangle a render
			-- however long its route has got.
			layWake(v.wakeHead, v.p1x, v.p1y, x, y)
		end
		if v.core ~= nil then
			-- The fuse burning. A shell crosses open water in a couple of seconds
			-- and this is the whole difference between a projectile and a dot that
			-- slid. The pulse is on the CORE alone, so the casing keeps a fixed
			-- size and the thing still reads as one object.
			v.burn += dt * 11
			local hot = 0.42 + 0.16 * math.sin(v.burn)
			v.core.Size = UDim2.fromScale(hot, hot)
		end
		if v.rock ~= nil then
			if rock then
				v.rock += dt * v.rockRate
				v.frame.Rotation = math.sin(v.rock) * ROCK_DEG
			elseif v.frame.Rotation ~= 0 then
				v.frame.Rotation = 0
			end
		end
	end
end

function Structures.clear(self: Structures)
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
		v.frame:Destroy()
		self.vehicleById[id] = nil
	end
	-- The bursts still fading. They are in no table, so they are swept by name;
	-- a round can end with half a dozen of them in the air.
	for _, c in self.vehicleLayer:GetChildren() do
		if c.Name == "Burst" then
			c:Destroy()
		end
	end
	-- Wakes, including any still fading. Nothing but wakes lives in that
	-- layer, so it can simply be emptied -- a pending fade's Destroy on an
	-- already-destroyed frame is a no-op.
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
