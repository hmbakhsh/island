import Foundation

/// A bot in Grok Bot's sidebar, as its saved roster has it.
public struct GrokBot: Equatable {
    public var id: String
    public var name: String
    public var avatarShape: String?
    public var avatarColor: String?
    /// The latest message's text, the bot's or yours.
    public var lastText: String?
    public var lastMessageId: String?
    public var unreadCount: Int
    /// Set while the bot waits on your answer: when it started waiting.
    public var awaitingSince: Double?
    public var createdAt: Double?
    /// Milliseconds since 1970 of the bot's latest message.
    public var lastActivityAt: Double?
}

extension GrokBot: Decodable {
    private enum Keys: String, CodingKey {
        case id, name, avatarShape, avatarColor, lastEntry, lastMessageId, unreadCount, hasUnread,
             awaitingUserResponse, createdAt, lastActivityAt
    }
    private struct Entry: Decodable { var text: String? }
    private struct Awaiting: Decodable { var since: Double? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Grok"
        avatarShape = try? c.decodeIfPresent(String.self, forKey: .avatarShape)
        avatarColor = try? c.decodeIfPresent(String.self, forKey: .avatarColor)
        lastText = (try? c.decodeIfPresent(Entry.self, forKey: .lastEntry))?.text
        lastMessageId = try? c.decodeIfPresent(String.self, forKey: .lastMessageId)
        let hasUnread = (try? c.decodeIfPresent(Bool.self, forKey: .hasUnread)) ?? false
        unreadCount = (try? c.decodeIfPresent(Int.self, forKey: .unreadCount)) ?? (hasUnread ? 1 : 0)
        // null, or {tabId, reason, since}.
        if let waiting = try? c.decodeIfPresent(Awaiting.self, forKey: .awaitingUserResponse) {
            awaitingSince = waiting.since ?? 0
        } else if (try? c.decodeIfPresent(Bool.self, forKey: .awaitingUserResponse)) == true {
            awaitingSince = 0
        }
        createdAt = try? c.decodeIfPresent(Double.self, forKey: .createdAt)
        lastActivityAt = try? c.decodeIfPresent(Double.self, forKey: .lastActivityAt)
    }
}

public struct GrokEvent: Equatable {
    public enum Kind: Equatable { case replied, needsYou }
    public var kind: Kind
    public var bot: GrokBot
}

/// Reads Grok Bot's saved state, read-only, and says when a bot replies or
/// starts waiting on you. Grok has no hook for this; the sidebar's roster is
/// saved to disk within seconds of a reply, so polling it is enough.
///
/// Files live in `sand-client-persistence/`, named with the lowercase base32
/// of a key. The roster is the one whose key ends in "roster.last-roster":
/// JSON `{schemaVersion, value: {rows: [...]}}`.
public final class GrokWatch {
    public static var defaultDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["ISLAND_GROK_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
    }

    public let directory: URL
    /// Off: keeps track, reports nothing.
    public var announces = true
    /// The latest roster read.
    public private(set) var bots: [GrokBot] = []
    private var seen: [String: (message: String?, awaiting: Double?)]?

    public init(directory: URL = GrokWatch.defaultDirectory) {
        self.directory = directory
    }

    /// Reads the roster and returns what's new since the last read. The first
    /// roster read only seeds, so a launch is quiet.
    @discardableResult
    public func poll() -> [GrokEvent] {
        guard let rows = read() else { return [] }
        bots = rows
        guard let before = seen else {
            seen = Dictionary(rows.map { ($0.id, ($0.lastMessageId, $0.awaitingSince)) }, uniquingKeysWith: { a, _ in a })
            return []
        }
        var events: [GrokEvent] = []
        var now = before
        for bot in rows {
            let old = before[bot.id]
            now[bot.id] = (bot.lastMessageId, bot.awaitingSince)
            guard announces else { continue }
            if let since = bot.awaitingSince, old?.awaiting != since {
                events.append(GrokEvent(kind: .needsYou, bot: bot))
            } else if bot.lastMessageId != old?.message, bot.lastMessageId != nil, bot.unreadCount > 0 {
                // Your own message changes the last id too, but leaves nothing unread.
                events.append(GrokEvent(kind: .replied, bot: bot))
            }
        }
        seen = now
        // Oldest first, so the banners queue in the order things happened.
        return events.sorted { ($0.bot.lastActivityAt ?? 0) < ($1.bot.lastActivityAt ?? 0) }
    }

    /// The bot shown in the picker until you choose others: the one named
    /// "Grok Bot", or else the oldest.
    public static func mainBot(in bots: [GrokBot]) -> GrokBot? {
        bots.first { $0.name == "Grok Bot" } ?? bots.min { ($0.createdAt ?? .infinity) < ($1.createdAt ?? .infinity) }
    }

    private func read() -> [GrokBot]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              let file = names.first(where: { Self.key(ofFile: $0)?.hasSuffix("roster.last-roster") == true }),
              let data = try? Data(contentsOf: directory.appendingPathComponent(file)),
              let roster = try? JSONDecoder().decode(Roster.self, from: data)
        else { return nil }
        return roster.value.rows
    }

    private struct Roster: Decodable {
        struct Value: Decodable { var rows: [GrokBot] }
        var value: Value
    }

    /// "onqw4zbo….blob" → "sand.client…". Lowercase RFC 4648 base32, no padding.
    public static func key(ofFile name: String) -> String? {
        let stem = name.hasSuffix(".blob") ? String(name.dropLast(5)) : name
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for ch in stem {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            value = ((value << 5) | i) & 0xffff
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((value >> bits) & 0xff))
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
