module TodoApp exposing (main)

-- fx-ui example: a playable CLI todos app on the full widget stack — Tea v2
-- (program loop), ListBox (the filterable, paginated todo list), TextInput
-- (the add/filter prompt), Help (the bottom key bar), Lipgloss (the styled
-- header), and the host TaskReadFile/TaskWriteFile leaves for PERSISTENCE.
--
-- The todo list survives restarts: init reads todos.txt (one todo per line,
-- "[x] text" = done, "[ ] text" = not done) and every mutation (add / toggle
-- done / delete / clear done) rewrites it.  A missing file reads as "" and
-- parses to the empty list (TaskReadFile open-failure parity).
--
-- KEYMAP
--   enter          add the typed todo (prompt is always live at the bottom)
--   space / x      toggle done on the SELECTED todo
--   d / backspace  delete the selected todo (backspace edits the prompt while
--                  it is non-empty; on an empty prompt it deletes)
--   C              clear all done todos
--   /              enter filter mode (type a substring, enter applies,
--                  esc cancels and returns to the prompt)
--   ?              toggle the full help
--   up/down        move the cursor   (ListBox's j/k page-flip semantics)
--   pgup/pgdn      previous / next page
--   q / ctrl+c     quit; esc quits when no filter is active and clears an
--                  applied filter
--
-- Like listdemo, the tea model is a REDUCED record (the full ListBox.Model —
-- 12 Lipgloss styles + paginator + help + keymap — would overflow elmvm's
-- final-model print under the pty).  `mk` rebuilds the ListBox transiently
-- from {todos, idx, st, fv} each event, so every key still drives the REAL
-- ListBox.update/view.  `k` is a per-key counter that makes every frame's
-- header needle unique for the pty gate.
--
-- PER THE STRATEGIST LESSON: TextInput/ListBox/Help are imported QUALIFIED
-- (no bare exposing) because this module defines its own `update`/`view` for
-- the Tea Config — never import a widget's same-named functions bare.

import Str
import Tea exposing (program, quit)
import TextInput
import ListBox
import Help
import Key
import Lipgloss


{-| One todo.
-}
type alias Todo =
  { text : String
  , done : Bool
  }


{-| The reduced tea model (see header).  `st` is the ListBox filter state as
a string ("unf"/"flt"/"app"); `fv` the filter value; `idx` the ListBox global
index (into the VISIBLE list).
-}
type alias Model =
  { todos : List Todo
  , input : String
  , st : String
  , fv : String
  , idx : Int
  , help : Bool
  , k : Int
  , cols : Int
  , rows : Int
  }


type Msg
  = GotKey Runtime.Key
  | Loaded String
  | Saved
  | Noop


main =
  program
    { init = \_ -> ( initModel, Task.perform Loaded (Io.readFile "todos.txt") )
    , update = update
    , view = view
    , resize = applyResize
    , onKey = GotKey
    , onMouse = \_ -> Noop
    , mouse = MouseModeOff
    }


initModel : Model
initModel =
  { todos = []
  , input = ""
  , st = "unf"
  , fv = ""
  , idx = 0
  , help = False
  , k = 0
  , cols = 80
  , rows = 24
  }


-- The annotation is load-bearing (S2 lesson): a multi-field record update on
-- an unannotated base fails at the second written field, so the updating
-- function must pin the base record type first.
applyResize : Int -> Int -> Model -> Model
applyResize cols rows m =
  { m | cols = cols, rows = rows }


-- ====================== persistence ======================


{-| Write the current todos back to todos.txt (a plain TaskWriteFile).
-}
save : Model -> Runtime.Cmd Msg
save m =
  Task.perform (\_ -> Saved) (Io.writeFile "todos.txt" (serialize m.todos))


serialize : List Todo -> String
serialize todos =
  String.join "\n" (map serializeTodo todos)


serializeTodo : Todo -> String
serializeTodo t =
  String.append (if t.done then "[x] " else "[ ] ") t.text


{-| Parse a todos.txt back into a list; a blank line is skipped, a line
without a recognised marker is taken as an undone todo verbatim.
-}
parse : String -> List Todo
parse contents =
  map parseTodo (filter (\l -> not (l == "")) (Str.lines contents))


parseTodo : String -> Todo
parseTodo line =
  if Str.startsWith "[x] " line then
    { text = String.sliceLen 4 (String.length line - 4) line, done = True }

  else if Str.startsWith "[ ] " line then
    { text = String.sliceLen 4 (String.length line - 4) line, done = False }

  else
    { text = line, done = False }


-- ====================== the transient ListBox ======================


{-| The ListBox items for the current todos: title = text, description =
"done"/"" (so the filter can also match on done state).
-}
toItems : List Todo -> List ListBox.Item
toItems todos =
  map (\t -> { title = t.text, description = descOf t }) todos


descOf : Todo -> String
descOf t =
  if t.done then
    "done"

  else
    ""


ctorOf : String -> ListBox.FilterState
ctorOf s =
  if s == "flt" then
    ListBox.Filtering

  else if s == "app" then
    ListBox.FilterApplied

  else
    ListBox.Unfiltered


{-| Rebuild the ListBox from the reduced model.  The title/help are turned OFF
(this app renders its own header + help bar); status + pagination stay on so
the item count and page dots show.
-}
mk : Model -> ListBox.Model
mk m =
  let
    lb0 =
      ListBox.new (toItems m.todos) m.cols (listHeight m)

    lb1 =
      { lb0
        | showTitle = False
        , showHelp = False
        , itemNameSingular = "todo"
        , itemNamePlural = "todos"
      }
  in
  ListBox.setFilterState (ctorOf m.st) m.fv (ListBox.select m.idx lb1)


{-| Fold the reduced (idx, st, fv) back out of a ListBox into the model after
an update — the cursor/filter state the widget owns, re-clamped through its
own pagination.
-}
extract : Model -> ListBox.Model -> Model
extract m lb =
  { m
    | idx = ListBox.index lb
    , st =
        if ListBox.isFiltering lb then
          "flt"

        else if ListBox.isFilterApplied lb then
          "app"

        else
          "unf"
    , fv = ListBox.filterValue lb
  }


{-| Re-derive the clamped (idx, st, fv) after the todos list changed: a
deletion/toggle can shrink the visible list (or drop the selected item when a
filter is applied), so the cursor is re-clamped through a full mk/extract.
-}
reclamp : Model -> Model
reclamp m =
  extract m (mk m)


{-| The rows allotted to the ListBox: the terminal height minus the header,
the prompt and the short help bar.
-}
listHeight : Model -> Int
listHeight m =
  max 1 (m.rows - 3)


-- ====================== selection ======================


{-| The ListBox filter predicate (mirrors ListBox.filterItemsGo: substring on
title OR description, case-sensitive; empty value matches everything).
-}
matchesFilter : String -> Todo -> Bool
matchesFilter fv t =
  fv == "" || Str.contains fv t.text || Str.contains fv (descOf t)


{-| The index into `m.todos` the cursor is on, or -1 when nothing is selected.
The ListBox `index` is an index into the VISIBLE list, so it is walked back to
the original todo index through the same filter predicate.
-}
selectedTodoIndex : Model -> Int
selectedTodoIndex m =
  selectedGo m.todos m.fv m.idx 0


selectedGo : List Todo -> String -> Int -> Int -> Int
selectedGo todos fv want i =
  case todos of
    [] ->
      -1

    t :: rest ->
      if matchesFilter fv t then
        if want == 0 then
          i

        else
          selectedGo rest fv (want - 1) (i + 1)

      else
        selectedGo rest fv want (i + 1)


-- ====================== todo mutations ======================


toggleAt : Int -> List Todo -> List Todo
toggleAt i todos =
  toggleGo i todos []


toggleGo : Int -> List Todo -> List Todo -> List Todo
toggleGo i todos acc =
  case todos of
    [] ->
      reverse acc

    t :: rest ->
      if i == 0 then
        append (reverse acc) ({ t | done = not t.done } :: rest)

      else
        toggleGo (i - 1) rest (t :: acc)


removeAt : Int -> List Todo -> List Todo
removeAt i todos =
  removeGo i todos []


removeGo : Int -> List Todo -> List Todo -> List Todo
removeGo i todos acc =
  case todos of
    [] ->
      reverse acc

    t :: rest ->
      if i == 0 then
        append (reverse acc) rest

      else
        removeGo (i - 1) rest (t :: acc)


clearDone : List Todo -> List Todo
clearDone todos =
  filter (\t -> not t.done) todos


countDone : List Todo -> Int
countDone todos =
  countGo todos 0


countGo : List Todo -> Int -> Int
countGo todos acc =
  case todos of
    [] ->
      acc

    t :: rest ->
      countGo rest (if t.done then acc + 1 else acc)


-- ====================== update ======================


update : Msg -> Model -> ( Model, Runtime.Cmd Msg )
update msg m =
  case msg of
    Loaded contents ->
      ( { m | todos = parse contents }, Cmd.none )

    Saved ->
      ( m, Cmd.none )

    Noop ->
      ( m, Cmd.none )

    GotKey key ->
      step key { m | k = m.k + 1 }


step : Runtime.Key -> Model -> ( Model, Runtime.Cmd Msg )
step key m =
  case key of
    KeyCtrl "c" ->
      ( m, quit )

    _ ->
      if m.st == "flt" then
        -- Typing a filter: the ListBox owns the filter editor (chars append,
        -- backspace drops, enter accepts, esc cancels -> back to the prompt).
        ( extract m (ListBox.update key (mk m)), Cmd.none )

      else
        stepBrowse key m


{-| Dispatch in browse mode: while the add prompt has text, every key is TEXT
entry (so a todo like "buy milk" — spaces and all — types cleanly); with an
empty prompt, the command keys fire.  This is the empty-prompt rule documented
in the header.
-}
stepBrowse : Runtime.Key -> Model -> ( Model, Runtime.Cmd Msg )
stepBrowse key m =
  if m.input == "" then
    commandKey key m

  else
    typeKey key m


{-| Mid-typing: enter adds, esc quits, arrows still navigate, everything else
appends to the prompt (TextInput.update ignores the non-printable keys it does
not handle).
-}
typeKey : Runtime.Key -> Model -> ( Model, Runtime.Cmd Msg )
typeKey key m =
  case key of
    KeyEnter ->
      add m

    KeyEsc ->
      ( m, quit )

    KeyUp ->
      nav key m

    KeyDown ->
      nav key m

    KeyPgUp ->
      nav key m

    KeyPgDn ->
      nav key m

    KeyHome ->
      nav key m

    KeyEnd ->
      nav key m

    _ ->
      ( { m | input = TextInput.update key m.input }, Cmd.none )


{-| Empty prompt: the command keymap.  esc quits unless a filter is applied
(then it clears the filter); printable chars start the prompt.
-}
commandKey : Runtime.Key -> Model -> ( Model, Runtime.Cmd Msg )
commandKey key m =
  case key of
    KeyEsc ->
      if m.st == "app" then
        ( { m | st = "unf", fv = "", idx = 0 }, Cmd.none )

      else
        ( m, quit )

    KeyChar "q" ->
      ( m, quit )

    KeyChar "/" ->
      ( extract m (ListBox.update key (mk m)), Cmd.none )

    KeyChar "?" ->
      ( { m | help = not m.help }, Cmd.none )

    KeyChar "C" ->
      let
        m1 =
          reclamp { m | todos = clearDone m.todos }
      in
      ( m1, save m1 )

    KeyChar "x" ->
      toggle m

    KeyChar " " ->
      toggle m

    KeyChar "d" ->
      deleteSelected m

    KeyBackspace ->
      deleteSelected m

    KeyEnter ->
      add m

    KeyUp ->
      nav key m

    KeyDown ->
      nav key m

    KeyPgUp ->
      nav key m

    KeyPgDn ->
      nav key m

    KeyHome ->
      nav key m

    KeyEnd ->
      nav key m

    KeyChar c ->
      ( { m | input = TextInput.update key m.input }, Cmd.none )

    _ ->
      ( m, Cmd.none )


nav : Runtime.Key -> Model -> ( Model, Runtime.Cmd Msg )
nav key m =
  ( extract m (ListBox.update key (mk m)), Cmd.none )


toggle : Model -> ( Model, Runtime.Cmd Msg )
toggle m =
  let
    i =
      selectedTodoIndex m
  in
  if i < 0 then
    ( m, Cmd.none )

  else
    let
      m1 =
        reclamp { m | todos = toggleAt i m.todos }
    in
    ( m1, save m1 )


deleteSelected : Model -> ( Model, Runtime.Cmd Msg )
deleteSelected m =
  let
    i =
      selectedTodoIndex m
  in
  if i < 0 then
    ( m, Cmd.none )

  else
    let
      m1 =
        reclamp { m | todos = removeAt i m.todos }
    in
    ( m1, save m1 )


add : Model -> ( Model, Runtime.Cmd Msg )
add m =
  if m.input == "" then
    ( m, Cmd.none )

  else
    let
      m1 =
        reclamp { m | todos = append m.todos [ { text = m.input, done = False } ], input = "" }
    in
    ( m1, save m1 )


-- ====================== view ======================


view : Model -> List String
view m =
  let
    header =
      headerView m

    listRows =
      ListBox.view (mk m)

    prompt =
      promptView m

    helpRows =
      Str.lines (helpView m)
  in
  append (append [ header ] listRows) (append [ prompt ] helpRows)


titleStyle : Lipgloss.Style
titleStyle =
  Lipgloss.bold True
    (Lipgloss.foreground (Lipgloss.color "#89B4FA")
      (Lipgloss.paddingRight 1 (Lipgloss.paddingLeft 1 Lipgloss.newStyle))
    )


headerView : Model -> String
headerView m =
  String.append (Lipgloss.render titleStyle "Todos") (String.append "  " (stat m))


{-| The unique-per-key state needle the pty gate asserts on.
-}
stat : Model -> String
stat m =
  String.append "n="
    (String.append (String.fromInt (length m.todos))
      (String.append " d="
        (String.append (String.fromInt (countDone m.todos))
          (String.append " k=" (String.fromInt m.k))
        )
      )
    )


promptView : Model -> String
promptView m =
  let
    value =
      if m.st == "flt" then
        m.fv

      else
        m.input

    prefix =
      if m.st == "flt" then
        "filter: "

      else
        "add: "

    rows =
      TextInput.view value
  in
  String.append prefix (firstRow rows)


firstRow : List String -> String
firstRow rows =
  case rows of
    r :: _ ->
      r

    [] ->
      ""


-- ====================== help bar ======================


bAdd : Key.Binding
bAdd =
  Key.newBinding [ "enter" ] "enter" "add"


bToggle : Key.Binding
bToggle =
  Key.newBinding [ "space", "x" ] "space/x" "toggle"


bDelete : Key.Binding
bDelete =
  Key.newBinding [ "d", "backspace" ] "d" "delete"


bClear : Key.Binding
bClear =
  Key.newBinding [ "C" ] "C" "clear done"


bFilter : Key.Binding
bFilter =
  Key.newBinding [ "/" ] "/" "filter"


bHelp : Key.Binding
bHelp =
  Key.newBinding [ "?" ] "?" "help"


bUp : Key.Binding
bUp =
  Key.newBinding [ "up", "down" ] "up/dn" "move"


bPage : Key.Binding
bPage =
  Key.newBinding [ "pgup", "pgdn" ] "pgup/pgdn" "page"


bQuit : Key.Binding
bQuit =
  Key.newBinding [ "q", "ctrl+c", "esc" ] "q" "quit"


shortHelp : List Key.Binding
shortHelp =
  [ bAdd, bToggle, bDelete, bClear, bFilter, bHelp, bQuit ]


fullHelp : List (List Key.Binding)
fullHelp =
  [ [ bAdd, bToggle, bDelete, bClear ]
  , [ bFilter, bHelp, bUp, bPage ]
  , [ bQuit ]
  ]


helpView : Model -> String
helpView m =
  let
    h0 =
      Help.new

    h =
      { h0 | showAll = m.help, width = m.cols }
  in
  Help.view h shortHelp fullHelp
