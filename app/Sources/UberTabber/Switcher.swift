import AppKit
import SwiftUI

struct Tile {
    enum Icon {
        case app(NSImage?)
        case tab(large: NSImage?, favicon: NSImage?, tint: NSColor?)
    }
    let title: String
    let icon: Icon
}

final class SwitcherModel: ObservableObject {
    @Published var tiles: [Tile] = []
    @Published var selected = 0
}

/// Floating, non-activating panel in the middle of the screen, styled after
/// the macOS Cmd-Tab switcher.
final class SwitcherPanel {
    let model = SwitcherModel()
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: SwitcherView(model: model))
    }

    func show(_ tiles: [Tile], selected: Int) {
        model.tiles = tiles
        model.selected = selected
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func move(_ delta: Int) {
        guard !model.tiles.isEmpty else { return }
        let n = model.tiles.count
        model.selected = (model.selected + delta + n) % n
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.tiles.enumerated()), id: \.offset) { index, tile in
                TileView(tile: tile, selected: index == model.selected)
            }
        }
        .padding(14)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous)))
    }
}

private struct TileView: View {
    let tile: Tile
    let selected: Bool
    static let chromeIcon: NSImage? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: History.chromeBundleID)
        .map { NSWorkspace.shared.icon(forFile: $0.path) }

    var body: some View {
        VStack(spacing: 6) {
            icon.frame(width: 104, height: 104)
            Text(String(tile.title.prefix(20)))
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 116)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(selected ? Color.white.opacity(0.2) : .clear))
    }

    @ViewBuilder private var icon: some View {
        switch tile.icon {
        case .app(let image):
            if let image { Image(nsImage: image).resizable().interpolation(.high) }
        case .tab(let large, let favicon, let tint):
            ZStack(alignment: .bottomTrailing) {
                // App icons carry a transparent margin; inset tab tiles to match.
                Group {
                    if let large {
                        Image(nsImage: large).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color(nsColor: tint ?? NSColor(white: 0.92, alpha: 1))
                            if let favicon {
                                Image(nsImage: favicon).resizable().interpolation(.high).frame(width: 44, height: 44)
                            } else {
                                Image(systemName: "globe").font(.system(size: 36)).foregroundStyle(.gray)
                            }
                        }
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .frame(width: 104, height: 104)

                if let chrome = Self.chromeIcon {
                    Image(nsImage: chrome).resizable().frame(width: 36, height: 36)
                }
            }
        }
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
