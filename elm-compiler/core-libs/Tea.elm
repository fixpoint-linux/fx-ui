module Tea exposing
  ( Config
  , program
  , quit
  , paint
  , skipRender
  )

-- M1 bubbletea-style core loop (charmbracelet/bubbletea's program loop,
-- subset-ported) over the M9 host Program substrate.  NOT an elm/core port —
-- this is fx-ui's terminal-UI runtime module, written in the subset the
-- checker accepts.
--
-- v2 (widgets-port S0): the app now receives Key AND Mouse events AND its own
-- messages (spinner ticks, etc.).  `Config msg model` names the app contract;
-- the app's `update` takes ITS OWN `msg`, produced by `onKey`/`onMouse` from a
-- decoded input or by the app's own commands.  The internal `FrameMsg` ADT
-- carries every host delivery (keys, mouse, resize, the user's own cmds mapped
-- back through `FUser`, quit, and side-effect ignores); `outerUpdate`
-- translates each into the app's message space and re-wraps the app's commands
-- with `Cmd.map FUser`.
--
-- Subset/architecture deviations from real bubbletea, all forced by the M9
-- cmd-driven loop and the checker surface:
--   * the input subscriptions are SELF-RE-ARMING TaskReadKey/TaskReadMouse
--     commands (the M9 loop delivers task results as the only messages; there
--     are no Subs) — every handled key re-arms `Io.readKey`, every handled
--     mouse event re-arms `Io.readMouse`, but quit and KeyEof/MouseEof do NOT:
--     KeyEof/MouseEof (stdin EOF) take the exit path directly and are never
--     delivered as normal input (a re-arm after them would spin — the host
--     completes every re-armed read with the EOF marker instantly once stdin
--     hits EOF);
--   * `view` returns List String (one string per terminal row) instead of a
--     full-screen view type (no String.split/`++` in the Prelude);
--   * quitting = appending `quit` (a [TaskQuit] command) to the command the
--     update returns; the payload-less Runtime.TaskQuit ctor is polymorphic in
--     BOTH Task params (Nothing : Maybe a class), so it inhabits any Cmd msg;
--     outerUpdate scans for it SYNCHRONOUSLY (ctor match, no equality) so the
--     readKey/readMouse re-arm is dropped on the quit event and the host's
--     eval set drains to zero (a delivery-time quit would leave a suspended
--     read and the program would hang waiting for one more event);
--   * the tea model is a plain record {mod, prev, rows, cols} — `mod` is the
--     user's model, `prev` the last painted frame (cursor rests one line
--     BELOW its last line), rows/cols the last resize dims;
--   * every frame is joined into ONE string -> ONE TaskWrite -> one write(2)
--     (PTY-deterministic single-write frames).


{-| The app contract.  `init`/`update`/`view`/`resize` are the same shape as
v1, but `update` now takes the APP'S OWN message type (produced by `onKey`/
`onMouse` from a decoded input, or by the app's own commands) and returns
`Cmd msg` of that same type.  `mouse` picks the terminal tracking mode —
`MouseModeOff` arms no readMouse at all.
-}
type alias Config msg model =
  { init : () -> ( model, Runtime.Cmd msg )
  , update : msg -> model -> ( model, Runtime.Cmd msg )
  , view : model -> List String
  , resize : Int -> Int -> model -> model
  , onKey : Runtime.Key -> msg
  , onMouse : Runtime.MouseMsg -> msg
  , mouse : Runtime.MouseMode
  }


-- The tea-internal model: the user's `mod` plus the painter's cursor state.
type alias TeaModel model =
  { mod : model
  , prev : List String
  , rows : Int
  , cols : Int
  }


{-| The messages `outerUpdate` handles.  `FKey`/`FMouse` carry a decoded
terminal input (translated through the app's onKey/onMouse); `FResize` the
cols/rows probe answered at startup and every live SIGWINCH; `FUser` the app's
own command deliveries (sleep ticks, etc.); `FQuit` a quit marker that escaped
the synchronous scan (defensive — the scan normally catches it first);
`FIgnored` the delivery of side-effect chains (frame writes, raw-mode flips,
mouse-mode flips).
-}
type FrameMsg msg
  = FKey Runtime.Key
  | FMouse Runtime.MouseMsg
  | FResize Int Int
  | FUser msg
  | FQuit
  | FIgnored


{-| Turn a user config `Config msg model` into a host Program.  init batches
the user's initial command (mapped into FUser space) with a RAW-MODE-FIRST
chain per input leaf: raw mode must be ON before the winsize probe / first
readKey / first readMouse (the first frame's \r\n is mangled by the tty's ONLCR
otherwise — the host runs batched tasks out of spawn order, so ordering here is
a chain, not a batch).

The mouse arm (mouseMode + readMouse) is included ONLY when `config.mouse` is
not MouseModeOff — a readMouse armed with tracking off would sit on fd0 and
never complete.  Each is chained after rawMode like the key arm.
-}
program config =
  let
    ( m0, c0 ) =
      config.init ()

    armed =
      case config.mouse of
        MouseModeOff ->
          False

        _ ->
          True
  in
  Platform.program
    { init =
        \_ ->
          ( { mod = m0, prev = [], rows = 0, cols = 0 }
          , Cmd.batch
              (List.append
                [ Cmd.map FUser c0
                , Task.perform resizeToFrame
                    (Task.andThen (\_ -> Io.winSize) (Io.rawMode True))
                , Task.perform FKey
                    (Task.andThen (\_ -> Io.readKey) (Io.rawMode True))
                ]
                (if armed then
                  [ Task.perform (\_ -> FIgnored)
                      (Task.andThen (\_ -> Io.mouseMode config.mouse) (Io.rawMode True))
                  , Task.perform FMouse
                      (Task.andThen (\_ -> Io.readMouse) (Io.rawMode True))
                  ]

                else
                  []
                )
              )
          )
    , update = \msg tea -> outerUpdate config msg tea
    , subscriptions = \_ -> Sub.none
    }


resizeToFrame size =
  FResize (Tuple.first size) (Tuple.second size)


{-| Append to the command your update returns to quit: outerUpdate sees the
marker synchronously, skips the repaint/re-arm, and runs the exit path.
-}
quit : Runtime.Cmd msg
quit =
  [ TaskQuit ]


-- The synchronous quit scan (see module header): True iff the command list
-- carries a TaskQuit.  A ctor match, not `==` (TaskQuit is a foreign ADT ctor
-- and `==` is comparable-only), and it runs on the synchronous command list so
-- the quit event itself drops the readKey/readMouse re-arm.
hasQuit : Runtime.Cmd msg -> Bool
hasQuit cmd =
  case cmd of
    [] ->
      False

    task :: rest ->
      case task of
        TaskQuit ->
          True

        _ ->
          hasQuit rest


-- Exit path: restore the cursor, drop raw mode, then quit.  ORDER MATTERS — a
-- batch runs out of spawn order, so this is a CHAIN: write showCursor, then
-- rawMode False, then Io.quit (which sets the host's quit latch — the loop
-- breaks even with a re-armed readKey/mouse/resize eval still suspended, so a
-- delivery-time quit can no longer hang waiting on one more event).
exit =
  Task.perform (\_ -> FIgnored)
    (Task.andThen (\_ -> Io.quit)
      (Task.andThen (\_ -> Io.rawMode False) (Io.writeString showCursor))
    )


outerUpdate : Config msg model -> FrameMsg msg -> TeaModel model -> ( TeaModel model, Runtime.Cmd (FrameMsg msg) )
outerUpdate config msg tea =
  case msg of
    FKey key ->
      case key of
        -- stdin EOF is never a normal key: delegating + re-arming here would
        -- livelock (deliver -> update -> re-arm -> instant KeyEof), so take
        -- the exit path — no delegation, no re-arm.
        KeyEof ->
          ( tea, exit )

        _ ->
          let
            ( m1, c1 ) =
              config.update (config.onKey key) tea.mod
          in
          delegate config tea m1 c1 [ Task.perform FKey Io.readKey ]

    FMouse mm ->
      case mm of
        -- stdin EOF, same as KeyEof: exit directly, never re-arm.
        MouseEof ->
          ( tea, exit )

        _ ->
          let
            ( m1, c1 ) =
              config.update (config.onMouse mm) tea.mod
          in
          -- Re-arm readMouse FIRST in the batch (waitResize discipline): the
          -- readMouse eval must be armed before the frame write, so a second
          -- wheel event that races the repaint is not missed.
          delegate config tea m1 c1 [ Task.perform FMouse Io.readMouse ]

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
    FResize cols rows ->
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
          [ Task.perform resizeToFrame Io.waitResize
          , repaint frame
          ]
      )

    -- The app's own command deliveries (sleep ticks, etc.): full delegation
    -- twin of FKey, but NO input re-arm — the command that produced this
    -- delivery self-re-arms via the commands it returns.
    FUser u ->
      let
        ( m1, c1 ) =
          config.update u tea.mod
      in
      delegate config tea m1 c1 []

    -- Quit marker delivered (only possible when the scan above missed):
    -- run the exit path, no re-arm.
    FQuit ->
      ( tea, exit )

    -- Frame writes, raw-mode flips, mouse-mode flips: nothing to do.
    FIgnored ->
      ( tea, Cmd.none )


-- Every delegating branch (FKey/FMouse/FUser) shares this shape: run the user
-- update, scan for quit, SKIP the repaint when the model is unchanged, repaint
-- otherwise, re-map the user command, then re-arm the inputs THAT BRANCH owns
-- (`rearm` — FKey readKey, FMouse readMouse, FUser nothing; re-arm FIRST in
-- the batch, waitResize discipline).
delegate : Config msg model -> TeaModel model -> model -> Runtime.Cmd msg -> List (Runtime.Cmd (FrameMsg msg)) -> ( TeaModel model, Runtime.Cmd (FrameMsg msg) )
delegate config tea m1 c1 rearm =
  if hasQuit c1 then
    ( tea, exit )

  else if skipRender tea m1 then
    -- Model structurally unchanged => config.view (pure in the model) would
    -- emit a byte-identical frame, so the repaint is skipped entirely — but
    -- the user's command c1 still runs and the input re-arms still fire.
    -- Never taken before the first paint (skipRender's prev == [] guard):
    -- nothing is on screen yet, so the first frame must always paint.
    ( { mod = m1, prev = tea.prev, rows = tea.rows, cols = tea.cols }
    , Cmd.batch (List.append rearm [ Cmd.map FUser c1 ])
    )

  else
    let
      ( tea1, frame ) =
        paint tea m1 (config.view m1)
    in
    ( tea1
    , Cmd.batch
        (List.append rearm [ Cmd.map FUser c1, repaint frame ])
    )


-- Should this delivery skip the repaint?  Only when a frame is already on
-- screen (prev /= [] — before the first paint the screen is NOT the old
-- frame's content, so the first frame always paints) AND the new user model
-- is structurally equal to the painted one (sameValue: the VM's deep
-- structural `=`, not the comparable-restricted `==`).  FResize repaints
-- unconditionally (its own branch — reflow at the new dims even when the
-- resize folds to the same model); quit/EOF take the exit paths before this.
skipRender : TeaModel model -> model -> Bool
skipRender tea m1 =
  case tea.prev of
    [] ->
      False

    _ ->
      sameValue tea.mod m1


-- ---- renderer ----


{-| Pure renderer: given the tea model, the NEW user model, and the view's
new frame, return the updated model (mod = the new user model, prev = frame)
and the ONE string to write.  The first paint (prev = []) hides the cursor
and writes every line ("clear-line, text, \r\n").  A repaint moves up
`len prev` rows, then writes the frame DIFFERENTIALLY: an unchanged line
emits only the \r\n advance (its row on screen is already exactly its
content), a changed line rewrites itself (clear-line + text + \r\n), lines
past prev's end are painted fully (new rows), and a frame that shrunk gets
a clear-to-end (\e[J) after its last line, wiping the stale rows below it.
Every emitted line ends in \r\n, so the cursor always rests one line BELOW
the last painted line and the next repaint's moveUp (len prev) lands exactly
on the old frame's first row.
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
          (String.append (diffString tea.prev frame)
            (if List.length frame < List.length tea.prev then
                clearRest

              else
                ""
            )
          )
      )


{-| The repaint body: walk prev and the new frame in lockstep.  An unchanged
line (==) costs ONLY the line advance; a changed line costs a full rewrite;
lines past prev's end are new rows and paint fully.  When prev runs out
first, the remaining frame lines are all new; when the frame runs out first
(shrunk), stop — paint appends clearRest for the stale rows below.
-}
diffString : List String -> List String -> String
diffString prev frame =
  case prev of
    [] ->
      frameString frame

    p :: prevRest ->
      case frame of
        [] ->
          ""

        line :: frameRest ->
          if line == p then
            String.append newline (diffString prevRest frameRest)

          else
            String.append (paintLine line) (diffString prevRest frameRest)


-- Wrap a frame string into a perform-wrapped write: the delivery lands on
-- the ignored branch of outerUpdate.
repaint frame =
  Task.perform (\_ -> FIgnored) (Io.writeString frame)


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
