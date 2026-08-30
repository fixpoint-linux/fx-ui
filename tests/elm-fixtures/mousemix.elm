module MouseMix exposing (main)

-- S4 (the queue proof): readKey AND readMouse BOTH armed over the shared fd0,
-- and a single write delivers keys and mouse events INTERLEAVED — the shared
-- decoded-event queue must route each event to the right reader without
-- dropping or mis-routing any.  init = rawMode -> mouseMode AllMotion ->
-- READY, then the Ready delivery arms BOTH reads.  Each event echoes its
-- marker; 'q' quits via the S3 quit latch.

type Msg
    = GotMouse Runtime.MouseMsg
    | GotKey Runtime.Key
    | Ready ()
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


mouseMark m =
    String.append "M:" (String.append (mouseTag m) "\n")


keyMark key =
    case key of
        KeyChar c ->
            String.append "K:" (String.append c "\n")

        KeyEof ->
            "K:eof\n"

        _ ->
            "K:other\n"


init () =
    ( 0
    , Task.perform Ready
        (Task.andThen (\_ -> Io.writeString "READY\n")
            (Task.andThen (\_ -> Io.mouseMode AllMotion) (Io.rawMode True)))
    )


update msg model =
    case msg of
        Ready _ ->
            ( model
            , Cmd.batch
                [ Task.perform GotMouse Io.readMouse
                , Task.perform GotKey Io.readKey
                ]
            )

        GotMouse m ->
            ( model + 1
            , Cmd.batch
                [ Task.perform Wrote (Io.writeString (mouseMark m))
                , Task.perform GotMouse Io.readMouse
                ]
            )

        GotKey key ->
            case key of
                KeyChar "q" ->
                    ( model + 1, Task.perform Wrote Io.quit )

                _ ->
                    ( model + 1
                    , Cmd.batch
                        [ Task.perform Wrote (Io.writeString (keyMark key))
                        , Task.perform GotKey Io.readKey
                        ]
                    )

        Wrote _ ->
            ( model, Cmd.none )
