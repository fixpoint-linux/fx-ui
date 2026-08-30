module Lower.Module exposing
    ( compileSources
    , compileBatch
    )

-- M1b/M1c/M2/M3 module lowering: turn PARSED Elm source(s) into a ZINC-csexp
-- BUNDLE.
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
-- M2 ADDITIONS:
--   * CustomTypeDeclaration ctor DEFUNS.  Each value constructor (name, arity
--     n) becomes a bundle entry whose body builds a vector[tag, a1..an]
--     (absvector + address->, the MX ADT rep).
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
-- where access 1 = param1, access 0 = param2; the prim pops a1=TOP first, so
-- we push param2 (access 0) then param1 (access 1).
--
-- ARG CONVENTION (RTL): arguments are pushed right-to-left; param_i =
-- access(n-i).
--
-- ============================================================
--  M3 ADDITIONS: QUALIFIED KEYS + THE ALIAS TABLE + PRELUDE
-- ============================================================
--
-- QUALIFIED GLOBAL KEYS.  Every function/constructor defun is keyed under its
-- FULLY QUALIFIED dotted name "<Module>.<member>" (e.g. "Main.fib",
-- "Prelude.map").  Name resolution (Lower.Expr) is ONE uniform rule over the
-- joined token "Mod.member" (bare names are the empty module case):
--
--     local scope  ->  alias table  ->  globals membership  ->  error
--
-- The globals-membership step makes PLAIN `import Aux` (no exposing clause)
-- work with ZERO registration: a qualified reference Aux.f simply checks
-- whether "Aux.f" is in the merged table.
--
-- THE ALIAS TABLE (ctx.imports : List (token, globalKey)) replaces plan §6's
-- generated-defun alias shims with pure compile-time rewriting — no alias
-- defuns exist.  Rows come from four sources, built per module:
--   1. PRIM DOT ALIASES: String.append -> "cn.curried", String.length ->
--      "c-strlen.curried", String.sliceLen -> "substring.curried" — dotted
--      conveniences backed DIRECTLY by curried prim wrappers (sliceLen is
--      (start, LEN, str), NOT real Elm's (start, end) slice).
--   2. PRELUDE ALIASES: the implicit `import Prelude exposing (..)` present
--      in every module except the Prelude compilation itself (where they
--      would self-shadow the definitions being lowered).
--   3. USER IMPORTS: `import X exposing (a, T)` contributes bare-token rows
--      x -> "X.a".  `exposing (..)` from a user module cannot be enumerated
--      without a cross-module pass — use dotted refs or explicit lists
--      (documented minimal-M3 limitation).
--   4. SELF ROWS: a module's OWN exposed names map bare token -> qualified
--      key (so the MAIN fixture regime keeps working after qualification).
--
-- MERGED VIEW / MULTI-SOURCE PIPELINE.  compile takes the LIST of sources;
-- every module is parsed, all qualified arity tables are UNIONED, and each
-- module is then lowered against the merged view (plus its own alias rows).
-- Qualified keys are globally unique, so the union cannot collide; the
-- per-module duplicate check keeps single-module hygiene.  The VM side
-- tolerates repeated bundle keys anyway (tables.defunSet: later store wins)
-- because identical prim-wrapper entries are emitted once per compilation
-- unit (dedupe-by-overwrite).
--
-- PRELUDE AUTO-INJECTION lives in run.js/Main (sources ++ [preludeSource]) —
-- here the Prelude is simply the last module in the list.  Gate runners find
-- the entry function under its qualified key ("<Fix>.main").
--
-- DOTTED SYMBOLS ARE VM-SAFE: symbol atoms carry byte-length-prefixed RAW
-- bytes (src/vm/parser.zig parseCsexpAtom) — "Prelude.map"/"cn.curried"
-- intern as ordinary symbols, and defunGet compares raw bytes.

import Dict exposing (Dict)
import Elm.Syntax.Declaration as Declaration exposing (Declaration(..))
import Elm.Syntax.Expression as Expression exposing (Expression, Function, FunctionImplementation)
import Elm.Syntax.File as File
import Elm.Parser
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..))
import Elm.Syntax.Range as Range
import Elm.Syntax.Type as Type
import Lower.Expr as Expr
import Lower.Pattern as Pat
import Lower.Resolve as Resolve
import Lower.Scope as Scope
import Type.Check as Check
import Type.Env as Env exposing (Env)
import Zinc.Csexp as Csexp
import Zinc.Emit as Emit exposing (Instr(..))



-- ============================ TOP-LEVEL API ============================
-- compileSources : parse all sources, merge, lower each module, concatenate
-- the per-module bundles into ONE bundle text.


compileSources : List String -> Result String String
compileSources sources =
    parseAll sources
        |> Result.andThen
            (\files ->
                collectAll files
                    |> Result.andThen
                        (\units ->
                            -- S6: typecheck every unit (in dependency order),
                            -- returning the CHECKER-REWRITTEN files; lowering
                            -- then proceeds unchanged over those files.
                            Check.checkUnits (List.map .file units)
                                |> Result.andThen
                                    (\checkedFiles ->
                                        collectAll checkedFiles
                                            |> Result.andThen
                                                (\checkedUnits ->
                                                    case mergedGlobals checkedUnits of
                                                        Err msg ->
                                                            Err msg

                                                        Ok globals ->
                                                            -- Per-unit lowering against the MERGED
                                                            -- table; concatenation preserves any
                                                            -- order (keys are globally unique).
                                                            sequenceMaps (List.map (compileUnit globals) checkedUnits)
                                                                |> Result.map (Csexp.list << List.concat)
                                                )
                                    )
                        )
            )


-- ======================= BATCH COMPILATION =======================
-- compileBatch : the corpus (Prelude + Runtime + 7 core-libs) is parsed,
-- typechecked, and LOWERED ONCE; every fixture group then only pays for its
-- own parse/typecheck/lower against the cached corpus environment + entries.
--
-- The corpus bundle is BYTE-IDENTICAL to the single-compile output because
-- each corpus unit's lowering depends only on the corpus globals' MEMBERSHIP
-- and ARITIES (see Lower.Expr.globalRefByKey), and both are unchanged by any
-- user group (corpus modules reference only corpus/Prelude names; user module
-- names are distinct, so no key/arity can be shadowed).  The 74-fixture gate
-- (byte-identical bundles) is the empirical check of this invariant.
--
-- Return shape: `Err msg` ONLY for a corpus-level failure (parse/typecheck/
-- lower of the corpus itself) — Main maps that to an `err` entry for every
-- group.  On corpus success the list has one entry PER GROUP: the full bundle
-- text, or "err <msg>" if that group alone failed to parse/typecheck/lower.


compileBatch : List String -> List (List String) -> Result String (List String)
compileBatch corpusSources groups =
    parseAll corpusSources
        |> Result.andThen
            (\corpusFiles ->
                collectAll corpusFiles
                    |> Result.andThen
                        (\_ ->
                            Check.checkBuiltins corpusFiles
                                |> Result.andThen
                                    (\{ env, files } ->
                                        collectAll files
                                            |> Result.andThen
                                                (\corpusUnits ->
                                                    case mergedGlobals corpusUnits of
                                                        Err msg ->
                                                            Err msg

                                                        Ok corpusGlobals ->
                                                            case sequenceMaps (List.map (compileUnit corpusGlobals) corpusUnits) of
                                                                Err msg ->
                                                                    Err msg

                                                                Ok corpusEntryLists ->
                                                                    let
                                                                        corpusEntries =
                                                                            List.concat corpusEntryLists
                                                                    in
                                                                    Ok (List.map (compileOneGroup env corpusUnits corpusEntries) groups)
                                                )
                                    )
                        )
            )


-- One fixture group: parse+collect the group, check it against the cached
-- builtin env, then lower the (rewritten) group units against the COMBINED
-- globals (corpus ++ group) so group modules resolve each other AND the
-- corpus.  Bundle = corpusEntries ++ groupEntries wrapped ONCE (byte-identical
-- to lowering corpus+group together in one compileSources call).
compileOneGroup : Env -> List Unit -> List String -> List String -> String
compileOneGroup env corpusUnits corpusEntries groupSources =
    case
        parseAll groupSources
            |> Result.andThen
                (\groupFiles ->
                    collectAll groupFiles
                        |> Result.andThen
                            (\groupUnits0 ->
                                Check.checkUserGroup env (List.map .file groupUnits0)
                                    |> Result.andThen
                                        (\checkedGroupFiles ->
                                            collectAll checkedGroupFiles
                                                |> Result.andThen
                                                    (\groupUnits ->
                                                        case mergedGlobals (corpusUnits ++ groupUnits) of
                                                            Err msg ->
                                                                Err msg

                                                            Ok globals ->
                                                                sequenceMaps (List.map (compileUnit globals) groupUnits)
                                                                    |> Result.map (Csexp.list << (++) corpusEntries << List.concat)
                                                    )
                                        )
                            )
                )
    of
        Ok bundle ->
            bundle

        Err msg ->
            "err " ++ msg


parseAll : List String -> Result String (List File.File)
parseAll sources =
    sequenceMaps (List.map parseOne sources)


parseOne : String -> Result String File.File
parseOne source =
    case Elm.Parser.parseToFile source of
        Ok file ->
            Ok file

        Err _ ->
            Err "parse failed"


collectAll : List File.File -> Result String (List Unit)
collectAll files =
    sequenceMaps (List.map collectUnit files)


-- One compilation unit: a module's lowering inputs + outputs.


type alias Unit =
    { moduleName : List String
    , funs : List ( String, Function )
    , ctors : List ( String, Int )
    , file : File.File
    }


collectUnit : File.File -> Result String Unit
collectUnit file =
    let
        modName =
            moduleNameOf file
    in
    collectFunctions file.declarations
        |> Result.andThen
            (\funs ->
                collectCtors file.declarations
                    |> Result.map
                        (\ctors ->
                            { moduleName = modName
                            , funs = funs
                            , ctors = ctors
                            , file = file
                            }
                        )
            )


-- Per-module duplicate check (ctor-vs-fn / ctor-vs-ctor collisions).


mergedGlobals : List Unit -> Result String (Dict String Int)
mergedGlobals units =
    List.foldl mergeStep (Ok Dict.empty) units


mergeStep : Unit -> Result String (Dict String Int) -> Result String (Dict String Int)
mergeStep unit accResult =
    case accResult of
        Err msg ->
            Err msg

        Ok acc ->
            let
                locals =
                    List.map Tuple.first unit.funs ++ List.map Tuple.first unit.ctors
            in
            case findDuplicate locals of
                Just dup ->
                    Err
                        ("duplicate top-level definition in "
                            ++ String.join "." unit.moduleName
                            ++ ": "
                            ++ dup
                        )

                Nothing ->
                    let
                        fnsArity =
                            List.map (\( nm, fn ) -> ( nm, functionArity fn )) unit.funs

                        qualifiedPairs =
                            List.map (\( n, ar ) -> ( Resolve.qualify unit.moduleName n, ar ))
                                (fnsArity ++ unit.ctors)
                    in
                    Ok (List.foldl (\( k, v ) d -> Dict.insert k v d) acc qualifiedPairs)


-- Sequence a list of Results into a Result of a list (Ok-shortcircuiting).


sequenceMaps : List (Result String a) -> Result String (List a)
sequenceMaps results =
    List.foldr (Result.map2 (::)) (Ok []) results



-- ========================= UNIT COMPILATION =========================
-- compileUnit lowers one collected module against the merged global view.


compileUnit : Dict String Int -> Unit -> Result String (List String)
compileUnit globals unit =
    let
        modName =
            unit.moduleName

        definedNames =
            List.map Tuple.first unit.funs ++ List.map Tuple.first unit.ctors

        exported =
            Resolve.exportedNames unit.file.moduleDefinition definedNames

        aliasTable =
            Resolve.aliasTableFor modName exported unit.file.imports

        baseCtx =
            Expr.newContext modName globals
                |> Expr.withImport aliasTable
    in
    compileFuns baseCtx unit.funs
        |> Result.map
            (\fnEntries ->
                let
                    ctorEntries =
                        List.map (ctorEntry modName) unit.ctors

                    wrapperEntries =
                        List.map wrapperEntry Expr.primWrappers
                            ++ List.map unaryWrapperEntry Expr.unaryPrims
                            ++ List.map ternaryWrapperEntry Expr.ternaryPrims
                            ++ [ substringWrapperEntry ]
                in
                fnEntries ++ ctorEntries ++ wrapperEntries
            )




-- ==================== DECLARATION COLLECTION ====================
-- collect the top-level FunctionDeclarations as (name, Function) pairs.
-- Non-function declarations are tolerated for now EXCEPT Port/Infix
-- declarations, which the subset never supports (they error).


moduleNameOf : File.File -> List String
moduleNameOf file =
    case file.moduleDefinition of
        Node _ modDef ->
            SyntaxModule.moduleName modDef


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


forbiddenDecl : Node Declaration.Declaration -> Maybe String
forbiddenDecl (Node _ decl) =
    case decl of
        Declaration.PortDeclaration _ ->
            Just "port declarations are not supported"

        Declaration.InfixDeclaration _ ->
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



-- ======================= COMPILATION CORE =======================


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


synthesize : String -> List (Node Pattern.Pattern) -> Node Expression -> Function
synthesize name args body =
    { documentation = Nothing
    , signature = Nothing
    , declaration = Node (Node.range body) (FunctionImplementation (Node Range.empty name) args body)
    }


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
                |> Result.andThen
                    (\argNames ->
                        Expr.lowerExpression impl.expression Expr.Tail (withArgs baseCtx argNames)
                            |> Result.map
                                (\body ->
                                    let
                                        grabs =
                                            List.repeat (List.length argNames - 1) Emit.Grab

                                        code =
                                            [ Emit.Cur (grabs ++ body ++ [ Emit.Return ]) ]
                                    in
                                    Csexp.bundleEntry (Resolve.qualify baseCtx.moduleName name)
                                        (Emit.flatten (Emit.resolve code))
                                )
                    )


withArgs : Expr.Context -> List String -> Expr.Context
withArgs baseCtx argNames =
    -- RTL arg convention: push param1 FIRST so it lands at the deepest slot
    -- access(n-1); param2 -> access(n-2), ..., param_n -> access(0).
    { baseCtx | scope = List.foldl Scope.push baseCtx.scope argNames }


-- A value-constructor defun for a ctor of arity n, keyed under the module's
-- qualified name.  The value is a VM VECTOR of size n+1 (the MX ADT rep):
-- element 0 is the ctor tag Symbol (the BARE name, shared with patterns —
-- Pattern.compilePattern tests Symbol tag), elements 1..n are the args in
-- source order.  Construction pushes each (val, idx) pair root-first, then
-- allocates the vector LAST (so it sits on top) and chains n+1 address-> stores
-- (each pops vec/idx/val and re-pushes vec).  Nullary (n=0): vector[tag] of
-- length 1, no grabs — a 0-arg thunk referenced via the existing 0-arity
-- `m g name p` apply path.
ctorEntry : List String -> ( String, Int ) -> String
ctorEntry modName ( name, n ) =
    let
        grabs =
            List.repeat (n - 1) Emit.Grab

        pushes =
            [ Emit.Symbol name, Emit.Number_ 0 ]
                ++ List.concatMap (\j -> [ Emit.Access (n - j), Emit.Number_ j ]) (List.range 1 n)

        body =
            pushes ++ [ Emit.Number_ (n + 1), Emit.Prim "absvector" ] ++ List.repeat (n + 1) (Emit.Prim "address->")

        code =
            [ Emit.Cur (grabs ++ body ++ [ Emit.Return ]) ]
    in
    Csexp.bundleEntry (Resolve.qualify modName name) (Emit.flatten (Emit.resolve code))


-- A 2-arg curried wrapper for a binary prim, keyed "<op>.curried" — the
-- OPERATOR name when present (so `(/)` -> "/.curried", `(//)` -> "//.curried"),
-- else the prim name (preserving "cn.curried").  Identical duplicates across
-- compilation units are harmless (defunSet: later store wins with
-- byte-identical bodies).
wrapperEntry : ( String, String ) -> String
wrapperEntry ( op, prim ) =
    let
        name =
            Expr.wrapperGlobalName (if op == "" then prim else op)

        body =
            [ Emit.Access 0, Emit.Access 1, Emit.Prim prim, Emit.Return ]

        code =
            [ Emit.Cur (Emit.Grab :: body) ]
    in
    Csexp.bundleEntry name (Emit.flatten (Emit.resolve code))


-- A 3-arg curried wrapper for a ternary prim, keyed "<prim>.curried".  Two
-- grabs (a lone third `r` would misbehave — see unaryWrapperEntry).  Body
-- pushes access 0 (= param3) FIRST and access 2 (= param1, the vector)
-- LAST, so the pops come out (vec, idx, val) = (param1, param2, param3) —
-- the same leftmost-pops-first order as the 2-arg wrapperEntry.
ternaryWrapperEntry : String -> String
ternaryWrapperEntry prim =
    let
        name =
            Expr.wrapperGlobalName prim

        body =
            [ Emit.Access 0, Emit.Access 1, Emit.Access 2, Emit.Prim prim, Emit.Return ]

        code =
            [ Emit.Cur (Emit.Grab :: Emit.Grab :: body) ]
    in
    Csexp.bundleEntry name (Emit.flatten (Emit.resolve code))


-- A 3-arg curried wrapper for the `substring` prim in String.sliceLen's
-- SOURCE order (start len str), keyed "substring.curried" (aliased via
-- Lower.Resolve.primDotAliases).  NOTE: deliberately NOT named String.slice —
-- real Elm's slice is (start, end, str), this prim is length-based; the
-- sliceLen spelling keeps the divergence from being silently wrong.  The
-- prim pops (string, start, len), and
-- access 0 = param3 / 1 = param2 / 2 = param1 (see ternaryWrapperEntry), so
-- the body pushes len (access 1), start (access 2), string (access 0) —
-- pops come out (string, start, len).  Same two-grab convention.
substringWrapperEntry : String
substringWrapperEntry =
    let
        name =
            Expr.wrapperGlobalName "substring"

        body =
            [ Emit.Access 1, Emit.Access 2, Emit.Access 0, Emit.Prim "substring", Emit.Return ]

        code =
            [ Emit.Cur (Emit.Grab :: Emit.Grab :: body) ]
    in
    Csexp.bundleEntry name (Emit.flatten (Emit.resolve code))


-- A 1-arg curried wrapper for a UNARY prim (`c-strlen`), keyed
-- "c-strlen.curried".  ZERO grabs: a lone `r` in a closure body misbehaves on
-- this VM — interp.zig's grab treats a mark-on-stack as "no more args", pops
-- it and EXITS the run loop with acc = mark (not a clean partial-app return),
-- so a full-arity call into `(r body)` returns garbage.  With zero grabs the
-- N==0 apply path jumps straight into the body; access(0) reads back the one
-- pushed arg.  (Binary wrappers stay healthy: their first grab consumes the
-- mark, and single-grab AFTER that grab behaves.)
unaryWrapperEntry : String -> String
unaryWrapperEntry prim =
    let
        name =
            Expr.wrapperGlobalName prim

        body =
            [ Emit.Access 0, Emit.Prim prim, Emit.Return ]

        code =
            [ Emit.Cur body ]
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
