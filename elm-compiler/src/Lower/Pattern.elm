module Lower.Pattern exposing
    ( Step(..)
    , ValuePath(..)
    , Binding
    , PatternResult
    , compilePattern
    , pathInstrs
    , normalizeClauses
    )

-- M2 pattern compiler for the Elm -> ZINC-csexp compiler.
--
-- A PURE helper (imports only elm-syntax + Zinc.Emit, NOT Lower.Expr): it turns
-- an elm-syntax `Pattern` into a list of match tests plus a list of name
-- bindings, each expressed relative to a scrutinee value.  The actual case
-- lowering lives in Lower/Expr.elm, which CALLS compilePattern — this keeps the
-- Expr<->Pattern import acyclic.
--
-- Values are represented as:
--   * Int/Bool/String/Char        -> the flat atom (== compares directly)
--   * unit ()                     -> Symbol "()"
--   * tuple (a,b)                 -> cons(a, cons(b, ...)) via @p
--   * list [a,b]                  -> cons(a, cons(b, nil)) via cons
--   * ADT ctor (Tag a1..an)       -> vector[tag, a1..an] via absvector + address-> (index 0 = tag Symbol)
--   * record { f = v, ... }       -> assoc list of (fieldSymbol, value) pairs
--   * Bool True/False in patterns -> NamedPattern (no BoolPattern variant),
--     so it is special-cased to a boolean `=` comparison.

import Elm.Syntax.Expression as Expression exposing (Expression)
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Pattern as Pattern exposing (Pattern(..), QualifiedNameRef)
import Elm.Syntax.Range as Range exposing (Range)
import Zinc.Emit as Emit exposing (Instr(..))


type Step
    = FstStep
    | SndStep
    | HdStep
    | TlStep
    | IdxStep Int


-- A value path locates a (sub-)value inside a scrutinee: walk a sequence of
-- de-structuring steps from the scrutinee root.  VField additionally treats the
-- reached value as a record and looks up field `f` (assoc + snd).
type ValuePath
    = VPath (List Step)
    | VField (List Step) String


type alias Binding =
    ( String, ValuePath )


type alias PatternResult =
    { tests : List (List Instr)
    , bindings : List Binding
    }


-- compilePattern : current-module-name -> pattern -> tests + bindings.
-- The first argument lets the ctor tag check reject foreign-qualified ADT
-- patterns (self-qualified ones resolve to the same tag symbol).
compilePattern : List String -> Node Pattern.Pattern -> Result String PatternResult
compilePattern modName (Node _ pat) =
    go modName pat []


-- go : moduleName -> pattern -> value path (relative to scrutinee root)
-- `readPath path = emitRead 0 path` emits a read of the value at `path`,
-- always from the scrutinee temp slot (index 0 in the caller's running
-- indexing; the caller re-bases it via pathInstrs).
go : List String -> Pattern.Pattern -> List Step -> Result String PatternResult
go modName pat path =
    case pat of
        AllPattern ->
            Ok emptyResult

        VarPattern name ->
            Ok { tests = [], bindings = [ ( name, VPath path ) ] }

        UnitPattern ->
            Ok { tests = [ readPath path ++ [ Symbol "()", Prim "=" ] ], bindings = [] }

        CharPattern c ->
            Ok { tests = [ readPath path ++ [ String_ (String.fromChar c), Prim "=" ] ], bindings = [] }

        StringPattern s ->
            Ok { tests = [ readPath path ++ [ String_ s, Prim "=" ] ], bindings = [] }

        IntPattern n ->
            Ok { tests = [ readPath path ++ [ Number_ n, Prim "=" ] ], bindings = [] }

        HexPattern n ->
            Ok { tests = [ readPath path ++ [ Number_ n, Prim "=" ] ], bindings = [] }

        FloatPattern _ ->
            Err "float patterns not supported"

        TuplePattern subs ->
            tuplePattern modName subs path

        UnConsPattern left right ->
            unConsPattern modName left right path

        ListPattern [] ->
            Ok { tests = [ readPath path ++ [ Prim "empty?" ] ], bindings = [] }

        ListPattern (p :: ps) ->
            listPattern modName (p :: ps) path

        NamedPattern qref subs ->
            namedPattern modName qref subs path

        AsPattern inner alias ->
            go modName (nodeValue inner) path
                |> Result.map (\res -> { res | bindings = res.bindings ++ [ ( nodeString alias, VPath path ) ] })

        ParenthesizedPattern inner ->
            go modName (nodeValue inner) path

        RecordPattern fields ->
            Ok
                { tests = []
                , bindings = List.map (\f -> ( nodeString f, VField path (nodeString f) )) fields
                }


emptyResult : PatternResult
emptyResult =
    { tests = [], bindings = [] }


tuplePattern : List String -> List (Node Pattern.Pattern) -> List Step -> Result String PatternResult
tuplePattern modName subs path =
    case subs of
        [] ->
            Err "empty tuple pattern"

        [ _ ] ->
            Err "single-element tuple pattern"

        _ ->
            let
                n =
                    List.length subs
            in
            -- A tuple is a cons chain; (a,b,...) = cons(a, cons(b, ...)).
            -- Element j is reached by fst after j snd-steps, EXCEPT the last
            -- element which is the terminal cdr (so no trailing fst).
            recurseIndexed modName subs (\j -> path ++ List.repeat j SndStep ++ (if j < n - 1 then [ FstStep ] else []))
                |> Result.map (\res -> { res | tests = [ readPath path ++ [ Prim "cons?" ] ] ++ res.tests })


unConsPattern : List String -> Node Pattern.Pattern -> Node Pattern.Pattern -> List Step -> Result String PatternResult
unConsPattern modName left right path =
    go modName (nodeValue left) (path ++ [ HdStep ])
        |> Result.andThen (\lres ->
            go modName (nodeValue right) (path ++ [ TlStep ])
                |> Result.map (\rres -> { tests = [ readPath path ++ [ Prim "cons?" ] ] ++ lres.tests ++ rres.tests, bindings = lres.bindings ++ rres.bindings })
        )


listPattern : List String -> List (Node Pattern.Pattern) -> List Step -> Result String PatternResult
listPattern modName elems path =
    let
        n =
            List.length elems

        consTests =
            List.range 0 (n - 1)
                |> List.map (\j -> readPath (path ++ List.repeat j TlStep) ++ [ Prim "cons?" ])

        emptyTest =
            [ readPath (path ++ List.repeat n TlStep) ++ [ Prim "empty?" ] ]
    in
    recurseIndexed modName elems (\j -> path ++ List.repeat j TlStep ++ [ HdStep ])
        |> Result.map (\res -> { res | tests = consTests ++ emptyTest ++ res.tests })


-- Recurse into each sub-pattern at a path given by its index; merge child
-- tests and bindings in source order.
recurseIndexed : List String -> List (Node Pattern.Pattern) -> (Int -> List Step) -> Result String PatternResult
recurseIndexed modName subs pathOf =
    recurseIndexedHelp modName 0 subs pathOf


recurseIndexedHelp : List String -> Int -> List (Node Pattern.Pattern) -> (Int -> List Step) -> Result String PatternResult
recurseIndexedHelp modName idx subs pathOf =
    case subs of
        [] ->
            Ok emptyResult

        sub :: rest ->
            go modName (nodeValue sub) (pathOf idx)
                |> Result.andThen (\headRes ->
                    recurseIndexedHelp modName (idx + 1) rest pathOf
                        |> Result.map (\tailRes -> mergeResults headRes tailRes)
                )


namedPattern : List String -> QualifiedNameRef -> List (Node Pattern.Pattern) -> List Step -> Result String PatternResult
namedPattern modName qref subs path =
    if List.isEmpty qref.moduleName && (qref.name == "True" || qref.name == "False") then
        -- Bool patterns arrive as NamedPattern (no BoolPattern variant).
        -- MUST compare against the boolean atom, NOT the ADT cons?/fst=tag
        -- scheme (a boolean never matches a cons tag).
        case subs of
            [] ->
                Ok { tests = [ readPath path ++ [ Boolean_ (qref.name == "True"), Prim "=" ] ], bindings = [] }

            _ ->
                Err "boolean pattern cannot have sub-patterns"

    else if not (List.isEmpty qref.moduleName) && qref.moduleName /= modName then
        Err ("foreign ADTs are M3: " ++ String.join "." qref.moduleName ++ "." ++ qref.name)

    else
        let
            tag =
                qref.name

            -- The absvector? guard MUST precede any <-address: a non-vector
            -- scrutinee fails the clause cleanly via jmpf instead of crashing
            -- <-address's unguarded index read.
            baseTests =
                [ readPath path ++ [ Prim "absvector?" ]
                , readPath (path ++ [ IdxStep 0 ]) ++ [ Symbol tag, Prim "=" ]
                ]
        in
        recurseIndexed modName subs (\j -> path ++ [ IdxStep (j + 1) ])
            |> Result.map (\res -> { res | tests = baseTests ++ res.tests })


mergeResults : PatternResult -> PatternResult -> PatternResult
mergeResults a b =
    { tests = a.tests ++ b.tests
    , bindings = a.bindings ++ b.bindings
    }


-- Read the value at `path` from the scrutinee temp slot (Access 0).
readPath : List Step -> List Instr
readPath steps =
    emitRead 0 steps


-- Turn a ValuePath into instructions to load it, rooted at de Bruijn index
-- `idx` (the running scrutinee temp slot index).  VField walks the steps to a
-- record then assoc-extracts field `f` (assoc returns the matching pair, so
-- snd yields the value).
pathInstrs : ValuePath -> Int -> List Instr
pathInstrs path idx =
    case path of
        VPath steps ->
            emitRead idx steps

        VField steps field ->
            emitRead idx steps ++ [ Symbol field, Prim "assoc", Prim "snd" ]


-- Emit a read of the value at `steps` from slot `idx` as ONE prefix/suffix
-- stream.  Fst/Snd/Hd/Tl stay post-fix prims in the SUFFIX; IdxStep j pushes
-- Number_ j into the PREFIX (before the Access) and emits `<-address` into the
-- SUFFIX (after), so with nested vectors the indices stack deepest-first and
-- each `<-address` dereferences after its index push.  `<-address` pops vec
-- first then idx, so the index push must precede the vector push.
emitRead : Int -> List Step -> List Instr
emitRead idx steps =
    let
        ( prefix, suffix ) =
            List.foldl collectStep ( [], [] ) steps
    in
    prefix ++ (Access idx :: suffix)


collectStep : Step -> ( List Instr, List Instr ) -> ( List Instr, List Instr )
collectStep step ( prefix, suffix ) =
    case step of
        FstStep ->
            ( prefix, suffix ++ [ Prim "fst" ] )

        SndStep ->
            ( prefix, suffix ++ [ Prim "snd" ] )

        HdStep ->
            ( prefix, suffix ++ [ Prim "hd" ] )

        TlStep ->
            ( prefix, suffix ++ [ Prim "tl" ] )

        IdxStep j ->
            ( Number_ j :: prefix, suffix ++ [ Prim "<-address" ] )


-- Desugar a list of (args, body) clauses (from a multi-clause / pattern-arg
-- function or a pattern lambda) into a single normal form:
--
--   * a function taking `n` fresh variable args ($arg0..$arg(n-1), illegal in
--     Elm so collision-free), and
--   * a `case` body that pattern-matches a tuple of those args (or the single
--     arg for n == 1) against the original patterns, binding the original
--     pattern variables in the clause bodies.
--
-- Returns ( freshArgNodes, caseNode ).
normalizeClauses : List ( List (Node Pattern.Pattern), Node Expression ) -> Result String ( List (Node Pattern.Pattern), Node Expression )
normalizeClauses clauses =
    case clauses of
        [] ->
            Err "empty clause list"

        ( firstArgs, firstBody ) :: _ ->
            let
                n =
                    List.length firstArgs

                uniform =
                    List.all (\(args, _) -> List.length args == n) clauses

                range =
                    Node.range firstBody

                freshNames =
                    List.map (\i -> "$arg" ++ String.fromInt i) (List.range 0 (n - 1))

                freshArgNodes =
                    List.map (\nm -> Node Range.empty (VarPattern nm)) freshNames

                scrutinee =
                    if n == 1 then
                        Node range (Expression.FunctionOrValue [] "$arg0")

                    else
                        Node range (Expression.TupledExpression (List.map (\nm -> Node range (Expression.FunctionOrValue [] nm)) freshNames))

                cases =
                    List.map
                        (\( args, body ) -> ( wrapPattern n args range, body ))
                        clauses

                caseNode =
                    Node range (Expression.CaseExpression { expression = scrutinee, cases = cases })
            in
            if uniform then
                Ok ( freshArgNodes, caseNode )

            else
                Err "clauses have differing arity"


wrapPattern : Int -> List (Node Pattern.Pattern) -> Range -> Node Pattern.Pattern
wrapPattern n args range =
    case n of
        1 ->
            -- Single arg: use the pattern directly (no tuple wrapper).
            List.head args |> Maybe.withDefault (Node Range.empty (VarPattern ""))

        _ ->
            Node range (TuplePattern args)


nodeValue : Node a -> a
nodeValue (Node _ v) =
    v


nodeString : Node String -> String
nodeString (Node _ s) =
    s
