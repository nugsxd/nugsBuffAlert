// wowcheck.js - WoW-specific risks the other checkers do not look for. These are the
// things an addon actually gets removed or badly reviewed for, as opposed to things
// that are merely untidy.
//
//   node wowcheck.js --all
//   node wowcheck.js D:/Claude/nugsCastBars/*.lua
//
// What it looks for, and why each one matters:
//
//   CLEU        COMBAT_LOG_EVENT_UNFILTERED fires for every combat event from every
//               source in the zone. It is the single most expensive thing an addon
//               can register for, and the first thing anyone profiling will blame.
//
//   UNITEVENT   RegisterEvent("UNIT_*") wakes your handler for every unit in the
//               game. RegisterUnitEvent(event, "player") filters it in the client,
//               which is free. Low-frequency events like UNIT_PET barely matter;
//               UNIT_AURA and UNIT_POWER_* very much do.
//
//   SETSCRIPT   SetScript on a frame pulled out of _G replaces Blizzard's handler,
//               and any other addon's. HookScript adds to it instead. This is the
//               difference between coexisting and breaking somebody's UI.
//
//   COMBAT      Show/Hide on a Blizzard frame with no InCombatLockdown() in sight.
//               Protected frames cannot be shown or hidden by insecure code during
//               combat; doing it anyway is what produces "Interface action failed
//               because of an AddOn" for the user.
//
//   ALLOC       A table constructor inside an OnUpdate handler allocates every
//               frame and hands the garbage collector work forever.
//
// A hit is a question, not a verdict. UNIT_PET unfiltered is fine. A table built
// once inside a handler that early-returns is fine. Read the line before changing it.
const fs = require('fs');
const path = require('path');

// Unit events cheap enough that filtering them buys nothing measurable.
const LOW_FREQUENCY = new Set(['UNIT_PET', 'UNIT_NAME_UPDATE', 'UNIT_PORTRAIT_UPDATE',
                               'UNIT_CONNECTION', 'UNIT_LEVEL', 'UNIT_FACTION']);

function scan(file) {
    const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
    const hits = [];
    const add = (line, tag, msg) => hits.push({ line: line + 1, tag, msg });

    // Frames fetched out of _G are Blizzard's (or another addon's), not ours. A name
    // that is ALSO used for a frame we create somewhere in the same file is dropped:
    // Lua scoping means those are two different variables, and this checker reads
    // lines rather than scopes, so it cannot tell them apart. Staying quiet beats
    // pointing at the wrong one - nugsComboBar has a `local frame = _G[name]` inside
    // one function and a `local frame = CreateFrame(...)` at file level.
    const foreign = new Set();
    const ours = new Set();
    lines.forEach((line) => {
        for (const m of line.matchAll(/local\s+(\w+)\s*=\s*_G\[/g)) foreign.add(m[1]);
        for (const m of line.matchAll(/local\s+(\w+)\s*=\s*CreateFrame\s*\(/g)) ours.add(m[1]);
    });
    for (const name of ours) foreign.delete(name);

    // Combat guards belong to a whole function, not to the few lines above a call.
    const enclosingStart = (i) => {
        for (let k = i; k >= 0; k--)
            if (/^\s*(local\s+)?function\b/.test(lines[k])) return k;
        return 0;
    };

    lines.forEach((line, i) => {
        const code = line.replace(/--.*$/, '');
        if (!code.trim()) return;

        if (/COMBAT_LOG_EVENT/.test(code)) add(i, 'CLEU', 'registers the full combat log');

        const ue = code.match(/RegisterEvent\s*\(\s*["'](UNIT_[A-Z_]+)["']/);
        if (ue && !LOW_FREQUENCY.has(ue[1]))
            add(i, 'UNITEVENT', ue[1] + ' unfiltered - RegisterUnitEvent is free');

        for (const name of foreign) {
            if (new RegExp('\\b' + name + ':SetScript\\s*\\(').test(code))
                add(i, 'SETSCRIPT', name + ':SetScript replaces the existing handler - use HookScript');
            if (new RegExp('\\b' + name + ':(Show|Hide)\\s*\\(').test(code)) {
                const fn = lines.slice(enclosingStart(i), i + 2).join('\n');
                if (!/InCombatLockdown/.test(fn))
                    add(i, 'COMBAT', name + ':Show/Hide with no InCombatLockdown guard in this function');
            }
        }

        if (/SetScript\s*\(\s*["']OnUpdate["']/.test(code) && !/OnUpdate["']\s*,\s*nil/.test(code)) {
            const body = lines.slice(i, i + 20);
            for (let k = 1; k < body.length; k++) {
                const b = body[k].replace(/--.*$/, '');
                if (/^\s*(end\)|end$)/.test(b)) break;
                // `if not x then x = {} end` fills a cache once and reuses it after,
                // which is the opposite of per-frame churn.
                if (/if\s+not\s+\w+\s+then\s+\w+\s*=\s*\{\s*\}/.test(b)) continue;
                // a table literal being built, not an index or a call
                if (/[=(,]\s*\{\s*$/.test(b) || /=\s*\{\s*\}/.test(b))
                    { add(i + k, 'ALLOC', 'table built inside an OnUpdate handler'); break; }
            }
        }
    });
    return hits;
}

let files = process.argv.slice(2).filter(a => !a.startsWith('--'));
if (process.argv.includes('--all')) {
    files = [];
    for (const a of ['nugsSuite', 'nugsRaidReady', 'nugsCastBars', 'nugsComboBar',
                     'nugsCooldownPulse', 'nugsAuras', 'nugsDeathNote']) {
        const dir = path.join('D:/Claude', a);
        if (!fs.existsSync(dir)) continue;
        for (const f of fs.readdirSync(dir).filter(x => x.endsWith('.lua')))
            files.push(path.join(dir, f));
    }
}
if (!files.length) { console.error('usage: node wowcheck.js --all | <files...>'); process.exit(2); }

let total = 0;
const counts = {};
for (const f of files) {
    const hits = scan(f);
    if (!hits.length) continue;
    console.log(f.replace(/\\/g, '/').replace('D:/Claude/', ''));
    for (const h of hits) {
        total++;
        counts[h.tag] = (counts[h.tag] || 0) + 1;
        console.log('   ' + h.tag.padEnd(10) + 'line ' + String(h.line).padEnd(6) + h.msg);
    }
}
console.log('');
console.log(files.length + ' files scanned, ' + total + ' to review'
            + (total ? '  [' + Object.entries(counts).map(([k, v]) => k + ' ' + v).join(', ') + ']' : ''));
