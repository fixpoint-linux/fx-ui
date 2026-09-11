#!/usr/bin/env bash
# selfhost-gate.sh — M16: byte-identical fixture equivalence between the
# SELF-COMPILED compiler and the STOCK compiler.
#
# The M16 proof, end to end:
#   1. tools/selfhost-compile.sh -> zig-out/selfhost.csexp
#      (the compiler's own 56 sources compiled AS ONE group by the stock-built
#       compiler — "the compiler compiles itself", first time).
#   2. aotdump selfhost.csexp NativeMain.main -> gen.zig
#      (transitively AOT-dumps the entry closure, embedding the bundle text).
#   3. zig build gen.zig + tools/aot/run.zig -> a native binary whose entry is
#      the SELF-COMPILED compiler (NOT the stock-compiled NativeMain that
#      tools/elmc.sh builds — that is M15's stock-frontend proof; this is the
#      self-hosted one).
#   4. For every gate fixture group: compile via that binary AND via
#      node run.js; cmp each .csexp byte-for-byte.
#
# DONE iff: selfhost.csexp is non-empty and not an "err " payload, AND every
# fixture's selfhost-compiled .csexp is cmp-identical to the stock-compiled one.
#
# Fixture groups are REUSED from tests/elm-fixtures/run-elm-gate.sh (its
# ELM_GATE_MANIFEST_ONLY=1 manifest), so the gate compares exactly the groups
# the 118-check gate compiles — not a hand-picked subset.
#
# Usage: tools/selfhost-gate.sh
# Env:
#   SELFHOST_OPT        zig optimize mode (default Debug — see below)
#   SELFHOST_BIN        skip the build and use this existing compiler binary
#
# Optimize mode: the full selfhost closure is ~1550 AOT units -> an ~800K-line
# gen.zig.  -Doptimize=Debug builds that in ~12s; ReleaseSmall/ReleaseFast take
# 11+ minutes (one-time LLVM cost).  This is a CORRECTNESS gate, not a perf
# benchmark, so Debug is the default.  Override SELFHOST_OPT for a perf run.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELFHOST_CSEXP="$ROOT/zig-out/selfhost.csexp"
OPT="${SELFHOST_OPT:-Debug}"
ENTRY="NativeMain.main"

command -v node >/dev/null 2>&1 || { echo "selfhost-gate: node not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "selfhost-gate: jq required" >&2; exit 2; }
[ -x "$ROOT/zig-out/bin/aotdump" ] || { echo "selfhost-gate: zig-out/bin/aotdump missing (zig build aotdump)" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# ============================ 1. the bundle ============================
# (re)compile the selfhost group; selfhost-compile.sh fails loudly if the
# bundle is empty or an err payload — the first half of M16's DONE criterion.
"$ROOT/tools/selfhost-compile.sh" "$SELFHOST_CSEXP"

# ==================== 2/3. native binary from the bundle ====================
# Only when SELFHOST_BIN is not pinned: aotdump the selfhost bundle, then build
# gen.zig + the generic driver into a native binary whose entry is the
# SELF-COMPILED compiler.
if [ -z "${SELFHOST_BIN:-}" ]; then
  echo "selfhost-gate: aotdump $SELFHOST_CSEXP $ENTRY -> gen.zig"
  "$ROOT/zig-out/bin/aotdump" "$SELFHOST_CSEXP" "$ENTRY" -o "$tmp/gen.zig"

  # build.zig: the generic AOT app wiring PLUS the gui/terminal imports the
  # effect loop needs (the copy in aot-build.sh predates them and no longer
  # links — see M16 broadcast).  Kept self-contained here; aot-build.sh is not
  # touched.
  cat > "$tmp/build.zig" <<'BZ'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Shipped/driver binary: the per-block instruction counter is OFF (~4% of
    // runtime, and nothing here reads it).
    const count_instrs = b.addOptions();
    count_instrs.addOption(bool, "count_instrs", false);
    const gc_mod = b.createModule(.{ .root_source_file = b.path("vendor/zinc-vm/src/gc.zig"), .target = target, .optimize = optimize });
    const vm_mod = b.createModule(.{ .root_source_file = b.path("vendor/zinc-vm/src/vm.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gc", .module = gc_mod }} });
    const aotrt_mod = b.createModule(.{ .root_source_file = b.path("tools/aot/runtime.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gc", .module = gc_mod }, .{ .name = "vm", .module = vm_mod }} });
    aotrt_mod.addOptions("count_instrs", count_instrs);
    const gui_model_mod = b.createModule(.{ .root_source_file = b.path("src/renderer/gui.zig"), .target = target, .optimize = optimize });
    const terminal_mod = b.createModule(.{ .root_source_file = b.path("src/renderer/terminal.zig"), .target = target, .optimize = optimize });
    terminal_mod.addImport("gui_model", gui_model_mod);
    const gui_backend_mod = b.createModule(.{ .root_source_file = b.path("src/renderer/gui_stub.zig"), .target = target, .optimize = optimize, .link_libc = true });
    gui_backend_mod.addImport("gui_model", gui_model_mod);
    const gen_mod = b.createModule(.{ .root_source_file = b.path("gen.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "gc", .module = gc_mod }, .{ .name = "vm", .module = vm_mod }, .{ .name = "runtime.zig", .module = aotrt_mod }} });
    const effectloop_mod = b.createModule(.{ .root_source_file = b.path("src/effectloop.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "gc", .module = gc_mod }, .{ .name = "vm", .module = vm_mod }, .{ .name = "gui_model", .module = gui_model_mod }, .{ .name = "gui_backend", .module = gui_backend_mod }, .{ .name = "terminal", .module = terminal_mod }} });
    const exe_mod = b.createModule(.{ .root_source_file = b.path("tools/aot/run.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "gc", .module = gc_mod }, .{ .name = "vm", .module = vm_mod }, .{ .name = "runtime.zig", .module = aotrt_mod }, .{ .name = "aot_gen", .module = gen_mod }, .{ .name = "effectloop", .module = effectloop_mod }} });
    const exe = b.addExecutable(.{ .name = "aot-app", .root_module = exe_mod });
    b.installArtifact(exe);
}
BZ
  cp "$tmp/build.zig" "$ROOT/selfhost-gate-build.zig"
  ln -sf "$tmp/gen.zig" "$ROOT/gen.zig"
  echo "selfhost-gate: zig build (-Doptimize=$OPT)"
  ( cd "$ROOT" && zig build --build-file selfhost-gate-build.zig --prefix "$tmp/out" -Doptimize="$OPT" )
  rm -f "$ROOT/selfhost-gate-build.zig" "$ROOT/gen.zig"
  BIN="$tmp/out/bin/aot-app"
else
  BIN="$SELFHOST_BIN"
  [ -x "$BIN" ] || { echo "selfhost-gate: SELFHOST_BIN not executable: $BIN" >&2; exit 2; }
fi

# ==================== 4. fixture equivalence ====================
# Reuse the gate's fixture groups (exact sources, in declaration order) via
# run-elm-gate.sh's manifest-only mode.  The manifest lives in a leaked temp
# dir (run-elm-gate.sh exits before its cleanup), so it stays readable here.
MANIFEST="$(ELM_GATE_MANIFEST_ONLY=1 "$ROOT/tests/elm-fixtures/run-elm-gate.sh")"
[ -f "$MANIFEST" ] || { echo "selfhost-gate: run-elm-gate.sh produced no manifest" >&2; exit 2; }

ngroup="$(jq '.groups | length' "$MANIFEST")"
[ "$ngroup" -gt 0 ] || { echo "selfhost-gate: manifest has no groups" >&2; exit 2; }
echo "selfhost-gate: $ngroup fixture groups"

# Disjoint per-group-index outputs so stock and selfhost never overwrite each
# other (the manifest itself reuses output paths, e.g. `sub` is registered
# twice, so we key on the group INDEX, not the output basename).
mkdir -p "$tmp/stock" "$tmp/self"
jq -c --arg d "$tmp/stock" '
  .groups = [ .groups | to_entries[] | .value.output = ($d + "/g" + (.key|tostring) + ".csexp") | .value ]
' "$MANIFEST" > "$tmp/stock-manifest.json"
jq -c --arg d "$tmp/self" '
  .groups = [ .groups | to_entries[] | .value.output = ($d + "/g" + (.key|tostring) + ".csexp") | .value ]
' "$MANIFEST" > "$tmp/self-manifest.json"

# stock reference: node run.js --batch over the same groups
echo "selfhost-gate: compiling $ngroup groups via stock (node run.js --batch)"
node "$ROOT/elm-compiler/run.js" --batch "$tmp/stock-manifest.json" 2>/dev/null

# selfhost: translate the JSON manifest to NativeMain's line format
# (one source path per line; each group terminated by '-> <output>') and run
# the SELF-COMPILED compiler on it.
jq -r '.groups[] | (.sources[] | .), "-> " + .output' "$tmp/self-manifest.json" > "$tmp/self.manifest"
echo "selfhost-gate: compiling $ngroup groups via the selfhost binary"
# M15 CONTRACT (handoff-elm-native-boot-plan M15): the compiler binary takes the
# manifest path as argv[1]; NativeMain reads it (via the *argv* pseudo-global
# run.zig installs / the Runtime.argv reader), Io.readFile's each source, calls
# Lower.Module.compileBatch, and Io.writeFile's each group to its '-> out' path.
# Compile failures land in the group's output path as "err <msg>" (run.js
# parity); adjust if M15's NativeMain routes errors to a sibling .err instead.
"$BIN" "$tmp/self.manifest"

# ---- cmp every group: selfhost .csexp vs stock .csexp, byte-for-byte ----
pass=0; fail=0
for ((i=0; i<ngroup; i++)); do
  s="$tmp/stock/g$i.csexp"
  h="$tmp/self/g$i.csexp"
  src="$(jq -r ".groups[$i].sources[0]" "$MANIFEST" | xargs basename)"
  if [ -s "$h" ] && cmp -s "$h" "$s"; then
    echo "PASS g$i ($src)"
    pass=$((pass+1))
  else
    echo "FAIL g$i ($src): selfhost != stock"
    fail=$((fail+1))
  fi
done

echo "=============================="
echo "selfhost-gate: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
