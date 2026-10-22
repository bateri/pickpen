/**
 * What the program holds of the input while the view is open: the rows read so far, the
 * columns, whether the input has ended, and the view's calls waiting for more.
 */

import type { Batch } from "../shared/wire.ts";
import type { Format, InputRecord, Sink } from "./input.ts";

/**
 * The most rows a view is given. Reading stops there, and the view says so: the rows go
 * across the terminal's stream, and a person does not look through more.
 */
export const MAX_ROWS = 200_000;

/** The longest cell a view is given; a longer one is cut, and the view says some were. */
export const MAX_CELL = 16_384;

/** How much of the stream one answer of `pickpen_rows` takes, as the stream counts it. */
const MAX_BATCH = 1024 * 1024;

/**
 * The bytes a text takes on the terminal's stream, where every character outside ASCII is
 * written as a `\uXXXX` escape.
 */
function wireSize(text: string): number {
  let size = text.length;
  for (let at = 0; at < text.length; at++) if (text.charCodeAt(at) > 0x7e) size += 5;
  return size;
}

export class Picker implements Sink {
  names: string[] = [];
  heading: string | undefined;
  readonly rows: InputRecord[] = [];
  format: Format | undefined;
  done = false;
  capped = false;
  readonly problems: string[] = [];
  #waiters = new Set<() => void>();

  columns(names: string[], heading?: string): void {
    this.names = names;
    if (heading !== undefined) this.heading = heading;
    this.#wake();
  }

  record(record: InputRecord): void {
    if (this.capped) return;
    if (this.rows.length >= MAX_ROWS) {
      this.capped = true;
      this.#wake();
      return;
    }
    this.rows.push(record);
    this.#wake();
  }

  problem(text: string): void {
    this.problems.push(text);
    this.#wake();
  }

  finish(): void {
    this.done = true;
    this.#wake();
  }

  /** Resolves when there is something new after `since` rows, the input ends, or `ms` pass. */
  wait(since: number, ms: number, signal?: AbortSignal): Promise<void> {
    if (this.rows.length > since || this.done || this.capped) return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        this.#waiters.delete(done);
        signal?.removeEventListener("abort", done);
        resolve();
      };
      const timer = setTimeout(done, ms);
      this.#waiters.add(done);
      signal?.addEventListener("abort", done);
    });
  }

  batch(since: number): Batch {
    const rows: string[][] = [];
    let size = 0;
    let cut = false;
    for (let at = since; at < this.rows.length; at++) {
      let cells = this.rows[at]!.cells;
      if (cells.some((cell) => cell.length > MAX_CELL)) {
        cells = cells.map((cell) => (cell.length > MAX_CELL ? cell.slice(0, MAX_CELL) : cell));
        cut = true;
      }
      const cost = cells.reduce((sum, cell) => sum + wireSize(cell) + 3, 2);
      if (rows.length > 0 && size + cost > MAX_BATCH) break;
      rows.push(cells);
      size += cost;
    }
    return {
      from: since,
      rows,
      total: this.rows.length,
      columns: this.names,
      format: this.format ?? null,
      done: this.done,
      capped: this.capped,
      problems: this.problems,
      cut,
    };
  }

  #wake(): void {
    for (const waiter of [...this.#waiters]) waiter();
  }
}
