module Elm.Interface exposing (Interface, build)

{-| Minimal selfhost stub of stil4m `Elm.Interface`.

The vendored parse closure (`Elm.Processing`) only needs `build`'s RESULT TYPE
(`Interface`, used as a `Dict` value) — `process` ignores the built context
entirely (`process _ (InternalRawFile.Raw file) = file`).  The faithful
`List Exposed` interface shape is elided here; a module name list is a valid
stand-in that keeps every consumer typechecking.

-}

import Elm.RawFile exposing (RawFile)
import Elm.Syntax.ModuleName exposing (ModuleName)


type alias Interface =
    List ModuleName


build : RawFile -> Interface
build file =
    [ Elm.RawFile.moduleName file ]
