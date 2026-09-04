module Stopwatch
  exposing
    ( Model
    , Msg (..)
    , elapsed
    , id
    , init
    , new
    , reset
    , running
    , start
    , stop
    , step
    , tick
    , toggle
    , update
    , view
    )

-- S9 bubbles stopwatch widget (charm.land/bubbles/v2 stopwatch, subset-ported
-- over the Tea v2 loop).  A count-UP: every accepted tick ADDS `intervalMs`
-- to `elapsedMs` and bumps `tag`; `tag` is the anti-double-tick guard —
-- after stop/start the chain re-arms with the tag captured at Start time, so
-- a stale duplicate tick (same tag as the accepted one) is rejected by the
-- accepted tick's tag++ ("heals" one stale tick per restart; Go's very first
-- restart at tag 0 slips through because the guard is `tag > 0` — ported
-- verbatim, hole included).  Like Spinner, `update` is MODEL-ONLY — the
-- delivery commands (`tick`/`start`/`stop`/`toggle`/`reset`) take an
-- `inject : Msg -> msg` argument and perform through the CALLER's `Msg`.
--
-- Subset deviations from Go, all forced by the runtime surface:
--   * integer milliseconds everywhere (`elapsedMs`/`intervalMs`) — no
--     time.Duration/float prims (the Progress.elm integer model); Go's `d`
--     field is `elapsedMs`;
--   * `new intervalMs` replaces Go's `New(WithInterval(...))`: Go's New()
--     actually leaves Interval at its ZERO value (the doc comment claims a
--     1s default the code does not implement — WithInterval is mandatory in
--     practice), so the interval is an explicit argument here;
--   * the package-global atomic `lastID` is gone: `id` is an app-owned model
--     field defaulting to 0 (record-update `{ m | id = 7 }` for
--     multi-stopwatch apps);
--   * Start performs StartStop THEN the sleeping Tick as one Cmd — Go uses
--     tea.Sequence, our Cmd is a 2-task batch, but the first task is an
--     INSTANT succeed and the Tick's sleep is chained behind
--     `Task.andThen (\_ -> Io.sleep i) (Task.succeed ())`, so the StartStop
--     delivery provably precedes the Tick (asyncorder proves batched host
--     tasks may otherwise overtake each other).  The Tick arms with the tag
--     captured at Start time, exactly like Go's tea.Sequence closure.
--   * View's Go `m.d.String()` is the hand-rolled integer `format` below,
--     private and duplicated from Timer.elm (see Timer's header for the
--     format rules); byte-identical to Go for ms-precision durations.

{-| The widget state.  `elapsedMs` counts up (Go `d`), `intervalMs` the tick
sleep, `id` the app-owned instance id, `tag` the anti-double-tick generation,
`running` the run flag (Go's unexported fields).  Go's New leaves the
stopwatch STOPPED with 0 elapsed — unlike the timer, init only ARMS on
Start.
-}
type alias Model =
  { elapsedMs : Int
  , intervalMs : Int
  , id : Int
  , tag : Int
  , running : Bool
  }


{-| The widget's own messages: the sleeping tick (carrying the arm-time id/
tag — Go TickMsg), the start/stop flip (Go StartStopMsg), and the zeroing
notice (Go ResetMsg).
-}
type Msg
  = Tick { id : Int, tag : Int }
  | StartStop { id : Int, running : Bool }
  | Reset { id : Int }


{-| Go's New(WithInterval(interval)): stopped, zero elapsed, tag 0.  (Go's
code default of a 0 interval is a doc bug — see the module header.)
-}
new : Int -> Model
new intervalMs =
  { elapsedMs = 0
  , intervalMs = intervalMs
  , id = 0
  , tag = 0
  , running = False
  }


-- ---- Go accessors ----


{-| Go ID().
-}
id : Model -> Int
id model =
  model.id


{-| Go Elapsed().
-}
elapsed : Model -> Int
elapsed model =
  model.elapsedMs


{-| Go Running().  (Unlike the timer, there is no timed-out state.)
-}
running : Model -> Bool
running model =
  model.running


-- ---- Tea surface ----


{-| Handle one message (Go Update minus the returned Cmd — the app re-arms
through `tick`/`start`).  A StartStop flips the run flag and a Reset zeroes
the elapsed time (both only for the matching id — the stopwatch, unlike the
timer, has NO id-0 wildcard); a Tick adds one interval and bumps the tag
ONLY when running, the id matches, and the tick's tag is either unset or
current.
-}
update : Msg -> Model -> Model
update msg model =
  case msg of
    StartStop ss ->
      if ss.id /= model.id then
        model

      else
        { model | running = ss.running }

    Reset r ->
      if r.id /= model.id then
        model

      else
        { model | elapsedMs = 0 }

    Tick t ->
      if not model.running || t.id /= model.id then
        model

      else if t.tag > 0 && t.tag /= model.tag then
        model

      else
        { model
          | elapsedMs = model.elapsedMs + model.intervalMs
          , tag = model.tag + 1
        }


{-| Render the elapsed time (Go View = d.String()).
-}
view : Model -> String
view model =
  format model.elapsedMs


{-| Go Update wholesale: the model transition (`update`) plus the Cmd Go's
update would return, delivered through `inject`.  This is the function an
APP calls from its own update — it needs no pattern matching on `Msg` (the
lowerer rejects cross-module ctor patterns), only a record-projected state.
Branches: an accepted Tick re-arms the tick (Go returns tick(id, m.tag,
m.Interval)); a tick landing on a stopped watch, a foreign-id tick and a
bad-tag tick arm nothing (Go's break); StartStop and Reset return no Cmd in
Go either — Start's own chained sleeping Tick is the restart's first beat.
-}
step : (Msg -> msg) -> Msg -> Model -> ( Model, Runtime.Cmd msg )
step inject msg model =
  case msg of
    Tick t ->
      if not model.running || t.id /= model.id then
        ( model, Cmd.none )
      else if t.tag > 0 && t.tag /= model.tag then
        ( model, Cmd.none )
      else
        let
          m1 =
            update msg model
        in
        ( m1, tick inject m1 )
    _ ->
      ( update msg model, Cmd.none )


{-| Go Init: start the stopwatch.
-}
init : (Msg -> msg) -> Model -> Runtime.Cmd msg
init inject model =
  start inject model


{-| The tick command: sleep `intervalMs`, then perform `Tick` armed with the
CURRENT model tag (Go's module-level tick()).  Re-ARM by returning this from
the app's Tick branch — the FUser branch of Tea's outerUpdate re-arms
nothing itself, the app's command is the re-arm.
-}
tick : (Msg -> msg) -> Model -> Runtime.Cmd msg
tick inject model =
  Task.perform
    (\_ -> inject (Tick { id = model.id, tag = model.tag }))
    (Io.sleep model.intervalMs)


{-| Go Start: the StartStop delivery, then the first sleeping Tick.  Go
spells this tea.Sequence(StartStop, tick); here the StartStop rides an
INSTANT succeed-task while the Tick's sleep is chained behind
`Task.andThen (\_ -> Io.sleep i) (Task.succeed ())` — a single task whose
sleep cannot begin until the succeed has completed — so the StartStop ALWAYS
delivers first no matter how the host interleaves the batch, and the Tick
arms with the tag captured at Start time (Go's closure).  Delivering them
out of order would drop the first tick (rejected while still stopped) and
freeze the stopwatch.
-}
start : (Msg -> msg) -> Model -> Runtime.Cmd msg
start inject model =
  Cmd.batch
    [ Task.perform
        (\_ -> inject (StartStop { id = model.id, running = True }))
        (Task.succeed ())
    , Task.perform
        (\_ -> inject (Tick { id = model.id, tag = model.tag }))
        (Task.andThen (\_ -> Io.sleep model.intervalMs) (Task.succeed ()))
    ]


{-| Go Stop: the immediate StartStop delivery.  A tick already in flight is
rejected when it lands (update gates on `running`) — and its stale tag can
no longer bite after the restart (see the module header).
-}
stop : (Msg -> msg) -> Model -> Runtime.Cmd msg
stop inject model =
  Task.perform
    (\_ -> inject (StartStop { id = model.id, running = False }))
    (Task.succeed ())


{-| Go Toggle.
-}
toggle : (Msg -> msg) -> Model -> Runtime.Cmd msg
toggle inject model =
  if running model then
    stop inject model

  else
    start inject model


{-| Go Reset: the immediate ResetMsg delivery (zeroes on processing; does
NOT stop the run).
-}
reset : (Msg -> msg) -> Model -> Runtime.Cmd msg
reset inject model =
  Task.perform (\_ -> inject (Reset { id = model.id })) (Task.succeed ())


-- ---- internals ----


{-| Go time.Duration.String() over integer milliseconds — byte-identical
copy of Timer.elm's private formatter (kept duplicated so each widget stays
self-contained; see Timer's header for the format rules).
-}
format : Int -> String
format ms =
  let
    neg =
      ms < 0

    u =
      if neg then
        0 - ms

      else
        ms

    body =
      if u == 0 then
        "0s"

      else if u < 1000 then
        String.append (String.fromInt u) "ms"

      else
        atLeastSecond u
  in
  if neg then
    String.append "-" body

  else
    body


atLeastSecond : Int -> String
atLeastSecond u =
  let
    totalSecs =
      u // 1000

    remMs =
      u - (totalSecs * 1000)

    secs =
      totalSecs - ((totalSecs // 60) * 60)

    secsStr =
      if remMs > 0 then
        String.append (String.fromInt secs) (String.append (frac remMs) "s")

      else
        String.append (String.fromInt secs) "s"

    totalMins =
      totalSecs // 60

    hours =
      totalMins // 60
  in
  if hours > 0 then
    String.fromInt hours
      ++ "h"
      ++ String.fromInt (totalMins - (hours * 60))
      ++ "m"
      ++ secsStr

  else if totalMins > 0 then
    String.fromInt totalMins ++ "m" ++ secsStr

  else
    secsStr


frac : Int -> String
frac remMs =
  let
    h =
      remMs // 100

    tens =
      remMs - (h * 100)

    t =
      tens // 10

    u =
      tens - (t * 10)
  in
  if u /= 0 then
    "." ++ String.fromInt h ++ String.fromInt t ++ String.fromInt u

  else if t /= 0 then
    "." ++ String.fromInt h ++ String.fromInt t

  else
    "." ++ String.fromInt h
