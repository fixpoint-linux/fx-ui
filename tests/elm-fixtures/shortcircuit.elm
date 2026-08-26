module ShortCircuit exposing (main)

-- SHORT-CIRCUIT probe: `&&`/`||` must NOT evaluate the right operand when the
-- left already decides.  `loop` never terminates, so if `&&`/`||` eagerly
-- evaluated its argument the program would hang; finishing fast proves the
-- right side was skipped.  Also `==` on a deep cons structure (structural).
loop n =
    loop (n + 1)

main =
    let
        a =
            False && loop 1

        b =
            True || loop 1

        c =
            [ [ 1, 2 ], [ 3 ] ] == [ [ 1, 2 ], [ 3 ] ]

        d =
            [ [ 1, 2 ], [ 3 ] ] /= [ [ 1, 2 ], [ 4 ] ]
    in
    if a || b then
        1
    else if c && d then
        2
    else
        3
