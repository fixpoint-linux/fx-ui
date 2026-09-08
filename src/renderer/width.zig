//! Terminal-cell display width — GENERATED FILE, DO NOT EDIT BY HAND.
//!
//! Emitted by tools/genwidth.zig, which parses the runewidth tables out
//! of elm-compiler/core-libs/Str.elm (combiningRanges Str.elm:317-322,
//! wideRanges Str.elm:330-346) and stamps them in below; everything
//! else mirrors Str.elm's `width` family line for line so the GUI
//! renderer's cell arithmetic and the Elm widgets' can never diverge:
//!
//!   * width walks BYTES, skipping ANSI escapes (CSI + OSC) and summing
//!     runewidth-style per-code-point widths (Str.elm:165-188).
//!   * runeWidth: control -> 0, combining (guarded cp >= 768) -> 0,
//!     wide (guarded cp >= 4352) -> 2, everything else -> 1 (Str.elm:286-297).
//!   * invalid UTF-8 is tolerated exactly like the Elm: a stray
//!     continuation byte is measured raw and advanced by one
//!     (Str.elm:190-208); a truncated tail folds 0x3F per missing byte
//!     (charCode -1, Bitwise.and 63 — Str.elm:228-233).
//!
//! Regenerate:  zig run tools/genwidth.zig -- elm-compiler/core-libs/Str.elm src/renderer/width.zig
//! Gate:        zig build width-check   (wired into `zig build test`)
//! Parity fixture: tests/elm-fixtures/widthparity.elm (Elm-side, elm gate).
//!
//! Pure Zig: no SDL, no allocator, no VM/GC — hot-path safe.

const Range = struct { lo: u21, hi: u21 };

/// Zero-width ranges (Str.elm:313-322 combiningRanges): combining marks,
/// zero-width spaces/joiners, variation selectors, combining diacriticals
/// for symbols.
const combining_ranges = [_]Range{
    .{ .lo = 0x0300, .hi = 0x036f },
    .{ .lo = 0x200b, .hi = 0x200f },
    .{ .lo = 0x20d0, .hi = 0x20ff },
    .{ .lo = 0xfe00, .hi = 0xfe0f },
};

/// Double-cell ranges (Str.elm:325-346 wideRanges): Hangul jamo, CJK
/// radicals/punct, hiragana/katakana, CJK unified ext-A + main, Yi,
/// Hangul syllables, CJK compatibility ideographs, CJK compat forms,
/// fullwidth forms, emoji blocks, and the CJK ext-B/-C planes.
const wide_ranges = [_]Range{
    .{ .lo = 0x1100, .hi = 0x115f },
    .{ .lo = 0x2e80, .hi = 0x303e },
    .{ .lo = 0x3041, .hi = 0x33ff },
    .{ .lo = 0x3400, .hi = 0x4dbf },
    .{ .lo = 0x4e00, .hi = 0x9fff },
    .{ .lo = 0xa000, .hi = 0xa4cf },
    .{ .lo = 0xac00, .hi = 0xd7a3 },
    .{ .lo = 0xf900, .hi = 0xfaff },
    .{ .lo = 0xfe30, .hi = 0xfe4f },
    .{ .lo = 0xff00, .hi = 0xff60 },
    .{ .lo = 0xffe0, .hi = 0xffe6 },
    .{ .lo = 0x1f300, .hi = 0x1f64f },
    .{ .lo = 0x1f900, .hi = 0x1f9ff },
    .{ .lo = 0x20000, .hi = 0x2fffd },
    .{ .lo = 0x30000, .hi = 0x3fffd },
};

/// 0, 1 or 2 display columns for one code point (Str.elm:286-297 runeWidth).
pub fn runeWidth(cp: u21) u8 {
    if (cp < 32 or (cp >= 127 and cp < 160)) {
        return 0; // C0 controls, DEL, C1 controls (Str.elm:287)
    }
    if (cp >= 768 and inRanges(cp, &combining_ranges)) {
        return 0; // combining / zero-width (Str.elm:290-291)
    }
    if (cp >= 4352 and inRanges(cp, &wide_ranges)) {
        return 2; // East Asian wide + emoji blocks (Str.elm:293-294)
    }
    return 1;
}

/// Display width of s in terminal cells — parity with Elm `Str.width`
/// (Str.elm:170-188 width/widthGo): byte walk, ANSI escape sequences
/// zero-width, UTF-8 decoded per lead byte, runeWidth summed.
pub fn strWidth(s: []const u8) usize {
    var i: usize = 0;
    var acc: usize = 0;
    while (i < s.len) {
        if (s[i] == 27) { // ESC: skip the whole sequence (Str.elm:183-184)
            i = skipAnsi(s, i);
            continue;
        }
        const c = s[i];
        acc += runeWidth(decodeRune(s, i));
        i += 1 + runeNeed(c); // Str.elm:187
    }
    return acc;
}

/// Byte index at which the display width of s would exceed max_cols
/// (the Str.elm:357-389 truncate walk, minus the SGR-reset append):
/// escape bytes are zero-width and stay inside the window, the first
/// rune that would overflow ends the walk, zero-width runes always fit,
/// and a wide rune never straddles the cut.  Returns s.len when
/// everything fits.
pub fn advance(s: []const u8, max_cols: usize) usize {
    var i: usize = 0;
    var budget = max_cols;
    while (i < s.len) {
        if (s[i] == 27) {
            i = skipAnsi(s, i);
            continue;
        }
        const c = s[i];
        const cw = runeWidth(decodeRune(s, i));
        if (cw > budget) { // budget - cw < 0 (Str.elm:377)
            return i;
        }
        budget -= cw;
        i += 1 + runeNeed(c);
    }
    return i;
}

fn inRanges(cp: u21, ranges: []const Range) bool {
    for (ranges) |r| {
        if (cp >= r.lo and cp <= r.hi) return true;
    }
    return false;
}

/// Continuation bytes to fold after lead byte c (Str.elm:194-208
/// runeNeed, whose first two branches both return 0): a stray
/// continuation byte (0x80..0xBF, only possible in invalid UTF-8) is
/// measured raw and advanced by one — garbage-in tolerated, never a hang.
fn runeNeed(c: u8) usize {
    if (c < 192) return 0;
    if (c < 224) return 1;
    if (c < 240) return 2;
    return 3;
}

/// Code point at byte i, folding continuation bytes with NO validation
/// (Str.elm:211-233 decodeRune/foldCont).  An out-of-string continuation
/// byte folds as 0x3F (charCode -1, Bitwise.and 63) — mirrors the Elm
/// exactly; the widest fold (0xFF lead + three 0x3F) lands on 0x1FFFFF,
/// the top of u21.
fn decodeRune(s: []const u8, i: usize) u21 {
    const c = s[i];
    var cp: u32 = switch (c) {
        0xC0...0xDF => c & 31, // Str.elm:218-219
        0xE0...0xEF => c & 15, // Str.elm:221-222
        0xF0...0xFF => c & 7, // Str.elm:224-225
        else => c, // ASCII raw + stray continuation raw (Str.elm:212-216)
    };
    var j = i + 1;
    var k = runeNeed(c);
    while (k > 0) : (k -= 1) {
        const b: u32 = if (j < s.len) s[j] else 0x3F; // -1 & 63 == 63
        cp = cp * 64 + (b & 63);
        j += 1;
    }
    return @intCast(cp);
}

/// Index AFTER the escape sequence starting at i (i is the ESC byte)
/// (Str.elm:241-253 skipAnsi).  CSI: 0x1B '[' ... final byte 0x40..0x7E.
/// OSC: 0x1B ']' ... BEL or ESC (the terminating ESC belongs to the NEXT
/// sequence).  Anything else: a 2-byte escape.  Running off the end just
/// lands the caller on end-of-string.
fn skipAnsi(s: []const u8, i: usize) usize {
    const c1: u32 = if (i + 1 < s.len) s[i + 1] else 0xFFFF; // charCode -1 sentinel
    if (c1 == 91) { // '['
        return skipCsi(s, i + 2);
    }
    if (c1 == 93) { // ']'
        return skipOsc(s, i + 2);
    }
    return i + 2;
}

/// Str.elm:256-268 skipCsi: consume until a final byte 0x40..0x7E.
fn skipCsi(s: []const u8, j: usize) usize {
    var k = j;
    while (k < s.len) : (k += 1) {
        if (s[k] >= 0x40 and s[k] <= 0x7E) return k + 1;
    }
    return k;
}

/// Str.elm:271-283 skipOsc: consume until BEL or ESC (ESC consumed).
fn skipOsc(s: []const u8, j: usize) usize {
    var k = j;
    while (k < s.len) : (k += 1) {
        if (s[k] == 7 or s[k] == 27) return k + 1;
    }
    return k;
}
