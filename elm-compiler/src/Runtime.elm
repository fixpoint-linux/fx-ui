module Runtime exposing (worker)

-- M6 self-hosted effects runtime (compiled by the compiler itself, like
-- Prelude).  NAMED `Runtime` (not `Platform`) because elm/core already ships a
-- `Platform` kernel module and a local `Platform.elm` would make `elm make`
-- ambiguous.  Fixtures keep the real-Elm spelling: the alias table rewrites
-- `Platform.worker` -> `Runtime.worker` (see Lower.Module.platformTable).
--
-- main = Platform.worker {init,update,subscriptions} runs the loop below:
-- init () -> (model, Cmd msg); each Cmd effect is a vector[tag, arg...]
-- descriptor interpreted via the stream prims; update feeds msgs back; the
-- loop returns the FINAL model (printed by elmvm).

type Eff msg
    = Wr String
    | RdLine (String -> msg)
    | RdFile String (String -> msg)
    | WrFile String String


type alias Cmd msg = List (Eff msg)


type alias Sub msg = ()


worker config =
    let
        ( m0, c0 ) = config.init ()
    in
    drive config.update m0 c0


drive update model cmd =
    case cmd of
        e :: rest ->
            runOne update model e rest

        [] ->
            model


runOne update model eff rest =
    case eff of
        Wr s ->
            let
                ignored = writeString s
            in
            drive update model rest

        RdLine cont ->
            let
                line = readLine ()
            in
            let
                ( m1, c1 ) = update (cont line) model
            in
            drive update m1 (append c1 rest)

        RdFile path cont ->
            let
                contents = readFileAsString path
            in
            let
                ( m1, c1 ) = update (cont contents) model
            in
            drive update m1 (append c1 rest)

        WrFile path contents ->
            let
                ignored = writeFile path contents
            in
            drive update model rest


cmdNone = []


cmdBatch cmds =
    foldr append [] cmds


cmdWriteString s =
    [ Wr s ]


cmdReadLine cont =
    [ RdLine cont ]


cmdReadFile path cont =
    [ RdFile path cont ]


cmdWriteFile path contents =
    [ WrFile path contents ]


subNone = ()


-- ---- stream helpers (prims + stdin/stdout pseudo-globals) ----

writeString s =
    writeBytes stdout (strToBytes s)


writeBytes out bytes =
    case bytes of
        b :: rest ->
            let
                ignored = writeByte b out
            in
            writeBytes out rest

        [] ->
            ()


writeFile path contents =
    let
        out = open path "out"
    in
    let
        ignored = writeBytes out (strToBytes contents)
    in
    close out


readFileAsString path =
    readFilePrim path


readLine () =
    readLineGo []


readLineGo acc =
    let
        b = readByte stdin
    in
    if b == -1 then
        bytesToString (reverse acc)

    else if b == 10 then
        bytesToString (reverse acc)

    else
        readLineGo (b :: acc)
