-- See docs/design.md for the Sync contract.
local _, ns = ...

local Sync = {}
Sync.__index = Sync
ns.Sync = Sync

local wishKeys = { id = "i", owner = "o", recipient = "r", item = "t", name = "n",
    qty = "q", note = "x", gold = "g", prio = "p", state = "s", v = "v", created = "c", modified = "m" }
local claimKeys = { id = "i", by = "b", qty = "q", state = "s", created = "c", sentAt = "t", receivedAt = "r" }

local function convert(value, keys, fromWire)
    local result = {}
    for long, short in pairs(keys) do
        if fromWire then result[long] = value[short] else result[short] = value[long] end
    end
    return result
end

function Sync.ToWire(wish)
    if type(wish) ~= "table" then return nil end
    local wire = convert(wish, wishKeys)
    if type(wish.audience) == "table" then wire.a = { g = wish.audience.guild, s = wish.audience.groups } end
    if type(wish.claims) == "table" then
        wire.h = {}
        for id, claim in pairs(wish.claims) do
            if type(claim) == "table" then wire.h[id] = convert(claim, claimKeys) end
        end
    end
    return wire
end

function Sync.FromWire(wire)
    if type(wire) ~= "table" then return nil end
    local wish = convert(wire, wishKeys, true)
    if type(wire.a) == "table" then wish.audience = { guild = wire.a.g, groups = wire.a.s } end
    if type(wire.h) == "table" then
        wish.claims = {}
        for id, claim in pairs(wire.h) do
            if type(claim) == "table" then wish.claims[id] = convert(claim, claimKeys, true) end
        end
    end
    return wish
end

local function included(self, wish)
    local guild = self.guild()
    return guild ~= nil and type(wish) == "table" and type(wish.audience) == "table" and wish.audience.guild == guild
end

local function digest(self)
    return self.store:Digest(function(wish) return included(self, wish) end)
end

local function send(self, message, priority)
    local text = ns.Codec.Serialize(message)
    if text then self.comm:Send(text, "GUILD", nil, priority or "bulk") end
end

local function sendWish(self, id, priority)
    local wish = self.store:Get(id)
    if included(self, wish) then send(self, { p = 1, k = "W", w = Sync.ToWire(wish) }, priority) end
end

local function later(self, delay, fn)
    local pending = { wishes = {}, requests = {} }
    self.pending[pending] = true
    self.after(delay, function()
        self.pending[pending] = nil
        fn(pending)
    end)
end

local function version(sig)
    if type(sig) ~= "string" then return nil end
    return tonumber(sig:match("^(%d+)%.%d+$"))
end

function Sync.new(opts)
    local self = setmetatable({ store = opts.store, comm = opts.comm, me = ns.FullName(opts.me),
        guild = opts.guild, now = opts.now, after = opts.after, random = opts.random, pending = {} }, Sync)
    self.comm:OnMessage(function(text, channel, sender) self:Receive(text, channel, sender) end)
    return self
end

function Sync:Start()
    if self.guild() then send(self, { p = 1, k = "H", d = digest(self) }) end
end

function Sync:OnLocalChange(wish)
    if included(self, wish) then send(self, { p = 1, k = "W", w = Sync.ToWire(wish) }, "high") end
end

function Sync:Receive(text, channel, sender)
    if channel ~= "GUILD" or type(sender) ~= "string" or ns.FullName(sender) == self.me or not self.guild() then return end
    sender = ns.FullName(sender)
    local message = ns.Codec.Deserialize(text)
    if type(message) ~= "table" or message.p ~= 1 then return end
    if message.k == "W" then
        local wish = Sync.FromWire(message.w)
        if not included(self, wish) then return end
        -- The received store computes the signature because merging can add claims the sender lacks.
        local received = ns.Store.new({ db = {}, now = self.now, guild = self.guild })
        if not received:Merge(wish) then return end
        local sig = received:Digest()[wish.id]
        for pending in pairs(self.pending) do
            pending.wishes[wish.id] = pending.wishes[wish.id] or {}
            pending.wishes[wish.id][sig] = true
        end
        self.store:Merge(wish)
    elseif message.k == "H" and type(message.d) == "table" then
        local mine, wishes, requests = digest(self), {}, {}
        for id, sig in pairs(mine) do
            local remote = message.d[id]
            if remote == nil or (version(remote) and version(remote) <= version(sig) and remote ~= sig) then wishes[id] = true end
        end
        for id, sig in pairs(message.d) do
            if type(id) == "string" and version(sig) and (not mine[id] or mine[id] ~= sig) then requests[id] = true end
        end
        later(self, self.random(0.5, 4), function(pending)
            local current = digest(self)
            for id in pairs(wishes) do
                if current[id] and not (pending.wishes[id] and pending.wishes[id][current[id]]) then sendWish(self, id) end
            end
            local ids = {}
            for id in pairs(requests) do
                if not pending.requests[id] and current[id] ~= message.d[id] then ids[#ids + 1] = id end
            end
            table.sort(ids)
            if #ids > 0 then send(self, { p = 1, k = "R", ids = ids }) end
        end)
    elseif message.k == "R" and type(message.ids) == "table" then
        for _, id in ipairs(message.ids) do
            if type(id) == "string" then
                for pending in pairs(self.pending) do pending.requests[id] = true end
                local wish = self.store:Get(id)
                if included(self, wish) then
                    local owner = wish.owner == self.me
                    later(self, owner and self.random(0, 0.5) or self.random(1, 4), function(pending)
                        if not pending.wishes[id] then sendWish(self, id) end
                    end)
                end
            end
        end
    end
end
