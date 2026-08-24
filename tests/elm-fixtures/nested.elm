module Nested exposing (main)

main =
    let
        a =
            2

        b =
            3
    in
    if a + b > 4 then
        let
            c =
                a * b
        in
        c + 1
    else
        0
