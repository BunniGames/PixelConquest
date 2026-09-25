--!strict
-- Conquest :: DiplomacyClient  (client)
--
-- The ALLIANCE tab on the left edge of the HUD under the shop tab, the panel of
-- live players it opens, the request card that lands bottom-right on the
-- person you ask, and the small toasts diplomacy throws. SERVER-AUTHORITATIVE:
-- this file sends intents and draws what it is told, and never decides who is
-- allied with whom.
--
-- THE FLOW (owner, 2026-09-18: "open up a tab of live players with a green
-- button of Alliance ... the player being sent the alliance should have a
-- request in the bottom right corner of their screen"):
--   ALLIANCE on a row   -> Intent {t="ally", id}. The server files a request
--                          (Conquest.Alliances.sendRequest) and tells both
--                          sides on the "ally" channel: "sent" to you, "request"
--                          to them.
--   their card          -> bottom-right, ACCEPT / DECLINE, and a bar that runs
--                          out in the 20 s the server gives a request.
--   ACCEPT              -> {t="ally", id} back. Meeting a request IS accepting
--                          it (upstream's rule: one intent for both halves).
--   DECLINE             -> {t="allyno", id}.
--   then both hear "allied" or "rejected" (a timeout is a rejection too).
--
-- THE REST OF UPSTREAM'S RULES (owner, 2026-09-18: "implement everything"),
-- as the row shows them:
--   ALLIED m:ss         the five-minute clock (ALLIANCE_DURATION), read off the
--                       private snapshot's `left`.
--   RENEW               in the last 30 s (EXTEND_OFFSET) -> {t="renew"}; the
--                       clock only resets once BOTH have pressed. RENEWING
--                       while yours is in and theirs is not; a toast when
--                       theirs lands first.
--   BREAK -> SURE?      two presses inside 3 s -> {t="unally"}. Breaking marks
--                       you a TRAITOR for 30 s (the row and the card say so,
--                       everybody is told), and the betrayed side gets a toast.
--   EMBARGO / LIFT      {t="embargo", stop}: closes the trading-boat lane both
--                       ways (Economy.pickTradePartner reads it). An attack lays
--                       a temporary one down by itself (Alliances.onAttack).
-- What an alliance DOES on the map is Sim's now: allies cannot attack each
-- other (refusal "allied"), an attack in progress retreats when its target
-- becomes an ally, a traitor is cheaper to invade, an ally's station pays
-- the most gold, and a nuke that glasses over 100 of an ally's tiles is a
-- betrayal. Targeting exists on the wire (TARGET intent) but has no button:
-- the only reader is the AI's assist logic, and a control that does nothing
-- visible is worse than none.
--
-- PLAYERS ONLY (owner: "players shouldnt be able to send alliance to AIs"):
-- the rows are every empire the wire calls a player (not isBot -- faux
-- players included, on purpose: the standings call them players too),
-- spawned and alive, not you, and not on your team. The server refuses an
-- ask aimed at an ordinary AI regardless ("notaplayer").
--
-- REAL GAMES ONLY (owner: "It should only appear in real games. NOT
-- tutorials"). The tab starts HIDDEN and is shown only once the server has
-- said, in so many words, that this round is not a lesson -- never the other
-- way round: a listener that finishes its setup after `init` misses it, and a
-- tab that pops up for 200 ms on a tutorial server and then hides is worse
-- than one that arrives 200 ms late everywhere else. Three signals say
-- "tutorial", and any one of them LATCHES for the life of the script, because
-- a server never turns from a lesson into a match:
--   * ReplicatedStorage[Matchmaker.LOCAL_TUTORIAL_ATTR] -- Studio, where a
--     tutorial pressed on the lobby page rides as an attribute;
--   * `init` carrying a `tutorial` table -- the student's own card;
--   * the repeating stats `phase` broadcast carrying `tutorial == true`.
-- A "tutorial" CARD message is deliberately not one of them: a real match
-- deals three of those to a player who followed a friend in (the lite
-- lesson), and it must keep its tab.
-- That same `phase` broadcast is the one that says NOT a tutorial (`false`),
-- and it repeats every STATS_INTERVAL, so the tab converges inside 200 ms of
-- this script starting whichever order the messages arrive in. The server
-- refuses the intents on a tutorial server as well, so the gate is not only
-- cosmetic.
--
-- IT IS ITS OWN SCRIPT for the reason TutorialShopClient is: ConquestClient
-- sits at Luau's 200-local ceiling (measured 2026-09-12) and the HUD is one
-- 3,500-line class. This reads the same "State" remote as both and adds
-- nothing to either. The HUD's palette and face are COPIED below rather than
-- required: a require of the HUD here would build nothing and cost the file.
--
-- THE TAB IS THE SHOP TAB'S TWIN. Same edge, same size, same drift / hover /
-- press dent (TutorialShopClient, "the shop tab" block), placed under it: the
-- shop tab is centred at reference y 340 and is 88 tall, and its SHOP caption
-- hangs to ~402, so this one's top sits at 408 -- centre 452. Captioned
-- ALLIANCE the way the shop tab is captioned SHOP -- see the caption block for
-- why its box is wider than the shop's.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Matchmaker = require(Shared.Matchmaker)
local Net = require(Shared.Net)
-- The map's labels: this file tells them which nation wears a handshake and
-- which a broken heart (NationLabels.setMark, module state shared with the
-- ConquestClient instance that draws them).
local NationLabels = require(Shared.NationLabels)
local Faces = require(Shared.Faces)
local Palette = require(Shared.Palette)
local Sfx = require(Shared.Sfx)

-- A lobby server runs no round. Yielding rather than returning is what every
-- match-only client does: a Studio lobby FLIPS to "match" when its own
-- countdown fires.
Matchmaker.awaitRole("match")

local netFolder = Net.await(ReplicatedStorage)
local StateRE = netFolder:WaitForChild("State") :: RemoteEvent
local IntentRE = netFolder:WaitForChild("Intent") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ------------------------------------------------------------------ the look --
-- The HUD's constants, verbatim, so a panel here reads as one of its own.
local FAMILY = Font.fromEnum(Enum.Font.GothamMedium).Family
local FONT_DISPLAY = Font.new(FAMILY, Enum.FontWeight.Bold)
local FONT_UI = Font.new(FAMILY, Enum.FontWeight.Medium)
local INK = Color3.fromRGB(234, 240, 250)
local INK_DIM = Color3.fromRGB(178, 190, 212)
local INK_OFF = Color3.fromRGB(146, 160, 186)
local PANEL = Color3.fromRGB(15, 20, 32)
local PANEL_HI = Color3.fromRGB(30, 39, 58)
local LINE = Color3.fromRGB(52, 66, 94)
local TRACK = Color3.fromRGB(9, 12, 20)
local GAIN = Color3.fromRGB(111, 217, 138)
local THREAT = Color3.fromRGB(232, 97, 90)
-- THE GREEN BUTTON (owner: "a green button of Alliance"). The HUD's press-this
-- green -- the one the lesson rings a button in -- and not GAIN: on this HUD
-- GAIN is a figure going up, and this is a thing to press.
local PRESS = Color3.fromRGB(60, 230, 110)
local ON_PRESS = Color3.fromRGB(8, 24, 14)

local REF_W, REF_H = 1280, 720

-- ------------------------------------------------------------------- the tab --
local TAB_X = 14 / 1280
local TAB_Y = 452 / 720
local TAB_SIZE = 88 / 720
local TAB_RATIO = 1
-- The shop tab's numbers for hover/press, but NO idle motion: the shop tab is
-- the invitation that pulses, the alliance tab holds still (owner, 2026-09-18).
-- Breathe/swing amplitudes are 0; the shop's values were 0.016 / 1.1.
local TAB_BREATHE = 0
local TAB_BREATHE_HZ = 0.55
local TAB_SWING = 0
local TAB_SWING_HZ = 0.3
local TAB_HOVER_GROW = 0.07
local TAB_PUNCH_DENT = 0.1
local HOVER_RATE = 12
-- ...but not in LOCKSTEP. Both ScreenGuis wake on the same broadcast, so with
-- the same clock the two icons would breathe and swing as one object with a
-- gap cut in it. A phase offset makes them two things drifting on one edge.
local TAB_PHASE = 2.1
-- Open, the tab holds still: it has stopped being an invitation and become a
-- close button (the shop tab's rule).
local TAB_OPEN_CALM = 0.25

-- ----------------------------------------------------------------- the panel --
-- Beside the tab column, in the band the shop's own note measured clear:
-- x from 14 + 88, y 72..608. Widened 300 -> 360 on 2026-09-18 for the second
-- button a row carries now (EMBARGO / BREAK beside the main one).
local PANEL_X = 14 + 88 + 14
local PANEL_Y = 150
local PANEL_W = 360
local PANEL_H = 360
local TITLE_H = 40
local ROW_H = 38
local ROW_PAD = 12
local BTN_W, BTN_H = 100, 26
local SIDE_W = 64
-- THE FACE (owner, 2026-09-18: "display the pfp of the player as well"): the
-- standings board's disc at the standings board's size, so a player looks the
-- same in every list that names them.
local AVATAR_D = 26
-- How long a row says DECLINED / WAIT before it offers the button again, and
-- how long BREAK stays armed as SURE? before it forgets.
local DECLINED_HOLD = 3
local WAIT_HOLD = 2
local BREAK_ARM = 3
local BTN_HOVER_GROW = 0.06

-- ------------------------------------------------------------ the request card --
-- BOTTOM-RIGHT (owner), on the HUD's 14 px foot margin -- the corner the clock
-- used to keep. A request can only exist while the round is PLAYING
-- (Alliances.handleIntent refuses outside it), and from 2026-09-18 the corner
-- clock hides itself once it counts up (HUD.setTimer), so the corner is always
-- empty when a card needs it. Further cards stack upward, and the toast line
-- sits above the stack.
local CARD_W, CARD_H = 250, 96
local CARD_GAP = 8
local CARD_X = REF_W - 14 - CARD_W
local CARD_Y0 = REF_H - 14 - CARD_H
local CARD_FACE = 40
local TOAST_W, TOAST_H = 320, 18
local TOAST_LIFE = 4
-- Alliances' REQUEST_DURATION: 200 ticks at 10 Hz. The bar on the card runs
-- out on the same clock the server's timeout does.
local REQUEST_SECONDS = 20
-- After you answer a card, the private snapshot can still list the ask for a
-- beat (the server has not processed the answer yet); the card is not rebuilt
-- from it inside this window.
local ANSWER_GRACE = 2

-- ====================================================================== state ==

local yourId = 0
local myTeam: number? = nil
local names: { [number]: string } = {}
local userIds: { [number]: number } = {}
local alive: { [number]: boolean } = {}
local isBot: { [number]: boolean } = {}
local teamOf: { [number]: number? } = {}
local spawnedIds: { number } = {}
local allies: { [number]: boolean } = {}
local allyLeft: { [number]: number } = {}
local expiring: { [number]: any } = {}
local embargo: { [number]: boolean } = {}
local traitors: { [number]: boolean } = {}
local outreq: { [number]: boolean } = {}
local inreq: { [number]: boolean } = {}
local declinedAt: { [number]: number } = {}
local waitAt: { [number]: number } = {}
local answeredAt: { [number]: number } = {}
local askedAt: { [number]: number } = {}
local breakArmedAt: { [number]: number } = {}
local breakSentAt: { [number]: number } = {}
local phase = ""
local open = false

-- ================================================================== helpers ==

-- Authored pixels -> Scale, read against the DIRECT parent's reference
-- footprint (the HUD's own primitive).
local function place(inst: GuiObject, pw: number, ph: number, x: number, y: number, w: number, h: number)
	inst.Size = UDim2.fromScale(w / pw, h / ph)
	inst.Position = UDim2.fromScale(x / pw, y / ph)
end

-- Text is TextScaled inside a box whose height IS the type size, capped so a
-- big window does not blow it up (the HUD's rule).
local function label(parent: Instance, name: string, font: Font, size: number, color: Color3): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.FontFace = font
	t.TextColor3 = color
	t.TextScaled = true
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Center
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = size
	cap.Parent = t
	t.Parent = parent
	return t
end

local function button(parent: Instance, name: string, size: number): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.FontFace = FONT_DISPLAY
	b.TextScaled = true
	b.Active = true
	b.Selectable = true
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = size
	cap.Parent = b
	b.Parent = parent
	return b
end

-- EVERY BUTTON ANSWERS THE CURSOR (owner: "buttons should all have hover
-- effects"). A short tween each way rather than an entry in the frame loop:
-- these are pressed a handful of times a round.
local function hoverable(b: GuiButton, base: UDim2)
	b.MouseEnter:Connect(function()
		if not b.Active then
			return
		end
		Sfx.play("Click", { volume = 0.12, pitch = 1.7 })
		TweenService:Create(b, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.fromScale(base.X.Scale * (1 + BTN_HOVER_GROW), base.Y.Scale * (1 + BTN_HOVER_GROW)),
		}):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(b, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = base }):Play()
	end)
end

local function isPlayerRow(id: number): boolean
	if id == yourId or alive[id] ~= true then
		return false
	end
	-- Whoever you are ALLIED with, or who has ASKED you, is a row whatever the
	-- wire calls them: an alliance a bot opened (/gotrequest, or an AI that
	-- asks one day) has to be somewhere you can break it.
	if allies[id] or inreq[id] then
		return true
	end
	return isBot[id] ~= true
		and (myTeam == nil or teamOf[id] ~= myTeam)
end

local function colorOf(id: number): Color3
	local ok, c = pcall(Palette.playerColor3, id, yourId)
	if ok and typeof(c) == "Color3" then
		return c
	end
	return INK_DIM
end

local function nameOf(id: number): string
	return names[id] or ("Empire " .. tostring(id))
end

local function send(t: string, id: number, extra: { [string]: any }?)
	local payload: { [string]: any } = { t = t, id = id }
	if extra ~= nil then
		for k, v in extra do
			payload[k] = v
		end
	end
	IntentRE:FireServer(payload)
end

local function mmss(ticks: number): string
	local s = math.max(0, math.floor(ticks / 10))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- THE STANDINGS BOARD'S DISC, rebuilt here line for line: the nation's colour
-- as a ring around the headshot (rbxthumb, resolved on the client with no web
-- call), and for an empire with no face -- a bot -- its initial on a filled
-- disc in its own colour, which reads as a flag rather than a broken image.
-- A UIAspectRatioConstraint is not optional: everything here is laid out in
-- Scale, and on any viewport that is not 16:9 a scale "square" is an egg.
local function avatar(parent: Instance, id: number, pw: number, ph: number, x: number, y: number, d: number, z: number): Frame
	local tint = colorOf(id)
	local av = Instance.new("Frame")
	av.Name = "Avatar"
	av.BorderSizePixel = 0
	av.BackgroundColor3 = tint
	av.ZIndex = z
	place(av, pw, ph, x, y, d, d)
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.DominantAxis = Enum.DominantAxis.Height
	ar.Parent = av
	local avr = Instance.new("UICorner")
	avr.CornerRadius = UDim.new(1, 0)
	avr.Parent = av

	local uid = userIds[id]
	local url = Faces.url(uid, 100)
	if url then
		local pic = Instance.new("ImageLabel")
		pic.Name = "Pic"
		pic.BackgroundColor3 = TRACK
		pic.BorderSizePixel = 0
		pic.ScaleType = Enum.ScaleType.Crop
		pic.Size = UDim2.fromScale(0.84, 0.84)
		pic.Position = UDim2.fromScale(0.08, 0.08)
		pic.Image = url
		pic.ZIndex = z + 1
		pic.Parent = av
		local picr = Instance.new("UICorner")
		picr.CornerRadius = UDim.new(1, 0)
		picr.Parent = pic
	else
		local ini = Instance.new("TextLabel")
		ini.Name = "Initial"
		ini.BackgroundTransparency = 1
		ini.FontFace = FONT_DISPLAY
		ini.TextScaled = true
		ini.TextColor3 = PANEL
		ini.Size = UDim2.fromScale(0.6, 0.6)
		ini.Position = UDim2.fromScale(0.2, 0.2)
		ini.Text = string.upper(string.sub(nameOf(id), 1, 1))
		ini.ZIndex = z + 1
		ini.Parent = av
	end
	av.Parent = parent
	return av
end

-- ====================================================================== build ==

-- ONLY THE IMAGE IS TAKEN FROM THE ART, never the instance -- the shop tab's
-- lesson: an `:IsA("ImageButton")` test failed SHUT when the owner swapped the
-- art to an ImageLabel. No error, just no tab.
local images = StarterGui:FindFirstChild("Images")
local art = images and images:FindFirstChild("Diplomacy")
local tabImage: string? = nil
if art ~= nil and (art:IsA("ImageLabel") or art:IsA("ImageButton")) then
	tabImage = (art :: any).Image
end
if tabImage == nil or tabImage == "" then
	warn("[Diplomacy] StarterGui.Images.Diplomacy is missing; no diplomacy tab.")
	return
end

local gui = Instance.new("ScreenGui")
gui.Name = "ConquestDiplomacy"
gui.Enabled = false
gui.ResetOnSpawn = false
-- The same inset rule as the shop's ScreenGui, or the two tabs' y fractions
-- would be measured from different tops and the pair would sit apart by the
-- topbar inset.
gui.IgnoreGuiInset = true
-- 4 is the band TutorialShopClient reserved for "the control that is always
-- available" (its DisplayOrder note has the whole ladder). Nothing here
-- overlaps the store, so sharing the number costs nothing.
gui.DisplayOrder = 4

-- ---- the tab --
local tab = Instance.new("ImageButton")
tab.Name = "DiplomacyTab"
tab.Image = tabImage
tab.AnchorPoint = Vector2.new(0, 0.5)
tab.Position = UDim2.fromScale(TAB_X, TAB_Y)
tab.Size = UDim2.fromScale(TAB_SIZE, TAB_SIZE)
tab.BackgroundTransparency = 1
tab.ScaleType = Enum.ScaleType.Fit
-- NO AutoButtonColor: it darkens the icon on press, a second animation arguing
-- with the dent the loop already spends.
tab.AutoButtonColor = false
tab.ZIndex = 10
local tabRatio = Instance.new("UIAspectRatioConstraint")
tabRatio.AspectRatio = TAB_RATIO
tabRatio.DominantAxis = Enum.DominantAxis.Height
tabRatio.Parent = tab
-- Selectable, so the controller's virtual cursor can land on it.
tab.Active = true
tab.Selectable = true
tab.Parent = gui

-- IT SAYS ALLIANCE (owner, 2026-09-18: "Make it say Alliance"), lettered by the
-- store's OWN header label so the two tabs are written in one hand, the way
-- SHOP is. Parented to the button, so it inherits the drift, the hover and the
-- press dent without its own entry in the loop.
--
-- WIDER THAN THE SHOP'S BOX, AND MEASURED: in GothamSSm Heavy "ALLIANCE" runs
-- 4.48x its height against SHOP's 2.52x, so in SHOP's 1.05-wide box it would
-- scale to 78% of SHOP's letter height and read as the smaller tab. The widest
-- box that keeps its left edge on screen is 1.27 icon-widths -- centred on the
-- icon at reference x 58, its edge lands 2 px from the screen's -- and there
-- the word scales to 95% of SHOP's height. Not 1.34, where the two would match
-- exactly, because that edge lands at -1.
local CAPTION_W = 1.27
local CAPTION_H = 0.3
local CAPTION_Y = 0.9

local storeArt = StarterGui:FindFirstChild("Store")
local wordSrc: Instance? = storeArt and storeArt:FindFirstChild("Frames")
wordSrc = wordSrc and wordSrc:FindFirstChild("Store")
wordSrc = wordSrc and wordSrc:FindFirstChild("Header")
wordSrc = wordSrc and wordSrc:FindFirstChild("Name")
if wordSrc ~= nil and wordSrc:IsA("TextLabel") then
	local word = wordSrc:Clone()
	word.Name = "TabWord"
	word.AnchorPoint = Vector2.new(0.5, 0)
	word.Position = UDim2.fromScale(0.5, CAPTION_Y)
	word.Size = UDim2.fromScale(CAPTION_W, CAPTION_H)
	word.TextXAlignment = Enum.TextXAlignment.Center
	word.TextScaled = true
	word.Visible = true
	word.ZIndex = 11
	word.Text = "ALLIANCE"
	word.Parent = tab
else
	warn("[Diplomacy] StarterGui.Store's header label is missing; the tab has no caption.")
end

-- ---- the panel --
local panel = Instance.new("Frame")
panel.Name = "AlliancePanel"
panel.BackgroundColor3 = PANEL
-- All but opaque, the HUD's own reason: a nation label is 400 px of near-white
-- text and it ghosts straight through anything lighter.
panel.BackgroundTransparency = 0.04
panel.BorderSizePixel = 0
panel.Active = true
panel.Visible = false
panel.AnchorPoint = Vector2.new(0, 0.5)
panel.ZIndex = 12
place(panel, REF_W, REF_H, PANEL_X, PANEL_Y + PANEL_H / 2, PANEL_W, PANEL_H)
panel.Parent = gui

local title = label(panel, "Title", FONT_DISPLAY, 16, INK)
title.Text = "ALLIANCES"
title.ZIndex = 13
place(title, PANEL_W, PANEL_H, ROW_PAD, 0, PANEL_W - ROW_PAD * 2 - 30, TITLE_H)

local closeBtn = button(panel, "Close", 16)
closeBtn.Text = "X"
closeBtn.BackgroundTransparency = 1
closeBtn.TextColor3 = INK_DIM
closeBtn.ZIndex = 13
place(closeBtn, PANEL_W, PANEL_H, PANEL_W - ROW_PAD - 24, (TITLE_H - 24) / 2, 24, 24)

local rule = Instance.new("Frame")
rule.Name = "Rule"
rule.BackgroundColor3 = LINE
rule.BorderSizePixel = 0
rule.ZIndex = 13
place(rule, PANEL_W, PANEL_H, 0, TITLE_H - 1, PANEL_W, 1)
rule.Parent = panel

-- THE ROWS ARE LAID OUT IN PIXELS. A ScrollingFrame cannot measure scale-sized
-- children for its canvas (the trap TutorialShopClient's store fell into), so
-- each row is sized from the list's AbsoluteSize at rebuild and the canvas is
-- set to the sum. Rebuilt again whenever that size changes.
local list = Instance.new("ScrollingFrame")
list.Name = "List"
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 4
list.ScrollBarImageColor3 = LINE
list.ScrollingDirection = Enum.ScrollingDirection.Y
list.CanvasSize = UDim2.new()
list.ZIndex = 13
place(list, PANEL_W, PANEL_H, 0, TITLE_H, PANEL_W, PANEL_H - TITLE_H)
list.Parent = panel

local empty = label(panel, "Empty", FONT_UI, 13, INK_OFF)
empty.Text = "NO PLAYERS TO ALLY WITH"
empty.TextXAlignment = Enum.TextXAlignment.Center
empty.ZIndex = 13
empty.Visible = false
place(empty, PANEL_W, PANEL_H, ROW_PAD, TITLE_H + 20, PANEL_W - ROW_PAD * 2, 16)

-- ---- the cards' holder, and the toast above them --
local cardsHolder = Instance.new("Folder")
cardsHolder.Name = "Requests"
cardsHolder.Parent = gui

local toastLabel = label(gui, "Toast", FONT_DISPLAY, 13, INK)
toastLabel.TextXAlignment = Enum.TextXAlignment.Right
toastLabel.AnchorPoint = Vector2.new(1, 1)
toastLabel.ZIndex = 22
toastLabel.Visible = false
toastLabel.Size = UDim2.fromScale(TOAST_W / REF_W, TOAST_H / REF_H)
local toastToken = 0

-- ==================================================================== the rows ==

type Row = { frame: Frame, btn: TextButton, side: TextButton, tag: TextLabel, id: number }
local rows: { Row } = {}

local function paintRow(r: Row)
	local id = r.id
	local b, side = r.btn, r.side
	local now = os.clock()

	-- The main button.
	local text, bg, ink, active = "ALLIANCE", PRESS, ON_PRESS, true
	if allies[id] then
		local ex = expiring[id]
		if ex ~= nil then
			if ex.mine then
				text, bg, ink, active = "RENEWING", PANEL_HI, INK_OFF, false
			else
				text = "RENEW"
			end
		else
			text, bg, ink, active = "ALLIED " .. mmss(allyLeft[id] or 0), PANEL_HI, GAIN, false
		end
	elseif inreq[id] then
		text = "ACCEPT"
	elseif outreq[id] then
		-- "REQUEST SENT", not "SENT" (owner, 2026-09-18): on its own the word
		-- read as a verb on a button still waiting to be pressed.
		text, bg, ink, active = "REQUEST SENT", PANEL_HI, INK_OFF, false
	elseif (declinedAt[id] or -1e9) > now - DECLINED_HOLD then
		text, bg, ink, active = "DECLINED", PANEL_HI, THREAT, false
	elseif (waitAt[id] or -1e9) > now - WAIT_HOLD then
		text, bg, ink, active = "WAIT", PANEL_HI, INK_OFF, false
	end
	b.Text = text
	b.BackgroundColor3 = bg
	b.TextColor3 = ink
	b.Active = active
	b.Selectable = active

	-- The side button: BREAK on an ally, EMBARGO on everyone else.
	local stext, sbg, sink = "EMBARGO", PANEL_HI, INK_OFF
	if allies[id] then
		-- RED (owner, 2026-09-18: "make the button red, so players notice
		-- it"): the one press on this panel you cannot take back wears the
		-- HUD's threat colour, and SURE? inverts it so the second press reads
		-- as a different button rather than the same one again.
		if (breakArmedAt[id] or -1e9) > now - BREAK_ARM then
			stext, sbg, sink = "SURE?", INK, THREAT
		else
			stext, sbg, sink = "BREAK", THREAT, INK
		end
	elseif embargo[id] then
		stext, sbg, sink = "LIFT", PANEL_HI, THREAT
	end
	side.Text = stext
	side.BackgroundColor3 = sbg
	side.TextColor3 = sink

	-- The mark everybody can see.
	r.tag.Visible = traitors[id] == true
end

local function paintRows()
	for _, r in rows do
		paintRow(r)
	end
end

-- Allies first, then whoever asked you, then the rest by name -- the rows
-- you can act on rise, the ones already settled sit on top as a record.
local function rowIds(): { number }
	local ids = {}
	for _, id in spawnedIds do
		if isPlayerRow(id) then
			table.insert(ids, id)
		end
	end
	table.sort(ids, function(a, b)
		local ra = (allies[a] and 0) or (inreq[a] and 1) or 2
		local rb = (allies[b] and 0) or (inreq[b] and 1) or 2
		if ra ~= rb then
			return ra < rb
		end
		return nameOf(a):lower() < nameOf(b):lower()
	end)
	return ids
end

-- What the list was last built from. REBUILDING IS DESTRUCTIVE -- every row
-- and every button is thrown away and made again -- so it happens only when
-- this changes. The first build ran on every `players` broadcast, five times
-- a second, and the button under the cursor was replaced between the press
-- and the release, so Activated never fired (owner, 2026-09-18: "the button
-- is really hard to press").
local rowSig = ""

local function rebuild()
	for _, r in rows do
		r.frame:Destroy()
	end
	table.clear(rows)

	local ids = rowIds()
	rowSig = table.concat(ids, ",")

	empty.Visible = #ids == 0

	local s = list.AbsoluteSize.X / PANEL_W
	local rowPx = ROW_H * s
	local nameX = ROW_PAD + AVATAR_D + 8
	local nameW = PANEL_W - nameX - 8 - SIDE_W - 8 - BTN_W - ROW_PAD
	for k, id in ids do
		local f = Instance.new("Frame")
		f.Name = "Row" .. id
		f.BackgroundColor3 = PANEL_HI
		f.BackgroundTransparency = k % 2 == 0 and 0.6 or 1
		f.BorderSizePixel = 0
		f.Size = UDim2.fromOffset(list.AbsoluteSize.X, rowPx)
		f.Position = UDim2.fromOffset(0, (k - 1) * rowPx)
		f.ZIndex = 14

		avatar(f, id, PANEL_W, ROW_H, ROW_PAD, (ROW_H - AVATAR_D) / 2, AVATAR_D, 15)

		local nm = label(f, "Name", FONT_UI, 14, INK)
		nm.Text = nameOf(id)
		nm.TextTruncate = Enum.TextTruncate.AtEnd
		nm.ZIndex = 15
		place(nm, PANEL_W, ROW_H, nameX, 2, nameW, ROW_H - 14)

		-- TRAITOR, in red under the name, for the 30 s the mark lasts.
		local tag = label(f, "Tag", FONT_DISPLAY, 9, THREAT)
		tag.Text = "TRAITOR"
		tag.ZIndex = 15
		tag.Visible = false
		place(tag, PANEL_W, ROW_H, nameX, ROW_H - 14, nameW, 11)

		local side = button(f, "Side", 11)
		side.AnchorPoint = Vector2.new(0.5, 0.5)
		side.ZIndex = 15
		place(side, PANEL_W, ROW_H, PANEL_W - ROW_PAD - BTN_W - 8 - SIDE_W / 2, ROW_H / 2, SIDE_W, BTN_H)
		hoverable(side, side.Size)

		local b = button(f, "Ally", 12)
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.ZIndex = 15
		place(b, PANEL_W, ROW_H, PANEL_W - ROW_PAD - BTN_W / 2, ROW_H / 2, BTN_W, BTN_H)
		hoverable(b, b.Size)

		local r: Row = { frame = f, btn = b, side = side, tag = tag, id = id }
		paintRow(r)

		b.Activated:Connect(function()
			if not b.Active then
				return
			end
			Sfx.play("Click")
			if allies[id] then
				-- RENEW: registers your half; the clock resets when both are in.
				local ex = expiring[id]
				if ex ~= nil and not ex.mine then
					ex.mine = true
					send("renew", id)
				end
			elseif not outreq[id] then
				-- One intent for both halves: asking somebody who has asked YOU
				-- is how you accept.
				if inreq[id] then
					answeredAt[id] = os.clock()
					inreq[id] = nil
				end
				outreq[id] = true
				askedAt[id] = os.clock()
				send("ally", id)
			end
			paintRow(r)
		end)
		side.Activated:Connect(function()
			Sfx.play("Click")
			local now = os.clock()
			if allies[id] then
				-- TWO PRESSES TO BETRAY, like the LEAVE button: the one press
				-- on this panel you cannot take back does not sit under a slip.
				if (breakArmedAt[id] or -1e9) > now - BREAK_ARM then
					breakArmedAt[id] = nil
					breakSentAt[id] = now
					send("unally", id)
				else
					breakArmedAt[id] = now
				end
			else
				local stop = embargo[id] == true
				embargo[id] = not stop
				send("embargo", id, { stop = stop })
			end
			paintRow(r)
		end)
		table.insert(rows, r)
		f.Parent = list
	end
	list.CanvasSize = UDim2.fromOffset(0, #ids * rowPx)
end

-- The cheap path: repaint in place, and rebuild only if the membership or
-- the order actually moved.
local function refreshRows()
	if not open then
		return
	end
	if table.concat(rowIds(), ",") ~= rowSig then
		rebuild()
	else
		paintRows()
	end
end

list:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	if panel.Visible then
		rebuild()
	end
end)

-- ==================================================================== the cards ==

type Card = { frame: Frame, id: number, bar: Frame, tween: Tween? }
local cards: { Card } = {}

local function stackTop(): number
	return CARD_Y0 - #cards * (CARD_H + CARD_GAP)
end

local function placeToast()
	toastLabel.Position = UDim2.fromScale((REF_W - 14) / REF_W, (stackTop() + CARD_H - 4) / REF_H)
end

local function layoutCards()
	for k, c in cards do
		local y = CARD_Y0 - (k - 1) * (CARD_H + CARD_GAP)
		TweenService:Create(c.frame, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromScale(CARD_X / REF_W, y / REF_H),
		}):Play()
	end
	placeToast()
end

-- A LINE, NOT A PANEL: "X BETRAYED YOU", "ALLIANCE WITH X EXPIRED". Sits above
-- the card stack, four seconds, the newest replaces the last.
local function toast(text: string, color: Color3)
	toastToken += 1
	local token = toastToken
	toastLabel.Text = text
	toastLabel.TextColor3 = color
	toastLabel.TextTransparency = 0
	toastLabel.Visible = true
	placeToast()
	task.delay(TOAST_LIFE - 0.5, function()
		if token ~= toastToken then
			return
		end
		local fade = TweenService:Create(toastLabel, TweenInfo.new(0.5), { TextTransparency = 1 })
		fade.Completed:Connect(function()
			if token == toastToken then
				toastLabel.Visible = false
			end
		end)
		fade:Play()
	end)
end

local function findCard(id: number): (Card?, number?)
	for k, c in cards do
		if c.id == id then
			return c, k
		end
	end
	return nil, nil
end

local function removeCard(id: number)
	local c, k = findCard(id)
	if c == nil or k == nil then
		return
	end
	table.remove(cards, k)
	if c.tween ~= nil then
		c.tween:Cancel()
	end
	local f = c.frame
	f.Active = false
	for _, d in f:GetDescendants() do
		if d:IsA("GuiButton") then
			d.Active = false
			d.Selectable = false
		end
	end
	-- Slides out the way it came, then goes.
	local out = TweenService:Create(f, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Position = UDim2.fromScale((CARD_X + 40) / REF_W, f.Position.Y.Scale),
		BackgroundTransparency = 1,
	})
	out.Completed:Connect(function()
		f:Destroy()
	end)
	out:Play()
	layoutCards()
end

local function addCard(id: number)
	if findCard(id) ~= nil then
		return
	end
	local k = #cards + 1
	local y = CARD_Y0 - (k - 1) * (CARD_H + CARD_GAP)

	local f = Instance.new("Frame")
	f.Name = "Request" .. id
	f.BackgroundColor3 = PANEL
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Active = true
	f.ZIndex = 20
	place(f, REF_W, REF_H, CARD_X + 40, y, CARD_W, CARD_H)

	avatar(f, id, CARD_W, CARD_H, 12, 10, CARD_FACE, 21)

	local textX = 12 + CARD_FACE + 10
	local cap = label(f, "Caption", FONT_UI, 11, INK_OFF)
	-- A traitor asking is told on the card, in the mark's own colour.
	if traitors[id] then
		cap.Text = "ALLIANCE REQUEST  -  TRAITOR"
		cap.TextColor3 = THREAT
	else
		cap.Text = "ALLIANCE REQUEST"
	end
	cap.ZIndex = 21
	place(cap, CARD_W, CARD_H, textX, 10, CARD_W - textX - 12, 12)

	local who = label(f, "Who", FONT_DISPLAY, 18, colorOf(id))
	who.Text = nameOf(id)
	who.TextTruncate = Enum.TextTruncate.AtEnd
	who.ZIndex = 21
	place(who, CARD_W, CARD_H, textX, 26, CARD_W - textX - 12, 22)

	local bw = (CARD_W - 12 * 2 - 8) / 2
	local yes = button(f, "Accept", 13)
	yes.Text = "ACCEPT"
	yes.BackgroundColor3 = PRESS
	yes.TextColor3 = ON_PRESS
	yes.ZIndex = 21
	yes.AnchorPoint = Vector2.new(0.5, 0.5)
	place(yes, CARD_W, CARD_H, 12 + bw / 2, 56 + 14, bw, 28)
	hoverable(yes, yes.Size)

	local no = button(f, "Decline", 13)
	no.Text = "DECLINE"
	no.BackgroundColor3 = PANEL_HI
	no.TextColor3 = INK_DIM
	no.ZIndex = 21
	no.AnchorPoint = Vector2.new(0.5, 0.5)
	place(no, CARD_W, CARD_H, 12 + bw + 8 + bw / 2, 56 + 14, bw, 28)
	hoverable(no, no.Size)

	-- The time left to answer, as a bar running out along the foot of the
	-- card on the same 20 s the server gives it.
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BackgroundColor3 = PRESS
	bar.BorderSizePixel = 0
	bar.ZIndex = 21
	place(bar, CARD_W, CARD_H, 0, CARD_H - 3, CARD_W, 3)
	bar.Parent = f

	local c: Card = { frame = f, id = id, bar = bar, tween = nil }
	table.insert(cards, c)
	f.Parent = cardsHolder

	yes.Activated:Connect(function()
		if not yes.Active then
			return
		end
		Sfx.play("Click")
		answeredAt[id] = os.clock()
		inreq[id] = nil
		outreq[id] = true
		send("ally", id)
		removeCard(id)
		paintRows()
	end)
	no.Activated:Connect(function()
		if not no.Active then
			return
		end
		Sfx.play("Click")
		answeredAt[id] = os.clock()
		inreq[id] = nil
		send("allyno", id)
		removeCard(id)
		paintRows()
	end)

	-- In from the right edge, with the sound of something landing.
	Sfx.play("Click", { pitch = 1.25 })
	TweenService:Create(f, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(CARD_X / REF_W, y / REF_H),
		BackgroundTransparency = 0.04,
	}):Play()
	placeToast()
	local run = TweenService:Create(bar, TweenInfo.new(REQUEST_SECONDS, Enum.EasingStyle.Linear), {
		Size = UDim2.fromScale(0, 3 / CARD_H),
	})
	c.tween = run
	run.Completed:Connect(function(state)
		-- Ran out: the server has rejected it by now (its timeout is a
		-- rejection), and "rejected" will clear the row. The card goes here
		-- so it never outlives its own bar.
		if state == Enum.PlaybackState.Completed then
			inreq[id] = nil
			removeCard(id)
			paintRows()
		end
	end)
	run:Play()
end

local function clearCards()
	for i = #cards, 1, -1 do
		removeCard(cards[i].id)
	end
end

-- ================================================================= open/close ==

local function setOpen(on: boolean)
	if open == on then
		return
	end
	open = on
	if on then
		rebuild()
		panel.Visible = true
		-- Pops from the tab's side: 94% -> 100% with a little overshoot, a
		-- Size tween and not a UIScale (the lesson card's rule).
		local full = UDim2.fromScale(PANEL_W / REF_W, PANEL_H / REF_H)
		panel.Size = UDim2.fromScale(full.X.Scale * 0.94, full.Y.Scale * 0.94)
		TweenService:Create(panel, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = full }):Play()
	else
		panel.Visible = false
	end
end

-- ======================================================================= feel ==

local hover = 0
local hovered = false
local punch = 0
local calm = 0

tab.MouseEnter:Connect(function()
	if not hovered then
		hovered = true
		Sfx.play("Click", { volume = 0.18, pitch = 1.6 })
	end
end)
tab.MouseLeave:Connect(function()
	hovered = false
end)
tab.Activated:Connect(function()
	punch = 1
	Sfx.play("Click")
	setOpen(not open)
end)
closeBtn.Activated:Connect(function()
	punch = 1
	Sfx.play("Click")
	setOpen(false)
end)
hoverable(closeBtn, closeBtn.Size)

-- ONE loop, and it returns immediately while the tab is down. Everything
-- animated every frame is written here and nowhere else.
local clock = 0
local repaintIn = 0
RunService.RenderStepped:Connect(function(dt)
	if not gui.Enabled then
		return
	end
	clock += dt
	hover += ((hovered and 1 or 0) - hover) * math.min(1, dt * HOVER_RATE)
	punch = math.max(0, punch - dt * 4)
	calm += ((open and 1 or 0) - calm) * math.min(1, dt * 6)

	local idle = 1 - calm * (1 - TAB_OPEN_CALM)
	local breathe = math.sin(clock * TAB_BREATHE_HZ * math.pi * 2 + TAB_PHASE) * TAB_BREATHE * idle
	local s = TAB_SIZE * (1 + breathe + TAB_HOVER_GROW * hover - TAB_PUNCH_DENT * punch)
	tab.Size = UDim2.fromScale(s, s)
	tab.Rotation = math.sin(clock * TAB_SWING_HZ * math.pi * 2 + TAB_PHASE) * TAB_SWING * idle * (1 - 0.7 * hover)

	-- DECLINED, WAIT and SURE? time out on their own, and the ally clocks
	-- tick; twice a second is plenty, and only while anyone is looking.
	if open then
		repaintIn -= dt
		if repaintIn <= 0 then
			repaintIn = 0.5
			paintRows()
		end
	end
end)

-- ============================================================= when it shows ==

-- `tutorialServer` latches and is never cleared; `known` flips the first time
-- any message says which kind of round this is. Shown only when both agree.
local tutorialServer = false
local known = false

local function refresh()
	local show = known and not tutorialServer
	if gui.Enabled ~= show then
		gui.Enabled = show
	end
end

local function latchTutorial()
	tutorialServer = true
	known = true
end

if ReplicatedStorage:GetAttribute(Matchmaker.LOCAL_TUTORIAL_ATTR) == true then
	latchTutorial()
end

-- ================================================================== messages ==

local function applyRoster(listIn: any)
	if type(listIn) ~= "table" then
		return
	end
	for _, e in listIn do
		if type(e) == "table" and typeof(e.i) == "number" then
			names[e.i] = tostring(e.n or "")
			-- `u` is the Roblox user id (absent on bots); a faux player has
			-- one and so gets a real face here for free, as on the standings.
			userIds[e.i] = if typeof(e.u) == "number" and e.u ~= 0 then e.u else nil
		end
	end
	for _, c in cards do
		local who = c.frame:FindFirstChild("Who")
		if who and who:IsA("TextLabel") then
			who.Text = nameOf(c.id)
		end
	end
end

local function toSet(arr: any): { [number]: boolean }
	local out = {}
	if type(arr) == "table" then
		for _, v in arr do
			if typeof(v) == "number" then
				out[v] = true
			end
		end
	end
	return out
end

-- THE MAP (owner, 2026-09-18: "use handshake and broken heart on the map to
-- represent betrayal and allies"): a handshake over every ally, a broken heart
-- over every marked traitor, yourself included. Traitor wins on an empire that
-- is both -- an ally who just stabbed somebody else is the thing worth seeing.
local function syncMarks()
	for _, id in spawnedIds do
		local kind = if traitors[id] then "traitor" elseif allies[id] then "ally" else nil
		NationLabels.setMark(id, kind)
	end
end

-- The private snapshot is the truth; the events are how it is animated. Cards
-- are reconciled against it so an ask that arrived before this script did,
-- or one whose "request" message was missed, still lands.
local function applySnapshot(d: any)
	allies = toSet(d.allies)
	outreq = toSet(d.outreq)
	-- A snapshot computed before the press reached the server would clear
	-- REQUEST SENT for one beat and then put it back; the press stands for a
	-- second, which is the same grace an answered card gets.
	for id, at in askedAt do
		if at > os.clock() - 1 then
			outreq[id] = true
		end
	end
	embargo = toSet(d.embargo)
	traitors = toSet(d.traitors)
	table.clear(allyLeft)
	if type(d.left) == "table" then
		for k, v in d.left do
			local id = tonumber(k)
			if id ~= nil and typeof(v) == "number" then
				allyLeft[id] = v
			end
		end
	end
	table.clear(expiring)
	if type(d.expiring) == "table" then
		for _, e in d.expiring do
			if type(e) == "table" and typeof(e.id) == "number" then
				expiring[e.id] = e
			end
		end
	end
	local now = os.clock()
	local incoming = toSet(d.inreq)
	for id in incoming do
		if (answeredAt[id] or -1e9) < now - ANSWER_GRACE then
			inreq[id] = true
			if findCard(id) == nil then
				addCard(id)
			end
		end
	end
	for id in inreq do
		if not incoming[id] then
			inreq[id] = nil
			removeCard(id)
		end
	end
	syncMarks()
	if open then
		paintRows()
	end
end

local function onAlly(p: any)
	if type(p) ~= "table" then
		return
	end
	local k = p.k
	local id = tonumber(p.id)
	if id == nil then
		return
	end
	if type(p.name) == "string" and p.name ~= "" then
		names[id] = p.name
	end
	local who = nameOf(id)
	local reorder = false
	if k == "request" then
		if (answeredAt[id] or -1e9) < os.clock() - ANSWER_GRACE then
			inreq[id] = true
			addCard(id)
		end
		reorder = true
	elseif k == "sent" then
		outreq[id] = true
	elseif k == "allied" then
		allies[id] = true
		outreq[id] = nil
		inreq[id] = nil
		removeCard(id)
		Sfx.play("Click", { pitch = 1.4 })
		toast("ALLIED WITH " .. string.upper(who), GAIN)
		reorder = true
	elseif k == "rejected" then
		if outreq[id] then
			declinedAt[id] = os.clock()
			Sfx.play("Deny")
		end
		outreq[id] = nil
		inreq[id] = nil
		removeCard(id)
		reorder = true
	elseif k == "expired" then
		allies[id] = nil
		expiring[id] = nil
		toast("ALLIANCE WITH " .. string.upper(who) .. " EXPIRED", INK_OFF)
		reorder = true
	elseif k == "broke" then
		allies[id] = nil
		expiring[id] = nil
		-- `mine` is the server's word for "you were the breaker" (the event's
		-- requestor side); the local stamp is only the belt to its braces.
		if p.mine or (breakSentAt[id] or -1e9) > os.clock() - 5 then
			toast("YOU BROKE WITH " .. string.upper(who), INK_OFF)
		else
			Sfx.play("Deny")
			toast(string.upper(who) .. " BETRAYED YOU", THREAT)
		end
		reorder = true
	elseif k == "renewed" then
		expiring[id] = nil
		toast("ALLIANCE WITH " .. string.upper(who) .. " RENEWED", GAIN)
	elseif k == "wantsrenew" then
		-- Both sides hear this; `mine` marks the one who pressed, whose row
		-- already reads RENEWING. For the other, theirs is in and yours is
		-- not, and the row's RENEW is the answer.
		local ex = expiring[id]
		if p.mine then
			if ex ~= nil then
				ex.mine = true
			end
		else
			if ex ~= nil then
				ex.theirs = true
			end
			toast(string.upper(who) .. " WANTS TO RENEW", INK)
		end
	elseif k == "traitor" then
		traitors[id] = true
		if id ~= yourId then
			toast(string.upper(who) .. " IS A TRAITOR", THREAT)
		end
	elseif k == "embargo" then
		if p.mine then
			embargo[id] = true
		else
			toast(string.upper(who) .. " EMBARGOED YOUR TRADE", INK_OFF)
		end
	elseif k == "unembargo" then
		if p.mine then
			embargo[id] = nil
		else
			toast(string.upper(who) .. " LIFTED THEIR EMBARGO", INK_OFF)
		end
	elseif k == "refused" then
		outreq[id] = nil
		if p.why == "alreadyallied" then
			allies[id] = true
		elseif p.why == "allycooldown" or p.why == "notaplayer" or p.why == "dead" then
			waitAt[id] = os.clock()
		end
	end
	syncMarks()
	-- Allied and asked rows change ORDER, not just paint; refreshRows tells.
	if reorder then
		refreshRows()
	elseif open then
		paintRows()
	end
end

StateRE.OnClientEvent:Connect(function(kind, payload)
	local p: any = payload
	if kind == "init" then
		-- The student's card rides with `init` as a TABLE; everyone else gets
		-- no field at all.
		if type(p) == "table" and p.tutorial ~= nil then
			latchTutorial()
		else
			known = true
		end
		if type(p) == "table" then
			yourId = tonumber(p.yourId) or 0
			phase = tostring(p.phase or "")
			-- A new round forgets the last one's diplomacy.
			table.clear(allies)
			table.clear(allyLeft)
			table.clear(expiring)
			table.clear(embargo)
			table.clear(traitors)
			table.clear(outreq)
			table.clear(inreq)
			table.clear(declinedAt)
			table.clear(waitAt)
			table.clear(answeredAt)
			table.clear(askedAt)
			table.clear(breakArmedAt)
			table.clear(breakSentAt)
			NationLabels.clearMarks()
			clearCards()
			setOpen(false)
			applyRoster(p.roster)
		end
	elseif kind == "roster" then
		applyRoster(p)
		return
	elseif kind == "players" then
		if typeof(p) == "buffer" then
			local ok, arr = pcall(Net.unpackPlayers, p)
			if ok and type(arr) == "table" then
				spawnedIds = {}
				for _, e in arr do
					alive[e.id] = e.alive
					isBot[e.id] = e.isBot
					teamOf[e.id] = e.team
					table.insert(spawnedIds, e.id)
				end
				myTeam = teamOf[yourId]
				refreshRows()
			end
		end
		return
	elseif kind == "fronts" then
		if type(p) == "table" and type(p.diplo) == "table" then
			applySnapshot(p.diplo)
		end
		return
	elseif kind == "ally" then
		onAlly(p)
		return
	elseif kind == "tutorial" then
		-- NOT A SIGNAL ANY MORE (2026-09-18). A lesson card also arrives in a
		-- REAL match: the lite lesson a player who followed a friend in is
		-- dealt (ConquestServer.followTakeover) sends three of them, and the
		-- latch hid the tab for the rest of that match. Whether this server
		-- is a tutorial is the server's word alone -- `init.tutorial` and the
		-- repeating `phase.tutorial`, both read off tutorialSession.
		return
	elseif kind == "phase" then
		-- A BOOLEAN on the repeating stats broadcast; absent on the plain
		-- phase-change message, which says nothing either way.
		if type(p) == "table" then
			if p.phase ~= nil then
				phase = tostring(p.phase)
			end
			if p.tutorial ~= nil then
				if p.tutorial == true then
					latchTutorial()
				else
					known = true
				end
			end
		end
	elseif kind == "win" then
		phase = "ended"
		setOpen(false)
		clearCards()
	else
		return
	end
	refresh()
end)

refresh()
gui.Parent = playerGui
