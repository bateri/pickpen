/**
 * The MCP server the view talks to: `show_picker`, the tool the view is of, and the tools
 * only the view calls (`visibility: ["app"]`): more rows as they come, the picture of what
 * will go out, the preview of a row, and the person's answer.
 *
 * pickpen is a filter: its stdin and stdout are the pipeline's, so this server is only ever
 * the view's, over the terminal, and never an MCP client's on stdio (pencere §13).
 */

import {
  RESOURCE_MIME_TYPE,
  registerAppResource,
  registerAppTool,
} from "@modelcontextprotocol/ext-apps/server";
import { McpServer } from "@modelcontextprotocol/server";
import { existsSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { z } from "zod";

import type { Boot } from "../shared/wire.ts";
import type { Options } from "./args.ts";
import { ICONS } from "./icon.ts";
import { problemOf, render } from "./output.ts";
import type { Shape } from "./output.ts";
import type { Picker } from "./picker.ts";
import { commandFor, runPreview } from "./preview.ts";

export const VIEW_URI = "ui://pickpen/view";

/**
 * The package's own directory: where its manifest is, above this file, whether it runs built
 * (`dist/node/server`) or from its sources in the tests (`src/server`).
 */
const ROOT = (() => {
  let dir = new URL("./", import.meta.url);
  while (!existsSync(new URL("package.json", dir))) {
    const parent = new URL("../", dir);
    if (parent.href === dir.href) throw new Error("pickpen's package.json is not above its files");
    dir = parent;
  }
  return dir;
})();

/** The view as the files `vite build` writes, for a terminal that keeps them by content. */
export const VIEW_DIRECTORY = new URL("dist/view/", ROOT);

/** The view as one document, for a host that reads it with `resources/read`. */
const VIEW_DOCUMENT = new URL("dist/single/index.html", ROOT);

/** The package's version, from its manifest: a release changes it there and nowhere else. */
export const VERSION: string = JSON.parse(
  readFileSync(new URL("package.json", ROOT), "utf8"),
).version;

/** How long a call for rows waits for the input before it answers with none. */
const ROWS_WAIT_MS = 1000;
/** After the first new row, how long it waits for the next few, so that rows come in batches. */
const ROWS_GATHER_MS = 40;

export interface Answer {
  /** The rows the person chose, by their place, in the order they go out, and their shape. */
  chosen(rows: number[], shape: Shape): void;
  /** The person sent nothing. */
  cancelled(): void;
}

const app = { _meta: { ui: { visibility: ["app" as const] } } };

function text(value: string) {
  return { content: [{ type: "text" as const, text: value }] };
}

function data<T>(value: T, summary: string) {
  return { ...text(summary), structuredContent: value as Record<string, unknown> };
}

function failure(message: string) {
  return { isError: true, ...text(message) };
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export function bootOf(options: Options): Boot {
  return {
    version: VERSION,
    title: options.title ?? null,
    query: options.query,
    where: options.where ?? null,
    confirm: options.confirm,
    sort: options.sort ?? null,
    preview: options.preview ?? null,
    given: options.given,
  };
}

export function createServer(picker: Picker, options: Options, answer: Answer): McpServer {
  // A terminal draws the icon beside the program's name above the view.
  const server = new McpServer({ name: "pickpen", version: VERSION, icons: ICONS });
  const boot = bootOf(options);
  /** The shape of the output: the command line's, or the columns the person picked in the view. */
  const shapeOf = (fields: string[] | undefined): Shape =>
    fields && fields.length > 0 ? { kind: "fields", names: fields } : options.shape;
  /** The places that name rows, each once, in the order given. */
  const placesOf = (rows: number[]) => {
    const seen = new Set<number>();
    return rows.filter((at) => {
      if (at < 0 || at >= picker.rows.length || seen.has(at)) return false;
      seen.add(at);
      return true;
    });
  };

  const view = registerAppTool(
    server,
    "show_picker",
    {
      // What a terminal writes above the view, in place of `show_picker`: the same for every
      // run, as a program's name is; `--title` is the view's to say, at its top.
      title: "Pick",
      description: "Show the rows of the input, for a person to choose from",
      _meta: { ui: { resourceUri: VIEW_URI } },
    },
    async () => {
      // A moment for the first rows, so that the view opens on them rather than on nothing.
      await picker.wait(0, 300);
      const batch = picker.batch(0);
      return data(
        { boot, ...batch },
        `${batch.total} rows${batch.done ? "" : " so far"}, ${batch.columns.length} columns`,
      );
    },
  );
  // ext-apps' config has no `icons`, though the tool it registers carries them into tools/list.
  view.icons = ICONS;

  registerAppTool(
    server,
    "pickpen_rows",
    {
      description:
        "The rows after the first `since`, waiting a moment for them when there are none yet",
      inputSchema: z.object({ since: z.number().int().min(0) }),
      ...app,
    },
    async ({ since }: { since: number }, ctx) => {
      const signal = ctx.mcpReq.signal;
      if (picker.rows.length <= since && !picker.done) {
        await picker.wait(since, ROWS_WAIT_MS, signal);
        if (picker.rows.length > since) await sleep(ROWS_GATHER_MS);
      }
      const batch = picker.batch(since);
      return data(batch, `${batch.rows.length} rows from ${since}`);
    },
  );

  registerAppTool(
    server,
    "pickpen_output",
    {
      description: "What would go out on stdout for these rows",
      inputSchema: z.object({
        rows: z.array(z.number().int()).max(1000),
        fields: z.array(z.string()).optional(),
      }),
      ...app,
    },
    async ({ rows, fields }: { rows: number[]; fields?: string[] }) => {
      const shape = shapeOf(fields);
      const problem = problemOf(shape, picker.names);
      if (problem) return failure(problem);
      const records = placesOf(rows).map((at) => picker.rows[at]!);
      const out = render(records, shape, picker);
      return data({ text: out }, `${records.length} rows`);
    },
  );

  if (options.preview !== undefined) {
    const template = options.preview;
    let running: AbortController | undefined;
    registerAppTool(
      server,
      "pickpen_preview",
      {
        description: "What the preview command prints for a row",
        inputSchema: z.object({
          row: z.number().int().min(0),
          width: z.number().int().min(10).max(1000),
        }),
        ...app,
      },
      async ({ row, width }: { row: number; width: number }, ctx) => {
        const record = picker.rows[row];
        if (record === undefined) return failure("There is no such row");
        // One preview at a time: the cursor has moved on from the last one.
        running?.abort();
        const mine = new AbortController();
        running = mine;
        ctx.mcpReq.signal.addEventListener("abort", () => mine.abort(), { once: true });
        const result = await runPreview(commandFor(template, record, picker), width, mine.signal);
        if (running === mine) running = undefined;
        return data(result, `Preview of row ${row}`);
      },
    );
  }

  registerAppTool(
    server,
    "pickpen_choose",
    {
      description: "Send these rows, by their place, in this order, and end",
      inputSchema: z.object({
        rows: z.array(z.number().int()),
        fields: z.array(z.string()).optional(),
      }),
      ...app,
    },
    async ({ rows, fields }: { rows: number[]; fields?: string[] }) => {
      const shape = shapeOf(fields);
      const problem = problemOf(shape, picker.names);
      if (problem) return failure(problem);
      const places = placesOf(rows);
      if (places.length === 0) return failure("No row was chosen");
      answer.chosen(places, shape);
      return text(`Sending ${places.length} row${places.length === 1 ? "" : "s"}`);
    },
  );

  registerAppTool(
    server,
    "pickpen_cancel",
    { description: "Send nothing, and end", ...app },
    async () => {
      answer.cancelled();
      return text("Sending nothing");
    },
  );

  registerAppResource(server, "pickpen", VIEW_URI, {}, async (uri) => ({
    contents: [
      { uri: uri.href, mimeType: RESOURCE_MIME_TYPE, text: await readFile(VIEW_DOCUMENT, "utf8") },
    ],
  }));
  return server;
}
