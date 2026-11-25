import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let history = History()
    private let server = ExtensionServer()
    private let log = EventLog()
    private let icons = IconStore()
    private let hotKey = HotKey()
    private let switcher = SwitcherPanel()
    private var shownItems: [HistoryItem] = []
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

        history.seed()
        print("UberTabber running. Logging to \(log.url.path)")

        hotKey.onShow = { [weak self] reverse in self?.showSwitcher(reverse: reverse) }
        hotKey.onMove = { [weak self] delta in self?.switcher.move(delta) }
        hotKey.onCommit = { [weak self] in self?.commitSwitcher() }
        hotKey.onCancel = { [weak self] in self?.switcher.hide() }
        hotKey.start()
    }

    // MARK: Switcher

    private func showSwitcher(reverse: Bool) {
        shownItems = Array(history.items.prefix(8))
        guard !shownItems.isEmpty else { return }
        let selected = shownItems.count < 2 ? 0 : (reverse ? shownItems.count - 1 : 1)
        switcher.show(shownItems.map(tile), selected: selected)
    }

    private func commitSwitcher() {
        switcher.hide()
        let index = switcher.model.selected
        guard index < shownItems.count else { return }
        switchTo(shownItems[index])
    }

    private func tile(for item: HistoryItem) -> Tile {
        switch item {
        case .app(let pid):
            let app = NSRunningApplication(processIdentifier: pid)
            return Tile(title: app?.localizedName ?? "", icon: .app(app?.icon))
        case .tab(let id):
            guard let tab = history.tabs[id] else { return Tile(title: "Tab", icon: .tab(large: nil, favicon: nil, tint: nil)) }
            return Tile(title: tab.shortTitle,
                        icon: .tab(large: icons.largeIcon(host: tab.host),
                                   favicon: icons.favicon(tab.favIconUrl),
                                   tint: icons.tint(tab.favIconUrl)))
        }
    }

    private func switchTo(_ item: HistoryItem) {
        switch item {
        case .app(let pid):
            bringToFront(pid)
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
            let menuItem = NSMenuItem(title: "", action: #selector(select(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            switch item {
            case .app(let pid):
                let app = NSRunningApplication(processIdentifier: pid)
                menuItem.title = app?.localizedName ?? "pid \(pid)"
                menuItem.image = app?.icon.map { icon in
                    let small = icon.copy() as! NSImage
                    small.size = NSSize(width: 16, height: 16)
                    return small
                }
            case .tab(let id):
                let tab = history.tabs[id]
                let host = tab.flatMap { URL(string: $0.url)?.host } ?? ""
                let title = tab.map { $0.title.isEmpty ? $0.url : $0.title } ?? "Tab \(id)"
                menuItem.title = String(title.prefix(60)) + (host.isEmpty ? "" : "  —  \(host)")
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
