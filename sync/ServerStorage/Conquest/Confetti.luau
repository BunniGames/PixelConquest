--!strict
-- Conquest :: Confetti  (client)
--
-- THE WINNER'S CONFETTI (owner, 2026-10-02: "add a confetti effect on the
-- winner clients screen"). Two cannons fire from the bottom corners, then a
-- short rain falls from the top edge. Plain UI Frames on a layer the size of
-- the screen, moved by hand every frame: no particle emitter exists for 2D UI,
-- and a few hundred Frames is well inside what a phone draws without noticing.
--
-- AUTHORED AT 720 TALL, like the HUD. Every distance and speed below is in
-- reference pixels and scaled by the layer's real height, so a phone and a
-- 1440p monitor see the same arc rather than one of them a fountain.
--
-- NEVER IN THE WAY. Every piece is Active = false, so a click passes straight
-- through to whatever is under it -- the 3x MONEY button, the LOBBY button.
--
-- `burst` returns a stop function. The layer cleans itself up once the last
-- piece has landed; stop is for a round that ends before that.

local RunService = game:GetService("RunService")

local Confetti = {}

local COLORS = {
	Color3.fromRGB(255, 214, 92), -- gold, twice: it is the winner's colour
	Color3.fromRGB(255, 214, 92),
	Color3.fromRGB(255, 244, 196),
	Color3.fromRGB(111, 217, 138),
	Color3.fromRGB(92, 170, 255),
	Color3.fromRGB(255, 110, 140),
	Color3.fromRGB(190, 130, 255),
	Color3.fromRGB(255, 255, 255),
}

local REF_H = 720
-- Up fast and down slow is what reads as paper rather than as gravel: a hard
-- pull while it climbs, then a low terminal speed it flutters down at.
local GRAVITY = 1500
local CANNON_EACH = 70
local CANNON_SPEED_MIN, CANNON_SPEED_MAX = 1050, 1650
local RAIN_SECONDS, RAIN_PER_SECOND = 2.4, 55
local FALL_MIN, FALL_MAX = 120, 230
local LIFE = 7.5
local FADE = 0.6

type Piece = {
	gui: Frame,
	x: number,
	y: number,
	vx: number,
	vy: number,
	fall: number,
	rot: number,
	spin: number,
	flip: number,
	flipRate: number,
	sway: number,
	swayRate: number,
	phase: number,
	w: number,
	h: number,
	age: number,
}

function Confetti.burst(parent: Instance, zIndex: number?): () -> ()
	local z = zIndex or 40
	local layer = Instance.new("Frame")
	layer.Name = "Confetti"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.Active = false
	layer.ZIndex = z
	layer.Parent = parent

	-- MEASURED ON THE FIRST FRAME, NOT HERE. A Frame parented a moment ago has
	-- not been laid out yet and reads an AbsoluteSize of 0 -- the first version
	-- measured it here, scaled every piece by 0 and fired the whole burst from
	-- the top-left corner at a pixel wide (owner: "confetti isnt showing").
	-- Set by the loop once the layer has a real size; nothing spawns before.
	local W, H, k = 0, 0, 0
	local started = false

	local pieces: { Piece } = {}

	local function spawn(x: number, y: number, vx: number, vy: number)
		local round = math.random() < 0.25
		local w = (5 + math.random() * 5) * k
		local h = round and w or (9 + math.random() * 8) * k
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BackgroundColor3 = COLORS[math.random(#COLORS)]
		f.Size = UDim2.fromOffset(w, h)
		f.Position = UDim2.fromOffset(x, y)
		f.Active = false
		f.ZIndex = z
		if round then
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(1, 0)
			c.Parent = f
		end
		f.Parent = layer
		table.insert(pieces, {
			gui = f,
			x = x,
			y = y,
			vx = vx,
			vy = vy,
			fall = (FALL_MIN + math.random() * (FALL_MAX - FALL_MIN)) * k,
			rot = math.random() * 360,
			spin = (math.random() * 2 - 1) * 420,
			flip = math.random() * math.pi * 2,
			flipRate = 4 + math.random() * 8,
			sway = (20 + math.random() * 40) * k,
			swayRate = 1.5 + math.random() * 2.5,
			phase = math.random() * math.pi * 2,
			w = w,
			h = h,
			age = 0,
		})
	end

	-- The cannons: up and inward from each bottom corner, fanned so the two
	-- plumes cross over the middle of the screen.
	local function fireCannons()
		for side = 0, 1 do
			local dir = side == 0 and 1 or -1
			local x0 = side == 0 and 0 or W
			for _ = 1, CANNON_EACH do
				local angle = math.rad(58 + math.random() * 26) -- from the horizontal
				local speed = (CANNON_SPEED_MIN + math.random() * (CANNON_SPEED_MAX - CANNON_SPEED_MIN)) * k
				spawn(x0, H + 10 * k, dir * math.cos(angle) * speed, -math.sin(angle) * speed)
			end
		end
	end

	local rainLeft = RAIN_SECONDS
	local rainDebt = 0
	local conn: RBXScriptConnection? = nil

	local function stop()
		if conn then
			conn:Disconnect()
			conn = nil
		end
		table.clear(pieces)
		layer:Destroy()
	end

	conn = RunService.RenderStepped:Connect(function(dt: number)
		dt = math.min(dt, 1 / 20)
		if not started then
			local size = layer.AbsoluteSize
			if size.X < 2 or size.Y < 2 then
				return -- not laid out yet; try again next frame
			end
			W, H, k = size.X, size.Y, size.Y / REF_H
			started = true
			fireCannons()
		end
		if rainLeft > 0 then
			rainLeft -= dt
			rainDebt += RAIN_PER_SECOND * dt
			while rainDebt >= 1 do
				rainDebt -= 1
				spawn(math.random() * W, -20 * k, (math.random() * 2 - 1) * 40 * k, 0)
			end
		end

		local drag = math.exp(-1.4 * dt)
		local i = 1
		while i <= #pieces do
			local p = pieces[i]
			p.age += dt
			p.vy = math.min(p.vy + GRAVITY * k * dt, p.fall)
			p.vx *= drag
			p.x += (p.vx + math.sin(p.age * p.swayRate + p.phase) * p.sway) * dt
			p.y += p.vy * dt
			p.rot += p.spin * dt
			if p.age >= LIFE or p.y > H + 30 * k then
				p.gui:Destroy()
				pieces[i] = pieces[#pieces]
				pieces[#pieces] = nil
			else
				local g = p.gui
				-- The flutter: the piece's width breathes through zero, which is a
				-- strip of paper turning over in the air.
				g.Size = UDim2.fromOffset(p.w * math.abs(math.cos(p.age * p.flipRate + p.flip)) + 1, p.h)
				g.Position = UDim2.fromOffset(p.x, p.y)
				g.Rotation = p.rot
				local left = LIFE - p.age
				if left < FADE then
					g.BackgroundTransparency = 1 - left / FADE
				end
				i += 1
			end
		end

		if rainLeft <= 0 and #pieces == 0 then
			stop()
		end
	end)

	return stop
end

return Confetti
