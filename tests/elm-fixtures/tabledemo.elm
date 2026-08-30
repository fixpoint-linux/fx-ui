module TableDemo exposing (main)

-- S7 (widget + demo): the Table widget driving a Tea v2 program, proven
-- end-to-end under a real pseudo-terminal by scripts/tabledemo.script.
--
-- The tea model is a SMALL record { cur, top } — the full Table.Model (10
-- rows + 3 columns + 3 Lipgloss styles + the 8-binding keymap + help +
-- viewport) exceeds the pty buffer, so elmvm's final-model print would
-- WouldBlock (the vpdemo/textareademo/listdemo workaround).  `mk` rebuilds
-- the widget transiently from the reduced model each event: the cursor AND
-- the ABSOLUTE scroll offset are both restored (setCursor alone would
-- re-derive the offset from scratch and lose the MoveDown/Up hysteresis), so
-- every key still exercises the REAL Table.update/view and the scroll state
-- carries across events exactly.
--
-- `view` renders a live "cur=<cursor>" header above the table so every
-- cursor state has a UNIQUE needle.  j/k move the cursor (j scrolls when the
-- cursor walks off the bottom visible row), G jumps to the last row (top =
-- rows-height), g back to the top.  q/ctrl+c quit via the TaskQuit scan.
--
-- PER THE STRATEGIST LESSON: `Table` is imported BARE (qualified-only) — the
-- demo defines its own local `update`/`view` for the Tea Config, so the
-- widget's same-named functions must NOT be imported bare.

import Str exposing (lines)
import Tea exposing (program, quit)
import Table


type alias Model =
  { cur : Int
  , top : Int
  }


type Msg
  = GotKey Runtime.Key
  | Noop


cols : List Table.Column
cols =
  [ { title = "Rank", width = 5 }
  , { title = "City", width = 8 }
  , { title = "Population", width = 8 }
  ]


rows : List Table.Row
rows =
  [ [ "1", "Tokyo", "37400068" ]
  , [ "2", "Delhi", "28514000" ]
  , [ "3", "Shanghai", "25582000" ]
  , [ "4", "Sao Paulo", "21650000" ]
  , [ "5", "Mexico City", "21581000" ]
  , [ "6", "Cairo", "20076000" ]
  , [ "7", "Mumbai", "19980000" ]
  , [ "8", "Beijing", "19618000" ]
  , [ "9", "Dhaka", "19578000" ]
  , [ "10", "Osaka", "19281000" ]
  ]


main =
  program
    { init = \_ -> ( { cur = 0, top = 0 }, Cmd.none )
    , update = update
    , view = view
    , resize = \cols_ rows_ m -> m
    , onKey = GotKey
    , onMouse = \_ -> Noop
    , mouse = MouseModeOff
    }


mk : Model -> Table.Model
mk m =
  Table.setYOffset m.top
    (Table.setCursor m.cur (Table.focus (Table.new cols rows 24 6)))


extract : Table.Model -> Model
extract tb =
  { cur = Table.cursor tb
  , top = Table.yOffset tb
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
          ( extract (Table.update key (mk m)), Cmd.none )

    Noop ->
      ( m, Cmd.none )


view m =
  let
    header =
      String.append "cur=" (String.fromInt m.cur)

    body =
      Table.view (mk m)
  in
  lines (String.append header (String.append "\n" body))
