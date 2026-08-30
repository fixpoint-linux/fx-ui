module TextareaDemo exposing (main)

-- S5 (widget + demo): the Textarea widget driving a Tea v2 program, proven
-- end-to-end under a real pseudo-terminal by scripts/textareademo.script.
--
-- The tea model is a SMALL record {value, row, col} (a full Textarea.Model —
-- viewport + prompt + the embedded viewport's keymap/style — exceeds the pty
-- buffer, so elmvm's final-model print would WouldBlock; same workaround as
-- vpdemo).  `mkTextarea` rebuilds the widget transiently from the small model
-- each event (fixed 40x8, focused), so every key still exercises the REAL
-- Textarea.update/view but the tea model stays three cheap fields.
--
-- `view` renders a live "v=<value \n -> /> r=<row> c=<col>" header above the
-- textarea so every cursor/content state has a UNIQUE needle.  q/esc/ctrl+c
-- quit via the TaskQuit scan.  resize is the identity (the textarea size is
-- fixed at 40x8, independent of the probed terminal dims, for byte-stable
-- frames).
--
-- PER THE STRATEGIST LESSON: `Textarea` is imported BARE (qualified-only) —
-- the demo defines its own local `update`/`view` for the Tea Config, so the
-- widget's same-named functions must NOT be imported bare.

import Str exposing (lines, replace)
import Tea exposing (program, quit)
import Textarea


type alias Model =
  { value : String
  , row : Int
  , col : Int
  }


type Msg
  = GotKey Runtime.Key
  | Noop


main =
  program
    { init = \_ -> ( { value = "", row = 0, col = 0 }, Cmd.none )
    , update = update
    , view = view
    , resize = \cols rows m -> m
    , onKey = GotKey
    , onMouse = \_ -> Noop
    , mouse = MouseModeOff
    }


mkTextarea : Model -> Textarea.Model
mkTextarea m =
  Textarea.setCursor m.row m.col
    (Textarea.setValue m.value (Textarea.focus (Textarea.init 40 8)))


update msg m =
  case msg of
    GotKey key ->
      case key of
        KeyChar "q" ->
          ( m, quit )

        KeyEsc ->
          ( m, quit )

        KeyCtrl "c" ->
          ( m, quit )

        _ ->
          let
            t1 =
              Textarea.update key (mkTextarea m)
          in
          ( { value = Textarea.value t1, row = Textarea.row t1, col = Textarea.col t1 }, Cmd.none )

    Noop ->
      ( m, Cmd.none )


view m =
  let
    header =
      String.append "v="
        (String.append (replace "\n" "/" m.value)
          (String.append " r="
            (String.append (String.fromInt m.row)
              (String.append " c=" (String.fromInt m.col))
            )
          )
        )
  in
  lines (String.append header (String.append "\n" (Textarea.view (mkTextarea m))))
