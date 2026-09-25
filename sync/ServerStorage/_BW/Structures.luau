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

local Config = require(script.Parent.Config)
local Numbers = require(script.Parent.Numbers)
local Palette = require(script.Parent.Palette)
local Icons = require(script.Parent.Icons)

local Structures = {}
Structures.__index = Structures

export type Structures = typeof(setmetatable({} :: any, Structures))

local W = Config.MAP_W
local H = Config.MAP_H

Structures.CITY = 1
Structures.PORT = 2
-- Vehicle kinds, a separate numbering from the structure kinds above. They
-- collide numerically, which is exactly why they are named.
Structures.SHIP = 1
Structures.TRAIN = 2
-- A transport ship carrying an invasion. Deliberately the biggest marker on
-- the map: it is the only vehicle whose arrival changes who owns territory,
-- so it has to be findable at a glance from across an ocean.
Structures.TRANSPORT = 3
-- A warship is the biggest vehicle marker and a shell the smallest: one
-- decides who owns the sea, the other is in flight for 50 ticks.
Structures.WARSHIP = 4
Structures.SHELL = 5

-- Below this the map is zoomed far enough out that a structure is smaller than
-- the 15-tile spacing rule guarantees between them, so the markers stop being
-- separate objects and become a rash over the territory colours.
local MIN_VISIBLE_ZOOM = 0.7
-- Rails are hairlines; below this they are aliasing rather than infrastructure.
local MIN_RAIL_ZOOM = 0.9

local BASE_SIZE = 11
local PER_LEVEL = 2.5
local SHIP_SIZE = 7
local TRAIN_SIZE = 6
local TRANSPORT_SIZE = 11
local WARSHIP_SIZE = 9
local SHELL_SIZE = 3

local INK = Color3.fromRGB(246, 249, 255)
local DARK = Color3.fromRGB(10, 14, 24)
local SEA_RING = Color3.fromRGB(122, 196, 232)
-- Rails belong to neither end of the line they join, so they are the one thing
-- on this map drawn in nobody's colour.
local RAIL_INK = Color3.fromRGB(168, 154, 128)
local RAIL_THICK = 1.6 -- in TILES; renders as 1.6 * zoom pixels

function Structures.new(container: Frame): Structures
	local root = Instance.new("Frame")
	root.Name = "Economy"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = container

	-- Three layers, in reading order: a station sits ON its lines, and a train
	-- runs OVER both.
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
		railLayer = layer("Rails", 4),
		markLayer = layer("Marks", 5),
		vehicleLayer = layer("Vehicles", 6),
		-- tile -> { frame, stroke, label, level, ownerId, kind }
		byTile = {} :: { [number]: any },
		-- "a:b" -> { segments = { Frame } }
		railByKey = {} :: { [string]: any },
		-- vehicle id -> { frame, x, y, targetX, targetY, ownerId, kind }
		vehicleById = {} :: { [number]: any },
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
		v.frame.BackgroundColor3 = Palette.playerColor3(v.ownerId, id)
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
	stroke.Thickness = 1.5
	stroke.Transparency = 0.15
	stroke.Parent = f

	-- The house / the ship, as a DARK SILHOUETTE inside the owner's colour
	-- rather than the sprite in its own colours. At eleven pixels a full-colour
	-- sticker on a coloured chip is mud; a hole in the chip shaped like a house
	-- is still a house. The ring keeps doing the work at the smallest sizes
	-- (see below) and the shape takes over as you zoom in.
	local glyph = Instance.new("ImageLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.ScaleType = Enum.ScaleType.Fit
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.Size = UDim2.fromScale(0.66, 0.66)
	glyph.ImageColor3 = DARK
	glyph.ZIndex = 6
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
	lvl.ZIndex = 6
	lvl.Parent = f

	f.Parent = self.markLayer

	local m = { frame = f, stroke = stroke, corner = corner, glyph = glyph, label = lvl, level = 0, ownerId = 0, kind = 0 }
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
		-- A port is a circle ringed in sea-blue, a city a rounded square ringed
		-- in near-black. At eleven pixels the RING is what actually reads --
		-- the silhouettes are too close at that size to tell apart alone.
		if kind == Structures.PORT then
			m.corner.CornerRadius = UDim.new(0.5, 0)
			m.stroke.Color = SEA_RING
			m.stroke.Thickness = 2
			m.glyph.Image = Icons.SHIP
		else
			m.corner.CornerRadius = UDim.new(0.35, 0)
			m.stroke.Color = DARK
			m.stroke.Thickness = 1.5
			m.glyph.Image = Icons.HOUSE
		end
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

local function makeVehicle(self: Structures, id: number, kind: number, ownerId: number, x: number, y: number): any
	local f = Instance.new("Frame")
	f.Name = kind == Structures.TRANSPORT and "Transport"
		or (kind == Structures.TRAIN and "Train" or "Ship")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = Palette.playerColor3(ownerId, self.myId)
	f.BorderSizePixel = 0
	f.ZIndex = 6
	local size = kind == Structures.TRANSPORT and TRANSPORT_SIZE
		or (kind == Structures.WARSHIP and WARSHIP_SIZE)
		or (kind == Structures.SHELL and SHELL_SIZE)
		or (kind == Structures.SHIP and SHIP_SIZE or TRAIN_SIZE)
	f.Size = UDim2.fromOffset(size, size)
	f.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)

	local corner = Instance.new("UICorner")
	-- A ship is round, a train is square. At six pixels that is the only
	-- distinction that survives, and it is enough because the two are never in
	-- the same place: one is on water, the other on a rail.
	corner.CornerRadius = UDim.new(
		(kind == Structures.SHIP or kind == Structures.TRANSPORT) and 0.5 or 0.15, 0)
	corner.Parent = f

	local stroke = Instance.new("UIStroke")
	stroke.Color = DARK
	stroke.Thickness = 1
	stroke.Transparency = 0.25
	stroke.Parent = f

	f.Parent = self.vehicleLayer
	local v = { frame = f, x = x, y = y, targetX = x, targetY = y, ownerId = ownerId, kind = kind }
	self.vehicleById[id] = v
	return v
end

-- The server sends positions a few times a second; `step` walks each marker
-- toward its target. Sending every tick would be several KB/s for something
-- the eye reads as "a boat, roughly there".
function Structures.setVehicles(self: Structures, list: { any })
	local seen = {}
	for _, e in list do
		seen[e.id] = true
		local v = self.vehicleById[e.id]
		if not v then
			v = makeVehicle(self, e.id, e.kind, e.owner, e.x, e.y)
		elseif v.ownerId ~= e.owner then
			v.ownerId = e.owner
			v.frame.BackgroundColor3 = Palette.playerColor3(e.owner, self.myId)
		end
		v.targetX = e.x
		v.targetY = e.y
	end
	for id, v in self.vehicleById do
		if not seen[id] then
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
	end
	local wantRails = zoom >= MIN_RAIL_ZOOM
	if wantRails ~= self.railsVisible then
		self.railsVisible = wantRails
		self.railLayer.Visible = wantRails
	end

	if not want then
		return
	end
	for _, v in self.vehicleById do
		-- Faster than the HUD's smoothers: this is chasing a position, not
		-- easing a figure, and a boat that lags its own wake looks broken.
		local nx = Numbers.approach(v.x, v.targetX, dt, 9)
		local ny = Numbers.approach(v.y, v.targetY, dt, 9)
		if math.abs(nx - v.x) > 0.01 or math.abs(ny - v.y) > 0.01 then
			v.x, v.y = nx, ny
			v.frame.Position = UDim2.fromScale((nx + 0.5) / W, (ny + 0.5) / H)
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
