#if os(iOS)
import SwiftUI
import UIKit
import SidraDesign
import SidraTerminal

/// iPhone (Waseem, 2026-11-26): Apple's keyboard in place of Sidra's own, typing into a compose bar above it.
/// Nothing reaches the terminal until Send (the keyboard's return): then the whole text goes in one paste,
/// followed by Enter. A pasted image shows as "[Image 1]" and is uploaded, and replaced by its path, on Send.
/// The keys row (esc, tab, arrows, ^C) acts on the terminal at once, for menus and dialogs.
@MainActor @Observable
final class Compose {
    static let shared = Compose()
    var open = false
    var text = ""
    /// Bumped to give the text view the keyboard (a terminal tap).
    var focus = 0
    @ObservationIgnored var images: [Int: Data] = [:]
    @ObservationIgnored private var nextImage = 1
    var sending = false

    private init() {}

    static var enabled: Bool { Platform.isPhone }

    /// Installed at launch on iPhone: a terminal tap opens the bar instead of a keyboard on the terminal.
    static func install() {
        guard enabled else { return }
        GhosttyTerminalView.composer = { _ in Compose.shared.show() }
        #if DEBUG
        // -sidra.composeDemo "text" (screenshots): the bar open with that draft and an image token.
        if let t = UserDefaults.standard.string(forKey: "sidra.composeDemo") {
            let c = Compose.shared
            c.text = t + " " + c.addImage(Data())
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { c.show() }
        }
        #endif
    }

    func show() { open = true; focus += 1 }
    func hide() { open = false; UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }

    /// The token a pasted image stands as until Send.
    func addImage(_ data: Data) -> String {
        let n = nextImage; nextImage += 1
        images[n] = data
        return "[Image \(n)]"
    }

    var target: GhosttyTerminalView? { GhosttyTerminalView.lastFocused }

    func key(_ k: TerminalKey) { target?.send(k) }

    /// Uploads the images the text still names, then pastes it all and presses Enter. Empty: Enter only.
    func send() {
        guard !sending else { return }
        guard let t = target else { SidraToast.show("Tap a terminal first."); return }
        let draft = text, pics = images
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { t.send(.enter); text = ""; return }
        sending = true
        Task {
            defer { sending = false }
            var out = draft
            for (n, data) in pics.sorted(by: { $0.key < $1.key }) {
                let token = "[Image \(n)]"
                guard out.contains(token) else { continue }
                guard let upload = t.onPasteImage else { SidraToast.show("This pane cannot take images."); return }
                guard let path = await upload(data) else { return }   // the pane shows why; the draft stays
                out = out.replacingOccurrences(of: token, with: path)
            }
            t.pasteText(out)
            // ponytail: Claude Code can take an Enter right after a paste as part of it; a short gap keeps them apart.
            try? await Task.sleep(for: .milliseconds(80))
            t.send(.enter)
            if text == draft { text = ""; images = [:]; nextImage = 1 }
        }
    }
}

/// Toasts from outside a view: AppModel's, through a hook RootView sets.
@MainActor enum SidraToast {
    static var show: (String) -> Void = { _ in }
}

struct ComposeBar: View {
    @State private var c = Compose.shared

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc") { c.key(.escape) }
                    key("tab") { c.key(.tab) }
                    key("↑") { c.key(.up) }
                    key("↓") { c.key(.down) }
                    key("←") { c.key(.left) }
                    key("→") { c.key(.right) }
                    key("^C") { c.key(.ctrl("c")) }
                    key("⏎") { c.key(.enter) }
                }
                .padding(.horizontal, 10)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { c.hide() } label: {
                    Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 16)).foregroundStyle(SidraColor.muted).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain).accessibilityLabel("Hide keyboard")
                ComposeTextView(text: $c.text, focus: c.focus, onSend: { c.send() })
                    .frame(minHeight: 40)
                    .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SidraColor.hairline2))
                Button { c.send() } label: {
                    Group { if c.sending { ProgressView() } else { Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)) } }
                        .foregroundStyle(SidraColor.ground).frame(width: 40, height: 40)
                        .background(SidraColor.jade, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Send")
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 8)
        .background(SidraColor.raised)
        .overlay(alignment: .top) { Rectangle().fill(SidraColor.hairline).frame(height: 1) }
    }

    private func key(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(SidraFont.mono(13, weight: .semibold)).foregroundStyle(SidraColor.text)
                .padding(.horizontal, 12).frame(minWidth: 44, minHeight: 34)
                .background(SidraColor.tabActive, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// A UITextView: return sends (a pasted newline stays), and an image paste becomes an "[Image n]" token.
private struct ComposeTextView: UIViewRepresentable {
    @Binding var text: String
    let focus: Int
    let onSend: () -> Void

    func makeUIView(context: Context) -> Field {
        let v = Field()
        v.delegate = context.coordinator
        v.font = UIFont(name: "Inter-Regular", size: 16) ?? .systemFont(ofSize: 16)
        v.textColor = UIColor(SidraColor.text)
        v.tintColor = UIColor(SidraColor.jade)
        v.backgroundColor = .clear
        v.returnKeyType = .send
        v.smartQuotesType = .no
        v.smartDashesType = .no
        v.keyboardAppearance = .dark
        v.textContainerInset = UIEdgeInsets(top: 10, left: 6, bottom: 10, right: 6)
        v.isScrollEnabled = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: Field, context: Context) {
        if v.text != text { v.text = text }
        context.coordinator.parent = self
        if context.coordinator.focus != focus {
            context.coordinator.focus = focus
            DispatchQueue.main.async { v.becomeFirstResponder() }
        }
        v.isScrollEnabled = v.contentSize.height > 140
    }

    /// Grows with the text up to about five lines, then scrolls.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Field, context: Context) -> CGSize? {
        let w = proposal.width ?? 300
        let h = uiView.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
        return CGSize(width: w, height: min(max(h, 40), 140))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposeTextView
        var focus = 0
        init(_ p: ComposeTextView) { parent = p }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText t: String) -> Bool {
            if t == "\n" { parent.onSend(); return false }   // the return key; a pasted newline is longer than one character
            return true
        }
        func textViewDidChange(_ v: UITextView) { parent.text = v.text }
    }

    final class Field: UITextView {
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)) { return UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages }
            return super.canPerformAction(action, withSender: sender)
        }
        override func paste(_ sender: Any?) {
            let board = UIPasteboard.general
            guard !board.hasStrings, let data = board.image?.pngData() else { return super.paste(sender) }
            insertText(MainActor.assumeIsolated { Compose.shared.addImage(data) } + " ")
        }
    }
}
#endif
