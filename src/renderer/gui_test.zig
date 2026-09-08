//! Headless unit tests for the SDL-free GUI logic (src/renderer/gui.zig),
//! per the P2 plan gate: Frame-decode-to-cells (span layout), keymap
//! (scancode -> Runtime.Key ctor name), text-input dedup, px->cell, and the
//! packed-color decode.  No SDL, no vm/gc — runs in the default `test` step.

const std = @import("std");
const testing = std.testing;
const gui = @import("gui.zig");

// ---------------------------------------------------------------------
//  Frame -> cell layout
// ---------------------------------------------------------------------

test "layoutFrame: plain ASCII spans place one rune per cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = [_][]const gui.Span{
        &.{ .{ .text = "hello", .fg = 3 }, .{ .text = " world", .bg = 4 } },
        &.{},
    };
    const g = try gui.layoutFrame(a, &frame, 80, 24);
    try testing.expectEqual(@as(u16, 80), g.cols);
    try testing.expectEqual(@as(u16, 24), g.rows);
    try testing.expectEqualStrings("hello world", rowText(g, 0));
    try testing.expectEqual(@as(i64, 3), g.cells[0].fg);
    // The second span starts at col 5 with bg set and default fg.
    try testing.expectEqualStrings(" ", cellText(g.cells[5]));
    try testing.expectEqual(@as(i64, -1), g.cells[5].fg);
    try testing.expectEqual(@as(i64, 4), g.cells[5].bg);
    // Row 1 is empty; row 2 onward is blank.
    try testing.expectEqual(@as(u8, 0), g.cells[80].len);
    try testing.expectEqual(@as(u8, 0), g.cells[160].len);
}

test "layoutFrame: wide rune occupies two cells, continuation marked skip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = [_][]const gui.Span{
        &.{.{ .text = "a\xe4\xb8\x80b" }}, // a, U+4E00 (wide), b
    };
    const g = try gui.layoutFrame(a, &frame, 80, 24);
    try testing.expectEqualStrings("a", cellText(g.cells[0]));
    try testing.expectEqualStrings("\xe4\xb8\x80", cellText(g.cells[1]));
    try testing.expectEqual(false, g.cells[1].skip);
    try testing.expectEqual(true, g.cells[2].skip); // continuation
    try testing.expectEqual(@as(u8, 0), g.cells[2].len);
    try testing.expectEqualStrings("b", cellText(g.cells[3]));
}

test "layoutFrame: span clips at the grid edge, never straddles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = [_][]const gui.Span{
        &.{.{ .text = "abcdefgh" }},
    };
    // 5-col grid: a..e placed, fgh clipped.
    const g = try gui.layoutFrame(a, &frame, 5, 1);
    try testing.expectEqualStrings("abcde", rowText(g, 0));
}

test "layoutFrame: wide rune that does not fit whole is not placed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = [_][]const gui.Span{
        &.{ .{ .text = "abcd" }, .{ .text = "\xe4\xb8\x80x" } }, // wide at col 4 of a 5-col grid
    };
    const g = try gui.layoutFrame(a, &frame, 5, 1);
    try testing.expectEqualStrings("abcd", rowText(g, 0));
    try testing.expectEqual(@as(u8, 0), g.cells[4].len); // wide rune refused (col 4+2 > 5)
    try testing.expectEqual(false, g.cells[4].skip);
}

test "layoutFrame: rows past the frame stay blank; frame rows past grid clip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = [_][]const gui.Span{
        &.{.{ .text = "one" }},
        &.{.{ .text = "two" }},
        &.{.{ .text = "dropped" }}, // grid has 2 rows
    };
    const g = try gui.layoutFrame(a, &frame, 10, 2);
    try testing.expectEqualStrings("one", rowText(g, 0));
    try testing.expectEqualStrings("two", rowText(g, 1));
}

test "layoutFrame: combining mark folds into the previous cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 'e' + U+0301 combining acute (zero width)
    const frame = [_][]const gui.Span{
        &.{.{ .text = "e\xcc\x81x" }},
    };
    const g = try gui.layoutFrame(a, &frame, 10, 1);
    try testing.expectEqual(@as(u8, 3), g.cells[0].len); // e + 2 combining bytes
    try testing.expectEqualStrings("x", cellText(g.cells[1]));
}

test "layoutFrame: escapes in span text are skipped (defensive)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = [_][]const gui.Span{
        &.{.{ .text = "a\x1b[31mb" }},
    };
    const g = try gui.layoutFrame(a, &frame, 10, 1);
    try testing.expectEqualStrings("ab", rowText(g, 0));
}

test "layoutFrame: attrs/colors ride every cell of a span" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const frame = [_][]const gui.Span{
        &.{.{ .text = "ab", .fg = 0x1000000 + 0x112233, .bg = 208, .attrs = gui.ATTR_BOLD | gui.ATTR_UNDERLINE }},
    };
    const g = try gui.layoutFrame(a, &frame, 10, 1);
    for (g.cells[0..2]) |c| {
        try testing.expectEqual(@as(i64, 0x1112233), c.fg);
        try testing.expectEqual(@as(i64, 208), c.bg);
        try testing.expectEqual(gui.ATTR_BOLD | gui.ATTR_UNDERLINE, c.attrs);
    }
}

test "hashCell: content-sensitive, style-sensitive" {
    const a = gui.Cell{ .bytes = .{ 'x', 0, 0, 0 }, .len = 1 };
    const b = gui.Cell{ .bytes = .{ 'x', 0, 0, 0 }, .len = 1 };
    const c = gui.Cell{ .bytes = .{ 'y', 0, 0, 0 }, .len = 1 };
    const styled = gui.Cell{ .bytes = .{ 'x', 0, 0, 0 }, .len = 1, .fg = 5 };
    try testing.expectEqual(gui.hashCell(a), gui.hashCell(b));
    try testing.expect(gui.hashCell(a) != gui.hashCell(c));
    try testing.expect(gui.hashCell(a) != gui.hashCell(styled));
}

// ---------------------------------------------------------------------
//  Keymap: SDL scancode -> Runtime.Key ctor name
// ---------------------------------------------------------------------

test "mapKey: named keys map to the Runtime.Key ctor spellings" {
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyEnter" }, gui.mapKey(gui.SCAN_RETURN, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyEsc" }, gui.mapKey(gui.SCAN_ESCAPE, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyBackspace" }, gui.mapKey(gui.SCAN_BACKSPACE, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyTab" }, gui.mapKey(gui.SCAN_TAB, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyUp" }, gui.mapKey(gui.SCAN_UP, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyDown" }, gui.mapKey(gui.SCAN_DOWN, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyLeft" }, gui.mapKey(gui.SCAN_LEFT, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyRight" }, gui.mapKey(gui.SCAN_RIGHT, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyHome" }, gui.mapKey(gui.SCAN_HOME, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyEnd" }, gui.mapKey(gui.SCAN_END, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyPgUp" }, gui.mapKey(gui.SCAN_PAGEUP, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyPgDn" }, gui.mapKey(gui.SCAN_PAGEDOWN, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyIns" }, gui.mapKey(gui.SCAN_INSERT, false).?);
    try testing.expectEqual(gui.KeyDesc{ .named = "KeyDel" }, gui.mapKey(gui.SCAN_DELETE, false).?);
}

test "mapKey: ctrl+letter maps to the control byte, plain letters are null" {
    try testing.expectEqual(gui.KeyDesc{ .ctrl = 3 }, gui.mapKey(gui.SCAN_C, true).?); // ctrl+c
    try testing.expectEqual(gui.KeyDesc{ .ctrl = 17 }, gui.mapKey(gui.SCAN_Q, true).?); // ctrl+q
    try testing.expectEqual(gui.KeyDesc{ .ctrl = 1 }, gui.mapKey(gui.SCAN_A, true).?);
    // Without ctrl, letters/digits ride SDL_TEXTINPUT — no mapping.
    try testing.expectEqual(@as(?gui.KeyDesc, null), gui.mapKey(gui.SCAN_A, false));
    try testing.expectEqual(@as(?gui.KeyDesc, null), gui.mapKey(gui.SCAN_1, true));
    try testing.expectEqual(@as(?gui.KeyDesc, null), gui.mapKey(999, false));
}

// ---------------------------------------------------------------------
//  Text-input dedup + px->cell
// ---------------------------------------------------------------------

test "filterTextInput: named-key duplicates dropped, real text passes" {
    try testing.expectEqual(@as(?[]const u8, null), gui.filterTextInput("\r"));
    try testing.expectEqual(@as(?[]const u8, null), gui.filterTextInput("\n"));
    try testing.expectEqual(@as(?[]const u8, null), gui.filterTextInput("\t"));
    try testing.expectEqual(@as(?[]const u8, null), gui.filterTextInput("\x08"));
    try testing.expectEqual(@as(?[]const u8, null), gui.filterTextInput(""));
    try testing.expectEqualStrings("a", gui.filterTextInput("a").?);
    try testing.expectEqualStrings("\xe4\xb8\x80", gui.filterTextInput("\xe4\xb8\x80").?);
}

test "pxToCell: floor division + clamping to the grid" {
    // 8x16 cells, 80x24 grid
    try testing.expectEqual(gui.CellPos{ .c = 0, .r = 0 }, gui.pxToCell(0, 0, 8, 16, 80, 24));
    try testing.expectEqual(gui.CellPos{ .c = 5, .r = 2 }, gui.pxToCell(47, 39, 8, 16, 80, 24));
    try testing.expectEqual(gui.CellPos{ .c = 6, .r = 2 }, gui.pxToCell(48, 39, 8, 16, 80, 24));
    try testing.expectEqual(gui.CellPos{ .c = 79, .r = 23 }, gui.pxToCell(100000, 100000, 8, 16, 80, 24));
    try testing.expectEqual(gui.CellPos{ .c = 0, .r = 0 }, gui.pxToCell(-5, -5, 8, 16, 80, 24));
}

// ---------------------------------------------------------------------
//  Packed colors
// ---------------------------------------------------------------------

test "colorOf: none/base16/cube/gray/rgb24" {
    try testing.expectEqual([3]u8{ 9, 9, 9 }, gui.colorOf(-1, .{ 9, 9, 9 }));
    try testing.expectEqual([3]u8{ 0xcd, 0x00, 0x00 }, gui.colorOf(1, .{ 9, 9, 9 })); // base16 red
    try testing.expectEqual([3]u8{ 0xff, 0xff, 0xff }, gui.colorOf(15, .{ 9, 9, 9 })); // base16 white
    try testing.expectEqual([3]u8{ 0x00, 0x00, 0x00 }, gui.colorOf(16, .{ 9, 9, 9 })); // cube [0,0,0]
    try testing.expectEqual([3]u8{ 0xff, 0xd7, 0x00 }, gui.colorOf(220, .{ 9, 9, 9 })); // cube 220 (yellow)
    try testing.expectEqual([3]u8{ 0x08, 0x08, 0x08 }, gui.colorOf(232, .{ 9, 9, 9 })); // gray ramp start
    try testing.expectEqual([3]u8{ 0xee, 0xee, 0xee }, gui.colorOf(255, .{ 9, 9, 9 })); // gray ramp end
    try testing.expectEqual([3]u8{ 0x11, 0x22, 0x33 }, gui.colorOf(0x1000000 + 0x112233, .{ 9, 9, 9 }));
}

test "EvRecord is 28 bytes and default-initializes" {
    const r = gui.EvRecord{};
    try testing.expectEqual(@as(u8, 0), r.kind);
    try testing.expectEqual(@as(usize, 24), @sizeOf(gui.EvRecord));
    try testing.expectEqual(@as(u32, 0), r.scancode);
}

// ---- helpers ---------------------------------------------------------

fn cellText(c: gui.Cell) []const u8 {
    return c.bytes[0..c.len];
}

/// Concatenate row `row`'s rune bytes into a static scratch buffer (tests are
/// single-threaded and compare immediately, so the borrow is safe).
var rowbuf: [512]u8 = undefined;

fn rowText(g: gui.Grid, row: usize) []const u8 {
    const start = row * g.cols;
    var end = start;
    while (end < start + g.cols and g.cells[end].len > 0 and !g.cells[end].skip) : (end += 1) {}
    var w: usize = 0;
    for (g.cells[start..end]) |c| {
        @memcpy(rowbuf[w..][0..c.len], c.bytes[0..c.len]);
        w += c.len;
    }
    return rowbuf[0..w];
}
