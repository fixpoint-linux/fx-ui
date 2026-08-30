module ExecEnv exposing (main)

-- M8 gate: the env/cwd prims chained through Task.andThen.  setenv FX_M8=hello
-- -> getenv -> "hello"; getpid delivers a NUMBER (String.fromInt proves it
-- stringifies, and the gate checks it is positive — the raw pid is
-- process-specific so it cannot appear in a deterministic expected file);
-- cd /tmp -> getcwd -> "/tmp" (the gate spawns a fresh elmvm per fixture, so
-- mutating the process CWD is safe).

type Msg
    = Got ( String, Int, String )


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( ""
    , Task.perform Got
        (Task.andThen
            (\_ ->
                Task.andThen
                    (\env ->
                        Task.andThen
                            (\pid ->
                                Task.andThen
                                    (\_ ->
                                        Task.map (\cwd -> ( env, pid, cwd )) (Io.getcwd)
                                    )
                                    (Io.cd "/tmp")
                            )
                            (Io.getpid)
                    )
                    (Io.getenv "FX_M8")
            )
            (Io.setenv "FX_M8" "hello")
        )
    )


update msg model =
    case msg of
        Got ( env, pid, cwd ) ->
            let
                pidStr = String.fromInt pid
                pidOk = pid > 0 && pidStr /= ""
            in
            ( String.join ""
                [ env
                , "|"
                , if pidOk then "1" else "0"
                , "|"
                , cwd
                ]
            , Cmd.none
            )
