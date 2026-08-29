module JsArray exposing
  ( empty, singleton, length
  , initialize, initializeFromList
  , unsafeGet, unsafeSet, push
  , foldl, foldr
  , map, indexedMap
  , slice, appendN
  )

-- elm/core 1.0.5 Elm/Kernel/JsArray.js port: the kernel's growable JS arrays
-- are substituted with the VM's mutable absvector, addressed as
--
--     slot 0   : element count (a VM number)
--     slot i+1 : element i
--
-- so `length a` is `vectorGet a 0` (O(1)); every other op walks i+1 offsets.
-- The VM prims reach the subset as bare aliases (Lower/Module
-- vectorPrimAliases): vectorMake = absvector.curried (1-arg slot count),
-- vectorGet vec i = <-address.curried, vectorSet vec i x = address->.curried
-- (the prim RETURNS the vector, so sets chain).
--
-- PERSISTENCE DISCIPLINE (the substitute for the kernel's copy-on-write): a
-- VM vector is MUTABLE and shared, so vectorSet is applied ONLY to vectors
-- freshly made by vectorMake inside this module — every op that derives a
-- new JsArray copies ALL slots first (copy-ALWAYS) and mutates the copy
-- before it becomes reachable elsewhere.  gc allocArray zero-fills vector
-- bodies, so a fresh vector reads as all-zeros (fill-then-share is GC-safe)
-- and `empty` needs no explicit store: slot 0 is already 0.
--
-- Semantics are the JS kernel's, operation for operation:
--   * `slice` reproduces the FULL Array.prototype.slice normalization
--     (negative bounds count from the end, out-of-range bounds clamp to
--     0/length, from >= to yields empty) because Array.appendHelpTree calls
--     it with a NEGATIVE `from`;
--   * `appendN` clamps itemsToCopy at 0 where the JS tolerates a negative
--     (same result either way: a plain copy of dest);
--   * `initializeFromList` takes exactly min(max, list-length) items and
--     returns the remaining list.
-- All copy/fill loops are tail-recursive TOP-LEVEL helpers (subset
-- let-functions cannot see their own name); loop depth is bounded by the
-- element count (<= 33 at every Array.elm call site).
--
-- The opaque `JsArray a` type is NOT redeclared: the subset's annotations are
-- tolerated but never parsed (Dict.elm precedent) and the representation is
-- an untyped VM vector.  Bare `length`/`empty`/... inside this module are the
-- module's OWN definitions (self-aliases shadow the prelude), so the one
-- place that needs the PRELUDE list functions spells them dotted
-- (List.length / List.drop in initializeFromList).


empty =
    vectorMake 1


singleton v =
    vectorSet (vectorSet (vectorMake 2) 0 1) 1 v


length a =
    vectorGet a 0


initialize size offset fn =
    if size <= 0 then
        empty

    else
        initializeHelp size offset fn (vectorSet (vectorMake (size + 1)) 0 size) 0


initializeHelp size offset fn vec i =
    if i >= size then
        vec

    else
        initializeHelp
            size
            offset
            fn
            (vectorSet vec (i + 1) (fn (offset + i)))
            (i + 1)


initializeFromList maxLen list =
    let
        n =
            min maxLen (List.length list)
    in
        ( initializeFromListHelp n 0 list (vectorSet (vectorMake (n + 1)) 0 n)
        , List.drop n list
        )


initializeFromListHelp n i xs vec =
    if i >= n then
        vec

    else
        case xs of
            x :: rest ->
                initializeFromListHelp n (i + 1) rest (vectorSet vec (i + 1) x)

            [] ->
                vec


unsafeGet i a =
    vectorGet a (i + 1)


unsafeSet i v a =
    vectorSet
        (copySlots a (vectorMake (length a + 1)) (length a + 1) 0)
        (i + 1)
        v


-- Copy slots 0..count-1 of src into the fresh vector dst.  count always
-- includes slot 0 (the length), so the copy preserves it.
copySlots src dst count i =
    if i >= count then
        dst

    else
        copySlots src (vectorSet dst i (vectorGet src i)) count (i + 1)


push v a =
    -- copy ALL old slots (0..len), then re-write slot 0 (the new length) and
    -- the new last element — both on the fresh copy.
    vectorSet
        (vectorSet
            (copySlots a (vectorMake (length a + 2)) (length a + 1) 0)
            0
            (length a + 1)
        )
        (length a + 1)
        v


foldl func acc a =
    foldlHelp func acc a 0


foldlHelp func acc a i =
    if i >= length a then
        acc

    else
        foldlHelp func (func (unsafeGet i a) acc) a (i + 1)


foldr func acc a =
    foldrHelp func acc a (length a - 1)


foldrHelp func acc a i =
    if i < 0 then
        acc

    else
        foldrHelp func (func (unsafeGet i a) acc) a (i - 1)


map fn a =
    mapHelp fn a (vectorSet (vectorMake (length a + 1)) 0 (length a)) 0


mapHelp fn a dst i =
    if i >= length a then
        dst

    else
        mapHelp fn a (vectorSet dst (i + 1) (fn (unsafeGet i a))) (i + 1)


indexedMap fn offset a =
    indexedMapHelp
        fn
        offset
        a
        (vectorSet (vectorMake (length a + 1)) 0 (length a))
        0


indexedMapHelp fn offset a dst i =
    if i >= length a then
        dst

    else
        indexedMapHelp
            fn
            offset
            a
            (vectorSet dst (i + 1) (fn (offset + i) (unsafeGet i a)))
            (i + 1)


slice from to a =
    let
        len =
            length a

        f =
            clampIndex len from

        t =
            clampIndex len to
    in
        if f >= t then
            empty

        else
            sliceHelp a (vectorSet (vectorMake (t - f + 1)) 0 (t - f)) f 0


-- Array.prototype.slice bound normalization.
clampIndex len x =
    if x < 0 then
        max 0 (len + x)

    else if x > len then
        len

    else
        x


sliceHelp a dst f i =
    if i >= length dst then
        dst

    else
        sliceHelp a (vectorSet dst (i + 1) (unsafeGet (f + i) a)) f (i + 1)


appendN n dest source =
    let
        destLen =
            length dest

        itemsToCopy =
            min (n - destLen) (length source)

        items =
            max 0 itemsToCopy
    in
        vectorSet
            (appendNHelp
                source
                (copySlots dest (vectorMake (destLen + items + 1)) (destLen + 1) 0)
                destLen
                items
                0
            )
            0
            (destLen + items)


appendNHelp source dst destLen items i =
    if i >= items then
        dst

    else
        appendNHelp
            source
            (vectorSet dst (destLen + i + 1) (unsafeGet i source))
            destLen
            items
            (i + 1)
