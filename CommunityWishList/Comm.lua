-- See docs/design.md for the Comm contract.
local _, ns = ...

local Comm = {}
Comm.__index = Comm
ns.Comm = Comm

function Comm.new(opts)
    return setmetatable({ prefix = opts.prefix, send = opts.send, now = opts.now,
        after = opts.after, tokens = 10, updated = opts.now(), mid = 0,
        high = {}, bulk = {}, incoming = {}, listeners = {} }, Comm)
end

local function schedule(self, delay)
    if self.scheduled then return end
    self.scheduled = true
    self.after(delay, function()
        self.scheduled = false
        self:Drain()
    end)
end

function Comm:Drain()
    if self.draining then return end
    self.draining = true
    local now = self.now()
    self.tokens = math.min(10, self.tokens + math.max(0, now - self.updated))
    self.updated = now
    while #self.high > 0 or #self.bulk > 0 do
        if self.retryAt and now < self.retryAt then
            schedule(self, self.retryAt - now)
            break
        end
        if self.tokens < 1 then
            schedule(self, 1 - self.tokens)
            break
        end
        local queue = #self.high > 0 and self.high or self.bulk
        local message = queue[1]
        self.tokens = self.tokens - 1
        local result = self.send(self.prefix, message.parts[message.next], message.channel, message.target)
        if result == 3 or result == 8 then
            self.retryAt = now + 1
            schedule(self, 1)
            break
        end
        self.retryAt = nil
        message.next = message.next + 1
        if message.next > #message.parts then table.remove(queue, 1) end
    end
    self.draining = false
end

function Comm:Send(text, channel, target, priority)
    if type(text) ~= "string" then return nil end
    local mid = tostring(self.mid + 1)
    local count, size = 1, 0
    while true do
        size = 255 - #(count .. "/" .. count .. "/" .. mid .. "|")
        if size <= 0 then return nil end
        local needed = math.max(1, math.ceil(#text / size))
        if needed == count then break end
        count = needed
        if count > 64 then return nil end
    end
    self.mid = self.mid + 1
    local parts = {}
    for i = 1, count do
        parts[i] = i .. "/" .. count .. "/" .. mid .. "|" .. text:sub((i - 1) * size + 1, i * size)
    end
    local queue = priority == "high" and self.high or self.bulk
    queue[#queue + 1] = { parts = parts, next = 1, channel = channel, target = target }
    self:Drain()
    return true
end

function Comm:OnMessage(fn)
    self.listeners[#self.listeners + 1] = fn
end

function Comm:Receive(prefix, text, channel, sender)
    local now = self.now()
    for name, messages in pairs(self.incoming) do
        for mid, message in pairs(messages) do
            if now - message.started >= 30 then messages[mid] = nil end
        end
        if not next(messages) then self.incoming[name] = nil end
    end
    if prefix ~= self.prefix or type(text) ~= "string" or #text > 255 or type(sender) ~= "string" then return end
    local i, n, mid, chunk = text:match("^(%d+)/(%d+)/(%d+)|(.*)$")
    i, n = tonumber(i), tonumber(n)
    if not i or not n or i < 1 or n < 1 or n > 64 or i > n or not tonumber(mid) or tonumber(mid) < 1 then return end
    local messages = self.incoming[sender] or {}
    self.incoming[sender] = messages
    local message = messages[mid]
    if message and (message.n ~= n or message.channel ~= channel) then return end
    if not message then
        message = { n = n, channel = channel, started = now, parts = {}, count = 0 }
        messages[mid] = message
    end
    if message.parts[i] then return end
    message.parts[i] = chunk
    message.count = message.count + 1
    if message.count == n then
        messages[mid] = nil
        if not next(messages) then self.incoming[sender] = nil end
        local body = table.concat(message.parts)
        for _, fn in ipairs(self.listeners) do fn(body, channel, sender) end
    end
end
