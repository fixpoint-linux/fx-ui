module IoFile exposing (main)

-- M6 gate: file round-trip.  RdFile reads hello.txt, update builds the final
-- model, WrFile writes it back to out/hello.out; the loop then returns the
-- final String model (printed by elmvm).

type Msg
    = Loaded String


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( "", Cmd.readFile "tests/elm-fixtures/input/hello.txt" Loaded )


update msg model =
    case msg of
        Loaded contents ->
            let
                out =
                    String.append "echo:" contents
            in
            ( out, Cmd.writeFile "tests/elm-fixtures/out/hello.out" out )
