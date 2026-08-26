module MultiMod exposing (..)

-- M3 gate (multi-module): cross-module calls in all reference shapes, plus a
-- Prelude list pipeline over imported functions.  Compiled together with
-- auxlib.elm by the gate runner (run.js receives BOTH files; run.elm's
-- module_name scan targets the LAST .elm input = THIS main fixture).

import Aux exposing (add, double, twice)


dotted x =
    Aux.double (Aux.add x 1)


main =
    let
        viaExpose =
            double 21

        -- 42
        viaDotted =
            dotted 20

        -- 42
        higher =
            twice (\n -> add n 3) 36

        -- 42
        piped =
            Prelude.foldl (+) 0 (Prelude.map Aux.double [ 1, 2, 3, 4 ])
    in
    -- 12: only the SECOND result prints; assert the rest via sum:
    if
        viaExpose == 42 && viaDotted == 42 && higher == 42 && piped == 20 then
        42

    else
        0
