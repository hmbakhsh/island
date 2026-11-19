import AppKit
import IslandCore
import SwiftUI

/// The command bar's live state, shared by the island and its view.
final class ComposerModel: ObservableObject {
    @Published var composer: Composer
    /// Grok's roster, for bot names and avatars.
    @Published var grokBots: [GrokBot] = []
    /// Effects of a key, for the island to carry out.
    var onEffects: (([Composer.Effect]) -> Void)?
    /// The bar's height changed (the picker opened, a filter narrowed it).
    var onResize: (() -> Void)?

    init() {
        composer = Composer(
            bots: [], projects: [],
            lastTarget: Config.shared.composerLastTarget.flatMap(Target.init(stored:)))
    }

    func press(_ key: Composer.Key) -> Bool {
        let before = composer.rows.count
        let mode = composer.mode
        guard let effects = composer.press(key) else { return false }
        if !effects.isEmpty { onEffects?(effects) }
        if composer.mode != mode || composer.rows.count != before { onResize?() }
        return true
    }

    func edit(_ text: String) {
        let before = composer.rows.count
        composer.setText(text)
        if composer.rows.count != before { onResize?() }
    }

    func name(of target: Target) -> String {
        switch target {
        case .chatgpt: return "ChatGPT"
        case .grok(let id): return grokBots.first { $0.id == id }?.name ?? "Grok"
        case .t3(let root):
            if let p = composer.projects.first(where: { $0.root == root }) { return p.scratch ? "No project" : p.name }
            return (root as NSString).lastPathComponent
        }
    }

    func bot(_ id: String) -> GrokBot? { grokBots.first { $0.id == id } }
}

enum ComposerLayout {
    static let width: CGFloat = 460
    /// Field and rows share one radius and inset; the island's corner is their sum.
    static let radius: CGFloat = 18
    static let inset: CGFloat = 10
    static let fieldHeight: CGFloat = 38
    static let rowHeight: CGFloat = 38
    static let detailRowHeight: CGFloat = 46
    static let maxList: CGFloat = 330

    static func height(_ c: Composer) -> CGFloat {
        let bar: CGFloat = 4 + 6 + fieldHeight + 10
        guard case .picker = c.mode else { return bar }
        return bar + 4 + listHeight(c)
    }

    static func listHeight(_ c: Composer) -> CGFloat {
        let rows = c.rows.isEmpty ? rowHeight : c.rows.reduce(0) { $0 + ($1.detail == nil ? rowHeight : detailRowHeight) }
        return min(rows, maxList)
    }
}

/// App icons and Grok avatars for rows, chips and banners.
enum TargetIcon {
    static let chatgptID = "com.openai.codex"

    static func app(_ bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    static var t3Path: String? { T3.appURL?.path }
    static var chatgptPath: String? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: chatgptID)?.path }

    /// Pre-rendered from Grok Bot's own avatar code (Resources/GrokAvatars).
    static func avatarPath(shape: String?, color: String?) -> String? {
        let name = "\(shape ?? "blob")-\(color ?? "black").svg"
        let dirs = [
            Bundle.main.resourceURL?.appendingPathComponent("GrokAvatars"),
            // swift run: straight from the source tree.
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/GrokAvatars"),
        ]
        for dir in dirs.compactMap({ $0 }) {
            let path = dir.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        let fallback = dirs.compactMap { $0?.appendingPathComponent("blob-black.svg").path }
        return fallback.first { FileManager.default.fileExists(atPath: $0) }
    }

    private static var cache: [String: NSImage] = [:]

    static func image(_ target: Target, model: ComposerModel) -> (image: NSImage?, avatar: Bool) {
        switch target {
        case .chatgpt: return (cached("app:" + chatgptID) { app(chatgptID) }, false)
        case .t3: return (cached("app:t3") { T3.appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }, false)
        case .grok(let id):
            let bot = model.bot(id)
            guard let path = avatarPath(shape: bot?.avatarShape, color: bot?.avatarColor) else { return (nil, true) }
            return (cached(path) { NSImage(contentsOfFile: path) }, true)
        }
    }

    private static func cached(_ key: String, _ make: () -> NSImage?) -> NSImage? {
        if let image = cache[key] { return image }
        let image = make()
        cache[key] = image
        return image
    }
}

/// An icon at a size. Grok avatars are drawn with room around them, so they
/// draw larger than their box to look the same size as app icons.
struct TargetImage: View {
    let target: Target
    @ObservedObject var model: ComposerModel
    let size: CGFloat

    var body: some View {
        let icon = TargetIcon.image(target, model: model)
        Group {
            if let image = icon.image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: size * (icon.avatar ? 1.4 : 1.15), height: size * (icon.avatar ? 1.4 : 1.15))
            } else {
                Circle().fill(Color.white.opacity(0.2))
            }
        }
        .frame(width: size, height: size)
    }
}

struct ComposerView: View {
    @ObservedObject var model: ComposerModel

    var body: some View {
        let c = model.composer
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                chip
                ComposerField(model: model)
                    .frame(height: 20)
            }
            .padding(.horizontal, 12)
            .frame(height: ComposerLayout.fieldHeight)
            .background(RoundedRectangle(cornerRadius: ComposerLayout.radius, style: .continuous).fill(Color.white.opacity(0.08)))
            .padding(.top, 6)

            if case .picker = c.mode {
                list(c).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ComposerLayout.inset)
        .padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var chip: some View {
        let c = model.composer
        switch c.mode {
        case .bar:
            chipBody(target: c.target, name: model.name(of: c.target))
        case .picker(.projects):
            chipBody(target: .t3(""), name: "T3 Code ›")
        default:
            EmptyView()
        }
    }

    private func chipBody(target: Target, name: String) -> some View {
        HStack(spacing: 6) {
            TargetImage(target: target, model: model, size: 18)
            Text(name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(.white)
        .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .frame(maxWidth: 190, alignment: .leading)
        .fixedSize()
    }

    private func list(_ c: Composer) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if c.rows.isEmpty {
                        Text("Nothing matches “\(c.query)”")
                            .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity, minHeight: ComposerLayout.rowHeight, alignment: .leading)
                            .padding(.horizontal, 14)
                    }
                    ForEach(Array(c.rows.enumerated()), id: \.offset) { index, row in
                        ComposerRow(row: row, model: model, selected: index == c.selection).id(index)
                    }
                }
            }
            .frame(height: ComposerLayout.listHeight(c))
            // A fresh scroll position per level: the project list's offset would carry over.
            .id(c.mode == .picker(.projects) ? "projects" : "top")
            .onChange(of: c.selection) { _, new in proxy.scrollTo(new) }
        }
    }
}

private struct ComposerRow: View {
    let row: Composer.Row
    @ObservedObject var model: ComposerModel
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 11) {
            TargetImage(target: target, model: model, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                if let detail = row.detail {
                    Text((detail as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if row.kind == .t3Code {
                Text("›").font(.system(size: 16)).foregroundStyle(.white.opacity(0.35)).padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: row.detail == nil ? ComposerLayout.rowHeight : ComposerLayout.detailRowHeight)
        .background(
            RoundedRectangle(cornerRadius: ComposerLayout.radius, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.1 : hovered ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.choose(row) }
    }

    private var target: Target {
        if case .target(let t) = row.kind { return t }
        return .t3("")
    }
}

extension ComposerModel {
    /// A click on a row: select it, then act as ⏎ would.
    func choose(_ row: Composer.Row) {
        guard let index = composer.rows.firstIndex(of: row) else { return }
        while composer.selection != index { _ = composer.press(.down) }
        _ = press(.enter)
    }
}

/// The text field. Keys the bar acts on are taken before the field sees them;
/// everything else (typing, pasting, Hex dictation) edits the text.
struct ComposerField: NSViewRepresentable {
    @ObservedObject var model: ComposerModel

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = .white
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let c = model.composer
        if field.stringValue != c.field {
            field.stringValue = c.field
            field.currentEditor()?.selectedRange = NSRange(location: (c.field as NSString).length, length: 0)
        }
        field.placeholderAttributedString = NSAttributedString(
            string: c.placeholder,
            attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.35), .font: NSFont.systemFont(ofSize: 14)])
        (field.currentEditor() as? NSTextView)?.insertionPointColor = .white
        if c.mode != .closed, field.window?.isKeyWindow == true, field.currentEditor() == nil {
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: ComposerModel
        init(model: ComposerModel) { self.model = model }

        func controlTextDidBeginEditing(_ note: Notification) {
            ((note.object as? NSTextField)?.currentEditor() as? NSTextView)?.insertionPointColor = .white
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            model.edit(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let key: Composer.Key? = switch selector {
            case #selector(NSResponder.insertNewline(_:)): .enter
            case #selector(NSResponder.insertTab(_:)): .tab
            case #selector(NSResponder.cancelOperation(_:)): .escape
            case #selector(NSResponder.deleteBackward(_:)): .backspace
            case #selector(NSResponder.moveUp(_:)): .up
            case #selector(NSResponder.moveDown(_:)): .down
            default: nil
            }
            // The Esc some setups send as Caps Lock (the bar's key) comes up.
            if key == .escape, Trigger.capsEscape { return true }
            guard let key else { return false }
            return model.press(key)
        }
    }
}
