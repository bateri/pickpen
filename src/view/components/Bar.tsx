/**
 * The bottom line: what the keys do here, each a button that does the same, and the two
 * answers, Send nothing and Send, the second saying what it would send.
 */

import { IconArrowBackUp, IconSend } from "@tabler/icons-react";

import * as act from "../state/actions";
import { set, useStore } from "../state/store";
import { Button, Keys, count, keepFocus, plural } from "./ui";

function Hint({ spec, label, run }: { spec: string; label: string; run: () => void }) {
  return (
    <button type="button" className="hint" onMouseDown={keepFocus} onClick={run} tabIndex={-1}>
      <Keys spec={spec} quiet /> {label}
    </button>
  );
}

export function Bar() {
  const boot = useStore((s) => s.boot)!;
  const marked = useStore((s) => s.marked);
  const cursor = useStore((s) => s.cursor);
  const sending = useStore((s) => s.sending);
  useStore((s) => s.where);
  const rows = act.toSend();
  const hidden = marked.size > 0 ? act.hiddenMarks() : 0;

  let label: string;
  if (sending) label = "Sending…";
  else if (marked.size > 0)
    label = `Send ${plural(marked.size, "row")}${hidden > 0 ? ` (${count(hidden)} not shown)` : ""}`;
  else if (boot.confirm) label = "Mark the rows to send";
  else if (cursor !== null) label = "Send this row";
  else label = "Send";

  return (
    <footer className="bar">
      <div className="hints">
        <Hint spec="Tab" label="mark" run={() => act.markAndMove(1)} />
        <Hint spec="Enter" label="send" run={() => void act.send()} />
        <Hint spec="Escape" label="back" run={act.back} />
        <Hint spec="Mod-k" label="commands" run={() => set({ overlay: { kind: "palette" } })} />
        <Hint spec="F1" label="help" run={() => set({ overlay: { kind: "help" } })} />
      </div>
      <div className="answers">
        <Button
          tone="quiet"
          onClick={() => void act.cancel()}
          disabled={sending}
          label="Send nothing and end"
        >
          <IconArrowBackUp size={14} stroke={1.8} /> Send nothing
        </Button>
        <Button
          tone="primary"
          onClick={() => void act.send()}
          disabled={sending || rows.length === 0}
          keys="Enter"
          className={hidden > 0 ? "warned" : undefined}
        >
          <IconSend size={14} stroke={1.8} /> {label}
        </Button>
      </div>
    </footer>
  );
}
