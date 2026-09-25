--!strict
-- Conquest :: Config
-- Every tunable in one place. Shared by server sim and client renderer.

local Config = {}

-- ------------------------------------------------------------- version ----
-- Printed by ConquestServer on startup and on every round start. It exists
-- because "is my change actually running?" is otherwise unanswerable from
-- inside Studio: a script editor tab can show a stale buffer, the plugin VM
-- caches required modules across edits, and a parallel session can overwrite
-- a file between two of your own reads. A number in the output is the only
-- thing that survives all three.
--
-- BUMP THIS whenever you change gameplay code. It is not semantic and it is
-- not a build id -- it is a marker that says which edit is live.
Config.VERSION = 10

-- ---------------------------------------------------------------- map ------
-- One tile per pixel, one frame for every map. Must match UsMap.WIDTH/HEIGHT.
--
-- 1600x1000 until 2026-08-30. The frame is the only dial that moves land per
-- empire, and at 1.6M tiles a 72-empire US round handed every empire 12,572
-- tiles -- the 99th-100th percentile of upstream's 118 maps (see
-- LAND_PER_EMPIRE below, which MUST be rescaled alongside this). 880x550 is
-- 0.3025x the area, which puts the US at 3,795 and the whole rotation inside
-- upstream's own distribution. It also drops both axes under the 1024 runtime
-- cap on CreateEditableImage, so Renderer's ceil(W/900) x ceil(H/900) image
-- grid collapses from four tiles to one.
Config.MAP_W = 880
Config.MAP_H = 550
Config.NUM_TILES = Config.MAP_W * Config.MAP_H -- 484,000

-- There is NO fixed tile-index width on the wire. Net.packDelta groups a
-- tick's changes by new owner and delta-varints the sorted indices;
-- Net.packOwners is a varint run-length over the owner buffer. Both are
-- dimension-agnostic. A `Config.INDEX_BITS = 21` used to sit here and was read
-- by NOTHING -- and it was one of the two reasons Maps gave for locking every
-- map to 1600x1000, so half that justification never existed.

-- --------------------------------------------------------------- timing ----
Config.TICK_RATE = 10
Config.TICK_DT = 1 / Config.TICK_RATE

Config.SPAWN_PHASE_SECONDS = 20
Config.LOBBY_SECONDS = 5
-- Reference: nobody may be attacked until numSpawnPhaseTurns +
-- spawnImmunityDuration has passed. Measured from the end of spawn selection,
-- and it never covers unclaimed land, so the land grab still opens on tick
-- one -- this only stops an empire being deleted before its first income.
Config.SPAWN_IMMUNITY_SECONDS = 5
-- ------------------------------------------------------------------ navy ---
-- Transport ships. Upstream's numbers: a boat carries troops/5, an empire may
-- have boatMaxNumber() = 3 at sea, and the landing conquers its beachhead
-- tile outright before the attack it spawns begins.
--
-- STRIDE is the coarse water grid the route search runs on (see Navy). 8 is
-- 1/64 the search work and still resolves every strait the maps contain --
-- the four bridged straits (Dover, Gibraltar, Messina, Qiongzhou) are all
-- wider than one cell.
-- STAYS 8 THROUGH THE RIVER PASS, and that was measured rather than assumed.
-- Rivers made more than half of every map's coarse cells hold some water, so a
-- route can string together cells that clip DIFFERENT rivers and read as
-- navigable across dry land: on the walk a boat actually makes, stride 8 went
-- from 13-18% of its steps on land to 27-39%. A finer grid fixes that (6 gives
-- 20-31%, 4 gives 12-22%) and the water-preferring step in Sim.stepBoats fixes
-- it for free (14-19% at stride 8, i.e. back to what this game always had), so
-- the grid does not have to pay for it. Full match on europe: stride 8 worst
-- tick 88.7 ms, stride 6 worst tick 121.8 ms against a 100 ms budget, same
-- match length either way. The route search IS the tail here -- do not shrink
-- this without re-measuring the worst tick.
Config.NAVY_GRID_STRIDE = 8
Config.NAVY_SEARCH_LIMIT = 20000 -- coarse cells expanded before giving up
Config.NAVY_LANDING_SEARCH = 60 -- tiles to spiral out for a landable beach
Config.NAVY_SPAWN_SCAN = 6000 -- border tiles sampled for an embark point
Config.BOAT_TROOP_DIVISOR = 5 -- upstream boatAttackAmount: troops / 5
Config.BOAT_MAX_PER_PLAYER = 3 -- upstream boatMaxNumber()
Config.BOAT_SPEED = 3 -- tiles per tick
Config.BOAT_MIN_TROOPS = 250
Config.BOAT_LAND_RADIUS = 12 -- tiles from the beach at which troops go ashore
-- A route search is 2-23 ms on a 1600x1000 map. That is fine on a button
-- press and NOT fine 72 times a tick, so launches are rationed globally --
-- which also caps what a room full of people tapping the water can cost.
Config.BOAT_LAUNCHES_PER_TICK = 1
-- FINE water routes per tick, server-wide (Navy.channel): the tile-level path
-- between two coarse waypoints, which is what keeps a hull in the channel of a
-- river instead of on the bank beside it. Measured at 0.05-0.3 ms a leg on a
-- 30-tile window, and a leg lasts a boat three ticks -- so this is a ceiling
-- on how many transports may round a corner in the same tick, not a rate. Over
-- budget they steer straight for one tick, which is what they always did.
Config.BOAT_CHANNEL_PER_TICK = 8

-- ------------------------------------------------------------- warships ---
-- Upstream src/core/configuration/Config.ts:1085-1162, kept LITERAL.
-- SCALE NOTE, read before retuning: upstream's maps run to ~2900x1670 and
-- this one is 880x550, so a 130-tile threat radius covers several times more
-- of this map than of upstream's -- one warship threatens ~15% of the map's
-- width. The map-scaled equivalents would be roughly 44 and 57. Left literal
-- because the port is 1:1 by decision; change them together and measure.
Config.WARSHIP_PATROL_RANGE = 100
Config.WARSHIP_TARGET_RANGE = 130
-- NOT applied to transports: WarshipExecution.ts:638-641 skips the reload
-- entirely when the target is a TransportShip, so a warship shoots transports
-- at unlimited rate.
Config.WARSHIP_SHELL_ATTACK_RATE = 20
Config.WARSHIP_DOCKING_RANGE = 5
Config.WARSHIP_PORT_HEALING_PER_LEVEL = 5
Config.WARSHIP_RETREAT_HEALTH_PERCENT = 75
Config.WARSHIP_PASSIVE_HEALING = 1
Config.WARSHIP_PASSIVE_HEALING_RANGE = 150
Config.WARSHIP_PORT_SWITCH_THRESHOLD = 0.75
-- Two DIFFERENT knobs that happen to share the value 20: this one is the
-- shell-damage bonus per veterancy level (Config.ts:1142-1144); the health
-- bonus of the same size lives in Units.maxHealthWithVeterancy.
Config.WARSHIP_VETERANCY_SHELL_DAMAGE_BONUS = 20
Config.SHELL_LIFETIME = 50
Config.SAFE_FROM_PIRATES_TICKS = 20
-- Conquest-only pacing: upstream steps a warship once a tick on patrol, twice
-- while hunting, and a shell three times (ShellExecution.ts:48).
Config.WARSHIP_SPEED = 1
Config.WARSHIP_HUNT_SPEED = 2
Config.SHELL_SPEED = 3
-- Coarse route searches per tick, server-wide -- same rationing as
-- BOAT_LAUNCHES_PER_TICK. Measured at 0.02 ms for a patrol leg.
Config.WARSHIP_PATH_BUDGET = 2
Config.WARSHIP_PORT_CACHE_TICKS = 10
-- PRODUCTION. Conquest's own, and a DELIBERATE DEVIATION FROM UPSTREAM: ports
-- build hulls and nobody buys them. Upstream sells warships at
-- min(1e6, (n+1)*250,000) (Config.ts:460-468), and that escalating PRICE is
-- its only brake on fleet size. Removing the price removes the brake, so a
-- structural cap has to replace it -- hence PER_PORT and MAX_PER_PLAYER.
--
-- THE CEILING IS THE PORT COUNT, NOT THE SUM OF PORT LEVELS. One port, one
-- hull; ten ports, ten hulls -- and Config.TRADE_SHIPS_PER_PORT says the same
-- thing about trade ships, so "how many ships do I have" has ONE answer and it
-- is a number a player can read off their own coastline. Levels used to buy
-- hulls, which made the fleet a figure you could only find by opening each
-- harbour one at a time.
--
-- WHAT A LEVEL BUYS INSTEAD IS TEMPO. A port rolls for a trade ship once per
-- level, and repairs a docked hull PORT_HEALING_PER_LEVEL faster. So width of
-- coastline buys the fleet and depth buys the throughput, and the two ends of
-- a harbour pull in different directions instead of both meaning "more".
--
-- 600 ticks is not converted from the old price (500,000 gold was 5,000 ticks
-- of a whole empire's income -- a lifetime, not a build rate). It is read off
-- the COMBAT loop instead: a duel is 80-100 ticks and a full retreat-and-
-- repair cycle is 100-250, so replacement must be DEARER than repair or the
-- whole retreat/dock half of the module becomes dead code and you would
-- simply let a hurt hull sink. 600 is 2.4x the repair cycle. It also has to
-- fit a match, and the timer being PER PORT is what makes that work at the new
-- ceiling: an empire's harbours run their clocks in parallel, so three ports
-- both sustain three hulls AND fill that squadron in one 60-second timer
-- rather than three. The first hull lands 60s after a port finishes, so a port
-- visibly does something. At the ceiling the yard idles but the clock does NOT
-- bank, so a loss is always replaced a full timer later.
Config.WARSHIP_SPAWN_TICKS = 600
Config.WARSHIP_PER_PORT = 1
-- Upstream's own AI ceiling (AiAttackBehavior warship paths). It used to bind
-- before ports did -- STRUCTURE_MAX_LEVEL is 10, so ONE maxed harbour reached
-- it -- and under the count rule it takes ten separate harbours, which almost
-- nothing gets to. So read it as a safety valve on the vehicle stream rather
-- than a balance dial; PER_PORT is the dial.
Config.WARSHIP_MAX_PER_PLAYER = 10
Config.WARSHIP_SPAWN_PATROL_RADIUS = 50
-- Upstream rolls for a boat on every AI think: 1 in 5 when it has no land
-- enemy at all, 1 in 10 when it does.
Config.BOT_BOAT_CHANCE = 0.10
Config.BOT_BOAT_CHANCE_ISOLATED = 0.20
-- Two armies pointed at each other annihilate one for one before either takes
-- ground (reference AttackExecution.init). Switchable because it is the one
-- combat rule that can produce a stable cold war: A attacks B, B retaliates,
-- both armies vanish and no land moves.
Config.OPPOSING_ATTACKS_CANCEL = true

-- --------------------------------------------------------------- spawn -----
Config.SPAWN_TROOPS = 25000
Config.BOT_SPAWN_TROOPS = 18000 -- upstream startManpower: Nation/Medium 18,750, Bot 10,000
-- Upstream Config.minDistanceBetweenPlayers() = 30 (src/core/configuration/
-- Config.ts:709-711), measured in MANHATTAN distance
-- (SpawnExecution.ts:162-165), and dropped entirely after 750 of 1,000
-- placement tries (SpawnExecution.ts:26, :151).
Config.MIN_SPAWN_DISTANCE = 30 -- MANHATTAN tiles between any two spawn points
Config.SPAWN_RADIUS = 11 -- radius of the starting blob

-- ---------------------------------------------------------------- army -----
-- maxTroops = MULT * (tiles^EXP * COEF + BASE). Sublinear, so a small player
-- is dense and a large one is spread thin. Matches the reference game's
-- curve, because the combat constants below are calibrated against these
-- army sizes -- porting one without the other gives nonsense.
Config.BASE_MAX_TROOPS = 50000
Config.TROOPS_PER_TILE_COEF = 1000
Config.TROOPS_TILE_EXPONENT = 0.6
Config.MAX_TROOPS_MULT = 2

-- growth = (BASE + troops^EXP / DIV) * (1 - troops/max)
Config.GROWTH_BASE = 10
Config.GROWTH_EXPONENT = 0.73
Config.GROWTH_DIVISOR = 4
-- NERFED 2026-08-30 by owner decision, and note this is HALF OF WHAT WAS
-- ALREADY A HALF: upstream's filler Bot tier is x0.5 (Config.ts:956-958) and
-- this file already shipped that, so "AI gains troops at 50%" was already true
-- and setting 0.5 would have been a no-op. 0.25 is a real nerf on top.
-- This is a DELIBERATE DEVIATION from every upstream tier (Bot 0.5, Nation
-- 0.9/0.95/1.0/1.05 by difficulty) -- do not "restore" it to 0.5 as a port fix.
-- NERFED AGAIN 2026-08-30 (owner: "nerf AI troop generation by 50% more").
-- Another half off the 0.25 above, which was itself half of upstream's
-- already-halved filler Bot tier -- so an AI empire now earns an EIGHTH of
-- what a human empire earns per tick. See BOT_MAX_TROOPS_SCALE below: the
-- CEILING is deliberately left at 1.0, so this slows how fast a nation
-- refills, not how big its army can ever get.
Config.BOT_GROWTH_SCALE = 0.125
-- Upstream scales an AI's army ceiling by CLASS: its filler `Bot` gets
-- maxTroops/3 and income x0.5, its `Nation` gets x0.75 and x0.95 on Medium.
-- Our roster is one class sitting between the two -- a Nation's start
-- (18,000 vs upstream's 18,750) on a Bot's income (0.5) -- which is a
-- deliberate tuning for a 1.6M-tile map with 72 empires, not an oversight.
-- 1.0 leaves the ceiling alone; that combination is what every balance number
-- in this file was measured against. Change both scales together or not at all.
Config.BOT_MAX_TROOPS_SCALE = 1.0

-- -------------------------------------------------------------- attack -----
-- THREE PRESETS: NOT A SLIDER, AND NOT THE LADDER EITHER (2026-08-31). The
-- commit slider became an automatic ladder for a few hours and then became
-- this. The player picks again -- but from three buttons, not from a
-- continuous bar. A slider offers ninety-odd values that differ by nothing
-- anyone can feel, and puts the whole decision inside a knob you have to aim
-- at mid-war. Three buttons ARE the decision: probe, commit, or empty the
-- country.
--
-- This list is also the WHITELIST -- ConquestServer snaps an incoming ratio
-- to the nearest entry, so a crafted intent cannot ask for 100%.
Config.ATTACK_PRESETS = { 0.25, 0.50, 0.75 }

-- Half your army is the move you make most often, so it is the one nobody
-- should have to choose. It is also what an untouched HUD commits, which is
-- why it sits in the middle rather than at the cautious end.
Config.DEFAULT_ATTACK_RATIO = 0.50
Config.MIN_ATTACK_RATIO = 0.05
Config.MAX_ATTACK_RATIO = 1.0
Config.MIN_ATTACK_TROOPS = 250

-- Retreating from a player costs this share of the committed army.
-- Retreating from neutral land is free.
Config.RETREAT_PENALTY = 0.25

-- Per-terrain attack magnitude and speed, indexed by terrain type
-- (1 = plains, 2 = highland, 3 = mountain). MAG drives troop cost, SPEED
-- drives how much of the tick budget a tile consumes.
Config.TERRAIN_MAG = { 80, 100, 120 }
Config.TERRAIN_SPEED = { 16.5, 20, 25 }

-- ATTRITION. Per contested tile:
--
--   defenderDensity = defTroops / defTiles
--   ratioTerm       = clamp(defTroops / atkTroops, RATIO_MIN, RATIO_MAX)
--   pressureLoss    = ratioTerm * mag * MAG_SCALE * defenderSizeDebuff
--                                                 * attackerSizePenalty
--   densityLoss     = ALT_COEF * defenderDensity * (mag / 100)
--   attackerLoss    = BLEND * pressureLoss + (1 - BLEND) * densityLoss
--   defenderLoss    = defenderDensity            <-- density, NOT a multiple
--
-- The defender losing exactly their density per tile is the crux of how this
-- genre feels: an attack takes LAND while the defender keeps most of their
-- army and can counterattack. An earlier version here multiplied that by 8
-- and made attacks ~3x too cheap, so one push took 9x the land and wiped the
-- defender's army outright -- a completely different, much worse game.
Config.ATTACK_RATIO_MIN = 0.6
Config.ATTACK_RATIO_MAX = 2.0
Config.ATTACK_MAG_SCALE = 0.8
-- PORTED VERBATIM from the reference (DefaultConfig.attackLogic): the
-- attacker's loss per tile is the ratio term alone. The density blend that
-- used to sit here is not in the original -- it discounted a push into
-- thinly-held land twice over, since the ratio term already carries that, and
-- it made an attack cost roughly 60% of what the reference charges.
-- CORRECTED 2026-08-30. These two ARE upstream's, and removing them was a
-- mistake: an earlier build of this file dropped the density half on the
-- belief that it was a local invention, which made an attack cost roughly 60%
-- of what upstream charges. `openfrontio/OpenFrontIO`
-- (src/core/configuration/Config.ts, `attackLogic` lines 839-843) is
--     mag * (ATTACKER_LOSS_RATIO_WEIGHT * ratioTerm
--            + ATTACKER_LOSS_DENSITY_WEIGHT * defenderTroopLoss)
--     ATTACKER_LOSS_RATIO_WEIGHT = 0.48, ATTACKER_LOSS_DENSITY_WEIGHT = 0.0052
-- and this file's form expands to exactly that:
--     BLEND * MAG_SCALE            = 0.6 * 0.8   = 0.48
--     (1 - BLEND) * ALT_COEF / 100 = 0.4 * 1.3 / 100 = 0.0052
-- Do not "simplify" the blend away again. Check the numbers first.
Config.ATTACK_ALT_COEF = 1.3
Config.ATTACK_LOSS_BLEND = 0.6

-- Reference: `attacker is Human/FakeHuman and defender is Bot -> mag *= 0.8`.
-- Pushing into AI land costs a person 20% less per tile than pushing into
-- another person's, which is what makes eating a nation the cheap move and
-- invading a player the deliberate one.
-- Upstream `BOT_DEFENDER_LOSS_MULT` is 0.7, and it applies only when the
-- DEFENDER is upstream's weak filler `Bot` class. Our AI empires are named
-- nations tuned as upstream's `Nation`, not as `Bot`, so this is 1.0 (off) --
-- set it to 0.7 only if a weak filler tier is ever added. See the AI economy
-- block below.
-- THE PLAYER INVASION BONUS. A real player attacking any AI pays this
-- multiple of the normal troop cost per tile, so 0.5 means an invasion goes
-- twice as far on the same army.
--
-- This started as upstream's BOT_DEFENDER_LOSS_MULT (0.7, Config.ts:104),
-- which fires when a Human OR Nation attacks upstream's weak filler `Bot`
-- class. It is now a broader, deliberately un-upstream rule: the bonus keys on
-- the ATTACKER being a person, not on the defender being filler, and AI
-- attacking AI never gets it. Upstream's own tribe discount still lives on
-- Config.TIER[defender].DEFENDER_MULT and still applies to AI attackers.
-- RAISED 2026-08-30 (owner: "attack multiplier for players on AI 75% more").
-- The bonus is a COST multiplier, so 75% more attack means 1.75x the ground
-- per army: 0.5 / 1.75 = 0.2857. A player invading AI now pays about 29% of
-- the normal per-tile troop cost.
Config.HUMAN_VS_BOT_MAG = 0.2857

-- Unclaimed land is a flat fraction of the terrain magnitude (bots pay half).
Config.NEUTRAL_LOSS_DIVISOR = 5
Config.NEUTRAL_LOSS_DIVISOR_BOT = 10

-- A big defender defends slightly worse per tile; a big attacker attacks
-- slightly worse. Both are anti-snowball brakes.
Config.DEFENSE_DEBUFF_MIDPOINT = 150000
Config.DEFENSE_DEBUFF_HALFLIFE = 50000
-- The reference DOES have this; it is `largeDefenderDebuff` in upstream
-- `attackLogic`, written there as `1 - 0.3 * sigmoid(defenderTiles,
-- LN2/50000, 150000)`. FLOOR 0.7 makes this file's form identical:
-- 0.7 + 0.3*(1 - sigmoid) == 1 - 0.3*sigmoid. It scales BOTH troop loss and
-- tile cost, so a big defender really is easier to bite into.
Config.DEFENSE_DEBUFF_FLOOR = 0.7 -- debuff spans FLOOR .. 1.0
-- ONE threshold, both exponents off it -- upstream `LARGE_ATTACKER_TILES`
-- 100_000 (src/core/configuration/Config.ts:103),
-- `LARGE_ATTACKER_LOSS_EXPONENT` 0.35 (Config.ts:109) and
-- `LARGE_ATTACKER_COST_EXPONENT` 0.6 (Config.ts:110), applied together at
-- Config.ts:820-826. An earlier build of this file had a 75k threshold with a
-- single 0.5 exponent; that pair is not upstream's -- read
-- src/core/configuration/Config.ts before changing these. They are a
-- BONUS to a huge attacker, not a brake: past 100k tiles its tiles get both
-- cheaper in troops and cheaper in tick budget.
Config.LARGE_ATTACKER_TILES = 100000
Config.LARGE_ATTACKER_SPEED_TILES = 100000
Config.LARGE_ATTACKER_LOSS_EXP = 0.35
Config.LARGE_ATTACKER_SPEED_EXP = 0.6

-- Tick-budget cost of one tile. Contested tiles cost
--   clamp(defTroops / (SPEED_RATIO_DIV * atkTroops), SPEED_MIN, SPEED_MAX)
--     * terrainSpeed * debuffs
-- Unclaimed tiles cost clamp(NEUTRAL_NUM * max(10, speed) / atkTroops, .., ..)
-- which is why a large army sweeps empty land far faster than a small one.
Config.SPEED_RATIO_DIV = 5
Config.SPEED_RATIO_MIN = 0.2
Config.SPEED_RATIO_MAX = 1.5
Config.NEUTRAL_TILE_NUM = 2000
Config.NEUTRAL_TILE_MIN = 5
Config.NEUTRAL_TILE_MAX = 100
-- How hard terrain bites on the rate you claim UNCLAIMED ground.
-- 1.0 = upstream's own terrain ratios (plains 1.00, highland 1.21, mountain
-- 1.52); 0 = terrain-blind, which is what upstream effectively is here because
-- its neutral cost clamps to NEUTRAL_TILE_MIN for any army over 10,000 and
-- every empire starts with more than that. Raise it if mountains should read
-- as a real obstacle on the map rather than a 1.5x tax.
-- Terrain ALSO costs troops (TERRAIN_MAG 80/100/120) and pushes a tile later
-- in the frontier queue (FRONTIER_REF_MAG); this dial is only the RATE.
Config.NEUTRAL_TERRAIN_FACTOR = 1.0

-- Tiles a single attack may take per tick, from its frontier width.
--   vs player: clamp(SPEED_RATIO_DIV * atk / def * 2, .., ..) * border * 3
--   vs empty : border * 2
Config.BUDGET_RATIO_MIN = 0.01
Config.BUDGET_RATIO_MAX = 0.5
Config.BUDGET_PLAYER_MULT = 3
Config.BUDGET_NEUTRAL_MULT = 2

-- An empire ground below this share of the playable land collapses outright:
-- whoever broke it absorbs the remainder. Without a finisher, wounded players
-- survive forever as scattered pockets and no one can ever reach the win
-- threshold -- games stall at a ~30% leader with a dozen crippled survivors.
-- Expressed as a FRACTION so it keeps working if the map size changes; as a
-- fixed 120 tiles it would be 0.01% of this map and never fire in time.
-- Upstream AttackExecution.handleDeadDefender (src/core/execution/
-- AttackExecution.ts:428): `this.target.numTilesOwned() < 100`. A FLAT TILE
-- COUNT, not a share of the map -- upstream applies the same 100 on a
-- 651,569-tile World and a 2,345,907-tile Europe.
Config.DEAD_DEFENDER_TILES = 100

-- ------------------------------------------------------- terrain shaping --
-- Share of each map's LAND that should come out highland / mountain. MapGen
-- calibrates its elevation quantiles against these, so they hold across maps
-- of different relief instead of a fixed magnitude threshold.
--
-- RECONSTRUCTED: these were added by a parallel session whose Config I
-- accidentally overwrote. Values chosen to match the previously measured
-- 7-16% mountain / ~12% highland on the US map. Adjust if the original
-- author intended different proportions.
Config.TERRAIN_MOUNTAIN_FRACTION = 0.10
Config.TERRAIN_HIGHLAND_FRACTION = 0.16

-- The "hard ground" field MapGen.roughness builds: SCALE is its feature
-- size in tiles. It stretches frontier delay in Sim.enqueue, which is what
-- gives each region of a map its own character.
Config.FRONTIER_ROUGH_SCALE = 45

-- FRONTIER ORDERING -- which tile of its front an attack takes next. This is
-- the whole reason territory looks like a country rather than like a coin.
--
-- The heap holds a READY TIME (tick + delay), not a score. A score is
-- re-sorted globally on every push, so the front forever services whichever
-- tile is most enclosed ANYWHERE along it: a curvature-minimising flow that
-- irons every edge straight. With a time, a tile queued twenty ticks ago
-- goes before anything queued now, so the front advances as a wave -- and
-- the wave is free to be ragged.
--
--   delay = (DELAY_MIN + roll * DELAY_SPREAD) * base
--   base  = 1 - wrap * WRAP_RELIEF + terrain + roughness,  floored at BASE_MIN
--
-- The random factor is MULTIPLICATIVE and WIDE, and its width is the
-- edge-roughness dial. A small additive jitter sitting beside a large
-- compactness term is a rounding error -- which is exactly how territory
-- came out as near-perfect discs (bbox fill 0.68, perimeter 0.88x a circle,
-- measured on a solo unobstructed expansion).
Config.FRONTIER_DELAY_MIN = 0.3
Config.FRONTIER_DELAY_SPREAD = 5

-- "reference" runs the original expansion rule verbatim (see Sim.enqueue):
--   priority = (rand(0,7) + 10) * (1 - ownedCardinal * 0.5 + mag / 2) + tick
-- counted over the FOUR cardinal neighbours, on a shared world tick, with no
-- readiness gate -- an attack simply pops until its budget is spent.
-- "wave" is the variant this project grew instead (a 20-tile disc wrap count,
-- a per-attack clock and a readiness gate). It is kept because it is what the
-- current border look was tuned against; switching the string is how the two
-- get compared.
Config.FRONTIER_MODE = "reference"
-- The frontier's terrain magnitude is a DIFFERENT scale from the combat one:
-- 1 / 1.5 / 2, not 80 / 100 / 120 normalised. Feeding the combat numbers into
-- the frontier formula (1 / 1.25 / 1.5) silently halves the terrain term.
Config.FRONTIER_REF_MAG = { 1, 1.5, 2 }
-- WIDENED 2026-08-31 (owner: "expansion is too square, roll a dice on it").
-- MEASURED, solo unobstructed expansion on us/101, 20,092 tiles:
--   stock 10..17  bbox fill 0.997  <-- the empire IS its bounding box
--   6..20         0.797
--   3..23         0.707
--   2..32         0.656   (and 0.618 at 45k tiles, ragged 0.164)
-- The dice was ALREADY here and ALREADY about x0.7..x1.3 of its own mean --
-- that width is exactly what made the rectangles, not the absence of a roll.
-- What matters is the roll's RATIO (max/min), because it competes against the
-- wrap term, and the wrap term is a MULTIPLIER spanning 1.0 down to -1.0 as
-- the four cardinal neighbours fill in. A 1.7x roll cannot reorder a front
-- against a 2.0-wide multiplicative compactness term; a 16x roll can.
-- Note bbox fill is the ONLY metric that sees this: perimeter-vs-circle
-- (1.12x) and border/owned (2.8%) both read perfectly healthy while the map
-- was made of rectangles. Cost is nil -- same one LCG step per tile, and the
-- tick count to reach a given size was unchanged (153 -> 151).
-- DELIBERATE DEVIATION from the verbatim port above, which is rand(0,7)+10.
Config.FRONTIER_REF_SPAN_MIN = 2
Config.FRONTIER_REF_SPAN_SPREAD = 30
Config.FRONTIER_REF_WRAP_RELIEF = 0.5

-- Wrapping is the compactness term: a tile whose surroundings we already
-- hold comes up sooner, so pockets fill and the front leaves no holes.
-- Measured over a DISC (Sim.WRAP_OFFSETS), never the four cardinal
-- neighbours -- a cross metric is itself axis-aligned and the limit shape
-- of a flow that minimises it is a rectangle, whatever noise is added.
Config.FRONTIER_WRAP_RELIEF = 0.55

-- Terrain is the tie-breaker, never the driver. When terrain outweighed
-- compactness the front chased cheap plains across the map and left every
-- highland tile behind as a permanent hole.
Config.FRONTIER_TERRAIN_PENALTY = 0.5

-- Regional character: the smooth hard-ground field stretches the delay by
-- plus or minus half of this, so a front bulges through soft country.
Config.FRONTIER_ROUGH_STRETCH = 1.6

-- However wrapped, cheap and soft a tile is it still waits this fraction of
-- its delay. Also the bound the lazy decrease-key prunes against.
Config.FRONTIER_BASE_MIN = 0.12

-- Ticks of an attack's OWN clock per real tick, per unit of the rate its
-- budget already grants it. The clock is what makes the delays above
-- real: a tile is not available until its time has come, however much
-- budget is left, and that is what stops a wide budget from swallowing
-- the whole front each tick and averaging the randomness away.
--
-- It has to be PER ATTACK rather than the world tick, or every push
-- advances at the same rate whatever army is behind it -- which erases
-- the strong-attacker lever entirely and drags matches out (measured:
-- 14.3 min at 55% against a 10.5 min target).
Config.FRONTIER_PACE = 0.56

-- Global safety valve: total tiles conquered per tick across all attacks.
-- MEASURED over 6,000 ticks of a 72-empire FFA on the US map: mean 421 tiles
-- per tick. The only tick that came near this number was the SPAWN tick
-- (26,385), which is blob placement and is not gated by this at all. So this
-- is a ceiling that never binds in play -- DO NOT TUNE PACING WITH IT. What
-- actually paces the land grab is the per-attack budget (border * 2 against
-- empty ground) and the troop cost of a tile.
Config.GLOBAL_TILE_BUDGET = 14000

-- Sim scales the ceiling by (playableLand / this) per round. Since the
-- ceiling never binds, the scaling is inert too: measured 98%-claimed times
-- were 1.2 min on china (477,436 playable), 1.6 min on us (905,215) and
-- 1.8 min on medit (1,116,063) -- sub-linear in land, and the spread comes
-- from FRONT WIDTH, not from this. The old claim here that a fixed budget
-- would make the largest map take 2.4x as long to fill is not what happens.
-- Kept because it costs nothing and would matter if the roster ever grew.
-- Live playable land on us is 905,215, so this carries 30 tiles of drift.
Config.TILE_BUDGET_REFERENCE_LAND = 905185
Config.TILE_BUDGET_MIN = 4000

-- ------------------------------------------------------------- scaling ----
-- Everything below is about holding a full 24-player server at 10 ticks a
-- second. The sim cost is roughly linear in LIVE EMPIRES x FRONT WIDTH, and
-- both of those grow all round, so the numbers that matter are the ones that
-- stop per-tick work from being unbounded.

-- Bots FILL to this roster rather than being added on top of the humans. A
-- flat +12 meant a full server ran 36 empires: 36 border sets for the AI to
-- sample, 36 income entries, 36 rows in every summary, and a proportionally
-- larger attack list walked several times per tick.
--
-- 72 is the design target: a FULL server is 24 players and 48 AI nations.
-- Because bots fill rather than stack, an empty server runs the same 72
-- empires a full one does, so the cost of a round -- and its balance -- does
-- not depend on how many people showed up. Every empire is per-tick work all
-- round, so this is the single biggest performance dial in the game; see
-- /simulate (ServerScriptService.ConquestSimulate) before moving it.
Config.TARGET_EMPIRES = 72

-- ...but 72 is now a CEILING, not the roster. Upstream sizes a lobby off the
-- map's land tiles, never off a constant: MapPlaylist.ts:812-825 is "for every
-- 1,000,000 land tiles, take 50 players", read out of each map's manifest by
-- MapLandTiles.ts:45-59 -- and when it replays a map at a QUARTER of its area
-- it takes a quarter of the bots (400 -> 100), a quarter of the humans and a
-- quarter of the nations, while changing NO distance constant at all.
--
-- Conquest's rotation spans 144,109 (china) to 337,848 (medit) playable
-- tiles, so a flat 72 turned a 2.34x spread in map size into a 2.34x spread in
-- how much ground one empire has to eat. Measured at 10 minutes with 72 AI on
-- the old 1600x1000 frames: leader 29.2% / 6 alive on china, 21.2% / 8 on us,
-- 25.4% / 13 on medit.
--
-- The roster is playableLand / this, clamped to [MIN_EMPIRES, TARGET_EMPIRES].
-- The value is the US map's own figure (273,226 / 72), so the map every
-- balance constant was swept against keeps a full roster and only the others
-- move.
--
-- Upstream's land per empire across its 118 maps is min 458, p25 1,927,
-- median 2,587, p75 3,664, max 7,796. Conquest used to sit at the 99th-100th
-- percentile of that on EVERY map in the rotation -- 12,572 on the US. The fix
-- was the FRAME and not this number: at 880x550 the rotation lands at us 3,795
-- / china 3,792 / europe 3,852 / medit 4,692, between upstream's p75 and its
-- max. So THIS CONSTANT HAS TO TRACK MAP_W x MAP_H. Left at 12572 the shrink
-- would be inert -- every map falls to MIN_EMPIRES and land per empire comes
-- straight back out at ~11,400.
Config.LAND_PER_EMPIRE = 3795
Config.MIN_EMPIRES = 24

-- Re-seeding an attack walks the attacker's ENTIRE border. Reinforcing does
-- not need it -- conquest enqueues each newly exposed neighbour as it goes --
-- so it is only worth redoing when the front has drained, or occasionally to
-- pick up contact opened by somebody else's conquest. Without this cap a
-- player tapping at the intent rate limit costs a full border scan eight
-- times a second, each, and 24 of them can bury the server on their own.
Config.RESEED_TICKS = 20

-- Opening a NEW front is the one attack path that cannot be throttled by
-- RESEED_TICKS -- it has to seed from scratch. Capping how many a single
-- empire may hold open at once is what stops a player alternating targets at
-- the intent rate limit from forcing a fresh border scan eight times a
-- second. Reinforcing a front you already hold is never blocked by this.
--
-- FOUR (2026-08-31, was three). Owner's call: three was a tighter leash than
-- the map asks for -- a mid-game empire regularly borders four rivals at once
-- and could not answer all of them. The commitment ladder above grows with
-- this number on its own, so the fourth front costs 40% and needs no second
-- constant. The cost is one more possible seedFrontier border walk per
-- player; BOT_MAX_FRONTS (2) is separate and unchanged, so the NPC roster
-- does not get a third of a scan each.
Config.MAX_FRONTS_PER_PLAYER = 4

-- Absorbing a broken empire is a scan of the whole map for its colours. Done
-- in one tick that is ~15 ms AND dumps tens of thousands of tiles into a
-- single delta frame (measured peak: 13,572 tiles = 54 KB to every client at
-- once). The victim is dead the instant it is called, so spreading the land
-- transfer over the next second is invisible and costs nothing.
Config.COLLAPSE_SCAN_PER_TICK = 250000
Config.COLLAPSE_TILES_PER_TICK = 2500

-- ---------------------------------------------------------------- bots -----
-- Ceiling on AI empires, not a quota: the roster is filled to
-- TARGET_EMPIRES and this only caps the fill. At 72 it never binds, which is
-- what makes a solo playtest the same match a full server plays.
Config.NUM_BOTS = 72
Config.BOT_THINK_TICKS = 60 -- reference: every 40-80 ticks (4-8 s)
-- Bots run two distinct phases -- LAND GRAB then BOXED IN -- and each gets its
-- own reserve and commitment, because they are not the same decision.
--
-- LAND GRAB. Unclaimed ground is strictly cheaper than a war (bots pay half of
-- an already-small NEUTRAL_LOSS_DIVISOR for it), so while ANY open tile still
-- touches the empire the bot takes it and considers nothing else. The reserve
-- here is deliberately low: a bot spawns with BOT_SPAWN_TROOPS against a pool
-- sized by its starting blob, so the old shared 0.35 gate left every bot
-- standing still for the first ~30 seconds of the round with the map wide open.
Config.BOT_EXPAND_RESERVE_RATIO = 0.10
Config.BOT_EXPAND_ATTACK_RATIO = 0.70
Config.BOT_MAX_FRONTS = 2 -- expansions may stack two deep; a war may not

-- BOXED IN. Once a bot's whole frontier is other empires it stockpiles to a
-- much larger share of its pool, then only OCCASIONALLY commits -- one war at
-- a time, against a neighbour it is already sitting beside.
Config.BOT_WAR_RESERVE_RATIO = 0.35
Config.BOT_DECLARE_ATTACK_RATIO = 0.85 -- the whole point of stockpiling
Config.BOT_ENGAGE_CHANCE = 0.35 -- per think, once stocked and off cooldown
Config.BOT_WAR_COOLDOWN_TICKS = 60 -- ~6s between declarations

-- ...and once declared, the war gets the income. An unreinforced push spends
-- its army without breaking anyone -- the defender regrows what it lost, so
-- attrition alone never resolves anything and matches run past the time
-- limit with everyone still alive. Measured: without this, 13 bots on the US
-- map sat at 13/13 alive and a 16% leader at 25 minutes.
Config.BOT_ATTACK_RATIO = 0.60 -- per think, poured into the running war
Config.BOT_WAR_SUSTAIN_RATIO = 0.12 -- floor it keeps at home while fighting

-- The boxed-in test samples the border rather than walking it, so it needs
-- hysteresis: one unlucky sample that misses the last sliver of open ground
-- must not start a war. BOT_BORDER_SAMPLE tiles per look, from a random
-- offset -- a fixed start re-reads the same head of the set every think, and
-- a boxed-in empire's border barely changes.
Config.BOT_BOXED_CONFIRMS = 4
-- 1200 was ~2 ms of scanning per think: 1200 border tiles, each costing a
-- neighbour lookup and four passability checks, over scattered cache lines.
-- There is no trick that makes those calls cheap -- the lever is making
-- fewer of them, and the resumable cursor is what makes that free. Each
-- think now reads a shorter stretch, but successive thinks continue from
-- where the last stopped, so a bot still sweeps its whole frontier; it just
-- takes a few more thinks to get round. BOXED_CONFIRMS is raised to match,
-- since each individual look now sees less of the border.
Config.BOT_BORDER_SAMPLE = 300

-- ------------------------------------------------- NPC combat (reference) --
-- The reference AI (BotExecution + BotBehavior) is three gates, and every one
-- of them is a share of maxTroops rather than of the army on hand:
--   expandRatio  0.10-0.20  reserve kept back when taking UNCLAIMED land
--   reserveRatio 0.30-0.40  reserve kept back when attacking a PLAYER
--   triggerRatio 0.50-0.60  the level it must reach before picking a fight
-- and what it commits is everything ABOVE the relevant reserve, never a
-- fraction of what it holds. That difference is most of why AI pushes here
-- used to arrive already spent: a fraction of a small army is a small army.
Config.BOT_TRIGGER_RATIO = 0.55
Config.BOT_TRIGGER_SPREAD = 0.091 -- 0.50 .. 0.60
Config.BOT_EXPAND_RESERVE_SPREAD = 0.333 -- 0.10 .. 0.20
Config.BOT_WAR_RESERVE_SPREAD = 0.143 -- 0.30 .. 0.40

-- forgetOldEnemies(): an enemy once chosen is kept for 100 ticks and attacked
-- again on EVERY think in between. Sustained pressure is the whole mechanism
-- -- a push that is not reinforced always loses to the defender's regrowth.
Config.BOT_ENEMY_FORGET_TICKS = 100

-- shouldAttack() (AiAttackBehavior.ts:849-871). CORRECTED: 0.25 is upstream's
-- EASY value, NOT "the reference's default difficulty" as this comment used to
-- claim. Both branches are written as REFUSALS, which is what makes them easy
-- to read backwards:
--   Easy   :864  nextInt(0,4) ~= 0 -> refuse 3 times in 4  => attacks 25%
--   Medium :867  chance(4)         -> refuse 1 time in 4   => attacks 75%
--   Hard / Impossible                                      => attacks 100%
-- and the whole function short-circuits to true when the ATTACKER is a Bot
-- (:856), so upstream's filler tribes never hesitate at any difficulty.
-- Upstream's public rotation runs Medium (MapPlaylist.ts:200-201); Hard is for
-- HumansVsNations only, and isHardNations is 1 ticket in 34 of the special
-- modifier pool (MapPlaylist.ts:89).
--
-- This constant is now only the TIER_LEGACY value. What a bot actually rolls
-- against is Config.TIER[tier].ATTACK_HUMAN_CHANCE. Left at 0.25 so
-- TIER_LEGACY reproduces what this game shipped, bit for bit.
Config.BOT_ATTACK_HUMAN_CHANCE = 0.25

-- selectEnemy(): below the trigger ratio an AI still commits one think in
-- ten, so a stalemated border is never perfectly quiet.
Config.BOT_TRIGGER_BYPASS_CHANCE = 0.10

-- checkIncomingAttacks(): whoever has the largest army pointed at us becomes
-- the enemy, bypassing every "should I attack them" check. An AI that ignores
-- being invaded is the loudest possible tell that it is not a person.
Config.BOT_RETALIATE = true
-- ------------------------------------- upstream strategy ladder (ported) --
-- Upstream picks a strategy ORDER per difficulty
-- (src/core/execution/utils/AiAttackBehavior.ts:363-378) and gates two
-- restraint rules to Hard and above. Conquest has no difficulty setting, so
-- one flag chooses between the two projections we can actually express:
--   false -> MEDIUM (:369) = retaliate, weakest, island
--   true  -> HARD   (:372) = retaliate, veryWeak, victim, weakest, island
--            plus troopSendCap (:910-919) and isAttackTooWeak (:885-889)
-- Everything else in those arrays -- bots, nuked, assist, betray, traitor,
-- hated, afk, donate -- needs a system this game does not have yet, and is
-- omitted rather than faked. See the deviation table in Sim.botThink.
Config.BOT_TIER_HARD = false

Config.BOT_TOO_WEAK_RATIO = 0.20 -- isAttackTooWeak (AiAttackBehavior.ts:888)
Config.BOT_RETAIN_FRACTION = 0.75 -- troopSendCap, Hard (:912); Impossible is 0.9
Config.BOT_VERY_WEAK_RATIO = 0.15 -- findVeryWeakEnemy, share of their OWN max (:601)
Config.BOT_VICTIM_PRESSURE_RATIO = 0.50 -- findVictim, incoming vs their army (:590)
Config.BOT_FFA_STRENGTH_MARGIN = 1.2 -- the shared FFA "not much stronger than us" margin (:582, :602)
Config.BOT_ISLAND_SECOND_CHANCE = 1 / 3 -- findNearestIslandEnemy takes the 2nd candidate on chance(3) (:682)

-- ------------------------------------------------------------ bot variance --
-- Every BOT_ constant above is the MEAN of a bot's behaviour, not the
-- behaviour itself. Each bot rolls its own values off these spreads once, in
-- Sim.addPlayer, and never re-rolls them: the point is that a nation behaves
-- CONSISTENTLY. A bot that re-rolls its aggression every think reads as one
-- erratic AI rather than as twelve different ones.
--
-- Without this the whole roster is a single oscillator. Income is
-- deterministic and every bot shares one reserve gate, so they all cross their
-- attack threshold on the same period -- only the starting offsets differ, and
-- identical periods stay phase-locked forever. The map visibly pulses.
--
-- BOT_THINK_SPREAD is the load-bearing one. Different think PERIODS, not just
-- different offsets, is what stops them drifting back into step.
Config.BOT_THINK_SPREAD = 20 -- reference rand(40, 80); think period varies by +/- this
Config.BOT_RESERVE_SPREAD = 0.45 -- +/- fraction on both reserve gates
Config.BOT_RATIO_SPREAD = 0.25 -- +/- fraction on how much they commit
Config.BOT_ENGAGE_SPREAD = 0.60 -- +/- fraction on the per-think war roll
Config.BOT_COOLDOWN_SPREAD = 0.40 -- +/- fraction on declaration cooldown

-- Jitter applied to the reserve gate on EVERY think, on top of the per-bot
-- roll. Without it a single bot still fires at exactly the same troop level
-- every cycle, so its own attacks come out evenly spaced even once its
-- neighbours' no longer are.
Config.BOT_GATE_JITTER = 0.12

-- Chance a bot does nothing at all on a given think. The cheapest possible
-- decorrelation, and it reads as hesitation rather than as a machine.
Config.BOT_IDLE_CHANCE_MAX = 0.12

-- How sharply a bot prefers the weakest neighbour when it picks a war. 1.0 is
-- the old behaviour; below 1 it barely discriminates and chooses close to at
-- random, above 1 it hunts the wounded. Rolled per bot, so some nations are
-- opportunists and some are indiscriminate.
Config.BOT_FOCUS_MIN = 0.35
Config.BOT_FOCUS_MAX = 2.0

-- ------------------------------------------------------------- economy -----
-- EVERY NUMBER IN THIS BLOCK IS PORTED FROM **openfrontio/OpenFrontIO**,
-- `src/core/configuration/Config.ts`. That file is the reference for all the
-- NON-COMBAT math in this game.
--
-- RE-PORTED 2026-08-30 against upstream HEAD. An earlier build of this block
-- carried an older set of economy numbers: a STRAIGHT-LINE trade payout, train
-- gold with a (level + 1) station multiplier, 25,000 for a stop on your own
-- network, equal gold income for AI and human, and shorter rail ranges. None
-- of those is upstream's -- see src/core/configuration/Config.ts lines 423-429
-- (tradeShipGold), 388-411 (trainGold), 982-991 (goldAdditionRate) and 413-421
-- (rail ranges). Every number below was re-read from that file; verify against
-- it before changing any of them. Both games tick at 10 Hz, so per-tick figures
-- transfer with no rescaling -- check that first if upstream is ever re-read.
--
-- Upstream functions behind this block, for anyone diffing it later:
--   goldAdditionRate()      bots 50n, everyone else 100n, per tick
--   cityTroopIncrease()     250_000, PER LEVEL, and only for CITIES
--   unitInfo(City|Port)     min(1_000_000, 2^n * 125_000)
--   constructionDuration    city 2*10 ticks, port 5*10
--   structureMinDist()      15
--   radiusPortSpawn()       20
--   tradeShipGold()         sigmoid, see below
--   tradeShipSpawnRate()    pity timer, see below
--   trainStationMinRange()  15      trainStationMaxRange() 110
--   railroadMaxSize()       maxRange * 1.4142
--   trainSpawnRate()        (factories + 10) * 15
--   trainGold()             self 10k / team 25k / ally 35k, decaying
--   conquerGoldAmount()     all of an AI's treasury, HALF of a human's

-- Flat, and deliberately NOT scaled by territory. The territorial snowball
-- already runs through troops; gold is the one resource that does not
-- compound, which is what makes the FIRST city an even trade for everyone and
-- the fourth a genuine cost. Do not "fix" this by making it proportional to
-- land -- that hands the leader the buildings as well.
-- Upstream's `goldMultiplier()` -- a LOBBY SETTING there, applied inside
-- goldAdditionRate, tradeShipGold and trainGold and nowhere else
-- (Config.ts:952-958, :361-367, :326-349). It is the only sanctioned dial on
-- the size of the economy: every other number in this block is a ported
-- constant and moving one of those changes the SHAPE.
--
-- At 1.0 a measured 30-minute 69-empire match on us/101 creates 2.3 BILLION
-- gold, of which about half is spent; the rest sits in treasuries because the
-- most expensive thing an AI buys is a 1M structure or a 5M hydrogen bomb.
-- Turn this down if gold should stay scarce for longer; it scales income and
-- leaves the trade-vs-rail-vs-base split exactly where it is.
Config.GOLD_MULTIPLIER = 1.0

Config.GOLD_PER_TICK = 100
-- Upstream halves an AI empire's income. Without this the whole bot roster
-- funds itself exactly as fast as a person does.
Config.GOLD_PER_TICK_BOT = 50

-- An AI hands over its whole treasury when it is absorbed; a HUMAN only half.
-- Taking a person's land, cities and ports is already the biggest prize on the
-- map, and paying full price for the treasury on top made hunting the one
-- human in reach strictly better than any other war.
Config.CONQUER_GOLD_HUMAN_SHARE = 0.5

-- Cities and ports share ONE cost ladder: min(CAP, GROWTH^built * BASE), so
-- 125k / 250k / 500k / 1M / 1M... The choice between them is never about
-- price, it is about whether you would rather have 250,000 troops or a trade
-- route. PORTS GIVE NO TROOPS.
Config.CITY_COST_BASE = 125000
Config.CITY_COST_GROWTH = 2
Config.CITY_COST_CAP = 1000000
Config.PORT_COST_BASE = 125000
Config.PORT_COST_GROWTH = 2
Config.PORT_COST_CAP = 1000000

-- Added to the troop ceiling per LEVEL of every CITY an empire owns -- so a
-- captured city is worth exactly what a built one is. Sits OUTSIDE
-- MAX_TROOPS_MULT and outside the AI handicap, matching upstream:
--   2 * (tiles^0.6 * 1000 + 50000) + sum(cityLevel) * 250000
Config.CITY_TROOP_INCREASE = 250000

Config.CITY_BUILD_TICKS = 20 -- 2 seconds
Config.PORT_BUILD_TICKS = 50 -- 5 seconds; upstream makes a port slower to raise
Config.FACTORY_BUILD_TICKS = 20 -- 2 seconds, same as a city (Config.ts:508-518)
Config.STRUCTURE_BUILD_TICKS = Config.CITY_BUILD_TICKS
Config.STRUCTURE_MIN_DIST = 15 -- tiles between any two buildings

-- ---------------------------------------------------------- factories -----
-- `unitInfo(Factory)`. THE FACTORY SHARES THE PORT'S COST LADDER -- upstream
-- puts Port and Factory in each other's cost pool (Config.ts:418-428 and
-- :508-518), so your first factory is priced as if it were your next port and
-- doubles the price of the port after it. It is not a cheap unlock bolted
-- onto a port network; it competes with one.
--
-- WHAT IT DOES: nothing on its own. A factory is the only building that
-- DISPATCHES trains, and every city or port within STATION_MAX_RANGE of one
-- becomes a station when it goes up. It is never itself a paying stop.
Config.FACTORY_COST_BASE = Config.PORT_COST_BASE
Config.FACTORY_COST_GROWTH = Config.PORT_COST_GROWTH
Config.FACTORY_COST_CAP = Config.PORT_COST_CAP

-- Clicking within STRUCTURE_MIN_DIST of one of your OWN buildings of the SAME
-- KIND upgrades it instead of refusing. Upstream prices an upgrade off
-- `min(owned, constructed)`, so upgrading does NOT raise the price of your
-- next building -- levelling one and spreading four are the same spend.
Config.CITY_MAX_LEVEL = 10
Config.STRUCTURE_MAX_LEVEL = Config.CITY_MAX_LEVEL

-- ------------------------------------------------------------ ports -------
-- `unitInfo(Port)` is the SAME cost curve as a city, and that is the point:
-- the choice between them is never about price, it is about whether you would
-- rather have 250,000 troops or a trade route. Ports give NO troops.
Config.PORT_COST_BASE = 125000
Config.PORT_COST_GROWTH = 2
Config.PORT_COST_CAP = 1000000

-- `radiusPortSpawn()`. A port must stand on the coast, and at low zoom the
-- coast is a line a player cannot click precisely -- so a click near the sea
-- SNAPS to the nearest owned coastal tile. Without this, placing a port is a
-- pixel-hunt rather than a decision.
Config.PORT_SPAWN_RADIUS = 20

-- ------------------------------------------------------- trade ships ------
-- Upstream `tradeShipGold(dist, player)`
-- (src/core/configuration/Config.ts:423-429). It is a SIGMOID, not the
-- straight line an earlier build of this file had:
--
--   75000 / (1 + e^(-0.03 * (dist - 300)))  +  50 * dist
--
-- The midpoint IS the short-range debuff, so a hop of a hundred tiles earns a
-- small fraction of the plateau while an ocean crossing earns nearly all of
-- it. That shape is the whole design -- trade is meant to be worth crossing
-- an ocean for, and shuttling between two ports on the same bay is not. There
-- is no bonus for owning many ports any more.
Config.TRADE_GOLD_SIG_MAX = 75000
Config.TRADE_GOLD_SIG_K = 0.03
Config.TRADE_GOLD_PER_TILE = 50
Config.TRADE_SHORT_RANGE_DEBUFF = 300

-- `tradeShipSpawnRate(rejections, numTradeShips)`: rate = 100 / (1 +
-- rejections) / (1 - sigmoid(ships, ln2/50, 400)), rolled once per port LEVEL
-- every TRADE_CHECK_TICKS. Two brakes in one -- a GLOBAL one that tightens as
-- the sea fills up, and a per-port PITY TIMER that loosens every time a port
-- rolls and misses. The pity half is what stops a lone port on a quiet map
-- from waiting forever.
Config.TRADE_CHECK_TICKS = 10
Config.TRADE_SPAWN_SCALE = 100
Config.TRADE_SPAWN_DECAY = 0.013862943611198906 -- ln(2) / 50
Config.TRADE_SPAWN_MID = 400

-- HOW MANY OF YOUR OWN HULLS MAY BE AT SEA AT ONCE: one per COMPLETED port,
-- the same rule and the same counter the navy uses (WARSHIP_PER_PORT). The
-- rates above are untouched and still decide WHEN a ship sails -- a port rolls
-- once per LEVEL -- so depth buys tempo and width buys the fleet, exactly as
-- on the warship side.
--
-- Note what this does to the global crowding brake above: the sea can now hold
-- no more hulls than the world has finished ports, so TRADE_SPAWN_MID is no
-- longer what bounds the vehicle stream. Left in place because it is
-- upstream's and it still shapes a busy sea, but it is not the ceiling any
-- more -- if trade traffic needs cutting, cut it HERE.
Config.TRADE_SHIPS_PER_PORT = 1

-- Tiles a trade ship covers per tick, as upstream (one path step per tick). At
-- this map's scale a long crossing is a genuine two-minute voyage, which is
-- what makes a ship on the water something worth looking at.
Config.TRADE_SHIP_SPEED = 1

-- `proximityBonusPortsNb(total) = clamp(total/3, 4, total)`: the nearest third
-- of the world's ports (at least four) count double when a port picks who to
-- trade with -- but only if they are FURTHER than the short-range debuff, so
-- the bonus never pushes a ship onto a route the payout curve punishes.
Config.PROXIMITY_PORTS_MIN = 4

-- --------------------------------------------------------- rail + trains --
-- A city or port is a train station only if a FACTORY stands within
-- STATION_MAX_RANGE of it, and only a factory dispatches trains. That is
-- upstream's rule and it is now this game's too -- the deviation this comment
-- used to describe (every structure a station, every station dispatching) was
-- measured at 3,570 simultaneous trains and 96% of all gold created in a
-- 30-minute match. See the note above Economy.stepStations.
--
-- A new station connects to nearby stations NEAREST FIRST, and only where the
-- two are not already within RAIL_MAX_CONNECTION_HOPS of each other through
-- the rails. That second rule is what makes the result look like a railway
-- instead of a complete graph.
Config.STATION_MIN_RANGE = 15 -- trainStationMinRange
Config.STATION_MAX_RANGE = 110 -- trainStationMaxRange
Config.RAIL_MAX_TILES = 156 -- railroadMaxSize = maxRange * 1.4142
Config.RAIL_MAX_CONNECTION_HOPS = 4 -- RailNetworkImpl.maxConnectionDistance

-- `trainSpawnRate(numPlayerFactories) = (factories + 10) * 15`, rolled once
-- per FACTORY level per tick, with a hard cooldown between departures. Keyed
-- on the owner's factory count (summed over levels, upstream's `unitCount`),
-- not on the size of the network, so a sprawling rail map does not generate
-- traffic in proportion to itself -- one empire's whole output is set by what
-- it has spent on factories.
--
-- More factories make each individual roll LESS likely (the +10 midpoint is a
-- hyperbolic decay); what raises output is that there are more rolls. An
-- empire with one level-1 factory rolls 1-in-165 a tick, so a train roughly
-- every seventeen seconds.
Config.TRAIN_SPAWN_BASE = 10
Config.TRAIN_SPAWN_MULT = 15
Config.TRAIN_COOLDOWN_TICKS = 10
Config.TRAIN_SPEED = 2 -- tiles per tick

-- How many newly promoted stations may be JOINED to the network per tick.
-- connectStation runs a land A* per candidate and was measured at 28 ms for
-- one station; a factory promoting eight neighbours at once would be a
-- quarter-second freeze. The rails appear over the next few ticks instead,
-- which nobody can see.
Config.STATION_LINKS_PER_TICK = 1

-- `trainGold(rel, stopsVisited)`, paid at EVERY stop on the route. A stop on
-- your OWN network pays the least and pays ONCE; a stop at somebody else's
-- pays more and pays BOTH sides. There is no station-level multiplier.
--
-- This is the biggest single correction in this block. An earlier build of
-- this file paid 25,000 x (level + 1) to both sides even on your own network
-- -- five times as much per stop, and it made rail 85% of all the gold on the
-- map. Read Config.ts:388-411 and TrainStation.ts:15-40 before touching these.
Config.TRAIN_GOLD_SELF = 10000
Config.TRAIN_GOLD_TEAM = 25000
Config.TRAIN_GOLD_OTHER = 25000
Config.TRAIN_GOLD_ALLY = 35000 -- unused until alliances exist
-- The first stops are free; past that each one is worth 5,000 less, floored.
-- A train circling a large network stops paying for it.
Config.TRAIN_GOLD_FREE_STOPS = 9
Config.TRAIN_GOLD_DECAY = 5000
Config.TRAIN_GOLD_FLOOR = 5000

-- How often a bot with the money considers spending it, and how far from its
-- own centre it will look for somewhere legal to put the thing. Cities are
-- placed inland on purpose: one on the frontier changes hands within the
-- minute and the gold is simply gone. Ports are the exception -- they have to
-- be on the coast, so a bot aims at its own shoreline instead.
Config.BOT_BUILD_CHANCE = 0.25
Config.BOT_BUILD_PROBES = 20
-- Share of a bot's purchases that are ports rather than cities. Below 0.5
-- because a city raises the troop ceiling, which is the thing a bot can
-- actually use; a port pays out only if somebody else has one too.
Config.BOT_PORT_SHARE = 0.35
--
-- SUPERSEDED, and left only because another session may still read it: WHICH
-- building a bot buys is no longer a coin flip. Sim.botBuild now ports
-- upstream's NationStructureBehavior, which keeps a ratio PER CITY of every
-- other structure (port 0.75, factory 0.75 x0.33 if coastal, SAM 0.2, silo
-- 0.2 with the first at 0.4 and a cap of three) and falls back to another
-- city. See the constants at the top of that function.

-- Whether AI empires buy MISSILE SILOS and SAM LAUNCHERS at all. This is the
-- only real gold SINK in the game -- a city, port or factory is capped at
-- 1,000,000 and a silo is 1,000,000 with nukes at 750k / 5M / 25M behind it,
-- so with this off a large empire's treasury simply grows without limit and
-- the whole Nukes module is unreachable (Nukes.aiThink returns immediately
-- unless the empire owns a silo). Turning it off restores the pre-2026-08-31
-- behaviour exactly.
Config.BOT_BUILDS_DEFENCES = true

-- ------------------------------------------------------- player nukes -----
-- DELIBERATE DEVIATION FROM UPSTREAM, owner's call 2026-08-31.
--
-- Upstream will only let a nuke leave a MISSILE SILO you have built
-- (PlayerImpl.nukeSpawn, PlayerImpl.ts:1518-1566), and in this game a human
-- has no way to buy one -- silos are on the AI's shopping list alone
-- (Sim.botBuild) and there is no build intent for them -- so the launch
-- button on the action rail could never fire a single shot. With this FALSE a
-- player's warhead spawns from their OWN LAND NEAREST THE TARGET instead, and
-- the 750,000 gold price is the only throttle on the rate.
--
-- The AI is untouched by the flag: Nukes.aiThink returns immediately unless
-- the empire owns a silo, so bots still have to build one, and every other
-- rule (SAM interception, fallout, the blast geometry) is unchanged -- the
-- shot still starts on a real tile and still has to fly there.
Config.NUKE_REQUIRES_SILO = false

-- Twin of Units.INFO[Units.ATOM_BOMB].costFn, which reads it (upstream
-- Config.ts:492-496). It lives here because the HUD prices the launch button
-- and must not carry a second copy of the number -- the same rule the client's
-- max-troops formula broke once and paid for.
Config.ATOM_BOMB_COST = 750000

-- ----------------------------------------------------------------- win -----
-- Upstream Config.percentageTilesOwnedToWin (src/core/configuration/
-- Config.ts:713-732) and OVERTIME_DEFAULTS (Config.ts:203-207). Base bar is
-- 80% free-for-all / 95% team. Overtime is OFF unless the lobby enables it;
-- upstream's public FFA rotation does (MapPlaylist.ts:219) and its team
-- rotation does not. It starts at 30 minutes, falls 2 WHOLE points a minute,
-- and has NO FLOOR: max(0, ...), so the FFA bar reaches zero at 70:00.
--
-- THE 30-MINUTE GUARANTEE IS GONE. Measured worst case is now 70:00 (FFA) /
-- 77:30 (team) before the bar hits zero, backed by the 170-minute wall below.
-- Observed matches are 9-24 min, but observed is not guaranteed. If the round
-- rotation cannot hold a 70-minute lobby, put 1800 back HERE and label it a
-- deliberate Roblox-side deviation rather than pretending the port is literal.
Config.WIN_PERCENT_FFA = 0.80
Config.WIN_PERCENT_TEAM = 0.95
Config.OVERTIME_ENABLED = true
Config.OVERTIME_START_MINUTES = 30
Config.OVERTIME_DROP_PER_MINUTE = 0.02
-- Upstream WinCheckExecution.HARD_TIME_LIMIT_SECONDS
-- (src/core/execution/WinCheckExecution.ts:26) = 170 * 60.
Config.HARD_TIME_LIMIT_SECONDS = 170 * 60

-- -------------------------------------------------------------- render -----
-- The map is 1600px wide, so 1.0 is roughly "fills a desktop screen" and the
-- minimum has to go below 1 for the whole country to be visible at once.
Config.MIN_ZOOM = 0.35
Config.MAX_ZOOM = 12.0
Config.DEFAULT_ZOOM = 1.0
Config.CLICK_DRAG_THRESHOLD = 6 -- px of movement that turns a click into a pan
-- Touch needs a far larger budget than a mouse: a finger resting on glass
-- wanders several pixels while it is down, even on a deliberate tap.
Config.TAP_SLOP_TOUCH = 16

-- ------------------------------------------------------------ AI tiers ----
-- UPSTREAM RUNS TWO AI CLASSES AND THIS GAME RAN ONE.
--
--   PlayerType.Bot    -> src/core/execution/TribeExecution.ts
--        Weak filler. It cannot even run the strategy ladder: it builds its
--        AiAttackBehavior with six arguments (:48-55), leaving
--        allianceBehavior undefined, and maybeAttack THROWS without one
--        (AiAttackBehavior.ts:53-56). So no bordering-player scan, no reserve
--        gate, no boat roll, no alliances -- just attackRandomTarget (:123).
--        That is why upstream can afford 400 of them (MapPlaylist.ts:213).
--
--   PlayerType.Nation -> src/core/execution/NationExecution.ts
--        The full ladder, difficulty-scaled, structures, warships, nukes.
--
-- What this game shipped was NEITHER: four Tribe legs (growth x0.5, gold 50,
-- neutral cost mag/10, think 40-80), three Nation legs (start ~18,000, builds
-- structures, runs the ladder), one value that is neither (maxTroops scale
-- 1.0) and one that is upstream's EASY (attacks a human 25% of the time).
--
-- TIER_LEGACY is exactly that hybrid, kept so the split can be PROVEN neutral:
-- a headless match on TIER_LEGACY must reproduce the measured
-- 16.1 min / 81.3% / 2-of-72 / 70-of-70-absorbed run digit for digit.
Config.TIER_HUMAN = 0
Config.TIER_TRIBE = 1
Config.TIER_NATION = 2
Config.TIER_LEGACY = 3

-- Which class Sim.addPlayer gives a bot when the caller does not say.
-- Flipping this to TIER_NATION is a BALANCE change, not a structural one, and
-- is predicted to move a match from 16.1 min to ~11.3. Measure it on its own.
Config.DEFAULT_BOT_TIER = Config.TIER_LEGACY

-- Tribes are ADDITIVE filler, not a slice of TARGET_EMPIRES: a human is a peer
-- and displaces a NATION, never a tribe. 0 keeps today's roster exactly.
--
-- Upstream's real counts, for whoever raises this: bots = 400 on a normal map
-- and 100 on Compact (MapPlaylist.ts:213), against 72 nations on World, 49 on
-- UnitedStates, 52 on Europe, 32 on China (resources/maps/*/manifest.json).
-- So upstream is 85-93% tribes. That cannot be ported literally -- addPlayer
-- caps at 255 ids -- and it is not the right target anyway, because the
-- quantity that governs how a map plays is LAND PER EMPIRE, and this game is
-- far sparser: World 651,569 land / 472 empires = 1,380 tiles each,
-- UnitedStates 1,868,914 / 449 = 4,162, this map 905,215 / 72 = 12,573.
-- 36 tribes puts the roster at 108 and the figure at 8,382 -- toward upstream,
-- not past it. Raise it 0 -> 24 -> 36 and read spawnMs each time: the binding
-- constraint is NOT the 255-id cap, it is Sim.isValidSpawn being O(placed) in
-- the single tick the spawn phase ends on.
Config.TRIBE_COUNT = 0

-- Every number below is upstream's, cited on its line. THINK_BASE/THINK_SPREAD
-- versus THINK_MIN/THINK_MAX is not stylistic: base+spread draws
-- NextInteger(-20, 20), which has 41 outcomes, and the exclusive form draws
-- NextInteger(40, 79), which has 40. They are different draws off the same
-- generator, so swapping one for the other reseeds every bot's think period
-- and the whole match diverges. TIER_LEGACY therefore keeps the old shape.
Config.TIER = {
	-- A human is never driven by the AI in the live game. These AI-only fields
	-- exist for ConquestSimulate, which runs humans through Sim.botThink to
	-- model the LOAD a person puts on the server.
	[Config.TIER_HUMAN] = {
		NAME = "human",
		SPAWN_TROOPS = Config.SPAWN_TROOPS,                   -- Config.ts:911
		MAX_TROOPS_SCALE = 1.0,                               -- Config.ts:930-932
		GROWTH_SCALE = 1.0,                                   -- no branch, Config.ts:948-980
		GOLD_PER_TICK = Config.GOLD_PER_TICK,                 -- Config.ts:987-988
		NEUTRAL_DIVISOR = Config.NEUTRAL_LOSS_DIVISOR,        -- Config.ts:785
		DEFENDER_MULT = 1.0,
		CONQUER_GOLD_SHARE = Config.CONQUER_GOLD_HUMAN_SHARE, -- Config.ts:621-630
		-- THE ECONOMY FIELDS ABOVE ARE LIVE. The AI fields below are not
		-- reached in a real match -- Sim.step's AI loop is gated on p.isBot --
		-- but they ARE reached by ConquestSimulate, which runs human empires
		-- through Sim.botThink to model the LOAD a person puts on the server
		-- (ConquestSimulate:124-130, :196-199).
		--
		-- So they must mirror TIER_LEGACY, not TIER_NATION. Before the split
		-- there was one set of BOT_* constants and the harness's humans used it
		-- like everything else; giving this tier nation values silently changed
		-- what the harness measures, which is a benchmark quietly re-baselining
		-- itself. (Found the hard way: it diverged the neutrality run at
		-- 7,050 ticks against 9,630.)
		THINK_BASE = Config.BOT_THINK_TICKS,
		THINK_SPREAD = Config.BOT_THINK_SPREAD,
		ATTACK_HUMAN_CHANCE = Config.BOT_ATTACK_HUMAN_CHANCE,
		BORDER_SAMPLE = Config.BOT_BORDER_SAMPLE,
		TRIBE_PARALLEL = 0,
		BUILDS = true, RAZES_CAPTURED = false,
		RESTRAINT = Config.BOT_TIER_HARD == true,
		BOAT_PREY = false, SEED_ATTACK = false, BUILD_SUBTICKS = false,
	},
	[Config.TIER_TRIBE] = {
		NAME = "tribe",
		SPAWN_TROOPS = 10000,          -- Config.ts:894-895
		MAX_TROOPS_SCALE = 1 / 3,      -- Config.ts:926-927
		GROWTH_SCALE = 0.5,            -- Config.ts:956-958
		GOLD_PER_TICK = 50,            -- Config.ts:985-986
		NEUTRAL_DIVISOR = 10,          -- Config.ts:785
		DEFENDER_MULT = 0.7,           -- Config.ts:104, :800-806
		CONQUER_GOLD_SHARE = 1.0,      -- Config.ts:621-630
		THINK_MIN = 40, THINK_MAX = 80, -- TribeExecution.ts:23
		-- shouldAttack short-circuits on a Bot ATTACKER (:856): never hesitates.
		ATTACK_HUMAN_CHANCE = 1.0,
		-- Upstream never walks a tribe's border -- it reads the cached
		-- nearby() list (TribeExecution.ts:116). This is the analogue, and at
		-- a fifth of a nation's it is what makes tribes nearly free.
		BORDER_SAMPLE = 60,
		-- attackRandomTarget skips a Nation/Human neighbour 1 time in 2
		-- (AiAttackBehavior.ts:726-733).
		PEER_SKIP_CHANCE = 0.5,
		BUILDS = false,                -- it razes instead, TribeExecution.ts:86-94
		RAZES_CAPTURED = true,         -- TribeExecution.ts:86-94
		RESTRAINT = false,             -- :879, :904 exempt Bots outright
		-- findRandomBoatTarget's "high interest" set is unowned land or land
		-- owned by PlayerType.Bot (AiAttackBehavior.ts:207-209).
		BOAT_PREY = true,
		-- A tribe's first think is its own special case on the tribe path.
		SEED_ATTACK = false,
		BUILD_SUBTICKS = false,
	},
	[Config.TIER_NATION] = {
		NAME = "nation",
		SPAWN_TROOPS = 18750,          -- Config.ts:901-902 (Medium)
		MAX_TROOPS_SCALE = 0.75,       -- Config.ts:937-938
		GROWTH_SCALE = 0.95,           -- Config.ts:965-966
		GOLD_PER_TICK = 100,           -- Config.ts:987-988
		-- A NATION pays the same mag/5 a human pays. Only PlayerType.Bot gets
		-- the halved neutral cost (Config.ts:785), which this game has been
		-- handing to its whole AI roster.
		NEUTRAL_DIVISOR = 5,
		DEFENDER_MULT = 1.0,
		CONQUER_GOLD_SHARE = 1.0,
		THINK_MIN = 55, THINK_MAX = 70, -- NationExecution.ts:80 (Medium)
		ATTACK_HUMAN_CHANCE = 0.75,     -- AiAttackBehavior.ts:867
		BORDER_SAMPLE = Config.BOT_BORDER_SAMPLE,
		TRIBE_PARALLEL = 2,             -- AiAttackBehavior.ts:474-475
		BUILDS = true,
		RAZES_CAPTURED = false,
		RESTRAINT = false,              -- troopSendCap/isAttackTooWeak are Hard+
		BOAT_PREY = false,
		-- NationExecution.ts:175-179 -> forceSendAttack (:750-758): the first
		-- think commits HALF the army at unclaimed ground, unconditionally.
		SEED_ATTACK = true,
		-- NationExecution.ts:181-197: handleStructures also runs at 1/3 and
		-- 2/3 of the attack interval, so gold cannot outrun spending.
		BUILD_SUBTICKS = true,
	},
	-- Bit for bit what this game shipped as its single AI class.
	[Config.TIER_LEGACY] = {
		NAME = "legacy",
		SPAWN_TROOPS = Config.BOT_SPAWN_TROOPS,
		MAX_TROOPS_SCALE = Config.BOT_MAX_TROOPS_SCALE,
		GROWTH_SCALE = Config.BOT_GROWTH_SCALE,
		GOLD_PER_TICK = Config.GOLD_PER_TICK_BOT,
		NEUTRAL_DIVISOR = Config.NEUTRAL_LOSS_DIVISOR_BOT,
		-- Literal 1.0, NOT HUMAN_VS_BOT_MAG: that constant is now the player
		-- invasion bonus, and routing it through here would hand the same
		-- discount to AI attacking AI.
		DEFENDER_MULT = 1.0,
		CONQUER_GOLD_SHARE = 1.0,
		THINK_BASE = Config.BOT_THINK_TICKS,
		THINK_SPREAD = Config.BOT_THINK_SPREAD,
		ATTACK_HUMAN_CHANCE = Config.BOT_ATTACK_HUMAN_CHANCE,
		BORDER_SAMPLE = Config.BOT_BORDER_SAMPLE,
		TRIBE_PARALLEL = 0,
		PEER_SKIP_CHANCE = 0.5,
		BUILDS = true,
		RAZES_CAPTURED = false,
		RESTRAINT = Config.BOT_TIER_HARD == true,
		-- All three FALSE-or-old on purpose. TIER_LEGACY has to reproduce the
		-- shipped game exactly, and each of these would otherwise change a
		-- decision or draw an extra random number:
		--   BOAT_PREY true keeps the old `other.isBot` split of the boat
		--     candidate pool, which decides which list NextInteger indexes.
		--   SEED_ATTACK false: the shipped AI had no first-think special case.
		--   BUILD_SUBTICKS false: the shipped AI called botBuild once a think,
		--     and botBuild rolls BOT_BUILD_CHANCE every call.
		BOAT_PREY = true,
		SEED_ATTACK = false,
		BUILD_SUBTICKS = false,
	},
}

return Config
