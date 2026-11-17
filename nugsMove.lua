--------------------------------------------------------------------------------
-- nugsMove
-- Copyright (c) 2026 nugs. All Rights Reserved.
--
-- Dragging a frame, done once for every nugs addon.
--
-- CANONICAL COPY: D:\Claude\shared\nugsMove.lua
-- Do not edit the copy inside an addon. Edit this file and run:
--     node sync-shared.js
--
--------------------------------------------------------------------------------
-- WHY THIS EXISTS
--
-- "The window sticks to the cursor" / "the window jumps when I grab the title bar"
-- was fixed four separate times in this family and came back every time.
--
-- Every one of those fixes had the same shape. It named a PATH by which a move could
-- be left running - the frame hidden mid-drag, a guard thrown away by a later
-- SetScript, a list row restructured under the cursor, a click swallowed by a
-- dropdown's full-screen catcher - and closed that path. There was always another
-- path, and the fix for each one lived in its own handler, in its own file, leaving
-- every other frame in the addon exactly as broken as before.
--
-- So this names no path. It asserts the thing that is true whatever the path was:
--
--      A FRAME NOBODY IS HOLDING MUST NOT BE MOVING.
--
-- Checked every frame that a move is running. A move that survives anything at all -
-- known or unknown, understood or not - is over on the next frame, and nobody has to
-- work out how it survived.
--
-- Around that invariant, three guards for the one gap it has (OnUpdate is not
-- delivered to a HIDDEN frame, so a move that outlives the frame being hidden is
-- invisible to it):
--
--   * BEGINNING a move stops any previous one first. StartMoving on a frame that is
--     already moving re-bases the running move onto the cursor - which is exactly
--     what "it jumps when I grab the title bar" looks like from the outside.
--   * OnHide stops one, for a move that outlives the frame being hidden.
--   * The caller's own "assert" path can call EndMove on show.
--
-- AND IT MEASURES. Being wrong about the cause four times is enough: if a frame ever
-- moves by an amount the cursor did not ask for, it says so, with numbers, rather
-- than leaving somebody to describe a jump in words. Silent otherwise.
--
--------------------------------------------------------------------------------
-- USING IT
--
--   ns.InstallMove(frame, {
--       label   = "the cast bar",   -- how the frame is named if it reports
--       handle  = header,           -- optional: a child that drags the frame
--       body    = true,             -- optional: the frame itself drags too
--       mouse   = false,            -- optional: the caller owns EnableMouse
--       canMove = function(f) return not DB.locked end,   -- optional
--       onBegin = function(f) end,  -- optional, runs BEFORE StartMoving
--       onEnd   = function(f) end,  -- optional, runs after a move that was running
--   })
--
-- With a `handle` and no `body`, only the handle drags - which is what a title bar
-- is. Without a handle the frame drags itself. That default is deliberate: it keeps
-- every window doing exactly what it did before this file existed, so converting an
-- addon changes its guards and nothing else.
--
-- `onEnd` runs when a move that WAS running ends, including when the invariant is
-- what ended it. That matters: position-saving lives in onEnd, and a drag that ended
-- because the mouse-up went missing still has to save where the frame ended up.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

-- Resolved when it is needed, not when this file loads: the addon's own Print is
-- usually defined in Core.lua, which loads after this.
local function Report(msg)
    if ns and type(ns.Print) == "function" then
        ns.Print(msg)
    else
        print("|cff8cd2ffnugs|r " .. tostring(msg))
    end
end

function ns.InstallMove(frame, opts)
    if not frame then return end
    opts = opts or {}
    local label = opts.label or "the window"

    frame:SetMovable(true)

    -- `mouse = false` for a frame that manages its own mouse - the display anchors in
    -- these addons take the mouse only while unlocked, so that clicks pass through to
    -- the world the rest of the time. Enabling it here unconditionally would make an
    -- aura swallow every click underneath it, which is a far worse bug than the one
    -- this file exists to fix.
    if opts.mouse ~= false then frame:EnableMouse(true) end

    -- The frame's bottom-left in SCREEN pixels, which is the only space a frame
    -- position and a cursor position can be compared in. These frames carry their own
    -- scale, so subtracting the two raw numbers would be measuring nothing at all.
    local function ScreenPos()
        local l, b = frame:GetLeft(), frame:GetBottom()
        if not (l and b) then return nil end
        local s = frame:GetEffectiveScale()
        return l * s, b * s
    end

    -- What the mouse was actually over when the move began.
    --
    -- This is the one question a source-reading check cannot answer. The commonest way
    -- a title bar stops working is another frame anchored over it, and whatever is
    -- covering it may not have existed when the window was built.
    local function MouseFocusNames()
        if not GetMouseFoci then return "unknown" end
        local ok, foci = pcall(GetMouseFoci)
        if not ok or type(foci) ~= "table" then return "unknown" end
        local names = {}
        for _, region in ipairs(foci) do
            -- Every read guarded. Some of what a cursor can be over is forbidden to
            -- addons, and a diagnostic that throws is worse than no diagnostic - that
            -- exact mistake made nugsAuras' drag check error five times per open.
            local name = "?"
            pcall(function() name = region:GetName() or region:GetObjectType() or "?" end)
            names[#names + 1] = name
        end
        return #names > 0 and table.concat(names, ", ") or "nothing"
    end

    local move = nil     -- non-nil only while a move is running

    frame.nugsBeginMove = function()
        if opts.canMove and not opts.canMove(frame) then return end

        -- FIRST, before anything else, for the re-basing reason at the top.
        local stale = false
        if frame.IsDragging then
            local ok, dragging = pcall(frame.IsDragging, frame)
            stale = (ok and dragging) and true or false
        end
        pcall(frame.StopMovingOrSizing, frame)

        -- Before the snapshot: a caller that re-anchors things on the way into a drag
        -- has to have done so before the position being measured is read.
        if opts.onBegin then opts.onBegin(frame) end

        local fl, fb = ScreenPos()
        local cx, cy = GetCursorPosition()
        move = fl and {
            fl = fl, fb = fb, cx = cx, cy = cy,
            stale = stale, focus = MouseFocusNames(), measured = false,
        } or nil

        frame:StartMoving()
    end

    frame.nugsEndMove = function()
        local wasMoving = move ~= nil
        move = nil
        pcall(frame.StopMovingOrSizing, frame)
        if wasMoving and opts.onEnd then opts.onEnd(frame) end
    end

    local function Begin() frame.nugsBeginMove() end
    local function End()   frame.nugsEndMove()   end

    -- A handle without `body` is a title bar: the bar drags, the window under it does
    -- not. Keeping that split is what makes converting an addon a no-op everywhere
    -- except the guards.
    if opts.handle then
        opts.handle:EnableMouse(true)
        opts.handle:RegisterForDrag("LeftButton")
        opts.handle:SetScript("OnDragStart", Begin)
        opts.handle:SetScript("OnDragStop",  End)
    end

    if opts.body or not opts.handle then
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", Begin)
        frame:SetScript("OnDragStop",  End)
    end

    -- A move that outlived the frame being hidden. The invariant below cannot see this
    -- one: a hidden frame is not given OnUpdate either.
    --
    -- HookScript is safe here ONLY while nothing later calls SetScript("OnHide") on
    -- this frame, which would discard it without a word - as it did for two releases
    -- running. That is not left to anybody's memory: dragcheck.js has a HOOKKILL rule
    -- that fails on exactly that.
    frame:HookScript("OnHide", function(self)
        self.nugsEndMove()
        pcall(self.StopMovingOrSizing, self)
    end)

    -- Runs only while the frame is SHOWN, and does nothing on any frame where no move
    -- is in progress - the first line after the chain returns. That is why it is not
    -- throttled: a throttle would cost more than the check it replaced.
    --
    -- CHAINED, not replaced. Several of these frames drive themselves from an OnUpdate
    -- of their own - a cast bar polling, a pulse animating - and SetScript would throw
    -- that away, silently, leaving a bar that never updates. Whatever was there when
    -- this ran still runs, first.
    --
    -- Which means INSTALL THIS AFTER the frame's own OnUpdate, not before: a handler
    -- set afterwards replaces this one, and the invariant would go quiet without
    -- anything saying so.
    local prevUpdate = frame.GetScript and frame:GetScript("OnUpdate") or nil
    frame:SetScript("OnUpdate", function(self, elapsed)
        if prevUpdate then prevUpdate(self, elapsed) end
        if not move then return end

        -- THE INVARIANT.
        if not IsMouseButtonDown("LeftButton") then
            self.nugsEndMove()
            return
        end

        if move.measured then return end

        -- Nothing to compare until the cursor has actually moved: before that both
        -- deltas are zero and every drag on earth reads as perfect.
        local cx, cy = GetCursorPosition()
        local dcx, dcy = cx - move.cx, cy - move.cy
        if dcx == 0 and dcy == 0 then return end
        move.measured = true

        local fl, fb = ScreenPos()
        if not fl then return end

        -- What the frame did, minus what the cursor asked for. Zero on a healthy drag
        -- whatever the scales involved, because both sides are screen pixels.
        local jx, jy = (fl - move.fl) - dcx, (fb - move.fb) - dcy
        if math.abs(jx) <= 2 and math.abs(jy) <= 2 then return end

        local point, rel, relPoint, ax, ay = frame:GetPoint(1)
        local relName = "?"
        pcall(function() relName = (rel and rel.GetName and rel:GetName()) or "unnamed" end)

        -- Floored before formatting. These are pixel measurements, not integers, and
        -- %d on a fractional number is a hard error on some Lua builds - a diagnostic
        -- that throws while reporting a bug is the worst outcome available here.
        Report(("|cffff5555%s jumped %d, %d px when the move started.|r"):format(
            label, math.floor(jx + 0.5), math.floor(jy + 0.5)))
        Report(("   was anchored %s to %s %s at %d, %d"):format(
            tostring(point), relName, tostring(relPoint),
            math.floor((ax or 0) + 0.5), math.floor((ay or 0) + 0.5)))
        Report("   a move was already running: " .. tostring(move.stale))
        Report("   under the cursor: " .. move.focus)
        Report(("   movable %s, scale %.2f, ui scale %.2f"):format(
            tostring(frame:IsMovable()), frame:GetScale(), UIParent:GetEffectiveScale()))
        Report("   |cffffd479please send these lines to nugs.|r")
    end)

    return frame
end
