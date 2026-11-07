--------------------------------------------------
-- CommunityWishList - shared wish list for guilds and groups
--------------------------------------------------

local ADDON_NAME, ns = ...

-- Tests and other addons reach the modules through this global.
CommunityWishList = ns
ns.ADDON_NAME = ADDON_NAME
ns.PREFIX = "CWList"
ns.PROTOCOL = 1

-- Every character in the store is "Name-Realm", because CHAT_MSG_ADDON and
-- the guild roster leave the realm off for characters on your own realm.
function ns.FullName(name)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then realm = (GetRealmName() or ""):gsub("[%s%-]", "") end
    return name .. "-" .. realm
end

function ns.ShortName(fullName)
    return (fullName and fullName:match("^[^-]+")) or fullName
end

function ns.Print(fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCommunityWishList|r: " .. fmt:format(...))
end
