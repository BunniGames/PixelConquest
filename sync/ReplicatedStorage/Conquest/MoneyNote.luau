--!strict
-- THE BANKNOTE, everywhere the word MONEY used to be (owner, 2026-10-05: "for
-- the other parts that say Money ... use the same pixel image of money i used in
-- the lobby"). The art is the lobby's own (LobbyUI MoneyIcon, 2026-10-02), moved
-- here so the bar and every shop/card that prices in Money draw one note.
--
-- `attach` hangs the note off a TextLabel and HUGS ITS TEXT: the figure changes
-- width and the label may be left, right or centre aligned, so the note is
-- re-placed off TextBounds every time either changes -- the same reason the
-- lobby's note follows its balance. For a left or centred label the room the
-- note takes is padded out of the label (UIPadding), so a centred "[note] 500"
-- centres as one group instead of the number alone.
--
-- Client only: EditableImage does not exist on the server.

local AssetService = game:GetService("AssetService")

local MoneyNote = {}

MoneyNote.ART = {
	"kkkkkkkkkkkkkkkkkk",
	"kddddddddddddddddk",
	"kdlggggggggggggldk",
	"kdgggggkkkkgggggdk",
	"kdggggkllllkggggdk",
	"kdggggklddlkggggdk",
	"kdggggkllllkggggdk",
	"kdgggggkkkkgggggdk",
	"kdlggggggggggggldk",
	"kddddddddddddddddk",
	"kkkkkkkkkkkkkkkkkk",
}

-- LobbyUI's PIX_P entries for the four letters the note uses.
local PAL: { [string]: { number } } = {
	["."] = { 0, 0, 0, 0 },
	["k"] = { 20, 22, 28, 255 },
	["d"] = { 28, 112, 62, 255 },
	["g"] = { 111, 217, 138, 255 },
	["l"] = { 206, 246, 214, 255 },
}

local W, H = #MoneyNote.ART[1], #MoneyNote.ART

-- One image for every note on the client; each label shows the same pixels.
local content: Content? = nil
local function image(): Content?
	if content ~= nil then
		return content
	end
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(W, H) })
	end)
	if not ok or img == nil then
		return nil
	end
	local buf = buffer.create(W * H * 4)
	for y = 1, H do
		local row = MoneyNote.ART[y]
		for x = 1, W do
			local rgba = PAL[string.sub(row, x, x)] or PAL["."]
			local o = ((y - 1) * W + (x - 1)) * 4
			buffer.writeu8(buf, o + 0, rgba[1])
			buffer.writeu8(buf, o + 1, rgba[2])
			buffer.writeu8(buf, o + 2, rgba[3])
			buffer.writeu8(buf, o + 3, rgba[4])
		end
	end
	;(img :: EditableImage):WritePixelsBuffer(Vector2.zero, Vector2.new(W, H), buf)
	content = Content.fromObject(img :: EditableImage)
	return content
end

-- A bare note, for a caller that places it itself (the lobby bar does).
function MoneyNote.new(parent: Instance?, name: string?): ImageLabel
	local lbl = Instance.new("ImageLabel")
	lbl.Name = name or "MoneyNote"
	lbl.BackgroundTransparency = 1
	lbl.BorderSizePixel = 0
	local c = image()
	if c ~= nil then
		lbl.ImageContent = c
	end
	lbl.ScaleType = Enum.ScaleType.Fit
	-- The one property that makes this pixel art instead of a blur.
	lbl.ResampleMode = Enum.ResamplerMode.Pixelated
	lbl.Parent = parent
	return lbl
end

-- "1,000 MONEY" -> "1,000", true. Anything without the word comes back as is.
function MoneyNote.strip(text: string): (string, boolean)
	local rest = string.match(text, "^(.-)%s*MONEY%s*$")
	if rest ~= nil then
		return rest, true
	end
	return text, false
end

-- Hangs a note off `label`, BEFORE its text by default ("[note] 1,000", the
-- lobby's order) or AFTER it. The note hides whenever the label's text is
-- empty, so a readout that blanks itself while loading takes the note with it.
-- Returns the note; calling again on the same label turns the same one back on.
function MoneyNote.attach(label: TextLabel, side: ("before" | "after")?): ImageLabel
	label:SetAttribute("MoneyNote", true)
	local existing = label:FindFirstChild("MoneyNote")
	if existing ~= nil and existing:IsA("ImageLabel") then
		return existing
	end
	local after = side == "after"
	local note = MoneyNote.new(nil, "MoneyNote")
	note.AnchorPoint = Vector2.new(0, 0.5)
	note.ZIndex = label.ZIndex

	-- The label's own padding, if it has one, is kept and added to.
	local pad = label:FindFirstChildOfClass("UIPadding")
	if pad == nil then
		pad = Instance.new("UIPadding")
		;(pad :: UIPadding).Parent = label
	end
	local p = pad :: UIPadding
	local baseL, baseR = p.PaddingLeft, p.PaddingRight

	local busy = false
	local function place()
		if busy then
			return
		end
		busy = true
		local size = label.AbsoluteSize
		local tb = label.TextBounds
		local on = label:GetAttribute("MoneyNote") ~= false
		note.Visible = on and label.Text ~= "" and tb.X > 0
		if size.X > 0 and size.Y > 0 then
			-- As tall as the type, snapped to whole pixels-per-pixel once it is
			-- big enough to have a choice: a note at 2x is crisp, at 2.36x it is
			-- uneven columns.
			local want = if tb.Y > 0 then math.min(tb.Y, size.Y) else size.Y
			local nh = if want >= H then math.floor(want / H + 0.25) * H else math.max(1, math.floor(want))
			local nw = math.floor(nh * W / H + 0.5)
			local gap = math.max(2, math.floor(nh * 0.3 + 0.5))
			local room = if on then nw + gap else 0
			local align = label.TextXAlignment
			local extraL = if not after and align ~= Enum.TextXAlignment.Right then room else 0
			local extraR = if after and align ~= Enum.TextXAlignment.Left then room else 0
			p.PaddingLeft = UDim.new(baseL.Scale + extraL / size.X, baseL.Offset)
			p.PaddingRight = UDim.new(baseR.Scale + extraR / size.X, baseR.Offset)
			local padL = p.PaddingLeft.Scale * size.X + p.PaddingLeft.Offset
			local padR = p.PaddingRight.Scale * size.X + p.PaddingRight.Offset
			local left
			if align == Enum.TextXAlignment.Left then
				left = padL
			elseif align == Enum.TextXAlignment.Right then
				left = size.X - padR - tb.X
			else
				left = padL + (size.X - padL - padR - tb.X) / 2
			end
			local x = if after then left + tb.X + gap else left - gap - nw
			-- Positioned against the label's box, not its padded content: the
			-- note is a child of the label, and UIPadding moves children too.
			note.Size = UDim2.fromOffset(nw, nh)
			note.Position = UDim2.new(0, math.floor(x - padL + 0.5), 0.5, 0)
		end
		busy = false
	end

	label:GetPropertyChangedSignal("TextBounds"):Connect(place)
	label:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
	label:GetPropertyChangedSignal("Text"):Connect(place)
	label:GetPropertyChangedSignal("TextXAlignment"):Connect(place)
	label:GetAttributeChangedSignal("MoneyNote"):Connect(place)
	-- Fades with its words.
	label:GetPropertyChangedSignal("TextTransparency"):Connect(function()
		note.ImageTransparency = label.TextTransparency
	end)
	note.ImageTransparency = label.TextTransparency
	note.Parent = label
	place()
	return note
end

-- For a recycled label whose next line is not Money: hides the note and gives
-- its room back. `attach` turns it on again.
function MoneyNote.off(label: TextLabel)
	if label:GetAttribute("MoneyNote") ~= nil then
		label:SetAttribute("MoneyNote", false)
	end
end

return MoneyNote
