--!strict
-- Conquest :: Net
-- Remote plumbing plus the tile-delta wire format.
--
-- The server owns the simulation (unlike the browser original, which trusts
-- clients and reconciles by hash -- on Roblox the server is already
-- authoritative, so that whole layer is unnecessary). Per tick the server
-- ships only the tiles whose owner changed. The format is NOT the
-- fixed-width u32 this comment used to describe -- that was the first version
-- and the comment outlived it. See Net.packDelta below: changes are grouped by
-- new owner, and each group's tile indices are sorted and delta-coded as
-- 7-bit varints. NOTHING ON THE WIRE DEPENDS on the map's width, height or
-- tile count, so none of it has to change if a map ever has different
-- dimensions.

local Config = require(script.Parent.Config)

local Net = {}

-- Largest number of tile changes in one frame. Chunking keeps any single
-- frame small and predictable.
Net.MAX_DELTA_PAIRS = 3000

-- `changes` holds interleaved (tileIndex, ownerId) pairs. `count` is how many
-- pairs to encode and `startPair` how many to skip, so a large batch can be
-- sliced without copying the source array.
--
-- Grouped by new owner, and each group's tile indices sorted and DELTA-coded
-- as 7-bit varints. Measured over 120 ticks of a 72-empire match:
--
--     raw u32 per tile        4.00 bytes/tile   45.2 KB/s
--     grouped by owner, 3B    3.09              34.9
--     grouped + runs          3.62              40.9
--     grouped + delta-varint  1.81              20.4
--
-- Runs being WORSE than deltas is the non-obvious part: a tick's conquests
-- are scattered ALONG a front rather than contiguous, so runs come out
-- nearly all length one and the run header costs more than it saves. The
-- gaps between them are small, which is what the varint exploits.
function Net.packDelta(changes: { number }, count: number, startPair: number?): buffer
	local start = startPair or 0
	local byOwner, owners = {}, {}
	for k = 0, count - 1 do
		local base = (start + k) * 2
		local o = changes[base + 2]
		local g = byOwner[o]
		if not g then
			g = {}
			byOwner[o] = g
			table.insert(owners, o)
		end
		table.insert(g, changes[base + 1])
	end

	-- A delta is at most the map size, so three varint bytes; four per tile
	-- plus the group headers cannot be exceeded.
	local scratch = buffer.create(count * 4 + #owners * 4 + 8)
	local w = 0
	buffer.writeu16(scratch, w, #owners)
	w += 2
	for _, o in owners do
		local g = byOwner[o]
		table.sort(g)
		buffer.writeu8(scratch, w, o)
		w += 1
		buffer.writeu16(scratch, w, #g)
		w += 2
		local prev = 0
		for i = 1, #g do
			local d = g[i] - prev
			prev = g[i]
			while d >= 128 do
				buffer.writeu8(scratch, w, bit32.bor(bit32.band(d, 127), 128))
				w += 1
				d = bit32.rshift(d, 7)
			end
			buffer.writeu8(scratch, w, d)
			w += 1
		end
	end
	local out = buffer.create(w)
	buffer.copy(out, 0, scratch, 0, w)
	return out
end

-- Calls `fn(tileIndex, ownerId)` for each entry.
function Net.unpackDelta(buf: buffer, fn: (number, number) -> ())
	local n = buffer.len(buf)
	if n < 2 then
		return
	end
	local r = 0
	local groups = buffer.readu16(buf, r)
	r += 2
	for _ = 1, groups do
		local owner = buffer.readu8(buf, r)
		r += 1
		local cnt = buffer.readu16(buf, r)
		r += 2
		local prev = 0
		for _ = 1, cnt do
			local d, shift = 0, 0
			while true do
				local by = buffer.readu8(buf, r)
				r += 1
				d = bit32.bor(d, bit32.lshift(bit32.band(by, 127), shift))
				if by < 128 then
					break
				end
				shift += 7
			end
			prev += d
			fn(prev, owner)
		end
	end
end

-- --------------------------------------------------------- full state -----
-- The whole ownership map, as run-length pairs of (owner, count).
--
-- The raw buffer is one byte per tile -- 1.6 MB at this map size -- and it
-- went to every client at every round start AND every join. At the start of
-- a round the map is almost entirely unclaimed, so it collapses to a couple
-- of kilobytes; mid-round it is large same-owner regions, so it still
-- collapses by well over an order of magnitude.
--
-- Returns nil if the encoding would not fit in the raw size, so the caller
-- can fall back and never do worse than sending the bytes.
function Net.packOwners(owner: buffer): buffer?
	local n = buffer.len(owner)
	local cap = n
	local scratch = buffer.create(cap)
	local w, i = 0, 0
	while i < n do
		local o = buffer.readu8(owner, i)
		local j = i + 1
		while j < n and buffer.readu8(owner, j) == o do
			j += 1
		end
		-- owner byte plus a 7-bit varint run length (3 bytes covers 2M tiles)
		if w + 5 > cap then
			return nil
		end
		buffer.writeu8(scratch, w, o)
		w += 1
		local run = j - i
		while run >= 128 do
			buffer.writeu8(scratch, w, bit32.bor(bit32.band(run, 127), 128))
			w += 1
			run = bit32.rshift(run, 7)
		end
		buffer.writeu8(scratch, w, run)
		w += 1
		i = j
	end
	local out = buffer.create(w)
	buffer.copy(out, 0, scratch, 0, w)
	return out
end

function Net.unpackOwners(buf: buffer, owner: buffer)
	local n = buffer.len(buf)
	local total = buffer.len(owner)
	local r, pos = 0, 0
	while r < n and pos < total do
		local o = buffer.readu8(buf, r)
		r += 1
		local run, shift = 0, 0
		while true do
			local b = buffer.readu8(buf, r)
			r += 1
			run = bit32.bor(run, bit32.lshift(bit32.band(b, 127), shift))
			if b < 128 then
				break
			end
			shift += 7
		end
		if run > total - pos then
			run = total - pos
		end
		buffer.fill(owner, pos, o, run)
		pos += run
	end
end

-- ---------------------------------------------------------- summaries -----
-- The twice-a-second summaries used to go as arrays of tables. Roblox sends
-- a table's KEYS as strings on every send, so "landPercent" cost more than
-- the number beside it, and the whole roster -- names included -- was
-- retransmitted five times a second for figures that are three integers.
-- Names and team never change inside a round, so they ride along with the
-- roster instead; only what moves is packed here.

-- 10 bytes per player: id, tiles, troops, flags(alive | isBot | team).
function Net.packPlayers(list: { any }): buffer
	local buf = buffer.create(#list * 10)
	for k, e in ipairs(list) do
		local o = (k - 1) * 10
		buffer.writeu8(buf, o, e.id)
		buffer.writeu32(buf, o + 1, e.tiles)
		buffer.writeu32(buf, o + 5, e.troops)
		local flags = (e.alive and 1 or 0) + (e.isBot and 2 or 0)
			+ bit32.lshift(e.team or 0, 2)
		buffer.writeu8(buf, o + 9, flags)
	end
	return buf
end

function Net.unpackPlayers(buf: buffer): { any }
	local out = {}
	for k = 0, buffer.len(buf) // 10 - 1 do
		local o = k * 10
		local flags = buffer.readu8(buf, o + 9)
		local team = bit32.rshift(flags, 2)
		table.insert(out, {
			id = buffer.readu8(buf, o),
			tiles = buffer.readu32(buf, o + 1),
			troops = buffer.readu32(buf, o + 5),
			alive = bit32.band(flags, 1) == 1,
			isBot = bit32.band(flags, 2) == 2,
			team = team > 0 and team or nil,
		})
	end
	return out
end

-- 17 bytes per army in the field. The extra byte is `c`, the cluster
-- index: one attack fighting on two disconnected fronts carries a number
-- on each, and the pair has to stay distinguishable on the wire or the
-- client cannot tell which label belongs to which front.
function Net.packArmies(list: { any }): buffer
	local buf = buffer.create(#list * 17)
	for k, a in ipairs(list) do
		local o = (k - 1) * 17
		buffer.writeu32(buf, o, a.a)
		buffer.writeu8(buf, o + 4, a.id)
		buffer.writeu8(buf, o + 5, a.t)
		buffer.writeu32(buf, o + 6, a.troops)
		buffer.writeu16(buf, o + 10, math.clamp(math.floor(a.x), 0, 65535))
		buffer.writeu16(buf, o + 12, math.clamp(math.floor(a.y), 0, 65535))
		buffer.writeu16(buf, o + 14, math.clamp(a.n, 0, 65535))
		buffer.writeu8(buf, o + 16, math.clamp(a.c, 0, 255))
	end
	return buf
end

function Net.unpackArmies(buf: buffer): { any }
	local out = {}
	for k = 0, buffer.len(buf) // 17 - 1 do
		local o = k * 17
		table.insert(out, {
			a = buffer.readu32(buf, o),
			id = buffer.readu8(buf, o + 4),
			t = buffer.readu8(buf, o + 5),
			troops = buffer.readu32(buf, o + 6),
			x = buffer.readu16(buf, o + 10),
			y = buffer.readu16(buf, o + 12),
			n = buffer.readu16(buf, o + 14),
			c = buffer.readu8(buf, o + 16),
		})
	end
	return out
end

-- ------------------------------------------------------------- remotes -----

local FOLDER_NAME = "ConquestNet"

-- Server-side creation. Idempotent so a re-run never duplicates remotes.
function Net.build(parent: Instance): Folder
	local folder = parent:FindFirstChild(FOLDER_NAME) :: Folder?
	if not folder then
		folder = Instance.new("Folder")
		;(folder :: Folder).Name = FOLDER_NAME
		;(folder :: Folder).Parent = parent
	end
	for _, name in { "State", "Delta", "Intent" } do
		if not (folder :: Folder):FindFirstChild(name) then
			local re = Instance.new("RemoteEvent")
			re.Name = name
			re.Parent = folder
		end
	end
	return folder :: Folder
end

function Net.await(parent: Instance): Folder
	return parent:WaitForChild(FOLDER_NAME) :: Folder
end

return Net