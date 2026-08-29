module ArrayBasic exposing (main)

-- Array basics across the leaf/tail boundary sizes 0/1/5/32/33/64/100
-- (32 = first Leaf, 33 = first tail push past a full Leaf): length +
-- foldl sums + get corners (OOB and OOB-1 unwrap to -1 via
-- Maybe.withDefault), toList==range, set (incl. OOB no-op +
-- persistence), push crossing 31->32->33, fromList/toList roundtrip,
-- map/indexedMap/filter, repeat, append small+crossing, slice (upstream
-- doc cases 1 4 / 0 -1 / -2 5 plus mid 2 3, past-end 5 3, negative both
-- -3 -1, and a big tail slice), toIndexedList through the Tuple module,
-- isEmpty.  Everything renders as one hand-computed Int sum: 20799.

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


main =
    let
        a0 =
            Array.initialize 0 identity

        a1 =
            Array.initialize 1 identity

        a5 =
            Array.initialize 5 identity

        a32 =
            Array.initialize 32 identity

        a33 =
            Array.initialize 33 identity

        a64 =
            Array.initialize 64 identity

        a100 =
            Array.initialize 100 identity

        sizes =
            s a0 + s a1 + s a5 + s a32 + s a33 + s a64 + s a100

        lens =
            Array.length a0
                + Array.length a1
                + Array.length a5
                + Array.length a32
                + Array.length a33
                + Array.length a64
                + Array.length a100

        corners =
            gg a0 0
                + gg a0 0
                + gg a0 0
                + gg a0 (0 - 1)
                + gg a1 0
                + gg a1 0
                + gg a1 1
                + gg a1 (0 - 1)
                + gg a5 0
                + gg a5 4
                + gg a5 5
                + gg a5 (0 - 1)
                + gg a32 0
                + gg a32 31
                + gg a32 32
                + gg a32 (0 - 1)
                + gg a33 0
                + gg a33 32
                + gg a33 33
                + gg a33 (0 - 1)
                + gg a64 0
                + gg a64 63
                + gg a64 64
                + gg a64 (0 - 1)
                + gg a100 0
                + gg a100 99
                + gg a100 100
                + gg a100 (0 - 1)

        toListRange =
            b (Array.toList a0 == rangeTo 0)
                + b (Array.toList a1 == rangeTo 1)
                + b (Array.toList a5 == rangeTo 5)
                + b (Array.toList a32 == rangeTo 32)
                + b (Array.toList a33 == rangeTo 33)
                + b (Array.toList a64 == rangeTo 64)
                + b (Array.toList a100 == rangeTo 100)

        setOps =
            s (Array.set 5 999 a32)
                + s (Array.set 31 7 a32)
                + b (Array.length (Array.set 32 1 a32) == 32)
                + b (s (Array.set 32 1 a32) == 496)
                + b (s a32 == 496)

        a31 =
            Array.initialize 31 identity

        p1 =
            Array.push 31 a31

        p2 =
            Array.push 32 p1

        p3 =
            Array.push 33 p2

        pushOps =
            b (Array.length p1 == 32)
                + b (Array.length p2 == 33)
                + b (Array.length p3 == 34)
                + b (gg p1 31 == 31)
                + b (gg p2 32 == 32)
                + b (gg p3 33 == 33)
                + s p2
                + s p3

        fl100 =
            Array.fromList (rangeTo 100)

        roundtrip =
            b (Array.length fl100 == 100)
                + b (Array.toList fl100 == rangeTo 100)
                + s fl100

        mapOps =
            s (Array.map (\x -> x * 2) a32)
                + s (Array.indexedMap (\i x -> i + x) a32)
                + s (Array.filter (\x -> Bitwise.and x 1 == 0) a32)
                + b (Array.length (Array.filter (\x -> Bitwise.and x 1 == 0) a32) == 16)

        rep =
            Array.repeat 7 5

        repOps =
            s rep
                + b (Array.length rep == 7)
                + b (gg rep 0 == 5)
                + b (gg rep 6 == 5)
                + b (Array.length (Array.repeat 0 9) == 0)

        appendOps =
            s (Array.append a5 a32)
                + s (Array.append a32 a33)
                + b (Array.length (Array.append a5 a32) == 37)
                + b (Array.length (Array.append a32 a33) == 65)
                + b (Array.length (Array.append Array.empty a32) == 32)
                + b (s (Array.append Array.empty a32) == 496)

        a5l =
            Array.fromList [ 0, 1, 2, 3, 4 ]

        sliceOps =
            s (Array.slice 1 4 a5l)
                + s (Array.slice 0 (0 - 1) a5l)
                + s (Array.slice (0 - 2) 5 a5l)
                + s (Array.slice 2 3 a5l)
                + b (Array.length (Array.slice 5 3 a5l) == 0)
                + s (Array.slice (0 - 3) (0 - 1) a5l)
                + s (Array.slice 95 100 a100)

        idxOps =
            List.foldl (\p acc -> acc + Tuple.first p) 0 (Array.toIndexedList a5)
                + List.foldl (\p acc -> acc + Tuple.second p) 0 (Array.toIndexedList a5)
                + b (List.length (Array.toIndexedList Array.empty) == 0)

        emptyOps =
            b (Array.isEmpty Array.empty) + b (Array.isEmpty a32)
    in
    sizes
        + lens
        + corners
        + toListRange
        + setOps
        + pushOps
        + roundtrip
        + mapOps
        + repOps
        + appendOps
        + sliceOps
        + idxOps
        + emptyOps
