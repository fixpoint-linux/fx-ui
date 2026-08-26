module CountCase exposing (main)

-- TAIL-APPTerm probe: the recursive call in the second clause body is in a
-- genuine tail position (the case is the function body).  It must compile to
-- `t` (appterm), not `p` (apply), or a 100000-deep loop overflows the call
-- stack (CALL_STACK_DEPTH=65536).  Expected 0.
count n =
    case n of
        0 ->
            0

        _ ->
            count (n - 1)

main =
    count 100000
