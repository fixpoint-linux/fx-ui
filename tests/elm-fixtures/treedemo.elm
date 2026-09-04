module TreeDemo exposing (main)

-- S10 (widget + demo): the Tree widget driving a Tea v2 program, proven
-- end-to-end under a real pseudo-terminal by scripts/treedemo.script.
--
-- The tea model is a SMALL record of SCALARS { cur, tOpen, cOpen, eOpen,
-- bOpen, hAll } — the full Tree.Model (the 13-line viewport content + the
-- tree + the styles + the keymap + help) exceeds the pty buffer for elmvm's
-- final-model print (the tabledemo/vpdemo workaround), so the widget is
-- REBUILT transiently from the scalars each event: the four parent nodes
-- are re-closed in DESCENDING y order (a closure only shifts the offsets
-- AFTER it, so each recorded offset stays valid on the partially-closed
-- tree), the "?" flip is replayed through `Tree.update` (keeping Go's
-- no-SetSize-on-help-flip quirk consistent), and the selection is restored
-- with setYOffset.  Every key still exercises the REAL Tree.update/view.
--
-- `view` renders a live "cur=<y> <value>:<open>" header above the tree so
-- every state has a UNIQUE needle.  j/k walk (a closed parent is skipped by
-- the preorder walk), enter toggles, l/h open/close, g/G jump, ? flips the
-- help, q/esc/ctrl+c quit via the TaskQuit scan.

import Str
import Tea exposing (program, quit)
import Tree


type alias Model =
  { cur : Int
  , rOpen : Bool
  , tOpen : Bool
  , cOpen : Bool
  , eOpen : Bool
  , bOpen : Bool
  , hAll : Bool
  }


type Msg
  = GotKey Runtime.Key
  | Noop


demoTree : Tree.Node
demoTree =
  Tree.root "~/charm"
    [ Tree.leaf "ayman"
    , Tree.root "bash"
        [ Tree.root "tools" [ Tree.leaf "zsh", Tree.leaf "doom-emacs" ] ]
    , Tree.root "carlos"
        [ Tree.root "emotes" [ Tree.leaf "chefkiss.png", Tree.leaf "kekw.png" ] ]
    , Tree.leaf "maas"
    ]


f : Bool -> String
f b =
  case b of
    True ->
      "1"

    False ->
      "0"


{-| The fully-open preorder: 0 ~/charm, 1 ayman, 2 bash, 3 tools, 4 zsh,
5 doom-emacs, 6 carlos, 7 emotes, 8 chefkiss.png, 9 kekw.png, 10 maas.  The
closures apply DESCENDING so each recorded offset is still valid.
-}
rebuild : Model -> Tree.Model
rebuild m =
  let
    base =
      if m.rOpen then
        Tree.new demoTree 70 13

      else
        Tree.closeNodeAt 0 (Tree.new demoTree 70 13)

    mE =
      if m.eOpen then
        base

      else
        Tree.closeNodeAt 7 base

    mC =
      if m.cOpen then
        mE

      else
        Tree.closeNodeAt 6 mE

    mT =
      if m.tOpen then
        mC

      else
        Tree.closeNodeAt 3 mC

    mB =
      if m.bOpen then
        mT

      else
        Tree.closeNodeAt 2 mT

    selected =
      Tree.setYOffset m.cur mB
  in
  if m.hAll then
    Tree.update (KeyChar "?") selected

  else
    selected


main =
  program
    { init = init
    , update = update
    , view = view
    , resize = \cols rows m -> m
    , onKey = GotKey
    , onMouse = \_ -> Noop
    , mouse = MouseModeOff
    }


init : () -> ( Model, Runtime.Cmd Msg )
init _ =
  ( { cur = 0
    , rOpen = True
    , tOpen = True
    , cOpen = True
    , eOpen = True
    , bOpen = True
    , hAll = False
    }
  , Cmd.none
  )


update : Msg -> Model -> ( Model, Runtime.Cmd Msg )
update msg model =
  case msg of
    GotKey key ->
      case key of
        KeyChar "q" ->
          ( model, quit )

        KeyCtrl "c" ->
          ( model, quit )

        KeyEsc ->
          ( model, quit )

        _ ->
          let
            t0 =
              rebuild model

            t1 =
              Tree.update key t0

            m1 =
              { model
                | cur = Tree.yOffset t1
                , rOpen = flagAt "~/charm" 0 t1 model.rOpen
                , bOpen = flagAt "bash" 2 t1 model.bOpen
                , tOpen = flagAt "tools" 3 t1 model.tOpen
                , cOpen = flagAt "carlos" 6 t1 model.cOpen
                , eOpen = flagAt "emotes" 7 t1 model.eOpen
                , hAll = t1.help.showAll
              }
          in
          ( m1, Cmd.none )

    Noop ->
      ( model, Cmd.none )


{-| The open flag of the node at offset k, but ONLY if that node is still
the named one — a closure hides the offsets after it, and the node that
slides into k must not poison the recorded flag (the fallback keeps the
last known state; the flag is unreachable while its parent is closed).
-}
flagAt : String -> Int -> Tree.Model -> Bool -> Bool
flagAt name k t fallback =
  case Tree.nodeAt k t of
    Just nd ->
      if Tree.value nd == name then
        Tree.isOpen nd

      else
        fallback

    Nothing ->
      fallback


view : Model -> List String
view model =
  let
    t =
      rebuild model

    header =
      case Tree.nodeAtCurrentOffset t of
        Just nd ->
          String.append
            (String.append
              (String.append
                (String.append "cur=" (String.fromInt (Tree.yOffset t)))
                " "
              )
              (Tree.value nd)
            )
            (String.append ":" (f (Tree.isOpen nd)))

        Nothing ->
          "cur=?"
  in
  header :: Str.lines (Tree.view t)
