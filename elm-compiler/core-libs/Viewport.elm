module Viewport exposing
  ( Model
  , KeyMap
  , init
  , defaultKeyMap
  , setContent
  , setWidth
  , setHeight
  , setHorizontalStep
  , maxYOffset
  , maxHeight
  , maxXOffset
  , atTop
  , atBottom
  , yOffset
  , xOffset
  , setYOffset
  , setXOffset
  , scrollDown
  , scrollUp
  , scrollLeft
  , scrollRight
  , pageDown
  , pageUp
  , halfPageDown
  , halfPageUp
  , gotoTop
  , gotoBottom
  , height
  , width
  , update
  , updateMouse
  , view
  )

-- S4 bubbles viewport widget (charmbracelet/bubbles viewport, subset-ported
-- over the Tea v2 loop).  The scrollable content box every data widget
-- (textarea, list, table) embeds: it keeps `lines` + the longest-line CELL
-- width, scrolls vertically (page/half-page/line keys) and horizontally
-- (Str.cut window), and renders through a Lipgloss style (border/padding/
-- margin) around a fixed content cell area.
--
-- Go parity notes (against viewport.go master):
--   * maxYOffset = max 0 (totalLines - height + verticalFrame) where the
--     frame is the style's padTop+padBottom plus 2 for a set border; the
--     frame is ADDED back so the content area (height - frame) is what the
--     line count is measured against (Go GetVerticalFrameSize).
--   * maxXOffset = max 0 (longestLineWidth - width) — the FULL width, NOT the
--     content width (Go maxXOffset does not subtract the horizontal frame).
--   * AtTop is yOffset <= 0, AtBottom is yOffset >= maxYOffset; page ops
--     no-op at their bounds, line ops clamp via SetYOffset.
--   * the keymap order is Go's switch order: pageDown, pageUp, halfPageDown,
--     halfPageUp, down, up, left, right.
--   * View mirrors Go View(): w/h = min(model size, style size), content
--     rendered as Width(contentW) Height(contentH) THEN the style (with its
--     width/height unset) wraps it — so border/padding add the frame back.
--
-- DEVIATIONS (all documented, none observable in the subset):
--   * softWrap is FIXED False (field present for parity, always False) — the
--     soft-wrap/gutter/highlight/styleLineFunc machinery is omitted; the
--     horizontal scroll is the Str.cut window (x/ansi.Cut parity).
--   * shift+wheel horizontal scroll is not decoded (MouseMsg carries no
--     modifier bits) and MouseWheelLeft/Right are ignored — wheel up/down
--     only, by mouseWheelDelta lines.
--   * SetContent normalizes "\r\n" to "\n" BEFORE splitting (Go's
--     SetContentLines splits first and leaves a trailing lone \r — a quirk we
--     do not reproduce).


{-| A set of keybindings for the viewport (Go viewport.KeyMap).
-}
type alias KeyMap =
  { pageDown : Key.Binding
  , pageUp : Key.Binding
  , halfPageUp : Key.Binding
  , halfPageDown : Key.Binding
  , down : Key.Binding
  , up : Key.Binding
  , left : Key.Binding
  , right : Key.Binding
  }


{-| The viewport state (Go viewport.Model, scroll subset).
-}
type alias Model =
  { width : Int
  , height : Int
  , keyMap : KeyMap
  , softWrap : Bool
  , fillHeight : Bool
  , mouseWheelEnabled : Bool
  , mouseWheelDelta : Int
  , yOffset : Int
  , xOffset : Int
  , horizontalStep : Int
  , style : Lipgloss.Style
  , lines : List String
  , longestLineWidth : Int
  }


{-| Go DefaultKeyMap (viewport/keymap.go): pager-like bindings.
-}
defaultKeyMap : KeyMap
defaultKeyMap =
  { pageDown = Key.newBinding [ "pgdown", "space", "f" ] "f/pgdn" "page down"
  , pageUp = Key.newBinding [ "pgup", "b" ] "b/pgup" "page up"
  , halfPageUp = Key.newBinding [ "u", "ctrl+u" ] "u" "½ page up"
  , halfPageDown = Key.newBinding [ "d", "ctrl+d" ] "d" "½ page down"
  , up = Key.newBinding [ "up", "k" ] "↑/k" "up"
  , down = Key.newBinding [ "down", "j" ] "↓/j" "down"
  , left = Key.newBinding [ "left", "h" ] "←/h" "move left"
  , right = Key.newBinding [ "right", "l" ] "→/l" "move right"
  }


{-| New(width, height) with Go's setInitialValues defaults: mouse wheel on with
a 3-line delta, a 6-cell horizontal step, empty content.
-}
init : Int -> Int -> Model
init w h =
  { width = w
  , height = h
  , keyMap = defaultKeyMap
  , softWrap = False
  , fillHeight = False
  , mouseWheelEnabled = True
  , mouseWheelDelta = 3
  , yOffset = 0
  , xOffset = 0
  , horizontalStep = 6
  , style = Lipgloss.newStyle
  , lines = []
  , longestLineWidth = 0
  }


-- ---- sizing helpers ----


{-| The vertical frame the style adds to the content area: top+bottom padding
plus 2 cells for a set border (Go GetVerticalFrameSize; a borderless style adds
nothing).
-}
verticalFrame : Lipgloss.Style -> Int
verticalFrame s =
  case s.border of
    Just _ ->
      s.padTop + s.padBottom + 2

    Nothing ->
      s.padTop + s.padBottom


{-| The horizontal frame (left+right padding plus a 2-cell border).
-}
horizontalFrame : Lipgloss.Style -> Int
horizontalFrame s =
  case s.border of
    Just _ ->
      s.padLeft + s.padRight + 2

    Nothing ->
      s.padLeft + s.padRight


{-| The content height (Go maxHeight): model height minus the vertical frame.
-}
maxHeight : Model -> Int
maxHeight m =
  max 0 (m.height - verticalFrame m.style)


{-| The content width (Go maxWidth): model width minus the horizontal frame.
-}
maxWidth : Model -> Int
maxWidth m =
  max 0 (m.width - horizontalFrame m.style)


{-| Go maxYOffset: the line count measured against the content area, floored
at zero.  total = len(lines) since softWrap is fixed False.
-}
maxYOffset : Model -> Int
maxYOffset m =
  max 0 (length m.lines - m.height + verticalFrame m.style)


{-| Go maxXOffset: the widest line measured against the FULL width (no
horizontal frame subtraction — Go parity).
-}
maxXOffset : Model -> Int
maxXOffset m =
  max 0 (m.longestLineWidth - m.width)


-- ---- content ----


{-| SetContent: normalize "\r\n" to "\n", split on "\n" (Str.lines), and treat
a single zero-width line as empty content (Go's nil-lines case).  Recomputes
longestLineWidth and clamps the y offset into the new range (Go SetContent's
GotoBottom-on-past-bottom).
-}
setContent : String -> Model -> Model
setContent s m =
  let
    norm =
      splitContent (Str.replace "\r\n" "\n" s)

    m1 =
      { m | lines = norm, longestLineWidth = maxLineWidth norm }
  in
  if m1.yOffset > maxYOffset m1 then
    gotoBottom m1

  else
    m1


splitContent : String -> List String
splitContent s =
  case Str.lines s of
    l :: [] ->
      if Str.width l == 0 then
        []

      else
        l :: []

    ls ->
      ls


maxLineWidth : List String -> Int
maxLineWidth ls =
  case ls of
    [] ->
      0

    l :: rest ->
      max (Str.width l) (maxLineWidth rest)


-- ---- state accessors ----


atTop : Model -> Bool
atTop m =
  m.yOffset <= 0


atBottom : Model -> Bool
atBottom m =
  m.yOffset >= maxYOffset m


yOffset : Model -> Int
yOffset m =
  m.yOffset


xOffset : Model -> Int
xOffset m =
  m.xOffset


height : Model -> Int
height m =
  m.height


width : Model -> Int
width m =
  m.width


setWidth : Int -> Model -> Model
setWidth w m =
  { m | width = w }


setHeight : Int -> Model -> Model
setHeight h m =
  { m | height = h }


{-| SetHorizontalStep (Go clamps to >= 0; <= 0 disables horizontal scroll).
-}
setHorizontalStep : Int -> Model -> Model
setHorizontalStep n m =
  { m | horizontalStep = max 0 n }


-- ---- scrolling ----


{-| SetYOffset clamps into [0, maxYOffset].
-}
setYOffset : Int -> Model -> Model
setYOffset n m =
  { m | yOffset = clamp 0 (maxYOffset m) n }


{-| SetXOffset clamps into [0, maxXOffset] (no-op when soft wrap is on; it is
always off here, kept for parity).
-}
setXOffset : Int -> Model -> Model
setXOffset n m =
  if m.softWrap then
    m

  else
    { m | xOffset = clamp 0 (maxXOffset m) n }


scrollDown : Int -> Model -> Model
scrollDown n m =
  if atBottom m || n == 0 || isEmpty m.lines then
    m

  else
    setYOffset (m.yOffset + n) m


scrollUp : Int -> Model -> Model
scrollUp n m =
  if atTop m || n == 0 || isEmpty m.lines then
    m

  else
    setYOffset (m.yOffset - n) m


scrollLeft : Int -> Model -> Model
scrollLeft n m =
  setXOffset (m.xOffset - n) m


scrollRight : Int -> Model -> Model
scrollRight n m =
  setXOffset (m.xOffset + n) m


pageDown : Model -> Model
pageDown m =
  if atBottom m then
    m

  else
    scrollDown m.height m


pageUp : Model -> Model
pageUp m =
  if atTop m then
    m

  else
    scrollUp m.height m


halfPageDown : Model -> Model
halfPageDown m =
  if atBottom m then
    m

  else
    scrollDown (m.height // 2) m


halfPageUp : Model -> Model
halfPageUp m =
  if atTop m then
    m

  else
    scrollUp (m.height // 2) m


gotoTop : Model -> Model
gotoTop m =
  setYOffset 0 m


gotoBottom : Model -> Model
gotoBottom m =
  setYOffset (maxYOffset m) m


-- ---- Tea surface ----


{-| Handle one key against the keymap (Go updateAsModel KeyPressMsg, in its
exact switch order).
-}
update : Runtime.Key -> Model -> Model
update key m =
  if Key.matches key [ m.keyMap.pageDown ] then
    pageDown m

  else if Key.matches key [ m.keyMap.pageUp ] then
    pageUp m

  else if Key.matches key [ m.keyMap.halfPageDown ] then
    halfPageDown m

  else if Key.matches key [ m.keyMap.halfPageUp ] then
    halfPageUp m

  else if Key.matches key [ m.keyMap.down ] then
    scrollDown 1 m

  else if Key.matches key [ m.keyMap.up ] then
    scrollUp 1 m

  else if Key.matches key [ m.keyMap.left ] then
    scrollLeft m.horizontalStep m

  else if Key.matches key [ m.keyMap.right ] then
    scrollRight m.horizontalStep m

  else
    m


{-| Handle a decoded SGR mouse event (Go updateAsModel MouseWheelMsg): wheel
down/up scroll by mouseWheelDelta lines.  Shift-horizontal and wheel-left/
right are not decoded (MouseMsg carries no modifier bits) — documented.
-}
updateMouse : Runtime.MouseMsg -> Model -> Model
updateMouse msg m =
  if not m.mouseWheelEnabled then
    m

  else
    case msg of
      MouseMsg MouseWheel MouseWheelDown _ _ ->
        scrollDown m.mouseWheelDelta m

      MouseMsg MouseWheel MouseWheelUp _ _ ->
        scrollUp m.mouseWheelDelta m

      _ ->
        m


-- ---- rendering ----


{-| The visible lines at the current offsets (Go visibleLines, soft wrap
always off): slice [yOffset, yOffset+contentHeight), optionally pad to
contentHeight when FillHeight, then cut each line to the [xOffset,
xOffset+contentWidth) cell window.
-}
visibleLines : Model -> List String
visibleLines m =
  let
    mh =
      maxHeight m

    mw =
      maxWidth m
  in
  if mh == 0 || mw == 0 then
    []

  else
    let
      ridx =
        min m.yOffset (length m.lines)

      bottom =
        min (length m.lines) (ridx + mh)

      sliced =
        take (bottom - ridx) (drop ridx m.lines)

      filled =
        if m.fillHeight then
          padLines mh sliced

        else
          sliced
    in
    if m.xOffset == 0 && m.longestLineWidth <= mw then
      filled

    else
      map (\l -> Str.cut m.xOffset (m.xOffset + mw) l) filled


padLines : Int -> List String -> List String
padLines h ls =
  if length ls < h then
    padLines h (append ls [ "" ])

  else
    ls


{-| View renders the viewport (Go View): effective size = min(model size,
style size), content sized to the content area and wrapped by the style with
its own width/height unset (border/padding/margin add the frame back).
-}
view : Model -> String
view m =
  let
    w =
      if m.style.width /= 0 then
        min m.width m.style.width

      else
        m.width

    h =
      if m.style.height /= 0 then
        min m.height m.style.height

      else
        m.height
  in
  if w == 0 || h == 0 then
    ""

  else
    let
      st =
        m.style

      contentW =
        w - horizontalFrame st

      contentH =
        h - verticalFrame st

      contents =
        Lipgloss.render
          (Lipgloss.setHeight contentH (Lipgloss.setWidth contentW Lipgloss.newStyle))
          (String.join "\n" (visibleLines m))

      outer =
        { st | width = 0, height = 0 }
    in
    Lipgloss.render outer contents
