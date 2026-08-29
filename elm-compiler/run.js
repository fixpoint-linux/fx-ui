// M0 bootstrap → M3: node wrapper for the elm-compiler.
//
//   node run.js <input1.elm> [input2.elm ...] <output.csexp>
//
// ALL inputs are compiled TOGETHER as one multi-module program (cross-module
// references resolve through the merged global table).  src/Prelude.elm is
// ALWAYS appended last — it is compiled by the compiler itself (plan §6/§8
// M3), so user modules get List/String/Basics conveniences without importing
// anything.  The source list travels to Main.elm as a JSON array string.
//
// Main.elm emits synchronously inside init, but Elm's kernel delivers port
// Cmd messages asynchronously (on the next tick), so we wait for the emit
// callback and exit once it fires.

'use strict';

const fs = require('fs');
const path = require('path');

if (process.argv.length < 4) {
  console.error('usage: node run.js <input1.elm> [input2.elm ...] <output.csexp>');
  process.exit(2);
}

const argv = process.argv.slice(2);
const output = argv[argv.length - 1];
const inputs = argv.slice(0, -1);

const sources = inputs.map((p) => fs.readFileSync(p, 'utf8'));
const prelude = fs.readFileSync(path.join(__dirname, 'src', 'Prelude.elm'), 'utf8');
const runtime = fs.readFileSync(path.join(__dirname, 'src', 'Runtime.elm'), 'utf8');
// elm/core runtime ports (Dict/Set/Maybe/Result): compiled as their OWN units
// like the Prelude, so dotted refs (Dict.insert, Maybe.map, Set.union) resolve
// through the merged global table without any alias rows.  They live in
// core-libs/ (NOT src/) because elm's ambiguity check spans source-directories:
// a local src/Dict.elm collides with elm/core's Dict for every compiler module
// that imports it, breaking `elm make src/Main.elm`.
const corelib = [ 'Dict.elm', 'Set.elm', 'Maybe.elm', 'Result.elm',
                  'Tuple.elm', 'JsArray.elm', 'Array.elm' ]
  .map((f) => fs.readFileSync(path.join(__dirname, 'core-libs', f), 'utf8'));
sources.push(prelude);
sources.push(runtime);
sources.push(...corelib);

const { Elm } = require('./compiler.js');

const app = Elm.Main.init({ flags: { sourcesJson: JSON.stringify(sources) } });

app.ports.emit.subscribe((msg) => {
  fs.writeFileSync(output, msg);
  process.exit(0);
});

// Safety net: if Main.elm never emits, don't hang forever.
setTimeout(() => {
  console.error('run.js: timed out waiting for emit port');
  process.exit(1);
}, 5000);
