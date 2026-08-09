--------------------------------------------------------------------------------
-- nugsBuffAlert
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsBuffAlert  -  Watch.lua
-- The only file that reads aura data. Everything else is drawing.
--
-- One question, asked over and over: is spell N on unit U right now. Under 12.x
-- that question has three possible answers, not two, and the third one is what
-- this file exists to keep honest.
--
--   yes      the aura is there
--   no       the aura is not there, and we are in a position to know that
--   unknown  the client is withholding, and "no" would be a guess
--
-- Collapsing unknown into no is the bug that makes an alert addon useless in the
-- only place it matters. An alert that fires when a buff drops would fire on every
-- pull; an alert that fires when a buff is missing would sit on the screen for the
-- whole fight. So unknown is carried all the way through and every trigger stands
-- down on it.
--
-- Three ways to get an answer, tried in order of how much they can be trusted:
--
--   1. GetUnitAuraBySpellID    exact, and the only one that survives 12.1
--   2. the Cooldown Manager    a bridge, covers procs the first path cannot see
--   3. a full enumeration      complete, but only outside combat
--
-- Which one answered is recorded, because the options window shows it per spell
-- and "why is this not firing in raids" is otherwise unanswerable.
--------------------------------------------------------------------------------

local ADDON_NAME, NBA = ...

local Plain     = NBA.Plain
local PlainBool = NBA.PlainBool

local UA = C_UnitAuras or {}

local HAS = {
    bySpellID  = UA.GetUnitAuraBySpellID          ~= nil,
    unitAuras  = UA.GetUnitAuras                  ~= nil,
    duration   = UA.GetAuraDuration               ~= nil,
    stacks     = UA.GetAuraApplicationDisplayCount ~= nil,
}
NBA.HAS = HAS

local Watch = {}
NBA.Watch = Watch

-- Per-alert running state, keyed by alert id. Never persisted: every field here is
-- about this second, and a stale "it was up when you logged out" would fire an
-- alert at the loading screen.
local state = {}
Watch.state = state

local function StateFor(id)
    local s = state[id]
    if not s then
        s = { present = nil, lastFire = 0, instanceID = nil, path = nil }
        state[id] = s
    end
    return s
end

--------------------------------------------------------------------------------
-- Readability
--
-- Whether the client will answer about a given spell at all. This is the single
-- most useful thing this addon can tell a player, because a spell that cannot be
-- read fails silently and looks exactly like a spell that never procs.
--------------------------------------------------------------------------------

-- True/false right now, or nil if the client has no opinion to give. Plain, and
-- safe to branch on.
function NBA.SpellIsReadable(spellID)
    if not spellID then return nil end
    if not (C_Secrets and C_Secrets.ShouldSpellAuraBeSecret) then
        -- No secret system at all (Classic, or a build before 12.0): everything reads.
        return true
    end
    local ok, secret = pcall(C_Secrets.ShouldSpellAuraBeSecret, spellID)
    if not ok then return nil end
    return not secret
end

-- Static, context-free secrecy, so the options window can say "this one never
-- works" rather than "this one is not working at the moment".
function NBA.SpellSecrecy(spellID)
    if not spellID then return nil end
    if not (C_Secrets and C_Secrets.GetSpellAuraSecrecy and Enum and Enum.SecrecyLevel) then
        return nil
    end
    local ok, level = pcall(C_Secrets.GetSpellAuraSecrecy, spellID)
    if not ok then return nil end
    if level == Enum.SecrecyLevel.NeverSecret  then return "always" end
    if level == Enum.SecrecyLevel.AlwaysSecret then return "never"  end
    return "sometimes"
end

--------------------------------------------------------------------------------
-- The Cooldown Manager bridge
--
-- The path that makes this addon work for procs specifically, and the reason it is
-- worth writing at all.
--
-- Blizzard's own Cooldown Manager is not an addon. Its code is untainted, so it may
-- read the aura data we may not - and its tracked-buff viewers are, almost by
-- definition, a list of your spec's procs. What it leaves lying on its item frames
-- is the useful part:
--
--   frame.cooldownID      plain, it is configuration rather than combat state
--   frame.auraInstanceID  plain, auraInstanceID is NeverSecret
--   frame.auraDataUnit    plain, "player" or "target"
--
-- Resolving cooldownID through GetCooldownViewerCooldownInfo gives a plain spellID.
-- Reading those three fields recovers exactly the spellID-to-aura mapping the
-- secret system withholds, without calling a single restricted API ourselves.
--
-- Two hard limits, both stated in the options window rather than buried here:
--   * it only covers spells the Cooldown Manager tracks for your current spec;
--   * CooldownViewerMixin:OnHide unregisters UNIT_AURA, so a hidden Cooldown
--     Manager stops updating and the bridge goes stale. It has to be switched on
--     and shown - which is what the "fade it out instead" setting is for, since an
--     alpha of zero is still shown as far as the game is concerned.
--------------------------------------------------------------------------------

local BUFF_VIEWERS = {
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

local ALL_VIEWERS = {
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
}

-- A cooldown is not one spell id, and assuming it was is what makes this bridge look
-- broken. The Cooldown Manager is a list of *abilities*: what it hands back from
-- GetCooldownViewerCooldownInfo is the id you cast. The buff that ability applies
-- carries a different id, and the buff is the thing an alert is watching.
--
-- So every id a cooldown entry knows about is collected, not just `spellID`:
--
--   spellID          the ability as the game lists it
--   overrideSpellID  a talent can replace the ability outright, and the aura then
--                    carries the override's id rather than the base one
--   linkedSpellIDs   everything else the entry is associated with, which is usually
--                    where the aura actually lives
--
-- And then, on top of all of that, by **name**. An ability and the buff it applies
-- share a name far more reliably than they share a number - names are readable
-- whenever ids are, so this costs nothing and catches the cases the id lists miss.
local function NewIndex()
    return { byID = {}, byName = {}, nameOwner = {}, ambiguous = {},
             idOwner = {}, ambiguousID = {} }
end

-- Every id one cooldown entry knows itself by, in the order they are worth trying.
local function AllIDs(info)
    local out = {}
    if info.spellID         then out[#out + 1] = info.spellID         end
    if info.overrideSpellID then out[#out + 1] = info.overrideSpellID end
    if NBA.Walkable(info.linkedSpellIDs) then
        for _, linked in ipairs(info.linkedSpellIDs) do out[#out + 1] = linked end
    end
    return out
end

-- `owner` is what makes two ids "the same thing". Every id belonging to one cooldown
-- entry shares an owner, so the ability and its buff and its talent override do not
-- look like rivals for the name. Two *different* owners claiming one name do.
--
-- That case is real and it breaks things quietly: a spell that puts up a stacking buff
-- and a second aura of the same name is indistinguishable by name, so a name match
-- hands back whichever was walked first and both alerts end up watching one aura -
-- one fires twice, the other never fires at all. Marking the name ambiguous and
-- refusing to answer on it is worse for convenience and correct, which is the trade
-- this addon makes everywhere else.
local function IndexEntry(index, info, value, owner)
    local function put(id)
        if not id then return end

        -- Ids collide too, not just names, and that was the harder half to see. Two
        -- Cooldown Manager entries can report the *same* spellID and differ only in
        -- what they link to - Voidfall does exactly this, two entries both calling
        -- themselves 1253304, one linking 1256301 and the other 1256302, with the
        -- auras living on the linked ids. A plain write meant the second entry
        -- silently replaced the first and an alert on the shared id resolved to
        -- whichever was walked last.
        local prevID = index.idOwner[id]
        if prevID == nil then
            index.idOwner[id] = owner
            index.byID[id]    = value
        elseif prevID ~= owner then
            index.ambiguousID[id] = true
        end

        local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
        if not name then return end
        local prev = index.nameOwner[name]
        if prev == nil then
            index.nameOwner[name] = owner
            index.byName[name]    = value
        elseif prev ~= owner then
            index.ambiguous[name] = true
        end
    end

    for _, id in ipairs(AllIDs(info)) do put(id) end
end

-- Looks a spell up by id first, then by name. The name pass is what lets an aura id
-- picked off your own buffs match the ability id the Cooldown Manager reports - but
-- only where the name means one thing.
-- Defined after TrackedSet, which it has to ask. Declared here because LookupIndexed
-- below closes over it, and a `local` written further down would bind this to a nil
-- global instead - silently, until a name actually collided.
local NameIsShared, IdIsShared

local function LookupIndexed(index, spellID)
    if not index then return nil end
    -- An id claimed by two entries answers for neither - and, as with names, that has
    -- to be judged across every source rather than within this one map. Only one
    -- Voidfall is up at a time, so the live bridge sees a single frame claiming 1253304
    -- and calls it unambiguous, while the Cooldown Manager's catalogue knows perfectly
    -- well that two entries share it.
    if index.ambiguousID[spellID] then return nil end
    if IdIsShared and IdIsShared(spellID) then return nil end
    local hit = index.byID[spellID]
    if hit ~= nil then return hit end

    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if not name then return nil end

    -- Ambiguity has to be judged across every source, not within this one map, and
    -- that was the hole. Only one Voidfall aura is ever up at a time, so a scan of
    -- what is on the player sees one owner for the name and calls it unambiguous -
    -- and then happily answers a lookup for the *other* Voidfall with the aura it
    -- found. Two alerts, two ids, one instance id, both firing for either buff.
    --
    -- The Cooldown Manager already knows the name is shared. Asking it means a name
    -- that means two things anywhere is refused everywhere, which is the only version
    -- of this that does not depend on which buff happens to be up when we look.
    if index.ambiguous[name] then return nil end
    if NameIsShared and NameIsShared(name) then return nil end

    return index.byName[name]
end

local function IndexIsAmbiguous(index, spellID)
    if not index then return false end
    if index.ambiguousID[spellID] then return true end
    if IdIsShared and IdIsShared(spellID) then return true end
    -- An unambiguous exact id match settles it; the name only matters as a fallback.
    if index.byID[spellID] ~= nil then return false end
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    return (name and index.ambiguous[name]) and true or false
end

-- Declared here rather than beside the function that reads it, because BridgeMap
-- below writes to it and a `local` further down would have made that write a silent
-- global - the one bug class the checkers in this repo exist for.
local servedEver = NewIndex()

-- Rebuilt once per update pass rather than once per alert: a dozen alerts walking
-- four frame pools each, ten times a second, is waste for a table that cannot have
-- changed between them.
local bridgeMap, bridgeGeneration, generation = nil, -1, 0

-- Pulled out so the diagnostic below can walk the same frames this does, rather than
-- a second implementation that could be right when the real one is wrong.
local function ViewerFrames(viewer)
    local frames
    if viewer.GetItemFrames then
        local ok, result = pcall(viewer.GetItemFrames, viewer)
        if ok then frames = result end
    end
    if not frames and viewer.itemFramePool then
        frames = {}
        local ok = pcall(function()
            for f in viewer.itemFramePool:EnumerateActive() do
                frames[#frames + 1] = f
            end
        end)
        if not ok then frames = nil end
    end
    return (type(frames) == "table") and frames or nil
end

local function BridgeMap()
    if bridgeGeneration == generation then return bridgeMap end
    bridgeGeneration = generation
    bridgeMap = nil

    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
        return nil
    end

    local map
    for _, name in ipairs(ALL_VIEWERS) do
        local viewer = _G[name]
        -- A hidden viewer has unregistered UNIT_AURA and is no longer being told
        -- about aura changes, so whatever it is still holding is stale. Better to
        -- have no answer than a wrong one.
        if viewer and viewer:IsShown() then
            local frames = ViewerFrames(viewer)

            if frames then
                for _, f in ipairs(frames) do
                    local cooldownID     = f and f.cooldownID
                    local auraInstanceID = f and f.auraInstanceID
                    if cooldownID and auraInstanceID ~= nil then
                        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
                        if ok and info then
                            map = map or NewIndex()
                            IndexEntry(map, info, {
                                id   = auraInstanceID,
                                unit = f.auraDataUnit or "player",
                            }, cooldownID)
                            -- Proof, kept for the session: this spell reached a viewer
                            -- frame, so the Cooldown Manager really is tracking it and
                            -- the bridge's answers about it can be trusted.
                            IndexEntry(servedEver, info, true, cooldownID)
                        end
                    end
                end
            end
        end
    end

    bridgeMap = map
    return map
end

local function BridgeLookup(spellID)
    return LookupIndexed(BridgeMap(), spellID)
end

-- Being in the Cooldown Manager's category set means the game *knows* the spell. It
-- does not mean the Cooldown Manager is *showing* it - that is a separate choice the
-- player makes in Blizzard's own options, and a spell they have not added never
-- reaches a viewer frame, so the bridge never sees it however hard it looks.
--
-- The difference is invisible from the category set alone, and getting it wrong is
-- expensive in both directions: claiming a spell reads in combat when it does not is
-- the failure this addon exists to avoid, and concluding "the buff is not up" from a
-- bridge that was never going to answer would make drop-off alerts fire on nothing.
--
-- So this is measured rather than inferred. Any spell that has actually turned up on a
-- viewer frame this session is one the bridge demonstrably serves. Until then the
-- honest answer about that spell is "cannot tell", and the options window says what to
-- do about it instead of leaving a silent alert.
local function BridgeHasServed(spellID)
    return LookupIndexed(servedEver, spellID) and true or false
end
NBA.BridgeHasServed = BridgeHasServed

-- Whether a *shown* viewer exists at all. Separate from BridgeMap because an empty
-- map means "nothing is procced right now" when a viewer is up, and "we have no
-- bridge" when one is not - opposite answers from the same nil.
--
-- Every viewer counts, not only the two buff ones. BridgeMap reads all four, so a
-- proc that happens to be tracked as an essential cooldown is served by this bridge
-- just as well - and checking a narrower list here would have reported it as
-- unreadable while the addon was busy reading it.
local function BridgeIsLive()
    for _, name in ipairs(ALL_VIEWERS) do
        local viewer = _G[name]
        if viewer and viewer:IsShown() then return true end
    end
    return false
end

-- The client's own answer to "does this character have a Cooldown Manager at all".
-- Worth asking rather than inferring from whether a viewer frame happens to exist:
-- when this is false the entire bridge is unavailable, and telling somebody to go and
-- enable a spell in a feature they do not have would be a wild goose chase.
function NBA.CooldownViewerAvailable()
    if not (C_CooldownViewer and C_CooldownViewer.IsCooldownViewerAvailable) then
        return nil
    end
    local ok, available = pcall(C_CooldownViewer.IsCooldownViewerAvailable)
    if not ok then return nil end
    return available and true or false
end
Watch.BridgeIsLive = BridgeIsLive

-- The set of spells the Cooldown Manager is configured to track for the spec you are
-- currently in. This is the closest thing to a definitive answer this addon has: it
-- is not a guess about what your class might proc, it is the game's own list, and
-- every spell on it is one the bridge can read during a fight.
--
-- Two honest limits. It answers for the **current spec only** - there is no call that
-- returns another spec's set, so the list changes when you change spec rather than
-- being a static per-class table. And it reflects what the Cooldown Manager is set to
-- track, which the player can edit in Blizzard's own options.
--
-- `list` is kept alongside the lookup indexes because the spell picker offers it as a
-- source, and building it there would mean walking every category a second time.
local trackedSet, trackedSpec = nil, nil

-- The categories worth offering as "buffs". Cooldown Manager categories are named
-- differently across 12.0.x and 12.1, and an unknown name is not an error here - the
-- enum is walked and matched by name, so a member that does not exist on this client
-- simply never appears.
local BUFF_CATEGORY_HINTS = {
    TrackedBuff = "Tracked buff",
    TrackedBar  = "Tracked bar",
    BuffIcon    = "Tracked buff",
    BuffBar     = "Tracked bar",
    GroupBuff   = "Group buff",          -- 12.1
    SpecAgnosticTracked = "Tracked",     -- 12.1
    EquipSlotTracked    = "Trinket",     -- 12.1
}

local function TrackedSet()
    local spec = NBA.CurrentSpecID()
    if trackedSet and trackedSpec == spec then return trackedSet end

    trackedSpec = spec
    trackedSet  = nil

    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
            and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
        return nil
    end
    if not (Enum and Enum.CooldownViewerCategory) then return nil end

    -- Two passes, because which id identifies an entry cannot be known until every
    -- entry has been seen. Listing the ability id was wrong twice over: two entries
    -- can share one, so they collapsed into a single row and you could never pick the
    -- second - and the ability id is often not an aura at all, so an alert built on it
    -- watched something that never appears.
    local set, seen, entries
    for categoryName, category in pairs(Enum.CooldownViewerCategory) do
        local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, false)
        if ok and NBA.Walkable(ids) then
            for _, cooldownID in ipairs(ids) do
                seen = seen or {}
                if not seen[cooldownID] then
                    seen[cooldownID] = true
                    local okInfo, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
                    if okInfo and info and info.spellID then
                        set = set or NewIndex()
                        set.familyOf = set.familyOf or {}
                        entries = entries or {}
                        IndexEntry(set, info, true, cooldownID)
                        -- Kept so any one id can be expanded back to the whole entry it
                        -- belongs to. See SiblingIDs below for why that matters.
                        set.familyOf[cooldownID] = AllIDs(info)
                        entries[#entries + 1] = { info = info, categoryName = categoryName }
                    end
                end
            end
        end
    end

    if set then
        set.list = {}
        for _, entry in ipairs(entries) do
            -- The first id this entry does not share with another. For a spell whose
            -- entries all report the same ability, that is the linked id - which is
            -- also the one the aura actually uses.
            local pick = entry.info.spellID
            for _, candidate in ipairs(AllIDs(entry.info)) do
                if not set.ambiguousID[candidate] then
                    pick = candidate
                    break
                end
            end

            local sname = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(pick)
            local sinfo = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(pick)
            set.list[#set.list + 1] = {
                spellID  = pick,
                name     = sname or ("spell " .. pick),
                icon     = sinfo and sinfo.iconID or nil,
                category = BUFF_CATEGORY_HINTS[entry.categoryName],
                isBuff   = BUFF_CATEGORY_HINTS[entry.categoryName] ~= nil,
            }
        end
    end

    if set then
        table.sort(set.list, function(a, b)
            -- Buff categories first: this addon is for buffs, and burying them under
            -- every ability on the bar would make the list useless for its own job.
            if a.isBuff ~= b.isBuff then return a.isBuff end
            return a.name < b.name
        end)
    end

    trackedSet = set
    return set
end

-- Every id belonging to the same Cooldown Manager entry as this one.
--
-- An entry is a family - the ability, its talent override, and the auras it applies -
-- and which member you happen to hold decides where you can be answered. The bridge
-- indexes them all to one payload, so any of them works there. A scan of what is on
-- the unit only ever holds the *aura's* id, so the ability's finds nothing, and an
-- alert built from the Cooldown Manager's list would work in combat and fail out of
-- it. Trying the whole family closes that gap without having to guess which member of
-- it is the real aura.
--
-- Final Hour is the case that showed it up: its entry carries the aura 1256322, which
-- is called Voidfall, so neither the id nor the name of one leads to the other.
local function SiblingIDs(spellID)
    local set = TrackedSet()
    if not (set and set.familyOf) then return nil end
    local owner = set.idOwner[spellID]
    if not owner then return nil end
    return set.familyOf[owner]
end

-- Whether this name means more than one thing anywhere the addon can see. The
-- Cooldown Manager's own catalogue is the authority: it lists every entry for the
-- spec at once, so it sees both Voidfalls whether or not either is currently up.
NameIsShared = function(name)
    if not name then return false end
    local set = TrackedSet()
    if set and set.ambiguous[name] then return true end
    -- The live map, read directly rather than through BridgeMap, so a lookup that
    -- happens while the map is being built cannot recurse into building it again.
    if bridgeMap and bridgeMap.ambiguous[name] then return true end
    return false
end

-- The same question for ids. Kept separate from the name version because an exact id
-- match is normally decisive, and this is the one circumstance where it is not.
IdIsShared = function(spellID)
    if not spellID then return false end
    local set = TrackedSet()
    if set and set.ambiguousID[spellID] then return true end
    if bridgeMap and bridgeMap.ambiguousID[spellID] then return true end
    return false
end

function NBA.CooldownManagerTracks(spellID)
    local set = TrackedSet()
    if not set then return nil end
    return LookupIndexed(set, spellID) and true or false
end

-- Whether this spell can only be matched by a name that means more than one thing.
-- Surfaced in the options window, because the symptom of a collision - one of two
-- alerts firing twice and the other never firing - looks like anything except a
-- naming problem, and there is no way to guess it from the outside.
function NBA.SpellNameCollides(spellID)
    if not spellID then return false end
    return IndexIsAmbiguous(TrackedSet(), spellID)
        or IndexIsAmbiguous(BridgeMap(), spellID)
end

-- The list itself, for the spell picker. Empty rather than nil when the game has no
-- answer, so the caller never has to distinguish "none" from "could not ask".
function NBA.CooldownManagerList()
    local set = TrackedSet()
    return (set and set.list) or {}
end

function Watch.InvalidateTracked()
    trackedSet, trackedSpec = nil, nil
end

--------------------------------------------------------------------------------
-- The out-of-combat enumeration
--
-- Nothing is secret outside combat, so the auras actually on a unit can be read in
-- full - name, id and all. Two jobs:
--
--   * it is how you find the id in the first place. The id printed on a website is
--     as often the ability as the aura it applies, and the two differ more often
--     than people expect. Putting the buff on yourself and picking it out of a list
--     cannot get that wrong.
--   * while it is available it is the authority, because it compares what is
--     actually on the unit instead of asking about an id we hope is right.
--------------------------------------------------------------------------------

-- Returns an array of { spellID, name, icon, harmful, mine }, plus a count of the
-- auras that were present but unreadable. A non-zero skip count is the entire
-- explanation for a short list, so it is reported rather than swallowed.
function NBA.ScanAuras(unit)
    if not UnitName(unit) then
        return nil, 0, "there is no " .. tostring(unit) .. "."
    end
    if not HAS.unitAuras then
        return nil, 0, "this client has no aura enumeration."
    end

    local out, seen, skipped = {}, {}, 0

    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        local ok, auras = pcall(UA.GetUnitAuras, unit, filter, 60)
        if ok and NBA.Walkable(auras) then
            for _, aura in ipairs(auras) do
                -- Plain() rather than a direct read: in combat every one of these is
                -- secret, and the count of what could not be read is the honest thing
                -- to show.
                local spellID = Plain(aura.spellId)
                if spellID == nil then
                    skipped = skipped + 1
                elseif not seen[spellID] then
                    seen[spellID] = true
                    -- The name is resolved from the plain id rather than taken off
                    -- the aura, so it is a plain string we may compare and sort.
                    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
                    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
                    out[#out + 1] = {
                        spellID = spellID,
                        name    = name or ("spell " .. spellID),
                        icon    = info and info.iconID or nil,
                        harmful = (filter == "HARMFUL"),
                        mine    = PlainBool(aura.isFromPlayerOrPlayerPet),
                    }
                end
            end
        end
    end

    -- Everything here is plain, so sorting is allowed. Yours first: the buff you are
    -- hunting is nearly always one you caused.
    table.sort(out, function(a, b)
        if (a.mine and true) ~= (b.mine and true) then return a.mine and true or false end
        return a.name < b.name
    end)

    NBA.RememberSpells(out)
    return out, skipped
end

-- The picker needs something to offer when you are standing in a city with no buffs
-- on. Anything this character has ever had on it, out of combat, goes in the
-- catalog - which is per character because a Paladin's list is noise on a Druid.
function NBA.RememberSpells(list)
    local catalog = NBA.char and NBA.char.catalog
    if not catalog or not list then return end
    for _, e in ipairs(list) do
        catalog[e.spellID] = { name = e.name, icon = e.icon, harmful = e.harmful or nil }
    end
end

-- spellID -> auraInstanceID for one unit, rebuilt at most once per pass. Indexed by
-- name as well, because the id somebody has for a spell is as likely to be the
-- ability as the aura, and the two share a name far more reliably than a number.
local scanMaps, scanGeneration = {}, -1

local function ScanMap(unit)
    if NBA.AurasAreSecret() then return nil end
    if not HAS.unitAuras then return nil end
    if not UnitName(unit) then return nil end

    if scanGeneration ~= generation then
        scanGeneration = generation
        wipe(scanMaps)
    end

    local cached = scanMaps[unit]
    if cached ~= nil then return cached or nil end

    local map
    for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
        local ok, auras = pcall(UA.GetUnitAuras, unit, filter, 60)
        if ok and NBA.Walkable(auras) then
            map = map or NewIndex()
            for _, aura in ipairs(auras) do
                local spellID = Plain(aura.spellId)
                if spellID and aura.auraInstanceID ~= nil then
                    -- Each aura is its own owner here, so two auras that merely share a
                    -- name mark it ambiguous exactly as they should - a unit really can
                    -- be carrying two different buffs called the same thing.
                    IndexEntry(map, { spellID = spellID }, {
                        id   = aura.auraInstanceID,
                        mine = PlainBool(aura.isFromPlayerOrPlayerPet),
                    }, spellID)
                end
            end
        end
    end

    scanMaps[unit] = map or false
    return map
end

--------------------------------------------------------------------------------
-- Resolution
--
-- The one function that answers the question, and the only place allowed to decide
-- that the answer is "no" rather than "cannot tell".
--------------------------------------------------------------------------------

-- Returns present, instanceID, path
--   present    true | false | nil   (nil = the client is not answering)
--   instanceID the aura's instance id when we have one, for swipe/stacks/timer
--   path       a short string naming which route answered, for the options window
local function ResolveAura(a)
    local unit    = a.unit or "player"
    local spellID = a.spellID
    if not spellID then return nil, nil, "no spell" end
    if not UnitName(unit) then return nil, nil, "no " .. unit end

    -- 1. The enumeration, while it is allowed. It compares what is really on the
    --    unit rather than asking about an id we assumed, so nothing beats it - and
    --    when it is available, absent means absent.
    local map = ScanMap(unit)
    if map then
        local hit = LookupIndexed(map, spellID)
        if not hit then
            -- The id in hand may be the ability's while the aura carries a sibling's.
            local family = SiblingIDs(spellID)
            if family then
                for _, sibling in ipairs(family) do
                    if sibling ~= spellID then
                        hit = LookupIndexed(map, sibling)
                        if hit then break end
                    end
                end
            end
        end
        if hit then
            if a.mineOnly and hit.mine == false then
                return false, nil, "scan (not yours)"
            end
            return true, hit.id, "scan"
        end
        return false, nil, "scan"
    end

    -- 2. The direct lookup. Exact, and the only aura call that survives 12.1. It
    --    only answers for spells Blizzard declassified - but when the client says
    --    the spell is readable, a nil from here is a real "not up" rather than a
    --    refusal, and that is what makes drop-off and missing alerts possible at all.
    --
    --    A nil from here is only a real "not up" once the bridge has also been asked.
    --    Spells chosen from the Cooldown Manager's list are *ability* ids, and the
    --    aura they apply carries a different one - so this lookup can answer nil for
    --    a readable spell that is genuinely up under another number. Concluding
    --    "absent" here would make every alert built that way permanently silent.
    local readable = NBA.SpellIsReadable(spellID)
    local directSaysAbsent = false
    if HAS.bySpellID and readable ~= false then
        local ok, aura = pcall(UA.GetUnitAuraBySpellID, unit, spellID)
        if ok and aura and aura.auraInstanceID ~= nil then
            if a.mineOnly and PlainBool(aura.isFromPlayerOrPlayerPet) == false then
                return false, nil, "direct (not yours)"
            end
            return true, aura.auraInstanceID, "direct"
        end
        if ok and readable == true then
            directSaysAbsent = true
        end
    end

    -- 3. The bridge. Covers the spells the first path cannot see, which for a proc
    --    is most of them. A shown viewer that is not showing this spell is a real
    --    "not up"; no viewer at all is no answer.
    local hit = BridgeLookup(spellID)
    if hit and hit.unit == unit then
        return true, hit.id, "cooldown manager"
    end
    -- Only a bridge that has demonstrably carried this spell may say it is not up. A
    -- spell the Cooldown Manager merely *could* track, but is not set to, produces the
    -- same empty answer as one that is genuinely absent, and treating that as "not up"
    -- is a lie the drop-off and missing triggers would act on.
    if BridgeIsLive() and BridgeHasServed(spellID) then
        return false, nil, "cooldown manager"
    end

    -- Every path has now had its say, so a "no" from the direct lookup can be trusted.
    if directSaysAbsent then
        return false, nil, "direct"
    end

    return nil, nil, "hidden"
end

--------------------------------------------------------------------------------
-- Stack thresholds
--
-- I removed this once, on the reasoning that a stack count could not be compared
-- under the secrecy rules and so a threshold was unbuildable. Measured on live
-- 12.0.7 against Collapsing Star in combat, that was simply wrong: `applications`
-- came back plain, and so did the display-count string. The rule about secrets is
-- real but it is per spell, not universal, and reasoning from the rule instead of
-- asking the client cost this feature a version.
--
-- Two ways to answer, in order of how much they give:
--
--   applications                  a number. Compare it and be done.
--   GetAuraApplicationDisplayCount  a string that is *empty below the minimum asked
--                                 for*, so asking with the minimum set to the number
--                                 you care about is itself the threshold test - no
--                                 comparison of counts required, only "is this empty".
--
-- The second is the interesting one, because it may well answer for spells the first
-- will not. If neither will say, the answer is unknown, and unknown stands down like
-- every other unknown in this file.
local function StacksAtLeast(unit, instanceID, want, aura)
    local n = aura and Plain(aura.applications)
    if n == nil and instanceID ~= nil and UA.GetAuraDataByAuraInstanceID then
        local ok, data = pcall(UA.GetAuraDataByAuraInstanceID, unit, instanceID)
        if ok and data then n = Plain(data.applications) end
    end
    if n ~= nil then return n >= want end

    if instanceID ~= nil and HAS.stacks then
        local ok, str = pcall(UA.GetAuraApplicationDisplayCount, unit, instanceID, want, 9999)
        if ok then
            local plain = Plain(str)
            if plain ~= nil then return plain ~= "" end
        end
    end

    return nil
end

-- The threshold is folded into presence rather than bolted on beside it, so a buff
-- that is up but under the mark is *not up* as far as everything downstream is
-- concerned. That gives the firing, holding and dropping logic the right behaviour
-- for free: reaching the threshold is a gain, falling under it is a loss, and sitting
-- above it is a hold.
function Watch:Resolve(a)
    local present, instanceID, path = ResolveAura(a)

    local want = a.minStacks or 0
    if present ~= true or want <= 1 then return present, instanceID, path end

    local enough = StacksAtLeast(a.unit or "player", instanceID, want, nil)
    if enough == nil   then return nil,   instanceID, path .. ", stacks hidden" end
    if enough == false then return false, instanceID, path .. ", under " .. want end
    return true, instanceID, path
end

-- What the options window prints beside a spell. Deliberately phrased as what will
-- happen in a raid, not as an API fact, because that is the question being asked.
function NBA.SpellStatus(spellID)
    if not spellID then
        return "none", "No spell chosen yet."
    end
    local secrecy = NBA.SpellSecrecy(spellID)
    if secrecy == "always" then
        return "always", "Readable everywhere, including raids and keys."
    end
    if NBA.SpellNameCollides(spellID) then
        return "collides",
               "This id is shared with another spell, or its name is - either way it "
               .. "cannot be told apart from something else, so nothing here will answer "
               .. "about it. Put the buff on yourself out of combat and pick it from the "
               .. "picker's \"On a unit right now\" source: that gives the id the aura "
               .. "itself uses, which is unique even when the ability's is not."
    end

    -- Confirmed: this spell has actually come through a viewer frame.
    if BridgeHasServed(spellID) then
        return "bridge",
               "Read through Blizzard's Cooldown Manager, which is tracking it. Works in combat."
    end

    if NBA.CooldownManagerTracks(spellID) then
        if NBA.CooldownViewerAvailable() == false then
            return "sometimes",
                   "Readable out of combat. This character has no Cooldown Manager, so "
                   .. "there is no way to read it during a fight."
        end
        if not BridgeIsLive() then
            return "bridge-off",
                   "Blizzard's Cooldown Manager could read this, but its displays are switched "
                   .. "off - turn one on and add this spell to it."
        end
        -- The distinction that matters, and the one nothing else tells you: the game
        -- knowing a spell is not the same as the Cooldown Manager being set to show it,
        -- and a spell it is not showing cannot be read in combat at all.
        return "bridge-add",
               "The Cooldown Manager knows this spell but is not showing it, and one it is "
               .. "not showing cannot be read in a fight at all. Turn it on in Edit Mode, on "
               .. "the Cooldown Manager itself. This addon cannot do it for you - the layout "
               .. "is a single encoded blob, so writing to it would mean replacing your whole "
               .. "Cooldown Manager rather than adding one spell. This line turns green on "
               .. "its own the moment it sees the spell come through."
    end
    if secrecy == "never" then
        return "never", "Never readable in combat. This alert only fires outside a fight."
    end
    return "sometimes", "Readable out of combat. In a raid or key it depends on the pull."
end

--------------------------------------------------------------------------------
-- The pass
--
-- UNIT_AURA is synchronous and fires hard in combat, so it never does the work
-- itself: it opens a short window in which a single ticker looks every frame. A burst
-- of thirty aura events therefore costs one window rather than thirty resolves, and
-- the rest of the time the ticker idles at ten passes a second.
--
-- The ticker is not redundant with the events. The Cooldown Manager's own frames
-- update on their own schedule and there is no event for "the viewer changed what
-- it is holding", so the bridge is only ever seen by looking - which is exactly why
-- one look per event was not enough.
--------------------------------------------------------------------------------

local INTERVAL = 0.1

--------------------------------------------------------------------------------
-- Watching the watcher
--
-- "It seems delayed" is not something either of us can settle by reading the code.
-- Three paths can answer, they disagree about when, and the one that covers procs is
-- a Blizzard frame updating on its own schedule - so the only honest way to find out
-- where a late alert lost its time is to timestamp it.
--
-- Session-only and off by default: this prints on every state change, which is far
-- too much to leave running, and a saved setting would eventually be left on.
--------------------------------------------------------------------------------

NBA.debug = false
local lastAuraEvent = 0

--------------------------------------------------------------------------------
-- Auras that changed without going away
--
-- A stacking buff that is spent down but not spent out never drops off. It loses
-- stacks, gains them back, and keeps the same aura the whole time - so there is no
-- gain to fire on, no loss to fire on, and not even a new instance id, because the
-- instance is the same one. An alert on it goes off once at the pull and then never
-- again, which is exactly what a Demon Hunter watching Collapsing Star through meta
-- sees.
--
-- The signal for it is in UNIT_AURA's own payload. `updatedAuraInstanceIDs` lists the
-- auras that changed, and on 12.0 the id arrays are NeverSecretContents - so we can be
-- told *that* an aura changed even when every fact about the change is withheld. We
-- never learn the stack count and do not need to: "it changed" is the event.
--
-- Filled by the event handler, drained by the pass that follows it, so an update is
-- always consumed exactly once.
local changedAuras = {}

local function DebugState(a, s, present, path, instanceID)
    local was = s.dbgPresent
    if was == present and s.dbgPath == path and s.dbgInstance == instanceID then return end
    s.dbgPresent, s.dbgPath, s.dbgInstance = present, path, instanceID

    local answer = (present == true and "|cff55dd55up|r")
                or (present == false and "|cffdd5555not up|r")
                or "|cffe0b040cannot tell|r"
    -- Only a delta when the aura event could plausibly have caused this change.
    -- Turning debug on while a buff is already up prints one line immediately, and
    -- timing it against whatever aura event happened to be most recent produces a
    -- number that looks like latency and is not - the first reading was a second of
    -- nothing at all, which read as a second of lag.
    local gap   = GetTime() - lastAuraEvent
    local since = (lastAuraEvent > 0 and gap <= 0.5)
                  and (" |cff666666+%dms since aura event|r"):format(math.floor(gap * 1000))
                  or " |cff666666(no aura event - idle poll or first look)|r"
    print(("|cff6fc2ffnba|r %s: %s via %s%s%s")
          :format(a.name or "?", answer, path or "?",
                  instanceID and (" |cff666666#" .. instanceID .. "|r") or "", since))
end

local function Fire(a, id, s, kind, instanceID)
    local now = GetTime()
    if (now - (s.lastFire or 0)) < (a.rearm or 0) then return end
    s.lastFire = now
    NBA.Display:Fire(id, a, kind, instanceID)
end

function Watch:Pass()
    generation = generation + 1

    local db = NBA.db
    if not db then return end

    for _, id in ipairs(db.order) do
        local a = db.alerts[id]
        if a and a.enabled and a.spellID and NBA.AlertAppliesHere(a) then
            local s = StateFor(id)
            local present, instanceID, path = self:Resolve(a)

            s.path = path
            if NBA.debug then DebugState(a, s, present, path, instanceID) end

            -- Unknown ends every comparison. The previous answer is kept rather than
            -- overwritten, so coming out of a pull where the client went quiet does
            -- not read as a fresh gain for a buff that was up the whole time.
            if present ~= nil then
                local was         = s.present
                local wasInstance = s.instanceID
                s.present    = present
                s.instanceID = instanceID

                -- A proc landing again while this still believed the last one was up
                -- produced no edge at all, so nothing fired and the alert looked
                -- late - or simply never arrived. auraInstanceID is NeverSecret, so
                -- comparing it is allowed, and a different one is the game telling us
                -- this is a *new application* rather than the same aura still running.
                --
                -- That is the difference between "the buff is up" and "the buff just
                -- procced", and for anything that refreshes itself mid-fight only the
                -- second one is the thing being waited for. The re-fire is still
                -- subject to the rearm delay, which is what stops an aura that
                -- re-applies on every tick from strobing.
                local reapplied = present and instanceID ~= nil
                                  and wasInstance ~= nil and instanceID ~= wasInstance

                -- And the case where even the instance id stays put: the aura was
                -- named in the last UNIT_AURA as having changed. Opt-in, because on a
                -- buff that ticks it would fire constantly - which is what the rearm
                -- delay is for once it is switched on.
                local changed = present and a.refire and instanceID ~= nil
                                and changedAuras[instanceID] and true or false

                if present and (was ~= true or reapplied or changed) then
                    if a.trigger == "gain" then
                        Fire(a, id, s, "gain", instanceID)
                    elseif a.trigger == "missing" then
                        NBA.Display:Stop(id)
                    end
                elseif not present and was == true then
                    if a.trigger == "loss" then
                        Fire(a, id, s, "loss", nil)
                    end
                end

                -- Holding states are levels rather than edges, so they are asserted
                -- every pass instead of being fired once. That also covers the case
                -- where the frame was hidden by something else.
                if a.trigger == "missing" and not present then
                    NBA.Display:Hold(id, a, nil)
                elseif a.trigger == "gain" and a.mode == "hold" then
                    if present then
                        NBA.Display:Hold(id, a, instanceID)
                    else
                        NBA.Display:Stop(id)
                    end
                end
            end
        end
    end

    -- Drained here rather than in the handler: every alert has now had its chance to
    -- see this batch, and leaving it would make the same stack change fire again on
    -- the next pass.
    if next(changedAuras) then wipe(changedAuras) end
end

--------------------------------------------------------------------------------
-- Bridge report
--
-- Answers, in one command and in combat, the question that reading the code cannot:
-- is the bridge alive, what is it holding, and what does every alert resolve to right
-- now. Deliberately walks the same ViewerFrames the real path does, because a second
-- implementation could be right while the one that matters is wrong.
--------------------------------------------------------------------------------

function NBA.BridgeReport()
    NBA.Print("Cooldown Manager bridge, right now:")

    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo) then
        print("  |cffdd5555C_CooldownViewer is not present on this client.|r")
        return
    end

    for _, name in ipairs(ALL_VIEWERS) do
        local viewer = _G[name]
        if not viewer then
            print(("  %-28s |cffdd5555does not exist|r"):format(name))
        elseif not viewer:IsShown() then
            print(("  %-28s |cffe0b040hidden - not updating|r"):format(name))
        else
            local frames = ViewerFrames(viewer)
            local total, withAura = 0, 0
            if frames then
                for _, f in ipairs(frames) do
                    total = total + 1
                    if f and f.auraInstanceID ~= nil then withAura = withAura + 1 end
                end
            end
            print(("  %-28s |cff55dd55shown|r  %d frames, %d holding an aura")
                  :format(name, total, withAura))
        end
    end

    local set = TrackedSet()
    print(("  cooldown viewer available: %s   tracked for this spec: %s   auras secret: %s")
          :format(tostring(NBA.CooldownViewerAvailable()),
                  set and #set.list or 0, tostring(NBA.AurasAreSecret())))

    print("  alerts:")
    for _, id in ipairs(NBA.db.order) do
        local a = NBA.db.alerts[id]
        if a and a.spellID then
            local present, instanceID, path = Watch:Resolve(a)
            local answer = (present == true and "|cff55dd55up|r")
                        or (present == false and "|cffdd5555not up|r")
                        or "|cffe0b040cannot tell|r"
            print(("    %s (%d)  %s via %s%s  tracked=%s readable=%s%s")
                  :format(a.name or "?", a.spellID, answer, path or "?",
                          instanceID and (" #" .. instanceID) or "",
                          tostring(NBA.CooldownManagerTracks(a.spellID)),
                          tostring(NBA.SpellIsReadable(a.spellID)),
                          NBA.SpellNameCollides(a.spellID)
                          and "  |cffdd5555name shared with another spell|r" or ""))
        end
    end
end

--------------------------------------------------------------------------------
-- Cooldown Manager dump
--
-- Every id the Cooldown Manager holds for a spell, laid out. When two spells share a
-- name, or the buff carries an id nothing else mentions, this is the only place the
-- shape of the problem is visible - the options window can say a name collides but it
-- cannot show you which ids to use instead.
--------------------------------------------------------------------------------

local function SpellLabel(id)
    if not id then return nil end
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
    return ("%d|cff888888(%s)|r"):format(id, name or "?")
end

function NBA.CooldownDump(filter)
    if not (C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
            and C_CooldownViewer.GetCooldownViewerCooldownInfo
            and Enum and Enum.CooldownViewerCategory) then
        NBA.Print("no Cooldown Manager on this client.")
        return
    end

    -- Built up front so the served/onViewer columns mean the same thing on every line.
    -- Left to the first lookup, the map would be built partway down the report and the
    -- lines above it would read as unserved when they were merely early.
    BridgeMap()

    local needle = (filter and filter ~= "") and filter:lower() or nil
    NBA.Print(needle and ("Cooldown Manager entries matching \"" .. needle .. "\":")
                     or "Cooldown Manager entries:")

    -- GetCooldownViewerCategorySet takes a second argument whose meaning is not
    -- documented, and everything in this addon has been reading it as `false`. If the
    -- two variants disagree, the one this addon uses is listing entries the player
    -- cannot actually choose - which would make "add it to the Cooldown Manager"
    -- advice for spells that can never be added. Both are asked so the difference is
    -- visible rather than assumed.
    local alt, altTotal, baseTotal = {}, 0, 0
    for _, category in pairs(Enum.CooldownViewerCategory) do
        local okA, idsA = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, true)
        if okA and NBA.Walkable(idsA) then
            for _, cooldownID in ipairs(idsA) do
                if not alt[cooldownID] then
                    alt[cooldownID] = true
                    altTotal = altTotal + 1
                end
            end
        end
        local okB, idsB = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, false)
        if okB and NBA.Walkable(idsB) then baseTotal = baseTotal + #idsB end
    end
    print(("  |cff888888entries: %d with the flag off, %d with it on|r")
          :format(baseTotal, altTotal))

    local shown, seen = 0, {}
    for categoryName, category in pairs(Enum.CooldownViewerCategory) do
        local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, category, false)
        if ok and NBA.Walkable(ids) then
            for _, cooldownID in ipairs(ids) do
                if not seen[cooldownID] then
                    seen[cooldownID] = true
                    local okInfo, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
                    if okInfo and info and info.spellID then
                        -- Matched against every id the entry knows, not just the
                        -- ability's. An entry named after one spell can carry the buff
                        -- you are hunting as a linked id, and filtering on the ability
                        -- name alone hides exactly the entry you are looking for.
                        local matched = (needle == nil)
                        if not matched then
                            for _, candidate in ipairs(AllIDs(info)) do
                                local n = C_Spell and C_Spell.GetSpellName
                                          and C_Spell.GetSpellName(candidate)
                                if n and n:lower():find(needle, 1, true) then
                                    matched = true
                                    break
                                end
                            end
                            -- And by id, so a number pasted from a tooltip finds the
                            -- entry that carries it however it is named.
                            if not matched and tonumber(needle) then
                                for _, candidate in ipairs(AllIDs(info)) do
                                    if candidate == tonumber(needle) then
                                        matched = true
                                        break
                                    end
                                end
                            end
                        end
                        if matched then
                            shown = shown + 1
                            print(("  |cff6fc2ff#%s|r %s  spell %s  %s")
                                  :format(tostring(cooldownID), categoryName,
                                          SpellLabel(info.spellID),
                                          alt[cooldownID] and "|cff55dd55offered|r"
                                                          or "|cffdd5555not offered|r"))
                            if info.overrideSpellID then
                                print(("      override  %s"):format(SpellLabel(info.overrideSpellID)))
                            end
                            if NBA.Walkable(info.linkedSpellIDs) then
                                for _, linked in ipairs(info.linkedSpellIDs) do
                                    print(("      linked    %s"):format(SpellLabel(linked)))
                                end
                            end
                            -- Whether this entry is actually reaching the addon.
                            print(("      served=%s  onViewerNow=%s")
                                  :format(tostring(BridgeHasServed(info.spellID)),
                                          tostring(BridgeLookup(info.spellID) ~= nil)))
                        end
                    end
                end
            end
        end
    end

    if shown == 0 then
        NBA.Print("nothing matched. Try |cff6fc2ff/nba cdm|r with no filter to see everything.")
    end
end

--------------------------------------------------------------------------------
-- One spell, all its answers
--
-- Being absent from the Cooldown Manager is not the same as being untrackable, and
-- assuming otherwise writes off spells that work perfectly well. The bridge is only
-- one of three paths: a spell the game has declassified is readable directly, in a
-- raid, with no Cooldown Manager involved at all. This says which case a given id is
-- in without having to build an alert to find out.
--------------------------------------------------------------------------------

function NBA.SpellReport(arg)
    local spellID = tonumber(arg)
    if not spellID then
        NBA.Print("usage: |cff6fc2ff/nba spell <id>|r - hover a buff with tooltip ids on "
                  .. "to find one.")
        return
    end

    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    if not name then
        NBA.Print(("no spell %d exists on this client."):format(spellID))
        return
    end

    NBA.Print(("%s |cff888888(%d)|r"):format(name, spellID))

    local readable = NBA.SpellIsReadable(spellID)
    print(("    readable right now   %s"):format(
        readable == true and "|cff55dd55yes|r"
        or readable == false and "|cffdd5555no|r" or "|cff888888unknown|r"))
    print(("    always/never/depends %s"):format(tostring(NBA.SpellSecrecy(spellID))))
    print(("    cooldown manager     %s"):format(
        NBA.CooldownManagerTracks(spellID) and "|cff55dd55tracks it|r"
        or "|cffe0b040does not track it|r"))
    print(("    shares a name or id  %s"):format(
        NBA.SpellNameCollides(spellID) and "|cffdd5555yes|r" or "no"))

    local _, why = NBA.SpellStatus(spellID)
    print("    |cffffffff" .. (why or "") .. "|r")
end

--------------------------------------------------------------------------------
-- Stack probe
--
-- Settles, on a live client and in combat, whether a stack count can be *reasoned*
-- about or only shown. The distinction decides whether "alert me at maximum stacks"
-- is buildable at all, and it is not answerable by reading documentation.
--
-- It goes through this addon's own resolution rather than calling
-- GetUnitAuraBySpellID directly, because for the spells this question matters for -
-- the ones read through the Cooldown Manager - the direct lookup returns nothing and
-- a hand-written probe finds no aura to ask about.
--------------------------------------------------------------------------------

local function Describe(value)
    if value == nil then return "|cff888888nil|r" end
    if issecretvalue and issecretvalue(value) then return "|cffdd5555secret|r" end
    if value == "" then return "|cff55dd55plain|r |cff888888(empty)|r" end
    return ("|cff55dd55plain|r \"%s\""):format(tostring(value))
end

function NBA.StackProbe()
    NBA.Print("stack readability, right now:")

    if not HAS.stacks then
        print("  |cffdd5555GetAuraApplicationDisplayCount does not exist on this client.|r")
        return
    end

    local any = false
    for _, id in ipairs(NBA.db.order) do
        local a = NBA.db.alerts[id]
        if a and a.spellID then
            local present, instanceID, path = Watch:Resolve(a)
            if present == true and instanceID ~= nil then
                any = true
                local unit = a.unit or "player"
                print(("  %s (%d) via %s  #%d")
                      :format(a.name or "?", a.spellID, path or "?", instanceID))

                -- The count as a display string, asked at several thresholds. It comes
                -- back empty below the minimum, so if these are plain then asking with
                -- the minimum set to the number you care about IS a threshold test.
                for _, range in ipairs({ { 1, 99 }, { 2, 99 }, { 5, 99 }, { 10, 99 } }) do
                    local ok, str = pcall(UA.GetAuraApplicationDisplayCount,
                                          unit, instanceID, range[1], range[2])
                    print(("      min=%-3d %s"):format(range[1],
                          ok and Describe(str) or "|cffdd5555call failed|r"))
                end

                -- And the raw count, which is the other way this could be possible.
                if UA.GetAuraDataByAuraInstanceID then
                    local ok, data = pcall(UA.GetAuraDataByAuraInstanceID, unit, instanceID)
                    print(("      applications  %s")
                          :format(ok and data and Describe(data.applications)
                                  or "|cff888888no aura data|r"))
                end
            end
        end
    end

    if not any then
        NBA.Print("no alert resolved to a buff that is up - run this with one on you.")
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Watch:Init()
    -- Two frames because RegisterUnitEvent takes at most two units, and the
    -- alternative - a bare RegisterEvent - would hand us every UNIT_AURA in a
    -- twenty-man raid to throw away.
    local aura1 = CreateFrame("Frame")
    aura1:RegisterUnitEvent("UNIT_AURA", "player", "pet")
    local aura2 = CreateFrame("Frame")
    aura2:RegisterUnitEvent("UNIT_AURA", "target", "focus")

    -- An aura event does not mean the answer is available yet. When a spell is read
    -- through the Cooldown Manager, the thing being watched is a Blizzard frame that
    -- is reacting to the same event we are - and if it has not reacted by the time
    -- this pass runs, the proc reads as absent and the next scheduled look is a tenth
    -- of a second away. One event, one pass, one visibly late alert.
    --
    -- So an event opens a short window of per-frame passes instead of asking for a
    -- single one. Whichever frame the viewer updates on, the alert goes up on that
    -- frame. A quarter of a second of per-frame work over a handful of alerts costs
    -- nothing and is the difference between "instant" and "sometimes lags".
    local SETTLE = 0.25
    local settleUntil = 0

    local function OnAura(_, _, _, updateInfo)
        lastAuraEvent = GetTime()
        settleUntil   = lastAuraEvent + SETTLE

        -- Walkable first: the payload's containers can themselves be secret in
        -- combat, and a secret table throws on ipairs rather than returning nothing.
        if type(updateInfo) == "table"
           and NBA.Walkable(updateInfo.updatedAuraInstanceIDs) then
            for _, auraInstanceID in ipairs(updateInfo.updatedAuraInstanceIDs) do
                if auraInstanceID ~= nil then changedAuras[auraInstanceID] = true end
            end
        end
    end
    aura1:SetScript("OnEvent", OnAura)
    aura2:SetScript("OnEvent", OnAura)

    local misc = CreateFrame("Frame")
    misc:RegisterEvent("PLAYER_TARGET_CHANGED")
    misc:RegisterEvent("PLAYER_FOCUS_CHANGED")
    misc:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    -- A talent swap changes which ability a cooldown entry overrides to, so the id
    -- lists the tracked set was built from go stale without the spec changing at all.
    misc:RegisterEvent("TRAIT_CONFIG_UPDATED")
    misc:RegisterEvent("PLAYER_REGEN_ENABLED")
    misc:RegisterEvent("PLAYER_ENTERING_WORLD")
    misc:SetScript("OnEvent", function(_, event)
        if event == "TRAIT_CONFIG_UPDATED" then
            Watch.InvalidateTracked()
        elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
            Watch.InvalidateTracked()
            -- An alert pinned to the old spec has to come off the screen at once
            -- rather than at the end of its fade.
            NBA.Display:StopAll()
            wipe(state)
        elseif event == "PLAYER_REGEN_ENABLED" then
            -- Combat just ended, so the enumeration is available again. Refreshing
            -- the catalog here is free and keeps the picker useful.
            local list = NBA.ScanAuras("player")
            if list then NBA.RememberSpells(list) end
        elseif event == "PLAYER_ENTERING_WORLD" then
            NBA.ApplyCooldownManagerFade()
        end
        settleUntil = GetTime() + SETTLE
    end)

    local elapsed = 0
    local ticker = CreateFrame("Frame")
    ticker:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if GetTime() >= settleUntil and elapsed < INTERVAL then return end
        elapsed = 0
        Watch:Pass()
    end)

    NBA.ApplyCooldownManagerFade()

    -- An alert saved against an id that turns out to be shared is silently broken in a
    -- way that looks like every other kind of broken: nothing fires in combat, and out
    -- of combat it fires for the wrong buff, because the name fallback finds whichever
    -- aura is actually up. There is no safe way to repair it automatically - only the
    -- player knows which of the two spells they meant - so it gets said out loud once.
    --
    -- Delayed because the Cooldown Manager's category sets are not populated the
    -- instant we log in, and asking too early reports every spell as fine.
    C_Timer.After(8, function()
        if not NBA.db then return end
        local bad = {}
        for _, id in ipairs(NBA.db.order) do
            local a = NBA.db.alerts[id]
            if a and a.enabled and a.spellID and NBA.SpellNameCollides(a.spellID) then
                bad[#bad + 1] = ("%s (%d)"):format(a.name or "?", a.spellID)
            end
        end
        if #bad > 0 then
            NBA.Print(("%d alert%s watching a spell that cannot be told apart from "
                       .. "another - choose it again in |cff6fc2ff/nba|r:")
                      :format(#bad, #bad == 1 and " is" or "s are"))
            for _, line in ipairs(bad) do print("    " .. line) end
        end
    end)
end

--------------------------------------------------------------------------------
-- Keeping the bridge alive without keeping it visible
--
-- The viewer has to be shown for its data to stay fresh, and most people do not
-- want a second row of buff icons on their screen. Alpha is not the shown flag, so
-- setting it to zero satisfies both: the viewer still updates, and nothing is drawn.
--
-- Only alpha is touched. Hiding, moving or reparenting a Blizzard frame is how
-- addons acquire taint; setting alpha on one is not protected and does not.
--------------------------------------------------------------------------------

function NBA.ApplyCooldownManagerFade()
    local db = NBA.db
    if not db then return end
    for _, name in ipairs(BUFF_VIEWERS) do
        local viewer = _G[name]
        if viewer and viewer.SetAlpha then
            pcall(viewer.SetAlpha, viewer, db.fadeCooldownManager and 0 or 1)
        end
    end
end
