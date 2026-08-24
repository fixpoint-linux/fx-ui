module Zinc.Csexp exposing
    ( utf8ByteLength
    , numberAtom
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
--
-- A LIST is  (elem elem ...)  with single-space separators, and a BUNDLE is a
-- list of (name code) entries.
--
-- The length prefix counts BYTES, not code points.  Elm's String.length counts
-- code points and is WRONG for the prefix whenever the value contains a
-- multi-byte UTF-8 character (é = 2 bytes, 🦀 = 4 bytes), so the emitter must
-- compute the UTF-8 byte length itself — utf8ByteLength below.


utf8ByteLength : String -> Int
utf8ByteLength str =
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
