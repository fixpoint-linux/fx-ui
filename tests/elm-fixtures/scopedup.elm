module Scopedup exposing (main)

-- SCOPED-LABEL UPDATE: an update { p | x = v } does NOT change the row shape
-- (restrict + extend keeps the tail r); p is a row-polymorphic parameter.

incX : { x : Int | r } -> { x : Int | r }
incX p =
    { p | x = p.x + 1 }


main =
    let
        a =
            incX { x = 1, y = 2 }

        b =
            incX { x = 5, y = 3, z = 4 }
    in
    a.x + a.y + b.x + b.y + b.z
