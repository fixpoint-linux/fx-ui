module Closure exposing (main)

makeAdder x =
    \y -> x + y


main =
    (makeAdder 5) 3
