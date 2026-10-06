--!strict
-- Conquest :: Money3xClient  (client)
--
-- THE 3x MONEY BUTTON (owner, 2026-09-29: "add a X3 money button after the game
-- ends for the client, so they can click it, buy a dev product, to get 3x the
-- normal money they normally wouldve gotten"). Round end ONLY: it appears when
-- the server sends the offer on the win tick and goes with the teleport home.
--
-- CALM, AND UNDER THE RECEIPT (owner, same day: "too obnoxious, put it calmly
-- below the how much money a player made gui"). One quiet line the width of
-- the payout card, in the card's own panel colour, directly under it. No
-- pulse. When the card fades (HUD's PAY_HOLD) the line stays where it was: the
-- offer has not gone anywhere.
--
-- IT LIVES IN THE HUD'S OWN ScreenGui ("Conquest") AND IS PLACED IN SCALE,
-- copied off the card's own Scale rect. The first version sat in a ScreenGui of
-- its own and converted the card's AbsolutePosition across, and the top-bar
-- inset landed on one side of that conversion only: the line drew 58pt too high,
-- over the card's last rows (owner's screenshot, 2026-09-29). Same parent, same
-- units, nothing to disagree about.
--
-- THE SERVER DECIDES EVERYTHING. Whether there is an offer, what it is worth
-- (twice what the round paid, so the round ends up worth three times itself),
-- and the prompt itself -- the press is an intent, and ConquestServer checks
-- the offer, opens the Roblox prompt, and holds the teleport while it is open.
--
-- IT IS ITS OWN SCRIPT RATHER THAN CODE IN ConquestClient for the reason
-- GoldTopUpClient gives: that file sits at Luau's 200-local ceiling.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Matchmaker = require(Shared.Matchmaker)
local Net = require(Shared.Net)
local Numbers = require(Shared.Numbers)
local Products = require(Shared.Products)
local Sfx = require(Shared.Sfx)
local MoneyNote = require(Shared.MoneyNote)

-- A lobby runs no round. Yielding rather than returning, for GoldTopUpClient's
-- reason: a Studio lobby flips to "match" when its own countdown fires.
Matchmaker.awaitRole("match")

local netFolder = Net.await(ReplicatedStorage)
local StateRE = netFolder:WaitForChild("State") :: RemoteEvent
local IntentRE = netFolder:WaitForChild("Intent") :: RemoteEvent

local entry = Products.product("MONEY3X")
if not Products.isLive(entry) then
	-- No id, no offer: the server never sends one either.
	return
end

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
-- ConquestClient's ScreenGui, which HUD.new builds the card into.
local screen = playerGui:WaitForChild("Conquest")

-- ================================================================= the look ==
--
-- GREEN (owner, 2026-09-29: "make the button more green"): REVIVE's fill,
-- hover and ink from HUD (REVIVE_FILL / REVIVE_HOVER / REVIVE_INK), with the
-- GAIN edge at full strength -- the two Robux buttons of a round's end read as
-- the same kind of thing. The names stay PANEL / PANEL_HI / INK_DIM so the
-- code below is untouched.
local PANEL = Color3.fromRGB(20, 62, 34)
local PANEL_HI = Color3.fromRGB(28, 88, 48)
local INK_DIM = Color3.fromRGB(178, 240, 194)
local GAIN = Color3.fromRGB(111, 217, 138)
local FAMILY = Font.fromEnum(Enum.Font.GothamMedium).Family
local FONT_DISPLAY = Font.new(FAMILY, Enum.FontWeight.Bold)
local FONT_UI = Font.new(FAMILY, Enum.FontWeight.Medium)
-- In HUD's 720-tall reference pixels, like the card: its height, and the gap
-- between the card's foot and it.
local REF_H = 720
local LINE_H = 34
local GAP = 8

-- A CANVASGROUP around the button, for the card's reason: the whole line --
-- fill, edge and both labels -- fades as one surface off the card's own
-- GroupTransparency (see the RenderStepped below).
local group = Instance.new("CanvasGroup")
group.Name = "Money3x"
group.BackgroundTransparency = 1
group.ZIndex = 10
group.Visible = false

local button = Instance.new("TextButton")
button.Name = "Button"
-- INSET BY THE STROKE. A Border stroke draws OUTSIDE the button, and the
-- group clips at its own edge -- flush, the outline was shaved off down every
-- side and broken at the corners. STROKE_ROOM px of margin all round.
local STROKE_ROOM = 2
button.Position = UDim2.fromOffset(STROKE_ROOM, STROKE_ROOM)
button.Size = UDim2.new(1, -2 * STROKE_ROOM, 1, -2 * STROKE_ROOM)
button.BackgroundColor3 = PANEL
button.BackgroundTransparency = 0.04
button.BorderSizePixel = 0
button.AutoButtonColor = false
button.Text = ""
button.Active = true
button.ZIndex = 10
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 6)
corner.Parent = button
local edge = Instance.new("UIStroke")
edge.Color = GAIN
-- The card's own weight (HUD payStroke, 1.4), so the two edges match.
edge.Thickness = 1.4
edge.Transparency = 0.2
edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
edge.Parent = button
local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0.053, 0)
pad.PaddingRight = UDim.new(0.053, 0)
pad.Parent = button

local function text(name: string, xAlign: Enum.TextXAlignment, font: Font, color: Color3): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.AnchorPoint = Vector2.new(0, 0.5)
	t.Position = UDim2.fromScale(0, 0.5)
	t.Size = UDim2.fromScale(1, 0.4)
	t.TextScaled = true
	t.FontFace = font
	t.TextColor3 = color
	t.TextXAlignment = xAlign
	t.ZIndex = 11
	t.Parent = button
	return t
end
local left = text("Label", Enum.TextXAlignment.Left, FONT_DISPLAY, INK_DIM)
-- White on the green fill: GAIN on it is green on green.
local right = text("Figure", Enum.TextXAlignment.Right, FONT_UI, Color3.fromRGB(234, 240, 250))
-- The banknote stands for the word MONEY: "[note] 3x" (MoneyNote).
MoneyNote.attach(left)

button.Parent = group
group.Parent = screen

-- ================================================================== state ==

local shown = false
local bonus = 0
local done = false
-- Asked of the site, not read off the catalogue: managed pricing varies it by
-- region. Blank until it answers.
local price: number? = nil
local card: GuiObject? = nil

local function paint()
	if done then
		left.Text = "3x  -  DONE"
		right.Text = "+" .. Numbers.format(bonus)
	else
		left.Text = "3x"
		right.Text = "+" .. Numbers.format(bonus) .. (price and ("   R$ " .. price) or "")
	end
end

task.spawn(function()
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo((entry :: any).id, Enum.InfoType.Product)
	end)
	if ok and type(info) == "table" and tonumber(info.PriceInRobux) then
		price = tonumber(info.PriceInRobux)
		paint()
	end
end)

-- The HUD's receipt: the CanvasGroup HUD.new names "Payout", a DIRECT child of
-- the screen. Not a recursive find -- ConquestClient's floating port-gold
-- labels are also named "Payout", deeper down.
local function findCard(): GuiObject?
	local c = screen:FindFirstChild("Payout")
	return if c and c:IsA("GuiObject") then c else nil
end

-- UNDER THE CARD AND ONLY WITH IT (owner, 2026-09-29: "make the 3x money
-- button disappear when the money summary hud disappears"). Placed off the
-- card's Scale rect and faded off its GroupTransparency every frame, so the two
-- leave together on HUD's PAY_HOLD / PAY_FADE -- and once the card is gone, the
-- line is too. A knocked-out spectator, whose card came and went when they
-- fell, therefore sees no line at the end of the round.
RunService.RenderStepped:Connect(function()
	if not shown then
		return
	end
	if card == nil or card.Parent ~= screen then
		card = findCard()
	end
	local c = card
	if c == nil or not c.Visible then
		group.Visible = false
		return
	end
	-- Grown by STROKE_ROOM all round, so the BUTTON inside lines up with the
	-- card's edges and the margin is only room for the outline.
	group.Position = UDim2.new(c.Position.X.Scale, -STROKE_ROOM, c.Position.Y.Scale + c.Size.Y.Scale + GAP / REF_H, -STROKE_ROOM)
	group.Size = UDim2.new(c.Size.X.Scale, 2 * STROKE_ROOM, LINE_H / REF_H, 2 * STROKE_ROOM)
	group.GroupTransparency = if c:IsA("CanvasGroup") then c.GroupTransparency else 0
	group.Visible = true
end)

button.MouseEnter:Connect(function()
	if not done then
		button.BackgroundColor3 = PANEL_HI
	end
end)
button.MouseLeave:Connect(function()
	button.BackgroundColor3 = PANEL
end)

button.Activated:Connect(function()
	if done or not shown then
		return
	end
	Sfx.play("Click")
	IntentRE:FireServer({ t = "money3x" })
end)

StateRE.OnClientEvent:Connect(function(kind, payload)
	if kind == "money3x" and type(payload) == "table" then
		if payload.done then
			bonus = tonumber(payload.bonus) or bonus
			done = true
			button.BackgroundColor3 = PANEL
			paint()
			Sfx.play("Cheer")
		else
			local b = tonumber(payload.bonus) or 0
			if b > 0 then
				bonus, done = b, false
				button.BackgroundColor3 = PANEL
				paint()
				shown = true
			end
		end
	elseif kind == "init" then
		-- A new round (a Studio session rotates in place instead of
		-- teleporting): last round's offer is gone with it.
		shown = false
		group.Visible = false
	end
end)
