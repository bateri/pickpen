/**
 * The query: what a person types above the rows, and what `--where` runs with no person.
 * One language and one reading of it, in the view and in the program, so that the command
 * line the view shows chooses the rows the view showed.
 *
 *   word            the row holds the word, in any column, in any case
 *   !word           it does not
 *   "two words"     quotes keep spaces in a word or a value
 *   col=v           the column is v (a quantity compares as one: `size=1G`), `col=a|b` either
 *   col!=v          it is not
 *   col~v  col!~v   it holds v, or does not, in any case
 *   col>v  col>=v  col<v  col<=v
 *                   compared as quantities when both are one (`cpu>50`, `age<2h`, `size>1G`),
 *                   otherwise as text
 *   col=a..b        between a and b, both included
 *
 * Every term must hold. A column is named as its heading is, in any case, or with only its
 * letters and digits (`cpu` for `%CPU`, `containerid` for `CONTAINER ID`). A name that is
 * no column's makes the whole term a word: `user=bob` searches lines for `user=bob`.
 */

import { comparable, quantity } from "./values.ts";
import type { Quantity } from "./values.ts";

export type Operator = "=" | "!=" | "~" | "!~" | ">" | ">=" | "<" | "<=";

export type Term =
  | { kind: "text"; text: string; negate: boolean; from: number; to: number }
  | {
      kind: "field";
      column: number;
      op: Operator;
      /** For `=` and `!=`: each alternative of `a|b`. Otherwise one value. */
      values: string[];
      /** For `=` written as `a..b`. */
      range?: [string, string];
      from: number;
      to: number;
    };

export interface Query {
  terms: Term[];
  /** The query had nothing to test: every row matches. */
  empty: boolean;
}

interface Token {
  text: string;
  /** The token as written, quotes and all, for finding the operator outside quotes. */
  raw: string;
  from: number;
  to: number;
}

const OPERATORS: Operator[] = [">=", "<=", "!=", "!~", "=", "~", ">", "<"];

/** Splits on spaces outside quotes; quotes are dropped from the text and kept in `raw`. */
function tokenize(source: string): Token[] {
  const tokens: Token[] = [];
  let at = 0;
  while (at < source.length) {
    while (at < source.length && /\s/.test(source[at]!)) at += 1;
    if (at >= source.length) break;
    const from = at;
    let text = "";
    let quote: string | undefined;
    while (at < source.length) {
      const c = source[at]!;
      if (quote) {
        if (c === quote) quote = undefined;
        else text += c;
      } else if (c === '"' || c === "'") {
        quote = c;
      } else if (/\s/.test(c)) {
        break;
      } else {
        text += c;
      }
      at += 1;
    }
    tokens.push({ text, raw: source.slice(from, at), from, to: at });
  }
  return tokens;
}

/** Letters and digits only, in lower case: how a heading may be named. */
export function simpleName(name: string): string {
  return name.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
}

/** The column a name names, or -1. */
export function columnNamed(columns: readonly string[], name: string): number {
  const lower = name.toLowerCase();
  const exact = columns.findIndex((c) => c.toLowerCase() === lower);
  if (exact >= 0) return exact;
  const simple = simpleName(name);
  if (simple === "") return -1;
  return columns.findIndex((c) => simpleName(c) === simple);
}

/** Where the operator is in a raw token, outside quotes: the first, longest first. */
function findOperator(raw: string): { at: number; op: Operator } | undefined {
  let quote: string | undefined;
  for (let at = 0; at < raw.length; at++) {
    const c = raw[at]!;
    if (quote) {
      if (c === quote) quote = undefined;
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      continue;
    }
    for (const op of OPERATORS) {
      if (raw.startsWith(op, at)) return { at, op };
    }
  }
  return undefined;
}

function unquote(raw: string): string {
  return tokenize(raw)
    .map((t) => t.text)
    .join(" ");
}

export function parse(source: string, columns: readonly string[]): Query {
  const terms: Term[] = [];
  for (const token of tokenize(source)) {
    const found = findOperator(token.raw);
    if (found && found.at > 0) {
      const name = unquote(token.raw.slice(0, found.at));
      const column = columnNamed(columns, name);
      if (column >= 0) {
        const value = unquote(token.raw.slice(found.at + found.op.length));
        const { op } = found;
        const range = op === "=" ? /^(.*[^.])\.\.([^.].*)$/.exec(value) : null;
        terms.push({
          kind: "field",
          column,
          op,
          values: op === "=" || op === "!=" ? value.split("|") : [value],
          ...(range ? { range: [range[1]!, range[2]!] as [string, string] } : {}),
          from: token.from,
          to: token.to,
        });
        continue;
      }
    }
    const negate = token.raw.startsWith("!") && token.raw.length > 1;
    const text = negate ? unquote(token.raw.slice(1)) : token.text;
    if (text === "") continue;
    terms.push({ kind: "text", text: text.toLowerCase(), negate, from: token.from, to: token.to });
  }
  return { terms, empty: terms.length === 0 };
}

/**
 * The names a query compares that are no column's, each once: such a term is looked for as
 * a word, which is seldom what was meant, so the view marks it and `--where` says so.
 */
export function unknownNames(source: string, columns: readonly string[]): string[] {
  const names = new Set<string>();
  for (const token of tokenize(source)) {
    const found = findOperator(token.raw);
    if (!found || found.at === 0) continue;
    const name = unquote(token.raw.slice(0, found.at));
    if (columnNamed(columns, name) < 0) names.add(name);
  }
  return [...names];
}

/** What a row is to a query: its cells, and the text a word is looked for in. */
export interface Row {
  cells: readonly string[];
  /** The cells joined by tabs, in lower case. */
  lower: string;
}

export function rowOf(cells: readonly string[]): Row {
  return { cells, lower: cells.join("\t").toLowerCase() };
}

/**
 * Text in order, with runs of digits by their number, without regard to case: `file9`
 * before `file10`. A plain loop, not `Intl.Collator`, so that the view and the program,
 * on two machines, put rows in one order.
 */
export function compareText(a: string, b: string): number {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  let i = 0;
  let j = 0;
  while (i < x.length && j < y.length) {
    const cx = x.charCodeAt(i);
    const cy = y.charCodeAt(j);
    const dx = cx >= 48 && cx <= 57;
    const dy = cy >= 48 && cy <= 57;
    if (dx && dy) {
      let ei = i;
      let ej = j;
      while (ei < x.length && x.charCodeAt(ei) >= 48 && x.charCodeAt(ei) <= 57) ei++;
      while (ej < y.length && y.charCodeAt(ej) >= 48 && y.charCodeAt(ej) <= 57) ej++;
      const nx = x.slice(i, ei).replace(/^0+(?=\d)/, "");
      const ny = y.slice(j, ej).replace(/^0+(?=\d)/, "");
      if (nx.length !== ny.length) return nx.length - ny.length;
      if (nx !== ny) return nx < ny ? -1 : 1;
      i = ei;
      j = ej;
      continue;
    }
    if (cx !== cy) return cx - cy;
    i++;
    j++;
  }
  return x.length - i - (y.length - j) || (a < b ? -1 : a > b ? 1 : 0);
}

/** A cell as the sort reads it, read once so that a long sort parses each cell once. */
export interface SortKey {
  text: string;
  empty: boolean;
  q: Quantity | undefined;
}

export function sortKey(cell: string): SortKey {
  const empty = cell.trim() === "";
  return { text: cell, empty, q: empty ? undefined : quantity(cell) };
}

/**
 * Two cells in order: quantities that compare as quantities, before words, which compare
 * as text; empty cells last. The order is the same in the view and with `--sort`.
 */
export function compareKeys(a: SortKey, b: SortKey): number {
  if (a.empty || b.empty) return a.empty === b.empty ? 0 : a.empty ? 1 : -1;
  const { q: qa } = a;
  const { q: qb } = b;
  if (qa && qb && comparable(qa, qb)) return qa.value - qb.value || compareText(a.text, b.text);
  if (qa && !qb) return -1;
  if (qb && !qa) return 1;
  if (qa && qb) return qa.kind < qb.kind ? -1 : qa.kind > qb.kind ? 1 : qa.value - qb.value;
  return compareText(a.text, b.text);
}

/** The order `--sort` and the view's headings put rows in: empty cells last either way. */
export function compareOrdered(a: SortKey, b: SortKey, descending: boolean): number {
  if (a.empty || b.empty) return a.empty === b.empty ? 0 : a.empty ? 1 : -1;
  const d = compareKeys(a, b);
  return descending ? -d : d;
}

function order(cell: string, value: string, cellQ: Quantity | undefined): number | undefined {
  const valueQ = quantity(value);
  if (valueQ) {
    if (!cellQ || !comparable(cellQ, valueQ)) return undefined;
    return cellQ.value - valueQ.value;
  }
  if (cell.trim() === "") return undefined;
  return compareText(cell.trim(), value);
}

function equal(cell: string, value: string, cellQ: Quantity | undefined): boolean {
  const valueQ = quantity(value);
  if (valueQ && cellQ && comparable(cellQ, valueQ)) return cellQ.value === valueQ.value;
  return cell.trim().toLowerCase() === value.toLowerCase();
}

function holds(term: Term, row: Row): boolean {
  if (term.kind === "text") return row.lower.includes(term.text) !== term.negate;
  const cell = row.cells[term.column] ?? "";
  const cellQ = quantity(cell);
  switch (term.op) {
    case "=":
      if (term.range) {
        const low = order(cell, term.range[0], cellQ);
        const high = order(cell, term.range[1], cellQ);
        return low !== undefined && high !== undefined && low >= 0 && high <= 0;
      }
      return term.values.some((v) => equal(cell, v, cellQ));
    case "!=":
      return !term.values.some((v) => equal(cell, v, cellQ));
    case "~":
      return cell.toLowerCase().includes(term.values[0]!.toLowerCase());
    case "!~":
      return !cell.toLowerCase().includes(term.values[0]!.toLowerCase());
    default: {
      const d = order(cell, term.values[0]!, cellQ);
      if (d === undefined) return false;
      if (term.op === ">") return d > 0;
      if (term.op === ">=") return d >= 0;
      if (term.op === "<") return d < 0;
      return d <= 0;
    }
  }
}

export function matches(query: Query, row: Row): boolean {
  for (const term of query.terms) if (!holds(term, row)) return false;
  return true;
}

/** A value as the query needs it written: quoted when it has a space, a quote or an operator. */
export function quoteValue(value: string): string {
  if (value !== "" && !/[\s"'=!~<>|]/.test(value)) return value;
  return value.includes('"') ? `'${value}'` : `"${value}"`;
}

/** A column's name as the query needs it written. */
export function quoteName(name: string): string {
  return quoteValue(name);
}

/**
 * The query with the terms on one column replaced by `term` (or removed, for `undefined`),
 * which is how the view's clicks write into what the person types.
 */
export function withTerm(
  source: string,
  columns: readonly string[],
  column: number,
  term: string | undefined,
): string {
  const parsed = parse(source, columns);
  let out = "";
  let at = 0;
  let placed = false;
  for (const t of parsed.terms) {
    if (t.kind === "field" && t.column === column) {
      out += source.slice(at, t.from);
      if (!placed && term !== undefined) {
        out += term;
        placed = true;
      }
      at = t.to;
    }
  }
  out += source.slice(at);
  out = out.replace(/\s{2,}/g, " ").trim();
  if (!placed && term !== undefined) out = out === "" ? term : `${out} ${term}`;
  return out;
}
