module TaskPure exposing (main)

-- M7 gate: pure Task composition (no I/O) — isolates the runTask scheduler
-- from the stream leaves.  andThen + map + succeed compose to 42:
--   succeed 1 -> map (+20) -> 21 -> andThen (*2) -> 42.

type Msg
    = Got Int


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( 0
    , Task.perform Got
        (Task.andThen (\x -> Task.succeed (x * 2))
            (Task.map (\n -> n + 20) (Task.succeed 1))
        )
    )


update msg model =
    case msg of
        Got n ->
            ( n, Cmd.none )
