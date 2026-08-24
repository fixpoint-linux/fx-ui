//! tools/elmvm.zig — M0 gate harness for the Elm->ZINC-csexp pipeline.
//!
//! Loads a csexp bundle (a list of (name (c<body>)) entries) into the Shen
//! ZINC VM, then builds a tiny call snippet and runs one function against a
//! set of integer arguments, printing the resulting value to stdout.
//!
//! Usage:
//!   elmvm <bundle.csexp> <fn-name> [arg ...]
//!
//! The call snippet mirrors the plan's full-arity emission rule:
//!   m <arg-atoms RTL> g[len:s]<fn> p v
//! i.e. pushmark, then each arg (number literal, auto-push) pushed
//! right-to-left (reverse command-line order), load the global closure by
//! symbol, apply, return.

const std = @import("std");
const gc = @import("gc");
const heap = gc.heap;
const types = gc.types;
const vm = @import("vm");
const values = vm.values;
const state = vm.state;
const parser = vm.parser;
const interp = vm.interp;

const HEAP_BYTES: usize = 16 * 1024 * 1024;
const RESERVE_BYTES: usize = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var it = init.minimal.args.iterate();
    _ = it.next(); // program name
    const bundle_path = it.next() orelse usage();
    const fn_name = it.next() orelse usage();

    // ---- read the bundle file into a [:0]const u8 buffer ----
    const file = try std.Io.Dir.openFile(.cwd(), io, bundle_path, .{});
    defer std.Io.File.close(file, io);
    const size = @as(usize, @intCast((try std.Io.File.stat(file, io)).size));
    const raw = try a.alloc(u8, size + 1);
    const n = try std.Io.File.readPositionalAll(file, io, raw[0..size], 0);
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
        std.debug.print("elmvm: bundle loaded 0 entries (bad bundle)\n", .{});
        return error.BadBundle;
    }

    // ---- build the call snippet: (m <arg atoms> g[len:s]fn p v) ----
    // Args are pushed RIGHT-TO-LEFT (reverse command-line order).  The VM's
    // apply pops them top-first into argbuf, so the LAST-pushed arg lands in
    // argbuf[0] = first command-line arg = param1.  This is consistent with the
    // compiler's currying env layout (param_i = access(n-i)).
    var argvals: [64]i64 = undefined;
    var nargs: usize = 0;
    while (it.next()) |arg| {
        if (nargs >= 64) return error.TooManyArgs;
        argvals[nargs] = try std.fmt.parseInt(i64, arg, 10);
        nargs += 1;
    }
    var snip_buf: [1024]u8 = undefined;
    var snip_len: usize = 0;
    snip_buf[snip_len] = '(';
    snip_len += 1;
    snip_buf[snip_len] = 'm';
    snip_len += 1;
    var i: usize = nargs;
    while (i > 0) {
        i -= 1;
        const val = argvals[i];
        var numbuf: [32]u8 = undefined;
        const numstr = try std.fmt.bufPrint(&numbuf, "{d}", .{val});
        const atom = try std.fmt.bufPrint(snip_buf[snip_len..], "n[{d}:n]{s}", .{ numstr.len, numstr });
        snip_len += atom.len;
    }
    const g_atom = try std.fmt.bufPrint(snip_buf[snip_len..], "g[{d}:s]{s}", .{ fn_name.len, fn_name });
    snip_len += g_atom.len;
    snip_buf[snip_len] = 'p';
    snip_len += 1;
    snip_buf[snip_len] = 'v';
    snip_len += 1;
    snip_buf[snip_len] = ')';
    snip_len += 1;
    snip_buf[snip_len] = 0;
    const snippet_z: [:0]const u8 = snip_buf[0..snip_len :0];

    // ---- parse + run ----
    var code: ?[*]types.Instr = null;
    const len = try parser.parseBytecode(&g, &v.symbols, snippet_z, &code);
    parser.resolveJumps(code.?, len);
    g.rootPushPtr(@ptrCast(&code));
    const result = interp.vmExec(&v, @ptrCast(code.?), len) catch |e| {
        g.rootPop();
        return e;
    };
    g.rootPop();

    var outbuf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&outbuf);
    try values.printValue(&w, result);
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, w.buffered());
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, "\n");
}

fn usage() noreturn {
    std.debug.print("usage: elmvm <bundle.csexp> <fn-name> [arg ...]\n", .{});
    std.process.exit(2);
}
