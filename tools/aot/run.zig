//! tools/aot/run.zig — the generic AOT program driver (what aot-build links).
//!
//! elmvm-shaped CLI (the pty gate harness drives it unchanged):
//!   <bin> [bundle.csexp] [fn-name]
//!
//! The bundle and the entry are both baked at aot-build time: aotdump embeds
//! the bundle text (pub const bundle) and emits the baked entry (aotEntry), so
//! `<bin>` with NO arguments is the self-contained native binary.  Passing a
//! bundle path overrides the embedded copy (ptytest / byte-diff symmetry with
//! elmvm); fn-name is accepted for CLI symmetry and ignored, exactly like
//! aotbench's.
//!
//! Loads the bundle, runs the generated aotInit (consts + globals cache +
//! registry), runs the baked entry (aotEntry) to obtain the Program value,
//! installs the aotrt.applyHost dispatch hook, and — when the result is a
//! Program — drives the host effect loop.  The update/view/continuation
//! closures the loop applies then NATIVE-dispatch through the registry
//! instead of a fresh interpreted vmExecEnv per call; an unregistered closure
//! falls back to that same vmExecEnv (correctness never depends on coverage).
//!
//! MEASUREMENT (env-gated, so the frame stream on stdout stays byte-clean for
//! the byte-identical diff):
//!   AOTRUN_INTERP=1      leave host_apply at the interpreted default
//!                        (hostcall.applyClosureN) — the elmvm baseline, timed
//!                        on an IDENTICAL driver+pty+workload.
//!   AOTRUN_STATS_FILE=   wrap host_apply in a timing counter and write
//!                        "calls=… total_ns=… max_ns=… vmexec_fb=…" to that
//!                        file at exit.

const std = @import("std");
const gc = @import("gc");
const heap = gc.heap;
const types = gc.types;
const vm = @import("vm");
const values = vm.values;
const state = vm.state;
const parser = vm.parser;
const streams = vm.streams;
const hostcall = vm.hostcall;
const effectloop = @import("effectloop");
const rt = @import("runtime.zig");
const aot_gen = @import("aot_gen");

const HEAP_BYTES: usize = 64 * 1024 * 1024;
const RESERVE_BYTES: usize = 64 * 1024 * 1024;

const Value = types.Value;
const Vm = state.Vm;
const VmError = state.VmError;

/// libc getenv — Zig 0.16 has no std-level env accessor (std.posix.getenv and
/// std.process.getEnvVarOwned are gone; the vm port uses this same extern).
/// String-literal args coerce to [*:0]const u8.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]u8;

// ---------------------------------------------------------------------
//  Apply-timing counters (populated only when AOTRUN_STATS_FILE is set)
// ---------------------------------------------------------------------

var apply_count: u64 = 0;
var apply_total_ns: u128 = 0;
var apply_max_ns: u128 = 0;

fn nowNs() u128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u128, @intCast(ts.sec)) * 1_000_000_000 + @as(u128, @intCast(ts.nsec));
}

fn timedApplyHost(vm_: *Vm, fnv: Value, args: []const Value) VmError!Value {
    const t0 = nowNs();
    defer {
        apply_count += 1;
        const dt = nowNs() - t0;
        apply_total_ns += dt;
        if (dt > apply_max_ns) apply_max_ns = dt;
    }
    return rt.applyHost(vm_, fnv, args);
}

fn timedApplyClosure(vm_: *Vm, fnv: Value, args: []const Value) VmError!Value {
    const t0 = nowNs();
    defer {
        apply_count += 1;
        const dt = nowNs() - t0;
        apply_total_ns += dt;
        if (dt > apply_max_ns) apply_max_ns = dt;
    }
    return hostcall.applyClosureN(vm_, fnv, args);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var it = init.minimal.args.iterate();
    const prog = it.next() orelse "aot-run";
    const bundle_arg: ?[]const u8 = it.next(); // optional: overrides the embedded bundle
    const fn_name: ?[]const u8 = it.next(); // CLI symmetry; the entry is baked
    if (fn_name != null and it.next() != null) usage(prog);

    const interp_mode = getenv("AOTRUN_INTERP") != null;
    const stats_file: ?[]const u8 = if (getenv("AOTRUN_STATS_FILE")) |p| std.mem.span(p) else null;

    // ---- the bundle text: CLI arg, else the copy aotdump embedded ----
    const bundle_z: [:0]const u8 = if (bundle_arg) |path| blk: {
        const file = try std.Io.Dir.openFile(.cwd(), io, path, .{});
        defer std.Io.File.close(file, io);
        const size = @as(usize, @intCast((try std.Io.File.stat(file, io)).size));
        const raw = try a.alloc(u8, size + 1);
        const n = try std.Io.File.readPositionalAll(file, io, raw[0..size], 0);
        raw[n] = 0;
        break :blk raw[0..n :0];
    } else aot_gen.bundle;

    // ---- init Gc + Vm ----
    var g = try heap.Gc.init(.{
        .heap_bytes = HEAP_BYTES,
        .reserve_bytes = RESERVE_BYTES,
    });
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // ---- load the bundle (registers each entry as a defun) ----
    const loaded = parser.parseBundle(&g, &v.symbols, &v, bundle_z);
    if (loaded <= 0) {
        std.debug.print("aot-run: bundle loaded 0 entries (bad bundle)\n", .{});
        return error.BadBundle;
    }

    // ---- wire the standard I/O streams (same as elmvm) ----
    v.valueSet("*stinput*", streams.valStreamInFd(0));
    v.valueSet("*stoutput*", streams.valStreamOutFd(1));
    v.valueSet("*sterror*", streams.valStreamOutFd(2));

    // ---- AOT init: consts + globals cache + registry (generated) ----
    aot_gen.aotInit(&v);

    // ---- install the host->Elm dispatch hook ----
    // interp_mode reproduces the elmvm baseline on the SAME driver (per-frame
    // apply time is then a like-for-like comparison); otherwise the AOT
    // registry-aware path.  stats_file wraps the chosen path in a timer.
    effectloop.host_apply = if (interp_mode)
        (if (stats_file != null) &timedApplyClosure else &hostcall.applyClosureN)
    else
        (if (stats_file != null) &timedApplyHost else &rt.applyHost);

    // ---- run the baked entry (0 args) -> the Program value ----
    var result = try rt.bounce(&v, try aot_gen.aotEntry(&v, null, 0));

    var outbuf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&outbuf);
    g.rootPushValue(&result);
    defer g.rootPop();
    if (effectloop.isProgram(result)) {
        var final = effectloop.runProgram(&v, result) catch |e| {
            std.debug.print("aot-run: error: {s}\n", .{values.errSlice(v.err_slot)});
            return e;
        };
        g.rootPushValue(&final);
        defer g.rootPop();
        try values.printValue(&w, final);
    } else {
        try values.printValue(&w, result);
    }
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, w.buffered());
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, "\n");

    // ---- write the apply stats (to a FILE, so stdout stays frame-clean) ----
    if (stats_file) |path| {
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "calls={d} total_ns={d} max_ns={d} vmexec_fb={d} elided={d} stack_env={d}\n",
            .{ apply_count, apply_total_ns, apply_max_ns, rt.vmexec_fallbacks, rt.elided_calls, rt.stack_env_calls },
        );
        std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = line }) catch {};
    }
}

fn usage(prog: []const u8) noreturn {
    std.debug.print("usage: {s} [bundle.csexp] [fn-name]\n  (no args = the bundle embedded at aot-build time)\n", .{prog});
    std.process.exit(2);
}
