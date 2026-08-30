module LgDemo exposing (main)

-- M-FOUNDATION S7 (integration demo): the whole foundation composing under a
-- real pty, driven by scripts/lgdemo.script —
--   * Tea core loop: keys drive update, every event repaints, Enter/Ctrl-C/
--     Esc/q quit via the synchronous quit scan + S3 quit latch (drains the
--     armed readKey AND waitResize evals);
--   * Lipgloss: a rounded-border box (cyan edges) with padding + width =
--     the terminal's probed cols, around a bold-cyan title rendered NESTED
--     inside the content (Str.width inside lipgloss must skip its ANSI to
--     pad/align the box correctly);
--   * Str toolkit: Str.lines splits the rendered box into Tea frame rows;
--   * WinSize/Resize: Tea re-arms Io.waitResize on every EvResize, so
--     ptytest's `resize 40 12` re-renders the box at the new dims live;
--   * the model is visible in the frame: n=<key count> last=<key>
--     size=<cols>x<rows> — every key CHANGES the box, not just a repaint.

import Lipgloss exposing
  ( bold
  , border
  , borderBottomForeground
  , borderLeftForeground
  , borderRightForeground
  , borderTopForeground
  , colorCyan
  , foreground
  , newStyle
  , padding
  , render
  , roundedBorder
  , setWidth
  )
import Str exposing (lines)
import Tea exposing (program, quit)


type alias Model =
  { count : Int
  , last : String
  , cols : Int
  , rows : Int
  }


main =
  program
    { init = \_ -> ( { count = 0, last = "-", cols = 0, rows = 0 }, Cmd.none )
    , update = demoUpdate
    , view = view
    , resize = applyResize
    }


-- Both annotations are load-bearing (S2 lesson): a multi-field record update
-- on an UNANNOTATED base fails at the SECOND written field ("record does not
-- have field <f>") — annotating the updating function pins the base record
-- before the fields restrict its row.
bump : Runtime.Key -> Model -> Model
bump key model =
  { model | count = model.count + 1, last = showKey key }


demoUpdate key model =
  let
    m1 =
      bump key model
  in
  case key of
    KeyEnter ->
      ( m1, quit )

    KeyCtrl "c" ->
      ( m1, quit )

    KeyEsc ->
      ( m1, quit )

    KeyChar "q" ->
      ( m1, quit )

    _ ->
      ( m1, Cmd.none )


-- The annotation is load-bearing for the same reason (see bump).
applyResize : Int -> Int -> Model -> Model
applyResize cols rows model =
  { model | cols = cols, rows = rows }


showKey key =
  case key of
    KeyChar s ->
      s

    KeyEnter ->
      "enter"

    KeyEsc ->
      "esc"

    KeyTab ->
      "tab"

    KeyBackspace ->
      "bs"

    KeyUp ->
      "up"

    KeyDown ->
      "down"

    KeyLeft ->
      "left"

    KeyRight ->
      "right"

    KeyCtrl c ->
      String.append "ctrl-" c

    KeyOther n ->
      String.fromInt n

    _ ->
      "key"


boxStyle cols =
  borderTopForeground colorCyan
    (borderRightForeground colorCyan
      (borderBottomForeground colorCyan
        (borderLeftForeground colorCyan
          (border roundedBorder
            (padding 1 (setWidth cols newStyle))
          )
        )
      )
    )


title =
  render (bold True (foreground colorCyan newStyle)) "lgdemo"


view model =
  let
    info =
      String.append "n="
        (String.append (String.fromInt model.count)
          (String.append " last="
            (String.append model.last
              (String.append " size="
                (String.append (String.fromInt model.cols)
                  (String.append "x" (String.fromInt model.rows))
                )
              )
            )
          )
        )

    box =
      render (boxStyle model.cols) (String.append title (String.append "\n" info))
  in
  lines box
