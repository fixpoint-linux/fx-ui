module MouseUnit exposing (main)

-- S4 (host mouse input): prove SGR mouse decode + TaskMouseMode + TaskReadMouse
-- end-to-end under a real pseudo-terminal.  init enables AllMotion mouse
-- tracking (1006+1003), prints READY, then arms readMouse; every mouse event
-- echoes "M:<kind>" and re-arms readMouse AND readKey; 'q' quits via Io.quit
-- (the S3 quit latch — the other suspended read stays armed).  Driven by the
-- HOST event loop (Platform.program), not the sync worker.

type Msg
    = GotMouse Runtime.MouseMsg
    | GotKey Runtime.Key
    | Wrote ()


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


actionTag a =
    case a of
        MousePress ->
            "press"

        MouseRelease ->
            "release"

        MouseMotion ->
            "motion"

        MouseWheel ->
            "wheel"


buttonTag b =
    case b of
        MouseLeft ->
            "left"

        MouseMiddle ->
            "middle"

        MouseRight ->
            "right"

        MouseNone ->
            "none"

        MouseWheelUp ->
            "up"

        MouseWheelDown ->
            "down"

        MouseWheelLeft ->
            "wleft"

        MouseWheelRight ->
            "wright"


mouseTag m =
    case m of
        MouseEof ->
            "eof"

        MouseMsg action button x y ->
            String.append (actionTag action)
                (String.append ":"
                    (String.append (buttonTag button)
                        (String.append "@"
                            (String.append (String.fromInt x)
                                (String.append "," (String.fromInt y))))))


marker m =
    String.append "M:" (String.append (mouseTag m) "\n")


reArmBoth =
    Cmd.batch
        [ Task.perform GotMouse Io.readMouse
        , Task.perform GotKey Io.readKey
        ]


init () =
    ( 0
    , Task.perform GotMouse
        (Task.andThen (\_ -> Io.readMouse)
            (Task.andThen (\_ -> Io.writeString "READY\n")
                (Task.andThen (\_ -> Io.mouseMode AllMotion) (Io.rawMode True))))
    )


update msg model =
    case msg of
        GotMouse m ->
            ( model + 1
            , Cmd.batch
                [ Task.perform Wrote (Io.writeString (marker m))
                , reArmBoth
                ]
            )

        GotKey key ->
            case key of
                KeyChar "q" ->
                    ( model + 1, Task.perform Wrote Io.quit )

                _ ->
                    ( model + 1, reArmBoth )

        Wrote _ ->
            ( model, Cmd.none )
