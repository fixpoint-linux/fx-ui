module Elm.RawFile exposing
    ( RawFile
    , moduleName, imports
    )

{-|

@docs RawFile

@docs moduleName, imports


-}

import Elm.Internal.RawFile as InternalRawFile
import Elm.Syntax.File as File
import Elm.Syntax.Import exposing (Import)
import Elm.Syntax.Module as Module
import Elm.Syntax.ModuleName exposing (ModuleName)
import Elm.Syntax.Node as Node


{-| A Raw file
-}
type alias RawFile =
    InternalRawFile.RawFile


{-| Retrieve the module name for a raw file
-}
moduleName : RawFile -> ModuleName
moduleName (InternalRawFile.Raw file) =
    Module.moduleName <| Node.value file.moduleDefinition


{-| Encode a `RawFile` syntax element to JSON.
-}
imports : RawFile -> List Import
imports (InternalRawFile.Raw file) =
    List.map Node.value file.imports
