module Tea exposing
  ( Config
  , program
  , guiProgram
  , quit
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
--     user's model, `prev` the last SUBMITTED frame (skipRender's unchanged-
--     model guard), rows/cols the last resize dims; repaints address rows
--     ABSOLUTELY (\e[row;1H, host-side), so the cursor's
--     resting place between frames is irrelevant (and mosh's predictive local
--     echo, which parks the cursor anywhere, cannot derail a repaint);
--   * every frame is submitted as ONE TaskRender (the structured
--     Draw.Frame via Draw.fromAnsiLog) -> ONE host render(2): the HOST
--     TerminalRenderer (src/renderer/terminal.zig) diffs+paints with the
--     same per-row damage vocabulary (PTY-deterministic single-write
--     frames, byte-parity with the retired Elm-side paint).


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


-- The tea-internal model: the user's `mod` plus the submitted-frame state.
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
  | FGui GuiEv
  | FUser msg
  | FQuit
  | FIgnored


{-| The GUI events the host completes TaskGuiPoll with (the fixed-size
self-pipe record decode in src/effectloop.zig leafGuiPoll/guiBuildEvent —
the ctor spellings GKey/GMouse/GResize/GClose/GIgnore are the host
contract).  GKey/GMouse carry the SAME decoded Key/MouseMsg values the
terminal readKey/readMouse leaves build, so the app's onKey/onMouse hooks
are unchanged; GResize carries the window size in CELLS; GClose is the
window-close / SDL-QUIT event; GIgnore marks a swallowed record (an unmapped
scancode or a filtered text byte) — re-armed, never delegated to the app.
-}
type GuiEv
  = GKey Runtime.Key
  | GMouse Runtime.MouseMsg
  | GResize Int Int
  | GClose
  | GIgnore


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


-- The terminal path: every repaint is the structured Frame (view ->
-- frameRepaintLog -> Io.renderFrame); the HOST diffs and paints (the
-- frameRepaintLog body: store the view as prev — skipRender parity — and
-- submit the SGR-event-log Frame).  Shape unchanged from the Elm-paint
-- version — same branches, same re-arm discipline; only the paint mechanism
-- moved behind the seam.
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
          -- readMouse eval must be armed before the frame render, so a second
          -- wheel event that races the repaint is not missed.
          delegate config tea m1 c1 [ Task.perform FMouse Io.readMouse ]

    -- The initial dims probe and every live SIGWINCH (the re-armed
    -- Io.waitResize below): the user's `resize` hook folds the dims into the
    -- user model, then the frame repaints at the new size.  prev is carried
    -- through, NOT forced to []: a key decoded before this delivery (startup
    -- typeahead) may already have painted a frame; forcing prev to [] would
    -- skipRender away the repaint and leave the stale frame stuck on screen.
    -- Carrying prev keeps skipRender's invariant — at a true first paint prev
    -- is still [] and the first frame always paints.  The waitResize re-arm
    -- is FIRST in the batch: leafWaitResize blocks SIGWINCH + arms the
    -- signalfd before the frame render can become visible to the peer, so a
    -- `resize` directive can never race the arming.  FResize repaints
    -- unconditionally (reflow at the new dims even when the resize folds to
    -- the same model).
    FResize cols rows ->
      let
        m1 =
          config.resize cols rows tea.mod

        ( tea1, rc ) =
          frameRepaintLog config { mod = m1, prev = tea.prev, rows = rows, cols = cols } m1
      in
      ( tea1
      , Cmd.batch
          [ Task.perform resizeToFrame Io.waitResize
          , rc
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

    FGui _ ->
      -- not a GUI program; a stray GuiEv delivery (mixed harness) is a no-op
      ( tea, Cmd.none )

    -- Quit marker delivered (only possible when the scan above missed):
    -- run the exit path, no re-arm.
    FQuit ->
      ( tea, exit )

    -- Frame renders, raw-mode flips, mouse-mode flips: nothing to do.
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
      ( tea1, rc ) =
        frameRepaintLog config tea m1
    in
    ( tea1
    , Cmd.batch
        (List.append rearm [ Cmd.map FUser c1, rc ])
    )


-- guiRepaint's body with fromAnsi swapped for fromAnsiLog: the terminal
-- seam carries the SGR-event markers so the HOST renderer reproduces the
-- exact byte stream (stacked nested prefixes included), while prev still
-- stores the raw view (skipRender parity).
frameRepaintLog : Config msg model -> TeaModel model -> model -> ( TeaModel model, Runtime.Cmd (FrameMsg msg) )
frameRepaintLog config tea m =
  let
    frame =
      config.view m
  in
  ( { mod = m, prev = frame, rows = tea.rows, cols = tea.cols }
  , render (Draw.fromAnsiLog frame)
  )


{-| The GUI twin of `program` (photon-gui P2): the SAME Config renders into
the host's SDL window instead of the terminal — apps switch backends at ONE
call site.  init arms guiOpen plus ONE self-re-arming guiPoll (the GUI
analogue of the rawMode->winSize->readKey(+mouse) chain); the window's first
event is the host's initial GResize at the real cell size, which triggers
the first paint.  The app-side view pipeline is UNCHANGED: `view` still
returns List String, and GUI mode feeds it through Draw.fromAnsi and
submits the STRUCTURED Frame to the host (TaskRender) — damage tracking and
presenting are host-side (rencache, dirty rects only).  (Since the P4
switch the TERMINAL path renders host-side too — the Elm-side
Tea.paint/diffString painter is retired; the two modes differ only in the
parser: plain fromAnsi here, the SGR-event-log fromAnsiLog on the terminal
seam.)  `config.mouse` is ignored: the window delivers mouse
events through guiPoll, so no tracking mode is armed.  Exit = GClose (window
close) or the app's quit, both via guiClose + the quit latch.

Fail-soft: without a window backend (-Dgui off) guiOpen/guiPoll complete
unit, the GUI branch treats that as a non-event, no re-arm fires, and the
program drains to exit instead of hanging.
-}
guiProgram config =
  let
    ( m0, c0 ) =
      config.init ()
  in
  Platform.program
    { init =
        \_ ->
          ( { mod = m0, prev = [], rows = 0, cols = 0 }
          , Cmd.batch
              [ Cmd.map FUser c0
                -- guiOpen completes synchronously BEFORE the guiArm eval
                -- steps (batch spawn order + a synchronous leaf), so the
                -- window and its initial-size record exist by then.
              , Task.perform (\_ -> FIgnored) (Io.guiOpen "fx-ui" 80 24)
              , guiArm
              ]
          )
    , update = \msg tea -> guiUpdate config msg tea
    , subscriptions = \_ -> Sub.none
    }


-- The GUI poll arm: exactly ONE guiPoll eval is armed at a time (the
-- readKey/readMouse re-arm discipline); every GUI branch re-arms it.
-- Task.perform already yields a Cmd (a Task list) — no extra [ ] wrap.
guiArm : Runtime.Cmd (FrameMsg msg)
guiArm =
  Task.perform FGui TaskGuiPoll


-- GUI update: the FGui branch handles GUI events; everything else (FUser
-- deliveries, FIgnored render/frame writes, FQuit, and the terminal
-- branches for a mixed harness) is outerUpdate's.
guiUpdate : Config msg model -> FrameMsg msg -> TeaModel model -> ( TeaModel model, Runtime.Cmd (FrameMsg msg) )
guiUpdate config msg tea =
  case msg of
    FGui ev ->
      guiEvent config tea ev

    _ ->
      outerUpdate config msg tea


guiEvent : Config msg model -> TeaModel model -> GuiEv -> ( TeaModel model, Runtime.Cmd (FrameMsg msg) )
guiEvent config tea ev =
  case ev of
    GKey key ->
      case key of
        -- Defensive only (the host sends GClose for window close, never a
        -- GUI KeyEof): take the exit path, no delegation, no re-arm.
        KeyEof ->
          ( tea, guiExit )

        _ ->
          let
            ( m1, c1 ) =
              config.update (config.onKey key) tea.mod
          in
          delegateGui config tea m1 c1

    GMouse mm ->
      case mm of
        MouseEof ->
          ( tea, guiExit )

        _ ->
          let
            ( m1, c1 ) =
              config.update (config.onMouse mm) tea.mod
          in
          delegateGui config tea m1 c1

    -- The window resized (the initial size arrives the same way): fold the
    -- cell dims through the app's resize hook and repaint at the new size —
    -- the host resets its damage grid (full repaint) on its side.
    GResize cols rows ->
      let
        m1 =
          config.resize cols rows tea.mod

        ( tea1, rc ) =
          guiRepaint config { mod = m1, prev = tea.prev, rows = rows, cols = cols } m1
      in
      ( tea1, Cmd.batch [ guiArm, rc ] )

    GClose ->
      ( tea, guiExit )

    -- A swallowed host record (unmapped scancode, filtered text byte): not
    -- an app event — just keep polling.
    GIgnore ->
      ( tea, guiArm )

    -- The stub backend (no -Dgui) completes guiPoll with unit: not a GuiEv.
    -- No re-arm — the program drains to exit (fail-soft open).
    _ ->
      ( tea, Cmd.none )


-- The GUI delegate twin: run the user update, scan for quit, skip the
-- render when the model is unchanged (same skipRender contract), else
-- repaint through the structured-Frame pipeline.  The re-arm is guiArm (the
-- single GUI poll), FIRST in the batch (waitResize discipline).
delegateGui : Config msg model -> TeaModel model -> model -> Runtime.Cmd msg -> ( TeaModel model, Runtime.Cmd (FrameMsg msg) )
delegateGui config tea m1 c1 =
  if hasQuit c1 then
    ( tea, guiExit )

  else if skipRender tea m1 then
    ( { mod = m1, prev = tea.prev, rows = tea.rows, cols = tea.cols }
    , Cmd.batch [ guiArm, Cmd.map FUser c1 ]
    )

  else
    let
      ( tea1, rc ) =
        guiRepaint config tea m1
    in
    ( tea1
    , Cmd.batch [ guiArm, Cmd.map FUser c1, rc ]
    )


-- Paint one frame in GUI mode: store the view as prev (skipRender parity)
-- and submit Draw.fromAnsi view as a TaskRender Frame — the host owns the
-- damage cache and presents only dirty cells.  NO ANSI string building or
-- diffing happens on the Elm side anywhere since the P4 switch (the terminal
-- seam's twin, frameRepaintLog, swaps in fromAnsiLog for the exact-byte
-- SGR-event replay).
guiRepaint : Config msg model -> TeaModel model -> model -> ( TeaModel model, Runtime.Cmd (FrameMsg msg) )
guiRepaint config tea m =
  let
    frame =
      config.view m
  in
  ( { mod = m, prev = frame, rows = tea.rows, cols = tea.cols }
  , render (Draw.fromAnsi frame)
  )


-- Submit one Frame to the host renderer (TaskRender): the delivery lands on
-- the ignored branch of guiUpdate/outerUpdate.
render frame =
  Task.perform (\_ -> FIgnored) (Io.renderFrame frame)


-- GUI exit path: tear the window down, then set the host quit latch (a
-- batch runs out of spawn order, so this is a CHAIN like `exit`).  No
-- raw-mode / alt-screen / cursor restore: the terminal was never touched.
guiExit =
  Task.perform (\_ -> FIgnored)
    (Task.andThen (\_ -> Io.quit) Io.guiClose)


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
      (Task.andThen (\_ -> Io.rawMode False)
        (Io.writeString (String.append showCursor leaveAltScreen))
      )
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


-- The byte-painting the retired Elm-side renderer emitted (first paint
-- = enterAltScreen + hideCursor + clear-line/row/CRLF walk; repaint =
-- per-row \e[row;1H + \e[2K; shrink = \e[n+1;1H + \e[J) is now the HOST
-- TerminalRenderer's contract (src/renderer/terminal.zig, unit-pinned in
-- terminal_test.zig, byte-parity-pinned by the pty fixtures).  Only the
-- EXIT side still writes bytes here.


-- Alternate-screen entry/exit.  mosh's predictive local echo echoes the FIRST
-- typed char (it has no full-screen cue yet), which paints a stray line on the
-- very first keypress.  Entering the alternate screen (\e[?1049h) is the
-- standard signal that a program is full-screen (vim/htop do this), which makes
-- mosh disable local echo for the session — so the first keypress stops
-- echoing.  The ENTRY side is the host renderer's first-paint bytes; only the
-- LEAVE side is still written here (the exit chain).
showCursor = "\u{1B}[?25h"

leaveAltScreen = "\u{1B}[?1049l"
