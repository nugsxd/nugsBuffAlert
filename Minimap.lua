--------------------------------------------------------------------------------
-- nugsBuffAlert
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsBuffAlert  -  Minimap.lua
-- A self-contained minimap button (no external libraries). Draggable around the
-- minimap edge; its angle persists in SavedVariables. Left click opens the options
-- window, right click unlocks the alerts for dragging.
--------------------------------------------------------------------------------
local ADDON_NAME, NBA = ...

-- Place the button on the minimap edge, adapting to the minimap's CURRENT size and
-- shape, so it works with resized/reshaped minimaps and not just the default.
local function PositionButton(btn, angle)
    local a = math.rad(angle)
    local cos, sin = math.cos(a), math.sin(a)
    local w = (Minimap:GetWidth()  / 2) + 5
    local h = (Minimap:GetHeight() / 2) + 5
    local shape = (type(GetMinimapShape) == "function") and GetMinimapShape() or "ROUND"
    local x, y
    if shape == "ROUND" then
        x, y = cos * w, sin * h
    else
        -- square / mixed-shape minimaps: clamp the point to the minimap box
        local diag = 1.41421356
        x = math.max(-w, math.min(cos * w * diag, w))
        y = math.max(-h, math.min(sin * h * diag, h))
    end
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While dragging, follow the cursor around the minimap edge.
local function OnDragUpdate(btn)
    local mx, my = Minimap:GetCenter()
    if not mx then return end
    local scale = Minimap:GetEffectiveScale()
    local px, py = GetCursorPosition()
    px, py = px / scale, py / scale
    local angle = math.deg(math.atan2(py - my, px - mx))
    NBA.db.minimapAngle = angle
    PositionButton(btn, angle)
end

function NBA.InitMinimap()
    if NBA.minimapButton or not NBA.db then return end
    NBA.db.minimapAngle = NBA.db.minimapAngle or 200

    local btn = CreateFrame("Button", "nugsBuffAlertMinimapButton", Minimap)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:SetSize(31, 31)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")

    -- A dark disc behind the icon. The tracking border's hole is slightly wider than
    -- the icon, and without this the gap between the two is see-through - the world
    -- scrolls past in a thin ring around the button. Deliberately sized past the hole,
    -- because the border art draws over the excess.
    local backing = btn:CreateTexture(nil, "BACKGROUND")
    backing:SetSize(23, 23)
    backing:SetPoint("CENTER", 0, 1)
    backing:SetTexture("Interface\\Buttons\\WHITE8X8")
    backing:SetVertexColor(0.05, 0.06, 0.08, 1)
    backing:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(21, 21)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture("Interface\\AddOns\\nugsBuffAlert\\icon")
    -- Circular alpha mask so the square art cannot poke past the round border.
    icon:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    btn:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", OnDragUpdate) end)
    btn:SetScript("OnDragStop",  function(self) self:SetScript("OnUpdate", nil) end)

    btn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            NBA.Display:ToggleLock(NBA.Display:IsUnlocked())
        else
            NBA.ToggleOptions()
        end
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("nugsBuffAlert")
        GameTooltip:AddLine("Left click to open the options", 1, 1, 1)
        GameTooltip:AddLine("Right click to lock or unlock the alerts", 1, 1, 1)
        GameTooltip:AddLine("Drag to move this button", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    NBA.minimapButton = btn
    PositionButton(btn, NBA.db.minimapAngle)
    NBA.SetMinimapShown(not NBA.db.minimapHidden)
end

function NBA.SetMinimapShown(shown)
    if not NBA.minimapButton then return end
    NBA.minimapButton:SetShown(shown and true or false)
end
