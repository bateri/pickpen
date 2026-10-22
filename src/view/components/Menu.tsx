/**
 * A menu at the pointer: what a right-click offers. ↑ ↓ choose, ⏎ runs, Esc closes.
 */

import { useEffect, useLayoutEffect, useRef, useState } from "react";

import { focusQuery } from "../state/actions";
import { set, useStore } from "../state/store";
import type { MenuItem } from "../state/store";
import { Keys } from "./ui";

export function openMenu(at: { x: number; y: number }, items: MenuItem[]): void {
  set({ overlay: { kind: "menu", at, items } });
}

export function MenuLayer() {
  const overlay = useStore((s) => s.overlay);
  if (overlay?.kind !== "menu") return null;
  return <Menu at={overlay.at} items={overlay.items} />;
}

type Runnable = Extract<MenuItem, { label: string }>;

function close(): void {
  set({ overlay: null });
  requestAnimationFrame(focusQuery);
}

function Menu({ at, items }: { at: { x: number; y: number }; items: MenuItem[] }) {
  const ref = useRef<HTMLDivElement>(null);
  const runnable = items
    .map((item, index) => ({ item, index }))
    .filter((x): x is { item: Runnable; index: number } => "label" in x.item && !x.item.disabled);
  const [chosen, setChosen] = useState(0);
  const [place, setPlace] = useState(at);

  useLayoutEffect(() => {
    const element = ref.current;
    if (!element) return;
    element.focus();
    const rect = element.getBoundingClientRect();
    setPlace({
      x: Math.max(6, Math.min(at.x, window.innerWidth - rect.width - 6)),
      y: Math.max(6, Math.min(at.y, window.innerHeight - rect.height - 6)),
    });
  }, [at]);

  useEffect(() => {
    const away = (event: MouseEvent) => {
      if (!ref.current?.contains(event.target as Node)) close();
    };
    window.addEventListener("mousedown", away, true);
    return () => window.removeEventListener("mousedown", away, true);
  }, []);

  const run = (item: Runnable) => {
    close();
    item.run();
  };

  const onKeyDown = (event: React.KeyboardEvent) => {
    event.stopPropagation();
    if (event.key === "ArrowDown" || (event.ctrlKey && event.key === "n")) {
      event.preventDefault();
      setChosen((c) => (c + 1) % Math.max(1, runnable.length));
    } else if (event.key === "ArrowUp" || (event.ctrlKey && event.key === "p")) {
      event.preventDefault();
      setChosen((c) => (c - 1 + runnable.length) % Math.max(1, runnable.length));
    } else if (event.key === "Enter") {
      event.preventDefault();
      const item = runnable[chosen];
      if (item) run(item.item);
    } else if (event.key === "Escape" || event.key === "Tab") {
      event.preventDefault();
      close();
    }
  };

  const active = runnable[chosen]?.index;
  return (
    <div
      ref={ref}
      className="menu pop"
      role="menu"
      tabIndex={-1}
      style={{ left: place.x, top: place.y }}
      onKeyDown={onKeyDown}
      onContextMenu={(e) => e.preventDefault()}
    >
      {items.map((item, index) =>
        "separator" in item ? (
          <div key={index} className="menu-separator" role="separator" />
        ) : (
          <button
            key={index}
            type="button"
            role="menuitem"
            className="menu-item"
            data-active={index === active}
            data-danger={item.danger}
            disabled={item.disabled}
            onMouseEnter={() => {
              const at = runnable.findIndex((r) => r.index === index);
              if (at >= 0) setChosen(at);
            }}
            onMouseDown={(e) => e.preventDefault()}
            onClick={() => run(item)}
          >
            <span className="menu-label">{item.label}</span>
            {item.keys ? <Keys spec={item.keys} quiet /> : null}
          </button>
        ),
      )}
    </div>
  );
}
