module DictStress exposing (main)

-- Dict under load: 1009 entries inserted in a deterministically shuffled
-- order (i * 856 mod 1009 + 1 — 856 coprime with the prime 1009, so a full
-- permutation), then size/foldl sums, a keys-ascending foldl check, removal
-- of every 3rd key (heavy moveRedLeft/moveRedRight/removeMin traffic) and
-- spot re-gets.  Everything renders as one Int sum (hand-computed).


boolToInt x =
    case x of
        True ->
            1

        False ->
            0


g d k =
    case Dict.get k d of
        Just v ->
            v

        Nothing ->
            -1


upToGo i hi acc =
    if i > hi then
        acc

    else
        upToGo (i + 1) hi (i :: acc)


upTo hi =
    Prelude.reverse (upToGo 1 hi [])


shuf i =
    (i * 856 - (i * 856 // 1009) * 1009) + 1


threes n hi =
    if n > hi then
        []

    else
        n :: threes (n + 3) hi


main =
    let
        ks =
            List.map shuf (upTo 1009)

        dict =
            Dict.fromList (List.map (\k -> ( k, k * 2 )) ks)

        size =
            Dict.size dict

        keySum =
            Dict.foldl (\k _ acc -> acc + k) 0 dict

        valSum =
            Dict.foldl (\_ v acc -> acc + v) 0 dict

        mono =
            Dict.foldl (\k _ p -> case p of
                ( prev, bad ) ->
                    ( k, bad + boolToInt (k < prev) )
              ) ( -1, 0 ) dict

        monoBad =
            case mono of
                ( prev, bad ) ->
                    bad

        removed =
            List.foldl (\k d -> Dict.remove k d) dict (threes 3 1009)

        rsize =
            Dict.size removed

        g2 =
            g removed 2

        g3 =
            g removed 3

        g1009 =
            g removed 1009

        dg3 =
            g dict 3

        dg505 =
            g dict 505
    in
    size + keySum + valSum + monoBad + rsize + g2 + g3 + g1009 + dg3 + dg505
