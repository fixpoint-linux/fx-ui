//! Headless unit tests for the P4 host TerminalRenderer
//! (src/renderer/terminal.zig): synthetic Frames in, EXACT output bytes out,
//! against hand-written expected strings replicating Tea.diffString/Tea.paint
//! behavior (elm-compiler/core-libs/Tea.elm:512-629) and the Lipgloss SGR
//! piece grammar (Lipgloss.elm:949-1052).

const std = @import("std");
const terminal = @import("terminal");
const gui = @import("gui_model");

const Span = terminal.Span;

fn sp(text: []const u8) Span {
    return .{ .text = text };
}

fn styled(text: []const u8, fg: i64, bg: i64, attrs: i64) Span {
    return .{ .text = text, .fg = fg, .bg = bg, .attrs = attrs };
}

/// Render one frame into a fresh fixed buffer and return the written bytes.
fn renderFrame(r: *terminal.TerminalRenderer, frame: []const []const Span) ![]const u8 {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try r.render(&w, frame);
    return w.buffered();
}

fn expectEncoded(alloc: std.mem.Allocator, row: []const Span, expected: []const u8) !void {
    const got = try terminal.encodeRow(alloc, row);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

// ---- encoder: the Lipgloss piece grammar ----

test "encodeRow: default span is bare text" {
    const alloc = std.testing.allocator;
    try expectEncoded(alloc, &.{ sp("hello"), sp(" world") }, "hello world");
}

test "encodeRow: empty row encodes empty" {
    try expectEncoded(std.testing.allocator, &.{}, "");
}

test "encodeRow: one piece per styled span, glue bare between" {
    const alloc = std.testing.allocator;
    try expectEncoded(
        alloc,
        &.{ styled("A", 6, -1, 0), sp(" hi "), styled("B", 2, -1, 0) },
        "\x1b[36mA\x1b[0m hi \x1b[32mB\x1b[0m",
    );
}

test "encodeRow: adjacent same-style pieces stay separate" {
    const alloc = std.testing.allocator;
    try expectEncoded(
        alloc,
        &.{ styled("A", 6, -1, 0), styled("B", 6, -1, 0) },
        "\x1b[36mA\x1b[0m\x1b[36mB\x1b[0m",
    );
}

test "encodeRow: color forms (16/256/RGB, fg and bg)" {
    const alloc = std.testing.allocator;
    try expectEncoded(alloc, &.{styled("x", 0, -1, 0)}, "\x1b[30mx\x1b[0m");
    try expectEncoded(alloc, &.{styled("x", 7, -1, 0)}, "\x1b[37mx\x1b[0m");
    try expectEncoded(alloc, &.{styled("x", 8, -1, 0)}, "\x1b[90mx\x1b[0m");
    try expectEncoded(alloc, &.{styled("x", 15, -1, 0)}, "\x1b[97mx\x1b[0m");
    try expectEncoded(alloc, &.{styled("x", 212, -1, 0)}, "\x1b[38;5;212mx\x1b[0m");
    try expectEncoded(alloc, &.{styled("x", -1, 240, 0)}, "\x1b[48;5;240mx\x1b[0m");
    try expectEncoded(alloc, &.{styled("x", -1, 14, 0)}, "\x1b[106mx\x1b[0m");
    // packed RGB (Draw.packRgb 1 2 3 = 0x1000000 + 0x010203)
    try expectEncoded(alloc, &.{styled("x", 0x1000000 + 0x010203, -1, 0)}, "\x1b[38;2;1;2;3mx\x1b[0m");
}

test "encodeRow: teParamsOf attr order + duplicated underline" {
    const alloc = std.testing.allocator;
    // bold + fg (tabledemo's selected-row needle form)
    try expectEncoded(alloc, &.{styled("x", 212, -1, gui.ATTR_BOLD)}, "\x1b[1;38;5;212mx\x1b[0m");
    // underline + fg: the v1.1.0 duplicate underline-4 (Lipgloss.elm:104)
    try expectEncoded(alloc, &.{styled("x", 6, -1, gui.ATTR_UNDERLINE)}, "\x1b[4;36;4mx\x1b[0m");
    // strikethrough lands AFTER the colors
    try expectEncoded(alloc, &.{styled("x", 212, -1, gui.ATTR_STRIKE)}, "\x1b[38;5;212;9mx\x1b[0m");
    // full attr block order: 1,3,4,7,5,2 then (no colors) then dup 4, then 9
    try expectEncoded(
        alloc,
        &.{styled("x", -1, -1, gui.ATTR_BOLD | gui.ATTR_FAINT | gui.ATTR_ITALIC |
            gui.ATTR_UNDERLINE | gui.ATTR_BLINK | gui.ATTR_REVERSE | gui.ATTR_STRIKE)},
        "\x1b[1;3;4;7;5;2;4;9mx\x1b[0m",
    );
    // attrs + fg + bg: attrs, fg, bg, dup-4, 9
    try expectEncoded(
        alloc,
        &.{styled("x", 6, 4, gui.ATTR_BOLD | gui.ATTR_UNDERLINE)},
        "\x1b[1;4;36;44;4mx\x1b[0m",
    );
}

test "encodeRow: wide runes pass through byte-exact" {
    const alloc = std.testing.allocator;
    try expectEncoded(alloc, &.{styled("日本語", 6, -1, 0)}, "\x1b[36m日本語\x1b[0m");
}

// ---- encoder: REPLAY mode (Draw.fromAnsiLog marker rows) ----

fn mark(fg: i64, bg: i64, attrs: i64) Span {
    return .{ .text = "", .fg = fg, .bg = bg, .attrs = attrs };
}

test "replay: markers replay SGR events, text spans are bare" {
    const alloc = std.testing.allocator;
    // tabledemo's header row: \e[1mRank \e[0m \e[1mCity    \e[0m
    try expectEncoded(
        alloc,
        &.{
            mark(-1, -1, gui.ATTR_BOLD),
            styled("Rank ", -1, -1, gui.ATTR_BOLD),
            mark(-1, -1, 0),
            sp(" "),
            mark(-1, -1, gui.ATTR_BOLD),
            styled("City    ", -1, -1, gui.ATTR_BOLD),
            mark(-1, -1, 0),
        },
        "\x1b[1mRank \x1b[0m \x1b[1mCity    \x1b[0m",
    );
}

test "replay: nested stacked prefixes and stacked trailing resets" {
    const alloc = std.testing.allocator;
    // listdemo's dimmed status row: outer #777777 wrapping pre-styled pieces
    try expectEncoded(
        alloc,
        &.{
            mark(0x1000000 + 0x777777, -1, 0),
            styled("6 items", 0x1000000 + 0x777777, -1, 0),
            mark(0x1000000 + 0x3C3C3C, -1, 0),
            styled(" • ", 0x1000000 + 0x3C3C3C, -1, 0),
            mark(-1, -1, 0),
            mark(0x1000000 + 0x3C3C3C, -1, 0),
            styled("6 filtered", 0x1000000 + 0x3C3C3C, -1, 0),
            mark(-1, -1, 0),
            mark(-1, -1, 0),
        },
        "\x1b[38;2;119;119;119m6 items\x1b[38;2;60;60;60m • \x1b[0m" ++
            "\x1b[38;2;60;60;60m6 filtered\x1b[0m\x1b[0m",
    );
}

test "replay: attr-clear markers re-emit their SGR code" {
    const alloc = std.testing.allocator;
    try expectEncoded(alloc, &.{mark(-1, -1, 4096 | 24)}, "\x1b[24m");
    try expectEncoded(alloc, &.{mark(-1, -1, 4096 | 22)}, "\x1b[22m");
}

test "replay: bare attrLogClear marker is the wrapReset \\e[m" {
    const alloc = std.testing.allocator;
    try expectEncoded(alloc, &.{mark(-1, -1, 4096)}, "\x1b[m");
}

test "replay: styled-empty-line row keeps its prefix and reset" {
    const alloc = std.testing.allocator;
    try expectEncoded(
        alloc,
        &.{ mark(6, -1, 0), mark(-1, -1, 0) },
        "\x1b[36m\x1b[0m",
    );
}

test "replay: marker prefix params follow teParamsOf order" {
    const alloc = std.testing.allocator;
    try expectEncoded(
        alloc,
        &.{ mark(212, -1, gui.ATTR_BOLD | gui.ATTR_UNDERLINE), styled("x", 212, -1, gui.ATTR_BOLD | gui.ATTR_UNDERLINE) },
        "\x1b[1;4;38;5;212;4mx",
    );
}

// ---- first paint (Tea.paint's prev == [] branch) ----

test "render: first paint = altScreen + hideCursor + clear/row/CRLF per row" {
    var r = terminal.TerminalRenderer.init(std.testing.allocator);
    defer r.deinit();
    const got = try renderFrame(&r, &.{
        &.{sp("alpha")},
        &.{styled("beta", 6, -1, 0)},
    });
    try std.testing.expectEqualStrings(
        "\x1b[?1049h\x1b[?25l" ++
            "\x1b[2Kalpha\r\n" ++
            "\x1b[2K\x1b[36mbeta\x1b[0m\r\n",
        got,
    );
}

test "render: first paint of an empty frame is just the screen prologue" {
    var r = terminal.TerminalRenderer.init(std.testing.allocator);
    defer r.deinit();
    const got = try renderFrame(&r, &.{});
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?25l", got);
}

test "render: first paint of empty rows emits the bare row frames" {
    var r = terminal.TerminalRenderer.init(std.testing.allocator);
    defer r.deinit();
    const e: []const Span = &.{};
    const got = try renderFrame(&r, &.{e, e});
    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?25l\x1b[2K\r\n\x1b[2K\r\n", got);
}

// ---- repaints (Tea.diffString) ----

test "render: unchanged repaint emits NOTHING" {
    var r = terminal.TerminalRenderer.init(std.testing.allocator);
    defer r.deinit();
    _ = try renderFrame(&r, &.{&.{sp("a")}, &.{sp("b")}});
    const got = try renderFrame(&r, &.{&.{sp("a")}, &.{sp("b")}});
    try std.testing.expectEqualStrings("", got);
}

test "render: changed row rewrites itself at its absolute address" {
    var r = terminal.TerminalRenderer.init(std.testing.allocator);
    defer r.deinit();
    _ = try renderFrame(&r, &.{ &.{sp("a")}, &.{sp("b")}, &.{sp("c")} });
    const got = try renderFrame(&r, &.{ &.{sp("a")}, &.{styled("B", 6, -1, 0)}, &.{sp("c")} });
    try std.testing.expectEqualStrings("\x1b[2;1H\x1b[2K\x1b[36mB\x1b[0m", got);
}

test "render: style-only change still rewrites the row" {
    var r = terminal.TerminalRenderer.init(std.testing.allocator);
    defer r.deinit();
    _ = try renderFrame(&r, &.{&.{sp("same")}});
    const got = try renderFrame(&r, &.{&.{styled("same", 6, -1, 0)}});
    try std.testing.expectEqualStrings("\x1b[1;1H\x1b[2K\x1b[36msame\x1b[0m", got);
}

test "render: grown frame paints new rows fully, changed rows addressed" {
    var r = terminal.TerminalRenderer.init(std.testing.allocator);
    defer r.deinit();
    _ = try renderFrame(&r, &.{ &.{sp("a")}, &.{sp("b")} });
    const got = try renderFrame(&r, &.{
        &.{styled("A", 6, -1, 0)},
        &.{sp("b")},
        &.{sp("c3")},
        &.{sp("d4")},
    });
    try std.testing.expectEqualStrings(
        "\x1b[1;1H\x1b[2K\x1b[36mA\x1b[0m" ++
            "\x1b[3;1H\x1b[2Kc3" ++
            "\x1b[4;1H\x1b[2Kd4",
        got,
    );
}

test "render: shrunk frame moves below the new last line and clears rest" {
    var r = terminal.TerminalRenderer.init(std.testing.allocator);
    defer r.deinit();
    _ = try renderFrame(&r, &.{ &.{sp("a")}, &.{sp("b")}, &.{sp("c")} });
    const got = try renderFrame(&r, &.{&.{sp("a")}});
    try std.testing.expectEqualStrings("\x1b[2;1H\x1b[J", got);
}

test "render: shrink with a changed row rewrites it, then clears rest" {
    var r = terminal.TerminalRenderer.init(std.testing.allocator);
    defer r.deinit();
    _ = try renderFrame(&r, &.{ &.{sp("a")}, &.{sp("b")}, &.{sp("c")} });
    const got = try renderFrame(&r, &.{&.{sp("A")}});
    try std.testing.expectEqualStrings("\x1b[1;1H\x1b[2KA\x1b[2;1H\x1b[J", got);
}

test "render: damage equality is over the ENCODED row, not span structure" {
    // Two spans "a"+"b" encode to the same bytes as one span "ab": the row
    // is NOT rewritten (a raw-string diff like Tea's would see them equal
    // only after re-encoding — the encoded form IS the canonical row).
    var r = terminal.TerminalRenderer.init(std.testing.allocator);
    defer r.deinit();
    _ = try renderFrame(&r, &.{&.{sp("ab")}});
    const got = try renderFrame(&r, &.{&.{ sp("a"), sp("b") }});
    try std.testing.expectEqualStrings("", got);
}
