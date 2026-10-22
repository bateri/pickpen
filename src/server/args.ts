/** The command line: what to read, what to do with it, and how what goes out is shaped. */

import { parseArgs } from "node:util";

import { FORMATS } from "./input.ts";
import type { Format } from "./input.ts";
import type { Shape } from "./output.ts";

export const USAGE = `usage: pickpen [options] [FILE]

Choose rows in the middle of a pipeline: they come in on stdin (or from FILE),
you choose in the terminal pane, and the rows you chose go out on stdout.

  ps aux | pickpen --field PID | xargs kill
  kubectl get pods | pickpen --where 'STATUS!=Running' --confirm --field NAME

  -q, --query QUERY      start with QUERY typed
  -w, --where QUERY      no view: write the rows QUERY matches, as grep would
  -c, --confirm          a person confirms: the rows --where matches are marked,
                         and only marked rows go out
  -s, --sort [-]COLUMN   in COLUMN's order (with -, the other way)
  -f, --field COLUMN,…   write these columns of each row, tab-separated
      --format TEMPLATE  write each row as TEMPLATE: {COLUMN}, {2}, {} the row
  -o, --output FORMAT    write csv, tsv, json or jsonl
  -i, --input FORMAT     read lines, csv, tsv, columns, jsonl or json
                         (without it, the shape is read from the first lines)
  -p, --preview COMMAND  show what COMMAND prints for the row the cursor is on;
                         {} {COLUMN} {2} stand for the row and its cells
  -t, --title TEXT       a line above the rows, saying what they are for
  -h, --help             this text
  -v, --version          the version

The query: words the row must hold, !word for one it must not, and
COLUMN=v, !=, ~ (holds), !~, >, >=, <, <=, and a..b, with quantities read
as such: cpu>50, size>1G, age<2h. The same query does the same in the view
and with --where.

Exit status: 0 rows went out, 1 none did, 2 a person was needed and there
was no terminal that shows pencere views, 64 the command line was wrong,
65 the input could not be read, 130 ⌃C.`;

export interface Options {
  file?: string;
  query: string;
  where?: string;
  confirm: boolean;
  sort?: { column: string; descending: boolean };
  shape: Shape;
  input?: Format;
  preview?: string;
  title?: string;
  /** The output flags as given, for the command line the view shows. */
  given: { input?: string; field?: string[]; format?: string; output?: string };
}

export class UsageError extends Error {
  override name = "UsageError";
}

export type Parsed = { kind: "help" } | { kind: "version" } | { kind: "run"; options: Options };

/** `--sort -cpu` as `--sort=-cpu`: the minus is the order's, not an option's. */
function joinSort(argv: readonly string[]): string[] {
  const out: string[] = [];
  for (let at = 0; at < argv.length; at++) {
    const arg = argv[at]!;
    const next = argv[at + 1];
    if ((arg === "--sort" || arg === "-s") && next !== undefined && next.startsWith("-")) {
      out.push(`--sort=${next}`);
      at += 1;
    } else out.push(arg);
  }
  return out;
}

export function parse(argv: readonly string[]): Parsed {
  let parsed;
  try {
    parsed = parseArgs({
      args: joinSort(argv),
      allowPositionals: true,
      options: {
        query: { type: "string", short: "q" },
        where: { type: "string", short: "w" },
        confirm: { type: "boolean", short: "c" },
        sort: { type: "string", short: "s" },
        field: { type: "string", short: "f", multiple: true },
        format: { type: "string" },
        output: { type: "string", short: "o" },
        input: { type: "string", short: "i" },
        preview: { type: "string", short: "p" },
        title: { type: "string", short: "t" },
        help: { type: "boolean", short: "h" },
        version: { type: "boolean", short: "v" },
      },
    });
  } catch (error) {
    throw new UsageError((error as Error).message);
  }
  const { values, positionals } = parsed;
  if (values.help) return { kind: "help" };
  if (values.version) return { kind: "version" };
  if (positionals.length > 1) throw new UsageError("give one FILE at most");

  const fields = (values.field ?? []).flatMap((f) => f.split(",")).map((f) => f.trim());
  if (fields.some((f) => f === "")) throw new UsageError("--field names a column with no name");
  const shapes = [fields.length > 0, values.format !== undefined, values.output !== undefined];
  if (shapes.filter(Boolean).length > 1) {
    throw new UsageError("give one of --field, --format and --output");
  }
  let shape: Shape = { kind: "input" };
  if (fields.length > 0) shape = { kind: "fields", names: fields };
  else if (values.format !== undefined) shape = { kind: "template", template: values.format };
  else if (values.output !== undefined) {
    const format = values.output;
    if (format !== "csv" && format !== "tsv" && format !== "json" && format !== "jsonl") {
      throw new UsageError(`--output is csv, tsv, json or jsonl, not ${JSON.stringify(format)}`);
    }
    shape = { kind: "as", format };
  }

  let input: Format | undefined;
  if (values.input !== undefined) {
    if (!(FORMATS as readonly string[]).includes(values.input)) {
      throw new UsageError(`--input is one of ${FORMATS.join(", ")}`);
    }
    input = values.input as Format;
  }

  let sort: Options["sort"];
  if (values.sort !== undefined) {
    const descending = values.sort.startsWith("-");
    const column = descending ? values.sort.slice(1) : values.sort;
    if (column === "") throw new UsageError("--sort names no column");
    sort = { column, descending };
  }

  const file = positionals[0];
  return {
    kind: "run",
    options: {
      ...(file !== undefined && file !== "-" ? { file } : {}),
      query: values.query ?? "",
      ...(values.where !== undefined ? { where: values.where } : {}),
      confirm: values.confirm ?? false,
      ...(sort ? { sort } : {}),
      shape,
      ...(input ? { input } : {}),
      ...(values.preview !== undefined ? { preview: values.preview } : {}),
      ...(values.title !== undefined ? { title: values.title } : {}),
      given: {
        ...(values.input !== undefined ? { input: values.input } : {}),
        ...(fields.length > 0 ? { field: fields } : {}),
        ...(values.format !== undefined ? { format: values.format } : {}),
        ...(values.output !== undefined ? { output: values.output } : {}),
      },
    },
  };
}
