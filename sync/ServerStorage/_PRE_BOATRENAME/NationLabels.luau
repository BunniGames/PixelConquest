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

local Palette = require(script.Parent.Palette)
local Config = require(script.Parent.Config)
local Numbers = require(script.Parent.Numbers)
local Icons = require(script.Parent.Icons)

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
	name.Size = UDim2.fromScale(1, 0.62)
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
	troops.Size = UDim2.fromScale(1, 0.34)
	troops.Position = UDim2.fromScale(0, 0.66)
	troops.Parent = holder

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

				-- The person behind the nation, over their own name. Only a
				-- human has a user id, and only a human gets a face -- which
				-- is the whole point: among seventy-odd generated names, the
				-- ones with a face are the ones you are playing against.
				local uid = p.userId
				if uid and uid > 0 then
					local face = e.face or buildFace(e)
					if e.userId ~= uid then
						e.userId = uid
						-- rbxthumb resolves on the client with no web call of
						-- our own. GetUserThumbnailAsync yields, and yielding
						-- here would be a request per label per broadcast.
						e.pic.Image = "rbxthumb://type=AvatarHeadShot&id=" .. uid .. "&w=150&h=150"
					end
					-- The same ink as the text beneath it, so the ring and
					-- the name read as one object in one nation's colour.
					face.BackgroundColor3 = ink
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

-- The armies in the field: a number on the front each one is fighting on.
--
-- ONLY YOUR WARS GET ONE. Upstream's controller walks the local player's
-- own outgoing and incoming attacks and labels nothing else
-- (src/client/controllers/AttackingTroopsController.ts:112-132), and that
-- is what keeps its map readable: across this roster, a number over every
-- war on the continent buries the two that are yours under sixty that are
-- not. The server has already cut the list to attacks some human is in;
-- this is where it becomes yours.
--
-- These men are not in their nation's garrison figure -- the server moved
-- them out of it the moment they were committed -- so sending half your
-- army away visibly halves the number on your land and puts the other
-- half on the border where it is actually doing something.
function NationLabels.setArmies(self: NationLabels, list: { any }, localId: number)
	local seen = {}

	-- Grouped by attack before anything is placed: an attack fighting on
	-- two disconnected fronts carries a number on each, and the two have to
	-- be matched to the right front -- see the swap below.
	local byAttack = {}
	local order = {}
	for _, a in list do
		if a.id == localId or a.t == localId then
			local g = byAttack[a.a]
			if not g then
				g = { incoming = a.t == localId }
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

		if zoomed or (e.face and e.faceVis == nil) then
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