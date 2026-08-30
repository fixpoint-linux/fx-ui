module Lipgloss exposing
    ( Style
    , Border
    , Pos(..)
    , Color(..)
    , newStyle
    , noColor
    , color
    , colorBlack
    , colorRed
    , colorGreen
    , colorYellow
    , colorBlue
    , colorMagenta
    , colorCyan
    , colorWhite
    , colorBrightBlack
    , colorBrightRed
    , colorBrightGreen
    , colorBrightYellow
    , colorBrightBlue
    , colorBrightMagenta
    , colorBrightCyan
    , colorBrightWhite
    , normalBorder
    , roundedBorder
    , blockBorder
    , outerHalfBlockBorder
    , innerHalfBlockBorder
    , thickBorder
    , doubleBorder
    , hiddenBorder
    , markdownBorder
    , asciiBorder
    , bold
    , italic
    , underline
    , strikethrough
    , reverse
    , blink
    , faint
    , underlineSpaces
    , strikethroughSpaces
    , colorWhitespace
    , inline
    , borderTop
    , borderRight
    , borderBottom
    , borderLeft
    , foreground
    , background
    , marginBackground
    , borderTopForeground
    , borderRightForeground
    , borderBottomForeground
    , borderLeftForeground
    , borderTopBackground
    , borderRightBackground
    , borderBottomBackground
    , borderLeftBackground
    , setWidth
    , setHeight
    , alignHorizontal
    , alignVertical
    , paddingTop
    , paddingRight
    , paddingBottom
    , paddingLeft
    , marginTop
    , marginRight
    , marginBottom
    , marginLeft
    , padding
    , margin
    , borderStyle
    , border
    , maxWidth
    , maxHeight
    , tabWidth
    , setString
    , render
    , width
    , height
    , size
    , joinHorizontal
    , joinVertical
    , placeHorizontal
    , placeVertical
    )

{-| M-FOUNDATION S2: a faithful port of charmbracelet/lipgloss v1.1.0's Style
renderer, written in the compiler's own subset over the S1 Str toolkit (NO new
VM prims — Str.width/Str.lines/Str.repeat/Str.countChar are the load-bearing
cell-width ops; Bitwise Int masks reproduce Go's `props`/`attrs` int64 model;
everything here is PURE, nothing trusted).

The Render pipeline mirrors lg-style.go line-for-line:

  1. value prepend + join with a single space (Style.SetString);
  2. `props == 0` shortcut — ONLY tab-conversion (this is why even a
     foreground(NoColor) style differs from an untouched style: it skips the
     \r\n -> \n rewrite);
  3. SGR param list in the EXACT v1.1.0 order 1,3,4,7,5,2,fg,bg,4,9 — INCLUDING
     the duplicated underline-4 (lg-style.go:307+341) for byte parity;
  4. one SGR pair per line (`\e[<params>m TEXT \e[0m`), the empty line still
     emitting the pair; useSpaceStyler styles per-RUNE (spaces via teSpace);
  5. tab conversion (default 4, tabWidth -1 = off, 0 = strip);
     \r\n -> \n; inline strips \n;
  6. word wrap (cellbuf.Wrap) when width > 0, wrapAt = width - padL - padR;
  7. L/R padding (whitespace styled by teWhitespace when colorWhitespace or
     reverse), then T/B padding rows;
  8. height -> alignTextVertical (Int arithmetic);
  9. alignTextHorizontal pads every line to max(widest, width);
 10. applyBorder (corner suppression + first-rune corners + horizontal-edge
     middle cycling) then applyMargins (marginBg-styled spaces + full-width
     blank rows);
 11. maxWidth per-line truncate; maxHeight first-N-lines.

DEVIATIONS from v1.1.0 (all documented, none observable for the 10 border
styles + truecolor host):

  * NO Renderer/ColorProfile — the host is truecolor-only, so ANSI16/256 and
    truecolor render their own SGR directly (no profile degradation, no HSLuv
    nearest-color; CompleteColor/AdaptiveColor are out of subset).
  * NO WhitespaceOption (place*/join* pad with plain spaces only).
  * NO Transform, no Inherit, no Copy, no StyleRunes.
  * Pos is a 5-ctor ADT (PLeft/PRight/PTop/PBottom/PCenter) instead of a float
    0..1; only the 3 canonical stops (0/0.5/1) are used, so round(x*0.5) is
    integer `(x+1)//2` (remainder to the right/bottom, Go math.Round parity).
  * Single-string Render/setString (no variadic args).
  * Style.Width/Height methods are `setWidth`/`setHeight` because the package-
    level `width`/`height` measuring functions own those names (one namespace).
  * `width` is Str.width (cell width, ANSI-skip + runewidth tables, no grapheme
    clustering — the same class of issue x/ansi has; documented in Str.elm).
  * Border edges are SINGLE-rune in all 10 ctors, so the multi-rune left/right
    edge rune-cycling and the renderHorizontalEdge post-increment oddity
    collapse to `repeat (edgeWidth - leftWidth) middle`; a custom multi-rune
    Border is not exposed.  Unicode whitespace other than space/tab is treated
    as a glyph (not routed to the space styler / wrap space buffer).
  * Word-wrap carries the FULL accumulated SGR state across a break
    (cellbuf.ReadStyle: bare/`0` sequences reset, set/clear pairs and
    per-slot colors overwrite, extended colors 38/48/58 consume `5;N` /
    `2;r;g;b`), re-emitted at BOL in cellbuf's canonical Sequence order
    (attrs 1,2,3,5,6,7,8,9, underline style, fg, bg, ul) with the x/ansi
    reset `\e[m`.  Hyperlinks (OSC 8) are copied through but never tracked;
    colon sub-param color forms (38:5:N) are not tracked.
-}


-- ====================== types ======================


{-| A style is a plain record.  `props`/`attrs` are Int bitmasks (Go's
`props`/`attrs` int64 model compressed into int32): `props` marks WHICH
properties are set, `attrs` holds the boolean VALUES (bit set = true), so
`getAsBool key default` == `props&key==0 ? default : attrs&key!=0` exactly.
Value props that can only be "unset == zero-value" (colors via ColorNo, ints
via 0, align via PLeft/PTop) share one aggregate `anyValueKey` bit so the
`props == 0` shortcut stays exact; tabWidth keeps its own bit because -1 is a
meaningful set value distinct from the unset default of 4.
-}
type alias Style =
    { value : String
    , props : Int
    , attrs : Int
    , fg : Color
    , bg : Color
    , width : Int
    , height : Int
    , alignH : Pos
    , alignV : Pos
    , padTop : Int
    , padRight : Int
    , padBottom : Int
    , padLeft : Int
    , marginTop : Int
    , marginRight : Int
    , marginBottom : Int
    , marginLeft : Int
    , marginBg : Color
    , border : Maybe Border
    , borderTopFg : Color
    , borderRightFg : Color
    , borderBottomFg : Color
    , borderLeftFg : Color
    , borderTopBg : Color
    , borderRightBg : Color
    , borderBottomBg : Color
    , borderLeftBg : Color
    , maxWidth : Int
    , maxHeight : Int
    , tabWidth : Int
    }


type Pos
    = PLeft
    | PRight
    | PTop
    | PBottom
    | PCenter


type Color
    = ColorNo
    | ColorAnsi Int
    | ColorAnsi256 Int
    | ColorRgb Int Int Int


{-| `==` is comparable-only in this subset, so Color equality is a `case`.
-}
isNoColor c =
    case c of
        ColorNo ->
            True

        _ ->
            False


type alias Border =
    { top : String
    , bottom : String
    , left : String
    , right : String
    , topLeft : String
    , topRight : String
    , bottomLeft : String
    , bottomRight : String
    , middleLeft : String
    , middleRight : String
    , middle : String
    , middleTop : String
    , middleBottom : String
    }


-- ====================== property bitmasks ======================
-- (Go's 1<<iota keys; compressed: bool props keep distinct bits, every
-- non-bool value prop shares anyValueKey, tabWidth keeps its own bit.)


boldKey = 1

italicKey = 2

underlineKey = 4

strikethroughKey = 8

reverseKey = 16

blinkKey = 32

faintKey = 64

underlineSpacesKey = 128

strikethroughSpacesKey = 256

colorWhitespaceKey = 512

inlineKey = 1024

borderTopKey = 2048

borderRightKey = 4096

borderBottomKey = 8192

borderLeftKey = 16384

tabWidthKey = 32768

anyValueKey = 65536

borderSideMask =
    Bitwise.or (Bitwise.or borderTopKey borderRightKey) (Bitwise.or borderBottomKey borderLeftKey)


-- ====================== constructors ======================


newStyle =
    { value = ""
    , props = 0
    , attrs = 0
    , fg = ColorNo
    , bg = ColorNo
    , width = 0
    , height = 0
    , alignH = PLeft
    , alignV = PTop
    , padTop = 0
    , padRight = 0
    , padBottom = 0
    , padLeft = 0
    , marginTop = 0
    , marginRight = 0
    , marginBottom = 0
    , marginLeft = 0
    , marginBg = ColorNo
    , border = Nothing
    , borderTopFg = ColorNo
    , borderRightFg = ColorNo
    , borderBottomFg = ColorNo
    , borderLeftFg = ColorNo
    , borderTopBg = ColorNo
    , borderRightBg = ColorNo
    , borderBottomBg = ColorNo
    , borderLeftBg = ColorNo
    , maxWidth = 0
    , maxHeight = 0
    , tabWidth = -1
    }


noColor =
    ColorNo


-- ====================== color parsing (termenv Profile.Color parity) ======================


{-| Parse a color string: '#rrggbb' -> RGB, a decimal 'N' -> ANSI (N <= 15) or
ANSI256 (else), anything else (empty/non-numeric) -> NoColor.
-}
color : String -> Color
color s =
    if String.length s == 7 && charCode s 0 == 35 then
        let
            r =
                16 * hexVal (charCode s 1) + hexVal (charCode s 2)

            g =
                16 * hexVal (charCode s 3) + hexVal (charCode s 4)

            b =
                16 * hexVal (charCode s 5) + hexVal (charCode s 6)
        in
        if r >= 0 && g >= 0 && b >= 0 then
            ColorRgb r g b

        else
            ColorNo

    else if String.length s == 0 then
        ColorNo

    else
        let
            n =
                parseNat s 0 0
        in
        if n < 0 then
            ColorNo

        else if n <= 15 then
            ColorAnsi n

        else
            ColorAnsi256 n


hexVal c =
    if c >= 48 && c <= 57 then
        c - 48

    else if c >= 65 && c <= 70 then
        c - 55

    else if c >= 97 && c <= 102 then
        c - 87

    else
        -1


{-| Parse a decimal digit string (no sign); -1 on any non-digit byte.
-}
parseNat s i acc =
    let
        c =
            charCode s i
    in
    if c == -1 then
        acc

    else if c >= 48 && c <= 57 then
        parseNat s (i + 1) (acc * 10 + (c - 48))

    else
        -1


-- Named ANSI16 sugar (fx-ui extension; ColorAnsi 0..15).


colorBlack =
    ColorAnsi 0


colorRed =
    ColorAnsi 1


colorGreen =
    ColorAnsi 2


colorYellow =
    ColorAnsi 3


colorBlue =
    ColorAnsi 4


colorMagenta =
    ColorAnsi 5


colorCyan =
    ColorAnsi 6


colorWhite =
    ColorAnsi 7


colorBrightBlack =
    ColorAnsi 8


colorBrightRed =
    ColorAnsi 9


colorBrightGreen =
    ColorAnsi 10


colorBrightYellow =
    ColorAnsi 11


colorBrightBlue =
    ColorAnsi 12


colorBrightMagenta =
    ColorAnsi 13


colorBrightCyan =
    ColorAnsi 14


colorBrightWhite =
    ColorAnsi 15


-- ====================== borders (lg-borders.go:67-219) ======================


normalBorder =
    { top = "─"
    , bottom = "─"
    , left = "│"
    , right = "│"
    , topLeft = "┌"
    , topRight = "┐"
    , bottomLeft = "└"
    , bottomRight = "┘"
    , middleLeft = "├"
    , middleRight = "┤"
    , middle = "┼"
    , middleTop = "┬"
    , middleBottom = "┴"
    }


roundedBorder =
    { top = "─"
    , bottom = "─"
    , left = "│"
    , right = "│"
    , topLeft = "╭"
    , topRight = "╮"
    , bottomLeft = "╰"
    , bottomRight = "╯"
    , middleLeft = "├"
    , middleRight = "┤"
    , middle = "┼"
    , middleTop = "┬"
    , middleBottom = "┴"
    }


blockBorder =
    { top = "█"
    , bottom = "█"
    , left = "█"
    , right = "█"
    , topLeft = "█"
    , topRight = "█"
    , bottomLeft = "█"
    , bottomRight = "█"
    , middleLeft = "█"
    , middleRight = "█"
    , middle = "█"
    , middleTop = "█"
    , middleBottom = "█"
    }


outerHalfBlockBorder =
    { top = "▀"
    , bottom = "▄"
    , left = "▌"
    , right = "▐"
    , topLeft = "▛"
    , topRight = "▜"
    , bottomLeft = "▙"
    , bottomRight = "▟"
    , middleLeft = ""
    , middleRight = ""
    , middle = ""
    , middleTop = ""
    , middleBottom = ""
    }


innerHalfBlockBorder =
    { top = "▄"
    , bottom = "▀"
    , left = "▐"
    , right = "▌"
    , topLeft = "▗"
    , topRight = "▖"
    , bottomLeft = "▝"
    , bottomRight = "▘"
    , middleLeft = ""
    , middleRight = ""
    , middle = ""
    , middleTop = ""
    , middleBottom = ""
    }


thickBorder =
    { top = "━"
    , bottom = "━"
    , left = "┃"
    , right = "┃"
    , topLeft = "┏"
    , topRight = "┓"
    , bottomLeft = "┗"
    , bottomRight = "┛"
    , middleLeft = "┣"
    , middleRight = "┫"
    , middle = "╋"
    , middleTop = "┳"
    , middleBottom = "┻"
    }


doubleBorder =
    { top = "═"
    , bottom = "═"
    , left = "║"
    , right = "║"
    , topLeft = "╔"
    , topRight = "╗"
    , bottomLeft = "╚"
    , bottomRight = "╝"
    , middleLeft = "╠"
    , middleRight = "╣"
    , middle = "╬"
    , middleTop = "╦"
    , middleBottom = "╩"
    }


hiddenBorder =
    { top = " "
    , bottom = " "
    , left = " "
    , right = " "
    , topLeft = " "
    , topRight = " "
    , bottomLeft = " "
    , bottomRight = " "
    , middleLeft = " "
    , middleRight = " "
    , middle = " "
    , middleTop = " "
    , middleBottom = " "
    }


markdownBorder =
    { top = "-"
    , bottom = "-"
    , left = "|"
    , right = "|"
    , topLeft = "|"
    , topRight = "|"
    , bottomLeft = "|"
    , bottomRight = "|"
    , middleLeft = "|"
    , middleRight = "|"
    , middle = "|"
    , middleTop = "|"
    , middleBottom = "|"
    }


asciiBorder =
    { top = "-"
    , bottom = "-"
    , left = "|"
    , right = "|"
    , topLeft = "+"
    , topRight = "+"
    , bottomLeft = "+"
    , bottomRight = "+"
    , middleLeft = "+"
    , middleRight = "+"
    , middle = "+"
    , middleTop = "+"
    , middleBottom = "+"
    }


-- ====================== prop get/set helpers ======================


getAsBool : Int -> Bool -> Style -> Bool
getAsBool k d s =
    if Bitwise.and s.props k == 0 then
        d

    else
        Bitwise.and s.attrs k /= 0


setBool : Int -> Bool -> Style -> Style
setBool k v s =
    { s
        | props = Bitwise.or s.props k
        , attrs =
            if v then
                Bitwise.or s.attrs k

            else
                Bitwise.and s.attrs (Bitwise.complement k)
    }


{-| Clamp to >= 0 (Go's set() does max(0, v) for every int prop except
tabWidth).
-}
clamp0 n =
    if n < 0 then
        0

    else
        n


{-| Set a non-bool value prop: mark anyValueKey and write the field.
Annotated Style -> Style -> Style so the higher-order helper's param stays
concrete (unannotated it infers an open `{props:Int|r}` that never unifies
with the field-writing lambdas below).
-}
setValue : (Style -> Style) -> Style -> Style
setValue f s =
    f { s | props = Bitwise.or s.props anyValueKey }


-- ====================== boolean setters (style-last) ======================


bold v s =
    setBool boldKey v s


italic v s =
    setBool italicKey v s


underline v s =
    setBool underlineKey v s


strikethrough v s =
    setBool strikethroughKey v s


reverse v s =
    setBool reverseKey v s


blink v s =
    setBool blinkKey v s


faint v s =
    setBool faintKey v s


underlineSpaces v s =
    setBool underlineSpacesKey v s


strikethroughSpaces v s =
    setBool strikethroughSpacesKey v s


colorWhitespace v s =
    setBool colorWhitespaceKey v s


inline v s =
    setBool inlineKey v s


borderTop v s =
    setBool borderTopKey v s


borderRight v s =
    setBool borderRightKey v s


borderBottom v s =
    setBool borderBottomKey v s


borderLeft v s =
    setBool borderLeftKey v s


-- ====================== color setters ======================


foreground : Color -> Style -> Style
foreground c s =
    setValue (\s2 -> { s2 | fg = c }) s


background : Color -> Style -> Style
background c s =
    setValue (\s2 -> { s2 | bg = c }) s


marginBackground : Color -> Style -> Style
marginBackground c s =
    setValue (\s2 -> { s2 | marginBg = c }) s


borderTopForeground : Color -> Style -> Style
borderTopForeground c s =
    setValue (\s2 -> { s2 | borderTopFg = c }) s


borderRightForeground : Color -> Style -> Style
borderRightForeground c s =
    setValue (\s2 -> { s2 | borderRightFg = c }) s


borderBottomForeground : Color -> Style -> Style
borderBottomForeground c s =
    setValue (\s2 -> { s2 | borderBottomFg = c }) s


borderLeftForeground : Color -> Style -> Style
borderLeftForeground c s =
    setValue (\s2 -> { s2 | borderLeftFg = c }) s


borderTopBackground : Color -> Style -> Style
borderTopBackground c s =
    setValue (\s2 -> { s2 | borderTopBg = c }) s


borderRightBackground : Color -> Style -> Style
borderRightBackground c s =
    setValue (\s2 -> { s2 | borderRightBg = c }) s


borderBottomBackground : Color -> Style -> Style
borderBottomBackground c s =
    setValue (\s2 -> { s2 | borderBottomBg = c }) s


borderLeftBackground : Color -> Style -> Style
borderLeftBackground c s =
    setValue (\s2 -> { s2 | borderLeftBg = c }) s


-- ====================== int setters ======================


setWidth : Int -> Style -> Style
setWidth n s =
    setValue (\s2 -> { s2 | width = clamp0 n }) s


setHeight : Int -> Style -> Style
setHeight n s =
    setValue (\s2 -> { s2 | height = clamp0 n }) s


paddingTop : Int -> Style -> Style
paddingTop n s =
    setValue (\s2 -> { s2 | padTop = clamp0 n }) s


paddingRight : Int -> Style -> Style
paddingRight n s =
    setValue (\s2 -> { s2 | padRight = clamp0 n }) s


paddingBottom : Int -> Style -> Style
paddingBottom n s =
    setValue (\s2 -> { s2 | padBottom = clamp0 n }) s


paddingLeft : Int -> Style -> Style
paddingLeft n s =
    setValue (\s2 -> { s2 | padLeft = clamp0 n }) s


marginTop : Int -> Style -> Style
marginTop n s =
    setValue (\s2 -> { s2 | marginTop = clamp0 n }) s


marginRight : Int -> Style -> Style
marginRight n s =
    setValue (\s2 -> { s2 | marginRight = clamp0 n }) s


marginBottom : Int -> Style -> Style
marginBottom n s =
    setValue (\s2 -> { s2 | marginBottom = clamp0 n }) s


marginLeft : Int -> Style -> Style
marginLeft n s =
    setValue (\s2 -> { s2 | marginLeft = clamp0 n }) s


{-| Shorthand: all four sides (lipgloss's single-arg Padding/Margin).
-}
padding : Int -> Style -> Style
padding n s =
    paddingLeft n (paddingRight n (paddingTop n (paddingBottom n s)))


margin : Int -> Style -> Style
margin n s =
    marginLeft n (marginRight n (marginTop n (marginBottom n s)))


maxWidth : Int -> Style -> Style
maxWidth n s =
    setValue (\s2 -> { s2 | maxWidth = clamp0 n }) s


maxHeight : Int -> Style -> Style
maxHeight n s =
    setValue (\s2 -> { s2 | maxHeight = clamp0 n }) s


{-| Tab width: -1 (or less) = NoTabConversion, 0 = strip tabs, else N spaces.
The field stores the value; the tabWidthKey bit distinguishes "set" from the
unset default of 4.
-}
tabWidth : Int -> Style -> Style
tabWidth n s =
    let
        v =
            if n <= -1 then
                -1

            else
                n
    in
    { s | tabWidth = v, props = Bitwise.or s.props tabWidthKey }


-- ====================== position setters ======================


alignHorizontal : Pos -> Style -> Style
alignHorizontal p s =
    setValue (\s2 -> { s2 | alignH = p }) s


alignVertical : Pos -> Style -> Style
alignVertical p s =
    setValue (\s2 -> { s2 | alignV = p }) s


-- ====================== border setters ======================


{-| Border style only (sides implicit -> all four on at render).
-}
borderStyle : Border -> Style -> Style
borderStyle b s =
    setValue (\s2 -> { s2 | border = Just b }) s


{-| Border style + all four sides explicitly on (lipgloss Border(b) default).
-}
border : Border -> Style -> Style
border b s =
    borderTop True (borderRight True (borderBottom True (borderLeft True (borderStyle b s))))


-- ====================== string setters ======================


setString : String -> Style -> Style
setString str s =
    { s | value = str }


-- ====================== SGR building ======================


csi = "\u{1B}["

reset = "\u{1B}[0m"

-- The wrap machine (cellbuf) resets line breaks with x/ansi's ResetStyle,
-- NOT termenv's `reset` above.
wrapReset = "\u{1B}[m"


{-| Wrap body in `\e[<params>m ... \e[0m`, or return body unchanged when there
are no params (termenv Styled: `len(styles)==0 -> s`).
-}
sgr : List String -> String -> String
sgr params body =
    if isEmpty params then
        body

    else
        String.append csi (String.append (String.join ";" params) (String.append "m" (String.append body reset)))


fgSeq : Color -> String
fgSeq c =
    case c of
        ColorNo ->
            ""

        ColorAnsi n ->
            ansiColorSeq 30 90 n

        ColorAnsi256 n ->
            String.append "38;5;" (String.fromInt n)

        ColorRgb r g b ->
            rgbSeq 38 r g b


bgSeq : Color -> String
bgSeq c =
    case c of
        ColorNo ->
            ""

        ColorAnsi n ->
            ansiColorSeq 40 100 n

        ColorAnsi256 n ->
            String.append "48;5;" (String.fromInt n)

        ColorRgb r g b ->
            rgbSeq 48 r g b


ansiColorSeq low hi n =
    if n < 8 then
        String.fromInt (low + n)

    else
        String.fromInt (hi + (n - 8))


rgbSeq p r g b =
    String.append (String.fromInt p)
        (String.append ";2;"
            (String.append (String.fromInt r)
                (String.append ";"
                    (String.append (String.fromInt g)
                        (String.append ";" (String.fromInt b))
                    )
                )
            )
        )


addIf cond p acc =
    if cond then
        p :: acc

    else
        acc


-- Core text SGR (v1.1.0 EXACT order incl. the duplicated underline).
teParamsOf : Style -> List String
teParamsOf s =
    let
        underline =
            getAsBool underlineKey False s

        fg =
            s.fg

        bg =
            s.bg

        rev =
            addIf (getAsBool strikethroughKey False s) "9"
                (addIf underline "4"
                    (addIf (not (isNoColor bg)) (bgSeq bg)
                        (addIf (not (isNoColor fg)) (fgSeq fg)
                            (addIf (getAsBool faintKey False s) "2"
                                (addIf (getAsBool blinkKey False s) "5"
                                    (addIf (getAsBool reverseKey False s) "7"
                                        (addIf underline "4"
                                            (addIf (getAsBool italicKey False s) "3"
                                                (addIf (getAsBool boldKey False s) "1" [])
                                            )
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
    in
    List.reverse rev


-- Whitespace SGR (teWhitespace): reverse + fg when reverse, bg when
-- colorWhitespace.
wsParamsOf : Style -> List String
wsParamsOf s =
    let
        rv =
            getAsBool reverseKey False s

        cw =
            getAsBool colorWhitespaceKey True s

        rev =
            addIf (cw && not (isNoColor s.bg)) (bgSeq s.bg)
                (addIf (rv && not (isNoColor s.fg)) (fgSeq s.fg)
                    (addIf rv "7" [])
                )
    in
    List.reverse rev


underlineSpacesOf : Style -> Bool
underlineSpacesOf s =
    getAsBool underlineSpacesKey False s || (getAsBool underlineKey False s && getAsBool underlineSpacesKey True s)


strikethroughSpacesOf : Style -> Bool
strikethroughSpacesOf s =
    getAsBool strikethroughSpacesKey False s || (getAsBool strikethroughKey False s && getAsBool strikethroughSpacesKey True s)


useSpaceStylerOf : Style -> Bool
useSpaceStylerOf s =
    let
        underline =
            getAsBool underlineKey False s

        strikethrough =
            getAsBool strikethroughKey False s

        uSp =
            underlineSpacesOf s

        sSp =
            strikethroughSpacesOf s
    in
    (underline && not uSp) || (strikethrough && not sSp) || uSp || sSp


-- Space SGR (teSpace): fg/bg when useSpaceStyler, underline/strikethrough
-- when underlineSpaces/strikethroughSpaces.
spaceParamsOf : Style -> List String
spaceParamsOf s =
    let
        useSp =
            useSpaceStylerOf s

        rev =
            addIf (strikethroughSpacesOf s) "9"
                (addIf (underlineSpacesOf s) "4"
                    (addIf (useSp && not (isNoColor s.bg)) (bgSeq s.bg)
                        (addIf (useSp && not (isNoColor s.fg)) (fgSeq s.fg) [])
                    )
                )
    in
    List.reverse rev


-- ====================== tab conversion ======================


maybeConvertTabs : Style -> String -> String
maybeConvertTabs s str =
    let
        tw =
            if Bitwise.and s.props tabWidthKey == 0 then
                4

            else
                s.tabWidth
    in
    if tw == -1 then
        str

    else if tw == 0 then
        Str.replace "\t" "" str

    else
        Str.replace "\t" (Str.repeat tw " ") str


-- ====================== measurement (lg-size.go) ======================


getLines : String -> ( List String, Int )
getLines str =
    let
        ls =
            Str.lines str
    in
    ( ls, widestOf ls )


widestOf : List String -> Int
widestOf lines =
    foldl (\l acc -> max acc (Str.width l)) 0 lines


width : String -> Int
width str =
    widestOf (Str.lines str)


height : String -> Int
height str =
    Str.countChar '\n' str + 1


size : String -> ( Int, Int )
size str =
    ( width str, height str )


-- ====================== core text rendering ======================


runeBytes c =
    if c < 128 then
        1

    else if c < 192 then
        1

    else if c < 224 then
        2

    else if c < 240 then
        3

    else
        4


renderText : Style -> String -> String
renderText s str =
    let
        teP =
            teParamsOf s

        spP =
            spaceParamsOf s

        useSp =
            useSpaceStylerOf s
    in
    String.join "\n" (map (\l -> if useSp then styleRunes teP spP l else sgr teP l) (Str.lines str))


{-| useSpaceStyler path: per-RUNE, spaces styled by teSpace (unicode.IsSpace
parity for ASCII space/tab), everything else by te.
-}
styleRunes : List String -> List String -> String -> String
styleRunes teP spP line =
    styleRunesGo teP spP line 0 ""


styleRunesGo teP spP line i acc =
    let
        c =
            charCode line i
    in
    if c == -1 then
        acc

    else
        let
            need =
                runeBytes c

            r =
                String.sliceLen i need line

            params =
                if c == 32 || c == 9 then
                    spP

                else
                    teP
        in
        styleRunesGo teP spP line (i + need) (String.append acc (sgr params r))


-- ====================== padding ======================


{-| padLeft (isLeft False) / padRight (isLeft True) every line with one styled
space run (termenv `style.Styled(repeat n " ")`).
-}
padSide : Bool -> Int -> List String -> String -> String
padSide isLeft n sp str =
    if n <= 0 then
        str

    else
        let
            pad =
                sgr sp (Str.repeat n " ")

            lines =
                Str.lines str
        in
        String.join "\n" (map (\l -> if isLeft then String.append l pad else String.append pad l) lines)


padLR : Style -> String -> String
padLR s str =
    let
        sp =
            wsParamsOf s

        l =
            s.padLeft

        r =
            s.padRight

        s1 =
            if l > 0 then
                padSide False l sp str

            else
                str
    in
    if r > 0 then
        padSide True r sp s1

    else
        s1


padTB : Style -> String -> String
padTB s str =
    let
        t =
            s.padTop

        b =
            s.padBottom

        s1 =
            if t > 0 then
                String.append (Str.repeat t "\n") str

            else
                str
    in
    if b > 0 then
        String.append s1 (Str.repeat b "\n")

    else
        s1


-- ====================== vertical / horizontal alignment ======================


alignTextVertical : Pos -> Int -> String -> String
alignTextVertical pos height str =
    let
        strH =
            Str.countChar '\n' str + 1
    in
    if height < strH then
        str

    else
        let
            diff =
                height - strH
        in
        case pos of
            PTop ->
                String.append str (Str.repeat diff "\n")

            PBottom ->
                String.append (Str.repeat diff "\n") str

            PCenter ->
                let
                    top =
                        diff // 2
                in
                String.append (Str.repeat top "\n") (String.append str (Str.repeat (diff - top) "\n"))

            _ ->
                str


alignTextHorizontal : Pos -> Int -> List String -> String -> String
alignTextHorizontal pos width sp str =
    let
        lines =
            Str.lines str

        widest =
            widestOf lines
    in
    String.join "\n" (map (\l -> alignLine pos width sp widest l) lines)


alignLine pos width sp widest l =
    let
        short =
            (widest - Str.width l) + max 0 (width - widest)
    in
    if short <= 0 then
        l

    else
        case pos of
            PRight ->
                String.append (sgr sp (Str.repeat short " ")) l

            PCenter ->
                let
                    left =
                        short // 2
                in
                String.append (sgr sp (Str.repeat left " "))
                    (String.append l (sgr sp (Str.repeat (short - left) " ")))

            _ ->
                String.append l (sgr sp (Str.repeat short " "))


-- ====================== border (lg-borders.go applyBorder) ======================


maxRuneWidth : String -> Int
maxRuneWidth str =
    Str.width str


styleBorder : Color -> Color -> String -> String
styleBorder fg bg str =
    if isNoColor fg && isNoColor bg then
        str

    else
        sgr (append (if isNoColor fg then [] else [ fgSeq fg ]) (if isNoColor bg then [] else [ bgSeq bg ])) str


{-| renderHorizontalEdge: left + (edgeWidth - leftWidth) middles + right.
For the 1-cell runes of every provided border this is byte-identical to the Go
loop (the post-increment width oddity collapses to a step of 1).
-}
renderHorizontalEdge : String -> String -> String -> Int -> String
renderHorizontalEdge left middle right edgeWidth =
    let
        m =
            if middle == "" then
                " "

            else
                middle
    in
    String.append left (String.append (Str.repeat (edgeWidth - Str.width left) m) right)


applyBorder : Style -> String -> String
applyBorder s str =
    case s.border of
        Nothing ->
            str

        Just b ->
            let
                implicit =
                    Bitwise.and s.props borderSideMask == 0

                hasTop =
                    if implicit then
                        True

                    else
                        getAsBool borderTopKey False s

                hasRight =
                    if implicit then
                        True

                    else
                        getAsBool borderRightKey False s

                hasBottom =
                    if implicit then
                        True

                    else
                        getAsBool borderBottomKey False s

                hasLeft =
                    if implicit then
                        True

                    else
                        getAsBool borderLeftKey False s

                topFg =
                    s.borderTopFg

                rightFg =
                    s.borderRightFg

                bottomFg =
                    s.borderBottomFg

                leftFg =
                    s.borderLeftFg

                topBg =
                    s.borderTopBg

                rightBg =
                    s.borderRightBg

                bottomBg =
                    s.borderBottomBg

                leftBg =
                    s.borderLeftBg
            in
            if not hasTop && not hasRight && not hasBottom && not hasLeft then
                str

            else
                let
                    lines =
                        Str.lines str

                    contentW =
                        widestOf lines

                    b1 =
                        if hasLeft && b.left == "" then
                            { b | left = " " }

                        else
                            b

                    b2 =
                        if hasRight && b1.right == "" then
                            { b1 | right = " " }

                        else
                            b1

                    b3 =
                        if hasTop && hasLeft && b2.topLeft == "" then
                            { b2 | topLeft = " " }

                        else
                            b2

                    b4 =
                        if hasTop && hasRight && b3.topRight == "" then
                            { b3 | topRight = " " }

                        else
                            b3

                    b5 =
                        if hasBottom && hasLeft && b4.bottomLeft == "" then
                            { b4 | bottomLeft = " " }

                        else
                            b4

                    b6 =
                        if hasBottom && hasRight && b5.bottomRight == "" then
                            { b5 | bottomRight = " " }

                        else
                            b5

                    b7 =
                        suppressTop b6 hasTop hasLeft hasRight

                    b8 =
                        suppressBottom b7 hasBottom hasLeft hasRight

                    edgeWidth =
                        contentW + (if hasLeft then maxRuneWidth b8.left else 0)

                    topEdge =
                        if hasTop then
                            styleBorder topFg topBg (renderHorizontalEdge b8.topLeft b8.top b8.topRight edgeWidth)

                        else
                            ""

                    bottomEdge =
                        if hasBottom then
                            styleBorder bottomFg bottomBg (renderHorizontalEdge b8.bottomLeft b8.bottom b8.bottomRight edgeWidth)

                        else
                            ""

                    sideRows =
                        String.join "\n" (map (renderRow hasLeft hasRight leftFg leftBg rightFg rightBg b8.left b8.right) lines)
                in
                String.append (if hasTop then String.append topEdge "\n" else "")
                    (String.append sideRows (if hasBottom then String.append "\n" bottomEdge else ""))


{-| Corner suppression when a side is off (lg-borders.go:344-365).
-}
suppressTop : Border -> Bool -> Bool -> Bool -> Border
suppressTop b hasTop hasLeft hasRight =
    if not hasTop then
        b

    else if not hasLeft && not hasRight then
        { b | topLeft = "", topRight = "" }

    else if not hasLeft then
        { b | topLeft = "" }

    else if not hasRight then
        { b | topRight = "" }

    else
        b


suppressBottom : Border -> Bool -> Bool -> Bool -> Border
suppressBottom b hasBottom hasLeft hasRight =
    if not hasBottom then
        b

    else if not hasLeft && not hasRight then
        { b | bottomLeft = "", bottomRight = "" }

    else if not hasLeft then
        { b | bottomLeft = "" }

    else if not hasRight then
        { b | bottomRight = "" }

    else
        b


renderRow hasLeft hasRight leftFg leftBg rightFg rightBg leftStr rightStr l =
    String.append
        (if hasLeft then
            styleBorder leftFg leftBg leftStr

         else
            ""
        )
        (String.append l
            (if hasRight then
                styleBorder rightFg rightBg rightStr

             else
                ""
            )
        )


-- ====================== margins (lg-style.go applyMargins) ======================


applyMargins : Style -> String -> String
applyMargins s str =
    let
        mg =
            s.marginBg

        sp =
            if isNoColor mg then
                []

            else
                [ bgSeq mg ]

        s1 =
            if s.marginLeft > 0 then
                padSide False s.marginLeft sp str

            else
                str

        s2 =
            if s.marginRight > 0 then
                padSide True s.marginRight sp s1

            else
                s1

        ( _, w ) =
            getLines s2

        spaces =
            Str.repeat w " "

        s3 =
            if s.marginTop > 0 then
                String.append (sgr sp (Str.repeat s.marginTop (String.append spaces "\n"))) s2

            else
                s2
    in
    if s.marginBottom > 0 then
        String.append s3 (sgr sp (Str.repeat s.marginBottom (String.append "\n" spaces)))

    else
        s3


-- ====================== word wrap (cellbuf.Wrap port) ======================


-- Active-pen attribute bits (cellbuf.Style.Attrs; underline lives in
-- ulStyle, not here).
penBold = 1

penFaint = 2

penItalic = 4

penSlowBlink = 8

penRapidBlink = 16

penReverse = 32

penConceal = 64

penStrike = 128


{-| Active SGR state carried across a wrap break (cellbuf.Style): three color
slots as canonical params ("" = unset), the attribute bits above, and the
underline style (0 none, 1 single, 2 double, 3 curly, 4 dotted, 5 dashed).
-}
type alias Pen =
    { fg : String
    , bg : String
    , ul : String
    , attrs : Int
    , ulStyle : Int
    }


penEmpty : Pen
penEmpty =
    { fg = "", bg = "", ul = "", attrs = 0, ulStyle = 0 }


penIsEmpty : Pen -> Bool
penIsEmpty p =
    p.fg == "" && p.bg == "" && p.ul == "" && p.attrs == 0 && p.ulStyle == 0


{-| Merge one SGR sequence's params into the pen (cellbuf.ReadStyle).  An
empty param list (`\e[m`) resets, like Go's `len(params) == 0` branch.
-}
penRead : Pen -> String -> Pen
penRead pen params =
    if params == "" then
        penEmpty

    else
        penParam pen params 0


penParam : Pen -> String -> Int -> Pen
penParam pen s i =
    if i >= String.length s then
        pen

    else
        let
            j =
                penTokEnd s i

            res =
                penStep pen s (String.sliceLen i (j - i) s) (j + 1)
        in
        penParam (Tuple.first res) s (Tuple.second res)


-- Index of the next `;` at/after i, or the string length (token end).
penTokEnd : String -> Int -> Int
penTokEnd s i =
    if charCode s i == -1 || charCode s i == 59 then
        i

    else
        penTokEnd s (i + 1)


{-| ASCII decimal token value, -1 when empty or has a non-digit (no real SGR
param is negative, so -1 marks "not a param").
-}
penNum : String -> Int
penNum s =
    if String.length s == 0 then
        -1

    else
        penNumGo s 0 0


penNumGo s i acc =
    if charCode s i == -1 then
        acc

    else if charCode s i < 48 || charCode s i > 57 then
        -1

    else
        penNumGo s (i + 1) (acc * 10 + (charCode s i - 48))


{-| ReadStyleColor (subset): read the value tokens `5;N` or `2;r;g;b` after a
38/48/58 prefix; return (canonical params incl. the prefix, index past the
last consumed token), or ("", i) when malformed — no pen change, like Go's
`n > 0` guard.
-}
penExt : Int -> String -> Int -> ( String, Int )
penExt p s i =
    let
        j1 =
            penTokEnd s i

        kind =
            String.sliceLen i (j1 - i) s
    in
    if kind == "5" then
        let
            a =
                j1 + 1

            j2 =
                penTokEnd s a

            n =
                penNum (String.sliceLen a (j2 - a) s)
        in
        if n < 0 then
            ( "", i )

        else
            ( String.append (String.fromInt p) (String.append ";5;" (String.fromInt n)), j2 + 1 )

    else if kind == "2" then
        let
            a =
                j1 + 1

            b =
                penTokEnd s a

            c =
                b + 1

            d =
                penTokEnd s c

            e =
                d + 1

            f =
                penTokEnd s e

            r =
                penNum (String.sliceLen a (b - a) s)

            g =
                penNum (String.sliceLen c (d - c) s)

            bl =
                penNum (String.sliceLen e (f - e) s)
        in
        if r < 0 || g < 0 || bl < 0 then
            ( "", i )

        else
            ( rgbSeq p r g b, f + 1 )

    else
        ( "", i )


{-| Apply one SGR param token; returns (pen, index of the next token start).
38/48/58 consume their value tokens (Go's `i += n - 1`).
-}
penStep : Pen -> String -> String -> Int -> ( Pen, Int )
penStep pen s tok next =
    let
        skip =
            ( pen, next )
    in
    if tok == "0" then
        ( penEmpty, next )

    else if tok == "1" then
        ( { pen | attrs = Bitwise.or pen.attrs penBold }, next )

    else if tok == "2" then
        ( { pen | attrs = Bitwise.or pen.attrs penFaint }, next )

    else if tok == "3" then
        ( { pen | attrs = Bitwise.or pen.attrs penItalic }, next )

    else if tok == "4" then
        ( { pen | ulStyle = 1 }, next )

    else if String.length tok == 3 && charCode tok 0 == 52 && charCode tok 1 == 58 then
        -- "4:N" underline style subparameter (0 none .. 5 dashed).
        let
            n =
                penNum (String.sliceLen 2 1 tok)
        in
        if n >= 0 && n <= 5 then
            ( { pen | ulStyle = n }, next )

        else
            skip

    else if tok == "5" then
        ( { pen | attrs = Bitwise.or pen.attrs penSlowBlink }, next )

    else if tok == "6" then
        ( { pen | attrs = Bitwise.or pen.attrs penRapidBlink }, next )

    else if tok == "7" then
        ( { pen | attrs = Bitwise.or pen.attrs penReverse }, next )

    else if tok == "8" then
        ( { pen | attrs = Bitwise.or pen.attrs penConceal }, next )

    else if tok == "9" then
        ( { pen | attrs = Bitwise.or pen.attrs penStrike }, next )

    else if tok == "22" then
        ( { pen | attrs = Bitwise.and pen.attrs (Bitwise.complement (Bitwise.or penBold penFaint)) }, next )

    else if tok == "23" then
        ( { pen | attrs = Bitwise.and pen.attrs (Bitwise.complement penItalic) }, next )

    else if tok == "24" then
        ( { pen | ulStyle = 0 }, next )

    else if tok == "25" then
        ( { pen | attrs = Bitwise.and pen.attrs (Bitwise.complement (Bitwise.or penSlowBlink penRapidBlink)) }, next )

    else if tok == "27" then
        ( { pen | attrs = Bitwise.and pen.attrs (Bitwise.complement penReverse) }, next )

    else if tok == "28" then
        ( { pen | attrs = Bitwise.and pen.attrs (Bitwise.complement penConceal) }, next )

    else if tok == "29" then
        ( { pen | attrs = Bitwise.and pen.attrs (Bitwise.complement penStrike) }, next )

    else if tok == "38" then
        let
            ext =
                penExt 38 s next
        in
        if Tuple.first ext == "" then
            skip

        else
            ( { pen | fg = Tuple.first ext }, Tuple.second ext )

    else if tok == "39" then
        ( { pen | fg = "" }, next )

    else if tok == "48" then
        let
            ext =
                penExt 48 s next
        in
        if Tuple.first ext == "" then
            skip

        else
            ( { pen | bg = Tuple.first ext }, Tuple.second ext )

    else if tok == "49" then
        ( { pen | bg = "" }, next )

    else if tok == "58" then
        let
            ext =
                penExt 58 s next
        in
        if Tuple.first ext == "" then
            skip

        else
            ( { pen | ul = Tuple.first ext }, Tuple.second ext )

    else if tok == "59" then
        ( { pen | ul = "" }, next )

    else
        let
            n =
                penNum tok
        in
        if (n >= 30 && n <= 37) || (n >= 90 && n <= 97) then
            ( { pen | fg = tok }, next )

        else if (n >= 40 && n <= 47) || (n >= 100 && n <= 107) then
            ( { pen | bg = tok }, next )

        else
            skip


{-| cellbuf Style.Sequence: the pen's canonical SGR params — attrs in
1,2,3,5,6,7,8,9 order, then the underline style, then fg, bg, ul.
-}
penSeq : Pen -> String
penSeq p =
    String.join ";"
        (addIf (Bitwise.and p.attrs penBold /= 0) "1"
            (addIf (Bitwise.and p.attrs penFaint /= 0) "2"
                (addIf (Bitwise.and p.attrs penItalic /= 0) "3"
                    (addIf (Bitwise.and p.attrs penSlowBlink /= 0) "5"
                        (addIf (Bitwise.and p.attrs penRapidBlink /= 0) "6"
                            (addIf (Bitwise.and p.attrs penReverse /= 0) "7"
                                (addIf (Bitwise.and p.attrs penConceal /= 0) "8"
                                    (addIf (Bitwise.and p.attrs penStrike /= 0) "9"
                                        (addIf (p.ulStyle == 1) "4"
                                            (addIf (p.ulStyle == 2) "4:2"
                                                (addIf (p.ulStyle == 3) "4:3"
                                                    (addIf (p.ulStyle == 4) "4:4"
                                                        (addIf (p.ulStyle == 5) "4:5"
                                                            (addIf (p.fg /= "") p.fg
                                                                (addIf (p.bg /= "") p.bg
                                                                    (addIf (p.ul /= "") p.ul
                                                                        []
                                                                    )
                                                                )
                                                            )
                                                        )
                                                    )
                                                )
                                            )
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )


type alias Wrap =
    { out : String
    , word : String
    , space : String
    , style : Pen
    , curStyle : Pen
    , curWidth : Int
    , wordLen : Int
    }


initWrap =
    { out = ""
    , word = ""
    , space = ""
    , style = penEmpty
    , curStyle = penEmpty
    , curWidth = 0
    , wordLen = 0
    }


wrap : Int -> String -> String
wrap limit str =
    if String.length str == 0 then
        ""

    else if limit < 1 then
        str

    else
        wrapGo limit str 0 initWrap


wrapGo : Int -> String -> Int -> Wrap -> String
wrapGo limit s i w =
    let
        c =
            charCode s i
    in
    if c == -1 then
        finishWrap limit w

    else if c == 10 then
        wrapGo limit s (i + 1) (stepNewline limit w)

    else if c == 9 then
        wrapGo limit s (i + 1) (stepTab w)

    else if c == 27 then
        wrapGo limit s (escEnd s i) (stepEsc s i w)

    else
        wrapGo limit s (i + runeBytes c) (stepGlyph limit s i w)


addSpace : Wrap -> Wrap
addSpace w =
    { w
        | out = String.append w.out w.space
        , curWidth = w.curWidth + String.length w.space
        , space = ""
    }


addWord : Wrap -> Wrap
addWord w =
    if String.length w.word == 0 then
        w

    else
        let
            w1 =
                addSpace w
        in
        { w1
            | curStyle = w1.style
            , curWidth = w1.curWidth + w1.wordLen
            , out = String.append w1.out w1.word
            , word = ""
            , wordLen = 0
        }


addNewline : Wrap -> Wrap
addNewline w =
    let
        resetStr =
            if penIsEmpty w.curStyle then
                ""

            else
                wrapReset

        restyle =
            if penIsEmpty w.curStyle then
                ""

            else
                String.append csi (String.append (penSeq w.curStyle) "m")
    in
    { w
        | out = String.append w.out (String.append resetStr (String.append "\n" restyle))
        , curWidth = 0
        , space = ""
    }


stepTab : Wrap -> Wrap
stepTab w =
    let
        w1 =
            addWord w
    in
    { w1 | space = String.append w1.space "\t" }


stepNewline : Int -> Wrap -> Wrap
stepNewline limit w =
    let
        w1 =
            if w.wordLen == 0 then
                if w.curWidth + String.length w.space > limit then
                    { w | curWidth = 0, space = "" }

                else
                    { w | out = String.append w.out w.space, space = "" }

            else
                w

        w2 =
            addWord w1
    in
    addNewline w2


{-| ANSI escape at i (i points at ESC): return the index just past it.
-}
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


stepEsc : String -> Int -> Wrap -> Wrap
stepEsc s i w =
    let
        c1 =
            charCode s (i + 1)

        end =
            escEnd s i

        seq =
            String.sliceLen i (end - i) s
    in
    if c1 == 91 && charCode s (end - 1) == 109 then
        -- SGR: ReadStyle — merge its params into the active pen (bare/`0`
        -- resets; stacked sequences accumulate).
        { w
            | style = penRead w.style (String.sliceLen (i + 2) (end - i - 3) s)
            , word = String.append w.word seq
        }

    else
        { w | word = String.append w.word seq }


stepGlyph : Int -> String -> Int -> Wrap -> Wrap
stepGlyph limit s i w =
    let
        c =
            charCode s i

        need =
            runeBytes c

        r =
            String.sliceLen i need s

        gw =
            Str.width r
    in
    if c == 32 then
        let
            w1 =
                addWord w
        in
        { w1 | space = String.append w1.space " " }

    else if c == 45 then
        let
            w1 =
                addSpace w
        in
        if w1.curWidth + w1.wordLen + gw <= limit then
            let
                w2 =
                    addWord w1
            in
            { w2 | out = String.append w2.out r, curWidth = w2.curWidth + gw }

        else
            stepRegular limit gw r w

    else
        stepRegular limit gw r w


stepRegular : Int -> Int -> String -> Wrap -> Wrap
stepRegular limit gw r w =
    let
        w1 =
            if w.wordLen + gw > limit then
                addWord w

            else
                w

        w2 =
            { w1 | word = String.append w1.word r, wordLen = w1.wordLen + gw }
    in
    if w2.curWidth + w2.wordLen + String.length w2.space > limit then
        addNewline w2

    else
        w2


finishWrap : Int -> Wrap -> String
finishWrap limit w =
    let
        w1 =
            if w.wordLen == 0 then
                if w.curWidth + String.length w.space > limit then
                    { w | curWidth = 0, space = "" }

                else
                    { w | out = String.append w.out w.space, space = "" }

            else
                w

        w2 =
            addWord w1

        w3 =
            if penIsEmpty w2.curStyle then
                w2

            else
                { w2 | out = String.append w2.out wrapReset }
    in
    w3.out


-- ====================== truncation (maxWidth/maxHeight) ======================


truncateMaxWidth : Int -> String -> String
truncateMaxWidth mw str =
    String.join "\n" (map (\l -> Str.truncate mw l) (Str.lines str))


truncateMaxHeight : Int -> String -> String
truncateMaxHeight mh str =
    String.join "\n" (take (min mh (length (Str.lines str))) (Str.lines str))


-- ====================== Render (lg-style.go pipeline) ======================


render : Style -> String -> String
render s str =
    let
        full =
            if s.value == "" then
                str

            else
                String.append s.value (String.append " " str)
    in
    if s.props == 0 then
        maybeConvertTabs s full

    else
        renderFull s full


renderFull : Style -> String -> String
renderFull s str0 =
    let
        inline =
            getAsBool inlineKey False s

        w =
            s.width

        h =
            s.height

        alignH =
            s.alignH

        alignV =
            s.alignV

        wsP =
            wsParamsOf s

        str1 =
            maybeConvertTabs s str0

        str2 =
            Str.replace "\r\n" "\n" str1

        str3 =
            if inline then
                Str.replace "\n" "" str2

            else
                str2

        str4 =
            if not inline && w > 0 then
                wrap (w - s.padLeft - s.padRight) str3

            else
                str3

        str5 =
            renderText s str4

        str6 =
            if inline then
                str5

            else
                padLR s str5

        str7 =
            if inline then
                str6

            else
                padTB s str6

        str8 =
            if h > 0 then
                alignTextVertical alignV h str7

            else
                str7

        str9 =
            if Str.countChar '\n' str8 /= 0 || w /= 0 then
                alignTextHorizontal alignH w wsP str8

            else
                str8

        str10 =
            if inline then
                str9

            else
                applyMargins s (applyBorder s str9)

        str11 =
            if s.maxWidth > 0 then
                truncateMaxWidth s.maxWidth str10

            else
                str10
    in
    if s.maxHeight > 0 then
        truncateMaxHeight s.maxHeight str11

    else
        str11


-- ====================== join / place (lg-join.go / lg-position.go) ======================


lineAt : Int -> List String -> String
lineAt i lines =
    case lines of
        l :: rest ->
            if i <= 0 then
                l

            else
                lineAt (i - 1) rest

        [] ->
            ""


repeatEmpty : Int -> List String
repeatEmpty n =
    if n <= 0 then
        []

    else
        "" :: repeatEmpty (n - 1)


padBlock : Pos -> Int -> List String -> List String
padBlock pos maxH block =
    let
        n =
            maxH - length block
    in
    if n <= 0 then
        block

    else
        case pos of
            PTop ->
                append block (repeatEmpty n)

            PBottom ->
                append (repeatEmpty n) block

            _ ->
                let
                    split =
                        (n + 1) // 2

                    top =
                        n - split
                in
                append (repeatEmpty top) (append block (repeatEmpty (n - top)))


rowAt : List (List String) -> List Int -> Int -> String
rowAt blocks widths i =
    case blocks of
        [] ->
            ""

        b :: bs ->
            case widths of
                [] ->
                    ""

                w :: ws ->
                    let
                        line =
                            lineAt i b
                    in
                    String.append line (String.append (Str.repeat (w - Str.width line) " ") (rowAt bs ws i))


joinHRows : List (List String) -> List Int -> Int -> Int -> String
joinHRows blocks widths maxH i =
    if i >= maxH then
        ""

    else
        let
            row =
                rowAt blocks widths i
        in
        if i == maxH - 1 then
            row

        else
            String.append row (String.append "\n" (joinHRows blocks widths maxH (i + 1)))


joinHorizontal : Pos -> List String -> String
joinHorizontal pos strs =
    case strs of
        [] ->
            ""

        x :: [] ->
            x

        _ ->
            let
                blocks =
                    map Str.lines strs

                widths =
                    map widestOf blocks

                maxH =
                    foldl (\b acc -> max acc (length b)) 0 blocks

                padded =
                    map (\b -> padBlock pos maxH b) blocks
            in
            joinHRows padded widths maxH 0


renderLineV : Pos -> Int -> String -> String
renderLineV pos maxW line =
    let
        w =
            maxW - Str.width line
    in
    case pos of
        PLeft ->
            String.append line (Str.repeat w " ")

        PRight ->
            String.append (Str.repeat w " ") line

        _ ->
            let
                left =
                    (w + 1) // 2
            in
            String.append (Str.repeat left " ") (String.append line (Str.repeat (w - left) " "))


joinVertical : Pos -> List String -> String
joinVertical pos strs =
    case strs of
        [] ->
            ""

        x :: [] ->
            x

        _ ->
            let
                blocks =
                    map Str.lines strs

                maxW =
                    foldl (\b acc -> max acc (widestOf b)) 0 blocks
            in
            String.join "\n" (Prelude.concat (map (map (renderLineV pos maxW)) blocks))


placeHLine : Pos -> Int -> Int -> String -> String
placeHLine pos contentW gap l =
    let
        total =
            gap + max 0 (contentW - Str.width l)
    in
    case pos of
        PLeft ->
            String.append l (Str.repeat total " ")

        PRight ->
            String.append (Str.repeat total " ") l

        _ ->
            let
                split =
                    (total + 1) // 2

                left =
                    total - split
            in
            String.append (Str.repeat left " ") (String.append l (Str.repeat (total - left) " "))


placeHorizontal : Int -> Pos -> String -> String
placeHorizontal width pos str =
    let
        lines =
            Str.lines str

        contentW =
            widestOf lines

        gap =
            width - contentW
    in
    if gap <= 0 then
        str

    else
        String.join "\n" (map (placeHLine pos contentW gap) lines)


joinNL : Int -> String -> String
joinNL n e =
    if n <= 0 then
        ""

    else if n == 1 then
        e

    else
        String.append e (String.append "\n" (joinNL (n - 1) e))


placeVertical : Int -> Pos -> String -> String
placeVertical height pos str =
    let
        contentH =
            Str.countChar '\n' str + 1

        gap =
            height - contentH
    in
    if gap <= 0 then
        str

    else
        let
            ( _, w ) =
                getLines str

            emptyLine =
                Str.repeat w " "
        in
        case pos of
            PTop ->
                String.append str (String.append "\n" (joinNL gap emptyLine))

            PBottom ->
                String.append (Str.repeat gap (String.append emptyLine "\n")) str

            _ ->
                let
                    split =
                        (gap + 1) // 2

                    top =
                        gap - split

                    bottom =
                        gap - top
                in
                String.append (Str.repeat top (String.append emptyLine "\n"))
                    (String.append str (Str.repeat bottom (String.append "\n" emptyLine)))
