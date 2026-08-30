module TaUnit exposing (main)

-- S5 gate (main : String): core-libs/Textarea.elm (bubbles textarea, the
-- multi-line editor).  Byte-exact PLAIN renders at a fixed size pin the
-- reverse-video cursor (\e[7m<chr>\e[0m on the current char, \e[7m \e[0m at
-- EOL), the prompt prefix on every row, the focus gate (blurred = no cursor),
-- and the vertical reposition (cursor below the fold scrolls it into view);
-- cursor/content states are driven through `update` folds (real keymap keys)
-- and `==` flags pin the grid arithmetic (row/col, value join, merge/split/
-- delete-word byte offsets).  The view literals were byte-verified by eye
-- against the gate-proven viewport/Lipgloss render (no hand-composed SGR —
-- the only SGR is the \e[7m/\e[0m cursor pair).
--
-- col is a BYTE offset (documented deviation): all fixtures use ASCII so
-- byte == char exactly.

import Textarea exposing (blur, col, focus, init, row, setCursor, setValue, update, value, view)


f x =
  case x of
    True ->
      "1"

    False ->
      "0"


main =
  let
    -- ---- init defaults ----
    d =
      init 12 5

    -- ---- setValue / accessors ----
    v =
      setValue "ab\ncd" (init 10 3)

    -- ---- cursor movement (update folds over real keys) ----
    m =
      focus (setValue "hello" (init 10 3))

    left2 =
      update KeyLeft (update KeyLeft m)

    moved =
      update KeyEnd (update KeyHome left2)

    rightFrom4 =
      update KeyRight (setCursor 0 4 m)

    rightAtEnd =
      update KeyRight moved

    -- ---- insert ----
    ins =
      update (KeyChar "!") (setCursor 0 2 m)

    -- ---- backspace (col>0 and col0-merge) ----
    bs =
      update KeyBackspace (setCursor 0 3 m)

    bsMerge =
      update KeyBackspace (setCursor 1 0 (focus (setValue "ab\ncd" (init 10 3))))

    -- ---- delete (forward; at EOL merges below) ----
    del =
      update KeyDel (setCursor 0 2 m)

    delMerge =
      update KeyDel (setCursor 0 2 (focus (setValue "ab\ncd" (init 10 3))))

    -- ---- enter split ----
    enter =
      update KeyEnter (setCursor 0 2 m)

    -- ---- ctrl+k / ctrl+u / ctrl+w ----
    kA =
      update (KeyCtrl "k") (setCursor 0 2 m)

    kMerge =
      update (KeyCtrl "k") (setCursor 0 2 (focus (setValue "ab\ncd" (init 10 3))))

    uB =
      update (KeyCtrl "u") (setCursor 0 3 m)

    uMerge =
      update (KeyCtrl "u") (setCursor 1 0 (focus (setValue "ab\ncd" (init 10 3))))

    wB =
      update (KeyCtrl "w") (focus (setValue "hello world" (init 20 3)))

    -- ---- up/down (clamp col to the target line) ----
    downToEnd =
      update KeyDown (setCursor 0 5 (focus (setValue "abcdef\nab" (init 10 3))))

    upBack =
      update KeyUp (setCursor 1 4 (focus (setValue "ab\ncdef" (init 10 3))))

    -- ---- pgup / pgdn move by height rows ----
    pg =
      focus (setValue "l0\nl1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9" (init 10 3))

    pgup =
      update KeyPgUp pg

    pgdn =
      update KeyPgDn (setCursor 0 0 pg)

    -- ---- blurred models ignore keys ----
    bl =
      update KeyLeft (setCursor 0 1 (setValue "ab" (init 10 3)))

    blType =
      update (KeyChar "x") bl

    -- ---- view bytes ----
    -- char cursor: "ab" with cursor on 'b' (col 1), 8 wide x 3 high
    vChar =
      view (setCursor 0 1 (focus (setValue "ab" (init 8 3))))

    -- EOL cursor: "ab" cursor past end (col 2), 8 wide x 1 high
    vEol =
      view (setCursor 0 2 (focus (setValue "ab" (init 8 1))))

    -- cursor at top of a 3-line grid, 8x2: rows 0,1 visible
    vTop =
      view (setCursor 0 0 (focus (setValue "a\nb\nc" (init 8 2))))

    -- cursor at the bottom line: reposition scrolls rows 1,2 into view
    vBot =
      view (setCursor 2 0 (focus (setValue "a\nb\nc" (init 8 2))))

    -- blurred: no cursor marker
    vBlur =
      view (setCursor 0 1 (setValue "ab" (init 8 1)))

    flags =
      String.join ""
        [ f (d.value == [ "" ])
        , f (d.row == 0)
        , f (d.col == 0)
        , f (not d.focus)
        , f (d.prompt == "┃ ")
        , f (d.width == 12)
        , f (d.height == 5)
        , f (v.value == [ "ab", "cd" ])
        , f (value v == "ab\ncd")
        , f (row v == 1)
        , f (col v == 2)
        , f (focus v).focus
        , f (not (blur (focus v)).focus)
        , f (col left2 == 3)
        , f (col moved == 5)
        , f (col rightFrom4 == 5)
        , f (col rightAtEnd == 5)
        , f (value ins == "he!llo")
        , f (col ins == 3)
        , f (value bs == "helo")
        , f (col bs == 2)
        , f (value bsMerge == "abcd")
        , f (row bsMerge == 0)
        , f (col bsMerge == 2)
        , f (value del == "helo")
        , f (col del == 2)
        , f (value delMerge == "abcd")
        , f (row delMerge == 0)
        , f (value enter == "he\nllo")
        , f (row enter == 1)
        , f (col enter == 0)
        , f (value kA == "he")
        , f (col kA == 2)
        , f (value kMerge == "abcd")
        , f (value uB == "lo")
        , f (col uB == 0)
        , f (value uMerge == "abcd")
        , f (row uMerge == 0)
        , f (value wB == "hello ")
        , f (col wB == 6)
        , f (value downToEnd == "abcdef\nab")
        , f (row downToEnd == 1)
        , f (col downToEnd == 2)
        , f (value upBack == "ab\ncdef")
        , f (row upBack == 0)
        , f (col upBack == 2)
        , f (row pgup == 6)
        , f (row pgdn == 3)
        , f (col bl == 1)
        , f (value blType == "ab")
        , f (vChar == "┃ a\u{1B}[7mb\u{1B}[0m    \n        \n        ")
        , f (vEol == "┃ ab\u{1B}[7m \u{1B}[0m   ")
        , f (vTop == "┃ \u{1B}[7ma\u{1B}[0m     \n┃ b     ")
        , f (vBot == "┃ b     \n┃ \u{1B}[7mc\u{1B}[0m     ")
        , f (vBlur == "┃ ab    ")
        ]
  in
  String.join "|"
    [ flags
    , vChar
    , vEol
    , vTop
    , vBot
    ]
