# AOT-to-Zig — design and results

Compiles a small Elm program to Zig, links the existing zinc-vm GC+VM as a
library, and runs it **correctly** and **measurably faster** than the
interpreted VM — while handling the two design cruxes (tail calls, GC rooting).

Pipeline: `Elm -> csexp -> parseBundle (real parser) -> aotdump (emit Zig) ->
zig build (link gc+vm+aotrt) -> aotbench (native exe)`.

```
elm-compiler/run.js          tools/aot/dump.zig         tools/aot/runtime.zig
  .elm ──► .csexp ──► parseBundle ──► emit gen.zig ──► aotbench-<fixture>
                                  (real parser, zero drift)   (native exe)
```

Correctness never depends on AOT coverage: every construct the emitter cannot
handle statically keeps the interpreter's behaviour, and the interpreter stays
the source of truth (`tools/aot/spike.sh` gate #1).

## Files

- `tools/aot/dump.zig` — `aotdump`: links gc+vm, runs the REAL
  `parser.parseBundle`, walks the entry defun + its transitive closure over
  every `g`/`Q`/`R`-referenced global name, emits one Zig fn per defun body
  (a labeled switch over comptime pc arms, grouped into basic blocks), plus the
  consts table, globals cache, registry fill, and `aotInit`.
- `tools/aot/runtime.zig` — `aotrt`: `Ret`/`AotFn`, the code-array→native-fn
  registry, `buildEnv`/`tailSelf`, `materializeEnv`, `callKnown`/`tailKnown`/
  `applyGeneric`/`applyHost`, and the bounce loop + native-depth guard.
- `tools/aot/main.zig` — `aotbench`: elmvm-shaped driver
  (`<bundle> <fn> [--secs=N] [--heap=MB] [args]`), mirrors the vmbench report.
  Note it does NOT link `effectloop.zig` — only `tools/aot/run.zig` (used by
  `aot-build.sh` / `addAotApp`) does.
- `tools/aot/run.zig` — the generic driver baked into self-contained binaries
  (`aot-build.sh`): parses the embedded bundle, runs `aotInit`, installs the
  effect-loop hook, trampolines the entry.
- `tools/aot/aot-build.sh` — `elm make` for native binaries: one command from
  an `.elm` app to a self-contained executable (`--group` for multi-module
  entries, `-O` for the optimize mode, default ReleaseFast).
- `tools/aot/spike.sh` — the verification runner (diffs + ulimit + Debug
  pressure + speed table). **It leaves Debug binaries installed** (its last
  step builds `-Doptimize=Debug`), so rebuild ReleaseFast afterwards before
  taking any timing.
- `tools/elmc.sh` — the M15 self-hosted compiler CLI (builds `zig-out/bin/elmc`
  from the selfhost group via `aot-build.sh --group`; defaults to Debug).

## Frame tiers

A body is emitted in one of four shapes, chosen statically; anything the
emitter cannot prove keeps the interpreter's shape or falls back to the
interpreter (`.cur` closures, `nat_depth >= nat_depth_max`, unknown prims,
statically unsizable stacks).

1. **Elided (unrooted prologue)** — a transitively NON-ALLOCATING body (no prim
   that can reach `gc_alloc`) takes NO GC roots at all, because no collection
   can start inside its dynamic extent. Its known-target calls pass a C-stack
   `senv` instead of building an env array. One `allocStable` assertion
   re-proves this per entry/exit in Debug; the assertion is relaxed iff a
   depth-guard fallback fired anywhere in the dynamic extent (that path routes
   through `vmExecEnv`, which does allocate).
2. **Native frame (`p[]`)** — a rooted body whose core (the instrs after the
   leading grab prefix, which is the arity convention) has no let/endlet/grab
   and no self-tail never mutates `env`, so params are materialized once into a
   rooted `p[arity]` and `.access` to a param becomes a constant index `p[i]`.
3. **Lex frame (`lex[]`)** — a rooted body that DOES have let/endlet/grab in
   its core gets a C-stack `lex: [LEX_MAX]Value` rooted once. `.let`/`.grab`
   append and `.endlet` pops, exactly like `envPush`/`envPop`, but with no
   `allocArray` growth and no per-store barrier. `.access n` becomes
   `lex[lexlen-1-n]` (relative to the TOP of the live env; `lexlen` is the
   runtime live height). Self-tail bodies are eligible too: `lex[]` IS the env,
   so the tail rebuilds it in place (`lexlen=arity; copy argbuf->lex; pc=0`),
   the direct analog of `rt.tailSelf` minus GC array reuse.
4. **Env-array frame** — everything else: the interpreter-shaped growing GC
   env array via `interp.envPush`/`envPop`.

Eligibility is **deny-by-default**. A static delta simulation must prove a
UNIQUE live-lets height at every `.access` site; ambiguous joins, unbounded
relaxation, `endlet` below the base, a jump into the grab prefix, a `.cur`
capture (unknown runtime base), or `arity + max_d > LEX_MAX` all keep the
env-array path. Lex frames assert `lexlen == env_len_in + <proven delta>` in
Debug (compiled out in ReleaseFast) — a sim that proved a *wrong* height would
produce silent wrong VALUES, not a crash, so the assert is the backstop.

`env` is reconstructed as a real GC array at exactly ONE point:
`rt.materializeEnv`, called at `.cur` (where `valLambda` captures it). The
depth-guard fallback needs no reconstruction — every fallback site passes the
*callee's* env, never a lex body's own.

## The two cruxes (how they're handled)

**Tail calls** — constant native stack across arbitrary tail chains:
1. `R <self>`: rebuild the env IN PLACE (the M11 reuse — reuse the array if
   `env_cap` fits, nil-clear the dead tail, barrier it), or for a lex frame
   rebuild `lex[]` in place, then `pc = 0; continue :sw 0` in the SAME frame.
   No per-iteration alloc, no native recursion.
2. `R`/`t` to a *different* known AOT defun: build the env and return
   `.{.tail}`, which the caller bounces (`while (r == .tail) r = r.tail.fn(...)`).
3. Unknown / first-class closures: `rt.applyGeneric` → registry hit ? native
   bounce : `interp.vmExecEnv(...)` (which handles its own appterm tails
   internally).

**GC rooting** — every rooted-frame prologue pushes `acc` (ROOT_VALUE), the
fixed value-stack base (ROOT_VALUE_ARRAY with a live `&stack.len` count), the
one apply-site `argbuf` (ROOT_VALUE_ARRAY, count set per site), and `env`
(ROOT_PTR) BEFORE any alloc, with one `defer g.rootPopTo(entry_wm)` covering
every exit (including error unwinds). No derived pointer is cached across an
alloc. Fixed-stack size (`MAXD`) is a conservative emit-time stack-depth
simulation (prim arity + tail-call reset) + 8 slack; a body whose slacked depth
exceeds `STK_MAX` (256) is left interpreted rather than clamped (an undersized
`stk` is a silent OOB write in ReleaseFast).

**Known-target calls** (S1): a defun/global closure has `env_len == 0`
(`parser.zig`), so `env == args` exactly — the caller's already-rooted `argbuf`
is passed straight through as the callee env, with no `buildEnv` allocation.
`tailKnown` and the tail / captured-env paths keep `buildEnv`: a `.tail{env}`
outlives the frame (the caller bounces it after return), so a C-stack `argbuf`
would dangle.

**Depth guard** — Zig has no TCO and AOT non-tail calls are raw native
recursion, so a non-tail call made at `nat_depth >= nat_depth_max`
(`AOT_NAT_DEPTH`, default 256) runs its callee through `interp.vmExecEnv`
instead: a flat loop with a pooled `CallFrame` array that never grows the C
stack. Shallow calls stay native; only the deep tail of a recursion degrades.

**ReleaseFast compilation** — the emitted `stk`/`argbuf`/`lex` frame arrays are
plain C-stack objects, but a struct literal that *repeats an array constant*
into an escaping alloca defeats SROA and hangs LLVM's optimizer (measured:
>240s vs 3s Debug, on a single 194-line generated fn — see `src/effectloop.zig`
`runProgramWith`, which had to be built via `undefined` + `@memset`). Sizing
the arrays with `@memset`/`undefined` instead of `**`-repeated literals keeps
ReleaseFast builds sane.

## Results

Baseline: ReleaseFast, `--secs=3`, this host. `vmbench` = the interpreter on
the identical bundle. `ns/instr` is from the tools' own counters.

| fixture | vm ns/instr | aot ns/instr | speedup |
|---|---|---|---|
| fib 30 | 16.77 | **4.99** | **3.3×** |
| countdown 100000 | 15.63 | **36.90** | **~48,000×** |
| biglist | 19.81 | **5.56** | **3.5×** |

Coverage per fixture (`aotdump` summary line):

| fixture | defuns | elided | native-frame | lex-frame |
|---|---|---|---|---|
| fib | 1 | 1 | 0 | 0 |
| countdown | 1 | 0 | 0 | 0 |
| biglist | 17 | 0 | 11 | 7 |
| todos (app) | 424 | 49 | 246 | 146 |

`biglist` is 18/19 bodies native (only `BigList.range` stays env-array: a
self-tail with no let/endlet/grab in core, so out of scope for lex).

## What the numbers mean (the honest part)

- **countdown** is the self-tail crux: one frame, no alloc, and — because
  `countdown n` returns the constant `0` — LLVM additionally proves the loop
  dead and folds the whole call to `return 0`. The ~48,000× therefore
  overstates the raw trampoline (the constant-fold subsumes the loop); the
  *constant native stack* property is what's load-bearing and is proven by the
  ulimit run + the emitted `pc=0; continue :sw 0`.
- **fib 30** is the elided/alloc-free case: every call takes the C-stack `senv`
  path with no env allocation and no rooting (45.7M elided calls, of which
  45.7M take the stack-env route, on a short `--secs=2` run). 3.3×.
- **biglist** is the cons-allocating + first-class-dispatch case. It was 1.16×
  at the spike and 1.9× after S1/S2; the `lex[]` frames took it to 3.5× by
  removing the GC env-array growth from the hot list loops
  (`foldl`/`lengthGo`/`listMapGo`/`listRevGo`/`listFilterGo` — all self-tail
  recursive). The residual is cons churn, which the AOT and interpreter share.
- **fib and biglist are NOT regressions of a stale doc**: an earlier revision of
  this file reported fib at 0.91× and biglist at 1.16×. Both were superseded by
  the per-call `buildEnv` removal (S1) and `lex[]` (S2.5).

**A dead end worth recording**: deleting the Phase-2 rooting-elision and making
the rooted prologue universal cost fib **57%** (7.96 vs 5.07 ns/instr) — the
unrooted elided prologue is fib's 45.7M-frame hot path. The NON_ALLOCATING
classification is therefore load-bearing; it is kept to choose the *prologue
shape*, not to gate the senv call (which is unconditional).

## Limitations (documented)

- Deep **non-tail** recursion degrades to the interpreter past `AOT_NAT_DEPTH`
  rather than overflowing the native stack. The cap is a knob, not a fix: a
  heap `CallFrame` array for AOT frames is the real answer.
- The nat-depth guard trades speed for stack safety at the boundary; measure
  `depth_fallbacks` when tuning it.
- `error.Halt` from a prim is contained per-defun (`.done = acc`) rather than
  aborting the whole run — unobservable for the valid fixtures.
- `LEX_MAX`/`STK_MAX` (64/256) are static caps: a body over either keeps the
  env-array path. Raising them trades frame size for coverage.
- No pc-free control flow: bodies are still a labeled switch over comptime pc
  arms (grouped into basic blocks). Converting to structured Zig control flow
  is a relooper-scale rewrite (no `goto` in Zig) and is deliberately not done.
- `zig build aot` compiles each fixture with `node run.js` inside the build;
  the build-graph prints `failed command: ...` lines even on success (a known
  zig quirk documented in `aot-build.sh`) — check the exit status, not stderr.
- ReleaseFast/ReleaseSafe builds of the generated code are sensitive to
  constant-array escapes in frame construction (see the `effectloop` note
  above). Debug is the fast sanity mode; ReleaseFast is ~94s for the 3 fixtures.

## Reproduce

```
zig build aotdump elmvm vmbench    # ReleaseFast tools (default)
zig build aot                      # the spike exes (ReleaseFast by default)
tools/aot/spike.sh                 # diffs + ulimit + Debug pressure + speed table
tests/elm-fixtures/run-elm-gate.sh # the fixture gate (PASS=122)
zig build vm-test                  # the VM test set (106 tests)
```

Single fixture, end to end:

```
zig build aot-build -Dapp=tests/elm-fixtures/biglist.elm -Dentry=BigList.main -Dout=biglist
./zig-out/bin/biglist
```
