module Aux exposing (..)

-- M3 gate (multi-module): the IMPORTED side.  Deliberately exercised through
-- every legal reference form: bare (via exposing), dotted, and self-qualified.

double x =
    x * 2


{-| Documented doc comment (parser stress).
-}
add a b =
    a + b


twice f x =
    f (f x)
