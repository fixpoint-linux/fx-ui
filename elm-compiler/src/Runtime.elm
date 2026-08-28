module Runtime exposing (worker, program)

-- M7 self-hosted async Kernel runtime (compiled by the compiler itself, like
-- Prelude).  NAMED `Runtime` (not `Platform`) because elm/core already ships a
-- `Platform` kernel module and a local `Platform.elm` would make `elm make`
-- ambiguous.  Fixtures keep the real-Elm spelling: the alias table rewrites
-- `Platform.worker` / `Cmd.*` / `Task.*` / `Io.*` -> `Runtime.*` (see
-- Lower.Module.platformTable).
--
-- Cmd msg = List (Task Never msg): a message command is a list of TASKS, not a
-- flat effect list (M6).  Each Task is a first-order description of an
-- effectful computation (succeed/fail/andThen/onError/stream leaves); runTask
-- INTERPRETS it to a Result; the drive/runOne loop runs each spawned task to
-- completion and feeds the delivered msg back through update.  This is a
-- COOPERATIVE scheduler (single-threaded, deterministic): no real interleaving
-- — that needs a host event loop the synchronous VM does not have (future
-- milestone).

type Task x a
    = TaskSucceed a
    | TaskFail x
    | TaskAndThen (a -> Task x b) (Task x a)
    | TaskOnError (x -> Task y a) (Task x a)
    | TaskWrite String
    | TaskReadLine
    | TaskReadFile String
    | TaskWriteFile String String
    | TaskExec a
    | TaskGetenv String
    | TaskSetenv String String
    | TaskCd String
    | TaskGetcwd
    | TaskGetpid
    | TaskGlob String


type alias Cmd msg = List (Task Never msg)


type alias Sub msg = ()


-- M9: a Program is returned by `program` as DATA (vector[Program, m0, c0,
-- updateFn], tag = bare symbol 'Program') so the HOST event loop
-- (src/vm/effectloop.zig) can drive the effects natively — real out-of-order
-- concurrency the synchronous worker cannot express.
type Program m c u
    = Program m c u


worker config =
    let
        ( m0, c0 ) = config.init ()
    in
    drive config.update m0 c0


program config =
    let
        ( m0, c0 ) = config.init ()
    in
    Program m0 c0 config.update


drive update model cmd =
    case cmd of
        task :: rest ->
            runOne update model task rest

        [] ->
            model


runOne update model task rest =
    case runTask task of
        Ok msg ->
            let
                ( m1, c1 ) = update msg model
            in
            drive update m1 (append c1 rest)

        Err e ->
            drive update model rest


runTask task =
    case task of
        TaskSucceed v ->
            Ok v

        TaskFail e ->
            Err e

        TaskAndThen cont inner ->
            case runTask inner of
                Ok v ->
                    runTask (cont v)

                Err e ->
                    Err e

        TaskOnError handler inner ->
            case runTask inner of
                Ok v ->
                    Ok v

                Err e ->
                    runTask (handler e)

        TaskWrite s ->
            let
                ignored = writeString s
            in
            Ok ()

        TaskReadLine ->
            Ok (readLine ())

        TaskReadFile path ->
            Ok (readFileAsString path)

        TaskWriteFile path contents ->
            let
                ignored = writeFile path contents
            in
            Ok ()

        TaskExec plan ->
            Ok (decodeExec (execPlanPrim plan))

        TaskGetenv name ->
            Ok (getenvPrim name)

        TaskSetenv name value ->
            Ok (setenvPrim name value)

        TaskCd path ->
            Ok (cdPrim path)

        TaskGetcwd ->
            Ok (getcwdPrim ())

        TaskGetpid ->
            Ok (getpidPrim ())

        TaskGlob pattern ->
            Ok (decodeStringList (globPrim pattern))


cmdNone = []


cmdBatch cmds =
    foldr append [] cmds


cmdMap f cmd =
    map (taskMap f) cmd


taskSucceed v =
    TaskSucceed v


taskFail e =
    TaskFail e


taskAndThen f t =
    TaskAndThen f t


taskOnError h t =
    TaskOnError h t


taskMap f t =
    taskAndThen (\v -> taskSucceed (f v)) t


taskMap2 f ta tb =
    taskAndThen (\a -> taskAndThen (\b -> taskSucceed (f a b)) tb) ta


taskSequence tasks =
    foldr (\t acc -> taskMap2 (\x xs -> x :: xs) t acc) (taskSucceed []) tasks


taskPerform toMsg task =
    [ taskMap toMsg task ]


taskAttempt toMsg task =
    [ taskMap toMsg (taskOnError (\e -> taskSucceed (Err e)) (taskMap Ok task)) ]


taskWriteString s =
    TaskWrite s


taskReadLine =
    TaskReadLine


taskReadFile path =
    TaskReadFile path


taskWriteFile path contents =
    TaskWriteFile path contents


taskExec plan =
    TaskExec plan


taskGetenv name =
    TaskGetenv name


taskSetenv name value =
    TaskSetenv name value


taskCd path =
    TaskCd path


taskGetcwd =
    TaskGetcwd


taskGetpid =
    TaskGetpid


taskGlob pattern =
    TaskGlob pattern


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


-- ---- M8 process execution: tagged-plan builders + result decoders ----
-- The exec-plan value is the Shen TAGGED-LIST demarshal format, built from
-- plain cons cells + interned symbol tags:
--   [cons]       = [intern "cons"]
--   [cons H T]   = [intern "cons", H, T]
--   [string S]   = [intern "string", S]
--   [number N]   = [intern "number", N]
--   [symbol X]   = [intern "symbol", intern X]
-- These are the ONLY way to build a plan; decodeExec/decodeStringList walk
-- the matching tagged results back to plain values.

tStr s =
    intern "string" :: s :: []


tNum n =
    intern "number" :: n :: []


tSym x =
    intern "symbol" :: intern x :: []


tNil =
    intern "cons" :: []


tCons h t =
    intern "cons" :: h :: t :: []


-- primExecPlan returns [cons [number code] [cons [string out] [cons [string
-- err] [cons]]]] -> (code, out, err).
decodeExec r =
    case r of
        _ :: codeTag :: outList :: _ ->
            case outList of
                _ :: outTag :: errList :: _ ->
                    case errList of
                        _ :: errTag :: _ :: _ ->
                            ( decodeNumber codeTag, decodeString outTag, decodeString errTag )

                        _ ->
                            ( 0, "", "" )

                _ ->
                    ( 0, "", "" )

        _ ->
            ( 0, "", "" )


-- primGlob returns [cons [string s1] [cons [string s2] [cons]]] -> [String].
decodeStringList r =
    case r of
        _ :: [] ->
            []

        _ :: (_ :: s :: _) :: rest :: [] ->
            s :: decodeStringList rest

        _ ->
            []


decodeNumber v =
    case v of
        _ :: n :: _ ->
            n

        _ ->
            0


decodeString v =
    case v of
        _ :: s :: _ ->
            s

        _ ->
            ""
