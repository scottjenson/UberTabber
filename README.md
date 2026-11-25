# UberTabber

A UX experiment: one most-recently-used switcher for Mac app windows **and** Chrome tabs.

macOS switches between apps (Cmd-Tab) and Chrome switches between tabs, but nothing switches between "the things I'm working on" when some are windows and some are tabs. UberTabber treats them the same: an Option-Tab switcher, styled after Cmd-Tab, whose history mixes app windows and Chrome tabs in the order you used them.

This is an experiment, not a product. Expect rough edges.

## Requirements

- macOS 14 or later (developed on macOS 26)
- Google Chrome
- Xcode or the Xcode Command Line Tools (for `swift`)

## Install

1. **Build and launch the app.** A stack icon appears in the menu bar.

   ```bash
   git clone https://github.com/scottjenson/UberTabber.git
   cd UberTabber/app && ./bundle.sh
   ```

   `bundle.sh` builds `app/build/UberTabber.app`, signs it locally, and (re)launches it. Run it again after any code change.

2. **Grant permissions** when macOS asks:
   - **Accessibility** (System Settings → Privacy & Security → Accessibility → UberTabber): needed for the Option-Tab hotkey, tracking windows and switching. Option-Tab starts working a couple of seconds after it's granted.
   - **Speech Recognition** and **Microphone**: optional, for voice. Without them everything else works.

3. **Load the Chrome extension** (once): open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and choose the `extension/` folder. Chrome will ask for access to all websites; that's used to find each site's large icon. The extension connects to the app by itself within about 30 seconds (or click its reload button).

## Using it

**Option-Tab** opens the switcher after a short delay, so a quick tap-and-release just flips back to what you were last doing, with no flash.

- **The strip** shows the 8 most recent items, with the second one selected. Each app window and each Chrome tab is its own item; Chrome itself never appears, its tabs stand in for it. Apps with no open windows appear once, by name.
- **Move** with Tab / Shift-Tab, the arrow keys, or the mouse (moving the pointer over an item selects it, and the keyboard carries on from there).
- **Switch** by releasing Option, pressing Return, or clicking. **Esc** cancels.

**Finding older items.** Pausing on the strip for half a second (each key press restarts the wait, so steady tabbing doesn't trigger it), pressing ↓, or typing drops down a list of everything else under the strip, in order of use, with things you haven't touched since launch at the bottom (including every open Chrome tab).

- **Type** to search everything. The strip stays put (dimmed) and the results appear in the list, best match first and selected. Once you've typed, you can let go of Option; the switcher stays open until Return, a click, or Esc. Backspace edits, Esc clears the search, a second Esc closes.
- **Say** a name while the list is open (the mic icon turns red). Voice highlights the best match, in the strip or the list, but never switches by itself: release Option to confirm. The mic only runs while the list is open, and recognition happens on your Mac.

**Matching** favors what you'd call something: a tab's title (without the site name), the start of a window's title, or the app's name. Saying or typing "projects" finds a Finder window called *Projects* before a tab called *Stitch - Projects*. Matching is at the start of words and ignores plurals ("project" finds "Projects").

The **menu-bar icon** shows the extension's connection status and the same history; clicking an entry switches to it. Its **Use Command-Tab instead of Option-Tab** item replaces Apple's switcher with UberTabber (everything above then works with Command in place of Option). It's remembered across launches, and Apple's Command-Tab returns whenever UberTabber isn't running.

## Known limitations

- Chrome only (no Safari, Firefox or Arc yet). Tabs in other Chrome profiles need the extension loaded in each profile.
- Windows on other Spaces may not appear until you've visited them.
- Switching to a window or tab in another app can briefly show that app's previous front window.
- Large site icons are cached in memory only, so the first Option-Tab after launch may show small favicons.
- If Option-Tab stops responding after a rebuild, remove UberTabber from the Accessibility list and add it back.

## How it works

- `extension/`: Chrome extension (Manifest V3). Reports tab and window focus events, tab titles and each site's largest icon to the app over a local WebSocket (`ws://127.0.0.1:47821`), and switches tabs when asked. No history logic.
- `app/`: Swift menu-bar app. Tracks app windows through the Accessibility API, merges them with the extension's tab events into one most-recently-used history, and draws the switcher. Whatever becomes active moves to the top.

## Privacy

Everything stays on your Mac. Every event is appended to `~/Library/Application Support/UberTabber/events.jsonl` (menu: **Show Log in Finder**); it includes page titles and URLs. Speech is recognized on-device, and the microphone only runs while the list is open.
