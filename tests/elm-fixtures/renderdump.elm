module RenderDump exposing (main)

-- P1 photon-gui gate: the Elm-built DrawList is the Elm<->host render API.
--
-- TWO oracles over one fixture (checks wired as `renderdump` in
-- run-elm-gate.sh: elmvm --render-dump, stdout+stderr compared against
-- expected/renderdump.txt):
--
-- 1. SELF-ORACLE (Elm-side, asserted in the final model): the round-trip
--    render -> Draw.fromAnsi -> Draw.toAnsi -> fromAnsi is the identity
--    (frameEq), and Draw.dumpFrame pins the DECODED STRUCTURE of a real
--    Lipgloss render (bold cyan fg-4 box line + reset + 256-color fg-212 /
--    RGB bg span) and of a hand-written ANSI row (multi-param SGR, empty
--    row kept as an empty row for frame geometry).
--
-- 2. HOST ORACLE (Zig-side, stderr): the same frames submitted through
--    Io.renderFrame cross the seam as TaskRender ctor vectors; the host
--    leafRender decodes them (cons list of Span ctor vectors, symSlice tag
--    compare) and --render-dump dumps the decoded structure to stderr.
--
-- The stdout model line + the two frame dumps together are byte-pinned by
-- expected/renderdump.txt.


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


-- A real Lipgloss render (bold + fg 4 cyan, then a 256-color fg-212 span on
-- an RGB bg) split into view rows by the Tea contract.
lipView =
    Str.lines
        (Lipgloss.render
            (Lipgloss.foreground (Lipgloss.ColorAnsi 4)
                (Lipgloss.bold True
                    (Lipgloss.foreground (Lipgloss.ColorAnsi 212)
                        (Lipgloss.background (Lipgloss.ColorRgb 10 20 30) Lipgloss.newStyle)
                    )
                )
            )
            "ab cd"
        )


-- Hand-written ANSI rows: multi-param SGR in canonical order, a skipped
-- non-SGR escape (\e[2K — the Tea clear-line), and an empty row.
handView =
    [ "\u{1B}[1;38;5;196;48;2;1;2;3mXY\u{1B}[0m plain \u{1B}[2K\u{1B}[4mu\u{1B}[0m"
    , ""
    ]


frameA =
    Draw.fromAnsi lipView


frameB =
    Draw.fromAnsi handView


-- The expected decoded structures (pinned by hand; Draw.dumpFrame output).
-- frameA: the Lipgloss style is ONE style (outer foreground 4 wins over the
-- nested 212; bg RGB(10,20,30) packs to 17437726 = 0x10A141E) -> one span.
-- frameB: SGR 1 + 38;5;196 + 48;2;1;2;3 -> one span (bg packs to 16843267);
-- the reset splits the run, \e[2K is skipped WITHOUT splitting, the next SGR
-- splits again -> three spans; the empty second string stays an empty row.
dumpA =
    "r0: fg=4 bg=17437726 attrs=1 \"ab cd\""


dumpB =
    String.join "\n"
        [ "r0: fg=196 bg=16843267 attrs=1 \"XY\" | fg=-1 bg=-1 attrs=0 \" plain \" | fg=-1 bg=-1 attrs=8 \"u\""
        , "r1: "
        ]


b cond =
    if cond then
        "1"

    else
        "0"


init () =
    ( String.join "|"
        [ -- self-oracle: round-trip identity on BOTH frames
          b (Draw.frameEq (Draw.fromAnsi (Draw.toAnsi frameA)) frameA)
        , b (Draw.frameEq (Draw.fromAnsi (Draw.toAnsi frameB)) frameB)
        , -- structure oracle: the decoded Frame matches the hand-pinned dump
          b (Draw.dumpFrame frameA == dumpA)
        , b (Draw.dumpFrame frameB == dumpB)
        ]
    , Cmd.batch
        [ Task.perform GotA (Io.renderFrame frameA)
        , Task.perform GotB (Io.renderFrame frameB)
        ]
    )


type Msg
    = GotA ()
    | GotB ()


update msg model =
    case msg of
        GotA _ ->
            ( model, Cmd.none )

        GotB _ ->
            ( model, Cmd.none )
