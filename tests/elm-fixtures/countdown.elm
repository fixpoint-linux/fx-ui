module Countdown exposing (countdown)

countdown n =
    if n == 0 then
        0
    else
        countdown (n - 1)
