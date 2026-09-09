---Bounded FIFO using head/tail indices to avoid shifting items on each pop.
Queue = {}
Queue.__index = Queue

---@return table
function Queue.new()
    return setmetatable({ items = {}, head = 1, tail = 0, size = 0, dropped = 0 }, Queue)
end

---@return number
function Queue:Size()
    return self.size
end

---Drops and counts the oldest item when the queue is full.
---@param value any
---@param maxSize number
---@return boolean added
---@return table|nil droppedItem
function Queue:Push(value, maxSize)
    local droppedItem
    while self.size >= maxSize do
        droppedItem = self:Pop()
        self.dropped += 1
    end

    self.tail += 1
    self.items[self.tail] = value
    self.size += 1
    return true, droppedItem
end

---@return any
function Queue:Pop()
    if self.size == 0 then return nil end

    local value = self.items[self.head]
    self.items[self.head] = nil
    self.head += 1
    self.size -= 1

    if self.size == 0 then
        self.head, self.tail = 1, 0
    elseif self.head > 512 and self.head > (self.tail / 2) then
        local compacted, index = {}, 0
        for cursor = self.head, self.tail do
            index += 1
            compacted[index] = self.items[cursor]
        end
        self.items, self.head, self.tail = compacted, 1, index
    end

    return value
end

---Removes up to limit items within maxBytes, using sizes recorded at enqueue.
---@param limit number
---@param maxBytes number
---@return table items
---@return number bytes
function Queue:PopBatch(limit, maxBytes)
    local batch, bytes = {}, 0

    while #batch < limit and self.size > 0 do
        local nextItem = self.items[self.head]
        local nextBytes = nextItem and nextItem.bytes or 0
        -- Take at least one item to avoid stalling; enqueue already checks its size.
        if #batch > 0 and (bytes + nextBytes) > maxBytes then break end
        batch[#batch + 1] = self:Pop()
        bytes += nextBytes
    end

    return batch, bytes
end

---@return number
function Queue:TakeDropped()
    local dropped = self.dropped
    self.dropped = 0
    return dropped
end
