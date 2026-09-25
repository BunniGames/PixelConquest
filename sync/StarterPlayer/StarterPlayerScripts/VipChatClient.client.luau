--!strict
-- Conquest :: VipChatClient  (client)
-- The VIP chat tag, and nothing else.
--
-- ON THE CLIENT, because OnIncomingMessage is a DISPLAY hook: it rewrites what
-- this client draws and cannot change what anybody else sees. That is exactly
-- why it is safe to drive off an attribute -- the worst a tampered client can
-- do here is give itself a tag in its own window.
--
-- THE ATTRIBUTE IS THE SERVER'S ANSWER. `ConquestVip` is set by
-- ConquestMonetization.settleVip once the site has confirmed the pass, and
-- player attributes replicate to every client, so the SENDER's tag is readable
-- from here without a remote of its own. It is also the same channel the
-- nation name uses (ConquestNation), for the same reason.
--
-- RETURN nil FOR EVERYONE ELSE. A callback that returns a properties object
-- replaces what is drawn, so anything that is not a VIP's message has to fall
-- through UNTOUCHED rather than be rebuilt -- rebuilding it is how a chat tag
-- quietly eats the name colour, rich text and emoji on every other message in
-- the channel.

local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")

local VIP_ATTR = "ConquestVip"

-- The gold this game already reads as "a readout, or a thing somebody paid
-- for": the lobby's money figure, the shop's Robux prices and the WEARING ring
-- are all this hue. A tag in a new colour would be a sixth thing to learn.
local TAG = '<font color="#E8C46E"><b>[VIP]</b></font> '

TextChatService.OnIncomingMessage = function(message: TextChatMessage)
	-- No sender: a system message, which has nobody to be VIP.
	local source = message.TextSource
	if source == nil then
		return nil
	end

	local player = Players:GetPlayerByUserId(source.UserId)
	if player == nil or player:GetAttribute(VIP_ATTR) ~= true then
		return nil
	end

	-- PREFIX, NOT TEXT. PrefixText is the name block; putting the tag in front
	-- of it keeps the engine's own name colouring and keeps the tag out of
	-- anything that reads the message body.
	local props = Instance.new("TextChatMessageProperties")
	props.PrefixText = TAG .. message.PrefixText
	return props
end
