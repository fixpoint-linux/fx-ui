module RawPty exposing (main)

-- STEP 2 (host substrate + PTY infra): prove TaskRawMode + TaskReadKey
-- end-to-end under a real pseudo-terminal.  init chains raw-on -> READY marker
-- -> first readKey; every key is echoed back to the pty as "K:<tag>" and the
-- key is re-armed, except ESC which quits (lone-ESC exercises the host's 50ms
-- flush).  Driven by the HOST event loop (Platform.program), not the sync
-- worker — the sync worker's TaskReadKey would no-op to KeyEof.

type Msg
    = GotKey Runtime.Key
    | Wrote ()


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


keyTag key =
    case key of
        KeyChar s ->
            String.append "char:" s

        KeyEnter ->
            "enter"

        KeyTab ->
            "tab"

        KeyBackspace ->
            "backspace"

        KeyEsc ->
            "esc"

        KeyUp ->
            "up"

        KeyDown ->
            "down"

        KeyLeft ->
            "left"

        KeyRight ->
            "right"

        KeyHome ->
            "home"

        KeyEnd ->
            "end"

        KeyPgUp ->
            "pgup"

        KeyPgDn ->
            "pgdn"

        KeyIns ->
            "ins"

        KeyDel ->
            "del"

        KeyCtrl c ->
            String.append "ctrl:" c

        KeyOther n ->
            String.append "other:" (String.fromInt n)

        KeyEof ->
            "eof"


marker key =
    String.append "K:" (String.append (keyTag key) "\n")


init () =
    ( 0
    , Task.perform GotKey
        (Task.andThen (\_ -> Io.readKey)
            (Task.andThen (\_ -> Io.writeString "READY\n") (Io.rawMode True)))
    )


update msg model =
    case msg of
        GotKey key ->
            case key of
                KeyEsc ->
                    ( model + 1
                    , Task.perform Wrote (Io.writeString (marker key))
                    )

                _ ->
                    ( model + 1
                    , Task.perform GotKey
                        (Task.andThen (\_ -> Io.readKey) (Io.writeString (marker key)))
                    )

        Wrote _ ->
            ( model, Cmd.none )
