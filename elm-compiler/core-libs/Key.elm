module Key
  exposing
    ( Binding
    , Help
    , enabled
    , help
    , keyName
    , keys
    , matches
    , member
    , newBinding
    , setEnabled
    , unbind
    )

-- M-WIDGETS S1: charmbracelet/bubbles' key package, subset-ported — the
-- foundational pure widget every other widget's keymap builds on (help,
-- paginator, viewport, textarea, list, table all match keys through this).
--
-- Go parity notes:
--  * NewBinding(WithKeys(..), WithHelp(..), WithDisabled()) collapses into
--    `newBinding keys helpKey helpDesc` (plain args replace the BindingOpt
--    variadics); bindings are disabled with setEnabled, never at build.
--  * Matches(k, bindings...) walks the bindings then their keys comparing
--    k.String() — here keyName.  A disabled binding never matches.
--  * Enabled() is `!disabled && keys != nil`; our List has no nil, so the
--    empty list IS the unbound state and `enabled` is False for it (unbind's
--    nullifying semantics survive exactly; a Go binding built with an
--    explicitly empty WithKeys() would differ, nothing constructs that).
--  * keyName is THE contract (Go tea key.String() spellings): every widget
--    keymap lists its keys in exactly these spellings.


{-| Help information for a binding (Go key.Help).
-}
type alias Help =
  { key : String
  , desc : String
  }


{-| A set of keybindings plus optional help text (Go key.Binding).
-}
type alias Binding =
  { keys : List String
  , help : Help
  , disabled : Bool
  }


{-| NewBinding from the Go package: the keys, then the help pair.
-}
newBinding : List String -> String -> String -> Binding
newBinding ks k d =
  { keys = ks, help = { key = k, desc = d }, disabled = False }


{-| The decoded terminal key's keymap spelling — Go tea key.String() parity.
KeyChar " " is "space" (bubbletea names the space bar), KeyOther n falls back
to the runtime's numeric key id.
-}
keyName : Runtime.Key -> String
keyName key =
  case key of
    KeyChar " " ->
      "space"

    KeyChar c ->
      c

    KeyEnter ->
      "enter"

    KeyTab ->
      "tab"

    KeyBackspace ->
      "backspace"

    KeyEsc ->
      "esc"

    KeyUp ->
      "up"

    KeyDown ->
      "down"

    KeyLeft ->
      "left"

    KeyRight ->
      "right"

    KeyHome ->
      "home"

    KeyEnd ->
      "end"

    KeyPgUp ->
      "pgup"

    KeyPgDn ->
      "pgdown"

    KeyIns ->
      "insert"

    KeyDel ->
      "delete"

    KeyCtrl c ->
      String.append "ctrl+" c

    KeyOther n ->
      String.fromInt n

    KeyEof ->
      "eof"


{-| Hand-rolled list membership (the Prelude has none): the inner loop of
both `matches` and `enabled`.
-}
member : String -> List String -> Bool
member needle ks =
  case ks of
    [] ->
      False

    k :: rest ->
      if k == needle then
        True

      else
        member needle rest


{-| Whether the binding can fire / should show in help.  Keybindings are
enabled by default; the unbound (empty-keys) binding is never enabled.
-}
enabled : Binding -> Bool
enabled b =
  (not b.disabled) && not (isEmpty b.keys)


{-| Matches checks if the given key fires any of the given bindings.
-}
matches : Runtime.Key -> List Binding -> Bool
matches key bs =
  case bs of
    [] ->
      False

    b :: rest ->
      if (not b.disabled) && member (keyName key) b.keys then
        True

      else
        matches key rest


{-| SetEnabled enables or disables the binding (Go stores `disabled = !v`).
-}
setEnabled : Bool -> Binding -> Binding
setEnabled on b =
  { b | disabled = not on }


{-| Unbind removes the keys and help from the binding, effectively
nullifying it — a step beyond disabling, since applications can enable or
disable bindings based on application state but an unbound one stays dead.
-}
unbind : Binding -> Binding
unbind b =
  { b | keys = [], help = { key = "", desc = "" } }


{-| The binding's keys.
-}
keys : Binding -> List String
keys b =
  b.keys


{-| The binding's help information.
-}
help : Binding -> Help
help b =
  b.help
