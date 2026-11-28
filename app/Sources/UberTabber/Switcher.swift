import AppKit
import Combine
import SwiftUI

/// One switchable thing, ready to draw and search.
struct Entry {
    enum Icon {
        case app(NSImage?)
        case tab(large: NSImage?, favicon: NSImage?, tint: NSColor?, badge: ProfileStore.Badge?)
    }
    let item: HistoryItem
    let label: String       // short, under a strip tile
    let title: String       // full, in a list row
    let subtitle: String    // domain or app name, in gray
    let icon: Icon
    let names: [String]     // what you'd call it, for matching (see Matcher)
    let rest: String        // other searchable text
}

/// Selection indices: 0..<8 are strip tiles, 8... are list rows (so a row's
/// index doesn't depend on how many tiles there are).
final class SwitcherModel: ObservableObject {
    static let stripCount = 8

    @Published var all: [Entry] = [] { didSet { refilter() } }
    @Published var query = "" { didSet { refilter() } }
    /// List rows: everything after the strip, or while typing, the matches
    /// from everything (strip included), best first.
    @Published private(set) var rows: [Entry] = []
    @Published var selected = 0
    @Published var listVisible = false
    @Published var listening = false
    var onClick: ((Int) -> Void)?

    var searching: Bool { !query.isEmpty }
    /// The strip never filters, so it stays a stable picture of recent work.
    var strip: [Entry] { Array(all.prefix(Self.stripCount)) }

    /// What can be selected, in order. While typing, only the results.
    var selectable: [Int] {
        let rowIndices = rows.indices.map { $0 + Self.stripCount }
        return searching ? rowIndices : Array(strip.indices) + rowIndices
    }

    private var lastMouse: NSPoint = .zero

    /// Called when the switcher opens: wherever the pointer already sits
    /// doesn't count as hovering.
    func resetHover() {
        lastMouse = NSEvent.mouseLocation
    }

    /// Moving the mouse over a tile or row selects it, like Cmd-Tab; the
    /// keyboard then carries on from there. A pointer that merely sits there
    /// while the panel appears or the list changes under it doesn't.
    func hover(_ index: Int) {
        let mouse = NSEvent.mouseLocation
        guard mouse != lastMouse else { return }
        lastMouse = mouse
        if selectable.contains(index) && selected != index { selected = index }
    }

    func entry(at index: Int) -> Entry? {
        if index < Self.stripCount { return strip.indices.contains(index) ? strip[index] : nil }
        let row = index - Self.stripCount
        return rows.indices.contains(row) ? rows[row] : nil
    }

    private func refilter() {
        rows = searching ? Matcher.filter(all, query) : Array(all.dropFirst(Self.stripCount))
    }
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
        panel.appearance = NSAppearance(named: .aqua)
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
        model.resetHover()
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
    static let tileSpacing: CGFloat = 19

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: Self.tileSpacing) {
                ForEach(Array(model.strip.enumerated()), id: \.offset) { index, entry in
                    TileView(entry: entry, selected: index == model.selected)
                        .onTapGesture { model.onClick?(index) }
                        .onContinuousHover { if case .active = $0 { model.hover(index) } }
                }
            }
            // While typing, results appear only in the list; the strip stays put, dimmed.
            .opacity(model.searching ? 0.4 : 1)
            .padding(.horizontal, 29)
            .padding(.top, 32)
            .padding(.bottom, 18)
            .background(Backdrop(radius: 58))
            .zIndex(1)  // the list slides out from behind the strip

            if model.listVisible {
                ListPanel(model: model, rows: model.rows)
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

    /// The list slides down from behind the strip and overshoots slightly
    /// before settling. It's rebuilt each time it opens, so this starts false;
    /// later changes (typing) aren't animated.
    @State private var shown = false

    var body: some View {
        content
            // Start fully hidden behind the strip (height estimated generously).
            .offset(y: shown ? 0 : -(CGFloat(min(rows.count, Self.maxRows)) * Self.rowHeight + 60))
            // Clip to the list's own area, reaching up across the gap behind the
            // strip so it emerges from the strip's bottom edge, and down to
            // leave room for the overshoot.
            .mask { Rectangle().padding(.top, -30).padding(.bottom, -16) }
            // Transparent room below, so the overshoot isn't cut off by the window edge.
            .padding(.bottom, 16)
            .onAppear { withAnimation(.spring(duration: 0.25, bounce: 0.25)) { shown = true } }
    }

    private var content: some View {
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

            if rows.isEmpty && model.searching {
                Text("No matches").font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: Self.rowHeight)
            }
            if !rows.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { offset, entry in
                                let index = offset + SwitcherModel.stripCount
                                RowView(entry: entry, selected: index == model.selected)
                                    .id(index)
                                    .onTapGesture { model.onClick?(index) }
                                    .onContinuousHover { if case .active = $0 { model.hover(index) } }
                            }
                        }
                    }
                    .frame(height: CGFloat(min(rows.count, Self.maxRows)) * Self.rowHeight)
                    .onChange(of: model.selected) { _, selected in
                        if selected >= SwitcherModel.stripCount { proxy.scrollTo(selected) }
                    }
                    .onChange(of: model.query) {
                        proxy.scrollTo(SwitcherModel.stripCount, anchor: .top)
                    }
                }
            }
        }
        .frame(width: 520, alignment: .leading)
        .padding(8)
        .background(Backdrop(radius: 26))
    }
}

private struct RowView: View {
    let entry: Entry
    let selected: Bool
    static let selection = Color(white: 0.3).opacity(0.35)

    var body: some View {
        HStack(spacing: 8) {
            IconView(icon: entry.icon, size: 26)
            Text(entry.title).font(.system(size: 13)).foregroundStyle(.primary).lineLimit(1)
            Text(entry.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: ListPanel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected ? Self.selection : .clear))
        .contentShape(Rectangle())
    }
}

private struct TileView: View {
    let entry: Entry
    let selected: Bool

    /// Like Cmd-Tab: a dark rounded square behind the selected icon, and only
    /// the selected item is labeled. The label may spill into the gaps beside
    /// the tile (never past the panel's padding) and truncates beyond that.
    /// App icon images include a transparent margin (~10% each side), so draw
    /// them larger than the selection square and let the margin overflow; the
    /// visible artwork (~104pt) then sits ~7pt inside the square, as in Cmd-Tab.
    static let canvas: CGFloat = 128
    static let square: CGFloat = 117

    var body: some View {
        VStack(spacing: 8) {
            IconView(icon: entry.icon, size: Self.canvas)
                .frame(width: Self.square, height: Self.square)
                .background(RoundedRectangle(cornerRadius: 31, style: .continuous)
                    .fill(selected ? Color(white: 0.25).opacity(0.55) : .clear))
            Text(selected ? entry.label : " ")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(white: 0.12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.square + 2 * SwitcherView.tileSpacing)
                .frame(width: Self.square)
        }
        .contentShape(Rectangle())
    }
}

/// App icon, or for a tab: the large site icon (or small favicon on a tinted
/// tile) inset like an app icon's artwork, so tabs and apps look alike.
/// Scales with `size`.
private struct IconView: View {
    let icon: Entry.Icon
    let size: CGFloat

    var body: some View {
        Group {
            switch icon {
            case .app(let image):
                if let image { Image(nsImage: image).resizable().interpolation(.high) } else { Color.clear }
            case .tab(let large, let favicon, let tint, let badge):
                let inner = size * 0.81
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
                .overlay(alignment: .bottomTrailing) {
                    if let badge { ProfileBadge(badge: badge, size: max(inner * 0.32, 11)) }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// A tab from a non-primary Chrome profile: its avatar, in a thin light ring,
/// straddling the icon's lower-right corner.
private struct ProfileBadge: View {
    let badge: ProfileStore.Badge
    let size: CGFloat

    var body: some View {
        Group {
            switch badge {
            case .picture(let image):
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            case .initial(let letter):
                ZStack {
                    Color(white: 0.45)
                    if letter.isEmpty {
                        Image(systemName: "person.fill").resizable().scaledToFit().padding(size * 0.22)
                    } else {
                        Text(letter).font(.system(size: size * 0.55, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: max(size * 0.06, 1)))
        .offset(x: size * 0.15, y: size * 0.15)
    }
}

/// Cmd-Tab's backdrop, measured on screen: #9F9F9F, very round.
private struct Backdrop: View {
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color(white: 0x9F / 255.0))
    }
}
