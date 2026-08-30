module StatUnit exposing (main)

-- S6 gate: host TaskStat (fstatat AT_FDCWD, symlink-following) via Io.stat.
-- Asserts size + isDir/isFile + the S_IFMT type bits of mode (61440 =
-- 0o170000; regular = 32768 = 0o100000, directory = 16384 = 0o40000) for a
-- known regular file and the fixture directory.  mtimeMs is asserted ONLY
-- as plausible (non-negative) — it changes with every checkout.  A missing
-- path must complete the ZERO record (host-failure parity with the sync
-- runTask no-op).

type Msg
    = Got String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( ""
    , Task.perform Got
        (Task.map go
            (Task.sequence
                [ Io.stat "tests/elm-fixtures/input/dirlist/alpha.txt"
                , Io.stat "tests/elm-fixtures/input/dirlist/beta.txt"
                , Io.stat "tests/elm-fixtures/input/dirlist/gamma"
                , Io.stat "tests/elm-fixtures/input/dirlist/absent"
                ]
            )
        )
    )


typeBits info =
    Bitwise.and info.mode 61440


alphaCheck info =
    String.append
        (if info.size == 12 then
            "s12-ok "

         else
            "s12-bad "
        )
        (String.append
            (if info.isDir then
                "dir-bad "

             else
                "nd-ok "
            )
            (String.append
                (if info.isFile then
                    "reg-ok "

                 else
                    "reg-bad "
                )
                (String.append
                    (if typeBits info == 32768 then
                        "treg-ok "

                     else
                        "treg-bad "
                    )
                    (if info.mtimeMs >= 0 then
                        "mtime-ok "

                     else
                        "mtime-bad "
                    )
                )
            )
        )


betaCheck info =
    if info.size == 8 then
        "s8-ok "

    else
        "s8-bad "


gammaCheck info =
    String.append
        (if info.isDir then
            "dir-ok "

         else
            "dir-bad "
        )
        (String.append
            (if info.isFile then
                "file-bad "

             else
                "nfile-ok "
            )
            (if typeBits info == 16384 then
                "tdir-ok"

             else
                "tdir-bad"
            )
        )


missCheck info =
    if info.size == 0 && not info.isDir && not info.isFile then
        " miss-ok"

    else
        " miss-bad"


go infos =
    case infos of
        a :: b :: c :: d :: [] ->
            String.append (alphaCheck a)
                (String.append (betaCheck b)
                    (String.append (gammaCheck c) (missCheck d))
                )

        _ ->
            "shape-bad"


update msg model =
    case msg of
        Got s ->
            ( s, Cmd.none )
