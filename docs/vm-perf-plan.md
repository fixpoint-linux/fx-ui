# zinc-vm performance plan (interactive TUI rendering)

Audit by strategist (DeepSeek V4 Pro) + independent reviewer, authorized VM
unfreeze. Goal: make interactive Lipgloss-heavy TUI rendering playable.
Baseline gate: PASS=106 FAIL=0, TestMain 90/90, HEAD 701e68b.

## The problem (measured, valid benchmarks)

The interpreted VM ran ~1M simple ops/sec in **Debug**, and a full
Lipgloss/ListBox frame is ~500K+ VM ops, so per-key full-frame re-render took
~1s (ListBox.view of 10 items) / ~112ms (Lipgloss.render of an 8-line box).

**The ~10x is NOT inherent.** It is (a) Debug build mode and (b) per-call
allocation churn in the interpreter. ReleaseFast alone is ~6-25x; the
allocation fix is another ~5.7x on top.

## Where VM time goes (root cause)

1. **PER-CALL ALLOCATION CHURN (dominant after build mode).**
   `interp.zig:85 STACK_INIT_CAP=64` makes `vaInit` (interp.zig:90-94)
   allocate a 64-Value (2560B) array per function-call frame. It exceeds the
   512B single-page nursery limit, so EVERY call allocates ~2.5KB in
   OLD-GEN + @memset 2560B. ~15K calls per Lipgloss.render = ~37MB old-gen
   garbage/render → full semi-space collects fire ~20x per render (measured:
   810 full + 101 scavenges over 41 renders). Fix: `STACK_INIT_CAP 64 -> 12`
   (vaPush already grows by doubling) or a pooled value-stack.
2. **BUILD MODE.** `build.zig` uses `standardOptimizeOption` (defaults to
   Debug). ReleaseFast is ~5.9x (strategist lg1 104.7->17.8ns/instr) to ~25x
   (reviewer, this host).
3. **Curried-call multiplier.** Elm emits curried closures; N>A over-
   application runs `peelOverArgs` (interp.zig:444-514) with a NESTED
   vmExecEnv per arity level (fresh/pooled frame stack + init_env copy +
   vaInit + 8 root pushes) — a 3-arg curried call can cost 2 nested VM
   entries.
4. **GC frequency.** nursery 2MB (heap.zig:48), scavenge at 87.5% full; with
   ~3KB/call churn that is a scavenge every ~600 calls.
5. **Write-barrier per push.** vaPush/envPush do an inOldgen check +
   valueReferencesNursery on every push (cheap but on the hot path).
6. NOT the bottleneck: dispatch (dense-enum jump table, ~9.7ns/instr floor),
   `cn` string append (already two-pass single-alloc linear), Value=40B/
   Instr=64B (fat but no cache-miss evidence), prim/defun hashing.

## Prioritized plan

### P0 — DO FIRST
- **P0b: ship ReleaseFast as the default build.** build.zig already plumbs
  `-Doptimize` through. Production TUI exe + gate must default to
  ReleaseFast/ReleaseSafe. Proven ~6-25x on the exact benchmarks, no code
  change. Entry-name gotcha: `elmvm <bundle> <Mod>.main` (bare `main` throws
  "global not found" and can masquerade as a broken binary).
- **P0a: STACK_INIT_CAP 64 -> 12** (interp.zig:85, one line). Measured
  ReleaseFast: lg1 101->17.8ns/instr (5.7x; Lipgloss.render 49.8ms->8.7ms),
  bb4 136->22.1ns/instr (6.2x; ListBox.view 268ms->43.6ms), full collects
  810->11. **BLOCKER: crashes vm_test.zig:3211 "M11 tail-env reuse:
  interactions" (misaligned root in gcMove during a GC storm). MUST be
  root-caused before shipping P0a** — deterministic single-test repro.
- **P0c: NURSERY_BYTES 2MB -> 8MB (heap.zig:48) + host heap_bytes 64MB**
  (elmvm.zig:28-29 + app sites): +8-16% (lg1 17.8->16.5, bb4 22.1->19.0).
  Requires heap_bytes >= ~32MB; M10 pool pins ~6MB.

Aggregate P0 vs the Debug baseline: Lipgloss.render ~112ms -> ~8ms (~14x),
ListBox.view ~1s -> ~37ms.

### P1 — moderate wins (each gate-verifiable)
- Merge stack+env into ONE array per frame, or pool stack arrays
  (interp.zig:90,526) like frameStackAcquire — kills 1 alloc+memset per call.
  Est 10-20% on bb4.
- `valCons` single-object (values.zig:112-130 does 2 allocs + 4 root ops per
  cons): one 2xValue alloc + a new value_pair GcTypeTag scanned as two
  Values. Est 3-8% (cons are 12-18K/render).
- Prim fast dispatch: resolve prim name->index at PARSE time, store in
  Instr.jmp_target (free for .prim; parser.zig:401-411 only sets it for
  jmp/jmpf), table-call with by-name fallback when 0. Kills StaticStringMap
  hash per prim op. Est 5-10%.
- .global slot caching: same jmp_target trick (interp.zig:919-924 +
  defunGetChecked:210), validate by strcmp vs operand symbol. Est 5-10%.
- Skip @memset for GC_TYPE_RAW bodies (heap.zig:627 + nursery 708-709): string
  bytes are overwritten immediately, never scanned. Est 3-5%.

### P2
- `repeat`/`pad` prim (or a builder) to kill the quadratic
  Str.repeat/padLeft/padRight (core-libs/Str.elm:120-150) used by Lipgloss
  borders/padding.
- Hash the dirtyVectorsAdd linear dedup (heap.zig:901-930) — O(n^2) probe
  storm when barriers fire.

### P3 (compiler+interp, bigger)
- Compiler superinstructions (fuse load+prim, global+apply) — cuts the
  490K(lg1)/3.94M(bb4) instr per render, 1.2-2x.
- Shrink Value/Instr (40/64B) — breaks C-ABI parity asserts (types.zig:257-269),
  only after cache profiling. NOT recommended this pass.

## Honest ceiling

After P0+P1, ListBox.view ~20-30ms is still ~2x above a 16ms 60fps budget.
Also recommend app-side: skip re-render when the model is unchanged (the
effectloop differential renderer only diffs OUTPUT lines; it still recomputes
view()).

## Correctness pitfalls a perf pass MUST NOT fall into (all interp.zig)

1. **Appterm no-alloc window** (interp.zig:1042-1048): between `ne = env.?`
   and `env = ne` there must be NO GC allocation (ne is a raw unrooted copy).
2. **Drop-grabs must stay a fresh array** (interp.zig:327-333): `code + nargs`
   interior pointers are FORBIDDEN roots (gcMove reads the header at *(p-1));
   never "optimize" to pointer arithmetic; the jmp-target rebase
   (interp.zig:373-378) is load-bearing.
3. **Tail-env reuse invariant** (interp.zig:1006-1041): reuse is safe ONLY
   because the running env array has exactly one referee (closure Values hold
   valLambda COPIES). Never store the running env array into a closure Value.
   Keep nil-clearing the dead tail and env_cap = true physical capacity.
4. **Grow-copy write barriers** (vaPush 114-122, envPush 191-199, apply env
   build 822-842): copying into an old-gen array requires the
   inOldgen+valueReferencesNursery+dirtyVectorsAdd dance. A pool that skips
   "the grow path" must not skip the barrier when the pooled array is old-gen.
5. **Full-capacity scan contract**: the GC drains VALUE_ARRAYs and
   CALLFRAME_ARRAYs by CAPACITY, not len — vaPop nil-clears (interp.zig:144),
   frameStackRelease clears [0..sp) (interp.zig:550). Any new pooling MUST
   preserve arrays-are-nil-at-rest or it leaks retention.
6. **valString contract** (values.zig:73-80): data must not point into the GC
   heap; use the slot-rooted valStringFrom for memcpy from a GC source.
7. **Root balance**: every vmExecEnv exit funnels through the single defer
   rootPopTo(entry_wm) (interp.zig:571). New early returns are fine, but any
   new rootPush between the argbuf push (770/994) and pops (846/862/1079/1090)
   must be LIFO-balanced on ALL exits including error.ShenError.
8. **`in` re-derivation** (interp.zig:680-683): re-derived from rooted cur_code
   every iteration — never cache it across an allocating call.

## Safety net

`zig build gate` (Debug + ReleaseSafe + ReleaseFast, 101 vm-tests + 106
fixtures) after each item. ReleaseFast compiles out the GC verify hook
(heap.zig:94-97) — run the full gate in RF after changes.

## Minimal file set

vendor/zinc-vm/src/vm/interp.zig, vendor/zinc-vm/src/gc/heap.zig,
vendor/zinc-vm/src/vm/values.zig, vendor/zinc-vm/src/gc/{types,collect}.zig
(only if valCons), vendor/zinc-vm/src/vm/parser.zig, tools/elmvm.zig + app
heap-size sites, build.zig (ReleaseFast default).
