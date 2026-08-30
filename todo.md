# fx-ui deferred work / TODO

Deferred items tracked in `plan.md` §11 (deliberate omissions, out of the M1–MX pure-core
path) plus follow-on ideas. The runtime surface (core libs) and the typechecker have both
landed; what remains are hardening / composition items on top of them. The shared VM
(`vendor/zinc-vm`) is frozen except the user-approved `prims.zig` (bitwise) + `interp.zig`
(partial-apply fix) from the Array work; `src/gc`, `tools/elmvm.zig` stay frozen.

Progress gates: `zig build elmvm`, `zig build vm-test`, `elm-compiler/build.sh`,
`tests/elm-fixtures/run-elm-gate.sh` (currently PASS=74 FAIL=0).

## Recommended (hardening / composition, after the typechecker landed)

- [ ] **Typechecker edge cases** — (a) unsaturated type-alias application silently accepted
      (wrong-arity alias should error); (b) row-kind generic alias applied to a bare type var
      (`Named r` in a signature) — documented limitation; (c) `Record.remove` as a value /
      partial application error quality; (d) the trusted skips (`Runtime.runTask` for the
      higher-kinded Task interpreter, `intern`).
- [ ] **Full end-to-end Elm program** — one program using the typechecker + Dict/Array +
      records + async I/O (M9) compiled and run end-to-end, proving the stack composes.
- [ ] **Typecheck-pass performance** — cache per-unit schemes keyed on source-hash (checking
      ~4KLOC core-libs on every gate run in pure Elm on node).

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
- [x] **TRUE nonblocking async** — **LANDED (M9)**: host-side effect-manager event loop
      (`src/vm/effectloop.zig` + `hostcall.zig`), `std.posix.poll`, out-of-order completion.
- [x] **Core libs (elm/core surface)** — `034c598`: verbatim ports of Dict (Red-Black over
      comparable), Set, Maybe, Result, Tuple, Array (relaxed radix tree via a VM-vector
      `Elm.JsArray` substitute) + structural comparable `compare` (cmpNum/cmpStrBytes/cmpList)
      over new `number?`/`string?`/`cons?`/`empty?`/`char-code` prims. zinc-vm reopened (user-
      approved) for 7 JS-int32 bitwise prims + a `buildPartialClosure` jump-target fix.
- [x] **Typechecker (full pre-0.16 scoped-labels records)** — `9520655`: HM Algorithm W over
      `src/Type/*`, Leijen extensible-record rows (Fig-3 rewrite, first-occurrence select/
      restrict, duplicate labels, `number`/`comparable`/`appendable` flex vars), `Record.remove`
      insertion `{r|f<-v}`, 3 AST rewrites driving lowering, source-ranged errors. 3-hunk
      vendored stil4m parser patch (+`FXUI-PATCHES.md`, `artifacts.dat` staleness guard).
      Gate PASS=74 FAIL=0.
