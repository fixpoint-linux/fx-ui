module Type.Check exposing (checkUnits)

{-| S6 pipeline orchestration: typecheck every compilation unit in DEPENDENCY
order and return the checker-REWRITTEN `File`s (the three surgical rewrites
from `Type.Infer`), ready for the existing lowering path.

`Lower.Module.compileSources` calls this after `collectAll`; it must live in its
own module (not `Lower.Module`, not `Type.Env`) because it imports `Type.Infer`,
which imports the shared alias tables from `Lower.Resolve` — and
`Lower.Module` imports `Type.Check`, so the only acyclic arrangement is:

    Lower.Module -> Type.Check -> Type.Infer -> Lower.Resolve -> Lower.Expr

The merged environment is built UP FRONT from every unit's signatures / ADT
constructor argument types / type aliases (exactly what `Env.collectFile`
collects).  Units are then checked in dependency order; each unit's inferred
schemes (its generalized unsignatured top-level functions) are merged back into
the environment so DOWNSTREAM units can resolve them.  This ordering is what
makes `Prelude`'s unsignatured `map`/`filter`/`compare`/`sum`/... resolvable
from `Dict`/`Set`/the fixtures even though `run.js` appends `Prelude` AFTER the
user units.

Reordering: the nine built-in modules (Prelude, Runtime, and the seven
core-libs) go first in a fixed canonical order (dependencies satisfied:
Prelude before Runtime/core-libs; JsArray before Array; Dict before Set), then
the user units are topologically sorted by their parsed `import` lists (CLI
order preserved for independent modules; a cycle is an error).

TRUSTED UNITS: `JsArray` and `Array` are trusted-skipped (their bodies are NOT
checked) for two documented reasons, both discovered during planning:
  * `JsArray`'s body uses the VM vector prims, whose uniform-poly `JsArray a`
    schemes lie about slot 0 (an `Int` element count), so `length a = vectorGet
    a 0` cannot be typed as `JsArray a -> Int`.
  * `Array`'s ADT/alias annotations reference the undeclared opaque `JsArray`
    type unqualified AND it calls `JsArray.*` functions (unsignatured in the
    skipped `JsArray` unit), so its body has no resolvable schemes for those
    calls.  Its SIGNATURES are still collected (clean public API), so fixtures
    using `Array.foldl`/`get`/`push`/... typecheck normally.

-}

import Elm.Syntax.File as File
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Type.Env as Env exposing (Env, Scheme)
import Type.Error as Error
import Type.Infer as Infer


{-| Check all units in dependency order; return the rewritten files (same
length, dependency-ordered).  Errors are already rendered (`type error at ...`
for inference failures, a plain message for import cycles).
-}
checkUnits : List File.File -> Result String (List File.File)
checkUnits files =
    let
        env0 =
            List.foldl (\f env -> Env.merge env (Env.collectFile f)) Env.empty files
    in
    orderUnits files
        |> Result.andThen (\ordered -> checkInOrder env0 ordered [])


checkInOrder : Env -> List File.File -> List File.File -> Result String (List File.File)
checkInOrder env files acc =
    case files of
        [] ->
            Ok (List.reverse acc)

        f :: rest ->
            if isTrustedUnit (moduleNameStr f) then
                -- Body skipped; signatures/ctors/aliases are already in the
                -- (up-front) environment.  Keep the ORIGINAL file — no
                -- rewrites are needed because the body is never checked.
                checkInOrder env rest (f :: acc)

            else
                case Infer.inferUnit env f of
                    Err err ->
                        Err (Error.render err)

                    Ok checked ->
                        checkInOrder (insertSchemes checked.schemes env) rest (checked.file :: acc)


insertSchemes : List ( String, Scheme ) -> Env -> Env
insertSchemes schemes env =
    List.foldl (\( n, s ) e -> Env.insert n s e) env schemes



-- ======================= REORDERING =======================


{-| The canonical dependency order for the nine built-in modules.  `Prelude`
first (its unsignatured List/Basics/compare functions are used by every other
module); `Runtime` next (its unsignatured `worker`/`task*` functions are used
by the effects fixtures); then the seven core-libs in dependency order
(`JsArray` before `Array`, `Dict` before `Set`).
-}
canonicalOrder : List String
canonicalOrder =
    [ "Prelude"
    , "Runtime"
    , "JsArray"
    , "Dict"
    , "Set"
    , "Array"
    , "Maybe"
    , "Result"
    , "Tuple"
    ]


{-| Units whose bodies are trusted-skipped (see the module docstring).
-}
trustedUnits : List String
trustedUnits =
    [ "JsArray", "Array" ]


isKnown : String -> Bool
isKnown name =
    List.member name canonicalOrder


isTrustedUnit : String -> Bool
isTrustedUnit name =
    List.member name trustedUnits


orderUnits : List File.File -> Result String (List File.File)
orderUnits files =
    let
        known =
            List.filterMap (\name -> findByModule name files) canonicalOrder

        user =
            List.filter (\f -> not (isKnown (moduleNameStr f))) files
    in
    topoUser user
        |> Result.map (\u -> known ++ u)


findByModule : String -> List File.File -> Maybe File.File
findByModule name files =
    case files of
        [] ->
            Nothing

        f :: rest ->
            if moduleNameStr f == name then
                Just f

            else
                findByModule name rest


{-| A stable topological sort of the USER units by their parsed import lists.
CLI order is preserved for independent modules; a module is "ready" once every
import is either already placed or names a built-in/unknown module (resolved
outside the user set).  If no module is ready but units remain, the import
graph has a cycle.
-}
topoUser : List File.File -> Result String (List File.File)
topoUser files =
    topoUserHelp files []


topoUserHelp : List File.File -> List File.File -> Result String (List File.File)
topoUserHelp remaining placed =
    case remaining of
        [] ->
            Ok (List.reverse placed)

        _ ->
            let
                placedNames =
                    List.map moduleNameStr placed

                remainingNames =
                    List.map moduleNameStr remaining

                ready =
                    List.filter
                        (\f ->
                            List.all
                                (\imp -> List.member imp placedNames || not (List.member imp remainingNames))
                                (importTargets f)
                        )
                        remaining
            in
            case ready of
                [] ->
                    Err ("import cycle detected among modules: " ++ String.join ", " remainingNames)

                f :: _ ->
                    topoUserHelp (List.filter (\g -> g /= f) remaining) (f :: placed)


importTargets : File.File -> List String
importTargets file =
    List.map (\(Node _ imp) -> String.join "." (Node.value imp.moduleName)) file.imports



-- ======================= HELPERS =======================


moduleNameStr : File.File -> String
moduleNameStr file =
    String.join "." (moduleNameOf file)


moduleNameOf : File.File -> List String
moduleNameOf file =
    case file.moduleDefinition of
        Node _ modDef ->
            SyntaxModule.moduleName modDef
