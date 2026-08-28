# fx-ui — Elm → ZINC-csexp compiler: complete M1–MX plan

> Living consolidation of `handoff-elm-csexp-plan` (memory) + the design decisions in
> `elm-zinc-bootstrap-idea`, refreshed to the current repo state. The goal of this
> thread is a **minimal Elm runtime**: parse Elm source with `stil4m/elm-syntax`
> (an **Elm** library), lower the resulting AST to **ZINC csexp bytecode**, and run it
> natively on the already-ported **Zig ZINC VM** (`src/gc` + `src/vm`, which are DONE
> and reviewed safe-to-ship).

---

## 0. Status — where we are (2026-08-25)

**Thread 1 — Zig ZINC VM + moving GC: DONE.** `src/gc` + `src/vm` fully green on Zig
0.16.0 (vm-test 67/67 in Debug+ReleaseSafe+ReleaseFast; `zig build test` clean),
reviewed safe-to-ship, committed.

**Thread 2 — Elm→ZINC-csexp compiler frontend (`elm-compiler/`): DONE.**
- **M0** (bootstrap + `tools/elmvm.zig` gate harness): DONE — proved the full
  `elm → csexp → elmvm → value` path.
- **M1a** (emitter infrastructure): DONE — `Zinc/Csexp.elm`, `Zinc/Emit.elm`,
  `Lower/Scope.elm`; 17 emitter assertions pass via node on host.
- **M1b** (core expression lowering): **DONE** — `Lower/Expr.elm` + `Lower/Module.elm`,
  functional-core subset, prim curried-wrapper table, RTL/auto-push/tail-position.
- **M1c** (module wiring): **DONE** — module name, qualified self-refs, dup detection,
  one-pass arity. Gate 20/20 green (commits 4fcd832, 96f13f3).
- **MX** (terminal: pure-core runtime `main -> value`): **DONE** — ADT ctors hardened
  to vectors `[tag, a1..an]` (absvector + address->); records stay assoc lists;
  composed `main : Int` / `main : String` gate fixtures (mxint/mxstring). Gate 42/42,
  vm-test 78/78.
- **M6** (I/O + effects runtime, first effects milestone): **DONE** — VM stream seam
  ported (`src/vm/streams.zig`: write-byte/read-byte/read-file-as-string/open/close +
  `Vm.streams` registry + real `*stinput*`/`*stoutput*`/`*sterror*` fds); a self-hosted
  `Runtime.elm` message loop (a `Platform.worker`-style `init`/`update`/`Cmd` effects
  model compiled by the compiler itself, like Prelude) + `Cmd`/`Sub` alias tables +
  stdin/stdout pseudo-globals. Gate 45/45 (iofile file round-trip + ioecho stdin
  echo-until-quit), vm-test 83/83. Also fixed a pre-existing label-collision bug in
  `bindDestructuring` (site-unique `let_bad`/`let_ok`) and a GC grow-barrier gap in
  `interp.zig` (byte-identical to shen's reference).
- **M7** (async Kernel: Task monad + effect-manager loop): **DONE** — a cooperative
  `Task x a` ADT (succeed/fail/andThen/onError + stream leaves) replaces M6's flat
  `Eff` list; `Cmd msg = List (Task Never msg)`; a `runTask` scheduler (mutual tail
  calls, constant-stack andThen steps) + the generalized `drive`/`runOne` effect-manager
  loop; `Task.map/map2/sequence/perform/attempt` + `Cmd.map` surface, all desugared to
  andThen+succeed+fail (no extra ctors). Fixtures keep real-Elm `Task.*`/`Cmd.*`/`Io.*`
  spellings via `Lower.Module.platformTable`. Gate 48/48 (taskpure/taskseq/taskattempt
  + iofile/ioecho rewritten to the Task spelling), vm-test 83/83. TRUE nonblocking
  (poll/select VM seam) is a separate future milestone — deliberately out of scope.
- **M8** (process execution): **DONE** — the declarative plan-runner `exec-plan` +
  the 7 env/cwd prims (`cd`/`getcwd`/`getpid`/`getenv`/`setenv`/`glob`; `wait`/`kill`
  excluded — they exist only for background processes). `src/vm/execplan.zig` synced
  from `shen/zig` (verbatim minus the native-only `is_wasm` gates and the wait/kill
  prims + test accessors); `build.zig` links libc on the vm/elmvm/vm-test modules;
  the prims registered in `src/vm/prims.zig`. Elm surface: `Io.exec`/`Io.getenv`/
  `Io.setenv`/`Io.cd`/`Io.getcwd`/`Io.getpid`/`Io.glob` leaf Tasks + `Plan.*` tagged-
  list builders (`str`/`num`/`sym`/`nil`/`cons` + `intern`) building the Shen TAGGED-LIST
  demarshal plan format; `decodeExec`/`decodeStringList` walk the tagged results.
  Gate 51/51 (execpipe pipeline / execenv env+cwd / execglob), vm-test unchanged.
- **M9** (TRUE nonblocking async): **DONE** — a HOST-SIDE effect-manager event loop
  (Design A; `src/vm/effectloop.zig` + `src/vm/hostcall.zig`). The VM runs each call
  as deep native `vmExecEnv` recursion (stream prims block natively), so effects run
  in the HOST: `main` returns a Program as DATA (vector `[Program, m0, c0, update]`,
  tag = bare symbol `'Program'`; `Platform.program`/`Runtime.program`); the host loop
  interprets each Task natively (CEK machine over the Task ADT) with nonblocking I/O
  via `std.posix.poll`, applies continuation closures via `applyClosureN` (a fresh
  `vmExecEnv` call), feeds msgs to update, and loops. `readFile` opens `O_NONBLOCK`
  and drains available bytes; `exec` runs a single command async (fork+execvp, piped
  stdout/stderr polled + `waitpid WNOHANG`); complex plans/redirects fall back to the
  sync `exec-plan`; `write`/`writeFile`/env/cwd/getpid/glob are synchronous. Multiple
  independent effects in flight complete OUT OF ORDER — proven by `asyncorder`
  (slow `sleep 1` exec + fast read: model `"file,ran"`). Gate 52/52; vm-test 86/86.

Convention: this document numbers milestones **M1 … MX** where **MX is the terminal
milestone** (the pure-core Elm runtime delivering `main -> value`). The compiler
front-end is M1–M3; the runtime-completion work is M4–MX, and the I/O/effects runtime
(M6) is the first post-MX milestone.

---

## 1. The chain (architecture)

```
Elm source (.elm)
  → stil4m/elm-syntax (Elm, parse to Elm.Syntax.File.File AST)
  → Lower.Module.compile / Lower.Expr.lowerExpression (new codegen: AST → flat ZINC instrs)
  → Zinc.Emit.resolve (2-pass label resolve) + flatten (→ csexp text)
  → .csexp bundle file
  → tools/elmvm.zig (init Gc+Vm, parseBundle, vmExec) → value
```

This is **NOT** based on the earlier `elm-native` (MLton/SML) idea. The VM is
dynamically typed, so a minimal untyped-subset runtime can dodge most overload
disambiguation that Elm's typechecker normally handles; Float/overloads are the
known bite-point (addressed in M4).

---

## 2. Target semantics (verified against the Zig VM + globals.csexp)

- **Opcodes:** `a`=access, `g`=global, `f`=jmpf, `j`=jmp, `t`=appterm, `p`=apply,
  `m`=pushmark, `c`=cur, `r`=grab, `v`=return, `e`=let, `d`=endlet, `n`/`S`/`s`/`b`=
  number/string/symbol/boolean literal (each **sets acc AND auto-pushes**; there is
  **no push opcode**), `P`=prim.
- **Csexp atom:** `[len:type]value`, `len` = **byte** length (negative `n` data is fine).
- **Bundle:** `(([len:s]name (c<body>)) …)` — `parseBundle` unwraps the single `cur`
  and `defunSet`s it (fx-ui `src/vm/parser.zig`).
- **Apply arg order:** `pushmark`, then args **RIGHT-TO-LEFT** (rightmost pushed first),
  then function expr, then `p`. `argbuf` collects `[a1..an]` leftmost-first; new env =
  `closure.env ++ [a1..an]`, so in the callee `param1=access(n-1)` … `paramN=access(0)`.
- **de Bruijn index** = distance from the innermost binder
  (`interp.zig lookupEnv`: `env[env_len-1-n]`).

### Curried VM (commit `5d340b7`): the compiler is simpler
The VM now implements full currying: `apply`/`appterm` with **N<A** → partial closure,
**N>A** → Elm-style over-app peel, **N==A** unchanged. The compiler does **not**
compute arity or reject partial application. **One** emission rule for all calls (see §4).

---

## 3. Data representation

| Elm | ZINC |
|---|---|
| Int | VM `number` (i64; `//` = `@divTrunc`) |
| Bool | VM `boolean` (required by `jmpf`) |
| String | VM `string` (UTF-8 bytes; atom `len` is **byte** length — `utf8ByteLength`, not code points) |
| Char | M3 optional (single-char string) |
| `[]` / list | `n[1:n]0 P emptylist` / cons chain |
| Tuple | `@p` right-nested (`(a,b)` → `code(b) code(a) P @p`) |
| Record | `@p`(symbolFieldName, value) assoc list, right-to-left |
| ADT / custom type | `vector[tagSymbol, a1..an]` (absvector + address->); each ctor becomes a normal defun |
| `True`/`False` in patterns | `= b[4:b]true` / `= b[5:b]false` boolean-atom tests |

**Caveats (document, don't fix):** `cons?` pattern tests also match `@p` values
(structural, untyped — same as KLambda); wrong-arity calls through variables =
silent garbage; no `Float` in the M1–M3 subset (M4 adds it); `++` forbidden
(`String.append`/`List.append` instead). Record update `{r|f=v}` PREPENDS a shadow
pair, so `{r|f=v} == {f=v}` is FALSE when `r` already has `f` (assoc
first-match-wins keeps ACCESS correct).

---

## 4. Emission rules (the authoritative table)

**Model:** mirror `shen/shen/zinc.shen` (zinc-c/zinc-t); confirmed against `globals.csexp`.

| Construct | Emission |
|---|---|
| N-ary top-level fn | bundle entry `(c (r×(n-1)) <body> v)` — grabs mirror zinc (no-ops on the C/Zig VM, kept for metacircular-bundle compat) |
| `let x = e1 in e2` non-tail | `code(e1) e code(e2) d` |
| `let x = e1 in e2` tail | `code(e1) e code(e2)` (no `endlet`) |
| `if c t e` | `code(c) f Lf code(t) j Le Lf: code(e) Le:` (2-pass labels; `cur` = 1 instr, labels 0) |
| binop `lhs OP rhs` | **`code(rhs) code(lhs) P op`** (RTL — the #1 bug pattern) |
| `[]` | `n[1:n]0 P[9:s]emptylist` |
| `x :: xs` | `code(xs) code(x) P cons` |
| `[a,b,c]` | `n0 P emptylist`, `code(c) P cons`, `code(b) P cons`, `code(a) P cons` |
| `(a,b)` / `(a,b,c)` | `code(b) code(a) P @p` / `@p a (@p b c)` |
| negate literal | negative `n` atom; of expr → `code(e) n0 P subtract` |
| `==` | `P =` (deep_equal covers cons/@p trees = ADTs+records+tuples+lists) |
| `/=` | inline not: `code(==) f L b[5:b]false j E L: b[4:b]true E:` |
| `&&` / `\|\|` | short-circuit `if a then b else False` / dual (**never** eager prim) |
| call `f a1..an` (known arity, non-tail) | `m code(an)..code(a1) g f p` |
| call `f a1..an` (tail) | same with `t` (appterm) |
| call via variable/expr | `m code(an)..code(a1) code(fnexpr) p` |
| 0-arg constant reference | `m g name p` (apply allows 0 args; appterm does NOT) |
| local lambda `\p1..pn -> e` | `c( (r×(n-1)) code(e) v )` with scope `[pn..p1 \| outer]`, innermost=0 |

### REVISION — call emission (curried VM, current)
`f a1..an` → **`m code(an)..code(a1) code(f) p`** — RTL args, **ONE apply, ANY arity**.
VM dispatches N==A / N<A partial / N>A over-app; compiler does not reject. Tail → `t`.
0-arg const ref stays `m g name p`. N-ary fn → curried closure `(c (r^(N-1) body v))` —
partial app of user fns "just works".

### REVISION — primitives (CRITICAL)
The VM's `apply` **prim** branch is **not** curried — over/under-applying a prim throws.
Therefore the compiler **must wrap each primitive used as a value or partially applied in
a CURRIED CLOSURE**: e.g. global `subtract.curried` = `(c (r (r <body>)))` where `<body>`
does the full-arity `access a2 access a1 P subtract v`. Source operator refs (`+`, `(+)`,
`(+ 1)`) resolve to the wrapper global; operator application = a normal curried call
through the wrapper. Keep inline `P op` only as an optional **full-arity** fast path.
This makes `(+)`, `(+ 1)`, `map (+) xs`, `map Just xs` all work.

### REVISION — removed
(1) "partial application = compile error"; (2) "over-app → M1 error / M2 let-temp";
(3) the arity-tracking rejection in `Lower/Module`. The only remaining compiler
responsibility re arity: a **primitive** call is either full-arity inline `P` or routed
through the curried wrapper — never a bare partial prim.

---

## 5. Case / pattern compiler (the crux — M2)

`case e of clauses` → `code(e) e` (scrutinee temp slot), then per clause `i`:
- emit tests for `pattern_i` against `access(slot)`; after **each** test emit `f next_i`
  (`jmpf` pops the test boolean); then binds (each binder = `let`-chain with temps, e.g.
  `Cons h t` → `let H=hd(slot) e let T=tl(slot) e …`; named ctor → temps for fst/snd +
  arg walks); then `body_i` (tail-aware) `j End`; then `next_i:` label.
- after the last clause emit `S[..:S]"non-exhaustive case" P simple-error` (throws —
  Elm exhaustive-check is unavailable untyped). `End:` label; `endlet` the scrutinee temp
  (+ any pending) in **non-tail**.
- Multi-clause / pattern-arg top-level fns and `\` pattern lambdas desugar to a
  single-param fn of a tuple-of-args + one `case` with tuple patterns (right-nested `@p`).
  All-var single-clause fns skip the desugar (direct params).
- **Tail-position threading:** `Tail | NonTail` context exactly like zinc-t/zinc-c;
  appterm **only** in genuine tail positions. Using `apply` where `appterm` fits is safe
  (stack-hungry); using `appterm` non-tail is **wrong**. M2 fixture must include a
  100k-deep tail loop to prove appterm (CALL_STACK_DEPTH=65536 would crash otherwise).

---

## 6. Module layout (all new; nothing existing touched)

```
fx-ui/elm-compiler/
  elm.json
  src/Main.elm            — orchestrate parse → Lower.Module.compile → Emit.resolve → flatten → emit port
  src/TestMain.elm        — node-side test driver
  src/Zinc/Csexp.elm      — atom/list emitter + utf8ByteLength          [M1a DONE]
  src/Zinc/Emit.elm       — Instr type + 2-pass label resolve + flatten [M1a DONE]
  src/Lower/Scope.elm     — de Bruijn scope stack                       [M1a DONE]
  src/Lower/Expr.elm      — expression lowering                         [M1b: in tree]
  src/Lower/Pattern.elm   — pattern compiler                            [M2 — stub now]
  src/Lower/Module.elm    — File → bundle: module/arity/ctor tables, name resolution,
                            embedded preludeSource, curried prim wrappers [M1b: in tree]
  src/Prelude.elm         — subset-Elm source STRING compiled at startup (M3):
                            not, Maybe/Result ctors+fns, List.map/filter/foldl/append/length,
                            String.concat/length/join, Basics.identity/always/clamp;
                            alias table user names → Prelude.* globals
  run.js                  — node wrapper: read .elm, Elm.Main.init, emit port → .csexp
  build.sh                — ELM_HOME=$PWD/.elm-cache elm make src/Main.elm --output=compiler.js
fx-ui/tools/elmvm.zig     — init Gc+Vm, read bundle, parseBundle, vmExec (M0 DONE)
fx-ui/build.zig           — addExecutable `elmvm` importing src/vm (M0 DONE)
fx-ui/tests/elm-fixtures/*.elm + expected/*.txt + run-elm-gate.sh
```

---

## 7. Bootstrap / verification notes

- elm 0.19.2 binary works **in-sandbox** (`/workspace/shen/node_modules/.bin/elm`), but
  sandbox DNS is empty → registry fetch fails. **Staging must be host-side**:
  `ELM_HOME=$PWD/.elm-cache elm init; elm install stil4m/elm-syntax` fills correct pins and
  populates the repo-local cache so all later builds are **offline-capable**. Keep
  `.elm-cache` in-repo (not gitignored).
- Verify offline build in-sandbox with
  `ELM_HOME=/workspace/fx-ui/elm-compiler/.elm-cache … elm make`. If elm still demands the
  all-packages list, fall back to **host-side `elm make` only** (build.sh auto-detects)
  and/or vendor elm-syntax+deps src into `source-directories`.
- `rattan_pacman_install(['nodejs'])` for in-sandbox differential runs.
- Zig 0.16.0. Sandbox rattan rejects `*` `?` `2>/dev/null` — use script files.

---

## 8. Milestones M1 … MX

### M1 — core expression lowering  *(tier: pro-coder; DONE — M1a/M1b/M1c, gate 20/20)*
- **M1a** (done): `Zinc/Csexp.elm`, `Zinc/Emit.elm`, `Lower/Scope.elm`; 17 emitter asserts.
- **M1b** (resume): `Lower/Expr.elm` + `Lower/Module.elm` + wire `Main.elm` + the primitive
  curried-wrapper mechanism. Functional-core subset ONLY: Integer/Hex, Literal(String),
  CharLiteral, `True/False`, Negation, ParenthesizedExpression, Application,
  OperatorApplication (arith + - * // == /= < <= > >=, and `&&`/`||` short-circuit),
  FunctionOrValue (local→module→global), IfBlock, LambdaExpression, LetExpression
  (LetFunction single-arg + LetDestructuring-to-VarPattern), ListExpr, TupledExpression.
  Prim names: `add subtract multiply divide lt le gt ge = cons emptylist @p fst snd …`
  (2-arg prims pop a1=TOP=leftmost then a2 → **RTL**).
- **Gate fixtures** (tests/elm-fixtures/*.elm → expected): `fib 10 = 55`;
  `10-3=7` **and** `3-10=-7` (RTL trap both ways); `100//7=14`; nested lets/ifs; closure
  call (returned fn then applied); apply-twice via fn value; `countdown 100000` tail loop
  (appterm proof); `==` on lists; 0-arg const; **partial app** `add 5` then apply to `3 → 8`;
  `(+ 1) 2 → 3`; `(+)` as a value.
- **REVIEW:** deep-review (correctness-critical: RTL/auto-push/tail-position/prim-wrappers —
  silent-wrong-results failure modes).

### M2 — patterns, ADTs, records, tuples, short-circuit  *(tier: pro-coder)*
- Case-of pattern compiler per §5: nested patterns, literals, cons, wildcards, vars,
  tuple patterns, record patterns.
- ADTs/custom types: each `type` decl → ordinary defuns per ctor (Module.CtorName, arity =
  ctor arity, body builds the `@p` value); BARE ctor refs are function-as-value globals
  (no partial-app problem). ADT pattern = `cons?` AND `fst = tag` tests + hd-walk of `snd`.
- Records: construct (right-to-left @p assoc), `.x` access → Prelude.fieldGet, `{r | x=v}`
  update → Prelude.fieldSet, `{x,y}` pattern → fieldGet binds.
- Tuples `@p`, `&& ||` short-circuit, over-app via the curried VM, deep structural `==`.
- **Gate:** list sum via `case`; ADT expression evaluator (recursive case over an AST);
  record CRUD; Maybe-chain; `False && crash` short-circuit proof; deep structural `==`.
- **REVIEW:** deep-review (endlet balance / case tree correctness).

### M3 — prelude, strings, multi-module  *(tier: coder)*
- Embedded `Prelude.elm` (compiled by the compiler itself at startup) + alias table.
- String ops via `cn str c-strlen pos substring` prims; String escapes; UTF-8 byte lengths.
- Multi-module: imports/exposing (minimal: qualified refs + explicit expose).
- Error messages with Node ranges; gate runner script + make target.
- **Gate:** `List.map/filter/foldl` over 1000 elems; `String.concat/join`; cross-module call.
- **REVIEW:** review.

### M4 — Float  *(tier: pro-coder — VM change + compiler)*
- **Modify the VM** to add a float tag (`VAL_FLOAT` + float arith prims) — the user's
  chosen Float strategy (a genuine gap: VM numbers are i64).
- Compiler: `Float`/`Floatable` literals → float atoms; `+ - * /` float variants /
  overload dispatch (the known untyped bite-point).
- **Gate:** Float arithmetic end-to-end; mixed Int/Float behavior documented.

### MX — terminal milestone: pure-core Elm runtime `main -> value`  *(tier: pro-coder; DONE)*
- ADT/custom-types hardened to `vector[tag, a1..an]` (index 0 = tag Symbol, indices
  1..n = args) via absvector + address->; records stay `@p` assoc lists (see §3).
- Full pure-core subset composed: an end-to-end **gate on real Elm programs**
  (`main : Int` = mxint, `main : String` = mxstring), run through `elmvm`.
- Final consolidated review + docs; the runtime is the foundation for a later
  I/O/effects milestone (out of MX scope — pure core only).

---

## 9. Routing evidence

Implementer-routing leans **under-implementation**: heavy correctness-critical work in
`projects/shen` (complex-tier coder failures — fx-ui M4 precise-rooting, projects/shen P2
integration) previously warranted **pro-coder**. The compiler frontend is novel,
wide-blast-radius on semantics, with subtle full-arity/RTL/auto-push correctness traps.
→ **pro-coder for M1, M2, M4, MX** (the codegen/VM-semantics crux); **coder for M3**
(contained prelude/strings/modules polish) and the M0/M1a bootstrap.

---

## 10. Uncertainties / risks

1. elm-syntax exact parser entrypoint/AST field names — **resolved** (verified 7.3.9 AST
   shapes in `handoff-elm-csexp-m1b-ctx`); re-confirm against the staged package source.
2. Offline `elm make` with a full repo-local ELM_HOME may still fetch all-packages —
   fall back to host-side builds.
3. fx-ui `prims.zig` is an older snapshot than shen's (missing stream/process prims —
   the subset needs none; core names verified present). If drift bites, sync the parser/
   interp/prims files from `shen/zig`.
4. `printValue` output format for `expected/*.txt` — read `src/vm/values.zig` when writing
   fixtures.
5. Untyped-subset caveats (§3) — document, don't fix.
6. elm auto-imports List/Maybe/Basics in every module — the subset compiler ignores
   implicit core imports and resolves those names via the prelude alias table; fixtures
   must not rely on anything beyond the alias table.

---

## 11. Deliberate omissions / out of scope

Not in the M1–MX pure-core path: ~~process-execution primitives~~ (landed in M8 — `exec-plan` +
`cd`/`getcwd`/`getpid`/`getenv`/`setenv`/`glob`, `wait`/`kill` excluded), `meta_repl`, `defun_freeze`
perfect hash, `eval-kl` + marshal layer, `symbol_static`, the trace facility, and the
~~asynchronous Kernel `Task`/effect-manager half of a full Elm runtime~~ (landed in M7 as a
cooperative Task monad + effect-manager loop). The stream I/O prims
(`write-byte/read-byte/read-file-as-string/open/close` + `val_string_stream_in`) and a
minimal self-hosted `Platform`/`Cmd`/`Sub`-style effects runtime have landed in M6 (sync
`src/vm` from `shen/zig` when porting the remaining deferred pieces). ~~TRUE nonblocking
(poll/select VM seam) remains out of scope.~~ TRUE nonblocking async has landed in M9
(a host-side effect-manager event loop with `std.posix.poll` + nonblocking readFile/exec).
MX deliberately stops
at the **pure** `main -> value` runtime.
