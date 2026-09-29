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

/// Parse an unsigned decimal env var; null when unset/empty/malformed.
fn envUsize(name: [*:0]const u8) ?usize {
    const v = getenv(name) orelse return null;
    const s = std.mem.span(v);
    if (s.len == 0) return null;
    return std.fmt.parseUnsigned(usize, s, 10) catch null;
}

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

/// AOTRUN_ARGV mode: the saved CLI args (prog already dropped), collected
/// from the iterator before the GC exists (iterator buffers live in the
/// process arena, which outlives the run).
var app_args: []const []const u8 = &.{};

/// Build the *argv* pseudo-global value: a plain cons LIST of strings, built
/// back-to-front (cdr-first) so each valCons roots the previous tail.  The
/// empty case installs the nil singleton (Runtime.argv () -> []).
fn buildArgvList(g: *gc.Gc, args: []const []const u8) Value {
    var acc: Value = values.valNil();
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        acc = values.valCons(g, values.valString(g, args[i]), acc);
    }
    return acc;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    // ---- env knobs (all optional) ----
    // AOTRUN_ARGV: hand the process arguments to the APP as the *argv*
    // pseudo-global (run.js argv[2:] shape: the binary path is NOT an
    // element).  In this mode the driver's own [bundle] [fn-name] positional
    // parsing is disabled — every argument belongs to the app — so a
    // compiler-CLI binary (elmc) can take real arguments.  The bundle comes
    // from the embedded copy; a bundle path can still be forced with
    // AOTRUN_BUNDLE for debugging.
    // AOTRUN_QUIET: suppress the final printValue line (a compiler CLI's
    // stdout must stay clean; the app writes its own files/status).
    // ELMC_HEAP_MB / AOTRUN_RESERVE_MB: heap sizing overrides (the whole
    // compiler closure through HM inference needs more than the default).
    const argv_mode = getenv("AOTRUN_ARGV") != null;
    const quiet = getenv("AOTRUN_QUIET") != null;
    const heap_bytes = (envUsize("ELMC_HEAP_MB") orelse (HEAP_BYTES / (1024 * 1024))) * 1024 * 1024;

    var it = init.minimal.args.iterate();
    const prog = it.next() orelse "aot-run";
    var bundle_arg: ?[]const u8 = null;
    if (argv_mode) {
        // Every argument (after the program name) belongs to the APP.  The
        // iterator's slices point into its internal buffer, so dupe them
        // into the process arena (outlives the run) for the global.
        var args_list: [256][]const u8 = undefined;
        var n: usize = 0;
        while (it.next()) |arg| {
            if (n == args_list.len) break; // absurd CLI; truncate
            args_list[n] = arg;
            n += 1;
        }
        const saved = try a.alloc([]const u8, n);
        for (args_list[0..n], 0..) |arg, i| saved[i] = try a.dupe(u8, arg);
        app_args = saved;
    } else {
        bundle_arg = it.next(); // optional: overrides the embedded bundle
        const fn_name = it.next(); // CLI symmetry; the entry is baked
        if (fn_name != null and it.next() != null) usage(prog);
    }

    const interp_mode = getenv("AOTRUN_INTERP") != null;
    const stats_file: ?[]const u8 = if (getenv("AOTRUN_STATS_FILE")) |p| std.mem.span(p) else null;
    if (getenv("AOTRUN_BUNDLE")) |p| bundle_arg = std.mem.span(p);
    // AOT_NAT_DEPTH: the native-depth cap (R1).  Non-tail native calls made
    // at or beyond it run interpreted (interp.vmExecEnv) instead of growing
    // the C stack — the cap bounds native recursion at depth x frame-size,
    // and the interpreter (flat loop, pooled call frames) handles the deep
    // remainder identically.  Default 256 (see rt.nat_depth_max).
    //
    // CLAMPED to rt.SAFE_NAT_DEPTH_CAP: the cap is ALSO a correctness bound.
    // Raising it past that runs native recursion the design does not trust,
    // and MEASURED corrupts results — a selfhost corpus compile is correct at
    // 256/512 but WRONG at 1024/6000 (see SAFE_NAT_DEPTH_CAP's comment).  The
    // clamp makes AOT_NAT_DEPTH un-lower-able (it can only lower the depth at
    // which fallback starts) rather than a knob that can silently break the
    // program.
    if (envUsize("AOT_NAT_DEPTH")) |nd| rt.nat_depth_max = @intCast(@min(nd, rt.SAFE_NAT_DEPTH_CAP));

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
        .heap_bytes = heap_bytes,
        // Reservation must exceed the initial heap or grow_heap can never
        // extend (a fixed 64MB cap made ELMC_HEAP_MB and even the default
        // 64->128MB growth spin forever); same policy as tools/aot/main.zig.
        .reserve_bytes = @max(heap_bytes * 2, RESERVE_BYTES),
    });
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // ZINCVM_INSTR_LIMIT: the VM's hard instruction budget (C parity —
    // $ZINCVM_INSTR_LIMIT, see state.Vm.instr_limit).  Default 5e9, which is
    // PER vmExecEnv entry: a whole-manifest compiler batch (the corpus plus
    // every fixture group) is one entry and legitimately exceeds it, aborting
    // mid-run ("[HARD LIMIT] ... aborting").  Raising the budget here lets the
    // whole batch run in ONE process — the corpus is then parsed/typechecked/
    // lowered once instead of once per group.
    if (envUsize("ZINCVM_INSTR_LIMIT")) |n| v.instr_limit = n;

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

    // ---- M15: the *argv* pseudo-global (AOTRUN_ARGV mode) ----
    // Mirrors the stream pseudo-globals: the app reads it via the trusted
    // Runtime.argvPrim (lowered to `Symbol "*argv*" + Prim "value"`), which
    // pops whatever value lives here.  valueSet copies into the GC-scanned
    // values table, so the list survives collections without rooting.
    if (argv_mode) {
        v.valueSet("*argv*", buildArgvList(&g, app_args));
    } else {
        v.valueSet("*argv*", values.valNil());
    }

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
    // AOTRUN_QUIET: a compiler CLI's stdout must stay clean (the app already
    // wrote its files + status itself); skip the final model print entirely.
    if (!quiet) {
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, w.buffered());
        try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, "\n");
    }

    // ---- write the apply stats (to a FILE, so stdout stays frame-clean) ----
    if (stats_file) |path| {
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "calls={d} total_ns={d} max_ns={d} vmexec_fb={d} elided={d} stack_env={d} depth_fb={d}\n",
            .{ apply_count, apply_total_ns, apply_max_ns, rt.vmexec_fallbacks, rt.elided_calls, rt.stack_env_calls, rt.depth_fallbacks },
        );
        std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = line }) catch {};
    }
}

fn usage(prog: []const u8) noreturn {
    std.debug.print("usage: {s} [bundle.csexp] [fn-name]\n  (no args = the bundle embedded at aot-build time)\n", .{prog});
    std.process.exit(2);
}
