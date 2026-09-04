module StopwatchDemo exposing (main)

-- S9 (widget + demo): the Stopwatch widget driving a Tea v2 program, proven
-- end-to-end under a real pseudo-terminal by scripts/stopwatchdemo.script.
--
-- The tea model is a small record { s, state }: the widget plus a state
-- prefix ("run "/"stop ") DERIVED from the model each frame (the lowerer
-- rejects cross-module ctor patterns, so the demo never matches
-- Stopwatch.Msg — it routes through `Stopwatch.step`, Go Update wholesale,
-- and reads the state back off the record).  The loop is the TICK RE-ARM:
-- step returns the re-arm for accepted ticks and nothing for rejected ones;
-- the app just pairs it with the stepped model.  s toggles run/stop (through
-- `Stopwatch.toggle`, whose Start carries the StartStop-before-Tick ordering
-- guarantee), r resets the elapsed time to zero WITHOUT stopping the run,
-- q/esc/ctrl+c quit via the TaskQuit scan (a pending tick sleep is dropped
-- by the quit latch).
--
-- The script's restart leg IS the ordering proof: after stop -> start, the
-- "run 1s" needle can only appear once the StartStop delivery has actually
-- landed BEFORE the sleeping Tick (had the Tick overtaken it, the tick would
-- be rejected while still stopped, no re-arm would follow, and the counter
-- would freeze forever below 1s).

import Tea exposing (program, quit)
import Stopwatch
import Tuple


type alias Model =
  { s : Stopwatch.Model
  , state : String
  }


type Msg
  = WatchMsg Stopwatch.Msg
  | GotKey Runtime.Key
  | Noop


main =
  program
    { init = init
    , update = update
    , view = view
    , resize = \cols rows m -> m
    , onKey = GotKey
    , onMouse = \_ -> Noop
    , mouse = MouseModeOff
    }


init : () -> ( Model, Runtime.Cmd Msg )
init _ =
  -- Go New leaves the watch STOPPED (init arms nothing until Start).
  ( { s = Stopwatch.new 250, state = "stop " }, Cmd.none )


update : Msg -> Model -> ( Model, Runtime.Cmd Msg )
update msg model =
  case msg of
    WatchMsg wmsg ->
      let
        pair =
          Stopwatch.step WatchMsg wmsg model.s

        s1 =
          Tuple.first pair

        state =
          if Stopwatch.running s1 then
            "run "

          else
            "stop "
      in
      ( { s = s1, state = state }, Tuple.second pair )

    GotKey key ->
      case key of
        KeyChar "s" ->
          ( model, Stopwatch.toggle WatchMsg model.s )

        KeyChar "r" ->
          ( model, Stopwatch.reset WatchMsg model.s )

        KeyChar "q" ->
          ( model, quit )

        KeyCtrl "c" ->
          ( model, quit )

        KeyEsc ->
          ( model, quit )

        _ ->
          ( model, Cmd.none )

    Noop ->
      ( model, Cmd.none )


view : Model -> List String
view model =
  [ String.append model.state (Stopwatch.view model.s) ]
