module Patterns exposing (main)

-- PATTERN TEST ORDER + first-match-wins probe: clauses must be tested in source
-- order with Jmpf fallthrough to the NEXT clause, and the first match wins.
-- Also exercises nested cons patterns, literals, wildcards, and tuple patterns.
classify x =
    case x of
        0 ->
            100

        1 ->
            101

        2 ->
            102

        _ ->
            999

fst3 t =
    case t of
        ( a, _, _ ) ->
            a

unwrapList l =
    case l of
        [ x ] ->
            x * 10

        [ x, y ] ->
            x + y

        _ ->
            0

main =
    classify 2 + classify 5 + fst3 ( 7, 9, 11 ) + unwrapList [ 4 ] + unwrapList [ 1, 2 ]
