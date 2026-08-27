module ExecPipe exposing (main)

-- M8 gate: the declarative plan-runner (Io.exec).  Builds the plan for
-- 'echo -n hi | tr i o' with the Plan.* tagged-list builders (the Shen
-- TAGGED-LIST demarshal format), runs it synchronously, and folds the
-- delivered (code, out, err) tuple into a String model.

type Msg
    = Got ( Int, String, String )


main =
    Platform.worker { init = init, update = update, subscriptions = \_ -> Sub.none }


echoArgv =
    Plan.cons (Plan.str "echo") (Plan.cons (Plan.str "-n") (Plan.cons (Plan.str "hi") Plan.nil))


trArgv =
    Plan.cons (Plan.str "tr") (Plan.cons (Plan.str "i") (Plan.cons (Plan.str "o") Plan.nil))


-- Cmd = [Argv Redirs Sub]: no redirects (Plan.nil), plain command (Plan.nil).
echoCmd =
    Plan.cons echoArgv (Plan.cons Plan.nil (Plan.cons Plan.nil Plan.nil))


trCmd =
    Plan.cons trArgv (Plan.cons Plan.nil (Plan.cons Plan.nil Plan.nil))


-- Pipeline = [echo, tr]; Chain = [seq pipeline]; Program = [chain].
pipeline =
    Plan.cons echoCmd (Plan.cons trCmd Plan.nil)


chain =
    Plan.cons (Plan.sym "seq") (Plan.cons pipeline Plan.nil)


plan =
    Plan.cons chain Plan.nil


init () =
    ( ""
    , Task.perform Got (Io.exec plan)
    )


update msg model =
    case msg of
        Got ( code, out, err ) ->
            ( String.join "" [ String.fromInt code, "|", out, "|", err ], Cmd.none )
