--!strict
-- Conquest :: Renderer  (client only)
-- One EditableImage at exactly one tile per pixel. Terrain never changes, so
-- per tick only the tiles whose owner changed are recoloured, and only the
-- affected row bands are uploaded. Two things that are NOT ownership write
-- pixels here as well, both through the same recolor path: the ground a
-- warhead poisons (setFalloutTiles) and the water a transport has crossed
-- (setWake).
--
-- Sized for 1.6M tiles, which forced three optimisations over the naive form:
--
--  1. No cached terrain-colour or shade buffers. Deriving both from the one
--     terrain byte costs a few bit ops and saves 6.4 MB of resident memory.
--  2. The upload scratch buffer is capped at MAX_BAND_ROWS instead of being
--     whole-map sized (614 KB rather than 6.4 MB); long bands are split.
--  3. A coarse block index of which empire occupies which 64x64 block, so
--     hover-highlighting an empire scans its own footprint instead of all
--     1.6M tiles. Without it every hover change cost a ~25 ms full scan.

local AssetService = game:GetService("AssetService")

local Config = require(script.Parent.Config)
local MapGen = require(script.Parent.MapGen)
local Palette = require(script.Parent.Palette)
local Patterns = require(script.Parent.Patterns)

local W = Config.MAP_W
local H = Config.MAP_H
local N = Config.NUM_TILES

local BLOCK = 64
local BW = math.ceil(W / BLOCK)
local BH = math.ceil(H / BLOCK)

-- Upload chunk height.
local MAX_BAND_ROWS = 96


-- AssetService:CreateEditableImage refuses any axis >= 1024 AT RUNTIME. (The
-- plugin/edit context has no such limit, which is exactly how a 1600x1000
-- image passed verification in Studio and then failed in the actual game.)
-- So the map is split across a grid of images and reassembled on screen.
local MAX_IMAGE_DIM = 900
local COLS = math.ceil(W / MAX_IMAGE_DIM)
local ROWS = math.ceil(H / MAX_IMAGE_DIM)
local IMG_W = W // COLS
local IMG_H = H // ROWS
assert(IMG_W * COLS == W and IMG_H * ROWS == H, "map size must divide evenly into image tiles")

-- How the reference composites a nation onto the map -- and it is two
-- different rules for two different things:
--   * Territory is the nation's colour laid over the terrain at this alpha, so
--     coast, relief and mountains still read UNDER owned land. A flat fill
--     erases the map the moment anybody owns anything.
--   * A border is not a tint at all: it is the nation's colour darkened by a
--     flat subtraction, at FULL opacity. Blending a border leaves it too weak
--     to survive at one pixel a tile, which is the size it is mostly seen at.
-- Both numbers are upstream's own, from render-settings.json:
-- mapOverlay.territoryAlpha 0.588 (which is exactly the 150/255 the older
-- canvas renderer used), mapOverlay.territorySaturation 0.85, and
-- default-theme.json borderDarken 0.125 -- a LIGHTNESS drop, not an RGB one.
local TERRITORY_ALPHA = Palette.TERRITORY_ALPHA
local TERRITORY_SATURATION = Palette.TERRITORY_SATURATION
local BORDER_DARKEN_L = 0.125
-- ...and YOUR nation's outline is LIFTED by this much instead of darkened.
-- Measured off a screenshot of the reference rather than guessed: the focused
-- player's rim comes out BRIGHTER than its own fill (227,153,151 over a
-- 183,111,120 fill) while every other nation's rim is darker than theirs. The
-- pair of them meeting is what makes an edge read as two-tone.
local BORDER_LIFT_ME = 0.45
-- An allied seam. Deliberately not zero: a line still has to exist or two
-- teammates' territories merge into one blob and you cannot see who holds
-- what inside the bloc.
local BORDER_DARKEN_ALLY = 0.045
local HIGHLIGHT_LIFT = 0.55
-- One mask byte per tile, a bit per border effect. Both effects mark the
-- exact tiles they lit, which is what lets either be cleared precisely
-- however much territory moved while it was up.
local TINT_HOVER = 1
local TINT_FLASH = 2
-- Which empire wears which pattern, as a flat array over the id space. Held
-- as an upvalue because `recolor` reads it once per owned tile.
local PATTERN_OF = Patterns.OWNER
-- The one pattern that is a HUE and not a lightness step, hoisted for exactly
-- the reason PATTERN_OF is: the test below runs once per owned tile, and a
-- comparison against an upvalue beats a table index into the module.
local RAINBOW_PAT = Patterns.RAINBOW_INDEX

-- A contested seam is the two nations' border colours AVERAGED -- and nothing
-- else. It is tempting to darken it further so it outranks a quiet coastal
-- edge, and that was tried: at 0.62 the seam between two mid-value nations
-- lands near 37/255, so every internal border on a fully-claimed map reads as
-- a black gash and the nations' own colours drop out of the line entirely.
-- The seam is already distinct from either neighbour by HUE, which is the
-- property that was wanted; it does not also need to be distinct by value.

-- How far the detail noise may shift a tile's band, in magnitude units.
-- This is the whole reason the map does not look airbrushed. Our elevation is
-- SYNTHESISED from a handful of mountain-range polylines, so it is perfectly
-- smooth, and the reference's comes from a real relief image, which is not:
-- their green/tan/white boundaries are ragged and mottled at every scale,
-- ours would be glass-smooth sweeping curves. The noise stands in for the
-- detail real terrain has. VISUAL ONLY -- gameplay reads the raw magnitude
-- out of the terrain byte, so terrain costs and combat balance are untouched.
local DETAIL_AMPLITUDE = 7.0
local DETAIL_CELL = 5 -- noise cell size in tiles

-- FALLOUT. The ground a warhead leaves behind, and the only place on this map
-- where terrain is overpainted rather than tinted: at 0.588 -- the alpha a
-- NATION gets -- a crater in the middle of a bright plain still reads as
-- plain, and the whole point of glassing ground is that you can see from
-- across the map that it is gone. So the terrain survives underneath at about
-- a tenth, which is enough for relief and coastline to show through and not
-- enough for the green to be mistaken for grass.
--
-- Two colours mottled by the SAME value noise the terrain bands are cut with:
-- scorched black-olive in the hollows, an acid green on the rises. One flat
-- green over two thousand tiles reads as a sticker somebody put on the map;
-- the noise is what makes it read as ground.
local FALLOUT_ALPHA = 0.9
local FALLOUT_DARK_R, FALLOUT_DARK_G, FALLOUT_DARK_B = 48, 62, 32
local FALLOUT_ACID_R, FALLOUT_ACID_G, FALLOUT_ACID_B = 136, 176, 56

-- A TRANSPORT'S ROUTE, painted into the sea it is crossing rather than laid
-- over it -- the other place on this map where something that is not terrain
-- writes terrain pixels. Structures stamps the tiles (see its wake section);
-- everything this file does is turn a stamped tile into a colour.
--
-- STRONGER THAN A NATION'S 0.588, and it has to be: a nation gets a whole
-- coastline to make that alpha read, while a wake is ONE TILE wide -- one
-- screen pixel at DEFAULT_ZOOM. At the territory alpha a route came out as a
-- smudge you had to already know was there. At 0.72 the line holds its own
-- pixel and the sea's shading still runs through it.
local WAKE_ALPHA = 0.72

-- Integer hash. Stays inside 32 bits after the first multiply so it never
-- loses precision in a double.
local function ihash(x: number, y: number): number
	local h = bit32.bxor(bit32.band(x * 374761393, 0xFFFFFFFF), bit32.band(y * 668265263, 0xFFFFFFFF))
	h = bit32.bxor(h, bit32.rshift(h, 15))
	h = bit32.band(bit32.bxor(h, bit32.lshift(h, 7)), 0xFFFFFFFF)
	h = bit32.bxor(h, bit32.rshift(h, 11))
	return bit32.band(h, 4095) / 4095
end

-- Smoothed value noise, so patches are blobby rather than TV static.
local function cellNoise(x: number, y: number, cell: number, seed: number): number
	local cx = x // cell + seed
	local cy = y // cell + seed
	local fx = (x % cell) / cell
	local fy = (y % cell) / cell
	fx = fx * fx * (3 - 2 * fx)
	fy = fy * fy * (3 - 2 * fy)
	local a = ihash(cx, cy)
	local b = ihash(cx + 1, cy)
	local c = ihash(cx, cy + 1)
	local d = ihash(cx + 1, cy + 1)
	local top = a + (b - a) * fx
	local bot = c + (d - c) * fx
	return top + (bot - top) * fy
end

-- THREE octaves at deliberately unrelated cell sizes, weighted almost evenly.
-- The two small ones give the surface its grain; the large one is what makes
-- a band boundary wander over tens of tiles instead of tracing a clean
-- contour, and it is the octave that does most of the work. Unrelated sizes
-- matter -- harmonically related cells beat against each other and the plains
-- come out as a regular fabric weave rather than as terrain.
local function valueNoise(x: number, y: number): number
	return cellNoise(x, y, DETAIL_CELL, 0) * 0.30
		+ cellNoise(x, y, 17, 7919) * 0.34
		+ cellNoise(x, y, 53, 104729) * 0.36
end

local Renderer = {}
Renderer.__index = Renderer

export type Renderer = typeof(setmetatable({} :: any, Renderer))

-- `container` is a Frame; the image tiles are created inside it as a grid and
-- laid out with Scale, so the camera only has to size and move the container.
function Renderer.new(mapId: string, seed: number, container: Frame): Renderer
	local terrain, landCount = MapGen.generate(mapId, seed)

	local images = {}
	local labels = {}
	for r = 0, ROWS - 1 do
		for c = 0, COLS - 1 do
			local img = AssetService:CreateEditableImage({ Size = Vector2.new(IMG_W, IMG_H) })
			local lbl = Instance.new("ImageLabel")
			lbl.Name = string.format("Tile_%d_%d", c, r)
			lbl.BackgroundTransparency = 1
			lbl.BorderSizePixel = 0
			lbl.ResampleMode = Enum.ResamplerMode.Pixelated
			-- Input is handled on the container; tiles must not swallow it.
			lbl.Active = false
			lbl.Size = UDim2.fromScale(1 / COLS, 1 / ROWS)
			lbl.Position = UDim2.fromScale(c / COLS, r / ROWS)
			lbl.ImageContent = Content.fromObject(img)
			lbl.Parent = container
			local k = r * COLS + c
			images[k] = img
			labels[k] = lbl
		end
	end

	local self = setmetatable({
		terrain = terrain,
		owner = buffer.create(N),
		rgba = buffer.create(N * 4),
		detail = buffer.create(N),
		landCount = landCount,

		-- One byte a tile: is this ground irradiated. The client keeps its own
		-- copy of a bit the server never sends -- a blast arrives as six
		-- numbers and is expanded here (see Missiles), and conquering clears it
		-- in setOwner the same way the simulation clears it in Sim.conquer. The
		-- counter is only there to let setOwner skip the read entirely in the
		-- overwhelmingly common case of a round in which nobody has nuked
		-- anybody, since it sits in the hottest write path in the client.
		fallout = buffer.create(N),
		falloutCount = 0,

		-- One byte a tile: whose transport has crossed this water. The route
		-- lines the boats drag behind them are PIXELS IN THIS MAP rather than
		-- frames over it, so they have to live beside the terrain -- that is
		-- what makes them survive every repaint that walks it: a border moving
		-- on the coast, a hover, a flash, a whole-map snapshot. An OWNER ID and
		-- not a flag, because recolor has to tint the line in its empire's
		-- colour off one read. Water only, so half of it is dead weight, and it
		-- is still the cheapest thing that works.
		wake = buffer.create(N),

		images = images,
		labels = labels,
		-- Is the terrain point-sampled right now. See setResample: Pixelated is
		-- only honest at 1:1 and above, and the labels are built Pixelated.
		pixelated = true,
		container = container,
		scratch = buffer.create(IMG_W * MAX_BAND_ROWS * 4),

		dirtyRow = {} :: { [number]: boolean },
		anyDirty = false,
		nbuf = table.create(4),

		localId = 0,
		highlightId = 0,
		hasOwners = false,

		-- Border tiles of highlightId, cached so the hover does not rescan,
		-- and a mask so recolor can ask "is this tile lit?" in O(1).
		-- Going through the MASK rather than `o == highlightId` is what makes
		-- a hover of unlimited length safe: a tile that joins the hovered
		-- nation while the mouse rests on it is simply not lit, instead of
		-- being lit by setOwner and then left lit forever because it was
		-- never in the list that clearing walks. The flash gets away without
		-- this only because it lives 0.45s.
		highlightTiles = {} :: { number },
		tintMask = buffer.create(N),

		-- Border lists memoised per nation against a monotonic per-nation
		-- change counter. See collectBorderTiles.
		borderCache = {} :: { [number]: { number } },
		borderStamp = {} :: { [number]: number },
		ownerStamp = {} :: { [number]: number },

		-- Click acknowledgement. The client drives flashAmount down over a few
		-- frames and recolor blends the territory toward flashRGB by that
		-- fraction. Kept separate from highlightId so a flash and a hover can
		-- land on the same empire without either cancelling the other.
		flashId = 0,
		flashAmount = 0,
		-- Border tiles of flashId, cached so the fade steps do not rescan.
		flashTiles = {} :: { number },
		flashR = 255,
		flashG = 255,
		flashB = 255,

		-- [ownerId] = { [blockIndex] = true }. Blocks are only ever added, so
		-- a stale entry costs one extra block scan and never a wrong pixel.
		ownerBlocks = {} :: { [number]: { [number]: boolean } },

		-- Running tile-position sums per owner, so a nation's centroid is O(1)
		-- instead of a 1.6M scan. NationLabels reads these twice a second to
		-- decide where each name sits.
		ownerSumX = {} :: { [number]: number },
		ownerSumY = {} :: { [number]: number },
		ownerCount = {} :: { [number]: number },
	}, Renderer)

	-- Bake the detail noise once (1.6 MB) rather than hashing on every
	-- recolor -- per-tick deltas repaint five tiles each and this runs in the
	-- inner loop.
	for y = 0, H - 1 do
		local row = y * W
		for x = 0, W - 1 do
			buffer.writeu8(self.detail, row + x, math.floor(valueNoise(x, y) * 255))
		end
	end

	-- Paint the unowned world once, through the SAME path every later update
	-- uses, so the dither pattern is identical. recolor writes RGB only.
	for i = 0, N - 1 do
		buffer.writeu8(self.rgba, i * 4 + 3, 255)
		Renderer.recolor(self, i)
	end

	for y = 0, H - 1 do
		self.dirtyRow[y] = true
	end
	self.anyDirty = true
	Renderer.flush(self)

	return self
end

-- ------------------------------------------------------------- colouring ---

-- -1 when `i` is not a border tile, otherwise the owner on the other side.
-- A RIVAL always beats unclaimed ground: a tile touching both open land and an
-- enemy is a contested border first, which is what makes a clash seam read as
-- one continuous line instead of dashing wherever the front is ragged.
local function borderAgainst(owner: buffer, i: number, me: number): number
	local best = -1
	local x = i % W
	local o
	if i >= W then
		o = buffer.readu8(owner, i - W)
		if o ~= me then
			if o ~= 0 then
				return o
			end
			best = 0
		end
	end
	if i < N - W then
		o = buffer.readu8(owner, i + W)
		if o ~= me then
			if o ~= 0 then
				return o
			end
			best = 0
		end
	end
	if x ~= 0 then
		o = buffer.readu8(owner, i - 1)
		if o ~= me then
			if o ~= 0 then
				return o
			end
			best = 0
		end
	end
	if x ~= W - 1 then
		o = buffer.readu8(owner, i + 1)
		if o ~= me then
			if o ~= 0 then
				return o
			end
			best = 0
		end
	end
	return best
end

local function isBorderTile(owner: buffer, i: number): boolean
	local me = buffer.readu8(owner, i)
	local x = i % W
	if i >= W and buffer.readu8(owner, i - W) ~= me then
		return true
	end
	if i < N - W and buffer.readu8(owner, i + W) ~= me then
		return true
	end
	if x ~= 0 and buffer.readu8(owner, i - 1) ~= me then
		return true
	end
	if x ~= W - 1 and buffer.readu8(owner, i + 1) ~= me then
		return true
	end
	return false
end

function Renderer.recolor(self: Renderer, i: number)
	local rgba = self.rgba
	local base = i * 4
	local b = buffer.readu8(self.terrain, i)
	local mag = bit32.band(b, 63)
	local isLand = bit32.btest(b, 128)

	-- The noised magnitude picks the BAND as well as the shade within it. That
	-- ordering is the whole trick: deriving the band from the raw magnitude
	-- and only shading with the noise leaves every green/tan/white boundary a
	-- mathematically smooth contour that no amount of noise can touch, because
	-- the noise never gets to move which side of the line a tile is on.
	-- Land/water and impassable still come off the RAW byte, so coastlines and
	-- the void stay exactly where the map says they are.
	local x = i % W
	local y = (i - x) / W
	local vmag = mag + (buffer.readu8(self.detail, i) / 255 - 0.5) * DETAIL_AMPLITUDE
	if vmag < 0 then
		vmag = 0
	end

	local tType: number
	if not isLand then
		tType = 0
	elseif mag >= 63 then
		tType = 4
	elseif vmag < 11 then
		tType = 1
	elseif vmag < 21 then
		tType = 2
	else
		tType = 3
	end
	-- Bit 6 is MapGen's shoreline flag, set on both sides of every coast.
	local tr, tg, tb = Palette.terrainSample(tType, vmag, bit32.btest(b, 64))

	-- Irradiated ground replaces the terrain colour BEFORE ownership is laid
	-- over it, which is the ordering that matters: a crater is almost always
	-- unclaimed (the blast relinquishes every tile it touches) but a nation
	-- pushing back into one has to be able to see it is standing in a crater --
	-- the ground under it costs five times what open land does.
	if buffer.readu8(self.fallout, i) ~= 0 then
		local n = buffer.readu8(self.detail, i) / 255
		local fr = FALLOUT_DARK_R + (FALLOUT_ACID_R - FALLOUT_DARK_R) * n
		local fg = FALLOUT_DARK_G + (FALLOUT_ACID_G - FALLOUT_DARK_G) * n
		local fb = FALLOUT_DARK_B + (FALLOUT_ACID_B - FALLOUT_DARK_B) * n
		tr += (fr - tr) * FALLOUT_ALPHA
		tg += (fg - tg) * FALLOUT_ALPHA
		tb += (fb - tb) * FALLOUT_ALPHA
	end

	-- The route a transport has dragged across this water, in its owner's
	-- colour and DESATURATED THE SAME WAY TERRITORY IS: a route is the same
	-- empire drawn on the same map, and a fully saturated line running up to a
	-- desaturated coast reads as two different empires. It goes in HERE, with
	-- the terrain rather than after the ownership branch, because that is what
	-- it is now -- water this empire has been over.
	--
	-- Water only, which costs nothing (isLand is already in hand) and is what
	-- keeps a landing from leaving a coloured pixel on somebody's beach.
	if not isLand then
		local wk = buffer.readu8(self.wake, i)
		if wk ~= 0 then
			local wr, wg, wb = Palette.colorFor(wk, self.localId)
			wr, wg, wb = Palette.desaturate(wr, wg, wb, TERRITORY_SATURATION)
			tr += (wr - tr) * WAKE_ALPHA
			tg += (wg - tg) * WAKE_ALPHA
			tb += (wb - tb) * WAKE_ALPHA
		end
	end

	local o = buffer.readu8(self.owner, i)
	if o == 0 then
		buffer.writeu8(rgba, base, tr)
		buffer.writeu8(rgba, base + 1, tg)
		buffer.writeu8(rgba, base + 2, tb)
	else
		local pr, pg, pb = Palette.colorFor(o, self.localId)
		local rr, gg, bb

		local against = borderAgainst(self.owner, i, o)
		if against >= 0 then
			-- Outline: the nation's own colour darkened in lightness, drawn
			-- OVER the terrain rather than through it.
			rr, gg, bb = Palette.darken(pr, pg, pb, BORDER_DARKEN_L)
			if o == self.localId then
				-- YOUR OUTLINE IS THE BRIGHT ONE, and it is the one seam
				-- colour that never averages with anybody.
				--
				-- Taken off the reference by measuring its pixels, and the
				-- measurement corrected the obvious reading: a seam there is
				-- not a two-tile band on one side, it is TWO one-tile bands,
				-- the enemy's darkened and the focused player's lifted, lying
				-- against each other. The contrast between the two IS the
				-- effect -- which is exactly what averaging them (below)
				-- destroys, and why this branch has to come first.
				--
				-- Free: it sits inside a test the loop already ran, and reads
				-- no extra neighbours.
				rr += (255 - rr) * BORDER_LIFT_ME
				gg += (255 - gg) * BORDER_LIFT_ME
				bb += (255 - bb) * BORDER_LIFT_ME
			elseif against > 0 and against ~= self.localId then
				local team = Palette.teamOf(o)
				if team ~= nil and team == Palette.teamOf(against) then
					-- AN ALLIED SEAM IS NOT A FRONT. Two teammates in contact
					-- were getting the same hard clash line as two enemies, so
					-- a bloc read as a dozen countries at war with each other.
					-- Barely darkened, it recedes to an internal line and the
					-- eye keeps the shape of the SIDE.
					--
					-- `teamOf` is nil in a free-for-all, so the whole rule is
					-- inert there -- and note the nil is tested rather than
					-- just the equality, because nil == nil would have made
					-- every seam in every FFA round friendly.
					rr, gg, bb = Palette.darken(pr, pg, pb, BORDER_DARKEN_ALLY)
				else
					-- Two nations in contact ink to the SAME mix of their two
					-- colours, so a contested border reads as one seam belonging to
					-- neither side -- you can see who is pressing who without tracing
					-- which side of the line you are on. The sum is commutative, so
					-- both sides land on the identical value by construction.
					-- Two statements on purpose: a multi-return call in a
					-- non-final argument slot is truncated to ONE value, so
					-- darken(colorFor(...), amount) silently passes (r, amount).
					local ar, ag, ab = Palette.colorFor(against, self.localId)
					ar, ag, ab = Palette.darken(ar, ag, ab, BORDER_DARKEN_L)
					rr = (rr + ar) * 0.5
					gg = (gg + ag) * 0.5
					bb = (bb + ab) * 0.5
				end
			end
			-- `against == self.localId` falls through on purpose, keeping the
			-- plain darkened outline: that dark band lying against your bright
			-- one is the two-tone edge.
		else
			-- Interior: the nation's colour, pulled slightly toward grey and
			-- then laid over the terrain, so coast, relief and mountains still
			-- read under owned land. The desaturation is what stops 72 fills
			-- from fighting the terrain underneath them.
			local sr, sg, sb = Palette.desaturate(pr, pg, pb, TERRITORY_SATURATION)
			rr = tr + (sr - tr) * TERRITORY_ALPHA
			gg = tg + (sg - tg) * TERRITORY_ALPHA
			bb = tb + (sb - tb) * TERRITORY_ALPHA

			-- ...AND THE OWNER'S PATTERN, laid over the finished fill.
			--
			-- IT IS IN THE INTERIOR BRANCH ON PURPOSE, so a border is never
			-- patterned: the outline is the layer that says where one nation
			-- stops and the next begins, and texture running through it would
			-- cost the map the one line it cannot afford to lose. Everything
			-- that makes this safe to hand a player is in the Patterns module
			-- -- zero-mean grids, no hue movement, an amplitude under the
			-- border's -- and this is the only place it is spent.
			--
			-- COSTS NOTHING WHEN NOBODY IS WEARING ONE, which is the usual
			-- case for most of a roster: the AI never wears a pattern, so
			-- two thirds of the map's owned tiles take one array read and
			-- the branch falls through.
			local pat = PATTERN_OF[o]
			if pat == RAINBOW_PAT then
				-- THE ONE PATTERN THAT MOVES HUE. It takes the tile rather than
				-- a sampled weight, and it has no zero cell to skip: every tile
				-- of the sweep is coloured. It sits in THIS branch with all the
				-- others, which is what keeps a rainbow empire's outline in its
				-- own colour -- the sweep never reaches the border.
				rr, gg, bb = Patterns.rainbow(rr, gg, bb, x, y)
			elseif pat > 1 then
				local k = Patterns.sample(pat, x, y)
				if k ~= 0 then
					rr, gg, bb = Patterns.apply(rr, gg, bb, k)
				end
			end
		end

		-- BORDER ONLY, for the same reason as the flash below. Lifting the
		-- whole fill cost one recolor per OWNED tile -- 75 ms at a 22%-of-map
		-- empire -- and it fires on every hover-owner change, i.e. repeatedly
		-- while the mouse sweeps a packed map. The mask holds exactly the
		-- border tiles setHighlight collected, so no `against` test is needed.
		local tint = buffer.readu8(self.tintMask, i)
		if bit32.band(tint, TINT_HOVER) ~= 0 then
			rr += (255 - rr) * HIGHLIGHT_LIFT
			gg += (255 - gg) * HIGHLIGHT_LIFT
			bb += (255 - bb) * HIGHLIGHT_LIFT
		end

		-- The tap flash sits ON TOP of the hover lift, so clicking the empire
		-- you are already hovering still visibly changes.
		-- BORDER ONLY. Tinting every owned tile meant the cost of a flash
		-- scaled with the target's territory: at 22% of the map that was
		-- 73 ms a step and ~513 ms across the fade. `against >= 0` is already
		-- computed above and is exactly "this tile is on the nation's edge".
		-- Driven off the mask, NOT `o == flashId and against >= 0`. With the
		-- owner test, a tile that BECOMES this nation's border mid-effect is
		-- tinted here by setOwner's repaint but is absent from the list that
		-- clearing walks, so it stays tinted after the flash ends. Measured:
		-- 723 stray pixels after 184 tiles changed hands under a live flash.
		local fa = self.flashAmount
		if fa > 0 and bit32.band(tint, TINT_FLASH) ~= 0 then
			rr += (self.flashR - rr) * fa
			gg += (self.flashG - gg) * fa
			bb += (self.flashB - bb) * fa
		end

		buffer.writeu8(rgba, base, rr > 255 and 255 or rr)
		buffer.writeu8(rgba, base + 1, gg > 255 and 255 or gg)
		buffer.writeu8(rgba, base + 2, bb > 255 and 255 or bb)
	end

	self.dirtyRow[y] = true
	self.anyDirty = true
end

-- A tile changing hands also flips whether its neighbours are border tiles,
-- so all five have to be repainted.
function Renderer.setOwner(self: Renderer, i: number, ownerId: number)
	-- Read the outgoing owner BEFORE the write; the centroid sums have to be
	-- debited from whoever is losing the tile.
	local previous = buffer.readu8(self.owner, i)
	buffer.writeu8(self.owner, i, ownerId)

	-- CONQUERING CLEARS FALLOUT, the same rule Sim.conquer applies to the
	-- server's own bitset. The client is not told about the bit, it derives it,
	-- so it has to derive the clearing too -- otherwise ground somebody has
	-- already retaken stays green on screen for the rest of the round while the
	-- simulation has long since forgotten it was ever glassed.
	if ownerId ~= 0 and self.falloutCount > 0 and buffer.readu8(self.fallout, i) ~= 0 then
		buffer.writeu8(self.fallout, i, 0)
		self.falloutCount -= 1
	end

	if previous ~= ownerId then
		-- Both sides' cached border lists are now stale. See collectBorderTiles.
		self.ownerStamp[previous] = (self.ownerStamp[previous] or 0) + 1
		self.ownerStamp[ownerId] = (self.ownerStamp[ownerId] or 0) + 1
		local px = i % W
		local py = (i - px) / W
		if previous ~= 0 then
			local c = (self.ownerCount[previous] or 0) - 1
			if c <= 0 then
				self.ownerCount[previous] = nil
				self.ownerSumX[previous] = nil
				self.ownerSumY[previous] = nil
			else
				self.ownerCount[previous] = c
				self.ownerSumX[previous] = (self.ownerSumX[previous] or 0) - px
				self.ownerSumY[previous] = (self.ownerSumY[previous] or 0) - py
			end
		end
		if ownerId ~= 0 then
			self.ownerCount[ownerId] = (self.ownerCount[ownerId] or 0) + 1
			self.ownerSumX[ownerId] = (self.ownerSumX[ownerId] or 0) + px
			self.ownerSumY[ownerId] = (self.ownerSumY[ownerId] or 0) + py
		end
	end

	if ownerId ~= 0 then
		local x = i % W
		local bi = ((i - x) / W // BLOCK) * BW + (x // BLOCK)
		local set = self.ownerBlocks[ownerId]
		if not set then
			set = {}
			self.ownerBlocks[ownerId] = set
		end
		set[bi] = true
	end

	Renderer.recolor(self, i)
	local nbuf = self.nbuf
	local n = 0
	local x = i % W
	if i >= W then n += 1; nbuf[n] = i - W end
	if i < N - W then n += 1; nbuf[n] = i + W end
	if x ~= 0 then n += 1; nbuf[n] = i - 1 end
	if x ~= W - 1 then n += 1; nbuf[n] = i + 1 end
	for k = 1, n do
		Renderer.recolor(self, nbuf[k])
	end
end

-- One warhead's blast set, expanded client-side from the six numbers the
-- server sent and handed straight here. ONLY LAND takes fallout -- the
-- shockwave crosses a strait and clears the shipping on it, but the sea does
-- not stay poisoned -- which is the identical test the simulation applies, so
-- the two copies of the bit agree tile for tile without either being sent.
--
-- No neighbour repaint, unlike setOwner: fallout is a property of the tile
-- alone and changes nobody's border.
function Renderer.setFalloutTiles(self: Renderer, tiles: { number }, count: number)
	local terrain = self.terrain
	local fallout = self.fallout
	for k = 1, count do
		local i = tiles[k]
		if bit32.btest(buffer.readu8(terrain, i), 128) and buffer.readu8(fallout, i) == 0 then
			buffer.writeu8(fallout, i, 1)
			self.falloutCount += 1
			Renderer.recolor(self, i)
		end
	end
end

-- ONE TILE OF A TRANSPORT'S ROUTE, and the whole of what this file knows about
-- boats. Structures decides which tiles a crossing covers and when they go;
-- this turns one of them into water somebody has sailed.
--
-- WATER ONLY, refused here rather than tested at the call site: a crossing ends
-- ON a beach and the tile list that describes it therefore ends on land, so
-- every caller would need the same guard and one of them would eventually not
-- have it -- as a coloured pixel stuck on a coastline for the rest of a round.
--
-- No neighbour repaint, like fallout and unlike setOwner: a wake belongs to its
-- own tile and changes nobody's border.
function Renderer.setWake(self: Renderer, i: number, ownerId: number)
	if bit32.btest(buffer.readu8(self.terrain, i), 128) then
		return
	end
	if buffer.readu8(self.wake, i) == ownerId then
		return
	end
	buffer.writeu8(self.wake, i, ownerId)
	Renderer.recolor(self, i)
end

-- ...and back to open water. OWNER-CHECKED, because two routes that cross share
-- a tile and whichever boat ends first would otherwise punch a hole in the
-- other empire's line. (Two of the SAME empire's transports crossing still can:
-- one tile of one line, which is not worth a reference count per tile of sea.)
function Renderer.clearWake(self: Renderer, i: number, ownerId: number)
	if ownerId == 0 or buffer.readu8(self.wake, i) ~= ownerId then
		return
	end
	buffer.writeu8(self.wake, i, 0)
	Renderer.recolor(self, i)
end

function Renderer.setLocalId(self: Renderer, id: number)
	if self.localId == id then
		return
	end
	self.localId = id
	-- Nothing is owned yet at join time; the snapshot repaint will apply it.
	if self.hasOwners then
		Renderer.repaintAll(self)
	end
end

-- Repaints only the tiles belonging to `a` or `b`, walking the block index
-- rather than the whole 1.6M-tile map.
-- Every tile on `id`'s edge. One block scan, which is the unavoidable part;
-- the point of returning a LIST is that the fade steps after this one just walk
-- it instead of scanning again.
local function scanBorderTiles(self: Renderer, id: number): { number }
	local tiles = {}
	local set = self.ownerBlocks[id]
	if not set or id == 0 then
		return tiles
	end
	local owner = self.owner
	local n = 0
	for bi in set do
		local bx = bi % BW
		local by = (bi - bx) / BW
		local x0 = bx * BLOCK
		local y0 = by * BLOCK
		local x1 = math.min(x0 + BLOCK - 1, W - 1)
		local y1 = math.min(y0 + BLOCK - 1, H - 1)
		for y = y0, y1 do
			local rowBase = y * W
			for x = x0, x1 do
				local i = rowBase + x
				if buffer.readu8(owner, i) == id and borderAgainst(owner, i, id) >= 0 then
					n += 1
					tiles[n] = i
				end
			end
		end
	end
	return tiles
end

-- Memoised in front of the scan, because the scan is the expensive half:
-- of a 17.8 ms hover onto a 22%-of-map empire, ~14 ms is walking its 76
-- blocks and only ~3.9 ms is recolouring the 4,623 tiles that result.
--
-- A stamp match is PROOF the cached list is still exact, not a heuristic.
-- A nation's border set can only change when its own TILE set changes: a
-- neighbour flipping from one rival to another alters the seam's COLOUR
-- (setOwner repaints it) but not which tiles sit on the edge. Every
-- setOwner bumps the stamp of BOTH sides, so any gain or loss invalidates.
--
-- The returned table is shared with whatever held it before and is never
-- mutated. An invalidation builds a NEW list, so a flash or hover still
-- holding the old one clears exactly the tiles it lit -- which is the
-- behaviour those paths need anyway.
local function collectBorderTiles(self: Renderer, id: number): { number }
	if id == 0 then
		return {}
	end
	local stamp = self.ownerStamp[id] or 0
	if self.borderStamp[id] == stamp then
		return self.borderCache[id]
	end
	local tiles = scanBorderTiles(self, id)
	self.borderCache[id] = tiles
	self.borderStamp[id] = stamp
	return tiles
end

-- Flashes one empire's territory toward `color` by `amount` (0..1).
--
-- A tap that changes nothing on the map reads as a tap the game did not
-- receive: the HUD line explaining the click sits in another corner of the
-- screen, and the player is looking at the territory.
--
-- Only the target's BORDER is tinted. Tinting the fill made the cost scale with
-- the target's territory -- 73 ms a call at 22% of the map, and the client
-- steps the fade about seven times, so ~513 ms of frame for one tap. The first
-- call pays one block scan to collect the border; the rest walk the cache.
function Renderer.setFlash(self: Renderer, id: number, amount: number, color: Color3?)
	local prev = self.flashId
	if prev == id and math.abs(self.flashAmount - amount) < 0.02 then
		return
	end
	self.flashId = id
	self.flashAmount = amount
	if color then
		self.flashR = color.R * 255
		self.flashG = color.G * 255
		self.flashB = color.B * 255
	end
	if prev == 0 and id == 0 then
		return
	end

	-- Only the target's BORDER is tinted. Tinting the fill made the cost
	-- scale with the target's territory -- 73 ms a call at 22% of the map,
	-- times about seven fade steps. The list is memoised per nation, so a
	-- flash on a nation whose borders have not moved costs no scan at all.
	local mask = self.tintMask
	if prev ~= id then
		for _, i in ipairs(self.flashTiles) do
			buffer.writeu8(mask, i, bit32.band(buffer.readu8(mask, i), bit32.bnot(TINT_FLASH)))
			Renderer.recolor(self, i)
		end
		local tiles = collectBorderTiles(self, id)
		self.flashTiles = tiles
		for _, i in ipairs(tiles) do
			buffer.writeu8(mask, i, bit32.bor(buffer.readu8(mask, i), TINT_FLASH))
		end
	end
	-- The fade steps land here only: mask already set, just repaint at the
	-- new amount.
	for _, i in ipairs(self.flashTiles) do
		Renderer.recolor(self, i)
	end
end

-- Lifts the hovered empire's territory. Scans only the blocks that empire is
-- known to touch rather than the whole map.
function Renderer.setHighlight(self: Renderer, id: number)
	local previous = self.highlightId
	if previous == id then
		return
	end
	self.highlightId = id
	if previous == 0 and id == 0 then
		return
	end

	-- Same shape as setFlash: the work is the hovered nation's PERIMETER
	-- (0.7-2.1% of its area), not its territory. Clear the old list -- unmask
	-- then recolor, so each tile is repainted unlit -- then collect the new
	-- nation's border, mask it, and paint it lit. recolor(i) reads only its
	-- own mask byte, so one pass each is enough.
	local mask = self.tintMask
	for _, i in ipairs(self.highlightTiles) do
		buffer.writeu8(mask, i, bit32.band(buffer.readu8(mask, i), bit32.bnot(TINT_HOVER)))
		Renderer.recolor(self, i)
	end

	local tiles = collectBorderTiles(self, id)
	self.highlightTiles = tiles
	for _, i in ipairs(tiles) do
		buffer.writeu8(mask, i, bit32.bor(buffer.readu8(mask, i), TINT_HOVER))
		Renderer.recolor(self, i)
	end
end

-- Repaints one empire's own tiles -- the whole territory, not just its edge
-- -- by walking the block index the same way the hover scan does. There is one
-- caller: an empire's PATTERN changing mid-round, which happens when a profile
-- lands a moment after its owner joined. A full repaint would be every tile
-- on the map for a change that usually touches one nation with almost no land
-- of its own yet.
function Renderer.repaintOwner(self: Renderer, id: number)
	local set = self.ownerBlocks[id]
	if not set or id == 0 then
		return
	end
	local owner = self.owner
	for bi in set do
		local bx = bi % BW
		local by = (bi - bx) / BW
		local x0 = bx * BLOCK
		local y0 = by * BLOCK
		local x1 = math.min(x0 + BLOCK - 1, W - 1)
		local y1 = math.min(y0 + BLOCK - 1, H - 1)
		for y = y0, y1 do
			local rowBase = y * W
			for x = x0, x1 do
				local i = rowBase + x
				if buffer.readu8(owner, i) == id then
					Renderer.recolor(self, i)
				end
			end
		end
	end
end

-- Bulk owner load (round start / mid-game join).
function Renderer.loadOwners(self: Renderer, source: buffer, offset: number)
	buffer.copy(self.owner, offset, source, 0, buffer.len(source))
	self.hasOwners = true
	-- Ownership changed wholesale, so a hover cached against the old map
	-- points at tiles that may now belong to anyone.
	buffer.fill(self.tintMask, 0, 0)
	self.highlightTiles = {}
	self.highlightId = 0
	self.flashTiles = {}
	self.flashId = 0
	self.flashAmount = 0
	-- This path moves ownership without a single setOwner call, so no stamp
	-- moves and every memoised border list would be silently wrong.
	self.borderCache = {}
	self.borderStamp = {}
	self.ownerStamp = {}
end

function Renderer.repaintAll(self: Renderer)
	-- Rebuild the block index AND the centroid sums from scratch: a bulk load
	-- bypasses setOwner, so both would otherwise describe the previous round.
	table.clear(self.ownerBlocks)
	table.clear(self.ownerSumX)
	table.clear(self.ownerSumY)
	table.clear(self.ownerCount)
	local owner = self.owner
	for i = 0, N - 1 do
		local o = buffer.readu8(owner, i)
		if o ~= 0 then
			local x = i % W
			local y = (i - x) / W
			local bi = (y // BLOCK) * BW + (x // BLOCK)
			local set = self.ownerBlocks[o]
			if not set then
				set = {}
				self.ownerBlocks[o] = set
			end
			set[bi] = true
			self.ownerCount[o] = (self.ownerCount[o] or 0) + 1
			self.ownerSumX[o] = (self.ownerSumX[o] or 0) + x
			self.ownerSumY[o] = (self.ownerSumY[o] or 0) + y
		end
		Renderer.recolor(self, i)
	end
	self.hasOwners = true
	for y = 0, H - 1 do
		self.dirtyRow[y] = true
	end
	self.anyDirty = true
end

-- --------------------------------------------------------------- upload ----

-- Uploads dirty rows. A band is clipped to one image tile at a time; within a
-- tile each row is a contiguous run of IMG_W pixels inside the full-width
-- buffer, so a band costs one memcpy per row plus one write per tile.
function Renderer.flush(self: Renderer)
	if not self.anyDirty then
		return
	end

	local dirty = self.dirtyRow
	local srcRowBytes = W * 4
	local dstRowBytes = IMG_W * 4
	local scratch = self.scratch
	local rgba = self.rgba

	local y = 0
	while y < H do
		if dirty[y] then
			local y0 = y
			local count = 0
			-- A band may not straddle a tile boundary.
			local tileRow = y0 // IMG_H
			local tileLimit = (tileRow + 1) * IMG_H
			while y < H and y < tileLimit and dirty[y] and count < MAX_BAND_ROWS do
				dirty[y] = nil
				y += 1
				count += 1
			end

			-- WritePixelsBuffer demands the buffer length EXACTLY equal
			-- width * height * 4, so a max-sized scratch cannot be used for a
			-- short band. Full-height bands (the repaint path) reuse the
			-- preallocated scratch; short ones get an exact-size buffer.
			local dst = scratch
			if count ~= MAX_BAND_ROWS then
				dst = buffer.create(IMG_W * count * 4)
			end

			local localY = y0 - tileRow * IMG_H
			for c = 0, COLS - 1 do
				local xOffsetBytes = c * IMG_W * 4
				for k = 0, count - 1 do
					buffer.copy(
						dst,
						k * dstRowBytes,
						rgba,
						(y0 + k) * srcRowBytes + xOffsetBytes,
						dstRowBytes
					)
				end
				self.images[tileRow * COLS + c]:WritePixelsBuffer(
					Vector2.new(0, localY),
					Vector2.new(IMG_W, count),
					dst
				)
			end
		else
			y += 1
		end
	end

	self.anyDirty = false
end

-- --------------------------------------------------------- name anchors ----
-- Where a nation's name goes, and how much room it has.
--
-- The centroid alone is not enough: a crescent or a ring puts it in open water
-- (on the Mediterranean map, an empire wrapped round the sea has its centroid
-- ON the sea), so the centroid is only a starting guess and the real anchor is
-- the nearest tile the nation actually owns. Sampling on a stride keeps that
-- search cheap -- at one tile per pixel an exact search would be pointless
-- precision for something that positions a text label.

local ANCHOR_STRIDE = 6
local ANCHOR_MAX_R = 300
local ROOM_STEP = 3
local ROOM_MAX = 190

local function ownedAt(owner: buffer, x: number, y: number, id: number): boolean
	if x < 0 or x >= W or y < 0 or y >= H then
		return false
	end
	return buffer.readu8(owner, y * W + x) == id
end

-- How far the nation extends from (x,y) in one direction, in tiles.
local function reach(owner: buffer, x: number, y: number, dx: number, dy: number, id: number): number
	local d = ROOM_STEP
	while d <= ROOM_MAX do
		if not ownedAt(owner, x + dx * d, y + dy * d, id) then
			return d
		end
		d += ROOM_STEP
	end
	return ROOM_MAX
end

-- Eight directions for the hill climb below.
local CLIMB = { 1, 0, -1, 0, 0, 1, 0, -1, 1, 1, 1, -1, -1, 1, -1, -1 }

-- How much clear room this nation has around (x,y): the tightest of the four
-- cardinal reaches, so a long thin nation is measured by its WAIST and not its
-- length. -1 when the tile is not the nation's at all.
local function roomAt(owner: buffer, x: number, y: number, id: number): number
	if not ownedAt(owner, x, y, id) then
		return -1
	end
	local a = reach(owner, x, y, 1, 0, id)
	local b = reach(owner, x, y, -1, 0, id)
	if b < a then
		a = b
	end
	b = reach(owner, x, y, 0, 1, id)
	if b < a then
		a = b
	end
	b = reach(owner, x, y, 0, -1, id)
	if b < a then
		a = b
	end
	return a
end

-- Returns anchor x, y and a radius in map tiles, or nil if the nation is too
-- small to label.
function Renderer.nationAnchor(self: Renderer, id: number): (number?, number?, number?)
	local count = self.ownerCount[id]
	if not count or count < 1 then
		return nil, nil, nil
	end

	local owner = self.owner
	local cx = math.floor(self.ownerSumX[id] / count + 0.5)
	local cy = math.floor(self.ownerSumY[id] / count + 0.5)

	local ax, ay
	if ownedAt(owner, cx, cy, id) then
		ax, ay = cx, cy
	else
		for r = ANCHOR_STRIDE, ANCHOR_MAX_R, ANCHOR_STRIDE do
			for d = -r, r, ANCHOR_STRIDE do
				if ownedAt(owner, cx + d, cy - r, id) then
					ax, ay = cx + d, cy - r
					break
				elseif ownedAt(owner, cx + d, cy + r, id) then
					ax, ay = cx + d, cy + r
					break
				elseif ownedAt(owner, cx - r, cy + d, id) then
					ax, ay = cx - r, cy + d
					break
				elseif ownedAt(owner, cx + r, cy + d, id) then
					ax, ay = cx + r, cy + d
					break
				end
			end
			if ax then
				break
			end
		end
	end
	if not ax then
		return nil, nil, nil
	end

	-- Climb toward open ground. The spiral above returns the NEAREST owned
	-- tile, which on a concave nation sits on its edge: an 86,000-tile ring
	-- anchored with room for a SIX tile wide label. Hill-climbing on clear room
	-- costs a few hundred probes and finds the belly of the territory instead.
	local best = roomAt(owner, ax, ay, id)
	local step = 64
	local budget = 40
	while step >= 4 and budget > 0 do
		local moved = false
		for k = 1, 15, 2 do
			local nx = ax + CLIMB[k] * step
			local ny = ay + CLIMB[k + 1] * step
			local r = roomAt(owner, nx, ny, id)
			if r > best then
				best, ax, ay = r, nx, ny
				moved = true
			end
		end
		budget -= 1
		if not moved then
			step //= 2
		end
	end

	-- Capped by sqrt(area) as well, or a narrow nation that happens to be
	-- locally fat gets a name far larger than the territory carrying it.
	local radius = math.min(best, math.sqrt(count) * 0.62)
	return ax, ay, radius
end

-- PIXELATED IS ONLY HONEST AT 1:1 AND ABOVE. This map is one tile per pixel,
-- so at zoom 0.5 the 880x550 image is drawn into 440x275 and nearest-neighbour
-- keeps 440 of the 880 tile columns: it DROPS every other one, and which ones
-- it drops changes with every pixel the container grows. Measured across a
-- phone pinch (zoom 0.495 -> 0.541 in 0.002 steps): tile 600's city chip
-- slides smoothly while the ground under it jumps in stair-steps, the two
-- disagreeing by 0.45 to 1.35 TILES, and in 12 of those 24 steps that tile is
-- not drawn AT ALL while its chip still is.
--
-- Every marker on this map -- chips, rails, boats, labels -- is a Frame
-- positioned in Scale inside the container, so the markers glide and only the
-- terrain snaps. The owner's "railways and buildings seem to be moving at a
-- different rate than the map" (2026-09-14) is that disagreement seen from the
-- outside; nothing is wrong with where the markers are.
--
-- So below 1:1 the terrain is averaged instead of point-sampled: no dropped
-- tiles, no snapping, and coastlines and rivers stop flickering while the hand
-- moves. At 1:1 and above there is nothing to drop and Pixelated is what keeps
-- the map crisp rather than smeared, so it stays.
function Renderer.setResample(self: Renderer, zoom: number)
	local want = zoom >= 1
	if want == self.pixelated then
		return
	end
	self.pixelated = want
	local mode = want and Enum.ResamplerMode.Pixelated or Enum.ResamplerMode.Default
	for _, lbl in self.labels do
		lbl.ResampleMode = mode
	end
end

function Renderer.destroy(self: Renderer)
	for _, img in self.images do
		img:Destroy()
	end
	for _, lbl in self.labels do
		lbl:Destroy()
	end
	table.clear(self.images)
	table.clear(self.labels)
end

return Renderer
