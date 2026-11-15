import AppKit
import SwiftUI

/// Mirrored notifications from one app (Slack) that arrived while a banner
/// for that app was up or waiting. They share one banner: the newest on top,
/// the rest stacked behind it, listed by conversation on hover.
struct MessageStack {
    struct Item {
        let id = UUID()
        let message: Message
        let date: Date
    }

    /// One row in the expanded list: a channel or DM with its newest message.
    struct Group: Identifiable {
        let id: String
        let latest: Item
        let count: Int
    }

    let app: String
    /// Oldest first.
    private(set) var items: [Item]
    var expanded = false

    init(app: String, first: Message) {
        self.app = app
        items = [Item(message: first, date: Date())]
    }

    var latest: Item { items[items.count - 1] }
    var count: Int { items.count }

    mutating func add(_ message: Message) {
        items.append(Item(message: message, date: Date()))
        if items.count > StackLayout.keep { items.removeFirst(items.count - StackLayout.keep) }
    }

    /// Drops the given conversation, or the notifications macOS no longer has.
    mutating func remove(where drop: (Item) -> Bool) {
        items.removeAll(where: drop)
        if items.count < 2 { expanded = false }
    }

    /// Conversations, most recent first.
    var groups: [Group] {
        var order: [String] = []
        var byKey: [String: [Item]] = [:]
        for item in items.reversed() {
            let key = Self.conversation(item.message)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.map { Group(id: $0, latest: byKey[$0]![0], count: byKey[$0]!.count) }
    }

    /// Workspace plus channel (the mirror puts the channel in the title).
    static func conversation(_ m: Message) -> String { (m.source ?? "") + "|" + m.title }

    var mirrorIDs: [Int] { items.compactMap(\.message.mirrorID) }
}

enum StackLayout {
    /// Notifications a stack holds; older ones are still in the inbox.
    static let keep = 30
    static let maxRows = 5
    /// How far each card behind shows below the one in front.
    static let peeks: [CGFloat] = [6, 11]
    /// How much narrower each card behind is.
    static let inset: CGFloat = 24
    /// Hovering this long on a stack lists it, so passing over doesn't.
    static let expandDelay = 0.18

    static func height(_ stack: MessageStack) -> CGFloat {
        guard stack.expanded else { return Content.message(stack.latest.message).height }
        let rows = CGFloat(min(stack.groups.count, maxRows))
        return 8 + SectionHeader.height + rows * InboxLayout.rowHeight + 14
    }
}

/// One curve for everything a stack does, so growing, listing and
/// collapsing move together.
let stackSpring = Animation.spring(response: 0.38 * slowmo, dampingFraction: 0.88)

struct StackView: View {
    let stack: MessageStack
    /// The conversation highlighted with the arrow keys, after Caps Lock.
    var selected: String?
    var keyboard = false
    let onOpen: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // One leaves quickly before the other fades in, so they never overlap.
            if stack.expanded {
                list.transition(swap(offset: -6))
            } else {
                banner.transition(swap(offset: 4))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func swap(offset: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: offset))
                .animation(.easeOut(duration: 0.22 * slowmo).delay(0.12 * slowmo)),
            removal: .opacity.animation(.easeIn(duration: 0.08 * slowmo)))
    }

    // MARK: Collapsed

    private var banner: some View {
        let message = stack.latest.message
        return HStack(spacing: 12) {
            MessageIcon(message: message)
                // Same app icon every time: swapping it shouldn't flicker.
                .transaction { $0.animation = nil }
            // The newest message drops in from above; the one it replaces
            // sinks into the stack behind.
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    if let body = message.body {
                        Text(body)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(stack.latest.id)
                // The old text is gone before the new one lands, so the two never overlap.
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: -8))
                        .animation(.spring(response: 0.34 * slowmo, dampingFraction: 0.9).delay(0.1 * slowmo)),
                    removal: .opacity.combined(with: .offset(y: 6))
                        .animation(.easeIn(duration: 0.1 * slowmo))))
            }
            .clipped()
            if keyboard, stack.count == 1 {
                // Armed with Caps Lock: ⏎ opens it, as on any banner.
                Image(systemName: "return")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .transition(.opacity)
            } else if stack.count > 1 {
                Text("+\(stack.count - 1)")
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(stack.count)))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(height: Content.message(message).height)
        .contentShape(Rectangle())
    }

    // MARK: Expanded

    private var list: some View {
        let groups = stack.groups
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader(text: appName, count: nil)
                Spacer()
                if keyboard {
                    Text("↑↓  ⏎ open")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .transition(.opacity)
                }
                ClearButton(action: onClear)
            }
            ForEach(Array(groups.prefix(StackLayout.maxRows))) { group in
                let message = group.latest.message
                Row(
                    leading: AnyView(MessageIcon(message: message, size: 28)),
                    title: message.title,
                    detail: message.body ?? "",
                    time: relative(group.latest.date),
                    badge: group.count > 1 ? group.count : nil,
                    selected: group.id == selected,
                    action: { onOpen(group.id) })
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var appName: String {
        let source = stack.latest.message.source ?? ""
        return source.components(separatedBy: separator).first ?? source
    }
}

/// Dismisses the whole stack: an × in a small circle, brighter on hover.
private struct ClearButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(hovered ? 0.9 : 0.6))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(hovered ? 0.2 : 0.12)))
                .padding(.horizontal, 6)
                .frame(height: SectionHeader.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("Clear")
    }
}

/// The cards peeking out under a stacked banner, one per extra message (up
/// to two). Solid black like the island, each one further back narrower,
/// with a lit hairline along its bottom edge and a small shadow, so they read
/// as separate cards on light and dark wallpapers alike.
struct StackPeeks: View {
    let count: Int
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            card(level: 2)
            card(level: 1)
        }
    }

    private func card(level: Int) -> some View {
        let shown = count >= level
        let inset = CGFloat(level) * StackLayout.inset
        // Narrower cards get proportionally smaller corners, so the curves nest.
        let r = radius * (width - inset) / width
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous)
        let glow = level == 1 ? 0.22 : 0.14
        return shape
            .fill(Color.black)
            .overlay(shape.stroke(
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.55), .init(color: .white.opacity(glow), location: 1)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75))
            // Each card casts its own small shadow on the one behind.
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .frame(
                width: width - inset,
                height: height + (shown ? StackLayout.peeks[level - 1] : 0))
            .opacity(shown ? 1 : 0)
    }
}

/// A hairline along the island's bottom edge while cards sit behind it,
/// matching theirs.
struct FrontEdge: View {
    let radius: CGFloat
    let shown: Bool

    var body: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
            .stroke(
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.6), .init(color: .white.opacity(0.18), location: 1)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(false)
    }
}
