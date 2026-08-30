module DirUnit exposing (main)

-- S6 gate: host TaskListDir (openat O_DIRECTORY + getdents64) via Io.listDir.
-- Entries arrive in RAW filesystem order (documented leaf contract — sorting
-- is app-side), so the fixture re-sorts the names through Set for a
-- deterministic join.  The '/'-suffix encodes isDir per name (dirent d_type;
-- DT_UNKNOWN falls back to fstatat) and pins that EXACTLY alpha.txt, beta.txt
-- and gamma exist — '.'/'..' are skipped Go-os.ReadDir-style.

type Msg
    = Got String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( ""
    , Task.perform Got
        (Task.map
            (\entries -> String.join "," (Set.toList (Set.fromList (List.map tagOf entries))))
            (Io.listDir "tests/elm-fixtures/input/dirlist")
        )
    )


tagOf entry =
    String.append entry.name
        (if entry.isDir then
            "/"

         else
            ""
        )


update msg model =
    case msg of
        Got s ->
            ( s, Cmd.none )
