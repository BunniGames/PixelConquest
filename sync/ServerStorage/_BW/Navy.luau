--!strict
-- Conquest :: Navy
-- Water movement. Everything a transport ship needs to know about the sea:
-- which of it is connected to which, how to get from one coast to another,
-- and where a landing can legally happen.
--
-- WHY A COARSE GRAPH. A* over 1.6M tiles is a non-starter -- a single
-- ocean-crossing search would touch six figures of tiles and there are up to
-- 72 empires launching boats. The sea is also enormously redundant at tile
-- resolution: what actually constrains a route is the coastline, and a
-- coastline is resolved perfectly well at 8 tiles. So the search runs on a
-- 200x125 = 25,000-cell grid (1/64 the work), and the boat walks tile by tile
-- between the waypoints it returns.
--
-- A cell is navigable if ANY tile inside it is water. That is deliberate: a
-- majority rule would seal one-tile straits and river mouths, which are
-- exactly the places a naval game wants to be passable. The cost is that a
-- route may hug a coast more tightly than the coarse cell suggests, which the
-- per-tile stepping in Sim handles.

local Config = require(script.Parent.Config)
local TileMap = require(script.Parent.TileMap)

local W = Config.MAP_W
local H = Config.MAP_H

local S = Config.NAVY_GRID_STRIDE or 8
local GW = math.ceil(W / S)
local GH = math.ceil(H / S)
local GN = GW * GH

local Navy = {}

export type Nav = {
	-- 0 = no water in this cell, otherwise the tile index of a water tile
	-- inside it, used as the waypoint the boat steers for.
	rep: { number },
	-- Connected-component id per cell. Two coasts can only trade boats if
	-- they share one, so an unreachable target is rejected in O(1) instead of
	-- by an exhaustive search that fails -- which is the expensive case and,
	-- on a map with lakes, the common one.
	comp: { number },
	compCount: number,
}

-- Cached per map id. The land/water mask is data, not noise, so it does not
-- vary by seed -- only elevation does, and elevation has no say in what
-- floats. One build serves every round on that map.
local cache: { [string]: Nav } = {}

local function cellOf(tile: number): number
	local x = tile % W
	local y = (tile - x) / W
	return (y // S) * GW + (x // S)
end

Navy.cellOf = cellOf
Navy.GW = GW
Navy.GH = GH
Navy.STRIDE = S

-- ------------------------------------------------------------- build -------

function Navy.build(map: TileMap.TileMap, mapId: string): Nav
	local hit = cache[mapId]
	if hit then
		return hit
	end

	local terrain = map.terrain
	local rep = table.create(GN, 0)

	-- One pass over the map, writing each water tile into its cell. Keeping
	-- the FIRST water tile seen (scan order, so top-left-most) rather than a
	-- centroid matters: a centroid of a C-shaped bay can land on the beach.
	for tile = 0, W * H - 1 do
		if not TileMap.isLandByte(buffer.readu8(terrain, tile)) then
			local c = cellOf(tile)
			if rep[c + 1] == 0 then
				rep[c + 1] = tile + 1 -- +1 so 0 can mean "no water here"
			end
		end
	end

	-- Flood the cell grid into connected components, 8-connected so a
	-- diagonal strait is not a wall.
	local comp = table.create(GN, 0)
	local compCount = 0
	local stack = {}
	for start = 0, GN - 1 do
		if rep[start + 1] ~= 0 and comp[start + 1] == 0 then
			compCount += 1
			comp[start + 1] = compCount
			local n = 1
			stack[1] = start
			while n > 0 do
				local c = stack[n]
				n -= 1
				local cx = c % GW
				local cy = (c - cx) / GW
				for dy = -1, 1 do
					for dx = -1, 1 do
						local nx, ny = cx + dx, cy + dy
						if nx >= 0 and nx < GW and ny >= 0 and ny < GH then
							local nc = ny * GW + nx
							if rep[nc + 1] ~= 0 and comp[nc + 1] == 0 then
								comp[nc + 1] = compCount
								n += 1
								stack[n] = nc
							end
						end
					end
				end
			end
		end
	end

	local nav: Nav = { rep = rep, comp = comp, compCount = compCount }
	cache[mapId] = nav
	return nav
end

-- ------------------------------------------------------------ queries ------

-- The water cell a coastal tile launches from / arrives at. A shore tile is
-- land, so its own cell may hold no water at all; look at the 4-neighbours
-- first, then widen. Returns a cell index or nil.
function Navy.waterCellNear(nav: Nav, map: TileMap.TileMap, tile: number): number?
	local c = cellOf(tile)
	if nav.rep[c + 1] ~= 0 then
		return c
	end
	local cx = c % GW
	local cy = (c - cx) / GW
	for r = 1, 3 do
		for dy = -r, r do
			for dx = -r, r do
				if math.abs(dx) == r or math.abs(dy) == r then
					local nx, ny = cx + dx, cy + dy
					if nx >= 0 and nx < GW and ny >= 0 and ny < GH then
						local nc = ny * GW + nx
						if nav.rep[nc + 1] ~= 0 then
							return nc
						end
					end
				end
			end
		end
	end
	return nil
end

-- O(1) reachability. Called before any search, because the answer "no" is the
-- one that would otherwise cost a full exhausted A*.
function Navy.reachable(nav: Nav, map: TileMap.TileMap, fromTile: number, toTile: number): boolean
	local a = Navy.waterCellNear(nav, map, fromTile)
	local b = Navy.waterCellNear(nav, map, toTile)
	if a == nil or b == nil then
		return false
	end
	return nav.comp[a + 1] == nav.comp[b + 1] and nav.comp[a + 1] ~= 0
end

-- ---------------------------------------------------------------- path -----

local NEI8 = { -1, -1, -1, 0, -1, 1, 0, -1, 0, 1, 1, -1, 1, 0, 1, 1 }

-- A* over the coarse water grid. Returns waypoint TILE indices (the `rep`
-- tile of each cell on the route), or nil. Diagonal steps cost sqrt(2) so the
-- route does not come out as a staircase, and the heuristic is octile to
-- match -- a Euclidean heuristic against diagonal-costed moves is
-- inadmissible in the other direction and produces visibly silly detours.
function Navy.path(nav: Nav, map: TileMap.TileMap, fromTile: number, toTile: number): { number }?
	local startC = Navy.waterCellNear(nav, map, fromTile)
	local goalC = Navy.waterCellNear(nav, map, toTile)
	if startC == nil or goalC == nil then
		return nil
	end
	if nav.comp[startC + 1] ~= nav.comp[goalC + 1] then
		return nil
	end
	if startC == goalC then
		return { nav.rep[goalC + 1] - 1 }
	end

	local gx, gy = goalC % GW, (goalC - goalC % GW) / GW
	local function heur(c: number): number
		local cx, cy = c % GW, (c - c % GW) / GW
		local dx, dy = math.abs(cx - gx), math.abs(cy - gy)
		local lo = math.min(dx, dy)
		return (dx + dy) + (1.41421356 - 2) * lo
	end

	local gScore: { [number]: number } = { [startC] = 0 }
	local came: { [number]: number } = {}
	-- Binary heap keyed on f. Small enough (a route is a few hundred cells)
	-- that the array-of-pairs form beats anything cleverer.
	local heapC, heapF, hn = {}, {}, 0
	local function push(c: number, f: number)
		hn += 1
		heapC[hn], heapF[hn] = c, f
		local i = hn
		while i > 1 do
			local p = i // 2
			if heapF[p] <= heapF[i] then
				break
			end
			heapC[p], heapC[i] = heapC[i], heapC[p]
			heapF[p], heapF[i] = heapF[i], heapF[p]
			i = p
		end
	end
	local function pop(): number?
		if hn == 0 then
			return nil
		end
		local top = heapC[1]
		heapC[1], heapF[1] = heapC[hn], heapF[hn]
		hn -= 1
		local i = 1
		while true do
			local l, r, best = i * 2, i * 2 + 1, i
			if l <= hn and heapF[l] < heapF[best] then
				best = l
			end
			if r <= hn and heapF[r] < heapF[best] then
				best = r
			end
			if best == i then
				break
			end
			heapC[best], heapC[i] = heapC[i], heapC[best]
			heapF[best], heapF[i] = heapF[i], heapF[best]
			i = best
		end
		return top
	end

	push(startC, heur(startC))
	local expanded = 0
	local limit = Config.NAVY_SEARCH_LIMIT or 20000

	while true do
		local c = pop()
		if c == nil then
			return nil
		end
		if c == goalC then
			break
		end
		expanded += 1
		if expanded > limit then
			-- Bounded so one pathological route cannot own a tick. The
			-- component test above already rejected the genuinely impossible
			-- cases, so hitting this means a very long way round.
			return nil
		end
		local cg = gScore[c]
		local cx, cy = c % GW, (c - c % GW) / GW
		for k = 1, #NEI8, 2 do
			local dx, dy = NEI8[k], NEI8[k + 1]
			local nx, ny = cx + dx, cy + dy
			if nx >= 0 and nx < GW and ny >= 0 and ny < GH then
				local nc = ny * GW + nx
				if nav.rep[nc + 1] ~= 0 then
					local step = (dx ~= 0 and dy ~= 0) and 1.41421356 or 1
					local ng = cg + step
					local old = gScore[nc]
					if old == nil or ng < old then
						gScore[nc] = ng
						came[nc] = c
						push(nc, ng + heur(nc))
					end
				end
			end
		end
	end

	local out = {}
	local c = goalC
	while c ~= startC do
		table.insert(out, 1, nav.rep[c + 1] - 1)
		c = came[c]
	end
	return out
end

-- ------------------------------------------------------------- landing -----

-- Is this land tile one a boat can unload onto -- i.e. does it touch water?
function Navy.isLandable(map: TileMap.TileMap, tile: number, nbuf: { number }): boolean
	if not TileMap.isPassable(map, tile) then
		return false
	end
	local n = TileMap.neighbors4(tile, nbuf)
	for k = 1, n do
		if not TileMap.isLand(map, nbuf[k]) then
			return true
		end
	end
	return false
end

-- The tile a landing aimed at `targetTile` actually happens on: the nearest
-- coastal tile with the SAME OWNER as what was aimed at. Spiralling outward
-- from the tap rather than demanding the exact tile is what makes tapping a
-- country's interior work -- a player aims at a nation, not at a beach.
function Navy.landingTile(
	map: TileMap.TileMap,
	targetTile: number,
	nbuf: { number },
	maxRadius: number?
): number?
	local owner = map.owner
	local want = buffer.readu8(owner, targetTile)
	local tx = targetTile % W
	local ty = (targetTile - tx) / W
	local R = maxRadius or (Config.NAVY_LANDING_SEARCH or 60)
	if Navy.isLandable(map, targetTile, nbuf) and buffer.readu8(owner, targetTile) == want then
		return targetTile
	end
	for r = 1, R do
		for dy = -r, r do
			for dx = -r, r do
				if math.abs(dx) == r or math.abs(dy) == r then
					local x, y = tx + dx, ty + dy
					if x >= 0 and x < W and y >= 0 and y < H then
						local t = y * W + x
						if buffer.readu8(owner, t) == want and Navy.isLandable(map, t, nbuf) then
							return t
						end
					end
				end
			end
		end
	end
	return nil
end

-- Where the boat sails FROM: the embarking empire's own coast, closest to the
-- landing site. Walks the player's border set, which is already maintained,
-- and caps the walk -- a late-game border is tens of thousands of tiles and
-- this runs on a button press, not a tick.
function Navy.spawnTile(
	map: TileMap.TileMap,
	border: { [number]: true },
	dstTile: number,
	nbuf: { number },
	scanCap: number?
): number?
	local dx0 = dstTile % W
	local dy0 = (dstTile - dx0) / W
	local best: number? = nil
	local bestD = math.huge
	local scanned = 0
	local cap = scanCap or (Config.NAVY_SPAWN_SCAN or 6000)
	for tile in border do
		scanned += 1
		if scanned > cap then
			break
		end
		if Navy.isLandable(map, tile, nbuf) then
			local x = tile % W
			local y = (tile - x) / W
			local d = (x - dx0) * (x - dx0) + (y - dy0) * (y - dy0)
			if d < bestD then
				bestD = d
				best = tile
			end
		end
	end
	return best
end

return Navy
