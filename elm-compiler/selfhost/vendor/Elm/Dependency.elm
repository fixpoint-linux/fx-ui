module Elm.Dependency exposing (Dependency, Version)

{-| stil4m `Elm.Dependency`, verbatim (no Json codec surface — the pruner left
the parse closure's `addDependency` path, which needs the record shape).

-}

import Dict exposing (Dict)
import Elm.Interface exposing (Interface)
import Elm.Syntax.ModuleName exposing (ModuleName)


type alias Dependency =
    { name : String
    , version : Version
    , interfaces : Dict ModuleName Interface
    }


type alias Version =
    String
