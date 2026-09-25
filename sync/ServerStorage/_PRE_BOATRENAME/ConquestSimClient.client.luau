--!strict
-- Conquest :: /simulate  (client half)
--
-- Two jobs, both small: get the typed command to the server, and print what
-- comes back into the local chat so a benchmark is readable without the
-- Output window open.
--
-- The command is caught HERE rather than on the server because that is the
-- one place it is guaranteed to arrive: TextChatCommand.Triggered always
-- fires on the client that typed it, while Player.Chatted only fires on the
-- server under some chat configurations. The server accepts either route and
-- de-duplicates, so it does not matter which one wins.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local folder = ReplicatedStorage:WaitForChild("ConquestSim", 30)
if not folder then
	return
end
local ReportRE = folder:WaitForChild("Report") :: RemoteEvent
local RequestRE = folder:WaitForChild("Request") :: RemoteEvent

local function channel(): TextChannel?
	local channels = TextChatService:FindFirstChild("TextChannels")
	if not channels then
		return nil
	end
	return (channels:FindFirstChild("RBXGeneral") or channels:FindFirstChildWhichIsA("TextChannel")) :: TextChannel?
end

ReportRE.OnClientEvent:Connect(function(line)
	if typeof(line) ~= "string" then
		return
	end
	print("[sim] " .. line)
	local ch = channel()
	if ch then
		-- Monospace so the columns in the report line up in the chat window;
		-- a proportional font turns the whole table into ragged prose.
		ch:DisplaySystemMessage(
			'<font face="RobotoMono" size="13" color="#8FD0FF">' .. line .. "</font>"
		)
	end
end)

local command = TextChatService:WaitForChild("SimulateCommand", 30) :: TextChatCommand?
if command then
	command.Triggered:Connect(function(_source, text)
		RequestRE:FireServer(text)
	end)
end
