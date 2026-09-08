//! Unit tests for the GENERATED src/renderer/width.zig (photon-gui P2 step 8).
//!
//! Layered parity story:
//!   * table parity  — `zig build width-check` (tools/genwidth.zig re-parses
//!     Str.elm's combiningRanges/wideRanges and byte-diffs width.zig);
//!   * walk parity   — THIS file pins ANSI skip / lead-byte decode /
//!     invalid-UTF-8 tolerance / advance cut points against
//!     elm-compiler/core-libs/Str.elm (width :170-188, runeWidth :286-297,
//!     decode :194-233, skipAnsi :241-283, truncate :357-389);
//!   * cross parity  — tests/elm-fixtures/widthparity.elm asserts the SAME
//!     representative values through the real Str.width in the elm gate.
//!
//! Pure std.testing; no SDL, no vm, no allocation.

const std = @import("std");
const width = @import("width.zig");

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "ascii is one column" {
    try expectEqual(1, width.runeWidth('a'));
    try expectEqual(1, width.runeWidth(' '));
    try expectEqual(1, width.runeWidth('~'));
    try expectEqual(5, width.strWidth("hello"));
    try expectEqual(0, width.strWidth(""));
}

test "cjk, kana, hangul and fullwidth are two columns" {
    // One representative per wide range (Str.elm:330-346).
    try expectEqual(2, width.runeWidth(0x1100)); // Hangul jamo
    try expectEqual(2, width.runeWidth(0x2E80)); // CJK radicals
    try expectEqual(2, width.runeWidth(0x3001)); // CJK punct 、
    try expectEqual(2, width.runeWidth(0x3042)); // hiragana あ
    try expectEqual(2, width.runeWidth(0x30A2)); // katakana ア
    try expectEqual(2, width.runeWidth(0x3400)); // ext-A
    try expectEqual(2, width.runeWidth(0x4E00)); // CJK unified 一
    try expectEqual(2, width.runeWidth(0xA000)); // Yi
    try expectEqual(2, width.runeWidth(0xAC00)); // Hangul syllable 가
    try expectEqual(2, width.runeWidth(0xF900)); // compat ideographs
    try expectEqual(2, width.runeWidth(0xFE3A)); // compat forms
    try expectEqual(2, width.runeWidth(0xFF21)); // fullwidth Ａ
    try expectEqual(2, width.runeWidth(0xFFE6)); // fullwidth ￦-edge
    try expectEqual(10, width.strWidth("漢字テスト")); // 5 runes x 2
    try expectEqual(4, width.strWidth("ＡＢ"));
}

test "combining and zero-width codepoints are zero columns" {
    // Boundaries of all four combiningRanges (Str.elm:317-322).
    try expectEqual(1, width.runeWidth(0x02FF));
    try expectEqual(0, width.runeWidth(0x0300));
    try expectEqual(0, width.runeWidth(0x036F));
    try expectEqual(1, width.runeWidth(0x0370));
    try expectEqual(1, width.runeWidth(0x200A));
    try expectEqual(0, width.runeWidth(0x200B)); // ZWSP
    try expectEqual(0, width.runeWidth(0x200D)); // ZWJ
    try expectEqual(0, width.runeWidth(0x200F));
    try expectEqual(1, width.runeWidth(0x2010));
    try expectEqual(1, width.runeWidth(0x20CF));
    try expectEqual(0, width.runeWidth(0x20D0));
    try expectEqual(0, width.runeWidth(0x20FF));
    try expectEqual(1, width.runeWidth(0x2100));
    try expectEqual(0, width.runeWidth(0xFE00)); // variation selector 1
    try expectEqual(0, width.runeWidth(0xFE0F)); // VS16
    try expectEqual(1, width.runeWidth(0xFE10));
    // The cp >= 768 guard (Str.elm:290): nothing below can be zero-width.
    try expectEqual(1, width.runeWidth(0x00B4));
    // Applied: combining marks do not add cells.
    try expectEqual(1, width.strWidth("e\u{0301}"));
    try expectEqual(2, width.strWidth("a\u{200D}b"));
    try expectEqual(2, width.strWidth("👍\u{FE0F}")); // emoji + VS16
}

test "box drawing is one column (Lipgloss border runes)" {
    // 0x2500..0x259F sits in the gap between wide ranges 0x2E80 and 0x1F300
    // — the single-cell assumption behind every Lipgloss box border.
    try expectEqual(1, width.runeWidth(0x2500)); // ─
    try expectEqual(1, width.runeWidth(0x2502)); // │
    try expectEqual(1, width.runeWidth(0x250C)); // ┌
    try expectEqual(1, width.runeWidth(0x2514)); // └
    try expectEqual(1, width.runeWidth(0x251C)); // ├
    try expectEqual(1, width.runeWidth(0x253C)); // ┼
    try expectEqual(1, width.runeWidth(0x2550)); // ═
    try expectEqual(1, width.runeWidth(0x2554)); // ╔
    try expectEqual(1, width.runeWidth(0x2570)); // ╰
    try expectEqual(1, width.runeWidth(0x2588)); // █
    try expectEqual(1, width.runeWidth(0x2591)); // ░
    try expectEqual(3, width.strWidth("┌─┐"));
    try expectEqual(4, width.strWidth("│漢│")); // mixed narrow + wide
}

test "control characters are zero columns" {
    try expectEqual(0, width.runeWidth(0x00));
    try expectEqual(0, width.runeWidth(0x07));
    try expectEqual(0, width.runeWidth('\t'));
    try expectEqual(0, width.runeWidth('\n'));
    try expectEqual(0, width.runeWidth('\r'));
    try expectEqual(0, width.runeWidth(0x1F));
    try expectEqual(0, width.runeWidth(0x7F)); // DEL
    try expectEqual(0, width.runeWidth(0x80)); // C1
    try expectEqual(0, width.runeWidth(0x9F));
    try expectEqual(2, width.strWidth("a\tb"));
    try expectEqual(0, width.strWidth("\n"));
    try expectEqual(2, width.strWidth("a\u{7F}b"));
}

test "ansi escape sequences are zero width (CSI + OSC)" {
    try expectEqual(3, width.strWidth("\x1b[31mred\x1b[0m"));
    try expectEqual(2, width.strWidth("\x1b[38;5;196mhi\x1b[0m"));
    try expectEqual(8, width.strWidth("\x1b[1;38;5;196;48;2;1;2;3mXY\x1b[0m plain")); // "XY"+" plain"
    try expectEqual(1, width.strWidth("\x1b]0;title\x07x")); // OSC, BEL-terminated
    // ESC-terminated OSC: the ESC is the terminator, the following '\' is
    // walked as a plain char (skipOsc consumes it, Str.elm:279-281).
    try expectEqual(5, width.strWidth("\x1b]8;;x\x1b\\link"));
    try expectEqual(0, width.strWidth("\x1bM")); // non-CSI/OSC: 2-byte escape
    try expectEqual(1, width.strWidth("a\x1b")); // lone ESC at end of string
    try expectEqual(0, width.strWidth("\x1b"));
}

test "emoji blocks are two columns" {
    try expectEqual(2, width.runeWidth(0x1F300));
    try expectEqual(2, width.runeWidth(0x1F44D)); // 👍
    try expectEqual(2, width.runeWidth(0x1F64F));
    try expectEqual(2, width.runeWidth(0x1F98A)); // 🦊
    try expectEqual(2, width.runeWidth(0x1F9FF));
    try expectEqual(1, width.runeWidth(0x1F2FF)); // gap before 0x1F300
    try expectEqual(1, width.runeWidth(0x1F650)); // gap 0x1F650..0x1F8FF
    try expectEqual(1, width.runeWidth(0x1FA00)); // gap after 0x1F9FF
    // Documented overcount (Str.elm:43-45): no grapheme clustering, so a
    // ZWJ family counts per code point — parity, not correctness.
    try expectEqual(6, width.strWidth("👨\u{200D}👩\u{200D}👧"));
    try expectEqual(1, width.strWidth("✓")); // U+2713: not wide, no VS16
    try expectEqual(1, width.strWidth("✓\u{FE0F}")); // VS16 adds nothing
}

test "wide and combining range boundaries match Str.elm exactly" {
    const cases = [_]struct { cp: u21, want: u8 }{
        // every wideRanges entry: lo, hi, and hi+1 (Str.elm:330-346)
        .{ .cp = 0x1100, .want = 2 },  .{ .cp = 0x115F, .want = 2 },
        .{ .cp = 0x1160, .want = 1 },  .{ .cp = 0x2E80, .want = 2 },
        .{ .cp = 0x303E, .want = 2 },  .{ .cp = 0x303F, .want = 1 },
        .{ .cp = 0x3041, .want = 2 },  .{ .cp = 0x33FF, .want = 2 },
        .{ .cp = 0x3400, .want = 2 },  .{ .cp = 0x4DBF, .want = 2 },
        .{ .cp = 0x4DC0, .want = 1 },  .{ .cp = 0x4E00, .want = 2 },
        .{ .cp = 0x9FFF, .want = 2 },  .{ .cp = 0xA000, .want = 2 },
        .{ .cp = 0xA4CF, .want = 2 },  .{ .cp = 0xA4D0, .want = 1 },
        .{ .cp = 0xAC00, .want = 2 },  .{ .cp = 0xD7A3, .want = 2 },
        .{ .cp = 0xD7A4, .want = 1 },  .{ .cp = 0xF900, .want = 2 },
        .{ .cp = 0xFAFF, .want = 2 },  .{ .cp = 0xFB00, .want = 1 },
        .{ .cp = 0xFE30, .want = 2 },  .{ .cp = 0xFE4F, .want = 2 },
        .{ .cp = 0xFE50, .want = 1 },  .{ .cp = 0xFF00, .want = 2 },
        .{ .cp = 0xFF60, .want = 2 },  .{ .cp = 0xFF61, .want = 1 },
        .{ .cp = 0xFFE0, .want = 2 },  .{ .cp = 0xFFE6, .want = 2 },
        .{ .cp = 0xFFE7, .want = 1 },  .{ .cp = 0x1F300, .want = 2 },
        .{ .cp = 0x1F64F, .want = 2 }, .{ .cp = 0x1F650, .want = 1 },
        .{ .cp = 0x1F900, .want = 2 }, .{ .cp = 0x1F9FF, .want = 2 },
        .{ .cp = 0x1FA00, .want = 1 }, .{ .cp = 0x20000, .want = 2 },
        .{ .cp = 0x2FFFD, .want = 2 }, .{ .cp = 0x2FFFE, .want = 1 },
        .{ .cp = 0x30000, .want = 2 }, .{ .cp = 0x3FFFD, .want = 2 },
        .{ .cp = 0x3FFFE, .want = 1 },
    };
    for (cases) |t| {
        try expectEqual(t.want, width.runeWidth(t.cp));
    }
}

test "widths stay within 0..2 across the whole codepoint space" {
    var cp: u32 = 0;
    while (cp <= 0x10FFFF) : (cp += 97) {
        try expect(width.runeWidth(@intCast(cp)) <= 2);
    }
    // u21 corners beyond Unicode — reachable only through invalid UTF-8.
    try expectEqual(1, width.runeWidth(0x1FFFFF));
}

test "utf8 boundary handling tolerates garbage exactly like Str.elm" {
    // Valid multibyte decodes.
    try expectEqual(1, width.strWidth("é")); // 2-byte rune
    try expectEqual(2, width.strWidth("漢")); // 3-byte rune
    try expectEqual(2, width.strWidth("🦊")); // 4-byte rune
    // Stray continuation byte: measured RAW and advanced by one
    // (Str.elm:190-199). 0x80..0x9F land in the C1 control band -> 0.
    try expectEqual(0, width.strWidth("\x80"));
    try expectEqual(1, width.strWidth("\xa0"));
    try expectEqual(1, width.strWidth("\xbf"));
    try expectEqual(2, width.strWidth("a\x80b"));
    // Truncated rune at end of string: missing continuation bytes fold as
    // 0x3F (charCode -1 & 63) and never hang the walk (Str.elm:228-233).
    try expectEqual(1, width.strWidth("e\xcc")); // folds to cp 0x33F: INSIDE combiningRanges -> 0
    try expectEqual(2, width.strWidth("e\xe2\x84")); // folds to cp 0x213F: plain -> 1
    // Overlong lead 0xC0: decodes to cp 0 (control band) -> 0.
    try expectEqual(0, width.strWidth("\xc0\x80"));
}

test "advance cuts at column boundaries" {
    try expectEqual(0, width.advance("", 5));
    try expectEqual(0, width.advance("abc", 0));
    try expectEqual(2, width.advance("abc", 2));
    try expectEqual(3, width.advance("abc", 10));
    // A wide rune never straddles the cut.
    try expectEqual(0, width.advance("漢", 1));
    try expectEqual(1, width.advance("a漢b", 1));
    try expectEqual(1, width.advance("a漢b", 2)); // 漢 needs 2 free cells
    try expectEqual(4, width.advance("a漢b", 3));
    try expectEqual(5, width.advance("a漢b", 4)); // everything fits
    // Zero-width runes always fit, before and after the budget runs out.
    try expectEqual(3, width.advance("e\u{0301}", 1));
    try expectEqual(0, width.advance("e\u{0301}", 0));
    try expectEqual(2, width.advance("\u{0301}e", 0));
    // Escape bytes are zero-width and stay inside the window.
    try expectEqual(7, width.advance("\x1b[31mabc\x1b[0m", 2));
    // Exact parity with Str.truncate's walk (Str.elm:377): the cut lands
    // after 2 visible cells; Elm appends only the SGR reset on top.
    try expectEqual(9, width.advance("\x1b[1;31mabc\x1b[0m", 2));
    try expectEqual(7, width.advance("\x1b]8;;u\x07text", 0));
}
