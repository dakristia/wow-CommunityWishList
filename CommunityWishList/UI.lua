local _, ns = ...

local UI = {}
ns.UI = UI
local store, settings, frame
local pool = {}
local refresh
local tabs = { "wanted", "mine", "claims", "groups" }
local tabNames = { wanted = "Wanted", mine = "My wishes", claims = "My claims", groups = "Groups" }
local priorities = { "Low", "Normal", "Urgent" }
local questionMark = "Interface\\Icons\\INV_Misc_QuestionMark"

local function button(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 70, 22)
    b:SetText(text)
    return b
end

local function editBox(parent, label, x, y, width)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 22)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    box:SetAutoFocus(false)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    local caption = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caption:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 0, 2)
    caption:SetText(label)
    return box
end

local function errorText(parent)
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetTextColor(1, 0.2, 0.2)
    text:SetJustifyH("LEFT")
    text:SetText("")
    return text
end

local function money(copper)
    copper = copper or 0
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    return ("%dg %ds %dc"):format(math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local function itemText(wish)
    if wish.item then
        local _, link = C_Item.GetItemInfo(wish.item)
        if link and link ~= "" then return link end
    end
    return wish.name
end

local function age(created)
    local seconds = math.max(0, time() - created)
    if seconds >= 86400 then return math.floor(seconds / 86400) .. "d" end
    if seconds >= 3600 then return math.floor(seconds / 3600) .. "h" end
    return math.floor(seconds / 60) .. "m"
end

local function sortedClaims(wish)
    local claims = {}
    for _, claim in pairs(wish.claims) do claims[#claims + 1] = claim end
    table.sort(claims, function(a, b)
        if a.created == b.created then return a.id < b.id end
        return a.created < b.created
    end)
    return claims
end

local function rowFor(wish, claim)
    local index = #frame.rows + 1
    local row = pool[index]
    if not row then
        row = CreateFrame("Frame", nil, frame.scrollChild)
        row:SetHeight(66)
        row:EnableMouse(true)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.icon:SetPoint("TOPLEFT", 0, -4)
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.label:SetPoint("TOPLEFT", 30, -4)
        row.label:SetPoint("TOPRIGHT", -4, -4)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(true)
        row.buttonPool = {}
        row:SetScript("OnEnter", function(self)
            local current = store:Get(self.wishId)
            if current and current.item and GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(current.item)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        pool[index] = row
    end
    for _, b in pairs(row.buttonPool) do b:Hide() end
    row.buttons = {}
    row.wishId, row.claimId = wish.id, claim and claim.id or nil
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", frame.scrollChild, "TOPLEFT", claim and 18 or 0, -(index - 1) * 66)
    row:SetPoint("TOPRIGHT", frame.scrollChild, "TOPRIGHT", 0, -(index - 1) * 66)
    local icon = questionMark
    if wish.item then
        local _, _, _, _, texture = C_Item.GetItemInfoInstant(wish.item)
        icon = texture or icon
    end
    row.icon:SetTexture(icon)
    row.icon:SetShown(not claim)
    row:Show()
    frame.rows[index] = row
    return row
end

local function action(row, key, text, fn)
    local b = row.buttonPool[key]
    if not b then
        b = button(row, text, text == "Mark sent" and 82 or 68)
        row.buttonPool[key] = b
    end
    local count = 0
    for _ in pairs(row.buttons) do count = count + 1 end
    b:ClearAllPoints()
    b:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -count * 88, 2)
    b:SetScript("OnClick", function()
        local result, reason = fn()
        frame.error:SetText(result and "" or reason or "")
    end)
    b:Show()
    row.buttons[key] = b
end

local function wishRow(wish)
    local row = rowFor(wish)
    row.label:SetText((wish.prio == 3 and "|cffff5555Urgent!|r " or "") .. itemText(wish)
        .. "  " .. store:Remaining(wish) .. " / " .. wish.qty .. "  " .. ns.ShortName(wish.owner)
        .. "  " .. money(wish.gold) .. "\n" .. (wish.note or ""))
    return row
end

local function showClaim(wish)
    local popup = frame.claimPopup
    popup.wishId = wish.id
    popup.qty:SetText(tostring(store:Remaining(wish)))
    popup.error:SetText("")
    popup:Show()
    popup.qty:SetFocus()
end

refresh = function()
    for _, row in ipairs(pool) do row:Hide() end
    frame.rows = {}
    local tab = settings.tab
    for key, b in pairs(frame.tabs) do
        if key == tab then b:LockHighlight() else b:UnlockHighlight() end
    end
    frame.addForm:SetShown(tab == "mine")
    frame.groups:SetShown(tab == "groups")
    frame.scrollFrame:SetShown(tab ~= "groups")
    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, tab == "mine" and -200 or -64)
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 66)
    if tab == "wanted" then
        local wishes = store:List({ state = "open" })
        -- Wanted uses two passes so each remaining-quantity group keeps the store's order.
        for pass = 1, 2 do
            for _, wish in ipairs(wishes) do
                if wish.owner ~= store.me and ((store:Remaining(wish) > 0) == (pass == 1)) then
                    local row = wishRow(wish)
                    action(row, "claim", "Claim", function() showClaim(wish); return true end)
                end
            end
        end
    elseif tab == "mine" or tab == "claims" then
        local wishes = store:List(tab == "mine" and { owner = store.me } or { claimer = store.me })
        for _, wish in ipairs(wishes) do
            local row = wishRow(wish)
            if tab == "mine" then
                if wish.state == "open" then
                    action(row, "close", "Close", function() return store:CloseWish(wish.id) end)
                end
                action(row, "delete", "Delete", function() return store:DeleteWish(wish.id) end)
            end
            for _, claim in ipairs(sortedClaims(wish)) do
                if tab == "mine" or claim.by == store.me then
                    local claimRow = rowFor(wish, claim)
                    claimRow.label:SetText(ns.ShortName(claim.by) .. "  " .. claim.qty .. "  " .. claim.state .. "  " .. age(claim.created))
                    if tab == "mine" and claim.state == "open" then
                        action(claimRow, "release", "Release", function() return store:ReleaseClaim(wish.id, claim.id) end)
                    elseif tab == "mine" and claim.state == "sent" then
                        action(claimRow, "received", "Received", function() return store:MarkReceived(wish.id, claim.id) end)
                    elseif tab == "claims" and claim.state == "open" then
                        action(claimRow, "sent", "Mark sent", function() return store:MarkSent(wish.id, claim.id) end)
                        action(claimRow, "cancel", "Cancel", function() return store:CancelClaim(wish.id, claim.id) end)
                    end
                end
            end
        end
    end
    frame.scrollChild:SetHeight(math.max(1, #frame.rows * 66))
end

local function addWish()
    local form = frame.addForm
    local text = strtrim(form.item:GetText())
    local item = tonumber(text:match("|Hitem:(%d+)"))
    local name, link
    if text ~= "" then
        if not item then item = C_Item.GetItemInfoInstant(text) end
        name, link = C_Item.GetItemInfo(item or text)
        if not item and link then item = tonumber(link:match("|Hitem:(%d+)")) end
    end
    if not name or name == "" then name = text:match("|h%[(.-)%]|h") or text end
    local goldText = strtrim(form.gold:GetText())
    local gold = goldText == "" and 0 or tonumber(goldText)
    if not gold then
        form.error:SetText("invalid gold")
        return
    end
    local wish, reason = store:AddWish({
        item = item, name = name, qty = tonumber(form.qty:GetText()),
        note = form.note:GetText(), gold = gold and math.floor(gold * 10000 + 0.5),
        prio = form.prio.value, guild = not not form.guild:GetChecked(),
    })
    form.error:SetText(wish and "" or reason)
    if wish then
        form.item:SetText("")
        form.qty:SetText("")
        form.note:SetText("")
        form.gold:SetText("")
        form.prio.value = 2
        form.prio:SetText(priorities[2])
        form.item:ClearFocus()
    end
end

local function createForm()
    local form = CreateFrame("Frame", nil, frame)
    form:SetPoint("TOPLEFT", 16, -64)
    form:SetSize(480, 130)
    form.item = editBox(form, "Item", 0, -16, 300)
    form.qty = editBox(form, "Quantity", 316, -16, 66)
    form.note = editBox(form, "Note", 0, -58, 300)
    form.note:SetMaxLetters(120)
    form.gold = editBox(form, "Gold", 316, -58, 66)
    form.prio = button(form, "Normal", 72)
    form.prio:SetPoint("TOPLEFT", 0, -86)
    form.prio.value = 2
    form.prio:SetScript("OnClick", function(self)
        self.value = self.value % 3 + 1
        self:SetText(priorities[self.value])
    end)
    form.guild = CreateFrame("CheckButton", nil, form, "UICheckButtonTemplate")
    form.guild:SetSize(24, 24)
    form.guild:SetPoint("LEFT", form.prio, "RIGHT", 10, 0)
    form.guild:SetChecked(true)
    local label = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", form.guild, "RIGHT", 0, 0)
    label:SetText("Guild")
    form.add = button(form, "Add")
    form.add:SetPoint("TOPRIGHT", -8, -86)
    form.add:SetScript("OnClick", addWish)
    form.error = errorText(form)
    form.error:SetPoint("TOPLEFT", 0, -112)
    form.error:SetPoint("TOPRIGHT", 0, -112)
    local function receiveItem()
        local kind, id, link = GetCursorInfo()
        if kind == "item" then
            form.item:SetText(link or ("|Hitem:%d|h[Item %d]|h"):format(id, id))
            ClearCursor()
        end
    end
    form.item:SetScript("OnReceiveDrag", receiveItem)
    form.item:SetScript("OnMouseUp", receiveItem)
    if ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", function(link)
            if form:IsVisible() and form.item:HasFocus() then
                form.item:SetText(link)
                return
            end
        end)
    end
    frame.addForm = form
end

local function createFrame()
    frame = CreateFrame("Frame", "CommunityWishListFrame", UIParent, "BackdropTemplate")
    frame:SetSize(520, 440)
    frame:SetPoint(settings.point, UIParent, settings.point, settings.x, settings.y)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.08, 0.08, 0.08, 0.92)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.8)
    local titleBar = CreateFrame("Frame", nil, frame)
    titleBar:SetPoint("TOPLEFT")
    titleBar:SetPoint("TOPRIGHT")
    titleBar:SetHeight(28)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, _, x, y = frame:GetPoint()
        settings.point, settings.x, settings.y = point, x, y
    end)
    frame.title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("LEFT", 10, 0)
    frame.title:SetText("Community Wish List")
    frame.title:SetTextColor(1, 0.82, 0)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() frame:Hide() end)
    UISpecialFrames[#UISpecialFrames + 1] = "CommunityWishListFrame"
    frame.tabs = {}
    for i, tab in ipairs(tabs) do
        local b = button(frame, tabNames[tab], 118)
        b:SetPoint("TOPLEFT", 12 + (i - 1) * 123, -32)
        b:SetScript("OnClick", function() UI.Show(tab) end)
        frame.tabs[tab] = b
    end
    frame.scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.scrollChild = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollChild:SetSize(474, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollChild)
    frame.rows = {}
    frame.groups = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.groups:SetPoint("CENTER")
    frame.groups:SetText("Groups come in a later version.")
    frame.error = errorText(frame)
    frame.error:SetPoint("BOTTOMLEFT", 16, 10)
    createForm()
    local popup = CreateFrame("Frame", nil, frame)
    popup:SetPoint("BOTTOMLEFT", 16, 12)
    popup:SetSize(480, 48)
    popup.qty = editBox(popup, "Claim quantity", 0, -14, 100)
    popup.ok = button(popup, "OK", 60)
    popup.ok:SetPoint("LEFT", popup.qty, "RIGHT", 8, 0)
    popup.cancel = button(popup, "Cancel")
    popup.cancel:SetPoint("LEFT", popup.ok, "RIGHT", 8, 0)
    popup.error = errorText(popup)
    popup.error:SetPoint("TOPLEFT", 0, -38)
    popup.error:SetPoint("TOPRIGHT", 0, -38)
    popup.ok:SetScript("OnClick", function()
        local claim, reason = store:Claim(popup.wishId, tonumber(popup.qty:GetText()))
        popup.error:SetText(claim and "" or reason)
        if claim then popup.qty:ClearFocus(); popup:Hide() end
    end)
    popup.cancel:SetScript("OnClick", function() popup.qty:ClearFocus(); popup:Hide() end)
    popup:Hide()
    frame.claimPopup = popup
    frame:SetScript("OnHide", function() popup:Hide() end)
    frame:Hide()
end

function UI.Attach(newStore, db)
    store = newStore
    db.ui = db.ui or {}
    settings = db.ui
    settings.point = settings.point or "CENTER"
    settings.x, settings.y = settings.x or 0, settings.y or 0
    if not tabNames[settings.tab] then settings.tab = "wanted" end
    settings.minimap = settings.minimap or {}
    settings.minimap.angle = settings.minimap.angle or 200
    if frame then
        frame:Hide()
        frame:ClearAllPoints()
        frame:SetPoint(settings.point, UIParent, settings.point, settings.x, settings.y)
    end
    store:OnChange(function()
        if store == newStore and frame and frame:IsShown() then refresh() end
    end)
end

function UI.Show(tab)
    if not store then return end
    if tabNames[tab] then settings.tab = tab end
    if not frame then createFrame() end
    frame.claimPopup:Hide()
    frame.error:SetText("")
    frame:Show()
    refresh()
end

function UI.Toggle()
    if frame and frame:IsShown() then frame:Hide() else UI.Show() end
end
