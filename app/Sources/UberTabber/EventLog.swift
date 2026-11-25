import Foundation

/// Appends one JSON object per line to
/// ~/Library/Application Support/UberTabber/events.jsonl
final class EventLog {
    let url: URL
    private let handle: FileHandle?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UberTabber")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func write(_ event: [String: Any]) {
        var e = event
        e["ts"] = Int(Date().timeIntervalSince1970 * 1000)
        guard let data = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        handle?.write(data)
        handle?.write(Data("\n".utf8))
    }
}
