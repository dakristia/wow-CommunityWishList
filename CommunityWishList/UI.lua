local _, ns = ...

local UI = {}
ns.UI = UI
local store, settings, frame
local pool = {}
local refresh
local tabs = { "wishes", "mine", "claims", "groups" }
local tabNames = { wishes = "Wishes", mine = "My wishes", claims = "My claims", groups = "Groups" }
local priorities = { "Low", "Normal", "Urgent" }
local questionMark = "Interface\\Icons\\INV_Misc_QuestionMark"
local neutralIcon = "Interface\\Icons\\INV_Misc_Note_01"
local contentWidth = 680
local stateColors = { open = "ffffffff", sent = "ff66dd88", received = "ff77bbff" }
local emptyText = {
    wishes = "No wishes from your guild yet.",
    mine = "You have no wishes. Add one above.",
    claims = "You have not claimed anything.",
}

local function section(parent)
    local panel = CreateFrame("Frame", nil, parent, "CollectionsBackgroundTemplate")
    panel:ClearAllPoints()
    return panel
end

local button = ns.Button

-- The dropdown look has an arrow, so only buttons that pick from a list use it.
local function dropdownButton(parent, text, width)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 70, 22)
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    b:SetDisabledFontObject(GameFontDisableSmall)
    b:SetNormalAtlas("common-dropdown-b-button")
    b:SetPushedAtlas("common-dropdown-b-button-pressed")
    b:SetDisabledAtlas("common-dropdown-b-button-disabled")
    -- The hover atlas is a whole opaque button, so it swaps in for the normal art.
    -- As a highlight texture it would draw above the label and hide it.
    b:SetScript("OnEnter", function(self) self:GetNormalTexture():SetAtlas("common-dropdown-b-button-hover") end)
    b:SetScript("OnLeave", function(self) self:GetNormalTexture():SetAtlas("common-dropdown-b-button") end)
    b:SetText(text)
    return b
end

local function itemTooltip(owner, id)
    if not id or not GameTooltip then return end
    local link = ns.Items.Link(id)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if link and GameTooltip.SetHyperlink then
        GameTooltip:SetHyperlink(link)
    elseif GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(id)
    else
        return
    end
    GameTooltip:Show()
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
    if copper <= 0 then return "" end
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    local coins = {}
    for _, coin in ipairs({ { 10000, "Gold" }, { 100, "Silver" }, { 1, "Copper" } }) do
        local amount = math.floor(copper / coin[1])
        if amount > 0 then
            coins[#coins + 1] = amount .. "|TInterface\\MoneyFrame\\UI-" .. coin[2] .. "Icon:0|t"
        end
        copper = copper % coin[1]
    end
    return table.concat(coins, " ")
end

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

local function itemText(wish, item)
    local link = ns.Items.Link(item)
    if link and link ~= "" then return link end
    local quality = ns.Items.Quality(item)
    local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color then return color.hex .. wish.name .. "|r" end
    return wish.name
end

local function matchesSearch(wish)
    local query = strtrim(frame.search:GetText()):lower()
    return query == "" or wish.name:lower():find(query, 1, true)
        or ns.ShortName(wish.owner):lower():find(query, 1, true)
        or (wish.note or ""):lower():find(query, 1, true)
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
        row:EnableMouse(true)
        row.background = row:CreateTexture(nil, "BACKGROUND")
        row.background:SetPoint("BOTTOMLEFT", 8, 0)
        row.background:SetPoint("BOTTOMRIGHT", -8, 0)
        row.background:SetHeight(1)
        row.background:SetColorTexture(0.65, 0.53, 0.33, 0.22)
        row.itemButton = CreateFrame("Button", nil, row)
        row.itemButton:SetSize(32, 32)
        row.itemButton:SetPoint("TOPLEFT", 8, -8)
        row.icon = row.itemButton:CreateTexture(nil, "ARTWORK")
        row.icon:SetAllPoints()
        row.itemButton.icon = row.icon
        row.itemButton.border = row.itemButton:CreateTexture(nil, "OVERLAY")
        row.itemButton.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        row.itemButton.border:SetBlendMode("ADD")
        row.itemButton.border:SetSize(56, 56)
        row.itemButton.border:SetPoint("CENTER")
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.detail:SetJustifyH("LEFT")
        row.detail:SetWordWrap(false)
        row.detail:SetTextColor(0.72, 0.72, 0.72)
        row.priority = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.priority:SetPoint("TOPRIGHT", -8, -5)
        row.gold = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.gold:SetPoint("TOPRIGHT", -8, -19)
        row.buttonPool = {}
        row.itemButton:SetScript("OnEnter", function(self) itemTooltip(self, row.displayItem) end)
        row.itemButton:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        row.itemButton:SetScript("OnClick", function()
            if row.displayItem and HandleModifiedItemClick then
                local link = ns.Items.Link(row.displayItem)
                if link then HandleModifiedItemClick(link) end
            end
        end)
        pool[index] = row
    end
    for _, b in pairs(row.buttonPool) do b:Hide() end
    row.buttons = {}
    row.wishId, row.claimId = wish.id, claim and claim.id or nil
    row.displayItem = nil
    if not claim then row.displayItem = displayItem(wish) end
    row:ClearAllPoints()
    row:SetHeight(claim and 24 or 48)
    row:SetPoint("TOPLEFT", frame.scrollChild, "TOPLEFT", claim and 44 or 0, -frame.rowHeight)
    row:SetPoint("TOPRIGHT", frame.scrollChild, "TOPRIGHT", 0, -frame.rowHeight)
    frame.rowHeight = frame.rowHeight + row:GetHeight() + (claim and 0 or 4)
    row.actionWidth = 0
    row.metaWidth = not claim and ((wish.gold or 0) > 0 and 100 or wish.prio ~= 2 and 48 or 0) or 0
    row.label:ClearAllPoints()
    row.label:SetFontObject(claim and GameFontNormalSmall or GameFontHighlight)
    row.label:SetTextColor(claim and 0.72 or 1, claim and 0.72 or 1, claim and 0.72 or 1)
    local textLeft = not claim and 48 or 8
    row.label:SetPoint("TOPLEFT", row, "TOPLEFT", textLeft, claim and -6 or -7)
    row.label:SetPoint("TOPRIGHT", -row.metaWidth - 8, claim and -6 or -7)
    row.detail:ClearAllPoints()
    row.detail:SetPoint("TOPLEFT", textLeft, -27)
    row.detail:SetPoint("TOPRIGHT", (wish.gold or 0) > 0 and -108 or -8, -27)
    row.detail:SetShown(not claim)
    row.priority:ClearAllPoints()
    row.priority:SetPoint("TOPRIGHT", row, "TOPRIGHT", -12, -5)
    row.gold:ClearAllPoints()
    row.gold:SetPoint("TOPRIGHT", row, "TOPRIGHT", -12, -21)
    row.priority:SetShown(not claim)
    row.gold:SetShown(not claim)
    row.background:SetShown(not claim)
    local icon = not claim and (ns.Items.Icon(row.displayItem) or neutralIcon) or nil
    row.icon:SetTexture(icon)
    row.itemButton:SetShown(not claim)
    local quality = ns.Items.Quality(row.displayItem)
    local color = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    row.itemButton.border:SetShown(color ~= nil and color ~= false)
    if color then row.itemButton.border:SetVertexColor(color.r, color.g, color.b) end
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
    b:ClearAllPoints()
    b:SetPoint("RIGHT", row, "RIGHT", -row.actionWidth - 6, 0)
    row.actionWidth = row.actionWidth + b:GetWidth() + 4
    row.label:SetPoint("TOPRIGHT", -row.actionWidth - row.metaWidth - 8, row.claimId and -6 or -7)
    local wish = store:Get(row.wishId)
    row.detail:SetPoint("TOPRIGHT", -row.actionWidth - ((wish.gold or 0) > 0 and 108 or 8), -27)
    row.priority:ClearAllPoints()
    row.priority:SetPoint("TOPRIGHT", row, "TOPRIGHT", -row.actionWidth - 12, -5)
    row.gold:ClearAllPoints()
    row.gold:SetPoint("TOPRIGHT", row, "TOPRIGHT", -row.actionWidth - 12, -21)
    b:SetScript("OnClick", function()
        local result, reason = fn()
        frame.error:SetText(result and "" or reason or "")
    end)
    b:Show()
    row.buttons[key] = b
end

local function wishRow(wish)
    local row = rowFor(wish)
    row.label:SetText(itemText(wish, row.displayItem))
    row.detail:SetText(store:Remaining(wish) .. " of " .. wish.qty .. " wanted · " .. ns.ShortName(wish.owner)
        .. (wish.note and wish.note ~= "" and " · " .. wish.note or ""))
    row.priority:SetText(wish.prio == 3 and "|cffff7777Urgent|r" or wish.prio == 1 and "|cffaaaaaaLow|r" or "")
    row.gold:SetText(money(wish.gold))
    row.gold:SetShown((wish.gold or 0) > 0)
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
    frame.rowHeight = 0
    local tab = settings.tab
    PanelTemplates_SetTab(frame, frame.tabs[tab]:GetID())
    frame.addForm:SetShown(tab == "mine")
    frame.groups:SetShown(tab == "groups")
    frame.scrollFrame:SetShown(tab ~= "groups")
    frame.search:SetShown(tab ~= "groups")
    frame.scrollFrame:ClearAllPoints()
    frame.scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -frame.contentTop - (tab == "mine" and 156 or 0))
    frame.scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -56, frame.contentBottom)
    if tab == "wishes" then
        local wishes = store:List({ state = "open" })
        -- Wishes uses two passes so each remaining-quantity group keeps the store's order.
        for pass = 1, 2 do
            for _, wish in ipairs(wishes) do
                if wish.owner ~= store.me and matchesSearch(wish) and ((store:Remaining(wish) > 0) == (pass == 1)) then
                    local row = wishRow(wish)
                    action(row, "claim", "Claim", function() showClaim(wish); return true end)
                end
            end
        end
    elseif tab == "mine" or tab == "claims" then
        local wishes = store:List(tab == "mine" and { owner = store.me } or { claimer = store.me })
        for _, wish in ipairs(wishes) do
            if matchesSearch(wish) then
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
                        claimRow.label:SetText(ns.ShortName(claim.by) .. " · " .. claim.qty .. " · |c"
                            .. (stateColors[claim.state] or "ff999999") .. claim.state .. "|r · " .. age(claim.created))
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
    end
    frame.scrollChild:SetHeight(math.max(1, frame.rowHeight))
    frame.empty:SetText(emptyText[tab] or "")
    frame.empty:SetShown(tab ~= "groups" and #frame.rows == 0)
    local open, claimed = 0, 0
    for _, wish in ipairs(store:List()) do
        if wish.state == "open" then open = open + 1 end
        for _, claim in pairs(wish.claims) do
            if claim.by == store.me and (claim.state == "open" or claim.state == "sent") then claimed = claimed + 1 end
        end
    end
    frame.status:SetText(open .. (open == 1 and " open wish" or " open wishes") .. " · "
        .. claimed .. (claimed == 1 and " claim by you" or " claims by you"))
end

local function addWish()
    local form = frame.addForm
    local text = strtrim(form.item:GetText())
    local item, name = ns.Items.Resolve(form.selectedItem and ns.Items.Link(form.selectedItem) or text)
    if not item then
        form.error:SetText("Pick an item from the list, or shift-click an item link.")
        return
    end
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
        form.selectedItem = nil
        form.itemIcon.icon:SetTexture(questionMark)
        form.suggestions:Hide()
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
    form:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -frame.contentTop)
    form:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -56, -frame.contentTop)
    form:SetHeight(146)
    local slotSize, slotGap = 28, 12
    local textLeft = slotSize + slotGap
    local leftWidth, rightWidth, gap = contentWidth - 196 - 24 - textLeft, 196, 24
    form.item = editBox(form, "Item", textLeft, -20, leftWidth)
    form.itemIcon = CreateFrame("Button", nil, form)
    form.itemIcon:SetSize(slotSize, slotSize)
    form.itemIcon:SetPoint("RIGHT", form.item, "LEFT", -slotGap, 0)
    form.itemIcon.icon = form.itemIcon:CreateTexture(nil, "ARTWORK")
    form.itemIcon.icon:SetAllPoints()
    form.itemIcon.icon:SetTexture(questionMark)
    form.itemIcon:SetScript("OnEnter", function(self) itemTooltip(self, form.selectedItem) end)
    form.itemIcon:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    local suggestions = CreateFrame("Frame", nil, form, "BackdropTemplate")
    form.suggestions = suggestions
    suggestions:SetPoint("TOPLEFT", form.item, "BOTTOMLEFT", 0, -2)
    suggestions:SetWidth(leftWidth)
    suggestions:SetFrameLevel(form:GetFrameLevel() + 10)
    suggestions:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    suggestions:SetBackdropColor(0.16, 0.11, 0.06, 1)
    suggestions:EnableMouse(true)
    suggestions.rows = {}
    local function selectItem(id)
        local resolved, name = ns.Items.Resolve(ns.Items.Link(id))
        if not resolved then return end
        form.selectedItem = resolved
        form.item:SetText(name)
        form.itemIcon.icon:SetTexture(ns.Items.Icon(resolved) or questionMark)
        suggestions:Hide()
        form.error:SetText("")
    end
    for i = 1, 8 do
        local row = CreateFrame("Button", nil, suggestions)
        row:SetSize(leftWidth, 28)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * 28)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.icon:SetPoint("LEFT", 2, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.name:SetPoint("LEFT", 30, 0)
        row.name:SetPoint("RIGHT", -4, 0)
        row.name:SetJustifyH("LEFT")
        row:SetScript("OnClick", function(self) selectItem(self.itemID) end)
        suggestions.rows[i] = row
    end
    suggestions:Hide()
    form.item:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        form.selectedItem = nil
        form.itemIcon.icon:SetTexture(questionMark)
        local results = ns.Items.Search(self:GetText())
        for i, row in ipairs(suggestions.rows) do
            local item = results[i]
            row.itemID = item and item.id or nil
            row:SetShown(item ~= nil)
            if item then
                row.icon:SetTexture(ns.Items.Icon(item.id) or questionMark)
                row.name:SetText(item.name)
                local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[item.quality]
                row.name:SetTextColor(color and color.r or 1, color and color.g or 1, color and color.b or 1)
            end
        end
        suggestions:SetHeight(math.max(1, #results * 28))
        suggestions:SetShown(#results > 0)
    end)
    form.item:SetScript("OnEnterPressed", function(self)
        if suggestions:IsShown() then selectItem(suggestions.rows[1].itemID) else self:ClearFocus() end
    end)
    form.item:SetScript("OnEscapePressed", function(self) suggestions:Hide(); self:ClearFocus() end)
    -- The list hides a moment later, so a click on a suggestion lands before the list goes away.
    form.item:SetScript("OnEditFocusLost", function()
        C_Timer.After(0.2, function() if not form.item:HasFocus() then suggestions:Hide() end end)
    end)
    form.qty = editBox(form, "Quantity", textLeft + leftWidth + gap, -20, rightWidth)
    form.note = editBox(form, "Note", textLeft, -62, leftWidth)
    form.note:SetMaxLetters(120)
    form.gold = editBox(form, "Gold", textLeft + leftWidth + gap, -62, rightWidth)
    form.prio = dropdownButton(form, "Normal", 72)
    form.prio:SetPoint("TOPLEFT", 0, -96)
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
    form.add:SetPoint("TOPRIGHT", 0, -96)
    form.add:SetScript("OnClick", addWish)
    form.error = errorText(form)
    form.error:SetPoint("TOPLEFT", 0, -124)
    form.error:SetPoint("TOPRIGHT", 0, -124)
    local divider = form:CreateTexture(nil, "BACKGROUND")
    divider:SetColorTexture(0.65, 0.53, 0.33, 0.3)
    divider:SetHeight(1)
    divider:SetPoint("BOTTOMLEFT")
    divider:SetPoint("BOTTOMRIGHT")
    local function receiveItem()
        local kind, id = GetCursorInfo()
        if kind == "item" then
            selectItem(id)
            ClearCursor()
        end
    end
    form.item:SetScript("OnReceiveDrag", receiveItem)
    form.item:SetScript("OnMouseUp", receiveItem)
    if ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", function(link)
            if form:IsVisible() and form.item:HasFocus() then
                local id = ns.Items.Resolve(link)
                if id then selectItem(id) end
                return
            end
        end)
    end
    frame.addForm = form
end

local function createFrame()
    frame = CreateFrame("Frame", "CommunityWishListFrame", UIParent, "PortraitFrameTemplate")
    frame:SetSize(760, 520)
    frame:SetPoint(settings.point, UIParent, settings.point, settings.x, settings.y)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("DIALOG")
    frame:EnableMouse(true)
    frame:SetPortraitToAsset("Interface\\Icons\\INV_Misc_Note_01")
    frame:SetTitle("Community Wish List")
    frame.title = frame:GetTitleText()
    frame.Inset = section(frame)
    frame.Inset:SetFrameLevel(frame:GetFrameLevel())
    frame.Inset:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -60)
    frame.Inset:SetPoint("BOTTOMRIGHT", -6, 38)
    local corner = C_Texture.GetAtlasInfo("collections-background-corner")
    local cornerHeight = corner and corner.height or frame.Inset.BGCornerTopLeft:GetHeight()
    frame.contentTop = math.max(132, 60 + cornerHeight + 8)
    frame.contentBottom = math.max(64, 38 + cornerHeight + 8)
    local titleBar = frame.TitleContainer
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, _, x, y = frame:GetPoint()
        settings.point, settings.x, settings.y = point, x, y
    end)
    UISpecialFrames[#UISpecialFrames + 1] = "CommunityWishListFrame"
    frame.tabs = {}
    for i, tab in ipairs(tabs) do
        local b = CreateFrame("Button", "CommunityWishListFrameTab" .. i, frame, "PanelTopTabButtonTemplate")
        b:SetID(i)
        b:SetText(tabNames[tab])
        if i == 1 then
            b:SetPoint("TOPLEFT", frame, "TOPLEFT", 58, -28)
        else
            b:SetPoint("LEFT", frame.tabs[tabs[i - 1]], "RIGHT", 0, 0)
        end
        b:SetScript("OnClick", function() UI.Show(tab) end)
        frame.tabs[tab] = b
    end
    PanelTemplates_SetNumTabs(frame, #tabs)
    frame.search = CreateFrame("EditBox", "CommunityWishListFrameSearch", frame, "SearchBoxTemplate")
    frame.search:SetSize(170, 22)
    frame.search:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -35)
    frame.search:SetScript("OnTextChanged", function(self)
        SearchBoxTemplate_OnTextChanged(self)
        if frame:IsShown() then refresh() end
    end)
    frame.scrollFrame = CreateFrame("ScrollFrame", nil, frame)
    frame.scrollFrame:EnableMouseWheel(true)
    frame.scrollFrame.ScrollBar = CreateFrame("EventFrame", nil, frame.scrollFrame, "WowTrimScrollBar")
    frame.scrollFrame.ScrollBar:SetPoint("TOPLEFT", frame.scrollFrame, "TOPRIGHT", 4, 0)
    frame.scrollFrame.ScrollBar:SetPoint("BOTTOMLEFT", frame.scrollFrame, "BOTTOMRIGHT", 4, 0)
    ScrollUtil.InitScrollFrameWithScrollBar(frame.scrollFrame, frame.scrollFrame.ScrollBar)
    frame.scrollChild = CreateFrame("Frame", nil, frame.scrollFrame)
    frame.scrollChild:SetSize(contentWidth, 1)
    frame.scrollFrame:SetScrollChild(frame.scrollChild)
    frame.rows = {}
    frame.empty = frame.scrollFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.empty:SetPoint("TOP", 0, -24)
    frame.groups = CreateFrame("Frame", nil, frame)
    frame.groups:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -frame.contentTop)
    frame.groups:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -56, frame.contentBottom)
    frame.groups.placeholder = frame.groups:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.groups.placeholder:SetPoint("CENTER")
    frame.groups.placeholder:SetText("Groups come in a later version.")
    frame.error = errorText(frame)
    frame.error:SetPoint("BOTTOMLEFT", 24, 10)
    frame.error:SetPoint("BOTTOMRIGHT", -56, 10)
    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.status:SetPoint("BOTTOMLEFT", 24, 26)
    frame.status:SetPoint("BOTTOMRIGHT", -56, 26)
    frame.status:SetJustifyH("LEFT")
    frame.status:SetTextColor(0.8, 0.72, 0.55)
    createForm()
    local popup = section(frame)
    popup:SetFrameLevel(frame:GetFrameLevel() + 20)
    popup:EnableMouse(true)
    popup:SetPoint("CENTER")
    popup:SetSize(300, 82)
    popup.qty = editBox(popup, "Claim quantity", 16, -28, 100)
    popup.ok = button(popup, "OK", 60)
    popup.ok:SetPoint("LEFT", popup.qty, "RIGHT", 8, 0)
    popup.cancel = button(popup, "Cancel")
    popup.cancel:SetPoint("LEFT", popup.ok, "RIGHT", 8, 0)
    popup.error = errorText(popup)
    popup.error:SetPoint("TOPLEFT", 16, -58)
    popup.error:SetPoint("TOPRIGHT", -16, -58)
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
    if settings.tab == "wanted" then settings.tab = "wishes" end
    if not tabNames[settings.tab] then settings.tab = "wishes" end
    settings.minimap = settings.minimap or {}
    if frame then
        frame:Hide()
        frame.search:SetText("")
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
