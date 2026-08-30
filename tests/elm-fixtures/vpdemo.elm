module VpDemo exposing (main)

-- S4 (widget + demo): the Viewport widget driving a Tea v2 program, proven
-- end-to-end under a real pseudo-terminal by scripts/vpdemo.script.
--
-- The app model is the viewport's SCROLL STATE (y offset + size), NOT the full
-- Viewport.Model: `mkViewport` rebuilds the viewport transiently from the
-- module-level content each event, so the keys/mouse/resize all exercise the
-- REAL Viewport.update/updateMouse/view but the tea model stays a handful of
-- Ints.  That is load-bearing for the pty gate: elmvm prints the FINAL model
-- to the (nonblocking) pty on exit, and a full Viewport.Model (style + keymap
-- + lines) exceeds the pty buffer -> a WouldBlock write error.  (The viewport
-- itself is byte-pinned in vpunit; this demo proves the live integration.)
--
-- `view` renders a live "off=<y> size=<cols>x<rows>" header above the viewport
-- so every scroll state has a UNIQUE needle.  j/k scroll a line, pgdn/pgup
-- page, wheel up/down scrolls by the 3-line delta (Click mode still decodes
-- SGR wheel), `resize` folds the probe dims into the viewport size.  q/esc/
-- ctrl+c quit via the TaskQuit scan.

import Str exposing (lines)
import Tea exposing (program, quit)
import Viewport exposing (init, setContent, setYOffset, updateMouse, yOffset)


type alias Model =
  { y : Int
  , w : Int
  , h : Int
  , cols : Int
  , rows : Int
  }


type Msg
  = GotKey Runtime.Key
  | GotMouse Runtime.MouseMsg
  | Noop


-- 40 numbered rows — more than any viewport height the script uses, so every
-- scroll direction has a distinct, unique line to needle on.
content =
  "row-00\nrow-01\nrow-02\nrow-03\nrow-04\nrow-05\nrow-06\nrow-07\nrow-08\nrow-09\nrow-10\nrow-11\nrow-12\nrow-13\nrow-14\nrow-15\nrow-16\nrow-17\nrow-18\nrow-19\nrow-20\nrow-21\nrow-22\nrow-23\nrow-24\nrow-25\nrow-26\nrow-27\nrow-28\nrow-29\nrow-30\nrow-31\nrow-32\nrow-33\nrow-34\nrow-35\nrow-36\nrow-37\nrow-38\nrow-39"


-- Rebuild the viewport at the model's current offset/size (the transient-
-- widget pattern: heavy fields stay module-level constants, out of the tea
-- model).
mkViewport : Model -> Viewport.Model
mkViewport m =
  setYOffset m.y (setContent content (init m.w m.h))


main =
  program
    { init = \_ -> ( { y = 0, w = 40, h = 8, cols = 0, rows = 0 }, Cmd.none )
    , update = update
    , view = view
    , resize = resize
    , onKey = GotKey
    , onMouse = GotMouse
    , mouse = Click
    }


resize : Int -> Int -> Model -> Model
resize cols rows m =
  { m | cols = cols, rows = rows, w = cols, h = rows }


update msg m =
  case msg of
    GotKey key ->
      case key of
        KeyChar "q" ->
          ( m, quit )

        KeyCtrl "c" ->
          ( m, quit )

        KeyEsc ->
          ( m, quit )

        _ ->
          let
            vp =
              Viewport.update key (mkViewport m)
          in
          ( { m | y = yOffset vp }, Cmd.none )

    GotMouse mm ->
      let
        vp =
          Viewport.updateMouse mm (mkViewport m)
      in
      ( { m | y = yOffset vp }, Cmd.none )

    Noop ->
      ( m, Cmd.none )


view m =
  let
    header =
      String.append "off="
        (String.append (String.fromInt m.y)
          (String.append " size="
            (String.append (String.fromInt m.cols)
              (String.append "x" (String.fromInt m.rows))
            )
          )
        )
  in
  lines (String.append header (String.append "\n" (Viewport.view (mkViewport m))))
