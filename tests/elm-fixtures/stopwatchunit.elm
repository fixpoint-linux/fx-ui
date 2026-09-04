module StopwatchUnit exposing (main)

-- S9 gate (main : String): core-libs/Stopwatch.elm (bubbles stopwatch — the
-- count-up).  Flags pin the Go update semantics: New leaves the stopwatch
-- STOPPED at "0s" (unlike the timer), StartStop flips the run flag with NO
-- id-0 wildcard (foreign id ignored on StartStop/Reset/Tick alike), each
-- accepted tick ADDS one interval and BUMPS the tag, the tag guard drops a
-- stale tick (tag 1 vs current 4), the tag-0 hole is Go parity (a tag-0
-- tick always passes the `tag > 0` guard — Go's own first-restart hole,
-- ported verbatim), Reset zeroes elapsed WITHOUT touching tag or running,
-- and the restart heal: after stop->start the stale pre-stop tick is
-- rejected by the accepted tick's tag++ (one stale tick healed per
-- restart).  Views are the byte-exact Go time.Duration.String() forms:
-- "250ms", "1s", "1.25s", "1m5s", "1m30s", "1h0m0s", "1h2m0.5s".
--
-- Cmd-side behavior (start's StartStop-before-Tick ordering, toggle/reset
-- delivery) is the stopwatchdemo pty row's job.

import Stopwatch


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


startIt : Stopwatch.Model -> Stopwatch.Model
startIt m =
  Stopwatch.update (Stopwatch.StartStop { id = 0, running = True }) m


tickI : Int -> Stopwatch.Model -> Stopwatch.Model
tickI tag m =
  Stopwatch.update (Stopwatch.Tick { id = 0, tag = tag }) m


viewMs : Int -> String
viewMs ms =
  Stopwatch.view
    { elapsedMs = ms, intervalMs = 1000, id = 0, tag = 0, running = True }


main =
  let
    -- Go New(): stopped, 0 elapsed, tag 0.
    s0 =
      Stopwatch.new 1000

    sRun =
      startIt s0

    -- three accepted ticks: 1s/2s/3s, tag climbing 0->3.
    s1 =
      tickI 0 sRun

    s2 =
      tickI 1 s1

    s3 =
      tickI 2 s2

    -- a stale tag-1 tick is dropped (tag > 0 and /= current 3).
    sStale =
      tickI 1 s3

    -- Go's tag-0 hole: a tag-0 tick ALWAYS passes (0 > 0 is false).
    sHole =
      tickI 0 s3

    -- foreign ids are dropped everywhere (no 0 wildcard).
    sFor =
      Stopwatch.update (Stopwatch.Tick { id = 3, tag = 3 }) s3

    sId5 =
      { s3 | id = 5 }

    sForRun =
      Stopwatch.update (Stopwatch.StartStop { id = 3, running = False }) sId5

    sForRst =
      Stopwatch.update (Stopwatch.Reset { id = 3 }) sId5

    -- Reset zeroes elapsed, keeps tag + running.
    sRst =
      Stopwatch.update (Stopwatch.Reset { id = 0 }) s3

    -- stop, then the stale-tick heal across a restart: the pre-stop tick
    -- (tag 4) lands while stopped (dropped by the run gate), Start re-arms
    -- with the tag captured at Start time (4) — so pre-stop and re-armed
    -- ticks share tag 4, the FIRST is accepted (tag++ to 5), the DUPLICATE
    -- is rejected by the tag guard: one stale tick healed per restart.
    sStopped =
      Stopwatch.update (Stopwatch.StartStop { id = 0, running = False }) sHole

    sStoppedTick =
      tickI 4 sStopped

    sRestarted =
      startIt sStopped

    sHealA =
      tickI 4 sRestarted

    sHealB =
      tickI 4 sHealA

    flags =
      [ "new=v=" ++ Stopwatch.view s0 ++ " run=" ++ f (Stopwatch.running s0) ++ " el=" ++ n (Stopwatch.elapsed s0) ++ " id=" ++ n (Stopwatch.id s0)
      , "run=" ++ f (Stopwatch.running sRun)
      , "walk=" ++ Stopwatch.view s1 ++ "," ++ Stopwatch.view s2 ++ "," ++ Stopwatch.view s3
      , "tags=" ++ n s1.tag ++ "," ++ n s2.tag ++ "," ++ n s3.tag
      , "stale=" ++ Stopwatch.view sStale ++ " tag=" ++ n sStale.tag
      , "hole=" ++ Stopwatch.view sHole ++ " tag=" ++ n sHole.tag
      , "for=tick=" ++ Stopwatch.view sFor ++ " run=" ++ f (Stopwatch.running sForRun) ++ " el=" ++ n (Stopwatch.elapsed sForRst)
      , "rst=v=" ++ Stopwatch.view sRst ++ " tag=" ++ n sRst.tag ++ " run=" ++ f (Stopwatch.running sRst)
      , "stopped=run=" ++ f (Stopwatch.running sStopped) ++ " tick=" ++ Stopwatch.view sStoppedTick
      , "heal=restarted=" ++ f (Stopwatch.running sRestarted) ++ " first=" ++ Stopwatch.view sHealA ++ " dup=" ++ Stopwatch.view sHealB ++ " tag=" ++ n sHealB.tag
      , "fmt=" ++ viewMs 250 ++ "," ++ viewMs 1000 ++ "," ++ viewMs 1250
      , "fmt2=" ++ viewMs 60000 ++ "," ++ viewMs 65000 ++ "," ++ viewMs 90000
      , "fmt3=" ++ viewMs 3600000 ++ "," ++ viewMs 3720500
      ]
  in
  String.join "\n" flags
