#!/usr/bin/env bash
# Interactive run of the fx-ui todos example.
#
# Prereqs (built once, from the repo root):
#   cd elm-compiler && ./build.sh
#   zig build elmvm
#
# Then run this from wherever you want todos.txt to live — the app reads it at
# startup and rewrites it on every change (add / toggle / delete / clear done),
# RELATIVE TO YOUR CURRENT DIRECTORY, so pick a scratch dir to avoid clobbering
# a real file.
#
# Keys: type a todo then enter to add; space/x toggle done; d/backspace delete
# the selected todo; C clears done; / filters (type, enter applies, esc
# cancels); ? shows full help; up/down/pgup/pgdn navigate; q/ctrl+c quit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

node "$ROOT/elm-compiler/run.js" "$ROOT/examples/todos/TodoApp.elm" /tmp/todos.csexp
exec "$ROOT/zig-out/bin/elmvm" /tmp/todos.csexp TodoApp.main
