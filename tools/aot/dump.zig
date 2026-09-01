//! tools/aot/dump.zig — the AOT-to-Zig emitter ("aotdump").
//!
//! Links the REAL GC+VM, runs parser.parseBundle on a csexp bundle (zero
//! parser drift), then walks the chosen entry defun + its TRANSITIVE closure
//! over every g/Q/R-referenced global name, emitting one Zig function per
//! defun body (a labeled-switch reification of the bytecode) plus the
//! consts table, globals cache, registry fill, and aotInit.
//!
//! Usage:
//!   aotdump <bundle.csexp> <entry-name> -o <out.zig>
//!
//! Every defun body becomes ONE Zig fn whose body is a labeled switch over
//! comptime pc arms (verified: compiles to threaded code).  Tail calls use
//! the 3 tiers documented in docs/aot-spike.md; GC rooting mirrors the
//! interpreter's windows via the handwritten tools/aot/runtime.zig (aotrt).
//!
//! COVERAGE IS OPT-IN: a g/Q/R reference to a non-lambda (prim/symbol) name
//! is kept in the globals cache only (dispatch falls to rt.applyGeneric ->
//! the interpreter); a body containing an unknown .prim op (jmp_target==0) is
//! left interpreted (skipped with a warning), and so is a body whose value
//! stack the emitter cannot statically size (stackDepth returns null).  The
//! emitter never generates code for a body whose stack depth it cannot size:
//! the fixed stk array's stores are unchecked in ReleaseFast.  Correctness
//! never depends on AOT coverage.

const std = @import("std");
const gc = @import("gc");
const heap = gc.heap;
const types = gc.types;
const vm_mod = @import("vm");
const values = vm_mod.values;
const state = vm_mod.state;
const parser = vm_mod.parser;
const interp = vm_mod.interp;
const prims = vm_mod.prims;
const rt = @import("runtime.zig");

const Instr = types.Instr;
const Value = types.Value;
const Gc = gc.Gc;
const Vm = state.Vm;

const HEAP_BYTES: usize = 64 * 1024 * 1024;
const RESERVE_BYTES: usize = 64 * 1024 * 1024;

/// One AOT'd defun (a lambda body + the emit-time facts we derive from it).
const Defun = struct {
    name: []const u8, // arena-owned copy
    code: ?*Instr, // the ORIGINAL GC Instr-array head (defun-table reachable)
    code_len: i32,
    arity: i32,
    maxd: i32, // fixed value-stack size (sim + slack)
};

/// One AOT'd cur body (a `.cur` closure body discovered while walking a defun
/// or a parent cur).  Identified by its closure Instr-array pointer; registered
/// in the registry so first-class applies of the closure hit native dispatch
/// instead of falling back to vmExecEnv.
const Cur = struct {
    name: []const u8, // synthesized "<parent>_c<pc>" (arena-owned)
    code: ?*Instr, // closure Instr-array head (identity for dedupe + registration)
    code_len: i32,
    arity: i32,
    maxd: i32,
    parent_code: ?*Instr, // code pointer of the containing unit (fresh aotInit read)
    pc: i32, // the .cur site within the parent body
};

/// A string/symbol literal built into the rooted consts table at aotInit.
const Const = struct {
    is_string: bool,
    text: []const u8,
};

const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var it = init.minimal.args.iterate();
    _ = it.next(); // program name
    const bundle_path = it.next() orelse usage();
    const entry_name = it.next() orelse usage();
    var out_path: []const u8 = "aot_gen.zig";
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-o")) {
            out_path = it.next() orelse usage();
        } else {
            std.debug.print("aotdump: unknown arg '{s}'\n", .{arg});
            return error.BadArg;
        }
    }

    // ---- read bundle ----
    const file = try std.Io.Dir.openFile(.cwd(), io, bundle_path, .{});
    defer std.Io.File.close(file, io);
    const size = @as(usize, @intCast((try std.Io.File.stat(file, io)).size));
    const raw = try a.alloc(u8, size + 1);
    const n = try std.Io.File.readPositionalAll(file, io, raw[0..size], 0);
    raw[n] = 0;
    const bundle_z: [:0]const u8 = raw[0..n :0];

    // ---- init Gc + Vm + parse the bundle (REAL parser, zero drift) ----
    var g = try heap.Gc.init(.{ .heap_bytes = HEAP_BYTES, .reserve_bytes = RESERVE_BYTES });
    defer g.deinit();
    var v: state.Vm = undefined;
    v.init(&g);
    defer v.deinit();
    const loaded = parser.parseBundle(&g, &v.symbols, &v, bundle_z);
    if (loaded <= 0) {
        std.debug.print("aotdump: bundle loaded 0 entries (bad bundle)\n", .{});
        return error.BadBundle;
    }

    // ---- entry must be a lambda defun ----
    if (v.defunGet(entry_name).tag != .lambda) {
        std.debug.print("aotdump: entry '{s}' is not a lambda defun\n", .{entry_name});
        return error.BadEntry;
    }

    // ---- transitive closure over g/Q/R global names + .cur bodies ----
    // A worklist over defuns AND cur bodies: each body may add globals (which
    // may add defuns) and cur bodies (which may add deeper cur bodies).  Curs
    // are appended after their parent, so a one-pass parent-kept filter later
    // can drop orphans in list order.
    var defuns = std.ArrayList(Defun).empty;
    var curs = std.ArrayList(Cur).empty;
    var globals = std.ArrayList([]const u8).empty;
    try globals.append(a, try a.dupe(u8, entry_name));
    try addDefun(&defuns, &v, entry_name, a);

    var di: usize = 0;
    var ci: usize = 0;
    while (di < defuns.items.len or ci < curs.items.len) {
        while (di < defuns.items.len) : (di += 1) {
            try walkBody(&defuns, &curs, &globals, &v, defuns.items[di].code, defuns.items[di].code_len, defuns.items[di].name, a);
        }
        while (ci < curs.items.len) : (ci += 1) {
            try walkBody(&defuns, &curs, &globals, &v, curs.items[ci].code, curs.items[ci].code_len, curs.items[ci].name, a);
        }
    }

    // ---- filter unknown-prim/oversized units; drop orphaned curs ----
    // Bodies with an unknown .prim op (jmp_target==0) stay interpreted: the
    // globals cache still holds their closure, and Q/R references fall back to
    // rt.applyGeneric -> the interpreter (correctness never depends on AOT).
    // The same goes for bodies the stackDepth sim cannot statically size — a
    // clamped-down stk would be an unchecked ReleaseFast OOB write.
    {
        var kept = std.ArrayList(Defun).empty;
        for (defuns.items) |*d| {
            if (hasUnknownPrim(d.code, d.code_len)) {
                std.debug.print("aotdump: warning: '{s}' has an unknown prim — left interpreted\n", .{d.name});
                continue;
            }
            d.maxd = stackDepth(@ptrCast(d.code.?), d.code_len) orelse {
                std.debug.print("aotdump: warning: '{s}' needs a value stack beyond the {d}-slot static limit — left interpreted\n", .{ d.name, STK_MAX });
                continue;
            };
            try kept.append(a, d.*);
        }
        defuns.deinit(a);
        defuns = kept;
        if (indexOfDefun(defuns.items, entry_name) == null) {
            std.debug.print("aotdump: entry '{s}' was left interpreted (unknown prim or over the stack-size limit)\n", .{entry_name});
            return error.BadEntry;
        }

        // Curs: keep a body iff it has no unknown prim, is statically
        // sizeable, AND its parent (a kept defun's code or an earlier kept
        // cur's code) survived.  Parents always precede children in `curs`,
        // so one in-order pass is exact.
        var kept_codes = std.ArrayList(?*Instr).empty;
        for (defuns.items) |d| try kept_codes.append(a, d.code);
        var kept_curs = std.ArrayList(Cur).empty;
        for (curs.items) |*c| {
            if (hasUnknownPrim(c.code, c.code_len)) {
                std.debug.print("aotdump: warning: '{s}' has an unknown prim — left interpreted\n", .{c.name});
                continue;
            }
            if (indexOfCode(kept_codes.items, c.parent_code) == null) continue; // orphaned
            c.maxd = stackDepth(@ptrCast(c.code.?), c.code_len) orelse {
                std.debug.print("aotdump: warning: '{s}' needs a value stack beyond the {d}-slot static limit — left interpreted\n", .{ c.name, STK_MAX });
                continue;
            };
            try kept_curs.append(a, c.*);
            try kept_codes.append(a, c.code);
        }
        curs.deinit(a);
        curs = kept_curs;
    }

    // ---- registry capacity (the generated aotInit indexes reg_fn/reg_code) ----
    if (defuns.items.len + curs.items.len > rt.REG_MAX) {
        std.debug.print("aotdump: {d} AOT units exceed the registry capacity {d}\n", .{ defuns.items.len + curs.items.len, rt.REG_MAX });
        return error.RegistryFull;
    }

    // ---- derive arity per unit (maxd was set by the filter pass) ----
    for (defuns.items) |*d| d.arity = interp.zincArity(d.code, d.code_len);
    for (curs.items) |*c| c.arity = interp.zincArity(c.code, c.code_len);

    // ---- classify NON_ALLOCATING defuns (Phase 2 rooting elision) ----
    const nonalloc = try classifyNonAlloc(defuns.items, a);
    var elided_count: usize = 0;
    for (nonalloc) |na| {
        if (na) elided_count += 1;
    }

    // ---- collect string/symbol consts ----
    var consts = std.ArrayList(Const).empty;
    for (defuns.items) |d| try collectConsts(&consts, d.code, d.code_len, a);
    for (curs.items) |c| try collectConsts(&consts, c.code, c.code_len, a);

    // ---- emit ----
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    try emit(a, &out, defuns.items, curs.items, globals.items, consts.items, entry_name, nonalloc);

    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = out_path, .data = out.items });
    std.debug.print("aotdump: emitted {s} ({d} defuns, {d} curs, {d} globals, {d} consts, {d} elided)\n", .{
        out_path, defuns.items.len, curs.items.len, globals.items.len, consts.items.len, elided_count,
    });
}

fn usage() noreturn {
    std.debug.print("usage: aotdump <bundle.csexp> <entry-name> -o <out.zig>\n", .{});
    std.process.exit(2);
}

// =====================================================================
//  Closure walk helpers
// =====================================================================

fn addDefun(defuns: *std.ArrayList(Defun), v: *Vm, name: []const u8, a: Allocator) !void {
    const val = v.defunGet(name);
    try defuns.append(a, .{
        .name = try a.dupe(u8, name),
        .code = val.payload.lambda.code,
        .code_len = val.payload.lambda.code_len,
        .arity = 0,
        .maxd = 0,
    });
}

fn addGlobal(
    globals: *std.ArrayList([]const u8),
    defuns: *std.ArrayList(Defun),
    v: *Vm,
    name: []const u8,
    a: Allocator,
) !void {
    if (indexOf(globals.items, name) == null)
        try globals.append(a, try a.dupe(u8, name));
    if (v.defunGet(name).tag == .lambda and indexOfDefun(defuns.items, name) == null)
        try addDefun(defuns, v, name, a);
}

fn indexOf(list: []const []const u8, name: []const u8) ?usize {
    for (list, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

fn indexOfDefun(list: []const Defun, name: []const u8) ?usize {
    for (list, 0..) |d, i| if (std.mem.eql(u8, d.name, name)) return i;
    return null;
}

fn indexOfCur(list: []const Cur, code: ?*Instr) ?usize {
    for (list, 0..) |c, i| if (c.code == code) return i;
    return null;
}

fn indexOfCode(list: []const ?*Instr, code: ?*Instr) ?usize {
    for (list, 0..) |c, i| if (c == code) return i;
    return null;
}

/// The registry slot of a cur's parent body (a kept defun or an earlier kept
/// cur).  Only called on curs whose parent survived the filter.
fn parentSlot(defuns: []const Defun, curs: []const Cur, c: Cur) usize {
    for (defuns, 0..) |d, i| if (d.code == c.parent_code) return i;
    for (curs, 0..) |cc, i| if (cc.code == c.parent_code) return defuns.len + i;
    unreachable;
}

/// Walk one body's instrs, adding referenced globals (which may add defuns) and
/// `.cur` closure bodies (deduped by Instr-array pointer).  `parent_name` names
/// the containing unit for synthesized cur names; `parent_code` is that unit's
/// code pointer (used to re-read the fresh pointer chain at aotInit).
fn walkBody(
    defuns: *std.ArrayList(Defun),
    curs: *std.ArrayList(Cur),
    globals: *std.ArrayList([]const u8),
    v: *Vm,
    code: ?*Instr,
    code_len: i32,
    parent_name: []const u8,
    a: Allocator,
) !void {
    const cur: [*]Instr = @ptrCast(code.?);
    var pc: i32 = 0;
    while (pc < code_len) : (pc += 1) {
        const ins = &cur[@intCast(pc)];
        switch (ins.op) {
            .global, .global_apply, .global_appterm => {
                if (ins.operand.tag == .symbol)
                    try addGlobal(globals, defuns, v, values.symSlice(ins.operand), a);
            },
            .cur => try addCur(curs, a, ins.closure_code, ins.closure_len, parent_name, code, pc),
            else => {},
        }
    }
}

fn addCur(
    curs: *std.ArrayList(Cur),
    a: Allocator,
    code: ?*Instr,
    code_len: i32,
    parent_name: []const u8,
    parent_code: ?*Instr,
    pc: i32,
) !void {
    if (code == null) return; // defensive: a .cur without a body
    if (indexOfCur(curs.items, code) != null) return; // dedupe by pointer
    const nm = try std.fmt.allocPrint(a, "{s}_c{d}", .{ parent_name, pc });
    try curs.append(a, .{
        .name = nm,
        .code = code,
        .code_len = code_len,
        .arity = 0,
        .maxd = 0,
        .parent_code = parent_code,
        .pc = pc,
    });
}

fn collectConsts(consts: *std.ArrayList(Const), code: ?*Instr, code_len: i32, a: Allocator) !void {
    const cur: [*]Instr = @ptrCast(code.?);
    var pc: i32 = 0;
    while (pc < code_len) : (pc += 1) {
        const ins = &cur[@intCast(pc)];
        switch (ins.op) {
            .string => try addConst(consts, true, values.strSlice(ins.operand), a),
            .symbol => try addConst(consts, false, values.symSlice(ins.operand), a),
            .const_prim => switch (ins.operand.tag) {
                .string => try addConst(consts, true, values.strSlice(ins.operand), a),
                .symbol => try addConst(consts, false, values.symSlice(ins.operand), a),
                else => {},
            },
            else => {},
        }
    }
}

fn addConst(consts: *std.ArrayList(Const), is_string: bool, text: []const u8, a: Allocator) !void {
    for (consts.items) |c| {
        if (c.is_string == is_string and std.mem.eql(u8, c.text, text)) return;
    }
    try consts.append(a, .{ .is_string = is_string, .text = try a.dupe(u8, text) });
}

fn hasUnknownPrim(code: ?*Instr, len: i32) bool {
    const cur: [*]Instr = @ptrCast(code.?);
    var pc: i32 = 0;
    while (pc < len) : (pc += 1) {
        if (cur[@intCast(pc)].op == .prim and cur[@intCast(pc)].jmp_target == 0) return true;
    }
    return false;
}

fn constIndex(consts: []const Const, is_string: bool, text: []const u8) usize {
    for (consts, 0..) |c, i| {
        if (c.is_string == is_string and std.mem.eql(u8, c.text, text)) return i;
    }
    unreachable;
}

// =====================================================================
//  Fixed value-stack depth simulation (conservative; +slack at the call site)
// =====================================================================

/// The emitted `stk` cap: a body whose slacked depth exceeds this is left
/// interpreted, NEVER clamped down — an undersized stk is a silent OOB write
/// in ReleaseFast (ipush's Debug assert is stripped).
const STK_MAX: i32 = 256;

/// The sim's heights/worklist array size: a body longer than this cannot be
/// statically sized at all.
const SIM_LIMIT: usize = 512;

/// Fixed value-stack size for one body (sim maxd + slack), or null when the
/// emitter cannot statically size it: body longer than SIM_LIMIT, worklist
/// overflow (unbounded relaxation), or depth beyond STK_MAX.  The caller
/// leaves null units interpreted.
fn stackDepth(code: [*]Instr, len: i32) ?i32 {
    if (@as(usize, @intCast(len)) > SIM_LIMIT) return null;
    var heights: [SIM_LIMIT]i32 = undefined;
    @memset(&heights, -1); // -1 = unvisited
    heights[0] = 0;
    var wl: [SIM_LIMIT]i32 = undefined;
    var wl_len: usize = 0;
    wl[wl_len] = 0;
    wl_len += 1;
    var maxd: i32 = 0;

    while (wl_len > 0) {
        wl_len -= 1;
        const pc = wl[wl_len];
        const h = heights[@intCast(pc)];
        const ins = &code[@intCast(pc)];

        var peak: i32 = 0;
        var succ: [2]i32 = undefined;
        var succ_h: [2]i32 = undefined; // value-stack height on entering succ
        var nsucc: usize = 0;

        switch (ins.op) {
            .number, .string, .symbol, .boolean, .float, .access, .pushmark, .cur, .global => {
                peak = 1;
                succ[0] = pc + 1;
                succ_h[0] = h + 1;
                nsucc = 1;
            },
            .prim => {
                peak = 1;
                succ[0] = pc + 1;
                succ_h[0] = h + 1 - @as(i32, prims.primByIndex(@intCast(ins.jmp_target - 1)).arity);
                nsucc = 1;
            },
            .const_prim, .access_prim => {
                peak = 1;
                succ[0] = pc + 1;
                succ_h[0] = h + 2 - @as(i32, prims.primByIndex(@intCast(ins.jmp_target - 1)).arity);
                nsucc = 1;
            },
            .prim_return => {}, // returns
            .grab, .let, .endlet => {
                succ[0] = pc + 1;
                succ_h[0] = h; // conservative: the conditional-pop empty-stack branch
                nsucc = 1;
            },
            .jmp => {
                succ[0] = ins.jmp_target;
                succ_h[0] = h;
                nsucc = 1;
            },
            .jmpf => {
                succ[0] = pc + 1;
                succ_h[0] = h; // conservative (conditionally pops 1)
                succ[1] = ins.jmp_target;
                succ_h[1] = h;
                nsucc = 2;
            },
            .ret => {},
            .apply, .global_apply => {
                // pops fn+mark, pushes result; args already counted by loads
                // (the dynamic arg count isn't known -> h-1 is the max).
                succ[0] = pc + 1;
                succ_h[0] = h - 1;
                nsucc = 1;
            },
            // Tail calls re-enter pc=0 with an EMPTY value stack (args moved
            // into the rebuilt env) — modelling that keeps self-tail loops
            // bounded instead of accumulating a phantom +1 per iteration.
            // The dynamic PRIM fall-through of the emitted appterm instead
            // continues at pc+1, having popped fn+mark and pushed the result:
            // at most h-1 (the callee prim's arity isn't statically known).
            .appterm, .global_appterm => {
                succ[0] = 0;
                succ_h[0] = 0;
                succ[1] = pc + 1;
                succ_h[1] = h - 1;
                nsucc = 2;
            },
            .count => {},
        }

        if (h + peak > maxd) maxd = h + peak;
        var s: usize = 0;
        while (s < nsucc) : (s += 1) {
            const t = succ[s];
            if (t < 0 or t >= len) continue; // bogus target — belt-and-braces
            if (succ_h[s] > heights[@intCast(t)]) {
                heights[@intCast(t)] = succ_h[s];
                if (wl_len >= wl.len) return null; // relaxation overflow: unsizable
                wl[wl_len] = t;
                wl_len += 1;
            }
        }
    }

    // never a tiny stack; never clamp DOWN — oversize means skip the unit.
    const with_slack = maxd + 8;
    if (with_slack < 16) return 16;
    if (with_slack > STK_MAX) return null;
    return with_slack;
}

// =====================================================================
//  NON_ALLOCATING classification (Phase 2 rooting elision)
// =====================================================================

/// Prims that provably never call gc_alloc (directly or via
/// valCons/valString/valVector/valError/throwShen/allocArray) and therefore
/// can never trigger a collection.  DENY-BY-DEFAULT: any prim NOT listed
/// here marks its body ALLOCATING, so a future allocating prim stays sound
/// without touching this list.  NOTE: `assoc` is deliberately OUT — it calls
/// throwShen on a non-list (throwShen -> valError -> gc_alloc), so it can
/// allocate; the plan's draft allowlist listed it, but the plan's own rule
/// ("any throwing prim is OUT") excludes it.
const PURE_PRIMS = [_][]const u8{
    "hd", "tl", "=", "empty?",
    "+", "/", "f/", "*", "-",
    ">", "<", ">=", "<=",
    "bitwise-and", "bitwise-or", "bitwise-xor", "bitwise-not",
    "bitwise-shift-left", "bitwise-shift-right", "bitwise-shift-right-zf",
    "number?", "string?", "symbol?", "boolean?", "cons?",
    "absvector?", "function?", "error?", "stream?", "variable?",
    "element?", "c-strlen", "char-code", "string->n",
    "address->", "<-address", "fst", "snd",
    "get-time", "intern", "set", "value",
};
// gensym/newvar are deliberately OUT: both pop-if-present under the
// nullary-call convention (primGensym/primNewvar), so their runtime stack
// effect diverges from the declared arity the arg-count analysis models;
// a fn using them stays ROOTED (fail-stop via the mark guard at worst).

fn isPurePrim(prim_index: usize) bool {
    const name = std.mem.sliceTo(prims.primByIndex(prim_index).name, 0);
    for (PURE_PRIMS) |p| if (std.mem.eql(u8, p, name)) return true;
    return false;
}

/// Static arg-count analysis: the worklist carries, per path, the open-mark
/// HEIGHT STACK (not just the current height) so the arg count at every
/// apply/appterm site is exact.  Dedupe by the full (pc, height, marks)
/// state; 4096 distinct states is the cap (overflow => ALLOCATING).
const MAX_MARKS: usize = 256; // open-mark nesting bound (overflow => unanalyzable)
const MAX_STATES: usize = 4096;
const ARG_UNSET: i32 = -1; // site unreached (dead) — conservative: ALLOCATING
const ARG_AMBIG: i32 = -2; // multiple distinct counts observed — ALLOCATING

const PathState = struct {
    pc: i32,
    h: i32, // value-stack height (values + marks)
    nmarks: i32,
    marks: [MAX_MARKS]i32, // heights of the open marks, bottom-most first
};

fn recordArg(counts: []i32, pc: i32, argc: i32) void {
    const i: usize = @intCast(pc);
    if (counts[i] == ARG_UNSET) counts[i] = argc
    else if (counts[i] != argc) counts[i] = ARG_AMBIG;
}

fn pushState(a: Allocator, visited: *std.AutoHashMap(PathState, void), wl: *std.ArrayList(PathState), s: PathState) !void {
    if (visited.contains(s)) return;
    if (visited.count() >= MAX_STATES) return error.Overflow;
    try visited.put(s, {});
    try wl.append(a, s);
}

/// Per apply/appterm site pc: ARG_UNSET / ARG_AMBIG / >=0 (unique count).
/// Returns null on state-space overflow (=> ALLOCATING).  Only called on
/// structurally-eligible bodies (no let/grab/cur/first-class apply/appterm),
/// so the reachable ops are the narrow set handled below and the appterm
/// prim fall-through is dead (targets are known defuns => lambdas).
fn analyzeArgCounts(a: Allocator, code: [*]Instr, len: i32) !?[]i32 {
    const n: usize = @intCast(len);
    var counts = try a.alloc(i32, n);
    @memset(counts, ARG_UNSET);

    var visited = std.AutoHashMap(PathState, void).init(a);
    defer visited.deinit();
    var wl = std.ArrayList(PathState).empty;
    defer wl.deinit(a);

    const s0: PathState = .{ .pc = 0, .h = 0, .nmarks = 0, .marks = [_]i32{0} ** MAX_MARKS };
    try visited.put(s0, {});
    try wl.append(a, s0);

    while (wl.pop()) |st| {
        if (st.pc < 0 or st.pc >= len) continue; // bogus target — belt-and-braces
        const ins = &code[@intCast(st.pc)];
        const pc = st.pc;
        switch (ins.op) {
            .number, .string, .symbol, .boolean, .float, .access, .global => {
                var ns = st;
                ns.pc = pc + 1;
                ns.h += 1;
                try pushState(a, &visited, &wl, ns);
            },
            .pushmark => {
                if (st.nmarks >= MAX_MARKS) return null; // nest overflow
                var ns = st;
                ns.pc = pc + 1;
                ns.h += 1;
                ns.marks[@intCast(ns.nmarks)] = ns.h;
                ns.nmarks += 1;
                try pushState(a, &visited, &wl, ns);
            },
            .prim => {
                const arity = prims.primByIndex(@intCast(ins.jmp_target - 1)).arity;
                var ns = st;
                ns.pc = pc + 1;
                ns.h += 1 - @as(i32, arity);
                try pushState(a, &visited, &wl, ns);
            },
            .const_prim, .access_prim => {
                const arity = prims.primByIndex(@intCast(ins.jmp_target - 1)).arity;
                var ns = st;
                ns.pc = pc + 1;
                ns.h += 2 - @as(i32, arity);
                try pushState(a, &visited, &wl, ns);
            },
            .jmp => {
                var ns = st;
                ns.pc = ins.jmp_target;
                try pushState(a, &visited, &wl, ns);
            },
            .jmpf => {
                // pops the condition (1 value), then branches either way.
                var ns = st;
                ns.h -= 1;
                ns.pc = pc + 1;
                try pushState(a, &visited, &wl, ns);
                ns.pc = ins.jmp_target;
                try pushState(a, &visited, &wl, ns);
            },
            .global_apply => {
                // Q fuses load+apply: the fn is NOT on the stack yet, so argc
                // is the values above the mark (h - m).  Popping args+mark and
                // pushing the result leaves the stack at height m.
                if (st.nmarks <= 0) {
                    counts[@intCast(pc)] = ARG_AMBIG;
                    continue;
                }
                const m = st.marks[@intCast(st.nmarks - 1)];
                recordArg(counts, pc, st.h - m);
                var ns = st;
                ns.pc = pc + 1;
                ns.h = m;
                ns.nmarks -= 1;
                ns.marks[@intCast(ns.nmarks)] = 0; // canonicalise the freed slot
                try pushState(a, &visited, &wl, ns);
            },
            .apply => {
                // first-class apply: the fn IS on the stack (pushed by a prior
                // global/cur), so argc excludes it (h - 1 - m).
                if (st.nmarks <= 0) {
                    counts[@intCast(pc)] = ARG_AMBIG;
                    continue;
                }
                const m = st.marks[@intCast(st.nmarks - 1)];
                recordArg(counts, pc, st.h - 1 - m);
                var ns = st;
                ns.pc = pc + 1;
                ns.h = m;
                ns.nmarks -= 1;
                ns.marks[@intCast(ns.nmarks)] = 0;
                try pushState(a, &visited, &wl, ns);
            },
            .global_appterm => {
                // R fuses load+tail: fn not on the stack, argc = h - m.
                if (st.nmarks <= 0) {
                    counts[@intCast(pc)] = ARG_AMBIG;
                    continue;
                }
                const m = st.marks[@intCast(st.nmarks - 1)];
                recordArg(counts, pc, st.h - m);
                const ns: PathState = .{ .pc = 0, .h = 0, .nmarks = 0, .marks = [_]i32{0} ** MAX_MARKS };
                try pushState(a, &visited, &wl, ns);
            },
            .appterm => {
                // first-class tail: fn on the stack, argc = h - 1 - m.
                if (st.nmarks <= 0) {
                    counts[@intCast(pc)] = ARG_AMBIG;
                    continue;
                }
                const m = st.marks[@intCast(st.nmarks - 1)];
                recordArg(counts, pc, st.h - 1 - m);
                const ns: PathState = .{ .pc = 0, .h = 0, .nmarks = 0, .marks = [_]i32{0} ** MAX_MARKS };
                try pushState(a, &visited, &wl, ns);
            },
            // ret / prim_return (return) and let/grab/endlet/cur/count (never
            // present in an eligible body): no successor.
            else => {},
        }
    }
    return counts;
}

/// Local (callee-independent) NON_ALLOCATING requirements of one body:
/// no cur/let/grab/endlet (env capture/extension can alloc), no first-class
/// apply/appterm (generic dispatch can alloc), every prim pure, every
/// .global_apply a KNOWN defun, every .global_appterm SELF (cross-defun tail
/// -> buildEnv alloc; generic tail -> applyGeneric).
fn structurallyEligible(d: Defun, defuns: []const Defun) bool {
    const cur: [*]Instr = @ptrCast(d.code.?);
    var pc: i32 = 0;
    while (pc < d.code_len) : (pc += 1) {
        const ins = &cur[@intCast(pc)];
        switch (ins.op) {
            .cur, .let, .grab, .endlet, .apply, .appterm => return false,
            .prim, .const_prim, .access_prim, .prim_return => {
                if (ins.jmp_target <= 0) return false; // unknown prim — filtered earlier, belt-and-braces
                if (!isPurePrim(@intCast(ins.jmp_target - 1))) return false;
            },
            .global_apply => {
                if (indexOfDefun(defuns, values.symSlice(ins.operand)) == null) return false;
            },
            // Self-tail (R) sites stay ROOTED: the rooted self-tail keeps LLVM's
            // constant-fold of degenerate loops (countdown -> "return 0"), and a
            // stack-env Q-call to a self-tail fn would root the caller's C-stack
            // buffer (ROOT_PTR must point at a GC object HEAD) — unsound.  So a
            // body with ANY global_appterm (self OR cross) is not elided.
            .global_appterm => return false,
            // Benign ops (no alloc, no env/closure effect).  FAIL CLOSED: any
            // op not listed here — including future additions to Opcode — is
            // rejected at the structural layer, so analyzeArgCounts never has
            // to guess a successor for an op it doesn't model.
            .number, .string, .symbol, .boolean, .float,
            .access, .global, .pushmark, .jmp, .jmpf, .ret => {},
            else => return false,
        }
    }
    return true;
}

/// Every Q site's static arg count == target arity; every R site's (self-tail)
/// static arg count == this body's arity.
fn arityMatches(d: Defun, counts: []const i32, defuns: []const Defun) bool {
    const cur: [*]Instr = @ptrCast(d.code.?);
    var pc: i32 = 0;
    while (pc < d.code_len) : (pc += 1) {
        const ins = &cur[@intCast(pc)];
        switch (ins.op) {
            .global_apply => {
                const tslot = indexOfDefun(defuns, values.symSlice(ins.operand)).?;
                if (counts[@intCast(pc)] != defuns[tslot].arity) return false;
            },
            .global_appterm => {
                if (counts[@intCast(pc)] != d.arity) return false;
            },
            else => {},
        }
    }
    return true;
}

/// Greatest fixpoint over the defun call graph.  nonalloc[i] starts true iff
/// the body is locally eligible (structure + static arities), then flips a
/// caller false whenever a Q-site target is ALLOCATING.  Self/mutual
/// recursion is coinductive: a cycle of mutually non-allocating fns stays
/// true (fib/countdown qualify).
fn classifyNonAlloc(defuns: []const Defun, a: Allocator) ![]bool {
    const n = defuns.len;
    var nonalloc = try a.alloc(bool, n);
    for (nonalloc) |*b| b.* = false;

    for (defuns, 0..) |d, i| {
        if (d.arity < 1) continue; // zero-arity thunk entry: env_len can be 0
        if (!structurallyEligible(d, defuns)) continue;
        const c = (try analyzeArgCounts(a, @ptrCast(d.code.?), d.code_len)) orelse continue; // overflow
        if (!arityMatches(d, c, defuns)) continue;
        nonalloc[i] = true;
    }

    var changed = true;
    while (changed) {
        changed = false;
        for (defuns, 0..) |d, i| {
            if (!nonalloc[i]) continue;
            const cur: [*]Instr = @ptrCast(d.code.?);
            var pc: i32 = 0;
            while (pc < d.code_len) : (pc += 1) {
                const ins = &cur[@intCast(pc)];
                if (ins.op == .global_apply) {
                    const tslot = indexOfDefun(defuns, values.symSlice(ins.operand)).?;
                    if (!nonalloc[tslot]) {
                        nonalloc[i] = false;
                        changed = true;
                        break;
                    }
                }
            }
        }
    }
    return nonalloc;
}

// =====================================================================
//  Emission
// =====================================================================

fn emit(
    a: Allocator,
    out: *std.ArrayList(u8),
    defuns: []const Defun,
    curs: []const Cur,
    globals: []const []const u8,
    consts: []const Const,
    entry_name: []const u8,
    nonalloc: []const bool,
) !void {
    try out.appendSlice(a,
        \\// auto-generated by tools/aot/dump.zig — do not edit.
        \\const std = @import("std");
        \\const gc = @import("gc");
        \\const types = gc.types;
        \\const vm_mod = @import("vm");
        \\const values = vm_mod.values;
        \\const state = vm_mod.state;
        \\const interp = vm_mod.interp;
        \\const prims = vm_mod.prims;
        \\const symbols = vm_mod.symbols;
        \\const rt = @import("runtime.zig");
        \\
        \\const Gc = gc.Gc;
        \\const Value = types.Value;
        \\const Vm = state.Vm;
        \\const VmError = state.VmError;
        \\
        \\
    );

    // ---- consts table ----
    try out.print(a, "const N_CONSTS = {d};\n", .{consts.len});
    try out.appendSlice(a, "var consts: [N_CONSTS]Value = undefined;\n");
    try out.appendSlice(a, "var consts_len: i32 = N_CONSTS;\n\n");

    // ---- globals cache ----
    try out.print(a, "const N_GLOBALS = {d};\n", .{globals.len});
    try out.appendSlice(a, "var globals: [N_GLOBALS]Value = undefined;\n");
    try out.appendSlice(a, "var globals_len: i32 = N_GLOBALS;\n\n");

    // ---- pre-built error Value for the elided no-alloc guard (throwStatic) ----
    try out.appendSlice(a, "var err_arity: Value = undefined;\n\n");

    // ---- inline stack ops (P1a) ----
    // The frame's `stk` is a fixed-size C-stack array (never oldgen), so the
    // grow + dirty-check branches of interp.vaPush/vaPop are provably dead.
    // `stk.len` is the stackDepth-sim MAXD (with slack), so the Debug assert
    // re-proves the fixed-depth guarantee before the bounds-checked write.
    try out.appendSlice(a,
        \\inline fn ipush(stk: []Value, len: *i32, v: Value) void {
        \\    std.debug.assert(len.* < @as(i32, @intCast(stk.len)));
        \\    stk[@intCast(len.*)] = v;
        \\    len.* += 1;
        \\}
        \\inline fn ipop(stk: []Value, len: *i32) Value {
        \\    std.debug.assert(len.* > 0);
        \\    len.* -= 1;
        \\    const v = stk[@intCast(len.*)];
        \\    stk[@intCast(len.*)] = values.valNil();
        \\    return v;
        \\}
        \\inline fn ipeek(stk: []Value, len: *i32) Value {
        \\    return stk[@intCast(len.* - 1)];
        \\}
        \\
        \\
    );

    // ---- defun fns (registry slots 0..N_DEFUNS-1) + cur-body fns ----
    for (defuns, 0..) |d, slot| {
        try emitFn(a, out, d.name, d.code, d.code_len, d.maxd, slot, consts, globals, defuns, nonalloc[slot]);
    }
    for (curs, 0..) |c, i| {
        try emitFn(a, out, c.name, c.code, c.code_len, c.maxd, defuns.len + i, consts, globals, defuns, false);
    }

    // ---- aotInit ----
    try out.appendSlice(a, "pub fn aotInit(vm: *Vm) void {\n");
    try out.appendSlice(a, "    const g = vm.gc;\n");
    try out.appendSlice(a, "    g.rootPushValueArray(&consts, &consts_len);\n");
    for (consts, 0..) |c, i| {
        if (c.is_string) {
            try out.print(a, "    consts[{d}] = values.valString(g, ", .{i});
        } else {
            try out.print(a, "    consts[{d}] = symbols.valSymbol(&vm.symbols, ", .{i});
        }
        try emitStringLit(a, out, c.text);
        try out.appendSlice(a, ");\n");
    }
    try out.appendSlice(a, "    g.rootPushValueArray(&globals, &globals_len);\n");
    for (globals, 0..) |nm, i| {
        try out.print(a, "    globals[{d}] = vm.defunGet(", .{i});
        try emitStringLit(a, out, nm);
        try out.appendSlice(a, ");\n");
    }
    // Pre-build the ONE error Value the elided fast paths raise on their
    // (statically-unreachable) malformed-arity guard — valError would alloc
    // inside an elided fn, so it is built once here and rooted with the rest.
    try out.appendSlice(a, "    err_arity = values.valError(g, \"runtime: malformed apply arity\");\n");
    try out.appendSlice(a, "    g.rootPushValue(&err_arity);\n");
    for (defuns, 0..) |d, i| {
        var mbuf: [256]u8 = undefined;
        const mangled = try mangle(&mbuf, d.name);
        try out.print(a, "    rt.reg_fn[{d}] = aot_{s};\n", .{ i, mangled });
        try out.print(a, "    rt.reg_code[{d}] = vm.defunGet(", .{i});
        try emitStringLit(a, out, d.name);
        try out.appendSlice(a, ").payload.lambda.code;\n");
    }
    // Cur bodies: reg_code[cur_slot] is read FRESH from the (already-rooted)
    // parent slot's .cur closure_code field — the same field the generated
    // `.cur` arm reads at runtime.  Parents are assigned before children, so
    // reg_code[parent] is live here.
    for (curs, 0..) |c, i| {
        const slot = defuns.len + i;
        var mbuf: [256]u8 = undefined;
        const mangled = try mangle(&mbuf, c.name);
        try out.print(a, "    rt.reg_fn[{d}] = aot_{s};\n", .{ slot, mangled });
        try out.print(a, "    rt.reg_code[{d}] = rt.origCode({d})[{d}].closure_code;\n", .{ slot, parentSlot(defuns, curs, c), c.pc });
    }
    try out.print(a, "    rt.reg_count = {d};\n", .{defuns.len + curs.len});
    try out.appendSlice(a, "    for (0..N_AOT) |i| g.rootPushPtr(@ptrCast(&rt.reg_code[i]));\n");
    try out.appendSlice(a, "}\n\n");
    try out.print(a, "const N_AOT = {d};\n\n", .{defuns.len + curs.len});

    // ---- entry ----
    var mbuf: [256]u8 = undefined;
    const entry_slot = indexOfDefun(defuns, entry_name).?;
    const mangled = try mangle(&mbuf, defuns[entry_slot].name);
    try out.print(a, "pub fn aotEntry(vm: *Vm, env: ?[*]Value, env_len: i32) VmError!rt.Ret {{\n", .{});
    try out.print(a, "    return aot_{s}(vm, env, env_len);\n", .{mangled});
    try out.appendSlice(a, "}\n");
}

fn emitFn(
    a: Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    code: ?*Instr,
    code_len: i32,
    maxd: i32,
    self_slot: usize,
    consts: []const Const,
    globals: []const []const u8,
    defuns: []const Defun,
    elided: bool,
) !void {
    var mbuf: [256]u8 = undefined;
    const mangled = try mangle(&mbuf, name);
    try out.print(a, "fn aot_{s}(vm: *Vm, env_in: ?[*]Value, env_len_in: i32) VmError!rt.Ret {{\n", .{mangled});
    // Large bodies (the todos app emits fns up to ~512 instrs, ~600
    // `continue :sw` arms) exceed Zig's default 1000 backwards-branch comptime
    // quota during switch analysis.  Compile-time only (zero runtime cost).
    try out.appendSlice(a, "    @setEvalBranchQuota(100000);\n");
    if (elided) {
        try out.print(a,
            \\    const g = vm.gc;
            \\    const a0 = rt.allocStable(g);
            \\    defer rt.assertAllocStable(g, a0);
            \\    rt.elided_calls += 1;
            \\    var acc: Value = values.valNil();
            \\    var stk: [{d}]Value = .{{values.valNil()}} ** {d};
            \\    var stack = types.ValueArray{{ .data = &stk, .len = 0, .cap = {d} }};
            \\    // NO rooting: a NON_ALLOCATING fn performs zero gc_allocs in
            \\    // its whole dynamic extent, so no collection can start and the
            \\    // unrooted acc/stack/env locals can never dangle (the assert
            \\    // above re-proves this per entry/exit in Debug).
            \\
        , .{ maxd, maxd, maxd });
        try out.appendSlice(a,
            \\    const env = env_in;
            \\    const env_len = env_len_in;
            \\    _ = &env; // used only by .access arms (a pure body may not read params)
            \\    _ = &env_len;
            \\    var pc: i32 = 0;
            \\    sw: switch (pc) {
            \\
        );
    } else {
        try out.print(a,
            \\    const g = vm.gc;
            \\    const wm = g.rootWatermark();
            \\    defer g.rootPopTo(wm);
            \\    var acc: Value = values.valNil();
            \\    g.rootPushValue(&acc);
            \\    var stk: [{d}]Value = .{{values.valNil()}} ** {d};
            \\    var stack = types.ValueArray{{ .data = &stk, .len = 0, .cap = {d} }};
            \\    g.rootPushValueArray(&stk, &stack.len);
            \\    // P1b: ONE apply-site argbuf, rooted once for the whole frame.  The
            \\    // ROOT_VALUE_ARRAY count pointer is read at SCAN time, so each apply
            \\    // site just sets argbuf_len = nargs before its alloc window and 0
            \\    // after — no per-site rootPushValueArray/rootPop pair.
            \\    var argbuf: [64]Value = undefined;
            \\    var argbuf_len: i32 = 0;
            \\    g.rootPushValueArray(&argbuf, &argbuf_len);
            \\    var env = env_in;
            \\    var env_len = env_len_in;
            \\    var env_cap = env_len_in;
            \\    g.rootPushPtr(@ptrCast(&env));
            \\    _ = &env_len; // frame slots mutated via &env_len/&env_cap in envPush/tailSelf
            \\    _ = &env_cap;
            \\    var pc: i32 = 0;
            \\    sw: switch (pc) {{
            \\
        , .{ maxd, maxd, maxd });
    }

    const cur: [*]Instr = @ptrCast(code.?);
    var pc: i32 = 0;
    while (pc < code_len) : (pc += 1) {
        const ins = &cur[@intCast(pc)];
        try emitArm(a, out, ins, pc, self_slot, consts, globals, defuns, elided);
    }
    try out.appendSlice(a, "        else => unreachable,\n");
    try out.appendSlice(a, "    }\n");
    try out.appendSlice(a, "}\n\n");
}

fn emitArm(
    a: Allocator,
    out: *std.ArrayList(u8),
    ins: *Instr,
    pc: i32,
    self_slot: usize,
    consts: []const Const,
    globals: []const []const u8,
    defuns: []const Defun,
    elided: bool,
) !void {
    const next = pc + 1;
    switch (ins.op) {
        .number, .string, .symbol, .boolean, .float => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            acc = ");
            try emitConst(a, out, consts, ins.operand);
            try out.appendSlice(a, ";\n            ipush(&stk, &stack.len, acc);\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{next});
        },
        .access => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            acc = interp.lookupEnv(");
            try out.print(a, "{d}", .{ins.jmp_target});
            try out.appendSlice(a, ", env, env_len);\n            ipush(&stk, &stack.len, acc);\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{next});
        },
        .prim => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n");
            try emitPrim(a, out, ins, ";\n            ipush(&stk, &stack.len, acc);\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{next});
        },
        .const_prim => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            acc = ");
            try emitConst(a, out, consts, ins.operand);
            try out.appendSlice(a, ";\n            ipush(&stk, &stack.len, acc);\n");
            try emitPrim(a, out, ins, ";\n            ipush(&stk, &stack.len, acc);\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{next});
        },
        .access_prim => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            acc = interp.lookupEnv(");
            try out.print(a, "{d}", .{ins.operand.payload.number});
            try out.appendSlice(a, ", env, env_len);\n            ipush(&stk, &stack.len, acc);\n");
            try emitPrim(a, out, ins, ";\n            ipush(&stk, &stack.len, acc);\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{next});
        },
        .prim_return => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n");
            try emitPrim(a, out, ins, ";\n            return .{ .done = acc };\n");
            try out.appendSlice(a, "        },\n");
        },
        .pushmark => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            ipush(&stk, &stack.len, values.valMark());\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{next});
        },
        .grab => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a,
                \\            rt.count(1);
                \\            if (stack.len > 0 and ipeek(&stk, &stack.len).tag == .mark) {
                \\                _ = ipop(&stk, &stack.len);
                \\                return .{ .done = acc };
                \\            } else if (stack.len > 0) {
                \\                const v = ipop(&stk, &stack.len);
                \\                interp.envPush(g, &env, &env_len, &env_cap, v);
                \\
            );
            try out.print(a, "                pc = {d};\n                continue :sw pc;\n            }} else {{\n", .{next});
            try out.print(a, "                pc = {d};\n                continue :sw pc;\n            }}\n        }},\n", .{next});
        },
        .let => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            const v: Value = if (stack.len > 0) ipop(&stk, &stack.len) else acc;\n            interp.envPush(g, &env, &env_len, &env_cap, v);\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{next});
        },
        .endlet => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            if (env_len > 0) _ = try interp.envPop(vm, &env, &env_len);\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{next});
        },
        .jmp => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{ins.jmp_target});
        },
        .jmpf => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            const cond: Value = if (stack.len > 0) ipop(&stk, &stack.len) else acc;\n            if (cond.tag == .boolean and cond.payload.boolean == 0) {\n");
            try out.print(a, "                pc = {d};\n                continue :sw pc;\n            }} else {{\n", .{ins.jmp_target});
            try out.print(a, "                pc = {d};\n                continue :sw pc;\n            }}\n        }},\n", .{next});
        },
        .cur => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            acc = values.valLambda(g, rt.origCode(");
            try out.print(a, "{d}", .{self_slot});
            try out.print(a, ")[{d}].closure_code, rt.origCode({d})[{d}].closure_len, env, env_len);\n", .{ pc, self_slot, pc });
            try out.appendSlice(a, "            ipush(&stk, &stack.len, acc);\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{next});
        },
        .ret => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            return .{ .done = acc };\n        },\n");
        },
        .global => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            acc = globals[");
            try out.print(a, "{d}", .{indexOf(globals, values.symSlice(ins.operand)).?});
            try out.appendSlice(a, "];\n            ipush(&stk, &stack.len, acc);\n");
            try out.print(a, "            pc = {d};\n            continue :sw pc;\n        }},\n", .{next});
        },
        .apply => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n");
            try emitApply(a, out, next, null, defuns);
            try out.appendSlice(a, "        },\n");
        },
        .global_apply => {
            const gname = values.symSlice(ins.operand);
            const gslot = indexOf(globals, gname).?;
            if (elided) {
                // Stack-env DIRECT call: target is a known NON_ALLOCATING defun
                // with static nargs == its arity (classification guarantees it).
                const tslot = indexOfDefun(defuns, gname).?;
                try out.print(a, "        {d} => {{\n            rt.count(1);\n", .{pc});
                try emitStackEnvCall(a, out, next, tslot, defuns[tslot].arity, defuns);
                try out.appendSlice(a, "        },\n");
            } else {
                try out.print(a, "        {d} => {{\n", .{pc});
                try out.appendSlice(a, "            rt.count(1);\n            acc = globals[");
                try out.print(a, "{d}", .{gslot});
                try out.appendSlice(a, "];\n            ipush(&stk, &stack.len, acc);\n");
                if (indexOfDefun(defuns, gname)) |slot| {
                    try emitApply(a, out, next, KnownTarget{ .slot = slot, .global = gslot }, defuns);
                } else {
                    try emitApply(a, out, next, null, defuns);
                }
                try out.appendSlice(a, "        },\n");
            }
        },
        .appterm => {
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n");
            try emitAppterm(a, out, next, null, defuns, null);
            try out.appendSlice(a, "        },\n");
        },
        .global_appterm => {
            // An elided fn never reaches here (structurallyEligible rejects any
            // .global_appterm), so this arm is the rooted P1 shape only.
            const gname = values.symSlice(ins.operand);
            const gslot = indexOf(globals, gname).?;
            try out.print(a, "        {d} => {{\n", .{pc});
            try out.appendSlice(a, "            rt.count(1);\n            acc = globals[");
            try out.print(a, "{d}", .{gslot});
            try out.appendSlice(a, "];\n            ipush(&stk, &stack.len, acc);\n");
            if (indexOfDefun(defuns, gname)) |slot| {
                if (slot == self_slot) {
                    // SELF-tail: rebuild the env IN PLACE (tailSelf reuse) and
                    // jump to pc=0 in the SAME frame — constant native stack,
                    // no per-iteration alloc (crux A tier 1).
                    try emitAppterm(a, out, next, KnownTarget{ .slot = slot, .global = gslot }, defuns, gslot);
                } else {
                    try emitAppterm(a, out, next, KnownTarget{ .slot = slot, .global = gslot }, defuns, null);
                }
            } else {
                try emitAppterm(a, out, next, null, defuns, null);
            }
            try out.appendSlice(a, "        },\n");
        },
        .count => {
            std.debug.print("aotdump: warning: unknown op at pc={d} — emitting unreachable\n", .{pc});
            try out.print(a, "        {d} => unreachable,\n", .{pc});
        },
    }
}

const KnownTarget = struct { slot: usize, global: usize };

/// Elided Q-site stack-env direct call (Phase 2): pops exactly `arity` args
/// into a SITE-LOCAL `senv` buffer (a distinct stack array per site — never
/// the fn's own env), guards the mark (malformed arity => throwStatic, which
/// does NOT allocate), and direct-calls the target with the C-stack buffer as
/// its env — no buildEnv alloc, no bounce (a NON_ALLOCATING target never
/// returns .tail).
fn emitStackEnvCall(a: Allocator, out: *std.ArrayList(u8), next: i32, target_slot: usize, arity: i32, defuns: []const Defun) !void {
    var mbuf: [256]u8 = undefined;
    const kmangled = try mangle(&mbuf, defuns[target_slot].name);
    try out.print(a,
        \\            rt.stack_env_calls += 1;
        \\            var senv: [{d}]Value = undefined;
        \\
    , .{arity});
    var ai: i32 = 0;
    while (ai < arity) : (ai += 1) {
        try out.print(a, "            senv[{d}] = ipop(&stk, &stack.len);\n", .{ai});
    }
    try out.print(a,
        \\            if (stack.len == 0 or ipeek(&stk, &stack.len).tag != .mark)
        \\                return rt.throwStatic(vm, err_arity);
        \\            _ = ipop(&stk, &stack.len);
        \\            const r = aot_{s}(vm, &senv, {d}) catch |e| switch (e) {{
        \\                error.Halt => return .{{ .done = acc }},
        \\                error.ShenError => return error.ShenError,
        \\            }};
        \\            acc = r.done;
        \\            ipush(&stk, &stack.len, acc);
        \\            pc = {d};
        \\            continue :sw pc;
        \\
    , .{ kmangled, arity, next });
}

/// The non-tail apply body (function already on top of the value stack).
fn emitApply(a: Allocator, out: *std.ArrayList(u8), next: i32, known: ?KnownTarget, defuns: []const Defun) !void {
    try out.appendSlice(a,
        \\            if (stack.len > 0) acc = ipop(&stk, &stack.len);
        \\            if (acc.tag == .lambda) {
        \\                var nargs: i32 = 0;
        \\                while (stack.len > 0 and ipeek(&stk, &stack.len).tag != .mark) {
        \\                    if (nargs < 64) { argbuf[@intCast(nargs)] = ipop(&stk, &stack.len); nargs += 1; } else { return vm.throwShen("runtime: too many args (>64)"); }
        \\                }
        \\                if (stack.len == 0 or ipeek(&stk, &stack.len).tag != .mark) {
        \\                    std.debug.print("runtime: apply missing pushmark\n", .{});
        \\                    return .{ .done = acc };
        \\                }
        \\                _ = ipop(&stk, &stack.len);
        \\                argbuf_len = nargs;
        \\
    );
    if (known) |k| {
        // known direct call — INLINE fast path (P1c): arity check + buildEnv +
        // direct target call + a local bounce loop, instead of the rt.callKnown
        // call layer (the mismatch case still falls back to rt.applyGeneric).
        var mbuf: [256]u8 = undefined;
        const kmangled = try mangle(&mbuf, defuns[k.slot].name);
        const arity = defuns[k.slot].arity;
        try out.print(a,
            \\                {{
            \\                    var r: rt.Ret = undefined;
            \\                    if (nargs == {d}) {{
            \\                        const built = rt.buildEnv(g, &acc, &argbuf, nargs);
            \\                        r = aot_{s}(vm, built.env, built.len) catch |e| switch (e) {{
            \\                            error.Halt => return .{{ .done = acc }},
            \\                            error.ShenError => return error.ShenError,
            \\                        }};
            \\                    }} else {{
            \\                        // N<A (partial) or N>A (peel): route the LOCAL
            \\                        // &acc (a rooted copy of the global) so the
            \\                        // partial/peel result is built in the frame slot —
            \\                        // NEVER in the globals cache (applyGeneric writes
            \\                        // cl.* = buildPartialClosure, which would corrupt
            \\                        // the shared global for every later caller).
            \\                        var nn = nargs;
            \\                        r = rt.applyGeneric(vm, &acc, &argbuf, &nn, false) catch |e| switch (e) {{
            \\                            error.Halt => return .{{ .done = acc }},
            \\                            error.ShenError => return error.ShenError,
            \\                        }};
            \\                    }}
            \\                    while (true) {{
            \\                        switch (r) {{
            \\                            .done => |v| {{ acc = v; break; }},
            \\                            .tail => |t| r = t.f(vm, t.env, t.env_len) catch |e| switch (e) {{
            \\                                error.Halt => return .{{ .done = acc }},
            \\                                error.ShenError => return error.ShenError,
            \\                            }},
            \\                        }}
            \\                    }}
            \\                }}
            \\
        , .{ arity, kmangled });
    } else {
        try out.appendSlice(a,
            \\                {
            \\                    const r = rt.applyGeneric(vm, &acc, &argbuf, &nargs, false) catch |e| switch (e) {
            \\                        error.Halt => return .{ .done = acc },
            \\                        error.ShenError => return error.ShenError,
            \\                    };
            \\                    acc = r.done;
            \\                }
            \\
        );
    }
    try out.appendSlice(a,
        \\                argbuf_len = 0;
        \\                ipush(&stk, &stack.len, acc);
        \\
    );
    try out.print(a, "                pc = {d};\n                continue :sw pc;\n", .{next});
    try out.appendSlice(a,
        \\            } else if (acc.tag == .prim) {
        \\                if (stack.len > 0 and ipeek(&stk, &stack.len).tag == .mark) _ = ipop(&stk, &stack.len);
        \\                const pn = values.primSlice(acc);
        \\                prims.execPrimitive(vm, pn, &acc, &stack) catch |e| switch (e) {
        \\                    error.Halt => return .{ .done = acc },
        \\                    error.ShenError => return error.ShenError,
        \\                };
        \\                ipush(&stk, &stack.len, acc);
        \\
    );
    try out.print(a, "                pc = {d};\n                continue :sw pc;\n", .{next});
    try out.appendSlice(a,
        \\            } else {
        \\                if (vm.catch_chain != null and vm.catch_chain.?.in_trap_error)
        \\                    return vm.throwShen("apply non-callable");
        \\                std.debug.print("runtime: apply non-callable tag={d}", .{@intFromEnum(acc.tag)});
        \\                return .{ .done = acc };
        \\            }
        \\
    );
}

/// The tail appterm body (function already on top of the value stack).
/// self_global (non-null) = the globals-cache slot of the SELF-tail target:
/// the env is rebuilt IN PLACE via rt.tailSelf and the frame jumps to pc=0
/// (constant native stack, no per-iteration alloc).  Otherwise a known target
/// returns a cross-defun .tail (bounced by the caller), and an unknown target
/// falls to rt.applyGeneric.
fn emitAppterm(a: Allocator, out: *std.ArrayList(u8), next: i32, known: ?KnownTarget, defuns: []const Defun, self_global: ?usize) !void {
    try out.appendSlice(a,
        \\            if (stack.len > 0) acc = ipop(&stk, &stack.len);
        \\            if (acc.tag == .lambda) {
        \\                if (stack.len <= 0) { std.debug.print("runtime: appterm empty stack\n", .{}); return .{ .done = acc }; }
        \\                var nargs: i32 = 0;
        \\                while (stack.len > 0 and ipeek(&stk, &stack.len).tag != .mark) {
        \\                    if (nargs < 64) { argbuf[@intCast(nargs)] = ipop(&stk, &stack.len); nargs += 1; } else { return vm.throwShen("runtime: appterm too many args (>64)"); }
        \\                }
        \\                if (stack.len == 0 or ipeek(&stk, &stack.len).tag != .mark) {
        \\                    std.debug.print("runtime: appterm missing pushmark\n", .{});
        \\                    return .{ .done = acc };
        \\                }
        \\                _ = ipop(&stk, &stack.len);
        \\                if (nargs == 0) { std.debug.print("runtime: appterm zero args\n", .{}); return .{ .done = acc }; }
        \\                argbuf_len = nargs;
        \\
    );
    if (self_global) |gs| {
        try out.print(a, "                rt.tailSelf(vm, &globals[{d}], &env, &env_len, &env_cap, &argbuf, nargs);\n", .{gs});
        try out.appendSlice(a, "                argbuf_len = 0;\n                pc = 0;\n                continue :sw 0;\n");
    } else if (known) |k| {
        // &acc (not &globals[k.global]): applyGeneric WRITES the cl slot when
        // N<A builds a partial — a write through the globals cache would
        // corrupt the shared global for every later site.  acc is rooted and
        // already holds the popped copy of the global.
        try out.print(a, "                {{\n                    const r = rt.tailKnown(vm, &acc, ", .{});
        try emitTarget(a, out, defuns, k.slot);
        try out.appendSlice(a, ", &argbuf, nargs) catch |e| switch (e) {\n                        error.Halt => return .{ .done = acc },\n                        error.ShenError => return error.ShenError,\n                    };\n                    argbuf_len = 0;\n                    return r;\n                }\n");
    } else {
        try out.appendSlice(a,
            \\                {
            \\                    const r = rt.applyGeneric(vm, &acc, &argbuf, &nargs, true) catch |e| switch (e) {
            \\                        error.Halt => return .{ .done = acc },
            \\                        error.ShenError => return error.ShenError,
            \\                    };
            \\                    argbuf_len = 0;
            \\                    return r;
            \\                }
            \\
        );
    }
    try out.appendSlice(a,
        \\            } else if (acc.tag == .prim) {
        \\                if (stack.len > 0 and ipeek(&stk, &stack.len).tag == .mark) _ = ipop(&stk, &stack.len);
        \\                const pn = values.primSlice(acc);
        \\                prims.execPrimitive(vm, pn, &acc, &stack) catch |e| switch (e) {
        \\                    error.Halt => return .{ .done = acc },
        \\                    error.ShenError => return error.ShenError,
        \\                };
        \\                ipush(&stk, &stack.len, acc);
        \\
    );
    try out.print(a, "                pc = {d};\n                continue :sw pc;\n", .{next});
    try out.appendSlice(a,
        \\            } else {
        \\                if (vm.catch_chain != null and vm.catch_chain.?.in_trap_error)
        \\                    return vm.throwShen("appterm non-lambda");
        \\                std.debug.print("runtime: appterm non-lambda\n", .{});
        \\                return .{ .done = acc };
        \\            }
        \\
    );
}

/// Emit the prim call + Halt/ShenError routing, followed by `suffix`.
fn emitPrim(a: Allocator, out: *std.ArrayList(u8), ins: *Instr, suffix: []const u8) !void {
    try out.print(a, "            prims.primByIndex({d}).func(vm, &acc, &stack) catch |e| switch (e) {{\n                error.Halt => return .{{ .done = acc }},\n                error.ShenError => return error.ShenError,\n            }}", .{ins.jmp_target - 1});
    try out.appendSlice(a, suffix);
}

/// Emit `<arity>, aot_<mangled>` for a known target slot.
fn emitTarget(a: Allocator, out: *std.ArrayList(u8), defuns: []const Defun, slot: usize) !void {
    var mbuf: [256]u8 = undefined;
    const mangled = try mangle(&mbuf, defuns[slot].name);
    try out.print(a, "{d}, aot_{s}", .{ defuns[slot].arity, mangled });
}

fn emitConst(a: Allocator, out: *std.ArrayList(u8), consts: []const Const, v: Value) !void {
    switch (v.tag) {
        .number => try out.print(a, "values.valNumber({d})", .{v.payload.number}),
        .boolean => try out.print(a, "values.valBoolean({s})", .{if (v.payload.boolean != 0) "true" else "false"}),
        .float => try out.print(a, "values.valFloat({d})", .{v.payload.float}),
        .string => try out.print(a, "consts[{d}]", .{constIndex(consts, true, values.strSlice(v))}),
        .symbol => try out.print(a, "consts[{d}]", .{constIndex(consts, false, values.symSlice(v))}),
        else => unreachable,
    }
}

fn emitStringLit(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            0 => try out.appendSlice(a, "\\x00"),
            else => {
                if (c < 0x20 or c >= 0x7f) {
                    var buf: [8]u8 = undefined;
                    const t = try std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c});
                    try out.appendSlice(a, t);
                } else {
                    try out.append(a, c);
                }
            },
        }
    }
    try out.append(a, '"');
}

/// Hex-escape a defun name into a valid Zig identifier suffix.
/// error.NameTooLong: the mangled name doesn't fit `buf` (defun names are
/// bounded in practice, but a cur's synthesized "<parent>_c<pc>" can nest).
fn mangle(buf: []u8, name: []const u8) error{NameTooLong}![]const u8 {
    const hex = "0123456789abcdef";
    var i: usize = 0;
    for (name) |c| {
        if (i + 3 > buf.len) return error.NameTooLong;
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            buf[i] = c;
            i += 1;
        } else {
            buf[i] = '_';
            buf[i + 1] = hex[@intCast(c >> 4)];
            buf[i + 2] = hex[@intCast(c & 0xf)];
            i += 3;
        }
    }
    return buf[0..i];
}
