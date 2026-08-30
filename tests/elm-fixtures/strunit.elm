module StrUnit exposing (main)

-- S1 gate (main : String): the core-libs/Str.elm toolkit + Prelude.List.take.
-- Every check contributes a "1"/"0" flag to one concatenated digit string
-- (hand-derived from the runewidth tables and Go/x-ansi parity documented in
-- Str.elm; position = declaration order below), then three VISIBLE strings
-- (fromFloat 42.5/2.0 via the trusted `str` prim, and a cell-width pad over
-- U+4E00) joined with "|".  ESC/OSC/BEL bytes only ever live INSIDE the
-- program (compared via ==) — nothing non-printing reaches stdout.


f x =
    case x of
        True ->
            "1"

        False ->
            "0"


main =
    let
        flags =
            String.join ""
                [ -- width: ASCII, CJK U+4E00 = 2 cells, mixed, combining
                  -- U+0301 = 0, emoji U+1F600 = 2, Hangul U+AC00 = 2,
                  -- fullwidth U+FF21 = 2, empty = 0
                  f (Str.width "hello" == 5)
                , f (Str.width "\u{4E00}\u{4E00}" == 4)
                , f (Str.width "a\u{4E00}b" == 4)
                , f (Str.width "e\u{0301}" == 1)
                , f (Str.width "\u{1F600}" == 2)
                , f (Str.width "\u{AC00}" == 2)
                , f (Str.width "\u{FF21}" == 2)
                , f (Str.width "" == 0)

                -- width skips ANSI: CSI (SGR) and OSC (hyperlink, BEL-terminated)
                , f (Str.width "\u{1B}[31mab\u{1B}[0m" == 2)
                , f (Str.width "\u{1B}]8;;x\u{7}ok\u{1B}]8;;\u{7}" == 2)

                -- split: basic, trailing sep (trailing ""), empty input,
                -- multi-byte sep, absent sep
                , f (Str.split "," "a,b,,c" == [ "a", "b", "", "c" ])
                , f (Str.split "," "a," == [ "a", "" ])
                , f (Str.split "," "" == [ "" ])
                , f (Str.split ",," "a,,b" == [ "a", "b" ])
                , f (Str.split "xyz" "abc" == [ "abc" ])

                -- lines: Go strings.Split(s, "\n") parity (trailing \n keeps "")
                , f (Str.lines "a\nb\nc" == [ "a", "b", "c" ])
                , f (Str.lines "a\n" == [ "a", "" ])

                -- repeat: n>0, n==0, wide content
                , f (Str.repeat 3 "ab" == "ababab")
                , f (Str.repeat 0 "x" == "")
                , f (Str.repeat 2 "\u{4E00}" == "\u{4E00}\u{4E00}")

                -- pad to CELL width (padLeft 4 "中" needs only 2 spaces)
                , f (Str.padLeft 3 "ab" == " ab")
                , f (Str.padRight 3 "ab" == "ab ")
                , f (Str.padLeft 4 "\u{4E00}" == "  \u{4E00}")
                , f (Str.padLeft 1 "abc" == "abc")
                , f (Str.padRight 0 "abc" == "abc")

                -- truncate: plain cut, no-op when it fits, SGR-preserving cut
                -- (+ reset), no cut inside a wide rune
                , f (Str.truncate 2 "abcde" == "ab")
                , f (Str.truncate 10 "abc" == "abc")
                , f (Str.truncate 2 "\u{1B}[31mabc\u{1B}[0m" == "\u{1B}[31mab\u{1B}[0m")
                , f (Str.truncate 3 "a\u{4E00}b" == "a\u{4E00}")
                , f (Str.truncate 3 "\u{4E00}\u{4E00}" == "\u{4E00}")

                -- replace: multi-hit, absent needle, the lipgloss \r\n -> \n use
                , f (Str.replace "o" "0" "foo boo" == "f00 b00")
                , f (Str.replace "z" "q" "abc" == "abc")
                , f (Str.replace "\r\n" "\n" "a\r\nb" == "a\nb")

                -- affixes
                , f (Str.startsWith "ab" "abc")
                , f (not (Str.startsWith "bc" "abc"))
                , f (Str.endsWith "bc" "abc")
                , f (Str.endsWith "" "abc")

                -- trim (ASCII whitespace both ends)
                , f (Str.trim "  a b  " == "a b")
                , f (Str.trim "\t\r\n x \n" == "x")
                , f (Str.trim "   " == "")

                -- countChar
                , f (Str.countChar '\n' "a\nb\nc" == 2)
                , f (Str.countChar 'x' "abc" == 0)

                -- List.take (the new Prelude mirror of drop) + drop regression
                , f (List.take 2 [ 1, 2, 3 ] == [ 1, 2 ])
                , f (List.take 9 [ 1, 2 ] == [ 1, 2 ])
                , f (List.take (0 - 1) [ 1, 2 ] == [])
                , f (List.take 1 [] == [])
                , f (List.drop 9 [ 1, 2 ] == [])

                -- fromFloat: shortest-roundtrip + mandatory ".0" when integral
                , f (Str.fromFloat 42.5 == "42.5")
                , f (Str.fromFloat 2.0 == "2.0")
                ]
    in
    String.join "|"
        [ flags
        , Str.fromFloat 42.5
        , Str.fromFloat 2.0
        , Str.padLeft 4 "\u{4E00}"
        ]
