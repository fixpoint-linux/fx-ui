module Lower.Scope exposing
    ( Scope
    , empty
    , push
    , pop
    , resolve
    )

-- A de Bruijn scope stack for local-name resolution.
--
-- `push` puts a binder on the innermost position; `resolve name` returns the
-- de Bruijn index of `name` = the distance from the innermost binder, where the
-- innermost binder is index 0.  This is exactly the convention the ZINC VM uses:
-- `access N` loads env[env_len - 1 - N] (see interp.zig lookupEnv), so a local
-- parameter is addressed by how many binders sit between it and the current
-- one.
--
--   push "x" (push "y" empty)
--   resolve "x" == Just 0     -- innermost
--   resolve "y" == Just 1     -- one level out
--   resolve "z" == Nothing


type Scope
    = Scope (List String)


empty : Scope
empty =
    Scope []


push : String -> Scope -> Scope
push name (Scope names) =
    Scope (name :: names)


pop : Scope -> Scope
pop (Scope names) =
    case names of
        [] ->
            Scope []

        _ :: rest ->
            Scope rest


resolve : String -> Scope -> Maybe Int
resolve name (Scope names) =
    indexOf name names


indexOf : String -> List String -> Maybe Int
indexOf target names =
    case names of
        [] ->
            Nothing

        head :: rest ->
            if head == target then
                Just 0

            else
                Maybe.map ((+) 1) (indexOf target rest)
