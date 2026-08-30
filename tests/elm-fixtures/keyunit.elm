module KeyUnit exposing (main)

-- STEP 1 (compiler surface): prove the foreign Key ADT BEFORE the host builds
-- it.  Builds Key values + case-matches them with UNQUALIFIED ctor names (the
-- bare rows in Lower.Resolve.platformTable — qualified foreign ctor PATTERNS
-- are rejected in Lower.Pattern), and roundtrips a real-Elm \u{1B} ANSI escape
-- through the length-prefixed csexp string encoding (byte-exact).

tag key =
    case key of
        KeyChar s ->
            String.append "char:" s

        KeyEnter ->
            "enter"

        KeyTab ->
            "tab"

        KeyBackspace ->
            "backspace"

        KeyEsc ->
            "esc"

        KeyUp ->
            "up"

        KeyDown ->
            "down"

        KeyLeft ->
            "left"

        KeyRight ->
            "right"

        KeyHome ->
            "home"

        KeyEnd ->
            "end"

        KeyPgUp ->
            "pgup"

        KeyPgDn ->
            "pgdn"

        KeyIns ->
            "ins"

        KeyDel ->
            "del"

        KeyCtrl c ->
            String.append "ctrl:" c

        KeyOther n ->
            String.append "other:" (String.fromInt n)

        KeyEof ->
            "eof"


main =
    let
        tags =
            Prelude.join " "
                [ tag (KeyChar "a")
                , tag KeyEnter
                , tag KeyTab
                , tag KeyBackspace
                , tag KeyEsc
                , tag KeyUp
                , tag KeyDown
                , tag KeyLeft
                , tag KeyRight
                , tag KeyHome
                , tag KeyEnd
                , tag KeyPgUp
                , tag KeyPgDn
                , tag KeyIns
                , tag KeyDel
                , tag (KeyCtrl "c")
                , tag (KeyOther 27)
                , tag KeyEof
                ]

        -- Real-Elm escape spelling: \u{1B} must reach the VM as the raw 0x1B
        -- byte.  charCode indexes the BYTES (String.length counts code points).
        ansi =
            "\u{1B}[2K"

        ansiSummary =
            Prelude.join " "
                [ "ansi"
                , String.fromInt (charCode ansi 0)
                , String.fromInt (charCode ansi 1)
                , String.fromInt (charCode ansi 2)
                , String.fromInt (charCode ansi 3)
                , String.append "len" (String.fromInt (String.length ansi))
                ]
    in
    String.append tags (String.append " " ansiSummary)
