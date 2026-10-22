/**
 * Colour codes in what a preview command prints (`git show --color`, `ls --color`), as runs
 * of text with a style. The sixteen colours are the terminal's own roles, as the host sends
 * them, so that a preview reads in the theme; the 256 and the 24-bit ones are as written.
 */

export interface Run {
  text: string;
  fg?: string;
  bg?: string;
  bold?: boolean;
  dim?: boolean;
  italic?: boolean;
  underline?: boolean;
}

const ROLES = [
  "var(--fg-3)",
  "var(--bad)",
  "var(--ok)",
  "var(--warn)",
  "var(--accent)",
  "color-mix(in oklab, var(--accent) 55%, var(--bad))",
  "var(--info)",
  "var(--fg)",
];

function cube(n: number): string {
  if (n < 8) return ROLES[n]!;
  if (n < 16) return ROLES[n - 8]!;
  if (n >= 232) {
    const level = 8 + (n - 232) * 10;
    return `rgb(${level}, ${level}, ${level})`;
  }
  const c = n - 16;
  const step = (v: number) => (v === 0 ? 0 : 55 + v * 40);
  return `rgb(${step(Math.floor(c / 36))}, ${step(Math.floor(c / 6) % 6)}, ${step(c % 6)})`;
}

const ESCAPE =
  /\x1b\[([0-9;:]*)m|\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]/g;

export function runs(source: string): Run[] {
  const out: Run[] = [];
  let style: Omit<Run, "text"> = {};
  let at = 0;
  const push = (text: string) => {
    if (text === "") return;
    out.push({ text, ...style });
  };
  for (const match of source.matchAll(ESCAPE)) {
    push(source.slice(at, match.index));
    at = match.index! + match[0].length;
    if (match[1] === undefined) continue;
    const codes = match[1] === "" ? [0] : match[1].split(/[;:]/).map(Number);
    for (let i = 0; i < codes.length; i++) {
      const code = codes[i]!;
      if (code === 0) style = {};
      else if (code === 1) style = { ...style, bold: true };
      else if (code === 2) style = { ...style, dim: true };
      else if (code === 3) style = { ...style, italic: true };
      else if (code === 4) style = { ...style, underline: true };
      else if (code === 22) style = { ...style, bold: false, dim: false };
      else if (code === 23) style = { ...style, italic: false };
      else if (code === 24) style = { ...style, underline: false };
      else if (code >= 30 && code <= 37) style = { ...style, fg: ROLES[code - 30]! };
      else if (code >= 90 && code <= 97) style = { ...style, fg: ROLES[code - 90]! };
      else if (code >= 40 && code <= 47) style = { ...style, bg: ROLES[code - 40]! };
      else if (code >= 100 && code <= 107) style = { ...style, bg: ROLES[code - 100]! };
      else if (code === 39) style = { ...style, fg: undefined };
      else if (code === 49) style = { ...style, bg: undefined };
      else if ((code === 38 || code === 48) && codes[i + 1] === 5) {
        const colour = cube(codes[i + 2] ?? 0);
        style = code === 38 ? { ...style, fg: colour } : { ...style, bg: colour };
        i += 2;
      } else if ((code === 38 || code === 48) && codes[i + 1] === 2) {
        const colour = `rgb(${codes[i + 2] ?? 0}, ${codes[i + 3] ?? 0}, ${codes[i + 4] ?? 0})`;
        style = code === 38 ? { ...style, fg: colour } : { ...style, bg: colour };
        i += 4;
      }
    }
  }
  push(source.slice(at));
  return out;
}
