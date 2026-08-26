module BoolCase exposing (main)

-- Boolean patterns arrive as NamedPattern (True/False), not a BoolPattern
-- variant.  They must be tested against the boolean ATOM, not the ADT
-- cons?/fst=tag scheme.
sign b =
    case b of
        True ->
            1

        False ->
            -1

main =
    sign True + sign False
