--!strict
-- Conquest :: Modes
-- The game-mode roster. A mode decides how many teams there are and what
-- share of the map ends the round; everything else in the sim is shared.
--
-- Rotates alongside the map rotation (3 modes x 4 maps), so the pair a player
-- sees never repeats two rounds running.

local Modes = {}

export type ModeData = {
	NAME: string,
	SHORT: string,
	TEAMS: number, -- 0 = free for all
	WIN: number, -- share of playable land that wins outright
	BLURB: string,
}

-- Order is the rotation order.
Modes.ORDER = { "ffa", "duo", "trio" }

-- WIN is upstream's `percentageTilesOwnedToWin` base: 80% free-for-all, 95%
-- team (src/core/configuration/Config.ts:714). It is declared here only for
-- display; Sim.winThreshold reads Config.WIN_PERCENT_FFA / _TEAM directly.
--
-- THERE IS NO PER-MODE FLOOR ANY MORE, and its absence is the point. Upstream
-- decays the bar to ZERO (`Math.max(0, base - points)`, Config.ts:731), so a
-- deadlocked round is always eventually called. A floor above an even split
-- does the opposite: two evenly matched teams hold each other at ~50/50, the
-- bar stops at 54%, and the round provably cannot end.

Modes.BY_ID = {
	ffa = {
		NAME = "FREE FOR ALL",
		SHORT = "FFA",
		TEAMS = 0,
		WIN = 0.80,
		BLURB = "Every empire for itself.",
	},
	duo = {
		NAME = "TWO TEAMS",
		SHORT = "2 TEAMS",
		TEAMS = 2,
		WIN = 0.95,
		BLURB = "Two alliances, one map. No friendly fire.",
	},
	trio = {
		NAME = "THREE TEAMS",
		SHORT = "3 TEAMS",
		TEAMS = 3,
		WIN = 0.95,
		BLURB = "Three-way war. Every border is someone else's.",
	},
} :: { [string]: ModeData }

-- An unknown id falls back to free-for-all rather than erroring, so a stale
-- saved id can never wedge the round loop.
function Modes.get(id: string?): ModeData
	local m = id and Modes.BY_ID[id]
	if not m then
		return Modes.BY_ID.ffa
	end
	return m
end

function Modes.exists(id: string): boolean
	return Modes.BY_ID[id] ~= nil
end

function Modes.name(id: string?): string
	return Modes.get(id).NAME
end

function Modes.teams(id: string?): number
	return Modes.get(id).TEAMS
end

function Modes.next(id: string?): string
	if id then
		for i, k in Modes.ORDER do
			if k == id then
				return Modes.ORDER[(i % #Modes.ORDER) + 1]
			end
		end
	end
	return Modes.ORDER[1]
end

return Modes
