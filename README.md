# pickpen

Choose rows in the middle of a pipeline, in a real interface in the terminal pane: the rows
come in on stdin, you filter, sort and mark them with the keyboard or the mouse, and the rows
you chose go out on stdout, to whatever comes next. In the colours and font of your terminal,
on your machine or on a server over plain `ssh`.

```sh
kubectl get pods | pickpen --where 'STATUS!=Running' --confirm --field NAME | xargs kubectl delete pod
```

pickpen is a [pencere](https://github.com/bateri/pencere) program, written in Lua and made one
native file by pencere's runner. In a terminal that hosts pencere views
([bateri](https://github.com/bateri/bateri)) the pane becomes the interface for as long as you
choose, the way `vim` takes the screen and gives it back. The pipeline's data never touches the
terminal: pickpen talks to the terminal on the terminal itself, and keeps stdin and stdout for the
rows.

## What it does

**It reads what commands print.** Lines, CSV and TSV, JSON lines, a JSON document (an array, or
the one array of objects an answer holds, as `kubectl get -o json` and most APIs give), and the
tables commands line up with spaces — `ps aux`, `docker ps`, `kubectl get`, `df -h` — cut into
their columns as they line them up, `Up 2 hours` and `/usr/bin/foo --bar` staying one cell
each. The shape is read from the first lines; `--input` says it when it would be read wrong.
Rows show as they arrive, so `tail -f app.log | pickpen` works, and a list of hundreds of thousands
of rows stays responsive: the program holds the rows and the page shows the few in sight.

**Typing filters.** What you type goes to the query. Words are looked for in every column; a column
can be compared by its heading, and quantities are compared as quantities:

| you type                  | the rows kept                                            |
| ------------------------- | -------------------------------------------------------- |
| `web !canary`             | hold `web`, in any column, in any case, and not `canary` |
| `STATUS=Running\|Pending` | whose `STATUS` is one of them (`!=` for none of them)    |
| `NAME~api` `NAME!~api`    | whose `NAME` holds `api`, or does not                    |
| `cpu>50` `size>=1G`       | `%CPU` above 50, a size of a gigabyte or more            |
| `age<2h` `ms=100..400`    | younger than two hours, between 100 and 400 ms           |
| `started>2026-10-01`      | dates and times compare as moments                       |

A column is named as its heading is, or by its letters alone (`cpu` for `%CPU`). Under the query,
each term says how it was read — `STATUS is not Running`, `has web` — and a name that is no
column's is looked for as a word, and the page says so.

**The mouse writes the query too.** Right-click a cell for _only rows where STATUS is
CrashLoopBackOff_; click a value in a column's panel, ⌘-click another to leave its rows out; drag
across the chart of a column's numbers to keep a range. Each of these is a term beside what you
typed, shown with a Remove that takes it out, and part of the command line the output panel shows.

**What goes out is shown before it goes.** The output panel has the exact bytes Send will write,
drawn by the program with the same function that writes them. By default a row goes out as it
came in — a line as its line, a table's row without the heading (so `xargs` gets only rows), CSV
after its heading, JSON lines as lines, a JSON document as an array of the elements chosen.
`--field NAME,PID` writes columns tab-separated (`--field 1` is the first word of a line, as in
awk), `--format 'kill {PID}'` fills a template, `--output json` converts. Right-click a heading
to send only that column, or pick the columns in the output panel.

**And how to do it again, with nobody to ask.** The same panel shows the command line that
chooses the same rows in a script or in cron — the query as `--where`, the order as `--sort`, the
columns as `--field` — and says whether it does: it does when the rows marked are exactly the
rows the query matches. Rows marked one by one have no query that names them, and the panel says
that too.

**A rule marks, a person confirms.** With `--where` alone nobody is asked: the rows the query
matches go out, as grep would, one by one as they come. Add `--confirm` and the view opens with
those rows marked; you look, unmark what should stay, and send. Without a terminal that shows
views, anything that needs a person ends with status 2 and sends nothing: pickpen never confirms
for you.

**A preview of the row the cursor is on.** `--preview 'git show --color {1}'` runs on the machine
pickpen runs on, with `{}`, `{COLUMN}` and `{2}` quoted for the shell, in a session of its own
with no terminal and no stdin, and shows what it prints, colours and all.

## The keyboard, and the mouse

The page has the keyboard in two places. It starts in the terminal's own text field: **what you type
is the query**. ⏎, ↓, ⇥ and Esc leave the field for the rows (the field keeps them, so the first
press of one only leaves), and `/` takes you back to it. Everything the keys do the mouse does too,
the bottom line has the keys that matter most (each one a button), and `?` lists them all.

|                   |                                                                                   |
| ----------------- | --------------------------------------------------------------------------------- |
| `↑` `↓`           | move; `PgUp` `PgDn` a page, `⌘↑` `⌘↓` the first and the last row                  |
| `⇥` `⇧⇥` `Space`  | mark the row and go on (the next, the previous)                                   |
| `⇧↑` `⇧↓`         | mark a run of rows                                                                |
| `⌘A`, `⇧⌘A`       | mark every row shown, unmark every row                                            |
| `⏎`               | send: the marked rows, or the row under the cursor                                |
| `Esc`             | back: close what is open, then the terms the mouse wrote, then send nothing       |
| `⌃1`–`⌃9`, `⌃0`   | order by that column (again for the other way), the input's order                 |
| `⌘K`              | every command, a column's own among them                                          |
| `⌘I`, `⇧⌘I`       | the side panel: show or hide it, and its next page (the row, a column, what goes out) |
| `⌘C`              | copy the row                                                                      |
| `/`, `?`          | take the keyboard back to the query, list the keys                                |
| `⌃C`              | quit, sending nothing                                                             |

Esc asks twice when rows are marked. The box in front of a row marks it, and a drag down the boxes
marks every row it passes; ⌘-click marks one row and ⇧-click a run; a double-click sends the row
when nothing is marked (never with `--confirm`); a click on a heading orders by it, and its edge
resizes it.

What the terminal keeps for itself never reaches a view — in bateri `⌘P`, `⌘W`, `⌘O`, `⌘T`,
`⌘N`, `⌘D` and `⌘1`–`⌘9` — and no command is on `⌥` and a letter, which is how a Mac types
`@`, `#`, `[` or `{` on many layouts. On Linux and Windows, `⌘` is `Ctrl`.

What a terminal's page cannot do yet, and what pickpen does instead:

- the page cannot write the terminal's text field, so **Esc does not clear what you typed** (it
  takes out the terms the mouse wrote); to clear the query press `/`, then `⌘A` and delete;
- the keys Backspace, `F1`–`F12` and `⌃` with a letter (`⌃P` `⌃N`) do not reach a page, so the
  help is `?`, the panel is `⌘I`, and the palette's filter is deleted with `←`;

## Run it

pickpen is one file with no dependencies: take the one for your machine from the
[releases](https://github.com/bateri/pickpen/releases) (macOS on Apple silicon, and Linux on `arm64`
and `x86_64`), check it against `SHA256SUMS`, make it executable and put it on your `PATH`.

To choose in a view you need a terminal that hosts pencere views. bateri is the first, and no
release of it has them yet: until one does, build bateri from its `main` branch. `--where`
without `--confirm` needs no terminal at all.

```sh
ps aux | pickpen --field PID | xargs kill
git log --oneline | pickpen --preview 'git show --color {1}' --field 1 | xargs git cherry-pick
pickpen --where 'level=error' --output json < app.jsonl > errors.json
```

| status | means                                                                    |
| ------ | ------------------------------------------------------------------------ |
| 0      | rows went out                                                            |
| 1      | none did: nothing was chosen, Send nothing, or `--where` matched nothing |
| 2      | a person was needed and there was no terminal that shows pencere views   |
| 64, 65 | the command line was wrong; the input could not be read as its shape     |
| 130    | ⌃C                                                                       |

**Nothing chosen, nothing sent.** Every command of a pipeline starts at once, and the one after
pickpen sees its input end whether rows came or not: `xargs -r` runs nothing on no input, but
`mail` sends an empty mail. A step that must not run without a choice waits for it:

```sh
pods=$(kubectl get pods | pickpen --confirm --where 'STATUS!=Running' --field NAME) \
  && printf '%s\n' "$pods" | xargs kubectl delete pod
```

**Over ssh.** Install it on the server and run it there, in a pane of a terminal that hosts
pencere: nothing listens on a port, the interface travels in the terminal's own stream, and it
runs on your machine in a sandbox that reaches nothing but its program. Its page crosses the
stream once (about 60 kB); after that the terminal keeps it.

pickpen is never an MCP server on stdio: its stdin and stdout are the pipeline's, and it does not
guess whether it is in one (pencere §13).

## How it works

[`src/program/README.md`](src/program/README.md) has the program's modules and the calls its page
makes. In short:

- `src/program/input/` reads the input as it comes, telling its shape from the first lines, and
  keeps each record's own text, which is what goes out when the output has the input's shape.
- `src/program/query/` is the query, the order and what a column holds; the page filters with it
  and `--where` runs it, so the command line the page shows chooses what the page showed. A test
  runs `--where` and a page sending the rows the query matches, in a pane, and compares the bytes.
- `src/program/output/` writes what goes out; the page's picture of it is drawn by the same function.
- `src/program/state/` is the table and the list a person looks at; `src/program/api/` is the one
  place that knows the page: its calls, and the topic it listens to.
- `src/program/app.lua` is the command line, and the one place that knows about the terminal:
  `serve{ filter = true }` shows the page on the terminal itself while stdin and stdout carry the
  rows, and `close_view` ends it once the person has answered.
- `src/view/page.lua` is the interface: a page of pencere's kit, in the terminal's own colours and
  font. It draws only the rows in sight and asks the program for more as it scrolls.

## Work on it

```sh
git clone https://github.com/bateri/pickpen && cd pickpen
make check          # format, the Lua tests (the modules and the page), the program built, and the
                    # built file in a pipeline under pencere-fake-host
```

`make check` needs a [pencere](https://github.com/bateri/pencere) checkout beside this one (or
`PENCERE=`, `FAKE_HOST=` and `PENCERE_KIT=` naming what it builds there): `cargo build --release -p
pencere-cli` and `cargo build -p pencere-fake-host`. There is no Node anywhere in it.

How a version is released is in [RELEASING.md](RELEASING.md), and what each one changed in
[CHANGELOG.md](CHANGELOG.md). `demo/` has made-up pods, processes, an access log, servers and
commits to try it on: `pickpen demo/pods.txt`.

## License

pickpen is free software: you can redistribute it and/or modify it under the terms of the
[GNU General Public License](LICENSE) as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version. It is distributed in the hope
that it will be useful, but WITHOUT ANY WARRANTY; see the license for details.
