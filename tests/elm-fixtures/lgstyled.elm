module LgStyled exposing (main)

-- P3 (photon-gui) gate: Lipgloss.renderStyled — style-as-data (Draw spans),
-- no ANSI produced or parsed.  The ORACLE is the existing ANSI path: for
-- every case below,
--
--     Draw.frameEq (Draw.fromAnsi [ Lipgloss.render s str ])
--                  [ Lipgloss.renderStyled s str ]
--
-- must hold (renderStyled must split/restyle runs exactly as fromAnsi would
-- split the ANSI render emits: whole-line te pair, per-rune space styler,
-- nested mid-string SGR).  Coverage: bold / ANSI fg (incl. bright + the
-- packed-0-not--1 black case) / 256 bg / RGB fg+bg / full attr stack (no
-- underline -> whole-line path), underline space-styler mid-string (per-rune
-- spans, bare-run merging), underlineSpaces / strikethroughSpaces (empty teP),
-- nested render mid-string, setString value prefix, props==0 plain shortcut,
-- tab conversion (plain + styled), CJK runes under the space styler, empty
-- strings both paths, and a props/=0 teP-empty renders-plain case.  The pins
-- section dumpFrames a few renderStyled outputs so the equality cannot pass
-- vacuously (span structure + packed ints are byte-pinned).


main =
    String.join "\n" (checkAll 0 cases ++ pins)


check : Int -> ( String, Lipgloss.Style, String ) -> String
check i ( name, s, str ) =
    let
        oracle =
            Draw.fromAnsi [ Lipgloss.render s str ]

        direct =
            [ Lipgloss.renderStyled s str ]
    in
    if Draw.frameEq oracle direct then
        "ok " ++ String.fromInt i ++ " " ++ name

    else
        "FAIL " ++ String.fromInt i ++ " " ++ name ++ "\n" ++ Draw.dumpFrame oracle ++ "\n--\n" ++ Draw.dumpFrame direct


cases : List ( String, Lipgloss.Style, String )
cases =
    let
        inner =
            Lipgloss.foreground (Lipgloss.ColorAnsi 6) (Lipgloss.bold True Lipgloss.newStyle)
    in
    [ ( "bold", Lipgloss.bold True Lipgloss.newStyle, "hello world" )
    , ( "fg-ansi", Lipgloss.foreground (Lipgloss.ColorAnsi 4) Lipgloss.newStyle, "cyan text" )
    , ( "fg-bright", Lipgloss.foreground (Lipgloss.ColorAnsi 12) Lipgloss.newStyle, "bright" )
    , ( "fg-black", Lipgloss.foreground (Lipgloss.ColorAnsi 0) Lipgloss.newStyle, "black" )
    , ( "bg-256", Lipgloss.background (Lipgloss.ColorAnsi256 212) Lipgloss.newStyle, "bg256" )
    , ( "rgb-both"
      , Lipgloss.background (Lipgloss.ColorRgb 10 20 30)
            (Lipgloss.foreground (Lipgloss.ColorRgb 200 100 50) Lipgloss.newStyle)
      , "truecolor"
      )
    , ( "stack-nound"
      , Lipgloss.strikethrough True
            (Lipgloss.background (Lipgloss.ColorAnsi 3)
                (Lipgloss.foreground (Lipgloss.ColorAnsi 9)
                    (Lipgloss.italic True
                        (Lipgloss.blink True
                            (Lipgloss.reverse True
                                (Lipgloss.faint True (Lipgloss.bold True Lipgloss.newStyle))
                            )
                        )
                    )
                )
            )
      , "all"
      )
    , ( "underline-spaces", Lipgloss.underline True Lipgloss.newStyle, "a b  c" )
    , ( "underline-fg", Lipgloss.foreground (Lipgloss.ColorAnsi 5) (Lipgloss.underline True Lipgloss.newStyle), "x y z" )
    , ( "ulspaces", Lipgloss.underlineSpaces True Lipgloss.newStyle, "a b" )
    , ( "strike-spaces", Lipgloss.strikethroughSpaces True Lipgloss.newStyle, "p q" )
    , ( "nested-mid", Lipgloss.foreground (Lipgloss.ColorAnsi 1) Lipgloss.newStyle, "a" ++ Lipgloss.render inner "mid" ++ "b" )
    , ( "value-prefix", Lipgloss.setString "P" (Lipgloss.bold True Lipgloss.newStyle), "x" )
    , ( "plain", Lipgloss.newStyle, "plain" )
    , ( "tab-plain", Lipgloss.newStyle, "\ta\tb" )
    , ( "tab-styled", Lipgloss.bold True Lipgloss.newStyle, "\tx" )
    , ( "cjk-underline", Lipgloss.underline True Lipgloss.newStyle, "中 文x" )
    , ( "empty-styled", Lipgloss.bold True Lipgloss.newStyle, "" )
    , ( "empty-plain", Lipgloss.newStyle, "" )
    , ( "cw-plain", Lipgloss.colorWhitespace False Lipgloss.newStyle, "cw" )
    ]


pins : List String
pins =
    [ Draw.dumpFrame [ Lipgloss.renderStyled (Lipgloss.bold True Lipgloss.newStyle) "hi" ]
    , Draw.dumpFrame [ Lipgloss.renderStyled (Lipgloss.underline True Lipgloss.newStyle) "a b" ]
    , Draw.dumpFrame
        [ Lipgloss.renderStyled
            (Lipgloss.background (Lipgloss.ColorRgb 10 20 30)
                (Lipgloss.foreground (Lipgloss.ColorRgb 200 100 50) Lipgloss.newStyle)
            )
            "x"
        ]
    , Draw.dumpFrame
        [ Lipgloss.renderStyled (Lipgloss.foreground (Lipgloss.ColorAnsi 1) Lipgloss.newStyle)
            ("a" ++ Lipgloss.render (Lipgloss.foreground (Lipgloss.ColorAnsi 6) (Lipgloss.bold True Lipgloss.newStyle)) "mid" ++ "b")
        ]
    ]


checkAll : Int -> List ( String, Lipgloss.Style, String ) -> List String
checkAll i cases =
    case cases of
        [] ->
            []

        c :: rest ->
            check i c :: checkAll (i + 1) rest
