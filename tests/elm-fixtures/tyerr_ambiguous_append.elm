module TyerrAmbiguousAppend exposing (main)

-- An (++) whose operand type never becomes String or List is AMBIGUOUS and
-- must be rejected at the end-of-declaration zonk.

main =
    let
        cat x =
            x ++ x
    in
    cat
