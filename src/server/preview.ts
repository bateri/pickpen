/**
 * `--preview`: the command run for the row the cursor is on, on the program's machine,
 * with what it prints shown beside the rows.
 *
 * Every process of a pipeline shares the pane's terminal, and the host's answers to the
 * program arrive on it, the token that opens views among them (pencere §13). So the command
 * runs in a session of its own, with no controlling terminal (`detached` is `setsid`), and
 * stdin from nowhere: it can neither read the terminal's input nor open `/dev/tty`.
 */

import { spawn } from "node:child_process";

import { shellQuote } from "../shared/command.ts";
import type { PreviewResult } from "../shared/wire.ts";
import type { InputRecord } from "./input.ts";
import { partOf } from "./output.ts";
import type { Source } from "./output.ts";

/** What the view is shown of a preview at most: more is cut, and the view says so. */
const MAX_OUTPUT = 256 * 1024;
const TIMEOUT_MS = 10_000;

/** The command with the row's values in place of `{}`, `{COLUMN}` and `{2}`, each quoted for sh. */
export function commandFor(
  template: string,
  record: InputRecord,
  source: Pick<Source, "names" | "format">,
): string {
  return template.replace(/\{([^{}]*)\}/g, (whole, name: string) => {
    const part = partOf(record, name, source);
    return part === undefined ? whole : shellQuote(part);
  });
}

export function runPreview(
  command: string,
  width: number,
  signal: AbortSignal,
): Promise<PreviewResult> {
  return new Promise((resolve) => {
    const child = spawn("/bin/sh", ["-c", command], {
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, COLUMNS: String(width), LINES: "200", PICKPEN_PREVIEW: "1" },
    });
    const chunks: Buffer[] = [];
    let size = 0;
    let cut = false;
    let timedOut = false;
    const kill = () => {
      try {
        // The command's whole group: a shell's children, a pager it started.
        if (child.pid !== undefined) process.kill(-child.pid, "SIGKILL");
      } catch {
        // Already gone.
      }
    };
    const take = (chunk: Buffer) => {
      if (size >= MAX_OUTPUT) {
        cut = true;
        return;
      }
      chunks.push(chunk.subarray(0, MAX_OUTPUT - size));
      size += chunk.length;
      if (size > MAX_OUTPUT) cut = true;
    };
    child.stdout.on("data", take);
    child.stderr.on("data", take);
    const timer = setTimeout(() => {
      timedOut = true;
      kill();
    }, TIMEOUT_MS);
    const abort = () => kill();
    signal.addEventListener("abort", abort, { once: true });
    child.on("error", (error) => {
      chunks.push(Buffer.from(String(error.message)));
    });
    child.on("close", (status) => {
      clearTimeout(timer);
      signal.removeEventListener("abort", abort);
      resolve({ text: Buffer.concat(chunks).toString("utf8"), status, cut, timedOut });
    });
  });
}
