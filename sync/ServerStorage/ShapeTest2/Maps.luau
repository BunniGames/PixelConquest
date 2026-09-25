--!strict
-- Conquest :: Maps
-- The map roster. Every entry is a generated module (build_maps.py) holding a
-- run-length land mask plus mountain-range polylines; MapGen turns one into
-- terrain, and the only thing that crosses the wire is the id string.
--
-- All maps are 1600x1000 by design. Sharing one resolution is what lets the
-- tile-index packing, the renderer's image grid and every distance constant in
-- Config stay fixed no matter which map is loaded -- the alternative is
-- re-deriving INDEX_BITS and re-sweeping the balance constants per map.

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
