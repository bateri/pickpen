# Changelog

Every change a user of pickpen would notice, newest first. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/): while pickpen is `0.x`, a minor release may
change what the previous one did.

## [Unreleased]

### Added

- Rows from stdin or a file, as lines, CSV, TSV, JSON lines, a JSON document, or a table lined up
  with spaces (`ps aux`, `docker ps`, `kubectl get`, `df -h`), its shape read from the first lines
  or given with `--input`, shown as they arrive.
- A query that typing goes to: words, `!word`, and columns compared by their headings, with
  sizes, lengths of time, dates and numbers compared as such (`cpu>50`, `age<2h`, `size>1G`,
  `ms=100..400`); each term shown as it was read, and the ones the mouse wrote taken out with a
  click.
- Marking with the keyboard (`Tab`, `⇧↑` `⇧↓`, `⌘A`) and the mouse (the boxes, a drag down them,
  ⌘- and ⇧-click), ordering by any column, a palette of every command (`⌘K`) and the keys on one
  page (`?`).
- A side panel: the row under the cursor, or what `--preview` prints for it; a column's values by
  how often they come and a chart of its quantities, which a click or a drag turns into a term of
  the query; and what will go out, exactly, with the command line that does it again.
- `--where` with nobody to ask, writing the rows it matches as they come; `--confirm` to have a
  person look at the rows it marks before they go; `--sort`, `--field`, `--format`, `--output` and
  `--title`.
- Exit statuses that say what happened: 0 rows went out, 1 none did, 2 a person was needed and
  there was no terminal to ask in.

### Changed

- pickpen is one native file, made from Lua by pencere's runner, with its page inside it (about
  4 MB): macOS on Apple silicon and Linux on `arm64` and `x86_64`, as files of the GitHub release.
  Node is no longer needed where it runs, and pickpen is not published on npm. The earlier
  Node program (a React page, speaking MCP Apps to the terminal) is gone; the page is now drawn by
  the terminal itself, in its font and colours, and a terminal that hosts the older views no
  longer shows it.
- The program holds the rows, the query's list and the marks, and the page asks for the few rows in
  sight; a list of 200,000 rows opens, filters and orders in a fraction of a second more than it
  takes to read. Reading stops at 200,000 rows, as before, and says so.
- The query is typed in the terminal's own text field. The field gives ⏎, ↓, ⇥ and Esc back to the
  page, so the first press of one only leaves it for the rows, and `/` returns to it. The page
  cannot change the field's text, so Esc takes out the terms the mouse wrote, and no longer clears
  what was typed. The terms a click or a drag writes are shown beside what was typed, each with an
  ✕, and are part of the `--where` the output panel shows.
- Backspace, `F1`–`F12` and `⌃` with a letter do not reach a page: help is `?` (it was `F1`), the
  side panel is `⌘I` and `⇧⌘I` (it was `F2`–`F4`), the palette's filter is deleted with `←`, and
  `⌃P` `⌃N` are gone.
- The columns that go out are picked in the output panel, and a heading's menu sends only that one.
- Case-insensitive matching folds ASCII, Latin, Greek, Cyrillic and Armenian letters.
- A date and time without a zone (`2026-10-22 10:00`) is read as UTC; one with a zone, and a date
  alone, are exact. A day a month does not have (`2026-02-30`) is not a moment.
- The columns of a JSON object are in the order its keys came in, including keys that are numbers
  (they were put first, in order, by the earlier program); a lone surrogate in a JSON string becomes
  U+FFFD.
- A preview that prints more than 256 KiB is ended, and the page says it was cut.
- The command line `--input` and `--output` the output panel shows are quoted for the shell.
