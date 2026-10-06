--!strict
-- Conquest :: RankedClient  (client, match side)
--
-- The ranked result card. RankedMatch sends "ranked" on the State remote the
-- moment this player is rated -- at the end of the round, or never for a
-- leaver (they are gone). It shows the rating change, the bar toward the next
-- rank, and on a rank-up the new emblem with what it paid. A voided match
-- (a side never arrived) says so instead.
--
-- The lobby half of the client is RankedUI, wired by LobbyClient.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Matchmaker = require(Shared.Matchmaker)
local Net = require(Shared.Net)
local Ranked = require(Shared.Ranked)
local RankEmblems = require(Shared.RankEmblems)
local LobbyUI = require(Shared.LobbyUI)
local Sfx = require(Shared.Sfx)

while ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) == nil do
	ReplicatedStorage:GetAttributeChangedSignal(Matchmaker.ROLE_ATTR):Wait()
end
-- In Studio the role flips lobby -> match in-session, so wait for "match"
-- rather than returning on "lobby".
Matchmaker.awaitRole("match")

local kit = LobbyUI.kit
local place, label, setText = kit.place, kit.label, kit.setText
local StateRE = Net.await(ReplicatedStorage):WaitForChild("State") :: RemoteEvent

local W, H = 320, 250
local GAIN = kit.GAIN
local LOSS = Color3.fromRGB(240, 96, 96)

local screen = Instance.new("ScreenGui")
screen.Name = "RankedResult"
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 40
screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local card = Instance.new("Frame")
card.Name = "Card"
card.BackgroundColor3 = kit.PANEL
card.BackgroundTransparency = 0.04
card.BorderSizePixel = 0
card.AnchorPoint = Vector2.new(0, 0.5)
card.Position = UDim2.fromScale(0.02, 0.5)
card.Size = UDim2.fromScale(W / kit.REF_W, H / kit.REF_H)
card.Visible = false
card.Parent = screen
local ar = Instance.new("UIAspectRatioConstraint")
ar.AspectRatio = W / H
ar.Parent = card
kit.roundOff(card, 12)
local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(196, 140, 255)
stroke.Thickness = 1.8
stroke.Parent = card
local scale = Instance.new("UIScale")
scale.Parent = card

local head = kit.kitLabel(card, "Head", W, H, 0, 12, W, 30, nil)
local emblemImg = RankEmblems.image(card, "Emblem", "recruit") :: ImageLabel
place(emblemImg, W, H, 16, 52, 92, 92)
local emblemScale = Instance.new("UIScale")
emblemScale.Parent = emblemImg
local rankName = label(card, "RankName", W, H, 118, 58, W - 130, 24, kit.GOLD, Enum.TextXAlignment.Left, kit.FONT_BOLD)
local delta = label(card, "Delta", W, H, 118, 86, W - 130, 30, GAIN, Enum.TextXAlignment.Left, kit.FONT_BOLD)
local rating = label(card, "Rating", W, H, 118, 120, W - 130, 18, kit.INK_DIM, Enum.TextXAlignment.Left)
local barBack = Instance.new("Frame")
barBack.BackgroundColor3 = Color3.fromRGB(30, 36, 52)
barBack.BorderSizePixel = 0
place(barBack, W, H, 16, 156, W - 32, 10)
barBack.Parent = card
kit.roundOff(barBack, 5)
local barFill = Instance.new("Frame")
barFill.BackgroundColor3 = kit.GOLD
barFill.BorderSizePixel = 0
barFill.Size = UDim2.fromScale(0, 1)
barFill.Parent = barBack
kit.roundOff(barFill, 5)
local nextLine = label(card, "Next", W, H, 16, 170, W - 32, 14, kit.INK_OFF, Enum.TextXAlignment.Center)
local rewardLines = label(card, "Rewards", W, H, 16, 192, W - 32, 40, GAIN, Enum.TextXAlignment.Center, kit.FONT_BOLD)
rewardLines.TextWrapped = true

-- Every word on the card is outlined, matching the lobby sheet (RankedUI).
for _, t in card:GetDescendants() do
	if t:IsA("TextLabel") and not t:FindFirstChildOfClass("UIStroke") then
		local st = Instance.new("UIStroke")
		st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		st.Color = Color3.new(0, 0, 0)
		st.Thickness = 1.5
		st.Transparency = 0.25
		st.Parent = t
	end
end

local function short(n: number): string
	if n >= 1000 then
		local k = n / 1000
		return (k == math.floor(k) and string.format("%dK", k) or string.format("%.1fK", k))
	end
	return tostring(n)
end

local function setEmblem(index: number)
	local e = RankEmblems.editable(RankEmblems.ORDER[index] or "recruit")
	if e then
		emblemImg.ImageContent = Content.fromObject(e)
	end
end

-- Bumped per card so a stale delayed bar tween never fires on a newer card.
local showToken = 0
local BAR_TIME = 0.9
local BAR_POPS = 10

local function show(p: any)
	card.Visible = true
	scale.Scale = 0.6
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	if p.void then
		-- `forfeit`: a win over a side that all quit early -- unrated.
		kit.kitSet(head, if p.forfeit then "VICTORY" else "MATCH CANCELLED")
		setEmblem(1)
		emblemImg.Visible = false
		setText(rankName, if p.forfeit then "Opponents left early" else "A side never arrived")
		setText(delta, "NO RATING CHANGE")
		delta.TextColor3 = kit.INK
		setText(rating, "")
		barBack.Visible = false
		setText(nextLine, "")
		setText(rewardLines, if p.forfeit then "" else "Sending you back to the lobby...")
		return
	end
	emblemImg.Visible = true
	barBack.Visible = true

	local rankUp = (p.rank or 1) > (p.oldRank or 1)
	local rankDown = (p.rank or 1) < (p.oldRank or 1)
	kit.kitSet(head, rankUp and "RANK UP!" or (p.won and "VICTORY" or "DEFEAT"))
	local rung = Ranked.rung(p.rank or 1)
	setText(rankName, string.upper(rung.name) .. (rankDown and "  (DOWN)" or ""))
	rankName.TextColor3 = rung.color
	-- RR, not MMR (the rating is hidden). No NEXT line, as on the lobby card.
	local d = tonumber(p.delta) or 0
	setText(delta, (d >= 0 and "+" or "") .. tostring(d) .. " RR")
	delta.TextColor3 = d >= 0 and GAIN or LOSS
	local rr = tonumber(p.rr) or 0
	local oldRR = tonumber(p.oldRR) or 0
	setText(rating, tostring(oldRR) .. "  ->  " .. tostring(rr) .. " RR")
	setText(nextLine, "")
	barFill.BackgroundColor3 = rung.color

	-- The bar runs from where you were to where you are; across a rank change
	-- it starts from the new rank's empty (or full, going down) end.
	-- RR is a running total; the bar is this rank's span of it.
	local rankNow = p.rank or 1
	local from = if rankUp then 0 elseif rankDown then 1 else Ranked.progress({ rank = rankNow, rr = oldRR })
	barFill.Size = UDim2.fromScale(from, 1)
	local target = { Size = UDim2.fromScale(Ranked.progress({ rank = rankNow, rr = rr }), 1) }
	showToken += 1
	if d > 0 then
		-- A gain holds 1 s on the old fill, then eases in and out (an S-curve).
		local token = showToken
		task.delay(1, function()
			if token == showToken and card.Visible then
				TweenService:Create(barFill, TweenInfo.new(BAR_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), target):Play()
				-- The conquest pop ticks the fill up, its pitch climbing with it.
				for i = 0, BAR_POPS - 1 do
					task.delay(i * BAR_TIME / BAR_POPS, function()
						if token == showToken and card.Visible then
							local f = i / (BAR_POPS - 1)
							Sfx.play("Pop", { pitch = 0.95 + 0.65 * f, volume = 1.2 })
						end
					end)
				end
			end
		end)
	else
		TweenService:Create(barFill, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), target):Play()
	end

	local lines = {}
	for _, r in (p.rewards or {}) do
		local bits = {}
		if (r.money or 0) > 0 then
			table.insert(bits, "+$" .. short(r.money))
		end
		if r.pattern then
			table.insert(bits, string.upper(r.pattern) .. " PATTERN")
		end
		if r.pass then
			table.insert(bits, string.upper(r.pass) .. " UNLOCKED")
		end
		if #bits > 0 then
			table.insert(lines, table.concat(bits, "  "))
		end
	end
	setText(rewardLines, table.concat(lines, "\n"))

	if rankUp then
		-- The old emblem, then the new one punches in.
		setEmblem(p.oldRank or 1)
		task.delay(0.6, function()
			setEmblem(p.rank or 1)
			emblemScale.Scale = 1.6
			TweenService:Create(emblemScale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end)
	else
		setEmblem(p.rank or 1)
	end
end

StateRE.OnClientEvent:Connect(function(kind: string, payload: any)
	if kind == "ranked" and type(payload) == "table" then
		show(payload)
	elseif kind == "init" then
		-- A new round (Studio rotates in place): the last card goes.
		card.Visible = false
	end
end)
