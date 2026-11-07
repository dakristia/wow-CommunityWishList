-- See docs/design.md for the Notify contract.
local _, ns = ...

local Notify = {}
Notify.__index = Notify
ns.Notify = Notify

local function itemText(wish)
    if wish.item and C_Item and C_Item.GetItemInfo then
        local _, link = C_Item.GetItemInfo(wish.item)
        if link then return link end
    end
    return "[" .. (wish.name or "?") .. "]"
end

function Notify.new(opts)
    local self = setmetatable({ store = opts.store, db = opts.db, me = ns.FullName(opts.me),
        isOnline = opts.isOnline, whisper = opts.whisper, alert = opts.alert, after = opts.after }, Notify)
    self.db.seen = self.db.seen or {}
    self.store:OnChange(function(kind, wish, claim)
        if kind == "claim_new" then self:OnClaimNew(wish, claim) end
    end)
    return self
end

function Notify:OnClaimNew(wish, claim)
    if wish.owner ~= self.me or claim.by == self.me or self.db.seen[claim.id] then return end
    self.db.seen[claim.id] = true
    self.alert(("%s will send you %d x %s"):format(ns.ShortName(claim.by), claim.qty, itemText(wish)))
end

function Notify:AfterLogin()
    self.after(10, function()
        local count = 0
        for _, wish in ipairs(self.store:List({ owner = self.me })) do
            for id, claim in pairs(wish.claims or {}) do
                if claim.by ~= self.me and not self.db.seen[id] then
                    self.db.seen[id] = true
                    count = count + 1
                end
            end
        end
        if count > 0 then self.alert(("%d new claims on your wishes"):format(count)) end
    end)
end

local function tell(self, wish, claim, verb)
    local target
    if wish.recipient and self.isOnline(wish.recipient) then
        target = wish.recipient
    elseif wish.owner and self.isOnline(wish.owner) then
        target = wish.owner
    end
    if target then
        self.whisper(("I %s you %d x %s (CommunityWishList)"):format(verb, claim.qty, itemText(wish)), target)
    end
end

function Notify:Claimed(wish, claim) tell(self, wish, claim, "will send") end
function Notify:Sent(wish, claim) tell(self, wish, claim, "have sent") end
