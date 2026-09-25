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
Icons.SHIELD = "rbxassetid://117954362575320"
-- THE TWO MAP BUILDINGS ARE PIXEL ART, on the same 16x16 grid and the same 8x
-- nearest-neighbour export as the boats below, because they are drawn at the
-- same size and for the same reason: a map marker is fourteen pixels of glyph,
-- and at fourteen pixels an anti-aliased sticker spends half its edge on grey.
-- They are the ONLY two icons here that need `ResampleMode = Pixelated`, which
-- is what Icons.isPixel is for -- see it before adding a render site.
-- The smooth stickers they replace, if either is ever wanted back at a size
-- where softness is an advantage: ship 108723415807591, house 79557230616080.
-- These are the IMAGE ids, not the Decal ids the upload returned: an
-- ImageLabel fed a Decal id draws nothing at all, silently. If either is ever
-- re-uploaded, run the new id through InsertService:LoadAsset and take the
-- Decal's .Texture. (Decals: ship 83008227888857, house 73457659797011.)
Icons.SHIP = "rbxassetid://74148882532012"
Icons.HOUSE = "rbxassetid://127235176785441"
Icons.NUKE = "rbxassetid://77992226064295"
-- Sawtooth roof and a chimney. It is a WHITE SILHOUETTE where the house and
-- the ship are colour drawings, which used to be because the marker tinted
-- every glyph dark and a silhouette was all that survived. The marker no
-- longer tints anything -- and white is still right, because it lands on the
-- same near-black plate and is the one building that belongs to the railway
-- rather than to a colour. A factory turns the cities and ports around it
-- into train stations.
Icons.FACTORY = "rbxassetid://115188178456698"

-- ===================================================================== boats
--
-- Pixel art rather than stickers: a boat on the map is ten pixels across, and
-- at that size a soft-edged sticker is a smudge while a 16x16 pixel sprite
-- reads. Drawn from the sailboat sticker above (Icons.SHIP), one grid per
-- vessel, exported at 8x nearest-neighbour -- render them with
-- `ResampleMode = Pixelated` or the engine will blur them back into smudges.
--
-- TWO LAYERS PER BOAT, and this is the part that matters. ImageColor3
-- MULTIPLIES, so a single sprite tinted to an owner's colour loses its own
-- outline the moment that colour is dark -- a navy empire's ships would be
-- black blobs on blue water. So `ink` is the solid silhouette, drawn dark and
-- NEVER tinted, and `body` is the interior alone, greyscale, tinted to the
-- owner. The hull comes out a deeper shade of the sail because it is painted
-- at about half the sail's luminance; that is one multiply doing the work of
-- a palette.
--
-- `r` faces right and `l` is its mirror. A side-on boat cannot be ROTATED to
-- its heading -- half of every crossing would sail upside down -- so it is
-- flipped instead, which is what a mirrored asset is for.
Icons.BOATS = {
	trade = {
		ink = { r = "rbxassetid://118641703906590", l = "rbxassetid://124133962613195" },
		body = { r = "rbxassetid://110145385409874", l = "rbxassetid://129662476150978" },
	},
	transport = {
		ink = { r = "rbxassetid://127403971730403", l = "rbxassetid://131778729661101" },
		body = { r = "rbxassetid://94557611481416", l = "rbxassetid://84664986501488" },
	},
	warship = {
		ink = { r = "rbxassetid://97372381036969", l = "rbxassetid://76095141665965" },
		body = { r = "rbxassetid://74433863794654", l = "rbxassetid://96202414476786" },
	},
}

-- Which ids are pixel grids rather than stickers. Keyed by the id STRING and
-- not by a name, so a caller that only has the image (the HUD's rail builds
-- its buttons out of a table of `icon = Icons.X` fields, and the map marker
-- swaps its glyph by kind) can still ask. Anything not in here is a sticker
-- and wants the default bilinear filter.
local PIXEL = {
	[Icons.SHIP] = true,
	[Icons.HOUSE] = true,
}
for _, boat in Icons.BOATS do
	for _, layer in boat do
		for _, id in layer do
			PIXEL[id] = true
		end
	end
end

function Icons.isPixel(id: string?): boolean
	return id ~= nil and PIXEL[id] == true
end

-- Set the right filter on an ImageLabel for whatever it is currently showing.
-- Call it AFTER every Image assignment, not once at construction: the marker
-- glyph and the rail's build icon both swap image mid-life.
function Icons.resample(img: ImageLabel)
	img.ResampleMode = if Icons.isPixel(img.Image)
		then Enum.ResamplerMode.Pixelated
		else Enum.ResamplerMode.Default
end

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
	Icons.resample(img)
	img.Parent = parent
	return img
end

return Icons
