//! genwidth — codegen for src/renderer/width.zig (photon-gui P2 step 8).
//!
//! Parses the runewidth tables out of elm-compiler/core-libs/Str.elm
//! (`combiningRanges` / `wideRanges`) and emits the ENTIRE
//! src/renderer/width.zig from the template below, so the Elm widgets'
//! notion of a terminal cell and the GUI renderer's can never diverge
//! (plan risk 3):
//!
//!   regen (human):  zig run tools/genwidth.zig -- \
//!                     elm-compiler/core-libs/Str.elm src/renderer/width.zig
//!   gate (build):   zig build width-check   (wired into `zig build test`)
//!     regenerates in memory and byte-diffs against the checked-in file.
//!
//! The parser is strict: any structural surprise in Str.elm (missing `=`,
//! `[`, `(`, `0x`, `,`, `)`) is a loud error, never a silently partial
//! table.  Pure std; no vm/gc imports; runs standalone.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    var argi: usize = 1;
    var check = false;
    if (argi < args.len and std.mem.eql(u8, args[argi], "--check")) {
        check = true;
        argi += 1;
    }
    if (args.len - argi != 2) {
        std.debug.print("usage: genwidth [--check] <elm-compiler/core-libs/Str.elm> <src/renderer/width.zig>\n", .{});
        std.process.exit(2);
    }
    const elm_path = args[argi];
    const zig_path = args[argi + 1];

    const elm_src = try std.Io.Dir.cwd().readFileAlloc(io, elm_path, alloc, .limited(16 * 1024 * 1024));
    const combining = try parseRanges(alloc, elm_src, "combiningRanges");
    const wide = try parseRanges(alloc, elm_src, "wideRanges");
    if (combining.len == 0 or wide.len == 0) {
        std.debug.print("genwidth: parsed an EMPTY table from {s} (combining={d} wide={d})\n", .{ elm_path, combining.len, wide.len });
        std.process.exit(3);
    }
    const generated = try render(alloc, combining, wide);

    if (check) {
        const current = try std.Io.Dir.cwd().readFileAlloc(io, zig_path, alloc, .limited(16 * 1024 * 1024));
        if (!std.mem.eql(u8, current, generated)) {
            const n = @min(current.len, generated.len);
            var d: usize = 0;
            while (d < n and current[d] == generated[d]) : (d += 1) {}
            std.debug.print(
                "genwidth: {s} is STALE vs {s} (first diff at byte {d})\n" ++
                    "  regenerate: zig run tools/genwidth.zig -- {s} {s}\n",
                .{ zig_path, elm_path, d, elm_path, zig_path },
            );
            std.process.exit(1);
        }
        std.debug.print("genwidth: {s} up to date with {s} ({d} combining + {d} wide ranges)\n", .{ zig_path, elm_path, combining.len, wide.len });
        return;
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = zig_path, .data = generated });
    std.debug.print("genwidth: wrote {s} ({d} combining + {d} wide ranges from {s})\n", .{ zig_path, combining.len, wide.len, elm_path });
}

const Range = struct { lo: u32, hi: u32 };

/// Find `name` as a whole identifier followed by `=`, returning the position
/// of the `=`.  Str.elm also mentions the table names in code (e.g. the
/// runeWidth body says `inRanges cp combiningRanges`), so a bare
/// indexOf would grab the wrong occurrence — require the binding.
fn findBinding(src: []const u8, name: []const u8) !usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, src, from, name)) |at| {
        const whole = (at == 0 or !isIdentChar(src[at - 1])) and
            (at + name.len >= src.len or !isIdentChar(src[at + name.len]));
        const eq = skipWs(src, at + name.len);
        if (whole and eq < src.len and src[eq] == '=') return eq;
        from = at + name.len;
    }
    return error.TableNotFound;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn skipWs(src: []const u8, at: usize) usize {
    var j = at;
    while (j < src.len and (src[j] == ' ' or src[j] == '\n' or src[j] == '\r' or src[j] == '\t')) : (j += 1) {}
    return j;
}

/// Parse `[ ( 0xLO, 0xHI ), ( 0xLO, 0xHI ), ... ]` — the exact shape the
/// Str.elm range tables are written in.
fn parseRanges(alloc: std.mem.Allocator, src: []const u8, name: []const u8) ![]Range {
    const eq = try findBinding(src, name);
    const bracket = skipWs(src, eq + 1);
    if (bracket >= src.len or src[bracket] != '[') return error.TableNotFound;

    var ranges: std.ArrayList(Range) = .empty;
    var j = bracket + 1;
    while (true) {
        j = skipWs(src, j);
        if (j >= src.len) return error.TableNotFound; // ran off before ']'
        if (src[j] == ']') break;
        if (src[j] == ',') {
            j += 1;
            continue;
        }
        if (src[j] != '(') return error.TableNotFound;
        const lo = try parseHex(src, skipWs(src, j + 1));
        const comma = skipWs(src, lo.end);
        if (comma >= src.len or src[comma] != ',') return error.TableNotFound;
        const hi = try parseHex(src, skipWs(src, comma + 1));
        const close = skipWs(src, hi.end);
        if (close >= src.len or src[close] != ')') return error.TableNotFound;
        try ranges.append(alloc, .{ .lo = lo.value, .hi = hi.value });
        j = close + 1;
    }
    return ranges.items;
}

const Hex = struct { value: u32, end: usize };

fn parseHex(src: []const u8, at: usize) !Hex {
    if (at + 1 >= src.len or src[at] != '0' or src[at + 1] != 'x') return error.TableNotFound;
    var j = at + 2;
    var v: u32 = 0;
    var digits: usize = 0;
    while (j < src.len) : (j += 1) {
        const d: u32 = switch (src[j]) {
            '0'...'9' => src[j] - '0',
            'a'...'f' => src[j] - 'a' + 10,
            'A'...'F' => src[j] - 'A' + 10,
            else => break,
        };
        v = v * 16 + d;
        digits += 1;
        if (v > 0x1FFFFF) return error.TableNotFound; // beyond the BMP+SMP range tables
    }
    if (digits == 0) return error.TableNotFound;
    return .{ .value = v, .end = j };
}

// ---- template ----
// Emitted in three chunks around the two parsed tables.  Everything except
// the range lines is STATIC and must keep mirroring Str.elm's width family.

fn render(alloc: std.mem.Allocator, combining: []const Range, wide: []const Range) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;

    try w.writeAll(header);
    try w.writeAll(combining_doc);
    for (combining) |r| try w.print("    .{{ .lo = 0x{x:0>4}, .hi = 0x{x:0>4} }},\n", .{ r.lo, r.hi });
    try w.writeAll(wide_doc);
    for (wide) |r| try w.print("    .{{ .lo = 0x{x:0>4}, .hi = 0x{x:0>4} }},\n", .{ r.lo, r.hi });
    try w.writeAll(body);
    return aw.written();
}

const header =
    \\//! Terminal-cell display width — GENERATED FILE, DO NOT EDIT BY HAND.
    \\//!
    \\//! Emitted by tools/genwidth.zig, which parses the runewidth tables out
    \\//! of elm-compiler/core-libs/Str.elm (combiningRanges Str.elm:317-322,
    \\//! wideRanges Str.elm:330-346) and stamps them in below; everything
    \\//! else mirrors Str.elm's `width` family line for line so the GUI
    \\//! renderer's cell arithmetic and the Elm widgets' can never diverge:
    \\//!
    \\//!   * width walks BYTES, skipping ANSI escapes (CSI + OSC) and summing
    \\//!     runewidth-style per-code-point widths (Str.elm:165-188).
    \\//!   * runeWidth: control -> 0, combining (guarded cp >= 768) -> 0,
    \\//!     wide (guarded cp >= 4352) -> 2, everything else -> 1 (Str.elm:286-297).
    \\//!   * invalid UTF-8 is tolerated exactly like the Elm: a stray
    \\//!     continuation byte is measured raw and advanced by one
    \\//!     (Str.elm:190-208); a truncated tail folds 0x3F per missing byte
    \\//!     (charCode -1, Bitwise.and 63 — Str.elm:228-233).
    \\//!
    \\//! Regenerate:  zig run tools/genwidth.zig -- elm-compiler/core-libs/Str.elm src/renderer/width.zig
    \\//! Gate:        zig build width-check   (wired into `zig build test`)
    \\//! Parity fixture: tests/elm-fixtures/widthparity.elm (Elm-side, elm gate).
    \\//!
    \\//! Pure Zig: no SDL, no allocator, no VM/GC — hot-path safe.
    \\
    \\const Range = struct { lo: u21, hi: u21 };
    \\
    \\
;

const combining_doc =
    \\/// Zero-width ranges (Str.elm:313-322 combiningRanges): combining marks,
    \\/// zero-width spaces/joiners, variation selectors, combining diacriticals
    \\/// for symbols.
    \\const combining_ranges = [_]Range{
    \\
;

const wide_doc =
    \\};
    \\
    \\/// Double-cell ranges (Str.elm:325-346 wideRanges): Hangul jamo, CJK
    \\/// radicals/punct, hiragana/katakana, CJK unified ext-A + main, Yi,
    \\/// Hangul syllables, CJK compatibility ideographs, CJK compat forms,
    \\/// fullwidth forms, emoji blocks, and the CJK ext-B/-C planes.
    \\const wide_ranges = [_]Range{
    \\
;

const body =
    \\};
    \\
    \\/// 0, 1 or 2 display columns for one code point (Str.elm:286-297 runeWidth).
    \\pub fn runeWidth(cp: u21) u8 {
    \\    if (cp < 32 or (cp >= 127 and cp < 160)) {
    \\        return 0; // C0 controls, DEL, C1 controls (Str.elm:287)
    \\    }
    \\    if (cp >= 768 and inRanges(cp, &combining_ranges)) {
    \\        return 0; // combining / zero-width (Str.elm:290-291)
    \\    }
    \\    if (cp >= 4352 and inRanges(cp, &wide_ranges)) {
    \\        return 2; // East Asian wide + emoji blocks (Str.elm:293-294)
    \\    }
    \\    return 1;
    \\}
    \\
    \\/// Display width of s in terminal cells — parity with Elm `Str.width`
    \\/// (Str.elm:170-188 width/widthGo): byte walk, ANSI escape sequences
    \\/// zero-width, UTF-8 decoded per lead byte, runeWidth summed.
    \\pub fn strWidth(s: []const u8) usize {
    \\    var i: usize = 0;
    \\    var acc: usize = 0;
    \\    while (i < s.len) {
    \\        if (s[i] == 27) { // ESC: skip the whole sequence (Str.elm:183-184)
    \\            i = skipAnsi(s, i);
    \\            continue;
    \\        }
    \\        const c = s[i];
    \\        acc += runeWidth(decodeRune(s, i));
    \\        i += 1 + runeNeed(c); // Str.elm:187
    \\    }
    \\    return acc;
    \\}
    \\
    \\/// Byte index at which the display width of s would exceed max_cols
    \\/// (the Str.elm:357-389 truncate walk, minus the SGR-reset append):
    \\/// escape bytes are zero-width and stay inside the window, the first
    \\/// rune that would overflow ends the walk, zero-width runes always fit,
    \\/// and a wide rune never straddles the cut.  Returns s.len when
    \\/// everything fits.
    \\pub fn advance(s: []const u8, max_cols: usize) usize {
    \\    var i: usize = 0;
    \\    var budget = max_cols;
    \\    while (i < s.len) {
    \\        if (s[i] == 27) {
    \\            i = skipAnsi(s, i);
    \\            continue;
    \\        }
    \\        const c = s[i];
    \\        const cw = runeWidth(decodeRune(s, i));
    \\        if (cw > budget) { // budget - cw < 0 (Str.elm:377)
    \\            return i;
    \\        }
    \\        budget -= cw;
    \\        i += 1 + runeNeed(c);
    \\    }
    \\    return i;
    \\}
    \\
    \\fn inRanges(cp: u21, ranges: []const Range) bool {
    \\    for (ranges) |r| {
    \\        if (cp >= r.lo and cp <= r.hi) return true;
    \\    }
    \\    return false;
    \\}
    \\
    \\/// Continuation bytes to fold after lead byte c (Str.elm:194-208
    \\/// runeNeed, whose first two branches both return 0): a stray
    \\/// continuation byte (0x80..0xBF, only possible in invalid UTF-8) is
    \\/// measured raw and advanced by one — garbage-in tolerated, never a hang.
    \\fn runeNeed(c: u8) usize {
    \\    if (c < 192) return 0;
    \\    if (c < 224) return 1;
    \\    if (c < 240) return 2;
    \\    return 3;
    \\}
    \\
    \\/// Code point at byte i, folding continuation bytes with NO validation
    \\/// (Str.elm:211-233 decodeRune/foldCont).  An out-of-string continuation
    \\/// byte folds as 0x3F (charCode -1, Bitwise.and 63) — mirrors the Elm
    \\/// exactly; the widest fold (0xFF lead + three 0x3F) lands on 0x1FFFFF,
    \\/// the top of u21.
    \\fn decodeRune(s: []const u8, i: usize) u21 {
    \\    const c = s[i];
    \\    var cp: u32 = switch (c) {
    \\        0xC0...0xDF => c & 31, // Str.elm:218-219
    \\        0xE0...0xEF => c & 15, // Str.elm:221-222
    \\        0xF0...0xFF => c & 7, // Str.elm:224-225
    \\        else => c, // ASCII raw + stray continuation raw (Str.elm:212-216)
    \\    };
    \\    var j = i + 1;
    \\    var k = runeNeed(c);
    \\    while (k > 0) : (k -= 1) {
    \\        const b: u32 = if (j < s.len) s[j] else 0x3F; // -1 & 63 == 63
    \\        cp = cp * 64 + (b & 63);
    \\        j += 1;
    \\    }
    \\    return @intCast(cp);
    \\}
    \\
    \\/// Index AFTER the escape sequence starting at i (i is the ESC byte)
    \\/// (Str.elm:241-253 skipAnsi).  CSI: 0x1B '[' ... final byte 0x40..0x7E.
    \\/// OSC: 0x1B ']' ... BEL or ESC (the terminating ESC belongs to the NEXT
    \\/// sequence).  Anything else: a 2-byte escape.  Running off the end just
    \\/// lands the caller on end-of-string.
    \\fn skipAnsi(s: []const u8, i: usize) usize {
    \\    const c1: u32 = if (i + 1 < s.len) s[i + 1] else 0xFFFF; // charCode -1 sentinel
    \\    if (c1 == 91) { // '['
    \\        return skipCsi(s, i + 2);
    \\    }
    \\    if (c1 == 93) { // ']'
    \\        return skipOsc(s, i + 2);
    \\    }
    \\    return i + 2;
    \\}
    \\
    \\/// Str.elm:256-268 skipCsi: consume until a final byte 0x40..0x7E.
    \\fn skipCsi(s: []const u8, j: usize) usize {
    \\    var k = j;
    \\    while (k < s.len) : (k += 1) {
    \\        if (s[k] >= 0x40 and s[k] <= 0x7E) return k + 1;
    \\    }
    \\    return k;
    \\}
    \\
    \\/// Str.elm:271-283 skipOsc: consume until BEL or ESC (ESC consumed).
    \\fn skipOsc(s: []const u8, j: usize) usize {
    \\    var k = j;
    \\    while (k < s.len) : (k += 1) {
    \\        if (s[k] == 7 or s[k] == 27) return k + 1;
    \\    }
    \\    return k;
    \\}
    \\
;
