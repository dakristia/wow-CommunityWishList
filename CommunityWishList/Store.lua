-- See docs/design.md for the Store contract.
local _, ns = ...

local ranks = { open = 0, released = 1, cancelled = 2, sent = 3, received = 4 }
local Store = {}
Store.__index = Store
ns.Store = Store

local function integer(n, min)
    return type(n) == "number" and n == n and n < math.huge and n >= min and n == math.floor(n)
end

local function fullname(name)
    if type(name) ~= "string" or name == "" then return nil end
    return ns.FullName(name)
end

local function notify(self, kind, wish, claim)
    for _, fn in ipairs(self.listeners) do fn(kind, wish, claim) end
end

function Store:IsMe(name)
    return type(name) == "string" and self.isMe(name) and true or false
end

function Store.new(opts)
    opts = opts or {}
    local db = opts.db or {}
    db.schema = db.schema or 1
    db.wishes = db.wishes or {}
    db.seq = db.seq or {}
    db.seen = db.seen or {}
    db.ui = db.ui or { point = "CENTER", x = 0, y = 0, tab = "wanted", minimap = { angle = 200 } }
    local me = fullname(opts.me)
    -- isMe also accepts the older key of this character ("Crayons-Realm" for "Crayons Bonk-Realm"), so records written before surnames were handled stay mine.
    local isMe = opts.isMe or function(name) return name == me end
    return setmetatable({ db = db, me = me, isMe = isMe, now = opts.now or time, guild = opts.guild or function() end, isMember = opts.isMember or function() return false end, listeners = {} }, Store)
end

local function nextId(self)
    self.db.seq[self.me] = (self.db.seq[self.me] or 0) + 1
    return self.me .. ":" .. self.db.seq[self.me]
end

local function fieldsFor(fields)
    if type(fields) ~= "table" then return nil, "invalid fields" end
    local result = {}
    if fields.qty ~= nil then
        if not integer(fields.qty, 1) then return nil, "invalid quantity" end
        result.qty = fields.qty
    end
    if fields.note ~= nil then
        if type(fields.note) ~= "string" then return nil, "invalid note" end
        result.note = fields.note:gsub("[%z\1-\31]", ""):sub(1, 120)
    end
    if fields.gold ~= nil then
        if not integer(fields.gold, 0) then return nil, "invalid gold" end
        result.gold = fields.gold
    end
    if fields.prio ~= nil then
        if not integer(fields.prio, 1) or fields.prio > 3 then return nil, "invalid priority" end
        result.prio = fields.prio
    end
    if fields.recipient ~= nil then
        result.recipient = fullname(fields.recipient)
        if not result.recipient then return nil, "invalid recipient" end
    end
    return result
end

function Store:AddWish(fields)
    local values, err = fieldsFor(fields)
    if not values then return nil, err end
    if not self.me or not values.qty then return nil, "invalid owner or quantity" end
    if type(fields.name) ~= "string" or fields.name == "" then return nil, "invalid name" end
    if fields.item ~= nil and not integer(fields.item, 1) then return nil, "invalid item" end
    if fields.guild ~= nil and type(fields.guild) ~= "boolean" then return nil, "invalid guild" end
    if fields.groups ~= nil and type(fields.groups) ~= "table" then return nil, "invalid groups" end
    local guild = fields.guild and self.guild() or nil
    local groups = {}
    for _, id in ipairs(fields.groups or {}) do
        if type(id) == "string" and id ~= "" and self.isMember(id) then groups[id] = true end
    end
    if not guild and not next(groups) then return nil, "no audience" end
    local now = self.now()
    local wish = { id = nextId(self), owner = self.me, recipient = values.recipient or self.me,
        item = fields.item, name = fields.name, qty = values.qty, note = values.note,
        gold = values.gold or 0, prio = values.prio or 2, audience = { guild = guild, groups = groups },
        state = "open", v = 1, created = now, modified = now, claims = {} }
    self.db.wishes[wish.id] = wish
    notify(self, "wish", wish)
    return wish
end

function Store:Get(id)
    if type(id) ~= "string" then return nil end
    return self.db.wishes[id]
end

local function owned(self, id)
    local wish = self:Get(id)
    if not wish or not self:IsMe(wish.owner) or wish.state == "deleted" then return nil, "not owner or wish missing" end
    return wish
end

local function bump(self, wish)
    wish.v = wish.v + 1
    wish.modified = self.now()
    notify(self, "wish", wish)
end

function Store:UpdateWish(id, fields)
    local wish, err = owned(self, id)
    if not wish then return nil, err end
    local values
    values, err = fieldsFor(fields)
    if not values then return nil, err end
    for key, value in pairs(values) do wish[key] = value end
    bump(self, wish)
    self:AutoClose(wish)
    return wish
end

function Store:CloseWish(id)
    local wish, err = owned(self, id)
    if not wish then return nil, err end
    if wish.state ~= "open" then return nil, "wish is not open" end
    wish.state = "closed"
    bump(self, wish)
    return wish
end

function Store:DeleteWish(id)
    local wish, err = owned(self, id)
    if not wish then return nil, err end
    -- The tombstone keeps its audience, because Sync only passes a wish on to members of its audience.
    wish = { id = wish.id, owner = wish.owner, audience = wish.audience, state = "deleted", v = wish.v + 1, modified = self.now() }
    self.db.wishes[id] = wish
    notify(self, "wish", wish)
    return wish
end

function Store:SentQty(wish)
    local total = 0
    if type(wish) ~= "table" then return 0 end
    for _, claim in pairs(wish.claims or {}) do
        if claim.state == "sent" or claim.state == "received" then total = total + claim.qty end
    end
    return total
end

function Store:ClaimedQty(wish)
    local total = 0
    if type(wish) ~= "table" then return 0 end
    for _, claim in pairs(wish.claims or {}) do
        if claim.state == "open" or claim.state == "sent" or claim.state == "received" then total = total + claim.qty end
    end
    return total
end

function Store:Remaining(wish)
    if type(wish) ~= "table" or type(wish.qty) ~= "number" then return 0 end
    return math.max(0, wish.qty - self:ClaimedQty(wish))
end

function Store:AutoClose(wish)
    if self:IsMe(wish.owner) and wish.state == "open" and wish.qty and self:SentQty(wish) >= wish.qty then
        wish.state = "closed"
        bump(self, wish)
    end
end

function Store:Claim(id, qty)
    local wish = self:Get(id)
    if not wish or wish.state ~= "open" or not self.me or self:IsMe(wish.owner) then return nil, "cannot claim wish" end
    if not integer(qty, 1) or qty > self:Remaining(wish) then return nil, "invalid quantity" end
    local claim = { id = nextId(self), by = self.me, qty = qty, state = "open", created = self.now() }
    wish.claims[claim.id] = claim
    notify(self, "claim_new", wish, claim)
    return claim, wish
end

local function transition(self, wishId, claimId, role, from, state)
    local wish = self:Get(wishId)
    local claim = wish and wish.claims and type(claimId) == "string" and wish.claims[claimId]
    if not claim or wish.state == "deleted" or claim.state ~= from or (role == "owner" and not self:IsMe(wish.owner)) or (role == "claimer" and not self:IsMe(claim.by)) then
        return nil, "invalid claim transition"
    end
    claim.state = state
    if state == "sent" then claim.sentAt = self.now() end
    if state == "received" then claim.receivedAt = self.now() end
    notify(self, "claim_state", wish, claim)
    self:AutoClose(wish)
    return claim, wish
end

function Store:CancelClaim(w, c) return transition(self, w, c, "claimer", "open", "cancelled") end
function Store:MarkSent(w, c) return transition(self, w, c, "claimer", "open", "sent") end
function Store:ReleaseClaim(w, c) return transition(self, w, c, "owner", "open", "released") end
function Store:MarkReceived(w, c) return transition(self, w, c, "owner", "sent", "received") end

function Store:List(filter)
    if filter ~= nil and type(filter) ~= "table" then return nil, "invalid filter" end
    filter = filter or {}
    local owner = filter.owner and fullname(filter.owner)
    local claimer = filter.claimer and fullname(filter.claimer)
    local ownerIsMe, claimerIsMe = owner and owner == self.me, claimer and claimer == self.me
    local list = {}
    for _, wish in pairs(self.db.wishes) do
        local matches = not filter.claimer
        if claimer then
            for _, claim in pairs(wish.claims or {}) do
                if claim.by == claimer or (claimerIsMe and self:IsMe(claim.by)) then matches = true end
            end
        end
        if matches and (not filter.owner or owner == wish.owner or (ownerIsMe and self:IsMe(wish.owner))) and (not filter.state or filter.state == wish.state) and (filter.includeDeleted or wish.state ~= "deleted") then
            list[#list + 1] = wish
        end
    end
    table.sort(list, function(a, b) if (a.created or 0) == (b.created or 0) then return a.id < b.id end return (a.created or 0) > (b.created or 0) end)
    return list
end

function Store:OnChange(fn)
    if type(fn) ~= "function" then return nil, "invalid listener" end
    self.listeners[#self.listeners + 1] = fn
    return true
end

local function cleanClaim(id, claim)
    if type(id) ~= "string" or type(claim) ~= "table" or claim.id ~= id or type(claim.by) ~= "string" or claim.by == "" or id:sub(1, #claim.by + 1) ~= claim.by .. ":" or not ranks[claim.state] or not integer(claim.qty, 1) or type(claim.created) ~= "number" then return nil end
    local copy = { id = id, by = fullname(claim.by), qty = claim.qty, state = claim.state, created = claim.created }
    if type(claim.sentAt) == "number" then copy.sentAt = claim.sentAt end
    if type(claim.receivedAt) == "number" then copy.receivedAt = claim.receivedAt end
    return copy
end

local function cleanWish(remote)
    if type(remote) ~= "table" or type(remote.id) ~= "string" or remote.id == "" or not fullname(remote.owner) or not integer(remote.v, 1) or (remote.state ~= "open" and remote.state ~= "closed" and remote.state ~= "deleted") or type(remote.modified) ~= "number" then return nil end
    local wish = { id = remote.id, owner = fullname(remote.owner), v = remote.v, state = remote.state, modified = remote.modified }
    wish.audience = { groups = {} }
    if type(remote.audience) == "table" then
        if type(remote.audience.guild) == "string" then wish.audience.guild = remote.audience.guild end
        if type(remote.audience.groups) == "table" then
            for k, v in pairs(remote.audience.groups) do
                if (type(k) == "string" or type(k) == "number") and (type(v) == "string" or type(v) == "boolean") then wish.audience.groups[k] = v end
            end
        end
    end
    if wish.state == "deleted" then return wish end
    if type(remote.name) ~= "string" or remote.name == "" or not integer(remote.qty, 1) or type(remote.created) ~= "number" then return nil end
    wish.name, wish.qty, wish.created = remote.name, remote.qty, remote.created
    wish.recipient = fullname(remote.recipient) or wish.owner
    wish.item = integer(remote.item, 1) and remote.item or nil
    wish.note = type(remote.note) == "string" and remote.note:gsub("[%z\1-\31]", ""):sub(1, 120) or nil
    wish.gold = integer(remote.gold, 0) and remote.gold or 0
    wish.prio = integer(remote.prio, 1) and remote.prio <= 3 and remote.prio or 2
    wish.claims = {}
    if type(remote.claims) == "table" then
        for id, claim in pairs(remote.claims) do
            local copy = cleanClaim(id, claim)
            if copy then wish.claims[id] = copy end
        end
    end
    return wish
end

function Store:Merge(remote)
    local incoming = cleanWish(remote)
    if not incoming then return false end
    local localWish = self.db.wishes[incoming.id]
    if localWish and (localWish.owner ~= incoming.owner or (localWish.state == "deleted" and incoming.v <= localWish.v)) then return false end
    if incoming.state == "deleted" then
        if localWish and incoming.v <= localWish.v then return false end
        self.db.wishes[incoming.id] = incoming
        notify(self, "wish", incoming)
        return true
    end
    local changed, body = false, false
    if not localWish or incoming.v > localWish.v then
        local claims = localWish and localWish.claims or {}
        incoming.claims, localWish = claims or {}, incoming
        self.db.wishes[incoming.id] = localWish
        changed, body = true, true
    end
    if localWish.state == "deleted" then return false end
    if body then notify(self, "wish", localWish) end
    local cleaned = cleanWish(remote)
    for id, claim in pairs(cleaned.claims) do
        local current = localWish.claims[id]
        if not current then
            localWish.claims[id] = claim
            changed = true
            notify(self, "claim_new", localWish, claim)
        else
            local stateChanged = ranks[claim.state] > ranks[current.state]
            if stateChanged then current.state = claim.state; changed = true end
            if not current.sentAt and claim.sentAt then current.sentAt = claim.sentAt; changed = true end
            if not current.receivedAt and claim.receivedAt then current.receivedAt = claim.receivedAt; changed = true end
            if stateChanged then notify(self, "claim_state", localWish, current) end
        end
    end
    self:AutoClose(localWish)
    return changed
end

function Store:Digest(predicate)
    if predicate ~= nil and type(predicate) ~= "function" then return nil, "invalid predicate" end
    local result = {}
    for id, wish in pairs(self.db.wishes) do
        if not predicate or predicate(wish) then
            local ids, parts = {}, {}
            for claimId in pairs(wish.claims or {}) do ids[#ids + 1] = claimId end
            table.sort(ids)
            for _, claimId in ipairs(ids) do parts[#parts + 1] = claimId .. "=" .. ranks[wish.claims[claimId].state] end
            local text, hash = table.concat(parts, ","), 5381
            for i = 1, #text do hash = (hash * 33 + text:byte(i)) % 4294967296 end
            result[id] = wish.v .. "." .. string.format("%.0f", hash)
        end
    end
    return result
end
