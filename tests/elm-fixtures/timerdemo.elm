module TimerDemo exposing (main)

-- S9 (widget + demo): the Timer widget driving a Tea v2 program, proven
-- end-to-end under a real pseudo-terminal by scripts/timerdemo.script.
--
-- The tea model is a small record { t, state }: the widget plus a state
-- prefix ("run "/"stop "/"over ") DERIVED from the model each frame (the
-- lowerer rejects cross-module ctor patterns, so the demo never matches
-- Timer.Msg — it routes through `Timer.step`, Go Update wholesale, and
-- reads the state back off the record).  The loop is the TICK RE-ARM: step
-- returns the exact Go Cmd (accepted tick -> tick, crossing tick -> the
-- Timedout notice, StartStop -> tick, rejected tick -> nothing); the app
-- just pairs it with the stepped model.  s toggles run/stop (the StartStop
-- re-arm in step is what keeps a restarted timer alive), q/esc/ctrl+c quit
-- via the TaskQuit scan.

import Tea exposing (program, quit)
import Timer
import Tuple


type alias Model =
  { t : Timer.Model
  , state : String
  }


type Msg
  = TimerMsg Timer.Msg
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
  let
    t0 =
      Timer.new 5000 1000

    pair =
      Timer.tick TimerMsg t0
  in
  ( { t = t0, state = "run " }, pair )


update : Msg -> Model -> ( Model, Runtime.Cmd Msg )
update msg model =
  case msg of
    TimerMsg tmsg ->
      let
        pair =
          Timer.step TimerMsg tmsg model.t

        t1 =
          Tuple.first pair

        state =
          if Timer.timedout t1 then
            "over "

          else if Timer.running t1 then
            "run "

          else
            "stop "
      in
      ( { t = t1, state = state }, Tuple.second pair )

    GotKey key ->
      case key of
        KeyChar "s" ->
          ( model, Timer.toggle TimerMsg model.t )

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
  [ String.append model.state (Timer.view model.t) ]
