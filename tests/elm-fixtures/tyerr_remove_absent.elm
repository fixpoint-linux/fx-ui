module TyerrRemoveAbsent exposing (main)

-- Record.remove on a field that is not in the record must be rejected
-- (scoped labels forbid removing an unknown/tail-only field).

main =
    Record.remove "z" { x = 1 }
