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

import Tea exposing (paint)


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
  String.append s1
    (String.append s2
      (String.append s3 (String.append s4 (String.append s5 s6)))
    )
