module LgUnit exposing (main)

-- S2 gate (main : String): byte-exact pure renders from core-libs/Lipgloss.elm.
-- Each test is one logical line (joined with "\n"); multi-line boxes therefore
-- span several physical lines.  ESC bytes are PRODUCED by the renderer (never
-- literal in this file) and reach stdout raw inside the printed quoted string,
-- exactly like teaunit.  expected/lgunit.txt is the byte-exact dump.


main =
    String.join "\n"
        [ -- 1. SGR order: bold(1) italic(no) underline(4) reverse(no) blink(no)
          --    faint(no) fg(31) bg(48;2;1;2;3) underline(4 AGAIN — v1.1.0 quirk)
          --    strikethrough(no).
          Lipgloss.render
            (Lipgloss.underline True
                (Lipgloss.background (Lipgloss.ColorRgb 1 2 3)
                    (Lipgloss.foreground (Lipgloss.ColorAnsi 1)
                        (Lipgloss.bold True Lipgloss.newStyle)
                    )
                )
            )
            "x"
        , -- 2. color parser: RGB, ANSI256, ANSI16, no color
          Lipgloss.render (Lipgloss.foreground (Lipgloss.color "#0000ff") Lipgloss.newStyle) "r"
        , Lipgloss.render (Lipgloss.foreground (Lipgloss.color "21") Lipgloss.newStyle) "a"
        , Lipgloss.render (Lipgloss.foreground (Lipgloss.color "5") Lipgloss.newStyle) "b"
        , Lipgloss.render (Lipgloss.foreground Lipgloss.noColor Lipgloss.newStyle) "n"
        , -- 6. padding + width (left pad, right pad, then align to width)
          Lipgloss.render (Lipgloss.setWidth 5 (Lipgloss.paddingLeft 1 (Lipgloss.paddingRight 1 Lipgloss.newStyle))) "ab"
        , -- 7. right align
          Lipgloss.render (Lipgloss.setWidth 5 (Lipgloss.alignHorizontal Lipgloss.PRight Lipgloss.newStyle)) "ab"
        , -- 8. center align
          Lipgloss.render (Lipgloss.setWidth 5 (Lipgloss.alignHorizontal Lipgloss.PCenter Lipgloss.newStyle)) "ab"
        , -- 9. normal border box
          Lipgloss.render (Lipgloss.border Lipgloss.normalBorder Lipgloss.newStyle) "abc"
        , -- 10. rounded border box
          Lipgloss.render (Lipgloss.border Lipgloss.roundedBorder Lipgloss.newStyle) "abc"
        , -- 11. corner matrix: top+bottom only (no left/right)
          Lipgloss.render (Lipgloss.borderTop True (Lipgloss.borderBottom True (Lipgloss.borderStyle Lipgloss.normalBorder Lipgloss.newStyle))) "abc"
        , -- 12. margins with marginBg
          Lipgloss.render (Lipgloss.margin 1 (Lipgloss.marginBackground (Lipgloss.ColorAnsi 4) Lipgloss.newStyle)) "x"
        , -- 13. maxWidth truncation
          Lipgloss.render (Lipgloss.maxWidth 3 Lipgloss.newStyle) "abcdef"
        , -- 14. maxHeight first-N-lines
          Lipgloss.render (Lipgloss.maxHeight 2 Lipgloss.newStyle) "a\nb\nc"
        , -- 15. joinHorizontal (top)
          Lipgloss.joinHorizontal Lipgloss.PTop [ "a", "b\nc" ]
        , -- 16. joinVertical (left)
          Lipgloss.joinVertical Lipgloss.PLeft [ "a\nb", "c" ]
        , -- 17. placeHorizontal (left)
          Lipgloss.placeHorizontal 5 Lipgloss.PLeft "ab"
        , -- 18. placeVertical (top)
          Lipgloss.placeVertical 3 Lipgloss.PTop "x"
        , -- 19. width / height / size
          String.fromInt (Lipgloss.width "abc")
        , String.fromInt (Lipgloss.height "a\nb")
        , String.fromInt (Tuple.first (Lipgloss.size "a\nbb"))
        , String.fromInt (Tuple.second (Lipgloss.size "a\nbb"))
        , -- 23. CJK box width (U+4E00 = 2 cells)
          Lipgloss.render (Lipgloss.border Lipgloss.normalBorder Lipgloss.newStyle) "\u{4E00}"
        , -- 24. word wrap: greedy break at the space (width 5), the space at
          --    the break dropped, lines padded to width
          Lipgloss.render (Lipgloss.setWidth 5 Lipgloss.newStyle) "ab cd ef"
        , -- 25. hard break of an over-limit word (width 3)
          Lipgloss.render (Lipgloss.setWidth 3 Lipgloss.newStyle) "abcdef"
        , -- 26. SGR carry across a wrap break: the active fg is reset at EOL
          --    with x/ansi's "\e[m" and re-emitted at BOL
          Lipgloss.render (Lipgloss.setWidth 4 Lipgloss.newStyle)
            (Lipgloss.render (Lipgloss.foreground (Lipgloss.color "1") Lipgloss.newStyle) "abcdef")
        , -- 27. stacked SGR carry: bold + fg from TWO sequences accumulate in
          --    the pen and re-emit together ("\e[1;31m") at the BOL
          Lipgloss.render (Lipgloss.setWidth 4 Lipgloss.newStyle)
            (Lipgloss.render (Lipgloss.bold True Lipgloss.newStyle)
                (Lipgloss.render (Lipgloss.foreground (Lipgloss.color "1") Lipgloss.newStyle) "abcdef")
            )
        ]
