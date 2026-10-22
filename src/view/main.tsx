import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import type { Shown } from "../shared/wire";
import { App } from "./App";
import { attach } from "./lib/bridge";
import { Host } from "./lib/host";
import { start } from "./state/actions";
import { onKeyDown } from "./state/keyboard";
import { set } from "./state/store";
import "./styles.css";

declare const __PICKPEN_VERSION__: string;

// The host calls `show_picker` once the view is up and sends its result here: the rows so
// far and how the command line set the view up. More rows come from `pickpen_rows`.
const host = new Host({
  toolResult(result) {
    if (result.isError) {
      const text = (result.content ?? []).find((c) => c.type === "text")?.text;
      set({ error: text ?? "The program could not show its rows" });
      return;
    }
    void start(result.structuredContent as Shown);
  },
  toolCancelled(reason) {
    set({ error: reason ?? "The program did not answer" });
  },
});
attach(host);
window.addEventListener("keydown", onKeyDown, true);
void host.connect({ name: "pickpen", version: __PICKPEN_VERSION__ }).catch((error: Error) => {
  set({ error: error.message });
});

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
