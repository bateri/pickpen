/** What the program and the view say to each other, beyond MCP: the tools' structured results. */

export type Format = "lines" | "csv" | "tsv" | "columns" | "jsonl" | "json";

/** What the view starts from, as the command line set it. */
export interface Boot {
  version: string;
  title: string | null;
  query: string;
  where: string | null;
  confirm: boolean;
  sort: { column: string; descending: boolean } | null;
  /** The `--preview` command, when there is one. */
  preview: string | null;
  /** The input and output flags as given, for the command line the view shows. */
  given: { input?: string; field?: string[]; format?: string; output?: string };
}

/** An answer of `pickpen_rows`, and the rows `show_picker` starts with. */
export interface Batch {
  /** The place of the first row in `rows`. */
  from: number;
  rows: string[][];
  /** How many rows there are now. */
  total: number;
  columns: string[];
  format: Format | null;
  done: boolean;
  capped: boolean;
  problems: string[];
  /** Some cell of these rows was longer than a view is given, and was cut. */
  cut: boolean;
}

export interface Shown extends Batch {
  boot: Boot;
}

export interface PreviewResult {
  text: string;
  /** The command's status, or null when a signal ended it. */
  status: number | null;
  cut: boolean;
  timedOut: boolean;
}

export interface OutputResult {
  text: string;
}
