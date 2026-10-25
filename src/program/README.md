# pickpen's program

The program of pickpen, in Lua, for the runner of the `pencere` command. `make build` packs
`src/program/` (this directory), `src/view/` (the page, `page.lua`) and `src/assets/` (the icons
a terminal draws beside the program's name) into the runner as one file, `dist/pickpen`. Nothing
generated is under `src/`.

The rule of the directories is one sentence: **`api/` knows the page; `input/`, `query/`,
`output/` and `state/` do not.** They take and return plain Lua values and never build a message:
a call, a subscription, a push, a `code`. What the page is told is made in `api/` from what they
hold.

| file                       | what it is                                                                                  |
| -------------------------- | ------------------------------------------------------------------------------------------- |
| `app.lua`                  | the entry: the command line, the two ways the program goes, the way out (writing the rows)  |
| `api/list.lua`             | the calls `open`, `query`, `order`, `window`, `row`, `mark`                                 |
| `api/panels.lua`           | the calls `column`, `term`, `output`, `preview`                                             |
| `api/answer.lua`           | the calls `choose` and `cancel`: each ends the view after its answer has gone               |
| `api/feed.lua`             | the topic `rows`: the summary, said again when it changes, a few times a second at most     |
| `api/summary.lua`          | what the page is told of the table and the list in one piece, and how each term was read    |
| `api/again.lua`            | the command line that chooses the marked rows again, and whether it does                    |
| `api/call.lua`             | how a call is answered: its params checked, what the work raises told with a code           |
| `api/params.lua`           | each call says what it asks: what does not fit is answered `bad-params` and never run       |
| `input/reader.lua`         | the sample the shape is told from, then the parser of that shape                            |
| `input/detect.lua`         | the shape of an input from its first lines                                                  |
| `input/{lines,delimited,columns,jsonl,document}.lua` | one module for each shape                                         |
| `input/json.lua`           | JSON with its keys in order, and numbers written as JavaScript writes them                  |
| `query/parse.lua`          | the terms of a query, a column named by its heading or its letters                          |
| `query/match.lua`          | a query as a function of a row, worked out once for a loop over many                        |
| `query/order.lua`          | the order of a column: quantities before words, empty last, stable, fast for 200,000 rows   |
| `query/values.lua`         | what a cell says as a quantity: a number, a size, a length of time, a moment                |
| `query/stats.lua`          | what the column panel shows: the kind, the values by how often, a chart of the quantities   |
| `query/fold.lua`           | upper and lower case for ASCII, Latin, Greek, Cyrillic and Armenian                         |
| `output/render.lua`        | the rows as they go out in each shape; the page's picture of them is the same function      |
| `output/preview.lua`       | `--preview`: the command, quoted, run in a session of its own with a time and a size limit  |
| `output/command_line.lua`  | the command line that chooses the same rows in a script                                     |
| `state/table.lua`          | the rows read so far, the columns, whether the input ended                                  |
| `state/view.lua`           | the query's list, its order, the marks, the rule; filtering in slices                       |
| `state/session.lua`        | what the command line asked for, the reader, and the answer                                 |
| `version.lua`              | the version (a built program has no manifest beside it; `make release-prepare` writes it)   |

## The page's calls

A position is a 1-based place in the list the page is showing, and `gen` says which list: it moves
whenever the same place would name another row. A call that names a `gen` other than the program's is
answered `stale` (the page asks for the list again); one that names none is made in the list as it
is.

| call      | params                                   | answer                                                              |
| --------- | ---------------------------------------- | ------------------------------------------------------------------- |
| `open`    | `wait`                                   | the command line's options, a `summary`; waits for the input to end |
| `query`   | `typed`, `chips`                         | the `summary` of the list that keeps the rows                       |
| `order`   | `column`, `descending`                   | the `summary`                                                       |
| `window`  | `gen`, `from`, `count`                   | the rows at those places, each with whether it is marked            |
| `row`     | `gen`, `pos`                             | one row whole                                                       |
| `mark`    | `gen`, `op`, `from`, `to`, `on`          | how many are marked, and how many of them the query hides          |
| `column`  | `gen`, `column`                          | the column's kind, values and chart, each with the term it writes   |
| `term`    | `column`, `value`, `negate`              | the term that keeps the rows with (or without) a value              |
| `output`  | `gen`, `cursor`, `fields`                | what Send would write, the command line again, whether it does      |
| `preview` | `gen`, `pos`, `width`                    | what the `--preview` command printed, its status, whether it was cut |
| `choose`  | `gen`, `cursor`, `fields`                | `chosen`; the view is closed after the answer, and the rows written |
| `cancel`  |                                          | `ok`; the view is closed and nothing is written                     |

The topic `rows` says the `summary` as it changes.

## Size

`dist/pickpen` is 4.2 MB (4,184,306 bytes) on macOS arm64: the runner, with the program and the page
in it. Of 200,000 rows of `ps`, the program reads and lists them in 0.8 s, the page draws a frame
of 641 elements, and a query or an order is 0.2 to 0.4 s.

## Its tests

`test/lua/cases/` are the tests of the modules and of the page: they run in a test app made of the
program's modules, the page and the tests, by the runner itself (`make test-lua`). The page runs there
on the kit's own page API, with the calls of `api/` answered from a real table in the same process
(`test/lua/page_host.lua`). `test/lua/binary/` runs the built file (`make test-binary`): as cron
would run it, and in a pipeline in a pane under `pencere-fake-host`, with a scripted page that makes
the calls the real page makes and the bytes that come out on stdout read back.

## Details that are not what a person would guess

- **A piece of the input** is read by the loop like the pipe of a process (`io.read_stdin`), so the
  page is answered while the rows come; a filter of a big table is done in slices of 20,000 rows,
  between which the program answers its other calls, and a newer query takes over from an older one.
- **The shape** is read from the first 50 lines or 64 KiB, or 150 ms after the first whole line when
  the input is slow.
- **The words** of a row and the keys of a column are counted in characters (code points), not
  bytes: a table with accents in it is cut where it lines up.
- **Writing** stops quietly when what reads stdout has gone (`head`), with the status a shell gives
  a SIGPIPE.
