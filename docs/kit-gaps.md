# What pickpen asked of a page, and the terminal and kit did not give

pickpen's page is a page of pencere's kit (Lua), drawn by bateri. These are the places where what
the person had before (the React page of the Node program) could not be had again, with what the
page does instead. Each is a thing the kit or the terminal could give; none is a bug of pickpen.

| gap | what pickpen does instead |
| --- | --- |
| A page cannot write the text of the terminal's field, or clear it | the query is the field's text plus terms the mouse wrote, shown beside it as chips with a Remove; Esc takes out the chips and not the typed text |
| The field keeps ⏎ ↓ ⇥ Esc and tells the page nothing; the page cannot ask where the keyboard is | the page takes the first key it is given for the keyboard having come to it, and draws no focus it cannot know; `/` hands the keyboard back |
| One text field a page (the first element that says it is one) | the palette's filter is typed as keys (a character is a key event) and deleted with ← |
| No Backspace/Delete, no `F1`–`F12`, no `⌃` with a letter in the keys a page is given | help is `?`, the side panel `⌘I`, ordering `⌃1`–`⌃9`; every command is also in the palette |
| An event carries no time, and a page's clock is its last frame's | a double-click, a toast's end and the Esc that asks twice are timers the next frame stamps and a frame at their end fires |
| No way to measure a text | columns are sized by a character of the terminal's face taken as 0.6 of the text size, and a cell is cut at its column's edge |
| No horizontal scroll, only `scroll_y` | columns shrink to fit the pane, and a column's edge can be dragged |
| A page is one script: there is no `require`, and a bundle's other files are not code | `src/view/page.lua` is one file, in numbered sections of local functions and tables that can be split mechanically when a join of files exists |
| A page cannot hold hundreds of thousands of rows (64 MiB, 250 ms a call) | the program holds the rows, filters in slices and orders them; the page asks for the 30 to 100 rows in sight (`window`) and keeps at most 2,500 |
| A program that is a filter had no way to read stdin as it arrives, to know whether a stream is a terminal, to show its view on the controlling terminal, or to end its view and then write | added to the runner: `io.read_stdin`, `io.is_terminal`, `serve{ filter = true }`, `close_view()`, and `session = true` for a command that must not reach the pane (see the pencere branch `wt/pickpen`) |
| `Terminal::controlling()` did not work on macOS (`poll` answers `POLLNVAL` for `/dev/tty`) | fixed in pencere's program library on the same branch |
