module TreeUnit exposing (main)

-- S10 gate (main : String): core-libs/Tree.elm (bubbles tree — the PURE
-- widget).  Everything renders through plainStyles (+ the help widget's own
-- styles blanked) so the bytes are the ansi-stripped counterpart of Go's
-- default_tree.golden: the full default render pins the "→ ▼ " cursor+root
-- indicator line, the "│  "/"   " indenter segments, the "├──"/"└──"
-- enumerators glued to the values, the per-parent "▼ " indicators inside
-- the enumerator cells, the 70-column viewport padding, the blank help
-- padding row and the short-help line.  The behavioral rows pin the close/
-- open/toggle folds (a closed root hides its children and shrinks the
-- render), the preorder y-offset walk (node k = the k-th VISIBLE node),
-- goToBottom/goToTop/setYOffset, the scrolloff reveal on a 21-node tree in
-- a 8-high viewport (off = min 5, 8//2 = 4), the cursor column riding the
-- selected row, the key surface (enter/l/h/j/G/g flip state through `update`,
-- an unmatched key is a no-op), the help flip (showAll + the 13-row total
-- with a 7-high viewport), the dark styleset actually painting SGR bytes,
-- and SetNodes clamping a kept selection into the new tree's size.  The
-- wide rows pin the over-wide single-line root value at width 70: the tree
-- block wraps at the FULL width (one row, the viewport cutting the
-- cursor-joined row back to width), not at width - cursor - frame.

import Help
import Lipgloss
import Str
import Tree


f : Bool -> String
f b =
  case b of
    True ->
      "1"

    False ->
      "0"


n : Int -> String
n =
  String.fromInt


line : Int -> String -> String
line k s =
  case drop k (Str.lines s) of
    l :: _ ->
      l

    [] ->
      ""


openAt : Int -> Tree.Model -> Bool
openAt k m =
  case Tree.nodeAt k m of
    Just nd ->
      Tree.isOpen nd

    Nothing ->
      False


valAt : Int -> Tree.Model -> String
valAt k m =
  case Tree.nodeAt k m of
    Just nd ->
      Tree.value nd

    Nothing ->
      "?"


{-| The help widget's own palette blanked (Help.defaultStyles is colored and
its styles are baked into Help.new).
-}
plainHelpStyles : Help.Styles
plainHelpStyles =
  { ellipsis = Lipgloss.newStyle
  , shortKey = Lipgloss.newStyle
  , shortDesc = Lipgloss.newStyle
  , shortSeparator = Lipgloss.newStyle
  , fullKey = Lipgloss.newStyle
  , fullDesc = Lipgloss.newStyle
  , fullSeparator = Lipgloss.newStyle
  }


{-| The parser subset has no nested record update ({ m.help | styles = .. }
does not parse), so the help model is rebuilt field-by-field.
-}
withPlainHelp : Tree.Model -> Tree.Model
withPlainHelp m =
  { m
    | help =
        { showAll = m.help.showAll
        , shortSeparator = m.help.shortSeparator
        , fullSeparator = m.help.fullSeparator
        , ellipsis = m.help.ellipsis
        , styles = plainHelpStyles
        , width = m.help.width
        }
  }


{-| The golden test tree (Go TestTree's "~/charm"), rendered unstyled at
70x13 (viewport 11 high + the 2-row help block).
-}
m0 : Tree.Model
m0 =
  withPlainHelp
    (Tree.setStyles
      Tree.plainStyles
      (Tree.new
        (Tree.root "~/charm"
          [ Tree.leaf "ayman"
          , Tree.root "bash"
              [ Tree.root "tools" [ Tree.leaf "zsh", Tree.leaf "doom-emacs" ] ]
          , Tree.root "carlos"
              [ Tree.root "emotes" [ Tree.leaf "chefkiss.png", Tree.leaf "kekw.png" ] ]
          , Tree.leaf "maas"
          ]
        )
        70
        13
      )
    )


{-| A 21-node tree (root + 20 leaves) in a 40x10 frame: the viewport is
8 high, so the scrolloff reveal (off = min 5, 8 // 2 = 4) engages.
-}
mTall : Tree.Model
mTall =
  Tree.setStyles
    Tree.plainStyles
    (Tree.new
      (Tree.root "top"
        [ Tree.leaf "n00", Tree.leaf "n01", Tree.leaf "n02", Tree.leaf "n03", Tree.leaf "n04"
        , Tree.leaf "n05", Tree.leaf "n06", Tree.leaf "n07", Tree.leaf "n08", Tree.leaf "n09"
        , Tree.leaf "n10", Tree.leaf "n11", Tree.leaf "n12", Tree.leaf "n13", Tree.leaf "n14"
        , Tree.leaf "n15", Tree.leaf "n16", Tree.leaf "n17", Tree.leaf "n18", Tree.leaf "n19"
        ]
      )
      40
      10
    )


{-| The DEFAULT dark styleset (SGR bytes must appear).
-}
mDark : Tree.Model
mDark =
  Tree.new
    (Tree.root "~/charm" [ Tree.leaf "ayman" ])
    70
    13


{-| The over-wide root: a childless root renders a bare 70-cell value line —
exactly the width, ONE rendered row with the first 68 tree cells visible
after the viewport cut (the tree block wraps/pads at the FULL width like
tree.go:369; sizing it at width - cursorWidth - frame would wrap this line
at 68 into TWO rows).  Line 1 stays a blank fill row — pinning the wrap.
-}
mWide : Tree.Model
mWide =
  withPlainHelp
    (Tree.setStyles
      Tree.plainStyles
      (Tree.new (Tree.root (Str.repeat 70 "w") []) 70 13)
    )


main =
  let
    -- the closed root: children hidden, indicator flips to "▶ ".
    mC =
      Tree.closeCurrentNode m0

    -- three downs: 1 ayman, 2 bash, 3 tools (preorder over VISIBLE nodes).
    d1 =
      Tree.down m0

    d2 =
      Tree.down d1

    d3 =
      Tree.down d2

    -- six downs put the selection on carlos (y 6); its cursor row pins the
    -- "→ " column at the selected row of the joined render.
    d6 =
      Tree.down (Tree.down (Tree.down d3))

    -- the walk to the bottom and back.
    mB =
      Tree.goToBottom m0

    mBup =
      Tree.up (Tree.up mB)

    -- tall-tree scrolloff: pageDown 8@5 (reveal below), a second pageDown
    -- pins the viewport at maxYOffset (16@13), pageUp 4 back to 12@13 ->
    -- the reveal-above branch keeps it pinned, half-page 4@2, setYOffset 5@2.
    pg1 =
      Tree.pageDown mTall

    pg2 =
      Tree.pageDown pg1

    pgu =
      Tree.pageUp pg2

    hpd =
      Tree.halfPageDown mTall

    sy =
      Tree.setYOffset 5 mTall

    tall m =
      String.append
        (String.append (n (Tree.yOffset m)) "@")
        (n (Tree.viewportYOffset m))

    -- the key surface: enter/l/h/j/G/g through `update`.
    kEnter =
      Tree.update KeyEnter m0

    kL =
      Tree.openCurrentNode mC

    -- close on an OPEN PARENT (bash, y 2): its 3 hidden descendants drop
    -- the visible count from 11 to 8.
    kH =
      Tree.closeCurrentNode d2

    kJ =
      Tree.update (KeyChar "j") m0

    kG =
      Tree.update (KeyChar "G") m0

    kg =
      Tree.update (KeyChar "g") kG

    kX =
      Tree.update (KeyChar "x") d1

    -- the help flip: Go's Update flips ShowAll WITHOUT a SetSize, so the
    -- viewport keeps its 11-row height (a quirk we port verbatim) and the
    -- full-help render is 11 + (1 padding + 5 help rows) = 17 rows.
    mH =
      Tree.update (KeyChar "?") m0

    mNoHelp =
      Tree.setShowHelp False m0

    -- SetNodes: a kept selection (bottom, y 10) clamps into the new size 2.
    mN =
      Tree.setNodes (Tree.root "a" [ Tree.leaf "b" ]) mB

    flags =
      [ "golden=" ++ Tree.view m0
      , "closed=" ++ Tree.view mC
      , "toggleEq=" ++ f (Tree.view (Tree.toggleCurrentNode m0) == Tree.view mC)
      , "reopenEq=" ++ f (Tree.view (Tree.openCurrentNode mC) == Tree.view m0)
      , "walk=" ++ n (Tree.yOffset d1) ++ "/" ++ n (Tree.yOffset d2) ++ "/" ++ n (Tree.yOffset d3)
      , "nodes=" ++ valAt 3 d3
      , "cursor6=" ++ Str.cut 0 15 (line 6 (Tree.view d6))
      , "bottom=" ++ n (Tree.yOffset mB) ++ "/" ++ valAt 10 mB
      , "up2=" ++ n (Tree.yOffset mBup) ++ " top=" ++ n (Tree.yOffset (Tree.goToTop mB))
      , "allnodes=" ++ n (length (Tree.allNodes m0.root))
      , "nodeAt10=" ++ valAt 10 m0
      , "nodeAt11=" ++ (case Tree.nodeAt 11 m0 of
                          Just nd ->
                            Tree.value nd

                          Nothing ->
                            "nothing")
      , "tallpg=" ++ tall pg1 ++ "," ++ tall pg2 ++ "," ++ tall pgu ++ "," ++ tall hpd ++ "," ++ tall sy
      , "enterClose=" ++ Str.cut 2 5 (line 0 (Tree.view kEnter))
      , "lOpen=" ++ f (openAt 0 kL)
      , "hClose=" ++ f (not (openAt 2 kH)) ++ " vis=" ++ n (length (Tree.allNodes kH.root))
      , "jkgG=" ++ n (Tree.yOffset kJ) ++ "/" ++ n (Tree.yOffset kG) ++ "/" ++ n (Tree.yOffset kg)
      , "badkey=" ++ f (Tree.view kX == Tree.view d1) ++ " y=" ++ n (Tree.yOffset kX)
      , "nohelp=" ++ n (length (Str.lines (Tree.view mNoHelp))) ++ " back=" ++ n (length (Str.lines (Tree.view (Tree.setShowHelp True mNoHelp))))
      , "helpall=" ++ f mH.help.showAll ++ " rows=" ++ n (length (Str.lines (Tree.view mH)))
      , "styled=" ++ Str.cut 0 40 (line 0 (Tree.view mDark))
      , "setnodes=" ++ n (length (Tree.allNodes mN.root)) ++ "/" ++ n (Tree.yOffset mN)
      , "wide0=" ++ Str.cut 0 20 (line 0 (Tree.view mWide))
      , "wide1=" ++ Str.cut 0 10 (line 1 (Tree.view mWide))
      ]
  in
  String.join "\n" flags
