module KbUnit exposing (main)

-- S1 gate (main : String): core-libs/Key.elm (bubbles key package) + the new
-- Str.contains / Str.cut.  Every check contributes a "1"/"0" flag to one
-- concatenated digit string (declaration order below), then VISIBLE strings —
-- the keyName row over every Runtime.Key ctor and two Str.cut windows —
-- joined with "|".  ESC bytes only ever live INSIDE the program (compared via
-- ==, the strunit discipline) — nothing non-printing reaches stdout.


f x =
  case x of
    True ->
      "1"

    False ->
      "0"


main =
  let
    -- the keymap under test (viewport-style spellings)
    up =
      Key.newBinding [ "up", "k" ] "↑/k" "move up"

    quit =
      Key.newBinding [ "q", "ctrl+c" ] "q" "quit"

    pause =
      Key.newBinding [ "space" ] "space" "pause"

    -- unbind/setEnabled probes
    off =
      Key.setEnabled False up

    on =
      Key.setEnabled True off

    ub =
      Key.unbind up

    ubHelp =
      Key.help ub

    pauseHelp =
      Key.help pause

    -- keyName over EVERY Runtime.Key ctor
    names =
      String.join ","
        [ Key.keyName (KeyChar "a")
        , Key.keyName (KeyChar " ")
        , Key.keyName KeyEnter
        , Key.keyName KeyTab
        , Key.keyName KeyBackspace
        , Key.keyName KeyEsc
        , Key.keyName KeyUp
        , Key.keyName KeyDown
        , Key.keyName KeyLeft
        , Key.keyName KeyRight
        , Key.keyName KeyHome
        , Key.keyName KeyEnd
        , Key.keyName KeyPgUp
        , Key.keyName KeyPgDn
        , Key.keyName KeyIns
        , Key.keyName KeyDel
        , Key.keyName (KeyCtrl "c")
        , Key.keyName (KeyOther 7)
        , Key.keyName KeyEof
        ]

    -- Str.cut windows (ANSI-free here; the escape-preserving cuts are flags)
    cuts =
      String.join "|"
        [ Str.cut 2 4 "abcdef"
        , Str.cut 0 3 "abcdef"
        , Str.cut 4 2 "abcdef"
        , Str.cut 3 99 "abc"
        , Str.cut 1 4 "一二三"
        , Str.cut 0 3 "一二三"
        ]
  in
  String.join "|"
    [ String.join ""
        [ -- keyName spellings (Go key.String() parity)
          f (Key.keyName (KeyChar "a") == "a")
        , f (Key.keyName (KeyChar " ") == "space")
        , f (Key.keyName KeyEnter == "enter")
        , f (Key.keyName KeyTab == "tab")
        , f (Key.keyName KeyBackspace == "backspace")
        , f (Key.keyName KeyEsc == "esc")
        , f (Key.keyName KeyUp == "up")
        , f (Key.keyName KeyDown == "down")
        , f (Key.keyName KeyLeft == "left")
        , f (Key.keyName KeyRight == "right")
        , f (Key.keyName KeyHome == "home")
        , f (Key.keyName KeyEnd == "end")
        , f (Key.keyName KeyPgUp == "pgup")
        , f (Key.keyName KeyPgDn == "pgdown")
        , f (Key.keyName KeyIns == "insert")
        , f (Key.keyName KeyDel == "delete")
        , f (Key.keyName (KeyCtrl "c") == "ctrl+c")
        , f (Key.keyName (KeyOther 7) == "7")
        , f (Key.keyName KeyEof == "eof")

        -- matches matrix: first binding, later binding, space, ctrl, miss
        , f (Key.matches KeyUp [ up, quit, pause ])
        , f (Key.matches (KeyChar "k") [ up, quit, pause ])
        , f (Key.matches (KeyChar " ") [ up, quit, pause ])
        , f (Key.matches (KeyCtrl "c") [ up, quit, pause ])
        , f (Key.matches (KeyChar "q") [ up, quit, pause ])
        , f (not (Key.matches KeyEsc [ up, quit, pause ]))
        , f (not (Key.matches KeyUp []))
        , f (not (Key.matches KeyEnter [ up, quit, pause ]))

        -- disabled / re-enabled / unbound bindings
        , f (not (Key.matches KeyUp [ off, quit ]))
        , f (Key.matches KeyUp [ on, quit ])
        , f (not (Key.enabled off))
        , f (Key.enabled on)
        , f (not (Key.enabled ub))
        , f (Key.keys ub == [])
        , f (ubHelp.key == "")
        , f (ubHelp.desc == "")
        , f (not (Key.enabled (Key.newBinding [] "x" "y")))
        , f (Key.matches KeyUp [ ub, off ])

        -- accessors round-trip the constructor
        , f (Key.keys up == [ "up", "k" ])
        , f (pauseHelp.key == "space")

        -- Str.contains: prefix, infix, suffix, miss, empty needle/hay,
        -- multibyte needle
        , f (Str.contains "el" "hello")
        , f (Str.contains "he" "hello")
        , f (Str.contains "lo" "hello")
        , f (Str.contains "hello" "hello")
        , f (not (Str.contains "hellp" "hello"))
        , f (not (Str.contains "world" "hello"))
        , f (Str.contains "" "hello")
        , f (not (Str.contains "x" ""))
        , f (Str.contains "" "")
        , f (Str.contains "界界" "世界界面")

        -- Str.cut: escapes verbatim before/after/inside the window,
        -- wide-rune straddle rules, combining mark at cell 0
        , f (Str.cut 0 2 "ab\u{1B}[0mcd" == "ab\u{1B}[0m")
        , f (Str.cut 1 3 "\u{1B}[31mabc" == "\u{1B}[31mbc")
        , f (Str.cut 2 4 "\u{1B}[31mab\u{1B}[0mcd" == "\u{1B}[31m\u{1B}[0mcd")
        , f (Str.cut 0 1 "e\u{0301}x" == "e\u{0301}")
        , f (Str.cut 0 0 "abc" == "")
        , f (Str.cut 0 99 "ab" == "ab")
        ]
    , names
    , cuts
    ]
