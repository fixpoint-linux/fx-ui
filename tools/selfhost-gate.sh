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
#   SELFHOST_OPT        zig optimize mode (default ReleaseFast — see below)
#   SELFHOST_BIN        skip the build and use this existing compiler binary
#
# Optimize mode: the full selfhost closure is ~1550 AOT units -> an ~800K-line
# gen.zig.  -Doptimize=Debug builds that in ~12s but runs ~10x slower;
# ReleaseFast takes ~7 minutes of one-time LLVM work.  The gate now runs the
# WHOLE fixture manifest in ONE process (see step 4), so the RUN dominates:
# ~55 min ReleaseFast vs ~9 h Debug, i.e. the 7-min build pays for itself many
# times over.  ReleaseFast is therefore the default.  Use Debug only for a
# quick syntax/debug pass on a reduced fixture set.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELFHOST_CSEXP="$ROOT/zig-out/selfhost.csexp"
OPT="${SELFHOST_OPT:-ReleaseFast}"
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

# selfhost: translate the JSON manifest to NativeMain's line format (one
# source path per line, terminated by '-> <output>') and run the SELF-COMPILED
# compiler on it.  The driver contract (tools/elmc.sh, tools/aot/run.zig) is
# the M15 one: AOTRUN_ARGV hands the manifest path to NativeMain as *argv*,
# AOTRUN_QUIET keeps the driver's final printValue off stdout.
#
# THE WHOLE MANIFEST IN ONE PROCESS.  Lower.Module.compileBatch parses,
# typechecks and lowers the fixed corpus ONCE per process, then compiles each
# group against it; the corpus pass is the entire cost (~30 min, and it
# dominates a fixture's own compile, which is ~10 s).  Running one process per
# group therefore REPEATS the corpus pass 121 times.  One process for the whole
# manifest pays it once: MEASURED 121 groups in 55 min, vs 121x ~30 min (~13 h
# even at -P 10).  Compile failures land in the group's own output path as
# "err <msg>" (run.js parity) and the cmp loop below reports them as FAIL.
#
# Two budgets must be lifted for the whole-batch entry:
#   * ELMC_HEAP_MB — the corpus + all groups have a multi-GB live set; 8 GB
#     lets the GC keep collecting (1.5 GB thrashes).
#   * ZINCVM_INSTR_LIMIT — the VM's hard per-entry budget defaults to 5e9, and
#     the whole batch is ONE entry that legitimately exceeds it, aborting with
#     "[HARD LIMIT] ... aborting" and writing no outputs.  (AOT_NAT_DEPTH is
#     NOT relevant to this: Type.Infer.inferExpr is left INTERPRETED by aotdump
#     — its value stack exceeds the 256-slot static limit — so it runs in
#     interp.vmExecEnv regardless of the native-depth cap.)
#
# Outputs are keyed on the group INDEX: the manifest reuses output basenames
# (e.g. `sub` is registered twice), so a basename-keyed manifest would have
# groups overwrite each other and cmp the wrong bytes.
jq -r --arg d "$tmp/self" \
  '.groups | to_entries[] | (.value.sources[] | .), "-> " + ($d + "/g" + (.key|tostring) + ".csexp")' \
  "$MANIFEST" > "$tmp/self.manifest"

echo "selfhost-gate: compiling $ngroup groups via the SELF-COMPILED compiler (one process)"
AOTRUN_ARGV=1 AOTRUN_QUIET=1 \
  ELMC_HEAP_MB="${ELMC_HEAP_MB:-8000}" \
  ZINCVM_INSTR_LIMIT="${ZINCVM_INSTR_LIMIT:-1000000000000}" \
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
