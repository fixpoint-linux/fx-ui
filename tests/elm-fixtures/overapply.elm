module OverApply exposing (main)

f x y =
    \z -> x * y + z


main =
    f 2 3 4
