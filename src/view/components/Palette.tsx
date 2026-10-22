/**
 * The palette (⌘K): every command by name, with its keys, the columns' own among them
 * (order by, look at, send, hide). Type to narrow it, ↑ ↓ to choose, ⏎ to run, Esc to close.
 */

import { useEffect, useMemo, useRef, useState } from "react";

import { focusQuery } from "../state/actions";
import { paletteCommands } from "../state/commands";
import type { Command } from "../state/commands";
import { set } from "../state/store";
import { Keys } from "./ui";

function close(): void {
  set({ overlay: null });
  requestAnimationFrame(focusQuery);
}

export function Palette() {
  const [text, setText] = useState("");
  const [chosen, setChosen] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const all = useMemo(paletteCommands, []);
  const shown = useMemo(() => {
    const words = text.toLowerCase().split(/\s+/).filter(Boolean);
    return all.filter((c) => {
      const title = `${c.title} ${c.group}`.toLowerCase();
      return words.every((w) => title.includes(w));
    });
  }, [all, text]);

  useEffect(() => input.current?.focus(), []);
  useEffect(() => setChosen(0), [text]);
  useEffect(() => {
    list.current?.querySelector('[data-active="true"]')?.scrollIntoView({ block: "nearest" });
  }, [chosen]);

  const run = (command: Command | undefined) => {
    if (!command || (command.when && !command.when())) return;
    close();
    command.run();
  };

  const onKeyDown = (event: React.KeyboardEvent) => {
    event.stopPropagation();
    if (event.key === "ArrowDown" || (event.ctrlKey && event.key === "n")) {
      event.preventDefault();
      setChosen((c) => Math.min(c + 1, shown.length - 1));
    } else if (event.key === "ArrowUp" || (event.ctrlKey && event.key === "p")) {
      event.preventDefault();
      setChosen((c) => Math.max(c - 1, 0));
    } else if (event.key === "Enter") {
      event.preventDefault();
      run(shown[chosen]);
    } else if (event.key === "Escape" || ((event.metaKey || event.ctrlKey) && event.key === "k")) {
      event.preventDefault();
      close();
    } else if (event.key === "Tab") {
      event.preventDefault();
    }
  };

  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && close()}>
      <div className="palette pop" role="dialog" aria-label="Commands">
        <input
          ref={input}
          className="palette-input"
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={onKeyDown}
          placeholder="A command, or a column's name"
          spellCheck={false}
          autoComplete="off"
        />
        <div ref={list} className="palette-list" role="listbox">
          {shown.length === 0 ? (
            <div className="palette-empty">No command has those words.</div>
          ) : null}
          {shown.map((command, i) => (
            <button
              key={command.id}
              type="button"
              role="option"
              aria-selected={i === chosen}
              data-active={i === chosen}
              className="palette-item"
              disabled={command.when ? !command.when() : false}
              onMouseDown={(e) => e.preventDefault()}
              onMouseMove={() => setChosen(i)}
              onClick={() => run(command)}
            >
              <span className="group">{command.group}</span>
              <span className="title">{command.title}</span>
              {command.keys?.[0] ? <Keys spec={command.keys[0]} quiet /> : null}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}
