module Type.Env exposing
    ( Scheme
    , Env
    , Alias
    , empty
    , collectFile
    , merge
    , insert, insertCtor, insertAlias
    , lookupValue, lookupCtor, lookupAlias
    , instantiate, expandAliases
    , generalize, generalizeAvoiding
    , freeVars, freeVarsOfScheme, freeVarsOfEnv
    , monoScheme
    )

{-| The type environment: qualified schemes, constructor schemes, and type
aliases, collected from parsed `File`s and merged into one table keyed by
qualified `"Mod.name"` (mirroring `Lower.Module.mergedGlobals`).

  - A `Scheme` is a universally-quantified type (`forall a b. body`); the
    quantified variables are the `VarId`s that `instantiate` freshens.
  - `collectFile` gathers a unit's SIGNATURES, ADT constructor argument types,
    and type aliases (unsignatured functions are NOT collected — the Infer
    pass pre-seeds them with a fresh monomorphic var and generalizes them when
    the unit finishes, exactly like Elm).
  - `generalize` quantifies every free type variable (top-level); flex-marked
    `number`/`comparable` variables are KEPT in schemes and re-instantiated
    with the same marker (so `Dict.get : comparable -> Dict comparable v ->
    Maybe v` stays a legal polymorphic scheme).  `appendable` is the zonk
    exception: it is resolved to String/List at each `++` site by the Infer
    pass BEFORE generalization, so no scheme ever carries it.
  - `generalizeAvoiding` is let-generalization: it quantifies the free
    variables of a type that are NOT free in the enclosing environment.

This module is pure Elm (elm/core + elm-syntax + Type.Representation/Unify)
and must stay free of `Lower.*` imports so it can be unit-tested in isolation
via `src/TestMain.elm`.

-}

import Dict exposing (Dict)
import Elm.Syntax.Declaration as Declaration exposing (Declaration(..))
import Elm.Syntax.File as File
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Signature as Signature
import Elm.Syntax.Type as SyntaxType
import Elm.Syntax.TypeAlias as TypeAlias
import Elm.Syntax.TypeAnnotation as TA
import Type.Representation as Rep exposing (Flex(..), Kind(..), Row, RowTail(..), Type(..), VarId)
import Type.Unify as Uni


{-| A type scheme: a universally-quantified body type. The `quantifiers` are
the free variables of `body` (in first-appearance order); `instantiate`
replaces each with a fresh variable of the same kind and flex marker.
-}
type alias Scheme =
    { quantifiers : List VarId
    , body : Type
    }


{-| A type alias, stored as a type-level function (generics + an annotation),
expanded at use by the Infer pass. Row-kind generics are legal here
(`type alias Named r = { name : String | r }`); the kind of each generic is
inferred from its use position at expansion time.

The body is PRE-CONVERTED once at collection time, with each generic bound to a
NEGATIVE-id sentinel variable (`genericVars`, in declaration order). At
expansion, `expandAliases` builds a substitution from sentinel -> argument type
and zonks the body; a row-kind generic applied to a concrete record splices
into its tail via `Rep.zonk`'s row-splice. Negative ids can never collide with
the unification state's (non-negative) fresh ids, so the zonk is exact.
-}
type alias Alias =
    { name : String
    , generics : List String
    , annotation : TA.TypeAnnotation
    , genericVars : List VarId
    , body : Type
    }


{-| The merged type environment. Value (function) schemes and constructor
schemes live in separate tables but are both keyed by qualified `"Mod.name"`;
aliases are keyed the same way. `lookupValue` checks values then constructors.
-}
type alias Env =
    { values : Dict String Scheme
    , ctors : Dict String Scheme
    , aliases : Dict String Alias
    }


empty : Env
empty =
    { values = Dict.empty
    , ctors = Dict.empty
    , aliases = Dict.empty
    }



-- ======================= COLLECTION =======================


{-| Collect one parsed file's signatures, ADT constructors, and type aliases
into an `Env` keyed by qualified name. Unsignatured functions, ports, infix
declarations, and destructuring are ignored (the Infer pass handles them).
-}
collectFile : File.File -> Env
collectFile file =
    let
        self =
            String.join "." (moduleNameOf file)
    in
    List.foldl (collectDecl self) empty file.declarations


collectDecl : String -> Node Declaration -> Env -> Env
collectDecl self node env =
    case node of
        Node _ (FunctionDeclaration fn) ->
            case fn.signature of
                Just (Node _ sig) ->
                    let
                        name =
                            nodeString sig.name
                    in
                    insert (self ++ "." ++ name)
                        (signatureScheme self (Node.value sig.typeAnnotation))
                        env

                Nothing ->
                    env

        Node _ (CustomTypeDeclaration typeDecl) ->
            collectCtors self typeDecl env

        Node _ (AliasDeclaration aliasDecl) ->
            let
                qname =
                    self ++ "." ++ nodeString aliasDecl.name
            in
            insertAlias qname (buildAlias self qname aliasDecl) env

        _ ->
            env


collectCtors : String -> SyntaxType.Type -> Env -> Env
collectCtors self typeDecl env =
    let
        typeName =
            nodeString typeDecl.name

        generics =
            List.map nodeString typeDecl.generics
    in
    List.foldl
        (\ctorNode e ->
            let
                vc =
                    Node.value ctorNode
            in
            insertCtor (self ++ "." ++ nodeString vc.name)
                (ctorScheme self typeName generics vc.arguments)
                e
        )
        env
        typeDecl.constructors


{-| Build an `Alias` from its declaration: pre-convert the body annotation with
each generic bound to a NEGATIVE-id sentinel var (kind inferred from use
position — a generic used as a row tail becomes `KRow`). `genericVars` mirrors
`generics` order so `expandAliases` can substitute positionally.
-}
buildAlias : String -> String -> TypeAlias.TypeAlias -> Alias
buildAlias self qname aliasDecl =
    let
        generics =
            List.map nodeString aliasDecl.generics

        ( body, varMap ) =
            convertAliasBody self (Node.value aliasDecl.typeAnnotation)
    in
    { name = qname
    , generics = generics
    , annotation = Node.value aliasDecl.typeAnnotation
    , genericVars = List.filterMap (\g -> Dict.get g varMap) generics
    , body = body
    }


-- Convert an alias-body annotation with sentinel (negative-id) generic vars,
-- returning the body type and the generic-name -> sentinel-var map.
convertAliasBody : String -> TA.TypeAnnotation -> ( Type, Dict String VarId )
convertAliasBody self ann =
    let
        ( body, ctx1 ) =
            convert { self = self, vars = Dict.empty, next = -1, step = -1 } ann
    in
    ( body, ctx1.vars )


-- A constructor scheme: `Just : a -> Maybe a` (result type qualified by the
-- defining module; argument types may additionally introduce FRESH type
-- variables, e.g. `TaskAndThen : (a -> Task x b) -> Task x a -> Task x a` —
-- those are quantified too, so `generalize` on the whole ctor type is exact).
ctorScheme : String -> String -> List String -> List (Node TA.TypeAnnotation) -> Scheme
ctorScheme self typeName generics argAnnos =
    let
        ctx0 =
            { self = self, vars = Dict.empty, next = 0, step = 1 }

        ( genVars, ctx1 ) =
            List.foldl makeGeneric ( [], ctx0 ) generics

        resultType =
            TCon (self ++ "." ++ typeName) (List.map TVar genVars)

        ( argTypes, _ ) =
            convertList ctx1 argAnnos
    in
    generalize (List.foldr TFun resultType argTypes)


makeGeneric : String -> ( List VarId, Ctx ) -> ( List VarId, Ctx )
makeGeneric name ( acc, ctx ) =
    let
        ( v, ctx2 ) =
            typeVar KType name ctx
    in
    ( acc ++ [ v ], ctx2 )


-- A signature scheme: every `GenericType` leaf is quantified (with `number`/
-- `comparable`/`appendable` leaves given their flex marker); the row-kind of a
-- generic used as a row tail is inferred from its use position.
signatureScheme : String -> TA.TypeAnnotation -> Scheme
signatureScheme self ann =
    let
        ( t, _ ) =
            convert { self = self, vars = Dict.empty, next = 0, step = 1 } ann
    in
    generalize t


moduleNameOf : File.File -> List String
moduleNameOf file =
    case file.moduleDefinition of
        Node _ modDef ->
            SyntaxModule.moduleName modDef



-- ======================= MERGING / LOOKUP =======================


merge : Env -> Env -> Env
merge a b =
    { values = Dict.union a.values b.values
    , ctors = Dict.union a.ctors b.ctors
    , aliases = Dict.union a.aliases b.aliases
    }


insert : String -> Scheme -> Env -> Env
insert name scheme env =
    { env | values = Dict.insert name scheme env.values }


insertCtor : String -> Scheme -> Env -> Env
insertCtor name scheme env =
    { env | ctors = Dict.insert name scheme env.ctors }


insertAlias : String -> Alias -> Env -> Env
insertAlias name alias env =
    { env | aliases = Dict.insert name alias env.aliases }


lookupValue : String -> Env -> Maybe Scheme
lookupValue name env =
    case Dict.get name env.values of
        Just scheme ->
            Just scheme

        Nothing ->
            Dict.get name env.ctors


lookupCtor : String -> Env -> Maybe Scheme
lookupCtor name env =
    Dict.get name env.ctors


lookupAlias : String -> Env -> Maybe Alias
lookupAlias name env =
    Dict.get name env.aliases



-- ======================= INSTANTIATION =======================


{-| Instantiate a scheme: replace each quantified variable with a FRESH
variable of the same kind and flex marker, threading the unification state's
fresh-id counter. `instantiate` is how `Dict.get : comparable -> ...` becomes a
call-site monomorphic type with a fresh `comparable` variable.
-}
instantiate : Scheme -> Uni.State -> ( Type, Uni.State )
instantiate scheme state =
    let
        ( renames, st ) =
            List.foldl freshQuant ( Dict.empty, state ) scheme.quantifiers
    in
    ( rename renames scheme.body, st )


freshQuant : VarId -> ( Dict Int VarId, Uni.State ) -> ( Dict Int VarId, Uni.State )
freshQuant q ( renames, state ) =
    let
        ( f, st ) =
            Uni.freshVar q.kind q.flex state
    in
    ( Dict.insert q.id f renames, st )



-- ======================= ALIAS EXPANSION =======================


{-| Expand every registered type alias in a type, recursively. A `TCon` whose
name is a registered alias is rewritten to its body with the alias's generics
substituted for the `TCon`'s arguments (a row-kind generic applied to a
concrete record splices into the body's row tail via `Rep.zonk`). Nested
aliases and aliases inside argument/field types are expanded too.

Any NEGATIVE-id sentinel that survives an expansion (a row-kind generic applied
to a BARE type variable — its row tail is not a concrete record, so `Rep.zonk`'s
row-splice does not fire — or an alias applied to the wrong number of
arguments) is FRESHENED to a fresh non-negative id drawn from the unification
state's counter. This keeps sentinel ids out of the shared substitution: `unify`
can never bind one, so a later independent use of the same alias can never
observe an earlier use's binding through the same negative key.
-}
expandAliases : Env -> Type -> Uni.State -> ( Type, Uni.State )
expandAliases env t state =
    case t of
        TVar v ->
            ( TVar v, state )

        TCon name args ->
            case lookupAlias name env of
                Just alias ->
                    let
                        ( args2, st1 ) =
                            expandAliasesList env args state

                        ( body, st2 ) =
                            expandAliasBody alias args2 st1
                    in
                    expandAliases env body st2

                Nothing ->
                    let
                        ( args2, st1 ) =
                            expandAliasesList env args state
                    in
                    ( TCon name args2, st1 )

        TFun a b ->
            let
                ( a2, st1 ) =
                    expandAliases env a state

                ( b2, st2 ) =
                    expandAliases env b st1
            in
            ( TFun a2 b2, st2 )

        TTuple ts ->
            let
                ( ts2, st1 ) =
                    expandAliasesList env ts state
            in
            ( TTuple ts2, st1 )

        TRecord row ->
            let
                ( row2, st1 ) =
                    expandAliasesRow env row state
            in
            ( TRecord row2, st1 )


expandAliasesList : Env -> List Type -> Uni.State -> ( List Type, Uni.State )
expandAliasesList env ts state =
    case ts of
        [] ->
            ( [], state )

        t :: rest ->
            let
                ( t2, st1 ) =
                    expandAliases env t state

                ( ts2, st2 ) =
                    expandAliasesList env rest st1
            in
            ( t2 :: ts2, st2 )


expandAliasBody : Alias -> List Type -> Uni.State -> ( Type, Uni.State )
expandAliasBody alias args state =
    let
        subst =
            List.foldl
                (\( gv, arg ) s -> Rep.extend gv arg s)
                Rep.emptySubst
                (List.map2 Tuple.pair alias.genericVars args)
    in
    freshenSentinels (Rep.zonk subst alias.body) state


expandAliasesRow : Env -> Row -> Uni.State -> ( Row, Uni.State )
expandAliasesRow env row state =
    let
        ( fields2, st1 ) =
            expandAliasesFields env row.fields state
    in
    ( { fields = fields2, tail = row.tail }, st1 )


expandAliasesFields : Env -> List ( String, Type ) -> Uni.State -> ( List ( String, Type ), Uni.State )
expandAliasesFields env fields state =
    case fields of
        [] ->
            ( [], state )

        ( n, t ) :: rest ->
            let
                ( t2, st1 ) =
                    expandAliases env t state

                ( rest2, st2 ) =
                    expandAliasesFields env rest st1
            in
            ( ( n, t2 ) :: rest2, st2 )


{-| Replace every NEGATIVE-id sentinel left in an expanded alias body with a
fresh non-negative variable of the same kind and flex. The mapping is memoized
per expansion so a sentinel appearing in several positions (a row generic used
as two row tails) stays a single shared variable. Sentinels are only left by
`expandAliasBody` when a row-kind generic is applied to a bare type variable or
when the alias is applied to the wrong number of arguments.
-}
freshenSentinels : Type -> Uni.State -> ( Type, Uni.State )
freshenSentinels t state =
    let
        ( t2, _, st ) =
            freshen Dict.empty t state
    in
    ( t2, st )


freshen : Dict Int VarId -> Type -> Uni.State -> ( Type, Dict Int VarId, Uni.State )
freshen renames t state =
    case t of
        TVar v ->
            let
                ( v2, r2, st2 ) =
                    freshenId renames v state
            in
            ( TVar v2, r2, st2 )

        TCon name args ->
            let
                ( args2, r2, st2 ) =
                    freshenList renames args state
            in
            ( TCon name args2, r2, st2 )

        TFun a b ->
            let
                ( a2, r1, st1 ) =
                    freshen renames a state

                ( b2, r2, st2 ) =
                    freshen r1 b st1
            in
            ( TFun a2 b2, r2, st2 )

        TTuple ts ->
            let
                ( ts2, r2, st2 ) =
                    freshenList renames ts state
            in
            ( TTuple ts2, r2, st2 )

        TRecord row ->
            let
                ( fields2, r1, st1 ) =
                    freshenFields renames row.fields state
            in
            case row.tail of
                REmpty ->
                    ( TRecord { fields = fields2, tail = REmpty }, r1, st1 )

                RVar v ->
                    let
                        ( v2, r2, st2 ) =
                            freshenId r1 v st1
                    in
                    ( TRecord { fields = fields2, tail = RVar v2 }, r2, st2 )


freshenId : Dict Int VarId -> VarId -> Uni.State -> ( VarId, Dict Int VarId, Uni.State )
freshenId renames v state =
    if v.id < 0 then
        case Dict.get v.id renames of
            Just f ->
                ( f, renames, state )

            Nothing ->
                let
                    ( f, st ) =
                        Uni.freshVar v.kind v.flex state
                in
                ( f, Dict.insert v.id f renames, st )

    else
        ( v, renames, state )


freshenList : Dict Int VarId -> List Type -> Uni.State -> ( List Type, Dict Int VarId, Uni.State )
freshenList renames ts state =
    case ts of
        [] ->
            ( [], renames, state )

        t :: rest ->
            let
                ( t2, r1, st1 ) =
                    freshen renames t state

                ( rest2, r2, st2 ) =
                    freshenList r1 rest st1
            in
            ( t2 :: rest2, r2, st2 )


freshenFields : Dict Int VarId -> List ( String, Type ) -> Uni.State -> ( List ( String, Type ), Dict Int VarId, Uni.State )
freshenFields renames fields state =
    case fields of
        [] ->
            ( [], renames, state )

        ( n, t ) :: rest ->
            let
                ( t2, r1, st1 ) =
                    freshen renames t state

                ( rest2, r2, st2 ) =
                    freshenFields r1 rest st1
            in
            ( ( n, t2 ) :: rest2, r2, st2 )



-- ======================= GENERALIZATION =======================


{-| Top-level generalization: quantify every free variable of the type. Flex
markers are preserved (a `FComparable` variable is quantified as-is).
-}
generalize : Type -> Scheme
generalize t =
    { quantifiers = freeVars t, body = t }


{-| Let-generalization: quantify the free variables of `t` that are NOT in the
`rigid` set (the free variables of the enclosing environment).
-}
generalizeAvoiding : List VarId -> Type -> Scheme
generalizeAvoiding rigid t =
    { quantifiers =
        List.filter (\v -> not (memberById v.id rigid)) (freeVars t)
    , body = t
    }


{-| A monomorphic scheme (no quantifiers) — the shape used for lambda-bound and
pattern-bound variables, and for builtin monomorphic schemes.
-}
monoScheme : Type -> Scheme
monoScheme t =
    { quantifiers = [], body = t }



-- ======================= FREE VARIABLES =======================


{-| The free variables of a type, in first-appearance order, INCLUDING
flex-marked variables (unlike `Rep.collectVars`, which skips them for the
pretty-printer's letter assignment).
-}
freeVars : Type -> List VarId
freeVars t =
    dedupeById (collect t [])


freeVarsOfScheme : Scheme -> List VarId
freeVarsOfScheme scheme =
    List.filter (\v -> not (memberById v.id scheme.quantifiers)) (freeVars scheme.body)


freeVarsOfEnv : Env -> List VarId
freeVarsOfEnv env =
    dedupeById
        (List.concatMap freeVarsOfScheme (Dict.values env.values ++ Dict.values env.ctors))


collect : Type -> List VarId -> List VarId
collect t acc =
    case t of
        TVar v ->
            v :: acc

        TCon _ args ->
            List.foldl collect acc args

        TFun a b ->
            -- Left-to-right (argument then result), matching Rep.collectVars.
            collect b (collect a acc)

        TTuple ts ->
            List.foldl collect acc ts

        TRecord row ->
            collectRow row acc


collectRow : Row -> List VarId -> List VarId
collectRow row acc =
    let
        accFields =
            List.foldl (\( _, t ) a -> collect t a) acc row.fields
    in
    case row.tail of
        REmpty ->
            accFields

        RVar v ->
            v :: accFields



-- ======================= ANNOTATION -> TYPE =======================


-- Conversion context: the current (qualified) module for self-type
-- qualification, the generic-name -> var mapping (lazily built), and the next
-- fresh var id (ids reflect first-appearance order).
type alias Ctx =
    { self : String
    , vars : Dict String VarId
    , next : Int
    , step : Int
    }


convert : Ctx -> TA.TypeAnnotation -> ( Type, Ctx )
convert ctx ann =
    case ann of
        TA.GenericType name ->
            let
                ( v, ctx2 ) =
                    typeVar KType name ctx
            in
            ( TVar v, ctx2 )

        TA.Typed (Node _ ( modName, name )) args ->
            let
                ( argTs, ctx2 ) =
                    convertList ctx args
            in
            ( TCon (qualifyTypeName ctx.self modName name) argTs, ctx2 )

        TA.Unit ->
            ( Rep.tUnit, ctx )

        TA.Tupled ts ->
            let
                ( ts2, ctx2 ) =
                    convertList ctx ts
            in
            ( TTuple ts2, ctx2 )

        TA.Record fields ->
            let
                ( fs, ctx2 ) =
                    convertFields ctx fields
            in
            ( TRecord { fields = fs, tail = REmpty }, ctx2 )

        TA.GenericRecord (Node _ tailName) (Node _ recordDef) ->
            let
                ( tv, ctx1 ) =
                    typeVar KRow tailName ctx

                ( fs, ctx2 ) =
                    convertFields ctx1 recordDef
            in
            ( TRecord { fields = fs, tail = RVar tv }, ctx2 )

        TA.FunctionTypeAnnotation left right ->
            let
                ( lt, ctx1 ) =
                    convert ctx (Node.value left)

                ( rt, ctx2 ) =
                    convert ctx1 (Node.value right)
            in
            ( TFun lt rt, ctx2 )


convertList : Ctx -> List (Node TA.TypeAnnotation) -> ( List Type, Ctx )
convertList ctx annos =
    case annos of
        [] ->
            ( [], ctx )

        (Node _ ann) :: rest ->
            let
                ( t, ctx1 ) =
                    convert ctx ann

                ( ts, ctx2 ) =
                    convertList ctx1 rest
            in
            ( t :: ts, ctx2 )


convertFields : Ctx -> List (Node TA.RecordField) -> ( List ( String, Type ), Ctx )
convertFields ctx fields =
    case fields of
        [] ->
            ( [], ctx )

        (Node _ ( nameNode, typeNode )) :: rest ->
            let
                ( t, ctx1 ) =
                    convert ctx (Node.value typeNode)

                ( fs, ctx2 ) =
                    convertFields ctx1 rest
            in
            ( ( nodeString nameNode, t ) :: fs, ctx2 )


-- Resolve a (possibly unqualified) type name to its qualified form. Builtin
-- value types keep their bare spelling; the Prelude ADTs (Maybe/Result/Order)
-- get the "Prelude." prefix; anything else unqualified is the current module's
-- own type.
--
-- NOTE (S6 gap): cross-module UNQUALIFIED opaque type references (Array.elm's
-- `JsArray`) do not resolve here — the Infer/Env wiring must add a shared
-- bare-type-name table before the full core-libs corpus is checked.
qualifyTypeName : String -> List String -> String -> String
qualifyTypeName self modName name =
    if not (List.isEmpty modName) then
        String.join "." (modName ++ [ name ])

    else
        case name of
            "Int" ->
                "Int"

            "Float" ->
                "Float"

            "Bool" ->
                "Bool"

            "Char" ->
                "Char"

            "String" ->
                "String"

            "List" ->
                "List"

            "Never" ->
                "Never"

            "Maybe" ->
                "Prelude.Maybe"

            "Result" ->
                "Prelude.Result"

            "Order" ->
                "Prelude.Order"

            _ ->
                self ++ "." ++ name


-- Lazily create (or fetch) the var for a generic name. `kind` is the use
-- position's kind (KRow only for a GenericRecord tail); first use wins if a
-- name is somehow used at two kinds.
typeVar : Kind -> String -> Ctx -> ( VarId, Ctx )
typeVar kind name ctx =
    case Dict.get name ctx.vars of
        Just v ->
            ( v, ctx )

        Nothing ->
            let
                v =
                    Rep.var ctx.next kind (specialFlex name)
            in
            ( v, { ctx | vars = Dict.insert name v ctx.vars, next = ctx.next + ctx.step } )


specialFlex : String -> Flex
specialFlex name =
    if name == "number" then
        FNumber

    else if name == "appendable" then
        FAppendable

    else if String.startsWith "comparable" name then
        FComparable

    else
        FNone



-- ======================= RENAMING =======================


-- Substitute fresh variables for quantified ones. Hand-written (not
-- `Rep.zonk`) because zonk does not rename a ROW variable bound to a TVar — it
-- only splices `TRecord` bindings — and scheme instantiation must rename row
-- tails (e.g. `forall r. { x : Int | r }`).
rename : Dict Int VarId -> Type -> Type
rename m t =
    case t of
        TVar v ->
            case Dict.get v.id m of
                Just f ->
                    TVar f

                Nothing ->
                    TVar v

        TCon name args ->
            TCon name (List.map (rename m) args)

        TFun a b ->
            TFun (rename m a) (rename m b)

        TTuple ts ->
            TTuple (List.map (rename m) ts)

        TRecord row ->
            TRecord (renameRow m row)


renameRow : Dict Int VarId -> Row -> Row
renameRow m row =
    { fields = List.map (\( n, t ) -> ( n, rename m t )) row.fields
    , tail =
        case row.tail of
            REmpty ->
                REmpty

            RVar v ->
                case Dict.get v.id m of
                    Just f ->
                        RVar f

                    Nothing ->
                        RVar v
    }



-- ======================= HELPERS =======================


nodeString : Node String -> String
nodeString (Node _ s) =
    s


memberById : Int -> List VarId -> Bool
memberById id vars =
    List.any (\v -> v.id == id) vars


dedupeById : List VarId -> List VarId
dedupeById xs =
    List.foldl
        (\v acc ->
            if memberById v.id acc then
                acc

            else
                acc ++ [ v ]
        )
        []
        xs
