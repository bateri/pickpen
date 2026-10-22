/**
 * The view's state: what the person typed and marked, where the cursor is, what is open.
 * The rows themselves are in `data.ts`; `version` moves when they change.
 */

import { create } from "zustand";

import type { Boot } from "../../shared/wire";
import type { Order } from "./data";

export type Tab = "row" | "column" | "output";

export type MenuItem =
  | { label: string; keys?: string; run: () => void; disabled?: boolean; danger?: boolean }
  | { separator: true };

export type Overlay =
  | { kind: "palette" }
  | { kind: "help" }
  | { kind: "menu"; at: { x: number; y: number }; items: MenuItem[] };

export interface Toast {
  text: string;
  tone: "info" | "bad";
  at: number;
}

export interface State {
  boot: Boot | null;
  /** The program could not be reached, or said something the view cannot go on from. */
  error: string | null;
  /** Moves when rows come or columns change. */
  version: number;

  query: string;
  /** The rows the query matches, by place, in the order shown. */
  shown: number[];
  /** Where each row is in `shown`, or -1: by place. */
  where: Int32Array;
  order: Order | null;

  /** The row the cursor is on, by place. */
  cursor: number | null;
  marked: Set<number>;
  /** Where a ⇧-click or ⇧↑ ⇧↓ marks from. */
  anchor: number | null;

  /**
   * The cursor keeps to the last row as rows come, as `tail -f` does: on once the person goes
   * to the last row (⌘↓), off as soon as the cursor moves another way.
   */
  follow: boolean;
  /** Rows that came below while the list was not following, for the button that goes to them. */
  unseen: number;

  widths: number[];
  hidden: Set<number>;
  /** The columns that go out, as the person picked them in the view; null keeps the command line's. */
  fields: string[] | null;

  panel: { open: boolean; tab: Tab };
  panelWidth: number;
  /** The column the column panel shows. */
  column: number;

  overlay: Overlay | null;
  sending: boolean;
  /** An Esc has asked once whether to send nothing, at this time. */
  escapeAsked: number;
  toast: Toast | null;
}

export const useStore = create<State>(() => ({
  boot: null,
  error: null,
  version: 0,
  query: "",
  shown: [],
  where: new Int32Array(0),
  order: null,
  cursor: null,
  marked: new Set(),
  anchor: null,
  follow: false,
  unseen: 0,
  widths: [],
  hidden: new Set(),
  fields: null,
  panel: { open: false, tab: "output" },
  panelWidth: 360,
  column: 0,
  overlay: null,
  sending: false,
  escapeAsked: 0,
  toast: null,
}));

export const get = useStore.getState;
export const set = useStore.setState;
