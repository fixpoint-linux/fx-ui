module TeaUnit exposing (main)

-- STEP 3 (Tea core loop): PURE surface check.  Since the P4 host-terminal
-- switch, the byte-painting half of this fixture (six frames through the
-- retired Elm-side Tea.paint/diffString: first paint, grow, shrink,
-- unchanged-row skip, added rows) moved WITH the machinery into the HOST
-- TerminalRenderer, where the same sequences are pinned byte-exactly by
-- src/renderer/terminal_test.zig and end-to-end by the Tea pty fixtures
-- (teademo/lgdemo/todos/... raw PTY captures).  What stays pure Elm-side —
-- and load-bearing for every Tea program — is the skipRender guard, proven
-- here byte-exactly (the "1"/"0" tail of the output):
--   sr1  prev = []                 -> 0: nothing painted yet, the FIRST
--       frame always paints (skipping it would leave a blank screen, since
--       prev's rows are not on it);
--   sr2  prev /= [], same model    -> 1: skip (repaint is a pure no-op);
--   sr3  prev /= [], changed model -> 0: must repaint;
--   sr4  deep structural equality: a freshly built RECORD equal to the
--       painted one skips too (Runtime.sameValue lowers to the VM's deep
--       structural `=` prim, not the comparable-restricted `==`).

import Tea exposing (skipRender)


sr1 =
  skipRender { mod = 1, prev = [], rows = 24, cols = 80 } 1


sr2 =
  skipRender { mod = 1, prev = [ "x" ], rows = 24, cols = 80 } 1


sr3 =
  skipRender { mod = 1, prev = [ "x" ], rows = 24, cols = 80 } 2


sr4 =
  skipRender { mod = { a = 1, b = "x" }, prev = [ "x" ], rows = 24, cols = 80 } { a = 1, b = "x" }


bit b =
  if b then
    "1"

  else
    "0"


main =
  String.append "skipRender[prev=[],same,changed,deepEq]="
    (String.append (bit sr1)
      (String.append (bit sr2) (String.append (bit sr3) (bit sr4)))
    )
