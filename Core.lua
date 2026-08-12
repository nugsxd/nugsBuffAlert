--------------------------------------------------------------------------------
-- nugsBuffAlert
-- Copyright (c) 2026 nugs. All Rights Reserved.
-- Unauthorized copying, distribution, or modification is prohibited. See LICENSE.
--------------------------------------------------------------------------------
-- nugsBuffAlert  -  Core.lua
-- The namespace, the alert model, saved variables and the slash command.
--
-- One alert is one spell. It watches a single aura on a single unit and, when that
-- aura appears, puts something on the screen where you told it to: a line of text,
-- an icon, or both. That is the whole addon.
--
-- Deliberately not a group tracker. nugsAuras exists for "show me everything
-- matching this filter, laid out in a row"; the shape here is the opposite one, a
-- named thing you are waiting for and want to be told about. Keeping them apart
-- means this one has no filters, no growth direction and no wrap - an alert has a
-- position and a look and nothing else - and it means someone who only wants proc
-- text does not have to learn a group model to get it.
--
-- Shared namespace: the second vararg is the same table across every Lua file in
-- this addon, so all state and functions hang off of it.
--------------------------------------------------------------------------------

local ADDON_NAME, NBA = ...

NBA.name    = ADDON_NAME
NBA.version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
              or "0.1.0"

local PREFIX = "|cff6fc2ffnugsBuffAlert|r: "
function NBA.Print(msg)
    print(PREFIX .. tostring(msg))
end

--------------------------------------------------------------------------------
-- Secret values (Midnight / 12.0)
--
-- Aura data is handed to addons as opaque "secret" values in combat, encounters,
-- keystones and rated pvp. Reading one is fine; doing arithmetic or comparisons on
-- it raises a Lua error. Everything pulled off an aura therefore goes through
-- Plain(), which hands back nil rather than something we may not compute with.
--
-- A secret *boolean* is the sharp edge: truth-testing one throws, because a
-- boolean's truthiness is its value. PlainBool() gives a true/false/nil tri-state
-- so nil can mean "not allowed to know" rather than collapsing into false.
--
-- That tri-state is load-bearing here in a way it is not in a group tracker. An
-- alert that fires when the aura appears must not fire because the client stopped
-- answering, and an alert that fires when the aura is *missing* must not fire for
-- the same reason. Unknown is a third answer and both directions stand down on it.
--------------------------------------------------------------------------------

local issecretvalue = _G.issecretvalue
local issecrettable = _G.issecrettable

NBA.secretsExist = (issecretvalue ~= nil)

local function Plain(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end
NBA.Plain = Plain

local function PlainBool(v)
    if v == nil then return nil end
    if issecretvalue and issecretvalue(v) then return nil end
    return v and true or false
end
NBA.PlainBool = PlainBool

-- A secret table throws on #, ipairs and pairs, not just on its contents, so
-- anything about to be walked is checked first.
local function Walkable(t)
    if type(t) ~= "table" then return false end
    if issecrettable and issecrettable(t) then return false end
    if issecretvalue and issecretvalue(t) then return false end
    return true
end
NBA.Walkable = Walkable

-- Whether the client is currently withholding aura data. A mode, not a constant:
-- it turns on for combat, encounters, keystones and rated pvp and off again
-- afterwards, so nothing may cache the answer.
-- Read as "can this addon get a truthful answer about an aura right now", which is
-- what every caller actually wants to know before deciding whether to enumerate.
--
-- Combat is checked FIRST and on its own, ahead of asking the client anything. On
-- 12.1 aura reads are refused outright while an addon is tainted, and every addon is
-- tainted by definition - so in combat the answer is no, whatever C_Secrets says
-- about secrecy. Relying on ShouldAurasBeSecret alone would be trusting a related
-- but different question: one is about whether values are masked, the other about
-- whether the call is served at all. Measured in the open world, not just in
-- instances, so there is no "only in raids" exemption to lean on either.
function NBA.AurasAreSecret()
    if InCombatLockdown() then return true end
    if not C_Secrets then return false end
    local ok, secret = pcall(C_Secrets.ShouldAurasBeSecret)
    if not ok then return false end
    return secret and true or false
end

--------------------------------------------------------------------------------
-- Units
--
-- Short list on purpose. A proc is on you; the other three are here because
-- "the boss gained its damage buff" and "my focus got the shield" are the same
-- feature pointed somewhere else, and cost nothing to allow.
--------------------------------------------------------------------------------

NBA.UNITS = {
    { key = "player", label = "Me"     },
    { key = "target", label = "Target" },
    { key = "focus",  label = "Focus"  },
    { key = "pet",    label = "Pet"    },
}

function NBA.UnitLabel(key)
    for _, u in ipairs(NBA.UNITS) do
        if u.key == key then return u.label end
    end
    return key or "?"
end

NBA.SHOW_MODES = {
    { key = "text", label = "Text only"      },
    { key = "icon", label = "Icon only"      },
    { key = "both", label = "Icon and text"  },
}

NBA.LAYOUTS = {
    { key = "below", label = "Text below icon"   },
    { key = "above", label = "Text above icon"   },
    { key = "right", label = "Text right of icon" },
    { key = "left",  label = "Text left of icon"  },
}

NBA.TRIGGERS = {
    { key = "gain",    label = "When it comes up"    },
    { key = "loss",    label = "When it drops off"   },
    { key = "missing", label = "While it is missing" },
}

NBA.MODES = {
    { key = "flash", label = "Flash once"          },
    { key = "hold",  label = "Stay while it is up" },
}

NBA.OUTLINES = { "NONE", "OUTLINE", "THICKOUTLINE" }

NBA.ANCHORS = {
    "CENTER", "TOP", "BOTTOM", "LEFT", "RIGHT",
    "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT",
}

NBA.STRATAS = { "MEDIUM", "HIGH", "DIALOG" }

--------------------------------------------------------------------------------
-- The alert
--
-- Every setting lives on the alert. There is no global look to inherit from, for
-- the same reason nugsAuras has none: two alerts that should match are made to
-- match by copying one onto the other, which is a button rather than a whole layer
-- of settings that has to be explained.
--------------------------------------------------------------------------------

function NBA.NewAlertTable(name)
    return {
        name    = name or "New alert",
        enabled = true,

        -- What is watched
        spellID = nil,
        unit    = "player",
        specID  = 0,          -- 0 = every spec
        mineOnly = false,     -- only when the aura came from you or your pet
        minStacks = 0,        -- 0 or 1 = any; otherwise it must have at least this many

        -- When it fires
        trigger = "gain",     -- gain | loss | missing
        mode    = "flash",    -- flash | hold  (ignored by "missing", which holds)
        refire  = false,      -- fire again when the aura changes without dropping off
        hold    = 1.2,        -- flash: seconds at full alpha
        fadeIn  = 0.15,
        fadeOut = 0.45,
        pop     = true,       -- scale overshoot on appear
        rearm   = 0.4,        -- seconds after firing before the same edge fires again

        -- What is drawn
        show    = "both",     -- text | icon | both
        text    = "",         -- empty means "use the spell's name"
        layout  = "below",
        gap     = 4,

        -- Icon
        iconSize = 48,
        zoom     = true,      -- crop the stock icon border away
        swipe    = true,      -- cooldown swipe while the aura runs (hold only)
        border   = true,

        -- Text
        font        = "Friz Quadrata TT",
        fontSize    = 26,
        fontOutline = "OUTLINE",
        color       = { 1, 0.82, 0.2 },
        shadow      = true,
        uppercase   = false,

        -- Extras
        showStacks = true,
        alpha      = 1,
        scale      = 1,

        -- Where
        anchor  = "CENTER",
        x       = 0,
        y       = 180,
        strata  = "HIGH",

        -- Sound
        sound     = "",       -- empty means silent
        soundChan = "Master",

        -- Speech
        speak     = false,
        speakText = "",       -- empty means "say what the alert says"
    }
end

-- Ids are handed out rather than derived from the array position, because the
-- options window holds a selection across deletes and reorders and an index would
-- quietly point at a different alert afterwards.
function NBA.CreateAlert(name)
    local db = NBA.db
    local id = db.nextID or 1
    db.nextID = id + 1
    db.alerts[id] = NBA.NewAlertTable(name or ("Alert " .. id))
    db.order[#db.order + 1] = id
    return id, db.alerts[id]
end

function NBA.DeleteAlert(id)
    local db = NBA.db
    db.alerts[id] = nil
    for i = #db.order, 1, -1 do
        if db.order[i] == id then table.remove(db.order, i) end
    end
end

-- Moves within the alert's own spec group. The list is grouped by spec, so swapping
-- with the next entry in the raw order would look like nothing happening whenever that
-- entry belongs to a different group - or worse, would move an alert into a group it
-- has no business being in.
function NBA.MoveAlert(id, delta)
    local order  = NBA.db.order
    local alerts = NBA.db.alerts
    local moving = alerts[id]
    if not moving then return end

    local from
    for i, v in ipairs(order) do
        if v == id then from = i break end
    end
    if not from then return end

    local step = (delta > 0) and 1 or -1
    local i = from + step
    while i >= 1 and i <= #order do
        local other = alerts[order[i]]
        if other and (other.specID or 0) == (moving.specID or 0) then
            order[from], order[i] = order[i], order[from]
            return
        end
        i = i + step
    end
end

-- Copies the look and the behaviour but not the identity: what an alert watches,
-- what it says and where it sits are the things that make it that alert.
function NBA.CopyAlertLook(from, to)
    local skip = {
        name = true, spellID = true, text = true,
        x = true, y = true, anchor = true, specID = true, unit = true,
    }
    for k, v in pairs(from) do
        if not skip[k] then
            if type(v) == "table" then
                local t = {}
                for i, n in pairs(v) do t[i] = n end
                to[k] = t
            else
                to[k] = v
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Spec
--
-- An alert list is spec-specific in practice - the procs a Retribution Paladin
-- waits on are not the ones Holy waits on - but the alerts live in the account-wide
-- saved variables so a profile string can carry them. So each alert may pin itself
-- to one spec, and the rest of the time the pin is simply absent.
--
-- The getters moved namespace in 12.0 and the old globals still exist as
-- forwarders. Both are tried because which one is authoritative has changed once
-- already and is not worth being wrong about.
--------------------------------------------------------------------------------

function NBA.CurrentSpecID()
    local index
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        local ok, v = pcall(C_SpecializationInfo.GetSpecialization)
        if ok then index = v end
    end
    if index == nil and _G.GetSpecialization then
        local ok, v = pcall(_G.GetSpecialization)
        if ok then index = v end
    end
    if not index then return 0 end

    local id
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo then
        local ok, v = pcall(C_SpecializationInfo.GetSpecializationInfo, index)
        if ok then id = v end
    end
    if id == nil and _G.GetSpecializationInfo then
        local ok, v = pcall(_G.GetSpecializationInfo, index)
        if ok then id = v end
    end
    return tonumber(id) or 0
end

-- Name, icon and owning class for a spec id. The class is what lets the list say "this
-- one belongs to a character you are not playing" rather than showing a Paladin's
-- alerts to a Druid as though they were merely switched off.
function NBA.SpecInfo(specID)
    if not specID or specID == 0 then return "Any spec", nil, nil end

    local getter = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoByID)
                   or _G.GetSpecializationInfoByID
    if not getter then return ("spec " .. specID), nil, nil end

    -- pcall shifts every return along by one, so the discards line up with
    -- id, name, description, icon, role, classFile.
    local ok, _, name, _, icon, _, classFile = pcall(getter, specID)
    if not ok then return ("spec " .. specID), nil, nil end
    return name or ("spec " .. specID), icon, classFile
end

function NBA.SpecName(specID)
    local name = NBA.SpecInfo(specID)
    return name
end

function NBA.PlayerClass()
    local ok, _, classFile = pcall(UnitClass, "player")
    if not ok then return nil end
    return Plain(classFile)
end

-- Three states, because "not right now" and "not on this character" are different
-- things and only one of them is worth acting on.
--   "active"    applies to the spec you are in
--   "inactive"  yours, but a spec you are not currently in
--   "other"     belongs to another class entirely
function NBA.SpecStanding(specID)
    if not specID or specID == 0 then return "active" end
    if specID == NBA.CurrentSpecID() then return "active" end
    local _, _, classFile = NBA.SpecInfo(specID)
    local mine = NBA.PlayerClass()
    if classFile and mine and classFile ~= mine then return "other" end
    return "inactive"
end

function NBA.AlertAppliesHere(a)
    if not a.specID or a.specID == 0 then return true end
    return a.specID == NBA.CurrentSpecID()
end

--------------------------------------------------------------------------------
-- Media
--------------------------------------------------------------------------------

local STOCK_FONTS = {
    { name = "Friz Quadrata TT", path = "Fonts\\FRIZQT__.TTF" },
    { name = "Arial Narrow",     path = "Fonts\\ARIALN.TTF"   },
    { name = "Skurri",           path = "Fonts\\SKURRI.TTF"   },
    { name = "Morpheus",         path = "Fonts\\MORPHEUS.TTF" },
}

-- Stock list first, LibSharedMedia appended if some other addon happens to have
-- loaded it. Never depended on: there is no OptionalDeps line and no LibStub of
-- our own, so this is pure opportunism.
local function MediaList(stock, lsmKind)
    local list, seen = {}, {}
    for _, entry in ipairs(stock) do
        list[#list + 1] = entry
        seen[entry.name] = true
    end
    local LSM = _G.LibStub and _G.LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local ok, names = pcall(LSM.List, LSM, lsmKind)
        if ok and type(names) == "table" then
            for _, name in ipairs(names) do
                if not seen[name] then
                    local okPath, path = pcall(LSM.Fetch, LSM, lsmKind, name)
                    if okPath and path then
                        list[#list + 1] = { name = name, path = path }
                        seen[name] = true
                    end
                end
            end
        end
    end
    return list
end

function NBA.FontList() return MediaList(STOCK_FONTS, "font") end

function NBA.SoundList()
    -- No stock entries: the game's own sound files cannot be enumerated and a list
    -- of hard-coded paths would be a list of guesses. LibSharedMedia's sound table
    -- is the only honest source, and an empty list is a true statement about a
    -- client that does not have it.
    return MediaList({}, "sound")
end

function NBA.FontPath(name)
    for _, entry in ipairs(NBA.FontList()) do
        if entry.name == name then return entry.path end
    end
    return STOCK_FONTS[1].path
end

-- SetFont answers false rather than erroring on a file it cannot use, so the
-- return has to be checked as well as the call.
function NBA.ApplyFont(fs, a)
    local flags = (a.fontOutline ~= "NONE") and a.fontOutline or ""
    local ok, applied = pcall(fs.SetFont, fs, NBA.FontPath(a.font), a.fontSize, flags)
    if not ok or applied == false then
        fs:SetFontObject("GameFontNormalLarge")
    end
end

-- Resolves whatever is in the sound field: a LibSharedMedia name if one matches,
-- otherwise the string is treated as a path the player typed.
function NBA.SoundPath(value)
    if not value or value == "" then return nil end
    for _, entry in ipairs(NBA.SoundList()) do
        if entry.name == value then return entry.path end
    end
    return value
end

--------------------------------------------------------------------------------
-- Text to speech
--
-- Worth having as an alternative to a sound rather than a novelty: a fight is already
-- full of noises competing for the same attention, and a spoken word is the one cue
-- that does not have to be learned first. It also carries when the alert is off the
-- part of the screen you happen to be looking at, which is the failure mode every
-- visual alert has.
--
-- The voice, rate and volume are one setting for the whole addon rather than per
-- alert. Nobody wants a different voice per proc, and per-alert copies of three
-- settings is three more things to get wrong.
--------------------------------------------------------------------------------

function NBA.TtsVoices()
    if not (C_VoiceChat and C_VoiceChat.GetTtsVoices) then return {} end
    local ok, list = pcall(C_VoiceChat.GetTtsVoices)
    if not ok or type(list) ~= "table" then return {} end
    local out = {}
    for _, voice in ipairs(list) do
        if voice and voice.voiceID then
            out[#out + 1] = {
                name    = voice.name or ("voice " .. tostring(voice.voiceID)),
                voiceID = voice.voiceID,
            }
        end
    end
    return out
end

function NBA.TtsVoiceName(voiceID)
    if voiceID == nil then return nil end
    for _, voice in ipairs(NBA.TtsVoices()) do
        if voice.voiceID == voiceID then return voice.name end
    end
    return nil
end

-- The client ships Enum.VoiceTtsStatusCode and no destination enum at all, which is the
-- shape of an API that reports its failures through a return value rather than an
-- error. Discarding that return is why speech looked like it worked and made no sound:
-- the call succeeded, the *request* did not, and nothing anywhere said so.
local function TtsStatusName(code)
    if code == nil then return nil end
    if Enum and Enum.VoiceTtsStatusCode then
        for name, value in pairs(Enum.VoiceTtsStatusCode) do
            if value == code then return ("%s (%d)"):format(name, code) end
        end
    end
    return tostring(code)
end
NBA.TtsStatusName = TtsStatusName

local function TtsSucceeded(code)
    -- No return at all is the old shape and is treated as success; a returned code is
    -- only success when it says so.
    if code == nil then return true end
    if type(code) ~= "number" then return true end
    local success = Enum and Enum.VoiceTtsStatusCode and Enum.VoiceTtsStatusCode.Success
    return code == (success or 0)
end

-- Why speech would not be heard, or nil when nothing is in the way.
--
-- This exists because the failure it describes is invisible from every angle the addon
-- could see before: the call returns nothing, the game's own text to speech settings
-- report full volume, and the playback events fire START and FINISH exactly as they
-- would for a sentence you heard. Speech is played through the **voice chat** output,
-- so being deafened or having that volume at zero silences it while every reading
-- available says it worked.
--
-- Reported, never fixed. Those are voice chat settings with consequences well outside
-- this addon - quietly undeafening somebody so a proc can talk would be a worse bug
-- than the silence.
local function AskVoiceChat(name)
    if not (C_VoiceChat and C_VoiceChat[name]) then return nil end
    local ok, value = pcall(C_VoiceChat[name])
    if not ok then return nil end
    return value
end

function NBA.SpeechBlocked()
    if not (C_VoiceChat and C_VoiceChat.SpeakText) then
        return "this client has no text to speech"
    end
    if #NBA.TtsVoices() == 0 then
        return "no text to speech voices are installed on this computer"
    end
    if AskVoiceChat("IsDeafened") == true then
        return "you are deafened in voice chat, and speech is played through it"
    end
    local output = AskVoiceChat("GetOutputVolume")
    if type(output) == "number" and output <= 0 then
        return "the voice chat output volume is zero, and speech is played through it"
    end
    -- IsLoggedIn is deliberately NOT checked. It reads false on a client that speaks
    -- perfectly well, and it was briefly reported as the blocker here purely because it
    -- was the last false-looking thing left after the real fault - a misremembered
    -- argument list - had been ruled out everywhere except in this addon's own code.
    return nil
end

-- Returns true when something was actually said, plus the reason when it was not, so a
-- failure can be reported rather than swallowed.
function NBA.Speak(text)
    if not text or text == "" then return nil, "nothing to say" end
    if not (C_VoiceChat and C_VoiceChat.SpeakText) then
        return false, "this client has no C_VoiceChat.SpeakText"
    end

    local db = NBA.db
    local voiceID = db and db.ttsVoice
    if voiceID == nil then
        -- Not stored on first use: whichever voice the client lists first is a better
        -- default than refusing to speak, and saving it would freeze a choice the
        -- player has not made.
        local list = NBA.TtsVoices()
        voiceID = list[1] and list[1].voiceID
    end
    if voiceID == nil then
        return false, "no text to speech voices are installed"
    end

    -- SpeakText(voiceID, text, rate, volume). Four arguments, no destination - which is
    -- also why there is no destination enum on this client to look one up from.
    --
    -- This was wrong for six versions. A remembered five-argument signature with a
    -- destination in third place shifted everything along: the destination was read as
    -- the rate, the rate as the volume, and the real volume fell off the end. Speech
    -- rendered perfectly, at volume zero. Every symptom followed from that - playback
    -- events firing, no error, no status code, and nothing audible - and none of it
    -- was about voice chat at all.
    local ok, result = pcall(C_VoiceChat.SpeakText, voiceID, text,
                             (db and db.ttsRate) or 0, (db and db.ttsVolume) or 100)
    if not ok then return false, tostring(result) end
    if not TtsSucceeded(result) then return false, TtsStatusName(result) end

    -- Checked after speaking rather than before: the utterance really was sent, and
    -- saying so is the difference between "this addon is broken" and "turn your voice
    -- chat volume up".
    local blocked = NBA.SpeechBlocked()
    if blocked then return false, blocked end
    return true
end

-- Everything the speech path can be asked, printed. Which of these is wrong is not
-- something either of us can work out by reading the code, and a silent failure is
-- exactly the kind this addon is supposed to refuse to have.
function NBA.TtsReport()
    NBA.Print("text to speech:")

    if not C_VoiceChat then
        print("  |cffdd5555C_VoiceChat does not exist on this client.|r")
        return
    end
    print(("  SpeakText %s    GetTtsVoices %s")
          :format(C_VoiceChat.SpeakText and "|cff55dd55yes|r" or "|cffdd5555no|r",
                  C_VoiceChat.GetTtsVoices and "|cff55dd55yes|r" or "|cffdd5555no|r"))

    if C_VoiceChat.GetTtsVoices then
        local ok, list = pcall(C_VoiceChat.GetTtsVoices)
        if not ok then
            print("  |cffdd5555GetTtsVoices errored:|r " .. tostring(list))
        elseif type(list) ~= "table" then
            print("  |cffdd5555GetTtsVoices returned " .. type(list) .. "|r")
        else
            print(("  voices: %d"):format(#list))
            for index, voice in ipairs(list) do
                print(("    [%d] id=%s  %s"):format(index, tostring(voice.voiceID),
                                                    tostring(voice.name)))
            end
        end
    end

    -- The verdict first. Everything below it is the working out.
    local blocked = NBA.SpeechBlocked()
    print("  verdict: " .. (blocked and ("|cffdd5555" .. blocked .. "|r")
                                     or "|cff55dd55nothing is in the way|r"))

    local db = NBA.db
    print(("  chosen voice %s   speed %s   volume %s")
          :format(tostring(db and db.ttsVoice), tostring(db and db.ttsRate),
                  tostring(db and db.ttsVolume)))

    -- Only the parts of the voice chat state that can actually silence speech. The
    -- rest of that namespace was dumped here while the cause of a silent feature was
    -- being hunted; the cause turned out to be a wrong argument list in this addon,
    -- and a shipped diagnostic should answer the question rather than record the hunt.
    for _, key in ipairs({ "IsEnabled", "IsDeafened", "GetOutputVolume" }) do
        if C_VoiceChat[key] then
            local ok, value = pcall(C_VoiceChat[key])
            print(("  %s = %s"):format(key, ok and tostring(value) or "?"))
        end
    end


    -- Called directly rather than through Speak, so the raw return is visible. "No
    -- return at all" and "returned Success" are different facts and the wrapper was
    -- flattening them into one cheerful message.
    local voiceID = db and db.ttsVoice
    if voiceID == nil then
        local list = NBA.TtsVoices()
        voiceID = list[1] and list[1].voiceID
    end
    if voiceID ~= nil then
        local ok, raw = pcall(C_VoiceChat.SpeakText, voiceID, "Text to speech is working",
                              (db and db.ttsRate) or 0, (db and db.ttsVolume) or 100)
        if not ok then
            print("  speak attempt: |cffdd5555error|r " .. tostring(raw))
        else
            print("  speak attempt returned: "
                  .. (raw == nil and "|cffe0b040nothing at all|r"
                                 or ("|cff55dd55" .. tostring(TtsStatusName(raw)) .. "|r")))
        end
    end
end

-- PlaySoundFile returns nothing at all for a file that is not there, and a handle
-- for one that is. That is the only way to tell a player their typed path is wrong,
-- because there is no directory listing and a custom .ogg dropped into the addon
-- folder never announces itself. Returns true when the file actually played.
function NBA.PlayAlertSound(value, channel)
    local path = NBA.SoundPath(value)
    if not path then return nil end
    local ok, willPlay = pcall(PlaySoundFile, path, channel or "Master")
    if not ok then return false end
    return willPlay and true or false
end

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

NBA.defaults = {
    locked        = true,
    minimapHidden = false,
    minimapAngle  = 200,
    closeInCombat = true,
    -- On by default: the whole point is that somebody who does not know ids exist
    -- finds one anyway, and a setting they have to discover first cannot do that.
    tooltipIDs    = true,
    ttsVoice      = nil,      -- nil means "whichever the client lists first"
    ttsRate       = 0,        -- -10 slow .. 10 fast
    ttsVolume     = 100,
    -- The Cooldown Manager has to stay visible to keep feeding the bridge in
    -- Watch.lua. This makes it visible and invisible at the same time, which is the
    -- only way to have the bridge without the bar.
    fadeCooldownManager = false,
    alerts        = {},
    order         = {},
    nextID        = 1,
    seeded        = false,
    -- Which spec groups are folded up in the list. Purely how the window looks, so it
    -- never leaves in a profile string.
    collapsed     = {},
}

NBA.charDefaults = {
    -- spellID -> { name, icon } for auras this character has actually had on it, so
    -- the picker has something to offer in a city. Machine-written, per character
    -- and class-specific, so it never leaves in a profile string.
    catalog = {},
}

local function CopyTable(v)
    local t = {}
    for i, n in pairs(v) do
        t[i] = (type(n) == "table") and CopyTable(n) or n
    end
    return t
end
NBA.CopyTable = CopyTable

local function ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            target[k] = (type(v) == "table") and CopyTable(v) or v
        end
    end
end

-- Alerts get the same treatment individually, so an alert saved by an older
-- version picks up any field added since without a migration step.
local function ApplyAlertDefaults(a)
    local defaults = NBA.NewAlertTable()
    ApplyDefaults(a, defaults)

    -- Repair, not migration. 0.2.1 and earlier had a choice button that could write a
    -- whole media entry into `font` instead of the entry's name, and a table sitting
    -- there makes the settings window throw on every refresh. Anything that is not the
    -- shape it should be goes back to the default rather than being carried forward.
    for _, key in ipairs({ "font", "fontOutline", "anchor", "strata", "show", "layout",
                           "trigger", "mode", "unit", "text", "name", "sound", "soundChan",
                           "speakText" }) do
        if type(a[key]) ~= type(defaults[key]) then a[key] = defaults[key] end
    end
    if type(a.color) ~= "table" or type(a.color[1]) ~= "number" then
        a.color = CopyTable(defaults.color)
    end
end

-- The suite is handed the defaults an alert *actually* starts life with. Handing
-- over defaults whose collections are empty makes every key look changed and
-- bloats every exported profile.
function NBA.EffectiveDefaults()
    return CopyTable(NBA.defaults)
end

local function SeedFirstAlert()
    -- A blank screen on first launch reads as broken. One alert, unconfigured but
    -- placed and shaped, gives the options window something to explain itself with.
    local _, a = NBA.CreateAlert("My first alert")
    a.text = "PROC"
    NBA.db.seeded = true
end

local function InitDB()
    nugsBuffAlertDB     = nugsBuffAlertDB     or {}
    nugsBuffAlertCharDB = nugsBuffAlertCharDB or {}

    NBA.db   = nugsBuffAlertDB
    NBA.char = nugsBuffAlertCharDB

    ApplyDefaults(NBA.db, NBA.defaults)
    ApplyDefaults(NBA.char, NBA.charDefaults)

    for _, a in pairs(NBA.db.alerts) do
        ApplyAlertDefaults(a)
    end

    -- An id present in alerts but missing from order would never be drawn and could
    -- never be selected, which looks exactly like a lost alert.
    local inOrder = {}
    for _, id in ipairs(NBA.db.order) do inOrder[id] = true end
    for id in pairs(NBA.db.alerts) do
        if not inOrder[id] then NBA.db.order[#NBA.db.order + 1] = id end
    end
    for i = #NBA.db.order, 1, -1 do
        if not NBA.db.alerts[NBA.db.order[i]] then table.remove(NBA.db.order, i) end
    end

    if not NBA.db.seeded and next(NBA.db.alerts) == nil then
        SeedFirstAlert()
    end
end

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------

local function HandleSlash(msg)
    local cmd, rest = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")

    if cmd == "" or cmd == "config" or cmd == "options" then
        NBA.ToggleOptions()

    elseif cmd == "unlock" then
        NBA.Display:ToggleLock(false)

    elseif cmd == "lock" then
        NBA.Display:ToggleLock(true)

    elseif cmd == "test" then
        NBA.Display:TestAll()
        NBA.Print("firing every alert that applies to this spec.")

    elseif cmd == "scan" then
        -- The one thing worth having outside the options window: it answers
        -- "what is the id of the thing currently on me", which is the question
        -- every alert starts with.
        local unit = (rest ~= "" and rest) or "player"
        local list, skipped, err = NBA.ScanAuras(unit)
        if not list then
            NBA.Print(err or "nothing to scan there.")
        else
            NBA.Print(("auras readable on %s right now:"):format(unit))
            for _, e in ipairs(list) do
                print(("  |cff6fc2ff%d|r  %s%s"):format(e.spellID, e.name,
                      e.harmful and "  |cff999999(debuff)|r" or ""))
            end
            if skipped > 0 then
                NBA.Print(("%d more were on the unit but could not be read - try again out of combat.")
                          :format(skipped))
            end
        end

    elseif cmd == "bridge" then
        NBA.BridgeReport()

    elseif cmd == "stacks" then
        NBA.StackProbe()

    elseif cmd == "cdm" then
        NBA.CooldownDump(rest)

    elseif cmd == "spell" then
        NBA.SpellReport(rest)

    elseif cmd == "tts" then
        NBA.TtsReport()

    elseif cmd == "debug" then
        NBA.debug = not NBA.debug
        NBA.Print(NBA.debug
            and "printing every change of state, with how long after the aura event it "
                .. "arrived. Run it again to stop."
            or "quiet again.")

    elseif cmd == "help" then
        NBA.Print("commands:")
        print("  |cff6fc2ff/nba|r - open the settings")
        print("  |cff6fc2ff/nba unlock|r / |cff6fc2ff/nba lock|r - move the alerts around")
        print("  |cff6fc2ff/nba test|r - fire every alert once")
        print("  |cff6fc2ff/nba scan [unit]|r - list the aura ids readable on a unit")
        print("  |cff6fc2ff/nba debug|r - print every state change and how late it was")
        print("  |cff6fc2ff/nba bridge|r - what the Cooldown Manager bridge can see right now")
        print("  |cff6fc2ff/nba stacks|r - whether a buff's stack count can be read or only shown")
        print("  |cff6fc2ff/nba cdm [name]|r - every id the Cooldown Manager holds for a spell")
        print("  |cff6fc2ff/nba spell <id>|r - whether one spell can be tracked, and how")
        print("  |cff6fc2ff/nba tts|r - why text to speech is or is not working")

    else
        NBA.Print("unknown command. Try |cff6fc2ff/nba help|r.")
    end
end

SLASH_NUGSBUFFALERT1 = "/nba"
SLASH_NUGSBUFFALERT2 = "/nugsbuffalert"
SlashCmdList["NUGSBUFFALERT"] = HandleSlash

--------------------------------------------------------------------------------
-- Spell ids in tooltips
--
-- Every alert starts with an id, and the id is the one thing the game shows you
-- nowhere. Putting it on the tooltip means hovering a buff on your own frame, or a
-- spell in your book, answers the question that otherwise needs a website - and a
-- website is exactly where the wrong id comes from, because the number printed for an
-- ability is usually not the number its buff carries.
--
-- Uses TooltipDataProcessor rather than hooking OnTooltipSetSpell, which stopped
-- being called in 10.0. The aura case is worth having as much as the spell case: an
-- aura tooltip is the only place the *buff's* own id can be seen.
--------------------------------------------------------------------------------

local function AddTooltipID(tooltip, data)
    if not (NBA.db and NBA.db.tooltipIDs) then return end
    if not (tooltip and tooltip.AddDoubleLine and data) then return end
    -- Blizzard reuses tooltips for embedded panels; only the real ones get a line.
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end

    if data.id == nil then return end

    local id = Plain(data.id)
    if id == nil then
        -- The id exists but is being withheld, which is worth saying: a blank tooltip
        -- would read as "this aura has no id" rather than "not while you are fighting".
        tooltip:AddDoubleLine("|cff6fc2ffnba|r", "|cff888888id hidden in combat|r")
    else
        tooltip:AddDoubleLine("|cff6fc2ffnba|r", "|cffffffff" .. id .. "|r")
    end
    tooltip:Show()
end

local function InitTooltips()
    if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
            and Enum and Enum.TooltipDataType) then
        return
    end
    for _, kind in ipairs({ "Spell", "UnitAura", "Item" }) do
        local dataType = Enum.TooltipDataType[kind]
        if dataType then
            pcall(TooltipDataProcessor.AddTooltipPostCall, dataType, AddTooltipID)
        end
    end
end

--------------------------------------------------------------------------------
-- nugsSuite
--
-- One entry written into a plain global table. Not a call into the suite: a global
-- is free of load order, so whichever side loads first the table is already there
-- and neither addon has to exist for the other to work. Registering is optional
-- and only buys settings export and minimap consolidation.
--------------------------------------------------------------------------------

local function RegisterWithSuite()
    _G.nugsSuiteRegistry = _G.nugsSuiteRegistry or {}
    _G.nugsSuiteRegistry[ADDON_NAME] = {
        title      = "nugsBuffAlert",
        version    = NBA.version,
        icon       = "Interface\\AddOns\\nugsBuffAlert\\icon",
        slash      = "/nba",
        Open       = function() NBA.ToggleOptions() end,
        SetMinimap = function(shown)
            NBA.db.minimapHidden = not shown
            NBA.SetMinimapShown(shown)
        end,
        GetDB      = function() return nugsBuffAlertDB, NBA.EffectiveDefaults() end,
        GetCharDB  = function() return nugsBuffAlertCharDB, NBA.charDefaults end,
        -- Where this button sits is nobody else's business, and the seed flag would
        -- hand an importer a first run they have already had.
        exclude     = { minimapAngle = true, seeded = true, collapsed = true },
        excludeChar = { catalog = true },
    }
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()
        RegisterWithSuite()

    elseif event == "PLAYER_LOGIN" then
        NBA.InitMinimap()
        NBA.Display:Init()
        NBA.Watch:Init()
        InitTooltips()
        if NBA.InitOptions then NBA.InitOptions() end
    end
end)
