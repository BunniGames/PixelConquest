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
-- a one-tick correction is ten tiles of jump on an atom bomb -- ten pixels of
-- teleport at a normal zoom, on the one object in the game the eye is
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
local Nukes = require(script.Parent.Nukes)
local Palette = require(script.Parent.Palette)

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

local HEAD_LEN = 18
local HEAD_THICK = 6
local SAM_LEN = 10
local SAM_THICK = 3

-- The exhaust: dots dropped every TRAIL_GAP ticks behind the head. At an atom
-- bomb's ten tiles a tick this spans about eighty tiles, which is a streak you
-- can pick up from across the map without being a line drawn over half of it.
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

-- Screen pixels of camera kick at detonation, per tile of outer radius. An
-- atom bomb is 30 tiles and lands at about five pixels; a hydrogen bomb is a
-- hundred and clips at SHAKE_MAX. Decays fast enough that it reads as an
-- impact rather than as a broken camera.
local SHAKE_PER_TILE = 0.17
local SHAKE_MAX = 13
local SHAKE_DECAY = 7

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
		fx = {} :: { any },

		localId = 0,
		-- The terrain buffer, borrowed from the renderer, so the blast set can
		-- be regenerated. Nil until setMap: no map, no craters.
		terrain = nil :: buffer?,
		-- Called with (tiles, count) the instant a warhead lands. The client
		-- points it at Renderer.setFalloutTiles.
		onFallout = nil :: (({ number }, number) -> ())?,

		tickBase = 0,
		tickTime = os.clock(),
		haveTick = false,

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

local function destroySam(self: Missiles, id: number)
	local s = self.sams[id]
	if s == nil then
		return
	end
	self.sams[id] = nil
	s.frame:Destroy()
end

function Missiles.clear(self: Missiles)
	for id in self.flights do
		destroyFlight(self, id)
	end
	for id in self.sams do
		destroySam(self, id)
	end
	for _, fx in self.fx do
		fx.frame:Destroy()
	end
	table.clear(self.fx)
	self.shake = 0
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
local function puff(self: Missiles, x: number, y: number, ink: Color3)
	local f = disc(self.root, 11)
	f.Size = UDim2.fromOffset(10, 10)
	f.BackgroundColor3 = ink
	atTile(f, x, y)
	self.fx[#self.fx + 1] = { kind = "puff", frame = f, t = 0, life = PUFF_LIFE, ink = ink }
end

local function launch(self: Missiles, ev: any)
	destroyFlight(self, ev.id)

	local fl = Nukes.flight(ev)
	local pr, pg, pb = Palette.colorFor(ev.owner, self.localId)
	fl.tint = Color3.fromRGB(pr, pg, pb)

	fl.head = capsule(self.root, HEAD_LEN, HEAD_THICK, HOT, 12)
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
	puff(self, ev.src % W, (ev.src - ev.src % W) / W, HOT)
end

local function blast(self: Missiles, ev: any)
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

	local kick = math.min(SHAKE_MAX, ev.outer * SHAKE_PER_TILE)
	if kick > self.shake then
		self.shake = kick
	end
end

-- A missile that stopped being one without landing: shot down, or caught in
-- somebody else's blast. `hit` is true only for the MIRV carrier reaching its
-- separation point and for a SAM reaching its prey, and neither of those wants
-- an air burst drawn over it -- the warheads and the kill say it already.
local function expire(self: Missiles, ev: any)
	local fl = self.flights[ev.id]
	if fl then
		if not ev.hit then
			local x, y = samplePos(fl.curve, nowTick(self) - fl.startTick)
			puff(self, x, y, HOT)
		end
		destroyFlight(self, ev.id)
	end
	local s = self.sams[ev.id]
	if s then
		if ev.hit then
			puff(self, s.x1, s.y1, SAM_INK)
		end
		destroySam(self, ev.id)
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
		end
	end
end

-- ------------------------------------------------------------------ step ---

function Missiles.step(self: Missiles, dt: number)
	if self.shake > 0 then
		self.shake *= math.exp(-dt * SHAKE_DECAY)
		if self.shake < 0.15 then
			self.shake = 0
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

		local ax, ay = samplePos(fl.curve, math.max(0, fi - 0.35))
		if x ~= ax or y ~= ay then
			fl.head.Rotation = math.deg(math.atan2(y - ay, x - ax))
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
		elseif fx.kind == "wave" then
			setRadius(fx.frame, fx.outer * WAVE_REACH * k ^ 0.45)
			fx.stroke.Thickness = 1 + 5 * (1 - k)
			fx.stroke.Transparency = k * k
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
