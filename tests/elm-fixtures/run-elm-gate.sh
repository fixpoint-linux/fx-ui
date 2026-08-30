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
compile_error dup         "duplicate top-level definition in Dup: f"

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
