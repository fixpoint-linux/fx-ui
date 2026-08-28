# fx-ui deferred work / TODO

Deferred items tracked in `plan.md` §11 (deliberate omissions, out of the M1–MX pure-core
path) plus follow-on ideas. Each is a port-completion of an already-Zig sibling file in
`~/projects/shen/zig/src/vm/` unless marked otherwise. `src/gc`, `src/vm`, `tools/elmvm.zig`
are frozen except when a milestone explicitly ports a named seam (M6 streams, M8 execplan).

Progress gates: `zig build elmvm`, `zig build vm-test`, `elm-compiler/build.sh`,
`tests/elm-fixtures/run-elm-gate.sh`. Handoff chains: `handoff-elm-csexp-m<8>-*`.

## Deferred / recommended

- [x] **TRUE nonblocking async** — poll/select VM seam. The one deferred item with real
      user-facing value for fx-ui: lets Elm programs do real concurrency instead of M7's
      deterministic single-threaded cooperative sequencing. **LANDED (M9)** as a host-side
      effect-manager event loop (`src/vm/effectloop.zig` + `hostcall.zig`): main returns a
      Program, the host interprets Tasks natively with `std.posix.poll`, out-of-order
      completion proven by the asyncorder fixture. Gate 54/54, vm-test 86/86.
- [ ] **Widen the Elm runtime surface** — more core libs (Dict/Set/Array/Result/Maybe),
      error messages with source ranges, type-checking (currently untyped-subset).
      Directly serves the "Elm" half of fx-ui.

## Shen-runtime machinery — NOT recommended for fx-ui

These all make the VM a fuller *standalone Shen runtime* (self-hosting interpreter / REPL).
They are `shen`-repo concerns, carried onto fx-ui's `plan.md` §11 only because it documents
what the shared VM is missing. An Elm runtime never evaluates Shen forms at runtime (Elm
compiles statically host-side), so these have ~zero value for fx-ui:

- [ ] **eval-kl + marshal layer** (`marshal.zig` + `hostcall.zig` + `eval-kl` prim).
      Metacircular Shen evaluation: marshal a Shen form to tagged form, run it through the
      compiled `extract-kl`/`kl->zinc`/`toplevel-interp` closures, demarshal the result.
      Powers `meta_repl`. ~zero value for an Elm runtime.
- [ ] **meta_repl** — interactive read-eval-print loop over the VM. Consumer of eval-kl.
- [ ] **defun_freeze perfect hash** — O(1) frozen-name resolution in the defun table.
- [ ] **symbol_static** — pre-interned static symbol store (VM currently uses a dynamic
      interner).
- [ ] **trace facility** — bytecode/execution trace for debugging the compiled chain.

## Done

- [x] **M6 — I/O + effects** (`07607ce`): stream prims + self-hosted Platform/Cmd/Sub.
- [x] **M7 — async Kernel** (`81f2cf5`): cooperative Task monad + effect-manager loop.
- [x] **M8 — process execution** (`c3fac66`): execplan.zig port (exec-plan + env/cwd prims).
      VM interp.zig vaPop/envPop leak fix: `cd9be11` (separate).
