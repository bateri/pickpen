/**
 * What goes out on stdout for the rows chosen. One function writes it, and the view's
 * picture of what will go out is drawn by the same function, so that the two never differ.
 *
 * In the input's shape, a row goes out as the text it was read from: lines and columns as
 * their lines (a table's heading stays behind, so that `| xargs` is given only rows), CSV
 * and TSV after their heading, JSON lines as their lines, and a JSON document as an array of
 * the elements chosen. `--field`, `--format` and `--output` shape it otherwise.
 */

import { columnNamed } from "../shared/query.ts";
import type { Format, InputRecord } from "./input.ts";

export type Shape =
  | { kind: "input" }
  | { kind: "fields"; names: string[] }
  | { kind: "template"; template: string }
  | { kind: "as"; format: "csv" | "tsv" | "json" | "jsonl" };

export interface Source {
  format: Format | undefined;
  names: readonly string[];
  heading: string | undefined;
}

/** Why the shape cannot be written with these columns, or undefined when it can. */
export function problemOf(shape: Shape, names: readonly string[]): string | undefined {
  const missing = (name: string) => `There is no column named ${JSON.stringify(name)}`;
  if (shape.kind === "fields") {
    const unknown = shape.names.find((name) => columnNamed(names, name) < 0);
    return unknown === undefined ? undefined : missing(unknown);
  }
  if (shape.kind === "template") {
    for (const [, name] of shape.template.matchAll(/\{([^{}]*)\}/g)) {
      if (name === "" || /^\d+$/.test(name!)) continue;
      if (columnNamed(names, name!) < 0) return missing(name!);
    }
  }
  return undefined;
}

function csvCell(cell: string): string {
  return /[",\n\r]/.test(cell) || cell !== cell.trim() ? `"${cell.replace(/"/g, '""')}"` : cell;
}

function tsvCell(cell: string): string {
  return cell.replace(/[\t\n\r]/g, " ");
}

function objectOf(record: InputRecord, names: readonly string[]): unknown {
  if (record.value !== undefined) return record.value;
  return Object.fromEntries(names.map((name, at) => [name, record.cells[at] ?? ""]));
}

/** Where the output ends a line: every line it writes ends with one. */
const lines = (items: string[]) => items.map((item) => `${item}\n`).join("");

/** The rows as they go out; nothing at all for no rows. */
export function render(records: readonly InputRecord[], shape: Shape, source: Source): string {
  if (records.length === 0) return "";
  const { names } = source;
  switch (shape.kind) {
    case "fields": {
      const at = shape.names.map((name) => columnNamed(names, name));
      return lines(records.map((r) => at.map((column) => r.cells[column] ?? "").join("\t")));
    }
    case "template":
      return lines(records.map((r) => fillTemplate(shape.template, r, names)));
    case "as":
      return renderAs(shape.format, records, source);
    case "input":
      switch (source.format) {
        case "csv":
        case "tsv":
          return (
            lines([source.heading ?? names.join(source.format === "csv" ? "," : "\t")]) +
            lines(records.map((r) => r.raw))
          );
        case "json":
          return `[\n${records.map((r) => `  ${r.raw}`).join(",\n")}\n]\n`;
        default:
          return lines(records.map((r) => r.raw));
      }
  }
}

function renderAs(
  format: "csv" | "tsv" | "json" | "jsonl",
  records: readonly InputRecord[],
  { names }: Source,
): string {
  switch (format) {
    case "csv":
      return lines([
        names.map(csvCell).join(","),
        ...records.map((r) => names.map((_, at) => csvCell(r.cells[at] ?? "")).join(",")),
      ]);
    case "tsv":
      return lines([
        names.map(tsvCell).join("\t"),
        ...records.map((r) => names.map((_, at) => tsvCell(r.cells[at] ?? "")).join("\t")),
      ]);
    case "jsonl":
      return lines(records.map((r) => JSON.stringify(objectOf(r, names))));
    case "json":
      return `[\n${records.map((r) => `  ${JSON.stringify(objectOf(r, names))}`).join(",\n")}\n]\n`;
  }
}

/** `{NAME}` is that column, `{2}` the second, `{}` the row as it was read. */
export function fillTemplate(
  template: string,
  record: InputRecord,
  names: readonly string[],
): string {
  return template.replace(/\{([^{}]*)\}/g, (_, name: string) => {
    if (name === "") return record.raw;
    if (/^\d+$/.test(name)) return record.cells[Number(name) - 1] ?? "";
    const at = columnNamed(names, name);
    return at < 0 ? "" : (record.cells[at] ?? "");
  });
}

/** Whether rows can be written one by one as they come, rather than all at the end. */
export function streams(shape: Shape, format: Format | undefined): boolean {
  if (shape.kind === "as") return shape.format !== "json";
  if (shape.kind === "input") return format !== "json";
  return true;
}

/** What goes ahead of the first row when rows are written one by one. */
export function head(shape: Shape, source: Source): string {
  if (shape.kind === "as" && shape.format === "csv")
    return lines([source.names.map(csvCell).join(",")]);
  if (shape.kind === "as" && shape.format === "tsv")
    return lines([source.names.map(tsvCell).join("\t")]);
  if (shape.kind === "input" && (source.format === "csv" || source.format === "tsv")) {
    return lines([source.heading ?? source.names.join(source.format === "csv" ? "," : "\t")]);
  }
  return "";
}

/** One row, as it goes out after `head` when rows are written one by one. */
export function one(record: InputRecord, shape: Shape, source: Source): string {
  if (shape.kind === "as" && (shape.format === "csv" || shape.format === "tsv")) {
    return render([record], shape, source).split("\n").slice(1).join("\n");
  }
  if (shape.kind === "input" && (source.format === "csv" || source.format === "tsv")) {
    return `${record.raw}\n`;
  }
  return render([record], shape, source);
}
