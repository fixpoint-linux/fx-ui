module Insrec exposing (main)

-- RECORD INSERTION { r | x <- v }: free extension onto an existing record,
-- including inserting onto a record that ALREADY has the field — the new pair
-- shadows the old (scoped labels), so `.x` selects the NEW value.

base =
    { y = 1 }


insertX r =
    { r | x <- 5 }


main =
    let
        a =
            insertX base

        b =
            a.x

        c =
            { a | x <- 99 }

        d =
            c.x
    in
    b + d + a.y
