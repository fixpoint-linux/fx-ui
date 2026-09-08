//! P4 host TerminalRenderer — the host twin of the Elm-side paint path
//! (elm-compiler/core-libs/Tea.elm:512-629), fed DECODED Frames
//! ([]const []const gui.Span — the same shape leafRender hands the GUI
//! backend) instead of pre-rendered ANSI rows.
//!
//! Byte contract: for a Tea terminal program whose view rows are the strings
//! `view`, the bytes this renderer emits for the Frame
//! `Draw.fromAnsi view` are IDENTICAL to what Tea.paint/diffString emitted
//! for `view` directly — pinned end-to-end by the pty fixtures
//! (tests/elm-fixtures/run-elm-gate.sh) and unit-pinned here against
//! hand-written expected strings.
//!
//! Two halves:
//!
//!  * ANSI ENCODER (encodeRow): one row of spans -> its styled-ANSI string.
//!    Span text is emitted bare for a default-style span (Lipgloss's `sgr`
//!    returns the body unchanged when a style has no params,
//!    Lipgloss.elm:949-955) and as ONE `\e[<params>m text \e[0m` piece per
//!    styled span — the piece grammar every Lipgloss emitter produces
//!    (teParamsOf text runs, spaceParamsOf/wsParamsOf space runs, border
//!    sgr, per-rune styleRunes).  Params are emitted in teParamsOf order
//!    (Lipgloss.elm:1020-1052): attrs bold,italic,underline,reverse,blink,
//!    faint then fg then bg then the DUPLICATED underline then
//!    strikethrough — byte-parity with the v1.1.0 duplicate underline-4
//!    (Lipgloss.elm:104,1040).  Colors decode as Lipgloss fgSeq/bgSeq
//!    (Lipgloss.elm:958-995): 0..7 = 30/40+n, 8..15 = 90/100+(n-8),
//!    16..255 = 38;5;n, packed RGB = 38;2;r;g;b.
//!
//!  * DIFF/PAINT (TerminalRenderer.render): rencache-style PER-ROW damage —
//!    a row is dirty iff its ENCODED form changed (any text or style byte) —
//!    driving Tea's exact escape vocabulary: FIRST paint =
//!    enterAltScreen + hideCursor + clear-line + row + \r\n per row
//!    (Tea.paint, Tea.elm:530-535); REPAINT = per-row diff with absolute
//!    addressing (\e[row;1H + \e[2K + row, Tea.paintAt Tea.elm:606-607),
//!    NOTHING for unchanged rows, full paintAt for new rows (Tea.paintRest
//!    Tea.elm:579-585), and on shrink \e[<n+1>;1H + \e[J (Tea.elm:539-548).
//!
//! Pure Zig: no SDL, no vm/gc imports; the allocator is chosen by the
//! caller.  Headless-unit-tested in terminal_test.zig.

const std = @import("std");
const gui = @import("gui_model");

pub const Span = gui.Span;

/// Tea.elm:614 — newline (first paint advances the cursor row by row).
pub const newline = "\r\n";

/// Tea.elm:616 — clearLine (\e[2K).
pub const clear_line = "\x1b[2K";

/// Tea.elm:618 — clearRest (\e[J): wipes everything below the cursor.
pub const clear_rest = "\x1b[J";

/// Tea.elm:620/622 — hide/show cursor.
pub const hide_cursor = "\x1b[?25l";
pub const show_cursor = "\x1b[?25h";

/// Tea.elm:629/631 — alternate-screen entry/exit (the mosh local-echo fix).
pub const enter_alt_screen = "\x1b[?1049h";
pub const leave_alt_screen = "\x1b[?1049l";

/// Tea.elm:610 — moveTo row: absolute cursor addressing (\e[row;1H).
fn appendMoveTo(w: *std.Io.Writer, row: usize) !void {
    try w.print("\x1b[{d};1H", .{row});
}

/// Color "none" (Draw.colorNo / Lipgloss ColorNo, packed -1).
const color_none: i64 = -1;

/// Packed RGB24 base (Draw.packRgb: 0x1000000 bor RGB24).
const rgb_base: i64 = 0x1000000;

/// Draw.attrLogClear (elm-compiler/core-libs/Draw.elm): a marker span's
/// attrs pack `4096 | sgr_code` (22..29) for a raw attr-clear replay.
const attr_log_clear: i64 = 4096;

// ====================== ANSI encoder ======================

/// Encode one row as its styled-ANSI byte form.  Two modes, distinguished
/// per row by the presence of a MARKER span (empty text — only
/// Draw.fromAnsiLog produces them):
///
///  * PIECE mode (no markers — plain fromAnsi/toAnsi/hand frames): every
///    non-default span is ONE `\e[<params>m<text>\e[0m` piece (adjacent
///    same-style pieces stay separate) and default spans are bare text.
///
///  * REPLAY mode (fromAnsiLog): markers replay their SGR EVENT verbatim
///    (params in teParamsOf order; the default marker is the reset the
///    event was; attr-clear markers re-emit their code) and text spans are
///    BARE — the pen is fully managed by the event log.  This reproduces
///    the exact byte stream, stacked nested prefixes and stacked trailing
///    resets included.
pub fn encodeRow(alloc: std.mem.Allocator, row: []const Span) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    const replay = hasMarker(row);
    for (row) |span| {
        if (span.text.len == 0) {
            if (span.attrs & attr_log_clear != 0) {
                const code = span.attrs & 0xFF;
                if (code == 0) {
                    // bare attrLogClear = `\e[m` (the wrap machine's
                    // ResetStyle — never replayed as `\e[0m`)
                    try w.writeAll("\x1b[m");
                } else {
                    try w.print("\x1b[{d}m", .{code});
                }
            } else if (span.fg == color_none and span.bg == color_none and span.attrs == 0) {
                try w.writeAll(reset);
            } else {
                try appendSgrPrefix(w, span.fg, span.bg, span.attrs);
            }
        } else if (replay) {
            try w.writeAll(span.text);
        } else if (span.fg == color_none and span.bg == color_none and span.attrs == 0) {
            try w.writeAll(span.text);
        } else {
            try appendSgrPrefix(w, span.fg, span.bg, span.attrs);
            try w.writeAll(span.text);
            try w.writeAll(reset);
        }
    }
    return aw.toOwnedSlice();
}

fn hasMarker(row: []const Span) bool {
    for (row) |span| {
        if (span.text.len == 0) return true;
    }
    return false;
}

/// Lipgloss.elm:939 — sgr's piece terminator.
const reset = "\x1b[0m";

/// Emit `\e[<params>m` — teParamsOf byte order (Lipgloss.elm:1020-1052):
/// attrs 1,3,4,7,5,2 then fg then bg then the duplicated 4 then 9.
fn appendSgrPrefix(w: *std.Io.Writer, fg: i64, bg: i64, attrs: i64) !void {
    try w.writeAll("\x1b[");
    var first = true;
    if (attrs & gui.ATTR_BOLD != 0) try param(w, &first, "1");
    if (attrs & gui.ATTR_ITALIC != 0) try param(w, &first, "3");
    if (attrs & gui.ATTR_UNDERLINE != 0) try param(w, &first, "4");
    if (attrs & gui.ATTR_REVERSE != 0) try param(w, &first, "7");
    if (attrs & gui.ATTR_BLINK != 0) try param(w, &first, "5");
    if (attrs & gui.ATTR_FAINT != 0) try param(w, &first, "2");
    if (fg != color_none) try appendColor(w, &first, fg, 30, 90, "38");
    if (bg != color_none) try appendColor(w, &first, bg, 40, 100, "48");
    if (attrs & gui.ATTR_UNDERLINE != 0) try param(w, &first, "4");
    if (attrs & gui.ATTR_STRIKE != 0) try param(w, &first, "9");
    try w.writeAll("m");
}

/// The ';' separator between SGR params (none before the first).
fn sep(w: *std.Io.Writer, first: *bool) !void {
    if (!first.*) try w.writeAll(";");
    first.* = false;
}

fn param(w: *std.Io.Writer, first: *bool, s: []const u8) !void {
    try sep(w, first);
    try w.writeAll(s);
}

/// Lipgloss ansiColorSeq/fgSeq/bgSeq parity (Lipgloss.elm:958-995):
/// 0..7 = low+n, 8..15 = hi+(n-8), 16..255 = ext;5;n, packed RGB =
/// ext;2;r;g;b.  A negative value emits nothing (guarded by callers; kept
/// defensive for hand-built spans).
fn appendColor(w: *std.Io.Writer, first: *bool, c: i64, low: i64, hi: i64, ext: []const u8) !void {
    if (c < 0) return;
    if (c < 8) {
        try sep(w, first);
        try w.print("{d}", .{low + c});
    } else if (c < 16) {
        try sep(w, first);
        try w.print("{d}", .{hi + (c - 8)});
    } else if (c < 256) {
        try sep(w, first);
        try w.print("{s};5;{d}", .{ ext, c });
    } else if (c >= rgb_base) {
        const rgb = c - rgb_base;
        try sep(w, first);
        try w.print("{s};2;{d};{d};{d}", .{ ext, (rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF });
    }
}

// ====================== diff/paint renderer ======================

/// The host-side twin of Tea's painter state: the previous frame's ENCODED
/// rows (per-row damage cache — a row is rewritten iff its encoded bytes
/// changed) and the first-paint latch (Tea.paint's `prev == []` branch).
pub const TerminalRenderer = struct {
    alloc: std.mem.Allocator,
    /// Previous frame's encoded rows (each owned by `alloc`).
    prev: std.ArrayListUnmanaged([]const u8) = .empty,
    painted: bool = false,

    pub fn init(alloc: std.mem.Allocator) TerminalRenderer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *TerminalRenderer) void {
        for (self.prev.items) |r| self.alloc.free(r);
        self.prev.deinit(self.alloc);
    }

    /// Render one decoded Frame to `w` — byte-identical to Tea.paint's
    /// string for the same view (see module doc).  On success the damage
    /// cache is swapped to this frame (rencache-style double-buffer swap);
    /// on error the previous state is left intact.
    pub fn render(self: *TerminalRenderer, w: *std.Io.Writer, frame: []const []const Span) !void {
        var enc: std.ArrayListUnmanaged([]const u8) = .empty;
        defer enc.deinit(self.alloc);
        errdefer for (enc.items) |r| self.alloc.free(r);
        try enc.ensureTotalCapacity(self.alloc, frame.len);
        for (frame) |row| enc.appendAssumeCapacity(try encodeRow(self.alloc, row));

        if (!self.painted) {
            // Tea.paint first-paint (Tea.elm:530-535): enterAltScreen ++
            // hideCursor ++ frameString — one clear-line + row + CRLF per
            // row, the cursor walking down the frame (Tea.paintLine).
            try w.writeAll(enter_alt_screen);
            try w.writeAll(hide_cursor);
            for (enc.items) |e| {
                try w.writeAll(clear_line);
                try w.writeAll(e);
                try w.writeAll(newline);
            }
        } else {
            // Tea.diffString (Tea.elm:559-575): lockstep walk over prev/new;
            // an unchanged row costs NOTHING, a changed row is rewritten AT
            // ITS ROW (absolute address, no trailing CRLF), rows past prev's
            // end are all-new and painted fully (Tea.paintRest via paintAt).
            const n = @min(self.prev.items.len, enc.items.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (!std.mem.eql(u8, enc.items[i], self.prev.items[i])) {
                    try paintAt(w, i + 1, enc.items[i]);
                }
            }
            while (i < enc.items.len) : (i += 1) {
                try paintAt(w, i + 1, enc.items[i]);
            }
            // Shrank: park the cursor on the row BELOW the new last line and
            // wipe the stale rows below it (Tea.elm:539-548).
            if (enc.items.len < self.prev.items.len) {
                try appendMoveTo(w, enc.items.len + 1);
                try w.writeAll(clear_rest);
            }
        }

        // Swap the damage cache to this frame's encoded rows.
        for (self.prev.items) |r| self.alloc.free(r);
        self.prev.clearRetainingCapacity();
        try self.prev.appendSlice(self.alloc, enc.items);
        self.painted = true;
    }
};

/// Tea.paintAt (Tea.elm:606-607): absolute row address + clear-line + text —
/// no trailing \r\n (the address sets the row).
fn paintAt(w: *std.Io.Writer, row: usize, encoded: []const u8) !void {
    try appendMoveTo(w, row);
    try w.writeAll(clear_line);
    try w.writeAll(encoded);
}
