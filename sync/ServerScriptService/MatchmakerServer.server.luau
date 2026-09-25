--!strict
-- Conquest :: MatchmakerServer  (lobby servers only)
--
-- Runs the cross-server lobby board. Every public server of this place polls
-- the same three MemoryStore records, shows them to its own players, and --
-- when one of them is ready to launch -- races every other server for the
-- right to reserve the match server.
--
-- THERE IS NO BACKEND ON ROBLOX, so the board is a distributed data structure
-- whose only consensus primitive is `UpdateAsync`, an atomic read-modify-write
-- on one key. Every hard thing in this file is a race, and each is handled
-- INSIDE a transform rather than around it:
--
--   * TWO SERVERS BOTH DECIDE TO LAUNCH. Only one can flip `open -> claim`,
--     because the flip happens inside the transform and the loser sees
--     `state ~= "open"` on its own attempt.
--   * THE WINNER DIES MID-RESERVATION. A claim older than CLAIM_STALE may be
--     stolen, so a crashed host costs 15 seconds rather than wedging the slot
--     until its TTL expires.
--   * A PLAYER JOINS AS THE LOBBY CLOSES. The join is refused in the same
--     transform that would have added them, and they are told why.
--   * A SERVER DIES HOLDING MEMBERS. Every server refreshes a heartbeat on its
--     own entry; entries that stop are pruned by whoever writes next.
--
-- AND ONE THING THAT IS NOT A RACE BUT LOOKS LIKE ONE: a server can only
-- teleport ITS OWN players, so the reservation is published back to the record
-- and all three servers independently teleport their own people with the same
-- access code. Nobody teleports anybody else's.

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Conquest")
local Matchmaker = require(Shared.Matchmaker)
local PrivateLobby = require(Shared.PrivateLobby)
-- WHAT THE LAST HOUR JOINED. Read in exactly one place -- the mint of a flex
-- slot -- and written in exactly one -- a join that landed. See Demand.
local Demand = require(Shared.Demand)
local Net = require(Shared.Net)
-- THE TUTORIAL. Only its round SHAPE is read here -- the map, the mode and how
-- many empires wear a name -- so that the two ways in (a player's first ever
-- join, and /tutorial) cannot disagree about what a tutorial is.
local Tutorial = require(Shared.Tutorial)
-- For ONE string: which skin the free-rewards claim grants. Read off the
-- catalogue rather than spelled out here, so this file and the sheet and the
-- shop cannot disagree about it.
local Patterns = require(Shared.Patterns)
-- The pass catalogue, for ONE thing: which passes exist, so the shop's
-- GAMEPASSES tab can be told which of them this account holds (sendPasses).
local Products = require(Shared.Products)
-- The profile store, for ONE thing: printing the account's Money balance on
-- the page. Nothing here earns or spends it -- a lobby server runs no
-- simulation -- and `install` is ConquestServer's call, not this file's.
local Data = require(script.Parent:WaitForChild("ConquestData"))
local Monetization = require(script.Parent:WaitForChild("ConquestMonetization"))

-- THE FUNNELS. This file owns the front half of every one of them: it is where
-- a player lands, where they press something, and where they are put on a
-- teleport -- and a teleport is where a visit gets cut in two unless the
-- payload below carries it across. Analytics is installed by ConquestServer,
-- which runs on this server too; these are calls into an already-live module.
local Analytics = require(script.Parent:WaitForChild("ConquestAnalytics"))

type Record = Matchmaker.Record

-- Built here as well as in ConquestServer: whichever script runs first creates
-- the folder, and `Net.build` is idempotent. Without this a lobby server would
-- have no remotes at all, because ConquestServer is the only other builder and
-- it is inert here.
local netFolder = Net.build(ReplicatedStorage)
local LobbyRE = netFolder:WaitForChild("Lobby") :: RemoteEvent
local LobbyIntentRE = netFolder:WaitForChild("LobbyIntent") :: RemoteEvent

-- NOBODY HAS A BODY. Conquest is a chart on a desk: the 3D world behind the
-- full-screen GUI is an empty baseplate no player ever sees. A character there
-- is not neutral -- WASD pans the map, and the same keys were also walking an
-- avatar around underneath it (and would put a thumbstick on top of the map on
-- a phone). No body, nothing for those keys to drive.
--
-- Above the match-server return on purpose: this is true of BOTH server kinds.
-- The loop is for Studio, where the local player can already be in by the time
-- this line runs; a live server has nobody yet.
Players.CharacterAutoLoads = false
for _, plr in Players:GetPlayers() do
	local body = plr.Character
	if body then
		body:Destroy()
	end
end

local IS_MATCH = Matchmaker.isMatchServer()
ReplicatedStorage:SetAttribute(Matchmaker.ROLE_ATTR, IS_MATCH and "match" or "lobby")

-- A match server has nothing to do here. It does not poll, it does not write,
-- and it costs the MemoryStore quota nothing.
if IS_MATCH then
	return
end

-- ------------------------------------------------------------- identity ----

-- `game.JobId` is EMPTY IN STUDIO, and two Studio sessions sharing one id
-- would each think the other's members were their own -- which is exactly the
-- case the two-instance test exists to exercise. A random stand-in makes them
-- distinct servers as far as the board is concerned.
local SERVER_ID = game.JobId
if SERVER_ID == "" then
	SERVER_ID = "studio-" .. HttpService:GenerateGUID(false)
end

-- ------------------------------------------------------ the board's home ---
--
-- THE PUBLIC BOARD LIVES IN THIS SERVER'S MEMORY (2026-09-20, at 2k CCU:
-- "matchmaking is starting to get really slow"). Until today it was a
-- MemoryStore sorted map that every lobby server polled once a second and
-- wrote into every five, and the Memory Stores dashboard showed what that
-- costs: sorted-map UpdateAsync was ~80% of every memory-store call the game
-- made, and FOUR OF EVERY FIVE were DataUpdateConflict retries -- servers
-- colliding on the same slot keys. That was the slow JOIN press (one press =
-- one UpdateAsync, retried until it lands) and the slow tick.
--
-- A board that only THIS server's players can join has exactly one writer,
-- so it needs no store at all. LocalBoard answers the same two calls the code
-- below has always made -- GetRangeAsync and UpdateAsync -- from a table, the
-- transform run synchronously, every record copied through JSON on the way
-- in and out so a local mutation can never leak into the "stored" copy (it
-- never could with the real store, and ensureSlot / the rollover rely on
-- that). NOT ONE LINE of the matchmaking logic changed; the transforms, the
-- generation guards and the claim race all still run, they just never lose.
-- A server that dies takes its board with it -- and its players, who were
-- the only ones who could see it; matches already launched are on their own
-- reserved servers. The price: a card fills from this server's players only,
-- which is what Players.MaxPlayers now dials.
--
-- STUDIO KEEPS THE REAL STORE, because two Studio instances sharing one board
-- is how the cross-server paths get exercised -- unless ReplicatedStorage
-- carries the ConquestLocalBoard attribute, which is how a playtest drives
-- THIS path. What still needs the store and still uses it: match records,
-- where entries, private rooms, public listings, the demand tally.
local LocalBoard = {}
LocalBoard.__index = LocalBoard

local function copyValue(v: any): any
	if type(v) ~= "table" then
		return v
	end
	return HttpService:JSONDecode(HttpService:JSONEncode(v))
end

function LocalBoard.new()
	return setmetatable({ items = {}, expires = {} }, LocalBoard)
end

function LocalBoard:_live(key: string): any
	local exp = self.expires[key]
	if exp ~= nil and os.time() >= exp then
		self.items[key] = nil
		self.expires[key] = nil
	end
	return self.items[key]
end

function LocalBoard:GetAsync(key: string): any
	return copyValue(self:_live(key))
end

function LocalBoard:SetAsync(key: string, value: any, ttl: number?): boolean
	self.items[key] = copyValue(value)
	self.expires[key] = os.time() + (ttl or Matchmaker.RECORD_TTL)
	return true
end

function LocalBoard:RemoveAsync(key: string)
	self.items[key] = nil
	self.expires[key] = nil
end

-- Same contract as the real one: the transform sees a copy of the stored
-- value (nil if none), returns the value to store or nil to leave it alone.
function LocalBoard:UpdateAsync(key: string, transform: (any) -> any, ttl: number?): any
	local nextValue = transform(copyValue(self:_live(key)))
	if nextValue == nil then
		return nil
	end
	self:SetAsync(key, nextValue, ttl)
	return copyValue(nextValue)
end

function LocalBoard:GetRangeAsync(direction: Enum.SortDirection, count: number, _lower: any?, _upper: any?): { any }
	local keys = {}
	for key in self.items do
		if self:_live(key) ~= nil then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	if direction == Enum.SortDirection.Descending then
		local rev = {}
		for i = #keys, 1, -1 do
			table.insert(rev, keys[i])
		end
		keys = rev
	end
	local out = {}
	for i = 1, math.min(count, #keys) do
		table.insert(out, { key = keys[i], value = copyValue(self.items[keys[i]]) })
	end
	return out
end

local USE_LOCAL_BOARD = not RunService:IsStudio() or ReplicatedStorage:GetAttribute("ConquestLocalBoard") == true
local lobbyStore: any = if USE_LOCAL_BOARD then LocalBoard.new() else MemoryStoreService:GetSortedMap(Matchmaker.STORE)
local matchStore = MemoryStoreService:GetHashMap(Matchmaker.MATCH_STORE)
local demandStore = MemoryStoreService:GetSortedMap(Demand.STORE)
local boardStore = MemoryStoreService:GetHashMap(Matchmaker.BOARD_STORE)

-- userId -> slot key. The authoritative copy lives in MemoryStore; this is the
-- local index that says who to teleport and whose heartbeat to refresh.
local mine: { [number]: string } = {}
local busy: { [number]: boolean } = {}
-- userId -> "pending" | "sent": a follower's join being finished. See
-- followFriend, and the tutorial gate that waits on this before deciding.
local following: { [number]: string } = {}
-- THE CURTAIN'S STATE, on the Player as an attribute so a client that connects
-- late still reads it (FollowCurtainClient): "looking" while the friend is
-- being found, "sent" once the teleport went out, "tutorial" when there was no
-- room and the lesson is opening instead, "stay" when the page is theirs.
local FOLLOW_ATTR = "ConquestFollow"
local function followState(player: Player, state: string)
	if player.Parent ~= nil then
		player:SetAttribute(FOLLOW_ATTR, state)
	end
end
local whereStore = MemoryStoreService:GetHashMap(Matchmaker.WHERE_STORE)
local cooldown: { [number]: number } = {}
local INTENT_COOLDOWN = 1
-- ...and a MUCH shorter one for the shop, which shares this remote and shares
-- none of the reasons the gate above is a whole second. Every board intent is
-- a MemoryStore write against a universe-wide budget; buying or equipping a
-- pattern is a table write on a profile this server already has open. Putting
-- the shop behind the board's cooldown would mean a player flicking through
-- swatches silently eats the allowance their next JOIN press needs.
local cosmeticAt: { [number]: number } = {}
local COSMETIC_COOLDOWN = 0.2
-- WHAT THE FREE REWARDS SHEET PAYS, beside the Ribbon skin (2026-09-17,
-- owner). Against the measured 1,868-5,129 Money an hour of play
-- (MONEYBALANCE.txt section 7) this is roughly twenty minutes of play -- more
-- than the COMMON tier costs and well under UNCOMMON, so it opens the bottom
-- of the shop without skipping anybody past it.
local REWARD_MONEY = 1000
-- THERE IS NO STEP GATE ANY MORE (2026-09-17, owner: "nevermind then, just
-- have like the game for now. and invite a friend"). A group-membership gate
-- was here for an hour and went with the JOIN THE GROUP step it belonged to;
-- neither of the two steps left can be checked by anything (see LobbyUI's
-- RW_TASKS for what the platform does and does not expose).
--
-- WHAT THE SERVER STILL OWNS IS THE ONLY THING THAT HAS TO BE TRUE: the grant
-- lands once per account, and it lands here rather than on a client's word.
-- If a real check is ever wanted back, this is where it goes -- one `if`
-- above the claim, and `ready` on the push below.

-- userId -> clan tag, for the people in THIS server. Purely local and never
-- written to the board: the tag only has to survive as far as the teleport that
-- carries this server's own batch into the match (see `tagsFor`), and every
-- lobby server sends its own people. Putting it in the record instead would
-- change the shape of a MemoryStore document that three servers write
-- concurrently, for a string that no other server ever reads.
local tagOf: { [number]: string } = {}

-- The tags of the players about to be teleported, keyed by userId AS A STRING.
-- Teleport data is JSON, so a numeric key arrives on the far side as a string
-- whatever it went in as -- keying it that way here is what makes the match
-- server's lookup an exact one instead of a guess.
local function tagsFor(list: { Player }): { [string]: string }
	local out: { [string]: string } = {}
	for _, p in list do
		local t = tagOf[p.UserId]
		if t and t ~= "" then
			out[tostring(p.UserId)] = t
		end
	end
	return out
end

-- One warning a minute, not one a second, when API access is off. Without the
-- throttle a Studio session with the setting unticked prints a wall of
-- identical errors and buries everything else; without the expiry a genuine
-- transient failure hours later would be silent.
local complained = -1e9
local function report(what: string, err: any)
	if os.clock() - complained > 60 then
		complained = os.clock()
		warn(
			"[Matchmaker] "
				.. what
				.. " failed: "
				.. tostring(err)
				.. "  -- if this is Studio, tick Game Settings > Security > Enable Studio Access to API Services."
		)
	end
end

local function toast(player: Player, text: string)
	LobbyRE:FireClient(player, "toast", text)
end
-- THE FLAG TAB'S HALF OF THE SAME PUSH. Sent by `sendPatterns` rather than by
-- its own set of call sites: every place that already tells the shop what
-- changed now tells it about both tabs, which is one fewer thing to forget the
-- day a third tab exists.
local function sendFlags(player: Player)
	local owned, equipped, tokens = Data.flagState(player)
	if owned == nil then
		-- A failed load. Sending nothing leaves the tab shut, which is the
		-- honest answer: there is nowhere to bank a purchase.
		return
	end
	LobbyRE:FireClient(player, "flags", {
		owned = owned,
		equipped = equipped,
		tokens = tokens,
	})
end

-- WHETHER THE FREE REWARD IS STILL THERE TO TAKE, and -- when a claim could
-- not go through -- WHY.
--
-- THE `say` IS NOT A NICETY. A refused claim used to answer with `toast`,
-- which writes to a label on the PAGE, and the rewards sheet covers the page
-- at ZIndex 20: every explanation it ever gave was rendered behind the modal
-- that asked for it, so the button simply appeared to do nothing. The sheet
-- has its own message line and this is what feeds it.
local function sendReward(player: Player, say: string?)
	LobbyRE:FireClient(player, "reward", {
		claimed = Data.freeRewardClaimed(player),
		say = say,
	})
end

-- WHAT THE SHOP MAY SHOW, straight off the profile. Sent when that profile
-- lands and again after anything moves, because the server is the only thing
-- that knows what an account owns -- a page that guessed would sooner or later
-- offer to sell somebody a pattern they already had.
local function sendPatterns(player: Player)
	local owned, equipped, money, wins = Data.patternState(player)
	if owned == nil then
		-- A failed load. Sending nothing leaves the shop shut, which is the
		-- honest answer: there is nowhere to bank a purchase.
		return
	end
	LobbyRE:FireClient(player, "patterns", {
		owned = owned,
		equipped = equipped,
		wins = wins,
		-- The one Robux unlock the shop draws a control for. Travels with the
		-- patterns because it is painted by the same page off the same push.
		money2x = Data.hasMoney2x(player),
	})
	LobbyRE:FireClient(player, "money", money)
	-- ...AND WHETHER THE FREE REWARD IS STILL THERE TO TAKE. It travels with
	-- the patterns for the same reason money2x does: one page paints all of
	-- it off one push, and a claim moves the skin, the balance and this latch
	-- in the same instant.
	sendReward(player)
	sendFlags(player)
end

-- WHAT THIS PLAYER'S PASSES OPEN IN A PRIVATE ROOM (2026-09-11): 0, or
-- PrivateLobby.TIER_HOST, or TIER_ADVANCED. ADVANCED is HOST plus the modes,
-- so it is asked first and answers for both. `ownsPass` YIELDS on a cold
-- cache (UserOwnsGamePassAsync); every caller is already on its own thread.
local function hostTier(player: Player): number
	-- VIP IS ALL GAME CREATION (owner, 2026-09-15), so it answers the top of
	-- the ladder before either host pass is asked. Deliberately FIRST: it is
	-- the only one of the three that is commonly true while both others are
	-- false, and asking it last would cost a VIP two UserOwnsGamePassAsync
	-- round trips on a cold cache to arrive at the same answer.
	if Monetization.ownsPass(player, "VIP") then
		return PrivateLobby.TIER_ADVANCED
	elseif Monetization.ownsPass(player, "ADVANCED") then
		return PrivateLobby.TIER_ADVANCED
	elseif Monetization.ownsPass(player, "HOST") then
		return PrivateLobby.TIER_HOST
	end
	return 0
end

-- ...and the page's copy of it, which only decides which arrows are dimmed.
-- The server never reads it back: createRoom and setRoom ask hostTier again.
local function sendPasses(player: Player)
	local tier = hostTier(player)
	-- ...AND WHICH PASSES THIS ACCOUNT HOLDS, one flag per live pass, for the
	-- shop's GAMEPASSES tab (2026-09-21). The tier collapses three passes into
	-- one number, which is all the room dials need and not enough for a card
	-- per pass to say OWNED. `ownsPass` caches a yes for good and a no for a
	-- minute, so past the tier's own lookups this costs nothing.
	local owned: { [string]: boolean } = {}
	for key, entry in Products.PASSES do
		if Products.isLive(entry) and Monetization.ownsPass(player, key) then
			owned[key] = true
		end
	end
	if player.Parent ~= nil then
		LobbyRE:FireClient(player, "passes", tier, owned)
	end
end

-- ------------------------------------------------------------- broadcast ---

-- THE LAST BOARD THIS SERVER READ, kept so a join can be SHOWN the moment it
-- lands instead of whenever the poll next comes round.
--
-- WHY THAT MATTERED. The only push used to be the poll's, so pressing JOIN
-- bought you one MemoryStore write, then up to POLL seconds of waiting for the
-- next tick, then that tick's own GetRangeAsync -- a card that did not move
-- for one to two seconds, with no press state, no colour change and nothing
-- else on the page to look at. A button that does nothing for that long gets
-- pressed again, and the second press is exactly what the intent cooldown
-- throws away. Writing the transform's own result back into the cache and
-- broadcasting it costs one RemoteEvent and no quota at all.
local boardCache: { [string]: Record } = {}
local lastWire: { any }? = nil
local lastSignature = ""
local lastPush = 0
-- HOW MANY SLOTS THIS SERVER IS MINTING (Matchmaker.slotsFor): written by
-- tick from the demand tally, read by the wire. Starts at the floor, so the
-- first board a cold server pushes is the floor and not the whole table.
local liveSlots = Matchmaker.MIN_SLOTS

local function signature(wire: { any }): string
	-- Deliberately EXCLUDES the countdown: the client ticks that down itself
	-- between updates, so including it would make every second a change and
	-- there would be no idle state at all.
	-- The RUNG is in here (e[8]) because it is a thing the card SAYS: a flex
	-- slot that rolls from twelve seats to twenty-four renames itself BATTLE ->
	-- WORLD WAR. It is almost always redundant, since a re-mint changes the map
	-- or the cap as well -- except on a map whose own ceiling binds both sizes
	-- to the same number (Korea holds two whatever the rung), which is exactly
	-- the case that would otherwise sit under the wrong name until the next
	-- idle push.
	local parts = {}
	for _, e in wire do
		-- A bare 0 is a slot past the live count with nothing in it (see
		-- Matchmaker.wire). It is part of the shape, so it is part of the key.
		if type(e) ~= "table" then
			table.insert(parts, "-")
		else
			table.insert(
				parts,
				string.format("%d.%d.%d.%d.%d.%d.%d", e[1], e[2], e[3], e[5], #e[6], e[7] or 0, e[8] or 0)
			)
		end
	end
	return table.concat(parts, "/")
end

-- Idle servers send one packet every PUSH seconds rather than one a second,
-- because nothing on a card moves except a clock the client runs on its own.
-- `force` is the press path: somebody is waiting on this exact packet.
local function pushBoard(force: boolean)
	local wire = Matchmaker.wire(boardCache, os.time(), liveSlots)
	lastWire = wire
	local sig = signature(wire)
	if force or sig ~= lastSignature or (os.clock() - lastPush) >= Matchmaker.PUSH then
		lastSignature = sig
		lastPush = os.clock()
		LobbyRE:FireAllClients("board", wire)
	end
end

-- ---------------------------------------------------------------- store ----

local function readBoard(): { [string]: Record }?
	local out: { [string]: Record } = {}
	local ok, items = pcall(function()
		-- The slot keys are the ONLY keys in this sorted map (match configs
		-- live in a separate hash map on purpose -- mixed in here they would
		-- sort ahead of "slotN" and a bounded range read could return nothing
		-- but match configs).
		return lobbyStore:GetRangeAsync(Enum.SortDirection.Ascending, #Matchmaker.SLOTS + 4)
	end)
	if not ok then
		report("GetRangeAsync", items)
		-- NIL, NOT AN EMPTY BOARD (2026-09-20). Returning `{}` here made a
		-- refused read look like a board with no lobbies on it: the tick
		-- pushed a page of blank cards to every client and then tried to
		-- MINT every slot against a store that had just refused a read. The
		-- in-memory board never refuses; Studio's real one can. The tick
		-- skips itself on nil.
		return nil
	end
	for _, item in items :: any do
		local key = item.key
		local value = item.value
		if type(key) == "string" and type(value) == "table" then
			out[key] = value
		end
	end
	return out
end

-- What the OTHER cards are currently offering, so a fresh draw can avoid all
-- of it -- map, mode and pair. See Matchmaker.drawPair.
local function shownElsewhere(board: { [string]: Record }, exceptKey: string?): { { map: string, mode: string } }
	local out = {}
	for key, rec in board do
		if key ~= exceptKey and rec.map and rec.mode and rec.state ~= "retired" then
			table.insert(out, { map = rec.map, mode = rec.mode })
		end
	end
	return out
end

-- Writes a record back under the guard that our generation is still the one in
-- the store. Every write in this file goes through here, because the whole
-- family of bugs it prevents is the same one: a slot that reset while we were
-- yielding, and a stale write that un-resets it.
local function commit(key: string, generation: string, mutate: (Record) -> boolean): boolean
	local applied = false
	local ok, err = pcall(function()
		lobbyStore:UpdateAsync(key, function(rec: any)
			applied = false
			if type(rec) ~= "table" then
				return nil
			end
			if generation ~= "" and rec.id ~= generation then
				return nil
			end
			if not mutate(rec) then
				return nil
			end
			applied = true
			return rec
		end, Matchmaker.RECORD_TTL)
	end)
	if not ok then
		report("UpdateAsync(" .. key .. ")", err)
		return false
	end
	return applied
end

-- --------------------------------------------------------------- demand ----
--
-- The EXTRA slots -- two on 2026-09-17, four since 2026-09-19, and up to nine
-- while the hour's traffic asks for them (sizeBoard) -- are whatever the past
-- hour actually joined.
-- Everything expensive about that is avoided by shape rather than by tuning:
--
--   THE WRITE is one UpdateAsync on a join that landed -- a join is already a
--   MemoryStore write behind a one-per-second-per-player gate, so this at most
--   doubles the rarest traffic on the page, and it is spawned so the player's
--   own press never waits on it.
--
--   THE READ is one GetRangeAsync over six keys, taken at most once a minute
--   per server and ONLY when a flex slot is being minted. A board whose extras
--   are both mid-countdown reads nothing at all.
--
-- AN UNREACHABLE STORE COSTS THE BOARD NOTHING. Every path here falls through
-- to `nil`, and a nil want is exactly the card the slot had before any of this
-- existed: its own cap, and a freshly drawn pairing.
local DEMAND_POLL = 60
local demandAt = 0
local demandTally = Demand.blank()

-- BATCHED, ONE WRITE PER SERVER PER HALF MINUTE (2026-09-20). "One UpdateAsync
-- per join" above was true and was still the last universe-wide hot key: every
-- join on every server wrote the SAME ten-minute bucket, and the Memory Stores
-- dashboard showed that key retrying on conflicts like the old board's did.
-- Joins are folded into a local tally and flushed by the poll loop. A server
-- that dies loses at most thirty seconds of a heuristic.
local DEMAND_FLUSH = 30
local demandPending: { [string]: { size: number, pair: string, n: number } } = {}
local demandFlushAt = 0

local function noteJoin(rec: Record)
	-- THE RUNG, NOT THE CAP. A SKIRMISH that drew Korea advertises two seats,
	-- and counting that join as "somebody wanted a 2" would invent a size the
	-- ladder does not have and hand it a fill rate nothing can beat.
	local size = rec.size or rec.cap
	local pair = Matchmaker.pairKey(rec.map, rec.mode)
	local k = tostring(size) .. "|" .. pair
	local p = demandPending[k]
	if p then
		p.n += 1
	else
		demandPending[k] = { size = size, pair = pair, n = 1 }
	end
end

local function flushDemand()
	if next(demandPending) == nil or os.clock() - demandFlushAt < DEMAND_FLUSH then
		return
	end
	demandFlushAt = os.clock()
	local batch = demandPending
	demandPending = {}
	task.spawn(function()
		local ok, err = pcall(function()
			demandStore:UpdateAsync(Demand.key(Demand.bucketOf(os.time())), function(old)
				-- The transform may run more than once; `batch` is immutable
				-- and `old` is fresh each time, so replaying it is safe.
				local t = old
				for _, p in batch do
					for _ = 1, p.n do
						t = Demand.add(t, p.size, p.pair)
					end
				end
				return t
			end, Demand.TTL)
		end)
		if not ok then
			report("demand write", err)
		end
	end)
end

local function refreshDemand()
	if os.clock() - demandAt < DEMAND_POLL then
		return
	end
	demandAt = os.clock()
	local ok, items = pcall(function()
		-- The window plus a straggler or two whose TTL has not caught up;
		-- `Demand.merge` drops anything older than the window itself.
		return demandStore:GetRangeAsync(Enum.SortDirection.Ascending, Demand.WINDOW + 2)
	end)
	if ok and type(items) == "table" then
		demandTally = Demand.merge(items, os.time())
	else
		report("demand read", items)
	end
end

-- WHAT THIS SLOT SHOULD BE MINTED AS. Nil for the three fixed rungs, which are
-- the ladder the extras choose FROM and must never move.
local function wantFor(slotIndex: number, board: { [string]: Record }, exceptKey: string?): Matchmaker.Want?
	if not Matchmaker.SLOTS[slotIndex].flex then
		return nil
	end
	refreshDemand()
	-- TWO DIFFERENT SETS OVER THE SAME BOARD, and the difference is the point.
	--
	-- OFFERS counts EVERY record including this slot's outgoing one: the hour
	-- of joins being divided was collected while that card was on the page, so
	-- leaving it out would flatter whatever it has been showing -- the feedback
	-- loop Demand.bestSize exists to close.
	--
	-- SHOWN and TAKEN skip it, because it is the record about to be replaced
	-- and what it shows now constrains nothing. That is also exactly how
	-- `shownElsewhere` builds the list passed to newRecord, and the two have to
	-- agree or the pick would be filtered against one board and minted against
	-- another.
	local offers, shown, taken = {}, {}, {}
	for key, rec in board do
		-- A tombstone offers nothing and shows nothing.
		if rec.state == "retired" then
			continue
		end
		local size = rec.size or rec.cap
		offers[size] = (offers[size] or 0) + 1
		if key ~= exceptKey then
			shown[Matchmaker.pairKey(rec.map, rec.mode)] = true
			-- NO TWO EXTRAS ON ONE MAP (2026-09-17, owner). Every live lobby's
			-- map is excluded, not just the other extra's: a rule that looked
			-- only at the other flex slot would still let an extra double a map
			-- the fixed three are showing, which is the same duplicate on the
			-- same list. The MODE is deliberately left alone -- two extras
			-- sharing a mode is fine, and with three in the rotation forbidding
			-- it would leave almost nothing to draw from.
			taken[rec.map] = true
		end
	end
	return {
		size = Demand.bestSize(demandTally, offers),
		pair = Demand.bestPair(demandTally, shown, taken),
	}
end

-- HOW MANY SLOTS THE BOARD HAS RIGHT NOW (2026-09-19, owner: "if traffic
-- demands it, add even more games", then "each additional hour can only +1
-- the # of lobbies"). Two questions, answered in order once a minute:
--
--   WHAT THE HOUR JUSTIFIES -- Matchmaker.slotsFor over the same tally the
--   extras are steered by. A blank tally (store unreachable) is zero joins,
--   which is the floor.
--
--   HOW FAR THE BOARD MAY MOVE TOWARDS IT -- Matchmaker.paceBoard over ONE
--   record every server shares (boardStore): one step up per hour, any step
--   down at once. Read with a GetAsync; written only when a step is due, and
--   the step is re-decided INSIDE the transform against the stored record,
--   so two servers reaching the hour together take one step, not two.
--
-- An unreachable board store keeps the last size this server knew -- the
-- floor on a cold one -- rather than guessing; the next minute tries again.
local boardSize = Matchmaker.MIN_SLOTS
local boardAt = 0

local function sizeBoard(): number
	refreshDemand()
	if os.clock() - boardAt < DEMAND_POLL then
		return boardSize
	end
	boardAt = os.clock()
	local wanted = Matchmaker.slotsFor(demandTally.joins)
	local okR, stored = pcall(function()
		return boardStore:GetAsync(Matchmaker.BOARD_KEY)
	end)
	if not okR then
		report("board size read", stored)
		return boardSize
	end
	local paced, due = Matchmaker.paceBoard(stored, wanted, os.time())
	if due then
		local okW, err = pcall(function()
			boardStore:UpdateAsync(Matchmaker.BOARD_KEY, function(old)
				local next, changed = Matchmaker.paceBoard(old, wanted, os.time())
				paced = next
				if not changed then
					return nil
				end
				return next
			end, Matchmaker.BOARD_TTL)
		end)
		if not okW then
			report("board size write", err)
			return boardSize
		end
	end
	boardSize = paced.live
	return boardSize
end

local function ensureSlot(index: number, board: { [string]: Record })
	local slot = Matchmaker.SLOTS[index]
	local cur = board[slot.key]
	-- A RETIRED tombstone is minted over, not kept: the hour wants this slot
	-- back.
	if cur and cur.state ~= "retired" then
		return
	end
	local fresh = Matchmaker.newRecord(index, shownElsewhere(board), wantFor(index, board, slot.key))
	local actual = nil
	local ok, err = pcall(function()
		lobbyStore:UpdateAsync(slot.key, function(rec: any)
			-- Somebody else got there first while we were yielding. Theirs is
			-- as good as ours and has the same shape; take it -- and take it
			-- LITERALLY, because assuming our own draw won would leave this
			-- server broadcasting a map the store does not have and guarding
			-- its writes with a generation nobody else knows.
			if type(rec) == "table" and rec.state ~= "retired" then
				actual = rec
				return nil
			end
			actual = fresh
			return fresh
		end, Matchmaker.RECORD_TTL)
	end)
	if ok and actual then
		board[slot.key] = actual
	elseif not ok then
		report("create " .. slot.key, err)
	end
end

-- ------------------------------------------------------- private lobbies ---
--
-- A ROOM YOU MAKE, keyed by its own four digits, configured by whoever made
-- it and started when they say so. Everything below is the same distributed
-- data structure as the public board above -- one record, `UpdateAsync` as the
-- only consensus primitive, every hard case handled INSIDE a transform -- and
-- it is deliberately a separate store and a separate code path rather than a
-- fourth slot, because almost nothing about it is the same: no countdown, no
-- rotation, no claim race between strangers' servers, and a host.
--
-- WHAT IS THE SAME, and had to be: a room spans SERVERS. Four friends who
-- clicked the game from four different places land in four different public
-- servers, and the whole point of a code is that it reaches across them. So
-- each server holds its own entry in the record, heartbeats it, and teleports
-- only its own people once the host's server has published a reservation.

local privStore = MemoryStoreService:GetHashMap(PrivateLobby.STORE)
-- ...and the shop window a PUBLIC room stands in. See PrivateLobby.PUBLIC_STORE
-- for why it is a second store and not a flag on the first: the room store is a
-- hash map, and a hash map cannot be listed.
local publicStore = MemoryStoreService:GetSortedMap(PrivateLobby.PUBLIC_STORE)

-- ONE SERVER ADVERTISES A ROOM AND IT IS THE HOST'S. Every server holding a
-- member polls the record (see tickRooms), so without that rule a room with
-- people in four servers would be written four times a heartbeat for one
-- listing -- and the writes would race to describe the same room.
--
-- The entry is REFRESHED rather than maintained: it carries a TTL of four
-- heartbeats and is rewritten while the room is still open and still public.
-- Nothing has to delete it when the host quits, the server dies or the match
-- starts; it simply stops being refreshed. That is the only cleanup rule that
-- survives a crash, which is the case every other rule here gets wrong.
local function advertise(code: string, rec: any)
	local listed = rec.state == "open" and PrivateLobby.isPublic(rec.s)
	local ok, err = pcall(function()
		if listed then
			publicStore:SetAsync(code, PrivateLobby.listing(rec, os.time()), PrivateLobby.PUBLIC_TTL)
		else
			-- A room that was public a moment ago and is not now (the host
			-- flipped it, or it is launching) goes at once rather than
			-- lingering for its TTL -- the whole cost of being listed while
			-- closed is a player pressing JOIN on a room that refuses them.
			publicStore:RemoveAsync(code)
		end
	end)
	if not ok then
		report("advertise " .. code, err)
	end
end

-- userId -> code. Same shape and the same reason as `mine`: MemoryStore is
-- authoritative and this is the local index that says whose heartbeat to
-- refresh and who to teleport.
local room: { [number]: string } = {}
local roomCache: { [string]: any } = {}

-- The room this server has already sent its people to. A single string for the
-- reason `teleportedGeneration` is one: the only code that can matter is the
-- one being launched right now.
local sentRoom = ""

local function playersInRoom(code: string): { Player }
	local list = {}
	for userId, c in room do
		if c == code then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(list, player)
			end
		end
	end
	return list
end

-- The distinct codes this server is holding anybody in. Usually zero, which is
-- what makes the feature free for every server nobody is using it in.
local function heldCodes(): { string }
	local seen, out = {}, {}
	for userId, code in room do
		if not seen[code] and Players:GetPlayerByUserId(userId) then
			seen[code] = true
			table.insert(out, code)
		end
	end
	return out
end

-- The room goes only to the people in it. A public server can hold members of
-- several unrelated rooms at once and none of them is entitled to the others'
-- roster, so this is per-player rather than FireAllClients.
local function pushRoom(code: string)
	local rec = roomCache[code]
	if not rec then
		return
	end
	local wire = PrivateLobby.wire(rec, os.time())
	for _, player in playersInRoom(code) do
		LobbyRE:FireClient(player, "room", wire)
	end
end

-- `false` is "you are not in a room", and it is what closes the panel. Sent
-- explicitly rather than inferred from silence, because silence is also what
-- an unreachable MemoryStore looks like.
local function pushNoRoom(player: Player)
	LobbyRE:FireClient(player, "room", false)
end

-- Every write to a room goes through here, and every one of them broadcasts
-- the transform's OWN result the instant it lands -- see pushBoard for why
-- waiting for the next poll is not an option on a page with a button on it.
local function commitRoom(code: string, mutate: (any) -> boolean): (boolean, any)
	local applied, updated = false, nil
	local ok, err = pcall(function()
		privStore:UpdateAsync(code, function(rec: any)
			applied = false
			updated = nil
			if type(rec) ~= "table" or type(rec.servers) ~= "table" then
				return nil
			end
			if not mutate(rec) then
				return nil
			end
			applied = true
			updated = rec
			return rec
		end, PrivateLobby.TTL)
	end)
	if not ok then
		report("room " .. code, err)
		return false, nil
	end
	if applied and updated then
		roomCache[code] = updated
		pushRoom(code)
	end
	return applied, updated
end

-- Takes one member out of this server's entry. Shared by the LEAVE button and
-- by PlayerRemoving, which must do exactly the same thing -- a player who quits
-- the game and one who presses leave are the same event to the record.
local function dropMember(code: string, userId: number)
	commitRoom(code, function(rec)
		local entry = PrivateLobby.entryFor(rec, SERVER_ID)
		if not entry then
			return false
		end
		local at = table.find(entry.u, userId)
		if not at then
			return false
		end
		table.remove(entry.u, at)
		entry.t = os.time()
		PrivateLobby.prune(rec, os.time())
		-- THE HOST WALKING OUT must not leave a room nobody can start. See
		-- PrivateLobby.reseat: lowest userId still in it, which every server
		-- derives identically from the same record.
		PrivateLobby.reseat(rec)
		return true
	end)
end

local function leaveRoom(player: Player)
	local userId = player.UserId
	local code = room[userId]
	if not code then
		return
	end
	room[userId] = nil
	pushNoRoom(player)
	dropMember(code, userId)
end

local function createRoom(player: Player, settings: any)
	local userId = player.UserId
	-- CREATING IS FREE; THE DIALS ARE NOT (2026-09-11). Without a pass the room
	-- opens on the defaults whatever the page sent, and HOST without ADVANCED
	-- keeps the mode CLASSIC. See PrivateLobby.allow.
	settings = PrivateLobby.allow(settings, PrivateLobby.defaults(), hostTier(player))
	-- One room at a time. Leaving first also means the room being left has its
	-- correct roster before the new one exists.
	if room[userId] then
		leaveRoom(player)
	end

	local now = os.time()
	-- FOUR DIGITS IS TEN THOUSAND ROOMS, so a draw can collide -- and with the
	-- birthday bound it collides far sooner than "ten thousand rooms" suggests.
	-- The claim happens INSIDE the transform: seeing a record at that code
	-- means somebody else got there first and this draw is spent, which is the
	-- only test that cannot race a concurrent create.
	for _ = 1, PrivateLobby.TRIES do
		local code = PrivateLobby.newCode()
		local fresh = PrivateLobby.newRecord(code, userId, settings)
		table.insert(fresh.servers, { j = SERVER_ID, t = now, u = { userId } })
		-- A PUBLIC ROOM IS BORN COUNTING DOWN (2026-09-17). Only an ADVANCED
		-- host can create one public at all, but when they do the clock has to
		-- exist before the first wire goes out or the panel opens on a blank
		-- chip and fills it a second later.
		fresh.deadline = PrivateLobby.deadlineFor(fresh, now)
		local won = false
		local ok, err = pcall(function()
			privStore:UpdateAsync(code, function(rec: any)
				won = false
				if type(rec) == "table" then
					return nil
				end
				won = true
				return fresh
			end, PrivateLobby.TTL)
		end)
		if not ok then
			report("create room", err)
			toast(player, "The lobby service is unreachable right now.")
			return
		end
		if won then
			room[userId] = code
			roomCache[code] = fresh
			pushRoom(code)
			return
		end
	end
	toast(player, "Could not find a free code -- try again.")
end

local function joinRoom(player: Player, code: string)
	local userId = player.UserId
	if room[userId] and room[userId] ~= code then
		leaveRoom(player)
	end

	local now = os.time()
	local refusal, joined = "", false
	local updated: any = nil
	local ok, err = pcall(function()
		privStore:UpdateAsync(code, function(rec: any)
			refusal, joined, updated = "", false, nil
			if type(rec) ~= "table" or type(rec.servers) ~= "table" then
				refusal = "No lobby with that code."
				return nil
			end
			PrivateLobby.prune(rec, now)
			-- THE CLOSING RACE, same as the public board's: refusing inside
			-- the transform is what makes it impossible to be added to a match
			-- that has already reserved its server and left without you.
			if rec.state ~= "open" then
				refusal = "That lobby has already started."
				return nil
			end
			if PrivateLobby.hasMember(rec, userId) then
				joined = true
				return nil
			end
			if PrivateLobby.members(rec) >= PrivateLobby.capFor(rec.s) then
				refusal = "That lobby is full."
				return nil
			end
			local entry = PrivateLobby.entryFor(rec, SERVER_ID)
			if not entry then
				entry = { j = SERVER_ID, t = now, u = {} }
				table.insert(rec.servers, entry)
			end
			;(entry :: any).t = now
			table.insert((entry :: any).u, userId)
			joined = true
			updated = rec
			return rec
		end, PrivateLobby.TTL)
	end)

	if not ok then
		report("join room " .. code, err)
		toast(player, "The lobby service is unreachable right now.")
		return
	end
	if joined then
		room[userId] = code
		if updated then
			roomCache[code] = updated
			pushRoom(code)
		elseif roomCache[code] then
			pushRoom(code)
		end
	elseif refusal ~= "" then
		toast(player, refusal)
	end
end

-- HOST ONLY, and enforced inside the transform rather than against this
-- server's copy of the record: the host can change while a settings packet is
-- in flight, and the record is the only thing that knows.
local function setRoom(player: Player, settings: any)
	local code = room[player.UserId]
	if not code then
		return
	end
	-- THE PASS IS CHECKED HERE, NOT ON THE PAGE -- but PER ROW, which it did
	-- not used to be (2026-09-17). A blanket "no pass, no changes" refusal
	-- stood in front of this and made the one FREE row unreachable: WHO CAN
	-- JOIN is tier 0 (PrivateLobby.tierFor), the page offered its arrows to
	-- everybody as it should, and every press was dropped here in silence. The
	-- room panel said PRIVATE for the whole life of a passless host's room.
	--
	-- `PrivateLobby.allow` is the per-row rule and it was always the real one:
	-- every row above the tier keeps the RECORD's value, so a pset from a
	-- modified client holding no pass can still change nothing but this row.
	local tier = hostTier(player)
	-- CHEAP REFUSAL FIRST. Without the blanket gate, a client resending its
	-- settings block changes nothing but still costs an UpdateAsync -- which is
	-- a MemoryStore request whether or not the transform writes. Tested against
	-- the cached record, and re-tested inside the transform against the real
	-- one, so a stale cache costs a wasted request and never a wrong write.
	local cached = roomCache[code]
	if cached and type(cached.s) == "table" then
		local want = PrivateLobby.allow(settings, cached.s, tier)
		local same = true
		for i, v in want do
			if cached.s[i] ~= v then
				same = false
			end
		end
		if same then
			return
		end
	end
	commitRoom(code, function(rec)
		if rec.host ~= player.UserId or rec.state ~= "open" then
			return false
		end
		-- Rows above this tier keep the RECORD's value, so it is decided in
		-- here, against the record, never against a cached copy.
		local want = PrivateLobby.allow(settings, rec.s, tier)
		local same = true
		for i, v in want do
			if rec.s[i] ~= v then
				same = false
			end
		end
		-- Cancelling an unchanged write is not an optimisation, it is what
		-- stops a client that resends its whole settings block on every
		-- keystroke from spending the universe's write budget.
		if same then
			return false
		end
		rec.s = want
		-- THE ROW THAT STARTS THE CLOCK. WHO CAN JOIN is the only setting that
		-- changes whether the room starts by itself, and this is where it does
		-- it: public gets a deadline, private loses one, and every other row --
		-- a map step, a troop step -- leaves an existing one exactly where it
		-- is. See PrivateLobby.deadlineFor for why it must not be recomputed.
		rec.deadline = PrivateLobby.deadlineFor(rec, os.time())
		return true
	end)
end

-- STUDIO HAS NO RESERVED SERVERS, so a room started there begins in the
-- session it is already in -- the same trick `startLocally` plays for the
-- public board, and the only way to play a private match without shipping.
local function startRoomLocally(code: string, st: any)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MAP_ATTR, st.map)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MODE_ATTR, st.mode)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TEAMS_ATTR, st.teams)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TROOPS_ATTR, st.troopScale)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_GOLD_ATTR, st.startGold)
	-- A ROOM PROMISED NOBODY. You invited the people in it, so there are no
	-- phantom seats to make good on and the round runs on real players plus
	-- ordinary NPC nations.
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_PHANTOMS_ATTR, 0)
	-- See startLocally: a tutorial pressed earlier in this session must not
	-- turn the host's room into one.
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TUTORIAL_ATTR, false)
	-- ...and the clan tags, for the same reason as there: no teleport, so no
	-- teleport data to carry them.
	ReplicatedStorage:SetAttribute(
		Matchmaker.LOCAL_TAGS_ATTR,
		HttpService:JSONEncode(tagsFor(Players:GetPlayers()))
	)
	ReplicatedStorage:SetAttribute(Matchmaker.ROLE_ATTR, "match")
	-- DELETE THE ROOM. This session stops polling the moment the role flips,
	-- so a record left in "claim" would sit there for its whole TTL and the
	-- next playtest that typed the same code would be told it had started.
	pcall(function()
		privStore:RemoveAsync(code)
	end)
	print(string.format(
		"[Matchmaker] STUDIO: no reserved servers here, so room %s (%s / %s, %d teams, x%.2g troops, %d gold) starts in this session.",
		code, st.map, st.mode, st.teams, st.troopScale, st.startGold
	))
end

local function sendRoomToMatch(rec: any)
	if not rec or rec.access == "" or sentRoom == rec.code then
		return
	end
	local list = playersInRoom(rec.code)
	if #list == 0 then
		return
	end
	sentRoom = rec.code

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = rec.access
	-- Carried for convenience only, exactly as the public path does: the match
	-- server reads its settings from the match record keyed by
	-- PrivateServerId, never from teleport data, which belongs to whichever
	-- client happens to arrive first.
	-- The clan tags are the exception the public path documents: per-player, so
	-- the per-batch channel is the only one that can carry them.
	options:SetTeleportData({ private = true, code = rec.code, tags = tagsFor(list), cq = Analytics.teleportData(list) })

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, list, options)
	end)
	if not ok then
		task.wait(1)
		-- Re-take the list: TeleportAsync throws on a player who has since
		-- left, which would fail the retry for the whole batch.
		list = playersInRoom(rec.code)
		if #list == 0 then
			sentRoom = ""
			return
		end
		ok = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, list, options)
		end)
	end

	if ok then
		Analytics.launched(list, "private")
		for _, player in list do
			room[player.UserId] = nil
		end
		commitRoom(rec.code, function(r)
			local entry = PrivateLobby.entryFor(r, SERVER_ID)
			if not entry then
				return false
			end
			entry.u = {}
			entry.t = os.time()
			return true
		end)
	else
		sentRoom = ""
		warn("[Matchmaker] room teleport failed: " .. tostring(err))
		Analytics.hopsCancelled(list)
		for _, player in list do
			room[player.UserId] = nil
			toast(player, "Could not start that match. Try again.")
			pushNoRoom(player)
		end
	end
end

local function launchRoom(code: string, expected: number)
	local st = PrivateLobby.settings(roomCache[code] and roomCache[code].s)
	-- A MODE THAT NEEDS A SCENARIO GETS ONE OR IS NOT PLAYED. PrivateLobby
	-- restates which maps have one (the lobby client loads it and should not
	-- pay for Scenarios' 42 KB of WW2 data); this is the check against the real
	-- list, so a drift between the two plays an ordinary round rather than a
	-- free-for-all wearing the historical name.
	local Scenarios = require(Shared.Scenarios)
	if Scenarios.BY_MODE[st.mode] ~= nil and not Scenarios.exists(st.map, st.mode) then
		warn("[Matchmaker] room " .. code .. " asked for " .. st.mode .. " on " .. st.map .. ", which has no scenario -- playing it classic")
		st.mode = PrivateLobby.modeFor(st.teams)
	end

	local ok, access, psid = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not ok then
		if RunService:IsStudio() then
			startRoomLocally(code, st)
			return
		end
		warn("[Matchmaker] ReserveServer failed for room " .. code .. ": " .. tostring(access))
		-- Hand the room back OPEN rather than leaving it claimed until the
		-- stale-steal timer notices. The host can simply press start again.
		commitRoom(code, function(r)
			if r.state ~= "claim" then
				return false
			end
			r.state = "open"
			r.hostServer = ""
			r.claimedAt = 0
			return true
		end)
		return
	end

	-- THE SETTINGS TRAVEL WITH THE RESERVATION, not with the players. This is
	-- the record ConquestServer reads on the far side to know what round to
	-- build, and it is the only thing that decides it.
	local wrote = pcall(function()
		matchStore:SetAsync(psid, {
			access = access,
			map = st.map,
			mode = st.mode,
			teams = st.teams,
			troopScale = st.troopScale,
			startGold = st.startGold,
			-- THE MAP'S OWN CEILING, not the room's; see PrivateLobby.capFor.
			cap = PrivateLobby.capFor(roomCache[code] and roomCache[code].s),
			-- See startRoomLocally: a private room advertises no phantoms, so
			-- it is owed no faux players.
			phantoms = 0,
			slot = 0,
			id = code,
			expected = expected,
			private = true,
		}, Matchmaker.MATCH_RECORD_TTL)
	end)
	if not wrote then
		warn("[Matchmaker] could not publish room " .. code .. "'s match record; it will use the rotation.")
	end

	local now = os.time()
	local published = commitRoom(code, function(r)
		if r.state ~= "claim" then
			return false
		end
		r.state = "ready"
		r.access = access
		r.psid = psid
		r.readyAt = now
		return true
	end)
	if published then
		print(string.format("[Matchmaker] launching room %s -- %s / %s, %d players", code, st.map, st.mode, expected))
		sendRoomToMatch(roomCache[code])
	end
end

-- TAKING THE ROOM, and the transform both ways in. `byUserId` is the host
-- pressing START; nil is the CLOCK running out on a public room, which asks
-- for no host and no press (see PrivateLobby.PUBLIC_START).
--
-- IT IS A TRANSFORM FOR BOTH, and for the same reason: the host's own two
-- servers -- a rejoin mid-press -- can both be holding a copy of the record
-- that says "open", and at a deadline several servers can each notice at once.
-- Exactly one write lands, and the losers see a record that is already claimed
-- and stop. Every condition is re-tested in HERE against the stored record,
-- never against this server's copy, which is up to a second old and unpruned.
--
-- Returns (won, expected, refusal) and takes the claimed record into the cache
-- itself, because the settings the match is built from must come from the
-- record the claim actually SAW -- see the note below `startRoom`.
local function claimRoom(code: string, byUserId: number?): (boolean, number, string)
	local now = os.time()
	local won, expected = false, 0
	local refusal = ""
	local claimed: any = nil
	local ok, err = pcall(function()
		privStore:UpdateAsync(code, function(r: any)
			won, refusal, claimed = false, "", nil
			if type(r) ~= "table" or type(r.servers) ~= "table" then
				refusal = "That lobby is gone."
				return nil
			end
			if byUserId and r.host ~= byUserId then
				refusal = "Only the host can start this lobby."
				return nil
			end
			PrivateLobby.prune(r, now)
			local stale = r.state == "claim" and (now - (r.claimedAt or 0)) > PrivateLobby.CLAIM_STALE
			if r.state ~= "open" and not stale then
				refusal = "That lobby is already starting."
				return nil
			end
			if PrivateLobby.members(r) <= 0 then
				refusal = "There is nobody in that lobby."
				return nil
			end
			-- THE CLOCK IS RE-READ HERE TOO. The host can have flipped the room
			-- back to PRIVATE, or pressed START themselves, in the second
			-- between the poll that saw the deadline pass and this transform.
			if not byUserId and not PrivateLobby.dueToStart(r, now) then
				return nil
			end
			r.state = "claim"
			r.hostServer = SERVER_ID
			r.claimedAt = now
			won = true
			-- Counted AFTER the prune and INSIDE the transform, for the reason
			-- tryClaim spells out: a count taken from a stale copy promises
			-- arrivals that are ghosts, and every real player then watches
			-- PREPARING THE MAP for the whole grace period waiting for them.
			expected = PrivateLobby.members(r)
			claimed = r
			return r
		end, PrivateLobby.TTL)
	end)
	if not ok then
		report("start room " .. code, err)
		return false, 0, "The lobby service is unreachable right now."
	end
	-- THE SETTINGS THE MATCH IS BUILT FROM COME FROM THE RECORD THE CLAIM
	-- ACTUALLY SAW, never from this server's cached copy. They are not always
	-- the same record: a host can inherit a room by reseat (see
	-- PrivateLobby.reseat) and press START on a server whose last poll predates
	-- the previous host's final settings write -- and the match would then be
	-- played on the wrong map with nothing anywhere reporting a problem.
	if won and claimed then
		roomCache[code] = claimed
	end
	return won, expected, refusal
end

-- HOST PRESSES START, which is still the ordinary way a room begins: the
-- countdown a PUBLIC room carries is a ceiling on the wait, never a floor.
local function startRoom(player: Player)
	local code = room[player.UserId]
	if not code then
		return
	end
	local won, expected, refusal = claimRoom(code, player.UserId)
	if not won then
		if refusal ~= "" then
			toast(player, refusal)
		end
		return
	end
	launchRoom(code, expected)
end

-- THE CLOCK RAN OUT. Nobody pressed anything and the room goes anyway --
-- see PrivateLobby.PUBLIC_START for why a room strangers can see is not
-- allowed to sit open forever. Silent on refusal: there is no press to answer
-- and a toast for a race that resolved correctly is a toast about nothing.
local function autoStartRoom(code: string)
	local won, expected = claimRoom(code, nil)
	if not won then
		return
	end
	print("[Matchmaker] room " .. code .. " reached its public deadline -- starting")
	launchRoom(code, expected)
end

-- Polled only for the codes this server actually holds somebody in, so a
-- server with no private lobbies in it does no work and spends no quota.
local lastRoomBeat = 0

-- How long a passed deadline has to sit there before a server that is NOT the
-- host's may start the room. Longer than a poll and shorter than anybody's
-- patience: the host's server gets first refusal and only a dead one loses it.
local AUTO_LATE = 4

local function tickRooms()
	local codes = heldCodes()
	if #codes == 0 then
		return
	end
	local beat = (os.clock() - lastRoomBeat) >= PrivateLobby.HEARTBEAT
	if beat then
		lastRoomBeat = os.clock()
	end

	for _, code in codes do
		local ok, rec = pcall(function()
			return privStore:GetAsync(code)
		end)
		if not ok then
			report("room read " .. code, rec)
		elseif type(rec) ~= "table" or type((rec :: any).servers) ~= "table" then
			-- THE ROOM IS GONE -- its TTL ran out, or a Studio host started it
			-- and deleted it. Say so once rather than leaving everybody
			-- staring at a panel that will never change again.
			for _, player in playersInRoom(code) do
				room[player.UserId] = nil
				pushNoRoom(player)
			end
			roomCache[code] = nil
		else
			roomCache[code] = rec
			pushRoom(code)

			if beat then
				commitRoom(code, function(r)
					local entry = PrivateLobby.entryFor(r, SERVER_ID)
					if not entry then
						-- Our entry is GONE while we still hold members: a
						-- pruning pass beat our heartbeat. Re-create it rather
						-- than leaving people believing they are in a room
						-- that has never heard of them.
						if r.state ~= "open" then
							return false
						end
						entry = { j = SERVER_ID, t = os.time(), u = {} }
						table.insert(r.servers, entry)
					end
					-- Reconcile against who is actually still here, the same
					-- way the public heartbeat does.
					local live = {}
					for userId, c in room do
						if c == code and Players:GetPlayerByUserId(userId) then
							table.insert(live, userId)
						end
					end
					local others = PrivateLobby.members(r) - #(entry :: any).u
					while #live > math.max(0, PrivateLobby.capFor(r.s) - others) do
						table.remove(live)
					end
					;(entry :: any).u = live
					;(entry :: any).t = os.time()
					PrivateLobby.prune(r, os.time())
					PrivateLobby.reseat(r)
					-- AND THE CLOCK, which is idempotent (deadlineFor keeps one
					-- that already exists) so every server may run it. This is
					-- what gives a room written before the countdown shipped a
					-- deadline, and what takes it away again from a room that
					-- somehow left `open` without one being cleared.
					r.deadline = PrivateLobby.deadlineFor(r, os.time())
					return true
				end)
			end

			-- THE SHOP WINDOW, from the host's server only. `room[host] == code`
			-- is true on exactly one server in the universe, and it is free to
			-- test: `room` is this server's own index.
			if beat and room[(rec :: any).host] == code then
				advertise(code, rec)
			end

			-- THE TWO-MINUTE CEILING ON A PUBLIC ROOM. Checked every poll
			-- rather than every heartbeat, because this is a clock somebody is
			-- watching count down and five seconds of overrun on a two-minute
			-- promise is visible.
			--
			-- THE HOST'S SERVER FIRES IT, the same one that advertises the
			-- room, so the usual case costs exactly one UpdateAsync rather than
			-- one per server holding members. The fallback is for the case that
			-- rule cannot cover: the host's server has died or is not polling,
			-- and the room would otherwise hang open at 0 forever -- so once the
			-- deadline is AUTO_LATE seconds old, anybody still in the room may
			-- start it. Several may then try at once; the transform is the
			-- arbiter and the losers write nothing.
			if PrivateLobby.dueToStart(rec, os.time()) then
				local late = os.time() - ((rec :: any).deadline or 0)
				if room[(rec :: any).host] == code or late >= AUTO_LATE then
					autoStartRoom(code)
				end
			end

			-- Somebody else's server reserved it. Send our own people after
			-- them; nobody teleports anybody else's.
			if (rec :: any).state == "ready" then
				sendRoomToMatch(rec)
			end
		end
	end
end

-- --------------------------------------------------------- browsing ------
--
-- SEE ALL GAMES, and the reason this is not simply broadcast to everybody: the
-- list is a MemoryStore range read, and a lobby server that polled for it
-- unconditionally would spend quota on a panel nobody has open. Almost nobody
-- has it open almost all the time, so the page SAYS when it is looking and the
-- server polls only while somebody is.
--
-- A BROWSER GOES STALE ON ITS OWN. The page re-states it while the panel is up;
-- a client that closes the game mid-browse stops saying so and falls out, which
-- means no leak from any disconnect path.
local browsing: { [number]: number } = {}
local BROWSE_STALE = 25
local ROOMS_POLL = 5
local lastRooms = -1e9
local roomsWire: { any } = {}

local function browsers(): { Player }
	local out = {}
	local now = os.clock()
	for userId, at in browsing do
		if now - at > BROWSE_STALE then
			browsing[userId] = nil
		else
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(out, player)
			else
				browsing[userId] = nil
			end
		end
	end
	return out
end

local function pushRooms(who: { Player })
	for _, player in who do
		LobbyRE:FireClient(player, "rooms", roomsWire)
	end
end

local function tickPublic()
	local who = browsers()
	if #who == 0 then
		return
	end
	if os.clock() - lastRooms < ROOMS_POLL then
		return
	end
	lastRooms = os.clock()
	local ok, items = pcall(function()
		return publicStore:GetRangeAsync(Enum.SortDirection.Ascending, PrivateLobby.PUBLIC_MAX)
	end)
	if not ok then
		report("public rooms", items)
		return
	end
	local out = {}
	for _, item in items do
		if type((item :: any).value) == "table" then
			table.insert(out, (item :: any).value)
		end
	end
	roomsWire = out
	pushRooms(who)
end

-- ----------------------------------------------------------- join / leave --

local function removeMember(key: string, userId: number)
	local updated: Record? = nil
	local applied = commit(key, "", function(rec)
		local entry = Matchmaker.entryFor(rec, SERVER_ID)
		if not entry then
			return false
		end
		local at = table.find(entry.u, userId)
		if not at then
			return false
		end
		table.remove(entry.u, at)
		entry.t = os.time()
		Matchmaker.prune(rec, os.time())
		-- Last one out RESTARTS the clock rather than stopping it -- the card
		-- keeps counting down with nobody in it now -- and the next joiner
		-- gets a fresh clock rather than the tail of somebody else's. Onto
		-- this slot's own grid point; see Matchmaker.nextDeadline.
		if Matchmaker.count(rec) == 0 then
			rec.deadline = Matchmaker.nextDeadline(rec.slot, os.time())
		end
		updated = rec
		return true
	end)
	if mine[userId] == key then
		mine[userId] = nil
	end
	-- Show it now, from the transform's own result -- see pushBoard.
	if applied and updated then
		boardCache[key] = updated
		pushBoard(true)
	end
end

local function leaveAll(userId: number)
	local key = mine[userId]
	if key then
		removeMember(key, userId)
	end
end

local function joinSlot(player: Player, key: string)
	local userId = player.UserId
	local now = os.time()
	local refusal = ""
	local okJoin = false
	local updated: Record? = nil

	local ok, err = pcall(function()
		lobbyStore:UpdateAsync(key, function(rec: any)
			okJoin = false
			refusal = ""
			updated = nil
			if type(rec) ~= "table" then
				refusal = "That lobby is not open yet."
				return nil
			end
			Matchmaker.prune(rec, now)
			-- THE CLOSING RACE. The player pressed JOIN while this lobby was
			-- being claimed. Refusing inside the transform is what makes it
			-- impossible for them to be added to a match that has already
			-- reserved its server and left without them.
			if rec.state ~= "open" then
				refusal = "That match just started -- try the next one."
				return nil
			end
			if Matchmaker.hasMember(rec, userId) then
				okJoin = true
				return nil
			end
			-- SEATS, not heads: the phantoms hold part of this card's cap and
			-- the count the player is looking at includes them, so a lobby
			-- that reads 6 / 6 has to refuse the seventh press.
			if Matchmaker.seats(rec) >= rec.cap then
				refusal = "That lobby just filled up."
				return nil
			end
			local entry = Matchmaker.entryFor(rec, SERVER_ID)
			if not entry then
				entry = { j = SERVER_ID, t = now, u = {} }
				table.insert(rec.servers, entry)
			end
			;(entry :: Matchmaker.ServerEntry).t = now
			table.insert((entry :: Matchmaker.ServerEntry).u, userId)
			-- THE COUNTDOWN NO LONGER STARTS HERE. A record is born counting
			-- down (Matchmaker.newRecord), so this is now only the guard for a
			-- record that reaches us with a stopped clock -- which is a v1
			-- record, and those live in a different store.
			if rec.deadline == 0 then
				rec.deadline = Matchmaker.nextDeadline(rec.slot, now)
			end
			okJoin = true
			updated = rec
			return rec
		end, Matchmaker.RECORD_TTL)
	end)

	if not ok then
		report("join " .. key, err)
		toast(player, "The matchmaker is unreachable right now.")
		return
	end
	if okJoin then
		mine[userId] = key
		-- Straight out to every client, without waiting for the poll. This is
		-- the whole difference between a card that answers the press and one
		-- that sits there looking broken.
		if updated then
			boardCache[key] = updated
			pushBoard(true)
			-- ...and the only place a join is COUNTED. `updated` is nil for a
			-- press the transform refused and for a re-join by somebody
			-- already in the lobby, so this is one tally per seat actually
			-- taken. Spawned inside; the press does not wait for it.
			noteJoin(updated)
		end
	elseif refusal ~= "" then
		toast(player, refusal)
	end
end

-- -------------------------------------------------------------- tutorial ---
--
-- A TUTORIAL IS A MATCH SERVER WITH ONE SEAT. Same reserved server every round
-- runs on, reached the same way, configured through the same match record --
-- with `tutorial = true` on it, which is the only thing that makes it a lesson
-- rather than a very small skirmish. There is no second launch path here; this
-- is the match path with `expected = 1`.
--
-- It is neither a board slot nor a private room, because there is no countdown
-- to wait out and nobody to wait for: the press reserves and teleports in one
-- go instead of joining anything.

-- WHICH MAP THIS PLAYER LEARNS ON. Dealt by `Tutorial.mapFor` -- one of
-- Tutorial.MAPS, fixed per account -- so that ConquestAnalytics can carry a
-- funnel per map and the owner can read the three completion rates side by
-- side (2026-09-08). The one way to CHOOSE is `/tutorial <map>`, and it is the
-- owner's only: a player who could pick their map would be picking which
-- funnel they count in. Studio is open season, as it is for /start, and has
-- no funnel to spoil -- AnalyticsService records nothing from here.
local function tutorialMapFor(player: Player, text: any): string
	if typeof(text) == "string" then
		local token = string.match(string.lower(text), "^%s*/%S+%s+(%a+)")
		local allowed = RunService:IsStudio()
			or (game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId)
		-- Maps is required HERE, not at the top of the file: the /world
		-- launcher below does the same, and this is the only other reader.
		-- A second require is a cache hit.
		if token ~= nil and allowed and require(Shared.Maps).exists(token) then
			return token
		end
	end
	return Tutorial.mapFor(player.UserId)
end

-- Studio has no reserved servers, so the tutorial starts in the session it was
-- pressed in -- the same trick `startLocally` and `startRoomLocally` play.
local function startTutorialLocally(mapId: string)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MAP_ATTR, mapId)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MODE_ATTR, Tutorial.MODE_ID)
	-- The empires wearing a real name and face. A tutorial has no lobby card
	-- behind it promising seats, so the figure is the tutorial's own.
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_PHANTOMS_ATTR, Tutorial.FAUX_COUNT)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TUTORIAL_ATTR, true)
	-- A PRIVATE ROOM'S DIALS MUST NOT LEAK IN. These attributes outlive
	-- whatever set them, so a session where somebody started a 4-team room with
	-- quadruple troops would otherwise teach the game on that.
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TEAMS_ATTR, 0)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TROOPS_ATTR, 1)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_GOLD_ATTR, 0)
	-- A LESSON HAS NO CLANS. Cleared rather than left, exactly like the dials
	-- above it: a tag set before somebody pressed LEARN TO PLAY would otherwise
	-- be worn into a round that has no teams for it to mean anything in.
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TAGS_ATTR, "{}")
	ReplicatedStorage:SetAttribute(Matchmaker.ROLE_ATTR, "match")
	print("[Matchmaker] STUDIO: no reserved servers here, so the tutorial starts in this session.")
end

-- `text` is the typed chat line, if a line was typed (`/tutorial world`); nil
-- for the automatic first-join launch. Only the owner's map choice is read
-- from it -- see tutorialMapFor.
local function startTutorial(player: Player, text: any?)
	-- A TUTORIAL AND A QUEUED SEAT ARE EXCLUSIVE, for the same reason a room
	-- and a slot are: both can teleport you, and whichever fires first decides
	-- which game you were in.
	leaveAll(player.UserId)

	-- THE MAP IS DEALT HERE AND NOWHERE ELSE, and it is dealt BEFORE the
	-- teleport payload is built: `tutorialArm` writes it onto the visit, and
	-- `Analytics.teleportData` below carries the visit -- so the match server
	-- and the lobby it comes home to both know which funnel this lesson
	-- belongs in. A visit that arrived with no map would put its card rows
	-- under nothing.
	local mapId = tutorialMapFor(player, text)
	Analytics.tutorialArm(player, mapId)

	local ok, access, psid = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not ok then
		if RunService:IsStudio() then
			startTutorialLocally(mapId)
			return
		end
		warn("[Matchmaker] ReserveServer failed for the tutorial: " .. tostring(access))
		toast(player, "Could not open the tutorial. Try again.")
		return
	end

	-- THE RECORD IS WHAT MAKES IT A TUTORIAL, and nothing else does. The far
	-- side reads it by PrivateServerId; it never reads the teleport data, which
	-- belongs to whichever client arrives first -- here also the only one.
	local wrote = pcall(function()
		matchStore:SetAsync(psid, {
			access = access,
			-- The dealt map, not Tutorial.MAP_ID: the far side builds
			-- whatever this says, and its funnel row is named after it.
			map = mapId,
			mode = Tutorial.MODE_ID,
			cap = 1,
			slot = 0,
			id = "tutorial",
			expected = 1,
			phantoms = Tutorial.FAUX_COUNT,
			tutorial = true,
		}, Matchmaker.MATCH_RECORD_TTL)
	end)
	if not wrote then
		-- Refuse rather than send them anyway. Without the record the far side
		-- falls back to the map rotation and runs an ordinary sixty-nine-empire
		-- round with no lesson track on it -- a worse first game than the page
		-- they are already standing on.
		warn("[Matchmaker] could not publish the tutorial's match record")
		toast(player, "Could not open the tutorial. Try again.")
		return
	end

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = access
	-- `cq` is the analytics payload: when this visit began and the id that ties
	-- its funnel steps together, keyed by user id exactly as the clan tags are.
	-- Without it the press that led here and the lesson it leads to are two
	-- unrelated sessions, and the tutorial funnel has no top.
	options:SetTeleportData({ tutorial = true, cq = Analytics.teleportData({ player }) })
	local sent = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if sent then
		Analytics.launched({ player }, "tutorial")
	else
		Analytics.hopCancelled(player)
		toast(player, "Could not open the tutorial. Try again.")
	end
end

-- --------------------------------------------------------- /world, /map ---
--
-- THE OWNER'S SHORTCUT TO A NAMED MAP (2026-09-08). ConquestWorld in
-- ServerScriptService parses the chat and gates it; the LAUNCH lives here,
-- because everything a launch needs -- leaveAll, the match store, the
-- reserved server, the clan tags and the Studio fallback -- is a local of this
-- script, and a second copy of them elsewhere would drift. Same split as
-- /endgame and _G.ConquestEndRound.
--
-- Shape is startTutorial's: reserve a server, write the record that tells it
-- what to run, teleport the one player. `expected = 1`, so the far side does
-- not hold the start open for a roster nobody promised, and `phantoms = 0`,
-- so the round is real players plus ordinary NPC nations. In Studio there
-- are no reserved servers, so it is the attribute channel every other local
-- start uses, with every dial stated. Returns ok, line.
_G.ConquestStartMap = function(player: Player, mapId: string, modeId: string): (boolean, string)
	local Maps = require(Shared.Maps)
	local Modes = require(Shared.Modes)
	if not Maps.exists(mapId) then
		return false, "'" .. mapId .. "' is not a map -- one of " .. table.concat(Maps.ORDER, ", ")
	end
	-- `exists`, not ORDER: the historical mode is a real mode that is kept
	-- OUT of the rotation on purpose (Modes), and this command is its only door.
	if not Modes.exists(modeId) then
		return false, "'" .. modeId .. "' is not a mode -- one of " .. table.concat(Modes.ORDER, ", ") .. ", historical, " .. table.concat(Modes.specialIds(), ", ")
	end
	if ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) ~= "lobby" then
		return false, "this server is already running a round -- /world works from the lobby page."
	end
	-- A COMMAND AND A QUEUED SEAT ARE EXCLUSIVE, for the same reason a room
	-- and a slot are: both can teleport you.
	leaveAll(player.UserId)

	local ok, access, psid = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not ok then
		if RunService:IsStudio() then
			ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MAP_ATTR, mapId)
			ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MODE_ATTR, modeId)
			ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TEAMS_ATTR, 0)
			ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TROOPS_ATTR, 1)
			ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_GOLD_ATTR, 0)
			ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_PHANTOMS_ATTR, 0)
			ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TUTORIAL_ATTR, false)
			ReplicatedStorage:SetAttribute(
				Matchmaker.LOCAL_TAGS_ATTR,
				HttpService:JSONEncode(tagsFor(Players:GetPlayers()))
			)
			ReplicatedStorage:SetAttribute(Matchmaker.ROLE_ATTR, "match")
			print(string.format(
				"[Matchmaker] STUDIO: no reserved servers here, so /world starts %s / %s in this session.",
				mapId, modeId
			))
			return true, string.format("starting %s / %s in this session", Maps.name(mapId), modeId)
		end
		warn("[Matchmaker] ReserveServer failed for /world: " .. tostring(access))
		return false, "could not reserve a server -- try again."
	end

	local wrote = pcall(function()
		matchStore:SetAsync(psid, {
			access = access,
			map = mapId,
			mode = modeId,
			cap = 1,
			slot = 0,
			id = "command",
			expected = 1,
			phantoms = 0,
			tutorial = false,
		}, Matchmaker.MATCH_RECORD_TTL)
	end)
	if not wrote then
		-- Refuse rather than send: without the record the far side falls back
		-- to the rotation, which is the opposite of what was asked for.
		warn("[Matchmaker] could not publish the /world match record")
		return false, "could not publish the match record -- try again."
	end

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = access
	options:SetTeleportData({
		map = mapId,
		mode = modeId,
		tags = tagsFor({ player }),
		cq = Analytics.teleportData({ player }),
	})
	local sent = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if not sent then
		Analytics.hopCancelled(player)
		return false, "teleport failed -- try again."
	end
	Analytics.launched({ player }, "command")
	return true, string.format("teleporting you to a %s / %s server", Maps.name(mapId), modeId)
end

-- /spawn (2026-09-11, owner: "make /spawn historical, so i can see what it
-- looks like in the homepage"). Puts a chosen map/mode pairing on a lobby
-- CARD instead of starting a round: the first OPEN slot with nobody queued in
-- it is re-minted with that pairing -- a fresh generation and a fresh clock --
-- and the board goes out at once. From then on it is an ordinary card: it
-- takes joins, launches, and rolls over at the end of its countdown like any
-- other. A card somebody is queued in is never taken; this is a look at the
-- page, not a way to pull people off a lobby. Parsed and gated in
-- ConquestWorld, the same split as /world and _G.ConquestStartMap.
_G.ConquestSpawnCard = function(player: Player, mapId: string, modeId: string): (boolean, string)
	local Maps = require(Shared.Maps)
	local Modes = require(Shared.Modes)
	if not Maps.exists(mapId) or not Modes.exists(modeId) then
		return false, "'" .. mapId .. " / " .. modeId .. "' is not a map and mode."
	end
	if ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) ~= "lobby" then
		return false, "this server is running a round -- /spawn works from the lobby page."
	end
	for _, slot in Matchmaker.SLOTS do
		local rec = boardCache[slot.key]
		if rec and rec.state ~= "retired" and rec.map == mapId and rec.mode == modeId then
			return true, string.format("%s / %s is already on the %s card.", Maps.name(mapId), Modes.name(modeId), slot.name)
		end
	end
	for _, slot in Matchmaker.SLOTS do
		local rec = boardCache[slot.key]
		if rec and rec.state == "open" and Matchmaker.count(rec) == 0 then
			local minted = nil
			local applied = commit(slot.key, rec.id, function(r)
				-- Re-checked inside the transform: somebody may have joined
				-- while the cached board was being read.
				if r.state ~= "open" or Matchmaker.count(r) > 0 then
					return false
				end
				local fresh = Matchmaker.newRecord(r.slot, nil)
				for k, v in fresh do
					(r :: any)[k] = v
				end
				r.map, r.mode = mapId, modeId
				-- THE CAP BELONGS TO THE MAP, AND THE MAP JUST CHANGED.
				-- newRecord computed `cap` from whatever pairing IT drew, so
				-- overwriting the map without recomputing left a Korea card
				-- advertising 24 seats (or a World card advertising 2, when the
				-- draw happened to be Korea). Same rule as newRecord.
				-- THE RECORD'S RUNG, not the slot table's. For slots 4 and 5
				-- the table only ever held a cold-start default, so reading it
				-- here would quietly shrink a 24-seat extra to six.
				local slotCap = r.size or (Matchmaker.SLOTS[r.slot] or slot).cap
				local mapCap = tonumber((Maps.get(mapId) :: any).MAX_EMPIRES)
				r.cap = if mapCap then math.min(slotCap, mapCap) else slotCap
				minted = r
				return true
			end)
			if applied and minted then
				boardCache[slot.key] = minted
				pushBoard(true)
				return true, string.format(
					"%s / %s is on the %s card -- it rolls over when its clock runs out, like any card.",
					Maps.name(mapId), Modes.name(modeId), slot.name
				)
			end
		end
	end
	return false, "every card has somebody queued in it -- try again in a moment."
end

LobbyIntentRE.OnServerEvent:Connect(function(player, action, key, tag)
	if typeof(action) ~= "string" then
		return
	end
	local userId = player.UserId
	local now = os.clock()

	-- THE CLAN TAG IS TAKEN BEFORE EITHER GATE, because it is the one thing on
	-- this remote that is free: a write into a local table, no MemoryStore
	-- behind it and nothing to serialise. Gating it would mean a tag typed
	-- just after a press is silently dropped, and the tag is what decides
	-- which side of the match its owner lands on.
	--
	-- It rides along with the three intents that ENTER a match, and "tag" is
	-- the catch-up send for somebody who queued first and typed afterwards.
	-- Normalised HERE and not trusted from the page: same function the client
	-- ran, because a client can send anything at all.
	if action == "tag" or action == "join" or action == "pjoin" or action == "create" then
		local t = Matchmaker.normaliseTag(tag)
		-- An EMPTY tag only clears when it was sent deliberately. A join that
		-- carries nothing must not wipe a tag this player already set -- the
		-- page sends both, and the order they arrive in is not guaranteed.
		if t ~= "" or action == "tag" then
			tagOf[userId] = t
		end
		if action == "tag" then
			return
		end
	end
	-- THE SHOP, ahead of both gates below and for the same reason the clan tag
	-- is: there is no MemoryStore write behind any of it. It carries its own,
	-- much shorter cooldown instead -- enough that a modified client cannot
	-- hammer DataStore flushes, nowhere near enough to be felt by somebody
	-- browsing swatches.
	-- THE SEE ALL GAMES PANEL SAYING IT IS OPEN. Ahead of both gates below for
	-- the same reason the shop is: there is no MemoryStore write behind it --
	-- it sets one number in a local table -- and behind the board's
	-- one-a-second cooldown the panel's own keep-alive would eat the JOIN press
	-- the player is about to make from inside it.
	if action == "browse" then
		if key == false then
			browsing[userId] = nil
		else
			-- A COLD LIST IS WORTH ONE READ OUT OF TURN: the first person to
			-- open the panel on this server would otherwise watch an empty
			-- sheet until the next poll. Self-limiting -- it can only fire when
			-- the last read is already older than the cadence, which is exactly
			-- when the poll would have read anyway, so a client saying this in
			-- a loop buys itself nothing.
			local already = browsing[userId] ~= nil
			browsing[userId] = now
			if not already and os.clock() - lastRooms > ROOMS_POLL then
				lastRooms = -1e9
			end
			-- ...and whatever was last read, right now. The panel opens on the
			-- previous poll's list rather than on nothing.
			if #roomsWire > 0 then
				LobbyRE:FireClient(player, "rooms", roomsWire)
			end
		end
		return
	end

	if action == "flag" then
		-- The other tab of the same shop, and there is no MemoryStore behind
		-- this one either -- so it shares the cosmetic cooldown rather than the
		-- board's much longer one.
		if (cosmeticAt[userId] or 0) > now - COSMETIC_COOLDOWN then
			return
		end
		cosmeticAt[userId] = now
		if key == "equip" then
			local ok, why = Data.equipFlag(player, tag)
			if not ok then
				toast(player, why)
			end
			sendFlags(player)
		elseif key == "buy" then
			local ok, why = Data.buyFlag(player, tag)
			if ok then
				-- DURABLE NOW, for the reason the pattern buy below gives: this
				-- player is one JOIN press from a teleport, and the far side
				-- reads what was WRITTEN.
				task.spawn(Data.flush, player)
			else
				toast(player, why)
			end
			sendFlags(player)
		end
		return
	end

	-- THE FREE REWARDS CLAIM (2026-09-17). Its own verb rather than a third
	-- `pattern` key, because it is not a cosmetic press: it moves the balance
	-- as well, it is a once-per-account latch, and it must not share the
	-- cosmetic cooldown with the shop's equip presses.
	--
	-- NOTHING HERE VERIFIES THE TWO STEPS. There is no server-side way to ask
	-- whether an account favourited the game (the avatar-editor read is the
	-- player's own client, behind their own permission prompt) and no way at
	-- all to ask about a like. The latch is what this owns.
	if action == "reward" then
		if (cosmeticAt[userId] or 0) > now - COSMETIC_COOLDOWN then
			return
		end
		cosmeticAt[userId] = now
		local skin = Patterns.REWARD_KEY
		if not Data.claimFreeReward(player, REWARD_MONEY, skin) then
			-- TWO VERY DIFFERENT REFUSALS, and the player is owed which one it
			-- was. Already claimed is a fact about the account and the sheet
			-- corrects itself; a profile that has not loaded is a DataStore that
			-- is down or locked, nothing was written, and the right answer is to
			-- say so and let them press again rather than leave a button that
			-- looks broken.
			sendPatterns(player)
			sendReward(player, if Data.freeRewardClaimed(player)
				then "YOU HAVE ALREADY CLAIMED THIS"
				else "YOUR PROFILE HAS NOT LOADED YET -- TRY AGAIN")
			return
		end
		-- DURABLE BEFORE IT IS ANNOUNCED. If the write fails the grant is taken
		-- back out of memory -- otherwise the latch survives, the player never
		-- sees the skin, and the sheet refuses to give it to them again.
		if not Data.flush(player) then
			Data.unclaimFreeReward(player, REWARD_MONEY, skin)
			sendPatterns(player)
			-- ON THE SHEET, not the page. See sendReward.
			sendReward(player, "COULD NOT SAVE THAT -- TRY AGAIN")
			return
		end
		sendPatterns(player)
		return
	end

	if action == "pattern" then
		if (cosmeticAt[userId] or 0) > now - COSMETIC_COOLDOWN then
			return
		end
		cosmeticAt[userId] = now
		if key == "equip" then
			local ok, why = Data.equipPattern(player, tag)
			if not ok then
				toast(player, why)
			end
			sendPatterns(player)
		elseif key == "buy" then
			local ok, why = Data.buyPattern(player, tag)
			if ok then
				-- DURABLE NOW, not at the next autosave. This player is one
				-- JOIN press from a teleport, and the match server on the far
				-- side reads what was WRITTEN -- so a purchase still sitting
				-- in memory when they leave is one they paid for and did not
				-- get.
				task.spawn(Data.flush, player)
			else
				toast(player, why)
			end
			sendPatterns(player)
		end
		return
	end

	-- One in flight per player. Both paths yield on MemoryStore, and a player
	-- mashing JOIN could otherwise have two transforms racing to add the same
	-- id twice.
	if busy[userId] then
		return
	end
	-- ...and a COOLDOWN on top of that, because `busy` only serialises: every
	-- join and leave is a MemoryStore WRITE, and the universe's whole budget is
	-- 1000 + 100 x CCU per MINUTE. One bored player alternating JOIN and LEAVE
	-- as fast as the round trip allows is a few writes a second on its own;
	-- sixty of them would take the board down for everybody.
	if (cooldown[userId] or 0) > now - INTENT_COOLDOWN then
		return
	end
	cooldown[userId] = now
	-- THE PRESS, recorded before its outcome and after both gates -- so it is
	-- one line per intent a player actually made, not one per packet a client
	-- sent. Which press it was is the whole point: "nobody presses anything"
	-- and "everybody presses LEAVE" are different games.
	Analytics.lobbyPress(player, action)
	busy[userId] = true
	task.spawn(function()
		local ok = pcall(function()
			-- ---------------------------------------- private lobbies --
			-- These share the busy guard and the one-a-second cooldown with
			-- the public board's intents, because they are the same kind of
			-- thing: every one of them is a MemoryStore write.
			if action == "create" then
				-- A PRIVATE ROOM AND A PUBLIC SLOT ARE EXCLUSIVE, and this is
				-- not tidiness: they are two independent things that can each
				-- teleport you, so being in both means whichever fires first
				-- decides which game you were in and the other one launches
				-- without you.
				leaveAll(userId)
				createRoom(player, key)
				return
			elseif action == "pjoin" then
				local code = PrivateLobby.normalise(key)
				if not code then
					toast(player, "A lobby code is four digits.")
					return
				end
				leaveAll(userId)
				joinRoom(player, code)
				return
			elseif action == "pleave" then
				leaveRoom(player)
				return
			elseif action == "pset" then
				setRoom(player, key)
				return
			elseif action == "pstart" then
				startRoom(player)
				return
			elseif action == "tutorial" then
				-- `key` is the typed chat line when /tutorial was used; only
				-- the owner's map choice is ever read out of it.
				startTutorial(player, key)
				return
			end

			if action == "join" then
				if typeof(key) ~= "string" then
					return
				end
				local slot
				for _, s in Matchmaker.SLOTS do
					if s.key == key then
						slot = s
					end
				end
				if not slot then
					return
				end
				-- A player is in at most one lobby. Leaving first also means
				-- the count they just left is correct before they appear in
				-- the new one.
				if mine[userId] and mine[userId] ~= key then
					removeMember(mine[userId] :: string, userId)
				end
				-- ...and out of any private room, for the reason above.
				if room[userId] then
					leaveRoom(player)
				end
				joinSlot(player, key)
			elseif action == "leave" then
				leaveAll(userId)
			elseif action == "start" then
				-- /start -- skip the countdown on the lobby you are in. It does
				-- NOT start anything itself: it drags the deadline into the
				-- past and lets the ordinary launch path notice, so there is no
				-- second route into a match that could drift from the first.
				--
				-- GATED, because on a live server this would otherwise let any
				-- player cut short everybody else's two minutes. Studio is open
				-- season; a real server allows only the owner.
				local allowed = RunService:IsStudio()
					or (game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId)
				if not allowed then
					toast(player, "/start is for the owner only.")
					return
				end
				local key = mine[userId]
				if not key then
					toast(player, "Join a lobby first, then /start it.")
					return
				end
				local started: Record? = nil
				local pulled = commit(key, "", function(rec)
					if rec.state ~= "open" then
						return false
					end
					rec.deadline = os.time() - 1
					started = rec
					return true
				end)
				-- Forced, because `signature` ignores the countdown and this
				-- changes nothing else -- without it the shortcut would not
				-- show up until something unrelated moved.
				if pulled and started then
					boardCache[key] = started
					pushBoard(true)
				end
				toast(player, pulled and "Starting that lobby now." or "That lobby is already starting.")
			end
		end)
		if not ok then
			toast(player, "Something went wrong -- try again.")
		end
		busy[userId] = false
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	local userId = player.UserId
	local key = mine[userId]
	local code = room[userId]
	mine[userId] = nil
	room[userId] = nil
	busy[userId] = nil
	browsing[userId] = nil
	following[userId] = nil
	-- A tag belongs to a session, not to an account. Left behind, it would be
	-- worn by whoever rejoins this server as that user id -- and on a lobby
	-- server that is a long-lived table nobody else prunes.
	tagOf[userId] = nil
	if key then
		task.spawn(removeMember, key, userId)
	end
	-- Quitting the game and pressing LEAVE are the same event to the record,
	-- and the seat has to pass on either one.
	if code then
		task.spawn(dropMember, code, userId)
	end
end)

-- -------------------------------------------------------------- teleport ---

-- The lobby generation this server has already sent its players to. A SINGLE
-- string, not a set: a set keyed by generation is only ever appended to, so it
-- grows by one entry per launched lobby for the life of the server, and the
-- only generation that can matter is the one the tick is looking at right now.
local teleportedGeneration = ""

local function myPlayersIn(key: string): { Player }
	local list = {}
	for userId, slotKey in mine do
		if slotKey == key then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(list, player)
			end
		end
	end
	return list
end

local function sendToMatch(rec: Record)
	local key = Matchmaker.SLOTS[rec.slot].key
	if teleportedGeneration == rec.id then
		return
	end
	local list = myPlayersIn(key)
	if #list == 0 then
		return
	end
	teleportedGeneration = rec.id

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = rec.code
	-- Carried for convenience only. The match server reads its map and mode
	-- from the match record keyed by PrivateServerId, NOT from this -- teleport
	-- data belongs to whichever client arrives first, which is not a thing the
	-- round should depend on.
	-- ...with ONE exception, and it is the clan tags. They are not "convenience"
	-- and there is nowhere else for them to be read from: the match record is
	-- keyed by PrivateServerId and shared by every server feeding this match,
	-- while a tag belongs to a PERSON. Teleport data is the only channel that
	-- arrives per batch, which is exactly the granularity a per-player value
	-- needs -- each lobby server sends its own people with its own tags.
	options:SetTeleportData({
		slot = rec.slot,
		map = rec.map,
		mode = rec.mode,
		id = rec.id,
		tags = tagsFor(list),
		-- The analytics payload, per player and for the same reason the tags
		-- are: a visit that crosses a teleport has to stay ONE visit, or the
		-- game reports two short sessions where a person played one long one.
		cq = Analytics.teleportData(list),
	})

	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, list, options)
	end)
	if not ok then
		-- One retry, then give up and put them back on the page. The match
		-- still runs for everyone whose server managed it.
		task.wait(1)
		-- Re-take the list: anyone who left during that second is not ours to
		-- send any more, and TeleportAsync throws on a player who is not in
		-- this server -- which would fail the retry for EVERYONE in the batch,
		-- not just for the one who quit.
		list = myPlayersIn(key)
		if #list == 0 then
			teleportedGeneration = ""
			return
		end
		ok = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, list, options)
		end)
	end
	if ok then
		Analytics.launched(list, "public")
		for _, player in list do
			mine[player.UserId] = nil
		end
		commit(key, rec.id, function(r)
			local entry = Matchmaker.entryFor(r, SERVER_ID)
			if not entry then
				return false
			end
			entry.u = {}
			entry.t = os.time()
			return true
		end)
	else
		teleportedGeneration = ""
		warn("[Matchmaker] teleport failed: " .. tostring(err))
		-- They are still here, so their visit never ended. Un-arming the hop is
		-- what stops a failed teleport from deleting that visit's length from
		-- the playtime numbers.
		Analytics.hopsCancelled(list)
		for _, player in list do
			mine[player.UserId] = nil
			toast(player, "Could not join that match. Pick another.")
		end
	end
end

TeleportService.TeleportInitFailed:Connect(function(player, result, message)
	warn("[Matchmaker] TeleportInitFailed " .. tostring(result) .. ": " .. tostring(message))
	if player and player.Parent then
		Analytics.hopCancelled(player)
		mine[player.UserId] = nil
		-- A FOLLOW that never got off the ground: `busy` was latched for the
		-- teleport and `following` said "sent", and with both left standing
		-- the player could neither press a card nor be given the tutorial.
		if following[player.UserId] == "sent" then
			following[player.UserId] = nil
			busy[player.UserId] = nil
			followState(player, "stay")
			toast(player, "Could not reach your friend's game.")
		else
			toast(player, "Could not join that match. Pick another.")
		end
	end
end)

-- ---------------------------------------------------------------- launch ---

-- STUDIO HAS NO RESERVED SERVERS, so a Studio lobby starts the round in the
-- session it is already in: it flips the role attribute, which both
-- ConquestServer and ConquestClient are waiting on. That is what makes the
-- whole page testable in Studio -- join a card, watch the clock run out, and
-- the game begins -- with only the teleport itself left for a live test.
local function startLocally(rec: Record, phantoms: number)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MAP_ATTR, rec.map)
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_MODE_ATTR, rec.mode)
	-- The seats nobody was sitting in, so the round makes up exactly the
	-- players the card promised and not one more. On a reserved server this
	-- rides in the match record; there is no record here to put it in.
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_PHANTOMS_ATTR, phantoms)
	-- CLEARED, NOT LEFT: these attributes outlive whatever set them, so a
	-- session where somebody pressed LEARN TO PLAY earlier would otherwise run
	-- this board's match on the tutorial's fixed small roster with a lesson
	-- track over it. Every local start states every dial it cares about.
	ReplicatedStorage:SetAttribute(Matchmaker.LOCAL_TUTORIAL_ATTR, false)
	-- THE CLAN TAGS, which on a reserved server ride in the teleport data. This
	-- round has no teleport -- it starts where it was queued -- so the same map
	-- goes on an attribute for ConquestServer to read. Everyone in the session
	-- is in the batch, because in Studio everyone in the session is the batch.
	ReplicatedStorage:SetAttribute(
		Matchmaker.LOCAL_TAGS_ATTR,
		HttpService:JSONEncode(tagsFor(Players:GetPlayers()))
	)
	ReplicatedStorage:SetAttribute(Matchmaker.ROLE_ATTR, "match")
	-- Hand the slot back OPEN. This session stops polling the moment the role
	-- flips, so without a reset the record sits in "claim" for its whole
	-- 15-minute TTL and the next Studio playtest finds that card unjoinable --
	-- every join refused with "that match just started".
	local key = Matchmaker.SLOTS[rec.slot].key
	-- Drawn against what the other two cards are showing rather than against
	-- nothing: a slot handed back OPEN with `nil` here can re-open on the map
	-- one of its neighbours is already advertising.
	local elsewhere = shownElsewhere(boardCache, key)
	commit(key, rec.id, function(r)
		-- ...unless the hour no longer wants this slot: then it is handed
		-- back as a tombstone, the same as a rollover would (tick).
		if r.slot > liveSlots then
			r.state = "retired"
			return true
		end
		local fresh = Matchmaker.newRecord(r.slot, elsewhere)
		for k, v in fresh do
			(r :: any)[k] = v
		end
		return true
	end)
	print(
		string.format(
			"[Matchmaker] STUDIO: no reserved servers here, so %s (%s / %s) starts in this session.",
			Matchmaker.SLOTS[rec.slot].name,
			rec.map,
			rec.mode
		)
	)
end

local function launch(rec: Record, key: string, expected: number, phantoms: number)
	local ok, code, psid = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)

	if not ok then
		if RunService:IsStudio() then
			startLocally(rec, phantoms)
			return
		end
		warn("[Matchmaker] ReserveServer failed: " .. tostring(code))
		-- Hand the slot back so another server can try, rather than leaving it
		-- claimed until the stale-steal timer notices.
		commit(key, rec.id, function(r)
			if r.state ~= "claim" then
				return false
			end
			r.state = "open"
			r.host = ""
			r.claimedAt = 0
			return true
		end)
		return
	end

	local wrote = pcall(function()
		matchStore:SetAsync(psid, {
			access = code,
			map = rec.map,
			mode = rec.mode,
			cap = rec.cap,
			slot = rec.slot,
			id = rec.id,
			expected = expected,
			-- THE SEATS NOBODY WAS SITTING IN. The card said this match had
			-- `expected + phantoms` commanders in it and the match server owes
			-- the difference; it makes exactly this many empires wear a name
			-- and a face. Counted at CLAIM time with `expected`, off the same
			-- record, so the two can never disagree.
			phantoms = phantoms,
		}, Matchmaker.MATCH_RECORD_TTL)
	end)
	if not wrote then
		-- Not fatal: the match server falls back to its own rotation, and a
		-- round on the wrong map beats no round at all.
		warn("[Matchmaker] could not publish the match record; that server will pick its own map.")
	end

	local now = os.time()
	local published = commit(key, rec.id, function(r)
		if r.state ~= "claim" then
			return false
		end
		r.state = "ready"
		r.code = code
		r.psid = psid
		r.readyAt = now
		return true
	end)
	if published then
		rec.state = "ready"
		rec.code = code
		rec.psid = psid
		rec.readyAt = now
		print(
			string.format(
				"[Matchmaker] launching %s -- %s / %s, %d players",
				Matchmaker.SLOTS[rec.slot].name,
				rec.map,
				rec.mode,
				expected
			)
		)
		sendToMatch(rec)
	else
		-- THE CODE COULD NOT BE WRITTEN ONTO THE CARD (2026-09-20). Seen live
		-- at the store's memory quota: the record grows by an access code, the
		-- write is refused, and the card sat at 0:00 with people on it while
		-- the stale-claim steal reserved a fresh server every 15 s forever.
		-- Hand the slot back OPEN on a fresh clock instead -- that write only
		-- SHRINKS the record, so it lands even when the one above could not --
		-- and the page shows a clock that restarts, which is a symptom anybody
		-- can see, rather than one frozen at zero. The reserved server is
		-- simply never used; the match record expires on its own.
		warn("[Matchmaker] could not publish the access code for " .. key .. " -- reopening the card.")
		commit(key, rec.id, function(r)
			if r.state ~= "claim" then
				return false
			end
			r.state = "open"
			r.host = ""
			r.claimedAt = 0
			r.deadline = Matchmaker.nextDeadline(r.slot, os.time())
			return true
		end)
	end
end

-- Returns whether we won the claim, how many players the record actually held
-- at the moment we won it, and how many phantom seats it was advertising
-- alongside them. The second value matters: it is what the match
-- server waits for, and the caller's copy of the record is up to a second old
-- and has not been pruned, so counting it there can promise arrivals that were
-- ghosts -- and every real player then stares at PREPARING THE MAP for the
-- whole 25-second grace waiting for somebody who does not exist.
local function tryClaim(rec: Record, key: string, now: number): (boolean, number, number)
	local won = false
	local claimed = 0
	local phantoms = 0
	local ok, err = pcall(function()
		lobbyStore:UpdateAsync(key, function(r: any)
			won = false
			if type(r) ~= "table" or r.id ~= rec.id then
				return nil
			end
			Matchmaker.prune(r, now)
			-- THE STALE-CLAIM STEAL. A host that crashed between claiming and
			-- publishing leaves the slot in "claim" forever, and its players
			-- would sit watching a dead clock. After CLAIM_STALE anybody may
			-- take it over.
			local stale = r.state == "claim" and (now - (r.claimedAt or 0)) > Matchmaker.CLAIM_STALE
			if r.state ~= "open" and not stale then
				return nil
			end
			if not Matchmaker.shouldLaunch(r, now) then
				return nil
			end
			r.state = "claim"
			r.host = SERVER_ID
			r.claimedAt = now
			won = true
			claimed = Matchmaker.count(r)
			phantoms = Matchmaker.phantoms(r)
			return r
		end, Matchmaker.RECORD_TTL)
	end)
	if not ok then
		report("claim " .. key, err)
		return false, 0, 0
	end
	return won, claimed, phantoms
end

-- ------------------------------------------------------------------ tick ---

local lastBeat = 0

-- A joiner must not wait up to PUSH seconds for an idle board to be pushed
-- again, so they get the last one immediately and the periodic push stays rare.
Players.PlayerAdded:Connect(function(player)
	if lastWire then
		task.defer(function()
			LobbyRE:FireClient(player, "board", lastWire)
		end)
	end
end)

-- MONEY ON THE PAGE. Off the profile's own ready callback rather than off
-- PlayerAdded, because the two are seconds apart: a player arriving from a
-- finished match has to wait for that match server to let go of the session
-- lock before their balance -- with the round they just played in it -- can be
-- read. Firing on PlayerAdded would reliably print the balance from BEFORE the
-- match they are walking out of.
--
-- ConquestServer calls Data.install on this server too, so the profiles are
-- already being loaded; this only asks to be told.
Data.onReady(function(player, profile)
	LobbyRE:FireClient(player, "money", tonumber(profile.money) or 0)
	-- ...and what they own, which travels with the balance because the shop
	-- cannot draw a price without both of them.
	sendPatterns(player)
	-- ...and which room dials their passes open. Spawned: the ownership check
	-- is a web call on a cold cache, and nothing above should wait on it.
	task.spawn(sendPasses, player)
end)

-- A ROBUX PURCHASE LANDING ON THIS SERVER repaints the page the same way a
-- Money purchase does. The hook fires after the receipt is durable, for every
-- product; a rename's grant has its own push (ConquestShop) and an extra
-- patterns push for it is one table on one wire. The module is the same
-- instance ConquestServer armed -- server Scripts share a require cache --
-- so this registers on the live handler and installs nothing.
Monetization.onGranted(function(player, entry)
	-- A PASS arrives here too (2026-09-11), once Monetization has re-asked the
	-- site and it said yes -- and a pass is room dials, not the shop.
	if entry and entry.kind == "pass" then
		sendPasses(player)
		return
	end
	sendPatterns(player)
end)

-- ...EXCEPT THE ONE PASS THAT GRANTS (2026-09-16). VIP's 10,000 Money and its
-- Rainbow pattern land in the profile a moment AFTER the branch above runs, so
-- that branch has nothing new to draw and the buyer watched the room dials
-- open while the balance and the swatch stayed exactly as they were -- two of
-- the four things they paid 120 Robux for, invisible until they happened to
-- rejoin. This fires once settleVip has flushed, which is the first moment the
-- page can be shown what was really banked.
Monetization.onVipSettled(function(player)
	LobbyRE:FireClient(player, "money", Data.money(player))
	sendPatterns(player)
end)

-- ------------------------------------------------------------- follow ----
--
-- A FRIEND WHO PRESSED JOIN ON SOMEBODY IN A MATCH LANDS HERE INSTEAD. A match
-- is a reserved server and the platform's own join cannot enter one: it falls
-- back to an ordinary public server of this place -- a lobby -- and leaves the
-- followed user's id on `Player.FollowUserId`. Left alone, that person sits on
-- the page and is matchmade with strangers, the one outcome nobody pressing
-- JOIN on a friend wanted. So the lobby finishes the join itself: every match
-- server publishes where each of its people is (Matchmaker.WHERE_STORE,
-- ConquestServer.publishWhere), this looks the friend up and teleports the
-- follower in with the same access code, and on the far side ConquestServer
-- hands them a bot beside their friend (followTakeover) -- or, before the war
-- has started, a seat of their own.
--
-- A FIRST-EVER VISIT THAT ARRIVED BY JOIN SKIPS THE LESSON. The tutorial gate
-- below waits on `following` -- "pending" while the lookup runs, "sent" once
-- the teleport went out -- and stands down when the follower was sent, rather
-- than tearing them away from the friend they came for. Their profile keeps
-- the flag unset, so the lesson runs on their next visit alone.
local function followFriend(player: Player)
	local friendId = player.FollowUserId
	if friendId <= 0 then
		return
	end
	-- SOMEBODY WALKING BACK OUT OF ONE OF OUR OWN TELEPORTS is not a follow,
	-- whatever the platform left on FollowUserId: a match server that had no
	-- bot to hand them bounces them here (`bounced`), and sending them straight
	-- back would be a loop. Our teleports always carry the visit (`cq`).
	local okJoin, data = pcall(function()
		return player:GetJoinData().TeleportData
	end)
	if okJoin and type(data) == "table" and data.cq ~= nil then
		return
	end
	followState(player, "looking")
	following[player.UserId] = "pending"
	local outcome = "nowhere"
	local ok, entry = pcall(function()
		return whereStore:GetAsync(tostring(friendId))
	end)
	if not ok then
		outcome = "error"
		entry = nil
	end
	if Players:GetPlayerByUserId(friendId) ~= nil then
		-- The platform already put them in the same server; nothing to finish.
		outcome = "here"
		entry = nil
	end
	-- NEW PLAYERS ONLY, FOR NOW (owner, 2026-09-18): somebody who has done the
	-- tutorial is not sent into a friend's running match. The profile answers,
	-- and it lands seconds after they do, so it is waited for -- but only once
	-- there is a match to send them to. The tutorial gate is waiting on
	-- `following` in the meantime, and `busy` keeps the two from racing.
	local newbie = false
	if type(entry) == "table" and entry.tutorial ~= true then
		if Data.wait(player, 10) ~= nil and player.Parent ~= nil then
			newbie = not Data.tutorialSeen(player)
			if not newbie then
				outcome = "veteran"
				toast(player, "Your friend is mid-match. Play a game and join them after.")
			end
		else
			outcome = "no profile"
		end
	end
	if type(entry) == "table" and type(entry.code) == "string" and entry.code ~= "" then
		if entry.tutorial == true then
			-- A tutorial is a match with one seat and a lesson on it -- not a
			-- place to drop a second person into.
			outcome = "tutorial"
			toast(player, "Your friend is in the tutorial -- they will be back on this page soon.")
		elseif newbie and player.Parent ~= nil and not busy[player.UserId] then
			busy[player.UserId] = true
			local options = Instance.new("TeleportOptions")
			options.ReservedServerAccessCode = entry.code
			options:SetTeleportData({
				-- Read per player on the far side (ConquestServer.followedUserId);
				-- the tags and the visit ride exactly as they do for a card.
				follow = friendId,
				tags = tagsFor({ player }),
				cq = Analytics.teleportData({ player }),
			})
			toast(player, "Joining your friend's game...")
			local sent = pcall(function()
				TeleportService:TeleportAsync(game.PlaceId, { player }, options)
			end)
			if not sent then
				task.wait(1)
				sent = player.Parent ~= nil and pcall(function()
					TeleportService:TeleportAsync(game.PlaceId, { player }, options)
				end)
			end
			if sent then
				outcome = "sent"
				Analytics.launched({ player }, "follow")
			else
				outcome = "failed"
				busy[player.UserId] = false
				Analytics.hopsCancelled({ player })
				toast(player, "Could not reach your friend's game.")
			end
		end
	end
	Analytics.event("follow_join", player, 1, { outcome = outcome })
	if outcome == "sent" then
		following[player.UserId] = "sent"
		followState(player, "sent")
	else
		following[player.UserId] = nil
		-- The page is theirs -- unless they are a newcomer, in which case the
		-- tutorial gate below is about to open the lesson and says so itself.
		if Data.isMemoryOnly() or (Data.isReady(player) and Data.tutorialSeen(player)) then
			followState(player, "stay")
		end
	end
end

-- BOUNCED BACK FROM A FULL MATCH: the match server found no bot to hand them
-- (ConquestServer, `leaveToLobby(player, true)`), so the lesson opens instead
-- -- the gate below does the opening; this only keeps the curtain up for it.
Players.PlayerAdded:Connect(function(player)
	local ok, data = pcall(function()
		return player:GetJoinData().TeleportData
	end)
	if ok and type(data) == "table" and data.bounced == true then
		followState(player, "tutorial")
	end
end)

Players.PlayerAdded:Connect(function(player)
	task.spawn(followFriend, player)
end)

-- A PLAYER'S FIRST EVER JOIN GOES STRAIGHT INTO THE TUTORIAL, and the page is
-- not consulted about it. Somebody who has never been here does not know what
-- a lobby card is or what CREATE LOBBY would create, and there is no longer a
-- button offering to explain -- LEARN TO PLAY came off the page when this went
-- in, because a door you are carried through does not also need advertising.
--
-- OFF THE PROFILE'S OWN READY CALLBACK, for the same reason the balance above
-- is: the answer lives in the profile, and the profile is seconds behind
-- PlayerAdded for anybody walking back out of a match server.
Data.onReady(function(player, _profile)
	-- A FOLLOWER IS ON THEIR WAY TO A FRIEND (followFriend): wait for that
	-- answer before deciding on a lesson, and stand down if it sent them.
	local waited = 0
	while following[player.UserId] == "pending" and waited < 8 do
		task.wait(0.25)
		waited += 0.25
	end
	if following[player.UserId] == "sent" then
		return
	end
	-- NO MEMORY, NO AUTO-LAUNCH. `Data.tutorialSeen` answers true for a player
	-- whose load failed, and memory-only is a Studio session with API access
	-- off, where every join looks like a first one. Either way this flag is
	-- the only thing standing between one automatic tutorial and an endless
	-- run of them, so a server that cannot remember having sent somebody must
	-- not send them. They still have /tutorial.
	if Data.isMemoryOnly() or Data.tutorialSeen(player) then
		followState(player, "stay")
		return
	end
	-- MARKED AND MADE DURABLE BEFORE THE TELEPORT, never after. The failure
	-- this ordering is against is a launch remembered nowhere: a player whose
	-- flag never landed comes back to the page and is sent into the lesson
	-- again, and again. The other direction costs them one tutorial they can
	-- replay by typing /tutorial, which is much the cheaper mistake.
	if not Data.markTutorialSeen(player) then
		followState(player, "stay")
		return
	end
	Data.flush(player)
	if player.Parent == nil then
		return
	end
	-- Through the same busy latch the page's own intents take. Loading a
	-- profile takes a moment, and a player who pressed JOIN inside it must not
	-- end up with two teleports racing to decide which game they were in.
	if busy[player.UserId] then
		followState(player, "stay")
		return
	end
	busy[player.UserId] = true
	-- A follower's curtain reads on from here: "no room beside your friend"
	-- when a match server bounced them (the attribute already says so), and
	-- plainly "first time here" when the friend was never in a match to join.
	-- For everyone else the attribute was never set and no curtain exists.
	local cur = player:GetAttribute(FOLLOW_ATTR)
	if cur ~= nil and cur ~= "tutorial" then
		followState(player, "first")
	end
	Analytics.tutorialEntered(player, "auto")
	toast(player, "First time here -- opening the tutorial...")
	local ok = pcall(startTutorial, player)
	busy[player.UserId] = false
	if not ok then
		followState(player, "stay")
		toast(player, "Could not open the tutorial. Try again.")
	end
end)

local function tick()
	local now = os.time()
	local board = readBoard()
	if not board then
		-- The store said no. Touch nothing: the clients keep the last board
		-- and count it down themselves, the heartbeat goes out on the next
		-- tick that can read, and nothing is minted over a board we cannot
		-- see. See readBoard.
		return
	end
	-- SIZE FIRST, MINT SECOND. The slots past what the hour justifies are
	-- left alone here and retire at their next empty rollover below; a slot
	-- the hour wants back is minted over its tombstone.
	liveSlots = sizeBoard()
	for i = 1, liveSlots do
		ensureSlot(i, board)
	end

	-- 1. Show it. The press paths have usually pushed this already; this is
	--    the catch-up for everything a press here did NOT cause -- another
	--    server's joins, a prune, a slot resetting between rounds.
	boardCache = board
	pushBoard(false)

	-- 2. Heartbeat + prune, but only for slots we actually hold people in.
	local beat = (os.clock() - lastBeat) >= Matchmaker.HEARTBEAT
	if beat then
		lastBeat = os.clock()
	end

	for _, slot in Matchmaker.SLOTS do
		local rec = board[slot.key]
		-- A tombstone is nobody's lobby: no heartbeat, no launch, no rollover.
		-- It expires with its TTL or is minted over (ensureSlot).
		if rec and rec.state ~= "retired" then
			local held = #myPlayersIn(slot.key) > 0

			if beat and held then
				commit(slot.key, rec.id, function(r)
					local entry = Matchmaker.entryFor(r, SERVER_ID)
					if not entry then
						-- Our entry is GONE while we still hold members: a
						-- pruning pass beat our heartbeat, or a join landed
						-- while another server's stale copy of us was being
						-- swept. Re-create it rather than leaving the player
						-- believing they are queued for a lobby that has never
						-- heard of them.
						if r.state ~= "open" then
							return false
						end
						entry = { j = SERVER_ID, t = os.time(), u = {} }
						table.insert(r.servers, entry)
					end
					-- Reconcile against who is actually still here. A player
					-- who left the SERVER is removed by PlayerRemoving, but a
					-- crash-and-restart of this script would not be, so the
					-- heartbeat rewrites the list from the truth.
					local live = {}
					for userId, k in mine do
						if k == slot.key and Players:GetPlayerByUserId(userId) then
							table.insert(live, userId)
						end
					end
					-- Never let a re-created entry push the lobby over its
					-- cap -- phantom seats included, because they are part of
					-- what the card has been promising all along.
					local others = Matchmaker.count(r)
						- #(entry :: Matchmaker.ServerEntry).u
						+ Matchmaker.phantoms(r)
					while #live > math.max(0, r.cap - others) do
						table.remove(live)
					end
					;(entry :: Matchmaker.ServerEntry).u = live
					;(entry :: Matchmaker.ServerEntry).t = os.time()
					Matchmaker.prune(r, os.time())
					return true
				end)
			end

			-- Housekeeping, and it is not cosmetic. Pruning only ever ran
			-- inside a write, and a slot whose members ALL belonged to servers
			-- that have since died gets no writes at all -- so the ghosts would
			-- sit there for the record's whole 15-minute TTL, and once its
			-- deadline passed every server would retry a claim it can never win
			-- (the transform prunes, the count drops to zero, shouldLaunch goes
			-- false, the update cancels, nothing is saved, repeat next second).
			-- Prune the local copy first, which is free, and only write when
			-- there is genuinely something to clean.
			if Matchmaker.prune(rec, now) then
				commit(slot.key, rec.id, function(r)
					return Matchmaker.prune(r, os.time())
				end)
			end

			if rec.state == "open" or rec.state == "claim" then
				if Matchmaker.shouldLaunch(rec, now) then
					local won, claimed, phantoms = tryClaim(rec, slot.key, now)
					if won then
						rec.state = "claim"
						launch(rec, slot.key, claimed, phantoms)
					end
				elseif
					rec.state == "open"
					and Matchmaker.count(rec) == 0
					and now >= rec.deadline
				then
					-- THE CLOCK RAN OUT ON AN EMPTY LOBBY. It cannot launch --
					-- `shouldLaunch` refuses a roster of nobody, which is what
					-- stops three idle slots reserving a match server every
					-- two minutes forever -- so instead it ROLLS OVER: a new
					-- generation, a fresh two minutes, a freshly drawn map and
					-- mode and a new phantom count. That is the difference
					-- between an idle page that rotates and one that sits at
					-- 0:00 waiting to be looked at.
					--
					-- Every lobby server races this and only one can win: the
					-- losers find a generation that is no longer theirs and
					-- write nothing. The conditions are re-tested INSIDE the
					-- transform against the stored record rather than against
					-- this copy, which is up to a second old and unpruned.
					local elsewhere = shownElsewhere(board, slot.key)
					-- OUTSIDE THE TRANSFORM, because it can read MemoryStore
					-- and a transform must not yield. Nil for slots 1-3.
					local want = wantFor(rec.slot, board, slot.key)
					local minted = nil
					local rolled = commit(slot.key, rec.id, function(r)
						if r.state ~= "open" then
							return false
						end
						Matchmaker.prune(r, os.time())
						if Matchmaker.count(r) > 0 or os.time() < r.deadline then
							return false
						end
						-- RETIRE, NOT RE-MINT, when the hour no longer wants
						-- this slot (2026-09-19). Only an EMPTY lobby at the end
						-- of its clock gets here, which is the one moment a slot
						-- can go without taking anybody's seat with it. The
						-- tombstone keeps the key so no server re-mints it, is
						-- hidden by the wire, and expires with its TTL; a slot
						-- the hour wants back is minted over it (ensureSlot).
						if r.slot > liveSlots then
							r.state = "retired"
							minted = nil
							return true
						end
						local fresh = Matchmaker.newRecord(r.slot, elsewhere, want)
						for k, v in fresh do
							(r :: any)[k] = v
						end
						minted = fresh
						return true
					end)
					-- TAKE THE NEW DRAW INTO THE LOCAL BOARD. Every slot after
					-- this one in the loop reads `board` to see what the others
					-- are showing, and without this it draws against the pair
					-- this card just STOPPED showing -- which is exactly how two
					-- cards ended up on the same map. It bit every two minutes
					-- while the three clocks ran in lockstep and all three slots
					-- rolled over inside one tick; the staggered deadlines make
					-- that rare, and this makes it impossible.
					if rolled and minted then
						board[slot.key] = minted
					elseif rolled then
						-- Retired: the local copy says so too, so the slots after
						-- this one stop drawing around a map nobody is showing.
						rec.state = "retired"
					end
				end
			elseif rec.state == "ready" then
				-- Somebody else reserved it. Send our own people after them.
				if held and rec.code ~= "" then
					sendToMatch(rec)
				end
				-- ...and once everyone has been sent -- or the hold has run
				-- out -- whoever is still looking resets the slot so the page
				-- has three open lobbies again. See Matchmaker.readyDone: the
				-- local copy decides whether to write; the STORED record, which
				-- is the one the other servers have been clearing their people
				-- out of, decides whether the write lands.
				if Matchmaker.readyDone(rec, now) then
					local elsewhere = shownElsewhere(board, slot.key)
					local want = wantFor(rec.slot, board, slot.key)
					local minted = nil
					local reset = commit(slot.key, rec.id, function(r)
						if r.state ~= "ready" or not Matchmaker.readyDone(r, os.time()) then
							return false
						end
						-- Everyone has been sent: the other moment a slot is
						-- empty, and so the other place it may retire.
						if r.slot > liveSlots then
							r.state = "retired"
							minted = nil
							return true
						end
						local fresh = Matchmaker.newRecord(r.slot, elsewhere, want)
						for k, v in fresh do
							(r :: any)[k] = v
						end
						minted = fresh
						return true
					end)
					-- Same reason as the rollover above: the slots after this one
					-- have to draw against the pair this card is showing NOW.
					if reset and minted then
						board[slot.key] = minted
					elseif reset then
						rec.state = "retired"
					end
				end
			end
		end
	end
end

task.spawn(function()
	while true do
		task.wait(Matchmaker.POLL)
		-- STOP once this session stops being a lobby. Only Studio can get here
		-- (`startLocally` flips the role in place), and without the break this
		-- server would keep polling the board all through the match it just
		-- started -- and could claim a SECOND lobby that nothing would ever run.
		if ReplicatedStorage:GetAttribute(Matchmaker.ROLE_ATTR) ~= "lobby" then
			print("[Matchmaker] this session is a match now -- lobby polling stopped.")
			break
		end
		-- An empty server costs the universe's MemoryStore quota nothing.
		if #Players:GetPlayers() > 0 then
			local ok, err = pcall(tick)
			if not ok then
				warn("[Matchmaker] tick error: " .. tostring(err))
			end
			-- Separate pcall: a private room that throws must not take the
			-- public board's poll down with it, and vice versa.
			local okRoom, errRoom = pcall(tickRooms)
			if not okRoom then
				warn("[Matchmaker] room tick error: " .. tostring(errRoom))
			end
			-- ...and the SEE ALL GAMES list, which is a third independent
			-- thing and does nothing at all unless somebody has the panel open.
			local okList, errList = pcall(tickPublic)
			if not okList then
				warn("[Matchmaker] public list error: " .. tostring(errList))
			end
			-- ...and the demand tally's batched write (see noteJoin), which
			-- is a fourth independent thing and usually has nothing to send.
			local okDemand, errDemand = pcall(flushDemand)
			if not okDemand then
				warn("[Matchmaker] demand flush error: " .. tostring(errDemand))
			end
		end
	end
end)

print("[Matchmaker] lobby server ready (" .. SERVER_ID .. ")")
