module Extrec exposing (main)

-- EXTENSIBLE-RECORD TYPE with the tail-LAST row (authentic pre-0.16 order) in
-- a signature, plus an INFERRED open record (a record-pattern argument).

sumXY : { x : Int, y : Int | r } -> Int
sumXY p =
    p.x + p.y


getX { x } =
    x


main =
    let
        a =
            sumXY { x = 2, y = 3 }

        b =
            sumXY { x = 4, y = 5, z = 6 }

        c =
            getX { x = 7 }

        d =
            getX { x = 8, y = 9 }
    in
    a + b + c + d
