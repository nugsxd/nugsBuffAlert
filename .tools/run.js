// Runs every static check over this addon's Lua files.
//
//   npm install && npm test
//
// Each of these exists because of a bug that reached a build. The comment at the top
// of each script says which one.
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const root = path.join(__dirname, '..');
const lua = fs.readdirSync(root).filter(f => f.endsWith('.lua')).map(f => path.join(root, f));
if (!lua.length) { console.error('no .lua files found in ' + root); process.exit(2); }

// gating: a hit is a build failure.  advisory: a hit is printed and moved past,
// because SavedVariables have to be globals and always show up here.
const CHECKS = [
    { file: 'check.js',       label: 'parses',                  gating: true  },
    { file: 'fwdref.js',      label: 'forward references',      gating: true  },
    { file: 'selfref.js',     label: 'self-referencing locals', gating: true  },
    { file: 'wowcheck.js',    label: 'WoW-specific risks',      gating: true  },
    { file: 'globalwrite.js', label: 'writes to globals',       gating: false },
];

let failed = 0;
for (const c of CHECKS) {
    const r = spawnSync(process.execPath, [path.join(__dirname, c.file), ...lua], { encoding: 'utf8' });
    const bad = r.status !== 0;
    const state = bad ? (c.gating ? 'FAIL' : 'note') : 'ok';
    console.log('  ' + c.label.padEnd(28) + state);
    if (bad) {
        process.stdout.write((r.stdout || '').replace(/^/gm, '      '));
        process.stderr.write(r.stderr || '');
        if (c.gating) failed++;
    }
}
console.log('');
console.log(failed ? failed + ' check(s) failed' : 'all checks passed');
process.exit(failed ? 1 : 0);
