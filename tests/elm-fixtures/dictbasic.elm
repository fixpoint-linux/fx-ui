module DictBasic exposing (main)

-- elm/core Dict gate: insert/get/member/remove/update/size/isEmpty/keys/
-- values/toList/fromList/filter/partition/union/intersect/diff/merge over
-- Int keys, plus a remove-heavy sequence over a 9-node tree exercising
-- moveRedLeft/moveRedRight/removeMin.  Renders every check as an Int and
-- sums them (expected value hand-computed).


b x =
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
            -999


main =
    let
        d1 =
            Dict.fromList [ ( 1, 10 ), ( 2, 20 ), ( 3, 30 ) ]

        g1 =
            g d1 2

        g2 =
            g d1 9

        m1 =
            b (Dict.member 3 d1)

        m2 =
            b (Dict.member 9 d1)

        s1 =
            Dict.size d1

        d2 =
            Dict.remove 2 d1

        s2 =
            Dict.size d2

        g3 =
            g d2 2

        d3 =
            Dict.insert 2 99 d2

        g4 =
            g d3 2

        u1 =
            g (Dict.update 1 (\mv -> case mv of
                Just v ->
                    Just (v + 1)

                Nothing ->
                    Nothing
              ) d1) 1

        u2 =
            g (Dict.update 7 (\mv -> case mv of
                Just v ->
                    Just v

                Nothing ->
                    Just 5
              ) d1) 7

        ksum =
            sum (Dict.keys d1)

        vsum =
            sum (Dict.values d1)

        tlsum =
            sum (List.map (\p -> case p of
                ( k, v ) ->
                    k * 100 + v
              ) (Dict.toList d1))

        fs =
            Dict.size (Dict.filter (\k v -> k > 1) d1)

        ( pa, pb ) =
            Dict.partition (\k v -> k < 3) d1

        pas =
            Dict.size pa

        pbs =
            Dict.size pb

        un =
            Dict.union d1 (Dict.fromList [ ( 3, 999 ), ( 4, 40 ) ])

        us =
            g un 3

        u4 =
            g un 4

        ix =
            Dict.intersect d1 (Dict.fromList [ ( 2, 999 ), ( 9, 9 ) ])

        isc =
            g ix 2

        iss =
            Dict.size ix

        df =
            Dict.diff d1 (Dict.fromList [ ( 2, 0 ) ])

        dfs =
            Dict.size df

        dfg =
            g df 2

        big =
            Dict.fromList [ ( 5, 1 ), ( 2, 2 ), ( 8, 3 ), ( 1, 4 ), ( 3, 5 ), ( 6, 6 ), ( 9, 7 ), ( 4, 8 ), ( 7, 9 ) ]

        rm1 =
            Dict.remove 1 big

        rm2 =
            Dict.remove 5 rm1

        rm3 =
            Dict.remove 9 rm2

        bsum =
            Dict.foldl (\k v acc -> acc + k) 0 rm3

        bget =
            g rm3 6

        mg =
            Dict.merge (\k v acc -> acc + k) (\k v w acc -> acc + k + v + w) (\k w acc -> acc - k) d1 (Dict.fromList [ ( 3, 7 ), ( 5, 5 ) ]) 0

        se =
            Dict.size (Dict.singleton 42 1)

        ie =
            b (Dict.isEmpty Dict.empty)

        ie2 =
            b (Dict.isEmpty d1)
    in
    g1 + g2 + m1 + m2 + s1 + s2 + g3 + g4 + u1 + u2 + ksum + vsum + tlsum + fs + pas + pbs + us + u4 + isc + iss + dfs + dfg + bsum + bget + mg + se + ie + ie2
