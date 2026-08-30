//! src/effectloop.zig — the M9 HOST-SIDE effect-manager event loop.
//!
//! (fx-ui-only consumer module over the zinc-vm package's `vm`; moved
//! consumer-side in extraction P2 — it is NOT part of the zinc-vm package.)
//!
//! Design A (plan M9): effects run in the HOST, not by suspending a half-run
//! vmExecEnv (which is a deep native recursion — see interp.zig).  `main`
//! returns a Program as DATA — a vector[Program, model0, cmd0, updateFn] with
//! tag = bare symbol 'Program'.  This module interprets each Task natively
//! (a CEK machine over the Task ADT) with nonblocking I/O via std.posix.poll,
//! applies continuation closures via hostcall.applyClosureN (a FRESH vmExecEnv
//! call), feeds completed msgs to update, and loops until the work set is
//! empty and no effects are pending.
//!
//! THE TASK LAYOUT CONTRACT (the host owns this): a Task is the MX ADT rep
//! vector[tag, a1..an] — data[0] is a BARE tag Symbol, data[1..n] are the
//! ctor args in source order (Lower.Module.ctorEntry).  TaskAndThen ->
//! data[1]=cont closure, data[2]=inner task.  TaskReadFile -> data[1]=path
//! string.  The host compares values.symSlice(data[0]) against the ctor names.
//!
//! CONCURRENCY MODEL: each Task in the Cmd list becomes one *evaluation*.  A
//! pure evaluation steps to a leaf; an interleavable leaf (readFile, exec)
//! STARTS its effect natively and SUSPENDS (registers its fd/pid); other
//! evaluations keep stepping, so independent effects complete OUT OF ORDER.
//! write/writeFile and the env/cwd/getpid/glob leaves are SYNCHRONOUS (small,
//! bounded).  readLine is SYNCHRONOUS too: stdin is a single shared fd, so
//! interleaving its reads is meaningless (documented divergence).
//!
//! TERMINATION: the loop steps every runnable evaluation until each suspends
//! or delivers; when only effects remain it std.posix.poll(BLOCK)s on the
//! registered fds; on readiness it drains (nonblocking read) / reaps children
//! (waitpid WNOHANG — no zombies) and resumes.  It NEVER busy-spins and
//! delivers msgs in COMPLETION order (the feature).

const std = @import("std");
const gc = @import("gc");
const types = gc.types;
const state = @import("vm").state;
const values = @import("vm").values;
const interp = @import("vm").interp;
const prims = @import("vm").prims;
const symbols = @import("vm").symbols;
const execplan = @import("vm").execplan;
const hostcall = @import("vm").hostcall;

const Gc = gc.Gc;
const Value = types.Value;
const ValueArray = types.ValueArray;
const Vm = state.Vm;
const VmError = state.VmError;

const pa = std.heap.page_allocator;

// ---------------------------------------------------------------------
//  Bounds — fixed tables, no dynamic growth (the host owns every fd/pid).
// ---------------------------------------------------------------------

const MAX_EVALS = 128; // concurrent evaluations in flight (Cmd.batch bound)
const MAX_FRAMES = 256; // continuation-stack depth per evaluation (Task.sequence bound)
const BLOCK = MAX_FRAMES + 2; // task slot + result slot + frame slots
const MAX_SLOTS = 2 + MAX_EVALS * BLOCK; // +2: model (0) and update (1)
const MAX_POLLFDS = MAX_EVALS * 2 + 2; // readFile=1 fd, exec=2 pipe fds
const MAX_CHILDREN = MAX_EVALS; // one child per exec evaluation

// ---------------------------------------------------------------------
//  libc externs (the process/syscall layer — same discipline as execplan.zig)
// ---------------------------------------------------------------------

extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

const F_GETFL: c_int = 3; // Linux
const F_SETFL: c_int = 4; // Linux
const O_NONBLOCK: c_int = 0x800; // Linux O_NONBLOCK (0o4000)

// ---------------------------------------------------------------------
//  Effect state — page_allocator-backed (never GC-scanned, never rooted).
// ---------------------------------------------------------------------

const ReadFileEff = struct {
    fd: i32 = -1,
    buf: std.ArrayListUnmanaged(u8) = .empty, // accumulated bytes (page_allocator)
};

const ExecEff = struct {
    prog: execplan.RProg = .{}, // decoded plan — kept alive until the child is reaped
    pid: c_int = -1,
    outfd: i32 = -1, // read end of stdout pipe
    errfd: i32 = -1, // read end of stderr pipe
    outbuf: std.ArrayListUnmanaged(u8) = .empty,
    errbuf: std.ArrayListUnmanaged(u8) = .empty,
    out_eof: bool = false,
    err_eof: bool = false,
    child_exited: bool = false,
    exit_code: i32 = 0,
};

/// TaskReadKey accumulator — page_allocator (never GC-scanned, never rooted),
/// like ReadFileEff.  `esc_wait` marks a suspended eval whose buffer starts
/// with an incomplete ESC/CSI sequence (lone-ESC flush on poll timeout).
const ReadKeyEff = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    esc_wait: bool = false,
};

const Eff = union(enum) {
    none,
    readfile: ReadFileEff,
    exec: ExecEff,
    readkey: ReadKeyEff,
};

/// A decoded terminal key, before it is built into a host Key vector.
const KeyVal = union(enum) {
    char: []const u8, // UTF-8 byte sequence (borrows from the eff buffer)
    enter,
    tab,
    backspace,
    esc,
    up,
    down,
    left,
    right,
    home,
    end,
    pgup,
    pgdn,
    ins,
    del,
    ctrl: u8, // the single control character (0x01 -> 'a')
    other: i64, // KeyOther Int payload
    eof,
};

const DecodedKey = struct {
    consumed: usize, // bytes consumed from the front of the buffer
    key: KeyVal,
};

const FrameKind = enum { andthen, onerror };

const Frame = struct {
    kind: FrameKind,
    cont_slot: usize, // slot index holding the continuation/handler closure
};

const Eval = struct {
    active: bool = false,
    base: usize = 0, // block base slot index (task = base, result = base+1)
    /// Generation token: bumped every time this slot is (re)spawned.  stepEval
    /// captures it on entry and keeps looping only while it is unchanged — a
    /// deliver() deactivates the eval and spawn() can place a NEW eval into
    /// the just-freed slot (first-inactive reuse), which must NOT be stepped
    /// by the stale eval pointer still walking its while-loop.
    gen: usize = 0,
    nframes: usize = 0,
    frames: [MAX_FRAMES]Frame = [_]Frame{Frame{ .kind = .andthen, .cont_slot = 0 }} ** MAX_FRAMES,
    eff: Eff = .none,
};

const PollRole = enum { readfile, exec_out, exec_err, readkey };

const Child = struct {
    pid: c_int = -1,
    eval: usize = 0,
};

const HostLoop = struct {
    vm: *Vm,
    g: *Gc,
    /// R1: EVERY host-held Value (model, update, current tasks, continuation
    /// closures, effect results) lives in this permanently-rooted slot array.
    /// It is rooted ONCE for the whole run (rootPushValueArray) and every
    /// Value read must be (re)read FRESH after each allocating call.
    slots: [MAX_SLOTS]Value,
    nslots: i32 = MAX_SLOTS,
    evals: [MAX_EVALS]Eval = [_]Eval{Eval{}} ** MAX_EVALS,
    nevals: usize = 0,
    nactive: usize = 0,
    pollfds: [MAX_POLLFDS]std.posix.pollfd = [_]std.posix.pollfd{std.posix.pollfd{ .fd = -1, .events = 0, .revents = 0 }} ** MAX_POLLFDS,
    poll_eval: [MAX_POLLFDS]usize = [_]usize{0} ** MAX_POLLFDS,
    poll_role: [MAX_POLLFDS]PollRole = [_]PollRole{.readfile} ** MAX_POLLFDS,
    npoll: usize = 0,
    children: [MAX_CHILDREN]Child = [_]Child{Child{}} ** MAX_CHILDREN,
    nchildren: usize = 0,

    /// Terminal substrate (M1 tea): stdin EOF latch (never re-poll a dead fd),
    /// a one-shot O_NONBLOCK latch for fd0, the saved termios for the raw-mode
    /// restore (only set once raw-mode ON succeeds), and the leftover-bytes
    /// pushback (page_allocator, like ReadKeyEff.buf) so a multi-key read never
    /// drops keys after the first.
    stdin_eof: bool = false,
    stdin_nonblock: bool = false,
    saved_termios: ?std.posix.termios = null,
    stdin_pending: std.ArrayListUnmanaged(u8) = .empty,

    const model_slot = 0;
    const update_slot = 1;

    fn slotBase(i: usize) usize {
        return 2 + i * BLOCK;
    }
    fn resultSlot(eval: *Eval) usize {
        return eval.base + 1;
    }

    fn evalIndex(self: *HostLoop, eval: *Eval) usize {
        return (@intFromPtr(eval) - @intFromPtr(&self.evals[0])) / @sizeOf(Eval);
    }

    // -------------------------------------------------------------
    //  Spawning / deactivating evaluations
    // -------------------------------------------------------------

    fn spawn(self: *HostLoop, task: Value) void {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            if (!self.evals[i].active) break;
        }
        if (i == self.nevals) {
            if (i >= MAX_EVALS) std.debug.panic("effectloop: too many evaluations", .{});
            self.nevals += 1;
        }
        const base = slotBase(i);
        // Clear the whole block (the GC scans all MAX_SLOTS permanently, so a
        // stale ref here would retain dead closures/tasks).
        var j: usize = 0;
        while (j < BLOCK) : (j += 1) self.slots[base + j] = values.valNil();
        self.evals[i] = .{ .active = true, .base = base, .gen = self.evals[i].gen + 1 };
        self.slots[base] = task; // root the task (no alloc — plain store)
        self.nactive += 1;
    }

    /// Iterate a Cmd (a cons list of Tasks, nil-terminated) and spawn one
    /// evaluation per Task.  ALLOCATION-FREE: the tasks are copied from the
    /// (rooted) cons list into rooted slots with no GC alloc in between, so
    /// the list's interior pointers stay valid throughout.
    fn spawnFromCmd(self: *HostLoop, cmd: Value) void {
        var cur = cmd;
        while (cur.tag == .cons) {
            const task = cur.payload.cons.car.?.*;
            self.spawn(task);
            cur = cur.payload.cons.cdr.?.*;
        }
    }

    fn deactivate(self: *HostLoop, eval: *Eval) void {
        eval.active = false;
        self.nactive -= 1;
        var j: usize = 0;
        while (j < BLOCK) : (j += 1) self.slots[eval.base + j] = values.valNil();
        eval.nframes = 0;
        eval.eff = .none;
    }

    // -------------------------------------------------------------
    //  CEK stepping — TaskSucceed/Fail/AndThen/OnError compose purely;
    //  leaves start an effect (possibly suspending).
    // -------------------------------------------------------------

    fn stepEval(self: *HostLoop, eval: *Eval) VmError!void {
        // The loop re-reads eval fields each pass, so a deliver() that
        // deactivates this eval must stop the loop even when spawn() has
        // placed a fresh eval into the same slot (active becomes true again):
        // the generation token identifies the LOGICAL eval, not the slot.
        const start_gen = eval.gen;
        while (eval.active and eval.gen == start_gen and eval.eff == .none) {
            const task = self.slots[eval.base]; // fresh read (rooted slot)
            if (task.tag != .vector) {
                self.deactivate(eval);
                return;
            }
            const data = task.payload.vector.data;
            if (data == null or task.payload.vector.len < 1) {
                self.deactivate(eval);
                return;
            }
            const tag = data.?[0];
            if (tag.tag != .symbol) {
                self.deactivate(eval);
                return;
            }
            const name = values.symSlice(tag);

            // NICE-TO-HAVE 5: validate ctor arity before reading data[i]
            // (vector len == arity + 1).  Fixed arities today, so a mismatch
            // is a malformed Task — drop it instead of an OOB read.
            if (taskArity(name)) |a| {
                if (task.payload.vector.len != a + 1) {
                    self.deactivate(eval);
                    return;
                }
            }

            if (std.mem.eql(u8, name, "TaskSucceed")) {
                self.slots[resultSlot(eval)] = data.?[1];
                try self.completeSuccess(eval);
            } else if (std.mem.eql(u8, name, "TaskFail")) {
                self.slots[resultSlot(eval)] = data.?[1];
                try self.completeError(eval);
            } else if (std.mem.eql(u8, name, "TaskAndThen")) {
                self.pushFrame(eval, .andthen, data.?[1]);
                self.slots[eval.base] = data.?[2];
            } else if (std.mem.eql(u8, name, "TaskOnError")) {
                self.pushFrame(eval, .onerror, data.?[1]);
                self.slots[eval.base] = data.?[2];
            } else if (std.mem.eql(u8, name, "TaskWrite")) {
                try self.leafWrite(eval);
            } else if (std.mem.eql(u8, name, "TaskReadLine")) {
                try self.leafReadLine(eval);
            } else if (std.mem.eql(u8, name, "TaskReadFile")) {
                try self.leafReadFile(eval);
            } else if (std.mem.eql(u8, name, "TaskWriteFile")) {
                try self.leafWriteFile(eval);
            } else if (std.mem.eql(u8, name, "TaskExec")) {
                try self.leafExec(eval);
            } else if (std.mem.eql(u8, name, "TaskGetenv")) {
                try self.leafPrim(eval, "getenv", &.{data.?[1]});
            } else if (std.mem.eql(u8, name, "TaskSetenv")) {
                try self.leafPrim(eval, "setenv", &.{ data.?[1], data.?[2] });
            } else if (std.mem.eql(u8, name, "TaskCd")) {
                try self.leafPrim(eval, "cd", &.{data.?[1]});
            } else if (std.mem.eql(u8, name, "TaskGetcwd")) {
                try self.leafPrim(eval, "getcwd", &.{});
            } else if (std.mem.eql(u8, name, "TaskGetpid")) {
                try self.leafPrim(eval, "getpid", &.{});
            } else if (std.mem.eql(u8, name, "TaskGlob")) {
                try self.leafPrim(eval, "glob", &.{data.?[1]});
            } else if (std.mem.eql(u8, name, "TaskReadKey")) {
                try self.leafReadKey(eval);
            } else if (std.mem.eql(u8, name, "TaskWinSize")) {
                try self.leafWinSize(eval);
            } else if (std.mem.eql(u8, name, "TaskRawMode")) {
                try self.leafRawMode(eval, data.?[1]);
            } else {
                // Unknown Task ctor — drop the evaluation defensively.
                self.deactivate(eval);
                return;
            }
        }
    }

    fn pushFrame(self: *HostLoop, eval: *Eval, kind: FrameKind, cont: Value) void {
        if (eval.nframes >= MAX_FRAMES) std.debug.panic("effectloop: continuation stack overflow", .{});
        const slot = eval.base + 2 + eval.nframes;
        self.slots[slot] = cont;
        eval.frames[eval.nframes] = .{ .kind = kind, .cont_slot = slot };
        eval.nframes += 1;
    }

    /// Match M7 runTask EXACTLY (taskattempt proves fail/onError).
    /// success: no frame -> deliver; AndThen -> step (cont v); OnError -> pass
    /// through.  error: no frame -> drop; AndThen -> propagate; OnError ->
    /// step (handler e).
    fn completeSuccess(self: *HostLoop, eval: *Eval) VmError!void {
        while (true) {
            if (eval.nframes == 0) {
                try self.deliver(eval, self.slots[resultSlot(eval)]);
                return;
            }
            const frame = eval.frames[eval.nframes - 1];
            if (frame.kind == .onerror) {
                eval.nframes -= 1;
                self.slots[frame.cont_slot] = values.valNil();
                continue; // success passes through OnError
            }
            // .andthen
            eval.nframes -= 1;
            const cont = self.slots[frame.cont_slot];
            self.slots[frame.cont_slot] = values.valNil();
            const v = self.slots[resultSlot(eval)];
            const newtask = try hostcall.applyClosureN(self.vm, cont, &.{v});
            self.slots[eval.base] = newtask;
            return;
        }
    }

    fn completeError(self: *HostLoop, eval: *Eval) VmError!void {
        while (true) {
            if (eval.nframes == 0) {
                self.deactivate(eval); // drop the msg (M7 runOne Err -> drive rest)
                return;
            }
            const frame = eval.frames[eval.nframes - 1];
            if (frame.kind == .andthen) {
                eval.nframes -= 1;
                self.slots[frame.cont_slot] = values.valNil();
                continue; // error propagates through AndThen
            }
            // .onerror
            eval.nframes -= 1;
            const handler = self.slots[frame.cont_slot];
            self.slots[frame.cont_slot] = values.valNil();
            const e = self.slots[resultSlot(eval)];
            const newtask = try hostcall.applyClosureN(self.vm, handler, &.{e});
            self.slots[eval.base] = newtask;
            return;
        }
    }

    fn deliver(self: *HostLoop, eval: *Eval, msg: Value) VmError!void {
        const model = self.slots[model_slot]; // fresh
        const update = self.slots[update_slot]; // fresh
        // update msg model -> (model', cmd') = cons(model', cmd')
        const pair = try hostcall.applyClosureN(self.vm, update, &.{ msg, model });
        if (pair.tag != .cons) {
            self.deactivate(eval);
            return;
        }
        self.slots[model_slot] = pair.payload.cons.car.?.*;
        const cmd = pair.payload.cons.cdr.?.*;
        self.deactivate(eval);
        self.spawnFromCmd(cmd);
    }

    // -------------------------------------------------------------
    //  Native leaf effects
    // -------------------------------------------------------------

    /// TaskWrite s — write s to stdout (fd 1) synchronously.  Completes with
    /// unit (nil — the continuation ignores it).
    fn leafWrite(self: *HostLoop, eval: *Eval) VmError!void {
        const s = self.slots[eval.base].payload.vector.data.?[1];
        writeFdAll(1, values.strSlice(s));
        self.slots[resultSlot(eval)] = values.valNil();
        try self.completeSuccess(eval);
    }

    /// TaskWriteFile path contents — synchronous open+write+close.
    fn leafWriteFile(self: *HostLoop, eval: *Eval) VmError!void {
        const data = self.slots[eval.base].payload.vector.data.?;
        const path = data[1];
        const contents = data[2];
        const fd = std.posix.openat(
            std.posix.AT.FDCWD,
            values.strSlice(path),
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o666,
        ) catch {
            self.slots[resultSlot(eval)] = values.valNil();
            try self.completeSuccess(eval);
            return;
        };
        writeFdAll(fd, values.strSlice(contents));
        _ = close(fd);
        self.slots[resultSlot(eval)] = values.valNil();
        try self.completeSuccess(eval);
    }

    /// TaskReadLine — synchronous (stdin is a single shared fd; interleaving
    /// reads of fd 0 is meaningless).  Mirrors Runtime.elm readLineGo: read
    /// byte-by-byte, stop at 0x0A or EOF.
    fn leafReadLine(self: *HostLoop, eval: *Eval) VmError!void {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(pa);
        var b: [1]u8 = undefined;
        while (true) {
            const n = std.posix.read(0, &b) catch break;
            if (n == 0) break; // EOF
            if (b[0] == 0x0A) break;
            buf.appendSlice(pa, &b) catch break;
        }
        self.slots[resultSlot(eval)] = values.valString(self.g, buf.items);
        try self.completeSuccess(eval);
    }

    /// TaskReadFile path — open O_NONBLOCK, read available bytes into a
    /// page_allocator accumulator, poll for more, on EOF (read==0) valString
    /// the contents.  A regular file drains to EOF synchronously (so it can
    /// overtake a concurrently-suspended slow exec — the concurrency proof).
    fn leafReadFile(self: *HostLoop, eval: *Eval) VmError!void {
        const path = self.slots[eval.base].payload.vector.data.?[1];
        const fd = std.posix.openat(std.posix.AT.FDCWD, values.strSlice(path), .{ .NONBLOCK = true }, 0) catch {
            self.slots[resultSlot(eval)] = values.valString(self.g, ""); // M6 open-failure parity
            try self.completeSuccess(eval);
            return;
        };
        eval.eff = .{ .readfile = .{ .fd = fd } };
        if (try readFileDrain(eval)) {
            try self.readFileComplete(eval);
        }
        // else: suspended — the poll loop resumes via readFileDrain.
    }

    fn readFileDrain(eval: *Eval) VmError!bool {
        const eff = &eval.eff.readfile;
        var tmp: [65536]u8 = undefined;
        while (true) {
            const n = std.posix.read(eff.fd, &tmp) catch |e| {
                if (e == error.WouldBlock) return false; // EAGAIN — still pending
                return true; // read error — complete with what we have
            };
            if (n == 0) return true; // EOF
            eff.buf.appendSlice(pa, tmp[0..n]) catch return true;
        }
    }

    fn readFileComplete(self: *HostLoop, eval: *Eval) VmError!void {
        const eff = &eval.eff.readfile;
        _ = close(eff.fd);
        eff.fd = -1;
        const s = values.valString(self.g, eff.buf.items); // buf is page_allocator
        eff.buf.deinit(pa);
        eval.eff = .none;
        self.slots[resultSlot(eval)] = s;
        try self.completeSuccess(eval);
    }

    /// TaskExec plan — SINGLE-COMMAND async (fork+execvp, capture stdout/stderr
    /// via PIPE fds polled + waitpid WNOHANG).  Complex plans (pipeline/chain/
    /// redirect) fall back to SYNCHRONOUS execplan.primExecPlan (documented
    /// limitation — the concurrency proof needs one command).
    fn leafExec(self: *HostLoop, eval: *Eval) VmError!void {
        var plan = self.slots[eval.base].payload.vector.data.?[1];
        var plan_root = self.g.rootValue(&plan);
        defer plan_root.end();

        var prog: execplan.RProg = .{};
        if (!execplan.planDecode(plan, &prog)) {
            execplan.planFree(&prog);
            return self.vm.throwShen("exec-plan: malformed plan");
        }
        // Single plain command: one seq chain, one command, no redirs/sub.
        const argv = singleCommandArgv(&prog);
        if (argv == null) {
            // Complex plan — run synchronously via the existing prim.
            execplan.planFree(&prog);
            const r = try self.runPrim("exec-plan", &.{plan});
            self.slots[resultSlot(eval)] = r;
            try self.completeSuccess(eval);
            return;
        }

        // Fork + execvp the single command with piped capture.
        var outpipe: [2]c_int = undefined;
        var errpipe: [2]c_int = undefined;
        const ok_out = pipe(&outpipe) == 0;
        const ok_err = ok_out and pipe(&errpipe) == 0;
        if (!ok_err) {
            // A half-failed pipe() still owns the first pair — close it before
            // unwinding (the adjacent fork-fail path closes all four).
            if (ok_out) {
                _ = close(outpipe[0]);
                _ = close(outpipe[1]);
            }
            execplan.planFree(&prog);
            return self.vm.throwShen("exec-plan: fork/pipe failed");
        }
        const pid = fork();
        if (pid < 0) {
            _ = close(outpipe[0]);
            _ = close(outpipe[1]);
            _ = close(errpipe[0]);
            _ = close(errpipe[1]);
            execplan.planFree(&prog);
            return self.vm.throwShen("exec-plan: fork/pipe failed");
        }
        if (pid == 0) {
            execChild(argv.?, outpipe, errpipe);
        }
        // Parent: close write ends, keep read ends (nonblocking).
        _ = close(outpipe[1]);
        _ = close(errpipe[1]);
        setNonblocking(outpipe[0]);
        setNonblocking(errpipe[0]);

        const idx = self.evalIndex(eval);
        self.registerChild(idx, pid);
        eval.eff = .{ .exec = .{
            .prog = prog,
            .pid = pid,
            .outfd = outpipe[0],
            .errfd = errpipe[0],
        } };
    }

    fn execDrainOut(eval: *Eval) VmError!void {
        const eff = &eval.eff.exec;
        if (eff.outfd < 0) return;
        var tmp: [65536]u8 = undefined;
        while (true) {
            const n = std.posix.read(eff.outfd, &tmp) catch |e| {
                if (e == error.WouldBlock) return;
                break; // error -> treat as EOF
            };
            if (n == 0) break;
            eff.outbuf.appendSlice(pa, tmp[0..n]) catch break;
        }
        _ = close(eff.outfd);
        eff.outfd = -1;
        eff.out_eof = true;
    }

    fn execDrainErr(eval: *Eval) VmError!void {
        const eff = &eval.eff.exec;
        if (eff.errfd < 0) return;
        var tmp: [65536]u8 = undefined;
        while (true) {
            const n = std.posix.read(eff.errfd, &tmp) catch |e| {
                if (e == error.WouldBlock) return;
                break;
            };
            if (n == 0) break;
            eff.errbuf.appendSlice(pa, tmp[0..n]) catch break;
        }
        _ = close(eff.errfd);
        eff.errfd = -1;
        eff.err_eof = true;
    }

    /// Build the @p right-nested tuple (code, out, err) = cons(code,
    /// cons(out, err)) — exactly what Runtime.elm decodeExec would return.
    fn execComplete(self: *HostLoop, eval: *Eval) VmError!void {
        const eff = &eval.eff.exec;
        const code = eff.exit_code;
        var out_v = values.valString(self.g, eff.outbuf.items);
        self.g.rootPushValue(&out_v);
        defer self.g.rootPop();
        var err_v = values.valString(self.g, eff.errbuf.items);
        self.g.rootPushValue(&err_v);
        defer self.g.rootPop();
        var inner = values.valCons(self.g, out_v, err_v);
        self.g.rootPushValue(&inner);
        defer self.g.rootPop();
        const tuple = values.valCons(self.g, values.valNumber(code), inner);

        eff.outbuf.deinit(pa);
        eff.errbuf.deinit(pa);
        execplan.planFree(&eff.prog);
        eval.eff = .none;
        self.slots[resultSlot(eval)] = tuple;
        try self.completeSuccess(eval);
    }

    /// TaskGetenv/Setenv/Cd/Getcwd/Getpid/Glob — synchronous native prims via
    /// the existing execplan handlers (runPrim wraps a fresh ValueArray).
    fn leafPrim(self: *HostLoop, eval: *Eval, name: []const u8, args: []const Value) VmError!void {
        const r = try self.runPrim(name, args);
        self.slots[resultSlot(eval)] = r;
        try self.completeSuccess(eval);
    }

    /// Run a prim by name with args pushed RTL (a1 popped first).  Roots the
    /// arg array + the stack.data slot across vaInit/vaPush; the prims
    /// themselves root their popped values (M8 discipline).
    fn runPrim(self: *HostLoop, name: []const u8, args: []const Value) VmError!Value {
        const g = self.g;
        var argbuf: [8]Value = undefined;
        var nargs: i32 = 0;
        for (args) |a| {
            argbuf[@intCast(nargs)] = a;
            nargs += 1;
        }
        g.rootPushValueArray(&argbuf, &nargs);
        defer g.rootPop();
        var stack: ValueArray = .{ .data = null, .len = 0, .cap = 0 };
        g.rootPushPtr(@ptrCast(&stack.data));
        defer g.rootPop();
        interp.vaInit(g, &stack);
        defer interp.vaFree(&stack);
        var i: usize = @intCast(nargs);
        while (i > 0) {
            i -= 1;
            interp.vaPush(g, &stack, argbuf[i]);
        }
        var acc: Value = values.valNil();
        try prims.execPrimitive(self.vm, name, &acc, &stack);
        return acc;
    }

    // -------------------------------------------------------------
    //  Terminal leaves (M1 tea): TaskReadKey / TaskWinSize / TaskRawMode
    // -------------------------------------------------------------

    /// TaskReadKey — arm a nonblocking fd0 read and try to drain a key.  If
    /// stdin has already hit EOF, complete KeyEof immediately (a poll on an
    /// EOF'd fd busy-spins, so the latch short-circuits every re-arm).  The
    /// fresh accumulator is seeded with any pushback bytes left over from a
    /// multi-key read, so leftover keys decode before fd0 is polled again.
    fn leafReadKey(self: *HostLoop, eval: *Eval) VmError!void {
        if (self.stdin_eof) {
            self.slots[resultSlot(eval)] = self.buildKey(.eof);
            try self.completeSuccess(eval);
            return;
        }
        if (!self.stdin_nonblock) {
            setNonblocking(0);
            self.stdin_nonblock = true;
        }
        eval.eff = .{ .readkey = .{} };
        if (self.stdin_pending.items.len > 0) {
            eval.eff.readkey.buf.appendSlice(pa, self.stdin_pending.items) catch {};
            self.stdin_pending.clearRetainingCapacity();
        }
        _ = try self.readKeyDrain(eval); // completes or suspends
    }

    /// Decode a key from the readkey accumulator, reading more bytes off fd0
    /// as needed.  Returns true iff the evaluation COMPLETED (key built +
    /// delivered, or KeyEof on EOF); false iff it suspended (EAGAIN or an
    /// incomplete sequence — esc_wait is then set iff the buffer starts with
    /// 0x1B).  On a complete key, bytes past `consumed` are pushed to
    /// stdin_pending for the re-armed readKey — a multi-key read is never
    /// truncated to its first key.
    fn readKeyDrain(self: *HostLoop, eval: *Eval) VmError!bool {
        const eff = &eval.eff.readkey;
        var tmp: [256]u8 = undefined;
        while (true) {
            // Decode what is already buffered (seeded pushback included) first.
            if (eff.buf.items.len > 0) {
                if (decodeKey(eff.buf.items)) |d| {
                    if (d.consumed < eff.buf.items.len) {
                        self.stdin_pending.appendSlice(pa, eff.buf.items[d.consumed..]) catch {};
                    }
                    try self.readKeyComplete(eval, d.key);
                    return true;
                }
            }
            const n = std.posix.read(0, &tmp) catch |e| {
                if (e == error.WouldBlock) {
                    // No complete key and no more bytes — suspend (esc_wait iff
                    // an ESC/CSI is being assembled).
                    eff.esc_wait = eff.buf.items.len > 0 and eff.buf.items[0] == 0x1B;
                    return false;
                }
                // EIO / other read error — the pty master went away: EOF.
                self.stdin_eof = true;
                try self.readKeyComplete(eval, .eof);
                try self.flushEof();
                return true;
            };
            if (n == 0) {
                self.stdin_eof = true;
                try self.readKeyComplete(eval, .eof);
                try self.flushEof();
                return true;
            }
            eff.buf.appendSlice(pa, tmp[0..n]) catch return false;
            // loop back to decode the enlarged buffer
        }
    }

    /// stdin EOF just latched: every OTHER suspended readkey eval would be
    /// skipped by rebuildPollfds (the !stdin_eof guard) and never complete, so
    /// complete them all with KeyEof now (mirrors flushEscWaits).
    fn flushEof(self: *HostLoop) VmError!void {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active or eval.eff != .readkey) continue;
            try self.readKeyComplete(eval, .eof);
        }
    }

    /// Build the Key vector, free the accumulator, clear the effect, and
    /// deliver.  buildKey is the only GC allocation — the buffer free + plain
    /// stores after it never trigger GC, so the returned value stays valid
    /// until it lands in the permanently-rooted result slot (execComplete
    /// rooting discipline).
    fn readKeyComplete(self: *HostLoop, eval: *Eval, key: KeyVal) VmError!void {
        const keyv = self.buildKey(key);
        eval.eff.readkey.buf.deinit(pa);
        eval.eff = .none;
        self.slots[resultSlot(eval)] = keyv;
        try self.completeSuccess(eval);
    }

    /// TaskWinSize — SYNCHRONOUS ioctl TIOCGWINSZ (fd0, falling back to fd1,
    /// else 0x0), completing with the (cols, rows) tuple = cons(col, row).
    fn leafWinSize(self: *HostLoop, eval: *Eval) VmError!void {
        var ws: std.posix.winsize = undefined;
        var cols: i64 = 0;
        var rows: i64 = 0;
        if (ioctl(0, std.posix.T.IOCGWINSZ, &ws) == 0) {
            cols = ws.col;
            rows = ws.row;
        } else if (ioctl(1, std.posix.T.IOCGWINSZ, &ws) == 0) {
            cols = ws.col;
            rows = ws.row;
        }
        const tuple = values.valCons(self.g, values.valNumber(cols), values.valNumber(rows));
        self.slots[resultSlot(eval)] = tuple;
        try self.completeSuccess(eval);
    }

    /// TaskRawMode Bool — SYNCHRONOUS.  ON: save termios once, clear
    /// ECHO/ICANON/ISIG/IEXTEN (lflag), ICRNL/IXON (iflag), OPOST (oflag),
    /// VMIN=1 VTIME=0, tcsetattr NOW.  OFF: restore the saved termios DRAIN.
    /// Not-a-tty (or an off-target OFF) is a silent no-op completing unit.
    fn leafRawMode(self: *HostLoop, eval: *Eval, enable: Value) VmError!void {
        const on = enable.payload.boolean != 0;
        if (on) {
            if (self.saved_termios == null) {
                self.saved_termios = std.posix.tcgetattr(0) catch null;
            }
            if (self.saved_termios) |saved| {
                var raw = saved;
                raw.lflag.ECHO = false;
                raw.lflag.ICANON = false;
                raw.lflag.ISIG = false;
                raw.lflag.IEXTEN = false;
                raw.iflag.ICRNL = false;
                raw.iflag.IXON = false;
                raw.oflag.OPOST = false;
                raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
                raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
                _ = std.posix.tcsetattr(0, .NOW, raw) catch {};
            }
        } else {
            if (self.saved_termios) |saved| {
                _ = std.posix.tcsetattr(0, .DRAIN, saved) catch {};
                self.saved_termios = null;
            }
        }
        self.slots[resultSlot(eval)] = values.valNil();
        try self.completeSuccess(eval);
    }

    /// Build a host Key vector (bare ctor name + args in ctor order) rooted
    /// per execComplete: arg built + rooted first, then the vector, then plain
    /// stores (no GC alloc after the vector).  Tag compare is by name
    /// (primEq), so the bare ctor spelling is the only contract.
    fn buildKey(self: *HostLoop, key: KeyVal) Value {
        switch (key) {
            .char => |s| return self.buildKeyArg("KeyChar", values.valString(self.g, s)),
            .ctrl => |c| {
                var cb = [1]u8{c};
                return self.buildKeyArg("KeyCtrl", values.valString(self.g, &cb));
            },
            .other => |n| return self.buildKeyArg("KeyOther", values.valNumber(n)),
            .enter => return self.buildKey0("KeyEnter"),
            .tab => return self.buildKey0("KeyTab"),
            .backspace => return self.buildKey0("KeyBackspace"),
            .esc => return self.buildKey0("KeyEsc"),
            .up => return self.buildKey0("KeyUp"),
            .down => return self.buildKey0("KeyDown"),
            .left => return self.buildKey0("KeyLeft"),
            .right => return self.buildKey0("KeyRight"),
            .home => return self.buildKey0("KeyHome"),
            .end => return self.buildKey0("KeyEnd"),
            .pgup => return self.buildKey0("KeyPgUp"),
            .pgdn => return self.buildKey0("KeyPgDn"),
            .ins => return self.buildKey0("KeyIns"),
            .del => return self.buildKey0("KeyDel"),
            .eof => return self.buildKey0("KeyEof"),
        }
    }

    fn buildKeyArg(self: *HostLoop, name: []const u8, arg: Value) Value {
        var a = arg;
        self.g.rootPushValue(&a);
        defer self.g.rootPop();
        const v = values.valVector(self.g, 2);
        v.payload.vector.data.?[0] = symbols.valSymbol(&self.vm.symbols, name);
        v.payload.vector.data.?[1] = a;
        return v;
    }

    fn buildKey0(self: *HostLoop, name: []const u8) Value {
        const v = values.valVector(self.g, 1);
        v.payload.vector.data.?[0] = symbols.valSymbol(&self.vm.symbols, name);
        return v;
    }

    /// True iff any active readkey eval is in lone-ESC wait — drives the 50ms
    /// poll timeout instead of blocking forever on an unconfirmed ESC.
    fn anyEscWait(self: *HostLoop) bool {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (eval.active and eval.eff == .readkey and eval.eff.readkey.esc_wait) return true;
        }
        return false;
    }

    /// Poll timed out: every readkey eval waiting on a possible lone ESC is
    /// now confirmed ESC (no CSI bytes followed within the deadline) — flush
    /// them all to KeyEsc (bubbletea's deadline approach).
    fn flushEscWaits(self: *HostLoop) VmError!void {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active or eval.eff != .readkey) continue;
            if (eval.eff.readkey.esc_wait) {
                try self.readKeyComplete(eval, .esc);
            }
        }
    }

    // -------------------------------------------------------------
    //  Poll / reap / resume
    // -------------------------------------------------------------

    fn stepAll(self: *HostLoop) VmError!void {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (eval.active and eval.eff == .none) {
                try self.stepEval(eval);
            }
        }
    }

    /// True iff some evaluation is active with no pending effect — i.e. PURE
    /// work stepAll can run right now.
    fn hasRunnable(self: *HostLoop) bool {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            if (self.evals[i].active and self.evals[i].eff == .none) return true;
        }
        return false;
    }

    fn rebuildPollfds(self: *HostLoop) void {
        self.npoll = 0;
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active) continue;
            switch (eval.eff) {
                .none => {},
                .readfile => if (eval.eff.readfile.fd >= 0)
                    self.addPoll(i, eval.eff.readfile.fd, .readfile),
                .exec => {
                    if (eval.eff.exec.outfd >= 0) self.addPoll(i, eval.eff.exec.outfd, .exec_out);
                    if (eval.eff.exec.errfd >= 0) self.addPoll(i, eval.eff.exec.errfd, .exec_err);
                },
                .readkey => if (!self.stdin_eof) self.addPoll(i, 0, .readkey),
            }
        }
    }

    fn addPoll(self: *HostLoop, eval_idx: usize, fd: i32, role: PollRole) void {
        if (self.npoll >= MAX_POLLFDS) std.debug.panic("effectloop: too many pollfds", .{});
        self.pollfds[self.npoll] = .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 };
        self.poll_eval[self.npoll] = eval_idx;
        self.poll_role[self.npoll] = role;
        self.npoll += 1;
    }

    fn registerChild(self: *HostLoop, eval_idx: usize, pid: c_int) void {
        var i: usize = 0;
        while (i < self.nchildren) : (i += 1) {
            if (self.children[i].pid < 0) break;
        }
        if (i == self.nchildren) {
            if (i >= MAX_CHILDREN) std.debug.panic("effectloop: too many children", .{});
            self.nchildren += 1;
        }
        self.children[i] = .{ .pid = pid, .eval = eval_idx };
    }

    fn reapChildren(self: *HostLoop) void {
        for (self.children[0..self.nchildren]) |*c| {
            if (c.pid < 0) continue;
            var st: c_int = 0;
            const rc = waitpid(c.pid, &st, std.posix.W.NOHANG);
            if (rc == c.pid) {
                const eval = &self.evals[c.eval];
                if (eval.active and eval.eff == .exec) {
                    const status: u32 = @bitCast(st);
                    eval.eff.exec.child_exited = true;
                    eval.eff.exec.exit_code = execplan.waitStatusCode(status);
                }
                c.pid = -1;
            } else if (rc < 0) {
                c.pid = -1; // ECHILD/error — nothing more to reap
            }
        }
    }

    /// Block-reap the first pending child.  Returns true iff one was reaped.
    /// Used only when NO pollable fd remains: an exec's pipe fds EOF (waking
    /// poll) a moment BEFORE the exiting child becomes a waitpid-able zombie,
    /// so the WNOHANG reap above can race past it.  Once the fds are gone the
    /// child must have exited, so the blocking waitpid returns promptly and
    /// never busy-spins.
    fn reapBlocking(self: *HostLoop) bool {
        for (self.children[0..self.nchildren]) |*c| {
            if (c.pid < 0) continue;
            var st: c_int = 0;
            const rc = blk: {
                while (true) {
                    const r = waitpid(c.pid, &st, 0); // BLOCKING (0 options)
                    if (r < 0 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
                    break :blk r;
                }
            };
            if (rc == c.pid) {
                const eval = &self.evals[c.eval];
                if (eval.active and eval.eff == .exec) {
                    const status: u32 = @bitCast(st);
                    eval.eff.exec.child_exited = true;
                    eval.eff.exec.exit_code = execplan.waitStatusCode(status);
                }
                c.pid = -1;
                return true;
            }
            c.pid = -1; // ECHILD/error — nothing more to reap
        }
        return false;
    }

    fn drainReady(self: *HostLoop) VmError!void {
        const n = self.npoll;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.pollfds[i].revents == 0) continue;
            const eval = &self.evals[self.poll_eval[i]];
            if (!eval.active) continue;
            switch (self.poll_role[i]) {
                .readfile => {
                    if (try readFileDrain(eval)) {
                        try self.readFileComplete(eval);
                    }
                },
                .exec_out => try execDrainOut(eval),
                .exec_err => try execDrainErr(eval),
                .readkey => {
                    // May have been flushed by a poll timeout before this scan.
                    if (eval.eff != .readkey) continue;
                    _ = try self.readKeyDrain(eval);
                },
            }
        }
    }

    fn completeReady(self: *HostLoop) VmError!void {
        const n = self.nevals;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active or eval.eff != .exec) continue;
            const eff = &eval.eff.exec;
            if (eff.child_exited and eff.out_eof and eff.err_eof) {
                try self.execComplete(eval);
            }
        }
    }

    /// Close/free every pending effect (error-exit cleanup): no zombies, no
    /// leaked fds/buffers.  No GC allocation — safe to run under any root set.
    fn cleanupAll(self: *HostLoop) void {
        // Restore the saved termios on ANY exit path (raw mode must not leak
        // past an error).
        if (self.saved_termios) |saved| {
            _ = std.posix.tcsetattr(0, .DRAIN, saved) catch {};
            self.saved_termios = null;
        }
        self.stdin_pending.deinit(pa);
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            switch (eval.eff) {
                .none => {},
                .readfile => {
                    if (eval.eff.readfile.fd >= 0) _ = close(eval.eff.readfile.fd);
                    eval.eff.readfile.buf.deinit(pa);
                    eval.eff = .none;
                },
                .exec => {
                    if (eval.eff.exec.outfd >= 0) _ = close(eval.eff.exec.outfd);
                    if (eval.eff.exec.errfd >= 0) _ = close(eval.eff.exec.errfd);
                    eval.eff.exec.outbuf.deinit(pa);
                    eval.eff.exec.errbuf.deinit(pa);
                    execplan.planFree(&eval.eff.exec.prog);
                    eval.eff = .none;
                },
                .readkey => {
                    eval.eff.readkey.buf.deinit(pa);
                    eval.eff = .none;
                },
            }
        }
        for (self.children[0..self.nchildren]) |*c| {
            if (c.pid < 0) continue;
            _ = waitpid(c.pid, null, 0); // block-reap so no zombie survives
            c.pid = -1;
        }
    }
};

/// True iff `v` is the Program ADT vector (data[0] == bare symbol 'Program',
/// arity 3 -> vector len 4).
pub fn isProgram(v: Value) bool {
    if (v.tag != .vector) return false;
    if (v.payload.vector.len != 4) return false;
    const data = v.payload.vector.data;
    if (data == null) return false;
    const tag = data.?[0];
    if (tag.tag != .symbol) return false;
    return std.mem.eql(u8, values.symSlice(tag), "Program");
}

/// Drive the M9 event loop over a Program vector, returning the final model.
/// The caller must keep `prog` rooted for the duration (its data[1..3] are
/// extracted into the loop's own permanent slots before any allocation).
pub fn runProgram(vm: *Vm, prog: Value) VmError!Value {
    std.debug.assert(prog.tag == .vector);
    const data = prog.payload.vector.data.?;

    var loop = HostLoop{
        .vm = vm,
        .g = vm.gc,
        .slots = [_]Value{values.valNil()} ** MAX_SLOTS,
    };
    vm.gc.rootPushValueArray(&loop.slots, &loop.nslots);
    defer vm.gc.rootPop();
    defer loop.cleanupAll();

    loop.slots[HostLoop.model_slot] = data[1]; // model0
    loop.slots[HostLoop.update_slot] = data[3]; // updateFn
    loop.spawnFromCmd(data[2]); // cmd0

    while (loop.nactive > 0) {
        try loop.stepAll();
        if (loop.nactive == 0) break;
        loop.reapChildren();
        try loop.completeReady();
        if (loop.nactive == 0) break;
        // M9 fix: completeReady applies exec continuations and deliver() can
        // spawn into slots stepAll's cursor already passed, leaving PURE
        // evaluations runnable.  Step them to a fixpoint BEFORE touching the fd
        // tables — otherwise the npoll == 0 branch below breaks the loop and
        // silently drops their messages (fast execs, pure cmd spawns).
        while (loop.hasRunnable()) {
            try loop.stepAll();
            try loop.completeReady();
        }
        if (loop.nactive == 0) break;
        loop.rebuildPollfds();
        if (loop.npoll == 0) {
            // No pollable fd: the only remaining work is reaping children.
            // An exec's pipe fds EOF (waking poll) a moment BEFORE the exiting
            // child becomes reapable, so the WNOHANG reap can race past it and
            // leave the exec active with its fds already drained.  Block on
            // waitpid to reap the zombie (returns promptly — the fds being
            // gone means the child has exited), then let completeReady finish.
            if (loop.hasRunnable()) continue; // belt: never drop pure work
            if (loop.reapBlocking()) {
                try loop.completeReady();
                continue;
            }
            std.debug.print("effectloop: pending effect with no pollable fd\n", .{});
            break;
        }
        // A readkey eval in lone-ESC wait needs a bounded poll (50ms) so an
        // unconfirmed ESC flushes to KeyEsc; otherwise block until an fd is
        // ready.
        const poll_timeout: i32 = if (loop.anyEscWait()) 50 else -1;
        const poll_rc = std.posix.poll(loop.pollfds[0..loop.npoll], poll_timeout) catch |e| switch (e) {
            error.NetworkDown, error.SystemResources => return error.ShenError,
            error.Unexpected => 0, // spurious — flush esc_waits like a timeout
        };
        if (poll_rc == 0) {
            try loop.flushEscWaits();
        }
        loop.reapChildren();
        try loop.drainReady();
        try loop.completeReady();
    }

    return loop.slots[HostLoop.model_slot];
}

// ---------------------------------------------------------------------
//  Free functions (child side + fd helpers)
// ---------------------------------------------------------------------

/// The forked child for a single-command exec: bind the pipe write ends to
/// stdout/stderr, run a builtin in-process or execvp.  Never returns; only
/// write(2) + libc + _exit (no GC, no Zig error paths).
fn execChild(argv: [:null]const ?[*:0]const u8, outpipe: [2]c_int, errpipe: [2]c_int) noreturn {
    _ = close(outpipe[0]);
    _ = close(errpipe[0]);
    _ = dup2(outpipe[1], 1);
    _ = dup2(errpipe[1], 2);
    if (outpipe[1] > 2) _ = close(outpipe[1]);
    if (errpipe[1] > 2 and errpipe[1] != outpipe[1]) _ = close(errpipe[1]);

    const bcode = execplan.childBuiltin(argv.len, argv);
    if (bcode >= 0) _exit(bcode);
    _ = execvp(argv[0].?, argv.ptr);
    if (std.c._errno().* == @intFromEnum(std.c.E.NOENT)) {
        childW2("shensh: ", std.mem.sliceTo(argv[0].?, 0), ": not found\n");
        _exit(127);
    }
    childW2("shensh: ", std.mem.sliceTo(argv[0].?, 0), ": cannot execute\n");
    _exit(126);
}

/// Child-side stderr note (write(2) only).
fn childW2(a: []const u8, b: []const u8, c: []const u8) void {
    _ = write(2, a.ptr, a.len);
    _ = write(2, b.ptr, b.len);
    _ = write(2, c.ptr, c.len);
}

/// Return the argv of `prog` iff it is a SINGLE PLAIN COMMAND (one seq chain,
/// one command, no redirects, no subshell); else null (caller falls back to
/// sync).  The returned slice borrows from `prog` and stays valid until
/// planFree — the exec effect keeps `prog` alive across the fork+waitpid.
fn singleCommandArgv(prog: *execplan.RProg) ?[:null]const ?[*:0]const u8 {
    if (prog.chains.len != 1) return null;
    const ch = &prog.chains[0];
    if (ch.op != .seq) return null;
    if (ch.pipe.cmds.len != 1) return null;
    const c = &ch.pipe.cmds[0];
    if (c.sub != null or c.redirs.len != 0) return null;
    if (c.argv.len == 0) return null;
    return c.argv;
}

/// Task ctor arity (vector len == arity + 1), or null for an unknown ctor.
fn taskArity(name: []const u8) ?i32 {
    if (std.mem.eql(u8, name, "TaskSucceed") or std.mem.eql(u8, name, "TaskFail") or
        std.mem.eql(u8, name, "TaskWrite") or std.mem.eql(u8, name, "TaskReadFile") or
        std.mem.eql(u8, name, "TaskExec") or std.mem.eql(u8, name, "TaskGetenv") or
        std.mem.eql(u8, name, "TaskCd") or std.mem.eql(u8, name, "TaskGlob") or
        std.mem.eql(u8, name, "TaskRawMode")) return 1;
    if (std.mem.eql(u8, name, "TaskAndThen") or std.mem.eql(u8, name, "TaskOnError") or
        std.mem.eql(u8, name, "TaskWriteFile") or std.mem.eql(u8, name, "TaskSetenv")) return 2;
    if (std.mem.eql(u8, name, "TaskReadLine") or std.mem.eql(u8, name, "TaskGetcwd") or
        std.mem.eql(u8, name, "TaskGetpid") or std.mem.eql(u8, name, "TaskReadKey") or
        std.mem.eql(u8, name, "TaskWinSize")) return 0;
    return null;
}

/// Set O_NONBLOCK on an fd (GETFL|SETFL — preserves any existing flags).
fn setNonblocking(fd: c_int) void {
    const fl = fcntl(fd, F_GETFL, @as(c_int, 0));
    if (fl < 0) return;
    _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/// Write all of `data` to `fd` (loops over partial writes; retries EINTR).
fn writeFdAll(fd: i32, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data[off..].ptr, data[off..].len);
        if (n < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return; // real error — stop (best-effort write)
        }
        if (n == 0) return;
        off += @intCast(n);
    }
}

// ---------------------------------------------------------------------
//  Terminal key decode (M1 tea) — the state machine behind TaskReadKey.
//  Returns null when the buffer is an INCOMPLETE prefix (caller suspends;
//  esc_wait is set iff the prefix is ESC/CSI).  Single-byte controls and
//  UTF-8 are decoded directly; ESC introduces CSI/SS3 sequences.
// ---------------------------------------------------------------------

fn decodeKey(buf: []const u8) ?DecodedKey {
    if (buf.len == 0) return null;
    const b0 = buf[0];
    // Ctrl keys: 0x01..0x1A EXCEPT the specials the switch maps (tab/enter/
    // backspace) — Zig switch ranges must not overlap, so this runs first.
    if (b0 >= 0x01 and b0 <= 0x1A and b0 != 0x08 and b0 != 0x09 and b0 != 0x0A and b0 != 0x0D) {
        return .{ .consumed = 1, .key = .{ .ctrl = @intCast(b0 - 0x01 + 'a') } };
    }
    switch (b0) {
        0x0D, 0x0A => return .{ .consumed = 1, .key = .enter },
        0x09 => return .{ .consumed = 1, .key = .tab },
        0x7F, 0x08 => return .{ .consumed = 1, .key = .backspace },
        0x00, 0x1C...0x1F => return .{ .consumed = 1, .key = .{ .other = b0 } },
        0x80...0xBF => return .{ .consumed = 1, .key = .{ .other = b0 } }, // stray continuation
        0x1B => return decodeEsc(buf),
        0xC0...0xF4 => return decodeUtf8(buf),
        0x20...0x7E => return .{ .consumed = 1, .key = .{ .char = buf[0..1] } }, // plain ASCII
        else => return .{ .consumed = 1, .key = .{ .other = b0 } }, // 0xF5..0xFF etc.
    }
}

/// ESC: CSI (`[`) / SS3 (`O`) with params then a final byte; a lone ESC or an
/// unparsed prefix is incomplete (null).  ESC followed by a NON-sequence byte
/// is a bare KeyEsc consuming ONLY the ESC — the following byte stays in the
/// read-key accumulator (stdin_pending pushback) and the re-armed readKey
/// decodes it as its own key.
fn decodeEsc(buf: []const u8) ?DecodedKey {
    if (buf.len < 2) return null; // lone ESC — incomplete
    const b1 = buf[1];
    if (b1 == 'O' or b1 == '[') {
        var i: usize = 2;
        while (i < buf.len) : (i += 1) {
            const c = buf[i];
            if (c >= 0x40 and c <= 0x7E) return mapCsiFinal(buf[2..i], c, i + 1);
            if (c < 0x30 or c > 0x3F) return null; // not a param/intermediate — incomplete
        }
        return null; // ran out before a final byte
    }
    return .{ .consumed = 1, .key = .esc };
}

/// UTF-8 lead (0xC0..0xF4): decode iff all continuation bytes are present.
/// Missing continuations -> incomplete (null); a non-continuation byte -> the
/// lead is treated as a stray KeyOther byte.
fn decodeUtf8(buf: []const u8) ?DecodedKey {
    const b0 = buf[0];
    const need: usize = if (b0 < 0xE0) 1 else if (b0 < 0xF0) 2 else 3;
    if (buf.len < 1 + need) return null;
    var i: usize = 1;
    while (i <= need) : (i += 1) {
        if (buf[i] & 0xC0 != 0x80) return .{ .consumed = 1, .key = .{ .other = b0 } };
    }
    return .{ .consumed = 1 + need, .key = .{ .char = buf[0 .. 1 + need] } };
}

/// Map a CSI/SS3 final byte (with the param bytes preceding it) to a key.
/// A/B/C/D -> arrows, H/F -> home/end, `~` -> by LAST param digit
/// (1..6 = Home/Ins/Del/End/PgUp/PgDn; params stripped, modifiers ignored).
fn mapCsiFinal(params: []const u8, final: u8, consumed: usize) ?DecodedKey {
    switch (final) {
        'A' => return .{ .consumed = consumed, .key = .up },
        'B' => return .{ .consumed = consumed, .key = .down },
        'C' => return .{ .consumed = consumed, .key = .right },
        'D' => return .{ .consumed = consumed, .key = .left },
        'H' => return .{ .consumed = consumed, .key = .home },
        'F' => return .{ .consumed = consumed, .key = .end },
        '~' => {
            var last: u8 = 1;
            for (params) |p| {
                if (p >= '0' and p <= '9') last = p - '0';
            }
            const key: KeyVal = switch (last) {
                1 => .home,
                2 => .ins,
                3 => .del,
                4 => .end,
                5 => .pgup,
                6 => .pgdn,
                else => .{ .other = last },
            };
            return .{ .consumed = consumed, .key = key };
        },
        else => return .{ .consumed = consumed, .key = .{ .other = final } },
    }
}
