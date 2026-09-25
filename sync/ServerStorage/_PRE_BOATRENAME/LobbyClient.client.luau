--!strict
-- Conquest :: LobbyClient
--
-- Drives the matchmaking page in a lobby server, and gets out of the way in a
-- match server. Deliberately tiny: the rules live in `Matchmaker` and the
-- drawing lives in `LobbyUI`, so this is only the wiring between the remote
-- and the page.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Matchmaker = require(Shared.Matchmaker)
local LobbyUI = require(Shared.LobbyUI)
local Net = require(Shared.Net)

local player = Players.LocalPlayer

-- The role attribute is set by whichever server script boots first, so it can
-- lag this script by a frame. Waiting for it to EXIST is not the same as
-- waiting for a value.
while ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) == nil do
	ReplicatedStorage:GetAttributeChangedSignal(Matchmaker.ROLE_ATTR):Wait()
end
if ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) ~= "lobby" then
	return
end

local netFolder = Net.await(ReplicatedStorage)
local LobbyRE = netFolder:WaitForChild("Lobby") :: RemoteEvent
local LobbyIntentRE = netFolder:WaitForChild("LobbyIntent") :: RemoteEvent

local playerGui = player:WaitForChild("PlayerGui")

local screen = Instance.new("ScreenGui")
screen.Name = "ConquestLobby"
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 5
screen.Parent = playerGui

local page = LobbyUI.new(screen, player.UserId)

-- The page is what this server is FOR, so it covers the default camera rather
-- than floating over a spawn nobody is meant to look at.
local camera = workspace.CurrentCamera
if camera then
	camera.CameraType = Enum.CameraType.Scriptable
end

-- THE SERVER TAKES ONE INTENT PER PLAYER PER SECOND and drops the rest in
-- silence, because every join and leave is a MemoryStore write and that is the
-- one thing on this page with a real budget behind it. The page paints a press
-- immediately now, so a DROPPED press would leave it showing a join the server
-- never heard about until the pending hold expired. Hold the press instead and
-- send it the moment the window opens -- and hold only the LAST one, because
-- that is what the page is already showing.
local INTENT_GAP = 1.05
local lastSent = -1e9
local queued: any = nil

local function intent(...)
	local now = os.clock()
	if now - lastSent >= INTENT_GAP then
		lastSent = now
		LobbyIntentRE:FireServer(...)
		return
	end
	local waiting = queued ~= nil
	queued = table.pack(...)
	-- One timer, not one per press: it fires at a fixed moment and sends
	-- whatever `queued` holds by then.
	if not waiting then
		task.delay(INTENT_GAP - (now - lastSent), function()
			local q = queued
			queued = nil
			if q then
				lastSent = os.clock()
				LobbyIntentRE:FireServer(table.unpack(q, 1, q.n))
			end
		end)
	end
end

page.onJoin = function(key: string)
	intent("join", key)
end
page.onLeave = function()
	intent("leave")
end

-- PRIVATE LOBBIES. Every one of these is a MemoryStore write on the far side,
-- so they go through the same one-a-second gate as the board's own intents --
-- which is also what makes a host flicking through the settings cheap: the
-- queue holds only the LAST state, so ten presses in a second are one write of
-- the thing the panel is already showing.
page.onCreate = function(settings)
	intent("create", settings)
end
page.onRoomJoin = function(code: string)
	intent("pjoin", code)
end
page.onRoomLeave = function()
	intent("pleave")
end
page.onRoomSettings = function(settings)
	intent("pset", settings)
end
page.onRoomStart = function()
	intent("pstart")
end

-- /start -- the dev shortcut past the two-minute clock, caught here as well as
-- on the server because TextChatCommand.Triggered is only guaranteed to fire
-- on the client that typed it. The server throttles both routes through the
-- same per-player cooldown the JOIN button uses, so a double delivery is free.
task.spawn(function()
	local TextChatService = game:GetService("TextChatService")
	local cmd = TextChatService:WaitForChild("StartCommand", 30)
	if not cmd then
		return
	end
	local command = cmd :: TextChatCommand
	command.Triggered:Connect(function(_source, text)
		intent("start", text)
	end)
end)

-- The same remote also carries "wait"/"go", which belong to MatchIntro in a
-- match server. Ignoring anything unrecognised is what lets one channel serve
-- both roles.
LobbyRE.OnClientEvent:Connect(function(kind, a)
	if kind == "board" then
		if type(a) == "table" then
			page:setBoard(Matchmaker.readWire(a, player.UserId))
		end
	elseif kind == "toast" then
		page:toast(tostring(a))
	elseif kind == "room" then
		-- `false` is a real value here and means "you are not in a room". The
		-- decode lives in LobbyUI, which is the only thing that needs it.
		page:setRoom(a)
	end
end)

-- STUDIO ONLY. A Studio session has no reserved servers, so a lobby whose
-- clock runs out starts the round in place and flips the role attribute. When
-- that happens the page has to go, or it sits opaque over the map forever.
if RunService:IsStudio() then
	task.spawn(function()
		Matchmaker.awaitRole("match")
		if camera then
			camera.CameraType = Enum.CameraType.Custom
		end
		screen:Destroy()
	end)
end

RunService.RenderStepped:Connect(function(dt)
	page:step(dt)
end)
