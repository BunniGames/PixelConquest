--!strict
-- Conquest :: MatchIntro  (match servers only)
--
-- The gap between arriving in a reserved server and the round beginning is
-- real: players teleport in from up to three different lobby servers and do not
-- land together, so `ConquestServer` holds the start open until the roster the
-- lobby promised has arrived. Without something on screen for those few
-- seconds a player's first impression of a match is a blank desk.
--
-- Deliberately separate from ConquestClient rather than spliced into it: this
-- has to be up BEFORE the map finishes building (Renderer.new is over a second
-- on its own), and ConquestClient is blocked doing exactly that.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Matchmaker = require(Shared.Matchmaker)
local Net = require(Shared.Net)

while ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) == nil do
	ReplicatedStorage:GetAttributeChangedSignal(Matchmaker.ROLE_ATTR):Wait()
end
if ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) ~= "match" then
	return
end

local FAMILY = Font.fromEnum(Enum.Font.GothamMedium).Family
local FONT_KIT = Font.new("rbxasset://fonts/families/LuckiestGuy.json", Enum.FontWeight.Regular)
local FONT_UI = Font.new(FAMILY, Enum.FontWeight.Medium)
local GOLD = Color3.fromRGB(232, 196, 110)
local INK_DIM = Color3.fromRGB(178, 190, 212)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screen = Instance.new("ScreenGui")
screen.Name = "ConquestMatchIntro"
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.DisplayOrder = 20
screen.Parent = playerGui

local back = Instance.new("Frame")
back.Size = UDim2.fromScale(1, 1)
back.BackgroundColor3 = Color3.fromRGB(10, 12, 18)
back.BorderSizePixel = 0
back.Parent = screen

local function line(name: string, y: number, h: number, color: Color3, font: Font): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.FontFace = font
	t.TextScaled = true
	t.TextColor3 = color
	t.Text = ""
	t.Size = UDim2.fromScale(0.6, h / 720)
	t.Position = UDim2.fromScale(0.2, y / 720)
	local c = Instance.new("UITextSizeConstraint")
	c.MaxTextSize = math.floor(h * 4)
	c.MinTextSize = 6
	c.Parent = t
	t.Parent = back
	return t
end

local title = line("Title", 300, 52, GOLD, FONT_KIT)
title.Text = "PREPARING THE MAP"
local sub = line("Sub", 368, 18, INK_DIM, FONT_UI)
sub.Text = "Commanders are still arriving..."

local netFolder = Net.await(ReplicatedStorage)
local LobbyRE = netFolder:WaitForChild("Lobby") :: RemoteEvent

local done = false
local function dismiss()
	if done then
		return
	end
	done = true
	local fade = TweenService:Create(back, TweenInfo.new(0.6), { BackgroundTransparency = 1 })
	TweenService:Create(title, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
	TweenService:Create(sub, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
	fade.Completed:Connect(function()
		screen:Destroy()
	end)
	fade:Play()
end

LobbyRE.OnClientEvent:Connect(function(kind, a, b)
	if kind == "wait" then
		sub.Text = string.format("Commanders arriving -- %d of %d", tonumber(a) or 0, tonumber(b) or 0)
	elseif kind == "go" then
		dismiss()
	end
end)

-- A safety net, not a timer: if the "go" is ever missed the intro must not sit
-- opaque over a running game.
task.delay(Matchmaker.BOARD_GRACE + 15, dismiss)
