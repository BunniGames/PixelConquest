--!strict
-- Conquest :: /world  (client half)
--
-- Same two jobs as /endgame's client half: get the typed command to the
-- server, and print the reply into the local chat so it is legible without
-- the Output window open. The command is caught HERE because
-- TextChatCommand.Triggered always fires on the client that typed it, while
-- Player.Chatted only reaches the server under some chat configurations. The
-- server accepts either route and de-duplicates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local folder = ReplicatedStorage:WaitForChild("ConquestCheats", 30)
if not folder then
	return
end
local ReportRE = folder:WaitForChild("MapReport") :: RemoteEvent
local RequestRE = folder:WaitForChild("MapRequest") :: RemoteEvent

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
	print("[world] " .. line)
	local ch = channel()
	if ch then
		ch:DisplaySystemMessage('<font color="#8CD5FF">' .. line .. "</font>")
	end
end)

-- ONE PER ALIAS ROW IN ConquestWorld, by INSTANCE NAME rather than by alias:
-- the server owns which word each one answers to, and this half only has to
-- forward whatever was typed. The first wait is the long one -- by the time
-- it returns the server script has made all of them, so the rest are a
-- formality and a short timeout is enough.
for i, name in { "WorldCommand", "PacificCommand", "NycCommand", "JapanCommand", "MarsCommand", "KoreaCommand", "AfricaCommand", "PhilippinesCommand", "EurasiaCommand", "SpawnCommand" } do
	local command = TextChatService:WaitForChild(name, if i == 1 then 30 else 10) :: TextChatCommand?
	if command then
		command.Triggered:Connect(function(_source, text)
			RequestRE:FireServer(text)
		end)
	end
end
