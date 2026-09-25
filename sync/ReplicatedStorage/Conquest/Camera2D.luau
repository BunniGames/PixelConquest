--!strict
-- Conquest :: Camera2D  (client only)
-- Pan/zoom over the map image. Holds map-space <-> screen-space conversion
-- and keeps the view clamped so the map can never be lost off-screen.

local Config = require(script.Parent.Config)

local W = Config.MAP_W
local H = Config.MAP_H

local Camera2D = {}
Camera2D.__index = Camera2D

export type Camera2D = typeof(setmetatable({} :: any, Camera2D))

function Camera2D.new(): Camera2D
	return setmetatable({
		zoom = Config.DEFAULT_ZOOM,
		x = 0, -- screen px offset of map pixel (0,0)
		y = 0,
		viewW = 1280,
		viewH = 720,
		-- Screen pixels of kick, written by the client while a warhead is going
		-- off and decayed by it. It lives here, and `apply` adds it, because
		-- `apply` is the ONE writer of where the map actually is -- a shake
		-- applied to the container directly would leave screenToTile pointing a
		-- few pixels away from the picture for as long as it lasted, which on a
		-- fully zoomed-out map is a couple of tiles.
		shakeX = 0,
		shakeY = 0,
		-- HOW FAR THE MAP MAY BE PUSHED PAST THE VIEWPORT, top and bottom, in
		-- screen px. The HUD is not a frame around the map, it sits ON it: the
		-- command bar owns the bottom fifth of the screen and the alert line the
		-- top tenth. Clamped hard to the viewport, those two bands were map nobody
		-- could ever look at -- at fit zoom the whole southern coast lived under
		-- the bar with no pan left to give it back. These are the heights of the
		-- two bands, written by the client from the HUD's own geometry, so the
		-- overscroll each way is exactly the thing that is covering the map.
		padTop = 0,
		padBottom = 0,
		-- TRUE WHILE FINGERS ARE ON THE GLASS. The rest clamp below is a vice
		-- that closes to nothing at the zoom where the map exactly fills an axis,
		-- so a live gesture is given a viewport of slack and `settle` walks the
		-- map home the moment the fingers lift.
		soft = false,
		settling = false,
		-- When a TIMED hold expires (os.clock). 0 means the hold is explicit --
		-- fingers on the glass -- and ends when they lift, not on a clock.
		softUntil = 0,

		-- The rect `apply` last drew, in viewport pixels. See screenToTile.
		drawX = 0,
		drawY = 0,
		drawW = 0,
		drawH = 0,
	}, Camera2D)
end

function Camera2D.setViewport(self: Camera2D, w: number, h: number)
	self.viewW = w
	self.viewH = h
end

-- The heights of the HUD's top and bottom bands, in viewport px. Written on
-- every viewport change from the HUD's own constants, so nothing here carries
-- a second copy of where the command bar is.
function Camera2D.setInsets(self: Camera2D, top: number, bottom: number)
	self.padTop = top
	self.padBottom = bottom
end

function Camera2D.centerOnTile(self: Camera2D, tile: number)
	local tx = tile % W
	local ty = (tile - tile % W) / W
	self.x = self.viewW / 2 - tx * self.zoom
	-- The middle of what you can SEE, not the middle of the window: the command
	-- bar owns the bottom fifth, so a tile parked at viewH / 2 sits low on the
	-- map that is actually showing.
	self.y = (self.padTop + self.viewH - self.padBottom) / 2 - ty * self.zoom
	Camera2D.clamp(self)
end

-- Shows the WHOLE map (min, not max): during the spawn phase you are choosing
-- where on the country to start, so nothing may be cropped off-screen -- and a
-- coast under the command bar is cropped as surely as a coast past the edge of
-- the window. So the fit is against the viewport MINUS the two HUD bands, and
-- the map is centred in what is left. That is a slightly smaller country than
-- the window alone would allow, and every tile of it can be seen and clicked.
function Camera2D.fit(self: Camera2D)
	local clearH = math.max(self.viewH - self.padTop - self.padBottom, 1)
	self.zoom = math.clamp(
		math.min(self.viewW / W, clearH / H),
		Config.MIN_ZOOM,
		Config.MAX_ZOOM
	)
	self.x = (self.viewW - W * self.zoom) / 2
	self.y = self.padTop + (clearH - H * self.zoom) / 2
	-- This IS the rest position, so nothing is owed a walk home.
	self.settling = false
end

-- The map can never be lost off-screen, so each axis is clamped to the travel
-- that keeps the viewport covered -- PLUS `padA` / `padB` of overscroll, which
-- is what lets a player pull the map's bottom edge up out from under the
-- command bar. Held there it shows the paper behind the map in the band the
-- bar is standing on, and that is the right trade: a strip of background is
-- something you chose to look at, a coastline welded under an opaque panel is
-- not.
--
-- A MAP SMALLER THAN THE VIEW IS NOT PINNED TO THE CENTRE (owner, 2026-09-06:
-- "when you zoom in and out on mobile it seems as if it's trying to fit to
-- screen"). It used to be: below the zoom where the map fits the axis, the
-- only legal position was centred, and a zoom anchored under two fingers
-- was overridden by the recentre on the next line -- on a phone the map is
-- narrower than the screen below zoom 0.96, so nearly every pinch-out slid
-- the ground 110 px out from under the hand (measured, 844x390). Now the two
-- rest positions -- map's near edge at the near band, map's far edge at the
-- far band -- bound the travel WHICHEVER ORDER they come in, so a small map
-- may sit anywhere inside the clear strip and a large one may retreat from
-- each edge by that edge's band, exactly as before. The two regimes meet
-- where the map exactly fills the strip, with one legal position, so
-- crossing the fit zoom never jumps. `fit` still centres the spawn view
-- explicitly; this no longer does it for it.
local function restBounds(view: number, map: number, padA: number, padB: number): (number, number)
	local a = padA -- near edge of the map just past the near band
	local b = view - padB - map -- far edge of the map just before the far band
	return math.min(a, b), math.max(a, b)
end

-- A GESTURE IS NOT CLAMPED THE WAY A REST POSITION IS (owner, 2026-09-14:
-- "when mobile players zoom in and out its hella buggy, especially when the
-- table behind is about to show").
--
-- The rest rule above is right, and it is also a vice that closes on the
-- pinch. Its legal interval is |view - map| wide, so it narrows to NOTHING at
-- the zoom where the map exactly fills the axis -- and those zooms are where a
-- phone lives. On 844x390 the map fills the WIDTH at zoom 0.96, which is the
-- very moment the desk appears at the sides (that is the "table behind"), and
-- fills the clear strip at 0.50, which is the fit zoom the round opens at.
-- Both sit inside the band a thumb actually uses, so `zoomAt` would put the
-- ground under the fingers and `clamp` would shove it straight back out on the
-- next line. MEASURED on 844x390 over a 20-step pinch-out: the ground moved
-- 98px away from the fingers anchored right of centre, 85px anchored dead
-- centre, 121px low-left. On 1920x1080 those two zooms are 2.18 and 1.39 --
-- past where the wheel goes -- which is why this only ever read as mobile.
--
-- So WHILE FINGERS ARE DOWN the map may sit anywhere within a viewport of the
-- rest region, and `settle` eases it back when they lift. Drift during the
-- gesture is then zero by construction, and the ease home is short: 51px x /
-- 115px y worst case over those same gestures. The 2026-09-06 pass reached for
-- this and stopped half way -- it removed the RECENTRE but kept the vice, and
-- a single legal position is a pin whatever else it is called.
local function clampAxis(pos: number, view: number, map: number, padA: number, padB: number, slack: number): number
	local lo, hi = restBounds(view, map, padA, padB)
	return math.clamp(pos, lo - slack, hi + slack)
end

function Camera2D.clamp(self: Camera2D)
	-- No horizontal slack: nothing on this HUD spans a SIDE of the screen the
	-- way the command bar spans its foot.
	local sx = self.soft and self.viewW or 0
	local sy = self.soft and self.viewH or 0
	self.x = clampAxis(self.x, self.viewW, W * self.zoom, 0, 0, sx)
	self.y = clampAxis(self.y, self.viewH, H * self.zoom, self.padTop, self.padBottom, sy)
end

-- Held open for as long as two fingers are on the glass. Turning it off does
-- NOT snap: it arms `settle`, so the release is a release and not a second
-- jump in the opposite direction.
function Camera2D.setSoft(self: Camera2D, on: boolean)
	self.soft = on
	-- An explicit hold has no deadline: the fingers decide when it is over.
	self.softUntil = 0
	if not on then
		self.settling = true
	end
end

-- THE SAME SLACK FOR A ZOOM THAT HAS NO RELEASE EVENT -- the mouse wheel and
-- the pad's triggers. A pinch has two ends a finger can lift off; a wheel notch
-- is a lone event and a trigger is a held analogue value, so those paths say
-- how long the hold should OUTLIVE the last input instead, and `settle` ends it
-- when the clock runs out.
--
-- AND THIS IS NOT A CONSOLE-ONLY REPAIR, though that is what went looking for
-- it (owner, 2026-09-14: "can you double check all console features can be
-- used"). The vice described above closes at the zoom where the map fills an
-- axis, and that zoom exists on EVERY device -- it is 1.39 and 2.18 on
-- 1920x1080, 0.93 and 1.46 on a 1280x720 TV, both squarely inside the range a
-- wheel or a trigger sweeps. MEASURED with on-map anchors: a wheel sweep from
-- 2.40 out to 0.66 dragged the ground 69px away from the cursor on 1920x1080
-- and 186px on 1280x720; a full trigger pull for a second, 43px and 119px. The
-- first pass at this fixed the pinch only, and reported the desktop as clean on
-- the strength of a gesture that started at 1.20 and never crossed 1.39.
function Camera2D.softFor(self: Camera2D, seconds: number)
	self.soft = true
	self.softUntil = os.clock() + seconds
end

-- Eases the map back inside the rest region after a gesture. Exponential, so
-- it is frame-rate independent, and it writes `self.settling` instead of
-- returning into a new local: the frame loop reads that field to decide
-- whether it owes the container an `apply` this frame, and ConquestClient is
-- at its register ceiling.
--
-- `settling` is cleared one frame AFTER arriving, not on the frame the ease
-- lands: the frame it snaps still has to reach `apply`, or the container keeps
-- the position from the frame before it and the map rests half a pixel out.
local SETTLE_TAU = 0.055
local SETTLE_SNAP = 0.5

function Camera2D.settle(self: Camera2D, dt: number)
	if self.soft then
		-- A timed hold ends itself here, which is why this runs before the
		-- `settling` test: the wheel and the triggers have nothing else to
		-- close them. An explicit hold (softUntil 0) waits for setSoft(false).
		if self.softUntil > 0 and os.clock() >= self.softUntil then
			Camera2D.setSoft(self, false)
		else
			return
		end
	end
	if not self.settling then
		return
	end
	local lox, hix = restBounds(self.viewW, W * self.zoom, 0, 0)
	local loy, hiy = restBounds(self.viewH, H * self.zoom, self.padTop, self.padBottom)
	local tx = math.clamp(self.x, lox, hix)
	local ty = math.clamp(self.y, loy, hiy)
	if self.x == tx and self.y == ty then
		self.settling = false
		return
	end
	local k = 1 - math.exp(-dt / SETTLE_TAU)
	self.x += (tx - self.x) * k
	self.y += (ty - self.y) * k
	if math.abs(tx - self.x) <= SETTLE_SNAP and math.abs(ty - self.y) <= SETTLE_SNAP then
		self.x, self.y = tx, ty
	end
end

function Camera2D.pan(self: Camera2D, dx: number, dy: number)
	self.x += dx
	self.y += dy
	Camera2D.clamp(self)
end

-- Zooms by `factor` keeping the map point under (sx, sy) pinned.
function Camera2D.zoomAt(self: Camera2D, factor: number, sx: number, sy: number)
	local oldZoom = self.zoom
	local newZoom = math.clamp(oldZoom * factor, Config.MIN_ZOOM, Config.MAX_ZOOM)
	if newZoom == oldZoom then
		return
	end
	local mapX = (sx - self.x) / oldZoom
	local mapY = (sy - self.y) / oldZoom
	self.zoom = newZoom
	self.x = sx - mapX * newZoom
	self.y = sy - mapY * newZoom
	Camera2D.clamp(self)
end

-- Returns a tile index, or nil when the point is off the map.
--
-- READS WHAT `apply` ACTUALLY DREW rather than self.x / self.zoom. The
-- container is placed at a FLOORED offset and sized UP TO AN EVEN number of
-- pixels, and the image tiles inside are laid out in Scale -- so the map on
-- screen is stretched across that rounded rect, not across exactly W * zoom
-- starting at exactly self.x. At fit zoom a tile is barely one pixel wide, so
-- a two-pixel disagreement is two tiles: the cursor sits on one tile and the
-- click lands on another. The fallbacks cover a call before the first apply.
function Camera2D.screenToTile(self: Camera2D, sx: number, sy: number): number?
	local ox = self.drawX or self.x
	local oy = self.drawY or self.y
	local dw = self.drawW or (W * self.zoom)
	local dh = self.drawH or (H * self.zoom)
	if dw <= 0 or dh <= 0 then
		return nil
	end
	local mapX = math.floor((sx - ox) / dw * W)
	local mapY = math.floor((sy - oy) / dh * H)
	if mapX < 0 or mapX >= W or mapY < 0 or mapY >= H then
		return nil
	end
	return mapY * W + mapX
end

-- THE SAME ARITHMETIC UNFLOORED: where on the map a screen point falls, in
-- tile units, so a marker drawn at (x + 0.5) can be measured against a press
-- rather than snapped to the tile under it first (Structures.gunboatNear).
-- Both nil off the map.
function Camera2D.screenToMap(self: Camera2D, sx: number, sy: number): (number?, number?)
	local ox = self.drawX or self.x
	local oy = self.drawY or self.y
	local dw = self.drawW or (W * self.zoom)
	local dh = self.drawH or (H * self.zoom)
	if dw <= 0 or dh <= 0 then
		return nil, nil
	end
	local mapX = (sx - ox) / dw * W
	local mapY = (sy - oy) / dh * H
	if mapX < 0 or mapX >= W or mapY < 0 or mapY >= H then
		return nil, nil
	end
	return mapX, mapY
end

-- Size is rounded UP TO AN EVEN number of pixels. The map is drawn as a grid
-- of image tiles laid out with Scale; an odd container size makes a tile's
-- edge land on a half pixel and shows as a seam between tiles.
function Camera2D.apply(self: Camera2D, container: GuiObject)
	local w = math.ceil(W * self.zoom)
	local h = math.ceil(H * self.zoom)
	w += w % 2
	h += h % 2
	local x = math.floor(self.x + self.shakeX)
	local y = math.floor(self.y + self.shakeY)
	container.Size = UDim2.fromOffset(w, h)
	container.Position = UDim2.fromOffset(x, y)
	-- ONE WRITER for "where the map actually is". `screenToTile` reads these
	-- four numbers instead of re-deriving them from self.x / self.zoom, so the
	-- rounding above cannot be applied here and forgotten there.
	self.drawX = x
	self.drawY = y
	self.drawW = w
	self.drawH = h
end

return Camera2D
