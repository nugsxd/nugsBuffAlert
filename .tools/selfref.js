// selfref.js - finds `local x = <expression mentioning x>`.
//
//   node selfref.js --all
//   node selfref.js D:/Claude/nugsCooldownPulse/*.lua
//
// A local's scope begins AFTER the statement that declares it, so this:
//
//   local btn = Button(parent, "", w, h, function() Popup(btn) end)
//
// does not capture `btn` at all. The closure binds to a *global* of that name and
// receives nil. It parses, it loads, and it only fails the moment somebody clicks -
// which is how it reached a shipped build of nugsCooldownPulse 0.16.0 and threw
// "attempt to index local 'anchorTo' (a nil value)" fourteen times.
//
// fwdref.js does not cover this: it looks for a name used before the top-level local
// that declares it, and here the use and the declaration are on the same statement,
// inside a function.
//
// The fix is always the same - split the declaration from the assignment:
//
//   local btn
//   btn = Button(parent, "", w, h, function() Popup(btn) end)
const fs = require('fs');
const path = require('path');
const luaparse = require('luaparse');

function scan(file) {
    const text = fs.readFileSync(file, 'utf8');
    let ast;
    try {
        ast = luaparse.parse(text, { locations: true, comments: false, scope: false });
    } catch (e) {
        return [{ line: e.line || 0, name: '(parse error)', detail: e.message }];
    }

    const hits = [];

    const walkAll = (node, fn) => {
        if (!node || typeof node !== 'object') return;
        if (Array.isArray(node)) { for (const n of node) walkAll(n, fn); return; }
        if (node.type) fn(node);
        for (const key of Object.keys(node)) {
            if (key === 'loc') continue;
            walkAll(node[key], fn);
        }
    };

    // Walks an expression looking for genuine *variable* references.
    //
    // The naive version of this flagged 139 things and every one was wrong, because
    // the name after a dot is a field, not a variable: `local db = CDP.db` reads
    // CDP's db field and has nothing to do with the local being declared. Same for
    // `local cos = math.cos` and `{ key = value }`. Those are skipped here.
    //
    // `shadowed` carries names re-bound by an inner function's parameters, which are
    // also not the outer local.
    const walkVars = (node, declared, shadowed, inClosure, fn) => {
        if (!node || typeof node !== 'object') return;
        if (Array.isArray(node)) {
            for (const n of node) walkVars(n, declared, shadowed, inClosure, fn);
            return;
        }

        if (node.type === 'MemberExpression') {
            walkVars(node.base, declared, shadowed, inClosure, fn);  // only base is an expression
            return;                                                  // identifier is a field name
        }
        if (node.type === 'TableKeyString') {
            walkVars(node.value, declared, shadowed, inClosure, fn);  // key is a name
            return;
        }
        if (node.type === 'FunctionDeclaration') {
            const inner = new Set(shadowed);
            for (const p of node.parameters || []) if (p.name) inner.add(p.name);
            walkVars(node.body, declared, inner, true, fn);           // now inside a closure
            return;
        }
        if (node.type === 'Identifier') {
            // Only a reference from inside a nested function is a bug. Everything
            // else is a deliberate idiom that binds to the global on purpose:
            //   local UnitPower = UnitPower   -- upvalue caching, correct
            //   local db = db or {}           -- seed from an existing global
            // The closure case is different because it runs LATER, when the author
            // plainly meant the local they were in the middle of declaring.
            if (inClosure && declared.has(node.name) && !shadowed.has(node.name)) fn(node);
            return;
        }
        for (const key of Object.keys(node)) {
            if (key === 'loc') continue;
            walkVars(node[key], declared, shadowed, inClosure, fn);
        }
    };

    walkAll(ast, (node) => {
        if (node.type !== 'LocalStatement') return;
        const declared = new Set((node.variables || []).map(v => v.name));
        if (!declared.size) return;
        for (const init of node.init || []) {
            walkVars(init, declared, new Set(), false, (inner) => {
                hits.push({
                    line: (inner.loc && inner.loc.start.line) || 0,
                    name: inner.name,
                    detail: 'used inside its own "local ' + inner.name + ' = ..." - binds to a global, not this local',
                });
            });
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
if (!files.length) { console.error('usage: node selfref.js --all | <files...>'); process.exit(2); }

let total = 0;
for (const f of files) {
    const hits = scan(f);
    if (!hits.length) continue;
    console.log(f.replace(/\\/g, '/').replace('D:/Claude/', ''));
    for (const h of hits) {
        total++;
        console.log('   line ' + String(h.line).padEnd(6) + h.name + '  -  ' + h.detail);
    }
}
console.log('');
console.log(files.length + ' files scanned, ' + total + ' found');
process.exit(total ? 1 : 0);
