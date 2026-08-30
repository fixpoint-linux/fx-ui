module Tea exposing
  ( Event
  , program
  , quit
  , paint
  )

-- M1 bubbletea-style core loop (charmbracelet/bubbletea's program loop,
-- subset-ported) over the M9 host Program substrate.  NOT an elm/core port —
-- this is fx-ui's terminal-UI runtime module, written in the subset the
-- checker accepts.
--
-- Subset/architecture deviations from real bubbletea, all forced by the M9
-- cmd-driven loop and the checker surface:
--   * the input subscription is a SELF-RE-ARMING TaskReadKey command (the M9
--     loop delivers task results as the only messages; there are no Subs) —
--     every handled key re-arms `Io.readKey`, but quit and KeyEof do NOT:
--     KeyEof (stdin EOF) takes the exit path directly and is never delivered
--     as a normal key (a re-arm after it would spin — the host completes
--     every re-armed readKey with KeyEof instantly once stdin hits EOF);
--   * `view` returns List String (one string per terminal row) instead of a
--     full-screen view type (no String.split/`++` in the Prelude);
--   * quitting = appending `quit` (a [TaskSucceed EvQuit] command) to the
--     command update returns; outerUpdate scans for it SYNCHRONOUSLY so the
--     readKey re-arm is dropped on the quit key itself and the host's eval
--     set drains to zero (a delivery-time quit would leave a suspended
--     readKey and the program would hang waiting for one more key);
--   * the tea model is a plain record {mod, prev, rows, cols} — `mod` is the
--     user's model, `prev` the last painted frame (cursor rests one line
--     BELOW its last line), rows/cols the last resize dims;
--   * every frame is joined into ONE string -> ONE TaskWrite -> one write(2)
--     (PTY-deterministic single-write frames).


{-| The messages `outerUpdate` handles.  `EvKey` carries a decoded terminal
key (a Runtime.Key, host-decoded); `EvResize` the cols/rows probe answered at
startup (the first paint piggybacks on it); `EvQuit` the quit marker, only
delivered if a `quit` task ever escapes to the host; `EvIgnored` the delivery
of side-effect chains (frame writes, raw-mode flips).
-}
type Event
  = EvKey Runtime.Key
  | EvResize Int Int
  | EvQuit
  | EvIgnored


{-| Turn a user config `{init, update, view, resize}` into a host Program.  init
batches the user's initial command with a RAW-MODE-FIRST chain: raw mode must
be ON before the winsize probe / first readKey (the first frame's \r\n is
mangled by the tty's ONLCR otherwise — the host runs batched tasks out of
spawn order, so ordering here is a chain, not a batch).

`resize cols rows model` folds EVERY EvResize delivery into the user model
before the repaint — the startup winsize probe AND every live SIGWINCH
(after each delivery the EvResize branch re-arms `Io.waitResize` first in its
batch, before the frame write, so the signalfd is armed before a peer-issued
resize can ever be observed — resizeunit's GotProbe ordering discipline).
-}
program config =
  let
    ( m0, c0 ) =
      config.init ()
  in
  Platform.program
    { init =
        \_ ->
          ( { mod = m0, prev = [], rows = 0, cols = 0 }
          , Cmd.batch
              [ c0
              , Task.perform resizeToEvent
                  (Task.andThen (\_ -> Io.winSize) (Io.rawMode True))
              , Task.perform EvKey
                  (Task.andThen (\_ -> Io.readKey) (Io.rawMode True))
              ]
          )
    , update = outerUpdate config
    , subscriptions = \_ -> Sub.none
    }


resizeToEvent size =
  EvResize (Tuple.first size) (Tuple.second size)


{-| Append to the command your update returns to quit: outerUpdate sees the
marker synchronously, skips the repaint/re-arm, and runs the exit path.
-}
quit =
  [ TaskSucceed EvQuit ]


-- The synchronous quit scan (see module header): True iff the command list
-- carries the quit marker task.
hasQuit cmd =
  case cmd of
    [] ->
      False

    task :: rest ->
      case task of
        TaskSucceed EvQuit ->
          True

        _ ->
          hasQuit rest


-- Exit path: restore the cursor, drop raw mode, then quit.  ORDER MATTERS — a
-- batch runs out of spawn order, so this is a CHAIN: write showCursor, then
-- rawMode False, then Io.quit (which sets the host's quit latch — the loop
-- breaks even with a re-armed readKey/mouse/resize eval still suspended, so a
-- delivery-time quit can no longer hang waiting on one more event).
exit =
  Task.perform (\_ -> EvIgnored)
    (Task.andThen (\_ -> Io.quit)
      (Task.andThen (\_ -> Io.rawMode False) (Io.writeString showCursor))
    )


outerUpdate config msg tea =
  case msg of
    EvKey key ->
      case key of
        -- stdin EOF is never a normal key: delegating + re-arming here would
        -- livelock (deliver -> update -> re-arm -> instant KeyEof), so take
        -- the exit path — no delegation, no re-arm.
        KeyEof ->
          ( tea, exit )

        _ ->
          let
            ( m1, c1 ) =
              config.update key tea.mod
          in
          if hasQuit c1 then
            ( tea, exit )

          else
            let
              ( tea1, frame ) =
                paint tea m1 (config.view m1)
            in
            ( tea1
            , Cmd.batch
                [ c1
                , repaint frame
                , Task.perform EvKey Io.readKey
                ]
            )

    -- The initial dims probe and every live SIGWINCH (the re-armed
    -- Io.waitResize below): the user's `resize` hook folds the dims into the
    -- user model, then the frame repaints at the new size.  prev is carried
    -- through, NOT forced to []: a key decoded before this delivery (startup
    -- typeahead) may already have painted a frame; forcing prev to [] would
    -- repaint over it with NO moveUp and leave the stale frame stuck on
    -- screen.  Carrying prev keeps paint's cursor invariant — at a true first
    -- paint prev is still [] and the first-frame branch is taken exactly as
    -- before.  The waitResize re-arm is FIRST in the batch: leafWaitResize
    -- blocks SIGWINCH + arms the signalfd before the frame write can become
    -- visible to the peer, so a `resize` directive can never race the arming.
    EvResize cols rows ->
      let
        m1 =
          config.resize cols rows tea.mod

        resized =
          { mod = m1, prev = tea.prev, rows = rows, cols = cols }

        ( tea1, frame ) =
          paint resized m1 (config.view m1)
      in
      ( tea1
      , Cmd.batch
          [ Task.perform resizeToEvent Io.waitResize
          , repaint frame
          ]
      )

    -- Quit marker delivered (only possible when the scan above missed):
    -- run the exit path, no re-arm.
    EvQuit ->
      ( tea, exit )

    -- Frame writes, raw-mode flips: nothing to do.
    _ ->
      ( tea, Cmd.none )


-- ---- renderer ----


{-| Pure renderer: given the tea model, the NEW user model, and the view's
new frame, return the updated model (mod = the new user model, prev = frame)
and the ONE string to write.  Invariant: every
line is written as "clear-line, text, \r\n", so the cursor always rests one
line BELOW the last painted line — a repaint moves up `len prev` lines first;
a frame that shrunk gets a clear-to-end (\e[J) after its last line; the first
paint hides the cursor.
-}
paint tea m frame =
  case tea.prev of
    [] ->
      ( { mod = m, prev = frame, rows = tea.rows, cols = tea.cols }
      , String.append hideCursor (frameString frame)
      )

    _ ->
      ( { mod = m, prev = frame, rows = tea.rows, cols = tea.cols }
      , String.append (moveUp (List.length tea.prev))
          (String.append (frameString frame)
            (if List.length frame < List.length tea.prev then
                clearRest

              else
                ""
            )
          )
      )


-- Wrap a frame string into a perform-wrapped write: the delivery lands on
-- the ignored branch of outerUpdate.
repaint frame =
  Task.perform (\_ -> EvIgnored) (Io.writeString frame)


frameString frame =
  String.join "" (map paintLine frame)


paintLine line =
  String.append clearLine (String.append line newline)


moveUp n =
  if n == 0 then
    ""

  else
    String.append "\u{1B}[" (String.append (String.fromInt n) "A")


newline = "\r\n"

clearLine = "\u{1B}[2K"

clearRest = "\u{1B}[J"

hideCursor = "\u{1B}[?25l"

showCursor = "\u{1B}[?25h"
