module Strings exposing (..)

-- M3 gate: string ops end-to-end — escape decoding to raw bytes, UTF-8
-- byte-length String.length, cn concat, fromInt rendering (cn "").

line =
    String.append "a\nb" "\tq"


main =
    let
        -- "héllo" is 6 BYTES (UTF-8 é = 2 bytes); escapes decode at compile
        -- time, so line = a \n b \t q -> 5 raw bytes.
        l1 =
            String.length "héllo"

        l2 =
            String.length line

        joined =
            Prelude.join ", " [ "x", "y", "z" ]

        -- "6" ++ ":" ++ "5" ++ ":" ++ "x, y, z"
        parts =
            String.append
                (String.append (String.fromInt l1) ":")
                (String.append (String.fromInt l2) ":")
    in
    String.append parts joined
