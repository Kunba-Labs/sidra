#if os(macOS)
import AppKit
import SwiftUI
import SidraDesign

/// SwiftUI face of a terminal on the Mac: always the Ghostty view. `engine` is accepted for the shared
/// signature; the SwiftTerm fallback is an iPad setting. Inline image thumbnails are iOS-only for now.
public struct TerminalPaneView: NSViewRepresentable {
    let io: TerminalIO
    var onTitle: ((String) -> Void)?
    var focusToken: Int
    var searchQuery: String?
    var searchStep: Int
    var onFind: (() -> Void)?
    var onSearchResult: ((Int, Int?) -> Void)?
    var onPasteImage: ((Data) async -> String?)?
    var onOpenLink: ((URL) -> Void)?
    var lost: Bool

    public init(io: TerminalIO, engine: TerminalEngineKind = .ghostty, focusToken: Int = 0, onTitle: ((String) -> Void)? = nil,
                searchQuery: String? = nil, searchStep: Int = 0, onFind: (() -> Void)? = nil, onSearchResult: ((Int, Int?) -> Void)? = nil,
                onPasteImage: ((Data) async -> String?)? = nil, pasteLabel: String = "⌘V",
                onFetchImage: ((String) async -> Data?)? = nil, onOpenImage: ((String, PlatformImage) -> Void)? = nil, onOpenLink: ((URL) -> Void)? = nil, lost: Bool = false) {
        self.io = io
        self.focusToken = focusToken
        self.onTitle = onTitle
        self.searchQuery = searchQuery
        self.searchStep = searchStep
        self.onFind = onFind
        self.onSearchResult = onSearchResult
        self.onPasteImage = onPasteImage
        self.onOpenLink = onOpenLink
        self.lost = lost
    }

    /// One surface per session, kept while the pane lives (see the iOS TerminalPaneView).
    @MainActor private static var surfaces: [ObjectIdentifier: GhosttyMacView] = [:]
    @MainActor public static func forget(_ io: TerminalIO) { surfaces[ObjectIdentifier(io)] = nil }

    public func makeNSView(context: Context) -> GhosttyMacView {
        if let kept = Self.surfaces[ObjectIdentifier(io)] { return kept }
        let v = GhosttyMacView(io: io)
        Self.surfaces[ObjectIdentifier(io)] = v
        return v
    }

    public func updateNSView(_ g: GhosttyMacView, context: Context) {
        g.onTitle = onTitle
        g.onFind = onFind
        g.onSearchResult = onSearchResult
        g.onPasteImage = onPasteImage
        g.onOpenLink = onOpenLink
        g.lost = lost
        if context.coordinator.lastQuery != searchQuery {
            context.coordinator.lastQuery = searchQuery
            g.search(searchQuery)
        }
        if context.coordinator.lastStep != searchStep {
            let forward = searchStep > context.coordinator.lastStep
            context.coordinator.lastStep = searchStep
            if forward { g.searchNext() } else { g.searchPrevious() }
        }
        guard context.coordinator.lastFocusToken != focusToken else { return }
        context.coordinator.lastFocusToken = focusToken
        g.wantsFocus = focusToken != 0
        DispatchQueue.main.async { g.applyFocus() }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }
    public final class Coordinator {
        var lastFocusToken = Int.min
        var lastQuery: String? = nil
        var lastStep = 0
    }
}
#endif
