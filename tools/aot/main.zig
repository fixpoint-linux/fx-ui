//! tools/aot/main.zig — the AOT benchmark driver ("aotbench").
//!
//! elmvm-shaped CLI: loads the SAME csexp bundle via the real parser (so the
//! defun table is populated exactly like elmvm), runs the generated aotInit
//! (consts + globals cache + registry), builds the entry env directly from the
//! RTL args, trampolines the generated entry, and prints the result value —
//! byte-identical to elmvm — plus vmbench-style timing stats.
//!
//! Usage:
//!   aotbench <bundle.csexp> <fn-name> [--secs=N] [--heap=MB] [arg ...]
//!
//! The <fn-name> is accepted for CLI symmetry with elmvm/vmbench but is
//! ignored: the entry defun was baked into the generated module at build time.
//! Args are Ints or Floats (same heuristic as elmvm).  `--secs` drives the
//! benchmark loop; without it, the program runs ONCE and prints the value only.

const std = @import("std");
const gc = @import("gc");
const heap = gc.heap;
const types = gc.types;
const vm_mod = @import("vm");
const values = vm_mod.values;
const state = vm_mod.state;
const parser = vm_mod.parser;
const interp = vm_mod.interp;
const streams = vm_mod.streams;
const rt = @import("runtime.zig");
const aot_gen = @import("aot_gen");

const HEAP_BYTES: usize = 64 * 1024 * 1024;
const RESERVE_BYTES: usize = 64 * 1024 * 1024;

fn nowNs() u128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u128, @intCast(ts.sec)) * 1_000_000_000 + @as(u128, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var it = init.minimal.args.iterate();
    _ = it.next(); // program name
    var bundle_path: ?[]const u8 = null;
    var fn_name: ?[]const u8 = null;
    var argstrs: [64][]const u8 = undefined;
    var nargs: usize = 0;
    var secs: ?f64 = null;
    var heap_mb: usize = 64;
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--secs=")) {
            secs = try std.fmt.parseFloat(f64, arg["--secs=".len..]);
            if (secs.? <= 0) return error.BadSecs;
        } else if (std.mem.startsWith(u8, arg, "--heap=")) {
            heap_mb = try std.fmt.parseInt(usize, arg["--heap=".len..], 10);
        } else if (bundle_path == null) {
            bundle_path = arg;
        } else if (fn_name == null) {
            fn_name = arg;
        } else {
            if (nargs >= 64) return error.TooManyArgs;
            argstrs[nargs] = arg;
            nargs += 1;
        }
    }
    const bundle = bundle_path orelse usage();

    // ---- read the bundle file into a [:0]const u8 buffer ----
    const file = try std.Io.Dir.openFile(.cwd(), io, bundle, .{});
    defer std.Io.File.close(file, io);
    const size = @as(usize, @intCast((try std.Io.File.stat(file, io)).size));
    const raw = try a.alloc(u8, size + 1);
    const n = try std.Io.File.readPositionalAll(file, io, raw[0..size], 0);
    raw[n] = 0;
    const bundle_z: [:0]const u8 = raw[0..n :0];

    // ---- init Gc + Vm (heap size from --heap, min 16MB / 512-page multiple) ----
    const heap_bytes: usize = blk: {
        const mb = @max(heap_mb, 16);
        break :blk mb * 1024 * 1024;
    };
    var g = try heap.Gc.init(.{
        .heap_bytes = heap_bytes,
        .reserve_bytes = @max(heap_bytes * 2, RESERVE_BYTES),
        // Compiled out in ReleaseFast/ReleaseSmall; in Debug/ReleaseSafe this
        // re-verifies the heap (precise-root contract) after every collection.
        .verify_collects = true,
    });
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();

    // ---- load the bundle (registers each entry as a defun) ----
    const loaded = parser.parseBundle(&g, &v.symbols, &v, bundle_z);
    if (loaded <= 0) {
        std.debug.print("aotbench: bundle loaded 0 entries (bad bundle)\n", .{});
        return error.BadBundle;
    }

    // ---- wire the standard I/O streams (same as elmvm) ----
    v.valueSet("*stinput*", streams.valStreamInFd(0));
    v.valueSet("*stoutput*", streams.valStreamOutFd(1));
    v.valueSet("*sterror*", streams.valStreamOutFd(2));

    // ---- AOT init: consts + globals cache + registry (generated) ----
    aot_gen.aotInit(&v);

    // ---- build the entry env directly from the RTL args ----
    var argvals: [64]types.Value = undefined;
    for (argstrs[0..nargs], 0..) |arg, i| {
        argvals[i] = if (isFloatArg(arg))
            values.valFloat(try std.fmt.parseFloat(f64, arg))
        else
            values.valNumber(try std.fmt.parseInt(i64, arg, 10));
    }
    var env: ?[*]types.Value = null;
    var env_len: i32 = @intCast(nargs);
    if (nargs > 0) {
        env = g.allocArray(types.Value, @intCast(nargs));
        @memcpy(env.?[0..nargs], argvals[0..nargs]);
    }
    // Root the entry env SLOT persistently: the benchmark loop re-passes it to
    // aotEntry every iteration, and a nursery scavenge during a call may move
    // the array — the rooted slot is updated on move (elmvm roots its result
    // the same way).  argvals is a C-stack array (numbers: pins nothing).
    g.rootPushPtr(@ptrCast(&env));
    defer g.rootPop();
    g.rootPushValueArray(&argvals, &env_len); // root argvals across the run (numbers: pins nothing)
    defer g.rootPop();
    const run_once = struct {
        fn go(vm: *state.Vm, e: ?[*]types.Value, el: i32) !types.Value {
            const r = try aot_gen.aotEntry(vm, e, el);
            return rt.bounce(vm, r);
        }
    }.go;

    var result = try run_once(&v, env, env_len);

    if (secs) |target_secs| {
        // ---- benchmark loop ----
        const gc_before = g.stats();
        const instr_before = rt.instrs;
        const target_ns: u128 = @intFromFloat(target_secs * 1_000_000_000.0);
        const t0 = nowNs();
        var iterations: u64 = 0;
        var elapsed = nowNs() - t0;
        while (elapsed < target_ns) : (elapsed = nowNs() - t0) {
            result = try run_once(&v, env, env_len);
            iterations += 1;
        }
        const total_ns: u128 = nowNs() - t0;
        const total_instr = rt.instrs - instr_before;
        const gc_after = g.stats();
        const seconds = @as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0;
        const instr_f: f64 = @floatFromInt(total_instr);
        std.debug.print(
            "aotbench: {s} ({d} args) heap={d}MB\n",
            .{ bundle, nargs, heap_mb },
        );
        std.debug.print("iterations:     {d}\n", .{iterations});
        std.debug.print("instructions:   {d}\n", .{total_instr});
        std.debug.print("elapsed_ms:     {d:.1}\n", .{@as(f64, @floatFromInt(total_ns)) / 1_000_000.0});
        std.debug.print("ns_per_iter:    {d:.1}\n", .{@as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations))});
        std.debug.print("instr_per_sec:  {d:.1}\n", .{instr_f / seconds});
        std.debug.print("ns_per_instr:   {d:.3}\n", .{@as(f64, @floatFromInt(total_ns)) / instr_f});
        std.debug.print(
            "gc: scavenges {d}->{d} (+{d})  full {d}->{d} (+{d})  pages {d}->{d}  env_reuse {d}/{d}\n",
            .{
                gc_before.nursery_scavenge_count, gc_after.nursery_scavenge_count,
                gc_after.nursery_scavenge_count - gc_before.nursery_scavenge_count,
                gc_before.full_collect_count,     gc_after.full_collect_count,
                gc_after.full_collect_count - gc_before.full_collect_count,
                gc_before.allocated_pages,        gc_after.allocated_pages,
                v.env_reuse_hits,                  v.env_reuse_misses,
            },
        );
        std.debug.print(
            "aot: elided {d}  stack_env {d}  vmexec_fb {d}\n",
            .{ rt.elided_calls, rt.stack_env_calls, rt.vmexec_fallbacks },
        );
    }

    // ---- print the result value (byte-identical to elmvm) ----
    var outbuf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&outbuf);
    g.rootPushValue(&result);
    defer g.rootPop();
    try values.printValue(&w, result);
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, w.buffered());
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, "\n");
}

fn usage() noreturn {
    std.debug.print("usage: aotbench <bundle.csexp> <fn-name> [--secs=N] [--heap=MB] [arg ...]\n", .{});
    std.process.exit(2);
}

fn isFloatArg(arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "NaN") or std.mem.eql(u8, arg, "Infinity") or
        std.mem.eql(u8, arg, "-Infinity")) return true;
    for (arg) |c| {
        if (c == '.' or c == 'e' or c == 'E') return true;
    }
    return false;
}
