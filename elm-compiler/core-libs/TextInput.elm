module TextInput
  exposing
    ( Model
    , init
    , update
    , view
    )

-- M1 textinput widget (charmbracelet/bubbletea's textinput, subset-ported
-- over the Tea core loop).  The model IS the typed value (single line);
-- `view` renders it as ONE terminal row ending in a reverse-video block
-- cursor — the ANSI the PTY gate asserts on.
--
-- Subset deviations from real bubbletea, all forced by the checker surface
-- (same class as Tea.elm's):
--   * no cursor-position state — the block cursor always sits at the END of
--     the value (free cursor movement is M2);
--   * only KeyChar insert + KeyBackspace delete are handled; every other key
--     passes the model through unchanged (the app's update decides quit etc.).


{-| The widget state: just the current value.
-}
type alias Model =
  String


init =
  ""


{-| Handle one key: printable characters append, backspace drops the last
character (a no-op on the empty value), everything else is ignored.
-}
update key model =
  case key of
    KeyChar c ->
      String.append model c

    KeyBackspace ->
      backspace model

    _ ->
      model


backspace model =
  if String.length model > 0 then
    -- String.sliceLen is (start, LEN, str) — NOT real Elm's String.slice
    -- (start, end, str); the exposed surface is named sliceLen (see
    -- Lower.Resolve.primDotAliases) so the divergence is never silent.
    String.sliceLen 0 (String.length model - 1) model

  else
    model


{-| Render the value as one row ending in a reverse-video space (the block
cursor); \e[0m resets so the cursor never bleeds into following bytes.
-}
view model =
  [ String.append model "\u{1B}[7m \u{1B}[0m" ]
