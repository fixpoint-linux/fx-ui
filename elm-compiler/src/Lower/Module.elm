module Lower.Module exposing (compileSources)

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
--      "c-strlen.curried", String.slice -> "substring.curried" — dotted
--      conveniences backed DIRECTLY by curried prim wrappers.
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
import Elm.Syntax.Exposing as Exposing exposing (Exposing(..))
import Elm.Syntax.Expression as Expression exposing (Expression, Function, FunctionImplementation)
import Elm.Syntax.File as File
import Elm.Parser
import Elm.Syntax.Import as Import
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


preludeModuleName : List String
preludeModuleName =
    [ "Prelude" ]



-- ============================ TOP-LEVEL API ============================
-- compileSources : parse all sources, merge, lower each module, concatenate
-- the per-module bundles into ONE bundle text.


compileSources : List String -> Result String String
compileSources sources =
    parseAll sources
        |> Result.andThen
            (\files ->
                let
                    unitsResult =
                        collectAll files
                in
                unitsResult
                    |> Result.andThen
                        (\units ->
                            case mergedGlobals units of
                                Err msg ->
                                    Err msg

                                Ok globals ->
                                    -- Per-unit lowering against the MERGED
                                    -- table; concatenation preserves any
                                    -- order (keys are globally unique).
                                    sequenceMaps (List.map (compileUnit globals) units)
                                        |> Result.map (Csexp.list << List.concat)
                        )
            )


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
                            List.map (\( n, ar ) -> ( qualify unit.moduleName n, ar ))
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
            exportedNames unit.file.moduleDefinition definedNames

        aliasTable =
            -- ORDER MATTERS (first-match-wins): SELF rows first — the
            -- module's own definitions shadow everything (incl. prelude
            -- names) — then user-import expose rows, then the implicit
            -- prelude. prim-dot keys are dotted so can go last.  M6 appends
            -- the Platform.* conveniences (dotted) + the stream-prim bare
            -- aliases (bare) after the prim-dot rows.
            selfAliases modName exported
                ++ importAliases unit.file.imports
                ++ preludeAliasesFor modName
                ++ primDotAliases
                ++ platformTable
                ++ streamPrimAliases
                ++ processPrimAliases

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
                in
                fnEntries ++ ctorEntries ++ wrapperEntries
            )



-- ======================= EXPORTS & ALIAS TABLE =======================


selfAliases : List String -> List String -> List ( String, String )
selfAliases modName exported =
    List.map (\n -> ( n, qualify modName n )) exported


preludeAliasesFor : List String -> List ( String, String )
preludeAliasesFor modName =
    if modName == preludeModuleName then
        []

    else
        preludeTable


-- The built-in `import Prelude exposing (..)` equivalent: bare short names
-- plus the dotted stdlib spellings, mapping to Prelude's qualified globals.


preludeTable : List ( String, String )
preludeTable =
    [ -- Basics-flavored values/functions
      ( "not", "Prelude.not" )
    , ( "identity", "Prelude.identity" )
    , ( "always", "Prelude.always" )
    , ( "min", "Prelude.min" )
    , ( "max", "Prelude.max" )
    , ( "clamp", "Prelude.clamp" )
    , ( "compare", "Prelude.compare" )

    -- Maybe / Result constructors + conveniences
    , ( "Just", "Prelude.Just" )
    , ( "Nothing", "Prelude.Nothing" )
    , ( "Ok", "Prelude.Ok" )
    , ( "Err", "Prelude.Err" )
    , ( "LT", "Prelude.LT" )
    , ( "EQ", "Prelude.EQ" )
    , ( "GT", "Prelude.GT" )
    , ( "maybeMap", "Prelude.maybeMap" )
    , ( "maybeWithDefault", "Prelude.maybeWithDefault" )
    , ( "resultMap", "Prelude.resultMap" )
    , ( "resultWithDefault", "Prelude.resultWithDefault" )

    -- List functions
    , ( "map", "Prelude.map" )
    , ( "filter", "Prelude.filter" )
    , ( "foldl", "Prelude.foldl" )
    , ( "foldr", "Prelude.foldr" )
    , ( "length", "Prelude.length" )
    , ( "sum", "Prelude.sum" )
    , ( "reverse", "Prelude.reverse" )
    , ( "append", "Prelude.append" )
    , ( "head", "Prelude.head" )
    , ( "tail", "Prelude.tail" )
    , ( "isEmpty", "Prelude.isEmpty" )
    , ( "singleton", "Prelude.singleton" )
    ]
        ++ dottedRows "List."
            [ ( "map", "map" )
            , ( "filter", "filter" )
            , ( "foldl", "foldl" )
            , ( "foldr", "foldr" )
            , ( "length", "length" )
            , ( "sum", "sum" )
            , ( "reverse", "reverse" )
            , ( "append", "append" )
            , ( "head", "head" )
            , ( "tail", "tail" )
            , ( "isEmpty", "isEmpty" )
            , ( "singleton", "singleton" )
            ]
        ++ dottedRows ""
            [ ( "String.concat", "concat" )
            , ( "String.join", "join" )
            , ( "String.fromInt", "fromInt" )
            ]


dottedRows : String -> List ( String, String ) -> List ( String, String )
dottedRows prefix rows =
    List.map (\( d, short ) -> ( prefix ++ d, "Prelude." ++ short )) rows


-- Dotted conveniences backed DIRECTLY by curried prim wrappers (see
-- wrapperEntry): these beat indirection through Prelude functions.


primDotAliases : List ( String, String )
primDotAliases =
    [ ( "String.append", Expr.wrapperGlobalName "cn" )
    , ( "String.length", Expr.wrapperGlobalName "c-strlen" )
    ]


-- M6/M7 Platform.*/Cmd.*/Task.*/Io.* conveniences: dotted Elm spellings that
-- rewrite to the self-hosted runtime's qualified globals (Runtime, the
-- auto-injected self-hosted effects module — NOT elm/core's Platform, which
-- would collide at `elm make` time).  Fixtures keep the real-Elm spellings
-- `Platform.worker` / `Cmd.*` / `Task.*` / `Io.*` without importing anything
-- (documented deviation).  `Io.*` is the VM stream-effect namespace (mirrors
-- real Elm's Http.getString/Time.now returning `Task Never a`).
platformTable : List ( String, String )
platformTable =
    [ ( "Platform.worker", "Runtime.worker" )
    , ( "Platform.program", "Runtime.program" )
    , ( "Cmd.none", "Runtime.cmdNone" )
    , ( "Cmd.batch", "Runtime.cmdBatch" )
    , ( "Cmd.map", "Runtime.cmdMap" )
    , ( "Task.succeed", "Runtime.taskSucceed" )
    , ( "Task.fail", "Runtime.taskFail" )
    , ( "Task.map", "Runtime.taskMap" )
    , ( "Task.map2", "Runtime.taskMap2" )
    , ( "Task.andThen", "Runtime.taskAndThen" )
    , ( "Task.onError", "Runtime.taskOnError" )
    , ( "Task.sequence", "Runtime.taskSequence" )
    , ( "Task.perform", "Runtime.taskPerform" )
    , ( "Task.attempt", "Runtime.taskAttempt" )
    , ( "Io.readLine", "Runtime.taskReadLine" )
    , ( "Io.readFile", "Runtime.taskReadFile" )
    , ( "Io.writeString", "Runtime.taskWriteString" )
    , ( "Io.writeFile", "Runtime.taskWriteFile" )
    , ( "Io.exec", "Runtime.taskExec" )
    , ( "Io.getenv", "Runtime.taskGetenv" )
    , ( "Io.setenv", "Runtime.taskSetenv" )
    , ( "Io.cd", "Runtime.taskCd" )
    , ( "Io.getcwd", "Runtime.taskGetcwd" )
    , ( "Io.getpid", "Runtime.taskGetpid" )
    , ( "Io.glob", "Runtime.taskGlob" )
    , ( "Plan.str", "Runtime.tStr" )
    , ( "Plan.num", "Runtime.tNum" )
    , ( "Plan.sym", "Runtime.tSym" )
    , ( "Plan.nil", "Runtime.tNil" )
    , ( "Plan.cons", "Runtime.tCons" )
    , ( "Sub.none", "Runtime.subNone" )
    ]


-- M6 stream-prim bare aliases.  The VM prim names are hyphenated/arrowed
-- ("write-byte", "shen.str->bytes") — NOT valid Elm identifiers — so the Elm
-- surface spells them with valid names (writeByte, strToBytes, ...) that
-- rewrite to the curried wrapper globals keyed "<prim>.curried".
streamPrimAliases : List ( String, String )
streamPrimAliases =
    [ ( "writeByte", Expr.wrapperGlobalName "write-byte" )
    , ( "readByte", Expr.wrapperGlobalName "read-byte" )
    , ( "readFilePrim", Expr.wrapperGlobalName "read-file-as-string" )
    , ( "open", Expr.wrapperGlobalName "open" )
    , ( "close", Expr.wrapperGlobalName "close" )
    , ( "strToBytes", Expr.wrapperGlobalName "shen.str->bytes" )
    , ( "bytesToString", Expr.wrapperGlobalName "shen.bytes->string" )
    ]


-- M8 process-prim bare aliases: the VM prim names are hyphenated ("exec-plan",
-- "getenv", ...) — some are valid Elm identifiers (cd/getenv/getpid/glob/intern)
-- but none is a `binaryPrims`/`unaryPrims` row, so the Runtime spells them with
-- camelCase names that rewrite to the curried wrapper globals keyed
-- "<prim>.curried".  `intern` backs the Plan.* tagged-value builders.
processPrimAliases : List ( String, String )
processPrimAliases =
    [ ( "execPlanPrim", Expr.wrapperGlobalName "exec-plan" )
    , ( "getenvPrim", Expr.wrapperGlobalName "getenv" )
    , ( "setenvPrim", Expr.wrapperGlobalName "setenv" )
    , ( "cdPrim", Expr.wrapperGlobalName "cd" )
    , ( "getcwdPrim", Expr.wrapperGlobalName "getcwd" )
    , ( "getpidPrim", Expr.wrapperGlobalName "getpid" )
    , ( "globPrim", Expr.wrapperGlobalName "glob" )
    , ( "intern", Expr.wrapperGlobalName "intern" )
    ]


-- User imports -> bare-token alias rows (explicit exposing lists only).


importAliases : List (Node Import.Import) -> List ( String, String )
importAliases imports =
    List.concatMap importAlias imports


importAlias : Node Import.Import -> List ( String, String )
importAlias (Node _ imp) =
    let
        target =
            Node.value imp.moduleName

        qualified n =
            String.join "." (target ++ [ n ])
    in
    -- Plain `import X` / `import X as Y` need NO rows: qualified references
    -- (X.f / Y.f — Y the alias spelling) resolve via globals-membership,
    -- because dotted tokens are tried verbatim against the merged table.
    -- (LIMITATION, fine for the M3 gate: `import X as Y exposing (..)`'s
    -- bare names are not enumerable without a cross-module export pass.)
    case imp.exposingList of
        Just (Node _ exp) ->
            case exp of
                All _ ->
                    -- Minimal-M3 limitation: unenumerable without a
                    -- cross-module export pass (use explicit lists).
                    []

                Explicit items ->
                    List.concatMap (exposeAlias qualified) items

        Nothing ->
            []


exposeAlias : (String -> String) -> Node Exposing.TopLevelExpose -> List ( String, String )
exposeAlias mkQualified (Node _ item) =
    case item of
        Exposing.InfixExpose _ ->
            []

        Exposing.FunctionExpose n ->
            [ ( n, mkQualified n ) ]

        Exposing.TypeOrAliasExpose n ->
            [ ( n, mkQualified n ) ]

        Exposing.TypeExpose { name } ->
            -- Listed type: expose the type name bare; its constructors ride
            -- along implicitly under the SAME spelling Elm uses for nullary
            -- tags (minimal semantics: unknown names still error naturally).
            [ ( name, mkQualified name ) ]


-- The exported-name list of a module, honoring its exposing clause:
--   exposing (..)        -> everything (functions + ctors)
--   exposing (a, T(..))  -> filtered to what the module actually defines


exportedNames : Node SyntaxModule.Module -> List String -> List String
exportedNames (Node _ modDef) defined =
    let
        pick names =
            List.filter (\n -> List.member n defined) names
    in
    case SyntaxModule.exposingList modDef of
        All _ ->
            defined

        Explicit items ->
            List.concatMap
                (\(Node _ item) ->
                    case item of
                        Exposing.InfixExpose _ ->
                            []

                        Exposing.FunctionExpose n ->
                            pick [ n ]

                        Exposing.TypeOrAliasExpose n ->
                            pick [ n ]

                        Exposing.TypeExpose { name } ->
                            pick [ name ]
                )
                items



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


qualify : List String -> String -> String
qualify modName name =
    String.join "." (modName ++ [ name ])



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
                                    Csexp.bundleEntry (qualify baseCtx.moduleName name)
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
    Csexp.bundleEntry (qualify modName name) (Emit.flatten (Emit.resolve code))


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
