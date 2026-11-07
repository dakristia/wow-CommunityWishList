local _, ns = ...

local MinimapButton = {}
ns.Minimap = MinimapButton
local button, settings

local function position()
    local radians = math.rad(settings.angle)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(radians) * (Minimap:GetWidth() / 2 + 8),
        math.sin(radians) * (Minimap:GetHeight() / 2 + 8))
end

function MinimapButton.Attach(db)
    db.ui = db.ui or {}
    db.ui.minimap = db.ui.minimap or {}
    settings = db.ui.minimap
    settings.angle = settings.angle or 200
    if not button then
        button = CreateFrame("Button", "CommunityWishListMinimapButton", Minimap)
        button:SetSize(31, 31)
        button:SetFrameStrata("MEDIUM")
        button:SetNormalTexture("Interface\\Icons\\INV_Misc_Note_01")
        button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        button:RegisterForClicks("LeftButtonUp")
        button:RegisterForDrag("LeftButton")
        button:SetScript("OnClick", function() ns.UI.Toggle() end)
        button:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local x, y = GetCursorPosition()
                local scale = Minimap:GetEffectiveScale()
                local cx, cy = Minimap:GetCenter()
                settings.angle = math.deg(math.atan2(y / scale - cy, x / scale - cx))
                position()
            end)
        end)
        button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        button:SetScript("OnEnter", function(self)
            if GameTooltip then
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:SetText("Community Wish List")
                GameTooltip:Show()
            end
        end)
        button:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    position()
    button:Show()
end
