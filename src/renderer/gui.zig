//! SDL-free pure logic for the P2 GUI backend (photon-gui plan item 10).
//!
//! Everything here is headless-unit-testable: NO SDL, NO vm/gc imports.  The
//! SDL half of the backend lives in gui_sdl.zig (compiled only under
//! -Dgui=true); gui_stub.zig is the default-build stand-in.  The pure parts:
//!
//!   * Frame->cell-grid layout (layoutFrame): walks decoded Span rows with the
//!     width.zig runewidth tables (the codegen-gated Elm/Zig parity tables),
//!     placing one rune per cell, clipping at `cols`, marking wide-rune
//!     continuation cells, folding zero-width runes into the previous cell.
//!   * keymap (mapKey): SDL scancode -> Runtime.Key ctor name (the ctor
//!     spellings at elm-compiler/src/Runtime.elm:55-77 are the contract).
//!   * text-input dedup (filterTextInput): named-key scancodes already emit
//!     their Key event, so the duplicate \r/\n/\t/\b text bytes SDL also
//!     reports for those keys are dropped here.
//!   * pxToCell: mouse/window pixel position -> terminal cell.
//!   * EvRecord: the FIXED-SIZE event record the SDL event thread writes to
//!     the self-pipe (see gui_sdl.zig for the HARD threading rule).
//!   * colorOf: packed Lipgloss color int -> RGB (xterm-256 palette + RGB24).
//!   * hashCell: per-cell content hash fed to rencache.Tracker.touch.
//!
//! Color packing contract (elm-compiler/core-libs/Draw.elm:70-101, matching
//! Lipgloss.Color): -1 = none, 0..255 = palette, 0x1000000 bor RGB24.
//! Attribute bits (Draw.elm:104-126): bold 1, faint 2, italic 4, underline 8,
//! blink 16, reverse 32, strikethrough 64 — one bit per SGR code.

const std = @import("std");
const width = @import("width.zig");

// ---------------------------------------------------------------------
//  Span / Cell / Grid — the decoded Frame (plain Zig, no VM values)
// ---------------------------------------------------------------------

/// One decoded span: the host-side image of Draw.Span
/// (Span String Int Int Int) — text carries no escapes and no newline.
pub const Span = struct {
    text: []const u8,
    fg: i64 = -1,
    bg: i64 = -1,
    attrs: i64 = 0,
};

/// One placed terminal cell.  `len == 0` is a blank/skip cell (no rune);
/// `skip` marks the continuation cell of a double-width rune.
pub const Cell = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 }, // one UTF-8 rune (at most 4 bytes)
    len: u8 = 0,
    skip: bool = false, // second cell of a wide rune (never drawn)
    fg: i64 = -1,
    bg: i64 = -1,
    attrs: i64 = 0,
};

pub const Grid = struct {
    cols: u16,
    rows: u16,
    cells: []Cell, // rows * cols, row-major
};

/// Place decoded span rows onto a cols x rows cell grid.  Rows past the
/// frame's end and columns past `cols` are clipped (blank cells); a span
/// never straddles the cut (the wide-rune rule: if it does not fit whole,
/// it is not placed).  Escapes in span text are defensive — Draw.fromAnsi
/// strips them, but a hand-built Span could carry one, so the walk skips
/// them (zero-width) exactly like width.strWidth.
pub fn layoutFrame(alloc: std.mem.Allocator, frame: []const []const Span, cols: u16, rows: u16) !Grid {
    const cells = try alloc.alloc(Cell, @as(usize, cols) * rows);
    @memset(cells, Cell{});
    var row_i: usize = 0;
    while (row_i < frame.len and row_i < rows) : (row_i += 1) {
        var col: usize = 0;
        for (frame[row_i]) |span| {
            var i: usize = 0;
            while (i < span.text.len) {
                if (span.text[i] == 27) { // ESC — skip the whole sequence
                    i = skipEsc(span.text, i);
                    continue;
                }
                const r = nextRune(span.text, i);
                i += r.len;
                const cw = width.runeWidth(r.cp);
                if (cw == 0) {
                    // Zero-width rune (combining mark / control): fold into
                    // the previous placed cell if its bytes still fit, else
                    // drop it (terminal behavior for a lone combining mark).
                    if (col > 0) {
                        const pc = &cells[row_i * cols + (col - 1)];
                        if (!pc.skip and pc.len > 0 and pc.len + r.len <= 4) {
                            @memcpy(pc.bytes[pc.len..][0..r.len], span.text[i - r.len ..][0..r.len]);
                            pc.len += @intCast(r.len);
                        }
                    }
                    continue;
                }
                if (col + cw > cols) break; // clip the span at the grid edge
                const c = &cells[row_i * cols + col];
                const n = @min(r.len, 4);
                @memset(&c.bytes, 0);
                @memcpy(c.bytes[0..n], span.text[i - r.len ..][0..n]);
                c.len = @intCast(n);
                c.fg = span.fg;
                c.bg = span.bg;
                c.attrs = span.attrs;
                if (cw == 2) {
                    c.skip = false;
                    const cont = &cells[row_i * cols + col + 1];
                    cont.skip = true;
                    cont.len = 0;
                    cont.bg = span.bg; // the wide rune's bg paints both cells
                }
                col += cw;
            }
        }
    }
    return .{ .cols = cols, .rows = rows, .cells = cells };
}

/// 64-bit fnv-1a over a cell's content — the content hash rencache.touch
/// consumes (the same combine mechanics as rencache.zig's hashCombine).
pub fn hashCell(c: Cell) u64 {
    var h: u64 = 14695981039346656037;
    hashBytes(&h, &.{ c.len, @intFromBool(c.skip) });
    hashBytes(&h, c.bytes[0..]);
    hashBytes(&h, std.mem.asBytes(&c.fg));
    hashBytes(&h, std.mem.asBytes(&c.bg));
    hashBytes(&h, std.mem.asBytes(&c.attrs));
    return h;
}

fn hashBytes(h: *u64, bytes: []const u8) void {
    for (bytes) |b| h.* = (h.* ^ b) *% 1099511628211;
}

// ---------------------------------------------------------------------
//  Keymap: SDL scancode -> Runtime.Key ctor name
// ---------------------------------------------------------------------

/// The result of mapping one SDL key event: either a 0-ary Runtime.Key ctor
/// NAME (host builds vector[tag=name]) or a KeyCtrl payload byte.  Printable
/// characters are NOT mapped here — they arrive as SDL_TEXTINPUT records
/// (filterTextInput dedups the named-key duplicates).
pub const KeyDesc = union(enum) {
    named: []const u8,
    ctrl: u8,
};

/// SDL scancode constants (ABI-stable, SDL_scancode.h; verified against
/// SDL 2.32.72): letters A..Z = 4..29, digits 1..0 = 30..39.
pub const SCAN_A: u32 = 4;
pub const SCAN_C: u32 = 6;
pub const SCAN_Q: u32 = 20;
pub const SCAN_Z: u32 = 29;
pub const SCAN_1: u32 = 30;
pub const SCAN_0: u32 = 39;
pub const SCAN_RETURN: u32 = 40;
pub const SCAN_ESCAPE: u32 = 41;
pub const SCAN_BACKSPACE: u32 = 42;
pub const SCAN_TAB: u32 = 43;
pub const SCAN_INSERT: u32 = 73;
pub const SCAN_HOME: u32 = 74;
pub const SCAN_PAGEUP: u32 = 75;
pub const SCAN_DELETE: u32 = 76;
pub const SCAN_END: u32 = 77;
pub const SCAN_PAGEDOWN: u32 = 78;
pub const SCAN_RIGHT: u32 = 79;
pub const SCAN_LEFT: u32 = 80;
pub const SCAN_DOWN: u32 = 81;
pub const SCAN_UP: u32 = 82;

/// Map one SDL key-down.  `ctrl` is the SDL KMOD_CTRL mask test result.
/// Ctrl+letter maps to the terminal control byte (letter & 0x1F — what the
/// terminal decoder produces and Tea's KeyCtrl payload carries).  Returns
/// null for keys with no Runtime.Key analogue (printables ride textinput,
/// F-keys/media are dropped).
pub fn mapKey(scancode: u32, ctrl: bool) ?KeyDesc {
    if (ctrl and scancode >= SCAN_A and scancode <= SCAN_Z) {
        const letter: u8 = @intCast('a' + (scancode - SCAN_A));
        return .{ .ctrl = letter & 0x1F };
    }
    return switch (scancode) {
        SCAN_RETURN => .{ .named = "KeyEnter" },
        SCAN_ESCAPE => .{ .named = "KeyEsc" },
        SCAN_BACKSPACE => .{ .named = "KeyBackspace" },
        SCAN_TAB => .{ .named = "KeyTab" },
        SCAN_UP => .{ .named = "KeyUp" },
        SCAN_DOWN => .{ .named = "KeyDown" },
        SCAN_LEFT => .{ .named = "KeyLeft" },
        SCAN_RIGHT => .{ .named = "KeyRight" },
        SCAN_HOME => .{ .named = "KeyHome" },
        SCAN_END => .{ .named = "KeyEnd" },
        SCAN_PAGEUP => .{ .named = "KeyPgUp" },
        SCAN_PAGEDOWN => .{ .named = "KeyPgDn" },
        SCAN_INSERT => .{ .named = "KeyIns" },
        SCAN_DELETE => .{ .named = "KeyDel" },
        else => null,
    };
}

/// SDL_TEXTINPUT bytes -> the KeyChar payload, or null when the text is one
/// of the bytes a named-key scancode already reported (\r \n \t \b DEL) —
/// SDL emits textinput for those keys too, and delivering both would double
/// every Enter/Tab/Backspace.
pub fn filterTextInput(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    if (text.len == 1) {
        const b = text[0];
        if (b == '\r' or b == '\n' or b == '\t' or b == 8 or b == 127) return null;
    }
    return text;
}

// ---------------------------------------------------------------------
//  Pixel -> cell mapping
// ---------------------------------------------------------------------

pub const CellPos = struct { c: u16, r: u16 };

/// Mouse/window px -> terminal cell, clamped to the grid.
pub fn pxToCell(x: i32, y: i32, cell_w: i32, cell_h: i32, cols: u16, rows: u16) CellPos {
    const cw: i32 = if (cell_w <= 0) 1 else cell_w;
    const ch: i32 = if (cell_h <= 0) 1 else cell_h;
    const cx = @divFloor(@max(x, 0), cw);
    const cy = @divFloor(@max(y, 0), ch);
    return .{
        .c = @intCast(@min(cx, @as(i32, cols) - 1)),
        .r = @intCast(@min(cy, @as(i32, rows) - 1)),
    };
}

// ---------------------------------------------------------------------
//  EvRecord — the self-pipe crossing (SDL thread -> effectloop thread)
// ---------------------------------------------------------------------

/// HARD RULE (the whole point of the record): the SDL event thread NEVER
/// touches the VM/GC — it translates SDL_Events into these fixed-size
/// records and write(2)s them to the self-pipe; ALL Value manufacture
/// happens on the effectloop thread (src/effectloop.zig leafGuiPoll).
/// 24 bytes, far under PIPE_BUF, so each write is atomic.
pub const EvKind = enum(u8) {
    none = 0,
    key_down = 1, // scancode + ctrl
    text = 2, // text[0..text_len] (ONE rune)
    mouse = 3, // act/button + px x/y
    wheel = 4, // button 0=up 1=down + px x/y
    resize = 5, // px x/y = new window w/h
    expose = 6, // window needs a full repaint
    close = 7, // window close / SDL_QUIT
};

/// Mouse action codes inside EvRecord (effectloop maps them to the
/// Runtime.MouseAction ctor names press/release/motion/wheel).
pub const RecMouseAct = enum(u8) { press = 0, release = 1, motion = 2 };

pub const EvRecord = extern struct {
    kind: u8 = 0, // EvKind
    ctrl: u8 = 0, // key_down: KMOD_CTRL test
    act: u8 = 0, // mouse: RecMouseAct
    button: u8 = 0, // mouse: SDL button id; wheel: 0=up 1=down
    scancode: u32 = 0, // key_down
    text: [4]u8 = .{ 0, 0, 0, 0 }, // text: one UTF-8 rune
    text_len: u8 = 0,
    x: i32 = 0, // mouse px / resize: window w
    y: i32 = 0, // mouse px / resize: window h
};

comptime {
    if (@sizeOf(EvRecord) != 24) @compileError("EvRecord must stay 24 bytes (pipe crossing)");
}

// ---------------------------------------------------------------------
//  Colors — packed Lipgloss int -> RGB24
// ---------------------------------------------------------------------

/// xterm base-16 palette (indices 0..15) — the classic VGA defaults.
const base16 = [16][3]u8{
    .{ 0x00, 0x00, 0x00 }, .{ 0xcd, 0x00, 0x00 }, .{ 0x00, 0xcd, 0x00 }, .{ 0xcd, 0xcd, 0x00 },
    .{ 0x00, 0x00, 0xee }, .{ 0xcd, 0x00, 0xcd }, .{ 0x00, 0xcd, 0xcd }, .{ 0xe5, 0xe5, 0xe5 },
    .{ 0x7f, 0x7f, 0x7f }, .{ 0xff, 0x00, 0x00 }, .{ 0x00, 0xff, 0x00 }, .{ 0xff, 0xff, 0x00 },
    .{ 0x5c, 0x5c, 0xff }, .{ 0xff, 0x00, 0xff }, .{ 0x00, 0xff, 0xff }, .{ 0xff, 0xff, 0xff },
};

/// Packed color int (Draw.elm:70-101 contract) -> RGB.  `def` is the
/// terminal default (fg or bg) used for colorNo (-1).
pub fn colorOf(packed_: i64, def: [3]u8) [3]u8 {
    if (packed_ < 0) return def;
    if (packed_ < 16) return base16[@intCast(packed_)];
    if (packed_ < 232) {
        // 6x6x6 color cube, levels 0x00 0x5f 0x87 0xaf 0xd7 0xff
        const idx: u32 = @intCast(packed_ - 16);
        const lv = [6]u8{ 0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff };
        return .{
            lv[(idx / 36) % 6],
            lv[(idx / 6) % 6],
            lv[idx % 6],
        };
    }
    if (packed_ < 256) {
        // 24-step grayscale ramp 8..238
        const g: u8 = @intCast(8 + (packed_ - 232) * 10);
        return .{ g, g, g };
    }
    const rgb: u32 = @intCast(packed_ - 0x1000000);
    return .{
        @truncate(rgb >> 16),
        @truncate(rgb >> 8),
        @truncate(rgb),
    };
}

/// Attribute bits (Draw.elm:104-126 — one bit per SGR code).
pub const ATTR_BOLD: i64 = 1;
pub const ATTR_FAINT: i64 = 2;
pub const ATTR_ITALIC: i64 = 4;
pub const ATTR_UNDERLINE: i64 = 8;
pub const ATTR_BLINK: i64 = 16;
pub const ATTR_REVERSE: i64 = 32;
pub const ATTR_STRIKE: i64 = 64;

// ---------------------------------------------------------------------
//  Local rune walk (width.zig internals are file-private; these mirror
//  width.decodeRune/runeNeed/skipAnsi line for line — see the cites)
// ---------------------------------------------------------------------

const Rune = struct { cp: u21, len: usize };

/// One UTF-8 rune at s[i], folding continuation bytes with no validation
/// (mirrors width.zig decodeRune, itself the Str.elm:211-233 walk).  Public:
/// gui_sdl.zig decodes cell bytes for glyph lookup.
pub fn nextRune(s: []const u8, i: usize) Rune {
    const c = s[i];
    var cp: u32 = switch (c) {
        0xC0...0xDF => c & 31,
        0xE0...0xEF => c & 15,
        0xF0...0xFF => c & 7,
        else => c,
    };
    var j = i + 1;
    var k = runeNeed(c);
    while (k > 0) : (k -= 1) {
        const b: u32 = if (j < s.len) s[j] else 0x3F;
        cp = cp * 64 + (b & 63);
        j += 1;
    }
    return .{ .cp = @intCast(@min(cp, 0x1FFFFF)), .len = 1 + runeNeed(c) };
}

/// width.zig runeNeed: continuation bytes after lead byte c.
fn runeNeed(c: u8) usize {
    if (c < 192) return 0;
    if (c < 224) return 1;
    if (c < 240) return 2;
    return 3;
}

/// width.zig skipAnsi: index after the escape sequence starting at the ESC.
fn skipEsc(s: []const u8, i: usize) usize {
    const c1: u32 = if (i + 1 < s.len) s[i + 1] else 0xFFFF;
    if (c1 == 91) { // '[' CSI
        var k = i + 2;
        while (k < s.len) : (k += 1) {
            if (s[k] >= 0x40 and s[k] <= 0x7E) return k + 1;
        }
        return k;
    }
    if (c1 == 93) { // ']' OSC
        var k = i + 2;
        while (k < s.len) : (k += 1) {
            if (s[k] == 7 or s[k] == 27) return k + 1;
        }
        return k;
    }
    return i + 2;
}
