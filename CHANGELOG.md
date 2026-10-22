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
- A query that typing always goes to: words, `!word`, and columns compared by their headings, with
  sizes, lengths of time, dates and numbers compared as such (`cpu>50`, `age<2h`, `size>1G`,
  `ms=100..400`); each term shown as it was read, and taken out with a click.
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
