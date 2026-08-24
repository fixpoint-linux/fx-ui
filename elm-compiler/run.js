// M0 bootstrap: node wrapper for the elm-compiler.
//
//   node run.js <input.elm> <output.csexp>
//
// Reads the input Elm source file, initialises the compiled Elm module with it
// as flags ({source}), subscribes to the `emit` port (Main.elm sends its parse
// result there), and writes that result to the output .csexp file.
//
// Main.elm emits synchronously inside init, but Elm's kernel delivers port
// Cmd messages asynchronously (on the next tick), so we wait for the emit
// callback and exit once it fires.

'use strict';

const fs = require('fs');

if (process.argv.length < 4) {
  console.error('usage: node run.js <input.elm> <output.csexp>');
  process.exit(2);
}

const inputPath = process.argv[2];
const outputPath = process.argv[3];

const source = fs.readFileSync(inputPath, 'utf8');
const { Elm } = require('./compiler.js');

const app = Elm.Main.init({ flags: { source } });

app.ports.emit.subscribe((msg) => {
  fs.writeFileSync(outputPath, msg);
  process.exit(0);
});

// Safety net: if Main.elm never emits, don't hang forever.
setTimeout(() => {
  console.error('run.js: timed out waiting for emit port');
  process.exit(1);
}, 5000);
