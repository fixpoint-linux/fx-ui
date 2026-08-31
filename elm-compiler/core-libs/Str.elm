module Str exposing
    ( split
    , lines
    , repeat
    , padLeft
    , padRight
    , replace
    , width
    , truncate
    , contains
    , startsWith
    , endsWith
    , cut
    , trim
    , countChar
    , fromFloat
    )

{-| M-FOUNDATION S1: the string toolkit lipgloss + widgets need, written in
the compiler's own subset (plain recursion, case/if, String.append/sliceLen/
length/charCode, Bitwise) over EXISTING VM prims — no new VM prims.

Representation ground truth this module is built on:

  * `String.length` is the BYTE length (c-strlen), not a rune count.
  * `String.sliceLen start len str` is the clamped byte-window `substring`
    prim (NOT real Elm's (start, end) String.slice).
  * `charCode str i` is the byte at index i, or -1 out of bounds.
  * `width` is TERMINAL CELL width: every op that mixes lengths and cells
    goes through `Str.width`, never `String.length` (repeat/slice arithmetic
    on multibyte content is the classic bug this avoids).

Deviations from elm/core String (all forced by the byte-string prim model,
all harmless for the terminal-UI consumers):

  * `split "" s` returns `[ s ]` (elm/core would split into 1-char strings);
    `lines` is Go strings.Split(s, "\n") parity — a trailing \n yields a
    trailing "" — because lipgloss's line splitter is strings.Split.
  * `replace "" x s` is the identity (elm/core would insert between every
    rune).
  * `padLeft/padRight` pad to CELL width with spaces only (lipgloss parity:
    its whitespace is 1-cell spaces, so padding count == cell count).
  * no grapheme clustering: `width` counts per code point with runewidth-style
    range tables (ZWJ emoji families overcount — the same class of issue
    x/ansi has; documented).
  * `fromFloat` rides the VM `str` prim (shortest-roundtrip {d} + mandatory
    ".0" when integral) through a TRUSTED body — the same trusted-lie pattern
    as `Prelude.fromInt` riding `cn`.
-}


-- ====================== splitting / joining ======================


split : String -> String -> List String
split sep s =
    if String.length sep == 0 then
        s :: []

    else
        splitGo sep s 0 0 []


{-| Byte-naive forward scan: at each index first try the separator, else
advance one byte. Segments accumulate REVERSED (right acc) and `reverse`
fixes the order once, at the end.
-}
splitGo sep s start i acc =
    if matchAt sep s i then
        let
            n =
                String.length sep
        in
        splitGo sep s (i + n) (i + n) (String.sliceLen start (i - start) s :: acc)

    else if charCode s i == -1 then
        reverse (String.sliceLen start (i - start) s :: acc)

    else
        splitGo sep s start (i + 1) acc


matchAt sep s i =
    matchGo sep s i 0


matchGo sep s i k =
    let
        c =
            charCode sep k
    in
    if c == -1 then
        True

    else if charCode s (i + k) /= c then
        False

    else
        matchGo sep s i (k + 1)


{-| Go strings.Split(s, "\n") parity (see module deviations): a trailing \n
KEEPS its trailing "" segment — lipgloss walks lines exactly that way.
-}
lines : String -> List String
lines s =
    split "\n" s


replace : String -> String -> String -> String
replace needle repl hay =
    String.join repl (split needle hay)


-- ====================== padding / repetition ======================


{-| Repeat `s` `n` times (negative n repeats nothing).

Rides the native VM `repeat` prim (ONE allocRaw(slen*n+1), filled by
doubling) instead of the old tail-accumulator loop — which did n x
String.append (n allocations + quadratic byte copy) and was the hot path
behind Lipgloss padding/borders and the Progress bar fill.  TRUSTED body:
the alias `repeatPrim` is typed Int -> String -> String, matching this
annotation, so the body is skipped by Type.Builtins.trustedBodies (same
pattern as Str.fromFloat riding `str`).
-}
repeat : Int -> String -> String
repeat n s =
    repeatPrim n s


{-| Pad to CELL width (`Str.width`, not String.length) with 1-cell spaces, so
the padding count equals the cell deficit — lipgloss parity.
-}
padLeft : Int -> String -> String
padLeft w s =
    let
        d =
            w - width s
    in
    if d <= 0 then
        s

    else
        String.append (repeat d " ") s


padRight : Int -> String -> String
padRight w s =
    let
        d =
            w - width s
    in
    if d <= 0 then
        s

    else
        String.append s (repeat d " ")


-- ====================== cell width ======================


{-| Terminal CELL width of s: walks BYTES, skipping ANSI escape sequences
(CSI + OSC, so nested styled strings measure correctly), decoding UTF-8 code
points by lead byte, and summing runewidth-style widths: combining -> 0,
wide (East Asian + emoji blocks) -> 2, control -> 0, everything else -> 1.
-}
width : String -> Int
width s =
    widthGo s 0 0


widthGo s i acc =
    let
        c =
            charCode s i
    in
    if c == -1 then
        acc

    else if c == 27 then
        widthGo s (skipAnsi s i) acc

    else
        widthGo s (i + 1 + runeNeed c) (acc + runeWidth (decodeRune s i c))


{-| Continuation bytes to fold after lead byte c. A stray continuation byte
(0x80..0xBF, only possible in invalid UTF-8) is measured raw and advanced by
one — garbage-in tolerated, never a hang.
-}
runeNeed c =
    if c < 128 then
        0

    else if c < 192 then
        0

    else if c < 224 then
        1

    else if c < 240 then
        2

    else
        3


decodeRune s i c =
    if c < 128 then
        c

    else if c < 192 then
        c

    else if c < 224 then
        foldCont (Bitwise.and c 31) s (i + 1) 1

    else if c < 240 then
        foldCont (Bitwise.and c 15) s (i + 1) 2

    else
        foldCont (Bitwise.and c 7) s (i + 1) 3


foldCont cp s j k =
    if k <= 0 then
        cp

    else
        foldCont (cp * 64 + Bitwise.and (charCode s j) 63) s (j + 1) (k - 1)


{-| Index AFTER the escape sequence starting at i (i is the ESC byte).
CSI: 0x1B '[' ... final byte 0x40..0x7E. OSC: 0x1B ']' ... BEL or ESC (the
terminating ESC belongs to the NEXT sequence). Anything else: 2-byte escape.
Running off the end just lands the caller on a -1 byte.
-}
skipAnsi s i =
    let
        c1 =
            charCode s (i + 1)
    in
    if c1 == 91 then
        skipCsi s (i + 2)

    else if c1 == 93 then
        skipOsc s (i + 2)

    else
        i + 2


skipCsi s j =
    let
        c =
            charCode s j
    in
    if c == -1 then
        j

    else if c >= 64 && c <= 126 then
        j + 1

    else
        skipCsi s (j + 1)


skipOsc s j =
    let
        c =
            charCode s j
    in
    if c == -1 then
        j

    else if c == 7 || c == 27 then
        j + 1

    else
        skipOsc s (j + 1)


runeWidth cp =
    if cp < 32 || (cp >= 127 && cp < 160) then
        0

    else if cp >= 768 && inRanges cp combiningRanges then
        0

    else if cp >= 4352 && inRanges cp wideRanges then
        2

    else
        1


inRanges cp ranges =
    case ranges of
        ( lo, hi ) :: rest ->
            if cp >= lo && cp <= hi then
                True

            else
                inRanges cp rest

        [] ->
            False


{-| Zero-width ranges (runewidth parity, no grapheme clustering): combining
marks, zero-width spaces/joiners, variation selectors, combining diacriticals
for symbols.
-}
combiningRanges =
    [ ( 0x0300, 0x036F )
    , ( 0x200B, 0x200F )
    , ( 0x20D0, 0x20FF )
    , ( 0xFE00, 0xFE0F )
    ]


{-| Double-cell ranges (runewidth parity): Hangul jamo, CJK radicals/punct,
hiragana/katakana, CJK unified ext-A + main, Yi, Hangul syllables, CJK
compatibility ideographs, CJK compat forms, fullwidth forms, emoji blocks,
and the CJK ext-B/-C planes.
-}
wideRanges =
    [ ( 0x1100, 0x115F )
    , ( 0x2E80, 0x303E )
    , ( 0x3041, 0x33FF )
    , ( 0x3400, 0x4DBF )
    , ( 0x4E00, 0x9FFF )
    , ( 0xA000, 0xA4CF )
    , ( 0xAC00, 0xD7A3 )
    , ( 0xF900, 0xFAFF )
    , ( 0xFE30, 0xFE4F )
    , ( 0xFF00, 0xFF60 )
    , ( 0xFFE0, 0xFFE6 )
    , ( 0x1F300, 0x1F64F )
    , ( 0x1F900, 0x1F9FF )
    , ( 0x20000, 0x2FFFD )
    , ( 0x30000, 0x3FFFD )
    ]


-- ====================== truncation ======================


{-| Cut s at `budget` cells (x/ansi.Truncate with no tail): escape sequences
are zero-width and copied verbatim (the walk never counts their bytes), the
first rune that would overflow ends the walk, and if any escape was copied a
trailing reset is appended so styling cannot bleed past the cut.
-}
truncate : Int -> String -> String
truncate budget s =
    truncGo s 0 budget "" False


truncGo s i budget acc sgr =
    let
        c =
            charCode s i
    in
    if c == -1 then
        acc

    else if c == 27 then
        let
            end =
                skipAnsi s i
        in
        truncGo s end budget (String.append acc (String.sliceLen i (end - i) s)) True

    else if budget - runeWidth (decodeRune s i c) < 0 then
        if sgr then
            String.append acc "\u{1B}[0m"

        else
            acc

    else
        let
            need =
                runeNeed c
        in
        truncGo s (i + 1 + need) (budget - runeWidth (decodeRune s i c)) (String.append acc (String.sliceLen i (1 + need) s)) sgr


{-| Cell window [start, end) of s (x/ansi.Cut parity): escape sequences are
copied verbatim wherever they occur (they are zero-width, before the window,
inside it and after it), a rune is kept iff its cumulative END cell is
`> start` and `<= end` — so a wide rune never straddles `end`, but one
straddling `start` IS kept (the same boundary rules x/ansi applies),
`end <= start` cuts everything.  The viewport's horizontal scroll and the
textarea's line slicing both render through this.

Documented deviation: x/ansi re-emits carried SGR state at the cut edges;
we do not — SGR state does not carry across a cut here.
-}
cut : Int -> Int -> String -> String
cut start end s =
    if end <= start then
        ""

    else
        cutGo s 0 0 start end ""


cutGo s i cell start end acc =
    let
        c =
            charCode s i
    in
    if c == -1 then
        acc

    else if c == 27 then
        let
            e =
                skipAnsi s i
        in
        cutGo s e cell start end (String.append acc (String.sliceLen i (e - i) s))

    else
        let
            need =
                runeNeed c

            cellEnd =
                cell + runeWidth (decodeRune s i c)

            piece =
                String.sliceLen i (1 + need) s
        in
        if cellEnd <= end && (start <= 0 || cellEnd > start) then
            cutGo s (i + 1 + need) cellEnd start end (String.append acc piece)

        else
            cutGo s (i + 1 + need) cellEnd start end acc


-- ====================== affixes / whitespace ======================


startsWith : String -> String -> Bool
startsWith pre s =
    matchAt pre s 0


endsWith : String -> String -> Bool
endsWith suf s =
    let
        off =
            String.length s - String.length suf
    in
    if off < 0 then
        False

    else
        matchAt suf s off


{-| Substring test (Go strings.Contains / elm/core String.contains parity):
the splitter's byte-naive `matchAt` anchored at every index.  `contains "" s`
is True (the empty needle matches at index 0).  Matching is byte-naive, the
same scan strings.Contains does — a valid UTF-8 needle never matches across a
rune boundary.
-}
contains : String -> String -> Bool
contains needle hay =
    containsGo needle hay 0


containsGo needle hay i =
    if matchAt needle hay i then
        True

    else if charCode hay i == -1 then
        False

    else
        containsGo needle hay (i + 1)


{-| Strip ASCII whitespace bytes (space, tab, \n, \r) from both ends. Byte
indices from each side; UTF-8 continuation bytes are >= 0x80 so multibyte
content is never damaged.
-}
trim : String -> String
trim s =
    trimGo s 0 (String.length s - 1)


trimGo s i j =
    if i <= j && isSpaceByte (charCode s i) then
        trimGo s (i + 1) j

    else if i <= j && isSpaceByte (charCode s j) then
        trimGo s i (j - 1)

    else
        String.sliceLen i (j - i + 1) s


isSpaceByte c =
    c == 32 || c == 9 || c == 10 || c == 13


{-| Count occurrences of a 1-byte character (the '\n' counter lipgloss's
height/margin arithmetic needs).  TRUSTED body: a Char lowers to its 1-byte
string but the checker's `charCode` scheme says String, so the Char -> String
step is a representational lie the checker must not see (same pattern as
Str.fromFloat below) — at runtime the comparison byte is c's first (only)
byte.
-}
countChar : Char -> String -> Int
countChar c s =
    countGo s (charCode c 0) 0 0


countGo s byte i acc =
    let
        b =
            charCode s i
    in
    if b == -1 then
        acc

    else if b == byte then
        countGo s byte (i + 1) (acc + 1)

    else
        countGo s byte (i + 1) acc


-- ====================== number rendering ======================


{-| Float -> String via the VM `str` prim (shortest-roundtrip decimal,
with a mandatory ".0" when integral: 2.0 -> "2.0").  TRUSTED body, same
pattern as `Prelude.fromInt` riding `cn`: the alias `strPrim` is typed
String -> String (a lie the checker cannot see through) so the body is
skipped by Type.Builtins.trustedBodies and only the annotation survives.
-}
fromFloat : Float -> String
fromFloat f =
    strPrim f
