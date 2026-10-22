// Runs the built program the way cron would: in a session of its own, with no controlling
// terminal, so that a test run from a terminal that shows pencere views opens none in it.

import { spawn } from "node:child_process";

export const MAIN = new URL("../dist/node/server/main.js", import.meta.url).pathname;

export interface Ran {
  out: string;
  err: string;
  status: number | null;
}

export function run(args: string[], input = ""): Promise<Ran> {
  return new Promise((resolve, reject) => {
    // `detached` is setsid(2): the child has no controlling terminal and cannot open /dev/tty.
    const child = spawn(process.execPath, [MAIN, ...args], {
      detached: true,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    child.stdout.setEncoding("utf8").on("data", (d: string) => (out += d));
    child.stderr.setEncoding("utf8").on("data", (d: string) => (err += d));
    const timer = setTimeout(() => child.kill("SIGKILL"), 20_000);
    child.on("error", reject);
    child.on("close", (status) => {
      clearTimeout(timer);
      resolve({ out, err, status });
    });
    child.stdin.on("error", () => {});
    child.stdin.end(input);
  });
}
