module TyerrNumstr exposing (main)

-- A `number` (Int|Float overload) cannot unify with String.

addOne x =
    x + 1


main =
    addOne "hello"
