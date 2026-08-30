module PagUnit exposing (main)

-- S2 gate (main : String): core-libs/Paginator.elm (bubbles paginator).
-- Flags pin the arithmetic and navigation (ceil division, Go's negative
-- itemsOnPage past the end, the clamp rules, NextPage-before-PrevPage
-- update order, the fixed "%d/%d" deviation); VISIBLE strings carry the
-- arabic + dots renders (default and pre-styled dots).  Field reads are
-- let-bound (no field-as-function, no paren-field — the S1 fixture rules).

f x =
  case x of
    True ->
      "1"

    False ->
      "0"


-- record-updating helpers (annotated: the S2 lesson)


setPP : Int -> Paginator.Model -> Paginator.Model
setPP n m =
  { m | perPage = n }


setPT : Paginator.Type -> Paginator.Model -> Paginator.Model
setPT t m =
  { m | ptype = t }


setPage : Int -> Paginator.Model -> Paginator.Model
setPage n m =
  { m | page = n }


setAF : String -> Paginator.Model -> Paginator.Model
setAF s m =
  { m | arabicFormat = s }


setDots : String -> String -> Paginator.Model -> Paginator.Model
setDots a i m =
  { m | activeDot = a, inactiveDot = i }


setKM : Paginator.KeyMap -> Paginator.Model -> Paginator.Model
setKM km m =
  { m | keyMap = km }


main =
  let
    p0 =
      Paginator.new

    -- perPage 5 over 23 items -> 5 pages
    p5 =
      Paginator.setTotalPages 23 (setPP 5 p0)

    p5b =
      Paginator.setTotalPages 20 (setPP 5 p0)

    p5c =
      Paginator.setTotalPages 21 (setPP 5 p0)

    at4 =
      setPage 4 p5

    at2 =
      setPage 2 p5

    at5 =
      setPage 5 p5

    b0 =
      Paginator.getSliceBounds p5 23

    b4 =
      Paginator.getSliceBounds at4 23

    b5 =
      Paginator.getSliceBounds at5 23

    b0s =
      Tuple.first b0

    b0e =
      Tuple.second b0

    b4s =
      Tuple.first b4

    b4e =
      Tuple.second b4

    b5s =
      Tuple.first b5

    b5e =
      Tuple.second b5

    -- navigation folds on the 5-page model (NextPage bindings are checked
    -- before PrevPage in update; new's 1-page model clamps everything)
    fwd3 =
      Paginator.update KeyRight
        (Paginator.update (KeyChar "l") (Paginator.update KeyPgDn p5))

    fwd3Page =
      Paginator.nextPage fwd3

    fwd3Stop =
      Paginator.nextPage fwd3Page

    back1 =
      Paginator.update KeyLeft (Paginator.update (KeyChar "h") fwd3)

    back1Page =
      Paginator.prevPage back1

    back0 =
      Paginator.update KeyPgUp back1

    clampedNext =
      Paginator.nextPage at4

    clampedPrev =
      Paginator.prevPage p5

    -- disabled next bindings: right is dead (page holds), left still pages
    kmNoNext =
      { prevPage = Paginator.defaultKeyMap.prevPage
      , nextPage = Key.setEnabled False Paginator.defaultKeyMap.nextPage
      }

    noNextM =
      setKM kmNoNext at2

    disNext =
      Paginator.update KeyRight noNextM

    backDis =
      Paginator.update KeyLeft disNext

    miss =
      Paginator.update (KeyChar "x") at2

    -- arabicFormat is FIXED (no printf in the subset): a bogus format still
    -- renders "%d/%d"
    bogus =
      Paginator.view (setAF "page %d of %d" at2)

    -- dots: defaults, then pre-styled dots (Go callers style the dots)
    dotsDef =
      Paginator.view (setPT Paginator.Dots at2)

    activeStyled =
      Lipgloss.render (Lipgloss.foreground (Lipgloss.ColorAnsi256 212) Lipgloss.newStyle) "●"

    inactiveStyled =
      Lipgloss.render (Lipgloss.foreground (Lipgloss.ColorAnsi256 243) Lipgloss.newStyle) "·"

    dotsStyled =
      Paginator.view (setDots activeStyled inactiveStyled (setPT Paginator.Dots at2))

    km0 =
      Paginator.defaultKeyMap

    setTP0 =
      Paginator.setTotalPages 0 p5

    kmPrev =
      Key.keys km0.prevPage

    kmNext =
      Key.keys km0.nextPage

    -- structural flags: declaration order
    flags =
      String.join ""
        [ f (p0.page == 0)
        , f (p0.perPage == 1)
        , f (p0.totalPages == 1)
        , f (p0.activeDot == "•")
        , f (p0.inactiveDot == "○")
        , f (p0.arabicFormat == "%d/%d")
        , f (Paginator.onFirstPage p0)
        , f (Paginator.onLastPage p0)
        , f (p5.totalPages == 5)
        , f (p5b.totalPages == 4)
        , f (p5c.totalPages == 5)
        , f (setTP0.totalPages == 5)
        , f (b0s == 0)
        , f (b0e == 5)
        , f (b4s == 20)
        , f (b4e == 23)
        , f (b5s == 25)
        , f (b5e == 23)
        , f (Paginator.itemsOnPage p5 23 == 5)
        , f (Paginator.itemsOnPage at4 23 == 3)
        , f (Paginator.itemsOnPage at5 23 == -2)
        , f (Paginator.itemsOnPage p5 0 == 0)
        , f (Paginator.onLastPage at4)
        , f (not (Paginator.onLastPage at2))
        , f (clampedNext.page == 4)
        , f (clampedPrev.page == 0)
        , f (fwd3.page == 3)
        , f (fwd3Page.page == 4)
        , f (fwd3Stop.page == 4)
        , f (back1.page == 1)
        , f (back1Page.page == 0)
        , f (back0.page == 0)
        , f (miss.page == 2)
        , f (disNext.page == 2)
        , f (backDis.page == 1)
        , f (kmPrev == [ "pgup", "left", "h" ])
        , f (kmNext == [ "pgdown", "right", "l" ])
        , f (Paginator.view p0 == Paginator.view (setPT Paginator.Arabic p0))
        ]
  in
  String.join "|"
    [ flags
    , Paginator.view p0
    , Paginator.view at2
    , bogus
    , dotsDef
    , dotsStyled
    , Paginator.arabicView p0
    , Paginator.dotsView p0
    ]
