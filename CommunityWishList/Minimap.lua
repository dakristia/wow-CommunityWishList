local _, ns = ...

local MinimapButton = {}
ns.Minimap = MinimapButton
local launcher

function MinimapButton.Attach(db)
    db.ui = db.ui or {}
    db.ui.minimap = db.ui.minimap or {}
    local settings = db.ui.minimap
    settings.minimapPos = settings.minimapPos or settings.angle or 200
    settings.angle = nil
    if not launcher then
        launcher = LibStub("LibDataBroker-1.1"):NewDataObject("CommunityWishList", {
            type = "launcher",
            icon = ns.ICON,
            OnClick = function(_, mouseButton)
                if mouseButton == "LeftButton" then ns.UI.Toggle() end
            end,
            OnTooltipShow = function(tooltip)
                tooltip:AddLine("Community Wish List")
                tooltip:AddLine("Click to open")
            end,
        })
    end
    local icon = LibStub("LibDBIcon-1.0")
    if icon:IsRegistered("CommunityWishList") then
        icon:Refresh("CommunityWishList", settings)
    else
        icon:Register("CommunityWishList", launcher, settings)
    end
end
