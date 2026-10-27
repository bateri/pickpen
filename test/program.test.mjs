// The built program, dist/pickpen (PICKPEN_BIN), run as it is run: with nobody to ask (`--where`
// writes what the query matches, as grep would, and the exit status says whether anything went out),
// and in a pipeline in a pane, with pencere's stand-in terminal (`pencere-fake-host`, at
// PENCERE_FAKE_HOST) playing the terminal and a scripted view: the view's calls travel to the program
// through the tty while stdin and stdout carry the pipeline's data.
//
// Nothing here is skipped: a program or a stand-in that is not there fails the run and says which.

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, test } from "node:test";

const BIN = resolve(process.env.PICKPEN_BIN ?? new URL("../dist/pickpen", import.meta.url).pathname);
const HOST = resolve(
  process.env.PENCERE_FAKE_HOST ?? new URL("../../pencere/target/debug/pencere-fake-host", import.meta.url).pathname,
);
const DEMO = new URL("../demo/", import.meta.url).pathname;

if (!existsSync(BIN)) throw new Error(`the program is not at ${BIN}: make build (PICKPEN_BIN=<it>)`);
if (!existsSync(HOST)) {
  throw new Error(`pencere-fake-host is not at ${HOST}: cargo build -p pencere-fake-host in a pencere checkout`);
}

const PODS = readFileSync(`${DEMO}pods.txt`, "utf8");

let dir;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "pickpen-test-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

const q = (text) => `'${text.replace(/'/g, `'\\''`)}'`;

/**
 * Runs the program the way cron would: in a session of its own, with no controlling terminal
 * (`detached` is setsid), so that a test run from a terminal that shows pencere views opens none.
 */
function run(args, input = "") {
  return new Promise((done, failed) => {
    const child = spawn(BIN, args, { detached: true, stdio: ["pipe", "pipe", "pipe"] });
    let out = "";
    let err = "";
    child.stdout.setEncoding("utf8").on("data", (d) => (out += d));
    child.stderr.setEncoding("utf8").on("data", (d) => (err += d));
    const timer = setTimeout(() => child.kill("SIGKILL"), 20_000);
    child.on("error", failed);
    child.on("close", (status) => {
      clearTimeout(timer);
      done({ out, err, status });
    });
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}

/**
 * Runs `pipeline` in a pane, `pickpen` in it standing for the program; the view makes the calls,
 * then `then` happens (by default nothing: the program closes its view once it has its answer).
 * stdout of pickpen goes to `out`, its status to `status`.
 */
function pane(pipeline, calls, then = []) {
  const args = ["--size", "100x30", "--limit", "25"];
  for (const [name, input] of calls) args.push("--call", `${name}=${JSON.stringify(input)}`);
  const script = `${pipeline.replace("pickpen", q(BIN))} > "${dir}/out" 2> "${dir}/err"; echo $? > "${dir}/status"`;
  // bash, which waits out a ⌃C its command handles and goes on (dash would end with it).
  const ran = spawnSync(HOST, [...args, ...then, "--", "bash", "-c", script], {
    encoding: "utf8",
    timeout: 40_000,
    env: { ...process.env, PENCERE_FAKE_GIST: "100000" },
  });
  const read = (name) => (existsSync(join(dir, name)) ? readFileSync(join(dir, name), "utf8") : "");
  return { log: ran.stderr, out: read("out"), err: read("err"), status: Number(read("status")) };
}

/** The results the view was given, in order, read from the stand-in's log. */
function results(log) {
  return [...log.matchAll(/view: <- response id=\d+ result=(.*)$/gm)].map((m) => JSON.parse(m[1]));
}

// ---- with nobody to ask -------------------------------------------------------------------------------

test("--where writes the rows the query matches, in the input's shape", async () => {
  const { out, status } = await run(["--where", "STATUS=Error"], PODS);
  assert.equal(status, 0);
  const lines = out.trimEnd().split("\n");
  assert.ok(lines.length > 0);
  assert.ok(lines.every((line) => /\sError\s/.test(line)));
  // The heading stays behind; the lines go out as they came.
  for (const line of lines) assert.ok(PODS.includes(`${line}\n`));
});

test("--where with --sort and --field", async () => {
  const { out, status } = await run([
    "--where",
    "status>=500",
    "--sort",
    "-ms",
    "--field",
    "ms,status",
    `${DEMO}requests.jsonl`,
  ]);
  assert.equal(status, 0);
  const ms = out
    .trimEnd()
    .split("\n")
    .map((line) => Number(line.split("\t")[0]));
  assert.ok(ms.length > 10);
  assert.deepEqual(
    ms,
    [...ms].sort((a, b) => b - a),
  );
});

test("nothing matched writes nothing and ends with 1, as grep does", async () => {
  const { out, status } = await run(["--where", "no-such-word"], PODS);
  assert.equal(out, "");
  assert.equal(status, 1);
});

test("a person is needed, and there is no terminal: 2, with what to do instead", async () => {
  for (const args of [[], ["--confirm", "--where", "x"], ["--query", "web"]]) {
    const { out, err, status } = await run(args, PODS);
    assert.equal(status, 2, args.join(" "));
    assert.equal(out, "");
    assert.match(err, /needs a terminal that shows pencere views; --where QUERY alone runs/);
  }
});

test("a column a term names that is not there is said", async () => {
  const { err, status } = await run(["--where", "PORT=80"], PODS);
  assert.equal(status, 1);
  assert.match(err, /no column named "PORT": that term is looked for as a word/);
});

test("the command line is checked before anything is read", async () => {
  assert.equal((await run(["--field", "A", "--output", "json"])).status, 64);
  assert.equal((await run(["--output", "xml"])).status, 64);
  assert.equal((await run(["--input", "yaml"])).status, 64);
  assert.equal((await run(["--delimiter", ":", "--input", "csv"])).status, 64);
  assert.equal((await run(["a", "b"])).status, 64);
  assert.equal((await run(["--where", "", "--field", "NOPE"], PODS)).status, 64);
  assert.equal((await run(["--where", "", "--sort", "NOPE"], PODS)).status, 64);
  assert.equal((await run(["--where", "", "/no/such/file"])).status, 66);
  assert.equal((await run(["--where", "x", "--input", "json"], "[1, 2")).status, 65);
  assert.match((await run(["--help"])).out, /^usage: pickpen/);
  assert.match((await run(["--version"])).out, /^pickpen \d+\.\d+\.\d+\n$/);
});

test("rows go out as they come, while the input is still being written", async () => {
  const child = spawn(BIN, ["--where", "error"], { stdio: ["pipe", "pipe", "pipe"], detached: true });
  child.stdin.write("ok one\nerror two\n");
  const first = await new Promise((done) => child.stdout.once("data", (d) => done(String(d))));
  assert.equal(first, "error two\n");
  child.stdin.end("error three\n");
  const status = await new Promise((done) => child.on("close", done));
  assert.equal(status, 0);
});

test("what reads the output going away ends pickpen quietly", () => {
  const result = spawnSync("sh", ["-c", `yes row | head -50000 | ${q(BIN)} --where row | head -1`], {
    encoding: "utf8",
    timeout: 20_000,
  });
  assert.equal(result.stdout, "row\n");
  assert.equal(result.stderr, "");
});

// ---- in a pane ----------------------------------------------------------------------------------------

test("the rows chosen in the pane go out on stdout, in the order sent", () => {
  const { out, status, log } = pane("printf 'alpha\\nbeta\\ngamma\\n' | pickpen", [
    ["boot", {}],
    ["choose", { ids: [2, 0] }],
  ]);
  assert.equal(out, "gamma\nalpha\n");
  assert.equal(status, 0);
  assert.match(log, /alternate screen off/);
});

test("the view is told the command line, and the rows so far", () => {
  const { log } = pane(`pickpen --query web --title Pods ${q(`${DEMO}pods.txt`)}`, [
    ["boot", {}],
    ["cancel", {}],
  ]);
  const [boot] = results(log);
  assert.equal(boot.query, "web");
  assert.equal(boot.title, "Pods");
  assert.equal(boot.confirm, false);
  assert.deepEqual(boot.summary.columns, ["NAME", "READY", "STATUS", "RESTARTS", "AGE"]);
  assert.equal(boot.summary.total, PODS.trimEnd().split("\n").length - 1);
  assert.ok(boot.summary.shown > 0 && boot.summary.shown < boot.summary.total);
  assert.equal(boot.summary.kinds[4], "duration");
  assert.match(boot.summary.placeholder, /STATUS=Running, AGE<1h/);
});

for (const [file, where, extra] of [
  ["pods.txt", "STATUS!=Running AGE<1h", ["--field", "NAME"]],
  ["pods.txt", "^web | ^worker | ^api !^running$", ["--field", "NAME"]],
  ["requests.jsonl", "status>=400 ms>100 !health", ["--sort", "-ms"]],
  ["servers.csv", "role=db|cache cpu>50", ["--sort", "memory"]],
  ["ps.txt", "%cpu>2 !postgres", ["--format", "kill {PID} # {COMMAND}"]],
]) {
  test(`--where ${q(where)} on ${file} writes what a view sending those rows writes`, async () => {
    const path = `${DEMO}${file}`;
    const headless = await run(["--where", where, ...extra, path]);
    assert.equal(headless.status, 0, headless.err);
    // The view types the query, marks every row it shows, and sends them.
    const shown = pane(`pickpen ${extra.map(q).join(" ")} ${q(path)}`, [
      ["boot", {}],
      ["query", { query: where }],
      ["mark_shown", { on: true }],
      ["choose", { marked: true }],
    ]);
    assert.equal(shown.status, 0, shown.err);
    assert.equal(shown.out, headless.out);
  });
}

test("--delimiter, --read0 and --print0: a view sending what --where matches writes what it writes", async () => {
  const grep = join(dir, "grep.txt");
  writeFileSync(grep, 'src/a.rs:12:let url = "http://x";\nsrc/b.rs:3:fn main() {\nsrc/c.rs:40:// done\n');
  const names = join(dir, "names");
  writeFileSync(names, "one file\0two\nlines\0three\0");
  for (const [path, where, extra, wanted] of [
    [grep, "2>10", ["--delimiter", ":", "--field", "1,3"], 'src/a.rs\tlet url = "http://x";\nsrc/c.rs\t// done\n'],
    [names, "!three", ["--read0", "--print0"], "one file\0two\nlines\0"],
  ]) {
    const headless = await run(["--where", where, ...extra, path]);
    assert.equal(headless.status, 0, headless.err);
    assert.equal(headless.out, wanted);
    const shown = pane(`pickpen ${extra.map(q).join(" ")} ${q(path)}`, [
      ["boot", {}],
      ["query", { query: where }],
      ["mark_shown", { on: true }],
      ["choose", { marked: true }],
    ]);
    assert.equal(shown.status, 0, shown.err);
    assert.equal(shown.out, headless.out);
  }
  const { log } = pane(`pickpen -d : --print0 ${q(grep)}`, [
    ["boot", {}],
    ["query", { query: "2>10" }],
    ["mark_shown", { on: true }],
    ["output", {}],
    ["cancel", {}],
  ]);
  assert.equal(results(log).at(-2).again.line, "pickpen --delimiter : --where '2>10' --print0");
});

test("the output panel shows what goes out, and the command line that does it again", () => {
  const { log } = pane(`pickpen --field NAME ${q(`${DEMO}pods.txt`)}`, [
    ["boot", {}],
    ["query", { query: "STATUS=Error" }],
    ["mark_shown", { on: true }],
    ["output", {}],
    ["cancel", {}],
  ]);
  const output = results(log).at(-2);
  assert.equal(output.again.kind, "same");
  assert.equal(output.again.line, "pickpen --where STATUS=Error --field NAME");
  assert.equal(output.text.split("\n").length - 1, output.count);
});

test("a row's place among those shown comes back as the cursor's, after the order changed", () => {
  const { log } = pane("printf 'b\\nc\\na\\n' | pickpen", [
    ["boot", {}],
    ["order", { column: 0, descending: false }],
    ["window", { from: 0, count: 10, cursor: 0 }],
    ["cancel", {}],
  ]);
  const window = results(log).at(-2);
  assert.deepEqual(
    window.rows.map((r) => r.cells[0]),
    ["a", "b", "c"],
  );
  assert.equal(window.cursor_index, 1);
});

test("a preview runs with no terminal and no stdin", () => {
  const { log } = pane(`printf 'one\\n' | pickpen --preview 'echo {}; tty; cat'`, [
    ["boot", {}],
    ["preview", { id: 0, width: 40 }],
    ["cancel", {}],
  ]);
  const preview = results(log).at(-2);
  assert.match(preview.text, /^one\nnot a tty\n/);
  assert.equal(preview.status, 0);
});

test("Send nothing writes nothing and ends with 1", () => {
  const { out, status, err } = pane("printf 'a\\nb\\n' | pickpen", [
    ["boot", {}],
    ["cancel", {}],
  ]);
  assert.equal(out, "");
  assert.equal(status, 1);
  assert.match(err, /nothing was chosen/);
});

test("⌃C ends it as a signal does, with the terminal given back", () => {
  const { out, status, log } = pane("printf 'a\\nb\\n' | pickpen", [["boot", {}]], ["--then", "interrupt"]);
  assert.equal(out, "");
  assert.equal(status, 130);
  assert.match(log, /program: bye id=\d+ reason=signal/);
  assert.match(log, /alternate screen off/);
});

test("the person closing the view sends nothing", () => {
  const { out, status } = pane("printf 'a\\n' | pickpen", [], ["--then", "close"]);
  assert.equal(out, "");
  assert.equal(status, 1);
});

test("an input that does not end does not hold the answer up", () => {
  const started = Date.now();
  const { out, status } = pane(
    `(printf 'one\\ntwo\\n'; sleep 5) | { pickpen; echo $? > "${dir}/own"; date +%s > "${dir}/ended"; }`,
    [
      ["boot", {}],
      ["choose", { ids: [1] }],
    ],
  );
  const ended = Number(readFileSync(join(dir, "ended"), "utf8")) * 1000;
  assert.equal(readFileSync(join(dir, "own"), "utf8").trim(), "0");
  assert.ok(ended - started < 5000, `pickpen took ${ended - started}ms`);
  assert.equal(out, "two\n");
  assert.equal(status, 0);
});

test("--confirm in a pane: the rule marks the rows, and what is marked is sent", async () => {
  const path = `${DEMO}pods.txt`;
  const headless = await run(["--where", "STATUS!=Running", "--field", "NAME", path]);
  const { log, out, status } = pane(`pickpen --where 'STATUS!=Running' --confirm --field NAME ${q(path)}`, [
    ["boot", {}],
    ["choose", { marked: true }],
  ]);
  const [boot] = results(log);
  assert.equal(boot.confirm, true);
  assert.equal(boot.summary.marked, headless.out.trimEnd().split("\n").length);
  assert.equal(out, headless.out);
  assert.equal(status, 0);
});

test("a terminal that shows no views: a person was needed, 2", () => {
  const args = [
    "--no-host",
    "--limit",
    "10",
    "--",
    "sh",
    "-c",
    `printf 'a\\n' | ${q(BIN)} > "${dir}/out" 2> "${dir}/err"; echo $? > "${dir}/status"`,
  ];
  spawnSync(HOST, args, { encoding: "utf8", timeout: 30_000 });
  assert.equal(readFileSync(join(dir, "status"), "utf8").trim(), "2");
  assert.equal(readFileSync(join(dir, "out"), "utf8"), "");
});
