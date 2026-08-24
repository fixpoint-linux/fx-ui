#!/usr/bin/env bash
# run-elm-gate.sh — M1b gate runner.
#
# For each fixture under tests/elm-fixtures, compiles it with the elm-compiler
# (node run.js -> .csexp), loads it into the ZINC VM via elmvm, runs the named
# function with the given args, and diffs the printed value against
# expected/<name>.txt.
#
# Usage:
#   tests/elm-fixtures/run-elm-gate.sh [elmvm-binary] [elm-compiler-dir] [fixtures-dir]
#
# Defaults assume you are running from the fx-ui repo root:
#   elmvm    -> zig-out/bin/elmvm   (built via `zig build elmvm`)
#   compiler -> elm-compiler/       (compiler.js built via build.sh)
#   fixtures -> tests/elm-fixtures
#
# Exit code 0 iff every check passes.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ELMVM="${1:-$ROOT/zig-out/bin/elmvm}"
CDIR="${2:-$ROOT/elm-compiler}"
FIX="${3:-$ROOT/tests/elm-fixtures}"
OUT="$(mktemp -d)"

if [ ! -x "$ELMVM" ]; then
  echo "error: elmvm not found at $ELMVM (run: zig build elmvm)" >&2
  exit 2
fi
if [ ! -f "$CDIR/compiler.js" ]; then
  echo "error: $CDIR/compiler.js missing (run: build.sh)" >&2
  exit 2
fi

pass=0; fail=0

# run <name> <fn> <expected> [args...]
run() {
  local name="$1" fn="$2" exp="$3"; shift 3
  node "$CDIR/run.js" "$FIX/$name.elm" "$OUT/$name.csexp" 2>/dev/null
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "FAIL $name: node run.js rc=$rc"; fail=$((fail+1)); return
  fi
  if head -c 4 "$OUT/$name.csexp" | grep -q '^err '; then
    echo "FAIL $name: compile error: $(cat "$OUT/$name.csexp")"; fail=$((fail+1)); return
  fi
  local got
  got=$("$ELMVM" "$OUT/$name.csexp" "$fn" "$@" 2>&1)
  if [ "$got" = "$exp" ]; then
    echo "PASS $name ($fn $*) -> $got"; pass=$((pass+1))
  else
    echo "FAIL $name ($fn $*): exp[$exp] got[$got]"; fail=$((fail+1))
  fi
}

# read_expected <name> -> trims the trailing newline
read_expected() { cat "$FIX/expected/$1.txt"; }

# compile_error <name> <expected-substring>: asserts compilation emits
# "err <message>" and that <message> contains the expected substring.  Used for
# fixtures that must FAIL to compile (duplicate/unknown names, etc.) rather than
# run through the value gate.
compile_error() {
  local name="$1" exp="$2"
  node "$CDIR/run.js" "$FIX/$name.elm" "$OUT/$name.csexp" 2>/dev/null
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "FAIL $name: node run.js rc=$rc"; fail=$((fail+1)); return
  fi
  local out
  out=$(cat "$OUT/$name.csexp")
  case "$out" in
    err*"$exp"*) echo "PASS $name: $out"; pass=$((pass+1));;
    *) echo "FAIL $name: expected err containing [$exp], got [$out]"; fail=$((fail+1));;
  esac
}

run fib        fib        "$(read_expected fib)"        10
run rtl1       main       "$(read_expected rtl1)"
run rtl2       main       "$(read_expected rtl2)"
run sub        sub        "$(read_expected sub)"        10 3
run sub        sub        "-7"                           3 10
run div        main       "$(read_expected div)"
run nested     main       "$(read_expected nested)"
run closure    main       "$(read_expected closure)"
run applytwice main       "$(read_expected applytwice)"
run countdown  countdown  "$(read_expected countdown)"  100000
run eqlist     main       "$(read_expected eqlist)"
run const      answer     "$(read_expected const)"
run partial    main       "$(read_expected partial)"
run subpartial main       "$(read_expected subpartial)"
run overapply  main       "$(read_expected overapply)"
run curry      main       "$(read_expected curry)"
run opvalue    main       "$(read_expected opvalue)"
run crossref   main       "$(read_expected crossref)"
run selfqual   main       "$(read_expected selfqual)"
compile_error dup         "duplicate top-level definition: f"

rm -rf "$OUT"
echo "=============================="
echo "PASS=$pass FAIL=$fail"
exit $((fail>0?1:0))
