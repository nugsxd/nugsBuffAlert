# nugsBuffAlert

Tells you the moment a buff or proc comes up — as a line of text, an icon, or both,
wherever you put it on screen. Retail World of Warcraft (The War Within / Midnight).

One alert is one spell. It watches a single aura on a single unit and, when that aura
appears, says so where you told it to. No filters, no groups, no rows that grow and
shrink: an alert has a position and a look, and that is all.

## Features

- Text, an icon, or both, with the words, font, size, outline, colour, shadow and
  case set per alert.
- Flash or hold: a flash fades in, sits and leaves on its own; a hold stays for as
  long as the buff is up, with an optional countdown swipe and stack count.
- Three triggers — when a buff comes up, when it drops off, and the whole time it is
  missing.
- An optional stack threshold, so an alert can wait until a buff reaches the count
  you actually care about.
- "Fire again when it changes", for a buff that never fully drops off — one you spend
  stacks of without spending all of them.
- A sound per alert, or have it read out through the game's own text to speech.
- **Every alert is marked with whether it will work in a raid**, in words, before you
  rely on it.
- Spell picker driven by Blizzard's own tracked list for your spec and by the auras
  actually on you, plus spell ids on tooltips.
- Alerts are shared across characters, can be pinned to a spec, and the list is
  grouped by spec and folds up.
- Its own anchor per alert; unlock, drag, lock.
- LibSharedMedia fonts and sounds when it is loaded. Part of the nugs suite, and
  standalone without it.

## Usage

`/nba` opens the options window.

| Command | Effect |
| --- | --- |
| `/nba` | open/close the options window |
| `/nba unlock` / `/nba lock` | move the alerts around |
| `/nba test` | fire every alert once |
| `/nba scan [unit]` | list the aura ids readable on a unit right now |
| `/nba spell <id>` | whether one spell can be tracked, and how |
| `/nba bridge` | what the Cooldown Manager bridge can currently see |
| `/nba stacks` | whether a buff's stack count can be read or only shown |
| `/nba tts` | why text to speech is or is not being heard |
| `/nba debug` | print every change of state and how late it arrived |

## What it can and cannot see

Since Midnight, the game hides aura data from addons during combat, encounters,
keystones and rated PvP — and whether *your* spell is hidden depends on the spell. An
addon that pretends otherwise works perfectly at a target dummy and silently shows
nothing on a pull. Most of the design here is about not doing that.

Auras are read three ways, in order of how much they can be trusted:

1. **`C_UnitAuras.GetUnitAuraBySpellID`** — exact, and the only aura call that
   survives the 12.1 overhaul. It answers for spells Blizzard has declassified.
2. **Blizzard's Cooldown Manager.** It is not an addon, so it is allowed to read auras
   this is not; its buff viewers carry a plain spell id, aura instance id and unit on
   their item frames, which recovers exactly the mapping the secrecy system withholds
   without calling a single restricted API. This is the path that covers procs.
3. **A full enumeration**, which is complete but only available outside combat, and is
   what the spell picker is built on.

Which one answered is recorded and shown, because "why is this not firing in raids"
is otherwise unanswerable.

Two consequences worth stating plainly:

- **A spell has to be *turned on* in the Cooldown Manager, not merely known to it.**
  One it is not showing never reaches a viewer frame, so the bridge cannot see it. An
  alert in that state is marked *add it to the Cooldown Manager* rather than being
  promised as readable, and the mark corrects itself the moment the spell comes
  through.
- **Nothing fires on a guess.** "Is this buff up" has three answers, not two — yes, no,
  and *not allowed to know* — and every trigger stands down on the third. A
  missing-buff warning that treated "cannot tell" as "not up" would sit on your screen
  for an entire fight.

## Known issues

**A stack threshold only works where the count is readable.** A spell reached only
through the Cooldown Manager gives an aura to point at but nothing readable about it,
so a number in that box can never be met during a fight and the alert stays quiet. The
options window says so when that combination is set; `/nba stacks` says which case a
given buff is in.

**Two spells that share a name, or share a Cooldown Manager entry's spell id, cannot
be told apart** and are refused rather than guessed at. Pick the buff off yourself out
of combat to get the aura's own id, which is unique even when the ability's is not.

**Speech is played through the voice chat output**, so being deafened or having that
volume at zero silences it while everything else reports success. That state is
detected and named rather than left to be discovered.

## Saved variables

Alerts are account-wide (`nugsBuffAlertDB`) so they follow you between characters, with
an optional per-alert spec pin. The catalogue of auras this character has seen, which
only exists to make the spell picker useful, is per character
(`nugsBuffAlertCharDB`) and never travels in a shared profile.

## 12.1

The aura overhaul in *Curse of Ula'tek* removes enumeration — `GetUnitAuras` and
instance-id iteration return a secret vector that cannot be counted or walked — and
explicitly exempts the spell-id lookup. Of the three paths above only the third is
affected, and it is the one that already only runs outside combat. Nothing that fires
an alert during a fight goes through it.

## Install

Copy the `nugsBuffAlert` folder into
`World of Warcraft\_retail_\Interface\AddOns\`, then restart the game.

## Checks

Every push runs static analysis over the Lua in this repo, and the same checks run
locally before a release. To run them yourself:

```
npm install
npm test
```

Each check exists because of a bug that got as far as a build, and each script says
which one at the top of the file:

| | |
|---|---|
| `check.js` | every file parses |
| `fwdref.js` | a name used above the `local` that declares it - which silently reads a nil global |
| `selfref.js` | `local x = f(function() ... x ... end)`, where the closure captures nil rather than `x` |
| `wowcheck.js` | taint, secret values, and the other WoW-specific ways Lua that looks fine still breaks |
| `globalwrite.js` | assignments that never declared a local - advisory, since SavedVariables have to be globals |

Two more run before release but are not in this repo, because they need a copy of
Ketho's WoW API annotations: a check that no call has been moved or removed in the
current patch, and a full `lua-language-server` pass.

## License

Copyright (c) 2026 nugs. All Rights Reserved. See [LICENSE](LICENSE).
