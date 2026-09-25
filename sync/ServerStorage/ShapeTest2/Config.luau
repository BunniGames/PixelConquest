--!strict
-- Conquest :: Config
-- Every tunable in one place. Shared by server sim and client renderer.

local Config = {}

-- ---------------------------------------------------------------- map ------
-- Contiguous United States at one tile per pixel. Must match UsMap.WIDTH/HEIGHT.
Config.MAP_W = 1600
Config.MAP_H = 1000
Config.NUM_TILES = Config.MAP_W * Config.MAP_H -- 1,600,000

-- Tile index packing for the network delta: 1.6M tiles needs 21 bits
-- (2,097,152), owner id occupies bits 21..28. Keep in sync with Net.packDelta.
Config.INDEX_BITS = 21

-- --------------------------------------------------------------- timing ----
Config.TICK_RATE = 10
Config.TICK_DT = 1 / Config.TICK_RATE

Config.SPAWN_PHASE_SECONDS = 20
Config.LOBBY_SECONDS = 5

-- --------------------------------------------------------------- spawn -----
Config.SPAWN_TROOPS = 25000
Config.BOT_SPAWN_TROOPS = 18000
Config.MIN_SPAWN_DISTANCE = 55 -- tiles between any two spawn points
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
Config.BOT_GROWTH_SCALE = 0.5

-- -------------------------------------------------------------- attack -----
Config.DEFAULT_ATTACK_RATIO = 0.25
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
Config.ATTACK_ALT_COEF = 1.3
Config.ATTACK_LOSS_BLEND = 0.6

-- Unclaimed land is a flat fraction of the terrain magnitude (bots pay half).
Config.NEUTRAL_LOSS_DIVISOR = 5
Config.NEUTRAL_LOSS_DIVISOR_BOT = 10

-- A big defender defends slightly worse per tile; a big attacker attacks
-- slightly worse. Both are anti-snowball brakes.
Config.DEFENSE_DEBUFF_MIDPOINT = 150000
Config.DEFENSE_DEBUFF_HALFLIFE = 50000
Config.DEFENSE_DEBUFF_FLOOR = 0.7 -- debuff spans FLOOR .. 1.0
Config.LARGE_ATTACKER_TILES = 100000
Config.LARGE_ATTACKER_LOSS_EXP = 0.35 -- sqrt(ratio)^0.7
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
Config.COLLAPSE_FRACTION = 0.010
Config.COLLAPSE_MIN_TILES = 120

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
Config.FRONTIER_ROUGH_SCALE = 90

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
Config.FRONTIER_DELAY_MIN = 3
Config.FRONTIER_DELAY_SPREAD = 20

-- Wrapping is the compactness term: a tile whose surroundings we already
-- hold comes up sooner, so pockets fill and the front leaves no holes.
-- Measured over a DISC (Sim.WRAP_OFFSETS), never the four cardinal
-- neighbours -- a cross metric is itself axis-aligned and the limit shape
-- of a flow that minimises it is a rectangle, whatever noise is added.
Config.FRONTIER_WRAP_RELIEF = 0.85

-- Terrain is the tie-breaker, never the driver. When terrain outweighed
-- compactness the front chased cheap plains across the map and left every
-- highland tile behind as a permanent hole.
Config.FRONTIER_TERRAIN_PENALTY = 0.5

-- Regional character: the smooth hard-ground field stretches the delay by
-- plus or minus half of this, so a front bulges through soft country.
Config.FRONTIER_ROUGH_STRETCH = 0.34

-- However wrapped, cheap and soft a tile is it still waits this fraction of
-- its delay. Also the bound the lazy decrease-key prunes against.
Config.FRONTIER_BASE_MIN = 0.12

-- Global safety valve: total tiles conquered per tick across all attacks.
-- Scaled with the map: at 1.6M tiles the old 1500 would have taken ten
-- minutes just to claim the empty land.
Config.GLOBAL_TILE_BUDGET = 14000

-- ...but that figure is calibrated for a map this size, so Sim scales it by
-- (playableLand / this) per round. The roster spans 477k to 1.13M playable
-- tiles, and a fixed budget would make the largest map take 2.4x as long to
-- fill as the smallest. Reference is the US map's playable land.
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
Config.TARGET_EMPIRES = 16

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
Config.MAX_FRONTS_PER_PLAYER = 3

-- Absorbing a broken empire is a scan of the whole map for its colours. Done
-- in one tick that is ~15 ms AND dumps tens of thousands of tiles into a
-- single delta frame (measured peak: 13,572 tiles = 54 KB to every client at
-- once). The victim is dead the instant it is called, so spreading the land
-- transfer over the next second is invisible and costs nothing.
Config.COLLAPSE_SCAN_PER_TICK = 250000
Config.COLLAPSE_TILES_PER_TICK = 2500

-- ---------------------------------------------------------------- bots -----
Config.NUM_BOTS = 12
Config.BOT_THINK_TICKS = 14 -- bots re-evaluate this often
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

-- ----------------------------------------------------------------- win -----
Config.WIN_PERCENT = 0.80
Config.OVERTIME_START_SECONDS = 360
Config.OVERTIME_DROP_PER_MINUTE = 0.03 -- win bar falls 3 points/min after that
Config.HARD_TIME_LIMIT_SECONDS = 1800

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

return Config
