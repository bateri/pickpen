/**
 * What the view does: take rows in, filter and sort them, move the cursor, mark, and send.
 * Every key, click and command ends up here, so that the keyboard and the mouse do the same.
 */

import { commandLine } from "../../shared/command";
import { columnNamed, quoteName, quoteValue, withTerm } from "../../shared/query";
import type { Query } from "../../shared/query";
import type { Batch, Shown } from "../../shared/wire";
import { ToolError, call, copy } from "../lib/bridge";
import { matching, parsed, sortIds, table, take } from "./data";
import type { Order } from "./data";
import { get, set } from "./store";
import type { Tab } from "./store";

// ---- focus -----------------------------------------------------------------------------

let queryInput: HTMLInputElement | null = null;

export function setQueryInput(input: HTMLInputElement | null): void {
  queryInput = input;
}

/** The keyboard goes back to what the person types in, after a click or an overlay. */
export function focusQuery(): void {
  if (get().overlay !== null) return;
  if (document.activeElement !== queryInput) queryInput?.focus({ preventScroll: true });
}

// ---- toasts ----------------------------------------------------------------------------

let toastTimer: ReturnType<typeof setTimeout> | undefined;

export function toast(text: string, tone: "info" | "bad" = "info"): void {
  clearTimeout(toastTimer);
  set({ toast: { text, tone, at: Date.now() } });
  toastTimer = setTimeout(() => set({ toast: null }), tone === "bad" ? 5000 : 2200);
}

// ---- filtering and order ---------------------------------------------------------------

/** How many rows a page is, as the list last measured itself. */
let pageRows = 10;

export function setPageRows(rows: number): void {
  pageRows = Math.max(1, rows);
}

function placesOf(ids: number[]): Int32Array {
  const where = new Int32Array(table.rows.length).fill(-1);
  for (let i = 0; i < ids.length; i++) where[ids[i]!] = i;
  return where;
}

/** The cursor after the rows shown changed: on its row if it is still shown, else on the first. */
function keptCursor(ids: number[], where: Int32Array): number | null {
  const { cursor } = get();
  if (ids.length === 0) return null;
  if (cursor !== null && (where[cursor] ?? -1) >= 0) return cursor;
  return ids[0]!;
}

/**
 * The rows to show, in order. A new query or order starts the cursor at the top, as a search
 * does; rows taken into their places while they come leave it on its row.
 */
function refilter(fromTop: boolean): void {
  const { query, order } = get();
  const ids = sortIds(matching(parsed(query)), order);
  const where = placesOf(ids);
  set({
    shown: ids,
    where,
    cursor: fromTop ? (ids[0] ?? null) : keptCursor(ids, where),
    ...(fromTop ? { follow: false } : {}),
  });
}

let filterTimer: ReturnType<typeof setTimeout> | undefined;

/** What the person typed; a large table is filtered a moment after the last key, not on each. */
export function setQuery(query: string): void {
  set({ query });
  clearTimeout(filterTimer);
  if (table.rows.length > 20_000) filterTimer = setTimeout(() => refilter(true), 60);
  else refilter(true);
}

export function setOrder(order: Order | null): void {
  set({ order, ...(order ? { column: order.column } : {}) });
  refilter(true);
}

/** A heading's click: up, then down, then the input's order again. */
export function cycleOrder(column: number): void {
  const { order } = get();
  if (order?.column !== column) setOrder({ column, descending: false });
  else if (!order.descending) setOrder({ column, descending: true });
  else setOrder(null);
}

/** The query with a column's term replaced, which is how a click filters. */
export function setTerm(column: number, term: string | undefined): void {
  setQuery(withTerm(get().query, table.columns, column, term));
  focusQuery();
}

/** The term that keeps rows whose column is (or is not) this value. */
export function termFor(column: number, value: string, negate = false): string {
  return `${quoteName(table.columns[column] ?? "")}${negate ? "!=" : "="}${quoteValue(value)}`;
}

// ---- rows coming in --------------------------------------------------------------------

/** The `--where` of `--confirm`: rows it matches are marked as they come. */
let rule: Query | null = null;
let ruleSource: string | null = null;
let resortTimer: ReturnType<typeof setTimeout> | undefined;

function takeBatch(batch: Batch): void {
  total = batch.total;
  const from = table.rows.length;
  const { added, columnsChanged } = take(batch);
  if (ruleSource !== null && (columnsChanged || rule === null)) rule = parsed(ruleSource);
  if (added > 0 && rule !== null) {
    const marked = new Set(get().marked);
    for (const id of matching(rule, from, from + added)) marked.add(id);
    set({ marked });
  }
  const state = get();
  if (columnsChanged || state.widths.length !== table.columns.length) {
    set({ widths: widthsFor(state.widths) });
  }
  if (columnsChanged || state.order !== null) {
    // A sorted list takes new rows into their places at most a few times a second.
    if (columnsChanged || from === 0) refilter(false);
    else if (added > 0 && resortTimer === undefined) {
      resortTimer = setTimeout(() => {
        resortTimer = undefined;
        refilter(false);
      }, 250);
    }
  } else if (added > 0) {
    const fresh = matching(parsed(state.query), from, from + added);
    const shown = state.shown.concat(fresh);
    const where = new Int32Array(table.rows.length).fill(-1);
    where.set(state.where.subarray(0, Math.min(state.where.length, where.length)));
    for (let i = state.shown.length; i < shown.length; i++) where[shown[i]!] = i;
    set({
      shown,
      where,
      cursor: state.follow ? (shown.at(-1) ?? null) : (state.cursor ?? shown[0] ?? null),
      unseen: state.follow ? 0 : state.unseen + fresh.length,
    });
  }
  set({ version: get().version + 1 });
}

/** Widths for columns, from their names and first rows, in the characters of the list's font. */
function widthsFor(known: number[]): number[] {
  const char = charWidth();
  return table.columns.map((name, column) => {
    if (known[column] !== undefined && known.length === table.columns.length) return known[column]!;
    let longest = name.length + 2;
    const end = Math.min(table.rows.length, 300);
    for (let at = 0; at < end; at++) {
      longest = Math.max(longest, (table.rows[at]!.cells[column] ?? "").length);
    }
    return Math.round(Math.min(Math.max(longest, 4), 60) * char + 20);
  });
}

let measured = 0;

/** The width of one character of the list's font. */
export function charWidth(): number {
  if (measured > 0) return measured;
  const probe = document.createElement("span");
  probe.className = "probe";
  probe.textContent = "0".repeat(50);
  document.body.append(probe);
  measured = probe.getBoundingClientRect().width / 50 || 7.4;
  probe.remove();
  return measured;
}

export async function start(first: Shown): Promise<void> {
  const { boot } = first;
  ruleSource = boot.confirm && boot.where !== null ? boot.where : null;
  const wide = window.innerWidth >= 1000;
  set({
    boot,
    query: boot.query,
    panel: { open: wide, tab: boot.preview !== null ? "row" : "output" },
    panelWidth: Math.round(Math.min(Math.max(window.innerWidth * 0.32, 300), 560)),
  });
  takeBatch(first);
  if (boot.sort) {
    const column = columnNamed(table.columns, boot.sort.column);
    if (column >= 0) setOrder({ column, descending: boot.sort.descending });
    else toast(`There is no column named ${JSON.stringify(boot.sort.column)} to sort by`, "bad");
  }
  void poll();
}

let polling = false;
/** How many rows the program last said it has. */
let total = 0;

/** Asks for rows until the input ends, each answer waiting a moment for more. */
async function poll(): Promise<void> {
  if (polling) return;
  polling = true;
  let failures = 0;
  while (!get().sending && !(table.done && table.rows.length >= total)) {
    try {
      takeBatch(await call<Batch>("pickpen_rows", { since: table.rows.length }));
      failures = 0;
    } catch (error) {
      failures += 1;
      if (failures >= 5) {
        set({ error: error instanceof Error ? error.message : String(error) });
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 500 * failures));
    }
  }
  polling = false;
}

// ---- the cursor ------------------------------------------------------------------------

function at(index: number): number | null {
  const { shown } = get();
  if (shown.length === 0) return null;
  return shown[Math.max(0, Math.min(index, shown.length - 1))]!;
}

function indexOfCursor(): number {
  const { cursor, where } = get();
  return cursor === null ? -1 : (where[cursor] ?? -1);
}

export function moveTo(index: number): void {
  const cursor = at(index);
  if (cursor !== null) set({ cursor, follow: false });
}

export function move(delta: number): void {
  const index = indexOfCursor();
  moveTo(index < 0 ? 0 : index + delta);
}

export function page(direction: 1 | -1): void {
  move(direction * Math.max(1, pageRows - 1));
}

export function first(): void {
  moveTo(0);
}

export function last(): void {
  moveTo(get().shown.length - 1);
  set({ follow: true, unseen: 0 });
}

export function setCursor(id: number): void {
  set({ cursor: id, follow: false });
}

// ---- marks -----------------------------------------------------------------------------

export function setMarked(ids: Iterable<number>, on: boolean): void {
  const marked = new Set(get().marked);
  for (const id of ids) {
    if (on) marked.add(id);
    else marked.delete(id);
  }
  set({ marked });
}

export function toggle(id: number): void {
  setMarked([id], !get().marked.has(id));
  set({ anchor: id });
}

/** Tab: marks (or unmarks) the row and steps on, as fzf does. */
export function markAndMove(delta: 1 | -1): void {
  const { cursor } = get();
  if (cursor === null) return;
  toggle(cursor);
  move(delta);
}

/** ⇧↑ ⇧↓ and ⇧-click: every row from the anchor to here takes the anchor's mark. */
export function extendTo(id: number): void {
  const { anchor, where, shown, marked } = get();
  const from = anchor !== null && (where[anchor] ?? -1) >= 0 ? where[anchor]! : where[id]!;
  const to = where[id] ?? -1;
  if (to < 0) return;
  const on = anchor === null ? true : marked.has(anchor) || anchor === id;
  const [low, high] = from <= to ? [from, to] : [to, from];
  setMarked(shown.slice(low, high + 1), on);
  if (anchor === null) set({ anchor: id });
  set({ cursor: id });
}

export function extend(delta: 1 | -1): void {
  const { cursor, anchor, marked } = get();
  if (cursor === null) return;
  if (anchor === null || !marked.has(anchor)) {
    set({ anchor: cursor });
    setMarked([cursor], true);
  }
  const next = at(indexOfCursor() + delta);
  if (next !== null) extendTo(next);
}

export function markShown(on = true): void {
  setMarked(get().shown, on);
}

export function unmarkAll(): void {
  set({ marked: new Set(), anchor: null });
}

export function invert(): void {
  const { shown, marked } = get();
  const next = new Set(marked);
  for (const id of shown) {
    if (next.has(id)) next.delete(id);
    else next.add(id);
  }
  set({ marked: next });
}

// ---- what goes out ---------------------------------------------------------------------

/** The rows Send sends, in the order they go out: the marked ones, or the cursor's row. */
export function toSend(): number[] {
  const { marked, cursor, boot, order } = get();
  if (marked.size > 0)
    return sortIds(
      [...marked].sort((a, b) => a - b),
      order,
    );
  if (boot?.confirm || cursor === null) return [];
  return [cursor];
}

/** How many of the marked rows the query hides. */
export function hiddenMarks(): number {
  const { marked, where } = get();
  let hidden = 0;
  for (const id of marked) if ((where[id] ?? -1) < 0) hidden += 1;
  return hidden;
}

/** The columns that go out when the person picked some, else the command line's `--field`. */
export function outputFields(): string[] | undefined {
  const { fields } = get();
  return fields ?? undefined;
}

export async function send(rows = toSend()): Promise<void> {
  if (rows.length === 0 || get().sending) return;
  set({ sending: true, overlay: null });
  try {
    await call("pickpen_choose", { rows, ...(get().fields ? { fields: get().fields } : {}) });
  } catch (error) {
    set({ sending: false });
    toast(error instanceof ToolError ? error.message : String(error), "bad");
  }
}

export async function cancel(): Promise<void> {
  if (get().sending) return;
  set({ sending: true, overlay: null });
  try {
    await call("pickpen_cancel");
  } catch (error) {
    set({ sending: false });
    toast(String(error), "bad");
  }
}

/** Esc, one step at a time toward sending nothing: what is open, then the query, then nothing. */
export function back(): void {
  const state = get();
  if (state.overlay !== null) {
    set({ overlay: null });
    focusQuery();
    return;
  }
  if (state.query !== "") {
    setQuery("");
    return;
  }
  if (state.marked.size > 0 && Date.now() - state.escapeAsked > 2500) {
    set({ escapeAsked: Date.now() });
    toast(`Esc again to send nothing — ${state.marked.size} marked rows would be dropped`);
    return;
  }
  void cancel();
}

export function toggleField(name: string): void {
  const current = get().fields ?? get().boot?.given.field ?? [];
  const has = current.some((f) => f.toLowerCase() === name.toLowerCase());
  const next = has
    ? current.filter((f) => f.toLowerCase() !== name.toLowerCase())
    : [...current, name];
  set({ fields: next.length > 0 ? next : [] });
}

export function resetFields(): void {
  set({ fields: null });
}

// ---- the command that does it again ----------------------------------------------------

export type Again =
  | { kind: "same"; line: string; rows: number; where: string }
  | { kind: "different"; line: string; rows: number; chosen: number; where: string }
  | { kind: "none"; line: string; where: string };

/**
 * The command line that does again what Send would do, with nobody to ask, and whether it
 * does: it does when the rows marked are exactly the rows a query matches — the query typed,
 * or, with `--confirm`, the rule the rows were marked by.
 */
export function again(): Again {
  const { query, order, boot, marked, fields, shown } = get();
  const given = boot?.given ?? {};
  const field = fields ?? given.field;
  const lineFor = (where: string) =>
    commandLine({
      ...(given.input ? { input: given.input } : {}),
      where,
      ...(order
        ? { sort: { column: table.columns[order.column] ?? "", descending: order.descending } }
        : {}),
      ...(field && field.length > 0 ? { field } : {}),
      ...(given.format ? { format: given.format } : {}),
      ...(given.output ? { output: given.output } : {}),
    });
  const queries: { where: string; ids: () => number[] }[] = [{ where: query, ids: () => shown }];
  if (ruleSource !== null && ruleSource.trim() !== query.trim()) {
    const rule = ruleSource;
    queries.push({ where: rule, ids: () => matching(parsed(rule)) });
  }
  // The query typed says what is meant once there is one; until then, the rule does.
  const main = query.trim() === "" && queries[1] ? queries[1] : queries[0]!;
  if (marked.size === 0) return { kind: "none", line: lineFor(main.where), where: main.where };
  for (const candidate of queries) {
    const ids = candidate.ids();
    if (marked.size === ids.length && ids.every((id) => marked.has(id))) {
      return {
        kind: "same",
        line: lineFor(candidate.where),
        rows: ids.length,
        where: candidate.where,
      };
    }
  }
  return {
    kind: "different",
    line: lineFor(main.where),
    rows: main.ids().length,
    chosen: marked.size,
    where: main.where,
  };
}

export async function copyText(text: string, what: string): Promise<void> {
  const done = await copy(text);
  focusQuery();
  toast(done ? `Copied ${what}` : `Could not copy ${what}`, done ? "info" : "bad");
}

export function copyCursorRow(): void {
  const { cursor } = get();
  if (cursor === null) return;
  void copyText(table.rows[cursor]!.cells.join("\t"), "the row");
}

// ---- panels and overlays ---------------------------------------------------------------

export function openTab(tab: Tab): void {
  const { panel } = get();
  set({ panel: { open: !(panel.open && panel.tab === tab), tab } });
}

export function togglePanel(): void {
  const { panel } = get();
  set({ panel: { ...panel, open: !panel.open } });
}

export function showColumn(column: number): void {
  set({ column, panel: { open: true, tab: "column" } });
}

/** Rows that came below have been seen: the list was scrolled to its end. */
export function seen(): void {
  if (get().unseen > 0) set({ unseen: 0 });
}
