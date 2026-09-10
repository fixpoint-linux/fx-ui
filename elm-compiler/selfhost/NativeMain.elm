module NativeMain exposing (main)

{-| M15: the node-free compiler driver — a pure `Runtime.program` Task app
that replaces `elm-compiler/run.js` for BOTH of its CLI shapes.

CLI (identical to run.js, minus the leading `node run.js`):

    elmc <input1.elm> [input2.elm ...] <output.csexp>
    elmc <manifest>

The manifest is LINE-ORIENTED (no Json.Decode in the selfhost corpus): one
source path per line; each group terminated by an output marker line.
tools/selfhost-gate.sh generates it from the gate's JSON manifest with

    jq -r '.groups[] | (.sources[] | .), "-> " + .output'

    <src1.elm>
    <src2.elm>
    -> <out1.csexp>
    <src3.elm>
    -> <out2.csexp>

A lone argument that is not `--batch`-like is treated as a manifest iff its
line 2 (or any later line) starts with "-> " — the single-group CLI shape
(a.b elm out.csexp) has no such line.  (`--batch` is accepted as a no-op
prefix for run.js symmetry; the manifest argument follows it.)

The fixed corpus (Prelude, Runtime, the 25 core-libs — run.js's exact order,
see corpusPaths) is compiled ONCE per process and every group compiles
against it, matching run.js's batch behavior byte for byte:
Lower.Module.compileBatch is called with the same corpus texts in the same
order and the same per-group source texts in the same order, and its output
is a pure function of those inputs.

I/O discipline: stdout stays CLEAN — the driver prints the final model (a
status line) after the effect loop drains.  Per-group compile failures land
in that group's OWN output file as "err <msg>" (run.js parity, so `head -c4
| grep '^err '` checks keep working).  Usage/manifest-level failures write
`err <msg>` to `elmc.err` in the CWD.

Env contract: ELMC_ROOT = repo root; the corpus is read from
$ELMC_ROOT/elm-compiler/.  When unset or empty the corpus root is the plain
relative path `elm-compiler` (paths resolve against the process CWD
everywhere else, matching run.js).  The process arguments arrive via
Runtime.argv () (the *argv* pseudo-global the driver installs — run.js
argv[2:] shape: the binary path is NOT an element).
-}

import Lower.Module as Module


type Msg
    = Done String


type alias Job =
    { sources : List String
    , output : String
    }


main =
    Runtime.program
        { init = init
        , update = update
        , subscriptions = \_ -> ()
        }


init () =
    ( "elmc: starting"
    , Task.perform Done (Task.andThen start (Task.succeed ()))
    )


update msg model =
    case msg of
        Done status ->
            ( status, Cmd.none )



-- ============================ entry ============================


start () =
    case parseArgs (stripFlags (Runtime.argv ())) of
        Err msg ->
            errLine msg

        Ok [] ->
            errLine "usage: elmc <in1.elm> [in2.elm ...] <out.csexp> | elmc <manifest>"

        Ok [ path ] ->
            -- A single argument is a MANIFEST (tools/selfhost-gate.sh's
            -- contract: `$BIN <manifest>`); the single-group CLI shape needs
            -- at least in+out, so it can never collide.
            Task.andThen runManifest (Io.readFile path)

        Ok args ->
            runJobs [ { sources = butLast args, output = last args "" } ]


butLast : List a -> List a
butLast xs =
    case xs of
        [] ->
            []

        _ :: rest ->
            case rest of
                [] ->
                    []

                _ ->
                    lead xs rest


lead : List a -> List a -> List a
lead xs rest =
    case xs of
        x :: _ ->
            x :: butLast rest

        [] ->
            []



-- run.js accepts `--batch <manifest>`; keep the spelling working.
stripFlags : List String -> List String
stripFlags argv_ =
    case argv_ of
        "--batch" :: rest ->
            stripFlags rest

        arg :: rest ->
            arg :: stripFlags rest

        [] ->
            []


parseArgs : List String -> Result String (List String)
parseArgs argv_ =
    Ok argv_


last : List a -> a -> a
last xs dflt =
    case xs of
        [] ->
            dflt

        x :: rest ->
            case rest of
                [] ->
                    x

                _ ->
                    last rest dflt



-- ======================= manifest -> jobs =======================
-- One job per "-> <out>" line; the lines above it (since the previous marker
-- or the start) are that job's sources, in file order.  Blank lines and
-- lines between a marker and the next source are skipped.


runManifest text =
    case manifestJobs (Str.lines text) of
        Err msg ->
            errLine msg

        Ok [] ->
            errLine "manifest has no groups"

        Ok jobs ->
            runJobs jobs


manifestJobs : List String -> Result String (List Job)
manifestJobs lines =
    manifestGo lines [] []


manifestGo : List String -> List String -> List Job -> Result String (List Job)
manifestGo lines accSrcs accJobs =
    case lines of
        [] ->
            case accSrcs of
                [] ->
                    Ok (reverse accJobs)

                _ ->
                    Err "manifest ends with sources but no '-> output' line"

        line :: rest ->
            if line == "" then
                manifestGo rest accSrcs accJobs

            else if isMarker line then
                case accSrcs of
                    [] ->
                        Err ("manifest output marker with no sources: " ++ line)

                    _ ->
                        manifestGo rest [] ({ sources = reverse accSrcs, output = markerPath line } :: accJobs)

            else
                manifestGo rest (line :: accSrcs) accJobs


isMarker : String -> Bool
isMarker line =
    String.startsWith "-> " line


markerPath : String -> String
markerPath line =
    String.dropLeft 3 line


reverse : List a -> List a
reverse xs =
    revGo xs []


revGo : List a -> List a -> List a
revGo xs acc =
    case xs of
        x :: rest ->
            revGo rest (x :: acc)

        [] ->
            acc



-- ======================= the compile pipeline =======================
-- Mirrors run.js: read every source ONCE (group texts in group order),
-- compile the corpus once via Module.compileBatch, write each bundle (or its
-- "err <msg>" payload) to the job's output path.


runJobs jobs =
    Task.andThen (compileJobs jobs) (readAll (allSources jobs))


allSources : List Job -> List String
allSources jobs =
    concatMap2 .sources jobs


readAll paths =
    seqMap (List.map Io.readFile paths)


compileJobs jobs texts =
    readCorpus
        |> Task.andThen
            (\corpus ->
                case Module.compileBatch corpus (regroup jobs texts) of
                    Ok bundles ->
                        writeBundles (zipJobs jobs bundles) []

                    Err msg ->
                        -- corpus-level failure: every group gets the payload
                        -- (run.js parity via Main.elm's Err branch)
                        writeBundles (zipJobs jobs (List.map (\_ -> "err " ++ msg) jobs)) []
            )


readCorpus =
    seqMap (List.map Io.readFile corpusPaths)


corpusPaths : List String
corpusPaths =
    List.map (\p -> corpusRoot ++ "/" ++ p)
        ([ "src/Prelude.elm", "src/Runtime.elm" ]
            ++ List.map (\f -> "core-libs/" ++ f) coreLibs
        )


coreLibs : List String
coreLibs =
    [ "Dict.elm", "Set.elm", "Maybe.elm", "Result.elm"
    , "Tuple.elm", "JsArray.elm", "Array.elm", "Tea.elm", "TextInput.elm"
    , "Str.elm", "Lipgloss.elm", "Draw.elm", "Key.elm", "Help.elm", "Paginator.elm"
    , "Progress.elm", "Spinner.elm", "Viewport.elm", "Textarea.elm"
    , "ListBox.elm", "Table.elm", "Timer.elm", "Stopwatch.elm", "Tree.elm"
    , "FilePicker.elm"
    ]


corpusRoot : String
corpusRoot =
    "elm-compiler"


regroup : List Job -> List String -> List (List String)
regroup jobs texts =
    splitAt (List.map (\j -> count (j.sources)) jobs) texts


writeBundles : List ( Job, String ) -> List String -> a
writeBundles pairs done =
    case pairs of
        [] ->
            Task.succeed ("elmc: wrote " ++ String.fromInt (count done) ++ " bundles")

        ( job, bundle ) :: rest ->
            Task.andThen
                (\_ -> writeBundles rest (job.output :: done))
                (Io.writeFile job.output bundle)


zipJobs : List Job -> List String -> List ( Job, String )
zipJobs jobs bundles =
    case jobs of
        [] ->
            []

        j :: jrest ->
            case bundles of
                b :: brest ->
                    ( j, b ) :: zipJobs jrest brest

                [] ->
                    []



-- ======================= tiny List helpers =======================
-- (Prelude's map/filter/... are in scope unqualified, but `length`/`concat`
-- spellings differ from elm/core; local helpers keep this self-contained.)


seqMap tasks =
    case tasks of
        [] ->
            Task.succeed []

        t :: rest ->
            Task.andThen (\v -> Task.andThen (\vs -> Task.succeed (v :: vs)) (seqMap rest)) t


concatMap2 : (a -> List b) -> List a -> List b
concatMap2 f xs =
    case xs of
        [] ->
            []

        x :: rest ->
            append2 (f x) (concatMap2 f rest)


append2 : List a -> List a -> List a
append2 xs ys =
    case xs of
        x :: rest ->
            x :: append2 rest ys

        [] ->
            ys


splitAt : List Int -> List a -> List (List a)
splitAt ns xs =
    case ns of
        [] ->
            []

        n :: rest ->
            take n xs :: splitAt rest (drop n xs)


count : List a -> Int
count xs =
    case xs of
        _ :: rest ->
            1 + count rest

        [] ->
            0


take : Int -> List a -> List a
take n xs =
    if n <= 0 then
        []

    else
        case xs of
            x :: rest ->
                x :: take (n - 1) rest

            [] ->
                []


drop : Int -> List a -> List a
drop n xs =
    if n <= 0 then
        xs

    else
        case xs of
            _ :: rest ->
                drop (n - 1) rest

            [] ->
                []


errLine : String -> a
errLine msg =
    Task.andThen (\_ -> Task.succeed ("elmc: " ++ msg)) (Io.writeFile "elmc.err" ("err " ++ msg ++ "\n"))
