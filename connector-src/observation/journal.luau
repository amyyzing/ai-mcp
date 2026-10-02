-- Immutable, bounded event history. Cursors count all events, including evictions.
local Journal = {}
Journal.__index = Journal
local function Copy(value, depth)
    if type(value) ~= "table" then return value end
    assert((depth or 0) < 12, "Event nesting exceeds journal limit.")
    local result = {}
    for key, child in pairs(value) do result[key] = Copy(child, (depth or 0) + 1) end
    return result
end
function Journal.new(capacity, measure, maxBytes)
    return setmetatable({ capacity = capacity or 1000, maxBytes = maxBytes or 2000000,
        measure = measure, entries = {}, first = 1, last = 0, bytes = 0, dropped = 0 }, Journal)
end
function Journal:Push(kind, data, at)
    self.last += 1
    local ok, copied = pcall(Copy, data)
    local row = { sequence = self.last, kind = kind, atMonotonicMs = at, data = if ok then copied else { omitted = true } }
    local size = self.measure(row)
    if size > self.maxBytes then
        row.data = { omitted = true, reason = "event-byte-limit" }
        size = self.measure(row)
    end
    self.entries[self.last] = { row = row, size = size }
    self.bytes += size
    while self.last - self.first + 1 > self.capacity or self.bytes > self.maxBytes do
        self.bytes -= self.entries[self.first].size
        self.entries[self.first] = nil
        self.first += 1
        self.dropped += 1
    end
    return self.last
end
function Journal:Read(cursor, limit)
    cursor, limit = cursor or 0, limit or 50
    local rows = {}
    local start = math.max(cursor + 1, self.first)
    for index = start, math.min(self.last, start + limit - 1) do table.insert(rows, Copy(self.entries[index].row)) end
    return { events = rows, nextCursor = if #rows > 0 then rows[#rows].sequence else math.max(cursor, self.first - 1),
        latestCursor = self.last, dropped = self.dropped, gap = cursor < self.first - 1,
        received = self.last, retained = self.last - self.first + 1, bytes = self.bytes }
end
return Journal
