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
	FLOOR: number, -- overtime floor for that share
	BLURB: string,
}

-- Order is the rotation order.
Modes.ORDER = { "ffa", "duo", "trio" }

-- WIN/FLOOR are NOT comparable across modes, because the baseline is not.
-- One empire in a free-for-all starts at well under 1% of the map, so 80% is
-- a conquest. A team owns roughly 1/TEAMS of the map the moment the land grab
-- ends, so the same number would be handed out for free -- the bar has to sit
-- far above an even split, and the overtime FLOOR has to stay above it too or
-- the clock alone would crown whoever is marginally ahead.
--
-- The team numbers below are measured, not guessed. Headless matches with
-- even sides (7v7, 5v5v5) across all four maps finished at 66.3/66.9/52.6/
-- 45.2/54.5 percent, i.e. NOWHERE NEAR an 0.85 or 0.72 opening bar -- so a
-- higher WIN is not a higher standard, it is just dead range the overtime
-- decay has to grind through before anything can happen. These are set where
-- a genuinely dominant side actually crosses them.
--
-- FLOOR is the deadlock tiebreak, and it has to sit only just above an even
-- split. Two evenly matched teams really can hold each other at ~50/50: at
-- the old 0.58 floor that round ran to the 30-minute hard limit instead of
-- being called for whoever was ahead.
Modes.BY_ID = {
	ffa = {
		NAME = "FREE FOR ALL",
		SHORT = "FFA",
		TEAMS = 0,
		WIN = 0.80,
		FLOOR = 0.15,
		BLURB = "Every empire for itself.",
	},
	duo = {
		NAME = "TWO TEAMS",
		SHORT = "2 TEAMS",
		TEAMS = 2,
		WIN = 0.78,
		FLOOR = 0.54,
		BLURB = "Two alliances, one map. No friendly fire.",
	},
	trio = {
		NAME = "THREE TEAMS",
		SHORT = "3 TEAMS",
		TEAMS = 3,
		WIN = 0.66,
		FLOOR = 0.40,
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
