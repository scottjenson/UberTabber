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
            self?.log.write(["type": "appTerminated", "bundleId": app.bundleIdentifier ?? "", "name": app.localizedName ?? ""])
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
        hotKey.useCommand = UserDefaults.standard.bool(forKey: Self.useCommandKey)
        switcher.model.listAnimation = ListAnimation(rawValue: UserDefaults.standard.integer(forKey: Self.listAnimationKey)) ?? .slide
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
        // The strip appears after 0.15 s; the list follows after a further pause.
        scheduleList(after: 0.15 + Self.listDelay)
    }

    /// The list drops down once you pause on the strip (you're looking, not
    /// tabbing); every key press restarts the wait.
    private static let listDelay = 0.5
    private var listTimer: DispatchWorkItem?

    private func scheduleList(after delay: TimeInterval) {
        listTimer?.cancel()
        guard !switcher.model.listVisible else { return }
        let work = DispatchWorkItem { [weak self] in self?.revealList() }
        listTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handleKey(_ key: HotKey.Key) {
        let model = switcher.model
        switcher.present()
        scheduleList(after: Self.listDelay)
        switch key {
        case .tab(let reverse): move(reverse ? -1 : 1)
        case .left: move(-1)
        case .right: move(1)
        case .down:
            revealList()
            if model.selected < SwitcherModel.stripCount {
                if !model.rows.isEmpty { model.selected = SwitcherModel.stripCount }
            } else {
                move(1)
            }
        case .up:
            if model.selected >= SwitcherModel.stripCount { move(-1) }
        case .escape:
            if model.searching {
                stopSearching()
            } else {
                hotKey.dismiss()
                closeSwitcher()
            }
        case .delete:
            guard model.searching else { break }
            model.query.removeLast()
            if model.searching { model.selected = SwitcherModel.stripCount } else { stopSearching() }
        case .enter:
            hotKey.dismiss()
            commitSwitcher()
        case .character(let text):
            revealList()
            hotKey.sticky = true
            model.query += text.lowercased()
            model.selected = SwitcherModel.stripCount  // the best match, first row
        }
    }

    /// Back to browsing: selection returns to the strip.
    private func stopSearching() {
        let model = switcher.model
        model.query = ""
        model.selected = min(1, model.strip.count - 1)
    }

    private func move(_ delta: Int) {
        let model = switcher.model
        let order = model.selectable
        guard !order.isEmpty else { return }
        let position = order.firstIndex(of: model.selected) ?? 0
        // Browsing wraps around; results stop at the ends.
        let next = model.searching
            ? min(max(position + delta, 0), order.count - 1)
            : (position + delta + order.count) % order.count
        model.selected = order[next]
    }

    private func revealList() {
        let model = switcher.model
        guard !model.listVisible else { return }
        model.listVisible = true
        voice.start(hints: model.all.map(\.label))
        model.listening = voice.isListening
    }

    /// Voice highlights the best match wherever it is (or among typed results);
    /// it never switches.
    private func heard(_ text: String) {
        let model = switcher.model
        guard model.listVisible else { return }
        if model.searching {
            if let row = Matcher.best(model.rows, text) { model.selected = SwitcherModel.stripCount + row }
        } else if let index = Matcher.best(model.all, text) {
            // Unfiltered, index i in `all` is tile i or row i - 8, which is selection index i.
            model.selected = index
        }
    }

    private func closeSwitcher() {
        listTimer?.cancel()
        voice.stop()
        switcher.model.listening = false
        switcher.hide()
    }

    private func commitSwitcher() {
        let chosen = switcher.model.entry(at: switcher.model.selected)
        closeSwitcher()
        if let chosen { switchTo(chosen.item) }
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
        let shortcut = NSMenuItem(title: "Use Command-Tab instead of Option-Tab",
                                  action: #selector(toggleShortcut), keyEquivalent: "")
        shortcut.target = self
        shortcut.state = hotKey.useCommand ? .on : .off
        menu.addItem(shortcut)
        let animations = NSMenu()
        for style in ListAnimation.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(chooseListAnimation(_:)), keyEquivalent: "")
            item.target = self
            item.tag = style.rawValue
            item.state = switcher.model.listAnimation == style ? .on : .off
            animations.addItem(item)
        }
        let animationItem = NSMenuItem(title: "List Animation", action: nil, keyEquivalent: "")
        animationItem.submenu = animations
        menu.addItem(animationItem)
        let reveal = NSMenuItem(title: "Show Log in Finder", action: #selector(revealLog), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(NSMenuItem(title: "Quit UberTabber", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func select(_ sender: NSMenuItem) {
        guard sender.tag < history.items.count else { return }
        switchTo(history.items[sender.tag])
    }

    private static let useCommandKey = "useCommandTab"

    private static let listAnimationKey = "listAnimation"

    @objc private func chooseListAnimation(_ sender: NSMenuItem) {
        guard let style = ListAnimation(rawValue: sender.tag) else { return }
        switcher.model.listAnimation = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.listAnimationKey)
    }

    @objc private func toggleShortcut() {
        hotKey.useCommand.toggle()
        UserDefaults.standard.set(hotKey.useCommand, forKey: Self.useCommandKey)
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([log.url])
    }
}
