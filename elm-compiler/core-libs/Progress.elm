module Progress
  exposing
    ( Model
    , new
    , viewAs
    )

-- M-WIDGETS S2: charmbracelet/bubbles' progress package, subset-ported —
-- the STATIC render only (Go's ViewAs): a solid-fill bar + optional
-- percentage.  Pure: nothing here needs the host.
--
-- Go parity notes (against progress.go master):
--  * ViewAs(percent) = barView(...) ++ percentageView(...), with the bar's
--    total width reduced by the CELL width of the rendered percentage
--    (ansi.StringWidth -> Str.width).
--  * barView solid-fill branch (the only one ported): filled =
--    FullStyle.Render(strings.Repeat(Full, fw)), empty =
--    EmptyStyle.Render(strings.Repeat(Empty, tw - fw)).  Zero-width renders
--    still emit the SGR pair (both in Go termenv and in our Lipgloss).
--  * percentageView clamps the percentage to [0,1] for DISPLAY; barView
--    does not clamp the input but clamps fw to [0, tw] — for the integer
--    permil below the two clamp sites are provably equivalent, so we clamp
--    the permil once up front.
--  * New(): width 40, Full '▌' (half block), Empty '░', colors
--    #7571F9 (blueberry) / #606060 (slate gray), percentage ON with format
--    " %3.0f%%" -> " " + padLeft 3 + "%".
--
-- DEVIATIONS (the documented integer model — NO float prims exist):
--  * percent is an INTEGER PERMILLE (0..1000) instead of a float 0..1; the
--    filled width truncates: fw = tw * permil // 1000 (Go rounds a float,
--    math.Round — differs by at most one cell off the exact fraction).
--  * the displayed percentage is permil // 10, truncating (Go's %3.0f
--    rounds): 55.5% renders as 55%, not 56%.
--  * NO spring animation / FrameMsg / SetPercent (harmonica needs floats),
--    NO blend/gradient fills or ColorFunc (lipgloss.Blend1D is not ported),
--    NO PercentageStyle — the percentage renders plain, and there is no
--    separate Update: callers just viewAs a new permil.

{-| The bar state (Go progress.Model, static subset).
-}
type alias Model =
  { width : Int
  , full : String
  , fullColor : Lipgloss.Color
  , empty : String
  , emptyColor : Lipgloss.Color
  , showPercentage : Bool
  }


{-| New with Go's defaults (Go progress.go:232-243).
-}
new : Model
new =
  { width = 40
  , full = "▌"
  , fullColor = Lipgloss.ColorRgb 117 113 249
  , empty = "░"
  , emptyColor = Lipgloss.ColorRgb 96 96 96
  , showPercentage = True
  }


{-| ViewAs renders the bar at the given permille (0..1000; values outside
clamp, as Go's float path clamps into [0,1]).
-}
viewAs : Int -> Model -> String
viewAs permil m =
  let
    pv =
      percentageView permil m
  in
  String.append (barView permil m (Str.width pv)) pv


{-| The numeric tail, " NNN%" (Go progress.go:423-431 with the fixed
" %3.0f%%" format; PercentageStyle is not ported).
-}
percentageView : Int -> Model -> String
percentageView permil m =
  if not m.showPercentage then
    ""

  else
    let
      n =
        String.fromInt (clamp 0 1000 permil // 10)
    in
    String.append " " (String.append (Str.padLeft 3 n) "%")


{-| The bar itself (Go progress.go:357-421, solid branch): tw is the bar
width after reserving the percentage's cells, fw the filled cell count.
-}
barView : Int -> Model -> Int -> String
barView permil m textWidth =
  let
    tw =
      max 0 (m.width - textWidth)

    fw =
      clamp 0 tw (tw * clamp 0 1000 permil // 1000)

    solid =
      Lipgloss.render (Lipgloss.foreground m.fullColor Lipgloss.newStyle)
        (Str.repeat fw m.full)

    void =
      Lipgloss.render (Lipgloss.foreground m.emptyColor Lipgloss.newStyle)
        (Str.repeat (max 0 (tw - fw)) m.empty)
  in
  String.append solid void
