module AdtEval exposing (main)

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

main =
    eval (Mul (Add (Num 2) (Num 3)) (Num 4))
