--!strict
-- Conquest :: Modes
-- The game-mode roster. A mode decides how many teams there are and what
-- share of the map ends the round; everything else in the sim is shared.
--
-- Rotates alongside the map rotation (3 modes x 4 maps), so the pair a player
-- sees never repeats two rounds running.

local Modes = {}

-- WHAT A SPECIAL MODE HANDS EVERY EMPIRE AT SPAWN (2026-09-18). Flat figures,
-- bots included; Sim.applySpecial copies them onto the sim and Sim's
-- payOpening pays them at the three spawn sites. Absent on every ordinary
-- mode, and nothing but those two functions reads it.
export type Special = {
	startGold: number?, -- the treasury, replacing a room's STARTING GOLD dial
	startTroops: number?, -- the army, replacing the tier's spawn troops outright
	troopCapBonus: number?, -- added to every ceiling (maxTroops), outside the tier scale
	startNukes: number?, -- atom bombs in hand (Player.freeNukes)
	attackSpeed: number?, -- every empire's Player.attackSpeed: tiles per tick per attack, not troop cost
}

export type ModeData = {
	NAME: string,
	SHORT: string,
	TEAMS: number, -- 0 = free for all
	WIN: number, -- share of playable land that wins outright
	BLURB: string,
	-- True on the one mode whose map is drawn before anybody clicks: the
	-- nations, their borders and their cities come from a Scenarios entry
	-- keyed by the map, and the spawn phase is "pick a nation" rather than
	-- "pick a tile". Absent everywhere else.
	HISTORICAL: boolean?,
	-- The special opening, on the occasional modes only. See Special.
	SPECIAL: Special?,
}

-- Order is the rotation order.
Modes.ORDER = { "ffa", "duo", "trio" }

-- WIN is the share of the map that ends the round, and it is 90% in EVERY mode
-- -- a deviation from upstream, which splits it 80% free-for-all / 95% team
-- (src/core/configuration/Config.ts:714); the win block in Config says why. It
-- is declared here only for display; Sim.winThreshold reads
-- Config.WIN_PERCENT_FFA / _TEAM directly, and those two are the truth.
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
		WIN = 0.90,
		BLURB = "Every empire for itself.",
	},
	duo = {
		NAME = "TWO TEAMS",
		SHORT = "2 TEAMS",
		TEAMS = 2,
		WIN = 0.90,
		BLURB = "Two alliances, one map. No friendly fire.",
	},
	trio = {
		NAME = "THREE TEAMS",
		SHORT = "3 TEAMS",
		TEAMS = 3,
		WIN = 0.90,
		BLURB = "Three-way war. Every border is someone else's.",
	},
	-- HISTORICAL (2026-09-11): the borders are drawn before anyone clicks.
	-- STILL NOT IN ORDER, deliberately: ORDER is the rotation, and in it this
	-- would be paired with every map, most of which have no scenario. The
	-- lobby deals it as extra pairings on ONLY the maps that have one
	-- (Matchmaker.allPairs, wired the same day -- owner: "wire up historcal
	-- mode into the game"), and the owner's `/world historical` (ConquestWorld
	-- -> _G.ConquestStartMap) still works. Which nations exist, whose land
	-- is whose and what stands where is the MAP's scenario (Scenarios.forMap);
	-- this entry only names the mode. A free-for-all in every other respect:
	-- no teams, the same win bar.
	historical = {
		NAME = "HISTORICAL",
		SHORT = "HIST",
		TEAMS = 0,
		WIN = 0.90,
		BLURB = "Start as a real nation. The borders are already drawn.",
		HISTORICAL = true,
	},
	-- THREE MORE SCENARIOS (2026-09-24, owner: "For world map I want WW1, for
	-- europe, i want napoleanic wars. Want a pacific WW2 scenerio that focuses
	-- more on navy using the pacific map"). Each is a mode of its own because
	-- a mode is what the card, the match record and the command already carry
	-- -- the World now has two scenarios and the map alone cannot pick. Which
	-- map each is drawn on is Scenarios.BY_MODE; Matchmaker deals them only
	-- there. Same free-for-all as `historical` in every other respect.
	ww1 = {
		NAME = "WORLD WAR I",
		SHORT = "WW1",
		TEAMS = 0,
		WIN = 0.90,
		BLURB = "1914. The great powers, and every border already drawn.",
		HISTORICAL = true,
	},
	napoleonic = {
		NAME = "NAPOLEONIC WARS",
		SHORT = "1800",
		TEAMS = 0,
		WIN = 0.90,
		BLURB = "1800. France against the coalitions of Europe.",
		HISTORICAL = true,
	},
	pacificwar = {
		NAME = "PACIFIC WAR",
		SHORT = "1941",
		TEAMS = 0,
		WIN = 0.90,
		BLURB = "1941. Every nation opens with a fleet. Hold the sea.",
		HISTORICAL = true,
	},
	-- THE SPECIAL MODES (2026-09-18, owner: "special modes that occasionally
	-- appear ... Starting 1 Million Gold. Starting 1 Million Army and +1
	-- Million army size. Everyone starts with 10 Nukes"). Outside ORDER like
	-- historical, and for the same reason: ORDER is the every-round rotation,
	-- and these are meant to be found now and then. The public board deals ONE
	-- at a time, on any map, at Matchmaker.SPECIAL_CHANCE (measured there); a
	-- private room's MODE row lists them under ADVANCED (PrivateLobby.MODES);
	-- the owner's `/world <map> rich` and `/spawn <map> rich` take the ids.
	--
	-- Each is a free-for-all with ONE thing about the opening changed, and the
	-- change is stated HERE, in numbers, so the sim, the headless harness and
	-- the card all read the same table (Sim.applySpecial is the only writer).
	-- The figures are the owner's, and "everyone" means everyone: bots open on
	-- the same gold, the same army and the same warheads, or the mode is a
	-- handicap wearing a mode's name.
	rich = {
		NAME = "GOLD RUSH",
		SHORT = "1M GOLD",
		TEAMS = 0,
		WIN = 0.90,
		BLURB = "Everyone opens on 1,000,000 gold.",
		SPECIAL = { startGold = 1000000 },
	},
	horde = {
		NAME = "MEGA ARMY",
		SHORT = "1M ARMY",
		TEAMS = 0,
		WIN = 0.90,
		BLURB = "Everyone opens with a million troops, and a million more room to hold them.",
		SPECIAL = { startTroops = 1000000, troopCapBonus = 1000000 },
	},
	nuclear = {
		NAME = "NUCLEAR WAR",
		SHORT = "10 NUKES",
		TEAMS = 0,
		WIN = 0.90,
		BLURB = "Everyone opens with ten atom bombs in hand.",
		SPECIAL = { startNukes = 10 },
	},
	-- BLITZ (2026-09-18, the owner's pick from the second batch): every attack
	-- on the map moves at double speed, bots included. The field is the one
	-- the tutorial's Special Forces product sets (Sim.tilesPerTick scales an
	-- attack's per-tick tile budget by it, AFTER the strength clamp, and
	-- nothing else about the push changes), so the land arrives twice as
	-- fast and costs exactly what it always cost. MEASURED (2026-09-18, one
	-- 50% push into neutral land, same seed): +620 tiles in 2,000 ticks
	-- against +312 at 1x -- a front moves at exactly double speed. It does
	-- NOT halve the round: a bot's pace is its think cadence, not its front
	-- (21 bots held the same land at 600 ticks in both modes), so what the
	-- mode rewards is a PERSON who keeps pushing, and what it punishes is a
	-- defender who reacts slowly. The per-tick tile budget (Sim.tileBudget)
	-- still caps the whole map's pace, which is what keeps the server cost
	-- where it was.
	blitz = {
		NAME = "BLITZ",
		SHORT = "2X SPEED",
		TEAMS = 0,
		WIN = 0.90,
		BLURB = "Every attack moves at double speed.",
		SPECIAL = { attackSpeed = 2 },
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

-- Whether this mode starts from a predrawn map. See Scenarios.
function Modes.isHistorical(id: string?): boolean
	return Modes.get(id).HISTORICAL == true
end

-- The special opening, or nil on every ordinary mode. See the block over `rich`.
function Modes.special(id: string?): Special?
	return Modes.get(id).SPECIAL
end

function Modes.isSpecial(id: string?): boolean
	return Modes.get(id).SPECIAL ~= nil
end

-- The special ids, sorted -- the lobby's draw pool and the owner commands'
-- help line both walk this, so both ends agree on what "a special" is.
function Modes.specialIds(): { string }
	local ids = {}
	for id, m in Modes.BY_ID do
		if m.SPECIAL ~= nil then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
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
