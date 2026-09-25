--!strict
-- Conquest :: Maps
-- The map roster. Every entry is a generated module (build_maps.py) holding a
-- run-length land mask plus mountain-range polylines; MapGen turns one into
-- terrain, and the only thing that crosses the wire is the id string.
--
-- All maps are 880x550 by design, and only ONE of the three reasons
-- originally given for that survives contact with the code.
--
--   NOT a reason -- tile-index packing. The wire is a delta-varint
--   (Net.packDelta) and a run-length (Net.packOwners). Neither has a fixed
--   index width. `Config.INDEX_BITS` was read by nothing at all.
--
--   NOT a reason -- the distance constants. Upstream holds every one of them
--   IDENTICAL across maps spanning 262,144 to 11,204,096 tiles, and identical
--   again when it replays one map at a quarter of its area:
--   minDistanceBetweenPlayers 30, structureMinDist 15, radiusPortSpawn 20,
--   trainStation 15/110, the 300-tile trade debuff, the nuke radii, the
--   100-tile dead-defender bar, the 80% win bar. What upstream scales with map
--   size is POPULATION, never distance (MapPlaylist.ts:812-825, :213,
--   :757-760; NationCreation.ts:163-175).
--
--   IS a reason -- the renderer. Renderer asserts W and H divide evenly into a
--   ceil(W/900) x ceil(H/900) grid of images, and TileMap, MapGen, Sim,
--   Renderer, Camera2D, NationLabels, Structures, Economy, Navy and Units all
--   cache W/H/N as module-level locals AT REQUIRE TIME. Per-map dimensions
--   means a setDimensions() entry point on all ten and a non-uniform last
--   image column.
--
-- The price of one frame is that a squarish region gets scaled to fit the
-- SHORTER axis. China's land bounding box is 598x502, so 38% of its frame is
-- ocean nothing can reach; upstream ships china as 2080x1892, and its 118 maps
-- fill their frames to a median of 97%.

local UsMap = require(script.Parent.UsMap)
local ChinaMap = require(script.Parent.ChinaMap)
local EuropeMap = require(script.Parent.EuropeMap)
local MediterraneanMap = require(script.Parent.MediterraneanMap)

export type MapData = {
	NAME: string,
	BLURB: string,
	WIDTH: number,
	HEIGHT: number,
	LAND_TILES: number,
	RUN_COUNT: number,
	KM_PER_PX: number,
	MIN_LANDMASS: number,
	RANGES: { { s: number, w: number, p: { number } } },
	TILT: { center: number, halfwidth: number, amount: number }?,
	MASK: string,
}

local Maps = {}

-- Order is the rotation order, so this is also the order players see.
Maps.ORDER = { "us", "europe", "china", "medit" }

Maps.BY_ID = {
	us = UsMap,
	europe = EuropeMap,
	china = ChinaMap,
	medit = MediterraneanMap,
} :: { [string]: MapData }

function Maps.get(id: string): MapData
	local m = Maps.BY_ID[id]
	if not m then
		warn("[Conquest] unknown map id '" .. tostring(id) .. "', falling back to us")
		return UsMap
	end
	return m
end

function Maps.exists(id: string): boolean
	return Maps.BY_ID[id] ~= nil
end

function Maps.name(id: string): string
	return Maps.get(id).NAME
end

-- Next map in the rotation. An unknown id restarts the rotation rather than
-- erroring, so a stale saved id can never wedge the round loop.
function Maps.next(id: string?): string
	if id then
		for i, k in Maps.ORDER do
			if k == id then
				return Maps.ORDER[(i % #Maps.ORDER) + 1]
			end
		end
	end
	return Maps.ORDER[1]
end

return Maps
