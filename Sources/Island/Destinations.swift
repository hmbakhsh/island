import AppKit
import ApplicationServices
import IslandCore
import ScriptingBridge

/// Why a send didn't go out, worded for the failure banner.
struct SendError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}

/// Where the command bar sends. Each runs off the main thread and never
/// brings its app forward.
protocol Destination {
    func send(_ text: String) throws
}

// MARK: - T3 Code

/// A new thread in a project, through T3's own CLI. "No project" is T3's
/// scratch project. The thread uses the project's default model and settings.
struct T3Destination: Destination {
    let root: String
    /// The new thread, so its banners open it.
    var onStarted: ((String) -> Void)?

    static var cli: String { (NSHomeDirectory() as NSString).appendingPathComponent(".t3/bin/t3") }

    func send(_ text: String) throws {
        guard FileManager.default.isExecutableFile(atPath: Self.cli) else {
            throw SendError("T3's CLI isn't at ~/.t3/bin/t3")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.cli)
        // The message goes in on stdin, so one starting with "-" isn't read as a flag.
        process.arguments = ["thread", "start", "--json", root, "-"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        log("t3 thread start in \(root): exit \(process.terminationStatus) \(String(decoding: out, as: UTF8.self).prefix(300))")
        guard process.terminationStatus == 0 else {
            let reason = String(decoding: err.isEmpty ? out : err, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SendError(reason.isEmpty ? "t3 exited with \(process.terminationStatus)" : String(reason.prefix(160)))
        }
        if let id = Self.threadID(in: out) { onStarted?(id) }
    }

    /// The thread id in `--json` output: {"threadId": …}, {"id": …} or {"thread": {"id": …}}.
    static func threadID(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let id = json["threadId"] as? String { return id }
        if let thread = json["thread"] as? [String: Any], let id = thread["id"] as? String { return id }
        return json["id"] as? String
    }
}

/// T3's projects for the picker, from its state database (read-only).
enum T3Projects {
    static func load() -> [Composer.Project] {
        let database = ProcessInfo.processInfo.environment["ISLAND_T3_DB"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata/statev2.sqlite").path
        let query = """
            select p.title, p.workspace_root root,
                   coalesce(max(t.updated_at), p.updated_at) used
            from projection_projects p
            left join orchestration_v2_projection_threads t on t.project_id = p.project_id
            where p.deleted_at is null and p.archived_at is null
            group by p.project_id;
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", "file:\(database)?mode=ro", query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        struct Row: Decodable { var title: String; var root: String; var used: String? }
        let rows = (try? JSONDecoder().decode([Row].self, from: data)) ?? []
        let scratch = (NSHomeDirectory() as NSString).appendingPathComponent(".t3/scratch")
        return rows.map {
            Composer.Project(
                root: $0.root, name: $0.title, lastUsed: $0.used.map(isoDate),
                scratch: $0.root == scratch || $0.root.hasSuffix("/.t3/scratch"))
        }
    }
}

// MARK: - Grok Bot

/// A message in a bot's Grok chat, typed in over Accessibility while Grok Bot
/// stays in the background.
struct GrokDestination: Destination {
    static let bundleID = "com.anysphere.sand"
    let agent: String
    let name: String

    func send(_ text: String) throws {
        guard AXIsProcessTrusted() else {
            throw SendError("Island needs Accessibility permission (Privacy & Security › Accessibility)")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            throw SendError("Grok Bot isn't running")
        }
        // Selects the bot without raising the app.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "grokbot://app/v1/agent?id=\(agent)"]
        try open.run()
        open.waitUntilExit()
        guard Self.waitFor({ GrokSelection.current() == agent }, seconds: 4) else {
            throw SendError("Grok Bot didn't switch to \(name)")
        }

        let ax = AXUIElementCreateApplication(app.processIdentifier)
        // Electron only builds its accessibility tree when asked.
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var prompt: AXUIElement?
        _ = Self.waitFor({
            prompt = Self.find(in: ax) { role($0) == "AXTextArea" && description($0) == "Prompt" }
            return prompt != nil
        }, seconds: 3)
        guard let prompt else { throw SendError("Grok Bot has no window open") }
        // Let the selected chat's composer settle before typing into it.
        usleep(300_000)
        guard AXUIElementSetAttributeValue(prompt, "AXValue" as CFString, text as CFString) == .success else {
            throw SendError("Couldn't type into Grok Bot")
        }
        var button: AXUIElement?
        _ = Self.waitFor({
            button = Self.find(in: ax) { role($0) == "AXButton" && description($0).lowercased().hasPrefix("send") }
            return button != nil
        }, seconds: 2)
        guard let button, AXUIElementPerformAction(button, "AXPress" as CFString) == .success else {
            throw SendError("Grok Bot's Send button didn't appear")
        }
        log("grok: sent to \(agent)")
    }

    static func waitFor(_ check: () -> Bool, seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if check() { return true }
            usleep(100_000)
        } while Date() < end
        return false
    }

    private static func find(in element: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        if match(element) { return element }
        guard depth < 60 else { return nil }
        var children: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] {
            if let found = find(in: child, depth: depth + 1, match) { return found }
        }
        return nil
    }
}

private func role(_ e: AXUIElement) -> String { string(e, kAXRoleAttribute) }
private func description(_ e: AXUIElement) -> String { string(e, kAXDescriptionAttribute) }
private func string(_ e: AXUIElement, _ attribute: String) -> String {
    var value: AnyObject?
    AXUIElementCopyAttributeValue(e, attribute as CFString, &value)
    return value as? String ?? ""
}

/// The bot Grok Bot has selected, from its saved state.
enum GrokSelection {
    static func current() -> String? {
        let dir = GrokWatch.defaultDirectory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let file = names.first(where: { GrokWatch.key(ofFile: $0)?.hasSuffix("selection.last-agent") == true }),
              let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json["value"] as? [String: Any]
        else { return nil }
        return value["agentId"] as? String
    }
}

// MARK: - ChatGPT

/// A new chat on chatgpt.com, in a background tab of the user's Helium
/// (not the agent instance), in the chosen profile's window. The selected
/// tab stays selected and Helium stays behind.
///
/// Helium's scripting doesn't say which profile a window is, so windows are
/// matched by their tabs against each profile's saved session (see
/// HeliumProfiles.owner). No match, no send: another profile's window is
/// never used.
struct ChatGPTDestination: Destination {
    static let heliumID = "net.imput.helium"
    let profile: String
    let profileName: String
    /// The tab the chat is in, once sent: wait on it for the reply.
    var onSent: ((pid_t, String) -> Void)?

    func send(_ text: String) throws {
        guard let pid = Helium.userPID() else { throw SendError("Helium isn't running") }
        guard let app = SBApplication(processIdentifier: pid) else { throw SendError("Couldn't reach Helium") }
        guard let window = Helium.window(of: app, profile: profile) else {
            throw SendError("No \(profileName) window open in Helium")
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let previous = window.value(forKey: "activeTabIndex") as? Int
        let tabs = window.value(forKey: "tabs") as! SBElementArray
        let before = Set(Helium.ids(tabs))
        guard let tabClass: AnyObject = app.class(forScriptingClass: "tab"),
              let raw = tabClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let tab = raw.perform(NSSelectorFromString("initWithProperties:"), with: ["URL": "https://chatgpt.com/?q=\(q)"])?
                .takeUnretainedValue()
        else { throw SendError("Couldn't make a Helium tab") }
        tabs.add(tab)
        // The add lands asynchronously and selects the new tab: put the
        // user's tab back as soon as it shows up.
        var id: String?
        _ = GrokDestination.waitFor({
            id = Helium.ids(tabs).first { !before.contains($0) }
            return id != nil
        }, seconds: 3)
        if let previous { window.setValue(previous, forKey: "activeTabIndex") }
        guard let id, let chat = Helium.tab(id, in: app) else { throw SendError("Helium didn't open the tab") }

        // ?q= fills the box but doesn't send: press its send button.
        let click = """
            (() => { const b = document.querySelector('form button[type=submit]');
              if (!b) return 'wait'; if (b.disabled) return 'disabled'; b.click(); return 'sent' })()
            """
        var result: String?
        let sent = GrokDestination.waitFor({
            result = Helium.run(click, in: chat)
            return result == "sent"
        }, seconds: 20)
        guard sent else {
            if result == nil {
                throw SendError("Turn on View › Developer › Allow JavaScript from Apple Events in Helium (\(profileName))")
            }
            throw SendError("ChatGPT's send button didn't appear (\(result!))")
        }
        log("chatgpt: sent in tab \(id)")
        onSent?(pid, id)
    }
}

enum Helium {
    /// The user's Helium: the one not started with --user-data-dir (that's the agent's).
    static func userPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: ChatGPTDestination.heliumID)
            .map(\.processIdentifier)
            .first { !(arguments(of: $0)?.contains { $0.hasPrefix("--user-data-dir") } ?? true) }
    }

    /// A process's command line, from the kernel.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buffer[i] != 0 { i += 1 }  // executable path
        while i < size, buffer[i] == 0 { i += 1 }  // padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    static func windows(of app: SBApplication) -> [SBObject] {
        (app.value(forKey: "windows") as? SBElementArray)?.compactMap { $0 as? SBObject } ?? []
    }

    /// The window that belongs to a profile, by its tabs.
    static func window(of app: SBApplication, profile: String) -> SBObject? {
        let profiles = HeliumProfiles.list().map(\.directory)
        let sessions = Dictionary(uniqueKeysWithValues: profiles.map { ($0, HeliumProfiles.sessionURLs(profile: $0)) })
        return windows(of: app).first { window in
            let tabs = window.value(forKey: "tabs") as? SBElementArray
            let urls = tabs?.compactMap { ($0 as AnyObject).value(forKey: "URL") as? String } ?? []
            return HeliumProfiles.owner(ofTabs: urls, sessions: sessions) == profile
        }
    }

    static func ids(_ tabs: SBElementArray) -> [String] {
        tabs.compactMap { ($0 as AnyObject).value(forKey: "id").map { "\($0)" } }
    }

    static func tab(_ id: String, in app: SBApplication) -> SBObject? {
        for window in windows(of: app) {
            guard let tabs = window.value(forKey: "tabs") as? SBElementArray else { continue }
            for case let tab as SBObject in tabs where (tab.value(forKey: "id")).map({ "\($0)" }) == id { return tab }
        }
        return nil
    }

    /// Runs JavaScript in a tab; nil when Helium refuses (Apple Events JavaScript off).
    static func run(_ script: String, in tab: SBObject) -> String? {
        guard let result = tab.perform(Selector(("executeJavascript:")), with: script)?.takeUnretainedValue()
        else { return nil }
        if result is NSNull { return nil }
        return "\(result)"
    }

    /// Clicking the reply banner: select the chat's tab and bring Helium forward.
    static func focus(pid: pid_t, tab id: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let app = SBApplication(processIdentifier: pid) {
                for (n, window) in windows(of: app).enumerated() {
                    guard let tabs = window.value(forKey: "tabs") as? SBElementArray,
                          let index = ids(tabs).firstIndex(of: id) else { continue }
                    window.setValue(index + 1, forKey: "activeTabIndex")
                    if n > 0 { window.setValue(1, forKey: "index") }
                    break
                }
            }
            DispatchQueue.main.async { NSRunningApplication(processIdentifier: pid)?.activate() }
        }
    }
}

/// Waits on a chat started from the bar, and hands back the reply.
enum ChatGPTReply {
    private static let read = """
        (() => {
          const stop = document.querySelector('[data-testid="stop-button"], button[aria-label*="Stop"]');
          const bodies = document.querySelectorAll('[data-response-body]');
          let reply = bodies.length ? bodies[bodies.length - 1].innerText : '';
          if (!reply) { const t = document.body.innerText; const i = t.lastIndexOf('ChatGPT said:');
            if (i >= 0) reply = t.slice(i + 'ChatGPT said:'.length); }
          return JSON.stringify({ busy: !!stop, reply: reply.trim() });
        })()
        """

    /// Polls every 2.5 seconds until ChatGPT stops writing; nil if the tab
    /// went away or ten minutes passed.
    static func wait(pid: pid_t, tab id: String) -> String? {
        let end = Date().addingTimeInterval(600)
        var quietPolls = 0
        while Date() < end {
            usleep(2_500_000)
            guard let app = SBApplication(processIdentifier: pid), let tab = Helium.tab(id, in: app) else { return nil }
            guard let json = Helium.run(read, in: tab),
                  let state = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            else { continue }
            let busy = state["busy"] as? Bool ?? false
            let reply = state["reply"] as? String ?? ""
            // Done once nothing is streaming and there's an answer, seen twice in a row.
            if !busy, !reply.isEmpty {
                quietPolls += 1
                if quietPolls >= 2 { return reply }
            } else {
                quietPolls = 0
            }
        }
        return nil
    }
}
