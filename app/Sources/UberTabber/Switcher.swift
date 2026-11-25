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
    let names: [String]     // what you'd call it, for matching (see Matcher)
    let rest: String        // other searchable text
}

/// How the list arrives (an experiment; chosen from the menu-bar icon).
enum ListAnimation: Int, CaseIterable {
    case drop = 1, unroll, stagger, dropStagger, slide

    var title: String {
        switch self {
        case .drop: return "1. Drop and fade"
        case .unroll: return "2. Unroll"
        case .stagger: return "3. Staggered rows"
        case .dropStagger: return "4. Drop plus stagger"
        case .slide: return "5. Slide out and bounce"
        }
    }
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
    var listAnimation = ListAnimation.slide
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

    /// Entrance animation; the list is rebuilt each time it opens, so this
    /// starts false. Later changes (typing) aren't animated.
    @State private var shown = false
    private var style: ListAnimation { model.listAnimation }
    private var drops: Bool { style == .drop || style == .dropStagger }

    /// Delay before row `offset` appears, for the staggered styles (visible rows only).
    private func rowDelay(_ offset: Int) -> Double? {
        guard offset < Self.maxRows else { return nil }
        switch style {
        case .stagger: return 0.05 + Double(offset) * 0.012
        case .dropStagger: return 0.03 + Double(offset) * 0.008
        default: return nil
        }
    }

    private var panelAnimation: Animation {
        switch style {
        case .drop, .dropStagger: return .spring(duration: 0.18, bounce: 0.25)
        case .unroll: return .easeOut(duration: 0.2)
        case .stagger: return .easeOut(duration: 0.1)
        // A light spring: one small overshoot past its resting place, then back.
        case .slide: return .spring(duration: 0.25, bounce: 0.25)
        }
    }

    /// Starting offset: a little dip for the drops; for the slide, the whole
    /// list's height (estimated generously), so it starts fully hidden behind the strip.
    private var startOffset: CGFloat {
        if drops { return -12 }
        if style == .slide { return -(CGFloat(min(rows.count, Self.maxRows)) * Self.rowHeight + 60) }
        return 0
    }

    var body: some View {
        content
            .opacity(style == .unroll || style == .slide || shown ? 1 : 0)
            .offset(y: shown ? 0 : startOffset)
            .mask(alignment: .top) {
                // The slide's mask reaches up behind the strip (across the gap
                // between them), so the list emerges from the strip's bottom edge.
                Rectangle()
                    .scaleEffect(x: 1, y: style == .unroll && !shown ? 0.01 : 1, anchor: .top)
                    .padding(.top, style == .slide ? -30 : 0)
                    .padding(.bottom, -16)
            }
            // Transparent room below, so a spring's overshoot isn't cut off by the window edge.
            .padding(.bottom, 16)
            .onAppear { withAnimation(panelAnimation) { shown = true } }
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
                                    .modifier(RowEntrance(shown: shown, delay: rowDelay(offset)))
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

/// A row fading and rising into place after `delay` (no effect without one).
private struct RowEntrance: ViewModifier {
    let shown: Bool
    let delay: Double?

    func body(content: Content) -> some View {
        if let delay {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 6)
                .animation(.easeOut(duration: 0.1).delay(delay), value: shown)
        } else {
            content
        }
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
            case .tab(let large, let favicon, let tint):
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
            }
        }
        .frame(width: size, height: size)
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
