module Type.Representation exposing
    ( Kind(..)
    , Flex(..)
    , VarId
    , Type(..)
    , Row
    , RowTail(..)
    , Subst
    , var
    , tInt, tFloat, tBool, tChar, tString, tUnit, tNever, tList
    , emptySubst, extend, lookup, compose, zonk, zonkRow
    , occurs, occursRow
    , pretty, prettyRow
    )

{-| The type representation for the fx-ui typechecker: a Hindley-Milner type
syntax extended with Leijen-style extensible records (scoped labels).

The interesting parts are the `Row` (an insertion-ordered field list plus a
row-typed tail, where DUPLICATE labels are legal and retained — a scoped label
is the *first* occurrence) and the `Flex` marker on type variables (Elm 0.19's
`number`/`comparable`/`appendable` flex-supers, which replace typeclasses).

This module is pure Elm (elm/core only) and must stay free of `Lower.*` imports
so it can be unit-tested in isolation via `src/TestMain.elm`.


## Kinds

`KType` is the kind of value types; `KRow` is the kind of row *tails* — a row
variable is only ever bound to a `Row` (see `zonkRow`), never to a value type.


## Substitution

The substitution is keyed by the unique `id` field of `VarId` and is KINDED:
the unifier is responsible for binding `KRow` variables only to `TRecord`
values.  `zonk` applies a substitution to fixpoint, splicing a bound row
variable's fields into the enclosing row's field list (a `RVar` tail bound to
`TRecord { fields, tail }` expands to `outerFields ++ fields` with the bound
tail).

-}

import Dict exposing (Dict)


{-| The kind of a type variable.  `KRow` variables range over row tails (they
only ever appear as the `RVar` tail of a `Row`); `KType` variables range over
ordinary value types.
-}
type Kind
    = KType
    | KRow


{-| A flex marker on a `KType` variable, mirroring Elm 0.19's special built-in
type variables.  `FNone` is an ordinary (rigid once inferred) variable.
-}
type Flex
    = FNone
    | FNumber
    | FComparable
    | FAppendable


{-| A type-variable identity: a globally-unique `id` plus its `kind` and flex
marker.  Two `VarId`s are the same variable iff their `id` fields match.
-}
type alias VarId =
    { id : Int
    , kind : Kind
    , flex : Flex
    }


{-| Build a `VarId`.  `var 0 KType FNone` is an ordinary type variable 0.
-}
var : Int -> Kind -> Flex -> VarId
var id kind flex =
    { id = id, kind = kind, flex = flex }


{-| A type.  Named types (`Int`, `Float`, `Bool`, `Char`, `String`, `()`,
`List`, `Never`, and user ADTs qualified as `"Mod.Name"`) are `TCon name args`;
tuples are `TTuple`; rows are `TRecord`.
-}
type Type
    = TVar VarId
    | TCon String (List Type)
    | TFun Type Type
    | TTuple (List Type)
    | TRecord Row


{-| A row: fields in INSERTION order plus a tail.  Duplicate labels are legal
and retained (scoped labels); the FIRST occurrence of a label is the one
`select`/`restrict` act on.
-}
type alias Row =
    { fields : List ( String, Type )
    , tail : RowTail
    }


{-| A row tail: closed (`REmpty`) or a `KRow` variable.
-}
type RowTail
    = REmpty
    | RVar VarId


{-| A kinded substitution, keyed by variable id.  Row variables are only ever
mapped to `TRecord` values (the unifier enforces this).
-}
type alias Subst =
    Dict Int Type



-- Convenient named types.


tInt : Type
tInt =
    TCon "Int" []


tFloat : Type
tFloat =
    TCon "Float" []


tBool : Type
tBool =
    TCon "Bool" []


tChar : Type
tChar =
    TCon "Char" []


tString : Type
tString =
    TCon "String" []


tUnit : Type
tUnit =
    TCon "()" []


tNever : Type
tNever =
    TCon "Never" []


tList : Type -> Type
tList elem =
    TCon "List" [ elem ]



-- Substitution.


emptySubst : Subst
emptySubst =
    Dict.empty


extend : VarId -> Type -> Subst -> Subst
extend v t s =
    Dict.insert v.id t s


lookup : VarId -> Subst -> Maybe Type
lookup v s =
    Dict.get v.id s


{-| Compose substitutions: `compose s1 s2` is `s1` after `s2` — every RHS of
`s2` is first zonked under `s1`, then `s1`'s own bindings win.
-}
compose : Subst -> Subst -> Subst
compose s1 s2 =
    Dict.union s1 (Dict.map (\_ t -> zonk s1 t) s2)


{-| Apply a substitution to a type to fixpoint (zonk).  A `TVar` bound to
another type is replaced and the result re-zonked; a bound row variable is
spliced into its enclosing row's field list.
-}
zonk : Subst -> Type -> Type
zonk s t =
    case t of
        TVar v ->
            case Dict.get v.id s of
                Just t2 ->
                    zonk s t2

                Nothing ->
                    t

        TCon name args ->
            TCon name (List.map (zonk s) args)

        TFun a b ->
            TFun (zonk s a) (zonk s b)

        TTuple ts ->
            TTuple (List.map (zonk s) ts)

        TRecord row ->
            TRecord (zonkRow s row)


{-| Zonk a row: zonk each field type, then splice a bound row tail.
-}
zonkRow : Subst -> Row -> Row
zonkRow s row =
    let
        fields =
            List.map (\( n, t ) -> ( n, zonk s t )) row.fields
    in
    case row.tail of
        REmpty ->
            { fields = fields, tail = REmpty }

        RVar v ->
            case Dict.get v.id s of
                Just (TRecord bound) ->
                    -- A row variable bound to a Row expands into that row's
                    -- (zonked) fields with its tail becoming ours.
                    let
                        spliced =
                            zonkRow s bound
                    in
                    { fields = fields ++ spliced.fields
                    , tail = spliced.tail
                    }

                _ ->
                    -- Unbound (or a kind violation, which the unifier forbids).
                    { fields = fields, tail = RVar v }



-- Occurs check (kind-aware: a KRow variable occurs via any row tail).


occurs : VarId -> Type -> Bool
occurs target t =
    case t of
        TVar v ->
            v.id == target.id

        TCon _ args ->
            List.any (occurs target) args

        TFun a b ->
            occurs target a || occurs target b

        TTuple ts ->
            List.any (occurs target) ts

        TRecord row ->
            occursRow target row


occursRow : VarId -> Row -> Bool
occursRow target row =
    List.any (\( _, t ) -> occurs target t) row.fields
        || occursTail target row.tail


occursTail : VarId -> RowTail -> Bool
occursTail target tail =
    case tail of
        REmpty ->
            False

        RVar v ->
            v.id == target.id



-- Pretty-printer.  Renders scoped rows VERBATIM (duplicate labels are all
-- shown), assigns type variables lowercase names in first-appearance order,
-- and spells flex markers as Elm does (`number`/`comparable`/`appendable`).


pretty : Type -> String
pretty t =
    let
        ordered =
            dedupe (collectVars t [])

        names =
            Dict.fromList
                (List.map2 Tuple.pair
                    (List.map .id ordered)
                    (List.map nameFor (List.range 0 (List.length ordered - 1)))
                )
    in
    render names t


prettyRow : Row -> String
prettyRow row =
    let
        ordered =
            dedupe (collectVarsRow row [])

        names =
            Dict.fromList
                (List.map2 Tuple.pair
                    (List.map .id ordered)
                    (List.map nameFor (List.range 0 (List.length ordered - 1)))
                )
    in
    renderRow names row


render : Dict Int String -> Type -> String
render names t =
    case t of
        TVar v ->
            varName names v

        TCon name args ->
            if List.isEmpty args then
                name

            else
                name ++ " " ++ String.join " " (List.map (renderAtomic names) args)

        TFun a b ->
            renderAtomic names a ++ " -> " ++ render names b

        TTuple ts ->
            "(" ++ String.join ", " (List.map (render names) ts) ++ ")"

        TRecord row ->
            renderRow names row


renderRow : Dict Int String -> Row -> String
renderRow names row =
    let
        fieldStrs =
            List.map (\( n, t ) -> n ++ ":" ++ render names t) row.fields

        body =
            String.join ", " fieldStrs

        tailStr =
            case row.tail of
                REmpty ->
                    ""

                RVar v ->
                    "| " ++ varName names v
    in
    "{" ++ body ++ tailStr ++ "}"


-- Parenthesize a type only when it would otherwise change precedence as an
-- argument (a function type).
renderAtomic : Dict Int String -> Type -> String
renderAtomic names t =
    case t of
        TFun _ _ ->
            "(" ++ render names t ++ ")"

        _ ->
            render names t


varName : Dict Int String -> VarId -> String
varName names v =
    case v.flex of
        FNumber ->
            "number"

        FComparable ->
            "comparable"

        FAppendable ->
            "appendable"

        FNone ->
            Maybe.withDefault ("t" ++ String.fromInt v.id) (Dict.get v.id names)


collectVars : Type -> List VarId -> List VarId
collectVars t acc =
    case t of
        TVar v ->
            addVar v acc

        TCon _ args ->
            List.foldl collectVars acc args

        TFun a b ->
            -- Left-to-right (argument then result) so `a -> b` names its
            -- variables in source order, matching Elm's own type rendering.
            collectVars b (collectVars a acc)

        TTuple ts ->
            List.foldl collectVars acc ts

        TRecord row ->
            collectVarsRow row acc


collectVarsRow : Row -> List VarId -> List VarId
collectVarsRow row acc =
    let
        accFields =
            List.foldl (\( _, t ) a -> collectVars t a) acc row.fields
    in
    case row.tail of
        REmpty ->
            accFields

        RVar v ->
            addVar v accFields


-- Flex markers render literally, so they do not consume a letter.
addVar : VarId -> List VarId -> List VarId
addVar v acc =
    if v.flex /= FNone then
        acc

    else
        acc ++ [ v ]


dedupe : List VarId -> List VarId
dedupe xs =
    List.foldl
        (\x acc ->
            if List.any (\y -> y.id == x.id) acc then
                acc

            else
                acc ++ [ x ]
        )
        []
        xs


nameFor : Int -> String
nameFor i =
    let
        letter =
            String.fromChar (Char.fromCode (97 + modBy 26 i))
    in
    if i < 26 then
        letter

    else
        letter ++ String.fromInt (i // 26)
