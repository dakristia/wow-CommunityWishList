local T = CommunityWishList_Tests
local ns = CommunityWishList

local function transport(clock, send)
    return ns.Comm.new({ prefix = "CWList", now = clock.now, after = clock.after, send = send })
end

local function network()
    local net = { clock = T.fakeClock(), peers = {}, sent = {}, messages = {} }
    local observer = transport(net.clock, function() return 0 end)
    observer:OnMessage(function(text, channel, sender)
        local message = ns.Codec.Deserialize(text)
        if message then net.messages[#net.messages + 1] = { body = message, sender = sender, channel = channel } end
    end)
    function net.add(name, guild)
        guild = guild or "Guild"
        local peer = { name = name, online = true }
        peer.store = T.newStore(name, guild, net.clock)
        peer.comm = transport(net.clock, function(prefix, text, channel, target)
            if not peer.online then return 0 end
            net.sent[#net.sent + 1] = { sender = name, text = text, at = net.clock.now() }
            observer:Receive(prefix, text, channel, name)
            for _, other in ipairs(net.peers) do
                if other ~= peer and other.online and ((channel == "GUILD" and other.guild == guild) or (channel == "WHISPER" and other.name == target)) then
                    other.comm:Receive(prefix, text, channel, name)
                end
            end
            return 0
        end)
        local seed = 17 + #net.peers * 7919
        peer.sync = ns.Sync.new({ store = peer.store, comm = peer.comm, me = name,
            guild = function() return guild end, now = net.clock.now, after = net.clock.after,
            random = function(a, b)
                seed = (seed * 16807) % 2147483647
                return a + (b - a) * seed / 2147483647
            end })
        peer.guild = guild
        net.peers[#net.peers + 1] = peer
        return peer
    end
    function net.count(kind)
        local count = 0
        for _, message in ipairs(net.messages) do
            if message.body.k == kind then count = count + 1 end
        end
        return count
    end
    return net
end

local function addWish(peer)
    return assert(peer.store:AddWish({ item = 2447, name = "Peacebloom", qty = 20, guild = true,
        note = "for alchemy", gold = 123, prio = 3, recipient = "Alt-Realm" }))
end

T.add("comm chunks 2000 bytes and reassembles out of order", function()
    local clock, parts, received = T.fakeClock(), {}, {}
    local a = transport(clock, function(_, text)
        T.check(#text <= 255, "part exceeds addon limit")
        parts[#parts + 1] = text
        return 0
    end)
    local b = transport(clock, function() return 0 end)
    b:OnMessage(function(text, channel, sender)
        T.eq(channel, "GUILD")
        T.eq(sender, "Ann-Realm")
        received[#received + 1] = text
    end)
    local payload = string.rep("abc|\n", 400)
    a:Send(payload, "GUILD", nil, "bulk")
    clock.advance(20)
    T.check(#parts > 1)
    for i = #parts, 1, -1 do b:Receive("CWList", parts[i], "GUILD", "Ann-Realm") end
    T.eq(#received, 1)
    T.eq(received[1], payload)
end)

T.add("comm drops invalid parts and expires incomplete messages", function()
    local clock, count = T.fakeClock(), 0
    local comm = transport(clock, function() return 0 end)
    comm:OnMessage(function() count = count + 1 end)
    for _, text in ipairs({ "garbage", "0/2/1|x", "3/2/1|x", "1/65/1|x", "1/0/1|x", "1/1/no|x", "1/1/0|x" }) do
        comm:Receive("CWList", text, "GUILD", "Ann-Realm")
    end
    comm:Receive("Other", "1/1/1|wrong prefix", "GUILD", "Ann-Realm")
    T.eq(next(comm.incoming), nil)
    comm:Receive("CWList", "1/2/1|lost", "GUILD", "Ann-Realm")
    comm:Receive("CWList", "1/2/1|lost", "GUILD", "Ann-Realm")
    comm:Receive("CWList", "2/3/1|inconsistent", "GUILD", "Ann-Realm")
    clock.advance(30)
    comm:Receive("CWList", "garbage", "GUILD", "Ann-Realm")
    T.eq(next(comm.incoming), nil)
    comm:Receive("CWList", "2/2/1|late", "GUILD", "Ann-Realm")
    T.eq(count, 0)
    comm:Receive("CWList", "1/2/1|other", "GUILD", "Bob-Realm")
    T.eq(count, 0, "senders must not share an assembly")
end)

T.add("comm token bucket burst and high priority", function()
    local clock, sent = T.fakeClock(), {}
    local comm = transport(clock, function(_, text)
        sent[#sent + 1] = { text = text:match("|(.*)$"), at = clock.now() }
        return 0
    end)
    for i = 1, 15 do comm:Send(tostring(i), "GUILD", nil, "bulk") end
    T.eq(#sent, 10)
    clock.advance(0.9)
    T.eq(#sent, 10)
    clock.advance(0.1)
    T.eq(#sent, 11)
    clock.advance(4)
    T.eq(#sent, 15)
    for i = 11, 15 do T.eq(sent[i].at, 1000 + i - 10) end
    comm:Send("bulk", "GUILD", nil, "bulk")
    comm:Send("high", "GUILD", nil, "high")
    clock.advance(1)
    T.eq(sent[16].text, "high")
    clock.advance(1)
    T.eq(sent[17].text, "bulk")
end)

T.add("comm retries throttle codes without changing part order", function()
    for _, code in ipairs({ 3, 8 }) do
        local clock, attempts = T.fakeClock(), {}
        local comm = transport(clock, function(_, text)
            attempts[#attempts + 1] = { text = text, at = clock.now() }
            return #attempts == 1 and code or 0
        end)
        comm:Send(string.rep("a", 600), "GUILD", nil, "bulk")
        comm:Send("later", "GUILD", nil, "bulk")
        T.eq(#attempts, 1)
        clock.advance(0.99)
        T.eq(#attempts, 1)
        clock.advance(0.01)
        T.eq(attempts[1].text, attempts[2].text)
        T.eq(attempts[2].at, 1001)
        T.check(attempts[3].text:match("^2/3/1|"))
        T.check(attempts[4].text:match("^3/3/1|"))
        T.check(attempts[5].text:match("^1/1/2|later$"))
    end
end)

T.add("sync local wish and offline owner relay", function()
    local net = network()
    local a, b = net.add("Ann-Realm"), net.add("Bob-Realm")
    local w = addWish(a)
    a.sync:OnLocalChange(w)
    net.clock.advance(10)
    T.check(b.store:Get(w.id), "online peer missed wish")
    a.online = false
    local c = net.add("Cara-Realm")
    c.sync:Start()
    net.clock.advance(20)
    T.check(c.store:Get(w.id), "relay missed wish")
    T.eq(c.store:Digest()[w.id], b.store:Digest()[w.id])
end)

T.add("sync rejects and never relays another guild audience", function()
    local net = network()
    local a, b = net.add("Ann-Realm"), net.add("Bob-Realm")
    local other = T.newStore("Other-Realm", "OtherGuild", net.clock)
    local w = assert(other:AddWish({ name = "Herb", qty = 10, guild = true }))
    a.store:Merge(w)
    a.sync:OnLocalChange(w)
    T.eq(net.count("W"), 0)
    a.comm:Send(assert(ns.Codec.Serialize({ p = 1, k = "W", w = ns.Sync.ToWire(w) })), "GUILD")
    net.clock.advance(10)
    T.eq(b.store:Get(w.id), nil)
    local before = net.count("W")
    b.sync:Start()
    b.comm:Send(assert(ns.Codec.Serialize({ p = 1, k = "R", ids = { w.id } })), "GUILD")
    net.clock.advance(20)
    T.eq(net.count("W"), before)
end)

T.add("sync hello suppresses duplicate wish broadcasts", function()
    local net = network()
    local a, b = net.add("Ann-Realm"), net.add("Bob-Realm")
    local w = addWish(a)
    b.store:Merge(w)
    local c = net.add("Cara-Realm")
    c.sync:Start()
    net.clock.advance(20)
    T.check(c.store:Get(w.id))
    T.eq(net.count("W"), 1)
end)

T.add("sync requests newer versions and spreads them", function()
    local net = network()
    local a, b, c = net.add("Ann-Realm"), net.add("Bob-Realm"), net.add("Cara-Realm")
    local w = addWish(a)
    b.store:Merge(w)
    c.store:Merge(w)
    assert(a.store:UpdateWish(w.id, { note = "newer" }))
    a.sync:Start()
    net.clock.advance(20)
    T.eq(net.count("R"), 1, "duplicate request was not suppressed")
    T.eq(b.store:Get(w.id).v, 2)
    T.eq(c.store:Get(w.id).note, "newer")
    T.eq(net.count("W"), 1, "request response was not suppressed")
end)

T.add("sync offline claim reaches returning owner", function()
    local net = network()
    local a, b = net.add("Ann-Realm"), net.add("Bob-Realm")
    local w = addWish(a)
    a.sync:OnLocalChange(w)
    net.clock.advance(10)
    a.online = false
    local claim, changed = b.store:Claim(w.id, 4)
    T.check(claim)
    b.sync:OnLocalChange(changed)
    net.clock.advance(10)
    T.eq(a.store:Get(w.id).claims[claim.id], nil)
    a.online = true
    a.sync:Start()
    net.clock.advance(20)
    T.eq(a.store:Get(w.id).claims[claim.id].qty, 4)
end)

T.add("sync wire round trip ignores unknown fields", function()
    local a = T.newStore("Ann-Realm", "Guild")
    local b = T.newStore("Bob-Realm", "Guild")
    local w = assert(a:AddWish({ name = "Herb", item = 2447, qty = 10, guild = true, note = "note", gold = 5, prio = 1 }))
    b:Merge(w)
    local claim = assert(b:Claim(w.id, 2))
    assert(b:MarkSent(w.id, claim.id))
    a:Merge(b:Get(w.id))
    assert(a:MarkReceived(w.id, claim.id))
    local wire = ns.Sync.ToWire(w)
    wire.unknown = "ignored"
    local copy = ns.Sync.FromWire(assert(ns.Codec.Deserialize(assert(ns.Codec.Serialize(wire)))))
    local function equal(left, right)
        for key, value in pairs(left) do
            if type(value) == "table" then T.eq(type(right[key]), "table"); equal(value, right[key]) else T.eq(right[key], value, key) end
        end
        for key in pairs(right) do T.check(left[key] ~= nil, "unexpected round-trip key " .. tostring(key)) end
    end
    equal(w, copy)
    equal(assert(a:DeleteWish(w.id)), ns.Sync.FromWire(ns.Sync.ToWire(a:Get(w.id))))
end)

T.add("sync ignores garbage missing protocol own messages and other channels", function()
    local net = network()
    local a, b = net.add("Ann-Realm"), net.add("Bob-Realm")
    local w = addWish(a)
    local wire = ns.Sync.ToWire(w)
    for _, body in ipairs({ { k = "W", w = wire }, { p = 1, k = "unknown" },
        { p = 1, k = "W", w = false }, { p = 1, k = "H", d = { bad = {} } },
        { p = 1, k = "R", ids = { false, 42, {} } } }) do
        a.comm:Send(assert(ns.Codec.Serialize(body)), "GUILD")
    end
    a.comm:Send("garbage", "GUILD")
    local text = assert(ns.Codec.Serialize({ p = 1, k = "W", w = wire }))
    a.comm:Send(text, "WHISPER", b.name)
    b.sync:Receive(text, "GUILD", b.name)
    net.clock.advance(30)
    T.eq(b.store:Get(w.id), nil)
    T.eq(net.count("R"), 1, "invalid input scheduled a request")
end)
