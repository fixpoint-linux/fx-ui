module AsyncOrder exposing (main)

-- M9 gate: REAL out-of-order interleaving.  Cmd.batch issues TWO independent
-- effects: a slow Io.exec (sleep 1 — issued FIRST) and a fast Io.readFile
-- (issued SECOND).  The host event loop runs both concurrently, so the fast
-- read OVERTAKES the slow exec and delivers File BEFORE Ran — proving true
-- nonblocking async (the sequential M7 worker would give "ran,file").

type Msg
    = Ran ( Int, String, String )
    | File String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


sleepArgv =
    Plan.cons (Plan.str "sleep") (Plan.cons (Plan.str "1") Plan.nil)


sleepCmd =
    Plan.cons sleepArgv (Plan.cons Plan.nil (Plan.cons Plan.nil Plan.nil))


sleepPipeline =
    Plan.cons sleepCmd Plan.nil


slowPlan =
    Plan.cons (Plan.cons (Plan.sym "seq") (Plan.cons sleepPipeline Plan.nil)) Plan.nil


init () =
    ( ""
    , Cmd.batch
        [ Task.perform Ran (Io.exec slowPlan)
        , Task.perform File (Io.readFile "tests/elm-fixtures/input/hello.txt")
        ]
    )


update msg model =
    case msg of
        Ran ( code, out, err ) ->
            ( String.append model ",ran", Cmd.none )

        File contents ->
            ( String.append model "file", Cmd.none )
