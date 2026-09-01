# AOT-to-Zig spike — results

Proof that a small Elm program compiles to Zig, links the existing zinc-vm
GC+VM as a library, and runs **correctly** and **measurably faster** than the
interpreted VM — while handling the two design cruxes (tail calls, GC rooting).

Pipeline: `Elm -> csexp -> parseBundle (real parser) -> aotdump (emit Zig) ->
zig build (link gc+vm+aotrt) -> aotbench (native exe)`.

```
elm-compiler/run.js          tools/aot/dump.zig         tools/aot/runtime.zig
  .elm ──► .csexp ──► parseBundle ──► emit gen.zig ──► aotbench-<fixture>
                                  (real parser, zero drift)   (native exe)
```

## Files

- `tools/aot/dump.zig` — `aotdump`: links gc+vm, runs the REAL
  `parser.parseBundle`, walks the entry defun + its transitive closure over
  every `g`/`Q`/`R`-referenced global name, emits one Zig fn per defun body
  (a labeled-switch reification), plus the consts table, globals cache,
  registry fill, and `aotInit`.
- `tools/aot/runtime.zig` — `aotrt`: `Ret`/`AotFn`, the code-array→native-fn
  registry, `buildEnv`/`tailSelf` (verbatim interp apply/appterm N==A env
  builds), `callKnown`/`tailKnown`/`applyGeneric`, and the bounce loop.
- `tools/aot/main.zig` — `aotbench`: elmvm-shaped driver (`<bundle> <fn>
  [--secs=N] [--heap=MB] [args]`), mirrors the vmbench report.
- `tools/aot/spike.sh` — the verification runner (diffs + ulimit + pressure +
  speed table).
- `build.zig` — `aotdump` exe + `addAotSpike(fib/countdown/biglist)` + the
  `aot` top step (SEPARATE from `gate`/`test`; the interpreter stays the
  source of truth).
- `vendor/zinc-vm/src/vm/interp.zig` — `buildPartialClosure` + `peelOverArgs`
  made `pub` (2 keywords, zero behavior change — needed by `aotApplyGeneric`).

## The two cruxes (how they're handled)

**Tail calls** — 3 tiers, constant native stack across arbitrary tail chains:
1. `R <self>` (countdown, `BigList.range`): `rt.tailSelf` rebuilds the env
   IN PLACE (the M11 reuse — reuse the array if `env_cap` fits, nil-clear the
   dead tail, barrier it), then `pc = 0; continue :sw 0` in the SAME frame.
   No per-iteration alloc, no native recursion.
2. `R`/`t` to a *different* known AOT defun: `rt.tailKnown` builds the env and
   returns `.{.tail}`, which the caller bounces
   (`while (r == .tail) r = r.tail.fn(...)`).
3. Unknown / first-class closures: `rt.applyGeneric` → registry hit ? native
   bounce : `interp.vmExecEnv(...)` (which handles its own appterm tails
   internally).

**GC rooting** — the generated prologue pushes `acc` (ROOT_VALUE), the fixed
value-stack base (ROOT_VALUE_ARRAY with a live `&stack.len` count) and `env`
(ROOT_PTR) BEFORE any alloc, with one `defer g.rootPopTo(entry_wm)` covering
every exit (including error unwinds).  Every argbuf is `rootPushValueArray`'d
before the first alloc at an apply/appterm site and popped right after.
`buildEnv`/`tailSelf` copy the interpreter's barrier dance verbatim; no derived
pointer is cached across an alloc.  Fixed-stack size (`MAXD`) is a conservative
emit-time stack-depth simulation (prim arity + tail-call reset) + 8 slack.

## Results (baseline @HEAD c8750f2 / zinc-vm 10fa875 + the 2 pub keywords)

### Correctness — byte-identical stdout on every run

| fixture | fn | result | elmvm | aotbench |
|---|---|---|---|---|
| fib 30 | `Fib.fib` | `832040` | ✓ | ✓ |
| countdown 100000 | `Countdown.countdown` | `0` | ✓ | ✓ |
| biglist | `BigList.main` | `2003000` | ✓ | ✓ |

### Tail calls — constant native stack

`countdown 100000` completes under `ulimit -s 1024` (1 MB stack) with the
correct `0`.  The self-tail arm is `rt.tailSelf(...); pc = 0; continue :sw 0`
in one frame — no native recursion, no per-iteration alloc
(`env_reuse` = 100000 hits, `scavenges` = 0).

### GC rooting — pressure-clean Debug

`biglist --heap=16` (the GC minimum) in **Debug** (`verify_collects` re-checks
the precise-root contract after every collection, root-balance asserts live):
correct `2003000`, 50 scavenges, 0 full collects, 2.95 M env-reuse hits — no
root imbalance, no precise-root violation.

### Speed (ReleaseFast, `--secs=3`, wall ns/iter)

| fixture | vmbench ns/iter | aotbench ns/iter | speedup | ns/instr (vm→aot) |
|---|---|---|---|---|
| countdown 100000 | 9.25 ms | 534 ns | **~17,300×** | 13.2 → 88.9 |
| biglist | 3.65 ms | 3.14 ms | **1.16×** | 17.1 → 16.1 |
| fib 30 | 342 ms | 375 ms | 0.91× | 13.4 → 14.7 |

## What the numbers mean (the honest part)

- **countdown** is the self-tail crux: one frame, no alloc, and — because
  `countdown n` returns the constant `0` — LLVM additionally proves the loop
  dead and folds the whole call to `return 0`.  The 17,300× therefore overstates
  the raw trampoline (the constant-fold subsumes the loop); the *constant
  native stack* property is what's load-bearing and is proven by the ulimit
  run + the emitted `pc=0; continue :sw 0`.
- **biglist** is the cons-allocating + registry-dispatch case (foldl/length/
  Just/maybeWithDefault, `+.curried`, cur closures): 1.16× — the wins (native
  dispatch, 11.5 M env-reuse hits from the self-tail `BigList.range`) are
  mostly hidden behind the cons churn, which the AOT and interpreter share.
- **fib 30** is *allocation-bound, not dispatch-bound*: every non-tail
  `Fib.fib` call allocates a fresh 1-element env (`buildEnv`), exactly like the
  interpreter's apply arm, and the generated fn additionally pays the prologue
  rooting + the `callKnown`/`bounce` call layers.  Net ~0.9×.  The labeled
  switch itself is ~1.2 ns/block (artifact-1), but fib's per-call GC+rooting
  cost dominates and matches the interpreter's.

**Conclusion**: the spike proves the full AOT pipeline, both cruxes (tail
calls / GC rooting), and byte-identical correctness.  Speed is decisive where
the recursion is *tail* (countdown) and neutral where it is *alloc-bound*
(non-tail fib, cons-churn biglist) — the same allocation the interpreter pays.
Beating the interpreter on alloc-bound code needs a stack-allocated env for
known direct calls (closure-env-empty, non-growing env), which is a follow-up,
not part of this spike.

## Limitations (documented)

- Deep **non-tail** recursion overflows the native stack where the interpreter
  survives (the plan's accepted risk): fib depth 30 is trivial, but the AOT
  has no CallFrame array.
- `error.Halt` from a prim is contained per-defun (`.done = acc`) rather than
  aborting the whole run — unobservable for the valid fixtures.
- The fixed value-stack size is a conservative estimate + 8 slack; the Debug
  pressure run (biglist) exercises it without overflow.
- `zig build aot` compiles each fixture with `node run.js` inside the build;
  the first run after a vendor change recompiles the VM (slow), later runs are
  cached.

## Reproduce

```
zig build aotdump elmvm vmbench    # ReleaseFast tools
zig build aot                      # the 3 spike exes
tools/aot/spike.sh                 # diffs + ulimit + Debug pressure + speed table
```
