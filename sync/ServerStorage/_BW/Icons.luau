--!strict
-- Conquest.Icons -- the five sprites the owner uploaded, in one place.
--
-- They live in StarterGui.Images as ImageLabels dropped into the tree by hand;
-- the ids are copied here rather than read from that folder at runtime, because
-- StarterGui is cloned into PlayerGui at spawn and a shared module has no
-- business waiting on either.
--
-- Every one is a chunky sticker WITH ITS OWN DARK OUTLINE baked in, drawn on a
-- transparent square. Two consequences worth knowing before using them:
--   * ScaleType.Fit, always. A non-square box stretches the outline and the
--     sticker stops reading as a sticker.
--   * They do NOT need a stroke, a shadow or a backing plate to survive on a
--     coloured map -- the outline is the reason they were drawn this way.
local Icons = {}

Icons.GOLD = "rbxassetid://103535920273936"
Icons.SWORD = "rbxassetid://80952439647563"
Icons.SHIP = "rbxassetid://108723415807591"
Icons.HOUSE = "rbxassetid://79557230616080"
Icons.NUKE = "rbxassetid://77992226064295"

-- A square icon centred in `parent`, sized as a fraction of the parent's
-- HEIGHT so a wide caption box does not stretch it sideways.
function Icons.image(parent: Instance, name: string, id: string, scale: number?): ImageLabel
	local img = Instance.new("ImageLabel")
	img.Name = name
	img.BackgroundTransparency = 1
	img.Image = id
	img.ScaleType = Enum.ScaleType.Fit
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Position = UDim2.fromScale(0.5, 0.5)
	img.Size = UDim2.fromScale(scale or 1, scale or 1)
	img.Parent = parent
	return img
end

return Icons
