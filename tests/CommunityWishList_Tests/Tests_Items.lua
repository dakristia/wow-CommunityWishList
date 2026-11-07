local T = CommunityWishList_Tests
local Items = CommunityWishList.Items

local function withBags(id, fn)
    local slots, info = C_Container.GetContainerNumSlots, C_Container.GetContainerItemInfo
    local scans = 0
    C_Container.GetContainerNumSlots = function(bag)
        scans = scans + 1
        return bag == 0 and 1 or 0
    end
    C_Container.GetContainerItemInfo = function() return { itemID = id } end
    local ok, err = pcall(fn)
    C_Container.GetContainerNumSlots, C_Container.GetContainerItemInfo = slots, info
    T.check(ok, err)
    return scans
end

T.add("Items search ranks bag items before alphabetical matches and respects limits", function()
    withBags(nil, function()
        local results = Items.Search("BANANA")
        T.eq(#results, 2)
        T.eq(results[1].id, 4601)
        T.eq(results[2].id, 4537)
        T.eq(results[2].name, "Tel'Abim Banana")
        T.eq(results[2].quality, 1)
        T.check(results[2].link:find("|Hitem:4537", 1, true))
    end)
    local scans = withBags(4537, function()
        local results = Items.Search("banana", 1)
        T.eq(#results, 1)
        T.eq(results[1].id, 4537)
    end)
    T.eq(scans, 5)
    T.eq(#Items.Search(""), 0)
    T.eq(#Items.Search("b"), 0)
    T.eq(#Items.Search("unknown item"), 0)
    T.eq(Items.Search("telabim")[1].id, 4537)
end)

T.add("Items prefix matches rank before substring matches", function()
    local lib = LibStub("LibItemDB-1.0")
    local search = lib.Search
    lib.Search = function(_, opts)
        T.eq(opts.query, "banana")
        T.eq(opts.loose, true)
        T.eq(opts.max, 50)
        return {
            { id = 1, name = "A banana" },
            { id = 2, name = "Banana Bread" },
        }
    end
    local ok, err = pcall(function()
        withBags(nil, function() T.eq(Items.Search("banana")[1].id, 2) end)
    end)
    lib.Search = search
    T.check(ok, err)
end)

T.add("Items resolves exact names and links using real names", function()
    local id, name = Items.Resolve(" pEaCeBlOoM ")
    T.eq(id, 2447)
    T.eq(name, "Peacebloom")
    id, name = Items.Resolve("|Hitem:4537|h[Wrong name]|h")
    T.eq(id, 4537)
    T.eq(name, "Tel'Abim Banana")
    T.eq(Items.Resolve("banana"), nil)
    T.eq(Items.Resolve("Unknown"), nil)
    T.eq(Items.Quality(19019), 5)
    T.check(Items.Link(2447):find("Peacebloom", 1, true))
end)

T.add("Items tolerates missing and unready libraries and missing bag APIs", function()
    local stub = LibStub
    local lib = stub("LibItemDB-1.0")
    local ready, container = lib.IsReady, C_Container
    local ok, err = pcall(function()
        C_Container = nil
        T.eq(#Items.Search("banana"), 2)
        lib.IsReady = function() return false end
        T.eq(#Items.Search("banana"), 0)
        T.eq(Items.Resolve("Peacebloom"), nil)
        LibStub = nil
        T.eq(#Items.Search("banana"), 0)
        T.eq(Items.Resolve("Peacebloom"), nil)
        Items.Link(2447)
        Items.Icon(2447)
        Items.Quality(2447)
    end)
    LibStub, C_Container, lib.IsReady = stub, container, ready
    T.check(ok, err)
end)
