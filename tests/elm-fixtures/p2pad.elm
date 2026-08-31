module P2Pad exposing (main)

-- P2-9 gate (main : String): the native Str.repeat prim at n=0/1/40 plus the
-- padLeft/padRight CELL-width interplay that rides it (each pad defers to
-- `repeat d " "` for the space run).  Boolean checks contribute a "1"/"0"
-- flag to one concatenated digit string (position = declaration order), then
-- three VISIBLE strings (repeat 40 "=", padLeft/padRight 6 "ab") joined with
-- "|".  Deterministic and byte-exact — nothing non-printing reaches stdout.


f x =
    case x of
        True ->
            "1"

        False ->
            "0"


main =
    let
        flags =
            String.join ""
                [ -- repeat: n=0, n=1, n=40, negative n, empty string
                  f (Str.repeat 0 "x" == "")
                , f (Str.repeat 0 "" == "")
                , f (Str.repeat 1 "ab" == "ab")
                , f (Str.repeat 40 "ab" == "abababababababababababababababababababababababababababababababababababababababab")
                , f (Str.repeat (0 - 9) "x" == "")
                , f (Str.repeat 3 "" == "")

                -- pad to CELL width: CJK U+4E00 is 2 cells, so the deficit is
                -- w - 2, not w - 1 (the width-interplay pin).
                , f (Str.padLeft 3 "a" == "  a")
                , f (Str.padRight 3 "a" == "a  ")
                , f (Str.padLeft 4 "\u{4E00}" == "  \u{4E00}")
                , f (Str.padRight 4 "\u{4E00}" == "\u{4E00}  ")
                , f (Str.padLeft 2 "abcd" == "abcd")
                , f (Str.padRight 2 "abcd" == "abcd")

                -- n=40 pad: 39 spaces + content (rides the doubling fill).
                , f (Str.padLeft 40 "x" == String.join "" [ Str.repeat 39 " ", "x" ])
                , f (Str.padRight 40 "x" == String.join "" [ "x", Str.repeat 39 " " ])
                ]
    in
    String.join "|"
        [ flags
        , Str.repeat 40 "="
        , Str.padLeft 6 "ab"
        , Str.padRight 6 "ab"
        ]
