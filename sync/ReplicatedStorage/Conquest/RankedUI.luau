--!strict
-- Conquest :: RankedUI  (client, lobby)
--
-- The RANKED sheet: your emblem and rating, the 1V1 / 2V2 / 4V4 picker, FIND
-- MATCH, your party, the people in this server you can invite, and the whole
-- ladder along the foot with what each rank pays. Plus the one piece that
-- lives OUTSIDE the sheet: an incoming party invite, which has to reach a
-- player who never opened it.
--
-- Drawn in the lobby page's own kit (LobbyUI.kit) at its 1280x720 reference,
-- every size in Scale. The server owns every rule (RankedLobby); this only
-- draws the "state" it is sent and reports presses.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local LobbyUI = require(Shared.LobbyUI)
local Ranked = require(Shared.Ranked)
local RankEmblems = require(Shared.RankEmblems)
local Patterns = require(Shared.Patterns)

local kit = LobbyUI.kit
local place, setText = kit.place, kit.setText

-- EVERY LABEL IN THE SHEET IS OUTLINED (owner, 2026-10-05: "add a ui
-- stroke"): a dark contextual stroke under the text, so coloured rank names
-- and dim figures still read over the violet highlight and the slabs.
local function label(...): TextLabel
	local t = kit.label(...)
	local st = Instance.new("UIStroke")
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	st.Color = Color3.new(0, 0, 0)
	st.Thickness = 1.5
	st.Transparency = 0.25
	st.Parent = t
	return t
end
local pillButton, roundOff, grower, tween = kit.pillButton, kit.roundOff, kit.grower, kit.tween

local REF_W, REF_H = kit.REF_W, kit.REF_H
local PW, PH = 900, 560
local PX, PY = (REF_W - PW) / 2, (REF_H - PH) / 2 + 6

local GOLD = kit.GOLD
local INK, INK_DIM, INK_OFF = kit.INK, kit.INK_DIM, kit.INK_OFF
local SLAB = Color3.fromRGB(11, 15, 25)
local PILL_OFF = Color3.fromRGB(38, 43, 56)
local VIOLET = Color3.fromRGB(86, 40, 150)
local VIOLET_LINE = Color3.fromRGB(196, 140, 255)
local RED = Color3.fromRGB(168, 40, 46)
local RED_LINE = Color3.fromRGB(232, 96, 96)

local OPEN = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local SHUT = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local RankedUI = {}
RankedUI.__index = RankedUI

local function slab(parent: Instance, name: string, pw: number, ph: number, x: number, y: number, w: number, h: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundColor3 = SLAB
	f.BackgroundTransparency = 0.1
	f.BorderSizePixel = 0
	place(f, pw, ph, x, y, w, h)
	f.Parent = parent
	roundOff(f, 10)
	local st = Instance.new("UIStroke")
	st.Color = kit.LINE
	st.Thickness = 1.4
	st.Transparency = 0.45
	st.Parent = f
	return f
end

local function emblem(parent: Instance, name: string, pw: number, ph: number, x: number, y: number, s: number, index: number): ImageLabel?
	local img = RankEmblems.image(parent, name, RankEmblems.ORDER[index] or "recruit")
	if img then
		place(img, pw, ph, x, y, s, s)
		img.ZIndex = 4
	end
	return img
end

local function setEmblem(img: ImageLabel?, index: number)
	if not img then
		return
	end
	local e = RankEmblems.editable(RankEmblems.ORDER[index] or "recruit")
	if e then
		img.ImageContent = Content.fromObject(e)
	end
end

local function short(n: number): string
	if n >= 1000 then
		local k = n / 1000
		return (k == math.floor(k) and string.format("%dK", k) or string.format("%.1fK", k))
	end
	return tostring(n)
end

local function mmss(s: number): string
	s = math.max(0, math.floor(s))
	return string.format("%d:%02d", s // 60, s % 60)
end

function RankedUI.new(screen: ScreenGui, onLeaveBoard: (() -> ())?)
	local self = setmetatable({}, RankedUI) :: any
	self.remote = (ReplicatedStorage:WaitForChild("ConquestRanked") :: Folder):WaitForChild("Ranked") :: RemoteEvent
	self.onLeaveBoard = onLeaveBoard
	self.isOpen = false
	self.queuePick = "1v1"
	self.state = nil :: any
	local me = Players.LocalPlayer

	-- ---------------------------------------------------------------- sheet
	local shade = Instance.new("ImageButton")
	shade.Name = "RankedShade"
	shade.Image = ""
	shade.AutoButtonColor = false
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = Color3.fromRGB(4, 6, 11)
	shade.BackgroundTransparency = 1
	shade.BorderSizePixel = 0
	shade.Visible = false
	shade.ZIndex = 20
	shade.Parent = screen
	shade.Activated:Connect(function()
		self:close()
	end)
	self.shade = shade

	local panel = Instance.new("Frame")
	panel.Name = "RankedPanel"
	panel.BackgroundColor3 = kit.PANEL
	panel.BackgroundTransparency = 0.02
	panel.BorderSizePixel = 0
	panel.Active = true
	place(panel, REF_W, REF_H, PX, PY, PW, PH)
	panel.Parent = shade
	roundOff(panel, 12)
	local ps = Instance.new("UIStroke")
	ps.Color = VIOLET_LINE
	ps.Thickness = 1.6
	ps.Transparency = 0.35
	ps.Parent = panel
	local scrim = Instance.new("ImageLabel")
	scrim.Name = "Scrim"
	scrim.BackgroundTransparency = 1
	scrim.Image = kit.SCRIM
	scrim.ScaleType = Enum.ScaleType.Stretch
	scrim.ImageTransparency = 0.3
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.ZIndex = 0
	scrim.Parent = panel
	roundOff(scrim, 12)
	self.panelScale = grower(panel)

	kit.kitSet(kit.kitLabel(panel, "Title", PW, PH, 0, 16, PW, 42, VIOLET_LINE), "RANKED")
	local close = pillButton(panel, "Close", PW, PH, PW - 16 - 44, 16, 44, 44, "X", RED, RED_LINE)
	close.Activated:Connect(function()
		self:close()
	end)

	-- ------------------------------------------------------------ you card
	local card = slab(panel, "You", PW, PH, 24, 72, 270, 316)
	local CW, CH = 270, 316
	self.bigEmblem = emblem(card, "Emblem", CW, CH, (CW - 140) / 2, 14, 140, 1)
	self.rankName = kit.kitLabel(card, "RankName", CW, CH, 0, 160, CW, 34, GOLD)
	self.rating = label(card, "Rating", CW, CH, 0, 198, CW, 22, INK, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	local barBack = Instance.new("Frame")
	barBack.Name = "Bar"
	barBack.BackgroundColor3 = Color3.fromRGB(30, 36, 52)
	barBack.BorderSizePixel = 0
	place(barBack, CW, CH, 24, 232, CW - 48, 12)
	barBack.Parent = card
	roundOff(barBack, 6)
	-- Outlined like the sheet's text (owner, 2026-10-05: "add a ui stroke to
	-- the bar"), so the track reads against the card.
	local barStroke = Instance.new("UIStroke")
	barStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	barStroke.Color = Color3.new(0, 0, 0)
	barStroke.Thickness = 1.5
	barStroke.Transparency = 0.15
	barStroke.Parent = barBack
	local barFill = Instance.new("Frame")
	barFill.Name = "Fill"
	barFill.BackgroundColor3 = GOLD
	barFill.BorderSizePixel = 0
	barFill.Size = UDim2.fromScale(0, 1)
	barFill.Parent = barBack
	roundOff(barFill, 6)
	self.barFill = barFill
	-- No NEXT line (owner, 2026-10-05): the bar and the ladder strip below
	-- already say what comes next.
	self.record = label(card, "Record", CW, CH, 0, 264, CW, 18, INK_OFF, Enum.TextXAlignment.Center, kit.FONT_BOLD)

	-- ------------------------------------------------------- queue picker
	local RX, RW = 314, PW - 314 - 24
	self.queueButtons = {}
	local qw = (RW - 2 * 14) / 3
	for i, q in Ranked.QUEUES do
		local b = pillButton(panel, "Q" .. q.id, PW, PH, RX + (i - 1) * (qw + 14), 72, qw, 54, q.name)
		b.Activated:Connect(function()
			self.queuePick = q.id
			self:paint()
		end)
		self.queueButtons[q.id] = b
	end

	self.findButton = pillButton(panel, "Find", PW, PH, RX, 138, RW, 66, "FIND MATCH", VIOLET, VIOLET_LINE)
	self.findButton.Activated:Connect(function()
		local st = self.state
		if st and st.queue then
			self.remote:FireServer("cancel")
		else
			if self.onLeaveBoard then
				self.onLeaveBoard()
			end
			self.remote:FireServer("queue", self.queuePick)
		end
	end)
	self.findCaption = self.findButton:FindFirstChild("Caption") :: TextLabel

	-- -------------------------------------------------------------- party
	-- ONE BOX, full width (owner, 2026-10-05: "remove in this server section
	-- and put invite friends under the party tab"). Members sit in a 2x2 grid
	-- and INVITE FRIENDS runs along the foot. That button does both halves of
	-- getting a friend into the party: the server sends a party invite to
	-- every friend already in this server, and Roblox's invite sheet goes to
	-- the rest, tagged with this party (LaunchData) so they are invited to it
	-- the moment they arrive.
	local PBH = 172
	local party = slab(panel, "Party", PW, PH, RX, 216, RW, PBH)
	self.partyTitle = label(party, "Title", RW, PBH, 14, 8, RW - 28, 18, GOLD, Enum.TextXAlignment.Left, kit.FONT_BOLD)
	self.partyRows = {}
	local GW = (RW - 28 - 14) / 2
	for i = 1, Ranked.MAX_PARTY do
		local col = (i - 1) % 2
		local rowN = (i - 1) // 2
		local row = Instance.new("Frame")
		row.Name = "Member" .. i
		row.BackgroundTransparency = 1
		place(row, RW, PBH, 14 + col * (GW + 14), 34 + rowN * 38, GW, 32)
		row.Parent = party
		local em = emblem(row, "Emblem", GW, 32, 0, 1, 30, 1)
		local nm = label(row, "Name", GW, 32, 36, 7, GW - 36 - 68 - 52, 18, INK, Enum.TextXAlignment.Left, kit.FONT_BOLD)
		local rt = label(row, "Rating", GW, 32, GW - 68 - 50, 7, 44, 18, INK_DIM, Enum.TextXAlignment.Right, kit.FONT_BOLD)
		local act = pillButton(row, "Act", GW, 32, GW - 64, 2, 64, 28, "")
		act.Visible = false
		table.insert(self.partyRows, { row = row, emblem = em, name = nm, rating = rt, act = act, id = 0 })
		act.Activated:Connect(function()
			local entry = self.partyRows[i]
			if entry.id == me.UserId then
				self.remote:FireServer("leave")
			elseif entry.id ~= 0 then
				self.remote:FireServer("kick", entry.id)
			end
		end)
	end
	local friendBtn = pillButton(party, "Friends", RW, PBH, 14, PBH - 14 - 40, RW - 28, 40, "INVITE FRIENDS")
	friendBtn.Activated:Connect(function()
		self:openFriends()
	end)

	-- ------------------------------------------------------- friend sheet
	-- Over the right column. Friends who are IN THIS GAME come first (in your
	-- server, then elsewhere in Conquest); friends online elsewhere follow,
	-- greyed, with no invite. Found with Player:GetFriendsOnlineAsync -- one web
	-- call from this client, refreshed every FRIENDS_REFRESH s while open.
	local FH = 316
	local sheet = Instance.new("Frame")
	sheet.Name = "Friends"
	sheet.BackgroundColor3 = kit.PANEL
	sheet.BackgroundTransparency = 0
	sheet.BorderSizePixel = 0
	sheet.Active = true
	sheet.Visible = false
	sheet.ZIndex = 10
	place(sheet, PW, PH, RX, 72, RW, FH)
	sheet.Parent = panel
	roundOff(sheet, 10)
	local sst = Instance.new("UIStroke")
	sst.Color = VIOLET_LINE
	sst.Thickness = 1.6
	sst.Transparency = 0.3
	sst.Parent = sheet
	label(sheet, "Title", RW, FH, 14, 10, 300, 20, GOLD, Enum.TextXAlignment.Left, kit.FONT_BOLD).Text = "INVITE FRIENDS"
	local back = pillButton(sheet, "Back", RW, FH, RW - 14 - 84, 8, 84, 28, "BACK")
	back.Activated:Connect(function()
		self:closeFriends()
	end)
	self.friendRows = {}
	local FROWS = 6
	for i = 1, FROWS do
		local row = Instance.new("Frame")
		row.Name = "Friend" .. i
		row.BackgroundTransparency = 1
		place(row, RW, FH, 14, 44 + (i - 1) * 40, RW - 28, 36)
		row.Parent = sheet
		local RWi = RW - 28
		local em = emblem(row, "Emblem", RWi, 36, 0, 3, 30, 1)
		local nm = label(row, "Name", RWi, 36, 38, 2, RWi - 38 - 100 - 8, 18, INK, Enum.TextXAlignment.Left, kit.FONT_BOLD)
		local st = label(row, "Status", RWi, 36, 38, 21, RWi - 38 - 100 - 8, 13, INK_OFF, Enum.TextXAlignment.Left, kit.FONT_BOLD)
		local inv = pillButton(row, "Invite", RWi, 36, RWi - 96, 3, 96, 30, "INVITE", VIOLET, VIOLET_LINE)
		table.insert(self.friendRows, { row = row, emblem = em, name = nm, status = st, invite = inv, id = 0 })
		inv.Activated:Connect(function()
			local entry = self.friendRows[i]
			if entry.id ~= 0 then
				self.remote:FireServer("invite", entry.id)
				self.invited[entry.id] = os.clock()
				self:paintFriends()
			end
		end)
	end
	for _, d in sheet:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = math.max(d.ZIndex, 11)
		end
	end
	local fprev = pillButton(sheet, "Prev", RW, FH, RW / 2 - 70, FH - 38, 40, 28, "<")
	local fnext = pillButton(sheet, "Next", RW, FH, RW / 2 + 30, FH - 38, 40, 28, ">")
	self.friendPage = label(sheet, "Page", RW, FH, RW / 2 - 28, FH - 34, 56, 18, INK_DIM, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	self.friendEmpty = label(sheet, "Empty", RW, FH, 0, 130, RW, 18, INK_OFF, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	for _, b in { fprev, fnext } do
		b.ZIndex = 11
		for _, d in b:GetDescendants() do
			if d:IsA("GuiObject") then
				d.ZIndex = math.max(d.ZIndex, 11)
			end
		end
	end
	fprev.Activated:Connect(function()
		self.fpage = math.max(1, self.fpage - 1)
		self:paintFriends()
	end)
	fnext.Activated:Connect(function()
		self.fpage += 1
		self:paintFriends()
	end)
	self.friendSheet = sheet
	self.friendList = {}
	self.fpage = 1
	self.invited = {} :: { [number]: number }

	-- ------------------------------------------------------------ ladder
	local LY, LH = 400, PH - 400 - 18
	local ladder = slab(panel, "Ladder", PW, PH, 24, LY, PW - 48, LH)
	local LW = PW - 48
	local cw = LW / #Ranked.LADDER
	self.ladderCells = {}
	for i, rung in Ranked.LADDER do
		local cell = Instance.new("Frame")
		cell.Name = "Rung" .. i
		cell.BackgroundColor3 = VIOLET
		cell.BackgroundTransparency = 1
		cell.BorderSizePixel = 0
		place(cell, LW, LH, (i - 1) * cw + 3, 4, cw - 6, LH - 8)
		cell.Parent = ladder
		roundOff(cell, 8)
		local ring = Instance.new("UIStroke")
		ring.Name = "Ring"
		ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		ring.Color = VIOLET_LINE
		ring.Thickness = 2
		ring.Enabled = false
		ring.Parent = cell
		local CWi, CHi = cw - 6, LH - 8
		emblem(cell, "Emblem", CWi, CHi, (CWi - 54) / 2, 4, 54, i)
		local nm = label(cell, "Name", CWi, CHi, 0, 60, CWi, 15, rung.color, Enum.TextXAlignment.Center, kit.FONT_BOLD)
		nm.Text = string.upper(rung.name)
		-- The RR TOTAL the rank starts at (owner, 2026-10-05: "display the total
		-- number of RR needed for each rank"). RR is a running total, so this is
		-- the number on your own card when you reach it.
		local need = label(cell, "Need", CWi, CHi, 0, 77, CWi, 13, INK_DIM, Enum.TextXAlignment.Center, kit.FONT_BOLD)
		need.Text = tostring(rung.rr) .. " RR"
		local rw = label(cell, "Money", CWi, CHi, 0, 93, CWi, 13, kit.GAIN, Enum.TextXAlignment.Center, kit.FONT_BOLD)
		rw.Text = rung.money > 0 and ("$" .. short(rung.money)) or ""
		local def = rung.pattern and Patterns.byKey(rung.pattern)
		local pt = label(cell, "Pattern", CWi, CHi, 0, 109, CWi, 12, GOLD, Enum.TextXAlignment.Center, kit.FONT_BOLD)
		pt.Text = if def then (string.upper(def.name) .. " SKIN")
			elseif rung.passName then string.upper(rung.passName)
			else ""
		self.ladderCells[i] = cell
	end

	self.toast = label(panel, "Toast", PW, PH, 0, 58, PW, 14, GOLD, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	self.toastUntil = 0

	-- ------------------------------------------- incoming invite (outside)
	local pop = Instance.new("Frame")
	pop.Name = "RankedInvite"
	pop.BackgroundColor3 = kit.PANEL
	pop.BackgroundTransparency = 0.02
	pop.BorderSizePixel = 0
	pop.Visible = false
	pop.ZIndex = 30
	place(pop, REF_W, REF_H, (REF_W - 520) / 2, 18, 520, 64)
	pop.Parent = screen
	roundOff(pop, 10)
	local popStroke = Instance.new("UIStroke")
	popStroke.Color = VIOLET_LINE
	popStroke.Thickness = 1.6
	popStroke.Parent = pop
	self.popText = label(pop, "Text", 520, 64, 16, 10, 300, 22, INK, Enum.TextXAlignment.Left, kit.FONT_BOLD)
	label(pop, "Sub", 520, 64, 16, 34, 300, 16, INK_DIM, Enum.TextXAlignment.Left).Text = "RANKED PARTY INVITE"
	local accept = pillButton(pop, "Accept", 520, 64, 520 - 200, 12, 92, 40, "ACCEPT", VIOLET, VIOLET_LINE)
	local decline = pillButton(pop, "Decline", 520, 64, 520 - 100, 12, 88, 40, "NO")
	for _, d in pop:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = math.max(d.ZIndex, 31)
		end
	end
	self.pop = pop
	self.popFrom = 0
	accept.Activated:Connect(function()
		self.remote:FireServer("accept", self.popFrom)
		pop.Visible = false
		self:open()
	end)
	decline.Activated:Connect(function()
		self.remote:FireServer("decline", self.popFrom)
		pop.Visible = false
	end)

	-- ------------------------------------------------------------ remote
	self.remote.OnClientEvent:Connect(function(kind: string, payload: any)
		if kind == "state" then
			-- A fresh queue (or none) starts its count over.
			if not (type(payload) == "table" and payload.queue and self.state and self.state.queue == payload.queue) then
				self.searchCount, self.searchNeed = nil, nil
			end
			self.state = payload
			self:paint()
			if self.friendSheet.Visible then
				self:paintFriends()
			end
		elseif kind == "toast" then
			self:say(tostring(payload))
		elseif kind == "invite" then
			if type(payload) == "table" then
				self.popFrom = tonumber(payload.id) or 0
				setText(self.popText, tostring(payload.name or "Someone") .. " invited you")
				pop.Visible = true
				task.delay(30, function()
					if self.popFrom == tonumber(payload.id) then
						pop.Visible = false
					end
				end)
			end
		elseif kind == "searching" and type(payload) == "table" then
			self.searchCount = tonumber(payload.count)
			self.searchNeed = tonumber(payload.need)
		elseif kind == "found" and type(payload) == "table" and payload.joining then
			self:say("Joining " .. tostring(payload.joining) .. "'s party...")
		elseif kind == "found" then
			setText(self.findCaption, "MATCH FOUND!")
			-- A loosened 4v4 says which size it became.
			local q = Ranked.queue(payload and payload.queue)
			local size = payload and tonumber(payload.size)
			local sized = if size and q and size ~= q.size then (" -- " .. size .. "V" .. size) else ""
			self:say("Match found" .. sized .. " -- joining " .. string.upper(tostring(payload and payload.map or "")) .. "...")
		end
	end)

	-- The queue clock.
	task.spawn(function()
		while true do
			task.wait(0.5)
			local st = self.state
			if st and st.queue and self.findCaption.Text ~= "MATCH FOUND!" then
				local q = Ranked.queue(st.queue)
				local need = self.searchNeed or (q and q.size * 2) or 2
				local have = self.searchCount or #(st.members or { 1 })
				setText(self.findCaption, string.format("SEARCHING %s  -  %d/%d  -  CANCEL",
					mmss(os.time() - (st.since or os.time())), have, need))
			end
			if self.toastUntil > 0 and os.clock() > self.toastUntil then
				self.toastUntil = 0
				setText(self.toast, "")
			end
		end
	end)

	self.remote:FireServer("view")
	self:paint()
	return self
end

function RankedUI.say(self: any, msg: string)
	setText(self.toast, string.upper(msg))
	self.toastUntil = os.clock() + 4
end

function RankedUI.paint(self: any)
	local st = self.state
	local me = Players.LocalPlayer
	local view = st and st.me
	local rating = view and view.rating or Ranked.START
	local rank = view and view.rank or 1
	local rr = view and view.rr or 0
	local rung = Ranked.rung(rank)

	setEmblem(self.bigEmblem, rank)
	kit.kitSet(self.rankName, string.upper(rung.name))
	setText(self.rating, tostring(rr) .. " RR")
	self.barFill.Size = UDim2.fromScale(Ranked.progress({ rank = rank, rr = rr }), 1)
	self.barFill.BackgroundColor3 = rung.color
	local games = view and view.games or 0
	local wins = view and view.wins or 0
	local losses = games - wins
	setText(self.record, games > 0 and string.format("%d %s  -  %d %s",
		wins, wins == 1 and "WIN" or "WINS", losses, losses == 1 and "LOSS" or "LOSSES") or "NO RANKED GAMES YET")

	-- The ladder strip: where you are.
	for i, cell in self.ladderCells do
		cell.BackgroundTransparency = (i == rank) and 0.35 or 1
		local ring = cell:FindFirstChild("Ring") :: UIStroke
		ring.Enabled = i == rank
	end

	-- Queue pills: the pick is gold; a size your party does not fit is dim.
	local members = st and st.members or {}
	local partySize = math.max(1, #members)
	local queued = st and st.queue
	-- A pick the party has outgrown moves up to the first size that fits.
	local pick = Ranked.queue(self.queuePick)
	if not pick or partySize > pick.size then
		for _, q in Ranked.QUEUES do
			if partySize <= q.size then
				self.queuePick = q.id
				break
			end
		end
	end
	for _, q in Ranked.QUEUES do
		local b = self.queueButtons[q.id]
		local active = (queued or self.queuePick) == q.id
		local fits = partySize <= q.size
		b.BackgroundColor3 = active and Color3.fromRGB(150, 110, 30) or PILL_OFF
		local cap = b:FindFirstChild("Caption") :: TextLabel
		cap.TextTransparency = fits and 0 or 0.6
	end

	local isLeader = st == nil or st.leader == me.UserId
	if queued then
		setText(self.findCaption, "SEARCHING  -  CANCEL")
	elseif isLeader then
		setText(self.findCaption, "FIND MATCH")
	else
		setText(self.findCaption, "WAITING FOR LEADER")
	end
	self.findButton.Active = isLeader or queued ~= nil

	-- Party.
	setText(self.partyTitle, string.format("PARTY  %d/%d", partySize, Ranked.MAX_PARTY))
	for i, row in self.partyRows do
		local m = members[i]
		if m then
			row.row.Visible = true
			row.id = m.id
			setEmblem(row.emblem, m.rank or 1)
			-- The leader's name is gold; that is the whole of "leader".
			setText(row.name, tostring(m.name))
			row.name.TextColor3 = (m.id == (st and st.leader)) and GOLD or INK
			setText(row.rating, tostring(m.rr or 0) .. " RR")
			local cap = row.act:FindFirstChild("Caption") :: TextLabel
			if m.id == me.UserId and partySize > 1 then
				row.act.Visible = true
				setText(cap, "LEAVE")
			elseif isLeader and m.id ~= me.UserId then
				row.act.Visible = true
				setText(cap, "KICK")
			else
				row.act.Visible = false
			end
		else
			row.row.Visible = false
			row.id = 0
		end
	end

	-- Pending invites arrive inside state too (a player who opens the sheet
	-- after the pop timed out still has them).
	if st and st.invites and #st.invites > 0 and not self.pop.Visible then
		local inv = st.invites[1]
		self.popFrom = inv.id
		setText(self.popText, tostring(inv.name) .. " invited you")
		self.pop.Visible = true
	end

end

-- GetFriendsOnlineAsync caches for 30 s, so asking more often buys nothing.
local FRIENDS_REFRESH = 30
local STATUS = {
	{ text = "IN YOUR SERVER", color = Color3.fromRGB(111, 217, 138) },
	{ text = "PLAYING CONQUEST", color = Color3.fromRGB(232, 196, 110) },
	{ text = "IN ANOTHER GAME", color = Color3.fromRGB(146, 160, 186) },
	{ text = "ONLINE", color = Color3.fromRGB(146, 160, 186) },
}

-- One web call: every online friend with where they are. A friend whose
-- privacy hides their game reads as ONLINE.
function RankedUI.fetchFriends(self: any)
	local me = Players.LocalPlayer
	local ok, list = pcall(function()
		-- The Async name is current; the old one is deprecated but kept as a
		-- fallback for any client build that predates it.
		local p = me :: any
		if p.GetFriendsOnlineAsync then
			return p:GetFriendsOnlineAsync(200)
		end
		return p:GetFriendsOnline(200)
	end)
	if not ok or type(list) ~= "table" then
		return
	end
	local out = {}
	for _, f in list do
		local id = tonumber(f.VisitorId)
		if id then
			local tier = 4
			if Players:GetPlayerByUserId(id) then
				tier = 1
			elseif f.PlaceId == game.PlaceId then
				tier = 2
			elseif f.LocationType == 4 then
				tier = 3
			end
			-- ONLY FRIENDS IN THIS GAME (owner, 2026-10-05: "i meant friends
			-- online in the game"). Anyone elsewhere is not listed at all.
			if tier <= 2 then
				table.insert(out, { id = id, name = tostring(f.DisplayName or f.UserName or "?"), tier = tier })
			end
		end
	end
	table.sort(out, function(a, b)
		if a.tier ~= b.tier then
			return a.tier < b.tier
		end
		return a.name < b.name
	end)
	self.friendList = out
	self.friendsAt = os.clock()
	self:paintFriends()
end

function RankedUI.openFriends(self: any)
	self.friendSheet.Visible = true
	self.fpage = 1
	setText(self.friendEmpty, "LOOKING FOR FRIENDS...")
	task.spawn(function()
		self:fetchFriends()
		while self.friendSheet.Visible and self.isOpen do
			task.wait(FRIENDS_REFRESH)
			if self.friendSheet.Visible and self.isOpen then
				self:fetchFriends()
			end
		end
	end)
	self:paintFriends()
end

function RankedUI.closeFriends(self: any)
	self.friendSheet.Visible = false
end

function RankedUI.paintFriends(self: any)
	local st = self.state
	local inParty: { [number]: boolean } = {}
	for _, m in (st and st.members or {}) do
		inParty[m.id] = true
	end
	local list = {}
	for _, f in self.friendList do
		if not inParty[f.id] then
			table.insert(list, f)
		end
	end
	local per = #self.friendRows
	local pages = math.max(1, math.ceil(#list / per))
	self.fpage = math.clamp(self.fpage, 1, pages)
	setText(self.friendPage, string.format("%d/%d", self.fpage, pages))
	if self.friendsAt then
		setText(self.friendEmpty, #list == 0 and "NO FRIENDS PLAYING CONQUEST RIGHT NOW" or "")
	end
	local me = Players.LocalPlayer
	local isLeader = st == nil or st.leader == me.UserId
	for i, row in self.friendRows do
		local f = list[(self.fpage - 1) * per + i]
		if f then
			row.row.Visible = true
			row.id = f.id
			local plr = Players:GetPlayerByUserId(f.id)
			local rank = plr and tonumber(plr:GetAttribute(Ranked.RANK_ATTR)) or 1
			setEmblem(row.emblem, rank)
			-- A rank is only known for someone in this server (their attribute);
			-- anyone else shows no badge rather than a guessed Recruit.
			if row.emblem then
				row.emblem.Visible = plr ~= nil
			end
			setText(row.name, f.name)
			row.name.TextColor3 = f.tier <= 2 and INK or INK_OFF
			setText(row.status, STATUS[f.tier].text)
			row.status.TextColor3 = STATUS[f.tier].color
			-- Only someone in Conquest can be pulled into a party.
			local sentAt = self.invited[f.id]
			local recent = sentAt ~= nil and os.clock() - sentAt < 10
			row.invite.Visible = isLeader and f.tier <= 2
			local cap = row.invite:FindFirstChild("Caption") :: TextLabel
			setText(cap, recent and "SENT" or "INVITE")
		else
			row.row.Visible = false
			row.id = 0
		end
	end
end

function RankedUI.open(self: any)
	if self.isOpen then
		return
	end
	self.isOpen = true
	self.remote:FireServer("view")
	self:paint()
	self.shade.BackgroundTransparency = 1
	self.panelScale.Scale = 0.86
	self.shade.Visible = true
	tween(self.shade, OPEN, { BackgroundTransparency = 0.35 })
	tween(self.panelScale, OPEN, { Scale = 1 })
end

function RankedUI.close(self: any)
	if not self.isOpen then
		return
	end
	self.isOpen = false
	self.friendSheet.Visible = false
	tween(self.shade, SHUT, { BackgroundTransparency = 1 })
	tween(self.panelScale, SHUT, { Scale = 0.86 })
	task.delay(0.12, function()
		if not self.isOpen then
			self.shade.Visible = false
		end
	end)
end

return RankedUI
