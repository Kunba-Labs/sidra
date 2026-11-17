#if os(macOS)
import AppKit
import SidraDesign

/// The Mac window has no title bar of its own (`.hiddenTitleBar`): Sidra's tab bar takes its place, and
/// the system traffic lights move into it, centred on the bar. They stay Apple's buttons, so hover
/// glyphs, Option-zoom and full screen behave as everywhere else.
@MainActor public enum WindowChrome {
    /// Room the tab bar leaves at its left for the three buttons.
    static let trafficLightsWidth: CGFloat = 72
    private static let leading: CGFloat = 18, spacing: CGFloat = 8
    /// Observer tokens per open window; dropped when it closes, so a reused identifier starts clean.
    private static var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    /// Places the buttons now and again whenever AppKit lays the title bar out afresh.
    public static func install(on window: NSWindow) {
        place(window)
        let id = ObjectIdentifier(window)
        guard observers[id] == nil else { return }
        let nc = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                                          NSWindow.didBecomeKeyNotification, NSWindow.didEndLiveResizeNotification]
        for name in names {
            tokens.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window { place(window) } }
            })
        }
        // AppKit lays its 28 pt title bar out again on its own (focus, toolbar, appearance); follow it.
        if let container = window.standardWindowButton(.closeButton)?.superview?.superview {
            container.postsFrameChangedNotifications = true
            tokens.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: container, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if let window, !placing { place(window) } }
            })
        }
        tokens.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { observers.removeValue(forKey: id)?.forEach(nc.removeObserver) }
        })
        observers[id] = tokens
    }
    private static var placing = false

    /// The title bar container grows to the tab bar's height and the buttons sit on its centre line.
    static func place(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        placing = true; defer { placing = false }
        let height = SidraSpace.titleBarHeight
        container.frame = NSRect(x: container.frame.minX, y: window.frame.height - height, width: container.frame.width, height: height)
        var x = leading
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let b = window.standardWindowButton(kind) else { continue }
            b.setFrameOrigin(NSPoint(x: x, y: (height - b.frame.height) / 2))
            x += b.frame.width + spacing - 2
        }
    }

    /// A double-click on the bar does what the user set in System Settings: zoom (the default),
    /// minimise, or nothing.
    static func zoomOnDoubleClick() {
        guard let w = NSApp.keyWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": w.miniaturize(nil)
        case "None": break
        default: w.zoom(nil)
        }
    }
}
#endif
