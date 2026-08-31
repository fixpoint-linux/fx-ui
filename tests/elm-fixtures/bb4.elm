module Bb4 exposing (main)

-- P1 VM benchmark: one full ListBox.view render (12 items, 40x19, cursor at
-- index 3 crossing the page boundary).  Matches listdemo's `mk` shape; driven
-- by tools/vmbench to measure per-render instruction count + ns/instr.

import ListBox


items : List ListBox.Item
items =
  [ { title = "Item 00", description = "west" }
  , { title = "Item 01", description = "north" }
  , { title = "Item 02", description = "test" }
  , { title = "Item 03", description = "south" }
  , { title = "Item 04", description = "rest" }
  , { title = "Item 05", description = "apple" }
  , { title = "Item 06", description = "best" }
  , { title = "Item 07", description = "kiwi" }
  , { title = "Item 08", description = "chest" }
  , { title = "Item 09", description = "lemon" }
  , { title = "Item 10", description = "guest" }
  , { title = "Item 11", description = "grape" }
  ]


main : String
main =
  String.join "\n" (ListBox.view (ListBox.select 3 (ListBox.new items 40 19)))
