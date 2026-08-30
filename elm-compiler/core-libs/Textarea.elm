module Textarea exposing
  ( Model
  , KeyMap
  , init
  , defaultKeyMap
  , setValue
  , setCursor
  , setWidth
  , setHeight
  , focus
  , blur
  , value
  , row
  , col
  , update
  , view
  )

-- M-WIDGETS S5: charmbracelet/bubbles' textarea, subset-ported over the Tea
-- v2 loop.  The multi-line editor: `value` holds the logical lines (a List of
-- Strings), `row`/`col` the cursor as a ROW index plus a BYTE offset into
-- that row, and the embedded `viewport` (S4) does the rendering + vertical
-- scroll.  `update` mirrors Go textarea.go:1169-1317's KeyPressMsg switch;
-- `view` builds the prompt-prefixed lines with a reverse-video cursor, feeds
-- them into the embedded viewport (setContent) and repositions it so the
-- cursor row stays visible.
--
-- Go parity notes (against textarea.go master):
--   * the keymap switch order is Go's exact order: deleteAfterCursor,
--     deleteBeforeCursor, deleteCharacterBackward, deleteCharacterForward,
--     deleteWordBackward, insertNewline, lineEnd, lineStart,
--     characterForward, lineNext, characterBackward, linePrevious, pageUp,
--     pageDown, then the default KeyChar insert.
--   * backspace / delete at col 0 (resp. >= line length) merge the line above
--     (resp. below); ctrl+u / ctrl+k at the line edge do the same; enter
--     splitLine moves the tail to a new row and advances the cursor onto it.
--   * deleteWordLeft (ctrl+w) is Go's exact algorithm: skip the whitespace
--     immediately left of the cursor, then the word, keeping the separator
--     space (readline unix-word-rubout semantics).
--   * the cursor is a STEADY reverse-video cell: \e[7m<chr>\e[0m on the
--     current char, \e[7m \e[0m past the end of the line (the M1 no-blink
--     deviation, same as TextInput).  Rendered only when focused.
--   * view = prompt + line per row (prompt on EVERY line, Go parity), the
--     cursor row gets the reverse-video cell, the result is SetContent into
--     the embedded viewport, then repositionView (Go: scroll the viewport so
--     the cursor row lands inside [yOffset, yOffset+height)).
--
-- DEVIATIONS (all documented, none observable in the subset):
--   * `col` is a BYTE offset and every cursor/delete op moves one BYTE
--     (characterRight/Left, backspace/delete, word boundaries): multibyte
--     UTF-8 is not rune-granular — ASCII is exact, multibyte content is
--     corrupted byte-by-byte.  Same class as the TextInput M1 deviation.
--   * soft-wrap is FIXED off: each logical line is ONE terminal row, so the
--     cursor line number == row, and pageUp/pageDown just move the cursor by
--     `height` rows (Go's snap-then-page soft-wrap dance is dropped).
--   * no line numbers, no placeholder, no end-of-buffer padding, no styles
--     (focused/blurred share one plain render), no virtual-cursor blink, no
--     paste/alt-word/case-transforms/transpose/InputBegin-InputEnd keys, no
--     CharLimit/MaxHeight/MaxWidth cache or wrap memoization.
--   * the horizontal scroll is the viewport's Str.cut window, but the
--     textarea does NOT auto-scroll x to keep the cursor column visible
--     (Go's repositionView is vertical-only too); narrow demo content keeps
--     the cursor in-window, and callers can Viewport.setXOffset explicitly.
--   * the keymap is a module-level constant (Go keeps it on the Model); the
--     Model omits it for the subset.


{-| A set of keybindings for the textarea (Go textarea.KeyMap, subset).
-}
type alias KeyMap =
  { characterForward : Key.Binding
  , characterBackward : Key.Binding
  , lineNext : Key.Binding
  , linePrevious : Key.Binding
  , deleteWordBackward : Key.Binding
  , deleteAfterCursor : Key.Binding
  , deleteBeforeCursor : Key.Binding
  , insertNewline : Key.Binding
  , deleteCharacterBackward : Key.Binding
  , deleteCharacterForward : Key.Binding
  , lineStart : Key.Binding
  , lineEnd : Key.Binding
  , pageUp : Key.Binding
  , pageDown : Key.Binding
  }


{-| The textarea state (Go textarea.Model, subset).
-}
type alias Model =
  { value : List String
  , row : Int
  , col : Int
  , focus : Bool
  , prompt : String
  , width : Int
  , height : Int
  , viewport : Viewport.Model
  }


{-| Go DefaultKeyMap (textarea.go:78), the subset the update switch handles.
-}
defaultKeyMap : KeyMap
defaultKeyMap =
  { characterForward = Key.newBinding [ "right", "ctrl+f" ] "right" "character forward"
  , characterBackward = Key.newBinding [ "left", "ctrl+b" ] "left" "character backward"
  , lineNext = Key.newBinding [ "down", "ctrl+n" ] "down" "next line"
  , linePrevious = Key.newBinding [ "up", "ctrl+p" ] "up" "previous line"
  , deleteWordBackward = Key.newBinding [ "ctrl+w" ] "ctrl+w" "delete word backward"
  , deleteAfterCursor = Key.newBinding [ "ctrl+k" ] "ctrl+k" "delete after cursor"
  , deleteBeforeCursor = Key.newBinding [ "ctrl+u" ] "ctrl+u" "delete before cursor"
  , insertNewline = Key.newBinding [ "enter", "ctrl+m" ] "enter" "insert newline"
  , deleteCharacterBackward = Key.newBinding [ "backspace", "ctrl+h" ] "backspace" "delete character backward"
  , deleteCharacterForward = Key.newBinding [ "delete", "ctrl+d" ] "delete" "delete character forward"
  , lineStart = Key.newBinding [ "home", "ctrl+a" ] "home" "line start"
  , lineEnd = Key.newBinding [ "end", "ctrl+e" ] "end" "line end"
  , pageUp = Key.newBinding [ "pgup" ] "pgup" "page up"
  , pageDown = Key.newBinding [ "pgdown" ] "pgdown" "page down"
  }


{-| New(width, height): one empty line, cursor at (0,0), unfocused, the Go
default prompt "┃ " (ThickBorder left + space), and an embedded viewport of
the same size.
-}
init : Int -> Int -> Model
init w h =
  { value = [ "" ]
  , row = 0
  , col = 0
  , focus = False
  , prompt = "┃ "
  , width = w
  , height = h
  , viewport = Viewport.init w h
  }


-- ---- state accessors / mutators ----


{-| SetValue: replace the whole content and move the cursor to its end (Go
SetValue = Reset + InsertString).  Lines split on "\n" (a trailing \n keeps a
trailing empty line).
-}
setValue : String -> Model -> Model
setValue s m =
  let
    ls =
      Str.lines s

    last =
      length ls - 1
  in
  { m | value = ls, row = last, col = String.length (nthLine last ls) }


{-| SetCursor clamps the cursor into the current grid.
-}
setCursor : Int -> Int -> Model -> Model
setCursor r c m =
  let
    r2 =
      clamp 0 (length m.value - 1) r
  in
  { m | row = r2, col = clamp 0 (String.length (nthLine r2 m.value)) c }


setWidth : Int -> Model -> Model
setWidth w m =
  { m | width = w, viewport = Viewport.setWidth w m.viewport }


setHeight : Int -> Model -> Model
setHeight h m =
  { m | height = h, viewport = Viewport.setHeight h m.viewport }


focus : Model -> Model
focus m =
  { m | focus = True }


blur : Model -> Model
blur m =
  { m | focus = False }


{-| Value: the lines joined back with "\n".
-}
value : Model -> String
value m =
  String.join "\n" m.value


row : Model -> Int
row m =
  m.row


col : Model -> Int
col m =
  m.col


-- ---- list-of-lines helpers (the Prelude has no indexed ops) ----


nthLine : Int -> List String -> String
nthLine i ls =
  case ls of
    [] ->
      ""

    l :: rest ->
      if i == 0 then
        l

      else
        nthLine (i - 1) rest


replaceLine : Int -> String -> List String -> List String
replaceLine i new ls =
  append (take i ls) (new :: drop (i + 1) ls)


insertLine : Int -> String -> List String -> List String
insertLine i new ls =
  append (take i ls) (new :: drop i ls)


removeLine : Int -> List String -> List String
removeLine i ls =
  append (take i ls) (drop (i + 1) ls)


lineLen : Model -> Int -> Int
lineLen m r =
  String.length (nthLine r m.value)


-- ---- cursor movement (BYTE granularity) ----


cursorEnd : Model -> Model
cursorEnd m =
  { m | col = lineLen m m.row }


cursorStart : Model -> Model
cursorStart m =
  { m | col = 0 }


characterRight : Model -> Model
characterRight m =
  if m.col < lineLen m m.row then
    { m | col = m.col + 1 }

  else if m.row < length m.value - 1 then
    { m | row = m.row + 1, col = 0 }

  else
    m


characterLeft : Model -> Model
characterLeft m =
  if m.col == 0 && m.row /= 0 then
    { m | row = m.row - 1, col = lineLen m (m.row - 1) }

  else if m.col > 0 then
    { m | col = m.col - 1 }

  else
    m


cursorDown : Model -> Model
cursorDown m =
  if m.row < length m.value - 1 then
    { m | row = m.row + 1, col = clamp 0 (lineLen m (m.row + 1)) m.col }

  else
    m


cursorUp : Model -> Model
cursorUp m =
  if m.row > 0 then
    { m | row = m.row - 1, col = clamp 0 (lineLen m (m.row - 1)) m.col }

  else
    { m | col = 0 }


moveCursorUp : Int -> Model -> Model
moveCursorUp n m =
  let
    r2 =
      max 0 (m.row - n)
  in
  { m | row = r2, col = clamp 0 (lineLen m r2) m.col }


moveCursorDown : Int -> Model -> Model
moveCursorDown n m =
  let
    r2 =
      min (length m.value - 1) (m.row + n)
  in
  { m | row = r2, col = clamp 0 (lineLen m r2) m.col }


-- ---- merge / split ----


{-| mergeLineAbove: fold the cursor's line onto the line above (cursor lands
at the old end of the upper line).
-}
mergeLineAbove : Model -> Model
mergeLineAbove m =
  if m.row <= 0 then
    m

  else
    let
      above =
        nthLine (m.row - 1) m.value

      merged =
        String.append above (nthLine m.row m.value)
    in
    { m | value = removeLine m.row (replaceLine (m.row - 1) merged m.value)
    , row = m.row - 1
    , col = String.length above
    }


{-| mergeLineBelow: fold the line below the cursor onto the cursor's line
(cursor position unchanged).
-}
mergeLineBelow : Model -> Model
mergeLineBelow m =
  if m.row >= length m.value - 1 then
    m

  else
    let
      merged =
        String.append (nthLine m.row m.value) (nthLine (m.row + 1) m.value)
    in
    { m | value = removeLine (m.row + 1) (replaceLine m.row merged m.value) }


-- ---- delete / insert ----


deleteCharacterBackward : Model -> Model
deleteCharacterBackward m =
  let
    c =
      clamp 0 (lineLen m m.row) m.col
  in
  if c <= 0 then
    mergeLineAbove m

  else if lineLen m m.row > 0 then
    { m | value = replaceLine m.row (dropByte (c - 1) (nthLine m.row m.value)) m.value
    , col = c - 1
    }

  else
    m


deleteCharacterForward : Model -> Model
deleteCharacterForward m =
  if lineLen m m.row > 0 && m.col < lineLen m m.row then
    { m | value = replaceLine m.row (dropByte m.col (nthLine m.row m.value)) m.value }

  else if m.col >= lineLen m m.row then
    mergeLineBelow m

  else
    m


deleteAfterCursor : Model -> Model
deleteAfterCursor m =
  let
    c =
      clamp 0 (lineLen m m.row) m.col
  in
  if c >= lineLen m m.row then
    mergeLineBelow m

  else
    let
      newLine =
        String.sliceLen 0 c (nthLine m.row m.value)
    in
    { m | value = replaceLine m.row newLine m.value, col = String.length newLine }


deleteBeforeCursor : Model -> Model
deleteBeforeCursor m =
  let
    c =
      clamp 0 (lineLen m m.row) m.col
  in
  if c <= 0 then
    mergeLineAbove m

  else
    let
      l =
        nthLine m.row m.value
    in
    { m | value = replaceLine m.row (String.sliceLen c (String.length l - c) l) m.value
    , col = 0
    }


{-| dropByte i line: the line with the single BYTE at offset i removed (byte
granularity — documented deviation).
-}
dropByte : Int -> String -> String
dropByte i line =
  String.append (String.sliceLen 0 i line)
    (String.sliceLen (i + 1) (String.length line - i - 1) line)


deleteWordBackward : Model -> Model
deleteWordBackward m =
  if m.col <= 0 then
    mergeLineAbove m

  else
    let
      start =
        wordLeftStart m.col (nthLine m.row m.value)
    in
    { m | value = replaceLine m.row (String.sliceLen 0 start (nthLine m.row m.value)) m.value
    , col = start
    }


{-| The byte offset a delete-word-backward deletes FROM (Go deleteWordLeft:
skip the whitespace immediately left, then the word, keeping the separator
space).
-}
wordLeftStart : Int -> String -> Int
wordLeftStart col line =
  skipWordLeft (skipSpacesLeft (clamp 0 (String.length line) (col - 1)) line) line


skipSpacesLeft : Int -> String -> Int
skipSpacesLeft i line =
  if i <= 0 then
    0

  else if isSpaceByte i line then
    skipSpacesLeft (i - 1) line

  else
    i


skipWordLeft : Int -> String -> Int
skipWordLeft i line =
  if i <= 0 then
    0

  else if not (isSpaceByte i line) then
    skipWordLeft (i - 1) line

  else
    i + 1


isSpaceByte : Int -> String -> Bool
isSpaceByte i line =
  let
    c =
      charCode line i
  in
  c == 32 || c == 9 || c == 10 || c == 13


insertNewline : Model -> Model
insertNewline m =
  let
    l =
      nthLine m.row m.value

    c =
      clamp 0 (String.length l) m.col
  in
  { m | value =
      replaceLine m.row (String.sliceLen 0 c l)
        (insertLine (m.row + 1) (String.sliceLen c (String.length l - c) l) m.value)
  , row = m.row + 1
  , col = 0
  }


insertChar : String -> Model -> Model
insertChar ch m =
  let
    l =
      nthLine m.row m.value

    c =
      clamp 0 (String.length l) m.col
  in
  { m | value =
      replaceLine m.row
        (String.append (String.sliceLen 0 c l) (String.append ch (String.sliceLen c (String.length l - c) l)))
        m.value
  , col = c + String.length ch
  }


-- ---- Tea surface ----


{-| Handle one key against the keymap (Go update KeyPressMsg switch, exact
order), inserting printable KeyChars as the default branch.  A blurred model
ignores every key (Go Update's !focus early return).
-}
update : Runtime.Key -> Model -> Model
update key m =
  if not m.focus then
    m

  else if Key.matches key [ defaultKeyMap.deleteAfterCursor ] then
    deleteAfterCursor m

  else if Key.matches key [ defaultKeyMap.deleteBeforeCursor ] then
    deleteBeforeCursor m

  else if Key.matches key [ defaultKeyMap.deleteCharacterBackward ] then
    deleteCharacterBackward m

  else if Key.matches key [ defaultKeyMap.deleteCharacterForward ] then
    deleteCharacterForward m

  else if Key.matches key [ defaultKeyMap.deleteWordBackward ] then
    deleteWordBackward m

  else if Key.matches key [ defaultKeyMap.insertNewline ] then
    insertNewline m

  else if Key.matches key [ defaultKeyMap.lineEnd ] then
    cursorEnd m

  else if Key.matches key [ defaultKeyMap.lineStart ] then
    cursorStart m

  else if Key.matches key [ defaultKeyMap.characterForward ] then
    characterRight m

  else if Key.matches key [ defaultKeyMap.lineNext ] then
    cursorDown m

  else if Key.matches key [ defaultKeyMap.characterBackward ] then
    characterLeft m

  else if Key.matches key [ defaultKeyMap.linePrevious ] then
    cursorUp m

  else if Key.matches key [ defaultKeyMap.pageUp ] then
    moveCursorUp m.height m

  else if Key.matches key [ defaultKeyMap.pageDown ] then
    moveCursorDown m.height m

  else
    case key of
      KeyChar ch ->
        insertChar ch m

      _ ->
        m


-- ---- rendering ----


{-| Render one row: prompt + line, with the reverse-video cursor cell on the
cursor row (only when focused).  \e[7m<chr>\e[0m on the current byte,
\e[7m \e[0m at/past end of line.
-}
renderLine : Model -> Int -> String -> String
renderLine m i line =
  let
    base =
      String.append m.prompt line
  in
  if i == m.row && m.focus then
    if m.col >= String.length line then
      String.append base "\u{1B}[7m \u{1B}[0m"

    else
      String.append m.prompt
        (String.append (String.sliceLen 0 m.col line)
          (String.append "\u{1B}[7m"
            (String.append (String.sliceLen m.col 1 line)
              (String.append "\u{1B}[0m"
                (String.sliceLen (m.col + 1) (String.length line - m.col - 1) line)
              )
            )
          )
        )

  else
    base


renderRows : Model -> List String
renderRows m =
  renderRowsGo m 0 m.value


renderRowsGo : Model -> Int -> List String -> List String
renderRowsGo m i ls =
  case ls of
    [] ->
      []

    l :: rest ->
      renderLine m i l :: renderRowsGo m (i + 1) rest


{-| Go repositionView: scroll the embedded viewport so the cursor row lands in
[ yOffset, yOffset + height ).
-}
reposition : Model -> Viewport.Model -> Viewport.Model
reposition m vp =
  let
    minV =
      Viewport.yOffset vp

    maxV =
      minV + m.height - 1
  in
  if m.row < minV then
    Viewport.scrollUp (minV - m.row) vp

  else if m.row > maxV then
    Viewport.scrollDown (m.row - maxV) vp

  else
    vp


{-| View: the prompt-prefixed cursor-marked rows joined with "\n", fed into
the embedded viewport (SetContent), repositioned so the cursor row is visible,
then rendered by the viewport.
-}
view : Model -> String
view m =
  Viewport.view (reposition m (Viewport.setContent (String.join "\n" (renderRows m)) m.viewport))
