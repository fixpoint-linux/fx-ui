module LetCase exposing (main)

-- ENDLET-BALANCE probe: the case scrutinee temp's Endlet must be emitted
-- exactly once in non-tail position, and the per-clause binding Endlets must
-- not leak.  If the scrutinee Endlet is forgotten, the outer `a`/`c` below
-- resolve to stale slots (expected 4 would fail as 102).
main =
    let
        a =
            case [ 1, 2, 3 ] of
                x :: _ ->
                    x

                [] ->
                    0

        c =
            a + 3
    in
    c
