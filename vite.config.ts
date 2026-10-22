import react from "@vitejs/plugin-react";
import { readFileSync } from "node:fs";
import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";

import { harness } from "./harness/plugin.ts";

const { version } = JSON.parse(readFileSync(new URL("package.json", import.meta.url), "utf8"));

// The view is built twice: `vite build` writes the files a pencere terminal keeps by content,
// and `vite build --mode single` one document, for a host that reads it with `resources/read`.
// `vite --mode harness` serves it in a stand-in host in the browser, with the program's
// server behind it.
export default defineConfig(({ mode }) => {
  const single = mode === "single";
  return {
    // Relative, so that the view's files are found wherever its document is served from.
    base: "./",
    // The view tells its host which version it is; a release changes it in package.json only.
    define: { __PICKPEN_VERSION__: JSON.stringify(version) },
    plugins: [
      react(),
      ...(single ? [viteSingleFile()] : []),
      ...(mode === "harness" ? [harness()] : []),
    ],
    build: {
      outDir: single ? "dist/single" : "dist/view",
      emptyOutDir: true,
    },
    server: { port: 5199, strictPort: true },
  };
});
