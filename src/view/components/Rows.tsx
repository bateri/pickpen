/**
 * The rows: only those in sight are drawn, so a few hundred thousand scroll as a few dozen.
 *
 * The mouse does what the keys do. A click puts the cursor on a row; the box in front of a
 * row marks it, and a drag down the boxes marks (or unmarks) every row it passes; ⌘-click
 * marks one row, ⇧-click every row from the last one marked; a double-click sends the row
 * when nothing is marked; a right-click offers what can be done with the row and the cell.
 * A heading sorts on a click and is resized by its edge. No click takes the keyboard from the
 * query.
 */

import { IconArrowDown, IconArrowUp, IconCheck, IconMinus } from "@tabler/icons-react";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";

import { parse } from "../../shared/query";
import * as act from "../state/actions";
import { table } from "../state/data";
import { get, set, useStore } from "../state/store";
import type { MenuItem } from "../state/store";
import { visibleColumns } from "../state/commands";
import { openMenu } from "./Menu";
import { count, keepFocus, plural } from "./ui";

const ROW = 22;
const HEAD = 26;
const MARK = 30;
const OVERSCAN = 8;
/** The most of a cell drawn; a longer one is cut where it would not be seen anyway. */
const DRAWN = 400;

const QUANTITIES = new Set(["number", "size", "duration"]);

/** The words of the query, for drawing where they are in each cell. */
function wordsOf(query: string): string[] {
  return parse(query, table.columns)
    .terms.filter((t) => t.kind === "text" && !t.negate)
    .map((t) => (t as { text: string }).text)
    .sort((a, b) => b.length - a.length);
}

function Cell({ text, words }: { text: string; words: string[] }) {
  const shown = text.length > DRAWN ? `${text.slice(0, DRAWN)}…` : text;
  if (words.length === 0) return <>{shown}</>;
  const lower = shown.toLowerCase();
  const parts: React.ReactNode[] = [];
  let at = 0;
  while (at < shown.length) {
    let best = -1;
    let length = 0;
    for (const word of words) {
      const found = lower.indexOf(word, at);
      if (found >= 0 && (best < 0 || found < best)) {
        best = found;
        length = word.length;
      }
    }
    if (best < 0) break;
    if (best > at) parts.push(shown.slice(at, best));
    parts.push(<mark key={best}>{shown.slice(best, best + length)}</mark>);
    at = best + length;
  }
  parts.push(shown.slice(at));
  return <>{parts}</>;
}

/** While the mouse is down on the boxes: whether the rows it passes are marked or unmarked. */
let painting: boolean | null = null;

function useCtrlHeld(): boolean {
  const [held, setHeld] = useState(false);
  useEffect(() => {
    const down = (e: KeyboardEvent) =>
      setHeld(e.key === "Control" ? true : e.ctrlKey && !e.metaKey);
    const up = (e: KeyboardEvent) => {
      if (e.key === "Control") setHeld(false);
    };
    const blur = () => setHeld(false);
    window.addEventListener("keydown", down);
    window.addEventListener("keyup", up);
    window.addEventListener("blur", blur);
    return () => {
      window.removeEventListener("keydown", down);
      window.removeEventListener("keyup", up);
      window.removeEventListener("blur", blur);
    };
  }, []);
  return held;
}

function rowMenu(id: number, column: number | null): MenuItem[] {
  const { marked, boot } = get();
  const row = table.rows[id]!;
  const items: MenuItem[] = [
    {
      label: marked.has(id) ? "Unmark the row" : "Mark the row",
      keys: "Tab",
      run: () => act.toggle(id),
    },
  ];
  if (!boot?.confirm && marked.size === 0) {
    items.push({ label: "Send this row", keys: "Enter", run: () => void act.send([id]) });
  }
  if (column !== null && table.columns.length > 1) {
    const name = table.columns[column]!;
    const value = row.cells[column] ?? "";
    const short = value.length > 24 ? `${value.slice(0, 23)}…` : value === "" ? "empty" : value;
    items.push(
      { separator: true },
      {
        label: `Only rows where ${name} is ${short}`,
        run: () => act.setTerm(column, act.termFor(column, value)),
      },
      {
        label: `Leave out rows where ${name} is ${short}`,
        run: () => act.setTerm(column, act.termFor(column, value, true)),
      },
      {
        label: `Mark every row where ${name} is ${short}`,
        run: () => {
          const ids: number[] = [];
          for (let at = 0; at < table.rows.length; at++) {
            if ((table.rows[at]!.cells[column] ?? "") === value) ids.push(at);
          }
          act.setMarked(ids, true);
          act.toast(`Marked ${plural(ids.length, "row")}`);
        },
      },
      { separator: true },
      { label: `Look at the column ${name}`, keys: "F3", run: () => act.showColumn(column) },
      { label: "Copy the value", run: () => void act.copyText(value, "the value") },
    );
  } else {
    items.push({ separator: true });
  }
  items.push({
    label: "Copy the row",
    keys: "Mod-c",
    run: () => void act.copyText(row.cells.join("\t"), "the row"),
  });
  return items;
}

function columnMenu(column: number): MenuItem[] {
  const { order, fields, boot } = get();
  const name = table.columns[column]!;
  const sending = (fields ?? boot?.given.field ?? []).some(
    (f) => f.toLowerCase() === name.toLowerCase(),
  );
  const quantities =
    QUANTITIES.has(table.kinds[column] ?? "text") || table.kinds[column] === "date";
  return [
    {
      label: quantities ? "Smallest first" : "A to Z",
      run: () => act.setOrder({ column, descending: false }),
      disabled: order?.column === column && !order.descending,
    },
    {
      label: quantities ? "Largest first" : "Z to A",
      run: () => act.setOrder({ column, descending: true }),
      disabled: order?.column === column && order.descending,
    },
    {
      label: "The input's order",
      keys: "Ctrl-0",
      run: () => act.setOrder(null),
      disabled: order === null,
    },
    { separator: true },
    { label: `Look at the column ${name}`, keys: "F3", run: () => act.showColumn(column) },
    {
      label: sending ? `Stop sending ${name}` : `Send ${name} of each row`,
      run: () => act.toggleField(name),
    },
    {
      label: `Hide ${name}`,
      run: () => set({ hidden: new Set([...get().hidden, column]) }),
      disabled: visibleColumns().length <= 1,
    },
  ];
}

export function Rows() {
  const shown = useStore((s) => s.shown);
  const where = useStore((s) => s.where);
  const cursor = useStore((s) => s.cursor);
  const marked = useStore((s) => s.marked);
  const order = useStore((s) => s.order);
  const widths = useStore((s) => s.widths);
  const hidden = useStore((s) => s.hidden);
  const query = useStore((s) => s.query);
  const unseen = useStore((s) => s.unseen);
  const follow = useStore((s) => s.follow);
  useStore((s) => s.version);
  const list = useRef<HTMLDivElement>(null);
  const [view, setView] = useState({ top: 0, height: 400 });
  const ctrl = useCtrlHeld();
  const words = useMemo(() => wordsOf(query), [query, table.columns]);
  const columns = visibleColumns();

  // The viewport, as it scrolls and as the pane is resized.
  useLayoutEffect(() => {
    const element = list.current!;
    const measure = () => {
      setView({ top: element.scrollTop, height: element.clientHeight });
      act.setPageRows(Math.floor((element.clientHeight - HEAD) / ROW));
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    let frame = 0;
    const scrolled = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        measure();
        if (element.scrollTop + element.clientHeight >= element.scrollHeight - ROW) act.seen();
      });
    };
    element.addEventListener("scroll", scrolled, { passive: true });
    return () => {
      observer.disconnect();
      element.removeEventListener("scroll", scrolled);
    };
  }, []);

  // The cursor stays in sight when the keys move it, or rows come while it follows.
  useLayoutEffect(() => {
    const element = list.current;
    if (!element || cursor === null) return;
    const index = where[cursor] ?? -1;
    if (index < 0) return;
    const top = index * ROW;
    const visible = element.clientHeight - HEAD;
    if (top < element.scrollTop) element.scrollTop = top;
    else if (top + ROW > element.scrollTop + visible) element.scrollTop = top + ROW - visible;
  }, [cursor, where, follow]);

  useEffect(() => {
    const up = () => {
      painting = null;
    };
    window.addEventListener("mouseup", up);
    return () => window.removeEventListener("mouseup", up);
  }, []);

  // A last column of words takes the room that is left; one of quantities keeps its width,
  // so that it stays beside the others, and the room is left empty after it.
  const lastColumn = columns.at(-1);
  const lastIsQuantity =
    lastColumn !== undefined && QUANTITIES.has(table.kinds[lastColumn] ?? "text");
  const template = `${MARK}px ${columns
    .map((c, i) =>
      i === columns.length - 1 && !lastIsQuantity
        ? `minmax(${widths[c] ?? 80}px, 1fr)`
        : `${widths[c] ?? 80}px`,
    )
    .join(" ")}${lastIsQuantity ? " minmax(0, 1fr)" : ""}`;
  const width = MARK + columns.reduce((sum, c) => sum + (widths[c] ?? 80), 0);
  const first = Math.max(0, Math.floor(view.top / ROW) - OVERSCAN);
  const end = Math.min(shown.length, Math.ceil((view.top + view.height) / ROW) + OVERSCAN);
  const allMarked = shown.length > 0 && shown.every((id) => marked.has(id));
  const someMarked = !allMarked && shown.some((id) => marked.has(id));

  const idAt = (
    target: EventTarget | null,
  ): { id: number; column: number | null; box: boolean } | null => {
    const element = (target as HTMLElement | null)?.closest<HTMLElement>("[data-id]");
    if (!element) return null;
    const cell = (target as HTMLElement).closest<HTMLElement>("[data-column]");
    return {
      id: Number(element.dataset.id),
      column: cell ? Number(cell.dataset.column) : null,
      box: (target as HTMLElement).closest(".box") !== null,
    };
  };

  const onMouseDown = (event: React.MouseEvent) => {
    keepFocus(event);
    if (event.button !== 0) return;
    const hit = idAt(event.target);
    if (!hit) return;
    const state = get();
    if (hit.box) {
      painting = !state.marked.has(hit.id);
      act.setMarked([hit.id], painting);
      set({ anchor: hit.id, cursor: hit.id, follow: false });
    } else if (event.shiftKey) {
      act.extendTo(hit.id);
    } else if (event.metaKey || event.ctrlKey) {
      act.toggle(hit.id);
      act.setCursor(hit.id);
    } else {
      act.setCursor(hit.id);
      set({ anchor: hit.id });
    }
  };

  const onMouseOver = (event: React.MouseEvent) => {
    if (painting === null) return;
    const hit = idAt(event.target);
    if (hit) act.setMarked([hit.id], painting);
  };

  const onDoubleClick = (event: React.MouseEvent) => {
    const hit = idAt(event.target);
    if (!hit || hit.box) return;
    const { marked: m, boot } = get();
    // Nothing goes out on a double-click when rows are marked, nor ever when a person confirms.
    if (m.size === 0 && !boot?.confirm) void act.send([hit.id]);
    else act.toggle(hit.id);
  };

  const onContextMenu = (event: React.MouseEvent) => {
    const hit = idAt(event.target);
    if (!hit) return;
    event.preventDefault();
    act.setCursor(hit.id);
    openMenu({ x: event.clientX, y: event.clientY }, rowMenu(hit.id, hit.column));
  };

  const resize = (column: number) => (event: React.MouseEvent) => {
    event.preventDefault();
    event.stopPropagation();
    const start = event.clientX;
    const from = widths[column] ?? 80;
    const moved = (e: MouseEvent) => act.resizeColumn(column, from + e.clientX - start);
    const done = () => {
      window.removeEventListener("mousemove", moved);
      window.removeEventListener("mouseup", done);
      document.body.classList.remove("resizing");
    };
    document.body.classList.add("resizing");
    window.addEventListener("mousemove", moved);
    window.addEventListener("mouseup", done);
  };

  const rows: React.ReactNode[] = [];
  for (let index = first; index < end; index++) {
    const id = shown[index]!;
    const row = table.rows[id]!;
    rows.push(
      <div
        key={id}
        className="row"
        data-id={id}
        data-cursor={id === cursor}
        data-marked={marked.has(id)}
        role="row"
        aria-selected={marked.has(id)}
        style={{ top: HEAD + index * ROW, gridTemplateColumns: template }}
      >
        <span className="box" role="gridcell" aria-label={marked.has(id) ? "Marked" : "Not marked"}>
          <span className="tick">{marked.has(id) ? <IconCheck size={11} stroke={3} /> : null}</span>
        </span>
        {columns.map((column) => (
          <span
            key={column}
            className="cell"
            role="gridcell"
            data-column={column}
            data-quantity={QUANTITIES.has(table.kinds[column] ?? "text")}
          >
            <Cell text={row.cells[column] ?? ""} words={words} />
          </span>
        ))}
      </div>,
    );
  }

  return (
    <div className="rows-wrap">
      <div
        ref={list}
        className="rows"
        role="grid"
        aria-rowcount={shown.length}
        aria-multiselectable="true"
        onMouseDown={onMouseDown}
        onMouseOver={onMouseOver}
        onDoubleClick={onDoubleClick}
        onContextMenu={onContextMenu}
      >
        <div className="sizer" style={{ height: HEAD + shown.length * ROW, minWidth: width }}>
          <div
            className="head"
            role="row"
            style={{ gridTemplateColumns: template, minWidth: width }}
          >
            <span
              className="box head-box"
              role="columnheader"
              title={allMarked ? "Unmark the rows shown" : "Mark every row shown"}
              onMouseDown={(e) => {
                keepFocus(e);
                e.stopPropagation();
              }}
              onClick={() => act.markShown(!allMarked)}
            >
              <span className="tick" data-on={allMarked || someMarked}>
                {allMarked ? (
                  <IconCheck size={11} stroke={3} />
                ) : someMarked ? (
                  <IconMinus size={11} stroke={3} />
                ) : null}
              </span>
            </span>
            {columns.map((column, i) => (
              <span
                key={column}
                className="heading"
                role="columnheader"
                data-quantity={QUANTITIES.has(table.kinds[column] ?? "text")}
                aria-sort={
                  order?.column === column
                    ? order.descending
                      ? "descending"
                      : "ascending"
                    : "none"
                }
                onMouseDown={(e) => {
                  keepFocus(e);
                  e.stopPropagation();
                }}
                onClick={() => act.cycleOrder(column)}
                onContextMenu={(e) => {
                  e.preventDefault();
                  e.stopPropagation();
                  openMenu({ x: e.clientX, y: e.clientY }, columnMenu(column));
                }}
                title={`${table.columns[column]}: click to order, right-click for more`}
              >
                {ctrl && i < 9 ? <span className="badge">{i + 1}</span> : null}
                <span className="name">{table.columns[column]}</span>
                {order?.column === column ? (
                  order.descending ? (
                    <IconArrowDown size={12} stroke={2} />
                  ) : (
                    <IconArrowUp size={12} stroke={2} />
                  )
                ) : null}
                <span className="resizer" onMouseDown={resize(column)} />
              </span>
            ))}
          </div>
          {rows}
        </div>
      </div>
      {shown.length === 0 ? <Empty /> : null}
      {unseen > 0 ? (
        <button
          type="button"
          className="unseen"
          onMouseDown={keepFocus}
          onClick={act.last}
          tabIndex={-1}
        >
          <IconArrowDown size={12} stroke={2} /> {plural(unseen, "new row")}
        </button>
      ) : null}
      {hidden.size > 0 ? (
        <button
          type="button"
          className="hidden-note"
          onMouseDown={keepFocus}
          onClick={() => set({ hidden: new Set() })}
          tabIndex={-1}
        >
          {plural(hidden.size, "column")} hidden · show
        </button>
      ) : null}
      {table.problems.length > 0 ? <div className="problems">{table.problems.at(-1)}</div> : null}
    </div>
  );
}

function Empty() {
  const query = useStore((s) => s.query);
  if (table.rows.length === 0) {
    return (
      <div className="empty">{table.done ? "The input has no rows." : "Waiting for rows…"}</div>
    );
  }
  return (
    <div className="empty">
      No row of {count(table.rows.length)} matches <b>{query}</b>.{" "}
      <span className="quiet">Esc clears the query.</span>
    </div>
  );
}
