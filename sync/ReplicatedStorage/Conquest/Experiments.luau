--!strict
-- Experiments: which arm of a live A/B test an account is in.
--
-- Pure and shared: the client reads it to decide what to draw, the server reads
-- it to tag analytics, and both get the same answer from the userId alone, so
-- no remote carries the arm and a rejoin or a teleport lands on the same side.
--
-- THE DEAL IS A SALTED HASH, NOT `userId % n`. The tutorial map test dealt by
-- `userId % 3`; a second test on a plain modulus would sort the same accounts
-- together and the two results would be read through each other. A per-test
-- salt makes every test an independent coin flip.

local Experiments = {}

-- Studio / owner override for eyeballing an arm: set to an arm name to force
-- it for everyone, nil to deal normally. NEVER publish with this set.
Experiments.FORCE_PASS_LABEL = nil :: string?

-- THE PREVIEW (/shop1 = get, /shop2 = price; ConquestShopTestClient). Set on
-- ONE client at runtime and never replicated: it changes what that screen
-- draws, not which arm the server's analytics files the account under.
Experiments.previewPassLabel = nil :: string?

local function hash(salt: string, userId: number): number
	-- Kept under 2^31 every step, so the doubles stay exact.
	local h = 7
	local s = salt .. ":" .. tostring(math.floor(userId))
	for i = 1, #s do
		h = (h * 31 + string.byte(s, i)) % 2147483647
	end
	return h
end

-- THE PASS LABEL TEST (2026-10-04). Half of all accounts see the game pass's
-- real Robux price on its pill ("price"); the other half keep "GET", the
-- label shipped 2026-09-22 ("get"). Read it on the `passab_prompt` /
-- `passab_bought` custom events, broken down by `arm` (field 1).
Experiments.PASS_LABEL_ARMS = { "get", "price" }

function Experiments.passLabelArm(userId: number?): string
	if Experiments.previewPassLabel ~= nil then
		return Experiments.previewPassLabel
	end
	if Experiments.FORCE_PASS_LABEL ~= nil then
		return Experiments.FORCE_PASS_LABEL
	end
	if type(userId) ~= "number" or userId <= 0 then
		return "get"
	end
	return Experiments.PASS_LABEL_ARMS[(hash("passlabel", userId) % 2) + 1]
end

return Experiments
