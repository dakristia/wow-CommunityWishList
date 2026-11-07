local T = CommunityWishList_Tests

local seed = 1
local function seeded()
    seed = (seed * 16807) % 2147483647
    return seed / 2147483647
end

local function newGroups(me, clock)
    return CommunityWishList.Groups.new{ db = {}, me = me, now = clock.now, random = seeded }
end

T.add("groups create invite accept leave and re-invite", function()
    local clock = T.fakeClock()
    local a, b = newGroups("Ann-Realm", clock), newGroups("Bob-Realm", clock)
    local events = {}
    a:OnChange(function(kind, group) events[#events + 1] = { kind, group.v } end)
    local g = assert(a:Create("Raid\nteam"))
    T.eq(g.id, "Ann-Realm:1")
    T.eq(g.name, "Raidteam")
    T.eq(#g.key, 12)
    T.check(g.key:match("^[A-Za-z0-9]+$"))
    T.check(a:IsMember(g.id, "Ann-Realm"))
    T.eq(a:Leave(g.id), nil)
    T.eq(a:Remove(g.id, "Ann-Realm"), nil)
    T.eq(b:Accept(g.id), nil)
    assert(a:Invite(g.id, "Bob-Realm"))
    T.eq(a:Invite(g.id, "Bob-Realm"), nil)
    T.check(b:Merge(g))
    T.eq(#b:List(), 1)
    T.eq(b:Invite(g.id, "Cara-Realm"), nil)
    assert(b:Accept(g.id))
    T.eq(b:Accept(g.id), nil)
    T.check(a:Merge(b:Get(g.id)))
    T.eq(a:Sig(g.id), b:Sig(g.id))
    T.eq(a:Members(g.id)[2], "Bob-Realm")
    assert(b:Invite(g.id, "Cara-Realm"))
    assert(b:Leave(g.id))
    T.eq(#b:List(), 0)
    a:Merge(b:Get(g.id))
    local old = b:Get(g.id).members["Bob-Realm"].v
    assert(a:Invite(g.id, "Bob-Realm"))
    T.eq(a:Get(g.id).members["Bob-Realm"].v, old + 1)
    b:Merge(a:Get(g.id))
    T.eq(b:Get(g.id).members["Bob-Realm"].state, "invited")
    assert(b:Leave(g.id))
    T.eq(b:Get(g.id).members["Bob-Realm"].state, "left")
    T.eq(events[1][1], "group")
end)

T.add("groups creator changes and capacity", function()
    local clock = T.fakeClock()
    local a, b = newGroups("Ann-Realm", clock), newGroups("Bob-Realm", clock)
    local g = assert(a:Create("Team"))
    assert(a:Invite(g.id, "Bob-Realm"))
    b:Merge(g)
    assert(b:Accept(g.id))
    T.eq(b:Rename(g.id, "Other"), nil)
    T.eq(b:Remove(g.id, "Ann-Realm"), nil)
    local before = g.v
    assert(a:Rename(g.id, "New"))
    T.eq(g.v, before + 1)
    local observed
    a:OnChange(function(_, group) observed = group.v end)
    assert(a:Remove(g.id, "Bob-Realm"))
    T.eq(observed, before + 2)
    T.eq(g.members["Bob-Realm"].state, "removed")
    assert(a:Invite(g.id, "Bob-Realm"))
    for i = 1, 38 do assert(a:Invite(g.id, "Member" .. i .. "-Realm")) end
    T.eq(a:Invite(g.id, "Extra-Realm"), nil)
end)

T.add("groups merge validates authors copies keys and resolves ties", function()
    local clock = T.fakeClock()
    local a, b = newGroups("Ann-Realm", clock), newGroups("Bob-Realm", clock)
    local g = assert(a:Create("Team"))
    assert(a:Invite(g.id, "Bob-Realm"))
    b:Merge(g)
    local bg = b:Get(g.id)
    T.check(bg ~= g and bg.members ~= g.members and bg.members["Bob-Realm"] ~= g.members["Bob-Realm"])
    local key = g.key
    bg.key = nil
    bg.members["Bob-Realm"] = { state = "joined", v = 1, by = "Bob-Realm" }
    T.check(a:Merge(bg))
    T.eq(g.members["Bob-Realm"].state, "joined")
    T.eq(g.key, key)
    bg.members["Bob-Realm"] = { state = "left", v = 10, by = "Ann-Realm" }
    bg.members["Cara-Realm"] = { state = "removed", v = 2, by = "Bob-Realm" }
    bg.members["Dan-Realm"] = { state = "invited", v = 1, by = "Nobody-Realm" }
    a:Merge(bg)
    T.eq(g.members["Bob-Realm"].state, "joined")
    T.eq(g.members["Cara-Realm"], nil)
    T.eq(g.members["Dan-Realm"], nil)
    b:Merge(g)
    bg.members["Bob-Realm"] = { state = "joined", v = 11, by = "Bob-Realm" }
    b:Merge(g)
    T.check(a:Sig(g.id) ~= b:Sig(g.id))
end)

T.add("group wish audience and shared sequence", function()
    local clock = T.fakeClock()
    local db = {}
    local groups = CommunityWishList.Groups.new{ db = db, me = "Ann-Realm", now = clock.now, random = seeded }
    local store = CommunityWishList.Store.new{ db = db, me = "Ann-Realm", now = clock.now,
        isMember = function(id) return groups:IsMember(id) end }
    local g = assert(groups:Create("Team"))
    local w = assert(store:AddWish{ name = "Herb", qty = 1, groups = { g.id, "missing" } })
    T.eq(w.id, "Ann-Realm:2")
    T.eq(w.audience.groups[g.id], true)
    T.eq(w.audience.groups.missing, nil)
    local missing, reason = store:AddWish{ name = "Herb", qty = 1, groups = { "missing" } }
    T.eq(missing, nil)
    T.eq(reason, "no audience")
end)
