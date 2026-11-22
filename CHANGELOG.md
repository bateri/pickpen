# Changelog

Every change a user of pickpen would notice, newest first. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[semantic versioning](https://semver.org/): while pickpen is `0.x`, a minor release may
change what the previous one did.

## [Unreleased]

### Fixed

- A screen reader, and an agent that reads the pane, are told what the view showed only by colour or
  by a drawn mark: the row the cursor is on, whether a row is marked and whether every row shown is,
  which way the ordered column goes, which tab of the side panel is open, which value of a column is
  kept, and the command the palette is on. The panel's edge and its chart, which had no name, have one.
  The command palette and the sheet of keys are read as dialogs, with the rows behind them left out of
  what is read, and the dimmed part around them is not read (it was an unnamed button). The box over
  the rows is "mixed" while some rows are marked, and the lines that resize a column and the panel are
  sliders with a name. A pencere too old for this shows a screen that says to update bateri, instead of
  a page that does not run.

## [0.2.0] - 2026-11-09

### Added

- **Releases carry a signed `app.json`.** A terminal that follows pickpen (bateri, from its list of
  apps) reads it to find the newest file it can open and to know the file is the one the maintainer
  released. `make sums` writes it and its signature beside `SHA256SUMS`, and the release checks
  refuse a release without them.

### Changed

- Building from source now needs Rust 1.99 or later.

## [0.1.0] - 2026-11-03

### Added

- Rows from stdin or a file, as lines, CSV, TSV, JSON lines, a JSON document, or a table lined up
  with spaces (`ps aux`, `docker ps`, `kubectl get`, `df -h`), its shape read from the first lines
  or given with `--input`, shown as they arrive.
- `--delimiter` to cut lines into columns numbered from `1` at a text, the last taking the rest of
  the line (`grep -n`), `--read0` for rows that end at NUL (`find -print0`), and `--print0` to end
  each row written with NUL (`xargs -0`).
- A query that typing always goes to: words, `!word`, `^word` and `word$` for a cell's start and
  end, `a | b` for either, and columns compared by their headings, with sizes, lengths of time,
  dates and numbers compared as such (`cpu>50`, `age<2h`, `size>1G`, `ms=100..400`); each term
  shown as it was read, and taken out with a click.
- `--expect` keys that send too, the key written ahead of the rows; `{q}` (the query) and `{+}`
  (the marked rows) in `--preview`.
- `--reload` to read the rows from a command, again on `⌃R`, and `--execute` to run a command for
  the row or the marked rows on `⌃X`, with no terminal, the view staying.
- `--fuzzy` (and its command in the palette): a plain word is its letters in order, gaps allowed,
  and the rows go best match first unless ordered by a column; quoted words stay as typed.
- Marking with the keyboard (`Tab`, `⇧↑` `⇧↓`, `⌘A`) and the mouse (the boxes, a drag down them,
  ⌘- and ⇧-click), ordering by any column, a palette of every command (`⌘K`) and the keys on one
  page (`F1`).
- A side panel: the row under the cursor, or what `--preview` prints for it; a column's values by
  how often they come and a chart of its quantities, which a click or a drag turns into a term of
  the query; and what will go out, exactly, with the command line that does it again.
- `--where` with nobody to ask, writing the rows it matches as they come; `--confirm` to have a
  person look at the rows it marks before they go; `--sort`, `--field`, `--format`, `--output` and
  `--title`.
- Exit statuses that say what happened: 0 rows went out, 1 none did, 2 a person was needed and
  there was no terminal to ask in.
- One native file for macOS on Apple silicon and Linux on arm64 and x86_64, installed with
  `install.sh` and checked against the release's sums. The program holds the rows and the view asks
  for the ones in sight, so up to a million rows filter, sort and scroll at once, over ssh too: a
  query looks through them on every core, and each order is sorted once, not again at each key.
