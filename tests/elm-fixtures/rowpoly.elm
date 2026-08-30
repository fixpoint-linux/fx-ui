module Rowpoly exposing (main)

-- ROW-POLYMORPHIC accessor: a function taking ANY record with an Int x field
-- (open row tail r), called with WIDER records; plus the `.x` accessor as a
-- first-class value handed to List.map.

getX : { x : Int | r } -> Int
getX p =
    p.x


main =
    let
        a =
            getX { x = 1, y = 2 }

        b =
            getX { x = 3, z = 4, w = 5 }

        xs =
            List.map .x [ { x = 10, q = 1 }, { x = 20, q = 2 } ]
    in
    a + b + sum xs
