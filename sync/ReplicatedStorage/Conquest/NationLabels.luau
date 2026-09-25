--!strict
-- Conquest :: NationLabels  (client only)
-- The name and army size written across each nation's own territory, the way a
-- political map labels countries.
--
-- The labels are children of the MAP CONTAINER, not the screen, and every size
-- and position is in Scale. That is the whole trick: the camera already sizes
-- and moves that container, so panning and zooming carry the labels along for
-- free and a name always covers the same share of its own territory.
--
-- update() and setArmies() only ever set TARGETS. step(), once a frame, is
-- the sole thing that draws: it walks each label to its target and rewrites a
-- figure only when the printed text changes. Summaries land five times a
-- second, and a map whose names and numbers jump five times a second is
-- unreadable -- so nothing here ever teleports, and a label that has not
-- meaningfully moved is not moved at all.

local Faces = require(script.Parent.Faces)
local Palette = require(script.Parent.Palette)
local Config = require(script.Parent.Config)
local Numbers = require(script.Parent.Numbers)
local Icons = require(script.Parent.Icons)
local Flags = require(script.Parent.Flags)

-- WHICH FLAG EACH EMPIRE FLIES, and it lives HERE rather than in ConquestClient
-- for one hard reason: ConquestClient is AT Luau's 200-local ceiling. A single
-- new file-scope local there ("local rosterFlag") fails to compile outright --
-- "Out of local registers ... exceeded limit 200" -- which kills the whole
-- client, not just the flag. So the module owns the map and the client only
-- calls into it, exactly the shape Patterns.setOwner/clearOwners already uses
-- and exactly why that shape exists.
local flagOwner: { [number]: string } = {}

-- THE DIPLOMACY MARK over a nation (owner, 2026-09-18: "use handshake and
-- broken heart on the map to represent betrayal and allies"): "ally" is a
-- handshake over an ally of the local player, "traitor" a broken heart over
-- anyone wearing the mark. Same shape as flagOwner and for the same reason:
-- DiplomacyClient sets it, and ConquestClient -- at the ceiling -- never
-- learns the word.
local markOf: { [number]: string } = {}
-- The owner's art, read off StarterGui.Images the way every sticker is. A
-- kind with no art is never drawn rather than drawn broken.
local MARK_IMAGE: { [string]: string } = {}
do
	local images = game:GetService("StarterGui"):FindFirstChild("Images")
	for kind, name in { ally = "Ally", traitor = "Betrayal" } do
		local art = images and images:FindFirstChild(name)
		if art ~= nil and (art:IsA("ImageLabel") or art:IsA("ImageButton")) then
			local img = (art :: any).Image
			if img ~= "" then
				MARK_IMAGE[kind] = img
			end
		end
	end
end

local W = Config.MAP_W
local H = Config.MAP_H

local FONT = Font.fromEnum(Enum.Font.GothamBold)

-- A nation smaller than this is a speck at any sane zoom; labelling it just
-- litters the map with text nobody can read.
local MIN_TILES = 900

-- Below this on-screen height the name is unreadable, so it is hidden rather
-- than drawn as a smear. Zoomed out over 17 nations that is most of them,
-- which is the correct look: names appear as you zoom into a region.
local MIN_ON_SCREEN_PX = 7

-- =================================================================== face ==
-- The headshot of whoever is actually playing a nation, above its name.
-- Seventy-one of the seventy-two empires on this map are AI wearing generated
-- names, so the first thing anyone wants off the map is WHERE THE PEOPLE ARE
-- -- and a face answers that at a glance where one more entry on a 72-colour
-- ramp cannot.
--
-- A fraction of the label's own height, not a screen size: the face belongs
-- to the name under it and has to grow with it. An army number is the
-- opposite -- it belongs to the screen -- which is why that one divides by
-- zoom and this one does not.
local FACE_H = 0.50
local FACE_GAP = 0.04
-- The mark sits UNDER THE ARMY FIGURE (owner, 2026-09-18: "put it below
-- their attack number"), centred, hanging off the foot of the holder the way
-- the face hangs off its top: a share of the holder's height so it grows
-- with the label, and a little air above it.
local MARK_H = 0.40
local MARK_GAP = 0.03
-- The name row's share of the holder (see build), the flag's share of that row,
-- and the air between the flag and the first letter -- all fractions, so they
-- hold at every zoom and every label size.
local NAME_H = 0.62
-- 0.78 -> 0.55: the owner asked for about 30% off (2026-09-15). Height only;
-- the aspect constraint carries the width, so the shape is untouched, and the
-- right-edge anchor keeps FLAG_GAP measuring the same air beside the letter.
local FLAG_H = 0.55
local FLAG_GAP = 0.015

-- =================================================================== sword ==
-- THE ARMY ROW, and the blade that says what the figure IS. A bare number
-- under a country called "Ironhold" is a rank, a population, a score -- the
-- map never said which, and it is the one number on it a player acts on.
--
-- The glyph is the HUD's own ARMY icon (HUD's IconArmy, Icons.SWORD), and that
-- is the whole point rather than decoration: the same object in both places
-- says THIS NUMBER IS THE ONE IN YOUR BAR, in one look and in every language.
--
-- UNTINTED, like every sticker here. ImageColor3 multiplies, so tinting it to
-- the nation would grey the blade out over a dark empire -- and the baked dark
-- outline is exactly why this art survives on coloured ground (see Icons).
local TROOPS_H = 0.34
local TROOPS_Y = 0.66
-- Share of the army row the blade stands in. A shade taller than the digits'
-- cap height, which is how a glyph flanks text without looming over it.
local SWORD_H = 0.9
-- The air between blade and first digit -- the same figure the flag takes
-- beside the first letter, for the same reason and at the same scale.
local SWORD_GAP = 0.015
-- ...and it leaves when the figure stops being a figure. Below this the blade
-- is three dark pixels beside two more -- litter rather than a label -- and at
-- that size the number under it is not readable either, so nothing is lost by
-- taking both. The face has its own, larger floor for the same reason.
local MIN_SWORD_PX = 5

-- ...and it leaves before the name does. A name is still readable at seven
-- pixels; a face at seven pixels is a smear of skin tone, and two dozen of
-- them are litter over the map rather than anything about it.
local MIN_FACE_PX = 12

-- An attack's number is the ONE thing on this map that does not live in
-- map units. Upstream draws it at a fixed SCREEN size and divides by the
-- camera zoom every frame (ATTACK_LABEL_SCREEN_SCALE = 17,
-- src/client/render/gl/passes/WorldTextPass.ts:44-49), so a battle reads
-- identically whether you are looking at one province or the whole
-- continent -- and no war ever grows into a number that covers a country.
local ARMY_PX = 19

-- Wide enough that HEIGHT is always what TextScaled binds on, so "1.30K"
-- and "23" come out the same size instead of the long one shrinking.
local ARMY_WIDTH_RATIO = 4.2

-- Aquarius for the men you sent, red-400 for the men coming for you --
-- upstream's two colours, and the only two an attack number ever takes
-- (src/client/controllers/AttackingTroopsController.ts:21-27). What has to
-- read at a glance is which way it points relative to YOU, not whose it is.
local ARMY_OUT = Color3.fromRGB(0x3F, 0xA9, 0xF5)
local ARMY_IN = Color3.fromRGB(0xF8, 0x71, 0x71)

-- Past this the label is redrawn at its new front instead of sliding to
-- it: a front that splits or collapses moves hundreds of tiles at once,
-- and crossing the map at walking pace is worse than a cut
-- (SNAP_DISTANCE, AttackingTroopsController.ts:32).
local ARMY_SNAP_TILES = 200

-- ==================================================================== war ==
-- The sword that punches out of the map where a war STARTS. The numbers below
-- say how big a fight is; nothing said one had BEGUN -- and an attack coming
-- at you can open anywhere along a border you are not looking at.
--
-- Fixed SCREEN size, like the army numbers: the camera scales this whole
-- container, so dividing by zoom cancels it exactly and a declaration reads
-- the same whether you are looking at one province or the continent.
local POP_PX = 44
local POP_LIFE = 0.8
-- Tiles it drifts upward over that life, at zoom 1. Rising is what separates
-- it from the static number about to settle underneath it.
local POP_RISE = 26
-- Which way the war points, as two different OBJECTS rather than two tints of
-- one. A tint cannot do this job: ImageColor3 multiplies, so red over a blue
-- blade desaturates to grey and reads as a dimmed copy of the same sword
-- (checked at 158/90/40/0). A shield is not a sword at any size or distance.
local POP_ICON_OUT = Icons.SWORD
local POP_ICON_IN = Icons.SHIELD

-- A reinforcement is the same news at a smaller size. The war did not
-- START, it got FED -- and the two must not read alike, or a declaration
-- stops being an event. Same two objects, so which way it points reads
-- identically; a fraction of the punch, so the bigger news stays bigger.
local POP_REINFORCE_SCALE = 0.68
-- One sword per front per this long. Summaries land five times a second
-- and the intent limit lets a player tap faster than that, so without a
-- floor a spammed reinforcement stacks four swords on one tile.
local POP_REINFORCE_GAP = 0.35

local NationLabels = {}
NationLabels.__index = NationLabels

-- Called from the roster handler, which is the only packet that carries a flag.
-- Static (a dot, not a colon): the caller has the module, not the instance, and
-- there is one label layer per client anyway.
function NationLabels.setFlag(id: number, key: string?)
	flagOwner[id] = (key ~= nil and key ~= Flags.NONE) and key or nil
end

-- A ROUND IS A NEW CAST. Empire ids are reused between rounds, so a stale entry
-- would fly the last occupant's flag over whoever inherits the number.
function NationLabels.clearFlags()
	table.clear(flagOwner)
end

-- `kind` is "ally", "traitor" or nil. Static, like setFlag, and for the same
-- reason. Read on the next update() -- 200 ms at most.
function NationLabels.setMark(id: number, kind: string?)
	markOf[id] = (kind ~= nil and MARK_IMAGE[kind] ~= nil) and kind or nil
end

function NationLabels.clearMarks()
	table.clear(markOf)
end

export type NationLabels = typeof(setmetatable({} :: any, NationLabels))

-- The one formatter, shared with the HUD: the same army must not read as
-- "5.43K" here and "5.4K" in the standings.
-- Troops display at a TENTH of their internal value (upstream
-- renderTroops = renderNumber(t / 10), src/client/Utils.ts). This is the
-- number drawn on a nation's own territory and on an army in the field.
local formatTroops = Numbers.formatTroops

-- Nothing on this map teleports. Summaries land five times a second and a
-- figure that jumps five times a second reads as flicker rather than as
-- information, so every value and every position is WALKED to its new
-- state at these rates (settling in roughly a third of a second).
local COUNT_RATE = 9
local MOVE_RATE = 9

-- ...and a label is not moved at all unless the move is worth making. The
-- anchor is recomputed from scratch each broadcast and wanders by a tile
-- or two even when the nation has not meaningfully changed shape; without
-- a deadband that wander becomes a permanent five-a-second twitch under
-- every name on the map. Fractions of the label's own radius, so a big
-- nation tolerates a bigger wander than a small one.
local ANCHOR_DEADBAND = 0.10
local RADIUS_DEADBAND = 0.06

-- Anchor finding is a spiral scan plus a hill climb, about 0.35 ms per
-- nation. That is nothing for four nations and a dropped frame for
-- twenty-four, five times a second. So only a few are refreshed per
-- broadcast and the rest keep the anchor they have -- which the deadband
-- above already says is the right answer for small movement anyway. A nation
-- whose anchor is a second stale is indistinguishable from one that is not.
local ANCHORS_PER_UPDATE = 6

function NationLabels.new(container: Frame): NationLabels
	local root = Instance.new("Frame")
	root.Name = "NationLabels"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	-- Must not eat map clicks: every input on the map is handled by the
	-- container underneath, and a label swallowing a click would make parts of
	-- your own territory unselectable.
	root.Active = false
	root.ZIndex = 5
	root.Parent = container

	return setmetatable({
		root = root,
		entries = {} :: { [number]: any },
		-- Keyed by the attack's own id, not by attacker: one nation can be
		-- pushing on two fronts and each army carries its own number.
		armies = {} :: { [number]: any },
		-- Live attack-declaration swords. Never pooled: at most a handful
		-- exist at once and each is gone in under a second.
		pops = {} :: { any },
		-- The FIRST armies list after a round starts is the state of the
		-- world, not news -- joining mid-round would otherwise open with a
		-- sword over every war already in progress.
		armiesSeeded = false,
		-- Rotates through `players` so every nation comes up in turn.
		anchorCursor = 0,
		zoom = -1,
	}, NationLabels)
end

-- Built lazily, and only for an empire with a real person behind it. The user
-- id rides with the roster (once, with `init`), a bot has none, and almost
-- every empire on this map is a bot that must not pay for the instances.
local function buildFace(e: any)
	local face = Instance.new("Frame")
	face.Name = "Face"
	face.BorderSizePixel = 0
	face.AnchorPoint = Vector2.new(0.5, 1)
	face.Position = UDim2.fromScale(0.5, -FACE_GAP)
	face.Size = UDim2.fromScale(1, FACE_H)
	-- Same rule as every other label here: it must not eat a map click.
	face.Active = false
	face.ZIndex = 6
	-- step() answers this on the first frame it is asked; starting visible
	-- would flash a face over a nation too small to be carrying one.
	face.Visible = false
	-- Not optional. The holder is twice as wide as it is tall, so a square in
	-- ITS scale units draws as a two-to-one egg. Bind the width to the drawn
	-- height and let the constraint redo the arithmetic on every zoom.
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.DominantAxis = Enum.DominantAxis.Height
	ar.Parent = face
	local fr = Instance.new("UICorner")
	fr.CornerRadius = UDim.new(1, 0)
	fr.Parent = face

	-- Inset inside the disc, so the nation's own ink survives as a ring round
	-- the face: the colour on the map and the person holding it are one
	-- identity, and this is exactly how the standings row already draws it.
	local pic = Instance.new("ImageLabel")
	pic.Name = "Pic"
	pic.BackgroundTransparency = 1
	pic.BorderSizePixel = 0
	pic.ScaleType = Enum.ScaleType.Crop
	-- Roblox frames a headshot with shoulders and empty plate around the
	-- head, and at map scale that padding is most of the disc. Take the
	-- middle 110px of the 150px source instead and let Crop fill with it.
	-- The rect sits above centre because the head does; 110 rather than
	-- anything tighter is what a tall hat or big hair still fits inside.
	pic.ImageRectOffset = Vector2.new(20, 6)
	pic.ImageRectSize = Vector2.new(110, 110)
	pic.Size = UDim2.fromScale(0.84, 0.84)
	pic.Position = UDim2.fromScale(0.08, 0.08)
	pic.Active = false
	pic.ZIndex = 7
	pic.Parent = face
	local pr = Instance.new("UICorner")
	pr.CornerRadius = UDim.new(1, 0)
	pr.Parent = pic

	face.Parent = e.holder
	e.face = face
	e.pic = pic
	return face
end

-- The flag an empire flies, left of its name. Built ON DEMAND like the face,
-- and for the same reason: most empires are bots that will never have one, and
-- a label that never shows a flag should not carry an ImageLabel for it.
local function buildFlag(e: any, id: string)
	if e.flag then
		e.flag:Destroy()
		e.flag = nil
	end
	-- Flags.image paints from an EditableImage and returns nil for an id this
	-- build does not know -- a flag sold after a client shipped, say.
	local img = Flags.image(e.holder, "Flag", id)
	if img == nil then
		e.flagId = nil
		return
	end
	img.Active = false
	img.ZIndex = 6
	-- Anchored on its RIGHT edge: what is being positioned is the gap between the
	-- flag and the name, so the edge that must land precisely is the near one.
	img.AnchorPoint = Vector2.new(1, 0.5)
	img.Size = UDim2.fromScale(1, NAME_H * FLAG_H)
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = Flags.DISPLAY_W / Flags.DISPLAY_H
	ar.DominantAxis = Enum.DominantAxis.Height
	ar.Parent = img
	e.flag = img
	e.flagId = id
end

-- The mark, under the army figure. Built on demand like the face and the flag.
local function buildMark(e: any, kind: string)
	if e.mark then
		e.mark:Destroy()
		e.mark = nil
	end
	local img = Instance.new("ImageLabel")
	img.Name = "Mark"
	img.BackgroundTransparency = 1
	img.Image = MARK_IMAGE[kind]
	img.ScaleType = Enum.ScaleType.Fit
	-- Same rule as every other label here: it must not eat a map click.
	img.Active = false
	img.ZIndex = 6
	-- step() answers this on the first frame it is asked, as with the face.
	img.Visible = false
	img.Size = UDim2.fromScale(1, MARK_H)
	-- Hung off the FOOT of the holder, centred under the figure: the army
	-- row ends at TROOPS_Y + TROOPS_H = 1.
	img.AnchorPoint = Vector2.new(0.5, 0)
	img.Position = UDim2.fromScale(0.5, 1 + MARK_GAP)
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.DominantAxis = Enum.DominantAxis.Height
	ar.Parent = img
	img.Parent = e.holder
	e.mark = img
	e.markKind = kind
	e.markVis = nil
end

local function build(self: NationLabels, id: number)
	local holder = Instance.new("Frame")
	holder.Name = "N" .. id
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Active = false
	holder.ZIndex = 5
	holder.Parent = self.root

	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.BackgroundTransparency = 1
	name.FontFace = FONT
	name.TextScaled = true
	name.Active = false
	name.ZIndex = 6
	name.Size = UDim2.fromScale(1, NAME_H)
	name.Position = UDim2.fromScale(0, 0)
	-- TextScaled refuses to grow past 100px without an explicit constraint, and
	-- a nation filling the screen needs far more than that.
	local con = Instance.new("UITextSizeConstraint")
	con.MinTextSize = 1
	con.MaxTextSize = 400
	con.Parent = name
	name.Parent = holder

	local troops = name:Clone()
	troops.Name = "Troops"
	troops.Size = UDim2.fromScale(1, TROOPS_H)
	troops.Position = UDim2.fromScale(0, TROOPS_Y)
	troops.Parent = holder

	-- Built here rather than on demand like the face and the flag: those two
	-- belong to the handful of empires that have a person or a flag behind
	-- them, and every label without exception carries a figure.
	local sword = Instance.new("ImageLabel")
	sword.Name = "Sword"
	sword.BackgroundTransparency = 1
	sword.Image = Icons.SWORD
	-- Fit, always -- the sticker's outline stretches with the box otherwise.
	sword.ScaleType = Enum.ScaleType.Fit
	-- Same rule as every other label here: it must not eat a map click.
	sword.Active = false
	sword.ZIndex = 6
	-- Anchored on its RIGHT edge, like the flag: what is being placed is the
	-- gap between the blade and the first digit, so the edge that has to land
	-- precisely is the near one. step() walks it to the rendered figure.
	sword.AnchorPoint = Vector2.new(1, 0.5)
	sword.Position = UDim2.fromScale(0.5 - SWORD_GAP, TROOPS_Y + TROOPS_H / 2)
	sword.Size = UDim2.fromScale(1, TROOPS_H * SWORD_H)
	-- Not optional, for the reason the face needs one: the holder is twice as
	-- wide as it is tall, so a square in ITS scale units draws as a two-to-one
	-- smear. Bind the width to the drawn height instead.
	local sr = Instance.new("UIAspectRatioConstraint")
	sr.AspectRatio = 1
	sr.DominantAxis = Enum.DominantAxis.Height
	sr.Parent = sword
	sword.Parent = holder

	-- ax/ay/radius are where the label is HEADED; cx/cy/cr are where it is
	-- drawn this frame. `moving` is what lets a settled
	-- label cost nothing per frame instead of rewriting the same values.
	local entry = {
		holder = holder, name = name, troops = troops, text = "",
		ax = 0, ay = 0, radius = 0,
		cx = 0, cy = 0, cr = 0,
		moving = false, numTarget = 0, numShown = 0, numText = "", vis = nil,
		-- Built on demand in update(), and only for a human. faceVis is its
		-- own flag because a face leaves the map before its name does.
		face = nil, pic = nil, userId = 0, faceVis = nil,
		flag = nil, flagId = nil,
		mark = nil, markKind = nil, markVis = nil,
		-- swordFrac is the figure's measured width share the blade is currently
		-- parked against; -1 so the first measurement always takes.
		sword = sword, swordFrac = -1, swordVis = nil,
	}
	self.entries[id] = entry
	return entry
end

-- `players` is the server's summary list; `renderer` supplies the anchors.
function NationLabels.update(self: NationLabels, renderer: any, players: { any }, localId: number)
	local seen = {}
	local n = #players
	local cursor = self.anchorCursor

	for i, p in players do
		if p.tiles and p.tiles >= MIN_TILES and p.alive then
			local e = self.entries[p.id]
			-- A nation with no anchor yet cannot be drawn at all, so it is
			-- always computed; the rest take their turn in the window.
			local due = e == nil or e.radius <= 0
				or (i - 1 - cursor) % n < ANCHORS_PER_UPDATE

			local ax, ay, radius
			if due then
				ax, ay, radius = renderer:nationAnchor(p.id)
			else
				ax, ay, radius = e.ax, e.ay, e.radius
			end

			if ax and radius and radius > 4 then
				seen[p.id] = true
				e = e or build(self, p.id)

				-- Text is the nation's own colour driven dark, haloed in the
				-- same colour driven light: legible on every hue, and still
				-- unmistakably that nation's label. Derived from the fill
				-- rather than a palette entry of its own, so it follows any
				-- later change to the nation colours for free.
				local fr, fg, fb = Palette.colorFor(p.id, localId)
				local ink = Color3.fromRGB(fr * 0.30, fg * 0.30, fb * 0.34)
				local halo = Color3.fromRGB(
					fr + (255 - fr) * 0.55,
					fg + (255 - fg) * 0.55,
					fb + (255 - fb) * 0.55
				)

				if e.text ~= p.name then
					e.text = p.name
					e.name.Text = p.name
				end
				-- A target, not a value: step() walks the drawn figure to it.
				e.numTarget = math.floor(p.troops or 0)

				for _, t in { e.name, e.troops } do
					t.TextColor3 = ink
					-- The legacy text stroke, not a UIStroke: it scales with
					-- the text, and this text ranges from 4px to 400px as the
					-- camera moves. A fixed-thickness UIStroke would swallow
					-- the glyphs at one end and vanish at the other.
					t.TextStrokeColor3 = halo
					t.TextStrokeTransparency = 0.15
				end

				-- The face behind the nation, over its name. Since 2026-09-25
				-- EVERY empire has one: a person's headshot, a faux player's
				-- rendered avatar, or an AI nation's (Faces). A face no longer
				-- says "a person is playing this".
				local uid = p.userId
				-- An account's headshot or a crowd face (negative id); nil
				-- means no face at all. See Faces.
				local url = Faces.url(uid, 150)
				if url then
					local face = e.face or buildFace(e)
					if e.userId ~= uid then
						e.userId = uid
						-- rbxthumb resolves on the client with no web call of
						-- our own. GetUserThumbnailAsync yields, and yielding
						-- here would be a request per label per broadcast.
						e.pic.Image = url
					end
					-- The same ink as the text beneath it, so the ring and
					-- the name read as one object in one nation's colour.
					face.BackgroundColor3 = ink
				elseif e.face then
					-- The person let go of it. On a predrawn map a claim moves
					-- from nation to nation during the spawn phase and the
					-- face rides the claim (ConquestServer's roster), so a
					-- label can lose the face it was built with.
					e.face:Destroy()
					e.face, e.pic, e.userId, e.faceVis = nil, nil, 0, nil
				end

				-- THE FLAG, placed against the RENDERED name rather than at a fixed
				-- offset: the name is centre-aligned and TextScaled, so where its
				-- first letter falls moves with the word. Same measurement the
				-- shop's Robux glyph uses.
				--
				-- Measured HERE, not in step(): TextBounds/AbsoluteSize is a ratio,
				-- and TextScaled keeps that ratio steady as the label zooms, so the
				-- per-frame loop stays untouched and a settled label still costs
				-- nothing.
				local fid = flagOwner[p.id]
				if fid ~= nil and fid ~= "" and Flags.has(fid) then
					if e.flagId ~= fid then
						buildFlag(e, fid)
					end
					local fw = e.name.AbsoluteSize.X
					if e.flag and fw > 1 then
						local frac = math.clamp(e.name.TextBounds.X / fw, 0, 1)
						e.flag.Position = UDim2.fromScale(0.5 - frac / 2 - FLAG_GAP, NAME_H / 2)
					end
				elseif e.flag then
					-- Same reason the face is torn down above: a claim can move.
					e.flag:Destroy()
					e.flag, e.flagId = nil, nil
				end

				-- THE DIPLOMACY MARK. Rebuilt only when the kind changes.
				local mk = markOf[p.id]
				if mk ~= nil then
					if e.markKind ~= mk then
						buildMark(e, mk)
					end
				elseif e.mark then
					e.mark:Destroy()
					e.mark, e.markKind, e.markVis = nil, nil, nil
				end

				-- Take the new anchor only if it has moved enough to be worth
				-- moving for. Below the deadband the label does not stir; above
				-- it, step() slides there. Either way it never jumps.
				if
					e.radius <= 0
					or math.abs(ax - e.ax) > e.radius * ANCHOR_DEADBAND
					or math.abs(ay - e.ay) > e.radius * ANCHOR_DEADBAND
					or math.abs(radius - e.radius) > e.radius * RADIUS_DEADBAND
				then
					e.ax, e.ay, e.radius = ax, ay, radius
					e.moving = true
				end
			end
		end
	end

	self.anchorCursor = n > 0 and (cursor + ANCHORS_PER_UPDATE) % n or 0

	for id, e in self.entries do
		if not seen[id] then
			e.holder:Destroy()
			self.entries[id] = nil
		end
	end

end

local function buildArmy(self: NationLabels, key: number)
	local label = Instance.new("TextLabel")
	label.Name = "A" .. key
	label.BackgroundTransparency = 1
	label.FontFace = FONT
	label.TextScaled = true
	label.Active = false
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.ZIndex = 7
	-- Black, always. Upstream's text shader mixes the fill toward vec3(0.0)
	-- and hangs a black halo off it (world-text.frag.glsl) -- a coloured
	-- number over coloured territory does not survive without one.
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0
	local con = Instance.new("UITextSizeConstraint")
	con.MinTextSize = 1
	con.MaxTextSize = 220
	con.Parent = label
	label.Parent = self.root

	local e = {
		label = label,
		ax = 0, ay = 0,
		cx = 0, cy = 0,
		placed = false, sizedAt = -1, tint = nil :: Color3?,
		numTarget = 0, numShown = 0, numText = "",
	}
	self.armies[key] = e
	return e
end

local function spawnPop(self: NationLabels, x: number, y: number, incoming: boolean, scale: number?)
	local img = Instance.new("ImageLabel")
	img.Name = "Pop"
	img.BackgroundTransparency = 1
	img.Image = if incoming then POP_ICON_IN else POP_ICON_OUT
	img.ScaleType = Enum.ScaleType.Fit
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Same rule as every other label here: it must not eat a map click.
	img.Active = false
	img.ZIndex = 9
	img.Size = UDim2.fromScale(0, 0)
	img.Position = UDim2.fromScale(x / W, y / H)
	img.Parent = self.root
	table.insert(self.pops, { img = img, x = x, y = y, t = 0, scale = scale or 1 })
end

-- A DECLARATION THE SERVER IS NEVER GOING TO SEND. Sim.armies drops any attack
-- whose target is nobody (`atk.targetId ~= 0`), which is upstream's rule and a
-- right one for the NUMBER: expansion's front wraps the whole country, so its
-- figure would sit on the nation's own name. The SWORD is a different object --
-- it lives for POP_LIFE at one tile and never has to find a front -- and
-- without it the single most common thing a player does, taking empty ground,
-- was the one action on this map that answered with nothing.
--
-- So the client raises it ITSELF, on the press, at the tile it just clicked --
-- the same optimism the ring and the attack cue already run on, and for the
-- same reason: the server's answer is a round trip away.
--
-- THROTTLED, not queued. The intent limiter lets a player tap faster than this
-- pop lives, and four swords stacked on one tile is a smear rather than an
-- event -- the same floor a reinforcement gets, for the same reason.
function NationLabels.declare(self: NationLabels, tile: number, incoming: boolean?)
	local now = os.clock()
	if now - (self.lastDeclare or -1e9) < POP_REINFORCE_GAP then
		return
	end
	self.lastDeclare = now
	local x = tile % W
	spawnPop(self, x, (tile - x) / W, incoming == true)
end

-- The armies in the field: a number on the front each one is fighting on.
--
-- ONLY YOUR SIDE'S WARS GET ONE. Upstream's controller walks the local
-- player's own outgoing and incoming attacks and labels nothing else
-- (src/client/controllers/AttackingTroopsController.ts:112-132), and that
-- is what keeps its map readable: across this roster, a number over every
-- war on the continent buries the two that are yours under sixty that are
-- not. Conquest widens "yours" to your TEAM (owner, 2026-09-06): a
-- teammate's push and the army coming for a teammate are wars you are in
-- whether you sent the men or not, and in a team game the map is read as
-- a side. Colour stays DIRECTION -- blue for men your side sent, red for
-- men coming at it -- so a teammate's war reads exactly like your own.
-- The server has already cut the list to attacks some human is in; this
-- is where it becomes your side's.
--
-- These men are not in their nation's garrison figure -- the server moved
-- them out of it the moment they were committed -- so sending half your
-- army away visibly halves the number on your land and puts the other
-- half on the border where it is actually doing something.
function NationLabels.setArmies(
	self: NationLabels,
	list: { any },
	localId: number,
	teamById: { [number]: number }?,
	myTeam: number?
)
	local seen = {}

	-- Yourself, or anyone wearing your team. In a free-for-all `myTeam` is
	-- nil and this collapses to the upstream rule: you and nobody else.
	local function onMySide(id: number): boolean
		if id == localId then
			return true
		end
		return myTeam ~= nil and teamById ~= nil and teamById[id] == myTeam
	end

	-- Grouped by attack before anything is placed: an attack fighting on
	-- two disconnected fronts carries a number on each, and the two have to
	-- be matched to the right front -- see the swap below.
	local byAttack = {}
	local order = {}
	for _, a in list do
		if onMySide(a.id) or onMySide(a.t) then
			local g = byAttack[a.a]
			if not g then
				g = { incoming = onMySide(a.t) }
				byAttack[a.a] = g
				table.insert(order, a.a)
			end
			g[a.c + 1] = a
		end
	end

	for _, atkId in order do
		local g = byAttack[atkId]
		local a0, a1 = g[1], g[2]

		-- The server sorts an attack's fronts by SIZE, so the instant one
		-- outgrows the other the pair swaps and both labels fly across the
		-- map past each other. Upstream keeps whichever pairing moves less
		-- (alignClusterOrder, AttackingTroopsController.ts:54-65). Four
		-- subtractions, and the difference between two numbers sitting on
		-- their fronts and two numbers trading places.
		if a0 and a1 then
			local e0 = self.armies[atkId * 4]
			local e1 = self.armies[atkId * 4 + 1]
			if e0 and e1 and e0.placed and e1.placed then
				local function d(e, a)
					return math.abs(a.x - e.ax) + math.abs(a.y - e.ay)
				end
				if d(e0, a1) + d(e1, a0) < d(e0, a0) + d(e1, a1) then
					a0, a1 = a1, a0
				end
			end
		end

		for i, a in { a0, a1 } do
			local key = atkId * 4 + (i - 1)
			local e = self.armies[key]
			if not e then
				e = buildArmy(self, key)
				if self.armiesSeeded then
					spawnPop(self, a.x, a.y, g.incoming)
				end
			elseif self.armiesSeeded and a.troops > e.numTarget then
				-- An army in the field only ever SPENDS men. The sim adds to a
				-- live attack in exactly one place -- launchAttack folding a
				-- repeat attack into the running push rather than opening a
				-- second front -- so a number that goes UP is a reinforcement
				-- and nothing else. Both fronts of one attack carry the same
				-- figure, so the pair swap above cannot fake this either.
				--
				-- And it is news for the same reason a declaration is: the
				-- fight just got bigger, on a border you may not be looking at.
				-- Feeding your own push and watching an enemy feed theirs are
				-- the two halves of a war you cannot read off a drifting number.
				local now = os.clock()
				if now - (e.lastPop or 0) >= POP_REINFORCE_GAP then
					e.lastPop = now
					spawnPop(self, a.x, a.y, g.incoming, POP_REINFORCE_SCALE)
				end
			end
			seen[key] = true

			-- A target, not a value; step() walks the drawn figure to it.
			e.numTarget = a.troops

			local tint = if g.incoming then ARMY_IN else ARMY_OUT
			if e.tint ~= tint then
				e.tint = tint
				e.label.TextColor3 = tint
			end

			-- No deadband here, unlike a nation's name. A front-line tile
			-- is a real position that genuinely moves as the battle does,
			-- and there are at most a handful of these on screen -- where a
			-- nation anchor is recomputed from scratch and wanders whether
			-- the country changed or not.
			e.ax, e.ay = a.x, a.y
			if e.placed and (e.ax - e.cx) ^ 2 + (e.ay - e.cy) ^ 2 > ARMY_SNAP_TILES ^ 2 then
				e.cx, e.cy = e.ax, e.ay
			end
		end
	end

	for key, e in self.armies do
		if not seen[key] then
			e.label:Destroy()
			self.armies[key] = nil
		end
	end

	self.armiesSeeded = true
end

-- Called every frame. This is the only place anything is actually drawn:
-- update() and setArmies() set targets, and this walks the labels to them.
-- A settled label costs one comparison -- it is not rewritten, which is
-- the difference between "does not move" and "is moved to where it
-- already was" five times a second.
function NationLabels.step(self: NationLabels, dt: number, zoom: number)
	local k = 1 - math.exp(-dt * MOVE_RATE)
	local zoomed = self.zoom ~= zoom
	self.zoom = zoom

	for _, e in self.entries do
		if e.moving then
			if e.cr <= 0 then
				-- First frame of a new label: appear in place rather than fly
				-- in from the top-left corner of the map.
				e.cx, e.cy, e.cr = e.ax, e.ay, e.radius
			else
				e.cx += (e.ax - e.cx) * k
				e.cy += (e.ay - e.cy) * k
				e.cr += (e.radius - e.cr) * k
			end
			if
				math.abs(e.ax - e.cx) < 0.05
				and math.abs(e.ay - e.cy) < 0.05
				and math.abs(e.radius - e.cr) < 0.05
			then
				e.cx, e.cy, e.cr = e.ax, e.ay, e.radius
				e.moving = false
			end
			e.holder.Size = UDim2.fromScale(e.cr * 2.3 / W, e.cr * 1.15 / H)
			e.holder.Position = UDim2.fromScale(e.cx / W, e.cy / H)
			zoomed = true
		end

		if e.numShown ~= e.numTarget then
			e.numShown = Numbers.approach(e.numShown, e.numTarget, dt, COUNT_RATE)
			local t = formatTroops(e.numShown)
			if t ~= e.numText then
				e.numText = t
				e.troops.Text = t
			end
		end

		-- THE BLADE RIDES THE FIGURE. The army text is centred and TextScaled,
		-- so where its first character falls moves with the number -- "23" and
		-- "1.30K" do not start in the same place, and a count walking from one
		-- to the other moves that edge every few frames.
		--
		-- Measured here rather than at the write above, because TextBounds has
		-- no answer for text set this frame: the label has not been laid out
		-- yet, and a blade one frame behind the digit it flanks is invisible.
		--
		-- And it is a RATIO, not a size -- the same measurement the flag takes,
		-- for the same reason. TextScaled holds TextBounds/AbsoluteSize steady
		-- as the camera zooms, so a settled label lands on the fraction it is
		-- already parked at and is not written to at all.
		if e.vis ~= false then
			local tw = e.troops.AbsoluteSize.X
			if tw > 1 then
				local frac = math.clamp(e.troops.TextBounds.X / tw, 0, 1)
				if math.abs(frac - e.swordFrac) > 0.002 then
					e.swordFrac = frac
					e.sword.Position =
						UDim2.fromScale(0.5 - frac / 2 - SWORD_GAP, TROOPS_Y + TROOPS_H / 2)
				end
			end
		end

		if zoomed or e.swordVis == nil or (e.face and e.faceVis == nil) or (e.mark and e.markVis == nil) then
			local h = e.cr * 1.15 * zoom
			local vis = h >= MIN_ON_SCREEN_PX
			if e.vis ~= vis then
				e.vis = vis
				e.holder.Visible = vis
			end
			-- A face needs more room than a name does, so it goes first on
			-- the way out and comes back last. And one built after its label
			-- had already settled has no answer yet -- that is the nil.
			if e.face then
				local fvis = h * FACE_H >= MIN_FACE_PX
				if e.faceVis ~= fvis then
					e.faceVis = fvis
					e.face.Visible = fvis
				end
			end
			-- The mark keeps the face's threshold: a handshake the size of a
			-- pin is a smudge.
			if e.mark then
				local mvis = h * MARK_H >= MIN_FACE_PX
				if e.markVis ~= mvis then
					e.markVis = mvis
					e.mark.Visible = mvis
				end
			end
			-- The blade goes before the number does, and never after it: a
			-- figure with no glyph beside it is the map as it was, while a
			-- glyph beside an unreadable smear is two smears.
			local svis = h * TROOPS_H * SWORD_H >= MIN_SWORD_PX
			if e.swordVis ~= svis then
				e.swordVis = svis
				e.sword.Visible = svis
			end
		end
	end

	-- Attack numbers do not scale with the land under them. The camera
	-- already scales the container every label lives in, so dividing by
	-- zoom cancels it exactly and leaves a constant on-screen size --
	-- upstream's ATTACK_LABEL_SCREEN_SCALE / zoom, WorldTextPass.ts:454.
	local armyH = ARMY_PX / math.max(zoom, 1e-4)
	local armySize = UDim2.fromScale(armyH * ARMY_WIDTH_RATIO / W, armyH / H)

	for _, e in self.armies do
		if not e.placed then
			-- A new front appears where it is, rather than flying in from
			-- wherever this pooled label was last used.
			e.placed = true
			e.cx, e.cy = e.ax, e.ay
		else
			e.cx += (e.ax - e.cx) * k
			e.cy += (e.ay - e.cy) * k
		end
		e.label.Position = UDim2.fromScale(e.cx / W, e.cy / H)

		-- Rewritten only when the size actually changed -- on a zoom, and
		-- on the frame a label is born. Not five times a second.
		if e.sizedAt ~= armyH then
			e.sizedAt = armyH
			e.label.Size = armySize
		end

		if e.numShown ~= e.numTarget then
			e.numShown = Numbers.approach(e.numShown, e.numTarget, dt, COUNT_RATE)
			local t = formatTroops(e.numShown)
			if t ~= e.numText then
				e.numText = t
				e.label.Text = t
			end
		end
	end

	-- Swords live well under a second, so they are stepped here rather than
	-- handed to TweenService: a tween outlives the round it belongs to, and
	-- clear() would leave one finishing over the next map.
	if #self.pops > 0 then
		local d = POP_PX / math.max(zoom, 1e-4)
		local rise = POP_RISE / math.max(zoom, 1e-4)
		for i = #self.pops, 1, -1 do
			local p = self.pops[i]
			p.t += dt
			local f = p.t / POP_LIFE
			if f >= 1 then
				p.img:Destroy()
				table.remove(self.pops, i)
			else
				-- Smoothstepped out of nothing over the first fifth, then a
				-- slow settle from 118%: a punch, not a fade-in.
				local a = math.min(f / 0.2, 1)
				a = a * a * (3 - 2 * a)
				local s = a * (1.18 - 0.18 * f) * d * p.scale
				p.img.Size = UDim2.fromScale(s / W, s / H)
				p.img.Position = UDim2.fromScale(p.x / W, (p.y - rise * f) / H)
				p.img.ImageTransparency = math.max(0, (f - 0.55) / 0.45)
			end
		end
	end
end

function NationLabels.clear(self: NationLabels)
	for id, e in self.entries do
		e.holder:Destroy()
		self.entries[id] = nil
	end
	for key, e in self.armies do
		e.label:Destroy()
		self.armies[key] = nil
	end
	for _, p in self.pops do
		p.img:Destroy()
	end
	table.clear(self.pops)
	self.armiesSeeded = false
end

function NationLabels.destroy(self: NationLabels)
	self.root:Destroy()
	table.clear(self.entries)
	table.clear(self.armies)
	table.clear(self.pops)
end

return NationLabels