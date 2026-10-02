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
    , maybeHead
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
    , take
    , member
    , any
    , all
    , concatMap
    , filterMap
    , map2
    , indexedMap
    , partition
    , range
    , repeat
    , modBy
    , stringFromChar
    , charToCode
    , charFromCode
    , stringToList
    , stringSlice
    , stringDropLeft
    , stringDropRight
    , stringStartsWith
    , stringEndsWith
    , stringFromFloat
    , stringFromList
    , stringToLower
    , stringToUpper
    , stringAny
    , stringCons
    , stringFoldr
    , charIsLower
    , charIsUpper
    , charIsAlpha
    , charIsDigit
    , charIsOctDigit
    , charIsHexDigit
    , charIsAlphaNum
    , basicsToFloat
    , basicsIsNaN
    , stringToFloat
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


-- The REAL Elm `List.head : List a -> Maybe a` (the bare `head` above is a
-- legacy element-returning convenience with a String fallback; the dotted
-- `List.head` spelling used by the compiler's own source needs the Maybe
-- shape).
maybeHead : List a -> Maybe a
maybeHead xs =
    case xs of
        y :: _ ->
            Just y

        [] ->
            Nothing


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



-- Tail-recursive take (Elm's List.take), the exact mirror of drop:
-- negative n takes nothing, n past the end takes everything.
take n xs =
    if n <= 0 then
        []

    else
        case xs of
            y :: rest ->
                y :: take (n - 1) rest

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



-- ====================== List helpers (M14 selfhost shims) ======================
-- The richer List surface the compiler's OWN source (Type/Lower/Zinc) needs:
-- plain recursive walkers over the existing Prelude combinators, so they stay
-- inside the supported subset (no List/String stdlib modules).


member : comparable -> List comparable -> Bool
member x xs =
    case xs of
        y :: rest ->
            if x == y then
                True

            else
                member x rest

        [] ->
            False


any : (a -> Bool) -> List a -> Bool
any f xs =
    case xs of
        y :: rest ->
            if f y then
                True

            else
                any f rest

        [] ->
            False


all : (a -> Bool) -> List a -> Bool
all f xs =
    case xs of
        y :: rest ->
            if f y then
                all f rest

            else
                False

        [] ->
            True


filterMap : (a -> Maybe b) -> List a -> List b
filterMap f xs =
    case xs of
        y :: rest ->
            case f y of
                Just v ->
                    v :: filterMap f rest

                Nothing ->
                    filterMap f rest

        [] ->
            []


concatMap : (a -> List b) -> List a -> List b
concatMap f xs =
    case xs of
        y :: rest ->
            append (f y) (concatMap f rest)

        [] ->
            []


map2 : (a -> b -> c) -> List a -> List b -> List c
map2 f xs ys =
    case xs of
        x :: xr ->
            case ys of
                y :: yr ->
                    f x y :: map2 f xr yr

                [] ->
                    []

        [] ->
            []


indexedMap : (Int -> a -> b) -> List a -> List b
indexedMap f xs =
    indexedMapGo f 0 xs


indexedMapGo : (Int -> a -> b) -> Int -> List a -> List b
indexedMapGo f i xs =
    case xs of
        y :: rest ->
            f i y :: indexedMapGo f (i + 1) rest

        [] ->
            []


partition : (a -> Bool) -> List a -> ( List a, List a )
partition f xs =
    partitionGo f xs [] []


partitionGo : (a -> Bool) -> List a -> List a -> List a -> ( List a, List a )
partitionGo f xs ys ns =
    case xs of
        y :: rest ->
            if f y then
                partitionGo f rest (y :: ys) ns

            else
                partitionGo f rest ys (y :: ns)

        [] ->
            ( reverse ys, reverse ns )


range : Int -> Int -> List Int
range lo hi =
    if lo > hi then
        []

    else
        lo :: range (lo + 1) hi


repeat : Int -> a -> List a
repeat n x =
    if n <= 0 then
        []

    else
        x :: repeat (n - 1) x


-- Integer modulo (both args non-negative at every selfhost call site: modBy 26
-- i, modBy 2 code).  `//` is the VM's integer division.
modBy : Int -> Int -> Int
modBy n x =
    x - (x // n) * n



-- ====================== Char / String helpers (M14 selfhost shims) ============
-- Char is a BYTE-ORIENTED 1-byte string at runtime (the VM's char-code /
-- c-strlen count bytes, not code points), so these shims are the byte-level
-- spellings the compiler's own source expects: Char.toCode = first byte,
-- Char.fromCode = one byte, String.fromChar = identity, String.toList = one
-- Char per byte.  The char/string conversion bodies are TRUSTED (the checker
-- keeps Char and String distinct, but the VM does not).


-- TRUSTED: `c` (a Char) IS a 1-byte string at runtime.
stringFromChar : Char -> String
stringFromChar c =
    c


-- TRUSTED: char-code on the 1-byte string is the code point for ASCII.
charToCode : Char -> Int
charToCode c =
    charCode c 0


-- TRUSTED: shen.bytes->string of the byte list.  n <= 0xFF keeps the
-- historical ONE-BYTE Char (String.toList/fromList round-trip over raw
-- source bytes depends on it); n > 0xFF encodes the code point as UTF-8 —
-- real Elm's Char carries a code point, and \u{4E00}-style escapes in
-- string literals must lower to the same bytes stock emits (a truncated
-- single byte diverges the S atom).
charFromCode : Int -> Char
charFromCode n =
    if n <= 255 then
        bytesToString (n :: [])

    else if n <= 2047 then
        bytesToString
            ((192 + n // 64) :: (128 + modBy 64 n) :: [])

    else if n <= 65535 then
        bytesToString
            ((224 + n // 4096)
                :: (128 + modBy 64 (n // 64))
                :: (128 + modBy 64 n)
                :: []
            )

    else
        bytesToString
            ((240 + n // 262144)
                :: (128 + modBy 64 (n // 4096))
                :: (128 + modBy 64 (n // 64))
                :: (128 + modBy 64 n)
                :: []
            )


-- One Char per byte (see the header note: byte semantics, not code points).
stringToList : String -> List Char
stringToList s =
    stringToListGo s 0 (String.length s)


stringToListGo : String -> Int -> Int -> List Char
stringToListGo s i len =
    if i >= len then
        []

    else
        charFromCode (charCode s i) :: stringToListGo s (i + 1) len


-- Real Elm's (start, end) slice over the byte-level substring prim.
stringSlice : Int -> Int -> String -> String
stringSlice start end s =
    String.sliceLen start (end - start) s


stringDropLeft : Int -> String -> String
stringDropLeft n s =
    if n <= 0 then
        s

    else if n >= String.length s then
        ""

    else
        String.sliceLen n (String.length s - n) s


stringDropRight : Int -> String -> String
stringDropRight n s =
    if n <= 0 then
        s

    else if n >= String.length s then
        ""

    else
        String.sliceLen 0 (String.length s - n) s


stringStartsWith : String -> String -> Bool
stringStartsWith prefix s =
    String.sliceLen 0 (String.length prefix) s == prefix


stringEndsWith : String -> String -> Bool
stringEndsWith suffix s =
    let
        n =
            String.length s - String.length suffix
    in
    if n < 0 then
        False

    else
        String.sliceLen n (String.length suffix) s == suffix


-- TRUSTED: the 1-arg `str` prim renders any scalar (a Float here) to its
-- decimal text.
-- JS Number::toString parity (the selfhost csexp F atom must render EXACTLY
-- like real Elm's String.fromFloat, which is JS).  The VM `str` prim gives
-- the correct SHORTEST-ROUNDTRIP DIGITS but always in fixed notation with a
-- mandatory ".0" on integrals; this re-renders those digits in JS's form:
-- exponential iff k > 21 or k <= -6 (k = decimal weight of the first
-- significant digit), "d.ddd" / "0.00ddd" / plain digits otherwise.  NaN and
-- the infinities pass through unchanged (same spellings in both).
stringFromFloat : Float -> String
stringFromFloat f =
    jsFloatText (strPrim f)


-- JS Number::toString parity over the `str` prim's text (see the note above
-- stringFromFloat).  Non-decimal texts (NaN / Infinity) pass through as-is:
-- both runtimes spell them identically.
jsFloatText : String -> String
jsFloatText text =
    let
        len =
            String.length text
    in
    if len == 0 then
        text

    else if charCode text 0 == 45 then
        -- "-" sign (a decimal negative, or -Infinity)
        if len > 1 && 48 <= charCode text 1 && charCode text 1 <= 57 then
            String.append "-" (jsFloatUnsigned text 1 len)

        else
            text

    else if 48 <= charCode text 0 && charCode text 0 <= 57 then
        jsFloatUnsigned text 0 len

    else
        -- NaN / Infinity
        text


jsFloatUnsigned : String -> Int -> Int -> String
jsFloatUnsigned text at end =
    let
        intEnd =
            digitsEnd text at end

        fracEnd =
            if charCode text intEnd == 46 then
                digitsEnd text (intEnd + 1) end

            else
                intEnd
    in
    jsFloatDigits text at intEnd fracEnd


digitsEnd : String -> Int -> Int -> Int
digitsEnd text i end =
    if i < end && 48 <= charCode text i && charCode text i <= 57 then
        digitsEnd text (i + 1) end

    else
        i


-- digits [at, fracEnd) with the '.' at intEnd skipped: LOGICAL digit index
-- space (0 = first int digit).  intCount = digits before the point; a digit
-- at logical i is at byte at+i while i < intCount, else at intEnd+1+(i-intCount).
jsFloatDigits : String -> Int -> Int -> Int -> String
jsFloatDigits text at intEnd fracEnd =
    let
        intCount =
            intEnd - at

        hasFrac =
            fracEnd > intEnd

        digitCount =
            intCount
                + (if hasFrac then
                    fracEnd - intEnd - 1

                   else
                    0
                  )

        digitAt i =
            if i < intCount then
                charCode text (at + i)

            else
                charCode text (intEnd + 1 + (i - intCount))

        firstSig =
            jsFirstSignificantDigit digitAt digitCount 0

        lastSig =
            jsLastSignificantDigit digitAt digitCount (digitCount - 1)
    in
    if firstSig == -1 then
        "0"

    else
        let
            k =
                intCount - firstSig

            n =
                lastSig - firstSig + 1

            sig =
                jsSigOfDigits digitAt firstSig lastSig 0
        in
        if k > 21 || k <= -6 then
            jsExponential sig n k

        else
            jsFixed sig n k


-- first logical digit index whose value is not "0" (-1 when all zeros)
jsFirstSignificantDigit : (Int -> Int) -> Int -> Int -> Int
jsFirstSignificantDigit digitAt count i =
    if i >= count then
        -1

    else if digitAt i == 48 then
        jsFirstSignificantDigit digitAt count (i + 1)

    else
        i


-- last logical digit index whose value is not "0" (trailing zeros stripped)
jsLastSignificantDigit : (Int -> Int) -> Int -> Int -> Int
jsLastSignificantDigit digitAt count i =
    if i < 0 then
        -1

    else if digitAt i == 48 then
        jsLastSignificantDigit digitAt count (i - 1)

    else
        i


-- significand of digits [from, to] inclusive (both logical indices)
jsSigOfDigits : (Int -> Int) -> Int -> Int -> Int -> Int
jsSigOfDigits digitAt from to acc =
    if from > to then
        acc

    else
        jsSigOfDigits digitAt (from + 1) to (acc * 10 + (digitAt from - 48))


-- digits (as Int significand), n = digit count, k = weight of d1: JS fixed
-- notation.  intPart = d1..dk, frac = dk+1..dn (or zeros when k >= n).
jsFixed : Int -> Int -> Int -> String
jsFixed sig n k =
    if k <= 0 then
        String.append "0."
            (String.append (zeroRun (0 - k)) (intDigits sig n 0))

    else if k < n then
        String.append (intDigits (sig // pow10 (n - k)) k 0)
            (String.append "." (intDigits (modBy (pow10 (n - k)) sig) (n - k) 0))

    else
        String.append (intDigits sig n 0) (zeroRun (k - n))


-- exponential: d1 [. d2..dn] e (+|-) (k-1)
jsExponential : Int -> Int -> Int -> String
jsExponential sig n k =
    String.append (intDigits (sig // pow10 (n - 1)) 1 0)
        (String.append
            (if n > 1 then
                String.append "." (intDigits (modBy (pow10 (n - 1)) sig) (n - 1) 0)

             else
                ""
            )
            (String.append "e"
                (if k - 1 >= 0 then
                    String.append "+" (fromInt (k - 1))

                 else
                    fromInt (k - 1)
                )
            )
        )


zeroRun : Int -> String
zeroRun count =
    if count <= 0 then
        ""

    else
        String.append "0" (zeroRun (count - 1))


-- decimal digits of a non-negative Int, padded WITH leading zeros to width.
intDigits : Int -> Int -> Int -> String
intDigits value width depth =
    if value < 10 then
        if width - depth > 1 then
            String.append "0" (intDigits value width (depth + 1))

        else
            stringFromChar (charFromCode (48 + value))

    else
        String.append (intDigits (value // 10) width (depth + 1))
            (stringFromChar (charFromCode (48 + modBy 10 value)))


pow10 : Int -> Int
pow10 n =
    if n <= 0 then
        1

    else
        10 * pow10 (n - 1)


-- String.fromList over the byte-level Char model (each Char is one byte).
stringFromList : List Char -> String
stringFromList chars =
    case chars of
        c :: rest ->
            String.append (stringFromChar c) (stringFromList rest)

        [] ->
            ""


-- ASCII byte case-mapping; non-ASCII bytes pass through unchanged (the
-- Unicode classification the selfhost corpus needs lives in Char.Extra's own
-- `code <= ...` range tests, not in String.toLower/toUpper).
charToLower : Char -> Char
charToLower c =
    let
        n =
            charToCode c
    in
    if 65 <= n && n <= 90 then
        charFromCode (n + 32)

    else
        c


charToUpper : Char -> Char
charToUpper c =
    let
        n =
            charToCode c
    in
    if 97 <= n && n <= 122 then
        charFromCode (n - 32)

    else
        c


stringToLower : String -> String
stringToLower s =
    stringFromList (map charToLower (stringToList s))


stringToUpper : String -> String
stringToUpper s =
    stringFromList (map charToUpper (stringToList s))


stringAny : (Char -> Bool) -> String -> Bool
stringAny f s =
    any f (stringToList s)


stringCons : Char -> String -> String
stringCons c s =
    String.append (stringFromChar c) s


stringFoldr : (Char -> b -> b) -> b -> String -> b
stringFoldr f z s =
    foldr f z (stringToList s)


-- 10^n as an exact Float (10^k is f64-exact through k = 22; larger n is a
-- product of exact factors — exactness is not required there, only use as a
-- division denominator when <= 22).
pow10Float : Int -> Float
pow10Float n =
    if n <= 0 then
        1

    else if n > 22 then
        pow10Float 22 * pow10Float (n - 22)

    else
        pow10FloatExact n


pow10FloatExact : Int -> Float
pow10FloatExact n =
    if n == 0 then
        1

    else
        10 * pow10FloatExact (n - 1)


-- Decimal -> Float over the grammar ParserFast pre-validates
-- (digits [ '.' digits ] [ ('e'|'E') ['+'|'-'] digits ]).  Byte semantics:
-- scan with charCode, never String.toList.  Correct rounding = ONE f/
-- division of two exact f64 operands: an integer significand N (exact in
-- f64, so at most 2^53) and 10^scale (exact through scale = 22).  IEEE
-- division rounds once, so N / 10^scale is the correctly-rounded value of
-- the decimal — bit-identical to JS's unary + and real Elm's String.toFloat
-- on this grammar.  A negative final scale (exponent overcame the fraction,
-- e.g. 15e2) folds the shift into the significand (still one division; the
-- shifted integer stays exact while it fits 2^53).  Returns Nothing outside
-- the grammar (real Elm's toFloat parity for malformed input).  The walkers
-- are TOP-LEVEL: let-bound functions cannot see their own name, so
-- self-recursion must live at module scope.
stringToFloat : String -> Maybe Float
stringToFloat s =
    let
        len =
            String.length s
    in
    if len == 0 || not (48 <= charCode s 0 && charCode s 0 <= 57) then
        Nothing

    else
        case floatSignificandScale s len 0 False 0 0 of
            Nothing ->
                Nothing

            Just ( value, scale, at ) ->
                if at >= len then
                    floatCombine value scale 0

                else if charCode s at == 101 || charCode s at == 69 then
                    let
                        first =
                            at + 1

                        afterSign =
                            if charCode s first == 43 || charCode s first == 45 then
                                first + 1

                            else
                                first

                        negated =
                            charCode s first == 45
                    in
                    if afterSign >= len || not (48 <= charCode s afterSign && charCode s afterSign <= 57) then
                        Nothing

                    else
                        case floatExponentValue s len afterSign 0 of
                            Nothing ->
                                Nothing

                            Just exponent ->
                                floatCombine value scale
                                    (if negated then 0 - exponent else exponent)

                else
                    Nothing


-- significand and decimal scale of digits [j, len), stopping at the first
-- non-digit; returns (value, scale, offsetStoppedAt).  fracSeen guards the
-- single '.'; each fraction digit INCREMENTS the scale, so `scale` is the
-- positive power of ten the significand must be divided by (floatCombine's
-- convention: value * 10^exponent / 10^scale).
floatSignificandScale : String -> Int -> Int -> Bool -> Int -> Int -> Maybe ( Int, Int, Int )
floatSignificandScale s len j fracSeen value scale =
    if j >= len then
        Just ( value, scale, j )

    else if charCode s j == 46 then
        -- '.' must introduce a fraction digit run (no "1." / "1..2")
        if fracSeen || not (48 <= charCode s (j + 1) && charCode s (j + 1) <= 57) then
            Nothing

        else
            floatSignificandScale s len (j + 1) True value scale

    else if 48 <= charCode s j && charCode s j <= 57 then
        floatSignificandScale s len (j + 1) fracSeen
            (value * 10 + (charCode s j - 48))
            (if fracSeen then scale + 1 else scale)

    else
        Just ( value, scale, j )


-- unsigned exponent digits [j, len)
floatExponentValue : String -> Int -> Int -> Int -> Maybe Int
floatExponentValue s len j acc =
    if j >= len then
        Just acc

    else if 48 <= charCode s j && charCode s j <= 57 then
        floatExponentValue s len (j + 1) (acc * 10 + (charCode s j - 48))

    else
        Nothing


-- value * 10^exponent / 10^scale as ONE exact-operand division
floatCombine : Int -> Int -> Int -> Maybe Float
floatCombine value scale exponent =
    let
        total =
            scale - exponent
    in
    if total <= 0 then
        floatShiftedDivide value (0 - total) 1

    else if total <= 22 then
        Just (basicsToFloat value / pow10Float total)

    else
        -- fraction deeper than 22: shift the significand (stays exact while
        -- it fits 2^53) and divide by 10^22
        floatShiftedDivide value (total - 22) (pow10Float 22)


floatShiftedDivide : Int -> Int -> Float -> Maybe Float
floatShiftedDivide value shift denominator =
    if shift <= 0 then
        Just (basicsToFloat value / denominator)

    else
        floatShiftedDivide (value * 10) (shift - 1) denominator


charIsLower : Char -> Bool
charIsLower c =
    let
        n =
            charToCode c
    in
    97 <= n && n <= 122


charIsUpper : Char -> Bool
charIsUpper c =
    let
        n =
            charToCode c
    in
    65 <= n && n <= 90


charIsAlpha : Char -> Bool
charIsAlpha c =
    charIsLower c || charIsUpper c


charIsDigit : Char -> Bool
charIsDigit c =
    let
        n =
            charToCode c
    in
    48 <= n && n <= 57


charIsOctDigit : Char -> Bool
charIsOctDigit c =
    let
        n =
            charToCode c
    in
    48 <= n && n <= 55


charIsHexDigit : Char -> Bool
charIsHexDigit c =
    charIsDigit c
        || (let
                n =
                    charToCode c
            in
            97 <= n && n <= 102 || 65 <= n && n <= 70
           )


charIsAlphaNum : Char -> Bool
charIsAlphaNum c =
    charIsAlpha c || charIsDigit c


-- TRUSTED: the VM number is untyped (Int/Float promote), so the identity is
-- the faithful Int->Float widening.
basicsToFloat : Int -> Float
basicsToFloat n =
    n


-- A Char's byte code is never NaN; the surrogate probe in Char.Extra needs
-- the Float-typed predicate to exist, and this is its faithful byte reading.
basicsIsNaN : Float -> Bool
basicsIsNaN f =
    False
