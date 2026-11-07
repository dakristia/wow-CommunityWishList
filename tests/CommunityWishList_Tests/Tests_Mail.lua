local T = CommunityWishList_Tests
local ns = CommunityWishList

-- Ann wishes, Bob claims. Bob's store is the one the mail module works on.
local function setup(wishQty, claimQtys)
    local clock = T.fakeClock()
    local ann = T.newStore("Ann-Realm", "Guild", clock)
    local wish = assert(ann:AddWish({ item = 2447, name = "Peacebloom", qty = wishQty or 100, guild = true }))
    local bob = T.newStore("Bob-Realm", "Guild", clock)
    bob:Merge(wish)
    local claims = {}
    for _, qty in ipairs(claimQtys or { 30 }) do
        clock.advance(1)
        claims[#claims + 1] = assert(bob:Claim(wish.id, qty))
    end
    return ann, bob, wish, claims
end

local function fakeApi(bags, sendItems, inbox)
    local api = { attached = {}, bags = bags or {}, sendItems = sendItems or {}, inbox = inbox or {} }
    function api.setRecipient(name) api.recipient = name end
    function api.setSubject(text) api.subject = text end
    function api.showSendTab() api.tab = true end
    function api.attach(bag, slot) api.attached[#api.attached + 1] = { bag, slot } end
    function api.numSlots(bag) return api.bags[bag] and #api.bags[bag] or 0 end
    function api.getContainerItem(bag, slot)
        local s = api.bags[bag][slot]
        if s then return s[1], s[2] end
    end
    function api.getSendItem(i)
        local s = api.sendItems[i]
        if s then return s[1], s[2] end
    end
    function api.getInboxHeader() return api.inbox.sender end
    function api.getInboxItem(_, a)
        local s = api.inbox.items and api.inbox.items[a]
        if s then return s[1], s[2] end
    end
    return api
end

local function newMail(store, me, api)
    return ns.Mail.new{ store = store, me = me, api = api }
end

T.add("Mail ClaimsToSend groups open claims by recipient and skips sent claims", function()
    local _, bob, wish, claims = setup(100, { 10, 20 })
    local other = T.newStore("Cara-Realm", "Guild")
    local w2 = assert(other:AddWish({ item = 2447, name = "Peacebloom", qty = 50, guild = true }))
    bob:Merge(w2)
    assert(bob:Claim(w2.id, 5))
    local mail = newMail(bob, "Bob-Realm", fakeApi())
    local groups = mail:ClaimsToSend()
    T.eq(#groups, 2)
    T.eq(groups[1].recipient, "Ann-Realm")
    T.eq(#groups[1].claims, 2)
    T.eq(groups[1].claims[1].claim.id, claims[1].id)
    T.eq(groups[2].recipient, "Cara-Realm")
    assert(bob:MarkSent(wish.id, claims[1].id))
    groups = mail:ClaimsToSend()
    T.eq(#groups[1].claims, 1)
    T.eq(groups[1].claims[1].claim.id, claims[2].id)
end)

T.add("Mail Prepare fills the form and attaches only stacks that fit", function()
    local _, bob, wish, claims = setup(100, { 30 })
    local api = fakeApi({ [0] = { { 2447, 20 }, { 2447, 15 }, { 999, 30 } }, [1] = { { 2447, 5 } } })
    local mail = newMail(bob, "Bob-Realm", api)
    local count = mail:Prepare(wish.id, claims[1].id)
    T.eq(count, 25)
    T.eq(api.recipient, "Ann")
    T.eq(api.subject, "CommunityWishList: 30 x Peacebloom")
    T.check(api.tab, "send tab not shown")
    T.eq(#api.attached, 2)
    T.eq(api.attached[1][2], 1)
    T.eq(api.attached[2][1], 1)
end)

T.add("Mail Prepare survives a failing attach", function()
    local _, bob, wish, claims = setup(100, { 30 })
    local api = fakeApi({ [0] = { { 2447, 20 } } })
    api.attach = function() error("no mail frame") end
    T.eq(newMail(bob, "Bob-Realm", api):Prepare(wish.id, claims[1].id), 0)
    T.eq(api.recipient, "Ann")
end)

T.add("Mail marks a matching claim sent after a successful send", function()
    local _, bob, wish, claims = setup(100, { 30 })
    local api = fakeApi(nil, { { 2447, 30 } })
    local mail = newMail(bob, "Bob-Realm", api)
    mail:OnSendMail("Ann")
    mail:OnSendSuccess()
    T.eq(bob:Get(wish.id).claims[claims[1].id].state, "sent")
end)

T.add("Mail marks nothing for another recipient or another item", function()
    local _, bob, wish, claims = setup(100, { 30 })
    local api = fakeApi(nil, { { 2447, 30 } })
    local mail = newMail(bob, "Bob-Realm", api)
    mail:OnSendMail("Dan")
    mail:OnSendSuccess()
    T.eq(bob:Get(wish.id).claims[claims[1].id].state, "open")
    api.sendItems = { { 111, 30 } }
    mail:OnSendMail("Ann")
    mail:OnSendSuccess()
    T.eq(bob:Get(wish.id).claims[claims[1].id].state, "open")
end)

T.add("Mail OnSendFailed clears the pending send", function()
    local _, bob, wish, claims = setup(100, { 30 })
    local mail = newMail(bob, "Bob-Realm", fakeApi(nil, { { 2447, 30 } }))
    mail:OnSendMail("Ann")
    mail:OnSendFailed()
    mail:OnSendSuccess()
    T.eq(bob:Get(wish.id).claims[claims[1].id].state, "open")
end)

T.add("Mail marks only the claims that the sent count covers", function()
    local _, bob, wish, claims = setup(100, { 10, 20 })
    local mail = newMail(bob, "Bob-Realm", fakeApi(nil, { { 2447, 15 } }))
    mail:OnSendMail("Ann")
    mail:OnSendSuccess()
    T.eq(bob:Get(wish.id).claims[claims[1].id].state, "sent")
    T.eq(bob:Get(wish.id).claims[claims[2].id].state, "open")
end)

T.add("Mail OnTakeItem marks the claimer's sent claim received and ignores other senders", function()
    local ann, bob, wish, claims = setup(100, { 30 })
    assert(bob:MarkSent(wish.id, claims[1].id))
    ann:Merge(bob:Get(wish.id))
    local api = fakeApi(nil, nil, { sender = "Cara", items = { { 2447, 30 } } })
    local mail = newMail(ann, "Ann-Realm", api)
    mail:OnTakeItem(1, 1)
    T.eq(ann:Get(wish.id).claims[claims[1].id].state, "sent", "mail from someone else")
    api.inbox.sender = "Bob"
    mail:OnTakeItem(1)
    T.eq(ann:Get(wish.id).claims[claims[1].id].state, "received")
end)

T.add("Mail panel shows an empty state", function()
    if not MailFrame then
        print("SKIP Mail panel: MailFrame missing in wowless")
        return
    end
    local _, bob = setup(100, {})
    local mail = newMail(bob, "Bob-Realm", fakeApi())
    local panel = ns.Mail.CreatePanel(mail)
    panel:Show()
    T.check(panel.empty:IsShown(), "empty text hidden")
    T.eq(panel.empty:GetText(), "Nothing to send.")
end)
