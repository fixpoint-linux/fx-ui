port module Main exposing (main)

-- M1b -> M3 -> batch: orchestrate the Elm -> ZINC-csexp compiler pipeline.
--
-- Receives ALL sources via flags:
--   {corpusSourcesJson} — a JSON array of the FIXED corpus module sources
--     (Prelude + Runtime + the seven core-libs), parsed+typechecked+lowered
--     ONCE per process.
--   {groupsJson}        — a JSON array of JSON arrays: one source list per
--     fixture group (1-2 user modules each).
--
-- Lower.Module.compileBatch turns that into ONE bundle text per group (the
-- corpus bundle entries reused across groups); the corpus is paid for once, so
-- compiling all N fixtures in this single process costs ~1 corpus pass instead
-- of N.  Emits over the `emit` port a single JSON ARRAY of per-group strings
-- (the bundle text, or "err <msg>" for that group alone); run.js writes each
-- element to its group's output .csexp.

import Json.Decode as JD
import Json.Encode as JE
import Lower.Module as Module
import Platform


port emit : String -> Cmd msg


type alias Flags =
    { corpusSourcesJson : String
    , groupsJson : String
    }


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
    ( (), emit (compileAll flags.corpusSourcesJson flags.groupsJson) )


compileAll : String -> String -> String
compileAll corpusSourcesJson groupsJson =
    case
        ( JD.decodeString (JD.list JD.string) corpusSourcesJson
        , JD.decodeString (JD.list (JD.list JD.string)) groupsJson
        )
    of
        ( Ok corpusSources, Ok groups ) ->
            case Module.compileBatch corpusSources groups of
                Ok bundles ->
                    encodeStrings bundles

                Err msg ->
                    -- Corpus-level failure: every group reports the same err.
                    encodeStrings (List.map (\_ -> "err " ++ msg) groups)

        _ ->
            encodeStrings [ "err internal: bad flags" ]


encodeStrings : List String -> String
encodeStrings strings =
    JE.encode 0 (JE.list JE.string strings)
