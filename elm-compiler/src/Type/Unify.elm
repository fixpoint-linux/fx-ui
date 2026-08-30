module Type.Unify exposing
    ( UnifyError(..)
    , State
    , emptyState
    , freshVar
    , unify
    , describe
    )

{-| Row/type unification: Robinson unification (the paper's Fig-2) extended
with the row-rewrite relation (Fig-3) for Leijen-style extensible records with
scoped labels.

Records are unified by `uni-row`: to unify `Row(l :: t | r)` with `s`, the
right-hand row `s` is *rewritten* (Fig-3) to expose `l` at its head, then the
field types and tails are unified. The rewrite has three cases: `row-head`
(the label is already first), `row-swap` (bubble `l` to the front, only across
a prefix of DISTINCT labels — Fig-1's `eq-swap`), and `row-var` (the tail is a
variable `a`, which binds to `Row(l :: fresh-gamma | fresh-beta)`). The
`row-var` case is guarded by the paper's side condition `a /= tail(r)` — the
LEFT row's tail variable is passed down as `forbidden` — which is what makes
unification terminate for the classic `\r -> if True then {x=2|r} else {y=2|r}`
program (that program is then a type error, not a loop).

This module is pure Elm (elm/core + Type.Representation) and must stay free of
`Lower.*` imports so it can be unit-tested in isolation via `src/TestMain.elm`.

-}

import Type.Representation as Rep exposing (Flex(..), Kind(..), Row, RowTail(..), Subst, Type(..), VarId)


{-| A unification failure. `describe` renders it as a human-readable message;
the Infer pass attaches a source range before reporting it.
-}
type UnifyError
    = MissingField String
    | CannotUnify Type Type
    | InfiniteType VarId Type
    | FlexConflict Flex Type


{-| Unification state: the accumulated kinded substitution plus the next fresh
variable id. Fresh ids are globally unique across kinds (see `freshVar`).
-}
type alias State =
    { subst : Subst
    , fresh : Int
    }


emptyState : State
emptyState =
    { subst = Rep.emptySubst, fresh = 0 }


{-| Allocate a fresh type variable of the given kind and flex marker.
-}
freshVar : Kind -> Flex -> State -> ( VarId, State )
freshVar kind flex state =
    ( Rep.var state.fresh kind flex, { state | fresh = state.fresh + 1 } )



-- Unification.


{-| Unify two types under the current substitution, returning the extended
substitution (kinded: row variables only ever bind to `TRecord` values).
-}
unify : State -> Type -> Type -> Result UnifyError State
unify state t1 t2 =
    let
        z1 =
            Rep.zonk state.subst t1

        z2 =
            Rep.zonk state.subst t2
    in
    case ( z1, z2 ) of
        ( TVar v1, TVar v2 ) ->
            unifyVarVar state v1 v2

        ( TVar v, t ) ->
            bindVar state v t

        ( t, TVar v ) ->
            bindVar state v t

        ( TCon n1 a1, TCon n2 a2 ) ->
            if n1 /= n2 then
                Err (CannotUnify z1 z2)

            else if List.length a1 /= List.length a2 then
                Err (CannotUnify z1 z2)

            else
                unifyList state a1 a2

        ( TFun p1 q1, TFun p2 q2 ) ->
            unify state p1 p2 |> Result.andThen (\s -> unify s q1 q2)

        ( TTuple ts1, TTuple ts2 ) ->
            if List.length ts1 == List.length ts2 then
                unifyList state ts1 ts2

            else
                Err (CannotUnify z1 z2)

        ( TRecord r1, TRecord r2 ) ->
            unifyRow state r1 r2

        _ ->
            Err (CannotUnify z1 z2)


unifyList : State -> List Type -> List Type -> Result UnifyError State
unifyList state ts1 ts2 =
    case ( ts1, ts2 ) of
        ( [], [] ) ->
            Ok state

        ( t1 :: r1, t2 :: r2 ) ->
            unify state t1 t2 |> Result.andThen (\s -> unifyList s r1 r2)

        -- Unreachable: callers pre-check that the two lists have equal length.
        _ ->
            Err (CannotUnify (TTuple ts1) (TTuple ts2))


unifyVarVar : State -> VarId -> VarId -> Result UnifyError State
unifyVarVar state v1 v2 =
    if v1.id == v2.id then
        Ok state

    else if v1.kind /= KType || v2.kind /= KType then
        Err (CannotUnify (TVar v1) (TVar v2))

    else
        case ( v1.flex, v2.flex ) of
            ( FNone, _ ) ->
                Ok (addSubst state v1 (TVar v2))

            ( _, FNone ) ->
                Ok (addSubst state v2 (TVar v1))

            -- numbers are comparable, so the more specific marker wins.
            ( FNumber, FComparable ) ->
                Ok (addSubst state v2 (TVar v1))

            ( FComparable, FNumber ) ->
                Ok (addSubst state v1 (TVar v2))

            ( f1, f2 ) ->
                if f1 == f2 then
                    Ok (addSubst state v1 (TVar v2))

                else
                    Err (FlexConflict f1 (TVar v2))


{-| Bind a type variable `v` to type `t` (already zonked). Enforces the occurs
check and the flex-marker constraint, propagating the marker through `List`
and `Tuple` structure (e.g. `comparable ~ List a` marks `a` comparable).
-}
bindVar : State -> VarId -> Type -> Result UnifyError State
bindVar state v t =
    if v.kind /= KType then
        Err (CannotUnify (TVar v) t)

    else if Rep.occurs v t then
        Err (InfiniteType v t)

    else
        case v.flex of
            FNone ->
                Ok (addSubst state v t)

            flex ->
                propagate flex t state
                    |> Result.map (\( t2, st ) -> addSubst st v t2)



-- Row unification (the paper's `uni-row` + Fig-3 rewrite).


unifyRow : State -> Row -> Row -> Result UnifyError State
unifyRow state r1 r2 =
    case r1.fields of
        ( l, t ) :: rest1 ->
            case rewrite state (tailVar r1) r2 l of
                Err (MissingFieldE l2) ->
                    Err (MissingField l2)

                Err (SharedTailE _) ->
                    Err (CannotUnify (TRecord r1) (TRecord r2))

                Ok ( t2, s2, state1 ) ->
                    unify state1 t t2
                        |> Result.andThen
                            (\state2 ->
                                unifyRow state2
                                    (Rep.zonkRow state2.subst { fields = rest1, tail = r1.tail })
                                    (Rep.zonkRow state2.subst s2)
                            )

        [] ->
            unifyTail state r1.tail r2


unifyTail : State -> RowTail -> Row -> Result UnifyError State
unifyTail state tail r2 =
    case tail of
        REmpty ->
            case r2.fields of
                [] ->
                    case r2.tail of
                        REmpty ->
                            Ok state

                        RVar b ->
                            bindRowVar state b { fields = [], tail = REmpty }

                ( l, _ ) :: _ ->
                    Err (MissingField l)

        RVar a ->
            bindRowVar state a r2


bindRowVar : State -> VarId -> Row -> Result UnifyError State
bindRowVar state a row =
    if a.kind /= KRow then
        Err (CannotUnify (TVar a) (TRecord row))

    else if rowIsSameVar a row then
        Ok state

    else if Rep.occurs a (TRecord row) then
        Err (InfiniteType a (TRecord row))

    else
        Ok (addSubst state a (TRecord row))


rowIsSameVar : VarId -> Row -> Bool
rowIsSameVar a row =
    case ( row.fields, row.tail ) of
        ( [], RVar b ) ->
            b.id == a.id

        _ ->
            False


tailVar : Row -> Maybe VarId
tailVar row =
    case row.tail of
        REmpty ->
            Nothing

        RVar a ->
            Just a


type RewriteError
    = MissingFieldE String
    | SharedTailE String


{-| Rewrite a row to expose `l` at its head (Fig-3), returning the exposed
field type, the remainder row, and the extended state.

`forbidden` is the tail variable of the LEFT row (`tail(r)`): if the rewrite
reaches a row variable equal to it, instantiation is rejected (the paper's
side condition), turning the divergent common-tail program into an error.
-}
rewrite : State -> Maybe VarId -> Row -> String -> Result RewriteError ( Type, Row, State )
rewrite state forbidden row l =
    let
        zrow =
            Rep.zonkRow state.subst row
    in
    case zrow.fields of
        ( l2, t ) :: rest ->
            if l2 == l then
                -- row-head: l is already first; the FIRST occurrence is the
                -- selectable one (scoped labels).
                Ok ( t, { fields = rest, tail = zrow.tail }, state )

            else
                -- row-swap: recurse into the tail, then prepend this field back.
                rewrite state forbidden { fields = rest, tail = zrow.tail } l
                    |> Result.map
                        (\( t2, s2, st ) ->
                            ( t2, { fields = ( l2, t ) :: s2.fields, tail = s2.tail }, st )
                        )

        [] ->
            case zrow.tail of
                REmpty ->
                    -- tail-Empty and l absent: cannot expose l.
                    Err (MissingFieldE l)

                RVar a ->
                    if forbidden == Just a then
                        -- Paper side condition a /= tail(r): reject instantiating
                        -- the LEFT row's tail, or unification would loop.
                        Err (SharedTailE l)

                    else
                        let
                            ( gamma, st1 ) =
                                freshVar KType FNone state

                            ( beta, st2 ) =
                                freshVar KRow FNone st1
                        in
                        Ok
                            ( TVar gamma
                            , { fields = [], tail = RVar beta }
                            , addSubst st2 a (TRecord { fields = [ ( l, TVar gamma ) ], tail = RVar beta })
                            )



-- Flex-marker propagation (Elm 0.19's number/comparable/appendable supers).


propagate : Flex -> Type -> State -> Result UnifyError ( Type, State )
propagate flex t state =
    case flex of
        FNone ->
            Ok ( t, state )

        FNumber ->
            if isInt t || isFloat t then
                Ok ( t, state )

            else
                Err (FlexConflict flex t)

        FAppendable ->
            if isString t then
                Ok ( t, state )

            else
                case t of
                    -- List of ANY element is appendable; no element constraint.
                    TCon "List" [ _ ] ->
                        Ok ( t, state )

                    _ ->
                        Err (FlexConflict flex t)

        FComparable ->
            comparableType t state


comparableType : Type -> State -> Result UnifyError ( Type, State )
comparableType t state =
    case t of
        TCon "Int" [] ->
            Ok ( t, state )

        TCon "Float" [] ->
            Ok ( t, state )

        TCon "Char" [] ->
            Ok ( t, state )

        TCon "String" [] ->
            Ok ( t, state )

        TCon "List" [ e ] ->
            comparableType e state |> Result.map (\( e2, st ) -> ( TCon "List" [ e2 ], st ))

        TTuple ts ->
            mapAccumState comparableType ts state |> Result.map (\( ts2, st ) -> ( TTuple ts2, st ))

        TVar e ->
            comparableVar e state

        _ ->
            Err (FlexConflict FComparable t)


comparableVar : VarId -> State -> Result UnifyError ( Type, State )
comparableVar e state =
    case e.flex of
        FComparable ->
            Ok ( TVar e, state )

        -- numbers are comparable; keep the more specific marker.
        FNumber ->
            Ok ( TVar e, state )

        FNone ->
            -- Redirect e to a FRESH comparable variable (a distinct id, never a
            -- same-id re-mark: the substitution is keyed by id, so binding e to
            -- a same-id var would be a self-cycle that makes zonk diverge).
            let
                ( marked, st ) =
                    freshVar KType FComparable state
            in
            Ok ( TVar marked, addSubst st e (TVar marked) )

        FAppendable ->
            Err (FlexConflict FComparable (TVar e))


mapAccumState : (a -> State -> Result e ( b, State )) -> List a -> State -> Result e ( List b, State )
mapAccumState f xs state =
    case xs of
        [] ->
            Ok ( [], state )

        x :: rest ->
            case f x state of
                Err err ->
                    Err err

                Ok ( b, st ) ->
                    mapAccumState f rest st
                        |> Result.map (\( bs, st2 ) -> ( b :: bs, st2 ))


isInt : Type -> Bool
isInt t =
    case t of
        TCon "Int" [] ->
            True

        _ ->
            False


isFloat : Type -> Bool
isFloat t =
    case t of
        TCon "Float" [] ->
            True

        _ ->
            False


isString : Type -> Bool
isString t =
    case t of
        TCon "String" [] ->
            True

        _ ->
            False



-- Substitution helpers.


addSubst : State -> VarId -> Type -> State
addSubst state v t =
    { state | subst = Rep.extend v t state.subst }



-- Error rendering.


describe : UnifyError -> String
describe err =
    case err of
        MissingField l ->
            "missing field " ++ l

        CannotUnify t1 t2 ->
            "cannot unify " ++ Rep.pretty t1 ++ " with " ++ Rep.pretty t2

        InfiniteType v t ->
            "infinite type: " ++ Rep.pretty (TVar v) ++ " = " ++ Rep.pretty t

        FlexConflict flex t ->
            "cannot unify " ++ flexName flex ++ " with " ++ Rep.pretty t


flexName : Flex -> String
flexName flex =
    case flex of
        FNone ->
            "type variable"

        FNumber ->
            "number"

        FComparable ->
            "comparable"

        FAppendable ->
            "appendable"
