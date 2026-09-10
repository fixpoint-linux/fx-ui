module LetClosure exposing (main)

-- A closure created INSIDE a let-body that CAPTURES a let-bound var: the .cur
-- site must reconstruct lex[] (including the live let) into a REAL GC env
-- array for valLambda to copy — the lex frame's env is a C-stack local, so a
-- captured closure cannot share it.
makeAdder x =
    let
        base =
            x + 10
    in
    \y -> base + y


main =
    (makeAdder 5) 3
