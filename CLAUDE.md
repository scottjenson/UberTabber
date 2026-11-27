# CLAUDE.md

UberTabber is a **UX experiment, not a product**: one most-recently-used switcher (Option-Tab, styled after macOS Cmd-Tab) that treats Mac app windows and Chrome tabs as the same kind of thing. The goal is to feel out the interaction, so favor small, simple changes that are easy to try and revert. See README.md for the user-facing description.

## Layout

- `extension/`: Chrome extension (MV3, `background.js` only). Reports raw tab/window events and each site's large icon to the app over a WebSocket (`ws://127.0.0.1:47821`) and performs `activate` commands. **No history logic here**; the app owns it.
- `app/`: Swift package (tools 5.9, macOS 14+), menu-bar app (`.accessory`, `LSUIElement`).
  - `AppDelegate.swift`: wiring. Switcher key handling, list reveal timer, voice hookup, switching (`switchTo`), extension message handling, menu-bar menu.
  - `History.swift`: the MRU list (`HistoryItem`: `.app(pid)` for windowless apps, `.window(pid, id)`, `.tab(id)`), launch seeding, all event handlers, `allItems()` (history, then never-used windows/apps/tabs).
  - `WindowTracker.swift`: per-app `AXObserver`s; maps AX windows to `CGWindowID` via private `_AXUIElementGetWindow`. Standard windows only.
  - `HotKey.swift`: `CGEvent` tap. Option-Tab (or Command-Tab, menu toggle); swallows all keys while open; modifier release commits unless `sticky` (set once you type). `UCKeyTranslate` gets un-modified characters.
  - `Switcher.swift`: `SwitcherModel` + SwiftUI views in a non-activating `NSPanel`. Strip of 8 tiles + drop-down list.
  - `Matcher.swift`: tiered name-first ranking for typing and voice.
  - `Voice.swift`: on-device `SFSpeechRecognizer`; fresh `AVAudioEngine` per listen (see gotchas).
  - `IconStore.swift`, `EventLog.swift`: icon caches, JSONL log.
  - `ExtensionServer.swift`: WebSocket server. Accepts only `Origin: chrome-extension://…` (any web page can open a socket to localhost); rejections log `extensionRejected`.

## Build and run

```bash
cd app && ./bundle.sh
```

Builds release, assembles `app/build/UberTabber.app` (Info.plist with mic/speech usage strings), ad-hoc signs it with designated requirement `identifier "org.jenson.UberTabber"` (so Accessibility permission survives rebuilds), kills the old copy, waits, and relaunches. stdout isn't visible (launched with `open`); debug through the event log.

After editing `extension/`, the user must click reload in `chrome://extensions` (bump `manifest.json` version). Extension errors show under the card's **Errors** button.

There are no tests. The user tests by hand; don't spin up screenshots for simple changes.

## Debugging

`~/Library/Application Support/UberTabber/events.jsonl` logs every extension message plus `appActivated`, `appTerminated`, `activateTab`, `extensionConnected`, `extensionRejected`. Analyze it with a small Python script. To see who holds the microphone, query CoreAudio `kAudioHardwarePropertyProcessObjectList` / `kAudioProcessPropertyIsRunningInput` (this once showed the orange dot was System Settings' Sound pane, not us).

## UX decisions (made by the user; don't relitigate without asking)

- **Option-Tab** by default so Apple's Cmd-Tab stays available for comparison; menu toggle "Use Command-Tab instead of Option-Tab" (UserDefaults `useCommandTab`).
- **Looks like Cmd-Tab**: solid `#9F9F9F` backdrop (measured), radius 58; tiles `square = 117` with icons drawn on a `canvas = 128` to absorb app icons' built-in margin; only the selected tile is labeled, truncated within the tile plus its gaps. A window's label is its title's first part (app name if untitled), like a tab's; the icon says which app. Tab icons inset to 0.81 like app artwork. **No Chrome badge**: blurring tab vs. window is the point.
- **Strip of 8**, most recent first, second item selected; Chrome itself never appears (its tabs stand in). Each app window is its own item ("windows everywhere"); apps with no windows appear once (Finder must, so you needn't open a window first). **Menu-bar apps appear only through their windows**, never on their own.
- **Show delay 150 ms** so a quick tap-and-release switches with no flash.
- **List reveal**: after a further **500 ms pause** (every key press restarts the timer, so steady tabbing never shows it), or immediately on ↓ or typing. Replaced an earlier "reveal on reaching the third item" rule the user found clunky.
- **List animation**: slides down from behind the strip with a small spring overshoot (`.spring(duration: 0.25, bounce: 0.25)`), no fade or stagger. Other variants were tried and removed; keep only this one.
- **List order**: recency; never-used items at the bottom.
- **Typing** works anytime. The strip stays unchanged but dimmed (0.4); results appear only in the list, best first (showing strip items again there is fine). Once you type, releasing the modifier doesn't close; Return/click/Esc does. Esc clears the search, a second Esc closes.
- **Voice** listens only while the list is open (avoid misfires in meetings). It **highlights, never switches**; release to confirm.
- **Matching is name-first; recency never beats name quality**. Tiers: exact name 500, name prefix 400, all words in names 300, all words anywhere 200 (filter threshold), then partial. Word-start matching, plural-tolerant, split compounds tried joined. Names: tab `shortTitle` (site name stripped), window title's first part and app name.
- **Mouse hover selects** (ignores a pointer that hasn't moved since open), and the keyboard continues from the hovered item; click switches.

## Gotchas learned the hard way

- **Chrome tab IDs change** when Chrome unloads long-unused tabs (Memory Saver). The extension handles `onReplaced` and, if an `activate` ID is stale, falls back to the tab with the same URL and reports `tabReplaced`; truly gone tabs report `activateFailed` and trigger a snapshot. Users leave tabs for days, so this must stay robust.
- **Quit apps can linger** via late notifications; `History.allItems()` prunes items whose process is gone.
- **Mic indicator**: a long-lived `AVAudioEngine` that has touched the input keeps the mic claimed; create one per listen and release it.
- **`NSRunningApplication.activate()` is unreliable** from a background app; use AX `kAXFrontmostAttribute`, then `kAXRaiseAction`/`kAXMainAttribute` for a specific window.
- **Launch Services error -600** if relaunching too fast; `bundle.sh` waits for exit plus 1 s.
- **Swift type-check timeouts** on long tuple/closure chains (happened in `Matcher.filter`); split into simple steps.
- Only `.regular` activation-policy apps count (filters things like `universalAccessAuthWarn`), and **policy changes at runtime**, so `pruneQuitApps()` rechecks on every open. Shottr is regular only while showing a window. ExpressVPN is the reverse: `LSUIElement` in its Info.plist but turns itself regular and stays that way, and with no window it can't even be brought forward; `isMenuBarApp` drops its windowless entry.
- **Event tap shares the main thread with AX calls** to other apps. A hung app would stall every keystroke system-wide, so the global AX messaging timeout is set to 0.25 s at launch.
- **Rejected WebSocket handshakes** leave the `NWConnection` `.ready`, and `receiveMessage` returns no data and no WebSocket metadata. Treat missing metadata as end of stream, or the receive loop spins.

## Known open issues / ideas (none requested yet)

- Switching to another app's window can briefly flash that app's previous front window.
- Windows on other Spaces may not appear until visited.
- Large site icons cached in memory only (first open after launch may show small favicons).
- Chrome only; other profiles need the extension loaded separately.
- Ideas floated: log analysis script, tab snapshots instead of icons, repeat-to-cycle for voice (user wanted to see if tiers suffice first).
