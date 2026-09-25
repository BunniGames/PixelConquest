--!strict
-- Conquest :: client entry
-- Builds the view, mirrors server ownership deltas into the renderer, and
-- turns pointer input into intents.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Camera2D = require(Shared.Camera2D)
local Config = require(Shared.Config)
local Gamepad = require(Shared.Gamepad)
local HUD = require(Shared.HUD)
local Icons = require(Shared.Icons)
local Missiles = require(Shared.Missiles)
local NationLabels = require(Shared.NationLabels)
local Net = require(Shared.Net)
-- Already in memory: Missiles requires it to expand a blast footprint. The
-- client wants it for ONE thing -- Nukes.magnitude, so the ghost circle is the
-- warhead's real radius rather than a number copied over here to go stale.
local Nukes = require(Shared.Nukes)
local Numbers = require(Shared.Numbers)
local Palette = require(Shared.Palette)
-- THE ONE LOCAL THIS CHUNK HAD LEFT. Luau allows 200 locals per function
-- scope and the main body of this file sits on 199, so `Patterns` keeps no
-- companion table here: which empire wears what lives inside the module and
-- is written an id at a time (Patterns.setOwner), which is also why there is
-- no bulk form of it.
local Patterns = require(Shared.Patterns)
local Renderer = require(Shared.Renderer)
local Sfx = require(Shared.Sfx)
local Structures = require(Shared.Structures)
local TileMap = require(Shared.TileMap)

-- ROBLOX'S OWN PLAYER LIST IS OFF (owner, 2026-09-03: "disable roblox's
-- built in leaderboard"). This game has a leaderboard already -- HUD's
-- STANDINGS board, which now sits in the top-right corner the core list used
-- to hold -- and two ladders on one screen is one too many. Nothing here has
-- ever set `leaderstats`, so that list was showing usernames and nothing
-- else: no readout goes with it.
--
-- ABOVE the role gate below, so it takes in a LOBBY server too. This script
-- yields on the next line until a round starts, and without that ordering
-- the list would sit over the matchmaking page for the whole wait.
--
-- Spawned and retried because SetCoreGuiEnabled throws while the core scripts
-- that own the list are still loading, which on a cold join is after this
-- runs -- and a throw here would take the whole client entry with it.
task.spawn(function()
	for _ = 1, 20 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		end)
		if ok then
			return
		end
		task.wait(0.25)
	end
end)

-- WHICH SERVER IS THIS? A public server of this place runs the matchmaking
-- page and no simulation; only a RESERVED server -- one a lobby launched --
-- runs a round. Yielding here rather than returning is deliberate: a Studio
-- lobby FLIPS to "match" when its own countdown fires, and the whole client
-- has to start building at exactly that moment.
local Matchmaker = require(Shared.Matchmaker)
Matchmaker.awaitRole("match")

local netFolder = Net.await(ReplicatedStorage)
local StateRE = netFolder:WaitForChild("State") :: RemoteEvent
local DeltaRE = netFolder:WaitForChild("Delta") :: RemoteEvent
local IntentRE = netFolder:WaitForChild("Intent") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ================================================================== view ===

local screen = Instance.new("ScreenGui")
screen.Name = "Conquest"
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = playerGui

-- Below fit-zoom the map does not fill the screen, and what showed through
-- used to be flat black. The chart now lies on a wooden desk. Flip DESK_WOOD
-- off for a plain neutral grey and every board/grain/vignette part is skipped.
local DESK_WOOD = true
local DESK_BASE = DESK_WOOD and Color3.fromRGB(76, 52, 36) or Color3.fromRGB(63, 65, 69)

local viewport = Instance.new("Frame")
viewport.Name = "Viewport"
viewport.Size = UDim2.fromScale(1, 1)
-- The desk (below) is what fills the screen now; this frame is only a clip box.
viewport.BackgroundTransparency = 1
viewport.BorderSizePixel = 0
viewport.ClipsDescendants = true
viewport.Active = true
viewport.Parent = screen
-- =================================================================== desk ===
-- Built once and never touched again: pure backdrop, zero per-frame cost.
-- LAYERS. Everything here is ZIndex -1, the map's paper/shadow is 0, and the
-- renderer's image tiles are the default 1 -- explicit, so nothing depends on
-- the order instances happen to be created in.
local desk = Instance.new("Frame")
desk.Name = "Desk"
desk.Size = UDim2.fromScale(1, 1)
desk.BackgroundColor3 = DESK_BASE
desk.BorderSizePixel = 0
desk.Active = false
desk.ZIndex = -1
desk.Parent = viewport

-- Boards run ACROSS the screen, not down it. Where the map falls short it
-- leaves a narrow band, and horizontal boards put several seams inside that
-- band where vertical ones would leave a single flat stripe.
if DESK_WOOD then
	-- Fixed seed: the desk must not differ between two players' screens.
	local rng = Random.new(20260831)
	local BOARDS = 7
	for i = 0, BOARDS - 1 do
		local board = Instance.new("Frame")
		board.Name = "Board" .. i
		board.Size = UDim2.new(1, 0, 1 / BOARDS, 0)
		board.Position = UDim2.fromScale(0, i / BOARDS)
		board.BackgroundColor3 = DESK_BASE:Lerp(
			rng:NextNumber() < 0.5 and Color3.new(0, 0, 0) or Color3.new(1, 1, 1),
			rng:NextNumber(0.02, 0.11)
		)
		board.BorderSizePixel = 0
		board.Active = false
		board.ZIndex = -1
		board.Parent = desk

		-- Shading across the board's width reads as the round of a plank.
		local round = Instance.new("UIGradient")
		round.Rotation = 90
		round.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(148, 148, 148)),
			ColorSequenceKeypoint.new(0.35, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(176, 176, 176)),
		})
		round.Parent = board

		for _ = 1, 4 do
			local grain = Instance.new("Frame")
			grain.Name = "Grain"
			grain.Size = UDim2.new(rng:NextNumber(0.3, 1), 0, 0, rng:NextInteger(1, 2))
			grain.Position = UDim2.new(rng:NextNumber(0, 0.55), 0, rng:NextNumber(0.12, 0.86), 0)
			grain.BackgroundColor3 = Color3.fromRGB(38, 24, 14)
			grain.BackgroundTransparency = rng:NextNumber(0.72, 0.9)
			grain.BorderSizePixel = 0
			grain.Active = false
			grain.ZIndex = -1
			grain.Parent = board
		end

		-- One board END per row, staggered, so the boards read as boards and
		-- not as stripes.
		local butt = Instance.new("Frame")
		butt.Name = "Butt"
		butt.Size = UDim2.new(0, 2, 1, 0)
		butt.Position = UDim2.new(rng:NextNumber(0.12, 0.88), 0, 0, 0)
		butt.BackgroundColor3 = Color3.fromRGB(30, 19, 11)
		butt.BackgroundTransparency = 0.45
		butt.BorderSizePixel = 0
		butt.Active = false
		butt.ZIndex = -1
		butt.Parent = board

		local seam = Instance.new("Frame")
		seam.Name = "Seam"
		seam.Size = UDim2.new(1, 0, 0, 2)
		seam.Position = UDim2.new(0, 0, 1, -2)
		seam.BackgroundColor3 = Color3.fromRGB(28, 18, 10)
		seam.BackgroundTransparency = 0.3
		seam.BorderSizePixel = 0
		seam.Active = false
		seam.ZIndex = -1
		seam.Parent = board
	end

	-- Corner shading. Two crossed gradients, both UNDER the map, so the desk
	-- gains depth without a single pixel of the chart being dimmed.
	for _, rot in { 0, 90 } do
		local vign = Instance.new("Frame")
		vign.Name = "Vignette" .. rot
		vign.Size = UDim2.fromScale(1, 1)
		vign.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		vign.BorderSizePixel = 0
		vign.Active = false
		vign.ZIndex = -1
		vign.Parent = desk
		local g = Instance.new("UIGradient")
		g.Rotation = rot
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(0.35, 1),
			NumberSequenceKeypoint.new(0.65, 1),
			NumberSequenceKeypoint.new(1, 0.55),
		})
		g.Parent = vign
	end
end

-- The map is drawn as a grid of EditableImage tiles (the runtime caps any one
-- image below 1024px per axis), so the camera moves this container and the
-- tiles sit inside it with Scale layout.
local mapImage = Instance.new("Frame")
mapImage.Name = "Map"
mapImage.BackgroundTransparency = 1
mapImage.BorderSizePixel = 0
mapImage.Active = true
-- HIDDEN UNTIL THERE IS A MAP ON IT (2026-09-16). The sheet built just below --
-- PaperEdge, an OPAQUE cream rectangle -- and its four shadows are created here
-- at module scope, but the terrain they are a backdrop for only exists once
-- Renderer.new runs, off the round's `init`. Between those two moments this
-- container drew a blank cream page on the desk: the "white map" that flashed
-- before every round loaded. The desk is the right thing to be looking at while
-- a round is still arriving, so the sheet stays off until it means something.
mapImage.Visible = false
mapImage.Parent = viewport
-- The chart is a SHEET lying on that desk: a paper margin and a soft drop
-- shadow, offset downward so the light reads as coming from above. Both are
-- children of the map container, so the camera pans and zooms them for free,
-- but both are sized in OFFSET so they stay the same few pixels wide at every
-- zoom -- a Scale-sized shadow would grow to hundreds of pixels zoomed in.
for _, layer in { { 34, 13, 0.9 }, { 24, 9, 0.82 }, { 16, 6, 0.7 }, { 9, 4, 0.55 } } do
	local grow, drop, alpha = layer[1], layer[2], layer[3]
	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow" .. grow
	shadow.Size = UDim2.new(1, grow * 2, 1, grow * 2)
	shadow.Position = UDim2.new(0, -grow, 0, -grow + drop)
	shadow.BackgroundColor3 = Color3.fromRGB(18, 11, 5)
	shadow.BackgroundTransparency = alpha
	shadow.BorderSizePixel = 0
	shadow.Active = false
	shadow.ZIndex = 0
	shadow.Parent = mapImage
end

local paper = Instance.new("Frame")
paper.Name = "PaperEdge"
paper.Size = UDim2.new(1, 14, 1, 14)
paper.Position = UDim2.new(0, -7, 0, -7)
paper.BackgroundColor3 = Color3.fromRGB(224, 214, 190)
paper.BorderSizePixel = 0
paper.Active = false
paper.ZIndex = 0
paper.Parent = mapImage

-- ONE POINTER SOURCE, ONE SPACE, AND THAT IS THE WHOLE OF IT.
-- `viewport` is a full-screen frame inside an IgnoreGuiInset ScreenGui, so its
-- top-left IS the top-left of the window, which makes viewport space and the
-- space UserInputService reports a pointer in the same space -- no inset term
-- anywhere. The camera lives there too: `camera:apply` writes `camera.x/y`
-- straight into the map container's Position, which is relative to this frame.
-- So a pointer sampled here goes to `screenToTile` unconverted.
--
-- WHAT THIS REPLACES, AND WHY: two conversions, `toLocal` for
-- GuiObject.MouseMoved and `pointerToAbs` for UserInputService, on the premise
-- that those two APIs report a pointer exactly one topbar apart. That premise
-- is not reliable -- it changed with the topbar rework (the inset went 36 ->
-- 58, and Roblox's own MouseMoved sample still hardcodes 36), and it differs
-- between Studio and a live client. When it is wrong the two paths disagree by
-- a topbar and THE TILE THAT HIGHLIGHTS IS NOT THE TILE THAT GETS ATTACKED,
-- which reads as "the mouse does not point where it is pointing".
--
-- Sampling ONE api for every path makes the question unanswerable instead of
-- answering it wrongly: hover, click, zoom anchor and edge scroll are now
-- literally the same numbers, so they cannot drift apart whatever the engine
-- does with its topbar next.
-- MEASURED IN A LIVE CLIENT, not assumed (2026-08-31), because this has been
-- wrong more than once:
--
--   GuiService:GetGuiInset()      = (0, 58)     -- 36 in a shipped client
--   viewport.AbsolutePosition     = (0, -58)    -- IgnoreGuiInset, full screen
--   viewport.AbsoluteSize         = the whole window
--   UserInputService:GetMouseLocation() == GuiObject.MouseMoved(x, y)  EXACTLY
--   legacy Mouse.X/Y              = both of those minus the inset
--
-- So MouseMoved is in WINDOW space, the same as UserInputService -- it is the
-- LEGACY Mouse that sits one topbar lower, and the old code had it backwards.
-- Everything here samples UserInputService and converts once.
--
-- `viewport`'s origin in WINDOW space is its AbsolutePosition (which is in GUI
-- space, whose origin is one inset lower) plus that inset. Today that comes
-- out (0, 0) and this is arithmetically a no-op -- but it is COMPUTED rather
-- than assumed, so it stays right if the inset changes (36 live, 58 in Studio,
-- more behind a notch), if this ScreenGui ever stops ignoring the inset, or if
-- the frame ever stops being the whole window. Read fresh every sample: the
-- inset is not constant across a session (it reports (0,0) for the first frame
-- after a join, and the map does not exist yet then).
local function viewportOrigin(): (number, number)
	local o = viewport.AbsolutePosition + GuiService:GetGuiInset()
	return o.X, o.Y
end

-- THERE ARE TWO SPACES AND UserInputService USES BOTH. Measured in a live
-- client, all four sampled in the same instant for the same pointer:
--
--   UserInputService:GetMouseLocation()   (700, 318)   WINDOW space
--   GuiObject.MouseMoved(x, y)            (700, 318)   WINDOW space
--   InputObject.Position                  (700, 260)   GUI space
--   legacy Mouse.X/Y                      (700, 260)   GUI space
--
-- The gap is exactly the top-left GUI inset (58 in Studio, 36 in a shipped
-- client). So `MouseMoved` is NOT in the same space as `InputObject.Position`
-- even though both arrive from the same service, and either one converted with
-- the other's rule lands a whole topbar out.
--
-- That is the bug, and it had been fixed in both directions before: hover ran
-- 58px low while clicks ran 58px high, 116px apart, so whichever one you
-- looked at last was the one that seemed broken. Hence two named converters
-- and no bare arithmetic anywhere -- a call site now has to say which API it
-- got its numbers from, and that is the only thing it can get wrong.
--
-- Both are computed from live geometry rather than from a constant: today
-- `fromWindow` is arithmetically a no-op (a full-screen frame in an
-- IgnoreGuiInset ScreenGui sits at AbsolutePosition (0, -58) against an inset
-- of (0, 58)) but it stays right if the inset changes, if this gui stops
-- ignoring the inset, or if the frame stops being the whole window.

-- For GetMouseLocation and GuiObject mouse events.
local function fromWindow(x: number, y: number): (number, number)
	local ox, oy = viewportOrigin()
	return x - ox, y - oy
end

-- For InputObject.Position -- mouse buttons, mouse movement and TOUCH, which
-- has no other source. GUI space, so it is offset by the viewport's own
-- AbsolutePosition and nothing else.
local function fromGui(x: number, y: number): (number, number)
	local o = viewport.AbsolutePosition
	return x - o.X, y - o.Y
end

local function pointer(): (number, number)
	local m = UserInputService:GetMouseLocation()
	return fromWindow(m.X, m.Y)
end

-- Parented to the MAP CONTAINER, not the screen, so the camera pans and
-- zooms the nation names along with the territory they sit on.
local nationLabels = NationLabels.new(mapImage)
-- Cities. Also a child of the map container, for the same reason.
local structures = Structures.new(mapImage)
-- Warheads in flight and the craters they leave. Same container, and the top
-- layer on it: nothing on this map outranks a nuke.
local missiles = Missiles.new(mapImage)

local hud = HUD.new(screen)
-- HUD panels swallow clicks so they never leak through to the map.
-- "Bar" joined this list when the size buttons landed on it: an inactive
-- Frame lets a press through to the map underneath, so missing a button by
-- a few pixels would have launched an attack instead of changing a setting.
-- "Rail" is that case once more: its buttons eat their own clicks, but the
-- 8px gutters between them are the frame, and a press there would build
-- nothing and declare a war.
for _, name in { "Army", "Ratio", "Board", "Banner", "Bar", "Rail" } do
	local p = screen:FindFirstChild(name)
	if p and p:IsA("GuiObject") then
		p.Active = true
	end
end

-- A CONTROLLER PLAYS THIS THROUGH ROBLOX'S VIRTUAL CURSOR -- the left stick
-- is the mouse and A is its button -- so every pointer handler in this file
-- serves a console unchanged. Anchored on the map so the cursor comes up
-- over the ground rather than over a panel. The pad's OWN controls (right
-- stick, triggers, B, X / Y / LB / RB, d-pad) are the `gp` block below the
-- click handlers.
Gamepad.watch(viewport)

local camera = Camera2D.new()
-- HOW LOUD ANYTHING THAT HAPPENS ON THE MAP IS. Every positional sound is
-- attenuated against the VIEW rather than against the map, so the mix is a
-- function of where you are looking -- see the Sfx header.
Sfx.setCamera(camera)

-- ================================================================= state ===

local renderer: any = nil
local myId = 0
local roundId = 0
local playableLand = 1
-- The win check's denominator and the bar it tests against, both straight off
-- the server: the HUD draws the finish line from these and nothing here
-- recomputes either.
local contestedLand = 1
local winThreshold = 0
-- The last teamStats the server sent, and the biggest empire in a free-for-all.
-- The share bar is refreshed from whichever of the two this mode has.
local teamStats: { any }? = nil
local leadId: number? = nil
local leadTiles = 0
-- What the next click commits. The player sets it from the three size
-- buttons on the command bar or with 1 / 2 / 3; the server snaps whatever
-- arrives to the same preset list, so this is a preference, not a trusted
-- input.
local attackRatio = Config.DEFAULT_ATTACK_RATIO
local phase = "lobby"
local phaseRemaining = 0
local hasSpawned = false
-- Where your dot is standing, while the round has not started. nil once it
-- has: the ring comes off, and the empire underneath is the thing on the map.
local myPick: number? = nil
-- HISTORICAL MODE: the nation your claim is standing on, by name, for the
-- banner; and the round's scenario payload from init (nil on an ordinary
-- round). The click on a predrawn map claims a COUNTRY, so the ring sits on
-- its capital and the banner says which one rather than "tap again to move".
local myPickName: string? = nil
local historical: any = nil
local winnerName: string? = nil

-- Empire id -> { r, g, b } from the scenario payload. Keys cross the wire as
-- strings (a sparse numeric table is a dictionary to the remote), exactly as
-- the team map does, so they are put back to numbers here.
local function nationColors(h: any): { [number]: { number } }?
	if type(h) ~= "table" or type(h.colors) ~= "table" then
		return nil
	end
	local map = {}
	for id, c in h.colors do
		map[tonumber(id) or id] = c
	end
	return map
end

-- Every one of these is a pair: the value the server last told us, and the
-- value currently on screen walking toward it. Nothing the player reads is
-- ever written straight from a network message.
local myTroops, myTroopsShown = 0, 0
local myMaxTroops, myMaxShown = Config.BASE_MAX_TROOPS, Config.BASE_MAX_TROOPS
local myTiles = 0
local myGain, myGainShown = 0, 0
-- Treasury and structures. Private state: these arrive only for you, on the
-- same per-client message the fronts do.
local myGold, myGoldShown = 0, 0
-- WHAT YOUR FIRST ONE COSTS, which stopped being the ladder's base when the
-- opening rungs went in (Config.CITY_COST_STEPS). Overwritten by the first
-- `fronts` message; the server prices every build and this is only what shows
-- until it does.
local myCityCost = Config.CITY_COST_FIRST
local myPortCost = Config.PORT_COST_FIRST
local myFactoryCost = Config.PORT_COST_FIRST
-- The defence post's ladder is linear and its own (Config.DEFENSE_POST_COST_*),
-- so the first rung is the constant rather than a STEPS list.
local myPostCost = Config.DEFENSE_POST_COST_STEP or 50000
local myCities, myPorts, myCityLevels = 0, 0, 0
local myFactories = 0
-- FREE WARHEADS IN HAND ("+1 Nuke!", tutorial only) would belong here, beside
-- the treasury, and there is NO REGISTER LEFT FOR IT: one more local in this
-- chunk is "Out of local registers ... exceeded limit 200" and the file stops
-- compiling outright. It lives on the HUD instead -- hud:setFreeNukes /
-- hud:freeNukes -- the same answer Sfx gives for the at-war set and the pop
-- curve. Anything added here from now on has to displace something first.
-- Armed by B. While it is on, a click buys a building instead of launching an
-- attack; C and P choose WHICH. Two keys rather than a menu, because there are
-- two things to build and a menu with two entries is a menu you have to open.
local buildMode = false
-- These are Units type ids, which is what the server's build intent expects:
-- 1 city, 2 port, 6 FACTORY. Not a dense 1..3 -- the wire numbering wins.
local buildKind = 1
local KIND_CITY, KIND_PORT, KIND_FACTORY, KIND_POST = 1, 2, 6, 3
local KIND_NAME = { [1] = "CITY", [2] = "PORT", [6] = "FACTORY", [3] = "DEFENSE", [5] = "ANTI-NUKE", [18] = "ARTILLERY GUN", [19] = "AIRFIELD", [21] = "RAILGUN" }
-- Units.ATOM_BOMB. Written out rather than required: the client needs ONE
-- number from a 56 KB module, and this comment is the twin the rule about
-- duplicated constants asks for.
local KIND_ATOM = 13
-- Armed exactly the way build mode is, and MUTUALLY EXCLUSIVE with it. One
-- click can only mean one thing, and "place a house" and "erase a city" are
-- the worst possible pair to leave ambiguous.
local nukeMode = false

-- WHY A PLACEMENT WAS REFUSED, IN ONE PLACE. Every rule that can stop a city
-- gets its own sentence: "too close to another building" and "not enough gold"
-- are the same silence otherwise, and the player has no way to tell which one
-- they hit.
--
-- Two callers, and that is the point. The server's `denied` reply passes its
-- reason through here, and so does the PLACEMENT GHOST -- which knows the same
-- answer before the click and says it without a round trip. One function is
-- what stops the two ever wording the same refusal differently.
-- SHORTENED 2026-09-03 with the rest of the notifications. Every one of these
-- used to be a sentence explaining the rule; what a refusal has to do is name
-- the reason in the half second before the player tries again, and the number
-- each of them quoted (the price, the spacing, the port radius) is already on
-- the rail button or under the pointer. `kind` and `cost` are still taken so
-- neither caller has to change.
local function buildRefusalText(reason: string?, _kind: number?, _cost: number?): string?
	if reason == "gold" then
		return "Not enough gold"
	elseif reason == "noland" then
		return "No land to launch from"
	elseif reason == "nosilo" then
		return "No silo ready"
	elseif reason == "friendly" then
		return "Your own side"
	elseif reason == "teammate" then
		return "Your own side's buildings"
	elseif reason == "crowded" then
		return "Too close to another building"
	elseif reason == "land" then
		return "Your own land only"
	elseif reason == "terrain" then
		return "Cannot build there"
	elseif reason == "maxlevel" then
		return "Already at max level"
	elseif reason == "coast" then
		return "No coast of yours nearby"
	-- Reinforcements (2026-09-21). "gold" above covers the third refusal.
	elseif reason == "full" then
		return "Army already at its limit"
	-- "cooldown" is TWO refusals: the airfield's reply names its kind (19),
	-- a reinforcement refusal names none.
	elseif reason == "cooldown" then
		return if _kind == 19 then "Airfield is rearming"
			elseif _kind == 21 then "Railgun is reloading"
			else "Reinforcements not ready yet"
	-- The airfield's other refusals (2026-09-21), Airstrikes.order's words.
	elseif reason == "range" then
		return "Out of the airfield's range"
	elseif reason == "notyours" then
		return if _kind == 21 then "No railgun of yours there" else "No airfield of yours there"
	elseif reason == "notready" then
		return if _kind == 21 then "Railgun is still being built" else "Airfield is still being built"
	-- The server's answer to a pass-gated card ordered without its pass (the
	-- mega nuke, 2026-09-22; the battery, the airfield and the reinforcements
	-- the same day). An honest client never sees one -- the card is hidden and
	-- `arm` refuses the key -- so this is for the crafted one, and for the
	-- one whose pass attribute had not landed yet when it pressed.
	--
	-- WHICH PASS, off the kind the refusal already carries: 18 the battery, 19
	-- the airfield, 17 the mega nuke. A reinforcement refusal names no kind
	-- (see the reinforce branch in ConquestServer), so it gets the plain line.
	elseif reason == "pass" then
		return if _kind == 18
			then "Artillery pass required"
			elseif _kind == 19 then "Air Strike pass required"
			elseif _kind == 17 then "Mega Nuke pass required"
			elseif _kind == 21 then "Railgun pass required"
			elseif _kind == 20 then "Scattershot pass required"
			else "Gamepass required"
	end
	return nil
end

local snapshotChunks: { [number]: boolean } = {}
local snapshotExpected = 0
local snapshotSeen = 0
-- Snapshot chunks are pieces of a run-length stream now, so they have to
-- be reassembled before they mean anything.
local snapshotBuf: buffer? = nil
local snapshotRaw = false

-- Name per id. Constant for a round, so it arrives once with `init`
-- instead of riding on every summary five times a second.

local rosterById: { [number]: string } = {}
-- The headshot on a standings row is drawn from the Roblox user id, which
-- rides with the roster (sent once) rather than with the five-a-second
-- summary. Bots have none.
local rosterUserId: { [number]: number } = {}

local pendingDeltas: { buffer } = {}

local playersById: { [number]: any } = {}
local teamById: { [number]: number } = {}
local botById: { [number]: boolean } = {}
local teamCount = 0
local myTeam: number? = nil
local modeName = "FREE FOR ALL"
local incomingCount = 0
-- HOW MUCH FIGHTING YOU ARE IN, counted off the fronts message and read by the
-- artillery ambience at the bottom of this file. Both directions count:
-- pushing into somebody is as loud as being pushed into.
local frontHeat = 0
local alertText: string? = nil
local alertUntil = 0
-- The alert line is a WARNING everywhere but one place: an elimination pays
-- gold, and painting that red would read as bad news. The override is stored
-- WITH the text it belongs to rather than as a colour that lingers, so the
-- next ordinary alert goes back to red without every call site having to
-- remember to clear it.
local alertColor: Color3? = nil
local alertColorText: string? = nil
local lastHoverOwner = -1
local lastMouse = Vector2.zero
local elapsed = 0
-- THE WAR CLOCK, which is not `elapsed`: that one starts when the round is
-- built and runs all the way through the placement phase, and how long you
-- spent choosing where to stand is not part of how long the match has been
-- going. See HUD.setTimer.
local warElapsed = 0

-- Is the pointer over the MAP rather than over a HUD panel? Fed by the map
-- frame's own MouseMoved / MouseLeave, which the HUD panels already mask. The
-- edge scroll reads it so that reaching for a HUD control -- the action rail
-- sat ON the right edge of the screen when this was written -- does not run
-- the map out from under the pointer.
local pointerOverMap = false
-- Set whenever the camera moves under a pointer that did not move: the tile
-- under the cursor changed without the cursor changing, and the hover card and
-- the highlight have to catch up or they describe where you used to be.
local hoverDirty = false

-- Forward declarations. All three are defined down with the rest of the click
-- feedback, but the "denied" and "built" message handlers ABOVE them need
-- them, and a `local` is not in scope before its own definition -- so the call
-- site saw nil and every refused click threw instead of explaining itself.
-- Assigned below, not redeclared (hence `function`, not `local function`, at
-- the definition of `ping`).
--
-- `lastClickTile` is the same bug wearing different clothes, and it is worth
-- spelling out because it is invisible: the handlers were not reading a stale
-- value, they were reading a GLOBAL of that name, while every click handler
-- wrote the local one further down. So the red ring that marks a refusal
-- could never have found the tile even if `ping` had existed -- which is
-- exactly the case a boat launch hits, since "nobeach", "nosearoute" and
-- "toomanytransportboats" all come back as `denied`.
local flashTarget: (number, Color3) -> ()
local ping: (number, Color3) -> ()
-- FORWARD-DECLARED FOR EXACTLY THE REASON `ping` IS. The "built" handler is
-- written above the block that defines this colour, so `ping(tile, GOLD)` there
-- compiled as a GLOBAL read: nil at runtime, and assigning nil to a UIStroke's
-- Color threw on every single building placed -- no gold ring, and an error in
-- the log for each one. The assignment stays where the colour is explained; by
-- the time any message arrives the script has run top to bottom and set it.
local GOLD: Color3
local skull: (number) -> ()
-- What a port just earned, printed over the port. Forward-declared for the
-- same reason `skull` is: the message handler that fires it is written above
-- the function that draws it.
local payout: (number, number) -> ()
-- The ring around YOUR dot while the round has not started. Forward-declared
-- for the same reason `ping` is: the message handler that moves it is written
-- above the function that draws it.
local setPick: (number?) -> ()
-- WHERE THE CURRENT LESSON IS POINTING. Same forward-declaration reason again:
-- both the `init` handler and the `tutorial` one set it, and both are written
-- above the block that draws it.
local setTutorialTarget: (number?) -> ()
-- ...and the HUD is the one that calls it, on every card it actually puts up.
-- The first card of a round is HELD a second after `init` (see
-- HUD.setTutorialHold), and the ring has to wait with it or the tutorial
-- points at ground the words have not mentioned yet. A field on `hud`, not a
-- local: this file is at Luau's 200-local ceiling, and the three locals this
-- logic first took here did not compile.
hud.onTutorial = function(state: any?)
	-- The card's own tile, kept where the frame loop can read it: the first
	-- airfield's ring (see stepGuide's caller) borrows this same ring whenever
	-- no card is pointing anywhere, and a card's tile always wins.
	hud.lessonTile = state and state.target or nil
	setTutorialTarget(hud.lessonTile)
end
local lastClickTile: number? = nil

hud:setRatio(attackRatio, 0)

local TERRAIN_NAME = { [0] = "ocean", "plains", "highland", "mountain", "impassable" }

local function updateViewport()
	local size = viewport.AbsoluteSize
	hud:layout(size.X, size.Y)
	camera:setViewport(size.X, size.Y)
	-- The camera has to know what the HUD is standing on before it clamps: those
	-- two bands are pan it is allowed to give back, and `fit` sizes the spawn
	-- view to the clear strip between them.
	camera:setInsets(hud:insets(size.X, size.Y))
	camera:clamp()
	camera:apply(mapImage)
end

viewport:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateViewport)

-- ============================================================== messages ===

local function applyDelta(buf: buffer)
	if not renderer then
		table.insert(pendingDeltas, buf)
		return
	end
	-- TAKING GROUND OFF SOMEBODY IS THE POINT OF THE GAME, AND IT WAS SILENT.
	-- This is the only place the client ever learns that a tile changed hands,
	-- and the owner byte is read here BEFORE setOwner overwrites it -- the one
	-- moment at which the empire that just lost the tile still exists to be
	-- asked about.
	--
	-- OPEN LAND COUNTS TOO (owner, 2026-09-05). It used to be excluded on the
	-- reasoning that claiming an empty tile is expansion and this cue is for
	-- territory that was somebody's -- but taking empty ground is most of what a
	-- player does for the first minutes of a round, and it was the part of the
	-- game the mix said nothing about at all. What the pop measures is the rate
	-- the front is MOVING, and a front moving into nobody is still moving.
	--
	-- A TEAMMATE'S STILL DOES NOT. A bloc taking ground off itself is not a
	-- conquest, and neither is a tile of your own arriving twice.
	local owners = renderer.owner
	local taken, at = 0, -1
	Net.unpackDelta(buf, function(tile, owner)
		if owner == myId then
			local lost = buffer.readu8(owners, tile)
			if lost ~= myId and (lost == 0 or myTeam == nil or teamById[lost] ~= myTeam) then
				taken += 1
				at = tile
			end
		end
		renderer:setOwner(tile, owner)
	end)
	if taken > 0 then
		-- ONE POP PER PACKET RATHER THAN PER TILE. A push takes tens or
		-- hundreds of tiles on a single tick and the ear hears all of that as
		-- one bite, so what the pops end up measuring is the RATE THE FRONT IS
		-- MOVING, which is the thing worth hearing. Any tile in the packet
		-- will do for where it came from: a front is contiguous.
		local x = at % Config.MAP_W
		-- HOW CLOSE TO OWNING THE LOT, measured against the same finish line
		-- the win bar draws, so the sound and the bar can never disagree about
		-- how close the round is to over. The BLOC's share in a team round,
		-- because that is whose victory it would be.
		local land = contestedLand > 1 and contestedLand or playableLand
		local held = myTiles
		if myTeam and teamStats and teamStats[myTeam] then
			held = teamStats[myTeam].tiles
		end
		local goal = math.max(1, land * (winThreshold > 0 and winThreshold or Config.WIN_PERCENT_FFA))
		-- A SPAWN CLAIM IS ONE POP, NOT A RATE (owner, 2026-09-12: "when i
		-- spawn and select a place on the map, i hear 2 pops ... i only wanna
		-- hear 1 pop"). Picking a spot paints a whole radius-4 disc in a
		-- single delta -- the dot is real territory from the first click --
		-- and the rate machinery reads one fat packet as a fast front and
		-- pays out two strikes for it. Nothing is moving: it is a placement,
		-- and re-picking pays it again. See Sfx.popOnce.
		if phase == "spawn" then
			Sfx.popOnce(taken, x, (at - x) / Config.MAP_W, held / goal)
		else
			Sfx.pop(taken, x, (at - x) / Config.MAP_W, held / goal)
		end
	end
end

-- The share bar and its finish line. A team round has real blocs to draw, so it
-- draws them. A free-for-all has seventy-two empires, which is not a bar anybody
-- can read, so it draws exactly one segment -- the LEADER -- because the only
-- question the bar exists to answer there is how close the empire in front is to
-- taking the map.
local function refreshWinBar()
	local land = contestedLand > 1 and contestedLand or playableLand
	if teamCount > 0 then
		hud:setTeamBar(teamStats, land, myTeam, winThreshold)
	elseif leadId and leadTiles > 0 then
		hud:setTeamBar(
			{ { tiles = leadTiles, troops = 0, alive = 1 } },
			land,
			nil,
			winThreshold,
			Palette.playerColor3(leadId, myId)
		)
	else
		hud:setTeamBar(nil, land, myTeam)
	end
end

StateRE.OnClientEvent:Connect(function(kind, payload, extra)
	if kind == "init" then
		roundId = payload.round
		myId = payload.yourId
		playableLand = payload.playableLand
		phase = payload.phase
		phaseRemaining = payload.phaseRemaining or 0
		hasSpawned = false
		-- ...AND THE ALERT LINE GOES WITH THEM. These four and the last click
		-- were the only round-scoped state `init` did not clear, so a rotation
		-- inside the alert's four seconds printed the previous round's "X has
		-- fallen" over the new round's spawn banner, and a refusal arriving
		-- before the first click rang a tile from the round before.
		alertText = nil
		alertUntil = 0
		alertColor = nil
		alertColorText = nil
		lastClickTile = nil
		myPick = nil
		myPickName = nil
		historical = payload.historical
		setPick(nil)
		winnerName = nil
		-- Last round's receipt, if a Studio session rotated in place before it
		-- had finished fading.
		hud:setPayout(nil)
		hud:setRevive(nil)
		-- ...and the bottom of the HUD comes back. A REVIVE is an `init` of its
		-- own (ConquestServer.takeover sends one), so this is also what puts the
		-- command bar and the rail back under a player who bought their way in.
		hud:setDefeated(false)
		-- A special mode's flat ceiling (Modes.SPECIAL troopCapBonus), into the
		-- mirror of Sim.maxTroops on the summary below. Held by the HUD: this
		-- file has no local left. 0 on every ordinary round.
		hud:setCapBonus(payload.troopCapBonus or 0)
		elapsed = 0
		warElapsed = 0
		myTroops, myTroopsShown, myTiles = 0, 0, 0
		myGain, myGainShown = 0, 0

		if renderer then
			renderer:destroy()
		end
		table.clear(snapshotChunks)
		snapshotExpected = 0
		snapshotSeen = 0
		snapshotBuf = nil
		table.clear(rosterById)
		table.clear(rosterUserId)
		-- Cleared before the roster is read, so an empire id that a different
		-- player drew this round cannot inherit the last one's pattern.
		Patterns.clearOwners()
		NationLabels.clearFlags()
		for _, e in payload.roster or {} do
			rosterById[e.i] = e.n
			rosterUserId[e.i] = e.u
			NationLabels.setFlag(e.i, e.f)
			-- `e.p` is absent on every empire wearing none, which is most of
			-- them; setOwner reads a nil as "solid".
			Patterns.setOwner(e.i, e.p)
		end
		table.clear(pendingDeltas)

		table.clear(playersById)
		incomingCount = 0
		lastHoverOwner = -1

		-- Teams must be installed in the Palette BEFORE the renderer is built
		-- and before the snapshot repaint, because every owned pixel is
		-- coloured through Palette.colorFor.
		teamCount = payload.teamCount or 0
		modeName = payload.modeName or "FREE FOR ALL"
		table.clear(teamById)
		if payload.teams and teamCount > 0 then
			for id, t in payload.teams do
				teamById[tonumber(id) or id] = t
			end
		end
		myTeam = teamById[myId]
		Palette.setTeams(teamCount > 0 and teamById or nil, teamCount)

		-- Same reason as teams: which empires are AI has to be installed in the
		-- Palette BEFORE the renderer is built and before the snapshot repaint,
		-- or every bot is painted in a player colour and then corrected by a
		-- full-map repaint a fraction of a second later.
		table.clear(botById)
		if payload.botIds then
			for _, id in payload.botIds do
				botById[tonumber(id) or id] = true
			end
		end
		Palette.setBots(botById)
		-- ...and, on a predrawn map, the nations' colours, for the same
		-- reason and at the same moment. nil clears them on an ordinary round.
		Palette.setNations(nationColors(historical))
		teamStats = nil
		leadId, leadTiles = nil, 0
		winThreshold = 0
		contestedLand = payload.playableLand or 1
		hud:setTeamBar(nil, playableLand, myTeam)
		hud:setFronts({}, {})
		hud:setHover(nil)
		-- The lesson card, and it is ABSENT in every ordinary round -- which is
		-- also what takes the card away when a Studio session rotates from a
		-- tutorial into a normal one. With it the ring, so a client that joined
		-- mid-lesson is shown the ground its card is talking about rather than
		-- the card alone; nil in an ordinary round, which tears the ring down.
		-- ONE SECOND AFTER LOADING IN, not on this frame (owner, 2026-09-11) --
		-- see HUD.setTutorialHold. The ring follows through hud.onTutorial.
		hud:setTutorialHold(1)
		hud:setTutorial(payload.tutorial)

		hud:setIdentity(player.DisplayName, Palette.playerColor3(myId, myId))
		hud:setTarget("PLAYER")
		myGold, myGoldShown = 0, 0
		myCities, myPorts, myCityLevels = 0, 0, 0
		myFactories = 0
		myCityCost = Config.CITY_COST_FIRST
		myPortCost = Config.PORT_COST_FIRST
		myFactoryCost = Config.PORT_COST_FIRST
		buildMode = false
		buildKind = 1
		attackRatio = Config.DEFAULT_ATTACK_RATIO
		hud:setGold(0, myCityCost, 0)
		hud:setGain(0)

		nationLabels:clear()
		structures:clear()
		structures:setLocalId(myId)
		-- A predrawn map opens with every nation's cities already standing,
		-- so its chips draw smaller (owner, 2026-09-11: "way too cluttered").
		structures:setScale(historical and Structures.HISTORICAL_SCALE or 1)
		missiles:clear()
		missiles:setLocalId(myId)
		-- Whatever the last round was still ringing with, cut. A Studio session
		-- rotates in place, so without this a detonation from the round before
		-- can arrive over the first frame of this one.
		Sfx.stopAll()
		frontHeat = 0
		renderer = Renderer.new(payload.mapId or "us", payload.seed, mapImage)
		renderer:setLocalId(myId)
		-- A transport's route is painted into the map's WATER PIXELS, so the
		-- boat layer needs the image to paint into. After Renderer.new by
		-- necessity and after structures:clear by design -- the clear puts the
		-- previous round's routes back to open water while the renderer that
		-- holds them is still the one they were stamped into.
		structures:setRenderer(renderer)
		-- The blast set is regenerated here from the seed the server sent with
		-- the detonation, and regenerating it needs exactly one thing: the
		-- terrain buffer, which the renderer has already built from the same
		-- map id and the same seed the simulation used.
		missiles:setMap(renderer.terrain)
		missiles.onFallout = function(tiles, count)
			if renderer then
				renderer:setFalloutTiles(tiles, count)
			end
		end
		-- IS THAT WARHEAD FOR ME. Missiles holds no ownership of its own and
		-- this is the only question it needs answered -- a launch aimed at your
		-- ground raises the siren, one aimed at anybody else's does not.
		--
		-- TEAMMATES DELIBERATELY DO NOT COUNT. An ally being nuked is an ally's
		-- alarm, and in a 72-empire team round counting them would sound one for
		-- half the map, which is the same as sounding it for nothing.
		missiles.ownerAt = function(tile)
			local r = renderer
			if r == nil or tile < 0 or tile >= buffer.len(r.owner) then
				return false
			end
			return buffer.readu8(r.owner, tile) == myId
		end
		updateViewport()
		camera:fit()
		camera:apply(mapImage)
		-- AND NOW THE SHEET COMES OUT. The terrain is painted and the camera is
		-- fitted, so the first frame anyone sees of this container is the real
		-- map rather than a blank page. See mapImage.Visible at its creation.
		mapImage.Visible = true

	elseif kind == "snapshot" then
		if not renderer or payload.round ~= roundId then
			return
		end
		if not snapshotChunks[payload.index] then
			snapshotChunks[payload.index] = true
			snapshotSeen += 1
			snapshotExpected = payload.count
			snapshotRaw = payload.raw == true
			-- Chunks are slices of one run-length stream, so they are
			-- reassembled first and decoded once at the end.
			if snapshotBuf == nil then
				snapshotBuf = buffer.create(payload.bytes)
			end
			buffer.copy(snapshotBuf :: buffer, payload.offset, payload.data, 0)
			if snapshotSeen >= snapshotExpected then
				if snapshotRaw then
					renderer:loadOwners(snapshotBuf :: buffer, 0)
				else
					Net.unpackOwners(snapshotBuf :: buffer, renderer.owner)
					renderer.hasOwners = true
				end
				snapshotBuf = nil
				renderer:repaintAll()
				for _, buf in pendingDeltas do
					applyDelta(buf)
				end
				table.clear(pendingDeltas)
			end
		end

	elseif kind == "historical" then
		-- The nations' colours again, keyed by whoever holds each nation NOW:
		-- sent once, the tick the spawn phase ends and the people take their
		-- seats. A colour that moved is a full repaint, the same rule the
		-- team and bot maps follow; and your own swatch follows your nation.
		historical = payload
		if Palette.setNations(nationColors(payload)) and renderer then
			renderer:repaintAll()
		end
		hud:setIdentity(player.DisplayName, Palette.playerColor3(myId, myId))

	elseif kind == "roster" then
		-- A ROSTER RE-SEND IS USUALLY A PATTERN ARRIVING -- a profile lands a
		-- second or two after its owner does, because the lobby server has to
		-- release the session lock first. Only the empires whose answer MOVED
		-- are repainted, and each on its own footprint through the block
		-- index: the alternative is repaintAll, which is every tile on the
		-- map for what is typically one player standing on nine of them.
		for _, e in payload do
			rosterById[e.i] = e.n
			rosterUserId[e.i] = e.u
			NationLabels.setFlag(e.i, e.f)
			if Patterns.setOwner(e.i, e.p) and renderer then
				renderer:repaintOwner(e.i)
			end
		end

	elseif kind == "players" then
		-- Ten packed bytes per empire. The name comes from the roster, which
		-- does not change inside a round.
		local list = Net.unpackPlayers(payload)
		for _, e in list do
			e.name = rosterById[e.id] or "?"
			e.userId = rosterUserId[e.id]
		end
		payload = list
		local teamsChanged = false
		local botsChanged = false
		for _, entry in payload do
			entry.landPercent = playableLand > 0 and (entry.tiles / playableLand * 100) or 0
			-- A human who leaves is handed straight to the AI mid-round, but
			-- KEEPS THEIR COLOUR (owner rule): an id only ever goes bot -> human
			-- here (a takeover), never human -> grey. The init list decides who
			-- starts grey, and the server leaves leavers out of it.
			-- Compare NORMALISED booleans. `entry.isBot` arriving as nil against
			-- a stored false would differ on every broadcast, and each difference
			-- costs a full-map repaint five times a second.
			local nowBot = entry.isBot == true
			if not nowBot and botById[entry.id] == true then
				botById[entry.id] = nowBot or nil
				botsChanged = true
			end
			if entry.team then
				entry.tag = Palette.teamTag(entry.team)
				if teamById[entry.id] ~= entry.team then
					teamById[entry.id] = entry.team
					teamsChanged = true
				end
			end
		end
		-- Someone joined mid-round. Re-deriving the shades reorders the variants
		-- inside a team, so the map has to be repainted rather than patched.
		local needsRepaint = false
		if teamsChanged and teamCount > 0 then
			-- Only repaint if a colour ALREADY ON THE MAP moved. A joiner
			-- takes the highest id and variants go out in id order, so they
			-- append to their team and shift nobody -- and repainting 1.6M
			-- tiles for that, on every client, every time someone joins, is
			-- the most expensive thing a full server can do to itself.
			needsRepaint = Palette.setTeams(teamById, teamCount)
			myTeam = teamById[myId]
		end
		if botsChanged and Palette.setBots(botById) then
			needsRepaint = true
		end
		if needsRepaint and renderer then
			renderer:repaintAll()
		end
		hud:setStandings(payload, myId)
		-- Who is in front, for the free-for-all share bar: the one figure in a
		-- 72-empire round that a bar can usefully carry. Redone from scratch
		-- twice a second, because a lead changes hands with nothing announcing
		-- it.
		leadId, leadTiles = nil, 0
		for _, entry in payload do
			if entry.alive and entry.tiles > leadTiles then
				leadId, leadTiles = entry.id, entry.tiles
			end
		end
		refreshWinBar()
		if renderer then
			nationLabels:update(renderer, payload, myId)
		end
		for _, entry in payload do
			playersById[entry.id] = entry
			if entry.id == myId then
				-- Change since the last server tick, shown as the floating
				-- +N above the troop bar. A target like everything else --
				-- unsmoothed it flickers between neighbouring values five
				-- times a second and reads as noise.
				myGain = entry.troops - myTroops
				myTroops = entry.troops
				myTiles = entry.tiles
				-- Mirrors Sim.maxTroops EXACTLY, MAX_TROOPS_MULT included. Dropping
				-- that factor halved the ceiling on the client alone, so the bar
				-- pinned at 100% and the income readout sat at "+0/s" for the whole
				-- top half of the growth curve while the army was visibly climbing.
				-- The city term is OUTSIDE the multiplier here too. myCityLevels
				-- arrives on the private `fronts` message, so it can lag this
				-- one by up to a broadcast -- which shows up as the ceiling
				-- stepping a fifth of a second after a city finishes, and never
				-- as a wrong number.
				myMaxTroops = (Config.MAX_TROOPS_MULT or 1)
					* ((entry.tiles ^ Config.TROOPS_TILE_EXPONENT) * Config.TROOPS_PER_TILE_COEF
						+ Config.BASE_MAX_TROOPS)
					+ myCityLevels * Config.CITY_TROOP_INCREASE
					-- ...and the special mode's flat ceiling, outside the
					-- multiplier exactly as Sim.maxTroops adds it.
					+ hud:capBonus()
				if entry.tiles > 0 then
					hasSpawned = true
				end
				-- OUT. The summary only carries empires that have spawned, so
				-- an entry of our own with `alive` false is an empire that fell
				-- -- and it keeps arriving afterwards, which is what makes this
				-- the honest place to read it rather than the revive offer (it
				-- is refused mid-tutorial) or the receipt (survivors get one
				-- too). setDefeated is a no-op unless the answer changed.
				hud:setDefeated(entry.alive ~= true)
			end
		end

	elseif kind == "structs" then
		-- `extra` is the reset flag: an absolute list (a join, or the start of a
		-- round) replaces what we have, an incremental batch is merged. Merging
		-- an absolute list would leave last round's buildings on this round's map.
		if extra then
			structures:setAll(payload)
		else
			for _, c in payload do
				structures:set(c.tile, c.ownerId, c.level, c.kind or 1, c.uc, c.left, c.rl, c.hp, c.rt)
			end
		end

	elseif kind == "rails" then
		if extra then
			structures:setAllRails(payload)
		else
			-- A rail event with no points is a line that was cut.
			for _, r in payload do
				structures:setRail(r.a, r.b, r.pts, r.id)
			end
		end

	elseif kind == "vehicles" then
		-- Boats and trains, on their own slower clock. Positions are targets,
		-- not coordinates: the markers walk toward them a frame at a time.
		structures:setVehicles(Net.unpackVehicles(payload))

	elseif kind == "missiles" then
		-- Launches, detonations, interceptions. Sent ONCE each -- see the
		-- Missiles header -- so this is the whole nuclear channel: everything
		-- between a launch and its flash is drawn from the same curve the
		-- server flies the unit along, and the crater is expanded locally from
		-- the seed in the blast event. `extra` is the server's tick, which is
		-- the clock that replay is against.
		-- A BATTERY'S SHOT TURNS AND KICKS ITS CHIP (2026-09-21): the chip is
		-- Structures' and the shell is Missiles', so the launch event is handed
		-- to both. `sh` only; the rest of the stream is Missiles' alone.
		for _, e in payload do
			if e.e == "sh" or e.e == "rf" then
				structures:gunFire(e.src, e.dst)
			end
		end
		missiles:onEvents(payload, extra)

	elseif kind == "armies" then
		if renderer then
			-- The team map rides along so a teammate's wars get a number too;
			-- in a free-for-all myTeam is nil and only your own do.
			nationLabels:setArmies(Net.unpackArmies(payload), myId, teamById, myTeam)
		end

	elseif kind == "fronts" then
		-- Fronts carry ids; the name is ours to look up.
		for _, e in payload.out do
			e.name = e.id ~= 0 and (rosterById[e.id] or "?") or "open land"
		end
		for _, e in payload.inc do
			e.name = rosterById[e.id] or "?"
		end
		-- setFronts also picks the status line above the list, so the two
		-- always quote the same front and the same smoothed figure.
		hud:setFronts(payload.out, payload.inc)
		-- The treasury rides on this message because it is private too.
		myGold = payload.gold or myGold
		myCityCost = payload.cost or myCityCost
		myPortCost = payload.portCost or myPortCost
		myFactoryCost = payload.factoryCost or myFactoryCost
		myPostCost = payload.postCost or myPostCost
		-- The anti-nuke tower's price, kept on the HUD because this file has no
		-- local register left for it -- see HUD.setSamCost. A PRICE and not a
		-- count, so unlike the free warheads below it keeps its last value when
		-- a message arrives without one.
		if payload.samCost then
			hud:setSamCost(payload.samCost)
		end
		-- REINFORCEMENTS (2026-09-21): the price of one purchase and the ticks
		-- of cooldown left, straight into the rail's cost table -- this file has
		-- no local register left, and ACTION_COSTS is read once a frame by
		-- setActions anyway. The price keeps its last value like every other
		-- price; the countdown is `or 0` like every count, so a message without
		-- one reads as ready rather than as stuck.
		-- ...via the HUD, NOT ACTION_COSTS: that table is declared ~1,900 lines
		-- below this handler, so a write here would index a nil global. The feed
		-- line copies the HUD's copy into ACTION_COSTS every frame.
		hud:setReinforce(payload.reinforceCost, payload.reinforceLeft or 0, payload.reinforceTroops)
		-- The battery's price, on the HUD for the same missing register --
		-- HUD.setArtilleryCost. NOT ACTION_COSTS: that table is declared two
		-- thousand lines below this handler, so a write to it from here would
		-- be a global.
		if payload.artilleryCost then
			hud:setArtilleryCost(payload.artilleryCost)
		end
		-- The airfield's, likewise (2026-09-21) -- see HUD.setAirfieldCost.
		if payload.airfieldCost then
			hud:setAirfieldCost(payload.airfieldCost)
		end
		-- And the railgun's (2026-09-24) -- HUD.setRailgunCost.
		if payload.railgunCost then
			hud:setRailgunCost(payload.railgunCost)
		end
		myFactories = payload.factories or myFactories
		-- Free warheads in hand, kept on the HUD because this file has no local
		-- register left for it -- see HUD.setFreeNukes. `or 0` rather than "keep
		-- the last value", unlike the prices above: this one is a COUNT that
		-- goes DOWN as shots are fired, so a missing field has to read as none
		-- rather than leave the launch button offering a spent warhead.
		hud:setFreeNukes(payload.freeNukes or 0)
		-- Free defence towers, on the HUD for the same missing register and
		-- `or 0` for the same reason: a COUNT that goes down as they are
		-- placed, so a message without one has to read as none rather than
		-- leave the rail offering a tower already built.
		hud:setFreePosts(payload.freePosts or 0)
		hud:setFreeCities(payload.freeCities or 0)
		hud:setFreeSams(payload.freeSams or 0)
		myCities = payload.cities or 0
		myPorts = payload.ports or 0
		myCityLevels = payload.levels or 0
		-- The growth bonus the equipped skin carries, for the income readout.
		-- A field on `hud` and not a local: this file is at Luau's 200-local
		-- ceiling, which is why hud.onTutorial and hud.beginPress live there too.
		hud.growthBoost = payload.boost or 0
		-- A new invader appearing is the one event you must not miss.
		if #payload.inc > incomingCount then
			local worst, worstTroops = nil, -1
			for _, e in payload.inc do
				if e.troops > worstTroops then
					worstTroops = e.troops
					worst = e.name
				end
			end
			if worst then
				alertText = worst .. " is attacking you"
				alertUntil = os.clock() + 3
			end
		end
		incomingCount = #payload.inc
		frontHeat = #payload.inc + #payload.out

	elseif kind == "phase" then
		local was = phase
		phase = payload.phase
		-- Belt and braces for the ring: the per-player "spawned" that opens the
		-- round takes it off, and so does this, so a client that misses one is
		-- not left ringing ground that is an empire now.
		if was == "spawn" and phase ~= "spawn" then
			myPick = nil
			setPick(nil)
		end
		phaseRemaining = payload.remaining or 0
		playableLand = payload.playableLand or playableLand
		contestedLand = payload.contested or playableLand
		winThreshold = payload.threshold or winThreshold
		teamStats = payload.teams
		refreshWinBar()

	elseif kind == "tutorial" then
		-- One of these per LESSON PLUS one whenever the ring moves -- the server
		-- sends a card when the one before it was completed, and again when the
		-- tile it is pointing at stopped being a legal answer. The grace clock on
		-- it is counted down by the HUD from the figure that arrived here. The
		-- ring moves with it through hud.onTutorial.
		hud:setTutorial(payload)

	elseif kind == "spawned" then
		if payload.preview then
			-- The dot moved. NO camera move and no zoom: you are already looking
			-- at the place you just clicked, and yanking the view on every
			-- re-pick would make changing your mind cost a pan back -- which is
			-- the one thing this phase exists to let you do.
			myPick = payload.tile
			setPick(payload.tile)
			-- On a predrawn map the claim is a COUNTRY: the ring is on its
			-- capital, the banner names it, and the country itself flashes
			-- so the answer to "which one did I get" is on the map.
			myPickName = payload.nation
			if payload.owner and payload.owner ~= 0 then
				flashTarget(payload.owner, Color3.fromRGB(255, 255, 255))
			end
		else
			-- The round has started and the dot is an empire. This arrives for
			-- everybody, including the players who never clicked and were placed
			-- by autoSpawn, so it is also the only moment those players are ever
			-- shown where they live.
			hasSpawned = true
			myPick = nil
			setPick(nil)
			camera.zoom = 4.5
			camera:centerOnTile(payload.tile)
			camera:apply(mapImage)
			-- The whole map just moved under a pointer that did not: whatever the
			-- hover card is describing, it is not what is under the cursor now.
			hoverDirty = true
		end

	elseif kind == "denied" then
		Sfx.play("Deny")
		-- ping: denied. Overwrites the optimistic acknowledgement with a red
		-- ring where the click landed, so a refusal is not only a sentence.
		-- ...unless nothing was clicked: a reinforcement refusal answers a
		-- rail press, and a ring on whatever tile was tapped LAST would mark a
		-- place that had nothing to do with it. "full" and "cooldown" are its
		-- alone; its "gold" is caught before the intent is sent (see `arm`).
		if lastClickTile and payload.reason ~= "full" and payload.reason ~= "cooldown" then
			ping(lastClickTile, Color3.fromRGB(232, 97, 90))
		end
		if payload.owner and payload.owner ~= 0 then
			flashTarget(payload.owner, Color3.fromRGB(255, 120, 110))
		end
		-- Why the last tap did not become an attack.
		local who = payload.owner and playersById[payload.owner]
		local name = who and who.name or "them"
		local msg
		if payload.reason == "notadjacent" then
			msg = "Your land does not touch " .. name .. " yet"
		elseif payload.reason == "troops" then
			msg = "Not enough troops - raise the commit bar"
		elseif payload.reason == "ally" then
			msg = name .. " is on your team"
		elseif payload.reason == "allied" then
			msg = name .. " is your ally - break the alliance first"
		elseif payload.reason == "water" then
			msg = "That is open water"
		elseif payload.reason == "own" then
			msg = "That is your own land"
		-- Spawn-phase refusals: the two places you may not stand.
		elseif payload.reason == "toonear" then
			msg = "Too close to another player - stand further out"
		elseif payload.reason == "already" then
			msg = "You are already on the map"
		-- Predrawn-map refusals: the three kinds of country you may not claim.
		elseif payload.reason == "taken" then
			msg = "Another player already has that nation"
		elseif payload.reason == "notplayable" then
			msg = "That nation is not playable - pick a coloured one"
		elseif payload.reason == "nonation" then
			msg = "That land belongs to no nation"
		elseif payload.reason == "toomanyfronts" then
			msg = "Too many fronts - press X to pull one back"
		-- Nobody may be attacked for the first few seconds of the round. Open
		-- land is never immune, so this only ever fires on a tap at a NATION,
		-- and saying so is the difference between "the game is protecting a
		-- new empire" and "my tap did not register".
		-- Naval refusals. Each one is a different fix for the player, so
		-- collapsing them into "you can't attack there" would be useless.
		-- A gunboat sent to water she cannot swim to: a lake, or a sea the
		-- other side of a land bridge. See the `movegunboat` handler.
		elseif payload.reason == "nosea" then
			msg = "Your gunboat cannot reach that water"
		elseif payload.reason == "nosearoute" then
			msg = "No sea route to " .. name
		elseif payload.reason == "nobeach" then
			msg = name .. " has no coast to land on there"
		elseif payload.reason == "nocoast" then
			msg = "You have no coastline to sail from"
		elseif payload.reason == "toomanytransportboats" then
			msg = "All your transport boats are at sea"
		elseif payload.reason == "busy" then
			msg = "Too many crossings at once - try again"
		elseif payload.reason == "immunity" then
			msg = name .. " is still under spawn protection"
		else
			-- Build and launch refusals, worded in exactly one place -- the
			-- placement ghost says the same sentences BEFORE the click, off
			-- the same function, so the two can never drift apart.
			msg = buildRefusalText(payload.reason, payload.kind, payload.cost)
		end
		if msg then
			alertText = msg
			alertUntil = os.clock() + 2.5
		end

	elseif kind == "rearmed" then
		-- THE SKIP LANDED (2026-09-22): the airfield's rearm was bought off. The
		-- chip's bar has already cleared through the unit event; this is the
		-- sentence, because a purchase with no acknowledgement reads as one
		-- that failed. `next` is the receipt that found nothing rearming and
		-- was banked for the next sortie instead (ConquestServer.skipRearm).
		-- The same product skips a RAILGUN's reload or build (2026-09-25):
		-- `kind` 21 is the railgun, `built` a site finished rather than a reload.
		if (payload :: any).next then
			alertText = "Your next shot reloads at once"
		else
			alertText = if (payload :: any).built then "Railgun built"
				elseif (payload :: any).kind == 21 then "Railgun reloaded"
				else "Airfield rearmed"
			if type((payload :: any).tile) == "number" then
				ping((payload :: any).tile, Color3.fromRGB(255, 176, 96))
			end
		end
		alertUntil = os.clock() + 2.5

	elseif kind == "march" then
		-- THE TAP WAS AT A COUNTRY WE DO NOT TOUCH YET, and the game answered
		-- it by taking the open ground in between rather than refusing. The
		-- press has already rung the tile the finger landed on and said
		-- "Attacking NAME"; both are a country's width out now, so this moves
		-- them to where the army actually sets off from. ONE LINE, ONCE: from
		-- here the march is on the map and says the rest itself.
		local marchWho = payload.owner and playersById[payload.owner]
		alertText = "No border with " .. (marchWho and marchWho.name or "them")
			.. " yet - taking the open land"
		alertUntil = os.clock() + 2.5
		if payload.tile then
			lastClickTile = payload.tile
			ping(payload.tile, Palette.playerColor3(myId, myId))
			-- The sword the press could not raise. A click on an EMPIRE waits
			-- for setArmies to raise it, and this push is an attack on nobody
			-- -- Sim.armies never carries one -- so it was never coming.
			nationLabels:declare(payload.tile, false)
		end

	elseif kind == "reinforced" then
		-- REINFORCEMENTS LANDED (2026-09-21). The treasury drops on this frame
		-- for the reason a build's does, and the men join the army figure NOW
		-- rather than a fifth of a second later when the next summary agrees
		-- -- the same rule the city punch follows for the ceiling. The punch is
		-- the city's: the ARMY block flashes green and bounces while the count
		-- runs up, because this IS the army being upgraded. The cooldown starts
		-- on the client's own clock so the caption reads "30s" on the same
		-- frame; the next `fronts` corrects it either way.
		myGold = payload.gold or myGold
		myTroops += payload.troops or 0
		hud:setReinforce(nil, Config.REINFORCE_COOLDOWN or 300)
		hud:punchArmy()
		-- A transport unloading on a beach is the one sample this game already
		-- has for "troops arriving", and that is what this is.
		Sfx.play("Landing")
		-- formatTroops, not format: a troop figure prints a tenth of the sim's
		-- count everywhere else on screen (owner, 2026-09-21).
		alertText = "+" .. Numbers.formatTroops(payload.troops or 0) .. " TROOPS"
		alertUntil = os.clock() + 2

	elseif kind == "built" then
		-- Accepted. The gold figure in the reply is authoritative and lands
		-- before the next summary, so the treasury drops on the same frame the
		-- click did rather than a fifth of a second later.
		myGold = payload.gold or myGold
		local what = KIND_NAME[payload.kind or 1] or "CITY"
		-- The second half of the two-beat the press started: the coin on the
		-- click, this when the ground actually broke. They are a round trip
		-- apart, which is what makes them read as cause and effect rather than
		-- as one muddy noise.
		Sfx.play("Build")
		if payload.kind == KIND_PORT then
			myPortCost = payload.cost or myPortCost
			-- One ladder, two buildings: buying a port repriced the factory too.
			myFactoryCost = myPortCost
		elseif payload.kind == KIND_FACTORY then
			myFactoryCost = payload.cost or myFactoryCost
			myPortCost = myFactoryCost
		-- ONLY A CITY DOES THE CITY'S BOOKKEEPING. This was an `else`, so every
		-- kind that is not a port or a factory -- the defence post, the anti-nuke
		-- tower, the artillery gun, the airfield -- came through here and was
		-- treated as a city: a full green ARMY UPGRADED punch, the troop ceiling
		-- stepped up, and the CITY card repriced to whatever had just been built.
		-- The next summary put it all back, so it read as the HUD flinching at
		-- the wrong moment. Those kinds carry their own prices on `fronts`.
		elseif payload.kind == KIND_CITY then
			myCityCost = payload.cost or myCityCost
			-- THE ARMY IS UPGRADED THE MOMENT THE CITY GOES DOWN (owner,
			-- 2026-09-11), not when it finishes building. The level joins the
			-- ceiling now -- the server's `levels` counts sites still going up,
			-- so the next `fronts` agrees instead of taking it back -- and the
			-- HUD punches the readout while the cap counts up to it.
			myCityLevels += 1
			myMaxTroops += Config.CITY_TROOP_INCREASE
			hud:punchArmy()
		end
		alertText = (payload.reason == "upgrade" and (what .. " UPGRADED"))
			or (what .. " BUILT")
		alertUntil = os.clock() + 2
		-- A port SNAPS to the nearest coast you own, so the ring goes where the
		-- building actually landed rather than where the click did -- otherwise
		-- the one case where the two differ is the one case with no feedback.
		if payload.tile then
			lastClickTile = payload.tile
			ping(payload.tile, GOLD)
		end
		-- ONE PRESS, ONE BUILDING. This used to stay armed so you could put
		-- two cities down in a row, and what that cost was a mode you were in
		-- without meaning to be: the next tap on the map spent gold instead of
		-- attacking. `sendClick` disarms on the way out now -- press the
		-- button again for the next one.

	elseif kind == "fell" then
		-- Everybody gets this one: an empire dying is public, and until now
		-- its colour just stopped being on the map with nothing to mark the
		-- moment. What it PAID is private and arrives separately, below.
		if payload.tile and payload.tile > 0 then
			skull(payload.tile)
		end

	elseif kind == "conquered" then
		-- An empire you broke just handed over its treasury. It is the largest
		-- single payment in the game and the only one with no click behind it,
		-- so it gets the alert line AND the figure -- otherwise the whole
		-- mechanic is a number that moves while you are looking elsewhere.
		local g = payload.gold or 0
		-- YOU ENDED THEM. The largest thing one player can do to another here,
		-- and it sounds like exactly one thing: the detonation. A coin used to
		-- land inside its tail for the treasury handed over (owner, 2026-09-11:
		-- "i dont want the coin sound, i want the explosion sound to be
		-- louder"), and the two muddied each other -- the payday is already
		-- in the alert line below, in words and a figure. The level lives on
		-- the Sound instance, as every cue's does (0.8 -> 1.2 the same day).
		Sfx.play("Destroy")
		alertText = (payload.name or "That empire") .. " has fallen"
			.. (g > 0 and ("  -  +" .. Numbers.format(g) .. " gold") or "")
		alertUntil = os.clock() + 4
		-- Not the GOLD constant: that local is declared BELOW this closure, so
		-- it is not an upvalue here and would read as a nil global.
		alertColor = Color3.fromRGB(232, 196, 110)
		alertColorText = alertText

	elseif kind == "portgold" then
		-- A trading boat just docked, or a train just paid at a station. Drawn
		-- ON the building that earned it, because trade and rail are the incomes
		-- with no click behind them: the treasury figure already moves five
		-- times a second on its own, and a number that changes while you are
		-- looking at the map is not an event. Only your own payouts ever arrive
		-- here.
		for _, e in payload do
			payout(e.t, e.g)
		end

	elseif kind == "money" then
		-- WHAT THE ROUND WAS WORTH. Private, and it arrives the moment this
		-- player's result stops being undecided -- which for most of the roster
		-- is the tick their empire fell, not the end of the match. So this is
		-- as often a consolation as a trophy, and that is the point: the card
		-- is the only thing between "you are dead" and a twelve-minute wait.
		--
		-- NOT AT THE END OF THE ROUND (owner, 2026-09-06: "when a player wins,
		-- dont show the notification ui at the top, instead just display the
		-- win banner we currently have but bigger"). The survivors are settled
		-- on the same tick the win goes out, so this card and the WINS strip
		-- used to land together; now the strip, at twice its size, is the
		-- whole of the ending. An empire that fell MID-match still gets its
		-- receipt -- that arrives while the round is running -- and the
		-- balance is on the lobby page either way.
		if phase ~= "ended" then
			hud:setPayout(payload)
		end

	elseif kind == "revive" then
		-- KNOCKED OUT, AND A WAY BACK (2026-09-08). Arrives beside the receipt
		-- on the tick this empire fell, and again with `allowed = false` the
		-- moment a takeover lands. See the revive block in ConquestServer.
		hud:setRevive(payload)

	elseif kind == "win" then
		-- For EVERYBODY, winner or not. It is the sound of the round being
		-- over, which is a thing that happened to all seventy-two of them.
		Sfx.play("Cheer")
		-- ...and a receipt still up comes down: from here the strip is the
		-- whole of the ending. See the "money" branch above.
		hud:setPayout(nil)
		hud:setRevive(nil)
		-- In a team round the BLOC took the map, not whichever member happened
		-- to hold the most of it at the final tick.
		winnerName = payload.team and (Palette.teamName(payload.team) .. " TEAM") or payload.name
		phase = "ended"
	end
end)

DeltaRE.OnClientEvent:Connect(applyDelta)

-- ================================================================= input ===

local dragging = false
local lastPos = Vector2.zero
local pressPos = Vector2.zero
local pressIsTouch = false

-- ---- the pinch -----------------------------------------------------------
-- TWO FINGERS, BECAUSE ON A PHONE THERE WAS NO OTHER WAY AT ALL (owner,
-- 2026-09-03: "mobile players have a hard time zooming in and out"). The wheel
-- handler further down was the ONLY zoom this game had, and MouseWheel does
-- not exist on glass -- so a phone was pinned at whatever zoom it spawned at
-- for the whole round.
--
-- And the attempt was worse than the absence. Both fingers arrive as ordinary
-- Touch inputs, so both were feeding the one-finger pan handler through a
-- single shared `lastPos`: the map lurched back and forth between them. That
-- is what "hard to zoom" looks like from the player's side -- not a control
-- that does nothing, a control that fights.
--
-- Positions are kept PER InputObject rather than counted, so a count and the
-- fingers can never disagree: one missed InputEnded would otherwise leave the
-- map convinced a finger is still down for the rest of the round.
local touches: { [any]: Vector2 } = {}
-- Suppresses the tap at the end of a gesture that turned out to be a pinch,
-- and stays true until the LAST finger leaves. A pinch almost never ends with
-- both fingers lifting on the same frame, and without this the straggler is a
-- tap -- which on this map is an attack.
local pinching = false
-- Finger separation and midpoint at the previous pinch event, or nil when
-- there is no live pinch to measure against.
local pinchSpan: number? = nil
local pinchMid: Vector2? = nil
-- Below this the two contacts are one fat thumb, and dividing by it turns a
-- millimetre of travel into a zoom factor of several hundred.
local PINCH_MIN_SPAN = 12

local function fingerCount(): number
	local n = 0
	for _ in touches do
		n += 1
	end
	return n
end

-- One step of a live pinch, run on every finger movement rather than on a
-- clock: the factor is a RATIO against the previous span, so it composes
-- correctly however many times it is called, and a frame with two moves in it
-- is not a double zoom.
local function stepPinch()
	local a, pa = next(touches)
	if a == nil then
		return
	end
	local b, pb = next(touches, a)
	if b == nil then
		return
	end
	local span = (pa - pb).Magnitude
	local mid = (pa + pb) / 2
	if pinchSpan == nil or pinchSpan < PINCH_MIN_SPAN or span < PINCH_MIN_SPAN then
		pinchSpan, pinchMid = span, mid
		return
	end
	-- A PINCH ALSO MOVES. Two fingers drifting together is a pan, and a pinch
	-- that only scales feels like the map fighting the hand -- the size obeys
	-- and the position does not.
	local drift = mid - (pinchMid :: Vector2)
	camera:pan(drift.X, drift.Y)
	-- Anchored at the midpoint, so the ground between the fingers stays between
	-- them. `mid` is built from InputObject.Position, which is GUI space -- the
	-- one conversion this file gets wrong every time it is skipped.
	local mx, my = fromGui(mid.X, mid.Y)
	camera:zoomAt(span / pinchSpan, mx, my)
	pinchSpan, pinchMid = span, mid
	camera:apply(mapImage)
end

-- ---- click feedback ------------------------------------------------------
-- Every tap leaves a mark ON THE MAP for a moment: a ring where you clicked
-- and a flash over the territory you clicked. The HUD already explains the
-- outcome in words, but the eye is on the map, and a control whose only
-- response is a line of text in another corner reads as one that did nothing.
--
-- The ring is a child of the MAP CONTAINER positioned in Scale, so it stays
-- pinned to its tile as you pan and zoom; its SIZE is offset, so it stays a
-- constant readable size on screen at any zoom, the way a map pin does.

-- The one place gold-the-colour is allowed, now that gold-the-resource
-- exists: it means currency and nothing else. The HUD's colour rule (one
-- meaning per colour) is what banned it while there was no economy.
GOLD = Color3.fromRGB(232, 196, 110)

local PING_LIFE = 0.45
local FLASH_LIFE = 0.45
local FLASH_STRENGTH = 0.55
local FLASH_STEP = 0.06

local pings: { any } = {}
local flashId, flashColor = 0, Color3.new(1, 1, 1)
local flashUntil, flashNext = 0, 0

function ping(tile: number, color: Color3)
	local x = tile % Config.MAP_W
	local y = (tile - x) / Config.MAP_W
	local f = Instance.new("Frame")
	f.Name = "Ping"
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromScale((x + 0.5) / Config.MAP_W, (y + 0.5) / Config.MAP_H)
	f.Size = UDim2.fromOffset(12, 12)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.ZIndex = 6
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 3
	stroke.Parent = f
	f.Parent = mapImage
	table.insert(pings, { frame = f, stroke = stroke, t = 0 })
end

-- YOUR OWN DOT, RINGED. Every pick on the map is already visible -- each one
-- is real territory in that empire's colour -- but at the zoom that fits a
-- continent, one coloured speck among two dozen is not findable, and the one
-- you need to find is yours. Nobody else's is ringed, and no text is added:
-- the colour says whose it is and the ring says which one is yours.
--
-- Assigns the forward-declared local above; NOT `local function`, which would
-- introduce a second one and leave the message handler's call site nil.
local pickRing: any = nil
local pickStroke: any = nil
local pickT = 0

function setPick(tile: number?)
	if tile == nil then
		if pickRing then
			pickRing:Destroy()
			pickRing = nil
			pickStroke = nil
		end
		return
	end
	if not pickRing then
		local f = Instance.new("Frame")
		f.Name = "SpawnPick"
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		-- The same rule as everything else drawn over the map: it must not eat
		-- the click that moves it.
		f.Active = false
		f.ZIndex = 6
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = f
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Parent = f
		f.Parent = mapImage
		pickRing = f
		pickStroke = stroke
		pickT = 0
	end
	local x = tile % Config.MAP_W
	local y = (tile - x) / Config.MAP_W
	-- Position in Scale so it holds its ground while you pan and zoom, exactly
	-- as the click rings and the skulls do.
	pickRing.Position = UDim2.fromScale((x + 0.5) / Config.MAP_W, (y + 0.5) / Config.MAP_H)
	pickStroke.Color = Palette.playerColor3(myId, myId)
end

local function stepPick(dt: number)
	if not pickRing then
		return
	end
	pickT += dt
	-- It breathes. A ring that simply sits there is read as part of the map,
	-- and this one has to keep saying "still yours to move" for as long as the
	-- phase lasts.
	local k = 0.5 + 0.5 * math.sin(pickT * 4.2)
	-- Sized off the dot it is ringing rather than off a constant, so it stays
	-- OUTSIDE the territory at every zoom -- with a floor, because at fit zoom
	-- the dot is a few pixels across and the ring is the only part of it that
	-- anybody can see.
	local d = math.max(26, (Config.SPAWN_PREVIEW_RADIUS * 2 + 5) * camera.zoom) + 6 * k
	pickRing.Size = UDim2.fromOffset(math.floor(d), math.floor(d))
	pickStroke.Transparency = 0.35 * k
end

-- ====================================================== the tutorial's ring ==
-- WHERE TO TAP, SHOWN RATHER THAN DESCRIBED. The lesson card names a tile and
-- this draws on it: a ring pinned to that ground, a pulse leaving the ring once
-- a second so it is findable in peripheral vision, and -- when the tile is off
-- screen, which at zoom 4.5 is most of the map -- a chevron on the edge of the
-- viewport pointing the way to it.
--
-- WHITE, after green and after amber. Both of those are colours this game
-- already speaks in ON THE MAP -- green is land, amber is money -- so a ring
-- in either read as a status painted on that tile rather than as an
-- instruction about it. White is the only ink out here that means nothing
-- yet, which is what lets it mean "press".
--
-- The rail button the lesson lights at the same time is GREEN, not white, and
-- that is not an oversight -- see TUT_POINT in HUD. A dark control and a
-- coloured map are not the same surface and do not read the same ink.
--
-- Nothing here is ever drawn in an ordinary round -- `setTutorialTarget(nil)`
-- is what an ordinary round's `setTutorial(nil)` amounts to here.
--
-- Built on the same rule as every other thing drawn over the map: POSITION IN
-- SCALE so it stays on its ground while you pan and zoom, SIZE IN OFFSET so it
-- stays readable at any zoom. The chevron is the exception and has to be -- it
-- lives in screen space by definition.
local GUIDE = Color3.fromRGB(255, 255, 255)
-- THE RHYTHM, and it is the whole instruction (owner: "2 fast ripples between
-- every 3 slow ripples"). A ring leaving on a fixed period reads as a beacon
-- -- something MARKED -- because nothing in the world pulses evenly forever.
-- A run of slow beats broken by a double-tap reads as a HAND, and a hand
-- tapping a spot is the one thing nobody has to be taught. Seconds per ripple,
-- looped: three slow, then the two quick ones.
local GUIDE_RIPPLES = { 1.05, 1.05, 1.05, 0.34, 0.34 }
-- How far inside the viewport edge the chevron rides, and how far off screen a
-- tile has to be before it appears at all. The margin is what stops it
-- flickering on and off while a tile sits exactly on the edge.
local GUIDE_EDGE = 54

local guideTile: number? = nil
local guideRing: Frame? = nil
local guideRingStroke: UIStroke? = nil
local guidePulse: Frame? = nil
local guidePulseStroke: UIStroke? = nil
local guideArrow: Frame? = nil
local guideT = 0
-- Which ripple of the bar above is in flight.
local guideBeat = 1

local function buildGuide()
	local ring = Instance.new("Frame")
	ring.Name = "TutorialTarget"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	-- It must not eat the click it is asking for. This is the whole point of
	-- the ring and the one bug that would make it worse than nothing.
	ring.Active = false
	-- Above the click rings and below the skulls: it is a standing instruction,
	-- so it outranks an acknowledgement, but an empire dying is still the thing
	-- worth seeing.
	ring.ZIndex = 6
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = ring
	local s = Instance.new("UIStroke")
	s.Color = GUIDE
	s.Thickness = 2.5
	s.Parent = ring

	-- Hidden until stepGuide has decided it is this tile's turn to be asked for
	-- (see the wait below). Born visible, it would flash for the frame between
	-- being parented and being judged -- the same one-frame class of bug as the
	-- load-in map flash.
	ring.Visible = false
	ring.Parent = mapImage

	local pulse = Instance.new("Frame")
	pulse.Name = "TutorialPulse"
	pulse.AnchorPoint = Vector2.new(0.5, 0.5)
	pulse.BackgroundTransparency = 1
	pulse.BorderSizePixel = 0
	pulse.Active = false
	pulse.ZIndex = 6
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0.5, 0)
	pc.Parent = pulse
	local ps = Instance.new("UIStroke")
	ps.Color = GUIDE
	ps.Thickness = 2
	ps.Parent = pulse
	pulse.Visible = false
	pulse.Parent = mapImage

	-- THE OFF-SCREEN CHEVRON, drawn out of two rotated bars rather than an
	-- image: there is no arrow in Icons, and a ">" is two rectangles. Both
	-- carry the same dark stroke the uploaded sprites have baked into them,
	-- for the same reason -- it lands on whatever colour the desk or the map
	-- happens to be under it.
	local arrow = Instance.new("Frame")
	arrow.Name = "TutorialArrow"
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Size = UDim2.fromOffset(30, 30)
	arrow.BackgroundTransparency = 1
	arrow.BorderSizePixel = 0
	arrow.Active = false
	arrow.Visible = false
	arrow.ZIndex = 8
	for i, rot in { -40, 40 } do
		local bar = Instance.new("Frame")
		bar.Name = "Bar" .. i
		bar.AnchorPoint = Vector2.new(1, 0.5)
		bar.Position = UDim2.fromOffset(25, 15)
		bar.Size = UDim2.fromOffset(17, 5)
		bar.Rotation = rot
		bar.BackgroundColor3 = GUIDE
		bar.BorderSizePixel = 0
		bar.Active = false
		bar.ZIndex = 8
		local bc = Instance.new("UICorner")
		bc.CornerRadius = UDim.new(0.5, 0)
		bc.Parent = bar
		local bs = Instance.new("UIStroke")
		bs.Color = Color3.fromRGB(14, 18, 26)
		bs.Thickness = 1.5
		bs.Transparency = 0.25
		bs.Parent = bar
		bar.Parent = arrow
	end
	-- Screen space, not map space: it is pinned to the edge of the VIEWPORT and
	-- has nothing to do with where the map has been panned to.
	arrow.Parent = viewport

	guideRing, guideRingStroke = ring, s
	guidePulse, guidePulseStroke = pulse, ps
	guideArrow = arrow
	guideT = 0
end

-- The tile the current lesson is pointing at, or nil for no ring at all.
-- Assigns the forward-declared local; NOT `local function`, which would leave
-- the message handler above calling a nil.
function setTutorialTarget(tile: number?)
	guideTile = tile
	if tile == nil then
		if guideRing ~= nil then
			guideRing:Destroy()
		end
		if guidePulse ~= nil then
			guidePulse:Destroy()
		end
		if guideArrow ~= nil then
			guideArrow:Destroy()
		end
		guideRing, guideRingStroke = nil, nil
		guidePulse, guidePulseStroke = nil, nil
		guideArrow = nil
		return
	end
	if guideRing == nil then
		buildGuide()
	end
	local x = tile % Config.MAP_W
	local y = (tile - x) / Config.MAP_W
	local at = UDim2.fromScale((x + 0.5) / Config.MAP_W, (y + 0.5) / Config.MAP_H)
	local ring = guideRing :: Frame
	local pulse = guidePulse :: Frame
	ring.Position = at
	pulse.Position = at
	-- The ripple restarts on the tile it moved to rather than finishing the
	-- ring it was drawing around the old one -- and from the TOP of the bar,
	-- so a target that moves does not land the player mid-double-tap.
	guideT, guideBeat = 0, 1
end

local function stepGuide(dt: number)
	local ring, pulse, arrow = guideRing, guidePulse, guideArrow
	if ring == nil or pulse == nil or arrow == nil or guideTile == nil then
		return
	end

	-- THE GROUND IS THE SECOND HALF OF A BUILD, SO IT WAITS FOR THE FIRST (owner,
	-- 2026-09-16: "the tap indicator on the map shouldnt appear till after ...
	-- clicking the city or port card"). Ringing the tile while the card is still
	-- unpressed is two instructions at once, and the ring is the half that cannot
	-- be acted on yet -- arming is what turns the ground into a legal press.
	-- Steps with no arm (spawn, attack, invade, conquer) leave tutorialArm nil and
	-- ring immediately, exactly as before.
	--
	-- `hud.armed` is last frame's -- setActions runs after this in the same loop --
	-- which is one frame of lag on a ring that is about to start a 0.4s ripple.
	local waiting = hud.tutorialArm ~= nil and hud.armed ~= hud.tutorialArm
	ring.Visible = not waiting
	pulse.Visible = not waiting
	if waiting then
		-- The off-screen chevron goes with it: it points at the ring.
		arrow.Visible = false
		return
	end
	guideT += dt

	-- Walk the bar. One ripple in flight at a time: two overlapping rings say
	-- "radar", which is a thing being watched rather than a thing to press.
	local dur = GUIDE_RIPPLES[guideBeat]
	if guideT >= dur then
		guideT -= dur
		guideBeat = guideBeat % #GUIDE_RIPPLES + 1
		dur = GUIDE_RIPPLES[guideBeat]
	end
	local a = math.clamp(guideT / dur, 0, 1)

	-- THE CORE, sized off the zoom with a floor -- at fit zoom a tile is under
	-- a pixel and this is the only part of it anybody can see.
	--
	-- It does not breathe on a clock of its own. It KICKS as each ripple is
	-- born and settles while that ripple travels, so the two read as one
	-- gesture -- a finger landing -- instead of as a ring with weather.
	local kick = (1 - a) ^ 3
	local d = math.max(18, 14 * camera.zoom)
	-- A BUILDING UNDER THE RING (the first airfield, 2026-09-22): ground is a
	-- point but a chip has a plate, and a 14-tile ring on a 13-tile chip is an
	-- outline, not a halo. Clear the plate with air; open ground is unchanged.
	local chip = structures:chipTiles(guideTile)
	if chip ~= nil then
		d = math.max(d, chip * 1.7 * camera.zoom)
	end
	local cd = d * (1 + 0.13 * kick)
	ring.Size = UDim2.fromOffset(math.floor(cd), math.floor(cd))
	;(guideRingStroke :: UIStroke).Transparency = 0.3 - 0.3 * kick

	local pd = d * (1 + 1.15 * a)
	pulse.Size = UDim2.fromOffset(math.floor(pd), math.floor(pd))
	;(guidePulseStroke :: UIStroke).Transparency = a
	;(guidePulseStroke :: UIStroke).Thickness = 2 * (1 - a) + 0.5

	-- ---------------------------------------------------------- the chevron --
	-- Where the target has ended up ON SCREEN. Worked out from the map
	-- container's own absolute rect rather than from the camera, so it cannot
	-- disagree with the ring: the ring is positioned in that rect's Scale
	-- space, so this is the same arithmetic the engine just did.
	local mp, ms = mapImage.AbsolutePosition, mapImage.AbsoluteSize
	local x = guideTile % Config.MAP_W
	local y = (guideTile - x) / Config.MAP_W
	local px = mp.X + (x + 0.5) / Config.MAP_W * ms.X
	local py = mp.Y + (y + 0.5) / Config.MAP_H * ms.Y

	local vp, vs = viewport.AbsolutePosition, viewport.AbsoluteSize
	local lx, ly = px - vp.X, py - vp.Y
	local m = GUIDE_EDGE
	if lx >= m and lx <= vs.X - m and ly >= m and ly <= vs.Y - m then
		-- On screen, and the ring is doing the job. A chevron as well would be
		-- pointing at something already in front of them.
		arrow.Visible = false
		return
	end

	arrow.Visible = true
	-- Aimed from the CENTRE of the viewport, which is where the eye is, and
	-- parked on the edge of the box the test above uses -- so it appears
	-- exactly where the target left and does not jump when it comes back.
	local cx, cy = vs.X * 0.5, vs.Y * 0.5
	local dx, dy = lx - cx, ly - cy
	if dx == 0 and dy == 0 then
		dy = 1
	end
	-- Scale the direction until it hits the nearer of the two edge planes.
	local sx = (math.abs(dx) > 0.001) and ((cx - m) / math.abs(dx)) or math.huge
	local sy = (math.abs(dy) > 0.001) and ((cy - m) / math.abs(dy)) or math.huge
	local sc = math.min(sx, sy)
	arrow.Position = UDim2.fromOffset(
		math.floor(cx + dx * sc),
		math.floor(cy + dy * sc)
	)
	-- The chevron is drawn pointing right at rotation 0, so the bearing is just
	-- the angle of the direction it is reporting. atan2 takes (y, x) and screen
	-- y grows downward, which is the same handedness Rotation uses.
	arrow.Rotation = math.deg(math.atan2(dy, dx))
	-- It breathes with the ring so the two read as one thing at two distances.
	-- `kick` is the ring's own settle curve above; this read a `k` that did not
	-- exist, which threw on EVERY FRAME the chevron was up (found 2026-09-09
	-- in the tutorial's US run: the nuke ring was off screen, and the output
	-- filled with "attempt to perform arithmetic (mul) on number and nil").
	for _, bar in arrow:GetChildren() do
		if bar:IsA("Frame") then
			bar.BackgroundTransparency = 0.15 * kick
		end
	end
end

local SKULL_LIFE = 3.0
local SKULL_SIZE = 44
local skulls: { any } = {}

-- A MAP PIN like the click ring, and for the same reasons: position in
-- Scale so it stays on its ground while you pan, size in Offset so it stays
-- readable at every zoom. It outlives a ping six times over because it is
-- reporting an event nobody asked for rather than acknowledging an input
-- somebody just made -- you have to be able to look up and find it.
function skull(tile: number)
	local x = tile % Config.MAP_W
	local y = (tile - x) / Config.MAP_W
	local img = Instance.new("ImageLabel")
	img.Name = "Skull"
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Position = UDim2.fromScale((x + 0.5) / Config.MAP_W, (y + 0.5) / Config.MAP_H)
	img.Size = UDim2.fromOffset(0, 0)
	img.BackgroundTransparency = 1
	img.Image = Icons.SKULL
	img.ScaleType = Enum.ScaleType.Fit
	-- Above the click rings: if you finish somebody with the tap that also
	-- draws a ping, the skull is the part worth seeing.
	img.ZIndex = 7
	img.Parent = mapImage
	table.insert(skulls, { frame = img, t = 0 })
end

local function stepSkulls(dt: number)
	for i = #skulls, 1, -1 do
		local s = skulls[i]
		s.t += dt
		local k = s.t / SKULL_LIFE
		if k >= 1 then
			s.frame:Destroy()
			table.remove(skulls, i)
		else
			-- Ease-out to full size with a sine bulge on top, so it punches past
			-- its final size by a quarter and settles back. The overshoot is what
			-- makes it read as something that HAPPENED; a sprite that merely
			-- appears reads as part of the map that was always there. (Multiplying
			-- the bulge by `grow` instead, as this first did, cannot overshoot at
			-- all -- the sine is zero exactly where the size peaks.)
			local grow = math.min(1, s.t / 0.22)
			local ease = 1 - (1 - grow) ^ 3
			local size = SKULL_SIZE * ease * (1 + 0.25 * math.sin(grow * math.pi))
			s.frame.Size = UDim2.fromOffset(math.floor(size), math.floor(size))
			-- Holds, then goes. Fading from the first frame would make the
			-- whole life read as a fade and none of it as an event.
			s.frame.ImageTransparency = if k < 0.6 then 0 else (k - 0.6) / 0.4
		end
	end
end

-- ------------------------------------------------------- trade payouts -----
-- WHAT A PORT JUST EARNED, printed on the port, for the same reason the skull
-- is planted where an empire died: it is the only place the event happened.
--
-- A MAP PIN like the skull and the click rings -- position in Scale so it
-- holds its ground through a pan and a zoom, size in Offset so it stays
-- readable at every zoom. The vertical OFFSET is the lift and the rise, in
-- pixels, so the label clears the marker chip and climbs the same distance on
-- screen however far out the map is.
-- ONE TABLE, NOT SEVEN LOCALS. This file sits on Luau's 200-local ceiling
-- (see `place`), and the controller block further down needed two of them.
local PAYOUT = {
	LIFE = 1.9,
	SIZE = 19,
	RISE = 30,
	-- Clear of the 26px marker chip, which is centred on the same tile.
	LIFT = 22,
	-- The HUD's currency colour, and the same one the build ping is inked in.
	GOLD = Color3.fromRGB(232, 196, 110),
	DARK = Color3.fromRGB(10, 14, 24),
	-- Live labels, KEYED BY TILE. A second payment at the same port inside
	-- the life of the first adds to it and restarts the pop, rather than
	-- stacking a second label over the first -- which is what a busy harbour
	-- would otherwise draw: two figures overlapping and neither readable.
	live = {} :: { [number]: any },
}

function payout(tile: number, gold: number)
	local r = PAYOUT.live[tile]
	if r then
		r.gold += gold
		r.t = 0
	else
		local x = tile % Config.MAP_W
		local y = (tile - x) / Config.MAP_W
		local lbl = Instance.new("TextLabel")
		lbl.Name = "Payout"
		lbl.AnchorPoint = Vector2.new(0.5, 1)
		lbl.BackgroundTransparency = 1
		lbl.Position = UDim2.new((x + 0.5) / Config.MAP_W, 0, (y + 0.5) / Config.MAP_H, -PAYOUT.LIFT)
		lbl.Size = UDim2.fromOffset(PAYOUT.SIZE * 6, PAYOUT.SIZE)
		-- The map's own face, the one the nation names are drawn in.
		lbl.FontFace = Font.fromEnum(Enum.Font.GothamBold)
		lbl.TextScaled = true
		lbl.TextColor3 = PAYOUT.GOLD
		-- Over the markers and the skulls: it is the newest thing on the map, and
		-- it is sitting on a chip that is already drawn.
		lbl.ZIndex = 8
		-- It must never eat a click on the port it is standing over.
		lbl.Active = false
		-- Dark, opaque and thick enough to survive being printed on the pale end
		-- of the palette: the figure is over territory, not over a panel.
		local stroke = Instance.new("UIStroke")
		stroke.Color = PAYOUT.DARK
		stroke.Thickness = 2
		stroke.LineJoinMode = Enum.LineJoinMode.Round
		stroke.Parent = lbl
		lbl.Parent = mapImage
		r = { frame = lbl, stroke = stroke, sx = (x + 0.5) / Config.MAP_W, sy = (y + 0.5) / Config.MAP_H, gold = gold, t = 0, shown = "" }
		PAYOUT.live[tile] = r
	end
	-- Gold is written raw, like every other treasury figure -- Numbers.format,
	-- not formatTroops.
	local text = "+" .. Numbers.format(r.gold)
	if text ~= r.shown then
		r.shown = text
		r.frame.Text = text
	end
end

local function stepPayouts(dt: number)
	for tile, r in PAYOUT.live do
		r.t += dt
		local k = r.t / PAYOUT.LIFE
		if k >= 1 then
			r.frame:Destroy()
			PAYOUT.live[tile] = nil
		else
			-- The same overshoot the skull uses and for the same reason: a label
			-- that merely appears reads as part of the map that was always there.
			local grow = math.min(1, r.t / 0.16)
			local ease = 1 - (1 - grow) ^ 3
			local h = PAYOUT.SIZE * ease * (1 + 0.25 * math.sin(grow * math.pi))
			r.frame.Size = UDim2.fromOffset(math.floor(h * 6), math.max(1, math.floor(h)))
			-- Rises for its whole life, eased out, so it drifts off the harbour
			-- instead of sliding away at a constant speed.
			local rise = PAYOUT.RISE * (1 - (1 - k) ^ 2)
			r.frame.Position = UDim2.new(r.sx, 0, r.sy, -PAYOUT.LIFT - rise)
			-- Holds, then goes. Fading from the first frame would make the whole
			-- life read as a fade and none of it as an event.
			local fade = if k < 0.55 then 0 else (k - 0.55) / 0.45
			r.frame.TextTransparency = fade
			r.stroke.Transparency = fade
		end
	end
end

-- Assigns the forward-declared local above; NOT `local function`, which
-- would introduce a second one and leave the earlier call site nil again.
function flashTarget(id: number, color: Color3)
	if not renderer or id == 0 then
		return
	end
	flashId = id
	flashColor = color
	flashUntil = os.clock() + FLASH_LIFE
	flashNext = 0
	renderer:setFlash(id, FLASH_STRENGTH, color)
end

-- Driven from the render loop: expands and fades the rings, and walks the
-- territory flash down in COARSE steps rather than every frame, because each
-- step repaints that empire's blocks.
local function stepClickFeedback(dt: number)
	for i = #pings, 1, -1 do
		local p = pings[i]
		p.t += dt
		local k = p.t / PING_LIFE
		if k >= 1 then
			p.frame:Destroy()
			table.remove(pings, i)
		else
			local size = 12 + k * 52
			p.frame.Size = UDim2.fromOffset(size, size)
			p.stroke.Transparency = k
			p.stroke.Thickness = 1 + 2 * (1 - k)
		end
	end

	if flashId ~= 0 and renderer then
		local now = os.clock()
		local left = flashUntil - now
		if left <= 0 then
			renderer:setFlash(0, 0)
			flashId = 0
		elseif now >= flashNext then
			flashNext = now + FLASH_STEP
			renderer:setFlash(flashId, FLASH_STRENGTH * (left / FLASH_LIFE), flashColor)
		end
	end
end

-- ====================================================== placement preview ==
--
-- WHAT YOU ARE ABOUT TO PLACE, AND WHETHER IT WOULD BE ALLOWED, BEFORE THE
-- CLICK. Twin of Economy.canBuild (Economy:741) and Nukes.nukeSpawn
-- (Nukes:792). The server is still the authority and still refuses; this is
-- here so the refusal arrives while the pointer is still moving instead of
-- 100ms after the gold was committed.
--
-- Every rule below reads data the client already holds -- the owner and
-- terrain buffers off the renderer, the structure markers, the treasury -- and
-- most of them call the same TileMap predicates the server calls, so what has
-- to be kept in step is the ORDER of the tests and nothing else. If one ever
-- stops matching its twin the symptom is a ghost that lies, and this is where
-- it gets fixed.
--
-- ONE TABLE, NOT TWENTY LOCALS. This file is a few names short of Luau's
-- 200-local ceiling at file scope -- adding the fields and helpers below as
-- plain locals overflows it, and the compiler reports that in a message which
-- names an unrelated variable three hundred lines away.
local place = {
	-- The tile being ASKED about: what the pointer is over, or what the last
	-- tap named. `target` is where the building would ACTUALLY go, which for a
	-- port is the snapped coast tile and for everything else is the same tile.
	tile = nil :: number?,
	target = nil :: number?,
	state = nil :: string?,
	reason = nil :: string?,
	age = 0,
	-- How often an armed ghost re-tests itself. See the render loop.
	RETEST = 1 / 6,
	DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } },
	-- WHICH WARHEAD nukeMode is armed with (2026-09-22): KIND_ATOM (13) for
	-- the NUKE card, 17 -- Units.MEGA_NUKE, a literal for the reason
	-- KIND_ATOM is -- for the MEGA NUKE card. A field here and not a local
	-- beside nukeMode for the reason this table exists at all. `arm` writes
	-- it; the ghost's radius, the price, the banner and the intent read it.
	warhead = 13,
}

-- Is there a POINTER in this session, or a finger? A mouse hovers, so the
-- ghost can follow it and every click commits. A touch screen has no hover at
-- all, so the ghost has nowhere to be until a tap names a tile. Asked of the
-- last INPUT rather than of the device, because a tablet with a mouse plugged
-- into it is both and the honest answer is "whichever they just used".
function place.hoverLive(): boolean
	local t = UserInputService:GetLastInputType()
	-- A controller's virtual cursor hovers too: it IS a mouse to every
	-- handler in this file, so the ghost follows it the way it follows one.
	return t == Enum.UserInputType.MouseMovement
		or t == Enum.UserInputType.MouseButton1
		or t == Enum.UserInputType.MouseWheel
		or Gamepad.cursorOn()
end

-- What the armed thing costs right now. The server prices it (Economy.cost)
-- and pushes the answer down on every build reply, so these are its own
-- figures rather than a curve recomputed here.
function place.cost(): number
	if nukeMode then
		-- A FREE SHOT COSTS NOTHING, AND SAYING SO HERE IS THE WHOLE FIX
		-- ("+1 Nuke!", tutorial only -- see Products). Every gate a launch
		-- passes on this client tests against this one function: place.nuke
		-- greys the ghost on `myGold < place.cost()`, sendClick re-tests the
		-- same thing at the press, and the banner prints "NEED n MORE GOLD"
		-- off the same comparison. Returning 0 while one is in hand answers
		-- all three at once, and leaves the server's own free-shot path
		-- (Nukes, at the order AND at the charge) as the only thing that can
		-- actually spend the warhead.
		-- The count itself lives on the HUD, not in this file: see
		-- HUD.setFreeNukes for the register that was not there.
		-- THE MEGA NUKE IS NEVER FREE (2026-09-22): the token is atom-only at
		-- the charge (Nukes), so a mega armed with a shot in hand still
		-- prices at its own flat 3M -- or the ghost would read green over a
		-- launch the server is about to refuse for gold.
		if place.warhead == 17 then
			return Config.MEGA_NUKE_COST or 2500000
		end
		-- 20 is Units.SCATTERSHOT (2026-09-24), never free either.
		if place.warhead == 20 then
			return Config.SCATTERSHOT_COST or 3750000
		end
		if hud:freeNukes() > 0 then
			return 0
		end
		return Config.ATOM_BOMB_COST or 750000
	elseif buildKind == KIND_PORT then
		return myPortCost
	elseif buildKind == KIND_FACTORY then
		return myFactoryCost
	elseif buildKind == KIND_POST then
		-- A TOWER ALREADY PAID FOR COSTS NOTHING. This is the site the free
		-- warhead was refused at twice: the ghost greys on `myGold <
		-- place.cost()`, sendClick re-tests it and the placement re-tests it
		-- again, so answering 0 here answers all three at once. The count
		-- lives on the HUD, not in this file -- see HUD.setFreePosts for the
		-- register that was not there.
		if hud:freePosts() > 0 then
			return 0
		end
		return myPostCost
	elseif buildKind == 5 then
		-- A FREE ANTI-NUKE TOWER (Starter Pack #2) costs nothing, for the same
		-- three-sites reason the post above gives.
		if hud:freeSams() > 0 then
			return 0
		end
		return hud:samCost()
	elseif buildKind == 18 then
		-- 18 is Units.ARTILLERY, a literal for the reason 5 is. No free
		-- batteries exist, so there is no count to consult first.
		return hud:artilleryCost()
	elseif buildKind == 19 then
		-- The airfield (2026-09-21), priced off the HUD like the tower and for
		-- the same missing register. No product hands one over, so no free path.
		return hud:airfieldCost()
	elseif buildKind == 21 then
		-- The railgun (2026-09-24), the airfield's rule.
		return hud:railgunCost()
	end
	-- And a free city, likewise: Starter Pack #2 hands over one.
	if hud:freeCities() > 0 then
		return 0
	end
	return myCityCost
end

-- Land tile with at least one water 4-neighbour. Twin of Economy's `isCoast`
-- (Economy:697) down to calling the same two TileMap predicates -- `renderer`
-- stands in for `sim.map` because both are a table with a `terrain` buffer.
function place.isCoast(tile: number): boolean
	if not TileMap.isPassable(renderer, tile) then
		return false
	end
	local w = Config.MAP_W
	local x = tile % w
	local y = (tile - x) / w
	for _, d in place.DIRS do
		local nx, ny = x + d[1], y + d[2]
		if TileMap.inBounds(nx, ny) and not TileMap.isLand(renderer, ny * w + nx) then
			return true
		end
	end
	return false
end

-- Twin of Economy's `snapToCoast` (Economy:715). A port goes where the COAST
-- is and not where the click was, and the ghost jumping to that tile is the
-- clearest way to say so -- it is the one case where the thing you place and
-- the thing you clicked are different tiles.
function place.snap(tile: number): number?
	local w = Config.MAP_W
	if buffer.readu8(renderer.owner, tile) == myId and place.isCoast(tile) then
		return tile
	end
	local r = Config.PORT_SPAWN_RADIUS
	local x0 = tile % w
	local y0 = (tile - x0) / w
	local best: number? = nil
	local bestD = math.huge
	for dy = -r, r do
		for dx = -r, r do
			local d = dx * dx + dy * dy
			if d <= r * r and d < bestD then
				local x, y = x0 + dx, y0 + dy
				if TileMap.inBounds(x, y) then
					local t = y * w + x
					if buffer.readu8(renderer.owner, t) == myId and place.isCoast(t) then
						best, bestD = t, d
					end
				end
			end
		end
	end
	return best
end

-- Returns the state the ghost should wear, the tile it would land on, the
-- refusal reason in the SERVER'S vocabulary (so buildRefusalText words it),
-- and the level the building would be.
function place.build(tile: number, kind: number): (string, number, string?, number)
	if renderer == nil or phase ~= "playing" or not hasSpawned then
		return "bad", tile, nil, 1
	end
	local target = tile
	if kind == KIND_PORT then
		local snapped = place.snap(tile)
		if snapped == nil then
			return "bad", tile, "coast", 1
		end
		target = snapped
	else
		if buffer.readu8(renderer.owner, target) ~= myId then
			return "bad", target, "land", 1
		end
		if not TileMap.isPassable(renderer, target) then
			return "bad", target, "terrain", 1
		end
	end
	-- An own building of the SAME KIND in range is an UPGRADE, not a refusal,
	-- and it is tested first for the reason Economy.canBuild tests it first:
	-- everything close enough to upgrade is also too close to build on. The
	-- `true` excludes sites -- a click must not level a building that is not
	-- standing yet.
	-- ...EXCEPT A DEFENCE POST, which has no upgrade: its unitInfo carries no
	-- `upgradable`, so a click beside one of your own is CROWDED and refused.
	-- The same skip, for the same reason, as Economy.canBuild's -- and the ghost
	-- has to agree with the server or it promises a level the build will not
	-- deliver.
	-- ...AND NEITHER GUN (2026-09-21): 18 is the artillery, 19 the airfield,
	-- both in Economy's NOT_UPGRADABLE set with the post.
	local mine = kind ~= KIND_POST and kind ~= 18 and kind ~= 19
		and structures:nearest(target, Config.STRUCTURE_MIN_DIST, myId, kind, true)
		or nil
	if mine ~= nil then
		if mine.level >= Config.STRUCTURE_MAX_LEVEL then
			return "bad", target, "maxlevel", mine.level
		end
		if myGold < place.cost() then
			return "bad", target, "gold", mine.level + 1
		end
		return "upgrade", target, nil, mine.level + 1
	end
	-- Anything of any kind and any owner inside the spacing radius blocks it,
	-- sites included: two sites half a tile apart are as illegal as two
	-- finished buildings.
	if structures:nearest(target, Config.STRUCTURE_MIN_DIST) ~= nil then
		return "bad", target, "crowded", 1
	end
	if myGold < place.cost() then
		return "bad", target, "gold", 1
	end
	return "ok", target, nil, 1
end

-- Twin of Nukes.nukeSpawn's refusals (Nukes:792-822), minus the silo search --
-- Config.NUKE_REQUIRES_SILO is false, so a launch site is always found.
function place.nuke(tile: number): (string, number, string?)
	if renderer == nil or phase ~= "playing" or not hasSpawned then
		return "bad", tile, nil
	end
	if not TileMap.isPassable(renderer, tile) then
		return "bad", tile, "terrain"
	end
	local o = buffer.readu8(renderer.owner, tile)
	if o == myId or (o ~= 0 and myTeam ~= nil and teamById[o] == myTeam) then
		return "bad", tile, "friendly"
	end
	if myGold < place.cost() then
		return "bad", tile, "gold"
	end
	-- A team game refuses a shot whose blast would take a teammate's building.
	-- Walked per teammate because the marker query filters on ONE owner, and a
	-- side is small -- the AI filler is neutral and holds no team at all, so
	-- this is a handful of ids rather than the whole roster.
	local mag = Nukes.magnitude(place.warhead)
	if myTeam ~= nil and mag ~= nil then
		for id, t in teamById do
			if t == myTeam and id ~= myId and structures:nearest(tile, mag.outer, id) ~= nil then
				return "bad", tile, "teammate"
			end
		end
	end
	return "ok", tile, nil
end

function place.clear()
	place.tile, place.target, place.state, place.reason = nil, nil, nil, nil
	structures:setGhost(nil)
end

function place.refresh()
	local at = place.tile
	place.age = 0
	if at == nil or renderer == nil or not (buildMode or nukeMode) then
		place.clear()
		return
	end
	if nukeMode then
		local state, target, why = place.nuke(at)
		place.state, place.target, place.reason = state, target, why
		-- THE CIRCLE IS THE WARHEAD'S OWN RADIUS. A nuke is not placed like a
		-- building -- what is being chosen is an AREA -- so the preview has to
		-- BE that area rather than a marker standing in for it -- the atom
		-- bomb's or the mega nuke's, whichever card armed it (place.warhead).
		local mag = Nukes.magnitude(place.warhead)
		local mega = place.warhead == 17
		-- THE SCATTERSHOT'S CIRCLE IS THE WHOLE SALVO (2026-09-24): the inner
		-- ring is the main warhead's crater and the outer one the furthest a
		-- small warhead's crater can reach (Config.SCATTERSHOT_SPREAD_MAX plus
		-- the MIRV warhead's outer 18), so the preview is everything at risk.
		local scatter = place.warhead == 20
		structures:setGhost({
			tile = target,
			state = state,
			inner = if scatter then (mag and mag.outer or 30) else (mag and mag.inner or (mega and 24 or 12)),
			outer = if scatter then (Config.SCATTERSHOT_SPREAD_MAX or 46) + 18 else (mag and mag.outer or (mega and 60 or 30)),
		})
	else
		local state, target, why, level = place.build(at, buildKind)
		place.state, place.target, place.reason = state, target, why
		structures:setGhost({ tile = target, state = state, kind = buildKind, level = level })
	end
end

function place.at(tile: number?)
	place.tile = tile
	place.refresh()
end

-- Where the ghost starts the moment a button is pressed: under the cursor if
-- there is one, and nowhere at all on a touch screen.
function place.arm()
	if place.hoverLive() and pointerOverMap and renderer ~= nil then
		local t = camera:screenToTile(lastMouse.X, lastMouse.Y)
		if t then
			place.at(t)
			return
		end
	end
	place.clear()
end

function place.disarm()
	buildMode, nukeMode = false, false
	place.clear()
end

-- (sx, sy) arrive in VIEWPORT space -- see pointer().
local function sendClick(sx: number, sy: number)
	if not renderer then
		return
	end
	local tile = camera:screenToTile(sx, sy)
	if not tile then
		return
	end

	if buildMode or nukeMode then
		-- PLACING TAKES THE CLICK WHOLE. Falling through to an attack when the
		-- tile turns out to be illegal would launch a war off a click that was
		-- meant to place a building, which is the worst possible misfire.
		local wasNuke = nukeMode
		-- The warhead the card armed (place.warhead): the atom bomb's 13 or
		-- the mega nuke's 17, which is what the intent below sends.
		local kind = wasNuke and place.warhead or buildKind
		local cost = place.cost()
		-- RE-TESTED AT THE PRESS rather than trusted from the last hover frame:
		-- a pointer may have crossed a tile since, and a finger never hovered at
		-- all. ONE PRESS COMMITS ON EVERY DEVICE (owner, 2026-09-06). A touch
		-- screen used to spend the first tap parking the ghost and only commit
		-- on a second tap of the same tile, and that read as a button that had
		-- missed the tap. The verdict the ghost would have shown still arrives:
		-- a legal tile builds, an illegal one says why below.
		place.at(tile)
		local target = place.target or tile
		if place.state ~= "ok" and place.state ~= "upgrade" then
			-- A MISS EXITS PLACING. The ghost was red, so the server would
			-- refuse this and there is no point spending a round trip finding
			-- that out: say why on the spot, drop the mode, and let the next
			-- click be an attack again.
			local why = place.reason
			place.disarm()
			local msg = buildRefusalText(why, kind, cost)
			if msg then
				alertText = msg
				alertUntil = os.clock() + 2.5
			end
			-- ...AND THE ONLY MOMENT A GOLD TOP-UP MEANS ANYTHING (2026-09-17).
			-- This branch is a player who armed a building, picked a tile and was
			-- turned down; `why == "gold"` narrows that to the one refusal money
			-- answers. Everything after this -- whether to offer at all, the 90%
			-- rule, the cooldown, the cards -- belongs to GoldTopUpClient, which
			-- owns the reasoning and can afford the locals.
			--
			-- LOOKED UP INLINE, NEVER HELD. A `local` for this at the main chunk is
			-- exactly the line that has broken this file before ("Out of local
			-- registers ... exceeded limit 200"), and a refused click happens at
			-- human speed, so one FindFirstChild costs nothing measurable. Absent
			-- -- the first frames of a round, before that file has run -- and the
			-- offer is simply skipped, which is the correct failure: a missed sale
			-- is nothing, a broken build click is everything.
			if why == "gold" then
				local ev = ReplicatedStorage:FindFirstChild("ConquestGoldShort")
				if ev ~= nil and ev:IsA("BindableEvent") then
					-- THE TILE AND THE KIND RIDE ALONG, because the top-up does not
					-- sell gold any more -- it finishes THIS build, on THIS tile
					-- (owner, 2026-09-17). `target` is the snapped tile the ghost was
					-- showing, which for a port is the coast it would have jumped to
					-- rather than the one under the finger. `wasNuke` is passed so the
					-- other side can tell a refused BUILDING from a refused warhead:
					-- there is nothing to place for the latter.
					ev:Fire(cost, myGold, target, buildKind, wasNuke)
				end
			end
			-- Refused HERE rather than by the server, so it is this that has to
			-- make the noise -- there is no "denied" coming to do it.
			Sfx.play("Deny")
			lastClickTile = tile
			ping(tile, Color3.fromRGB(232, 97, 90))
			return
		end
		if wasNuke then
			IntentRE:FireServer({ t = "nuke", tile = target, kind = place.warhead })
			-- Acknowledge the tap where it landed. The warhead takes seconds to
			-- arrive and the crater is the only other feedback this control
			-- has, so without the ring it reads as a dead button.
			ping(target, Color3.fromRGB(255, 176, 96))
			alertText = "Missile away"
			alertUntil = os.clock() + 2
		else
			IntentRE:FireServer({ t = "build", tile = target, kind = buildKind })
			-- The ring goes down on the PRESS now, where it used to wait for
			-- the server to say where the building went: the ghost has already
			-- run the same snap, so this is the tile the port really takes.
			ping(target, GOLD)
		end
		-- THE MONEY LEAVES ON THE PRESS. The treasury figure and the building
		-- itself both wait on a reply a round trip away; this does not, because
		-- a control that spends a quarter of a million gold and makes no sound
		-- for 100ms reads as one that missed the click. Covers the warhead too:
		-- it is the most expensive purchase in the game.
		Sfx.play("Coin")
		lastClickTile = target
		-- One press, one building -- see the `built` handler.
		place.disarm()
		return
	end

	-- A GUNBOAT IN HAND, OR ONE UNDER THE PRESS (owner, 2026-09-18: "you can
	-- press on them and move it to other parts of the ocean"). Above the
	-- attack: a press that lands on one of your own gunboats picks her up --
	-- white ring, see Structures.selectGunboat -- instead of attacking the sea
	-- under her, and with one in hand the press is HERS WHOLE: water sends her
	-- there, anything else just puts her down. The rule build mode follows,
	-- for the same reason -- falling through to an attack off a press that was
	-- meant for a boat is the worst possible misfire. Pressing the boat already
	-- in hand puts her down, as re-pressing an armed rail button disarms it;
	-- pressing another of yours swaps the ring to her.
	--
	-- The order is upstream's MoveWarshipExecution: the server re-stations her
	-- patrol centre, so at the far end she carries on patrolling, shelling and
	-- pirating around the new spot rather than sitting still.
	if phase == "playing" and hasSpawned then
		local held = structures:selectedGunboat()
		local mx, my = camera:screenToMap(sx, sy)
		-- AN AIRFIELD IN HAND, OR ONE UNDER THE PRESS (owner, 2026-09-21: "when
		-- you click it again, it allows you to bomb an area you'd like in its
		-- larger radius"). The gunboat's shape exactly, and above it: a press
		-- on your own finished airfield picks it up -- white ring, and the bomb
		-- disc rides the pointer (Structures.selectAirfield / aimAirfield) --
		-- and with one in hand the press is ITS WHOLE: inside its reach the
		-- order goes out, outside it just puts the field down and says so.
		-- Pressing the field in hand puts it down; another of yours swaps the
		-- ring. The server re-checks reach, rearm and ownership and answers
		-- "denied" with a reason the banner prints.
		local field = structures:selectedAirfield()
		local underField = if mx ~= nil and my ~= nil then structures:airfieldAt(mx, my, camera.zoom) else nil
		-- YOUR RAILGUN STILL GOING UP (2026-09-25): a press on the site asks
		-- for the SKIP on the rest of its build. The server decides whether
		-- to offer (75% rule, ask clock); no new local -- register wall.
		if underField == nil and field == nil and mx ~= nil and my ~= nil
			and structures:railSiteAt(mx, my, camera.zoom) ~= nil then
			IntentRE:FireServer({ t = "railsite", from = structures:railSiteAt(mx, my, camera.zoom), tile = tile })
			return
		end
		if underField ~= nil then
			-- ONE THING IN HAND AT A TIME (airfield). The two selections used to
			-- be independent, and the airfield branch below `return`s -- so with
			-- a gunboat already ringed, the press that ordered the bomber also
			-- swallowed her move order and left her ring on with nothing coming.
			structures:selectGunboat(nil)
			structures:selectAirfield(if underField ~= field then underField else nil)
			return
		end
		if field ~= nil then
			structures:selectAirfield(nil)
			-- A RAILGUN IN HAND (2026-09-24) is held by the same selection -- see
			-- Structures.aimsLike -- and fires anywhere: its own intent, no range.
			if structures:isRailgun(field) then
				IntentRE:FireServer({ t = "railgun", from = field, tile = tile })
				lastClickTile = tile
				ping(tile, Color3.fromRGB(120, 230, 255))
				alertText = "Railgun fired"
				alertUntil = os.clock() + 2
			elseif structures:airfieldInRange(field, tile) then
				IntentRE:FireServer({ t = "airstrike", from = field, tile = tile })
				-- Acknowledge the tap where it landed, in the warhead's amber:
				-- the bombs take seconds to arrive.
				lastClickTile = tile
				ping(tile, Color3.fromRGB(255, 176, 96))
				alertText = "Bomber away"
				alertUntil = os.clock() + 2
			else
				alertText = buildRefusalText("range")
				alertUntil = os.clock() + 2.5
				Sfx.play("Deny")
				lastClickTile = tile
				ping(tile, Color3.fromRGB(232, 97, 90))
			end
			return
		end
		local under = if mx ~= nil and my ~= nil then structures:gunboatNear(mx, my, camera.zoom) else nil
		if under ~= nil then
			-- ONE THING IN HAND AT A TIME (gunboat). The other half of the rule
			-- above, so an airfield in hand cannot eat the next press either.
			structures:selectAirfield(nil)
			structures:selectGunboat(if under ~= held then under else nil)
			return
		end
		if held ~= nil then
			structures:selectGunboat(nil)
			if not TileMap.isLand(renderer, tile) then
				IntentRE:FireServer({ t = "movegunboat", ids = { held }, tile = tile })
				-- ping: the order goes out, in the ring's own white. Optimistic
				-- like an attack's; the server's "denied" paints it red if this
				-- is water she cannot reach.
				lastClickTile = tile
				ping(tile, Color3.fromRGB(255, 255, 255))
			end
			return
		end
	end

	if phase == "spawn" then
		-- MOVABLE. The click asks to stand HERE, whether or not a dot is
		-- already down somewhere else: the server picks the old one up and
		-- answers with the new tile. `hasSpawned` is no use as a gate any more
		-- -- the dot is real territory, so the standings have you holding
		-- ground from the first click onward.
		IntentRE:FireServer({ t = "spawn", tile = tile })
		lastClickTile = tile -- ping: spawn
		ping(tile, Color3.fromRGB(255, 226, 140))
	elseif phase == "playing" and hasSpawned then
		-- The server rejects friendly fire regardless; catching it here is what
		-- turns a click that silently does nothing into an explanation.
		local o = buffer.readu8(renderer.owner, tile)
		if o ~= 0 and o ~= myId and myTeam ~= nil and teamById[o] == myTeam then
			local ally = playersById[o]
			alertText = "Allied territory - " .. (ally and ally.name or "your team")
			alertUntil = os.clock() + 2
			-- ping: refused locally. Red ring, and the ally's own land flashes
			-- red, so the reason shows where the click actually happened.
			lastClickTile = tile
			ping(tile, Color3.fromRGB(232, 97, 90))
			flashTarget(o, Color3.fromRGB(255, 120, 110))
			Sfx.play("Deny")
			return
		end
		IntentRE:FireServer({ t = "attack", tile = tile, ratio = attackRatio })
		-- ping: attack sent. Fired before the server answers -- the round trip
		-- is 100ms and the acknowledgement has to be immediate.
		lastClickTile = tile
		ping(tile, Palette.playerColor3(myId, myId))
		-- The order goes out. Not positional: you are looking at the tile you
		-- just clicked by definition, so attenuating it would only ever make
		-- your own commands quieter than everybody else's guns.
		--
		-- AND THE FIRST BLOW AGAINST AN EMPIRE IS NOT THE FORTIETH. The click
		-- that opens a war you have not fought yet is steel; every one after
		-- it is the ordinary charge. Played INSTEAD of it rather than over it
		-- -- two samples on one press is a smear, and what makes the moment
		-- land is that it is a DIFFERENT sound, not a louder one.
		--
		-- UNCLAIMED GROUND IS AN OPPONENT LIKE ANY OTHER HERE (owner,
		-- 2026-09-05). It used to short-circuit to the charge on the reasoning
		-- that expanding into empty land declares nothing -- but key 0 is a key,
		-- so the rule is now simply the rule: the first time you push into open
		-- country this round is steel, and every push after it is the charge.
		if not Sfx.playOnce("Clash", o) then
			Sfx.play("Charge")
		end
		if o ~= 0 then
			flashTarget(o, Color3.fromRGB(255, 255, 255))
		else
			-- ...AND THE SWORD, which for an attack on an EMPIRE is raised by
			-- setArmies when the army it opened turns up in the next broadcast.
			-- Sim.armies never carries an attack on nobody, so that route can
			-- never fire here -- see NationLabels.declare, which is the client
			-- raising it for itself on the press. Only in the `o == 0` branch,
			-- or a war would get two swords: this one and the server's.
			nationLabels:declare(tile, false)
		end
		-- Acknowledge the tap on the spot. The server's answer is a round trip
		-- away, and a control that shows nothing for 100ms reads as one that
		-- never received the input. If the server refuses, its "denied"
		-- message overwrites this a frame later.
		if o ~= 0 then
			local target = playersById[o]
			alertText = "Attacking " .. (target and target.name or "them")
			alertUntil = os.clock() + 1.5
		end
	end
end

-- IS THE POINTER OVER A HUD PANEL? `pointerOverMap` cannot answer this on its
-- own. It is fed by the map frame's MouseMoved / MouseLeave, and a panel only
-- masks those if it is ACTIVE -- most of this HUD is plain Frames, so the map
-- goes on receiving MouseMoved straight through them. Measured in a live
-- match: with the pointer parked on the action rail (which then sat ON the
-- right edge of the screen) the edge push ran the map the full 553px to its
-- clamp, i.e. reaching for the build button scrolled the map out from under
-- it. The rail is on the command bar now, but the rule it bought is general.
--
-- The panels are the ScreenGui's own children other than the viewport, so the
-- test is a handful of rect compares. The list is CACHED because
-- `GetChildren` allocates and this runs every frame; it is rebuilt whenever
-- the ScreenGui gains or loses a child, which happens at startup and never
-- again. TWO CHILDREN ARE EXCLUDED DELIBERATELY. The HOVER CARD follows the
-- cursor, so counting it would let the card the pointer just summoned be the
-- reason the map stops moving. The TUTORIAL is a frame that draws nothing --
-- see HUD.buildTutorial -- so its rect is an invisible dead zone across the
-- top of the map, and a drag that dies under no visible panel is a bug with
-- nothing on screen to explain it.
local hudPanels: { GuiObject } = {}
local function refreshHudPanels()
	table.clear(hudPanels)
	for _, d in screen:GetChildren() do
		if d ~= viewport and d.Name ~= "Hover" and d.Name ~= "Tutorial" and d:IsA("GuiObject") then
			table.insert(hudPanels, d)
		end
	end
end
refreshHudPanels()
screen.ChildAdded:Connect(refreshHudPanels)
screen.ChildRemoved:Connect(refreshHudPanels)

-- (px, py) in VIEWPORT space, like everything else here. Panel rects are read
-- in GUI space, so they are shifted by the viewport's own origin -- the same
-- one number `toViewport` uses, from the same place.
local function pointerOverHud(px: number, py: number): boolean
	local vo = viewport.AbsolutePosition
	for _, d in hudPanels do
		if d.Visible then
			local p, s = d.AbsolutePosition - vo, d.AbsoluteSize
			if px >= p.X and px < p.X + s.X and py >= p.Y and py < p.Y + s.Y then
				return true
			end
		end
	end
	return false
end

-- --------------------------------------------------------------- hover ---
-- Reading the board is the whole decision loop of the genre: who owns this,
-- how strong are they, is it worth the click. MouseMoved on the map only
-- fires when the cursor is actually over it, so HUD panels mask it for free.

-- (x, y) arrive in VIEWPORT space -- what `pointer()` samples, what the camera
-- works in, what `hud:moveHover` draws in. One space, no conversion.
local function updateHover(x: number, y: number)
	lastMouse = Vector2.new(x, y)
	-- A PANEL OVER THE MAP IS NOT A WINDOW ONTO IT. Without this, resting the
	-- pointer on the action rail or the standings board pops a card describing
	-- whatever tile happens to lie behind the panel and lights that empire up
	-- across the whole map -- the same "it is reacting to somewhere I am not
	-- pointing" the coordinate bug caused, arriving from a different
	-- direction. The map's own MouseMoved does not filter these: it only stops
	-- firing under an ACTIVE panel, and most of this HUD is plain Frames.
	if pointerOverHud(x, y) then
		hud:setHover(nil)
		structures:hoverGunboat(nil)
		structures:hoverAirfield(nil)
		structures:aimAirfield(nil)
		if lastHoverOwner ~= 0 and renderer then
			renderer:setHighlight(0)
			lastHoverOwner = 0
		end
		return
	end
	if not renderer then
		hud:setHover(nil)
		structures:hoverGunboat(nil)
		structures:hoverAirfield(nil)
		structures:aimAirfield(nil)
		return
	end

	local tile = camera:screenToTile(x, y)
	if not tile then
		hud:setHover(nil)
		structures:hoverGunboat(nil)
		structures:hoverAirfield(nil)
		structures:aimAirfield(nil)
		if lastHoverOwner ~= 0 then
			renderer:setHighlight(0)
			lastHoverOwner = 0
		end
		return
	end

	local o = buffer.readu8(renderer.owner, tile)
	if o ~= lastHoverOwner then
		renderer:setHighlight(o)
		lastHoverOwner = o
	end

	-- A GUNBOAT UNDER THE POINTER (owner, 2026-09-18: "give battleship hover
	-- effects"). Yours gets the faint ring that promises the press -- see
	-- Structures.hoverGunboat -- and a card saying so; anyone's gets a card
	-- naming the flag, in the flag's colour, so a hull on the horizon can be
	-- read without guessing from its tint. Not while placing: the pointer is
	-- carrying a building and the ghost is what it is about. The same pick,
	-- radius and coordinates as the press in sendClick, so what the ring
	-- promises is exactly what the press does.
	local boat: number? = nil
	-- ...AND AN AIRFIELD (2026-09-21): yours gets the faint ring and a card,
	-- and while one is in hand the bomb disc follows the pointer here.
	local field: number? = nil
	if not (buildMode or nukeMode) then
		local mx, my = camera:screenToMap(x, y)
		if mx ~= nil and my ~= nil then
			boat = structures:gunboatNear(mx, my, camera.zoom, true)
			field = structures:airfieldAt(mx, my, camera.zoom)
			structures:aimAirfield(mx, my)
		end
	end
	structures:hoverGunboat(boat)
	structures:hoverAirfield(field)
	if field ~= nil then
		local rail = structures:isRailgun(field)
		hud:setHover({
			name = if rail then "Railgun  (you)" else "Airfield  (you)",
			color = Palette.playerColor3(myId, myId),
			stats = if structures:selectedAirfield() == field
				then (if rail then "Tap anywhere to fire" else "Tap a spot to bomb")
				else (if rail then "Press to aim" else "Press to arm a strike"),
			terrain = "",
		})
		local size = viewport.AbsoluteSize
		hud:moveHover(x, y, size.X, size.Y)
		return
	end
	if boat ~= nil then
		local bo = structures:vehicleOwner(boat) or 0
		local entry = playersById[bo]
		local suffix = ""
		if bo == myId then
			suffix = "  (you)"
		elseif myTeam ~= nil and teamById[bo] == myTeam then
			suffix = "  (ally)"
		elseif teamById[bo] then
			suffix = "  [" .. Palette.teamTag(teamById[bo]) .. "]"
		end
		hud:setHover({
			name = (if bo == myId then "Gunboat" else (entry and entry.name or "Unknown")) .. suffix,
			color = Palette.playerColor3(bo, myId),
			stats = if bo == myId then "Press to move" else "Gunboat",
			terrain = "",
		})
		local size = viewport.AbsoluteSize
		hud:moveHover(x, y, size.X, size.Y)
		return
	end

	-- THE GHOST FOLLOWS THE POINTER, in a session that has one. This runs on a
	-- touch DRAG as well -- it is the pan handler that calls it -- and there
	-- the ghost must NOT follow, or dragging the map would drag the building
	-- across it. `hoverLive` is the whole test.
	if (buildMode or nukeMode) and place.hoverLive() then
		place.at(tile)
	end

	local tType = TileMap.typeByte(buffer.readu8(renderer.terrain, tile))
	local terrainLabel = TERRAIN_NAME[tType] or "?"

	if o == 0 then
		local claimable = tType ~= 0 and tType ~= 4
		-- IMPASSABLE GROUND IS NOT SEA. Type 4 is the grey out-of-bounds LAND
		-- drawn around New York, Japan and Korea, and calling it "Sea" put the
		-- card at odds with the picture and with its own terrain line.
		hud:setHover({
			name = if claimable then "Open land" elseif tType == 4 then "Impassable" else "Sea",
			color = Color3.fromRGB(170, 182, 200),
			unclaimed = true,
			terrain = terrainLabel,
		})
	else
		local entry = playersById[o]
		local suffix = ""
		if o == myId then
			suffix = "  (you)"
		elseif myTeam ~= nil and teamById[o] == myTeam then
			suffix = "  (ally)"
		elseif teamById[o] then
			suffix = "  [" .. Palette.teamTag(teamById[o]) .. "]"
		end
		hud:setHover({
			id = o,
			name = (entry and entry.name or "Unknown") .. suffix,
			color = Palette.playerColor3(o, myId),
			-- Only a fallback for a nation the standings have not listed yet;
			-- the HUD prefers its own smoothed figures, keyed by id.
			troops = entry and entry.troops or 0,
			tiles = entry and entry.tiles or 0,
			terrain = terrainLabel,
		})
	end

	local size = viewport.AbsoluteSize
	hud:moveHover(x, y, size.X, size.Y)
end

-- The map's MouseMoved is used as a MASK, not as a coordinate source. It fires
-- only while the cursor is over the map -- HUD panels swallow it -- which is
-- exactly the question `pointerOverMap` asks; where the cursor actually is
-- comes from `pointer()`, so this path cannot drift from the click path.
mapImage.MouseMoved:Connect(function()
	pointerOverMap = true
	updateHover(pointer())
end)
mapImage.MouseLeave:Connect(function()
	pointerOverMap = false
	hud:setHover(nil)
	structures:hoverGunboat(nil)
	structures:hoverAirfield(nil)
	structures:aimAirfield(nil)
	if renderer and lastHoverOwner ~= 0 then
		renderer:setHighlight(0)
		lastHoverOwner = 0
	end
end)

-- TRACKED IF IT STARTED ON THE MAP *OR ON THE DESK BESIDE IT*, and not on a
-- panel. A finger that lands on the rail or the standings belongs to that
-- panel, and pinching from one would zoom the map out from under a button
-- being pressed. That exclusion is the rect test below, NOT `Active`: measured
-- in a Studio client (2026-09-22), a press on an Active sibling Frame still
-- fired InputBegan on every frame behind it, and only a GuiButton sank its
-- press -- so the panels' Active flag never kept a gutter press off the map,
-- and `pointerOverHud` is what does, on every surface alike.
--
-- THE DESK WAS THE HOLE (owner, 2026-09-22: "mobile zoom, the side parts are
-- very off ... its like not zooming along with everything else, the far left
-- and right sides of the screen"). This listened on the map container alone,
-- and a phone opens at fit zoom 0.50, where the map is 440px wide in the middle
-- of an 844px screen and the outer 200px a side is table. A finger that landed
-- there was never tracked, so the gesture was never a pinch -- and worse, its
-- moves fell through to the one-finger pan below measured against the OTHER
-- finger's lastPos, so the map lurched by the whole span on every event and
-- never zoomed. Both surfaces feed one table keyed by the InputObject, so a
-- touch that reaches both registers once. A press on the desk that turns out
-- to be a tap lands off the map and sendClick drops it; one that turns out to
-- be a drag pans, which is what a hand on the table expects.
--
-- A field on `hud`, not a local, for the reason hud.onTutorial is one: this
-- file is at Luau's 200-local ceiling.
hud.beginPress = function(input)
	-- Panel rects are tested in viewport space; InputObject.Position is GUI
	-- space, hence fromGui.
	if pointerOverHud(fromGui(input.Position.X, input.Position.Y)) then
		return
	end
	if input.UserInputType == Enum.UserInputType.Touch then
		touches[input] = Vector2.new(input.Position.X, input.Position.Y)
		if fingerCount() >= 2 then
			-- THE SECOND FINGER CANCELS THE FIRST FINGER'S TAP. Without this a
			-- pinch that happened to start on enemy land launches an attack the
			-- moment the hand comes off.
			pinching = true
			dragging = false
			pinchSpan, pinchMid = nil, nil
			-- THE CLAMP GOES SOFT FOR THE LENGTH OF THE GESTURE. Without this the
			-- rest clamp overrides the anchored zoom at exactly the zooms a phone
			-- uses -- measured 85-121px of ground sliding out from under the
			-- fingers on an 844x390 pinch-out. See Camera2D.clampAxis.
			camera:setSoft(true)
			return
		end
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		dragging = true
		pressIsTouch = input.UserInputType == Enum.UserInputType.Touch
		pressPos = Vector2.new(input.Position.X, input.Position.Y)
		lastPos = pressPos
	end
end
mapImage.InputBegan:Connect(hud.beginPress)
viewport.InputBegan:Connect(hud.beginPress)

mapImage.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		-- The zoom anchor is a pointer position too, so it needs the same
		-- conversion or the map creeps while zooming under the cursor.
		local mx, my = pointer()
		-- A NOTCH IS A GESTURE TOO. The rest clamp overrides an anchored zoom at
		-- the zoom where the map fills an axis -- 1.39 and 2.18 on 1920x1080,
		-- measured at 69px of ground dragged out from under the cursor over one
		-- wheel sweep, 186px on a 1280x720 TV. The wheel has no release event, so
		-- the hold outlives the last notch by a beat and `settle` closes it.
		camera:softFor(0.25)
		camera:zoomAt(input.Position.Z > 0 and 1.18 or 1 / 1.18, mx, my)
		camera:apply(mapImage)
		updateHover(mx, my)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	-- A tracked finger updates its own entry FIRST, whatever else is going on:
	-- the pinch reads both positions out of that table, and a stale one is a
	-- zoom measured against where a finger used to be.
	if input.UserInputType == Enum.UserInputType.Touch and touches[input] ~= nil then
		touches[input] = Vector2.new(input.Position.X, input.Position.Y)
		if fingerCount() >= 2 then
			stepPinch()
			return
		end
	end
	-- A FINGER THE MAP NEVER TRACKED DOES NOT PAN IT. It landed on a panel or
	-- a button (see hud.beginPress), and until now its moves fell through here
	-- against the OTHER finger's lastPos -- the lurch that made a pinch with one
	-- finger off the map thrash instead of zoom.
	if input.UserInputType == Enum.UserInputType.Touch and touches[input] == nil then
		return
	end
	if not dragging then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement
		and input.UserInputType ~= Enum.UserInputType.Touch
	then
		return
	end
	local pos = Vector2.new(input.Position.X, input.Position.Y)
	local delta = pos - lastPos
	lastPos = pos
	camera:pan(delta.X, delta.Y)
	camera:apply(mapImage)
	-- `delta` above needs no conversion: it is a difference of two points in
	-- the same space, and the inset cancels. The hover point does.
	-- `pos` is an InputObject.Position, so it is GUI space -- NOT the space
	-- `pointer()` samples, however much the two look alike.
	updateHover(fromGui(pos.X, pos.Y))
end)

UserInputService.InputEnded:Connect(function(input)
	-- Read before the block below clears it: the last finger of a gesture is
	-- tracked right up to this event, and its lift is the one that can be a tap.
	local tracked = touches[input] ~= nil
	if input.UserInputType == Enum.UserInputType.Touch and tracked then
		touches[input] = nil
		pinchSpan, pinchMid = nil, nil
		-- BELOW TWO FINGERS THERE IS NO PINCH LEFT -- one still down is a pan
		-- now, none is a finished gesture -- so the soft clamp is released here
		-- and the map starts easing home on this frame. Tested against the
		-- count, not the branch below, so lifting one of THREE fingers leaves
		-- the pinch soft.
		if fingerCount() < 2 then
			camera:setSoft(false)
		end
		if fingerCount() >= 1 then
			-- HAND THE MAP TO THE FINGER STILL DOWN, at where that finger
			-- actually is. Leaving `lastPos` where the LIFTED one was would snap
			-- the map by the distance between them on the very next move, which
			-- is the jump that makes a pinch feel broken on the way OUT of it.
			local other = next(touches)
			lastPos = touches[other]
			pressPos = lastPos
			dragging = true
			return
		end
		if pinching then
			-- The last finger of a pinch. Not a tap, and never was.
			pinching = false
			dragging = false
			return
		end
	end
	-- An untracked finger lifting -- off a panel or a button -- is not the end
	-- of a drag another finger is making, and never a tap on the map.
	if input.UserInputType == Enum.UserInputType.Touch and not tracked then
		return
	end
	if not dragging then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		dragging = false
		-- NET displacement from where the press went down -- NOT the distance
		-- the pointer travelled. A finger resting on glass reports a stream of
		-- one-pixel jitter, and summing that blew through a 6px path budget on
		-- taps that never actually went anywhere, so a tap on enemy land was
		-- classified as a pan and the attack was never sent at all.
		local endPos = Vector2.new(input.Position.X, input.Position.Y)
		local slop = pressIsTouch and Config.TAP_SLOP_TOUCH or Config.CLICK_DRAG_THRESHOLD
		-- THE CLOCK TEST IS THE PAD'S (see gp.press): a tap that follows the
		-- pad's own A press by less than a fifth of a second IS that press,
		-- emulated, and sending it on would attack twice off one push.
		if (endPos - pressPos).Magnitude <= slop
			and os.clock() - (hud.padClickAt or -1e9) > 0.2
		then
			-- InputObject.Position, so fromGui. Getting this one wrong put
			-- every click a whole topbar above the cursor.
			sendClick(fromGui(endPos.X, endPos.Y))
		end
	end
end)

-- Attack size: the three buttons on the command bar, or 1 / 2 / 3. Both
-- routes run the same function, so the key and the button cannot drift.
local PRESET_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.KeypadOne] = 1,
	[Enum.KeyCode.KeypadTwo] = 2,
	[Enum.KeyCode.KeypadThree] = 3,
}

local function setAttackRatio(r: number)
	attackRatio = math.clamp(r, Config.MIN_ATTACK_RATIO, Config.MAX_ATTACK_RATIO)
	-- Repainted on the spot rather than waiting for the next frame: the
	-- point of a preset is that the troop figure answers on the press.
	hud:setRatio(attackRatio, myTroopsShown)
end

hud:bindPresets(setAttackRatio)

-- One table, refilled in place. It is read once a frame and a fresh one each
-- time is garbage for nothing. DECLARED ABOVE `arm` (2026-09-21), which reads
-- it for the reinforcement pre-check: a `local` is not in scope before its own
-- line, and `arm` would otherwise be reading a nil GLOBAL of this name -- the
-- same trap the note over `lastClickTile` describes.
-- `reinforce` opens at the smallest honest price (the floor times the rate)
-- for the frame or two before the first `fronts` prices it, the way
-- CITY_COST_FIRST does for the city; `reinforceLeft` is the cooldown in ticks,
-- a sibling KEY in the same table rather than a local of this file's own --
-- see the note over buildMode for why there is no register left for one.
-- setActions reads it as `<id>Left` beside the price.
local ACTION_COSTS = {
	city = 0, port = 0, post = 0, sam = 0, artillery = 0, airfield = 0, nuke = Config.ATOM_BOMB_COST or 750000,
	-- The mega nuke's is flat like the atom bomb's (2026-09-22); the rail
	-- prints it under the MEGA NUKE card for a pass holder.
	meganuke = Config.MEGA_NUKE_COST or 2500000,
	-- The two late-game weapons (2026-09-24): the scattershot flat, the
	-- railgun's ladder fed off the HUD every frame like the airfield's.
	scattershot = Config.SCATTERSHOT_COST or 3750000,
	railgun = 0,
	reinforce = Config.REINFORCE_COST or 100000,
	reinforceLeft = 0,
}

-- ONE ARMED THING AT A TIME. The rail's three buttons and the C / P / F / N
-- keys both route through `arm`, so a key and a button can never leave the
-- HUD lit for one mode while the next click runs a different one.
local function arm(id: string?)
	-- REINFORCEMENTS ARE NOT A MODE (2026-09-21). The rail button, the E key
	-- and nothing else reach here with this id, and it acts on the press:
	-- nothing is armed, nothing is disarmed -- a city held ready stays ready,
	-- a gunboat in hand stays in hand -- which is why this returns before
	-- every line below. Refused in a lesson round like the post and the
	-- tower (the rail hides the button there; this shuts the key). The three
	-- refusals the server would send are caught HERE first, off the last
	-- `fronts` quote, for the reason sendClick refuses an unaffordable build
	-- before sending it: a press that does nothing for a round trip reads as
	-- a dead button, so it is this that makes the noise and says why. The
	-- server re-checks all three regardless and its answer wins on a race.
	-- The coin plays when the intent goes out -- the money leaves on the
	-- press, the same rule a build follows -- and "Landing" answers when the
	-- men arrive (the `reinforced` handler).
	if id == "reinforce" then
		-- THE BARRACKS BUNDLE'S CARD (2026-09-22, owner: "I only want people who
		-- have the gamepass to have access to it"). The rail hides the tile
		-- without the pass (HUD, RAIL_ACTIONS.pass) and this shuts the E key,
		-- which is the only other way in. Silent, like every hidden card's key:
		-- with nothing on screen there is no button for the noise to belong to.
		-- ConquestServer re-checks and its answer wins on a race.
		if hud:isTutorial() or phase ~= "playing" or not hasSpawned or not hud:passHeld("BARRACKS") then
			return
		end
		local why = (hud:reinforceLeft() > 0 and "cooldown")
			or (myGold < hud:reinforceCost() and "gold")
			or nil
		if why then
			Sfx.play("Deny")
			alertText = buildRefusalText(why)
			alertUntil = os.clock() + 2.5
			return
		end
		IntentRE:FireServer({ t = "reinforce" })
		Sfx.play("Coin")
		return
	end
	if id ~= nil and (phase ~= "playing" or not hasSpawned) then
		id = nil
	end
	-- A GUNBOAT IN HAND IS PUT DOWN. With a building armed the next press
	-- builds, and a ring left on her would promise a move that press can no
	-- longer make. See sendClick.
	if id ~= nil then
		structures:selectGunboat(nil)
		-- ...and an airfield in hand likewise (2026-09-21).
		structures:selectAirfield(nil)
	end
	-- NO DEFENCE POST IN A LESSON ROUND (owner, 2026-09-12: "defence tower
	-- should not be in tutorial"). The rail hides its button there -- see
	-- RAIL_ACTIONS.tutHide in HUD -- and this is the other half of that. The
	-- T key, the pad's LB and B's re-arm-whatever-was-armed-last all reach
	-- the mode through HERE, so hiding the button on its own would leave
	-- three unlabelled ways into a building the tutorial never teaches.
	-- ...AND THE ANTI-NUKE TOWER WITH IT (2026-09-14), for the same reason
	-- and through the same funnel: the rail hides its button in a lesson
	-- (tutHide), and the G key, B's re-arm-whatever-was-armed-last and the
	-- virtual cursor would all still reach the mode without this.
	-- ...UNLESS THE TOWER WAS BOUGHT. Starter Pack #1 is sold inside the
	-- lesson and grants one, and this funnel is what EVERY route to placing
	-- one passes through -- the rail button, the T key, the pad's LB, and B's
	-- re-arm-whatever-was-armed-last. Left as it was, the tutorial would take
	-- the money and then refuse all four. The anti-nuke tower has no such
	-- product behind it and keeps the flat refusal.
	-- A BOUGHT ANTI-NUKE TOWER (Starter Pack #2) opens "sam" the same way a
	-- bought post opens "post": only while one is in hand.
	-- ...AND THE BATTERY AND THE AIRFIELD (2026-09-21), flat, like the tower:
	-- nothing sells either inside a lesson.
	if ((id == "post" and hud:freePosts() == 0) or (id == "sam" and hud:freeSams() == 0) or id == "artillery" or id == "airfield"
		or id == "railgun" or id == "scattershot") and hud:isTutorial() then
		id = nil
	end
	-- THE FACTORY IS DISABLED (Config.FACTORIES_ENABLED, 2026-09-18). No key or
	-- pad button reaches here with it any more; this catches B's re-arm of a
	-- stale buildKind and anything else that still knows the word.
	if id == "factory" and not Config.FACTORIES_ENABLED then
		id = nil
	end
	-- THE MEGA NUKE CARD IS THE PASS'S (2026-09-22). The rail hides the tile
	-- for everyone else (HUD, RAIL_ACTIONS.pass), and this is the other half:
	-- the M key and B's re-arm of a stale mode both come through here, so
	-- without it a hidden card would still have two unlabelled doors. Shut in
	-- a lesson too, like every untaught card above.
	if id == "meganuke" and (hud:isTutorial() or not hud:passHeld("MEGANUKE")) then
		id = nil
	end
	-- ...AND THE BATTERY AND THE AIRFIELD ARE THEIR BUNDLES' (2026-09-22, owner:
	-- "I only want people who have the gamepass to have access to it"). The same
	-- two halves as the card above -- the rail hides the tile, this shuts the R
	-- and F keys and B's re-arm of a stale mode -- and the same third half on
	-- the server, which refuses kinds 18 and 19 from a non-holder. The pass may
	-- have been bought with Robux or with Money; both write the attribute HUD
	-- mirrors, so both open the card mid-round. The flat lesson refusal a few
	-- lines up still stands on its own: a holder gets neither in a lesson.
	if (id == "artillery" and not hud:passHeld("ARTILLERY"))
		or (id == "airfield" and not hud:passHeld("AIRSTRIKE"))
		-- The late-game pair's passes (2026-09-24), the same rule.
		or (id == "railgun" and not hud:passHeld("RAILGUN"))
		or (id == "scattershot" and not hud:passHeld("SCATTERSHOT"))
	then
		id = nil
	end
	if id == "nuke" or id == "meganuke" or id == "scattershot" then
		buildMode, nukeMode = false, true
		-- Which warhead the mode fires -- see place.warhead. 17 is
		-- Units.MEGA_NUKE and 20 Units.SCATTERSHOT, literals for the reason
		-- KIND_ATOM is.
		place.warhead = if id == "meganuke" then 17 elseif id == "scattershot" then 20 else KIND_ATOM
	elseif id ~= nil then
		nukeMode, buildMode = false, true
		-- 5 is Units.SAM_LAUNCHER, written out rather than named: a KIND_SAM
		-- beside the four above is one local more than this chunk has (see the
		-- note over buildMode), and the wire numbering is what buildKind holds.
		buildKind = (id == "port" and KIND_PORT)
			or (id == "factory" and KIND_FACTORY)
			or (id == "post" and KIND_POST)
			or (id == "sam" and 5)
			-- 18 is Units.ARTILLERY, a literal for the same reason.
			or (id == "artillery" and 18)
			-- 19 is Units.AIRFIELD (2026-09-21), a literal for the reason 5 is.
			or (id == "airfield" and 19)
			-- 21 is Units.RAILGUN (2026-09-24).
			or (id == "railgun" and 21)
			or KIND_CITY
	else
		buildMode, nukeMode = false, false
	end
	-- THE PREVIEW IS PART OF BEING ARMED, so it goes on and off here and
	-- nowhere else. On a mouse it appears under the cursor on the press; on a
	-- touch screen there is no hover, so the tap that names a tile is also
	-- the tap that commits it -- see sendClick.
	if id == nil then
		place.clear()
	else
		place.arm()
	end
end

-- Derived, never stored: the lit button is read back out of the same two
-- variables the click handler branches on, so the light cannot lie.
local function armedId(): string?
	if nukeMode then
		return if place.warhead == 17 then "meganuke" elseif place.warhead == 20 then "scattershot" else "nuke"
	elseif buildMode then
		return (buildKind == KIND_PORT and "port")
			or (buildKind == KIND_FACTORY and "factory")
			or (buildKind == KIND_POST and "post")
			or (buildKind == 5 and "sam")
			or (buildKind == 18 and "artillery")
			or (buildKind == 19 and "airfield")
			or (buildKind == 21 and "railgun")
			or "city"
	end
	return nil
end

local KEY_ACTIONS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.C] = "city",
	[Enum.KeyCode.P] = "port",
	-- F was the factory until 2026-09-18 (Config.FACTORIES_ENABLED); the
	-- airfield's since 2026-09-21.
	[Enum.KeyCode.F] = "airfield",
	[Enum.KeyCode.N] = "nuke",
	-- T for tower, which is what the icon is. D is the obvious letter and is
	-- the camera's -- it pans east (PAN_KEYS below) -- and so are W/A/S, B for
	-- build mode and C/P/F/N above.
	[Enum.KeyCode.T] = "post",
	-- G for the anti-nuke tower: every letter this game has a use for is
	-- taken -- C/P/F/N/T are the other builds, B is build mode, W/A/S/D and
	-- the arrows are the camera, 1/2/3 the attack sizes.
	[Enum.KeyCode.G] = "sam",
	-- E for reinforcements (2026-09-21): an instant purchase, not a mode --
	-- see `arm`. E was free (keys taken: W A S D, C P N T G B, 1 2 3).
	[Enum.KeyCode.E] = "reinforce",
	-- R for the battery (2026-09-21): E / F / R were the letters left, and R
	-- is the one under the fingers that already rest on W / A / S / D.
	[Enum.KeyCode.R] = "artillery",
	-- M for the mega nuke (2026-09-22). `arm` refuses it without the pass and
	-- in a lesson, the same funnel the rail card goes through.
	[Enum.KeyCode.M] = "meganuke",
	-- The late-game pair (2026-09-24): L for raiLgun, X for the scattershot.
	[Enum.KeyCode.L] = "railgun",
	[Enum.KeyCode.X] = "scattershot",
}
-- Pressing the button that is already armed disarms it. The button is the
-- only VISIBLE way out of the mode, and one that cannot be pressed off is a
-- trap on a touchscreen, where there is no ESC key to fall back on.
hud:bindActions(function(id: string)
	arm(armedId() ~= id and id or nil)
end)

-- THE WAY OUT. The HUD has already taken the second press that confirms it, so
-- by the time this runs the player has asked twice. Nothing is torn down here
-- and no state is cleared: the server answers with a teleport, and until it
-- lands the match goes on exactly as it was -- a client that blanked its own
-- map on the press would spend that round trip looking like it had crashed.
hud:bindLeave(function()
	alertText = "Leaving..."
	alertUntil = os.clock() + 5
	IntentRE:FireServer({ t = "leave" })
end)

-- REVIVE goes up the intent remote the way LEAVE does: the server decides
-- whether a token is spent or a purchase is prompted, and answers on "revive".
hud:bindRevive(function()
	IntentRE:FireServer({ t = "revive", tile = 0 })
end)

-- ============================================================ controller ==
-- A CONSOLE PLAYS THIS WITH ROBLOX'S VIRTUAL CURSOR (see Gamepad): the left
-- stick is the mouse and RT is its button, so hovering, attacking, placing,
-- dragging the map and every button on the HUD already work through the
-- handlers above. What a pad has that a mouse does not is wired here --
--
--   A              press the map under the cursor: attack, build, gunboat
--   LB / RB        zoom out / in, anchored under the cursor (gp.step)
--   right stick    pan (in driveCamera, beside WASD)
--   B              cancel: disarm placing, or an armed LEAVE
--   d-pad          attack size, one preset either way
--
-- THE CURSOR CLICKS WITH RT, AND A DID NOTHING AT ALL (owner, 2026-09-22:
-- "for controller settings, it says A to attack, but only RT works").
-- Roblox's virtual cursor presses with ButtonR2 and leaves A free -- A is
-- jump in every experience that has one -- so the legend named a button
-- that was wired to nothing. Both halves of that are answered here. A
-- presses the MAP under the cursor (gp.press), which is the console
-- convention and what the legend promises; a GuiButton is still pressed
-- with the cursor's own RT click, which belongs to the engine and cannot
-- be moved. AND THE ZOOM CAME OFF THE TRIGGERS: with RT as the click, a
-- pull to zoom in also fired a press at whatever the cursor was standing
-- on -- an attack on the tile under it, or the card it was over.
--
-- -- and while a pad is the last thing touched the rail's hotkey captions go
-- BLANK and the HUD's pad legend comes up in the top-left corner (A ATTACK,
-- LB RB ZOOM). NO BUTTON ON THE PAD ARMS A CARD (owner, 2026-09-21:
-- "for the cards like port, city and all that, you don't have to have a
-- keybind for it, players should just be able to click it as normal"). Until
-- then X / Y / LB / RB / R3 armed the five rail actions and the rail printed
-- those names in place of C / P / N; a card is a button the cursor presses,
-- and a chord on the pad was a second, invisible way in that a stray press
-- while aiming could fire. ONE TABLE for the same reason `place` is one: this
-- file sits on Luau's 200-local ceiling.
local gp = {
	-- Zoom per second at a full trigger pull: eight wheel notches (1.18^8).
	ZOOM_RATE = 3.75,
	-- Whether the rail's captions and the legend are currently the pad's.
	padLabels = false,
}

-- One preset up or down from the one nearest the current ratio. Nearest,
-- not equal, for the reason HUD.selectPreset gives: the ratio may sit a
-- float off a preset, and a step that finds no match would go nowhere.
function gp.stepPreset(dir: number)
	local presets = Config.ATTACK_PRESETS
	if not presets or #presets == 0 then
		return
	end
	local best, bestD = 1, math.huge
	for i, r in presets do
		local d = math.abs(r - attackRatio)
		if d < bestD then
			best, bestD = i, d
		end
	end
	local i = math.clamp(best + dir, 1, #presets)
	if i ~= best then
		-- The press sounds here for the reason the size buttons sound in
		-- the HUD: it is the press that clicked, whatever it changed.
		Sfx.play("Click")
		setAttackRatio(presets[i])
	end
end

-- A pad button went down. True when it was one of ours, so the keyboard
-- handler below does not also look at it.
function gp.press(key: Enum.KeyCode): boolean
	if key == Enum.KeyCode.ButtonA then
		-- THE PAD'S ATTACK -- and everything else a press on the map does:
		-- this is the mouse's own entry point, so placing a building,
		-- picking up a gunboat and declaring a war all come out of it
		-- unchanged. GATED THE WAY THE MOUSE IS GATED: `pointerOverMap`
		-- goes false under an Active panel and `pointerOverHud` covers the
		-- rest of this ScreenGui, so A over the rail or an open shop does
		-- nothing rather than attacking the map behind it.
		local px, py = pointer()
		if pointerOverMap and not pointerOverHud(px, py) then
			-- STAMPED SO ONE PUSH CANNOT ATTACK TWICE. Should a pad turn up
			-- whose cursor DOES click with A, that emulated press arrives on
			-- the mouse path as well, and the tap there drops anything that
			-- lands within a breath of this one.
			hud.padClickAt = os.clock()
			sendClick(px, py)
		end
		return true
	end
	if key == Enum.KeyCode.ButtonB then
		-- The way out of anything armed, which is what B means everywhere
		-- else on a console. Nothing armed: nothing happens, and the press
		-- is still ours -- B is never a letter.
		if armedId() ~= nil then
			arm(nil)
		end
		-- ...and puts down a gunboat in hand, which is the same kind of thing.
		structures:selectGunboat(nil)
		structures:selectAirfield(nil)
		hud:disarmLeave()
		return true
	end
	if key == Enum.KeyCode.DPadLeft or key == Enum.KeyCode.DPadDown then
		gp.stepPreset(-1)
		return true
	elseif key == Enum.KeyCode.DPadRight or key == Enum.KeyCode.DPadUp then
		gp.stepPreset(1)
		return true
	end
	return false
end

-- Once a frame, from the render loop beside driveCamera.
function gp.step(dt: number)
	-- THE SHOULDERS ZOOM -- LB out, RB in -- at the pace a full trigger pull
	-- used to give. They took it from LT / RT on 2026-09-22 because RT is
	-- the virtual cursor's CLICK (see the block above this one), so every
	-- pull to zoom in also pressed whatever the cursor stood on. A
	-- shoulder is digital, hence Gamepad.down where this asked
	-- Gamepad.trigger. Anchored under the cursor while it is on the map,
	-- so the ground under it stays put -- the wheel's own rule -- and at
	-- the centre of the clear strip between the HUD bands otherwise.
	local pull = (if Gamepad.down(Enum.KeyCode.ButtonR1) then 1 else 0)
		- (if Gamepad.down(Enum.KeyCode.ButtonL1) then 1 else 0)
	if pull ~= 0 and renderer then
		local size = viewport.AbsoluteSize
		local px, py = pointer()
		if not (Gamepad.cursorOn() and pointerOverMap) or pointerOverHud(px, py) then
			local top, bottom = hud:insets(size.X, size.Y)
			px, py = size.X / 2, (top + size.Y - bottom) / 2
		end
		-- Held open while the zoom is held and for a beat after it is let go:
		-- this loop polls the pad once a frame rather than watching for the
		-- release, and without it the clamp fought a console player exactly
		-- as it fought a thumb -- 43px on 1920x1080, 119px on 1280x720, for
		-- one second of it.
		camera:softFor(0.25)
		camera:zoomAt(gp.ZOOM_RATE ^ (pull * dt), px, py)
		camera:apply(mapImage)
		hoverDirty = true
	end

	-- The rail's captions and the legend follow the last device touched.
	-- Compared before written: this runs every frame, and the HUD repaints
	-- only on change. A pad has no letters, so the rail's captions go blank
	-- (an empty table: see HUD.setActionKeys) and the legend names the two
	-- things the cursor does not spell out, in the pad's own family.
	local on = Gamepad.active()
	if on ~= gp.padLabels then
		gp.padLabels = on
		if on then
			hud:setActionKeys({})
			hud:setPadHints({
				attack = Gamepad.label(Enum.KeyCode.ButtonA),
				zoomOut = Gamepad.label(Enum.KeyCode.ButtonL1),
				zoomIn = Gamepad.label(Enum.KeyCode.ButtonR1),
			})
		else
			hud:setActionKeys(nil)
			hud:setPadHints(nil)
		end
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	-- THE PAD'S BUTTONS, by KeyCode alone: no keyboard has a ButtonB, so a
	-- device check would only cost the Studio bridge -- which delivers these
	-- codes as keyboard events -- its way of exercising this path. AHEAD OF
	-- `processed`, because the virtual cursor is a GUI pointer and a press
	-- made while it stands on something can arrive marked handled -- which
	-- would eat A, the pad's attack. Each button below tests for itself
	-- where the cursor is.
	if gp.press(input.KeyCode) then
		return
	end
	if processed then
		return
	end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.B then
		-- Kept from before the rail existed: B arms whichever building was
		-- armed last, and C / P / F still swap between them.
		if buildMode then
			arm(nil)
		else
			arm((buildKind == KIND_PORT and "port")
				or (buildKind == KIND_POST and "post")
				or (buildKind == 5 and "sam")
				or (buildKind == 18 and "artillery")
				or (buildKind == 19 and "airfield")
				or (buildKind == 21 and "railgun")
				or (buildKind == KIND_FACTORY and "factory")
				or "city")
		end
		return
	end
	if key == Enum.KeyCode.Escape then
		-- Puts down a gunboat in hand too, the way B does on a pad.
		structures:selectGunboat(nil)
		structures:selectAirfield(nil)
		if armedId() ~= nil then
			arm(nil)
			return
		end
	end
	-- The building keys no longer need build mode to be ON first. They used to
	-- be a second step inside a mode that nothing on screen announced; each one
	-- now arms its own thing directly, and pressing the armed one again
	-- disarms it -- the same rule the rail buttons follow.
	local direct = KEY_ACTIONS[key]
	if direct then
		arm(armedId() ~= direct and direct or nil)
		return
	end
	local preset = PRESET_KEYS[key]
	if preset and Config.ATTACK_PRESETS and Config.ATTACK_PRESETS[preset] then
		setAttackRatio(Config.ATTACK_PRESETS[preset])
	end
end)

-- ========================================================== camera drive ===
-- Dragging the map is fine for a nudge and miserable for crossing a country:
-- the hand has to let go of the map to do anything else, and a drag that
-- starts on your own land is one slip away from being an attack. So the camera
-- also drives itself -- WASD or the arrow keys while a key is held, and a push
-- when the pointer leans on the edge of the screen.
--
-- SIGNS. `camera.x/y` is the screen offset of map pixel (0,0), so looking
-- NORTH means sliding the map DOWN: W is +y. Looking west is +x.
local PAN_KEYS = {
	{ Enum.KeyCode.W, Enum.KeyCode.Up, 0, 1 },
	{ Enum.KeyCode.S, Enum.KeyCode.Down, 0, -1 },
	{ Enum.KeyCode.A, Enum.KeyCode.Left, 1, 0 },
	{ Enum.KeyCode.D, Enum.KeyCode.Right, -1, 0 },
}

-- SCREEN PIXELS a second, not tiles a second. The camera is a window over an
-- image and what a hand expects is the IMAGE moving under it at a constant
-- rate; a tiles-per-second rate would crawl at 12x zoom and be uncontrollable
-- at 1x. Roughly one screen-width per second at 1080p, which is the pace that
-- lets you cross this map without letting go of the keys.
local PAN_SPEED = 1150
local PAN_FAST = 2.2
-- How deep the band is that the pointer has to be inside for the edge push.
-- The push RAMPS from nothing at the inner edge of the band to full at the
-- screen edge: a binary "inside the band" push feels like a trapdoor, and the
-- ramp is what makes it feel like leaning on the map.
local EDGE_BAND = 34
local EDGE_PAN = true

-- A key released while the window was not focused never delivers its
-- InputEnded, so held keys are POLLED once a frame rather than tracked through
-- InputBegan/InputEnded -- otherwise alt-tabbing mid-press leaves the camera
-- sliding forever with nothing to stop it.
local windowFocused = true
UserInputService.WindowFocused:Connect(function()
	windowFocused = true
end)
UserInputService.WindowFocusReleased:Connect(function()
	windowFocused = false
end)

local function edgePush(p: number, size: number): number
	if p < EDGE_BAND then
		return (EDGE_BAND - p) / EDGE_BAND
	elseif p > size - EDGE_BAND then
		return -(p - (size - EDGE_BAND)) / EDGE_BAND
	end
	return 0
end

local function driveCamera(dt: number)
	local dx, dy = 0, 0

	-- Typing in the chat box must not fly the camera around.
	if windowFocused and UserInputService:GetFocusedTextBox() == nil then
		for _, k in PAN_KEYS do
			if UserInputService:IsKeyDown(k[1]) or UserInputService:IsKeyDown(k[2]) then
				dx += k[3]
				dy += k[4]
			end
		end
	end
	-- THE RIGHT STICK PANS, beside the keys and added to them: half over is
	-- half speed, full over is exactly a held key, and it counts as `keyed`
	-- below so the edge push stays out of its way. Same signs as PAN_KEYS --
	-- up on the stick looks north, which slides the map down.
	-- ...unless that stick is busy scrolling a panel the cursor is standing
	-- on. A pad has no wheel, so the right stick is also how the store and
	-- the flag catalogue are read (see Gamepad.scrolling), and the map
	-- sliding about behind an open shop is not what that push meant.
	if not Gamepad.scrolling() then
		local sx, sy = Gamepad.stick(Enum.KeyCode.Thumbstick2)
		dx -= sx
		dy += sy
	end
	local keyed = dx ~= 0 or dy ~= 0

	-- Keys WIN over the edge: a player holding D with the cursor parked on the
	-- left edge means to go east, and summing the two would cancel out. The
	-- controller's virtual cursor leans on the edge the way a mouse does.
	if EDGE_PAN and not keyed and pointerOverMap and windowFocused
		and not dragging and (UserInputService.MouseEnabled or Gamepad.cursorOn())
	then
		local size = viewport.AbsoluteSize
		local px, py = pointer()
		-- The rect test, not `pointerOverMap` alone -- see pointerOverHud.
		if not pointerOverHud(px, py) then
			dx += edgePush(px, size.X)
			dy += edgePush(py, size.Y)
		end
	end

	if dx == 0 and dy == 0 then
		return
	end
	-- Normalised only when it would EXCEED full speed, so two keys at once is
	-- not 1.41x a single key while a half-strength edge push stays at half.
	local len = math.sqrt(dx * dx + dy * dy)
	local speed = PAN_SPEED * dt * math.min(1, len) / len
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	then
		speed *= PAN_FAST
	end
	camera:pan(dx * speed, dy * speed)
	camera:apply(mapImage)
	hoverDirty = true
end

-- ================================================================== loop ===

updateViewport()

-- Troop income per second, from the same curve the server integrates. Shown
-- rather than derived by the player from a bar that moves twice a second.
local function incomePerSec(troops: number, maxTroops: number): number
	if maxTroops <= 0 then
		return 0
	end
	local g = (Config.GROWTH_BASE + (troops ^ Config.GROWTH_EXPONENT) / Config.GROWTH_DIVISOR)
		* (1 - troops / maxTroops)
	if g < 0 then
		g = 0
	end
	-- ...AND THE SKIN'S BONUS, which the server applies to this same curve. It
	-- arrives on the private `fronts` push; 0 until the first one lands, which
	-- is what it was worth before this anyway.
	g *= 1 + (hud.growthBoost or 0)
	return g * Config.TICK_RATE
end

-- ARTILLERY, SOMEWHERE OFF THE EDGE OF WHAT YOU CAN SEE. The only ambient
-- sound in the game and the only one not tied to a single event: it is on
-- while you have live fronts and off the moment you do not, which is what
-- makes the silence mean something -- either you are at peace or you are dead.
--
-- DELIBERATELY SPARSE AND QUIET. A front is a state that lasts minutes, so
-- anything repeating on a regular beat would be the loudest thing in the room
-- by the third one. Random gaps of several seconds instead, at a fraction of
-- the sample's authored volume, scaled by how many fronts are open: one
-- skirmish is a rumble on the horizon, six of them is a war.
local BARRAGE_MIN_GAP = 3.5
local BARRAGE_MAX_GAP = 7
local barrageAt = 0

local function stepBarrage()
	if frontHeat <= 0 or phase ~= "playing" then
		barrageAt = 0
		return
	end
	local now = os.clock()
	if barrageAt == 0 then
		-- First front of the round: hold a beat rather than firing on the same
		-- frame the fighting started, where it would be heard as part of the
		-- attack that started it rather than as the front it opened.
		barrageAt = now + 1.5
		return
	end
	if now < barrageAt then
		return
	end
	barrageAt = now + BARRAGE_MIN_GAP + math.random() * (BARRAGE_MAX_GAP - BARRAGE_MIN_GAP)
	Sfx.play("Barrage", { volume = math.min(1, 0.35 + frontHeat * 0.12) })
end

-- Was the camera shaking LAST frame? Only there so the frame the kick reaches
-- zero still runs one apply and puts the map back exactly where it was.
local shaking = false

RunService.RenderStepped:Connect(function(dt)
	if renderer then
		renderer:flush()
		-- Point-sampled terrain DROPS tile columns below 1:1 while the markers
		-- over it glide, which is what read as the rails and buildings moving at
		-- a different rate from the map -- see Renderer.setResample. One compare
		-- a frame, and it only touches the labels when the answer changes.
		renderer:setResample(camera.zoom)
	end

	elapsed += dt
	-- THE TWO HALVES OF THE ROUND CLOCK. The placement window runs DOWN and the
	-- war clock does not start until it is over, so between them the HUD counts
	-- down to the start and then up from it.
	if phase == "spawn" then
		phaseRemaining = math.max(0, phaseRemaining - dt)
	else
		warElapsed += dt
	end

	-- WASD and the edge push. Driven from the frame loop rather than from an
	-- input event because holding a key is a STATE, not an event: the camera
	-- has to move on every frame the key is down, not once when it goes down.
	driveCamera(dt)
	-- The controller's own per-frame work: trigger zoom, rail captions.
	gp.step(dt)
	if hoverDirty then
		hoverDirty = false
		if pointerOverMap then
			updateHover(pointer())
		end
	end

	-- Walks the map labels to their targets and re-decides visibility.
	nationLabels:step(dt, camera.zoom)
	structures:step(dt, camera.zoom)
	missiles:step(dt)
	hud:step(dt)
	stepClickFeedback(dt)
	stepSkulls(dt)
	stepPayouts(dt)
	stepPick(dt)
	-- THE FIRST AIRFIELD BORROWS THE LESSON RING (owner, 2026-09-22: "when the
	-- player places their first airfield each game, add a tap indicator similar
	-- to the one in the tutorial"). Structures offers the tile -- the first
	-- field of ours to finish, until it is pressed or razed -- and a card's own
	-- tile always wins, the field's coming back when the card lets go, so the
	-- two never fight over the one ring. Written only on a change: every call
	-- to setTutorialTarget restarts the ripple.
	do
		local want = hud.lessonTile or structures:airfieldGuide()
		if want ~= guideTile then
			setTutorialTarget(want)
		end
	end
	stepGuide(dt)
	stepBarrage()

	-- A detonation kicks the view. The offset goes through the CAMERA rather
	-- than onto the container, so that where the map is drawn and where a click
	-- lands stay one answer while it is shaking -- see Camera2D.apply. Two
	-- frequencies with no common period, so it reads as a rumble and not as a
	-- wobble, and one extra apply a frame for half a second costs nothing next
	-- to the fireball it is under.
	-- WALKS THE MAP HOME AFTER A PINCH. While the fingers were down the clamp
	-- was soft so the ground could stay under them; this is the ease back into
	-- the rest region, and it sets `camera.settling` for the test below rather
	-- than returning into a local, because this file is at its register
	-- ceiling. See Camera2D.setSoft.
	camera:settle(dt)

	local kick = missiles.shake
	if kick > 0 or shaking or camera.settling then
		shaking = kick > 0
		camera.shakeX = kick * math.sin(elapsed * 61.0)
		camera.shakeY = kick * math.sin(elapsed * 43.7)
		camera:apply(mapImage)
	end

	-- Build mode is not a state you can be in by accident: it ends the moment
	-- the round does or you stop being a live empire.
	-- ...OR YOUR EMPIRE IS GONE. `hasSpawned` is set when the first tiles
	-- arrive and cleared only by `init`, so it stays true after an empire falls
	-- (HUD's showActions says as much). Without the tile test the ghost kept
	-- riding the pointer over land the player no longer owned, the banner kept
	-- reading BUILD A CITY, and every press spent a round trip on a refusal.
	if (buildMode or nukeMode)
		and (phase ~= "playing" or not hasSpawned or (myTiles ~= nil and myTiles <= 0))
	then
		place.disarm()
	end
	-- THE GHOST IS RE-TESTED, NOT TRUSTED. Gold ticks up past the cost, a
	-- neighbour takes the tile out from under it, somebody's city goes up
	-- inside the spacing radius -- all three change the answer without the
	-- pointer having moved. Six times a second covers every one of them and
	-- keeps the marker walk off the frame budget.
	if (buildMode or nukeMode) and place.tile ~= nil then
		place.age += dt
		if place.age >= place.RETEST then
			place.refresh()
		end
	end
	-- The rail exists only while you are a live empire in a live round: three
	-- buttons that cannot be pressed are three questions about why not.
	hud:showActions(phase == "playing" and hasSpawned)
	-- The way out is up for the whole of a match and NOT gated on being alive --
	-- somebody who has just been wiped off the map is the player most likely to
	-- want it, and a control that disappears at exactly the moment it is wanted
	-- is worse than none. Down on the lobby page, where there is nothing to
	-- leave and the page has its own front door.
	hud:showLeave(phase ~= "lobby")
	ACTION_COSTS.city = myCityCost
	ACTION_COSTS.port = myPortCost
	ACTION_COSTS.post = myPostCost
	-- Off the HUD rather than a local of this file's own -- HUD.setSamCost.
	ACTION_COSTS.sam = hud:samCost()
	-- The reinforcement quote too -- HUD.setReinforce; see the note there.
	ACTION_COSTS.reinforce = hud:reinforceCost()
	ACTION_COSTS.reinforceLeft = hud:reinforceLeft()
	ACTION_COSTS.artillery = hud:artilleryCost()
	ACTION_COSTS.airfield = hud:airfieldCost()
	ACTION_COSTS.railgun = hud:railgunCost()
	hud:setActions(armedId(), ACTION_COSTS, myGold)

	-- One smoother, from the shared module, for all four: the bar, its
	-- ceiling, the tile count and the gain readout must not disagree about
	-- how fast a number is allowed to move.
	myTroopsShown = Numbers.approach(myTroopsShown, myTroops, dt, 14)
	myMaxShown = Numbers.approach(myMaxShown, myMaxTroops, dt, 9)
	myGainShown = Numbers.approach(myGainShown, myGain, dt, 6)
	-- Gold climbs at a flat 1000 a second, so it is the one figure that would
	-- look WRONG counting smoothly toward a target that is already moving --
	-- but the same ease is what stops the 25,000-point jump of a conquest from
	-- reading as a glitch. Faster than the troop smoother for exactly that
	-- reason: it has less distance to cover on an ordinary tick.
	myGoldShown = Numbers.approach(myGoldShown, myGold, dt, 16)
	-- The readout follows what is ARMED: while build mode is on it prices the
	-- thing you are about to place, and otherwise it shows the city, which is
	-- the building that matters to the army.
	if buildMode and buildKind == KIND_PORT then
		hud:setGold(myGoldShown, myPortCost, myPorts, "PORT")
	elseif buildMode and buildKind == KIND_FACTORY then
		hud:setGold(myGoldShown, myFactoryCost, myFactories, "FACTORY")
	else
		hud:setGold(myGoldShown, myCityCost, myCities, "CITY")
	end
	hud:setGain(myGainShown)
	hud:setArmy(myTroopsShown, myMaxShown, incomePerSec(myTroopsShown, myMaxShown))
	-- DOWN TO THE START, THEN UP FROM IT -- the clock is fed the placement
	-- window while there is one and the war clock after that.
	if phase == "spawn" then
		hud:setTimer(phaseRemaining, phase, true)
	else
		hud:setTimer(warElapsed, phase == "playing" and "WAR" or phase)
	end
	-- Keep the committed-troop figure live as the army grows.
	hud:setRatio(attackRatio, myTroopsShown)

	-- Build mode outranks the alert line: it is a state the player is IN, not
	-- an event that happened, and leaving it unsignposted turns the next click
	-- into a surprise.
	--
	-- ONE THING, IN THREE WORDS (owner, 2026-09-03: "just say build a city for
	-- the notif. simplify all notifs"). This line used to carry five facts at
	-- once -- the mode, where to click, the price, the three hotkeys and the way
	-- out -- of which the rail button already prices the building and the ghost
	-- under the pointer already shows where it may go. What is left is the only
	-- thing the banner alone can say: which mode you are in, or why the next
	-- click is going to fail.
	if nukeMode then
		-- Priced off the warhead the card armed (place.warhead): the mega
		-- nuke's flat 3M or the atom bomb's 750k. A free shot is not spelled
		-- out here, as it never was -- the ghost and the press read
		-- place.cost() for that; this strip names the mode.
		local mega = place.warhead == 17
		local cost = if mega then (Config.MEGA_NUKE_COST or 2500000)
			elseif place.warhead == 20 then (Config.SCATTERSHOT_COST or 3750000)
			else (Config.ATOM_BOMB_COST or 750000)
		hud:setBanner(
			myGold >= cost and (if mega then "FIRE A MEGA NUKE" elseif place.warhead == 20 then "FIRE A SCATTERSHOT" else "FIRE A NUKE")
				or ("NEED " .. Numbers.format(cost - myGold) .. " MORE GOLD"),
			myGold >= cost and Color3.fromRGB(255, 176, 96) or Color3.fromRGB(255, 132, 118)
		)
	elseif buildMode then
		-- THE POST AND THE TOWER WERE MISSING FROM THIS LADDER, so the banner
		-- quoted a CITY's price at somebody placing either one -- and for the
		-- tower that is a 1.5M building priced as a 25k one, i.e. the banner
		-- would say BUILD when the click is about to be refused for gold.
		local cost = (buildKind == KIND_PORT and myPortCost)
			or (buildKind == KIND_FACTORY and myFactoryCost)
			-- The banner prices itself off buildKind rather than place.cost(), so
			-- a free tower has to be spelled out again here or the strip reads
			-- "NEED 50,000 MORE GOLD" over a placement that is about to succeed.
			-- That exact mismatch is refusal #2 of the three the free nuke hit.
			or (buildKind == KIND_POST and (hud:freePosts() > 0 and 0 or myPostCost))
			or (buildKind == 5 and (hud:freeSams() > 0 and 0 or hud:samCost()))
			or (buildKind == 18 and hud:artilleryCost())
			or (buildKind == 19 and hud:airfieldCost())
			or (buildKind == 21 and hud:railgunCost())
			or (hud:freeCities() > 0 and 0 or myCityCost)
		hud:setBanner(
			-- "AN" before ANTI-NUKE, ARTILLERY and AIRFIELD. Three buildings in
			-- eight start with a vowel and the banner is read on every placement.
			myGold >= cost and ("BUILD " .. ((buildKind == 5 or buildKind == 18 or buildKind == 19) and "AN " or "A ") .. KIND_NAME[buildKind])
				or ("NEED " .. Numbers.format(cost - myGold) .. " MORE GOLD"),
			myGold >= cost and GOLD or Color3.fromRGB(255, 132, 118)
		)
	elseif phase == "playing" and hasSpawned and alertText and os.clock() < alertUntil then
		hud:setBanner(
			alertText,
			(alertColorText == alertText and alertColor) or Color3.fromRGB(255, 132, 118)
		)
	elseif phase == "playing" and historical and type(historical.grace) == "number" and warElapsed < historical.grace then
		-- THE OPENING TRUCE of a predrawn map: every border is somebody's from
		-- the first tick, so the sim refuses attacks on nations for a while
		-- (Sim.loadScenario). Said here, counting down, or the first minute
		-- reads as every tap being broken.
		hud:setBanner(
			string.format("TRUCE - WAR IN %ds", math.ceil(historical.grace - warElapsed)),
			Color3.fromRGB(255, 226, 140)
		)
	elseif phase == "spawn" then
		if alertText and os.clock() < alertUntil then
			-- Why the last click did not take. In the one phase where clicking the
			-- map is the whole interface, a refusal nobody explains reads as a
			-- dead game rather than as an illegal move.
			hud:setBanner(alertText, Color3.fromRGB(255, 132, 118))
		elseif hud:isTutorial() then
			-- THE CARD IS ALREADY SAYING IT. "PICK YOUR LAND" with a ring on
			-- the ground it means, and a phase clock top-right -- this strip
			-- would print the same instruction and the same countdown a
			-- second time, directly under the card that just said it.
			hud:setBanner(nil)
		elseif myPick and myPickName then
			-- A predrawn map: the claim is a nation, and the banner says which.
			hud:setBanner("PLAYING AS " .. string.upper(myPickName) .. " - TAP ANOTHER TO SWITCH", Color3.fromRGB(150, 220, 170))
		elseif myPick then
			-- THE SECONDS CAME OFF BOTH OF THESE. The clock is counting the same
			-- window down two panels away, and a banner that prints it again is a
			-- second clock rather than an instruction.
			hud:setBanner(
				myTeam and (Palette.teamName(myTeam) .. " TEAM") or "TAP AGAIN TO MOVE",
				myTeam and Palette.teamColor3(myTeam) or Color3.fromRGB(150, 220, 170)
			)
		elseif historical then
			hud:setBanner("PICK A NATION", Color3.fromRGB(255, 226, 140))
		else
			hud:setBanner("PICK YOUR LAND", Color3.fromRGB(255, 226, 140))
		end
	elseif phase == "ended" and winnerName then
		-- AT TWICE THE SIZE (owner, 2026-09-06). The end of the round is the
		-- one moment this strip is the only thing on screen worth reading.
		hud:setBanner(winnerName .. " WINS", Color3.fromRGB(255, 226, 140), true)
	elseif phase == "playing" and not hasSpawned then
		hud:setBanner("SPECTATING", Color3.fromRGB(170, 180, 200))
	else
		hud:setBanner(nil)
	end
end)

-- Every handler above is connected now, so it is safe to ask for our own init
-- rather than hoping the round's broadcast waited for us. See the "hello"
-- branch in ConquestServer.
IntentRE:FireServer({ t = "hello", tile = 0 })

print("[Conquest] client ready")
