--!strict
-- Conquest :: MapGen
-- Builds a real-world region from the run-length mask in one of the map
-- modules (see Maps), then synthesises elevation from projected mountain-range
-- polylines.
--
-- Still deterministic and still costs one integer on the wire: the client
-- rebuilds the identical terrain locally from the map id and seed. No
-- coastline varies by seed (they are real places), so each map's terrain is
-- cached the first time it is built and every later round on it is free.
--
-- Everything expensive runs on a COARSE grid and is bilinearly interpolated up.
-- Elevation is smooth by nature, so sampling it at 1/8 resolution costs 1/64
-- the work and is visually identical -- at 1.6M tiles the difference between
-- doing this and not is seconds per load.

local Config = require(script.Parent.Config)
local TileMap = require(script.Parent.TileMap)
local Maps = require(script.Parent.Maps)

local W = Config.MAP_W
local H = Config.MAP_H
local N = Config.NUM_TILES

local MapGen = {}

local COARSE = 8
local CW = math.ceil(W / COARSE) + 1
local CH = math.ceil(H / COARSE) + 1

local MAX_LAND_MAG = 30
local MAX_WATER_MAG = 26

-- ------------------------------------------------------------ mask decode --

local ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"
local DECODE = {}
for i = 1, #ALPHABET do
	DECODE[string.byte(ALPHABET, i)] = i - 1
end

-- Writes 1 for land into `mask`. Runs alternate starting with water.
local function decodeMask(mask: buffer, s: string)
	local len = #s
	local pos = 1
	local idx = 0
	local isLand = false

	while pos <= len do
		local v = 0
		local shift = 0
		while true do
			local d = DECODE[string.byte(s, pos)]
			pos += 1
			v += bit32.lshift(bit32.band(d, 31), shift)
			shift += 5
			if d < 32 then
				break
			end
		end
		if isLand then
			local stop = idx + v - 1
			for k = idx, stop do
				buffer.writeu8(mask, k, 1)
			end
		end
		idx += v
		isLand = not isLand
	end
end

-- ------------------------------------------------------------- elevation ---

local function fbm(x: number, y: number, seed: number, octaves: number): number
	local amp, freq, sum, norm = 1.0, 1.0, 0.0, 0.0
	for i = 1, octaves do
		sum += math.noise(x * freq, y * freq, seed + i * 19.73) * amp
		norm += amp
		amp *= 0.5
		freq *= 2.0
	end
	return sum / norm
end

-- Squared distance from (px,py) to segment (ax,ay)-(bx,by).
local function segDist2(px: number, py: number, ax: number, ay: number, bx: number, by: number): number
	local dx, dy = bx - ax, by - ay
	local len2 = dx * dx + dy * dy
	local t = 0
	if len2 > 0 then
		t = ((px - ax) * dx + (py - ay) * dy) / len2
		if t < 0 then
			t = 0
		elseif t > 1 then
			t = 1
		end
	end
	local cx, cy = ax + t * dx, ay + t * dy
	local ex, ey = px - cx, py - cy
	return ex * ex + ey * ey
end

-- ------------------------------------------------------------------ build --

local cache: { [string]: { terrain: buffer, land: number } } = {}

-- Elevation -> magnitude thresholds, picked as QUANTILES of the elevation the
-- map actually produced rather than from a fixed divisor.
--
-- The predecessor divided by a hand-tuned constant as if heights spanned a
-- known range. They do not: the peak depends entirely on how many ranges a
-- region has and how close together they run, and getting it wrong once cost
-- this project a US map with literally zero mountain tiles. With four maps of
-- wildly different relief a constant is not merely fragile, it cannot exist --
-- China's plateau and the Sahara do not share a scale.
--
-- Quantiles also make the terrain SPLIT identical everywhere, which is what
-- keeps one set of combat constants valid on every map: terrain magnitude
-- feeds attack cost and tick budget, so a map that came out 30% mountain
-- would silently play at half speed.
local function calibrate(coarseElev: buffer, coarseLand: buffer, count: number): (number, number, number, number)
	local vals = table.create(count)
	for i = 0, count - 1 do
		if buffer.readu8(coarseLand, i) == 1 then
			vals[#vals + 1] = buffer.readf32(coarseElev, i * 4)
		end
	end
	if #vals < 64 then
		return 0, 0.5, 1.0, 1.5
	end
	table.sort(vals)

	local n = #vals
	local function q(f: number): number
		return vals[math.clamp(math.floor(f * (n - 1)) + 1, 1, n)]
	end

	-- Defaulted: Config is edited by more than one author here, and a nil
	-- read would throw inside startRound -- taking down the whole round loop
	-- over a missing tuning constant. Seen live, once.
	local mountain = Config.TERRAIN_MOUNTAIN_FRACTION or 0.11
	local highland = Config.TERRAIN_HIGHLAND_FRACTION or 0.12
	local lo = q(0.002)
	local mid = q(1 - highland - mountain)
	local hi = q(1 - mountain)
	local top = q(0.999)

	-- A region with almost no relief would collapse these onto each other.
	mid = math.max(mid, lo + 1e-4)
	hi = math.max(hi, mid + 1e-4)
	top = math.max(top, hi + 1e-4)
	return lo, mid, hi, top
end

-- Returns terrain buffer, land tile count. `seed` is accepted for API symmetry
-- but every coastline is a real place, so the result is cached per map id.
function MapGen.generate(mapId: string, seed: number): (buffer, number)
	local hit = cache[mapId]
	if hit then
		return hit.terrain, hit.land
	end

	local mapData = Maps.get(mapId)
	assert(
		mapData.WIDTH == W and mapData.HEIGHT == H,
		mapId .. " resolution does not match Config"
	)

	local terrain = buffer.create(N)
	local mask = buffer.create(N)
	decodeMask(mask, mapData.MASK)

	-- --- coarse pass: ridge elevation, noise, and land/water flags
	local coarseElev = buffer.create(CW * CH * 4) -- f32
	local coarseLand = buffer.create(CW * CH)

	local ranges = mapData.RANGES
	local tilt = mapData.TILT
	for cy = 0, CH - 1 do
		local py = cy * COARSE
		for cx = 0, CW - 1 do
			local px = cx * COARSE
			local ci = cy * CW + cx

			local sx = px < W and px or W - 1
			local sy = py < H and py or H - 1
			buffer.writeu8(coarseLand, ci, buffer.readu8(mask, sy * W + sx))

			-- Ridge influence: gaussian falloff from each range's polyline.
			local e = 0.0
			for _, rng in ranges do
				local pts = rng.p
				local best = math.huge
				for i = 1, #pts - 3, 2 do
					local d2 = segDist2(px, py, pts[i], pts[i + 1], pts[i + 2], pts[i + 3])
					if d2 < best then
						best = d2
					end
				end
				local w = rng.w
				local q = best / (w * w)
				if q < 9 then
					e += rng.s * math.exp(-q)
				end
			end

			-- Optional continental tilt: a broad west-east ramp. This is what
			-- makes the US Great Plains rise toward the Rockies instead of
			-- lying flat right up to the foothills. Regions whose relief is
			-- fully described by their ranges leave TILT nil.
			local u = px / W
			if tilt then
				e += math.max(0, 1 - math.abs(u - tilt.center) / tilt.halfwidth) * tilt.amount
			end

			local detail = fbm(u * 7.0, (py / H) * 7.0, 17.0, 4) * 0.42
			buffer.writef32(coarseElev, ci * 4, e + detail)
		end
	end

	-- --- coarse pass 2: water depth as BFS distance from the coastline
	local depth = buffer.create(CW * CH * 2) -- u16, in coarse cells
	local queue = table.create(CW * CH)
	local qHead, qTail = 1, 0
	for i = 0, CW * CH - 1 do
		if buffer.readu8(coarseLand, i) == 1 then
			buffer.writeu16(depth, i * 2, 0)
			qTail += 1
			queue[qTail] = i
		else
			buffer.writeu16(depth, i * 2, 65535)
		end
	end
	while qHead <= qTail do
		local i = queue[qHead]
		qHead += 1
		local d = buffer.readu16(depth, i * 2) + 1
		local cx = i % CW
		local cy = (i - cx) / CW
		if cx > 0 then
			local n = i - 1
			if buffer.readu16(depth, n * 2) > d then
				buffer.writeu16(depth, n * 2, d); qTail += 1; queue[qTail] = n
			end
		end
		if cx < CW - 1 then
			local n = i + 1
			if buffer.readu16(depth, n * 2) > d then
				buffer.writeu16(depth, n * 2, d); qTail += 1; queue[qTail] = n
			end
		end
		if cy > 0 then
			local n = i - CW
			if buffer.readu16(depth, n * 2) > d then
				buffer.writeu16(depth, n * 2, d); qTail += 1; queue[qTail] = n
			end
		end
		if cy < CH - 1 then
			local n = i + CW
			if buffer.readu16(depth, n * 2) > d then
				buffer.writeu16(depth, n * 2, d); qTail += 1; queue[qTail] = n
			end
		end
	end

	-- --- calibrate the magnitude bands against this map's own elevation
	local eLo, eMid, eHi, eTop = calibrate(coarseElev, coarseLand, CW * CH)
	local invLow = 1 / (eMid - eLo)
	local invMid = 1 / (eHi - eMid)
	local invHigh = 1 / (eTop - eHi)

	-- --- full-res pass: interpolate and pack
	local landCount = 0
	local invC = 1 / COARSE
	for y = 0, H - 1 do
		local gy = y * invC
		local cy0 = math.floor(gy)
		local fy = gy - cy0
		local rowA = cy0 * CW
		local rowB = (cy0 + 1) * CW
		local base = y * W

		for x = 0, W - 1 do
			local i = base + x
			local b: number

			if buffer.readu8(mask, i) == 1 then
				local gx = x * invC
				local cx0 = math.floor(gx)
				local fx = gx - cx0

				local e00 = buffer.readf32(coarseElev, (rowA + cx0) * 4)
				local e10 = buffer.readf32(coarseElev, (rowA + cx0 + 1) * 4)
				local e01 = buffer.readf32(coarseElev, (rowB + cx0) * 4)
				local e11 = buffer.readf32(coarseElev, (rowB + cx0 + 1) * 4)
				local top = e00 + (e10 - e00) * fx
				local bot = e01 + (e11 - e01) * fx
				local e = top + (bot - top) * fy

				-- Piecewise-linear onto the magnitude range, with the two band
				-- edges landing exactly on TileMap's type boundaries
				-- (plains < 11 <= highland < 21 <= mountain). Peaks stay on
				-- ridges because the top band only opens above a quantile
				-- that, by construction, only ridges reach.
				local mag: number
				if e < eMid then
					mag = math.floor(math.clamp((e - eLo) * invLow, 0, 1) * 10.999)
				elseif e < eHi then
					mag = 11 + math.floor((e - eMid) * invMid * 9.999)
				else
					mag = 21 + math.floor(math.clamp((e - eHi) * invHigh, 0, 1) * 9.999)
				end
				if mag > MAX_LAND_MAG then
					mag = MAX_LAND_MAG
				end
				b = bit32.bor(mag, 128)
				landCount += 1
			else
				local gx = x * invC
				local cx0 = math.floor(gx)
				local d = buffer.readu16(depth, (rowA + cx0) * 2)
				if d == 65535 then
					d = 40
				end
				local mag = math.floor(d * 2.2)
				if mag > MAX_WATER_MAG then
					mag = MAX_WATER_MAG
				end
				b = mag
			end

			buffer.writeu8(terrain, i, b)
		end
	end

	-- --- shoreline flags
	for y = 0, H - 1 do
		local base = y * W
		for x = 0, W - 1 do
			local i = base + x
			local b = buffer.readu8(terrain, i)
			local land = bit32.btest(b, 128)
			local touches = false
			if y > 0 and bit32.btest(buffer.readu8(terrain, i - W), 128) ~= land then
				touches = true
			elseif y < H - 1 and bit32.btest(buffer.readu8(terrain, i + W), 128) ~= land then
				touches = true
			elseif x > 0 and bit32.btest(buffer.readu8(terrain, i - 1), 128) ~= land then
				touches = true
			elseif x < W - 1 and bit32.btest(buffer.readu8(terrain, i + 1), 128) ~= land then
				touches = true
			end
			if touches then
				buffer.writeu8(terrain, i, bit32.bor(b, 64))
			end
		end
	end

	cache[mapId] = { terrain = terrain, land = landCount }
	return terrain, landCount
end

-- ------------------------------------------------------------ roughness ---
-- A smooth "how hard is this ground to take" field. It is NOT terrain, is
-- never drawn, and never crosses the wire -- it exists only to shape the way
-- territory grows: it stretches the frontier delay in Sim.enqueue, so a front
-- bulges through soft country and drags through hard. See
-- Config.FRONTIER_ROUGH_SPREAD.
--
-- Unlike the coastline this DOES vary with the seed, so it is regenerated per
-- round (and cached within a round). Same coarse-grid-plus-bilinear trick as
-- elevation, and normalised against the range the field actually produced
-- rather than an assumed -1..1 -- math.noise does not fill its nominal range,
-- and assuming it does silently squashes the whole effect.

local ROUGH_COARSE = 8
local RCW = math.ceil(W / ROUGH_COARSE) + 1
local RCH = math.ceil(H / ROUGH_COARSE) + 1

local cachedRough: buffer? = nil
local cachedRoughSeed: number? = nil

-- Returns a full-resolution u8 buffer, 0 = softest ground, 255 = hardest.
function MapGen.roughness(seed: number): buffer
	if cachedRough and cachedRoughSeed == seed then
		return cachedRough
	end

	local freq = 1 / Config.FRONTIER_ROUGH_SCALE
	local coarse = buffer.create(RCW * RCH * 4) -- f32
	local lo, hi = math.huge, -math.huge

	for cy = 0, RCH - 1 do
		local ny = cy * ROUGH_COARSE * freq
		for cx = 0, RCW - 1 do
			local v = fbm(cx * ROUGH_COARSE * freq, ny, seed * 0.37 + 5.5, 3)
			buffer.writef32(coarse, (cy * RCW + cx) * 4, v)
			if v < lo then
				lo = v
			end
			if v > hi then
				hi = v
			end
		end
	end

	local span = hi - lo
	local norm = span > 1e-6 and 255 / span or 0

	local rough = buffer.create(N)
	local invC = 1 / ROUGH_COARSE
	for y = 0, H - 1 do
		local gy = y * invC
		local cy0 = math.floor(gy)
		local fy = gy - cy0
		local rowA = cy0 * RCW
		local rowB = (cy0 + 1) * RCW
		local base = y * W

		for x = 0, W - 1 do
			local gx = x * invC
			local cx0 = math.floor(gx)
			local fx = gx - cx0

			local v00 = buffer.readf32(coarse, (rowA + cx0) * 4)
			local v10 = buffer.readf32(coarse, (rowA + cx0 + 1) * 4)
			local v01 = buffer.readf32(coarse, (rowB + cx0) * 4)
			local v11 = buffer.readf32(coarse, (rowB + cx0 + 1) * 4)
			local top = v00 + (v10 - v00) * fx
			local bot = v01 + (v11 - v01) * fx

			local g = math.floor((top + (bot - top) * fy - lo) * norm)
			buffer.writeu8(rough, base + x, math.clamp(g, 0, 255))
		end
	end

	cachedRough = rough
	cachedRoughSeed = seed
	return rough
end

-- Flood-fills landmasses and keeps only those big enough to hold a game, so a
-- player cannot spawn on a coastal islet and be walled in (there are no boats).
-- Returns the spawnable tile list and the playable land count.
function MapGen.analyze(terrain: buffer, minLandmassSize: number): ({ number }, number)
	local visited = buffer.create(N)
	local candidates = {}
	local playable = 0

	local stack = table.create(8192)
	local component = table.create(8192)
	local margin = 8

	local function passable(i: number): boolean
		local b = buffer.readu8(terrain, i)
		return bit32.btest(b, 128) and bit32.band(b, 63) < 63
	end

	for start = 0, N - 1 do
		if buffer.readu8(visited, start) == 0 then
			if passable(start) then
				table.clear(stack)
				table.clear(component)
				buffer.writeu8(visited, start, 1)
				stack[1] = start
				local top = 1

				while top > 0 do
					local i = stack[top]
					top -= 1
					component[#component + 1] = i
					local x = i % W

					if i >= W then
						local n = i - W
						if buffer.readu8(visited, n) == 0 and passable(n) then
							buffer.writeu8(visited, n, 1); top += 1; stack[top] = n
						end
					end
					if i < N - W then
						local n = i + W
						if buffer.readu8(visited, n) == 0 and passable(n) then
							buffer.writeu8(visited, n, 1); top += 1; stack[top] = n
						end
					end
					if x ~= 0 then
						local n = i - 1
						if buffer.readu8(visited, n) == 0 and passable(n) then
							buffer.writeu8(visited, n, 1); top += 1; stack[top] = n
						end
					end
					if x ~= W - 1 then
						local n = i + 1
						if buffer.readu8(visited, n) == 0 and passable(n) then
							buffer.writeu8(visited, n, 1); top += 1; stack[top] = n
						end
					end
				end

				if #component >= minLandmassSize then
					playable += #component
					-- Sub-sample spawn candidates: at ~900k tiles a full list
					-- is pointless churn, and every 16th tile still leaves
					-- tens of thousands of choices.
					for k = 1, #component, 16 do
						local i = component[k]
						local x = i % W
						local y = (i - x) / W
						if x >= margin and x < W - margin and y >= margin and y < H - margin then
							candidates[#candidates + 1] = i
						end
					end
				end
			else
				buffer.writeu8(visited, start, 1)
			end
		end
	end

	return candidates, playable
end

return MapGen
