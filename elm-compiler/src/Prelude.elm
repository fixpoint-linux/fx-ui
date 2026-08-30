module Prelude exposing
    ( Order(..)
    , Maybe(..)
    , Result(..)
    , not
    , identity
    , always
    , min
    , max
    , clamp
    , compare
    , lt
    , gt
    , le
    , ge
    , eq
    , neq
    , maybeMap
    , maybeWithDefault
    , resultMap
    , resultWithDefault
    , isEmpty
    , head
    , tail
    , singleton
    , reverse
    , map
    , filter
    , foldl
    , foldr
    , append
    , sum
    , concat
    , join
    , fromInt
    , length
    , drop
    )

-- The M3 prelude: a pure-core Elm module compiled BY the compiler itself at
-- startup (run.js injects this file's source as the first compilation unit,
-- so it participates in the multi-module pipeline exactly like a user
-- module).  Everything here must therefore live inside the compiler's own
-- supported subset: no `++`, no List/String stdlib modules, plain recursion
-- over case-expressions, literals, arithmetic and comparisons only.
--
-- Representation notes:
--   * Maybe/Result/Order are ordinary ADTs (vector[tag, a1..an] ctors generated
--     by the ctor mechanism, registered under BOTH their bare and
--     "Prelude."-qualified names).
--   * Lists are VM cons chains; `x :: xs` sugar lowers through UnConsPattern /
--     the cons emitter.
--   * map/filter/reverse are TAIL-recursive accumulator walkers so the
--     1000-element gate stays inside the VM's constant-depth tail-loop model;
--     foldl recurses in tail position directly.  append/sum/concat/foldr are
--     structurally non-tail convenience folds (documented in plan §8 M3 scope;
--     the gate exercises map/filter/foldl over 1000 elems).
--
-- String ops ride the VM byte-string prims (plan §3) THROUGH the curried
-- wrapper globals Lower.Module emits for them: `String.append` -> `cn`
-- (full source-order 2-arg concat), `String.length` -> `c-strlen` (BYTE
-- length), `String.sliceLen` -> `substring` (start LEN str — NOT real Elm's
-- (start, end) String.slice), and `fromInt` =
-- `cn ""` (cn renders numbers in decimal).  Those DOTTED names resolve via
-- the compiler's alias table to `.curried` wrapper globals, which are
-- emitted alongside every module (deduped identically on bundle merge).


type Order
    = LT
    | EQ
    | GT


type Maybe a
    = Just a
    | Nothing


type Result e a
    = Ok a
    | Err e


not b =
    if b then
        False

    else
        True


identity x =
    x


always x y =
    x


min a b =
    if a < b then
        a

    else
        b


max a b =
    if a > b then
        a

    else
        b


clamp lo hi x =
    if x < lo then
        lo

    else if x > hi then
        hi

    else
        x


-- STRUCTURAL COMPARE (elm/core Basics.compare parity) — replaces the old
-- Int-only version.  A pure-Elm dispatcher over the compare prim aliases
-- (see Lower.Module.comparePrimAliases): the VM < > prims are NUMERIC-ONLY,
-- so strings/lists/tuples compare structurally here.
--
--   * number? covers Int AND Float (VM promotes across the two, NaN -> EQ —
--     same as real Elm's JS Utils.cmp).
--   * Strings compare byte-lexicographically via the char-code prim (UTF-8
--     byte order; differs from JS UTF-16 code-unit order only for astral
--     chars).  Char rides this branch (chars lower to 1-byte strings).
--   * Lists AND tuples are cons chains: tuples are cons(a, cons(b, ...))
--     with the LAST element as terminal cdr (Expr.tupleCode), so the walker
--     recurses through `compare` itself — a proper list's tail re-dispatches
--     to cmpList/the nil rule, a tuple's terminal cdr compares by its own
--     structural order.  The nil-vs-cons prefix rule gives [] < (y :: ys).
--   * Ill-typed mixed comparisons (e.g. 5 vs "a") fall to EQ — the untyped
--     subset has no type error to raise.
--
-- `compare` is a RUNTIME-TYPE-TAG dispatcher (isNumber/isString/isCons/isNil),
-- which HM cannot type — it is the authentic elm/core Basics.compare surface,
-- which real Elm implements in the KERNEL.  Its body is therefore TRUSTED
-- (Type.Builtins.trustedBodies), and this signature (`comparable -> comparable
-- -> Order`, verbatim elm/core) is what the checker uses at every call site.


compare : comparable -> comparable -> Order
compare a b =
    if isNumber a then
        cmpNum a b

    else if isString a then
        cmpStrBytes 0 a b

    else if isCons a then
        cmpList a b

    else if isNil a then
        if isNil b then
            EQ

        else
            LT

    else
        EQ


cmpNum x y =
    if x < y then
        LT

    else if x > y then
        GT

    else
        EQ


cmpStrBytes i s t =
    let
        ca =
            charCode s i

        cb =
            charCode t i
    in
    if ca == -1 then
        if cb == -1 then
            EQ

        else
            LT

    else if cb == -1 then
        GT

    else if ca < cb then
        LT

    else if ca > cb then
        GT

    else
        cmpStrBytes (i + 1) s t


cmpList xs ys =
    if isNil xs then
        if isNil ys then
            EQ

        else
            LT

    else if isNil ys then
        GT

    else
        case xs of
            x :: xr ->
                case ys of
                    y :: yr ->
                        case compare x y of
                            EQ ->
                                compare xr yr

                            o ->
                                o

                    [] ->
                        GT

            [] ->
                LT


lt a b =
    case compare a b of
        LT ->
            True

        _ ->
            False


gt a b =
    case compare a b of
        GT ->
            True

        _ ->
            False


le a b =
    case compare a b of
        GT ->
            False

        _ ->
            True


ge a b =
    case compare a b of
        LT ->
            False

        _ ->
            True


eq a b =
    a == b


neq a b =
    not (a == b)



-- ====================== Maybe ======================


maybeMap f mx =
    case mx of
        Just x ->
            Just (f x)

        Nothing ->
            Nothing


maybeWithDefault d mx =
    case mx of
        Just x ->
            x

        Nothing ->
            d



-- ====================== Result =====================


resultMap f rx =
    case rx of
        Ok x ->
            Ok (f x)

        Err e ->
            Err e


resultWithDefault d rx =
    case rx of
        Ok x ->
            x

        Err _ ->
            d



-- ======================= List ======================
-- Shared tail-recursive walkers: reversed-accumulator folds finished by one
-- reverse, keeping order.


listRevGo acc xs =
    case xs of
        y :: rest ->
            listRevGo (y :: acc) rest

        [] ->
            acc


reverse xs =
    listRevGo [] xs


listMapGo f acc xs =
    case xs of
        y :: rest ->
            listMapGo f (f y :: acc) rest

        [] ->
            acc


map f xs =
    reverse (listMapGo f [] xs)


listFilterGo f acc xs =
    case xs of
        y :: rest ->
            if f y then
                listFilterGo f (y :: acc) rest

            else
                listFilterGo f acc rest

        [] ->
            acc


filter f xs =
    reverse (listFilterGo f [] xs)


foldl f z xs =
    case xs of
        y :: rest ->
            foldl f (f y z) rest

        [] ->
            z


-- Structurally non-tail (small-list convenience only; see header note).
foldr f z xs =
    case xs of
        y :: rest ->
            f y (foldr f z rest)

        [] ->
            z


isEmpty xs =
    case xs of
        [] ->
            True

        _ ->
            False


head xs =
    case xs of
        y :: _ ->
            y

        [] ->
            "head of empty list"


tail xs =
    case xs of
        _ :: rest ->
            rest

        [] ->
            []


singleton x =
    x :: []


append xs ys =
    case xs of
        y :: rest ->
            y :: append rest ys

        [] ->
            ys


sum xs =
    case xs of
        y :: rest ->
            y + sum rest

        [] ->
            0


-- List.concat: flatten one level (non-tail; gate sizes are modest).
concat xss =
    case xss of
        xs :: rest ->
            append xs (concat rest)

        [] ->
            []


join sep strs =
    case strs of
        s :: rest ->
            String.append s (case rest of
                [] ->
                    ""

                _ ->
                    String.append sep (join sep rest)
            )

        [] ->
            ""



-- ====================== String =====================


-- `fromInt` rides the `cn` prim (String.append), which RENDERS a number in
-- decimal when concatenated — a trusted lie the checker cannot see (String.append
-- is typed String -> String -> String), so the body is TRUSTED.
fromInt : Int -> String
fromInt n =
    String.append "" n



-- Tail-recursive LIST length (Elm's List.length).
length xs =
    lengthGo 0 xs


lengthGo acc xs =
    case xs of
        y :: rest ->
            lengthGo (acc + 1) rest

        [] ->
            acc


-- Tail-recursive drop (Elm's List.drop): negative n drops nothing.
drop n xs =
    if n <= 0 then
        xs

    else
        case xs of
            _ :: rest ->
                drop (n - 1) rest

            [] ->
                []



-- ==================== Record field removal ====================
-- The runtime for `Record.remove '<label>' r` (the typechecker rewrites that
-- surface to `Prelude.removeFieldImpl "<label>" r`).  A record VALUE is an
-- assoc list of @p(symbol, value) pairs, so this walks it and drops the FIRST
-- matching pair only — returning `rest` on a match, NOT a full filter — which
-- is exactly the paper's `restrict` (outermost-occurrence removal) that scoped
-- labels require: with duplicate labels {x=1, x=2}, removing x leaves {x=2}
-- and `.x` then selects 2.  `intern` (processPrimAliases) makes the symbol from
-- the string; `==` lowers to the structural `=` prim.  The body is TRUSTED
-- (Type.Builtins.trustedBodies): it pattern-matches a record as a raw assoc
-- list, which the TRecord-typed checker must never see.

removeFieldImpl name rec =
    case rec of
        ( k, v ) :: rest ->
            if k == intern name then
                rest

            else
                ( k, v ) :: removeFieldImpl name rest

        [] ->
            []
