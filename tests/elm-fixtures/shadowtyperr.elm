module Shadowtyperr exposing (main)

-- NEGATIVE fixture pinning the TYPE-NAME half of the import-shadowing check:
-- `Model` is imported bare from Spinner AND declared here as a type alias (an
-- ADT `type Model = ..` behaves identically).  A bare exposing row hides the
-- local type exactly like it hides a same-named function — real Elm rejects
-- the clash; the compiler must fail LOUDLY before typechecking/lowering.

import Spinner exposing (Model)


type alias Model =
    { n : Int }


main =
    0
