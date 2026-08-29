module CmpOrder exposing (main)

-- Structural Basics.compare gate (gate: char-code wrapper ARG ORDER first —
-- "ab" vs "b" must be LT via byte 97 < 98; a flipped wrapper would feed the
-- prim a number as the string).  Covers Int/Float/Int-Float-promotion,
-- Strings, Chars, (Int,Int) tuples incl. the equal-prefix EQ path (terminal
-- cdr compared via `compare` itself), and lists incl. the [] prefix rule.

render o =
    case o of
        LT ->
            "LT"

        EQ ->
            "EQ"

        GT ->
            "GT"


show a b =
    render (compare a b)


main =
    Prelude.join " "
        [ show 3 5
        , show 5 3
        , show 2 2
        , show 1.5 2.5
        , show 2 2.0
        , show "ab" "b"
        , show "b" "ab"
        , show "ab" "ab"
        , show 'a' 'b'
        , show 'a' 'a'
        , show (1, 2) (1, 3)
        , show (1, 2) (1, 2)
        , show (2, 1) (1, 9)
        , show [ 1, 2 ] [ 1, 3 ]
        , show [ 1, 2 ] [ 1, 2 ]
        , show [ 1, 2 ] [ 1, 2, 0 ]
        , show [] [ 0 ]
        , show [] []
        ]
