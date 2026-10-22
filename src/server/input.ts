/**
 * Reading the pipeline's input as rows: what shape it has (unless `--input` says), and
 * each record as it comes, so that a view opened on `tail -f` shows lines while they arrive.
 *
 * The shape is read from the first lines, never the mode: whether pickpen is in a pipeline is
 * not a question this file asks. A record keeps the text it was read from (`raw`), which is
 * what goes out when the output has the input's shape.
 */

import type { Format } from "../shared/wire.ts";

export type { Format };

export const FORMATS: readonly Format[] = ["lines", "csv", "tsv", "columns", "jsonl", "json"];

export interface InputRecord {
  /** One per column, as text; a record may have fewer than there are columns. */
  cells: string[];
  /** The text it was read from, without its line ending and colour codes. */
  raw: string;
  /** For JSON input, the value itself. */
  value?: unknown;
}

export interface Sink {
  /**
   * The columns, the first time and whenever JSON brings a key not seen before; for CSV and
   * TSV with the heading's own text, which goes out ahead of the rows.
   */
  columns(names: string[], heading?: string): void;
  record(record: InputRecord): void;
  /** Something in the input that could not be read as its shape; reading goes on. */
  problem(text: string): void;
}

/** Colour and other terminal codes: dropped, from what is shown and from what goes out. */
const ESCAPES = /\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]/g;

export function plain(text: string): string {
  return text.includes("\x1b") ? text.replace(ESCAPES, "") : text;
}

/** How many lines, or bytes, the shape is read from before records flow. */
const SAMPLE_LINES = 50;
const SAMPLE_BYTES = 64 * 1024;

export class Reader {
  #format: Format | undefined;
  #buffer = "";
  #decided = false;
  #ended = false;
  #parser: Parser | undefined;
  readonly sink: Sink;

  constructor(sink: Sink, format?: Format) {
    this.sink = sink;
    this.#format = format;
  }

  get format(): Format | undefined {
    return this.#decided ? this.#format : undefined;
  }

  /** Text as it comes. */
  feed(text: string): void {
    if (this.#parser) {
      this.#parser.feed(text);
      return;
    }
    this.#buffer += text;
    if (this.#format !== undefined) {
      this.decide();
      return;
    }
    if (this.#buffer.length >= SAMPLE_BYTES || countLines(this.#buffer) >= SAMPLE_LINES) {
      this.decide();
    }
  }

  /** Whether a whole line has come, so that a slow input can be decided on what it has sent. */
  get hasLine(): boolean {
    return this.#parser !== undefined || this.#buffer.includes("\n");
  }

  /**
   * Settles the shape on what has come so far, and lets the records flow. Called when the
   * sample is full, at the end, and by a timer when the input is slow to come.
   */
  decide(): void {
    if (this.#decided) return;
    this.#decided = true;
    const text = this.#buffer;
    this.#buffer = "";
    this.#format ??= detect(text, this.#ended);
    this.#parser = parserFor(this.#format, this.sink);
    this.#parser.feed(text);
  }

  end(): void {
    this.#ended = true;
    this.decide();
    this.#parser!.end();
  }
}

function countLines(text: string): number {
  let n = 0;
  for (let at = text.indexOf("\n"); at >= 0; at = text.indexOf("\n", at + 1)) n += 1;
  return n;
}

/** The complete lines of a sample, plain, without the blank ones. */
function sampleLines(text: string, ended: boolean): string[] {
  const lines = text.split("\n");
  if (!ended) lines.pop();
  return lines.map((line) => plain(line.replace(/\r$/, ""))).filter((line) => line.trim() !== "");
}

/** The shape of an input, from its first lines. */
export function detect(text: string, ended = true): Format {
  const lines = sampleLines(text, ended);
  const first = lines[0]?.trim();
  if (first === undefined) return "lines";
  if (first.startsWith("{") || first.startsWith("[")) {
    const value = tryJson(first);
    if (isObject(value)) return "jsonl";
    if (Array.isArray(value)) return "json";
    if (first === "{" || first === "[" || /^\[\s*[{["]/.test(first) || /^\{\s*"/.test(first)) {
      return "json";
    }
  }
  if (lines.length < 2) return "lines";
  const tabs = lines.map((line) => line.split("\t").length - 1);
  if (tabs[0]! >= 1 && tabs.every((n) => n === tabs[0])) return "tsv";
  const commas = lines.map((line) => csvFields(line, ",").length);
  if (commas[0]! >= 2 && commas.every((n) => n === commas[0]) && !lines[0]!.includes("  ")) {
    return "csv";
  }
  if (looksLikeHeading(lines[0]!) && columnStarts(lines[0]!, lines.slice(1)).length >= 2) {
    return "columns";
  }
  return "lines";
}

function tryJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** `NAME   READY   STATUS`, `USER PID %CPU`, `Filesystem Size Used`: words a table is headed with. */
function looksLikeHeading(line: string): boolean {
  const words = line.trim().split(/\s+/);
  if (words.length < 2 || words.length > 40) return false;
  if (!/^\p{Lu}/u.test(words[0]!)) return false;
  return words.every((word) => !/^[+-]?\d/.test(word) && !/[/=:]/.test(word) && word.length <= 32);
}

/** Splits one line of CSV that has no quoted line break: for telling the shape. */
function csvFields(line: string, delimiter: string): string[] {
  const fields: string[] = [];
  let field = "";
  let quoted = false;
  for (let at = 0; at < line.length; at++) {
    const c = line[at]!;
    if (quoted) {
      if (c === '"' && line[at + 1] === '"') {
        field += '"';
        at += 1;
      } else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"' && field === "") quoted = true;
    else if (c === delimiter) {
      fields.push(field);
      field = "";
    } else field += c;
  }
  fields.push(field);
  return fields;
}

/**
 * Where the columns of a table lined up with spaces begin: at each place where every line,
 * the heading among them, has a space just before and the heading a word, so that a value
 * with spaces of its own (`Up 2 hours`) stays one cell. The last column takes the rest of
 * each line (`COMMAND` in `ps`).
 */
export function columnStarts(heading: string, lines: readonly string[]): number[] {
  const words = [...heading.matchAll(/\S+/g)].map((m) => m.index!);
  if (words.length === 0) return [];
  const last = words[words.length - 1]!;
  const blank = (line: string, at: number) => at >= line.length || line[at] === " ";
  const gap = (at: number) => blank(heading, at) && lines.every((line) => blank(line, at));
  const starts = [words[0]!];
  for (let at = words[0]! + 1; at <= last; at++) {
    if (gap(at - 1) && !gap(at)) starts.push(at);
  }
  // A column whose values are wider than its heading (a right-aligned PID) begins before
  // the heading's word: the first column still begins at 0.
  starts[0] = 0;
  return starts;
}

/** A line cut at the starts, each boundary moved to the nearest space when a word crosses it. */
export function cutColumns(line: string, starts: readonly number[]): string[] {
  const bounds = [...starts];
  for (let i = 1; i < bounds.length; i++) {
    const at = bounds[i]!;
    if (at >= line.length || line[at - 1] === " " || line[at] === " ") continue;
    const floor = bounds[i - 1]! + 1;
    let left = at - 1;
    while (left >= floor && line[left] !== " ") left -= 1;
    let right = at;
    while (right < line.length && line[right] !== " ") right += 1;
    const toLeft = left >= floor ? at - left - 1 : Infinity;
    const toRight = right < line.length ? right - at : Infinity;
    if (toLeft === Infinity && toRight === Infinity) continue;
    bounds[i] = toLeft <= toRight ? left + 1 : right + 1;
  }
  return bounds.map((from, i) => line.slice(from, bounds[i + 1] ?? line.length).trim());
}

/** Column names from a heading, unique and never empty. */
export function namesOf(fields: readonly string[]): string[] {
  const seen = new Map<string, number>();
  return fields.map((field, at) => {
    const base = field.trim() === "" ? `column ${at + 1}` : field.trim();
    const n = (seen.get(base.toLowerCase()) ?? 0) + 1;
    seen.set(base.toLowerCase(), n);
    return n === 1 ? base : `${base} ${n}`;
  });
}

interface Parser {
  feed(text: string): void;
  end(): void;
}

function parserFor(format: Format, sink: Sink): Parser {
  switch (format) {
    case "lines":
      return new LineParser(sink, (line) => sink.record({ cells: [line], raw: line }), ["line"]);
    case "columns":
      return new ColumnsParser(sink);
    case "csv":
      return new DelimitedParser(sink, ",");
    case "tsv":
      return new DelimitedParser(sink, "\t");
    case "jsonl":
      return new JsonLinesParser(sink);
    case "json":
      return new JsonParser(sink);
  }
}

/** Whole lines, plain, without their endings; blank lines are skipped. */
class LineParser implements Parser {
  #rest = "";
  #started = false;
  readonly sink: Sink;
  readonly line: (line: string) => void;
  readonly names: string[] | undefined;

  constructor(sink: Sink, line: (line: string) => void, names?: string[]) {
    this.sink = sink;
    this.line = line;
    this.names = names;
  }

  feed(text: string): void {
    this.#start();
    const lines = (this.#rest + text).split("\n");
    this.#rest = lines.pop()!;
    for (const line of lines) this.#one(line);
  }

  end(): void {
    this.#start();
    if (this.#rest !== "") this.#one(this.#rest);
    this.#rest = "";
  }

  #start(): void {
    if (this.#started) return;
    this.#started = true;
    if (this.names) this.sink.columns(this.names);
  }

  #one(line: string): void {
    const clean = plain(line.endsWith("\r") ? line.slice(0, -1) : line);
    if (clean.trim() !== "") this.line(clean);
  }
}

class ColumnsParser implements Parser {
  #lines: LineParser;
  #heading: string | undefined;
  #waiting: string[] = [];
  #starts: number[] | undefined;

  readonly sink: Sink;

  constructor(sink: Sink) {
    this.sink = sink;
    this.#lines = new LineParser(sink, (line) => this.#line(line));
  }

  feed(text: string): void {
    this.#lines.feed(text);
    // The columns are read from what this first piece brought: the sample the shape was
    // told from, or the first lines of a file whose shape was given.
    this.#settle();
  }

  end(): void {
    this.#lines.end();
    this.#settle(true);
  }

  #line(line: string): void {
    if (this.#heading === undefined) this.#heading = line;
    else if (this.#starts === undefined) this.#waiting.push(line);
    else this.#emit(line);
  }

  #settle(ended = false): void {
    if (this.#starts !== undefined || this.#heading === undefined) return;
    // A heading alone tells no column from a space inside a heading (`IMAGE ID`): wait for a line.
    if (this.#waiting.length === 0 && !ended) return;
    this.#starts = columnStarts(this.#heading, this.#waiting.slice(0, 200));
    this.sink.columns(namesOf(cutColumns(this.#heading, this.#starts)));
    for (const line of this.#waiting) this.#emit(line);
    this.#waiting = [];
  }

  #emit(line: string): void {
    this.sink.record({ cells: cutColumns(line, this.#starts!), raw: line });
  }
}

/** CSV or TSV: the first record is the heading; quoted fields may hold line breaks. */
class DelimitedParser implements Parser {
  #field = "";
  #cells: string[] = [];
  #raw = "";
  #quoted = false;
  /** A quote just closed inside a quoted field: the next quote makes it a literal one. */
  #closing = false;
  #heading = true;

  readonly sink: Sink;

  readonly delimiter: string;

  constructor(sink: Sink, delimiter: string) {
    this.sink = sink;

    this.delimiter = delimiter;
  }

  feed(text: string): void {
    for (let at = 0; at < text.length; at++) this.#char(text[at]!);
  }

  end(): void {
    if (this.#raw.trim() !== "" || this.#cells.length > 0) this.#record();
  }

  #char(c: string): void {
    if (c === "\n" && !this.#quoted) {
      this.#record();
      return;
    }
    this.#raw += c;
    if (this.#quoted) {
      if (c === '"') {
        this.#quoted = false;
        this.#closing = true;
      } else this.#field += c;
      return;
    }
    if (this.#closing && c === '"') {
      this.#field += '"';
      this.#quoted = true;
      this.#closing = false;
      return;
    }
    this.#closing = false;
    if (c === '"' && this.#field === "") this.#quoted = true;
    else if (c === this.delimiter) {
      this.#cells.push(this.#field);
      this.#field = "";
    } else if (c !== "\r") this.#field += c;
  }

  #record(): void {
    const raw = plain(this.#raw.replace(/\r$/, ""));
    this.#cells.push(this.#field);
    const cells = this.#cells.map(plain);
    this.#field = "";
    this.#cells = [];
    this.#raw = "";
    this.#closing = false;
    if (raw.trim() === "") return;
    if (this.#heading) {
      this.#heading = false;
      this.sink.columns(namesOf(cells), raw);
    } else {
      this.sink.record({ cells, raw });
    }
  }
}

/** The columns of JSON objects: their keys, in the order they were first seen. */
class Keys {
  readonly names: string[] = [];
  readonly #at = new Map<string, number>();

  readonly sink: Sink;

  constructor(sink: Sink) {
    this.sink = sink;
  }

  /** The cells of a value, telling the sink of keys it brings. */
  cells(value: unknown): string[] {
    if (!isObject(value)) {
      this.#add(["value"]);
      const cells: string[] = [];
      cells[this.#at.get("value")!] = textOf(value);
      return fill(cells);
    }
    this.#add(Object.keys(value));
    const cells: string[] = [];
    for (const [key, item] of Object.entries(value)) cells[this.#at.get(key)!] = textOf(item);
    return fill(cells);
  }

  #add(keys: string[]): void {
    let added = false;
    for (const key of keys) {
      if (this.#at.has(key)) continue;
      this.#at.set(key, this.names.length);
      this.names.push(key);
      added = true;
    }
    if (added) this.sink.columns([...this.names]);
  }
}

function fill(cells: string[]): string[] {
  for (let at = 0; at < cells.length; at++) cells[at] ??= "";
  return cells;
}

function textOf(value: unknown): string {
  if (value === null || value === undefined) return "";
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return JSON.stringify(value);
}

class JsonLinesParser implements Parser {
  #lines: LineParser;
  #keys: Keys;
  #bad = 0;

  readonly sink: Sink;

  constructor(sink: Sink) {
    this.sink = sink;
    this.#keys = new Keys(sink);
    this.#lines = new LineParser(sink, (line) => this.#line(line));
  }

  feed(text: string): void {
    this.#lines.feed(text);
  }

  end(): void {
    this.#lines.end();
  }

  #line(line: string): void {
    const value = tryJson(line);
    if (value === undefined) {
      this.#bad += 1;
      // Told once, then counted: a log with a line of text in it should not drown the view.
      if (this.#bad === 1 || this.#bad % 1000 === 0) {
        this.sink.problem(`${this.#bad === 1 ? "A line is" : `${this.#bad} lines are`} not JSON`);
      }
      return;
    }
    this.sink.record({ cells: this.#keys.cells(value), raw: line, value });
  }
}

/** One JSON document, read whole: an array is its elements, `{"items": [...]}` its items. */
class JsonParser implements Parser {
  #text = "";

  readonly sink: Sink;

  constructor(sink: Sink) {
    this.sink = sink;
  }

  feed(text: string): void {
    this.#text += text;
  }

  end(): void {
    const value = tryJson(this.#text);
    if (value === undefined) {
      this.sink.problem("The input is not one JSON document");
      return;
    }
    const keys = new Keys(this.sink);
    for (const item of elementsOf(value)) {
      this.sink.record({ cells: keys.cells(item), raw: JSON.stringify(item), value: item });
    }
    if (keys.names.length === 0) this.sink.columns(["value"]);
  }
}

/** The rows of a JSON document: an array's elements, the one array of objects an object holds, or itself. */
function elementsOf(value: unknown): unknown[] {
  if (Array.isArray(value)) return value;
  if (isObject(value)) {
    const arrays = Object.values(value).filter(
      (item): item is unknown[] => Array.isArray(item) && item.length > 0 && item.every(isObject),
    );
    if (arrays.length === 1) return arrays[0]!;
  }
  return [value];
}
