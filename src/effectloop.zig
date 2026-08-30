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

/// SGR mouse-tracking DECRST (the exact set leafMouseMode Off emits) — reused
/// by cleanupAll so a real terminal does not keep 1000/1002/1003/1006 tracking
/// armed after quit or error.
const MOUSE_OFF_SEQ = "\x1b[?1006l\x1b[?1003l\x1b[?1002l\x1b[?1000l";

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
/// glibc fstatat (std.c leaves it void on linux — 0.16 prefers statx; the
/// plain call matches the file's other libc externs and Go os.Stat semantics).
extern "c" fn fstatat(dirfd: c_int, path: [*:0]const u8, buf: *Stat, flag: c_uint) c_int;

/// glibc `struct stat` on x86_64-linux (std.c.Stat is void there) — only the
/// fields the stat leaves read are named; layout must match bits/stat.h.
const Stat = extern struct {
    dev: u64,
    ino: u64,
    nlink: u64,
    mode: u32,
    uid: u32,
    gid: u32,
    pad0: c_int,
    rdev: u64,
    size: i64,
    blksize: i64,
    blocks: i64,
    atim: std.os.linux.timespec,
    mtim: std.os.linux.timespec,
    ctim: std.os.linux.timespec,
    reserved: [3]c_long,
};

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

/// TaskReadMouse accumulator — identical shape to ReadKeyEff: SGR mouse events
/// and a lone-ESC wait both ride the SAME shared fd0.
const ReadMouseEff = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    esc_wait: bool = false,
};

/// TaskSleep suspends until `deadline_ms` (CLOCK_MONOTONIC).  No fd and no
/// buffer: the poll loop bounds its timeout by the nearest deadline and
/// flushExpiredSleeps completes expired sleeps after every poll return.
const SleepEff = struct {
    deadline_ms: i64 = 0,
};

const Eff = union(enum) {
    none,
    readfile: ReadFileEff,
    exec: ExecEff,
    readkey: ReadKeyEff,
    readmouse: ReadMouseEff,
    sleep: SleepEff,
    winch, // SIGWINCH wait — no per-eval fd (all share HostLoop.winch_fd)
};

/// A decoded terminal key, before it is built into a host Key vector.  The
/// queued form is OWNED: `char` used to borrow the eff buffer (which is
/// deinit'd on completion), so the shared queue stores the bytes by value.
const KeyKind = enum(u8) {
    char,
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
    ctrl,
    other,
    eof,
};

const EventKey = struct {
    kind: KeyKind = .other,
    char: [4]u8 = undefined, // UTF-8 bytes for .char (at most 4)
    char_len: usize = 0,
    num: i64 = 0, // .ctrl single char or .other Int payload
};

/// SGR mouse action/button enums (the Runtime.elm MouseMsg ADT contract).
const MouseAction = enum(u8) { press, release, motion, wheel };
const MouseButton = enum(u8) { left, middle, right, none, wheel_up, wheel_down, wheel_left, wheel_right };

const EventMouse = struct {
    eof: bool = false,
    action: MouseAction = .press,
    button: MouseButton = .none,
    x: i64 = 0,
    y: i64 = 0,
};

const InputEvent = union(enum) {
    key: EventKey,
    mouse: EventMouse,
};

const DecodedInput = struct {
    consumed: usize, // bytes consumed from the front of the buffer
    event: InputEvent,
};

fn evKey(kind: KeyKind) InputEvent {
    return .{ .key = .{ .kind = kind } };
}

fn evMouseEof() InputEvent {
    return .{ .mouse = .{ .eof = true } };
}

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

const PollRole = enum { readfile, exec_out, exec_err, readkey, winch };

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
    /// SGR mouse-tracking latch (set by leafMouseMode): true while the terminal
    /// has 1000/1002/1003/1006 tracking armed, so cleanupAll can emit the
    /// DECRST mouse-off reset before restoring termios (a real terminal
    /// otherwise keeps tracking on after quit/error and spews SGR packets).
    mouse_armed: bool = false,
    /// Shared decoded-event queue (readKey AND readMouse both armed over fd0).
    /// OWNED bytes — a queued KeyChar/EventKey carries its UTF-8 bytes by
    /// value, never a borrow into an eff buffer that gets deinit'd.  A drain
    /// parks non-matching kinds here; leafReadKey/leafReadMouse pop a matching
    /// event first (typeahead) before touching fd0.
    pending_events: std.ArrayListUnmanaged(InputEvent) = .empty,
    /// Quit latch: TaskQuit sets it; the main loop breaks once the current
    /// stepAll/completeReady round finishes (even with suspended evals still
    /// armed — unlike nactive==0, which a re-armed readKey/mouse/resize eval
    /// would block forever).
    quit: bool = false,
    /// The signalfd for SIGWINCH (lazy one-time init in leafWaitResize).  -1
    /// until the first TaskWaitResize runs.  One shared fd for every armed
    /// winch eval — on readiness drainWinch completes ALL of them with a fresh
    /// TIOCGWINSZ read.
    winch_fd: i32 = -1,

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
            } else if (std.mem.eql(u8, name, "TaskReadMouse")) {
                try self.leafReadMouse(eval);
            } else if (std.mem.eql(u8, name, "TaskMouseMode")) {
                try self.leafMouseMode(eval, data.?[1]);
            } else if (std.mem.eql(u8, name, "TaskWinSize")) {
                try self.leafWinSize(eval);
            } else if (std.mem.eql(u8, name, "TaskWaitResize")) {
                try self.leafWaitResize(eval);
            } else if (std.mem.eql(u8, name, "TaskRawMode")) {
                try self.leafRawMode(eval, data.?[1]);
            } else if (std.mem.eql(u8, name, "TaskNow")) {
                try self.leafNow(eval);
            } else if (std.mem.eql(u8, name, "TaskSleep")) {
                try self.leafSleep(eval, data.?[1]);
            } else if (std.mem.eql(u8, name, "TaskQuit")) {
                try self.leafQuit(eval);
            } else if (std.mem.eql(u8, name, "TaskListDir")) {
                try self.leafListDir(eval);
            } else if (std.mem.eql(u8, name, "TaskStat")) {
                try self.leafStat(eval);
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
    //  Terminal leaves (M1 tea + S4 mouse): TaskReadKey / TaskReadMouse /
    //  TaskMouseMode / TaskWinSize / TaskRawMode
    // -------------------------------------------------------------

    /// TaskReadKey — arm a nonblocking fd0 read and try to drain a key.  If
    /// stdin has already hit EOF, complete KeyEof immediately (a poll on an
    /// EOF'd fd busy-spins, so the latch short-circuits every re-arm).  A
    /// queued key (decoded by an earlier drain) is popped first — typeahead.
    /// Otherwise the fresh accumulator is seeded with any pushback bytes left
    /// over from a multi-event read, so leftovers decode before fd0 is polled.
    fn leafReadKey(self: *HostLoop, eval: *Eval) VmError!void {
        if (self.stdin_eof) {
            self.slots[resultSlot(eval)] = self.buildKey(evKey(.eof));
            try self.completeSuccess(eval);
            return;
        }
        if (self.popPending(false)) |event| {
            self.slots[resultSlot(eval)] = self.buildKey(event);
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
        _ = try self.inputDrain(eval, false); // completes or suspends
    }

    /// TaskReadMouse — the mouse analogue of leafReadKey over the SAME fd0.
    /// EOF -> MouseEof; queued mouse event -> pop first; else arm + seed the
    /// pushback + drain.
    fn leafReadMouse(self: *HostLoop, eval: *Eval) VmError!void {
        if (self.stdin_eof) {
            self.slots[resultSlot(eval)] = self.buildMouse(evMouseEof());
            try self.completeSuccess(eval);
            return;
        }
        if (self.popPending(true)) |event| {
            self.slots[resultSlot(eval)] = self.buildMouse(event);
            try self.completeSuccess(eval);
            return;
        }
        if (!self.stdin_nonblock) {
            setNonblocking(0);
            self.stdin_nonblock = true;
        }
        eval.eff = .{ .readmouse = .{} };
        if (self.stdin_pending.items.len > 0) {
            eval.eff.readmouse.buf.appendSlice(pa, self.stdin_pending.items) catch {};
            self.stdin_pending.clearRetainingCapacity();
        }
        _ = try self.inputDrain(eval, true); // completes or suspends
    }

    /// TaskMouseMode mode — SYNCHRONOUS.  Writes the SGR mouse-tracking
    /// DECSET/DECRST to fd1 (the pty): Click=1006+1000, Drag=1006+1002,
    /// AllMotion=1006+1003, Off=reset all.  `mode` is a 0-ary ctor vector
    /// whose tag symbol names the mode.
    fn leafMouseMode(self: *HostLoop, eval: *Eval, mode: Value) VmError!void {
        var name: []const u8 = "";
        if (mode.tag == .vector and mode.payload.vector.data != null and mode.payload.vector.len >= 1) {
            const tag = mode.payload.vector.data.?[0];
            if (tag.tag == .symbol) name = values.symSlice(tag);
        }
        const seq: []const u8 = if (std.mem.eql(u8, name, "Click"))
            "\x1b[?1006h\x1b[?1000h"
        else if (std.mem.eql(u8, name, "Drag"))
            "\x1b[?1006h\x1b[?1002h"
        else if (std.mem.eql(u8, name, "AllMotion"))
            "\x1b[?1006h\x1b[?1003h"
        else
            MOUSE_OFF_SEQ; // Off / unknown — reset all
        self.mouse_armed = !std.mem.eql(u8, seq, MOUSE_OFF_SEQ);
        writeFdAll(1, seq);
        self.slots[resultSlot(eval)] = values.valNil();
        try self.completeSuccess(eval);
    }

    /// Decode events from the readkey/readmouse accumulator (want_mouse picks
    /// the kind THIS eval is armed for), reading more bytes off fd0 as needed.
    /// Events are decoded IN ORDER; a non-matching event is handed to a sibling
    /// eval of the right kind (parked in pending_events if none is armed) and
    /// draining continues; the first matching event completes THIS eval with
    /// bytes past `consumed` pushed to stdin_pending.  Returns true iff this
    /// eval COMPLETED; false iff it suspended (EAGAIN or an incomplete
    /// sequence — esc_wait is then set iff the buffer starts with 0x1B).
    fn inputDrain(self: *HostLoop, eval: *Eval, comptime want_mouse: bool) VmError!bool {
        const eff = if (want_mouse) &eval.eff.readmouse else &eval.eff.readkey;
        var tmp: [256]u8 = undefined;
        while (true) {
            // Decode what is already buffered (seeded pushback included) first.
            if (eff.buf.items.len > 0) {
                if (decodeInput(eff.buf.items)) |d| {
                    const is_mouse = switch (d.event) {
                        .mouse => true,
                        .key => false,
                    };
                    if (is_mouse == want_mouse) {
                        if (d.consumed < eff.buf.items.len) {
                            self.stdin_pending.appendSlice(pa, eff.buf.items[d.consumed..]) catch {};
                        }
                        try self.inputComplete(eval, d.event);
                        return true;
                    }
                    // Non-matching kind: drop the consumed bytes from the front
                    // of the buffer, route the event to a matching sibling eval
                    // (or park it), and keep draining.
                    const rest = eff.buf.items[d.consumed..];
                    std.mem.copyForwards(u8, eff.buf.items[0..rest.len], rest);
                    eff.buf.items.len = rest.len;
                    try self.deliverInputEvent(d.event);
                    continue;
                }
            }
            const n = std.posix.read(0, &tmp) catch |e| {
                if (e == error.WouldBlock) {
                    // No complete event and no more bytes — suspend (esc_wait
                    // iff an ESC/CSI is being assembled).
                    eff.esc_wait = eff.buf.items.len > 0 and eff.buf.items[0] == 0x1B;
                    return false;
                }
                // EIO / other read error — the pty master went away: EOF.
                self.stdin_eof = true;
                try self.inputComplete(eval, if (want_mouse) evMouseEof() else evKey(.eof));
                try self.flushEof();
                return true;
            };
            if (n == 0) {
                self.stdin_eof = true;
                try self.inputComplete(eval, if (want_mouse) evMouseEof() else evKey(.eof));
                try self.flushEof();
                return true;
            }
            eff.buf.appendSlice(pa, tmp[0..n]) catch return false;
            // loop back to decode the enlarged buffer
        }
    }

    /// Hand a decoded event to the first ARMED eval of the matching kind
    /// (readkey for a key, readmouse for a mouse); park it in pending_events if
    /// none is armed.  The queue stores OWNED bytes, so the event is safe
    /// after any eff buffer deinit.
    fn deliverInputEvent(self: *HostLoop, event: InputEvent) VmError!void {
        const is_mouse = switch (event) {
            .mouse => true,
            .key => false,
        };
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active) continue;
            if (is_mouse) {
                if (eval.eff == .readmouse) {
                    try self.inputComplete(eval, event);
                    return;
                }
            } else if (eval.eff == .readkey) {
                try self.inputComplete(eval, event);
                return;
            }
        }
        self.pending_events.append(pa, event) catch {};
    }

    /// Pop the first queued event of the given kind (typeahead), in order.
    fn popPending(self: *HostLoop, want_mouse: bool) ?InputEvent {
        var i: usize = 0;
        while (i < self.pending_events.items.len) : (i += 1) {
            const ev = self.pending_events.items[i];
            const is_mouse = switch (ev) {
                .mouse => true,
                .key => false,
            };
            if (is_mouse == want_mouse) {
                _ = self.pending_events.orderedRemove(i);
                return ev;
            }
        }
        return null;
    }

    /// stdin EOF just latched: every OTHER suspended readkey/readmouse eval
    /// would be skipped by rebuildPollfds (the !stdin_eof guard) and never
    /// complete, so complete them all now — readkey -> KeyEof, readmouse ->
    /// MouseEof (mirrors flushEscWaits).
    fn flushEof(self: *HostLoop) VmError!void {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active) continue;
            if (eval.eff == .readkey) {
                try self.inputComplete(eval, evKey(.eof));
            } else if (eval.eff == .readmouse) {
                try self.inputComplete(eval, evMouseEof());
            }
        }
    }

    /// Feed parked stdin_pending bytes into an ALREADY-ARMED stdin eval whose
    /// accumulator is empty, and decode them directly (inputDrain decodes the
    /// seeded buffer first, before polling fd0).  Without this, leftover raw
    /// bytes parked by a sibling drain are invisible to an armed empty-buf
    /// eval: it polls fd0, which will not re-fire for already-consumed bytes,
    /// so the parked (older) bytes get bypassed by newer input or the reader
    /// hangs with bytes available.  Each inputDrain call consumes >= 1 byte or
    /// parks a strictly shorter tail, so the loop makes progress and cannot
    /// livelock; a partial sequence that still needs more bytes suspends in the
    /// eval's own buffer (esc_wait) and the pending queue is then empty.
    fn drainPendingStdin(self: *HostLoop) VmError!void {
        while (self.stdin_pending.items.len > 0) {
            var target: ?*Eval = null;
            var i: usize = 0;
            while (i < self.nevals) : (i += 1) {
                const eval = &self.evals[i];
                if (!eval.active) continue;
                if (eval.eff == .readkey and eval.eff.readkey.buf.items.len == 0) {
                    target = eval;
                    break;
                }
                if (eval.eff == .readmouse and eval.eff.readmouse.buf.items.len == 0) {
                    target = eval;
                    break;
                }
            }
            const eval = target orelse return; // no armed empty-buf stdin eval
            if (eval.eff == .readkey) {
                eval.eff.readkey.buf.appendSlice(pa, self.stdin_pending.items) catch return;
                self.stdin_pending.clearRetainingCapacity();
                _ = try self.inputDrain(eval, false);
            } else {
                eval.eff.readmouse.buf.appendSlice(pa, self.stdin_pending.items) catch return;
                self.stdin_pending.clearRetainingCapacity();
                _ = try self.inputDrain(eval, true);
            }
        }
    }

    /// Build the Key/MouseMsg value, free the accumulator, clear the effect,
    /// and deliver.  buildKey/buildMouse are the only GC allocations — the
    /// buffer free + plain stores after them never trigger GC, so the returned
    /// value stays valid until it lands in the permanently-rooted result slot
    /// (execComplete rooting discipline).
    fn inputComplete(self: *HostLoop, eval: *Eval, event: InputEvent) VmError!void {
        const is_mouse = eval.eff == .readmouse;
        const v = if (is_mouse) self.buildMouse(event) else self.buildKey(event);
        if (is_mouse) {
            eval.eff.readmouse.buf.deinit(pa);
        } else {
            eval.eff.readkey.buf.deinit(pa);
        }
        eval.eff = .none;
        self.slots[resultSlot(eval)] = v;
        try self.completeSuccess(eval);
    }

    /// TaskWinSize — SYNCHRONOUS ioctl TIOCGWINSZ, completing with the
    /// (cols, rows) tuple = cons(col, row).
    fn leafWinSize(self: *HostLoop, eval: *Eval) VmError!void {
        const sz = readWinSize();
        const tuple = values.valCons(self.g, values.valNumber(sz.cols), values.valNumber(sz.rows));
        self.slots[resultSlot(eval)] = tuple;
        try self.completeSuccess(eval);
    }

    /// TaskWaitResize — SUSPENDING signalfd wait.  Lazy one-time init: block
    /// SIGWINCH (so the signal queues into the signalfd instead of firing the
    /// default disposition) and create a shared SFD_CLOEXEC signalfd.  Every
    /// armed winch eval shares that one fd; drainWinch completes them all with
    /// a fresh TIOCGWINSZ read.  A signalfd failure falls back to the
    /// synchronous winSize probe so the app still gets a size (no hang).
    fn leafWaitResize(self: *HostLoop, eval: *Eval) VmError!void {
        if (self.winch_fd < 0) {
            var mask = sigwinchMask();
            // BLOCK before signalfd: a resize between the two syscalls is
            // queued as pending once blocked, then reported by the signalfd.
            std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, null);
            const fd = std.posix.signalfd(-1, &mask, std.os.linux.SFD.CLOEXEC) catch -1;
            if (fd < 0) {
                // Restore the default disposition on failure, then fall back.
                std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &mask, null);
            }
            self.winch_fd = fd;
        }
        if (self.winch_fd < 0) {
            const sz = readWinSize();
            const tuple = values.valCons(self.g, values.valNumber(sz.cols), values.valNumber(sz.rows));
            self.slots[resultSlot(eval)] = tuple;
            try self.completeSuccess(eval);
            return;
        }
        eval.eff = .winch;
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

    // -------------------------------------------------------------
    //  Time + quit leaves (M-FOUNDATION): TaskNow / TaskSleep / TaskQuit
    // -------------------------------------------------------------

    /// TaskNow — SYNCHRONOUS monotonic clock read (CLOCK_MONOTONIC).  The VM's
    /// get-time prim is CLOCK_REALTIME (wall clock — jumps break timers), so
    /// the host reads the monotonic clock directly and completes with ms.
    fn leafNow(self: *HostLoop, eval: *Eval) VmError!void {
        self.slots[resultSlot(eval)] = values.valNumber(nowMs());
        try self.completeSuccess(eval);
    }

    /// TaskSleep ms — SUSPENDING: record an absolute monotonic deadline.  The
    /// poll timeout is bounded by the nearest deadline (see pollTimeout) and
    /// flushExpiredSleeps completes expired sleeps after every poll return.
    fn leafSleep(self: *HostLoop, eval: *Eval, ms: Value) VmError!void {
        _ = self;
        const dur = ms.payload.number;
        eval.eff = .{ .sleep = .{ .deadline_ms = nowMs() + dur } };
    }

    fn sleepComplete(self: *HostLoop, eval: *Eval) VmError!void {
        eval.eff = .none;
        self.slots[resultSlot(eval)] = values.valNil();
        try self.completeSuccess(eval);
    }

    /// TaskQuit — set the quit latch; the main loop breaks after the current
    /// step.  The evaluation is deactivated (no deliver): quitting means exit
    /// with the model as-is, not a normal message round-trip.
    fn leafQuit(self: *HostLoop, eval: *Eval) VmError!void {
        self.quit = true;
        self.deactivate(eval);
    }

    // -------------------------------------------------------------
    //  Dir + stat leaves (M-FOUNDATION): TaskListDir / TaskStat
    // -------------------------------------------------------------

    /// TaskListDir path — SYNCHRONOUS directory listing.  openat(O_DIRECTORY)
    /// + getdents64 (raw fs order — NOT sorted; sorting is app-side, Go's
    /// os.ReadDir sorts but the filepicker wants insertion order anyway);
    /// '.'/'..' are skipped (Go os.ReadDir parity).  isDir comes from the
    /// dirent d_type (DT_UNKNOWN falls back to fstatat — symlinked dirs are
    /// NOT dirs, matching Go DirEntry.IsDir).  A failed open completes []
    /// (leafReadFile's empty-string parity).  Entries are drained into
    /// page_allocator storage first, the fd closed, and the Elm list built
    /// right-to-left afterwards — so no GC allocation happens while the fd is
    /// open and every cons cell is rooted per the execComplete discipline.
    fn leafListDir(self: *HostLoop, eval: *Eval) VmError!void {
        const path = self.slots[eval.base].payload.vector.data.?[1];
        var entries = std.ArrayListUnmanaged(DirEntryHost).empty;
        defer {
            for (entries.items) |e| pa.free(e.name);
            entries.deinit(pa);
        }
        const fd = std.posix.openat(
            std.posix.AT.FDCWD,
            values.strSlice(path),
            .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true },
            0,
        ) catch {
            return self.listDirComplete(eval, entries.items);
        };
        defer _ = close(fd);
        var buf: [4096]u8 align(8) = undefined;
        drain: while (true) {
            const nread = std.os.linux.getdents64(fd, &buf, buf.len);
            if (std.os.linux.errno(nread) != .SUCCESS) break :drain; // read error: deliver what we have
            if (nread == 0) break :drain; // end of directory
            var off: usize = 0;
            while (off < nread) {
                const d: *std.os.linux.dirent64 = @alignCast(@ptrCast(&buf[off]));
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&d.name)), 0);
                const dot = name.len == 1 and name[0] == '.';
                const dotdot = name.len == 2 and name[0] == '.' and name[1] == '.';
                if (!dot and !dotdot) {
                    const is_dir = if (d.type == std.os.linux.DT.UNKNOWN)
                        dirEntryIsDir(fd, name)
                    else
                        d.type == std.os.linux.DT.DIR;
                    const copy = pa.dupe(u8, name) catch break :drain; // OOM
                    entries.append(pa, .{ .name = copy, .is_dir = is_dir }) catch {
                        pa.free(copy);
                        break :drain; // OOM: deliver the entries collected so far
                    };
                }
                off += d.reclen;
            }
        }
        try self.listDirComplete(eval, entries.items);
    }

    /// Drain results: build the Elm List of {name,isDir} records right-to-left
    /// (each new record consed onto the rooted tail), then completeSuccess.
    fn listDirComplete(self: *HostLoop, eval: *Eval, entries: []const DirEntryHost) VmError!void {
        var acc_r = values.valNil();
        self.g.rootPushValue(&acc_r);
        defer self.g.rootPop();
        var i = entries.len;
        while (i > 0) {
            i -= 1;
            acc_r = try self.dirRecord(entries[i].name, entries[i].is_dir, acc_r);
        }
        self.slots[resultSlot(eval)] = acc_r;
        try self.completeSuccess(eval);
    }

    /// Build one {name,isDir} record pair-consed onto `tail`, every
    /// intermediate rooted (execComplete discipline).  Field pairs are
    /// cons(name, val) (@p) and the record spine is cons-first-field — the
    /// compiler's record layout (Lower/Expr.recordExpr: field j of the source
    /// sits at depth j; assoc access is first-match anyway).
    fn dirRecord(self: *HostLoop, name: []const u8, is_dir: bool, tail: Value) VmError!Value {
        const g = self.g;
        var tail_r = tail;
        g.rootPushValue(&tail_r);
        defer g.rootPop();
        const name_v = values.valString(g, name);
        var name_r = name_v;
        g.rootPushValue(&name_r);
        defer g.rootPop();
        const name_sym = symbols.valSymbol(&self.vm.symbols, "name");
        const pair_name = try self.runPrim("@p", &.{ name_sym, name_r });
        var pname_r = pair_name;
        g.rootPushValue(&pname_r);
        defer g.rootPop();
        const isdir_sym = symbols.valSymbol(&self.vm.symbols, "isDir");
        const pair_isdir = try self.runPrim("@p", &.{ isdir_sym, values.valBoolean(is_dir) });
        var pdir_r = pair_isdir;
        g.rootPushValue(&pdir_r);
        defer g.rootPop();
        // The RECORD spine ends at nil here — the list tail is only consed
        // onto the OUTSIDE of the finished record below (threading tail_r
        // into this cons would bury the rest of the list inside the isDir
        // pair, making assoc/isDir read the tail instead of the bool).
        const inner = values.valCons(g, pdir_r, values.valNil());
        var inner_r = inner;
        g.rootPushValue(&inner_r);
        defer g.rootPop();
        const rec = values.valCons(g, pname_r, inner_r);
        var rec_r = rec;
        g.rootPushValue(&rec_r);
        defer g.rootPop();
        return values.valCons(g, rec_r, tail_r);
    }

    /// TaskStat path — SYNCHRONOUS fstatat(AT_FDCWD) following symlinks (Go
    /// os.Stat parity).  Completes with {size, mode, mtimeMs, isDir, isFile};
    /// mtimeMs = st_mtim sec*1000 + nsec/1e6, isDir/isFile are the S_IFMT
    /// type bits.  A failed stat (ENOENT ...) completes the ZERO record —
    /// the same shape as the sync runTask no-op (pinned by statunit).
    fn leafStat(self: *HostLoop, eval: *Eval) VmError!void {
        const path = self.slots[eval.base].payload.vector.data.?[1];
        var st: Stat = undefined;
        var ok = false;
        if (std.posix.toPosixPath(values.strSlice(path))) |pathz| {
            ok = fstatat(std.posix.AT.FDCWD, &pathz, &st, 0) == 0;
        } else |_| {}
        const size: i64 = if (ok) @intCast(st.size) else 0;
        const mode: i64 = if (ok) @intCast(st.mode) else 0;
        const mtime_ms: i64 = if (ok)
            @as(i64, @intCast(st.mtim.sec)) * 1000 + @divTrunc(@as(i64, @intCast(st.mtim.nsec)), 1_000_000)
        else
            0;
        const type_bits: u32 = if (ok) st.mode & std.posix.S.IFMT else 0;
        const is_dir = type_bits == std.posix.S.IFDIR;
        const is_file = type_bits == std.posix.S.IFREG;
        self.slots[resultSlot(eval)] = try self.statRecord(size, mode, mtime_ms, is_dir, is_file);
        try self.completeSuccess(eval);
    }

    /// Build the {size,mode,mtimeMs,isDir,isFile} record right-to-left (field
    /// j of the source at depth j).  All field values are immediates, so the
    /// only GC allocations are the rooted pair + spine conses.
    fn statRecord(self: *HostLoop, size: i64, mode: i64, mtime_ms: i64, is_dir: bool, is_file: bool) VmError!Value {
        const g = self.g;
        const Field = struct { sym: []const u8, val: Value };
        const fields = [_]Field{
            .{ .sym = "isFile", .val = values.valBoolean(is_file) },
            .{ .sym = "isDir", .val = values.valBoolean(is_dir) },
            .{ .sym = "mtimeMs", .val = values.valNumber(mtime_ms) },
            .{ .sym = "mode", .val = values.valNumber(mode) },
            .{ .sym = "size", .val = values.valNumber(size) },
        };
        var acc_r = values.valNil();
        g.rootPushValue(&acc_r);
        defer g.rootPop();
        for (fields) |f| {
            const sym = symbols.valSymbol(&self.vm.symbols, f.sym);
            const pair = try self.runPrim("@p", &.{ sym, f.val });
            var pair_r = pair;
            g.rootPushValue(&pair_r);
            defer g.rootPop();
            acc_r = values.valCons(g, pair_r, acc_r);
        }
        return acc_r;
    }

    /// Build a host Key vector (bare ctor name + args in ctor order) rooted
    /// per execComplete: arg built + rooted first, then the vector, then plain
    /// stores (no GC alloc after the vector).  Tag compare is by name
    /// (primEq), so the bare ctor spelling is the only contract.
    fn buildKey(self: *HostLoop, event: InputEvent) Value {
        const ek = event.key;
        switch (ek.kind) {
            .char => return self.buildKeyArg("KeyChar", values.valString(self.g, ek.char[0..ek.char_len])),
            .ctrl => {
                var cb = [1]u8{@intCast(ek.num)};
                return self.buildKeyArg("KeyCtrl", values.valString(self.g, &cb));
            },
            .other => return self.buildKeyArg("KeyOther", values.valNumber(ek.num)),
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

    /// Build the host MouseMsg vector (bare ctor "MouseMsg" + action/button
    /// 0-ary ctor vectors + x/y) or "MouseEof" for EOF.  The action/button
    /// vectors are GC-allocated, so each is rooted BEFORE the next allocation
    /// (numbers/symbols are immediate / non-GC).
    fn buildMouse(self: *HostLoop, event: InputEvent) Value {
        const m = event.mouse;
        if (m.eof) return self.buildKey0("MouseEof");
        const action = self.buildKey0(mouseActionName(m.action));
        var a = action;
        self.g.rootPushValue(&a);
        defer self.g.rootPop();
        const button = self.buildKey0(mouseButtonName(m.button));
        var b = button;
        self.g.rootPushValue(&b);
        defer self.g.rootPop();
        const v = values.valVector(self.g, 5);
        const d = v.payload.vector.data.?;
        d[0] = symbols.valSymbol(&self.vm.symbols, "MouseMsg");
        d[1] = a;
        d[2] = b;
        d[3] = values.valNumber(m.x);
        d[4] = values.valNumber(m.y);
        return v;
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

    /// True iff any active readkey/readmouse eval is in lone-ESC wait — drives
    /// the 50ms poll timeout instead of blocking forever on an unconfirmed ESC.
    fn anyEscWait(self: *HostLoop) bool {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active) continue;
            if (eval.eff == .readkey and eval.eff.readkey.esc_wait) return true;
            if (eval.eff == .readmouse and eval.eff.readmouse.esc_wait) return true;
        }
        return false;
    }

    /// Poll timed out: every eval waiting on a possible lone ESC is now
    /// confirmed ESC (no CSI bytes followed within the deadline).  A readkey
    /// eval flushes to KeyEsc; a readmouse eval's lone ESC is a KEY, so it is
    /// handed to an armed readkey eval (or parked) and the mouse eval keeps
    /// waiting (bubbletea's deadline approach).
    fn flushEscWaits(self: *HostLoop) VmError!void {
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active) continue;
            if (eval.eff == .readkey and eval.eff.readkey.esc_wait) {
                try self.inputComplete(eval, evKey(.esc));
            } else if (eval.eff == .readmouse and eval.eff.readmouse.esc_wait) {
                eval.eff.readmouse.buf.clearRetainingCapacity();
                eval.eff.readmouse.esc_wait = false;
                try self.deliverInputEvent(evKey(.esc));
            }
        }
    }

    /// The earliest pending sleep deadline (monotonic ms), or null if none.
    fn nearestSleepDeadline(self: *HostLoop) ?i64 {
        var best: ?i64 = null;
        var i: usize = 0;
        while (i < self.nevals) : (i += 1) {
            const eval = &self.evals[i];
            if (!eval.active or eval.eff != .sleep) continue;
            const d = eval.eff.sleep.deadline_ms;
            if (best == null or d < best.?) best = d;
        }
        return best;
    }

    /// Poll timeout: the existing 50ms lone-ESC bound, tightened by the nearest
    /// pending sleep deadline (so a sleeping eval wakes the poll instead of
    /// blocking past it).  -1 = block indefinitely (no esc_wait, no sleep).
    fn pollTimeout(self: *HostLoop) i32 {
        var t: i32 = if (self.anyEscWait()) 50 else -1;
        if (self.nearestSleepDeadline()) |deadline| {
            const remain = deadline - nowMs();
            const rem: i32 = if (remain <= 0)
                0
            else
                @intCast(@min(remain, @as(i64, std.math.maxInt(i32))));
            t = if (t < 0) rem else @min(t, rem);
        }
        return t;
    }

    /// Complete every expired sleep in deadline order (earliest first).  Each
    /// completion may deliver + spawn new evals, so re-scan from scratch after
    /// each — a freshly spawned sleep's deadline is now+ms (future), so it
    /// cannot make this loop livelock.
    fn flushExpiredSleeps(self: *HostLoop) VmError!void {
        const now = nowMs();
        while (true) {
            var best: ?*Eval = null;
            var i: usize = 0;
            while (i < self.nevals) : (i += 1) {
                const eval = &self.evals[i];
                if (!eval.active or eval.eff != .sleep) continue;
                if (eval.eff.sleep.deadline_ms > now) continue;
                if (best == null or eval.eff.sleep.deadline_ms < best.?.eff.sleep.deadline_ms) {
                    best = eval;
                }
            }
            if (best) |eval| {
                try self.sleepComplete(eval);
            } else return;
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
                .readmouse => if (!self.stdin_eof) self.addPoll(i, 0, .readkey),
                .sleep => {},
                .winch => if (self.winch_fd >= 0) self.addPoll(i, self.winch_fd, .winch),
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
        // Winch is a SHARED fd with complete-ALL semantics (one SIGWINCH wakes
        // every armed winch eval) — drain it once up front, before the per-eval
        // scan, so the siginfo is read exactly once per poll wake.
        var winch_ready = false;
        var wi: usize = 0;
        while (wi < n) : (wi += 1) {
            if (self.poll_role[wi] == .winch and self.pollfds[wi].revents != 0) {
                winch_ready = true;
                break;
            }
        }
        if (winch_ready) try self.drainWinch();

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
                    // May have been flushed by a poll timeout/EOF before this
                    // scan — drain whichever stdin-eff variant is still armed.
                    switch (eval.eff) {
                        .readkey => _ = try self.inputDrain(eval, false),
                        .readmouse => _ = try self.inputDrain(eval, true),
                        else => {},
                    }
                },
                .winch => {}, // handled by drainWinch above
            }
        }
    }

    /// One SIGWINCH arrived on the shared signalfd: drain one siginfo, read the
    /// fresh size, and complete EVERY armed winch eval with it.  Each
    /// completion may deliver + spawn a re-arm eval (which is .none until the
    /// next stepAll), so rescan per completion like flushExpiredSleeps.
    fn drainWinch(self: *HostLoop) VmError!void {
        var si: std.os.linux.signalfd_siginfo = undefined;
        _ = std.posix.read(self.winch_fd, std.mem.asBytes(&si)) catch {};
        const sz = readWinSize();
        var tuple = values.valCons(self.g, values.valNumber(sz.cols), values.valNumber(sz.rows));
        self.g.rootPushValue(&tuple);
        defer self.g.rootPop();
        while (true) {
            var found = false;
            var i: usize = 0;
            while (i < self.nevals) : (i += 1) {
                const eval = &self.evals[i];
                if (eval.active and eval.eff == .winch) {
                    eval.eff = .none;
                    self.slots[resultSlot(eval)] = tuple;
                    try self.completeSuccess(eval);
                    found = true;
                    break;
                }
            }
            if (!found) return;
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
        // Mouse-off DECRST BEFORE the termios restore: once termios is back to
        // canonical echo the terminal re-reads the keyboard normally, but SGR
        // tracking modes are independent termios state — without the reset a
        // real terminal keeps reporting clicks as raw SGR packets after exit.
        if (self.mouse_armed) {
            writeFdAll(1, MOUSE_OFF_SEQ);
            self.mouse_armed = false;
        }
        // Restore the saved termios on ANY exit path (raw mode must not leak
        // past an error).
        if (self.saved_termios) |saved| {
            _ = std.posix.tcsetattr(0, .DRAIN, saved) catch {};
            self.saved_termios = null;
        }
        self.stdin_pending.deinit(pa);
        self.pending_events.deinit(pa);
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
                .readmouse => {
                    eval.eff.readmouse.buf.deinit(pa);
                    eval.eff = .none;
                },
                .sleep => {
                    // No fd or buffer to free — just drop the pending sleep.
                    eval.eff = .none;
                },
                .winch => {
                    // No per-eval fd/buffer — the shared signalfd is closed below.
                    eval.eff = .none;
                },
            }
        }
        if (self.winch_fd >= 0) {
            _ = close(self.winch_fd);
            self.winch_fd = -1;
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

    while (loop.nactive > 0 and !loop.quit) {
        try loop.stepAll();
        if (loop.quit) break;
        if (loop.nactive == 0) break;
        loop.reapChildren();
        try loop.completeReady();
        // Parked bytes from a previous drain must reach an already-armed
        // stdin eval (and its continuation spawns must be stepped) before
        // the poll — otherwise an empty-buf reader hangs on a silent fd0.
        try loop.drainPendingStdin();
        if (loop.nactive == 0) break;
        // M9 fix: completeReady applies exec continuations and deliver() can
        // spawn into slots stepAll's cursor already passed, leaving PURE
        // evaluations runnable.  Step them to a fixpoint BEFORE touching the fd
        // tables — otherwise the npoll == 0 branch below breaks the loop and
        // silently drops their messages (fast execs, pure cmd spawns).
        while (loop.hasRunnable()) {
            try loop.stepAll();
            if (loop.quit) break;
            try loop.completeReady();
        }
        if (loop.quit) break;
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
            // Only pending sleeps remain: fall through to poll with an empty
            // fd set — poll(2) with nfds=0 + a timeout is a bounded sleep.
            if (loop.nearestSleepDeadline() == null) {
                std.debug.print("effectloop: pending effect with no pollable fd\n", .{});
                break;
            }
        }
        // A readkey eval in lone-ESC wait needs a bounded poll (50ms) so an
        // unconfirmed ESC flushes to KeyEsc; a pending sleep tightens that to
        // its nearest deadline; otherwise block until an fd is ready.
        const poll_timeout: i32 = loop.pollTimeout();
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
        try loop.flushExpiredSleeps();
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
    // The host BLOCKs SIGWINCH for its signalfd; exec PRESERVES the blocked
    // mask, so unblock it here or the exec'd child (a shell, a pager) loses
    // its own SIGWINCH handling.  libc-only (async-signal-safe), no GC.
    var winch_mask = sigwinchMask();
    std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &winch_mask, null);

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
        std.mem.eql(u8, name, "TaskRawMode") or std.mem.eql(u8, name, "TaskSleep") or
        std.mem.eql(u8, name, "TaskMouseMode") or
        std.mem.eql(u8, name, "TaskListDir") or std.mem.eql(u8, name, "TaskStat")) return 1;
    if (std.mem.eql(u8, name, "TaskAndThen") or std.mem.eql(u8, name, "TaskOnError") or
        std.mem.eql(u8, name, "TaskWriteFile") or std.mem.eql(u8, name, "TaskSetenv")) return 2;
    if (std.mem.eql(u8, name, "TaskReadLine") or std.mem.eql(u8, name, "TaskGetcwd") or
        std.mem.eql(u8, name, "TaskGetpid") or std.mem.eql(u8, name, "TaskReadKey") or
        std.mem.eql(u8, name, "TaskReadMouse") or
        std.mem.eql(u8, name, "TaskWinSize") or std.mem.eql(u8, name, "TaskWaitResize") or
        std.mem.eql(u8, name, "TaskNow") or std.mem.eql(u8, name, "TaskQuit")) return 0;
    return null;
}

/// Monotonic clock in milliseconds (CLOCK_MONOTONIC — NOT wall-clock; a wall
/// clock jump would break timers).  Returns 0 on a failed read.
fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    if (std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// Terminal size via ioctl TIOCGWINSZ (fd0, falling back to fd1, else 0x0).
/// Shared by leafWinSize (sync probe), leafWaitResize's signalfd-failure
/// fallback, and drainWinch (fresh read on each SIGWINCH).
const WinSize = struct { cols: i64, rows: i64 };

/// A drained directory entry — page_allocator OWNED name bytes (GC values are
/// only built in listDirComplete, after the dirfd is closed).
const DirEntryHost = struct { name: []u8, is_dir: bool };

/// d_type DT_UNKNOWN fallback (some filesystems): fstatat the entry relative
/// to the open dirfd without following symlinks (Go DirEntry.IsDir parity —
/// a symlink-to-dir is NOT a dir).
fn dirEntryIsDir(dirfd: c_int, name: []const u8) bool {
    const pathz = std.posix.toPosixPath(name) catch return false;
    var st: Stat = undefined;
    if (fstatat(dirfd, &pathz, &st, std.posix.AT.SYMLINK_NOFOLLOW) != 0) return false;
    return st.mode & std.posix.S.IFMT == std.posix.S.IFDIR;
}

fn readWinSize() WinSize {
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
    return .{ .cols = cols, .rows = rows };
}

/// The SIGWINCH mask: BLOCKed by the host (so the signal queues into the
/// signalfd instead of firing the default disposition) and UNBLOCKed in exec
/// children (exec preserves the blocked mask — a blocked SIGWINCH would break
/// the child's own resize handling).
fn sigwinchMask() std.posix.sigset_t {
    var mask = std.posix.sigemptyset();
    std.posix.sigaddset(&mask, std.posix.SIG.WINCH);
    return mask;
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
//  Terminal input decode (M1 tea + S4 mouse) — the state machine behind
//  TaskReadKey AND TaskReadMouse.  Returns null when the buffer is an
//  INCOMPLETE prefix (caller suspends; esc_wait is set iff the prefix is
//  ESC/CSI).  Single-byte controls and UTF-8 are decoded directly; ESC
//  introduces CSI/SS3 sequences, including SGR mouse (ESC [ < ... M/m).
// ---------------------------------------------------------------------

fn decodeInput(buf: []const u8) ?DecodedInput {
    if (buf.len == 0) return null;
    const b0 = buf[0];
    // Ctrl keys: 0x01..0x1A EXCEPT the specials the switch maps (tab/enter/
    // backspace) — Zig switch ranges must not overlap, so this runs first.
    if (b0 >= 0x01 and b0 <= 0x1A and b0 != 0x08 and b0 != 0x09 and b0 != 0x0A and b0 != 0x0D) {
        return .{ .consumed = 1, .event = .{ .key = .{ .kind = .ctrl, .num = @intCast(b0 - 0x01 + 'a') } } };
    }
    switch (b0) {
        0x0D, 0x0A => return .{ .consumed = 1, .event = .{ .key = .{ .kind = .enter } } },
        0x09 => return .{ .consumed = 1, .event = .{ .key = .{ .kind = .tab } } },
        0x7F, 0x08 => return .{ .consumed = 1, .event = .{ .key = .{ .kind = .backspace } } },
        0x00, 0x1C...0x1F => return .{ .consumed = 1, .event = .{ .key = .{ .kind = .other, .num = b0 } } },
        0x80...0xBF => return .{ .consumed = 1, .event = .{ .key = .{ .kind = .other, .num = b0 } } }, // stray continuation
        0x1B => return decodeEsc(buf),
        0xC0...0xF4 => return decodeUtf8(buf),
        0x20...0x7E => return .{ .consumed = 1, .event = .{ .key = .{ .kind = .char, .char = .{ b0, 0, 0, 0 }, .char_len = 1 } } }, // plain ASCII
        else => return .{ .consumed = 1, .event = .{ .key = .{ .kind = .other, .num = b0 } } }, // 0xF5..0xFF etc.
    }
}

/// ESC: CSI (`[`) / SS3 (`O`) with params then a final byte; a lone ESC or an
/// unparsed prefix is incomplete (null).  ESC followed by a NON-sequence byte
/// is a bare KeyEsc consuming ONLY the ESC — the following byte stays in the
/// accumulator (stdin_pending pushback) and the re-armed read decodes it as
/// its own event.  A CSI whose params start with '<' and final is 'M'/'m' is
/// SGR mouse (decoded BEFORE the generic CSI map).
fn decodeEsc(buf: []const u8) ?DecodedInput {
    if (buf.len < 2) return null; // lone ESC — incomplete
    const b1 = buf[1];
    if (b1 == 'O' or b1 == '[') {
        var i: usize = 2;
        while (i < buf.len) : (i += 1) {
            const c = buf[i];
            if (c >= 0x40 and c <= 0x7E) {
                const params = buf[2..i];
                if (b1 == '[' and params.len > 0 and params[0] == '<' and (c == 'M' or c == 'm')) {
                    if (decodeSgrMouse(params, c, i + 1)) |d| return d;
                }
                return mapCsiFinal(params, c, i + 1);
            }
            if (c < 0x30 or c > 0x3F) return null; // not a param/intermediate — incomplete
        }
        return null; // ran out before a final byte
    }
    return .{ .consumed = 1, .event = .{ .key = .{ .kind = .esc } } };
}

/// SGR mouse packet: ESC [ < cb ; cx ; cy M/m.  `params` starts with '<'.
/// cb: button bits 0-1 (0=left,1=middle,2=right,3=none), motion bit 0x20,
/// wheel bit 0x40 (64-67 = up/down/left/right).  final 'm' = release, else
/// press (or motion when bit 5 set).  x=cx-1, y=cy-1 (1-based -> 0-based).
fn decodeSgrMouse(params: []const u8, final: u8, consumed: usize) ?DecodedInput {
    if (params.len < 1 or params[0] != '<') return null;
    var vals: [3]i64 = .{ 0, 0, 0 };
    var n: usize = 0;
    var acc: i64 = 0;
    var i: usize = 1;
    while (i < params.len) : (i += 1) {
        const c = params[i];
        if (c >= '0' and c <= '9') {
            acc = acc * 10 + @as(i64, c - '0');
        } else if (c == ';') {
            if (n >= 3) return null;
            vals[n] = acc;
            n += 1;
            acc = 0;
        } else {
            return null; // ':'/'?' etc — not a plain SGR mouse packet
        }
    }
    if (n >= 3) return null;
    vals[n] = acc;
    n += 1;
    if (n != 3) return null;

    const cb = vals[0];
    const btn = cb & 0x03;
    var action: MouseAction = undefined;
    var button: MouseButton = undefined;
    if ((cb & 0x40) != 0) {
        action = .wheel;
        button = switch (btn) {
            0 => .wheel_up,
            1 => .wheel_down,
            2 => .wheel_left,
            3 => .wheel_right,
            else => .none,
        };
    } else if ((cb & 0x20) != 0) {
        action = .motion;
        button = switch (btn) {
            0 => .left,
            1 => .middle,
            2 => .right,
            else => .none,
        };
    } else {
        action = if (final == 'm') .release else .press;
        button = switch (btn) {
            0 => .left,
            1 => .middle,
            2 => .right,
            else => .none,
        };
    }
    return .{ .consumed = consumed, .event = .{ .mouse = .{
        .action = action,
        .button = button,
        .x = vals[1] - 1,
        .y = vals[2] - 1,
    } } };
}

/// UTF-8 lead (0xC0..0xF4): decode iff all continuation bytes are present.
/// Missing continuations -> incomplete (null); a non-continuation byte -> the
/// lead is treated as a stray KeyOther byte.
fn decodeUtf8(buf: []const u8) ?DecodedInput {
    const b0 = buf[0];
    const need: usize = if (b0 < 0xE0) 1 else if (b0 < 0xF0) 2 else 3;
    if (buf.len < 1 + need) return null;
    var i: usize = 1;
    while (i <= need) : (i += 1) {
        if (buf[i] & 0xC0 != 0x80) return .{ .consumed = 1, .event = .{ .key = .{ .kind = .other, .num = b0 } } };
    }
    var ek = EventKey{ .kind = .char, .char_len = 1 + need };
    @memcpy(ek.char[0 .. 1 + need], buf[0 .. 1 + need]);
    return .{ .consumed = 1 + need, .event = .{ .key = ek } };
}

/// Map a CSI/SS3 final byte (with the param bytes preceding it) to a key.
/// A/B/C/D -> arrows, H/F -> home/end, `~` -> by LAST param digit
/// (1..6 = Home/Ins/Del/End/PgUp/PgDn; params stripped, modifiers ignored).
fn mapCsiFinal(params: []const u8, final: u8, consumed: usize) ?DecodedInput {
    switch (final) {
        'A' => return .{ .consumed = consumed, .event = .{ .key = .{ .kind = .up } } },
        'B' => return .{ .consumed = consumed, .event = .{ .key = .{ .kind = .down } } },
        'C' => return .{ .consumed = consumed, .event = .{ .key = .{ .kind = .right } } },
        'D' => return .{ .consumed = consumed, .event = .{ .key = .{ .kind = .left } } },
        'H' => return .{ .consumed = consumed, .event = .{ .key = .{ .kind = .home } } },
        'F' => return .{ .consumed = consumed, .event = .{ .key = .{ .kind = .end } } },
        '~' => {
            var last: u8 = 1;
            for (params) |p| {
                if (p >= '0' and p <= '9') last = p - '0';
            }
            const kind: KeyKind = switch (last) {
                1 => .home,
                2 => .ins,
                3 => .del,
                4 => .end,
                5 => .pgup,
                6 => .pgdn,
                else => .other,
            };
            if (kind == .other) {
                return .{ .consumed = consumed, .event = .{ .key = .{ .kind = .other, .num = last } } };
            }
            return .{ .consumed = consumed, .event = .{ .key = .{ .kind = kind } } };
        },
        else => return .{ .consumed = consumed, .event = .{ .key = .{ .kind = .other, .num = final } } },
    }
}

fn mouseActionName(a: MouseAction) []const u8 {
    return switch (a) {
        .press => "MousePress",
        .release => "MouseRelease",
        .motion => "MouseMotion",
        .wheel => "MouseWheel",
    };
}

fn mouseButtonName(b: MouseButton) []const u8 {
    return switch (b) {
        .left => "MouseLeft",
        .middle => "MouseMiddle",
        .right => "MouseRight",
        .none => "MouseNone",
        .wheel_up => "MouseWheelUp",
        .wheel_down => "MouseWheelDown",
        .wheel_left => "MouseWheelLeft",
        .wheel_right => "MouseWheelRight",
    };
}
