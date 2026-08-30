//! tools/ptytest.zig — PTY test harness for the bubbletea substrate (STEP 2).
//!
//! A libc-linked, dependency-free (NO vm imports) POSIX expect-runner: it
//! spawns `elmvm <bundle> <Mod.fn>` inside a freshly allocated pseudo-terminal
//! (so the program sees a real tty on fd 0/1/2), then drives it with a
//! line-based script and asserts on the captured output.
//!
//! Usage:
//!   ptytest <elmvm> <bundle.csexp> <Mod.fn> <script-file>
//!
//! Prints `PASS <label>: <n> expects` (exit 0) or `FAIL <label>: <reason>`
//! followed by an escaped dump of the captured output (exit 1).
//!
//! SCRIPT (line-based; `#` comments and blank lines ignored):
//!   send <escaped>          write bytes to the pty master
//!   expect <escaped>        wait (10s cap) until the capture CONTAINS the bytes
//!   expect_exit <code>      wait (10s cap) for the child to exit <code>
//!   resize <cols> <rows>    TIOCSWINSZ on the master (fires SIGWINCH)
//!   Escapes: \xNN \n \r \e \t (\\ is a literal backslash).
//!
//! SETUP: open /dev/ptmx (O_RDWR|O_NOCTTY), unlock it (TIOCSPTLCK=0), read the
//! pts number (TIOCGPTN), set the window size 80x24 (TIOCSWINSZ), open the
//! slave, then fork.  The child calls setsid(), adopts the slave as its
//! controlling terminal (TIOCSCTTY), dup2s it onto 0/1/2, and execvp's elmvm.
//! The parent keeps the master and runs the script.

const std = @import("std");

extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn fork() c_int;
extern "c" fn setsid() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn clock_gettime(clk_id: c_int, tp: *std.posix.timespec) c_int;

const O_RDWR: c_int = 2;
const O_NOCTTY: c_int = 0x100;
const O_NONBLOCK: c_int = 0x800;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const CLOCK_MONOTONIC: c_int = 1;
const WNOHANG: c_int = 1;
const SIGKILL: c_int = 9;

const EXPECT_TIMEOUT_MS: i64 = 10_000;
const EXIT_TIMEOUT_MS: i64 = 10_000;

const pa = std.heap.page_allocator;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;

    var it = init.minimal.args.iterate();
    _ = it.next(); // program name
    const elmvm_path = it.next() orelse usage();
    const bundle_path = it.next() orelse usage();
    const fn_name = it.next() orelse usage();
    const script_path = it.next() orelse usage();

    const script = std.Io.Dir.readFileAlloc(.cwd(), io, script_path, a, std.Io.Limit.limited(1 << 20)) catch {
        try outFmt(io, "FAIL {s}: cannot read script\n", .{script_path});
        std.process.exit(1);
    };

    var label = std.fs.path.basename(script_path);
    if (std.mem.endsWith(u8, label, ".script")) label = label[0 .. label.len - ".script".len];

    // ---- allocate + configure the pty master ----
    const master = open("/dev/ptmx", O_RDWR | O_NOCTTY);
    if (master < 0) return fail(io, label, "cannot open /dev/ptmx", "");

    var unlock: c_int = 0;
    _ = ioctl(master, std.posix.T.IOCSPTLCK, &unlock);

    var ptn: c_uint = 0;
    if (ioctl(master, std.posix.T.IOCGPTN, &ptn) != 0) {
        _ = close(master);
        return fail(io, label, "TIOCGPTN failed", "");
    }
    var slave_path_buf: [64]u8 = undefined;
    const slave_path = std.fmt.bufPrintZ(&slave_path_buf, "/dev/pts/{d}", .{ptn}) catch {
        _ = close(master);
        return fail(io, label, "pts path too long", "");
    };

    var ws = std.posix.winsize{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = ioctl(master, std.posix.T.IOCSWINSZ, &ws);

    const slave = open(slave_path.ptr, O_RDWR | O_NOCTTY);
    if (slave < 0) {
        _ = close(master);
        return fail(io, label, "cannot open pty slave", "");
    }

    const elmvm_z = a.dupeZ(u8, elmvm_path) catch unreachable;
    const bundle_z = a.dupeZ(u8, bundle_path) catch unreachable;
    const fn_z = a.dupeZ(u8, fn_name) catch unreachable;

    const pid = fork();
    if (pid < 0) {
        _ = close(master);
        _ = close(slave);
        return fail(io, label, "fork failed", "");
    }
    if (pid == 0) {
        // Child: new session, adopt the slave as controlling tty, bind it to
        // 0/1/2, then run elmvm.  Only libc + write + _exit from here on (no
        // allocator, no GC) — safe after fork.
        _ = setsid();
        _ = ioctl(slave, std.posix.T.IOCSCTTY, @as(c_int, 0));
        _ = dup2(slave, 0);
        _ = dup2(slave, 1);
        _ = dup2(slave, 2);
        if (slave > 2) _ = close(slave);
        _ = close(master);
        const argv: [:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{ elmvm_z.ptr, bundle_z.ptr, fn_z.ptr };
        _ = execvp(elmvm_z.ptr, argv.ptr);
        const msg = "ptytest: execvp failed\n";
        _ = write(2, msg.ptr, msg.len);
        _exit(126);
    }

    // Parent: close the slave, keep the master, run the script.
    _ = close(slave);
    setNonblocking(master);

    var capture = std.ArrayListUnmanaged(u8).empty;
    defer capture.deinit(pa);

    var nexp: usize = 0;
    var ok = true;
    var reason: []const u8 = "";

    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, line_raw, "\r"), " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "send ")) {
            var bytes = std.ArrayListUnmanaged(u8).empty;
            defer bytes.deinit(pa);
            if (!unescape(&bytes, line["send ".len..])) {
                ok = false;
                reason = "bad send escape";
                break;
            }
            writeAll(master, bytes.items);
        } else if (std.mem.startsWith(u8, line, "resize ")) {
            // resize <cols> <rows>: TIOCSWINSZ on the master fires SIGWINCH at
            // the foreground process group (the child elmvm), which the S5
            // signalfd host loop delivers as a resize event.
            var dims = std.mem.tokenizeScalar(u8, std.mem.trim(u8, line["resize ".len..], " \t"), ' ');
            const cols_s = dims.next() orelse {
                ok = false;
                reason = "resize: missing cols";
                break;
            };
            const rows_s = dims.next() orelse {
                ok = false;
                reason = "resize: missing rows";
                break;
            };
            const cols = std.fmt.parseInt(u16, cols_s, 10) catch {
                ok = false;
                reason = "resize: bad cols";
                break;
            };
            const rows = std.fmt.parseInt(u16, rows_s, 10) catch {
                ok = false;
                reason = "resize: bad rows";
                break;
            };
            var nws = std.posix.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
            if (ioctl(master, std.posix.T.IOCSWINSZ, &nws) != 0) {
                ok = false;
                reason = "resize: TIOCSWINSZ failed";
                break;
            }
        } else if (std.mem.startsWith(u8, line, "expect_exit ")) {
            const code = std.fmt.parseInt(u8, std.mem.trim(u8, line["expect_exit ".len..], " \t"), 10) catch 255;
            if (!expectExit(master, pid, code, &capture)) {
                ok = false;
                reason = "expect_exit failed";
                break;
            }
            nexp += 1;
        } else if (std.mem.startsWith(u8, line, "expect ")) {
            var needle = std.ArrayListUnmanaged(u8).empty;
            defer needle.deinit(pa);
            if (!unescape(&needle, line["expect ".len..])) {
                ok = false;
                reason = "bad expect escape";
                break;
            }
            if (!expect(master, &capture, needle.items)) {
                ok = false;
                reason = "expect timeout";
                break;
            }
            nexp += 1;
        } else {
            ok = false;
            reason = "unknown directive";
            break;
        }
    }

    if (ok) {
        try outFmt(io, "PASS {s}: {d} expects\n", .{ label, nexp });
        // A script without a trailing expect_exit leaves a still-running elmvm
        // attached to a now-closing master — reap it (SIGKILL if not already
        // exited) instead of orphaning it.
        reapChild(pid);
        std.process.exit(0);
    }

    // Failure: kill any still-running child, then dump the capture.
    _ = kill(pid, SIGKILL);
    _ = waitpid(pid, null, 0);
    try outFmt(io, "FAIL {s}: {s}\n", .{ label, reason });
    dumpCapture(io, capture.items);
    std.process.exit(1);
}

/// Reap the child without orphaning it: try WNOHANG first (a trailing
/// expect_exit already reaped it -> ECHILD, harmless), and only SIGKILL + block
/// if it is still running.
fn reapChild(pid: c_int) void {
    var st: c_int = 0;
    const r = waitpid(pid, &st, WNOHANG);
    if (r == 0) {
        _ = kill(pid, SIGKILL);
        _ = waitpid(pid, null, 0);
    }
}

fn usage() noreturn {
    std.debug.print("usage: ptytest <elmvm> <bundle.csexp> <Mod.fn> <script-file>\n", .{});
    std.process.exit(2);
}

fn fail(io: std.Io, label: []const u8, reason: []const u8, dump: []const u8) noreturn {
    outFmt(io, "FAIL {s}: {s}\n", .{ label, reason }) catch {};
    if (dump.len > 0) dumpCapture(io, dump);
    std.process.exit(1);
}

fn outFmt(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try std.Io.File.writeStreamingAll(stdout, io, s);
}

/// Unescape a script token into `dst`.  Returns false on a malformed escape.
fn unescape(dst: *std.ArrayListUnmanaged(u8), src: []const u8) bool {
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            i += 1;
            const e = src[i];
            switch (e) {
                'n' => dst.append(pa, '\n') catch return false,
                'r' => dst.append(pa, '\r') catch return false,
                't' => dst.append(pa, '\t') catch return false,
                'e' => dst.append(pa, 0x1B) catch return false,
                'x' => {
                    if (i + 2 >= src.len) return false;
                    const hi = std.fmt.charToDigit(src[i + 1], 16) catch return false;
                    const lo = std.fmt.charToDigit(src[i + 2], 16) catch return false;
                    dst.append(pa, hi * 16 + lo) catch return false;
                    i += 2;
                },
                '\\' => dst.append(pa, '\\') catch return false,
                else => {
                    dst.append(pa, '\\') catch return false;
                    dst.append(pa, e) catch return false;
                },
            }
        } else {
            dst.append(pa, c) catch return false;
        }
    }
    return true;
}

/// Poll the master for output until `capture` CONTAINS `needle` (substring,
/// scanning across reads), capped at EXPECT_TIMEOUT_MS.  The capture buffer
/// persists across expects, so output emitted before the expect also counts.
fn expect(master: c_int, capture: *std.ArrayListUnmanaged(u8), needle: []const u8) bool {
    if (std.mem.indexOf(u8, capture.items, needle) != null) return true;
    const deadline = nowMs() + EXPECT_TIMEOUT_MS;
    var pfds = [1]std.posix.pollfd{.{ .fd = master, .events = std.posix.POLL.IN, .revents = 0 }};
    while (true) {
        const remaining = deadline - nowMs();
        if (remaining <= 0) return false;
        const rc = std.posix.poll(&pfds, @intCast(@min(remaining, 1000))) catch return false;
        if (rc == 0) continue; // within budget — re-check the deadline
        var buf: [4096]u8 = undefined;
        const n = read(master, &buf, buf.len);
        if (n < 0) {
            const e = std.c._errno().*;
            if (e == @intFromEnum(std.c.E.INTR) or e == @intFromEnum(std.c.E.AGAIN)) continue;
            return false;
        }
        if (n == 0) return std.mem.indexOf(u8, capture.items, needle) != null; // master EOF
        capture.appendSlice(pa, buf[0..@intCast(n)]) catch return false;
        if (std.mem.indexOf(u8, capture.items, needle) != null) return true;
    }
}

/// Wait for the child to exit with `code` (capped at EXIT_TIMEOUT_MS), draining
/// the master meanwhile so a full pty buffer never stalls the child.  On
/// timeout, SIGKILL + fail.
fn expectExit(master: c_int, pid: c_int, code: u8, capture: *std.ArrayListUnmanaged(u8)) bool {
    const deadline = nowMs() + EXIT_TIMEOUT_MS;
    var pfds = [1]std.posix.pollfd{.{ .fd = master, .events = std.posix.POLL.IN, .revents = 0 }};
    while (true) {
        var st: c_int = 0;
        const r = waitpid(pid, &st, WNOHANG);
        if (r == pid) return wexitstatus(st) == code;
        if (r < 0) return false;
        const remaining = deadline - nowMs();
        if (remaining <= 0) break;
        const rc = std.posix.poll(&pfds, @intCast(@min(remaining, 100))) catch 0;
        if (rc > 0) {
            var buf: [4096]u8 = undefined;
            const n = read(master, &buf, buf.len);
            if (n > 0) capture.appendSlice(pa, buf[0..@intCast(n)]) catch {};
        }
    }
    _ = kill(pid, SIGKILL);
    _ = waitpid(pid, null, 0);
    return false;
}

fn wexitstatus(st: c_int) u8 {
    return @intCast((@as(u32, @bitCast(st)) >> 8) & 0xff);
}

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn setNonblocking(fd: c_int) void {
    const fl = fcntl(fd, F_GETFL, @as(c_int, 0));
    if (fl < 0) return;
    _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

fn writeAll(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = write(fd, data[off..].ptr, data[off..].len);
        if (n < 0) {
            if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
            return;
        }
        if (n == 0) return;
        off += @intCast(n);
    }
}

/// Escaped dump of the captured output (readable; `\n`/`\r`/`\t`/`\e` named,
/// other non-printables as \xNN).
fn dumpCapture(io: std.Io, capture: []const u8) void {
    const stdout = std.Io.File.stdout();
    std.Io.File.writeStreamingAll(stdout, io, "captured output (escaped):\n") catch {};
    var wbuf: [8]u8 = undefined;
    for (capture) |b| {
        const s: []const u8 = switch (b) {
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x1B => "\\e",
            else => blk: {
                if (b >= 0x20 and b <= 0x7E) {
                    wbuf[0] = b;
                    break :blk wbuf[0..1];
                }
                break :blk std.fmt.bufPrint(&wbuf, "\\x{x:0>2}", .{b}) catch unreachable;
            },
        };
        std.Io.File.writeStreamingAll(stdout, io, s) catch {};
    }
    std.Io.File.writeStreamingAll(stdout, io, "\n") catch {};
}
