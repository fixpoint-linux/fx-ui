module BitwisePins exposing (main)

-- Bitwise int32 pins (elm/core Bitwise semantics through the zinc-vm
-- prims): and/or/xor/complement truncation to 32 bits, shift-count &31
-- masking, arithmetic vs zero-fill right shift — incl. the upstream doc
-- examples (shiftRightZfBy 1 -32 == 2147483632, shiftRightZfBy 27
-- 0xFFFFFFFF == 31, the bitMask computation itself).  Negative operands
-- are written `0 - n` because `f x -1` would parse as subtraction.
-- Every check contributes a raw value or a 0/1 flag to one Int sum
-- (hand-computed: 12 flags + raw 31+250+90+31+32 = 434 -> 446).

b x =
    case x of
        True ->
            1

        False ->
            0


neg32 =
    0 - 32


main =
    let
        checks =
            b (Bitwise.and 0x1F 0xFFFFFFFF == 31)
                + b (Bitwise.and 240 170 == 160)
                + b (Bitwise.or 136 34 == 170)
                + b (Bitwise.xor 170 240 == 90)
                + b (Bitwise.complement 5 == (0 - 6))
                + b (Bitwise.complement 0xFFFFFFFF == 0)
                + b (Bitwise.shiftLeftBy 32 1 == 1)
                + b (Bitwise.shiftLeftBy 5 1 == 32)
                + b (Bitwise.shiftRightBy 1 neg32 == (0 - 16))
                + b (Bitwise.shiftRightBy 4 32 == 2)
                + b (Bitwise.shiftRightZfBy 1 neg32 == 2147483632)
                + b (Bitwise.shiftRightZfBy 27 0xFFFFFFFF == 31)

        raws =
            Bitwise.and 0x1F 0xFFFFFFFF
                + Bitwise.or 240 170
                + Bitwise.xor 240 170
                + Bitwise.shiftRightZfBy 27 0xFFFFFFFF
                + Bitwise.shiftLeftBy 5 1
    in
    checks + raws
