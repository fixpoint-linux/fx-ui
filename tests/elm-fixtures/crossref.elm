module CrossRef exposing (main)

add1 x =
    x + 1


add2 x =
    add1 (add1 x)


main =
    add2 40
