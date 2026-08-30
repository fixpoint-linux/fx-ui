module SpinUnit exposing (main)

-- S3 gate (main : String): core-libs/Spinner.elm (bubbles spinner).  The
-- joined rows pin: the fpsMs floors of Go's time.Second/N (1000/12 -> 83,
-- 1000/7 -> 142, 1000/3 -> 333), BYTE-EXACT frames of all six presets (Dot's
-- trailing spaces + MiniDot braille are Go parity), the update-fold advance
-- and the wrap back to frame 0 (line 4-tick cycle, Dot 8-tick, Ellipsis "" ->
-- "." -> ".." -> "..."), the "(error)" guard on an out-of-range frame, and a
-- styled render (fg SGR pair through Lipgloss, real \e bytes).  `update` is
-- driven with the qualified ctor `Spinner.Tick` (corpus ctors resolve ONLY
-- qualified cross-module — the S2 lesson).

import Lipgloss
import Spinner exposing (dot, ellipsis, init, line, miniDot, points, pulse, update, view)


f x =
  case x of
    True ->
      "1"

    False ->
      "0"


-- annotated single-field helpers (the S2 lesson)


setSpinner : Spinner.Spinner -> Spinner.Model -> Spinner.Model
setSpinner sp m =
  { m | spinner = sp }


setStyle : Lipgloss.Style -> Spinner.Model -> Spinner.Model
setStyle st m =
  { m | style = st }


setFrame : Int -> Spinner.Model -> Spinner.Model
setFrame i m =
  { m | frame = i }


frameOf : Spinner.Model -> String
frameOf m =
  String.join "" (view m)


advance : Spinner.Model -> Spinner.Model
advance m =
  update Spinner.Tick m


main =
  let
    -- fpsMs floors: Go time.Second/10 /12 /8 /7 /3
    ln =
      line

    dt =
      dot

    md =
      miniDot

    rates =
      String.join ","
        [ String.fromInt ln.fpsMs
        , String.fromInt dt.fpsMs
        , String.fromInt md.fpsMs
        , String.fromInt pulse.fpsMs
        , String.fromInt points.fpsMs
        , String.fromInt ellipsis.fpsMs
        ]

    -- line cycle: frames 0-3 then the 4th tick WRAPS back to frame 0
    l1 =
      advance init

    l2 =
      advance l1

    l3 =
      advance l2

    l4 =
      advance l3

    lineCycle =
      String.join "," [ frameOf init, frameOf l1, frameOf l2, frameOf l3, frameOf l4 ]

    -- out-of-range frame -> the literal guard text
    guard =
      frameOf (setFrame 99 init)

    -- dot: full 8-frame cycle (braille + trailing space) + the wrap tick
    d0 =
      setSpinner dot init

    d1 =
      advance d0

    d2 =
      advance d1

    d3 =
      advance d2

    d4 =
      advance d3

    d5 =
      advance d4

    d6 =
      advance d5

    d7 =
      advance d6

    d8 =
      advance d7

    dotCycle =
      String.join ","
        [ frameOf d0
        , frameOf d1
        , frameOf d2
        , frameOf d3
        , frameOf d4
        , frameOf d5
        , frameOf d6
        , frameOf d7
        , frameOf d8
        ]

    -- miniDot: first three braille frames
    n0 =
      setSpinner miniDot init

    n1 =
      advance n0

    n2 =
      advance n1

    miniCycle =
      String.join "," [ frameOf n0, frameOf n1, frameOf n2 ]

    -- pulse: full 4-frame cycle (the shade blocks)
    p0 =
      setSpinner pulse init

    p1 =
      advance p0

    p2 =
      advance p1

    p3 =
      advance p2

    pulseCycle =
      String.join "," [ frameOf p0, frameOf p1, frameOf p2, frameOf p3 ]

    -- points: full 4-frame cycle
    q0 =
      setSpinner points init

    q1 =
      advance q0

    q2 =
      advance q1

    q3 =
      advance q2

    pointsCycle =
      String.join "," [ frameOf q0, frameOf q1, frameOf q2, frameOf q3 ]

    -- ellipsis: full 4-frame cycle — frame 0 is the EMPTY string, so the
    -- joined row starts with a comma
    e0 =
      setSpinner ellipsis init

    e1 =
      advance e0

    e2 =
      advance e1

    e3 =
      advance e2

    ellipsisCycle =
      String.join "," [ frameOf e0, frameOf e1, frameOf e2, frameOf e3 ]

    -- styled render: pulse frame 0 through an fg-only Lipgloss style — the
    -- SAME SGR spelling the gate-proven Lipgloss emits (\e[38;2;R;G;Bm ...\e[0m)
    red =
      Lipgloss.foreground (Lipgloss.color "#FF0000") Lipgloss.newStyle

    styled =
      frameOf (setStyle red p0)
  in
  String.join "\n"
    [ rates
    , lineCycle
    , guard
    , dotCycle
    , miniCycle
    , pulseCycle
    , pointsCycle
    , ellipsisCycle
    , styled
    ]
