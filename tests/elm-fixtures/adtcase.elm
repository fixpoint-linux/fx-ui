module AdtCase exposing (main)

-- ADT pattern compiler probe: named-ctor patterns with sub-patterns, nested
-- patterns, and a bare (0-arg) ctor matched by literal.
type Shape
    = Circle Int
    | Rect Int Int
    | Origin

area s =
    case s of
        Circle r ->
            r * r

        Rect w h ->
            w * h

        Origin ->
            0

isOrigin s =
    case s of
        Origin ->
            1

        _ ->
            0

main =
    area (Rect 3 4) + isOrigin Origin
