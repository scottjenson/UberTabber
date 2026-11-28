import AppKit

struct TabInfo {
    let id: Int
    var windowId: Int
    var index: Int
    var title: String
    var url: String
    var favIconUrl: String?
    var active: Bool
    var profile: String     // which Chrome profile's extension reported it

    var host: String { URL(string: url)?.host ?? "" }

    init?(_ dict: Any?) {
        guard let d = dict as? [String: Any],
              let id = d["id"] as? Int,
              let windowId = d["windowId"] as? Int else { return nil }
        self.id = id
        self.windowId = windowId
        self.index = d["index"] as? Int ?? 0
        self.title = d["title"] as? String ?? ""
        self.url = d["url"] as? String ?? ""
        self.favIconUrl = d["favIconUrl"] as? String
        self.active = d["active"] as? Bool ?? false
        self.profile = d["profile"] as? String ?? ""
    }

    /// Page title without the site name, which the icon already shows:
    /// "Q3 Planning - Google Docs" -> "Q3 Planning", "GitHub - owner/repo" -> "owner/repo".
    var shortTitle: String {
        let pieces = title.replacingOccurrences(of: " [-–—|] ", with: "\u{0}", options: .regularExpression)
            .components(separatedBy: "\u{0}")
        guard pieces.count > 1 else { return title.isEmpty ? host : title }
        let labels = host.split(separator: ".")
        let site = labels.count >= 2 ? labels[labels.count - 2].lowercased() : host.lowercased()
        if pieces[0].lowercased().contains(site) {
            return pieces.dropFirst().joined(separator: " - ")
        }
        return pieces.dropLast().joined(separator: " - ")
    }
}

enum HistoryItem: Hashable {
    case app(pid: pid_t)                        // a running app with no windows
    case window(pid: pid_t, id: CGWindowID)
    case tab(id: Int)
}

/// Most-recently-used list of app windows and Chrome tabs. Whatever becomes
/// active moves to the top. Chrome's windows never appear; its tabs stand in.
final class History {
    static let chromeBundleID = "com.google.Chrome"

    let windows = WindowTracker()
    private(set) var items: [HistoryItem] = []
    private(set) var tabs: [Int: TabInfo] = [:]
    var onChange: (() -> Void)?

    /// Where Chrome sat in the seeded list, until the extension reports its current tab.
    private var chromeSlot: Int?

    init() {
        windows.onFocus = { [weak self] in self?.windowFocused($0) }
        windows.onDestroy = { [weak self] in self?.windowDestroyed($0) }
        windows.onChange = { [weak self] in self?.onChange?() }
    }

    /// Like Cmd-Tab, only apps with a Dock icon count (no permission dialogs,
    /// helpers or menu-bar apps).
    private static func counts(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    /// Declared a menu-bar app (LSUIElement) in its Info.plist, even if it has
    /// since turned itself regular (ExpressVPN does). Such apps appear only
    /// through their windows, never on their own.
    private static func isMenuBarApp(_ pid: pid_t) -> Bool {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              let value = Bundle(url: url)?.object(forInfoDictionaryKey: "LSUIElement") else { return false }
        return (value as? Bool) ?? ((value as? String) == "1")
    }

    private var otherApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { Self.counts($0) && $0.bundleIdentifier != Self.chromeBundleID }
    }

    private func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Everything, for the switcher: the history first, then whatever has never
    /// been used since launch (windows, windowless apps, then Chrome tabs in
    /// Chrome's own order).
    func allItems() -> [HistoryItem] {
        pruneQuitApps()
        var result = items
        var seen = Set(items)
        func add(_ item: HistoryItem) {
            if seen.insert(item).inserted { result.append(item) }
        }
        windows.windows.values.sorted { $0.id < $1.id }.forEach { add(.window(pid: $0.pid, id: $0.id)) }
        otherApps.map(\.processIdentifier)
            .filter { windows.count(of: $0) == 0 && !Self.isMenuBarApp($0) }
            .forEach { add(.app(pid: $0)) }
        tabs.values.sorted { ($0.windowId, $0.index) < ($1.windowId, $1.index) }.forEach { add(.tab(id: $0.id)) }
        return result
    }

    // MARK: Mac events

    /// Fills the history at launch from the on-screen windows, front to back
    /// (the best guess at recency). Everything else shows up via allItems().
    func seed() {
        otherApps.forEach(windows.observe)
        let chromePids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: Self.chromeBundleID)
            .map(\.processIdentifier))
        let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in onScreen where info[kCGWindowLayer as String] as? Int == 0 {
            guard let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init),
                  let id = (info[kCGWindowNumber as String] as? Int).map(CGWindowID.init) else { continue }
            if chromePids.contains(pid) {
                if chromeSlot == nil { chromeSlot = items.count }
            } else if windows.windows[id] != nil, !items.contains(.window(pid: pid, id: id)) {
                items.append(.window(pid: pid, id: id))
            }
        }
        onChange?()
    }

    func appLaunched(_ app: NSRunningApplication) {
        guard Self.counts(app), app.bundleIdentifier != Self.chromeBundleID else { return }
        windows.observe(app)
        onChange?()
    }

    func appActivated(_ app: NSRunningApplication) {
        // Chrome's own activation is ignored: the extension's windowFocused
        // event says which tab is current.
        guard Self.counts(app), app.bundleIdentifier != Self.chromeBundleID else { return }
        windows.observe(app)
        let pid = app.processIdentifier
        if let window = windows.focusedWindow(of: pid) {
            touch(.window(pid: pid, id: window.id))
        } else {
            touch(.app(pid: pid))
        }
    }

    func appTerminated(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        if app.bundleIdentifier == Self.chromeBundleID {
            tabs.removeAll()
        }
        windows.forget(pid)
        items.removeAll {
            switch $0 {
            case .app(let p), .window(let p, _): return p == pid
            case .tab: return app.bundleIdentifier == Self.chromeBundleID
            }
        }
        onChange?()
    }

    private func windowFocused(_ window: WindowInfo) {
        // Background apps can shuffle their windows; only count what you're in.
        if isFrontmost(window.pid) { touch(.window(pid: window.pid, id: window.id)) }
    }

    private func windowDestroyed(_ id: CGWindowID) {
        guard let index = items.firstIndex(where: { if case .window(_, id) = $0 { return true } else { return false } }),
              case .window(let pid, _) = items[index] else { onChange?(); return }
        // An app left with no windows keeps the closed window's place.
        if windows.count(of: pid) == 0 && !items.contains(.app(pid: pid)) {
            items[index] = .app(pid: pid)
        } else {
            items.remove(at: index)
        }
        onChange?()
    }

    // MARK: Extension events

    /// One profile's full tab list; other profiles' tabs are kept.
    func snapshot(_ all: [TabInfo], profile: String, lastFocusedWindowId: Int?) {
        tabs = tabs.filter { $0.value.profile != profile }
        for tab in all { tabs[tab.id] = tab }
        items.removeAll { if case .tab(let id) = $0 { return tabs[id] == nil } else { return false } }
        // First report after launch: Chrome's current tab takes Chrome's seeded place.
        if let slot = chromeSlot,
           let current = all.first(where: { $0.active && $0.windowId == lastFocusedWindowId }),
           !items.contains(.tab(id: current.id)) {
            items.insert(.tab(id: current.id), at: min(slot, items.count))
        }
        chromeSlot = nil
        onChange?()
    }

    func tabActivated(_ tab: TabInfo) {
        tabs[tab.id] = tab
        // Tabs can change in background windows; only count it if you're in Chrome.
        let chromeIsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.chromeBundleID
        if chromeIsFrontmost { touch(.tab(id: tab.id)) } else { onChange?() }
    }

    func windowFocused(_ tab: TabInfo) {
        tabs[tab.id] = tab
        touch(.tab(id: tab.id))
    }

    func tabUpdated(_ tab: TabInfo) {
        tabs[tab.id] = tab
        onChange?()
    }

    /// Chrome gave a tab a new ID (it unloaded a long-unused tab, for one): the
    /// tab keeps its place in the history.
    func tabReplaced(_ oldId: Int, with tab: TabInfo) {
        tabs[oldId] = nil
        tabs[tab.id] = tab
        if items.contains(.tab(id: tab.id)) {
            items.removeAll { $0 == .tab(id: oldId) }  // the new ID already has a place
        } else if let index = items.firstIndex(of: .tab(id: oldId)) {
            items[index] = .tab(id: tab.id)
        }
        onChange?()
    }

    func tabRemoved(_ id: Int) {
        tabs[id] = nil
        items.removeAll { $0 == .tab(id: id) }
        onChange?()
    }

    /// Safety net: a late notification can re-add an app just after it quits
    /// (it showed as a blank tile), and menu-bar apps like Shottr turn regular
    /// only while showing a window. Drop anything that no longer counts.
    private func pruneQuitApps() {
        func gone(_ pid: pid_t) -> Bool {
            guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
            return app.isTerminated || !Self.counts(app)
        }
        for pid in Set(windows.windows.values.map(\.pid)) where gone(pid) { windows.forget(pid) }
        items.removeAll {
            switch $0 {
            case .app(let pid): return gone(pid) || Self.isMenuBarApp(pid)
            case .window(let pid, _): return gone(pid)
            case .tab: return false
            }
        }
    }

    private func touch(_ item: HistoryItem) {
        items.removeAll { $0 == item }
        // Once an app has a window in the history, its windowless entry goes.
        if case .window(let pid, _) = item { items.removeAll { $0 == .app(pid: pid) } }
        items.insert(item, at: 0)
        onChange?()
    }
}
