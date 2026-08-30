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
    | TaskReadKey
    | TaskWinSize
    | TaskWaitResize
    | TaskRawMode Bool
    | TaskNow
    | TaskSleep Int
    | TaskQuit
    | TaskMouseMode MouseMode
    | TaskReadMouse
    | TaskListDir String
    | TaskStat String


-- A decoded terminal key (M1 tea input surface).  The HOST event loop builds
-- these vectors with the BARE ctor name as tag (tag compare is by name), so
-- the ctor spellings here are the contract for effectloop.zig's decode table.
type Key
    = KeyChar String
    | KeyEnter
    | KeyTab
    | KeyBackspace
    | KeyEsc
    | KeyUp
    | KeyDown
    | KeyLeft
    | KeyRight
    | KeyHome
    | KeyEnd
    | KeyPgUp
    | KeyPgDn
    | KeyIns
    | KeyDel
    | KeyCtrl String
    | KeyOther Int
    | KeyEof


-- A decoded SGR mouse event (S4 host surface).  The HOST event loop builds
-- these vectors with the BARE ctor names as tags (tag compare is by name), so
-- the ctor spellings here are the contract for effectloop.zig's decode table.
type MouseMsg
    = MouseMsg MouseAction MouseButton Int Int
    | MouseEof


type MouseAction
    = MousePress
    | MouseRelease
    | MouseMotion
    | MouseWheel


type MouseButton
    = MouseLeft
    | MouseMiddle
    | MouseRight
    | MouseNone
    | MouseWheelUp
    | MouseWheelDown
    | MouseWheelLeft
    | MouseWheelRight


-- Mouse tracking mode for TaskMouseMode.  Click = press/release only (1006+
-- 1000), Drag = +drag (1006+1002), AllMotion = +all motion (1006+1003), Off
-- resets everything.  Off is spelled MouseModeOff (not `Off`) to avoid
-- colliding with the bare-name namespace of user modules.
type MouseMode
    = MouseModeOff
    | Click
    | Drag
    | AllMotion


type alias Cmd msg = List (Task Never msg)


type alias Sub msg = ()


-- M9: a Program is returned by `program` as DATA (vector[Program, m0, c0,
-- updateFn], tag = bare symbol 'Program') so the HOST event loop
-- (src/effectloop.zig) can drive the effects natively — real out-of-order
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


-- The Task interpreter.  Each Task constructor's effect has a DIFFERENT result
-- type (TaskWrite -> (), TaskReadLine -> String, TaskExec -> (Int, String,
-- String), TaskGetpid -> Int, TaskGlob -> List String, ...), which HM cannot
-- type — the untyped VM runs `runTask` dynamically.  Its body is therefore
-- TRUSTED (Type.Builtins.trustedBodies) and this signature (`Task x a ->
-- Result x a`, the honest monadic shape) is what the checker uses at every
-- call site (`runOne`/`drive`).
runTask : Task x a -> Result x a
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

        -- M1 terminal effects.  In the SYNC worker (this trusted interpreter)
        -- they are no-ops: no terminal to poll, so readKey completes with
        -- KeyEof, winSize reports 0x0, rawMode is ignored.  The HOST event loop
        -- (src/effectloop.zig, STEP 2) dispatches these same Task tags to real
        -- nonblocking stdin / ioctl / termios handling.
        TaskReadKey ->
            Ok KeyEof

        TaskWinSize ->
            Ok ( 0, 0 )

        -- M-FOUNDATION resize leaf.  Sync no-op: no signalfd / SIGWINCH here.
        -- The HOST event loop arms the shared signalfd and completes every
        -- armed waitResize eval with the fresh size on each SIGWINCH.
        TaskWaitResize ->
            Ok ( 0, 0 )

        TaskRawMode _ ->
            Ok ()

        -- M-FOUNDATION time/quit leaves.  Sync no-ops: no monotonic clock /
        -- event loop here.  The HOST event loop dispatches these same tags.
        TaskNow ->
            Ok 0

        TaskSleep _ ->
            Ok ()

        TaskQuit ->
            Ok ()

        -- M-FOUNDATION mouse leaves.  Sync no-ops: no terminal to poll, so
        -- readMouse completes with MouseEof and mouseMode is ignored.  The HOST
        -- event loop dispatches these same tags.
        TaskReadMouse ->
            Ok MouseEof

        TaskMouseMode _ ->
            Ok ()

        -- M-FOUNDATION dir/stat leaves.  Sync no-ops: no filesystem here, so
        -- listDir completes empty and stat completes the ZERO record.  The
        -- HOST event loop dispatches these same tags to getdents64 / fstatat
        -- (a failed host stat also completes the zero record).
        TaskListDir _ ->
            Ok []

        TaskStat _ ->
            Ok { size = 0, mode = 0, mtimeMs = 0, isDir = False, isFile = False }


cmdNone : List (Task Never msg)
cmdNone = []


cmdBatch : List (List (Task Never msg)) -> List (Task Never msg)
cmdBatch cmds =
    foldr append [] cmds


cmdMap : (a -> msg) -> List (Task Never a) -> List (Task Never msg)
cmdMap f cmd =
    map (taskMap f) cmd


taskSucceed : a -> Task x a
taskSucceed v =
    TaskSucceed v


taskFail : x -> Task x a
taskFail e =
    TaskFail e


taskAndThen : (a -> Task x b) -> Task x a -> Task x b
taskAndThen f t =
    TaskAndThen f t


taskOnError : (x -> Task y a) -> Task x a -> Task y a
taskOnError h t =
    TaskOnError h t


taskMap : (a -> b) -> Task x a -> Task x b
taskMap f t =
    taskAndThen (\v -> taskSucceed (f v)) t


taskMap2 : (a -> b -> c) -> Task x a -> Task x b -> Task x c
taskMap2 f ta tb =
    taskAndThen (\a -> taskAndThen (\b -> taskSucceed (f a b)) tb) ta


taskSequence : List (Task x a) -> Task x (List a)
taskSequence tasks =
    foldr (\t acc -> taskMap2 (\x xs -> x :: xs) t acc) (taskSucceed []) tasks


taskPerform : (a -> msg) -> Task x a -> List (Task Never msg)
taskPerform toMsg task =
    [ taskMap toMsg task ]


taskAttempt : (Result x a -> msg) -> Task x a -> List (Task Never msg)
taskAttempt toMsg task =
    [ taskMap toMsg (taskOnError (\e -> taskSucceed (Err e)) (taskMap Ok task)) ]


taskWriteString : String -> Task x ()
taskWriteString s =
    TaskWrite s


taskReadLine : Task x String
taskReadLine =
    TaskReadLine


taskReadFile : String -> Task x String
taskReadFile path =
    TaskReadFile path


taskWriteFile : String -> String -> Task x ()
taskWriteFile path contents =
    TaskWriteFile path contents


taskExec : a -> Task x (Int, String, String)
taskExec plan =
    TaskExec plan


taskGetenv : String -> Task x String
taskGetenv name =
    TaskGetenv name


taskSetenv : String -> String -> Task x Bool
taskSetenv name value =
    TaskSetenv name value


taskCd : String -> Task x Bool
taskCd path =
    TaskCd path


taskGetcwd : Task x String
taskGetcwd =
    TaskGetcwd


taskGetpid : Task x Int
taskGetpid =
    TaskGetpid


taskGlob : String -> Task x (List String)
taskGlob pattern =
    TaskGlob pattern


taskReadKey : Task x Key
taskReadKey =
    TaskReadKey


taskWinSize : Task x ( Int, Int )
taskWinSize =
    TaskWinSize


taskWaitResize : Task x ( Int, Int )
taskWaitResize =
    TaskWaitResize


taskRawMode : Bool -> Task x ()
taskRawMode enable =
    TaskRawMode enable


taskNow : Task x Int
taskNow =
    TaskNow


taskSleep : Int -> Task x ()
taskSleep ms =
    TaskSleep ms


taskQuit : Task x ()
taskQuit =
    TaskQuit


taskMouseMode : MouseMode -> Task x ()
taskMouseMode mode =
    TaskMouseMode mode


taskReadMouse : Task x MouseMsg
taskReadMouse =
    TaskReadMouse


taskListDir : String -> Task x (List { name : String, isDir : Bool })
taskListDir path =
    TaskListDir path


taskStat : String -> Task x { size : Int, mode : Int, mtimeMs : Int, isDir : Bool, isFile : Bool }
taskStat path =
    TaskStat path


subNone : ()
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

tStr : String -> List a
tStr s =
    intern "string" :: s :: []


tNum : number -> List a
tNum n =
    intern "number" :: n :: []


tSym : String -> List a
tSym x =
    intern "symbol" :: intern x :: []


tNil : List a
tNil =
    intern "cons" :: []


tCons : List a -> List a -> List a
tCons h t =
    intern "cons" :: h :: t :: []


-- primExecPlan returns [cons [number code] [cons [string out] [cons [string
-- err] [cons]]]] -> (code, out, err).
decodeExec : List a -> ( Int, String, String )
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
decodeStringList : List a -> List String
decodeStringList r =
    case r of
        _ :: [] ->
            []

        _ :: (_ :: s :: _) :: rest :: [] ->
            s :: decodeStringList rest

        _ ->
            []


decodeNumber : List a -> Int
decodeNumber v =
    case v of
        _ :: n :: _ ->
            n

        _ ->
            0


decodeString : List a -> String
decodeString v =
    case v of
        _ :: s :: _ ->
            s

        _ ->
            ""
