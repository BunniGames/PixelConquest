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

function Camera2D.centerOnTile(self: Camera2D, tile: number)
	local tx = tile % W
	local ty = (tile - tile % W) / W
	self.x = self.viewW / 2 - tx * self.zoom
	self.y = self.viewH / 2 - ty * self.zoom
	Camera2D.clamp(self)
end

-- Shows the WHOLE map (min, not max): during the spawn phase you are choosing
-- where on the country to start, so nothing may be cropped off-screen.
function Camera2D.fit(self: Camera2D)
	self.zoom = math.clamp(
		math.min(self.viewW / W, self.viewH / H),
		Config.MIN_ZOOM,
		Config.MAX_ZOOM
	)
	self.x = (self.viewW - W * self.zoom) / 2
	self.y = (self.viewH - H * self.zoom) / 2
end

-- Keeps at least a third of the viewport covered by map in each axis.
function Camera2D.clamp(self: Camera2D)
	local mapW = W * self.zoom
	local mapH = H * self.zoom

	if mapW <= self.viewW then
		self.x = (self.viewW - mapW) / 2
	else
		self.x = math.clamp(self.x, self.viewW - mapW, 0)
	end

	if mapH <= self.viewH then
		self.y = (self.viewH - mapH) / 2
	else
		self.y = math.clamp(self.y, self.viewH - mapH, 0)
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
