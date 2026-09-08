module Todosgui exposing (main)

-- GUI smoke fixture (photon-gui P2 item 14): the SAME TodoApp config the
-- pty-gate todos.elm re-export drives, but through Tea.guiProgram — the
-- SDL window backend instead of the terminal.  NOT part of the pty byte
-- gate: it needs a real window, so it is the manual/headless smoke fixture
-- (build with -Dgui=true, run under a display — Xvfb works headless).
--
--   node elm-compiler/run.js examples/todos/TodoApp.elm \
--       tests/elm-fixtures/todosgui.elm todosgui.csexp
--   DISPLAY=:99 elmvm todosgui.csexp Todosgui.main

import TodoApp
import Tea exposing (guiProgram)


main =
  guiProgram TodoApp.config
