module ProgUnit exposing (main)

-- S2 gate (main : String): core-libs/Progress.elm (bubbles progress, static
-- ViewAs subset).  The == flags pin FULL BYTE EXACTNESS of several renders
-- by comparing against strings composed from the SAME SGR spellings the
-- gate-proven Lipgloss emits (fg-only style: \e[<fg>m TEXT \e[0m — one pair
-- per render, the zero-width repeat still emitting the pair), so a PASS is
-- the byte check itself; width/character flags cover the rest.  Integer
-- arithmetic pins: fw = tw * permil // 1000 (truncating), pct = permil//10.
-- VISIBLE strings: the default bar at 0 / 50 / 100 permille of the
-- percentage.

f x =
  case x of
    True ->
      "1"

    False ->
      "0"


-- annotated record-updating helpers (the S2 lesson)


setW : Int -> Progress.Model -> Progress.Model
setW w m =
  { m | width = w }


setPct : Bool -> Progress.Model -> Progress.Model
setPct b m =
  { m | showPercentage = b }


setChars : String -> String -> Progress.Model -> Progress.Model
setChars fl em m =
  { m | full = fl, empty = em }


setFullColor : Lipgloss.Color -> Progress.Model -> Progress.Model
setFullColor c m =
  { m | fullColor = c }


main =
  let
    bar =
      Progress.new

    -- a 40-wide bar with the "   0%" tail reserves 5 cells: tw = 35
    at0 =
      Progress.viewAs 0 bar

    at1000 =
      Progress.viewAs 1000 bar

    at500 =
      Progress.viewAs 500 bar

    at250 =
      Progress.viewAs 250 bar

    at333 =
      Progress.viewAs 333 bar

    -- clamping: 1500 permille -> full bar + " 100%"; -50 -> empty + "   0%"
    at1500 =
      Progress.viewAs 1500 bar

    atNeg =
      Progress.viewAs -50 bar

    -- no percentage: the bar spans the whole width (40)
    bare =
      Progress.viewAs 500 (setPct False bar)

    -- width smaller than the percentage text: tw = 0 -> percentage only
    tiny =
      Progress.viewAs 500 (setW 4 bar)

    -- custom fill characters, whole-width bar (no percentage): 10 -> tw 10,
    -- 250 permille -> 2 filled + 8 empty
    blocks =
      Progress.viewAs 250 (setPct False (setChars "█" "-" (setW 10 bar)))

    -- 256-color foreground on the filled segment
    ind =
      Progress.viewAs 1000 (setFullColor (Lipgloss.ColorAnsi256 212) bar)

    -- composed byte-exact expectations (SGR = Lipgloss fg-only render)
    fgFull =
      "\u{1B}[38;2;117;113;249m"

    fgEmpty =
      "\u{1B}[38;2;96;96;96m"

    fg212 =
      "\u{1B}[38;5;212m"

    rst =
      "\u{1B}[0m"

    exp0 =
      String.append fgFull
        (String.append rst
          (String.append fgEmpty
            (String.append (Str.repeat 35 "░")
              (String.append rst "   0%")
            )
          )
        )

    exp1000 =
      String.append fgFull
        (String.append (Str.repeat 35 "▌")
          (String.append rst
            (String.append fgEmpty
              (String.append rst " 100%")
            )
          )
        )

    exp500 =
      String.append fgFull
        (String.append (Str.repeat 17 "▌")
          (String.append rst
            (String.append fgEmpty
              (String.append (Str.repeat 18 "░")
                (String.append rst "  50%")
              )
            )
          )
        )

    expInd =
      String.append fg212
        (String.append (Str.repeat 35 "▌")
          (String.append rst
            (String.append fgEmpty
              (String.append rst " 100%")
            )
          )
        )

    expBlocks =
      String.append fgFull
        (String.append (Str.repeat 2 "█")
          (String.append rst
            (String.append fgEmpty
              (String.append (Str.repeat 8 "-")
                (String.append rst "")
              )
            )
          )
        )

    expTiny =
      String.append fgFull
        (String.append rst
          (String.append fgEmpty
            (String.append rst "  50%")
          )
        )

    -- structural flags: declaration order
    flags =
      String.join ""
        [ f (bar.width == 40)
        , f (bar.full == "▌")
        , f (bar.empty == "░")
        , f bar.showPercentage
        , f (at0 == exp0)
        , f (at1000 == exp1000)
        , f (at500 == exp500)
        , f (ind == expInd)
        , f (blocks == expBlocks)
        , f (Str.width at250 == 40)
        , f (Str.width bare == 40)
        , f (Str.width tiny == 5)
        , f (Str.width at1500 == 40)
        , f (Str.width atNeg == 40)
        , -- 35 * 333 // 1000 = 11 (truncated), pct 333//10 = 33
          f (Str.contains (String.append (Str.repeat 11 "▌") rst) at333)
        , f (Str.contains "  33%" at333)
        , -- 500 permille bare: 20 filled, 20 empty, no tail
          f (Str.contains (Str.repeat 20 "▌") bare)
        , f (Str.contains (Str.repeat 20 "░") bare)
        , f (at0 == atNeg)
        , f (at1000 == at1500)
        , -- percentage cell width counts even when the bar has no room
          f (tiny == expTiny)
        ]
  in
  String.join "|"
    [ flags
    , at0
    , at500
    , at1000
    ]
