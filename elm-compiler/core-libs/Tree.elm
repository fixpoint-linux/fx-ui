module Tree
  exposing
    ( KeyMap
    , Model
    , Node
    , Styles
    , allNodes
    , children
    , closeCurrentNode
    , defaultKeyMap
    , defaultStyles
    , down
    , fullHelp
    , goToBottom
    , goToTop
    , halfPageDown
    , halfPageUp
    , isOpen
    , leaf
    , new
    , nodeAt
    , nodeAtCurrentOffset
    , openCurrentNode
    , openNodeAt
    , closeNodeAt
    , pageDown
    , pageUp
    , plainStyles
    , root
    , setNodes
    , setScrollOff
    , setShowHelp
    , setStyles
    , setViewportYOffset
    , setWidth
    , setHeight
    , setYOffset
    , shortHelp
    , showHelpView
    , size
    , toggleCurrentNode
    , up
    , update
    , value
    , view
    , viewportYOffset
    , yOffset
    )

-- S10 bubbles tree widget (charm.land/bubbles/v2 tree, subset-ported over the
-- Tea v2 loop).  A PURE widget: `update : Runtime.Key -> Model -> Model`
-- (model-only, no Cmds, no host prims) — the app routes its own Key msgs
-- through `update` and renders `view`.  Reuses the ported Viewport (the
-- scroll box), Help and Key widgets; lipgloss/v2/tree is NOT in Lipgloss.elm,
-- so the classic tree-string renderer is embedded here.
--
-- Go parity notes (against tree.go / node.go / styles.go master):
--   * BYTE TRUTH (default_tree.golden): the root line is the open/closed
--     indicator ("▼ "/"▶ ") glued to the value; each child line is
--     per-ancestor indenter segments ("│  " when that ancestor is a non-last
--     child, "   " when it is the last) + the enumerator ("├──" non-last /
--     "└──" last) GLUED to the value with no space; an open parent node's
--     value cell starts with its own indicator.  The cursor column (one rune
--     per rendered row, "→" on the selected row) is joined LEFT of the tree
--     (JoinHorizontal(Top, cursor, tree)); the tree block is sized by
--     TreeStyle.Width(width).MaxWidth(width) — wrap/pad at the FULL width,
--     exactly tree.go:369 — and the viewport cuts every cursor-joined row
--     (width + cursor column) back to the width.
--   * yOffsets: Go stores yOffset/lineOffset per mutable Node (setYOffsets
--     DFS preorder over VISIBLE nodes).  Here the Node tree is immutable, so
--     a node's offset IS its preorder index over open nodes (allNodes) —
--     findNode(y) = the y-th visible node, Size = its count.  With
--     single-line values lineOffset == yOffset everywhere (deviation below),
--     so one index serves both.
--   * updateViewport(movement): clamp yOffset into [0, size-1]; SetContent
--     the joined cursor+tree block; then (unless the initial
--     yOffset==0/movement==0 render) the scrolloff reveal — off =
--     min(scrollOff, visibleLines//2), minTop = max(selLine-off, 0), minBottom
--     = min(totalLines-1, selLine+off); reveal above when viewport.yOffset >
--     minTop, else below when viewport.yOffset + visible < minBottom + 1.
--   * SetSize: viewport gets width x (height - helpViewHeight) — the help
--     height measured with the help's OLD width (Go sets Help.SetWidth
--     after); the help view itself is HelpStyle (PaddingTop 1) around
--     Help.View(short, full).
--   * Update's key order is Go's switch: down, up, pgdown, pgup,
--     halfPageDown, halfPageUp, goToTop, goToBottom, toggle, open, close,
--     then "?" flips Help.ShowAll.
--   * Dark styles (DefaultStyles(isDark=true)): node #B0B0B0, selected
--     node/cursor 256-color 212 + bold, root #EE6FF8 (selected root keeps its
--     root color and takes ONLY selected's bold — Go RootNodeStyle.Inherit),
--     parent 99, enumerator/indenter #3C3C3C, open indicator #5C5C5C, help
--     style PaddingTop 1.
--
-- DEVIATIONS (all documented, none observable in the subset):
--   * single-line node values only — the multi-line lineOffset machinery is
--     dropped; a node's rendered height equals its visible node count.
--   * open : Bool replaces Go's Hidden/Offset machinery; the indicator and
--     the parent STYLE are tied to having children (Go ties them to isRoot —
--     a childless Root() node would show a bare indicator and parent color;
--     not representable in the { value, children, open } shape).
--   * classic glyphs baked in: no Enumerator/Indenter (or their styles)
--     setters; SetOpenCharacter/SetCursorCharacter/SetClosedCharacter dropped
--     (the chars are plain model fields openChar/closedChar/cursorChar).
--   * static per-node-kind styles only — no StyleFunc closures, light palette
--     dropped (defaultStyles is dark); plainStyles (all no-op styles, cursor
--     padding and help padding kept) exists for byte-exact unstyled renders.
--   * Node is a wrapped record (`type Node = Node { .. }`) — recursive type
--     aliases do not exist; projections are the value/children/isOpen fns.


import Help
import Key
import Lipgloss
import Str
import Viewport


{-| The keybindings (Go tree.KeyMap).
-}
type alias KeyMap =
  { down : Key.Binding
  , up : Key.Binding
  , pageDown : Key.Binding
  , pageUp : Key.Binding
  , halfPageDown : Key.Binding
  , halfPageUp : Key.Binding
  , goToTop : Key.Binding
  , goToBottom : Key.Binding
  , toggle : Key.Binding
  , open : Key.Binding
  , close : Key.Binding
  , showFullHelp : Key.Binding
  , closeFullHelp : Key.Binding
  }


{-| A tree node (Go tree.Node, value/children/open subset).  `open` carries
the open/closed state; children of a closed node are hidden.
-}
type Node
  = Node
      { value : String
      , children : List Node
      , open : Bool
      }


{-| The render styles (Go tree.Styles, static dark subset).
-}
type alias Styles =
  { treeStyle : Lipgloss.Style
  , helpStyle : Lipgloss.Style
  , nodeStyle : Lipgloss.Style
  , selectedNodeStyle : Lipgloss.Style
  , rootNodeStyle : Lipgloss.Style
  , parentNodeStyle : Lipgloss.Style
  , cursorStyle : Lipgloss.Style
  , enumeratorStyle : Lipgloss.Style
  , selectedEnumeratorStyle : Lipgloss.Style
  , indenterStyle : Lipgloss.Style
  , openIndicatorStyle : Lipgloss.Style
  }


{-| The widget state (Go tree.Model; the help-key closures and the
Enumerator/Indenter back-refs of the Go model are dropped).
-}
type alias Model =
  { keyMap : KeyMap
  , help : Help.Model
  , showHelp : Bool
  , scrollOff : Int
  , openChar : String
  , closedChar : String
  , cursorChar : String
  , styles : Styles
  , root : Node
  , viewport : Viewport.Model
  , width : Int
  , height : Int
  , yOffset : Int
  }


{-| Go DefaultKeyMap.
-}
defaultKeyMap : KeyMap
defaultKeyMap =
  { down = Key.newBinding [ "down", "j", "ctrl+n" ] "↓/j" "down"
  , up = Key.newBinding [ "up", "k", "ctrl+p" ] "↑/k" "up"
  , pageDown = Key.newBinding [ "pgdown", " ", "f" ] "f/pgdn" "page down"
  , pageUp = Key.newBinding [ "pgup", "b" ] "b/pgup" "page up"
  , halfPageDown = Key.newBinding [ "d", "ctrl+d" ] "d" "½ page down"
  , halfPageUp = Key.newBinding [ "u", "ctrl+u" ] "u" "½ page up"
  , goToTop = Key.newBinding [ "g", "home" ] "g" "top"
  , goToBottom = Key.newBinding [ "G", "shift+g", "end" ] "G" "bottom"
  , toggle = Key.newBinding [ "enter" ] "⏎" "toggle"
  , open = Key.newBinding [ "l", "right" ] "→/l" "open"
  , close = Key.newBinding [ "h", "left" ] "←/h" "close"
  , showFullHelp = Key.newBinding [ "?" ] "?" "more"
  , closeFullHelp = Key.newBinding [ "?" ] "?" "close help"
  }


{-| DefaultStyles(isDark = True) — the dark palette.
-}
defaultStyles : Styles
defaultStyles =
  let
    verySubdued =
      Lipgloss.foreground (Lipgloss.color "#3C3C3C") Lipgloss.newStyle
  in
  { treeStyle = Lipgloss.newStyle
  , helpStyle = Lipgloss.paddingTop 1 Lipgloss.newStyle
  , nodeStyle = Lipgloss.foreground (Lipgloss.color "#B0B0B0") Lipgloss.newStyle
  , selectedNodeStyle = Lipgloss.bold True (Lipgloss.foreground (Lipgloss.color "212") Lipgloss.newStyle)
  , rootNodeStyle = Lipgloss.foreground (Lipgloss.color "#EE6FF8") Lipgloss.newStyle
  , parentNodeStyle = Lipgloss.foreground (Lipgloss.color "99") Lipgloss.newStyle
  , cursorStyle = Lipgloss.bold True (Lipgloss.foreground (Lipgloss.color "212") (Lipgloss.paddingRight 1 Lipgloss.newStyle))
  , enumeratorStyle = verySubdued
  , selectedEnumeratorStyle = verySubdued
  , indenterStyle = verySubdued
  , openIndicatorStyle = Lipgloss.foreground (Lipgloss.color "#5C5C5C") Lipgloss.newStyle
  }


{-| The no-color styleset for byte-exact unstyled renders: every color style
is a no-op, while the two GEOMETRY styles keep their paddings (they survive
ansi.Strip in Go).
-}
plainStyles : Styles
plainStyles =
  { treeStyle = Lipgloss.newStyle
  , helpStyle = Lipgloss.paddingTop 1 Lipgloss.newStyle
  , nodeStyle = Lipgloss.newStyle
  , selectedNodeStyle = Lipgloss.newStyle
  , rootNodeStyle = Lipgloss.newStyle
  , parentNodeStyle = Lipgloss.newStyle
  , cursorStyle = Lipgloss.paddingRight 1 Lipgloss.newStyle
  , enumeratorStyle = Lipgloss.newStyle
  , selectedEnumeratorStyle = Lipgloss.newStyle
  , indenterStyle = Lipgloss.newStyle
  , openIndicatorStyle = Lipgloss.newStyle
  }


-- ---- node builders / projections ----


{-| Root builds an OPEN node with children (Go tree.Root; the fluent
Child(...) chain collapses into the list argument).
-}
root : String -> List Node -> Node
root v kids =
  Node { value = v, children = kids, open = True }


{-| Leaf builds a childless node (Go Child("...") — no indicator, no
children to toggle).
-}
leaf : String -> Node
leaf v =
  Node { value = v, children = [], open = False }


value : Node -> String
value n =
  case n of
    Node r ->
      r.value


children : Node -> List Node
children n =
  case n of
    Node r ->
      r.children


isOpen : Node -> Bool
isOpen n =
  case n of
    Node r ->
      r.open


setOpen : Bool -> Node -> Node
setOpen b n =
  case n of
    Node r ->
      Node { r | open = b }


{-| The visible (open-flattened) preorder list — Go AllNodes; a closed
child counts as exactly itself.
-}
allNodes : Node -> List Node
allNodes n =
  n :: concatMap allNodes (visibleChildren n)


{-| The prelude alias table exposes map/filter/foldl/... bare but not
concat, so the one flatten site carries its own concatMap.
-}
concatMap : (a -> List b) -> List a -> List b
concatMap f xs =
  case xs of
    x :: rest ->
      append (f x) (concatMap f rest)

    [] ->
      []


visibleChildren : Node -> List Node
visibleChildren n =
  if isOpen n then
    children n

  else
    []


{-| Go Node.Size(): the number of VISIBLE nodes in the subtree.
-}
size : Node -> Int
size n =
  length (allNodes n)


{-| Go findNode: the Maybe-wrapped y-th visible node (DFS preorder — the
same order setYOffsets assigns).
-}
nodeIn : Int -> Node -> Maybe Node
nodeIn k n =
  case drop k (allNodes n) of
    hit :: _ ->
      Just hit

    [] ->
      Nothing


{-| Go Model.Node: the node at the given y offset of the MODEL's tree.
-}
nodeAt : Int -> Model -> Maybe Node
nodeAt k m =
  nodeIn k m.root


{-| Go Model.NodeAtCurrentOffset.
-}
nodeAtCurrentOffset : Model -> Maybe Node
nodeAtCurrentOffset m =
  nodeIn m.yOffset m.root


-- ---- model ----


{-| New(t, width, height) with the Go defaults: help on, scrollOff 5, the
classic glyphs, dark styles; sizes, then the initial render (movement 0).
-}
new : Node -> Int -> Int -> Model
new t w h =
  updateViewport 0
    (setSize w h
      { keyMap = defaultKeyMap
      , help = Help.new
      , showHelp = True
      , scrollOff = 5
      , openChar = "▼"
      , closedChar = "▶"
      , cursorChar = "→"
      , styles = defaultStyles
      , root = t
      , viewport = Viewport.init 0 0
      , width = 0
      , height = 0
      , yOffset = 0
      }
    )


-- ---- accessors / setters ----


yOffset : Model -> Int
yOffset m =
  m.yOffset


{-| Go ViewportYOffset.
-}
viewportYOffset : Model -> Int
viewportYOffset m =
  m.viewport.yOffset


{-| Go SetViewportYOffset (clamped by the viewport).
-}
setViewportYOffset : Int -> Model -> Model
setViewportYOffset y m =
  { m | viewport = Viewport.setYOffset y m.viewport }


{-| Go SetYOffset: SELECT the node at the offset (the movement is the delta).
-}
setYOffset : Int -> Model -> Model
setYOffset y m =
  updateViewport (y - m.yOffset) m


setScrollOff : Int -> Model -> Model
setScrollOff v m =
  { m | scrollOff = v }


{-| Go SetShowHelp: re-sizes (the viewport height depends on the help block).
-}
setShowHelp : Bool -> Model -> Model
setShowHelp v m =
  setSize m.width m.height { m | showHelp = v }


{-| Go SetStyles: swap + re-size + re-render (the viewport content still
holds the old styles' bytes).
-}
setStyles : Styles -> Model -> Model
setStyles s m =
  updateViewport 0 (setSize m.width m.height { m | styles = s })


{-| Go SetNodes: swap the root and re-render (the selection offset is KEPT
and clamped by updateViewport — Go parity).
-}
setNodes : Node -> Model -> Model
setNodes t m =
  updateViewport 0 { m | root = t }


{-| Go SetSize: the viewport is width x (height - helpHeight), the help
height measured with the OLD help width (Go sets Help.SetWidth last).
-}
setSize : Int -> Int -> Model -> Model
setSize w h m =
  let
    m1 =
      { m | width = w, height = h }

    hv =
      if m1.showHelp then
        Lipgloss.height (helpView m1)

      else
        0
  in
  { m1
    | viewport = Viewport.setHeight (h - hv) (Viewport.setWidth w m1.viewport)
    , help = Help.setWidth w m1.help
  }


{-| Go SetWidth.
-}
setWidth : Int -> Model -> Model
setWidth w m =
  setSize w m.height m


{-| Go SetHeight.
-}
setHeight : Int -> Model -> Model
setHeight h m =
  setSize m.width h m


-- ---- navigation (Go Update's action methods) ----


down : Model -> Model
down m =
  updateViewport 1 m


up : Model -> Model
up m =
  updateViewport (0 - 1) m


pageDown : Model -> Model
pageDown m =
  updateViewport (Viewport.height m.viewport) m


pageUp : Model -> Model
pageUp m =
  updateViewport (0 - Viewport.height m.viewport) m


halfPageDown : Model -> Model
halfPageDown m =
  updateViewport (Viewport.height m.viewport // 2) m


halfPageUp : Model -> Model
halfPageUp m =
  updateViewport (0 - (Viewport.height m.viewport // 2)) m


goToTop : Model -> Model
goToTop m =
  updateViewport (0 - m.yOffset) m


goToBottom : Model -> Model
goToBottom m =
  updateViewport (size m.root) m


{-| Go ToggleCurrentNode: flip the selected node's open state.
-}
toggleCurrentNode : Model -> Model
toggleCurrentNode m =
  case nodeAtCurrentOffset m of
    Just n ->
      toggleNode (not (isOpen n)) m

    Nothing ->
      m


{-| Go OpenCurrentNode.
-}
openCurrentNode : Model -> Model
openCurrentNode m =
  toggleNode True m


{-| Go CloseCurrentNode.
-}
closeCurrentNode : Model -> Model
closeCurrentNode m =
  toggleNode False m


{-| Go toggleNode: flip the node at the selection, then re-render (the
offset is kept; updateViewport clamps it into the new size).
-}
toggleNode : Bool -> Model -> Model
toggleNode b m =
  case nodeAtCurrentOffset m of
    Just _ ->
      updateViewport 0 { m | root = setOpenAt m.yOffset b m.root }

    Nothing ->
      m


{-| Rebuild the tree with the k-th VISIBLE node's open flag set (the
countdown walks the same preorder allNodes does).
-}
setOpenAt : Int -> Bool -> Node -> Node
setOpenAt k b n =
  case setOpenMaybe k b n of
    Just n2 ->
      n2

    Nothing ->
      n


setOpenMaybe : Int -> Bool -> Node -> Maybe Node
setOpenMaybe k b n =
  case n of
    Node r ->
      if k == 0 then
        Just (Node { r | open = b })

      else if not r.open then
        Nothing

      else
        case setOpenKids (k - 1) b r.children of
          Just kids ->
            Just (Node { r | children = kids })

          Nothing ->
            Nothing


{-| The countdown enters the first child at k-1 (the parent consumed one
step); a failed subtree consumed exactly its visible size.
-}
setOpenKids : Int -> Bool -> List Node -> Maybe (List Node)
setOpenKids k b kids =
  case kids of
    [] ->
      Nothing

    c :: rest ->
      case setOpenMaybe k b c of
        Just c2 ->
          Just (c2 :: rest)

        Nothing ->
          case setOpenKids (k - size c) b rest of
            Just rest2 ->
              Just (c :: rest2)

            Nothing ->
              Nothing


{-| Go Node.Open/Close through the model: set the node at the given
offset and re-render (the selection is untouched).
-}
openNodeAt : Int -> Model -> Model
openNodeAt k m =
  setOpenAtK k True m


closeNodeAt : Int -> Model -> Model
closeNodeAt k m =
  setOpenAtK k False m


setOpenAtK : Int -> Bool -> Model -> Model
setOpenAtK k b m =
  case nodeIn k m.root of
    Just _ ->
      updateViewport 0 { m | root = setOpenAt k b m.root }

    Nothing ->
      m


{-| The whole Update (Go's KeyPressMsg switch, same order): the pure
Runtime.Key -> Model -> Model fold.
-}
update : Runtime.Key -> Model -> Model
update key m =
  if Key.matches key [ m.keyMap.down ] then
    down m

  else if Key.matches key [ m.keyMap.up ] then
    up m

  else if Key.matches key [ m.keyMap.pageDown ] then
    pageDown m

  else if Key.matches key [ m.keyMap.pageUp ] then
    pageUp m

  else if Key.matches key [ m.keyMap.halfPageDown ] then
    halfPageDown m

  else if Key.matches key [ m.keyMap.halfPageUp ] then
    halfPageUp m

  else if Key.matches key [ m.keyMap.goToTop ] then
    goToTop m

  else if Key.matches key [ m.keyMap.goToBottom ] then
    goToBottom m

  else if Key.matches key [ m.keyMap.toggle ] then
    toggleCurrentNode m

  else if Key.matches key [ m.keyMap.open ] then
    openCurrentNode m

  else if Key.matches key [ m.keyMap.close ] then
    closeCurrentNode m

  else if Key.matches key [ m.keyMap.showFullHelp ] then
    flipHelp m

  else if Key.matches key [ m.keyMap.closeFullHelp ] then
    flipHelp m

  else
    m


flipHelp : Model -> Model
flipHelp m =
  { m | help = helpFlipped m.help }


helpFlipped : Help.Model -> Help.Model
helpFlipped h =
  { h | showAll = not h.showAll }


{-| The core render+scroll step (Go updateViewport): clamp the selection,
SetContent the joined cursor+tree block, then the scrolloff reveal.
-}
updateViewport : Int -> Model -> Model
updateViewport movement m =
  let
    total =
      size m.root

    y =
      max (min (total - 1) (m.yOffset + movement)) 0

    m1 =
      { m | yOffset = y }

    content =
      Lipgloss.joinHorizontal Lipgloss.PTop
        [ cursorView m1
        , Lipgloss.render
            (Lipgloss.maxWidth m1.width (Lipgloss.setWidth m1.width m1.styles.treeStyle))
            (treeString m1)
        ]

    m2 =
      { m1 | viewport = Viewport.setContent content m1.viewport }
  in
  if y == 0 && movement == 0 then
    m2

  else
    let
      vh =
        Viewport.maxHeight m2.viewport

      off =
        min m2.scrollOff (vh // 2)

      minTop =
        max (y - off) 0

      minBottom =
        min (length m2.viewport.lines - 1) (y + off)

      vy =
        m2.viewport.yOffset
    in
    if vy > minTop then
      { m2 | viewport = Viewport.setYOffset minTop m2.viewport }

    else if vy + vh < minBottom + 1 then
      { m2 | viewport = Viewport.setYOffset (minBottom - vh + 1) m2.viewport }

    else
      m2


-- ---- rendering ----


{-| The open/closed indicator cell (Go Node.Indicator): the char + a space,
styled; empty for childless nodes (the isRoot proxy — see the header).
-}
indicator : Model -> Node -> String
indicator m n =
  if isEmpty (children n) then
    ""

  else
    let
      ch =
        if isOpen n then
          m.openChar

        else
          m.closedChar
    in
    if ch == "" then
      ""

    else
      Lipgloss.render m.styles.openIndicatorStyle (String.append ch " ")


{-| The value cell: indicator + the styled value (Go Node.Value /
updateStyles' root line).  The root keeps its root color and takes only the
selected style's BOLD (Go RootNodeStyle.Inherit(SelectedNodeStyle) — exact
here for the bold attr: the root's own bold wins when set, else the selected
style's bold rides); child cells are selected / parent / node styles.
-}
valueCell : Model -> Bool -> Bool -> Node -> String
valueCell m sel isRoot n =
  let
    st =
      if isRoot then
        if sel && boldSet m.styles.selectedNodeStyle then
          Lipgloss.bold True m.styles.rootNodeStyle

        else
          m.styles.rootNodeStyle

      else if sel then
        m.styles.selectedNodeStyle

      else if not (isEmpty (children n)) then
        m.styles.parentNodeStyle

      else
        m.styles.nodeStyle
  in
  String.append (indicator m n) (Lipgloss.render st (value n))


{-| The bold attr bit of a style (Lipgloss's private boldKey = 1: props
marks "set", attrs holds the value).
-}
boldSet : Lipgloss.Style -> Bool
boldSet s =
  Bitwise.and s.props 1 /= 0 && Bitwise.and s.attrs 1 /= 0


{-| One indenter segment (Go classic indenter): a non-last ancestor draws
the vertical connector, a last ancestor blanks out.
-}
segFor : Model -> Bool -> String
segFor m nonLast =
  Lipgloss.render m.styles.indenterStyle
    (if nonLast then
      "│  "

     else
      "   "
    )


{-| The lines of one node: per-ancestor indenter segments + this node's
enumerator (the LAST flag of `flags`; Nothing for the root, which has no
enumerator) + the value cell, then the open node's children.
-}
nodeLines : Model -> Int -> List Bool -> Maybe Bool -> Node -> List String
nodeLines m idx flags ownLast n =
  let
    sel =
      idx == m.yOffset

    isRoot =
      case ownLast of
        Just _ ->
          False

        Nothing ->
          True

    segments =
      foldr (\f acc -> String.append (segFor m f) acc) "" flags

    enum =
      case ownLast of
        Just nonLast ->
          Lipgloss.render
            (if sel then
              m.styles.selectedEnumeratorStyle

             else
              m.styles.enumeratorStyle
            )
            (if nonLast then
              "├──"

             else
              "└──"
            )

        Nothing ->
          ""

    own =
      String.append segments (String.append enum (valueCell m sel isRoot n))

    kids =
      if isOpen n then
        kidLines m (idx + 1) (appendFlags flags ownLast) (children n)

      else
        []
  in
  own :: kids


{-| The strict-ancestor flags grow by this node's own lastness (the root
contributes none — its children are indented from column 0).
-}
appendFlags : List Bool -> Maybe Bool -> List Bool
appendFlags flags ownLast =
  case ownLast of
    Just nonLast ->
      append flags (nonLast :: [])

    Nothing ->
      flags


{-| The sibling block (Go setYOffsets' child walk): each child's preorder
index is base + one (itself) + the visible sizes of its earlier siblings.
-}
kidLines : Model -> Int -> List Bool -> List Node -> List String
kidLines m base flags kids =
  case kids of
    [] ->
      []

    c :: rest ->
      append
        (nodeLines m base flags (Just (not (isEmpty rest))) c)
        (kidLines m (base + size c) flags rest)


{-| The tree block (Go root.String() through the lipgloss renderer).
-}
treeString : Model -> String
treeString m =
  String.join "\n" (nodeLines m 0 [] Nothing m.root)


{-| The cursor column (Go cursorView): rootHeight rows of one space with the
cursor rune on the selected row, joined vertical and rendered through the
cursor style (PaddingRight 1 makes every row two cells).
-}
cursorView : Model -> String
cursorView m =
  if m.cursorChar == "" then
    ""

  else
    let
      h =
        size m.root

      rows =
        markRows 0 h m.yOffset m.cursorChar []
    in
    Lipgloss.render m.styles.cursorStyle (Lipgloss.joinVertical Lipgloss.PLeft rows)


markRows : Int -> Int -> Int -> String -> List String -> List String
markRows i h sel ch acc =
  if i >= h then
    reverse acc

  else
    markRows (i + 1) h sel ch
      ((if i == sel then
          ch

        else
          " "
       )
        :: acc
      )


{-| Go ShortHelp.
-}
shortHelp : Model -> List Key.Binding
shortHelp m =
  [ m.keyMap.down
  , m.keyMap.up
  , m.keyMap.toggle
  , m.keyMap.showFullHelp
  ]


{-| Go FullHelp.
-}
fullHelp : Model -> List (List Key.Binding)
fullHelp m =
  [ [ m.keyMap.down
    , m.keyMap.up
    , m.keyMap.open
    , m.keyMap.close
    , m.keyMap.toggle
    ]
  , [ m.keyMap.pageDown
    , m.keyMap.pageUp
    , m.keyMap.halfPageDown
    , m.keyMap.halfPageUp
    ]
  , [ m.keyMap.goToTop
    , m.keyMap.goToBottom
    ]
  , [ m.keyMap.closeFullHelp ]
  ]


{-| Go helpView: HelpStyle (PaddingTop 1) around the help widget's view.
-}
helpView : Model -> String
helpView m =
  Lipgloss.render m.styles.helpStyle (Help.view m.help (shortHelp m) (fullHelp m))


{-| Go SetShowHelp's subject: the help block ON/OFF — exposed so callers can
derive the expected viewport height the same way SetSize does.
-}
showHelpView : Model -> String
showHelpView m =
  helpView m


{-| Go View: the viewport block joined above the (optional) help block.
-}
view : Model -> String
view m =
  if m.showHelp then
    Lipgloss.joinVertical Lipgloss.PLeft
      [ Viewport.view m.viewport
      , helpView m
      ]

  else
    Viewport.view m.viewport
