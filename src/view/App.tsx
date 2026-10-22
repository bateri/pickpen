import { useEffect, useState } from "react";

import { Bar } from "./components/Bar";
import { Help } from "./components/Help";
import { MenuLayer } from "./components/Menu";
import { Palette } from "./components/Palette";
import { Panel } from "./components/Panel";
import { QueryBar } from "./components/QueryBar";
import { Rows } from "./components/Rows";
import { Mark } from "./components/ui";
import { useStore } from "./state/store";

/** Below this width the side panel lies over the rows instead of beside them. */
const NARROW = 760;

export function App() {
  const boot = useStore((s) => s.boot);
  const error = useStore((s) => s.error);
  const overlay = useStore((s) => s.overlay);
  const panel = useStore((s) => s.panel);
  const panelWidth = useStore((s) => s.panelWidth);
  const sending = useStore((s) => s.sending);
  const toast = useStore((s) => s.toast);
  const narrow = useWidth() < NARROW;

  if (error !== null && boot === null) {
    return (
      <div className="app empty-state">
        <Mark size={28} />
        <p>{error}</p>
      </div>
    );
  }
  if (boot === null) {
    return (
      <div className="app empty-state">
        <Mark size={28} />
        <p className="quiet">Waiting for the program…</p>
      </div>
    );
  }
  return (
    <div className="app" data-narrow={narrow} data-sending={sending}>
      <QueryBar />
      <div
        className="body"
        style={{
          gridTemplateColumns:
            panel.open && !narrow ? `minmax(0, 1fr) ${panelWidth}px` : "minmax(0, 1fr)",
        }}
      >
        <Rows />
        {panel.open ? <Panel narrow={narrow} /> : null}
      </div>
      <Bar />
      {overlay?.kind === "palette" ? <Palette /> : null}
      {overlay?.kind === "help" ? <Help /> : null}
      <MenuLayer />
      {toast ? (
        <div key={toast.at} className="toast" data-tone={toast.tone} role="status">
          {toast.text}
        </div>
      ) : null}
      {error !== null ? <div className="banner">{error}</div> : null}
    </div>
  );
}

function useWidth(): number {
  const [width, setWidth] = useState(window.innerWidth);
  useEffect(() => {
    const resize = () => setWidth(window.innerWidth);
    window.addEventListener("resize", resize);
    return () => window.removeEventListener("resize", resize);
  }, []);
  return width;
}
