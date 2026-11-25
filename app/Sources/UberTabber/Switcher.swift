import AppKit
import Combine
import SwiftUI

/// One switchable thing, ready to draw and search.
struct Entry {
    enum Icon {
        case app(NSImage?)
        case tab(large: NSImage?, favicon: NSImage?, tint: NSColor?)
    }
    let item: HistoryItem
    let label: String       // short, under a strip tile
    let title: String       // full, in a list row
    let subtitle: String    // domain or app name, in gray
    let icon: Icon

    /// Typing filter: every typed word must appear somewhere.
    func matches(_ query: String) -> Bool {
        let haystack = "\(title) \(label) \(subtitle)".lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { haystack.contains($0) }
    }

    /// Voice: how many spoken words (3+ letters) appear in this entry.
    func score(_ spoken: String) -> Int {
        let haystack = "\(title) \(label) \(subtitle)".lowercased()
        return spoken.lowercased().split(separator: " ").filter { $0.count >= 3 && haystack.contains($0) }.count
    }
}

final class SwitcherModel: ObservableObject {
    static let stripCount = 8

    @Published var all: [Entry] = []
    @Published var query = ""
    @Published var selected = 0
    @Published var listVisible = false
    @Published var listening = false
    var onClick: ((Int) -> Void)?

    var visible: [Entry] { query.isEmpty ? all : all.filter { $0.matches(query) } }
}

/// Floating, non-activating panel styled after the macOS Cmd-Tab switcher:
/// a strip of the 8 most recent items, with a smaller list of everything else
/// that drops down beneath it.
final class SwitcherPanel {
    let model = SwitcherModel()
    private let panel: NSPanel
    private var pendingShow: DispatchWorkItem?
    private var anchorTop: CGFloat = 0
    private var screenFrame: NSRect = .zero
    private var changes: AnyCancellable?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: SwitcherView(model: model))
        // Resize after SwiftUI has applied each change, keeping the strip in place.
        changes = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.relayout() }
        }
    }

    /// Like Apple's switcher, wait a moment before appearing so a quick
    /// tap-and-release switches without a flash.
    func open(_ entries: [Entry], selected: Int) {
        model.all = entries
        model.query = ""
        model.selected = selected
        model.listVisible = false
        let work = DispatchWorkItem { [weak self] in self?.present() }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Show immediately (any key press while open).
    func present() {
        pendingShow?.cancel()
        pendingShow = nil
        guard !panel.isVisible, let content = panel.contentView else { return }
        let mouse = NSEvent.mouseLocation
        screenFrame = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.frame ?? .zero
        content.layoutSubtreeIfNeeded()
        anchorTop = screenFrame.midY + content.fittingSize.height / 2
        relayout()
        panel.orderFrontRegardless()
    }

    func hide() {
        pendingShow?.cancel()
        pendingShow = nil
        panel.orderOut(nil)
    }

    private func relayout() {
        guard let content = panel.contentView, pendingShow == nil else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.setFrame(NSRect(x: screenFrame.midX - size.width / 2, y: anchorTop - size.height,
                              width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }
}

// MARK: Views

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        let visible = model.visible
        let strip = Array(visible.prefix(SwitcherModel.stripCount))
        let list = Array(visible.dropFirst(SwitcherModel.stripCount))

        VStack(spacing: 10) {
            HStack(spacing: 4) {
                if strip.isEmpty {
                    Text("No matches").font(.system(size: 15)).foregroundStyle(.secondary).padding(40)
                }
                ForEach(Array(strip.enumerated()), id: \.offset) { index, entry in
                    TileView(entry: entry, selected: index == model.selected)
                        .onTapGesture { model.onClick?(index) }
                }
            }
            .padding(14)
            .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)))

            if model.listVisible {
                ListPanel(model: model, rows: list)
            }
        }
        .fixedSize()
    }
}

private struct ListPanel: View {
    @ObservedObject var model: SwitcherModel
    let rows: [Entry]
    static let rowHeight: CGFloat = 34
    static let maxRows = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: model.listening ? "mic.fill" : "magnifyingglass")
                    .foregroundStyle(model.listening ? .red : .secondary)
                Text(model.query.isEmpty ? "Type or say a name" : model.query)
                    .foregroundStyle(model.query.isEmpty ? .secondary : .primary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            if !rows.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { offset, entry in
                                let index = offset + SwitcherModel.stripCount
                                RowView(entry: entry, selected: index == model.selected)
                                    .id(index)
                                    .onTapGesture { model.onClick?(index) }
                            }
                        }
                    }
                    .frame(height: CGFloat(min(rows.count, Self.maxRows)) * Self.rowHeight)
                    .onChange(of: model.selected) { _, selected in
                        if selected >= SwitcherModel.stripCount { proxy.scrollTo(selected) }
                    }
                }
            }
        }
        .frame(width: 520, alignment: .leading)
        .padding(8)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
    }
}

private struct RowView: View {
    let entry: Entry
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            IconView(icon: entry.icon, size: 26)
            Text(entry.title).font(.system(size: 13)).foregroundStyle(.white).lineLimit(1)
            Text(entry.subtitle).font(.system(size: 11)).foregroundStyle(.gray).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: ListPanel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(Rectangle())
    }
}

private struct TileView: View {
    let entry: Entry
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            IconView(icon: entry.icon, size: 104)
            Text(String(entry.label.prefix(20)))
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 116)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(selected ? Color.white.opacity(0.2) : .clear))
        .contentShape(Rectangle())
    }
}

/// App icon, or for a tab: the large site icon (or small favicon on a tinted
/// tile) inset like an app icon, with a Chrome badge. Scales with `size`.
private struct IconView: View {
    let icon: Entry.Icon
    let size: CGFloat
    static let chromeIcon: NSImage? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: History.chromeBundleID)
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    var body: some View {
        Group {
            switch icon {
            case .app(let image):
                if let image { Image(nsImage: image).resizable().interpolation(.high) } else { Color.clear }
            case .tab(let large, let favicon, let tint):
                let inner = size * 0.81
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let large {
                            Image(nsImage: large).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Color(nsColor: tint ?? NSColor(white: 0.92, alpha: 1))
                                if let favicon {
                                    Image(nsImage: favicon).resizable().interpolation(.high)
                                        .frame(width: inner * 0.52, height: inner * 0.52)
                                } else {
                                    Image(systemName: "globe").resizable().foregroundStyle(.gray)
                                        .frame(width: inner * 0.45, height: inner * 0.45)
                                }
                            }
                        }
                    }
                    .frame(width: inner, height: inner)
                    .clipShape(RoundedRectangle(cornerRadius: inner * 0.225, style: .continuous))
                    .frame(width: size, height: size)

                    if let chrome = Self.chromeIcon {
                        Image(nsImage: chrome).resizable().frame(width: size * 0.35, height: size * 0.35)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
