local T = CommunityWishList_Tests
local ns = CommunityWishList
local link = "|cffffffff|Hitem:2447::::::::1:::::::|h[Peacebloom]|h|r"

local function click(button)
    button:GetScript("OnClick")(button, "LeftButton")
end

local function search(frame, text)
    frame.search:SetText(text)
    -- Wowless SetText only stores text, so tests dispatch the client script explicitly.
    if _G.__wowless then frame.search:GetScript("OnTextChanged")(frame.search, true) end
end

local function setup(tab)
    local store = T.newStore("Ann-Realm", "Guild")
    local db = { ui = {} }
    ns.UI.Attach(store, db)
    ns.UI.Show(tab or "mine")
    return store, CommunityWishListFrame, db
end

local function typeItem(form, text)
    form.item:SetText(text)
    form.item:GetScript("OnTextChanged")(form.item, true)
end

T.add("UI item suggestions select a bag item and Add stores its real name", function()
    local store, frame = setup()
    local form = frame.addForm
    local slots, info, icon = C_Container.GetContainerNumSlots, C_Container.GetContainerItemInfo, C_Item.GetItemIconByID
    C_Container.GetContainerNumSlots = function(bag) return bag == 0 and 1 or 0 end
    C_Container.GetContainerItemInfo = function() return { itemID = 4537 } end
    C_Item.GetItemIconByID = function() return 134400 end
    local ok, err = pcall(function()
        typeItem(form, "banana")
        T.check(form.suggestions:IsShown())
        T.eq(form.suggestions.rows[1].itemID, 4537)
        T.eq(form.suggestions.rows[2].itemID, 4601)
        T.check(not form.suggestions.rows[3]:IsShown())
        click(form.suggestions.rows[1])
        T.eq(form.selectedItem, 4537)
        T.eq(form.item:GetText(), "Tel'Abim Banana")
        T.check(not form.suggestions:IsShown())
        T.check(form.itemIcon:IsShown())
        T.eq(form.itemIcon.icon:GetTexture(), 134400)
        form.qty:SetText("5")
        click(form.add)
        T.eq(#store:List(), 1)
        T.eq(store:List()[1].item, 4537)
        T.eq(store:List()[1].name, "Tel'Abim Banana")
        T.eq(form.selectedItem, nil)
        T.eq(form.itemIcon.icon:GetTexture(), "Interface\\Icons\\INV_Misc_QuestionMark")
    end)
    C_Container.GetContainerNumSlots, C_Container.GetContainerItemInfo, C_Item.GetItemIconByID = slots, info, icon
    T.check(ok, err)
end)

T.add("UI content clears native ornaments and fills the available width", function()
    local _, frame = setup("mine")
    local form = frame.addForm
    T.eq(frame:GetWidth(), 760)
    T.eq(frame:GetHeight(), 520)
    local _, _, _, formLeft, formTop = form:GetPoint(1)
    local cornerHeight = C_Texture.GetAtlasInfo("collections-background-corner").height
    T.check(-formTop >= 60 + cornerHeight + 8, "form clears upper ornaments")
    local _, _, _, formRight = form:GetPoint(2)
    local available = frame:GetWidth() + formRight - formLeft
    local _, _, _, itemX = form.item:GetPoint(1)
    T.check(itemX >= form.itemIcon:GetWidth(), "item box leaves room for the item slot")
    T.eq(itemX + form.item:GetWidth() + 24 + form.qty:GetWidth(), available)
    local _, _, _, qtyX = form.qty:GetPoint(1)
    T.eq(qtyX, itemX + form.item:GetWidth() + 24)
    local _, _, _, noteX = form.note:GetPoint(1)
    T.eq(noteX, itemX, "note lines up with item")
    T.eq(frame.scrollChild:GetWidth(), available)
    local _, _, _, listRight, listBottom = frame.scrollFrame:GetPoint(2)
    T.eq(listRight, formRight)
    T.check(listBottom >= 38 + cornerHeight + 8, "list and scrollbar clear lower ornaments")
    local _, _, _, _, listTop = frame.scrollFrame:GetPoint(1)
    T.eq(listTop, formTop - form:GetHeight() - 10)
    T.check(frame:GetHeight() + listTop - listBottom >= 100, "My wishes retains usable list height")
end)

T.add("UI Enter selects suggestions and editing rejects unresolved names", function()
    local store, frame = setup()
    local form = frame.addForm
    typeItem(form, "peace")
    T.check(form.suggestions:IsShown())
    form.item:GetScript("OnEnterPressed")(form.item)
    T.eq(form.selectedItem, 2447)
    typeItem(form, "unknown item")
    T.eq(form.selectedItem, nil)
    T.eq(form.itemIcon.icon:GetTexture(), "Interface\\Icons\\INV_Misc_QuestionMark")
    T.check(not form.suggestions:IsShown())
    form.qty:SetText("5")
    click(form.add)
    T.eq(#store:List(), 0)
    T.eq(form.error:GetText(), "Pick an item from the list, or shift-click an item link.")
    typeItem(form, "banana")
    form.item:GetScript("OnEscapePressed")(form.item)
    T.check(not form.suggestions:IsShown())
    typeItem(form, "banana")
    form.item:GetScript("OnEditFocusLost")(form.item)
    T.check(form.suggestions:IsShown(), "suggestions stay up briefly so a click can land")
end)

T.add("UI shift-clicking a link selects its item and icon", function()
    local store, frame = setup()
    local form = frame.addForm
    form.item:SetFocus()
    local hasFocus = form.item.HasFocus
    -- Wowless does not track edit-box focus, so the link hook needs a focused test box.
    if _G.__wowless then form.item.HasFocus = function() return true end end
    local ok, err = pcall(ChatEdit_InsertLink, link)
    form.item.HasFocus = hasFocus
    T.check(ok, err)
    T.eq(form.selectedItem, 2447)
    T.eq(form.item:GetText(), "Peacebloom")
    T.check(form.itemIcon:IsShown())
    form.qty:SetText("5")
    click(form.add)
    T.eq(store:List()[1].item, 2447)
    T.eq(store:List()[1].name, "Peacebloom")
end)

T.add("Init slash add resolves names and reports unresolved items or guild errors", function()
    local output = {}
    local printMessage = ns.Print
    ns.Print = function(format, ...) output[#output + 1] = format:format(...) end
    local count = #ns.store:List()
    local ok, err = pcall(function()
        SlashCmdList.COMMUNITYWISHLIST("add 5 unknown item")
        T.eq(#ns.store:List(), count)
        T.eq(output[1], "Pick an item from the list, or shift-click an item link.")
        SlashCmdList.COMMUNITYWISHLIST("add 5 Peacebloom")
        if GetGuildInfo("player") then
            T.eq(#ns.store:List(), count + 1)
            local found = false
            for _, wish in ipairs(ns.store:List()) do
                if wish.item == 2447 and wish.name == "Peacebloom" and wish.qty == 5 then found = true end
            end
            T.check(found)
        else
            T.eq(#ns.store:List(), count)
            T.check(output[2]:find("guild", 1, true))
        end
    end)
    ns.Print = printMessage
    T.check(ok, err)
end)

local function findRow(frame, wishId, claimId)
    for _, row in ipairs(frame.rows) do
        if row.wishId == wishId and row.claimId == claimId then
            T.check(row:IsShown(), "row is hidden")
            return row
        end
    end
    error("missing row for " .. wishId)
end

local function bobWish(store, qty)
    local bob = T.newStore("Bob-Realm", "Guild")
    local wish = assert(bob:AddWish({ name = "Peacebloom", qty = qty or 20, guild = true }))
    store:Merge(bob:Get(wish.id))
    return wish, bob
end

T.add("UI Toggle and tab buttons save the selected tab", function()
    local _, frame, db = setup("wishes")
    ns.UI.Toggle()
    T.check(not frame:IsShown())
    ns.UI.Toggle()
    T.check(frame:IsShown())
    for _, tab in ipairs({ "mine", "claims", "groups", "wishes" }) do
        click(frame.tabs[tab])
        T.eq(db.ui.tab, tab)
        T.eq(frame.addForm:IsShown(), tab == "mine")
    end
    T.eq(frame.title:GetText(), "Community Wish List")
    T.eq(db.ui.point, "CENTER")
    T.eq(frame.tabs.wishes:GetText(), "Wishes")
end)

T.add("UI header fits tabs beside search and form columns stay aligned", function()
    local _, frame = setup("mine")
    local _, _, _, tabLeft, tabTop = frame.tabs.wishes:GetPoint(1)
    local tabRight = tabLeft
    for _, key in ipairs({ "wishes", "mine", "claims", "groups" }) do
        tabRight = tabRight + frame.tabs[key]:GetWidth()
    end
    local _, _, _, searchRight = frame.search:GetPoint(1)
    local searchLeft = frame:GetWidth() + searchRight - frame.search:GetWidth()
    T.check(searchLeft - tabRight >= 16, "tab artwork must leave space before search")
    local _, _, _, _, insetTop = frame.Inset:GetPoint(1)
    T.eq(tabTop - frame.tabs.wishes:GetHeight(), insetTop, "tabs attach to the content edge")
    local form = frame.addForm
    for _, pair in ipairs({ { form.item, form.note }, { form.qty, form.gold } }) do
        local _, _, _, firstX = pair[1]:GetPoint(1)
        local _, _, _, secondX = pair[2]:GetPoint(1)
        T.eq(firstX, secondX, "field left edges align")
        T.eq(pair[1]:GetWidth(), pair[2]:GetWidth(), "field right edges align")
    end
end)

T.add("UI Add creates a quantity 20 wish and a visible row", function()
    local store, frame = setup()
    frame.addForm.item:SetText("Peacebloom")
    frame.addForm.qty:SetText("20")
    frame.addForm.note:SetText("for alchemy")
    frame.addForm.gold:SetText("1.25")
    click(frame.addForm.add)
    local wishes = store:List({ owner = "Ann-Realm" })
    T.eq(#wishes, 1, "added wishes (form error: " .. frame.addForm.error:GetText() .. ")")
    T.eq(wishes[1].name, "Peacebloom")
    T.eq(wishes[1].qty, 20)
    T.eq(wishes[1].gold, 12500)
    T.eq(wishes[1].note, "for alchemy")
    T.check(findRow(frame, wishes[1].id).label:GetText():find("Peacebloom", 1, true))
    T.eq(frame.addForm.item:GetText(), "")
    T.eq(frame.addForm.error:GetText(), "")
end)

T.add("UI Add rejects zero quantity and invalid gold without adding a wish", function()
    local store, frame = setup()
    local form = frame.addForm
    form.item:SetText("Peacebloom")
    form.qty:SetText("0")
    click(form.add)
    T.eq(#store:List(), 0)
    T.check(form.error:GetText() ~= "", "missing quantity error")
    form.qty:SetText("20")
    form.gold:SetText("invalid")
    click(form.add)
    T.eq(#store:List(), 0)
    T.eq(form.error:GetText(), "invalid gold")
    form.gold:SetText("")
end)

T.add("UI Add parses a shift-click style item link", function()
    local store, frame = setup()
    frame.addForm.item:SetText(link)
    frame.addForm.qty:SetText("20")
    click(frame.addForm.add)
    T.eq(#store:List(), 1, "linked wish (form error: " .. frame.addForm.error:GetText() .. ")")
    T.eq(store:List()[1].item, 2447)
end)

T.add("UI Wishes claims five and refreshes remaining, then marks sent", function()
    local store, frame = setup("wishes")
    local wish = bobWish(store)
    local own = assert(store:AddWish({ name = "My herb", qty = 3, guild = true }))
    T.eq(#frame.rows, 1, "Wishes excludes my wishes")
    T.check(frame.rows[1].wishId ~= own.id)
    local row = findRow(frame, wish.id)
    T.check(row.buttons.claim)
    click(row.buttons.claim)
    local popup = frame.claimPopup
    T.check(popup:IsShown())
    T.eq(popup.qty:GetText(), "20")
    popup.qty:SetText("0")
    click(popup.ok)
    T.check(popup:IsShown())
    T.check(popup.error:GetText() ~= "")
    popup.qty:SetText("5")
    click(popup.ok)
    T.check(not popup:IsShown())
    local current = store:Get(wish.id)
    local claimId, claim = next(current.claims)
    T.eq(claim.qty, 5)
    T.eq(store:Remaining(current), 15)
    T.check(findRow(frame, wish.id).detail:GetText():find("15 of 20 wanted", 1, true))
    click(frame.tabs.claims)
    local claimRow = findRow(frame, wish.id, claimId)
    T.check(claimRow.buttons.sent and claimRow.buttons.cancel)
    click(claimRow.buttons.sent)
    T.eq(store:Get(wish.id).claims[claimId].state, "sent")
    claimRow = findRow(frame, wish.id, claimId)
    T.check(claimRow.label:GetText():find("sent", 1, true))
    T.eq(claimRow.buttons.sent, nil)
    T.eq(claimRow.buttons.cancel, nil)
end)

T.add("UI claim Cancel and popup Cancel leave the expected state", function()
    local store, frame = setup("wishes")
    local wish = bobWish(store)
    click(findRow(frame, wish.id).buttons.claim)
    click(frame.claimPopup.cancel)
    T.check(not frame.claimPopup:IsShown())
    T.eq(next(store:Get(wish.id).claims), nil)
    click(findRow(frame, wish.id).buttons.claim)
    frame.claimPopup.qty:SetText("3")
    click(frame.claimPopup.ok)
    local claimId = next(store:Get(wish.id).claims)
    click(frame.tabs.claims)
    click(findRow(frame, wish.id, claimId).buttons.cancel)
    T.eq(store:Get(wish.id).claims[claimId].state, "cancelled")
end)

T.add("UI claim dialog shows the item and wisher with separate input and action rows", function()
    local store, frame = setup("wishes")
    local wish = bobWish(store)
    local row = findRow(frame, wish.id)
    click(row.buttons.claim)
    local popup = frame.claimPopup
    T.eq(popup.title:GetText(), "Claim")
    T.eq(popup.item:GetText(), row.label:GetText())
    T.eq(popup.icon:GetTexture(), row.icon:GetTexture())
    T.eq(popup.context:GetText(), "20 left · wished by " .. ns.ShortName(wish.owner))
    T.eq(popup.ok:GetText(), "Claim")
    -- Wowless stubs IsNumeric, so only the client can check the template's numeric flag.
    if not _G.__wowless then T.check(popup.qty:IsNumeric()) end
    T.eq(popup.BGCornerTopLeft, nil, "dialog does not inherit collection ornaments")
    local point, relative, relativePoint = popup:GetPoint(1)
    T.eq(point, "CENTER")
    T.eq(relative, frame)
    T.eq(relativePoint, "CENTER")
    local _, _, _, _, qtyY = popup.qty:GetPoint(1)
    local _, _, _, _, errorY = popup.error:GetPoint(1)
    local _, _, _, _, cancelY = popup.cancel:GetPoint(1)
    T.check(errorY < qtyY - popup.qty:GetHeight(), "error sits below the quantity input")
    T.check(popup:GetHeight() + errorY - popup.error:GetHeight() > cancelY + popup.cancel:GetHeight(),
        "error clears the bottom action row")
    click(popup.cancel)
end)

T.add("UI claim Max uses the current remaining quantity and Enter claims it", function()
    local store, frame = setup("wishes")
    local wish = bobWish(store)
    assert(store:Claim(wish.id, 3))
    click(findRow(frame, wish.id).buttons.claim)
    local popup = frame.claimPopup
    T.eq(popup.qty:GetText(), "17")
    T.eq(popup.context:GetText(), "17 left · wished by " .. ns.ShortName(wish.owner))
    assert(store:Claim(wish.id, 2))
    popup.qty:SetText("1")
    click(popup.max)
    T.eq(popup.qty:GetText(), "15")
    popup.qty:GetScript("OnEnterPressed")(popup.qty)
    T.check(not popup:IsShown())
    T.eq(store:Remaining(store:Get(wish.id)), 0)
    T.eq(popup.error:GetText(), "")
end)

T.add("UI claim Enter shows errors and Escape cancels without claiming", function()
    local store, frame = setup("wishes")
    local wish = bobWish(store)
    click(findRow(frame, wish.id).buttons.claim)
    local popup = frame.claimPopup
    popup.qty:SetText("21")
    popup.qty:GetScript("OnEnterPressed")(popup.qty)
    T.check(popup:IsShown())
    T.check(popup.error:GetText() ~= "")
    -- Wowless stubs GetTextColor, so only the client can check the error colour.
    if not _G.__wowless then
        local r, g, b = popup.error:GetTextColor()
        T.eq(r, 1); T.eq(g, 0.2); T.eq(b, 0.2)
    end
    popup.qty:GetScript("OnEscapePressed")(popup.qty)
    T.check(not popup:IsShown())
    T.eq(next(store:Get(wish.id).claims), nil)
    click(findRow(frame, wish.id).buttons.claim)
    T.eq(popup.error:GetText(), "")
    T.eq(popup.qty:GetText(), "20")
    click(popup.cancel)
end)

T.add("UI My wishes releases and receives claims, closes and deletes wishes", function()
    local store, frame = setup()
    local bob = T.newStore("Bob-Realm", "Guild")
    local wish = assert(store:AddWish({ name = "Herb", qty = 20, guild = true }))
    bob:Merge(wish)
    local released = assert(bob:Claim(wish.id, 2))
    local sent = assert(bob:Claim(wish.id, 3))
    assert(bob:MarkSent(wish.id, sent.id))
    store:Merge(bob:Get(wish.id))
    click(findRow(frame, wish.id, released.id).buttons.release)
    T.eq(store:Get(wish.id).claims[released.id].state, "released")
    click(findRow(frame, wish.id, sent.id).buttons.received)
    T.eq(store:Get(wish.id).claims[sent.id].state, "received")
    click(findRow(frame, wish.id).buttons.close)
    T.eq(store:Get(wish.id).state, "closed")
    click(findRow(frame, wish.id).buttons.delete)
    T.eq(store:Get(wish.id).state, "deleted")
    T.eq(#frame.rows, 0)
end)

T.add("UI Wishes puts wishes with remaining quantity before fully claimed wishes", function()
    local store, frame = setup("wishes")
    local bob = T.newStore("Bob-Realm", "Guild")
    local filled = assert(bob:AddWish({ name = "Filled", qty = 2, guild = true }))
    local open = assert(bob:AddWish({ name = "Available", qty = 4, guild = true }))
    store:Merge(filled)
    store:Merge(open)
    assert(store:Claim(filled.id, 2))
    T.eq(frame.rows[1].wishId, open.id)
    T.eq(frame.rows[2].wishId, filled.id)
end)

T.add("UI Groups shows the placeholder and hides list rows", function()
    local _, frame = setup("groups")
    T.check(frame.groups:IsShown())
    T.eq(frame.groups:GetObjectType(), "Frame")
    T.eq(frame.groups.placeholder:GetParent(), frame.groups)
    T.eq(frame.groups.placeholder:GetText(), "Groups come in a later version.")
    T.eq(#frame.rows, 0)
    T.check(not frame.scrollFrame:IsShown())
    T.check(not frame.search:IsShown())
end)

T.add("UI migrates the saved wanted tab to wishes", function()
    local store = T.newStore("Ann-Realm", "Guild")
    local db = { ui = { tab = "wanted" } }
    ns.UI.Attach(store, db)
    ns.UI.Show()
    T.eq(db.ui.tab, "wishes")
    T.eq(CommunityWishListFrame.selectedTab, 1)
    T.eq(CommunityWishListFrame:GetTitleText():GetText(), "Community Wish List")
end)

T.add("UI search filters Wishes by item name, wisher and note as text changes", function()
    local store, frame = setup("wishes")
    local wish, bob = bobWish(store)
    local other = assert(bob:AddWish({ name = "Silverleaf", qty = 10, note = "For Alchemy", guild = true }))
    store:Merge(other)
    T.check(frame.search:IsShown())
    search(frame, "PEACE")
    T.eq(#frame.rows, 1)
    T.eq(frame.rows[1].wishId, wish.id)
    search(frame, "bOb")
    T.eq(#frame.rows, 2)
    search(frame, "alchemy")
    T.eq(#frame.rows, 1)
    T.eq(frame.rows[1].wishId, other.id)
    search(frame, "no match")
    T.eq(#frame.rows, 0)
    search(frame, "")
    T.eq(#frame.rows, 2)
end)

T.add("UI search filters My wishes and My claims with their claim rows", function()
    local store, frame = setup("mine")
    local own = assert(store:AddWish({ name = "My herb", qty = 3, guild = true }))
    local wish = bobWish(store)
    local claim = assert(store:Claim(wish.id, 2))
    search(frame, "my herb")
    T.eq(#frame.rows, 1)
    T.eq(frame.rows[1].wishId, own.id)
    click(frame.tabs.claims)
    T.check(frame.search:IsShown())
    T.eq(#frame.rows, 0)
    search(frame, "peace")
    T.eq(#frame.rows, 2)
    T.eq(findRow(frame, wish.id, claim.id).claimId, claim.id)
end)

T.add("UI wish rows have item buttons with item icons and a neutral fallback", function()
    local store, frame = setup("mine")
    local getIcon = C_Item.GetItemIconByID
    local icon = getIcon(2447)
    if _G.__wowless and not icon then
        icon = 134400
        C_Item.GetItemIconByID = function(id)
            T.eq(id, 2447)
            return icon
        end
    end
    local ok, wish = pcall(store.AddWish, store, { item = 2447, name = "Peacebloom", qty = 2, prio = 1, guild = true })
    C_Item.GetItemIconByID = getIcon
    T.check(ok, wish)
    T.check(wish)
    local row = findRow(frame, wish.id)
    T.eq(row.itemButton:GetObjectType(), "Button")
    T.eq(row.itemButton:GetWidth(), 32)
    T.eq(row.itemButton:GetHeight(), 32)
    T.eq(row.itemButton.icon:GetTexture(), icon)
    T.check(row.itemButton.icon:GetTexture() ~= nil)
    T.eq(row.priority:GetText(), "|cffaaaaaaLow|r")
    local textWish = assert(store:AddWish({ name = "Unknown herb", qty = 1, guild = true }))
    local textRow = findRow(frame, textWish.id)
    T.check(textRow.itemButton:IsShown())
    T.eq(textRow.icon:GetTexture(), "Interface\\Icons\\INV_Misc_Note_01")
    T.eq(textRow.displayItem, nil)
    T.check(not textRow.itemButton.border:IsShown())
    local _, _, _, x = textRow.label:GetPoint(1)
    T.eq(x, 48, "all wishes reserve the same icon space")
    row = findRow(frame, wish.id)
    T.check(row.itemButton:IsShown(), "pooled name-only rows restore the item button for items")
    local _, _, _, itemX = row.label:GetPoint(1)
    T.eq(itemX, 48)
end)

T.add("UI legacy exact names use ItemDB presentation without changing wish identity", function()
    local store, frame = setup("mine")
    local getIcon, tooltip, modifiedClick = C_Item.GetItemIconByID, GameTooltip, HandleModifiedItemClick
    local itemLink = ns.Items.Link
    local hovered, clicked
    C_Item.GetItemIconByID = function(id) return id == 4537 and 133980 or 134400 end
    GameTooltip = {
        SetOwner = function() end, Show = function() end, Hide = function() end,
        IsOwned = function() return false end,
        SetItemByID = function(_, id) hovered = id end,
    }
    HandleModifiedItemClick = function(value) clicked = value end
    local ok, err = pcall(function()
        local wish = assert(store:AddWish({ name = "Tel'Abim Banana", qty = 3, guild = true }))
        local row = findRow(frame, wish.id)
        T.eq(row.displayItem, 4537)
        T.eq(row.icon:GetTexture(), 133980)
        T.eq(row.label:GetText(), ns.Items.Link(4537))
        T.check(row.itemButton.border:IsShown())
        local r, g, b = row.itemButton.border:GetVertexColor()
        local color = ITEM_QUALITY_COLORS[ns.Items.Quality(4537)]
        T.eq(r, color.r); T.eq(g, color.g); T.eq(b, color.b)
        row.itemButton:GetScript("OnEnter")(row.itemButton)
        click(row.itemButton)
        T.eq(hovered, 4537)
        T.eq(clicked, ns.Items.Link(4537))
        T.eq(store:Get(wish.id).item, nil, "display resolution does not change stored identity")

        ns.Items.Link = function() return nil end
        local legendary = assert(store:AddWish({ name = "Thunderfury, Blessed Blade of the Windseeker", qty = 1, guild = true }))
        T.eq(findRow(frame, legendary.id).label:GetText(), ITEM_QUALITY_COLORS[5].hex .. legendary.name .. "|r")
        ns.Items.Link = itemLink

        local unknown = assert(store:AddWish({ name = "Banana", qty = 1, guild = true }))
        search(frame, "Banana")
        search(frame, "Tel'Abim")
        local pooled = frame.rows[1]
        T.eq(pooled.displayItem, 4537)
        search(frame, "Banana")
        assert(store:DeleteWish(wish.id))
        T.eq(frame.rows[1], pooled)
        T.eq(pooled.wishId, unknown.id)
        T.eq(pooled.displayItem, nil, "partial names must not select a search result")
        T.eq(pooled.label:GetText(), "Banana")
        T.eq(pooled.icon:GetTexture(), "Interface\\Icons\\INV_Misc_Note_01")
        T.check(not pooled.itemButton.border:IsShown())
        hovered, clicked = nil, nil
        pooled.itemButton:GetScript("OnEnter")(pooled.itemButton)
        click(pooled.itemButton)
        T.eq(hovered, nil)
        T.eq(clicked, nil)

        local remote = bobWish(store)
        local claim = assert(store:Claim(remote.id, 1))
        search(frame, "")
        click(frame.tabs.claims)
        local claimRow = findRow(frame, remote.id, claim.id)
        T.eq(claimRow.displayItem, nil)
        T.check(not claimRow.itemButton:IsShown())
        click(claimRow.itemButton)
        T.eq(clicked, nil)
    end)
    C_Item.GetItemIconByID, GameTooltip, HandleModifiedItemClick = getIcon, tooltip, modifiedClick
    ns.Items.Link = itemLink
    T.check(ok, err)
end)

T.add("UI and mail display reject ambiguous truncated and unavailable name searches", function()
    local itemSearch, itemIcon = ns.Items.Search, ns.Items.Icon
    local ok, err = pcall(function()
        T.withMailFrame(function()
            local exact = { id = 38, name = "Recruit's Shirt" }
            local capped = { exact }
            for i = 2, 50 do capped[i] = { id = 1000 + i, name = "Recruit's Shirt variant " .. i } end
            local cases = {
                { results = { exact, { id = 6120, name = "RECRUIT'S SHIRT" } } },
                { results = {} },
                { results = { { id = 6120, name = "Recruit's Shirt variant" } } },
                { results = capped },
                { results = { { id = 38, name = "rEcRuIt'S sHiRt" } }, expected = 38 },
                { results = capped, explicit = 2447, expected = 2447 },
            }
            ns.Items.Icon = function(id) return id and 134400 end
            for _, case in ipairs(cases) do
                local calls = 0
                ns.Items.Search = function(name, limit)
                    calls = calls + 1
                    T.eq(name, "Recruit's Shirt")
                    T.eq(limit, 50)
                    return case.results
                end
                local store, frame = setup("mine")
                local wish = assert(store:AddWish({ name = "  Recruit's Shirt  ", item = case.explicit, qty = 1, guild = true }))
                local row = findRow(frame, wish.id)
                T.eq(row.displayItem, case.expected)
                local mail = {
                    store = store,
                    ClaimsToSend = function()
                        return { { recipient = "Ann-Realm", claims = { { wish = wish, claim = { qty = 1 } } } } }
                    end,
                }
                local panel = ns.Mail.CreatePanel(mail)
                panel:Show()
                local mailRow
                for _, child in ipairs({ panel:GetChildren() }) do
                    if child.text then mailRow = child end
                end
                T.check(mailRow)
                if case.expected then
                    T.eq(row.icon:GetTexture(), 134400)
                    T.eq(mailRow.icon:GetTexture(), 134400)
                else
                    T.eq(row.icon:GetTexture(), "Interface\\Icons\\INV_Misc_Note_01")
                    T.eq(mailRow.icon:GetTexture(), "Interface\\Icons\\INV_Misc_Note_01")
                    T.eq(row.label:GetText(), wish.name)
                    T.eq(mailRow.text:GetText(), "1 x " .. wish.name)
                    T.check(not row.itemButton.border:IsShown())
                end
                T.eq(store:Get(wish.id).item, case.explicit)
                T.eq(calls, case.explicit and 0 or 2, "explicit IDs bypass both display searches")
                panel:Hide()
            end
        end)
    end)
    ns.Items.Search, ns.Items.Icon = itemSearch, itemIcon
    T.check(ok, err)
end)

T.add("UI mail recipient headers show full names and legacy rows keep icon space", function()
    T.withMailFrame(function()
        local store = T.newStore("Ann-Realm", "Guild")
        local wish = bobWish(store)
        assert(store:Claim(wish.id, 1))
        local mail = ns.Mail.new({ store = store, me = "Ann-Realm", api = {} })
        local panel = ns.Mail.CreatePanel(mail)
        panel:Show()
        local foundHeader, foundRow = false, false
        for _, region in ipairs({ panel:GetRegions() }) do
            if region.GetText and region:GetText() == "Bob" then foundHeader = true end
        end
        for _, row in ipairs({ panel:GetChildren() }) do
            if row.text then
                foundRow = true
                T.check(row.icon:IsShown())
                T.eq(row.text:GetText(), "1 x " .. ns.Items.Link(2447))
                local _, _, _, x = row.text:GetPoint(1)
                T.eq(x, 24, "mail text indent")
            end
        end
        panel:Hide()
        T.check(foundHeader, "mail header shows the display name")
        T.check(foundRow)
    end)
end)

T.add("UI native scrollbar connects wheel and thumb movement to the list", function()
    local store, frame = setup("mine")
    local scroll = frame.scrollFrame
    local bar = scroll.ScrollBar
    local getRange = scroll.GetVerticalScrollRange
    local saturate = Saturate
    -- Wowless stubs scroll ranges and math.saturate, so native scroll wiring needs real values.
    if _G.__wowless then
        scroll.GetVerticalScrollRange = function() return 600 end
        Saturate = function(value) return math.max(0, math.min(1, value)) end
    end
    local ok, err = pcall(function()
        for i = 1, 20 do
            assert(store:AddWish({ name = "Scroll test herb " .. i, qty = 1, guild = true }))
        end
        scroll:UpdateScrollChildRect()
        local range = scroll:GetVerticalScrollRange()
        T.check(range > 0, "visible wishes must overflow the list")
        bar:SetScrollPercentage(0, true)
        scroll:GetScript("OnScrollRangeChanged")(scroll, 0, range)
        scroll:GetScript("OnMouseWheel")(scroll, -1)
        T.check(scroll:GetVerticalScroll() > 0, "mouse wheel scrolls the list")
        bar:SetScrollPercentage(0.5, true)
        T.eq(scroll:GetVerticalScroll(), range * 0.5, "thumb position scrolls the list")
        bar:SetScrollPercentage(0, true)
    end)
    scroll.GetVerticalScrollRange = getRange
    Saturate = saturate
    T.check(ok, err)
end)

T.add("UI empty states describe each list tab", function()
    local _, frame = setup("wishes")
    for _, entry in ipairs({
        { "wishes", "No wishes from your guild yet." },
        { "mine", "You have no wishes. Add one above." },
        { "claims", "You have not claimed anything." },
    }) do
        click(frame.tabs[entry[1]])
        T.eq(#frame.rows, 0)
        T.check(frame.empty:IsShown())
        T.eq(frame.empty:GetText(), entry[2])
    end
    click(frame.tabs.groups)
    T.check(not frame.empty:IsShown())
end)

T.add("UI wish cards separate quantity and note and hide zero gold", function()
    local store, frame = setup("mine")
    local wish = assert(store:AddWish({ name = "Herb", qty = 10, note = "for alchemy", gold = 0, guild = true }))
    local row = findRow(frame, wish.id)
    T.eq(row.label:GetText(), "Herb")
    T.eq(row.detail:GetText(), "10 of 10 wanted · Ann · for alchemy")
    T.eq(row:GetHeight(), 48)
    T.eq(row.gold:GetText(), "")
    T.check(not row.gold:IsShown())
    T.check(not row.detail:GetText():find("0g", 1, true))
    T.check(not frame.empty:IsShown())
    assert(store:UpdateWish(wish.id, { gold = 50000 }))
    row = findRow(frame, wish.id)
    T.check(row.gold:IsShown())
    T.check(row.gold:GetText():find("5", 1, true))
    T.check(row.gold:GetText():find("|T", 1, true), "gold uses a coin texture")
    T.eq(frame.status:GetText(), "1 open wish · 0 claims by you")
end)

T.add("UI mixed wish and claim rows use their content heights", function()
    local store, frame = setup("claims")
    local wish, bob = bobWish(store, 10)
    assert(bob:UpdateWish(wish.id, { gold = 50000, prio = 3 }))
    store:Merge(bob:Get(wish.id))
    local claim = assert(store:Claim(wish.id, 2))
    click(frame.tabs.wishes)
    click(frame.tabs.claims)
    local wishRow, claimRow = findRow(frame, wish.id), findRow(frame, wish.id, claim.id)
    local _, _, _, goldX = wishRow.gold:GetPoint(1)
    T.eq(goldX, -12, "pooled cards reset the offer position when actions disappear")
    T.eq(wishRow.priority:GetText(), "|cffff7777Urgent|r")
    T.eq(wishRow:GetHeight(), 48)
    T.eq(claimRow:GetHeight(), 24)
    local _, _, _, x, y = claimRow:GetPoint(1)
    T.eq(x, 44)
    T.eq(y, -52)
    T.eq(frame.scrollChild:GetHeight(), 76)
    T.eq(claimRow.label:GetText():match(" · (|c%x+open|r) · "), "|cffffffffopen|r")
    T.check(not claimRow.detail:IsShown())
    T.check(claimRow.label:GetText():find("Ann", 1, true))
    T.check(not claimRow.label:GetText():find("Realm", 1, true))
    T.check(wishRow.detail:GetText():find("Bob", 1, true))
    T.check(not wishRow.detail:GetText():find("Realm", 1, true))
    T.check(not claimRow.itemButton:IsShown())
    T.eq(claimRow.displayItem, nil)
    T.eq(claimRow.buttons.sent:GetHeight(), 22)
    T.eq(frame.status:GetText(), "1 open wish · 1 claim by you")
    click(frame.tabs.mine)
    local own = assert(store:AddWish({ name = "My herb", qty = 1, guild = true }))
    T.check(findRow(frame, own.id).detail:IsShown(), "pooled claim rows become wish cards")
end)

T.add("minimap button attaches once and toggles the UI", function()
    local _, frame, db = setup("groups")
    ns.Minimap.Attach(db)
    local minimap = LibDBIcon10_CommunityWishList
    T.eq(minimap:GetWidth(), 31)
    T.eq(minimap:GetHeight(), 31)
    T.eq(minimap:GetParent(), Minimap)
    click(minimap)
    T.check(not frame:IsShown())
    click(minimap)
    T.check(frame:IsShown())
    ns.Minimap.Attach(db)
    T.eq(LibDBIcon10_CommunityWishList, minimap)
    T.eq(db.ui.minimap.minimapPos, 200)
    click(minimap)
    minimap:GetScript("OnClick")(minimap, "RightButton")
    T.check(not frame:IsShown())
end)

T.add("minimap migrates angle once and refreshes saved visibility", function()
    local db = { ui = { minimap = { angle = 123, hide = true } } }
    ns.Minimap.Attach(db)
    T.eq(db.ui.minimap.minimapPos, 123)
    T.eq(db.ui.minimap.angle, nil)
    T.check(not LibDBIcon10_CommunityWishList:IsShown())
    db.ui.minimap.angle = 50
    db.ui.minimap.hide = false
    ns.Minimap.Attach(db)
    T.eq(db.ui.minimap.minimapPos, 123)
    T.eq(db.ui.minimap.angle, nil)
    T.check(LibDBIcon10_CommunityWishList:IsShown())
end)
