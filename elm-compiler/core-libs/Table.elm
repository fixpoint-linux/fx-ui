module Table exposing
  ( Column
  , Row
  , Model
  , KeyMap
  , Styles
  , new
  , defaultKeyMap
  , defaultStyles
  , setStyles
  , setColumns
  , setRows
  , setWidth
  , setHeight
  , setCursor
  , moveUp
  , moveDown
  , gotoTop
  , gotoBottom
  , update
  , view
  , headersView
  , selectedRow
  , rows
  , columns
  , cursor
  , height
  , width
  , yOffset
  , setYOffset
  , focused
  , focus
  , blur
  , helpView
  )

-- M-WIDGETS S7: charmbracelet/bubbles' table, subset-ported over the Tea v2
-- loop — the LAST widget.  A fixed-width data table: a bold header row
-- (per-column title, width-clamped), a cursor-selected data row (bold fg 212),
-- and a Viewport (S4) that does the vertical scrolling.  `update` moves the
-- cursor + scrolls the viewport in parity with Go's MoveUp/MoveDown offset
-- logic.
--
-- Go parity notes (against table.go master):
--   * Column = {title, width}; Row = List String.  A column with width <= 0
--     renders NOTHING (skipped in both headersView and renderRow), matching
--     Go's `if col.Width <= 0 { continue }`.
--   * headersView: per column, a Width(w)+MaxWidth(w)+Inline(true) style
--     renders the title truncated to w cells with a "…" tail (x/ansi.Truncate
--     parity), then the Header style (bold + right-pad 1) wraps it; columns
--     join horizontally at Top.
--   * renderRow: the same per-cell sizing, wrapped in the Cell style
--     (right-pad 1); the row joins horizontally at Top; when r == cursor the
--     WHOLE joined row is wrapped in the Selected style (bold + fg 212,
--     ColorAnsi256 — no '#' prefix, the ListBox S6 lesson).
--   * update is model-only, gated on `focus` (a blurred table ignores every
--     key — Go's `if !m.focus { return m, nil }`).  The keymap switch ORDER
--     is Go's exact order: lineUp, lineDown, pageUp, pageDown, halfPageUp,
--     halfPageDown, gotoTop, gotoBottom.
--   * pageUp/pageDown move by viewport.Height(), half-page by Height()/2
--     (integer division).
--   * HelpView renders the keymap through Help (short = [lineUp, lineDown];
--     full = [[lineUp, lineDown, gotoTop, gotoBottom], [pageUp, pageDown,
--     halfPageUp, halfPageDown]]).
--
-- DEVIATIONS (all documented, none observable in the subset):
--   * Go renders only the 2*height window [cursor-h, cursor+h) of rows for
--     constant runtime; we render ALL rows into the viewport and scroll it
--     with an ABSOLUTE y offset.  Go's MoveUp/MoveDown clamp the viewport
--     offset against `start`/`end` (the window bounds) — those bounds are a
--     pure function of (cursor, height, rowCount), so they are re-derived
--     inline here (never stored) and the offset clamp is ported EXACTLY in
--     absolute terms (exhaustively verified against table.go MoveUp/MoveDown,
--     including the MoveDown asymmetry: it re-derives start/end BEFORE the
--     offset adjustment while MoveUp uses the OLD start, and the post-move
--     SetContent "GotoBottom" clamp).
--   * FromValues (string -> rows by separator) is omitted — the subset has no
--     String.split; callers build Row lists directly.
--   * the With* option variadics collapse into `new cols rows width height`
--     (ListBox's `new items width height` convention); WithHeight's
--     `h - headerHeight` subtraction happens inside `new`/`setHeight`.
--   * `focus` is False in `new` (Go's New leaves it zero too) — call `focus`
--     before driving keys.


{-| A table column: a header title and a fixed cell width (cells).
-}
type alias Column =
  { title : String
  , width : Int
  }


{-| One table row: a cell per column (Go `type Row []string`).
-}
type alias Row =
  List String


{-| The table keybindings (Go table.KeyMap).
-}
type alias KeyMap =
  { lineUp : Key.Binding
  , lineDown : Key.Binding
  , pageUp : Key.Binding
  , pageDown : Key.Binding
  , halfPageUp : Key.Binding
  , halfPageDown : Key.Binding
  , gotoTop : Key.Binding
  , gotoBottom : Key.Binding
  }


{-| The three render styles (Go table.Styles).
-}
type alias Styles =
  { header : Lipgloss.Style
  , cell : Lipgloss.Style
  , selected : Lipgloss.Style
  }


{-| The table state (Go table.Model, minus the dropped start/end window).
-}
type alias Model =
  { cols : List Column
  , rows : List Row
  , cursor : Int
  , focus : Bool
  , styles : Styles
  , keyMap : KeyMap
  , help : Help.Model
  , viewport : Viewport.Model
  }


{-| Go DefaultKeyMap.
-}
defaultKeyMap : KeyMap
defaultKeyMap =
  { lineUp = Key.newBinding [ "up", "k" ] "↑/k" "up"
  , lineDown = Key.newBinding [ "down", "j" ] "↓/j" "down"
  , pageUp = Key.newBinding [ "b", "pgup" ] "b/pgup" "page up"
  , pageDown = Key.newBinding [ "f", "pgdown", "space" ] "f/pgdn" "page down"
  , halfPageUp = Key.newBinding [ "u", "ctrl+u" ] "u" "½ page up"
  , halfPageDown = Key.newBinding [ "d", "ctrl+d" ] "d" "½ page down"
  , gotoTop = Key.newBinding [ "home", "g" ] "g/home" "go to start"
  , gotoBottom = Key.newBinding [ "end", "G" ] "G/end" "go to end"
  }


{-| Go DefaultStyles: Selected = bold + fg 212 (ANSI256), Header = bold +
Padding(0,1) (right pad 1), Cell = Padding(0,1) (right pad 1).
-}
defaultStyles : Styles
defaultStyles =
  { selected = Lipgloss.bold True (Lipgloss.foreground (Lipgloss.color "212") Lipgloss.newStyle)
  , header = Lipgloss.bold True (Lipgloss.paddingRight 1 Lipgloss.newStyle)
  , cell = Lipgloss.paddingRight 1 Lipgloss.newStyle
  }


{-| New(cols, rows, width, height): the viewport gets the content height
(height - headerHeight) exactly like Go's WithHeight, and the width directly
(Go WithWidth).
-}
new : List Column -> List Row -> Int -> Int -> Model
new cols rs w h =
  { cols = cols
  , rows = rs
  , cursor = 0
  , focus = False
  , styles = defaultStyles
  , keyMap = defaultKeyMap
  , help = Help.new
  , viewport = Viewport.init w (h - headerHeightOf cols)
  }


-- ---- sizing/scroll helpers (Go start/end re-derived inline) ----


{-| Go's `start = clamp(cursor - height, 0, cursor)`.
-}
startOf : Int -> Int -> Int
startOf cursor h =
  clamp 0 cursor (cursor - h)


{-| Go's `end = clamp(cursor + height, cursor, len(rows))`.
-}
endOf : Int -> Int -> Int -> Int
endOf cursor h rowsLen =
  clamp cursor rowsLen (cursor + h)


{-| The viewport maxYOffset for the rendered window: max(0, (end-start)-h).
-}
maxYOf : Int -> Int -> Int -> Int
maxYOf cursor h rowsLen =
  max 0 ((endOf cursor h rowsLen - startOf cursor h) - h)


{-| The window-relative offset of the current model (t - start).
-}
windowOffset : Model -> Int
windowOffset m =
  Viewport.yOffset m.viewport - startOf m.cursor (Viewport.height m.viewport)


{-| Re-derive the absolute offset after a non-move mutation (SetRows/SetCursor/
SetHeight): the window-relative offset is unchanged, then clamped by the
viewport's SetContent "GotoBottom" into the new maxYOffset.
-}
recomputeScroll : Model -> Model -> Model
recomputeScroll old new =
  let
    off =
      windowOffset old

    h =
      Viewport.height new.viewport

    c =
      new.cursor

    off2 =
      min off (maxYOf c h (length new.rows))

    t2 =
      startOf c h + off2

    vp =
      new.viewport
  in
  { new | viewport = { vp | yOffset = t2 } }


{-| Store an absolute top row directly (bypassing Viewport.setYOffset, which
clamps against the — possibly stale/empty — viewport content).
-}
setTop : Int -> Model -> Model
setTop t m =
  let
    vp =
      m.viewport
  in
  { m | viewport = { vp | yOffset = t } }


-- ---- state accessors ----


cursor : Model -> Int
cursor m =
  m.cursor


rows : Model -> List Row
rows m =
  m.rows


columns : Model -> List Column
columns m =
  m.cols


height : Model -> Int
height m =
  Viewport.height m.viewport


width : Model -> Int
width m =
  Viewport.width m.viewport


{-| The absolute scroll offset (the top visible row).  Go keeps a
window-relative offset internally; ours is absolute because we render all
rows — this getter/setter pair lets an app reconstruct the scroll state
exactly (no Go counterpart is needed for the window-relative form).
-}
yOffset : Model -> Int
yOffset m =
  Viewport.yOffset m.viewport


{-| Set the absolute scroll offset directly (the value should come from a
prior `yOffset` — no clamping, matching Viewport's raw field write).
-}
setYOffset : Int -> Model -> Model
setYOffset n m =
  setTop n m


focused : Model -> Bool
focused m =
  m.focus


{-| The selected row (Go SelectedRow: nil — here [] — when out of range).
-}
selectedRow : Model -> Row
selectedRow m =
  if m.cursor < 0 || m.cursor >= length m.rows then
    []

  else
    nthRow m.cursor m.rows


nthRow : Int -> List Row -> Row
nthRow i rs =
  case rs of
    [] ->
      []

    r :: rest ->
      if i == 0 then
        r

      else
        nthRow (i - 1) rest


-- ---- setters ----


setStyles : Styles -> Model -> Model
setStyles s m =
  { m | styles = s }


setColumns : List Column -> Model -> Model
setColumns c m =
  { m | cols = c }


setRows : List Row -> Model -> Model
setRows r m =
  let
    c2 =
      clamp 0 (length r - 1) m.cursor

    m1 =
      { m | rows = r, cursor = c2 }
  in
  recomputeScroll m m1


setWidth : Int -> Model -> Model
setWidth w m =
  { m | viewport = Viewport.setWidth w m.viewport }


setHeight : Int -> Model -> Model
setHeight h m =
  let
    vp =
      Viewport.setHeight (h - headerHeightOf m.cols) m.viewport

    m1 =
      { m | viewport = vp }
  in
  recomputeScroll m m1


setCursor : Int -> Model -> Model
setCursor n m =
  let
    c2 =
      clamp 0 (length m.rows - 1) n

    m1 =
      { m | cursor = c2 }
  in
  recomputeScroll m m1


focus : Model -> Model
focus m =
  { m | focus = True }


blur : Model -> Model
blur m =
  { m | focus = False }


-- ---- cursor movement (Go MoveUp/MoveDown/GotoTop/GotoBottom, absolute) ----


moveUp : Int -> Model -> Model
moveUp n m =
  let
    h =
      Viewport.height m.viewport

    len =
      length m.rows

    c2 =
      clamp 0 (len - 1) (m.cursor - n)

    sOld =
      startOf m.cursor h

    offset =
      windowOffset m

    off1 =
      if sOld == 0 then
        clamp 0 c2 offset

      else if sOld < h then
        clamp 0 h (clamp 0 c2 (offset + n))

      else if offset >= 1 then
        clamp 1 h (offset + n)

      else
        offset

    off2 =
      min off1 (maxYOf c2 h len)

    t2 =
      startOf c2 h + off2
  in
  setTop t2 { m | cursor = c2 }


moveDown : Int -> Model -> Model
moveDown n m =
  let
    h =
      Viewport.height m.viewport

    len =
      length m.rows

    c2 =
      clamp 0 (len - 1) (m.cursor + n)

    sOld =
      startOf m.cursor h

    yoffOld =
      windowOffset m

    sNew =
      startOf c2 h

    eNew =
      endOf c2 h len

    my =
      maxYOf c2 h len

    offset0 =
      min yoffOld my

    offset =
      if eNew == len && offset0 > 0 then
        clamp 1 h (offset0 - n)

      else if c2 > (eNew - sNew) // 2 && offset0 > 0 then
        clamp 1 c2 (offset0 - n)

      else if offset0 > 1 then
        offset0

      else if c2 > offset0 + h - 1 then
        clamp 0 1 (offset0 + 1)

      else
        offset0

    off2 =
      min offset my

    t2 =
      sNew + off2
  in
  setTop t2 { m | cursor = c2 }


gotoTop : Model -> Model
gotoTop m =
  moveUp m.cursor m


gotoBottom : Model -> Model
gotoBottom m =
  moveDown (length m.rows) m


-- ---- Tea surface ----


update : Runtime.Key -> Model -> Model
update key m =
  if not m.focus then
    m

  else
    let
      km =
        m.keyMap

      h =
        Viewport.height m.viewport
    in
    if Key.matches key [ km.lineUp ] then
      moveUp 1 m

    else if Key.matches key [ km.lineDown ] then
      moveDown 1 m

    else if Key.matches key [ km.pageUp ] then
      moveUp h m

    else if Key.matches key [ km.pageDown ] then
      moveDown h m

    else if Key.matches key [ km.halfPageUp ] then
      moveUp (h // 2) m

    else if Key.matches key [ km.halfPageDown ] then
      moveDown (h // 2) m

    else if Key.matches key [ km.gotoTop ] then
      gotoTop m

    else if Key.matches key [ km.gotoBottom ] then
      gotoBottom m

    else
      m


-- ---- rendering ----


{-| Go ansi.Truncate(s, w, "…"): unchanged when it fits, else the first w-1
cells + a "…" tail (the tail lives INSIDE the w-cell budget).
-}
truncateWith : Int -> String -> String
truncateWith w s =
  if Str.width s <= w then
    s

  else
    String.append (Str.truncate (w - 1) s) "…"


{-| The per-cell sizing style: Width(w) + MaxWidth(w) + Inline(true).
-}
sizedCellStyle : Int -> Lipgloss.Style
sizedCellStyle w =
  Lipgloss.inline True (Lipgloss.maxWidth w (Lipgloss.setWidth w Lipgloss.newStyle))


{-| Go headersView: per width>0 column, render the truncated title in the
sizing style, wrap it in the Header style, then JoinHorizontal(Top).
-}
headersView : Model -> String
headersView m =
  Lipgloss.joinHorizontal Lipgloss.PTop (headerCells m.cols m.styles.header)


headerCells : List Column -> Lipgloss.Style -> List String
headerCells cols headerStyle =
  case cols of
    [] ->
      []

    c :: rest ->
      if c.width <= 0 then
        headerCells rest headerStyle

      else
        let
          inner =
            Lipgloss.render (sizedCellStyle c.width) (truncateWith c.width c.title)

          rendered =
            Lipgloss.render headerStyle inner
        in
        rendered :: headerCells rest headerStyle


colWidth : Int -> List Column -> Int
colWidth i cols =
  case cols of
    [] ->
      0

    c :: rest ->
      if i == 0 then
        c.width

      else
        colWidth (i - 1) rest


{-| Go renderRow(r): each row cell (matched to its column by index) rendered in
the sizing style + Cell style, joined horizontally; the selected row is wrapped
whole in the Selected style.
-}
renderRow : Int -> Model -> String
renderRow r m =
  let
    cells =
      renderCells 0 (nthRow r m.rows) m.cols m.styles.cell

    joined =
      Lipgloss.joinHorizontal Lipgloss.PTop cells
  in
  if r == m.cursor then
    Lipgloss.render m.styles.selected joined

  else
    joined


renderCells : Int -> List String -> List Column -> Lipgloss.Style -> List String
renderCells i cells cols cellStyle =
  case cells of
    [] ->
      []

    value :: rest ->
      let
        w =
          colWidth i cols
      in
      if w <= 0 then
        renderCells (i + 1) rest cols cellStyle

      else
        let
          inner =
            Lipgloss.render (sizedCellStyle w) (truncateWith w value)

          rendered =
            Lipgloss.render cellStyle inner
        in
        rendered :: renderCells (i + 1) rest cols cellStyle


renderAllRows : Model -> List String
renderAllRows m =
  renderRowLoop 0 (length m.rows) m


renderRowLoop : Int -> Int -> Model -> List String
renderRowLoop i n m =
  if i >= n then
    []

  else
    renderRow i m :: renderRowLoop (i + 1) n m


{-| Go View: the header line, a newline, then the viewport (which shows the
height rows starting at the absolute y offset).
-}
view : Model -> String
view m =
  let
    content =
      Lipgloss.joinVertical Lipgloss.PLeft (renderAllRows m)

    vp =
      Viewport.setContent content m.viewport
  in
  String.append (headersView m) (String.append "\n" (Viewport.view vp))


-- ---- help ----


helpView : Model -> String
helpView m =
  Help.view m.help (shortHelp m) (fullHelp m)


shortHelp : Model -> List Key.Binding
shortHelp m =
  [ m.keyMap.lineUp, m.keyMap.lineDown ]


fullHelp : Model -> List (List Key.Binding)
fullHelp m =
  [ [ m.keyMap.lineUp, m.keyMap.lineDown, m.keyMap.gotoTop, m.keyMap.gotoBottom ]
  , [ m.keyMap.pageUp, m.keyMap.pageDown, m.keyMap.halfPageUp, m.keyMap.halfPageDown ]
  ]


-- ---- header height ----


{-| The header row height: 1 when any column has a positive width, else 0
(Go's lipgloss.Height(headersView) — a single line, or nothing).
-}
headerHeightOf : List Column -> Int
headerHeightOf cols =
  if anyRenderableCol cols then
    1

  else
    0


anyRenderableCol : List Column -> Bool
anyRenderableCol cols =
  case cols of
    [] ->
      False

    c :: rest ->
      if c.width > 0 then
        True

      else
        anyRenderableCol rest
