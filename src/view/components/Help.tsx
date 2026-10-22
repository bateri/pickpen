/**
 * F1: the keys, what the mouse does, and the query, on one page. The keys are read from the
 * commands, so the page cannot say other than what the keys do.
 */

import { focusQuery } from "../state/actions";
import { COMMANDS } from "../state/commands";
import type { Group } from "../state/commands";
import { set } from "../state/store";
import { Keys } from "./ui";

const GROUPS: Group[] = ["Move", "Mark", "Send", "Order", "Panels", "Copy"];

const MOUSE: [string, string][] = [
  ["Click", "put the cursor on the row"],
  ["Click the box, or drag down the boxes", "mark, or unmark, the rows"],
  ["⌘-click, ⇧-click", "mark one row; every row from the last one marked"],
  ["Double-click", "send the row, when nothing is marked"],
  ["Right-click", "what can be done with the row, its cell, or a heading"],
  ["Click a heading", "order by it: up, down, then as it came"],
  ["Drag a heading's edge", "make the column wider or narrower"],
  ["Click a value in the column panel", "keep only the rows with it (⌘-click: or with it)"],
  ["Drag across the chart", "keep only the rows in that range"],
];

const QUERY: [string, string][] = [
  ["word", "the row holds it, in any column, in any case"],
  ["!word", "it does not"],
  ['"two words"', "quotes keep spaces in a word or a value"],
  ["STATUS=Running", "the column is that; =a|b either"],
  ["STATUS!=Running", "it is not"],
  ["NAME~web  NAME!~web", "it holds web, or does not"],
  ["cpu>50  size>=1G  age<2h", "quantities compare as quantities"],
  ["latency=100..400", "between, both ends included"],
];

export function Help() {
  const close = () => {
    set({ overlay: null });
    requestAnimationFrame(focusQuery);
  };
  return (
    <div className="scrim" onMouseDown={(e) => e.target === e.currentTarget && close()}>
      <div className="help pop" role="dialog" aria-label="Keys, the mouse and the query">
        <header>
          <b>Typing always goes to the query.</b> The commands are on keys that do not type.
          <button
            type="button"
            className="help-close"
            onMouseDown={(e) => e.preventDefault()}
            onClick={close}
          >
            <Keys spec="Escape" quiet />
          </button>
        </header>
        <div className="help-columns">
          <section>
            {GROUPS.map((group) => {
              const commands = COMMANDS.filter(
                (c) => c.group === group && c.keys && !c.id.startsWith("order-"),
              );
              return (
                <div key={group} className="help-group">
                  <h3>{group}</h3>
                  {commands.map((c) => (
                    <div key={c.id} className="help-row">
                      <span className="help-keys">
                        {c.keys!.map((k) => (
                          <Keys key={k} spec={k} />
                        ))}
                      </span>
                      <span>{c.title}</span>
                    </div>
                  ))}
                  {group === "Order" ? (
                    <div className="help-row">
                      <span className="help-keys">
                        <Keys spec="Ctrl-1" /> … <Keys spec="Ctrl-9" />
                      </span>
                      <span>Order by the column at that place; again for the other way</span>
                    </div>
                  ) : null}
                </div>
              );
            })}
          </section>
          <section>
            <div className="help-group">
              <h3>The mouse</h3>
              {MOUSE.map(([what, does]) => (
                <div key={what} className="help-row">
                  <span className="help-what">{what}</span>
                  <span>{does}</span>
                </div>
              ))}
            </div>
            <div className="help-group">
              <h3>The query</h3>
              {QUERY.map(([what, does]) => (
                <div key={what} className="help-row">
                  <code className="help-what">{what}</code>
                  <span>{does}</span>
                </div>
              ))}
              <p className="quiet">
                Every term must hold. A column is named as its heading is, or with only its letters
                (cpu for %CPU). The same query, given to <code>--where</code>, chooses the same rows
                with no one to ask.
              </p>
            </div>
          </section>
        </div>
      </div>
    </div>
  );
}
