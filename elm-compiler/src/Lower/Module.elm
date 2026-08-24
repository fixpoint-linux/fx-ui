module Lower.Module exposing (compile)

-- M1b module lowering: turn a parsed Elm File into a ZINC-csexp BUNDLE.
--
-- For every top-level FunctionDeclaration we emit one bundle entry
--
--     ( [len:s]<name> ( c ( r^(arity-1) <body> v ) ) )
--
-- i.e. a curried closure (grabs mirror zinc-arity metadata; they are no-ops on
-- the C/Zig VM).  The body is lowered in Tail position (its final call uses
-- appterm) with the function's params in de Bruijn scope.
--
-- We also build the top-level global table (name -> source-arity) used by
-- Expr for name resolution (local scope -> module/global -> prim wrapper) and
-- for the 0-arg-const-vs-N-arg-function value distinction.
--
-- CURRIED PRIM WRAPPERS: the VM prim apply branch is NOT curried, so every
-- binary operator usable as a value or partially applied gets a curried
-- wrapper global.  For a 2-arg prim `<prim>`:
--
--     ( [len:s]<op>.curried ( c ( r  a[1:n]0 a[1:n]1 P[..:s]<prim> v ) ) )
--
-- where access 1 = 1st arg (param1), access 0 = 2nd arg (param2), and the prim
-- pops a1=TOP first, so we push param2 (access 0) then param1 (access 1).
-- Source operator refs (`(+)`, `(+ 1)`) route through these wrappers; direct
-- `lhs OP rhs` keeps the inline full-arity `P <prim>` fast path in Expr.
--
-- ARG CONVENTION (RTL): arguments are pushed right-to-left
-- (`m code(an)..code(a1)`), matching the elmvm gate harness which also pushes
-- command-line args RTL.  The VM pops them top-first into argbuf, so argbuf[0]
-- = first source arg (param1) = access(n-1).

import Dict exposing (Dict)
import Elm.Syntax.Declaration as Declaration exposing (Declaration(..))
import Elm.Syntax.Expression as Expression exposing (Expression, Function)
import Elm.Syntax.File as File
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..))
import Lower.Expr as Expr
import Lower.Scope as Scope
import Zinc.Csexp as Csexp
import Zinc.Emit as Emit exposing (Instr(..))


compile : File.File -> Result String String
compile file =
    let
        modName =
            moduleNameOf file
    in
    collectFunctions file.declarations
        |> Result.andThen (\funs ->
            case findDuplicate (List.map Tuple.first funs) of
                Just dup ->
                    Err ("duplicate top-level definition: " ++ dup)

                Nothing ->
                    let
                        globals =
                            buildArityDict funs

                        -- Build the base context once; each function entry gets
                        -- its own scope.  The module name lets Expr resolve
                        -- self-qualified references (Module.name) as globals.
                        baseCtx =
                            Expr.newContext modName globals

                        entryResult =
                            List.foldl (compileEntry baseCtx) (Ok []) funs
                    in
                    entryResult
                        |> Result.map (\entries ->
                            let
                                wrapperEntries =
                                    List.map wrapperEntry Expr.binaryPrims

                                bundleEntries =
                                    entries ++ wrapperEntries
                            in
                            Csexp.list bundleEntries
                        )
        )


-- The current module's name (e.g. ["Fib"] for `module Fib exposing (..)`).
-- Used by Expr name resolution to distinguish self-qualified references from
-- foreign (imported) ones.
moduleNameOf : File.File -> List String
moduleNameOf file =
    case file.moduleDefinition of
        Node _ modDef ->
            SyntaxModule.moduleName modDef


-- Collect the top-level FunctionDeclarations as (name, Function) pairs.
-- Non-function declarations are tolerated for now EXCEPT Port/Infix
-- declarations, which the subset never supports (they error).  Alias/CustomType/
-- Destructuring declarations are silently skipped (M2 implements them); if one
-- of their names is referenced the existing "unknown name" error fires.
collectFunctions : List (Node Declaration.Declaration) -> Result String (List ( String, Function ))
collectFunctions decls =
    List.foldr collectOne (Ok []) decls


collectOne : Node Declaration.Declaration -> Result String (List ( String, Function )) -> Result String (List ( String, Function ))
collectOne node acc =
    case acc of
        Err msg ->
            Err msg

        Ok funs ->
            case asFunction node of
                Just f ->
                    Ok (f :: funs)

                Nothing ->
                    case forbiddenDecl node of
                        Just msg ->
                            Err msg

                        Nothing ->
                            -- Alias/CustomType/Destructuring: tolerate silently.
                            Ok funs


-- Port/Infix declarations are never supported by the subset; everything else
-- (Alias/CustomType/Destructuring) is tolerated (M2).
forbiddenDecl : Node Declaration.Declaration -> Maybe String
forbiddenDecl (Node _ decl) =
    case decl of
        PortDeclaration _ ->
            Just "port declarations are not supported"

        InfixDeclaration _ ->
            Just "infix declarations are not supported"

        _ ->
            Nothing


asFunction : Node Declaration.Declaration -> Maybe ( String, Function )
asFunction (Node _ decl) =
    case decl of
        FunctionDeclaration fn ->
            case fn.declaration of
                Node _ impl ->
                    Just ( nodeString impl.name, fn )

        _ ->
            Nothing


-- Build the top-level global table (name -> source-arity) in ONE pass.
-- Dict.fromList alone would silently overwrite on duplicate names, so
-- duplicates are detected separately (findDuplicate) BEFORE this runs.
buildArityDict : List ( String, Function ) -> Dict String Int
buildArityDict funs =
    List.foldl
        (\( name, fn ) acc -> Dict.insert name (functionArity fn) acc)
        Dict.empty
        funs


-- First duplicate name in the (ordered) function list, if any.
findDuplicate : List String -> Maybe String
findDuplicate names =
    Tuple.second (List.foldl findDuplicateStep ( Dict.empty, Nothing ) names)


findDuplicateStep : String -> ( Dict String (), Maybe String ) -> ( Dict String (), Maybe String )
findDuplicateStep name ( seen, dup ) =
    case dup of
        Just _ ->
            ( seen, dup )

        Nothing ->
            if Dict.member name seen then
                ( seen, Just name )

            else
                ( Dict.insert name () seen, Nothing )


functionArity : Function -> Int
functionArity fn =
    case fn.declaration of
        Node _ impl ->
            List.length impl.arguments


compileEntry : Expr.Context -> ( String, Function ) -> Result String (List String) -> Result String (List String)
compileEntry baseCtx ( name, fn ) accResult =
    case accResult of
        Err msg ->
            Err msg

        Ok acc ->
            case compileOne baseCtx name fn of
                Err msg ->
                    Err msg

                Ok entry ->
                    Ok (acc ++ [ entry ])


compileOne : Expr.Context -> String -> Function -> Result String String
compileOne baseCtx name fn =
    case fn.declaration of
        Node _ impl ->
            let
                argNamesResult =
                    patternNames impl.arguments
            in
            argNamesResult
                |> Result.andThen (\argNames ->
                    Expr.lowerExpression impl.expression Expr.Tail (withArgs baseCtx argNames)
                        |> Result.map (\body ->
                            let
                                grabs =
                                    List.repeat (List.length argNames - 1) Emit.Grab

                                code =
                                    [ Emit.Cur (grabs ++ body ++ [ Emit.Return ]) ]
                            in
                            Csexp.bundleEntry name (Emit.flatten (Emit.resolve code))
                        )
                )


withArgs : Expr.Context -> List String -> Expr.Context
withArgs baseCtx argNames =
    -- RTL arg convention: push param1 FIRST so it lands at the deepest slot
    -- access(n-1); param2 -> access(n-2), ..., param_n -> access(0).
    { baseCtx | scope = List.foldl Scope.push baseCtx.scope argNames }


-- A 2-arg curried wrapper for a binary prim:  (c (r a[1:n]0 a[1:n]1 P p v)).
-- Under RTL, param1 = access(1), param2 = access(0).  The prim pops a1 = TOP
-- first and we need a1 = param1, so we push param2 (access 0) then param1
-- (access 1).
wrapperEntry : ( String, String ) -> String
wrapperEntry ( op, prim ) =
    let
        name =
            Expr.wrapperGlobalName op

        body =
            [ Emit.Access 0, Emit.Access 1, Emit.Prim prim, Emit.Return ]

        code =
            [ Emit.Cur (Emit.Grab :: body) ]
    in
    Csexp.bundleEntry name (Emit.flatten (Emit.resolve code))


patternNames : List (Node Pattern.Pattern) -> Result String (List String)
patternNames nodes =
    case nodes of
        [] ->
            Ok []

        n :: rest ->
            Result.map2 (::) (patternName n) (patternNames rest)


patternName : Node Pattern.Pattern -> Result String String
patternName (Node _ pat) =
    case pat of
        VarPattern name ->
            Ok name

        ParenthesizedPattern (Node _ inner) ->
            patName inner

        _ ->
            Err "M1b supports only variable patterns in function arguments (pattern compiler is M2)"


patName : Pattern.Pattern -> Result String String
patName pat =
    case pat of
        VarPattern name ->
            Ok name

        ParenthesizedPattern (Node _ inner) ->
            patName inner

        _ ->
            Err "M1b supports only variable patterns in function arguments (pattern compiler is M2)"


nodeString : Node String -> String
nodeString (Node _ s) =
    s
