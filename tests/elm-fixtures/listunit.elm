module ListUnit exposing (main)

-- S6 gate (main : String): core-libs/ListBox.elm (bubbles list — the
-- filterable, paginated list).  Flags pin the page-flip cursor logic (R6, the
-- subtlest port): 12 items at 40x19 -> perPage 4 (availHeight = 19 - 7 chrome
-- rows = 12, /3), 3 pages, crossing the page boundary in BOTH directions.
-- VISIBLE strings carry the byte-exact renders: title/status/populated/
-- pagination/help joined vertically, the selected item's left border, the
-- dimmed filtering state, the "“es” N items • M filtered" applied state.
--
-- 12 items: descriptions "west/north/test/south/rest/apple/best/kiwi/chest/
-- lemon/guest/grape" — "es" matches exactly the 6 with "es" (west test rest
-- best chest guest), titles "Item NN" never match.  "zzz" matches nothing
-- (the Nothing-matched status).
--
-- ESC/SGR bytes only ever live INSIDE the program (the kbunit discipline): the
-- only hand-composed escape is none at all — every SGR byte is produced by
-- Lipgloss.render inside ListBox.  The expected file is byte-verified by eye
-- against the Go list.go render pipeline.

import ListBox exposing (cursor, filterValue, index, isFilterApplied, isFiltering, new, page, update, view, visibleCount)


f : Bool -> String
f b =
  case b of
    True ->
      "1"

    False ->
      "0"


fst : ListBox.Model -> String
fst m =
  if isFiltering m then
    "flt"

  else if isFilterApplied m then
    "app"

  else
    "unf"


n : Int -> String
n =
  String.fromInt


items : List ListBox.Item
items =
  [ { title = "Item 00", description = "west" }
  , { title = "Item 01", description = "north" }
  , { title = "Item 02", description = "test" }
  , { title = "Item 03", description = "south" }
  , { title = "Item 04", description = "rest" }
  , { title = "Item 05", description = "apple" }
  , { title = "Item 06", description = "best" }
  , { title = "Item 07", description = "kiwi" }
  , { title = "Item 08", description = "chest" }
  , { title = "Item 09", description = "lemon" }
  , { title = "Item 10", description = "guest" }
  , { title = "Item 11", description = "grape" }
  ]


main =
  let
    m0 =
      new items 40 19

    m1 =
      update (KeyChar "j") m0

    m2 =
      update (KeyChar "j") m1

    m3 =
      update (KeyChar "j") m2

    m4 =
      update (KeyChar "j") m3

    m5 =
      update (KeyChar "k") m4

    m6 =
      update (KeyChar "G") m5

    m7 =
      update (KeyChar "g") m6

    mf0 =
      update (KeyChar "/") m7

    mf1 =
      update (KeyChar "e") mf0

    mf2 =
      update (KeyChar "s") mf1

    mf3 =
      update KeyEsc mf2

    mf4 =
      update (KeyChar "/") mf3

    mf5 =
      update (KeyChar "e") mf4

    mf6 =
      update (KeyChar "s") mf5

    mf7 =
      update KeyEnter mf6

    mz0 =
      update (KeyChar "/") m7

    mz1 =
      update (KeyChar "z") mz0

    mz2 =
      update (KeyChar "z") mz1

    mz3 =
      update (KeyChar "z") mz2

    -- Go parity (list.go:872-875): the prevPage/nextPage KEYS flip the
    -- paginator RAW — the cursor is left untouched and may fall out of range
    -- on a partial last page (no selection until the next move).  10 items at
    -- 40x19 -> perPage 4, 3 pages, page 2 holds only 2 items.
    mp0 =
      new (take 10 items) 40 19

    mp3 =
      update (KeyChar "j") (update (KeyChar "j") (update (KeyChar "j") mp0))

    mp4 =
      update (KeyChar "l") mp3

    mp5 =
      update (KeyChar "l") mp4

    mp6 =
      update (KeyChar "h") mp5

    flags =
      [ "idx0=" ++ n (index m0) ++ " pg0=" ++ n (page m0) ++ " cur0=" ++ n (cursor m0)
      , "idx3=" ++ n (index m3) ++ " pg3=" ++ n (page m3) ++ " cur3=" ++ n (cursor m3)
      , "idx4=" ++ n (index m4) ++ " pg4=" ++ n (page m4) ++ " cur4=" ++ n (cursor m4)
      , "idx5=" ++ n (index m5) ++ " pg5=" ++ n (page m5) ++ " cur5=" ++ n (cursor m5)
      , "idx6=" ++ n (index m6) ++ " pg6=" ++ n (page m6) ++ " cur6=" ++ n (cursor m6)
      , "idx7=" ++ n (index m7)
      , "mf0=" ++ fst mf0 ++ " vis=" ++ n (visibleCount mf0) ++ " v=" ++ filterValue mf0
      , "mf2=" ++ fst mf2 ++ " vis=" ++ n (visibleCount mf2) ++ " v=" ++ filterValue mf2
      , "mf3=" ++ fst mf3 ++ " vis=" ++ n (visibleCount mf3)
      , "mf7=" ++ fst mf7 ++ " vis=" ++ n (visibleCount mf7) ++ " v=" ++ filterValue mf7
      , "mz3=" ++ fst mz3 ++ " vis=" ++ n (visibleCount mz3)
      , "mp3 pg=" ++ n (page mp3) ++ " cur=" ++ n (cursor mp3)
      , "mp4 pg=" ++ n (page mp4) ++ " cur=" ++ n (cursor mp4)
      , "mp5 pg=" ++ n (page mp5) ++ " cur=" ++ n (cursor mp5)
      , "mp6 pg=" ++ n (page mp6) ++ " cur=" ++ n (cursor mp6)
      ]
  in
  String.join "\n"
    ( append flags
      [ "--- view m0 ---"
      , String.join "\n" (view m0)
      , "--- view m4 ---"
      , String.join "\n" (view m4)
      , "--- view mf2 ---"
      , String.join "\n" (view mf2)
      , "--- view mf7 ---"
      , String.join "\n" (view mf7)
      , "--- view mz3 ---"
      , String.join "\n" (view mz3)
      , "--- view mp5 ---"
      , String.join "\n" (view mp5)
      ]
    )
