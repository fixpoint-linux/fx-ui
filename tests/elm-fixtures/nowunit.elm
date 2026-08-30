module NowUnit exposing (main)

-- S3 gate: host TaskNow (monotonic) + TaskSleep (suspending) leaves under a
-- real Platform.program.  One chain proves two things:
--   * now -> sleep 30 -> now: elapsed monotonic time is >= 25ms.  TaskNow
--     reads CLOCK_MONOTONIC (the VM's get-time prim is CLOCK_REALTIME, which
--     jumps with wall-clock changes and cannot time an animation).
--   * now -> sleep 20 -> sleep 20 -> now: two SEQUENTIAL sleeps chain in
--     order — a sleep's continuation runs only after the prior completes — so
--     the total is >= 40ms (the sleeps cannot overlap or reorder).

type Msg
    = Got String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( ""
    , Task.perform Got nowChain
    )


nowChain =
    Task.andThen
        (\t0 ->
            Task.andThen
                (\_ ->
                    Task.andThen
                        (\t1 ->
                            Task.andThen
                                (\s0 ->
                                    Task.andThen
                                        (\_ ->
                                            Task.andThen
                                                (\_ ->
                                                    Task.andThen
                                                        (\s1 ->
                                                            Task.succeed
                                                                (String.append
                                                                    (if t1 - t0 >= 25 then
                                                                        "now-ok "
                                                                     else
                                                                        "now-bad "
                                                                    )
                                                                    (if s1 - s0 >= 40 then
                                                                        "order-ok"
                                                                     else
                                                                        "order-bad"
                                                                    )
                                                                )
                                                        )
                                                        Io.now
                                                )
                                                (Io.sleep 20)
                                        )
                                        (Io.sleep 20)
                                )
                                Io.now
                        )
                        Io.now
                )
                (Io.sleep 30)
        )
        Io.now


update msg model =
    case msg of
        Got result ->
            ( result, Cmd.none )
