module IoEcho exposing (main)

-- M6 gate: stdin echo-until-quit.  Proves fd0 read (readLine via read-byte),
-- fd1 write (writeString via write-byte), Cmd.batch, and the update loop.
-- stdin = input/echo.txt ("hello\nworld\nquit\n"); echoed lines go to stdout
-- and the final Int count (2) is the model.

type Msg
    = Line String


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( 0, Cmd.readLine Line )


update msg model =
    case msg of
        Line text ->
            if text == "quit" then
                ( model, Cmd.none )

            else
                ( model + 1, Cmd.batch [ Cmd.writeString (String.append text "\n"), Cmd.readLine Line ] )
