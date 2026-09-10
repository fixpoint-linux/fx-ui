module LetDeepRec exposing (main)

-- Non-tail recursion whose body is a LET-body: `go` binds `m` (a let) before
-- recursing non-tail (`1 + go m`), so it runs as a lex[] frame natively until
-- nat_depth_max (256), then falls back to interp.vmExecEnv for the deep
-- remainder.  The lex frame must not break the depth-guarded fallback (result
-- must equal the interpreted one exactly).  20000 is far past 256 yet fits
-- elmvm's default 64MB heap (100000 OOMs the fully-interpreted reference).
go n =
    let
        m =
            n - 1
    in
    if n <= 0 then
        0

    else
        1 + go m


main =
    go 20000
