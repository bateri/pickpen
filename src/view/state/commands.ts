/**
 * Every command of the view, with its keys: the keyboard runs them, the palette lists them,
 * and the help shows them, from this one list.
 *
 * What is typed goes to the query, always, so no command is on a key that types: they are on
 * the arrows, Tab, Enter, Esc, the function keys, and ⌘ or ⌃ with a letter. The keys a terminal
 * keeps for itself (in bateri ⌘P ⌘W ⌘O ⌘T ⌘N ⌘D ⌘1–⌘9) and ⌥ with a letter (how a Mac types
 * @ # [ { on many layouts) are left alone.
 */

import { table } from "./data";
import * as act from "./actions";
import { get, set } from "./store";

export type Group = "Move" | "Mark" | "Send" | "Order" | "Panels" | "Copy";

export interface Command {
  id: string;
  title: string;
  group: Group;
  keys?: string[];
  run(): void;
  /** Whether it can run now; a command that cannot is passed over by its keys. */
  when?(): boolean;
  /** Not offered in the palette: moving the cursor is not something one searches for. */
  quiet?: boolean;
  /** Other words the palette finds it by: "sort" for an order, "select" for a mark. */
  also?: string;
}

const hasRows = () => get().shown.length > 0;

function selectionInQuery(): boolean {
  const element = document.activeElement;
  return (
    element instanceof HTMLInputElement &&
    (element.selectionStart ?? 0) !== (element.selectionEnd ?? 0)
  );
}

export const COMMANDS: Command[] = [
  {
    id: "down",
    title: "Next row",
    group: "Move",
    keys: ["ArrowDown", "Ctrl-n"],
    run: () => act.move(1),
    quiet: true,
  },
  {
    id: "up",
    title: "Previous row",
    group: "Move",
    keys: ["ArrowUp", "Ctrl-p"],
    run: () => act.move(-1),
    quiet: true,
  },
  {
    id: "page-down",
    title: "A page down",
    group: "Move",
    keys: ["PageDown"],
    run: () => act.page(1),
    quiet: true,
  },
  {
    id: "page-up",
    title: "A page up",
    group: "Move",
    keys: ["PageUp"],
    run: () => act.page(-1),
    quiet: true,
  },
  {
    id: "first",
    also: "top home beginning",
    title: "First row",
    group: "Move",
    keys: ["Mod-ArrowUp"],
    run: act.first,
  },
  {
    id: "last",
    also: "bottom end tail follow",
    title: "Last row, and follow new rows",
    group: "Move",
    keys: ["Mod-ArrowDown"],
    run: act.last,
  },

  {
    id: "mark",
    title: "Mark the row and go to the next",
    group: "Mark",
    keys: ["Tab"],
    run: () => act.markAndMove(1),
  },
  {
    id: "mark-up",
    title: "Mark the row and go to the previous",
    group: "Mark",
    keys: ["Shift-Tab"],
    run: () => act.markAndMove(-1),
    quiet: true,
  },
  {
    id: "extend-down",
    title: "Mark down from here",
    group: "Mark",
    keys: ["Shift-ArrowDown"],
    run: () => act.extend(1),
    when: hasRows,
    quiet: true,
  },
  {
    id: "extend-up",
    title: "Mark up from here",
    group: "Mark",
    keys: ["Shift-ArrowUp"],
    run: () => act.extend(-1),
    when: hasRows,
    quiet: true,
  },
  {
    id: "mark-shown",
    also: "select all check",
    title: "Mark every row shown",
    group: "Mark",
    keys: ["Mod-a"],
    run: () => act.markShown(true),
  },
  {
    id: "unmark",
    also: "deselect clear none uncheck",
    title: "Unmark every row",
    group: "Mark",
    keys: ["Shift-Mod-a"],
    run: act.unmarkAll,
  },
  {
    id: "invert",
    also: "select toggle reverse",
    title: "Invert the marks of the rows shown",
    group: "Mark",
    run: act.invert,
  },
  {
    id: "unmark-shown",
    also: "deselect uncheck",
    title: "Unmark the rows shown",
    group: "Mark",
    run: () => act.markShown(false),
  },

  {
    id: "send",
    also: "choose accept ok done submit enter",
    title: "Send",
    group: "Send",
    keys: ["Enter"],
    run: () => void act.send(),
    when: () => act.toSend().length > 0,
  },
  {
    id: "back",
    also: "escape clear",
    title: "Back: close, clear the query, then send nothing",
    group: "Send",
    keys: ["Escape"],
    run: act.back,
  },
  {
    id: "cancel",
    also: "quit exit abort close nothing",
    title: "Send nothing and end",
    group: "Send",
    run: () => void act.cancel(),
  },

  {
    id: "order-clear",
    also: "sort unsorted original",
    title: "Rows in the input's order",
    group: "Order",
    keys: ["Ctrl-0"],
    run: () => act.setOrder(null),
  },

  {
    id: "palette",
    title: "Commands",
    group: "Panels",
    keys: ["Mod-k"],
    run: () => set({ overlay: { kind: "palette" } }),
  },
  {
    id: "help",
    also: "shortcuts keyboard f1 syntax",
    title: "Keys, the mouse and the query",
    group: "Panels",
    keys: ["F1"],
    run: () => set({ overlay: { kind: "help" } }),
  },
  {
    id: "panel",
    also: "inspector sidebar preview details",
    title: "Show or hide the side panel",
    group: "Panels",
    keys: ["Mod-i"],
    run: act.togglePanel,
  },
  {
    id: "tab-row",
    also: "preview details fields",
    title: "The row the cursor is on",
    group: "Panels",
    keys: ["F2"],
    run: () => act.openTab("row"),
  },
  {
    id: "tab-column",
    also: "histogram chart distribution values facets",
    title: "A column: its values, and a chart of its quantities",
    group: "Panels",
    keys: ["F3"],
    run: () => act.openTab("column"),
  },
  {
    id: "tab-output",
    also: "stdout result command again script",
    title: "What goes out, and the command that does it again",
    group: "Panels",
    keys: ["F4"],
    run: () => act.openTab("output"),
  },

  {
    id: "copy-row",
    also: "clipboard",
    title: "Copy the row",
    group: "Copy",
    keys: ["Mod-c"],
    run: act.copyCursorRow,
    when: () => get().cursor !== null && !selectionInQuery(),
  },
  {
    id: "copy-command",
    also: "clipboard script cron",
    title: "Copy the command that does it again",
    group: "Copy",
    run: () => void act.copyText(act.again().line, "the command"),
  },
];

for (let n = 1; n <= 9; n++) {
  COMMANDS.push({
    id: `order-${n}`,
    title: `Order by column ${n}, again for the other way`,
    group: "Order",
    keys: [`Ctrl-${n}`],
    run: () => {
      const column = visibleColumns()[n - 1];
      if (column !== undefined) act.cycleOrder(column);
    },
    when: () => visibleColumns().length >= n,
    quiet: true,
  });
}

/** The columns shown, in order: what ⌃1 to ⌃9 count. */
export function visibleColumns(): number[] {
  const { hidden } = get();
  return table.columns.map((_, at) => at).filter((at) => !hidden.has(at));
}

/** The palette's commands: the fixed ones and one for each thing a column offers. */
export function paletteCommands(): Command[] {
  const fixed = COMMANDS.filter((c) => !c.quiet);
  const columns: Command[] = table.columns.flatMap((name, column) => [
    {
      id: `sort:${column}`,
      title: `Order by ${name}, smallest or A first`,
      also: "sort ascending",
      group: "Order",
      run: () => act.setOrder({ column, descending: false }),
    },
    {
      id: `sort-down:${column}`,
      title: `Order by ${name}, largest or Z first`,
      also: "sort descending reverse",
      group: "Order",
      run: () => act.setOrder({ column, descending: true }),
    },
    {
      id: `column:${column}`,
      title: `Look at the column ${name}`,
      also: "histogram chart values",
      group: "Panels",
      run: () => act.showColumn(column),
    },
    {
      id: `field:${column}`,
      title: `Send the column ${name} (or stop sending it)`,
      also: "field output only",
      group: "Send",
      run: () => act.toggleField(name),
    },
    {
      id: `hide:${column}`,
      title: `${get().hidden.has(column) ? "Show" : "Hide"} the column ${name}`,
      group: "Panels",
      run: () => {
        const hidden = new Set(get().hidden);
        if (hidden.has(column)) hidden.delete(column);
        else hidden.add(column);
        set({ hidden });
      },
    },
  ]);
  return [...fixed, ...columns];
}
