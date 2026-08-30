module Lower.Resolve exposing
    ( aliasTableFor
    , exportedNames
    , preludeModuleName
    , preludeTable
    , platformTable
    , streamPrimAliases
    , vectorPrimAliases
    , processPrimAliases
    , comparePrimAliases
    , primDotAliases
    , qualify
    )

-- The SINGLE shared alias-table construction + export enumeration, used by
-- BOTH the lowerer (Lower.Module/Lower.Expr) and the typechecker (Type.Infer /
-- Type.Builtins) so name resolution cannot drift between the two passes.
--
-- These live in their OWN leaf module (not Lower.Module) because Lower.Module
-- must import the typechecker (Type.Check) at S6, and Type.Infer imports this
-- module — putting the tables in Lower.Module would create a module cycle
-- (Lower.Module -> Type.Check -> Type.Infer -> Lower.Module).
--
-- ORDER MATTERS (first-match-wins): SELF rows first — the module's own
-- definitions shadow everything (incl. prelude names) — then user-import expose
-- rows, then the implicit prelude. prim-dot keys are dotted so can go last;
-- the Platform.* conveniences (dotted) + the stream/vector/process/compare prim
-- bare aliases follow.

import Elm.Syntax.Exposing as Exposing exposing (Exposing(..))
import Elm.Syntax.Import as Import
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Lower.Expr as Expr


preludeModuleName : List String
preludeModuleName =
    [ "Prelude" ]


aliasTableFor : List String -> List String -> List (Node Import.Import) -> List ( String, String )
aliasTableFor modName exported imports =
    selfAliases modName exported
        ++ importAliases imports
        ++ preludeAliasesFor modName
        ++ primDotAliases
        ++ platformTable
        ++ streamPrimAliases
        ++ vectorPrimAliases
        ++ processPrimAliases
        ++ comparePrimAliases


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
    , ( "lt", "Prelude.lt" )
    , ( "gt", "Prelude.gt" )
    , ( "le", "Prelude.le" )
    , ( "ge", "Prelude.ge" )
    , ( "eq", "Prelude.eq" )
    , ( "neq", "Prelude.neq" )

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
    , ( "drop", "Prelude.drop" )
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
            , ( "drop", "drop" )
            ]
        ++ dottedRows ""
            [ ( "String.concat", "concat" )
            , ( "String.join", "join" )
            , ( "String.fromInt", "fromInt" )
            ]
        ++ dottedRows "Basics."
            [ ( "compare", "compare" )
            , ( "lt", "lt" )
            , ( "gt", "gt" )
            , ( "le", "le" )
            , ( "ge", "ge" )
            , ( "eq", "eq" )
            , ( "neq", "neq" )
            ]


dottedRows : String -> List ( String, String ) -> List ( String, String )
dottedRows prefix rows =
    List.map (\( d, short ) -> ( prefix ++ d, "Prelude." ++ short )) rows


-- Dotted conveniences backed DIRECTLY by curried prim wrappers (see
-- Lower.Module.wrapperEntry): these beat indirection through Prelude functions.
primDotAliases : List ( String, String )
primDotAliases =
    [ ( "String.append", Expr.wrapperGlobalName "cn" )
    , ( "String.length", Expr.wrapperGlobalName "c-strlen" )

    -- elm/core Bitwise (Array port support): dotted spellings rewrite to the
    -- curried prim wrappers minted from Expr.primWrappers/unaryPrims.
    , ( "Bitwise.and", Expr.wrapperGlobalName "bitwise-and" )
    , ( "Bitwise.or", Expr.wrapperGlobalName "bitwise-or" )
    , ( "Bitwise.xor", Expr.wrapperGlobalName "bitwise-xor" )
    , ( "Bitwise.complement", Expr.wrapperGlobalName "bitwise-not" )
    , ( "Bitwise.shiftLeftBy", Expr.wrapperGlobalName "bitwise-shift-left" )
    , ( "Bitwise.shiftRightBy", Expr.wrapperGlobalName "bitwise-shift-right" )
    , ( "Bitwise.shiftRightZfBy", Expr.wrapperGlobalName "bitwise-shift-right-zf" )
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


-- Vector-prim bare aliases (elm/core Array port): the JsArray substitute
-- module spells the VM vector prims with valid Elm identifiers that rewrite
-- to the curried wrapper globals keyed "<prim>.curried".
vectorPrimAliases : List ( String, String )
vectorPrimAliases =
    [ ( "vectorMake", Expr.wrapperGlobalName "absvector" )
    , ( "vectorGet", Expr.wrapperGlobalName "<-address" )
    , ( "vectorSet", Expr.wrapperGlobalName "address->" )
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


-- Structural-compare prim aliases: the Elm-level type predicates + byte-index
-- prim the Prelude.compare dispatcher is built from (elm/core Basics parity).
-- Bare names, appended to EVERY unit's alias table (incl. the Prelude itself —
-- preludeAliasesFor excludes only the preludeTable rows there), so `isNumber`
-- etc. resolve to the curried prim wrappers in any module.  charCode is the
-- 2-arg wrapper: param1 = STRING, param2 = index (the prim pops the string
-- first) -> call it `charCode str idx`; returns the byte at idx or -1.
comparePrimAliases : List ( String, String )
comparePrimAliases =
    [ ( "isNumber", Expr.wrapperGlobalName "number?" )
    , ( "isString", Expr.wrapperGlobalName "string?" )
    , ( "isCons", Expr.wrapperGlobalName "cons?" )
    , ( "isNil", Expr.wrapperGlobalName "empty?" )
    , ( "charCode", Expr.wrapperGlobalName "char-code" )
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


qualify : List String -> String -> String
qualify modName name =
    String.join "." (modName ++ [ name ])
