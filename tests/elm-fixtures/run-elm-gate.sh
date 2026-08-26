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

# Derive a fixture's Elm MODULE NAME by scanning its `module X ...` header.
module_name() {
  awk '/^module /{print $2; exit}' "$1"
}

# run <name> <fn> <expected> [args...]
#
# Entry resolution: since M3 keys defuns under QUALIFIED names ("<Mod>.<fn>",
# e.g. "Fib.fib"), the runner first calls "<Mod>.<fn>" with the module name
# scanned from the fixture header; bundles from older-style/anonymous content
# still fall back to the bare name.
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
  local mod qname got
  mod=$(module_name "$FIX/$name.elm")
  qname="$mod.$fn"
  got=$("$ELMVM" "$OUT/$name.csexp" "$qname" "$@" 2>&1)
  if [ "$got" != "unknown global: $qname" ] && [ "$got" != "unknown name: $qname" ]; then
    if [ "$got" = "$exp" ]; then
      echo "PASS $name ($qname $*) -> $got"; pass=$((pass+1))
    else
      echo "FAIL $name ($qname $*): exp[$exp] got[$got]"; fail=$((fail+1))
    fi
    return
  fi
  # fallback to the bare fn name (legacy single-module bundles)
  got=$("$ELMVM" "$OUT/$name.csexp" "$fn" "$@" 2>&1)
  if [ "$got" = "$exp" ]; then
    echo "PASS $name ($fn $*) -> $got"; pass=$((pass+1))
  else
    echo "FAIL $name ($fn $*): exp[$exp] got[$got]"; fail=$((fail+1))
  fi
}

# run2 <name> <auxname> <fn> <expected>: multi-module fixture — compile
# <aux>.elm TOGETHER WITH <name>.elm (cross-module import); entry is looked
# up under "<NameModule>.<fn>" scanned from the MAIN fixture header.
run2() {
  local name="$1" aux="$2" fn="$3" exp="$4"; shift 4
  node "$CDIR/run.js" "$FIX/$aux.elm" "$FIX/$name.elm" "$OUT/$name.csexp" 2>/dev/null
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "FAIL $name: node run.js rc=$rc"; fail=$((fail+1)); return
  fi
  if head -c 4 "$OUT/$name.csexp" | grep -q '^err '; then
    echo "FAIL $name: compile error: $(cat "$OUT/$name.csexp")"; fail=$((fail+1)); return
  fi
  local mod got
  mod=$(module_name "$FIX/$name.elm")
  got=$("$ELMVM" "$OUT/$name.csexp" "$mod.$fn" "$@" 2>&1)
  if [ "$got" = "$exp" ]; then
    echo "PASS $name ($mod.$fn multi) -> $got"; pass=$((pass+1))
  else
    echo "FAIL $name ($mod.$fn multi): exp[$exp] got[$got]"; fail=$((fail+1))
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
# --- M2: case/pattern compiler, ADTs, records, short-circuit ---
run listcase    main       "$(read_expected listcase)"
run adteval     main       "$(read_expected adteval)"
run adtcase     main       "$(read_expected adtcase)"
run letcase     main       "$(read_expected letcase)"
run countcase   main       "$(read_expected countcase)"
run patterns    main       "$(read_expected patterns)"
run boolcase    main       "$(read_expected boolcase)"
run records     main       "$(read_expected records)"
run shortcircuit main      "$(read_expected shortcircuit)"
# --- M3: prelude (List API over 1000 elems), strings, multi-module ---
run biglist    main       "$(read_expected biglist)"
run strings    main       "$(read_expected strings)"
run2 multimod  auxlib     main       "$(read_expected multimod)"
compile_error dup         "duplicate top-level definition in Dup: f"

rm -rf "$OUT"
echo "=============================="
echo "PASS=$pass FAIL=$fail"
exit $((fail>0?1:0))
