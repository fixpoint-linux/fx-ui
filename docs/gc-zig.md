# Shen GC — Zig port notes (src/gc)

A faithful Zig 0.16 port of the Shen Lisp generational moving GC in
`reference/shen-gc/gc.c` (+ `zincvm.c`'s scan helpers and `gc.md`'s write-barrier
design).  Each function carries a `/// C: gc.c:NNNN` (or `zincvm.c:NNNN`) doc
comment pointing at its C origin — that comment is the reviewability contract
against the reference.

Module layout (see `src/gc.zig`):

| file | ports |
|---|---|
| `src/gc/types.zig` | `zinctypes.h` + `gc.h` type layer, header helpers |
| `src/gc/heap.zig` | `Gc` state, init/deinit, queue, `gcalloc_internal`, `allocatepage`, `grow_heap`, nursery fast path, counters, dirty sets, predicates |
| `src/gc/collect.zig` | `collect`, `collectNursery`, `cheneyDrain`, `scanRoots`, `moveInternal`/`gcMove`, `debugVerifyHeap` |
| `src/gc/scan.zig` | `scanValue`, `evacuate`, `evacInstr`, `valueReferencesNursery` |
| `src/gc/roots.zig` | precise-root shadow stack + registrations |

## What was omitted (~1000 lines of opt-in diagnostics)

The C collector carries a large body of opt-in diagnostic/verification code that
is **not** ported, because it is unportable (C-stack frame walking), redundant
under precise roots, or only useful during C development:

- `check_closures`, `dump_roots`, `stale_scan`, `page_transition`, `watch_alloc`,
  `verify_codechains`, `verify_live` + reverse-search, and the C-stack frame
  walker.  Zig has no portable equivalent of walking the mutator's native stack,
  and with precise shadow-stack roots the collector never *needs* it.
- `SIGALRM`-blocking around collection.  The Zig runtime has no alarm-driven GC
  timeout yet; `std.posix.sigprocmask` will be available when the VM port lands.
- The only diagnostics kept are the two verbose collection banners
  (`[GC FULL #seq trigger live_pages]` / `[GC NURSERY #seq trigger nursery_free]`,
  gated on `Options.verbose`) and **`debugVerifyHeap`** — a test-only
  (caller-invoked) heap verifier used by the test suite instead of the C
  verifiers.  `debugVerifyHeap` checks page invariants and, for a given phase,
  that no live object holds a stale pointer (post-scavenge: no nursery pointer
  from a live object; post-collect: no pointer into dead/released space).
- `exit(1)` on OOM is mapped to `std.debug.panic`; `Gc.init` returns a proper
  Zig error union (`error.InvalidHeapSize`) instead of aborting.

## Mutator contract

The collector is a **moving** (copying, semi-space) GC: any allocation can
trigger a scavenge/full collect that **moves previously-allocated objects** and
rewrites the interior pointer slots of every *rooted* object.  The exact C
hazard ("any GC pointer held only in registers / un-rooted locals across a
`gc_alloc*`/`collect` goes stale") applies verbatim.

Rules to follow in any code that allocates from the `Gc` heap:

1. **Root before the allocating call.**  Any GC pointer that must survive a
   potential collection must have its *slot's address* pushed on the shadow
   stack **before** the allocating call that could trigger the GC.  `evacuate`
   rewrites through the slot during the collection.
2. **`var` locals are rootable; `const` locals are unrootable by construction.**
   Zig's "local variable is never mutated" compile error is an *asset*: a
   pointer local that is only read must be `const`, and a `const` cannot be
   mutated by the GC.  Treat the lint as a rooting-audit signal — a pointer that
   is only read is fine as `const` only if it cannot be invalidated by a
   collection (e.g. it points into old-gen that is itself rooted), otherwise it
   must be a `var` whose address is rooted.
3. **`ROOT_PTR` requires an object head.**  `gc.rootPushPtr(slot)` tells the
   scanner the slot points at the *head* of a GC object.  An interior pointer
   (into the middle of a multi-page object) is a fatal error (the
   `gc.c:1527-1539` defense; proven by the `gc_root_ptr_panic` test exe).

## Root rules (the precise-root API)

- `rootPushValue(&v)` — root a `Value` local (`v: var types.Value`).  The `Value`
  itself stays put; its interior pointers (`cons.car/cdr`, `lambda.code/env`,
  `vector.data`, `str.data`, `error_.message`) are rewritten in place via
  `scanValue`.  This is how you hold a cons list head across a collection.
- `rootPushPtr(&p)` — root a raw GC pointer slot (`p: var ?*Value` etc. —
  a *slot*, not the pointed-at value).  `p` must point at an object **head**.
- `rootPushValueVolatile`, `rootPushValueArray(base, &len)`,
  `rootPushCallframeArray` — API parity with the C roots.
- **Slices:** root a GC slice by rooting its head pointer:
  `gc.rootPushPtr(@ptrCast(&slice.ptr))`.  The object must be a single GC
  object (e.g. a `Value[n]` array allocated as one object).
- **Interior slice starts are invalid roots.**  `arr[i..]` (for `i > 0`) points
  into the middle of the object; registering it as a `ROOT_PTR` makes the GC
  read a garbage header at `*(ptr-1)`.  Root `&slice.ptr` (the object head) and
  re-derive `i..` after any collection.
- The shadow stack is **never** scanned by the GC itself — it is read by
  `scanRoots` as the root set; the drain never descends into it.  It lives in
  C-heap memory (`page_allocator`), outside both semi-spaces.
- `rootPop` / `rootPopTo(watermark)` / `rootWatermark` follow the C LIFO
  discipline.  Always pop what you push (or restore the watermark) before the
  `Gc` goes out of scope.

## Build / run

Prerequisites: Zig 0.16.x.  `ZIG_GLOBAL_CACHE_DIR` (e.g. `/tmp/zigcache`) is
recommended so the first compile reuses the std precompiled artifacts.

```sh
zig build test                     # Debug — full suite incl. the Shen GC tests
zig build test -Doptimize=ReleaseFast
zig build gc-test                  # Shen GC tests alone (incl. T8 churn + T9 panic exe)
zig build gc-test -Doptimize=ReleaseFast
zig build run                      # the main.zig demo (init → build (1 2 3) → scavenge → collect → stats)
```

The test gate (plan DECISION 7): `zig build test` and
`zig build test -Doptimize=ReleaseFast` must both pass.  `tests/gc_test.zig`
holds T1–T8; the T9 ROOT_PTR defense is a build-level expected-panic executable
(`tests/root_ptr_panic.zig`, wired into `gc-test`).
