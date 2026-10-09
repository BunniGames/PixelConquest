--!strict
-- THE HALLOWEEN EVENT PASS SHEET (2026-10-09). Opened by the lobby's orange
-- HALLOWEEN EVENT PASS pill (LobbyUI.onEvent -> LobbyClient), built the way
-- PatternShop is: its own page over the lobby screen, borrowing the lobby
-- page's kit, knowing nothing about remotes. Every press goes out through a
-- callback LobbyClient assigns:
--   onClaim(tier, premium)   one reward; tier 0 = CLAIM ALL
--   onRobux(key)             a developer product (premium, tier skips)
--
-- TWO ROWS PER TIER: the FREE reward on top, the PREMIUM one under it, and the
-- premium slot carries the owner's ladder colour (EventPass.classOf). Claiming
-- is a press on a lit slot, or CLAIM ALL.
--
-- WHAT IS TRUE COMES FROM THE SERVER (setState): XP, the claimed set and
-- whether premium is unlocked. Nothing here guesses at any of it.
local AssetService = game:GetService("AssetService")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local Conquest = script.Parent
local EventPass = require(Conquest:WaitForChild("EventPass"))
local Patterns = require(Conquest:WaitForChild("Patterns"))
local Products = require(Conquest:WaitForChild("Products"))
local LobbyUI = require(Conquest:WaitForChild("LobbyUI"))
local Sfx = require(Conquest:WaitForChild("Sfx"))
local MoneyNote = require(Conquest:WaitForChild("MoneyNote"))
local Icons = require(Conquest:WaitForChild("Icons"))

local kit = LobbyUI.kit
local place, label, kitLabel, kitSet, setText = kit.place, kit.label, kit.kitLabel, kit.kitSet, kit.setText
local roundOff, pillButton, grower, tween = kit.roundOff, kit.pillButton, kit.grower, kit.tween
local REF_W, REF_H = kit.REF_W, kit.REF_H

local EventPassUI = {}
EventPassUI.__index = EventPassUI

-- ---------------------------------------------------------------- layout ---
local PW, PH = 1184, 648
local PX, PY = (REF_W - PW) / 2, (REF_H - PH) / 2

-- The track, with the row labels in a fixed column left of it.
local LABEL_X, LABEL_W = 24, 100
local TRACK_X, TRACK_Y = 132, 140
local TRACK_W, TRACK_H = PW - 24 - TRACK_X, 382
local CW, CH, CGAP = 128, 364, 12
local CANVAS_W = EventPass.COUNT * (CW + CGAP) + CGAP
-- Inside a card.
local FREE_Y, FREE_H = 32, 100
local PREM_Y, PREM_H = 140, 218
local SLOT_X, SLOT_W = 6, CW - 12

-- The bottom row.
local ROW_Y, ROW_H = 538, 58
local MSG_Y = 610

-- ---------------------------------------------------------------- colour ---
local ORANGE = Color3.fromRGB(255, 146, 48)
local ORANGE_DEEP = Color3.fromRGB(150, 62, 14)
local GREEN_FILL = Color3.fromRGB(28, 112, 62)
local RED = Color3.fromRGB(168, 40, 46)
local RED_LINE = Color3.fromRGB(232, 96, 96)
local SLOT_FILL = Color3.fromRGB(11, 15, 25)

-- THE OWNER'S LADDER, as colour: grey filler, blue mid, violet good, gold
-- great. Only the premium slot wears it; the free row is all filler.
local CLASS = {
	filler = { edge = kit.LINE, thick = 1.6, fill = SLOT_FILL },
	mid = { edge = Color3.fromRGB(92, 173, 245), thick = 2.2, fill = Color3.fromRGB(12, 22, 40) },
	good = { edge = Color3.fromRGB(196, 140, 255), thick = 2.6, fill = Color3.fromRGB(26, 16, 44) },
	great = { edge = kit.GOLD, thick = 3.2, fill = Color3.fromRGB(44, 34, 12) },
}

-- ---------------------------------------------------------------- motion ---
local OPEN_SHADE = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_PANEL = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local SHUT = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local CARD_IN = TweenInfo.new(0.26, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local BAR_FILL = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local LAND_FLASH = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LAND_PUNCH = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SHADE_ALPHA = 0.25
local PANEL_FROM = 0.965

-- --------------------------------------------------------------- sprites ---
-- Painted, not uploaded -- LobbyUI's gift and pumpkin are made the same way.
local PIX: { [string]: { number } } = {
	["k"] = { 20, 22, 28 },
	["R"] = { 230, 50, 60 },
	["W"] = { 255, 255, 255 },
	["Y"] = { 250, 204, 64 },
	["y"] = { 214, 160, 40 },
	["P"] = { 240, 140, 170 },
	["T"] = { 60, 60, 70 },
	["O"] = { 255, 146, 48 },
	["L"] = { 255, 226, 140 },
	["G"] = { 178, 186, 204 },
	["V"] = { 111, 217, 138 },
}
local HEART = {
	"................",
	"..kkkk....kkkk..",
	".kRRRRk..kRRRRk.",
	"kRRWRRRkkRRRRRRk",
	"kRWRRRRRRRRRRRRk",
	"kRRRRRRRRRRRRRRk",
	"kRRRRRRRRRRRRRRk",
	".kRRRRRRRRRRRRk.",
	"..kRRRRRRRRRRk..",
	"...kRRRRRRRRk...",
	"....kRRRRRRk....",
	".....kRRRRk.....",
	"......kRRk......",
	".......kk.......",
	"................",
	"................",
}
local PENCIL = {
	"................",
	"............k...",
	"...........kPk..",
	"..........kPPPk.",
	".........kYPPk..",
	"........kYYyk...",
	".......kYYyk....",
	"......kYYyk.....",
	".....kYYyk......",
	"....kYYyk.......",
	"...kYYyk........",
	"..kYYyk.........",
	".kTYyk..........",
	".TTkk...........",
	".kk.............",
	"................",
}
local FLAG = {
	"................",
	".kk.............",
	".kWkkkkkkkkk....",
	".kWkOOOOOOOOkk..",
	".kWkOOOOOOOOOOk.",
	".kWkOOLLOOOOOOk.",
	".kWkOLLLLOOOOOk.",
	".kWkOOLLOOOOOOk.",
	".kWkOOOOOOOOOOk.",
	".kWkkkkOOOOOOOk.",
	".kWk...kkkkkkk..",
	".kWk............",
	".kWk............",
	".kWk............",
	"kkkkk...........",
	"................",
}
local LOCK = {
	"................",
	".....kkkkkk.....",
	"....kGGGGGGk....",
	"...kGk....kGk...",
	"...kGk....kGk...",
	"...kGk....kGk...",
	"..kkkkkkkkkkkk..",
	"..kYYYYYYYYYYk..",
	"..kYYYYkkYYYYk..",
	"..kYYYYkkYYYYk..",
	"..kYYYYYkYYYYk..",
	"..kYYYYYYYYYYk..",
	"..kyyyyyyyyyyk..",
	"..kkkkkkkkkkkk..",
	"................",
	"................",
}

local CHECK = {
	"................",
	"................",
	"..............kk",
	".............kVk",
	"............kVVk",
	"...........kVVk.",
	"..kk......kVVk..",
	".kVVk....kVVk...",
	".kVVVk..kVVk....",
	"..kVVVkkVVk.....",
	"...kVVVVVk......",
	"....kVVVk.......",
	".....kVk........",
	"......k.........",
	"................",
	"................",
}

local spriteCache: { [any]: Content } = {}
local function spriteContent(art: { string }): Content
	local hit = spriteCache[art]
	if hit then
		return hit
	end
	local w, h = #art[1], #art
	local img = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	local buf = buffer.create(w * h * 4)
	for y = 1, h do
		for x = 1, w do
			local c = PIX[string.sub(art[y], x, x)]
			local o = ((y - 1) * w + (x - 1)) * 4
			if c then
				buffer.writeu8(buf, o, c[1])
				buffer.writeu8(buf, o + 1, c[2])
				buffer.writeu8(buf, o + 2, c[3])
				buffer.writeu8(buf, o + 3, 255)
			end
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), buf)
	local content = Content.fromObject(img)
	spriteCache[art] = content
	return content
end

local function pixelLabel(parent: Instance, name: string): ImageLabel
	local l = Instance.new("ImageLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.ScaleType = Enum.ScaleType.Fit
	l.ResampleMode = Enum.ResamplerMode.Pixelated
	l.Parent = parent
	return l
end

-- ----------------------------------------------------------------- words ---
local function comma(n: number): string
	local s = string.format("%.0f", math.max(0, n))
	local out = ""
	while #s > 3 do
		out = "," .. string.sub(s, -3) .. out
		s = string.sub(s, 1, -4)
	end
	return s .. out
end

-- 500, 1.5K, 25K: what fits on a badge.
local function short(n: number): string
	if n < 1000 then
		return tostring(math.floor(n))
	end
	local k = n / 1000
	return (if k == math.floor(k) then tostring(math.floor(k)) else string.format("%.1f", k)) .. "K"
end

-- A number in the kit's face, stroked, in a corner of an icon box.
local function badge(box: Instance, text: string, color: Color3, top: boolean?)
	local b = label(box, "Badge", 100, 100, 0, if top then 0 else 76, 100, 24, color, Enum.TextXAlignment.Right, kit.FONT_KIT)
	setText(b, text)
	b.ZIndex = 4
	local s = Instance.new("UIStroke")
	s.Thickness = 2
	s.Color = Color3.fromRGB(20, 22, 28)
	s.Parent = b
end

local function grantWords(g: EventPass.Grant): string
	local n = math.floor(g.amount or 1)
	if g.kind == "money" then
		return comma(n) .. " MONEY"
	elseif g.kind == "pattern" then
		local def = Patterns.byKey(g.key)
		return string.upper(def and def.name or tostring(g.key)) .. " SKIN"
	elseif g.kind == "pass" then
		local e = Products.pass(g.key :: string)
		return string.upper(e and e.name or tostring(g.key))
	elseif g.kind == "revive" then
		return if n > 1 then n .. " REVIVES" else "REVIVE"
	elseif g.kind == "rename" then
		return "NATION RENAME"
	elseif g.kind == "flag" then
		return "FLAG UNLOCK"
	elseif g.kind == "money3x" then
		return if n > 1 then n .. "x 3X MONEY ROUND" else "3X MONEY ROUND"
	elseif g.kind == "coupon" then
		local what = if g.key == "BOOST_GOLD" then "GOLD BOOST" else "SPECIAL FORCES"
		return (if n > 1 then n .. "x " else "") .. what .. " COUPON"
	end
	return ""
end

-- One or two words for a card: the badge carries the number.
local function shortName(g: EventPass.Grant): string
	if g.kind == "money" then
		return "MONEY"
	elseif g.kind == "pattern" then
		local def = Patterns.byKey(g.key)
		return string.upper(def and def.name or tostring(g.key)) .. " SKIN"
	elseif g.kind == "pass" then
		return if g.key == "ARTILLERY" then "ARTILLERY" else string.upper(tostring(g.key))
	elseif g.kind == "revive" then
		return "REVIVE"
	elseif g.kind == "rename" then
		return "RENAME"
	elseif g.kind == "flag" then
		return "FLAG"
	elseif g.kind == "money3x" then
		return "3X MONEY"
	elseif g.kind == "coupon" then
		return if g.key == "BOOST_GOLD" then "GOLD BOOST" else "SPECIAL FORCES"
	end
	return ""
end

local function rewardWords(grants: { EventPass.Grant }): string
	local parts = {}
	for _, g in grants do
		table.insert(parts, grantWords(g))
	end
	return table.concat(parts, "\n+ ")
end

-- ----------------------------------------------------------------- icons ---
-- WHAT THE REWARD IS, drawn as the thing itself where the game already has a
-- picture of it: the pattern's own swatch, the pass's shop art, the banknote.
local function iconInto(box: GuiObject, g: EventPass.Grant)
	if g.kind == "pattern" then
		local img = pixelLabel(box, "Swatch")
		img.ImageContent = Content.fromObject(Patterns.swatch(Patterns.indexOf(g.key)))
		img.Size = UDim2.fromScale(1, 1)
		roundOff(img, 8)
		return
	end
	if g.kind == "pass" then
		local entry = Products.pass(g.key :: string)
		local images = StarterGui:FindFirstChild("Images")
		local src = entry and entry.art and images and images:FindFirstChild(entry.art)
		if src and src:IsA("ImageLabel") then
			local pic = src:Clone()
			for _, d in pic:GetChildren() do
				d:Destroy()
			end
			pic.Name = "Pass"
			pic.BackgroundTransparency = 1
			pic.ScaleType = Enum.ScaleType.Fit
			pic.AnchorPoint = Vector2.new(0.5, 0.5)
			pic.Position = UDim2.fromScale(0.5, 0.5)
			pic.Size = UDim2.fromScale(1, 1)
			pic.Visible = true
			pic.Parent = box
			return
		end
	end
	if g.kind == "coupon" then
		local img = Instance.new("ImageLabel")
		img.Name = "Coupon"
		img.BackgroundTransparency = 1
		img.ScaleType = Enum.ScaleType.Fit
		img.Image = if g.key == "BOOST_GOLD" then Icons.GOLD else Icons.SWORD
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.Size = UDim2.fromScale(0.86, 0.86)
		img.Parent = box
		Icons.resample(img)
		-- The clock is what says "a boost you start yourself".
		badge(box, "15:00", Color3.fromRGB(111, 217, 138))
		if (g.amount or 1) > 1 then
			badge(box, "x" .. math.floor(g.amount :: number), kit.INK, true)
		end
		return
	end
	local art = if g.kind == "revive" then HEART elseif g.kind == "rename" then PENCIL elseif g.kind == "flag" then FLAG else nil
	if art then
		local img = pixelLabel(box, "Sprite")
		img.ImageContent = spriteContent(art)
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.Size = UDim2.fromScale(0.78, 0.78)
		if (g.amount or 1) > 1 then
			badge(box, "x" .. math.floor(g.amount :: number), kit.INK)
		end
		return
	end
	-- Money, the 3x round, and anything unknown: the banknote.
	local note = MoneyNote.new(box, "Note")
	note.AnchorPoint = Vector2.new(0.5, 0.5)
	note.Position = UDim2.fromScale(0.5, 0.5)
	note.Size = UDim2.fromScale(0.86, 0.6)
	if g.kind == "money3x" then
		badge(box, "3X", kit.GOLD, true)
		if (g.amount or 1) > 1 then
			badge(box, "x" .. math.floor(g.amount :: number), kit.INK)
		end
	elseif g.kind == "money" then
		badge(box, short(g.amount or 0), kit.GOLD)
	end
end

-- ----------------------------------------------------------------- build ---
-- One reward slot: a CanvasGroup (so a locked slot dims as one thing) with a
-- transparent button over it for the press.
local function buildSlot(self: any, card: Instance, tier: number, premium: boolean, y: number, h: number): any
	local grants = if premium then EventPass.TIERS[tier].premium else EventPass.TIERS[tier].free
	-- A FREE TIER WITH AN EXTRA (every fifth) leads with the extra -- its icon,
	-- its words first -- and wears the mid blue, so it reads as more than Money.
	local extra = not premium and #grants > 1
	local class = if premium then CLASS[EventPass.classOf(tier)] elseif extra then CLASS.mid else CLASS.filler

	local group = Instance.new("CanvasGroup")
	group.Name = if premium then "Premium" else "Free"
	group.BackgroundColor3 = class.fill
	group.BackgroundTransparency = 0.05
	group.BorderSizePixel = 0
	place(group, CW, CH, SLOT_X, y, SLOT_W, h)
	group.Parent = card
	roundOff(group, 10)
	local stroke = Instance.new("UIStroke")
	stroke.Color = class.edge
	stroke.Thickness = class.thick
	stroke.Transparency = 0.1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = group
	local scale = grower(group)

	-- PICTURES, NOT WORDS (owner, 2026-10-09: "dont make it so much text, make
	-- it intuitive"). The reward is its icon and a number; its name shows on
	-- hover and on a tap (EventPassUI.hint / press).
	local iconSide = if premium then 112 else 62
	local box = Instance.new("Frame")
	box.Name = "Icon"
	box.BackgroundTransparency = 1
	place(box, SLOT_W, h, (SLOT_W - iconSide) / 2, if premium then 30 else 8, iconSide, iconSide)
	box.Parent = group
	local square = Instance.new("UIAspectRatioConstraint")
	square.AspectRatio = 1
	square.DominantAxis = Enum.DominantAxis.Height
	square.Parent = box
	local lead = if extra then grants[2] else grants[1]
	iconInto(box, lead)
	-- A SECOND GRANT IS A "+" BADGE on the first: the Money riding with a skin,
	-- or under a free tier's extra.
	local other = if extra then grants[1] elseif #grants > 1 then grants[2] else nil
	if other ~= nil and other.kind == "money" then
		badge(box, "+" .. short(other.amount or 0), kit.GOLD)
	end
	local words = if extra then grantWords(grants[2]) .. "  +  " .. grantWords(grants[1]) else (string.gsub(rewardWords(grants), "\n", " "))

	-- THE PREMIUM REWARD'S NAME, one short line under its icon (owner,
	-- 2026-10-09: "you can still have some text"). The free row is Money with
	-- its number on the badge, so it goes without.
	if premium then
		local nm = label(group, "Name", SLOT_W, h, 4, 148, SLOT_W - 8, 20, kit.INK, Enum.TextXAlignment.Center, kit.FONT_BOLD)
		local cap = nm:FindFirstChildOfClass("UITextSizeConstraint")
		if cap then
			cap.MaxTextSize = 15
		end
		setText(nm, shortName(lead))
	end

	-- CLAIM: a green chip under the icon while it can be taken.
	local chipW, chipH = SLOT_W - 24, if premium then 26 else 22
	local chip = Instance.new("Frame")
	chip.Name = "Claim"
	chip.BackgroundColor3 = GREEN_FILL
	chip.BorderSizePixel = 0
	place(chip, SLOT_W, h, 12, h - chipH - 8, chipW, chipH)
	chip.ZIndex = 4
	chip.Visible = false
	chip.Parent = group
	roundOff(chip, 8)
	local cs = Instance.new("UIStroke")
	cs.Color = kit.GAIN
	cs.Thickness = 1.4
	cs.Parent = chip
	local chipText = label(chip, "Caption", chipW, chipH, 0, 2, chipW, chipH - 4, kit.INK, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	setText(chipText, "CLAIM")
	chipText.ZIndex = 5

	-- TAKEN: a green tick over the icon -- on the CARD, not in the slot's group,
	-- so it stays bright while the slot behind it dims.
	local tickSide = iconSide * 0.75
	local check = pixelLabel(card, "Check")
	check.ImageContent = spriteContent(CHECK)
	place(check, CW, CH, SLOT_X + (SLOT_W - tickSide) / 2, y + (if premium then 30 else 8) + (iconSide - tickSide) / 2, tickSide, tickSide)
	check.ZIndex = 7
	check.Visible = false

	-- The premium row's padlock, over the icon, while premium is locked.
	local lock: ImageLabel? = nil
	if premium then
		local l = pixelLabel(group, "Lock")
		l.ImageContent = spriteContent(LOCK)
		place(l, SLOT_W, h, SLOT_W - 34, 6, 28, 28)
		l.ZIndex = 5
		lock = l
	end

	local hit = Instance.new("ImageButton")
	hit.Name = "Hit"
	hit.Image = ""
	hit.BackgroundTransparency = 1
	hit.AutoButtonColor = false
	place(hit, CW, CH, SLOT_X, y, SLOT_W, h)
	hit.ZIndex = 6
	hit.Parent = card

	local slot = {
		tier = tier, premium = premium, group = group, stroke = stroke, scale = scale,
		chip = chip, check = check, words = words, lock = lock, class = class, hover = false,
	}
	hit.MouseEnter:Connect(function()
		slot.hover = true
		tween(scale, kit.HOVER_IN, { Scale = 1.04 })
		EventPassUI.hint(self, words)
	end)
	hit.MouseLeave:Connect(function()
		slot.hover = false
		tween(scale, kit.HOVER_OUT, { Scale = 1 })
		EventPassUI.hint(self, nil)
	end)
	hit.MouseButton1Down:Connect(function()
		tween(scale, kit.PRESS_IN, { Scale = kit.PRESS_SCALE })
	end)
	hit.MouseButton1Up:Connect(function()
		tween(scale, kit.PRESS_OUT, { Scale = if slot.hover then 1.04 else 1 })
	end)
	hit.Activated:Connect(function()
		EventPassUI.press(self, slot)
	end)
	return slot
end

local function buildCard(self: any, parent: Instance, tier: number): any
	local x = CGAP + (tier - 1) * (CW + CGAP)
	local card = Instance.new("Frame")
	card.Name = "Tier" .. tier
	card.BackgroundTransparency = 1
	place(card, CANVAS_W, TRACK_H, x, 4, CW, CH)
	card.Parent = parent
	local scale = grower(card)
	local cls = EventPass.classOf(tier)
	local num = label(card, "Num", CW, CH, 0, 2, CW, 26,
		if cls == "filler" then kit.INK_DIM else CLASS[cls].edge, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	setText(num, tostring(tier))
	return {
		tier = tier, card = card, scale = scale, num = num, x = x,
		free = buildSlot(self, card, tier, false, FREE_Y, FREE_H),
		premium = buildSlot(self, card, tier, true, PREM_Y, PREM_H),
	}
end

function EventPassUI.new(parent: Instance): any
	local self = setmetatable({}, EventPassUI)
	self.xp = 0
	self.claimed = {} :: { [string]: boolean }
	self.premium = false
	self.known = false
	self.openGen = 0
	self.msgUntil = 0
	self.clockAt = 0
	self.onClaim = nil :: ((number, boolean?) -> ())?
	self.onRobux = nil :: ((string) -> ())?

	-- The backdrop is a button: a press that misses the panel closes it.
	local shade = Instance.new("ImageButton")
	shade.Name = "EventShade"
	shade.Image = ""
	shade.AutoButtonColor = false
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(4, 6, 11)
	shade.BackgroundTransparency = 1
	shade.BorderSizePixel = 0
	shade.Visible = false
	shade.ZIndex = 20
	shade.Parent = parent
	self.shade = shade
	shade.Activated:Connect(function()
		EventPassUI.close(self)
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.BackgroundColor3 = kit.PANEL
	panel.BackgroundTransparency = 0.02
	panel.BorderSizePixel = 0
	panel.Active = true
	place(panel, REF_W, REF_H, PX, PY, PW, PH)
	panel.Parent = shade
	roundOff(panel, 12)
	self.panelScale = grower(panel)
	local ps = Instance.new("UIStroke")
	ps.Color = ORANGE
	ps.Thickness = 1.6
	ps.Transparency = 0.35
	ps.Parent = panel
	local scrim = Instance.new("ImageLabel")
	scrim.Name = "Scrim"
	scrim.BackgroundTransparency = 1
	scrim.Image = kit.SCRIM
	scrim.ScaleType = Enum.ScaleType.Stretch
	scrim.ImageTransparency = 0.3
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = panel
	roundOff(scrim, 12)

	kitSet(kitLabel(panel, "Title", PW, PH, 0, 16, PW, 44, ORANGE), EventPass.NAME)

	local close = pillButton(panel, "Close", PW, PH, PW - 16 - 44, 16, 44, 44, "X", RED, RED_LINE)
	close.Activated:Connect(function()
		EventPassUI.close(self)
	end)

	-- ------------------------------------------------------- progress --
	-- THE TIER YOU ARE ON, the bar to the next, and how long is left. No
	-- words the shapes already say.
	local tb = Instance.new("Frame")
	tb.Name = "TierBadge"
	tb.BackgroundColor3 = ORANGE_DEEP
	tb.BorderSizePixel = 0
	place(tb, PW, PH, 24, 70, 92, 50)
	tb.Parent = panel
	roundOff(tb, 10)
	local tbs = Instance.new("UIStroke")
	tbs.Color = ORANGE
	tbs.Thickness = 1.6
	tbs.Parent = tb
	local tierCap = label(tb, "TierCaption", 92, 50, 0, 3, 92, 12, Color3.fromRGB(255, 214, 170), Enum.TextXAlignment.Center, kit.FONT_BOLD)
	setText(tierCap, "TIER")
	self.tierText = label(tb, "Tier", 92, 50, 0, 15, 92, 32, kit.INK, Enum.TextXAlignment.Center, kit.FONT_KIT)
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BackgroundColor3 = SLOT_FILL
	bar.BorderSizePixel = 0
	place(bar, PW, PH, 132, 80, 820, 30)
	bar.Parent = panel
	roundOff(bar, 15)
	local bs = Instance.new("UIStroke")
	bs.Color = kit.LINE
	bs.Thickness = 1.4
	bs.Parent = bar
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = ORANGE
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = bar
	roundOff(fill, 15)
	self.barFill = fill
	self.xpText = label(bar, "Xp", 820, 30, 0, 5, 820, 20, kit.INK, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	self.xpText.ZIndex = 3
	local xs = Instance.new("UIStroke")
	xs.Thickness = 1.5
	xs.Color = Color3.fromRGB(20, 22, 28)
	xs.Parent = self.xpText
	local how = label(panel, "Hint", PW, PH, 132, 114, 820, 16, kit.INK_DIM, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	setText(how, "PLAY MATCHES TO EARN XP  -  HORDE GIVES 2X")
	self.clock = label(panel, "Clock", PW, PH, 1000, 83, PW - 24 - 1000, 24, ORANGE, Enum.TextXAlignment.Left, kit.FONT_BOLD)
	do
		local images = StarterGui:FindFirstChild("Images")
		local glass = images and images:FindFirstChild("Hourglass")
		if glass and glass:IsA("ImageLabel") then
			local g = Instance.new("ImageLabel")
			g.Name = "Hourglass"
			g.BackgroundTransparency = 1
			g.Image = glass.Image
			g.ScaleType = Enum.ScaleType.Fit
			place(g, PW, PH, 966, 81, 28, 28)
			g.Parent = panel
		end
	end

	-- ------------------------------------------------------ row labels --
	local freeLbl = label(panel, "FreeRow", PW, PH, LABEL_X, TRACK_Y + 4 + FREE_Y + 36, LABEL_W, 22, kit.INK_DIM, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	setText(freeLbl, "FREE")
	local premLbl = label(panel, "PremiumRow", PW, PH, LABEL_X, TRACK_Y + 4 + PREM_Y + 98, LABEL_W, 22, ORANGE, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	setText(premLbl, "PREMIUM")
	local pump = pixelLabel(panel, "Lock")
	pump.ImageContent = spriteContent(LOCK)
	place(pump, PW, PH, LABEL_X + (LABEL_W - 44) / 2, TRACK_Y + 4 + PREM_Y + 46, 44, 44)
	self.premRowLock = pump

	-- ----------------------------------------------------------- track --
	local track = Instance.new("ScrollingFrame")
	track.Name = "Track"
	track.BackgroundTransparency = 1
	track.BorderSizePixel = 0
	track.ScrollingDirection = Enum.ScrollingDirection.X
	track.ScrollBarThickness = 8
	track.ScrollBarImageColor3 = ORANGE
	track.ElasticBehavior = Enum.ElasticBehavior.Always
	-- MEASURED, NOT ASSUMED: this canvas's Scale resolves against the PANEL
	-- (an edit-mode capture read 1221x711 for a 1.0 x 1.0 canvas, the panel's
	-- own size), so it is authored in panel units.
	track.CanvasSize = UDim2.fromScale(CANVAS_W / PW, TRACK_H / PH)
	track.VerticalScrollBarInset = Enum.ScrollBarInset.None
	place(track, PW, PH, TRACK_X, TRACK_Y, TRACK_W, TRACK_H)
	track.Parent = panel
	self.track = track
	self.cards = {}
	for t = 1, EventPass.COUNT do
		self.cards[t] = buildCard(self, track, t)
	end

	-- ------------------------------------------------------ bottom row --
	self.unlock = pillButton(panel, "Unlock", PW, PH, 24, ROW_Y, 300, ROW_H, "UNLOCK PREMIUM", ORANGE_DEEP, ORANGE)
	self.unlockCap = self.unlock:FindFirstChild("Caption") :: TextLabel
	self.unlock.Activated:Connect(function()
		if self.premium then
			return
		end
		Sfx.play("Click")
		if self.onRobux then
			self.onRobux(EventPass.PREMIUM_PRODUCT)
		end
	end)

	self.claimAll = pillButton(panel, "ClaimAll", PW, PH, 340, ROW_Y, 220, ROW_H, "CLAIM ALL", GREEN_FILL, kit.GAIN)
	self.claimAll.Activated:Connect(function()
		if EventPassUI.claimable(self) == 0 then
			Sfx.play("Deny")
			EventPassUI.say(self, "NOTHING TO CLAIM YET -- PLAY A MATCH")
			return
		end
		if self.onClaim then
			self.onClaim(0, nil)
		end
	end)

	self.skips = {}
	local skipW, skipGap = 186, 12
	local skipX = PW - 24 - (skipW * 3 + skipGap * 2)
	for i, spec in EventPass.SKIPS do
		local b = pillButton(panel, "Skip" .. spec.tiers, PW, PH, skipX + (i - 1) * (skipW + skipGap), ROW_Y, skipW, ROW_H,
			"+" .. spec.tiers .. " TIER" .. (if spec.tiers > 1 then "S" else ""), Color3.fromRGB(24, 40, 70), kit.ACCENT)
		local entry = { key = spec.key, tiers = spec.tiers, button = b, caption = b:FindFirstChild("Caption") :: TextLabel }
		b.Activated:Connect(function()
			local reached = EventPass.progress(self.xp)
			if EventPass.COUNT - reached < spec.tiers then
				Sfx.play("Deny")
				EventPassUI.say(self, "ONLY " .. (EventPass.COUNT - reached) .. " TIERS LEFT")
				return
			end
			if not EventPass.isLive() then
				Sfx.play("Deny")
				EventPassUI.say(self, "THE EVENT HAS ENDED")
				return
			end
			Sfx.play("Click")
			if self.onRobux then
				self.onRobux(spec.key)
			end
		end)
		table.insert(self.skips, entry)
	end

	self.message = label(panel, "Message", PW, PH, 24, MSG_Y, PW - 48, 18, kit.GOLD)

	-- THE PRICES, asked of the site (managed pricing varies them by region);
	-- Products' display price until it answers.
	task.spawn(function()
		local function priceOf(key: string): number?
			local e = Products.product(key)
			if e == nil then
				return nil
			end
			if Products.isLive(e) then
				local ok, info = pcall(function()
					return MarketplaceService:GetProductInfo((e :: any).id, Enum.InfoType.Product)
				end)
				if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
					return tonumber(info.PriceInRobux)
				end
			end
			return (e :: any).robux
		end
		local p = priceOf(EventPass.PREMIUM_PRODUCT)
		if p then
			setText(self.unlockCap, "UNLOCK PREMIUM   R$ " .. p)
		end
		for _, s in self.skips do
			local sp = priceOf(s.key)
			if sp then
				setText(s.caption, "+" .. s.tiers .. " TIER" .. (if s.tiers > 1 then "S" else "") .. "   R$ " .. sp)
			end
		end
	end)

	EventPassUI.paint(self)
	return self
end

-- ----------------------------------------------------------------- state ---

-- Unclaimed rewards already earned (premium ones only once premium is open).
function EventPassUI.claimable(self: any): number
	local reached = EventPass.progress(self.xp)
	local n = 0
	for t = 1, reached do
		if not self.claimed[EventPass.claimKey(t, false)] then
			n += 1
		end
		if self.premium and not self.claimed[EventPass.claimKey(t, true)] then
			n += 1
		end
	end
	return n
end

local function paintSlot(self: any, slot: any, reached: number)
	local key = EventPass.claimKey(slot.tier, slot.premium)
	local taken = self.claimed[key] == true
	local open = slot.tier <= reached
	local locked = slot.premium and not self.premium
	slot.ready = self.known and open and not taken and not locked
	if slot.lock then
		slot.lock.Visible = locked
	end
	slot.chip.Visible = slot.ready
	slot.check.Visible = taken
	if taken then
		slot.group.GroupTransparency = 0.6
		slot.stroke.Color = slot.class.edge
		slot.stroke.Thickness = slot.class.thick
	elseif slot.ready then
		slot.group.GroupTransparency = 0
		slot.stroke.Color = kit.GAIN
		slot.stroke.Thickness = slot.class.thick + 0.8
	else
		-- Not reached, or premium not unlocked: dimmed, the reward still
		-- legible -- what it is is the reason to keep playing.
		slot.group.GroupTransparency = if open and locked then 0.15 else 0.45
		slot.stroke.Color = slot.class.edge
		slot.stroke.Thickness = slot.class.thick
	end
end

function EventPassUI.paint(self: any)
	local reached, into, need = EventPass.progress(self.xp)
	for _, c in self.cards do
		paintSlot(self, c.free, reached)
		paintSlot(self, c.premium, reached)
		c.num.TextTransparency = if c.tier <= reached then 0 else 0.4
	end
	if reached >= EventPass.COUNT then
		setText(self.tierText, tostring(EventPass.COUNT))
		setText(self.xpText, "COMPLETE")
		tween(self.barFill, BAR_FILL, { Size = UDim2.fromScale(1, 1) })
	else
		setText(self.tierText, tostring(reached))
		setText(self.xpText, comma(into) .. " / " .. comma(need) .. " XP")
		tween(self.barFill, BAR_FILL, { Size = UDim2.fromScale(math.clamp(into / math.max(1, need), 0, 1), 1) })
	end
	self.unlock.Visible = not self.premium
	self.premRowLock.Visible = not self.premium
	local n = EventPassUI.claimable(self)
	setText(self.claimAll:FindFirstChild("Caption") :: TextLabel, if n > 0 then "CLAIM ALL (" .. n .. ")" else "CLAIM ALL")
	self.claimAll.BackgroundColor3 = if n > 0 then GREEN_FILL else kit.PANEL
	for _, s in self.skips do
		s.button.Visible = EventPass.isLive() and EventPass.COUNT - reached >= s.tiers
	end
end

-- The server's word on this account's pass. `landed` is the tiers a claim
-- just paid; the premium flip and an XP jump (a tier skip) are noticed here.
function EventPassUI.setState(self: any, xp: any, claimed: any, premium: any, landed: any?, say: any?)
	local wasKnown = self.known
	local wasPremium, wasReached = self.premium, (EventPass.progress(self.xp))
	self.xp = math.max(0, math.floor(tonumber(xp) or 0))
	self.claimed = if type(claimed) == "table" then claimed else {}
	self.premium = premium == true
	self.known = true
	EventPassUI.paint(self)
	if type(say) == "string" and say ~= "" then
		Sfx.play("Deny")
		EventPassUI.say(self, say)
	end
	if not wasKnown then
		return
	end
	local reached = EventPass.progress(self.xp)
	if self.premium and not wasPremium then
		Sfx.play("Cheer")
		EventPassUI.say(self, "HALLOWEEN PASS UNLOCKED -- CLAIM YOUR PREMIUM REWARDS")
		for t = 1, reached do
			EventPassUI.flash(self, self.cards[t].premium, ORANGE)
		end
	elseif reached > wasReached and self.shade.Visible then
		Sfx.play("Cheer")
		EventPassUI.say(self, "TIER " .. reached .. " REACHED")
		EventPassUI.scrollTo(self, wasReached + 1)
	end
	if type(landed) == "table" and #landed > 0 then
		EventPassUI.landed(self, landed)
	end
end

-- A claim the server paid: every slot it took flashes and punches, and the
-- sound says how big the best of it was.
function EventPassUI.landed(self: any, landed: { any })
	local best = "filler"
	local order = { filler = 1, mid = 2, good = 3, great = 4 }
	for _, k in landed do
		local s = tostring(k)
		local tier = tonumber(string.sub(s, 2))
		local premium = string.sub(s, 1, 1) == "p"
		local card = tier and self.cards[tier]
		if card then
			local slot = if premium then card.premium else card.free
			EventPassUI.flash(self, slot, kit.GOLD)
			if premium and order[EventPass.classOf(tier :: number)] > order[best] then
				best = EventPass.classOf(tier :: number)
			end
		end
	end
	Sfx.play(if best == "great" or best == "good" then "Cheer" else "Coin")
	EventPassUI.say(self, if #landed == 1 then "CLAIMED!" else "CLAIMED " .. #landed .. " REWARDS!")
end

function EventPassUI.flash(_self: any, slot: any, color: Color3)
	local s = slot.stroke
	local c, t = s.Color, s.Thickness
	s.Color = color
	s.Thickness = t + 3
	s.Transparency = 0
	tween(s, LAND_FLASH, { Color = c, Thickness = t, Transparency = 0.1 })
	slot.scale.Scale = 1.15
	tween(slot.scale, LAND_PUNCH, { Scale = 1 })
end

function EventPassUI.say(self: any, text: string)
	setText(self.message, text)
	self.msgUntil = os.clock() + 4
end

-- The hovered reward's name on the message line, while the cursor is on it.
-- A timed message (a refusal, a claim) is not talked over.
function EventPassUI.hint(self: any, text: string?)
	if self.msgUntil > 0 then
		return
	end
	setText(self.message, text or "")
end

-- ---------------------------------------------------------------- presses --

function EventPassUI.press(self: any, slot: any)
	if not self.known then
		return
	end
	local key = EventPass.claimKey(slot.tier, slot.premium)
	if self.claimed[key] then
		return
	end
	if slot.premium and not self.premium then
		Sfx.play("Deny")
		EventPassUI.say(self, slot.words .. "  -  UNLOCK PREMIUM")
		return
	end
	local reached = EventPass.progress(self.xp)
	if slot.tier > reached then
		Sfx.play("Deny")
		EventPassUI.say(self, slot.words .. "  -  TIER " .. slot.tier)
		return
	end
	-- NO SOUND YET: the cheer belongs to the grant landing (setState).
	if self.onClaim then
		self.onClaim(slot.tier, slot.premium)
	end
end

-- ------------------------------------------------------------ open / shut --

-- Centres a tier's card in the track.
function EventPassUI.scrollTo(self: any, tier: number)
	local t = math.clamp(tier, 1, EventPass.COUNT)
	local track = self.track
	local canvas = track.AbsoluteCanvasSize.X
	if canvas <= 0 then
		return
	end
	local cx = (self.cards[t].x + CW / 2) / CANVAS_W * canvas
	local target = math.clamp(cx - track.AbsoluteWindowSize.X / 2, 0, math.max(0, canvas - track.AbsoluteWindowSize.X))
	tween(track, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CanvasPosition = Vector2.new(target, 0) })
end

-- Where the eye should land: the first thing waiting to be claimed, else the
-- tier being worked towards.
local function focusTier(self: any): number
	local reached = EventPass.progress(self.xp)
	for t = 1, reached do
		if not self.claimed[EventPass.claimKey(t, false)]
			or (self.premium and not self.claimed[EventPass.claimKey(t, true)]) then
			return t
		end
	end
	return reached + 1
end

function EventPassUI.open(self: any)
	if self.shade.Visible then
		return
	end
	self.openGen += 1
	local gen = self.openGen
	setText(self.message, "")
	EventPassUI.paint(self)
	EventPassUI.tickClock(self)
	self.shade.BackgroundTransparency = 1
	self.panelScale.Scale = PANEL_FROM
	self.shade.Visible = true
	tween(self.shade, OPEN_SHADE, { BackgroundTransparency = SHADE_ALPHA })
	tween(self.panelScale, OPEN_PANEL, { Scale = 1 })
	local focus = focusTier(self)
	task.defer(function()
		RunService.Heartbeat:Wait()
		if self.openGen ~= gen then
			return
		end
		-- Jump, then deal the cards around it in from the middle out.
		local track = self.track
		local canvas = track.AbsoluteCanvasSize.X
		if canvas > 0 then
			local t = math.clamp(focus, 1, EventPass.COUNT)
			local cx = (self.cards[t].x + CW / 2) / CANVAS_W * canvas
			track.CanvasPosition = Vector2.new(math.clamp(cx - track.AbsoluteWindowSize.X / 2, 0, math.max(0, canvas - track.AbsoluteWindowSize.X)), 0)
		end
		for _, c in self.cards do
			local d = math.abs(c.tier - focus)
			if d <= 5 then
				c.scale.Scale = 0.8
				task.delay(0.04 * d, function()
					if self.openGen == gen then
						tween(c.scale, CARD_IN, { Scale = 1 })
					end
				end)
			else
				c.scale.Scale = 1
			end
		end
	end)
end

function EventPassUI.close(self: any)
	if not self.shade.Visible then
		return
	end
	self.openGen += 1
	local gen = self.openGen
	tween(self.shade, SHUT, { BackgroundTransparency = 1 })
	tween(self.panelScale, SHUT, { Scale = PANEL_FROM })
	task.delay(0.12, function()
		if self.openGen == gen then
			self.shade.Visible = false
		end
	end)
end

function EventPassUI.isOpen(self: any): boolean
	return self.shade.Visible
end

function EventPassUI.tickClock(self: any)
	local left = EventPass.ENDS - os.time()
	if left <= 0 then
		setText(self.clock, "ENDED")
		return
	end
	local d, h, m = left // 86400, (left % 86400) // 3600, (left % 3600) // 60
	setText(self.clock, if d > 0 then string.format("%dD %dH", d, h) else string.format("%dH %dM", h, m))
end

function EventPassUI.step(self: any)
	if not self.shade.Visible then
		return
	end
	local now = os.clock()
	if self.msgUntil > 0 and now > self.msgUntil then
		self.msgUntil = 0
		setText(self.message, "")
	end
	if now - self.clockAt > 1 then
		self.clockAt = now
		EventPassUI.tickClock(self)
	end
	-- What can be claimed breathes, so the eye finds it.
	local a = 0.5 + 0.5 * math.sin(now * 5)
	for _, c in self.cards do
		if c.free.ready then
			c.free.stroke.Transparency = 0.45 * a
		end
		if c.premium.ready then
			c.premium.stroke.Transparency = 0.45 * a
		end
	end
end

return EventPassUI
