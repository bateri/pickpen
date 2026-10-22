/**
 * The line the person types in, which always has the keyboard, and under it what the query
 * means, term by term: a chip says how each term was read (a column compared, or a word looked
 * for), and its × takes it out.
 */

import { IconX } from "@tabler/icons-react";
import { useEffect, useMemo, useRef } from "react";

import { parse, unknownNames } from "../../shared/query";
import type { Term } from "../../shared/query";
import { setQuery, setQueryInput } from "../state/actions";
import { table } from "../state/data";
import { useStore } from "../state/store";
import { Mark, count, keepFocus, plural } from "./ui";

const WORDS: Record<string, string> = {
  "=": "is",
  "!=": "is not",
  "~": "holds",
  "!~": "does not hold",
  ">": "above",
  ">=": "at least",
  "<": "below",
  "<=": "at most",
};

function Chip({ term, source, columns }: { term: Term; source: string; columns: string[] }) {
  const remove = () =>
    setQuery((source.slice(0, term.from) + source.slice(term.to)).replace(/\s{2,}/g, " ").trim());
  let body;
  if (term.kind === "text") {
    body = (
      <>
        <span className="op">{term.negate ? "without" : "has"}</span> <b>{term.text}</b>
      </>
    );
  } else {
    const name = columns[term.column] ?? "";
    const value = term.range ? (
      <>
        <span className="op">between</span> <b>{term.range[0]}</b> <span className="op">and</span>{" "}
        <b>{term.range[1]}</b>
      </>
    ) : (
      <>
        <span className="op">{WORDS[term.op]}</span>{" "}
        {term.values.map((v, i) => (
          <span key={i}>
            {i > 0 ? <span className="op"> or </span> : null}
            <b>{v === "" ? "empty" : v}</b>
          </span>
        ))}
      </>
    );
    body = (
      <>
        <span className="name">{name}</span> {value}
      </>
    );
  }
  return (
    <span className="chip" data-kind={term.kind}>
      {body}
      <button
        type="button"
        className="chip-x"
        aria-label="Take this term out"
        onMouseDown={keepFocus}
        onClick={remove}
        tabIndex={-1}
      >
        <IconX size={11} stroke={2} />
      </button>
    </span>
  );
}

export function QueryBar() {
  const query = useStore((s) => s.query);
  const shown = useStore((s) => s.shown.length);
  const marked = useStore((s) => s.marked.size);
  const boot = useStore((s) => s.boot)!;
  useStore((s) => s.version);
  const input = useRef<HTMLInputElement>(null);

  useEffect(() => {
    setQueryInput(input.current);
    input.current?.focus();
    return () => setQueryInput(null);
  }, []);

  const parsed = useMemo(() => parse(query, table.columns), [query, table.columns]);
  const unknown = useMemo(() => unknownNames(query, table.columns), [query, table.columns]);
  const total = table.rows.length;

  let state: React.ReactNode;
  if (table.capped)
    state = (
      <span className="state warn">the first {count(total)} rows; the rest was not read</span>
    );
  else if (!table.done) state = <span className="state live">reading…</span>;

  return (
    <header className="query-bar">
      {boot.title ? (
        <div className="title">
          <Mark /> {boot.title}
        </div>
      ) : null}
      <div className="query-line">
        <span className="prompt" aria-hidden="true">
          ›
        </span>
        <input
          ref={input}
          className="query"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={placeholderFor(table.columns)}
          spellCheck={false}
          autoComplete="off"
          autoCapitalize="off"
          aria-label="Query"
        />
        <span className="counts">
          {query.trim() === ""
            ? plural(total, "row")
            : `${count(shown)} of ${plural(total, "row")}`}
          {marked > 0 ? <span className="marked"> · {count(marked)} marked</span> : null}
          {state ? <> · {state}</> : null}
        </span>
      </div>
      {parsed.terms.length > 0 ? (
        <div className="terms">
          {parsed.terms.map((term, i) => (
            <Chip key={`${i}:${term.from}`} term={term} source={query} columns={table.columns} />
          ))}
          {unknown.map((name) => (
            <span key={name} className="chip" data-kind="unknown">
              no column named <b>{name}</b>: looked for as a word
            </span>
          ))}
        </div>
      ) : null}
    </header>
  );
}

/**
 * What to type, with the input's own columns and values: `STATUS=Running`, `AGE<1h`, from the
 * column of words with the fewest values and the first column of quantities.
 */
function placeholderFor(columns: string[]): string {
  if (columns.length <= 1) return "Type to filter: words, !word to leave out — F1 for more";
  const examples: string[] = [];
  const sample = table.rows.slice(0, 300);
  let fewest: { name: string; value: string; distinct: number } | undefined;
  columns.forEach((name, column) => {
    if ((table.kinds[column] ?? "text") !== "text" || !/^[\p{L}\p{N}_%-]+$/u.test(name)) return;
    const counts = new Map<string, number>();
    for (const row of sample) {
      const value = row.cells[column] ?? "";
      if (value !== "") counts.set(value, (counts.get(value) ?? 0) + 1);
    }
    const [value] = [...counts].sort((a, b) => b[1] - a[1])[0] ?? [];
    if (value === undefined || counts.size < 2 || !/^\p{L}[\p{L}\p{N}_-]*$/u.test(value)) return;
    if (!fewest || counts.size < fewest.distinct) fewest = { name, value, distinct: counts.size };
  });
  if (fewest) examples.push(`${fewest.name}=${fewest.value}`);
  const quantity = columns.findIndex(
    (name, column) =>
      (table.kinds[column] ?? "text") !== "text" && /^[\p{L}\p{N}_%-]+$/u.test(name),
  );
  if (quantity >= 0) {
    const kind = table.kinds[quantity];
    const bound =
      kind === "duration"
        ? "<1h"
        : kind === "size"
          ? ">1G"
          : kind === "date"
            ? ">2026-01-01"
            : ">10";
    examples.push(`${columns[quantity]}${bound}`);
  }
  return `Type to filter: words, !word${examples.map((e) => `, ${e}`).join("")} — F1 for more`;
}
