module Records exposing (main)

-- RECORD CRUD probe: construct, access, update (prepend-shadow), record pattern
-- destructuring in a let, and an accessor function value.
type alias Point =
    { x : Int, y : Int }

origin =
    { x = 0, y = 0 }

shift p dx dy =
    { p | x = p.x + dx, y = p.y + dy }

sumCoords { x, y } =
    x + y

main =
    let
        p =
            { x = 3, y = 4 }

        q =
            shift origin 10 20

        ( { x, y } ) =
            ( { x = 1, y = 2 } )
    in
    p.x + p.y + q.x + q.y + x + y
