# UberTabber

A UX experiment: one most-recently-used switcher for both Mac apps and Chrome tabs.

- `extension/`: Chrome extension. Reports tab/window focus events to the app; switches tabs on request. No history logic.
- `app/`: Swift menu-bar app. Watches app activation, receives tab events on `ws://127.0.0.1:47821`, keeps the merged history.

History rule: whatever becomes active moves to the top. Chrome itself never appears in the list; its tabs stand in for it.

## Run

1. Build and launch the app (a stack icon appears in the menu bar):

   ```bash
   ~/Projects/UberTabber/app/bundle.sh
   ```

   The first time, macOS asks for Accessibility permission (System Settings → Privacy & Security → Accessibility → UberTabber). Option-Tab starts working a couple of seconds after it's granted.
   `swift run` still works for quick menu-only testing, but the hotkey needs the bundled app.

2. Load the extension once: open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, choose the `extension/` folder.
   The extension reconnects by itself whenever the app is running (within ~30s).

3. Option-Tab opens the switcher (after a short delay, so a quick tap just toggles). The strip shows the 8 most recent windows and tabs; the second is selected.
   - Tab / Shift-Tab or arrows move; releasing Option (or Return, or a click) switches; Esc clears typing, then cancels.
   - Reaching the third item, pressing ↓, or typing opens a list of everything else below the strip, least used at the bottom.
   - Typing filters both. While the list is open the mic listens: saying a name highlights the best match (it never switches by itself).
   The menu-bar icon shows the same history; clicking an entry switches to it.

## Log

Every event is appended to `~/Library/Application Support/UberTabber/events.jsonl` (menu: **Show Log in Finder**). It contains page titles and URLs and stays local.
