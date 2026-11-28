import AppKit

/// Which Chrome profile each tab came from, and the avatar badge for tabs not
/// from the primary profile. Chrome's "Default" profile folder is primary: its
/// tabs look exactly like apps. Avatars come from Chrome's own files, matched
/// by the email each profile's extension reports.
final class ProfileStore {
    enum Badge {
        case picture(NSImage)
        case initial(String)    // empty when the profile isn't signed in
    }

    private struct ChromeProfile {
        let folder: String
        let name: String
        let picture: NSImage?
    }

    private static let chromeDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome")

    private var emails: [String: String] = [:]          // extension profile ID -> email
    private var chrome: [String: ChromeProfile] = [:]   // lowercased email -> Chrome's profile
    private var primaryEmail = ""

    func register(_ id: String, email: String) {
        let email = email.lowercased()
        let isNew = emails[id] != email
        emails[id] = email
        if isNew { reload() }
    }

    func badge(for id: String) -> Badge? {
        // No email (an older extension, or a profile not signed in): we can't
        // tell which profile it is, so leave it looking like the primary.
        guard let email = emails[id], !email.isEmpty, email != primaryEmail,
              let profile = chrome[email] else { return nil }
        if let picture = profile.picture { return .picture(picture) }
        return .initial(String(profile.name.prefix(1)).uppercased())
    }

    /// Reads Chrome's profile list (Local State: profile.info_cache).
    private func reload() {
        guard let data = try? Data(contentsOf: Self.chromeDir.appendingPathComponent("Local State")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { return }
        chrome = [:]
        for (folder, info) in cache {
            let email = (info["user_name"] as? String ?? "").lowercased()
            if folder == "Default" { primaryEmail = email }
            guard !email.isEmpty else { continue }
            let file = info["gaia_picture_file_name"] as? String ?? ""
            let picture = file.isEmpty ? nil
                : NSImage(contentsOf: Self.chromeDir.appendingPathComponent(folder).appendingPathComponent(file))
            chrome[email] = ChromeProfile(folder: folder, name: info["name"] as? String ?? email, picture: picture)
        }
    }
}
