// The server the view talks to, over an in-memory MCP connection: rows as they come, the
// picture of what will go out, which must be what goes out, and the answers.

import { Client } from "@modelcontextprotocol/client";
import { InMemoryTransport } from "@modelcontextprotocol/server";
import assert from "node:assert/strict";
import { test } from "node:test";

import { parse } from "../src/server/args.ts";
import { Reader } from "../src/server/input.ts";
import { render } from "../src/server/output.ts";
import type { Shape } from "../src/server/output.ts";
import { Picker } from "../src/server/picker.ts";
import { createServer } from "../src/server/tools.ts";
import type { Batch, Shown } from "../src/shared/wire.ts";

async function start(argv: string[]) {
  const parsed = parse(argv);
  assert.equal(parsed.kind, "run");
  const options = (parsed as Extract<typeof parsed, { kind: "run" }>).options;
  const picker = new Picker();
  const reader = new Reader(
    {
      columns(names, heading) {
        picker.format = reader.format;
        picker.columns(names, heading);
      },
      record: (r) => picker.record(r),
      problem: (t) => picker.problem(t),
    },
    options.input,
  );
  const answers: ({ rows: number[]; shape: Shape } | "cancelled")[] = [];
  const server = createServer(picker, options, {
    chosen: (rows, shape) => answers.push({ rows, shape }),
    cancelled: () => answers.push("cancelled"),
  });
  const client = new Client({ name: "test", version: "0.0.0" });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  await client.connect(b);
  const call = async <T>(name: string, args: Record<string, unknown> = {}) => {
    const result = (await client.callTool({ name, arguments: args })) as {
      isError?: boolean;
      structuredContent?: unknown;
      content?: { text?: string }[];
    };
    return {
      error: result.isError ? result.content?.[0]?.text : undefined,
      data: result.structuredContent as T,
    };
  };
  return { picker, reader, answers, call, client, options };
}

test("the view is told the command line, and the rows so far", async () => {
  const t = await start([
    "--where",
    "STATUS!=Running",
    "--confirm",
    "--title",
    "Delete?",
    "--field",
    "NAME",
  ]);
  t.reader.feed("NAME   STATUS\nweb-1  Running\nweb-2  Error\n");
  const { data } = await t.call<Shown>("show_picker");
  assert.equal(data.boot.title, "Delete?");
  assert.equal(data.boot.where, "STATUS!=Running");
  assert.equal(data.boot.confirm, true);
  assert.deepEqual(data.boot.given, { field: ["NAME"] });
  // The shape is not settled until the input says more, or a moment passes.
  t.reader.decide();
  const more = await t.call<Batch>("pickpen_rows", { since: 0 });
  assert.deepEqual(more.data.columns, ["NAME", "STATUS"]);
  assert.deepEqual(more.data.rows, [
    ["web-1", "Running"],
    ["web-2", "Error"],
  ]);
  assert.equal(more.data.format, "columns");
});

test("a call for rows waits for them, and answers when they come", async () => {
  const t = await start([]);
  t.reader.feed("one\n");
  t.reader.decide();
  const first = await t.call<Batch>("pickpen_rows", { since: 0 });
  assert.equal(first.data.total, 1);
  const waiting = t.call<Batch>("pickpen_rows", { since: 1 });
  setTimeout(() => t.reader.feed("two\nthree\n"), 50);
  const next = await waiting;
  assert.equal(next.data.from, 1);
  assert.deepEqual(next.data.rows, [["two"], ["three"]]);
  assert.equal(next.data.done, false);
  t.reader.end();
  t.picker.finish();
  const last = await t.call<Batch>("pickpen_rows", { since: 3 });
  assert.equal(last.data.done, true);
  assert.deepEqual(last.data.rows, []);
});

test("what the view shows will go out is what goes out", async () => {
  const t = await start(["--format", "{NAME}={2}"]);
  t.reader.feed("NAME   STATUS\nweb-1  Running\nweb-2  Error\ndb     Running\n");
  t.reader.end();
  const rows = [2, 0];
  const shown = await t.call<{ text: string }>("pickpen_output", { rows });
  assert.equal(shown.data.text, "db=Running\nweb-1=Running\n");
  await t.call("pickpen_choose", { rows });
  const answer = t.answers[0];
  assert.ok(answer && answer !== "cancelled");
  assert.equal(
    render(
      answer.rows.map((at) => t.picker.rows[at]!),
      answer.shape,
      t.picker,
    ),
    shown.data.text,
  );
});

test("columns picked in the view shape what goes out, over the command line's", async () => {
  const t = await start(["--field", "NAME"]);
  t.reader.feed("NAME   STATUS\nweb-1  Running\n");
  t.reader.end();
  const own = await t.call<{ text: string }>("pickpen_output", { rows: [0] });
  assert.equal(own.data.text, "web-1\n");
  const picked = await t.call<{ text: string }>("pickpen_output", {
    rows: [0],
    fields: ["STATUS", "NAME"],
  });
  assert.equal(picked.data.text, "Running\tweb-1\n");
});

test("a choice names rows that are there, each once; nothing chosen is refused", async () => {
  const t = await start([]);
  t.reader.feed("a\nb\n");
  t.reader.end();
  const none = await t.call("pickpen_choose", { rows: [9, -1] });
  assert.equal(none.error, "No row was chosen");
  await t.call("pickpen_choose", { rows: [1, 1, 7, 0] });
  assert.deepEqual(t.answers, [{ rows: [1, 0], shape: { kind: "input" } }]);
});

test("a shape that names no column is refused when the view sends", async () => {
  const t = await start(["--field", "nope"]);
  t.reader.feed("a,b\n1,2\n");
  t.reader.end();
  const sent = await t.call("pickpen_choose", { rows: [0] });
  assert.equal(sent.error, 'There is no column named "nope"');
  assert.deepEqual(t.answers, []);
});

test("Send nothing is an answer too", async () => {
  const t = await start([]);
  await t.call("pickpen_cancel");
  assert.deepEqual(t.answers, ["cancelled"]);
});

test("only the view's tool is offered as more than the view's", async () => {
  const t = await start(["--preview", "echo {}"]);
  const { tools } = await t.client.listTools();
  const visible = tools.filter((tool) => {
    const ui = (tool._meta as { ui?: { visibility?: string[] } } | undefined)?.ui;
    return !ui?.visibility || ui.visibility.includes("model");
  });
  assert.deepEqual(
    visible.map((tool) => tool.name),
    ["show_picker"],
  );
  assert.ok(tools.some((tool) => tool.name === "pickpen_preview"));
  const plain = await (await start([])).client.listTools();
  assert.ok(!plain.tools.some((tool) => tool.name === "pickpen_preview"));
});

test("a preview runs with no terminal and no stdin, and is cut when it prints too much", async () => {
  const t = await start([
    "--preview",
    "printf '%s|' {} {2}; tty || true; cat; yes | head -c 400000",
  ]);
  t.reader.feed("a,b\nx y,z\n");
  t.reader.end();
  const { data } = await t.call<{ text: string; status: number; cut: boolean }>("pickpen_preview", {
    row: 0,
    width: 80,
  });
  assert.match(data.text, /^x y,z\|z\|not a tty\n/);
  assert.equal(data.cut, true);
  assert.equal(data.text.length, 256 * 1024);
});
