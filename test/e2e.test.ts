// pickpen in a pipeline in a terminal pane, with pencere's stand-in host (`pencere-fake-host`)
// playing the terminal and a scripted view: the view's calls travel to the program through the
// tty while stdin and stdout carry the pipeline's data. Skipped where the stand-in is not built:
// set PENCERE_FAKE_HOST, or build it in a pencere checkout beside this one
// (`cargo build -p pencere-fake-host`). Run against the built program (`npm run build`).

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, test } from "node:test";

import { MAIN, run } from "./detached.ts";

import { Reader } from "../src/server/input.ts";
import type { InputRecord } from "../src/server/input.ts";
import {
  columnNamed,
  compareOrdered,
  matches,
  parse,
  rowOf,
  sortKey,
} from "../src/shared/query.ts";

const HOST =
  process.env.PENCERE_FAKE_HOST ??
  new URL("../../pencere/target/debug/pencere-fake-host", import.meta.url).pathname;
const DEMO = new URL("../demo/", import.meta.url).pathname;
const skip = !existsSync(HOST)
  ? "pencere-fake-host is not built"
  : !existsSync(MAIN)
    ? "run npm run build first"
    : false;

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "pickpen-e2e-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const q = (text: string) => `'${text.replace(/'/g, `'\\''`)}'`;

/**
 * Runs `pipeline` in a pane, `pickpen` in it standing for the program; the view makes the
 * calls, then `then` happens. stdout of pickpen goes to `out`, its status to `status`.
 */
function pane(pipeline: string, calls: [string, unknown][], then: string[] = []) {
  const args = ["--size", "100x30", "--limit", "25"];
  for (const [name, input] of calls) args.push("--call", `${name}=${JSON.stringify(input)}`);
  const pickpen = `"${process.execPath}" "${MAIN}"`;
  const script = `${pipeline.replace("pickpen", pickpen)} > "${dir}/out" 2> "${dir}/err"; echo $? > "${dir}/status"`;
  const run = spawnSync(HOST, [...args, ...then, "--", "sh", "-c", script], {
    encoding: "utf8",
    timeout: 40_000,
  });
  const read = (name: string) =>
    existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8") : "";
  return { log: run.stderr, out: read("out"), err: read("err"), status: Number(read("status")) };
}

/** The rows of a file as pickpen reads them, for working out what a view would send. */
function rowsOf(file: string): { records: InputRecord[]; names: string[] } {
  const records: InputRecord[] = [];
  let names: string[] = [];
  const reader = new Reader({
    columns: (n) => (names = n),
    record: (r) => records.push(r),
    problem() {},
  });
  reader.feed(readFileSync(file, "utf8"));
  reader.end();
  return { records, names };
}

test("the rows chosen in the pane go out on stdout, in the order sent", { skip }, () => {
  const { out, status, log } = pane("printf 'alpha\\nbeta\\ngamma\\n' | pickpen", [
    ["pickpen_rows", { since: 0 }],
    ["pickpen_choose", { rows: [2, 0] }],
  ]);
  assert.equal(out, "gamma\nalpha\n");
  assert.equal(status, 0);
  assert.match(log, /program: dismiss/);
  assert.match(log, /alternate screen off/);
});

for (const [file, where, extra] of [
  ["pods.txt", "STATUS!=Running AGE<1h", ["--field", "NAME"]],
  ["requests.jsonl", "status>=400 ms>100 !health", ["--sort", "-ms"]],
  ["servers.csv", "role=db|cache cpu>50", ["--sort", "memory"]],
  ["ps.txt", "%cpu>2 !postgres", ["--format", "kill {PID} # {COMMAND}"]],
] as [string, string, string[]][]) {
  test(
    `--where ${q(where)} on ${file} writes what a view sending those rows writes`,
    { skip },
    async () => {
      const path = `${DEMO}${file}`;
      const headless = await run(["--where", where, ...extra, path]);
      assert.equal(headless.status, 0, headless.err);
      // The rows the view shows for the query, in its order: what Send sends when they are marked.
      const { records, names } = rowsOf(path);
      const query = parse(where, names);
      let ids = records
        .map((_, at) => at)
        .filter((at) => matches(query, rowOf(records[at]!.cells)));
      const sort = extra[0] === "--sort" ? extra[1]! : undefined;
      if (sort) {
        const descending = sort.startsWith("-");
        const column = columnNamed(names, sort.replace(/^-/, ""));
        const keys = records.map((r) => sortKey(r.cells[column] ?? ""));
        ids = ids.sort((a, b) => compareOrdered(keys[a]!, keys[b]!, descending) || a - b);
      }
      const shown = pane(`pickpen ${extra.map(q).join(" ")} ${q(path)}`, [
        ["pickpen_rows", { since: 0 }],
        ["pickpen_choose", { rows: ids }],
      ]);
      assert.equal(shown.status, 0, shown.err);
      assert.equal(shown.out, headless.out);
    },
  );
}

test("Send nothing writes nothing and ends with 1", { skip }, () => {
  const { out, status, err } = pane("printf 'a\\nb\\n' | pickpen", [["pickpen_cancel", {}]]);
  assert.equal(out, "");
  assert.equal(status, 1);
  assert.match(err, /nothing was chosen/);
});

test("⌃C ends it as a signal does, with the terminal given back", { skip }, () => {
  const { out, status, log } = pane(
    "printf 'a\\nb\\n' | pickpen",
    [["pickpen_rows", { since: 0 }]],
    ["--then", "interrupt"],
  );
  assert.equal(out, "");
  assert.equal(status, 130);
  assert.match(log, /program: bye id=\d+ reason=signal/);
  assert.match(log, /alternate screen off/);
});

test("the person closing the view sends nothing", { skip }, () => {
  const { out, status } = pane("printf 'a\\n' | pickpen", [], ["--then", "close"]);
  assert.equal(out, "");
  assert.equal(status, 1);
});

test("a view the terminal starts again finds the rows where they were", { skip }, () => {
  const { log, out, status } = pane(
    "printf 'a\\nb\\nc\\n' | pickpen",
    [["pickpen_rows", { since: 0 }]],
    ["--then", "restart"],
  );
  assert.equal((log.match(/tools\/call show_picker/g) ?? []).length, 2);
  assert.match(log, /tool-result "3 rows, 1 columns"[\s\S]*tool-result "3 rows, 1 columns"/);
  // The stand-in types ^C once the second view has made its calls.
  assert.equal(out, "");
  assert.equal(status, 130);
});

test("an input that does not end does not hold the answer up", { skip }, () => {
  const started = Date.now();
  const { out, status } = pane(
    `(printf 'one\\ntwo\\n'; sleep 5) | { pickpen; echo $? > "${dir}/own"; node -e 'console.log(Date.now())' > "${dir}/ended"; }`,
    [
      ["pickpen_rows", { since: 0 }],
      ["pickpen_choose", { rows: [1] }],
    ],
  );
  const ended = Number(readFileSync(join(dir, "ended"), "utf8"));
  assert.equal(readFileSync(join(dir, "own"), "utf8").trim(), "0");
  assert.ok(ended - started < 4500, `pickpen took ${ended - started}ms`);
  assert.equal(out, "two\n");
  assert.equal(status, 0);
});

test("--confirm in a pane: the view is told the rule, and sends what is marked", { skip }, () => {
  const { log, out, status } = pane(
    `pickpen --where 'STATUS!=Running' --confirm --field NAME ${q(`${DEMO}pods.txt`)}`,
    [["pickpen_choose", { rows: [1] }]],
  );
  assert.match(log, /tool-result "\d+ rows, 5 columns"/);
  assert.equal(out, `${rowsOf(`${DEMO}pods.txt`).records[1]!.cells[0]}\n`);
  assert.equal(status, 0);
});

test("a terminal that shows no views: a person was needed, 2", { skip }, () => {
  const args = [
    "--no-host",
    "--limit",
    "10",
    "--",
    "sh",
    "-c",
    `printf 'a\\n' | "${process.execPath}" "${MAIN}" > "${dir}/out" 2> "${dir}/err"; echo $? > "${dir}/status"`,
  ];
  spawnSync(HOST, args, { encoding: "utf8", timeout: 30_000 });
  assert.equal(readFileSync(join(dir, "status"), "utf8").trim(), "2");
  assert.equal(readFileSync(join(dir, "out"), "utf8"), "");
});
