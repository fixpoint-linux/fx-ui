module Lower.Module exposing (compile)

-- M1b/M1c/M2 module lowering: turn a parsed Elm File into a ZINC-csexp BUNDLE.
--
-- For every top-level FunctionDeclaration (grouped by name; see below) we emit
-- one bundle entry
--
--     ( [len:s]<name> ( c ( r^(arity-1) <body> v ) ) )
--
-- i.e. a curried closure (grabs mirror zinc-arity metadata; they are no-ops on
-- the C/Zig VM).  The body is lowered in Tail position (its final call uses
-- appterm) with the function's params in de Bruijn scope.
--
-- M2 ADDS:
--   * CustomTypeDeclaration ctor DEFUNS.  Each value constructor (name, arity
--     n) becomes a bundle entry whose body builds
--
--         (tag . [a1..an])     via   n0 P emptylist  a[0:n]0 P cons ... @p tag
--
--     under RTL: param1 = access(n-1) .. param_n = access(0); the args list is
--     built by consing arg_n first so the front-to-back list is [a1..an]; @p
--     pops the args-list then the tag symbol -> (tag . argsList).  Nullary
--     ctors are 0-arg thunks (referenced via the existing `m g name p` apply).
--   * TOP-LEVEL GLOBALS are the union of function arities and ctor arities;
--     a ctor-vs-fn or ctor-vs-ctor name collision is a duplicate error.
--   * MULTI-CLAUSE / PATTERN-ARG FUNCTIONS are desugared: functions with the
--     same name are grouped, and any group with >1 clause or a non-variable
--     argument is rewritten (via Lower.Pattern.normalizeClauses) into a single
--     function of fresh variable args whose body is a `case` that re-matches
--     the original patterns.  Single-clause all-variable functions keep the
--     fast path.
--
-- CURRIED PRIM WRAPPERS: the VM prim apply branch is NOT curried, so every
-- binary operator usable as a value or partially applied gets a curried
-- wrapper global.  For a 2-arg prim `<prim>`:
--
--     ( [len:s]<op>.curried ( c ( r  a[1:n]0 a[1:n]1 P[..:s]<prim> v ) ) )
--
-- where access 1 = 1st arg (param1), access 0 = 2nd arg (param2), and the prim
-- pops a1=TOP first, so we push param2 (access 0) then param1 (access 1).
--
-- ARG CONVENTION (RTL): arguments are pushed right-to-left
-- (`m code(an)..code(a1)`), matching the elmvm gate harness which also pushes
-- command-line args RTL.  The VM pops them top-first into argbuf, so argbuf[0]
-- = first source arg (param1) = access(n-1).

import Dict exposing (Dict)
import Elm.Syntax.Declaration as Declaration exposing (Declaration(..))
import Elm.Syntax.Expression as Expression exposing (Expression, Function, FunctionImplementation)
import Elm.Syntax.File as File
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..))
import Elm.Syntax.Range as Range
import Elm.Syntax.Type as Type
import Lower.Expr as Expr
import Lower.Pattern as Pat
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
            collectCtors file.declarations
                |> Result.andThen (\ctors ->
                    case findDuplicate (List.map Tuple.first funs ++ List.map Tuple.first ctors) of
                        Just dup ->
                            Err ("duplicate top-level definition: " ++ dup)

                        Nothing ->
                            let
                                fnGlobals =
                                    buildArityDict funs

                                ctorGlobals =
                                    Dict.fromList ctors

                                -- Union (no collision: findDuplicate caught it above).
                                globals =
                                    Dict.union ctorGlobals fnGlobals

                                baseCtx =
                                    Expr.newContext modName globals

                                fnEntriesResult =
                                    compileFuns baseCtx funs
                            in
                            fnEntriesResult
                                |> Result.map (\fnEntries ->
                                    let
                                        ctorEntries =
                                            List.map (ctorEntry baseCtx) ctors

                                        wrapperEntries =
                                            List.map wrapperEntry Expr.binaryPrims

                                        bundleEntries =
                                            fnEntries ++ ctorEntries ++ wrapperEntries
                                    in
                                    Csexp.list bundleEntries
                                )
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
-- Destructuring declarations are silently skipped here (CustomType ctor defuns
-- are collected separately in collectCtors).
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


-- Collect the value constructors of every CustomTypeDeclaration as
-- (name, arity) pairs.
collectCtors : List (Node Declaration.Declaration) -> Result String (List ( String, Int ))
collectCtors decls =
    List.foldr collectCtorOne (Ok []) decls


collectCtorOne : Node Declaration.Declaration -> Result String (List ( String, Int )) -> Result String (List ( String, Int ))
collectCtorOne node acc =
    case acc of
        Err msg ->
            Err msg

        Ok ctors ->
            case node of
                Node _ (CustomTypeDeclaration typeDecl) ->
                    Ok (List.foldl addCtor ctors typeDecl.constructors)

                _ ->
                    Ok ctors


addCtor : Node Type.ValueConstructor -> List ( String, Int ) -> List ( String, Int )
addCtor node acc =
    case node of
        Node _ vc ->
            ( nodeString vc.name, List.length vc.arguments ) :: acc


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


-- First duplicate name in the (ordered) name list, if any.
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


-- Group flat (name, Function) pairs by name, preserving first-occurrence group
-- order and within-group clause order.  A multi-clause Elm function is parsed
-- as several FunctionDeclarations sharing one name.
groupByName : List ( String, Function ) -> List ( String, List Function )
groupByName pairs =
    case pairs of
        [] ->
            []

        ( name, fn ) :: rest ->
            let
                ( same, others ) =
                    List.partition (\( n, _ ) -> n == name) rest
            in
            ( name, fn :: List.map Tuple.second same ) :: groupByName others


compileFuns : Expr.Context -> List ( String, Function ) -> Result String (List String)
compileFuns baseCtx funs =
    groupByName funs
        |> List.foldl (compileGroup baseCtx) (Ok [])


compileGroup : Expr.Context -> ( String, List Function ) -> Result String (List String) -> Result String (List String)
compileGroup baseCtx ( name, funs ) accResult =
    case accResult of
        Err msg ->
            Err msg

        Ok acc ->
            case compileGroupOne baseCtx name funs of
                Err msg ->
                    Err msg

                Ok entry ->
                    Ok (acc ++ [ entry ])


compileGroupOne : Expr.Context -> String -> List Function -> Result String String
compileGroupOne baseCtx name funs =
    case funs of
        [ single ] ->
            -- Fast path: single-clause, all-variable args.
            if allSimpleVarArgs single then
                compileOne baseCtx name single

            else
                desugarAndCompile baseCtx name funs

        _ ->
            -- Multi-clause function: desugar to a case.
            desugarAndCompile baseCtx name funs


desugarAndCompile : Expr.Context -> String -> List Function -> Result String String
desugarAndCompile baseCtx name funs =
    let
        clauses =
            List.map clauseOf funs
    in
    Pat.normalizeClauses clauses
        |> Result.andThen (\( freshArgNodes, caseNode ) ->
            compileOne baseCtx name (synthesize name freshArgNodes caseNode)
        )


clauseOf : Function -> ( List (Node Pattern.Pattern), Node Expression )
clauseOf fn =
    case fn.declaration of
        Node _ impl ->
            ( impl.arguments, impl.expression )


-- Build a single Function whose declaration carries the given variable args
-- and case body — the normal form normalizeClauses produces.
synthesize : String -> List (Node Pattern.Pattern) -> Node Expression -> Function
synthesize name args body =
    { documentation = Nothing
    , signature = Nothing
    , declaration = Node (Node.range body) (FunctionImplementation (Node Range.empty name) args body)
    }


-- True iff every argument pattern is a variable (possibly parenthesized).
allSimpleVarArgs : Function -> Bool
allSimpleVarArgs fn =
    case fn.declaration of
        Node _ impl ->
            List.all isSimpleVarPattern impl.arguments


isSimpleVarPattern : Node Pattern.Pattern -> Bool
isSimpleVarPattern (Node _ pat) =
    case pat of
        VarPattern _ ->
            True

        ParenthesizedPattern inner ->
            isSimpleVarPattern inner

        _ ->
            False


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


-- A value-constructor defun for a ctor of arity n:
--
--     ( [len:s]<name> ( c ( r^(n-1)  n0 P emptylist  a[0:n]0 P cons ... a[n-1:n]N P cons  s<name> P @p  v ) ) )
--
-- RTL: param1 = access(n-1) .. param_n = access(0).  The args list [a1..an] is
-- built front-to-back by consing arg_n (access 0) first, then arg_{n-1} (access
-- 1), ... so the cons chain is [a1, a2, ...] in source order.  @p pops the
-- args-list then the tag symbol -> (tag . argsList).  Nullary (n=0): no grabs,
-- body `n0 P emptylist s<name> P @p` — a 0-arg thunk (referenced via the
-- existing 0-arity `m g name p` apply path).
ctorEntry : Expr.Context -> ( String, Int ) -> String
ctorEntry _ ( name, n ) =
    let
        grabs =
            List.repeat (n - 1) Emit.Grab

        argsList =
            [ Emit.Number_ 0, Emit.Prim "emptylist" ]
                ++ List.concatMap (\k -> [ Emit.Access k, Emit.Prim "cons" ]) (List.range 0 (n - 1))

        body =
            argsList ++ [ Emit.Symbol name, Emit.Prim "@p" ]

        code =
            [ Emit.Cur (grabs ++ body ++ [ Emit.Return ]) ]
    in
    Csexp.bundleEntry name (Emit.flatten (Emit.resolve code))


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
