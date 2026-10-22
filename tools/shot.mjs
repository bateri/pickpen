// Screenshots of the view in the harness, with headless Chrome, for docs/ and for looking:
//
//   npm run harness &        (serves the harness on :5199)
//   node tools/shot.mjs <out.png> "<harness query>" <width> <height> [steps...]
//
// The query is the harness page's (input=, args=, theme=, size=); `bare` is added, so that the
// pane fills the shot. Steps run in order:
//
//   wait:ms   type:text   key:Tab   key:Shift-Tab   key:Mod-a   key:F3
//   click:x,y   rclick:x,y   dclick:x,y   drag:x1,y1,x2,y2   move:x,y
//
// What the page logs, and what it throws, is written to stderr.

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [out, query = "", width = "1280", height = "760", ...steps] = process.argv.slice(2);
const CHROME = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = mkdtempSync(join(tmpdir(), "pickpen-shot-"));
const port = 9300 + Math.floor(Math.random() * 500);
const chrome = spawn(
  CHROME,
  [
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    `--user-data-dir=${profile}`,
    `--remote-debugging-port=${port}`,
    `--window-size=${width},${height}`,
    "about:blank",
  ],
  { stdio: "ignore" },
);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let targets;
for (let i = 0; i < 50; i++) {
  try {
    targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    break;
  } catch {
    await sleep(200);
  }
}
const page = targets.find((t) => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r));
let id = 0;
const pending = new Map();
ws.addEventListener("message", (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) {
    pending.get(m.id)(m);
    pending.delete(m.id);
  } else if (m.method === "Runtime.consoleAPICalled") {
    process.stderr.write(
      `console.${m.params.type}: ${m.params.args.map((a) => a.value ?? a.description).join(" ")}\n`,
    );
  } else if (m.method === "Runtime.exceptionThrown") {
    const d = m.params.exceptionDetails;
    process.stderr.write(`exception: ${d.exception?.description ?? d.text}\n`);
  }
});
const send = (method, params = {}) =>
  new Promise((r) => {
    const i = ++id;
    pending.set(i, r);
    ws.send(JSON.stringify({ id: i, method, params }));
  });
await send("Runtime.enable");
await send("Emulation.setDeviceMetricsOverride", {
  width: +width,
  height: +height,
  deviceScaleFactor: 2,
  mobile: false,
});
await send("Page.navigate", { url: `http://localhost:5199/harness/index.html?bare=1&${query}` });
await sleep(3500);

const CODES = {
  Enter: 13,
  Escape: 27,
  ArrowDown: 40,
  ArrowUp: 38,
  ArrowLeft: 37,
  ArrowRight: 39,
  Tab: 9,
  PageDown: 34,
  PageUp: 33,
  Backspace: 8,
  F1: 112,
  F2: 113,
  F3: 114,
  F4: 115,
};
const MODS = { Alt: 1, Ctrl: 2, Mod: 4, Meta: 4, Shift: 8 };

async function key(spec) {
  const parts = spec.split("-");
  const name = parts.pop();
  let modifiers = 0;
  for (const p of parts) modifiers |= MODS[p] ?? 0;
  const code = CODES[name];
  const text = code || modifiers & 6 ? undefined : name;
  const base = {
    key: name,
    modifiers,
    ...(code
      ? { windowsVirtualKeyCode: code, code: name }
      : {
          code: `Key${name.toUpperCase()}`,
          windowsVirtualKeyCode: name.toUpperCase().charCodeAt(0),
        }),
    ...(text ? { text } : {}),
  };
  await send("Input.dispatchKeyEvent", { type: text ? "keyDown" : "rawKeyDown", ...base });
  await send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
  await sleep(120);
}

async function mouse(type, x, y, extra = {}) {
  await send("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1, ...extra });
}

for (const step of steps) {
  const [kind, ...rest] = step.split(":");
  const value = rest.join(":");
  const numbers = value.split(",").map(Number);
  if (kind === "wait") await sleep(+value);
  else if (kind === "key") await key(value);
  else if (kind === "type") {
    for (const ch of value) {
      await send("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch });
      await send("Input.dispatchKeyEvent", { type: "keyUp", key: ch });
      await sleep(30);
    }
    await sleep(150);
  } else if (kind === "click" || kind === "dclick" || kind === "rclick") {
    const [x, y] = numbers;
    const button = kind === "rclick" ? "right" : "left";
    await mouse("mouseMoved", x, y);
    for (let n = 1; n <= (kind === "dclick" ? 2 : 1); n++) {
      await mouse("mousePressed", x, y, { button, clickCount: n });
      await mouse("mouseReleased", x, y, { button, clickCount: n });
    }
    await sleep(150);
  } else if (kind === "drag") {
    const [x1, y1, x2, y2] = numbers;
    await mouse("mouseMoved", x1, y1);
    await mouse("mousePressed", x1, y1);
    for (let i = 1; i <= 10; i++) {
      await mouse("mouseMoved", x1 + ((x2 - x1) * i) / 10, y1 + ((y2 - y1) * i) / 10, {
        buttons: 1,
      });
    }
    await mouse("mouseReleased", x2, y2);
    await sleep(150);
  } else if (kind === "move") {
    await mouse("mouseMoved", numbers[0], numbers[1]);
  }
}
await sleep(300);
const shot = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(out, Buffer.from(shot.result.data, "base64"));
ws.close();
chrome.kill();
await sleep(300);
rmSync(profile, { recursive: true, force: true });
