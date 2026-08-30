module TeaDemo exposing (main)

-- STEP 4 (widget + demo): a Tea program over the TextInput widget, proven
-- end-to-end under a real pseudo-terminal by scripts/teademo.script — typing
-- "hi" repaints the frame, the up-arrow repaints unchanged (an ignored key
-- still paints), backspace shortens the value, and Enter / Ctrl-C / ESC quit
-- (Tea's synchronous quit scan drops the readKey re-arm; the exit path shows
-- the cursor and drops raw mode, so the program exits 0).

import Tea exposing (program, quit)
import TextInput exposing (init, update, view)


main =
  program
    { init = \_ -> ( TextInput.init, Cmd.none )
    , update = demoUpdate
    , view = TextInput.view

    -- S7 added the resize hook to Tea's config: teademo keeps no dims state,
    -- so its hook is the identity (the repaint still happens, unchanged).
    , resize = \cols rows m -> m
    }


demoUpdate key model =
  let
    m1 =
      TextInput.update key model
  in
  case key of
    KeyEnter ->
      ( m1, quit )

    KeyCtrl "c" ->
      ( m1, quit )

    KeyEsc ->
      ( m1, quit )

    _ ->
      ( m1, Cmd.none )
