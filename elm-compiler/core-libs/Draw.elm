module Draw exposing
    ( Frame
    , Row
    , Span(..)
    , colorNo
    , packAnsi
    , packAnsi256
    , packRgb
    , attrBold
    , attrFaint
    , attrItalic
    , attrUnderline
    , attrBlink
    , attrReverse
    , attrStrikethrough
    , text
    , frameEq
    , fromAnsi
    , fromAnsiLog
    , toAnsi
    , dumpFrame
    )

{-| P1 (photon-gui plan, DESIGN A): the Elm-built DrawList — the render API
that crosses the Elm<->host seam.  A Frame is a CELL-GRID core: one Row per
terminal row, one Span per styled run.  Span is an ADT CTOR (not a record:
records lower to assoc-lists, ctors to vector[tag args...] — the form the host
already decodes via symSlice, src/effectloop.zig buildKeyArg discipline).

Colors are PACKED INTs matching the Lipgloss.Color ctors (Lipgloss.elm
ColorNo|ColorAnsi|ColorAnsi256|ColorRgb): -1 = none, 0..255 = palette (16-color
subset rides the same range), 0x1000000+ = RGB24.  attrBits is the Lipgloss
Int-bitmask idiom (Style.props/attrs): bit SET = attribute ON; the constants
below are the SGR codes the parser accepts, one bit each.

fromAnsi is a CLOSED-SUBSET SGR parser: it reads ONLY the SGR sequences
Lipgloss.sgr emits (bold 1, faint 2, italic 3, underline 4, blink 5, reverse
7, strikethrough 9, fgSeq/bgSeq 30..37/90..97/38;5/38;2/40..47/100..107/
48;5/48;2, reset 0/empty) plus the control escapes Tea.paint emits
(cursor addressing \e[r;1H, clear-line \e[2K) and any other CSI/OSC, which
are skipped WITHOUT changing style (they end the text run, so control bytes
never leak into span text).  The scanner reuses the
escEnd/skipCsi/skipOsc approach from Lipgloss.elm.

toAnsi is the round-trip TWIN: toAnsi emits ONE explicit style prefix per span
(a bare \e[0m for a default-style span — the flush boundary fromAnsi needs to
keep adjacent same-style spans separate), so for EVERY frame f:

    frameEq (fromAnsi (toAnsi f)) f == True

That makes the pair its own test oracle (render -> fromAnsi -> toAnsi ->
fromAnsi == id) and the P4 terminal-parity baseline.  Emission is canonical,
not minimal: attrs in bit order 1;2;3;4;5;7;9, then fg, then bg — the parser
is order-independent so any SGR is accepted on input.
-}


type alias Frame =
    List Row


type alias Row =
    List Span


{-| One styled run of one row: (text, fgCode, bgCode, attrBits).  text carries
no escapes and no newline (a view row must be pre-split — the Tea view
contract).
-}
type Span
    = Span String Int Int Int


-- ====================== color packing (Lipgloss.Color parity) ======================


colorNo =
    -1


{-| ColorAnsi n AND ColorAnsi256 n pack to the same 0..255 range: the packed
form is deliberately coarser than the ctor (a render re-parses either SGR
spelling to the same span, so the round-trip oracle stays closed).
-}
packAnsi n =
    n


packAnsi256 n =
    n


{-| ColorRgb r g b -> 0x1000000 bor RGB24 (16777216 = 0x1000000).
-}
packRgb r g b =
    16777216 + (r * 65536) + (g * 256) + b


-- ====================== attribute bits (one per SGR code) ======================


attrBold =
    1


attrFaint =
    2


attrItalic =
    4


attrUnderline =
    8


attrBlink =
    16


attrReverse =
    32


attrStrikethrough =
    64


{-| A default-style span.
-}
text : String -> Span
text t =
    Span t colorNo colorNo 0


{-| Structural equality over any frame (the trusted sameValue prim — `==` is
comparable-only in this subset).  The damage-diff equality for a GUI host.
-}
frameEq : Frame -> Frame -> Bool
frameEq a b =
    sameValue a b


-- ====================== fromAnsi: the closed-subset SGR parser ======================


fromAnsi : List String -> Frame
fromAnsi rows =
    fromRows rows []


fromRows rows acc =
    case rows of
        [] ->
            reverse acc

        row :: rest ->
            -- Every input string is one row — an empty string stays an empty
            -- row (frame geometry must match the terminal row count).
            fromRows rest (reverse (parseRow row emptySgr 0 0 []) :: acc)


{-| Parser style state (fg/bg packed + attr bits).
-}
type alias Sgr =
    { fg : Int
    , bg : Int
    , attrs : Int
    }


emptySgr =
    { fg = colorNo, bg = colorNo, attrs = 0 }


{-| Walk one row byte-wise (charCode returns -1 past the end).  `start`/`i`
bound the current plain-text run: an SGR flushes it as a span and switches
style; any other escape (cursor addressing, clear-line, OSC) flushes WITHOUT
switching style and skips the escape bytes, so control sequences never leak
into span text.
-}
parseRow : String -> Sgr -> Int -> Int -> List Span -> List Span
parseRow s st start i acc =
    let
        c =
            charCode s i
    in
    if c == -1 then
        flushRun s st start i acc

    else if c == 27 then
        let
            j =
                escEnd s i
        in
        if isSgrAt s i (j - i) then
            let
                acc1 =
                    flushRun s st start i acc

                st1 =
                    applySgr (sgrParams s (i + 2) (j - 1) 0 []) st
            in
            parseRow s st1 j j acc1

        else
            parseRow s st j j (flushRun s st start i acc)

    else
        parseRow s st start (i + 1) acc


{-| Emit the run [start, i) as a span iff non-empty; returns the acc consed.
-}
flushRun : String -> Sgr -> Int -> Int -> List Span -> List Span
flushRun s st start i acc =
    if i <= start then
        acc

    else
        Span (String.sliceLen start (i - start) s) st.fg st.bg st.attrs :: acc


{-| True iff s[i..i+len) is an SGR the parser owns: `ESC [ <digits/;> m`.
Everything else (\e[?25l, \e[2K, \e[J, \e]OSC...) fails the charset test and
is skipped whole.
-}
isSgrAt : String -> Int -> Int -> Bool
isSgrAt s i len =
    if len < 3 then
        False

    else if charCode s (i + 1) /= 91 then
        False

    else if charCode s (i + len - 1) /= 109 then
        False

    else
        sgrDigits s (i + 2) (i + len - 1)


sgrDigits : String -> Int -> Int -> Bool
sgrDigits s lo hi =
    if lo >= hi then
        True

    else
        let
            c =
                charCode s lo
        in
        if (c >= 48 && c <= 57) || c == 59 then
            sgrDigits s (lo + 1) hi

        else
            False


{-| Split the param section [i, end) on ';' into Ints (an empty field is SGR 0,
so `\e[m` parses to [0] = reset — exactly its C-terminal meaning).
-}
sgrParams : String -> Int -> Int -> Int -> List Int -> List Int
sgrParams s i end cur acc =
    if i >= end then
        reverse (cur :: acc)

    else
        let
            c =
                charCode s i
        in
        if c == 59 then
            sgrParams s (i + 1) end 0 (cur :: acc)

        else
            sgrParams s (i + 1) end ((cur * 10) + (c - 48)) acc


applySgr : List Int -> Sgr -> Sgr
applySgr params st =
    case params of
        [] ->
            st

        p :: rest ->
            if p == 0 then
                applySgr rest emptySgr

            else if p == 1 then
                applySgr rest { st | attrs = Bitwise.or st.attrs attrBold }

            else if p == 2 then
                applySgr rest { st | attrs = Bitwise.or st.attrs attrFaint }

            else if p == 3 then
                applySgr rest { st | attrs = Bitwise.or st.attrs attrItalic }

            else if p == 4 then
                applySgr rest { st | attrs = Bitwise.or st.attrs attrUnderline }

            else if p == 5 then
                applySgr rest { st | attrs = Bitwise.or st.attrs attrBlink }

            else if p == 7 then
                applySgr rest { st | attrs = Bitwise.or st.attrs attrReverse }

            else if p == 9 then
                applySgr rest { st | attrs = Bitwise.or st.attrs attrStrikethrough }

            else if p == 22 then
                applySgr rest { st | attrs = clearAttrs st.attrs (Bitwise.or attrBold attrFaint) }

            else if p == 23 then
                applySgr rest { st | attrs = clearAttrs st.attrs attrItalic }

            else if p == 24 then
                applySgr rest { st | attrs = clearAttrs st.attrs attrUnderline }

            else if p == 25 then
                applySgr rest { st | attrs = clearAttrs st.attrs attrBlink }

            else if p == 27 then
                applySgr rest { st | attrs = clearAttrs st.attrs attrReverse }

            else if p == 29 then
                applySgr rest { st | attrs = clearAttrs st.attrs attrStrikethrough }

            else if p >= 30 && p <= 37 then
                applySgr rest { st | fg = p - 30 }

            else if p == 39 then
                applySgr rest { st | fg = colorNo }

            else if p >= 40 && p <= 47 then
                applySgr rest { st | bg = p - 40 }

            else if p == 49 then
                applySgr rest { st | bg = colorNo }

            else if p >= 90 && p <= 97 then
                applySgr rest { st | fg = (p - 90) + 8 }

            else if p >= 100 && p <= 107 then
                applySgr rest { st | bg = (p - 100) + 8 }

            else if p == 38 then
                case rest of
                    n :: rest1 ->
                        if n == 5 then
                            case rest1 of
                                v :: rest2 ->
                                    applySgr rest2 { st | fg = packAnsi256 v }

                                [] ->
                                    st

                        else if n == 2 then
                            case rest1 of
                                r :: g :: b :: rest2 ->
                                    applySgr rest2 { st | fg = packRgb r g b }

                                _ ->
                                    st

                        else
                            st

                    [] ->
                        st

            else if p == 48 then
                case rest of
                    n :: rest1 ->
                        if n == 5 then
                            case rest1 of
                                v :: rest2 ->
                                    applySgr rest2 { st | bg = packAnsi256 v }

                                [] ->
                                    st

                        else if n == 2 then
                            case rest1 of
                                r :: g :: b :: rest2 ->
                                    applySgr rest2 { st | bg = packRgb r g b }

                                _ ->
                                    st

                        else
                            st

                    [] ->
                        st

            else
                -- Unknown code: ignore (the closed subset keeps growing safely).
                applySgr rest st


clearAttrs attrs mask =
    Bitwise.and attrs (Bitwise.complement mask)


-- ANSI escape scanner (Lipgloss.elm escEnd/skipCsi/skipOsc, byte-identical):
-- return the index just past the escape at i (i points at ESC).


escEnd : String -> Int -> Int
escEnd s i =
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


skipCsi : String -> Int -> Int
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


skipOsc : String -> Int -> Int
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


-- ====================== toAnsi: the round-trip twin ======================


csi =
    "\u{1B}["


reset =
    "\u{1B}[0m"


toAnsi : Frame -> List String
toAnsi frame =
    map toRowString frame


toRowString : Row -> String
toRowString row =
    joinSpans row ""


joinSpans : Row -> String -> String
joinSpans row acc =
    case row of
        [] ->
            acc

        sp :: rest ->
            case sp of
                Span t fg bg attrs ->
                    joinSpans rest
                        (String.append acc
                            (String.append (spanPrefix fg bg attrs) t)
                        )


{-| ONE explicit style prefix per span — \e[0m for a default span.  The
prefix is the flush boundary fromAnsi needs, so toAnsi (fromAnsi x) re-parses
to the identical frame even for adjacent same-style spans.
-}
spanPrefix : Int -> Int -> Int -> String
spanPrefix fg bg attrs =
    if fg == colorNo && bg == colorNo && attrs == 0 then
        reset

    else
        String.append csi
            (String.append (String.join ";" (spanParams fg bg attrs)) "m")


{-| Canonical param order: attrs in bit order, then fg, then bg (the parser is
order-independent; this is the P4 parity baseline).
-}
spanParams : Int -> Int -> Int -> List String
spanParams fg bg attrs =
    reverse
        (appendIf (bg /= colorNo) (bgSeqOf bg)
            (appendIf (fg /= colorNo) (fgSeqOf fg)
                (appendIf (Bitwise.and attrs attrStrikethrough /= 0) "9"
                    (appendIf (Bitwise.and attrs attrReverse /= 0) "7"
                        (appendIf (Bitwise.and attrs attrBlink /= 0) "5"
                            (appendIf (Bitwise.and attrs attrUnderline /= 0) "4"
                                (appendIf (Bitwise.and attrs attrItalic /= 0) "3"
                                    (appendIf (Bitwise.and attrs attrFaint /= 0) "2"
                                        (appendIf (Bitwise.and attrs attrBold /= 0) "1" [])
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )


appendIf : Bool -> String -> List String -> List String
appendIf cond x acc =
    if cond then
        x :: acc

    else
        acc


{-| Packed color -> SGR body, Lipgloss.fgSeq/bgSeq byte-parity: 0..7 = 30+n /
40+n, 8..15 = 90+(n-8) / 100+(n-8), 16..255 = 38;5;n / 48;5;n, packed RGB =
38;2;r;g;b / 48;2;r;g;b.
-}
fgSeqOf : Int -> String
fgSeqOf c =
    if c < 8 then
        String.fromInt (30 + c)

    else if c < 16 then
        String.fromInt (90 + (c - 8))

    else if c < 256 then
        String.append "38;5;" (String.fromInt c)

    else
        String.append "38;2;" (rgbBody c)


bgSeqOf : Int -> String
bgSeqOf c =
    if c < 8 then
        String.fromInt (40 + c)

    else if c < 16 then
        String.fromInt (100 + (c - 8))

    else if c < 256 then
        String.append "48;5;" (String.fromInt c)

    else
        String.append "48;2;" (rgbBody c)


rgbBody : Int -> String
rgbBody c =
    let
        rgb =
            c - 16777216
    in
    String.append (String.fromInt (Bitwise.and (Bitwise.shiftRightZfBy 16 rgb) 255))
        (String.append ";"
            (String.append (String.fromInt (Bitwise.and (Bitwise.shiftRightZfBy 8 rgb) 255))
                (String.append ";" (String.fromInt (Bitwise.and rgb 255)))
            )
        )


-- ====================== fromAnsiLog: the SGR-event-log parser ======================


{-| P4 TERMINAL-SEAM twin of fromAnsi: same closed-subset scanner, but every
SGR EVENT also lands in the frame as a ZERO-WIDTH MARKER span (empty text,
the event's params packed as a Span tuple).  The host TerminalRenderer
replays markers as the exact SGR bytes and emits text runs BARE, so

    encodeRow (fromAnsiLog row) == row        (byte-for-byte)

for every row the Lipgloss piece grammar produces — INCLUDING nested pieces
(an outer style wrapping pre-styled content: stacked prefixes with no
intermediate reset, stacked trailing resets), which the plain cell-grid
fromAnsi flattens away (the stacked bytes paint zero cells: the GUI backend
rightly ignores them, the terminal byte stream must keep them).

Only fromAnsiLog rows carry markers (every styled run is preceded by its
event), so a row WITH a marker is unambiguous: the host replays; a row
WITHOUT (plain fromAnsi, toAnsi output, hand-built) renders piece-style.
The marker vocabulary is the closed emitter subset: SGR 0 (default marker),
attrs 1/2/3/4/5/7/9, fg/bg 30..37/39/40..47/49/90..97/100..107/38;5/38;2/
48;5/48;2, and the attr-clear codes 22..29 packed as attrLogClear + code
(no corpus emitter uses them today; kept so a marker never lies).
-}
attrLogClear =
    4096


fromAnsiLog : List String -> Frame
fromAnsiLog rows =
    fromRowsLog rows []


fromRowsLog rows acc =
    case rows of
        [] ->
            reverse acc

        row :: rest ->
            fromRowsLog rest (reverse (parseRowLog row emptySgr 0 0 []) :: acc)


{-| parseRow with event markers: an SGR flushes the pending run (with the
CURRENT style, exactly like parseRow), then appends the event's marker span,
then applies the params.  Any other escape is skipped unchanged (no marker,
no text — control bytes never leak into span text).
-}
parseRowLog : String -> Sgr -> Int -> Int -> List Span -> List Span
parseRowLog s st start i acc =
    let
        c =
            charCode s i
    in
    if c == -1 then
        flushRun s st start i acc

    else if c == 27 then
        let
            j =
                escEnd s i
        in
        if isSgrAt s i (j - i) then
            let
                params =
                    sgrParams s (i + 2) (j - 1) 0 []

                acc1 =
                    if j - 1 == i + 2 then
                        -- `\e[m` (EMPTY param section — the wrap machine's
                        -- ResetStyle, Lipgloss.elm:943): replay it verbatim,
                        -- never as the `\e[0m` a literal 0 would be.
                        Span "" colorNo colorNo attrLogClear
                            :: flushRun s st start i acc

                    else
                        sgrMarker params :: flushRun s st start i acc

                st1 =
                    applySgr params st
            in
            parseRowLog s st1 j j acc1

        else
            parseRowLog s st j j (flushRun s st start i acc)

    else
        parseRowLog s st start (i + 1) acc


{-| Pack one SGR event's params as a marker span (empty text).  Attr-adds
set their bit, colors set their slot, 0 makes the DEFAULT marker (the host
replays it as the reset the event was), attr-clears pack attrLogClear + the
SGR code, unknown codes contribute nothing.
-}
sgrMarker : List Int -> Span
sgrMarker params =
    let
        m =
            markerDelta params emptyMarker
    in
    Span "" m.fg m.bg m.attrs


type alias Marker =
    { fg : Int
    , bg : Int
    , attrs : Int
    }


emptyMarker =
    { fg = colorNo
    , bg = colorNo
    , attrs = 0
    }


-- SGR attr code -> Draw attr bit (0 = not an attr code in the corpus set).
attrBitOf p =
    if p == 1 then
        attrBold

    else if p == 2 then
        attrFaint

    else if p == 3 then
        attrItalic

    else if p == 4 then
        attrUnderline

    else if p == 5 then
        attrBlink

    else if p == 7 then
        attrReverse

    else if p == 9 then
        attrStrikethrough

    else
        0


markerDelta : List Int -> Marker -> Marker
markerDelta params m =
    case params of
        [] ->
            m

        p :: rest ->
            if p == 0 then
                markerDelta rest emptyMarker

            else if attrBitOf p /= 0 then
                -- attrs 1,2,3,4,5,7,9 mapped to their Draw attrBITS (the
                -- bits are NOT the SGR codes: italic 3->4, underline 4->8,
                -- blink 5->16, reverse 7->32, strike 9->64)
                markerDelta rest { m | attrs = Bitwise.or m.attrs (attrBitOf p) }

            else if (p >= 22 && p <= 25) || p == 27 || p == 29 then
                -- attr-clear codes: attrLogClear + the code (21/26/28 are
                -- outside the corpus set; 22/23/24/25/27/29 replay raw)
                markerDelta rest { m | attrs = Bitwise.or m.attrs (Bitwise.or attrLogClear p) }

            else if p >= 30 && p <= 37 then
                markerDelta rest { m | fg = p - 30 }

            else if p == 39 then
                markerDelta rest { m | fg = colorNo }

            else if p >= 40 && p <= 47 then
                markerDelta rest { m | bg = p - 40 }

            else if p == 49 then
                markerDelta rest { m | bg = colorNo }

            else if p >= 90 && p <= 97 then
                markerDelta rest { m | fg = (p - 90) + 8 }

            else if p >= 100 && p <= 107 then
                markerDelta rest { m | bg = (p - 100) + 8 }

            else if p == 38 then
                case rest of
                    5 :: v :: rest2 ->
                        markerDelta rest2 { m | fg = v }

                    2 :: r :: g :: b :: rest2 ->
                        markerDelta rest2 { m | fg = packRgb r g b }

                    _ ->
                        m

            else if p == 48 then
                case rest of
                    5 :: v :: rest2 ->
                        markerDelta rest2 { m | bg = v }

                    2 :: r :: g :: b :: rest2 ->
                        markerDelta rest2 { m | bg = packRgb r g b }

                    _ ->
                        m

            else
                markerDelta rest m


-- ====================== dumpFrame: the structure oracle ======================


{-| One line per row: `r<n>: fg=.. bg=.. attrs=.. "<text>" | ...`.  Pure
debug/oracle text (the Elm-side twin of the host's --render-dump stderr dump,
with printable-ASCII escaping so each line stays a safe physical line).
-}
dumpFrame : Frame -> String
dumpFrame frame =
    String.join "\n" (reverse (dumpLines 0 frame []))


dumpLines : Int -> Frame -> List String -> List String
dumpLines r frame acc =
    case frame of
        [] ->
            acc

        row :: rest ->
            dumpLines (r + 1)
                rest
                (String.append "r"
                    (String.append (String.fromInt r)
                        (String.append ": " (dumpSpans row))
                    )
                    :: acc
                )


dumpSpans : Row -> String
dumpSpans row =
    String.join " | " (map dumpSpan row)


dumpSpan : Span -> String
dumpSpan sp =
    case sp of
        Span t fg bg attrs ->
            String.append "fg="
                (String.append (String.fromInt fg)
                    (String.append " bg="
                        (String.append (String.fromInt bg)
                            (String.append " attrs="
                                (String.append (String.fromInt attrs)
                                    (String.append " " (quoteEsc t))
                                )
                            )
                        )
                    )
                )


{-| Quote a span's text with printable-ASCII escaping (control bytes -> \xNN,
quote/backslash escaped) so a dump line is always one safe physical line.
-}
quoteEsc : String -> String
quoteEsc s =
    quoteEscGo s 0 (String.length s) "\""


quoteEscGo : String -> Int -> Int -> String -> String
quoteEscGo s i len acc =
    if i >= len then
        String.append acc "\""

    else
        let
            c =
                charCode s i
        in
        if c == 34 then
            quoteEscGo s (i + 1) len (String.append acc "\\\"")

        else if c == 92 then
            quoteEscGo s (i + 1) len (String.append acc "\\\\")

        else if c >= 32 && c < 127 then
            quoteEscGo s (i + 1) len (String.append acc (String.sliceLen i 1 s))

        else
            quoteEscGo s (i + 1) len (String.append acc (escByte c))


escByte : Int -> String
escByte c =
    String.append "\\x"
        (String.append (hexDigit (Bitwise.shiftRightZfBy 4 c)) (hexDigit (Bitwise.and c 15)))


hexDigit : Int -> String
hexDigit c =
    if c < 10 then
        String.fromInt c

    else
        String.sliceLen (c - 10) 1 "abcdef"
