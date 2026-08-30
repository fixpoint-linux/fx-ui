module TaskAttempt exposing (main)

-- M7 gate: Task.attempt + Task.fail + Task.onError propagation.  The task fails
-- with "boom"; attempt wraps the Result (Err "boom") and delivers Got; update
-- extracts the error string as the final model (proves fail -> onError ->
-- attempt's Err-wrapper propagation).

type Msg
    = Got (Result String Int)


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( ""
    , Task.attempt Got
        (Task.andThen (\_ -> Task.fail "boom") (Task.succeed ()))
    )


update msg model =
    case msg of
        Got (Ok n) ->
            ( String.fromInt n, Cmd.none )

        Got (Err e) ->
            ( e, Cmd.none )
