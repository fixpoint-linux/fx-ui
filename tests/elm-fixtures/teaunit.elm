module TeaUnit exposing (main)

-- STEP 3 (Tea core loop): PURE renderer check.  Paints three frames through
-- Tea.paint with a fixed model and asserts the EXACT ANSI byte stream: the
-- first paint hides the cursor and writes every line (clear-line + text +
-- CRLF); the second moves up over the previous frame and rewrites per-line;
-- the third shrinks the frame, so a clear-to-end follows its last line.
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

    ( _, s3 ) =
      paint m2 () [ "only" ]
  in
  String.append s1 (String.append s2 s3)
