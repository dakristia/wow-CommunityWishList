--------------------------------------------------
-- CommunityWishList - shared wish list for guilds and groups
--------------------------------------------------

local ADDON_NAME, ns = ...

-- Tests and other addons reach the modules through this global.
CommunityWishList = ns
ns.ADDON_NAME = ADDON_NAME
ns.PREFIX = "CWList"
ns.PROTOCOL = 1
ns.ICON = "Interface\\AddOns\\CommunityWishList\\Media\\icon"

-- Every character in the store is "First Surname-Realm" (the surname is optional), because CHAT_MSG_ADDON
-- and the guild roster leave the realm off for characters on your own realm. See docs/design.md.
-- Realm names in addon messages have no spaces, hyphens or apostrophes, but UnitName's second value is raw.
function ns.NormalizeRealm(realm)
    return (tostring(realm or ""):gsub("[%s%-']", ""))
end

local function realm()
    local normalized = GetNormalizedRealmName and GetNormalizedRealmName()
    if normalized and normalized ~= "" then return normalized end
    return ns.NormalizeRealm(GetRealmName and GetRealmName() or "")
end

function ns.FullName(name)
    if not name or name == "" then return nil end
    if not name:find("-", 1, true) then name = name .. "-" .. realm() end
    return name
end

-- A value the client keeps from us (identity is restricted in a battleground, for example). Anything
-- unexpected counts as secret, because touching a secret value the wrong way raises an error.
local function secret(v)
    if not issecretvalue then return false end
    local ok, hidden = pcall(issecretvalue, v)
    return (not ok) or (hidden and true or false)
end

local function separator(which, fallback)
    local consts = Constants and Constants.CharacterNameSeparatorConsts
    local v = consts and consts[which]
    return type(v) == "string" and v or fallback
end

local function sameRealmUnit(unit)
    if not UnitRealmRelationship then return nil end
    local ok, relation = pcall(UnitRealmRelationship, unit)
    if not ok or type(relation) ~= "number" then return nil end
    return relation == (LE_REALM_RELATION_SAME or 1)
end

local function realmFromGUID(unit)
    if not (UnitGUID and GetPlayerInfoByGUID) then return nil end
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or type(guid) ~= "string" or guid == "" then return nil end
    local ok2, _, _, _, _, _, _, guidRealm = pcall(GetPlayerInfoByGUID, guid)
    if not ok2 or secret(guidRealm) or type(guidRealm) ~= "string" or guidRealm == "" then return nil end
    return guidRealm
end

-- UnitName's second value is a realm OR a surname (Forever has regional unique names), so this decides
-- which one it is. Returns name, surname, realm, or nil when the client hides who the unit is.
local function nameParts(unit)
    local name, second
    if UnitNameUnmodified then name, second = UnitNameUnmodified(unit) end
    -- Wowless answers UnitNameUnmodified with an empty string, so an empty answer falls back to UnitName.
    if not secret(name) and (name == nil or name == "") and UnitName then name, second = UnitName(unit) end
    if secret(name) or secret(second) then return nil end
    if not name or name == "" or name == UNKNOWNOBJECT then return nil end
    if second == "" then second = nil end
    if not second then return name, nil, nil end
    local flat = ns.NormalizeRealm(second)
    if flat == realm() or flat == ns.NormalizeRealm(GetRealmName and GetRealmName() or "") then
        return name, nil, second
    end
    local same = sameRealmUnit(unit)
    if same == true then return name, second, nil end
    if same == false then return name, nil, second end
    local actual = realmFromGUID(unit)
    if actual then
        if ns.NormalizeRealm(actual) == flat then return name, nil, second end
        return name, second, nil
    end
    if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then return name, second, nil end
    return name, nil, second
end

-- nil means "we do not know who this is right now", so callers must not cache or delete anything over it.
function ns.UnitKey(unit)
    local name, surname, unitRealm = nameParts(unit or "player")
    if not name then return nil end
    if surname then name = name .. separator("CHARACTERNAME_SURNAME_SEPARATOR", " ") .. surname end
    if unitRealm then return name .. "-" .. ns.NormalizeRealm(unitRealm) end
    return ns.FullName(name)
end

function ns.Me()
    if not ns.me then ns.me = ns.UnitKey("player") end
    return ns.me
end

-- Recognises the character we play now in a key written before surnames were handled ("Crayons-Realm"
-- for "Crayons Bonk-Realm"). Only for our own records: "Crayons" and "Crayons Bonk" can be two players.
function ns.IsMyStoredName(key)
    if type(key) ~= "string" or key == "" then return false end
    local me = ns.Me()
    if not me then return false end
    if key == me then return true end
    local myName, myRealm = me:match("^(.*)%-([^%-]+)$")
    local name, keyRealm = key:match("^(.*)%-([^%-]+)$")
    if not (myName and name) then return false end
    if ns.NormalizeRealm(keyRealm) ~= ns.NormalizeRealm(myRealm) then return false end
    if name == myName then return true end
    local first, myFirst = name:match("^%S+"), myName:match("^%S+")
    if first ~= myFirst then return false end
    return name == first or myName == myFirst
end

-- The name shown to users: first name and surname, never the realm.
function ns.ShortName(fullName)
    if not fullName then return "?" end
    return (fullName:match("^(.*)%-[^%-]*$")) or fullName
end

-- The stock panel button is red, so its art is desaturated and tinted bronze to match the window trim.
function ns.Button(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 70, 22)
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    b:SetDisabledFontObject(GameFontDisableSmall)
    local art = { b.Left, b.Middle, b.Right, b:GetNormalTexture(), b:GetPushedTexture(), b:GetDisabledTexture() }
    for _, texture in pairs(art) do
        texture:SetDesaturated(true)
        texture:SetVertexColor(1, 0.82, 0.55)
    end
    b:SetText(text)
    return b
end

function ns.Print(fmt, ...)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffCommunityWishList|r: " .. fmt:format(...))
end
