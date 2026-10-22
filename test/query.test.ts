// The query and the quantities it compares: what a person types chooses the rows they mean, in
// the view and with --where alike, since both run this code.

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  compareOrdered,
  matches,
  parse,
  rowOf,
  sortKey,
  unknownNames,
  withTerm,
} from "../src/shared/query.ts";
import { columnKind, quantity, writeQuantity } from "../src/shared/values.ts";

const COLUMNS = ["NAME", "STATUS", "%CPU", "SIZE", "AGE", "CONTAINER ID", "STARTED"];
const row = (...cells: string[]) => rowOf(cells);
const keep = (query: string, rows: ReturnType<typeof row>[]) =>
  rows.filter((r) => matches(parse(query, COLUMNS), r)).map((r) => r.cells[0]);

const ROWS = [
  row("web-1", "Running", "12.5", "1.2G", "3d4h", "a1b2", "2026-10-20"),
  row("web-2", "CrashLoopBackOff", "0.0", "512Mi", "47m", "c3d4", "2026-10-22T08:00:00Z"),
  row("db-1", "Running", "88", "40GiB", "45s", "e5f6", "2026-09-01"),
  row("cache", "Pending", "", "10MB", "2m", "Up 2 hours", ""),
];

test("a quantity is read from what a cell says", () => {
  assert.deepEqual(quantity("12"), { kind: "number", value: 12 });
  assert.deepEqual(quantity("12.5%"), { kind: "number", value: 12.5 });
  assert.deepEqual(quantity("1.5G"), { kind: "size", value: 1.5 * 1024 ** 3 });
  assert.deepEqual(quantity("512Ki"), { kind: "size", value: 512 * 1024 });
  assert.deepEqual(quantity("3.4 MB"), { kind: "size", value: 3.4e6 });
  assert.deepEqual(quantity("10k"), { kind: "size", value: 10240 });
  assert.deepEqual(quantity("3m"), { kind: "duration", value: 180 });
  assert.deepEqual(quantity("5d2h"), { kind: "duration", value: 5 * 86400 + 7200 });
  assert.deepEqual(quantity("500ms"), { kind: "duration", value: 0.5 });
  assert.deepEqual(quantity("1:02:03"), { kind: "duration", value: 3723 });
  assert.equal(quantity("2026-10-22")?.kind, "date");
  assert.equal(quantity("2026-10-22T10:00:00Z")?.value, Date.parse("2026-10-22T10:00:00Z"));
  for (const words of ["Running", "1.2.3", "v2", "", "a1b2", "-", "12 apples"]) {
    assert.equal(quantity(words), undefined, words);
  }
});

test("a column's kind is what most of its cells are", () => {
  assert.equal(columnKind(["1", "2", "3", "4", "x"]), "number");
  assert.equal(columnKind(["1", "2", "x", "y"]), "text");
  assert.equal(columnKind(["1G", "0", "300M", "2G", "5G"]), "size");
  assert.equal(columnKind(["Running", "Pending", "3"]), "text");
  assert.equal(columnKind([]), "text");
});

test("a quantity is written back as a query reads it", () => {
  assert.equal(writeQuantity("size", 1.5 * 1024 ** 3), "1.5Gi");
  assert.equal(writeQuantity("duration", 5400), "1.5h");
  assert.equal(writeQuantity("number", 1234.567), "1230");
  for (const [kind, value] of [
    ["size", 3 * 1024 ** 2],
    ["duration", 90],
    ["number", 0.25],
  ] as const) {
    assert.equal(quantity(writeQuantity(kind, value))?.value, value);
  }
});

test("words are looked for in every column, in any case; !word leaves rows out", () => {
  assert.deepEqual(keep("web", ROWS), ["web-1", "web-2"]);
  assert.deepEqual(keep("RUNNING", ROWS), ["web-1", "db-1"]);
  assert.deepEqual(keep("!running", ROWS), ["web-2", "cache"]);
  assert.deepEqual(keep("web running", ROWS), ["web-1"]);
  assert.deepEqual(keep('"up 2"', ROWS), ["cache"]);
  assert.deepEqual(keep("", ROWS), ["web-1", "web-2", "db-1", "cache"]);
});

test("a column is compared by its heading, or by its letters alone", () => {
  assert.deepEqual(keep("status=running", ROWS), ["web-1", "db-1"]);
  assert.deepEqual(keep("STATUS=Running|Pending", ROWS), ["web-1", "db-1", "cache"]);
  assert.deepEqual(keep("STATUS!=Running", ROWS), ["web-2", "cache"]);
  assert.deepEqual(keep("name~WEB", ROWS), ["web-1", "web-2"]);
  assert.deepEqual(keep("name!~web", ROWS), ["db-1", "cache"]);
  assert.deepEqual(keep("cpu>50", ROWS), ["db-1"]);
  assert.deepEqual(keep('"container id"~up', ROWS), ["cache"]);
  assert.deepEqual(keep("containerid=e5f6", ROWS), ["db-1"]);
});

test("quantities compare as quantities, and an empty cell is never above or below", () => {
  assert.deepEqual(keep("%cpu<=12.5", ROWS), ["web-1", "web-2"]);
  assert.deepEqual(keep("size>1G", ROWS), ["web-1", "db-1"]);
  assert.deepEqual(keep("size=1.2G", ROWS), ["web-1"]);
  assert.deepEqual(keep("age<1h", ROWS), ["web-2", "db-1", "cache"]);
  assert.deepEqual(keep("age=1m..1h", ROWS), ["web-2", "cache"]);
  assert.deepEqual(keep("started>2026-10-01", ROWS), ["web-1", "web-2"]);
  // A bare number is read in the column's unit: a thousand bytes.
  assert.deepEqual(keep("size<20000000", ROWS), ["cache"]);
  // A value that is no quantity compares as text.
  assert.deepEqual(keep("name>e", ROWS), ["web-1", "web-2"]);
});

test("a name that is no column's makes the term a word, and is told", () => {
  const lines = ["line"];
  const r = rowOf(["GET /a user=bob 200"]);
  assert.ok(matches(parse("user=bob", lines), r));
  assert.ok(!matches(parse("user=alice", lines), r));
  assert.deepEqual(unknownNames("user=bob line~GET size>1", lines), ["user", "size"]);
  assert.deepEqual(unknownNames("STATUS=x !foo", COLUMNS), []);
});

test("cells sort as quantities before words, empty cells last either way", () => {
  const cells = ["10", "9", "", "b", "1.5G", "A", "2"];
  const up = [...cells].sort((a, b) => compareOrdered(sortKey(a), sortKey(b), false));
  const down = [...cells].sort((a, b) => compareOrdered(sortKey(a), sortKey(b), true));
  assert.deepEqual(up, ["2", "9", "10", "1.5G", "A", "b", ""]);
  assert.deepEqual(down, ["b", "A", "1.5G", "10", "9", "2", ""]);
  const before = (a: string, b: string) => compareOrdered(sortKey(a), sortKey(b), false) < 0;
  assert.ok(before("file9", "file10"));
  assert.ok(before("512Mi", "1G"));
});

test("a click writes its term into the query, in place of the column's own", () => {
  assert.equal(withTerm("web STATUS=Running", COLUMNS, 1, "STATUS=Pending"), "web STATUS=Pending");
  assert.equal(withTerm("web", COLUMNS, 1, "STATUS=Pending"), "web STATUS=Pending");
  assert.equal(withTerm("STATUS=a web status!=b", COLUMNS, 1, undefined), "web");
  assert.equal(withTerm("", COLUMNS, 2, "%CPU=1..5"), "%CPU=1..5");
});
