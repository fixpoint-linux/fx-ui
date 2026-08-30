module Tea2Unit exposing (main)

-- S0 (Tea v2) gate: the three new loop behaviors, end-to-end under a real pty
-- (driven by scripts/tea2unit.script):
--   * FUser wrap — init returns a USER command (Io.sleep 50 -> Tick); Tea wraps
--     it Cmd.map FUser, so the sleep's completion is delivered to outerUpdate as
--     FUser Tick and DELEGATED to the app's update (the v2 branch that v1 could
--     not express — a task completion can now reach the app as its own msg);
--   * tick re-arm — every Tick re-arms the sleep via the command it returns
--     (the spinner's re-arm discipline: the FUser branch re-arms NOTHING itself,
--     the app's command self-re-arms);
--   * TaskQuit scan — after 2 ticks the app returns `quit` ([TaskQuit]); Tea's
--     synchronous hasQuit scan (ctor match, no equality) runs the exit chain
--     (showCursor -> rawMode off -> Io.quit) and the program exits 0.
--
-- A PLAIN `run` row cannot prove these: Tea always arms Io.readKey, and under
-- the gate's elmvm stdin (a pipe/EOF) the readKey completes KeyEof and takes
-- the exit path before the first sleep deadline is flushed, so a tick would
-- never run.  A pty (whose master never EOFs) keeps readKey blocked and lets
-- the ticks drive the loop — hence this is a `pty` row, not `run`.

import Tea exposing (program, quit)


type Msg
  = Tick
  | Noop


main =
  program
    { init = \_ -> ( 0, Task.perform (\_ -> Tick) (Io.sleep 50) )
    , update = update
    , view = view
    , resize = \cols rows n -> n
    , onKey = \_ -> Noop
    , onMouse = \_ -> Noop
    , mouse = MouseModeOff
    }


update msg n =
  case msg of
    Noop ->
      ( n, Cmd.none )

    Tick ->
      if n >= 2 then
        ( n, quit )

      else
        ( n + 1, Task.perform (\_ -> Tick) (Io.sleep 50) )


view n =
  [ String.append "tick=" (String.fromInt n) ]
