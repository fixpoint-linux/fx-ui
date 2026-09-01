#!/usr/bin/env bash
# tools/aot/spike.sh — AOT-to-Zig spike verification runner.
#
# Proves the spike end-to-end:
#   1. correctness: elmvm vs aotbench stdout is byte-identical (all 3 fixtures)
#   2. tail calls:  countdown 100000 under `ulimit -s 1024` (constant native stack)
#   3. speed:       vmbench --secs=3 vs aotbench --secs=3 (ns/iter + ns/instr)
#   4. GC rooting:  biglist under a minimal heap in DEBUG (root-balance asserts +
#      verify_collects precise-root contract live) — built LAST so the
#      ReleaseFast speed table runs first (no redundant mode rebuild).
#
# Usage: tools/aot/spike.sh   (from the repo root)
# Exit 0 iff every check passes.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

pass=0; fail=0
note() { echo "  $*"; }
ok()   { echo "PASS $*"; pass=$((pass+1)); }
bad()  { echo "FAIL $*"; fail=$((fail+1)); }

echo "== build ReleaseFast tools + spike exes =="
for step in aotdump elmvm vmbench aot; do
  if zig build "$step" >/dev/null 2>&1; then
    note "built $step"
  else
    bad "build $step"; break
  fi
done

echo "== compile fixtures (node run.js) =="
for f in fib countdown biglist; do
  node elm-compiler/run.js "tests/elm-fixtures/$f.elm" "$OUT/$f.csexp" 2>/dev/null
  [ -s "$OUT/$f.csexp" ] && note "compiled $f.csexp" || bad "compile $f"
done

echo "== 1. correctness: elmvm vs aotbench (byte-identical stdout) =="
check_diff() { # name fn args...
  local name="$1"; shift
  local fn="$1"; shift
  local elm aot
  elm="$(./zig-out/bin/elmvm "$OUT/$name.csexp" "$fn" "$@" 2>/dev/null)"
  aot="$(./zig-out/bin/aotbench-$name "$OUT/$name.csexp" "$fn" "$@" 2>/dev/null)"
  if [ "$elm" = "$aot" ] && [ -n "$elm" ]; then
    ok "$name ($fn $*) -> $elm"
  else
    bad "$name ($fn $*): elmvm[$elm] != aotbench[$aot]"
  fi
}
check_diff fib        Fib.fib           30
check_diff countdown  Countdown.countdown 100000
check_diff biglist    BigList.main

echo "== 2. tail calls: countdown 100000 under ulimit -s 1024 =="
if ( ulimit -s 1024; got="$(./zig-out/bin/aotbench-countdown "$OUT/countdown.csexp" Countdown.countdown 100000 2>/dev/null)"; [ "$got" = "0" ] ); then
  ok "countdown 100000 constant native stack (ulimit -s 1024)"
else
  bad "countdown 100000 blew the 1MB native stack"
fi

echo "== 3. speed: vmbench vs aotbench (--secs=3) =="
speed() { # name fn args...
  local name="$1"; shift
  local fn="$1"; shift
  local vm_iter aot_iter
  # bench stats (iterations:) are printed to STDERR via std.debug.print.
  vm_iter=$(./zig-out/bin/vmbench "$OUT/$name.csexp" "$fn" --secs=3 "$@" 2>&1 | awk '/iterations:/{print $2}')
  aot_iter=$(./zig-out/bin/aotbench-$name "$OUT/$name.csexp" "$fn" --secs=3 "$@" 2>&1 | awk '/iterations:/{print $2}')
  if [ -n "$vm_iter" ] && [ -n "$aot_iter" ] && [ "$aot_iter" -gt 0 ] 2>/dev/null; then
    local ratio
    ratio=$(awk -v a="$aot_iter" -v v="$vm_iter" 'BEGIN{printf "%.1f", a/v}')
    printf "  %-12s vmbench %8s iters  aotbench %8s iters  speedup %sx\n" "$name" "$vm_iter" "$aot_iter" "$ratio"
  else
    bad "speed $name (missing iterations)"
  fi
}
speed fib       Fib.fib           30
speed countdown Countdown.countdown 100000
speed biglist   BigList.main

echo "== 4. GC rooting: biglist Debug --heap=16 (root-balance + precise-root) =="
zig build aot -Doptimize=Debug >/dev/null 2>&1 || bad "build aot Debug"
got="$(./zig-out/bin/aotbench-biglist "$OUT/biglist.csexp" BigList.main --heap=16 2>/dev/null)"
if [ "$got" = "2003000" ]; then
  ok "biglist Debug --heap=16 pressure-clean -> $got"
else
  bad "biglist Debug pressure: got[$got] (crashed or wrong)"
fi

echo "=============================="
echo "PASS=$pass FAIL=$fail"
exit $((fail > 0 ? 1 : 0))
