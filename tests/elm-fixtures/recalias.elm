module Recalias exposing (main)

-- TYPE ALIAS with a row generic, APPLIED: `Named { age : Int }` expands to
-- `{ name : String, age : Int }` (the row argument splices into the tail).
-- `ageOf` reads a field that came from the argument row; `nameOf` reads the
-- alias's own field.

type alias Named r =
    { name : String | r }


ageOf : Named { age : Int } -> Int
ageOf p =
    p.age


nameOf : Named { age : Int } -> String
nameOf p =
    p.name


main =
    let
        a =
            ageOf { name = "alice", age = 30 }

        b =
            String.length (nameOf { name = "bob", age = 40 })
    in
    a + b
