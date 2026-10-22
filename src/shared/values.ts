/**
 * What a cell says as a quantity: a number, a size, a length of time or a moment. The
 * query's comparisons and the sort read cells through this one function, in the view and
 * in the program alike, so that `cpu>50` and `--sort -cpu` mean the same rows wherever
 * they run. A cell is read on its own, never by the type of its column: a column whose
 * every other cell is a size does not make a stray word one.
 */

export type Kind = "number" | "size" | "duration" | "date";

export interface Quantity {
  kind: Kind;
  /** In the kind's base unit: bytes, seconds, milliseconds since 1970. */
  value: number;
}

const NUMBER = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/;
const PERCENT = /^([+-]?(?:\d+\.?\d*|\.\d+))\s?%$/;
const SIZE = /^([+-]?(?:\d+\.?\d*|\.\d+))\s?([kKmMgGtTpP]i?[bB]?|[bB])$/;
const DURATION_PART = /(\d+(?:\.\d+)?)(ms|y|w|d|h|m|s)/g;
const DURATION = /^(?:\d+(?:\.\d+)?(?:ms|y|w|d|h|m|s))+$/;
const CLOCK = /^(\d+):(\d{2})(?::(\d{2}))?(\.\d+)?$/;
const DATE = /^\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?$/;

const POWERS: Record<string, number> = { k: 1, m: 2, g: 3, t: 4, p: 5 };
const SECONDS: Record<string, number> = {
  ms: 0.001,
  s: 1,
  m: 60,
  h: 3600,
  d: 86_400,
  w: 604_800,
  y: 31_536_000,
};

/**
 * The quantity a cell holds, or undefined when it holds words.
 *
 * - `12`, `-3.5`, `1e6`, `12%` are numbers (a percentage is its number);
 * - `1.2G`, `512Ki`, `3.4 MB`, `200M`, `10k` are sizes: one letter and `iB` count in 1024s,
 *   as `ls -h`, `du -h` and Kubernetes do, and `kB`, `MB` and the rest in 1000s, as Docker does;
 * - `45s`, `3m`, `5d2h`, `500ms`, `1:02:03`, `0:01.23` are lengths of time: a small `m` is
 *   minutes and a capital `M` a size;
 * - `2026-10-22`, `2026-10-22T10:00:00Z`, `2026-10-22 10:00` are moments.
 */
export function quantity(cell: string): Quantity | undefined {
  const text = cell.trim();
  if (text === "" || text.length > 40) return undefined;
  if (NUMBER.test(text)) return { kind: "number", value: Number(text) };
  let match = PERCENT.exec(text);
  if (match) return { kind: "number", value: Number(match[1]) };
  match = SIZE.exec(text);
  if (match) {
    const unit = match[2]!;
    const letter = unit[0]!.toLowerCase();
    // `b` alone is bytes; `m` alone (no `i`, no `b`) is minutes, read below.
    if (letter === "b") return { kind: "size", value: Number(match[1]) };
    if (!(unit === "m")) {
      const binary = unit.length === 1 || unit[1] === "i";
      const base = binary ? 1024 : 1000;
      return { kind: "size", value: Number(match[1]) * base ** POWERS[letter]! };
    }
  }
  if (DURATION.test(text)) {
    let seconds = 0;
    for (const part of text.matchAll(DURATION_PART)) {
      seconds += Number(part[1]) * SECONDS[part[2]!]!;
    }
    return { kind: "duration", value: seconds };
  }
  match = CLOCK.exec(text);
  if (match) {
    const [, a, b, c, fraction] = match;
    const seconds =
      c === undefined ? Number(a) * 60 + Number(b) : Number(a) * 3600 + Number(b) * 60 + Number(c);
    return { kind: "duration", value: seconds + (fraction ? Number(fraction) : 0) };
  }
  if (DATE.test(text)) {
    const value = Date.parse(
      text.includes("T") || text.length === 10 ? text : text.replace(" ", "T"),
    );
    if (!Number.isNaN(value)) return { kind: "date", value };
  }
  return undefined;
}

/**
 * Whether two quantities can be compared: of one kind, or one a bare number, which is read
 * in the other's base unit (`size>1000` is a thousand bytes). A moment is compared only
 * with a moment.
 */
export function comparable(a: Quantity, b: Quantity): boolean {
  if (a.kind === b.kind) return true;
  if (a.kind === "date" || b.kind === "date") return false;
  return a.kind === "number" || b.kind === "number";
}

/** The kind most of a column's cells have, or `text`: what the view aligns and charts by. */
export function columnKind(cells: Iterable<string>, sample = 500): Kind | "text" {
  const counts = new Map<Kind, number>();
  let filled = 0;
  for (const cell of cells) {
    if (cell.trim() === "") continue;
    filled += 1;
    const q = quantity(cell);
    if (q) counts.set(q.kind, (counts.get(q.kind) ?? 0) + 1);
    if (filled >= sample) break;
  }
  if (filled === 0) return "text";
  let best: Kind | "text" = "text";
  let most = 0;
  for (const [kind, count] of counts) {
    if (count > most) [best, most] = [kind, count];
  }
  // Numbers read in any unit's column ("0" in a column of sizes), so they count for it.
  const numbers = best === "number" ? 0 : (counts.get("number") ?? 0);
  return (most + numbers) / filled >= 0.8 ? best : "text";
}

/** A quantity as a person writes it in a query: what the column panel puts there. */
export function writeQuantity(kind: Kind, value: number): string {
  const round = (n: number) => String(Number(n.toPrecision(3)));
  switch (kind) {
    case "number":
      return round(value);
    case "size": {
      const units = ["", "Ki", "Mi", "Gi", "Ti", "Pi"];
      let n = value;
      let at = 0;
      while (Math.abs(n) >= 1024 && at < units.length - 1) {
        n /= 1024;
        at += 1;
      }
      return at === 0 ? `${round(n)}B` : `${round(n)}${units[at]}`;
    }
    case "duration": {
      const steps: [string, number][] = [
        ["d", 86_400],
        ["h", 3600],
        ["m", 60],
        ["s", 1],
      ];
      for (const [unit, size] of steps) {
        if (Math.abs(value) >= size) return `${round(value / size)}${unit}`;
      }
      return `${Math.round(value * 1000)}ms`;
    }
    case "date": {
      const iso = new Date(value).toISOString();
      return iso.endsWith("T00:00:00.000Z") ? iso.slice(0, 10) : iso.slice(0, 19) + "Z";
    }
  }
}
