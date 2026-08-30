module TyerrArity exposing (main)

-- Applying a concrete non-function (an Int) to an argument is an arity error.

answer : Int -> Int
answer x =
    x + 1


main =
    answer 1 2
