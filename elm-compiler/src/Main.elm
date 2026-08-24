port module Main exposing (main)

-- M1b: orchestrate the Elm -> ZINC-csexp compiler pipeline.
--
-- Receives Elm source via flags, parses it to a File with Elm.Parser.parseToFile,
-- lowers it to a ZINC bundle (Lower.Module.compile), resolves jumps + flattens
-- (Zinc.Emit), and emits over the `emit` port:
--   the bundle csexp TEXT on success
--   "err <message>"                on parse or compile failure
-- run.js wires flags -> compiler.js and the emit port -> a .csexp output file.

import Elm.Parser
import Lower.Module as Module
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
            case Module.compile file of
                Ok bundleText ->
                    bundleText

                Err msg ->
                    "err " ++ msg

        Err _ ->
            "err parse failed"
