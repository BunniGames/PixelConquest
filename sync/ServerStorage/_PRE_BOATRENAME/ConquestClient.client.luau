--!strict
-- Conquest :: client entry
-- Builds the view, mirrors server ownership deltas into the renderer, and
-- turns pointer input into intents.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Camera2D = require(Shared.Camera2D)
local Config = require(Shared.Config)
local HUD = require(Shared.HUD)
local Missiles = require(Shared.Missiles)
local NationLabels = require(Shared.NationLabels)
local Net = require(Shared.Net)
local Numbers = require(Shared.Numbers)
local Palette = require(Shared.Palette)
local Renderer = require(Shared.Renderer)
local Structures = require(Shared.Structures)
local TileMap = require(Shared.TileMap)

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

local camera = Camera2D.new()

-- ================================================================= state ===

local renderer: any = nil
local myId = 0
local roundId = 0
local playableLand = 1
-- What the next click commits. The player sets it from the three size
-- buttons on the command bar or with 1 / 2 / 3; the server snaps whatever
-- arrives to the same preset list, so this is a preference, not a trusted
-- input.
local attackRatio = Config.DEFAULT_ATTACK_RATIO
local phase = "lobby"
local phaseRemaining = 0
local hasSpawned = false
local winnerName: string? = nil

-- Every one of these is a pair: the value the server last told us, and the
-- value currently on screen walking toward it. Nothing the player reads is
-- ever written straight from a network message.
local myTroops, myTroopsShown = 0, 0
local myMaxTroops, myMaxShown = Config.BASE_MAX_TROOPS, Config.BASE_MAX_TROOPS
local myTiles, myTilesShown = 0, 0
local myGain, myGainShown = 0, 0
-- Treasury and structures. Private state: these arrive only for you, on the
-- same per-client message the fronts do.
local myGold, myGoldShown = 0, 0
local myCityCost = Config.CITY_COST_BASE
local myPortCost = Config.PORT_COST_BASE
local myFactoryCost = Config.PORT_COST_BASE
local myCities, myPorts, myCityLevels = 0, 0, 0
local myFactories = 0
-- Armed by B. While it is on, a click buys a building instead of launching an
-- attack; C and P choose WHICH. Two keys rather than a menu, because there are
-- two things to build and a menu with two entries is a menu you have to open.
local buildMode = false
-- These are Units type ids, which is what the server's build intent expects:
-- 1 city, 2 port, 6 FACTORY. Not a dense 1..3 -- the wire numbering wins.
local buildKind = 1
local KIND_CITY, KIND_PORT, KIND_FACTORY = 1, 2, 6
local KIND_NAME = { [1] = "CITY", [2] = "PORT", [6] = "FACTORY" }
-- Units.ATOM_BOMB. Written out rather than required: the client needs ONE
-- number from a 56 KB module, and this comment is the twin the rule about
-- duplicated constants asks for.
local KIND_ATOM = 13
-- Armed exactly the way build mode is, and MUTUALLY EXCLUSIVE with it. One
-- click can only mean one thing, and "place a house" and "erase a city" are
-- the worst possible pair to leave ambiguous.
local nukeMode = false

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
local alertText: string? = nil
local alertUntil = 0
local lastHoverOwner = -1
local lastMouse = Vector2.zero
local elapsed = 0

-- Is the pointer over the MAP rather than over a HUD panel? Fed by the map
-- frame's own MouseMoved / MouseLeave, which the HUD panels already mask. The
-- edge scroll reads it so that reaching for the action rail -- which lives ON
-- the right edge of the screen -- does not scroll the map east.
local pointerOverMap = false
-- Set whenever the camera moves under a pointer that did not move: the tile
-- under the cursor changed without the cursor changing, and the hover card and
-- the highlight have to catch up or they describe where you used to be.
local hoverDirty = false

-- Forward declaration. `flashTarget` is defined down with the rest of the
-- click feedback, but the "denied" message handler ABOVE it needs to call it,
-- and a `local function` is not in scope before its own definition -- so the
-- call site saw nil and every refused click threw instead of explaining
-- itself. Assigned below, not redeclared (hence `function`, not
-- `local function`, at the definition).
local flashTarget: (number, Color3) -> ()

hud:setRatio(attackRatio, 0)

local TERRAIN_NAME = { [0] = "ocean", "plains", "highland", "mountain", "impassable" }

local function updateViewport()
	local size = viewport.AbsoluteSize
	hud:layout(size.X, size.Y)
	camera:setViewport(size.X, size.Y)
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
	Net.unpackDelta(buf, function(tile, owner)
		renderer:setOwner(tile, owner)
	end)
end

StateRE.OnClientEvent:Connect(function(kind, payload, extra)
	if kind == "init" then
		roundId = payload.round
		myId = payload.yourId
		playableLand = payload.playableLand
		phase = payload.phase
		phaseRemaining = payload.phaseRemaining or 0
		hasSpawned = false
		winnerName = nil
		elapsed = 0
		myTroops, myTroopsShown, myTiles, myTilesShown = 0, 0, 0, 0
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
		for _, e in payload.roster or {} do
			rosterById[e.i] = e.n
			rosterUserId[e.i] = e.u
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
		hud:setTeamBar(nil, playableLand, myTeam)
		hud:setFronts({}, {})
		hud:setHover(nil)

		local lobby = string.format("ROUND %d - %s", roundId, modeName)
		if myTeam then
			lobby = lobby .. " - " .. Palette.teamName(myTeam)
		end
		hud:setLobbyCode(lobby)
		hud:setIdentity(player.DisplayName, Palette.playerColor3(myId, myId))
		hud:setTarget("PLAYER")
		myGold, myGoldShown = 0, 0
		myCities, myPorts, myCityLevels = 0, 0, 0
		myFactories = 0
		myCityCost = Config.CITY_COST_BASE
		myPortCost = Config.PORT_COST_BASE
		myFactoryCost = Config.PORT_COST_BASE
		buildMode = false
		buildKind = 1
		attackRatio = Config.DEFAULT_ATTACK_RATIO
		hud:setGold(0, myCityCost, 0)
		hud:setGain(0)

		nationLabels:clear()
		structures:clear()
		structures:setLocalId(myId)
		missiles:clear()
		missiles:setLocalId(myId)
		renderer = Renderer.new(payload.mapId or "us", payload.seed, mapImage)
		renderer:setLocalId(myId)
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
		updateViewport()
		camera:fit()
		camera:apply(mapImage)

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

	elseif kind == "roster" then
		for _, e in payload do
			rosterById[e.i] = e.n
			rosterUserId[e.i] = e.u
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
			-- A human who leaves is handed straight to the AI mid-round, so an
			-- id can turn grey without the round changing.
			-- Compare NORMALISED booleans. `entry.isBot` arriving as nil against
			-- a stored false would differ on every broadcast, and each difference
			-- costs a full-map repaint five times a second.
			local nowBot = entry.isBot == true
			if nowBot ~= (botById[entry.id] == true) then
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
				if entry.tiles > 0 then
					hasSpawned = true
				end
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
				structures:set(c.tile, c.ownerId, c.level, c.kind or 1)
			end
		end

	elseif kind == "rails" then
		if extra then
			structures:setAllRails(payload)
		else
			-- A rail event with no points is a line that was cut.
			for _, r in payload do
				structures:setRail(r.a, r.b, r.pts)
			end
		end

	elseif kind == "vehicles" then
		-- Ships and trains, on their own slower clock. Positions are targets,
		-- not coordinates: the markers walk toward them a frame at a time.
		structures:setVehicles(Net.unpackVehicles(payload))

	elseif kind == "missiles" then
		-- Launches, detonations, interceptions. Sent ONCE each -- see the
		-- Missiles header -- so this is the whole nuclear channel: everything
		-- between a launch and its flash is drawn from the same curve the
		-- server flies the unit along, and the crater is expanded locally from
		-- the seed in the blast event. `extra` is the server's tick, which is
		-- the clock that replay is against.
		missiles:onEvents(payload, extra)

	elseif kind == "armies" then
		if renderer then
			nationLabels:setArmies(Net.unpackArmies(payload), myId)
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
		myFactories = payload.factories or myFactories
		myCities = payload.cities or 0
		myPorts = payload.ports or 0
		myCityLevels = payload.levels or 0
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

	elseif kind == "phase" then
		phase = payload.phase
		phaseRemaining = payload.remaining or 0
		playableLand = payload.playableLand or playableLand
		hud:setTeamBar(payload.teams, playableLand, myTeam)

	elseif kind == "spawned" then
		hasSpawned = true
		camera.zoom = 4.5
		camera:centerOnTile(payload.tile)
		camera:apply(mapImage)
		-- The whole map just moved under a pointer that did not: whatever the
		-- hover card is describing, it is not what is under the cursor now.
		hoverDirty = true

	elseif kind == "denied" then
		-- ping: denied. Overwrites the optimistic acknowledgement with a red
		-- ring where the click landed, so a refusal is not only a sentence.
		if lastClickTile then
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
		elseif payload.reason == "water" then
			msg = "That is open water"
		elseif payload.reason == "own" then
			msg = "That is your own land"
		elseif payload.reason == "toomanyfronts" then
			msg = "Too many fronts - press X to pull one back"
		-- Nobody may be attacked for the first few seconds of the round. Open
		-- land is never immune, so this only ever fires on a tap at a NATION,
		-- and saying so is the difference between "the game is protecting a
		-- new empire" and "my tap did not register".
		-- Naval refusals. Each one is a different fix for the player, so
		-- collapsing them into "you can't attack there" would be useless.
		elseif payload.reason == "nosearoute" then
			msg = "No sea route to " .. name
		elseif payload.reason == "nobeach" then
			msg = name .. " has no coast to land on there"
		elseif payload.reason == "nocoast" then
			msg = "You have no coastline to sail from"
		elseif payload.reason == "toomanyboats" then
			msg = "All your transport boats are at sea"
		elseif payload.reason == "busy" then
			msg = "Too many crossings at once - try again"
		elseif payload.reason == "immunity" then
			msg = name .. " is still under spawn protection"
		-- Build refusals. Every rule that can stop a city gets its own
		-- sentence: "too close to another city" and "not enough gold" are the
		-- same silence otherwise, and the player has no way to tell which one
		-- they hit.
		elseif payload.reason == "gold" then
			-- The reply carries WHAT was refused, so the sentence names the
			-- thing that was pressed instead of always naming the city.
			if payload.kind == KIND_ATOM then
				msg = "Not enough gold - a nuke costs "
					.. Numbers.format(Config.ATOM_BOMB_COST or 750000)
			else
				msg = "Not enough gold - a "
					.. string.lower(KIND_NAME[payload.kind or 1] or "city")
					.. " costs " .. Numbers.format(payload.cost or myCityCost)
			end
		-- Launch refusals. "noland" is the silo-free launch site failing, which
		-- can only happen to an empire that holds nothing at all.
		elseif payload.reason == "noland" then
			msg = "You hold no ground to launch from"
		elseif payload.reason == "nosilo" then
			msg = "No missile silo is ready"
		elseif payload.reason == "friendly" then
			msg = "That is your own side"
		elseif payload.reason == "crowded" then
			msg = "Too close to another building - keep them "
				.. Config.STRUCTURE_MIN_DIST .. " tiles apart"
		elseif payload.reason == "land" then
			msg = "Buildings go on your own land"
		elseif payload.reason == "terrain" then
			msg = "Nothing can be built there"
		elseif payload.reason == "maxlevel" then
			msg = "That one is already at maximum level"
		elseif payload.reason == "coast" then
			msg = "A port needs your own coastline - none within "
				.. Config.PORT_SPAWN_RADIUS .. " tiles"
		end
		if msg then
			alertText = msg
			alertUntil = os.clock() + 2.5
		end

	elseif kind == "built" then
		-- Accepted. The gold figure in the reply is authoritative and lands
		-- before the next summary, so the treasury drops on the same frame the
		-- click did rather than a fifth of a second later.
		myGold = payload.gold or myGold
		local what = KIND_NAME[payload.kind or 1] or "CITY"
		if payload.kind == KIND_PORT then
			myPortCost = payload.cost or myPortCost
			-- One ladder, two buildings: buying a port repriced the factory too.
			myFactoryCost = myPortCost
		elseif payload.kind == KIND_FACTORY then
			myFactoryCost = payload.cost or myFactoryCost
			myPortCost = myFactoryCost
		else
			myCityCost = payload.cost or myCityCost
		end
		alertText = (payload.reason == "upgrade" and (what .. " upgraded"))
			or (what .. " under construction")
		alertUntil = os.clock() + 2
		-- A port SNAPS to the nearest coast you own, so the ring goes where the
		-- building actually landed rather than where the click did -- otherwise
		-- the one case where the two differ is the one case with no feedback.
		if payload.tile then
			lastClickTile = payload.tile
			ping(payload.tile, GOLD)
		end
		-- Stays armed: the natural thing after placing one building is to place
		-- the next, and the treasury readout already says whether that is
		-- possible.

	elseif kind == "win" then
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
local GOLD = Color3.fromRGB(232, 196, 110)

local PING_LIFE = 0.45
local FLASH_LIFE = 0.45
local FLASH_STRENGTH = 0.55
local FLASH_STEP = 0.06

local pings: { any } = {}
local flashId, flashColor = 0, Color3.new(1, 1, 1)
local flashUntil, flashNext = 0, 0
local lastClickTile: number? = nil

local function ping(tile: number, color: Color3)
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

-- (sx, sy) arrive in VIEWPORT space -- see pointer().
local function sendClick(sx: number, sy: number)
	if not renderer then
		return
	end
	local tile = camera:screenToTile(sx, sy)
	if not tile then
		return
	end

	if nukeMode then
		-- A nuke takes the click whole and then DISARMS ITSELF. Every other
		-- armed mode here stays on, because placing two houses in a row is the
		-- normal thing to do; spending 750,000 gold twice by accident is not.
		if phase == "playing" and hasSpawned then
			IntentRE:FireServer({ t = "nuke", tile = tile, kind = KIND_ATOM })
			-- Acknowledge the tap where it landed. The warhead takes seconds to
			-- arrive and the crater is the only other feedback this control
			-- has, so without the ring it reads as a dead button.
			lastClickTile = tile
			ping(tile, Color3.fromRGB(255, 176, 96))
			alertText = "Missile away"
			alertUntil = os.clock() + 2
		end
		nukeMode = false
		return
	end

	if buildMode then
		-- Build mode takes the click whole. Falling through to an attack when
		-- the tile turns out to be illegal would launch a war off a click that
		-- was meant to place a building, which is the worst possible misfire.
		if phase == "playing" and hasSpawned then
			IntentRE:FireServer({ t = "build", tile = tile, kind = buildKind })
			-- No optimistic ping here, unlike an attack: a port moves to the
			-- coast and a refusal is common, so the ring waits for the server
			-- to say WHERE it went. The round trip is 100ms.
		end
		return
	end

	if phase == "spawn" and not hasSpawned then
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
			return
		end
		IntentRE:FireServer({ t = "attack", tile = tile, ratio = attackRatio })
		-- ping: attack sent. Fired before the server answers -- the round trip
		-- is 100ms and the acknowledgement has to be immediate.
		lastClickTile = tile
		ping(tile, Palette.playerColor3(myId, myId))
		if o ~= 0 then
			flashTarget(o, Color3.fromRGB(255, 255, 255))
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
-- match: with the pointer parked on the action rail (which sits ON the right
-- edge of the screen) the edge push ran the map the full 553px to its clamp,
-- i.e. reaching for the build button scrolled the map out from under it.
--
-- The panels are the ScreenGui's own children other than the viewport, so the
-- test is a handful of rect compares. The list is CACHED because
-- `GetChildren` allocates and this runs every frame; it is rebuilt whenever
-- the ScreenGui gains or loses a child, which happens at startup and never
-- again. The HOVER CARD IS EXCLUDED DELIBERATELY: it is parented here too and
-- it follows the cursor, so counting it would let the card the pointer just
-- summoned be the reason the map stops moving.
local hudPanels: { GuiObject } = {}
local function refreshHudPanels()
	table.clear(hudPanels)
	for _, d in screen:GetChildren() do
		if d ~= viewport and d.Name ~= "Hover" and d:IsA("GuiObject") then
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
		if lastHoverOwner ~= 0 and renderer then
			renderer:setHighlight(0)
			lastHoverOwner = 0
		end
		return
	end
	if not renderer then
		hud:setHover(nil)
		return
	end

	local tile = camera:screenToTile(x, y)
	if not tile then
		hud:setHover(nil)
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

	local tType = TileMap.typeByte(buffer.readu8(renderer.terrain, tile))
	local terrainLabel = TERRAIN_NAME[tType] or "?"

	if o == 0 then
		local claimable = tType ~= 0 and tType ~= 4
		hud:setHover({
			name = claimable and "Open land" or "Sea",
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
	if renderer and lastHoverOwner ~= 0 then
		renderer:setHighlight(0)
		lastHoverOwner = 0
	end
end)

mapImage.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
	then
		dragging = true
		pressIsTouch = input.UserInputType == Enum.UserInputType.Touch
		pressPos = Vector2.new(input.Position.X, input.Position.Y)
		lastPos = pressPos
	end
end)

mapImage.InputChanged:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		-- The zoom anchor is a pointer position too, so it needs the same
		-- conversion or the map creeps while zooming under the cursor.
		local mx, my = pointer()
		camera:zoomAt(input.Position.Z > 0 and 1.18 or 1 / 1.18, mx, my)
		camera:apply(mapImage)
		updateHover(mx, my)
	end
end)

UserInputService.InputChanged:Connect(function(input)
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
		if (endPos - pressPos).Magnitude <= slop then
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

-- ONE ARMED THING AT A TIME. The rail's three buttons and the C / P / F / N
-- keys both route through `arm`, so a key and a button can never leave the
-- HUD lit for one mode while the next click runs a different one.
local function arm(id: string?)
	if id ~= nil and (phase ~= "playing" or not hasSpawned) then
		id = nil
	end
	if id == "nuke" then
		buildMode, nukeMode = false, true
	elseif id ~= nil then
		nukeMode, buildMode = false, true
		buildKind = (id == "port" and KIND_PORT) or (id == "factory" and KIND_FACTORY) or KIND_CITY
	else
		buildMode, nukeMode = false, false
	end
end

-- Derived, never stored: the lit button is read back out of the same two
-- variables the click handler branches on, so the light cannot lie.
local function armedId(): string?
	if nukeMode then
		return "nuke"
	elseif buildMode then
		return (buildKind == KIND_PORT and "port") or (buildKind == KIND_FACTORY and "factory") or "city"
	end
	return nil
end

local KEY_ACTIONS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.C] = "city",
	[Enum.KeyCode.P] = "port",
	[Enum.KeyCode.F] = "factory",
	[Enum.KeyCode.N] = "nuke",
}

-- One table, refilled in place. It is read once a frame and a fresh one each
-- time is garbage for nothing.
local ACTION_COSTS = { city = 0, port = 0, nuke = Config.ATOM_BOMB_COST or 750000 }

-- Pressing the button that is already armed disarms it. The button is the
-- only VISIBLE way out of the mode, and one that cannot be pressed off is a
-- trap on a touchscreen, where there is no ESC key to fall back on.
hud:bindActions(function(id: string)
	arm(armedId() ~= id and id or nil)
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.X then
		IntentRE:FireServer({ t = "cancel", tile = 0 })
		return
	end
	if key == Enum.KeyCode.B then
		-- Kept from before the rail existed: B arms whichever building was
		-- armed last, and C / P / F still swap between them.
		if buildMode then
			arm(nil)
		else
			arm((buildKind == KIND_PORT and "port")
				or (buildKind == KIND_FACTORY and "factory")
				or "city")
		end
		return
	end
	if key == Enum.KeyCode.Escape and armedId() ~= nil then
		arm(nil)
		return
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
	local keyed = dx ~= 0 or dy ~= 0

	-- Keys WIN over the edge: a player holding D with the cursor parked on the
	-- left edge means to go east, and summing the two would cancel out.
	if EDGE_PAN and not keyed and pointerOverMap and windowFocused
		and not dragging and UserInputService.MouseEnabled
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
	return g * Config.TICK_RATE
end

-- Was the camera shaking LAST frame? Only there so the frame the kick reaches
-- zero still runs one apply and puts the map back exactly where it was.
local shaking = false

RunService.RenderStepped:Connect(function(dt)
	if renderer then
		renderer:flush()
	end

	elapsed += dt

	-- WASD and the edge push. Driven from the frame loop rather than from an
	-- input event because holding a key is a STATE, not an event: the camera
	-- has to move on every frame the key is down, not once when it goes down.
	driveCamera(dt)
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

	-- A detonation kicks the view. The offset goes through the CAMERA rather
	-- than onto the container, so that where the map is drawn and where a click
	-- lands stay one answer while it is shaking -- see Camera2D.apply. Two
	-- frequencies with no common period, so it reads as a rumble and not as a
	-- wobble, and one extra apply a frame for half a second costs nothing next
	-- to the fireball it is under.
	local kick = missiles.shake
	if kick > 0 or shaking then
		shaking = kick > 0
		camera.shakeX = kick * math.sin(elapsed * 61.0)
		camera.shakeY = kick * math.sin(elapsed * 43.7)
		camera:apply(mapImage)
	end

	-- Build mode is not a state you can be in by accident: it ends the moment
	-- the round does or you stop being a live empire.
	if (buildMode or nukeMode) and (phase ~= "playing" or not hasSpawned) then
		buildMode, nukeMode = false, false
	end
	-- The rail exists only while you are a live empire in a live round: three
	-- buttons that cannot be pressed are three questions about why not.
	hud:showActions(phase == "playing" and hasSpawned)
	ACTION_COSTS.city = myCityCost
	ACTION_COSTS.port = myPortCost
	hud:setActions(armedId(), ACTION_COSTS, myGold)

	-- One smoother, from the shared module, for all four: the bar, its
	-- ceiling, the tile count and the gain readout must not disagree about
	-- how fast a number is allowed to move.
	myTroopsShown = Numbers.approach(myTroopsShown, myTroops, dt, 14)
	myMaxShown = Numbers.approach(myMaxShown, myMaxTroops, dt, 9)
	myTilesShown = Numbers.approach(myTilesShown, myTiles, dt, 9)
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
	hud:setArmy(
		myTroopsShown,
		myMaxShown,
		myTilesShown,
		playableLand,
		incomePerSec(myTroopsShown, myMaxShown)
	)
	hud:setTimer(elapsed, phase == "playing" and "WAR" or phase)
	-- Keep the committed-troop figure live as the army grows.
	hud:setRatio(attackRatio, myTroopsShown)

	-- Build mode outranks the alert line: it is a state the player is IN, not
	-- an event that happened, and leaving it unsignposted turns the next click
	-- into a surprise.
	if nukeMode then
		local cost = Config.ATOM_BOMB_COST or 750000
		hud:setBanner(
			myGold >= cost
					and ("NUCLEAR STRIKE  -  click a target  -  "
						.. Numbers.format(cost) .. " gold  -  ESC")
				or ("NUCLEAR STRIKE  -  need "
					.. Numbers.format(cost - myGold) .. " more gold  -  ESC"),
			myGold >= cost and Color3.fromRGB(255, 176, 96) or Color3.fromRGB(255, 132, 118)
		)
	elseif buildMode then
		local cost = (buildKind == KIND_PORT and myPortCost)
			or (buildKind == KIND_FACTORY and myFactoryCost)
			or myCityCost
		local where = buildKind == KIND_PORT and "click your coast" or "click your own land"
		hud:setBanner(
			myGold >= cost
				and ("BUILD " .. KIND_NAME[buildKind] .. "  -  " .. where .. "  -  "
					.. Numbers.format(cost) .. " gold  -  C city / P port / F factory  -  ESC")
				or ("BUILD " .. KIND_NAME[buildKind] .. "  -  need "
					.. Numbers.format(cost - myGold)
					.. " more gold  -  C city / P port / F factory  -  ESC"),
			myGold >= cost and GOLD or Color3.fromRGB(255, 132, 118)
		)
	elseif phase == "playing" and hasSpawned and alertText and os.clock() < alertUntil then
		hud:setBanner(alertText, Color3.fromRGB(255, 132, 118))
	elseif phase == "spawn" then
		phaseRemaining = math.max(0, phaseRemaining - dt)
		if hasSpawned then
			hud:setBanner(
				string.format(
					"%sHolding. Battle begins in %ds",
					myTeam and (Palette.teamName(myTeam) .. " TEAM  -  ") or "",
					math.ceil(phaseRemaining)
				),
				myTeam and Palette.teamColor3(myTeam) or Color3.fromRGB(150, 220, 170)
			)
		else
			hud:setBanner(
				string.format("Click anywhere on land to claim your start  ·  %ds", math.ceil(phaseRemaining)),
				Color3.fromRGB(255, 226, 140)
			)
		end
	elseif phase == "ended" and winnerName then
		hud:setBanner(winnerName .. " has taken the map", Color3.fromRGB(255, 226, 140))
	elseif phase == "playing" and not hasSpawned then
		hud:setBanner("Spectating until the next round", Color3.fromRGB(170, 180, 200))
	else
		hud:setBanner(nil)
	end
end)

-- Every handler above is connected now, so it is safe to ask for our own init
-- rather than hoping the round's broadcast waited for us. See the "hello"
-- branch in ConquestServer.
IntentRE:FireServer({ t = "hello", tile = 0 })

print("[Conquest] client ready")
