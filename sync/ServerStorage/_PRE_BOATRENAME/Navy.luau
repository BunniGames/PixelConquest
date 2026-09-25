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
--
-- RIVERS CHANGED WHAT THIS GRID IS. Before them the water was one sea with a
-- few lakes, cells holding water were a coastal fringe, and "the water near
-- this tile" was unambiguous. Now 41-79% of every map's cells hold some water,
-- a tile can sit between two bodies that never meet, and the sea is 6 to 29
-- components rather than 1. Every query below therefore works on a SET of
-- nearby cells and picks the body both ends SHARE, instead of taking the
-- nearest cell at each end and testing afterwards that they happen to match.
--
-- The other consequence is measured rather than argued. Simulating the walk a
-- boat actually makes, over 300-400 random coast-to-coast routes per map:
--
--                       stride 8   stride 6   stride 4
--   pre-river             13-18%        --      6-11%
--   with rivers           27-39%     20-31%    12-22%
--   with rivers + hug     14-19%     9-13%         --
--
-- (percent of the boat's steps that land on LAND. The coarse grid cuts
-- corners by design and Sim.stepBoats knowingly allows it, but a chain of
-- cells each clipping a DIFFERENT river reads as navigable end to end, which
-- is how rivers doubled it.) "hug" is Sim.stepBoats preferring a 45-degrees-off
-- step that is water. It costs three tile reads and recovers the whole
-- regression, so THE STRIDE DID NOT HAVE TO CHANGE: shipped at 8 with hug.
-- A finer grid was measured and rejected on the tail, not on the mean -- a
-- full europe match came out at the same length either way, with the worst
-- tick at 88.7 ms on stride 8 and 121.8 ms on stride 6 against a 100 ms
-- budget. At 1 route search a tick, this search IS that tail.
--
-- WHAT FINALLY FIXED IT WAS NOT A FINER GRID BUT A SECOND SEARCH. Navy.channel
-- runs a tile-level A* over water alone between two consecutive waypoints, in
-- a window a few tiles wider than the leg. The coarse grid keeps doing what it
-- is good at -- deciding which way round a continent, over 25,000 cells
-- instead of half a million tiles -- and the fine search decides which water,
-- which is the only question a river ever asks. Boats and trade ships both
-- steer by it now; hug survives as the fallback for a leg the window cannot
-- solve.

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

	-- One pass over the map, keeping in each cell the water tile NEAREST ITS
	-- CENTRE. Not a centroid -- a centroid of a C-shaped bay lands on the
	-- beach, which is why this used to keep the first water tile in scan
	-- order instead. But first-in-scan-order is the cell's TOP-LEFT-most
	-- water, and an anchor in the corner of every cell is what made an open
	-- crossing zig-zag and a river route aim alternately at either bank.
	-- Nearest-to-centre keeps the guarantee that matters -- the anchor is a
	-- real water tile someone can float on -- and puts it in the middle of
	-- the channel, which is where Navy.channel then has to join them up.
	local anchorD = table.create(GN, 0)
	local HALF = (S - 1) / 2
	for tile = 0, W * H - 1 do
		if not TileMap.isLandByte(buffer.readu8(terrain, tile)) then
			local x = tile % W
			local y = (tile - x) / W
			local cx = x // S
			local cy = y // S
			local c = cy * GW + cx
			local ax = x - (cx * S + HALF)
			local ay = y - (cy * S + HALF)
			local d = ax * ax + ay * ay
			if rep[c + 1] == 0 or d < anchorD[c + 1] then
				rep[c + 1] = tile + 1 -- +1 so 0 can mean "no water here"
				anchorD[c + 1] = d
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

local SEARCH_R = 3

-- Every navigable cell within SEARCH_R cells of this tile's own, nearest ring
-- first, as a map of cell -> ring. Rivers are why this is a SET and not the
-- one nearest cell it used to be: a tile on the Rhine two cells from the North
-- Sea sits beside two different bodies of water, and answering "which water is
-- this tile on" with whichever the spiral saw first refuses half the crossings
-- an empire on a river mouth can really make.
local function cellsNear(nav: Nav, tile: number, out: { [number]: number }): boolean
	table.clear(out)
	local any = false
	local c = cellOf(tile)
	if nav.rep[c + 1] ~= 0 then
		out[c] = 0
		any = true
	end
	local cx = c % GW
	local cy = (c - cx) / GW
	for r = 1, SEARCH_R do
		for dy = -r, r do
			for dx = -r, r do
				if math.abs(dx) == r or math.abs(dy) == r then
					local nx, ny = cx + dx, cy + dy
					if nx >= 0 and nx < GW and ny >= 0 and ny < GH then
						local nc = ny * GW + nx
						if nav.rep[nc + 1] ~= 0 and out[nc] == nil then
							out[nc] = r
							any = true
						end
					end
				end
			end
		end
	end
	return any
end

-- Scratch, because these run per boat launch and per candidate embark tile.
-- Never held across a call.
local nearA: { [number]: number } = {}
local nearB: { [number]: number } = {}

-- The water bodies a tile touches, as comp -> distance in cells.
function Navy.compsNear(nav: Nav, tile: number, out: { [number]: number }): { [number]: number }
	table.clear(out)
	cellsNear(nav, tile, nearA)
	for cell, r in nearA do
		local comp = nav.comp[cell + 1]
		if comp ~= 0 and (out[comp] == nil or r < out[comp]) then
			out[comp] = r
		end
	end
	return out
end

-- The water cell nearest `tile` that belongs to `comp`. This is what makes a
-- route start on the RIGHT water: the cell nearest the tile may be a river
-- the route has nothing to do with.
function Navy.cellInComp(nav: Nav, tile: number, comp: number): number?
	cellsNear(nav, tile, nearA)
	local best, bestR = nil, math.huge
	for cell, r in nearA do
		if nav.comp[cell + 1] == comp and r < bestR then
			best, bestR = cell, r
		end
	end
	return best
end

-- The nearest water body this tile touches that is also in `comps`, or nil.
function Navy.compIn(nav: Nav, tile: number, comps: { [number]: number }): number?
	cellsNear(nav, tile, nearA)
	local pick, pickR = nil, math.huge
	for cell, r in nearA do
		local comp = nav.comp[cell + 1]
		if comp ~= 0 and comps[comp] ~= nil and r < pickR then
			pick, pickR = comp, r
		end
	end
	return pick
end

-- The water body both tiles touch, or nil. Ties break on total distance, so a
-- crossing uses the water actually between the two banks rather than an ocean
-- both of them happen to be three cells away from.
function Navy.sharedComp(nav: Nav, fromTile: number, toTile: number): number?
	local a = Navy.compsNear(nav, fromTile, nearB)
	local pick, pickD = nil, math.huge
	cellsNear(nav, toTile, nearA)
	for cell, r in nearA do
		local comp = nav.comp[cell + 1]
		local da = a[comp]
		if da ~= nil and da + r < pickD then
			pick, pickD = comp, da + r
		end
	end
	return pick
end

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
	for r = 1, SEARCH_R do
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
	return Navy.sharedComp(nav, fromTile, toTile) ~= nil
end

-- ---------------------------------------------------------------- path -----

local NEI8 = { -1, -1, -1, 0, -1, 1, 0, -1, 0, 1, 1, -1, 1, 0, 1, 1 }

-- A* over the coarse water grid. Returns waypoint TILE indices (the `rep`
-- tile of each cell on the route), or nil. Diagonal steps cost sqrt(2) so the
-- route does not come out as a staircase, and the heuristic is octile to
-- match -- a Euclidean heuristic against diagonal-costed moves is
-- inadmissible in the other direction and produces visibly silly detours.
function Navy.path(nav: Nav, map: TileMap.TileMap, fromTile: number, toTile: number): { number }?
	-- Choose the WATER BODY first and the cells second. Taking the nearest
	-- cell at each end independently and then testing that they match is the
	-- same thing only on a map with one sea; with rivers the two ends can each
	-- pick a different body and a perfectly ordinary crossing comes back
	-- impossible.
	local comp = Navy.sharedComp(nav, fromTile, toTile)
	if comp == nil then
		return nil
	end
	local startC = Navy.cellInComp(nav, fromTile, comp)
	local goalC = Navy.cellInComp(nav, toTile, comp)
	if startC == nil or goalC == nil then
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

-- ------------------------------------------------------------- channel -----

-- How far outside the box its two ends span the fine search may look. One
-- leg is a single coarse cell long, so this is sized for the case that
-- actually costs something: a river that bends out of that box and back.
local CHANNEL_PAD = 10
-- Expansions, not tiles. The window already bounds how much map this can see;
-- this bounds the work inside a window that is mostly water.
local CHANNEL_CAP = 1200

local chG: { [number]: number } = {}
local chCame: { [number]: number } = {}
local chHeapT: { number } = {}
local chHeapF: { number } = {}

-- Cells expanded by the last channel search, so a caller running SEVERAL of
-- them in one tick can spend a budget rather than a count. Economy refines a
-- whole ocean lane in one go and the legs vary by two orders of magnitude:
-- counting legs would ration the cheap ones and let a single expensive one
-- own the tick.
Navy.lastExpanded = 0

-- The tile-by-tile route between two waypoints: 8-connected A* over WATER
-- ONLY, inside the box the two tiles span padded by CHANNEL_PAD.
--
-- THIS IS THE MISSING HALF OF THE COARSE SEARCH. A cell counts as navigable
-- when a single tile inside it is wet, so a coarse route only ever promised
-- that water is NEAR the line between two waypoints -- and a ship steering
-- straight at the next waypoint therefore clips headlands, and up a river it
-- sails over the fields beside it. The coarse search says which way round the
-- continent; this says which water.
--
-- Bounded twice, because it runs inside the tick: the window caps how much
-- map it can see, `cap` caps the expansions inside it. Both failures return
-- nil, and every caller falls back to steering straight at the waypoint --
-- which is exactly what the whole game did before this existed. A caller that
-- only pays once per lane rather than once per tick can afford to widen both
-- and ask again, which is what Economy does with the legs that fail.
--
-- `landCost` opens a PORTAGE: land becomes passable at that multiple of a
-- water step instead of being a wall. It exists because the coarse grid is
-- deliberately permissive -- a cell is navigable if any tile in it is wet, so
-- a route can be laid across a one-tile land bridge at Dover or a river that
-- does not reach the sea, and refusing those crossings outright would take
-- away half the naval game these maps are drawn for. What a portage buys is
-- that the crossing is as SHORT as the map allows: the hull sails to the
-- narrowest point and steps over, instead of drawing a straight line across
-- twenty-five tiles of countryside.
function Navy.channel(
	map: TileMap.TileMap,
	fromTile: number,
	toTile: number,
	cap: number?,
	pad: number?,
	landCost: number?
): { number }?
	if fromTile == toTile then
		Navy.lastExpanded = 0
		return nil
	end
	local p = pad or CHANNEL_PAD
	local sx = fromTile % W
	local sy = (fromTile - sx) / W
	local gx = toTile % W
	local gy = (toTile - gx) / W
	local x0 = math.max(0, math.min(sx, gx) - p)
	local x1 = math.min(W - 1, math.max(sx, gx) + p)
	local y0 = math.max(0, math.min(sy, gy) - p)
	local y1 = math.min(H - 1, math.max(sy, gy) + p)

	local g, came = chG, chCame
	table.clear(g)
	table.clear(came)
	local heapT, heapF = chHeapT, chHeapF
	local hn = 0

	local function push(t: number, f: number)
		hn += 1
		heapT[hn], heapF[hn] = t, f
		local i = hn
		while i > 1 do
			local p = i // 2
			if heapF[p] <= heapF[i] then
				break
			end
			heapT[p], heapT[i] = heapT[i], heapT[p]
			heapF[p], heapF[i] = heapF[i], heapF[p]
			i = p
		end
	end
	local function pop(): number?
		if hn == 0 then
			return nil
		end
		local top = heapT[1]
		heapT[1], heapF[1] = heapT[hn], heapF[hn]
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
			heapT[best], heapT[i] = heapT[i], heapT[best]
			heapF[best], heapF[i] = heapF[i], heapF[best]
			i = best
		end
		return top
	end

	-- Octile, to match the sqrt(2) diagonals below.
	local function heur(x: number, y: number): number
		local dx, dy = math.abs(x - gx), math.abs(y - gy)
		local lo = math.min(dx, dy)
		return (dx + dy) + (1.41421356 - 2) * lo
	end

	g[fromTile] = 0
	push(fromTile, heur(sx, sy))
	local expanded = 0
	local limit = cap or CHANNEL_CAP
	local found = false

	while true do
		local cur = pop()
		if cur == nil then
			break
		end
		if cur == toTile then
			found = true
			break
		end
		expanded += 1
		if expanded > limit then
			break
		end
		local cg = g[cur]
		local cx = cur % W
		local cy = (cur - cx) / W
		for k = 1, #NEI8, 2 do
			local dx, dy = NEI8[k], NEI8[k + 1]
			local nx, ny = cx + dx, cy + dy
			if nx >= x0 and nx <= x1 and ny >= y0 and ny <= y1 then
				local nt = ny * W + nx
				local onLand = TileMap.isLand(map, nt)
				-- The GOAL is always enterable whether or not it floats: on a
				-- landing the last thing a boat aims at is the beach itself.
				if nt == toTile or not onLand or landCost ~= nil then
					local ok = true
					if dx ~= 0 and dy ~= 0 and landCost == nil then
						-- NO CORNER CUTTING. Two land tiles meeting at a
						-- point are a spit, and a hull that slides through
						-- the join reads as sailing through the land -- which
						-- is the whole thing this function exists to stop.
						ok = not TileMap.isLand(map, cy * W + nx)
							or not TileMap.isLand(map, ny * W + cx)
					end
					if ok then
						local step = (dx ~= 0 and dy ~= 0) and 1.41421356 or 1
						if onLand and landCost ~= nil and nt ~= toTile then
							step *= landCost
						end
						local ng = cg + step
						local old = g[nt]
						if old == nil or ng < old then
							g[nt] = ng
							came[nt] = cur
							push(nt, ng + heur(nx, ny))
						end
					end
				end
			end
		end
	end

	Navy.lastExpanded = expanded
	if not found then
		return nil
	end
	-- Start EXCLUSIVE: the caller is standing on it. Built back to front and
	-- reversed rather than table.insert(out, 1, ...) -- a leg is short, but
	-- Economy refines a whole ocean crossing one leg at a time.
	local rev: { number } = {}
	local c = toTile
	while c ~= fromTile do
		rev[#rev + 1] = c
		c = came[c]
	end
	local out: { number } = {}
	for i = #rev, 1, -1 do
		out[#out + 1] = rev[i]
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
	-- WALK THE RING, NOT THE SQUARE. This loop used to run dy and dx over the
	-- whole (2r+1)^2 block at every radius and keep only the tiles that landed
	-- ON the ring, which makes the spiral O(R^3) instead of O(R^2). At the
	-- default R = 60 that is 288,000 positions visited where 14,641 will do,
	-- and a call that finds nothing pays all of it: measured at 295 ms in one
	-- tick, the second-worst tick of a 30-minute match.
	--
	-- The visit ORDER is deliberately identical to the old one -- top row left
	-- to right, then each middle row's left and right cell, then the bottom
	-- row -- so the tile this returns does not change. It is the same search,
	-- with the 4/5ths of it that could never match no longer walked.
	local function hit(x: number, y: number): number?
		if x < 0 or x >= W or y < 0 or y >= H then
			return nil
		end
		local t = y * W + x
		if buffer.readu8(owner, t) == want and Navy.isLandable(map, t, nbuf) then
			return t
		end
		return nil
	end

	for r = 1, R do
		for dy = -r, r do
			local y = ty + dy
			if dy == -r or dy == r then
				for x = tx - r, tx + r do
					local t = hit(x, y)
					if t ~= nil then
						return t
					end
				end
			else
				local t = hit(tx - r, y)
				if t ~= nil then
					return t
				end
				t = hit(tx + r, y)
				if t ~= nil then
					return t
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
--
-- `nav` + `comp` restrict it to coast on ONE body of water, and passing them is
-- not optional in practice. Since rivers, "touches water" no longer means
-- "touches the sea": an empire holding both a stretch of the Rhine and a
-- stretch of the North Sea coast would embark from whichever bank happened to
-- be geometrically nearest, and a landing across the Channel launched from a
-- river three hundred miles inland is refused as unreachable. Choosing the
-- destination's own water first turns that into a slightly longer sail.
function Navy.spawnTile(
	map: TileMap.TileMap,
	border: { [number]: true },
	dstTile: number,
	nbuf: { number },
	scanCap: number?,
	nav: Nav?,
	comps: { [number]: number }?
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
		-- DISTANCE FIRST, then landability, then water body -- cheapest test
		-- to dearest, and every one of them only paid for a tile that is
		-- already winning. The comment below was right about the component
		-- spiral and the same argument applies one step earlier: isLandable
		-- reads the tile and all four of its neighbours, and running it on
		-- every one of the 6,000 scanned border tiles rather than only on the
		-- handful that beat the best distance so far was the whole cost of
		-- this function -- 235 ms in a single tick on Venice, whose empires
		-- are all coast.
		--
		-- Exactly equivalent, not an approximation: the winner has to satisfy
		-- all three predicates and be the nearest, so testing them in any
		-- order over the same candidate set selects the same tile.
		local x = tile % W
		local y = (tile - x) / W
		local d = (x - dx0) * (x - dx0) + (y - dy0) * (y - dy0)
		if d < bestD and Navy.isLandable(map, tile, nbuf) then
			-- The component test costs a spiral over the cell grid, so it is
			-- only worth paying for a tile that would actually win.
			if nav == nil or comps == nil or Navy.compIn(nav, tile, comps) ~= nil then
				bestD = d
				best = tile
			end
		end
	end
	return best
end

return Navy
