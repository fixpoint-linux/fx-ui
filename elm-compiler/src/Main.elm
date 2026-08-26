port module Main exposing (main)

-- M1b -> M3: orchestrate the Elm -> ZINC-csexp compiler pipeline.
--
-- Receives ALL Elm sources via flags ({sourcesJson}) — a JSON array of module
-- source strings — and lowers the whole list through
-- Lower.Module.compileSources, emitting over the `emit` port:
--   the bundle csexp TEXT on success
--   "err <message>"                on parse or compile failure
-- run.js wires flags -> compiler.js and the emit port -> a .csexp output
-- file; it appends src/Prelude.elm's source as the LAST compilation unit so
-- every user module gets the prelude (plan §6/§8 M3).

import Json.Decode as JD
import Lower.Module as Module
import Platform


port emit : String -> Cmd msg


type alias Flags =
    { sourcesJson : String }


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
    ( (), emit (compileAll flags.sourcesJson) )


compileAll : String -> String
compileAll sourcesJson =
    case JD.decodeString (JD.list JD.string) sourcesJson of
        Ok sources ->
            case Module.compileSources sources of
                Ok bundleText ->
                    bundleText

                Err msg ->
                    "err " ++ msg

        Err _ ->
            "err internal: bad flags"
