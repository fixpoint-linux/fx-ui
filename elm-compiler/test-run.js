// M1a test runner: builds/loads test-compiler.js (from src/TestMain.elm),
// collects the `report` port output, prints it, and exits nonzero if any
// assertion FAILed.
//
//   ELM_HOME=.elm-cache elm make src/TestMain.elm --output=test-compiler.js
//   node test-run.js

'use strict';

const { Elm } = require('./test-compiler.js');

const app = Elm.TestMain.init();

let lines = [];
app.ports.report.subscribe((msg) => {
  lines = msg.split('\n');
});

// Port Cmd messages are delivered on a later tick, so collect then print.
setTimeout(() => {
  for (const l of lines) {
    process.stdout.write(l + '\n');
  }
  const fails = lines.filter((l) => l.startsWith('FAIL')).length;
  if (fails > 0) {
    process.stderr.write(`\n${fails} FAILED assertion(s)\n`);
    process.exit(1);
  } else {
    const total = lines.length;
    process.stdout.write(`\nAll ${total} assertions passed.\n`);
    process.exit(0);
  }
}, 500);
