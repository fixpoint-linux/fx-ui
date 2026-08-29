module ArrayStress exposing (main)

-- Array under load across the depth-2 -> depth-3 tree boundary
-- (32*32 = 1024): sizes 1023/1024/1025 plus 1000.  initialize identity
-- sums (n(n-1)/2), set every 32nd index (i -> i+1, so the sum grows by
-- the number of sets), a foldr alternating-difference ORDER check
-- (x - acc over [0..n-1] is -(n/2) for even n, (n-1)/2 for odd),
-- push walking 1023 -> 1026 across the depth boundary, append 1000+100,
-- deep slices (500..1019 and 0..1019), a fromList 1025 roundtrip with a
-- positional order check (element i must sit at index i), get-unwrap
-- corners, map/indexedMap/filter over 1024, and set persistence.
-- Everything renders as one hand-computed Int sum: 7947531.

b x =
    case x of
        True ->
            1

        False ->
            0


rangeHelp lo hi acc =
    if lo > hi then
        List.reverse acc

    else
        rangeHelp (lo + 1) hi (lo :: acc)


rangeTo n =
    rangeHelp 0 (n - 1) []


s arr =
    Array.foldl (\x acc -> acc + x) 0 arr


gg arr i =
    Maybe.withDefault (0 - 1) (Array.get i arr)


setEvery32 i n arr =
    if i < n then
        setEvery32 (i + 32) n (Array.set i (i + 1) arr)

    else
        arr


diff arr =
    Array.foldr (\x acc -> x - acc) 0 arr


main =
    let
        a1000 =
            Array.initialize 1000 identity

        a1023 =
            Array.initialize 1023 identity

        a1024 =
            Array.initialize 1024 identity

        a1025 =
            Array.initialize 1025 identity

        sums =
            s a1023 + s a1024 + s a1025 + s a1000

        setSums =
            s (setEvery32 0 1023 a1023)
                + s (setEvery32 0 1024 a1024)
                + s (setEvery32 0 1025 a1025)

        order =
            diff a1023 + diff a1024 + diff a1025 + diff a1000

        p1 =
            Array.push 1023 a1023

        p2 =
            Array.push 1024 p1

        p3 =
            Array.push 1025 p2

        pushOps =
            b (Array.length p1 == 1024)
                + b (Array.length p2 == 1025)
                + b (Array.length p3 == 1026)
                + b (gg p1 1023 == 1023)
                + b (gg p2 1024 == 1024)
                + b (gg p3 1025 == 1025)
                + s p3

        ap =
            Array.append a1000 (Array.initialize 100 identity)

        appendOps =
            s ap
                + b (Array.length ap == 1100)
                + b (gg ap 999 == 999)
                + b (gg ap 1000 == 0)
                + b (gg ap 1099 == 99)

        sliceOps =
            s (Array.slice 500 1020 a1025)
                + b (Array.length (Array.slice 500 1020 a1025) == 520)
                + s (Array.slice 0 (0 - 5) a1025)

        fl =
            Array.fromList (rangeTo 1025)

        posCheck =
            List.foldl
                (\x p ->
                    case p of
                        ( i, bad ) ->
                            ( i + 1, bad + b (x /= i) )
                )
                ( 0, 0 )
                (Array.toList fl)

        roundtrip =
            b (Array.length fl == 1025)
                + s fl
                + b (Tuple.second posCheck == 0)
                + gg fl 0
                + gg fl 512
                + gg fl 1024

        corners =
            b (gg a1025 1024 == 1024)
                + gg a1025 1025
                + b (gg a1025 (0 - 1) == (0 - 1))

        mapOps =
            s (Array.map (\x -> x + 1) a1024)
                + s (Array.indexedMap (\i x -> i) a1024)

        fev =
            Array.filter (\x -> Bitwise.and x 1 == 0) a1024

        filterOps =
            s fev + b (Array.length fev == 512)

        persist =
            s (Array.set 1000 0 a1025) + b (s a1025 == 524800)
    in
    sums
        + setSums
        + order
        + pushOps
        + appendOps
        + sliceOps
        + roundtrip
        + corners
        + mapOps
        + filterOps
        + persist
