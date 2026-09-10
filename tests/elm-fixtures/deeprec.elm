module DeepRec exposing (..)

-- R1 gate (native-depth guard with interpreted fallback): NON-TAIL recursion
-- over a 100K-element list.  `sumR` (non-tail: `x + sumR rest`) and
-- `appendR` (non-tail: `x :: appendR rest`) each recurse 100000 deep — far
-- past any C stack, and past concatMap's 551-frame crash — so the AOT binary
-- can only finish by falling back to interp.vmExecEnv at depth.  The
-- interpreter runs the deep remainder in its flat loop (pooled call frames),
-- so the AOT result must equal the interpreted one exactly.

range n acc =
    if n <= 0 then
        acc

    else
        range (n - 1) (n :: acc)


input =
    range 100000 []


sumR xs =
    case xs of
        x :: rest ->
            x + sumR rest

        [] ->
            0


appendR xs =
    case xs of
        x :: rest ->
            x :: appendR rest

        [] ->
            []


-- non-tail length via appendR's structure (forces the whole list)
len xs =
    case xs of
        _ :: rest ->
            1 + len rest

        [] ->
            0


main =
    let
        total =
            sumR input

        copied =
            appendR input

        n =
            len copied
    in
    -- sum 1..100000 = 5000050000; appendR preserves length 100000
    if total == 5000050000 && n == 100000 then
        "deeprec-ok"

    else
        "deeprec-MISMATCH"
