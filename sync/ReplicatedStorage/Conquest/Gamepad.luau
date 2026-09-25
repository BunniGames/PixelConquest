--!strict
-- Conquest :: Gamepad  (client only)
--
-- WHAT A CONTROLLER IS DOING, IN ONE PLACE. This is a pointer game -- every
-- decision in it is a tile under a cursor -- and a console has no pointer.
-- The cursor a pad gets is Roblox's own VIRTUAL CURSOR (GamepadService): the
-- engine emulates a mouse from the left stick and RT -- NOT A, measured on a
-- real pad 2026-09-22 -- so the map's hover,
-- click and drag handlers and every GuiButton on the lobby page, the shop and
-- the HUD fire exactly as they do for a mouse, and none of them had to learn
-- a second way to be pressed.
--
-- What the engine does NOT hand a pad is here: the sticks as dead-zoned,
-- curved vectors, the triggers as a scalar, whether the last thing the player
-- touched was a pad at all (which is what decides whether the rail prints
-- C / P / N or nothing at all), and the button captions in the pad's own family
-- (an Xbox pad says RB where a PlayStation one says R1).
--
-- THE CURSOR'S LIFECYCLE IS DELIBERATELY ONE-SIDED. It is switched ON when a
-- pad becomes the last input, and at once on a console, where there is no
-- other pointer to wait for. It is never switched OFF here: the engine hides
-- it itself the moment a real mouse or a finger is used and brings it back
-- with the next pad input. Disabling it ourselves on every non-pad input is
-- the one thing that could fight that, because the cursor's own emulated
-- mouse movement is not something this module can tell from a real mouse.
--
-- EVERY GamepadService CALL IS UNDER pcall. The property and both methods
-- are years old, but a client that lacks them must degrade to "no virtual
-- cursor", never to a client entry that throws before the map is built.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Gamepad = {}

-- Below this a stick at rest still reports a few hundredths, and a camera
-- that creeps on its own reads as broken. Radial, so a diagonal rest is as
-- dead as an axis one.
Gamepad.DEADZONE = 0.2
-- A trigger's own floor: they rest at exactly 0, so this only has to swallow
-- a finger resting on one.
Gamepad.TRIGGER_DEADZONE = 0.08
-- Response curve past the dead zone. Above 1 gives the first half of the
-- travel to fine control -- a full-speed pan a millimetre off centre is how a
-- stick overshoots every target.
Gamepad.CURVE = 1.7

local gamepadService: any = nil
pcall(function()
	gamepadService = game:GetService("GamepadService")
end)

-- The pad the player last touched. Buttons and sticks are read off THIS one,
-- so a second controller left on the sofa cannot dead-zone the first.
local lastPad: Enum.UserInputType = Enum.UserInputType.Gamepad1
-- The InputObjects of `lastPad`, keyed by KeyCode, refreshed at most once a
-- frame: GetGamepadState allocates a table of ~20 objects per call, and the
-- three stick reads a frame would otherwise be three of them.
local state: { [Enum.KeyCode]: InputObject } = {}
local statePad: Enum.UserInputType? = nil
local stateAt = -1

function Gamepad.isPadType(t: Enum.UserInputType): boolean
	return string.sub(t.Name, 1, 7) == "Gamepad"
end

local function refresh()
	local now = os.clock()
	if statePad == lastPad and now - stateAt < 1 / 240 then
		return
	end
	stateAt = now
	statePad = lastPad
	table.clear(state)
	if not UserInputService.GamepadEnabled then
		return
	end
	local ok, objs = pcall(UserInputService.GetGamepadState, UserInputService, lastPad)
	if ok and type(objs) == "table" then
		for _, o in objs do
			state[o.KeyCode] = o
		end
	end
end

-- One stick as a vector: radially dead-zoned, rescaled so the zone's edge is
-- 0, and curved. Up on the stick is +Y, the way the engine reports it.
function Gamepad.stick(key: Enum.KeyCode): (number, number)
	refresh()
	local o = state[key]
	if o == nil then
		return 0, 0
	end
	local p = o.Position
	local m = math.sqrt(p.X * p.X + p.Y * p.Y)
	local dz = Gamepad.DEADZONE
	if m <= dz then
		return 0, 0
	end
	local k = math.min(1, (m - dz) / (1 - dz)) ^ Gamepad.CURVE
	return p.X / m * k, p.Y / m * k
end

-- One trigger as 0..1. The engine keeps a trigger's pull in Position.Z.
function Gamepad.trigger(key: Enum.KeyCode): number
	refresh()
	local o = state[key]
	if o == nil then
		return 0
	end
	local z = o.Position.Z
	return if z > Gamepad.TRIGGER_DEADZONE then math.min(1, z) else 0
end

-- One BUTTON as a boolean, off the same pad the sticks are read from. The
-- shoulders are DIGITAL -- no pull to report at all -- so `trigger` above
-- reads a held LB as 0 however hard it is squeezed, and the zoom that moved
-- onto them (ConquestClient's gp.step) asks this instead.
function Gamepad.down(key: Enum.KeyCode): boolean
	local ok, held = pcall(UserInputService.IsGamepadButtonDown, UserInputService, lastPad, key)
	return ok and held == true
end

-- Is the virtual cursor up right now.
function Gamepad.cursorOn(): boolean
	return gamepadService ~= nil and gamepadService.GamepadCursorEnabled == true
end

-- The last thing the player touched was a pad -- or the cursor is up, which
-- is the engine making the same claim.
function Gamepad.active(): boolean
	return Gamepad.cursorOn() or Gamepad.isPadType(UserInputService:GetLastInputType())
end

-- Turn the cursor on, parked over `anchor` when one is given (the engine
-- warns and uses its default spot for an anchor that is not on screen).
-- A no-op when it is already up or there is no pad to drive it.
function Gamepad.enableCursor(anchor: GuiObject?)
	if gamepadService == nil or gamepadService.GamepadCursorEnabled then
		return
	end
	if not UserInputService.GamepadEnabled then
		return
	end
	pcall(function()
		if anchor ~= nil and anchor.Visible then
			gamepadService:EnableGamepadCursor(anchor)
		else
			gamepadService:EnableGamepadCursor(nil)
		end
	end)
end

-- ============================================================== scrolling ==
-- A LIST A PAD CANNOT SCROLL IS A LIST A PAD CANNOT BUY FROM. The virtual
-- cursor emulates a mouse's MOVEMENT and its BUTTON. It does not emulate a
-- WHEEL -- and the engine's other way of scrolling a ScrollingFrame with a
-- pad, walking GuiService.SelectedObject into an off-screen child, is switched
-- off deliberately in watch() below. Between the two, a console player had
-- every scrolling list in this game pinned at its first row, with what was
-- under it unreachable rather than merely awkward. MEASURED LIVE, 2026-09-17:
-- the in-match store is a 592px canvas in a 401px window -- and the 191px
-- below the fold is exactly where the two bundle strips sort (LayoutOrder 55
-- and 60, after the power-up row), so the packs could not be BOUGHT on a pad;
-- the flag catalogue is 77 cards over 13 rows with three in the window, so 59
-- of the 77 could not be reached.
--
-- THE RIGHT STICK SCROLLS WHATEVER THE CURSOR IS STANDING ON. Nothing
-- registers itself here: the frame is whatever the PlayerGui reports under the
-- cursor, so a ScrollingFrame added to this game tomorrow scrolls on a pad
-- without anybody having to remember this file exists.
-- GetGuiObjectsAtPosition returns what is rendered at a point, topmost first,
-- so the map behind an open panel is never the first hit.
--
-- IT TAKES THE STICK OFF THE MAP WHILE IT DOES IT. The right stick pans the
-- camera in a match, so `scrolling()` is what ConquestClient's driveCamera
-- asks before adding its own pan: standing on an open panel is exactly when
-- sliding the map behind it is not what the push meant. A TIMESTAMP rather
-- than a flag, so the answer cannot depend on which RenderStepped connection
-- the engine happens to call first.

-- Canvas pixels a second at a full push. A shade under a wheel's pace, and
-- enough to cross the flag catalogue in about a second.
Gamepad.SCROLL_RATE = 1100
-- How long after a scroll the stick still counts as spent. Two frames at 60:
-- long enough to bridge any ordering against the camera's own loop, short
-- enough that letting go of a panel and panning reads as immediate.
local SCROLL_HOLD = 0.12
local scrolledAt = -1e9

-- Is the right stick currently being spent on a panel rather than on the map.
function Gamepad.scrolling(): boolean
	return os.clock() - scrolledAt < SCROLL_HOLD
end

-- RENDERED, not merely present. A closed panel in this game is hidden through
-- an ANCESTOR -- the shop's own frame -- and a test that trusted the
-- ScrollingFrame's own Visible would let a shut shop keep the stick away from
-- the map for as long as the cursor sat where that shop would have been.
local function shown(g: Instance): boolean
	local node: Instance? = g
	while node ~= nil do
		if node:IsA("GuiObject") then
			if not node.Visible then
				return false
			end
		elseif node:IsA("LayerCollector") then
			return (node :: any).Enabled == true
		else
			return false
		end
		node = node.Parent
	end
	return false
end

local function scrollStep(dt: number)
	if not Gamepad.cursorOn() then
		return
	end
	local sx, sy = Gamepad.stick(Enum.KeyCode.Thumbstick2)
	if sx == 0 and sy == 0 then
		return
	end
	local player = Players.LocalPlayer
	local pg = player and player:FindFirstChildOfClass("PlayerGui")
	if pg == nil then
		return
	end
	-- GUI SPACE, which is what AbsolutePosition and this method speak; the
	-- pointer apis answer in WINDOW space, one top bar lower. The measurement
	-- that settles the two is in ConquestClient's header.
	local at = UserInputService:GetMouseLocation() - GuiService:GetGuiInset()
	local ok, hits = pcall(function()
		return (pg :: any):GetGuiObjectsAtPosition(at.X, at.Y)
	end)
	if not ok or type(hits) ~= "table" then
		return
	end
	for _, g in hits do
		if g:IsA("ScrollingFrame") and g.ScrollingEnabled and shown(g) then
			local span = g.AbsoluteCanvasSize - g.AbsoluteWindowSize
			if span.X > 1 or span.Y > 1 then
				-- STAMPED WHETHER OR NOT THE CANVAS MOVED. A list already at
				-- its last row is still what the stick is pushing against,
				-- and a stamp that skipped that case would slide the map out
				-- from behind an open shop at exactly the moment a player
				-- leans harder on it.
				scrolledAt = os.clock()
				local p = g.CanvasPosition
				local rate = Gamepad.SCROLL_RATE * dt
				-- Up on the stick is +Y and scrolling UP is a SMALLER canvas
				-- offset, so the Y push is subtracted and the X one is not.
				g.CanvasPosition = Vector2.new(
					math.clamp(p.X + sx * rate, 0, math.max(0, span.X)),
					math.clamp(p.Y - sy * rate, 0, math.max(0, span.Y))
				)
				return
			end
		end
	end
end

local scrollBound = false
local function beginScroll()
	if scrollBound then
		return
	end
	scrollBound = true
	RunService.RenderStepped:Connect(scrollStep)
end

local watching = false
local anchorObj: GuiObject? = nil

-- Keep the cursor up for a pad, from now on. Called once by each client entry
-- (the lobby page, the match); a second call only moves the anchor.
function Gamepad.watch(anchor: GuiObject?)
	anchorObj = anchor
	if watching then
		return
	end
	watching = true
	beginScroll()
	-- The Select / View button must not drop the player into Roblox's d-pad
	-- selection mode: nothing in this game is wired for NextSelection, so it
	-- would pick a button at random and take the left stick away from the
	-- cursor to move the selection box around.
	pcall(function()
		GuiService.AutoSelectGuiEnabled = false
	end)
	UserInputService.LastInputTypeChanged:Connect(function(t)
		if Gamepad.isPadType(t) then
			lastPad = t
			Gamepad.enableCursor(anchorObj)
		end
	end)
	UserInputService.GamepadConnected:Connect(function(pad)
		-- A pad plugged into a console mid-session is the only pointer it
		-- has. On a PC it waits to be touched, like any other device.
		lastPad = pad
		if GuiService:IsTenFootInterface() then
			Gamepad.enableCursor(anchorObj)
		end
	end)
	if GuiService:IsTenFootInterface() or Gamepad.active() then
		Gamepad.enableCursor(anchorObj)
	end
end

-- The captions a pad's buttons go by, in the pad's own family. The probe is
-- the engine's own name for X: an Xbox-style pad answers "ButtonX", a
-- PlayStation one "ButtonSquare".
local XBOX: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.ButtonA] = "A",
	[Enum.KeyCode.ButtonB] = "B",
	[Enum.KeyCode.ButtonX] = "X",
	[Enum.KeyCode.ButtonY] = "Y",
	[Enum.KeyCode.ButtonL1] = "LB",
	[Enum.KeyCode.ButtonR1] = "RB",
	[Enum.KeyCode.ButtonL2] = "LT",
	[Enum.KeyCode.ButtonR2] = "RT",
	[Enum.KeyCode.ButtonR3] = "RS",
}
local PLAYSTATION: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.ButtonA] = "✕",
	[Enum.KeyCode.ButtonB] = "○",
	[Enum.KeyCode.ButtonX] = "□",
	[Enum.KeyCode.ButtonY] = "△",
	[Enum.KeyCode.ButtonL1] = "L1",
	[Enum.KeyCode.ButtonR1] = "R1",
	[Enum.KeyCode.ButtonL2] = "L2",
	[Enum.KeyCode.ButtonR2] = "R2",
	[Enum.KeyCode.ButtonR3] = "R3",
}

function Gamepad.label(key: Enum.KeyCode): string
	local ps = false
	pcall(function()
		ps = UserInputService:GetStringForKeyCode(Enum.KeyCode.ButtonX) == "ButtonSquare"
	end)
	return (if ps then PLAYSTATION else XBOX)[key] or key.Name
end

return Gamepad
