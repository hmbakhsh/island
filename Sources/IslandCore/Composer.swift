import Foundation

/// Where a message from the command bar goes. Every send starts something
/// new: a T3 Code thread in a project, a message in a bot's one Grok chat, or
/// a new ChatGPT chat.
public enum Target: Hashable {
    /// A T3 project, by its workspace root. T3's scratch project is "No project".
    case t3(String)
    /// A Grok bot, by its agent id.
    case grok(String)
    case chatgpt

    /// The form kept in the config: "t3:<root>", "grok:<id>" or "chatgpt".
    public var stored: String {
        switch self {
        case .t3(let root): return "t3:" + root
        case .grok(let id): return "grok:" + id
        case .chatgpt: return "chatgpt"
        }
    }

    public init?(stored: String) {
        if stored == "chatgpt" {
            self = .chatgpt
        } else if stored.hasPrefix("t3:"), stored.count > 3 {
            self = .t3(String(stored.dropFirst(3)))
        } else if stored.hasPrefix("grok:"), stored.count > 5 {
            self = .grok(String(stored.dropFirst(5)))
        } else {
            return nil
        }
    }
}

/// The command bar's state and keys, with no UI: keys and text edits in,
/// state and effects out.
///
///     bar,  ⌫ on empty text          → picker(top), on the current target
///     bar,  ⏎ with text              → send + persistLastTarget + close
///     bar,  esc                      → close
///     top,  ⏎/⇥ on T3 Code           → picker(projects), on the last-picked project
///     top,  ⏎/⇥ on a target          → bar(that target)
///     projects, ⏎/⇥ on a project     → bar(that project), remembered as last picked
///     projects, esc or ⌫ on empty    → picker(top), on T3 Code
///     top,  esc                      → bar(previous target)
///     picker, typing                 → filter by name, selection back to the first row
public struct Composer {
    public struct Bot: Equatable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Project: Equatable {
        public var root: String
        public var name: String
        /// When a thread in it last changed; orders the list.
        public var lastUsed: Date?
        /// T3's scratch project, listed first as "No project".
        public var scratch: Bool
        public init(root: String, name: String, lastUsed: Date? = nil, scratch: Bool = false) {
            self.root = root
            self.name = name
            self.lastUsed = lastUsed
            self.scratch = scratch
        }
    }

    public struct Row: Equatable {
        public enum Kind: Equatable {
            case target(Target)
            /// Drills into the project list.
            case t3Code
        }
        public var kind: Kind
        public var name: String
        /// Second line: a project's folder.
        public var detail: String?
    }

    public enum Level: Equatable { case top, projects }
    public enum Mode: Equatable { case closed, bar, picker(Level) }
    public enum Key { case enter, tab, escape, backspace, up, down }

    public enum Effect: Equatable {
        case send(Target, String)
        case persistLastTarget(Target)
        case close
    }

    public private(set) var mode = Mode.closed
    public private(set) var target: Target
    /// The message being written.
    public private(set) var text = ""
    /// The picker's filter.
    public private(set) var query = ""
    /// Index into `rows`.
    public private(set) var selection = 0
    /// Where the project list starts.
    public private(set) var lastProject: String?

    /// Grok bots chosen for the picker.
    public var bots: [Bot]
    /// "No project" first, then by most recent use.
    public private(set) var projects: [Project]
    private var lastTarget: Target?

    public init(bots: [Bot], projects: [Project], lastTarget: Target?) {
        self.bots = bots
        self.projects = Self.ordered(projects)
        self.lastTarget = lastTarget
        target = .chatgpt
        target = lastTarget ?? defaultTarget
        if case .t3(let root) = lastTarget { lastProject = root }
    }

    /// Before anything's been sent: T3 Code ("No project" first in the list),
    /// else the main bot, else ChatGPT.
    private var defaultTarget: Target {
        projects.first.map { .t3($0.root) } ?? bots.first.map { .grok($0.id) } ?? .chatgpt
    }

    public mutating func setProjects(_ projects: [Project]) {
        self.projects = Self.ordered(projects)
    }

    private static func ordered(_ projects: [Project]) -> [Project] {
        projects.filter(\.scratch).prefix(1)
            + projects.filter { !$0.scratch }.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    /// The hotkey: the bar, empty, aimed at where you last sent.
    public mutating func open() {
        mode = .bar
        target = lastTarget ?? defaultTarget
        text = ""
        query = ""
        selection = 0
    }

    /// Closed from outside the keys: a click elsewhere, another panel.
    public mutating func close() {
        mode = .closed
        text = ""
        query = ""
    }

    /// What the field shows when it's empty.
    public var placeholder: String {
        switch mode {
        case .picker(.top): return "Send to…"
        case .picker(.projects): return "Project…"
        default: return ""
        }
    }

    /// The field's text: the message in the bar, the filter in the picker.
    public var field: String {
        if case .picker = mode { return query }
        return text
    }

    /// The field changed (typing, pasting, dictation).
    public mutating func setText(_ value: String) {
        switch mode {
        case .closed: break
        case .bar: text = value
        case .picker:
            query = value
            selection = 0
        }
    }

    /// The current level of the picker, filtered.
    public var rows: [Row] {
        guard case .picker(let level) = mode else { return [] }
        let all: [Row]
        switch level {
        case .top:
            all = bots.map { Row(kind: .target(.grok($0.id)), name: $0.name) }
                + [Row(kind: .target(.chatgpt), name: "ChatGPT"), Row(kind: .t3Code, name: "T3 Code")]
        case .projects:
            all = projects.map {
                Row(kind: .target(.t3($0.root)), name: $0.scratch ? "No project" : $0.name,
                    detail: $0.scratch ? nil : $0.root)
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { $0.name.lowercased().contains(q) }
    }

    /// A key the bar might act on. Returns its effects, or nil when the key
    /// is the field's to handle (⌫ on text).
    @discardableResult
    public mutating func press(_ key: Key) -> [Effect]? {
        switch mode {
        case .closed:
            return nil
        case .bar:
            return pressInBar(key)
        case .picker(let level):
            return pressInPicker(key, level: level)
        }
    }

    private mutating func pressInBar(_ key: Key) -> [Effect]? {
        switch key {
        case .backspace:
            guard text.isEmpty else { return nil }
            mode = .picker(.top)
            query = ""
            selection = rows.firstIndex {
                if case .t3 = target { return $0.kind == .t3Code }
                return $0.kind == .target(target)
            } ?? 0
            return []
        case .enter:
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return [] }
            lastTarget = target
            mode = .closed
            text = ""
            return [.send(target, message), .persistLastTarget(target), .close]
        case .escape:
            mode = .closed
            return [.close]
        case .tab, .up, .down:
            return []
        }
    }

    private mutating func pressInPicker(_ key: Key, level: Level) -> [Effect]? {
        let count = rows.count
        switch key {
        case .up:
            if count > 0 { selection = (selection - 1 + count) % count }
        case .down:
            if count > 0 { selection = (selection + 1) % count }
        case .enter, .tab:
            guard rows.indices.contains(selection) else { return [] }
            choose(rows[selection])
        case .escape:
            if level == .projects { backToTop() } else { backToBar() }
        case .backspace:
            guard query.isEmpty else { return nil }
            if level == .projects { backToTop() }
        }
        return []
    }

    private mutating func choose(_ row: Row) {
        switch row.kind {
        case .t3Code:
            mode = .picker(.projects)
            query = ""
            let start = lastProject ?? projects.first { !$0.scratch }?.root
            selection = rows.firstIndex { $0.kind == .target(.t3(start ?? "")) } ?? 0
        case .target(let chosen):
            if case .t3(let root) = chosen { lastProject = root }
            target = chosen
            backToBar()
        }
    }

    private mutating func backToTop() {
        mode = .picker(.top)
        query = ""
        selection = rows.firstIndex { $0.kind == .t3Code } ?? 0
    }

    private mutating func backToBar() {
        mode = .bar
        query = ""
        text = ""
        selection = 0
    }
}
