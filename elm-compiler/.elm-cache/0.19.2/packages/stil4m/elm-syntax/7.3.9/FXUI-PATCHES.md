# FXUI patches to stil4m/elm-syntax 7.3.9

This vendored copy of the parser is DIVERGED from upstream to admit the
pre-0.16 extensible-record surface that the fx-ui typechecker targets.
Four hunks, all additive:

1. `src/Elm/Syntax/Expression.elm`
   - New constructor `InsertionValue (Node Expression)` plus matching
     `encode`/`decoder` arms (`"insertionValue"`).  This marks the RHS of a
     record-INSERTION setter (`{ r | f <- v }`) so the typechecker can
     distinguish insertion (free extension, may duplicate a label) from
     update (must expose an existing label).  The lowerer unwraps it to its
     inner expression (insertion and update lower identically).

2. `src/Elm/Parser/Expression.elm` (`recordSetterNodeWithLayout`)
   - The setter separator is now `oneOf2 "=" "<-"`.  An `=` RHS is the
     ordinary `Node Expression`; a `<-` RHS is wrapped in
     `InsertionValue valueNode` (range = the RHS node's range).

3. `src/Elm/Parser/TypeAnnotation.elm` (`recordTypeAnnotation`, Record branch)
   - After the field list, an optional `| tailvar` is accepted and produces
     `GenericRecord tailvar fields` — so BOTH tail-first (`{ r | x : Int }`)
     and tail-last (`{ x : Int | r }`, the authentic pre-0.16 order) parse to
     the same node.  The tail-last branch consumes a trailing
     `Layout.maybeLayout` after the tail name (mirroring `recordFieldDefinition`),
     otherwise `{ x : Int | r }` fails to parse — the space before `}` would
     make `followedBySymbol "}"` see ` }`.

4. `src/Elm/Writer.elm` (`writeExpression` + `writeRecordSetter`)
   - `writeExpression` gains an `InsertionValue` arm (delegates to the inner
     expression) and `writeRecordSetter` emits `name <- value` for an insertion
     RHS.  This is REQUIRED: elm 0.19.2 compiles ALL exposed modules of a
     dependency package (not just the reachable ones), and `Elm.Writer` is an
     exposed module whose `writeExpression` case has no wildcard — a new
     `Expression` constructor breaks it.  (`Elm.Processing`/`Elm.Dependency`/
     `Elm.Interface` are also exposed but never match `Expression`
     exhaustively, so they are untouched.)

Build mechanics note: elm 0.19.2 caches compiled package modules in a COMMITTED
`artifacts.dat` and never re-verifies package content once it exists.  Any edit
to these sources must be followed by deleting `artifacts.dat` (and `elm-stuff/`)
and re-running `elm-compiler/build.sh`, which regenerates it with the patch.
`elm-compiler/build.sh` also guards against a stale artifacts.dat (it deletes
it when any package `src` file is newer).
