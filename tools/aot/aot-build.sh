#!/usr/bin/env bash
# aot-build — 'elm make' for native binaries: one command from an .elm app to
# a self-contained executable.
#
#   aot-build.sh <app.elm> [-o <out-bin>] [--entry <Module>.main] [-O <mode>] \
#               [--group <manifest.json>] [--flags '<env=v ...>']
#
# Pipeline (run directly, not through the zig build graph — the build-graph
# node/aotdump steps trip a zig "failed command" quirk even when the command
# succeeds):
#   1. the `module <Name> exposing (...)` declaration names the entry
#      (<Name>.main, unless --entry overrides it)
#   2. node elm-compiler/run.js compiles the app to a csexp bundle
#   3. aotdump transitively AOT-dumps the entry closure to gen.zig, embedding
#      the bundle text
#   4. the generated gen.zig + the generic driver (tools/aot/run.zig) link
#      into <out-bin> — a native binary that runs with NO arguments, anywhere
#      (the bundle lives inside it).
#
# --group <manifest.json>: compile the WHOLE multi-module group named by the
#   run.js batch manifest (first group's sources, in file order) instead of
#   the single .elm app — for apps whose entry lives in a group of mutually
#   referencing modules (NativeMain + the selfhost frontend).
# --flags '<env=v ...>': extra env for the BUILT binary's runtime contract —
#   currently AOTRUN_ARGV (argv pseudo-global), AOTRUN_QUIET (clean stdout),
#   ELMC_HEAP_MB (heap override) are passed by the WRAPPER (tools/elmc.sh),
#   not baked here; this flag is reserved for future baking.
#
# Prereqs (from the repo root): cd elm-compiler && ./build.sh   (once)
#                               zig build aotdump                 (once)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# The LOCAL zig cache (repo .zig-cache) already lives on the big ZFS pool with
# the repo, so it needs no redirect.  Only the GLOBAL cache (~/.cache/zig) sits
# on the cramped /home that MicroOS snapshots fill — point it into the repo (=
# pool) unless the caller overrides ZIG_GLOBAL_CACHE_DIR.
: "${ZIG_GLOBAL_CACHE_DIR:=$ROOT/.zig-cache-global}"
export ZIG_GLOBAL_CACHE_DIR
mkdir -p "$ZIG_GLOBAL_CACHE_DIR"

usage() {
  echo "usage: aot-build.sh <app.elm> [-o <out-bin>] [--entry <Module>.main] [-O <mode>]" >&2
  echo "  -O <mode>    zig optimize mode: Debug|ReleaseSafe|ReleaseFast|ReleaseSmall (default ReleaseFast)" >&2
  exit 2
}

app=""
out=""
entry=""
optimize="ReleaseFast"
group=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) [ $# -ge 2 ] || usage; out="$2"; shift 2 ;;
    --entry) [ $# -ge 2 ] || usage; entry="$2"; shift 2 ;;
    -O) [ $# -ge 2 ] || usage; optimize="$2"; shift 2 ;;
    --group) [ $# -ge 2 ] || usage; group="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "aot-build: unknown option: $1" >&2; usage ;;
    *) [ -z "$app" ] || { echo "aot-build: one .elm app per build (got '$app' and '$1')" >&2; exit 2; }
       app="$1"; shift ;;
  esac
done
if [ -n "$group" ]; then
  [ -n "$app" ] || { echo "aot-build: --group needs the entry .elm (read for its module header)" >&2; exit 2; }
  [ -f "$group" ] || { echo "aot-build: no such group manifest: $group" >&2; exit 2; }
fi
[ -n "$app" ] || usage
[ -f "$app" ] || { echo "aot-build: no such file: $app" >&2; exit 2; }
case "$optimize" in
  Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
  *) echo "aot-build: invalid optimize mode: $optimize (want Debug|ReleaseSafe|ReleaseFast|ReleaseSmall)" >&2; exit 2 ;;
esac

# The entry module from the `module <Name> exposing (...)` declaration.
app_abs="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
mod="$(sed -n 's/^[[:space:]]*module[[:space:]]\{1,\}\([A-Za-z0-9_]\{1,\}\)[[:space:]].*/\1/p' "$app_abs" | head -n1)"
if [ -z "$mod" ]; then
  echo "aot-build: no 'module <Name> exposing (...)' declaration in $app" >&2
  exit 2
fi
[ -n "$entry" ] || entry="$mod.main"

# Default output: the module name, lowercased, next to the source.
[ -n "$out" ] || out="$(dirname "$app_abs")/$(printf '%s' "$mod" | tr 'A-Z' 'a-z')"

# Zig artifact names are [A-Za-z0-9_-]; the final binary is placed at $out.
# (bin_name unused in the direct pipeline; kept for reference)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "aot-build: $app ($entry) -> $out"

# 1. Elm -> csexp bundle.
#    --group: compile the whole multi-module group (the app + its sibling
#    modules from the run.js batch manifest) as ONE unit so cross-module
#    references resolve through the merged global table.
if [ -n "$group" ]; then
  # Dedupe: the entry module may already be one of the group's sources.
  jq --arg app "$app_abs" --arg out "$work/bundle.csexp" \
     '{groups: [ .groups[0] | .sources = ((.sources + [$app]) | unique) | .output = $out ]}' \
     "$group" > "$work/group.json"
  node "$ROOT/elm-compiler/run.js" --batch "$work/group.json" 1>/dev/null
else
  node "$ROOT/elm-compiler/run.js" "$app_abs" "$work/bundle.csexp" 1>/dev/null
fi

# 2. csexp -> generated Zig (aotdump, transitive closure + embedded bundle).
"$ROOT/zig-out/bin/aotdump" "$work/bundle.csexp" "$entry" -o "$work/gen.zig"

# 3. Build gen.zig + the generic driver (tools/aot/run.zig) into a native exe.
#    A tiny build.zig wires the modules exactly like build.zig's addAotApp.
mkdir -p "$work/out"
cat > "$work/build.zig" <<'BZ'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // A shipped app must not pay for the per-block instruction counter (it is
    // ~4% of runtime and nothing reads it here).  `-Dcount-instrs=true` opts
    // back in for a profiling build.
    const count_instrs_opt = b.option(bool, "count-instrs", "AOT: emit the per-block instruction counter") orelse false;
    const count_instrs = b.addOptions();
    count_instrs.addOption(bool, "count_instrs", count_instrs_opt);
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
# run the build from a dir where gen.zig is reachable: symlink gen.zig + build.zig into the work root.
cp "$work/build.zig" "$ROOT/aot-build-build.zig"
ln -sf "$work/gen.zig" "$ROOT/gen.zig"
( cd "$ROOT" && zig build --build-file aot-build-build.zig --prefix "$work/out" -Doptimize="$optimize" )
rm -f "$ROOT/aot-build-build.zig" "$ROOT/gen.zig"

mkdir -p "$(dirname "$out")"
cp "$work/out/bin/aot-app" "$out"
chmod +x "$out"
echo "aot-build: done -> $out (self-contained; run: $out)"
