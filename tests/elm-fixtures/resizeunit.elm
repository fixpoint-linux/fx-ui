module ResizeUnit exposing (main)

-- S5 gate: SIGWINCH window-resize delivery via signalfd + TaskWaitResize under
-- a real pty.  init probes the INITIAL size (Io.winSize = 80x24), then arms
-- Io.waitResize AND Io.readKey.  ptytest's `resize 40 12` directive fires
-- SIGWINCH; the host's shared signalfd wakes the poll loop and completes the
-- armed waitResize eval with the fresh size, which the program prints and
-- re-arms.  readKey stays armed throughout (re-armed only on a key), so 'q'
-- quits via the S3 quit latch while a waitResize is still suspended.
--
-- ARM-ORDER NOTE: the waitResize task is FIRST in the GotProbe command batch.
-- Cmd.batch preserves list order and the host steps evals in spawn order, so
-- leafWaitResize (which BLOCKs SIGWINCH + creates the signalfd) runs BEFORE
-- the "80x24" write is emitted — the first resize can never race the lazy
-- signalfd init.

type Msg
    = GotProbe ( Int, Int )
    | GotResize ( Int, Int )
    | GotKey Runtime.Key
    | Wrote ()


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


sizeTag size =
    String.append (String.fromInt (Tuple.first size))
        (String.append "x" (String.fromInt (Tuple.second size)))


printSize size =
    Io.writeString (String.append (sizeTag size) "\n")


init () =
    ( 0
    , Task.perform GotProbe
        (Task.andThen (\_ -> Io.winSize) (Io.rawMode True))
    )


update msg model =
    case msg of
        GotProbe size ->
            ( model + 1
            , Cmd.batch
                [ Task.perform GotResize Io.waitResize
                , Task.perform GotKey Io.readKey
                , Task.perform Wrote (printSize size)
                ]
            )

        GotResize size ->
            ( model + 1
            , Cmd.batch
                [ Task.perform Wrote (printSize size)
                , Task.perform GotResize Io.waitResize
                ]
            )

        GotKey key ->
            case key of
                KeyChar "q" ->
                    ( model + 1, Task.perform Wrote Io.quit )

                _ ->
                    ( model + 1, Task.perform GotKey Io.readKey )

        Wrote _ ->
            ( model, Cmd.none )
