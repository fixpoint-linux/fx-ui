module Lower.Expr exposing
    ( Position(..)
    , Context
    , newContext
    , binaryPrims
    , wrapperGlobalName
    , lowerExpression
    )

-- M1b core expression lowering for the Elm -> ZINC-csexp compiler.
--
-- `lowerExpression` walks the elm-syntax Expression AST and emits flat ZINC
-- bytecode (Zinc.Emit.Instr).  It threads a `Position` context (Tail | NonTail)
-- exactly like the C VM's zinc-c / zinc-t: an application in a genuine tail
-- position compiles to `t` (appterm), everywhere else to `p` (apply); a let in
-- non-tail emits its `d` endlet, in tail position it omits it (the tail call /
-- frame pop discards the bindings naturally).
--
-- KEY EMISSION RULES (from the plan's MODEL EMISSION + REVISION):
--   * binop  `lhs OP rhs`   -> code(rhs) code(lhs) P <prim>   (RTL prim args)
--   * call   `f a1..an`      -> m code(an)..code(a1) code(f) p|t  (RTL args;
--     VM pops top-first so argbuf[0] = param1 = first source arg = access(n-1))
--   * let    x = e1 in e2    -> code(e1) e code(e2) [d]
--   * if     c t e           -> code(c) f Lf code(t) j Le Lf: code(e) Le:
--   * list   [a,b,c]         -> n0 P emptylist code(c) P cons code(b) P cons
--                                code(a) P cons
--   * tuple  (a,b)           -> code(b) code(a) P @p
--   * neg    -lit            -> Number_ (-lit); -e -> code(e) n0 P -
--   * ==     -> P = ; /=     -> inline not; && / || -> short-circuit if
--   * 0-arg  const ref       -> m g name p   (apply the thunk to get its value)
--   * N-arg  fn as a value   -> g name       (load the closure)
--
-- PRIMITIVE CURRYING: the VM prim apply branch is NOT curried, so any operator
-- used as a value or partially applied must route through a CURRIED WRAPPER
-- GLOBAL (see Lower.Module for the wrapper bundle entries).  Here
-- `operatorValue`/`PrefixOperator`/`Operator` resolve to the wrapper global
-- (e.g. "+.curried"); direct `lhs OP rhs` operator application keeps the
-- inline full-arity `P <prim>` fast path.

import Dict exposing (Dict)
import Elm.Syntax.Expression as Expression exposing (Expression(..), Function, Lambda, LetBlock, LetDeclaration(..))
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..))
import Elm.Syntax.Range as Range exposing (Range)
import Lower.Scope as Scope
import Zinc.Emit as Emit exposing (Instr(..), Target(..))


type Position
    = Tail
    | NonTail


type alias Context =
    { scope : Scope.Scope
    , globals : Dict String Int
    }


newContext : Dict String Int -> Context
newContext globals =
    { scope = Scope.empty
    , globals = globals
    }


-- Operator -> VM prim-name table.  Single source of truth for BOTH the inline
-- `P <prim>` fast path and the curried wrapper globals (Lower.Module emits a
-- wrapper entry per row).
binaryPrims : List ( String, String )
binaryPrims =
    [ ( "+", "+" )
    , ( "-", "-" )
    , ( "*", "*" )
    , ( "//", "/" )
    , ( "==", "=" )
    , ( "<", "<" )
    , ( "<=", "<=" )
    , ( ">", ">" )
    , ( ">=", ">=" )
    ]


wrapperGlobalName : String -> String
wrapperGlobalName op =
    op ++ ".curried"


primOf : String -> Maybe String
primOf op =
    List.filterMap
        (\(o, p) -> if o == op then Just p else Nothing)
        binaryPrims
        |> List.head


primWrapperName : String -> Maybe String
primWrapperName op =
    if List.any (\(o, _) -> o == op) binaryPrims then
        Just (wrapperGlobalName op)

    else
        Nothing


lowerExpression : Node Expression -> Position -> Context -> Result String (List Instr)
lowerExpression (Node range expr) pos ctx =
    case expr of
        Integer n ->
            Ok [ Number_ n ]

        Hex n ->
            Ok [ Number_ n ]

        Literal str ->
            Ok [ String_ str ]

        CharLiteral c ->
            Ok [ String_ (String.fromChar c) ]

        Floatable _ ->
            Err "floats are not supported in the M1b subset"

        Negation inner ->
            negation inner ctx

        ParenthesizedExpression inner ->
            lowerExpression inner pos ctx

        FunctionOrValue _ name ->
            functionOrValue name ctx

        PrefixOperator op ->
            operatorValue op ctx

        Operator op ->
            operatorValue op ctx

        OperatorApplication op _ left right ->
            operatorApplication range op left right ctx

        Application es ->
            application es pos ctx

        IfBlock c t e ->
            ifBlock range c t e pos ctx

        LambdaExpression lambda ->
            lambdaExpr lambda ctx

        LetExpression block ->
            letExpr block pos ctx

        ListExpr es ->
            listExpr es ctx

        TupledExpression es ->
            tupledExpr es ctx

        _ ->
            Err "unsupported expression in the M1b subset (case/records/ADTs are M2)"


negation : Node Expression -> Context -> Result String (List Instr)
negation inner ctx =
    case inner of
        Node _ (Integer n) ->
            Ok [ Number_ (-n) ]

        Node _ (Hex n) ->
            Ok [ Number_ (-n) ]

        _ ->
            lowerExpression inner NonTail ctx
                |> Result.map (\code -> code ++ [ Number_ 0, Prim "-" ])


functionOrValue : String -> Context -> Result String (List Instr)
functionOrValue name ctx =
    if name == "True" then
        Ok [ Boolean_ True ]

    else if name == "False" then
        Ok [ Boolean_ False ]

    else
        case Scope.resolve name ctx.scope of
            Just idx ->
                Ok [ Access idx ]

            Nothing ->
                case Dict.get name ctx.globals of
                    Just 0 ->
                        -- 0-arg top-level constant: apply the thunk to get its value.
                        Ok [ Pushmark, Global name, Apply ]

                    Just _ ->
                        -- N-arg function used as a value: load the closure.
                        Ok [ Global name ]

                    Nothing ->
                        Err ("unknown name: " ++ name)


operatorValue : String -> Context -> Result String (List Instr)
operatorValue op _ =
    case primWrapperName op of
        Just wname ->
            Ok [ Global wname ]

        Nothing ->
            Err ("unsupported operator used as a value: " ++ op)


operatorApplication : Range -> String -> Node Expression -> Node Expression -> Context -> Result String (List Instr)
operatorApplication range op left right ctx =
    case op of
        "&&" ->
            andShort range left right ctx

        "||" ->
            orShort range left right ctx

        "/=" ->
            notEqual range left right ctx

        _ ->
            case primOf op of
                Just pname ->
                    lowerExpression right NonTail ctx
                        |> Result.andThen (\rcode ->
                            lowerExpression left NonTail ctx
                                |> Result.map (\lcode -> rcode ++ lcode ++ [ Prim pname ])
                        )

                Nothing ->
                    Err ("unsupported operator: " ++ op)


andShort : Range -> Node Expression -> Node Expression -> Context -> Result String (List Instr)
andShort range left right ctx =
    let
        lfalse =
            label range "and_false"

        lend =
            label range "and_end"
    in
    lowerExpression left NonTail ctx
        |> Result.andThen (\lcode ->
            lowerExpression right NonTail ctx
                |> Result.map (\rcode ->
                    lcode
                        ++ [ Jmpf (TRef lfalse) ]
                        ++ rcode
                        ++ [ Jmp (TRef lend) ]
                        ++ [ Label_ lfalse, Boolean_ False, Label_ lend ]
                )
        )


orShort : Range -> Node Expression -> Node Expression -> Context -> Result String (List Instr)
orShort range left right ctx =
    let
        lfalse =
            label range "or_false"

        lend =
            label range "or_end"
    in
    lowerExpression left NonTail ctx
        |> Result.andThen (\lcode ->
            lowerExpression right NonTail ctx
                |> Result.map (\rcode ->
                    lcode
                        ++ [ Jmpf (TRef lfalse) ]
                        ++ [ Boolean_ True, Jmp (TRef lend) ]
                        ++ [ Label_ lfalse ]
                        ++ rcode
                        ++ [ Label_ lend ]
                )
        )


notEqual : Range -> Node Expression -> Node Expression -> Context -> Result String (List Instr)
notEqual range left right ctx =
    let
        lfalse =
            label range "ne_false"

        lend =
            label range "ne_end"
    in
    lowerExpression right NonTail ctx
        |> Result.andThen (\rcode ->
            lowerExpression left NonTail ctx
                |> Result.map (\lcode ->
                    rcode
                        ++ lcode
                        ++ [ Prim "=" ]
                        ++ [ Jmpf (TRef lfalse), Boolean_ False, Jmp (TRef lend) ]
                        ++ [ Label_ lfalse, Boolean_ True, Label_ lend ]
                )
        )


ifBlock : Range -> Node Expression -> Node Expression -> Node Expression -> Position -> Context -> Result String (List Instr)
ifBlock range cond thenExpr elseExpr pos ctx =
    let
        lfalse =
            label range "if_false"

        lend =
            label range "if_end"
    in
    lowerExpression cond NonTail ctx
        |> Result.andThen (\ccode ->
            lowerExpression thenExpr pos ctx
                |> Result.andThen (\tcode ->
                    lowerExpression elseExpr pos ctx
                        |> Result.map (\ecode ->
                            ccode
                                ++ [ Jmpf (TRef lfalse) ]
                                ++ tcode
                                ++ [ Jmp (TRef lend) ]
                                ++ [ Label_ lfalse ]
                                ++ ecode
                                ++ [ Label_ lend ]
                        )
                )
        )


application : List (Node Expression) -> Position -> Context -> Result String (List Instr)
application es pos ctx =
    case es of
        [] ->
            Err "empty application"

        fn :: args ->
            let
                applyInstr =
                    case pos of
                        Tail ->
                            Appterm

                        NonTail ->
                            Apply
            in
            -- Args are emitted in REVERSE (right-to-left) order, i.e.
            -- `m code(an)..code(a1) code(f) p|t`.  The VM's apply pops them
            -- into argbuf top-first so the LAST-pushed arg lands in argbuf[0]
            -- = param1 (first source arg).  lambda/function scope pushes
            -- param1 first (deepest slot), so param_i = access(n-i): param1 =
            -- access(n-1).
            lowerArgs args ctx
                |> Result.andThen (\argCodeLists ->
                    calleeCode fn ctx
                        |> Result.map (\fcode ->
                            Pushmark :: (List.concat (List.reverse argCodeLists) ++ fcode ++ [ applyInstr ])
                        )
                )


-- Lower each argument expression to its own list of instructions, preserving
-- source order.  `application` reverses the *list of per-arg code lists* (not
-- the flat instruction stream) so each argument's internal code stays intact.
lowerArgs : List (Node Expression) -> Context -> Result String (List (List Instr))
lowerArgs exprs ctx =
    case exprs of
        [] ->
            Ok []

        e :: rest ->
            lowerExpression e NonTail ctx
                |> Result.andThen (\code ->
                    lowerArgs rest ctx
                        |> Result.map (\codes -> code :: codes)
                )


calleeCode : Node Expression -> Context -> Result String (List Instr)
calleeCode fn ctx =
    case fn of
        Node _ (FunctionOrValue _ name) ->
            case Scope.resolve name ctx.scope of
                Just idx ->
                    Ok [ Access idx ]

                Nothing ->
                    case Dict.get name ctx.globals of
                        -- A 0-arg const used as a callee: first get its value
                        -- (the thunk returns e.g. a partial/closure), the
                        -- surrounding apply then feeds the args to that value.
                        Just 0 ->
                            Ok [ Pushmark, Global name, Apply ]

                        _ ->
                            Ok [ Global name ]

        _ ->
            lowerExpression fn NonTail ctx


lambdaExpr : Lambda -> Context -> Result String (List Instr)
lambdaExpr lambda ctx =
    patternNames lambda.args
        |> Result.andThen (\argNames ->
            let
                -- RTL arg convention: push param1 FIRST so it lands at the
                -- deepest slot access(n-1).  Scope.push adds to the front, so
                -- pushing argNames in source order gives param1 = access(n-1),
                -- param2 = access(n-2), ..., param_n = access(0).
                bodyScope =
                    List.foldl Scope.push ctx.scope argNames

                bodyCtx =
                    { ctx | scope = bodyScope }
            in
            lowerExpression lambda.expression Tail bodyCtx
                |> Result.map (\body ->
                    let
                        grabs =
                            List.repeat (List.length argNames - 1) Grab
                    in
                    [ Cur (grabs ++ body ++ [ Return ]) ]
                )
        )


letExpr : LetBlock -> Position -> Context -> Result String (List Instr)
letExpr block pos ctx =
    bindAll block.declarations ctx
        |> Result.andThen (\(bcode, finalCtx) ->
            lowerExpression block.expression pos finalCtx
                |> Result.map (\bodyCode ->
                    let
                        endlets =
                            if pos == NonTail then
                                List.repeat (List.length block.declarations) Endlet

                            else
                                []
                    in
                    bcode ++ bodyCode ++ endlets
                )
        )


bindAll : List (Node LetDeclaration) -> Context -> Result String ( List Instr, Context )
bindAll decls ctx =
    case decls of
        [] ->
            Ok ( [], ctx )

        d :: rest ->
            bindOne d ctx
                |> Result.andThen (\(code, newCtx) ->
                    bindAll rest newCtx
                        |> Result.map (\(codes, finalCtx) -> ( code ++ codes, finalCtx ))
                )


bindOne : Node LetDeclaration -> Context -> Result String ( List Instr, Context )
bindOne (Node _ decl) ctx =
    case decl of
        LetDestructuring patNode eNode ->
            patternName patNode
                |> Result.andThen (\name ->
                    lowerExpression eNode NonTail ctx
                        |> Result.map (\code -> ( code ++ [ Let_ ], { ctx | scope = Scope.push name ctx.scope } ))
                )

        LetFunction fn ->
            lowerLetFunction fn ctx


lowerLetFunction : Function -> Context -> Result String ( List Instr, Context )
lowerLetFunction fn ctx =
    case fn.declaration of
        Node _ impl ->
            let
                name =
                    nodeString impl.name
            in
            if List.isEmpty impl.arguments then
                -- elm-syntax parses `let a = <value> in ...` as a 0-arg
                -- LetFunction.  That is a VALUE binding (like a const), so bind
                -- the evaluated value directly (no Cur); references to `a` in
                -- the body then Access the value.
                lowerExpression impl.expression NonTail ctx
                    |> Result.map (\code -> ( code ++ [ Let_ ], { ctx | scope = Scope.push name ctx.scope } ))

            else
                patternNames impl.arguments
                    |> Result.andThen (\argNames ->
                        let
                            bodyScope =
                                List.foldl Scope.push ctx.scope argNames

                            bodyCtx =
                                { ctx | scope = bodyScope }
                        in
                        lowerExpression impl.expression Tail bodyCtx
                            |> Result.map (\body ->
                                let
                                    grabs =
                                        List.repeat (List.length argNames - 1) Grab
                                in
                                ( [ Cur (grabs ++ body ++ [ Return ]), Let_ ]
                                , { ctx | scope = Scope.push name ctx.scope }
                                )
                            )
                    )


listExpr : List (Node Expression) -> Context -> Result String (List Instr)
listExpr es ctx =
    buildList es ctx
        |> Result.map (\codes -> [ Number_ 0, Prim "emptylist" ] ++ codes)


buildList : List (Node Expression) -> Context -> Result String (List Instr)
buildList es ctx =
    case es of
        [] ->
            Ok []

        e :: rest ->
            buildList rest ctx
                |> Result.andThen (\codes ->
                    lowerExpression e NonTail ctx
                        |> Result.map (\code -> codes ++ code ++ [ Prim "cons" ])
                )


tupledExpr : List (Node Expression) -> Context -> Result String (List Instr)
tupledExpr es ctx =
    case es of
        [] ->
            Err "empty tuple"

        [ _ ] ->
            Err "single-element tuple"

        _ ->
            tupleCode es ctx


tupleCode : List (Node Expression) -> Context -> Result String (List Instr)
tupleCode es ctx =
    case es of
        [ a, b ] ->
            lowerExpression b NonTail ctx
                |> Result.andThen (\bcode ->
                    lowerExpression a NonTail ctx
                        |> Result.map (\acode -> bcode ++ acode ++ [ Prim "@p" ])
                )

        a :: rest ->
            tupleCode rest ctx
                |> Result.andThen (\restCode ->
                    lowerExpression a NonTail ctx
                        |> Result.map (\acode -> restCode ++ acode ++ [ Prim "@p" ])
                )

        [] ->
            Err "empty tuple"


label : Range -> String -> String
label range tag =
    tag ++ "_" ++ String.fromInt range.start.row ++ "_" ++ String.fromInt range.start.column


patternNames : List (Node Pattern.Pattern) -> Result String (List String)
patternNames nodes =
    case nodes of
        [] ->
            Ok []

        n :: rest ->
            Result.map2 (::) (patternName n) (patternNames rest)


patternName : Node Pattern.Pattern -> Result String String
patternName (Node _ pat) =
    patName pat


patName : Pattern.Pattern -> Result String String
patName pat =
    case pat of
        VarPattern name ->
            Ok name

        ParenthesizedPattern (Node _ inner) ->
            patName inner

        _ ->
            Err "M1b supports only variable patterns (destructuring is M2)"


nodeString : Node String -> String
nodeString (Node _ s) =
    s
