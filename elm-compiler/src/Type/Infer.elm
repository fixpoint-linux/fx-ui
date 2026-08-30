module Type.Infer exposing ( inferUnit, CheckedUnit )

{-| Algorithm W over `Node Expression`/`Node Pattern`, reusing `Type.Unify`
state threading (`Uni.State{ subst, fresh }`).

This pass infers a type for every top-level function in a single module
(treated as ONE recursive group, order-independent), checks each body against
its signature (or a fresh mono variable for unsignatured definitions), and
EMITS the three surgical AST rewrites the lowerer needs:

  1. `a ++ b`  ->  `String.append a b` / `List.append a b`, chosen by zonking
     the site's `appendable` variable at the end of the declaration
     (still-flex -> `ambiguous (++)`).  `List.append` takes ANY element type.
  2. `Record.remove '<lit>' r`  ->  `Prelude.removeFieldImpl "<lit>" r`
     (the label literal is normalized to a `String`).
  3. `InsertionValue e`  ->  `e`  (an insertion setter RHS unwraps to its
     inner expression; insertion and update lower identically = prepend).

The rewritten `File` is returned so `Lower.Module.compileSources` (S6) can
lower it unchanged.

Name resolution mirrors `Lower.Expr` (local scope -> alias-table rows
first-match -> globals membership -> self-qualified fallback), sharing
`Lower.Module.aliasTableFor`/`exportedNames` so the two passes cannot drift.

Type aliases are transparent: a `TCon` whose name is a registered alias is
expanded (row-kind generics splice into row-tail positions via `zonk`).

This module is pure Elm (elm/core + elm-syntax + the Type.* modules + the
shared Lower.Module alias tables).

-}

import Dict exposing (Dict)
import Elm.Syntax.Declaration as Declaration exposing (Declaration(..))
import Elm.Syntax.Expression as Expression exposing ( Expression(..), Function, Case, RecordSetter, LetDeclaration(..) )
import Elm.Syntax.File as File
import Elm.Syntax.Module as SyntaxModule
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..), QualifiedNameRef)
import Elm.Syntax.Range as Range exposing (Range)
import Lower.Resolve as LowerModule
import Type.Builtins as Builtins
import Type.Env as Env exposing (Scheme, Env)
import Type.Error as Error exposing (TypeError)
import Type.Representation as Rep exposing (Flex(..), Kind(..), Row, RowTail(..), Type(..), VarId)
import Type.Unify as Uni



-- ======================= PUBLIC API =======================


{-| A checked + rewritten unit: the rewritten `File` (ready to lower) and the
unit's value schemes (qualified `"Mod.name"` keys) for merging into the global
environment for downstream units.
-}
type alias CheckedUnit =
    { file : File.File
    , schemes : List ( String, Scheme )
    }


{-| Infer + rewrite one module. `env` is the MERGED environment (all units'
signatures, ADT constructors, and aliases — `Env.collectFile`/`Env.merge`);
it must already contain this unit's own signatures/ctors/aliases.
-}
inferUnit : Env -> File.File -> Result TypeError CheckedUnit
inferUnit env file =
    let
        self =
            moduleNameOf file

        selfStr =
            joinName self

        fnDecls =
            List.filterMap
                (\nd ->
                    case Node.value nd of
                        FunctionDeclaration _ ->
                            Just nd

                        _ ->
                            Nothing
                )
                file.declarations

        groups =
            groupFnDecls fnDecls

        names =
            List.map Tuple.first groups

        definedNames =
            names ++ ctorNames file.declarations

        exported =
            LowerModule.exportedNames file.moduleDefinition definedNames

        aliasTable =
            LowerModule.aliasTableFor self exported file.imports

        ( top, unsignatured, state0 ) =
            seedTop env selfStr names Uni.emptyState

        ctx =
            { self = self
            , env = env
            , envFree = Env.freeVarsOfEnv env
            , top = top
            , locals = []
            , aliasTable = aliasTable
            }

        refs name =
            refsOf self names groups name

        sccs =
            sccOrder names refs
    in
    -- Check the unit's top-level groups in DEPENDENCY order (SCCs), generalizing
    -- each non-recursive SCC before its dependents are checked — the authentic
    -- HM/Elm treatment (a helper used at many types, like `show`, must be
    -- polymorphic at its use sites; only mutually-recursive SCCs stay mono).
    checkSccs ctx unsignatured groups sccs { uni = state0, appends = [] }
        |> Result.map
            (\( rewritten, finalTop, _ ) ->
                { file = rebuildFile rewritten file
                , schemes =
                    List.map (\( n, s ) -> ( selfStr ++ "." ++ n, s )) (Dict.toList finalTop)
                }
            )



-- ======================= INFERENCE MONAD =======================


{-| Inference state: the unification state (substitution + fresh counter) plus
the pending `++` sites accumulated while typing the current clause body.
-}
type alias InferState =
    { uni : Uni.State
    , appends : List AppendSite
    }


{-| A pending `++` application: the `appendable` variable to zonk, the source
range of the `++` node, and its (un-rewritten) operand nodes.
-}
type alias AppendSite =
    { var : VarId
    , range : Range
    , left : Node Expression
    , right : Node Expression
    }


{-| A monadic action threading `InferState` and failing with a `TypeError`.
-}
type alias M a =
    InferState -> Result TypeError ( a, InferState )


emptyInferState : InferState
emptyInferState =
    { uni = Uni.emptyState, appends = [] }


ok : a -> M a
ok a state =
    Ok ( a, state )


fail : TypeError -> M a
fail err _ =
    Err err


-- Flipped bind, so `m |> andThen (\a -> ...)` reads as `andThen (\a -> ...) m`.
andThen : (a -> M b) -> M a -> M b
andThen f m state =
    case m state of
        Err err ->
            Err err

        Ok ( a, state2 ) ->
            f a state2


map : (a -> b) -> M a -> M b
map f m =
    andThen (\a -> ok (f a)) m


mapM : (a -> M b) -> List a -> M (List b)
mapM f xs =
    case xs of
        [] ->
            ok []

        x :: rest ->
            f x
                |> andThen (\b -> mapM f rest |> map (\bs -> b :: bs))


foldM : (a -> b -> M b) -> b -> List a -> M b
foldM f acc xs =
    case xs of
        [] ->
            ok acc

        x :: rest ->
            f x acc
                |> andThen (\acc2 -> foldM f acc2 rest)


fresh : Kind -> Flex -> M VarId
fresh kind flex state =
    let
        ( v, uni2 ) =
            Uni.freshVar kind flex state.uni
    in
    Ok ( v, { state | uni = uni2 } )


instantiate : Env -> Range -> Scheme -> M Type
instantiate env range scheme state =
    let
        ( t, uni2 ) =
            Env.instantiate scheme state.uni
    in
    case Env.expandAliases env t uni2 of
        Err msg ->
            Err (Error.atRange range msg "")

        Ok ( expanded, uni3 ) ->
            Ok ( expanded, { state | uni = uni3 } )


zonkM : Type -> M Type
zonkM t state =
    Ok ( Rep.zonk state.uni.subst t, state )


unifyM : Range -> Type -> Type -> M ()
unifyM range t1 t2 state =
    case Uni.unify state.uni t1 t2 of
        Err err ->
            Err (Error.atRange range (Uni.describe err) "")

        Ok uni2 ->
            Ok ( (), { state | uni = uni2 } )


recordAppend : AppendSite -> M ()
recordAppend site state =
    Ok ( (), { state | appends = site :: state.appends } )


resetAppends : M ()
resetAppends state =
    Ok ( (), { state | appends = [] } )



-- ======================= CONTEXT & RESOLUTION =======================


{-| The checking context: the current module name, the merged environment, the
unit's own top-level bindings (bare name -> scheme, seeded up front), the local
scope (innermost first), and the shared alias table.
-}
type alias Ctx =
    { self : List String
    , env : Env
    , envFree : List VarId
    , top : Dict String Scheme
    , locals : List ( String, Scheme )
    , aliasTable : List ( String, String )
    }


lookupLocal : String -> List ( String, Scheme ) -> Maybe Scheme
lookupLocal name locals =
    case locals of
        [] ->
            Nothing

        ( n, s ) :: rest ->
            if n == name then
                Just s

            else
                lookupLocal name rest


{-| Resolve a (possibly qualified) value/constructor reference to its scheme,
mirroring `Lower.Expr`'s resolution order. `Nothing` = unknown name.
-}
resolveScheme : Ctx -> List String -> String -> Maybe Scheme
resolveScheme ctx modName name =
    if List.isEmpty modName then
        case lookupLocal name ctx.locals of
            Just s ->
                Just s

            Nothing ->
                case Dict.get name ctx.top of
                    Just s ->
                        Just s

                    Nothing ->
                        resolveTokenScheme ctx name

    else if modName == ctx.self then
        -- Self-qualified reference: resolves to the unit's own TOP-LEVEL
        -- binding (like a bare name, but a local `SelfQual.x` is not allowed
        -- to reach a let-bound x).  Check the top group first — an
        -- unsignatured self function lives there, not in the env.
        case Dict.get name ctx.top of
            Just s ->
                Just s

            Nothing ->
                resolveGlobalScheme (joinName (ctx.self ++ [ name ])) ctx

    else
        resolveTokenScheme ctx (joinName (modName ++ [ name ]))


resolveTokenScheme : Ctx -> String -> Maybe Scheme
resolveTokenScheme ctx token =
    case resolveImport token ctx.aliasTable of
        Just key ->
            resolveGlobalScheme key ctx

        Nothing ->
            case resolveGlobalScheme token ctx of
                Just s ->
                    Just s

                Nothing ->
                    resolveGlobalScheme (joinName (ctx.self ++ [ token ])) ctx


resolveGlobalScheme : String -> Ctx -> Maybe Scheme
resolveGlobalScheme key ctx =
    case Builtins.lookupValue key of
        Just s ->
            Just s

        Nothing ->
            Env.lookupValue key ctx.env


resolveImport : String -> List ( String, String ) -> Maybe String
resolveImport name rows =
    case rows of
        [] ->
            Nothing

        ( alias, target ) :: rest ->
            if alias == name then
                Just target

            else
                resolveImport name rest


{-| Resolve + instantiate a value/constructor reference to a mono type.
-}
resolveValue : Ctx -> Range -> List String -> String -> M Type
resolveValue ctx range modName name =
    if List.isEmpty modName && (name == "True" || name == "False") then
        ok Rep.tBool

    else if modName == [ "Record" ] && name == "remove" then
        -- `Record.remove` only typechecks through the magic 2-argument literal
        -- surface in `inferExpr`; used as a value or partially applied it is
        -- not in `Builtins.valueTable`, so give a clear diagnostic instead of
        -- the misleading "unknown name: Record.remove".
        fail (Error.atRange range "Record.remove must be fully applied with a literal field name" "")

    else
        case resolveScheme ctx modName name of
            Just scheme ->
                instantiate ctx.env range scheme

            Nothing ->
                fail (Error.atRange range ("unknown name: " ++ joinName (modName ++ [ name ])) "")


{-| The scheme of an operator used as a value (`(+)`, `(++)`, ...).
-}
resolveOperator : Env -> Range -> String -> M Type
resolveOperator env range op =
    case Builtins.operatorScheme op of
        Just scheme ->
            instantiate env range scheme

        Nothing ->
            fail (Error.atRange range ("unsupported operator: " ++ op) "")


{-| Free variables of the enclosing environment (globals + top-level group +
locals) — the rigid set for let-generalization.
-}
scopeFreeVars : Ctx -> List VarId
scopeFreeVars ctx =
    -- `ctx.envFree` is the free variables of the merged environment, computed
    -- ONCE per unit (they are fixed during a unit's checking) — recomputing
    -- them per let-binding over the ~4KLOC core-libs corpus was the S5
    -- deferred hot spot.
    dedupeIds
        (ctx.envFree
            ++ List.concatMap (Env.freeVarsOfScheme << Tuple.second) ctx.locals
            ++ List.concatMap Env.freeVarsOfScheme (Dict.values ctx.top)
        )



-- ======================= EXPRESSIONS =======================


inferExpr : Ctx -> Node Expression -> M Type
inferExpr ctx (Node range expr) =
    case expr of
        UnitExpr ->
            ok Rep.tUnit

        Integer _ ->
            fresh KType FNumber |> map TVar

        Hex _ ->
            fresh KType FNumber |> map TVar

        Floatable _ ->
            ok Rep.tFloat

        Literal _ ->
            ok Rep.tString

        CharLiteral _ ->
            ok Rep.tChar

        FunctionOrValue modName name ->
            resolveValue ctx range modName name

        PrefixOperator op ->
            resolveOperator ctx.env range op

        Operator op ->
            resolveOperator ctx.env range op

        Negation inner ->
            fresh KType FNumber
                |> andThen (\n ->
                    inferExpr ctx inner
                        |> andThen (\it ->
                            unifyM range it (TVar n)
                                |> map (\_ -> TVar n)
                        )
                )

        ParenthesizedExpression inner ->
            inferExpr ctx inner

        Application nodes ->
            case nodes of
                [] ->
                    fail (Error.atRange range "empty application" "")

                head :: args ->
                    if isRecordRemove head args then
                        inferRecordRemove ctx range args

                    else
                        inferExpr ctx head
                            |> andThen (\ft ->
                                inferExprs ctx args
                                    |> andThen (\argTypes -> applyTypes range ft argTypes)
                            )

        OperatorApplication op _ left right ->
            if op == "++" then
                inferAppend ctx range left right

            else
                resolveOperator ctx.env range op
                    |> andThen (\opType ->
                        inferExpr ctx left
                            |> andThen (\lt ->
                                inferExpr ctx right
                                    |> andThen (\rt -> applyTypes range opType [ lt, rt ])
                            )
                    )

        IfBlock c t e ->
            inferExpr ctx c
                |> andThen (\ct ->
                    unifyM range ct Rep.tBool
                        |> andThen (\_ ->
                            inferExpr ctx t
                                |> andThen (\tt ->
                                    inferExpr ctx e
                                        |> andThen (\te ->
                                            unifyM range tt te |> map (\_ -> tt)
                                        )
                                )
                        )
                )

        LambdaExpression lam ->
            inferPatterns ctx lam.args
                |> andThen (\( argTypes, binds ) ->
                    inferExpr { ctx | locals = binds ++ ctx.locals } lam.expression
                        |> map (\bt -> List.foldr TFun bt argTypes)
                )

        LetExpression block ->
            inferLet ctx block.declarations
                |> andThen (\ctx2 -> inferExpr ctx2 block.expression)

        CaseExpression block ->
            inferExpr ctx block.expression
                |> andThen (\st ->
                    fresh KType FNone
                        |> andThen (\resultVar ->
                            mapM (inferCaseClause ctx st resultVar) block.cases
                                |> map (\_ -> TVar resultVar)
                        )
                )

        RecordExpr setters ->
            foldM
                (\setter fields ->
                    inferExpr ctx (setterValue setter)
                        |> map (\t -> fields ++ [ ( nodeString (setterField setter), t ) ])
                )
                []
                setters
                |> map (\fields -> TRecord { fields = fields, tail = REmpty })

        ListExpr xs ->
            fresh KType FNone
                |> andThen (\elem ->
                    inferExprs ctx xs
                        |> andThen (\ts ->
                            foldM (\( xr, t ) _ -> unifyM (Node.range xr) t (TVar elem)) ()
                                (List.map2 Tuple.pair xs ts)
                                |> map (\_ -> Rep.tList (TVar elem))
                        )
                )

        TupledExpression xs ->
            inferExprs ctx xs |> map TTuple

        RecordAccess rec nameNode ->
            inferExpr ctx rec
                |> andThen (\rt ->
                    fresh KType FNone
                        |> andThen (\a ->
                            fresh KRow FNone
                                |> andThen (\beta ->
                                    unifyM range rt
                                        (TRecord { fields = [ ( nodeString nameNode, TVar a ) ], tail = RVar beta })
                                        |> map (\_ -> TVar a)
                                )
                        )
                )

        RecordAccessFunction name ->
            let
                field =
                    String.dropLeft 1 name
            in
            fresh KType FNone
                |> andThen (\a ->
                    fresh KRow FNone
                        |> map (\beta ->
                            TFun (TRecord { fields = [ ( field, TVar a ) ], tail = RVar beta }) (TVar a)
                        )
                )

        RecordUpdateExpression baseNode setters ->
            let
                baseName =
                    nodeString baseNode
            in
            case lookupLocal baseName ctx.locals of
                Nothing ->
                    fail (Error.atNode baseNode "record update base must be a local variable" ("cannot update " ++ baseName))

                Just scheme ->
                    instantiate ctx.env (Node.range baseNode) scheme
                        |> andThen (\baseType -> inferSetters ctx baseType setters)

        InsertionValue inner ->
            inferExpr ctx inner

        GLSLExpression _ ->
            fail (Error.atRange range "GLSL is not supported" "")


inferExprs : Ctx -> List (Node Expression) -> M (List Type)
inferExprs ctx nodes =
    mapM (inferExpr ctx) nodes


{-| Apply a function type to argument types by peeling one `TFun` per argument
(with a fresh result variable between steps).  Applying a CONCRETE non-function
to an argument is the arity error; a type variable still unifies against a
fresh `TFun` (an occurs check rejects the infinite `5 3` case).
-}
applyTypes : Range -> Type -> List Type -> M Type
applyTypes range fn args =
    case args of
        [] ->
            ok fn

        a :: rest ->
            zonkM fn
                |> andThen
                    (\zfn ->
                        case zfn of
                            TVar _ ->
                                applyStep range zfn a rest

                            TFun _ _ ->
                                applyStep range zfn a rest

                            _ ->
                                fail (Error.atRange range "apply non-function" ("cannot apply " ++ Rep.pretty zfn ++ " to an argument"))
                    )


applyStep : Range -> Type -> Type -> List Type -> M Type
applyStep range fn a rest =
    fresh KType FNone
        |> andThen (\res ->
            unifyM range fn (TFun a (TVar res))
                |> andThen (\_ -> applyTypes range (TVar res) rest)
        )


inferAppend : Ctx -> Range -> Node Expression -> Node Expression -> M Type
inferAppend ctx range left right =
    fresh KType FAppendable
        |> andThen (\a ->
            inferExpr ctx left
                |> andThen (\lt ->
                    inferExpr ctx right
                        |> andThen (\rt ->
                            unifyM range lt (TVar a)
                                |> andThen (\_ ->
                                    unifyM range rt (TVar a)
                                        |> andThen (\_ ->
                                            recordAppend { var = a, range = range, left = left, right = right }
                                                |> map (\_ -> TVar a)
                                        )
                                )
                        )
                )
        )


{-| Is this application the magic `Record.remove <lit> r` surface?
-}
isRecordRemove : Node Expression -> List (Node Expression) -> Bool
isRecordRemove head args =
    case ( Node.value head, args ) of
        ( FunctionOrValue [ "Record" ] "remove", [ labelNode, _ ] ) ->
            case Node.value labelNode of
                Literal _ ->
                    True

                CharLiteral _ ->
                    True

                _ ->
                    False

        _ ->
            False


inferRecordRemove : Ctx -> Range -> List (Node Expression) -> M Type
inferRecordRemove ctx range args =
    case args of
        [ labelNode, recNode ] ->
            case labelString labelNode of
                Nothing ->
                    fail (Error.atRange range "Record.remove requires a literal field name" "")

                Just l ->
                    inferExpr ctx recNode
                        |> andThen (\rt ->
                            zonkM rt
                                |> andThen
                                    (\zrt ->
                                        case zrt of
                                            TRecord row ->
                                                case restrictField l row of
                                                    Nothing ->
                                                        fail (Error.atNode labelNode ("record does not have field " ++ l) "")

                                                    Just ( _, remainder ) ->
                                                        ok (TRecord remainder)

                                            _ ->
                                                fail (Error.atNode recNode "Record.remove expects a record" "")
                                    )
                        )

        _ ->
            fail (Error.atRange range "Record.remove expects a field and a record" "")


labelString : Node Expression -> Maybe String
labelString (Node _ e) =
    case e of
        Literal s ->
            Just s

        CharLiteral c ->
            Just (String.fromChar c)

        _ ->
            Nothing


{-| Infer a record update/insertion's setters sequentially.  An `InsertionValue`
RHS is a free extension (may duplicate); any other RHS is an update
(restrict+extend: the label MUST already exist).
-}
inferSetters : Ctx -> Type -> List (Node RecordSetter) -> M Type
inferSetters ctx baseType setters =
    case setters of
        [] ->
            ok baseType

        setter :: rest ->
            inferSetter ctx baseType setter
                |> andThen (\newBase -> inferSetters ctx newBase rest)


inferSetter : Ctx -> Type -> Node RecordSetter -> M Type
inferSetter ctx baseType (Node r ( fieldNode, valNode )) =
    let
        f =
            nodeString fieldNode
    in
    case Node.value valNode of
        InsertionValue inner ->
            inferExpr ctx inner
                |> andThen (\tv ->
                    zonkM baseType
                        |> andThen (\zb -> ensureRecordForInsert r zb |> map (\row -> TRecord { fields = ( f, tv ) :: row.fields, tail = row.tail }))
                )

        _ ->
            inferExpr ctx valNode
                |> andThen (\tv ->
                    zonkM baseType
                        |> andThen
                            (\zb ->
                                case zb of
                                    TRecord row ->
                                        case restrictField f row of
                                            Nothing ->
                                                fail (Error.atNode fieldNode ("record does not have field " ++ f) "")

                                            Just ( oldT, remainder ) ->
                                                unifyM r tv oldT
                                                    |> map (\_ -> TRecord { fields = ( f, tv ) :: remainder.fields, tail = remainder.tail })

                                    -- An unbound base variable is constrained to
                                    -- carry the field (Elm's own behavior for
                                    -- `{ p | x = v }` with a fresh `p`).
                                    TVar v ->
                                        fresh KType FNone
                                            |> andThen (\tf ->
                                                fresh KRow FNone
                                                    |> andThen (\beta ->
                                                        unifyM r (TVar v) (TRecord { fields = [ ( f, TVar tf ) ], tail = RVar beta })
                                                            |> andThen (\_ ->
                                                                unifyM r tv (TVar tf)
                                                                    |> map (\_ -> TRecord { fields = [ ( f, tv ) ], tail = RVar beta })
                                                            )
                                                    )
                                            )

                                    _ ->
                                        fail (Error.atNode valNode "expected a record for update" "")
                            )
                )


{-| Ensure a base is a record for INSERTION; an unbound type variable becomes
an open empty record (`{ | beta }`), a concrete record passes through.
-}
ensureRecordForInsert : Range -> Type -> M Row
ensureRecordForInsert range t =
    case t of
        TRecord row ->
            ok row

        TVar v ->
            fresh KRow FNone
                |> andThen (\beta ->
                    let
                        emptyRecord =
                            TRecord { fields = [], tail = RVar beta }
                    in
                    unifyM range (TVar v) emptyRecord
                        |> map (\_ -> { fields = [], tail = RVar beta })
                )

        _ ->
            fail (Error.atRange range "expected a record for insertion" "")


{-| The paper's `restrict`: remove the FIRST concrete occurrence of `l`,
returning its type and the remainder row (inner duplicates are kept).
`Nothing` means `l` is not a concrete field (scoped labels forbid removing an
unknown/tail-only field).
-}
restrictField : String -> Row -> Maybe ( Type, Row )
restrictField l row =
    case row.fields of
        [] ->
            Nothing

        ( l2, t ) :: rest ->
            if l2 == l then
                Just ( t, { fields = rest, tail = row.tail } )

            else
                restrictField l { fields = rest, tail = row.tail }
                    |> Maybe.map
                        (\( ft, remainder ) ->
                            ( ft, { fields = ( l2, t ) :: remainder.fields, tail = remainder.tail } )
                        )


setterField : Node RecordSetter -> Node String
setterField (Node _ ( f, _ )) =
    f


setterValue : Node RecordSetter -> Node Expression
setterValue (Node _ ( _, v )) =
    v



-- ======================= LET =======================


inferLet : Ctx -> List (Node LetDeclaration) -> M Ctx
inferLet ctx decls =
    case decls of
        [] ->
            ok ctx

        d :: rest ->
            inferLetDecl ctx d
                |> andThen (\ctx2 -> inferLet ctx2 rest)


inferLetDecl : Ctx -> Node LetDeclaration -> M Ctx
inferLetDecl ctx (Node _ decl) =
    case decl of
        LetFunction fn ->
            inferLetFunction ctx fn
                |> map (\scheme -> { ctx | locals = ( fnName fn, scheme ) :: ctx.locals })

        LetDestructuring patNode eNode ->
            inferExpr ctx eNode
                |> andThen (\et ->
                    inferPattern ctx patNode
                        |> andThen (\( binds, pt ) ->
                            unifyM (Node.range patNode) pt et
                                |> andThen
                                    (\_ ->
                                        let
                                            rigid =
                                                scopeFreeVars ctx
                                        in
                                        generalizeBinds rigid binds
                                            |> map (\gens -> { ctx | locals = gens ++ ctx.locals })
                                    )
                        )
                )


inferLetFunction : Ctx -> Function -> M Scheme
inferLetFunction ctx fn =
    let
        impl =
            Node.value fn.declaration

        rigid =
            scopeFreeVars ctx
    in
    inferPatterns ctx impl.arguments
        |> andThen (\( argTypes, binds ) ->
            inferExpr { ctx | locals = binds ++ ctx.locals } impl.expression
                |> andThen (\bt ->
                    zonkM (List.foldr TFun bt argTypes)
                        |> map (\zt -> generalizeLet rigid zt)
                )
        )


{-| Generalize a list of destructuring binds.  Each bind's body is ZONKED first:
a pattern variable bound to a CLOSED type (e.g. `let y = h x` with a concrete
record result) would otherwise still look like a free `TVar` (bound in the
substitution) to `freeVars`, get quantified, and re-instantiate to a FRESH var —
losing the concrete record and making a later `{ y | f = ... }` update fail with
"record does not have field f".  Zonking first turns such a body into the closed
record, whose free-variable set is empty, so nothing is quantified.
-}
generalizeBinds : List VarId -> List ( String, Scheme ) -> M (List ( String, Scheme ))
generalizeBinds rigid binds =
    case binds of
        [] ->
            ok []

        ( n, s ) :: rest ->
            zonkM s.body
                |> andThen (\zt -> generalizeBinds rigid rest |> map (\gens -> ( n, generalizeLet rigid zt ) :: gens))


{-| Let-generalization: quantify the free variables of `t` that are not rigid
in the enclosing environment AND are not `appendable` (the zonk exception — an
`appendable` variable stays shared so it can be resolved at the enclosing
declaration's end-of-declaration zonk).
-}
generalizeLet : List VarId -> Type -> Scheme
generalizeLet rigid t =
    { quantifiers =
        Env.freeVars t
            |> List.filter (\v -> not (memberById v.id rigid) && v.flex /= FAppendable)
    , body = t
    }



-- ======================= CASE =======================


inferCaseClause : Ctx -> Type -> VarId -> Case -> M ()
inferCaseClause ctx scrutineeType resultVar ( patNode, bodyNode ) =
    inferPattern ctx patNode
        |> andThen (\( binds, pt ) ->
            unifyM (Node.range patNode) pt scrutineeType
                |> andThen (\_ ->
                    inferExpr { ctx | locals = binds ++ ctx.locals } bodyNode
                        |> andThen (\bt -> unifyM (Node.range bodyNode) bt (TVar resultVar))
                )
        )



-- ======================= PATTERNS =======================


inferPatterns : Ctx -> List (Node Pattern) -> M ( List Type, List ( String, Scheme ) )
inferPatterns ctx pats =
    case pats of
        [] ->
            ok ( [], [] )

        p :: rest ->
            inferPattern ctx p
                |> andThen (\( binds, pt ) ->
                    inferPatterns ctx rest
                        |> map (\( pts, moreBinds ) -> ( pt :: pts, binds ++ moreBinds ))
                )


inferPattern : Ctx -> Node Pattern -> M ( List ( String, Scheme ), Type )
inferPattern ctx (Node r pat) =
    case pat of
        AllPattern ->
            fresh KType FNone |> map (\v -> ( [], TVar v ))

        UnitPattern ->
            ok ( [], Rep.tUnit )

        CharPattern _ ->
            ok ( [], Rep.tChar )

        StringPattern _ ->
            ok ( [], Rep.tString )

        IntPattern _ ->
            ok ( [], Rep.tInt )

        HexPattern _ ->
            ok ( [], Rep.tInt )

        FloatPattern _ ->
            ok ( [], Rep.tFloat )

        VarPattern name ->
            fresh KType FNone |> map (\v -> ( [ ( name, Env.monoScheme (TVar v) ) ], TVar v ))

        TuplePattern ps ->
            inferPatterns ctx ps |> map (\( pts, binds ) -> ( binds, TTuple pts ))

        RecordPattern fields ->
            fresh KRow FNone
                |> andThen
                    (\tail ->
                        foldM
                            (\field ( fieldTypes, binds ) ->
                                fresh KType FNone
                                    |> map
                                        (\v ->
                                            ( fieldTypes ++ [ ( nodeString field, TVar v ) ]
                                            , binds ++ [ ( nodeString field, Env.monoScheme (TVar v) ) ]
                                            )
                                        )
                            )
                            ( [], [] )
                            fields
                            |> map (\( fieldTypes, binds ) -> ( binds, TRecord { fields = fieldTypes, tail = RVar tail } ))
                    )

        UnConsPattern left right ->
            fresh KType FNone
                |> andThen (\elem ->
                    inferPattern ctx left
                        |> andThen (\( lb, lt ) ->
                            unifyM r lt (TVar elem)
                                |> andThen (\_ ->
                                    inferPattern ctx right
                                        |> andThen (\( rb, rt ) ->
                                            unifyM r rt (Rep.tList (TVar elem))
                                                |> map (\_ -> ( lb ++ rb, Rep.tList (TVar elem) ))
                                        )
                                )
                        )
                )

        ListPattern ps ->
            fresh KType FNone
                |> andThen (\elem ->
                    inferPatterns ctx ps
                        |> andThen (\( pts, binds ) ->
                            foldM (\( pr, pt ) _ -> unifyM (Node.range pr) pt (TVar elem)) ()
                                (List.map2 Tuple.pair ps pts)
                                |> map (\_ -> ( binds, Rep.tList (TVar elem) ))
                        )
                )

        NamedPattern qref subpats ->
            resolveCtorType ctx r qref
                |> andThen (\ctorType -> peelCtor ctx subpats ctorType)

        AsPattern inner nameNode ->
            inferPattern ctx inner
                |> map (\( binds, t ) -> ( binds ++ [ ( nodeString nameNode, Env.monoScheme t ) ], t ))

        ParenthesizedPattern inner ->
            inferPattern ctx inner


resolveCtorType : Ctx -> Range -> QualifiedNameRef -> M Type
resolveCtorType ctx range qref =
    if List.isEmpty qref.moduleName && (qref.name == "True" || qref.name == "False") then
        ok Rep.tBool

    else
        case resolveScheme ctx qref.moduleName qref.name of
            Just scheme ->
                instantiate ctx.env range scheme

            Nothing ->
                fail (Error.atRange range ("unknown name: " ++ joinName (qref.moduleName ++ [ qref.name ])) "")


peelCtor : Ctx -> List (Node Pattern) -> Type -> M ( List ( String, Scheme ), Type )
peelCtor ctx subpats ctorType =
    case subpats of
        [] ->
            ok ( [], ctorType )

        p :: rest ->
            case ctorType of
                TFun arg res ->
                    inferPattern ctx p
                        |> andThen (\( binds, pt ) ->
                            unifyM (Node.range p) pt arg
                                |> andThen (\_ ->
                                    peelCtor ctx rest res
                                        |> map (\( more, result ) -> ( binds ++ more, result ))
                                )
                        )

                _ ->
                    fail (Error.atRange (Node.range p) "constructor applied to too many arguments" "")



-- ======================= TOP-LEVEL GROUP =======================


{-| Group `FunctionDeclaration` nodes by (bare) name, preserving clause order.
-}
groupFnDecls : List (Node Declaration) -> List ( String, List (Node Declaration) )
groupFnDecls decls =
    case decls of
        [] ->
            []

        nd :: rest ->
            let
                name =
                    declName nd

                ( same, others ) =
                    List.partition (\d -> declName d == name) rest
            in
            ( name, nd :: same ) :: groupFnDecls others


declName : Node Declaration -> String
declName (Node _ decl) =
    case decl of
        FunctionDeclaration fn ->
            fnName fn

        _ ->
            ""


fnName : Function -> String
fnName fn =
    case fn.declaration of
        Node _ impl ->
            nodeString impl.name


ctorNames : List (Node Declaration) -> List String
ctorNames decls =
    List.concatMap
        (\(Node _ decl) ->
            case decl of
                CustomTypeDeclaration typeDecl ->
                    List.map
                        (\vcNode ->
                            case Node.value vcNode of
                                vc ->
                                    nodeString vc.name
                        )
                        typeDecl.constructors

                _ ->
                    []
        )
        decls


{-| Seed the unit's top-level bindings: signatured names get their (already
generalized) scheme from the merged environment; unsignatured names get a
fresh mono variable (monomorphic recursion, generalized per-SCC — see
`checkSccs`).
-}
seedTop : Env -> String -> List String -> Uni.State -> ( Dict String Scheme, List String, Uni.State )
seedTop env selfStr names state =
    List.foldl (seedOne env selfStr) ( Dict.empty, [], state ) names


seedOne : Env -> String -> String -> ( Dict String Scheme, List String, Uni.State ) -> ( Dict String Scheme, List String, Uni.State )
seedOne env selfStr name ( dict, unsig, state ) =
    case Env.lookupValue (selfStr ++ "." ++ name) env of
        Just scheme ->
            ( Dict.insert name scheme dict, unsig, state )

        Nothing ->
            let
                ( v, st ) =
                    Uni.freshVar KType FNone state
            in
            ( Dict.insert name (Env.monoScheme (TVar v)) dict, name :: unsig, st )


generalizeUnsig : List String -> Dict String Scheme -> Uni.State -> Dict String Scheme
generalizeUnsig names top state =
    List.foldl
        (\n dict ->
            case Dict.get n dict of
                Just scheme ->
                    Dict.insert n (Env.generalize (Rep.zonk state.subst scheme.body)) dict

                Nothing ->
                    dict
        )
        top
        names



-- ======================= SCC ORDER + CHECK =======================
-- Real Elm checks top-level definitions in STRONGLY-CONNECTED-COMPONENT order
-- (dependencies first) and generalizes a non-recursive definition BEFORE its
-- dependents see it.  The previous "one recursive group, generalized at the
-- end" design was too conservative: a helper used at several types in the same
-- unit (e.g. `show` in cmporder) stayed monomorphic and failed to unify its
-- multiple uses.


{-| The top-level names a function's (checked) body references, restricted to
the unit's own top-level names.  Trusted bodies are skipped, so they contribute
NO references — this also breaks the fake cycle `compare <-> cmpList`, where
`compare`'s body is skipped but its signature is already fixed.
-}
refsOf : List String -> List String -> List ( String, List (Node Declaration) ) -> String -> List String
refsOf self names groups name =
    if Builtins.isTrusted (joinName (self ++ [ name ])) then
        []

    else
        case List.filterMap (\( n, cl ) -> if n == name then Just cl else Nothing) groups of
            clauses :: _ ->
                List.concatMap (clauseRefs self names) clauses

            [] ->
                []


clauseRefs : List String -> List String -> Node Declaration -> List String
clauseRefs self names (Node _ decl) =
    case decl of
        FunctionDeclaration fn ->
            fnRefs self names fn

        _ ->
            []


fnRefs : List String -> List String -> Function -> List String
fnRefs self names fn =
    case fn.declaration of
        Node _ impl ->
            collectRefs self names impl.expression


collectRefs : List String -> List String -> Node Expression -> List String
collectRefs self names (Node _ expr) =
    collectRefsExpr self names expr


collectRefsExpr : List String -> List String -> Expression -> List String
collectRefsExpr self names expr =
    case expr of
        FunctionOrValue modName name ->
            if (List.isEmpty modName || modName == self) && List.member name names then
                [ name ]

            else
                []

        Application nodes ->
            List.concatMap (collectRefs self names) nodes

        OperatorApplication _ _ l r ->
            collectRefs self names l ++ collectRefs self names r

        Negation x ->
            collectRefs self names x

        ParenthesizedExpression x ->
            collectRefs self names x

        IfBlock c t e ->
            collectRefs self names c ++ collectRefs self names t ++ collectRefs self names e

        LambdaExpression lam ->
            collectRefs self names lam.expression

        LetExpression lb ->
            List.concatMap (collectRefsLetDecl self names) lb.declarations
                ++ collectRefs self names lb.expression
        CaseExpression cb ->
            collectRefs self names cb.expression
                ++ List.concatMap (\( _, e ) -> collectRefs self names e) cb.cases

        RecordExpr setters ->
            List.concatMap (\(Node _ ( _, v )) -> collectRefs self names v) setters

        ListExpr xs ->
            List.concatMap (collectRefs self names) xs

        TupledExpression xs ->
            List.concatMap (collectRefs self names) xs

        RecordAccess rec _ ->
            collectRefs self names rec

        RecordUpdateExpression _ setters ->
            List.concatMap (\(Node _ ( _, v )) -> collectRefs self names v) setters

        InsertionValue x ->
            collectRefs self names x

        _ ->
            []


collectRefsLetDecl : List String -> List String -> Node LetDeclaration -> List String
collectRefsLetDecl self names (Node _ decl) =
    case decl of
        LetFunction fn ->
            fnRefs self names fn

        LetDestructuring _ e ->
            collectRefs self names e


{-| Compute the SCCs of the top-level names in dependency order (dependencies
first).  A name is ready once every name it references has already been placed;
if nothing is ready but names remain, the remaining names are mutually
recursive and form ONE SCC (a sound over-grouping for the tiny corpus).
-}
sccOrder : List String -> (String -> List String) -> List (List String)
sccOrder names refs =
    sccGo names [] [] refs


sccGo : List String -> List String -> List (List String) -> (String -> List String) -> List (List String)
sccGo remaining placed acc refs =
    case remaining of
        [] ->
            List.reverse acc

        _ ->
            case findReady remaining placed refs of
                Just n ->
                    sccGo (List.filter (\m -> m /= n) remaining) (n :: placed) ([ n ] :: acc) refs

                Nothing ->
                    sccGo [] (placed ++ remaining) (remaining :: acc) refs


findReady : List String -> List String -> (String -> List String) -> Maybe String
findReady remaining placed refs =
    case remaining of
        [] ->
            Nothing

        n :: rest ->
            if List.all (\r -> List.member r placed) (refs n) then
                Just n

            else
                findReady rest placed refs


checkSccs : Ctx -> List String -> List ( String, List (Node Declaration) ) -> List (List String) -> InferState -> Result TypeError ( Dict NodeKey Function, Dict String Scheme, InferState )
checkSccs ctx unsig groups sccs state =
    case sccs of
        [] ->
            Ok ( Dict.empty, ctx.top, state )

        scc :: rest ->
            checkScc ctx scc groups state
                |> Result.andThen
                    (\( dict, s2 ) ->
                        let
                            ctx2 =
                                { ctx | top = generalizeScc scc unsig ctx.top s2.uni }
                        in
                        checkSccs ctx2 unsig groups rest s2
                            |> Result.map (\( dict2, finalTop, s3 ) -> ( Dict.union dict dict2, finalTop, s3 ))
                    )


checkScc : Ctx -> List String -> List ( String, List (Node Declaration) ) -> InferState -> Result TypeError ( Dict NodeKey Function, InferState )
checkScc ctx scc groups state =
    typeClauses ctx (List.concatMap (\( n, cl ) -> if List.member n scc then cl else []) groups) state


generalizeScc : List String -> List String -> Dict String Scheme -> Uni.State -> Dict String Scheme
generalizeScc scc unsig top state =
    generalizeUnsig (List.filter (\n -> List.member n scc) unsig) top state


typeClauses : Ctx -> List (Node Declaration) -> InferState -> Result TypeError ( Dict NodeKey Function, InferState )
typeClauses ctx clauses state =
    case clauses of
        [] ->
            Ok ( Dict.empty, state )

        clause :: rest ->
            typeOneClause ctx clause state
                |> Result.andThen
                    (\( key, fn, s2 ) ->
                        typeClauses ctx rest s2
                            |> Result.map (\( d, s3 ) -> ( Dict.insert key fn d, s3 ))
                    )


typeOneClause : Ctx -> Node Declaration -> InferState -> Result TypeError ( NodeKey, Function, InferState )
typeOneClause ctx node state =
    case node of
        Node r (FunctionDeclaration fn) ->
            case inferClause ctx fn state of
                Err err ->
                    Err err

                Ok ( fn2, s2 ) ->
                    Ok ( keyOf r, fn2, s2 )

        _ ->
            Err (Error.atRange Range.empty "internal: not a function declaration" "")


{-| Peel an (instantiated) signature type into its argument types and result
type.  A concrete `TFun` chain is split directly; a bare type variable (an
unsignatured mono var, possibly already bound by an earlier clause) is unified
against a fresh `arg1 -> ... -> argn -> rest` shape so the split always
succeeds.
-}
peelArity : Range -> Type -> Int -> M ( List Type, Type )
peelArity range t n =
    zonkM t
        |> andThen
            (\zt ->
                case ( n, zt ) of
                    ( 0, _ ) ->
                        ok ( [], zt )

                    ( _, TFun a b ) ->
                        peelArity range b (n - 1)
                            |> map (\( args, res ) -> ( a :: args, res ))

                    ( _, TVar v ) ->
                        fresh KType FNone
                            |> andThen (\a ->
                                fresh KType FNone
                                    |> andThen (\rest ->
                                        unifyM range (TVar v) (TFun (TVar a) (TVar rest))
                                            |> andThen (\_ ->
                                                peelArity range (TVar rest) (n - 1)
                                                    |> map (\( args, res ) -> ( TVar a :: args, res ))
                                            )
                                    )
                            )

                    _ ->
                        fail (Error.atRange range "arity mismatch: too many arguments for the signature" "")
            )


unifyEach : Range -> List Type -> List Type -> M ()
unifyEach range ts1 ts2 =
    case ( ts1, ts2 ) of
        ( [], [] ) ->
            ok ()

        ( t1 :: r1, t2 :: r2 ) ->
            unifyM range t1 t2
                |> andThen (\_ -> unifyEach range r1 r2)

        _ ->
            fail (Error.atRange range "arity mismatch" "")


inferClause : Ctx -> Function -> M Function
inferClause ctx fn =
    let
        impl =
            Node.value fn.declaration

        name =
            nodeString impl.name

        qualified =
            joinName (ctx.self ++ [ name ])
    in
    if Builtins.isTrusted qualified then
        -- Trusted body (e.g. Prelude.removeFieldImpl): skip inference AND
        -- rewriting; its call-site scheme comes from Type.Builtins (the
        -- record-removal impl pattern-matches a record as a raw assoc list,
        -- which the TRecord-typed checker must never see).
        ok fn

    else
        case Dict.get name ctx.top of
            Nothing ->
                fail (Error.atRange (Node.range fn.declaration) ("internal: unseeded top-level name " ++ name) "")

            Just scheme ->
                instantiate ctx.env (Node.range fn.declaration) scheme
                    |> andThen (\expected ->
                        inferPatterns ctx impl.arguments
                            |> andThen (\( argTypes, binds ) ->
                                peelArity (Node.range fn.declaration) expected (List.length argTypes)
                                    |> andThen (\( argExpecteds, resultExpected ) ->
                                        -- Annotation-directed: constrain each pattern
                                        -- arg by the signature BEFORE the body, so a
                                        -- signatured record update sees the concrete
                                        -- field set (and can raise "does not have
                                        -- field x") instead of an unbound variable.
                                        unifyEach (Node.range fn.declaration) argTypes argExpecteds
                                            |> andThen (\_ ->
                                                let
                                                    ctx2 =
                                                        { ctx | locals = binds ++ ctx.locals }
                                                in
                                                resetAppends
                                                    |> andThen (\_ ->
                                                        inferExpr ctx2 impl.expression
                                                            |> andThen (\bodyType ->
                                                                unifyM (Node.range fn.declaration) bodyType resultExpected
                                                                    |> andThen (\_ ->
                                                                        resolveAppends
                                                                            |> andThen (\siteMap ->
                                                                                checkNoResidualAppendable (Node.range fn.declaration) (List.foldr TFun bodyType argTypes)
                                                                                    |> map
                                                                                        (\_ ->
                                                                                            { fn
                                                                                                | declaration =
                                                                                                    Node (Node.range fn.declaration)
                                                                                                        { impl | expression = rewriteExpr siteMap impl.expression }
                                                                                            }
                                                                                        )
                                                                            )
                                                                    )
                                                            )
                                                    )
                                            )
                                    )
                            )
                    )



-- ======================= APPENDABLE ZONK & REWRITES =======================


type alias SiteMap =
    Dict NodeKey ( String, Node Expression, Node Expression )


resolveAppends : M SiteMap
resolveAppends state =
    resolveSites state.appends Dict.empty state


resolveSites : List AppendSite -> SiteMap -> InferState -> Result TypeError ( SiteMap, InferState )
resolveSites sites acc state =
    case sites of
        [] ->
            Ok ( acc, { state | appends = [] } )

        site :: rest ->
            case Rep.zonk state.uni.subst (TVar site.var) of
                TCon "String" [] ->
                    resolveSites rest (Dict.insert (keyOf site.range) ( "String.append", site.left, site.right ) acc) state

                TCon "List" _ ->
                    resolveSites rest (Dict.insert (keyOf site.range) ( "List.append", site.left, site.right ) acc) state

                _ ->
                    Err (Error.atRange site.range "ambiguous (++)" "")


checkNoResidualAppendable : Range -> Type -> M ()
checkNoResidualAppendable range t state =
    case residualAppendable (Rep.zonk state.uni.subst t) of
        Just v ->
            Err (Error.atRange range "ambiguous (++)" ("cannot resolve appendable of type " ++ Rep.pretty (TVar v)))

        Nothing ->
            Ok ( (), state )


residualAppendable : Type -> Maybe VarId
residualAppendable t =
    case t of
        TVar v ->
            if v.flex == FAppendable then
                Just v

            else
                Nothing

        TCon _ args ->
            firstJust (List.map residualAppendable args)

        TFun a b ->
            firstJust [ residualAppendable a, residualAppendable b ]

        TTuple ts ->
            firstJust (List.map residualAppendable ts)

        TRecord row ->
            firstJust (List.map (residualAppendable << Tuple.second) row.fields)


{-| The phase-2 rewrite: replace resolved `++` sites, `Record.remove`
applications, and unwrap `InsertionValue` markers (recursively).
-}
rewriteExpr : SiteMap -> Node Expression -> Node Expression
rewriteExpr sites (Node range expr) =
    case expr of
        InsertionValue inner ->
            rewriteExpr sites inner

        _ ->
            case Dict.get (keyOf range) sites of
                Just ( appendFn, left, right ) ->
                    Node range
                        (Application
                            [ Node.empty (FunctionOrValue [] appendFn)
                            , rewriteExpr sites left
                            , rewriteExpr sites right
                            ]
                        )

                Nothing ->
                    Node range (rewriteExprValue sites expr)


rewriteExprValue : SiteMap -> Expression -> Expression
rewriteExprValue sites expr =
    case expr of
        UnitExpr ->
            UnitExpr

        Application nodes ->
            case recordRemoveArgs nodes of
                Just ( labelNode, recNode ) ->
                    Application
                        [ Node.empty (FunctionOrValue [ "Prelude" ] "removeFieldImpl")
                        , labelNode
                        , rewriteExpr sites recNode
                        ]

                Nothing ->
                    Application (List.map (rewriteExpr sites) nodes)

        OperatorApplication op dir l r ->
            OperatorApplication op dir (rewriteExpr sites l) (rewriteExpr sites r)

        FunctionOrValue m n ->
            FunctionOrValue m n

        IfBlock c t e ->
            IfBlock (rewriteExpr sites c) (rewriteExpr sites t) (rewriteExpr sites e)

        PrefixOperator op ->
            PrefixOperator op

        Operator op ->
            Operator op

        Integer n ->
            Integer n

        Hex n ->
            Hex n

        Floatable f ->
            Floatable f

        Negation x ->
            Negation (rewriteExpr sites x)

        Literal s ->
            Literal s

        CharLiteral c ->
            CharLiteral c

        TupledExpression xs ->
            TupledExpression (List.map (rewriteExpr sites) xs)

        ParenthesizedExpression x ->
            ParenthesizedExpression (rewriteExpr sites x)

        LetExpression lb ->
            LetExpression
                { declarations = List.map (rewriteLetDecl sites) lb.declarations
                , expression = rewriteExpr sites lb.expression
                }

        CaseExpression cb ->
            CaseExpression
                { expression = rewriteExpr sites cb.expression
                , cases = List.map (\( p, e ) -> ( p, rewriteExpr sites e )) cb.cases
                }

        LambdaExpression lam ->
            LambdaExpression { args = lam.args, expression = rewriteExpr sites lam.expression }

        RecordExpr setters ->
            RecordExpr (List.map (rewriteSetter sites) setters)

        ListExpr xs ->
            ListExpr (List.map (rewriteExpr sites) xs)

        RecordAccess rec n ->
            RecordAccess (rewriteExpr sites rec) n

        RecordAccessFunction n ->
            RecordAccessFunction n

        RecordUpdateExpression base setters ->
            RecordUpdateExpression base (List.map (rewriteSetter sites) setters)

        InsertionValue x ->
            Node.value (rewriteExpr sites x)

        GLSLExpression s ->
            GLSLExpression s


recordRemoveArgs : List (Node Expression) -> Maybe ( Node Expression, Node Expression )
recordRemoveArgs nodes =
    case nodes of
        headNode :: labelNode :: recNode :: [] ->
            case ( Node.value headNode, Node.value labelNode ) of
                ( FunctionOrValue [ "Record" ] "remove", Literal s ) ->
                    Just ( Node (Node.range labelNode) (Literal s), recNode )

                ( FunctionOrValue [ "Record" ] "remove", CharLiteral c ) ->
                    Just ( Node (Node.range labelNode) (Literal (String.fromChar c)), recNode )

                _ ->
                    Nothing

        _ ->
            Nothing


rewriteSetter : SiteMap -> Node RecordSetter -> Node RecordSetter
rewriteSetter sites (Node r ( field, val )) =
    Node r ( field, rewriteExpr sites val )


rewriteLetDecl : SiteMap -> Node LetDeclaration -> Node LetDeclaration
rewriteLetDecl sites (Node r decl) =
    Node r
        (case decl of
            LetFunction fn ->
                LetFunction (rewriteFnExpr sites fn)

            LetDestructuring pat e ->
                LetDestructuring pat (rewriteExpr sites e)
        )


rewriteFnExpr : SiteMap -> Function -> Function
rewriteFnExpr sites fn =
    case fn.declaration of
        Node r impl ->
            { fn | declaration = Node r { impl | expression = rewriteExpr sites impl.expression } }



-- ======================= FILE REBUILD =======================


rebuildFile : Dict NodeKey Function -> File.File -> File.File
rebuildFile rewritten file =
    { file | declarations = List.map (rewriteDecl rewritten) file.declarations }


rewriteDecl : Dict NodeKey Function -> Node Declaration -> Node Declaration
rewriteDecl rewritten (Node r decl) =
    case decl of
        FunctionDeclaration fn ->
            case Dict.get (keyOf r) rewritten of
                Just fn2 ->
                    Node r (FunctionDeclaration fn2)

                Nothing ->
                    Node r decl

        _ ->
            Node r decl



-- ======================= HELPERS =======================


moduleNameOf : File.File -> List String
moduleNameOf file =
    case file.moduleDefinition of
        Node _ modDef ->
            SyntaxModule.moduleName modDef


nodeString : Node String -> String
nodeString (Node _ s) =
    s


joinName : List String -> String
joinName =
    String.join "."


{-| A node identity key: the node's FULL range (start + end).  The START alone
is not unique (a parent node's range starts where its leftmost child's does),
which would make `++`-site matching rewrite the wrong node and loop.
-}
type alias NodeKey =
    String


keyOf : Range -> NodeKey
keyOf range =
    String.fromInt range.start.row
        ++ ":"
        ++ String.fromInt range.start.column
        ++ "-"
        ++ String.fromInt range.end.row
        ++ ":"
        ++ String.fromInt range.end.column


memberById : Int -> List VarId -> Bool
memberById id vars =
    List.any (\v -> v.id == id) vars


dedupeIds : List VarId -> List VarId
dedupeIds xs =
    List.foldl (\v acc -> if memberById v.id acc then acc else acc ++ [ v ]) [] xs


firstJust : List (Maybe a) -> Maybe a
firstJust xs =
    case xs of
        [] ->
            Nothing

        Just a :: _ ->
            Just a

        Nothing :: rest ->
            firstJust rest
