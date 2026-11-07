local _, ns = ...

local Items = {}
ns.Items = Items

local function library()
    local lib = LibStub and LibStub("LibItemDB-1.0", true)
    if lib and lib:IsReady() then return lib end
end

local function trim(text)
    return type(text) == "string" and text:match("^%s*(.-)%s*$") or ""
end

local function loose(text)
    return (text:lower():gsub("[',:%-]", ""):gsub("%s+", " "))
end

function Items.Search(text, max)
    text = trim(text)
    local lib = library()
    if #text < 2 or not lib then return {} end
    local bags = {}
    if C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerItemInfo then
        for bag = 0, 4 do
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID then bags[info.itemID] = true end
            end
        end
    end
    local query = loose(text)
    local results = lib:Search{ query = text, loose = true, max = 50 }
    local function rank(item)
        if bags[item.id] then return 1 end
        if loose(item.name):sub(1, #query) == query then return 2 end
        return 3
    end
    table.sort(results, function(a, b)
        local ar, br = rank(a), rank(b)
        if ar ~= br then return ar < br end
        if a.name:lower() == b.name:lower() then return a.id < b.id end
        return a.name:lower() < b.name:lower()
    end)
    local out = {}
    for i = 1, math.min(#results, max or 8) do
        local item = results[i]
        out[i] = { id = item.id, name = item.name, quality = item.quality, link = item.link }
    end
    return out
end

function Items.Resolve(text)
    local lib = library()
    if not lib then return nil end
    text = trim(text)
    local id = tonumber(text:match("|Hitem:(%d+)")) or lib:GetID(text)
    -- A real link names its item even when ItemDB lacks it, so a shift-click on a new item still works.
    local name = id and (lib:GetName(id) or text:match("|h%[(.-)%]|h"))
    if name then return id, name end
end

function Items.Icon(id)
    if id and C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(id) end
end

function Items.Link(id)
    if not id then return nil end
    local lib = library()
    local link = lib and lib:GetLink(id)
    if link then return link end
    if C_Item and C_Item.GetItemInfo then
        local _, fallback = C_Item.GetItemInfo(id)
        return fallback
    end
end

function Items.Quality(id)
    if not id then return nil end
    local lib = library()
    if lib then return lib:GetQuality(id) end
    if C_Item and C_Item.GetItemQualityByID then return C_Item.GetItemQualityByID(id) end
end
