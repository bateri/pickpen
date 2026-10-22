/**
 * The rows the view holds, outside React: a few hundred thousand rows are kept once, and the
 * store holds only what is derived from them and a version that moves when they change.
 */

import { compareOrdered, matches, parse, rowOf, sortKey } from "../../shared/query";
import type { Query, Row, SortKey } from "../../shared/query";
import { columnKind } from "../../shared/values";
import type { Kind } from "../../shared/values";
import type { Batch, Format } from "../../shared/wire";

export interface Table {
  columns: string[];
  kinds: (Kind | "text")[];
  rows: Row[];
  format: Format | null;
  done: boolean;
  capped: boolean;
  problems: string[];
  cut: boolean;
}

export const table: Table = {
  columns: [],
  kinds: [],
  rows: [],
  format: null,
  done: false,
  capped: false,
  problems: [],
  cut: false,
};

/** Takes a batch in, when it follows on from the rows held. The places of the rows it added. */
export function take(batch: Batch): { added: number; columnsChanged: boolean } {
  const columnsChanged = batch.columns.join("\u0000") !== table.columns.join("\u0000");
  table.columns = batch.columns;
  table.format = batch.format;
  table.done = batch.done;
  table.capped = batch.capped;
  table.problems = batch.problems;
  table.cut ||= batch.cut;
  if (batch.from !== table.rows.length) return { added: 0, columnsChanged };
  for (const cells of batch.rows) table.rows.push(rowOf(cells));
  // A column's kind is read from its first rows; more rows seldom change it.
  if (columnsChanged || table.rows.length - batch.rows.length < 500) {
    table.kinds = table.columns.map((_, at) => columnKind(cellsOf(at, 500)));
    sortCache.clear();
  }
  return { added: batch.rows.length, columnsChanged };
}

function* cellsOf(column: number, limit: number): Iterable<string> {
  const end = Math.min(table.rows.length, limit);
  for (let at = 0; at < end; at++) yield table.rows[at]!.cells[column] ?? "";
}

/** Sort keys by column, read once and extended as rows come. */
const sortCache = new Map<number, SortKey[]>();

function keysOf(column: number): SortKey[] {
  let keys = sortCache.get(column);
  if (!keys) {
    keys = [];
    sortCache.set(column, keys);
  }
  for (let at = keys.length; at < table.rows.length; at++) {
    keys.push(sortKey(table.rows[at]!.cells[column] ?? ""));
  }
  return keys;
}

export interface Order {
  column: number;
  descending: boolean;
}

/** Rows in the order the view shows them; ties keep the input's order. */
export function sortIds(ids: number[], order: Order | null): number[] {
  if (order === null || order.column >= table.columns.length) return ids;
  const keys = keysOf(order.column);
  return ids.sort((a, b) => compareOrdered(keys[a]!, keys[b]!, order.descending) || a - b);
}

/** The rows from `from` on that a query matches, by place. */
export function matching(query: Query, from = 0, to = table.rows.length): number[] {
  const ids: number[] = [];
  for (let at = from; at < to; at++) {
    if (query.empty || matches(query, table.rows[at]!)) ids.push(at);
  }
  return ids;
}

export function parsed(source: string): Query {
  return parse(source, table.columns);
}
