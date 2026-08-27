module MxString exposing (main)

-- MX gate (main : String): list-of-records, record access inside a lambda to
-- map, join/fromInt/String.append, string main — exercises the ADT vector rep
-- indirectly (records stay assoc lists) plus the Prelude/String subset.

type alias Person =
    { name : String, age : Int }


greet p =
    String.append "Hi " (String.append p.name "!")


main =
    let
        ann =
            { name = "Ann", age = 30 }

        bo =
            { name = "Bo", age = 25 }

        people =
            [ ann, bo ]

        names =
            Prelude.map (\p -> p.name) people

        joined =
            Prelude.join ", " names

        count =
            Prelude.length people

        label =
            String.fromInt count

        greeting =
            greet ann
    in
    String.append (String.append (String.append label ":") joined) (String.append "|" greeting)
