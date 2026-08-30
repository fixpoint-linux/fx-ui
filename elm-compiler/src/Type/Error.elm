module Type.Error exposing (TypeError, atNode, atRange, render)

{-| A typechecker failure: a source `range` (elm-syntax node ranges), a short
one-line `summary`, and an optional longer `detail` (multi-line explanation).

`render` turns it into the message that flows through the compiler's existing
`err ` channel (`Main.elm`), e.g.

    type error at 3:7: record does not have field x

The gate runner's `compile_error` helper substring-matches this text, so the
`type error at <row>:<col>:` prefix is the stable contract.

-}

import Elm.Syntax.Node as Node exposing (Node)
import Elm.Syntax.Range as Range exposing (Range)


type alias TypeError =
    { range : Range
    , summary : String
    , detail : String
    }


{-| Build a `TypeError` from an elm-syntax `Node` (which always carries a range).
-}
atNode : Node a -> String -> String -> TypeError
atNode node summary detail =
    TypeError (Node.range node) summary detail


{-| Build a `TypeError` from an explicit `Range`.
-}
atRange : Range -> String -> String -> TypeError
atRange range summary detail =
    TypeError range summary detail


{-| Render a `TypeError` as `type error at <row>:<col>: <summary>`, with the
detail (when non-empty) on following lines.
-}
render : TypeError -> String
render { range, summary, detail } =
    "type error at "
        ++ String.fromInt range.start.row
        ++ ":"
        ++ String.fromInt range.start.column
        ++ ": "
        ++ summary
        ++ (if detail == "" then
                ""

            else
                "\n" ++ detail
           )
