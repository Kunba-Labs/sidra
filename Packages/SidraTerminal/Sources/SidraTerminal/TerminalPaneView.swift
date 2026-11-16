import SwiftUI
import SidraDesign
import UIKit

/// SwiftUI face of a terminal: picks the engine and hosts the UIKit surface.
public struct TerminalPaneView: UIViewRepresentable {
    let io: TerminalIO
    let engine: TerminalEngineKind
    var onTitle: ((String) -> Void)? = nil
    var focusToken: Int = 0
    /// Scrollback search: nil hides highlights; `searchStep` increments step to the next (+) or
    /// previous (−) match; `onFind` fires on Cmd-F inside the terminal.
    var searchQuery: String? = nil
    var searchStep: Int = 0
    var onFind: (() -> Void)? = nil
    var onSearchResult: ((Int, Int?) -> Void)? = nil
    var onPasteImage: ((Data) async -> String?)? = nil
    var pasteLabel = "⌘V"
    var onFetchImage: ((String) async -> Data?)? = nil
    var onOpenImage: ((String, UIImage) -> Void)? = nil
    var onOpenLink: ((URL) -> Void)? = nil
    /// The host went away: the screen rots and keys go nowhere.
    var lost = false

    public init(io: TerminalIO, engine: TerminalEngineKind = .ghostty, focusToken: Int = 0, onTitle: ((String) -> Void)? = nil,
                searchQuery: String? = nil, searchStep: Int = 0, onFind: (() -> Void)? = nil, onSearchResult: ((Int, Int?) -> Void)? = nil,
                onPasteImage: ((Data) async -> String?)? = nil, pasteLabel: String = "⌘V",
                onFetchImage: ((String) async -> Data?)? = nil, onOpenImage: ((String, UIImage) -> Void)? = nil, onOpenLink: ((URL) -> Void)? = nil, lost: Bool = false) {
        self.onOpenLink = onOpenLink
        self.lost = lost
        self.onPasteImage = onPasteImage
        self.onFetchImage = onFetchImage
        self.onOpenImage = onOpenImage
        self.pasteLabel = pasteLabel
        self.io = io
        self.engine = engine
        self.focusToken = focusToken
        self.onTitle = onTitle
        self.searchQuery = searchQuery
        self.searchStep = searchStep
        self.onFind = onFind
        self.onSearchResult = onSearchResult
    }

    /// One surface per session, kept while the pane lives: it keeps reading the session's output (a
    /// stream only one reader can drain) while its tab is hidden, so switching back shows the same
    /// screen and scrollback instead of reconnecting. `forget` when the session closes.
    @MainActor private static var surfaces: [ObjectIdentifier: (engine: TerminalEngineKind, view: UIView)] = [:]
    @MainActor public static func forget(_ io: TerminalIO) { surfaces[ObjectIdentifier(io)] = nil }

    public func makeUIView(context: Context) -> UIView {
        if let kept = Self.surfaces[ObjectIdentifier(io)], kept.engine == engine {
            if let g = kept.view as? GhosttyTerminalView { g.onTitle = onTitle }
            return kept.view
        }
        let v = makeSurface()
        Self.surfaces[ObjectIdentifier(io)] = (engine, v)
        return v
    }

    private func makeSurface() -> UIView {
        switch engine {
        case .ghostty:
            // -sidra.fontSize N (UI tests) shrinks the grid so vttest gets its 24 rows with the keyboard up.
            let size: CGFloat = CommandLine.arguments.firstIndex(of: "-sidra.fontSize").flatMap { i in i + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[i + 1]) : nil }.map { CGFloat($0) } ?? 13
            let v = GhosttyTerminalView(io: io, fontSize: size)
            v.onTitle = onTitle
            v.onFind = onFind
            v.onSearchResult = onSearchResult
            v.onPasteImage = onPasteImage
            v.onFetchImage = onFetchImage
            v.onOpenImage = onOpenImage
            v.onOpenLink = onOpenLink
            v.pasteLabel = pasteLabel
            return v
        case .swiftTerm:
            let v = SwiftTermSurface(io: io)
            v.onPasteImage = onPasteImage
            return v
        }
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        if let g = uiView as? GhosttyTerminalView {
            g.onFind = onFind
            g.onSearchResult = onSearchResult
            g.onPasteImage = onPasteImage
            g.onFetchImage = onFetchImage
            g.onOpenImage = onOpenImage
            g.onOpenLink = onOpenLink
            g.lost = lost
            if g.pasteLabel != pasteLabel { g.pasteLabel = pasteLabel }
            if context.coordinator.lastQuery != searchQuery {
                context.coordinator.lastQuery = searchQuery
                g.search(searchQuery)
            }
            if context.coordinator.lastStep != searchStep {
                let forward = searchStep > context.coordinator.lastStep
                context.coordinator.lastStep = searchStep
                if forward { g.searchNext() } else { g.searchPrevious() }
            }
        }
        (uiView as? SwiftTermSurface)?.onPasteImage = onPasteImage
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            if CommandLine.arguments.contains("-sidra.noAutoFocus") { return }  // ponytail: UI tests keep the software keyboard down
            // Hidden tabs stay built; an unfocused terminal gives the keyboard up instead of taking it.
            DispatchQueue.main.async { if focusToken != 0 { _ = uiView.becomeFirstResponder() } else if uiView.isFirstResponder { _ = uiView.resignFirstResponder() } }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var lastFocusToken = -1
        var lastQuery: String? = nil
        var lastStep = 0
    }
}
