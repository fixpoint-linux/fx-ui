module Type.Builtins exposing
    ( lookupValue
    , operatorScheme
    , recordRemove
    , recordRemoveImpl
    , removeFieldImplScheme
    , isTrusted
    , primWrapperSchemes
    , uncoveredPrimRows
    )

{-| Builtin schemes: the special-variable (flex-super) operator schemes from
the plan, the schemes for every alias-table row that targets a PRIM WRAPPER
global (`<prim>.curried`), the magic `Record.remove` surface, and the
trusted-bodies set.

Name resolution is shared with the lowerer: this module imports the alias
tables from `Lower.Module` (the SINGLE source of truth, exposed for exactly
this purpose) and derives the value table FROM them, so adding a prim alias
row without a scheme here is detected by `uncoveredPrimRows` (a TestMain
drift guard), and rows targeting Prelude/Runtime globals are left to the
merged environment's schemes.

The operator rules (the plan's special vars, no typeclasses):

  - `Integer`/`Hex` -> fresh `number`; `Floatable` -> `Float` (a float literal
    is never `Int`).
  - `+` `-` `*` (and unary negation) : `number -> number -> number`.
  - `//` : `Int -> Int -> Int`;  `/` : `Float -> Float -> Float`.
  - `<` `<=` `>` `>=` `==` `/=` : `comparable -> comparable -> Bool`.
  - `&&` `||` : `Bool -> Bool -> Bool`;  `++` : `appendable -> appendable ->
    appendable`;  `::` : `a -> List a -> List a`.

`appendable` is resolved to String/List per `++` site by the Infer pass (the
zonk exception); it never survives into a generalized scheme.

This module is pure Elm (elm/core + Type.Representation/Unify + Type.Env +
the shared Lower.Module alias tables).

-}

import Dict exposing (Dict)
import Lower.Resolve as LowerModule
import Type.Env exposing (Scheme)
import Type.Representation as Rep exposing (Flex(..), Kind(..), Type(..))


{-| Resolve a value name (a `.curried` prim-wrapper global, a prim alias
spelling such as `String.append` / `writeByte`, or `Prelude.removeFieldImpl`)
to its builtin scheme. `Nothing` means "not a builtin" — resolve through the
merged environment instead.
-}
lookupValue : String -> Maybe Scheme
lookupValue name =
    Dict.get name valueTable


{-| The scheme for a binary/prefix operator used in source (e.g. `(+)`), by
operator name.
-}
operatorScheme : String -> Maybe Scheme
operatorScheme op =
    Dict.get op operatorSchemes


{-| The magic record-removal surface: `Record.remove '<label>' record`.  The
label comes from a literal and the type depends on that literal, which HM
cannot express as a scheme, so the Infer pass recognizes this reference and
rewrites it to `recordRemoveImpl` (see `handoff-elm-typecheck-artifact-3`).
-}
recordRemove : String
recordRemove =
    "Record.remove"


{-| The trusted Prelude function `Record.remove` rewrites to.  It removes the
OUTERMOST matching field only (paper `restrict`), preserving scoped labels.
-}
recordRemoveImpl : String
recordRemoveImpl =
    "Prelude.removeFieldImpl"


{-| The (trusted-lie) scheme for `removeFieldImpl`: `String -> a -> b` — the
result row is not the argument row, so a precise scheme does not exist; the
body is skipped by the checker (it is in `isTrusted`).
-}
removeFieldImplScheme : Scheme
removeFieldImplScheme =
    poly [ a, b ] (func [ tString, TVar a ] (TVar b))


{-| Is a qualified function name's body trusted (skipped by the checker)?
-}
isTrusted : String -> Bool
isTrusted name =
    List.member name trustedBodies



-- ======================= OPERATORS =======================


operatorSchemes : Dict String Scheme
operatorSchemes =
    Dict.fromList
        [ ( "+", flexBinop FNumber )
        , ( "-", flexBinop FNumber )
        , ( "*", flexBinop FNumber )
        , ( "//", mono (func [ tInt, tInt ] tInt) )
        , ( "/", mono (func [ tFloat, tFloat ] tFloat) )
        , ( "<", cmpOp )
        , ( "<=", cmpOp )
        , ( ">", cmpOp )
        , ( ">=", cmpOp )
        , ( "==", cmpOp )
        , ( "/=", cmpOp )
        , ( "&&", mono (func [ tBool, tBool ] tBool) )
        , ( "||", mono (func [ tBool, tBool ] tBool) )
        , ( "++", flexBinop FAppendable )
        , ( "::", consOp )

        -- Pipe conveniences (Lower lowers `x |> f a` to `f a x`): typed here
        -- so the checker and the lowerer agree on the same surface.
        , ( "|>", pipeRight )
        , ( "<|", pipeLeft )
        ]


-- a -> a -> a with the given flex marker on the (single) variable.
flexBinop : Flex -> Scheme
flexBinop flex =
    let
        v =
            Rep.var 0 KType flex
    in
    poly [ v ] (func [ TVar v, TVar v ] (TVar v))


-- comparable -> comparable -> Bool
cmpOp : Scheme
cmpOp =
    let
        v =
            Rep.var 0 KType FComparable
    in
    poly [ v ] (func [ TVar v, TVar v ] tBool)


-- a -> List a -> List a
consOp : Scheme
consOp =
    let
        v =
            Rep.var 0 KType FNone
    in
    poly [ v ] (func [ TVar v, tList (TVar v) ] (tList (TVar v)))


-- a -> (a -> b) -> b  (forward pipe `|>`)
pipeRight : Scheme
pipeRight =
    poly [ a, b ] (func [ TVar a, TFun (TVar a) (TVar b) ] (TVar b))


-- (a -> b) -> a -> b  (backward pipe `<|`)
pipeLeft : Scheme
pipeLeft =
    poly [ a, b ] (func [ TFun (TVar a) (TVar b), TVar a ] (TVar b))



-- ======================= PRIM WRAPPERS =======================


-- Every alias-table row that targets a PRIM WRAPPER global ("<prim>.curried")
-- gets a scheme here, keyed by PRIM name.  Rows targeting Prelude/Runtime
-- globals are absent (they resolve via the merged env).
primWrapperSchemes : Dict String Scheme
primWrapperSchemes =
    Dict.fromList
        [ ( "cn", mono (func [ tString, tString ] tString) )
        , ( "c-strlen", mono (func [ tString ] tInt) )
        , ( "bitwise-and", mono (func [ tInt, tInt ] tInt) )
        , ( "bitwise-or", mono (func [ tInt, tInt ] tInt) )
        , ( "bitwise-xor", mono (func [ tInt, tInt ] tInt) )
        , ( "bitwise-not", mono (func [ tInt ] tInt) )
        , ( "bitwise-shift-left", mono (func [ tInt, tInt ] tInt) )
        , ( "bitwise-shift-right", mono (func [ tInt, tInt ] tInt) )
        , ( "bitwise-shift-right-zf", mono (func [ tInt, tInt ] tInt) )

        -- Stream I/O.  `Stream` is an opaque VM type with no Elm declaration;
        -- open can also yield `false` at runtime (trusted lie: Stream only).
        , ( "write-byte", mono (func [ tInt, stream ] tInt) )
        , ( "read-byte", mono (func [ stream ] tInt) )
        , ( "read-file-as-string", mono (func [ tString ] tString) )
        , ( "open", mono (func [ tString, tString ] stream) )
        , ( "close", mono (func [ stream ] tUnit) )
        , ( "shen.str->bytes", mono (func [ tString ] (tList tInt)) )
        , ( "shen.bytes->string", mono (func [ tList tInt ] tString) )

        -- Vector prims (the JsArray substitute).  UNIFORM-poly lies: the VM
        -- vector also stores the element count in slot 0 (an Int), so the
        -- JsArray/Array units will likely need trusted-skip at S6 (plan R2).
        , ( "absvector", poly [ a ] (func [ tInt ] (jsArray (TVar a))) )
        , ( "<-address", poly [ a ] (func [ jsArray (TVar a), tInt ] (TVar a)) )
        , ( "address->", poly [ a ] (func [ jsArray (TVar a), tInt, TVar a ] (jsArray (TVar a))) )

        -- substring(str, start, len), clamped — but the wrapper
        -- (Lower.Module.substringWrapperEntry) permutes to String.sliceLen's
        -- SOURCE order, so the visible spelling is start -> len -> str
        -- (deliberately NOT real Elm's (start, end) String.slice).
        , ( "substring", mono (func [ tInt, tInt, tString ] tString) )

        -- Process execution.  exec-plan takes/returns a tagged list; intern is
        -- a trusted lie (returns a VM symbol typed as String).  Inert by
        -- construction: its only call sites are TRUSTED bodies (Prelude.
        -- removeFieldImpl, Runtime.tStr/tNum/tSym/tNil/tCons), which the
        -- checker skips — so no checked code ever observes the symbol as a
        -- String.  Kept in the value table only so the scheme is documented
        -- and TestMain can assert it stays stable.
        , ( "exec-plan", poly [ a, b ] (func [ tList (TVar a) ] (tList (TVar b))) )
        , ( "getenv", mono (func [ tString ] tString) )
        , ( "setenv", mono (func [ tString, tString ] tBool) )
        , ( "cd", mono (func [ tString ] tBool) )
        , ( "getcwd", mono (func [ tUnit ] tString) )
        , ( "getpid", mono (func [ tUnit ] tInt) )
        , ( "glob", mono (func [ tString ] (tList tString)) )
        , ( "intern", mono (func [ tString ] tString) )

        -- Structural-compare predicates (Prelude.compare dispatcher).
        , ( "number?", poly [ a ] (func [ TVar a ] tBool) )
        , ( "string?", poly [ a ] (func [ TVar a ] tBool) )
        , ( "cons?", poly [ a ] (func [ TVar a ] tBool) )
        , ( "empty?", poly [ a ] (func [ TVar a ] tBool) )
        , ( "char-code", mono (func [ tString, tInt ] tInt) )
        ]


-- The alias tables whose rows target prim wrappers (NOT prelude/platform
-- rows, which map to Prelude/Runtime globals).
primAliasTables : List (List ( String, String ))
primAliasTables =
    [ LowerModule.primDotAliases
    , LowerModule.streamPrimAliases
    , LowerModule.vectorPrimAliases
    , LowerModule.processPrimAliases
    , LowerModule.comparePrimAliases
    ]


-- Rows targeting a prim wrapper that have NO scheme here — a drift guard: the
-- TestMain checks assert this is empty (and that the count matches).
uncoveredPrimRows : List ( String, String )
uncoveredPrimRows =
    List.concat primAliasTables
        |> List.filter
            (\( _, target ) ->
                String.endsWith ".curried" target && primSchemeOf target == Nothing
            )


primSchemeOf : String -> Maybe Scheme
primSchemeOf target =
    if String.endsWith ".curried" target then
        Dict.get (String.dropRight 8 target) primWrapperSchemes

    else
        Nothing


-- The full builtin value table: every "<prim>.curried" global key, every prim
-- alias spelling, and removeFieldImpl.
valueTable : Dict String Scheme
valueTable =
    let
        fromPrims =
            Dict.foldl
                (\prim scheme acc -> Dict.insert (prim ++ ".curried") scheme acc)
                Dict.empty
                primWrapperSchemes

        fromAliases =
            List.concat primAliasTables
                |> List.foldl addAliasRow Dict.empty

        removeField =
            Dict.singleton recordRemoveImpl removeFieldImplScheme

        -- M6 stdin/stdout pseudo-globals: the lowerer rewrites these bare names
        -- to the VM stream VALUES (`Symbol "*stinput*"` / `Symbol "*stoutput*"`
        -- + `value`); the checker types them as the opaque `Stream`.
        pseudoGlobals =
            Dict.fromList
                [ ( "stdin", mono stream )
                , ( "stdout", mono stream )
                ]
    in
    Dict.union fromPrims (Dict.union fromAliases (Dict.union removeField pseudoGlobals))


addAliasRow : ( String, String ) -> Dict String Scheme -> Dict String Scheme
addAliasRow ( alias, target ) acc =
    case primSchemeOf target of
        Just scheme ->
            Dict.insert alias scheme acc

        Nothing ->
            acc



-- ======================= TRUSTED BODIES =======================


trustedBodies : List String
trustedBodies =
    [ recordRemoveImpl
    , "Prelude.compare"
    , "Prelude.fromInt"
    , "Runtime.runTask"
    , "Runtime.taskAndThen"
    , "Runtime.taskOnError"
    , "Runtime.decodeExec"
    , "Runtime.decodeStringList"
    , "Runtime.decodeNumber"
    , "Runtime.decodeString"
    , "Runtime.tStr"
    , "Runtime.tNum"
    , "Runtime.tSym"
    , "Runtime.tNil"
    , "Runtime.tCons"
    ]



-- ======================= HELPERS =======================


-- Build `a1 -> a2 -> ... -> res` (right-nested function type).
func : List Type -> Type -> Type
func args res =
    List.foldr TFun res args


mono : Type -> Scheme
mono t =
    { quantifiers = [], body = t }


poly : List Rep.VarId -> Type -> Scheme
poly qs t =
    { quantifiers = qs, body = t }


-- Fresh ids are per-scheme, so a single shared id-0/id-1 var is fine for every
-- polymorphic scheme (instantiate freshens independently per scheme).
a : Rep.VarId
a =
    Rep.var 0 KType FNone


b : Rep.VarId
b =
    Rep.var 1 KType FNone


stream : Type
stream =
    TCon "Stream" []


jsArray : Type -> Type
jsArray elem =
    TCon "JsArray" [ elem ]


tInt : Type
tInt =
    Rep.tInt


tFloat : Type
tFloat =
    Rep.tFloat


tBool : Type
tBool =
    Rep.tBool


tString : Type
tString =
    Rep.tString


tUnit : Type
tUnit =
    Rep.tUnit


tList : Type -> Type
tList =
    Rep.tList
