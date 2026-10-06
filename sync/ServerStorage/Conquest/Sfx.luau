--!strict
-- Conquest :: Sfx  (client)
-- Every sound in the game except the score, which is MusicClient's.
--
-- THE SOUNDS THEMSELVES LIVE IN SoundService and are authored there: the asset
-- id, and -- the part that matters -- the volume each one was mixed at. This
-- module does not restate a single one of those numbers. It reads the
-- template's own Volume and scales it, so rebalancing the mix is done by
-- dragging a slider in the Explorer and nothing here goes stale. A name with
-- no Sound behind it is silent rather than an error, which is what makes it
-- safe to call for a sound that has not been added yet.
--
-- WHY CLONES. A Sound has ONE playhead, so `:Play()` on a sound that is
-- already playing restarts it -- and a broadside of six shells would be one
-- shell. Each name therefore keeps a small pool of clones and a voice is an
-- idle one. When the pool is full the sound is DROPPED rather than stealing an
-- older voice: the sixth simultaneous cannon adds nothing to what you hear
-- except mud, and cutting a report off halfway is more noticeable than not
-- firing it.
--
-- WHY DISTANCE, AND WHY IT IS MEASURED IN SCREEN PIXELS. This is a chart, not
-- a world -- there is no listener to put a 3D Sound near, and the map is a
-- thousand tiles across. What "far away" honestly means here is how far the
-- thing is from what you are LOOKING AT: a detonation under your cursor is the
-- loudest event in the game, and the same detonation while you are zoomed into
-- your own border on the other side of the map is a rumble you feel rather
-- than hear. `playAt` measures that in the camera's own coordinates, so the
-- mix follows the view. Zooming out to the whole map genuinely does bring the
-- whole war into earshot, which is the correct answer: you can see all of it.
--
-- SERVER-SAFE. These modules are shared, so every entry point no-ops off the
-- client rather than assuming it will never be required there.

local ContentProvider = game:GetService("ContentProvider")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local Sfx = {}

-- Everything this module will ever play, by CUE NAME. Listed rather than
-- discovered so the preload below has something to work from, and so a typo at
-- a call site is a silent no-op instead of a hunt through SoundService.
--
-- These are not the Instance names. The Sounds are named "<cue> - <what it is
-- for>" in the Explorer ("Blast - Nuke exploding"), which is worth keeping --
-- it is the only place the mix documents itself, and a folder of eighteen
-- one-word names tells whoever opens it next to nothing. So the lookup takes
-- the cue and finds the child that leads with it; see resolve.
local NAMES = {
	"Blast",
	"Boom",
	"Launch",
	"Flyby",
	"Siren",
	"Intercept",
	"Barrage",
	"Charge",
	"Cannon",
	"Sink",
	"Landing",
	"Build",
	"Coin",
	"Click",
	"Deny",
	"Cheer",
	"Clash",
	"Destroy",
	"Pop",
	-- One second of the start countdown landing. The owner's own recording,
	-- "Tick - Countdown beep" in SoundService -- it briefly borrowed the click
	-- asset as a placeholder and does not any more. Its level is the slider on
	-- that instance, like every other cue here.
	"Tick",
}

-- HOW LONG THE SAME NAME MUST WAIT BEFORE IT MAY SOUND AGAIN. The case this
-- exists for is a whole packet's worth of events arriving on one frame: eight
-- guns that fired on the same server tick are ONE report to the ear, and eight
-- overlapping copies of the same half-second sample is a smear that reads as a
-- bug rather than as a volley. Tuned per name because the right answer is a
-- property of the sound, not of the game -- a click may repeat as fast as a
-- player can click, a siren may not.
local MIN_GAP: { [string]: number } = {
	Click = 0.04,
	Deny = 0.14,
	Coin = 0.08,
	Build = 0.10,
	Charge = 0.09,
	Cheer = 2.0,
	Barrage = 2.0,
	Launch = 0.16,
	-- One warning per warhead, not one per packet -- and a second missile
	-- arriving while the first is still inbound does not need a second siren.
	Siren = 6.0,
	Flyby = 0.45,
	-- RAISED for the owner's distant-explosion recording (2026-09-15): four and
	-- a half seconds of rumble where the old cue was one and a half. At 0.16 a
	-- salvo being shot down stacked half a dozen overlapping copies into mud.
	-- Still short enough that a genuine double kill sounds twice.
	Intercept = 0.35,
	Blast = 0.28,
	Boom = 0.40,
	Cannon = 0.09,
	Sink = 0.15,
	Landing = 0.13,
	-- One per empire is what the call site already guarantees; the gap is only
	-- here to stop two declarations landing on the same frame from doubling.
	Clash = 0.6,
	-- Nothing in the game is allowed to sit on top of this one.
	Destroy = 2.0,
	-- A FLOOR, NOT A SPACING. The pops are MEANT to run together (owner,
	-- 2026-09-04: "way too fucking slow"). This went 0.15 -> 0.3 chasing
	-- separation, which was the wrong read of the complaint before it:
	-- what was wrong with the first pass was the SAMPLE being stretched an
	-- octave, not the pops being close together. A RUN of pops is the
	-- sound -- spacing them out turned it into a clock.
	--
	-- 0.04 IS NOT A SPACING EITHER. It is the smallest gap two strikes of
	-- ONE packet may sit at -- see POP_SPACING, which is 0.05 and has to get
	-- through here. This was 0.07, a ceiling of fourteen a second, back when
	-- a packet could only ever fire one pop; since POP_MAX_PER_PACKET that
	-- number throttles the SECOND strike and nothing else.
	--
	-- IT IS STILL A REAL LIMIT. The slices one big tick is split into (see
	-- MAX_DELTA_PAIRS) arrive a frame apart, about 0.016s, so 0.04 still
	-- collapses them into the single bite they are. Much below 0.02 it stops
	-- doing that and a big tick turns into a machine gun.
	Pop = 0.04,
	-- A second apart by construction, so this only guards against the same
	-- second being written twice on one frame.
	Tick = 0.25,
}
local DEFAULT_GAP = 0.08

-- PITCH SPREAD. A sound the player hears forty times a round has to not be the
-- same sound forty times, and a few percent of playback speed is the whole
-- trick -- it is the difference between a gun and a loop of a gun. Widest on
-- the things that fire in bursts, narrowest on the ones that are meant to be
-- recognised instantly (a detonation, a refusal).
local JITTER: { [string]: number } = {
	Cannon = 0.14,
	Barrage = 0.18,
	Charge = 0.09,
	Coin = 0.10,
	Intercept = 0.10,
	-- ZERO, for the reason JITTER.Pop is zero: this cue's pitch is CARRYING
	-- something (which second of five you are on), and a random wobble on top
	-- of a rising ramp is noise on the only channel it has. A clock that
	-- wavers also stops sounding like a clock.
	Tick = 0,
	Sink = 0.08,
	Landing = 0.08,
	Boom = 0.08,
	Launch = 0.06,
	Build = 0.06,
	Click = 0.04,
	Blast = 0.04,
	Deny = 0,
	Siren = 0,
	Cheer = 0,
	Flyby = 0.06,
	Clash = 0.05,
	-- The sound that means you ended somebody has to be the same sound every
	-- time or it stops meaning it.
	Destroy = 0,
	-- A FEW PERCENT, NOT ZERO. This was zero because the pitch is carrying
	-- a number (see Sfx.pop) and spread reads as noise on it -- which was
	-- right about the signal and wrong about the sound. Forty identical
	-- copies of one sample is the exact thing the ear hears as MACHINERY,
	-- and no mouth has ever made the same pop twice. At 0.025 the wobble
	-- is smaller than one step of the progress ramp, so it is heard as
	-- the sound being alive and never as the number moving.
	Pop = 0.025,
}
local DEFAULT_JITTER = 0.06

-- HOW MANY TIMES ONE EVENT STRIKES. Everything else in this module is a single
-- sound per event; this is for the cue whose sample IS one blow and whose
-- moment is a fight. Clash -- the asset is literally called "Sword Clash" --
-- opens a war, and one clang reads as a parry. Three back to back read as the
-- exchange the moment actually is.
--
-- A REPEAT RATHER THAN A LOUDER OR LONGER SAMPLE, for the same reason Clash
-- plays instead of Charge and not over it: rhythm is something the ear reads
-- as intent, where level is just level. Three of the same sample is also why
-- the per-strike pitch jitter matters more here than anywhere else -- without
-- it, three identical copies land as one stuttering copy.
--
-- THE GAP IS WHAT MAKES IT THREE HITS INSTEAD OF ONE THICK ONE: far enough
-- apart that the attacks stay countable, close enough that they are obviously
-- one event. Clash rings for 1.72s, so at 0.24 the whole flurry is over in
-- 0.48s and the three tails still overlap into a single decay -- it is three
-- blows of one exchange, not three exchanges.
--
-- WIDENED FROM 0.16 (owner, 2026-09-04: "add a bit more time between each
-- one"). At the old spacing the second and third strikes landed inside the
-- attack of the first and the flurry read as one ragged hit; a beat and a
-- half apart is where the ear starts counting them. THE CEILING IS
-- MIN_GAP.Clash (0.6): the last strike must land before another declaration
-- is allowed to start its own flurry, or two wars interleave. 0.48 is inside
-- that with room; much past 0.28 and it is not.
local REPEATS: { [string]: number } = {
	Clash = 3,
}
local REPEAT_GAP: { [string]: number } = {
	Clash = 0.24,
}
local DEFAULT_REPEAT_GAP = 0.16

-- Voices per name. Five overlapping copies of anything is already more than
-- the ear separates; past that the throttle above has failed and dropping is
-- the kinder answer. Total across all names is bounded by this times #NAMES,
-- which is the only ceiling this module needs.
local POOL_MAX = 5

-- EXTRA VOICES, BY NAME. Pop is the only cue that has ever needed them: at
-- POP_MAX_PER_PACKET strikes a packet it runs twenty a second, and the sample
-- is up to 0.23s, so four or five copies are legitimately ringing at once
-- before anything has gone wrong. At five voices it would start DROPPING
-- strikes in the middle of exactly the blitz this is meant to make audible --
-- and a dropped pop is not a quieter pop, it is a hole in the rate the ear is
-- reading the front's speed off.
local POOL_EXTRA: { [string]: number } = {
	Pop = 3,
}

-- ------------------------------------------------------------- attenuation --

-- Screen-space distance from the middle of the view, in units of half a
-- viewport diagonal: 0 under the cursor, ~1 at the corner of the screen. Full
-- volume out to NEAR (so anything actually on screen is simply present, with
-- no fade across the visible area to explain), then down to nothing at FAR.
--
-- FAR is deliberately several screens: the map is much bigger than the window
-- at any useful zoom, and cutting off at the frame edge would make a war two
-- screens away completely silent, which is the wrong lie. It is audible and
-- small, which is what "over there" sounds like.
local NEAR = 0.9
local FAR = 4.5

-- How much of a sound's pitch a full fade takes with it. Distance dulls; this
-- is the cheapest honest version of that, and at 8% it is felt rather than
-- heard as a pitch change.
local FAR_PITCH = 0.08

local camera: any = nil

-- Registered by the client once the camera exists. Until then `playAt` behaves
-- as `play` -- correct for the handful of events that can happen before the
-- map is up, and it means no call site needs a nil check.
function Sfx.setCamera(cam: any)
	camera = cam
end

-- 1 = you are looking straight at it, 0 = far enough away to be inaudible.
-- Public because two sounds pick BETWEEN THEMSELVES on it: a detonation you
-- can see is a Blast, and the same detonation across the map is a Boom.
function Sfx.viewGain(tx: number, ty: number): number
	local cam = camera
	if cam == nil then
		return 1
	end
	local sx = tx * cam.zoom + cam.x
	local sy = ty * cam.zoom + cam.y
	local cx = cam.viewW * 0.5
	local cy = cam.viewH * 0.5
	-- Half the diagonal, so the normalisation is the same shape on any aspect
	-- ratio and an ultrawide does not hear further sideways than up.
	local half = math.max(1, math.sqrt(cx * cx + cy * cy))
	local d = math.sqrt((sx - cx) ^ 2 + (sy - cy) ^ 2) / half
	if d <= NEAR then
		return 1
	end
	local k = (d - NEAR) / (FAR - NEAR)
	if k >= 1 then
		return 0
	end
	-- Squared, not linear: an inverse-square-ish tail keeps things close to the
	-- edge of the screen nearly full and drops the genuinely distant away fast.
	return (1 - k) * (1 - k)
end

-- ------------------------------------------------------------------ voices --

local IS_CLIENT = RunService:IsClient()

local enabled = true
local templates: { [string]: Sound } = {}
local pools: { [string]: { Sound } } = {}
local lastPlayed: { [string]: number } = {}
-- The keys each cue has already been fired for -- see playOnce. Cleared beside
-- the throttle in stopAll, because both are memories of a round that is over.
local firstFor: { [string]: { [number]: boolean } } = {}
local rng = Random.new()
-- The second and third strikes of a repeated cue, still waiting to sound. Held
-- so stopAll can cancel them: a flurry that started a frame before the round
-- ended would otherwise clang into the first frame of the next one, which is
-- the exact thing stopAll exists to prevent.
local pending: { [thread]: boolean } = {}

-- Turned off wholesale. Nothing in the game uses this yet; it is here because
-- the first thing anyone wants from a sound system is a way to stop it, and
-- because a Studio session tuning something visual should be able to work in
-- silence without editing call sites.
function Sfx.setEnabled(on: boolean)
	enabled = on
end

-- CUE -> INSTANCE. The exact name wins if somebody ever adds one, otherwise
-- the child that leads with "<cue> - ", which is how the eighteen in the place
-- are named. Deliberately not a bare prefix match: "Blast" must not be
-- answered by a future "Blastwave", and requiring the separator is what makes
-- adding sounds safe.
local function resolve(cue: string): Sound?
	local exact = SoundService:FindFirstChild(cue)
	if exact and exact:IsA("Sound") then
		return exact
	end
	local lead = cue .. " - "
	for _, c in SoundService:GetChildren() do
		if c:IsA("Sound") and string.sub(c.Name, 1, #lead) == lead then
			return c
		end
	end
	return nil
end

-- WARMED IN THE BACKGROUND, ONCE. Two things have to happen before the first
-- shot and neither may happen on the frame it fires: the Sound children of
-- SoundService have to have replicated, and the audio itself has to be
-- fetched. A sound asked for before this finishes is simply dropped, which for
-- the first second of a session is exactly right -- there is nothing to hear
-- yet anyway.
--
-- POLLED rather than WaitForChild-ed, because the cue is not the child's name
-- and there is nothing to wait on. It gives up after DISCOVER_FOR: at that
-- point the Sound is genuinely not in the place, and retrying forever would
-- hide that instead of letting it be silent.
local DISCOVER_FOR = 20

if IS_CLIENT then
	task.spawn(function()
		local pending = #NAMES
		local deadline = os.clock() + DISCOVER_FOR
		local assets = {}
		repeat
			for _, cue in NAMES do
				if templates[cue] == nil then
					local s = resolve(cue)
					if s then
						templates[cue] = s
						pools[cue] = {}
						assets[#assets + 1] = s
						pending -= 1
					end
				end
			end
			if pending > 0 then
				task.wait(0.25)
			end
		until pending == 0 or os.clock() > deadline
		-- Best effort. A failed preload costs a hitch on the first play of that
		-- one sound, which is not worth propagating an error over.
		pcall(function()
			ContentProvider:PreloadAsync(assets)
		end)
	end)
end

-- An idle clone, or a new one, or nil when this name is already at full voice.
local function voice(name: string): Sound?
	local pool = pools[name]
	if pool == nil then
		return nil
	end
	for _, s in pool do
		if not s.IsPlaying then
			return s
		end
	end
	-- A REPEATED CUE'S EXTRA STRIKES ARE STILL ONE EVENT, so its ceiling is
	-- raised by exactly what one flurry costs. Without this, making Clash three
	-- hits would quietly cut the number of simultaneous declarations the pool
	-- can carry from five to one, and the drop would land on the last strike of
	-- the second war -- audible as a flurry that fumbles, with nothing to see.
	if #pool >= POOL_MAX + (POOL_EXTRA[name] or 0) + (REPEATS[name] or 1) - 1 then
		return nil
	end
	local s = templates[name]:Clone()
	-- Not the template's parent by accident -- SoundService is what makes it a
	-- 2D sound with no listener and no rolloff, which is the whole point.
	s.Parent = SoundService
	pool[#pool + 1] = s
	return s
end

-- ONE HIT. Split out of `fire` because a repeated cue has to start a voice
-- again later WITHOUT going back through the throttle: the throttle decides
-- whether this event sounds at all, and by then it has already said yes.
-- Jitter is taken here rather than in `fire` so every strike of a flurry gets
-- its own -- that is what makes three copies of one sample read as three
-- strikes instead of a stutter.
local function strike(name: string, vol: number, pitch: number): boolean
	local s = voice(name)
	if s == nil then
		return false
	end
	local spread = JITTER[name] or DEFAULT_JITTER
	if spread > 0 then
		pitch *= 1 + rng:NextNumber(-spread, spread)
	end
	s.Volume = vol
	s.PlaybackSpeed = pitch
	s:Play()
	return true
end

-- The one place a sound is actually started. `gain` is the distance multiplier
-- (1 for anything non-positional); `opts.volume` and `opts.pitch` are the call
-- site's own multipliers on top of what the template was authored at.
-- Returns whether a voice actually STARTED. Every caller but playOnce ignores
-- it; that one needs it because a cue it drops is a cue the call site still
-- has to cover with something.
local function fire(name: string, gain: number, opts: { volume: number?, pitch: number? }?): boolean
	if not (IS_CLIENT and enabled) or gain <= 0 then
		return false
	end
	local template = templates[name]
	if template == nil then
		-- LATE ARRIVAL. Discovery gives up after DISCOVER_FOR seconds, and on a
		-- slow join that deadline can pass before SoundService's children have
		-- finished replicating -- which used to mean the whole session played
		-- in silence, with nothing anywhere to see wrong. One more look here,
		-- only ever on a cue that has no template yet, is the difference
		-- between a sound that starts late and a game that has no sound.
		template = resolve(name)
		if template == nil then
			return false
		end
		templates[name] = template
		if pools[name] == nil then
			pools[name] = {}
		end
	end

	local now = os.clock()
	local gap = MIN_GAP[name] or DEFAULT_GAP
	if now - (lastPlayed[name] or -1e9) < gap then
		return false
	end

	local vol = template.Volume * gain
	local pitch = 1 - FAR_PITCH * (1 - gain)
	if opts then
		vol *= opts.volume or 1
		pitch *= opts.pitch or 1
	end

	-- THE FIRST STRIKE DECIDES. If there is no voice for it the event did not
	-- sound at all, so nothing is scheduled and nothing is charged against the
	-- throttle -- a flurry that begins on its second hit is worse than silence.
	if not strike(name, vol, pitch) then
		return false
	end
	lastPlayed[name] = now

	local n = REPEATS[name]
	if n then
		local step = REPEAT_GAP[name] or DEFAULT_REPEAT_GAP
		for i = 2, n do
			local th
			th = task.delay(step * (i - 1), function()
				pending[th] = nil
				strike(name, vol, pitch)
			end)
			pending[th] = true
		end
	end
	return true
end

-- ------------------------------------------------------------------- play ---

-- A sound that is not anywhere: a button, a refusal, an air-raid warning meant
-- for you. Full authored volume, no attenuation.
function Sfx.play(name: string, opts: { volume: number?, pitch: number? }?)
	fire(name, 1, opts)
end

-- THE FIRST TIME AND NO OTHER. A cue whose whole meaning is "this one is new"
-- -- war opening on an empire you have not fought before -- needs a memory of
-- what it has already sounded for, and the natural place to keep that is not
-- always the call site: ConquestClient is one local under Luau's 200-per-scope
-- ceiling and cannot hold another table. `key` is the caller's own (an empire
-- id), and the set is per cue, so two cues never collide.
--
-- A key is spent whether or not the sound came out -- being at war with them
-- is a fact about the round, not about the mix -- but the RETURN says what the
-- ear got, so a call site whose cue was throttled or dropped can fall back to
-- its ordinary sound instead of going silent.
function Sfx.playOnce(name: string, key: number, opts: { volume: number?, pitch: number? }?): boolean
	if not IS_CLIENT then
		return false
	end
	local seen = firstFor[name]
	if seen == nil then
		seen = {}
		firstFor[name] = seen
	end
	if seen[key] then
		return false
	end
	seen[key] = true
	return fire(name, 1, opts)
end

-- A sound that happened at a TILE. Attenuated by how far that tile is from the
-- middle of the view -- see viewGain.
--
-- `opts.floor` raises the quietest it may ever be: the events that use it are
-- the ones a player must not miss wherever they happen (a nuke going off
-- anywhere on the map is the round changing shape), so they fade toward small
-- rather than toward nothing.
function Sfx.playAt(name: string, tx: number, ty: number, opts: { volume: number?, pitch: number?, floor: number? }?)
	local g = Sfx.viewGain(tx, ty)
	local floor = opts and opts.floor or 0
	if floor > 0 then
		g = floor + (1 - floor) * g
	end
	fire(name, g, opts)
end

-- --------------------------------------------------------------- conquest --

-- GROUND TAKEN OFF SOMEBODY ELSE -- the thing this entire game is about, and
-- the thing that made no sound at all. The map changed colour, the treasury
-- moved, and that was the whole of the feedback.
--
-- THE PITCH IS INFORMATION, NOT DECORATION. It rises with `progress` -- 0 at
-- the start of a round, 1 at the share of the map that ENDS it -- so a player
-- who never looks up at the win bar still knows, from the sound of their own
-- conquest, whether they are nibbling at a border or closing the round out.
-- That is what JITTER.Pop = 0 protects: every other cue jitters so that forty
-- copies are not one copy, and here a random few percent would be noise on
-- the only channel this sound carries.
--
-- CURVE. An empire holding five percent of the map is already a real empire,
-- and linear in share would spend nearly the whole round at the bottom of the
-- range. Raising the progress to a power below 1 spends most of the pitch on
-- the part of the round that is actually played.
--
-- THE RANGE IS NARROW ON PURPOSE, and that is most of the rest of the ASMR
-- fix. Playback speed is the only pitch control there is here, so it
-- STRETCHES the sample as well as transposing it -- and everything this cue
-- is worth is in its timbre, the wet click of a mouth. The first pass ran
-- 0.82 to 2.0, an octave and a quarter, and past roughly a fourth it stops
-- sounding like a pop at all: low it is a thud, high it is a plastic tick.
-- Inside a fifth every pop still sounds like the recording, and the climb is
-- still plainly audible.
--
-- AND IT NO LONGER GOES BELOW THE RECORDING'S OWN PITCH. The satisfying part
-- of this sample is at the top of it, so starting under 1.0 spent the early
-- game -- which is most of the game -- on the dullest version of the sound.
local POP_LOW = 0.95
local POP_HIGH = 1.6
local POP_SHAPE = 0.6

-- A BITE IS ONE POP HOWEVER BIG IT IS, and the size of it is in the LEVEL
-- instead. One tile off a border skirmish and a collapsing empire's entire
-- map arriving on a single tick are the same EVENT to the ear; what separates
-- them is how hard it lands. Square-rooted, so the first handful of tiles is
-- most of the difference and a thousand is not ten times a hundred.
--
-- MULTIPLIERS ABOVE 1, which is a deliberate reversal (owner, 2026-09-04:
-- "pops are too quiet"). They were 0.55-0.85 on the reasoning that the cue
-- should sit UNDER the war -- but the template is authored at 0.5, so that
-- landed the loudest pop at 0.43 absolute, under a mix carrying nukes and
-- artillery. "Close and intimate" is a property of the SAMPLE, not of the
-- fader: a mouth pop at conversational level still reads as a mouth pop,
-- and one at a whisper just reads as something you missed.
--
-- POP_TILES_LOUD came down with them. At 300 against a 15-tile threshold
-- the level sat at the bottom of its range all round, because the debt at
-- the moment a pop fires is almost never near 300. 60 is four pops' worth,
-- which is what a genuinely big bite looks like now.
local POP_TILES_LOUD = 60
local POP_QUIET = 1.1
local POP_LOUD = 1.7

-- Ground you took while you were looking somewhere else is still ground you
-- took, so this fades toward small rather than toward nothing -- the same
-- reason the nukes have a floor. RAISED with the level above: a front on
-- the far side of the map was landing at 0.3 of an already-quiet cue,
-- which is most of a round's conquest for anybody zoomed in on one war.
local POP_FLOOR = 0.55

-- HOW MUCH GROUND ONE POP IS WORTH, AND THE WHOLE REASON THE CUE NOW MATCHES
-- THE MAP (owner, 2026-09-04: "the asmr pop sound doesnt match with expansion
-- speed pixels being gained").
--
-- It used to be ONE POP PER DELTA PACKET. That made the cadence a property of
-- the SERVER'S SEND RATE -- a flat 10 Hz -- and not of the territory: a
-- one-tile nibble and a three-hundred-tile blitz popped at exactly the same
-- speed, so the ear was being told nothing the eye could not already see, and
-- the two were plainly out of step whenever the front moved fast.
--
-- Counted in TILES instead, so the pop rate IS the expansion rate. Against
-- measured play -- Config's own figure is a mean 421 tiles a tick across the
-- whole map, which is roughly 20 a tick on one live front:
--   a dying trickle    ~20 tiles/s   -> about three a second
--   a working front    ~70 tiles/s   -> ten a second, the ceiling
--   anything faster                  -> ten a second
--
-- 100 -> 15 -> 7, twice on the owner's ear ("way too fucking slow", then
-- "start it at 3" -- three a second at the BOTTOM of the range, where a
-- front is barely moving). A hundred tiles is most of a second of a real
-- advance, so the cue sat there ticking while the map poured outward.
--
-- WHAT THIS USED TO SPEND was the top of the range: at 7 the rate tracked the
-- front only to about seventy tiles a second, and every push past that sounded
-- identical -- a border skirmish and an empire collapsing across the whole map
-- were the same ten pops a second. The ceiling was never MIN_GAP and it was
-- never this number either: it was ONE POP PER DELTA PACKET, ten a second at
-- Config.TICK_RATE, whatever value sat here.
--
-- POP_MAX_PER_PACKET lifted that roof, and then MEASUREMENT retired the
-- divisor entirely (owner, 2026-09-12: "now that the range is bigger, i want
-- you to fit it to different expansion speeds").
--
-- WHAT THE HARNESS SAID. Four headless rounds through /simulate's Sim -- a
-- human-weighted empire (hthink=3) on us/europe/world, gains counted per tick
-- straight off `sim.changes` -- on the ticks it actually took ground:
--
--            p10   p50   p95   max    share already at the ceiling
--   us/101     3    16    58   144            55%
--   us/202     6    24    72   131            72%
--   europe     4    11    89   132            46%
--   world      3    20    50   153            68%
--
-- In tiles a second that is a p10 near 40 and a p95 near 670: a SEVENTEENFOLD
-- span. A linear divisor of 7 saturates at 140, so the MEDIAN tick a player
-- took ground on was already pinned at the top of the range -- 46-72% of them,
-- run by run. More than half of all conquest sounded exactly alike, and the
-- whole range was being spent on the slowest tenth.
--
-- THE OLD COMMENT'S NUMBERS WERE A GUESS AND THEY WERE LOW. It called ~20
-- tiles a second "a dying trickle"; that is below a player's tenth percentile.
-- The floor the owner asked for ("start it at 3") now sits at the p10 the
-- harness actually found, rather than at an invented one.
--
-- SO THE RATE IS A LOG READOUT NOW, not a linear one. 40 -> 670 tiles a second
-- maps onto 3 -> 20 pops a second, which puts every quartile of real play at a
-- rate the ear can tell from its neighbours (about 6, 12, 15, 18, 20) instead
-- of four of them sharing one number. Log rather than linear because that is
-- what hearing does to rate anyway: "twice as fast" is a ratio, not a
-- difference. The cost is that the rate is no longer PROPORTIONAL to the
-- front's speed -- it is a readout of it, which is what it was always for.
local POP_SPEED_LOW = 40
local POP_SPEED_HIGH = 670
local POP_RATE_LOW = 3
-- Equal to POP_MAX_PER_PACKET * Config.TICK_RATE by construction. The curve
-- must not ask for a rate the packet ceiling cannot deliver, or the top of the
-- range becomes a promise the mix quietly breaks.
local POP_RATE_HIGH = 20

-- TILES PER POP at a given front speed. Below the low anchor there is nothing
-- left to compress -- a front that slow is dying, and it should THIN OUT
-- rather than hold a floor, or the last few tiles of a lost war would pop as
-- busily as a push. Linear continuation below the anchor, so the two halves
-- meet at exactly POP_RATE_LOW and there is no step at the join.
local function popTilesPerPop(speed: number): number
	if speed <= POP_SPEED_LOW then
		return POP_SPEED_LOW / POP_RATE_LOW
	end
	local f = math.min(math.log(speed / POP_SPEED_LOW) / math.log(POP_SPEED_HIGH / POP_SPEED_LOW), 1)
	return speed / (POP_RATE_LOW + (POP_RATE_HIGH - POP_RATE_LOW) * f)
end

-- THE CURVE, ASKED DIRECTLY: the rate a front moving at `speed` tiles a second
-- is meant to pop at. Pure -- no state, no clock -- which is the point of it:
-- the fit can be checked without running a round, and the test ladder can
-- print what it is about to play rather than carrying a second, driftable copy
-- of these numbers.
function Sfx.popRateAt(speed: number): number
	return speed / popTilesPerPop(speed)
end

-- THE READOUT IS THE FRONT'S SPEED, NOT THIS PACKET'S, so the estimate is
-- smoothed -- one fat tick inside a slow grind is not a blitz, and the rate
-- lurching on it would read as the sound glitching rather than as the war
-- moving. Just under half a second: long enough that a single packet cannot
-- move it far, short enough that the rate is climbing while a push still is.
--
-- MEASURED OVER REAL TIME, NOT PER CALL, because ConquestClient only calls
-- this when it actually gained something -- a third of playing ticks it gains
-- nothing and there is no packet at all. Per-call smoothing would hold a stale
-- fast rate straight through a lull. `dt` floors at one tick: the slices a big
-- tick is split into (MAX_DELTA_PAIRS) arrive a frame apart and dividing by a
-- frame would read a hundred-tile slice as a ten-thousand-tile-a-second front.
local POP_TAU = 0.45
local POP_DT_MIN = 0.1
local POP_DT_MAX = 3

-- HOW MANY POPS ONE PACKET MAY FIRE (owner, 2026-09-12: "i want more pops than
-- 10 without it sounding unhearable").
--
-- TWO, NOT THREE. The strikes have to spread evenly across the tick or the
-- cadence limps, so the reachable rates are quantised to multiples of
-- Config.TICK_RATE: 10, 20, 30. At 20 the gap is 50 ms, which is about where
-- the ear stops resolving clicks as separate events; at 30 it is 33 ms, which
-- is past it -- a click train that fast FUSES into a low buzz and stops being
-- a pop at all. So 2 is not a cautious 3. It is the last value that still
-- sounds like the sample.
local POP_MAX_PER_PACKET = 2

-- Evenly across the tick, so a run of packets each firing two is a steady
-- twenty a second rather than a gallop. It has to clear MIN_GAP.Pop (0.04) or
-- the throttle eats every second strike and this whole thing buys nothing.
local POP_SPACING = 0.05

-- Ground taken but not yet sounded for. Carried between calls because a front
-- moving slowly is spread across many packets and each of them alone is worth
-- nothing -- the run of them is what deserves a pop. Cleared by stopAll: a
-- debt run up in a round that is over must not pop into the next one.
--
-- CAPPED at the volume ceiling rather than left to run. Without it a long
-- blitz banks tens of thousands of tiles while the throttle is holding pops
-- back, and every pop for the rest of the round comes out at full level.
local popDebt = 0
-- The smoothed front speed in tiles a second, and when it was last fed. Both
-- cleared by stopAll beside the debt: a speed carried out of a finished round
-- would set the rate for the first seconds of the next one.
local popSpeed = 0
local popLast = 0

function Sfx.pop(tiles: number, tx: number, ty: number, progress: number)
	local now = os.clock()
	local dt = math.clamp(now - popLast, POP_DT_MIN, POP_DT_MAX)
	popLast = now
	popSpeed += (tiles / dt - popSpeed) * (1 - math.exp(-dt / POP_TAU))
	local per = popTilesPerPop(popSpeed)

	-- The debt cap is what stops a blitz banking thousands of tiles and pinning
	-- the volume at max for the rest of the round. It has to clear one packet's
	-- worth of pops at the CURRENT divisor, though: at a blitz `per` alone can
	-- exceed POP_TILES_LOUD, and capping under it would silently cost the second
	-- strike exactly when the front most deserves it.
	popDebt = math.min(popDebt + tiles, math.max(POP_TILES_LOUD, per * POP_MAX_PER_PACKET))
	if popDebt < per then
		return
	end
	-- WHAT IS LEFT OVER STAYS ON THE CLOCK, up to one more pop's worth. A push
	-- big enough to owe several at once should pop AGAIN on the next packet --
	-- that is what a fast front sounds like -- and the throttle, not this, is
	-- what decides how fast that may happen.
	local due = popDebt
	-- ONE STRIKE PER POP'S WORTH OF GROUND IN HAND, up to the packet's ceiling.
	-- This is the difference between Pop and the REPEATS machinery Clash uses:
	-- there the extra strikes are part of what the cue IS and fire whatever
	-- happened, here every one of them has to be PAID FOR in tiles. A packet
	-- that only earned one pop fires exactly one, so a slow front -- and the
	-- three-a-second floor -- is untouched by any of this.
	local n = math.min(math.floor(due / per), POP_MAX_PER_PACKET)
	popDebt = math.min(due - n * per, per)
	local p = math.clamp(progress, 0, 1) ^ POP_SHAPE
	-- Level off the bite that TRIGGERED it, not off one packet: a pop that has
	-- been waiting five seconds for its hundred tiles should land softer than
	-- one that was paid for in a single tick.
	local k = math.sqrt(math.clamp(due / POP_TILES_LOUD, 0, 1))
	-- Shared by every strike of this packet: they are one bite, and the pitch is
	-- carrying a number that did not change between them. What keeps them from
	-- being one sound played twice is JITTER, which `strike` takes fresh.
	local opts: { volume: number?, pitch: number?, floor: number? } = {
		pitch = POP_LOW + (POP_HIGH - POP_LOW) * p,
		volume = POP_QUIET + (POP_LOUD - POP_QUIET) * k,
		floor = POP_FLOOR,
	}
	Sfx.playAt("Pop", tx, ty, opts)
	for i = 2, n do
		-- Held in `pending` for the reason Clash's extra strikes are: a strike
		-- scheduled a frame before the round ends must not land on the first
		-- frame of the next one.
		local th
		th = task.delay(POP_SPACING * (i - 1), function()
			pending[th] = nil
			Sfx.playAt("Pop", tx, ty, opts)
		end)
		pending[th] = true
	end
end

-- ONE POP, FOR A CLAIM RATHER THAN AN ADVANCE (owner, 2026-09-12: "when i
-- spawn and select a place on the map, i hear 2 pops, for that i only wanna
-- hear 1 pop").
--
-- The spawn click paints a radius-4 disc -- up to 49 tiles -- in a single
-- delta, and `Sfx.pop` reads that the way it reads any fat packet: as a front
-- moving fast enough to have earned two strikes. Measured: 49 tiles on a clean
-- slate fires 2. It is not a front, though. It is a PLACEMENT, it happens in
-- one instant, and it happens once per pick -- so it gets exactly one sound,
-- however much ground the disc covers.
--
-- AND IT DELIBERATELY DOES NOT FEED THE ESTIMATOR. Letting 49 instant tiles
-- into the EMA primes `popSpeed` as though the war had opened at a sprint, and
-- the first real pops of the round would then come out at a rate the front has
-- not earned. The debt is untouched for the same reason: nothing here is owed,
-- because nothing here is a run of ground being taken.
--
-- The LEVEL is still the shared curve, so a claim sounds like a pop of its
-- size rather than like a different cue -- it is the count that changes, not
-- the sound.
function Sfx.popOnce(tiles: number, tx: number, ty: number, progress: number)
	local p = math.clamp(progress, 0, 1) ^ POP_SHAPE
	local k = math.sqrt(math.clamp(tiles / POP_TILES_LOUD, 0, 1))
	Sfx.playAt("Pop", tx, ty, {
		pitch = POP_LOW + (POP_HIGH - POP_LOW) * p,
		volume = POP_QUIET + (POP_LOUD - POP_QUIET) * k,
		floor = POP_FLOOR,
	})
end

-- WHAT THE CURVE ACTUALLY SOUNDS LIKE, on demand (owner, 2026-09-12).
--
-- Both of these drive Sfx.pop the way a delta packet does -- same entry point,
-- same smoothing, same debt, same throttle, same pool -- at the tick rate. So
-- neither is a mock-up of the mix: if it smears here it smears in a round.
-- Fired at the middle of the view so attenuation is 1 and what you hear is the
-- mix's own level.
local TEST_DT = 0.1 -- Config.TICK_RATE, inlined to keep Sfx dependency-free

local function popTestCentre(): (number, number)
	local cam = camera
	if cam == nil then
		return 0, 0
	end
	return (cam.viewW * 0.5 - cam.x) / cam.zoom, (cam.viewH * 0.5 - cam.y) / cam.zoom
end

-- A FRONT MOVING AT A GIVEN SPEED, held for as long as asked.
--
-- `progress` is PINNED rather than swept, which is the whole point of it: this
-- exists to compare RATES against each other, and a pitch climbing at the same
-- time would make it impossible to say which of the two the ear was answering.
-- The first half-second or so of each call is the speed estimate settling (see
-- POP_TAU), which is why a rung wants a couple of seconds to be judged on.
function Sfx.testSpeed(tilesPerSec: number, seconds: number?, progress: number?)
	if not IS_CLIENT then
		return
	end
	local dur = seconds or 2.5
	local p = progress or 0.35
	task.spawn(function()
		local tx, ty = popTestCentre()
		local t0 = os.clock()
		repeat
			Sfx.pop(tilesPerSec * TEST_DT, tx, ty, p)
			task.wait(TEST_DT)
		until os.clock() - t0 >= dur
	end)
end

-- The ceiling, with the pitch ramp sweeping 0 -> 1 underneath it: the whole
-- range going past at the fastest the rate can ever be, which is the case most
-- likely to turn to mush. Driven at twice POP_SPEED_HIGH so the curve is
-- clamped for the entire run and the rate really is the ceiling throughout.
function Sfx.testMaxPop(seconds: number?)
	if not IS_CLIENT then
		return
	end
	local dur = seconds or 6
	task.spawn(function()
		local tx, ty = popTestCentre()
		local t0 = os.clock()
		repeat
			Sfx.pop(POP_SPEED_HIGH * 2 * TEST_DT, tx, ty, (os.clock() - t0) / dur)
			task.wait(TEST_DT)
		until os.clock() - t0 >= dur
	end)
end

-- Everything still ringing, cut. Called when a round ends or rotates: a
-- detonation from the last round arriving over the first frame of the next one
-- is the sort of thing nobody ever tracks down.
function Sfx.stopAll()
	for _, pool in pools do
		for _, s in pool do
			if s.IsPlaying then
				s:Stop()
			end
		end
	end
	for th in pending do
		-- A thread that has already run is dead, and cancelling a dead thread
		-- throws. The callback clears its own entry first, so this only ever
		-- sees live ones -- pcall because "only ever" is not worth a crash.
		pcall(task.cancel, th)
	end
	table.clear(pending)
	table.clear(lastPlayed)
	table.clear(firstFor)
	popDebt = 0
	popSpeed = 0
	popLast = 0
end

return Sfx
