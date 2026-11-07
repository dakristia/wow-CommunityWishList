local lib = LibStub:NewLibrary("LibItemDB-1.0", 1)
if not lib then return end

local items = {
    [4537] = { name = "Tel'Abim Banana", quality = 1 },
    [4601] = { name = "Soft Banana Bread", quality = 1 },
    [2447] = { name = "Peacebloom", quality = 1 },
    [13463] = { name = "Dreamfoil", quality = 1 },
    [19019] = { name = "Thunderfury, Blessed Blade of the Windseeker", quality = 5 },
}

function lib:IsReady() return true end

function lib:GetName(id) return items[id] and items[id].name end

function lib:GetQuality(id) return items[id] and items[id].quality end

function lib:GetID(name)
    if not name then return nil end
    for id, item in pairs(items) do
        if item.name:lower() == name:lower() then return id end
    end
end

function lib:GetLink(id)
    local name = self:GetName(id)
    if name then return ("|cffffffff|Hitem:%d::::::::::::::|h[%s]|h|r"):format(id, name) end
end

local function normalize(text, loose)
    text = text:lower()
    if loose then text = text:gsub("[',:%-]", ""):gsub("%s+", " ") end
    return text
end

function lib:Search(opts)
    opts = opts or {}
    local query = normalize(opts.query or "", opts.loose)
    local results = {}
    for id, item in pairs(items) do
        if normalize(item.name, opts.loose):find(query, 1, true) then
            results[#results + 1] = { id = id, name = item.name, quality = item.quality, link = self:GetLink(id) }
        end
    end
    table.sort(results, function(a, b) return a.name < b.name end)
    while #results > (opts.max or 300) do table.remove(results) end
    return results
end
