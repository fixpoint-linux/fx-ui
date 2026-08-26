module BigList exposing (..)

-- M3 gate: Prelude list API over 1000 elements — map / filter / foldl,
-- tail-recursive walkers, plus a Maybe round-trip.  Build the input INSIDE
-- Elm (range1000 ++ [1000]) so no gate-arg plumbing is needed.

-- Tail-recursive ascending range (accumulator; `++` is forbidden).
range n acc =
    if n <= 0 then
        acc

    else
        range (n - 1) (n :: acc)


data =
    range 1000 []


doubled =
    Prelude.map (\x -> x * 2) data


evens =
    Prelude.filter (\x -> x // 2 * 2 == x) doubled


main =
    let
        total =
            Prelude.foldl (+) 0 evens

        -- evens = [4, 8, ..., 2000]; sum via pairs:
        --   pairs sum    = 2*(2+4+...+1000) = 2*250500 = 501000
        --   count        = 500
        count =
            Prelude.length evens

        wrapped =
            maybeWithDefault 0 (Just total)
    in
    -- 501000 + 500 + 501000
    total + count + wrapped
