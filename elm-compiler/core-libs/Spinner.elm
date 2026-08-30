module Spinner
  exposing
    ( Model
    , Msg (..)
    , Spinner
    , dot
    , ellipsis
    , init
    , line
    , miniDot
    , points
    , pulse
    , tick
    , update
    , view
    )

-- S3 bubbles spinner widget (charmbracelet/bubbles spinner, subset-ported
-- over the Tea v2 loop).  A `Spinner` is a frame set + tick rate; the `Model`
-- holds the chosen spinner, a Lipgloss style, and the current frame index.
-- This is the FIRST Cmd-producing widget: `update` only advances/wraps the
-- frame — the animation loop lives in `tick`, which sleeps `fpsMs` and
-- performs `Tick` through the CALLER's `Msg` (the `inject` argument), so the
-- APP builds the re-arm in its own update (its Tick branch calls `tick`
-- again; Tea's FUser branch re-arms nothing itself).
--
-- Subset deviations from Go, all forced by the checker surface:
--   * 6 of the 12 presets (Line/Dot/MiniDot/Pulse/Points/Ellipsis) — the
--     emoji/moon/meter frames are omitted; frames are BYTE-FAITHFUL (Dot's
--     trailing spaces and the MiniDot braille are intentional — Go parity);
--   * `fpsMs : Int` floors Go's time.Second/N (1000/12 -> 83, 1000/7 -> 142,
--     1000/3 -> 333): the host sleep takes milliseconds and there are no
--     float/duration prims;
--   * no ID/tag TickMsg routing (single spinner per app in the subset — the
--     app routes by its own Msg ctor instead);
--   * presets are lowercase VALUES (real Elm: uppercase identifiers are
--     constructors, so Go's Line/Dot/... become line/dot/...).


{-| A frame set + tick rate.  `fpsMs` is the sleep between frames.
-}
type alias Spinner =
  { frames : List String
  , fpsMs : Int
  }


{-| The widget state.  `style` colors the rendered frame (Lipgloss).
-}
type alias Model =
  { spinner : Spinner
  , style : Lipgloss.Style
  , frame : Int
  }


{-| The widget's own message: the timer tick.
-}
type Msg
  = Tick


{-| Go's New(): the Line spinner, zero style, frame 0.
-}
init : Model
init =
  { spinner = line
  , style = Lipgloss.newStyle
  , frame = 0
  }


-- ---- presets (frames byte-faithful to bubbles/spinner.go) ----


line : Spinner
line =
  { frames = [ "|", "/", "-", "\\" ]
  , fpsMs = 100
  }


dot : Spinner
dot =
  { frames =
      [ "⣾ "
      , "⣽ "
      , "⣻ "
      , "⢿ "
      , "⡿ "
      , "⣟ "
      , "⣯ "
      , "⣷ "
      ]
  , fpsMs = 100
  }


miniDot : Spinner
miniDot =
  { frames =
      [ "⠋"
      , "⠙"
      , "⠹"
      , "⠸"
      , "⠼"
      , "⠴"
      , "⠦"
      , "⠧"
      , "⠇"
      , "⠏"
      ]
  , fpsMs = 83
  }


pulse : Spinner
pulse =
  { frames = [ "█", "▓", "▒", "░" ]
  , fpsMs = 125
  }


points : Spinner
points =
  { frames = [ "∙∙∙", "●∙∙", "∙●∙", "∙∙●" ]
  , fpsMs = 142
  }


ellipsis : Spinner
ellipsis =
  { frames = [ "", ".", "..", "..." ]
  , fpsMs = 333
  }


-- ---- Tea surface ----


{-| Advance one frame, wrapping to 0 past the end (Go Update/TickMsg).
-}
update : Msg -> Model -> Model
update msg model =
  case msg of
    Tick ->
      let
        n =
          List.length model.spinner.frames

        next =
          model.frame + 1

        wrapped =
          if next >= n then
            0

          else
            next
      in
      { model | frame = wrapped }


{-| Render the current frame through the style, as ONE terminal row.
Out-of-range frame -> the literal "(error)" (Go View's guard; unreachable
through `update`, which always wraps).
-}
view : Model -> List String
view model =
  let
    n =
      framesLen model.spinner.frames

    body =
      if model.frame >= n then
        "(error)"

      else
        Lipgloss.render model.style (frameAt model.frame model.spinner.frames)
  in
  [ body ]


{-| The animation command: sleep `fpsMs`, then perform `Tick` through the
caller's `Msg`.  Start the loop from init, and RE-ARM by returning this from
the app's Tick branch — the FUser branch of Tea's outerUpdate re-arms nothing
itself, the app's command is the re-arm.
-}
tick : (Msg -> msg) -> Model -> Runtime.Cmd msg
tick inject model =
  Task.perform (\_ -> inject Tick) (Io.sleep model.spinner.fpsMs)


-- ---- internals ----


framesLen : List String -> Int
framesLen frames =
  case frames of
    [] ->
      0

    _ :: rest ->
      1 + framesLen rest


frameAt : Int -> List String -> String
frameAt i frames =
  case frames of
    [] ->
      ""

    f :: rest ->
      if i <= 0 then
        f

      else
        frameAt (i - 1) rest

