module SpinnerDemo exposing (main)

-- S3 (widget + demo): the Spinner widget driving a Tea v2 program, proven
-- end-to-end under a real pseudo-terminal by scripts/spinnerdemo.script —
-- the animation loop is the TICK RE-ARM: init returns `Spinner.tick` (a
-- TaskSleep on the widget's fpsMs), Tea wraps it Cmd.map FUser, and every
-- delivered Tick's update returns the NEXT tick command (Tea's FUser branch
-- re-arms nothing itself — the app's command IS the re-arm).  'q'/esc/
-- ctrl+c quit (the synchronous TaskQuit scan drops the pending tick's
-- successor and runs the exit chain: show cursor, raw mode off, exit 0).
--
-- The demo model IS Spinner.Model (the widget state is the whole app state,
-- like teademo's model being TextInput's).

import Spinner exposing (Model)
import Tea exposing (program, quit)


type Msg
  = SpinnerTick Spinner.Msg
  | GotKey Runtime.Key
  | Noop


main =
  program
    { init = \_ -> ( Spinner.init, Spinner.tick SpinnerTick Spinner.init )
    , update = update

    -- Spinner.view : Model -> List String is the Tea view shape directly
    , view = Spinner.view
    , resize = \cols rows m -> m
    , onKey = GotKey
    , onMouse = \_ -> Noop
    , mouse = MouseModeOff
    }


update msg model =
  case msg of
    -- the tick: advance one frame, then RE-ARM by returning the next sleep
    SpinnerTick smsg ->
      let
        m1 =
          Spinner.update smsg model
      in
      ( m1, Spinner.tick SpinnerTick m1 )

    GotKey key ->
      case key of
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
