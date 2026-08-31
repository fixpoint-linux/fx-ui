module TeaUnit exposing (main)

-- STEP 3 (Tea core loop): PURE renderer check.  Paints six frames through
-- Tea.paint with a fixed model and asserts the EXACT ANSI byte stream:
--   1  first paint hides the cursor and writes every line (clear-line +
--      text + CRLF);
--   2  repaint, all lines changed AND longer: move-up + full rewrites;
--   3  repaint, shorter: move-up + rewrite + clear-to-end (\e[J);
--   4  repaint, first line UNCHANGED (differential: only the CRLF advance,
--      no clear, no text) + one new line painted fully;
--   5  repaint, first line unchanged, middle changed, one line added;
--   6  repaint, first line unchanged and SHRUNK: one advance + \e[J wipes
--      the two stale rows below.
-- main returns the concatenated frame string (printValue emits strings raw
-- between quotes), so expected/teaunit.txt is the byte-exact dump.

import Tea exposing (paint, skipRender)


model0 =
  { mod = ()
  , prev = []
  , rows = 24
  , cols = 80
  }


main =
  let
    ( m1, s1 ) =
      paint model0 () [ "alpha", "beta" ]

    ( m2, s2 ) =
      paint m1 () [ "alpha2", "beta2", "gamma" ]

    ( m3, s3 ) =
      paint m2 () [ "only" ]

    ( m4, s4 ) =
      paint m3 () [ "only", "row2" ]

    ( m5, s5 ) =
      paint m4 () [ "only", "row2x", "row3" ]

    ( _, s6 ) =
      paint m5 () [ "only" ]
  in
  String.append
    (String.append s1
      (String.append s2
        (String.append s3 (String.append s4 (String.append s5 s6)))
      )
    )
    skipRenderDump


-- SKIP-RENDER (runtime-owned, Tea.delegate): a delivery whose update returns
-- a structurally UNCHANGED model skips config.view + the repaint entirely —
-- the pure view would re-emit a byte-identical frame.  skipRender is the
-- guard, proven here byte-exactly (the "1"/"0" tail of the output):
--   sr1  prev = []                 -> 0: nothing painted yet, the FIRST
--       frame always paints (load-bearing guard — skipping it would leave a
--       blank screen, since prev's rows are not on it);
--   sr2  prev /= [], same model    -> 1: skip (repaint is a pure no-op);
--   sr3  prev /= [], changed model -> 0: must repaint;
--   sr4  deep structural equality: a freshly built RECORD equal to the
--       painted one skips too (Runtime.sameValue lowers to the VM's deep
--       structural `=` prim, not the comparable-restricted `==`).
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


skipRenderDump =
  String.append "\nskipRender[prev=[],same,changed,deepEq]="
    (String.append (bit sr1)
      (String.append (bit sr2) (String.append (bit sr3) (bit sr4)))
    )
