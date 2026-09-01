#!/usr/bin/env bash
# aot-build — 'elm make' for native binaries: one command from an .elm app to
# a self-contained executable.
#
#   aot-build.sh <app.elm> [-o <out-bin>] [--entry <Module>.main]
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
# Prereqs (from the repo root): cd elm-compiler && ./build.sh   (once)
#                               zig build aotdump                 (once)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

usage() {
  echo "usage: aot-build.sh <app.elm> [-o <out-bin>] [--entry <Module>.main]" >&2
  exit 2
}

app=""
out=""
entry=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) [ $# -ge 2 ] || usage; out="$2"; shift 2 ;;
    --entry) [ $# -ge 2 ] || usage; entry="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "aot-build: unknown option: $1" >&2; usage ;;
    *) [ -z "$app" ] || { echo "aot-build: one .elm app per build (got '$app' and '$1')" >&2; exit 2; }
       app="$1"; shift ;;
  esac
done
[ -n "$app" ] || usage
[ -f "$app" ] || { echo "aot-build: no such file: $app" >&2; exit 2; }

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
node "$ROOT/elm-compiler/run.js" "$app_abs" "$work/bundle.csexp" 1>/dev/null

# 2. csexp -> generated Zig (aotdump, transitive closure + embedded bundle).
"$ROOT/zig-out/bin/aotdump" "$work/bundle.csexp" "$entry" -o "$work/gen.zig"

# 3. Build gen.zig + the generic driver (tools/aot/run.zig) into a native exe.
#    A tiny build.zig wires the modules exactly like build.zig's addAotApp.
mkdir -p "$work/out"
cat > "$work/build.zig" <<'BZ'
const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });
    const gc_mod = b.createModule(.{ .root_source_file = b.path("vendor/zinc-vm/src/gc.zig"), .target = target, .optimize = optimize });
    const vm_mod = b.createModule(.{ .root_source_file = b.path("vendor/zinc-vm/src/vm.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gc", .module = gc_mod }} });
    const aotrt_mod = b.createModule(.{ .root_source_file = b.path("tools/aot/runtime.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "gc", .module = gc_mod }, .{ .name = "vm", .module = vm_mod }} });
    const gen_mod = b.createModule(.{ .root_source_file = b.path("gen.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "gc", .module = gc_mod }, .{ .name = "vm", .module = vm_mod }, .{ .name = "runtime.zig", .module = aotrt_mod }} });
    const effectloop_mod = b.createModule(.{ .root_source_file = b.path("src/effectloop.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "gc", .module = gc_mod }, .{ .name = "vm", .module = vm_mod }} });
    const exe_mod = b.createModule(.{ .root_source_file = b.path("tools/aot/run.zig"), .target = target, .optimize = optimize, .link_libc = true, .imports = &.{.{ .name = "gc", .module = gc_mod }, .{ .name = "vm", .module = vm_mod }, .{ .name = "runtime.zig", .module = aotrt_mod }, .{ .name = "aot_gen", .module = gen_mod }, .{ .name = "effectloop", .module = effectloop_mod }} });
    const exe = b.addExecutable(.{ .name = "aot-app", .root_module = exe_mod });
    b.installArtifact(exe);
}
BZ
# run the build from a dir where gen.zig is reachable: symlink gen.zig + build.zig into the work root.
cp "$work/build.zig" "$ROOT/aot-build-build.zig"
ln -sf "$work/gen.zig" "$ROOT/gen.zig"
( cd "$ROOT" && zig build --build-file aot-build-build.zig --prefix "$work/out" )
rm -f "$ROOT/aot-build-build.zig" "$ROOT/gen.zig"

mkdir -p "$(dirname "$out")"
cp "$work/out/bin/aot-app" "$out"
chmod +x "$out"
echo "aot-build: done -> $out (self-contained; run: $out)"
