module TableUnit exposing (main)

-- S7 gate (main : String): core-libs/Table.elm (bubbles table — the data
-- table).  Flags pin the R7 scroll parity (10 rows / 5-high viewport / j / G
-- / g): j walks the cursor to the bottom visible row then scrolls, G jumps to
-- the last row (top = rows-height), g back to the top.  Views carry the
-- byte-exact renders: bold header cells (title truncated with a "…" tail
-- INSIDE the width budget), right-padded cells, the selected row wrapped in
-- bold + fg 212 (ColorAnsi256), and the viewport padding each row to the
-- table width.
--
-- Truncation is exercised on BOTH axes: the header "Population" (10 cells) in
-- an 8-wide column -> "Populat…"; the "Sao Paulo" (9) -> "Sao Pau…" and
-- "Mexico City" (11) -> "Mexico …" data cells; "Shanghai" (8) fits exactly.
--
-- ESC/SGR bytes only ever live INSIDE the program (the kbunit discipline): no
-- hand-composed escape — every SGR byte is produced by Lipgloss.render inside
-- Table.  The expected file is byte-verified by eye against the table.go
-- render pipeline.

import Table exposing (blur, columns, cursor, focus, focused, gotoBottom, gotoTop, height, helpView, new, rows, selectedRow, setCursor, setRows, update, view, width)


f : Bool -> String
f b =
  case b of
    True ->
      "1"

    False ->
      "0"


n : Int -> String
n =
  String.fromInt


cols : List Table.Column
cols =
  [ { title = "Rank", width = 5 }
  , { title = "City", width = 8 }
  , { title = "Population", width = 8 }
  ]


dataRows : List Table.Row
dataRows =
  [ [ "1", "Tokyo", "37400068" ]
  , [ "2", "Delhi", "28514000" ]
  , [ "3", "Shanghai", "25582000" ]
  , [ "4", "Sao Paulo", "21650000" ]
  , [ "5", "Mexico City", "21581000" ]
  , [ "6", "Cairo", "20076000" ]
  , [ "7", "Mumbai", "19980000" ]
  , [ "8", "Beijing", "19618000" ]
  , [ "9", "Dhaka", "19578000" ]
  , [ "10", "Osaka", "19281000" ]
  ]


main =
  let
    m0 =
      focus (new cols dataRows 24 6)

    m1 =
      update (KeyChar "j") m0

    m4 =
      update (KeyChar "j") (update (KeyChar "j") (update (KeyChar "j") m1))

    m5 =
      update (KeyChar "j") m4

    mG =
      update (KeyChar "G") m5

    mg =
      update (KeyChar "g") mG

    mGB =
      gotoBottom m0

    mGT =
      gotoTop mGB

    mb =
      blur m0

    mb2 =
      update (KeyChar "j") mb

    mpd =
      update (KeyChar "f") m0

    mpu =
      update (KeyChar "b") mpd

    mhd =
      update (KeyChar "d") m0

    msc =
      setCursor 3 m0

    msr =
      setRows (take 3 dataRows) mG

    flags =
      [ "cur0=" ++ n (cursor m0) ++ " h0=" ++ n (height m0) ++ " w0=" ++ n (width m0) ++ " foc0=" ++ f (focused m0)
      , "cur1=" ++ n (cursor m1) ++ " cur4=" ++ n (cursor m4) ++ " cur5=" ++ n (cursor m5)
      , "curG=" ++ n (cursor mG) ++ " curg=" ++ n (cursor mg) ++ " gb=" ++ n (cursor mGB) ++ " gt=" ++ n (cursor mGT)
      , "blur=" ++ f (focused mb) ++ " blurKey=" ++ n (cursor mb2)
      , "pgdn=" ++ n (cursor mpd) ++ " pgup=" ++ n (cursor mpu) ++ " half=" ++ n (cursor mhd)
      , "setCur=" ++ n (cursor msc) ++ " setRows=" ++ n (cursor msr) ++ " nRows=" ++ n (length (rows msr))
      , "sel0=" ++ String.join "," (selectedRow m0) ++ " selG=" ++ String.join "," (selectedRow mG)
      , "cols=" ++ n (length (columns m0)) ++ " hG=" ++ n (height mG) ++ " wG=" ++ n (width mG)
      , "help=" ++ helpView m0
      ]
  in
  String.join "\n"
    ( append flags
      [ "--- view m0 ---"
      , view m0
      , "--- view m5 ---"
      , view m5
      , "--- view mG ---"
      , view mG
      , "--- view msr ---"
      , view msr
      ]
    )
