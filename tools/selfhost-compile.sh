#!/usr/bin/env bash
# selfhost-compile.sh — M16: compile the compiler's OWN 56 sources (the
# selfhost group) as ONE multi-module group into a csexp bundle.
#
# This is the "the compiler compiles itself" step: the stock-built compiler
# (node elm-compiler/run.js --batch, i.e. elm-compiler/compiler.js built by
# STOCK elm 0.19.2 + the run.js batch driver) compiles
# elm-compiler/selfhost/manifest.json — the 14 compiler frontend sources
# (src/{Lower,Type,Zinc}) + the 38 vendored parse-closure files + NativeMain —
# TOGETHER with the fixed corpus (Prelude + Runtime + the core-libs), in one
# process, into zig-out/selfhost.csexp.
#
# That bundle IS the compiler, expressed as a csexp program whose entry is
# NativeMain.main (M15's node-free driver).  A native binary built FROM this
# bundle (tools/selfhost-gate.sh) is the self-compiled compiler.
#
# Usage: tools/selfhost-compile.sh [out.csexp]
# Exit:  0 on success (non-empty, no "err " payload); 2 on tooling failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CDIR="$ROOT/elm-compiler"
MANIFEST="$CDIR/selfhost/manifest.json"
OUT="${1:-$ROOT/zig-out/selfhost.csexp}"

command -v node >/dev/null 2>&1 || { echo "selfhost-compile: node not found" >&2; exit 2; }
[ -f "$CDIR/compiler.js" ] || {
  echo "selfhost-compile: elm-compiler/compiler.js missing (run elm-compiler/build.sh once)" >&2
  exit 2
}
[ -f "$MANIFEST" ] || { echo "selfhost-compile: manifest missing: $MANIFEST" >&2; exit 2; }

# run.js resolves manifest source paths against its process CWD, so the
# manifest's repo-root-relative paths require running from the repo root.
mkdir -p "$(dirname "$OUT")"
(
  cd "$ROOT"
  node "$CDIR/run.js" --batch "$MANIFEST" 2>/dev/null
) || { echo "selfhost-compile: node run.js --batch failed" >&2; exit 1; }

# ---- verify the bundle is a real compile, not an error payload ----
[ -s "$OUT" ] || { echo "selfhost-compile: $OUT is empty (run.js produced no output)" >&2; exit 1; }
if head -c 4 "$OUT" | grep -q '^err '; then
  echo "selfhost-compile: $OUT is an err payload: $(head -c 200 "$OUT")" >&2
  exit 1
fi

bytes=$(wc -c < "$OUT")
echo "selfhost-compile: wrote $OUT ($bytes bytes)"
