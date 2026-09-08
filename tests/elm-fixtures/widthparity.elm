module WidthParity exposing (main)

-- P2 photon-gui: cell-width PARITY fixture (frozen contract: the GUI
-- renderer's src/renderer/width.zig must match Str.width EXACTLY).
--
-- Three-layer parity, this fixture is the cross layer: it asserts the
-- representative classes (ASCII, CJK/kana/fullwidth, combining/zero-width,
-- box-drawing borders, control bytes, ANSI CSI/OSC skip, emoji+VS16, ZWJ
-- family, range edges, truncate walk) through the REAL Str.width in the elm
-- gate, printing one bit per assert joined with "|".  The SAME numbers are
-- pinned Zig-side in src/renderer/width_test.zig; the TABLES are byte-gated
-- by tools/genwidth.zig (zig build width-check), so neither side can drift.
--
-- Wired as `run widthparity main` in run-elm-gate.sh; expected/widthparity.txt
-- must be all ones — any bit 0 is a live Elm-vs-Zig width divergence.


main =
    Platform.program { init = init, update = update, subscriptions = \_ -> Sub.none }


b cond =
    if cond then
        "1"

    else
        "0"


init () =
    ( String.join "|"
        [ -- ASCII = 1 cell
          b (Str.width "hello" == 5)
        , -- CJK / kana / fullwidth = 2 cells
          b (Str.width "漢字テスト" == 10)
        , b (Str.width "ＡＢ" == 4)
        , -- combining + zero-width = 0 cells
          b (Str.width "e\u{0301}" == 1)
        , b (Str.width "a\u{200D}b" == 2)
        , b (Str.width "👍\u{FE0F}" == 2)
        , -- box-drawing (Lipgloss borders) = 1, mixed with wide
          b (Str.width "┌─┐" == 3)
        , b (Str.width "│漢│" == 4)
        , -- control bytes = 0 cells
          b (Str.width "a\tb" == 2)
        , b (Str.width "\n" == 0)
        , b (Str.width "a\u{7F}b" == 2)
        , -- ANSI CSI + OSC sequences are zero-width
          b (Str.width "\u{1B}[31mred\u{1B}[0m" == 3)
        , b (Str.width "\u{1B}]8;;x\u{7}link\u{1B}]8;;\u{7}" == 4)
        , b (Str.width "\u{1B}]8;;x\u{1B}\\link" == 5)
        , -- emoji = 2; ZWJ family overcounts per code point (documented)
          b (Str.width "🦊" == 2)
        , b (Str.width "👨\u{200D}👩\u{200D}👧" == 6)
        , -- range edges: first cp past wideRanges entries = 1
          b (Str.width "\u{1160}" == 1)
        , b (Str.width "\u{FF61}" == 1)
        , -- truncate walk == the Zig advance cut point: escape + 2 cells
          b (Str.truncate 2 "\u{1B}[1;31mabc\u{1B}[0m" == "\u{1B}[1;31mab\u{1B}[0m")
        , b (Str.width (Str.truncate 3 "a漢b") == 3)
        ]
    , Cmd.none
    )


type Msg
    = Never


update msg model =
    case msg of
        Never ->
            ( model, Cmd.none )
