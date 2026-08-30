module TyerrUpdateMissingField exposing (main)

-- An update { p | x = v } whose label is NOT in the (signature-fixed) record
-- must be rejected: the flagship "does not have field" diagnostic.

f : { y : Int } -> { y : Int }
f p =
    { p | x = 1 }


main =
    f { y = 2 }
