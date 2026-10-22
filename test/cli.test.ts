// The built program with nobody to ask: `--where` writes what the query matches, as grep would,
// the exit status says whether anything went out, and a person is never stood in for. Run
// against the built program (`npm run build`).

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { test } from "node:test";

import { MAIN, run } from "./detached.ts";

const DEMO = new URL("../demo/", import.meta.url).pathname;
const skip = existsSync(MAIN) ? false : "run npm run build first";

const PODS = readFileSync(`${DEMO}pods.txt`, "utf8");

test("--where writes the rows the query matches, in the input's shape", { skip }, async () => {
  const { out, status } = await run(["--where", "STATUS=Error"], PODS);
  assert.equal(status, 0);
  const lines = out.trimEnd().split("\n");
  assert.ok(lines.length > 0);
  assert.ok(lines.every((line) => /\sError\s/.test(line)));
  // The heading stays behind; the lines go out as they came.
  for (const line of lines) assert.ok(PODS.includes(`${line}\n`));
});

test("--where with --sort and --field", { skip }, async () => {
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

test("nothing matched writes nothing and ends with 1, as grep does", { skip }, async () => {
  const { out, status } = await run(["--where", "no-such-word"], PODS);
  assert.equal(out, "");
  assert.equal(status, 1);
});

test(
  "a person is needed, and there is no terminal: 2, with what to do instead",
  { skip },
  async () => {
    for (const args of [[], ["--confirm", "--where", "x"], ["--query", "web"]]) {
      const { out, err, status } = await run(args, PODS);
      assert.equal(status, 2, args.join(" "));
      assert.equal(out, "");
      assert.match(err, /needs a terminal that shows pencere views; --where QUERY alone runs/);
    }
  },
);

test("a column a term names that is not there is said", { skip }, async () => {
  const { err, status } = await run(["--where", "PORT=80"], PODS);
  assert.equal(status, 1);
  assert.match(err, /no column named "PORT": that term is looked for as a word/);
});

test("the command line is checked before anything is read", { skip }, async () => {
  assert.equal((await run(["--field", "A", "--output", "json"])).status, 64);
  assert.equal((await run(["--output", "xml"])).status, 64);
  assert.equal((await run(["--input", "yaml"])).status, 64);
  assert.equal((await run(["a", "b"])).status, 64);
  assert.equal((await run(["--where", "", "--field", "NOPE"], PODS)).status, 64);
  assert.equal((await run(["--where", "", "--sort", "NOPE"], PODS)).status, 64);
  assert.equal((await run(["--where", "", "/no/such/file"])).status, 66);
  assert.equal((await run(["--where", "x", "--input", "json"], "[1, 2")).status, 65);
  assert.match((await run(["--help"])).out, /^usage: pickpen/);
  assert.match((await run(["--version"])).out, /^pickpen \d+\.\d+\.\d+\n$/);
});

test("rows go out as they come, while the input is still being written", { skip }, async () => {
  const { spawn } = await import("node:child_process");
  const child = spawn(process.execPath, [MAIN, "--where", "error"], {
    stdio: ["pipe", "pipe", "pipe"],
    detached: true,
  });
  child.stdin.write("ok one\nerror two\n");
  const first = await new Promise<string>((resolve) =>
    child.stdout.once("data", (d) => resolve(String(d))),
  );
  assert.equal(first, "error two\n");
  child.stdin.end("error three\n");
  const status = await new Promise<number | null>((resolve) => child.on("close", resolve));
  assert.equal(status, 0);
});

test("what reads the output going away ends pickpen quietly", { skip }, async () => {
  const result = spawnSync(
    "sh",
    ["-c", `yes row | head -50000 | "${process.execPath}" "${MAIN}" --where row | head -1`],
    {
      encoding: "utf8",
      timeout: 20_000,
    },
  );
  assert.equal(result.stdout, "row\n");
  assert.equal(result.stderr, "");
});
