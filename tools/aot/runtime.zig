//! tools/aot/runtime.zig — the AOT-to-Zig runtime (aotrt), shared by every
//! generated module and the aotbench driver.
//!
//! This is the handwritten half of the spike: the generated Zig (aotdump
//! output) reifies each defun body as a labeled-switch function, and calls
//! back into this module for the three things that must be shared with the
//! interpreter — tail-call dispatch, GC rooting around env builds, and the
//! code-array -> native-fn registry.
//!
//! DESIGN CONTRACT (see tools/aot/../../docs/aot-spike.md for the full writeup):
//!   - Ret is the AOT call result: either a finished Value (.done) or a
//!     cross-defun tail call (.tail).  Every caller (callKnown / applyGeneric
//!     / the driver) bounces .tail until .done — Zig has no TCO, so the
//!     bounce loop is what keeps deep tail chains on constant native stack.
//!   - buildEnv / tailSelf mirror interp.zig's apply/appterm N==A env build
//!     VERBATIM (same alloc, same barrier dance, same fresh post-alloc reads
//!     of the closure fields through a rooted slot).  Nothing here caches a
//!     derived pointer across an alloc.
//!   - The registry maps a closure's ORIGINAL Instr-array pointer to its
//!     native fn.  reg_code[i] slots are rootPushPtr'd once at aotInit so the
//!     pointer compares stay valid across GC moves.

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const vm_mod = @import("vm");
const values = vm_mod.values;
const state = vm_mod.state;
const interp = vm_mod.interp;
const prims = vm_mod.prims;

const Gc = gc.Gc;
const Value = types.Value;
const Instr = types.Instr;
const Vm = state.Vm;
const VmError = state.VmError;

// =====================================================================
//  Call-result shape + function type
// =====================================================================

/// A native AOT'd defun: enters with an owned env array (single referee),
/// roots it in its prologue, and returns either a finished value or a
/// cross-defun tail call.
pub const AotFn = *const fn (vm: *Vm, env: ?[*]Value, env_len: i32) VmError!Ret;

pub const Tail = struct {
    f: AotFn,
    env: ?[*]Value,
    env_len: i32,
};

pub const Ret = union(enum) {
    done: Value,
    tail: Tail,
};

// =====================================================================
//  Instruction-parity counter (drives the aotbench ns/instr report)
// =====================================================================

/// When false, count() compiles to nothing (pure-speed runs).  The driver's
/// ns/instr report reads the delta in `instrs` between its timed window.
pub const COUNT_INSTRS = true;
pub var instrs: u64 = 0;

pub inline fn count(n: u64) void {
    if (COUNT_INSTRS) instrs += n;
}

// =====================================================================
//  Phase-2 counters (reported in the aotbench line)
// =====================================================================

/// Frames entered by a NON_ALLOCATING (rooting-elided) fn.
pub var elided_calls: u64 = 0;
/// Stack-env direct calls emitted (no buildEnv, no bounce).
pub var stack_env_calls: u64 = 0;
/// First-class applies of an UNREGISTERED closure -> interpreted vmExecEnv.
pub var vmexec_fallbacks: u64 = 0;

// =====================================================================
//  Registry: code-array identity -> native fn
// =====================================================================

pub const REG_MAX = 1024;

/// The native fn per AOT'd defun (index = the defun's registry slot).
pub var reg_fn: [REG_MAX]AotFn = undefined;
/// The defun body's ORIGINAL Instr-array head per slot — each slot is
/// rootPushPtr'd at aotInit so the identity compare in lookup() stays valid
/// after a moving collect.  Also re-read by generated `.cur` arms.
pub var reg_code: [REG_MAX]?*Instr = undefined;
pub var reg_count: usize = 0;

/// The RUNTIME partial-application registry (Phase 4).  A partial closure
/// (buildPartialClosure) has a FRESHLY-ALLOCATED code array (a drop-grabs
/// suffix copy of its source), so its pointer is never in reg_code — the
/// Tea update/continuation closures are partials, and lookup() missed them
/// to vmExecEnv.  When applyGeneric builds a partial FROM a registered
/// source it records the partial's fresh code pointer -> the SAME target
/// AotFn (a full apply of a partial runs the original body with env =
/// captured ++ args, so the target fn is unchanged; a partial of a partial
/// resolves transitively through lookup() before the build).  Slots are
/// rootPushPtr'd at creation; on overflow the partial is simply left
/// unregistered (correct — lookup() misses it and the interpreter runs it).
pub var pfn: [REG_MAX]AotFn = undefined;
pub var pcode: [REG_MAX]?*Instr = undefined;
pub var pcount: usize = 0;

/// Linear scan: the closure's fresh-read code pointer vs each rooted slot.
/// Precondition: cl.tag == .lambda.
pub fn lookup(cl: Value) ?AotFn {
    const code = cl.payload.lambda.code;
    var i: usize = 0;
    while (i < reg_count) : (i += 1) {
        if (reg_code[i] == code) return reg_fn[i];
    }
    i = 0;
    while (i < pcount) : (i += 1) {
        if (pcode[i] == code) return pfn[i];
    }
    return null;
}

/// The ORIGINAL body Instr array for registry slot `slot` — the same array
/// the interpreter's `.cur` arm reads closure_code from.  reg_code[slot] is
/// a rooted slot, so this read is fresh (post-GC-move).  Generated `.cur`
/// arms index it: rt.origCode(SELF)[pc].closure_code.
pub inline fn origCode(slot: usize) [*]Instr {
    return @ptrCast(reg_code[slot].?);
}

// =====================================================================
//  Tail-call bounce (tier 2)
// =====================================================================

/// Runs r to completion, chasing cross-defun .tail links — constant native
/// stack across arbitrary tail chains (self-tails already loop inside a
/// single frame via tailSelf + `continue :sw 0`).
pub fn bounce(vm: *Vm, r: Ret) VmError!Value {
    var rr = r;
    while (true) {
        switch (rr) {
            .done => |v| return v,
            .tail => |t| rr = try t.f(vm, t.env, t.env_len),
        }
    }
}

// =====================================================================
//  Phase-2 rooting-elision backstop + no-alloc error raise
// =====================================================================

/// Snapshot the Debug allocation counter for an elided fn's entry.  In
/// ReleaseFast/Small the load is dead-code-eliminated (its only use is the
/// assert below, whose failure path is `unreachable`), so this is zero-cost
/// in release; live in Debug/ReleaseSafe.
pub inline fn allocStable(g: *Gc) u64 {
    return g.debug_allocs;
}

/// Entry/exit backstop for an elided fn: the count must be unchanged, i.e. no
/// gc_alloc ran in the fn's whole dynamic extent, so no collection could have
/// moved its unrooted acc/stack/env locals.
pub inline fn assertAllocStable(g: *Gc, a0: u64) void {
    std.debug.assert(g.debug_allocs == a0);
}

/// Raise a Shen error WITHOUT allocating (throwShen -> valError -> gc_alloc).
/// The elided fast paths use this for their malformed-arity guard: the error
/// Value is PRE-BUILT once at aotInit (rooted with the consts table) and just
/// assigned into vm.err_slot here.
pub fn throwStatic(vm: *Vm, err: Value) VmError {
    vm.err_slot = err;
    return error.ShenError;
}

// =====================================================================
//  Env builds (verbatim interp.zig apply/appterm N==A)
// =====================================================================

pub const BuiltEnv = struct {
    env: ?[*]Value,
    len: i32,
};

/// Fresh env = closure_env ++ argbuf[0..nargs] — interp.zig:887-919.
/// cl is a ROOTED slot (the generated fn's &acc, or a globals-cache slot);
/// every lambda field is read fresh AFTER the alloc.  The returned array is
/// single-referee and handed straight to the callee, whose prologue roots it
/// before its first alloc (no alloc in the handoff window).
pub fn buildEnv(g: *Gc, cl: *Value, argbuf: [*]Value, nargs: i32) BuiltEnv {
    const lambda_env_len = cl.payload.lambda.env_len; // i32 — GC-invariant
    const new_env_len = lambda_env_len + nargs;
    const ne = g.allocArray(Value, @intCast(new_env_len));
    const lambda_env = cl.payload.lambda.env; // fresh post-alloc read
    const ne_is_oldgen = g.inOldgen(@intFromPtr(ne));
    if (lambda_env_len > 0 and lambda_env != null) {
        const lel: usize = @intCast(lambda_env_len);
        @memcpy(ne[0..lel], lambda_env.?[0..lel]);
        if (ne_is_oldgen) {
            var j: usize = 0;
            while (j < lel) : (j += 1) {
                if (gc.scan.valueReferencesNursery(g, &lambda_env.?[j])) {
                    g.dirtyVectorsAdd(ne);
                    break;
                }
            }
        }
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(nargs))) : (i += 1) {
        const idx = @as(usize, @intCast(lambda_env_len)) + i;
        ne[idx] = argbuf[i];
        if (ne_is_oldgen and gc.scan.valueReferencesNursery(g, &argbuf[i]))
            g.dirtyVectorsAdd(ne);
    }
    return .{ .env = ne, .len = new_env_len };
}

/// Self-tail env rebuild IN PLACE — interp.zig:1216-1275 (the M11 reuse).
/// The current env array (rooted by the running frame's &env slot) is dead
/// past the tail jump, so it is reused when env_cap fits; otherwise a fresh
/// exact-size alloc replaces it.  The dead tail [new_env_len..env_cap) is
/// nil-cleared and env_cap stays the TRUE physical capacity.  env/env_len/
/// env_cap are the caller's frame locals (env is the rooted slot).
pub fn tailSelf(
    vm: *Vm,
    cl: *Value,
    env: *?[*]Value,
    env_len: *i32,
    env_cap: *i32,
    argbuf: [*]Value,
    nargs: i32,
) void {
    const g = vm.gc;
    const lambda_env_len = cl.payload.lambda.env_len;
    const new_env_len = lambda_env_len + nargs;
    const reuse = env.* != null and env_cap.* >= new_env_len;
    const ne: [*]Value = if (reuse) env.*.? else g.allocArray(Value, @intCast(new_env_len));
    const new_cap: i32 = if (reuse) env_cap.* else new_env_len;
    if (reuse) {
        if (env_cap.* > new_env_len) {
            const tail: usize = @intCast(new_env_len);
            const cap: usize = @intCast(env_cap.*);
            @memset(ne[tail..cap], values.valNil());
        }
        vm.env_reuse_hits += 1;
    } else {
        vm.env_reuse_misses += 1;
    }
    // NO-ALLOC WINDOW from here to `env.* = ne`: ne may alias the rooted
    // env slot's array, so every statement is alloc-free (memcpy / nil
    // stores / dirtyVectorsAdd are non-allocating) — interp.zig:1238-1247.
    const lambda_env = cl.payload.lambda.env; // fresh read
    const ne_is_oldgen = g.inOldgen(@intFromPtr(ne));
    if (lambda_env_len > 0 and lambda_env != null) {
        const lel: usize = @intCast(lambda_env_len);
        @memcpy(ne[0..lel], lambda_env.?[0..lel]);
        if (ne_is_oldgen) {
            var j: usize = 0;
            while (j < lel) : (j += 1) {
                if (gc.scan.valueReferencesNursery(g, &lambda_env.?[j])) {
                    g.dirtyVectorsAdd(ne);
                    break;
                }
            }
        }
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(nargs))) : (i += 1) {
        const idx = @as(usize, @intCast(lambda_env_len)) + i;
        ne[idx] = argbuf[i];
        if (ne_is_oldgen and gc.scan.valueReferencesNursery(g, &argbuf[i]))
            g.dirtyVectorsAdd(ne);
    }
    env.* = ne;
    env_len.* = new_env_len;
    env_cap.* = new_cap;
}

// =====================================================================
//  Host->Elm apply (Phase 4): the AOT-aware seam the effect loop uses
// =====================================================================

/// Mirrors vendor hostcall.applyClosureN's arg budget (the M9 host call sites
/// are 1 continuation/handler arg or 2 update args; 8 leaves headroom).
pub const MAX_HOSTCALL_ARGS = 8;

/// The registry-aware host call.  Semantically identical to
/// hostcall.applyClosureN — captured env EXTENDED by the call args (the
/// args ride AFTER env_len so `access 0` reaches the last arg exactly like a
/// normal apply) — but LOOKUP-FIRST: a registered closure native-dispatches
/// (buildEnv + direct call + bounce), an unregistered one falls back to the
/// same interpreted vmExecEnv the host used before.  The effect loop installs
/// this via its `host_apply` fn-pointer hook at aotInit, so it stays
/// AOT-optional (it never imports this module).
pub fn applyHost(vm: *Vm, fnv_in: Value, args: []const Value) VmError!Value {
    const g = vm.gc;
    std.debug.assert(args.len <= MAX_HOSTCALL_ARGS);
    var fnv = fnv_in;
    std.debug.assert(fnv.tag == .lambda);

    // Rooting identical to applyClosureN: fnv + the arg array are rooted
    // across the env alloc; every fnv field read afterwards is FRESH (the
    // rooted slot is updated if a collect moves the closure).
    g.rootPushValue(&fnv);
    var argbuf: [MAX_HOSTCALL_ARGS]Value = undefined;
    var nargs: i32 = 0;
    for (args) |av| {
        argbuf[@intCast(nargs)] = av;
        nargs += 1;
    }
    g.rootPushValueArray(&argbuf, &nargs);

    // env = captured ++ args (the exact applyClosureN / buildEnv dance).
    const built = buildEnv(g, &fnv, &argbuf, nargs);

    if (lookup(fnv)) |f| {
        g.rootPop(); // argbuf
        g.rootPop(); // fnv
        return bounce(vm, try f(vm, built.env, built.len));
    }
    const code = fnv.payload.lambda.code;
    const code_len = fnv.payload.lambda.code_len;
    g.rootPop(); // argbuf
    g.rootPop(); // fnv
    vmexec_fallbacks += 1;
    return try interp.vmExecEnv(vm, code, code_len, built.env, built.len);
}

// =====================================================================
//  Call sites
// =====================================================================

/// Non-tail known-global call (fused Q = global + apply): fast path when the
/// runtime arg count matches the emit-time arity, else the generic apply
/// (currying / peel).  Returns the fully-bounced result value.
pub fn callKnown(
    vm: *Vm,
    globals_k: *Value,
    expect_arity: i32,
    comptime target: AotFn,
    argbuf: *[64]Value,
    nargs: i32,
) VmError!Value {
    if (nargs == expect_arity) {
        const built = buildEnv(vm.gc, globals_k, argbuf, nargs);
        return bounce(vm, try target(vm, built.env, built.len));
    }
    // N<A (partial) / N>A (peel): applyGeneric WRITES cl.* (the partial lands
    // there) — copy the global into a rooted frame-local first so the shared
    // globals cache is never mutated (a moving collect keeps the copy fresh).
    var cl = globals_k.*;
    vm.gc.rootPushValue(&cl);
    defer vm.gc.rootPop();
    var nn = nargs;
    const r = try applyGeneric(vm, &cl, argbuf, &nn, false);
    return bounce(vm, r);
}

/// Tail known-global call (fused R = global + appterm): fast path returns a
/// .tail for the bounce loop; arity mismatch falls to the generic appterm.
pub fn tailKnown(
    vm: *Vm,
    globals_k: *Value,
    expect_arity: i32,
    comptime target: AotFn,
    argbuf: *[64]Value,
    nargs: i32,
) VmError!Ret {
    if (nargs == expect_arity) {
        const built = buildEnv(vm.gc, globals_k, argbuf, nargs);
        return .{ .tail = .{ .f = target, .env = built.env, .env_len = built.len } };
    }
    // Same globals-cache protection as callKnown: applyGeneric writes cl.*.
    var cl = globals_k.*;
    vm.gc.rootPushValue(&cl);
    defer vm.gc.rootPop();
    var nn = nargs;
    return applyGeneric(vm, &cl, argbuf, &nn, true);
}

/// Generic apply/appterm of a first-class closure.  cl is a ROOTED,
/// CALLER-OWNED frame slot: this fn may WRITE cl.* (the N<A partial lands
/// there), so a shared/persistent slot — e.g. a globals-cache entry — must
/// never be passed directly; copy into a rooted local first (see callKnown).
/// argbuf is the caller's rootPushValueArray pair (live below this entry).
/// Matches interp.zig's .apply/.appterm arity dispatch: N>A peels, N==A (or
/// N==0) full-calls via the registry (native) or vmExecEnv (interpreted),
/// N<A builds a partial closure.  tail=true returns .tail for the full call
/// (caller bounces); tail=false bounces internally and returns .done.
pub fn applyGeneric(
    vm: *Vm,
    cl: *Value,
    argbuf: *[64]Value,
    nargs: *i32,
    tail: bool,
) VmError!Ret {
    const g = vm.gc;
    var arity = interp.zincArity(cl.payload.lambda.code, cl.payload.lambda.code_len);
    if (nargs.* > arity) {
        try interp.peelOverArgs(vm, cl, argbuf, nargs, if (tail) "appterm" else "apply");
        if (cl.tag == .lambda)
            arity = interp.zincArity(cl.payload.lambda.code, cl.payload.lambda.code_len);
    }

    if (cl.tag == .lambda and (nargs.* == arity or nargs.* == 0)) {
        const built = buildEnv(g, cl, argbuf, nargs.*);
        if (lookup(cl.*)) |f| {
            if (tail)
                return .{ .tail = .{ .f = f, .env = built.env, .env_len = built.len } };
            return .{ .done = try bounce(vm, try f(vm, built.env, built.len)) };
        }
        // Unknown closure: run its ORIGINAL body through the interpreter,
        // which handles its own appterm tails internally (never grows native
        // stack).  built.env is a fresh single-referee array handed straight
        // to vmExecEnv, whose prologue copies + roots it.
        vmexec_fallbacks += 1;
        const v = try interp.vmExecEnv(vm, cl.payload.lambda.code, cl.payload.lambda.code_len, built.env, built.len);
        return .{ .done = v };
    }

    // N<A (nargs>0) partial closure, or a post-peel final value (non-lambda,
    // nargs==0 — never read lambda fields then).
    if (cl.tag == .lambda and nargs.* > 0) {
        // Resolve the SOURCE's native target BEFORE the build: a partial of a
        // defun/cur/partial all funnel to one AotFn (see the pcode contract
        // above).  Unknown source -> unregistered partial -> interpreter later.
        const target = lookup(cl.*);
        cl.* = interp.buildPartialClosure(g, cl, argbuf, nargs.*);
        if (target) |f| {
            if (pcount < REG_MAX) {
                pcode[pcount] = cl.*.payload.lambda.code;
                pfn[pcount] = f;
                g.rootPushPtr(@ptrCast(&pcode[pcount]));
                pcount += 1;
            }
        }
    }
    return .{ .done = cl.* };
}
