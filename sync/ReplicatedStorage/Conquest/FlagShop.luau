--!strict
-- Conquest :: FlagShop  (client, lobby only)
-- The FLAGS tab of the shop: the nation flag a player flies beside their name.
--
-- IT IS A PAGE, NOT A PANEL. `PatternShop` owns the window, the tab strip, the
-- money readout and the DONE button; this owns the rectangle between them and
-- nothing else. Everything here is drawn in the same kit (`LobbyUI.kit`) the
-- rest of that page uses, and the dependency stays one-way in the same
-- direction: this requires PatternShop's kit source, never PatternShop.
--
-- WHY THIS ONE SCROLLS AND THE PATTERN PAGE DOES NOT. The pattern ladder is
-- seventeen entries whose LAYOUT is the product -- one column per tier, worst
-- to best, so "which is the good one" is answered before a word is read. Flags
-- have no ladder: fifty-seven nations, none better than another, and the only
-- question is "is mine in here". That is a list you search, not a ladder you
-- read, so it scrolls and it is ordered by the historical roster (the ten
-- playable nations first) rather than by any notion of rank.
--
-- NOTHING HERE DECIDES ANYTHING. The server owns what an account owns and
-- refuses anything it did not authorise; this checks the same rules locally
-- only so a refusal is instant and a press that cannot succeed is never sent.

local Products = require(script.Parent.Products)
local Flags = require(script.Parent.Flags)
local LobbyUI = require(script.Parent.LobbyUI)
local Sfx = require(script.Parent.Sfx)

local kit = LobbyUI.kit
local place, label = kit.place, kit.label
local setText = kit.setText
local roundOff, grower, tween = kit.roundOff, kit.grower, kit.tween

local FlagShop = {}
FlagShop.__index = FlagShop

-- ---------------------------------------------------------------- layout ---
-- SIX ACROSS. A flag is 18x12 and has to stay big enough that Honduras and
-- Nicaragua are not the same picture; six columns over the panel's inner width
-- leaves each one about ninety pixels of flag, which is five times the art's
-- own width and well clear of that.
local COLS = 6

-- Fractions of the scroll WINDOW, not of the canvas: a UIGridLayout resolves a
-- scale cell against the frame it is in, and AutomaticCanvasSize does the
-- canvas arithmetic, so the cards stay the same size whatever the roster grows
-- to. Row height is a shade under a third of the window, which puts three rows
-- and a sliver of the fourth on screen -- enough that it is OBVIOUSLY a list
-- that continues, without a scrollbar being the only thing that says so.
local GAP_X, GAP_Y = 0.012, 0.03
local CELL_W = (1 - GAP_X * (COLS - 1)) / COLS
local CELL_H = 0.30

-- Inside a card, all fractions of the card itself. The name takes the height:
-- it is what somebody is scanning this list FOR, and the flag above it is
-- already doing the recognising.
local ART_Y, ART_H = 0.04, 0.48
local NAME_Y, NAME_H = 0.55, 0.24
local STATE_Y, STATE_H = 0.81, 0.16

-- The card's size on the 16:9 reference screen, used ONLY to size the text
-- constraints (see buildCard). Measured off the built page: 161x156.
local CARD_PX_W, CARD_PX_H = 161, 156
local NAME_PX, STATE_PX = 34, 22

local SCROLLBAR = 6

-- ------------------------------------------------------------------ build --

local function buildCard(self: any, parent: Instance, id: string): any
	local card = Instance.new("ImageButton")
	card.Name = "Flag_" .. id
	card.Image = ""
	card.BackgroundColor3 = kit.PANEL
	card.BackgroundTransparency = 0.35
	card.BorderSizePixel = 0
	card.AutoButtonColor = false
	card.Parent = parent
	roundOff(card, 8)

	local stroke = Instance.new("UIStroke")
	stroke.Color = kit.LINE
	stroke.Thickness = 1.6
	stroke.Transparency = 0.45
	stroke.Parent = card

	-- THE FLAG ITSELF IS NOT PAINTED HERE (2026-09-16). Every card's art is an
	-- EditableImage, and building the whole catalogue in the constructor cost
	-- EVERY LOBBY JOIN 77 of them plus their pixel writes -- whether or not the
	-- player ever pressed the FLAGS tab. `FlagShop.realize` does it on the
	-- first setVisible(true) instead; until then `entry.art` is nil, which is
	-- the resting state paintCard already guards for.

	-- AUTHORED IN REAL PIXELS, not 1x1. `kit.label` fits a UITextSizeConstraint
	-- with MaxTextSize = h * 4, so passing a height of ONE capped this text at
	-- FOUR PIXELS -- which is the whole reason the nation names came out
	-- unreadable, and no amount of growing the box would have fixed it. These
	-- are the card's true size on the reference screen; Position and Size are
	-- still driven in Scale underneath, so the grid keeps its say over layout.
	local name = label(card, "Name", CARD_PX_W, CARD_PX_H, 0, 0, CARD_PX_W, NAME_PX, kit.INK, Enum.TextXAlignment.Center, kit.FONT_BOLD)
	name.Position = UDim2.fromScale(0.04, NAME_Y)
	name.Size = UDim2.fromScale(0.92, NAME_H)
	setText(name, string.upper(Flags.name(id)))

	local state = label(card, "State", CARD_PX_W, CARD_PX_H, 0, 0, CARD_PX_W, STATE_PX, kit.INK_OFF, Enum.TextXAlignment.Center)
	state.Position = UDim2.fromScale(0.04, STATE_Y)
	state.Size = UDim2.fromScale(0.92, STATE_H)

	local scale = grower(card)
	local entry = { id = id, card = card, art = nil, stroke = stroke, name = name, state = state, scale = scale, hover = false }

	card.MouseEnter:Connect(function()
		entry.hover = true
		tween(scale, kit.HOVER_IN, { Scale = kit.HOVER_SCALE })
		tween(stroke, kit.HOVER_IN, { Transparency = 0 })
	end)
	card.MouseLeave:Connect(function()
		entry.hover = false
		tween(scale, kit.HOVER_OUT, { Scale = 1 })
		FlagShop.paintCard(self, entry)
	end)
	card.MouseButton1Down:Connect(function()
		tween(scale, kit.PRESS_IN, { Scale = kit.PRESS_SCALE })
	end)
	card.MouseButton1Up:Connect(function()
		tween(scale, kit.PRESS_OUT, { Scale = entry.hover and kit.HOVER_SCALE or 1 })
	end)
	card.Activated:Connect(function()
		FlagShop.press(self, entry)
	end)
	return entry
end

-- `parent` is the shop panel; the rest is the rectangle on it this page owns,
-- in the panel's own authored pixel space (see PatternShop's layout block).
function FlagShop.new(parent: Instance, pw: number, ph: number, x: number, y: number, w: number, h: number): any
	local self = setmetatable({}, FlagShop)
	-- Nothing is known until the server says so -- same rule as the pattern
	-- page, and for the same reason: a page that showed everything unowned
	-- while the profile was loading would offer to sell what you already have.
	self.known = false
	-- Whether the flag art has been painted yet; see FlagShop.realize.
	self.realized = false
	self.owned = {} :: { [string]: boolean }
	self.equipped = Flags.NONE
	self.tokens = 0
	self.prices = {} :: { [string]: number }
	self.onIntent = nil :: ((string, string) -> ())?
	self.onRobux = nil :: ((string) -> ())?
	self.onSay = nil :: ((string) -> ())?
	self.entries = {}

	local root = Instance.new("Frame")
	root.Name = "FlagsPage"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Visible = false
	place(root, pw, ph, x, y, w, h)
	root.Parent = parent
	self.root = root

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Scroll"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.ScrollBarThickness = SCROLLBAR
	scroll.ScrollBarImageColor3 = kit.LINE
	scroll.ScrollBarImageTransparency = 0.3
	-- The canvas is whatever the grid turns out to be. Computing it by hand
	-- means every future flag added to the roster is a second edit that some
	-- day will not be made.
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	scroll.Parent = root
	self.scroll = scroll

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromScale(CELL_W, CELL_H)
	grid.CellPadding = UDim2.fromScale(GAP_X, GAP_Y)
	grid.FillDirectionMaxCells = COLS
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll

	-- A little air under the last row, or the bottom row sits flush against the
	-- edge of the window and reads as cut off rather than as the end.
	local pad = Instance.new("UIPadding")
	pad.PaddingBottom = UDim.new(0.02, 0)
	pad.PaddingRight = UDim.new(0, SCROLLBAR + 2)
	pad.Parent = scroll

	for i, id in Flags.ORDER do
		local entry = buildCard(self, scroll, id)
		entry.card.LayoutOrder = i
		table.insert(self.entries, entry)
	end

	FlagShop.repaint(self)
	return self
end

-- ----------------------------------------------------------------- paint ---

function FlagShop.paintCard(self: any, entry: any)
	local owned = self.known and self.owned[entry.id] == true
	local worn = owned and self.equipped == entry.id
	local live = Products.isLive(Products.product("FLAG"))

	if worn then
		entry.stroke.Color = kit.GOLD
		entry.stroke.Thickness = 2.6
		entry.stroke.Transparency = 0
		setText(entry.state, "FLYING")
		entry.state.TextColor3 = kit.GOLD
		entry.name.TextColor3 = kit.INK
	elseif not self.known then
		entry.stroke.Color = kit.LINE
		entry.stroke.Thickness = 1.6
		entry.stroke.Transparency = 0.45
		setText(entry.state, "")
		entry.name.TextColor3 = kit.INK_OFF
	elseif owned then
		entry.stroke.Color = kit.LINE
		entry.stroke.Thickness = 1.6
		entry.stroke.Transparency = 0.15
		setText(entry.state, "FLY")
		entry.state.TextColor3 = kit.INK_DIM
		entry.name.TextColor3 = kit.INK
	elseif self.tokens > 0 then
		-- AN UNLOCK IN HAND. This is the one state that is worth shouting
		-- about: it is free to press and it is why they bought the thing.
		entry.stroke.Color = kit.GAIN
		entry.stroke.Thickness = 2.2
		entry.stroke.Transparency = 0.1
		setText(entry.state, "UNLOCK")
		entry.state.TextColor3 = kit.GAIN
		entry.name.TextColor3 = kit.INK
	else
		-- SOON is a product with no id yet -- drawn, dimmed, unpressable. Same
		-- contract as a Robux skin on the pattern page.
		entry.stroke.Color = kit.LINE
		entry.stroke.Thickness = 1.6
		entry.stroke.Transparency = 0.55
		local price = self.prices["FLAG"]
		setText(entry.state, live and (price and ("R$ " .. price) or "ROBUX") or "SOON")
		entry.state.TextColor3 = live and kit.GOLD or kit.INK_OFF
		entry.name.TextColor3 = live and kit.INK or kit.INK_OFF
	end

	-- The art never dims. A flag you do not own yet is exactly the thing the
	-- page is trying to sell you, and greying it out sells nothing.
	if entry.art then
		entry.art.ImageTransparency = self.known and 0 or 0.45
	end
end

function FlagShop.repaint(self: any)
	for _, entry in self.entries do
		FlagShop.paintCard(self, entry)
	end
end

-- CAPTURED INTO A LOCAL BEFORE THE CALL, here and at every other optional
-- callback below. `if self.onX then self.onX() end` does not narrow the
-- optional away under --!strict -- it types as "calling a value that might be
-- false" -- and this file is strict. Same call, with a refinement Luau can see.
local function say(self: any, text: string)
	local fn = self.onSay
	if fn then
		fn(text)
	end
end

-- ---------------------------------------------------------------- presses --

function FlagShop.press(self: any, entry: any)
	if not self.known then
		Sfx.play("Deny")
		say(self, "YOUR PROFILE HAS NOT LOADED YET.")
		return
	end

	local owned = self.owned[entry.id] == true

	if owned then
		-- PAINTED FIRST, THEN SENT, like the pattern page's equip: flying a
		-- flag you own is free and can only be refused for ownership, which
		-- was just checked, so a round trip would only make the page feel slow.
		-- Pressing the one you are already flying takes it off.
		self.equipped = if self.equipped == entry.id then Flags.NONE else entry.id
		FlagShop.repaint(self)
		Sfx.play("Click")
		local fn = self.onIntent
		if fn then
			fn("equip", self.equipped)
		end
		return
	end

	if self.tokens > 0 then
		-- Spending an unlock. NOT painted optimistically: the token is the
		-- server's to spend, and the card flips when the profile says it did.
		Sfx.play("Cheer")
		local fn = self.onIntent
		if fn then
			fn("buy", entry.id)
		end
		return
	end

	if not Products.isLive(Products.product("FLAG")) then
		Sfx.play("Deny")
		say(self, "FLAGS ARE NOT ON SALE YET.")
		return
	end

	-- No unlock in hand, so this press buys one. The site decides; the page
	-- repaints when the receipt has landed and the profile has come back.
	Sfx.play("Coin")
	local fn = self.onRobux
	if fn then
		fn("FLAG")
	end
end

-- ------------------------------------------------------------------ state --

function FlagShop.setState(self: any, owned: any, equipped: any, tokens: any)
	self.owned = type(owned) == "table" and owned or {}
	self.equipped = type(equipped) == "string" and equipped or Flags.NONE
	self.tokens = tonumber(tokens) or 0
	self.known = true
	FlagShop.repaint(self)
end

function FlagShop.setPrice(self: any, key: string, robux: number)
	self.prices[key] = robux
	FlagShop.repaint(self)
end

-- PAINT THE CATALOGUE, ONCE, the first time it is actually looked at. Flags
-- caches the EditableImage per flag id, so this is the only place the 77 are
-- ever built and nothing repeats the cost on a later tab switch.
function FlagShop.realize(self: any)
	if self.realized then
		return
	end
	self.realized = true
	for _, entry in self.entries do
		if entry.art == nil then
			-- Pixelated and Fit are the Flags module's job, not this file's.
			-- Nepal is not a rectangle and Fit is what keeps it from being
			-- stretched into one.
			local art = Flags.image(entry.card, "Art", entry.id)
			if art then
				art.AnchorPoint = Vector2.new(0.5, 0)
				art.Position = UDim2.fromScale(0.5, ART_Y)
				art.Size = UDim2.fromScale(0.82, ART_H)
				entry.art = art
			end
		end
	end
	-- The art carries an owned/unowned transparency, so it has to be painted
	-- once it exists rather than waiting for the next state change.
	FlagShop.repaint(self)
end

function FlagShop.setVisible(self: any, on: boolean)
	if on then
		FlagShop.realize(self)
	end
	self.root.Visible = on
end

return FlagShop
