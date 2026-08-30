module Shadowerr exposing (main)

-- NEGATIVE fixture pinning the import-shadowing compile error: `update`/`view`
-- are both imported bare from Viewport AND defined top-level here.  This used
-- to resolve SILENTLY to the imported (wrong-typed) functions — a widget demo
-- then "segfaulted" on quit.  Real Elm rejects the clash; the compiler must
-- fail LOUDLY with the shadowing error (never reach typechecking/lowering).

import Viewport exposing (update, view)


update : Int -> Int
update n =
    n + 1000


view : Int -> Int
view n =
    n * 2


main =
    update 1
