--!strict
-- Conquest :: Missiles  (client)
-- The nuclear layer as you SEE it: a warhead climbing away from your ground, a
-- ring closing on the country it is aimed at, the flash, the shockwave, and
-- the glass it leaves behind.
--
-- NOTHING HERE IS REPLICATED PER TICK. The server sends one launch event and
-- one blast event per missile on ConquestServer's "missiles" channel and this
-- module rebuilds everything between them: `Nukes.arc` is the same integer
-- Bezier the server flies the unit along, so replaying it against a shared
-- clock puts the marker where the missile actually IS, rather than where a
-- smoother guesses it might be. The blast is six numbers -- tile, inner,
-- outer, seed -- and `Nukes.blastTiles` expands them here with the same PRNG
-- and the same visit order the simulation used, so the crater on screen is the
-- crater in the simulation, tile for tile.
--
-- THE CLOCK is what makes that replay possible, and it is the only piece of
-- state this module keeps that is not an instance. Every packet carries the
-- server's tick; between packets it free-runs at Config.TICK_RATE. An arrival
-- EASES it a quarter of the way toward the truth rather than snapping, because
-- a one-tick correction is five tiles of jump on an atom bomb -- five pixels
-- of teleport at a normal zoom, on the one object in the game the eye is
-- following. A gap too big to be jitter (a stalled server, a tab that was
-- asleep) is snapped instead: easing across thirty ticks would drag every
-- missile backwards for three seconds.
--
-- POSITION IS SCALE, SIZE IS OFFSET for the missile itself, the same rule the
-- structure markers follow: a warhead is a pin on the map and has to stay
-- legible at any zoom. THE BLAST IS THE OPPOSITE and is sized in SCALE,
-- because a crater is a piece of the ground rather than a pin on it -- it has
-- a radius in TILES and it has to keep it. Camera2D sizes the map container to
-- exactly (W*zoom, H*zoom), so a Scale size of (2r/W, 2r/H) renders as a
-- 2r*zoom circle: the true footprint, at any zoom, with no per-frame maths.

local Config = require(script.Parent.Config)
local Icons = require(script.Parent.Icons)
local Nukes = require(script.Parent.Nukes)
local Palette = require(script.Parent.Palette)
local Sfx = require(script.Parent.Sfx)
local Units = require(script.Parent.Units)

local W = Config.MAP_W
local H = Config.MAP_H

local Missiles = {}
Missiles.__index = Missiles

export type Missiles = typeof(setmetatable({} :: any, Missiles))

-- ------------------------------------------------------------------ look ---

local HOT = Color3.fromRGB(255, 246, 220) -- the warhead, and the first frame of the fireball
local FIRE = Color3.fromRGB(255, 164, 56)
local SMOKE = Color3.fromRGB(84, 66, 58)
local DARK = Color3.fromRGB(10, 14, 24)

-- INCOMING IS NOT A NATION'S COLOUR. Who fired it is on the launch banner and
-- in the trail's tint; what a warhead means to everybody looking at the map is
-- the same thing, so the ring around the aimpoint is the one red on the map.
local THREAT = Color3.fromRGB(255, 88, 60)

-- An interceptor is cold where a warhead is hot: the two are in the sky at the
-- same time, crossing, and telling them apart is the whole point of drawing
-- the SAM at all.
local SAM_INK = Color3.fromRGB(150, 226, 255)

-- THE WARHEAD IS THE RAIL'S NUKE STICKER, the same picture as the button that
-- fired it, so what leaves the ground is recognisably the thing you bought.
-- Each drawing has its nose somewhere -- the original bomb's bottom-right
-- (45 degrees, screen y down), the owner's mega missile's bottom-left (135)
-- -- so the heading is corrected by THAT sticker's nose (Icons.NUKE_NOSE /
-- Icons.MEGA_NUKE_NOSE, read off the art's own NoseDeg attribute, 2026-09-22;
-- under one shared 45 the mega crossed the map sideways) before it becomes a
-- Rotation; `fl.nose` carries it per flight. Square box, ScaleType.Fit, no
-- stroke: the sticker has its own dark outline (see Icons).
--
-- Side of the square in screen pixels, per unit type. A hydrogen bomb reads
-- bigger than an atom bomb before it lands, and a MIRV's warheads are the
-- small ones -- a dozen full-size stickers raining on one country is a pile.
local HEAD_PX = {
	[Units.ATOM_BOMB] = 30,
	[Units.HYDROGEN_BOMB] = 40,
	[Units.MIRV] = 36,
	[Units.MIRV_WARHEAD] = 20,
	-- Between the two bombs it is between in yield. It reads bigger than an atom
	-- bomb on the way in, which is the only warning anybody gets that the crater
	-- about to appear is four times the ground.
	[Units.MEGA_NUKE] = 36,
	-- The scattershot's main warhead (2026-09-24) is an atom bomb's crater and
	-- flies the atom bomb's sticker, a touch bigger than the 20-px warheads
	-- fanning out around it so the salvo reads as one missile and its brood.
	[Units.SCATTERSHOT] = 32,
}
local HEAD_PX_DEFAULT = 30

local SAM_LEN = 10
local SAM_THICK = 3

-- The exhaust: dots dropped every TRAIL_GAP ticks behind the head. At an atom
-- bomb's five tiles a tick this spans about forty tiles, which is a streak you
-- can pick up from across the map without being a line drawn over half of it.
-- It halved with Nukes.CFG.SPEED and was left at fourteen dots: the streak is
-- the same LENGTH IN TICKS either way, which is what makes it read as exhaust
-- rather than as a drawn line, and a slower missile wants a shorter tail.
local TRAIL_N = 14
local TRAIL_GAP = 0.6
local TRAIL_HEAD = 7
local TRAIL_TAIL = 2

local FLASH_GROW = 0.26 -- seconds from the fireball's first frame to full radius
local FLASH_LIFE = 1.7
-- THE SHOCKWAVE HAS TO OUTRUN THE FIREBALL or it is never seen: at the first
-- tuning it reached 25 tiles while the ball was already at 30 and the whole
-- ring spent its life inside an opaque disc. It is now past the ball's full
-- radius before the ball gets there, and gone before the ball starts to fade.
local WAVE_LIFE = 0.55
local WAVE_REACH = 2.2 -- multiples of the outer radius
local PUFF_LIFE = 0.55

-- THE KILL, DRAWN (owner, 2026-09-15: an explosion when it hits). A ring that
-- snaps outward and a white core that burns down through orange, both in SCREEN
-- pixels like every other air effect here -- an interception happens in the sky
-- and has no footprint on the ground to be measured against.
--
-- SHORT, because the event is short: a quarter of a second of ring is what
-- reads as something being destroyed, where a slow bloom reads as a detonation
-- and would be confused with the thing the tower just prevented.
local BURST_PX = 54
local BURST_CORE_PX = 26
local BURST_LIFE = 0.42

-- THE SHELL (2026-09-21): a battery's round, on the same channel as the
-- warheads. TINY -- a 6x3 capsule in hot brass with the dark outline every
-- pin on this map wears -- because there can be sixty guns on the map firing
-- every seven seconds, and a shell drawn at warhead size would turn every
-- front into a missile crisis. It LOBS: a parabola over the straight line,
-- apex SHELL_LOFT of the span (in tiles, so it is part of the map's geometry
-- at any zoom), which reads as a gun's arc rather than a bullet or a nuke's
-- climb. Three smoke dots behind it are what make it read as MOVING at the
-- size it is.
local SHELL_LEN = 6
local SHELL_THICK = 3
local SHELL_LOFT = 0.28
local SHELL_LOFT_MAX = 14
local SHELL_TRAIL = 3
local SHELL_TRAIL_GAP = 0.9 -- ticks between trail dots
local SHELL_INK = Color3.fromRGB(255, 214, 120)
-- The burst, between a gunboat shell's hit and a SAM kill: the kill's ring at
-- a little over half the size, with a smoke puff under it that outlives the
-- ring. Scaled up when a building was under it and again when that building
-- fell, so the hit that mattered is the one the eye catches.
-- GROWN (owner, 2026-09-21: "make the explosion a bit bigger"): 30/14/0.36 ->
-- 46/22/0.44 -- and then POLISHED the same evening ("polish up the explosions
-- for the artillery") into a timeline rather than a ring: a white-hot core
-- that POPS to full size in the first frames and burns down to orange, the
-- fire ring racing out and cooling to smoke, SHELL_SPARKS embers flung on an
-- ease-out and dying as they land, three smoke puffs drifting off the point
-- and outliving everything, and a dark scorch left on the ground that fades
-- over a second and a half. All of it is OFFSET pixels off one root frame, so
-- one Destroy takes the lot and the shape is the same at every zoom; a burst
-- is a dozen instances for under a second, and sixty guns firing every seven
-- seconds is about a hundred live at once. A hit that FELLS a building also
-- kicks the camera a little (see `impact`).
local SHELL_BURST_PX = 46
local SHELL_BURST_CORE_PX = 22
local SHELL_BURST_LIFE = 0.48
local SHELL_BURST_POP = 0.06 -- seconds for the core to reach full size
local SHELL_SPARKS = 6
local SHELL_SPARK_PX = 3
local SHELL_SPARK_REACH = 0.85 -- of the ring's full size
local SHELL_SMOKE_LIFE = 0.9
local SHELL_SCORCH_LIFE = 1.5
local SHELL_SCORCH_T = 0.6 -- resting transparency of the ground mark
local SHELL_RAZE_SHAKE = 3
-- Floors for the two shell sounds. See `shell` and `impact` for who gets them.
local CANNON_NEAR = { floor = 0.3 }
local BOOM_SHELL = { floor = 0.4 }

-- Screen pixels of camera kick at detonation, per tile of outer radius. An
-- atom bomb is 30 tiles and lands at about five pixels; a hydrogen bomb is a
-- hundred and clips at SHAKE_MAX. Decays fast enough that it reads as an
-- impact rather than as a broken camera.
local SHAKE_PER_TILE = 0.17
local SHAKE_MAX = 13
local SHAKE_DECAY = 7
-- YOUR OWN WARHEAD HITS HARDER (owner, 2026-09-24: "shake a bit more when
-- the nuke hits, so it has that satisfying feel"). The launcher's kick is
-- scaled, floored so even an atom bomb lands with weight, and rings out
-- longer: `step` decays at SHAKE_DECAY_OWN while `shakeOwn` is set.
local SHAKE_OWN_MULT = 1.8
local SHAKE_OWN_MIN = 9
local SHAKE_OWN_MAX = 22
local SHAKE_DECAY_OWN = 4.5

-- THE BOMBER (2026-09-21, the airfield's sortie). A PIN like the warhead --
-- OFFSET pixels, the same picture at every zoom -- because a plane three
-- tiles long is three pixels at the default view, and the one thing on the
-- map worth watching would be invisible. 32 is the 16x16 sprite at 2x. The
-- sprite FACES RIGHT (Icons.PLANE), so its Rotation is the bare heading.
local PLANE_PX = 32
-- The contrail: a small light puff every PLANE_PUFF_GAP seconds, gone in
-- PLANE_PUFF_LIFE. At four tiles a tick that is one every three tiles, a
-- thread behind the plane rather than the warhead's streak.
local PLANE_PUFF_GAP = 0.07
local PLANE_PUFF_LIFE = 0.5
-- Past the target the plane flies on, fading, for this long, then goes.
local PLANE_OVERRUN = 0.5
-- The bombs landing: a fireball the size of the disc, over faster than a
-- warhead's -- no crater follows it, so nothing needs the ground seen through
-- smoke -- and a short shockwave.
local BOMB_LIFE = 0.85
local BOMB_WAVE_LIFE = 0.4
local CONTRAIL = Color3.fromRGB(226, 232, 240)
-- THE RAILGUN (2026-09-24). A slug is a white-hot head dragging a short
-- FIRE streak (RAIL_TAIL tiles of it) across the map; on impact the WHOLE
-- line from gun to target flares and burns down to smoke over RAIL_FADE --
-- the trail you see after the fact, then the hit. FIRE, NOT ELECTRIC (owner,
-- 2026-09-24: the cyan laser was "too futuristic", and a lobbed shell
-- "doesnt feel the same" -- keep the straight fast shot, make it burn).
local RAIL_GLOW = Color3.fromRGB(255, 120, 40)
local RAIL_CORE = Color3.fromRGB(255, 214, 110)
local RAIL_TAIL = 40
local RAIL_FADE = 0.6
local RAIL_THICK = 5
-- A SLIGHT ARC (owner, 2026-09-25: "give it more of an arc when it fires.
-- just a slight one"): apex RAIL_ARC of the span, capped, so it reads as a
-- flat fast shot that still has weight. The streak and the landed line are
-- RAIL_SEGS straight pieces laid along that curve.
local RAIL_ARC = 0.06
local RAIL_ARC_MAX = 24
local RAIL_SEGS = 12

-- ------------------------------------------------------------------ util ---

local function atTile(f: GuiObject, x: number, y: number)
	f.Position = UDim2.fromScale((x + 0.5) / W, (y + 0.5) / H)
end

-- Radius in TILES. See the header: scale size against a container the camera
-- has already sized to the map.
local function setRadius(f: GuiObject, r: number)
	f.Size = UDim2.fromScale(2 * r / W, 2 * r / H)
end

local function disc(parent: Instance, z: number): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	f.Parent = parent
	return f
end

-- A body drawn as a capsule: rotated to its heading, it reads as ordnance at
-- any size a map marker is allowed to be.
local function capsule(parent: Instance, len: number, thick: number, fill: Color3, z: number): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(len, thick)
	f.BackgroundColor3 = fill
	f.BorderSizePixel = 0
	f.ZIndex = z
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = DARK
	stroke.Thickness = 1
	stroke.Transparency = 0.35
	stroke.Parent = f
	f.Parent = parent
	return f
end

-- `image` picks the sticker; nil is the atom bomb's. The mega nuke flies
-- under its own (Icons.MEGA_NUKE, 2026-09-22) so a bigger crater is
-- announced by a different head, not only by a bigger one.
local function warhead(parent: Instance, px: number, z: number, image: string?): ImageLabel
	local img = Instance.new("ImageLabel")
	img.Name = "Warhead"
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Size = UDim2.fromOffset(px, px)
	img.BackgroundTransparency = 1
	img.Image = image or Icons.NUKE
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = z
	Icons.resample(img)
	img.Parent = parent
	return img
end

-- Position along a sampled curve at a FRACTIONAL index. The curve holds one
-- point per tick; the client draws at 60fps, so everything between two ticks
-- is this lerp.
local function samplePos(c: any, fi: number): (number, number)
	local n = #c.px
	if fi < 0 then
		fi = 0
	elseif fi > n - 1 then
		fi = n - 1
	end
	local i = math.floor(fi)
	local f = fi - i
	local a = i + 1
	local b = a < n and a + 1 or n
	return c.px[a] + (c.px[b] - c.px[a]) * f, c.py[a] + (c.py[b] - c.py[a]) * f
end

-- ------------------------------------------------------------------ life ---

function Missiles.new(container: Frame): Missiles
	local root = Instance.new("Frame")
	root.Name = "Missiles"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	-- ABOVE EVERYTHING ELSE ON THE MAP, and this one number does all of it:
	-- ZIndexBehavior is Sibling, so a sibling's whole subtree is placed by its
	-- root. Over the map tiles (1), the economy markers (3), the nation labels
	-- (5) and the click pings (6). Nothing on the map outranks a warhead.
	root.ZIndex = 7
	root.Parent = container

	return setmetatable({
		root = root,
		-- [unit id] = flight. Nukes and SAM missiles are Units and share one id
		-- space, so one table per kind is a naming convenience, not a necessity.
		flights = {} :: { [number]: any },
		sams = {} :: { [number]: any },
		-- [shell id] = shell. Its OWN id space (sim.artilleryShellSeq), not a
		-- unit id, which is why it cannot share the two tables above.
		shells = {} :: { [number]: any },
		-- [sortie id] = plane. Its own id space (Airstrikes.airstrikeSeq), so
		-- its own table rather than a kind on the flights.
		planes = {} :: { [number]: any },
		fx = {} :: { any },

		localId = 0,
		-- The terrain buffer, borrowed from the renderer, so the blast set can
		-- be regenerated. Nil until setMap: no map, no craters.
		terrain = nil :: buffer?,
		-- Called with (tiles, count) the instant a warhead lands. The client
		-- points it at Renderer.setFalloutTiles.
		onFallout = nil :: (({ number }, number) -> ())?,

		-- WHOSE GROUND IS UNDER A TILE, asked of the client -- which owns the
		-- ownership buffer -- rather than duplicated here. Used for exactly one
		-- thing: deciding whether an incoming warhead is aimed at YOU, which is
		-- the difference between a launch you watch and one you run from. Nil
		-- until the client sets it, and a nil answer is simply "not yours".
		ownerAt = nil :: ((number) -> boolean)?,

		tickBase = 0,
		tickTime = os.clock(),
		haveTick = false,

		-- WHERE EACH INTERCEPTOR WAS AIMED, outliving the sprite itself so a kill
		-- event arriving after the reap still knows where to put the explosion.
		-- See expire.
		samEnd = {},

		-- Read by the client every frame and fed to the camera.
		shake = 0,
	}, Missiles)
end

function Missiles.setLocalId(self: Missiles, id: number)
	self.localId = id
end

function Missiles.setMap(self: Missiles, terrain: buffer?)
	self.terrain = terrain
end

local function destroyFlight(self: Missiles, id: number)
	local fl = self.flights[id]
	if fl == nil then
		return
	end
	self.flights[id] = nil
	fl.head:Destroy()
	for _, d in fl.trail do
		d:Destroy()
	end
	if fl.ring then
		fl.ring:Destroy()
	end
	if fl.lead then
		fl.lead:Destroy()
	end
end

local function destroyPlane(self: Missiles, id: number)
	local pl = self.planes[id]
	if pl == nil then
		return
	end
	self.planes[id] = nil
	pl.img:Destroy()
end

local function destroySam(self: Missiles, id: number)
	local s = self.sams[id]
	if s == nil then
		return
	end
	self.sams[id] = nil
	s.frame:Destroy()
end

local function destroyShell(self: Missiles, id: number)
	local s = self.shells[id]
	if s == nil then
		return
	end
	self.shells[id] = nil
	s.frame:Destroy()
	for _, d in s.trail do
		d:Destroy()
	end
end

function Missiles.clear(self: Missiles)
	for id in self.flights do
		destroyFlight(self, id)
	end
	for id in self.sams do
		destroySam(self, id)
	end
	for id in self.shells do
		destroyShell(self, id)
	end
	for id in self.planes do
		destroyPlane(self, id)
	end
	-- Aimpoints belong to the round that fired them: a kill event cannot arrive
	-- for a missile launched in a match that is already over.
	table.clear(self.samEnd)
	for _, fx in self.fx do
		fx.frame:Destroy()
	end
	table.clear(self.fx)
	if self.rails ~= nil then
		table.clear(self.rails)
	end
	self.shake = 0
	self.shakeOwn = false
	-- The clock belongs to a round: the next one starts its ticks at zero and
	-- a stale base would put every launch minutes into the past.
	self.haveTick = false
end

-- ----------------------------------------------------------------- clock ---

local function nowTick(self: Missiles): number
	return self.tickBase + (os.clock() - self.tickTime) * Config.TICK_RATE
end

function Missiles.setTick(self: Missiles, tick: number?)
	if tick == nil then
		return
	end
	if not self.haveTick then
		self.tickBase, self.tickTime, self.haveTick = tick, os.clock(), true
		return
	end
	local est = nowTick(self)
	local drift = tick - est
	self.tickBase = (math.abs(drift) > 5) and tick or (est + drift * 0.25)
	self.tickTime = os.clock()
end

-- ---------------------------------------------------------------- events ---

-- A short burst of light, in SCREEN pixels rather than tiles: everything this
-- draws happens in the air (a launch, an interception) and has no footprint on
-- the ground to be measured against.
local function puff(self: Missiles, x: number, y: number, ink: Color3, life: number?)
	local f = disc(self.root, 11)
	f.Size = UDim2.fromOffset(10, 10)
	f.BackgroundColor3 = ink
	atTile(f, x, y)
	self.fx[#self.fx + 1] = { kind = "puff", frame = f, t = 0, life = life or PUFF_LIFE, ink = ink }
end

-- An interception, as an explosion. The core is a CHILD of the ring so the step
-- loop's single `fx.frame:Destroy()` takes both down -- a second root-level
-- frame here would leak one every time a tower did its job -- and it is sized in
-- OFFSET, so it holds its own size while the ring grows past it.
local function burst(self: Missiles, x: number, y: number)
	local ring = disc(self.root, 14)
	ring.Size = UDim2.fromOffset(6, 6)
	local stroke = Instance.new("UIStroke")
	stroke.Color = HOT
	stroke.Thickness = 3
	stroke.Parent = ring
	atTile(ring, x, y)

	local core = disc(ring, 15)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.Size = UDim2.fromOffset(BURST_CORE_PX, BURST_CORE_PX)
	core.BackgroundColor3 = HOT
	core.BackgroundTransparency = 0

	self.fx[#self.fx + 1] = {
		kind = "burst", frame = ring, stroke = stroke, core = core, t = 0, life = BURST_LIFE,
		px = BURST_PX, corePx = BURST_CORE_PX,
	}
end

-- A shell landing. The SAM kill's ring, smaller and in the fireball's orange
-- rather than white-hot, over a smoke puff -- see SHELL_BURST_PX. `scale` is
-- the hit's weight: 1 for ground, more when a building was under it, more
-- again when that building fell.
local function shellBurst(self: Missiles, x: number, y: number, scale: number)
	local px = SHELL_BURST_PX * scale
	-- THE SCORCH goes down first so everything else draws over it: a dark
	-- disc under the point, the size the ring will reach, fading slowly.
	local scorch = disc(self.root, 10)
	scorch.Size = UDim2.fromOffset(px * 0.7, px * 0.7)
	scorch.BackgroundColor3 = DARK
	scorch.BackgroundTransparency = SHELL_SCORCH_T
	atTile(scorch, x, y)
	self.fx[#self.fx + 1] = { kind = "scorch", frame = scorch, t = 0, life = SHELL_SCORCH_LIFE }

	local ring = disc(self.root, 14)
	ring.Size = UDim2.fromOffset(4, 4)
	local stroke = Instance.new("UIStroke")
	stroke.Color = FIRE
	stroke.Thickness = 2
	stroke.Parent = ring
	atTile(ring, x, y)

	-- The core starts as a POINT and pops -- see the step: a disc that is
	-- already full on its first frame is a sticker, one that arrives is a blast.
	local core = disc(ring, 15)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.Size = UDim2.fromOffset(2, 2)
	core.BackgroundColor3 = HOT
	core.BackgroundTransparency = 0

	-- EMBERS, children of the ring so its Destroy takes them: each flung on
	-- its own heading at its own pace, from the centre outward.
	local sparks = table.create(SHELL_SPARKS)
	for i = 1, SHELL_SPARKS do
		local sp = disc(ring, 16)
		sp.Size = UDim2.fromOffset(SHELL_SPARK_PX, SHELL_SPARK_PX)
		sp.BackgroundColor3 = HOT
		sp.BackgroundTransparency = 0
		sp.Position = UDim2.fromScale(0.5, 0.5)
		local a = (i - 1) / SHELL_SPARKS * math.pi * 2 + math.random() * 0.9
		sparks[i] = { frame = sp, ax = math.cos(a), ay = math.sin(a), pace = 0.7 + math.random() * 0.6 }
	end

	self.fx[#self.fx + 1] = {
		kind = "shellburst", frame = ring, stroke = stroke, core = core, sparks = sparks, t = 0,
		life = SHELL_BURST_LIFE, px = px, corePx = SHELL_BURST_CORE_PX * scale,
	}
	-- THREE PUFFS OF SMOKE, off-centre at random and outliving the fire: the
	-- plume is what is still there when the eye arrives.
	puff(self, x, y, SMOKE, SHELL_SMOKE_LIFE)
	puff(self, x + (math.random() - 0.5) * 1.6, y - 0.4 - math.random() * 0.6, SMOKE, SHELL_SMOKE_LIFE)
	puff(self, x + (math.random() - 0.5) * 1.6, y - 0.8 - math.random() * 0.6, SMOKE, SHELL_SMOKE_LIFE * 1.15)
end

-- A small light puff for the contrail: the launch puff's shape at a third of
-- the size, so a bomber leaves a thread rather than a smear.
local function trail(self: Missiles, x: number, y: number, ink: Color3)
	local f = disc(self.root, 11)
	f.Size = UDim2.fromOffset(4, 4)
	f.BackgroundColor3 = ink
	f.BackgroundTransparency = 0.4
	atTile(f, x, y)
	self.fx[#self.fx + 1] = { kind = "trail", frame = f, t = 0, life = PLANE_PUFF_LIFE }
end

-- THE BOMBER LEAVES THE FIELD ("pl", Airstrikes.order). Four numbers and two
-- ticks: a straight line from src to dst over (t1 - t0) sim ticks on the same
-- clock the warheads fly on, so it is where the server has it. Untinted -- the
-- sprite is its own grey -- and the contrail carries the owner's colour, which
-- is where "whose plane is that" is read, as on the warhead's exhaust.
local function plane(self: Missiles, ev: any)
	destroyPlane(self, ev.id)
	local sx = ev.src % W
	local sy = (ev.src - sx) / W
	local dx = ev.dst % W
	local dy = (ev.dst - dx) / W
	local pr, pg, pb = Palette.colorFor(ev.owner, self.localId)
	local img = Instance.new("ImageLabel")
	img.Name = "Plane"
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Size = UDim2.fromOffset(PLANE_PX, PLANE_PX)
	img.BackgroundTransparency = 1
	img.Image = Icons.PLANE
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 12
	img.Rotation = math.deg(math.atan2(dy - sy, dx - sx))
	Icons.resample(img)
	atTile(img, sx, sy)
	img.Parent = self.root
	self.planes[ev.id] = {
		img = img,
		x0 = sx,
		y0 = sy,
		x1 = dx,
		y1 = dy,
		t0 = ev.t0,
		t1 = math.max(ev.t0 + 1, ev.t1),
		tint = Color3.fromRGB(pr, pg, pb),
		puffT = 0,
		-- Seconds since the bombs landed, nil while still inbound. See step.
		landed = nil :: number?,
		flew = false,
	}
	-- Something happens at the field, and the roar -- the warhead's rule.
	puff(self, sx, sy, HOT)
	Sfx.playAt("Launch", sx, sy, { floor = 0.3 })
end

-- THE BOMBS LAND ("pb"). A fireball sized to the disc -- between a shell's
-- burst and an atom bomb's -- and a short shockwave; NO CRATER, the ground is
-- not changed. The plane is not destroyed here: it flies on past the target
-- for PLANE_OVERRUN and fades (see step), which is what a bomber does.
local function bomb(self: Missiles, ev: any)
	local x = ev.tile % W
	local y = (ev.tile - x) / W
	local r = ev.r or 10

	local ball = disc(self.root, 13)
	ball.BackgroundColor3 = HOT
	atTile(ball, x, y)
	setRadius(ball, r * 0.2)
	local core = disc(ball, 14)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.BackgroundColor3 = HOT
	self.fx[#self.fx + 1] =
		{ kind = "ball", frame = ball, core = core, t = 0, life = BOMB_LIFE, inner = r * 0.55, outer = r }

	local wave = disc(self.root, 15)
	local stroke = Instance.new("UIStroke")
	stroke.Color = HOT
	stroke.Thickness = 4
	stroke.Parent = wave
	atTile(wave, x, y)
	setRadius(wave, 0)
	self.fx[#self.fx + 1] = { kind = "wave", frame = wave, stroke = stroke, t = 0, life = BOMB_WAVE_LIFE, outer = r * 0.7 }

	local pl = self.planes[ev.id]
	if pl ~= nil then
		pl.landed = 0
	end

	-- Near or far, the warhead's two recordings and the same gate; floored
	-- lower than a nuke's because a raid is not something the whole map has to
	-- hear.
	if Sfx.viewGain(x, y) > 0.55 then
		Sfx.playAt("Blast", x, y, { floor = 0.35 })
	else
		Sfx.playAt("Boom", x, y, { floor = 0.2 })
	end
	local kick = math.min(SHAKE_MAX, r * SHAKE_PER_TILE * 1.5)
	if kick > self.shake then
		self.shake = kick
	end
end

local function launch(self: Missiles, ev: any)
	destroyFlight(self, ev.id)

	local fl = Nukes.flight(ev)
	local pr, pg, pb = Palette.colorFor(ev.owner, self.localId)
	fl.tint = Color3.fromRGB(pr, pg, pb)
	fl.owner = ev.owner

	local mega = ev.kind == Units.MEGA_NUKE
	fl.head = warhead(self.root, HEAD_PX[ev.kind] or HEAD_PX_DEFAULT, 12, if mega then Icons.MEGA_NUKE else nil)
	-- Which way this sticker's nose points in its own drawing (see the note
	-- above HEAD_PX): the Rotation below is heading minus this.
	fl.nose = if mega then Icons.MEGA_NUKE_NOSE else Icons.NUKE_NOSE
	fl.trail = table.create(TRAIL_N)
	for i = 1, TRAIL_N do
		local d = disc(self.root, 11)
		local k = (i - 1) / (TRAIL_N - 1)
		-- The exhaust cools from the flame at the nozzle to the launcher's own
		-- colour further back, which is where "whose missile is that" is
		-- readable without putting a name on it.
		d.BackgroundColor3 = HOT:Lerp(fl.tint, k)
		fl.trail[i] = d
	end

	-- THE AIMPOINT, WHILE IT IS STILL IN THE AIR. The outer ring is the crater
	-- this warhead will leave, drawn at its true radius; the disc inside it
	-- closes on the centre as the missile closes on the ground. So anyone
	-- watching has both facts before the flash -- where, and how long -- which
	-- is the difference between a nuke you can run from and one you cannot.
	--
	-- A MIRV carrier has no magnitude entry (it drops warheads, it does not
	-- detonate), so it flies without a ring and its children draw their own.
	local mag = Nukes.magnitude(ev.kind)
	if mag then
		local ring = disc(self.root, 10)
		setRadius(ring, mag.outer)
		local stroke = Instance.new("UIStroke")
		stroke.Color = THREAT
		stroke.Thickness = 2
		stroke.Parent = ring
		atTile(ring, ev.dst % W, (ev.dst - ev.dst % W) / W)
		fl.ring = ring
		fl.ringStroke = stroke

		local lead = disc(self.root, 10)
		lead.BackgroundColor3 = THREAT
		lead.BackgroundTransparency = 0.72
		atTile(lead, ev.dst % W, (ev.dst - ev.dst % W) / W)
		fl.lead = lead
		fl.outer = mag.outer
	end

	self.flights[ev.id] = fl

	-- Something happens at the launch site. Without it a missile simply exists
	-- one frame, off in a corner of the map nobody was looking at, and the
	-- first thing anybody knows about the strike is the ring around the target.
	local sx = ev.src % W
	local sy = (ev.src - sx) / W
	puff(self, sx, sy, HOT)

	-- THE ROAR AT THE PAD. Floored rather than left to fade away entirely,
	-- because a launch anywhere on this map is the round changing shape, and
	-- "I never heard it" is not something a nuclear weapon should be able to
	-- do -- however far off the edge of the view the silo is.
	Sfx.playAt("Launch", sx, sy, { floor = 0.3 })

	-- AND THE WARNING, if the ground it is aimed at is yours. NOT positional:
	-- this one is not a sound on the map, it is a sound in your room, and it is
	-- the same however far away the silo that fired it was. A MIRV carrier has
	-- no magnitude and detonates nowhere, so it raises none -- the warheads it
	-- drops raise their own when they separate, which is also the first moment
	-- anybody knows where they are going.
	if mag and self.ownerAt and self.ownerAt(ev.dst) then
		Sfx.play("Siren")
	end
end

local function blast(self: Missiles, ev: any)
	local fl = self.flights[ev.id]
	local mine = (ev.owner or (fl and fl.owner)) == self.localId and self.localId ~= 0
	destroyFlight(self, ev.id)

	local x = ev.tile % W
	local y = (ev.tile - x) / W

	local ball = disc(self.root, 13)
	ball.BackgroundColor3 = HOT
	atTile(ball, x, y)
	setRadius(ball, ev.inner * 0.35)
	-- A HOT CORE INSIDE THE FIREBALL. One flat orange disc the size of a
	-- county is a sticker; the thing that makes it read as a detonation is that
	-- the middle is white and burns out faster than the edge. A child rather
	-- than a second effect so it cannot drift off the centre.
	local core = disc(ball, 14)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.BackgroundColor3 = HOT
	self.fx[#self.fx + 1] =
		{ kind = "ball", frame = ball, core = core, t = 0, life = FLASH_LIFE, inner = ev.inner, outer = ev.outer }

	local wave = disc(self.root, 15)
	local stroke = Instance.new("UIStroke")
	stroke.Color = HOT
	stroke.Thickness = 6
	stroke.Parent = wave
	atTile(wave, x, y)
	setRadius(wave, 0)
	self.fx[#self.fx + 1] = { kind = "wave", frame = wave, stroke = stroke, t = 0, life = WAVE_LIFE, outer = ev.outer }

	-- GLASS THE GROUND. Regenerated rather than received: see the header. The
	-- fake sim is the whole contract blastTiles has with the world -- one
	-- terrain buffer, which the renderer already owns because it generated the
	-- same map from the same seed.
	local paint = self.onFallout
	local terrain = self.terrain
	if paint and terrain then
		local tiles, count = Nukes.blastTiles({ map = { terrain = terrain } }, ev.tile, ev.inner, ev.outer, ev.seed)
		paint(tiles, count)
	end

	-- NEAR OR FAR, AND THEY ARE DIFFERENT RECORDINGS. What decides is how far
	-- the crater is from the middle of the view: a detonation you are looking
	-- at is the loudest thing in the game, and the same detonation while you
	-- are zoomed into your own border on the other side of the map is a long
	-- roll of thunder from over the horizon. Both are floored -- a nuke is
	-- always heard -- and the distant one is floored higher, because being
	-- heard from a long way off is the whole reason that sample exists.
	if Sfx.viewGain(x, y) > 0.55 then
		Sfx.playAt("Blast", x, y, { floor = 0.35 })
	else
		Sfx.playAt("Boom", x, y, { floor = 0.55 })
	end

	local kick = math.min(SHAKE_MAX, ev.outer * SHAKE_PER_TILE)
	if mine then
		kick = math.clamp(kick * SHAKE_OWN_MULT, SHAKE_OWN_MIN, SHAKE_OWN_MAX)
		self.shakeOwn = true
	end
	if kick > self.shake then
		self.shake = kick
	end
end

-- A missile that stopped being one without landing: shot down, or caught in
-- somebody else's blast. `hit` is true only for the MIRV carrier reaching its
-- separation point and for a SAM reaching its prey. The carrier still draws
-- nothing -- the warheads it drops say it -- but A SAM KILL NOW EXPLODES (owner,
-- 2026-09-15). It used to be a single cold dot, which was the whole of the
-- feedback for the most expensive building in the game doing the one thing it
-- was bought for; the tower deserves to be SEEN working.
--
-- KEYED ON hit == true, which is exactly one event per kill. The interceptor
-- ALSO fires `hit = false` when it simply times out, and the warhead it killed
-- fires its own `hit = false` as it is removed -- so drawing on the false branch
-- would both miss real kills and burst over misses.
local function expire(self: Missiles, ev: any)
	local fl = self.flights[ev.id]
	if fl then
		if not ev.hit then
			local x, y = samplePos(fl.curve, nowTick(self) - fl.startTick)
			puff(self, x, y, HOT)
		end
		destroyFlight(self, ev.id)
	end
	-- THE SPRITE MAY ALREADY BE GONE, AND THE KILL STILL HAPPENED. `step` reaps
	-- an interceptor 20 ticks after the CLIENT's straight-line arrival estimate,
	-- while the server flies a LONGER jittered air path -- so a kill event can
	-- arrive to find `sams[id]` already swept up, and before this the explosion
	-- and the bang were both lost with it, silently. That is a far better
	-- explanation for "no sound on an interception" than any mixing level, and
	-- turning the volume up would never have fixed it.
	local s = self.sams[ev.id] or self.samEnd[ev.id]
	if s then
		if ev.hit then
			burst(self, s.x1, s.y1)
			-- The cold dot stays UNDER the explosion: it is the interceptor's own
			-- colour, and it is what ties the flash to the blue thing that just
			-- crossed the map rather than to the warhead it removed.
			puff(self, s.x1, s.y1, SAM_INK)
			-- A KILL, NOT A LAUNCH, and that still holds: the interceptor LEAVING
			-- the rail is neither drawn nor heard. Only the moment it connects
			-- makes any sound, because that is the only part of an interception
			-- anybody can act on -- whether it worked.
			--
			-- ONE SAMPLE, THE OWNER'S OWN (2026-09-15: "use distant exploison for
			-- the sound"). This briefly layered a pitched-up copy of the nuke's
			-- `Blast` underneath to force something explosive out of a thin cue;
			-- that hack is GONE, because a purpose-made recording does the job it
			-- was faking and two samples on one event only ever muddy each other.
			--
			-- NO VOLUME MULTIPLIER EITHER. The sound is authored in SoundService
			-- and its level is a slider in the Explorer -- see the Sfx header.
			-- Restating a volume here is how the mix goes stale.
			--
			-- FLOOR 0.5 STAYS, and it is not a volume: it is the DISTANCE rule.
			-- An interception is a fact about your defences working and is worth
			-- hearing wherever the camera happens to be pointing, the same
			-- argument the nuke's own floor makes, one step quieter.
			-- FLOOR 0.9, not 0.5 (owner, 2026-09-15: "turn it up a hella lot").
			-- This is the DISTANCE rule, not the level: at 0.9 an interception on
			-- the far side of the map still arrives at nine tenths of the sound
			-- of one under your cursor. Effectively un-attenuated, which is the
			-- right call for the one event that says your defences worked -- the
			-- level itself is the slider on the instance in SoundService.
			Sfx.playAt("Intercept", s.x1, s.y1, { floor = 0.9 })
		end
		destroySam(self, ev.id)
		-- Whether it hit or timed out, this interceptor is finished with.
		self.samEnd[ev.id] = nil
	end
end

local function sam(self: Missiles, ev: any)
	destroySam(self, ev.id)
	local sx = ev.src % W
	local sy = (ev.src - sx) / W
	local dx = ev.dst % W
	local dy = (ev.dst - dx) / W
	local span = math.sqrt((dx - sx) ^ 2 + (dy - sy) ^ 2)
	-- The real interceptor walks a jittered air path; what matters on screen is
	-- that something cold and fast leaves the launcher and reaches the warhead
	-- at the moment the warhead disappears, and a straight line at the right
	-- speed does that exactly.
	self.sams[ev.id] = {
		x0 = sx,
		y0 = sy,
		x1 = dx,
		y1 = dy,
		start = ev.tick,
		ticks = math.max(1, span / math.max(1, ev.speed)),
		frame = capsule(self.root, SAM_LEN, SAM_THICK, SAM_INK, 12),
	}
	-- THE AIMPOINT, KEPT SEPARATELY. The live record above is destroyed by the
	-- reap in `step`; this one is not, and it is what lets a late kill still
	-- burst. SAME FIELD NAMES as the live record on purpose, so expire reads one
	-- shape either way rather than branching on which table it got.
	self.samEnd[ev.id] = { x1 = dx, y1 = dy }
end

-- A battery's round leaving the gun (Artillery.fire). Flown from the two
-- tick stamps on the event against the shared clock, the way a warhead is
-- flown from its curve: no per-tick traffic, and the shell sits ON its
-- aimpoint until the impact event says what it did.
local function shell(self: Missiles, ev: any)
	destroyShell(self, ev.id)
	local sx = ev.src % W
	local sy = (ev.src - sx) / W
	local dx = ev.dst % W
	local dy = (ev.dst - dx) / W
	local span = math.sqrt((dx - sx) ^ 2 + (dy - sy) ^ 2)
	local trail = table.create(SHELL_TRAIL)
	for i = 1, SHELL_TRAIL do
		local d = disc(self.root, 11)
		d.Size = UDim2.fromOffset(3, 3)
		d.BackgroundColor3 = SMOKE
		d.BackgroundTransparency = 0.3 + 0.2 * i
		d.Visible = false
		trail[i] = d
	end
	self.shells[ev.id] = {
		x0 = sx,
		y0 = sy,
		x1 = dx,
		y1 = dy,
		t0 = ev.t0,
		t1 = math.max(ev.t1, ev.t0 + 1),
		loft = math.min(SHELL_LOFT_MAX, span * SHELL_LOFT),
		frame = capsule(self.root, SHELL_LEN, SHELL_THICK, SHELL_INK, 12),
		trail = trail,
	}
	-- THE REPORT. Attenuated like the gunboat's, not floored like the nuke's:
	-- with sixty guns on the map firing every seven seconds, a floor on all
	-- of them is a drumroll from nowhere. YOURS, and the ones aimed at your
	-- ground, keep a floor -- those are the two a player has to be able to
	-- hear from anywhere on the map.
	local near = ev.owner == self.localId or (self.ownerAt ~= nil and self.ownerAt(ev.dst))
	Sfx.playAt("Cannon", sx, sy, near and CANNON_NEAR or nil)
end

-- ...and landing (Artillery.land). `hit` is a building under it, `razed` that
-- building falling; `kill` is troops off the victim's army and is not drawn
-- here -- the army readout is where that number lives.
local function impact(self: Missiles, ev: any)
	destroyShell(self, ev.id)
	local x = ev.tile % W
	local y = (ev.tile - x) / W
	shellBurst(self, x, y, ev.razed == 1 and 1.8 or (ev.hit == 1 and 1.35 or 1))
	-- A BUILDING FALLING kicks the camera a little, and only then: shells land
	-- by the dozen and a jolt on each would be a permanent tremor.
	if ev.razed == 1 and SHELL_RAZE_SHAKE > self.shake and Sfx.viewGain(x, y) > 0.55 then
		self.shake = SHELL_RAZE_SHAKE
	end
	-- HEARD ONLY WHEN SEEN. A detonation plays from anywhere because a nuke is
	-- the round changing shape; a shell is one of hundreds, and the ones off
	-- screen are somebody else's war. 0.55 is the blast's own line between a
	-- crater you are looking at and one over the horizon.
	if Sfx.viewGain(x, y) > 0.55 then
		Sfx.playAt("Boom", x, y, BOOM_SHELL)
	end
end

-- A beam frame laid from (x0, y0) to (x1, y1) in tiles, `thick` px across.
-- Scale X against the map-sized root, so its length is right at every zoom
-- and every heading (the root is the map's aspect, a tile is square).
local function layBeam(f: Frame, x0: number, y0: number, x1: number, y1: number, thick: number)
	local dx, dy = x1 - x0, y1 - y0
	local len = math.sqrt(dx * dx + dy * dy)
	f.Position = UDim2.fromScale(((x0 + x1) * 0.5 + 0.5) / W, ((y0 + y1) * 0.5 + 0.5) / H)
	f.Size = UDim2.new(math.max(len, 0.5) / W, 0, 0, thick)
end

-- The rail's curve at `p` (0 gun, 1 target): the straight line lifted by a
-- parabola, apex fx.lift / 4 at mid-flight.
local function railAt(fx: any, p: number): (number, number)
	return fx.x0 + (fx.x1 - fx.x0) * p, fx.y0 + (fx.y1 - fx.y0) * p - fx.lift * p * (1 - p)
end

-- Lay the rail's segments along its curve from `pa` to `pb`, `thick` px.
local function layArc(fx: any, pa: number, pb: number, thick: number)
	local n = #fx.segs
	for i, seg in fx.segs do
		local ax, ay = railAt(fx, pa + (pb - pa) * (i - 1) / n)
		local bx, by = railAt(fx, pa + (pb - pa) * i / n)
		layBeam(seg.glow, ax, ay, bx, by, thick)
		seg.glow.Rotation = math.deg(math.atan2(by - ay, bx - ax))
	end
end

-- THE SLUG LEAVES THE GUN ("rf", Railgun.order). RAIL_SEGS pieces, each a
-- fire-orange glow with a yellow-hot core, and a white-hot head, all under
-- one map-sized holder so the fx loop's single Destroy takes the lot.
local function railFire(self: Missiles, ev: any)
	local sx = ev.src % W
	local sy = (ev.src - sx) / W
	local dx = ev.dst % W
	local dy = (ev.dst - dx) / W
	local holder = Instance.new("Frame")
	holder.Name = "Rail"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.Size = UDim2.fromScale(1, 1)
	holder.ZIndex = 12
	local segs = table.create(RAIL_SEGS)
	for i = 1, RAIL_SEGS do
		local glow = Instance.new("Frame")
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.BorderSizePixel = 0
		glow.ZIndex = 12
		glow.BackgroundColor3 = RAIL_GLOW
		glow.BackgroundTransparency = 0.3
		local gc = Instance.new("UICorner")
		gc.CornerRadius = UDim.new(0.5, 0)
		gc.Parent = glow
		local core = Instance.new("Frame")
		core.AnchorPoint = Vector2.new(0.5, 0.5)
		core.Position = UDim2.fromScale(0.5, 0.5)
		core.Size = UDim2.fromScale(1, 0.4)
		core.BorderSizePixel = 0
		core.ZIndex = 13
		core.BackgroundColor3 = RAIL_CORE
		core.Parent = glow
		glow.Parent = holder
		segs[i] = { glow = glow, core = core }
	end
	local head = disc(holder, 14)
	head.Size = UDim2.fromOffset(8, 8)
	head.BackgroundColor3 = HOT
	head.BackgroundTransparency = 0
	atTile(head, sx, sy)
	holder.Parent = self.root
	local len = math.sqrt((dx - sx) ^ 2 + (dy - sy) ^ 2)
	local fx = {
		kind = "rail", frame = holder, segs = segs, head = head, t = 0, life = 60,
		x0 = sx, y0 = sy, x1 = dx, y1 = dy,
		lift = 4 * math.min(RAIL_ARC_MAX, len * RAIL_ARC),
		len = len, t0 = ev.t0, t1 = math.max(ev.t0 + 1, ev.t1),
		-- Seconds since the impact, nil while the slug is still out.
		landed = nil :: number?,
	}
	layArc(fx, 0, 0, RAIL_THICK)
	self.fx[#self.fx + 1] = fx
	self.rails = self.rails or {}
	self.rails[ev.id] = fx
	puff(self, sx, sy, FIRE)
	puff(self, sx, sy, HOT)
	Sfx.playAt("Cannon", sx, sy, CANNON_NEAR)
end

-- THE SLUG LANDS ("ri"). A heavier shell burst, a fire shockwave, and a
-- kick: a real one for the shooter, a small one for anyone watching the spot.
local function railHit(self: Missiles, ev: any)
	local x = ev.tile % W
	local y = (ev.tile - x) / W
	local fx = self.rails and self.rails[ev.id]
	if fx ~= nil then
		fx.landed = 0
		self.rails[ev.id] = nil
	end
	shellBurst(self, x, y, ev.razed == 1 and 2.4 or 1.9)
	local wave = disc(self.root, 15)
	local stroke = Instance.new("UIStroke")
	stroke.Color = FIRE
	stroke.Thickness = 3
	stroke.Parent = wave
	atTile(wave, x, y)
	setRadius(wave, 0)
	self.fx[#self.fx + 1] = { kind = "wave", frame = wave, stroke = stroke, t = 0, life = BOMB_WAVE_LIFE, outer = (ev.r or 5) * 1.4 }
	local seen = Sfx.viewGain(x, y) > 0.55
	if seen then
		Sfx.playAt("Blast", x, y, { floor = 0.3 })
	else
		Sfx.playAt("Boom", x, y, { floor = 0.15 })
	end
	local mine = ev.owner == self.localId and self.localId ~= 0
	local kick = if mine then 7 elseif seen then 4 else 0
	if kick > self.shake then
		self.shake = kick
	end
end

function Missiles.onEvents(self: Missiles, list: { any }, tick: number?)
	Missiles.setTick(self, tick)
	for _, ev in list do
		local e = ev.e
		if e == "l" then
			launch(self, ev)
		elseif e == "b" then
			blast(self, ev)
		elseif e == "x" then
			expire(self, ev)
		elseif e == "s" then
			sam(self, ev)
		elseif e == "sh" then
			shell(self, ev)
		elseif e == "si" then
			impact(self, ev)
		elseif e == "pl" then
			plane(self, ev)
		elseif e == "pb" then
			bomb(self, ev)
		elseif e == "rf" then
			railFire(self, ev)
		elseif e == "ri" then
			railHit(self, ev)
		end
	end
end

-- ------------------------------------------------------------------ step ---

function Missiles.step(self: Missiles, dt: number)
	if self.shake > 0 then
		self.shake *= math.exp(-dt * (if self.shakeOwn then SHAKE_DECAY_OWN else SHAKE_DECAY))
		if self.shake < 0.15 then
			self.shake = 0
			self.shakeOwn = false
		end
	end

	local t = nowTick(self)

	for _, fl in self.flights do
		local last = fl.count - 1
		local fi = t - fl.startTick
		-- CLAMPED AT BOTH ENDS, and the far end is the one that matters: a
		-- missile whose blast event has not arrived yet must sit ON its target,
		-- not vanish. The clock is deliberately a little behind the server, so
		-- this happens on every single flight for a few frames.
		if fi < 0 then
			fi = 0
		elseif fi > last then
			fi = last
		end
		local x, y = samplePos(fl.curve, fi)
		atTile(fl.head, x, y)

		-- IT WENT OVER YOU. Once per flight, on the first frame the warhead is
		-- ON YOUR SCREEN and still has ground to cover -- so it is one crossing
		-- the view you are watching, rather than one arriving (that is the
		-- blast) or one leaving (that is the launch). A missile fired off
		-- screen at a target off screen never trips it, which is exactly right:
		-- this is the sound of something passing overhead, and nothing passed
		-- over anything you could see.
		--
		-- 0.8 is a little wider than the frame, not narrower: the corner of the
		-- screen is already 0.945, so this reaches a short way past the edge.
		-- Deliberate -- a warhead that clips the corner of your view did fly
		-- over you, and a threshold tight enough to mean "dead centre" would
		-- fire on almost nothing.
		if not fl.flew and fi > 1 and fi < last - 2 and Sfx.viewGain(x, y) > 0.8 then
			fl.flew = true
			Sfx.playAt("Flyby", x, y)
		end

		local ax, ay = samplePos(fl.curve, math.max(0, fi - 0.35))
		if x ~= ax or y ~= ay then
			fl.head.Rotation = math.deg(math.atan2(y - ay, x - ax)) - fl.nose
		end

		for i = 1, TRAIL_N do
			local d = fl.trail[i]
			local bi = fi - i * TRAIL_GAP
			if bi < 0 then
				d.Visible = false
			else
				d.Visible = true
				local tx, ty = samplePos(fl.curve, bi)
				atTile(d, tx, ty)
				local k = (i - 1) / (TRAIL_N - 1)
				local s = TRAIL_HEAD + (TRAIL_TAIL - TRAIL_HEAD) * k
				d.Size = UDim2.fromOffset(s, s)
				d.BackgroundTransparency = k * k
			end
		end

		if fl.ring then
			local p = last > 0 and (fi / last) or 1
			-- Scaled off the ring's own size rather than from a second radius
			-- write, so the closing disc and the crater it is closing inside
			-- can never disagree about how big the crater is.
			fl.lead.Size = UDim2.fromScale(fl.ring.Size.X.Scale * (1 - p), fl.ring.Size.Y.Scale * (1 - p))
			-- Two beats a second, tightening as it closes.
			local pulse = 0.5 + 0.5 * math.sin(t * (0.6 + p * 1.4))
			fl.ringStroke.Thickness = 1.5 + 2.5 * pulse
			fl.ringStroke.Transparency = 0.15 * pulse
		end
	end

	for id, pl in self.planes do
		local span = pl.t1 - pl.t0
		local p = (t - pl.t0) / span
		if pl.landed == nil then
			-- HELD ON THE TARGET until the bombs are heard, the warhead's rule:
			-- the clock runs a little behind the server, so this is every
			-- sortie for a few frames.
			if p > 1 then
				p = 1
			end
		else
			-- Past the target at the same speed, fading, then gone.
			pl.landed += dt
			local over = pl.landed / PLANE_OVERRUN
			if over >= 1 then
				destroyPlane(self, id)
				continue
			end
			p = 1 + (pl.landed * Config.TICK_RATE) / span
			pl.img.ImageTransparency = over * over
		end
		if p < 0 then
			p = 0
		end
		local x = pl.x0 + (pl.x1 - pl.x0) * p
		local y = pl.y0 + (pl.y1 - pl.y0) * p
		atTile(pl.img, x, y)
		-- IT WENT OVER YOU -- the warhead's rule and threshold, see above.
		if not pl.flew and p > 0.05 and p < 0.9 and Sfx.viewGain(x, y) > 0.8 then
			pl.flew = true
			Sfx.playAt("Flyby", x, y)
		end
		if p > 0 and pl.landed == nil then
			pl.puffT += dt
			if pl.puffT >= PLANE_PUFF_GAP then
				pl.puffT = 0
				trail(self, x, y, CONTRAIL:Lerp(pl.tint, 0.35))
			end
		end
	end

	for id, s in self.sams do
		local p = math.clamp((t - s.start) / s.ticks, 0, 1)
		local x = s.x0 + (s.x1 - s.x0) * p
		local y = s.y0 + (s.y1 - s.y0) * p
		atTile(s.frame, x, y)
		s.frame.Rotation = math.deg(math.atan2(s.y1 - s.y0, s.x1 - s.x0))
		-- An interceptor whose kill event never arrived (its target died to
		-- something else) would otherwise hang at the aimpoint forever.
		if p >= 1 and t - s.start > s.ticks + 20 then
			destroySam(self, id)
		end
	end

	for id, s in self.shells do
		local span = s.t1 - s.t0
		local p = (t - s.t0) / span
		local q = p < 0 and 0 or (p > 1 and 1 or p)
		local lx = s.x1 - s.x0
		local ly = s.y1 - s.y0
		-- The lob: a parabola over the straight line, apex at mid-flight, and
		-- the nose follows its tangent so it climbs, tips and dives.
		local lift = s.loft * 4
		atTile(s.frame, s.x0 + lx * q, s.y0 + ly * q - lift * q * (1 - q))
		s.frame.Rotation = math.deg(math.atan2(ly - lift * (1 - 2 * q), lx))
		for i, d in s.trail do
			local qi = q - (i * SHELL_TRAIL_GAP) / span
			if qi <= 0 or p > 1 then
				d.Visible = false
			else
				d.Visible = true
				atTile(d, s.x0 + lx * qi, s.y0 + ly * qi - lift * qi * (1 - qi))
			end
		end
		-- A shell whose impact never arrived (a packet lost, a round that
		-- ended) would otherwise sit on its aimpoint forever.
		if p > 1 and t - s.t1 > 20 then
			destroyShell(self, id)
		end
	end

	for i = #self.fx, 1, -1 do
		local fx = self.fx[i]
		fx.t += dt
		local k = fx.t / fx.life
		if k >= 1 then
			fx.frame:Destroy()
			table.remove(self.fx, i)
		elseif fx.kind == "ball" then
			-- Out to the full radius fast, then a long fade: the shape of the
			-- thing is established in a quarter of a second and the rest is it
			-- burning down through fire to smoke. Colour is on its OWN clock,
			-- not the size's -- white for the first frames however fast the
			-- ball is growing, because the flash is what the eye catches.
			local grow = math.min(1, fx.t / FLASH_GROW) ^ 0.55
			local r0 = fx.inner * 0.35
			setRadius(fx.frame, r0 + (fx.outer - r0) * grow)
			local heat = math.clamp((fx.t - 0.05) / 0.28, 0, 1)
			fx.frame.BackgroundColor3 = heat < 1 and HOT:Lerp(FIRE, heat) or FIRE:Lerp(SMOKE, k ^ 0.8)
			fx.frame.BackgroundTransparency = k * k
			-- Sized against the BALL, not the map, so it stays a fraction of
			-- whatever the fireball currently is.
			local f = 0.55 * (1 - k ^ 0.45)
			fx.core.Size = UDim2.fromScale(f, f)
			fx.core.BackgroundTransparency = math.min(1, k * 2.4)
		elseif fx.kind == "burst" then
			-- Out fast and thinning as it goes. The SPEED is the read: an
			-- interception is over before the eye can track it, and a ring that
			-- eases would read as a slow bloom instead of something breaking.
			local s = fx.px * k ^ 0.42
			fx.frame.Size = UDim2.fromOffset(s, s)
			fx.stroke.Thickness = 0.5 + 3 * (1 - k)
			fx.stroke.Transparency = k * k
			-- The core burns white to orange and is gone well before the ring,
			-- so what is left at the end is an expanding empty circle.
			local c = fx.corePx * (1 - k ^ 0.7)
			fx.core.Size = UDim2.fromOffset(c, c)
			fx.core.BackgroundColor3 = HOT:Lerp(FIRE, math.min(1, k * 2.2))
			fx.core.BackgroundTransparency = math.min(1, k * 1.8)
		elseif fx.kind == "shellburst" then
			-- The ring races out and cools: fire at the start, smoke by the end.
			local s = fx.px * k ^ 0.42
			fx.frame.Size = UDim2.fromOffset(s, s)
			fx.stroke.Thickness = 0.5 + 3 * (1 - k)
			fx.stroke.Transparency = k * k
			fx.stroke.Color = FIRE:Lerp(SMOKE, k)
			-- The core POPS to full in SHELL_BURST_POP, then burns down white to
			-- orange and is gone well before the ring.
			local pop = math.min(1, fx.t / SHELL_BURST_POP)
			local burn = math.max(0, (fx.t - SHELL_BURST_POP) / (fx.life - SHELL_BURST_POP))
			local c = fx.corePx * pop * (1 - burn ^ 0.7)
			fx.core.Size = UDim2.fromOffset(c, c)
			fx.core.BackgroundColor3 = HOT:Lerp(FIRE, math.min(1, burn * 2.2))
			fx.core.BackgroundTransparency = math.min(1, burn * 1.8)
			-- Embers: out fast on an ease-out, shrinking and dimming as they land.
			local reach = fx.px * SHELL_SPARK_REACH * 0.5
			for _, sp in fx.sparks do
				local d = reach * sp.pace * (1 - (1 - k) ^ 2.2)
				sp.frame.Position = UDim2.new(0.5, sp.ax * d, 0.5, sp.ay * d)
				local ss = SHELL_SPARK_PX * (1 - 0.5 * k)
				sp.frame.Size = UDim2.fromOffset(ss, ss)
				sp.frame.BackgroundColor3 = HOT:Lerp(FIRE, math.min(1, k * 1.6))
				sp.frame.BackgroundTransparency = k ^ 1.5
			end
		elseif fx.kind == "scorch" then
			-- The ground mark: sits, then fades.
			fx.frame.BackgroundTransparency = SHELL_SCORCH_T + (1 - SHELL_SCORCH_T) * k ^ 1.5
		elseif fx.kind == "wave" then
			setRadius(fx.frame, fx.outer * WAVE_REACH * k ^ 0.45)
			fx.stroke.Thickness = 1 + 5 * (1 - k)
			fx.stroke.Transparency = k * k
		elseif fx.kind == "rail" then
			-- In flight: a RAIL_TAIL streak behind the head on the sim clock.
			-- Landed: the whole line flares, thins and burns down fire to smoke.
			if fx.landed == nil then
				local p = math.clamp((t - fx.t0) / (fx.t1 - fx.t0), 0, 1)
				local pa = if fx.len > 0 then math.max(0, p - RAIL_TAIL / fx.len) else 0
				layArc(fx, pa, p, RAIL_THICK)
				atTile(fx.head, railAt(fx, p))
				-- An impact that never arrived (lost packet, round over).
				if p >= 1 and t - fx.t1 > 20 then
					fx.t = fx.life
				end
			else
				fx.landed += dt
				local q = math.clamp(fx.landed / RAIL_FADE, 0, 1)
				layArc(fx, 0, 1, 1 + RAIL_THICK * (1 - q))
				for _, seg in fx.segs do
					seg.glow.BackgroundColor3 = RAIL_GLOW:Lerp(SMOKE, q)
					seg.glow.BackgroundTransparency = 0.3 + 0.7 * q
					seg.core.BackgroundColor3 = RAIL_CORE:Lerp(FIRE, q)
					seg.core.BackgroundTransparency = math.min(1, q * 1.6)
				end
				fx.head.Visible = false
				if q >= 1 then
					fx.t = fx.life
				end
			end
		elseif fx.kind == "trail" then
			-- Grows a little and thins: exhaust spreading, at a size that stays
			-- a thread rather than a cloud.
			local s = 4 + 7 * k
			fx.frame.Size = UDim2.fromOffset(s, s)
			fx.frame.BackgroundTransparency = 0.4 + 0.6 * k
		else
			local s = 10 + 26 * k
			fx.frame.Size = UDim2.fromOffset(s, s)
			fx.frame.BackgroundTransparency = k
		end
	end
end

function Missiles.count(self: Missiles): (number, number)
	local f, s = 0, 0
	for _ in self.flights do
		f += 1
	end
	for _ in self.sams do
		s += 1
	end
	return f, s
end

return Missiles
