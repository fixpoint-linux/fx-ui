module Zinc.Emit exposing
    ( Label
    , Target(..)
    , Const(..)
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
-- P3 superinstructions (fused by `fuse` inside `resolve`; see below):
--
--   AccessPrim n p  -> A [..:n]n [..:s]p   (access + prim)
--   ConstPrim c p   -> K <lit-atom> [..:s]p (literal load + prim)
--   PrimReturn p    -> V [..:s]p            (prim + return)
--   GlobalApply g   -> Q [..:s]g            (global + apply)
--   GlobalAppterm g -> R [..:s]g            (global + appterm)
--
-- Jumps carry a `Target`.  The source-level compiler writes forward references
-- as `TRef label`; before flattening, `resolve` first runs the `fuse` peephole
-- over the stream (greedy, label-blocked, recursing into Cur bodies), THEN does
-- the existing two-pass pc assignment over the FUSED layout — so every TRef
-- retargets to the fused pc automatically, no manual jump rewriting.  Each
-- `Cur` body is resolved independently, mirroring how the VM's resolve_jumps
-- recurses into closure bodies.

import Dict exposing (Dict)
import Zinc.Csexp as Csexp


type alias Label =
    String


type Target
    = TRef Label
    | TAbs Int


type Const
    = CNumber Int
    | CFloat Float
    | CSymbol String
    | CString String
    | CBoolean Bool


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
    | AccessPrim Int String
    | ConstPrim Const String
    | GlobalApply String
    | GlobalAppterm String
    | PrimReturn String
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
        -- P3 peephole: fuse superinstruction pairs BEFORE pc assignment so
        -- the label map (and thus every TRef retarget) is computed against
        -- the fused layout.
        fused =
            fuse instrs

        labels =
            addressMap fused
    in
    List.map (resolveInstr labels) fused


-- P3 peephole: greedy, left-to-right, non-overlapping fusion of the measured
-- hot bigrams into single superinstructions.  HARD RULE: never fuse across a
-- Label_ — a label marks a jump target at the SECOND instruction position, so
-- fusing through it would redirect that jump to the first op.  The label is
-- only ever a first or second element (never matched as the operand of a
-- pair), so `fusePair` returning Nothing on it blocks the merge naturally;
-- Cur bodies are recursed into (wrapper bodies are the hottest code).
fuse : List Instr -> List Instr
fuse instrs =
    case instrs of
        [] ->
            []

        [ single ] ->
            [ fuseInstr single ]

        x :: y :: rest ->
            case fusePair x y of
                Just merged ->
                    merged :: fuse rest

                Nothing ->
                    fuseInstr x :: fuse (y :: rest)


fuseInstr : Instr -> Instr
fuseInstr instr =
    case instr of
        Cur body ->
            Cur (fuse body)

        other ->
            other


fusePair : Instr -> Instr -> Maybe Instr
fusePair x y =
    case ( x, y ) of
        ( Access n, Prim p ) ->
            Just (AccessPrim n p)

        ( Number_ n, Prim p ) ->
            Just (ConstPrim (CNumber n) p)

        ( Float_ f, Prim p ) ->
            Just (ConstPrim (CFloat f) p)

        ( Symbol s, Prim p ) ->
            Just (ConstPrim (CSymbol s) p)

        ( String_ s, Prim p ) ->
            Just (ConstPrim (CString s) p)

        ( Boolean_ b, Prim p ) ->
            Just (ConstPrim (CBoolean b) p)

        ( Global g, Apply ) ->
            Just (GlobalApply g)

        ( Global g, Appterm ) ->
            Just (GlobalAppterm g)

        ( Prim p, Return ) ->
            Just (PrimReturn p)

        _ ->
            Nothing


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

        AccessPrim n p ->
            Just ("A " ++ Csexp.numberAtom n ++ " " ++ Csexp.symbolAtom p)

        ConstPrim c p ->
            Just ("K " ++ constText c ++ " " ++ Csexp.symbolAtom p)

        GlobalApply g ->
            Just ("Q " ++ Csexp.symbolAtom g)

        GlobalAppterm g ->
            Just ("R " ++ Csexp.symbolAtom g)

        PrimReturn p ->
            Just ("V " ++ Csexp.symbolAtom p)

        Cur body ->
            Just ("c " ++ flatten body)

        Label_ _ ->
            Nothing


constText : Const -> String
constText c =
    case c of
        CNumber n ->
            Csexp.numberAtom n

        CFloat f ->
            Csexp.floatAtom f

        CSymbol s ->
            Csexp.symbolAtom s

        CString s ->
            Csexp.stringAtom s

        CBoolean b ->
            Csexp.booleanAtom b


targetText : Target -> String
targetText target =
    case target of
        TAbs n ->
            Csexp.numberAtom n

        TRef _ ->
            -- Should not survive a correct resolve; render 0 so the output is
            -- still parseable and the bug is detectable in diffs.
            "[1:n]0"
