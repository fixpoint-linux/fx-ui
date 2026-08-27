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
-- length), `String.slice` -> `substring` (start len str), and `fromInt` =
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


compare a b =
    if a < b then
        LT

    else if a > b then
        GT

    else
        EQ



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
            "tail of empty list"


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
