module ExecGlob exposing (main)

-- M8 gate: glob.  Globs tests/elm-fixtures/expected/exec*.txt (the three M8
-- expected files themselves), decodes the tagged result list to [String], and
-- joins them — sorted ascending by the VM.

type Msg
    = Got String


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( ""
    , Task.perform Got
        (Task.map (\xs -> String.join "," xs) (Io.glob "tests/elm-fixtures/expected/exec*.txt"))
    )


update msg model =
    case msg of
        Got s ->
            ( s, Cmd.none )
