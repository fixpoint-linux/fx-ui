#!/usr/bin/env bash
# elmc.sh — thin CLI wrapper for the aot-built elmc compiler binary (M15).
#
#   elmc <input1.elm> [input2.elm ...] <output.csexp>
#   elmc <manifest>            (line format: sources one per line, each
#                                group terminated by '-> <out.csexp>')
#
# Builds zig-out/bin/elmc from the selfhost group (NativeMain + the compiler
# frontend, via aot-build.sh --group) on first use, then runs it with the
# driver's argv plumbing enabled:
#   AOTRUN_ARGV=1   the binary's arguments reach NativeMain as Runtime.argv ()
#   AOTRUN_QUIET=1  the driver's final model print is suppressed (clean stdout)
#
# Byte-for-byte parity with `node elm-compiler/run.js ...` is the contract
# (same corpus order, same Lower.Module.compileBatch, same output bytes).
#
# Env:
#   ELMC_BIN   use this prebuilt binary instead of (re)building
#   ELMC_HEAP_MB  heap override for the compiler binary (big groups)
#   ELMC_SKIP_BUILD=1  fail loudly instead of building when ELMC_BIN is unset
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${ELMC_BIN:-$ROOT/zig-out/bin/elmc}"

# Global zig cache off the cramped /home onto the pool (see aot-build.sh).
: "${ZIG_GLOBAL_CACHE_DIR:=$ROOT/.zig-cache-global}"
export ZIG_GLOBAL_CACHE_DIR
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

if [ ! -x "$BIN" ]; then
  if [ "${ELMC_SKIP_BUILD:-0}" = "1" ]; then
    echo "elmc: no binary at $BIN (set ELMC_BIN or drop ELMC_SKIP_BUILD)" >&2
    exit 2
  fi
  echo "elmc: building $BIN (aot-build NativeMain + selfhost group)..." >&2
  # ELMC_BUILD_MODE: -O for aot-build.  Default ReleaseFast: the compiler is a
  # binary you RUN (often repeatedly), and a Debug build is ~10x slower at
  # runtime (it is the whole point of elmc to be usable); the one-time ~9 min
  # LLVM cost on the full-closure gen.zig is worth it.  Set
  # ELMC_BUILD_MODE=Debug only for a quick syntax/debug build.
  "$ROOT/tools/aot/aot-build.sh" \
    "$ROOT/elm-compiler/selfhost/NativeMain.elm" \
    --group "$ROOT/elm-compiler/selfhost/manifest.json" \
    --entry NativeMain.main \
    -O "${ELMC_BUILD_MODE:-ReleaseFast}" \
    -o "$BIN"
fi

export AOTRUN_ARGV=1
export AOTRUN_QUIET=1

# ELMC_HEAP_MB — the compiler's GC heap.  Measured on the corpus compile
# (2026-10-02): time SCALES WITH HEAP SIZE because a nursery scavenge walks the
# old-gen live set (O(heap)), so a smaller heap is faster.  Curve (one corpus
# compile): 1000MB=25m35s (past the knee — full collects thrash), 1500MB=21m31s
# (fastest), 2000MB=22m05s, 4000MB=25m58s, 8000MB=~35m, 16000MB=62m.  2000 sits
# just above the ~1500MB knee with headroom for large groups — the previous
# hard-coded 8000 was ~40% slower.  Override for a bigger/smaller working set.
export ELMC_HEAP_MB="${ELMC_HEAP_MB:-2000}"

exec "$BIN" "$@"
