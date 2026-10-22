/**
 * The keyboard: one listener on the window, ahead of everything (capture). What is typed goes
 * to the query, wherever the focus was; the keys of the commands run them, before the browser
 * can move the focus (Tab), select the text (⌘A) or move the caret (⌘↑).
 *
 * ⌃C is never taken: it is the program's, and the terminal sends it there whatever the view
 * does. What is over the list (the palette, a menu) takes its own keys.
 */

import { matches, typing } from "../lib/keys";
import { focusQuery } from "./actions";
import { COMMANDS } from "./commands";
import { get, set } from "./store";

export function onKeyDown(event: KeyboardEvent): void {
  if (event.defaultPrevented || event.isComposing) return;
  if (event.ctrlKey && !event.metaKey && event.key.toLowerCase() === "c") return;
  const state = get();
  if (state.sending) {
    event.preventDefault();
    return;
  }
  if (state.overlay !== null) {
    if (state.overlay.kind === "help" && (event.key === "Escape" || event.key === "F1")) {
      event.preventDefault();
      set({ overlay: null });
      focusQuery();
    }
    return;
  }
  for (const command of COMMANDS) {
    if (!command.keys?.some((key) => matches(event, key))) continue;
    if (command.when && !command.when()) continue;
    event.preventDefault();
    event.stopPropagation();
    command.run();
    return;
  }
  // A key that types, with the focus elsewhere (a button, the list after a click): it is
  // the query's, and focusing it now lets the browser put the character there.
  const types = event.key.length === 1 && !event.metaKey && !event.ctrlKey;
  if (types && !typing(event.target)) focusQuery();
}
