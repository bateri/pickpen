/**
 * Small pieces the screens share: keys as the platform writes them, and buttons that never
 * take the keyboard from the query (a mouse-down on them is not let to move the focus).
 */

import type { ReactNode } from "react";

import { glyphs, isMac } from "../lib/keys";

/** A key, drawn as keycaps: `⌘K`, `Ctrl+K`. */
export function Keys({ spec, quiet = false }: { spec: string; quiet?: boolean }) {
  const parts = glyphs(spec);
  return (
    <span className="keys" data-quiet={quiet} aria-label={parts.join(isMac ? " " : "+")}>
      {parts.map((part, i) => (
        <kbd key={i}>{part}</kbd>
      ))}
    </span>
  );
}

/** Keeps the focus where it is: on the query. */
export const keepFocus = (event: React.MouseEvent) => event.preventDefault();

export function Button({
  children,
  onClick,
  keys,
  label,
  tone,
  disabled,
  className,
}: {
  children: ReactNode;
  onClick: (event: React.MouseEvent) => void;
  keys?: string;
  label?: string;
  tone?: "primary" | "danger" | "quiet";
  disabled?: boolean;
  className?: string;
}) {
  return (
    <button
      type="button"
      className={`button${tone ? ` ${tone}` : ""}${className ? ` ${className}` : ""}`}
      aria-label={label}
      title={label}
      disabled={disabled}
      onClick={onClick}
      onMouseDown={keepFocus}
      tabIndex={-1}
    >
      {children}
      {keys ? <Keys spec={keys} quiet /> : null}
    </button>
  );
}

/** pickpen's mark: three rows, the first and the last of them chosen (tools/icon.mjs draws the same). */
export function Mark({ size = 14 }: { size?: number }) {
  return (
    <svg className="mark" width={size} height={size} viewBox="2 2 20 20" aria-hidden="true">
      <rect x="3" y="3.5" width="4.5" height="4.5" rx="1.2" />
      <rect x="9" y="4.5" width="12" height="2.5" rx="1.25" />
      <rect x="3" y="9.75" width="4.5" height="4.5" rx="1.2" opacity="0.3" />
      <rect x="9" y="10.75" width="9" height="2.5" rx="1.25" opacity="0.4" />
      <rect x="3" y="16" width="4.5" height="4.5" rx="1.2" />
      <rect x="9" y="17" width="10.5" height="2.5" rx="1.25" />
    </svg>
  );
}

/** A count as a person reads it: 12,480. */
export function count(n: number): string {
  return n.toLocaleString("en-US");
}

export function plural(n: number, one: string, many = `${one}s`): string {
  return `${count(n)} ${n === 1 ? one : many}`;
}
