// Companion to fwdref.js, which only catches a name declared `local` LATER in the
// file. This catches the other half of the same bug class: a bare identifier that is
// ASSIGNED but never declared local anywhere, so the write silently lands on a global.
// Same user-visible symptom, and fwdref.js reports those files clean.
//
// Writes to globals are legitimate in a few addon spots (SLASH_*, SlashCmdList,
// SavedVariables names, deliberate _G handoffs), so this prints every hit for review
// rather than exiting non-zero.
const luaparse = require('luaparse');
const fs = require('fs');
const path = require('path');

// Deliberate global writes an addon is allowed to make.
const ALLOWED = /^(SLASH_|SlashCmdList$|BINDING_|StaticPopupDialogs$|nugs\w*DB$|nugs\w*CharDB$)/;

for (const file of process.argv.slice(2)) {
  const src = fs.readFileSync(file, 'utf8');
  const ast = luaparse.parse(src, { luaVersion: '5.1', locations: true, comments: false });

  // Every name declared local ANYWHERE in the file, at any depth.
  const locals = new Set();
  (function collect(n) {
    if (!n || typeof n !== 'object') return;
    if (Array.isArray(n)) return n.forEach(collect);
    if (n.type === 'LocalStatement') for (const v of n.variables) locals.add(v.name);
    if (n.type === 'FunctionDeclaration') {
      if (n.isLocal && n.identifier && n.identifier.type === 'Identifier') locals.add(n.identifier.name);
      for (const p of n.parameters || []) if (p.name) locals.add(p.name);
    }
    // `for i = ...` and `for k, v in ...` bind names too.
    if (n.type === 'ForNumericStatement' && n.variable) locals.add(n.variable.name);
    if (n.type === 'ForGenericStatement') for (const v of n.variables || []) locals.add(v.name);
    for (const k of Object.keys(n)) if (k !== 'loc') collect(n[k]);
  })(ast.body);

  const hits = [];
  (function walk(n) {
    if (!n || typeof n !== 'object') return;
    if (Array.isArray(n)) return n.forEach(walk);
    if (n.type === 'AssignmentStatement') {
      for (const t of n.variables) {
        // Only bare `x = ...`. `a.b = ...` and `a[i] = ...` mutate a table, not a binding.
        if (t.type === 'Identifier' && !locals.has(t.name) && !ALLOWED.test(t.name))
          hits.push({ name: t.name, line: t.loc.start.line });
      }
    }
    // `function Foo()` with no dot/colon is also a global write.
    if (n.type === 'FunctionDeclaration' && !n.isLocal && n.identifier &&
        n.identifier.type === 'Identifier' && !locals.has(n.identifier.name) &&
        !ALLOWED.test(n.identifier.name))
      hits.push({ name: n.identifier.name + '()', line: n.loc.start.line });
    for (const k of Object.keys(n)) if (k !== 'loc') walk(n[k]);
  })(ast.body);

  const label = path.basename(path.dirname(file)) + '/' + path.basename(file);
  if (hits.length) {
    console.log(label);
    for (const h of hits) console.log(`   ${h.name}  assigned line ${h.line}  (never declared local)`);
  } else {
    console.log(`${label}  clean`);
  }
}
