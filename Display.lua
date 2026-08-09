--------------------------------------------------------------------------------
-- nugsBuffAlert
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsBuffAlert  -  Display.lua
-- One frame per alert. Icon, text, or both, wherever you put it.
--
-- Two shapes of alert, and they are genuinely different things rather than one
-- setting:
--
--   flash   a moment. Something procced, you get told, it goes away on its own.
--           Nothing about it needs the aura to still be readable a second later.
--   hold    a state. It stays for as long as the buff is up, which means it wants
--           a swipe, a timer and a stack count, and it wants to disappear the
--           instant the buff does.
--
-- Everything a frame draws about the aura itself - swipe, timer, stacks - goes
-- through a display sink rather than a value we read. The frame is handed a
-- duration object and animates itself; nothing here ever learns a number. That is
-- what lets a held alert count down correctly on a buff whose remaining time this
-- addon is not allowed to know.
--
-- Positions are always CENTER-to-anchor. Every alert's saved x and y mean "from
-- this corner of the screen to the middle of this alert", which is the only reading
-- that survives a size change: growing the font would otherwise walk the alert
-- across the screen.
--------------------------------------------------------------------------------

local ADDON_NAME, NBA = ...

local UA = C_UnitAuras or {}

local Display = {}
NBA.Display = Display

local frames = {}          -- [alertID] = frame
Display.frames = frames

local unlocked = false

local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

-- Screen coordinates of one of UIParent's anchor points, in UIParent's own scale.
local function AnchorPoint(anchor)
    local l, r = UIParent:GetLeft(), UIParent:GetRight()
    local b, t = UIParent:GetBottom(), UIParent:GetTop()
    if not l then return 0, 0 end
    local cx, cy = (l + r) / 2, (b + t) / 2

    local x = (anchor:find("LEFT") and l) or (anchor:find("RIGHT") and r) or cx
    local y = (anchor:find("TOP")  and t) or (anchor:find("BOTTOM") and b) or cy
    return x, y
end

local function PlaceFrame(f, a)
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, a.anchor or "CENTER", a.x or 0, a.y or 0)
end

-- Turns wherever the player dragged the frame to back into an offset from its own
-- anchor. Done in UIParent's scale because the frame carries the alert's scale and
-- GetCenter answers in the frame's.
local function SavePosition(f, a)
    local fx, fy = f:GetCenter()
    if not fx then return end
    local ratio = f:GetEffectiveScale() / UIParent:GetEffectiveScale()
    fx, fy = fx * ratio, fy * ratio

    local ax, ay = AnchorPoint(a.anchor or "CENTER")
    a.x = math.floor(fx - ax + 0.5)
    a.y = math.floor(fy - ay + 0.5)
    PlaceFrame(f, a)
end

--------------------------------------------------------------------------------
-- Building a frame
--------------------------------------------------------------------------------

local function BuildFrame(id)
    local f = CreateFrame("Frame", "nugsBuffAlertFrame" .. id, UIParent)
    f:SetSize(64, 64)
    -- So an alert cannot be dragged half off the edge and then be unreachable.
    f:SetClampedToScreen(true)
    f:Hide()

    f.icon = f:CreateTexture(nil, "ARTWORK")

    -- Drawn behind and slightly larger than the icon, so the "border" is the part
    -- of this that sticks out. Cheaper than a nine-slice and it cannot be nudged
    -- out of alignment by an odd icon size.
    f.iconBorder = f:CreateTexture(nil, "BACKGROUND")
    f.iconBorder:SetTexture("Interface\\Buttons\\WHITE8X8")
    f.iconBorder:SetVertexColor(0, 0, 0, 0.9)

    f.cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    f.cd:SetDrawEdge(false)
    f.cd:SetHideCountdownNumbers(true)
    f.cd:SetReverse(true)
    -- Never fully opaque. A buff applied without a timer hands back a duration that
    -- has nothing to count towards, and the swipe drawn from it covers the whole icon
    -- - so the alert fires, draws, and looks like it did not, because what is on
    -- screen is a black square. There is no way to ask whether an aura is timerless
    -- (the duration is secret), so the swipe is simply never allowed to hide the icon
    -- it is drawn over.
    f.cd:SetSwipeColor(0, 0, 0, 0.55)

    f.text   = f:CreateFontString(nil, "OVERLAY")
    f.stacks = f:CreateFontString(nil, "OVERLAY", "NumberFontNormal")

    -- Placement furniture. Shown only while unlocked, so a locked alert has no
    -- mouse footprint at all and cannot eat a click meant for the world.
    f.dragBG = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    f.dragBG:SetAllPoints(f)
    f.dragBG:SetTexture("Interface\\Buttons\\WHITE8X8")
    f.dragBG:SetVertexColor(0.11, 0.6, 1, 0.18)
    f.dragBG:Hide()

    f.dragLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.dragLabel:SetPoint("BOTTOM", f, "TOP", 0, 2)
    f.dragLabel:Hide()

    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        if unlocked then self:StartMoving() end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local a = NBA.db.alerts[self.alertID]
        if a then SavePosition(self, a) end
        if NBA.RefreshOptions then NBA.RefreshOptions() end
    end)

    f.alertID = id
    frames[id] = f
    return f
end

local function FrameFor(id)
    return frames[id] or BuildFrame(id)
end

--------------------------------------------------------------------------------
-- Laying one out
--
-- Called whenever the alert's settings change and whenever it fires, because the
-- cost is a handful of setters and the alternative is a dirty flag that will
-- eventually be wrong.
--------------------------------------------------------------------------------

local function AlertText(a)
    local label = a.text
    if not label or label == "" then
        label = (a.spellID and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(a.spellID))
                or a.name or "?"
    end
    if a.uppercase then label = label:upper() end
    return label
end
NBA.AlertText = AlertText

-- What gets spoken. Deliberately not AlertText: that one applies UPPERCASE, which is a
-- decision about how the words look and has nothing to say about how they sound.
function NBA.SpokenText(a)
    if a.speakText and a.speakText ~= "" then return a.speakText end
    if a.text and a.text ~= "" then return a.text end
    return (a.spellID and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(a.spellID))
           or a.name or ""
end

local function AlertIcon(a)
    if a.spellID and C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(a.spellID)
        if info and info.iconID then return info.iconID end
    end
    return QUESTION
end
NBA.AlertIcon = AlertIcon

local function Layout(f, a)
    local showIcon = (a.show == "icon" or a.show == "both")
    local showText = (a.show == "text" or a.show == "both")

    f:SetFrameStrata(a.strata or "HIGH")
    f:SetScale(a.scale or 1)

    -- Icon
    local size = a.iconSize or 48
    f.icon:SetShown(showIcon)
    f.iconBorder:SetShown(showIcon and a.border and true or false)
    f.cd:SetShown(false)
    if showIcon then
        f.icon:SetSize(size, size)
        f.icon:SetTexture(AlertIcon(a))
        if a.zoom then
            f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        else
            f.icon:SetTexCoord(0, 1, 0, 1)
        end
        f.iconBorder:ClearAllPoints()
        f.iconBorder:SetPoint("TOPLEFT", f.icon, "TOPLEFT", -1.5, 1.5)
        f.iconBorder:SetPoint("BOTTOMRIGHT", f.icon, "BOTTOMRIGHT", 1.5, -1.5)
        f.cd:ClearAllPoints()
        f.cd:SetAllPoints(f.icon)
    end

    -- Text
    f.text:SetShown(showText)
    if showText then
        NBA.ApplyFont(f.text, a)
        f.text:SetText(AlertText(a))
        local c = a.color or { 1, 1, 1 }
        f.text:SetTextColor(c[1], c[2], c[3])
        if a.shadow then
            f.text:SetShadowColor(0, 0, 0, 1)
            f.text:SetShadowOffset(1, -1)
        else
            f.text:SetShadowOffset(0, 0)
        end
    end

    -- Arrangement. Everything is placed relative to the frame's centre, and the
    -- frame is then sized to hold it, so the anchor stays the middle of whatever
    -- ends up being drawn no matter which pieces are on.
    local gap = a.gap or 4
    local tw  = showText and f.text:GetStringWidth()  or 0
    local th  = showText and f.text:GetStringHeight() or 0
    local iw  = showIcon and size or 0
    local ih  = showIcon and size or 0

    local w, h
    if showIcon and showText then
        if a.layout == "right" or a.layout == "left" then
            w, h = iw + gap + tw, math.max(ih, th)
            local dir = (a.layout == "right") and 1 or -1
            f.icon:ClearAllPoints()
            f.icon:SetPoint("CENTER", f, "CENTER", -dir * (w / 2 - iw / 2), 0)
            f.text:ClearAllPoints()
            f.text:SetPoint("CENTER", f, "CENTER", dir * (w / 2 - tw / 2), 0)
        else
            w, h = math.max(iw, tw), ih + gap + th
            local dir = (a.layout == "above") and 1 or -1
            f.icon:ClearAllPoints()
            f.icon:SetPoint("CENTER", f, "CENTER", 0, -dir * (h / 2 - ih / 2))
            f.text:ClearAllPoints()
            f.text:SetPoint("CENTER", f, "CENTER", 0, dir * (h / 2 - th / 2))
        end
    elseif showIcon then
        w, h = iw, ih
        f.icon:ClearAllPoints()
        f.icon:SetPoint("CENTER")
    else
        w, h = tw, th
        f.text:ClearAllPoints()
        f.text:SetPoint("CENTER")
    end

    -- A zero-size frame cannot be grabbed, and an alert with no spell and no text is
    -- exactly the one a new player needs to be able to grab.
    f:SetSize(math.max(w, 20), math.max(h, 20))

    f.stacks:ClearAllPoints()
    f.stacks:SetPoint("BOTTOMRIGHT", showIcon and f.icon or f, "BOTTOMRIGHT", 2, -2)
    f.stacks:SetShown(false)

    f.dragLabel:SetText(a.name or "alert")

    PlaceFrame(f, a)
end

--------------------------------------------------------------------------------
-- The aura-derived extras
--
-- Every one of these is a value we are not allowed to read handed straight to a
-- widget that is. Nothing below branches on aura data, which is why it all keeps
-- working inside an encounter.
--------------------------------------------------------------------------------

-- Split in two on purpose. A held alert is re-asserted ten times a second, and the
-- swipe is a *binding* - handing it the same duration again restarts the animation, so
-- an icon that should sweep smoothly stutters instead. It is therefore bound once, when
-- the aura this frame is showing actually changes. Stacks are a value rather than a
-- binding and are refreshed every pass.
local function BindAura(f, a, instanceID)
    local unit = a.unit or "player"

    local duration
    if instanceID ~= nil and NBA.HAS.duration then
        local ok, obj = pcall(UA.GetAuraDuration, unit, instanceID)
        if ok then duration = obj end
    end

    -- Swipe. SetCooldownFromDurationObject is the only setter that accepts a secret
    -- duration from tainted code; SetCooldown and SetCooldownFromExpirationTime both
    -- reject one, so there is no fallback worth attempting.
    if a.swipe and duration and f.icon:IsShown() then
        local ok = pcall(f.cd.SetCooldownFromDurationObject, f.cd, duration)
        f.cd:SetShown(ok and true or false)
    else
        f.cd:SetShown(false)
    end
end

-- Stacks. The count comes back preformatted precisely so it can be shown without
-- being known - empty below the minimum, and a bare "*" above the maximum.
local function ApplyStacks(f, a, instanceID)
    if a.showStacks and instanceID ~= nil and NBA.HAS.stacks then
        local ok, str = pcall(UA.GetAuraApplicationDisplayCount, a.unit or "player",
                              instanceID, 2, 99)
        if ok and str then
            f.stacks:SetText(str)
            f.stacks:Show()
            return
        end
    end
    f.stacks:Hide()
end

local function ApplyAuraExtras(f, a, instanceID)
    if f.boundInstance ~= instanceID then
        f.boundInstance = instanceID
        BindAura(f, a, instanceID)
    end
    ApplyStacks(f, a, instanceID)
end

--------------------------------------------------------------------------------
-- Animation
--
-- Hand-run rather than an AnimationGroup, because the fade has to be interruptible
-- at any point: a buff that comes back while its own fade-out is still running has
-- to snap back to full rather than queue behind the tail of the last one.
--------------------------------------------------------------------------------

local POP = 0.4

local function Advance(f, dt)
    local a = NBA.db and NBA.db.alerts[f.alertID]
    if not a then f:Hide() return end

    f.t = (f.t or 0) + dt
    local alpha, pop = 1, 1

    if f.phase == "in" then
        local d = math.max(a.fadeIn or 0.15, 0.01)
        local p = math.min(f.t / d, 1)
        alpha = p
        if a.pop then pop = 1 + POP * (1 - p) * (1 - p) end
        if p >= 1 then
            f.phase = f.holding and "held" or "hold"
            f.t = 0
        end

    elseif f.phase == "hold" then
        if f.t >= (a.hold or 1.2) then
            f.phase = "out"
            f.t = 0
        end

    elseif f.phase == "held" then
        -- Level, not an edge: it sits here until Stop is called.
        alpha = 1

    elseif f.phase == "out" then
        local d = math.max(a.fadeOut or 0.45, 0.01)
        local p = math.min(f.t / d, 1)
        alpha = 1 - p
        if p >= 1 then
            f:Hide()
            f:SetScript("OnUpdate", nil)
            return
        end
    end

    f:SetAlpha(alpha * (a.alpha or 1))
    f:SetScale((a.scale or 1) * pop)
end

local function Run(f)
    f:SetScript("OnUpdate", function(self, dt) Advance(self, dt) end)
end

--------------------------------------------------------------------------------
-- The interface Watch.lua drives
--------------------------------------------------------------------------------

-- A one-shot alert: something happened, say so, get out of the way.
function Display:Fire(id, a, kind, instanceID)
    if unlocked then return end

    local f = FrameFor(id)
    Layout(f, a)
    -- A fresh appearance, so whatever was bound last time is not this aura.
    f.boundInstance = nil
    ApplyAuraExtras(f, a, instanceID)

    f.holding = (a.mode == "hold" and a.trigger == "gain")
    f.phase   = "in"
    f.t       = 0
    f:SetAlpha(0)
    f:Show()
    Run(f)

    if kind ~= "test" then
        if a.sound and a.sound ~= "" then
            NBA.PlayAlertSound(a.sound, a.soundChan)
        end
        if a.speak then
            NBA.Speak(NBA.SpokenText(a))
        end
    end
end

-- A state that is true right now. Asserted every pass rather than fired once, so a
-- frame that was hidden by anything else comes back on the next tick.
function Display:Hold(id, a, instanceID)
    if unlocked then return end

    local f = FrameFor(id)
    if not f:IsShown() then
        Layout(f, a)
        f.holding = true
        f.phase   = "in"
        f.t       = 0
        f:SetAlpha(0)
        f:Show()
        Run(f)
        if a.sound and a.sound ~= "" then
            NBA.PlayAlertSound(a.sound, a.soundChan)
        end
    elseif f.phase == "out" then
        -- It came back mid-fade. Snap to full rather than finish dying first.
        f.holding = true
        f.phase   = "in"
        f.t       = (a.fadeIn or 0.15) * (1 - f:GetAlpha())
    end

    ApplyAuraExtras(f, a, instanceID)
end

function Display:Stop(id)
    local f = frames[id]
    if not f or not f:IsShown() then return end
    if f.phase == "out" then return end
    f.holding = false
    f.phase   = "out"
    f.t       = 0
    Run(f)
end

function Display:StopAll()
    for _, f in pairs(frames) do
        f:Hide()
        f:SetScript("OnUpdate", nil)
        f.phase = nil
        f.boundInstance = nil
    end
end

--------------------------------------------------------------------------------
-- Placement and preview
--------------------------------------------------------------------------------

function Display:ToggleLock(lock)
    -- Unlocking mid-fight is refused. This one puts *every* alert that applies to the
    -- spec on screen at once so they can all be placed together - which during a real
    -- pull is a screen full of procs that are not actually happening. Every entry
    -- point comes through here, so this is the only place it needs saying.
    if not lock and InCombatLockdown() then
        NBA.Print("alerts cannot be placed during combat - try again after the fight.")
        return
    end

    unlocked = not lock
    NBA.db.locked = lock and true or false

    if unlocked then
        -- Every alert that applies here goes up at once, whatever it is watching.
        -- Placing things one proc at a time is not a workflow.
        for _, id in ipairs(NBA.db.order) do
            local a = NBA.db.alerts[id]
            if a and NBA.AlertAppliesHere(a) then
                local f = FrameFor(id)
                Layout(f, a)
                f:SetScript("OnUpdate", nil)
                f.phase = nil
                f:SetAlpha(1)
                f:SetScale(a.scale or 1)
                f:EnableMouse(true)
                f.dragBG:Show()
                f.dragLabel:Show()
                f:Show()
            end
        end
    else
        for _, f in pairs(frames) do
            f:EnableMouse(false)
            f.dragBG:Hide()
            f.dragLabel:Hide()
            f:Hide()
            f:SetScript("OnUpdate", nil)
            f.phase = nil
        end
    end

    if NBA.OnLockChanged then NBA.OnLockChanged(lock) end
end

function Display:IsUnlocked() return unlocked end

-- Preview one alert exactly as it will appear, without waiting for the buff.
function Display:Test(id)
    local a = NBA.db.alerts[id]
    if not a then return end
    if unlocked then self:ToggleLock(true) end
    self:Fire(id, a, "test", nil)
end

function Display:TestAll()
    if unlocked then self:ToggleLock(true) end
    for _, id in ipairs(NBA.db.order) do
        local a = NBA.db.alerts[id]
        if a and a.enabled and NBA.AlertAppliesHere(a) then
            self:Fire(id, a, "test", nil)
        end
    end
end

-- Re-lay every live frame. Called from the options window on any change, so a
-- slider drag is visible while it is being dragged rather than at the next proc.
function Display:Refresh()
    for id, f in pairs(frames) do
        local a = NBA.db.alerts[id]
        if not a then
            f:Hide()
            f:SetScript("OnUpdate", nil)
        elseif f:IsShown() then
            Layout(f, a)
            -- Layout has just cleared the swipe, and the settings that drive the
            -- bindings may be exactly what changed, so the next pass rebinds.
            f.boundInstance = nil
            if unlocked then
                f:SetAlpha(1)
                f:SetScale(a.scale or 1)
            end
        end
    end
end

function Display:Forget(id)
    local f = frames[id]
    if not f then return end
    f:Hide()
    f:SetScript("OnUpdate", nil)
    f:EnableMouse(false)
    -- Frames cannot be destroyed, so this one is hidden and dropped on the floor.
    -- Ids are handed out by a counter that only ever goes up, so nothing will ask
    -- for it again and it will simply sit there unreferenced.
    frames[id] = nil
end

--------------------------------------------------------------------------------

function Display:Init()
    -- Locked is the state every session starts in, so the saved flag is corrected
    -- rather than obeyed. Logging out unlocked would otherwise leave the database
    -- claiming a state the screen is not in, and the first click of the unlock button
    -- would do nothing visible.
    unlocked = false
    if NBA.db then NBA.db.locked = true end

    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:SetScript("OnEvent", function()
        -- Unlocked means fake alerts are on the screen, and fake alerts during a
        -- real pull cannot be told apart from the real thing.
        if unlocked then Display:ToggleLock(true) end
    end)
end
