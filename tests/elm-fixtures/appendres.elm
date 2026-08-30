module Appendres exposing (main)

-- APPENDABLE (++) resolution: the checker picks String.append for a String
-- append and List.append for a List append at each site.

main =
    let
        s =
            "a" ++ "b"

        l =
            [ 1 ] ++ [ 2 ]
    in
    String.length s + sum l
