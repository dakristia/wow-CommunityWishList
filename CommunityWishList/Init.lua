-- See docs/design.md for the Init contract.
local ADDON_NAME, ns = ...

local me
local rosterCache
local started = false

local function guildName()
    return GetGuildInfo("player")
end

local function isOnline(name)
    local full = ns.FullName(name)
    if not full or not GetNumGuildMembers or not GetGuildRosterInfo then return false end
    if not rosterCache then
        rosterCache = {}
        for i = 1, GetNumGuildMembers() do
            local rosterName, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
            if rosterName then rosterCache[ns.FullName(rosterName)] = online and true or false end
        end
    end
    return rosterCache[full] == true
end

local function whisper(text, target)
    if C_ChatInfo and C_ChatInfo.SendChatMessage then C_ChatInfo.SendChatMessage(text, "WHISPER", nil, target) end
end

local function alert(text)
    ns.Print("%s", text)
    if PlaySound then PlaySound((SOUNDKIT and SOUNDKIT.TELL_MESSAGE) or 3081) end
    if UIErrorsFrame then UIErrorsFrame:AddMessage(text, 1, 0.82, 0) end
end

-- Merge-triggered changes must not go out as "high" local broadcasts, so only
-- these wrapped methods mark a change as local.
local localDepth = 0

local function wrapLocal(store, method, after)
    local original = store[method]
    store[method] = function(self, ...)
        localDepth = localDepth + 1
        local results = { pcall(original, self, ...) }
        localDepth = localDepth - 1
        if not results[1] then error(results[2], 0) end
        if results[2] and after then after(results[2], results[3]) end
        return unpack(results, 2, table.maxn(results))
    end
end

local function setupStore()
    local store = ns.Store.new{ db = CommunityWishListDB, me = me, now = time, guild = guildName }
    ns.store = store
    -- A "wish" change on my own wish is always mine to broadcast, so the auto-close that Merge triggers also goes out.
    store:OnChange(function(kind, wish)
        if ns.sync and (localDepth > 0 or (kind == "wish" and wish.owner == me)) then ns.sync:OnLocalChange(wish) end
    end)
    for _, method in ipairs({ "AddWish", "UpdateWish", "CloseWish", "DeleteWish", "CancelClaim", "ReleaseClaim", "MarkReceived" }) do
        wrapLocal(store, method)
    end
    wrapLocal(store, "Claim", function(claim, wish)
        if ns.notify then ns.notify:Claimed(wish, claim) end
    end)
    wrapLocal(store, "MarkSent", function(claim, wish)
        if ns.notify then ns.notify:Sent(wish, claim) end
    end)
    ns.notify = ns.Notify.new{ store = store, db = CommunityWishListDB, me = me,
        isOnline = isOnline, whisper = whisper, alert = alert, after = C_Timer.After }
end

local function mailApi()
    return {
        setRecipient = function(name) SendMailNameEditBox:SetText(name) end,
        setSubject = function(text) SendMailSubjectEditBox:SetText(text) end,
        showSendTab = function()
            if MailFrameTab_OnClick and MailFrameTab2 then MailFrameTab_OnClick(MailFrameTab2, 2) end
        end,
        attach = function(bag, slot)
            C_Container.PickupContainerItem(bag, slot)
            ClickSendMailItemButton()
        end,
        numSlots = function(bag) return C_Container.GetContainerNumSlots(bag) end,
        getContainerItem = function(bag, slot)
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info then return info.itemID, info.stackCount end
        end,
        getSendItem = function(i)
            local _, itemID, _, count = GetSendMailItem(i)
            return itemID, count
        end,
        getInboxHeader = function(index)
            local _, _, sender = GetInboxHeaderInfo(index)
            return sender
        end,
        getInboxItem = function(index, a)
            local _, itemID, _, count = GetInboxItem(index, a)
            return itemID, count
        end,
    }
end

local function setupMail()
    ns.mail = ns.Mail.new{ store = ns.store, me = me, api = mailApi() }
    -- The hooks run after the original call, so a failure in them can never block the player's mail.
    if _G.SendMail then
        hooksecurefunc("SendMail", function(recipient) ns.mail:OnSendMail(recipient) end)
    end
    if _G.TakeInboxItem then
        hooksecurefunc("TakeInboxItem", function(index, attachment) ns.mail:OnTakeItem(index, attachment) end)
    end
    if _G.AutoLootMailItem then
        hooksecurefunc("AutoLootMailItem", function(index) ns.mail:OnTakeItem(index) end)
    end
end

local function printUsage()
    ns.Print("/cwl - show or hide the window")
    ns.Print("/cwl add <qty> <item link or name> - add a wish")
end

local function handleSlash(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    if msg == "" then
        ns.UI.Toggle()
    elseif msg:lower() == "help" then
        printUsage()
    else
        local qty, item = msg:match("^[Aa][Dd][Dd]%s+(%d+)%s+(.+)$")
        if not qty then
            printUsage()
            return
        end
        local id, name = ns.Items.Resolve(item)
        if not id then
            ns.Print("Pick an item from the list, or shift-click an item link.")
            return
        end
        local wish, err = ns.store:AddWish{ item = id, name = name, qty = tonumber(qty), guild = true }
        if wish then
            ns.Print("Added %s x %d.", wish.name, wish.qty)
        else
            ns.Print("Could not add the wish: %s", tostring(err))
        end
    end
end

local function startSync()
    if started then return end
    started = true
    if ns.sync then ns.sync:Start() end
    ns.notify:AfterLogin()
end

local function onLogin()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX) end
    ns.comm = ns.Comm.new{ prefix = ns.PREFIX, now = GetTime, after = C_Timer.After,
        send = function(prefix, text, channel, target)
            if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return 0 end
            local result = C_ChatInfo.SendAddonMessage(prefix, text, channel, target)
            if result == true then return 0 end
            if result == false then return 3 end
            return result
        end }
    ns.sync = ns.Sync.new{ store = ns.store, comm = ns.comm, me = me, guild = guildName,
        now = GetTime, after = C_Timer.After,
        random = function(a, b) return a + math.random() * (b - a) end }
    if guildName() then
        if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
        C_Timer.After(5, startSync)
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("MAIL_SHOW")
frame:RegisterEvent("MAIL_CLOSED")
frame:RegisterEvent("MAIL_SEND_SUCCESS")
frame:RegisterEvent("MAIL_FAILED")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON_NAME then return end
        CommunityWishListDB = CommunityWishListDB or {}
    elseif event == "PLAYER_LOGIN" then
        -- The store starts here and not at ADDON_LOADED, because the realm name can still be nil there.
        me = ns.FullName(UnitName("player"))
        setupStore()
        setupMail()
        ns.UI.Attach(ns.store, CommunityWishListDB)
        ns.Minimap.Attach(CommunityWishListDB)
        SLASH_COMMUNITYWISHLIST1 = "/cwl"
        SLASH_COMMUNITYWISHLIST2 = "/wishlist"
        SlashCmdList.COMMUNITYWISHLIST = handleSlash
        onLogin()
    elseif event == "CHAT_MSG_ADDON" then
        if ns.comm then ns.comm:Receive(...) end
    elseif event == "MAIL_SHOW" then
        if ns.mail then
            ns.mail.panel = ns.mail.panel or ns.Mail.CreatePanel(ns.mail)
            ns.mail.panel:Show()
        end
    elseif event == "MAIL_CLOSED" then
        if ns.mail and ns.mail.panel then ns.mail.panel:Hide() end
    elseif event == "MAIL_SEND_SUCCESS" then
        if ns.mail then ns.mail:OnSendSuccess() end
    elseif event == "MAIL_FAILED" then
        if ns.mail then ns.mail:OnSendFailed() end
    elseif event == "GUILD_ROSTER_UPDATE" then
        rosterCache = nil
        if ns.sync and guildName() then startSync() end
    end
end)
