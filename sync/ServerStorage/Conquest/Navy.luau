--!strict
-- Conquest :: Navy
-- Water movement. Everything a transport boat needs to know about the sea:
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
-- corners by design and Sim.stepTransportBoats knowingly allows it, but a chain of
-- cells each clipping a DIFFERENT river reads as navigable end to end, which
-- is how rivers doubled it.) "hug" is Sim.stepTransportBoats preferring a 45-degrees-off
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
-- which is the only question a river ever asks. Transport boats and trading boats both
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
	--
	-- MEASURED ON TILES, NOT ON CELLS (2026-09-03). It used to be a flood of
	-- the CELL grid, and a cell counts as navigable when a single tile in it is
	-- wet -- so two cells that share nothing but a beach came out in the same
	-- component, and a chain of cells each clipping a DIFFERENT river read as
	-- one navigable sea. That is what made a coarse route cross dry land in the
	-- first place, and no amount of work downstream can undo it: the fine
	-- search is asked for a water route between two waypoints that no water
	-- joins. Now a component is a 4-connected body of WATER TILES and a cell
	-- takes the component of its own anchor, so `sharedComp` answering yes
	-- means a hull can really float from one to the other.
	comp: { number },
	compCount: number,
	-- Water tiles inside each cell, 0..S*S. A cell counts as navigable when a
	-- single tile in it is wet, which is what keeps one-tile straits open --
	-- and it is also why a coarse route will happily run along a coastline
	-- through cells that are nine tenths beach. This is what lets the search
	-- prefer the open sea without forbidding the strait.
	wet: { number },
	-- EVERY BODY OF WATER INSIDE EACH CELL, as a flat list of four values per
	-- body: {comp, anchor, d2, link}. `comp` above is only the body the cell's
	-- own anchor sits in, which is a different question -- a cell where a river
	-- runs three tiles from the sea holds both.
	--
	-- `link` is which way out of this cell THIS BODY can float, as a bitmask of
	-- NORTH 1 / SOUTH 2 / WEST 4 / EAST 8, set when one of its tiles is
	-- 4-adjacent to a water tile in the neighbouring cell. Per body and not per
	-- cell, and that distinction is the last of the overland sailing: a cell
	-- holding a river and a sea has an exit bit for each, and a coarse route
	-- reading the cell as a whole would enter on the sea and leave up the
	-- river. The two are not joined, so no fine search can serve the leg it
	-- just laid, and a trading boat crossed twenty tiles of France.
	--
	-- Linked water is by construction the SAME component on both sides, so a
	-- coarse step never changes body: a route lives in one comp from end to
	-- end, which is what makes `sharedComp` answering yes a promise.
	bodies: { { number } },
	-- Water component per TILE (0 = land). The source of truth the rest of this
	-- is derived from; kept so a caller can ask about a tile rather than a cell.
	tcomp: buffer,
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

-- 4-connected components of the WATER, as an i32 per tile (0 = land). This is
-- the connectivity a rook-stepping hull actually has, and everything above
-- reads it: the coarse graph, the reachability test, and which anchor a route
-- steers for. Iterative, with an explicit stack, because an ocean is a quarter
-- of a million tiles and recursion is not an option.
local function floodWater(terrain: buffer): (buffer, number)
	local tcomp = buffer.create(W * H * 4)
	local count = 0
	local stack = table.create(4096)
	for start = 0, W * H - 1 do
		if buffer.readi32(tcomp, start * 4) == 0
			and not TileMap.isLandByte(buffer.readu8(terrain, start))
		then
			count += 1
			buffer.writei32(tcomp, start * 4, count)
			local n = 1
			stack[1] = start
			while n > 0 do
				local t = stack[n]
				n -= 1
				local x = t % W
				for k = 1, 4 do
					local nb = -1
					if k == 1 then
						nb = t >= W and t - W or -1
					elseif k == 2 then
						nb = t < W * H - W and t + W or -1
					elseif k == 3 then
						nb = x ~= 0 and t - 1 or -1
					else
						nb = x ~= W - 1 and t + 1 or -1
					end
					if nb >= 0 and buffer.readi32(tcomp, nb * 4) == 0
						and not TileMap.isLandByte(buffer.readu8(terrain, nb))
					then
						buffer.writei32(tcomp, nb * 4, count)
						n += 1
						stack[n] = nb
					end
				end
			end
		end
	end
	return tcomp, count
end

function Navy.build(map: TileMap.TileMap, mapId: string): Nav
	local hit = cache[mapId]
	if hit then
		return hit
	end

	local terrain = map.terrain
	local tcomp, compCount = floodWater(terrain)

	local rep = table.create(GN, 0)
	local comp = table.create(GN, 0)
	local wet = table.create(GN, 0)
	local bodies: { { number } } = table.create(GN)

	-- comp -> its slot in a cell's `bodies` list, so the second pass can find
	-- the entry to set a link bit on without rescanning it.
	local function slotOf(c: number, k: number): number?
		local list = bodies[c + 1]
		if list == nil then
			return nil
		end
		for j = 1, #list, 4 do
			if list[j] == k then
				return j
			end
		end
		return nil
	end

	-- One pass over the map doing four things at once.
	--
	-- The ANCHOR of a cell is the water tile NEAREST ITS CENTRE. Not a centroid
	-- -- a centroid of a C-shaped bay lands on the beach, which is why this
	-- used to keep the first water tile in scan order instead. But
	-- first-in-scan-order is the cell's TOP-LEFT-most water, and an anchor in
	-- the corner of every cell is what made an open crossing zig-zag and a
	-- river route aim alternately at either bank. Nearest-to-centre keeps the
	-- guarantee that matters -- the anchor is a real water tile someone can
	-- float on -- and puts it in the middle of the channel, which is where
	-- Navy.channel then has to join them up.
	--
	-- A CELL CAN HOLD MORE THAN ONE BODY OF WATER, and pretending otherwise is
	-- what broke the first version of the tile-level components: a cell where
	-- the Rhone runs three tiles from the Mediterranean has an anchor in one of
	-- them, so asking "which water does this coast touch" through the cell
	-- answered with the river and a perfectly ordinary crossing came back
	-- unreachable. `bodies` therefore holds a flat {comp, anchor, comp, anchor}
	-- list per cell -- one entry on almost every cell, two where it matters.
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
			wet[c + 1] += 1
			if rep[c + 1] == 0 or d < anchorD[c + 1] then
				rep[c + 1] = tile + 1 -- +1 so 0 can mean "no water here"
				anchorD[c + 1] = d
			end

			local k = buffer.readi32(tcomp, tile * 4)
			local list = bodies[c + 1]
			if list == nil then
				bodies[c + 1] = { k, tile, d, 0 }
			else
				local found = false
				for j = 1, #list, 4 do
					if list[j] == k then
						found = true
						if d < list[j + 2] then
							list[j + 1] = tile
							list[j + 2] = d
						end
						break
					end
				end
				if not found then
					list[#list + 1] = k
					list[#list + 1] = tile
					list[#list + 1] = d
					list[#list + 1] = 0
				end
			end
		end
	end

	-- WHICH WAY OUT OF EACH CELL EACH BODY CAN FLOAT. A second pass, because
	-- the first one has to have finished creating every cell's body list before
	-- a bit can be written on the far side of a boundary. Only the east and
	-- south edges are examined, with the mirrored bit set on the neighbour, so
	-- every boundary is looked at exactly once.
	for tile = 0, W * H - 1 do
		if not TileMap.isLandByte(buffer.readu8(terrain, tile)) then
			local x = tile % W
			local y = (tile - x) / W
			local c = (y // S) * GW + (x // S)
			local k = buffer.readi32(tcomp, tile * 4)
			if x % S == S - 1 and x + 1 < W
				and not TileMap.isLandByte(buffer.readu8(terrain, tile + 1))
			then
				local a, b = slotOf(c, k), slotOf(c + 1, k)
				if a ~= nil then
					bodies[c + 1][a + 3] = bit32.bor(bodies[c + 1][a + 3], 8)
				end
				if b ~= nil then
					bodies[c + 2][b + 3] = bit32.bor(bodies[c + 2][b + 3], 4)
				end
			end
			if y % S == S - 1 and y + 1 < H
				and not TileMap.isLandByte(buffer.readu8(terrain, tile + W))
			then
				local a, b = slotOf(c, k), slotOf(c + GW, k)
				if a ~= nil then
					bodies[c + 1][a + 3] = bit32.bor(bodies[c + 1][a + 3], 2)
				end
				if b ~= nil then
					bodies[c + GW + 1][b + 3] = bit32.bor(bodies[c + GW + 1][b + 3], 1)
				end
			end
		end
	end

	for c = 0, GN - 1 do
		local r = rep[c + 1]
		if r ~= 0 then
			comp[c + 1] = buffer.readi32(tcomp, (r - 1) * 4)
		end
	end

	local nav: Nav = {
		rep = rep, comp = comp, compCount = compCount, wet = wet,
		bodies = bodies, tcomp = tcomp,
	}
	cache[mapId] = nav
	return nav
end

-- The water tile in `cell` belonging to `comp` that is nearest the cell's
-- centre, or nil. This is the waypoint a route through that cell steers for:
-- `rep` is the nearest water of ANY body, which on a river mouth is the wrong
-- one.
function Navy.anchorIn(nav: Nav, cell: number, comp: number): number?
	local list = nav.bodies[cell + 1]
	if list == nil then
		return nil
	end
	for j = 1, #list, 4 do
		if list[j] == comp then
			return list[j + 1]
		end
	end
	return nil
end

-- The body two CELLS have in common, or nil. Economy reaches the coarse graph
-- through cells rather than tiles (a port's cell is found once and cached), and
-- a coarse route belongs to exactly one body, so this is where it picks which.
-- Ties break on the fuller cell, i.e. the sea rather than the river through it.
function Navy.sharedCellComp(nav: Nav, a: number, b: number): number?
	local la = nav.bodies[a + 1]
	local lb = nav.bodies[b + 1]
	if la == nil or lb == nil then
		return nil
	end
	local pick, pickD = nil, math.huge
	local primary = nav.comp[a + 1]
	for i = 1, #la, 4 do
		for j = 1, #lb, 4 do
			if la[i] == lb[j] then
				-- Break ties on the body whose anchor sits nearest the cell's
				-- centre, which is the cell's dominant water: a river clipping
				-- the corner of a port's cell loses to the sea it opens onto.
				local d = la[i] == primary and -1 or la[i + 2]
				if d < pickD then
					pick, pickD = la[i], d
				end
			end
		end
	end
	return pick
end

-- Which way out of `cell` this body can float, as the NSWE bitmask. 0 when the
-- cell holds none of it.
function Navy.linkIn(nav: Nav, cell: number, comp: number): number
	local list = nav.bodies[cell + 1]
	if list == nil then
		return 0
	end
	for j = 1, #list, 4 do
		if list[j] == comp then
			return list[j + 3]
		end
	end
	return 0
end

-- Can a hull step from cell `c` to the cell `dx,dy` away without crossing dry
-- land? A straight step reads one bit. A DIAGONAL is allowed only when one of
-- its two L-shaped detours is open, which is the same answer for a boat that
-- moves one axis at a time -- and it is what stops a coarse route cutting
-- through the point where two headlands meet.
local N_BIT, S_BIT, W_BIT, E_BIT = 1, 2, 4, 8

local function bitFor(dx: number, dy: number): number
	if dx > 0 then
		return E_BIT
	elseif dx < 0 then
		return W_BIT
	elseif dy > 0 then
		return S_BIT
	end
	return N_BIT
end

function Navy.canStep(nav: Nav, c: number, comp: number, dx: number, dy: number): boolean
	local here = Navy.linkIn(nav, c, comp)
	if dx == 0 or dy == 0 then
		return bit32.btest(here, bitFor(dx, dy))
	end
	if bit32.btest(here, bitFor(dx, 0))
		and bit32.btest(Navy.linkIn(nav, c + dx, comp), bitFor(0, dy))
	then
		return true
	end
	return bit32.btest(here, bitFor(0, dy))
		and bit32.btest(Navy.linkIn(nav, c + dy * GW, comp), bitFor(dx, 0))
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

-- Scratch, because these run per transport-boat launch and per candidate embark tile.
-- Never held across a call.
local nearA: { [number]: number } = {}
local nearB: { [number]: number } = {}

-- EVERY BODY IN EVERY NEARBY CELL, not one per cell. `nav.comp` is the body
-- the cell's own anchor happens to sit in, and a cell where a river runs three
-- tiles from the sea holds both -- so reading the anchor alone answered "which
-- water does this coast touch" with the river, and refused the crossing. All
-- four queries below walk `nav.bodies` for that reason.
-- The water bodies a tile touches, as comp -> distance in cells.
function Navy.compsNear(nav: Nav, tile: number, out: { [number]: number }): { [number]: number }
	table.clear(out)
	cellsNear(nav, tile, nearA)
	for cell, r in nearA do
		local list = nav.bodies[cell + 1]
		if list ~= nil then
			for j = 1, #list, 4 do
				local comp = list[j]
				if out[comp] == nil or r < out[comp] then
					out[comp] = r
				end
			end
		end
	end
	return out
end

-- The water cell nearest `tile` that holds `comp`. This is what makes a route
-- start on the RIGHT water: the cell nearest the tile may be a river the route
-- has nothing to do with.
function Navy.cellInComp(nav: Nav, tile: number, comp: number): number?
	cellsNear(nav, tile, nearA)
	local best, bestR = nil, math.huge
	for cell, r in nearA do
		if r < bestR and Navy.anchorIn(nav, cell, comp) ~= nil then
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
		local list = nav.bodies[cell + 1]
		if list ~= nil and r < pickR then
			for j = 1, #list, 4 do
				local comp = list[j]
				if comps[comp] ~= nil then
					pick, pickR = comp, r
					break
				end
			end
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
		local list = nav.bodies[cell + 1]
		if list ~= nil then
			for j = 1, #list, 4 do
				local comp = list[j]
				local da = a[comp]
				if da ~= nil and da + r < pickD then
					pick, pickD = comp, da + r
				end
			end
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
-- ROOK STEPS, for the FINE route only. The coarse search above still moves
-- diagonally between cells -- it is choosing which way round a continent, and
-- nothing is ever drawn on it -- but Navy.channel is the line a hull is
-- actually walked along, and the owner wants boats moving in one axis at a
-- time (2026-09-01): "i want them to be able to move only in the x or y at a
-- time to limit what looks like diagonal movement". A side-on sprite that
-- cannot be rotated to its heading is what makes a diagonal read badly -- the
-- boat crabs -- so the fix is in the movement, not the art.
--
-- It costs route LENGTH: a diagonal run is now a staircase, up to 1.41x the
-- tiles. That is the price of the look and it was accepted knowing it.
local NEI4 = { -1, 0, 0, -1, 0, 1, 1, 0 }

-- WHAT A COASTLINE COSTS, in extra cells, when a cell is ALL beach and one
-- tile of water. It is the single most effective thing in the naval pass of
-- 2026-09-02 and it is upstream's idea: AStar.Water prices a water tile within
-- three of the shore at TEN TIMES a tile out in the lane
-- (getMagnitudePenalty), so its ships stand off the land and sail in straight
-- lines between headlands. Conquest could not do that in the FINE search --
-- measured, and it was worse on every count, because a leg's window is twelve
-- tiles wide and there is nowhere to stand off TO -- but the coarse grid
-- chooses which way round a continent and has the whole sea to choose from.
--
-- Without it, "navigable if ANY tile in the cell is wet" means the cheapest
-- route between two coasts is the one that traces the coastline, and a hull
-- following it spends the crossing entering every inlet. Then no amount of
-- straightening downstream can help: there is no straight line to find.
--
-- Measured over 60 coast-to-coast crossings a map, against the same routes
-- with everything else in this pass already in (turn tie-break, straightener,
-- straight jumps), us / europe / venice / china:
--
--   coast   turns per crossing        tiles on land        fine searches
--     0      158 / 152 / 106 / 199    2.5 / 3.9 / .13 / 5.9%   47 / 40 / 18 / 57
--     1       92 / 101 /  87 /  91    1.7 / 4.1 / .00 / 4.7%   29 / 33 /  9 / 23
--     2       74 /  93 /  86 /  76    1.0 / 4.0 / .00 / 4.4%   21 / 31 /  8 / 19
--     3       74 /  77 /  86 /  75    1.0 / 3.0 / .00 / 4.4%   21 / 26 /  8 / 19
--
-- 3 buys almost nothing over 2 and starts lengthening routes (europe: 838
-- tiles against 752), so 2. Note the fine searches falling with it -- a
-- straight route through open water is one a hull can be given in one piece,
-- so this pass PAYS for itself twice over in the tick.
--
-- What it costs: a coarse route now expands about twice the cells (us 1,149 ->
-- 2,430 against a 20,000 limit), and it is emphatically NOT free for anything
-- with a smaller cap -- Economy's own sea search caps at 4,000 pops and lost
-- three lanes in twenty until that was doubled. MOVE THE CAP WITH THIS.
local COAST_COST = 2
local INV_CELL = 1 / (S * S)

-- What entering `cell` costs a coarse route beyond the step itself: nothing in
-- open water, up to COAST_COST for a cell that is one wet tile in a beach.
-- Economy's sea search prices its lanes with this too, so a trading boat and a
-- transport agree about where the sea lanes are.
function Navy.cellCost(nav: Nav, cell: number): number
	return COAST_COST * (1 - nav.wet[cell + 1] * INV_CELL)
end

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
	-- The waypoint for a cell is the anchor OF THIS ROUTE'S BODY, not the
	-- cell's own nearest-to-centre anchor: on a river mouth those are different
	-- tiles and the second one is a waypoint no hull on this sea can reach.
	local function way(c: number): number
		return (Navy.anchorIn(nav, c, comp) or (nav.rep[c + 1] - 1)) :: number
	end
	if startC == goalC then
		return { way(goalC) }
	end

	local wet = nav.wet
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
				-- THE WATER HAS TO JOIN UP. "Both cells hold some water" was
				-- the whole test until 2026-09-03, and it is not one: a cell is
				-- navigable on a SINGLE wet tile, so the two cells either side
				-- of a headland both qualified and the route stepped straight
				-- over it. Everything downstream then inherits a leg that no
				-- water can serve, and the only way to walk it is ashore --
				-- which is where the overland sailing in this game came from.
				-- See Navy.canStep.
				if Navy.canStep(nav, c, comp, dx, dy) then
					local step = (dx ~= 0 and dy ~= 0) and 1.41421356 or 1
					-- OPEN WATER IS CHEAPER THAN A COASTLINE, in proportion to
					-- how much beach the cell holds. Upstream prices its water
					-- the same way and for the same reason -- AStar.Water's
					-- getMagnitudePenalty makes a tile within three of the
					-- shore ten times the cost of one in the lane -- and this
					-- is the grid that has the room to act on it. Without it
					-- the coarse route threads whichever cells are nearest the
					-- line, coastal ones included, and a hull spends the
					-- crossing tracing every inlet: no straight run is
					-- available to it, however the fine search is asked.
					step += COAST_COST * (1 - wet[nc + 1] * INV_CELL)
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
		table.insert(out, 1, way(c))
		c = came[c]
	end
	return out
end

-- -------------------------------------------------------- straight runs ----

-- UPSTREAM SMOOTHS EVERY WATER ROUTE BEFORE ANYTHING SAILS IT, and that is
-- most of why its ships read as deliberate. The A* answer goes through
-- SmoothingWaterTransformer (src/core/pathfinding/transformers): binary-search
-- line-of-sight, a bounded local A* over the first and last fifty tiles, then
-- line-of-sight again farther from the shore. What a hull follows is a handful
-- of long straight runs, not the grid-shaped thing the search returned.
--
-- The same idea in rook geometry. A boat here moves on one axis at a time, so
-- the straight line between two tiles is an L: one run along x, one along y.
-- An L is EXACTLY as long as any other rook route between the same two tiles
-- (both are the Manhattan distance), so replacing a staircase with one costs
-- no tiles, no time and no balance -- it only changes what the line looks
-- like. That is the whole reason this is safe to do everywhere.
--
-- The depth test is upstream's too (LOS_MIN_MAGNITUDE_PASS1/2, and TileMap's
-- magnitude IS depth for a water tile): straight runs are taken through open
-- water first and only the leftovers are allowed to straighten through the
-- shallows, so a hull crossing a sea does not shave the corner off a headland
-- it had the room to stand off from.
local SMOOTH_DEEP = 2
local SMOOTH_ANY = 0

-- Furthest ahead the binary search may look, in route points. It bounds the
-- cost of one failed line-of-sight test, which is the only expensive thing
-- here.
local LOS_LOOKAHEAD = 384

-- Every terrain byte, pre-answered: does a hull sailing this pass float, and
-- is it deep enough. A straight-run test reads one tile per tile it crosses
-- and an ocean crossing crosses hundreds, so this is the difference between a
-- table lookup and unpacking the byte every time.
local PASS: { { boolean } } = {}
for _, minMag in { SMOOTH_ANY, SMOOTH_DEEP } do
	local t = table.create(256, false)
	for b = 0, 255 do
		t[b + 1] = not TileMap.isLandByte(b) and TileMap.magnitudeByte(b) >= minMag
	end
	PASS[minMag + 1] = t
end

-- One axis of a straight run, EXCLUDING the tile it starts on: a boat is
-- allowed to be where it already is, which matters because every transport
-- starts on a beach.
local function clearRow(terrain: buffer, y: number, xa: number, xb: number, pass: { boolean }): boolean
	local step = xa < xb and 1 or -1
	local base = y * W
	for x = xa + step, xb, step do
		if not pass[buffer.readu8(terrain, base + x) + 1] then
			return false
		end
	end
	return true
end

local function clearCol(terrain: buffer, x: number, ya: number, yb: number, pass: { boolean }): boolean
	local step = ya < yb and 1 or -1
	for y = ya + step, yb, step do
		if not pass[buffer.readu8(terrain, y * W + x) + 1] then
			return false
		end
	end
	return true
end

-- Can a hull get from `from` to `to` in two straight runs over water no
-- shallower than `minMag`? Returns 1 for x-then-y, 2 for y-then-x, nil for
-- neither. THE LONG AXIS GOES FIRST when both orders are clear, and that is
-- not cosmetic: Sim gives up on a transport that stops closing on its
-- waypoint, it measures closing in Chebyshev distance, and a leg that spends
-- its first two hundred tiles on the short axis does not close at all.
local function seeL(map: TileMap.TileMap, from: number, to: number, minMag: number): number?
	local terrain = map.terrain
	local pass = PASS[minMag + 1]
	local x0 = from % W
	local y0 = (from - x0) / W
	local x1 = to % W
	local y1 = (to - x1) / W
	if y0 == y1 then
		return (x0 ~= x1 and clearRow(terrain, y0, x0, x1, pass)) and 1 or nil
	end
	if x0 == x1 then
		return clearCol(terrain, x0, y0, y1, pass) and 2 or nil
	end
	if math.abs(x1 - x0) >= math.abs(y1 - y0) then
		if clearRow(terrain, y0, x0, x1, pass) and clearCol(terrain, x1, y0, y1, pass) then
			return 1
		end
		return (clearCol(terrain, x0, y0, y1, pass) and clearRow(terrain, y1, x0, x1, pass)) and 2 or nil
	end
	if clearCol(terrain, x0, y0, y1, pass) and clearRow(terrain, y1, x0, x1, pass) then
		return 2
	end
	return (clearRow(terrain, y0, x0, x1, pass) and clearCol(terrain, x1, y0, y1, pass)) and 1 or nil
end

-- Write that L into `out`, start-exclusive, in the order `seeL` approved.
local function traceL(from: number, to: number, order: number, out: { number })
	local x0 = from % W
	local y0 = (from - x0) / W
	local x1 = to % W
	local y1 = (to - x1) / W
	if order == 1 then
		local sx = x0 < x1 and 1 or -1
		local base = y0 * W
		for x = x0 + sx, x1, sx do
			out[#out + 1] = base + x
		end
		local sy = y0 < y1 and 1 or -1
		for y = y0 + sy, y1, sy do
			out[#out + 1] = y * W + x1
		end
	else
		local sy = y0 < y1 and 1 or -1
		for y = y0 + sy, y1, sy do
			out[#out + 1] = y * W + x0
		end
		local sx = x0 < x1 and 1 or -1
		local base = y1 * W
		for x = x0 + sx, x1, sx do
			out[#out + 1] = base + x
		end
	end
end

-- Upstream's losSmooth. From each anchor, binary-search the FURTHEST point of
-- the route still reachable in two straight runs, replace everything between
-- with that L, and start again from there.
--
-- Visibility is not strictly monotone -- a farther point can be reachable when
-- a nearer one is not -- so the binary search can miss a run. Upstream lives
-- with that and so does this: the alternative is a linear scan of a route that
-- can be a thousand tiles long, and a miss costs one turn that was already
-- there.
--
-- A point it cannot see AT ALL is copied through untouched, which is what
-- keeps a portage intact: the land tiles of a crossing fail every
-- line-of-sight test and survive exactly as the search laid them.
local function losSmooth(map: TileMap.TileMap, pts: { number }, minMag: number): { number }
	local n = #pts
	if n <= 2 then
		return pts
	end
	local out = { pts[1] }
	local cur = 1
	while cur < n do
		local lo = cur + 1
		local hi = math.min(n, cur + LOS_LOOKAHEAD)
		local far, farOrder = 0, nil :: number?
		while lo <= hi do
			local mid = (lo + hi) // 2
			local order = seeL(map, pts[cur], pts[mid], minMag)
			if order ~= nil then
				far, farOrder = mid, order
				lo = mid + 1
			else
				hi = mid - 1
			end
		end
		if farOrder ~= nil then
			traceL(pts[cur], pts[far], farOrder, out)
			cur = far
		else
			cur += 1
			out[#out + 1] = pts[cur]
		end
	end
	return out
end

-- A route, straightened. Routes here are start-exclusive by convention --
-- `fromTile` is the tile the hull is standing on -- and so is the answer.
-- Two passes, open water and then any water, for the reason above.
function Navy.straighten(map: TileMap.TileMap, fromTile: number, route: { number }): { number }
	local n = #route
	if n < 3 then
		return route
	end
	local pts = table.create(n + 1)
	pts[1] = fromTile
	table.move(route, 1, n, 2, pts)
	local sm = losSmooth(map, losSmooth(map, pts, SMOOTH_DEEP), SMOOTH_ANY)
	local out = table.create(#sm - 1)
	table.move(sm, 2, #sm, 1, out)
	return out
end

-- Tiles one straight jump may cover. A leg is walked one tile a tick and Sim
-- sends home a transport that has not closed on its waypoint in 300 of them;
-- the stall inside an L is at most its short axis, so half of this is the
-- number that has to stay under that.
local JUMP_MAX_TILES = 256
-- Waypoints a SHALLOW straight run may cover, when no open-water one exists.
-- This is the river and the strait, where the water is one magnitude band deep
-- everywhere and a long straight line through it is usually a line through the
-- bank -- so it is asked for a few waypoints, not a crossing. Worth having:
-- it took the fine searches a transport pays for from 21 to 16 a crossing on
-- us and 31 to 24 on europe, for no change in the shape of the route.
local JUMP_SHALLOW_AHEAD = 4

-- THE SAME SMOOTHING, APPLIED TO THE COARSE ROUTE BEFORE IT IS WALKED. The
-- waypoints are cell anchors eight tiles apart, so a hull crossing open sea
-- diagonally used to draw a staircase with an eight-tile step -- every leg
-- individually straight and the whole crossing a zigzag. This asks the only
-- question that matters out there: how far along the route can it get in two
-- straight runs? Answer that and an ocean crossing is two lines.
--
-- It runs BEFORE the channel search rather than instead of it, which is
-- upstream's arrangement exactly: line-of-sight owns the open water, the local
-- A* owns the coast, where line of sight always fails and detail is what is
-- actually wanted.
function Navy.straightJump(
	map: TileMap.TileMap,
	fromTile: number,
	path: { number },
	idx: number,
	maxAhead: number
): (number, { number }?)
	local n = #path
	if idx > n then
		return idx, nil
	end
	local fx = fromTile % W
	local fy = (fromTile - fx) / W
	local best, bestOrder = 0, nil :: number?
	local function search(minMag: number, reach: number)
		local lo = idx
		local hi = math.min(n, idx + reach - 1)
		while lo <= hi do
			local mid = (lo + hi) // 2
			local wp = path[mid]
			local wx = wp % W
			local wy = (wp - wx) / W
			local order = nil
			if math.abs(wx - fx) + math.abs(wy - fy) <= JUMP_MAX_TILES then
				order = seeL(map, fromTile, wp, minMag)
			end
			if order ~= nil then
				best, bestOrder = mid, order
				lo = mid + 1
			else
				hi = mid - 1
			end
		end
	end
	search(SMOOTH_DEEP, maxAhead)
	if bestOrder == nil then
		-- Nothing in open water. A river or a strait is the case here, so ask
		-- again over any water at all and over a shorter reach -- straightening
		-- a river is worth a few waypoints, not the whole crossing.
		search(SMOOTH_ANY, JUMP_SHALLOW_AHEAD)
	end
	if bestOrder == nil then
		return idx, nil
	end
	local out: { number } = {}
	traceL(fromTile, path[best], bestOrder, out)
	return best, out
end

-- ------------------------------------------------------------- channel -----

-- How far outside the box its two ends span the fine search may look. One
-- leg is a single coarse cell long, so this is sized for the case that
-- actually costs something: a river that bends out of that box and back.
local CHANNEL_PAD = 10
-- Expansions, not tiles. The window already bounds how much map this can see;
-- this bounds the work inside a window that is mostly water.
local CHANNEL_CAP = 1200

-- What a route pays for changing direction, in water steps. It is a TIE-BREAK,
-- not a preference: every rook route between two tiles that does not double
-- back is the same length, so on open water the search has hundreds of equally
-- short answers and used to return whichever one the heap happened to settle
-- first -- a staircase. Priced below 1/CHANNEL_CAP so the total penalty along
-- any route the cap allows stays under one tile, i.e. it can only ever choose
-- BETWEEN shortest routes and never buy straightness with a longer one.
local TURN_COST = 0.0005

local chG: { [number]: number } = {}
local chCame: { [number]: number } = {}
local chDir: { [number]: number } = {}
local chHeapT: { number } = {}
local chHeapF: { number } = {}

-- Cells expanded by the last channel search, so a caller running SEVERAL of
-- them in one tick can spend a budget rather than a count. Economy refines a
-- whole ocean lane in one go and the legs vary by two orders of magnitude:
-- counting legs would ration the cheap ones and let a single expensive one
-- own the tick.
Navy.lastExpanded = 0

-- The tile-by-tile route between two waypoints: 4-connected A* over WATER
-- ONLY, inside the box the two tiles span padded by CHANNEL_PAD. Four, not
-- eight, so a hull only ever moves along one axis at a time -- see NEI4.
--
-- THIS IS THE MISSING HALF OF THE COARSE SEARCH. A cell counts as navigable
-- when a single tile inside it is wet, so a coarse route only ever promised
-- that water is NEAR the line between two waypoints -- and a boat steering
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
-- that the crossing is as SHORT as the map allows: the boat sails to the
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

	local g, came, dir = chG, chCame, chDir
	table.clear(g)
	table.clear(came)
	table.clear(dir)
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

	-- Manhattan, which is exact for unit rook steps -- so this A* expands the
	-- minimum it can on open water. The octile heuristic that was here matched
	-- the sqrt(2) diagonals that no longer exist; it would still be admissible,
	-- just needlessly weak.
	local function heur(x: number, y: number): number
		return math.abs(x - gx) + math.abs(y - gy)
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
		local cd = dir[cur]
		for k = 1, #NEI4, 2 do
			local nx, ny = cx + NEI4[k], cy + NEI4[k + 1]
			if nx >= x0 and nx <= x1 and ny >= y0 and ny <= y1 then
				local nt = ny * W + nx
				local onLand = TileMap.isLand(map, nt)
				-- The GOAL is always enterable whether or not it floats: on a
				-- landing the last thing a boat aims at is the beach itself.
				if nt == toTile or not onLand or landCost ~= nil then
					-- The corner-cutting guard that used to live here is GONE
					-- WITH THE DIAGONALS, not forgotten: it existed only to
					-- stop a hull sliding through the point where two land
					-- tiles meet, and a rook step cannot reach that join.
					local step = 1
					if onLand and landCost ~= nil and nt ~= toTile then
						step = landCost
					end
					if cd ~= nil and cd ~= k then
						step += TURN_COST
					end
					local ng = cg + step
					local old = g[nt]
					if old == nil or ng < old then
						g[nt] = ng
						came[nt] = cur
						dir[nt] = k
						push(nt, ng + heur(nx, ny))
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
	-- Straightened before anyone sails it, exactly as upstream hands every
	-- water route through its smoothing transformer. The tie-break above
	-- already stops the search returning a staircase where it had a choice;
	-- this is for where it had none -- the search is optimal one tile at a
	-- time and still comes out of a bay a step at a time.
	return Navy.straighten(map, fromTile, out)
end

-- ------------------------------------------------------------- landing -----

-- Is this land tile one a transport boat can unload onto -- i.e. does it touch water?
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

-- Where the transport boat sails FROM: the embarking empire's own coast, closest to the
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
