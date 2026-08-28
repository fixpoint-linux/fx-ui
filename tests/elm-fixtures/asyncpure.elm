module AsyncPure exposing (main)

-- M9 gate: pure task spawn chain under Platform.program.  Cmd.batch issues two
-- pure tasks; the SECOND task's update spawns a third.  Because spawn() reuses
-- the lowest inactive slot, the third task lands in a slot stepAll's cursor
-- already passed — the blocker's cursor-skip path would drop it (model "ab").
-- The fixpoint drain must deliver it (model "abc").

type Msg
    = A
    | B
    | C


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( ""
    , Cmd.batch
        [ Task.perform (\_ -> A) (Task.succeed ())
        , Task.perform (\_ -> B) (Task.succeed ())
        ]
    )


update msg model =
    case msg of
        A ->
            ( String.append model "a", Cmd.none )

        B ->
            ( String.append model "b", Task.perform (\_ -> C) (Task.succeed ()) )

        C ->
            ( String.append model "c", Cmd.none )
