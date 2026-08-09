// Flags a name used BEFORE the `local` that declares it, in ANY scope.
//
// Lua resolves such a name to a global rather than erroring, so the bug is
// invisible until the code runs. See README.md for the failure it causes.
//
// Walks each block in statement order tracking what is in scope *so far*, and
// treats function bodies AND nested statement blocks (if / do / while / for /
// repeat) as their own scopes.
//
// The previous version only inspected top-level `local`s, and treated any local
// declared anywhere inside a function as shadowing. That made it report clean on
// a real bug in nugsAuras/Options.lua, where a closure assigned to `scanResults`
// eighteen lines above the `local scanResults` in the same function body. Both
// halves matter: the declaration has to be found wherever it is, and it only
// shadows from its own line onward.
//
// The version after THAT still only compared a reference against declarations in
// its OWN block. Descending into a function body started a fresh scanBlock with a
// fresh declLine, so the enclosing block's later declarations were invisible from
// inside the function -- which is where essentially all real code lives. It
// reported clean on nugsCombatText/Core.lua, where an ApplyFont defined at line
// 200 read a `db` declared local at line 221 and bound to a nil global instead,
// for 774 errors. Declarations pending in ENCLOSING blocks are now threaded down
// through nesting, which is the whole point of the check.
//
//   node fwdref.js D:/Claude/nugsAuras/*.lua
//
// Exits non-zero if anything is found.

const luaparse = require('luaparse');
const fs = require('fs');

// Statement types whose `body` is a nested block with its own scope.
const NESTED = {
  IfClause: 1, ElseifClause: 1, ElseClause: 1, DoStatement: 1,
  WhileStatement: 1, RepeatStatement: 1,
  ForNumericStatement: 1, ForGenericStatement: 1,
};

let bad = 0;

for (const file of process.argv.slice(2)) {
  const src = fs.readFileSync(file, 'utf8');
  const ast = luaparse.parse(src, { luaVersion: '5.1', locations: true, comments: false });
  const hits = [];

  function scanBlock(stmts, outerInScope, outerPending) {
    // Every name this block declares, and the line it becomes valid on.
    const declLine = new Map();
    for (const st of stmts) {
      if (st.type === 'LocalStatement') {
        for (let i = 0; i < st.variables.length; i++) {
          const v = st.variables[i];
          // `local UnitGUID = UnitGUID` is the localise-a-global-for-speed idiom.
          // Uses above it do bind to the global, but the local is that same global,
          // so nothing can go wrong and flagging it is pure noise. This is the only
          // shape where an earlier reference is provably harmless -- `local db` and
          // `local db = {}` are the real bug and stay flagged.
          const init = st.init && st.init[i];
          const selfCache = init && init.type === 'Identifier' && init.name === v.name;
          if (!selfCache && !declLine.has(v.name)) declLine.set(v.name, st.loc.start.line);
        }
      } else if (st.type === 'FunctionDeclaration' && st.isLocal && st.identifier) {
        if (!declLine.has(st.identifier.name)) declLine.set(st.identifier.name, st.loc.start.line);
      }
    }

    // Declarations still to come, in this block AND every block enclosing it. A
    // reference from inside a nested function has to be checked against the
    // enclosing file scope too -- that is where `local db` sits while the function
    // that reads it is being defined forty lines above.
    //
    // This block's own declarations overwrite an outer entry of the same name,
    // because from here on it is the inner one that will shadow.
    const pending = new Map(outerPending);
    for (const [name, line] of declLine) pending.set(name, line);

    const inScope = new Set(outerInScope);

    function expr(node, scope) {
      if (!node || typeof node !== 'object') return;
      if (Array.isArray(node)) return node.forEach(n => expr(n, scope));

      // a.b and a:b -> only `a` is a variable; `b` is a field name.
      if (node.type === 'MemberExpression') return expr(node.base, scope);
      if (node.type === 'TableKeyString') return expr(node.value, scope);

      if (node.type === 'FunctionDeclaration') {
        const inner = new Set(scope);
        for (const p of node.parameters || []) if (p.name) inner.add(p.name);
        if (node.identifier && !node.isLocal) expr(node.identifier, scope);
        scanBlock(node.body, inner, pending);
        return;
      }

      if (NESTED[node.type] && Array.isArray(node.body)) {
        if (node.condition) expr(node.condition, scope);
        for (const k of ['start', 'end', 'step', 'iterators']) if (node[k]) expr(node[k], scope);
        const inner = new Set(scope);
        for (const v of node.variables || []) if (v.name) inner.add(v.name);
        scanBlock(node.body, inner, pending);
        return;
      }

      if (node.type === 'Identifier' && node.loc) {
        // Not yet in scope at this point, but declared local later somewhere that
        // encloses it: Lua binds this to a global and the local never sees it.
        const decl = pending.get(node.name);
        if (!scope.has(node.name) && decl !== undefined
            && node.loc.start.line < decl) {
          hits.push({ name: node.name, used: node.loc.start.line, decl });
        }
        return;
      }

      for (const k of Object.keys(node)) if (k !== 'loc') expr(node[k], scope);
    }

    for (const st of stmts) {
      if (st.type === 'LocalStatement') {
        // The right-hand side is evaluated before the names are bound, so
        // `local x = x` legitimately refers to an outer x.
        expr(st.init, inScope);
        for (const v of st.variables) inScope.add(v.name);
      } else if (st.type === 'FunctionDeclaration' && st.isLocal && st.identifier) {
        // `local function f` binds f before its body, so recursion is fine.
        inScope.add(st.identifier.name);
        expr(st, inScope);
      } else {
        expr(st, inScope);
      }
    }
  }

  scanBlock(ast.body, new Set(), new Map());

  const seen = new Set();
  const uniq = hits.filter(h => {
    const k = h.name + ':' + h.used;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });

  if (uniq.length) {
    bad++;
    console.log(file);
    for (const h of uniq) console.log(`   ${h.name}  used line ${h.used}, declared line ${h.decl}`);
  } else {
    console.log(`${file}  clean`);
  }
}

process.exit(bad ? 1 : 0);
