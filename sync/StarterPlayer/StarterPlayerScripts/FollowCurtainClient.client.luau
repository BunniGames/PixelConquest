--!strict
-- Conquest :: FollowCurtain  (lobby servers only)
--
-- A friend who pressed JOIN on somebody mid-match lands on the lobby page for
-- the seconds it takes the lobby to find that match and send them on
-- (MatchmakerServer.followFriend). This covers the page for those seconds, so
-- the arrival reads as one loading screen rather than a lobby that flashes up
-- and vanishes -- and when there is no room beside the friend it says so
-- while the tutorial opens instead.
--
-- Driven by the `ConquestFollow` attribute on the Player, which replicates and
-- can be read late -- a message fired before this script connected would be
-- lost, an attribute is simply there:
--   looking   the lobby is asking where the friend is
--   sent      the teleport into the friend's match went out
--   tutorial  no room beside the friend; the tutorial is opening instead
--   first     the friend was not in a match to join; a first visit opens the
--             tutorial as it always has
--   stay      nothing to do -- the page is theirs
-- Anyone who did not arrive by JOIN never has the attribute, and this draws
-- nothing for them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Matchmaker = require(Shared.Matchmaker)

while ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) == nil do
	ReplicatedStorage:GetAttributeChangedSignal(Matchmaker.ROLE_ATTR):Wait()
end
if ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) ~= "lobby" then
	return
end

local ATTR = "ConquestFollow"
local FAMILY = Font.fromEnum(Enum.Font.GothamMedium).Family
local FONT_KIT = Font.new("rbxasset://fonts/families/LuckiestGuy.json", Enum.FontWeight.Regular)
local FONT_UI = Font.new(FAMILY, Enum.FontWeight.Medium)
local GOLD = Color3.fromRGB(232, 196, 110)
local INK_DIM = Color3.fromRGB(178, 190, 212)
-- The longest a curtain may stay up with nothing happening behind it -- a
-- teleport that never came, a profile that never loaded. Restarted on every
-- state change, so each step gets its own four seconds (owner, 2026-09-18:
-- "safety timer should be less than 5 seconds"). A step that runs longer
-- drops the curtain and the next state puts it back up.
local SAFETY_SECONDS = 4

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screen = Instance.new("ScreenGui")
screen.Name = "ConquestFollowCurtain"
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.DisplayOrder = 21
screen.Enabled = false
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
local sub = line("Sub", 368, 18, INK_DIM, FONT_UI)

local shown = false
local gen = 0
-- The fades in flight, so a show that lands mid-fade can cancel them: a tween
-- left running would carry the curtain back to transparent under the new
-- words, and Completed would then leave it enabled and invisible.
local fades: { Tween } = {}

local function cancelFades()
	for _, tw in fades do
		tw:Cancel()
	end
	table.clear(fades)
end

local function hide()
	if not shown then
		return
	end
	shown = false
	cancelFades()
	local fade = TweenService:Create(back, TweenInfo.new(0.5), { BackgroundTransparency = 1 })
	local t1 = TweenService:Create(title, TweenInfo.new(0.35), { TextTransparency = 1 })
	local t2 = TweenService:Create(sub, TweenInfo.new(0.35), { TextTransparency = 1 })
	fades = { fade, t1, t2 }
	fade.Completed:Connect(function(ps: Enum.PlaybackState)
		if ps == Enum.PlaybackState.Completed and not shown then
			screen.Enabled = false
		end
	end)
	fade:Play()
	t1:Play()
	t2:Play()
end

local function show(t: string, s: string)
	title.Text = t
	sub.Text = s
	if not shown then
		shown = true
		cancelFades()
		back.BackgroundTransparency = 0
		title.TextTransparency = 0
		sub.TextTransparency = 0
		screen.Enabled = true
	end
	gen += 1
	local mine = gen
	task.delay(SAFETY_SECONDS, function()
		if gen == mine then
			hide()
		end
	end)
end

local function apply()
	local state = player:GetAttribute(ATTR)
	if state == "looking" then
		show("FINDING YOUR FRIEND'S GAME", "Hold on...")
	elseif state == "sent" then
		show("JOINING YOUR FRIEND", "Teleporting...")
	elseif state == "tutorial" then
		show("NO ROOM BESIDE YOUR FRIEND", "Opening the tutorial instead...")
	elseif state == "first" then
		show("FIRST TIME HERE", "Opening the tutorial...")
	else
		hide()
	end
end

apply()
player:GetAttributeChangedSignal(ATTR):Connect(apply)
