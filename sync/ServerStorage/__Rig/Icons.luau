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
-- where softness is an advantage: port 108723415807591, house 79557230616080.
-- These are the IMAGE ids, not the Decal ids the upload returned: an
-- ImageLabel fed a Decal id draws nothing at all, silently. If either is ever
-- re-uploaded, run the new id through InsertService:LoadAsset and take the
-- Decal's .Texture. (Decals: port 83008227888857, house 73457659797011.)
Icons.PORT = "rbxassetid://74148882532012"
Icons.HOUSE = "rbxassetid://127235176785441"
Icons.NUKE = "rbxassetid://77992226064295"
-- The defence post: a stone keep with crenellations, drawn in the same chunky
-- sticker style as the warhead above -- slate greys over a baked dark outline.
-- A STICKER, NOT PIXEL ART, so it is deliberately absent from the PIXEL table
-- below: the source is 420px with ~1,900 anti-aliased colours, and forcing
-- Pixelated on it would crunch the outline it was drawn with.
Icons.TOWER = "rbxassetid://77612503652449"
-- The anti-nuke tower, since 2026-09-15. A sticker in the same chunky style as
-- the keep above -- an olive launcher box tipped up with a missile leaving it,
-- 1254px with a baked dark outline -- so it is deliberately NOT in the PIXEL
-- table below, for the reason TOWER is not.
--
-- IT WAS Icons.SHIELD, and SHIELD IS STILL HERE ON PURPOSE: NationLabels flies
-- it as the REINFORCEMENT glyph opposite the sword, where the pair means troops
-- coming in vs a war going out and has nothing to do with this building.
-- Repointing SHIELD would have swapped that icon too.
Icons.DOME = "rbxassetid://92953500285413"
-- Planted on the map where an empire died. It is a MAP PIN, not a HUD
-- glyph: it lands on whatever colour that ground happens to be, which is
-- exactly the case the baked dark outline was drawn for.
Icons.SKULL = "rbxassetid://112657419190758"
-- Sawtooth roof and a chimney. It is a WHITE SILHOUETTE where the house and
-- the port are colour drawings, which used to be because the marker tinted
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
-- reads. Drawn from the sailboat sticker above (Icons.PORT), one grid per
-- boat, exported at 8x nearest-neighbour -- render them with
-- `ResampleMode = Pixelated` or the engine will blur them back into smudges.
--
-- TWO LAYERS PER BOAT, and this is the part that matters. ImageColor3
-- MULTIPLIES, so a single sprite tinted to an owner's colour loses its own
-- outline the moment that colour is dark -- a navy empire's boats would be
-- black blobs on blue water. So `ink` is the solid silhouette, drawn dark and
-- NEVER tinted, and `body` is the interior alone, greyscale, tinted to the
-- owner. The hull comes out a deeper shade of the sail because it is painted
-- at about half the sail's luminance; that is one multiply doing the work of
-- a palette.
--
-- FOUR VIEWS. `r` faces right and `l` is its mirror; `u` and `d` are the
-- stern-on and bow-on views a hull running due north or south needs. A side-on
-- boat cannot be ROTATED to its heading -- half of every crossing would sail
-- upside down -- so it is mirrored for left and swapped outright for the two
-- verticals, which is why they are separate art rather than a Rotation.
--
-- `u` and `d` are OPTIONAL and Structures asks before it reaches for them, so a
-- boat given only `r`/`l` still works: it holds its last facing through a
-- vertical leg, which is what every boat here did before these existed.
--
-- THE VERTICAL VIEWS WERE DRAWN SMOOTH AT ~1024px and are downsampled onto the
-- same 16x16 grid as the side views, then split into ink and body the same way
-- -- otherwise a boat changed art style every time it turned a corner, which is
-- the one artefact four headings were added to remove. Two consequences of the
-- split worth knowing before redrawing any of them: a sail seen edge-on is two
-- cells wide, so the erosion that leaves an ink edge all the way round leaves
-- it as pure ink -- correct, because edge-on a sail IS its own dark edge -- and
-- the body is painted in three flat greys per sprite rather than one per row,
-- because a palette value per row turns a gradient into sixteen stripes at this
-- size.
--
-- THE GUNBOAT'S BOW AND STERN WERE REDRAWN (2026-09-02, owner spotted it:
-- "i think the normal ships in the game going up and down use the images of a
-- gunboat"). They did not -- every id here is distinct -- but the drawing was
-- the same IDEA as the sailboat's: a mast over a widening triangle, just
-- shorter. End-on, a warship and a merchantman were the same silhouette, and
-- when every ship went to one size on the same day the last thing telling them
-- apart went with it. The replacement is what a warship actually looks like
-- coming at you: WIDE AND LOW, 12 cells across the bow and 14 across the
-- stern, eight tall, a bridge block and no mast at all. Against the sailboat's
-- narrow tall triangle it reads at a glance, which is the whole job.
--
-- Both new views are 8 cells tall, the same as the side view, so the height
-- rule below costs them nothing (Structures.hullFit comes out at exactly 1).
--
-- AND EACH VERTICAL VIEW IS SCALED SO ITS CONTENT IS AS TALL AS THE SIDE
-- VIEW'S -- a boat does not change height when it turns, and fitting the
-- drawing to the full 16 cells instead made a gunboat sailing north twice the
-- size of the same gunboat sailing east. The sailboat lands on 15 cells, which
-- is exactly its side view. The gunboat is the awkward one: its side sprite is
-- an unusually flat 8 cells, and the bow drawing it used to have carried a
-- mast the side drawing does not, which is what forced it up to 10. The
-- redrawn pair is flat too, so the gunboat now sits at 8 like its own side
-- view -- bow and stern are told apart by their WIDTH (12 against 14) and by
-- which end tapers, not by height.
--
-- TRANSPORT AND TRADE SHARE ONE PAIR. Their side-on sprites are already nearly
-- the same sailboat, and one bow/stern drawing covers both.
Icons.BOATS = {
	trade = {
		ink = {
			r = "rbxassetid://118641703906590",
			l = "rbxassetid://124133962613195",
			u = "rbxassetid://104660617367653",
			d = "rbxassetid://118477524065762",
		},
		body = {
			r = "rbxassetid://110145385409874",
			l = "rbxassetid://129662476150978",
			u = "rbxassetid://125013298096114",
			d = "rbxassetid://75479469900855",
		},
	},
	transport = {
		ink = {
			r = "rbxassetid://127403971730403",
			l = "rbxassetid://131778729661101",
			u = "rbxassetid://104660617367653",
			d = "rbxassetid://118477524065762",
		},
		body = {
			r = "rbxassetid://94557611481416",
			l = "rbxassetid://84664986501488",
			u = "rbxassetid://125013298096114",
			d = "rbxassetid://75479469900855",
		},
	},
	gunboat = {
		ink = {
			r = "rbxassetid://97372381036969",
			l = "rbxassetid://76095141665965",
			u = "rbxassetid://75878624553559",
			d = "rbxassetid://108312848556400",
		},
		body = {
			r = "rbxassetid://74433863794654",
			l = "rbxassetid://96202414476786",
			u = "rbxassetid://118065450072843",
			d = "rbxassetid://99651826849216",
		},
	},
}

-- Which ids are pixel grids rather than stickers. Keyed by the id STRING and
-- not by a name, so a caller that only has the image (the HUD's rail builds
-- its buttons out of a table of `icon = Icons.X` fields, and the map marker
-- swaps its glyph by kind) can still ask. Anything not in here is a sticker
-- and wants the default bilinear filter.
local PIXEL = {
	[Icons.PORT] = true,
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
