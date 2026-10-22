#!/usr/bin/env node
/**
 * pickpen: rows come in on stdin (or from a file), a person chooses in the terminal pane,
 * and the rows chosen go out on stdout, for what comes next in the pipeline.
 *
 *   ps aux | pickpen --field PID | xargs kill
 *
 * stdin and stdout are the pipeline's, so the view is asked for on the terminal itself
 * (`filter`), always: pickpen is never an MCP client's stdio server, and it never guesses
 * whether it is in a pipeline. With `--where` and no `--confirm` nobody is asked: the rows the
 * query matches go out, the same in a terminal and in cron.
 */

import { ViewControl, bundleFromDirectory, serve } from "@pencere/sdk";
import { createReadStream, openSync } from "node:fs";
import type { Readable } from "node:stream";

import {
  columnNamed,
  compareOrdered,
  matches,
  parse as parseQuery,
  rowOf,
  sortKey,
  unknownNames,
} from "../shared/query.ts";
import type { Query } from "../shared/query.ts";
import { USAGE, UsageError, parse } from "./args.ts";
import type { Options } from "./args.ts";
import { Reader } from "./input.ts";
import type { InputRecord, Sink } from "./input.ts";
import { head, one, problemOf, render, streams } from "./output.ts";
import type { Shape, Source } from "./output.ts";
import { Picker } from "./picker.ts";
import { VERSION, VIEW_DIRECTORY, createServer } from "./tools.ts";

/** How long a slow input may take before its shape is read from the lines it has sent. */
const DECIDE_AFTER_MS = 150;

function say(message: string): void {
  process.stderr.write(`pickpen: ${message}\n`);
}

function quit(code: number, message: string): never {
  say(message);
  process.exit(code);
}

/** Writes to stdout, and ends quietly, as a SIGPIPE would, when what reads it has gone. */
class Out {
  #gone = false;

  constructor() {
    process.stdout.on("error", (error: NodeJS.ErrnoException) => {
      if (error.code === "EPIPE") {
        this.#gone = true;
        process.exit(141);
      }
      quit(74, `cannot write: ${error.message}`);
    });
  }

  /** Resolves once the text is handed on, so that a full pipe slows the reading down. */
  write(text: string): Promise<void> {
    if (text === "" || this.#gone) return Promise.resolve();
    return new Promise((resolve) => {
      if (process.stdout.write(text)) resolve();
      else process.stdout.once("drain", resolve);
    });
  }

  /** Writes the last of it, and ends the program once it has gone. */
  end(text: string, code: number): void {
    if (text === "") process.exit(code);
    process.stdout.write(text, () => process.exit(code));
  }
}

/**
 * Feeds the input to the reader as it comes. `after` runs once each piece is read, and may
 * hold the reading up; reading stops when `stop` says so.
 */
async function pump(
  stream: Readable,
  reader: Reader,
  stop: () => boolean,
  after?: () => Promise<void>,
): Promise<void> {
  stream.setEncoding("utf8");
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    for await (const chunk of stream) {
      reader.feed(chunk as string);
      if (timer === undefined && reader.format === undefined && reader.hasLine) {
        timer = setTimeout(() => reader.decide(), DECIDE_AFTER_MS);
      }
      if (after) await after();
      if (stop()) break;
    }
  } finally {
    clearTimeout(timer);
  }
  reader.end();
}

function inputOf(options: Options): Readable {
  if (options.file === undefined) {
    // A person who typed `pickpen` alone would wait on a read nobody feeds.
    if (process.stdin.isTTY) throw new UsageError("give rows on stdin or name a FILE");
    return process.stdin;
  }
  // Opened now, so that a file that cannot be read is said before any view opens.
  try {
    return createReadStream("", { fd: openSync(options.file, "r") });
  } catch (error) {
    quit(66, `cannot read ${options.file}: ${(error as Error).message}`);
  }
}

/** `--where` with nobody to ask: the rows the query matches go out, one by one when they can. */
async function headless(options: Options, stream: Readable, out: Out): Promise<never> {
  const where = options.where!;
  let query: Query | undefined;
  let names: string[] = [];
  let heading: string | undefined;
  const held: InputRecord[] = [];
  let count = 0;
  let headed = false;
  let pending: Promise<void> = Promise.resolve();
  const source: Source = {
    get format() {
      return reader.format;
    },
    get names() {
      return names;
    },
    get heading() {
      return heading;
    },
  };
  const oneByOne = () => options.sort === undefined && streams(options.shape, reader.format);
  const sink: Sink = {
    columns(next, text) {
      if (names.length === 0) {
        for (const name of unknownNames(where, next)) {
          say(
            `there is no column named ${JSON.stringify(name)}: that term is looked for as a word`,
          );
        }
      }
      names = next;
      if (text !== undefined) heading = text;
      query = parseQuery(where, names);
      const problem = problemOf(options.shape, names);
      if (problem) quit(64, problem);
      if (options.sort && columnNamed(names, options.sort.column) < 0) {
        quit(64, `there is no column named ${JSON.stringify(options.sort.column)} to sort by`);
      }
    },
    record(record) {
      query ??= parseQuery(where, names);
      if (!matches(query, rowOf(record.cells))) return;
      count += 1;
      if (!oneByOne()) {
        held.push(record);
        return;
      }
      if (!headed) {
        headed = true;
        pending = pending.then(() => out.write(head(options.shape, source)));
      }
      pending = pending.then(() => out.write(one(record, options.shape, source)));
    },
    problem(text) {
      say(text[0]!.toLowerCase() + text.slice(1));
    },
  };
  const reader = new Reader(sink, options.input);
  const reading = pump(
    stream,
    reader,
    () => false,
    () => pending,
  );
  try {
    await reading;
  } catch (error) {
    quit(66, `cannot read ${options.file ?? "stdin"}: ${(error as Error).message}`);
  }
  await pending;
  if (reader.format === "json" && names.length === 0) quit(65, "the input could not be read");
  let rest = "";
  if (!oneByOne()) {
    if (options.sort) {
      const column = columnNamed(names, options.sort.column);
      const { descending } = options.sort;
      // Array.sort keeps ties in the input's order, as the view does.
      const keyed = held.map((record) => ({ record, key: sortKey(record.cells[column] ?? "") }));
      keyed.sort((a, b) => compareOrdered(a.key, b.key, descending));
      held.splice(0, held.length, ...keyed.map((k) => k.record));
    }
    rest = render(held, options.shape, source);
  }
  out.end(rest, count > 0 ? 0 : 1);
  return new Promise<never>(() => {});
}

/** A person chooses in the pane. */
async function choose(options: Options, stream: Readable, out: Out): Promise<never> {
  const picker = new Picker();
  const reader = new Reader(
    {
      columns(names, heading) {
        picker.format = reader.format;
        picker.columns(names, heading);
      },
      record: (record) => picker.record(record),
      problem: (text) => picker.problem(text),
    },
    options.input,
  );
  void pump(stream, reader, () => picker.capped)
    .catch((error: Error) => picker.problem(`The input could not be read: ${error.message}`))
    .finally(() => {
      picker.format = reader.format;
      picker.finish();
    });

  const control = new ViewControl();
  const abort = new AbortController();
  let chosen: { rows: number[]; shape: Shape } | undefined;
  let cancelled = false;
  // After the answer has gone back to the view: the program closes its view and goes on
  // to write. A terminal that cannot close it for the program has the wait ended instead.
  const close = () =>
    setImmediate(() => {
      void control.close().then((closed) => {
        if (closed.kind === "unsupported") abort.abort();
      });
    });
  const server = createServer(picker, options, {
    chosen(rows, shape) {
      chosen = { rows, shape };
      close();
    },
    cancelled() {
      cancelled = true;
      close();
    },
  });

  let noView = false;
  const result = await serve(server, {
    tool: "show_picker",
    bundle: await bundleFromDirectory(VIEW_DIRECTORY),
    filter: true,
    control,
    signal: abort.signal,
    fallback: () => {
      noView = true;
    },
  });
  stream.destroy();

  if (chosen !== undefined) {
    out.end(
      render(
        chosen.rows.map((at) => picker.rows[at]!),
        chosen.shape,
        picker,
      ),
      0,
    );
    return new Promise<never>(() => {});
  }
  if (noView) {
    quit(
      2,
      "choosing rows needs a terminal that shows pencere views; --where QUERY alone runs without one",
    );
  }
  if (cancelled) quit(1, "nothing was chosen");
  if (result.kind === "closed" && result.by === "signal") process.exit(130);
  if (result.kind === "no-view" && result.reason === "aborted") process.exit(130);
  quit(1, "nothing was chosen");
}

let parsed;
try {
  parsed = parse(process.argv.slice(2));
} catch (error) {
  if (error instanceof UsageError)
    quit(64, `${error.message} (pickpen --help says how it is used)`);
  throw error;
}
if (parsed.kind === "help") {
  process.stdout.write(`${USAGE}\n`);
  process.exit(0);
}
if (parsed.kind === "version") {
  process.stdout.write(`pickpen ${VERSION}\n`);
  process.exit(0);
}

const options = parsed.options;
let stream: Readable;
try {
  stream = inputOf(options);
} catch (error) {
  quit(64, `${(error as Error).message} (pickpen --help says how it is used)`);
}
const out = new Out();
if (options.where !== undefined && !options.confirm) await headless(options, stream, out);
else await choose(options, stream, out);
