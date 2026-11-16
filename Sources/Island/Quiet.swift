import AppKit

/// Notices when something is full screen (a video, mostly), so the island can
/// keep out of the way: no wings, no "done" banners, other banners small.
final class FullScreenWatcher {
    private(set) var active = false
    var onChange: (() -> Void)?
    private var timer: Timer?

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The space animation takes a moment to put the new windows on screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.check() }
        }
    }

    private func check() {
        let now = Config.shared.quietInFullScreen != false
            && (ProcessInfo.processInfo.environment["ISLAND_FORCE_FULLSCREEN"] != nil || Self.somethingFullScreen())
        guard now != active else { return }
        active = now
        log("full screen: \(now ? "quiet" : "normal")")
        onChange?()
    }

    /// An app window covering a whole screen, up to the notch's lower edge
    /// (full-screen windows sit below the camera housing). Tiled or maximized
    /// windows stop at the menu bar or sketchybar, below that, so they don't count.
    static func somethingFullScreen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]],
            let primary = NSScreen.screens.first?.frame
        else { return false }
        // CG window bounds are top-left origin, from the primary screen.
        let screens = NSScreen.screens.map {
            let top = $0.safeAreaInsets.top
            return CGRect(
                x: $0.frame.minX, y: primary.maxY - $0.frame.maxY + top,
                width: $0.frame.width, height: $0.frame.height - top)
        }
        let me = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  window[kCGWindowOwnerPID as String] as? pid_t != me,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return false }
            return screens.contains { rect.insetBy(dx: -1, dy: -1).contains($0) }
        }
    }
}
