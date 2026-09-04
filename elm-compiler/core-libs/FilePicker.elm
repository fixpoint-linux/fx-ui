module FilePicker
  exposing
    ( Entry
    , KeyMap
    , Model
    , Msg (..)
    , Styles
    , defaultKeyMap
    , defaultStyles
    , didSelectDisabledFile
    , didSelectFile
    , highlightedPath
    , initCmd
    , joinPath
    , new
    , parentDir
    , permOf
    , plainStyles
    , canSelect
    , readDirCmd
    , resize
    , setHeight
    , sortEntries
    , step
    , update
    , view
    )

import Key
import Lipgloss
import Str


-- S11 bubbles filepicker widget (charm.land/bubbles/v2 filepicker, subset-
-- ported over the Tea v2 loop) — the only RUNTIME-DEPENDENT widget of the
-- four: directory listings arrive through the host (Io.listDir = openat
-- O_DIRECTORY + getdents64, Io.stat = fstatat, both proven by dirunit/
-- statunit; the sync Runtime-worker no-ops are NOT what a Program sees).
-- Like Timer/Stopwatch, the app-facing shape is the Cmd-returning one:
--   * `update : (Msg -> msg) -> Runtime.Key -> Model -> (Model, Cmd msg)` is
--     Go Update's KeyPressMsg switch wholesale — Go returns m.readDir(...) as
--     the Back/Open-into-directory Cmd, so the key handler takes an
--     `inject : Msg -> msg` and performs the listing through the CALLER's
--     Msg (GotDir lands back in the app's update, which routes it into
--     `step`);
--   * `step : (Msg -> msg) -> Msg -> Model -> (Model, Cmd msg)` is Go Update
--     wholesale: the readDirMsg branch (id-routed files+maxIdx fold) plus key
--     routing into `update`.  Apps never pattern-match Msg (cross-module ctor
--     patterns are rejected) — they call `step FilePickerMsg msg fp`.
--   * `resize : Int -> Int -> Model -> Model` replaces Go's WindowSizeMsg
--     branch (Tea delivers terminal sizes through its resize hook): the
--     AutoHeight SetHeight(rows - marginBottom) + the unconditional
--     maxIdx = bottomIdx(minIdx) recompute, verbatim.
--
-- Go parity notes (against filepicker.go master):
--   * the three closure-stacks (selectedStack/minStack/maxStack) collapse
--     into ONE `stack : List (Int, Int, Int)` of (selected, minIdx, maxIdx)
--     triples, head = top (they are only ever pushed/popped together; Back's
--     guard is Go's selectedStack.Length() > 0 = the list being non-empty);
--   * the package-global atomic `lastID` is gone: `id` is an app-owned model
--     field defaulting to 0 (Timer precedent); GotDir is id-routed exactly
--     like Go's readDirMsg (which only ever filters OTHER instances);
--   * DefaultKeyMap/DefaultStyles are VALUES (`defaultKeyMap`/`defaultStyles`
--     — Key.newBinding takes plain args, Tree precedent); KeyMap/Styles field
--     names are the lowercased Go names.
--
-- Subset deviations from Go, all forced by the runtime surface:
--   * NO symlink detection: the getdents64 record carries no LNK bit, so
--     there is no Symlink style and no " → target" suffix, and Open/
--     didSelectFile skip Go's EvalSymlinks+os.Stat re-check.  Entry.isDir is
--     the STAT's isDir (fstatat FOLLOWS symlinks), so a link-to-dir still
--     opens as a directory (Go's EvalSymlinks outcome) at the cost of two
--     hairline divergences: it SORTS as a directory (Go sorts by dirent
--     type) and paints with the Directory style (Go: Symlink); a dangling
--     link renders as a plain 0-byte file with mode 0.
--   * size column = RAW bytes right-aligned in 7 (`String.fromInt`), NOT
--     humanize.Bytes — the SI suffixes need float math.
--   * permissions = the 10-char "-rwxrwxrwx" shape derived from the mode int
--     via Bitwise.and ('d' for S_IFDIR, '-' otherwise; Go's setuid/setgid/
--     sticky 'u'/'g'/'t' replacements and the special-type chars are out).
--   * a failed per-entry stat completes the ZERO record (host contract), and
--     the row is KEPT — Go `continue`s rows whose f.Info() fails in View and
--     `break`s Open on the same condition; we cannot observe the failure.
--   * a `selected` left out-of-range by a shrunk listing no-ops (Go would
--     index-panic); entryAt returns Nothing and the key is ignored.
--   * `FileSelected` is kept for surface parity — dead in Go too (written by
--     nothing in filepicker.go).
--   * EmptyDirectory drops SetString: the View renders the literal through
--     the style (byte-identical; our render PREPENDS a style's value, so a
--     baked value would grow a trailing space).
--
-- Exposed beyond Go, all for the gate (Tree precedent): `plainStyles` (the
-- default styleset with colors stripped, geometry kept), `sortEntries` (Go
-- readDir's private sort.Slice: directories first, then by name),
-- `readDirCmd` (Go's private readDir as a named Cmd), and the pure helpers
-- `permOf`/`canSelect`/`joinPath`/`parentDir` (private in Go, unobservable
-- there without the full Model).

{-| One rendered row's worth of fs data: the name, whether it opens as a
directory (stat's isDir — see the symlink deviation), the raw byte size and
the stat mode int the permission column decodes.
-}
type alias Entry =
  { name : String
  , isDir : Bool
  , size : Int
  , mode : Int
  }


{-| Go KeyMap: one binding per user action (Key.newBinding keys helpKey
helpDesc).
-}
type alias KeyMap =
  { goToTop : Key.Binding
  , goToLast : Key.Binding
  , down : Key.Binding
  , up : Key.Binding
  , pageUp : Key.Binding
  , pageDown : Key.Binding
  , back : Key.Binding
  , open : Key.Binding
  , select : Key.Binding
  }


{-| Go Styles: the paint of each row ingredient.
-}
type alias Styles =
  { disabledCursor : Lipgloss.Style
  , cursor : Lipgloss.Style
  , symlink : Lipgloss.Style
  , directory : Lipgloss.Style
  , file : Lipgloss.Style
  , disabledFile : Lipgloss.Style
  , permission : Lipgloss.Style
  , selected : Lipgloss.Style
  , disabledSelected : Lipgloss.Style
  , fileSize : Lipgloss.Style
  , emptyDirectory : Lipgloss.Style
  }


{-| The widget state — Go Model, fields lowercased, the three stacks folded
into `stack`, Go's unexported fields exposed (Timer precedent).
-}
type alias Model =
  { id : Int
  , path : String
  , currentDirectory : String
  , allowedTypes : List String
  , keyMap : KeyMap
  , files : List Entry
  , showPermissions : Bool
  , showSize : Bool
  , showHidden : Bool
  , dirAllowed : Bool
  , fileAllowed : Bool
  , fileSelected : String
  , selected : Int
  , stack : List ( Int, Int, Int )
  , minIdx : Int
  , maxIdx : Int
  , height : Int
  , autoHeight : Bool
  , cursor : String
  , styles : Styles
  }


{-| The widget's own messages: the completed directory listing (Go readDirMsg
— id + the sorted, hidden-filtered entries) and the decoded key press (Go
tea.KeyPressMsg, routed through `step`).
-}
type Msg
  = GotDir { id : Int, entries : List Entry }
  | KeyPressed Runtime.Key


{-| Go's Update's WindowSizeMsg constants.
-}
marginBottom = 5


fileSizeWidth = 7


{-| Go New(): the "." directory, cursor ">", permissions+size shown, hidden
filtered, files selectable, auto height, empty stacks.  `id` defaults to 0
(the wildcard — apps bump it via record update for multi-picker apps).
-}
new : Model
new =
  { id = 0
  , path = ""
  , currentDirectory = "."
  , allowedTypes = []
  , keyMap = defaultKeyMap
  , files = []
  , showPermissions = True
  , showSize = True
  , showHidden = False
  , dirAllowed = False
  , fileAllowed = True
  , fileSelected = ""
  , selected = 0
  , stack = []
  , minIdx = 0
  , maxIdx = 0
  , height = 0
  , autoHeight = True
  , cursor = ">"
  , styles = defaultStyles
  }


{-| Go DefaultKeyMap().
-}
defaultKeyMap : KeyMap
defaultKeyMap =
  { goToTop = Key.newBinding [ "g" ] "g" "first"
  , goToLast = Key.newBinding [ "G" ] "G" "last"
  , down = Key.newBinding [ "j", "down", "ctrl+n" ] "j" "down"
  , up = Key.newBinding [ "k", "up", "ctrl+p" ] "k" "up"
  , pageUp = Key.newBinding [ "K", "pgup" ] "pgup" "page up"
  , pageDown = Key.newBinding [ "J", "pgdown" ] "pgdown" "page down"
  , back = Key.newBinding [ "h", "backspace", "left", "esc" ] "h" "back"
  , open = Key.newBinding [ "l", "right", "enter" ] "l" "open"
  , select = Key.newBinding [ "enter" ] "enter" "select"
  }


{-| Go DefaultStyles().
-}
defaultStyles : Styles
defaultStyles =
  { disabledCursor = Lipgloss.foreground (Lipgloss.color "247") Lipgloss.newStyle
  , cursor = Lipgloss.foreground (Lipgloss.color "212") Lipgloss.newStyle
  , symlink = Lipgloss.foreground (Lipgloss.color "36") Lipgloss.newStyle
  , directory = Lipgloss.foreground (Lipgloss.color "99") Lipgloss.newStyle
  , file = Lipgloss.newStyle
  , disabledFile = Lipgloss.foreground (Lipgloss.color "243") Lipgloss.newStyle
  , disabledSelected = Lipgloss.foreground (Lipgloss.color "247") Lipgloss.newStyle
  , permission = Lipgloss.foreground (Lipgloss.color "244") Lipgloss.newStyle
  , selected = Lipgloss.bold True (Lipgloss.foreground (Lipgloss.color "212") Lipgloss.newStyle)
  , fileSize =
      Lipgloss.alignHorizontal Lipgloss.PRight
        (Lipgloss.setWidth fileSizeWidth
          (Lipgloss.foreground (Lipgloss.color "240") Lipgloss.newStyle)
        )
  , emptyDirectory =
      Lipgloss.paddingLeft 2
        (Lipgloss.foreground (Lipgloss.color "240") Lipgloss.newStyle)
  }


{-| The default styleset with the colors stripped (geometry kept: the 7-cell
right-aligned size column, the 2-cell empty-directory pad) — the gate's
byte-exact unstyled renders.
-}
plainStyles : Styles
plainStyles =
  { disabledCursor = Lipgloss.newStyle
  , cursor = Lipgloss.newStyle
  , symlink = Lipgloss.newStyle
  , directory = Lipgloss.newStyle
  , file = Lipgloss.newStyle
  , disabledFile = Lipgloss.newStyle
  , permission = Lipgloss.newStyle
  , selected = Lipgloss.newStyle
  , disabledSelected = Lipgloss.newStyle
  , fileSize = Lipgloss.alignHorizontal Lipgloss.PRight (Lipgloss.setWidth fileSizeWidth Lipgloss.newStyle)
  , emptyDirectory = Lipgloss.paddingLeft 2 Lipgloss.newStyle
  }


-- ---- Go accessors ----


{-| Go bottomIdx: the last visible index for a viewport whose first visible
index is `top`; an unset height shows ONE entry so the view is never blank.
-}
bottomIdx : Model -> Int -> Int
bottomIdx m top =
  if m.height < 1 then
    top

  else
    top + m.height - 1


{-| Go SetHeight.
-}
setHeight : Int -> Model -> Model
setHeight h m =
  let
    m1 =
      { m | height = h }
  in
  if m1.maxIdx > h - 1 then
    { m1 | maxIdx = bottomIdx m1 m1.minIdx }

  else
    m1


{-| Go HighlightedPath.
-}
highlightedPath : Model -> String
highlightedPath m =
  case entryAt m.selected m.files of
    Just f ->
      joinPath m.currentDirectory f.name

    Nothing ->
      ""


-- ---- Tea surface ----


{-| Go Update's KeyPressMsg switch, same order (GoToTop GoToLast Down Up
PageDown PageUp Back Open), with Go's returned readDir Cmds performed through
`inject`.  The Open branch is Go's verbatim, symlink re-stat dropped: enter
matches BOTH Open and Select (Go's default keymap), so a selectable entry has
its Path set by the SAME press that would navigate (a directory with
DirAllowed navigates AND records the path; the default DirAllowed=False
directory press only navigates), then a directory descends (push the view,
reset the window, re-list) and a file stops.
-}
update : (Msg -> msg) -> Runtime.Key -> Model -> ( Model, Runtime.Cmd msg )
update inject key m =
  if Key.matches key [ m.keyMap.goToTop ] then
    ( { m | selected = 0, minIdx = 0, maxIdx = bottomIdx m 0 }, Cmd.none )

  else if Key.matches key [ m.keyMap.goToLast ] then
    ( { m
        | selected = length m.files - 1
        , minIdx = maxOf 0 (length m.files - m.height)
        , maxIdx = length m.files - 1
      }
    , Cmd.none
    )

  else if Key.matches key [ m.keyMap.down ] then
    let
      s1 =
        m.selected + 1

      sel =
        if s1 >= length m.files then
          length m.files - 1

        else
          s1

      shifted =
        sel > m.maxIdx
    in
    ( { m
        | selected = sel
        , minIdx =
            if shifted then
              m.minIdx + 1

            else
              m.minIdx
        , maxIdx =
            if shifted then
              m.maxIdx + 1

            else
              m.maxIdx
      }
    , Cmd.none
    )

  else if Key.matches key [ m.keyMap.up ] then
    let
      s1 =
        m.selected - 1

      sel =
        if s1 < 0 then
          0

        else
          s1

      shifted =
        sel < m.minIdx
    in
    ( { m
        | selected = sel
        , minIdx =
            if shifted then
              m.minIdx - 1

            else
              m.minIdx
        , maxIdx =
            if shifted then
              m.maxIdx - 1

            else
              m.maxIdx
      }
    , Cmd.none
    )

  else if Key.matches key [ m.keyMap.pageDown ] then
    let
      sel =
        if m.selected + m.height >= length m.files then
          length m.files - 1

        else
          m.selected + m.height

      max1 =
        m.maxIdx + m.height

      clamped =
        max1 >= length m.files

      max2 =
        if clamped then
          length m.files - 1

        else
          max1

      min2 =
        if clamped then
          maxOf 0 (max2 - m.height)

        else
          m.minIdx + m.height
    in
    ( { m | selected = sel, minIdx = min2, maxIdx = max2 }, Cmd.none )

  else if Key.matches key [ m.keyMap.pageUp ] then
    let
      sel =
        if m.selected - m.height < 0 then
          0

        else
          m.selected - m.height

      min1 =
        m.minIdx - m.height

      clamped =
        min1 < 0

      min2 =
        if clamped then
          0

        else
          min1

      max2 =
        if clamped then
          min2 + m.height

        else
          m.maxIdx - m.height
    in
    ( { m | selected = sel, minIdx = min2, maxIdx = max2 }, Cmd.none )

  else if Key.matches key [ m.keyMap.back ] then
    let
      restored =
        case m.stack of
          ( sel, mn, mx ) :: rest ->
            { m | currentDirectory = parentDir m.currentDirectory, selected = sel, minIdx = mn, maxIdx = mx, stack = rest }

          [] ->
            { m | currentDirectory = parentDir m.currentDirectory, selected = 0, minIdx = 0, maxIdx = bottomIdx m 0 }
    in
    ( restored, readDirCmd inject restored restored.currentDirectory )

  else if Key.matches key [ m.keyMap.open ] then
    case entryAt m.selected m.files of
      Nothing ->
        ( m, Cmd.none )

      Just f ->
        let
          -- Go: the Select-matching press records the path ONLY when the
          -- entry's kind is allowed; otherwise the press just navigates.
          withPath =
            if not f.isDir && m.fileAllowed then
              if Key.matches key [ m.keyMap.select ] then
                { m | path = joinPath m.currentDirectory f.name }

              else
                m

            else if f.isDir && m.dirAllowed then
              if Key.matches key [ m.keyMap.select ] then
                { m | path = joinPath m.currentDirectory f.name }

              else
                m

            else
              m
        in
        if not f.isDir then
          ( withPath, Cmd.none )

        else
          let
            m1 =
              { withPath
                | currentDirectory = joinPath m.currentDirectory f.name
                , selected = 0
                , minIdx = 0
                , maxIdx = bottomIdx withPath 0
                , stack = ( m.selected, m.minIdx, m.maxIdx ) :: m.stack
              }
          in
          ( m1, readDirCmd inject m1 m1.currentDirectory )

  else
    ( m, Cmd.none )


{-| Go Update wholesale: the id-routed readDirMsg fold (files + the maxIdx
grow) plus key routing into `update`.  A GotDir from another instance is
dropped (Go's `if msg.id != m.id { break }`).
-}
step : (Msg -> msg) -> Msg -> Model -> ( Model, Runtime.Cmd msg )
step inject msg m =
  case msg of
    GotDir d ->
      if d.id /= m.id then
        ( m, Cmd.none )

      else
        ( { m | files = d.entries, maxIdx = maxOf m.maxIdx (bottomIdx m m.minIdx) }, Cmd.none )

    KeyPressed k ->
      update inject k m


{-| Go's WindowSizeMsg branch, delivered through Tea's resize hook: AutoHeight
picks SetHeight(rows - marginBottom), then the window recompute runs
unconditionally (it subsumes SetHeight's own maxIdx clamp).
-}
resize : Int -> Int -> Model -> Model
resize _ rows m =
  let
    m1 =
      if m.autoHeight then
        { m | height = rows - marginBottom }

      else
        m
  in
  { m1 | maxIdx = bottomIdx m1 m1.minIdx }


{-| Go Init: list the current directory.
-}
initCmd : (Msg -> msg) -> Model -> Runtime.Cmd msg
initCmd inject m =
  readDirCmd inject m m.currentDirectory


{-| Go's private readDir: Io.listDir, then one Io.stat per entry (fstatat
follows symlinks — Go EvalSymlinks parity for isDir), then Go's sort.Slice
(directories first, then by name) and the IsHidden filter — all inside the
Cmd, so GotDir carries the FINAL listing exactly like Go's readDirMsg.

The stat fan-out runs in statChunkSize-sized batches: the task interpreter
pushes one continuation frame per nested Task.andThen and PANICS past
MAX_FRAMES = 256 (src/effectloop.zig), and Task.sequence costs a frame per
element, so one unchunked sequence hard-crashes on any directory bigger
than the frame budget (e.g. /usr/lib).  statBatch threads the accumulated
entries through each batch's continuation, which the interpreter applies
only after its own frame popped — pending frames stay at one batch's worth
for ANY directory size.  Same single GotDir, same order, same listing.
-}
readDirCmd : (Msg -> msg) -> Model -> String -> Runtime.Cmd msg
readDirCmd inject m dir =
  Task.perform
    (\entries ->
      inject
        (GotDir
          { id = m.id
          , entries = sanitize m.showHidden (sortEntries entries)
          }
        )
    )
    (Task.andThen (\es -> statBatch dir es []) (Io.listDir dir))


-- One Task.sequence's worth of per-entry stats: sized so a batch's frames
-- (one per element, plus the perform/chain frames around it) stay well
-- under the runtime's MAX_FRAMES = 256 continuation-stack bound.
statChunkSize =
  200


-- statTask over every entry, chunked.  Unannotated like statTask: the
-- inferred Task error type stays listDir's, unified through Task.andThen
-- in readDirCmd.
statBatch dir es acc =
  case es of
    [] ->
      Task.succeed acc

    _ ->
      Task.andThen
        (\xs -> statBatch dir (drop statChunkSize es) (append acc xs))
        (Task.sequence (map (statTask dir) (take statChunkSize es)))


-- Go DidSelectFile: whether THIS press selected a file the app accepts.
-- Go's (bool, path) pair is Maybe String (Nothing = the false/"" row).


{-| Go DidSelectFile.
-}
didSelectFile : Runtime.Key -> Model -> Maybe String
didSelectFile key m =
  case didSelect key m of
    Just p ->
      if canSelect m p then
        Just p

      else
        Nothing

    Nothing ->
      Nothing


{-| Go DidSelectDisabledFile: the user pressed enter on an entry whose kind is
allowed but whose type is filtered out (for warning the user).
-}
didSelectDisabledFile : Runtime.Key -> Model -> Maybe String
didSelectDisabledFile key m =
  case didSelect key m of
    Just p ->
      if canSelect m p then
        Nothing

      else
        Just p

    Nothing ->
      Nothing


{-| Go's private didSelectFile: a press that matched Select, on a non-empty
listing whose selected entry's KIND is allowed and whose Path was actually
recorded (the Open branch only sets it for allowed kinds).
-}
didSelect : Runtime.Key -> Model -> Maybe String
didSelect key m =
  if isEmpty m.files then
    Nothing

  else if not (Key.matches key [ m.keyMap.select ]) then
    Nothing

  else
    case entryAt m.selected m.files of
      Nothing ->
        Nothing

      Just f ->
        if (not f.isDir && m.fileAllowed) || (f.isDir && m.dirAllowed) then
          if m.path /= "" then
            Just m.path

          else
            Nothing

        else
          Nothing


{-| Go canSelect: an empty AllowedTypes allows everything; otherwise the name
must end in one of the extensions.
-}
canSelect : Model -> String -> Bool
canSelect m file =
  case m.allowedTypes of
    [] ->
      True

    exts ->
      anySuffix exts file


-- ---- View ----


{-| Go View: the minIdx..maxIdx window of rows (cursor column, permission
column, 7-cell right-aligned size column, styled name), newline-terminated,
then newline-padded out to the model height; the empty listing renders the
"Bummer. No Files Found." style padded to the height instead.
-}
view : Model -> String
view m =
  if isEmpty m.files then
    let
      empty =
        m.styles.emptyDirectory
    in
    Lipgloss.render
      (Lipgloss.maxHeight m.height (Lipgloss.setHeight m.height empty))
      "Bummer. No Files Found."

  else
    let
      body =
        viewRows m 0 m.files
    in
    padToHeight (Lipgloss.height body) m.height body


viewRows : Model -> Int -> List Entry -> String
viewRows m i entries =
  case entries of
    [] ->
      ""

    e :: rest ->
      let
        tailStr =
          viewRows m (i + 1) rest
      in
      if i < m.minIdx || i > m.maxIdx then
        tailStr

      else
        String.append (String.append (viewRow m i e) "\n") tailStr


viewRow : Model -> Int -> Entry -> String
viewRow m i e =
  let
    disabled =
      not (canSelect m e.name) && not e.isDir

    sizeStr =
      String.fromInt e.size

    permStr =
      permOf e.mode
  in
  if m.selected == i then
    let
      -- Go's selected row builds the suffix UNSTYLED (plain %7s size) and
      -- paints the whole thing with Selected/DisabledSelected.
      selected =
        String.append
          (if m.showPermissions then
            String.append " " permStr

          else
            ""
          )
          (String.append
            (if m.showSize then
              padLeft7 sizeStr

            else
              ""
            )
            (String.append " " e.name)
          )

      ( cursorStyle, selectedStyle ) =
        if disabled then
          ( m.styles.disabledCursor, m.styles.disabledSelected )

        else
          ( m.styles.cursor, m.styles.selected )
    in
    String.append (Lipgloss.render cursorStyle m.cursor) (Lipgloss.render selectedStyle selected)

  else
    let
      nameStyle =
        if e.isDir then
          m.styles.directory

        else if disabled then
          m.styles.disabledFile

        else
          m.styles.file
    in
    String.append (Lipgloss.render m.styles.cursor " ")
      (String.append
        (if m.showPermissions then
          String.append " " (Lipgloss.render m.styles.permission permStr)

        else
          ""
        )
        (String.append
          (if m.showSize then
            Lipgloss.render m.styles.fileSize sizeStr

          else
            ""
          )
          (String.append " " (Lipgloss.render nameStyle e.name))
        )
      )


-- ---- internals ----


{-| The 10-char permission string for a stat mode: 'd' for S_IFDIR (16384),
'-' otherwise, then rwx for owner/group/other (256/128/64, 32/16/8, 4/2/1).
Go's setuid/setgid/sticky letters and special-type chars are out of subset.
-}
permOf : Int -> String
permOf mode =
  String.append
    (if Bitwise.and mode 16384 /= 0 then
      "d"

    else
      "-"
    )
    (String.append (permBit 256 mode "r")
      (String.append (permBit 128 mode "w")
        (String.append (permBit 64 mode "x")
          (String.append (permBit 32 mode "r")
            (String.append (permBit 16 mode "w")
              (String.append (permBit 8 mode "x")
                (String.append (permBit 4 mode "r")
                  (String.append (permBit 2 mode "w") (permBit 1 mode "x"))
                )
              )
            )
          )
        )
      )
    )


permBit : Int -> Int -> String -> String
permBit mask mode on =
  if Bitwise.and mode mask /= 0 then
    on

  else
    "-"


{-| Go readDir's sort.Slice: directories first, then by name (insertion sort —
the prelude has no sort; listings are fixture-sized).
-}
sortEntries : List Entry -> List Entry
sortEntries entries =
  case entries of
    [] ->
      []

    e :: rest ->
      insertEntry e (sortEntries rest)


insertEntry : Entry -> List Entry -> List Entry
insertEntry e sorted =
  case sorted of
    [] ->
      [ e ]

    h :: rest ->
      if entryLess e h then
        e :: sorted

      else
        h :: insertEntry e rest


{-| Directories before files; within a kind, by name (byte compare).
-}
entryLess : Entry -> Entry -> Bool
entryLess a b =
  if a.isDir && not b.isDir then
    True

  else if not a.isDir && b.isDir then
    False

  else
    case compare a.name b.name of
      LT ->
        True

      _ ->
        False


{-| Go readDir's hidden filter: IsHidden is the '.' prefix (hidden_unix.go).
-}
sanitize : Bool -> List Entry -> List Entry
sanitize showHidden entries =
  if showHidden then
    entries

  else
    filter (\e -> not (Str.startsWith "." e.name)) entries


-- The per-entry stat leaf: fstatat(dir/name) folded into an Entry.  A failed
-- stat completes the ZERO record (host contract) and the row is kept (see
-- the module header).  No annotation: the inferred Task error type is
-- listDir's, unified through Task.andThen in readDirCmd.

statTask dir e =
  Task.map
    (\st ->
      { name = e.name
      , isDir = st.isDir
      , size = st.size
      , mode = st.mode
      }
    )
    (Io.stat (joinPath dir e.name))


{-| filepath.Join for the reachable directory shapes ('.'-relative or
slash-joined, never a trailing slash): '.' and '' vanish, otherwise
dir + "/" + name.
-}
joinPath : String -> String -> String
joinPath dir name =
  if dir == "." || dir == "" then
    name

  else
    String.append dir (String.append "/" name)


{-| filepath.Dir over the same shapes: no separator means '.', a lone root
slash stays '/', otherwise the text before the last '/' (a trailing slash is
dropped by the split, matching Go's Clean).  Hand-rolled through split +
reverse (no lastIndexOf in the subset).
-}
parentDir : String -> String
parentDir path =
  if not (hasSlash path) then
    "."

  else
    case reverse (Str.split "/" path) of
      _ :: rest0 ->
        let
          dir =
            String.join "/" (reverse rest0)
        in
        if dir == "" then
          "/"

        else
          dir

      [] ->
        "."


hasSlash : String -> Bool
hasSlash path =
  case Str.split "/" path of
    _ :: _ :: _ ->
      True

    _ ->
      False


entryAt : Int -> List Entry -> Maybe Entry
entryAt k entries =
  case drop k entries of
    e :: _ ->
      Just e

    [] ->
      Nothing


{-| Go's fmt %7s for the SELECTED row's size column (the unselected rows go
through the styled FileSize render, which pads the same 7 by cell width).
-}
padLeft7 : String -> String
padLeft7 s =
  let
    w =
      String.length s
  in
  if w >= 7 then
    s

  else
    String.append (Str.repeat (7 - w) " ") s


{-| Go View's trailing loop: append newlines while the line count is still
within the height (Lipgloss.height counts the split-lines, so a body that
already ends in '\n' starts one PAST its last row — Go's exact arithmetic).
-}
padToHeight : Int -> Int -> String -> String
padToHeight i h s =
  if i <= h then
    padToHeight (i + 1) h (String.append s "\n")

  else
    s


anySuffix : List String -> String -> Bool
anySuffix exts file =
  case exts of
    [] ->
      False

    ext :: rest ->
      if Str.endsWith ext file then
        True

      else
        anySuffix rest file


maxOf : Int -> Int -> Int
maxOf a b =
  if a > b then
    a

  else
    b
