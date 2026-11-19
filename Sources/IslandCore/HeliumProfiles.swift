import Foundation

/// Helium's profiles, and which of its windows belongs to which. Helium's
/// scripting doesn't say a window's profile, so a window is matched by its
/// tabs: each profile saves its open tabs' URLs in its `Sessions/` files.
public enum HeliumProfiles {
    public struct Profile: Equatable {
        /// The profile's folder, e.g. "Profile 3". This is what the config stores.
        public var directory: String
        /// What Helium calls it, e.g. "36 Labs".
        public var name: String
        public init(directory: String, name: String) {
            self.directory = directory
            self.name = name
        }
    }

    public static var dataDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["ISLAND_HELIUM_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/net.imput.helium")
    }

    /// The profiles in `Local State`'s `profile.info_cache`, by name.
    public static func list(localState: Data) -> [Profile] {
        guard let root = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
        else { return [] }
        return cache.compactMap { dir, info in
            let name = (info as? [String: Any])?["name"] as? String
            return Profile(directory: dir, name: name?.isEmpty == false ? name! : dir)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func list(in dataDirectory: URL = dataDirectory) -> [Profile] {
        (try? Data(contentsOf: dataDirectory.appendingPathComponent("Local State"))).map(list(localState:)) ?? []
    }

    /// The profile ChatGPT uses until one is chosen: "36 Labs".
    public static func defaultProfile(in profiles: [Profile]) -> Profile? {
        profiles.first { $0.name == "36 Labs" }
    }

    /// The http(s) URLs saved in a profile's session files.
    public static func sessionURLs(profile: String, in dataDirectory: URL = dataDirectory) -> Set<String> {
        let dir = dataDirectory.appendingPathComponent(profile).appendingPathComponent("Sessions")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var urls = Set<String>()
        for file in files where file.hasPrefix("Session_") || file.hasPrefix("Tabs_") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { continue }
            urls.formUnion(self.urls(in: data))
        }
        return urls
    }

    /// Printable runs that start with http: session files are binary, but
    /// keep URLs as plain bytes.
    static func urls(in data: Data) -> Set<String> {
        var out = Set<String>()
        var run: [UInt8] = []
        func flush() {
            if run.count > 8, let s = String(bytes: run, encoding: .ascii), s.hasPrefix("http") { out.insert(s) }
            run.removeAll(keepingCapacity: true)
        }
        for byte in data {
            if byte > 0x20 && byte < 0x7f { run.append(byte) } else { flush() }
        }
        flush()
        return out
    }

    /// Which profile a window belongs to, from its tabs' URLs: the profile
    /// whose sessions hold most of them, and clearly more than any other.
    /// nil when it can't tell; a window is never guessed.
    public static func owner(ofTabs tabs: [String], sessions: [String: Set<String>]) -> String? {
        let tabs = tabs.filter { $0.hasPrefix("http") }
        guard !tabs.isEmpty else { return nil }
        let scores = sessions.map { profile, urls in (profile, tabs.filter(urls.contains).count) }
            .sorted { $0.1 > $1.1 }
        guard let best = scores.first, best.1 * 2 >= tabs.count else { return nil }
        if scores.count > 1, scores[1].1 * 2 >= best.1 { return nil }
        return best.0
    }
}
