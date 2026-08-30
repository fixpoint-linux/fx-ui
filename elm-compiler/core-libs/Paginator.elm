module Paginator
  exposing
    ( KeyMap
    , Model
    , Type(..)
    , arabicView
    , defaultKeyMap
    , dotsView
    , getSliceBounds
    , itemsOnPage
    , new
    , nextPage
    , onFirstPage
    , onLastPage
    , prevPage
    , setTotalPages
    , update
    , view
    )

-- M-WIDGETS S2: charmbracelet/bubbles' paginator package, subset-ported —
-- page arithmetic + keystroke navigation + the dots/arabic status renders.
-- Pure + keys: no host surface, navigation arrives through Key.matches on
-- the S1 key widget's bindings.
--
-- Go parity notes:
--  * Update checks NextPage BEFORE PrevPage (Go paginator.go:162-174) —
--    matters only for keymaps with overlapping keys.
--  * SetTotalPages(items) with items < 1 leaves the model untouched (and Go
--    also returns the unchanged TotalPages there).
--  * ItemsOnPage can go NEGATIVE when page is past the last item (Go
--    paginator.go:77-83: end - start with start unclamped) — pinned as-is,
--    it is the documented Go behavior.
--  * New(): Type Arabic, Page 0, PerPage 1, TotalPages 1, dots "•"/"○".
--
-- Deviations (both documented, neither observable in the default config):
--  * arabicFormat is kept in the model for record parity but arabicView
--    ALWAYS renders the fixed "%d/%d" shape — there is no printf in the
--    subset, so a custom Go format string could not be honored anyway.
--  * The Option variadics collapse into record updates by the caller.

{-| How the pagination renders (Go paginator.Type).
-}
type Type
  = Arabic
  | Dots


{-| The navigation keybindings (Go paginator.KeyMap).
-}
type alias KeyMap =
  { prevPage : Key.Binding
  , nextPage : Key.Binding
  }


{-| The pager state (Go paginator.Model).
-}
type alias Model =
  { ptype : Type
  , page : Int
  , perPage : Int
  , totalPages : Int
  , activeDot : String
  , inactiveDot : String
  , arabicFormat : String
  , keyMap : KeyMap
  }


{-| DefaultKeyMap (Go paginator.go:31-36; help text is empty, as in Go).
-}
defaultKeyMap : KeyMap
defaultKeyMap =
  { prevPage = Key.newBinding [ "pgup", "left", "h" ] "" ""
  , nextPage = Key.newBinding [ "pgdown", "right", "l" ] "" ""
  }


{-| New with Go's defaults (Go paginator.go:128-138).
-}
new : Model
new =
  { ptype = Arabic
  , page = 0
  , perPage = 1
  , totalPages = 1
  , activeDot = "•"
  , inactiveDot = "○"
  , arabicFormat = "%d/%d"
  , keyMap = defaultKeyMap
  }


{-| SetTotalPages from an item count (Go paginator.go:63-73): items < 1 is a
no-op; otherwise ceil(items / perPage) via truncated division + remainder
bump (no `rem` prim in the subset, so the remainder is spelled out).
-}
setTotalPages : Int -> Model -> Model
setTotalPages items m =
  if items < 1 then
    m

  else
    let
      n =
        items // m.perPage
    in
    { m
      | totalPages =
          if items - n * m.perPage > 0 then
            n + 1

          else
            n
    }


{-| ItemsOnPage (Go paginator.go:77-83) — negative when page is past the
end, exactly as in Go.
-}
itemsOnPage : Model -> Int -> Int
itemsOnPage m totalItems =
  if totalItems < 1 then
    0

  else
    Tuple.second (getSliceBounds m totalItems)
      - Tuple.first (getSliceBounds m totalItems)


{-| GetSliceBounds (Go paginator.go:92-96): the (start, end) window of a
length-N slice for the current page.
-}
getSliceBounds : Model -> Int -> ( Int, Int )
getSliceBounds m length =
  let
    start =
      m.page * m.perPage
  in
  ( start, min (start + m.perPage) length )


{-| PrevPage stops at page 0 (Go paginator.go:100-104).
-}
prevPage : Model -> Model
prevPage m =
  if m.page > 0 then
    { m | page = m.page - 1 }

  else
    m


{-| NextPage stops at the last page (Go paginator.go:108-112).
-}
nextPage : Model -> Model
nextPage m =
  if not (onLastPage m) then
    { m | page = m.page + 1 }

  else
    m


{-| OnLastPage (Go paginator.go:115-117).
-}
onLastPage : Model -> Bool
onLastPage m =
  m.page == m.totalPages - 1


{-| OnFirstPage (Go paginator.go:120-122).
-}
onFirstPage : Model -> Bool
onFirstPage m =
  m.page == 0


{-| Update: NextPage bindings win over PrevPage bindings (Go's switch
order); every other key is a no-op.
-}
update : Runtime.Key -> Model -> Model
update key m =
  if Key.matches key [ m.keyMap.nextPage ] then
    nextPage m

  else if Key.matches key [ m.keyMap.prevPage ] then
    prevPage m

  else
    m


{-| View renders per the Type (Go paginator.go:177-184).
-}
view : Model -> String
view m =
  case m.ptype of
    Dots ->
      dotsView m

    Arabic ->
      arabicView m


{-| DotsView: activeDot at the current page, inactiveDot elsewhere
(Go paginator.go:186-196).  Dots are caller-styled strings (usually a
pre-rendered Lipgloss render), concatenated verbatim.
-}
dotsView : Model -> String
dotsView m =
  dotsLoop m 0 ""


dotsLoop : Model -> Int -> String -> String
dotsLoop m i acc =
  if i >= m.totalPages then
    acc

  else if i == m.page then
    dotsLoop m (i + 1) (String.append acc m.activeDot)

  else
    dotsLoop m (i + 1) (String.append acc m.inactiveDot)


{-| ArabicView: the FIXED "%d/%d" (1-based page over total pages) — the
arabicFormat field is kept for record parity but never consulted, the
subset has no printf (Go paginator.go:198-200).
-}
arabicView : Model -> String
arabicView m =
  String.join "/" [ String.fromInt (m.page + 1), String.fromInt m.totalPages ]
