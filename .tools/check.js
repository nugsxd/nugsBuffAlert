const luaparse = require('luaparse');
const fs = require('fs');
const files = process.argv.slice(2);
let bad = 0;
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  try {
    luaparse.parse(src, { luaVersion: '5.1', comments: false });
    console.log('OK   ' + f);
  } catch (e) {
    bad++;
    console.log('FAIL ' + f + '\n     ' + e.message);
  }
}
process.exit(bad ? 1 : 0);
