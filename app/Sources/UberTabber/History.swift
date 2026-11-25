import AppKit

struct TabInfo {
    let id: Int
    var windowId: Int
    var title: String
    var url: String
    var favIconUrl: String?
    var active: Bool

    var host: String { URL(string: url)?.host ?? "" }

    init?(_ dict: Any?) {
        guard let d = dict as? [String: Any],
              let id = d["id"] as? Int,
              let windowId = d["windowId"] as? Int else { return nil }
        self.id = id
        self.windowId = windowId
        self.title = d["title"] as? String ?? ""
        self.url = d["url"] as? String ?? ""
        self.favIconUrl = d["favIconUrl"] as? String
        self.active = d["active"] as? Bool ?? false
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

enum HistoryItem: Equatable {
    case app(pid: pid_t)
    case tab(id: Int)
}

/// Most-recently-used list of apps and Chrome tabs. Whatever becomes active
/// moves to the top. Chrome itself never appears; its tabs stand in for it.
final class History {
    static let chromeBundleID = "com.google.Chrome"

    private(set) var items: [HistoryItem] = []
    private(set) var tabs: [Int: TabInfo] = [:]
    var onChange: (() -> Void)?

    /// Where Chrome sat in the seeded list, until the extension reports its current tab.
    private var chromeSlot: Int?

    private var chromeIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.chromeBundleID
    }

    // MARK: Mac events

    /// Fills the list at launch with the running Dock apps, in front-to-back
    /// window order (the best guess at recency), then any without windows.
    func seed() {
        let regular = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var pids: [pid_t] = []
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            if let pid = (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init), !pids.contains(pid) {
                pids.append(pid)
            }
        }
        pids += regular.map(\.processIdentifier).filter { !pids.contains($0) }

        for pid in pids {
            guard let app = regular.first(where: { $0.processIdentifier == pid }) else { continue }
            if app.bundleIdentifier == Self.chromeBundleID {
                chromeSlot = items.count
            } else {
                items.append(.app(pid: pid))
            }
        }
        onChange?()
    }

    func appActivated(_ app: NSRunningApplication) {
        // Like Cmd-Tab, only apps with a Dock icon count (no permission
        // dialogs, helpers or menu-bar apps). Chrome's own activation is
        // ignored: the extension's windowFocused event says which tab is current.
        guard app.activationPolicy == .regular,
              app.bundleIdentifier != Self.chromeBundleID,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        touch(.app(pid: app.processIdentifier))
    }

    func appTerminated(_ app: NSRunningApplication) {
        if app.bundleIdentifier == Self.chromeBundleID {
            tabs.removeAll()
            items.removeAll { if case .tab = $0 { return true } else { return false } }
        }
        items.removeAll { $0 == .app(pid: app.processIdentifier) }
        onChange?()
    }

    // MARK: Extension events

    func snapshot(_ all: [TabInfo], lastFocusedWindowId: Int?) {
        tabs = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
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

    func tabRemoved(_ id: Int) {
        tabs[id] = nil
        items.removeAll { $0 == .tab(id: id) }
        onChange?()
    }

    private func touch(_ item: HistoryItem) {
        items.removeAll { $0 == item }
        items.insert(item, at: 0)
        onChange?()
    }
}
