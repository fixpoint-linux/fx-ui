module Lg1 exposing (main)

-- P1 VM benchmark: one Lipgloss.render of a styled multi-line box (the
-- representative "8-line box" render from docs/vm-perf-plan.md).  Driven by
-- tools/vmbench to measure per-render instruction count + ns/instr.

import Lipgloss


main : String
main =
  Lipgloss.render
    (Lipgloss.border Lipgloss.roundedBorder
      (Lipgloss.paddingLeft 1
        (Lipgloss.paddingRight 1
          (Lipgloss.bold True Lipgloss.newStyle)
        )
      )
    )
    "line 1\nline 2\nline 3\nline 4\nline 5\nline 6"
