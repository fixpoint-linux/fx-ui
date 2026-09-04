module TimerUnit exposing (main)

-- S9 gate (main : String): core-libs/Timer.elm (bubbles timer — the
-- countdown).  Flags pin the Go update semantics: the 5s/1s countdown
-- crossing zero on the 5th accepted tick (then timedout, and the 6th tick
-- REJECTED because Running() is false), the tag guard (a tick with tag > 0
-- not matching the model tag is dropped — the timer never bumps its own tag,
-- Go's vestigial tag), the ID routing (a foreign id is ignored, 0 is the
-- wildcard that reaches a re-id'd model), the StartStop flip (foreign id
-- ignored, 0 wildcards) and its interplay with the tick gate, and the
-- timed-out state's behavior (running False forever even if StartStop flips
-- the raw field).  Views are the byte-exact Go time.Duration.String() forms
-- over integer ms: whole seconds, "1m30s"/"1h0m0s" zero-component rules,
-- ".5s"/".05s"/".005s" fractions, "750ms"/"50ms", "0s", and the negative
-- "-500ms" (reachable: interval > timeout drives Timeout below zero on the
-- crossing tick).
--
-- Every message is delivered through `update` directly (the Cmd-returning
-- helpers' delivery order is the timerdemo pty row's job); the re-id'd
-- models use record update, which is also how multi-timer apps set ids.

import Timer


f : Bool -> String
f b =
  case b of
    True ->
      "1"

    False ->
      "0"


n : Int -> String
n =
  String.fromInt


-- fold one accepted tick into m (the app's Tick branch shape)
tickFold : Timer.Model -> Timer.Model
tickFold m =
  Timer.update (Timer.Tick { id = 0, tag = 0, timeout = False }) m


viewMs : Int -> String
viewMs ms =
  Timer.view { timeoutMs = ms, intervalMs = 1000, id = 0, tag = 0, running = True }


main =
  let
    -- Go New(5s, WithInterval(1s)): running immediately, never timed out.
    t0 =
      Timer.new 5000 1000

    -- five accepted ticks walk 5s -> 0s (the 5th is the crossing tick).
    t1 =
      tickFold t0

    t2 =
      tickFold t1

    t3 =
      tickFold t2

    t4 =
      tickFold t3

    t5 =
      tickFold t4

    -- a 6th tick on the timed-out timer is rejected (Running() false).
    t6 =
      tickFold t5

    -- the tag guard: tag 7 vs model tag 0 -> dropped.
    tTag =
      Timer.update (Timer.Tick { id = 0, tag = 7, timeout = False }) t0

    -- foreign id -> dropped; id 0 wildcards into a re-id'd model.
    tFor =
      Timer.update (Timer.Tick { id = 3, tag = 0, timeout = False }) t0

    tId5 =
      { t0 | id = 5 }

    tWild =
      Timer.update (Timer.Tick { id = 0, tag = 0, timeout = False }) tId5

    -- StartStop: the flip + the same id gate.
    tStop =
      Timer.update (Timer.StartStop { id = 0, running = False }) t0

    tStopTick =
      tickFold tStop

    tRestart =
      Timer.update (Timer.StartStop { id = 0, running = True }) tStop

    tSSFor =
      Timer.update (Timer.StartStop { id = 3, running = True }) t0

    tSSWild =
      Timer.update (Timer.StartStop { id = 0, running = False }) tId5

    -- flipping the raw running field cannot resurrect a timed-out timer.
    tToStart =
      Timer.update (Timer.StartStop { id = 0, running = True }) t5

    -- Timedout is a no-op on the model (the notice rides the Cmd side).
    tNotice =
      Timer.update (Timer.Timedout { id = 0 }) t0

    -- negative: interval > timeout drives Timeout below zero.
    tNeg =
      tickFold (Timer.new 500 1000)

    flags =
      [ "new=5s run=" ++ f (Timer.running t0) ++ " to=" ++ f (Timer.timedout t0) ++ " id=" ++ n (Timer.id t0)
      , "walk=" ++ Timer.view t1 ++ "," ++ Timer.view t2 ++ "," ++ Timer.view t3 ++ "," ++ Timer.view t4 ++ "," ++ Timer.view t5
      , "cross=run=" ++ f (Timer.running t5) ++ " to=" ++ f (Timer.timedout t5) ++ " v=" ++ Timer.view t5
      , "t6=" ++ Timer.view t6 ++ " to=" ++ f (Timer.timedout t6)
      , "tag=" ++ Timer.view tTag ++ " for=" ++ Timer.view tFor ++ " wild=" ++ Timer.view tWild
      , "stop=run=" ++ f (Timer.running tStop) ++ " tick=" ++ Timer.view tStopTick
      , "restart=run=" ++ f (Timer.running tRestart) ++ " v=" ++ Timer.view tRestart
      , "ssFor=" ++ f (Timer.running tSSFor) ++ " ssWild(run field)=" ++ f tSSWild.running
      , "toStart=run=" ++ f (Timer.running tToStart) ++ " to=" ++ f (Timer.timedout tToStart)
      , "notice=" ++ Timer.view tNotice ++ " run=" ++ f (Timer.running tNotice)
      , "neg=" ++ Timer.view tNeg ++ " to=" ++ f (Timer.timedout tNeg)
      , "fmt=" ++ viewMs 59000 ++ "," ++ viewMs 60000 ++ "," ++ viewMs 61000
      , "fmt2=" ++ viewMs 3600000 ++ "," ++ viewMs 3661500 ++ "," ++ viewMs 7325000
      , "fmt3=" ++ viewMs 1500 ++ "," ++ viewMs 1050 ++ "," ++ viewMs 1005
      , "fmt4=" ++ viewMs 750 ++ "," ++ viewMs 50 ++ "," ++ viewMs 0
      ]
  in
  String.join "\n" flags
