local _, ns = ...

local ranks = { invited = 0, joined = 1, left = 2, removed = 3 }
local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
local Groups = {}
Groups.__index = Groups
ns.Groups = Groups

local function fullname(name)
    if type(name) ~= "string" or name == "" then return nil end
    return ns.FullName(name)
end

local function integer(n)
    return type(n) == "number" and n == n and n < math.huge and n >= 1 and n == math.floor(n)
end

local function groupName(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("[%z\1-\31\127]", ""):sub(1, 32)
    if name == "" then return nil end
    return name
end

local function notify(self, group)
    for _, fn in ipairs(self.listeners) do fn("group", group) end
end

function Groups.new(opts)
    opts = opts or {}
    local db = opts.db or {}
    db.groups = db.groups or {}
    db.seq = db.seq or {}
    return setmetatable({ db = db, me = fullname(opts.me), now = opts.now, random = opts.random or math.random, listeners = {} }, Groups)
end

function Groups:Create(name)
    name = groupName(name)
    if not self.me or not name then return nil, "invalid creator or name" end
    local key = {}
    for i = 1, 12 do
        local n = self.random()
        if type(n) ~= "number" or n ~= n or n < 0 or n >= 1 then return nil, "invalid random value" end
        local index = math.floor(n * #alphabet) + 1
        key[i] = alphabet:sub(index, index)
    end
    self.db.seq[self.me] = (self.db.seq[self.me] or 0) + 1
    local id = self.me .. ":" .. self.db.seq[self.me]
    local group = { id = id, name = name, creator = self.me, key = table.concat(key), v = 1,
        members = { [self.me] = { state = "joined", v = 1, by = self.me } } }
    self.db.groups[id] = group
    notify(self, group)
    return group
end

function Groups:Get(id)
    if type(id) ~= "string" then return nil end
    return self.db.groups[id]
end

function Groups:IsMember(id, name)
    local group = self:Get(id)
    name = name == nil and self.me or fullname(name)
    local member = group and name and group.members[name]
    return member ~= nil and member.state == "joined"
end

function Groups:Members(id)
    local group = self:Get(id)
    if not group then return nil, "group missing" end
    local result = {}
    for name, member in pairs(group.members) do
        if member.state == "joined" then result[#result + 1] = name end
    end
    table.sort(result)
    return result
end

function Groups:List()
    local result = {}
    for _, group in pairs(self.db.groups) do
        local member = self.me and group.members[self.me]
        if member and (member.state == "joined" or member.state == "invited") then result[#result + 1] = group end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

local function setMember(self, group, name, state)
    local old = group.members[name]
    group.members[name] = { state = state, v = old and old.v + 1 or 1, by = self.me }
    notify(self, group)
    return group
end

function Groups:Invite(id, name)
    local group = self:Get(id)
    name = fullname(name)
    if not group or not name or not self:IsMember(id, self.me) then return nil, "cannot invite" end
    local old = group.members[name]
    if old and (old.state == "joined" or old.state == "invited") then return nil, "already a member or invited" end
    local count = 0
    for _, member in pairs(group.members) do
        if member.state == "joined" or member.state == "invited" then count = count + 1 end
    end
    if count >= 40 then return nil, "group full" end
    return setMember(self, group, name, "invited")
end

function Groups:Accept(id)
    local group = self:Get(id)
    local member = group and self.me and group.members[self.me]
    if not member or member.state ~= "invited" then return nil, "not invited" end
    return setMember(self, group, self.me, "joined")
end

function Groups:Leave(id)
    local group = self:Get(id)
    local member = group and self.me and group.members[self.me]
    if not member or group.creator == self.me or (member.state ~= "joined" and member.state ~= "invited") then return nil, "cannot leave" end
    return setMember(self, group, self.me, "left")
end

function Groups:Remove(id, name)
    local group = self:Get(id)
    name = fullname(name)
    if not group or not name or group.creator ~= self.me or name == group.creator or not group.members[name] then return nil, "cannot remove" end
    group.v = group.v + 1
    return setMember(self, group, name, "removed")
end

function Groups:Rename(id, name)
    local group = self:Get(id)
    name = groupName(name)
    if not group or group.creator ~= self.me or not name then return nil, "cannot rename" end
    group.name = name
    group.v = group.v + 1
    notify(self, group)
    return group
end

function Groups:OnChange(fn)
    if type(fn) ~= "function" then return nil, "invalid listener" end
    self.listeners[#self.listeners + 1] = fn
    return true
end

local function cleanGroup(remote)
    if type(remote) ~= "table" or type(remote.id) ~= "string" or remote.id == "" or not fullname(remote.creator) or not integer(remote.v) or type(remote.members) ~= "table" then return nil end
    local creator, name = fullname(remote.creator), groupName(remote.name)
    if not name or remote.id:sub(1, #creator + 1) ~= creator .. ":" then return nil end
    local group = { id = remote.id, creator = creator, name = name, v = remote.v, members = {} }
    if type(remote.key) == "string" and #remote.key == 12 and remote.key:match("^[A-Za-z0-9]+$") then group.key = remote.key end
    local authors = {}
    for member in pairs(remote.members) do
        local normalized = fullname(member)
        if normalized then authors[normalized] = true end
    end
    for rawName, entry in pairs(remote.members) do
        local member = fullname(rawName)
        if member and type(entry) == "table" and type(entry.state) == "string" and ranks[entry.state] and integer(entry.v) then
            local by = fullname(entry.by)
            local valid = by and ((entry.state == "invited" and authors[by]) or
                ((entry.state == "joined" or entry.state == "left") and by == member) or
                (entry.state == "removed" and by == creator))
            if valid and (member ~= creator or entry.state == "joined") then
                local current = group.members[member]
                if not current or entry.v > current.v or (entry.v == current.v and ranks[entry.state] > ranks[current.state]) then
                    group.members[member] = { state = entry.state, v = entry.v, by = by }
                end
            end
        end
    end
    return group
end

function Groups:Merge(remote)
    local incoming = cleanGroup(remote)
    if not incoming then return false end
    local group = self.db.groups[incoming.id]
    if group and group.creator ~= incoming.creator then return false end
    if not group then
        self.db.groups[incoming.id] = incoming
        notify(self, incoming)
        return true
    end
    local changed = false
    -- A key-less G can arrive before the invite, so the invite's key must still land afterwards.
    if not group.key and incoming.key then group.key, changed = incoming.key, true end
    if incoming.v > group.v then group.name, group.v, changed = incoming.name, incoming.v, true end
    for name, entry in pairs(incoming.members) do
        local old = group.members[name]
        if not old or entry.v > old.v or (entry.v == old.v and ranks[entry.state] > ranks[old.state]) then
            group.members[name] = entry
            changed = true
        end
    end
    if changed then notify(self, group) end
    return changed
end

function Groups:Sig(id)
    local group = self:Get(id)
    if not group then return nil, "group missing" end
    local names, parts = {}, {}
    for name in pairs(group.members) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local member = group.members[name]
        parts[#parts + 1] = name .. "=" .. member.v .. "." .. ranks[member.state]
    end
    local text, hash = table.concat(parts, ","), 5381
    for i = 1, #text do hash = (hash * 33 + text:byte(i)) % 4294967296 end
    return group.v .. "." .. string.format("%.0f", hash)
end
