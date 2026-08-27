module Lower.Expr exposing
    ( Position(..)
    , Context
    , newContext
    , binaryPrims
    , primWrappers
    , unaryPrims
    , wrapperGlobalName
    , withImport
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
import Elm.Syntax.Expression as Expression exposing (Expression(..), Function, Lambda, LetBlock, LetDeclaration(..), CaseBlock, Case)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..))
import Elm.Syntax.Range as Range exposing (Range)
import Lower.Pattern as Pat
import Lower.Scope as Scope
import Zinc.Emit as Emit exposing (Instr(..), Target(..))


type Position
    = Tail
    | NonTail


type alias Context =
    { moduleName : List String
    , scope : Scope.Scope
    , globals : Dict String Int
    , imports : List ( String, String )
    }


newContext : List String -> Dict String Int -> Context
newContext moduleName globals =
    { moduleName = moduleName
    , scope = Scope.empty
    , globals = globals
    , imports = []
    }


-- Import resolution: a bare name is looked up in the alias table FIRST ( Elm
-- semantics: imports shadow nothing local but win over the "unknown" error —
-- and exposed Prelude names must rewrite to their qualified globals).  The
-- table maps EXPOSED SHORT name -> GLOBAL key as registered by Lower.Module:
--
--   * Prelude entries:  ("map", "Prelude.map"), ("Just", "Prelude.Just") …
--     (the Prelude module compiles under its own name; preludeName prefixes).
--   * User-module entries: ("Aux.f", "Aux.f") for `import Aux` — the user's
--     own module names cannot collide with it because Elm identifiers cannot
--     contain `.`.
withImport : List ( String, String ) -> Context -> Context
withImport imports ctx =
    { ctx | imports = imports }


resolveImport : String -> List ( String, String ) -> Maybe String
resolveImport name imports =
    Maybe.map Tuple.second (listAssoc lookupPair name imports)


lookupPair : String -> ( String, String ) -> Bool
lookupPair a ( b, _ ) =
    a == b


listAssoc : (String -> a -> Bool) -> String -> List a -> Maybe a
listAssoc pred key items =
    case items of
        [] ->
            Nothing

        item :: rest ->
            if pred key item then
                Just item

            else
                listAssoc pred key rest


orElse : (() -> Maybe a) -> Maybe a -> Maybe a
orElse f m =
    case m of
        Just v ->
            Just v

        Nothing ->
            f ()


-- Operator -> VM prim-name table.  Single source of truth for BOTH the inline
-- `P <prim>` fast path and the curried wrapper globals (Lower.Module emits a
-- wrapper entry per row).
binaryPrims : List ( String, String )
binaryPrims =
    [ ( "+", "+" )
    , ( "-", "-" )
    , ( "*", "*" )
    , ( "//", "/" )
    , ( "/", "f/" )
    , ( "==", "=" )
    , ( "<", "<" )
    , ( "<=", "<=" )
    , ( ">", ">" )
    , ( ">=", ">=" )
    ]


wrapperGlobalName : String -> String
wrapperGlobalName op =
    op ++ ".curried"


-- Prims that additionally get a CURRIED WRAPPER usable as a value.
-- Lower.Module emits one `<prim>.curried` wrapper global per row:
--   * primWrappers -> 2-ARG wrapper `(c (r a[1:n]0 a[1:n]1 P<prim> v))`;
--     covers every binary operator plus `cn` (source-order concat).
--   * unaryPrims   -> 1-ARG wrapper `(c (r a[1:n]0 P<prim> v))`; c-strlen
--     pops exactly ONE value, and a 2-arg wrapper would under-apply into a
--     stray partial closure when called full-arity.
primWrappers : List ( String, String )
primWrappers =
    binaryPrims ++ [ ( "", "cn" ) ]


unaryPrims : List String
unaryPrims =
    [ "c-strlen" ]


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

        -- Strings are VM string VALUES (UTF-8 bytes); a Char lowers to its
        -- 1-byte string when it fits Latin-1 (the VM byte-string model),
        -- otherwise to its UTF-8 encoding (String.length counts code points,
        -- byte LENGTHS are handled by utf8ByteLength at emission).
        CharLiteral c ->
            Ok [ String_ (String.fromChar c) ]

        UnitExpr ->
            Ok [ Symbol "()" ]

        Floatable f ->
            Ok [ Float_ f ]

        Negation inner ->
            negation inner ctx

        ParenthesizedExpression inner ->
            lowerExpression inner pos ctx

        FunctionOrValue modName name ->
            functionOrValue modName name ctx

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

        CaseExpression block ->
            lowerCase range block pos ctx

        RecordExpr setters ->
            recordExpr setters ctx

        RecordAccess rec nameNode ->
            recordAccess rec nameNode ctx

        RecordAccessFunction name ->
            recordAccessFunction name ctx

        RecordUpdateExpression baseName updates ->
            recordUpdate baseName updates ctx

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

        Node _ (Floatable f) ->
            Ok [ Float_ (-f) ]

        _ ->
            lowerExpression inner NonTail ctx
                |> Result.map (\code -> code ++ [ Number_ 0, Prim "-" ])


functionOrValue : List String -> String -> Context -> Result String (List Instr)
functionOrValue modName name ctx =
    if not (List.isEmpty modName) then
        -- Qualified reference: resolve over the joined token "Mod.member".
        -- A SELF-qualified ref (Mod == current module) resolves directly;
        -- other dotted tokens go through the unified resolution order (which
        -- tries aliases first, then plain globals-membership).
        if modName == ctx.moduleName then
            resolveGlobal (String.join "." (modName ++ [ name ])) ctx

        else
            resolveName (String.join "." (modName ++ [ name ])) ctx

    else if name == "True" then
        Ok [ Boolean_ True ]

    else if name == "False" then
        Ok [ Boolean_ False ]

    else
        -- Bare name: local scope first, then alias/global resolution.
        case Scope.resolve name ctx.scope of
            Just idx ->
                Ok [ Access idx ]

            Nothing ->
                resolveName name ctx


-- THE UNIFIED NAME RESOLUTION ORDER for a reference token t (bare or dotted):
--
--   1. local scope            (bare names only — handled by callers, but a
--                              dotted token can never be local, so re-check
--                              here is harmless),
--   2. the module's alias table rows EXACTLY (prim-dot conveniences,
--      prelude rows, explicit import-expose rows, self-rows),
--   3. raw globals MEMBERSHIP — makes plain `import Aux` + `Aux.f` work with
--      zero registration; also covers self-qualified refs of foreign modules
--      and bare names that ARE global keys.
--   4. error "unknown name".
resolveName : String -> Context -> Result String (List Instr)
resolveName token ctx =
    case Scope.resolve token ctx.scope of
        Just idx ->
            Ok [ Access idx ]

        Nothing ->
            let
                -- Self-qualified spelling of a BARE token (dotted tokens pass
                -- through unchanged): a module's own names always resolve.
                qualified =
                    String.join "." ctx.moduleName ++ "." ++ token

                -- Resolve a token to its global KEY (alias rows first, then
                -- raw table membership), then emit by the KEY'S OWN ARITY —
                -- mandatory because an alias row hit says nothing about the
                -- target being a 0-arg thunk (apply!) or a closure (load).
                tryTok t =
                    case resolveImport t ctx.imports of
                        Just gkey ->
                            Just (globalRefByKey gkey ctx)

                        Nothing ->
                            if Dict.member t ctx.globals then
                                Just (globalRefByKey t ctx)

                            else
                                Nothing
            in
            case tryTok token of
                Just code ->
                    code

                Nothing ->
                    case tryTok qualified of
                        Just code ->
                            code

                        Nothing ->
                            Err ("unknown name: " ++ token)


-- Emit the VALUE reference for a resolved global key: 0-arity entries are
-- thunks and must be APPLIED; everything else (N-arg closures, prim-wrapper
-- globals) loads directly.
globalRefByKey : String -> Context -> Result String (List Instr)
globalRefByKey name ctx =
    case Dict.get name ctx.globals of
        Just 0 ->
            Ok [ Pushmark, Global name, Apply ]

        _ ->
            Ok [ Global name ]


-- Resolve an (unqualified or qualified-self) name against the top-level global
-- table.  0-arg constants are thunks, so referencing them APPLIES the thunk to
-- obtain the value; N-arg functions are curried closures loaded directly.
resolveGlobal : String -> Context -> Result String (List Instr)
resolveGlobal name ctx =
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

        "::" ->
            -- Cons sugar: `x :: xs` lowers exactly like a 2-arg cons
            -- application (RTL prim args: xs pushed first).
            lowerExpression right NonTail ctx
                |> Result.andThen (\rcode ->
                    lowerExpression left NonTail ctx
                        |> Result.map (\lcode -> rcode ++ lcode ++ [ Prim "cons" ])
                )

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
        Node _ (FunctionOrValue modName name) ->
            calleeFunctionOrValue modName name ctx

        _ ->
            lowerExpression fn NonTail ctx


-- The callee side of name resolution MIRRORS functionOrValue over the joined
-- token (local scope, then alias rows, then globals membership; a
-- current-module qualifier resolves straight against the merged table).
calleeFunctionOrValue : List String -> String -> Context -> Result String (List Instr)
calleeFunctionOrValue modName name ctx =
    if not (List.isEmpty modName) then
        if modName == ctx.moduleName then
            resolveGlobal (String.join "." (modName ++ [ name ])) ctx

        else
            resolveName (String.join "." (modName ++ [ name ])) ctx

    else
        case Scope.resolve name ctx.scope of
            Just idx ->
                Ok [ Access idx ]

            Nothing ->
                resolveName name ctx


lambdaExpr : Lambda -> Context -> Result String (List Instr)
lambdaExpr lambda ctx =
    -- A lambda whose arguments are all simple variables is compiled directly
    -- (fast path).  A PATTERN lambda (\x::xs -> e, \(a,b) -> e, ...) is
    -- desugared by normalizeClauses into a single fresh-variable argument whose
    -- body is a `case` that re-matches the original patterns.
    if List.all isSimpleVarPattern lambda.args then
        emitLambda lambda.args lambda.expression ctx

    else
        Pat.normalizeClauses [ ( lambda.args, lambda.expression ) ]
            |> Result.andThen (\( freshArgs, caseNode ) ->
                emitLambda freshArgs caseNode ctx
            )


emitLambda : List (Node Pattern.Pattern) -> Node Expression -> Context -> Result String (List Instr)
emitLambda argNodes bodyNode ctx =
    patternNames argNodes
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
            lowerExpression bodyNode Tail bodyCtx
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
        |> Result.andThen (\(bcode, finalCtx, slots) ->
            lowerExpression block.expression pos finalCtx
                |> Result.map (\bodyCode ->
                    let
                        endlets =
                            if pos == NonTail then
                                List.repeat slots Endlet

                            else
                                []
                    in
                    bcode ++ bodyCode ++ endlets
                )
        )


-- bindAll : lower each declaration, threading the scope; returns the emitted
-- code, the final context, and the NUMBER OF LET_ SLOTS pushed (used to emit
-- the matching Endlets in NonTail).  A variable destructuring pushes 1 slot; a
-- complex destructuring pushes 1 (scrutinee temp) + k (pattern bindings).
bindAll : List (Node LetDeclaration) -> Context -> Result String ( List Instr, Context, Int )
bindAll decls ctx =
    case decls of
        [] ->
            Ok ( [], ctx, 0 )

        d :: rest ->
            bindOne d ctx
                |> Result.andThen (\(code, newCtx, slots) ->
                    bindAll rest newCtx
                        |> Result.map (\(codes, finalCtx, moreSlots) -> ( code ++ codes, finalCtx, slots + moreSlots ))
                )


bindOne : Node LetDeclaration -> Context -> Result String ( List Instr, Context, Int )
bindOne (Node _ decl) ctx =
    case decl of
        LetDestructuring patNode eNode ->
            -- A let-destructuring to a VARIABLE is a plain binding.  A
            -- let-destructuring to a COMPLEX pattern (`let (a,b) = e in ...`)
            -- is desugared into a case over the value (see bindDestructuring).
            if isSimpleVarPattern patNode then
                patternName patNode
                    |> Result.andThen (\name ->
                        lowerExpression eNode NonTail ctx
                            |> Result.map (\code -> ( code ++ [ Let_ ], { ctx | scope = Scope.push name ctx.scope }, 1 ))
                    )

            else
                bindDestructuring patNode eNode ctx

        LetFunction fn ->
            lowerLetFunction fn ctx


-- Desugar a complex-pattern let-binding (`let (a,b) = e in ...`) into a case:
--
--     let $t = e in case $t of (a,b) -> <rest>
--
-- We push ONE scrutinee temp slot (named "$case", never resolved by name), then
-- the pattern's tests + bindings (each binding Let_s one slot, reading the
-- scrutinee at the running slot index).  The failure path throws (Elm requires
-- exhaustive let patterns).  The block.expression runs AFTER these bindings
-- (compiled by letExpr with the returned body scope), and letExpr emits the
-- matching Endlets (1 temp + k bindings) via the returned slot count.
bindDestructuring : Node Pattern.Pattern -> Node Expression -> Context -> Result String ( List Instr, Context, Int )
bindDestructuring patNode eNode ctx =
    lowerExpression eNode NonTail ctx
        |> Result.andThen (\code ->
            Pat.compilePattern ctx.moduleName patNode
                |> Result.andThen (\{ tests, bindings } ->
                    let
                        scrutCtx =
                            { ctx | scope = Scope.push "$case" ctx.scope }

                        slots =
                            1 + List.length bindings
                    in
                    compileBindings bindings 0
                        |> Result.andThen (\(bindCode, boundNames) ->
                            let
                                bodyScope =
                                    List.foldl Scope.push scrutCtx.scope boundNames
                            in
                            Ok
                                ( code
                                    ++ [ Let_ ]
                                    ++ List.concatMap (\t -> t ++ [ Jmpf (TRef "let_bad") ]) tests
                                    ++ [ Jmp (TRef "let_ok") ]
                                    ++ [ Label_ "let_bad", String_ "non-exhaustive let pattern", Prim "simple-error" ]
                                    ++ [ Label_ "let_ok" ]
                                    ++ bindCode
                                , { ctx | scope = bodyScope }
                                , slots
                                )
                        )
                )
        )


lowerLetFunction : Function -> Context -> Result String ( List Instr, Context, Int )
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
                    |> Result.map (\code -> ( code ++ [ Let_ ], { ctx | scope = Scope.push name ctx.scope }, 1 ))

            else if List.all isSimpleVarPattern impl.arguments then
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
                                , 1
                                )
                            )
                    )

            else
                -- A let-function with PATTERN arguments desugars to a
                -- single-fresh-arg lambda whose body is a case (via
                -- emitLambda), then binds the function name as usual.
                Pat.normalizeClauses [ ( impl.arguments, impl.expression ) ]
                    |> Result.andThen (\( freshArgs, caseNode ) ->
                        emitLambda freshArgs caseNode ctx
                            |> Result.map (\code -> ( code ++ [ Let_ ], { ctx | scope = Scope.push name ctx.scope }, 1 ))
                    )


-- CASE LOWERING (M2).  `case scrutinee of clauses`.
--
-- Emission:
--     code(scrutinee) e <clause0> <clause1> ... S"non-exhaustive case" P simple-error Lend [d]
--
-- The scrutinee is pushed into ONE Let_ temp slot, named "$case" (contains `$`,
-- illegal in Elm ids, so nested-case shadowing is harmless).  It is never
-- resolved BY NAME — only by index — so the name is just a constant.  Each
-- clause is: its pattern tests (source-order, first-match-wins via Jmpf
-- fallthrough to the next clause), then its bindings (each pushed with Let_,
-- reading the scrutinee temp via the running slot index), then the body.
--
-- ENDLET BALANCE (NonTail): per taken branch there are 1 (temp) + k_i
-- (bindings) Let_s, so we emit exactly k_i Endlets right after that clause's
-- body (before its Jmp endLabel) plus ONE trailing Endlet after endLabel for
-- the temp.  In Tail position we emit ZERO Endlets: the appterm/tail-call frame
-- reuse discards the temp + bindings naturally.  Clause bodies inherit `pos`,
-- so a genuine tail call in a clause body emits Appterm.
lowerCase : Range -> CaseBlock -> Position -> Context -> Result String (List Instr)
lowerCase range block pos ctx =
    let
        endLabel =
            label range "case_end"

        scrutCtx =
            { ctx | scope = Scope.push "$case" ctx.scope }
    in
    lowerExpression block.expression NonTail ctx
        |> Result.andThen (\scrutCode ->
            lowerClauses range (List.indexedMap Tuple.pair block.cases) endLabel pos scrutCtx
                |> Result.map (\clauseCodes ->
                    scrutCode
                        ++ [ Let_ ]
                        ++ List.concat clauseCodes
                        ++ [ String_ "non-exhaustive case", Prim "simple-error", Label_ endLabel ]
                        ++ (if pos == NonTail then [ Endlet ] else [])
                )
        )


lowerClauses : Range -> List ( Int, Case ) -> String -> Position -> Context -> Result String (List (List Instr))
lowerClauses caseRange indexed endLabel pos scrutCtx =
    case indexed of
        [] ->
            Ok []

        ( i, clause ) :: rest ->
            lowerClause caseRange i clause endLabel pos scrutCtx
                |> Result.andThen (\code ->
                    lowerClauses caseRange rest endLabel pos scrutCtx
                        |> Result.map (\codes -> code :: codes)
                )


lowerClause : Range -> Int -> Case -> String -> Position -> Context -> Result String (List Instr)
lowerClause caseRange i ( patNode, bodyNode ) endLabel pos scrutCtx =
    let
        nextLabel =
            labelIndex caseRange "case_next" i
    in
    Pat.compilePattern scrutCtx.moduleName patNode
        |> Result.andThen (\{ tests, bindings } ->
            let
                testCode =
                    -- Each test fails -> jump to the next clause.
                    List.concatMap (\t -> t ++ [ Jmpf (TRef nextLabel) ]) tests
            in
            compileBindings bindings 0
                |> Result.andThen (\(bindCode, boundNames) ->
                    let
                        bodyScope =
                            List.foldl Scope.push scrutCtx.scope boundNames

                        bodyCtx =
                            { scrutCtx | scope = bodyScope }
                    in
                    lowerExpression bodyNode pos bodyCtx
                        |> Result.map (\body ->
                            testCode
                                ++ bindCode
                                ++ body
                                ++ (if pos == NonTail then List.repeat (List.length boundNames) Endlet else [])
                                ++ [ Jmp (TRef endLabel), Label_ nextLabel ]
                        )
                )
        )


-- Compile the pattern bindings: each binding k reads the scrutinee temp at
-- slot k (each prior binding's Let_ pushed one slot), then pushes the bound
-- value with its own Let_.  Returns (bindCode, boundNames in emission order).
compileBindings : List Pat.Binding -> Int -> Result String ( List Instr, List String )
compileBindings bindings idx =
    case bindings of
        [] ->
            Ok ( [], [] )

        ( name, path ) :: rest ->
            compileBindings rest (idx + 1)
                |> Result.map (\(restCode, restNames) ->
                    ( Pat.pathInstrs path idx ++ [ Let_ ] ++ restCode
                    , name :: restNames
                    )
                )


-- RECORDS (M2): an assoc list of (fieldSymbol, value) cons pairs, built
-- right-to-left so field j (source order) sits at head.
--
--   * construct `{f=e, g=h}`  -> n0 P emptylist, then per setter in REVERSE
--     source order: code(e); Symbol f; P @p; P cons   (pair = @p of (f,e);
--     cons prepends it onto the running assoc list).
--   * access  `r.f`           -> code(r); Symbol f; P assoc; P snd
--     (assoc pops key=LAST-pushed then list=FIRST-pushed; returns the matched
--     PAIR, so snd extracts the value).
--   * accessor `.f`           -> a 1-arg lambda \r -> r.f.
--   * update  `{r | f=v}`     -> code(r); then per setter: code(v); Symbol f;
--     P @p; P cons  (PREPEND-SHADOW: cons the new (f,v) pair onto r; assoc's
--     first-match-wins makes it shadow any older same-field pair).
recordExpr : List (Node Expression.RecordSetter) -> Context -> Result String (List Instr)
recordExpr setters ctx =
    List.foldl
        (\setter acc ->
            setterCode setter ctx
                |> Result.andThen (\code -> acc |> Result.map (\codes -> codes ++ code))
        )
        (Ok [ Number_ 0, Prim "emptylist" ])
        (List.reverse setters)


setterCode : Node Expression.RecordSetter -> Context -> Result String (List Instr)
setterCode (Node _ ( fieldNode, valNode )) ctx =
    lowerExpression valNode NonTail ctx
        |> Result.map (\code -> code ++ [ Symbol (nodeString fieldNode), Prim "@p", Prim "cons" ])


recordAccess : Node Expression -> Node String -> Context -> Result String (List Instr)
recordAccess rec nameNode ctx =
    lowerExpression rec NonTail ctx
        |> Result.map (\code -> code ++ [ Symbol (nodeString nameNode), Prim "assoc", Prim "snd" ])


recordAccessFunction : String -> Context -> Result String (List Instr)
recordAccessFunction name _ =
    Ok [ Cur (Grab :: [ Access 0, Symbol name, Prim "assoc", Prim "snd" ] ++ [ Return ]) ]


recordUpdate : Node String -> List (Node Expression.RecordSetter) -> Context -> Result String (List Instr)
recordUpdate baseNode updates ctx =
    let
        baseName =
            nodeString baseNode
    in
    resolveBaseRecord baseName ctx
        |> Result.andThen (\baseCode ->
            List.foldl
                (\setter acc ->
                    setterCode setter ctx
                        |> Result.andThen (\code -> acc |> Result.map (\codes -> codes ++ code))
                )
                (Ok baseCode)
                updates
        )


-- The base record of an update is a local variable (Elm requires `{r | ...}`
-- where r is a name).  It cannot be a module global (Elm's type system forbids
-- updating a module-level value), so a global here is a compile error.
resolveBaseRecord : String -> Context -> Result String (List Instr)
resolveBaseRecord name ctx =
    case Scope.resolve name ctx.scope of
        Just idx ->
            Ok [ Access idx ]

        Nothing ->
            Err ("record update base must be a local variable: " ++ name)


labelIndex : Range -> String -> Int -> String
labelIndex range tag i =
    label range tag ++ "_" ++ String.fromInt i


listExpr : List (Node Expression) -> Context -> Result String (List Instr)
listExpr es ctx =
    buildList es ctx
        |> Result.map (\codes -> [ Number_ 0, Prim "emptylist" ] ++ codes)
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


isSimpleVarPattern : Node Pattern.Pattern -> Bool
isSimpleVarPattern (Node _ pat) =
    case pat of
        VarPattern _ ->
            True

        ParenthesizedPattern inner ->
            isSimpleVarPattern inner

        _ ->
            False


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
