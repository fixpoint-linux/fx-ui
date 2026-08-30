module ListDemo exposing (main)

-- S6 (widget + demo): the ListBox widget driving a Tea v2 program, proven
-- end-to-end under a real pseudo-terminal by scripts/listdemo.script.
--
-- The tea model is a SMALL record { idx, st, fv } — the full ListBox.Model
-- (12 items + filteredItems + paginator + help + 12 Lipgloss styles + the
-- 14-binding keymap) exceeds the pty buffer, so elmvm's final-model print
-- would WouldBlock (same workaround as vpdemo/textareademo).  `mk` rebuilds
-- the widget transiently from the reduced model each event (fixed 40x19,
-- perPage 4, 3 pages), so every key still exercises the REAL ListBox.update/
-- view but the tea model stays three cheap fields.
--
-- `view` renders a live "i=<idx> st=<st> v=<fv>" header above the list so
-- every cursor/filter state has a UNIQUE needle.  j/k move the cursor (j
-- crosses the page boundary from index 3 -> 4), "/" enters filtering, the
-- filter value is typed live ("es" shrinks 12 -> 6 items), esc clears the
-- filter, enter accepts it (FilterApplied).  q/ctrl+c quit via the TaskQuit
-- scan; esc is routed to the list (clearFilter), NOT to quit.
--
-- PER THE STRATEGIST LESSON: `ListBox` is imported BARE (qualified-only) —
-- the demo defines its own local `update`/`view` for the Tea Config, so the
-- widget's same-named functions must NOT be imported bare.

import Str exposing (lines)
import Tea exposing (program, quit)
import ListBox


type alias Model =
  { idx : Int
  , st : String
  , fv : String
  }


type Msg
  = GotKey Runtime.Key
  | Noop


items : List ListBox.Item
items =
  [ { title = "Item 00", description = "west" }
  , { title = "Item 01", description = "north" }
  , { title = "Item 02", description = "test" }
  , { title = "Item 03", description = "south" }
  , { title = "Item 04", description = "rest" }
  , { title = "Item 05", description = "apple" }
  , { title = "Item 06", description = "best" }
  , { title = "Item 07", description = "kiwi" }
  , { title = "Item 08", description = "chest" }
  , { title = "Item 09", description = "lemon" }
  , { title = "Item 10", description = "guest" }
  , { title = "Item 11", description = "grape" }
  ]


main =
  program
    { init = \_ -> ( { idx = 0, st = "unf", fv = "" }, Cmd.none )
    , update = update
    , view = view
    , resize = \cols rows m -> m
    , onKey = GotKey
    , onMouse = \_ -> Noop
    , mouse = MouseModeOff
    }


ctorOf : String -> ListBox.FilterState
ctorOf s =
  if s == "flt" then
    ListBox.Filtering

  else if s == "app" then
    ListBox.FilterApplied

  else
    ListBox.Unfiltered


mk : Model -> ListBox.Model
mk m =
  ListBox.setFilterState (ctorOf m.st) m.fv
    (ListBox.select m.idx (ListBox.new items 40 19))


extract : ListBox.Model -> Model
extract lb =
  { idx = ListBox.index lb
  , st =
      if ListBox.isFiltering lb then
        "flt"

      else if ListBox.isFilterApplied lb then
        "app"

      else
        "unf"
  , fv = ListBox.filterValue lb
  }


update msg m =
  case msg of
    GotKey key ->
      case key of
        KeyChar "q" ->
          ( m, quit )

        KeyCtrl "c" ->
          ( m, quit )

        _ ->
          ( extract (ListBox.update key (mk m)), Cmd.none )

    Noop ->
      ( m, Cmd.none )


view m =
  let
    lb =
      mk m

    header =
      String.append "i="
        (String.append (String.fromInt m.idx)
          (String.append " st="
            (String.append m.st
              (String.append " v=" m.fv)
            )
          )
        )

    body =
      String.join "\n" (ListBox.view lb)
  in
  lines (String.append header (String.append "\n" body))
