module IoFile exposing (main)

-- M7 gate: file round-trip via the Task kernel.  Io.readFile reads hello.txt
-- (a Task Never String), update builds the final model, Io.writeFile writes it
-- back to out/hello.out through a nullary Saved msg (the write must route
-- through a msg, else `()` becomes the delivered msg — message-delivery trap);
-- the loop then returns the final String model (printed by elmvm).

type Msg
    = Loaded String
    | Saved


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( "", Task.perform Loaded (Io.readFile "tests/elm-fixtures/input/hello.txt") )


update msg model =
    case msg of
        Loaded contents ->
            let
                out =
                    String.append "echo:" contents
            in
            ( out, Task.perform (always Saved) (Io.writeFile "tests/elm-fixtures/out/hello.out" out) )

        Saved ->
            ( model, Cmd.none )
