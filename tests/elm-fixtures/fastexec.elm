module FastExec exposing (main)

-- M9 gate: a FAST async exec (no sleep) must still complete under the host
-- event loop.  This is the regression the blocker masked: the child is reaped
-- in the SAME iteration its pipes drain, so the andThen continuation that
-- wraps the exec result becomes a pure TaskSucceed msg that stepAll's cursor
-- already ran past — the old npoll==0 break silently dropped it (model "").
-- The fixpoint drain must deliver it.

type Msg
    = Got ( Int, String, String )


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


echoArgv =
    Plan.cons (Plan.str "echo") (Plan.cons (Plan.str "hi") Plan.nil)


echoCmd =
    Plan.cons echoArgv (Plan.cons Plan.nil (Plan.cons Plan.nil Plan.nil))


echoPipeline =
    Plan.cons echoCmd Plan.nil


echoPlan =
    Plan.cons (Plan.cons (Plan.sym "seq") (Plan.cons echoPipeline Plan.nil)) Plan.nil


init () =
    ( "", Task.perform Got (Io.exec echoPlan) )


update msg model =
    case msg of
        Got ( code, out, err ) ->
            ( String.join "" [ String.fromInt code, "|", out, "|", err ], Cmd.none )
