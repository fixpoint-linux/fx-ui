// M0 bootstrap → M3 → batch: node wrapper for the elm-compiler.
//
// Single-fixture CLI (preserved):
//   node run.js <input1.elm> [input2.elm ...] <output.csexp>
// ALL inputs are compiled TOGETHER as one multi-module program (cross-module
// references resolve through the merged global table).  src/Prelude.elm is
// ALWAYS appended last — it is compiled by the compiler itself (plan §6/§8
// M3), so user modules get List/String/Basics conveniences without importing
// anything.  The source list travels to Main.elm as a JSON array string.
//
// Batch CLI (S8):
//   node run.js --batch <manifest.json>
// manifest = { "groups": [ { "sources": ["/abs/a.elm", ...], "output": "/abs/x.csexp" }, ... ] }
// The fixed corpus (Prelude + Runtime + the seven core-libs) is read ONCE and
// every group is compiled in this one process; Main.elm emits a JSON ARRAY of
// per-group bundle strings ("<bundle>" or "err <msg>" per group), which are
// written to each group's output file.  This pays for the corpus
// parse+typecheck+lower exactly once instead of once per fixture.
//
// Main.elm emits synchronously inside init, but Elm's kernel delivers port
// Cmd messages asynchronously (on the next tick), so we wait for the emit
// callback and exit once it fires.

'use strict';

const fs = require('fs');
const path = require('path');

// The fixed corpus, in the order Main/run.js historically appended them:
// Prelude, Runtime, then the seven elm/core ports plus Tea (Dict/Set/Maybe/
// Result/Tuple live in core-libs/ — NOT src/ — because elm's ambiguity check
// spans source-directories: a local src/Dict.elm collides with elm/core's
// Dict for every compiler module that imports it, breaking
// `elm make src/Main.elm`).
const CORPUS = [
  fs.readFileSync(path.join(__dirname, 'src', 'Prelude.elm'), 'utf8'),
  fs.readFileSync(path.join(__dirname, 'src', 'Runtime.elm'), 'utf8'),
  ...[ 'Dict.elm', 'Set.elm', 'Maybe.elm', 'Result.elm',
       'Tuple.elm', 'JsArray.elm', 'Array.elm', 'Tea.elm', 'TextInput.elm',
       'Str.elm', 'Lipgloss.elm', 'Key.elm', 'Help.elm', 'Paginator.elm',
       'Progress.elm', 'Spinner.elm', 'Viewport.elm', 'Textarea.elm',
       'ListBox.elm', 'Table.elm' ]
    .map((f) => fs.readFileSync(path.join(__dirname, 'core-libs', f), 'utf8')),
];

const { Elm } = require('./compiler.js');

// Compile `groups` (array of { sources: [String], output: String }) in ONE
// process.  Each group's bundle (or "err <msg>") lands in its output file.
function compileGroups(groups) {
  const app = Elm.Main.init({
    flags: {
      corpusSourcesJson: JSON.stringify(CORPUS),
      groupsJson: JSON.stringify(groups.map((g) => g.sources)),
    },
  });

  app.ports.emit.subscribe((msg) => {
    let bundles;
    try {
      bundles = JSON.parse(msg);
    } catch (e) {
      console.error('run.js: bad emit payload (not JSON)');
      process.exit(1);
    }
    if (!Array.isArray(bundles) || bundles.length !== groups.length) {
      console.error(
        `run.js: expected ${groups.length} bundles, got ` +
        `${Array.isArray(bundles) ? bundles.length : 'non-array'}`
      );
      process.exit(1);
    }
    for (let i = 0; i < groups.length; i++) {
      fs.writeFileSync(groups[i].output, bundles[i]);
    }
    process.exit(0);
  });

  // Safety net: if Main.elm never emits, don't hang forever.  Generous for
  // the batch mode (all fixtures in one process).
  setTimeout(() => {
    console.error('run.js: timed out waiting for emit port');
    process.exit(1);
  }, 120000);
}

function usage() {
  console.error(
    'usage: node run.js <input1.elm> [input2.elm ...] <output.csexp>\n' +
    '       node run.js --batch <manifest.json>'
  );
  process.exit(2);
}

function main() {
  const argv = process.argv.slice(2);

  if (argv[0] === '--batch') {
    if (argv.length !== 2) usage();
    const manifest = JSON.parse(fs.readFileSync(argv[1], 'utf8'));
    const groups = manifest.groups.map((g) => ({
      sources: g.sources.map((p) => fs.readFileSync(p, 'utf8')),
      output: g.output,
    }));
    compileGroups(groups);
    return;
  }

  if (argv.length < 2) usage();
  const output = argv[argv.length - 1];
  const inputs = argv.slice(0, -1);
  compileGroups([{ sources: inputs.map((p) => fs.readFileSync(p, 'utf8')), output }]);
}

main();
