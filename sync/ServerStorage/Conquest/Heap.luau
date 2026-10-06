--!strict
-- Conquest :: Heap
-- Flat binary min-heap over two parallel arrays. An attack's frontier is a
-- priority queue of candidate tiles, popped cheapest-first, so this is the
-- hottest data structure in the sim -- hence no per-node tables.

local Heap = {}
Heap.__index = Heap

export type Heap = typeof(setmetatable(
	{} :: {
		values: { number },
		priorities: { number },
		count: number,
	},
	Heap
))

function Heap.new(): Heap
	return setmetatable({
		values = {},
		priorities = {},
		count = 0,
	}, Heap) :: any
end

function Heap.size(self: Heap): number
	return self.count
end

function Heap.clear(self: Heap)
	table.clear(self.values)
	table.clear(self.priorities)
	self.count = 0
end

-- The smallest priority in the heap without removing it. The frontier
-- stores ready TIMES, so callers need to ask "has anything come due?"
-- before deciding to spend budget.
function Heap.peek(self: Heap): number?
	if self.count == 0 then
		return nil
	end
	return self.priorities[1]
end

function Heap.push(self: Heap, value: number, priority: number)
	local values, priorities = self.values, self.priorities
	local i = self.count + 1
	self.count = i
	values[i] = value
	priorities[i] = priority

	-- sift up
	while i > 1 do
		local parent = i // 2
		if priorities[parent] <= priority then
			break
		end
		values[i] = values[parent]
		priorities[i] = priorities[parent]
		values[parent] = value
		priorities[parent] = priority
		i = parent
	end
end

-- Returns nil when empty.
function Heap.pop(self: Heap): number?
	local count = self.count
	if count == 0 then
		return nil
	end

	local values, priorities = self.values, self.priorities
	local top = values[1]

	local lastValue = values[count]
	local lastPriority = priorities[count]
	values[count] = nil
	priorities[count] = nil
	count -= 1
	self.count = count

	if count > 0 then
		local i = 1
		values[1] = lastValue
		priorities[1] = lastPriority

		-- sift down
		while true do
			local left = i * 2
			if left > count then
				break
			end
			local right = left + 1
			local child = left
			if right <= count and priorities[right] < priorities[left] then
				child = right
			end
			if priorities[child] >= lastPriority then
				break
			end
			values[i] = values[child]
			priorities[i] = priorities[child]
			values[child] = lastValue
			priorities[child] = lastPriority
			i = child
		end
	end

	return top
end

return Heap
