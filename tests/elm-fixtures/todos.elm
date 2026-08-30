module Todos exposing (main)

-- PTY gate fixture for the examples/todos app: re-exports TodoApp.main so the
-- gate can run the real app under a pseudo-terminal.  The gate drives it from
-- a temp CWD (see the ptycwd dispatch), so todos.txt persistence writes to a
-- throwaway directory rather than the repo root.

import TodoApp


main =
  TodoApp.main
