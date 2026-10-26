// The Lua tests: the page against the kit's page API, with a stand-in for its program. They run in
// pencere's Lua runner (the Lua there is), packed into a program of their own: test/lua/main.lua is
// its entry. The page is held to the kit by loading the kit's own
// prelude (PENCERE_PRELUDE, a pencere checkout's kit/luau/prelude), the Lua a terminal gives a page.
//
// Nothing here is skipped: a runner or a prelude that is not there fails the run and says which.

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";

const PENCERE = process.env.PENCERE
  ? resolve(process.env.PENCERE)
  : new URL("../../pencere/target/release/pencere", import.meta.url).pathname;
const PRELUDE = process.env.PENCERE_PRELUDE
  ? resolve(process.env.PENCERE_PRELUDE)
  : new URL("../../pencere/kit/luau/prelude", import.meta.url).pathname;
const TESTS = new URL("./lua", import.meta.url).pathname;
const PAGE = new URL("../src/view/page.lua", import.meta.url).pathname;

if (!existsSync(PENCERE)) {
  throw new Error(`the Lua tests cannot run: the pencere command is not at ${PENCERE} (PENCERE=<it>)`);
}
if (!existsSync(join(PRELUDE, "40-page.lua"))) {
  throw new Error(`the Lua tests cannot run: the kit's prelude is not at ${PRELUDE} (PENCERE_PRELUDE=<it>)`);
}

// The tests' program: their files, with their entry as its app.lua.
const dir = mkdtempSync(join(tmpdir(), "pickpen-lua-"));
for (const name of readdirSync(TESTS)) {
  cpSync(join(TESTS, name), join(dir, name === "main.lua" ? "app.lua" : name));
}
const built = spawnSync(PENCERE, ["build", dir, "--name", "pickpen-tests", "-o", join(dir, "tests")], {
  encoding: "utf8",
});
assert.equal(built.status, 0, `pencere build: ${built.stderr}${built.stdout}`);
const run = spawnSync(join(dir, "tests"), [], {
  encoding: "utf8",
  env: { ...process.env, PENCERE_PRELUDE: PRELUDE, PICKPEN_PAGE: PAGE },
  timeout: 120_000,
});
rmSync(dir, { recursive: true, force: true });

// The tests as TAP, a test of this file's for each, so that a failure says which.
const results = [];
let last;
for (const line of run.stdout.split("\n")) {
  const match = /^(ok|not ok) \d+ - (.*)$/.exec(line);
  if (match) {
    last = { ok: match[1] === "ok", name: match[2], notes: [] };
    results.push(last);
  } else if (line.startsWith("# ") && last) {
    last.notes.push(line.slice(2));
  }
}

test("the Lua tests ran", () => {
  assert.ok(results.length > 0, `no test ran: ${run.stdout}\n${run.stderr}`);
});

for (const result of results) {
  test(result.name, () => {
    assert.ok(result.ok, result.notes.join("\n"));
  });
}
