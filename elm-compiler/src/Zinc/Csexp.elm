module Zinc.Csexp exposing
    ( utf8ByteLength
    , numberAtom
    , floatAtom
    , symbolAtom
    , stringAtom
    , booleanAtom
    , list
    , bundleEntry
    )

-- The ZINC flat csexp text format (see src/vm/parser.zig for the reader).
--
-- An ATOM is written as  [len:type]value  where `len` is the BYTE length of the
-- value and `type` is one of:
--
--   's' symbol   (len = byte length of the name)
--   'n' number   (len = byte length of the decimal text; may be negative)
--   'S' string   (len = byte length of the UTF-8 bytes)
--   'b' boolean  (len = 4 for "true", 5 for "false")
--   'F' float    (len = byte length of String.fromFloat's decimal/scientific text)
--
-- A LIST is  (elem elem ...)  with single-space separators, and a BUNDLE is a
-- list of (name code) entries.
--
-- The length prefix counts BYTES, not code points.  Under real Elm,
-- String.length counts code points and is WRONG for the prefix whenever the
-- value contains a multi-byte UTF-8 character (é = 2 bytes, 🦀 = 4 bytes),
-- so the emitter must compute the UTF-8 byte length itself — utf8ByteLength
-- below.


{-| This module runs under TWO runtimes with opposite String semantics, and
both must emit the same (byte-count) prefixes:

  - real Elm (compiler.js on node): Strings are CODE-POINT indexed —
    String.length "é" == 1, String.toList yields one Char per code point.
  - the fx Zig VM (selfhost.csexp): Strings are BYTE indexed —
    String.length "é" == 2 (the UTF-8 byte count) and String.toList yields
    one Char per BYTE, so summing charUtf8Length over it would count every
    continuation byte as 2 and over-count.

The code-point sum is only correct under code-point semantics; under byte
semantics String.length already IS the UTF-8 byte count.  Probe which runtime
we are in by measuring a string whose two measures differ.
-}
stringIsByteIndexed : Bool
stringIsByteIndexed =
    String.length "é" == 2


utf8ByteLength : String -> Int
utf8ByteLength str =
    if stringIsByteIndexed then
        String.length str

    else
        List.sum (List.map charUtf8Length (String.toList str))


charUtf8Length : Char -> Int
charUtf8Length char =
    let
        code = Char.toCode char
    in
    if code <= 0x007F then
        1

    else if code <= 0x07FF then
        2

    else if code <= 0xFFFF then
        3

    else
        4


atom : Char -> String -> String
atom typeChar payload =
    "["
        ++ String.fromInt (utf8ByteLength payload)
        ++ ":"
        ++ String.fromChar typeChar
        ++ "]"
        ++ payload


numberAtom : Int -> String
numberAtom n =
    atom 'n' (String.fromInt n)


floatAtom : Float -> String
floatAtom f =
    atom 'F' (String.fromFloat f)


symbolAtom : String -> String
symbolAtom name =
    atom 's' name


stringAtom : String -> String
stringAtom str =
    atom 'S' str


booleanAtom : Bool -> String
booleanAtom bool =
    atom 'b' (if bool then "true" else "false")


list : List String -> String
list elems =
    "(" ++ String.join " " elems ++ ")"


bundleEntry : String -> String -> String
bundleEntry name code =
    list [ symbolAtom name, code ]
