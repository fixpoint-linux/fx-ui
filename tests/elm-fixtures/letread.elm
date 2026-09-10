module LetRead exposing (main)

-- Off-by-one probe for the lex[] local-env frame: `a` is bound FIRST (lower
-- env slot), `b` SECOND (higher).  Reading `a` AFTER `b` is pushed must index
-- from the TOP (lex[lexlen-1-n], mirroring lookupEnv), not from the bottom
-- (S2's p[i] rule).  A bottom-index bug reads `b` instead of `a`, turning the
-- answer -1 into 1.
f x =
    let
        a =
            x + 1

        b =
            x + 2
    in
    a - b


main =
    f 0
