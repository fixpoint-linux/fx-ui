module FilePickerUnit exposing (main)

-- S11 gate (main : String via Platform.program): core-libs/FilePicker.elm
-- (bubbles filepicker — the only RUNTIME-DEPENDENT widget of the four).
--
-- The model is the OUTPUT STRING itself (dirunit precedent — a record model
-- would print as a cons dump), and the three listing rounds are phased by it:
-- "" = awaiting the parent listing, a walk-marker WITHOUT "inGamma" = awaiting
-- the gamma listing, anything WITH "inGamma" = awaiting the restored parent
-- listing.  Each phase REBUILDS its picker from FilePicker.new-shaped literals
-- plus the PREVIOUS phase's pinned scalars (dir/path/selected/stack —
-- constants, byte-pinned by the earlier phase's marker row, so the rebuild is
-- provably the fold's own result), then resize's window reset (height 19 =
-- rows 24 - marginBottom 5).
--
-- The host round trip: init fires the module's OWN readDirCmd against
-- tests/elm-fixtures/input/dirlist (committed stable files: alpha.txt 12
-- bytes, beta.txt 8 bytes, gamma/ holding only the hidden .keep), the GotDir
-- lands through FilePicker.step, the scripted keys j j <enter> k k <enter>
-- walk to beta.txt (enter records the path — enter matches BOTH open and
-- select), back to gamma and descend into it (pushing the stack and firing
-- the second listing), whose only entry is the filtered .keep (n=0 — the
-- hidden filter proven by the REAL pipeline), then h pops the stack and
-- re-lists the parent (restoration).
--
-- Asserted (all fs-STABLE facts — names/isDir/counts/state, never the byte
-- sizes or modes of the real files: dir st_size is fs-dependent and file
-- modes are umask-dependent, so view BYTES are pinned over SYNTHETIC
-- entries):
--   * the sorted listing (dirs first, then by name — Go readDir's
--     sort.Slice through sortEntries) + the hidden filter,
--   * the scripted navigation folds with the path recording and the
--     descend/stack/back restoration,
--   * id routing of GotDir (foreign id dropped, matching id applied) and
--     step's verbatim files passthrough (no double-filter),
--   * the window folds over a 5-entry/2-high picker: down/up with the
--     scroll shift in both directions and their clamps, goToTop/goToLast,
--     pageDown/pageUp and their clamps,
--   * resize (AutoHeight rows-5 + the maxIdx recompute) and setHeight,
--   * did-/canSelect: the allowed-kind gate, dirAllowed on a directory,
--     AllowedTypes suffixes, didSelectDisabledFile (kind allowed, type
--     filtered),
--   * highlightedPath, the sticky path surviving the round trip,
--   * the pure helpers: permOf's 10-char modes (dir/exec/plain/zero),
--     joinPath/parentDir shapes (incl. the one-separator parent), the
--     sortEntries order,
--   * the byte-exact plainStyles views (the 3-row window with the cursor
--     column, the %7s size column and a disabled row) and the empty
--     directory's padded "Bummer" block,
--   * the DEFAULT styleset's disabled-row SGR paint (fg 247 on the cursor
--     and on the selected suffix).
--
-- The unit never pattern-matches FilePicker.Msg (cross-module ctor
-- patterns are rejected): GotDir is received through FilePicker.step, and
-- the scripted keys go through FilePicker.update directly (the returned
-- readDirCmd of the descend / back folds is what Platform executes — that
-- advancing Cmd is the only one kept).

import FilePicker
import Str


type Msg
  = Got FilePicker.Msg


fxdir : String
fxdir =
  "tests/elm-fixtures/input/dirlist"


main =
  Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
  ( ""
  , FilePicker.readDirCmd Got (FilePicker.resize 80 24 FilePicker.new) fxdir
  )


{-| One key folded into fp, the Cmd dropped (only folds that MUST fire a
listing keep it — the descend and the back-out).
-}
press : Runtime.Key -> FilePicker.Model -> FilePicker.Model
press key fp =
  Tuple.first (FilePicker.update Got key fp)


{-| The GotDir fold through the module's own step (id routing inside).
-}
gotDir d fp =
  Tuple.first (FilePicker.step Got (FilePicker.GotDir d) fp)


{-| The phase's base picker: the Go New defaults with the carried scalars
restored, then resize's window reset (idempotent at rows 24: height 19,
maxIdx = bottomIdx 0 = 18).
-}
rebuild : String -> String -> Int -> List ( Int, Int, Int ) -> FilePicker.Model
rebuild dir path sel stack =
  FilePicker.resize 80 24
    { id = 0
    , path = path
    , currentDirectory = dir
    , allowedTypes = []
    , keyMap = FilePicker.defaultKeyMap
    , files = []
    , showPermissions = True
    , showSize = True
    , showHidden = False
    , dirAllowed = False
    , fileAllowed = True
    , fileSelected = ""
    , selected = sel
    , stack = stack
    , minIdx = 0
    , maxIdx = 18
    , height = 19
    , autoHeight = True
    , cursor = ">"
    , styles = FilePicker.defaultStyles
    }


{-| A copy of fp with app-chosen flags (AllowedTypes / showHidden /
dirAllowed / selected) — a full literal so no record-update ever touches a
module Model.
-}
variant : FilePicker.Model -> List String -> Bool -> Bool -> Int -> FilePicker.Model
variant fp types hidden dirAllowed sel =
  { id = fp.id
  , path = fp.path
  , currentDirectory = fp.currentDirectory
  , allowedTypes = types
  , keyMap = fp.keyMap
  , files = fp.files
  , showPermissions = fp.showPermissions
  , showSize = fp.showSize
  , showHidden = hidden
  , dirAllowed = dirAllowed
  , fileAllowed = fp.fileAllowed
  , fileSelected = fp.fileSelected
  , selected = sel
  , stack = fp.stack
  , minIdx = fp.minIdx
  , maxIdx = fp.maxIdx
  , height = fp.height
  , autoHeight = fp.autoHeight
  , cursor = fp.cursor
  , styles = fp.styles
  }


stackHeld : List ( Int, Int, Int ) -> String
stackHeld stack =
  case stack of
    _ :: _ ->
      "held"

    [] ->
      "empty"


-- ---- synthetic entries (byte-stable view/scroll material) ----

eDir : FilePicker.Entry
eDir =
  { name = "sub", isDir = True, size = 4096, mode = 16877 }


eTxt : FilePicker.Entry
eTxt =
  { name = "alpha.txt", isDir = False, size = 12345, mode = 33188 }


eNo : FilePicker.Entry
eNo =
  { name = "no.zzz", isDir = False, size = 7, mode = 33188 }


f : Int -> FilePicker.Entry
f k =
  { name = "f" ++ String.fromInt k, isDir = False, size = k, mode = 33188 }


nameOf : FilePicker.Entry -> String
nameOf e =
  String.append e.name
    (if e.isDir then
      "/"

     else
      ""
    )


namesOf : List FilePicker.Entry -> String
namesOf entries =
  String.join "," (map nameOf entries)


maybeOf : Maybe String -> String
maybeOf m =
  case m of
    Just p ->
      String.append "just:" p

    Nothing ->
      "none"


boolOf : Bool -> String
boolOf b =
  if b then
    "1"

  else
    "0"


st : FilePicker.Model -> String
st fp =
  "sel=" ++ String.fromInt fp.selected ++ "/min=" ++ String.fromInt fp.minIdx ++ "/max=" ++ String.fromInt fp.maxIdx


{-| The 3-row byte-exact view material: dir row, SELECTED file row, and a
type-disabled file row (AllowedTypes .zzz) — plainStyles so the bytes are
exactly the geometry (cursor column, " " + perm, the %7s size, " " + name).
-}
plainView : String
plainView =
  FilePicker.view
    { id = 0
    , path = ""
    , currentDirectory = "."
    , allowedTypes = [ ".zzz" ]
    , keyMap = FilePicker.defaultKeyMap
    , files = [ eDir, eTxt, eNo ]
    , showPermissions = True
    , showSize = True
    , showHidden = False
    , dirAllowed = False
    , fileAllowed = True
    , fileSelected = ""
    , selected = 1
    , stack = []
    , minIdx = 0
    , maxIdx = 2
    , height = 3
    , autoHeight = False
    , cursor = ">"
    , styles = FilePicker.plainStyles
    }


{-| The empty listing's padded "Bummer" block, 2 high, unstyled.
-}
emptyView : String
emptyView =
  FilePicker.view
    { id = 0
    , path = ""
    , currentDirectory = "."
    , allowedTypes = []
    , keyMap = FilePicker.defaultKeyMap
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
    , height = 2
    , autoHeight = False
    , cursor = ">"
    , styles = FilePicker.plainStyles
    }


{-| The DEFAULT styleset's disabled-row paint: a selected but type-disabled
file (alpha.txt vs AllowedTypes .zzz) renders cursor + suffix through
DisabledCursor/DisabledSelected (fg 247) — the SGR bytes pin the disabled
STYLE PICKING that plainStyles strips.
-}
styledDisabled : String
styledDisabled =
  FilePicker.view
    { id = 0
    , path = ""
    , currentDirectory = "."
    , allowedTypes = [ ".zzz" ]
    , keyMap = FilePicker.defaultKeyMap
    , files = [ eTxt ]
    , showPermissions = False
    , showSize = False
    , showHidden = False
    , dirAllowed = False
    , fileAllowed = True
    , fileSelected = ""
    , selected = 0
    , stack = []
    , minIdx = 0
    , maxIdx = 0
    , height = 1
    , autoHeight = False
    , cursor = ">"
    , styles = FilePicker.defaultStyles
    }


{-| The 5-entry window picker for the scroll folds: 7 rows -> AutoHeight
height 2 -> the visible window is 2 (maxIdx = bottomIdx 0 = 1).
-}
window5 : FilePicker.Model
window5 =
  gotDir { id = 0, entries = [ f 1, f 2, f 3, f 4, f 5 ] } (FilePicker.resize 80 7 FilePicker.new)


update : Msg -> String -> ( String, Runtime.Cmd Msg )
update msg model =
  case msg of
    Got fmsg ->
      if model == "" then
        -- The parent listing landed: walk to beta.txt (j j), enter records
        -- the path (enter matches open AND select; the file stops), walk
        -- back to gamma (k k) and descend through enter (push + re-list).
        let
          fp1 =
            Tuple.first (FilePicker.step Got fmsg (rebuild fxdir "" 0 []))

          walked =
            press (KeyChar "k") (press (KeyChar "k") (press KeyEnter (press (KeyChar "j") (press (KeyChar "j") fp1))))

          descended =
            FilePicker.update Got KeyEnter walked

          d =
            Tuple.first descended
        in
        ( "z"
            ++ "\nwalk dir="
            ++ d.currentDirectory
            ++ " sel="
            ++ String.fromInt d.selected
            ++ " stack="
            ++ stackHeld d.stack
            ++ " path="
            ++ d.path
        , Tuple.second descended
        )

      else if not (Str.contains "inGamma" model) then
        -- The gamma listing landed (only the hidden .keep -> n=0): h pops
        -- the stack and re-lists the parent.
        let
          fpg =
            Tuple.first
              (FilePicker.step Got fmsg
                (rebuild (FilePicker.joinPath fxdir "gamma") (FilePicker.joinPath fxdir "beta.txt") 0 [ ( 0, 0, 18 ) ])
              )

          back =
            FilePicker.update Got (KeyChar "h") fpg

          b =
            Tuple.first back
        in
        ( model
            ++ "\ninGamma dir="
            ++ fpg.currentDirectory
            ++ " n="
            ++ String.fromInt (length fpg.files)
            ++ " stack="
            ++ stackHeld fpg.stack
            ++ "\nback dir="
            ++ b.currentDirectory
            ++ " sel="
            ++ String.fromInt b.selected
            ++ " stack="
            ++ stackHeld b.stack
            ++ " path="
            ++ b.path
        , Tuple.second back
        )

      else
        -- The parent listing is restored: emit every assertion row.
        let
          fp2 =
            Tuple.first (FilePicker.step Got fmsg (rebuild fxdir (FilePicker.joinPath fxdir "beta.txt") 0 []))

          foreign =
            gotDir { id = 7, entries = [ eNo ] } fp2

          replaced =
            gotDir { id = 0, entries = [ eDir ] } fp2

          rawTwo =
            gotDir { id = 0, entries = [ eNo, { name = ".dot", isDir = False, size = 1, mode = 33188 } ] }
              (variant fp2 [] True False 0)

          dirAllowedFp =
            variant fp2 [] False True 0

          txtTypes =
            variant fp2 [ ".txt" ] False False 2

          zzzTypes =
            variant fp2 [ ".zzz" ] False False 2

          fp5 =
            window5

          down2 =
            press (KeyChar "j") (press (KeyChar "j") fp5)

          down5 =
            press (KeyChar "j") (press (KeyChar "j") (press (KeyChar "j") down2))

          up1 =
            press (KeyChar "k") down5

          up2 =
            press (KeyChar "k") up1

          upTop =
            press (KeyChar "k") (press (KeyChar "k") (press (KeyChar "k") (press (KeyChar "k") up2)))

          topped =
            press (KeyChar "g") upTop

          lasted =
            press (KeyChar "G") topped

          paged1 =
            press (KeyChar "J") topped

          paged2 =
            press (KeyChar "J") paged1

          upPaged =
            press (KeyChar "K") paged2

          upPaged2 =
            press (KeyChar "K") upPaged

          rows =
            [ model
            , "restored dir="
                ++ fp2.currentDirectory
                ++ " names="
                ++ namesOf fp2.files
                ++ " sel="
                ++ String.fromInt fp2.selected
            , "sticky path="
                ++ fp2.path
                ++ " stack="
                ++ stackHeld fp2.stack
                ++ " highlighted="
                ++ FilePicker.highlightedPath fp2
            , "new dir="
                ++ FilePicker.new.currentDirectory
                ++ " cursor="
                ++ FilePicker.new.cursor
                ++ " perms="
                ++ boolOf FilePicker.new.showPermissions
                ++ " size="
                ++ boolOf FilePicker.new.showSize
                ++ " hidden="
                ++ boolOf FilePicker.new.showHidden
                ++ " dirAllowed="
                ++ boolOf FilePicker.new.dirAllowed
                ++ " fileAllowed="
                ++ boolOf FilePicker.new.fileAllowed
                ++ " autoHeight="
                ++ boolOf FilePicker.new.autoHeight
                ++ " files="
                ++ String.fromInt (length FilePicker.new.files)
            , "id7="
                ++ String.fromInt (length foreign.files)
                ++ " id0="
                ++ String.fromInt (length replaced.files)
                ++ " raw2="
                ++ String.fromInt (length rawTwo.files)
            , "sort=" ++ namesOf (FilePicker.sortEntries [ eNo, eDir, eTxt ])
            , "perm=" ++ FilePicker.permOf 16877 ++ "," ++ FilePicker.permOf 33188 ++ "," ++ FilePicker.permOf 493 ++ "," ++ FilePicker.permOf 0
            , "join="
                ++ FilePicker.joinPath "." "x"
                ++ ","
                ++ FilePicker.joinPath "" "x"
                ++ ","
                ++ FilePicker.joinPath "a/b" "c"
                ++ " parent="
                ++ FilePicker.parentDir "a/b/c"
                ++ ","
                ++ FilePicker.parentDir "a/b"
                ++ ","
                ++ FilePicker.parentDir "gamma"
                ++ ","
                ++ FilePicker.parentDir "/"
            , "dsf(dirAllowed)="
                ++ maybeOf (FilePicker.didSelectFile KeyEnter dirAllowedFp)
                ++ " dsf(default)="
                ++ maybeOf (FilePicker.didSelectFile KeyEnter fp2)
                ++ " dsf(txt)="
                ++ maybeOf (FilePicker.didSelectFile KeyEnter txtTypes)
                ++ " dsf(zzz)="
                ++ maybeOf (FilePicker.didSelectFile KeyEnter zzzTypes)
            , "dsdf(txt)=" ++ maybeOf (FilePicker.didSelectDisabledFile KeyEnter txtTypes) ++ " dsdf(zzz)=" ++ maybeOf (FilePicker.didSelectDisabledFile KeyEnter zzzTypes)
            , "can empty=" ++ boolOf (FilePicker.canSelect fp2 "anything.txt") ++ " can zzz-no=" ++ boolOf (FilePicker.canSelect zzzTypes "no.zzz") ++ " can zzz-txt=" ++ boolOf (FilePicker.canSelect zzzTypes "alpha.txt") ++ " can zzz-dir=" ++ boolOf (FilePicker.canSelect zzzTypes "sub")
            , "win5=" ++ st fp5 ++ " d2=" ++ st down2 ++ " d5=" ++ st down5 ++ " u1=" ++ st up1 ++ " u2=" ++ st up2 ++ " uTop=" ++ st upTop
            , "top=" ++ st topped ++ " last=" ++ st lasted
            , "pd1=" ++ st paged1 ++ " pd2=" ++ st paged2 ++ " pu1=" ++ st upPaged ++ " pu2=" ++ st upPaged2
            , "setH=" ++ st (FilePicker.setHeight 2 fp2) ++ " rsz=" ++ st (FilePicker.resize 80 6 fp2)
            , String.append "v1[" (String.append plainView "]")
            , String.append "v2[" (String.append emptyView "]")
            , String.append "v3[" (String.append styledDisabled "]")
            ]
        in
        ( String.join "\n" rows
        , Cmd.none
        )
