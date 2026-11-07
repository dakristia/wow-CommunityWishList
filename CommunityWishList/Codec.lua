-- See docs/design.md for the Codec contract.
local _, ns = ...

local function encode(value, depth, seen)
    local kind = type(value)
    if kind == "string" then
        local escaped = value:gsub("%%", "%%25"):gsub("%z", "%%00")
        return "s" .. #escaped .. ":" .. escaped
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return nil end
        local text = string.format("%.17g", value)
        return "n" .. #text .. ":" .. text
    elseif kind == "boolean" then
        return value and "b1" or "b0"
    elseif kind ~= "table" or depth > 8 or seen[value] then
        return nil
    end
    seen[value] = true
    local parts, count = {}, 0
    for key, item in pairs(value) do
        local k = encode(key, depth + 1, seen)
        local v = encode(item, depth + 1, seen)
        if not k or not v or type(key) == "table" then seen[value] = nil; return nil end
        count = count + 1
        parts[#parts + 1] = k .. v
    end
    seen[value] = nil
    return "t" .. count .. ":" .. table.concat(parts)
end

ns.Codec = {}
function ns.Codec.Serialize(value)
    local result = encode(value, 1, {})
    if result and #result <= 65536 then return result end
end

function ns.Codec.Deserialize(text)
    if type(text) ~= "string" or #text > 65536 or text:find("%z") then return nil end
    local function parse(pos, depth)
        local tag = text:sub(pos, pos)
        if tag == "b" then
            local b = text:sub(pos + 1, pos + 1)
            if b == "0" then return false, pos + 2 end
            if b == "1" then return true, pos + 2 end
            error("boolean")
        end
        if tag ~= "s" and tag ~= "n" and tag ~= "t" then error("tag") end
        local colon = text:find(":", pos + 1, true)
        if not colon then error("length") end
        local digits = text:sub(pos + 1, colon - 1)
        if not digits:match("^%d+$") or #digits > 6 then error("length") end
        local count = tonumber(digits)
        if count > 65536 then error("length") end
        pos = colon + 1
        if tag == "t" then
            if depth > 8 or count > (#text - pos + 1) / 4 then error("table") end
            local result = {}
            for _ = 1, count do
                local key, value
                key, pos = parse(pos, depth + 1)
                if type(key) == "table" or result[key] ~= nil then error("key") end
                value, pos = parse(pos, depth + 1)
                result[key] = value
            end
            return result, pos
        end
        if pos + count - 1 > #text then error("truncated") end
        local value = text:sub(pos, pos + count - 1)
        if tag == "n" then
            if not value:match("^[+-]?%d+%.?%d*[eE]?[+-]?%d*$") then error("number") end
            value = tonumber(value)
            if not value or value ~= value or value == math.huge or value == -math.huge then error("number") end
        else
            if value:find("%%[^02]") or value:find("%%$") or value:find("%%0[^0]") or value:find("%%2[^5]") or value:find("%%[02]$") then error("escape") end
            value = value:gsub("%%00", "\0"):gsub("%%25", "%%")
        end
        return value, pos + count
    end
    local ok, value, pos = pcall(parse, 1, 1)
    if ok and pos == #text + 1 then return value end
end
