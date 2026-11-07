-- See docs/design.md for the Mail contract.
local _, ns = ...

local Mail = {}
Mail.__index = Mail
ns.Mail = Mail

local BAGS = { 0, 1, 2, 3, 4 }

local function byAge(a, b)
    if (a.claim.created or 0) == (b.claim.created or 0) then return a.claim.id < b.claim.id end
    return (a.claim.created or 0) < (b.claim.created or 0)
end

function Mail.new(opts)
    return setmetatable({ store = opts.store, me = ns.FullName(opts.me), api = opts.api }, Mail)
end

-- Closed wishes stay in the list because the wisher still receives mail for a filled wish.
-- Entries of { wish, claim } where `match(wish, claim)` holds, oldest claim first.
local function collect(self, state, match)
    local entries = {}
    for _, wish in ipairs(self.store:List()) do
        for _, claim in pairs(wish.claims or {}) do
            if claim.state == state and match(wish, claim) then entries[#entries + 1] = { wish = wish, claim = claim } end
        end
    end
    table.sort(entries, byAge)
    return entries
end

function Mail:ClaimsToSend()
    local entries = collect(self, "open", function(wish, claim) return wish.state == "open" and claim.by == self.me end)
    local groups, order = {}, {}
    for _, entry in ipairs(entries) do
        local recipient = entry.wish.recipient or entry.wish.owner
        if not groups[recipient] then
            groups[recipient] = { recipient = recipient, claims = {} }
            order[#order + 1] = groups[recipient]
        end
        local list = groups[recipient].claims
        list[#list + 1] = entry
    end
    return order
end

local function bagStacks(self, itemID)
    local stacks = {}
    for _, bag in ipairs(BAGS) do
        for slot = 1, self.api.numSlots(bag) or 0 do
            local id, count = self.api.getContainerItem(bag, slot)
            if id == itemID and count and count > 0 then stacks[#stacks + 1] = { bag = bag, slot = slot, count = count } end
        end
    end
    table.sort(stacks, function(a, b) return a.count > b.count end)
    return stacks
end

function Mail:Prepare(wishId, claimId)
    local wish = self.store:Get(wishId)
    local claim = wish and wish.claims and wish.claims[claimId]
    if not claim or claim.state ~= "open" or claim.by ~= self.me then return 0 end
    self.api.showSendTab()
    self.api.setRecipient(ns.ShortName(wish.recipient or wish.owner))
    self.api.setSubject(("CommunityWishList: %d x %s"):format(claim.qty, wish.name or "?"))
    local attached = 0
    if wish.item then
        for _, stack in ipairs(bagStacks(self, wish.item)) do
            if attached + stack.count <= claim.qty then
                local ok = pcall(self.api.attach, stack.bag, stack.slot)
                if ok then attached = attached + stack.count end
            end
        end
    end
    return attached
end

function Mail:OnSendMail(recipient)
    local items = {}
    for i = 1, ATTACHMENTS_MAX_SEND or 12 do
        local itemID, count = self.api.getSendItem(i)
        if itemID then items[#items + 1] = { itemID = itemID, count = count or 1 } end
    end
    -- The recipient is lowercased because players type names in any case and the mail still arrives.
    local name = ns.FullName(recipient)
    self.pending = { recipient = name and name:lower(), items = items }
end

function Mail:OnSendSuccess()
    local pending = self.pending
    self.pending = nil
    if not pending or not pending.recipient then return end
    local sentByItem = {}
    for _, item in ipairs(pending.items) do sentByItem[item.itemID] = (sentByItem[item.itemID] or 0) + item.count end
    for itemID, sent in pairs(sentByItem) do
        local entries = collect(self, "open", function(wish, claim)
            return claim.by == self.me and wish.item == itemID
                and ((wish.recipient or ""):lower() == pending.recipient or wish.owner:lower() == pending.recipient)
        end)
        for _, entry in ipairs(entries) do
            if sent < entry.claim.qty then break end
            if self.store:MarkSent(entry.wish.id, entry.claim.id) then sent = sent - entry.claim.qty end
        end
    end
end

function Mail:OnSendFailed()
    self.pending = nil
end

local function receive(self, sender, itemID, count)
    local entries = collect(self, "sent", function(wish, claim)
        return wish.item == itemID and claim.by == sender and (wish.owner == self.me or wish.recipient == self.me)
    end)
    for _, entry in ipairs(entries) do
        if count < entry.claim.qty then break end
        if self.store:MarkReceived(entry.wish.id, entry.claim.id) then count = count - entry.claim.qty end
    end
end

function Mail:OnTakeItem(index, attachment)
    local sender = ns.FullName(self.api.getInboxHeader(index))
    if not sender then return end
    local first, last = attachment or 1, attachment or ATTACHMENTS_MAX_RECEIVE or 16
    for a = first, last do
        local itemID, count = self.api.getInboxItem(index, a)
        if itemID then receive(self, sender, itemID, count or 1) end
    end
end

-- The panel rebuilds its rows on every store change while it is shown, so a sent claim leaves the list at once.
function Mail.CreatePanel(mail)
    local function displayItem(wish)
        if wish.item then return wish.item end
        local name = strtrim(wish.name):lower()
        local results = ns.Items.Search(strtrim(wish.name), 50)
        if #results >= 50 then return nil end
        local match
        for _, item in ipairs(results) do
            if item.name:lower() == name then
                if match then return nil end
                match = item.id
            end
        end
        return match
    end

    -- The panel uses the mailbox's own frame style, so the two read as one window.
    local panel = CreateFrame("Frame", "CommunityWishListMailPanel", MailFrame or UIParent, "ButtonFrameTemplate")
    panel:ClearAllPoints()
    panel:SetSize(300, 260)
    if MailFrame then panel:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 0, 0) end
    if ButtonFrameTemplate_HidePortrait then ButtonFrameTemplate_HidePortrait(panel) end
    if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(panel) end
    if panel.CloseButton then panel.CloseButton:Hide() end
    panel.Inset:ClearAllPoints()
    panel.Inset:SetPoint("TOPLEFT", 4, -24)
    panel.Inset:SetPoint("BOTTOMRIGHT", -6, 6)
    panel:SetTitle("Wishes to send")
    panel:Hide()

    local empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("TOPLEFT", 14, -34)
    empty:SetText("Nothing to send.")
    panel.empty = empty

    local rows = {}
    local function row(i)
        if rows[i] then return rows[i] end
        local r = CreateFrame("Frame", nil, panel)
        r:SetSize(276, 28)
        local divider = r:CreateTexture(nil, "BACKGROUND")
        divider:SetPoint("BOTTOMLEFT")
        divider:SetPoint("BOTTOMRIGHT")
        divider:SetHeight(1)
        divider:SetColorTexture(0.65, 0.53, 0.33, 0.22)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(20, 20)
        r.icon:SetPoint("LEFT", 0, 0)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
        r.text:SetPoint("RIGHT", -78, 0)
        r.text:SetJustifyH("LEFT")
        r.text:SetWordWrap(false)
        r.button = ns.Button(r, "Mail it")
        r.button:SetPoint("RIGHT", 0, 0)
        rows[i] = r
        return r
    end

    local headers = {}
    function panel.Refresh()
        for _, r in ipairs(rows) do r:Hide() end
        for _, h in ipairs(headers) do h:Hide() end
        local groups = mail:ClaimsToSend()
        panel.empty:SetShown(#groups == 0)
        local y, n = -34, 0
        for g, group in ipairs(groups) do
            local header = headers[g]
            if not header then
                header = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                headers[g] = header
            end
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", 12, y)
            header:SetText(ns.ShortName(group.recipient))
            header:Show()
            y = y - 16
            for _, entry in ipairs(group.claims) do
                n = n + 1
                local r = row(n)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", 12, y)
                local item = displayItem(entry.wish)
                r.icon:SetTexture(ns.Items.Icon(item) or "Interface\\Icons\\INV_Misc_Note_01")
                r.icon:Show()
                r.text:ClearAllPoints()
                r.text:SetPoint("LEFT", r, "LEFT", 24, 0)
                r.text:SetPoint("RIGHT", -78, 0)
                local quality = ns.Items.Quality(item)
                local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
                local name = ns.Items.Link(item) or (color and color.hex .. entry.wish.name .. "|r") or entry.wish.name
                r.text:SetText(("%d x %s"):format(entry.claim.qty, name or "?"))
                r.button:SetScript("OnClick", function() mail:Prepare(entry.wish.id, entry.claim.id) end)
                r:Show()
                y = y - 32
            end
        end
        -- The panel is as tall as the mailbox, and grows past it only when the list needs the room.
        panel:SetHeight(math.max(MailFrame and MailFrame:GetHeight() or 0, 80, -y + 12))
    end

    mail.store:OnChange(function()
        if panel:IsShown() then panel.Refresh() end
    end)
    panel:SetScript("OnShow", function()
        if not MailFrame then
            panel:Hide()
            return
        end
        if panel:GetParent() ~= MailFrame then
            panel:SetParent(MailFrame)
            panel:ClearAllPoints()
            panel:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 0, 0)
        end
        panel.Refresh()
    end)
    mail.panel = panel
    return panel
end
