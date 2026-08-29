module SetOps exposing (main)

-- elm/core Set gate: fromList/insert/remove/member/size/isEmpty/singleton/
-- union/intersect/diff/toList/map/filter/partition/foldl over Int sets.
-- Renders every check as an Int and sums them (hand-computed).


b x =
    case x of
        True ->
            1

        False ->
            0


even x =
    x - (x // 2) * 2 == 0


main =
    let
        s1 =
            Set.fromList [ 3, 1, 4, 1, 5, 9, 2, 6 ]

        size1 =
            Set.size s1

        mem1 =
            b (Set.member 4 s1)

        mem2 =
            b (Set.member 7 s1)

        s2 =
            Set.insert 7 s1

        size2 =
            Set.size s2

        s3 =
            Set.remove 1 s2

        size3 =
            Set.size s3

        m3 =
            b (Set.member 1 s3)

        u =
            Set.union s1 (Set.fromList [ 5, 6, 7 ])

        usize =
            Set.size u

        i =
            Set.intersect s1 (Set.fromList [ 2, 3, 11 ])

        isize =
            Set.size i

        isum =
            Set.foldl (\x acc -> acc + x) 0 i

        dd =
            Set.diff s1 (Set.fromList [ 1, 2, 3 ])

        dsize =
            Set.size dd

        dsum =
            Set.foldl (\x acc -> acc + x) 0 dd

        lsum =
            sum (Set.toList s1)

        msum =
            Set.foldl (\x acc -> acc + x) 0 (Set.map (\x -> x * 2) s1)

        fsize =
            Set.size (Set.filter (\x -> x > 4) s1)

        ( p1, p2 ) =
            Set.partition even s1

        p1size =
            Set.size p1

        p2size =
            Set.size p2

        ie =
            b (Set.isEmpty Set.empty)

        ie2 =
            b (Set.isEmpty s1)

        sing =
            Set.size (Set.singleton 42)
    in
    size1 + mem1 + mem2 + size2 + size3 + m3 + usize + isize + isum + dsize + dsum + lsum + msum + fsize + p1size + p2size + ie + ie2 + sing
