--------------------------------------------------------------------------------
-- nugsBuffAlert
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsBuffAlert  -  Options.lua
-- The settings window.
--
-- A list of alerts on the left and the selected alert's settings on the right,
-- rather than the tab-per-thing the smaller nugs addons use. The number of alerts
-- is unbounded and the list has to be on screen anyway, so it may as well be the
-- navigation.
--
-- The one thing this window has to do that a settings window normally does not is
-- tell you whether an alert will actually fire in a raid. A spell the client will
-- not answer about fails silently and looks exactly like a spell that never procs,
-- so every alert carries a readability mark and a sentence saying what will happen
-- on a pull. That mark is the reason the spell picker exists in this shape: you
-- choose from what is genuinely on you rather than typing an id off a website and
-- finding out during the fight.
--
-- Shared namespace: the second vararg is the same table across every Lua file in
-- this addon, so all state and functions hang off of it.
--------------------------------------------------------------------------------

local ADDON_NAME, NBA = ...

local C = {
    bg     = { 0.07, 0.07, 0.07, 0.96 },
    header = { 0.10, 0.10, 0.10, 1.00 },
    panel  = { 0.10, 0.10, 0.10, 0.90 },
    input  = { 0.14, 0.14, 0.14, 1.00 },
    btn    = { 0.16, 0.16, 0.16, 1.00 },
    btnHi  = { 0.24, 0.24, 0.24, 1.00 },
    accent = { 0.35, 0.72, 1.00, 1.00 },
    rowA   = { 1, 1, 1, 0.025 },
    rowB   = { 1, 1, 1, 0.055 },
    text   = { 0.82, 0.82, 0.82 },
    faint  = { 0.50, 0.50, 0.50 },
    gold   = { 1.00, 0.84, 0.42 },
    good   = { 0.45, 0.85, 0.45 },
    warn   = { 0.95, 0.70, 0.30 },
    bad    = { 0.90, 0.40, 0.40 },
}

local ADDON_ICON = "Interface\\AddOns\\nugsBuffAlert\\icon"

local WIDTH, HEIGHT = 860, 640
local LEFT_W    = 236
local CONTENT_W = WIDTH - LEFT_W - 56
local COL_GAP   = 20
local COL_W     = math.floor((CONTENT_W - COL_GAP) / 2)
local ROW_H     = 22

local window, tabStrip, alertList, picker, emptyLabel
local panels     = {}
local currentKey = "alert"
local selectedID
local sink
local RelayoutAll, RebuildAlertList, RebuildAlertRow, RefreshPicker, ShowPicker

-- The alert the settings columns are acting on. Every getter and setter closes over
-- this rather than a captured alert table, so selecting a different alert in the
-- list does not need the panels rebuilt.
local function A()
    return NBA.db and NBA.db.alerts[selectedID]
end

local function Apply()
    if NBA.Display then NBA.Display:Refresh() end
end

--------------------------------------------------------------------------------
-- Widgets
--------------------------------------------------------------------------------

local function Backdrop(frame, color, borderAlpha)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(color))
    frame.bgTex = bg
    if borderAlpha then
        for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" } }) do
            local t = frame:CreateTexture(nil, "BORDER")
            t:SetPoint(p[1]); t:SetPoint(p[2]); t:SetHeight(1)
            t:SetColorTexture(0, 0, 0, borderAlpha)
        end
        for _, p in ipairs({ { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
            local t = frame:CreateTexture(nil, "BORDER")
            t:SetPoint(p[1]); t:SetPoint(p[2]); t:SetWidth(1)
            t:SetColorTexture(0, 0, 0, borderAlpha)
        end
    end
    return bg
end

local function Panel(parent, color)
    local f = CreateFrame("Frame", nil, parent)
    Backdrop(f, color or C.panel, 1)
    return f
end

local function Label(parent, text, template, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
    fs:SetText(text)
    fs:SetJustifyH("LEFT")
    fs:SetTextColor(unpack(color or C.text))
    return fs
end

local function SectionHeader(parent, text)
    return Label(parent, text, "GameFontNormal", C.accent)
end

local function Button(parent, text, w, h, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    Backdrop(b, C.btn, 1)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(text)
    b.text:SetTextColor(unpack(C.text))
    b:SetScript("OnEnter", function(self) self.bgTex:SetColorTexture(unpack(C.btnHi)) end)
    b:SetScript("OnLeave", function(self) self.bgTex:SetColorTexture(unpack(C.btn)) end)
    b:SetScript("OnClick", onClick)
    b.SetLabel = function(self, t) self.text:SetText(t) end
    b.SetGrey = function(self, grey)
        self.text:SetTextColor(unpack(grey and C.faint or C.text))
        if grey then self:Disable() else self:Enable() end
    end
    return b
end

-- Deliberately built to match the rest of the suite so they read as one thing: a
-- 30px bar with a storm-blue underline, the addon icon on the left, a gold title
-- with a blue tail, and a small flat close button.
local function HeaderBar(f, titleText, tailText)
    local header = CreateFrame("Frame", nil, f)
    Backdrop(header, C.header, 1)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(30)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local accent = header:CreateTexture(nil, "OVERLAY")
    accent:SetPoint("BOTTOMLEFT", 0, 0)
    accent:SetPoint("BOTTOMRIGHT", 0, 0)
    accent:SetHeight(3)
    accent:SetColorTexture(unpack(C.accent))

    local icon = header:CreateTexture(nil, "OVERLAY")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", 10, 0)
    icon:SetTexture(ADDON_ICON)

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText(titleText .. (tailText and (" |cff8cd2ff" .. tailText .. "|r") or ""))
    title:SetTextColor(unpack(C.gold))

    local close = Button(header, "x", 22, 18, function() f:Hide() end)
    close:SetPoint("RIGHT", -6, 0)

    -- Shown only when nugsSuite is absent. _G.nugsSuite is the suite's own handle, so
    -- this also reads correctly when it is installed but switched off - a disabled
    -- suite is no more use than a missing one.
    --
    -- A note, never a warning, and never a dependency: this addon works perfectly
    -- well on its own and the suite is only worth having once you run more than one.
    if not _G.nugsSuite then
        local suite = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        suite:SetPoint("RIGHT", close, "LEFT", -10, 0)
        suite:SetText("Part of the |cff8cd2ffnugs suite|r")
        suite:SetTextColor(unpack(C.faint))
    end

    return header
end

local function Check(parent, text, getter, setter, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(ROW_H)

    local box = CreateFrame("Frame", nil, b)
    box:SetSize(14, 14)
    box:SetPoint("LEFT", 0, 0)
    Backdrop(box, C.input, 1)

    local fill = box:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 3, -3)
    fill:SetPoint("BOTTOMRIGHT", -3, 3)
    fill:SetColorTexture(unpack(C.accent))

    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", box, "RIGHT", 6, 0)
    fs:SetPoint("RIGHT", b, "RIGHT", -4, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    fs:SetTextColor(unpack(C.text))

    b:SetScript("OnClick", function()
        setter(not getter())
        Apply()
        NBA.RefreshOptions()
    end)
    b:SetScript("OnEnter", function(self)
        fs:SetTextColor(1, 1, 1)
        if tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(text)
            GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function()
        fs:SetTextColor(unpack(C.text))
        GameTooltip:Hide()
    end)

    b.Refresh = function() fill:SetShown(getter() and true or false) end
    sink[#sink + 1] = b
    return b
end

local sliderIndex = 0
local function Slider(parent, title, minV, maxV, step, getter, setter, fmt)
    sliderIndex = sliderIndex + 1
    local name = "nugsBuffAlertSlider" .. sliderIndex

    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(40)

    local titleFS = Label(holder, title, "GameFontNormalSmall")
    titleFS:SetPoint("TOPLEFT", 0, 0)

    local valueFS = Label(holder, "", "GameFontHighlightSmall", C.accent)
    valueFS:SetPoint("TOPRIGHT", 0, 0)
    valueFS:SetJustifyH("RIGHT")

    local sl
    local ok = pcall(function()
        sl = CreateFrame("Slider", name, holder, "OptionsSliderTemplate")
    end)
    if not ok or not sl then
        -- Template missing on this client: fall back to a bare slider we skin ourselves.
        sl = CreateFrame("Slider", name, holder)
        sl:SetOrientation("HORIZONTAL")
        local track = sl:CreateTexture(nil, "BACKGROUND")
        track:SetPoint("LEFT"); track:SetPoint("RIGHT")
        track:SetHeight(4)
        track:SetColorTexture(0.25, 0.25, 0.25, 1)
        sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    end
    sl:SetPoint("TOPLEFT", 2, -18)
    sl:SetPoint("TOPRIGHT", -2, -18)
    sl:SetHeight(16)
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end

    -- The template ships Low/High/Text labels we do not want.
    for _, suffix in ipairs({ "Low", "High", "Text" }) do
        local fs = sl[suffix] or _G[name .. suffix]
        if fs and fs.SetText then fs:SetText("") end
    end

    local applying = false
    sl:SetScript("OnValueChanged", function(self, value)
        if applying then return end
        -- SetValueStep does not round for us on every path, and the leftover float
        -- noise would end up in saved variables.
        value = tonumber(string.format("%.4f", math.floor(value / step + 0.5) * step))
        setter(value)
        valueFS:SetText(string.format(fmt or "%.2f", value))
        Apply()
    end)

    holder.Refresh = function()
        applying = true
        local v = getter()
        sl:SetValue(v)
        valueFS:SetText(string.format(fmt or "%.2f", v))
        applying = false
    end
    sink[#sink + 1] = holder
    return holder
end

-- Cycling choice button. A dropdown would be the obvious widget, but Blizzard has
-- renamed that one twice in two expansions, and with three or four options a
-- click-to-cycle button is fewer motions anyway.
local function Choice(parent, prefix, options, getter, setter)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(ROW_H)

    -- Two shapes of option list arrive here: {key=, label=} for the addon's own
    -- vocabularies, and {name=, path=} for a media list. The original form of these
    -- was `type(o) == "table" and o.key or o`, which looks like it handles both and
    -- does not: on a media entry `o.key` is nil, so the `and` collapses and the `or`
    -- hands back **the whole table**. Clicking the font button then wrote that table
    -- into the saved font setting, and every later refresh tried to concatenate it.
    --
    -- A key must always be a plain value, so the fallbacks are explicit and the table
    -- itself is never a possible answer.
    local function keyOf(o)
        if type(o) ~= "table" then return o end
        if o.key ~= nil then return o.key end
        return o.name
    end
    local function labelOf(o)
        if type(o) ~= "table" then return o end
        return o.label or o.name or tostring(o.key)
    end

    local btn
    btn = Button(holder, "", 100, ROW_H, function()
        local list = type(options) == "function" and options() or options
        local index = 1
        for i, o in ipairs(list) do
            if keyOf(o) == getter() then index = i break end
        end
        setter(keyOf(list[(index % #list) + 1]))
        Apply()
        NBA.RefreshOptions()
    end)
    btn:SetPoint("LEFT", 0, 0)
    btn:SetPoint("RIGHT", 0, 0)

    holder.Refresh = function()
        local list = type(options) == "function" and options() or options
        local text = tostring(getter())
        for _, o in ipairs(list) do
            if keyOf(o) == getter() then text = labelOf(o) end
        end
        btn:SetLabel(prefix .. ": " .. text)
    end
    sink[#sink + 1] = holder
    return holder
end

-- Colour swatch. Opens the game's own picker, which knows how to be a colour picker
-- better than anything hand-rolled would.
local function ShowColorPicker(r, g, b, a, hasAlpha, apply)
    local function currentAlpha()
        if ColorPickerFrame.GetColorAlpha then
            local ok, v = pcall(ColorPickerFrame.GetColorAlpha, ColorPickerFrame)
            if ok and type(v) == "number" then return v end
        end
        if _G.OpacitySliderFrame then return 1 - _G.OpacitySliderFrame:GetValue() end
        return a or 1
    end
    local function onChange()
        local nr, ng, nb = ColorPickerFrame:GetColorRGB()
        apply(nr, ng, nb, hasAlpha and currentAlpha() or a)
    end

    local info = {
        r = r, g = g, b = b,
        hasOpacity  = hasAlpha,
        opacity     = hasAlpha and (a or 1) or nil,
        swatchFunc  = onChange,
        opacityFunc = onChange,
        cancelFunc  = function() apply(r, g, b, a) end,
    }

    if ColorPickerFrame.SetupColorPickerAndShow then
        ColorPickerFrame:SetupColorPickerAndShow(info)
    else
        -- Pre-11.x shape, kept so the window is never dead on an older client.
        ColorPickerFrame.func        = info.swatchFunc
        ColorPickerFrame.opacityFunc = info.opacityFunc
        ColorPickerFrame.cancelFunc  = info.cancelFunc
        ColorPickerFrame.hasOpacity  = hasAlpha
        ColorPickerFrame.opacity     = hasAlpha and (1 - (a or 1)) or nil
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Hide()
        ColorPickerFrame:Show()
    end
end

local function Swatch(parent, text, getter, hasAlpha)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(ROW_H)

    local well = CreateFrame("Frame", nil, b)
    well:SetSize(30, 14)
    well:SetPoint("LEFT", 0, 0)
    Backdrop(well, { 0, 0, 0, 1 }, 1)

    local fill = well:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMRIGHT", -1, 1)

    local fs = Label(b, text, "GameFontHighlightSmall")
    fs:SetPoint("LEFT", well, "RIGHT", 8, 0)

    b:SetScript("OnClick", function()
        local c = getter()
        if not c then return end
        ShowColorPicker(c[1], c[2], c[3], c[4], hasAlpha, function(r, g, bb, a)
            -- Mutated in place: the colour array is handed out by reference to the
            -- display, and replacing the table would leave it holding the old one.
            c[1], c[2], c[3] = r, g, bb
            if hasAlpha then c[4] = a end
            fill:SetColorTexture(r, g, bb, hasAlpha and a or 1)
            Apply()
        end)
    end)
    b:SetScript("OnEnter", function() fs:SetTextColor(1, 1, 1) end)
    b:SetScript("OnLeave", function() fs:SetTextColor(unpack(C.text)) end)

    b.Refresh = function()
        local c = getter()
        if c then fill:SetColorTexture(c[1], c[2], c[3], hasAlpha and (c[4] or 1) or 1) end
    end
    sink[#sink + 1] = b
    return b
end

-- `onChanged` is a parameter rather than something the caller attaches afterwards,
-- because the placeholder needs OnTextChanged too and whichever of the two was set
-- last would silently win.
local function EditBox(parent, h, onEnter, placeholder, onChanged)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetHeight(h or 22)
    eb:SetAutoFocus(false)
    eb:SetFontObject("GameFontHighlightSmall")
    eb:SetTextInsets(6, 6, 0, 0)
    Backdrop(eb, C.input, 1)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if onEnter then onEnter(self:GetText()) end
    end)

    local ph
    if placeholder then
        ph = Label(eb, placeholder, "GameFontDisableSmall", C.faint)
        ph:SetPoint("LEFT", 7, 0)
    end

    -- The placeholder is updated on every change, user-driven or not, so clearing the
    -- box from code brings it back. `onChanged` only fires for real typing.
    local function update(self, user)
        if ph then ph:SetShown(eb:GetText() == "") end
        if user and onChanged then onChanged(eb:GetText()) end
    end
    eb:SetScript("OnTextChanged", update)
    eb:SetScript("OnShow", update)
    update()

    return eb
end

-- Wheel-scrolled area: no Blizzard scroll template, just a child frame we shift plus
-- a draggable position indicator on the right edge.
local function ScrollArea(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    scroll.content = content

    -- BAR_W is the grab area and is wider than the 3px line you can see: a 3px target
    -- is not something anybody can reliably hit. It overlaps the right edge of the
    -- rows underneath, which is why it is hidden outright when everything fits - an
    -- invisible strip that eats row clicks would be worse than no bar at all.
    local BAR_W = 9

    local bar = CreateFrame("Frame", nil, scroll)
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", 0, 0)
    bar:SetWidth(BAR_W)
    bar:EnableMouse(true)

    local track = bar:CreateTexture(nil, "ARTWORK")
    track:SetPoint("TOPRIGHT", 0, 0)
    track:SetPoint("BOTTOMRIGHT", 0, 0)
    track:SetWidth(3)
    track:SetColorTexture(1, 1, 1, 0.05)

    local thumb = CreateFrame("Frame", nil, bar)
    thumb:SetWidth(BAR_W)
    thumb:EnableMouse(true)
    local thumbTex = thumb:CreateTexture(nil, "OVERLAY")
    thumbTex:SetPoint("TOPRIGHT", 0, 0)
    thumbTex:SetPoint("BOTTOMRIGHT", 0, 0)
    thumbTex:SetWidth(3)
    thumbTex:SetColorTexture(unpack(C.accent))

    local function MaxScroll()
        return math.max(0, (content:GetHeight() or 1) - (scroll:GetHeight() or 1))
    end

    local function ScrollTo(value)
        scroll:SetVerticalScroll(math.max(0, math.min(MaxScroll(), value)))
        scroll:UpdateBar()
    end

    function scroll:UpdateBar()
        local viewH    = self:GetHeight() or 1
        local totalH   = content:GetHeight() or 1
        local maxScrol = math.max(0, totalH - viewH)
        if self:GetVerticalScroll() > maxScrol then self:SetVerticalScroll(maxScrol) end
        if maxScrol <= 0 then
            bar:Hide()
            return
        end
        bar:Show()
        local frac   = math.min(1, viewH / totalH)
        local thumbH = math.max(20, viewH * frac)
        local travel = viewH - thumbH
        local pos    = (self:GetVerticalScroll() / maxScrol) * travel
        thumb:SetHeight(thumbH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, -pos)
        -- Kept for the drag maths below, which needs the travel distance and cannot
        -- recompute it from a frame mid-drag without fighting its own SetPoint.
        self.thumbTravel = travel
    end

    -- Cursor position comes back in screen pixels at the root scale, so it has to be
    -- divided by the frame's effective scale before it can be compared with anything
    -- measured off the frame itself.
    local function CursorY()
        local _, y = GetCursorPosition()
        return y / (thumb:GetEffectiveScale() or 1)
    end

    local function OnDrag(self)
        local travel = scroll.thumbTravel or 0
        if travel <= 0 then return end
        -- Cursor down is a decreasing y, and scrolling down is an increasing scroll
        -- value, hence grab minus now rather than the other way round.
        local delta = (self.grabY - CursorY()) * (MaxScroll() / travel)
        ScrollTo(self.grabScroll + delta)
    end

    thumb:SetScript("OnMouseDown", function(self)
        self.grabY      = CursorY()
        self.grabScroll = scroll:GetVerticalScroll()
        thumbTex:SetColorTexture(1, 1, 1, 0.9)
        self:SetScript("OnUpdate", OnDrag)
    end)
    -- OnHide as well as OnMouseUp: releasing the button outside the frame does not
    -- always deliver OnMouseUp, and an OnUpdate left running would drag the list
    -- around with the cursor forever.
    local function EndDrag(self)
        self:SetScript("OnUpdate", nil)
        thumbTex:SetColorTexture(unpack(C.accent))
    end
    thumb:SetScript("OnMouseUp", EndDrag)
    thumb:SetScript("OnHide", EndDrag)

    -- Clicking the track pages toward the click rather than jumping to it. A jump
    -- would be a guess at where in the list that pixel means; a page is the same thing
    -- the wheel does, only faster.
    bar:SetScript("OnMouseDown", function(self)
        local viewH = scroll:GetHeight() or 1
        local top   = thumb:GetTop()
        local bot   = thumb:GetBottom()
        local y     = CursorY()
        if top and bot and y <= top and y >= bot then return end   -- on the thumb
        ScrollTo(scroll:GetVerticalScroll() + ((top and y > top) and -viewH or viewH))
    end)

    -- A frame positioned by anchors measures 0 until a layout pass has run, so a
    -- caller that sized its content from scroll:GetWidth() on the very first call
    -- builds every row zero-wide - the "the list is empty until I click a second
    -- time" bug. Only corrected when it is still zero, because several callers set a
    -- deliberate width and clobbering those would trade this bug for a layout one.
    --
    -- The width of the *scroll frame* is checked too, and that is not belt and
    -- braces. This fires during the first layout pass while the scroll frame itself
    -- still measures 0, so without the guard it copies that 0 onto the content, the
    -- content is then no longer "unset", and nothing ever corrects it. Rows anchored
    -- to the content's two top corners come out zero-wide - which still *draws*,
    -- because a FontString does not clip to its parent, but a zero-wide button has no
    -- hit rectangle. That is a list you can read and cannot click.
    scroll:SetScript("OnSizeChanged", function(self)
        local w = self:GetWidth() or 0
        if w > 1 and (self.content:GetWidth() or 0) <= 1 then
            self.content:SetWidth(w)
        end
        if self.UpdateBar then self:UpdateBar() end
    end)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local viewH    = self:GetHeight() or 1
        local maxScrol = math.max(0, (content:GetHeight() or 1) - viewH)
        self:SetVerticalScroll(math.max(0, math.min(maxScrol, self:GetVerticalScroll() - delta * 34)))
        self:UpdateBar()
    end)

    return scroll
end

--------------------------------------------------------------------------------
-- Floating lists
--
-- A cycling button is fine for three or four options and useless for forty-four:
-- with LibSharedMedia loaded the font list is as long as the window, and clicking
-- through it one entry at a time is not a way to choose anything.
--
-- A dropdown would be the obvious widget, but Blizzard has renamed that one twice in
-- two expansions. This is a plain popup list, ported from nugsCooldownPulse, and every
-- font name is drawn in its own font so the choice is visible before you make it.
--------------------------------------------------------------------------------

-- Popups share the window's near-black background, which makes a floating list hard
-- to separate from the panel behind it. This lifts the fill and draws an accent edge
-- so the thing reads as sitting ON TOP of the window rather than being part of it.
local POPUP_BG = { 0.13, 0.13, 0.15, 0.98 }

local function PopupChrome(frame)
    Backdrop(frame, POPUP_BG, 1)
    for _, p in ipairs({ { "TOPLEFT", "TOPRIGHT", "h" }, { "BOTTOMLEFT", "BOTTOMRIGHT", "h" },
                         { "TOPLEFT", "BOTTOMLEFT", "v" }, { "TOPRIGHT", "BOTTOMRIGHT", "v" } }) do
        local edge = frame:CreateTexture(nil, "OVERLAY")
        edge:SetPoint(p[1]); edge:SetPoint(p[2])
        if p[3] == "h" then edge:SetHeight(1) else edge:SetWidth(1) end
        edge:SetColorTexture(0.35, 0.72, 1.00, 0.55)
    end
end

-- SetPropagateKeyboardInput is protected during combat, and a blocked call is not a
-- Lua error: pcall does not contain it, it raises ADDON_ACTION_BLOCKED and taints the
-- addon for the rest of the session. So it is never called inside a lockdown, and the
-- next key pressed after combat ends restores propagation on its own.
local function SafePropagate(frame, value)
    if InCombatLockdown() then return end
    frame:SetPropagateKeyboardInput(value)
end

-- Shared behaviour for every floating list: closes when you click away from it,
-- closes on Escape, and never outlives the window it belongs to.
--
-- There is no "clicked anywhere" event, so the outside click is caught by a full
-- screen button underneath the popup, shown and hidden with it. It swallows the click
-- that dismisses - first click closes, second one acts - which is how every dropdown
-- in the game behaves, Blizzard's included.
local function AttachPopupBehaviour(popup)
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:RegisterForClicks("AnyUp")
    catcher:Hide()
    catcher:SetScript("OnClick", function() popup:Hide() end)

    -- Escape closes the list rather than the window behind it. Propagation is left on
    -- for every other key, so this never swallows movement or typing; it is turned off
    -- only for the Escape actually being handled, which is what stops the same press
    -- also reaching CloseSpecialWindows and shutting the window.
    popup:EnableKeyboard(true)
    SafePropagate(popup, true)
    popup:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" and not InCombatLockdown() then
            SafePropagate(self, false)
            self:Hide()
        else
            SafePropagate(self, true)
        end
    end)

    -- The anchor is read back from the popup's own SetPoint rather than passed in, so
    -- this works for every caller without any of them having to remember to say who
    -- owns them. IsVisible is false when any ancestor is hidden, which is exactly the
    -- case being watched for.
    local function WatchOwner(self)
        if self.owner and not self.owner:IsVisible() then self:Hide() end
    end

    popup:HookScript("OnShow", function(self)
        local _, relativeTo = self:GetPoint(1)
        self.owner = relativeTo
        self:SetScript("OnUpdate", WatchOwner)
        catcher:SetFrameStrata(self:GetFrameStrata())
        catcher:SetFrameLevel(110)
        self:SetFrameLevel(120)
        catcher:Show()
    end)
    popup:HookScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
        SafePropagate(self, true)
        catcher:Hide()
    end)
    return popup
end

-- Drops down if there is room and opens upwards if there is not. Clamping alone would
-- slide the list over the button that opened it, hiding the thing being changed.
local function PlacePopup(popup, anchorTo)
    popup:ClearAllPoints()
    local below = (anchorTo:GetBottom() or 0) - popup:GetHeight()
    if below < 20 then
        popup:SetPoint("BOTTOMLEFT", anchorTo, "TOPLEFT", 0, 2)
    else
        popup:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -2)
    end
    popup:Show()
end

local function EnsurePopup(existing, width, height)
    if existing then return existing end
    local popup = CreateFrame("Frame", nil, UIParent)
    popup:SetSize(width, height)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:EnableMouse(true)
    popup:SetClampedToScreen(true)
    PopupChrome(popup)
    popup.scroll = ScrollArea(popup)
    popup.scroll:SetPoint("TOPLEFT", 5, -5)
    popup.scroll:SetPoint("BOTTOMRIGHT", -5, 5)
    popup.rows = {}
    AttachPopupBehaviour(popup)
    return popup
end

-- Builds the rows for a popup from a media list. `style` is handed each row so the
-- font list can draw every name in its own face.
local function FillPopup(popup, entries, onPick, style)
    local content = popup.scroll.content
    -- Width from the popup's own SetSize, NOT from scroll:GetWidth(). The scroll is
    -- sized by anchors, so on the very first call - the frame having been created
    -- microseconds earlier with no layout pass yet - it measures 0, every row is built
    -- zero-wide, and the list looks empty until you click a second time.
    content:SetWidth(popup:GetWidth() - 10)

    for index, entry in ipairs(entries) do
        local row = popup.rows[index]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(22)
            row:SetPoint("TOPLEFT", 0, -(index - 1) * 22)
            row:SetPoint("TOPRIGHT", 0, -(index - 1) * 22)
            row.stripe = row:CreateTexture(nil, "BACKGROUND")
            row.stripe:SetAllPoints()
            row.stripe:SetColorTexture(1, 1, 1, 0)
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.label:SetPoint("LEFT", 6, 0)
            row.label:SetPoint("RIGHT", -6, 0)
            row.label:SetJustifyH("LEFT")
            row.label:SetWordWrap(false)
            row:SetScript("OnEnter", function(self) self.stripe:SetColorTexture(unpack(C.rowB)) end)
            row:SetScript("OnLeave", function(self) self.stripe:SetColorTexture(1, 1, 1, 0) end)
            popup.rows[index] = row
        end

        row.label:SetFontObject("GameFontHighlightSmall")
        row.label:SetText(entry.name)
        if style then style(row, entry) end
        row:SetScript("OnClick", function()
            onPick(entry)
            popup:Hide()
        end)
        row:Show()
    end

    for index = #entries + 1, #popup.rows do popup.rows[index]:Hide() end

    content:SetHeight(math.max(1, #entries * 22))
    popup.scroll:SetVerticalScroll(0)
    popup.scroll:UpdateBar()
end

local fontPopup

local function ToggleFontPicker(anchorTo, onPick)
    if fontPopup and fontPopup:IsShown() then fontPopup:Hide() return end
    fontPopup = EnsurePopup(fontPopup, 232, 268)
    FillPopup(fontPopup, NBA.FontList(), function(entry) onPick(entry.name) end,
        function(row, entry)
            -- Preview in the font itself; fall back quietly if the file will not load,
            -- and say so rather than showing a name that will not draw.
            local ok, applied = pcall(row.label.SetFont, row.label, entry.path, 13, "")
            if not ok or applied == false then
                row.label:SetFontObject("GameFontHighlightSmall")
                row.label:SetText(entry.name .. " |cff888888(unavailable)|r")
            end
        end)
    PlacePopup(fontPopup, anchorTo)
end

local soundPopup

-- Clicking a row picks it AND plays it, because a list of sound names tells you
-- nothing until you hear one.
local function ToggleSoundPicker(anchorTo, onPick)
    if soundPopup and soundPopup:IsShown() then soundPopup:Hide() return end
    soundPopup = EnsurePopup(soundPopup, 232, 268)

    local entries = { { name = "No sound", none = true } }
    for _, e in ipairs(NBA.SoundList()) do entries[#entries + 1] = e end
    if #entries == 1 then
        entries[#entries + 1] = { name = "|cff888888LibSharedMedia is not loaded|r", dead = true }
    end

    FillPopup(soundPopup, entries, function(entry)
        if entry.dead then return end
        onPick(entry.none and "" or entry.name)
    end)
    PlacePopup(soundPopup, anchorTo)
end

local voicePopup

-- Clicking a voice picks it and says its own name in it, for the same reason the sound
-- list plays: a list of voice names tells you nothing about how they sound.
local function ToggleVoicePicker(anchorTo, onPick)
    if voicePopup and voicePopup:IsShown() then voicePopup:Hide() return end
    voicePopup = EnsurePopup(voicePopup, 232, 268)

    local entries = NBA.TtsVoices()
    if #entries == 0 then
        entries = { { name = "|cff888888No voices on this client|r", dead = true } }
    end

    FillPopup(voicePopup, entries, function(entry)
        if entry.dead then return end
        onPick(entry.voiceID)
    end)
    PlacePopup(voicePopup, anchorTo)
end

-- A button whose label is the current value and whose click opens one of the lists
-- above. `onOpen` is handed the button, so the popup anchors under the control that
-- opened it rather than under the window.
local function MediaButton(parent, prefix, getter, onOpen)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetHeight(ROW_H)

    local btn
    btn = Button(holder, "", 100, ROW_H, function() onOpen(btn) end)
    btn:SetPoint("LEFT", 0, 0)
    btn:SetPoint("RIGHT", 0, 0)

    holder.Refresh = function()
        local v = getter()
        if v == nil or v == "" then v = "none" end
        btn:SetLabel(prefix .. ": " .. tostring(v))
    end
    sink[#sink + 1] = holder
    return holder
end

--------------------------------------------------------------------------------
-- Column layout
-- Widgets declare when they are relevant (`show`), and the column re-flows around
-- whatever is hidden. That is what lets one panel serve a flashing alert and a
-- holding one without leaving holes where the other's controls would have been.
--------------------------------------------------------------------------------

local function NewColumn(parent, xOffset, width)
    local col = { parent = parent, x = xOffset, width = width, items = {} }

    function col:Add(region, height, show, indent)
        local isText = region.GetObjectType and region:GetObjectType() == "FontString"
        self.items[#self.items + 1] = {
            region = region, h = height, show = show,
            indent = indent or 0, stretch = not isText,
        }
        return region
    end

    -- The leading gap carries the section's own visibility, so a section that does not
    -- apply leaves no hole where it would have been.
    function col:Header(text, show)
        self:Gap(6, show)
        return self:Add(SectionHeader(self.parent, text), 22, show)
    end

    -- The declared height is a floor, not the answer. Layout measures the wrapped
    -- text and uses whichever is larger - see the note there for why counting
    -- newlines was never going to work.
    function col:Hint(text, show)
        local fs = Label(self.parent, text, "GameFontDisableSmall", C.faint)
        fs:SetWordWrap(true)
        return self:Add(fs, 16, show)
    end

    function col:Gap(h, show)
        self.items[#self.items + 1] = { h = h, show = show }
    end

    function col:Layout()
        local y = 0
        for _, item in ipairs(self.items) do
            local visible = (not item.show) or item.show()
            if item.region then
                if visible then
                    item.region:Show()
                    item.region:ClearAllPoints()
                    item.region:SetPoint("TOPLEFT", self.parent, "TOPLEFT",
                        self.x + item.indent, -y)
                    local h = item.h
                    if item.stretch then
                        item.region:SetPoint("TOPRIGHT", self.parent, "TOPLEFT",
                            self.x + self.width, -y)
                    else
                        item.region:SetWidth(self.width - item.indent)
                        -- Measured, not declared. Every explanatory line in this
                        -- window wraps, and the height they were given only ever
                        -- counted the newlines somebody typed - so a two-line hint
                        -- was allotted one line's worth and the control under it was
                        -- drawn through the tail of the sentence. Asking the
                        -- FontString how tall it actually became is the only version
                        -- of this that cannot drift as the wording changes.
                        local sh = item.region.GetStringHeight and item.region:GetStringHeight()
                        if sh and sh > 0 then h = math.max(h, math.ceil(sh) + 4) end
                    end
                    y = y + h
                else
                    item.region:Hide()
                end
            elseif visible then
                y = y + item.h
            end
        end
        return y
    end

    return col
end

--------------------------------------------------------------------------------
-- Readability marks
--
-- The one thing this window knows that the player cannot find out any other way.
-- Phrased as what will happen on a pull, not as an API fact, because that is the
-- question actually being asked.
--------------------------------------------------------------------------------

local STATUS_COLOR = {
    collides       = C.bad,
    always         = C.good,
    bridge         = C.accent,
    ["bridge-add"] = C.warn,
    ["bridge-off"] = C.warn,
    sometimes      = C.warn,
    never          = C.bad,
    none           = C.faint,
}

local STATUS_SHORT = {
    collides       = "another spell shares this name",
    always         = "reads everywhere",
    bridge         = "reads via Cooldown Manager",
    ["bridge-add"] = "add it to the Cooldown Manager",
    ["bridge-off"] = "needs the Cooldown Manager on",
    sometimes      = "out of combat only",
    never          = "never reads in combat",
    none           = "no spell chosen",
}

local function StatusFor(spellID)
    local key, why = NBA.SpellStatus(spellID)
    return key, why, STATUS_COLOR[key] or C.faint, STATUS_SHORT[key] or key
end

--------------------------------------------------------------------------------
-- Alert list
--------------------------------------------------------------------------------

local function SelectAlert(id)
    selectedID = id
    RebuildAlertList()
    NBA.RefreshOptions()
end

-- The list is grouped by the spec each alert is pinned to, because an alert list is
-- spec-specific in practice and a flat one stops being readable at about a dozen
-- entries. Order within a group is still the order you put them in.
--
-- Groups come out: Any spec, the spec you are in, the rest of your class, then other
-- classes. That puts everything that can fire today at the top and everything that
-- belongs to a character you are not playing at the bottom, which is the order you
-- want when you open the window to fix one thing.
local function AlertGroups()
    local db = NBA.db
    local byID, order = {}, {}

    for _, id in ipairs(db.order) do
        local a = db.alerts[id]
        if a then
            local key = a.specID or 0
            if not byID[key] then
                byID[key] = { specID = key, ids = {} }
                order[#order + 1] = byID[key]
            end
            byID[key].ids[#byID[key].ids + 1] = id
        end
    end

    local current = NBA.CurrentSpecID()
    local function rank(g)
        if g.specID == 0        then return 0 end
        if g.specID == current  then return 1 end
        local standing = NBA.SpecStanding(g.specID)
        if standing == "inactive" then return 2 end
        return 3
    end

    for _, g in ipairs(order) do
        g.name, g.icon = NBA.SpecInfo(g.specID)
        g.standing = (g.specID == 0) and "active" or NBA.SpecStanding(g.specID)
        g.rank = rank(g)
    end

    table.sort(order, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return (a.name or "") < (b.name or "")
    end)

    return order
end

local function GroupHeader(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(22)
    Backdrop(row, { 1, 1, 1, 0.045 }, nil)

    row.arrow = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.arrow:SetPoint("LEFT", 8, 0)
    row.arrow:SetWidth(12)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(14, 14)
    row.icon:SetPoint("LEFT", row.arrow, "RIGHT", 2, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.name = Label(row, "", "GameFontNormalSmall", C.accent)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)

    row.count = Label(row, "", "GameFontDisableSmall", C.faint)
    row.count:SetPoint("RIGHT", -8, 0)
    return row
end

RebuildAlertList = function()
    if not alertList then return end
    local db = NBA.db
    local content = alertList.content
    alertList.rows    = alertList.rows or {}
    alertList.headers = alertList.headers or {}

    local groups = AlertGroups()
    local y, usedRows, usedHeaders = 0, 0, 0

    for _, group in ipairs(groups) do
        usedHeaders = usedHeaders + 1
        local header = alertList.headers[usedHeaders] or GroupHeader(content)
        alertList.headers[usedHeaders] = header

        local collapsed = db.collapsed[group.specID] and true or false

        header:SetPoint("TOPLEFT", 0, -y)
        header:SetPoint("TOPRIGHT", 0, -y)
        header.arrow:SetText(collapsed and "+" or "-")
        header.icon:SetShown(group.icon ~= nil)
        if group.icon then header.icon:SetTexture(group.icon) end
        header.name:SetText(group.name)
        -- Another class's alerts are not broken, they are simply not yours today, and
        -- the list says which by colour rather than by hiding them.
        header.name:SetTextColor(unpack(group.standing == "other" and C.faint or C.accent))
        header.count:SetText(("%d"):format(#group.ids))
        header:SetScript("OnClick", function()
            db.collapsed[group.specID] = not db.collapsed[group.specID]
            RebuildAlertList()
        end)
        header:Show()
        y = y + 23

        if not collapsed then
            for _, id in ipairs(group.ids) do
                usedRows = usedRows + 1
                y = RebuildAlertRow(content, usedRows, id, group, y)
            end
        end
    end

    for i = usedHeaders + 1, #alertList.headers do alertList.headers[i]:Hide() end
    for i = usedRows   + 1, #alertList.rows    do alertList.rows[i]:Hide()    end

    content:SetHeight(math.max(1, y))
    alertList:UpdateBar()
end

RebuildAlertRow = function(content, index, id, group, y)
    local db  = NBA.db
    local a   = db.alerts[id]
    local row = alertList.rows[index]
    if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(32)
            Backdrop(row, C.rowA, nil)

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(22, 22)
            row.icon:SetPoint("LEFT", 8, 0)
            row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

            -- Both lines stop short of the status dot and neither wraps, so a long
            -- spell name is cut with an ellipsis instead of growing under the dot.
            row.name = Label(row, "", "GameFontHighlightSmall")
            row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
            row.name:SetPoint("RIGHT", row, "RIGHT", -20, 0)
            row.name:SetWordWrap(false)

            row.sub = Label(row, "", "GameFontDisableSmall", C.faint)
            row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 1)
            row.sub:SetPoint("RIGHT", row, "RIGHT", -20, 0)
            row.sub:SetWordWrap(false)

            row.mark = row:CreateTexture(nil, "OVERLAY")
            row.mark:SetSize(3, 24)
            row.mark:SetPoint("LEFT", 0, 0)
            row.mark:SetColorTexture(unpack(C.accent))

            row.dot = row:CreateTexture(nil, "OVERLAY")
            row.dot:SetSize(6, 6)
            row.dot:SetPoint("RIGHT", -8, 0)
            row.dot:SetTexture("Interface\\Buttons\\WHITE8X8")

            -- Right-click enables or disables rather than opening a menu: it is the
            -- only per-row action worth a click of its own, and a menu for one item is
            -- a menu nobody reads.
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            alertList.rows[index] = row
    end

    -- An alert belonging to a class you are not playing is dimmed rather than hidden.
    -- It is not broken and it is not switched off; it simply cannot fire on this
    -- character, and hiding it would make a profile look like it had lost entries.
    local elsewhere = (group.standing == "other")
    local dim       = elsewhere or not a.enabled

    row.alertID = id
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetPoint("TOPRIGHT", 0, -y)

    local label = a.name
    if a.spellID and (not a.name or a.name == "" or a.name:match("^Alert %d+$")) then
        label = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(a.spellID)) or a.name
    end
    row.icon:SetTexture(NBA.AlertIcon(a))
    row.icon:SetDesaturated(dim)
    row.icon:SetAlpha(elsewhere and 0.45 or 1)
    row.name:SetText(label)
    row.name:SetTextColor(unpack(dim and C.faint or C.text))

    local trig = "on gain"
    if a.trigger == "loss"    then trig = "on drop"    end
    if a.trigger == "missing" then trig = "when missing" end
    row.sub:SetText(string.format("%s  |cff666666%s, %s|r",
        NBA.UnitLabel(a.unit), trig,
        (a.trigger ~= "missing" and a.mode == "hold") and "held" or "flash"))

    local _, _, colour = StatusFor(a.spellID)
    row.dot:SetColorTexture(colour[1], colour[2], colour[3], dim and 0.3 or 1)

    row.mark:SetShown(id == selectedID)
    row.bgTex:SetColorTexture(unpack(id == selectedID and C.rowB or C.rowA))

    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            local al = NBA.db.alerts[self.alertID]
            al.enabled = not al.enabled
            if not al.enabled then NBA.Display:Stop(self.alertID) end
        end
        SelectAlert(self.alertID)
    end)
    row:Show()

    return y + 33
end

--------------------------------------------------------------------------------
-- The spell picker
--
-- Overlays the settings side rather than opening a second window, because it is a
-- step in editing an alert and not a thing of its own.
--
-- Two sources, in this order: what is genuinely on the unit right now, and what has
-- been on this character before. The first is authoritative and is what makes the id
-- correct - the number printed on a website is as often the ability as the aura it
-- applies, and picking the aura off yourself cannot get that wrong. The second is
-- what makes the picker useful in a city with no buffs up.
--------------------------------------------------------------------------------

local pickerUnit = "player"

-- Three sources, and the order is the point. The Cooldown Manager's own list is not a
-- guess about what your spec procs - it is the game's list, every entry on it is
-- readable in combat through the bridge, and it is therefore the answer for nearly
-- every proc anyone would build an alert on. Live auras come second because they are
-- authoritative about the *id* but say nothing about whether it will read in a raid.
-- The remembered catalog is last, because it is only a convenience.
local SOURCES = {
    { key = "cdm",  label = "Cooldown Manager (this spec)" },
    { key = "live", label = "On a unit right now"          },
    { key = "seen", label = "Everything seen before"       },
}

local pickerSource = "cdm"

local function PickerEntries(filter)
    local out = {}

    if pickerSource == "cdm" then
        for _, e in ipairs(NBA.CooldownManagerList()) do
            out[#out + 1] = {
                spellID  = e.spellID, name = e.name, icon = e.icon,
                category = e.category, tracked = true, rank = e.isBuff and 0 or 1,
            }
        end

    elseif pickerSource == "live" then
        local live = NBA.ScanAuras(pickerUnit)
        if live then
            for _, e in ipairs(live) do
                out[#out + 1] = {
                    spellID = e.spellID, name = e.name, icon = e.icon,
                    harmful = e.harmful, rank = e.mine and 0 or 1,
                }
            end
        end

    else
        local catalog = NBA.char and NBA.char.catalog
        if catalog then
            for spellID, e in pairs(catalog) do
                out[#out + 1] = {
                    spellID = spellID, name = e.name or ("spell " .. spellID),
                    icon = e.icon, harmful = e.harmful, rank = 0,
                }
            end
        end
    end

    if filter and filter ~= "" then
        local needle = filter:lower()
        local kept = {}
        for _, e in ipairs(out) do
            if e.name:lower():find(needle, 1, true) or tostring(e.spellID):find(needle, 1, true) then
                kept[#kept + 1] = e
            end
        end
        out = kept
    end

    table.sort(out, function(x, y)
        if x.rank ~= y.rank then return (x.rank or 0) < (y.rank or 0) end
        return x.name < y.name
    end)
    return out
end

local function ChooseSpell(spellID)
    local a = A()
    if not a then return end
    a.spellID = spellID
    -- The alert takes the spell's name unless the player has already named it
    -- something. An alert called "Alert 3" is a placeholder, not a decision.
    if not a.name or a.name == "" or a.name:match("^Alert %d+$") or a.name == "My first alert" then
        a.name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)) or a.name
    end
    picker:Hide()
    Apply()
    RebuildAlertList()
    NBA.RefreshOptions()
end

local function BuildPicker(parent)
    -- Opaque, not the window's 0.96: this is meant to occlude, and at 0.96 the panel
    -- behind it reads through as a second set of headings sharing the same rows.
    local f = Panel(parent, { C.bg[1], C.bg[2], C.bg[3], 1 })
    f:SetAllPoints(parent)
    f:EnableMouse(true)

    -- Above every sibling in the content panel. Same numbers the dropdown popups in
    -- the other nugs addons use, so an overlay is always at 120 whichever addon it is.
    f:SetFrameLevel((parent:GetFrameLevel() or 0) + 120)

    -- Hiding the panel underneath is not only about what can be seen. A shown panel
    -- keeps taking mouse input through the gaps between this frame's own widgets, so
    -- a click meant for a spell row can land on a slider behind it.
    f:HookScript("OnShow", function(self)
        local p = panels[currentKey]
        if p then p.frame:Hide() end
        SafePropagate(self, true)
    end)
    f:HookScript("OnHide", function(self)
        SafePropagate(self, true)
        NBA.RefreshOptions()
    end)

    -- Escape closes the picker rather than the window behind it. Propagation is left
    -- on for every other key, so this never swallows movement or typing; it is turned
    -- off only for the Escape actually being handled, which is what stops the same
    -- press also reaching CloseSpecialWindows and shutting the whole window.
    f:EnableKeyboard(true)
    SafePropagate(f, true)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" and not InCombatLockdown() then
            SafePropagate(self, false)
            self:Hide()
        else
            SafePropagate(self, true)
        end
    end)

    f:Hide()

    local title = Label(f, "Choose the spell to watch", "GameFontNormal", C.gold)
    title:SetPoint("TOPLEFT", 14, -12)

    local close = Button(f, "Cancel", 70, 20, function() f:Hide() end)
    close:SetPoint("TOPRIGHT", -12, -10)

    local sourceBtn
    sourceBtn = Button(f, "", 210, 20, function()
        local index = 1
        for i, s in ipairs(SOURCES) do if s.key == pickerSource then index = i break end end
        pickerSource = SOURCES[(index % #SOURCES) + 1].key
        RefreshPicker()
    end)
    sourceBtn:SetPoint("TOPLEFT", 14, -38)
    f.sourceBtn = sourceBtn

    local unitBtn
    unitBtn = Button(f, "", 100, 20, function()
        local list = NBA.UNITS
        local index = 1
        for i, u in ipairs(list) do if u.key == pickerUnit then index = i break end end
        pickerUnit = list[(index % #list) + 1].key
        RefreshPicker()
    end)
    unitBtn:SetPoint("LEFT", sourceBtn, "RIGHT", 6, 0)
    f.unitBtn = unitBtn

    local search = EditBox(f, 20, nil, "search by name or id", function() RefreshPicker() end)
    search:SetPoint("LEFT", unitBtn, "RIGHT", 6, 0)
    search:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    search:SetPoint("TOP", sourceBtn, "TOP", 0, 0)
    f.search = search

    local note = Label(f, "", "GameFontDisableSmall", C.faint)
    note:SetPoint("TOPLEFT", 14, -64)
    note:SetPoint("RIGHT", -12, 0)
    note:SetWordWrap(true)
    f.note = note

    -- Hung off the bottom of the note rather than a fixed offset, because the note is
    -- a different number of lines per source and a fixed one either wasted a band of
    -- empty space or let the longest wording run down into the first row.
    local list = ScrollArea(f)
    list:SetPoint("TOPLEFT", note, "BOTTOMLEFT", -2, -10)
    list:SetPoint("BOTTOMRIGHT", -12, 44)
    -- Given a real width up front rather than left to the scroll frame's first
    -- layout pass, exactly as the panels are. Every list in the suite that works
    -- does this; the two that were left to resolve themselves are the two that broke.
    list.content:SetWidth(CONTENT_W - 24)
    f.list = list

    -- Manual entry stays, because a buff you cannot currently put on yourself - a
    -- raid cooldown somebody else presses - has no other way in.
    local idLabel = Label(f, "or type a spell id:", "GameFontNormalSmall")
    idLabel:SetPoint("BOTTOMLEFT", 14, 14)

    local idBox = EditBox(f, 20, function(text)
        local id = tonumber(text)
        if not id then
            NBA.Print("that is not a number.")
            return
        end
        local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
        if not name then
            NBA.Print(("no spell %d exists on this client."):format(id))
            return
        end
        ChooseSpell(id)
    end, "e.g. 1719")
    idBox:SetPoint("LEFT", idLabel, "RIGHT", 8, 0)
    idBox:SetWidth(120)

    return f
end

RefreshPicker = function()
    if not picker or not picker:IsShown() then return end

    local label = pickerSource
    for _, s in ipairs(SOURCES) do if s.key == pickerSource then label = s.label end end
    picker.sourceBtn:SetLabel(label)

    -- The unit only means anything to the live scan; the other two sources are not
    -- about a unit at all, and a control that does nothing is worse than no control.
    picker.unitBtn:SetShown(pickerSource == "live")
    picker.unitBtn:SetLabel("On: " .. NBA.UnitLabel(pickerUnit))

    local entries = PickerEntries(picker.search:GetText())
    local content = picker.list.content
    picker.rows = picker.rows or {}

    if pickerSource == "cdm" then
        if #entries == 0 then
            picker.note:SetText("|cffe0b040The Cooldown Manager has nothing tracked for this "
                .. "spec.|r Turn it on in Blizzard's options and choose which buffs it "
                .. "watches; everything it tracks becomes readable here during a fight.")
        else
            picker.note:SetText("Blizzard's own list for the spec you are in - not a guess. "
                .. "Buffs are listed first. |cffe0b040A spell here only reads during a fight "
                .. "while the Cooldown Manager is actually set to show it|r - the list is what "
                .. "it knows, not what it is tracking, so check its settings for anything "
                .. "marked in orange.")
        end
    elseif pickerSource == "live" then
        if NBA.AurasAreSecret() then
            picker.note:SetText("|cffe0b040In combat the game will not list what is on a unit.|r "
                .. "Come out of combat for a live list, or use the Cooldown Manager source.")
        else
            picker.note:SetText("What is actually on the unit right now. This is the only way "
                .. "to be certain of an id - but being readable here says nothing about "
                .. "whether it will read in a raid, which is what the mark on the right is for.")
        end
    else
        picker.note:SetText("Every aura this character has had on it, out of combat. "
            .. "A convenience for finding something you cannot put up right now.")
    end

    local y = 0
    for i, e in ipairs(entries) do
        local row = picker.rows[i]
        if not row then
            row = CreateFrame("Button", nil, content)
            row:SetHeight(26)
            Backdrop(row, C.rowA, nil)

            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(18, 18)
            row.icon:SetPoint("LEFT", 6, 0)
            row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

            row.name = Label(row, "", "GameFontHighlightSmall")
            row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)

            row.id = Label(row, "", "GameFontDisableSmall", C.faint)
            row.id:SetPoint("RIGHT", -10, 0)
            row.id:SetJustifyH("RIGHT")

            row.status = Label(row, "", "GameFontDisableSmall", C.faint)
            row.status:SetPoint("RIGHT", row.id, "LEFT", -12, 0)
            row.status:SetJustifyH("RIGHT")

            row:SetScript("OnEnter", function(self)
                self.bgTex:SetColorTexture(unpack(C.rowB))
            end)
            row:SetScript("OnLeave", function(self)
                self.bgTex:SetColorTexture(unpack(C.rowA))
            end)
            picker.rows[i] = row
        end

        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("TOPRIGHT", 0, -y)
        row.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local tag = ""
        if e.harmful  then tag = " |cff996666(debuff)|r"    end
        if e.category then tag = " |cff666666" .. e.category .. "|r" end
        row.name:SetText(e.name .. tag)
        row.name:SetTextColor(unpack((e.rank or 0) == 0 and C.text or C.faint))
        row.id:SetText(tostring(e.spellID))

        local _, _, colour, short = StatusFor(e.spellID)
        row.status:SetText(short)
        row.status:SetTextColor(unpack(colour))

        row:SetScript("OnClick", function() ChooseSpell(e.spellID) end)
        row:Show()
        y = y + 27
    end

    for i = #entries + 1, #picker.rows do
        picker.rows[i]:Hide()
    end

    content:SetHeight(math.max(1, y))
    picker.list:UpdateBar()
end

ShowPicker = function()
    if not picker then return end
    picker:Show()
    RefreshPicker()
end

--------------------------------------------------------------------------------
-- Panels
--------------------------------------------------------------------------------

local TABS = {
    { key = "alert", label = "Alert" },
    { key = "look",  label = "Look"  },
    { key = "sound", label = "Sound" },
    { key = "place", label = "Place" },
}

local function Selected() return A() end
local function Always() return true end

local function BuildAlertPanel(parent)
    local left  = NewColumn(parent, 0, COL_W)
    local right = NewColumn(parent, COL_W + COL_GAP, COL_W)

    --------------------------------------------------------------------- left
    left:Header("The spell", Always)

    -- The spell row is a button rather than a label, because the whole point of the
    -- picker is that it is one click away from wherever you notice the spell is wrong.
    local spellRow = CreateFrame("Button", nil, parent)
    spellRow:SetHeight(40)
    Backdrop(spellRow, C.input, 1)

    local sIcon = spellRow:CreateTexture(nil, "ARTWORK")
    sIcon:SetSize(28, 28)
    sIcon:SetPoint("LEFT", 6, 0)
    sIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Bounded on the right and not wrapping: the status line under the name is a
    -- whole sentence's worth of text in a 40px row, and left unbounded it ran out of
    -- the row and across the column beside it.
    local sName = Label(spellRow, "", "GameFontHighlightSmall")
    sName:SetPoint("TOPLEFT", sIcon, "TOPRIGHT", 8, -1)
    sName:SetPoint("RIGHT", spellRow, "RIGHT", -8, 0)
    sName:SetWordWrap(false)

    local sSub = Label(spellRow, "", "GameFontDisableSmall", C.faint)
    sSub:SetPoint("BOTTOMLEFT", sIcon, "BOTTOMRIGHT", 8, 1)
    sSub:SetPoint("RIGHT", spellRow, "RIGHT", -8, 0)
    sSub:SetWordWrap(false)

    spellRow:SetScript("OnClick", ShowPicker)
    spellRow:SetScript("OnEnter", function(self) self.bgTex:SetColorTexture(unpack(C.btnHi)) end)
    spellRow:SetScript("OnLeave", function(self) self.bgTex:SetColorTexture(unpack(C.input)) end)
    spellRow.Refresh = function()
        local a = A()
        if not a then return end
        sIcon:SetTexture(NBA.AlertIcon(a))
        if a.spellID then
            sName:SetText((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(a.spellID))
                          or ("spell " .. a.spellID))
            local _, _, colour, short = StatusFor(a.spellID)
            sSub:SetText(("%d  -  %s"):format(a.spellID, short))
            sSub:SetTextColor(unpack(colour))
        else
            sName:SetText("Click to choose a spell")
            sSub:SetText("nothing is being watched yet")
            sSub:SetTextColor(unpack(C.faint))
        end
    end
    sink[#sink + 1] = spellRow
    left:Add(spellRow, 44, Always)

    -- The sentence under the row is the honest part of this addon. It says what will
    -- happen on a pull, in words, rather than leaving the player to discover it.
    local why = Label(parent, "", "GameFontDisableSmall", C.faint)
    why:SetWordWrap(true)
    why.Refresh = function()
        local a = A()
        if not a then return end
        local _, text = StatusFor(a.spellID)
        why:SetText(text or "")
    end
    sink[#sink + 1] = why
    left:Add(why, 42, Always)

    left:Add(Choice(parent, "Watch", NBA.UNITS,
        function() return A() and A().unit or "player" end,
        function(v) A().unit = v end), ROW_H, Selected)

    -- Shown only when it applies, because it is a caveat rather than a rule and
    -- nobody watching their own procs needs to read it.
    left:Hint("Watching someone other than yourself works, but it is thinner than it "
              .. "looks. Out of combat it always works. In a fight the game only answers "
              .. "about another unit for spells it has declassified - raid buffs and "
              .. "healer HoTs, mostly - and for whatever the Cooldown Manager is tracking "
              .. "on your target. Your own buffs are the case this is best at.",
        function() local a = A() return a and a.unit ~= "player" end)

    left:Add(Check(parent, "Only when I caused it",
        function() return A() and A().mineOnly end,
        function(v) A().mineOnly = v end,
        "Ignores the same buff when it came from somebody else. Whether the game will "
        .. "answer this in combat depends on the spell, and it stands down rather than "
        .. "guessing when it cannot."), ROW_H, Selected)

    -- Typed rather than dragged. Stack caps run to fifty and beyond, and any slider
    -- wide enough for those is one where the useful low numbers are a few pixels
    -- apart - so the control that fits every buff is a box.
    left:Add(Label(parent, "Only at this many stacks", "GameFontNormalSmall"), 18, Selected)

    local stackBox = EditBox(parent, 22, function(text)
        local a = A()
        if not a then return end
        a.minStacks = math.max(0, math.floor(tonumber(text) or 0))
        Apply()
        NBA.RefreshOptions()
    end, "0 for any number")
    stackBox.Refresh = function()
        local a = A()
        if a and not stackBox:HasFocus() then
            stackBox:SetText((a.minStacks or 0) > 0 and tostring(a.minStacks) or "")
        end
    end
    sink[#sink + 1] = stackBox
    left:Add(stackBox, 26, Selected)

    left:Hint("Zero for any number. Set it to the count you actually care about and the "
              .. "alert treats anything below that as the buff not being up at all - so it "
              .. "fires when the buff reaches the number, and drops when it falls back "
              .. "under.",
        function() local a = A() return a and (a.minStacks or 0) > 1 end)

    -- The specific, predictable case, called out rather than left to be discovered in
    -- a fight: a spell reached only through the Cooldown Manager gives us an aura to
    -- point at but nothing readable about it, so a threshold on one can never be met
    -- in combat and the alert correctly - and invisibly - stays quiet.
    left:Hint("|cffe0b040This buff's stack count cannot be read during a fight.|r The game "
              .. "will say the buff is up, through the Cooldown Manager, but not how many "
              .. "stacks it has - so with a number set here the alert stays quiet in combat "
              .. "rather than guessing. Clear this box and it will fire; the count can still "
              .. "be shown on the alert itself, because showing one does not require reading "
              .. "it.",
        function()
            local a = A()
            return a and (a.minStacks or 0) > 1 and NBA.SpellIsReadable(a.spellID) == false
        end)

    left:Hint("Whether the game will tell us a stack count depends on the spell, and it is "
              .. "not the same question as whether it will tell us the buff is up. Use "
              .. "|cff6fc2ff/nba stacks|r with the buff on you to find out - if it cannot be "
              .. "read, the alert stays quiet rather than guessing.",
        function()
            local a = A()
            return a and (a.minStacks or 0) > 1 and NBA.SpellIsReadable(a.spellID) ~= false
        end)

    left:Add(Choice(parent, "Spec",
        function()
            local here = NBA.CurrentSpecID()
            local list = { { key = 0, label = "Any spec" },
                           { key = here, label = NBA.SpecName(here) } }
            -- An alert pinned to a spec you are not currently in still has to show its
            -- own pin, or the button would read as the raw spec id and cycling would
            -- silently move the alert to whichever spec you happened to be sitting in.
            local a = A()
            if a and a.specID and a.specID ~= 0 and a.specID ~= here then
                table.insert(list, 2, { key = a.specID, label = NBA.SpecName(a.specID) })
            end
            return list
        end,
        function() return A() and A().specID or 0 end,
        function(v) A().specID = v end), ROW_H, Selected)

    left:Hint("Alerts are shared across your characters. Pinning one to a spec keeps a "
              .. "Retribution proc off your Holy bars without deleting it.", Selected)

    left:Header("Name", Always)
    local nameBox = EditBox(parent, 22, function(text)
        local a = A()
        if not a then return end
        a.name = (text ~= "" and text) or "Alert"
        RebuildAlertList()
    end, "what to call it in the list")
    nameBox.Refresh = function()
        local a = A()
        if a and not nameBox:HasFocus() then nameBox:SetText(a.name or "") end
    end
    sink[#sink + 1] = nameBox
    left:Add(nameBox, 26, Selected)

    -------------------------------------------------------------------- right
    right:Header("When it fires", Always)

    right:Add(Choice(parent, "Fire", NBA.TRIGGERS,
        function() return A() and A().trigger or "gain" end,
        function(v) A().trigger = v end), ROW_H, Selected)

    right:Add(Choice(parent, "Then", NBA.MODES,
        function() return A() and A().mode or "flash" end,
        function(v) A().mode = v end), ROW_H,
        function() local a = A() return a and a.trigger == "gain" end)

    right:Hint("A missing-buff alert always holds - there is nothing for it to flash at.",
        function() local a = A() return a and a.trigger == "missing" end)

    right:Hint("A drop-off alert always flashes. The buff is gone, so there is nothing "
               .. "left to hold on screen.",
        function() local a = A() return a and a.trigger == "loss" end)

    right:Add(Check(parent, "Fire again when it changes",
        function() return A() and A().refire end,
        function(v) A().refire = v end,
        "For a buff that never actually drops off - one you spend stacks of without "
        .. "spending all of them. There is no gain to fire on, because it never left, "
        .. "so this fires on the game telling us the aura changed at all. Use the rearm "
        .. "delay below to stop one that ticks from strobing."),
        ROW_H, function() local a = A() return a and a.trigger == "gain" end)

    right:Hint("Collapsing Star through meta is the case: stacks go down and back up, "
               .. "the buff itself never disappears, and an alert waiting for it to come "
               .. "back waits forever.",
        function() local a = A() return a and a.trigger == "gain" and a.refire end)

    right:Add(Slider(parent, "Hold for", 0.2, 6, 0.1,
        function() return A() and A().hold or 1.2 end,
        function(v) A().hold = v end, "%.1fs"), 40,
        function()
            local a = A()
            return a and (a.trigger == "loss" or (a.trigger == "gain" and a.mode == "flash"))
        end)

    right:Add(Slider(parent, "Fade in", 0, 1, 0.05,
        function() return A() and A().fadeIn or 0.15 end,
        function(v) A().fadeIn = v end, "%.2fs"), 40, Selected)

    right:Add(Slider(parent, "Fade out", 0.05, 2, 0.05,
        function() return A() and A().fadeOut or 0.45 end,
        function(v) A().fadeOut = v end, "%.2fs"), 40, Selected)

    right:Add(Check(parent, "Pop as it appears",
        function() return A() and A().pop end,
        function(v) A().pop = v end,
        "Overshoots the size briefly so the alert catches your eye without moving."),
        ROW_H, Selected)

    right:Add(Slider(parent, "Do not fire again for", 0, 3, 0.1,
        function() return A() and A().rearm or 0.4 end,
        function(v) A().rearm = v end, "%.1fs"), 40, Selected)

    right:Hint("Some procs refresh themselves several times a second. This stops one "
               .. "from strobing.", Selected)

    return { left, right }
end

--------------------------------------------------------------------------------
-- Sound tab
--
-- Everything you can hear, in one place. The per-alert choices and the settings that
-- apply to all of them were split across two other tabs, which meant setting up one
-- alert's voice took a trip to a tab about where things sit on screen.
--
-- Laid out as one wide column rather than two, because the controls here are text
-- boxes: a path or a sentence in a 274 pixel box with a scroll bar down the side of it
-- is a box you cannot read what you typed into.
--------------------------------------------------------------------------------

local function BuildSoundPanel(parent)
    local wide = NewColumn(parent, 0, CONTENT_W - 16)

    wide:Header("A sound for this alert", Always)

    local soundBox = EditBox(parent, 22, function(text)
        local a = A()
        if not a then return end
        a.sound = text or ""
        if a.sound ~= "" then
            local played = NBA.PlayAlertSound(a.sound, a.soundChan)
            if played == false then
                NBA.Print("that sound file did not play - check the path.")
            end
        end
    end, "a LibSharedMedia name, or a path to your own file")
    soundBox.Refresh = function()
        local a = A()
        if a and not soundBox:HasFocus() then soundBox:SetText(a.sound or "") end
    end
    sink[#sink + 1] = soundBox
    wide:Add(soundBox, 26, Selected)

    wide:Add(MediaButton(parent, "Pick a sound",
        function()
            local a = A()
            return (a and a.sound ~= "" and a.sound) or nil
        end,
        function(btn)
            ToggleSoundPicker(btn, function(name)
                A().sound = name
                if name ~= "" then NBA.PlayAlertSound(name, A().soundChan) end
                NBA.RefreshOptions()
            end)
        end), ROW_H, Selected)

    wide:Hint("The game cannot list its own sound files, so the list is whatever "
              .. "LibSharedMedia knows about. Anything else is a path you type, and a path "
              .. "can only be checked by playing it - press Enter and you will hear it, or "
              .. "be told it did not play.", Selected)

    wide:Header("Speech for this alert", Always)

    wide:Add(Check(parent, "Say it out loud",
        function() return A() and A().speak end,
        function(v) A().speak = v end,
        "Reads the alert out through the game's own text to speech. A spoken word does "
        .. "not have to be learned the way a sound effect does, and it carries when the "
        .. "alert is somewhere you are not looking."), ROW_H, Selected)

    local speakBox = EditBox(parent, 22, function(text)
        local a = A()
        if not a then return end
        a.speakText = text or ""
        local said, why = NBA.Speak(NBA.SpokenText(a))
        if said == false then
            NBA.Print("nothing was said - " .. tostring(why)
                      .. ". Run |cff6fc2ff/nba tts|r for the whole picture.")
        end
    end, "leave empty to say whatever the alert itself says")
    speakBox.Refresh = function()
        local a = A()
        if a and not speakBox:HasFocus() then speakBox:SetText(a.speakText or "") end
    end
    sink[#sink + 1] = speakBox
    wide:Add(speakBox, 26, function() local a = A() return a and a.speak end)

    wide:Hint("Press Enter to hear it. Worth saying something short and unlike your other "
              .. "alerts - the point is knowing which one fired without looking.",
        function() local a = A() return a and a.speak end)

    -- The one thing that makes speech silently useless, said where it is switched on.
    -- Speech goes out through voice chat, so being deafened or having that volume at
    -- zero silences it while every reading the addon can take says it worked.
    local blockedNote = Label(parent, "", "GameFontDisableSmall", C.warn)
    blockedNote:SetWordWrap(true)
    blockedNote.Refresh = function()
        local why = NBA.SpeechBlocked()
        blockedNote:SetText(why
            and ("|cffe0b040Nothing will be heard: " .. why .. ".|r  Speech is sent through "
                 .. "voice chat, so its output volume in the game's Voice Chat settings is "
                 .. "what governs it - not the volume above, and not the game's own text to "
                 .. "speech settings.")
            or "")
    end
    sink[#sink + 1] = blockedNote
    wide:Add(blockedNote, 16, function()
        local a = A()
        return a and a.speak and NBA.SpeechBlocked() ~= nil
    end)

    wide:Header("The voice, for every alert", Always)

    wide:Add(MediaButton(parent, "Voice",
        function()
            local db = NBA.db
            return db and NBA.TtsVoiceName(db.ttsVoice) or "the first one"
        end,
        function(btn)
            ToggleVoicePicker(btn, function(voiceID)
                NBA.db.ttsVoice = voiceID
                NBA.Speak(NBA.TtsVoiceName(voiceID) or "This is the voice")
                NBA.RefreshOptions()
            end)
        end), ROW_H, Always)

    wide:Add(Slider(parent, "Speed", -10, 10, 1,
        function() return NBA.db and NBA.db.ttsRate or 0 end,
        function(v) NBA.db.ttsRate = v end, "%.0f"), 40, Always)

    wide:Add(Slider(parent, "Volume", 0, 100, 5,
        function() return NBA.db and NBA.db.ttsVolume or 100 end,
        function(v) NBA.db.ttsVolume = v end, "%.0f"), 40, Always)

    local sayBtn = Button(parent, "Say something", 150, 22, function()
        local said, why = NBA.Speak("Text to speech is working")
        if said == false then
            NBA.Print("nothing was said - " .. tostring(why)
                      .. ". Run |cff6fc2ff/nba tts|r for the whole picture.")
        end
    end)
    wide:Add(sayBtn, 26, Always)

    wide:Hint("One voice for every alert; the words are set per alert above. Speech is "
              .. "played through the voice chat output, so its volume in the game's Voice "
              .. "Chat settings governs it as well as the slider here. If nothing is "
              .. "heard, |cff6fc2ff/nba tts|r says why.", Always)

    return { wide }
end

local function BuildLookPanel(parent)
    local left  = NewColumn(parent, 0, COL_W)
    local right = NewColumn(parent, COL_W + COL_GAP, COL_W)

    local function ShowsText()
        local a = A()
        return a and (a.show == "text" or a.show == "both")
    end
    local function ShowsIcon()
        local a = A()
        return a and (a.show == "icon" or a.show == "both")
    end
    local function ShowsBoth()
        local a = A()
        return a and a.show == "both"
    end

    --------------------------------------------------------------------- left
    left:Header("What to draw", Always)

    left:Add(Choice(parent, "Show", NBA.SHOW_MODES,
        function() return A() and A().show or "both" end,
        function(v) A().show = v end), ROW_H, Selected)

    left:Add(Choice(parent, "Arrange", NBA.LAYOUTS,
        function() return A() and A().layout or "below" end,
        function(v) A().layout = v end), ROW_H, ShowsBoth)

    left:Add(Slider(parent, "Space between them", 0, 30, 1,
        function() return A() and A().gap or 4 end,
        function(v) A().gap = v end, "%.0f"), 40, ShowsBoth)

    left:Header("Text", ShowsText)

    local textBox = EditBox(parent, 22, function(text)
        local a = A()
        if not a then return end
        a.text = text or ""
        Apply()
    end, "leave empty to use the spell's name")
    textBox.Refresh = function()
        local a = A()
        if a and not textBox:HasFocus() then textBox:SetText(a.text or "") end
    end
    sink[#sink + 1] = textBox
    left:Add(textBox, 26, ShowsText)

    left:Add(MediaButton(parent, "Font",
        function() return A() and A().font end,
        function(btn)
            ToggleFontPicker(btn, function(name)
                A().font = name
                Apply()
                NBA.RefreshOptions()
            end)
        end), ROW_H, ShowsText)

    left:Add(Slider(parent, "Size", 8, 72, 1,
        function() return A() and A().fontSize or 26 end,
        function(v) A().fontSize = v end, "%.0f"), 40, ShowsText)

    left:Add(Choice(parent, "Outline", NBA.OUTLINES,
        function() return A() and A().fontOutline end,
        function(v) A().fontOutline = v end), ROW_H, ShowsText)

    left:Add(Swatch(parent, "Colour",
        function() return A() and A().color end, false), ROW_H, ShowsText)

    left:Add(Check(parent, "Drop shadow",
        function() return A() and A().shadow end,
        function(v) A().shadow = v end), ROW_H, ShowsText)

    left:Add(Check(parent, "UPPERCASE",
        function() return A() and A().uppercase end,
        function(v) A().uppercase = v end), ROW_H, ShowsText)

    -------------------------------------------------------------------- right
    right:Header("Icon", ShowsIcon)

    right:Add(Slider(parent, "Icon size", 16, 128, 1,
        function() return A() and A().iconSize or 48 end,
        function(v) A().iconSize = v end, "%.0f"), 40, ShowsIcon)

    right:Add(Check(parent, "Crop the icon border",
        function() return A() and A().zoom end,
        function(v) A().zoom = v end,
        "Trims the dull edge every game icon ships with."), ROW_H, ShowsIcon)

    right:Add(Check(parent, "Dark outline",
        function() return A() and A().border end,
        function(v) A().border = v end), ROW_H, ShowsIcon)

    -- The three things that come off the aura rather than out of the settings, kept
    -- together because they share one property worth understanding: every one is a
    -- value this addon is never allowed to read, handed straight to a widget that is.
    -- That is why they keep working inside an encounter.
    right:Header("Extras", Always)

    right:Add(Check(parent, "Countdown swipe",
        function() return A() and A().swipe end,
        function(v) A().swipe = v end,
        "The dark sweep around the icon as the buff runs out. Needs the icon, and only "
        .. "means anything on an alert that holds - a flash is gone before it would."),
        ROW_H, ShowsIcon)

    right:Add(Check(parent, "Stack count",
        function() return A() and A().showStacks end,
        function(v) A().showStacks = v end,
        "Shown from two stacks upward. The number arrives from the game already "
        .. "formatted, which is how it can be shown during a fight."), ROW_H, Selected)

    right:Hint("Both are only as good as what the game will show. On a buff it will not "
               .. "talk about, the alert still fires - it just appears without the sweep "
               .. "or the count.", Selected)

    right:Header("The whole alert", Always)

    right:Add(Slider(parent, "Opacity", 0.1, 1, 0.05,
        function() return A() and A().alpha or 1 end,
        function(v) A().alpha = v end, "%.2f"), 40, Selected)

    right:Add(Slider(parent, "Scale", 0.3, 3, 0.05,
        function() return A() and A().scale or 1 end,
        function(v) A().scale = v end, "%.2f"), 40, Selected)

    return { left, right }
end

local function BuildPlacePanel(parent)
    local left  = NewColumn(parent, 0, COL_W)
    local right = NewColumn(parent, COL_W + COL_GAP, COL_W)

    --------------------------------------------------------------------- left
    left:Header("Where it sits", Always)

    left:Add(Choice(parent, "Anchor to", NBA.ANCHORS,
        function() return A() and A().anchor or "CENTER" end,
        function(v) A().anchor = v end), ROW_H, Selected)

    left:Hint("The corner of the screen the offsets below are measured from. Anchoring "
              .. "to a corner keeps an alert put when the window size changes.", Selected)

    left:Add(Slider(parent, "Across", -1200, 1200, 1,
        function() return A() and A().x or 0 end,
        function(v) A().x = v end, "%.0f"), 40, Selected)

    left:Add(Slider(parent, "Up and down", -900, 900, 1,
        function() return A() and A().y or 0 end,
        function(v) A().y = v end, "%.0f"), 40, Selected)

    left:Add(Choice(parent, "Layer", NBA.STRATAS,
        function() return A() and A().strata or "HIGH" end,
        function(v) A().strata = v end), ROW_H, Selected)

    left:Hint("Raise the layer if something else is drawing on top of this alert.", Selected)

    -------------------------------------------------------------------- right
    right:Header("Copy this alert's look", Always)

    right:Hint("Takes everything except the spell, the name, the unit and the position, "
               .. "and puts it on every other alert. There is no shared style to inherit "
               .. "from on purpose - this button is the shortcut instead.", Selected)

    local copyBtn = Button(parent, "Apply this look to every alert", 200, 24, function()
        local from = A()
        if not from then return end
        local n = 0
        for id, a in pairs(NBA.db.alerts) do
            if id ~= selectedID then
                NBA.CopyAlertLook(from, a)
                n = n + 1
            end
        end
        Apply()
        NBA.RefreshOptions()
        NBA.Print(("copied that look onto %d other alert%s."):format(n, n == 1 and "" or "s"))
    end)
    right:Add(copyBtn, 28, Selected)

    right:Header("Blizzard's Cooldown Manager", Always)

    right:Add(Check(parent, "Fade it out but keep it running",
        function() return NBA.db and NBA.db.fadeCooldownManager end,
        function(v)
            NBA.db.fadeCooldownManager = v
            NBA.ApplyCooldownManagerFade()
        end,
        "Sets its opacity to zero. It keeps updating, which is what lets this addon "
        .. "read procs during a fight, but nothing is drawn."), ROW_H, Always)

    local cdmNote = Label(parent, "", "GameFontDisableSmall", C.faint)
    cdmNote:SetWordWrap(true)
    cdmNote.Refresh = function()
        if NBA.Watch.BridgeIsLive() then
            cdmNote:SetText("A display is on. Note that this only helps for the spells the "
                .. "Cooldown Manager is actually set to track - it cannot read one it is not "
                .. "showing, however well the game knows it.")
            cdmNote:SetTextColor(unpack(C.good))
        else
            cdmNote:SetText("Every Cooldown Manager display is off. Spells the game will not "
                .. "answer about directly cannot be seen during a fight without one - turn on "
                .. "its tracked buffs in Blizzard's own options and add the spells you want.")
            cdmNote:SetTextColor(unpack(C.warn))
        end
    end
    sink[#sink + 1] = cdmNote
    right:Add(cdmNote, 54, Always)

    right:Header("Tooltips", Always)

    right:Add(Check(parent, "Show spell ids on tooltips",
        function() return NBA.db and NBA.db.tooltipIDs end,
        function(v) NBA.db.tooltipIDs = v end,
        "Puts the id on spell, aura and item tooltips. Hovering a buff on your own "
        .. "frame is the quickest way to the number an alert needs - and the right "
        .. "number, which the one printed on a website often is not."), ROW_H, Always)

    right:Hint("Takes effect at once for tooltips shown from now on. An aura's id is "
               .. "withheld during a fight, and the line says so rather than vanishing.",
               Always)

    right:Header("This window", Always)

    right:Add(Check(parent, "Close when a fight starts",
        function() return NBA.db and NBA.db.closeInCombat end,
        function(v) NBA.db.closeInCombat = v end), ROW_H, Always)

    return { left, right }
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function SelectTab(key)
    -- Changing tab while the picker is up means the picker is not what you wanted.
    -- Leaving it open would put a panel behind it and then fight over the clicks.
    if picker and picker:IsShown() then picker:Hide() end
    currentKey = key
    for _, tab in ipairs(tabStrip or {}) do
        tab.mark:SetShown(tab.key == key)
        tab.text:SetTextColor(unpack(tab.key == key and C.gold or C.text))
    end
    for k, p in pairs(panels) do
        p.frame:SetShown(k == key)
    end
    NBA.RefreshOptions()
end

local function BuildTabs(parent)
    tabStrip = {}
    local x = 0
    for _, def in ipairs(TABS) do
        local tab = Button(parent, def.label, 84, 24, function() SelectTab(def.key) end)
        tab:SetPoint("TOPLEFT", x, 0)
        tab.key = def.key
        tab.mark = tab:CreateTexture(nil, "OVERLAY")
        tab.mark:SetPoint("BOTTOMLEFT", 0, 0)
        tab.mark:SetPoint("BOTTOMRIGHT", 0, 0)
        tab.mark:SetHeight(2)
        tab.mark:SetColorTexture(unpack(C.accent))
        tabStrip[#tabStrip + 1] = tab
        x = x + 86
    end
end

local function BuildWindow()
    local f = CreateFrame("Frame", "nugsBuffAlertOptions", UIParent)
    f:SetSize(WIDTH, HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    -- Draggable from the body as well as the header, matching the rest of the suite.
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    Backdrop(f, C.bg, 1)
    table.insert(UISpecialFrames, "nugsBuffAlertOptions")

    -- The blue tail is the version in every other addon in the suite, not a tagline.
    HeaderBar(f, "nugsBuffAlert", "v" .. NBA.version)

    ----------------------------------------------------------------- left side
    local listPanel = Panel(f, C.panel)
    listPanel:SetPoint("TOPLEFT", 12, -42)
    listPanel:SetPoint("BOTTOMLEFT", 12, 46)
    listPanel:SetWidth(LEFT_W)

    local listTitle = Label(listPanel, "Alerts", "GameFontNormal", C.accent)
    listTitle:SetPoint("TOPLEFT", 10, -8)

    alertList = ScrollArea(listPanel)
    alertList:SetPoint("TOPLEFT", 2, -30)
    alertList:SetPoint("BOTTOMRIGHT", -2, 32)
    alertList.content:SetWidth(LEFT_W - 6)

    emptyLabel = Label(listPanel, "No alerts yet.\nPress New below.",
                       "GameFontDisableSmall", C.faint)
    emptyLabel:SetPoint("TOPLEFT", 12, -40)
    emptyLabel:SetWordWrap(true)

    local newBtn = Button(listPanel, "New", 56, 22, function()
        local id = NBA.CreateAlert()
        -- A new alert lands in the "Any spec" group; opening it if it was folded up
        -- stops the button looking like it did nothing.
        NBA.db.collapsed[0] = nil
        SelectAlert(id)
    end)
    newBtn:SetPoint("BOTTOMLEFT", 6, 6)

    local delBtn = Button(listPanel, "Delete", 60, 22, function()
        if not selectedID then return end
        local gone = selectedID
        NBA.Display:Forget(gone)
        NBA.DeleteAlert(gone)
        selectedID = NBA.db.order[1]
        RebuildAlertList()
        NBA.RefreshOptions()
    end)
    delBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)

    local upBtn = Button(listPanel, "^", 24, 22, function()
        if selectedID then NBA.MoveAlert(selectedID, -1) RebuildAlertList() end
    end)
    upBtn:SetPoint("LEFT", delBtn, "RIGHT", 4, 0)

    local downBtn = Button(listPanel, "v", 24, 22, function()
        if selectedID then NBA.MoveAlert(selectedID, 1) RebuildAlertList() end
    end)
    downBtn:SetPoint("LEFT", upBtn, "RIGHT", 4, 0)

    ---------------------------------------------------------------- right side
    local tabHolder = CreateFrame("Frame", nil, f)
    tabHolder:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", 12, 0)
    tabHolder:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    tabHolder:SetHeight(24)
    BuildTabs(tabHolder)

    local content = Panel(f, C.panel)
    content:SetPoint("TOPLEFT", tabHolder, "BOTTOMLEFT", 0, -6)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 46)

    local builders = {
        alert = BuildAlertPanel,
        look  = BuildLookPanel,
        sound = BuildSoundPanel,
        place = BuildPlacePanel,
    }

    for _, def in ipairs(TABS) do
        local scroll = ScrollArea(content)
        scroll:SetPoint("TOPLEFT", 12, -10)
        scroll:SetPoint("BOTTOMRIGHT", -8, 10)
        scroll.content:SetWidth(CONTENT_W)

        local widgets = {}
        sink = widgets
        local columns = builders[def.key](scroll.content)
        sink = nil

        panels[def.key] = { frame = scroll, columns = columns, widgets = widgets }
        scroll:Hide()
    end

    -- The picker overlays the settings area rather than the whole window, so the
    -- alert list stays visible and you can see which alert you are picking for.
    picker = BuildPicker(content)

    --------------------------------------------------------------- bottom bar
    local unlockBtn = Button(f, "", 150, 24, function()
        NBA.Display:ToggleLock(NBA.Display:IsUnlocked())
    end)
    unlockBtn:SetPoint("BOTTOMLEFT", 12, 12)
    f.unlockBtn = unlockBtn

    local testBtn = Button(f, "Test all", 90, 24, function()
        NBA.Display:TestAll()
    end)
    testBtn:SetPoint("LEFT", unlockBtn, "RIGHT", 6, 0)

    local testOne = Button(f, "Test this one", 110, 24, function()
        if selectedID then NBA.Display:Test(selectedID) end
    end)
    testOne:SetPoint("LEFT", testBtn, "RIGHT", 6, 0)

    -- Down here rather than only on the Place tab. It is the one setting that helps
    -- somebody who has not worked out yet that spells have ids, and a setting like that
    -- is no use two clicks inside a tab they have no reason to open.
    local idCheck
    idCheck = CreateFrame("Button", nil, f)
    idCheck:SetSize(180, ROW_H)
    idCheck:SetPoint("BOTTOMRIGHT", -12, 12)

    local idBox = CreateFrame("Frame", nil, idCheck)
    idBox:SetSize(14, 14)
    idBox:SetPoint("RIGHT", 0, 0)
    Backdrop(idBox, C.input, 1)

    local idFill = idBox:CreateTexture(nil, "ARTWORK")
    idFill:SetPoint("TOPLEFT", 3, -3)
    idFill:SetPoint("BOTTOMRIGHT", -3, 3)
    idFill:SetColorTexture(unpack(C.accent))

    local idText = Label(idCheck, "Spell ids on tooltips", "GameFontDisableSmall", C.faint)
    idText:SetPoint("RIGHT", idBox, "LEFT", -6, 0)
    idText:SetJustifyH("RIGHT")

    idCheck:SetScript("OnClick", function()
        NBA.db.tooltipIDs = not NBA.db.tooltipIDs
        NBA.RefreshOptions()
    end)
    idCheck:SetScript("OnEnter", function(self)
        idText:SetTextColor(1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("Spell ids on tooltips")
        GameTooltip:AddLine("Hovering a buff shows the id an alert needs - and the buff's "
            .. "own id, which is often not the one a website prints for the ability.",
            0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    idCheck:SetScript("OnLeave", function()
        idText:SetTextColor(unpack(C.faint))
        GameTooltip:Hide()
    end)
    idCheck.Refresh = function() idFill:SetShown(NBA.db.tooltipIDs and true or false) end
    f.idCheck = idCheck

    -- A frame created with CreateFrame is shown from birth, so without this the first
    -- /nba builds a visible window and then toggles it straight back off, and the
    -- command has to be typed twice.
    f:Hide()

    window = f
    return f
end

--------------------------------------------------------------------------------

RelayoutAll = function()
    for _, p in pairs(panels) do
        local tallest = 0
        -- Twice, and not out of superstition. A wrapped FontString cannot report its
        -- height until it has been given the width it wraps to, and the width is set
        -- by the pass that is asking. The first pass therefore measures some labels
        -- at one line; the second measures them all correctly, because every width is
        -- already applied by then. It is a few dozen SetPoints, once per refresh.
        for _ = 1, 2 do
            tallest = 0
            for _, col in ipairs(p.columns) do
                tallest = math.max(tallest, col:Layout())
            end
        end
        p.frame.content:SetHeight(math.max(1, tallest + 12))
        p.frame.content:SetWidth(CONTENT_W)
        p.frame:UpdateBar()
    end
end

function NBA.RefreshOptions()
    if not window or not window:IsShown() then return end

    -- A selection that survived a delete points at nothing. Falling back to the first
    -- alert is better than every getter having to guard.
    if not NBA.db.alerts[selectedID or -1] then
        selectedID = NBA.db.order[1]
    end

    local has = selectedID ~= nil
    emptyLabel:SetShown(not has)

    -- The picker owns the content area while it is up. Without this the refresh that
    -- follows choosing a spell would put the panel back underneath it.
    local hidden = picker and picker:IsShown()
    for _, p in pairs(panels) do
        -- A hidden control cannot be clicked into a nil, which is the whole guard for
        -- the zero-alerts case.
        p.frame:SetShown(has and not hidden and p == panels[currentKey])
    end

    if has then
        for _, w in ipairs(panels[currentKey].widgets) do
            if w.Refresh then w.Refresh() end
        end
        RelayoutAll()
    end

    window.unlockBtn:SetLabel(NBA.Display:IsUnlocked() and "Lock the alerts"
                                                       or "Unlock to move them")
    -- Lives on the window rather than in a panel's widget list, so it refreshes here.
    if window.idCheck then window.idCheck.Refresh() end
    RebuildAlertList()
end

--------------------------------------------------------------------------------
-- Move bar
--
-- Placing alerts means dragging boxes that this window is usually sitting on top of,
-- so it gets out of the way on its own: unlocking hides it and puts up a small bar
-- instead, and locking brings it back exactly where it was.
--
-- Deliberately not a saved position. It moves if it is in the way and starts near the
-- top of the screen next time; persisting it would mean a saved variable nobody would
-- ever go looking for.
--------------------------------------------------------------------------------

local moveBar
local windowWasOpen = false

local function BuildMoveBar()
    local f = CreateFrame("Frame", "nugsBuffAlertMoveBar", UIParent)
    f:SetSize(320, 34)
    f:SetPoint("TOP", 0, -120)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:SetClampedToScreen(true)
    Backdrop(f, C.bg, 1)

    local accent = f:CreateTexture(nil, "OVERLAY")
    accent:SetPoint("TOPLEFT", 0, 0)
    accent:SetPoint("TOPRIGHT", 0, 0)
    accent:SetHeight(2)
    accent:SetColorTexture(unpack(C.accent))

    local label = Label(f, "Drag the alerts where you want them",
                        "GameFontHighlightSmall", C.text)
    label:SetPoint("LEFT", 12, 0)

    local lockBtn = Button(f, "Lock", 70, 22, function()
        NBA.Display:ToggleLock(true)
    end)
    lockBtn:SetPoint("RIGHT", -10, 0)

    -- Escape locks rather than merely dismissing the bar: hiding it while things were
    -- still unlocked would leave nothing on screen to end that state with.
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" and not InCombatLockdown() then
            SafePropagate(self, false)
            NBA.Display:ToggleLock(true)
        else
            SafePropagate(self, true)
        end
    end)
    f:EnableKeyboard(true)
    SafePropagate(f, true)

    moveBar = f
    return f
end

-- Called by Display whenever the lock changes, from any source: this window, the
-- minimap button's right click, or the slash command.
--
-- The guard is load-bearing, not defensive. Unlocking hides the settings window, and
-- the window's own OnHide hook calls straight back in here - so without it the second
-- pass re-read `window:IsShown()` from inside the Hide that was still running, found
-- false, and overwrote the `true` the first pass had just recorded. Locking then had
-- nothing telling it the window had been open, and never brought it back.
--
-- The hook still matters on its own: closing the window by hand while the alerts are
-- unlocked has to put the move bar up, or there is nothing left on screen to lock
-- with. That path is a fresh call and passes the guard.
local inLockChange = false

function NBA.OnLockChanged(locked)
    if inLockChange then return end
    inLockChange = true

    if not locked then
        windowWasOpen = window and window:IsShown()
        if window then window:Hide() end
        if not moveBar then BuildMoveBar() end
        moveBar:Show()
    else
        if moveBar then moveBar:Hide() end
        -- Only reopened if it was open to begin with. Unlocking from the slash command
        -- should not conjure a settings window on locking.
        if windowWasOpen and window then
            window:Show()
            NBA.RefreshOptions()
        end
        windowWasOpen = false
    end

    inLockChange = false
end

--------------------------------------------------------------------------------

-- Builds the window once and hooks it once. Hooked here rather than inside
-- BuildWindow because moveBar is declared in this block: a closure written above its
-- declaration would bind to a nil global instead, silently, until somebody clicked it.
--
-- The two hooks keep the pair consistent whichever one the player acts on. Opening
-- the settings while unlocked should not leave two lock buttons on screen, and closing
-- the settings while unlocked should put the bar back rather than leaving that state
-- with no way out of it.
local function EnsureWindow()
    if window then return end
    BuildWindow()
    selectedID = NBA.db.order[1]
    SelectTab(currentKey)
    window:HookScript("OnShow", function()
        if moveBar then moveBar:Hide() end
    end)
    window:HookScript("OnHide", function()
        if picker then picker:Hide() end
        if not NBA.db.locked then NBA.OnLockChanged(false) end
    end)
end

function NBA.ToggleOptions()
    EnsureWindow()
    if window:IsShown() then
        window:Hide()
    else
        window:Show()
        NBA.RefreshOptions()
    end
end

--------------------------------------------------------------------------------
-- A stub in the Blizzard settings list so the addon is findable there; the real
-- controls live in our own window, which stays movable.
--------------------------------------------------------------------------------

function NBA.InitOptions()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end

    local panel = CreateFrame("Frame")
    panel.name = "nugsBuffAlert"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("nugsBuffAlert")

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    note:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    note:SetJustifyH("LEFT")
    note:SetText("Text and icon alerts when a buff or proc comes up." ..
        "\n\nAll settings live in the nugsBuffAlert window - open it with the button "
        .. "below or with |cffffd479/nba|r.")

    local open = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    open:SetSize(220, 24)
    open:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -16)
    open:SetText("Open nugsBuffAlert options")
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        EnsureWindow()
        window:Show()
        NBA.RefreshOptions()
    end)

    local category = Settings.RegisterCanvasLayoutCategory(panel, "nugsBuffAlert")
    category.ID = "nugsBuffAlert"
    Settings.RegisterAddOnCategory(category)
end

local combat = CreateFrame("Frame")
combat:RegisterEvent("PLAYER_REGEN_DISABLED")
combat:SetScript("OnEvent", function()
    -- Not because anything here would be blocked - none of these frames are secure -
    -- but because the window puts test alerts on the screen, and a fake alert during a
    -- real pull cannot be told apart from the real thing.
    if NBA.db and NBA.db.closeInCombat and window and window:IsShown() then
        window:Hide()
    end
end)
