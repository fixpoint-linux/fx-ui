module ApplyTwice exposing (main)

twice f x =
    f (f x)


add1 x =
    x + 1


main =
    twice add1 10
