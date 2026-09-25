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
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Gamepad = require(Shared.Gamepad)
local Matchmaker = require(Shared.Matchmaker)
local LobbyUI = require(Shared.LobbyUI)
local Net = require(Shared.Net)
local PatternShop = require(Shared.PatternShop)

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
local ShopRE = netFolder:WaitForChild("Shop") :: RemoteEvent

local playerGui = player:WaitForChild("PlayerGui")

local screen = Instance.new("ScreenGui")
screen.Name = "ConquestLobby"
screen.IgnoreGuiInset = true
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 5
screen.Parent = playerGui

local page = LobbyUI.new(screen, player.UserId)
-- THE PATTERN SHOP, a page of its own over the same screen. It is built here
-- rather than inside LobbyUI so that the dependency stays one-way: the shop
-- borrows the lobby page's kit, and the lobby page knows nothing about the
-- shop beyond a button that reports having been pressed.
local shop = PatternShop.new(screen)
page.onPatterns = function()
	shop:open()
end

-- ------------------------------------------------------------- rewards ---
--
-- NOTHING IS CHECKED HERE, and that is the design rather than an omission.
--
-- THE SHEET ASKS FOR THREE THINGS AND THE ENGINE CAN ANSWER FOR ONE. A game's
-- LIKES have no per-player endpoint anywhere; a FAVOURITE is readable only
-- through AvatarEditorService, behind a permission dialog that reads "would
-- like to access your avatar's items" -- a prompt with nothing to do with
-- favouriting a game, which players refuse on reflex, and whose answer for a
-- place id is undocumented anyway (measured 2026-09-17: GetFavorite throws
-- until that permission is granted, and it was never granted in testing).
-- That route was built and then taken out for those reasons.
--
-- What is left is GROUP MEMBERSHIP, and it is checked on the SERVER
-- (MatchmakerServer, REWARD_GROUP) -- not because the client cannot call
-- IsInGroup, but because a client deciding whether it has earned a free skin
-- is a client that can be told to say yes. This file only draws what arrives.

-- WHAT THE INVITE PILL OPENS. PromptGameInvite is the one social action
-- Roblox gives an in-experience dialog for -- there is no equivalent for a
-- like, a favourite or a community join (checked against the live API dump:
-- no Prompt* member for any of them on any service).
--
-- OPENING IT IS THE WHOLE GATE, and that is a TRUST SYSTEM by choice (owner,
-- 2026-09-17: "allow players to claim after they open the invite friend api.
-- at that point just make it a trust system"). What could be verified instead
-- is the other end of it -- an invited player's join carries
-- ReferredByPlayerId -- but that proof lands in a different session, possibly
-- days later, so gating on it would mean nobody ever claims in the moment.
--
-- SESSION-LOCAL ON PURPOSE. Nothing about this is written to the profile: the
-- thing worth persisting is the GRANT, and the server owns that.
local SocialService = game:GetService("SocialService")
local invited = false
local rewardClaimed = false

page.onInvite = function()
	-- CanSendGameInviteAsync YIELDS, so the whole thing is spawned -- a press
	-- that froze the page while it asked would be worse than one that waited a
	-- frame. Both calls are pcall'd: invites are unavailable on some accounts
	-- and devices, and that is a sentence on the sheet rather than an error.
	task.spawn(function()
		local ok, can = pcall(function()
			return SocialService:CanSendGameInviteAsync(player)
		end)
		if ok and can == false then
			page:rewardSay("INVITES ARE NOT AVAILABLE ON THIS ACCOUNT")
			return
		end
		local sent = pcall(function()
			SocialService:PromptGameInvite(player)
		end)
		if not sent then
			page:rewardSay("INVITES ARE NOT AVAILABLE RIGHT NOW")
			return
		end
		-- The dialog is up. That is the trust gate met -- and it stays met for
		-- the rest of the session, because a player who sends the invite and
		-- comes back to the sheet must not find the button dark again.
		invited = true
		page:setRewardState(rewardClaimed, true)
	end)
end

-- A CONTROLLER GETS ROBLOX'S VIRTUAL CURSOR ON THIS PAGE, so every card, pill
-- and field is pressed the way a mouse presses it -- see Gamepad. Anchored on
-- the page itself so the cursor comes up in the middle of it.
Gamepad.watch(screen:FindFirstChild("Page") :: GuiObject?)

-- B BACKS OUT, the way the CANCEL and DONE buttons do: the shop if it is open,
-- else the join panel. The room panel is deliberately left alone -- leaving a
-- room is a LEAVE press, and a back button that quietly did that would be
-- worse than one that does nothing. By KeyCode alone: no keyboard has a
-- ButtonB, and the Studio bridge sends pad codes as keyboard events.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.ButtonB then
		return
	end
	if shop:isOpen() then
		shop:close()
	elseif page.rewardsOpen then
		page:closeRewards()
	elseif page.listOpen then
		page:closeList()
	elseif page.joinView.Visible then
		page:closePanel()
	end
end)

-- STRAIGHT DOWN THE REMOTE, NOT THROUGH `intent()` -- and this is the one
-- place on this page that bypasses that gate. The gate exists because every
-- board intent is a MemoryStore write, and it holds exactly ONE queued intent
-- with the last one winning: a pattern press going through it would REPLACE a
-- JOIN the player had just made, and they would never enter the lobby. There
-- is no MemoryStore behind a cosmetic -- the far side is a table write on a
-- profile that server already has open -- so it has its own, much shorter
-- cooldown there instead (MatchmakerServer, COSMETIC_COOLDOWN).
shop.onIntent = function(verb: string, key: string)
	LobbyIntentRE:FireServer("pattern", verb, key)
end
-- ...and the Robux half of the same page: a product key up the Shop remote,
-- which is the purchase channel the rename already uses (ConquestShop). The
-- prompt is the site's; the page repaints when the receipt has landed.
shop.onRobux = function(key: string)
	ShopRE:FireServer("buy", key)
end
-- ...and the PASS half, which is a different verb and not a nicety: `buy` is
-- PromptProductPurchase and VIP is a game pass, so sending it up the line
-- above would prompt nothing at all. Same channel the room panel's locked
-- arrows already use (`page.onPassBuy` below).
shop.onPass = function(key: string)
	ShopRE:FireServer("pass", key)
end
-- ...and the MONEY half of a pass card (2026-09-22): no site prompt, the
-- server settles it and answers on this same remote ("passmoney" below).
shop.onMoneyPass = function(key: string)
	ShopRE:FireServer("passmoney", key)
end
-- The FLAGS tab's half of the same seam. A separate verb rather than a second
-- argument on the pattern one, so the server's two handlers stay independent
-- and a malformed flag press can never be read as a pattern press.
shop.onFlagIntent = function(verb: string, id: string)
	LobbyIntentRE:FireServer("flag", verb, id)
end
-- SEE ALL GAMES SAYING IT IS OPEN, and it bypasses the gate below for exactly
-- the reason the shop does -- with one extra edge that makes it mandatory here.
-- The gate holds ONE queued intent and the last one wins, and this is sent on a
-- TIMER (the server drops a browser that goes quiet): a keep-alive landing in
-- the queue a fraction after a JOIN press would replace that press, and the
-- player would sit in a lobby they had already left the page believing they had
-- joined. There is no MemoryStore write behind it -- the server sets one number
-- in a local table -- so it belongs nowhere near a queue built for writes.
page.onBrowse = function(open: boolean)
	LobbyIntentRE:FireServer("browse", open)
end

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

-- THE CLAN TAG RIDES WITH THE INTENTS THAT ENTER A MATCH, and never on a timer
-- of its own. It is a team key -- type the same tag as your friends and the
-- match puts you on the same side (Matchmaker.normaliseTag, Sim.addPlayer) --
-- so the moments it has to be true are exactly the moments a player commits to
-- a game: joining a card, joining a room, creating one.
--
-- WHY IT IS NOT ITS OWN INTENT. The gate below holds ONE queued intent and the
-- last one in wins, so a tag sent a fraction of a second after a JOIN press
-- would REPLACE that press and the player would never enter the lobby. Riding
-- along costs no traffic and cannot displace anything.
local function myTag(): string
	local _, t = page:identity()
	return Matchmaker.normaliseTag(t)
end

page.onJoin = function(key: string)
	intent("join", key, myTag())
end
page.onLeave = function()
	intent("leave")
end

-- THE FREE REWARDS CLAIM, down here with the other intents rather than beside
-- the rest of the rewards wiring at the top of this file -- and the reason is
-- not taste.
--
-- `intent` IS A LOCAL DECLARED FURTHER UP THIS FILE THAN THIS LINE BUT LOWER
-- THAN THE REWARDS BLOCK, and a closure written ABOVE a local's declaration
-- captures the GLOBAL of that name instead -- which is nil. That is exactly
-- what happened: the claim button called into LobbyUI, LobbyUI called onClaim,
-- onClaim called nil, and the error went to the output where nobody playing
-- would ever see it. The button simply appeared to do nothing and the page
-- kept saying CLAIM, because the server was never told.
--
-- Every other hook that sends an intent is below the declaration for the same
-- reason. Anything added here must stay below it too.
page.onClaim = function()
	intent("reward")
end

-- PRIVATE LOBBIES. Every one of these is a MemoryStore write on the far side,
-- so they go through the same one-a-second gate as the board's own intents --
-- which is also what makes a host flicking through the settings cheap: the
-- queue holds only the LAST state, so ten presses in a second are one write of
-- the thing the panel is already showing.
page.onCreate = function(settings)
	intent("create", settings, myTag())
end
page.onRoomJoin = function(code: string)
	intent("pjoin", code, myTag())
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

-- ...AND ONE CATCH-UP SEND, for the player who queues first and types their tag
-- afterwards. Strictly opportunistic: if anything is queued, or the gate is
-- inside its one-second window, this does nothing at all rather than risk
-- displacing a press. The tag is a free local write on the server -- no
-- MemoryStore behind it -- so the only cost of skipping is that the tag waits
-- for the next join, which carries it anyway.
page.tagBox.FocusLost:Connect(function()
	if queued ~= nil or os.clock() - lastSent < INTENT_GAP then
		return
	end
	intent("tag", myTag())
end)

-- THE NATION NAME, ON ITS OWN REMOTE and deliberately outside the gate above.
-- That gate holds ONE queued message and the last one in wins, so a name
-- committed a moment after a JOIN press would replace the press and the player
-- would never enter the lobby they thought they had joined. Neither of these
-- is a MemoryStore write, so neither belongs in a queue built for them; the
-- server keeps its own floor (ConquestShop).
page.onRenameBuy = function()
	ShopRE:FireServer("buy")
end
-- A LOCKED ROOM DIAL: the arrow asks for the pass that opens it, up the same
-- purchase channel (ConquestShop "pass"). The page lights up when the server
-- has confirmed the pass and sent "passes" back.
page.onPassBuy = function(key: string)
	ShopRE:FireServer("pass", key)
end
page.onRename = function(text: string)
	ShopRE:FireServer("name", text)
end

ShopRE.OnClientEvent:Connect(function(kind, a, b, c, d)
	if kind == "nation" then
		-- COUNT FIRST, NAME LAST -- see the note in ConquestShop's `push`. The
		-- name is nil for anyone who has never bought a rename, so it rides in
		-- the position where a nil cannot swallow the argument behind it.
		page:setNation(b, a)
	elseif kind == "denied" then
		page:toast(tostring(a))
	elseif kind == "passmoney" then
		-- key, ok, a line to print, the balance afterwards (2026-09-22). The
		-- balance rides the same message so the page that just spent it is
		-- right at once; the OWNED flip and the lobby's own balance push
		-- follow on the Lobby remote a moment later.
		shop:setMoney(tonumber(d))
		shop:say(string.upper(tostring(c)))
	elseif kind == "money" then
		shop:setMoney(tonumber(a))
	end
end)

-- THE PRICE, ASKED OF THE SITE rather than read out of the catalogue's display
-- field, because managed pricing is on for this product and the real number
-- varies by region. Spawned and pcall'd: GetProductInfo is a web call that
-- throws on network trouble, and a caption that stays reading RENAME is a much
-- smaller failure than a page that will not finish drawing.
task.spawn(function()
	local Products = require(Shared.Products)
	local entry = Products.product("RENAME")
	if not Products.isLive(entry) then
		return
	end
	local ok, info = pcall(function()
		return game:GetService("MarketplaceService"):GetProductInfo((entry :: any).id, Enum.InfoType.Product)
	end)
	if ok and type(info) == "table" then
		page:setRenamePrice(info.PriceInRobux)
	end
end)

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

-- /tutorial -- the only way back into the lesson now that the page has no
-- button for it. A player's first ever join is carried into the tutorial
-- without being asked (MatchmakerServer, off the profile's `tutorialSeen`), so
-- this is for the second time and after: somebody who wants to see it again,
-- and anybody testing it. Same remote, same one-a-second gate, same server
-- path as the automatic launch -- there is no second way to start a tutorial.
--
-- LOBBY SERVERS ONLY, like everything else in this file: a match server
-- returns above, and there is nothing to teleport out of a lesson into.
task.spawn(function()
	local TextChatService = game:GetService("TextChatService")
	local cmd = TextChatService:WaitForChild("TutorialCommand", 30)
	if not cmd then
		return
	end
	;(cmd :: TextChatCommand).Triggered:Connect(function(_source, text)
		-- The answer is a TELEPORT, which takes a moment to arrive. The toast
		-- is the only thing between the two.
		page:toast("Opening the tutorial...")
		-- THE TYPED LINE RIDES ALONG for one reason: `/tutorial world` is the
		-- owner's way of testing the lesson on a named map (MatchmakerServer,
		-- tutorialMapFor). For everybody else the server ignores it and deals
		-- the map itself -- a player who could pick would be picking which
		-- funnel they count in.
		intent("tutorial", text)
	end)
end)

-- The same remote also carries "wait"/"go", which belong to MatchIntro in a
-- match server. Ignoring anything unrecognised is what lets one channel serve
-- both roles.
LobbyRE.OnClientEvent:Connect(function(kind, a, b)
	if kind == "board" then
		if type(a) == "table" then
			page:setBoard(Matchmaker.readWire(a, player.UserId))
		end
	elseif kind == "toast" then
		page:toast(tostring(a))
	elseif kind == "money" then
		-- The account balance, sent once the profile has loaded and again
		-- whenever it moves. A number that never arrives leaves the readout
		-- hidden, which is the right answer for a DataStore that is down.
		page:setMoney(tonumber(a))
		-- The shop prices against the same balance, and it is the one page
		-- where the number has to be right the instant it moves: it has just
		-- been spent.
		shop:setMoney(tonumber(a))
	elseif kind == "patterns" then
		-- What this account owns, what it is wearing, and how many rounds it
		-- has won. Sent when the profile lands and again after every buy or
		-- equip -- the page never guesses at any of it.
		if type(a) == "table" then
			shop:setState(a.owned, a.equipped, a.wins, a.money2x)
		end
	elseif kind == "flags" then
		-- Which flags this account owns, which one it is flying, and how many
		-- unspent unlocks it holds. Same contract as "patterns" above: the page
		-- never guesses at any of it.
		if type(a) == "table" then
			shop:setFlagState(a.owned, a.equipped, a.tokens)
		end
	elseif kind == "rooms" then
		-- The public rooms, sent only while this client has the sheet open.
		-- Plural, and one letter from "room" below, which is the singular and
		-- means the room this player is IN -- they are different messages about
		-- different things and the page keeps them apart.
		page:setRooms(a)
	elseif kind == "room" then
		-- `false` is a real value here and means "you are not in a room". The
		-- decode lives in LobbyUI, which is the only thing that needs it.
		page:setRoom(a)
	elseif kind == "reward" then
		-- Whether the grant is still there to take, and whether this account is
		-- in the group that opens it. Sent when the profile lands and again the
		-- instant a claim moves it, so the sheet never has to guess -- and a
		-- second press after a successful claim finds the button already
		-- reading CLAIMED.
		if type(a) == "table" then
			-- THE SERVER OWNS `claimed` AND THIS FILE OWNS `ready`. The grant is
			-- the server's and is latched on the profile; whether the invite
			-- dialog has been opened is a fact about this session and lives
			-- nowhere else, so a push must not overwrite it with an answer the
			-- server has no way to hold.
			rewardClaimed = a.claimed == true
			page:setRewardState(rewardClaimed, invited)
			-- ...and why, when a claim could not go through. It goes on the SHEET'S
			-- own line: the page's toast is drawn under the sheet's shade, which is
			-- how a refused claim came to look like a button that did nothing.
			if type(a.say) == "string" and a.say ~= "" then
				page:rewardSay(a.say)
			end
		end
	elseif kind == "passes" then
		-- Which room dials this account's passes open: 0, HOST or ADVANCED.
		page:setPassTier(tonumber(a) or 0)
		-- ...and which passes it holds, by key, for the shop's GAMEPASSES tab.
		-- Same contract as "patterns" and "flags": the page never guesses.
		if type(b) == "table" then
			shop:setPassState(b)
		end
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
	shop:step()
end)
