import AppKit
import SwiftUI

/// macOS light/dark. Flipping it moves every app set to follow the system.
final class Appearance: ObservableObject {
    @Published private(set) var dark = Appearance.isDark
    private let scripts = DispatchQueue(label: "dev.notchisland.appearance")

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in self?.dark = Appearance.isDark }
    }

    func toggle() {
        dark.toggle()
        let target = dark
        scripts.async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to \(target)"]
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                log("appearance: osascript failed: \(error)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.dark = Appearance.isDark }
        }
    }

    /// Fresh from disk: UserDefaults caches the global domain for the life of the process.
    private static var isDark: Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return CFPreferencesCopyAppValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication) as? String == "Dark"
    }
}

struct FocusMode: Identifiable, Equatable {
    /// e.g. com.apple.donotdisturb.mode.default
    let id: String
    let name: String
    let symbol: String
    let tint: Color
}

/// Focus modes, read and set through the Focus database in
/// ~/Library/DoNotDisturb/DB (needs Full Disk Access). Setting one writes the
/// active assertion and kills donotdisturbd so it rereads the file: no
/// Shortcuts round trip. Unofficial; the schema is the one macOS 15 and 26 use.
final class Focus: ObservableObject {
    @Published private(set) var modes: [FocusMode] = []
    /// Active mode id, nil when Focus is off.
    @Published private(set) var active: String?
    /// False without Full Disk Access: modes and state are unknown.
    @Published private(set) var readable = true

    private let queue = DispatchQueue(label: "dev.notchisland.focus")
    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB")
    private static let assertions = dir.appendingPathComponent("Assertions.json")
    private static let configurations = dir.appendingPathComponent("ModeConfigurations.json")
    /// Seconds from 1970 to 2001, the epoch these files count from.
    private static let appleEpoch: TimeInterval = 978_307_200
    private static let client = "dev.notchisland.Island"
    /// Do Not Disturb first, as Control Center lists it.
    private static let dnd = "com.apple.donotdisturb.mode.default"

    var activeMode: FocusMode? { modes.first { $0.id == active } }

    /// What the list shows: every mode but the hidden ones, unless one is on.
    var shown: [FocusMode] {
        let hidden = Set((Config.shared.hiddenFocusModes ?? []).map { $0.lowercased() })
        return modes.filter { $0.id == active || !hidden.contains($0.name.lowercased()) }
    }

    func reload(_ done: (() -> Void)? = nil) {
        queue.async {
            let modes = Self.readModes()
            let active = Self.readActive()
            DispatchQueue.main.async {
                self.readable = modes != nil
                self.modes = modes ?? []
                self.active = active ?? nil
                done?()
            }
        }
    }

    /// nil turns Focus off.
    func set(_ id: String?) {
        active = id
        queue.async {
            if Self.write(active: id) {
                Self.restartDaemon()
                log("focus: \(id ?? "off")")
            }
            // Read back what macOS settled on.
            Thread.sleep(forTimeInterval: 0.5)
            let now = Self.readActive()
            DispatchQueue.main.async { self.active = now ?? nil }
        }
    }

    // MARK: Files

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readModes() -> [FocusMode]? {
        guard let file = readJSON(configurations), let stores = file["data"] as? [[String: Any]] else { return nil }
        var out: [FocusMode] = []
        for store in stores {
            for (key, value) in store["modeConfigurations"] as? [String: Any] ?? [:] {
                guard let mode = (value as? [String: Any])?["mode"] as? [String: Any] else { continue }
                // 1: not set up (System Settings doesn't list it either).
                if mode["visibility"] as? Int == 1 { continue }
                out.append(FocusMode(
                    id: key,
                    name: mode["name"] as? String ?? key,
                    symbol: mode["symbolImageName"] as? String ?? "moon.fill",
                    tint: tint(mode["tintColorName"] as? String)))
            }
        }
        return out.sorted { ($0.id == dnd ? 0 : 1, $0.name) < ($1.id == dnd ? 0 : 1, $1.name) }
    }

    /// Outer nil: unreadable. Inner nil: off.
    private static func readActive() -> String?? {
        guard let file = readJSON(assertions) else { return nil }
        let stores = file["data"] as? [[String: Any]] ?? []
        for store in stores {
            if let record = (store["storeAssertionRecords"] as? [[String: Any]])?.first,
               let details = record["assertionDetails"] as? [String: Any] {
                return .some(details["assertionDetailsModeIdentifier"] as? String)
            }
        }
        return .some(nil)
    }

    /// Replaces the active assertions, keeping the history arrays as they are.
    private static func write(active id: String?) -> Bool {
        var file = readJSON(assertions) ?? [:]
        var stores = file["data"] as? [[String: Any]] ?? []
        if stores.isEmpty { stores = [["storeInvalidationRecords": [], "storeInvalidationRequestRecords": []]] }
        let now = Date().timeIntervalSince1970 - appleEpoch
        stores[0]["storeAssertionRecords"] = id.map { mode in
            [[
                "assertionDetails": [
                    "assertionDetailsIdentifier": client,
                    "assertionDetailsModeIdentifier": mode,
                    "assertionDetailsReason": "user-action",
                ],
                "assertionSource": ["assertionClientIdentifier": client],
                "assertionStartDateTimestamp": now,
                "assertionUUID": UUID().uuidString,
            ]]
        } ?? []
        file["data"] = stores
        var header = file["header"] as? [String: Any] ?? ["version": 8]
        header["timestamp"] = now
        file["header"] = header
        do {
            let data = try JSONSerialization.data(withJSONObject: file, options: [.prettyPrinted])
            try data.write(to: assertions, options: .atomic)
            return true
        } catch {
            log("focus: write failed: \(error)")
            return false
        }
    }

    /// donotdisturbd only reads the file when it starts. SIP blocks
    /// `launchctl kickstart -k`, but killing it works, and a plain kickstart
    /// starts it again at once (otherwise launchd waits for the next request,
    /// and nothing shows the change until then).
    private static func restartDaemon() {
        run("/usr/bin/killall", ["-9", "donotdisturbd"])
        run("/bin/launchctl", ["kickstart", "gui/\(getuid())/com.apple.donotdisturbd"])
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            log("focus: \(path) failed: \(error)")
        }
    }

    private static func tint(_ name: String?) -> Color {
        let colors: [String: NSColor] = [
            "systemBlueColor": .systemBlue, "systemBrownColor": .systemBrown, "systemCyanColor": .systemCyan,
            "systemGrayColor": .systemGray, "systemGreenColor": .systemGreen, "systemIndigoColor": .systemIndigo,
            "systemMintColor": .systemMint, "systemOrangeColor": .systemOrange, "systemPinkColor": .systemPink,
            "systemPurpleColor": .systemPurple, "systemRedColor": .systemRed, "systemTealColor": .systemTeal,
            "systemYellowColor": .systemYellow,
        ]
        return Color(nsColor: name.flatMap { colors[$0] } ?? .systemIndigo)
    }
}

// MARK: - Focus panel

enum FocusLayout {
    static let rowHeight: CGFloat = 38

    static func height(_ focus: Focus) -> CGFloat {
        8 + SectionHeader.height + CGFloat(max(FocusView.order(focus).count, 1)) * rowHeight + 14
    }
}

/// Off, then every Focus mode. Tap or ⏎ sets it.
struct FocusView: View {
    @ObservedObject var focus: Focus
    let selected: String?
    let onPick: (String?) -> Void

    static let off = "off"

    static func order(_ focus: Focus) -> [String] {
        focus.readable ? [off] + focus.shown.map(\.id) : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(text: "Focus")
            if !focus.readable {
                Text("Give Island Full Disk Access to set Focus")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 8)
                    .frame(height: FocusLayout.rowHeight)
            } else {
                FocusRow(symbol: "circle", tint: .white.opacity(0.35), name: "Off", key: key(0),
                         on: focus.active == nil, selected: selected == Self.off) { onPick(nil) }
                ForEach(Array(focus.shown.enumerated()), id: \.element.id) { i, mode in
                    FocusRow(symbol: mode.symbol, tint: mode.tint, name: mode.name, key: key(i + 1),
                             on: focus.active == mode.id, selected: selected == mode.id) { onPick(mode.id) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    /// 1–9 beside the rows while the list has the keyboard.
    private func key(_ index: Int) -> Int? {
        selected != nil && index < 9 ? index + 1 : nil
    }
}

private struct FocusRow: View {
    let symbol: String
    let tint: Color
    let name: String
    let key: Int?
    let on: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(on ? .white : tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(on ? tint : Color.white.opacity(0.08)))
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            if on {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            }
            if let key {
                Text("\(key)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 17, height: 17)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.12)))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: FocusLayout.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.12 : hovered ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: action)
    }
}
