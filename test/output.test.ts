// What goes out on stdout for the rows chosen, in each shape, and the command line the view
// shows for doing it again.

import assert from "node:assert/strict";
import { test } from "node:test";

import { commandLine, shellQuote } from "../src/shared/command.ts";
import { Reader } from "../src/server/input.ts";
import type { Format, InputRecord } from "../src/server/input.ts";
import { head, one, partOf, problemOf, render, streams } from "../src/server/output.ts";
import type { Shape, Source } from "../src/server/output.ts";
import { commandFor } from "../src/server/preview.ts";

function table(text: string, format?: Format): { records: InputRecord[]; source: Source } {
  const records: InputRecord[] = [];
  const source = {
    format: undefined as Format | undefined,
    names: [] as string[],
    heading: undefined as string | undefined,
  };
  const reader = new Reader(
    {
      columns(names, heading) {
        source.names = names;
        if (heading !== undefined) source.heading = heading;
      },
      record: (r) => records.push(r),
      problem() {},
    },
    format,
  );
  reader.feed(text);
  reader.end();
  source.format = reader.format;
  return { records, source };
}

const CSV = table('name,note\nann,"a, b"\nbob,plain\n');
const PODS = table("NAME     STATUS\nweb-1    Running\nweb-2    Error\n");
const JSONL = table('{"a":1,"b":"x"}\n{"a":2}\n');
const LINES = table("a1b2c3d Fix the thing\n9f8e7d6 Add more\n");
const input: Shape = { kind: "input" };

test("in the input's shape, a row goes out as the text it was read from", () => {
  assert.equal(render(CSV.records, input, CSV.source), 'name,note\nann,"a, b"\nbob,plain\n');
  // A table's heading stays behind, so that what reads the rows is given only rows.
  assert.equal(render(PODS.records.slice(1), input, PODS.source), "web-2    Error\n");
  assert.equal(render(JSONL.records, input, JSONL.source), '{"a":1,"b":"x"}\n{"a":2}\n');
  const json = table('[{"a":1},{"a":2},{"a":3}]');
  assert.equal(
    render([json.records[2]!, json.records[0]!], input, json.source),
    '[\n  {"a":3},\n  {"a":1}\n]\n',
  );
  assert.deepEqual(JSON.parse(render(json.records, input, json.source)), [
    { a: 1 },
    { a: 2 },
    { a: 3 },
  ]);
});

test("nothing chosen writes nothing at all", () => {
  for (const shape of [
    input,
    { kind: "as", format: "json" },
    { kind: "fields", names: ["note"] },
  ] as Shape[]) {
    assert.equal(render([], shape, CSV.source), "");
  }
});

test("--field writes columns tab-separated; a number is a column's place, or a line's word", () => {
  assert.equal(
    render(CSV.records, { kind: "fields", names: ["note", "name"] }, CSV.source),
    "a, b\tann\nplain\tbob\n",
  );
  assert.equal(render(CSV.records, { kind: "fields", names: ["2"] }, CSV.source), "a, b\nplain\n");
  assert.equal(
    render(LINES.records, { kind: "fields", names: ["1"] }, LINES.source),
    "a1b2c3d\n9f8e7d6\n",
  );
  assert.equal(partOf(LINES.records[0]!, "4", LINES.source), "thing");
  assert.equal(partOf(LINES.records[0]!, "", LINES.source), "a1b2c3d Fix the thing");
});

test("--format fills a template; --output converts", () => {
  assert.equal(
    render(
      PODS.records,
      { kind: "template", template: "kubectl delete pod {NAME} # {2}" },
      PODS.source,
    ),
    "kubectl delete pod web-1 # Running\nkubectl delete pod web-2 # Error\n",
  );
  assert.equal(
    render(CSV.records, { kind: "as", format: "tsv" }, CSV.source),
    "name\tnote\nann\ta, b\nbob\tplain\n",
  );
  assert.equal(
    render(PODS.records, { kind: "as", format: "csv" }, PODS.source),
    "NAME,STATUS\nweb-1,Running\nweb-2,Error\n",
  );
  assert.deepEqual(JSON.parse(render(PODS.records, { kind: "as", format: "json" }, PODS.source)), [
    { NAME: "web-1", STATUS: "Running" },
    { NAME: "web-2", STATUS: "Error" },
  ]);
  // JSON keeps the values it was given, not their text.
  assert.equal(
    render(JSONL.records, { kind: "as", format: "jsonl" }, JSONL.source),
    '{"a":1,"b":"x"}\n{"a":2}\n',
  );
});

test("a shape that names no column is refused before anything is written", () => {
  assert.equal(
    problemOf({ kind: "fields", names: ["NAME", "nope"] }, PODS.source.names),
    'There is no column named "nope"',
  );
  assert.equal(
    problemOf({ kind: "template", template: "{NAME} {wat}" }, PODS.source.names),
    'There is no column named "wat"',
  );
  assert.equal(
    problemOf({ kind: "template", template: "{} {2} {name}" }, PODS.source.names),
    undefined,
  );
});

test("rows written one by one come to what rendering them all at once writes", () => {
  for (const [t, shape] of [
    [CSV, input],
    [CSV, { kind: "as", format: "csv" }],
    [PODS, { kind: "as", format: "tsv" }],
    [PODS, { kind: "fields", names: ["NAME"] }],
    [JSONL, input],
  ] as [typeof CSV, Shape][]) {
    assert.ok(streams(shape, t.source.format));
    const piecewise =
      head(shape, t.source) + t.records.map((r) => one(r, shape, t.source)).join("");
    assert.equal(piecewise, render(t.records, shape, t.source));
  }
  assert.ok(!streams({ kind: "as", format: "json" }, "csv"));
});

test("a preview command is given the row's values quoted for the shell", () => {
  const record = { cells: ["it's", "x"], raw: "it's x; rm -rf /" };
  const source = { names: ["a", "b"], format: "csv" as Format };
  assert.equal(
    commandFor("echo {} {a} {2} {zzz}", record, source),
    `echo 'it'\\''s x; rm -rf /' 'it'\\''s' x {zzz}`,
  );
});

test("the command line quotes what the shell would split", () => {
  assert.equal(shellQuote("NAME"), "NAME");
  assert.equal(shellQuote("STATUS!=Running"), "'STATUS!=Running'");
  assert.equal(shellQuote("it's"), `'it'\\''s'`);
  assert.equal(shellQuote(""), "''");
  assert.equal(
    commandLine({
      where: "STATUS!=Running cpu>50",
      sort: { column: "%CPU", descending: true },
      field: ["NAME", "PID"],
    }),
    "pickpen --where 'STATUS!=Running cpu>50' --sort -%CPU --field NAME,PID",
  );
  assert.equal(
    commandLine({ input: "lines", where: "", output: "json" }),
    "pickpen --input lines --where '' --output json",
  );
});
