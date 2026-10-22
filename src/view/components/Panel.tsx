/**
 * The side panel, three tabs:
 *
 * - the row the cursor is on: what `--preview` prints for it, or its cells;
 * - a column: its values by how often they come, or a chart of its quantities, among the rows
 *   the rest of the query keeps; a click on a value, or a drag across the chart, writes the term
 *   into the query, where the keyboard can change it;
 * - what goes out: the bytes Send would write, drawn by the program with the function that
 *   writes them, and the command line that does it again with nobody to ask.
 */

import { IconCheck, IconChevronDown, IconCopy, IconInfoCircle, IconX } from "@tabler/icons-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { matches, parse, quoteName, quoteValue } from "../../shared/query";
import { quantity, writeQuantity } from "../../shared/values";
import type { Kind } from "../../shared/values";
import type { OutputResult, PreviewResult } from "../../shared/wire";
import { runs } from "../lib/ansi";
import { label } from "../lib/keys";
import { call } from "../lib/bridge";
import * as act from "../state/actions";
import { table } from "../state/data";
import { set, useStore } from "../state/store";
import type { Tab } from "../state/store";
import { openMenu } from "./Menu";
import { Keys, count, keepFocus, plural } from "./ui";

const TABS: { tab: Tab; label: string; keys: string }[] = [
  { tab: "row", label: "Row", keys: "F2" },
  { tab: "column", label: "Column", keys: "F3" },
  { tab: "output", label: "Output", keys: "F4" },
];

export function Panel({ narrow }: { narrow: boolean }) {
  const panel = useStore((s) => s.panel);
  const width = useStore((s) => s.panelWidth);

  const resize = (event: React.MouseEvent) => {
    event.preventDefault();
    const start = event.clientX;
    const from = width;
    const moved = (e: MouseEvent) =>
      set({
        panelWidth: Math.max(240, Math.min(window.innerWidth - 280, from - (e.clientX - start))),
      });
    const done = () => {
      window.removeEventListener("mousemove", moved);
      window.removeEventListener("mouseup", done);
      document.body.classList.remove("resizing");
    };
    document.body.classList.add("resizing");
    window.addEventListener("mousemove", moved);
    window.addEventListener("mouseup", done);
  };

  return (
    <aside
      className="panel"
      data-narrow={narrow}
      style={narrow ? { width: Math.min(width, window.innerWidth - 24) } : undefined}
    >
      {!narrow ? <div className="panel-edge" onMouseDown={resize} /> : null}
      <nav className="tabs" role="tablist">
        {TABS.map(({ tab, label, keys }) => (
          <button
            key={tab}
            type="button"
            role="tab"
            aria-selected={panel.tab === tab}
            className="tab"
            onMouseDown={keepFocus}
            onClick={() => set({ panel: { open: true, tab } })}
            tabIndex={-1}
          >
            {label} <Keys spec={keys} quiet />
          </button>
        ))}
        <span className="spacer" />
        <button
          type="button"
          className="tab-close"
          aria-label="Close the panel"
          onMouseDown={keepFocus}
          onClick={act.togglePanel}
          tabIndex={-1}
        >
          <IconX size={13} stroke={2} />
        </button>
      </nav>
      <div className="panel-body">
        {panel.tab === "row" ? <RowTab /> : panel.tab === "column" ? <ColumnTab /> : <OutputTab />}
      </div>
    </aside>
  );
}

// ---- the row ---------------------------------------------------------------------------

function RowTab() {
  const cursor = useStore((s) => s.cursor);
  const boot = useStore((s) => s.boot)!;
  if (cursor === null) return <p className="quiet pad">No row is under the cursor.</p>;
  if (boot.preview !== null) return <Preview row={cursor} command={boot.preview} />;
  const row = table.rows[cursor]!;
  return (
    <dl className="fields">
      {table.columns.map((name, column) => {
        const value = row.cells[column] ?? "";
        return (
          <div key={column} className="field">
            <dt>{name}</dt>
            <dd>
              <button
                type="button"
                className="value"
                title={table.columns.length > 1 ? `Only rows where ${name} is this` : undefined}
                onMouseDown={keepFocus}
                onClick={() =>
                  table.columns.length > 1 && act.setTerm(column, act.termFor(column, value))
                }
                onContextMenu={(e) => {
                  e.preventDefault();
                  openMenu({ x: e.clientX, y: e.clientY }, [
                    {
                      label: `Only rows where ${name} is this`,
                      run: () => act.setTerm(column, act.termFor(column, value)),
                    },
                    {
                      label: `Leave out rows where ${name} is this`,
                      run: () => act.setTerm(column, act.termFor(column, value, true)),
                    },
                    { separator: true },
                    { label: "Copy the value", run: () => void act.copyText(value, "the value") },
                  ]);
                }}
                tabIndex={-1}
              >
                {value === "" ? <span className="quiet">empty</span> : value}
              </button>
            </dd>
          </div>
        );
      })}
    </dl>
  );
}

function Preview({ row, command }: { row: number; command: string }) {
  const [result, setResult] = useState<PreviewResult | null>(null);
  const [waiting, setWaiting] = useState(false);
  const box = useRef<HTMLPreElement>(null);

  useEffect(() => {
    let current = true;
    setWaiting(true);
    // The cursor may be moving through rows: a preview is asked for once it rests a moment.
    const timer = setTimeout(() => {
      const chars = Math.max(
        20,
        Math.floor((box.current?.clientWidth ?? 400) / act.charWidth()) - 2,
      );
      call<PreviewResult>("pickpen_preview", { row, width: Math.min(chars, 1000) })
        .then((r) => current && setResult(r))
        .catch(
          (e: Error) =>
            current && setResult({ text: e.message, status: null, cut: false, timedOut: false }),
        )
        .finally(() => current && setWaiting(false));
    }, 120);
    return () => {
      current = false;
      clearTimeout(timer);
    };
  }, [row, command]);

  return (
    <div className="preview">
      <div className="preview-head" title={command}>
        <code>{command}</code>
        {waiting ? <span className="state live">running</span> : null}
        {result && !waiting && result.status !== 0 ? (
          <span className="state warn">
            {result.timedOut
              ? "took too long"
              : result.status === null
                ? "ended by a signal"
                : `exit ${result.status}`}
          </span>
        ) : null}
      </div>
      <pre ref={box} className="preview-text" data-stale={waiting}>
        {result
          ? runs(result.text).map((run, i) => (
              <span
                key={i}
                style={{
                  color: run.fg,
                  background: run.bg,
                  fontWeight: run.bold ? 600 : undefined,
                  opacity: run.dim ? 0.65 : undefined,
                  fontStyle: run.italic ? "italic" : undefined,
                  textDecoration: run.underline ? "underline" : undefined,
                }}
              >
                {run.text}
              </span>
            ))
          : null}
        {result?.cut ? <span className="quiet">{"\n"}… the rest was cut</span> : null}
      </pre>
    </div>
  );
}

// ---- a column --------------------------------------------------------------------------

/** The rows the query keeps when its own terms on this column are left out: what the column's values are counted on. */
function facetRows(query: string, column: number): number[] {
  const parsed = parse(query, table.columns);
  const rest = {
    terms: parsed.terms.filter((t) => !(t.kind === "field" && t.column === column)),
    empty: false,
  };
  rest.empty = rest.terms.length === 0;
  const ids: number[] = [];
  for (let at = 0; at < table.rows.length; at++) {
    if (rest.empty || matches(rest, table.rows[at]!)) ids.push(at);
  }
  return ids;
}

function ColumnTab() {
  const column = useStore((s) => Math.min(s.column, Math.max(0, table.columns.length - 1)));
  const query = useStore((s) => s.query);
  const version = useStore((s) => s.version);
  const name = table.columns[column] ?? "";
  const kind = table.kinds[column] ?? "text";
  const ids = useMemo(() => facetRows(query, column), [query, column, version]);

  const choose = (event: React.MouseEvent) => {
    openMenu(
      { x: event.clientX, y: event.clientY },
      table.columns.map((c, at) => ({ label: c, run: () => set({ column: at }) })),
    );
  };

  return (
    <div className="column-tab">
      <button
        type="button"
        className="column-pick"
        onMouseDown={keepFocus}
        onClick={choose}
        tabIndex={-1}
      >
        <b>{name}</b> <span className="quiet">{kind === "text" ? "words" : `${kind}s`}</span>
        <IconChevronDown size={13} stroke={2} />
      </button>
      {kind !== "text" ? <Chart column={column} kind={kind} ids={ids} /> : null}
      <Values column={column} ids={ids} limit={kind === "text" ? 40 : 12} />
    </div>
  );
}

const BINS = 36;

function Chart({ column, kind, ids }: { column: number; kind: Kind; ids: number[] }) {
  const query = useStore((s) => s.query);
  const area = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<[number, number] | null>(null);

  const stats = useMemo(() => {
    const values: number[] = [];
    for (const id of ids) {
      const q = quantity(table.rows[id]!.cells[column] ?? "");
      if (q && (q.kind === kind || q.kind === "number")) values.push(q.value);
    }
    if (values.length === 0) return null;
    values.sort((a, b) => a - b);
    const min = values[0]!;
    const max = values.at(-1)!;
    // Times, sizes and counts are often spread over orders of magnitude (most requests take
    // milliseconds, a few seconds): then the chart is in logarithms, so that the many small
    // values are not one bar and the few large ones are still seen.
    const log = min > 0 && max / min >= 100;
    const scale = log ? (v: number) => Math.log(v) : (v: number) => v;
    const unscale = log ? (v: number) => Math.exp(v) : (v: number) => v;
    const low = scale(min);
    const span = scale(max) - low || 1;
    const bins = new Array<number>(BINS).fill(0);
    for (const v of values) {
      bins[Math.min(BINS - 1, Math.floor(((scale(v) - low) / span) * BINS))]! += 1;
    }
    return {
      min,
      max,
      median: values[Math.floor(values.length / 2)]!,
      bins,
      log,
      /** Where a value is across the chart, from 0 to 1, and the value at a place. */
      place: (v: number) => (scale(v) - low) / span,
      valueAt: (f: number) => unscale(low + f * span),
    };
  }, [ids, column, kind]);

  if (!stats) return <p className="quiet pad">No cell of these rows is a {kind}.</p>;
  const peak = Math.max(...stats.bins);
  const at = (x: number) => {
    const rect = area.current!.getBoundingClientRect();
    return Math.max(0, Math.min(1, (x - rect.left) / rect.width));
  };
  const { valueAt } = stats;
  const name = quoteName(table.columns[column] ?? "");
  const range = (() => {
    const parsed = parse(query, table.columns);
    const term = parsed.terms.find((t) => t.kind === "field" && t.column === column && t.range);
    if (!term || term.kind !== "field" || !term.range) return null;
    const low = quantity(term.range[0]);
    const high = quantity(term.range[1]);
    if (!low || !high) return null;
    return [stats.place(low.value), stats.place(high.value)] as [number, number];
  })();
  const band = drag ?? range;

  const onMouseDown = (event: React.MouseEvent) => {
    event.preventDefault();
    const from = at(event.clientX);
    setDrag([from, from]);
    const moved = (e: MouseEvent) => setDrag([from, at(e.clientX)]);
    const done = (e: MouseEvent) => {
      window.removeEventListener("mousemove", moved);
      window.removeEventListener("mouseup", done);
      setDrag(null);
      const to = at(e.clientX);
      if (Math.abs(to - from) < 0.01) {
        act.setTerm(column, undefined);
        return;
      }
      const [low, high] = from < to ? [from, to] : [to, from];
      act.setTerm(
        column,
        `${name}=${writeQuantity(kind, valueAt(low))}..${writeQuantity(kind, valueAt(high))}`,
      );
    };
    window.addEventListener("mousemove", moved);
    window.addEventListener("mouseup", done);
  };

  return (
    <div className="chart-box">
      <div
        ref={area}
        className="chart"
        onMouseDown={onMouseDown}
        title="Drag across to keep only that range; click to let every value in"
      >
        {stats.bins.map((n, i) => (
          <span
            key={i}
            className="bin"
            data-in={
              band
                ? (i + 0.5) / BINS >= Math.min(...band) && (i + 0.5) / BINS <= Math.max(...band)
                : undefined
            }
            style={{ height: `${n === 0 ? 0 : Math.max(4, Math.sqrt(n / peak) * 100)}%` }}
          />
        ))}
        {band ? (
          <span
            className="band"
            style={{
              left: `${Math.min(...band) * 100}%`,
              width: `${Math.abs(band[1] - band[0]) * 100}%`,
            }}
          />
        ) : null}
      </div>
      <div className="chart-scale">
        <span>{writeQuantity(kind, stats.min)}</span>
        <span>
          median {writeQuantity(kind, stats.median)}
          {stats.log ? " · log scale" : ""}
        </span>
        <span>{writeQuantity(kind, stats.max)}</span>
      </div>
    </div>
  );
}

function Values({ column, ids, limit }: { column: number; ids: number[]; limit: number }) {
  const query = useStore((s) => s.query);
  const values = useMemo(() => {
    const counts = new Map<string, number>();
    for (const id of ids) {
      const v = table.rows[id]!.cells[column] ?? "";
      counts.set(v, (counts.get(v) ?? 0) + 1);
    }
    return [...counts].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
  }, [ids, column]);
  const chosen = useMemo(() => {
    const term = parse(query, table.columns).terms.find(
      (t) => t.kind === "field" && t.column === column && t.op === "=" && !t.range,
    );
    return new Set(term && term.kind === "field" ? term.values.map((v) => v.toLowerCase()) : []);
  }, [query, column]);
  const top = values.slice(0, limit);
  const most = top[0]?.[1] ?? 1;
  const name = quoteName(table.columns[column] ?? "");

  const pick = (value: string, event: React.MouseEvent) => {
    if (event.metaKey || event.ctrlKey) {
      const next = new Set(chosen);
      if (next.has(value.toLowerCase())) next.delete(value.toLowerCase());
      else next.add(value.toLowerCase());
      const kept = top.map(([v]) => v).filter((v) => next.has(v.toLowerCase()));
      act.setTerm(
        column,
        kept.length === 0 ? undefined : `${name}=${kept.map(quoteValue).join("|")}`,
      );
    } else if (chosen.size === 1 && chosen.has(value.toLowerCase())) {
      act.setTerm(column, undefined);
    } else {
      act.setTerm(column, act.termFor(column, value));
    }
  };

  return (
    <div className="values">
      <div className="values-head">
        {values.length === 1 ? "one value" : `${count(values.length)} values`} in{" "}
        {plural(ids.length, "row")}
        {values.length > top.length ? (
          <span className="quiet"> · the {top.length} most common</span>
        ) : null}
      </div>
      {top.map(([value, n]) => (
        <button
          key={value}
          type="button"
          className="value-row"
          data-chosen={chosen.has(value.toLowerCase())}
          onMouseDown={keepFocus}
          onClick={(e) => pick(value, e)}
          onContextMenu={(e) => {
            e.preventDefault();
            openMenu({ x: e.clientX, y: e.clientY }, [
              {
                label: "Only rows with this",
                run: () => act.setTerm(column, act.termFor(column, value)),
              },
              {
                label: "Leave out rows with this",
                run: () => act.setTerm(column, act.termFor(column, value, true)),
              },
              {
                label: "Mark the rows with this",
                run: () =>
                  act.setMarked(
                    ids.filter((id) => (table.rows[id]!.cells[column] ?? "") === value),
                    true,
                  ),
              },
            ]);
          }}
          title="Click: only rows with this · ⌘-click: or with this · right-click: more"
          tabIndex={-1}
        >
          <span className="value-bar" style={{ width: `${(n / most) * 100}%` }} />
          <span className="value-text">
            {value === "" ? <span className="quiet">empty</span> : value}
          </span>
          <span className="value-count">{count(n)}</span>
          {chosen.has(value.toLowerCase()) ? <IconCheck size={12} stroke={2.5} /> : null}
        </button>
      ))}
    </div>
  );
}

// ---- what goes out ---------------------------------------------------------------------

function OutputTab() {
  const marked = useStore((s) => s.marked);
  const cursor = useStore((s) => s.cursor);
  const order = useStore((s) => s.order);
  const fields = useStore((s) => s.fields);
  const boot = useStore((s) => s.boot)!;
  const query = useStore((s) => s.query);
  useStore((s) => s.shown);
  const [out, setOut] = useState<{ text: string; error?: string } | null>(null);
  const rows = act.toSend();
  const again = act.again();
  const sentFields = fields ?? boot.given.field ?? null;

  useEffect(() => {
    let current = true;
    const timer = setTimeout(() => {
      const first = rows.slice(0, 200);
      call<OutputResult>("pickpen_output", { rows: first, ...(fields ? { fields } : {}) })
        .then((r) => current && setOut({ text: r.text }))
        .catch((e: Error) => current && setOut({ text: "", error: e.message }));
    }, 120);
    return () => {
      current = false;
      clearTimeout(timer);
    };
    // The rows to send change with the marks, the cursor and the order.
  }, [marked, cursor, order, fields, rows.length]);

  return (
    <div className="output-tab">
      <section>
        <h3>Again, with nobody to ask</h3>
        <div className="command">
          <code>{again.line}</code>
          <button
            type="button"
            className="copy"
            aria-label="Copy the command"
            onMouseDown={keepFocus}
            onClick={() => void act.copyText(again.line, "the command")}
            tabIndex={-1}
          >
            <IconCopy size={13} stroke={1.8} />
          </button>
        </div>
        <p className="again" data-kind={again.kind}>
          {again.kind === "same" ? (
            <>
              <IconCheck size={13} stroke={2.5} /> Sends the same {plural(again.rows, "row")}: the
              ones marked are the ones {again.where.trim() === "" ? "there are" : "it matches"}.
            </>
          ) : again.kind === "different" ? (
            <>
              <IconInfoCircle size={13} stroke={2} /> Would send{" "}
              {again.where.trim() === ""
                ? "every row"
                : `the ${plural(again.rows, "row")} it matches`}
              ; {count(again.chosen)} {again.chosen === 1 ? "is" : "are"} marked, by hand.{" "}
              {again.where === query ? (
                <button
                  type="button"
                  className="link"
                  onMouseDown={keepFocus}
                  onClick={() => {
                    act.unmarkAll();
                    act.markShown(true);
                  }}
                  tabIndex={-1}
                >
                  Mark just the rows shown
                </button>
              ) : null}
            </>
          ) : (
            <>
              <IconInfoCircle size={13} stroke={2} /> Sends{" "}
              {again.where.trim() === "" ? "every row" : "the rows it matches"}.
              {again.where === query ? (
                <> Mark them ({label("Mod-a")}) to send the same now.</>
              ) : null}
            </>
          )}
        </p>
      </section>
      <section>
        <h3>
          What goes out{" "}
          <span className="quiet">
            {rows.length === 0
              ? "· nothing yet"
              : `· ${plural(rows.length, "row")}${rows.length > 200 ? ", the first 200 shown" : ""}`}
          </span>
        </h3>
        <div className="sent-fields">
          {sentFields && sentFields.length > 0 ? (
            <>
              {sentFields.map((f) => (
                <span key={f} className="chip" data-kind="field">
                  {f}
                  <button
                    type="button"
                    className="chip-x"
                    aria-label={`Stop sending ${f}`}
                    onMouseDown={keepFocus}
                    onClick={() => act.toggleField(f)}
                    tabIndex={-1}
                  >
                    <IconX size={11} stroke={2} />
                  </button>
                </span>
              ))}
              {fields !== null ? (
                <button
                  type="button"
                  className="link"
                  onMouseDown={keepFocus}
                  onClick={act.resetFields}
                  tabIndex={-1}
                >
                  as the command line said
                </button>
              ) : null}
            </>
          ) : (
            <span className="quiet">
              Each row whole. Right-click a heading to send only that column.
            </span>
          )}
        </div>
        {out?.error ? <p className="bad pad">{out.error}</p> : null}
        <pre className="out-text">{out?.text ?? ""}</pre>
      </section>
    </div>
  );
}
