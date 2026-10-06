--!strict
-- Conquest :: /shop1 + /shop2  (client only)
--
-- SEE BOTH ARMS OF THE PASS LABEL TEST (owner, 2026-10-04). The arm is dealt
-- from the userId (Experiments.passLabelArm), so an account only ever sees its
-- own side. These flip what THIS screen draws on the game pass pills, in the
-- lobby GAMEPASSES tab and the in-game "+" page alike:
--
--   /shop1   the "get" arm   -- the pill says GET
--   /shop2   the "price" arm -- the pill shows the Robux price
--
-- Client only, like /testpop: nothing is sent, the server's analytics still
-- file the account under its real arm, and a rejoin puts the real arm back.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Conquest = ReplicatedStorage:WaitForChild("Conquest")
local Experiments = require(Conquest:WaitForChild("Experiments"))
local PassShop = require(Conquest:WaitForChild("PassShop"))

local function allowed(): boolean
	if RunService:IsStudio() then
		return true
	end
	local me = Players.LocalPlayer
	return game.CreatorType == Enum.CreatorType.User and me ~= nil and me.UserId == game.CreatorId
end

local function tell(line: string)
	print("[shop] " .. line)
	local channels = TextChatService:FindFirstChild("TextChannels")
	local ch = channels and (channels:FindFirstChild("RBXGeneral") or channels:FindFirstChildWhichIsA("TextChannel"))
	if ch then
		(ch :: TextChannel):DisplaySystemMessage('<font color="#8CD5FF">' .. line .. "</font>")
	end
end

local function command(name: string, alias: string): TextChatCommand
	local found = TextChatService:FindFirstChild(name)
	if found and found:IsA("TextChatCommand") then
		return found
	end
	local c = Instance.new("TextChatCommand")
	c.Name = name
	c.PrimaryAlias = alias
	c.Parent = TextChatService
	return c
end

local function preview(arm: string, cmd: string, what: string)
	if not allowed() then
		tell(cmd .. " is for the owner only.")
		return
	end
	Experiments.previewPassLabel = arm
	PassShop.repaintAll()
	tell(cmd .. ": pass shop now shows " .. what .. " (preview on this screen only)")
end

command("ShopOneCommand", "/shop1").Triggered:Connect(function()
	preview("get", "/shop1", "GET")
end)

command("ShopTwoCommand", "/shop2").Triggered:Connect(function()
	preview("price", "/shop2", "the Robux price")
end)
