--!strict
-- Conquest :: Numbers  (shared)
-- ONE formatter and ONE smoother for every figure the game puts on screen.
--
-- They used to live in two places -- HUD.formatCount and
-- NationLabels.formatTroops -- and disagreed: the same 5,432 troops read as
-- "5.4K" in the standings and "5.43K" on the map at the same instant. A
-- number the player is comparing between two panels has to be written the
-- same way in both, so both call this.

local Numbers = {}

-- UPSTREAM `renderNumber` (src/client/Utils.ts), band for band and decimal
-- for decimal. The bands were already right here; two things were not.
--
-- 1. It TRUNCATES, it does not round: `Math.floor(num / 10) / 100` for the
--    kilo band, so 5,439 reads "5.43K" and never "5.44K". A %.2f rounds it up
--    and disagrees with upstream on roughly half of all values.
-- 2. Negatives clamp to zero (`num = Math.max(num, 0)`), so a caller wanting
--    to show a loss must pass the magnitude and write its own sign.
--
-- The billions band exists because GOLD reaches it -- a MIRV is 25,000,000
-- and treasuries accumulate -- even though troops never can.
local function band(n: number, div: number, places: number, suffix: string): string
	local scale = 10 ^ places
	local v = math.floor(n / (div / scale)) / scale
	return string.format("%." .. places .. "f%s", v, suffix)
end

function Numbers.format(n: number): string
	if n < 0 or n ~= n then
		n = 0
	end
	if n >= 10000000000 then
		return band(n, 1000000000, 1, "B")
	elseif n >= 1000000000 then
		return band(n, 1000000000, 2, "B")
	elseif n >= 10000000 then
		return band(n, 1000000, 1, "M")
	elseif n >= 1000000 then
		return band(n, 1000000, 2, "M")
	elseif n >= 100000 then
		return string.format("%dK", math.floor(n / 1000))
	elseif n >= 10000 then
		return band(n, 1000, 1, "K")
	elseif n >= 1000 then
		return band(n, 1000, 2, "K")
	end
	return string.format("%d", math.floor(n))
end

-- TROOPS ARE SHOWN AT A TENTH OF THEIR INTERNAL VALUE. Upstream's
-- `renderTroops(t) = renderNumber(t / 10)` (src/client/Utils.ts), and every
-- troop quantity on screen goes through it: army, max army, income rate, the
-- figure on a nation's territory, the figure on an army in the field, and the
-- attack and boat labels. Gold, costs and TILE counts do NOT -- upstream
-- calls renderNumber raw for those, so they stay on Numbers.format.
--
-- The sim keeps full-resolution troops; only the display divides. Conquest's
-- internal figures already matched upstream exactly, so this one factor was
-- the entire discrepancy: an army upstream shows as 67.6K was reading 676K.
function Numbers.formatTroops(n: number): string
	return Numbers.format(n / 10)
end

-- Exponential approach, written against dt rather than per frame, so the
-- same call settles in the same wall-clock time at 30fps and at 144.
--
-- Snaps once it is within a thousandth of the way there. Without that a
-- tweened counter never actually arrives, and the last digit sits one off
-- the true value indefinitely -- which is worse than not tweening at all,
-- because the number is then quietly WRONG rather than merely late.
function Numbers.approach(shown: number, target: number, dt: number, rate: number): number
	if shown == target then
		return target
	end
	local next = shown + (target - shown) * (1 - math.exp(-dt * rate))
	if math.abs(target - next) <= math.max(0.001, math.abs(target) * 0.001) then
		return target
	end
	return next
end

return Numbers