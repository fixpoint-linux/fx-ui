module VpUnit exposing (main)

-- S4 gate (main : String): core-libs/Viewport.elm (bubbles viewport, scroll
-- subset).  Byte-exact PLAIN renders at a fixed size (5-wide ASCII lines need
-- no padding, so the vertical-scroll expected strings are just the joined
-- line triples), x-scroll through the Str.cut window, and scroll states via
-- `update` folds (real keymap keys) and the scroll/mouse ops.  `==` flags pin
-- the frame arithmetic (maxYOffset/maxXOffset), the init defaults, and the
-- boundary predicates.  A rounded-border + padding render is included and
-- byte-pinned by eye against the gate-proven Lipgloss border (no hand-composed
-- SGR — plain box-drawing border chars).
--
-- All record-updating helpers are ANNOTATED (the S2 lesson: a multi-field
-- update on an unannotated base fails at the second field).

import Lipgloss exposing (border, newStyle, padding, roundedBorder)
import Str exposing (repeat, width)

f x =
  case x of
    True ->
      "1"

    False ->
      "0"


setStyle : Lipgloss.Style -> Viewport.Model -> Viewport.Model
setStyle st m =
  { m | style = st }


setWheel : Bool -> Viewport.Model -> Viewport.Model
setWheel b m =
  { m | mouseWheelEnabled = b }


main =
  let
    -- 8 lines, 5 cells each -> no padding in a 5-wide viewport
    vlines =
      "aaaaa\nbbbbb\nccccc\nddddd\neeeee\nfffff\nggggg\nhhhhh"

    v =
      Viewport.setContent vlines (Viewport.init 5 3)

    -- plain vertical renders (height 3)
    vTop =
      Viewport.view v

    vDown =
      Viewport.view (Viewport.update (KeyChar "j") v)

    vDown2 =
      Viewport.view (Viewport.scrollDown 2 v)

    vBot =
      Viewport.view (Viewport.gotoBottom v)

    vPageDown =
      Viewport.view (Viewport.pageDown v)

    vPageUp =
      Viewport.view (Viewport.pageUp (Viewport.gotoBottom v))

    vHalfDown =
      Viewport.view (Viewport.halfPageDown v)

    vPgDnKey =
      Viewport.view (Viewport.update KeyPgDn v)

    vSpaceKey =
      Viewport.view (Viewport.update (KeyChar " ") v)

    vPgUpKey =
      Viewport.view (Viewport.update (KeyChar "b") (Viewport.gotoBottom v))

    vNoop =
      Viewport.view (Viewport.update (KeyChar "z") (Viewport.gotoBottom v))

    -- x-scroll: a 20-cell line in a 10-wide viewport
    xlines =
      "0123456789abcdefghij"

    x =
      Viewport.setContent xlines (Viewport.init 10 1)

    xTop =
      Viewport.view x

    xStep =
      Viewport.view (Viewport.setXOffset 6 x)

    xMax =
      Viewport.view (Viewport.setXOffset 99 x)

    xRight =
      Viewport.view (Viewport.update (KeyChar "l") x)

    xBack =
      Viewport.view (Viewport.update (KeyChar "h") (Viewport.update (KeyChar "l") x))

    xAtMax =
      Viewport.view (Viewport.scrollRight 6 (Viewport.scrollRight 6 x))

    -- mouse wheel folds (delta 3)
    wDownModel =
      Viewport.updateMouse (MouseMsg MouseWheel MouseWheelDown 0 0) v

    wDown =
      Viewport.view wDownModel

    wUp =
      Viewport.view
        (Viewport.updateMouse (MouseMsg MouseWheel MouseWheelUp 0 0) wDownModel)

    wDisabled =
      Viewport.view
        (Viewport.updateMouse (MouseMsg MouseWheel MouseWheelDown 0 0) (setWheel False v))

    wNoise =
      Viewport.view (Viewport.updateMouse (MouseMsg MousePress MouseLeft 1 1) v)

    -- default init values
    d =
      Viewport.init 12 7

    -- frame arithmetic: border + padding -> vertical frame 4, horizontal 4
    framedStyle =
      Lipgloss.border Lipgloss.roundedBorder (Lipgloss.padding 1 Lipgloss.newStyle)

    fv =
      Viewport.setContent "one\ntwo\nthree\nfour\nfive\nsix"
        (setStyle framedStyle (Viewport.init 8 6))

    framed =
      Viewport.view fv

    flags =
      String.join ""
        [ f (d.width == 12)
        , f (d.height == 7)
        , f (not d.softWrap)
        , f (not d.fillHeight)
        , f d.mouseWheelEnabled
        , f (d.mouseWheelDelta == 3)
        , f (d.horizontalStep == 6)
        , f (d.yOffset == 0)
        , f (d.xOffset == 0)
        , f (d.longestLineWidth == 0)
        , f (Viewport.maxYOffset v == 5)
        , f (Viewport.maxXOffset x == 10)
        , f (Viewport.maxYOffset fv == 4)
        , f (Viewport.atTop v)
        , f (not (Viewport.atBottom v))
        , f (Viewport.atBottom (Viewport.gotoBottom v))
        , f (Viewport.yOffset (Viewport.gotoBottom v) == 5)
        , f (Viewport.xOffset (Viewport.setXOffset 99 x) == 10)
        , f (x.longestLineWidth == 20)
        , f (vTop == "aaaaa\nbbbbb\nccccc")
        , f (vDown == "bbbbb\nccccc\nddddd")
        , f (vDown2 == "ccccc\nddddd\neeeee")
        , f (vBot == "fffff\nggggg\nhhhhh")
        , f (vPageDown == "ddddd\neeeee\nfffff")
        , f (vPageUp == "ccccc\nddddd\neeeee")
        , f (vHalfDown == "bbbbb\nccccc\nddddd")
        , f (vPgDnKey == "ddddd\neeeee\nfffff")
        , f (vSpaceKey == "ddddd\neeeee\nfffff")
        , f (vPgUpKey == "ccccc\nddddd\neeeee")
        , f (vNoop == "fffff\nggggg\nhhhhh")
        , f (xTop == "0123456789")
        , f (xStep == "6789abcdef")
        , f (xMax == "abcdefghij")
        , f (xRight == "6789abcdef")
        , f (xBack == "0123456789")
        , f (xAtMax == "abcdefghij")
        , f (wDown == "ddddd\neeeee\nfffff")
        , f (wUp == "aaaaa\nbbbbb\nccccc")
        , f (wDisabled == "aaaaa\nbbbbb\nccccc")
        , f (wNoise == "aaaaa\nbbbbb\nccccc")
        , f (Lipgloss.width framed == 8)
        , f (framed == "╭──────╮\n│      │\n│ one  │\n│ two  │\n│      │\n╰──────╯")
        ]
  in
  String.join "|"
    [ flags
    , vTop
    , vBot
    , xTop
    , xStep
    , xMax
    , framed
    ]
