local T = CommunityWishList_Tests
local ns = CommunityWishList
local realm = ns.FullName("x"):match("%-(.*)$")

-- Replaces globals (or ns fields) for one test and puts every one of them back afterwards.
local function stubbed(target, values, fn)
    local saved = {}
    for key in pairs(values) do saved[key] = target[key] end
    for key, value in pairs(values) do target[key] = value end
    local ok, err = pcall(fn)
    for key in pairs(values) do target[key] = saved[key] end
    T.check(ok, err)
end

T.add("Names ShortName drops the realm and keeps the surname", function()
    T.eq(ns.ShortName("Crayons Bonk-CAMWOWEU5Realm4PvP"), "Crayons Bonk")
    T.eq(ns.ShortName("Crayons-Realm"), "Crayons")
    T.eq(ns.ShortName("Crayons"), "Crayons")
end)

T.add("Names FullName keeps a surname and appends the realm once", function()
    T.eq(ns.FullName("Crayons Bonk"), "Crayons Bonk-" .. realm)
    T.eq(ns.FullName("Crayons Bonk-Other"), "Crayons Bonk-Other")
end)

T.add("Names IsMyStoredName accepts the first-name-only key and rejects another surname", function()
    stubbed(ns, { Me = function() return "Crayons Bonk-Realm" end }, function()
        T.check(ns.IsMyStoredName("Crayons Bonk-Realm"))
        T.check(ns.IsMyStoredName("Crayons-Realm"))
        T.check(not ns.IsMyStoredName("Crayons Other-Realm"))
        T.check(not ns.IsMyStoredName("Crayon-Realm"))
        T.check(not ns.IsMyStoredName("Crayons-Elsewhere"))
    end)
end)

local function legacyStore(isMe)
    local clock = T.fakeClock()
    local function guild() return "Guild" end
    local store = ns.Store.new({ db = {}, me = "Crayons Bonk-Realm", now = clock.now, guild = guild, isMe = isMe })
    local old = ns.Store.new({ db = {}, me = "Crayons-Realm", now = clock.now, guild = guild })
    local wish = assert(old:AddWish({ name = "Herb", qty = 2, guild = true }))
    assert(store:Merge(old:Get(wish.id)))
    local bob = ns.Store.new({ db = {}, me = "Bob-Realm", now = clock.now, guild = guild })
    local theirs = assert(bob:AddWish({ name = "Ore", qty = 2, guild = true }))
    assert(store:Merge(bob:Get(theirs.id)))
    return store, wish, theirs
end

local function acceptsOldKey(name) return name == "Crayons Bonk-Realm" or name == "Crayons-Realm" end

T.add("Names a store with isMe owns records under the older key", function()
    local store, wish, theirs = legacyStore(acceptsOldKey)
    local found = false
    for _, w in ipairs(store:List({ owner = "Crayons Bonk-Realm" })) do found = found or w.id == wish.id end
    T.check(found, "List owner includes the older key")
    T.check(store:Claim(wish.id, 1) == nil, "cannot claim my own wish")
    local claim = assert(store:Claim(theirs.id, 1))
    claim.by = "Crayons-Realm"
    assert(store:MarkSent(theirs.id, claim.id))
    assert(store:CloseWish(wish.id))
    assert(store:DeleteWish(wish.id))
end)

T.add("Names a store without isMe keeps exact matching", function()
    local store, wish = legacyStore(nil)
    for _, w in ipairs(store:List({ owner = "Crayons Bonk-Realm" })) do T.check(w.id ~= wish.id) end
    T.check(store:CloseWish(wish.id) == nil)
    T.check(store:DeleteWish(wish.id) == nil)
end)

T.add("Names UnitKey puts the surname back on", function()
    stubbed(_G, {
        UnitName = function() return "Crayons", "Bonk" end,
        UnitNameUnmodified = function() return "Crayons", "Bonk" end,
        UnitRealmRelationship = false,
        UnitGUID = false,
        RegionalUniqueNamesEnabled = function() return true end,
    }, function()
        local consts = Constants and Constants.CharacterNameSeparatorConsts
        local separator = consts and type(consts.CHARACTERNAME_SURNAME_SEPARATOR) == "string"
            and consts.CHARACTERNAME_SURNAME_SEPARATOR or " "
        T.eq(ns.UnitKey("player"), "Crayons" .. separator .. "Bonk-" .. realm)
    end)
end)

T.add("Names a wish row shows the display name and not the realm", function()
    local store = T.newStore("Ann-Realm", "Guild")
    ns.UI.Attach(store, { ui = {} })
    ns.UI.Show("wishes")
    local frame = CommunityWishListFrame
    local bob = T.newStore("Crayons Bonk-CAMWOWEU5Realm4PvP", "Guild")
    local wish = assert(bob:AddWish({ name = "Peacebloom", qty = 3, guild = true }))
    store:Merge(bob:Get(wish.id))
    local detail
    for _, row in ipairs(frame.rows) do
        if row.wishId == wish.id then detail = row.detail:GetText() end
    end
    T.check(detail, "missing row")
    T.check(detail:find("Crayons Bonk", 1, true), detail)
    T.check(not detail:find("CAMWOWEU5Realm4PvP", 1, true), detail)
end)
