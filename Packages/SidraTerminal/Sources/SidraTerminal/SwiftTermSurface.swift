import UIKit
import SwiftTerm

/// Fallback engine: SwiftTerm's own view wired to the same `TerminalIO`.
public final class SwiftTermSurface: UIView, TerminalViewDelegate {
    private let io: TerminalIO
    private let terminal: PasteTerminalView
    public var onPasteImage: ((Data) async -> String?)? {
        get { terminal.onPasteImage } set { terminal.onPasteImage = newValue }
    }
    private var readTask: Task<Void, Never>?

    public init(io: TerminalIO) {
        self.io = io
        terminal = PasteTerminalView(frame: .zero)
        super.init(frame: .zero)
        terminal.terminalDelegate = self
        terminal.nativeBackgroundColor = UIColor(red: 0x12 / 255, green: 0x15 / 255, blue: 0x1a / 255, alpha: 1)
        terminal.nativeForegroundColor = UIColor(red: 0xc8 / 255, green: 0xcc / 255, blue: 0xd2 / 255, alpha: 1)
        if let f = UIFont(name: "JetBrainsMono-Regular", size: 13) { terminal.font = f }
        addSubview(terminal)
        readTask = Task { [weak self] in
            for await chunk in io.output {
                guard let self else { return }
                await MainActor.run { self.terminal.feed(byteArray: ArraySlice(chunk)) }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { readTask?.cancel() }

    public override func layoutSubviews() {
        super.layoutSubviews()
        terminal.frame = bounds
    }

    public override func becomeFirstResponder() -> Bool { terminal.becomeFirstResponder() }

    // MARK: TerminalViewDelegate

    public func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        io.resize(cols: newCols, rows: newRows)
    }
    public func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    public func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        io.write(Data(data))
    }
    public func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    public func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    public func bell(source: SwiftTerm.TerminalView) {}
    public func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }
    public func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    public func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

/// SwiftTerm's view, with an image on the clipboard pasted as a remote file path (as in the Ghostty view).
final class PasteTerminalView: SwiftTerm.TerminalView {
    var onPasteImage: ((Data) async -> String?)?
    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        guard !board.hasStrings, let upload = onPasteImage, let data = board.image?.pngData() else { return super.paste(sender) }
        Task { @MainActor [weak self] in
            // Focus may have moved during the upload: then the path goes to the clipboard instead.
            guard let path = await upload(data) else { return }
            if let self, self.isFirstResponder { self.pasteText(path) } else { UIPasteboard.general.string = path }
        }
    }
}
