import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let history = History()
    private let server = ExtensionServer()
    private let log = EventLog()
    private let icons = IconStore()
    private let hotKey = HotKey()
    private let switcher = SwitcherPanel()
    private let voice = Voice()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "UberTabber")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.log.write(["type": "appActivated", "bundleId": app.bundleIdentifier ?? "", "name": app.localizedName ?? ""])
            self?.history.appActivated(app)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.history.appTerminated(app)
        }

        server.onMessage = { [weak self] in self?.handle($0) }
        server.onConnectionChange = { [weak self] connected in
            self?.log.write(["type": connected ? "extensionConnected" : "extensionDisconnected"])
        }
        do {
            try server.start()
        } catch {
            print("Could not start extension server: \(error)")
        }

        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.history.appLaunched(app)
        }

        history.seed()
        print("UberTabber running. Logging to \(log.url.path)")

        hotKey.onShow = { [weak self] reverse in self?.showSwitcher(reverse: reverse) }
        hotKey.onKey = { [weak self] key in self?.handleKey(key) }
        hotKey.onCommit = { [weak self] in self?.commitSwitcher() }
        hotKey.start()

        switcher.model.onClick = { [weak self] index in
            self?.hotKey.dismiss()
            self?.switcher.model.selected = index
            self?.commitSwitcher()
        }
        voice.onTranscript = { [weak self] text in self?.heard(text) }
        voice.requestPermission()
    }

    // MARK: Switcher

    private func showSwitcher(reverse: Bool) {
        let entries = history.allItems().map(entry)
        guard !entries.isEmpty else { return }
        let stripCount = min(entries.count, SwitcherModel.stripCount)
        let selected = entries.count < 2 ? 0 : (reverse ? stripCount - 1 : 1)
        switcher.open(entries, selected: selected)
    }

    private func handleKey(_ key: HotKey.Key) {
        let model = switcher.model
        switcher.present()
        switch key {
        case .tab(let reverse): move(reverse ? -1 : 1)
        case .left: move(-1)
        case .right: move(1)
        case .down:
            revealList()
            if model.selected < SwitcherModel.stripCount {
                if model.visible.count > SwitcherModel.stripCount { model.selected = SwitcherModel.stripCount }
            } else {
                move(1)
            }
        case .up:
            if model.selected >= SwitcherModel.stripCount { move(-1) }
        case .escape:
            if model.query.isEmpty {
                hotKey.dismiss()
                closeSwitcher()
            } else {
                model.query = ""
                model.selected = 0
            }
        case .delete:
            if !model.query.isEmpty {
                model.query.removeLast()
                model.selected = 0
            }
        case .enter:
            hotKey.dismiss()
            commitSwitcher()
        case .character(let text):
            revealList()
            model.query += text.lowercased()
            model.selected = 0
        }
    }

    private func move(_ delta: Int) {
        let model = switcher.model
        let count = model.visible.count
        guard count > 0 else { return }
        model.selected = (model.selected + delta + count) % count
        // Reaching the third item means you're hunting, not toggling.
        if model.selected >= 2 { revealList() }
    }

    private func revealList() {
        let model = switcher.model
        guard !model.listVisible else { return }
        model.listVisible = true
        voice.start(hints: model.all.map(\.label))
        model.listening = voice.isListening
    }

    /// Voice highlights the best match among what's visible; it never switches.
    private func heard(_ text: String) {
        let model = switcher.model
        guard model.listVisible else { return }
        if let index = Matcher.best(model.visible, text) { model.selected = index }
    }

    private func closeSwitcher() {
        voice.stop()
        switcher.model.listening = false
        switcher.hide()
    }

    private func commitSwitcher() {
        let model = switcher.model
        let visible = model.visible
        closeSwitcher()
        guard model.selected < visible.count else { return }
        switchTo(visible[model.selected].item)
    }

    private func entry(for item: HistoryItem) -> Entry {
        switch item {
        case .app(let pid):
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? ""
            return Entry(item: item, label: name, title: name, subtitle: "No open windows", icon: .app(app?.icon),
                         names: [name], rest: "")
        case .window(let pid, let id):
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? ""
            let title = history.windows.windows[id]?.title ?? ""
            // Under a tile, the app name is enough unless the app has several windows.
            let label = history.windows.count(of: pid) > 1 && !title.isEmpty ? title : name
            // "History.swift — UberTabber" is called "History.swift" (or by its app).
            let firstPart = title.replacingOccurrences(of: " [-–—|] .*", with: "", options: .regularExpression)
            return Entry(item: item, label: label, title: title.isEmpty ? name : title, subtitle: name, icon: .app(app?.icon),
                         names: [firstPart, name], rest: title)
        case .tab(let id):
            let tab = history.tabs[id]
            return Entry(item: item,
                         label: tab?.shortTitle ?? "Tab",
                         title: tab.map { $0.title.isEmpty ? $0.url : $0.title } ?? "Tab",
                         subtitle: tab?.host ?? "",
                         icon: .tab(large: tab.flatMap { icons.largeIcon(host: $0.host) },
                                    favicon: icons.favicon(tab?.favIconUrl),
                                    tint: icons.tint(tab?.favIconUrl)),
                         names: [tab?.shortTitle ?? ""],
                         rest: "\(tab?.title ?? "") \(tab?.host ?? "")")
        }
    }

    private func switchTo(_ item: HistoryItem) {
        switch item {
        case .app(let pid):
            bringToFront(pid)
        case .window(let pid, let id):
            bringToFront(pid)
            history.windows.raise(id)
        case .tab(let id):
            guard let tab = history.tabs[id] else { return }
            server.send(["cmd": "activate", "tabId": tab.id, "windowId": tab.windowId])
            if let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: History.chromeBundleID).first {
                bringToFront(chrome.processIdentifier)
            }
        }
    }

    /// NSRunningApplication.activate() is unreliable from a background app on
    /// macOS 14+, so ask Accessibility to make the app frontmost instead.
    private func bringToFront(_ pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.unhide()
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String, type != "ping" else { return }
        var entry = msg
        entry["source"] = "chrome"
        log.write(entry)

        if let tab = TabInfo(msg["tab"]) { icons.prefetchFavicon(tab.favIconUrl) }

        switch type {
        case "snapshot":
            let tabs = (msg["tabs"] as? [Any] ?? []).compactMap(TabInfo.init)
            tabs.forEach { icons.prefetchFavicon($0.favIconUrl) }
            history.snapshot(tabs, lastFocusedWindowId: msg["lastFocusedWindowId"] as? Int)
        case "siteIcon":
            if let origin = msg["origin"] as? String, let host = URL(string: origin)?.host,
               let url = msg["iconUrl"] as? String {
                icons.siteIcon(host: host, url: url)
            }
        case "tabActivated":
            if let tab = TabInfo(msg["tab"]) { history.tabActivated(tab) }
        case "windowFocused":
            if let tab = TabInfo(msg["tab"]) { history.windowFocused(tab) }
        case "tabUpdated":
            if let tab = TabInfo(msg["tab"]) { history.tabUpdated(tab) }
        case "tabRemoved":
            if let id = msg["tabId"] as? Int { history.tabRemoved(id) }
        default:
            break
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = server.isConnected ? "Chrome extension connected" : "Chrome extension not connected"
        menu.addItem(NSMenuItem(title: status, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        for (index, item) in history.items.prefix(20).enumerated() {
            let entry = entry(for: item)
            let menuItem = NSMenuItem(title: String(entry.title.prefix(60)) + "  —  \(entry.subtitle)",
                                      action: #selector(select(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            if case .app(let icon?) = entry.icon {
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                menuItem.image = small
            } else {
                menuItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            }
            menu.addItem(menuItem)
        }

        menu.addItem(.separator())
        let reveal = NSMenuItem(title: "Show Log in Finder", action: #selector(revealLog), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(NSMenuItem(title: "Quit UberTabber", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard sender.tag < history.items.count else { return }
        switchTo(history.items[sender.tag])
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([log.url])
    }
}
