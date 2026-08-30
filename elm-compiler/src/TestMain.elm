port module TestMain exposing (main)

-- M1a unit-test harness for the emitter infrastructure.  NOT part of the
-- compiler (Main.elm stays the M0 parse driver).  Built separately with:
--
--   ELM_HOME=.elm-cache elm make src/TestMain.elm --output=test-compiler.js
--   node test-run.js
--
-- Every assertion prints a "PASS <name>" or "FAIL <name>" line over the
-- `report` port; test-run.js exits nonzero if any FAIL appears.

import Dict
import Elm.Parser
import Elm.Syntax.Declaration as Declaration
import Elm.Syntax.Expression as Expression
import Elm.Syntax.File as File
import Elm.Syntax.Node as Node exposing (Node(..))
import Elm.Syntax.Range as Range
import Platform
import Type.Builtins as Builtins
import Type.Env as Env
import Type.Error as Error
import Type.Infer as Infer
import Type.Representation as Rep
import Type.Unify as Uni
import Zinc.Csexp as Csexp
import Zinc.Emit as Emit
import Lower.Resolve as Resolve
import Lower.Scope as Scope


port report : String -> Cmd msg


type Msg
    = Noop


main : Program () () Msg
main =
    Platform.worker
        { init = \_ -> ( (), runTests )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


runTests : Cmd Msg
runTests =
    report (String.join "\n" checks)


checks : List String
checks =
    [ check "utf8ByteLength 'héllo' == 6" (Csexp.utf8ByteLength "héllo" == 6)
    , check "utf8ByteLength '🦀' == 4" (Csexp.utf8ByteLength "🦀" == 4)
    , check "utf8ByteLength 'abcde' == 5" (Csexp.utf8ByteLength "abcde" == 5)
    , check "utf8ByteLength '' == 0" (Csexp.utf8ByteLength "" == 0)
    , check "numberAtom 5 == [1:n]5" (Csexp.numberAtom 5 == "[1:n]5")
    , check "numberAtom -1 == [2:n]-1" (Csexp.numberAtom (-1) == "[2:n]-1")
    , check "symbolAtom cons == [4:s]cons" (Csexp.symbolAtom "cons" == "[4:s]cons")
    , check "booleanAtom True == [4:b]true" (Csexp.booleanAtom True == "[4:b]true")
    , check "booleanAtom False == [5:b]false" (Csexp.booleanAtom False == "[5:b]false")
    , check "stringAtom é == [2:S]é" (Csexp.stringAtom "é" == "[2:S]é")
    , check "scope innermost == 0" (Scope.resolve "x" (Scope.push "x" (Scope.push "y" Scope.empty)) == Just 0)
    , check "scope one out == 1" (Scope.resolve "y" (Scope.push "x" (Scope.push "y" Scope.empty)) == Just 1)
    , check "scope not found == Nothing" (Scope.resolve "z" (Scope.push "x" Scope.empty) == Nothing)
    , check "scope pop" (Scope.resolve "y" (Scope.pop (Scope.push "x" (Scope.push "y" Scope.empty))) == Just 0)
    , check "addressMap forward jmpf" (forwardLabelResolved)
    , check "flatten resolved program" (Emit.flatten (Emit.resolve forwardProgram) == forwardFlattened)
    , check "cur counts one, nested label resolved" (Emit.flatten (Emit.resolve curProgram) == curFlattened)

    -- Type.Representation pretty-printer: scoped rows render VERBATIM (duplicate
    -- labels are not collapsed), row tails show their variable, function types
    -- parenthesize their argument.
    , check "pretty scoped row keeps duplicate labels"
        (Rep.pretty (Rep.TRecord { fields = [ ( "x", Rep.tInt ), ( "x", Rep.tBool ) ], tail = Rep.REmpty }) == "{x:Int, x:Bool}")
    , check "pretty row with tail"
        (Rep.pretty (Rep.TRecord { fields = [ ( "x", Rep.tInt ) ], tail = Rep.RVar (Rep.var 1 Rep.KRow Rep.FNone) }) == "{x:Int| a}")
    , check "pretty function parenthesizes left"
        (Rep.pretty (Rep.TFun (Rep.TFun Rep.tInt Rep.tInt) Rep.tInt) == "(Int -> Int) -> Int")
    , check "pretty list of function"
        (Rep.pretty (Rep.tList (Rep.TFun Rep.tInt Rep.tString)) == "List (Int -> String)")
    , check "pretty shares variable names"
        (Rep.pretty (Rep.TFun (Rep.TVar (Rep.var 0 Rep.KType Rep.FNone)) (Rep.TVar (Rep.var 0 Rep.KType Rep.FNone))) == "a -> a")

    -- Type.Representation substitution/zonk/occurs.
    , check "zonk replaces a type variable"
        (Rep.zonk (Rep.extend (Rep.var 0 Rep.KType Rep.FNone) Rep.tInt Rep.emptySubst) (Rep.TVar (Rep.var 0 Rep.KType Rep.FNone)) == Rep.tInt)
    , check "zonkRow splices a bound row tail"
        (Rep.zonkRow
            (Rep.extend (Rep.var 1 Rep.KRow Rep.FNone)
                (Rep.TRecord { fields = [ ( "x", Rep.tInt ) ], tail = Rep.REmpty })
                Rep.emptySubst
            )
            { fields = [ ( "y", Rep.tBool ) ], tail = Rep.RVar (Rep.var 1 Rep.KRow Rep.FNone) }
            == { fields = [ ( "y", Rep.tBool ), ( "x", Rep.tInt ) ], tail = Rep.REmpty }
        )
    , check "occurs finds a variable through a function"
        (Rep.occurs (Rep.var 0 Rep.KType Rep.FNone) (Rep.TFun (Rep.TVar (Rep.var 0 Rep.KType Rep.FNone)) Rep.tInt))
    , check "occurs absent"
        (not (Rep.occurs (Rep.var 0 Rep.KType Rep.FNone) Rep.tInt))
    , check "occurs finds a row variable through a tail"
        (Rep.occurs (Rep.var 1 Rep.KRow Rep.FNone) (Rep.TRecord { fields = [], tail = Rep.RVar (Rep.var 1 Rep.KRow Rep.FNone) }))

    -- Type.Error: source ranges flow into the rendered message.
    , check "type error renders row:col"
        (Error.render
            (Error.atRange
                { start = { row = 3, column = 7 }, end = { row = 3, column = 9 } }
                "missing field x"
                "cannot unify Int with Bool"
            )
            == "type error at 3:7: missing field x\ncannot unify Int with Bool"
        )
    , check "type error renders without detail"
        (Error.render (Error.atRange { start = { row = 1, column = 1 }, end = { row = 1, column = 2 } } "bad type" "") == "type error at 1:1: bad type")

    -- Type.Unify: paper examples. {x:Int,y:Int} ~ {y:Int,x:Int} unify up to
    -- swap (empty substitution); duplicate-label rows are order-sensitive.
    , check "unify swaps distinct adjacent labels"
        (case
            Uni.unify Uni.emptyState
                (Rep.TRecord { fields = [ ( "x", Rep.tInt ), ( "y", Rep.tInt ) ], tail = Rep.REmpty })
                (Rep.TRecord { fields = [ ( "y", Rep.tInt ), ( "x", Rep.tInt ) ], tail = Rep.REmpty })
         of
            Ok { subst } ->
                subst == Rep.emptySubst

            Err _ ->
                False
        )
    , check "duplicate labels are order-sensitive (scoped)"
        (case
            Uni.unify Uni.emptyState
                (Rep.TRecord { fields = [ ( "x", Rep.tInt ), ( "x", Rep.tBool ) ], tail = Rep.REmpty })
                (Rep.TRecord { fields = [ ( "x", Rep.tBool ), ( "x", Rep.tInt ) ], tail = Rep.REmpty })
         of
            Ok _ ->
                False

            Err _ ->
                True
        )
    , check "row-var instantiation freshens kinded vars"
        (let
            alpha =
                Rep.var 0 Rep.KRow Rep.FNone

            beta =
                Rep.var 1 Rep.KRow Rep.FNone

            left =
                Rep.TRecord { fields = [ ( "x", Rep.tInt ) ], tail = Rep.RVar alpha }

            right =
                Rep.TRecord { fields = [ ( "y", Rep.tInt ) ], tail = Rep.RVar beta }

            state0 =
                { subst = Rep.emptySubst, fresh = 100 }
         in
         case Uni.unify state0 left right of
            Err _ ->
                False

            Ok state ->
                case Rep.lookup beta state.subst of
                    Just (Rep.TRecord bound) ->
                        case Rep.zonkRow state.subst bound of
                            { fields, tail } ->
                                (fields == [ ( "x", Rep.tInt ) ])
                                    && (case tail of
                                            Rep.RVar b ->
                                                b.kind == Rep.KRow && b.id /= alpha.id && b.id /= beta.id

                                            _ ->
                                                False
                                       )

                    _ ->
                        False
        )
    , check "common-tail rows do not loop (alpha /= tail guard)"
        (let
            alpha =
                Rep.var 0 Rep.KRow Rep.FNone

            left =
                Rep.TRecord { fields = [ ( "x", Rep.tInt ) ], tail = Rep.RVar alpha }

            right =
                Rep.TRecord { fields = [ ( "y", Rep.tInt ) ], tail = Rep.RVar alpha }
         in
         case Uni.unify Uni.emptyState left right of
            Ok _ ->
                False

            Err _ ->
                True
        )
    , check "number + comparable merge to number"
        (let
            n =
                Rep.var 0 Rep.KType Rep.FNumber

            c =
                Rep.var 1 Rep.KType Rep.FComparable
         in
         case Uni.unify Uni.emptyState (Rep.TVar n) (Rep.TVar c) of
            Ok state ->
                Rep.zonk state.subst (Rep.TVar c) == Rep.TVar n

            Err _ ->
                False
        )
    , check "number + appendable cross is an error"
        (let
            n =
                Rep.var 0 Rep.KType Rep.FNumber

            a =
                Rep.var 1 Rep.KType Rep.FAppendable
         in
         case Uni.unify Uni.emptyState (Rep.TVar n) (Rep.TVar a) of
            Ok _ ->
                False

            Err _ ->
                True
        )
    , check "number cannot bind to Bool"
        (let
            n =
                Rep.var 0 Rep.KType Rep.FNumber
         in
         case Uni.unify Uni.emptyState (Rep.TVar n) Rep.tBool of
            Ok _ ->
                False

            Err _ ->
                True
        )
    , check "number binds to Int"
        (let
            n =
                Rep.var 0 Rep.KType Rep.FNumber
         in
         case Uni.unify Uni.emptyState (Rep.TVar n) Rep.tInt of
            Ok state ->
                Rep.zonk state.subst (Rep.TVar n) == Rep.tInt

            Err _ ->
                False
        )
    , check "comparable propagates through List"
        (let
            c =
                Rep.var 0 Rep.KType Rep.FComparable

            a =
                Rep.var 1 Rep.KType Rep.FNone
         in
         case Uni.unify { subst = Rep.emptySubst, fresh = 100 } (Rep.TVar c) (Rep.tList (Rep.TVar a)) of
            Ok state ->
                case Rep.zonk state.subst (Rep.TVar a) of
                    Rep.TVar za ->
                        za.flex == Rep.FComparable

                    _ ->
                        False

            Err _ ->
                False
        )
    , check "occurs check rejects infinite type"
        (let
            a =
                Rep.var 0 Rep.KType Rep.FNone
         in
         case Uni.unify Uni.emptyState (Rep.TVar a) (Rep.TFun (Rep.TVar a) Rep.tInt) of
            Ok _ ->
                False

            Err _ ->
                True
        )
    , check "unify missing field reports the label"
        (case
            Uni.unify Uni.emptyState
                (Rep.TRecord { fields = [ ( "x", Rep.tInt ) ], tail = Rep.REmpty })
                (Rep.TRecord { fields = [], tail = Rep.REmpty })
         of
            Err (Uni.MissingField "x") ->
                True

            _ ->
                False
        )

    -- Type.Env: instantiation, generalization (incl. flex markers), and
    -- collection from a parsed File.
    , check "env instantiate freshens ids and keeps comparable marker"
        (let
            c =
                Rep.var 0 Rep.KType Rep.FComparable

            scheme =
                { quantifiers = [ c ], body = Rep.TFun (Rep.TVar c) (Rep.TVar c) }

            ( t, state ) =
                Env.instantiate scheme { subst = Rep.emptySubst, fresh = 100 }
         in
         case t of
            Rep.TFun (Rep.TVar v1) (Rep.TVar v2) ->
                (v1.id == 100)
                    && (v2.id == 100)
                    && (v1.flex == Rep.FComparable)
                    && (state.fresh == 101)

            _ ->
                False
        )
    , check "env generalize keeps comparable in the scheme (Dict.get-style)"
        (let
            c =
                Rep.var 0 Rep.KType Rep.FComparable

            v =
                Rep.var 1 Rep.KType Rep.FNone

            dictGet =
                Rep.TFun (Rep.TVar c)
                    (Rep.TFun (Rep.TCon "Dict.Dict" [ Rep.TVar c, Rep.TVar v ])
                        (Rep.TCon "Prelude.Maybe" [ Rep.TVar v ])
                    )

            scheme =
                Env.generalize dictGet
         in
         (List.length scheme.quantifiers == 2)
            && List.any (\q -> q.id == 0 && q.flex == Rep.FComparable) scheme.quantifiers
            && List.any (\q -> q.id == 1 && q.flex == Rep.FNone) scheme.quantifiers
        )
    , check "env let-generalization avoids rigid vars"
        (let
            x =
                Rep.var 0 Rep.KType Rep.FNone

            y =
                Rep.var 1 Rep.KType Rep.FNone

            scheme =
                Env.generalizeAvoiding [ x ] (Rep.TFun (Rep.TVar x) (Rep.TVar y))
         in
         List.map .id scheme.quantifiers == [ 1 ]
        )
    , check "env freeVars includes flex-marked vars"
        (Env.freeVars (Rep.TVar (Rep.var 0 Rep.KType Rep.FComparable)) == [ Rep.var 0 Rep.KType Rep.FComparable ])
    , check "env collects ctor and signature schemes"
        (case
            Elm.Parser.parseToFile
                "module Mini exposing (..)\n\ntype Wrap a = Wrap a\n\nid : a -> a\nid x =\n    x\n"
         of
            Ok file ->
                let
                    env =
                        Env.collectFile file
                in
                (case Env.lookupCtor "Mini.Wrap" env of
                    Just s ->
                        Rep.pretty s.body == "a -> Mini.Wrap a"

                    Nothing ->
                        False
                )
                    && (case Env.lookupValue "Mini.id" env of
                            Just s ->
                                Rep.pretty s.body == "a -> a"

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )

    -- Type.Builtins: operator schemes, prim-wrapper alias-row schemes, and
    -- the Record.remove / trusted-bodies surface.
    , check "builtin (+) is number -> number -> number"
        (case Builtins.operatorScheme "+" of
            Just s ->
                Rep.pretty s.body == "number -> number -> number"

            Nothing ->
                False
        )
    , check "builtin (//) is Int -> Int -> Int"
        (case Builtins.operatorScheme "//" of
            Just s ->
                Rep.pretty s.body == "Int -> Int -> Int"

            Nothing ->
                False
        )
    , check "builtin (/) is Float -> Float -> Float"
        (case Builtins.operatorScheme "/" of
            Just s ->
                Rep.pretty s.body == "Float -> Float -> Float"

            Nothing ->
                False
        )
    , check "builtin (<) is comparable -> comparable -> Bool"
        (case Builtins.operatorScheme "<" of
            Just s ->
                Rep.pretty s.body == "comparable -> comparable -> Bool"

            Nothing ->
                False
        )
    , check "builtin (++) is appendable -> appendable -> appendable"
        (case Builtins.operatorScheme "++" of
            Just s ->
                Rep.pretty s.body == "appendable -> appendable -> appendable"

            Nothing ->
                False
        )
    , check "builtin (::) is a -> List a -> List a"
        (case Builtins.operatorScheme "::" of
            Just s ->
                Rep.pretty s.body == "a -> List a -> List a"

            Nothing ->
                False
        )
    , check "builtin String.append is String -> String -> String"
        (case Builtins.lookupValue "String.append" of
            Just s ->
                Rep.pretty s.body == "String -> String -> String"

            Nothing ->
                False
        )
    , check "builtin Bitwise.and is Int -> Int -> Int"
        (case Builtins.lookupValue "Bitwise.and" of
            Just s ->
                Rep.pretty s.body == "Int -> Int -> Int"

            Nothing ->
                False
        )
    , check "builtin vectorGet is JsArray a -> Int -> a"
        (case Builtins.lookupValue "vectorGet" of
            Just s ->
                Rep.pretty s.body == "JsArray a -> Int -> a"

            Nothing ->
                False
        )
    , check "builtin intern is String -> String"
        (case Builtins.lookupValue "intern" of
            Just s ->
                Rep.pretty s.body == "String -> String"

            Nothing ->
                False
        )
    , check "builtin writeByte is Int -> Stream -> Int"
        (case Builtins.lookupValue "writeByte" of
            Just s ->
                Rep.pretty s.body == "Int -> Stream -> Int"

            Nothing ->
                False
        )
    , check "builtin strPrim is String -> String"
        (case Builtins.lookupValue "strPrim" of
            Just s ->
                Rep.pretty s.body == "String -> String"

            Nothing ->
                False
        )
    , check "builtin removeFieldImpl is String -> a -> b"
        (case Builtins.lookupValue "Prelude.removeFieldImpl" of
            Just s ->
                Rep.pretty s.body == "String -> a -> b"

            Nothing ->
                False
        )
    , check "Record.remove surface name"
        (Builtins.recordRemove == "Record.remove")
    , check "Record.remove rewrites to removeFieldImpl"
        (Builtins.recordRemoveImpl == "Prelude.removeFieldImpl")
    , check "removeFieldImpl is a trusted body"
        (Builtins.isTrusted "Prelude.removeFieldImpl")
    , check "map is not a trusted body"
        (not (Builtins.isTrusted "Prelude.map"))
    , check "every prim-wrapper alias row has a builtin scheme"
        (Builtins.uncoveredPrimRows == [])
    , check "34 prim-wrapper schemes registered"
        (Dict.size Builtins.primWrapperSchemes == 34)

    -- Type.Infer: Algorithm W over expressions/patterns, record operations,
    -- let-generalization, top-level group, and the ++/Record.remove rewrites.
    , check "infer ++ zonks to String.append"
        (case inferSrc "module Main exposing (..)\n\nf x =\n    x ++ \"!\"\n" of
            Ok unit ->
                (prettyScheme "Main.f" unit == "String -> String")
                    && (case bodyOf "f" unit.file of
                            Just e ->
                                isAppendCall "String.append" e

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "infer ++ zonks to List.append"
        (case inferSrc "module Main exposing (..)\n\ng x =\n    x ++ [1]\n" of
            Ok unit ->
                (prettyScheme "Main.g" unit == "List number -> List number")
                    && (case bodyOf "g" unit.file of
                            Just e ->
                                isAppendCall "List.append" e

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "infer ambiguous (++) errors"
        (case inferSrc "module Main exposing (..)\n\nh x =\n    x ++ x\n" of
            Err err ->
                String.contains "ambiguous" err.summary

            Ok _ ->
                False
        )
    , check "infer arity error (applying a non-function)"
        (case inferSrc "module Main exposing (..)\n\nmain =\n    5 3\n" of
            Err _ ->
                True

            Ok _ ->
                False
        )
    , check "import shadowing rejected (bare exposing row vs local def)"
        (case Elm.Parser.parseToFile "module A exposing (main)\nimport B exposing (update)\n\nupdate = 1\n\nmain = 0\n" of
            Ok file ->
                Resolve.checkImportShadowing [ "update", "main" ] file.imports
                    == Err "the name `update` is both a top-level definition and imported via `exposing` from B; remove it from the import's exposing list (real Elm rejects this)"

            Err _ ->
                False
        )
    , check "import shadowing allows clean explicit imports"
        (case Elm.Parser.parseToFile "module A exposing (main)\nimport B exposing (update)\n\nhelper = 2\n\nmain = 0\n" of
            Ok file ->
                Resolve.checkImportShadowing [ "helper", "main" ] file.imports == Ok ()

            Err _ ->
                False
        )
    , check "infer let-generalizes (id used at Bool and String)"
        (case inferSrc "module Main exposing (..)\n\nmain =\n    let\n        id x =\n            x\n    in\n    ( id True, id \"a\" )\n" of
            Ok unit ->
                prettyScheme "Main.main" unit == "(Bool, String)"

            Err _ ->
                False
        )
    , check "infer top-level group is order-independent"
        (case inferSrc "module Main exposing (..)\n\nf =\n    g 1\n\ng x =\n    x\n" of
            Ok unit ->
                (prettyScheme "Main.f" unit == "number")
                    && (prettyScheme "Main.g" unit == "a -> a")

            Err _ ->
                False
        )
    , check "infer record ops: duplicate-label shadow + remove"
        (case inferSrc "module Main exposing (..)\n\na =\n    { x = 1, x = True }\n\nb =\n    a.x\n\nc =\n    Record.remove \"x\" a\n\nd =\n    c.x\n" of
            Ok unit ->
                (prettyScheme "Main.a" unit == "{x:number, x:Bool}")
                    && (prettyScheme "Main.b" unit == "number")
                    && (prettyScheme "Main.c" unit == "{x:Bool}")
                    && (prettyScheme "Main.d" unit == "Bool")
                    && (case bodyOf "c" unit.file of
                            Just e ->
                                isRemoveCall e

                            Nothing ->
                                False
                       )

            Err _ ->
                False
        )
    , check "infer insertion is free extension (may duplicate)"
        (case inferSrc "module Main exposing (..)\n\nins r =\n    { r | x <- 1 }\n" of
            Ok unit ->
                (prettyScheme "Main.ins" unit == "{| a} -> {x:number| a}")
                    && (case bodyOf "ins" unit.file of
                            Just (Expression.RecordUpdateExpression _ setters) ->
                                case setters of
                                    Node _ ( _, Node _ (Expression.Integer 1) ) :: [] ->
                                        True

                                    _ ->
                                        False

                            _ ->
                                False
                       )

            Err _ ->
                False
        )
    , check "infer update of a missing field errors"
        (case inferSrc "module Main exposing (..)\n\nf : { y : Int } -> { y : Int }\nf p =\n    { p | x = 1 }\n" of
            Err err ->
                String.contains "does not have field x" err.summary

            Ok _ ->
                False
        )
    , check "infer update keeps an existing field"
        (case inferSrc "module Main exposing (..)\n\nf : { x : Int } -> { x : Int }\nf p =\n    { p | x = 2 }\n" of
            Ok unit ->
                prettyScheme "Main.f" unit == "{x:Int} -> {x:Int}"

            Err _ ->
                False
        )
    , check "infer apply non-function diagnostic"
        (case inferSrc "module Main exposing (..)\n\nanswer : Int -> Int\nanswer x =\n    x + 1\n\nmain =\n    answer 1 2\n" of
            Err err ->
                String.contains "apply non-function" err.summary

            Ok _ ->
                False
        )
    , check "env expands a row-generic type alias (Named {age:Int})"
        (case Elm.Parser.parseToFile "module Mini exposing (..)\n\ntype alias Named r = { name : String | r }\n" of
            Ok file ->
                let
                    env =
                        Env.collectFile file

                    applied =
                        Rep.TCon "Mini.Named" [ Rep.TRecord { fields = [ ( "age", Rep.tInt ) ], tail = Rep.REmpty } ]
                in
                case Env.expandAliases env applied Uni.emptyState of
                    Ok ( expanded, _ ) ->
                        Rep.pretty expanded == "{name:String, age:Int}"

                    Err _ ->
                        False

            Err _ ->
                False
        )
    , check "env expands a type-generic type alias (Box Int)"
        (case Elm.Parser.parseToFile "module Mini exposing (..)\n\ntype alias Box a = { value : a }\n" of
            Ok file ->
                let
                    env =
                        Env.collectFile file

                    applied =
                        Rep.TCon "Mini.Box" [ Rep.tInt ]
                in
                case Env.expandAliases env applied Uni.emptyState of
                    Ok ( expanded, _ ) ->
                        Rep.pretty expanded == "{value:Int}"

                    Err _ ->
                        False

            Err _ ->
                False
        )
    , check "env expands a zero-generic alias applied to zero args"
        (case Elm.Parser.parseToFile "module Mini exposing (..)\n\ntype alias Point = { x : Int, y : Int }\n" of
            Ok file ->
                let
                    env =
                        Env.collectFile file
                in
                case Env.expandAliases env (Rep.TCon "Mini.Point" []) Uni.emptyState of
                    Ok ( expanded, _ ) ->
                        Rep.pretty expanded == "{x:Int, y:Int}"

                    Err _ ->
                        False

            Err _ ->
                False
        )
    , check "env alias arity error on too many arguments"
        (case Elm.Parser.parseToFile "module Mini exposing (..)\n\ntype alias Box a = { value : a }\n" of
            Ok file ->
                let
                    env =
                        Env.collectFile file

                    applied =
                        Rep.TCon "Mini.Box" [ Rep.tInt, Rep.tBool ]
                in
                case Env.expandAliases env applied Uni.emptyState of
                    Err msg ->
                        String.contains "expects 1 type argument but got 2" msg

                    Ok _ ->
                        False

            Err _ ->
                False
        )
    , check "infer rejects an unsaturated type-alias application"
        (case inferSrc "module Main exposing (..)\n\ntype alias Named r = { name : String | r }\n\nf : Named -> String\nf p =\n    p.name\n" of
            Err err ->
                String.contains "type alias Main.Named expects 1 type argument but got 0" err.summary

            Ok _ ->
                False
        )
    , check "alias sentinels never leak across call sites (two concrete rows)"
        (case inferSrc "module Main exposing (..)\n\ntype alias Named r = { name : String | r }\n\ngetName : Named r -> String\ngetName p =\n    p.name\n\na =\n    getName { name = \"a\", age = 1 }\n\nb =\n    getName { name = \"b\", foo = \"c\" }\n" of
            Ok unit ->
                (prettyScheme "Main.a" unit == "String")
                    && (prettyScheme "Main.b" unit == "String")

            Err err ->
                False
        )
    , check "Record.remove as a value gives a clear diagnostic"
        (case inferSrc "module Main exposing (..)\n\nf =\n    Record.remove \"x\"\n" of
            Err err ->
                String.contains "Record.remove must be fully applied" err.summary

            Ok _ ->
                False
        )
    ]


check : String -> Bool -> String
check name ok =
    if ok then
        "PASS " ++ name

    else
        "FAIL " ++ name


-- ======================= Type.Infer helpers =======================

inferSrc : String -> Result Error.TypeError Infer.CheckedUnit
inferSrc src =
    case Elm.Parser.parseToFile src of
        Ok file ->
            Infer.inferUnit (Env.collectFile file) file

        Err _ ->
            Err (Error.atRange Range.empty "parse failed" "")


schemeFor : String -> Infer.CheckedUnit -> Maybe Env.Scheme
schemeFor qname unit =
    case List.filter (\( n, _ ) -> n == qname) unit.schemes of
        ( _, s ) :: _ ->
            Just s

        [] ->
            Nothing


prettyScheme : String -> Infer.CheckedUnit -> String
prettyScheme qname unit =
    case schemeFor qname unit of
        Just s ->
            Rep.pretty s.body

        Nothing ->
            "<missing>"


bodyOf : String -> File.File -> Maybe Expression.Expression
bodyOf name file =
    List.filterMap
        (\nd ->
            case Node.value nd of
                Declaration.FunctionDeclaration fn ->
                    case Node.value fn.declaration of
                        impl ->
                            if Node.value impl.name == name then
                                Just (Node.value impl.expression)

                            else
                                Nothing

                _ ->
                    Nothing
        )
        file.declarations
        |> List.head


isAppendCall : String -> Expression.Expression -> Bool
isAppendCall fnName expr =
    case expr of
        Expression.Application nodes ->
            case nodes of
                Node _ (Expression.FunctionOrValue [] n) :: _ ->
                    n == fnName

                _ ->
                    False

        _ ->
            False


isRemoveCall : Expression.Expression -> Bool
isRemoveCall expr =
    case expr of
        Expression.Application nodes ->
            case nodes of
                Node _ (Expression.FunctionOrValue [ "Prelude" ] "removeFieldImpl") :: _ ->
                    True

                _ ->
                    False

        _ ->
            False


-- A small program with a forward jmpf/jmp, exercising the two-pass resolve:
--
--   pc 0  m            (pushmark)
--   pc 1  g foo        (global foo)
--   pc 2  f Lf         (jmpf forward)
--   pc 3  n 0          (number 0)
--   pc 4  j Le         (jmp forward)
--   pc 5  n 1          (number 1)   <- Lf:  label here (pc 5)
--   pc 6  p            (apply)      <- Le:  label here (pc 6)
--   pc 7  v            (return)

forwardProgram : List Emit.Instr
forwardProgram =
    [ Emit.Pushmark
    , Emit.Global "foo"
    , Emit.Jmpf (Emit.TRef "Lf")
    , Emit.Number_ 0
    , Emit.Jmp (Emit.TRef "Le")
    , Emit.Label_ "Lf"
    , Emit.Number_ 1
    , Emit.Label_ "Le"
    , Emit.Apply
    , Emit.Return
    ]


forwardFlattened : String
forwardFlattened =
    "(m g [3:s]foo f [1:n]5 n [1:n]0 j [1:n]6 n [1:n]1 p v)"


forwardLabelResolved : Bool
forwardLabelResolved =
    -- resolve replaces TRef with TAbs but does NOT drop Label_ markers
    -- (flatten drops them). So the resolved list still contains both labels.
    case Emit.resolve forwardProgram of
        [ Emit.Pushmark, Emit.Global _, Emit.Jmpf (Emit.TAbs 5), Emit.Number_ 0, Emit.Jmp (Emit.TAbs 6), Emit.Label_ "Lf", Emit.Number_ 1, Emit.Label_ "Le", Emit.Apply, Emit.Return ] ->
            True

        _ ->
            False


-- A Cur body resolved independently of the enclosing program.

curProgram : List Emit.Instr
curProgram =
    [ Emit.Cur
        [ Emit.Jmpf (Emit.TRef "L")
        , Emit.Label_ "L"
        , Emit.Return
        ]
    ]


curFlattened : String
curFlattened =
    "(c (f [1:n]1 v))"
