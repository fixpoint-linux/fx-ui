port module TestMain exposing (main)

-- M1a unit-test harness for the emitter infrastructure.  NOT part of the
-- compiler (Main.elm stays the M0 parse driver).  Built separately with:
--
--   ELM_HOME=.elm-cache elm make src/TestMain.elm --output=test-compiler.js
--   node test-run.js
--
-- Every assertion prints a "PASS <name>" or "FAIL <name>" line over the
-- `report` port; test-run.js exits nonzero if any FAIL appears.

import Platform
import Zinc.Csexp as Csexp
import Zinc.Emit as Emit
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
    ]


check : String -> Bool -> String
check name ok =
    if ok then
        "PASS " ++ name

    else
        "FAIL " ++ name


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
