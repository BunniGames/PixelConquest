--!strict
-- Conquest :: /gold  (client half)
--
-- Two small jobs: get the typed command to the server, and print what comes
-- back into the local chat so the new figure is legible without the Output
-- window open.
--
-- The command is caught HERE rather than on the server because that is the
-- one place it is guaranteed to arrive: TextChatCommand.Triggered always
-- fires on the client that typed it, while Player.Chatted only fires on the
-- server under some chat configurations. The server accepts either route and
-- de-duplicates, so it does not matter which one wins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local folder = ReplicatedStorage:WaitForChild("ConquestCheats", 30)
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
	print("[gold] " .. line)
	local ch = channel()
	if ch then
		-- Gold, so the reply reads as the thing it is about rather than as
		-- another system message.
		ch:DisplaySystemMessage('<font color="#FFD35C">' .. line .. "</font>")
	end
end)

local command = TextChatService:WaitForChild("GoldCommand", 30) :: TextChatCommand?
if command then
	command.Triggered:Connect(function(_source, text)
		RequestRE:FireServer(text)
	end)
end
