//! tools/vmbench.zig — VM throughput benchmark harness.
//!
//! Loads a csexp bundle, builds ONE call snippet (parsed once), then runs
//! vmExec on the same code in a loop for a target duration, reporting
//! measured instructions-per-second from the Vm.instr_exec counter.
//!
//! Usage:
//!   vmbench <bundle.csexp> <fn-name> [--secs=N] [arg ...]
//!
//! The bundle-load + stream-wiring + RTL arg-atom snippet mirror tools/elmvm.zig.

const std = @import("std");
const gc = @import("gc");
const heap = gc.heap;
const types = gc.types;
const vm = @import("vm");
const values = vm.values;
const state = vm.state;
const parser = vm.parser;
const interp = vm.interp;
const streams = vm.streams;

const HEAP_BYTES: usize = 64 * 1024 * 1024;
const RESERVE_BYTES: usize = 64 * 1024 * 1024;

/// CLOCK_MONOTONIC as u128 nanoseconds.
fn nowNs() u128 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u128, @intCast(ts.sec)) * 1_000_000_000 + @as(u128, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();

    var it = init.minimal.args.iterate();
    _ = it.next(); // program name
    var bundle_path: ?[]const u8 = null;
    var fn_name: ?[]const u8 = null;
    var argstrs: [64][]const u8 = undefined;
    var nargs: usize = 0;
    var secs: f64 = 3.0;
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--secs=")) {
            secs = try std.fmt.parseFloat(f64, arg["--secs=".len..]);
            if (secs <= 0) return error.BadSecs;
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
    const fname = fn_name orelse usage();

    // ---- read the bundle file into a [:0]const u8 buffer ----
    const file = try std.Io.Dir.openFile(.cwd(), init.io, bundle, .{});
    defer std.Io.File.close(file, init.io);
    const size = @as(usize, @intCast((try std.Io.File.stat(file, init.io)).size));
    const raw = try a.alloc(u8, size + 1);
    const n = try std.Io.File.readPositionalAll(file, init.io, raw[0..size], 0);
    raw[n] = 0;
    const bundle_z: [:0]const u8 = raw[0..n :0];

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
        std.debug.print("vmbench: bundle loaded 0 entries (bad bundle)\n", .{});
        return error.BadBundle;
    }

    // ---- wire the standard I/O streams (same as elmvm) ----
    v.valueSet("*stinput*", streams.valStreamInFd(0));
    v.valueSet("*stoutput*", streams.valStreamOutFd(1));
    v.valueSet("*sterror*", streams.valStreamOutFd(2));

    // ---- build the call snippet ONCE: (m <arg atoms RTL> g[len:s]fn p v) ----
    var snip_buf: [1024]u8 = undefined;
    var snip_len: usize = 0;
    snip_buf[snip_len] = '(';
    snip_len += 1;
    snip_buf[snip_len] = 'm';
    snip_len += 1;
    var i: usize = nargs;
    while (i > 0) {
        i -= 1;
        const arg = argstrs[i];
        const atom = if (isFloatArg(arg))
            try std.fmt.bufPrint(snip_buf[snip_len..], "F[{d}:F]{s}", .{ arg.len, arg })
        else blk: {
            const val = try std.fmt.parseInt(i64, arg, 10);
            var numbuf: [32]u8 = undefined;
            const numstr = try std.fmt.bufPrint(&numbuf, "{d}", .{val});
            break :blk try std.fmt.bufPrint(snip_buf[snip_len..], "n[{d}:n]{s}", .{ numstr.len, numstr });
        };
        snip_len += atom.len;
    }
    const g_atom = try std.fmt.bufPrint(snip_buf[snip_len..], "g[{d}:s]{s}", .{ fname.len, fname });
    snip_len += g_atom.len;
    snip_buf[snip_len] = 'p';
    snip_len += 1;
    snip_buf[snip_len] = 'v';
    snip_len += 1;
    snip_buf[snip_len] = ')';
    snip_len += 1;
    snip_buf[snip_len] = 0;
    const snippet_z: [:0]const u8 = snip_buf[0..snip_len :0];

    // ---- parse ONCE, root across the whole run ----
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(&g, &v.symbols, snippet_z, &code);
    parser.resolveJumps(code.?, len);
    g.rootPushPtr(@ptrCast(&code));
    defer g.rootPop();

    const gc_before = g.stats();

    // ---- warm-up: one run to trigger lazy interning/rooting ----
    _ = interp.vmExec(&v, @ptrCast(code.?), len) catch |e| {
        std.debug.print("vmbench: error: {s}\n", .{values.errSlice(v.err_slot)});
        return e;
    };

    const instr_before = v.instr_exec;
    const target_ns: u128 = @intFromFloat(secs * 1_000_000_000.0);
    const t0 = nowNs();
    var iterations: u64 = 0;
    var elapsed = nowNs() - t0;
    while (elapsed < target_ns) : (elapsed = nowNs() - t0) {
        _ = interp.vmExec(&v, @ptrCast(code.?), len) catch |e| {
            std.debug.print("vmbench: error: {s}\n", .{values.errSlice(v.err_slot)});
            return e;
        };
        iterations += 1;
    }
    const total_ns: u128 = nowNs() - t0;
    const total_instr = v.instr_exec - instr_before;

    const gc_after = g.stats();
    const seconds = @as(f64, @floatFromInt(total_ns)) / 1_000_000_000.0;
    const instr_f: f64 = @floatFromInt(total_instr);
    std.debug.print(
        "vmbench: {s} {s} ({d} args)\n",
        .{ bundle, fname, nargs },
    );
    std.debug.print("iterations:     {d}\n", .{iterations});
    std.debug.print("instructions:   {d}\n", .{total_instr});
    std.debug.print("elapsed_ms:     {d:.1}\n", .{@as(f64, @floatFromInt(total_ns)) / 1_000_000.0});
    std.debug.print("instr_per_sec:  {d:.1}\n", .{instr_f / seconds});
    std.debug.print("ns_per_instr:   {d:.3}\n", .{@as(f64, @floatFromInt(total_ns)) / instr_f});
    std.debug.print(
        "gc: scavenges {d}->{d} (+{d})  full {d}->{d} (+{d})  pages {d}->{d}\n",
        .{
            gc_before.nursery_scavenge_count, gc_after.nursery_scavenge_count,
            gc_after.nursery_scavenge_count - gc_before.nursery_scavenge_count,
            gc_before.full_collect_count,     gc_after.full_collect_count,
            gc_after.full_collect_count - gc_before.full_collect_count,
            gc_before.allocated_pages,        gc_after.allocated_pages,
        },
    );
}

fn usage() noreturn {
    std.debug.print("usage: vmbench <bundle.csexp> <fn-name> [--secs=N] [arg ...]\n", .{});
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
