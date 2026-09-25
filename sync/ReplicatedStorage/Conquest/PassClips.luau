--!strict
-- Conquest :: PassClips  (client)
-- A short looping diorama of what a pass DOES, drawn in a card's drawer: a
-- battery shelling a city to the ground, a bomber leaving its field and
-- flattening one, a mega nuke dropping on one. Owner, 2026-09-22: "When I
-- hover over them. I want it to play a short clip of what it can do."
--
-- DRAWN BY HAND, WITH THE GAME'S OWN PARTS. The stickers are the rail's
-- (Icons), the chip is Structures' chip -- owner ring, dark plate, glyph --
-- and every effect is Missiles' recipe with its numbers: the gun's recoil and
-- muzzle flash, the lobbed shell with three smoke dots, the shell burst (core
-- pop, fire ring cooling to smoke, six embers, three puffs, a scorch), the
-- bomber's contrail and the bomb's fireball and shockwave. What is NOT reused
-- is those modules themselves: Structures keeps its chip scale in a MODULE
-- field, Missiles runs on the server's tick clock and asks Sfx where the
-- camera is, and neither has a map under it here. A copy of the recipe costs
-- three hundred lines; a second instance of the real thing would have reached
-- into the live round.
--
-- THE POLISH (owner: "polish up the animations without it looking too
-- expensive") is all read, no spend: a shell that swells at the top of its
-- lob so the arc has depth; a puff of smoke off the muzzle; a city that
-- darkens as it is hurt, sinks as it falls and leaves rubble; the stage
-- jolting when a building goes; a bomber that DROPS the bomb -- a thing that
-- falls -- rather than the ground simply exploding under it. One puff, three
-- rubble squares and one bomb frame is the whole bill.
--
-- THE BOMBING RUN IS A DIVE (owner, 2026-09-22: "make the airplane appear to
-- be descending as its bombing the building"). The bomber climbs off its
-- field, then comes DOWN the whole way to the city, steepening as it nears
-- the release, lets the bomb go low and pulls up and away. Height is drawn
-- two ways, because a top-down sprite has none of its own: the plane sits
-- that many tiles above its own SHADOW on the ground, and the shadow
-- sharpens and closes under it as it comes down. One more frame.
--
-- THE MEGA NUKE COMES IN FROM THE SIDE (owner, 2026-09-22, twice: "I dont
-- want the nuke to come out the building, i just want it to drop", then
-- "make the nuke come sideways and in ... i dont want it to be dropped from
-- the top", then, after a level run that snapped into a dive, "just make it
-- curve down and hit it while the warhead's angle also changes"). No silo
-- on the stage: the warhead flies in from off your edge on ONE ARC -- a
-- touch of climb, over an apex near the top edge, and curving down onto a
-- red aim ring closing on the city, its nose on the arc's tangent every
-- frame and its exhaust strung out behind it along the same arc -- and the
-- crater is twice an atom bomb's radius, four times its ground, which is
-- the whole of the pitch.
--
-- THE LATE-GAME PAIR (2026-09-24, owner: "did you make the railgun and mirv
-- a gamepass with animations like everything else"). The RAILGUN stands at
-- your far edge and the city at theirs -- no range is the pitch, so the shot
-- crosses the whole stage: the gun heats up, kicks, a slug drags Missiles'
-- fire streak across, and on impact the whole line flares and burns down
-- to smoke while the city goes in one hit. (Fire, not the first cut's cyan
-- electric beam -- owner 2026-09-24: "too futuristic".) The SCATTERSHOT is the mega
-- nuke's arc with the atom bomb's sticker; at the crest it SPLITS, and 4-6
-- smaller warheads (a different count each loop) peel off onto red rings
-- around the city, each leaving its own small crater after the big one.
--
-- ONE AUTHORED SPACE, IN TILES, AS WIDE AS THE WINDOW. The stage is
-- STAGE_H tiles tall and as many wide as the window's aspect makes it, so
-- a tile is square at any size and the picture fills the drawer edge to
-- edge rather than sitting in the middle of it. The gun and the city stand
-- at FRACTIONS of the width and every flight time is a distance over a
-- speed, so a wide lobby drawer and a narrower in-game one play the same
-- scene at the same pace. Nothing here is an Offset pixel except strokes.
--
-- SILENT. The shop has its own sounds, and a boom looping under a hover would
-- be the sound of the lobby.

local RunService = game:GetService("RunService")

local Icons = require(script.Parent.Icons)
local Palette = require(script.Parent.Palette)

local PassClips = {}
PassClips.__index = PassClips

-- Which passes have a clip. Anything else gets nil from `new`.
PassClips.KEYS = { ARTILLERY = true, AIRSTRIKE = true, MEGANUKE = true, RAILGUN = true, SCATTERSHOT = true }

-- ----------------------------------------------------------------- stage ---

local STAGE_H = 16
-- The width the clip is drawn at when the caller gives no aspect.
PassClips.ASPECT = 2.5

-- The game's inks, verbatim (Missiles / Structures).
local HOT = Color3.fromRGB(255, 246, 220)
local FIRE = Color3.fromRGB(255, 164, 56)
local SMOKE = Color3.fromRGB(84, 66, 58)
local DARK = Color3.fromRGB(10, 14, 24)
local SHELL_INK = Color3.fromRGB(255, 214, 120)
local CONTRAIL = Color3.fromRGB(226, 232, 240)
local HP_GREEN = Color3.fromRGB(88, 206, 98)
local HP_RED = Color3.fromRGB(202, 54, 46)
local RUBBLE_INK = Color3.fromRGB(64, 60, 58)
local WHITE = Color3.new(1, 1, 1)
-- The warhead's aimpoint ring (Missiles' one red), and the ground it leaves:
-- the renderer's fallout, scorched olive in the hollows and acid green on the
-- rises, at its 0.9.
local THREAT = Color3.fromRGB(255, 88, 60)
local FALLOUT_DARK = Color3.fromRGB(48, 62, 32)
local FALLOUT_ACID = Color3.fromRGB(136, 176, 56)

-- Where things stand: the launcher this far across, the city this far, the
-- border between them, all on one row so the shot reads left to right the
-- way the perk list does. PER CLIP, because the distance IS the pitch
-- (owner, 2026-09-22: "communicate artillery is for shorter distances,
-- while airbase is for longer distances"): the gun stands a hop from the
-- border and shells a city just over it, the field sits at your far edge
-- and its bomber crosses nearly the whole stage. The mega nuke's city keeps
-- the room its crater needs on the right.
local CHIP = 4.4
local BORDER_F = 0.47
local ACTORS_F = {
	ARTILLERY = { 0.36, 0.60 },
	AIRSTRIKE = { 0.06, 0.90 },
	MEGANUKE = { 0.2, 0.74 },
	RAILGUN = { 0.05, 0.93 },
	SCATTERSHOT = { 0.2, 0.64 },
}
local ROW_Y = 9.2
local BORDER_W = 0.6
local GRAIN_PER_40 = 22

-- Sizes as fractions of the chip. In the game these are Offset pixels sized
-- for a chip seen at about 3.5x zoom (a 46 px burst on a 45 px chip); here
-- they are tied to the chip so the picture is the same at every drawer size.
local BURST_D = CHIP * 1.1
local BURST_CORE_D = CHIP * 0.52
local SPARK_D = CHIP * 0.07
local PUFF_D0, PUFF_D1 = CHIP * 0.24, CHIP * 0.85
local SCORCH_D = BURST_D * 0.7
local SHELL_LEN, SHELL_THICK = CHIP * 0.15, CHIP * 0.075
local TRAIL_D = CHIP * 0.1
local PLANE_D = CHIP * 0.8
local BOMB_R = CHIP * 0.85
local BOMB_LEN, BOMB_THICK = CHIP * 0.13, CHIP * 0.06
local RUBBLE_D = CHIP * 0.14
local HP_W, HP_H, HP_LIFT = 0.4, 0.075, 0.1 -- of the chip
-- THE MEGA NUKE: its own sticker (Icons.MEGA_NUKE) for a warhead, the
-- exhaust behind it, and a crater twice an atom bomb's radius -- four times
-- its ground, which is the whole of the pitch, so the blast is drawn at a
-- size that swallows the city and half the stage with it.
local NUKE_D = CHIP * 0.95
local NUKE_TRAIL_N = 14
local NUKE_TRAIL_STEP = 0.035 -- of the run, between exhaust dots
local NUKE_TRAIL_HEAD, NUKE_TRAIL_TAIL = CHIP * 0.16, CHIP * 0.05
local NUKE_INNER, NUKE_OUTER = CHIP * 1.3, CHIP * 3.2 -- radii, in tiles
-- THE ARC (see the header): one smooth curve from off your edge to the
-- city, a cubic Bezier in tiles. In a head's width off the edge, this far
-- above the row; the first inner point pulls the arc UP -- this far across,
-- this far above the top edge -- so it climbs a little and crests near the
-- top; the second, this far short of the city and level with the top edge,
-- is what makes the last stretch steep, about fifty-five degrees at the
-- ground. Nothing is straight and the heading never stops changing, which
-- is the whole ask (owner, 2026-09-22: a level run that snapped into a
-- dive "looks like ass, just make it curve down and hit it while the
-- warhead's angle also changes"). THE HEAD MOVES BY ARC LENGTH, not by the
-- curve's own parameter -- that parameter crawls on the short last leg and
-- a warhead does not slow down to land -- and NUKE_ACCEL > 1 has it
-- arriving faster than it entered. The clock is the arc's length over a
-- speed, faster than the bomber's, floored like every flight here.
local NUKE_ENTRY_H = CHIP * 1.4
local NUKE_ARC_UP_F, NUKE_ARC_UP_Y = 0.35, 1.0 -- crest ~1.2 tiles in: the head's top brushes the edge, no more
local NUKE_ARC_DIVE_BACK, NUKE_ARC_DIVE_Y = CHIP * 1.6, -1.0
local NUKE_SPEED, NUKE_TIME_MIN = 55, 0.9
local NUKE_ACCEL = 1.15
local NUKE_ARC_SAMPLES = 64

-- THE RAILGUN: Missiles' fire inks and fade; the streak and the trail in
-- tiles of this stage. The charge is an orange disc closing on the gun
-- before the shot, the slug is fast enough that the trail is what you see.
local RAIL_GLOW = Color3.fromRGB(255, 120, 40)
local RAIL_CORE = Color3.fromRGB(255, 214, 110)
local RAIL_TAIL = 16
local RAIL_THICK = CHIP * 0.12
local RAIL_HEAD_D = CHIP * 0.22
local RAIL_FADE = 0.6
local RAIL_SPEED, RAIL_TIME_MIN = 200, 0.3
local RAIL_CHARGE = 0.55
local RAIL_CHARGE_D0, RAIL_CHARGE_D1 = CHIP * 1.5, CHIP * 0.25
local RAIL_WAVE = CHIP * 0.9
-- Missiles' slight arc: apex RAIL_ARC_H tiles over the chord (~6% of the
-- stage's span), drawn as RAIL_SEGS straight pieces along the curve.
local RAIL_ARC_H = CHIP * 0.45
local RAIL_SEGS = 10

-- THE SCATTERSHOT: the atom bomb's sticker and crater on the same arc as the
-- mega nuke, split at SCATTER_SPLIT of its run into warheads aimed at these
-- offsets from the city (in chips; the stage is 16 tall, so the spread is
-- wider than it is deep). The first SCATTER_MIN always fly; loop by loop the
-- count walks 4, 5, 6 -- the 4-6 the perk says.
local SCATTER_D = CHIP * 0.8
local SCATTER_INNER, SCATTER_OUTER = CHIP * 0.55, CHIP * 1.3
local SCATTER_SPLIT = 0.55
local SCATTER_MIN, SCATTER_MAX = 4, 6
local SCATTER_AIMS = {
	{ -2.1, -0.35 }, { 1.05, -0.9 }, { -0.9, 0.95 }, { 2.1, 0.4 }, { -1.0, -0.95 }, { 1.0, 0.98 },
}
local MIRV_D = CHIP * 0.5
local MIRV_INNER, MIRV_OUTER = CHIP * 0.3, CHIP * 0.7
local MIRV_TRAIL_N, MIRV_TRAIL_STEP = 6, 0.05
local MIRV_SPEED = 48
local MIRV_LAG = 0.06 -- each later warhead a touch slower, so they land in a ripple

-- The recipes' clocks, Missiles' and Structures' numbers.
local GUN_RECOIL_LIFE, GUN_RECOIL_KICK = 0.28, 0.12
local GUN_FLASH_LIFE, GUN_FLASH_SIZE = 0.14, 0.55
local GUN_MUZZLE_X, GUN_MUZZLE_Y = 0.76, 0.07
-- Tiles per second, and the least a flight may take: distance over speed
-- is what keeps a wide drawer and a narrow one at the same pace.
local SHELL_SPEED, SHELL_TIME_MIN = 60, 0.6
local PLANE_SPEED, PLANE_TIME_MIN = 45, 0.9
-- Missiles' fireball and shockwave clocks for a warhead, and the sticker's
-- nose: drawn at the bottom-right, so the heading is corrected by this.
local FLASH_LIFE, WAVE_LIFE = 1.7, 0.55
local NOSE_DEG = Icons.MEGA_NUKE_NOSE -- the mega sticker's nose (Icons: it lives with the art)
local NUKE_KICK = 0.7
local NUKE_HOLD = 1.0
local SHELL_LOFT, SHELL_LOFT_MAX = 0.28, 5
local SHELL_TRAIL, SHELL_TRAIL_GAP = 3, 0.06 -- dots, seconds apart
local BURST_LIFE, BURST_POP = 0.48, 0.06
local SPARKS, SPARK_REACH = 6, 0.85
local SMOKE_LIFE, SCORCH_LIFE, SCORCH_T = 0.9, 1.5, 0.6
local PLANE_PUFF_GAP, PLANE_PUFF_LIFE, PLANE_OVERRUN = 0.07, 0.5, 0.5
local BOMB_LIFE, BOMB_WAVE_LIFE, FLASH_GROW, WAVE_REACH = 0.85, 0.4, 0.26, 2.2
local PUFF_LIFE = 0.55
-- A building falling, and coming back for the next loop.
local COLLAPSE, REVIVE = 0.35, 0.3
-- The beats between shots, and the hold on the ruin before the loop.
local FIRST_SHOT, BETWEEN_SHOTS, RUIN_HOLD = 0.25, 0.5, 1.3
local LAUNCH_AT, RAID_HOLD = 0.35, 2.2

-- The polish, all cheap (see the header).
local SHELL_ARC_SWELL = 0.6 -- the shell draws this much bigger at the top of its lob
local MUZZLE_SMOKE_LIFE = 0.7
local DAMAGE_TINT = 0.4 -- how far toward DARK the sticker goes at zero health
local SINK = 0.45 -- tiles a razed chip drops as it goes
local RUBBLE = 3
local KICK_TILES, KICK_DECAY = 0.28, 11 -- the stage's jolt on a raze, and how fast it settles
local PLANE_RISE = 0.35 -- seconds to come up to size off the field
local PLANE_RISE_FROM = 0.55
local PLANE_BOB, PLANE_BOB_RATE = 0.16, 7 -- tiles, rad/s
local PLANE_BANK, PLANE_BANK_RATE = 4, 5 -- degrees, rad/s
local BOMB_DROP = 0.3 -- seconds the bomb falls before it lands
-- THE DIVE (see the header). Heights are tiles above the ground line the
-- shadow runs along, which sits a hair above the row so the plane crosses
-- the city and not its doorstep. The run is a climb for its first
-- PLANE_CLIMB_F, then a descent whose curve steepens toward the release
-- (PLANE_DIVE_POW: 1 would be a straight glide); past the release it pulls
-- PLANE_PULL_UP tiles back up over the overrun with its nose PLANE_PULL_DEG
-- above level. The shadow is an ellipse under the sprite, faint and small
-- while the plane is high, dark and full-size as it comes down.
local PLANE_GROUND_LIFT = CHIP * 0.1
local PLANE_ALT_TAKEOFF = CHIP * 0.2
local PLANE_ALT_HIGH = CHIP * 1.25
local PLANE_ALT_LOW = CHIP * 0.3
local PLANE_CLIMB_F = 0.3
local PLANE_DIVE_POW = 1.7
local PLANE_PULL_UP = CHIP * 0.9
local PLANE_PULL_DEG = 14
local PLANE_SHADOW_D = PLANE_D * 0.75
local PLANE_SHADOW_SQUASH = 0.45
local PLANE_SHADOW_T_HIGH, PLANE_SHADOW_T_LOW = 0.86, 0.5
local PLANE_SHADOW_SHRINK = 0.35 -- how much smaller the shadow is at full height

-- ------------------------------------------------------------------ util ---
-- Positions and sizes are tiles of THIS clip's stage, whose width is its own.

local function at(self: any, f: GuiObject, x: number, y: number)
	f.Position = UDim2.fromScale(x / self.W, y / STAGE_H)
end

local function sized(self: any, f: GuiObject, w: number, h: number)
	f.Size = UDim2.fromScale(w / self.W, h / STAGE_H)
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

-- Missiles' layBeam in this stage's tiles: a frame laid from one point to
-- another, `thick` tiles across. A tile is square, so Rotation is honest.
local function beamAt(self: any, f: GuiObject, x0: number, y0: number, x1: number, y1: number, thick: number)
	local dx, dy = x1 - x0, y1 - y0
	at(self, f, (x0 + x1) * 0.5, (y0 + y1) * 0.5)
	sized(self, f, math.max(math.sqrt(dx * dx + dy * dy), 0.3), thick)
	f.Rotation = math.deg(math.atan2(dy, dx))
end

-- Missiles' capsule: a rounded body with the dark outline every pin wears.
local function capsule(self: any, len: number, thick: number, fill: Color3, z: number): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = fill
	f.BorderSizePixel = 0
	f.ZIndex = z
	sized(self, f, len, thick)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = DARK
	stroke.Thickness = 1
	stroke.Transparency = 0.35
	stroke.Parent = f
	f.Parent = self.stage
	return f
end

local function c3(r: number, g: number, b: number): Color3
	return Color3.fromRGB(math.clamp(math.floor(r + 0.5), 0, 255), math.clamp(math.floor(g + 0.5), 0, 255), math.clamp(math.floor(b + 0.5), 0, 255))
end

-- A nation laid over plains, the renderer's own arithmetic (Palette): the
-- nation desaturated to 0.85 and blended in at 0.588 over the land colour.
local function territory(id: number): (Color3, Color3)
	local lr, lg, lb = Palette.terrainColor(1, 5)
	local nr, ng, nb = Palette.colorFor(id, 1)
	nr, ng, nb = Palette.desaturate(nr, ng, nb, Palette.TERRITORY_SATURATION)
	local a = Palette.TERRITORY_ALPHA
	local r, g, b = lr + (nr - lr) * a, lg + (ng - lg) * a, lb + (nb - lb) * a
	local dr, dg, db = Palette.darken(r, g, b, 0.16)
	return c3(r, g, b), c3(dr, dg, db)
end

-- ------------------------------------------------------------------ chip ---
-- Structures.buildChip, to the number: owner ring, dark plate at 0.898, the
-- sticker at 0.92 overhanging onto the ring, corner by kind.

local function chip(self: any, image: string, radius: number, owner: Color3, x: number, y: number): any
	local f = Instance.new("Frame")
	f.Name = "Chip"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BackgroundColor3 = owner
	f.BorderSizePixel = 0
	f.ZIndex = 5
	sized(self, f, CHIP, CHIP)
	at(self, f, x, y)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(radius, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = DARK
	stroke.Thickness = 1.75
	stroke.Parent = f

	local plate = Instance.new("Frame")
	plate.Name = "Plate"
	plate.BackgroundColor3 = DARK
	plate.BorderSizePixel = 0
	plate.AnchorPoint = Vector2.new(0.5, 0.5)
	plate.Position = UDim2.fromScale(0.5, 0.5)
	plate.Size = UDim2.fromScale(0.898, 0.898)
	plate.ZIndex = 6
	plate.Parent = f
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(radius, 0)
	pc.Parent = plate

	local glyph = Instance.new("ImageLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.ScaleType = Enum.ScaleType.Fit
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.Size = UDim2.fromScale(0.92, 0.92)
	glyph.Image = image
	glyph.ZIndex = 7
	Icons.resample(glyph)
	glyph.Parent = f

	local scale = Instance.new("UIScale")
	scale.Parent = f
	f.Parent = self.stage
	return { frame = f, stroke = stroke, plate = plate, glyph = glyph, scale = scale, x = x, y = y, hpBar = nil :: Frame?, hpFill = nil :: Frame? }
end

-- How far gone a chip is drawn: 0 standing, 1 gone.
local function fade(m: any, k: number)
	m.frame.BackgroundTransparency = k
	m.stroke.Transparency = k
	m.plate.BackgroundTransparency = k
	m.glyph.ImageTransparency = k
end

-- Structures.setHealth: the gunboat's bar over the chip, red track, green
-- fill, hidden while unhurt. The sticker also darkens with the damage, so a
-- hurt building reads hurt without the bar.
local function setHealth(m: any, hp: number?)
	m.glyph.ImageColor3 = WHITE:Lerp(DARK, (1 - (hp or 1)) * DAMAGE_TINT)
	if hp == nil or hp >= 1 then
		if m.hpBar then
			m.hpBar.Visible = false
		end
		return
	end
	local track = m.hpBar
	if track == nil then
		track = Instance.new("Frame")
		track.Name = "Health"
		track.AnchorPoint = Vector2.new(0.5, 1)
		track.BackgroundColor3 = HP_RED
		track.BorderSizePixel = 0
		track.Size = UDim2.fromScale(HP_W, HP_H)
		track.Position = UDim2.fromScale(0.5, -HP_LIFT)
		track.ZIndex = 8
		local edge = Instance.new("UIStroke")
		edge.Color = DARK
		edge.Thickness = 1
		edge.Transparency = 0.25
		edge.Parent = track
		local green = Instance.new("Frame")
		green.Name = "Fill"
		green.AnchorPoint = Vector2.new(0, 0.5)
		green.Position = UDim2.fromScale(0, 0.5)
		green.Size = UDim2.fromScale(1, 1)
		green.BackgroundColor3 = HP_GREEN
		green.BorderSizePixel = 0
		green.ZIndex = 9
		green.Parent = track
		track.Parent = m.frame
		m.hpBar, m.hpFill = track, green
	end
	track.Visible = true
	m.hpFill.Size = UDim2.fromScale(math.max(hp, 0.08), 1)
end

-- ------------------------------------------------------------------- fx ----
-- Missiles' effect list, the same kinds and the same step arithmetic.

local function puff(self: any, x: number, y: number, ink: Color3, life: number?, d0: number?, d1: number?)
	local f = disc(self.stage, 11)
	sized(self, f, d0 or PUFF_D0, d0 or PUFF_D0)
	f.BackgroundColor3 = ink
	at(self, f, x, y)
	self.fx[#self.fx + 1] = { kind = "puff", frame = f, t = 0, life = life or PUFF_LIFE, d0 = d0 or PUFF_D0, d1 = d1 or PUFF_D1 }
end

local function shellBurst(self: any, x: number, y: number, scale: number)
	local d = BURST_D * scale
	local scorch = disc(self.stage, 10)
	sized(self, scorch, SCORCH_D * scale, SCORCH_D * scale)
	scorch.BackgroundColor3 = DARK
	scorch.BackgroundTransparency = SCORCH_T
	at(self, scorch, x, y)
	self.fx[#self.fx + 1] = { kind = "scorch", frame = scorch, t = 0, life = SCORCH_LIFE }

	local ring = disc(self.stage, 14)
	sized(self, ring, 0.1, 0.1)
	local stroke = Instance.new("UIStroke")
	stroke.Color = FIRE
	stroke.Thickness = 2
	stroke.Parent = ring
	at(self, ring, x, y)

	local core = disc(ring, 15)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.Size = UDim2.fromScale(0, 0)
	core.BackgroundColor3 = HOT
	core.BackgroundTransparency = 0

	local sparks = table.create(SPARKS)
	for i = 1, SPARKS do
		local sp = disc(ring, 16)
		sp.BackgroundColor3 = HOT
		sp.BackgroundTransparency = 0
		sp.Position = UDim2.fromScale(0.5, 0.5)
		local a = (i - 1) / SPARKS * math.pi * 2 + math.random() * 0.9
		sparks[i] = { frame = sp, ax = math.cos(a), ay = math.sin(a), pace = 0.7 + math.random() * 0.6 }
	end
	self.fx[#self.fx + 1] = {
		kind = "shellburst", frame = ring, stroke = stroke, core = core, sparks = sparks, t = 0,
		life = BURST_LIFE, d = d, coreD = BURST_CORE_D * scale,
	}
	puff(self, x, y, SMOKE, SMOKE_LIFE)
	puff(self, x + (math.random() - 0.5) * 1.6, y - 0.4 - math.random() * 0.6, SMOKE, SMOKE_LIFE)
	puff(self, x + (math.random() - 0.5) * 1.6, y - 0.8 - math.random() * 0.6, SMOKE, SMOKE_LIFE * 1.15)
end

local function bombBurst(self: any, x: number, y: number)
	local ball = disc(self.stage, 13)
	ball.BackgroundColor3 = HOT
	at(self, ball, x, y)
	sized(self, ball, BOMB_R * 0.4, BOMB_R * 0.4)
	local core = disc(ball, 14)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.BackgroundColor3 = HOT
	self.fx[#self.fx + 1] = { kind = "ball", frame = ball, core = core, t = 0, life = BOMB_LIFE, inner = BOMB_R * 0.55, outer = BOMB_R }

	local wave = disc(self.stage, 15)
	local stroke = Instance.new("UIStroke")
	stroke.Color = HOT
	stroke.Thickness = 4
	stroke.Parent = wave
	at(self, wave, x, y)
	sized(self, wave, 0, 0)
	self.fx[#self.fx + 1] = { kind = "wave", frame = wave, stroke = stroke, t = 0, life = BOMB_WAVE_LIFE, outer = BOMB_R * 0.7 }
end

local function stepFx(self: any, dt: number)
	for i = #self.fx, 1, -1 do
		local fx = self.fx[i]
		fx.t += dt
		local k = fx.t / fx.life
		if k >= 1 then
			fx.frame:Destroy()
			table.remove(self.fx, i)
		elseif fx.kind == "ball" then
			local grow = math.min(1, fx.t / FLASH_GROW) ^ 0.55
			local r0 = fx.inner * 0.35
			local r = r0 + (fx.outer - r0) * grow
			sized(self, fx.frame, r * 2, r * 2)
			local heat = math.clamp((fx.t - 0.05) / 0.28, 0, 1)
			fx.frame.BackgroundColor3 = heat < 1 and HOT:Lerp(FIRE, heat) or FIRE:Lerp(SMOKE, k ^ 0.8)
			fx.frame.BackgroundTransparency = k * k
			local f = 0.55 * (1 - k ^ 0.45)
			fx.core.Size = UDim2.fromScale(f, f)
			fx.core.BackgroundTransparency = math.min(1, k * 2.4)
		elseif fx.kind == "shellburst" then
			local s = fx.d * k ^ 0.42
			sized(self, fx.frame, s, s)
			fx.stroke.Thickness = 0.5 + 3 * (1 - k)
			fx.stroke.Transparency = k * k
			fx.stroke.Color = FIRE:Lerp(SMOKE, k)
			local pop = math.min(1, fx.t / BURST_POP)
			local burn = math.max(0, (fx.t - BURST_POP) / (fx.life - BURST_POP))
			-- The core is a child of the ring, so its Scale is of the ring:
			-- sized against the ring's current diameter to hold its own size.
			local c = fx.coreD * pop * (1 - burn ^ 0.7)
			local cs = if s > 0 then c / s else 0
			fx.core.Size = UDim2.fromScale(cs, cs)
			fx.core.BackgroundColor3 = HOT:Lerp(FIRE, math.min(1, burn * 2.2))
			fx.core.BackgroundTransparency = math.min(1, burn * 1.8)
			local reach = fx.d * SPARK_REACH * 0.5
			for _, sp in fx.sparks do
				local dd = reach * sp.pace * (1 - (1 - k) ^ 2.2)
				local ss = SPARK_D * (1 - 0.5 * k)
				-- In the ring's own Scale: the ring is s tiles across.
				local rs = if s > 0 then 1 / s else 0
				sp.frame.Position = UDim2.fromScale(0.5 + sp.ax * dd * rs, 0.5 + sp.ay * dd * rs)
				sp.frame.Size = UDim2.fromScale(ss * rs, ss * rs)
				sp.frame.BackgroundColor3 = HOT:Lerp(FIRE, math.min(1, k * 1.6))
				sp.frame.BackgroundTransparency = k ^ 1.5
			end
		elseif fx.kind == "scorch" then
			fx.frame.BackgroundTransparency = SCORCH_T + (1 - SCORCH_T) * k ^ 1.5
		elseif fx.kind == "wave" then
			local r = fx.outer * WAVE_REACH * k ^ 0.45
			sized(self, fx.frame, r * 2, r * 2)
			fx.stroke.Thickness = 1 + 5 * (1 - k)
			fx.stroke.Transparency = k * k
		elseif fx.kind == "charge" then
			-- Heat drawn IN: the disc closes on the gun and brightens.
			local s = fx.d0 + (fx.d1 - fx.d0) * k ^ 0.7
			sized(self, fx.frame, s, s)
			fx.frame.BackgroundTransparency = 0.9 - 0.75 * k
		elseif fx.kind == "beam" then
			-- Missiles' landed rail: the whole line flares, thins, burns to smoke.
			beamAt(self, fx.frame, fx.x0, fx.y0, fx.x1, fx.y1, RAIL_THICK * (0.25 + 1.4 * (1 - k)))
			fx.frame.BackgroundColor3 = RAIL_GLOW:Lerp(SMOKE, k)
			fx.frame.BackgroundTransparency = 0.1 + 0.9 * k
			fx.core.BackgroundColor3 = RAIL_CORE:Lerp(FIRE, k)
			fx.core.BackgroundTransparency = math.min(1, k * 1.6)
		elseif fx.kind == "trail" then
			local s = TRAIL_D * (1 + 1.75 * k)
			sized(self, fx.frame, s, s)
			fx.frame.BackgroundTransparency = 0.4 + 0.6 * k
		else
			local s = fx.d0 + (fx.d1 - fx.d0) * k
			sized(self, fx.frame, s, s)
			fx.frame.BackgroundTransparency = k
		end
	end
end

-- ------------------------------------------------------------------ build --

-- `parent` is the drawer's window; `aspect` its width over its height, which
-- sets how many tiles wide the stage is. Returns nil for a pass with no clip.
-- ------------------------------------------------------ the mega nuke's arc --
-- Built once per clip from where the city stands: the Bezier's four points in
-- tiles, and NUKE_ARC_SAMPLES points along it with their running length, so
-- the head can be placed by distance flown (arcAt) and turned along the
-- chord it is on (arcHeading). The trail reads the same table at earlier
-- shares, which is how it lies along the arc behind the head.
local function bez(p0: { number }, p1: { number }, p2: { number }, p3: { number }, u: number): (number, number)
	local v = 1 - u
	local a, b, c, d = v * v * v, 3 * v * v * u, 3 * v * u * u, u * u * u
	return a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1], a * p0[2] + b * p1[2] + c * p2[2] + d * p3[2]
end

local function arcOf(p0: { number }, p1: { number }, p2: { number }, p3: { number }): any
	local pts, cum = {}, {}
	local total = 0
	local px, py = bez(p0, p1, p2, p3, 0)
	for i = 0, NUKE_ARC_SAMPLES do
		local x, y = bez(p0, p1, p2, p3, i / NUKE_ARC_SAMPLES)
		total += math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
		pts[i + 1] = { x, y }
		cum[i + 1] = total
		px, py = x, y
	end
	return { pts = pts, cum = cum, total = total }
end

local function nukeArc(self: any): any
	local x1, y1 = self.rightX, ROW_Y
	return arcOf(
		{ -self.headD, ROW_Y - NUKE_ENTRY_H },
		{ x1 * NUKE_ARC_UP_F, NUKE_ARC_UP_Y },
		{ x1 - NUKE_ARC_DIVE_BACK, NUKE_ARC_DIVE_Y },
		{ x1, y1 }
	)
end

-- The two samples either side of a share `p` of the flight, by distance
-- along the arc (p ^ NUKE_ACCEL of its length), and how far between them.
local function arcSeg(arc: any, p: number): ({ number }, { number }, number)
	local d = math.clamp(p, 0, 1) ^ NUKE_ACCEL * arc.total
	local pts, cum = arc.pts, arc.cum
	for i = 2, #pts do
		if cum[i] >= d then
			local seg = cum[i] - cum[i - 1]
			return pts[i - 1], pts[i], if seg > 0 then (d - cum[i - 1]) / seg else 0
		end
	end
	return pts[#pts - 1], pts[#pts], 1
end

local function arcAt(arc: any, p: number): (number, number)
	local a, b, k = arcSeg(arc, p)
	return a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k
end

-- Degrees, 0 = right, growing clockwise (screen y down): the chord's own.
local function arcHeading(arc: any, p: number): number
	local a, b = arcSeg(arc, p)
	return math.deg(math.atan2(b[2] - a[2], b[1] - a[1]))
end

function PassClips.new(parent: Instance, key: string, aspect: number?): any?
	if not PassClips.KEYS[key] then
		return nil
	end
	local self = setmetatable({}, PassClips)
	self.key = key
	self.aspect = aspect or PassClips.ASPECT
	self.W = STAGE_H * self.aspect
	local actors = ACTORS_F[key]
	self.leftX = actors[1] * self.W
	self.rightX = actors[2] * self.W
	self.fx = {}
	self.rubble = {}
	self.cues = {}
	self.t = 0
	self.conn = nil :: RBXScriptConnection?
	self.shell = nil :: any
	self.plane = nil :: any
	-- `dropping`, not `bomb`: a nil field falls through the metatable to the
	-- PassClips.bomb METHOD, and the first reset then tried to index it.
	self.dropping = nil :: any
	self.missile = nil :: any
	self.mirvs = {} :: { any }
	self.slug = nil :: any
	self.salvo = SCATTER_MIN - 1 -- reset walks it to SCATTER_MIN for the first loop
	-- The warhead this clip flies: the mega nuke's own, or the atom bomb's
	-- on the scattershot (Missiles draws a scattershot with Icons.NUKE).
	local scatter = key == "SCATTERSHOT"
	self.headImg = if scatter then Icons.NUKE else (Icons.MEGA_NUKE or Icons.NUKE)
	self.headNose = if scatter then Icons.NUKE_NOSE else NOSE_DEG
	self.headD = if scatter then SCATTER_D else NUKE_D
	self.inner = if scatter then SCATTER_INNER else NUKE_INNER
	self.outer = if scatter then SCATTER_OUTER else NUKE_OUTER
	self.crater = {}
	self.gunFx = nil :: any
	self.collapse = nil :: number?
	self.revive = nil :: number?
	self.kick = 0

	-- THE STAGE keeps the tile grid's aspect inside whatever it is given, so
	-- a tile is square and every Scale below means what it says.
	local stage = Instance.new("Frame")
	stage.Name = "Stage"
	stage.AnchorPoint = Vector2.new(0.5, 0.5)
	stage.Position = UDim2.fromScale(0.5, 0.5)
	stage.Size = UDim2.fromScale(1, 1)
	stage.BorderSizePixel = 0
	stage.ClipsDescendants = true
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = self.aspect
	ar.Parent = stage
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = stage
	stage.Parent = parent
	self.stage = stage

	-- TWO NATIONS ON PLAINS, the attacker's (yours: colorFor's local colour)
	-- on the left and a neighbour's on the right, a dark border between them
	-- the way the map draws one, and a scatter of slightly darker tiles so the
	-- ground has the grain a painted map has.
	local W = self.W
	local mine, mineDark = territory(1)
	local theirs, theirsDark = territory(2)
	stage.BackgroundColor3 = theirs
	local left = Instance.new("Frame")
	left.Name = "Mine"
	left.BackgroundColor3 = mine
	left.BorderSizePixel = 0
	left.ZIndex = 1
	left.Size = UDim2.fromScale(BORDER_F, 1)
	left.Parent = stage
	local border = Instance.new("Frame")
	border.Name = "Border"
	border.BackgroundColor3 = theirsDark
	border.BorderSizePixel = 0
	border.ZIndex = 2
	border.AnchorPoint = Vector2.new(0.5, 0)
	border.Position = UDim2.fromScale(BORDER_F, 0)
	border.Size = UDim2.fromScale(BORDER_W / W, 1)
	border.Parent = stage
	local rng = Random.new(7)
	local wTiles = math.floor(W)
	for i = 1, math.floor(GRAIN_PER_40 * W / 40) do
		local gx, gy = rng:NextInteger(0, wTiles - 1), rng:NextInteger(0, STAGE_H - 1)
		local g = Instance.new("Frame")
		g.Name = "Grain"
		g.BorderSizePixel = 0
		g.ZIndex = 1
		g.BackgroundColor3 = if gx < BORDER_F * W then mineDark else theirsDark
		g.BackgroundTransparency = 0.72
		g.Position = UDim2.fromScale(gx / W, gy / STAGE_H)
		g.Size = UDim2.fromScale(1 / W, 1 / STAGE_H)
		g.Parent = stage
	end

	-- THE ACTORS. The city is theirs; the gun or the field is yours. The
	-- mega nuke has NO launcher on the stage (owner, 2026-09-22: "i just
	-- want it to drop", then "come sideways and in") -- it flies in from
	-- off your edge, so there is nothing for it to leave from and your side
	-- of the border stands empty.
	self.city = chip(self, Icons.HOUSE, 0.35, c3(Palette.colorFor(2, 1)), self.rightX, ROW_Y)
	local mineInk = c3(Palette.colorFor(1, 1))
	self.tint = mineInk
	if key == "ARTILLERY" then
		self.gun = chip(self, Icons.ARTILLERY, 0.08, mineInk, self.leftX, ROW_Y)
	elseif key == "AIRSTRIKE" then
		self.field = chip(self, Icons.AIRFIELD, 0.08, mineInk, self.leftX, ROW_Y)
	elseif key == "RAILGUN" then
		-- `gun`, so the battery's recoil and flash (gunFx) drive it as-is.
		self.gun = chip(self, Icons.RAILGUN, 0.08, mineInk, self.leftX, ROW_Y)
	end

	-- THE TIMELINE: flights are distance over speed, so the beats are laid
	-- out from those; cues at seconds into the loop, and the loop's length.
	-- The nuke's clock is its arc's length over its speed (nukeArc).
	local span = self.rightX - self.leftX
	self.shellTime = math.max(SHELL_TIME_MIN, span / SHELL_SPEED)
	self.planeTime = math.max(PLANE_TIME_MIN, span / PLANE_SPEED)
	if key == "ARTILLERY" then
		local t1 = FIRST_SHOT
		local t2 = t1 + self.shellTime + BETWEEN_SHOTS
		local t3 = t2 + self.shellTime + BETWEEN_SHOTS
		self.loop = t3 + self.shellTime + RUIN_HOLD
		self.cues = {
			{ at = t1, fn = function() PassClips.fire(self, 1) end },
			{ at = t2, fn = function() PassClips.fire(self, 2) end },
			{ at = t3, fn = function() PassClips.fire(self, 3) end },
		}
	elseif key == "AIRSTRIKE" then
		self.loop = LAUNCH_AT + self.planeTime + RAID_HOLD
		self.cues = {
			{ at = LAUNCH_AT, fn = function() PassClips.launch(self) end },
		}
	elseif key == "RAILGUN" then
		self.slugTime = math.max(RAIL_TIME_MIN, span / RAIL_SPEED)
		local fireAt = LAUNCH_AT + RAIL_CHARGE
		self.loop = fireAt + self.slugTime + RAIL_FADE + RUIN_HOLD
		self.cues = {
			{ at = LAUNCH_AT, fn = function() PassClips.charge(self) end },
			{ at = fireAt, fn = function() PassClips.railFire(self) end },
		}
	else
		self.arc = nukeArc(self)
		self.nukeTime = math.max(NUKE_TIME_MIN, self.arc.total / NUKE_SPEED)
		local last = self.nukeTime
		if scatter then
			-- Every warhead's arc is fixed by the split point, so the loop is
			-- long enough for the slowest of the six to land and burn out.
			local splitAt = SCATTER_SPLIT * self.nukeTime
			local sx, sy = arcAt(self.arc, SCATTER_SPLIT)
			local hd = math.rad(arcHeading(self.arc, SCATTER_SPLIT))
			self.split = { x = sx, y = sy }
			self.mirvArcs = {}
			for i, aim in SCATTER_AIMS do
				local tx, ty = self.rightX + aim[1] * CHIP, ROW_Y + aim[2] * CHIP
				local a = arcOf(
					{ sx, sy },
					{ sx + math.cos(hd) * CHIP * 1.2, sy + math.sin(hd) * CHIP * 1.2 },
					{ tx - CHIP * 0.7, math.max(0.5, ty - CHIP * 1.3) },
					{ tx, ty }
				)
				local time = math.max(NUKE_TIME_MIN * 0.5, a.total / (MIRV_SPEED * (1 - MIRV_LAG * (i - 1))))
				self.mirvArcs[i] = { arc = a, time = time, x = tx, y = ty }
				last = math.max(last, splitAt + time)
			end
		end
		self.loop = LAUNCH_AT + last + FLASH_LIFE + NUKE_HOLD
		self.cues = {
			{ at = LAUNCH_AT, fn = function() PassClips.nukeIn(self) end },
		}
		if scatter then
			table.insert(self.cues, { at = LAUNCH_AT + SCATTER_SPLIT * self.nukeTime, fn = function() PassClips.scatter(self) end })
		end
	end
	PassClips.reset(self, true)
	return self
end

-- ---------------------------------------------------------------- actions --

-- Structures.gunFire: the glyph kicked back along the line of fire, a flash at
-- the barrel tip and a puff of smoke off it; then the shell leaves (Missiles'
-- "sh"): a lobbed capsule with three smoke dots behind it.
function PassClips.fire(self: any, n: number)
	local m = self.gun
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.BackgroundColor3 = HOT
	flash.BorderSizePixel = 0
	flash.AnchorPoint = Vector2.new(0.5, 0.5)
	flash.Position = UDim2.fromScale(GUN_MUZZLE_X, GUN_MUZZLE_Y)
	flash.Size = UDim2.fromScale(GUN_FLASH_SIZE, GUN_FLASH_SIZE)
	flash.ZIndex = 9
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = flash
	flash.Parent = m.frame
	self.gunFx = { flash = flash, t = 0 }

	local x0, y0 = self.leftX + CHIP * 0.3, ROW_Y - CHIP * 0.4
	puff(self, x0 + 0.3, y0 - 0.3, SMOKE, MUZZLE_SMOKE_LIFE, CHIP * 0.18, CHIP * 0.7)

	local body = capsule(self, SHELL_LEN, SHELL_THICK, SHELL_INK, 12)
	body.Name = "Shell"
	local trail = {}
	for i = 1, SHELL_TRAIL do
		local d = disc(self.stage, 11)
		sized(self, d, TRAIL_D, TRAIL_D)
		d.BackgroundColor3 = SMOKE
		d.BackgroundTransparency = 0.3 + 0.2 * i
		d.Visible = false
		trail[i] = d
	end
	local x1, y1 = self.rightX, ROW_Y
	local span = x1 - x0
	self.shell = { body = body, trail = trail, x0 = x0, y0 = y0, x1 = x1, y1 = y1, t = 0, hit = n, loft = math.min(SHELL_LOFT * span, SHELL_LOFT_MAX) }
end

-- The city goes: the burst that fells it, the stage jolted, the chip sinking
-- and fading over COLLAPSE (see step), rubble left where it stood.
local function raze(self: any)
	setHealth(self.city, nil)
	self.collapse = 0
	self.kick = KICK_TILES
	for i = 1, RUBBLE do
		local r = Instance.new("Frame")
		r.Name = "Rubble"
		r.AnchorPoint = Vector2.new(0.5, 0.5)
		r.BackgroundColor3 = RUBBLE_INK
		r.BackgroundTransparency = 0.2
		r.BorderSizePixel = 0
		r.ZIndex = 4
		r.Rotation = math.random() * 90
		local d = RUBBLE_D * (0.8 + math.random() * 0.6)
		sized(self, r, d, d)
		local a = (i - 1) / RUBBLE * math.pi * 2 + math.random() * 1.5
		local reach = CHIP * (0.18 + math.random() * 0.22)
		at(self, r, self.rightX + math.cos(a) * reach, ROW_Y + math.sin(a) * reach * 0.7 + CHIP * 0.15)
		r.Parent = self.stage
		table.insert(self.rubble, r)
	end
end

-- The shell lands (Missiles' "si"): a burst weighted by what it hit, and the
-- city's bar drops -- or, on the third, the city falls.
function PassClips.hit(self: any, n: number)
	if n < 3 then
		shellBurst(self, self.rightX, ROW_Y, 1.35)
		setHealth(self.city, n == 1 and 0.66 or 0.33)
	else
		shellBurst(self, self.rightX, ROW_Y, 1.8)
		raze(self)
	end
end

-- ------------------------------------------------------------- the warhead --
-- THE RUN-IN (owner, 2026-09-22: "come sideways and in"). The mega nuke's
-- sticker for the head, an exhaust of NUKE_TRAIL_N dots cooling from the
-- flame to your own colour strung out BEHIND it along its line, and at the
-- aimpoint the ring of the crater to come with a red disc inside it that
-- closes as the warhead does -- where, and how long, before the flash. The
-- path is the clip's arc (nukeArc, built in new): the head is placed along
-- it by distance flown and turned nose-first along its tangent every frame,
-- so it climbs in, crests, and curves down onto the city.
-- One warhead in the air: its sticker `d` tiles across on `arc`, `time`
-- seconds of flight, an exhaust of `trailN` dots `trailStep` of the run
-- apart, and the red aim ring of radius `outer` at where it lands. The
-- mega nuke's and the scattershot's heads and every MIRV warhead are one.
local function flight(self: any, arc: any, time: number, d: number, outer: number, trailN: number, trailStep: number): any
	local x1, y1 = arcAt(arc, 1)
	local x0, y0 = arcAt(arc, 0)
	local head = Instance.new("ImageLabel")
	head.Name = "Warhead"
	head.AnchorPoint = Vector2.new(0.5, 0.5)
	head.BackgroundTransparency = 1
	head.Image = self.headImg
	head.ScaleType = Enum.ScaleType.Fit
	head.ZIndex = 12
	sized(self, head, d, d)
	Icons.resample(head)
	at(self, head, x0, y0)
	head.Rotation = arcHeading(arc, 0) - self.headNose -- step keeps it on the tangent
	head.Parent = self.stage
	local trail = table.create(trailN)
	for i = 1, trailN do
		local dot = disc(self.stage, 11)
		local k = (i - 1) / (trailN - 1)
		dot.BackgroundColor3 = HOT:Lerp(self.tint, k)
		dot.Visible = false
		trail[i] = dot
	end
	local ring = disc(self.stage, 10)
	sized(self, ring, outer * 2, outer * 2)
	local rs = Instance.new("UIStroke")
	rs.Color = THREAT
	rs.Thickness = 2
	rs.Parent = ring
	at(self, ring, x1, y1)
	local lead = disc(self.stage, 10)
	lead.BackgroundColor3 = THREAT
	lead.BackgroundTransparency = 0.72
	at(self, lead, x1, y1)
	sized(self, lead, outer * 2, outer * 2)
	return {
		head = head, trail = trail, ring = ring, lead = lead, t = 0,
		arc = arc, time = time, x1 = x1, y1 = y1, outer = outer,
		trailStep = trailStep, trailHead = NUKE_TRAIL_HEAD * d / NUKE_D, trailTail = NUKE_TRAIL_TAIL * d / NUKE_D,
	}
end

local function dropFlight(ms: any)
	ms.head:Destroy()
	for _, d in ms.trail do
		d:Destroy()
	end
	ms.ring:Destroy()
	ms.lead:Destroy()
end

-- Where the head is at share `p` of its flight, nose on the tangent, the
-- exhaust strung back along the line it came in on, and the red disc
-- closing on the centre as the warhead closes on the ground.
local function stepFlight(self: any, ms: any, p: number)
	local x, y = arcAt(ms.arc, p)
	at(self, ms.head, x, y)
	ms.head.Rotation = arcHeading(ms.arc, p) - self.headNose
	local n = #ms.trail
	for i, d in ms.trail do
		local bp = p - i * ms.trailStep
		if bp < 0 then
			d.Visible = false
		else
			d.Visible = true
			local tx, ty = arcAt(ms.arc, bp)
			at(self, d, tx, ty)
			local k = (i - 1) / (n - 1)
			local sz = ms.trailHead + (ms.trailTail - ms.trailHead) * k
			sized(self, d, sz, sz)
			d.BackgroundTransparency = k * k
		end
	end
	local r = ms.outer * (1 - p)
	sized(self, ms.lead, r * 2, r * 2)
end

function PassClips.nukeIn(self: any)
	self.missile = flight(self, self.arc, self.nukeTime, self.headD, self.outer, NUKE_TRAIL_N, NUKE_TRAIL_STEP)
end

-- THE SPLIT: a flash where the bus opens, and this loop's salvo of smaller
-- warheads off it, each on its own arc to its own ring round the city.
function PassClips.scatter(self: any)
	local s = self.split
	puff(self, s.x, s.y, HOT, 0.35, CHIP * 0.3, CHIP * 1.1)
	for i = 1, self.salvo do
		local m = self.mirvArcs[i]
		self.mirvs[i] = flight(self, m.arc, m.time, MIRV_D, MIRV_OUTER, MIRV_TRAIL_N, MIRV_TRAIL_STEP)
	end
end

-- ------------------------------------------------------------- the railgun --
-- The slug's curve at `p` (0 gun, 1 city): the chord lifted by a parabola
-- whose apex is RAIL_ARC_H at mid-flight.
local function railAt(sl: any, p: number): (number, number)
	return sl.x0 + (sl.x1 - sl.x0) * p, sl.y0 + (sl.y1 - sl.y0) * p - 4 * RAIL_ARC_H * p * (1 - p)
end

-- Lay the slug's segments along its curve from `pa` to `pb`.
local function layArc(self: any, sl: any, pa: number, pb: number, thick: number)
	local n = #sl.segs
	for i, seg in sl.segs do
		local ax, ay = railAt(sl, pa + (pb - pa) * (i - 1) / n)
		local bx, by = railAt(sl, pa + (pb - pa) * i / n)
		beamAt(self, seg.glow, ax, ay, bx, by, thick)
	end
end

-- THE CHARGE: the gun heats up -- an orange disc closing on it -- so the
-- shot has a wind-up the way the in-game gun's cooldown does.
function PassClips.charge(self: any)
	local f = disc(self.stage, 9)
	f.BackgroundColor3 = RAIL_GLOW
	sized(self, f, RAIL_CHARGE_D0, RAIL_CHARGE_D0)
	at(self, f, self.leftX, ROW_Y)
	self.fx[#self.fx + 1] = { kind = "charge", frame = f, t = 0, life = RAIL_CHARGE, d0 = RAIL_CHARGE_D0, d1 = RAIL_CHARGE_D1 }
end

-- Structures.gunFire's recoil and flash (the battery's gunFx), then
-- Missiles' "rf": a fire-orange glow with the yellow-hot core and a
-- white-hot head at its front, dragging RAIL_TAIL tiles of streak.
function PassClips.railFire(self: any)
	local m = self.gun
	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.BackgroundColor3 = HOT
	flash.BorderSizePixel = 0
	flash.AnchorPoint = Vector2.new(0.5, 0.5)
	flash.Position = UDim2.fromScale(GUN_MUZZLE_X, GUN_MUZZLE_Y)
	flash.Size = UDim2.fromScale(GUN_FLASH_SIZE, GUN_FLASH_SIZE)
	flash.ZIndex = 9
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0.5, 0)
	round.Parent = flash
	flash.Parent = m.frame
	self.gunFx = { flash = flash, t = 0 }

	local x0, y0 = self.leftX + CHIP * 0.3, ROW_Y - CHIP * 0.3
	puff(self, x0, y0, FIRE, 0.4)
	puff(self, x0, y0, HOT, 0.3, CHIP * 0.15, CHIP * 0.55)
	local segs = table.create(RAIL_SEGS)
	for i = 1, RAIL_SEGS do
		local glow = Instance.new("Frame")
		glow.Name = "Rail"
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
		glow.Parent = self.stage
		segs[i] = { glow = glow, core = core }
	end
	local head = disc(self.stage, 14)
	head.BackgroundColor3 = HOT
	head.BackgroundTransparency = 0
	sized(self, head, RAIL_HEAD_D, RAIL_HEAD_D)
	at(self, head, x0, y0)
	local sl = { segs = segs, head = head, x0 = x0, y0 = y0, x1 = self.rightX, y1 = ROW_Y, t = 0 }
	layArc(self, sl, 0, 0, RAIL_THICK)
	self.slug = sl
end

-- Missiles' "ri": the line flares end to end and burns down, a heavy
-- burst, a fire ring, and the city goes in one hit.
local function railHit(self: any)
	local s = self.slug
	s.head:Destroy()
	layArc(self, s, 0, 1, RAIL_THICK * 1.65)
	local n = #s.segs
	for i, seg in s.segs do
		local ax, ay = railAt(s, (i - 1) / n)
		local bx, by = railAt(s, i / n)
		self.fx[#self.fx + 1] = { kind = "beam", frame = seg.glow, core = seg.core, t = 0, life = RAIL_FADE, x0 = ax, y0 = ay, x1 = bx, y1 = by }
	end
	self.slug = nil
	shellBurst(self, s.x1, s.y1, 2.0)
	local wave = disc(self.stage, 15)
	local stroke = Instance.new("UIStroke")
	stroke.Color = FIRE
	stroke.Thickness = 3
	stroke.Parent = wave
	at(self, wave, s.x1, s.y1)
	sized(self, wave, 0, 0)
	self.fx[#self.fx + 1] = { kind = "wave", frame = wave, stroke = stroke, t = 0, life = BOMB_WAVE_LIFE, outer = RAIL_WAVE }
	raze(self)
end

-- Where the head is and which way it points: arcAt / arcHeading, above new.

-- Missiles' blast: the fireball with the white core, the shockwave at six
-- pixels, and the ground GLASSED -- a crater of fallout that stays until the
-- loop resets, with the acid-green rises the renderer puts on real fallout.
-- The city under it goes the way a shelled one does, harder.
local function blast(self: any, x: number, y: number, inner: number, outer: number, glass: number, seed: number, life: number)
	local crater = disc(self.stage, 3)
	crater.Name = "Crater"
	crater.BackgroundColor3 = FALLOUT_DARK
	crater.BackgroundTransparency = 0.1
	sized(self, crater, outer * 1.9, outer * 1.9)
	at(self, crater, x, y)
	table.insert(self.crater, crater)
	local rng = Random.new(seed)
	for i = 1, glass do
		local a = rng:NextNumber() * math.pi * 2
		local r = outer * 0.85 * math.sqrt(rng:NextNumber())
		local g = Instance.new("Frame")
		g.Name = "Glass"
		g.AnchorPoint = Vector2.new(0.5, 0.5)
		g.BackgroundColor3 = FALLOUT_DARK:Lerp(FALLOUT_ACID, 0.55 + rng:NextNumber() * 0.45)
		g.BackgroundTransparency = 0.15
		g.BorderSizePixel = 0
		g.ZIndex = 3
		local d = (0.8 + rng:NextNumber() * 1.0) * math.min(1, outer / NUKE_OUTER * 2)
		sized(self, g, d, d)
		at(self, g, x + math.cos(a) * r, y + math.sin(a) * r)
		g.Parent = self.stage
		table.insert(self.crater, g)
	end

	local ball = disc(self.stage, 13)
	ball.BackgroundColor3 = HOT
	at(self, ball, x, y)
	sized(self, ball, inner * 0.7, inner * 0.7)
	local core = disc(ball, 14)
	core.Position = UDim2.fromScale(0.5, 0.5)
	core.BackgroundColor3 = HOT
	self.fx[#self.fx + 1] = { kind = "ball", frame = ball, core = core, t = 0, life = life, inner = inner, outer = outer }
	local wave = disc(self.stage, 15)
	local stroke = Instance.new("UIStroke")
	stroke.Color = HOT
	stroke.Thickness = 6
	stroke.Parent = wave
	at(self, wave, x, y)
	sized(self, wave, 0, 0)
	self.fx[#self.fx + 1] = { kind = "wave", frame = wave, stroke = stroke, t = 0, life = WAVE_LIFE, outer = outer }
end

local function detonate(self: any)
	local m = self.missile
	if m then
		dropFlight(m)
		self.missile = nil
	end
	blast(self, self.rightX, ROW_Y, self.inner, self.outer, 14, 11, FLASH_LIFE)
	raze(self)
	self.kick = NUKE_KICK
end

-- A MIRV warhead lands: its own small crater and flash on its ring, and a
-- smaller jolt than the main one's.
local function mirvLand(self: any, i: number)
	local ms = self.mirvs[i]
	dropFlight(ms)
	self.mirvs[i] = false
	blast(self, ms.x1, ms.y1, MIRV_INNER, MIRV_OUTER, 5, 20 + i, FLASH_LIFE * 0.6)
	self.kick = math.max(self.kick, NUKE_KICK * 0.45)
end

-- --------------------------------------------------------------- the bomber --

-- HOW HIGH THE BOMBER IS a share `q` of the way along its run: up off the
-- field over the first PLANE_CLIMB_F, eased so the climb flattens out, then
-- down toward the city on a curve that steepens into the release -- the
-- dive the owner asked for (see the header). In tiles above the ground line.
local function planeAlt(q: number): number
	q = math.clamp(q, 0, 1)
	if q < PLANE_CLIMB_F then
		local a = q / PLANE_CLIMB_F
		return PLANE_ALT_TAKEOFF + (PLANE_ALT_HIGH - PLANE_ALT_TAKEOFF) * (1 - (1 - a) ^ 2)
	end
	local d = (q - PLANE_CLIMB_F) / (1 - PLANE_CLIMB_F)
	return PLANE_ALT_HIGH + (PLANE_ALT_LOW - PLANE_ALT_HIGH) * d ^ PLANE_DIVE_POW
end

-- The shadow says how high: faint and small at height, dark and full-size
-- on the deck, always on the ground line under the sprite.
local function paintShadow(self: any, pl: any, x: number, alt: number, rise: number, fadeK: number)
	local hi = math.clamp((alt - PLANE_ALT_LOW) / (PLANE_ALT_HIGH - PLANE_ALT_LOW), 0, 1)
	local d = PLANE_SHADOW_D * rise * (1 - PLANE_SHADOW_SHRINK * hi)
	sized(self, pl.shadow, d, d * PLANE_SHADOW_SQUASH)
	at(self, pl.shadow, x, pl.gy)
	local t = PLANE_SHADOW_T_LOW + (PLANE_SHADOW_T_HIGH - PLANE_SHADOW_T_LOW) * hi
	pl.shadow.BackgroundTransparency = t + (1 - t) * fadeK
end

-- Missiles' "pl": the bomber leaves the field for the city, a launch puff at
-- the field, a contrail behind it. It comes up to size over the first
-- stretch and climbs (planeAlt), so it reads as taking off; the shadow is
-- born under it on the runway.
function PassClips.launch(self: any)
	local img = Instance.new("ImageLabel")
	img.Name = "Plane"
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.BackgroundTransparency = 1
	img.Image = Icons.PLANE
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 12
	sized(self, img, PLANE_D * PLANE_RISE_FROM, PLANE_D * PLANE_RISE_FROM)
	Icons.resample(img)
	local gy = ROW_Y - PLANE_GROUND_LIFT
	local x0, x1 = self.leftX, self.rightX
	local alt0 = planeAlt(0)
	img.Rotation = 0
	at(self, img, x0, gy - alt0)
	img.Parent = self.stage
	local shadow = disc(self.stage, 4)
	shadow.Name = "Shadow"
	shadow.BackgroundColor3 = DARK
	self.plane = {
		img = img, shadow = shadow, x0 = x0, x1 = x1, gy = gy,
		-- Where the sprite is drawn this frame and which way its nose
		-- points, for the contrail and for the bomb's release.
		x = x0, y = gy - alt0, alt = alt0, heading = 0,
		t = 0, puffT = 0, landed = nil :: number?,
	}
	paintShadow(self, self.plane, x0, alt0, PLANE_RISE_FROM, 0)
	puff(self, self.leftX, ROW_Y - CHIP * 0.3, HOT)
end

-- THE BOMB LEAVES THE PLANE a moment before the target and FALLS -- a thing
-- dropping is what makes a bombing read as one, where the ground simply
-- exploding under a passing plane reads as a mine. It leaves from where the
-- plane IS -- low, in the dive -- carries the plane's way forward to the
-- city as it falls, and tips from the plane's heading to nose-down. The
-- plane flies on from here, pulling up and fading (see step).
local function release(self: any)
	local pl = self.plane
	local b = capsule(self, BOMB_LEN, BOMB_THICK, DARK, 12)
	b.Name = "Bomb"
	b.Rotation = pl.heading
	at(self, b, pl.x, pl.y)
	self.dropping = { frame = b, x0 = pl.x, y0 = pl.y, x1 = pl.x1, y1 = ROW_Y, rot0 = pl.heading, t = 0 }
	pl.landed = 0
end

-- Missiles' "pb": the fireball and the shockwave on the city, and the city
-- falls.
function PassClips.bomb(self: any)
	bombBurst(self, self.rightX, ROW_Y)
	raze(self)
end

-- ------------------------------------------------------------------- loop --

-- Back to the first frame: everything transient gone, the city standing.
-- `instant` skips the revive fade (the resting picture when not playing).
function PassClips.reset(self: any, instant: boolean?)
	for _, fx in self.fx do
		fx.frame:Destroy()
	end
	table.clear(self.fx)
	for _, r in self.rubble do
		r:Destroy()
	end
	table.clear(self.rubble)
	if self.shell then
		self.shell.body:Destroy()
		for _, d in self.shell.trail do
			d:Destroy()
		end
		self.shell = nil
	end
	if self.plane then
		self.plane.img:Destroy()
		self.plane.shadow:Destroy()
		self.plane = nil
	end
	if self.dropping then
		self.dropping.frame:Destroy()
		self.dropping = nil
	end
	if self.missile then
		dropFlight(self.missile)
		self.missile = nil
	end
	for _, ms in self.mirvs do
		if ms then
			dropFlight(ms)
		end
	end
	table.clear(self.mirvs)
	-- 4, 5, 6, 4, ...: the salvo the next loop splits into.
	self.salvo = if self.salvo >= SCATTER_MAX then SCATTER_MIN else self.salvo + 1
	if self.slug then
		for _, seg in self.slug.segs do
			seg.glow:Destroy()
		end
		self.slug.head:Destroy()
		self.slug = nil
	end
	for _, c in self.crater do
		c:Destroy()
	end
	table.clear(self.crater)
	if self.gunFx then
		self.gunFx.flash:Destroy()
		self.gunFx = nil
		self.gun.glyph.Position = UDim2.fromScale(0.5, 0.5)
	end
	for _, cue in self.cues do
		cue.done = false
	end
	self.t = 0
	self.collapse = nil
	self.kick = 0
	self.stage.Position = UDim2.fromScale(0.5, 0.5)
	local city = self.city
	city.scale.Scale = 1
	city.frame.Visible = true
	at(self, city.frame, city.x, city.y)
	setHealth(city, nil)
	if instant then
		self.revive = nil
		fade(city, 0)
	else
		self.revive = 0
		fade(city, 1)
	end
end

-- One frame of the loop. Public so a harness can hand-drive the clip to a
-- known moment and look at it; play() runs it off RenderStepped.
function PassClips.step(self: any, dt: number)
	self.t += dt
	for _, cue in self.cues do
		if not cue.done and self.t >= cue.at then
			cue.done = true
			cue.fn()
		end
	end

	local g = self.gunFx
	if g then
		g.t += dt
		local k = g.t / GUN_RECOIL_LIFE
		if k >= 1 then
			self.gun.glyph.Position = UDim2.fromScale(0.5, 0.5)
			g.flash:Destroy()
			self.gunFx = nil
		else
			local kick = (1 - k) ^ 2
			self.gun.glyph.Position = UDim2.fromScale(0.5 - GUN_RECOIL_KICK * kick, 0.5 + 0.03 * kick)
			local fk = g.t / GUN_FLASH_LIFE
			if fk >= 1 then
				g.flash.Visible = false
			else
				local s = GUN_FLASH_SIZE * (1 - fk) ^ 0.6
				g.flash.Size = UDim2.fromScale(s, s)
				g.flash.BackgroundColor3 = HOT:Lerp(FIRE, fk)
				g.flash.BackgroundTransparency = fk * fk
			end
		end
	end

	local s = self.shell
	if s then
		s.t += dt
		local p = s.t / self.shellTime
		if p >= 1 then
			local n = s.hit
			s.body:Destroy()
			for _, d in s.trail do
				d:Destroy()
			end
			self.shell = nil
			PassClips.hit(self, n)
		else
			-- Missiles' lob: a parabola over the straight line, the body
			-- turned along it, and SWELLING at the top of the arc so the
			-- lob has height as well as a curve.
			local lx, ly = s.x1 - s.x0, s.y1 - s.y0
			local arc = 4 * p * (1 - p)
			local x = s.x0 + lx * p
			local y = s.y0 + ly * p - s.loft * arc
			at(self, s.body, x, y)
			local swell = 1 + SHELL_ARC_SWELL * arc
			sized(self, s.body, SHELL_LEN * swell, SHELL_THICK * swell)
			local vx = lx
			local vy = ly - s.loft * 4 * (1 - 2 * p)
			s.body.Rotation = math.deg(math.atan2(vy, vx))
			for i, d in s.trail do
				local q = p - (i * SHELL_TRAIL_GAP) / self.shellTime
				if q <= 0 then
					d.Visible = false
				else
					d.Visible = true
					at(self, d, s.x0 + lx * q, s.y0 + ly * q - s.loft * 4 * q * (1 - q))
				end
			end
		end
	end

	local pl = self.plane
	if pl then
		pl.t += dt
		local p = pl.t / self.planeTime
		-- Off the runway it comes up to size; on the way it bobs and banks a
		-- little, which is what tells a sprite from a sticker.
		local rise = PLANE_RISE_FROM + (1 - PLANE_RISE_FROM) * math.min(1, pl.t / PLANE_RISE) ^ 0.6
		sized(self, pl.img, PLANE_D * rise, PLANE_D * rise)
		local bob = math.sin(pl.t * PLANE_BOB_RATE) * PLANE_BOB * math.min(1, pl.t / PLANE_RISE)
		local bank = math.sin(pl.t * PLANE_BANK_RATE) * PLANE_BANK
		if pl.landed == nil then
			-- THE RUN: along the ground line at a steady pace, up and then
			-- DOWN by planeAlt. The nose follows the slope it is flying --
			-- the gradient between this frame's height and one a step back
			-- -- so it lifts on the climb and tips further over as the dive
			-- steepens. The shadow closes under it as it comes down.
			local q = math.min(1, p)
			local alt = planeAlt(q)
			local x = pl.x0 + (pl.x1 - pl.x0) * q
			local y = pl.gy - alt + bob
			local back = 0.01
			local dx = (pl.x1 - pl.x0) * back
			local dy = -(alt - planeAlt(q - back))
			pl.heading = math.deg(math.atan2(dy, dx))
			pl.img.Rotation = pl.heading + bank
			at(self, pl.img, x, y)
			pl.x, pl.y, pl.alt = x, y, alt
			paintShadow(self, pl, x, alt, rise, 0)
			pl.puffT += dt
			if pl.puffT >= PLANE_PUFF_GAP then
				pl.puffT -= PLANE_PUFF_GAP
				local f = disc(self.stage, 11)
				sized(self, f, TRAIL_D, TRAIL_D)
				f.BackgroundColor3 = CONTRAIL
				f.BackgroundTransparency = 0.4
				at(self, f, x - 0.6, y)
				self.fx[#self.fx + 1] = { kind = "trail", frame = f, t = 0, life = PLANE_PUFF_LIFE }
			end
			if pl.t >= self.planeTime - BOMB_DROP then
				release(self)
			end
		else
			-- PAST THE RELEASE it pulls up and away, fading: height back over
			-- the overrun, the nose coming up through level to a climb, the
			-- shadow drawing off and dimming with it.
			pl.landed += dt
			local k = pl.landed / PLANE_OVERRUN
			if k >= 1 then
				pl.img:Destroy()
				pl.shadow:Destroy()
				self.plane = nil
			else
				local speed = (pl.x1 - pl.x0) / self.planeTime
				local x = pl.x + speed * dt
				local alt = pl.alt + PLANE_PULL_UP * (k ^ 0.7 - math.max(0, (k - dt / PLANE_OVERRUN)) ^ 0.7)
				pl.x, pl.alt = x, alt
				pl.y = pl.gy - alt + bob
				at(self, pl.img, x, pl.y)
				pl.img.Rotation = pl.heading * (1 - k) - PLANE_PULL_DEG * k + bank
				pl.img.ImageTransparency = k
				paintShadow(self, pl, x, alt, rise, k)
			end
		end
	end

	local b = self.dropping
	if b then
		b.t += dt
		local p = b.t / BOMB_DROP
		if p >= 1 then
			b.frame:Destroy()
			self.dropping = nil
			PassClips.bomb(self)
		else
			-- Gravity down, the plane's way forward: slow off the rack, fast
			-- at the ground, carrying on to the city as it falls, and tipping
			-- from the plane's heading to straight down.
			at(self, b.frame, b.x0 + (b.x1 - b.x0) * p, b.y0 + (b.y1 - b.y0) * p ^ 1.7)
			b.frame.Rotation = b.rot0 + (90 - b.rot0) * p ^ 0.8
		end
	end

	local ms = self.missile
	if ms then
		ms.t += dt
		local p = ms.t / ms.time
		if p >= 1 then
			detonate(self)
		else
			stepFlight(self, ms, p)
		end
	end
	for i, mv in self.mirvs do
		if mv then
			mv.t += dt
			local p = mv.t / mv.time
			if p >= 1 then
				mirvLand(self, i)
			else
				stepFlight(self, mv, p)
			end
		end
	end

	local sl = self.slug
	if sl then
		sl.t += dt
		local p = sl.t / self.slugTime
		if p >= 1 then
			railHit(self)
		else
			-- The streak: RAIL_TAIL tiles behind the head along the arc.
			local dx, dy = sl.x1 - sl.x0, sl.y1 - sl.y0
			local len = math.sqrt(dx * dx + dy * dy)
			local pa = if len > 0 then math.max(0, p - RAIL_TAIL / len) else 0
			layArc(self, sl, pa, p, RAIL_THICK)
			at(self, sl.head, railAt(sl, p))
		end
	end

	stepFx(self, dt)

	-- THE STAGE'S JOLT when a building goes: the camera kick the round gives
	-- a razing, in miniature, decaying fast enough to read as an impact.
	if self.kick > 0 then
		self.kick *= math.exp(-dt * KICK_DECAY)
		if self.kick < 0.01 then
			self.kick = 0
			self.stage.Position = UDim2.fromScale(0.5, 0.5)
		else
			local a = self.t * 60
			self.stage.Position = UDim2.fromScale(0.5 + math.cos(a) * self.kick / self.W, 0.5 + math.sin(a * 1.3) * self.kick / STAGE_H)
		end
	end

	local city = self.city
	if self.collapse ~= nil then
		self.collapse += dt
		local k = math.min(1, self.collapse / COLLAPSE)
		city.scale.Scale = 1 - 0.8 * k
		at(self, city.frame, city.x, city.y + SINK * k * k)
		fade(city, k)
		if k >= 1 then
			city.frame.Visible = false
			self.collapse = nil
		end
	elseif self.revive ~= nil then
		self.revive += dt
		local k = math.min(1, self.revive / REVIVE)
		fade(city, 1 - k)
		if k >= 1 then
			self.revive = nil
		end
	end

	if self.t >= self.loop then
		PassClips.reset(self)
	end
end

function PassClips.play(self: any)
	if self.conn then
		return
	end
	PassClips.reset(self, true)
	self.conn = RunService.RenderStepped:Connect(function(dt: number)
		PassClips.step(self, math.min(dt, 0.1))
	end)
end

function PassClips.stop(self: any)
	local c = self.conn
	if c then
		c:Disconnect()
		self.conn = nil
	end
	PassClips.reset(self, true)
end

function PassClips.destroy(self: any)
	PassClips.stop(self)
	self.stage:Destroy()
end

return PassClips
