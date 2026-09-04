module FilePickerDemo exposing (main)

-- S11 (widget + demo): the FilePicker widget driving a Tea v2 program,
-- proven end-to-end under a real pseudo-terminal by
-- scripts/filepickerdemo.script — the ONLY widget of the four whose listings
-- ride the host (Io.listDir + Io.stat through the module's own readDirCmd).
--
-- The tea model carries only DETERMINISTIC scalars-plus-data (dir / files /
-- sel / stack / path + a press counter): the full FilePicker.Model holds
-- Lipgloss styles and Key bindings (lambdas — pointer-y in elmvm's
-- final-model print), so the picker is REBUILT transiently from those fields
-- each event via a full record literal (the treedemo scalar-model lesson;
-- `files` itself is safe — a small list of int/string/bool records).
--
-- The view renders a live "#<presses> dir=<last segment> n=<count>
-- sel=<name|-> pick=<0|1>" header above the widget rows: the counter makes
-- every frame's needle UNIQUE forever (an expect needle that ever occurred
-- before stale-matches instantly), and the header pins the async state that
-- the widget rows alone can't show — the STALE-files frames after l/h (the
-- listing arrives one message later) and the sticky pick.
--
-- Coverage: the init listing round trip, j/j/G/k/g walks with BOTH clamps
-- (G at the last row, k at the top), enter on a FILE records the path
-- (enter matches open AND select) and the pick survives g/l/h, l descends
-- into gamma (push + re-list -> the hidden .keep filters to n=0/Bummer),
-- h pops the stack and re-lists the parent (restoration), q quits via the
-- TaskQuit scan.

import FilePicker
import Str
import Tea exposing (program, quit)
import Tuple


fxdir : String
fxdir =
  "tests/elm-fixtures/input/dirlist"


type alias Model =
  { cnt : Int
  , dir : String
  , files : List FilePicker.Entry
  , sel : Int
  , stack : List ( Int, Int, Int )
  , path : String
  }


type Msg
  = FPMsg FilePicker.Msg
  | GotKey Runtime.Key
  | Noop


main =
  program
    { init = init
    , update = update
    , view = view
    , resize = \_ _ m -> m
    , onKey = GotKey
    , onMouse = \_ -> Noop
    , mouse = MouseModeOff
    }


init : () -> ( Model, Runtime.Cmd Msg )
init _ =
  let
    m0 =
      { cnt = 0
      , dir = fxdir
      , files = []
      , sel = 0
      , stack = []
      , path = ""
      }
  in
  ( m0, FilePicker.initCmd FPMsg (rebuild m0) )


{-| The transient picker: Go New defaults + the model's carried state, at a
fixed 10-row window (the pty never resizes in this demo; resize is pinned by
the unit row instead).
-}
rebuild : Model -> FilePicker.Model
rebuild m =
  { id = 0
  , path = m.path
  , currentDirectory = m.dir
  , allowedTypes = []
  , keyMap = FilePicker.defaultKeyMap
  , files = m.files
  , showPermissions = True
  , showSize = True
  , showHidden = False
  , dirAllowed = False
  , fileAllowed = True
  , fileSelected = ""
  , selected = m.sel
  , stack = m.stack
  , minIdx = 0
  , maxIdx = 9
  , height = 10
  , autoHeight = False
  , cursor = ">"
  , styles = FilePicker.defaultStyles
  }


update : Msg -> Model -> ( Model, Runtime.Cmd Msg )
update msg model =
  case msg of
    FPMsg fmsg ->
      let
        pair =
          FilePicker.step FPMsg fmsg (rebuild model)

        m1 =
          Tuple.first pair
      in
      ( { model
          | dir = m1.currentDirectory
          , files = m1.files
          , sel = m1.selected
          , stack = m1.stack
          , path = m1.path
        }
      , Tuple.second pair
      )

    GotKey key ->
      case key of
        KeyChar "q" ->
          ( model, quit )

        KeyCtrl "c" ->
          ( model, quit )

        KeyEsc ->
          ( model, quit )

        _ ->
          let
            pair =
              FilePicker.update FPMsg key (rebuild model)

            m1 =
              Tuple.first pair
          in
          ( { model
              | cnt = model.cnt + 1
              , dir = m1.currentDirectory
              , files = m1.files
              , sel = m1.selected
              , stack = m1.stack
              , path = m1.path
            }
          , Tuple.second pair
          )

    Noop ->
      ( model, Cmd.none )


lastSeg : String -> String
lastSeg dir =
  case reverse (Str.split "/" dir) of
    s :: _ ->
      s

    [] ->
      "?"


selName : Model -> String
selName model =
  case drop model.sel model.files of
    e :: _ ->
      e.name

    [] ->
      "-"


view : Model -> List String
view model =
  let
    header =
      String.append
        ("#"
          ++ String.fromInt model.cnt
          ++ " dir="
          ++ lastSeg model.dir
          ++ " n="
          ++ String.fromInt (length model.files)
          ++ " sel="
          ++ selName model
          ++ " pick="
        )
        (if model.path == "" then
          "0"

         else
          "1"
        )
  in
  header :: Str.lines (FilePicker.view (rebuild model))
