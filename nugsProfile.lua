--------------------------------------------------------------------------------
-- nugsProfile
-- Copyright (c) 2026 nugs. All Rights Reserved.
--
-- Per-character settings for every nugs addon.
--
-- CANONICAL COPY: D:\Claude\shared\nugsProfile.lua
-- Do not edit the copy inside an addon. Edit this file and run:
--     node sync-shared.js
-- sync-shared.js --check fails if any addon's copy has drifted, so an edit made in
-- the wrong place is caught rather than silently living in one addon.
--
--------------------------------------------------------------------------------
-- WHY THIS EXISTS
--
-- Settings used to be account-wide, so a tweak made on the paladin changed the
-- priest. The usual answer to that is named profiles - the ElvUI model - where
-- several characters point AT one profile. That is a reference, and it has the same
-- problem by construction: editing what two characters share edits both of them.
--
-- So nothing here is ever linked. A character's settings are SEEDED once - from a
-- template, from another character, or from the defaults - and are its own from
-- then on. Copying is an action you take, not a state you are left in. You give up
-- automatic propagation and get back the guarantee that nothing you do on one
-- character can reach another.
--
-- WHERE IT LIVES
--
-- All of it in the account-wide saved variables, keyed by character - NOT in
-- SavedVariablesPerCharacter. That is not a preference: the client only loads the
-- per-character file for the character being played, so a per-character file cannot
-- be read to copy settings FROM an alt. Copying between characters is the whole
-- point, so the data has to be somewhere every character can see.
--
-- SavedVariablesPerCharacter stays useful for genuinely incidental state - a
-- learned spell catalog, the last tab you had open - which nobody copies.
--------------------------------------------------------------------------------

local ADDON_NAME, ns = ...

local Profile = {}
ns.Profile = Profile

-- The keys this file manages inside the account-wide table. Anything else found at
-- the top level is the addon's own account-wide bookkeeping, or pre-conversion
-- settings waiting to be migrated.
local MANAGED = { chars = true, roster = true, template = true, profileVersion = true }

--------------------------------------------------------------------------------
-- Table helpers
--------------------------------------------------------------------------------

local function DeepCopy(src)
    if type(src) ~= "table" then return src end
    local out = {}
    for key, value in pairs(src) do out[key] = DeepCopy(value) end
    return out
end

-- Fill in anything the stored table is missing, without touching what it has.
--
-- Only descends where BOTH sides are tables. A stored value that is not a table
-- stands, even where the default is one: that is a setting somebody changed, and a
-- new addon version is not a reason to overwrite it.
local function FillDefaults(dst, defaults)
    if type(defaults) ~= "table" then return dst end
    for key, value in pairs(defaults) do
        if dst[key] == nil then
            dst[key] = DeepCopy(value)
        elseif type(dst[key]) == "table" and type(value) == "table" then
            FillDefaults(dst[key], value)
        end
    end
    return dst
end

-- Overwrite a table's CONTENTS, keeping the table itself.
--
-- Every copy operation goes through this. The addon holds a reference to the
-- settings table - that is what Init returns - so replacing the table instead of
-- its contents would leave the addon reading settings that are no longer stored.
local function Replace(target, source)
    for key in pairs(target) do target[key] = nil end
    for key, value in pairs(source) do target[key] = DeepCopy(value) end
end

--------------------------------------------------------------------------------
-- Identity
--------------------------------------------------------------------------------

-- "Name-Realm", which is unique where a bare name is not: two characters on two
-- realms can share a name and would otherwise share their settings, which is the
-- exact bug this file exists to prevent.
function Profile:Key()
    local name  = UnitName("player")
    local realm = GetRealmName and GetRealmName() or ""
    if not name then return nil end
    return realm ~= "" and (name .. "-" .. realm) or name
end

local function RosterEntry()
    local className, classFile, classID = UnitClass("player")
    return {
        name    = UnitName("player"),
        realm   = GetRealmName and GetRealmName() or "",
        class   = className,
        classFile = classFile,
        classID = classID,
        level   = UnitLevel and UnitLevel("player") or nil,
    }
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

-- opts.global    name of the account-wide saved variable, as a STRING
-- opts.defaults  the settings table's defaults
-- opts.onApply   called after any operation that replaces the live settings, so the
--                addon can rebuild whatever it draws from them
-- opts.carry     extra key names that are settings but have no default, because nil
--                is meaningful for them - "not asked yet" is a real state that no
--                default can express. Listed here so the migration moves them with
--                everything else instead of stranding them on the account table.
-- opts.migrate   called with the stored table BEFORE the defaults are filled in, for
--                one-time repairs that test whether a key is missing. Filling the
--                defaults first would answer every such test with the default and the
--                repair would never fire - which is how a migration silently stops
--                working the moment it is moved behind one.
--
-- Returns this character's settings table. Assign it wherever the addon previously
-- assigned the account-wide one and every existing read and write keeps working.
---@return table settings this character's settings
function Profile:Init(opts)
    self.globalName = opts.global
    self.defaults   = opts.defaults or {}
    self.onApply    = opts.onApply
    self.migrate    = opts.migrate
    self.carry      = opts.carry

    local db = _G[self.globalName]
    if type(db) ~= "table" then
        db = {}
        _G[self.globalName] = db
    end
    self.account = db

    db.chars  = db.chars  or {}
    db.roster = db.roster or {}

    -- Called at ADDON_LOADED, where the player's name may not be readable yet.
    -- Rather than returning nil - which would make every settings read nil and the
    -- addon look broken - hand back a detached table filled with the defaults and
    -- let Attach() bind it to the real character at PLAYER_LOGIN. The addon holds
    -- one reference either way and never has to know which happened.
    local key = self:Key()
    if not key then
        self.pending = true
        self.db = FillDefaults({}, self.defaults)
        return self.db
    end

    self.db = self:Bind(key)
    return self.db
end

-- Bind this character's stored settings, migrating and seeding as needed.
function Profile:Bind(key)
    local db = self.account

    -- One-time migration off account-wide settings.
    --
    -- Everything at the top level that the defaults know about is pre-conversion
    -- settings. It becomes this character's settings AND the template, so the
    -- character you convert on keeps exactly what it had and every other character
    -- starts from it rather than from bare defaults. Nobody loses a setup.
    if not db.profileVersion then
        local carried = {}
        local found = false

        local function Take(name)
            if db[name] ~= nil and not MANAGED[name] then
                carried[name] = DeepCopy(db[name])
                db[name] = nil
                found = true
            end
        end

        for name in pairs(self.defaults) do Take(name) end
        for _, name in ipairs(self.carry or {}) do Take(name) end
        if found then
            db.chars[key]  = db.chars[key] or carried
            db.template    = db.template or DeepCopy(carried)
        end
        db.profileVersion = 1
    end

    -- A character with nothing yet is seeded from the template, or from defaults
    -- when there is no template. A COPY of the template, never a reference to it.
    if not db.chars[key] then
        db.chars[key] = db.template and DeepCopy(db.template) or {}
    end

    db.roster[key] = RosterEntry()

    self.key = key

    -- Before the defaults, deliberately. See opts.migrate.
    if self.migrate then self.migrate(db.chars[key]) end
    return FillDefaults(db.chars[key], self.defaults)
end

-- Bind a profile that Init could not, because the player was not readable yet.
--
-- Call from PLAYER_LOGIN. Returns true when it actually bound something, so the
-- caller knows to redraw: the settings it has been holding since ADDON_LOADED were
-- the defaults, and they may have just become somebody's saved setup.
function Profile:Attach()
    if not self.pending then return false end

    local key = self:Key()
    if not key then return false end

    local stored = self:Bind(key)
    -- Contents, not the table. The addon is holding a reference to self.db and
    -- swapping it would leave every one of those references on the detached copy.
    Replace(self.db, stored)
    FillDefaults(self.db, self.defaults)
    self.account.chars[key] = self.db

    self.pending = nil
    if self.onApply then self.onApply() end
    return true
end

function Profile:Current()
    return self.db
end

--------------------------------------------------------------------------------
-- Reading the roster
--------------------------------------------------------------------------------

-- Every character that has settings stored, current one first, then by name.
--
-- Sorted rather than returned in pairs() order, because pairs() is a different
-- order on every login and a list that reshuffles itself is unusable as a menu.
function Profile:Characters()
    local out = {}
    for key in pairs(self.account.chars or {}) do
        local info = (self.account.roster or {})[key] or {}
        out[#out + 1] = {
            key     = key,
            name    = info.name or key,
            realm   = info.realm,
            class   = info.class,
            classFile = info.classFile,
            current = (key == self.key),
        }
    end
    table.sort(out, function(a, b)
        if a.current ~= b.current then return a.current end
        return (a.name or "") < (b.name or "")
    end)
    return out
end

function Profile:HasTemplate()
    return self.account.template ~= nil
end

--------------------------------------------------------------------------------
-- Copying
--
-- Every one of these replaces the live settings table's CONTENTS rather than the
-- table itself. The addon holds a reference to it - that is the whole point of
-- Init returning it - so swapping the table would leave every existing reference
-- pointing at the old settings and the addon would carry on reading them.
--------------------------------------------------------------------------------

function Profile:Apply(source)
    if type(source) ~= "table" or not self.db then return false end
    Replace(self.db, source)
    FillDefaults(self.db, self.defaults)
    if self.onApply then self.onApply() end
    return true
end

function Profile:CopyFrom(key)
    if key == self.key then return false end
    local source = (self.account.chars or {})[key]
    if not source then return false end
    return self:Apply(source)
end

-- Push this character's settings onto every other character.
--
-- A deliberate action with an obvious name, which is the thing shared profiles gave
-- you for free and charged for forever afterwards. Returns how many it wrote, so
-- the caller can say so rather than appearing to do nothing.
function Profile:CopyToAll()
    local written = 0
    for key in pairs(self.account.chars or {}) do
        if key ~= self.key then
            self.account.chars[key] = DeepCopy(self.db)
            written = written + 1
        end
    end
    return written
end

function Profile:SaveTemplate()
    self.account.template = DeepCopy(self.db)
end

function Profile:ApplyTemplate()
    return self:Apply(self.account.template)
end

function Profile:ClearTemplate()
    self.account.template = nil
end

function Profile:Reset()
    return self:Apply({})
end

-- Forget a character you no longer play. Refused for the one you are on, which
-- would delete the settings currently in use and leave the addon holding a table
-- that is no longer stored anywhere.
function Profile:Forget(key)
    if not key or key == self.key then return false end
    if not (self.account.chars or {})[key] then return false end
    self.account.chars[key] = nil
    if self.account.roster then self.account.roster[key] = nil end
    return true
end
