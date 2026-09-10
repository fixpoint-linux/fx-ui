module Nativeio exposing (main)

-- M12 spike: the 'read .elm -> write .csexp' worker shape as a NATIVE binary
-- (aot-build.sh, zero node at runtime).  init reads two paths from env vars
-- (ELMC_IN / ELMC_OUT via Io.getenv), then one andThen chain reads the input
-- file, writes a line-numbered copy (1-based, "n: line") to the output path,
-- and writes a stdout sentinel — Io.writeFile SWALLOWS open failures
-- (effectloop.zig leafWriteFile completes success on openat error), so the
-- sentinel is the only observable proof the whole chain ran.  Model ends as a
-- status string (printed by the driver after the effect loop drains; stdout
-- order: sentinel first, then the final model).

type Msg
    = Done String


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


init () =
    ( "working"
    , Task.perform Done
        (Task.andThen
            (\inPath ->
                Task.andThen
                    (\outPath ->
                        Task.andThen
                            (\contents ->
                                Task.andThen
                                    (\nLines ->
                                        Task.andThen
                                            (\_ ->
                                                Task.map
                                                    (\_ ->
                                                        String.append "wrote "
                                                            (String.append (String.fromInt nLines) " lines")
                                                    )
                                                    (Io.writeString "NATIVEIO-OK\n")
                                            )
                                            (Io.writeFile outPath (numbered 1 (Str.lines contents)))
                                    )
                                    (Task.succeed (countReal (Str.lines contents)))
                            )
                            (Io.readFile inPath)
                    )
                    (Io.getenv "ELMC_OUT")
            )
            (Io.getenv "ELMC_IN")
        )
    )


-- Line-number the split lines 1-based ("n: line\n").  Str.lines is Go
-- strings.Split parity: a trailing \n yields one trailing "" segment, which
-- is NOT a line (real Elm String.lines / nl(1) semantics) — skip it.
numbered n lines =
    case lines of
        line :: rest ->
            let
                row =
                    if line == "" && rest == [] then
                        ""

                    else
                        String.append (String.fromInt n)
                            (String.append ": " (String.append line "\n"))
            in
            String.append row (numbered (n + 1) rest)

        [] ->
            ""


-- Segments the split produced (trailing "" after a final \n is NOT a line):
-- segments minus one when the source ends with a newline.
countReal lines =
    case lines of
        [] ->
            0

        _ :: rest ->
            if lastIsNothing lines then
                Prelude.length lines - 1

            else
                Prelude.length lines


lastIsNothing lines =
    case lines of
        [] ->
            True

        _ :: rest ->
            lastIsNothing rest


update msg model =
    case msg of
        Done status ->
            ( status, Cmd.none )
