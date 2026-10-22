/**
 * The harness's server side: Vite serves the view with hot reload, and this plugin runs
 * pickpen's own server in the same process, fed from a file of `demo/` (or any file), and
 * passes the harness page's tool calls to it over an in-memory MCP connection.
 *
 * pickpen is a filter and never an MCP server on stdio, so the harness does not start the
 * program: it builds what the program builds, from the built modules (`npm run build:node`).
 * `drip` lets the input come a line at a time, as `tail -f` would.
 */

import { Client } from "@modelcontextprotocol/client";
import { InMemoryTransport } from "@modelcontextprotocol/server";
import { createReadStream } from "node:fs";
import type { IncomingMessage } from "node:http";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { Plugin } from "vite";

interface Started {
  client: Client;
  /** What the program would have written, once the view has sent. */
  sent: string | null;
  stop: () => void;
}

/** Words of a command line, as a shell splits them: quotes keep spaces. */
function words(line: string): string[] {
  const out: string[] = [];
  for (const m of line.matchAll(/'([^']*)'|"((?:\\.|[^"])*)"|(\S+)/g))
    out.push(m[1] ?? m[2] ?? m[3]!);
  return out;
}

async function load<T>(name: string): Promise<T> {
  return (await import(pathToFileURL(resolve(`dist/node/server/${name}.js`)).href)) as T;
}

async function start(input: string, args: string, drip: number): Promise<Started> {
  const { Picker } = await load<typeof import("../src/server/picker.ts")>("picker");
  const { Reader } = await load<typeof import("../src/server/input.ts")>("input");
  const { createServer } = await load<typeof import("../src/server/tools.ts")>("tools");
  const { parse } = await load<typeof import("../src/server/args.ts")>("args");
  const { render } = await load<typeof import("../src/server/output.ts")>("output");

  const parsed = parse(words(args));
  if (parsed.kind !== "run") throw new Error("the harness runs pickpen, not --help or --version");
  const options = parsed.options;
  const picker = new Picker();
  const reader = new Reader(
    {
      columns(names, heading) {
        picker.format = reader.format;
        picker.columns(names, heading);
      },
      record: (record) => picker.record(record),
      problem: (text) => picker.problem(text),
    },
    options.input,
  );
  const stream = createReadStream(resolve(input), "utf8");
  let stopped = false;
  void (async () => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    for await (const chunk of stream) {
      if (drip > 0) {
        for (const line of (chunk as string).split(/(?<=\n)/)) {
          if (stopped) return;
          reader.feed(line);
          if (reader.format === undefined && timer === undefined)
            timer = setTimeout(() => reader.decide(), 150);
          await new Promise((r) => setTimeout(r, drip));
        }
      } else reader.feed(chunk as string);
      if (picker.capped || stopped) break;
    }
    clearTimeout(timer);
    reader.end();
    picker.format = reader.format;
    picker.finish();
  })();

  const started: Started = {
    client: new Client({ name: "pickpen-harness", version: "0.0.0" }),
    sent: null,
    stop: () => (stopped = true),
  };
  const server = createServer(picker, options, {
    chosen(rows, shape) {
      started.sent = render(
        rows.map((at) => picker.rows[at]!),
        shape,
        picker,
      );
    },
    cancelled() {
      started.sent = "";
    },
  });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(a);
  await started.client.connect(b);
  return started;
}

export function harness(): Plugin {
  let current: Started | undefined;
  const body = (request: IncomingMessage) =>
    new Promise<string>((done, fail) => {
      let text = "";
      request.on("data", (chunk: Buffer) => (text += chunk.toString("utf8")));
      request.on("end", () => done(text));
      request.on("error", fail);
    });
  return {
    name: "pickpen-harness",
    configureServer(server) {
      server.middlewares.use(async (request, response, next) => {
        if (request.url === "/" || request.url?.startsWith("/?")) {
          response.statusCode = 302;
          response.setHeader("Location", `/harness/index.html${request.url.slice(1)}`);
          response.end();
          return;
        }
        if (!request.url?.startsWith("/__harness/")) return next();
        try {
          let result: unknown;
          if (request.url === "/__harness/start") {
            const { input, args, drip } = JSON.parse(await body(request)) as {
              input: string;
              args: string;
              drip: number;
            };
            current?.stop();
            current = await start(input, args, drip);
            result = {};
          } else if (!current) {
            throw new Error("start the harness first");
          } else if (request.url === "/__harness/tools") {
            result = await current.client.listTools();
          } else if (request.url === "/__harness/sent") {
            result = { sent: current.sent };
          } else {
            const { name, arguments: args } = JSON.parse(await body(request)) as {
              name: string;
              arguments: Record<string, unknown>;
            };
            result = await current.client.callTool({ name, arguments: args });
          }
          response.setHeader("Content-Type", "application/json");
          response.end(JSON.stringify(result));
        } catch (error) {
          response.statusCode = 500;
          response.end(String(error instanceof Error ? error.stack : error));
        }
      });
    },
  };
}
