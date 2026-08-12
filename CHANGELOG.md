# Changelog

## 1.0.5

- Now built for patch 12.1 only. 12.1 is live, and listing the previous patch
  alongside it claimed support for a client nobody is on any more.

## 1.0.4

**Fixed: a stream of Lua errors during combat, and alerts dying with them.**

On 12.1 an aura instance id that arrives by way of the Cooldown Manager is a **secret
number**. A secret can be passed along and handed to a widget, but it cannot be
compared, concatenated, formatted, or used as a table key — each of those is a hard
error rather than a false or a blank. This addon did all four.

One fight produced 282 errors from a single line.

- **Re-application detection** compared the current instance id against the previous
  one. It now compares plain copies, and when either is secret the answer is "cannot
  tell" — which skips the re-fire. A missed re-fire, never a wrong one.
- **The refire trigger** used the instance id as a table key, in both directions.
  Secret ids are no longer recorded, so that tick is missed rather than the whole
  aura handler dying.
- **The duration binding** compared ids to avoid rebinding what was already bound.
  Now compares plain copies; a secret id skips a rebind that would have re-shown the
  same aura anyway.
- **The debug line and both diagnostics** concatenated the id straight into text.
  They print `#secret` instead — a diagnostic being the thing that crashes is the
  worst possible failure.

## 1.0.3 (not released separately - folded into 1.0.4)

**Patch 12.1 housekeeping. Alerts were not broken by 12.1 — this closes one real gap
and corrects the notes around it.**

12.1 refuses to **enumerate** auras for an addon in combat. Looking up **one known
spell id** is still served, still in combat, and still comes back as a plain
arithmetic-safe value. This addon's primary path is the by-id lookup, so alerts
carried on working through fights.

- **Enumeration is now blocked in combat** at the shared guard rather than at each
  call site. That path was already out-of-combat only in practice; now it is enforced
  in one place, so a future caller cannot reintroduce it by accident.
- Corrected the notes describing which reads survive 12.1. An earlier draft of this
  release had the distinction backwards and disabled the by-id lookup during combat —
  that would have discarded the most accurate source available and fallen through to
  the Cooldown Manager, which only knows the spells you personally track. It was
  caught before release and never shipped.

Worth knowing, and now recorded in the code: the Cooldown Manager carries **no stack
count**. A tracked-buff entry has no `applications` field and its `charges` is a
true/false, not a number. Anything counting stacks has to use the by-id lookup.

## 1.0.2

- **Alerts can no longer be placed during combat**, which matches the rule that a pull
  locks them in the first place. Unlocking deliberately puts every alert that applies
  to your spec on screen at once so they can be arranged together - mid-fight that is
  a screen full of procs that are not actually happening. It is now refused with a line
  of chat rather than half-entered.

## 1.0.1

- **Fixed: "action blocked" errors during combat.** `SetPropagateKeyboardInput` - used
  so that Escape closes a dropdown or the placement bar rather than the window behind
  it - is protected during a fight. Calling it then raises ADDON_ACTION_BLOCKED naming
  this addon, and unlike a Lua error it cannot be caught: it taints the addon for the
  rest of the session. 3 call sites now skip themselves in combat.
- The worst of them was the key handler: it guarded the Escape branch but not the
  branch every *other* key took, so with a list open in combat any keypress would have
  thrown it - movement keys included.
- This addon already had the guard; the remaining direct calls now go through it too.

## 1.0.0

First public release.

- **Tells you the moment a buff or proc comes up** - as text, an icon, or both,
  wherever you put it on screen. One alert is one spell: a position and a look, with no
  filters or groups to learn first.
- Flash or hold, three triggers (gained, dropped, missing), an optional stack
  threshold, and a re-fire for buffs that never actually drop off.
- A sound or a spoken cue per alert, with the voice shared across all of them.
- **Every alert says whether it will work in a raid**, before you rely on it. The game
  hides aura data during combat and whether your spell is hidden depends on the spell,
  so each one is marked and the reason is spelled out in words. Nothing fires on a
  guess - "cannot tell" is a third answer and every trigger stands down on it.
- Spell picker driven by Blizzard's own tracked list for your spec and by what is
  actually on you, plus spell ids on tooltips, because building an alert on the wrong
  id is the most common way to end up with a proc that never fires.
- Alerts are shared across characters, can be pinned to a spec, and the list is grouped
  by spec and folds up.
- `/nba`, a minimap button, LibSharedMedia support, and nugsSuite registration for
  profile sharing.

## 0.12.0

- **Speech works.** `SpeakText` takes four arguments - voice, text, rate, volume - and
  this addon had been calling it with five, having invented a destination parameter in
  third place. Everything shifted along: the destination was read as the rate, the rate
  as the volume, and the real volume fell off the end. Speech rendered perfectly, at
  volume zero.
- Every symptom followed from that one mistake, and every one of them pointed away from
  it: playback events firing start and finish, no error, no status code, the game's own
  speech settings reporting full volume. Three versions were spent diagnosing the
  client. Two addons already installed on this machine had the correct call in them the
  whole time.
- Removed the destination setting and the `/nba tts <n>` prober, which existed to search
  for a parameter that does not exist. `/nba tts` keeps the parts that are still worth
  having: the voices, the voice chat state, and a verdict.
- "The voice chat client is not logged in" is no longer reported as a blocker. It reads
  false on a client that speaks perfectly well; it was only ever the last false-looking
  thing left after the real fault had been ruled out everywhere except in this addon's
  own code.

## 0.11.3

- **Speech says when it will not be heard.** It turns out speech is played through the
  *voice chat* output, so being deafened or having that volume at zero silences it - and
  that failure is invisible from every angle the addon could previously see. The call
  returns nothing, the game's own text to speech settings report full volume, and the
  playback events fire started and finished exactly as they would for a sentence you
  heard. Every reading said it worked.
- That state is now stated: on the Sound tab where speech is switched on, in the reply
  when a test says nothing, and as a one-line verdict at the top of `/nba tts`.
- Reported, never fixed. Undeafening somebody's voice chat so a proc can talk would be a
  worse bug than the silence.
- `/nba tts` no longer dumps every speech enum in the client. That was for finding this
  and it has been found.

## 0.11.0

- **A Sound tab.** Everything you can hear is on it: the sound and the words for the
  selected alert, and the voice, speed and volume that apply to all of them. Setting up
  one alert's voice used to mean a trip to a tab about where things sit on screen.
- Laid out as one wide column. These controls are text boxes, and a path or a sentence
  in a 274 pixel box with a scroll bar beside it is a box you cannot read what you typed
  into.
- **Speech failures are reported.** This client ships `Enum.VoiceTtsStatusCode` and no
  destination enum at all, which is the shape of an API that reports failure through a
  return value - and that return was being discarded. The call succeeded, the request
  did not, and nothing said so.
- `/nba tts <n>` tries one destination, names the status code it got back, and remembers
  the value if it worked. There is no constant on this client to look it up from, so it
  has to be found by ear.

## 0.10.1

- **`/nba tts`** prints everything the speech path can be asked: whether the API exists,
  every voice the client lists, the playback enum, the chosen settings, and the actual
  error from an attempt to speak.
- Speech failures now say why. They were being swallowed into a single "no voices"
  message that was a guess at the cause rather than the cause.

## 0.10.0

- **The alert list is grouped by spec, and the groups fold up.** A list of alerts is
  spec-specific in practice and a flat one stops being readable at about a dozen
  entries. Which groups you have folded is remembered, and never travels in a profile
  string - it is how your window looks, not what your alerts do.
- Groups are ordered: Any spec, the spec you are in, the rest of your class, then other
  classes. Everything that can fire today is at the top, everything belonging to a
  character you are not playing is at the bottom.
- **Alerts pinned to another class's spec are dimmed rather than hidden.** They are not
  broken and not switched off - they simply cannot fire here - and hiding them would
  make an imported profile look like it had lost entries.
- Moving an alert up or down now moves it within its own group. Swapping with whatever
  came next in the raw order would look like nothing happening whenever that entry sat
  in a different group.

## 0.9.1

- **Removed "time remaining".** On a flash it is gone before it can be read, and on an
  alert that holds the sweep already says the same thing in a shape you can take in
  without reading. The duration binding it needed goes with it.

## 0.9.0

- **Alerts can speak.** Tick "Say it out loud" and the alert is read through the game's
  own text to speech, with the words set per alert and the voice, speed and volume set
  once for all of them. Worth having over another sound: a fight is already full of
  noises competing for the same attention, a spoken word does not have to be learned
  first, and it carries when the alert is somewhere you are not looking.
- Picking a voice says its own name in it, because a list of voice names tells you
  nothing about how they sound.
- **The spell id toggle is in the bottom corner of the window**, not only inside a tab.
  It is the setting that helps somebody who has not worked out yet that spells have
  ids, and one like that is no use two clicks inside a tab they have no reason to open.
- **The title bar matches the rest of the suite.** Every other nugs addon puts its
  version in the blue tail; this one had a tagline there.

## 0.8.4

- **An alert works whether you picked the ability's id or the buff's.** A Cooldown
  Manager entry is a family - the ability, its talent override, and the auras it applies
  - and which member you happen to hold decided where you could be answered: the bridge
  accepts any of them, while a scan of what is on you only ever holds the aura's, so an
  alert built from the Cooldown Manager's list worked in combat and failed the moment
  the fight ended. The whole family is now tried.
- Final Hour is the case that showed it up: its Cooldown Manager entry carries an aura
  called Voidfall, so neither the id nor the name of one leads to the other.

## 0.8.3

- **An id shared by two Cooldown Manager entries is now refused everywhere.** It was
  already refused where the sharing could be seen, but only one of two sibling buffs is
  ever up at a time - so the live bridge saw a single frame claiming the shared id,
  called it unambiguous, and answered with whichever buff happened to be up. The
  Cooldown Manager's catalogue knows better and is now what decides, exactly as it
  already did for names.
- **`/nba cdm` searches every id an entry carries**, by name and by number, not just the
  ability's name. An entry named after one spell can carry the buff you are hunting as a
  linked id, so filtering on the ability name alone hid precisely the entry you were
  looking for.

## 0.8.2

- `/nba cdm` marks each entry **offered** or **not offered**, and prints how many
  entries the Cooldown Manager reports either way. The call that lists them takes an
  undocumented second argument this addon has always passed as `false`; if the two
  answers differ, "the Cooldown Manager tracks this" has been claimed for spells that
  cannot actually be chosen, and telling somebody to go and enable one of those is a
  wild goose chase.

## 0.8.1

- **`/nba spell <id>`** answers whether one spell can be tracked and how, without
  having to build an alert to find out. Being absent from the Cooldown Manager is not
  the same as being untrackable - the bridge is one of three paths, and a spell the
  game has declassified reads directly in a raid with no Cooldown Manager involved at
  all.

## 0.8.0

- **Spell ids on tooltips**, on by default and switchable on the Place tab. Every alert
  starts with an id and the game shows it nowhere, so hovering a buff on your own frame
  now answers the question that otherwise needs a website - and a website is exactly
  where the wrong id comes from, since the number printed for an ability is usually not
  the number its buff carries.
- Covers spell, aura and item tooltips. An aura's id is withheld during a fight, and
  the line says that rather than disappearing, so a missing id never reads as "this
  buff has no id".

## 0.7.3

- **Says when a stack threshold cannot work for the buff it is set on.** A spell reached
  only through the Cooldown Manager gives an aura to point at but nothing readable about
  it, so a number in that box can never be met during a fight and the alert correctly -
  and silently - stays quiet. That case now warns on the Alert tab, with the fix: clear
  the box. The count can still be *shown* on the alert, because displaying a number does
  not require being allowed to read it.

## 0.7.2

- **Two alerts on two spells that share a name no longer land on the same aura.**
  Whether a name is ambiguous was being judged one source at a time, and only one
  Voidfall is ever up at once - so a scan of what is on you sees a single owner for
  the name, calls it unambiguous, and then answers a lookup for the *other* Voidfall
  with the aura it happened to find. Two ids, one instance, both alerts firing for
  either buff and neither firing in a fight.
- A name is now refused everywhere if it means more than one thing anywhere. The
  Cooldown Manager's catalogue is what decides, because it lists every entry for the
  spec at once and therefore sees both spells whether or not either is currently up.

## 0.7.1

- **Says so at login when an alert is watching an id that cannot be told apart from
  another spell.** That state is silently broken in a way that looks like every other
  kind of broken - nothing fires in combat, and out of combat it fires for the wrong
  buff, because the name fallback finds whichever aura is up. It cannot be repaired
  automatically, since only you know which of the two spells you meant, so it is now
  said out loud rather than left to be rediscovered.

## 0.7.0

- **Two Cooldown Manager entries can report the same spell id.** Voidfall does: two
  entries both calling themselves 1253304, differing only in the spell each links to,
  with the actual auras living on those linked ids. The addon wrote both into one slot,
  so the second silently replaced the first - and because the picker listed entries by
  that shared id, the two collapsed into a single row and the second buff could not be
  chosen at all. Ids are now checked for collisions exactly as names already were.
- **The picker offers the id that identifies each entry**, which for a spell like this
  is the linked id - and that is also the id the aura genuinely uses. Listing the
  ability id was wrong twice over: entries could share one, and it is frequently not an
  aura at all, so an alert built on it watched for something that never appears.
- A spell that cannot be told apart from another, by id or by name, is marked and says
  what to do: put the buff on yourself out of combat and pick it from the "On a unit
  right now" source, which gives the aura's own id.
- `/nba cdm` builds the bridge before printing, so its served column means the same
  thing on every line rather than reporting the first entries as unserved for being
  early.

## 0.6.2

- **`/nba cdm [name]`** prints every id the Cooldown Manager holds for a spell - the
  ability, a talent's override, its linked spells, and whether each has actually
  reached this addon. When two spells share a name, or a buff carries an id nothing
  else mentions, this is the only place the shape of the problem is visible.

## 0.6.1

- **The stack threshold is a box you type in.** Caps run past fifty, and a slider wide
  enough for those puts the useful low numbers a few pixels apart.
- **Two spells sharing a name no longer collide into one alert.** Matching falls back
  to a spell's name when its id does not match, which is what lets an aura id find the
  ability id the Cooldown Manager reports - but where two different spells share one
  name, that fallback handed both alerts the same aura. One would fire twice and the
  other never at all, which looks like anything except a naming problem. Ambiguous
  names are now detected and refused, so matching falls back to the exact id only.
- Such a spell is marked **another spell shares this name** in red, with what to do
  about it: pick the buff off yourself out of combat, using the picker's "On a unit
  right now" source, to get the id the aura really uses rather than the one the
  Cooldown Manager reports. `/nba bridge` flags it too.

## 0.6.0

- **Only fire at a number of stacks - properly this time.** Set the count you care
  about and anything below it counts as the buff not being up at all, so the alert
  fires when it reaches the number and drops when it falls back under. Collapsing Star
  at maximum, without a flash for every stack along the way.
- I removed this feature two versions ago on the reasoning that a stack count could not
  be compared under the secrecy rules. Measured against Collapsing Star in combat, that
  was wrong - the count came back plain. The rule is real but it is per spell rather
  than universal, and reasoning from the rule instead of asking the client cost this
  feature a version.
- Where a count genuinely cannot be read the alert stays quiet rather than guessing,
  and `/nba stacks` says which case a given buff is in.
- The threshold also has a second way to answer: the display count is empty below the
  minimum asked for, so asking with the minimum set to the number you want is itself
  the test, with no counts compared at all. That may work for spells the plain count
  does not.

## 0.5.1

- **`/nba stacks`** reports whether a buff's stack count can be reasoned about or only
  shown, for every alert currently up. It goes through the addon's own resolution, so
  it works for spells read through the Cooldown Manager - which a hand-written probe
  cannot, because the direct lookup finds nothing to ask about for exactly those.

## 0.5.0

- **"Fire again when it changes"**, for a buff that never actually drops off. A
  stacking buff you spend down but not out keeps the same aura the whole time - no
  gain to fire on, no loss to fire on, not even a new instance id - so an alert on it
  went off once at the pull and never again. Collapsing Star through meta is the case.
- It works because UNIT_AURA names the auras that changed, and those id lists stay
  readable in combat when everything about the change is withheld. The addon never
  learns the stack count and does not need to: "it changed" is the event.
- Off by default and governed by the rearm delay, because on a buff that ticks it
  would otherwise fire constantly.

## 0.4.2

- The "add it to the Cooldown Manager" note now says where to go - Edit Mode, on the
  Cooldown Manager itself - and why this addon will not do it for you. The Cooldown
  Manager's configuration turns out to be a single versioned, encoded string rather
  than a list of spells, so adding one entry would mean decoding an undocumented format
  and writing the whole thing back, where a mistake replaces the entire layout instead
  of failing.

## 0.4.1

- Uses the client's own `IsCooldownViewerAvailable` instead of inferring it from
  whether a viewer frame happens to exist. On a character with no Cooldown Manager the
  spell now says so, rather than sending you off to enable something in a feature you
  do not have.
- `/nba bridge` reports it too.

## 0.4.0

- **A spell has to be turned on in the Cooldown Manager, not merely known to it - and
  the addon now says so.** Being in the Cooldown Manager's list means the game knows
  the spell. It does not mean the Cooldown Manager is showing it, and one it is not
  showing never reaches a viewer frame, so the bridge never sees it. The alert then
  stays silent in a fight with nothing to explain why, which is the exact failure this
  addon was built to not have.
- Spells in that state are now marked **add it to the Cooldown Manager** in orange
  rather than being promised as readable. The mark corrects itself the moment the
  bridge actually sees the spell, so turning it on in Blizzard's settings is visible
  feedback rather than a leap of faith.
- **The bridge may no longer report a buff as "not up" unless it has demonstrably
  carried that spell.** A spell the Cooldown Manager could track but is not tracking
  gives the same empty answer as one that is genuinely gone, and drop-off and missing
  alerts would have acted on the difference.

## 0.3.4

- **`/nba bridge`** reports what the Cooldown Manager bridge can actually see: which
  viewers exist, which are shown, how many of their frames are holding an aura, and
  what every alert resolves to at this instant. Works in combat, which is the only
  place the answer is interesting.
- **A proc tracked as an essential cooldown rather than a buff is no longer reported as
  unreadable.** The check for "is there a live viewer" only looked at the two buff
  viewers while the code that actually reads them walks all four - so a spell the
  bridge was perfectly able to serve could be marked as out-of-combat-only, and
  drop-off alerts on it would never conclude the buff had gone.

## 0.3.3

- `/nba debug` no longer reports a fake delay on its first line. Turning it on while a
  buff was already up printed one line immediately and timed it against whatever aura
  event happened to be most recent - so a second of nothing at all was reported as a
  second of lag. A change that no aura event could have caused now says so.

## 0.3.2

- **A buff with no timer no longer blacks out its own icon.** The countdown swipe was
  drawn from a duration with nothing to count towards, which covers the icon
  completely - so the alert fired, drew, and looked like it had not, because what was
  on screen was a black square. There is no way to ask whether an aura is timerless,
  the duration being secret, so the swipe is simply never allowed to hide the icon it
  is drawn over.
- **`/nba debug`** prints every change of state: which of the three paths answered,
  the aura's instance id, and how many milliseconds after the game's own aura event it
  arrived. Session-only and off by default. If an alert still feels late, this is what
  turns that into a number.

## 0.3.1

- **A proc landing again now fires the alert again.** If a buff re-applied while the
  addon still believed the last one was up, there was no edge to fire on - so nothing
  happened, and the alert looked late or never arrived. The game hands out a new
  instance id for a new application, and that is now what "it just procced" means, as
  distinct from "it is still running". The rearm delay still governs how often it can
  repeat.
- **Alerts appear on the frame the buff lands.** An aura event does not mean the answer
  is ready: for a spell read through the Cooldown Manager, the thing being watched is a
  Blizzard frame reacting to the same event - and if it had not reacted yet, the proc
  read as absent and the next look was a tenth of a second away. An event now opens a
  short window of per-frame checks instead of asking for a single one.
- The countdown swipe, the stack count and the time remaining are grouped together
  under Extras. They share the one property worth knowing: each is a value this addon
  is never allowed to read, handed straight to a widget that is. Opacity and scale moved
  to their own group.
- Removed the stack threshold added a moment ago. It could not be made to work where it
  was wanted - the count the game gives out in combat is formatted for display and
  cannot be compared - and a condition that only holds outside a fight is worse than no
  condition.

## 0.3.0

- **Fonts are a dropdown, not a button you click forty-four times.** Every name is
  drawn in its own font, so the choice is visible before you make it, and one that
  will not load says so instead of being offered silently.
- **Sounds get the same list**, and clicking one plays it - a list of sound names
  tells you nothing until you hear one. Typing a path still works for your own files.
- **Fixed the error when changing font.** The cycling button understood options
  shaped `{key, label}` and fonts are shaped `{name, path}`, and the code that was
  meant to handle both did not: it handed back the whole entry instead of a name, so
  clicking wrote a table into the font setting and every refresh afterwards threw.
  Any font setting already broken this way is repaired on load.
- **Fixed "tried to call the protected function SetPropagateKeyboardInput".** That
  call is protected during combat, and a blocked call is not something that can be
  caught - it taints the addon for the rest of the session. Every use is now skipped
  inside a lockdown; the next key pressed after the fight restores it.
- Every other setting saved in the wrong shape is repaired on load rather than
  carried forward.

## 0.2.2

- **Locking brings the settings window back.** Unlocking hides the window, and the
  window's own hide handler called straight back into the lock handler - which then
  re-read whether the window was open from inside the hide that was still running,
  found it closed, and overwrote the note saying it had been open a moment earlier. So
  locking had nothing telling it to bring anything back.
- Closing the window by hand while the alerts are unlocked still puts the move bar up,
  and locking from there does not conjure a window that was not there.

## 0.2.1

- **The alert list shows each alert's spell icon**, greyed out when the alert is
  switched off.
- **Text no longer runs into the controls under it.** Every explanatory line in the
  window wraps, and the space each was given only ever counted the newlines that had
  been typed - so a sentence that wrapped to three lines was allotted one line's worth
  and whatever came next was drawn through its tail. Heights are now measured from the
  text itself, which cannot drift as the wording changes.
- The spell name and status line in the Alert tab, and the two lines of every row in
  the alert list, stop short of the edge and are cut with an ellipsis rather than
  growing across whatever is beside them.
- The picker's list starts below its own explanation rather than at a fixed offset, so
  the longest wording no longer covers the first row.
- **Watching a unit other than yourself now says what it can actually do**, when you
  pick one. Out of combat it always works; in a fight the game only answers about
  another unit for spells it has declassified, plus whatever the Cooldown Manager is
  tracking on your target.

## 0.2.0

- **The spell picker now offers Blizzard's own tracked list for your spec.** Not a
  guess about what your class procs - the Cooldown Manager's list, straight from the
  game, with buffs first. Everything on it can be read during a fight through the
  bridge, which makes it the right place to start nearly every alert. It is the
  picker's default source; the live scan and the remembered list are still there
  behind the same button.
- **Most buffs were being marked unreadable when they were not.** A Cooldown Manager
  entry is an *ability*, and the buff it applies carries a different spell id, so
  matching only on the id it reports missed almost everything. Every id an entry knows
  about is now indexed - the ability, a talent's override, and its linked spells - and
  then matched by **name** as well, because an ability and its buff share a name far
  more reliably than they share a number.
- **A readable spell that answers "not up" is no longer trusted until the Cooldown
  Manager has also been asked.** Picking a spell from the tracked list gives you an
  ability id; the aura can be up under a different one. Concluding "absent" from the
  first lookup would have made every alert built that way permanently silent.
- The tracked list is rebuilt on a talent change, not only on a spec change - a talent
  can replace the ability an entry points at without the spec moving.
- The unit button is hidden for the two sources that are not about a unit.

## 0.1.2

- **The spells in the picker can be clicked.** Every row was zero pixels wide, so
  there was nothing to click even though the names drew perfectly - a FontString does
  not clip to its parent, but a zero-wide button has no hit rectangle at all. A list
  you can read and cannot touch.
- The cause was the guard that is supposed to prevent exactly this. It copies the
  scroll frame's width onto its contents when the contents have none, but it fires
  during the first layout pass, while the scroll frame itself still measures zero - so
  it copied that zero, the contents no longer counted as unset, and nothing ever
  corrected it. It now waits for a real width, and both lists are given one up front
  the way the settings panels already were.

## 0.1.1

- **`/nba` opens the window on the first press.** A frame is shown from the moment it
  is created, so the first command built a visible window and then toggled it straight
  back off. Every other addon in the suite hides it at the end of the build; this one
  did not.
- **The spell picker covers what is behind it.** It was drawing at the same frame level
  as the settings panel and over a background that was not quite opaque, so the two
  interleaved and the panel underneath was still taking clicks through the gaps. The
  panel is now hidden while the picker is up, the picker sits well above it, and
  Escape closes the picker rather than the whole window.
- Changing tab, or closing the window, closes the picker with it.
- The window can be dragged from its body as well as its title bar, matching the rest
  of the suite.
- **nugsBuffAlert appears in Blizzard's own settings list**, with a button that opens
  the real window - the same stub every other nugs addon has.
- Closing the settings window while the alerts are unlocked puts the move bar back,
  instead of leaving that state with nothing on screen to end it.
- Alerts are clamped to the screen, so one cannot be dragged half off the edge and
  become unreachable.
- The lock is forced on at login rather than restored, so the saved flag can never
  disagree with what is on screen.
- Held alerts no longer restart their swipe and countdown ten times a second. Those are
  bindings, and handing a binding the same duration again restarts its animation.

## 0.1.0

First version.

- **One alert is one spell.** It watches a single aura on a single unit and puts text,
  an icon, or both on screen where you placed it. Every setting - font, colour, size,
  timing, position - lives on the alert, so two alerts never have to look alike.
- **Flash or hold.** A flash fades in, sits, and leaves on its own; a hold stays for as
  long as the buff is up and can carry a countdown swipe, the time remaining and a
  stack count.
- **Three triggers:** when a buff comes up, when it drops off, and the whole time it is
  missing.
- **Every alert says whether it will work in a raid.** The game hides aura data during
  combat and whether *your* spell is hidden depends on the spell, so each one is marked
  - reads everywhere, reads via the Cooldown Manager, out of combat only, or never -
  and the Alert tab says it in a sentence. An alert that would silently show nothing on
  a pull is the failure this addon exists to not have.
- **Procs are read through Blizzard's Cooldown Manager** where the game will not answer
  directly. It is not an addon, so it is allowed to read what this is not; this reads
  the plain ids its frames already carry. It has to be visible to keep updating, so
  there is a setting to fade it to nothing instead of hiding it.
- **Nothing fires on an unknown.** "Is this buff up" has three answers, not two, and a
  missing-buff warning that treats "not allowed to know" as "not up" would sit on your
  screen for a whole fight.
- Spell picker driven by a live scan of what is actually on you, plus everything this
  character has had on it before. The id on a website is as often the ability as the
  aura it applies.
- Alerts can be pinned to a spec, so a Retribution proc does not need deleting to play
  Holy.
- Unlocking hides the settings window and puts up a small bar instead, because placing
  things means dragging boxes the window is usually sitting on top of.
- `/nba`, a minimap button, LibSharedMedia fonts and sounds if some other addon has
  loaded it, and a nugsSuite registration for profile sharing.
