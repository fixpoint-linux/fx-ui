module IoEcho exposing (main)

-- M7 gate: stdin echo-until-quit via the Task kernel.  Proves fd0 read
-- (readLine via read-byte), fd1 write (writeString via write-byte), Cmd.batch,
-- and the update loop.  stdin = input/echo.txt ("hello\nworld\nquit\n");
-- echoed lines go to stdout and the final Int count (2) is the model.
--
-- Io.writeString then Io.readLine are chained with Task.andThen (always
-- Io.readLine): the write's unit result is discarded, then a line is read and
-- delivered as the Line msg.

type Msg
    = Line String


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( 0, Task.perform Line (Io.readLine) )


update msg model =
    case msg of
        Line text ->
            if text == "quit" then
                ( model, Cmd.none )

            else
                ( model + 1, Cmd.batch [ Task.perform Line (Task.andThen (always Io.readLine) (Io.writeString (String.append text "\n"))) ] )
