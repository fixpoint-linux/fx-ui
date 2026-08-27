module Zinc.Emit exposing
    ( Label
    , Target(..)
    , Instr(..)
    , addressMap
    , resolve
    , flatten
    )

-- The flat ZINC bytecode emitter (see src/vm/parser.zig for the opcode set).
--
-- Each `Instr` is one logical instruction in the flat stream.  Opcodes and
-- their operands flatten to consecutive csexp atoms:
--
--   Pushmark        -> m            Apply   -> p   Appterm -> t
--   Grab            -> r            Return  -> v   Let_    -> e   Endlet -> d
--   Access n        -> a [..:n]n
--   Global name     -> g [..:s]name
--   Jmpf/Jmp target -> f/j [..:n]pc
--   Number_ n       -> n [..:n]n
--   Symbol name     -> s [..:s]name
--   String_ s       -> S [..:S]s
--   Boolean_ b      -> b [..:b]true|false
--   Prim name       -> P [..:s]name
--   Cur body        -> c ( body )          (one instruction, nested list body)
--   Label_ _        -> (marker, emits nothing, counts 0)
--
-- Jumps carry a `Target`.  The source-level compiler writes forward references
-- as `TRef label`; before flattening, `resolve` performs a two-pass pass that
-- assigns an absolute program counter to every instruction (each `Cur` counts
-- as one instruction even though it wraps a nested list; a `Label_` marker
-- counts as zero) and then replaces every `TRef` with the absolute pc of the
-- matching label.  Each `Cur` body is resolved independently, mirroring how the
-- VM's resolve_jumps recurses into closure bodies.

import Dict exposing (Dict)
import Zinc.Csexp as Csexp


type alias Label =
    String


type Target
    = TRef Label
    | TAbs Int


type Instr
    = Pushmark
    | Apply
    | Appterm
    | Grab
    | Return
    | Let_
    | Endlet
    | Access Int
    | Global String
    | Jmpf Target
    | Jmp Target
    | Number_ Int
    | Float_ Float
    | Symbol String
    | String_ String
    | Boolean_ Bool
    | Prim String
    | Cur (List Instr)
    | Label_ Label


addressMap : List Instr -> Dict Label Int
addressMap instrs =
    walk 0 instrs Dict.empty


walk : Int -> List Instr -> Dict Label Int -> Dict Label Int
walk pc instrs acc =
    case instrs of
        [] ->
            acc

        Label_ label :: rest ->
            -- Labels do not advance the pc.
            walk pc rest (Dict.insert label pc acc)

        _ :: rest ->
            walk (pc + 1) rest acc


resolve : List Instr -> List Instr
resolve instrs =
    let
        labels =
            addressMap instrs
    in
    List.map (resolveInstr labels) instrs


resolveInstr : Dict Label Int -> Instr -> Instr
resolveInstr labels instr =
    case instr of
        Jmpf target ->
            Jmpf (resolveTarget labels target)

        Jmp target ->
            Jmp (resolveTarget labels target)

        Cur body ->
            -- Each closure body has its own label space.
            Cur (resolve body)

        other ->
            other


resolveTarget : Dict Label Int -> Target -> Target
resolveTarget labels target =
    case target of
        TAbs n ->
            TAbs n

        TRef label ->
            case Dict.get label labels of
                Just pc ->
                    TAbs pc

                Nothing ->
                    -- Undefined label: leave unresolved so it is visible in the
                    -- output (flatten renders an unresolved ref as [1:n]0).
                    TRef label


flatten : List Instr -> String
flatten instrs =
    "(" ++ String.join " " (List.filterMap instrText instrs) ++ ")"


instrText : Instr -> Maybe String
instrText instr =
    case instr of
        Pushmark ->
            Just "m"

        Apply ->
            Just "p"

        Appterm ->
            Just "t"

        Grab ->
            Just "r"

        Return ->
            Just "v"

        Let_ ->
            Just "e"

        Endlet ->
            Just "d"

        Access n ->
            Just ("a " ++ Csexp.numberAtom n)

        Global name ->
            Just ("g " ++ Csexp.symbolAtom name)

        Jmpf target ->
            Just ("f " ++ targetText target)

        Jmp target ->
            Just ("j " ++ targetText target)

        Number_ n ->
            Just ("n " ++ Csexp.numberAtom n)

        Float_ f ->
            Just ("F " ++ Csexp.floatAtom f)

        Symbol name ->
            Just ("s " ++ Csexp.symbolAtom name)

        String_ str ->
            Just ("S " ++ Csexp.stringAtom str)

        Boolean_ bool ->
            Just ("b " ++ Csexp.booleanAtom bool)

        Prim name ->
            Just ("P " ++ Csexp.symbolAtom name)

        Cur body ->
            Just ("c " ++ flatten body)

        Label_ _ ->
            Nothing


targetText : Target -> String
targetText target =
    case target of
        TAbs n ->
            Csexp.numberAtom n

        TRef _ ->
            -- Should not survive a correct resolve; render 0 so the output is
            -- still parseable and the bug is detectable in diffs.
            "[1:n]0"
