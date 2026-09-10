module LexSelfTail exposing (main)

-- Coverage for the lex-frame SELF-TAIL path — the one deviation from the
-- implementing brief, and the path that carries the whole lex[] win (the
-- hot list loops are all self-tail recursive).  A self-tail in a lex frame
-- rebuilds lex[] IN PLACE ("lexlen = arity; copy argbuf -> lex; pc = 0"),
-- the analog of rt.tailSelf minus GC array reuse.
--
-- `go` self-tails (the recursive call is in tail position) AND has a live
-- `let` in its core, so it is a lex frame, not a native p[] frame.  A broken
-- in-place rebuild (args copied to the wrong slots, or lexlen left stale)
-- yields a wrong accumulator rather than a crash, so this compares against
-- elmvm like every other fixture.
go acc n =
    let
        next =
            n - 1
    in
    if n <= 0 then
        acc

    else
        go (acc + n) next


main =
    go 0 1000
