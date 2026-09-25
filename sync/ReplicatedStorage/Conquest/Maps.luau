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
-- THREE OF THESE ARE NOT CONTINENTS (2026-08-31). Tokyo, Istanbul and Venice
-- are regions 520-720 km across at 0.6-0.8 km/px, where the first four are
-- 4,300-4,700 km across at 5-8. Same 880x550 frame, so nothing in the engine
-- can tell the difference -- but the ground each tile stands for is roughly
-- a kilometre rather than five, which is why Istanbul can have a strait two
-- tiles wide and a bridge over it. That scale is also the floor: Natural
-- Earth 1:10m carries a coastline vertex about every 1.5 km, so below
-- ~0.4 km/px a coast stops being a coast and becomes the polygon's own
-- straight edges. See mapgen/specs.py.
--
-- The price of one frame is that a squarish region gets scaled to fit the
-- SHORTER axis. China's land bounding box is 598x502, so 38% of its frame is
-- ocean nothing can reach; upstream ships china as 2080x1892, and its 118 maps
-- fill their frames to a median of 97%.

local UsMap = require(script.Parent.UsMap)
local ChinaMap = require(script.Parent.ChinaMap)
local EuropeMap = require(script.Parent.EuropeMap)
local MediterraneanMap = require(script.Parent.MediterraneanMap)
local TokyoMap = require(script.Parent.TokyoMap)
local IstanbulMap = require(script.Parent.IstanbulMap)
local VeniceMap = require(script.Parent.VeniceMap)
local PacificMap = require(script.Parent.PacificMap)
local WorldMap = require(script.Parent.WorldMap)
local NewYorkMap = require(script.Parent.NewYorkMap)
local JapanMap = require(script.Parent.JapanMap)
local KoreaMap = require(script.Parent.KoreaMap)
local AfricaMap = require(script.Parent.AfricaMap)
local PhilippinesMap = require(script.Parent.PhilippinesMap)
local EurasiaMap = require(script.Parent.EurasiaMap)
local MarsMap = require(script.Parent.MarsMap)

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
	-- Set only by the CITY maps, which are flat enough that MapGen's
	-- quantile split would invent relief out of the detail noise.
	TERRAIN_SPLIT: { highland: number, mountain: number }?,
	MASK: string,
	-- Land the frame can see and nobody may enter: the neighbouring countries,
	-- and any landmass too big to keep as scenery. Same encoding as MASK and
	-- disjoint from it. Absent on Tokyo and Venice, where the frame IS the
	-- city; New York's is New Jersey, Nassau and Westchester. MapGen packs these tiles at magnitude 63,
	-- TileMap calls that terrain type 4, isPassable excludes it and Palette
	-- draws it void grey.
	OOB_MASK: string?,
	OOB_TILES: number?,
	-- A FIXED AI COUNT, stated by a map instead of derived from its land. The
	-- World map (2026-09-08) is 97,638 playable tiles, which the land formula
	-- reads as 26 empires; the owner wants fifty AI on a planet. Read by
	-- ConquestServer.startRound and /simulate: humans come on top of it and
	-- Config.TARGET_EMPIRES is still the ceiling. Absent on every other map.
	BOTS: number?,
}

local Maps = {}

-- Order is the rotation order, so this is also the order players see.
-- Interleaved rather than appended: four of these are CONTINENTS at 5-8
-- km/px and three are REGIONS at 0.6-0.8, which is a different-feeling map,
-- so the rotation alternates instead of playing four of one kind and then
-- three of the other.
--
-- PACIFIC (2026-09-04) is a third scale class and goes on the end, because
-- there is nothing to interleave it with: 24.7 km/px, a whole hemisphere,
-- and the only map in the rotation where most of the frame is ocean and the
-- navy is a theatre rather than a river crossing. Eight maps and three modes
-- are still coprime, so a map/mode pair now repeats every 24 rounds instead
-- of every 21.
--
-- WORLD (2026-09-08) is the whole planet on the same frame, 35 km/px, and it
-- goes on the end next to the Pacific for the same reason the Pacific did:
-- it is an ocean map with continents in it, not a continent with a coast.
-- Nine maps and three modes are coprime, so a map/mode pair repeats every 27.
--
-- NEW YORK (2026-09-11) is a CITY, 85 km across at 0.1 km/px, so it sits
-- between the Mediterranean and the Pacific and the rotation keeps
-- alternating scale classes. Ten maps and three modes are coprime, so a
-- map/mode pair repeats every 30.
--
-- JAPAN (2026-09-11) is the home islands at 3.1 km/px, between the
-- continents and the regions, so it follows the New York city map and
-- leads into the Pacific.
--
-- KOREA, AFRICA and MARS (2026-09-13) go in at their own scale classes
-- rather than on the end. Korea is 2.1 km/px and the other map in the
-- rotation framed by height, so it follows Japan -- but it is a MAINLAND
-- at that scale where Japan is islands, which is a different game on a
-- similar-looking frame. Africa is the largest continent and the coarsest
-- one (17.7 km/px), so it leads out of the continents and into the three
-- maps where water is the theatre rather than a border: Pacific, World and
-- then Mars, which is last because it is the other planet and belongs next
-- to this one. Fourteen maps and three modes are still coprime, so a
-- map/mode pair now repeats every 42 rounds instead of every 33.
--
-- PHILIPPINES (2026-09-21, owner: "encourage more ocean gameplay") is an
-- archipelago at 2.9 km/px with no mainland -- eleven spawnable islands and
-- no land border between any two of them -- so it goes where the water maps
-- start: after Africa, ahead of the Pacific. Fifteen maps and three modes are
-- NOT coprime, so the fallback rotation (a reserved server with no match
-- record: Maps.next and Modes.next stepping together) now pairs each map
-- with one fixed mode. The public board draws from Matchmaker.allPairs, every
-- map in every mode, and is unaffected.
Maps.ORDER = { "us", "istanbul", "europe", "tokyo", "china", "venice", "medit", "nyc", "japan", "korea", "africa", "philippines", "pacific", "world", "eurasia", "mars" }

Maps.BY_ID = {
	us = UsMap,
	europe = EuropeMap,
	china = ChinaMap,
	medit = MediterraneanMap,
	tokyo = TokyoMap,
	istanbul = IstanbulMap,
	venice = VeniceMap,
	pacific = PacificMap,
	world = WorldMap,
	nyc = NewYorkMap,
	japan = JapanMap,
	korea = KoreaMap,
	africa = AfricaMap,
	philippines = PhilippinesMap,
	eurasia = EurasiaMap,
	mars = MarsMap,
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
