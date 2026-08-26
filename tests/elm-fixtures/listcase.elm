module ListCase exposing (main)

sum xs =
    case xs of
        [] ->
            0

        x :: rest ->
            x + sum rest

main =
    sum [ 1, 2, 3, 4, 5 ]
