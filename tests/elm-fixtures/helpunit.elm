module HelpUnit exposing (main)

-- S2 gate (main : String): core-libs/Help.elm (bubbles help package).  Flags
-- pin the structural semantics (defaults, enabled filtering, the
-- shouldAddItem boundary rules, view dispatch); the VISIBLE strings carry
-- the byte-exact renders — short help (default styles, disabled middle),
-- width-truncated short help (ellipsis tail, and the overflow-WITHOUT-tail
-- case), full help columns (two groups, disabled column members, the width
-- cap).  Item widths under the default styles: up=6 cells, down=11 (3 sep),
-- quit=9, help=9 — the width pins below are computed from those.  ESC bytes
-- only ever live INSIDE the program (==-compared, the kbunit discipline).

f x =
  case x of
    True ->
      "1"

    False ->
      "0"


main =
  let
    -- a small viewport-style keymap
    up =
      Key.newBinding [ "up", "k" ] "↑/k" "up"

    down =
      Key.newBinding [ "down", "j" ] "↓/j" "down"

    quit =
      Key.newBinding [ "q", "ctrl+c" ] "q" "quit"

    help =
      Key.newBinding [ "?" ] "?" "help"

    off =
      { down | disabled = True }

    h0 =
      Help.new

    h9 =
      Help.setWidth 9 h0

    h26 =
      Help.setWidth 26 h0

    h30 =
      Help.setWidth 30 h0

    -- SHORT HELP renders (visible, byte-exact)
    shortAll =
      Help.shortHelpView h0 [ up, down, quit ]

    shortDis =
      Help.shortHelpView h0 [ up, off, quit ]

    -- 26 cells: up(6) + sep+down(11) + sep+quit(9) exactly fits -> no tail
    shortFit =
      Help.shortHelpView h26 [ up, down, quit ]

    -- 30 cells, 4 items: up(6) down(11) fit; quit(9) overflows (17+9=26>30
    -- is false -> FITS); help(9): 26+9=35>30 -> tail " …"(2): 26+2=28<30
    -- -> tail emitted, help dropped
    shortTrunc =
      Help.shortHelpView h30 [ up, down, quit, help ]

    -- 9 cells: up(6) fits; down overflows, tail " …" fits strictly (6+2=8<9)
    -- -> tail replaces it
    shortTail =
      Help.shortHelpView h9 [ up, down, quit ]

    -- 8 cells: tail needs 6+2=8, STRICT < fails -> overflowing items render
    -- whole anyway -> identical to the unlimited render
    shortNoTail =
      Help.shortHelpView (Help.setWidth 8 h0) [ up, down ]

    -- FULL HELP renders (visible, byte-exact): col widths 8 then 10
    fullTwo =
      Help.fullHelpView h0 [ [ up, down ], [ quit, help ] ]

    fullDis =
      Help.fullHelpView h0 [ [ up, off ], [ quit ] ]

    -- 14 cells: col1(8) fits; col2(10) overflows (8+10=18>14), tail " …"
    -- fits strictly (8+2=10<14) -> tail column; row 1 = 10 cells wide
    fullTrunc =
      Help.fullHelpView (Help.setWidth 14 h0) [ [ up, down ], [ quit, help ] ]

    -- every group without an enabled binding -> ""
    fullNone =
      Help.fullHelpView h0 [ [ off ], [] ]

    -- view dispatch on showAll
    vShort =
      Help.view h0 [ up, quit ] [ [ up ], [ quit ] ]

    vFull =
      Help.view { h0 | showAll = True } [ up, quit ] [ [ up ], [ quit ] ]

    w42 =
      Help.setWidth 42 h0

    n0 =
      Help.new

    shortAll2 =
      Help.shortHelpView h0 [ up, down ]

    fullTwoRows =
      Str.lines fullTwo

    fullTwoRow1 =
      case fullTwoRows of
        r1 :: _ ->
          r1

        [] ->
          ""

    truncRows =
      Str.lines fullTrunc

    truncRow1 =
      case truncRows of
        r1 :: _ ->
          r1

        [] ->
          ""

    -- structural flags: declaration order
    flags =
      String.join ""
        [ f (n0.width == 0)
        , f (not n0.showAll)
        , f (n0.ellipsis == "…")
        , f (n0.shortSeparator == " • ")
        , f (n0.fullSeparator == "    ")
        , f (w42.width == 42)
        , f (Help.shortHelpView h0 [] == "")
        , f (Help.shortHelpView h0 [ off ] == "")
        , f (Help.fullHelpView h0 [] == "")
        , f (fullNone == "")
        , f (Help.shortHelpView h0 [ up ] == Help.shortHelpView h0 [ up, off ])
        , f (shortFit == shortAll)
        , f (Str.width shortTrunc == 28)
        , f (Str.width shortTail == 8)
        , f (shortNoTail == shortAll2)
        , f (Str.width truncRow1 == 10)
        , f (vShort == Help.shortHelpView h0 [ up, quit ])
        , f (vFull == Help.fullHelpView h0 [ [ up ], [ quit ] ])
        , f (Str.width shortAll == 26)
        , f (Str.width fullTwoRow1 == 18)
        , f (Str.width fullDis == 16)
        , -- the ellipsis tail is rendered in the separator (dark #3C3C3C)
          -- style, inline: SGR + space + … + reset
          f (Str.contains " \u{1B}[38;2;60;60;60m…\u{1B}[0m" shortTail)
        ]
  in
  String.join "|"
    [ flags
    , shortAll
    , shortDis
    , shortTrunc
    , shortTail
    , fullTwo
    , fullDis
    , fullTrunc
    , vShort
    , vFull
    ]
