module Timer
  exposing
    ( Model
    , Msg (..)
    , id
    , init
    , new
    , running
    , start
    , startStop
    , stop
    , step
    , tick
    , timedout
    , timedoutCmd
    , toggle
    , update
    , view
    )

-- S9 bubbles timer widget (charm.land/bubbles/v2 timer, subset-ported over
-- the Tea v2 loop).  A countdown: `Timeout` decrements by `Interval` on every
-- accepted tick; once `Timeout <= 0` the timer is TIMED OUT and stops
-- responding to ticks (Go Running()/Timedout()).  Like Spinner, `update` is
-- MODEL-ONLY — the tick re-arm and the timeout fire live in the Cmd-returning
-- helpers (`tick`/`timedoutCmd`/`startStop`), which take an `inject :
-- Msg -> msg` argument and perform through the CALLER's `Msg`, so the APP
-- builds the re-arm in its own update (its Tick branch calls `tick` again).
--
-- ID routing + tag rejection are ported VERBATIM (Go timer.go Update): a
-- StartStop/Tick whose `id` is neither 0 nor the model's `id` is ignored (0
-- is the wildcard for apps that never set ids); a Tick with `tag > 0` that
-- does not match the model's `tag` is rejected — the anti-double-tick guard
-- for restarts.  The timer never increments its tag (Go's timer tag is
-- vestigial), so the guard only ever bites tags the app fabricates itself.
--
-- Subset deviations from Go, all forced by the runtime surface:
--   * integer milliseconds everywhere (`timeoutMs`/`intervalMs`) — there are
--     no time.Duration/float prims (the Progress.elm integer model);
--   * `new timeoutMs intervalMs` replaces Go's `New(timeout,
--     WithInterval(...))` variadic options (Key.newBinding precedent); Go's
--     default interval of 1s becomes the explicit second argument;
--   * the package-global atomic `lastID` is gone: `id` is an app-owned model
--     field defaulting to 0 (record-update `{ m | id = 7 }` for multi-timer
--     apps);
--   * View's Go `m.Timeout.String()` (time.Duration formatting) is the
--     hand-rolled integer `format` below, private and duplicated in
--     Stopwatch.elm: "0s", whole seconds "5s", sub-second "750ms" /
--     "-500ms", fractional ".5s"/".05s"/".005s" (ms written as 3 digits,
--     trailing zeros stripped), minutes "1m30s", hours "1h0m0s" (Go prints
--     the zero minutes and seconds under an hour component).  Byte-identical
--     to Go for every ms-precision duration; Go's ns/us digits are
--     unreachable in an ms runtime.

{-| The widget state.  `timeoutMs` counts down (Go Timeout), `intervalMs` is
the tick sleep (Go Interval, New's default 1s made explicit), `id` the
app-owned instance id, `tag` the anti-double-tick generation, `running` the
paused flag (Go's unexported fields).
-}
type alias Model =
  { timeoutMs : Int
  , intervalMs : Int
  , id : Int
  , tag : Int
  , running : Bool
  }


{-| The widget's own messages: the sleeping tick (carrying the arm-time id/
tag and whether the timer was ALREADY timed out when the tick was armed —
Go TickMsg.Timeout), the start/stop flip (Go StartStopMsg), and the one-shot
timeout notice (Go TimeoutMsg).
-}
type Msg
  = Tick { id : Int, tag : Int, timeout : Bool }
  | StartStop { id : Int, running : Bool }
  | Timedout { id : Int }


{-| Go's New(timeout, WithInterval(interval)): running immediately, tag 0.
-}
new : Int -> Int -> Model
new timeoutMs intervalMs =
  { timeoutMs = timeoutMs
  , intervalMs = intervalMs
  , id = 0
  , tag = 0
  , running = True
  }


-- ---- Go accessors ----


{-| Go ID().
-}
id : Model -> Int
id model =
  model.id


{-| Go Running(): false once timed out OR paused.
-}
running : Model -> Bool
running model =
  if timedout model || not model.running then
    False

  else
    True


{-| Go Timedout(): the countdown has reached zero.
-}
timedout : Model -> Bool
timedout model =
  model.timeoutMs <= 0


-- ---- Tea surface ----


{-| Handle one message (Go Update minus the returned Cmd — the app re-arms
through `tick`/`timedoutCmd`).  A StartStop just flips the paused flag
(unless the id mismatches); a Tick decrements the countdown ONLY when the
timer is running, the id matches (0 wildcards), and the tag is either unset
or current — a rejected tick changes nothing.
-}
update : Msg -> Model -> Model
update msg model =
  case msg of
    StartStop ss ->
      if ss.id /= 0 && ss.id /= model.id then
        model

      else
        { model | running = ss.running }

    Tick t ->
      if not (running model) || (t.id /= 0 && t.id /= model.id) then
        model

      else if t.tag > 0 && t.tag /= model.tag then
        model

      else
        { model | timeoutMs = model.timeoutMs - model.intervalMs }

    Timedout _ ->
      model


{-| Render the remaining time (Go View = Timeout.String()).
-}
view : Model -> String
view model =
  format model.timeoutMs


{-| Go Update wholesale: the model transition (`update`) plus the Cmd Go's
update would return, delivered through `inject`.  This is the function an
APP calls from its own update — it needs no pattern matching on `Msg` (the
lowerer rejects cross-module ctor patterns), only a record-projected state.
Branches: a StartStop re-arms the tick (Go returns m.tick()); an accepted
Tick re-arms, except the CROSSING tick which fires the timeout notice
instead (Go returns tea.Batch(tick, timedout) — the extra re-armed tick
would deliver once and be rejected, so skipping it only quiets the drain);
a rejected tick (stopped/timed out/foreign id/bad tag) and the Timedout
notice arm nothing (Go's break / no-op).
-}
step : (Msg -> msg) -> Msg -> Model -> ( Model, Runtime.Cmd msg )
step inject msg model =
  case msg of
    StartStop ss ->
      if ss.id /= 0 && ss.id /= model.id then
        ( model, Cmd.none )
      else
        let
          m1 =
            update msg model
        in
        ( m1, tick inject m1 )
    Tick t ->
      if not (running model) || (t.id /= 0 && t.id /= model.id) then
        ( model, Cmd.none )
      else if t.tag > 0 && t.tag /= model.tag then
        ( model, Cmd.none )
      else
        let
          m1 =
            update msg model
        in
        ( m1
        , if timedout m1 then
            timedoutCmd inject m1
          else
            tick inject m1
        )
    Timedout _ ->
      ( model, Cmd.none )


{-| Go Init: arm the first tick.  Re-ARM by returning this from the app's
Tick branch — the FUser branch of Tea's outerUpdate re-arms nothing itself,
the app's command is the re-arm.
-}
init : (Msg -> msg) -> Model -> Runtime.Cmd msg
init inject model =
  tick inject model


{-| The tick command: sleep `intervalMs`, then perform `Tick` armed with the
model's CURRENT id/tag/timedout (Go Model.tick).
-}
tick : (Msg -> msg) -> Model -> Runtime.Cmd msg
tick inject model =
  Task.perform
    (\_ ->
      inject (Tick { id = model.id, tag = model.tag, timeout = timedout model })
    )
    (Io.sleep model.intervalMs)


{-| Go's private timedout(): the one-shot timeout notice, fired by the app's
Tick branch when the crossing tick lands (`Timer.timedout t1`).  Delivers
immediately (no sleep).
-}
timedoutCmd : (Msg -> msg) -> Model -> Runtime.Cmd msg
timedoutCmd inject model =
  Task.perform (\_ -> inject (Timedout { id = model.id })) (Task.succeed ())


{-| Go's private startStop(): the immediate StartStop delivery.  Go sends
these "extraneous" messages (instead of mutating the model directly) so
callers never fight command-ordering pitfalls — the flip takes effect when
the app's update processes the StartStop.
-}
startStop : (Msg -> msg) -> Bool -> Model -> Runtime.Cmd msg
startStop inject v model =
  Task.perform
    (\_ -> inject (StartStop { id = model.id, running = v }))
    (Task.succeed ())


{-| Go Start: resume.  Has no visible effect on a timed-out timer (Running
stays false; the re-armed tick is rejected on delivery).
-}
start : (Msg -> msg) -> Model -> Runtime.Cmd msg
start inject model =
  startStop inject True model


{-| Go Stop: pause.  A tick already in flight is rejected when it lands
(`update` gates on `running`).
-}
stop : (Msg -> msg) -> Model -> Runtime.Cmd msg
stop inject model =
  startStop inject False model


{-| Go Toggle.
-}
toggle : (Msg -> msg) -> Model -> Runtime.Cmd msg
toggle inject model =
  startStop inject (not (running model)) model


-- ---- internals ----


{-| Go time.Duration.String() over integer milliseconds (see the module
header for the format; Go's ns/us digits are unreachable).  Negative
durations are reachable — interval > timeout drives Timeout below zero —
and format with a leading '-' exactly like Go.
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


{-| The `u >= 1s` branch of Go's format: seconds (with fraction), plus
minutes iff totalSecs >= 60, plus hours iff totalMins >= 60 — Go prints the
ZERO minutes and seconds components under a higher one ("1h0m0s").
-}
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


{-| The fractional-second suffix ".5" / ".05" / ".005": Go writes the
9-digit ns fraction with trailing zeros stripped; an ms remainder is that
same fraction with 6 known zeros, i.e. 3 digits with trailing zeros stripped
(leading zeros KEPT — 50ms renders ".05").
-}
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
