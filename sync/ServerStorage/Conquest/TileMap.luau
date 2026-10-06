--!strict
-- Conquest :: TileMap
-- Flat typed-buffer world. There are no tile objects: a tile is an integer
-- index into two parallel buffers, which is what keeps 163k tiles cheap.
--
--   terrain (u8, immutable after generation)
--     bit 7 : is land
--     bit 6 : is shore (land touching water, or water touching land)
--     0..5  : magnitude -- elevation for land, depth for water
--
--   owner (u8, mutable)
--     0     : unclaimed
--     1-255 : player small id

local Config = require(script.Parent.Config)

local W = Config.MAP_W
local H = Config.MAP_H
local N = Config.NUM_TILES

local LAND_BIT = 128
local SHORE_BIT = 64
local MAG_MASK = 63

local TileMap = {}
TileMap.__index = TileMap

export type TileMap = typeof(setmetatable(
	{} :: {
		terrain: buffer,
		owner: buffer,
		landCount: number,
	},
	TileMap
))

function TileMap.new(terrain: buffer, landCount: number): TileMap
	return setmetatable({
		terrain = terrain,
		owner = buffer.create(N),
		landCount = landCount,
	}, TileMap) :: any
end

-- ------------------------------------------------------------ geometry -----

function TileMap.index(x: number, y: number): number
	return y * W + x
end

function TileMap.x(i: number): number
	return i % W
end

function TileMap.y(i: number): number
	return (i - i % W) / W
end

function TileMap.inBounds(x: number, y: number): boolean
	return x >= 0 and x < W and y >= 0 and y < H
end

-- Writes the 4-neighbours of `i` into `out` and returns the count. `out` is
-- reused by the caller so hot loops allocate nothing.
function TileMap.neighbors4(i: number, out: { number }): number
	local x = i % W
	local n = 0
	if i >= W then
		n += 1
		out[n] = i - W
	end
	if i < N - W then
		n += 1
		out[n] = i + W
	end
	if x ~= 0 then
		n += 1
		out[n] = i - 1
	end
	if x ~= W - 1 then
		n += 1
		out[n] = i + 1
	end
	return n
end

-- --------------------------------------------------------------- terrain ---

function TileMap.isLandByte(b: number): boolean
	return bit32.btest(b, LAND_BIT)
end

function TileMap.magnitudeByte(b: number): number
	return bit32.band(b, MAG_MASK)
end

-- 0 = water, 1 = plains, 2 = highland, 3 = mountain, 4 = impassable
function TileMap.typeByte(b: number): number
	if not bit32.btest(b, LAND_BIT) then
		return 0
	end
	local mag = bit32.band(b, MAG_MASK)
	if mag >= MAG_MASK then
		return 4
	elseif mag < 11 then
		return 1
	elseif mag < 21 then
		return 2
	end
	return 3
end

function TileMap.packTerrain(isLand: boolean, isShore: boolean, magnitude: number): number
	local b = math.clamp(math.floor(magnitude), 0, MAG_MASK)
	if isLand then
		b = bit32.bor(b, LAND_BIT)
	end
	if isShore then
		b = bit32.bor(b, SHORE_BIT)
	end
	return b
end

-- --------------------------------------------------------------- access ----

function TileMap.terrainAt(self: TileMap, i: number): number
	return buffer.readu8(self.terrain, i)
end

function TileMap.isLand(self: TileMap, i: number): boolean
	return bit32.btest(buffer.readu8(self.terrain, i), LAND_BIT)
end

function TileMap.isShore(self: TileMap, i: number): boolean
	return bit32.btest(buffer.readu8(self.terrain, i), SHORE_BIT)
end

function TileMap.isPassable(self: TileMap, i: number): boolean
	local b = buffer.readu8(self.terrain, i)
	return bit32.btest(b, LAND_BIT) and bit32.band(b, MAG_MASK) < MAG_MASK
end

function TileMap.terrainType(self: TileMap, i: number): number
	return TileMap.typeByte(buffer.readu8(self.terrain, i))
end

function TileMap.ownerAt(self: TileMap, i: number): number
	return buffer.readu8(self.owner, i)
end

function TileMap.setOwner(self: TileMap, i: number, id: number)
	buffer.writeu8(self.owner, i, id)
end

-- True when any 4-neighbour is owned by someone other than `i`'s owner.
-- Off-map edges do not count, so a coastline is a border but the map rim is
-- only a border if something across it differs.
function TileMap.isBorder(self: TileMap, i: number): boolean
	local owner = self.owner
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

return TileMap
