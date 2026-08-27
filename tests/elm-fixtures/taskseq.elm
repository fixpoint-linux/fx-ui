module TaskSeq exposing (main)

-- M7 gate: Task.sequence (source order via foldr) + Cmd.map + Cmd.batch.
-- sequence [succeed 1, succeed 2, succeed 3] -> [1,2,3]; Task.map sum -> 6;
-- Task.perform identity delivers 6; Cmd.map Got wraps it; Cmd.batch holds the
-- one task.  Final model 6.

type Msg
    = Got Int


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( 0
    , Cmd.batch
        [ Cmd.map Got
            (Task.perform identity
                (Task.map sum (Task.sequence [ Task.succeed 1, Task.succeed 2, Task.succeed 3 ]))
            )
        ]
    )


update msg model =
    case msg of
        Got n ->
            ( n, Cmd.none )
