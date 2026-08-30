module Help
  exposing
    ( Model
    , Styles
    , defaultStyles
    , fullHelpView
    , new
    , setWidth
    , shortHelpView
    , view
    )

-- M-WIDGETS S2: charmbracelet/bubbles' help package, subset-ported — renders
-- a keymap as a one-line short help or a multi-column full help, on top of
-- the Key (S1) + Lipgloss (foundation) widgets.
--
-- Go parity notes:
--  * KeyMap is an interface in Go; here `view` takes the two keymap slices
--    as plain arguments (List Binding, List (List Binding)) and dispatches
--    on showAll itself.
--  * ShortHelpView walks the bindings: disabled ones are skipped entirely
--    (the separator only ever appears BETWEEN rendered items), each rendered
--    item is `<shortKey> <shortDesc>` with the separator prepended from the
--    second item on.
--  * Truncation is ITEM-granular via shouldAddItem: when width > 0 and the
--    next item would overflow, the tail " <ellipsis>" is emitted only if it
--    itself fits STRICTLY (totalWidth + tailWidth < width) — otherwise the
--    overflowing item is still rendered whole (Go help.go:234-244).
--  * FullHelpView builds one column per group (groups with no enabled
--    binding are skipped): JoinHorizontal(Top, sep, keys, " ", descs) where
--    the key/desc blocks are each a newline-joined FullKey/FullDesc render
--    (non-inline — every line gets its own SGR pair), so both blocks align
--    to their widest line.  The final JoinHorizontal(Top, columns) stacks
--    the columns side by side.
--  * DefaultStyles(dark) colors: keys #626262, descs #4A4A4A, separators
--    #3C3C3C; light variants dropped (single dark palette — the LightDark
--    adaptive-color machinery is out of subset).
--  * Inline(true) is applied exactly where Go applies it: short key/desc/
--    separator/ellipsis renders (single-line, no width alignment); the full
--    column blocks render non-inline.
--
-- Deviations: PercentageStyle-equivalent niceties aside, the only structural
-- change is `width` being a plain model field set via setWidth (Go's private
-- field + SetWidth accessor).

{-| The seven render styles (Go help.Styles).
-}
type alias Styles =
  { ellipsis : Lipgloss.Style
  , shortKey : Lipgloss.Style
  , shortDesc : Lipgloss.Style
  , shortSeparator : Lipgloss.Style
  , fullKey : Lipgloss.Style
  , fullDesc : Lipgloss.Style
  , fullSeparator : Lipgloss.Style
  }


{-| The help view state (Go help.Model).
-}
type alias Model =
  { showAll : Bool
  , shortSeparator : String
  , fullSeparator : String
  , ellipsis : String
  , styles : Styles
  , width : Int
  }


{-| DefaultStyles(dark) — the dark palette (Go help.go:48-64).
-}
defaultStyles : Styles
defaultStyles =
  let
    keyStyle =
      Lipgloss.foreground (Lipgloss.color "#626262") Lipgloss.newStyle

    descStyle =
      Lipgloss.foreground (Lipgloss.color "#4A4A4A") Lipgloss.newStyle

    sepStyle =
      Lipgloss.foreground (Lipgloss.color "#3C3C3C") Lipgloss.newStyle
  in
  { ellipsis = sepStyle
  , shortKey = keyStyle
  , shortDesc = descStyle
  , shortSeparator = sepStyle
  , fullKey = keyStyle
  , fullDesc = descStyle
  , fullSeparator = sepStyle
  }


{-| New with Go's defaults (Go help.go:93-100).
-}
new : Model
new =
  { showAll = False
  , shortSeparator = " • "
  , fullSeparator = "    "
  , ellipsis = "…"
  , styles = defaultStyles
  , width = 0
  }


{-| SetWidth caps the rendered width (0 = unlimited).
-}
setWidth : Int -> Model -> Model
setWidth w m =
  { m | width = w }


{-| View renders short or full help according to showAll, taking the keymap
as its two slices (Go's KeyMap interface flattened).
-}
view : Model -> List Key.Binding -> List (List Key.Binding) -> String
view m short full =
  if m.showAll then
    fullHelpView m full

  else
    shortHelpView m short


{-| Render with the inline flag Go sets on every short-help style.
-}
renderInline : Lipgloss.Style -> String -> String
renderInline st s =
  Lipgloss.render (Lipgloss.inline True st) s


{-| Go lipgloss.Width for a BLOCK: the widest LINE (ansi.StringWidth per
line), not the sum — the full-help columns are multi-line, and the width
budget arithmetic must measure them exactly as Go does.
-}
blockWidth : String -> Int
blockWidth s =
  blockWidthLoop (Str.lines s) 0


blockWidthLoop : List String -> Int -> Int
blockWidthLoop ls acc =
  case ls of
    [] ->
      acc

    l :: rest ->
      blockWidthLoop rest (max acc (Str.width l))


{-| Go help.go:234-244 — decide whether the item of the given width still
fits, and if not, whether the " …" tail fits strictly (in which case the
caller stops and emits the tail instead of the item).  Returning
( "", True ) means "render the item anyway".
-}
shouldAddItem : Model -> Int -> Int -> ( String, Bool )
shouldAddItem m totalWidth w =
  if m.width > 0 && totalWidth + w > m.width then
    let
      tail =
        String.append " " (renderInline m.styles.ellipsis m.ellipsis)
    in
    if totalWidth + Str.width tail < m.width then
      ( tail, False )

    else
      ( "", True )

  else
    ( "", True )


{-| ShortHelpView: the single-line help (Go help.go:128-167).
-}
shortHelpView : Model -> List Key.Binding -> String
shortHelpView m bs =
  String.join "" (shortHelpLoop m bs 0 [])


shortHelpLoop : Model -> List Key.Binding -> Int -> List String -> List String
shortHelpLoop m bs totalWidth acc =
  case bs of
    [] ->
      acc

    kb :: rest ->
      if not (Key.enabled kb) then
        shortHelpLoop m rest totalWidth acc

      else
        let
          sep =
            if totalWidth > 0 then
              renderInline m.styles.shortSeparator m.shortSeparator

            else
              ""

          h =
            kb.help

          item =
            String.append sep
              (String.append (renderInline m.styles.shortKey h.key)
                (String.append " " (renderInline m.styles.shortDesc h.desc))
              )

          w =
            Str.width item

          res =
            shouldAddItem m totalWidth w

          tail =
            Tuple.first res
        in
        if not (Tuple.second res) then
          if tail == "" then
            acc

          else
            append acc [ tail ]

        else
          shortHelpLoop m rest (totalWidth + w) (append acc [ item ])


{-| FullHelpView: the column layout (Go help.go:171-232).
-}
fullHelpView : Model -> List (List Key.Binding) -> String
fullHelpView m groups =
  Lipgloss.joinHorizontal Lipgloss.PTop (fullHelpLoop m groups 0 [])


fullHelpLoop : Model -> List (List Key.Binding) -> Int -> List String -> List String
fullHelpLoop m groups totalWidth acc =
  case groups of
    [] ->
      acc

    group :: rest ->
      if not (shouldRenderColumn group) then
        fullHelpLoop m rest totalWidth acc

      else
        let
          sep =
            if totalWidth > 0 then
              renderInline m.styles.fullSeparator m.fullSeparator

            else
              ""

          ks =
            Tuple.first (splitGroup group)

          ds =
            Tuple.second (splitGroup group)

          col =
            Lipgloss.joinHorizontal Lipgloss.PTop
              [ sep
              , Lipgloss.render m.styles.fullKey (String.join "\n" ks)
              , " "
              , Lipgloss.render m.styles.fullDesc (String.join "\n" ds)
              ]

          w =
            blockWidth col

          res =
            shouldAddItem m totalWidth w

          tail =
            Tuple.first res
        in
        if not (Tuple.second res) then
          if tail == "" then
            acc

          else
            append acc [ tail ]

        else
          fullHelpLoop m rest (totalWidth + w) (append acc [ col ])


{-| The enabled bindings' key/desc columns, pairwise (Go appends into two
slices as it walks the group).
-}
splitGroup : List Key.Binding -> ( List String, List String )
splitGroup group =
  case group of
    [] ->
      ( [], [] )

    kb :: rest ->
      if not (Key.enabled kb) then
        splitGroup rest

      else
        let
          h =
            kb.help

          rec =
            splitGroup rest
        in
        ( h.key :: Tuple.first rec, h.desc :: Tuple.second rec )


{-| A column renders iff at least one of its bindings is enabled
(Go help.go:246-253).
-}
shouldRenderColumn : List Key.Binding -> Bool
shouldRenderColumn group =
  case group of
    [] ->
      False

    kb :: rest ->
      if Key.enabled kb then
        True

      else
        shouldRenderColumn rest
