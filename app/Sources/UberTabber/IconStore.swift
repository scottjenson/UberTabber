import AppKit
import CoreImage

/// Downloads and caches tab icons in memory: large site icons (by host, as
/// reported by the extension) and Chrome's small favicons (by URL), plus an
/// average colour for each small favicon to tint its tile.
final class IconStore {
    private var large: [String: NSImage] = [:]
    private var small: [String: NSImage] = [:]
    private var tints: [String: NSColor] = [:]
    private var pending: Set<String> = []

    func siteIcon(host: String, url: String) {
        guard large[host] == nil else { return }
        download(url) { [weak self] image in self?.large[host] = image }
    }

    func prefetchFavicon(_ url: String?) {
        guard let url, small[url] == nil else { return }
        download(url) { [weak self] image in
            self?.small[url] = image
            self?.tints[url] = Self.averageColor(image)
        }
    }

    func largeIcon(host: String) -> NSImage? { large[host] }
    func favicon(_ url: String?) -> NSImage? { url.flatMap { small[$0] } }
    func tint(_ url: String?) -> NSColor? { url.flatMap { tints[$0] } }

    private func download(_ urlString: String, then store: @escaping (NSImage) -> Void) {
        guard let url = URL(string: urlString), !pending.contains(urlString) else { return }
        pending.insert(urlString)
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                self?.pending.remove(urlString)
                if let data, let image = NSImage(data: data) { store(image) }
            }
        }.resume()
    }

    private static func averageColor(_ image: NSImage) -> NSColor? {
        guard let tiff = image.tiffRepresentation, let input = CIImage(data: tiff),
              let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(output, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        guard pixel[3] > 0 else { return nil }
        // Premultiplied: undo alpha, then lighten so the favicon stands out on it.
        let a = CGFloat(pixel[3])
        let base = NSColor(red: CGFloat(pixel[0]) / a, green: CGFloat(pixel[1]) / a, blue: CGFloat(pixel[2]) / a, alpha: 1)
        return base.blended(withFraction: 0.75, of: .white)
    }
}
