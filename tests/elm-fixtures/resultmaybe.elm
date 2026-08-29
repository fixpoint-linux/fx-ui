module ResultMaybe exposing (main)

-- elm/core Maybe + Result API gate: map/map2/map3/withDefault/andThen/
-- isJust (Maybe) and map/map2/map3/withDefault/andThen/mapError/toMaybe/
-- fromMaybe/isOk (Result).  Renders every check as a String chunk joined
-- with spaces (hand-computed; Nothing/Err render as N/E markers).


showInt mx =
    case mx of
        Just v ->
            String.fromInt v

        Nothing ->
            "N"


showRes r =
    case r of
        Ok v ->
            String.append "O" (String.fromInt v)

        Err _ ->
            "E"


showErr re =
    case re of
        Err e ->
            String.append "E" (String.fromInt e)

        Ok _ ->
            "ok"


b x =
    case x of
        True ->
            1

        False ->
            0


main =
    let
        m1 =
            Maybe.map (\x -> x + 1) (Just 41)

        m2 =
            Maybe.withDefault 7 Nothing

        m3 =
            Maybe.andThen (\x -> if x > 10 then Just x else Nothing) (Just 12)

        m4 =
            Maybe.andThen (\x -> if x > 10 then Just x else Nothing) (Just 3)

        m5 =
            b (Maybe.isJust (Just 1))

        m6 =
            b (Maybe.isJust Nothing)

        m7 =
            showInt (Maybe.map2 (\a b -> a + b) (Just 3) (Just 4))

        m8 =
            showInt (Maybe.map2 (\a b -> a + b) (Just 3) Nothing)

        m9 =
            showInt (Maybe.map3 (\a b c -> a * 100 + b * 10 + c) (Just 1) (Just 2) (Just 3))

        r1 =
            Result.map (\x -> x * 2) (Ok 21)

        r2 =
            Result.map (\x -> x * 2) (Err "bad")

        r3 =
            Result.withDefault 5 (Ok 9)

        r4 =
            Result.withDefault 5 (Err "x")

        r5 =
            Result.andThen (\x -> Ok (x + 1)) (Ok 41)

        r6 =
            Result.andThen (\x -> Err "no") (Ok 1)

        r7 =
            Result.mapError (\s -> String.length s) (Err "abcd")

        r8 =
            showInt (Result.toMaybe (Ok 77))

        r9 =
            showInt (Result.toMaybe (Err "e"))

        r10 =
            showRes (Result.fromMaybe "dflt" (Just 8))

        r11 =
            showRes (Result.fromMaybe "dflt" Nothing)

        r12 =
            b (Result.isOk (Ok 1))

        r13 =
            b (Result.isOk (Err 2))

        r14 =
            showRes (Result.map3 (\a b c -> a + b + c) (Ok 1) (Ok 2) (Ok 3))
    in
    Prelude.join " "
        [ showInt m1
        , String.fromInt m2
        , showInt m3
        , showInt m4
        , String.fromInt m5
        , String.fromInt m6
        , m7
        , m8
        , m9
        , showRes r1
        , showRes r2
        , String.fromInt r3
        , String.fromInt r4
        , showRes r5
        , showRes r6
        , showErr r7
        , r8
        , r9
        , r10
        , r11
        , String.fromInt r12
        , String.fromInt r13
        , r14
        ]
