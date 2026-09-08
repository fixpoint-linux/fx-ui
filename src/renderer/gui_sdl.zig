//! SDL2 window + software renderer backend (photon-gui P2 items 10-11) —
//! compiled ONLY under `zig build -Dgui=true` (build.zig wires the effectloop
//! import "gui_backend" to this file; the default build gets gui_stub.zig).
//!
//! THREADING MODEL — THE HARD RULE:
//!   The SDL event thread NEVER touches the VM/GC and never draws.  It
//!   translates SDL_Events into fixed-size gui.EvRecord values and write(2)s
//!   them to a SELF-PIPE; the effectloop thread polls that pipe exactly like
//!   stdin and manufactures ALL Elm Values (leafGuiPoll) on its own thread.
//!   Every window/surface/font/tracker operation (open/present/close) also
//!   runs on the effectloop thread; the event thread's ONLY SDL call is
//!   SDL_WaitEvent (the event subsystem has SDL-internal locking).  This is
//!   the plan's risk-2 mitigation, verbatim.
//!
//! RENDER MODEL (photon renderer.c + rencache.c, in terminal cells):
//!   leafRender decodes the TaskRender Frame Value into []const []const
//!   gui.Span (effectloop thread, page-allocator arena), then present()
//!   layouts it onto the cell grid (gui.layoutFrame), hashes every cell into
//!   the rencache damage tracker, and repaints ONLY the dirty rects: per cell
//!   SetClip == the SDL_Rect clip of the dirty rect, DrawRect == SDL_FillRect
//!   of the cell bg, DrawText == stb_truetype glyph blit at (col*cell_w,
//!   row*cell_h) in the span fg with bold/underline/strike attrs.  The glyph
//!   cache is lazy (rasterized on first use) and only the drawing thread
//!   touches it.
//!
//! SDL and stb_truetype are bound through extern declarations (the
//! effectloop libc-externs discipline): Zig 0.16.0 translate-c cannot compile
//! SDL's headers.  All constants below are ABI-stable SDL values, verified
//! against SDL 2.32.72 (see tools note in the P2 plan).

const std = @import("std");
const posix = std.posix;
const gui = @import("gui_model");
const rencache = @import("rencache.zig");

const pa = std.heap.page_allocator;

// libc externs (std.posix lost pipe/write/close in 0.16 — same declarations
// as src/effectloop.zig:86-90, namespaced so the backend's own close() API
// keeps its name).
const c = struct {
    extern "c" fn pipe(fds: *[2]c_int) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
};
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x800;

// ---------------------------------------------------------------------
//  SDL extern declarations + ABI constants
// ---------------------------------------------------------------------

const SDL_Window = opaque {};

const SDL_Rect = extern struct { x: i32, y: i32, w: i32, h: i32 };

const SDL_PixelFormat = extern struct {
    format: u32,
    palette: ?*anyopaque,
    BitsPerPixel: u8,
    BytesPerPixel: u8,
    padding: [2]u8,
    Rmask: u32,
    Gmask: u32,
    Bmask: u32,
    Amask: u32,
    Rloss: u8,
    Gloss: u8,
    Bloss: u8,
    Aloss: u8,
    Rshift: u8,
    Gshift: u8,
    Bshift: u8,
    Ashift: u8,
    refcount: i32,
    next: ?*SDL_PixelFormat,
};

const SDL_Surface = extern struct {
    flags: u32,
    format: *SDL_PixelFormat,
    w: i32,
    h: i32,
    pitch: i32,
    pixels: *anyopaque,
    userdata: ?*anyopaque,
    locked: i32,
    lock_data: ?*anyopaque,
    clip_rect: SDL_Rect,
    map: ?*anyopaque,
    refcount: i32,
};

comptime {
    if (@sizeOf(SDL_Surface) != 96) @compileError("SDL_Surface ABI drift (expected 96 bytes)");
}

/// sizeof(SDL_Event) == 56 (documented SDL ABI).  Every event layout below
/// is cast out of these bytes — SDL writes only the member it delivers.
const SDL_Event = extern struct { data: [56]u8 };

const EvCommon = extern struct { type: u32, timestamp: u32 };
const EvKey = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    state: u8,
    repeat: u8,
    padding: [2]u8,
    keysym: extern struct { scancode: i32, sym: i32, mod: u16, unused: u32 },
};
const EvText = extern struct { type: u32, timestamp: u32, windowID: u32, text: [32]u8 };
const EvMotion = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    which: u32,
    state: u32,
    x: i32,
    y: i32,
    xrel: i32,
    yrel: i32,
};
const EvButton = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    which: u32,
    button: u8,
    state: u8,
    clicks: u8,
    padding1: u8,
    x: i32,
    y: i32,
};
const EvWheel = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    which: u32,
    x: i32,
    y: i32,
    direction: u32,
};
const EvWindow = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    event: u8,
    padding1: u8,
    padding2: u8,
    padding3: u8,
    data1: i32,
    data2: i32,
};

const SDL_INIT_VIDEO: u32 = 0x20;
const SDL_WINDOWPOS_CENTERED: c_int = 0x2FFF0000;
const SDL_WINDOW_SHOWN: u32 = 0x4;
const SDL_WINDOW_RESIZABLE: u32 = 0x20;

const SDL_QUIT: u32 = 0x100;
const SDL_WINDOWEVENT: u32 = 0x200;
const SDL_KEYDOWN: u32 = 0x300;
const SDL_TEXTINPUT: u32 = 0x303;
const SDL_MOUSEMOTION: u32 = 0x400;
const SDL_MOUSEBUTTONDOWN: u32 = 0x401;
const SDL_MOUSEBUTTONUP: u32 = 0x402;
const SDL_MOUSEWHEEL: u32 = 0x403;
const SDL_USEREVENT: u32 = 0x8000;

const SDL_WINDOWEVENT_EXPOSED: u8 = 3;
const SDL_WINDOWEVENT_RESIZED: u8 = 5;
const SDL_WINDOWEVENT_SIZE_CHANGED: u8 = 6;
const SDL_WINDOWEVENT_CLOSE: u8 = 14;

const KMOD_CTRL: u16 = 0x00C0;

extern fn SDL_Init(flags: u32) c_int;
extern fn SDL_Quit() void;
extern fn SDL_CreateWindow(title: [*:0]const u8, x: c_int, y: c_int, w: c_int, h: c_int, flags: u32) ?*SDL_Window;
extern fn SDL_DestroyWindow(window: *SDL_Window) void;
extern fn SDL_GetWindowSurface(window: *SDL_Window) ?*SDL_Surface;
extern fn SDL_GetWindowSize(window: *SDL_Window, w: *c_int, h: *c_int) void;
extern fn SDL_UpdateWindowSurfaceRects(window: *SDL_Window, rects: [*]const SDL_Rect, numrects: c_int) c_int;
extern fn SDL_FillRect(dst: *SDL_Surface, rect: ?*const SDL_Rect, color: u32) c_int;
extern fn SDL_MapRGB(format: *const SDL_PixelFormat, r: u8, g: u8, b: u8) u32;
extern fn SDL_WaitEvent(event: *SDL_Event) c_int;
extern fn SDL_PushEvent(event: *SDL_Event) c_int;
extern fn SDL_StartTextInput() void;

// ---------------------------------------------------------------------
//  stb_truetype extern declarations (vendor/stb/stb_truetype_impl.c)
// ---------------------------------------------------------------------

/// stbtt__buf (private struct, stb_truetype.h): { unsigned char *data; int cursor; int size; }.
const stbtt__buf = extern struct {
    data: [*]u8,
    cursor: c_int,
    size: c_int,
};

/// stbtt_fontinfo from the vendored stb_truetype.h v1.19 (public domain).
const stbtt_fontinfo = extern struct {
    userdata: ?*anyopaque,
    data: [*]const u8,
    fontstart: c_int,
    numGlyphs: c_int,
    loca: c_int,
    head: c_int,
    glyf: c_int,
    hhea: c_int,
    hmtx: c_int,
    kern: c_int,
    gpos: c_int,
    index_map: c_int,
    indexToLocFormat: c_int,
    cff: stbtt__buf,
    charstrings: stbtt__buf,
    gsubrs: stbtt__buf,
    subrs: stbtt__buf,
    fontdicts: stbtt__buf,
    fdselect: stbtt__buf,
};

comptime {
    if (@sizeOf(stbtt__buf) != 16) @compileError("stbtt__buf ABI drift (expected 16 bytes)");
    if (@sizeOf(stbtt_fontinfo) != 160) @compileError("stbtt_fontinfo ABI drift (expected 160 bytes)");
}

extern fn stbtt_InitFont(info: *stbtt_fontinfo, data: [*]const u8, offset: c_int) c_int;
extern fn stbtt_GetFontVMetrics(info: *const stbtt_fontinfo, ascent: *c_int, descent: *c_int, lineGap: *c_int) void;
extern fn stbtt_ScaleForPixelHeight(info: *const stbtt_fontinfo, pixels: f32) f32;
extern fn stbtt_GetCodepointHMetrics(info: *const stbtt_fontinfo, codepoint: c_int, advanceWidth: *c_int, leftSideBearing: *c_int) void;
extern fn stbtt_GetCodepointBitmapBox(info: *const stbtt_fontinfo, codepoint: c_int, scale_x: f32, scale_y: f32, ix0: *c_int, iy0: *c_int, ix1: *c_int, iy1: *c_int) void;
extern fn stbtt_MakeCodepointBitmap(info: *const stbtt_fontinfo, output: [*]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, codepoint: c_int) void;

// ---------------------------------------------------------------------
//  Fonts / glyphs / colors
// ---------------------------------------------------------------------

const FONT_PATHS = [2][]const u8{
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf",
};
const FONT_SIZE: f32 = 14.0;

const GlyphKey = struct { cp: u32, bold: bool };
const Glyph = struct { w: i32, h: i32, xoff: i32, yoff: i32, pixels: []const u8 };

const DEFAULT_FG = [3]u8{ 0xBF, 0xBF, 0xBF };
const DEFAULT_BG = [3]u8{ 0x00, 0x00, 0x00 };

// ---------------------------------------------------------------------
//  Backend state (single window, like photon's file-static renderer)
// ---------------------------------------------------------------------

const State = struct {
    win: ?*SDL_Window = null,
    fonts: [2]stbtt_fontinfo = undefined,
    fontdata: [2][]const u8 = .{ "", "" },
    scale: f32 = 0,
    ascent: i32 = 0,
    cell_w: i32 = 8,
    cell_h: i32 = 16,
    cols: u16 = 1,
    rows: u16 = 1,
    tracker: ?*rencache.Tracker = null,
    dirty: std.ArrayList(rencache.CellRect) = .empty,
    arena: std.heap.ArenaAllocator, // per-frame layout scratch
    glyphs: std.AutoHashMap(GlyphKey, Glyph),
    pipe_r: i32 = -1,
    pipe_w: i32 = -1,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    force_full: bool = true,
    can_blit: bool = false, // surface is 32bpp
};

var g: ?*State = null;

// ---------------------------------------------------------------------
//  Open / close (effectloop thread only)
// ---------------------------------------------------------------------

pub fn open(alloc: std.mem.Allocator, title: []const u8, cols: u16, rows: u16) bool {
    if (g != null) return true; // already open — one window per process
    if (SDL_Init(SDL_INIT_VIDEO) != 0) return false;

    const st = alloc.create(State) catch {
        SDL_Quit();
        return false;
    };
    st.* = .{
        .arena = std.heap.ArenaAllocator.init(alloc),
        .glyphs = std.AutoHashMap(GlyphKey, Glyph).init(alloc),
    };

    // Fonts first: cell metrics size the window (fixed-size monospace,
    // 14px DejaVu Sans Mono -> the classic 8x16 terminal cell).
    var asc: c_int = 0;
    var desc: c_int = 0;
    var gap: c_int = 0;
    var adv: c_int = 0;
    var lsb: c_int = 0;
    for (FONT_PATHS, 0..) |path, i| {
        st.fontdata[i] = readFile(alloc, path) catch {
            teardown(st);
            return false;
        };
        if (stbtt_InitFont(&st.fonts[i], st.fontdata[i].ptr, 0) != 1) {
            teardown(st);
            return false;
        }
    }
    stbtt_GetFontVMetrics(&st.fonts[0], &asc, &desc, &gap);
    stbtt_GetCodepointHMetrics(&st.fonts[0], 'M', &adv, &lsb);
    st.scale = stbtt_ScaleForPixelHeight(&st.fonts[0], FONT_SIZE);
    st.ascent = @intFromFloat(@as(f32, @floatFromInt(asc)) * st.scale);
    st.cell_w = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(adv)) * st.scale))));
    st.cell_h = @max(1, @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(asc - desc + gap)) * st.scale))));

    const titlez = alloc.dupeZ(u8, title) catch {
        teardown(st);
        return false;
    };
    st.win = SDL_CreateWindow(
        titlez.ptr,
        SDL_WINDOWPOS_CENTERED,
        SDL_WINDOWPOS_CENTERED,
        @as(c_int, cols) * st.cell_w,
        @as(c_int, rows) * st.cell_h,
        SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE,
    );
    alloc.free(titlez);
    if (st.win == null) {
        teardown(st);
        return false;
    }
    var pw: c_int = 0;
    var ph: c_int = 0;
    SDL_GetWindowSize(st.win.?, &pw, &ph);
    st.cols = @intCast(@max(1, @divTrunc(pw, st.cell_w)));
    st.rows = @intCast(@max(1, @divTrunc(ph, st.cell_h)));

    st.tracker = rencache.Tracker.init(alloc, st.cols, st.rows) catch {
        teardown(st);
        return false;
    };

    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) {
        teardown(st);
        return false;
    }
    st.pipe_r = fds[0];
    st.pipe_w = fds[1];
    setNonblocking(st.pipe_r);
    setNonblocking(st.pipe_w);

    SDL_StartTextInput();

    // The FIRST record on the pipe is the initial size: Tea's guiProgram arms
    // guiPoll before guiOpen completes, and its first delivery (GResize)
    // triggers the first paint at the real window size.
    writeRecord(st, .{ .kind = @intFromEnum(gui.EvKind.resize), .x = pw, .y = ph });

    st.running.store(true, .release);
    st.thread = std.Thread.spawn(.{}, eventThreadMain, .{st}) catch null;
    if (st.thread == null) {
        teardown(st);
        return false;
    }
    g = st;
    return true;
}

pub fn opened() bool {
    return g != null;
}

/// Read fd of the self-pipe (the effectloop polls it like stdin).
pub fn eventFd() i32 {
    return if (g) |st| st.pipe_r else -1;
}

pub fn cellDims() struct { w: i32, h: i32 } {
    if (g) |st| return .{ .w = st.cell_w, .h = st.cell_h };
    return .{ .w = 0, .h = 0 };
}

/// Current cell-grid size (effectloop maps mouse px -> cells with it).
pub fn gridSize() struct { cols: u16, rows: u16 } {
    if (g) |st| return .{ .cols = st.cols, .rows = st.rows };
    return .{ .cols = 0, .rows = 0 };
}

/// Window exposed / surface invalidated: next present repaints everything.
pub fn invalidate() void {
    if (g) |st| st.force_full = true;
}

pub fn close() void {
    if (g) |st| {
        g = null;
        teardown(st);
    }
}

/// Tear the window down.  Every piece is optional-shaped because open()'s
/// failure paths arrive mid-setup (SDL_Quit always runs: SDL_Init succeeded).
fn teardown(st: *State) void {
    st.running.store(false, .release);
    if (st.thread) |t| {
        wakeEventThread();
        t.join();
        st.thread = null;
    }
    if (st.pipe_r >= 0) _ = c.close(st.pipe_r);
    if (st.pipe_w >= 0) _ = c.close(st.pipe_w);
    if (st.win) |w| SDL_DestroyWindow(w);
    SDL_Quit();
    var it = st.glyphs.valueIterator();
    while (it.next()) |gl| if (gl.pixels.len > 0) pa.free(gl.pixels);
    st.glyphs.deinit();
    st.dirty.deinit(pa);
    if (st.tracker) |tr| tr.deinit();
    st.arena.deinit();
    for (st.fontdata) |fd| if (fd.len > 0) pa.free(fd);
    pa.destroy(st);
}

/// Push a synthetic SDL_USEREVENT so the event thread's SDL_WaitEvent returns
/// and it observes `running == false` (SDL_PushEvent is thread-safe).
fn wakeEventThread() void {
    var wake = SDL_Event{ .data = [_]u8{0} ** 56 };
    std.mem.writeInt(u32, wake.data[0..4], SDL_USEREVENT, .little);
    _ = SDL_PushEvent(&wake);
}

fn setNonblocking(fd: c_int) void {
    const fl = c.fcntl(fd, F_GETFL, @as(c_int, 0));
    if (fl < 0) return;
    _ = c.fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

// ---------------------------------------------------------------------
//  Event thread — the pipe-only SDL crossing
// ---------------------------------------------------------------------

fn eventThreadMain(st: *State) void {
    // HARD RULE (again, where it counts): this thread NEVER touches the
    // VM/GC, the tracker, the glyph cache, or the window surface — only
    // SDL_WaitEvent and one fixed-size record write to the self-pipe.  ALL
    // Value manufacture happens on the effectloop thread.
    var e: SDL_Event = undefined;
    while (st.running.load(.acquire)) {
        if (SDL_WaitEvent(&e) != 1) return; // SDL error — pipe EOF => GClose
        translateEvent(st, &e);
    }
}

fn eventType(e: *const SDL_Event) u32 {
    return @as(*align(1) const EvCommon, @ptrCast(&e.data)).type;
}

fn translateEvent(st: *State, e: *SDL_Event) void {
    switch (eventType(e)) {
        SDL_QUIT => writeRecord(st, .{ .kind = @intFromEnum(gui.EvKind.close) }),
        SDL_WINDOWEVENT => {
            const w: *align(1) const EvWindow = @ptrCast(&e.data);
            switch (w.event) {
                SDL_WINDOWEVENT_CLOSE => writeRecord(st, .{ .kind = @intFromEnum(gui.EvKind.close) }),
                SDL_WINDOWEVENT_EXPOSED => writeRecord(st, .{ .kind = @intFromEnum(gui.EvKind.expose) }),
                SDL_WINDOWEVENT_SIZE_CHANGED, SDL_WINDOWEVENT_RESIZED => writeRecord(st, .{
                    .kind = @intFromEnum(gui.EvKind.resize),
                    .x = w.data1,
                    .y = w.data2,
                }),
                else => {},
            }
        },
        SDL_KEYDOWN => {
            const k: *align(1) const EvKey = @ptrCast(&e.data);
            if (k.repeat != 0) return;
            writeRecord(st, .{
                .kind = @intFromEnum(gui.EvKind.key_down),
                .scancode = @bitCast(k.keysym.scancode),
                .ctrl = if (k.keysym.mod & KMOD_CTRL != 0) 1 else 0,
            });
        },
        SDL_TEXTINPUT => {
            // One record per rune (a paste reports a whole string; records
            // carry one rune so nothing is truncated mid-rune).
            const t: *align(1) const EvText = @ptrCast(&e.data);
            var i: usize = 0;
            while (i < t.text.len and t.text[i] != 0) {
                const r = gui.nextRune(t.text[0..], i);
                if (r.len == 0) break;
                var rec = gui.EvRecord{ .kind = @intFromEnum(gui.EvKind.text) };
                const n = @min(r.len, rec.text.len);
                @memcpy(rec.text[0..n], t.text[i..][0..n]);
                rec.text_len = @intCast(n);
                writeRecord(st, rec);
                i += r.len;
            }
        },
        SDL_MOUSEMOTION => {
            const m: *align(1) const EvMotion = @ptrCast(&e.data);
            writeRecord(st, .{
                .kind = @intFromEnum(gui.EvKind.mouse),
                .act = @intFromEnum(gui.RecMouseAct.motion),
                .x = m.x,
                .y = m.y,
            });
        },
        SDL_MOUSEBUTTONDOWN, SDL_MOUSEBUTTONUP => {
            const b: *align(1) const EvButton = @ptrCast(&e.data);
            const act: gui.RecMouseAct = if (b.type == SDL_MOUSEBUTTONDOWN) .press else .release;
            writeRecord(st, .{
                .kind = @intFromEnum(gui.EvKind.mouse),
                .act = @intFromEnum(act),
                .button = b.button,
                .x = b.x,
                .y = b.y,
            });
        },
        SDL_MOUSEWHEEL => {
            // SDL wheel events carry no position — x/y stay 0 (the app sees
            // the wheel at cell 0,0; terminal SGR wheels carry position but
            // nothing in the corpus reads wheel position).
            const w: *align(1) const EvWheel = @ptrCast(&e.data);
            writeRecord(st, .{
                .kind = @intFromEnum(gui.EvKind.wheel),
                .button = if (w.y > 0) 0 else 1, // 0 = wheel up, 1 = wheel down
            });
        },
        else => {},
    }
}

fn writeRecord(st: *State, rec: gui.EvRecord) void {
    const bytes = std.mem.asBytes(&rec);
    _ = c.write(st.pipe_w, bytes.ptr, bytes.len); // EAGAIN (pipe full) drops
}

// ---------------------------------------------------------------------
//  Present (effectloop thread only)
// ---------------------------------------------------------------------

pub fn present(frame: []const []const gui.Span) void {
    const st = g orelse return;
    const tracker = st.tracker orelse return;
    const surf = SDL_GetWindowSurface(st.win.?) orelse return;
    st.can_blit = surf.format.BitsPerPixel == 32;

    // Sync the grid to the actual surface size (a resize => tracker reset =>
    // full repaint — rencache.resize semantics).
    const cols: u16 = @intCast(@max(1, @divTrunc(surf.w, st.cell_w)));
    const rows: u16 = @intCast(@max(1, @divTrunc(surf.h, st.cell_h)));
    if (cols != st.cols or rows != st.rows) {
        st.cols = cols;
        st.rows = rows;
        tracker.resize(cols, rows);
        st.force_full = true;
    }

    _ = st.arena.reset(.retain_capacity);
    const grid = gui.layoutFrame(st.arena.allocator(), frame, cols, rows) catch return;

    // Damage pass: hash every cell into the tracker; endFrame diffs against
    // the previous frame and reports only what changed.
    tracker.beginFrame();
    var y: u16 = 0;
    while (y < rows) : (y += 1) {
        var x: u16 = 0;
        while (x < cols) : (x += 1) {
            const cell = grid.cells[@as(usize, y) * cols + x];
            tracker.touch(.{ .x = x, .y = y, .w = 1, .h = 1 }, gui.hashCell(cell));
        }
    }
    tracker.endFrame(&st.dirty);

    // Draw pass: full (expose/resize/first) or dirty rects only.
    var rects: [64]SDL_Rect = undefined;
    var nrects: usize = 0;
    if (st.force_full) {
        st.force_full = false;
        drawCells(st, surf, .{ .x = 0, .y = 0, .w = cols, .h = rows }, grid);
        rects[0] = .{ .x = 0, .y = 0, .w = surf.w, .h = surf.h };
        nrects = 1;
    } else {
        for (st.dirty.items) |r| {
            if (nrects >= rects.len) break;
            drawCells(st, surf, r, grid);
            rects[nrects] = .{
                .x = @as(c_int, r.x) * st.cell_w,
                .y = @as(c_int, r.y) * st.cell_h,
                .w = @as(c_int, r.w) * st.cell_w,
                .h = @as(c_int, r.h) * st.cell_h,
            };
            nrects += 1;
        }
    }
    if (nrects > 0) _ = SDL_UpdateWindowSurfaceRects(st.win.?, &rects, @intCast(nrects));
}

/// bg fill + glyph for every cell in `r` (the photon DrawRect/DrawText pair,
/// in cell units — the SDL_Rect clip of the dirty rect is the SetClip).
fn drawCells(st: *State, surf: *SDL_Surface, r: rencache.CellRect, grid: gui.Grid) void {
    const x1 = @min(@as(u32, r.x) + r.w, grid.cols);
    const y1 = @min(@as(u32, r.y) + r.h, grid.rows);
    var y: u32 = r.y;
    while (y < y1) : (y += 1) {
        var x: u32 = r.x;
        while (x < x1) : (x += 1) {
            const cell = grid.cells[y * grid.cols + x];
            drawCell(st, surf, @intCast(x), @intCast(y), cell);
        }
    }
}

fn drawCell(st: *State, surf: *SDL_Surface, x: u16, y: u16, cell: gui.Cell) void {
    var fg = gui.colorOf(cell.fg, DEFAULT_FG);
    var bg = gui.colorOf(cell.bg, DEFAULT_BG);
    if (cell.attrs & gui.ATTR_REVERSE != 0) {
        const t = fg;
        fg = bg;
        bg = t;
    }
    const px: i32 = @as(i32, x) * st.cell_w;
    const py: i32 = @as(i32, y) * st.cell_h;
    const rect = SDL_Rect{ .x = px, .y = py, .w = st.cell_w, .h = st.cell_h };
    _ = SDL_FillRect(surf, &rect, SDL_MapRGB(surf.format, bg[0], bg[1], bg[2]));

    if (cell.len == 0 or cell.skip or !st.can_blit) return;
    const ru = gui.nextRune(cell.bytes[0..], 0);
    const glyph = getGlyph(st, ru.cp, cell.attrs & gui.ATTR_BOLD != 0) orelse return;
    if (glyph.w <= 0 or glyph.h <= 0) return;

    const faint = cell.attrs & gui.ATTR_FAINT != 0;
    blitGlyph(surf, glyph, px + glyph.xoff, py + st.ascent + glyph.yoff, fg, faint);

    if (cell.attrs & gui.ATTR_UNDERLINE != 0) {
        const bar = SDL_Rect{ .x = px, .y = py + st.ascent + 1, .w = st.cell_w, .h = 1 };
        _ = SDL_FillRect(surf, &bar, SDL_MapRGB(surf.format, fg[0], fg[1], fg[2]));
    }
    if (cell.attrs & gui.ATTR_STRIKE != 0) {
        const bar = SDL_Rect{ .x = px, .y = py + @divTrunc(st.ascent, 2), .w = st.cell_w, .h = 1 };
        _ = SDL_FillRect(surf, &bar, SDL_MapRGB(surf.format, fg[0], fg[1], fg[2]));
    }
    // ATTR_BLINK / ATTR_ITALIC are carried but not rendered (blink needs a
    // tick clock; stb does no italic synthesis).
}

/// Alpha-blend an 8-bit coverage glyph into the 32bpp surface with `fg`
/// (the surface has no alpha channel — straight coverage blend over the bg
/// fill that is already there).
fn blitGlyph(surf: *SDL_Surface, gl: Glyph, x0: i32, y0: i32, fg: [3]u8, faint: bool) void {
    if (surf.format.BytesPerPixel != 4) return;
    const base = @intFromPtr(surf.pixels);
    const row_bytes: usize = @intCast(surf.pitch);
    var gy: i32 = 0;
    while (gy < gl.h) : (gy += 1) {
        const sy = y0 + gy;
        if (sy < 0 or sy >= surf.h) continue;
        var gx: i32 = 0;
        while (gx < gl.w) : (gx += 1) {
            const sx = x0 + gx;
            if (sx < 0 or sx >= surf.w) continue;
            var a: u32 = gl.pixels[@intCast(gy * gl.w + gx)];
            if (faint) a = a * 128 / 256;
            if (a == 0) continue;
            const dst: *u32 = @ptrFromInt(base + @as(usize, @intCast(sy)) * row_bytes + @as(usize, @intCast(sx)) * 4);
            const dr: u32 = (dst.* >> @intCast(surf.format.Rshift)) & 0xFF;
            const dg: u32 = (dst.* >> @intCast(surf.format.Gshift)) & 0xFF;
            const db: u32 = (dst.* >> @intCast(surf.format.Bshift)) & 0xFF;
            const out_r = (dr * (255 - a) + @as(u32, fg[0]) * a) / 255;
            const out_g = (dg * (255 - a) + @as(u32, fg[1]) * a) / 255;
            const out_b = (db * (255 - a) + @as(u32, fg[2]) * a) / 255;
            dst.* = (out_r << @intCast(surf.format.Rshift)) |
                (out_g << @intCast(surf.format.Gshift)) |
                (out_b << @intCast(surf.format.Bshift));
        }
    }
}

fn getGlyph(st: *State, cp: u21, bold: bool) ?Glyph {
    const key = GlyphKey{ .cp = cp, .bold = bold };
    if (st.glyphs.get(key)) |gl| return gl;
    const font = &st.fonts[if (bold) 1 else 0];
    var x0: c_int = 0;
    var y0: c_int = 0;
    var x1: c_int = 0;
    var y1: c_int = 0;
    stbtt_GetCodepointBitmapBox(font, cp, st.scale, st.scale, &x0, &y0, &x1, &y1);
    const w = x1 - x0;
    const h = y1 - y0;
    if (w <= 0 or h <= 0) {
        // Blank glyph (space, unmapped cp): remember it so the cache absorbs
        // repeats instead of re-probing the font every frame.
        st.glyphs.put(key, .{ .w = 0, .h = 0, .xoff = 0, .yoff = 0, .pixels = "" }) catch {};
        return st.glyphs.get(key);
    }
    // Page-allocator (NOT the frame arena — that resets every present, which
    // would dangle every cached glyph after one frame).
    const pixels = pa.alloc(u8, @intCast(w * h)) catch return null;
    stbtt_MakeCodepointBitmap(font, pixels.ptr, w, h, w, st.scale, st.scale, cp);
    const gl = Glyph{ .w = w, .h = h, .xoff = x0, .yoff = y0, .pixels = pixels };
    st.glyphs.put(key, gl) catch return null;
    return gl;
}

// ---------------------------------------------------------------------
//  Misc
// ---------------------------------------------------------------------

fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const fd = try posix.openat(posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = c.close(fd);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);
    var tmp: [16384]u8 = undefined;
    while (true) {
        const n = posix.read(fd, &tmp) catch break;
        if (n == 0) break;
        try buf.appendSlice(alloc, tmp[0..n]);
    }
    return try buf.toOwnedSlice(alloc);
}
