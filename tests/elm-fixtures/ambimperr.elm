module Ambimperr exposing (main)

-- NEGATIVE fixture pinning the ambiguous-import check: `foo` is exposed bare
-- by TWO different modules.  The alias table is first-match-wins, so the
-- second row used to be silently dead and every bare `foo` resolved to
-- whichever import came first.  Real Elm rejects the ambiguity; the compiler
-- must fail LOUDLY before typechecking/lowering.

import A exposing (foo)
import B exposing (foo)


main =
    foo
