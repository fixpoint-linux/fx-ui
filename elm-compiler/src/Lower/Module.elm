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
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..))
import Lower.Expr as Expr
import Lower.Scope as Scope
import Zinc.Csexp as Csexp
import Zinc.Emit as Emit exposing (Instr(..))


compile : File.File -> Result String String
compile file =
    let
        funs =
            List.filterMap asFunction file.declarations

        globals =
            Dict.fromList (List.map (\(name, _) -> ( name, arityOf name funs )) funs)

        -- Build the base context once; each function entry gets its own scope.
        baseCtx =
            Expr.newContext globals

        entryResult =
            List.foldl (compileEntry baseCtx) (Ok []) funs
    in
    case entryResult of
        Err msg ->
            Err msg

        Ok entries ->
            let
                wrapperEntries =
                    List.map wrapperEntry Expr.binaryPrims

                bundleEntries =
                    entries ++ wrapperEntries
            in
            Ok (Csexp.list bundleEntries)


asFunction : Node Declaration.Declaration -> Maybe ( String, Function )
asFunction (Node _ decl) =
    case decl of
        FunctionDeclaration fn ->
            case fn.declaration of
                Node _ impl ->
                    Just ( nodeString impl.name, fn )

        _ ->
            Nothing


arityOf : String -> List ( String, Function ) -> Int
arityOf name funs =
    case List.head (List.filter (\(n, _) -> n == name) funs) of
        Just ( _, fn ) ->
            functionArity fn

        Nothing ->
            0


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
