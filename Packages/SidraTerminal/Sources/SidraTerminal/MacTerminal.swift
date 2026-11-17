#if os(macOS)
import AppKit
import SwiftUI
import SwiftTerm
import SidraDesign

/// The Mac terminal: SwiftTerm's AppKit view wired to a `TerminalIO`. It brings selection, mouse,
/// scrollback and the hardware keyboard with it.
/// ponytail: SwiftTerm on every Mac pane; port GhosttyTerminalView to AppKit when Ghostty's rendering or search is missed.
public final class MacTerminalSurface: SwiftTerm.TerminalView, TerminalViewDelegate {
    private let io: TerminalIO
    private var readTask: Task<Void, Never>?
    var onTitle: ((String) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var onPasteImage: ((Data) async -> String?)?

    public init(io: TerminalIO, fontSize: CGFloat = 14) {
        self.io = io
        super.init(frame: .zero)
        terminalDelegate = self
        nativeBackgroundColor = NSColor(red: 0x12 / 255, green: 0x15 / 255, blue: 0x1a / 255, alpha: 1)
        nativeForegroundColor = NSColor(red: 0xc8 / 255, green: 0xcc / 255, blue: 0xd2 / 255, alpha: 1)
        if let f = NSFont(name: "JetBrainsMono-Regular", size: fontSize) { font = f }
        readTask = Task { [weak self] in
            for await chunk in io.output {
                guard let self else { return }
                await MainActor.run { self.feed(byteArray: ArraySlice(chunk)) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { readTask?.cancel() }

    /// An image on the clipboard is uploaded and pasted as its remote path, as on iPad.
    public override func paste(_ sender: Any) {
        let board = NSPasteboard.general
        guard board.string(forType: .string) == nil, let upload = onPasteImage,
              let tiff = NSImage(pasteboard: board)?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return super.paste(sender) }
        Task { @MainActor [weak self] in
            guard let path = await upload(png) else { return }
            self?.send(txt: path)
        }
    }

    public func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { io.resize(cols: newCols, rows: newRows) }
    public func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { onTitle?(title) }
    public func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    public func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { io.write(Data(data)) }
    public func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    public func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        if let open = onOpenLink { open(url) } else { NSWorkspace.shared.open(url) }
    }
    public func bell(source: SwiftTerm.TerminalView) { NSSound.beep() }
    public func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
    }
    public func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    public func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

/// SwiftUI face of a terminal on the Mac. Same signature as the iOS one; scrollback search and
/// inline images are iOS-only for now, so those parameters are accepted and ignored.
public struct TerminalPaneView: NSViewRepresentable {
    let io: TerminalIO
    var onTitle: ((String) -> Void)?
    var focusToken: Int
    var onPasteImage: ((Data) async -> String?)?
    var onOpenLink: ((URL) -> Void)?

    public init(io: TerminalIO, engine: TerminalEngineKind = .ghostty, focusToken: Int = 0, onTitle: ((String) -> Void)? = nil,
                searchQuery: String? = nil, searchStep: Int = 0, onFind: (() -> Void)? = nil, onSearchResult: ((Int, Int?) -> Void)? = nil,
                onPasteImage: ((Data) async -> String?)? = nil, pasteLabel: String = "⌘V",
                onFetchImage: ((String) async -> Data?)? = nil, onOpenImage: ((String, PlatformImage) -> Void)? = nil, onOpenLink: ((URL) -> Void)? = nil, lost: Bool = false) {
        self.io = io
        self.focusToken = focusToken
        self.onTitle = onTitle
        self.onPasteImage = onPasteImage
        self.onOpenLink = onOpenLink
    }

    /// One surface per session, kept while the pane lives (see the iOS TerminalPaneView).
    @MainActor private static var surfaces: [ObjectIdentifier: MacTerminalSurface] = [:]
    @MainActor public static func forget(_ io: TerminalIO) { surfaces[ObjectIdentifier(io)] = nil }

    public func makeNSView(context: Context) -> MacTerminalSurface {
        let v = Self.surfaces[ObjectIdentifier(io)] ?? MacTerminalSurface(io: io)
        Self.surfaces[ObjectIdentifier(io)] = v
        update(v)
        return v
    }

    public func updateNSView(_ v: MacTerminalSurface, context: Context) {
        update(v)
        guard context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        if focusToken != 0 { DispatchQueue.main.async { v.window?.makeFirstResponder(v) } }
    }

    private func update(_ v: MacTerminalSurface) {
        v.onTitle = onTitle
        v.onPasteImage = onPasteImage
        v.onOpenLink = onOpenLink
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }
    public final class Coordinator { var lastFocusToken = -1 }
}
#endif
