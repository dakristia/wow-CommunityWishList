local T = CommunityWishList_Tests
local ns = CommunityWishList

-- Ann owns the wish and Bob claims it, so the store here is Ann's.
local function setup(online)
    local clock = T.fakeClock()
    local store = T.newStore("Ann-Realm", "Guild", clock)
    local db = { seen = {} }
    local alerts, whispers = {}, {}
    local notify = ns.Notify.new{
        store = store, db = db, me = "Ann-Realm",
        isOnline = function(name) return online and online[name] or false end,
        whisper = function(text, target) whispers[#whispers + 1] = { text = text, target = target } end,
        alert = function(text) alerts[#alerts + 1] = text end,
        after = clock.after,
    }
    return store, db, notify, alerts, whispers, clock
end

local function bobClaims(store, qty)
    local wish = assert(store:AddWish({ name = "Peacebloom", qty = 100, guild = true }))
    local bob = T.newStore("Bob-Realm", "Guild")
    bob:Merge(wish)
    local claim = assert(bob:Claim(wish.id, qty or 40))
    return wish, bob, claim
end

T.add("Notify alerts once for a new claim on my wish and marks it seen", function()
    local store, db, _, alerts = setup()
    local wish, bob, claim = bobClaims(store)
    store:Merge(bob:Get(wish.id))
    T.eq(#alerts, 1)
    T.eq(alerts[1], "Bob will send you 40 x [Peacebloom]")
    T.check(db.seen[claim.id])
    store:Merge(bob:Get(wish.id))
    T.eq(#alerts, 1, "alerts after a repeated merge")
end)

T.add("Notify ignores my own claims and claims on other wishes", function()
    local store, _, _, alerts = setup()
    local bob = T.newStore("Bob-Realm", "Guild")
    local theirs = assert(bob:AddWish({ name = "Herb", qty = 10, guild = true }))
    store:Merge(theirs)
    assert(store:Claim(theirs.id, 5))
    local cara = T.newStore("Cara-Realm", "Guild")
    cara:Merge(store:Get(theirs.id))
    assert(cara:Claim(theirs.id, 2))
    store:Merge(cara:Get(theirs.id))
    T.eq(#alerts, 0)
end)

T.add("Notify AfterLogin summarizes unseen claims after 10 seconds and skips live ones", function()
    local store, db, notify, alerts, _, clock = setup()
    local wish, bob = bobClaims(store, 10)
    notify:AfterLogin()
    store:Merge(bob:Get(wish.id))
    T.eq(#alerts, 1, "live alert")
    -- A claim that arrives while no listener runs stays unseen, so the summary must count it.
    local late = { id = "Cara-Realm:1", by = "Cara-Realm", qty = 5, state = "open", created = 1 }
    store:Get(wish.id).claims[late.id] = late
    clock.advance(9)
    T.eq(#alerts, 1, "alerts before 10 seconds")
    clock.advance(1)
    T.eq(#alerts, 2)
    T.eq(alerts[2], "1 new claims on your wishes")
    T.check(db.seen[late.id])
    clock.advance(10)
    T.eq(#alerts, 2)
end)

T.add("Notify Claimed whispers the recipient first, then the owner, then nobody", function()
    local store, _, notify, _, whispers = setup({ ["Ann-Realm"] = true, ["Dan-Realm"] = true })
    local wish, _, claim = bobClaims(store)
    wish.recipient = "Dan-Realm"
    notify:Claimed(wish, claim)
    T.eq(#whispers, 1)
    T.eq(whispers[1].target, "Dan-Realm")
    T.eq(whispers[1].text, "I will send you 40 x [Peacebloom] (CommunityWishList)")
    notify:Sent(wish, claim)
    T.eq(whispers[2].text, "I have sent you 40 x [Peacebloom] (CommunityWishList)")

    local onlyOwner, _, ownerNotify, _, ownerWhispers = setup({ ["Ann-Realm"] = true })
    local w, _, c = bobClaims(onlyOwner)
    w.recipient = "Dan-Realm"
    ownerNotify:Claimed(w, c)
    T.eq(#ownerWhispers, 1)
    T.eq(ownerWhispers[1].target, "Ann-Realm")

    local offline, _, offlineNotify, _, offlineWhispers = setup({})
    local w2, _, c2 = bobClaims(offline)
    offlineNotify:Claimed(w2, c2)
    offlineNotify:Sent(w2, c2)
    T.eq(#offlineWhispers, 0)
end)

T.add("Init slash command toggles the window and adds a wish or reports an error", function()
    local slash = SlashCmdList.COMMUNITYWISHLIST
    T.check(slash, "slash handler missing")
    local before = CommunityWishListFrame and CommunityWishListFrame:IsShown()
    slash("")
    T.check(CommunityWishListFrame, "frame missing")
    T.check(CommunityWishListFrame:IsShown() ~= before, "frame did not toggle")
    slash("")
    T.eq(CommunityWishListFrame:IsShown(), before and true or false)
    slash("help")
    local store = ns.store
    T.check(store, "store missing")
    local count = #store:List()
    local ok, err = pcall(slash, "add 5 Peacebloom")
    T.check(ok, tostring(err))
    if GetGuildInfo("player") then
        T.eq(#store:List(), count + 1)
    else
        T.eq(#store:List(), count)
    end
end)
