#!/usr/bin/env bash
# run-elm-gate.sh — M1b gate runner (BATCH mode).
#
# For each fixture under tests/elm-fixtures, compiles it with the elm-compiler
# (node run.js -> .csexp), loads it into the ZINC VM via elmvm, runs the named
# function with the given args, and diffs the printed value against
# expected/<name>.txt.
#
# Since S8 the compile step is BATCHED: the fixed corpus (Prelude + Runtime +
# the seven core-libs) is parsed+typechecked+lowered ONCE, and every fixture
# group is compiled in the SAME node run.js process against the cached corpus.
# The script declares all fixtures up front (registering each (sources, output)
# group + its post-compile check), calls run.js ONCE with a batch manifest, then
# runs the elmvm/diff checks in declaration order — the PASS/FAIL output and
# counts are byte-identical to the pre-batch runner.
#
# Usage:
#   tests/elm-fixtures/run-elm-gate.sh [elmvm-binary] [elm-compiler-dir] [fixtures-dir]
#
# Defaults assume you are running from the fx-ui repo root:
#   elmvm    -> zig-out/bin/elmvm   (built via `zig build elmvm`)
#   compiler -> elm-compiler/       (compiler.js built via build.sh)
#   fixtures -> tests/elm-fixtures
#
# NOTE: M6's iofile fixture resolves input/hello.txt and out/hello.out RELATIVE
# TO THE PROCESS CWD (the stream prims take plain paths), so the gate MUST be
# started from the repo root.
#
# Exit code 0 iff every check passes.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

ELMVM="${1:-$ROOT/zig-out/bin/elmvm}"
PTYTEST="${PTYTEST:-$ROOT/zig-out/bin/ptytest}"
CDIR="${2:-$ROOT/elm-compiler}"
FIX="${3:-$ROOT/tests/elm-fixtures}"
OUT="$(mktemp -d)"

if [ ! -x "$ELMVM" ]; then
  echo "error: elmvm not found at $ELMVM (run: zig build elmvm)" >&2
  exit 2
fi
if [ ! -x "$PTYTEST" ]; then
  echo "error: ptytest not found at $PTYTEST (run: zig build elmvm ptytest)" >&2
  exit 2
fi
if [ ! -f "$CDIR/compiler.js" ]; then
  echo "error: $CDIR/compiler.js missing (run: build.sh)" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq required to build the batch manifest" >&2
  exit 2
fi

pass=0; fail=0

# Derive a fixture's Elm MODULE NAME by scanning its `module X ...` header.
module_name() {
  awk '/^module /{print $2; exit}' "$1"
}

# read_expected <name> -> trims the trailing newline
read_expected() { cat "$FIX/expected/$1.txt"; }

# ============================ PHASE 1: declare ============================
# Every fixture call registers (a) its compile GROUP (user source file(s) +
# output .csexp) and (b) its post-compile CHECK.  Nothing compiles or runs
# elmvm yet; the checks fire in declaration order after the one batch compile.

ngroup=0; ncheck=0
declare -a GOUT GSRC
declare -a CKIND CNAME CFN CEXP CARG CSTDIN CFIX COUT

register_group() {
  local out="$1"; shift
  GOUT[$ngroup]="$out"
  GSRC[$ngroup]="$*"
  ngroup=$((ngroup+1))
}

add_check() {
  CKIND[$ncheck]="$1"; CNAME[$ncheck]="$2"; CFN[$ncheck]="$3"
  CEXP[$ncheck]="$4"; CARG[$ncheck]="$5"; CSTDIN[$ncheck]="$6"
  CFIX[$ncheck]="$7"; COUT[$ncheck]="$8"
  ncheck=$((ncheck+1))
}

# run <name> <fn> <expected> [args...]
#
# Entry resolution: since M3 keys defuns under QUALIFIED names ("<Mod>.<fn>",
# e.g. "Fib.fib"), the runner first calls "<Mod>.<fn>" with the module name
# scanned from the fixture header; bundles from older-style/anonymous content
# still fall back to the bare name.
run() {
  local name="$1" fn="$2" exp="$3"; shift 3
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check run "$name" "$fn" "$exp" "$*" "" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# run2 <name> <auxname> <fn> <expected>: multi-module fixture — compile
# <aux>.elm TOGETHER WITH <name>.elm (cross-module import); entry is looked
# up under "<NameModule>.<fn>" scanned from the MAIN fixture header.
run2() {
  local name="$1" aux="$2" fn="$3" exp="$4"; shift 4
  register_group "$OUT/$name.csexp" "$FIX/$aux.elm" "$FIX/$name.elm"
  add_check run2 "$name" "$fn" "$exp" "" "" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# run_io <name> <fn> <expected> <stdin-file>
#
# Like run(), but elmvm's stdin is redirected from "$FIX/input/<stdin-file>"
# instead of being inherited — the M6 stream-prims fixtures (Cmd.readLine via
# read-byte on fd 0) consume stdin.  Still checks the printed FINAL MODEL.
run_io() {
  local name="$1" fn="$2" exp="$3" stdin="$4"
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check io "$name" "$fn" "$exp" "" "$stdin" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# compile_error <name> <expected-substring>: asserts compilation emits
# "err <message>" and that <message> contains the expected substring.  Used for
# fixtures that must FAIL to compile (duplicate/unknown names, etc.) rather than
# run through the value gate.
compile_error() {
  local name="$1" exp="$2"
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check err "$name" "" "$exp" "" "" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# pty <name> <fn> <script-name>: compile <name>.elm, then run it under a real
# pseudo-terminal via ptytest, driving the script tests/elm-fixtures/scripts/
# <script-name> (send/expect/expect_exit).  PASS iff ptytest exits 0 AND its
# output starts with 'PASS'.
pty() {
  local name="$1" fn="$2" script="$3"
  register_group "$OUT/$name.csexp" "$FIX/$name.elm"
  add_check pty "$name" "$fn" "" "" "$script" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# pty_app <name> <fn> <script-name> <app-source>: like pty, but compiles an
# out-of-tree example app (examples/<app-source>) TOGETHER with the fixture
# (which re-exports its main), and runs under ptytest from a FRESH TEMP CWD so
# the app's relative-file persistence (todos.txt) never clobbers a real file
# nor leaks state between gate runs.  module_name is scanned from the fixture.
pty_app() {
  local name="$1" fn="$2" script="$3" app="$4"
  register_group "$OUT/$name.csexp" "$ROOT/examples/$app" "$FIX/$name.elm"
  add_check ptycwd "$name" "$fn" "" "" "$script" "$FIX/$name.elm" "$OUT/$name.csexp"
}

# out_cmp <name>: compare the raw file an elmvm run wrote (iofile's hello.out)
# against its expected bytes.
out_cmp() {
  add_check cmp "$1" "" "" "" "" "" ""
}

run fib        fib        "$(read_expected fib)"        10
run rtl1       main       "$(read_expected rtl1)"
run rtl2       main       "$(read_expected rtl2)"
run sub        sub        "$(read_expected sub)"        10 3
run sub        sub        "-7"                           3 10
run div        main       "$(read_expected div)"
run nested     main       "$(read_expected nested)"
run closure    main       "$(read_expected closure)"
run applytwice main       "$(read_expected applytwice)"
run countdown  countdown  "$(read_expected countdown)"  100000
run eqlist     main       "$(read_expected eqlist)"
run const      answer     "$(read_expected const)"
run partial    main       "$(read_expected partial)"
run subpartial main       "$(read_expected subpartial)"
run overapply  main       "$(read_expected overapply)"
run curry      main       "$(read_expected curry)"
run opvalue    main       "$(read_expected opvalue)"
run crossref   main       "$(read_expected crossref)"
run selfqual   main       "$(read_expected selfqual)"
# --- M2: case/pattern compiler, ADTs, records, short-circuit ---
run listcase    main       "$(read_expected listcase)"
run adteval     main       "$(read_expected adteval)"
run adtcase     main       "$(read_expected adtcase)"
run letcase     main       "$(read_expected letcase)"
run countcase   main       "$(read_expected countcase)"
run patterns    main       "$(read_expected patterns)"
run boolcase    main       "$(read_expected boolcase)"
run records     main       "$(read_expected records)"
run shortcircuit main      "$(read_expected shortcircuit)"
# --- M3: prelude (List API over 1000 elems), strings, multi-module ---
run biglist    main       "$(read_expected biglist)"
run strings    main       "$(read_expected strings)"
run2 multimod  auxlib     main       "$(read_expected multimod)"
# --- M4: floats ---
run floatlit     main  "$(read_expected floatlit)"
run floatarith   main  "$(read_expected floatarith)"
run floatdiv     main  "$(read_expected floatdiv)"
run floatmix     main  "$(read_expected floatmix)"
run floatcmp     main  "$(read_expected floatcmp)"
run floatfun     area  "$(read_expected floatfun)"     2.0
run floatpartial main  "$(read_expected floatpartial)"
run floatineq    main  "$(read_expected floatineq)"
# --- MX: terminal pure-core composed programs (main : Int / String) ---
run mxint     main   "$(read_expected mxint)"
run mxstring  main   "$(read_expected mxstring)"
# --- M6: I/O effects runtime (self-hosted Platform; stream prims) ---
# iofile: RdFile round-trip — the final String model is printed (printValue
# wraps it in quotes) AND the raw file is written to out/hello.out.
run_io iofile  main   "$(read_expected iofile)" hello.txt
out_cmp iofile
# ioecho: readLine echo-until-quit — echoed lines + the final Int count.
run_io ioecho  main   "$(read_expected ioecho)" echo.txt
# --- M7: async Kernel (Task monad + effect-manager loop) ---
run taskpure     main   "$(read_expected taskpure)"
run taskseq      main   "$(read_expected taskseq)"
run taskattempt  main   "$(read_expected taskattempt)"
# --- M8: process execution (exec-plan + env/cwd prims) ---
run execpipe     main   "$(read_expected execpipe)"
run execenv      main   "$(read_expected execenv)"
run execglob     main   "$(read_expected execglob)"
# --- M9: TRUE nonblocking async (host event loop drives a Program) ---
run asyncorder   main   "$(read_expected asyncorder)"
run fastexec     main   "$(read_expected fastexec)"
run asyncpure    main   "$(read_expected asyncpure)"
compile_error dup          "duplicate top-level definition in Dup: f"
compile_error shadowerr    "is both a top-level definition and imported via"
compile_error shadowtyperr "is both a top-level definition and imported via"
compile_error ambimperr    "from two different modules"

# --- M1 bubbletea: terminal Key ADT compiler surface (pure, no terminal) ---
run keyunit     main   "$(read_expected keyunit)"
# --- M1 STEP 2: host terminal substrate (raw mode + nonblocking readKey) ---
pty rawpty      main   rawpty.script
# --- M1 STEP 3: Tea core loop — pure renderer, byte-exact ANSI frame stream ---
run teaunit     main   "$(read_expected teaunit)"
# --- M1 STEP 4: TextInput widget + teademo (Tea program under a real pty) ---
pty teademo     main   teademo.script

# --- elm/core 1.0.5 runtime ports: structural Basics.compare + Dict/Set/Maybe/Result ---
# cmporder runs FIRST: it is the char-code wrapper ARG ORDER smoke test for the
# structural compare ("ab" vs "b" must be LT via byte 97 < 98).
run cmporder    main   "$(read_expected cmporder)"
run resultmaybe main   "$(read_expected resultmaybe)"
run dictbasic   main   "$(read_expected dictbasic)"
run setops      main   "$(read_expected setops)"
run dictstress  main   "$(read_expected dictstress)"

# --- elm/core Bitwise + Array port (vector JsArray substitute, RRB tree) ---
# bitwise: int32 semantics pins for the 7 zinc-vm prims (truncation, count
# &31 masking, arithmetic vs zero-fill right shift, doc examples).
run bitwise     main   "$(read_expected bitwise)"
# arraybasic: sizes 0/1/5/32/33/64/100 (first Leaf at 32) — length/foldl/get
# corners, set OOB no-op + persistence, push 31->33 crossing, roundtrips,
# map/indexedMap/filter, repeat, append, slice doc cases, toIndexedList/Tuple.
run arraybasic  main   "$(read_expected arraybasic)"
# arraystress: 1023/1024/1025 (depth-2->3 boundary at 32*32) + 1000 — sums,
# set-every-32nd, foldr order check, push 1023->1026, append, deep slices,
# fromList 1025 positional roundtrip, map/filter over 1024, persistence.
run arraystress main   "$(read_expected arraystress)"

# --- S1 (M-FOUNDATION): core-libs/Str.elm string toolkit + Prelude.List.take ---
# strunit: width (ANSI-skip + UTF-8 cell tables), split/lines/repeat/pad/
# truncate/replace/affixes/trim/countChar, List.take, trusted Str.fromFloat.
run strunit     main   "$(read_expected strunit)"
# p2pad: the P2-9 native Str.repeat prim (n=0/1/40, negative, empty) + the
# padLeft/padRight cell-width interplay that rides it.
run p2pad       main   "$(read_expected p2pad)"

# --- S2 (M-FOUNDATION): core-libs/Lipgloss.elm faithful v1.1.0 port ---
# lgunit: byte-exact pure renders (SGR param order incl. the v1.1.0 duplicate
# underline-4; color parser RGB/ANSI256/ANSI16; padding/width/align; normal+
# rounded border boxes + the corner-suppression matrix; marginBg margins;
# maxWidth/maxHeight; joinH/joinV/place; width/height/size; CJK box width).
run lgunit      main   "$(read_expected lgunit)"

# --- S3 (M-FOUNDATION): host TaskNow/Sleep/Quit leaves (monotonic time) ---
# nowunit: sleep 30 then now-diff >= 25 (CLOCK_MONOTONIC, not the wall-clock
# get-time prim) + a two-sleep ORDER chain (sequential sleeps take >= 40ms).
run nowunit     main   "$(read_expected nowunit)"

# --- S4 (M-FOUNDATION): host mouse input (SGR decode + shared event queue) ---
# mouseunit: AllMotion mouse mode + readMouse loop — press/release/wheel SGR
# packets decode to press:left@4,2 / release:left@4,2 / wheel:up@4,2; 'q' quits.
pty mouseunit   main   mouseunit.script
# mousemix: readKey AND readMouse BOTH armed; one send interleaves 'a' + click
# + 'b' — the shared queue must route each event to the right reader.
pty mousemix    main   mousemix.script

# --- S5 (M-FOUNDATION): SIGWINCH resize (signalfd + TaskWaitResize) ---
# resizeunit: initial 80x24 probe (Io.winSize), `resize 40 12` -> SIGWINCH ->
# waitResize delivers 40x12 + re-arms; 'q' quits via the S3 quit latch.
pty resizeunit  main   resizeunit.script

# --- S6 (M-FOUNDATION): host dir/stat leaves (getdents64 + fstatat) ---
# dirunit: Io.listDir over input/dirlist — '.'/'..' skipped, isDir from dirent
# d_type; RAW fs order re-sorted through Set for a deterministic join.
run dirunit     main   "$(read_expected dirunit)"
# statunit: Io.stat size + isDir/isFile + mode S_IFMT type bits (NOT mtime) +
# the zero-record failure parity for a missing path.
run statunit    main   "$(read_expected statunit)"

# --- M-FOUNDATION S7: Tea + Lipgloss integration demo (lgdemo) ---
# The composing proof: a Tea program whose view is a Lipgloss rounded-border
# box (cyan edges, bold-cyan nested title, padding, width = probed cols) split
# into frame rows by Str.lines.  Every key re-renders with a changed n=/last=
# field; a live `resize 40 12` (Tea re-arms Io.waitResize on every EvResize)
# re-renders the box at the new dims; Enter quits via the S3 quit latch.
pty lgdemo      main   lgdemo.script

# --- S0 (M-FOUNDATION): Tea v2 — Key+Mouse+own-message loop ---
# tea2unit: FUser wrap (init's Io.sleep 50 -> Tick delivered through Tea's
# Cmd.map FUser + delegated to the app) + tick re-arm (each Tick re-arms the
# sleep) + TaskQuit scan (quit after 2 ticks -> hasQuit -> exit chain -> exit 0).
# pty row: Tea always arms readKey, and a plain elmvm run's EOF stdin would exit
# via KeyEof before the first tick deadline is flushed.
pty tea2unit    main   tea2unit.script

# --- S1 (M-WIDGETS): bubbles key bindings + Str.contains/cut ---
# kbunit: keyName over EVERY Runtime.Key ctor (Go key.String() parity), the
# matches matrix (first/later binding, space, ctrl+c, misses, empty list),
# disabled/setEnabled/unbind semantics, accessors, Str.contains substring
# matrix, Str.cut cell windows (escapes verbatim before/after/inside, wide
# rune straddle, end<=start).
run kbunit      main   "$(read_expected kbunit)"

# --- S2 (M-WIDGETS): the pure bubbles widgets — help, paginator, progress ---
# helpunit: short help renders (default dark styles, disabled filtering,
# item-granular width truncation incl. the strict-< ellipsis-tail rule and
# the overflow-without-tail case), full help columns (JoinHorizontal Top,
# disabled columns/members, ellipsis column), view dispatch.
run helpunit    main   "$(read_expected helpunit)"
# pagunit: ceil SetTotalPages, GetSliceBounds/ItemsOnPage (incl. Go's
# negative count past the end), page clamps, key navigation (next before
# prev, disabled bindings, misses), arabic "%d/%d" (format field FIXED — no
# printf), default + pre-styled dots.
run pagunit     main   "$(read_expected pagunit)"
# progunit: integer permille ViewAs — byte-exact bars (SGR pair per
# segment, zero-width repeats still emit the pair), truncating fw/pct
# arithmetic, clamps, percentage reserving bar cells, 256-color fills,
# custom fill chars.
run progunit    main   "$(read_expected progunit)"

# --- S3 (M-WIDGETS): the spinner — the FIRST Cmd-producing widget ---
# spinunit: fpsMs floors of Go's time.Second/N, byte-exact frames of all six
# presets (Dot's trailing spaces + MiniDot braille are Go parity), the
# update-fold advance + wrap (line 4-tick, Dot 8-tick), the "(error)" guard,
# one styled render (fg SGR pair through Lipgloss).
run spinunit    main   "$(read_expected spinunit)"
# spinnerdemo: the tick re-arm under a real pty — init arms Io.sleep 100, and
# every delivered Tick returns the NEXT tick command (Tea's FUser branch
# re-arms nothing; the app's command IS the re-arm).  Needles span frame
# boundaries (prev tail \r\n -> \e[1;1H\e[2K<next>) so tick timing is never
# asserted (R4); 'q' exercises the TaskQuit scan with a tick still pending.
pty spinnerdemo main   spinnerdemo.script

# --- S4 (M-WIDGETS): the viewport — the first COMPLEX interactive widget ---
# vpunit: byte-exact PLAIN renders at a fixed size (vertical scroll states via
# `update` key folds + the scroll/mouse ops), x-scroll through the Str.cut
# window, the frame arithmetic (maxYOffset/maxXOffset), init defaults, and a
# rounded-border + padding render byte-pinned by eye against the gate-proven
# Lipgloss border.
run vpunit      main   "$(read_expected vpunit)"
# vpdemo: the viewport under a real pty — j/k line scroll, pgdn page (clamped
# to maxYOffset), a live `resize 40 12`, and the SGR wheel-up packet scrolling
# by the 3-line delta (Click mode still decodes wheel); q quits.
pty vpdemo      main   vpdemo.script

# --- S5 (M-WIDGETS): the textarea — the multi-line editor ---
# taunit: byte-exact PLAIN renders at a fixed size (reverse-video cursor cell
# on the current char + at EOL, prompt prefix on every row, focus gate,
# vertical reposition when the cursor is below the fold), cursor/content
# states driven through `update` key folds (left/right/home/end/up/down/pgup/
# pgdn, backspace incl. the col-0 merge-line-above, delete incl. EOL
# merge-below, enter split, ctrl+k/ctrl+u/ctrl+w), and `==` flags pinning the
# grid arithmetic (value join, row/col, word-delete byte offsets).
run taunit      main   "$(read_expected taunit)"
# textareademo: type/arrows/home/end/delete/enter-split/backspace-at-col0/
# up/down under a real pty (unique header needles); q quits.
pty textareademo main  textareademo.script

# --- S6 (M-WIDGETS): the list — the filterable, paginated list ---
# listunit: the page-flip cursor logic (R6) — 12 items at 40x19 -> perPage 4
# (availHeight = 19 - 7 chrome rows = 12, /3), 3 pages, crossing the page
# boundary in BOTH directions (j 0->3->page2, k back to the previous page's
# last index); goToEnd/goToStart; the filter lifecycle ("/"->Filtering,
# "es"->6 visible, esc->Unfiltered, "/"+"es"+enter->FilterApplied, "zzz"->
# Nothing-matched); byte-exact views (title/status/body/dots/help joined
# vertically, selected item's left border, dimmed filtering, the "“es” N
# items • M filtered" applied status).
run listunit    main   "$(read_expected listunit)"
# listdemo: the list under a real pty — j crosses the page boundary (3->4),
# "/"+"es" filters 12->6, esc clears, "/"+"es"+enter applies; q quits.
pty listdemo    main   listdemo.script

# --- S7 (EXAMPLE): the full-stack todos app (Tea v2 + ListBox + TextInput +
# Help + Lipgloss + TaskReadFile/WriteFile persistence) under a real pty ---
# todos.elm re-exports examples/todos/TodoApp.main; the ptycwd row runs it
# from a temp CWD so todos.txt persistence stays isolated between runs.
pty_app todos  main   todos.script  todos/TodoApp.elm

# --- S7 (M-WIDGETS): the table — the data table ---
# tableunit: the R7 scroll parity (10 rows / 5-high viewport / j / G / g):
# j walks the cursor to the bottom visible row then scrolls, G jumps to the
# last row (top = rows-height), g back to the top; the byte-exact views pin
# the bold header cells (title truncated with a "…" tail INSIDE the width
# budget), the right-padded cells, the selected row wrapped in bold + fg 212
# (ColorAnsi256), and the viewport padding each row to the table width.
run tableunit    main   "$(read_expected tableunit)"
# tabledemo: the table under a real pty — j/k move the selection (the cursor
# crossing the 5-high fold scrolls the viewport), G jumps to the bottom; q
# quits.
pty tabledemo    main   tabledemo.script

# --- S9 (M-WIDGETS): timer + stopwatch — Cmd-producing widgets #2/#3 ---
# timerunit: the Go update semantics over model-only folds — the 5s/1s
# countdown crossing zero on the 5th accepted tick (6th REJECTED: Running()
# false), the vestigial tag guard, ID routing with the 0 wildcard, the
# StartStop flip vs the tick gate, the timed-out state (a StartStop cannot
# resurrect it), and the byte-exact Go duration formats ("1m30s"/"1h0m0s"
# zero components, ".5s"/".05s"/".005s" fractions, "750ms", "0s", the
# negative "-500ms").
run timerunit     main   "$(read_expected timerunit)"
# stopwatchunit: New leaves the watch STOPPED at "0s", accepted ticks ADD
# one interval and BUMP the tag, the tag guard drops a stale tick, the tag-0
# hole is Go parity (0 > 0 is false), Reset zeroes WITHOUT touching tag/run,
# and the restart heal (first same-tag tick accepted, duplicate rejected).
run stopwatchunit main   "$(read_expected stopwatchunit)"
# timerdemo: the tick re-arm under a real pty — s stop/start flips the
# header deterministically, the countdown resumes from the frozen value, the
# crossing tick fires the Timedout notice ("over 0s"); q quits with the
# timeout chain drained.
pty timerdemo     main   timerdemo.script
# stopwatchdemo: the StartStop-before-Tick ordering proof under a real pty —
# after s(start), "run 1s" can only appear if the StartStop delivery landed
# before the chained sleeping Tick (an overtaken tick freezes the watch
# below 1s forever); s stop, r reset-while-stopped ("stop 0s"); q quits.
pty stopwatchdemo main   stopwatchdemo.script

# --- S10 (M-WIDGETS): tree — the PURE widget (model-only update) ---
# treeunit: the byte-exact UNSTYLED render (plainStyles + blanked help
# styles) equal to the ansi-stripped default_tree.golden — the "→ ▼ " cursor
# + root-indicator line, the "│  "/"   " indenter segments, the "├──"/
# "└──" enumerators glued to the values, per-parent "▼ " indicators, the
# 70-column viewport padding, the blank help padding row — plus the
# close/open/toggle folds, the preorder y-offset walk over VISIBLE nodes,
# goToBottom/goToTop, the 8-high-viewport scrolloff reveal (off = min 5,
# 8//2 = 4) with the pageUp reveal-above pin, the cursor column riding the
# selected row, the key surface (enter/l/h/j/G/g through `update`, an
# unmatched key a no-op), the help flip (showAll + Go's no-SetSize quirk
# keeping the 11-row viewport: 17 total rows), the dark styleset painting
# SGR bytes (bold+212 cursor, #5C5C5C indicator, #EE6FF8+bold selected
# root), and SetNodes clamping a kept selection into the new tree's size.
# The wide rows pin the over-wide root value at width 70: the tree block
# wraps at the FULL width (one row, the viewport cutting the cursor-joined
# row back to width), not at width - cursor - frame.
run treeunit main   "$(read_expected treeunit)"
# treedemo: the tree under a real pty — the scalar-model rebuild (the full
# Tree.Model exceeds the pty buffer) restores selection + open flags exactly;
# j walks the preorder over visible nodes (a closed parent's children are
# skipped), h/l close/open, enter toggles the root, g/G jump, ? flips
# short->full help and back; q quits.
pty treedemo     main   treedemo.script

# --- S11 (M-WIDGETS): filepicker — the RUNTIME-DEPENDENT widget (host listDir
# + stat through the module's own readDirCmd) ---
# filepickerunit: the full host round trip over input/dirlist (committed
# stable files) — the sorted listing (dirs first then name, hidden .keep
# filtered to n=0 in gamma/), the scripted j j enter k k enter walk (enter
# records the file path — enter matches open AND select — then descends into
# gamma pushing the stack) and the h back-out (pop restoration + the sticky
# path), GotDir id routing, the window folds over a 5-entry/2-high picker
# (down/up scroll shifts + clamps, g/G, pageDown/pageUp clamps), resize's
# AutoHeight rows-5 recompute + setHeight, did-/canSelect (kind gate,
# dirAllowed, AllowedTypes suffixes, the disabled-type didSelect), the pure
# helpers (permOf modes, joinPath/parentDir shapes, sortEntries), and the
# byte-exact plainStyles views (cursor column, %7s sizes, disabled row, the
# padded "Bummer" block) + the default styleset's fg-247 disabled-row SGR.
run filepickerunit main   "$(read_expected filepickerunit)"
# filepickerdemo: the picker under a real pty — the "#<n> dir= n= sel= pick="
# header gives every frame a unique needle: j/j walk, G/k clamps at both
# ends, enter on a file records the sticky pick, l descends into gamma (the
# stale-listing frame then the GotDir n=0 "Bummer"), h pops the stack and
# re-lists the parent (restored sel); q quits.
pty filepickerdemo main   filepickerdemo.script

# --- S7: typechecker extensible-record surface (scoped labels) ---
run rowpoly     main   "$(read_expected rowpoly)"
run extrec      main   "$(read_expected extrec)"
run insrec      main   "$(read_expected insrec)"
run remrec      main   "$(read_expected remrec)"
run scopedup    main   "$(read_expected scopedup)"
run recalias    main   "$(read_expected recalias)"
run appendres   main   "$(read_expected appendres)"
compile_error tyerr_update_missing_field "does not have field"
compile_error tyerr_ambiguous_append      "ambiguous"
compile_error tyerr_numstr                "unify number with String"
compile_error tyerr_arity                 "apply non-function"
compile_error tyerr_remove_absent         "does not have field"

# ============================ PHASE 2: batch compile ============================
# Build the manifest {groups:[{sources:[...],output:"..."}]} and run.js ONCE.
: > "$OUT/groups.jsonl"
for ((i=0;i<ngroup;i++)); do
  read -r -a srcs <<< "${GSRC[$i]}"
  jq -n --arg out "${GOUT[$i]}" \
        --argjson srcs "$(printf '%s\n' "${srcs[@]}" | jq -R . | jq -s .)" \
        '{sources: $srcs, output: $out}' >> "$OUT/groups.jsonl"
done
jq -s '{groups: .}' "$OUT/groups.jsonl" > "$OUT/manifest.json"

# ELM_GATE_MANIFEST_ONLY=1: stop after building the manifest (debugging / the
# byte-identical bundle diff) — print its path and leave $OUT in place.
if [ "${ELM_GATE_MANIFEST_ONLY:-0}" = "1" ]; then
  echo "$OUT/manifest.json"
  exit 0
fi

node "$CDIR/run.js" --batch "$OUT/manifest.json" 2>/dev/null
if [ $? -ne 0 ]; then
  echo "FAIL: node run.js --batch failed" >&2
  rm -rf "$OUT"
  exit 1
fi

# ============================ PHASE 3: checks ============================
dispatch() {
  local kind="$1" i="$2"
  local name fn exp args stdin fixfile outfile mod qname got out
  name="${CNAME[$i]}"; fn="${CFN[$i]}"; exp="${CEXP[$i]}"
  args="${CARG[$i]}"; stdin="${CSTDIN[$i]}"; fixfile="${CFIX[$i]}"; outfile="${COUT[$i]}"
  case "$kind" in
    cmp)
      if cmp -s "$FIX/out/hello.out" "$FIX/expected/hello.out.txt"; then
        echo "PASS iofile out-file cmp"; pass=$((pass+1))
      else
        echo "FAIL iofile out-file cmp: out/hello.out != expected/hello.out.txt"; fail=$((fail+1))
      fi
      ;;
    err)
      out=$(cat "$outfile")
      case "$out" in
        err*"$exp"*) echo "PASS $name: $out"; pass=$((pass+1));;
        *) echo "FAIL $name: expected err containing [$exp], got [$out]"; fail=$((fail+1));;
      esac
      ;;
    run2)
      if head -c 4 "$outfile" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$outfile")"; fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      got=$("$ELMVM" "$outfile" "$mod.$fn" 2>&1)
      if [ "$got" = "$exp" ]; then
        echo "PASS $name ($mod.$fn multi) -> $got"; pass=$((pass+1))
      else
        echo "FAIL $name ($mod.$fn multi): exp[$exp] got[$got]"; fail=$((fail+1))
      fi
      ;;
    pty)
      if head -c 4 "$outfile" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$outfile")"; fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      got=$("$PTYTEST" "$ELMVM" "$outfile" "$qname" "$FIX/scripts/$stdin" 2>&1)
      if [ $? -eq 0 ] && printf '%s' "$got" | grep -q '^PASS'; then
        echo "PASS $name ($qname pty)"; pass=$((pass+1))
      else
        echo "FAIL $name ($qname pty): $got"; fail=$((fail+1))
      fi
      ;;
    ptycwd)
      if head -c 4 "$outfile" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$outfile")"; fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      tmpd="$(mktemp -d)"
      # The example app reads/writes relative paths (todos.txt) from the CWD;
      # run ptytest from a throwaway dir so persistence is isolated.  All the
      # command paths below are absolute, so the cd does not break them.
      got=$(cd "$tmpd" && "$PTYTEST" "$ELMVM" "$outfile" "$qname" "$FIX/scripts/$stdin" 2>&1)
      rc=$?
      rm -rf "$tmpd"
      if [ "$rc" -eq 0 ] && printf '%s' "$got" | grep -q '^PASS'; then
        echo "PASS $name ($qname pty, temp cwd)"; pass=$((pass+1))
      else
        echo "FAIL $name ($qname pty, temp cwd): $got"; fail=$((fail+1))
      fi
      ;;
    io)
      if head -c 4 "$outfile" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$outfile")"; fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      got=$("$ELMVM" "$outfile" "$qname" < "$FIX/input/$stdin" 2>&1)
      if [ "$got" = "$exp" ]; then
        echo "PASS $name ($qname < input/$stdin) -> $(echo "$got" | tail -1)"; pass=$((pass+1))
      else
        echo "FAIL $name ($qname < input/$stdin): exp[$exp] got[$got]"; fail=$((fail+1))
      fi
      ;;
    run)
      if head -c 4 "$outfile" | grep -q '^err '; then
        echo "FAIL $name: compile error: $(cat "$outfile")"; fail=$((fail+1)); return
      fi
      mod=$(module_name "$fixfile")
      qname="$mod.$fn"
      got=$("$ELMVM" "$outfile" "$qname" $args 2>&1)
      if [ "$got" != "unknown global: $qname" ] && [ "$got" != "unknown name: $qname" ]; then
        if [ "$got" = "$exp" ]; then
          echo "PASS $name ($qname $args) -> $got"; pass=$((pass+1))
        else
          echo "FAIL $name ($qname $args): exp[$exp] got[$got]"; fail=$((fail+1))
        fi
        return
      fi
      # fallback to the bare fn name (legacy single-module bundles)
      got=$("$ELMVM" "$outfile" "$fn" $args 2>&1)
      if [ "$got" = "$exp" ]; then
        echo "PASS $name ($fn $args) -> $got"; pass=$((pass+1))
      else
        echo "FAIL $name ($fn $args): exp[$exp] got[$got]"; fail=$((fail+1))
      fi
      ;;
  esac
}

for ((i=0;i<ncheck;i++)); do
  dispatch "${CKIND[$i]}" "$i"
done

rm -rf "$OUT"
echo "=============================="
echo "PASS=$pass FAIL=$fail"
exit $((fail>0?1:0))
