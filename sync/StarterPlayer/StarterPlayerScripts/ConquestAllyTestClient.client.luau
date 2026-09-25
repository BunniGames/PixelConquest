--!strict
-- Conquest :: /gotrequest  (client half)
--
-- Same two jobs as /attackme's client half: get the typed command to the
-- server, and print the reply into the local chat so it is legible without the
-- Output window open. The command is caught HERE because
-- TextChatCommand.Triggered always fires on the client that typed it, while
-- Player.Chatted only reaches the server under some chat configurations. The
-- server accepts either route and de-duplicates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local folder = ReplicatedStorage:WaitForChild("ConquestCheats", 30)
if not folder then
	return
end
local ReportRE = folder:WaitForChild("AllyTestReport") :: RemoteEvent
local RequestRE = folder:WaitForChild("AllyTestRequest") :: RemoteEvent

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
	print("[gotrequest] " .. line)
	local ch = channel()
	if ch then
		-- Green, the colour of the button the card is about to show.
		ch:DisplaySystemMessage('<font color="#8CFFB0">' .. line .. "</font>")
	end
end)

local command = TextChatService:WaitForChild("GotRequestCommand", 30) :: TextChatCommand?
if command then
	command.Triggered:Connect(function(_source, text)
		RequestRE:FireServer(text)
	end)
end
