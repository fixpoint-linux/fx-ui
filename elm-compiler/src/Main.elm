port module Main exposing (main)

-- M0 bootstrap: prove the stil4m/elm-syntax 7.3.9 API end-to-end against a real
-- build.  Receives Elm source via flags, parses it with Elm.Parser.parseToFile,
-- and emits a one-line result over the `emit` port:
--   "ok <declCount> <firstDeclName>"   on successful parse
--   "err <deadEndCount>"               on parse failure
-- run.js wires flags -> compiler.js and the emit port -> a .csexp output file.

import Elm.Parser
import Elm.Syntax.Declaration as Declaration exposing (Declaration(..))
import Elm.Syntax.Node exposing (Node(..))
import Platform

port emit : String -> Cmd msg


type alias Flags =
    { source : String }


type Msg
    = Noop


main : Program Flags () Msg
main =
    Platform.worker
        { init = init
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


init : Flags -> ( (), Cmd Msg )
init flags =
    ( (), emit (compile flags.source) )


compile : String -> String
compile source =
    case Elm.Parser.parseToFile source of
        Ok file ->
            let
                count =
                    List.length file.declarations

                firstName =
                    firstDeclName file.declarations
            in
            "ok " ++ String.fromInt count ++ " " ++ firstName

        Err deadends ->
            "err " ++ String.fromInt (List.length deadends)


firstDeclName : List (Node Declaration.Declaration) -> String
firstDeclName decls =
    case decls of
        [] ->
            ""

        first :: _ ->
            case first of
                Node _ (FunctionDeclaration fn) ->
                    case fn.declaration of
                        Node _ impl ->
                            case impl.name of
                                Node _ name ->
                                    name

                Node _ _ ->
                    ""
