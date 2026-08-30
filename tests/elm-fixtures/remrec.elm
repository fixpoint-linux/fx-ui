module Remrec exposing (main)

-- RECORD REMOVAL: Record.remove drops the OUTERMOST occurrence only.  The
-- duplicate-label killer demo: { x = 1, x = 2 } remove x leaves { x = 2 }, so
-- `.x` then selects 2.

main =
    let
        dup =
            { x = 1, x = 2 }

        r1 =
            Record.remove "x" dup

        a =
            r1.x

        r2 =
            Record.remove "x" { x = 5, y = 6 }

        b =
            r2.y
    in
    a + b
