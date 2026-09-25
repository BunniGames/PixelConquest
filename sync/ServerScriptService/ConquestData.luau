--!strict
-- Conquest :: ConquestData  (server)
-- The persistence layer. Nothing in this game persisted between rounds before
-- this file existed, which is why MONETIZATION.txt puts it first in the build
-- order: names, purchases, progression and skins all need it, so the FIRST
-- monetised feature pays for the whole layer and the second and third are
-- nearly free.
--
-- IT IS NOT WIRED UP. Nothing calls into here yet. `Data.install()` is the one
-- line that turns it on (connects PlayerAdded / PlayerRemoving / BindToClose);
-- until something calls that, this module does nothing at all and cannot
-- affect a live round.
--
-- THE THREE THINGS THAT ARE EASY TO GET WRONG, and what is done about each:
--
-- 1. SESSION LOCKING. This place teleports players between a lobby server and
--    a reserved match server OF THE SAME PLACE, so the same profile is opened
--    twice within a second or two in the ordinary case. Without a lock the
--    lobby's autosave lands after the match server's load and silently rolls
--    back whatever was bought in between. The lock is a { job, t } stamp
--    written inside the same UpdateAsync that reads the profile, so acquiring
--    it is atomic; a lock older than LOCK_TTL is assumed to belong to a server
--    that crashed and is taken.
--
-- 2. UPDATEASYNC, NOT SETASYNC, for every write. SetAsync is last-write-wins,
--    which is exactly the wrong policy when the thing being written is a
--    purchase.
--
-- 3. STUDIO. DataStore calls THROW in Studio unless "Enable Studio Access to
--    API Services" is on, and a throw here would break every playtest for a
--    feature nobody is using yet. The first failure of that specific shape
--    flips the module into MEMORY-ONLY: everything works, nothing persists,
--    and it says so once in the output rather than erroring on every call.
--
-- WHAT A FAILED LOAD MEANS. `Data.get` returns nil, and every caller must
-- treat nil as "this player has no profile this session" -- play continues,
-- purchases return NotProcessedYet so Roblox retries later, and NOTHING is
-- written. The one thing never to do is fabricate a default profile after a
-- failed load: that is how a player's whole history gets overwritten with a
-- blank one.

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Data = {}

-- THE COSMETIC CATALOGUE, shared rather than server-side because the shop has
-- to draw from the same list the server enforces against. Nothing about a
-- pattern is secret; what has to be authoritative is who OWNS one, and that
-- lives in the profile below.
local Patterns = require(ReplicatedStorage:WaitForChild("Conquest"):WaitForChild("Patterns"))

-- THE VERSION LIVES IN THE STORE NAME, which is the same migration idiom
-- Matchmaker uses for its MemoryStore records: a breaking schema change bumps
-- the name, old servers keep talking to the old store until they die, and
-- there is never a moment where two shapes share one key. Bumping this
-- ABANDONS existing data -- it is for a shape change that cannot be migrated
-- in `migrate` below, not for adding a field.
local STORE_NAME = "ConquestPlayer_v1"

-- Additive changes go here instead: bump SCHEMA and teach `migrate` to fill
-- in whatever is new. This costs one read-modify-write per player per bump.
local SCHEMA = 1

-- Seconds a lock is believed. Long enough that an ordinary autosave gap never
-- looks stale, short enough that a crashed server does not strand a player for
-- a whole round. The heartbeat below refreshes it at a third of this.
local LOCK_TTL = 90
local AUTOSAVE = 30
-- How long a load will wait out someone else's live lock before giving up and
-- playing without persistence. Slightly over the TTL, so the common case of a
-- crashed server resolves itself inside one attempt.
local LOCK_WAIT = LOCK_TTL + 15
local LOCK_POLL = 3

local RETRIES = 4
local RETRY_BASE = 0.6

local store: DataStore? = nil
local memoryOnly = false
local warnedMemoryOnly = false

local profiles: { [Player]: any } = {}
local loading: { [Player]: boolean } = {}
local dirty: { [Player]: boolean } = {}
local installed = false
local readyCallbacks: { (Player, any) -> () } = {}

Data.counters = {
	loads = 0,
	loadFailures = 0,
	saves = 0,
	saveFailures = 0,
	lockSteals = 0,
	lockWaits = 0,
}

local JOB = game.JobId ~= "" and game.JobId or ("studio-" .. tostring(os.time()))

-- ================================================================= schema ==

local function defaultProfile(): any
	return {
		schema = SCHEMA,
		created = os.time(),
		-- Identity. `nationName` is the FILTERED string, never the raw one --
		-- see ConquestNames. nil means "use the Roblox username", which is
		-- what NationLabels draws today.
		nationName = nil,
		titleIndex = 1,
		-- Every name this account has ever worn, oldest first. The abuse path
		-- this closes: rename, do something reportable, rename again. It costs
		-- almost nothing and it is the first thing anyone moderating this will
		-- wish they had.
		nameHistory = {},
		renameTokens = 0,
		titleTokens = 0,
		-- THE FLAG a player flies beside their name, and the unlocks they hold
		-- for it. Same shape as patterns below: `flags` is what the account
		-- owns, `flag` is the one it is wearing, and the token is what a
		-- purchase banks until it is spent on one (ConquestMonetization).
		flags = {},
		flag = "",
		flagTokens = 0,
		-- Cached pass ownership, keyed by the pass KEY rather than its id, so
		-- re-creating a pass on the site does not orphan the record.
		passes = {},
		-- Lifetime count per developer-product key. Not currency: the tokens
		-- above are what gets spent. This is for analytics and support.
		purchases = {},
		-- PurchaseId -> when. The whole of ProcessReceipt's idempotency rests
		-- on this table; see recordReceipt for why it is pruned by an explicit
		-- order list rather than by iterating.
		receipts = {},
		receiptOrder = {},
		-- MONEY -- the between-rounds currency, paid at the end of every round
		-- by ConquestServer (see the Money module for what it pays for and how
		-- the rates were fitted). It is the first field in here that a PLAYER
		-- earns rather than buys, and the additive migration above is what
		-- carries it onto profiles written before it existed: a nil reads as
		-- zero for exactly one load and is then written as a real 0.
		money = 0,
		-- COSMETICS. The tile patterns this account owns, and the one it is
		-- wearing. Both are recorded by the pattern's KEY and never by its
		-- index in the catalogue, for the same reason `passes` is keyed by
		-- pass key rather than by product id: an index is a position in a
		-- list somebody will one day reorder, and the failure mode of that is
		-- handing a player a cosmetic they never bought.
		--
		-- `solid` is deliberately NOT recorded here. It is the default and
		-- everybody has it, so an empty table is the correct starting state
		-- rather than a table with one entry in it.
		patterns = {},
		pattern = "solid",
		-- ROBUX UNLOCKS (2026-09-08). `money2x` doubles every round's payout
		-- for good; `reviveTokens` is how many takeovers are in hand -- bought
		-- in a match, spent the moment one can be honoured, carried to the
		-- next round when it cannot. Both are written ONLY by a grant in
		-- ConquestMonetization and read back by the two functions under
		-- `robux flags` below; the additive migration fills them in on every
		-- profile written before they existed.
		money2x = false,
		reviveTokens = 0,
		-- VIP (2026-09-15). NOT a record of owning the pass -- `passes` above is
		-- that, written by Monetization.ownsPass off the site's own answer --
		-- but of the one-time grants that come WITH it having been paid: the
		-- Money and the Rainbow pattern. It has to be its own latch, because
		-- ownership is re-confirmed on every single join for the rest of the
		-- account's life, and a grant keyed on ownership alone would pay again
		-- every time a VIP walked in.
		vipCredited = false,
		-- THE SAME LATCH FOR EVERY OTHER PASS THAT PAYS SOMETHING (2026-09-22:
		-- the extra-buildings bundles carry 5,000 Money each), keyed by pass
		-- KEY. Written by Data.creditPass, read by Data.passCredited; the
		-- additive migration hands an empty table to older profiles.
		passCredited = {},
		-- PASSES BOUGHT WITH MONEY (2026-09-22, owner: "players can also buy it
		-- with the currency Money that they earn"), keyed by pass KEY. Its own
		-- table and not a write into `passes`, which is a cache of what the
		-- SITE said: this is the game's own record of a sale, and the one place
		-- a Money purchase is remembered. Monetization.ownsPass reads it ahead
		-- of the site, so every gate a pass opens opens for either way of
		-- buying it. The additive migration hands older profiles an empty one.
		moneyPasses = {},
		-- FREE REWARDS (2026-09-17): whether this account has taken the one
		-- grant that sheet gives -- the Ribbon skin and its Money. A latch and
		-- not a counter, because there is exactly one of it per account ever.
		--
		-- `false` IS ALSO THE RIGHT ANSWER FOR EVERY PROFILE THAT PREDATES IT,
		-- so this one is left to the additive loop in `migrate` rather than
		-- special-cased the way tutorialSeen is: an account that existed before
		-- the sheet did has not claimed it, and should be able to.
		freeReward = false,
		-- THE TUTORIAL FOUR (2026-09-12), keyed by product key: how many of
		-- each are in hand. Banked by a grant in ConquestMonetization, spent
		-- by ConquestServer.redeemBoost, and read through Data.boostTokens /
		-- Data.spendBoost below -- nothing else may touch it. An empty table
		-- is the right starting state for the same reason `patterns` is one:
		-- owning none of something is not a row.
		tutorialBoosts = {},
		-- HAS THIS ACCOUNT BEEN THROUGH THE TUTORIAL. Asked in exactly one
		-- place and for one purpose: a lobby server puts a player who has
		-- never been here into the lesson instead of onto the page. Set the
		-- moment that launch is committed and NOT when the track is finished
		-- -- a student who quits or is wiped out has still had their turn, and
		-- a flag that waited for a finish would put them back into the
		-- tutorial on every join for as long as they kept losing it. `false`
		-- is what a brand-new profile gets; see `migrate` for why a profile
		-- that already existed gets `true`.
		tutorialSeen = false,
		-- Lifetime. The last four are what the funnels bank here: seconds
		-- played (summed per SERVER, so a lobby wait and the round it led to
		-- both count), visits that actually ended rather than teleported,
		-- tutorials finished, and when they were last seen -- which is the one
		-- field that makes "is this a returning player" answerable from inside
		-- the game instead of only on the dashboard.
		stats = {
			matches = 0,
			wins = 0,
			tilesPeak = 0,
			playSeconds = 0,
			sessions = 0,
			tutorials = 0,
			lastSeen = 0,
			-- Which map their tutorial was dealt on ("us" | "europe" |
			-- "world"; empty until they enter one). Banked by
			-- ConquestAnalytics.tutorialArm for the map experiment, so a
			-- later retention pass can ask "who learned on which map" from
			-- inside the game rather than only on the dashboard.
			tutorialMap = "",
		},
		lock = nil,
	}
end

-- Additive-only. Anything that cannot be expressed as "fill in a missing
-- field" belongs in a STORE_NAME bump instead.
local function migrate(p: any): any
	if type(p) ~= "table" then
		return defaultProfile()
	end
	local base = defaultProfile()
	-- WHO HAS ALREADY HAD THEIR CHANCE. Filled HERE rather than by the
	-- additive loop below, which would hand every existing account the `false`
	-- out of `defaultProfile` and march the whole playerbase back through the
	-- tutorial on their next join. A profile that already exists predates the
	-- auto-launch; the auto-launch is for accounts that have never been here.
	if p.tutorialSeen == nil then
		p.tutorialSeen = true
	end
	for k, v in base do
		if p[k] == nil then
			p[k] = v
		end
	end
	if type(p.stats) ~= "table" then
		p.stats = base.stats
	else
		-- ADDITIVE INSIDE `stats` TOO. The loop above only fills TOP-LEVEL
		-- keys, so a counter added to stats after a profile was written would
		-- read nil on that profile forever -- and every one of them is read as
		-- `(tonumber(x) or 0) + 1`, which papers over exactly this and then
		-- writes the field anyway. Filling it here is what keeps the schema
		-- honest rather than implicit.
		for k, v in base.stats do
			if p.stats[k] == nil then
				p.stats[k] = v
			end
		end
	end
	p.schema = SCHEMA
	return p
end

-- ============================================================ store access ==

-- The specific Studio failure, told apart from a transient one by its message.
-- Getting this wrong in either direction is bad: treating a real outage as
-- "Studio" would silently stop saving in production, and treating Studio as an
-- outage would retry four times on every single call in every playtest.
local function isStudioApiError(err: string): boolean
	local e = string.lower(tostring(err))
	return string.find(e, "studio", 1, true) ~= nil
		and (string.find(e, "api", 1, true) ~= nil or string.find(e, "publish", 1, true) ~= nil)
end

local function goMemoryOnly(why: string)
	memoryOnly = true
	if not warnedMemoryOnly then
		warnedMemoryOnly = true
		warn(("[ConquestData] MEMORY ONLY -- nothing will persist. %s"):format(why))
	end
end

local function getStore(): DataStore?
	if memoryOnly then
		return nil
	end
	if store then
		return store
	end
	local ok, res = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		if isStudioApiError(res) then
			goMemoryOnly("Studio access to API services is off.")
		else
			warn("[ConquestData] GetDataStore failed: " .. tostring(res))
		end
		return nil
	end
	store = res
	return store
end

-- Wait for request budget before spending it. Without this a full server
-- joining at once burns the budget in one second and then every call queues
-- for minutes; with it the calls are merely slow. Bounded, because a budget
-- that never arrives must not hang a player's join forever.
local function awaitBudget(kind: Enum.DataStoreRequestType)
	for _ = 1, 30 do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(kind)
		end)
		if not ok or budget == nil or budget > 0 then
			return
		end
		task.wait(0.5)
	end
end

-- One retried DataStore call. Returns ok, value. Backoff is exponential with
-- jitter -- without the jitter, twenty players who joined together retry in
-- lockstep and rebuild the exact thundering herd the backoff was for.
local rng = Random.new()
local function attempt(kind: Enum.DataStoreRequestType, fn: () -> any): (boolean, any)
	local lastErr: any = nil
	for i = 1, RETRIES do
		if memoryOnly then
			return false, "memory-only"
		end
		awaitBudget(kind)
		local ok, res = pcall(fn)
		if ok then
			return true, res
		end
		lastErr = res
		if isStudioApiError(res) then
			goMemoryOnly("Studio access to API services is off.")
			return false, res
		end
		if i < RETRIES then
			task.wait(RETRY_BASE * (2 ^ (i - 1)) * (0.75 + rng:NextNumber() * 0.5))
		end
	end
	return false, lastErr
end

local function keyFor(userId: number): string
	return "u_" .. tostring(userId)
end

-- =================================================================== load ==

local function lockIsLive(lock: any): boolean
	return type(lock) == "table"
		and type(lock.t) == "number"
		and (os.time() - lock.t) < LOCK_TTL
end

-- Reads the profile AND takes the lock in one UpdateAsync, so there is no
-- window between "I saw it was free" and "I claimed it". Returns nil when
-- someone else holds a live lock, which the caller turns into a wait.
local function tryAcquire(ds: DataStore, key: string): (boolean, any, boolean)
	local blocked = false
	local ok, res = attempt(Enum.DataStoreRequestType.UpdateAsync, function()
		blocked = false
		return ds:UpdateAsync(key, function(old)
			local p = migrate(old)
			local lock = p.lock
			if lock ~= nil and lock.job ~= JOB and lockIsLive(lock) then
				blocked = true
				-- nil aborts the write. The profile is left exactly as it was.
				return nil
			end
			if lock ~= nil and lock.job ~= JOB then
				Data.counters.lockSteals += 1
			end
			p.lock = { job = JOB, t = os.time() }
			return p
		end)
	end)
	return ok, res, blocked
end

-- Loads `player`, taking the session lock. Yields. Safe to call twice: the
-- second call returns the already-loaded profile rather than re-reading.
function Data.load(player: Player): any
	if profiles[player] then
		return profiles[player]
	end
	if loading[player] then
		-- Someone else is mid-load. Wait for them rather than starting a second
		-- one, which would fight over the same lock with itself.
		local deadline = os.clock() + LOCK_WAIT + 10
		while loading[player] and os.clock() < deadline do
			task.wait(0.1)
		end
		return profiles[player]
	end

	loading[player] = true
	local finish = function(p: any?): any
		loading[player] = nil
		if p ~= nil and player.Parent ~= nil then
			profiles[player] = p
			Data.counters.loads += 1
			for _, cb in readyCallbacks do
				task.spawn(cb, player, p)
			end
		end
		return p
	end

	local ds = getStore()
	if ds == nil then
		-- Memory only. A fresh profile that will never be written anywhere is
		-- still the right thing in Studio: features work, nothing persists.
		if memoryOnly then
			return finish(defaultProfile())
		end
		Data.counters.loadFailures += 1
		return finish(nil)
	end

	local key = keyFor(player.UserId)
	local deadline = os.clock() + LOCK_WAIT
	while true do
		if player.Parent == nil then
			loading[player] = nil
			return nil
		end
		local ok, res, blocked = tryAcquire(ds, key)
		if ok and not blocked then
			return finish(migrate(res))
		end
		if not ok then
			if memoryOnly then
				return finish(defaultProfile())
			end
			Data.counters.loadFailures += 1
			warn(("[ConquestData] load failed for %s: %s"):format(player.Name, tostring(res)))
			return finish(nil)
		end
		-- Blocked by a live lock held elsewhere.
		if os.clock() >= deadline then
			Data.counters.loadFailures += 1
			warn(("[ConquestData] %s is locked by another server; playing without persistence."):format(player.Name))
			return finish(nil)
		end
		Data.counters.lockWaits += 1
		task.wait(LOCK_POLL)
	end
end

-- Non-yielding. nil means "not loaded, or the load failed" and MUST be
-- treated as "do not write anything for this player", never as "make a new
-- one" -- see the header.
function Data.get(player: Player): any
	return profiles[player]
end

function Data.isReady(player: Player): boolean
	return profiles[player] ~= nil
end

function Data.wait(player: Player, timeout: number?): any
	local deadline = os.clock() + (timeout or 10)
	while profiles[player] == nil and os.clock() < deadline do
		if player.Parent == nil then
			return nil
		end
		task.wait(0.1)
	end
	return profiles[player]
end

-- Called after every mutation. Cheap on purpose: the autosave loop is what
-- actually writes, so a hundred mutations in a round cost a hundred boolean
-- assignments and one write.
function Data.markDirty(player: Player)
	if profiles[player] then
		dirty[player] = true
	end
end

function Data.onReady(fn: (Player, any) -> ())
	table.insert(readyCallbacks, fn)
	-- Anyone already loaded when a listener registers still gets the call, so
	-- registration order does not decide correctness.
	for player, p in profiles do
		task.spawn(fn, player, p)
	end
end

-- =================================================================== save ==

-- The lock is re-checked INSIDE the transform: if this server lost the lock
-- while the round was running (a long hang, then a steal by the server the
-- player teleported to) then this write is stale and must not land.
local function writeProfile(ds: DataStore, key: string, p: any, release: boolean): boolean
	local abandoned = false
	local ok, err = attempt(Enum.DataStoreRequestType.UpdateAsync, function()
		abandoned = false
		return ds:UpdateAsync(key, function(old)
			if type(old) == "table" and old.lock ~= nil and old.lock.job ~= JOB and lockIsLive(old.lock) then
				abandoned = true
				return nil
			end
			local copy = table.clone(p)
			copy.lock = if release then nil else { job = JOB, t = os.time() }
			return copy
		end)
	end)
	if abandoned then
		warn("[ConquestData] discarded a stale save: the lock moved to another server.")
		return false
	end
	if not ok then
		Data.counters.saveFailures += 1
		warn("[ConquestData] save failed: " .. tostring(err))
		return false
	end
	Data.counters.saves += 1
	return true
end

-- Yields. `release` also drops the lock, which is what makes an immediate
-- rejoin (or a teleport into the match server) fast instead of waiting out the
-- TTL. Returns false when nothing was written -- callers that are granting a
-- purchase MUST check this.
function Data.save(player: Player, release: boolean?): boolean
	local p = profiles[player]
	if p == nil then
		return false
	end
	if memoryOnly then
		dirty[player] = nil
		return true
	end
	local ds = getStore()
	if ds == nil then
		return memoryOnly
	end
	local wrote = writeProfile(ds, keyFor(player.UserId), p, release == true)
	if wrote then
		dirty[player] = nil
	end
	return wrote
end

-- Save now, whether or not anything is marked dirty. This is the one
-- ProcessReceipt uses: a receipt is only safe to acknowledge once it is
-- durable, so it cannot wait for the autosave tick.
function Data.flush(player: Player): boolean
	return Data.save(player, false)
end

function Data.release(player: Player)
	local p = profiles[player]
	if p ~= nil then
		Data.save(player, true)
	end
	profiles[player] = nil
	dirty[player] = nil
	loading[player] = nil
end

-- ================================================================ receipts ==
--
-- Kept here rather than in ConquestMonetization because they are a property of
-- the STORED SHAPE: the pruning rule and the schema have to agree, and they
-- only stay in agreement if they live in the same file.

-- Roblox re-sends a receipt until the handler returns PurchaseGranted, and a
-- server restart in between means the retry arrives at a process that has no
-- memory of the first attempt. This table is that memory.
local RECEIPT_KEEP = 200

function Data.hasReceipt(p: any, purchaseId: string): boolean
	return p ~= nil and p.receipts ~= nil and p.receipts[purchaseId] ~= nil
end

-- Pruned by an explicit insertion-order list rather than by scanning for the
-- oldest timestamp: `receipts` is a dictionary, `next` order is undefined, and
-- an eviction that picks an arbitrary entry can evict the receipt that is
-- being retried right now and double-grant it.
function Data.recordReceipt(p: any, purchaseId: string)
	if p.receipts == nil then
		p.receipts = {}
	end
	if p.receiptOrder == nil then
		p.receiptOrder = {}
	end
	if p.receipts[purchaseId] ~= nil then
		return
	end
	p.receipts[purchaseId] = os.time()
	table.insert(p.receiptOrder, purchaseId)
	while #p.receiptOrder > RECEIPT_KEEP do
		local oldest = table.remove(p.receiptOrder, 1)
		if oldest ~= nil then
			p.receipts[oldest] = nil
		end
	end
end

-- Undo, for the one case that needs it: a grant applied in memory whose save
-- then failed. Leaving the receipt behind would make the retry a no-op and the
-- player would have paid for nothing.
function Data.forgetReceipt(p: any, purchaseId: string)
	if p == nil or p.receipts == nil then
		return
	end
	p.receipts[purchaseId] = nil
	if p.receiptOrder ~= nil then
		local n = #p.receiptOrder
		for i = n, 1, -1 do
			if p.receiptOrder[i] == purchaseId then
				table.remove(p.receiptOrder, i)
				break
			end
		end
	end
end

-- =================================================================== money ==
--
-- The ONE mutator for the earned balance, so the two rules about it live in
-- one place and cannot drift: it is a whole number, and it never goes down by
-- accident (a negative delta is a spend, and there is nothing to spend it on
-- yet, so it is refused rather than silently clamped).
--
-- Returns the new balance, or nil when there is no profile -- which is not an
-- error, it is a player whose load failed, and per the header the correct
-- response to that is to write NOTHING. The award is simply not banked; the
-- round still pays out on screen, because telling someone they earned nothing
-- when the DataStore is down is a worse lie than the one this avoids.
function Data.addMoney(player: Player, amount: number): number?
	local p = profiles[player]
	if p == nil then
		return nil
	end
	local delta = math.floor(tonumber(amount) or 0)
	if delta <= 0 then
		return tonumber(p.money) or 0
	end
	p.money = math.max(0, (tonumber(p.money) or 0) + delta)
	dirty[player] = true
	return p.money
end

-- THE ONE DEBIT. Kept apart from `addMoney` rather than folded into it as a
-- negative delta, because the two have genuinely different rules: a credit
-- clamps and always succeeds, and a spend must be ALL OR NOTHING -- a purchase
-- that half-charged is worse than one that failed outright. Writes nothing and
-- returns false when the balance will not cover it, or when there is no
-- profile at all (a failed load, which per the header means write nothing).
function Data.spendMoney(player: Player, amount: number): boolean
	local p = profiles[player]
	if p == nil then
		return false
	end
	local cost = math.floor(tonumber(amount) or 0)
	if cost < 0 then
		return false
	end
	local balance = tonumber(p.money) or 0
	if balance < cost then
		return false
	end
	p.money = balance - cost
	dirty[player] = true
	return true
end

function Data.money(player: Player): number
	local p = profiles[player]
	return p and (tonumber(p.money) or 0) or 0
end

-- ============================================================ robux flags ==
--
-- Two things a receipt can put on a profile. Read here so the rest of the
-- server never indexes the raw fields, and never fabricates an answer for a
-- player whose load failed -- a nil profile is "no", the same way it is "no
-- money" and "no patterns".

function Data.hasMoney2x(player: Player): boolean
	local p = profiles[player]
	return p ~= nil and p.money2x == true
end

-- ====================================================================== VIP ==
--
-- VIP'S ONE-TIME SETTLEMENT (2026-09-15). Whether an account OWNS the pass is
-- Monetization.ownsPass's question and is cached in `passes`; this is the
-- separate question of whether the grants that ride along with it have been
-- PAID, and the two are separate because the first is true on every join
-- forever after and the second must happen exactly once.
--
-- The amount and the pattern key are passed IN rather than read from Config
-- here, so this file keeps the one dependency it has always had (Patterns) and
-- the numbers stay in the one place the rest of the game reads them from.

function Data.vipCredited(player: Player): boolean
	local p = profiles[player]
	return p ~= nil and p.vipCredited == true
end

-- ALL OR NOTHING, AND IT LATCHES BEFORE IT PAYS. Returns false when there is
-- nothing to do -- no profile, or already settled -- so the caller can be
-- driven by "is this player VIP", which is true on every join, without ever
-- paying twice. The latch goes first for the same reason ProcessReceipt
-- records its receipt first: the step that DECIDES must not be able to run
-- twice while the step that pays is in flight, and nothing here yields
-- between the two.
--
-- THE CALLER MUST FLUSH, and must call `uncreditVip` if that flush fails. A
-- grant that is not durable is a grant that did not happen -- and here the
-- consequence is worse than losing it, because the latch would survive in
-- memory and refuse to pay it again.
function Data.creditVip(player: Player, money: number, patternKey: string): boolean
	local p = profiles[player]
	if p == nil or p.vipCredited == true then
		return false
	end
	p.vipCredited = true
	p.money = math.max(0, (tonumber(p.money) or 0) + math.floor(tonumber(money) or 0))
	if type(p.patterns) ~= "table" then
		p.patterns = {}
	end
	p.patterns[patternKey] = true
	dirty[player] = true
	return true
end

-- The rollback half, and the same shape ConquestMonetization's restore has: a
-- grant applied in memory whose save then failed must leave no trace at all,
-- or the retry on the next join sees the latch and never pays.
--
-- It does NOT un-equip a pattern the player had already chosen for themselves,
-- only one this grant put on.
function Data.uncreditVip(player: Player, money: number, patternKey: string)
	local p = profiles[player]
	if p == nil then
		return
	end
	p.vipCredited = false
	p.money = math.max(0, (tonumber(p.money) or 0) - math.floor(tonumber(money) or 0))
	if type(p.patterns) == "table" then
		p.patterns[patternKey] = nil
	end
	if p.pattern == patternKey then
		p.pattern = Patterns.DEFAULT_KEY
	end
	dirty[player] = true
end

-- ============================================================ pass grants ==
--
-- THE SAME LATCH FOR ANY OTHER PASS THAT PAYS SOMETHING ONCE (2026-09-22: the
-- extra-buildings bundles carry 5,000 Money each). One table keyed by the
-- pass KEY, for VIP's reasons: owning the pass is `passes`' question and is
-- true on every join; whether its grant has been PAID must be answered
-- exactly once. VIP keeps its own latch above because its grant carries a
-- pattern as well.

function Data.passCredited(player: Player, key: string): boolean
	local p = profiles[player]
	return p ~= nil and type(p.passCredited) == "table" and p.passCredited[key] == true
end

-- Latches first, pays second, nothing yields between -- creditVip's shape.
-- THE CALLER MUST FLUSH, and must call `uncreditPass` if that flush fails.
function Data.creditPass(player: Player, key: string, money: number): boolean
	local p = profiles[player]
	if p == nil then
		return false
	end
	if type(p.passCredited) ~= "table" then
		p.passCredited = {}
	end
	if p.passCredited[key] == true then
		return false
	end
	p.passCredited[key] = true
	p.money = math.max(0, (tonumber(p.money) or 0) + math.floor(tonumber(money) or 0))
	dirty[player] = true
	return true
end

-- The rollback half: a grant applied in memory whose save then failed must
-- leave no trace, or the retry on the next join sees the latch and never pays.
function Data.uncreditPass(player: Player, key: string, money: number)
	local p = profiles[player]
	if p == nil then
		return
	end
	if type(p.passCredited) == "table" then
		p.passCredited[key] = nil
	end
	p.money = math.max(0, (tonumber(p.money) or 0) - math.floor(tonumber(money) or 0))
	dirty[player] = true
end

-- ============================================================ money passes ==
--
-- A PASS BOUGHT WITH MONEY (2026-09-22). The sale is the game's own, so it is
-- recorded here and nowhere else: `moneyPasses[key]` is what
-- Monetization.ownsPass reads before it ever asks the site. ALL OR NOTHING,
-- like spendMoney -- the debit and the flag land together or not at all --
-- and the caller flushes and calls `unbuyMoneyPass` if that flush fails, the
-- same contract creditPass has.

function Data.ownsMoneyPass(player: Player, key: string): boolean
	local p = profiles[player]
	return p ~= nil and type(p.moneyPasses) == "table" and p.moneyPasses[key] == true
end

-- Returns ok, a reason a player can read, and the balance afterwards.
function Data.buyMoneyPass(player: Player, key: string, price: number): (boolean, string, number)
	local p = profiles[player]
	if p == nil then
		return false, "Your profile has not loaded yet.", 0
	end
	if type(p.moneyPasses) ~= "table" then
		p.moneyPasses = {}
	end
	local balance = tonumber(p.money) or 0
	if p.moneyPasses[key] == true then
		return false, "You already own that.", balance
	end
	local cost = math.floor(tonumber(price) or 0)
	if cost <= 0 then
		return false, "That is not for sale for Money.", balance
	end
	if not Data.spendMoney(player, cost) then
		return false, "Not enough Money.", balance
	end
	p.moneyPasses[key] = true
	dirty[player] = true
	return true, "", tonumber(p.money) or 0
end

-- The rollback for a purchase whose flush failed: the Money comes back and
-- the flag goes, so the player is exactly where they were before the press.
function Data.unbuyMoneyPass(player: Player, key: string, price: number)
	local p = profiles[player]
	if p == nil then
		return
	end
	if type(p.moneyPasses) == "table" then
		p.moneyPasses[key] = nil
	end
	p.money = math.max(0, (tonumber(p.money) or 0) + math.floor(tonumber(price) or 0))
	dirty[player] = true
end

-- =========================================================== free reward ==
--
-- THE ONE GRANT THE FREE REWARDS SHEET MAKES, and the same shape as
-- creditVip above because it has the same hazard: it must happen exactly
-- once, and the thing that decides is a latch on the profile.
--
-- WHAT IT IS NOT: a check that the player did the two steps. The favourite
-- is read on the CLIENT (there is no server-side way to ask -- see
-- LobbyClient) and the like cannot be read anywhere at all, so the steps are
-- the player's word. What the server owns is that the grant lands ONCE, and
-- that is what this enforces.
function Data.freeRewardClaimed(player: Player): boolean
	local p = profiles[player]
	return p ~= nil and p.freeReward == true
end

-- ALL OR NOTHING, AND IT LATCHES BEFORE IT PAYS -- see creditVip for why
-- that ordering is the whole safety of it. Returns false when there is
-- nothing to do (no profile, or already claimed), so the caller can be driven
-- by a button press without ever paying twice.
--
-- THE CALLER MUST FLUSH and must call `unclaimFreeReward` if that flush
-- fails: a grant that is not durable is a grant that did not happen, and here
-- the latch would survive in memory and refuse to pay it again.
--
-- IT DOES NOT EQUIP THE SKIN. buyPattern equips what it sells because a
-- purchase that does not put the thing on reads as a failure; this is a
-- reward taken from a sheet in the lobby, and silently replacing whatever
-- somebody chose to wear is not what they asked for.
function Data.claimFreeReward(player: Player, money: number, patternKey: string): boolean
	local p = profiles[player]
	if p == nil or p.freeReward == true then
		return false
	end
	p.freeReward = true
	p.money = math.max(0, (tonumber(p.money) or 0) + math.floor(tonumber(money) or 0))
	if type(p.patterns) ~= "table" then
		p.patterns = {}
	end
	if patternKey ~= "" then
		p.patterns[patternKey] = true
	end
	dirty[player] = true
	return true
end

-- The rollback half. A grant applied in memory whose save then failed must
-- leave no trace, or the next press sees the latch and never pays.
function Data.unclaimFreeReward(player: Player, money: number, patternKey: string)
	local p = profiles[player]
	if p == nil then
		return
	end
	p.freeReward = false
	p.money = math.max(0, (tonumber(p.money) or 0) - math.floor(tonumber(money) or 0))
	if type(p.patterns) == "table" and patternKey ~= "" then
		p.patterns[patternKey] = nil
	end
	-- ...and if they put it on in the meantime, take it back off: wearing a
	-- skin the profile no longer records is the one state patternKey refuses
	-- to return anyway.
	if p.pattern == patternKey then
		p.pattern = Patterns.DEFAULT_KEY
	end
	dirty[player] = true
end

function Data.reviveTokens(player: Player): number
	local p = profiles[player]
	if p == nil then
		return 0
	end
	return math.max(0, math.floor(tonumber(p.reviveTokens) or 0))
end

-- THE TUTORIAL FOUR (2026-09-12). One TABLE keyed by product key rather than
-- four more flat fields beside `reviveTokens`: they are bought, banked and
-- spent identically, and the set is the sort of thing that grows -- four
-- fields would have been four defaults, four readers and four spenders that
-- differ only in a string.
--
-- Counters, not flags: every one of them can honestly be bought twice, unlike
-- `money2x`. What stops a second purchase being wasted is the redeem refusing
-- before it spends (ConquestServer.redeemBoost), not the grant refusing to
-- bank it.
--
-- Read defensively because the field post-dates live profiles; the additive
-- migration fills it in, and a profile written before it existed still
-- answers 0 rather than erroring on a nil index.
function Data.boostTokens(player: Player, key: string): number
	local p = profiles[player]
	if p == nil or type(p.tutorialBoosts) ~= "table" then
		return 0
	end
	return math.max(0, math.floor(tonumber(p.tutorialBoosts[key]) or 0))
end

-- ALL OR NOTHING, like spendReviveToken: false and no write when there is
-- nothing in hand, so a refused redeem cannot cost the player a token.
function Data.spendBoost(player: Player, key: string): boolean
	local p = profiles[player]
	if p == nil or type(p.tutorialBoosts) ~= "table" then
		return false
	end
	local n = math.floor(tonumber(p.tutorialBoosts[key]) or 0)
	if n <= 0 then
		return false
	end
	p.tutorialBoosts[key] = n - 1
	dirty[player] = true
	return true
end

-- ALL OR NOTHING, like spendMoney: false and no write when there is nothing
-- in hand, or no profile at all.
function Data.spendReviveToken(player: Player): boolean
	local p = profiles[player]
	if p == nil then
		return false
	end
	local n = math.floor(tonumber(p.reviveTokens) or 0)
	if n <= 0 then
		return false
	end
	p.reviveTokens = n - 1
	dirty[player] = true
	return true
end

-- ============================================================== cosmetics ==
--
-- Tile patterns: the only thing Money has ever been able to buy. WHICH
-- patterns exist, what they cost and what they need lives in the shared
-- `Patterns` module, because the shop has to draw the same ladder the server
-- enforces. What lives here is the account's side of it, and the rule that
-- THE SERVER DECIDES: a client that sends "equip marble" without owning
-- marble is refused here and nowhere else.

-- Everything the shop needs to draw itself, in one read. `wins` comes off the
-- same lifetime stats the round settlement writes, which is what makes the
-- earned tier reachable at all.
function Data.patternState(player: Player): (any, string, number, number)
	local p = profiles[player]
	if p == nil then
		return nil, Patterns.DEFAULT_KEY, 0, 0
	end
	local stats = type(p.stats) == "table" and p.stats or {}
	return type(p.patterns) == "table" and p.patterns or {},
		Data.patternKey(player),
		tonumber(p.money) or 0,
		tonumber(stats.wins) or 0
end

-- The key this account is WEARING, validated on the way OUT rather than only
-- on the way in. A pattern retired from the catalogue, or one recorded before
-- its owner somehow lost it, must not leave this function: the renderer would
-- draw it perfectly happily and the player would be wearing something they do
-- not own.
function Data.patternKey(player: Player): string
	local p = profiles[player]
	if p == nil then
		return Patterns.DEFAULT_KEY
	end
	local key = type(p.pattern) == "string" and p.pattern or Patterns.DEFAULT_KEY
	if key == Patterns.DEFAULT_KEY then
		return key
	end
	if Patterns.byKey(key) == nil then
		return Patterns.DEFAULT_KEY
	end
	local owned = type(p.patterns) == "table" and p.patterns or nil
	if owned == nil or owned[key] ~= true then
		return Patterns.DEFAULT_KEY
	end
	return key
end

-- BUY AND EQUIP IN ONE CALL, in that order: a purchase that does not put the
-- thing on reads as a purchase that failed.
--
-- THE DEBIT GOES AHEAD OF THE GRANT, which is the same ordering ProcessReceipt
-- uses and for the same reason -- the step that can refuse runs before the
-- step that cannot. Both are table writes on a profile that is saved as a
-- whole, so there is no window in which a player is charged and ungranted.
--
-- Returns ok, a reason a player can read, and the balance afterwards.
function Data.buyPattern(player: Player, key: any): (boolean, string, number)
	local p = profiles[player]
	if p == nil then
		return false, "Your profile has not loaded yet.", 0
	end
	local def = type(key) == "string" and Patterns.byKey(key) or nil
	if def == nil then
		return false, "No such pattern.", tonumber(p.money) or 0
	end
	if type(p.patterns) ~= "table" then
		p.patterns = {}
	end
	local stats = type(p.stats) == "table" and p.stats or {}
	local money = tonumber(p.money) or 0
	local may, why = Patterns.mayBuy(def, p.patterns, money, tonumber(stats.wins) or 0)
	if not may then
		return false, why, money
	end
	-- An earned pattern costs nothing -- its tier's price is 0 -- and a spend
	-- of 0 succeeds without touching the balance, so the win gate above is the
	-- only thing standing in front of it.
	if not Data.spendMoney(player, Patterns.price(def)) then
		return false, "Not enough Money.", tonumber(p.money) or 0
	end
	p.patterns[def.key] = true
	p.pattern = def.key
	dirty[player] = true
	return true, "", tonumber(p.money) or 0
end

-- Equipping is free and reversible, so ownership is the only question.
function Data.equipPattern(player: Player, key: any): (boolean, string)
	local p = profiles[player]
	if p == nil then
		return false, "Your profile has not loaded yet."
	end
	if key == Patterns.DEFAULT_KEY then
		p.pattern = Patterns.DEFAULT_KEY
		dirty[player] = true
		return true, ""
	end
	local def = type(key) == "string" and Patterns.byKey(key) or nil
	if def == nil then
		return false, "No such pattern."
	end
	local owned = type(p.patterns) == "table" and p.patterns or nil
	if owned == nil or owned[def.key] ~= true then
		return false, "You do not own that pattern."
	end
	p.pattern = def.key
	dirty[player] = true
	return true, ""
end

-- =================================================================== flags ==
--
-- The account's side of the flag catalogue. What flags EXIST lives in the
-- shared `Flags` module, because the shop has to draw the same roster the
-- server enforces; what lives here is ownership, and the rule that THE SERVER
-- DECIDES. Required lazily rather than at the head of this file so the data
-- layer keeps working on a server that has no cosmetics loaded.
local Flags = require(game:GetService("ReplicatedStorage"):WaitForChild("Conquest"):WaitForChild("Flags"))

-- Everything the flag tab needs in order to draw itself, in one read.
function Data.flagState(player: Player): (any, string, number)
	local p = profiles[player]
	if p == nil then
		return nil, Flags.NONE, 0
	end
	return type(p.flags) == "table" and p.flags or {},
		Data.flagKey(player),
		tonumber(p.flagTokens) or 0
end

-- The flag this account is FLYING, validated on the way out as well as in: a
-- flag recorded before its owner somehow lost it must not leave this function.
function Data.flagKey(player: Player): string
	local p = profiles[player]
	if p == nil then
		return Flags.NONE
	end
	local id = type(p.flag) == "string" and p.flag or Flags.NONE
	if id == Flags.NONE or not Flags.has(id) then
		return Flags.NONE
	end
	local owned = type(p.flags) == "table" and p.flags or nil
	if owned == nil or owned[id] ~= true then
		return Flags.NONE
	end
	return id
end

-- SPENDS AN UNLOCK, not Money. The token is what the developer product grants
-- (see ConquestMonetization), and this is the only thing that spends one.
--
-- OWN AND FLY IN ONE CALL, in that order, for the reason Data.buyPattern gives:
-- a purchase that does not put the thing on reads as a purchase that failed.
function Data.buyFlag(player: Player, id: any): (boolean, string)
	local p = profiles[player]
	if p == nil then
		return false, "Your profile has not loaded yet."
	end
	if type(id) ~= "string" or not Flags.has(id) then
		return false, "No such flag."
	end
	if type(p.flags) ~= "table" then
		p.flags = {}
	end
	if p.flags[id] == true then
		-- Already owned, so this is a fly rather than a buy. Not an error: a
		-- second press of a card mid-round-trip must not cost a token.
		p.flag = id
		dirty[player] = true
		return true, ""
	end
	local tokens = tonumber(p.flagTokens) or 0
	if tokens <= 0 then
		return false, "You do not have a flag unlock."
	end
	-- The debit ahead of the grant, the same ordering ProcessReceipt uses: the
	-- step that can refuse runs before the step that cannot.
	p.flagTokens = tokens - 1
	p.flags[id] = true
	p.flag = id
	dirty[player] = true
	return true, ""
end

-- Flying is free and reversible, so ownership is the only question. The empty
-- string is a real value and means "no flag".
function Data.equipFlag(player: Player, id: any): (boolean, string)
	local p = profiles[player]
	if p == nil then
		return false, "Your profile has not loaded yet."
	end
	if id == Flags.NONE or id == nil then
		p.flag = Flags.NONE
		dirty[player] = true
		return true, ""
	end
	if type(id) ~= "string" or not Flags.has(id) then
		return false, "No such flag."
	end
	local owned = type(p.flags) == "table" and p.flags or nil
	if owned == nil or owned[id] ~= true then
		return false, "You do not own that flag."
	end
	p.flag = id
	dirty[player] = true
	return true, ""
end

-- ================================================================ tutorial ==
--
-- LATCHED, NEVER CLEARED. This answers "has this account ever been SENT into
-- the tutorial", and there is nothing that should un-answer it -- see the
-- field's own note in `defaultProfile` for why finishing is not the question.

-- Returns true when the flag actually MOVED, so a caller can tell "I am the
-- one launching them" from "somebody already did" without a second read.
function Data.markTutorialSeen(player: Player): boolean
	local p = profiles[player]
	if p == nil or p.tutorialSeen == true then
		return false
	end
	p.tutorialSeen = true
	dirty[player] = true
	return true
end

-- TRUE FOR A PLAYER WITH NO PROFILE, and that is the deliberate reading rather
-- than a missing nil check: per the header, a failed load means write nothing,
-- and this flag is the only thing standing between one automatic tutorial and
-- an endless run of them. A session that cannot remember having sent somebody
-- must not send them.
function Data.tutorialSeen(player: Player): boolean
	local p = profiles[player]
	return p == nil or p.tutorialSeen == true
end

-- ================================================================ install ==

function Data.isMemoryOnly(): boolean
	return memoryOnly
end

-- THE ONE LINE THAT TURNS THIS ON. Idempotent, so a second caller (or a
-- reloaded script during a Studio session) cannot end up with two autosave
-- loops writing over each other.
function Data.install()
	if installed then
		return
	end
	installed = true

	for _, player in Players:GetPlayers() do
		task.spawn(Data.load, player)
	end
	Players.PlayerAdded:Connect(function(player)
		task.spawn(Data.load, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		Data.release(player)
	end)

	task.spawn(function()
		while true do
			task.wait(AUTOSAVE)
			for player, _ in profiles do
				if player.Parent ~= nil then
					-- The heartbeat and the save are the same write: a profile
					-- with nothing to save still has to refresh its lock, or a
					-- quiet player loses it after LOCK_TTL and the next write
					-- is discarded as stale.
					if dirty[player] then
						Data.save(player, false)
					else
						local p = profiles[player]
						if p ~= nil and p.lock ~= nil and (os.time() - p.lock.t) > (LOCK_TTL / 3) then
							Data.save(player, false)
						end
					end
					task.wait(0.1)
				end
			end
		end
	end)

	-- BindToClose gets roughly 30 seconds. Saves run in parallel and the join
	-- below is bounded, because a shutdown that overruns is killed outright and
	-- takes every remaining save with it.
	game:BindToClose(function()
		if RunService:IsStudio() and memoryOnly then
			return
		end
		local pending = 0
		for player, _ in profiles do
			pending += 1
			task.spawn(function()
				Data.release(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return Data
