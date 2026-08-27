module MxInt exposing (main)

-- MX gate (main : Int): a composed pure-core program exercising the ADT
-- vector rep (Expr eval via case), records (construct/access/update), lists +
-- Prelude map/foldl, a Maybe round-trip, and float arith + == + if — all in
-- one main that sums to 175.

type Expr
    = Num Int
    | Add Expr Expr
    | Mul Expr Expr


eval e =
    case e of
        Num n ->
            n

        Add a b ->
            eval a + eval b

        Mul a b ->
            eval a * eval b


type alias Point =
    { x : Int, y : Int }


scale k p =
    { p | x = p.x * k, y = p.y * k }


distance p q =
    let
        dx =
            p.x - q.x

        dy =
            p.y - q.y
    in
    dx * dx + dy * dy


circleArea r =
    3.0 * r * r


main =
    let
        p =
            { x = 3, y = 4 }

        q =
            scale 2 p

        d =
            distance p q

        ast =
            Add (Mul (Num 2) (Num 3)) (Num 4)

        nums =
            [ 1, 2, 3, 4, 5 ]

        doubled =
            Prelude.map (\x -> x * 2) nums

        total =
            Prelude.foldl (+) 0 doubled

        maybe =
            maybeWithDefault 0 (Just (eval ast))

        check =
            if circleArea 2.0 == 12.0 then
                100

            else
                0
    in
    d + total + maybe + eval ast + check
