import AppKit
import Combine
import IslandCore
import SwiftUI

let slowmo = Double(ProcessInfo.processInfo.environment["ISLAND_SLOWMO"] ?? "") ?? 1

final class FirstClickHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless windows are normally kept below the menu bar; the island has
/// to sit in it, over the notch.
final class IslandPanel: NSPanel {
    /// Only the command bar takes the keyboard; the panel never activates Island.
    var takesKeyboard = false
    override var canBecomeKey: Bool { takesKeyboard }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the panel and decides what it shows: the Spotify player on request,
/// otherwise queued messages one at a time. Mirrored notifications from one
/// app share a banner (see MessageStack).
final class Island: NSObject, NSApplicationDelegate {
    let player = Player()
    let history = History()
    let watcher = T3Watcher()
    let agenda = Agenda()
    let mirror = NotificationMirror(apps: Config.shared.mirrorNotifications ?? [])
    let devices = DeviceWatcher()
    let codes = EmailCodes()
    let fullScreen = FullScreenWatcher()
    let state = IslandState()
    let composer = ComposerModel()
    let grok = GrokWatch()
    private let grokQueue = DispatchQueue(label: "island.grok")
    private var grokTimer: Timer?
    let panel: IslandPanel
    /// Banners waiting their turn: single messages, or a stack per mirrored app.
    private var queue: [Content] = []
    /// From the start of opening until the panel is ordered out.
    private var busy = false
    /// A panel asked for while a message was up; shown once it has gone.
    private var requested: Panel?
    private var outsideClickMonitor: Any?
    private var closedByOutsideClickAt = Date.distantPast
    private var dismissTimer: DispatchWorkItem?
    private var expandTimer: DispatchWorkItem?
    private var bannerHovered = false
    private var hoverTimer: Timer?
    private var hoverSince: Date?
    private var hoverLeftAt: Date?
    /// Opened from the keyboard, so moving the mouse doesn't close it.
    private var homePinned = false
    /// The next panel was opened from the keyboard and should take ↑ ↓ ⏎.
    private var pendingListKeys = false
    private var meetingTimer: Timer?
    /// Meetings already announced, so each gets one reminder.
    private var remindedMeetings = Set<String>()
    private lazy var settings = SettingsWindow(
        agenda: agenda, grokBots: { [weak self] in self?.composer.grokBots ?? [] }
    ) { [weak self] in self?.applyConfig() }
    private var capsInstalled = false
    private var updateTimer: Timer?
    private var updating = false
    private var subscriptions = Set<AnyCancellable>()

    override init() {
        panel = IslandPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = FirstClickHost(rootView: IslandView(
            state: state, player: player, history: history, watcher: watcher, agenda: agenda, composer: composer,
            onMessageTap: { [weak self] in self?.tapMessage() },
            onMessageHover: { [weak self] inside in self?.hoverMessage(inside) },
            onOpenThread: { [weak self] id in
                T3.open(thread: id)
                self?.close()
            },
            onOpenEntry: { [weak self] entry in
                entry.open()
                self?.close()
            },
            onOpenURL: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.close()
            },
            onOpenPanel: { [weak self] panel in self?.toggle(panel) },
            onOpenAgent: { [weak self] id in
                T3.open(thread: id)
                self?.close()
            },
            onOpenStackGroup: { [weak self] key in self?.openStackGroup(key) },
            onClearStack: { [weak self] in self?.close() }))
        // The island sizes the window itself; don't let SwiftUI resize it too.
        host.sizingOptions = []
        panel.contentView = host

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: spotifyName, object: nil, queue: .main) { [weak self] _ in
            self?.player.refresh()
        }
        center.addObserver(forName: spotifyToggleName, object: nil, queue: .main) { [weak self] _ in
            self?.toggle(.player)
        }
        center.addObserver(forName: inboxName, object: nil, queue: .main) { [weak self] _ in
            self?.toggle(.inbox, keyboard: true)
        }
        center.addObserver(forName: calendarName, object: nil, queue: .main) { [weak self] _ in
            self?.toggle(.calendar, keyboard: true)
        }
        center.addObserver(forName: messageName, object: nil, queue: .main) { [weak self] note in
            guard let json = note.userInfo?["json"] as? String,
                  let message = try? JSONDecoder().decode(Message.self, from: Data(json.utf8))
            else { return }
            self?.deliver(message)
        }
        center.addObserver(forName: dismissName, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.bannerUp else { return }
            self.close()
        }
        watcher.onNew = { [weak self] thread in self?.deliver(thread.message) }
        watcher.onChange = { [weak self] in
            self?.updateBar()
            self?.updateLive()
        }
        watcher.start()
        fullScreen.onChange = { [weak self] in self?.updateLive() }
        fullScreen.start()
        mirror.onMessage = { [weak self] message in self?.deliver(message) }
        mirror.tracked = { [weak self] in self?.heldMirrorIDs ?? [] }
        mirror.onRemoved = { [weak self] ids in self?.mirroredRemoved(ids) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier { self?.appActivated(id) }
        }
        codes.onCode = { [weak self] message in self?.deliver(message) }
        mirror.start()
        devices.onConnect = { [weak self] device in
            guard Config.shared.deviceAlerts != false else { return }
            self?.showDevice(device)
        }
        devices.onBattery = { [weak self] name, level in
            guard self?.state.device?.name == name else { return }
            self?.state.device?.battery = level
        }
        devices.start()
        center.addObserver(forName: mirrorReplayName, object: nil, queue: .main) { [weak self] _ in
            self?.mirror.replayLatest()
        }
        center.addObserver(forName: devicePreviewName, object: nil, queue: .main) { [weak self] note in
            self?.devices.preview(note.userInfo?["json"] as? String ?? "AirPods Pro")
        }
        center.addObserver(forName: homeName, object: nil, queue: .main) { [weak self] _ in
            self?.toggle(.home)
        }
        center.addObserver(forName: agentsName, object: nil, queue: .main) { [weak self] _ in
            self?.toggle(.agents, keyboard: true)
        }
        center.addObserver(forName: settingsName, object: nil, queue: .main) { [weak self] _ in
            self?.openSettings()
        }
        center.addObserver(forName: composerName, object: nil, queue: .main) { [weak self] _ in
            self?.toggle(.composer)
        }
        composer.onEffects = { [weak self] effects in self?.composerDid(effects) }
        composer.onResize = { [weak self] in self?.resizeComposer() }
        pollGrok()
        grokTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollGrok() }
        applyConfig()
        meetingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkMeetings()
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.checkHover()
        }
        // Closing or opening the lid, or plugging a display, moves the notch
        // screen and the whole coordinate space: re-park the island on it.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.screensChanged() }
        player.$playing.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateLive() }
            .store(in: &subscriptions)
        player.refresh()
        updateBar()
    }

    // MARK: Settings

    /// Opening Island.app again (Finder, Spotlight) while it runs shows settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        checkForUpdate()
        return false
    }

    private func openSettings() {
        if state.open { close() }
        settings.show()
    }

    /// Applies the config to what's running; called at launch and on every
    /// change in the settings window.
    private func applyConfig() {
        let config = Config.shared
        watcher.announces = config.t3Banners != false
        let banners = config.grokBanners != false
        grokQueue.async { self.grok.announces = banners }
        updateComposerBots()
        mirror.setApps(config.mirrorNotifications ?? [])
        codes.setEnabled(config.emailCodes != false)
        if config.capsLockTrigger == true, !capsInstalled {
            capsInstalled = true
            Trigger.install { [weak self] in self?.capsPressed() }
        } else if config.capsLockTrigger != true, capsInstalled {
            capsInstalled = false
            Trigger.uninstall()
        }
        agenda.reloadIfAllowed()
    }

    // MARK: Meetings

    /// A few minutes before each meeting: a banner counting down to it, which
    /// joins the call (or opens the event) on click, or Caps then ⏎.
    private func checkMeetings() {
        let config = Config.shared
        guard config.meetingReminders != false else { return }
        agenda.reloadIfAllowed()
        let now = Date()
        for event in agenda.events where !remindedMeetings.contains(event.id) {
            let left = event.start.timeIntervalSince(now)
            guard left <= Double(config.meetingLead * 60) else { continue }
            remindedMeetings.insert(event.id)
            // Already well under way (e.g. Island just started): skip it.
            guard left > -60 else { continue }
            deliver(meetingMessage(event))
        }
    }

    private func meetingMessage(_ event: AgendaEvent) -> Message {
        var m = Message(title: event.title)
        m.countdown = event.start.timeIntervalSince1970
        m.body = [event.tag, event.detail].compactMap { $0 }.joined(separator: separator)
        if m.body?.isEmpty == true { m.body = nil }
        m.icon = event.joinURL == nil ? "calendar" : "video.fill"
        m.color = "green"
        m.source = event.joinURL == nil ? "Calendar" : "Join"
        m.open = event.openURL.absoluteString
        m.seconds = Config.shared.meetingBanner
        m.sound = "Glass"
        return m
    }

    // MARK: Panels opened from the bar

    enum Panel { case player, inbox, calendar, agents, home, composer }

    private var openPanel: Panel? {
        guard state.open else { return nil }
        switch state.content {
        case .player: return .player
        case .inbox: return .inbox
        case .calendar: return .calendar
        case .agents: return .agents
        case .home: return .home
        case .composer: return .composer
        case .message, .stack: return nil
        }
    }

    /// keyboard: opened by a key, so the panel takes its list keys (↑ ↓ ⏎).
    private func toggle(_ panel: Panel, keyboard: Bool = false) {
        pendingListKeys = keyboard && (panel == .agents || panel == .calendar || panel == .inbox)
        if openPanel == panel || (panel == .home && openPanel != nil) {
            // The trigger key closes whatever panel is open.
            close()
        } else if case .home = state.content, state.open {
            content(for: panel) { [weak self] content in
                self?.morph(to: content)
                self?.watchOutsideClicks()
            }
        } else if Date().timeIntervalSince(closedByOutsideClickAt) < 0.4 {
            // A click on the bar item also counts as an outside click; that
            // click already closed us, so don't reopen.
        } else if busy {
            // Something else is up; swap once it has gone.
            requested = panel
            close()
        } else {
            show(panel)
        }
    }

    private func show(_ panel: Panel) {
        content(for: panel) { [weak self] content in
            guard let self, !self.busy else { return }
            self.present(content)
            self.watchOutsideClicks()
        }
    }

    /// Loads what a panel needs, then hands back its content. Calendar waits
    /// for the permission prompt the first time.
    private func content(for panel: Panel, _ done: @escaping (Content) -> Void) {
        if panel != .agents && panel != .calendar && panel != .inbox {
            Trigger.captureList(nil)
            state.selected = nil
        }
        switch panel {
        case .player:
            player.refresh()
            done(.player)
        case .inbox:
            history.markRead()
            updateBar()
            state.selected = takeListKeys() ? InboxView.order(history).first : nil
            done(.inbox(height: InboxView.height(history)))
        case .calendar:
            let keys = takeListKeys()
            agenda.refresh { [weak self] in
                guard let self else { return }
                self.state.selected = keys ? self.agenda.events.first?.id : nil
                done(.calendar(height: AgendaLayout.height(events: self.agenda.events, access: self.agenda.access)))
            }
        case .agents:
            // Start on the thread that finished most recently, not one still working.
            let shown = Set(AgentsView.order(watcher))
            let latestDone = watcher.completed.filter { shown.contains($0.id) }.max { $0.since < $1.since }?.id
            state.selected = takeListKeys() ? latestDone ?? AgentsView.order(watcher).first : nil
            done(.agents(height: AgentsView.height(watcher)))
        case .home:
            agenda.reloadIfAllowed()
            player.refresh()
            homePinned = true
            state.keyboard = Config.shared.capsLockTrigger == true
            if state.keyboard { Trigger.captureNumbers { [weak self] n in self?.pressNumber(n) } }
            done(.home)
        case .composer:
            composer.composer.setProjects(T3Projects.load())
            updateComposerBots()
            composer.composer.open()
            done(.composer(height: ComposerLayout.height(composer.composer)))
        }
    }

    /// Claims ↑ ↓ ⏎ for the panel being opened, if it was opened by a key.
    private func takeListKeys() -> Bool {
        let keys = pendingListKeys
        pendingListKeys = false
        Trigger.captureList(keys ? { [weak self] key in self?.pressListKey(key) } : nil)
        return keys
    }

    /// ↑ ↓ move through the agents or calendar list; ⏎ opens the highlighted
    /// row (the thread in T3, or the event's call or Calendar entry).
    private func pressListKey(_ key: Trigger.ListKey) {
        guard state.open else { return }
        let order: [String]
        switch state.content {
        case .agents: order = AgentsView.order(watcher)
        case .calendar: order = agenda.events.map(\.id)
        case .inbox: order = InboxView.order(history)
        default: return
        }
        guard !order.isEmpty else { return }
        let index = state.selected.flatMap { order.firstIndex(of: $0) }
        switch key {
        case .up: state.selected = order[max((index ?? 0) - 1, 0)]
        case .down: state.selected = order[min((index ?? -1) + 1, order.count - 1)]
        case .open:
            let id = state.selected ?? order[0]
            if case .calendar = state.content {
                if let event = agenda.events.first(where: { $0.id == id }) { NSWorkspace.shared.open(event.openURL) }
            } else if case .inbox = state.content {
                InboxView.entry(id, in: history)?.open()
            } else {
                T3.open(thread: id)
            }
            close()
        }
    }

    /// Caps Lock on a banner pins it and arms ⏎ (open) and Esc (dismiss);
    /// pressed again it opens it. Otherwise it opens or closes the overview.
    private func capsPressed() {
        // Opened by hovering: Caps takes it over for the keyboard rather than
        // closing it, so a quick Caps then 4 doesn't type "4" into the app.
        if case .home = state.content, state.open, !state.keyboard, Config.shared.capsLockTrigger == true {
            homePinned = true
            state.keyboard = true
            Trigger.captureNumbers { [weak self] n in self?.pressNumber(n) }
            return
        }
        guard bannerUp else {
            toggle(.home)
            return
        }
        if case .stack(let stack) = state.content {
            capsOnStack(stack)
            return
        }
        if state.armed {
            tapMessage()
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { state.armed = true }
        Trigger.captureEscape { [weak self] in self?.close() }
        Trigger.captureList { [weak self] key in
            if key == .open { self?.tapMessage() }
        }
        // Pinned, but not forever if it's ignored.
        scheduleDismiss(after: 30)
    }

    /// Caps on a stack lists it and hands it the keyboard: ↑ ↓ pick a
    /// conversation, ⏎ (or Caps again) opens it, Esc dismisses. A stack of one
    /// arms like any banner.
    private func capsOnStack(_ stack: MessageStack) {
        if state.armed {
            if stack.expanded, let id = state.selected { openStackGroup(id) } else { tapMessage() }
            return
        }
        expandTimer?.cancel()
        var stack = stack
        stack.expanded = stack.count > 1
        state.selected = stack.expanded ? stack.groups.first?.id : nil
        withAnimation(.easeOut(duration: 0.15)) { state.armed = true }
        morph(to: .stack(stack), animation: stackSpring)
        Trigger.captureEscape { [weak self] in self?.close() }
        Trigger.captureList { [weak self] key in self?.pressStackKey(key) }
        scheduleDismiss(after: 30)
    }

    private func pressStackKey(_ key: Trigger.ListKey) {
        guard state.open, case .stack(let stack) = state.content else { return }
        guard stack.expanded else {
            if key == .open { tapMessage() }
            return
        }
        let order = stack.groups.prefix(StackLayout.maxRows).map(\.id)
        let index = state.selected.flatMap { order.firstIndex(of: $0) }
        switch key {
        case .up: state.selected = order[max((index ?? 0) - 1, 0)]
        case .down: state.selected = order[min((index ?? -1) + 1, order.count - 1)]
        case .open: openStackGroup(state.selected ?? order[0])
        }
        // Moving around counts as attention: don't vanish mid-choice.
        scheduleDismiss(after: 30)
    }

    /// 1: calendar. 2: notifications. 3: play/pause. 4: agents. ",": settings. A: the command bar.
    /// Lists open with ↑ ↓ ⏎.
    private func pressNumber(_ n: Int) {
        guard case .home = state.content, state.open else { return }
        switch n {
        case 1:
            toggle(.calendar, keyboard: true)
        case 2:
            toggle(.inbox, keyboard: true)
        case 3:
            player.send("playpause")
        case 4:
            toggle(.agents, keyboard: true)
        case 5:
            openSettings()
        case 6:
            toggle(.composer)
        default:
            break
        }
    }

    // MARK: Hover

    /// Resting on the notch opens the overview; leaving it closes it again.
    private func checkHover() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        if case .home = state.content, state.open {
            guard !homePinned else { return }
            let inside = NSMouseInRect(mouse, islandFrame, false)
                || panel.screen.map { NSMouseInRect(mouse, hotZone(on: $0), false) } == true
            if inside {
                hoverLeftAt = nil
            } else if let left = hoverLeftAt {
                if now.timeIntervalSince(left) > 0.3 { hoverLeftAt = nil; close() }
            } else {
                hoverLeftAt = now
            }
            return
        }

        guard !busy, NSEvent.pressedMouseButtons == 0,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              NSMouseInRect(mouse, hotZone(on: screen), false)
        else {
            hoverSince = nil
            return
        }
        if let since = hoverSince {
            if now.timeIntervalSince(since) > 0.15 {
                hoverSince = nil
                showHome()
            }
        } else {
            hoverSince = now
        }
    }

    private func showHome() {
        agenda.reloadIfAllowed()
        player.refresh()
        hoverLeftAt = nil
        homePinned = false
        state.keyboard = false
        present(.home)
    }

    /// The notch itself, or a strip at the top centre of screens without one.
    private func hotZone(on screen: NSScreen) -> NSRect {
        let notch = notchSize(of: screen)
        var width = notch.height > 0 ? notch.width : 200
        var height = max(notch.height, 4)
        if wingsVisible, panel.isVisible, panel.screen == screen {
            width = state.liveWidth
            height = state.liveHeight
        }
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height + 1)
    }

    /// The visible island, without the panel's shadow margin.
    private var islandFrame: NSRect {
        let height = state.notch.height + state.content.height
        let width = state.content.width
        return NSRect(x: panel.frame.midX - width / 2, y: panel.frame.maxY - height, width: width, height: height + 1)
    }

    private func watchOutsideClicks() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            self?.closedByOutsideClickAt = Date()
            self?.close()
        }
    }

    // MARK: Updates

    /// After launch: says if an update just landed or a migration failed, then
    /// checks for updates now and every 6 hours.
    func started(migrationError: String?) {
        let updated = Install.justUpdated()
        if let migrationError {
            deliver(Message(title: "Island couldn't finish updating", body: migrationError,
                            icon: "exclamationmark.triangle.fill", color: "orange", seconds: 0))
        } else if let updated {
            deliver(Message(title: "Updated to \(updated)", body: "Nothing to do on your end.",
                            icon: "arrow.down.circle.fill", color: "green"))
        }
        checkForUpdate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: Updater.checkEvery, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    private func checkForUpdate() {
        guard !updating else { return }
        updating = true
        Task {
            guard let version = await Updater.newer() else {
                DispatchQueue.main.async { self.updating = false }
                return
            }
            if let brew = Updater.brew {
                DispatchQueue.main.async {
                    self.updating = false
                    if let message = Updater.announcement(version, brew: brew) { self.deliver(message) }
                }
                return
            }
            DispatchQueue.main.async {
                self.whenIdle {
                    DispatchQueue.global().async {
                        guard Updater.apply(version) else {
                            DispatchQueue.main.async { self.updating = false }
                            return
                        }
                        DispatchQueue.main.async { self.whenIdle { Install.restart() } }
                    }
                }
            }
        }
    }

    /// Runs `work` once no banner, panel or settings window is up, so an update never lands mid-use.
    private func whenIdle(_ work: @escaping () -> Void) {
        guard !busy, queue.isEmpty, !state.open, !settings.visible else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.whenIdle(work) }
            return
        }
        work()
    }

    // MARK: Messages

    private var bannerUp: Bool {
        guard state.open else { return false }
        switch state.content {
        case .message, .stack: return true
        default: return false
        }
    }

    private func deliver(_ message: Message) {
        history.add(message)
        updateBar()
        // Watching something: codes still show in full, "done" not at all,
        // anything else as one small, silent line (only the latest waits).
        if fullScreen.active, message.copies != true {
            guard message.icon != "checkmark.circle.fill",
                  message.mirroredFrom == nil
                  || NSWorkspace.shared.frontmostApplication?.bundleIdentifier != message.mirroredFrom
            else { return }
            var m = message
            m.quiet = true
            m.sound = nil
            m.seconds = min(m.seconds.flatMap { $0 > 0 ? $0 : nil } ?? 5, 5)
            queue.removeAll { if case .message(let q) = $0 { q.quiet == true } else { false } }
            queue.append(.message(m))
            showNext()
            return
        }
        guard let app = message.mirroredFrom else {
            queue.append(.message(message))
            showNext()
            return
        }
        // Already looking at the app: the inbox has it, no banner.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app { return }

        // Same app's banner is up: the message joins it instead of waiting.
        if state.open, case .stack(var stack) = state.content, stack.app == app {
            stack.add(message)
            morph(to: .stack(stack), animation: stackSpring)
            // Keep it up while messages flow, unless others are waiting.
            if !bannerHovered, !state.armed, queue.isEmpty { scheduleDismiss(after: Config.shared.banner) }
            return
        }
        if let i = queue.firstIndex(where: { if case .stack(let s) = $0 { s.app == app } else { false } }),
           case .stack(var stack) = queue[i] {
            stack.add(message)
            queue[i] = .stack(stack)
        } else {
            queue.append(.stack(MessageStack(app: app, first: message)))
        }
        showNext()
    }

    /// Notification rows held in banners, so the mirror can say when one is cleared.
    private var heldMirrorIDs: [Int] {
        var stacks = queue.compactMap { if case .stack(let s) = $0 { s } else { nil } }
        if state.open, case .stack(let s) = state.content { stacks.append(s) }
        return stacks.flatMap(\.mirrorIDs)
    }

    /// Notifications cleared in macOS (read in Slack, here or elsewhere) leave their banner.
    private func mirroredRemoved(_ ids: Set<Int>) {
        let gone: (MessageStack.Item) -> Bool = { $0.message.mirrorID.map(ids.contains) ?? false }
        queue = queue.compactMap { content in
            guard case .stack(var s) = content else { return content }
            s.remove(where: gone)
            return s.count == 0 ? nil : .stack(s)
        }
        if state.open, case .stack(var s) = state.content {
            s.remove(where: gone)
            if s.count == 0 { close() } else { morph(to: .stack(s), animation: stackSpring) }
        }
    }

    /// Switched to a mirrored app: its banners are old news.
    private func appActivated(_ app: String) {
        queue.removeAll { if case .stack(let s) = $0 { s.app == app } else { false } }
        if state.open, case .stack(let s) = state.content, s.app == app { close() }
    }

    /// Publishes counts for status bars: writes status.json next to the
    /// history, and fires sketchybar's `island_update` event (WAITING, UNREAD)
    /// if sketchybar is installed.
    private func updateBar() {
        let waiting = watcher.waiting.count
        let unread = history.unread
        let status = #"{"waiting": \#(waiting), "unread": \#(unread)}"#
        try? status.write(to: history.directory.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)

        guard let sketchybar = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
        else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sketchybar)
        process.arguments = ["--trigger", "island_update", "WAITING=\(waiting)", "UNREAD=\(unread)"]
        try? process.run()
    }

    private func showNext() {
        guard !busy, !queue.isEmpty else { return }
        let content = queue.removeFirst()
        let message: Message
        switch content {
        case .stack(let s): message = s.latest.message
        case .message(let m): message = m
        default: return
        }
        if let sound = message.sound { NSSound(named: sound == "default" ? "Glass" : sound)?.play() }
        bannerHovered = false
        present(content)
        scheduleDismiss(after: message.seconds ?? Config.shared.banner)
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTimer?.cancel()
        guard seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.close() }
        dismissTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func hoverMessage(_ inside: Bool) {
        guard bannerUp else { return }
        bannerHovered = inside
        expandTimer?.cancel()
        if case .stack(var stack) = state.content {
            if inside, stack.count > 1, !stack.expanded {
                // Resting on a stack lists it by conversation.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.bannerHovered, self.state.open,
                          case .stack(var current) = self.state.content else { return }
                    current.expanded = true
                    self.morph(to: .stack(current), animation: stackSpring)
                }
                expandTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + StackLayout.expandDelay, execute: work)
            } else if !inside, stack.expanded, !state.armed {
                stack.expanded = false
                morph(to: .stack(stack), animation: stackSpring)
            }
        }
        if inside {
            dismissTimer?.cancel()
        } else if case .message(let message) = state.content, message.seconds == 0 {
            // Sticky: stays until clicked.
        } else if !state.armed {
            scheduleDismiss(after: 2)
        }
    }

    private func tapMessage() {
        guard bannerUp else { return }
        switch state.content {
        case .message(let message): message.perform()
        // Listed: a tap between rows does nothing; the rows open themselves.
        case .stack(let stack) where stack.expanded: return
        case .stack(let stack): stack.latest.message.perform()
        default: break
        }
        close()
    }

    /// A conversation picked from a listed stack: open it and drop it from the stack.
    private func openStackGroup(_ key: String) {
        guard state.open, case .stack(var stack) = state.content,
              let group = stack.groups.first(where: { $0.id == key }) else { return }
        group.latest.message.perform()
        stack.remove { MessageStack.conversation($0.message) == key }
        if stack.count == 0 { close(); return }
        if state.armed, stack.count > 1 { stack.expanded = true }
        if state.selected == key { state.selected = stack.expanded ? stack.groups.first?.id : nil }
        morph(to: .stack(stack), animation: stackSpring)
    }

    // MARK: Panel

    private func present(_ content: Content) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        busy = true
        let notch = notchSize(of: screen)
        // Wide enough for the command bar, so morphing into it never clips.
        let width = max(islandWidth, ComposerLayout.width) + shadowRoom * 2
        let height = notch.height + content.height + shadowRoom
        panel.setFrame(
            NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height),
            display: false)

        state.notch = notch
        state.content = content
        state.armed = false
        // Esc closes panels and the overview. Banners leave it alone: they
        // appear while you're typing, and Esc belongs to that app.
        switch content {
        case .message, .stack, .composer: break
        default: Trigger.captureEscape { [weak self] in self?.close() }
        }
        state.open = false
        state.showContent = false
        panel.orderFrontRegardless()
        withAnimation(.spring(response: 0.32 * slowmo, dampingFraction: 0.82)) { state.open = true }
        withAnimation(.easeOut(duration: 0.18 * slowmo).delay(0.04 * slowmo)) { state.showContent = true }
        if case .composer = content { focusComposer() }
    }

    /// Grows (or shrinks) the open island into other content without closing.
    private func morph(
        to content: Content, animation: Animation = .spring(response: 0.34 * slowmo, dampingFraction: 0.86)
    ) {
        releaseNumbers()
        // Grow the window first (it's transparent), shrink it only once the
        // shape has finished, so the window edge never cuts the animation.
        setFrame(contentHeight: max(content.height, state.content.height))
        withAnimation(animation) { state.content = content }
        if case .composer = content {
            // From the overview: its Esc capture would swallow the field's.
            Trigger.captureEscape(nil)
            focusComposer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 * slowmo) { [weak self] in
            // Whatever is showing by then: a stack may have changed again.
            guard let self, self.state.open, self.state.content.key == content.key else { return }
            self.setFrame(contentHeight: self.state.content.height)
        }
    }

    /// Resizes the panel in place, keeping it pinned to the top of its screen.
    private func setFrame(contentHeight: CGFloat) {
        let height = state.notch.height + contentHeight + shadowRoom
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private func releaseNumbers() {
        guard state.keyboard else { return }
        state.keyboard = false
        Trigger.captureNumbers(nil)
    }

    private func close() {
        guard state.open else { return }
        let composing = if case .composer = state.content { true } else { false }
        if composing {
            composer.composer.close()
            panel.takesKeyboard = false
        }
        releaseNumbers()
        state.armed = false
        expandTimer?.cancel()
        bannerHovered = false
        Trigger.captureEscape(nil)
        Trigger.captureList(nil)
        dismissTimer?.cancel()
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        withAnimation(.easeIn(duration: 0.12 * slowmo)) { state.showContent = false }
        withAnimation(.spring(response: 0.28 * slowmo, dampingFraction: 1)) { state.open = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32 * slowmo) { [weak self] in
            guard let self, !self.state.open else { return }
            self.busy = false
            // Ordering out hands the keyboard back to the app you were in.
            if composing || !self.wingsVisible { self.panel.orderOut(nil) }
            if self.wingsVisible { self.showLive() }
            if let panel = self.requested {
                self.requested = nil
                self.show(panel)
            } else {
                // Leave a beat between messages so each one reads as new.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.showNext() }
            }
        }
    }

    // MARK: Live indicator

    /// Shows, updates or hides the wings beside the notch as agents start,
    /// wait and finish, and as Spotify plays and stops. While a panel or
    /// banner is up, close() settles it.
    private func updateLive() {
        let needs = watcher.waiting.filter { $0.needsInput || $0.reason == "failed" }.count
        let done = watcher.waiting.count - needs
        // Watching something full screen: nothing beside the notch.
        let quiet = fullScreen.active
        let counts = quiet || watcher.running.isEmpty && watcher.waiting.isEmpty
            ? nil : LiveCounts(running: watcher.running.count, needs: needs, done: done)
        let music = !quiet && player.playing
        guard counts != state.live || music != state.music else { return }
        let appearing = !wingsVisible
        if !busy, appearing, counts != nil || music { showLive() }
        withAnimation(.spring(response: 0.34 * slowmo, dampingFraction: 0.82)) {
            state.live = counts
            state.music = music
        }
        if !busy, !wingsVisible { hideWingsIfIdle() }
    }

    private var wingsVisible: Bool { state.live != nil || state.device != nil || state.music }

    /// Screens changed. An open island closes (close() re-parks the wings);
    /// parked wings move now, and again once the displays have settled.
    private func screensChanged() {
        if state.open { close(); return }
        guard !busy, wingsVisible else { return }
        showLive()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.busy, !self.state.open, self.wingsVisible else { return }
            self.showLive()
        }
    }

    private func hideWingsIfIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 * slowmo) { [weak self] in
            guard let self, !self.busy, !self.wingsVisible else { return }
            self.panel.orderOut(nil)
        }
    }

    // MARK: Devices

    /// Headphones connected: show them in the wings with their battery for a
    /// few seconds, iOS-style, with a sound. Skipped while the island is open.
    private func showDevice(_ device: ConnectedDevice) {
        guard !busy else { return }
        playDeviceSound(for: device)
        if !wingsVisible { showLive() }
        withAnimation(.spring(response: 0.34 * slowmo, dampingFraction: 0.78)) { state.device = device }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.state.device?.name == device.name else { return }
            withAnimation(.spring(response: 0.34 * slowmo, dampingFraction: 0.86)) { self.state.device = nil }
            if !self.busy, !self.wingsVisible { self.hideWingsIfIdle() }
        }
    }

    /// AirPods and Beats play Apple's chime themselves, in your ears, as they
    /// connect; a second sound would land on top of it. Others get "Tink".
    private func playDeviceSound(for device: ConnectedDevice) {
        let apple = device.symbol.hasPrefix("airpods") || device.symbol.hasPrefix("beats")
        guard let sound = Config.shared.deviceSound ?? (apple ? nil : "Tink") else { return }
        let path = (sound as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            NSSound(contentsOfFile: path, byReference: true)?.play()
        } else {
            NSSound(named: sound)?.play()
        }
    }

    /// Parks the closed island on the notch screen, sized to the wings.
    private func showLive() {
        guard let screen = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) ?? NSScreen.main
        else { return }
        state.notch = notchSize(of: screen)
        let width = state.liveWidth
        let height = state.liveHeight
        panel.setFrame(
            NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height),
            display: true)
        panel.orderFrontRegardless()
    }

    /// The notch's size, or a zero-height sliver on screens without one so the
    /// island still grows out of the top edge.
    private func notchSize(of screen: NSScreen) -> CGSize {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return CGSize(width: 200, height: 0)
        }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }

    // MARK: Command bar

    /// The panel takes the keyboard without activating Island, so the app
    /// you're in stays frontmost and Hex can paste into the field.
    private func focusComposer() {
        if panel.isKeyWindow { return }
        panel.takesKeyboard = true
        panel.makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.panel.contentView else { return }
            // Already typing: making it first responder again would select all, and the next key would replace it.
            if let field = Self.firstField(in: host), field.currentEditor() == nil { self.panel.makeFirstResponder(field) }
            log("composer open: key \(self.panel.isKeyWindow), Island active \(NSApp.isActive), frontmost \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
        }
    }

    private static func firstField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let f = firstField(in: sub) { return f } }
        return nil
    }

    private func resizeComposer() {
        guard state.open, case .composer = state.content else { return }
        morph(to: .composer(height: ComposerLayout.height(composer.composer)),
              animation: .spring(response: 0.26 * slowmo, dampingFraction: 0.9))
    }

    private func composerDid(_ effects: [Composer.Effect]) {
        for effect in effects {
            switch effect {
            case .send(let target, let text): send(text, to: target)
            case .persistLastTarget(let target):
                Config.shared.composerLastTarget = target.stored
                Config.shared.save()
            case .close: close()
            }
        }
    }

    /// Sends in the background; only a failure (or a ChatGPT reply) comes back as a banner.
    private func send(_ text: String, to target: Target) {
        let name = composer.name(of: target)
        let destination: Destination
        switch target {
        case .t3(let root):
            destination = T3Destination(root: root)
        case .grok(let id):
            // Only bots Grok Bot knows: an unknown id would make it open on nothing.
            guard composer.bot(id) != nil else {
                deliver(failure(name, "Grok Bot has no bot with id \(id.prefix(8))"))
                return
            }
            destination = GrokDestination(agent: id, name: name)
        case .chatgpt:
            let profiles = HeliumProfiles.list()
            guard let profile = Config.shared.chatgptHeliumProfile.flatMap({ dir in profiles.first { $0.directory == dir } })
                ?? HeliumProfiles.defaultProfile(in: profiles)
            else {
                deliver(failure(name, "Choose a Helium profile in Island's settings"))
                return
            }
            destination = ChatGPTDestination(profile: profile.directory, profileName: profile.name) { [weak self] pid, tab in
                DispatchQueue.global(qos: .utility).async {
                    guard let reply = ChatGPTReply.wait(pid: pid, tab: tab) else { return }
                    DispatchQueue.main.async { self?.deliver(Self.chatGPTMessage(reply, pid: pid, tab: tab)) }
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try destination.send(text)
            } catch {
                log("send to \(target.stored) failed: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.deliver(Self.failureMessage(name, error.localizedDescription)) }
            }
        }
    }

    private func failure(_ name: String, _ reason: String) -> Message { Self.failureMessage(name, reason) }

    static func failureMessage(_ name: String, _ reason: String) -> Message {
        Message(title: "Couldn't send to \(name)", body: reason,
                icon: "exclamationmark.triangle.fill", color: "orange", seconds: 12)
    }

    static func chatGPTMessage(_ reply: String, pid: pid_t, tab: String) -> Message {
        var m = Message(title: "ChatGPT")
        m.body = reply.split(whereSeparator: \.isNewline).joined(separator: " ")
        m.source = "Helium"
        if let path = TargetIcon.chatgptPath { m.image = "app:" + path } else { m.icon = "bubble.left.fill" }
        m.heliumTab = "\(pid):\(tab)"
        return m
    }

    // MARK: Grok banners

    private func pollGrok() {
        grokQueue.async { [weak self] in
            guard let self else { return }
            let events = self.grok.poll()
            let bots = self.grok.bots
            DispatchQueue.main.async {
                if bots != self.composer.grokBots {
                    self.composer.grokBots = bots
                    self.updateComposerBots()
                }
                for event in events { self.deliver(Self.grokMessage(event)) }
            }
        }
    }

    /// The picker's bots: the ones chosen in settings, or the main bot.
    private func updateComposerBots() {
        let bots = composer.grokBots
        let chosen = Config.shared.composerGrokBots ?? GrokWatch.mainBot(in: bots).map { [$0.id] } ?? []
        composer.composer.bots = bots.filter { chosen.contains($0.id) }.map { Composer.Bot(id: $0.id, name: $0.name) }
    }

    static func grokMessage(_ event: GrokEvent) -> Message {
        let bot = event.bot
        var m = Message(title: event.kind == .needsYou ? "\(bot.name) needs you" : bot.name)
        m.body = bot.lastText.map { $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
        m.source = "Grok"
        if let path = TargetIcon.avatarPath(shape: bot.avatarShape, color: bot.avatarColor) { m.image = path }
        m.open = "grokbot://app/v1/agent?id=\(bot.id)"
        if event.kind == .needsYou { m.sound = "Glass" }
        return m
    }
}
