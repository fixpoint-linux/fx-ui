module ListBox exposing
  ( Item
  , Model
  , FilterState(..)
  , KeyMap
  , Styles
  , new
  , update
  , view
  , cursor
  , page
  , index
  , filterState
  , filterValue
  , visibleCount
  , isFiltering
  , isFilterApplied
  , isUnfiltered
  , select
  , setFilterState
  )

-- M-WIDGETS S6: charmbracelet/bubbles' list, subset-ported over the Tea v2
-- loop.  The filterable, paginated list: a fixed DefaultDelegate (title +
-- description, no Item interface), filter-as-you-type (case-sensitive
-- substring over title OR description — no fuzzy, no matched-indexes), a
-- Paginator (dots), a Help footer, and the page-flip cursor logic that is the
-- subtlest part of the whole widget port (list.go:516-568 + updatePagination
-- 776-810, ported line-by-line).
--
-- Go parity notes (against list.go / defaultitem.go / keys.go / style.go
-- master):
--   * update dispatches on filterState: Filtering -> handleFiltering, else
--     handleBrowsing.  Both are model-only (the Go tea.Cmd returns are either
--     tea.Quit — handled by the APP, not the widget — or textinput.Blink /
--     status-message timers, both omitted).  quit/forceQuit therefore never
--     fire INSIDE the widget; the demo routes q/ctrl+c itself.
--   * handleBrowsing's switch ORDER is Go's: clearFilter, (quit), cursorUp,
--     cursorDown, prevPage, nextPage, goToStart, goToEnd, filter, then the
--     showFullHelp/closeFullHelp toggle.  clearFilter matches before quit
--     because both are esc by default (a filter-applied esc clears, not quits).
--   * CursorUp/CursorDown are the page-flip dance: decrement/increment first,
--     clamp to the current page's maxCursorIndex (= ItemsOnPage(visible)-1),
--     and only cross a page boundary when the cursor walks off the END of the
--     page — crossing back to the PREVIOUS page lands on that page's last
--     index, crossing FORWARD lands on 0.  At the first/last page the cursor
--     clamps in place.
--   * updatePagination keeps the selected item's INDEX stable across a
--     recomputation (filter shrink / size change): idx = page*perPage+cursor
--     is captured from the OLD perPage, then page/cursor are re-derived from
--     the NEW perPage, then the page is clamped into [0, totalPages-1].
--     perPage = max(1, availHeight/(itemHeight+spacing)) with the fixed
--     delegate height 2 / spacing 1, availHeight = height - the rendered
--     heights of title/status/pagination/help (each measured as lines of the
--     ACTUAL rendered view, Go lipgloss.Height parity).
--   * view = JoinVertical(Left, [title, status, content, pagination, help]);
--     content = populatedView rendered in a Height(availHeight) style (pads
--     the list body to fill the window).  An empty pagination (totalPages<2)
--     still contributes ONE blank row — Go JoinVertical does not skip "".
--   * statusView counts: "%d items" (singular when the visible count is 1),
--     "Nothing matched" while filtering to zero, "No items" when empty, a
--     leading "“<filter>” " (trimmed, truncated to 10 cells + "…") when a
--     filter is applied, and a " • N filtered" divider+counter suffix.
--   * the delegate render: truncate title/desc to width-2 cells (NormalTitle
--     padLeft 2); empty-filter dims everything; the selected item (only when
--     NOT Filtering) gets the left border + #EE6FF8/#AD58B4 palette; while
--     Filtering with a non-empty value every item renders NORMAL (the
--     selected style waits for the accept).
--   * updateKeybindings re-derives the enabled/disabled flags of all 14
--     bindings from state (Go mutates m.KeyMap in place; we rebuild the
--     record — the model's keyMap is always defaultKeyMap, no custom setter).
--
-- DEVIATIONS (all documented, none observable in the subset):
--   * no spinner, no status messages, no custom delegates, no infinite
--     scrolling, no sort; the filter is a plain String (filterValue) driven
--     through TextInput.update (KeyChar append / KeyBackspace drop, no cursor
--     movement), rendered as "Filter: <value>" + a steady block cursor.
--   * no fuzzy matching / matched-index highlight: filterItems keeps an item
--     iff Str.contains value title OR Str.contains value description
--     (case-sensitive), and the FilteredItem.index is the unfiltered index
--     (Go's itemsAsFilterItems zeroes it for the empty filter; unobservable —
--     GlobalIndex/SetItem are omitted).
--   * description is a SINGLE line (Go keeps only the first line for a
--     height-2 delegate); title/desc truncation uses Str.truncate + a manual
--     "…" tail (x/ansi.Truncate(s, w, "…") parity).
--   * ActivePaginationDot/InactivePaginationDot/DividerDot render their glyph
--     as the render() argument rather than SetString (byte-identical output,
--     avoids the value-prepend space).


{-| An item in the list (Go list.Item flattened to a fixed two-string
DefaultDelegate item — no Item interface).
-}
type alias Item =
  { title : String
  , description : String
  }


{-| Filter state (Go list.FilterState).
-}
type FilterState
  = Unfiltered
  | Filtering
  | FilterApplied


{-| A filtered item: its index in the UNFILTERED list + the item itself.
Go's filteredItem also carries fuzzy `matches`; we omit those (no fuzzy).
-}
type alias FilteredItem =
  { index : Int
  , item : Item
  }


{-| The 14 navigation/filter/help bindings (Go list.KeyMap).
-}
type alias KeyMap =
  { cursorUp : Key.Binding
  , cursorDown : Key.Binding
  , nextPage : Key.Binding
  , prevPage : Key.Binding
  , goToStart : Key.Binding
  , goToEnd : Key.Binding
  , filter : Key.Binding
  , clearFilter : Key.Binding
  , cancelWhileFiltering : Key.Binding
  , acceptWhileFiltering : Key.Binding
  , showFullHelp : Key.Binding
  , closeFullHelp : Key.Binding
  , quit : Key.Binding
  , forceQuit : Key.Binding
  }


{-| The 12 render styles (Go list.Styles, minus Spinner/Filter/active-filter/
match styles, all omitted with their features).
-}
type alias Styles =
  { titleBar : Lipgloss.Style
  , title : Lipgloss.Style
  , statusBar : Lipgloss.Style
  , statusEmpty : Lipgloss.Style
  , statusBarFilterCount : Lipgloss.Style
  , noItems : Lipgloss.Style
  , paginationStyle : Lipgloss.Style
  , helpStyle : Lipgloss.Style
  , activePaginationDot : Lipgloss.Style
  , inactivePaginationDot : Lipgloss.Style
  , arabicPagination : Lipgloss.Style
  , dividerDot : Lipgloss.Style
  }


{-| The list state (Go list.Model).
-}
type alias Model =
  { title : String
  , styles : Styles
  , keyMap : KeyMap
  , items : List Item
  , filteredItems : List FilteredItem
  , filterState : FilterState
  , cursor : Int
  , paginator : Paginator.Model
  , help : Help.Model
  , filterValue : String
  , width : Int
  , height : Int
  , showTitle : Bool
  , showFilter : Bool
  , showStatusBar : Bool
  , showPagination : Bool
  , showHelp : Bool
  , filteringEnabled : Bool
  , itemNameSingular : String
  , itemNamePlural : String
  }


-- ====================== defaults ======================


{-| DefaultKeyMap (Go keys.go:44-117).
-}
defaultKeyMap : KeyMap
defaultKeyMap =
  { cursorUp = Key.newBinding [ "up", "k" ] "↑/k" "up"
  , cursorDown = Key.newBinding [ "down", "j" ] "↓/j" "down"
  , prevPage = Key.newBinding [ "left", "h", "pgup", "b", "u" ] "←/h/pgup" "prev page"
  , nextPage = Key.newBinding [ "right", "l", "pgdown", "f", "d" ] "→/l/pgdn" "next page"
  , goToStart = Key.newBinding [ "home", "g" ] "g/home" "go to start"
  , goToEnd = Key.newBinding [ "end", "G" ] "G/end" "go to end"
  , filter = Key.newBinding [ "/" ] "/" "filter"
  , clearFilter = Key.newBinding [ "esc" ] "esc" "clear filter"
  , cancelWhileFiltering = Key.newBinding [ "esc" ] "esc" "cancel"
  , acceptWhileFiltering = Key.newBinding [ "enter", "tab", "shift+tab", "ctrl+k", "up", "ctrl+j", "down" ] "enter" "apply filter"
  , showFullHelp = Key.newBinding [ "?" ] "?" "more"
  , closeFullHelp = Key.newBinding [ "?" ] "?" "close help"
  , quit = Key.newBinding [ "q", "esc" ] "q" "quit"
  , forceQuit = Key.newBinding [ "ctrl+c" ] "" ""
  }


{-| DefaultStyles(dark) (Go style.go:44-78): the dark palette, minus the
omitted Spinner/Filter/DefaultFilterCharacterMatch/StatusBarActiveFilter.
-}
defaultStyles : Styles
defaultStyles =
  let
    verySubdued =
      Lipgloss.color "#3C3C3C"

    subdued =
      Lipgloss.color "#5C5C5C"
  in
  { titleBar =
      Lipgloss.paddingBottom 1 (Lipgloss.paddingLeft 2 Lipgloss.newStyle)
  , title =
      Lipgloss.background (Lipgloss.color "62")
        (Lipgloss.foreground (Lipgloss.color "230")
          (Lipgloss.paddingRight 1 (Lipgloss.paddingLeft 1 Lipgloss.newStyle)))
  , statusBar =
      Lipgloss.foreground (Lipgloss.color "#777777")
        (Lipgloss.paddingBottom 1 (Lipgloss.paddingLeft 2 Lipgloss.newStyle))
  , statusEmpty =
      Lipgloss.foreground subdued Lipgloss.newStyle
  , statusBarFilterCount =
      Lipgloss.foreground verySubdued Lipgloss.newStyle
  , noItems =
      Lipgloss.foreground (Lipgloss.color "#626262") Lipgloss.newStyle
  , paginationStyle =
      Lipgloss.paddingLeft 2 Lipgloss.newStyle
  , helpStyle =
      Lipgloss.paddingTop 1 (Lipgloss.paddingLeft 2 Lipgloss.newStyle)
  , activePaginationDot =
      Lipgloss.foreground (Lipgloss.color "#979797") Lipgloss.newStyle
  , inactivePaginationDot =
      Lipgloss.foreground verySubdued Lipgloss.newStyle
  , arabicPagination =
      Lipgloss.foreground subdued Lipgloss.newStyle
  , dividerDot =
      Lipgloss.foreground verySubdued Lipgloss.newStyle
  }


-- The fixed DefaultDelegate item styles (Go defaultitem.go
-- NewDefaultItemStyles(true)).  The delegate is NOT pluggable; these back
-- renderItem directly.
normalTitleStyle : Lipgloss.Style
normalTitleStyle =
  Lipgloss.foreground (Lipgloss.color "#dddddd") (Lipgloss.paddingLeft 2 Lipgloss.newStyle)


normalDescStyle : Lipgloss.Style
normalDescStyle =
  Lipgloss.foreground (Lipgloss.color "#777777") (Lipgloss.paddingLeft 2 Lipgloss.newStyle)


selectedTitleStyle : Lipgloss.Style
selectedTitleStyle =
  Lipgloss.borderLeftForeground (Lipgloss.color "#AD58B4")
    (Lipgloss.foreground (Lipgloss.color "#EE6FF8")
      (Lipgloss.paddingLeft 1
        (Lipgloss.borderLeft True (Lipgloss.borderStyle Lipgloss.normalBorder Lipgloss.newStyle))))


selectedDescStyle : Lipgloss.Style
selectedDescStyle =
  Lipgloss.borderLeftForeground (Lipgloss.color "#AD58B4")
    (Lipgloss.foreground (Lipgloss.color "#AD58B4")
      (Lipgloss.paddingLeft 1
        (Lipgloss.borderLeft True (Lipgloss.borderStyle Lipgloss.normalBorder Lipgloss.newStyle))))


dimmedTitleStyle : Lipgloss.Style
dimmedTitleStyle =
  Lipgloss.foreground (Lipgloss.color "#777777") (Lipgloss.paddingLeft 2 Lipgloss.newStyle)


dimmedDescStyle : Lipgloss.Style
dimmedDescStyle =
  Lipgloss.foreground (Lipgloss.color "#4D4D4D") (Lipgloss.paddingLeft 2 Lipgloss.newStyle)


{-| New with Go's defaults (Go list.go:184-235): Dots paginator pre-styled,
help width = list width, then updatePagination + updateKeybindings.
-}
new : List Item -> Int -> Int -> Model
new items width height =
  let
    styles =
      defaultStyles

    p0 =
      Paginator.new

    p =
      { p0
        | ptype = Paginator.Dots
        , activeDot = Lipgloss.render styles.activePaginationDot "•"
        , inactiveDot = Lipgloss.render styles.inactivePaginationDot "•"
      }

    m =
      { title = "List"
      , styles = styles
      , keyMap = defaultKeyMap
      , items = items
      , filteredItems = []
      , filterState = Unfiltered
      , cursor = 0
      , paginator = p
      , help = Help.setWidth width Help.new
      , filterValue = ""
      , width = width
      , height = height
      , showTitle = True
      , showFilter = True
      , showStatusBar = True
      , showPagination = True
      , showHelp = True
      , filteringEnabled = True
      , itemNameSingular = "item"
      , itemNamePlural = "items"
      }
  in
  updateKeybindings (updatePagination m)


-- ====================== accessors ======================


{-| The page-relative cursor.
-}
cursor : Model -> Int
cursor m =
  m.cursor


{-| The current page.
-}
page : Model -> Int
page m =
  m.paginator.page


{-| The global selected index in the VISIBLE list (Go Index()).
-}
index : Model -> Int
index m =
  m.paginator.page * m.paginator.perPage + m.cursor


{-| The filter state.
-}
filterState : Model -> FilterState
filterState m =
  m.filterState


{-| The current filter value.
-}
filterValue : Model -> String
filterValue m =
  m.filterValue


{-| The number of currently visible items.
-}
visibleCount : Model -> Int
visibleCount m =
  length (visibleItems m)


{-| Select the given global index (Go Select): page + cursor from the index.
-}
select : Int -> Model -> Model
select idx m =
  let
    p0 =
      m.paginator
  in
  { m
    | paginator = { p0 | page = idx // p0.perPage }
    , cursor = idx - (idx // p0.perPage) * p0.perPage
  }


{-| Restore an arbitrary filter state/value (used by the demo to rebuild a
transient widget from a reduced tea model; Go SetFilterState + SetFilterText).
-}
setFilterState : FilterState -> String -> Model -> Model
setFilterState st v m =
  case st of
    Unfiltered ->
      resetFiltering m

    Filtering ->
      updateKeybindings
        (updatePagination
          { m | filterState = Filtering, filterValue = v, filteredItems = filterItemsGo v m.items }
        )

    FilterApplied ->
      updateKeybindings
        (updatePagination
          { m | filterState = FilterApplied, filterValue = v, filteredItems = filterItemsGo v m.items }
        )


-- ====================== update ======================


{-| Dispatch on the filter state (Go list.go:840-846): Filtering routes to the
filter editor, everything else browses.
-}
update : Runtime.Key -> Model -> Model
update key m =
  case m.filterState of
    Filtering ->
      handleFiltering key m

    _ ->
      handleBrowsing key m


handleBrowsing : Runtime.Key -> Model -> Model
handleBrowsing key m =
  if Key.matches key [ m.keyMap.clearFilter ] then
    resetFiltering m

  else if Key.matches key [ m.keyMap.cursorUp ] then
    cursorUp m

  else if Key.matches key [ m.keyMap.cursorDown ] then
    cursorDown m

  else if Key.matches key [ m.keyMap.prevPage ] then
    -- Go flips the paginator RAW on the key path (list.go:872-875): the cursor
    -- is left untouched and may fall out of range on a partial last page.  The
    -- clamping prevPage/nextPage below mirror Go's Model.PrevPage/NextPage for
    -- app-facing callers only.
    { m | paginator = Paginator.prevPage m.paginator }

  else if Key.matches key [ m.keyMap.nextPage ] then
    { m | paginator = Paginator.nextPage m.paginator }

  else if Key.matches key [ m.keyMap.goToStart ] then
    goToStart m

  else if Key.matches key [ m.keyMap.goToEnd ] then
    goToEnd m

  else if Key.matches key [ m.keyMap.filter ] then
    startFiltering m

  else if Key.matches key [ m.keyMap.showFullHelp ] then
    toggleHelp m

  else
    m


handleFiltering : Runtime.Key -> Model -> Model
handleFiltering key m =
  let
    mKeys =
      if Key.matches key [ m.keyMap.cancelWhileFiltering ] then
        resetFiltering m

      else if Key.matches key [ m.keyMap.acceptWhileFiltering ] then
        acceptFilter m

      else
        m

    v1 =
      TextInput.update key mKeys.filterValue

    changed =
      v1 /= mKeys.filterValue

    mText =
      { mKeys | filterValue = v1 }

    mRefilter =
      if changed then
        { mText | filteredItems = filterItemsGo v1 mText.items }

      else
        mText

    mAccept =
      if changed then
        { mRefilter | keyMap = setEnabledOn (v1 /= "") mRefilter.keyMap.acceptWhileFiltering mRefilter.keyMap }

      else
        mRefilter
  in
  updatePagination mAccept


setEnabledOn : Bool -> Key.Binding -> KeyMap -> KeyMap
setEnabledOn on b km =
  { km | acceptWhileFiltering = Key.setEnabled on b }


-- ---- browsing navigation (list.go:516-588) ----


cursorUp : Model -> Model
cursorUp m =
  let
    c1 =
      m.cursor - 1
  in
  if c1 < 0 && Paginator.onFirstPage m.paginator then
    { m | cursor = 0 }

  else if c1 >= 0 then
    { m | cursor = c1 }

  else
    { m | paginator = Paginator.prevPage m.paginator, cursor = maxCursorIndex m }


cursorDown : Model -> Model
cursorDown m =
  let
    maxIdx =
      maxCursorIndex m

    c1 =
      m.cursor + 1
  in
  if c1 <= maxIdx then
    { m | cursor = c1 }

  else if not (Paginator.onLastPage m.paginator) then
    { m | paginator = Paginator.nextPage m.paginator, cursor = 0 }

  else
    { m | cursor = max 0 maxIdx }


prevPage : Model -> Model
prevPage m =
  let
    pag =
      Paginator.prevPage m.paginator

    m1 =
      { m | paginator = pag }
  in
  { m1 | cursor = clamp 0 (maxCursorIndex m1) m1.cursor }


nextPage : Model -> Model
nextPage m =
  let
    pag =
      Paginator.nextPage m.paginator

    m1 =
      { m | paginator = pag }
  in
  { m1 | cursor = clamp 0 (maxCursorIndex m1) m1.cursor }


goToStart : Model -> Model
goToStart m =
  let
    p0 =
      m.paginator
  in
  { m | paginator = { p0 | page = 0 }, cursor = 0 }


goToEnd : Model -> Model
goToEnd m =
  let
    p0 =
      m.paginator

    p1 =
      { p0 | page = max 0 (p0.totalPages - 1) }

    m1 =
      { m | paginator = p1 }
  in
  { m1 | cursor = maxCursorIndex m1 }


maxCursorIndex : Model -> Int
maxCursorIndex m =
  max 0 (Paginator.itemsOnPage m.paginator (length (visibleItems m)) - 1)


-- ---- filtering ----


startFiltering : Model -> Model
startFiltering m =
  let
    m1 =
      if m.filterValue == "" then
        { m | filteredItems = filterItemsGo "" m.items }

      else
        m

    m2 =
      goToStart m1
  in
  updateKeybindings { m2 | filterState = Filtering }


acceptFilter : Model -> Model
acceptFilter m =
  if isEmpty m.items then
    m

  else if isEmpty (visibleItems m) then
    resetFiltering m

  else
    let
      mApplied =
        updateKeybindings { m | filterState = FilterApplied }
    in
    if m.filterValue == "" then
      resetFiltering mApplied

    else
      mApplied


resetFiltering : Model -> Model
resetFiltering m =
  if isUnfiltered m then
    m

  else
    updateKeybindings
      (updatePagination { m | filterState = Unfiltered, filterValue = "", filteredItems = [] })


toggleHelp : Model -> Model
toggleHelp m =
  let
    h =
      m.help
  in
  updatePagination { m | help = { h | showAll = not h.showAll } }


-- ---- keymap state ----


updateKeybindings : Model -> Model
updateKeybindings m =
  { m | keyMap = keymapForState m }


keymapForState : Model -> KeyMap
keymapForState m =
  case m.filterState of
    Filtering ->
      let
        km =
          m.keyMap
      in
      { km
        | cursorUp = Key.setEnabled False km.cursorUp
        , cursorDown = Key.setEnabled False km.cursorDown
        , nextPage = Key.setEnabled False km.nextPage
        , prevPage = Key.setEnabled False km.prevPage
        , goToStart = Key.setEnabled False km.goToStart
        , goToEnd = Key.setEnabled False km.goToEnd
        , filter = Key.setEnabled False km.filter
        , clearFilter = Key.setEnabled False km.clearFilter
        , cancelWhileFiltering = Key.setEnabled True km.cancelWhileFiltering
        , acceptWhileFiltering = Key.setEnabled (m.filterValue /= "") km.acceptWhileFiltering
        , quit = Key.setEnabled False km.quit
        , showFullHelp = Key.setEnabled False km.showFullHelp
        , closeFullHelp = Key.setEnabled False km.closeFullHelp
      }

    _ ->
      let
        km =
          m.keyMap

        hasItems =
          not (isEmpty m.items)

        hasPages =
          m.paginator.totalPages > 1

        minHelp =
          countEnabledBindings (fullHelp m) > 1
      in
      { km
        | cursorUp = Key.setEnabled hasItems km.cursorUp
        , cursorDown = Key.setEnabled hasItems km.cursorDown
        , nextPage = Key.setEnabled hasPages km.nextPage
        , prevPage = Key.setEnabled hasPages km.prevPage
        , goToStart = Key.setEnabled hasItems km.goToStart
        , goToEnd = Key.setEnabled hasItems km.goToEnd
        , filter = Key.setEnabled (m.filteringEnabled && hasItems) km.filter
        , clearFilter = Key.setEnabled (isFilterApplied m) km.clearFilter
        , cancelWhileFiltering = Key.setEnabled False km.cancelWhileFiltering
        , acceptWhileFiltering = Key.setEnabled False km.acceptWhileFiltering
        , quit = km.quit
        , showFullHelp = Key.setEnabled minHelp km.showFullHelp
        , closeFullHelp = Key.setEnabled minHelp km.closeFullHelp
      }


-- ---- pagination ----


updatePagination : Model -> Model
updatePagination m =
  let
    idx =
      m.paginator.page * m.paginator.perPage + m.cursor

    perPage =
      max 1 (availHeightOf m // 3)

    visCount =
      length (visibleItems m)

    p0 =
      m.paginator

    pag1 =
      { p0 | perPage = perPage }

    pag2 =
      if visCount < 1 then
        Paginator.setTotalPages 1 pag1

      else
        Paginator.setTotalPages visCount pag1

    newPage =
      idx // perPage

    newCursor =
      idx - newPage * perPage

    pageClamped =
      if newPage >= pag2.totalPages - 1 then
        max 0 (pag2.totalPages - 1)

      else
        newPage
  in
  { m | paginator = { pag2 | page = pageClamped }, cursor = newCursor }


-- ====================== view ======================


{-| View (Go list.go:1042-1084): title + status + content (height-padded) +
pagination + help, joined vertically at the left, split into rows.
-}
view : Model -> List String
view m =
  let
    av =
      availHeightOf m

    titleSections =
      if m.showTitle || (m.showFilter && m.filteringEnabled) then
        [ titleView m ]

      else
        []

    statusSections =
      if m.showStatusBar then
        append titleSections [ statusView m ]

      else
        titleSections

    content =
      Lipgloss.render (Lipgloss.setHeight av Lipgloss.newStyle) (populatedView m)

    withContent =
      append statusSections [ content ]

    withPagination =
      if m.showPagination then
        append withContent [ paginationView m ]

      else
        withContent

    final =
      if m.showHelp then
        append withPagination [ helpView m ]

      else
        withPagination
  in
  Str.lines (Lipgloss.joinVertical Lipgloss.PLeft final)


{-| The rows left for the list body (Go updatePagination/View's availHeight):
height minus the RENDERED heights of title/status/pagination/help.
-}
availHeightOf : Model -> Int
availHeightOf m =
  m.height
    - (if m.showTitle || (m.showFilter && m.filteringEnabled) then
        Lipgloss.height (titleView m)

      else
        0
      )
    - (if m.showStatusBar then
        Lipgloss.height (statusView m)

      else
        0
      )
    - (if m.showPagination then
        Lipgloss.height (paginationView m)

      else
        0
      )
    - (if m.showHelp then
        Lipgloss.height (helpView m)

      else
        0
      )


titleView : Model -> String
titleView m =
  let
    content =
      if m.showFilter && isFiltering m then
        filterLine m

      else if m.showTitle then
        let
          base =
            Lipgloss.render m.styles.title m.title
        in
        if isFiltering m then
          base

        else
          truncateTail (String.append base "  ") m.width

      else
        ""
  in
  if content == "" then
    ""

  else
    Lipgloss.render m.styles.titleBar content


filterLine : Model -> String
filterLine m =
  String.append "Filter: " (String.append m.filterValue "\u{1B}[7m \u{1B}[0m")


statusView : Model -> String
statusView m =
  let
    totalItems =
      length m.items

    visCount =
      length (visibleItems m)

    itemName =
      if visCount /= 1 then
        m.itemNamePlural

      else
        m.itemNameSingular

    itemsDisplay =
      String.append (String.fromInt visCount) (String.append " " itemName)

    status =
      if isFiltering m then
        if visCount == 0 then
          Lipgloss.render m.styles.statusEmpty "Nothing matched"

        else
          itemsDisplay

      else if isEmpty m.items then
        Lipgloss.render m.styles.statusEmpty (String.append "No " m.itemNamePlural)

      else
        let
          base =
            if isFilterApplied m then
              let
                f =
                  truncateTail (Str.trim m.filterValue) 10
              in
              String.append "“" (String.append f (String.append "” " itemsDisplay))

            else
              itemsDisplay
        in
        base

    numFiltered =
      totalItems - visCount

    status2 =
      if numFiltered > 0 then
        String.append status
          (String.append (Lipgloss.render m.styles.dividerDot " • ")
            (Lipgloss.render m.styles.statusBarFilterCount
              (String.append (String.fromInt numFiltered) " filtered")
            )
          )

      else
        status
  in
  Lipgloss.render m.styles.statusBar status2


paginationView : Model -> String
paginationView m =
  if m.paginator.totalPages < 2 then
    ""

  else
    let
      s =
        Paginator.view m.paginator

      s2 =
        if Str.width s > m.width then
          Lipgloss.render m.styles.arabicPagination (Paginator.arabicView m.paginator)

        else
          s
    in
    Lipgloss.render m.styles.paginationStyle s2


populatedView : Model -> String
populatedView m =
  let
    vis =
      visibleItems m
  in
  if isEmpty vis then
    if isFiltering m then
      ""

    else
      Lipgloss.render m.styles.noItems (String.append "No " (String.append m.itemNamePlural "."))

  else
    let
      bounds =
        Paginator.getSliceBounds m.paginator (length vis)

      start =
        Tuple.first bounds

      end =
        Tuple.second bounds

      docs =
        slice start end vis
    in
    String.append (renderItems m start docs) (tailPadding m vis)


renderItems : Model -> Int -> List Item -> String
renderItems m gi items =
  case items of
    [] ->
      ""

    it :: rest ->
      if isEmpty rest then
        renderItem m gi it

      else
        String.append (renderItem m gi it)
          (String.append "\n\n" (renderItems m (gi + 1) rest))


renderItem : Model -> Int -> Item -> String
renderItem m gi item =
  let
    textwidth =
      m.width - 2

    isSelected =
      gi == index m

    emptyFilter =
      isFiltering m && m.filterValue == ""

    title0 =
      truncateTail item.title textwidth

    desc0 =
      truncateTail item.description textwidth

    title =
      if emptyFilter then
        Lipgloss.render dimmedTitleStyle title0

      else if isSelected && not (isFiltering m) then
        Lipgloss.render selectedTitleStyle title0

      else
        Lipgloss.render normalTitleStyle title0

    desc =
      if emptyFilter then
        Lipgloss.render dimmedDescStyle desc0

      else if isSelected && not (isFiltering m) then
        Lipgloss.render selectedDescStyle desc0

      else
        Lipgloss.render normalDescStyle desc0
  in
  String.append title (String.append "\n" desc)


tailPadding : Model -> List Item -> String
tailPadding m vis =
  let
    onPage =
      Paginator.itemsOnPage m.paginator (length vis)
  in
  if onPage < m.paginator.perPage then
    Str.repeat ((m.paginator.perPage - onPage) * 3) "\n"

  else
    ""


helpView : Model -> String
helpView m =
  Lipgloss.render m.styles.helpStyle (Help.view m.help (shortHelp m) (fullHelp m))


shortHelp : Model -> List Key.Binding
shortHelp m =
  let
    km =
      m.keyMap
  in
  [ km.cursorUp
  , km.cursorDown
  , km.filter
  , km.clearFilter
  , km.acceptWhileFiltering
  , km.cancelWhileFiltering
  , km.quit
  , km.showFullHelp
  ]


fullHelp : Model -> List (List Key.Binding)
fullHelp m =
  let
    km =
      m.keyMap
  in
  [ [ km.cursorUp, km.cursorDown, km.nextPage, km.prevPage, km.goToStart, km.goToEnd ]
  , [ km.filter, km.clearFilter, km.acceptWhileFiltering, km.cancelWhileFiltering ]
  , [ km.quit, km.closeFullHelp ]
  ]


countEnabledBindings : List (List Key.Binding) -> Int
countEnabledBindings groups =
  countEnabledLoop groups 0


countEnabledLoop : List (List Key.Binding) -> Int -> Int
countEnabledLoop groups acc =
  case groups of
    [] ->
      acc

    g :: rest ->
      countEnabledLoop rest (acc + countEnabledGroup g)


countEnabledGroup : List Key.Binding -> Int
countEnabledGroup g =
  case g of
    [] ->
      0

    kb :: rest ->
      if Key.enabled kb then
        1 + countEnabledGroup rest

      else
        countEnabledGroup rest


-- ====================== shared helpers ======================


{-| The visible item list: the raw items when unfiltered, the filtered items
otherwise (Go VisibleItems).
-}
visibleItems : Model -> List Item
visibleItems m =
  case m.filterState of
    Unfiltered ->
      m.items

    _ ->
      map (\fi -> fi.item) m.filteredItems


{-| Filter items: keep those whose title OR description contains the value
(case-sensitive substring).  An empty value matches everything.
-}
filterItemsGo : String -> List Item -> List FilteredItem
filterItemsGo value items =
  filterItemsLoop value items 0 []


filterItemsLoop : String -> List Item -> Int -> List FilteredItem -> List FilteredItem
filterItemsLoop value items i acc =
  case items of
    [] ->
      reverse acc

    it :: rest ->
      if value == "" || Str.contains value it.title || Str.contains value it.description then
        filterItemsLoop value rest (i + 1) ({ index = i, item = it } :: acc)

      else
        filterItemsLoop value rest (i + 1) acc


{-| The [start, end) window of a list (Go items[start:end]).
-}
slice : Int -> Int -> List Item -> List Item
slice start end items =
  take (end - start) (drop start items)


{-| Truncate to `w` cells with an ellipsis tail (x/ansi.Truncate(s, w, "…")
parity: content fits -> unchanged, else keep w-1 cells + "…").
-}
truncateTail : String -> Int -> String
truncateTail s w =
  if Str.width s <= w then
    s

  else
    String.append (Str.truncate (w - 1) s) "…"


isFiltering : Model -> Bool
isFiltering m =
  case m.filterState of
    Filtering ->
      True

    _ ->
      False


isFilterApplied : Model -> Bool
isFilterApplied m =
  case m.filterState of
    FilterApplied ->
      True

    _ ->
      False


isUnfiltered : Model -> Bool
isUnfiltered m =
  case m.filterState of
    Unfiltered ->
      True

    _ ->
      False
