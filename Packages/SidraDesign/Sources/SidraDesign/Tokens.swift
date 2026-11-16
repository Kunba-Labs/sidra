import SwiftUI

/// Design tokens from design/sidra.css. Values are the mockup's, not approximations.
public enum SidraColor {
    public static let ground = Color(hex: 0x0c0e12)
    public static let ground2 = Color(hex: 0x101318)
    public static let pane = Color(hex: 0x12151a)
    public static let panel = Color(hex: 0x14181e)
    public static let raised = Color(hex: 0x191e25)
    public static let tabStrip = Color(hex: 0x13161b)
    public static let tabActive = Color(hex: 0x222831)
    public static let popup = Color(hex: 0x171b22)
    public static let hairline = Color.white.opacity(0.065)
    public static let hairline2 = Color.white.opacity(0.11)
    public static let text = Color(hex: 0xd9dde3)
    public static let textBright = Color(hex: 0xe9ecf0)
    public static let muted = Color(hex: 0x828b98)
    public static let dim = Color(hex: 0x5a626e)
    public static let lineNumber = Color(hex: 0x3f4651)
    public static let terminalText = Color(hex: 0xc8ccd2)
    public static let jade = Color(hex: 0x5ad6a0)
    public static let gold = Color(hex: 0xe8c46a)
    public static let red = Color(hex: 0xff6b6b)
    public static let yellow = Color(hex: 0xf3c35c)
    public static let blue = Color(hex: 0x7fc8ff)
    public static let violet = Color(hex: 0xb49cff)
    public static let orange = Color(hex: 0xe8894f)

    /// Syntax palette.
    public enum Syntax {
        public static let keyword = Color(hex: 0xff9178)
        public static let type = Color(hex: 0x7fc8ff)
        public static let function = Color(hex: 0xe8c46a)
        public static let string = Color(hex: 0xa4dc8e)
        public static let comment = Color(hex: 0x5d6674)
        public static let number = Color(hex: 0xf3a85c)
        public static let macro = Color(hex: 0x5ad6a0)
        public static let attribute = Color(hex: 0xb49cff)
        public static let lifetime = Color(hex: 0xc9a0ff)
        public static let punctuation = Color(hex: 0x8f98a4)
    }

    /// Process icon fills: flat solid squares with a dark glyph.
    public enum Process {
        public static let code = Color(hex: 0xff9178)
        public static let cargo = Color(hex: 0xff9178)
        public static let serial = Color(hex: 0xe8c46a)
        public static let mosh = Color(hex: 0x7fc8ff)
        public static let ssh = Color(hex: 0x7fc8ff)
        public static let agent = Color(hex: 0x5ad6a0)
        public static let git = Color(hex: 0xb49cff)
        /// Theasa's watch gold: the one colour Theasa gives itself.
        public static let theasa = Color(hex: 0xf0b429)
        /// HackerTab's orange, from the notes console it was ported from.
        public static let hackertab = Color(hex: 0xff6600)   // Hacker News's orange, for its Y mark
        /// Pipelines (GitLab CI): pink, so a red failure inside never reads as the tab's own colour.
        public static let pipelines = Color(hex: 0xf28cb8)
        /// Chess: lilac, the knight tile of design/html/12-chess.html.
        public static let chess = Color(hex: 0xc9a0ff)
        public static let glyph = Color(hex: 0x0f1216)
    }

    /// The chess board's squares: two greys a step above the pane, so pieces of both colours read.
    public enum Board {
        public static let light = Color(hex: 0x2a313b)
        public static let dark = Color(hex: 0x1b2028)
    }
}

/// The Sidra gradient. Selection and progress only: active tab border, focused pane border,
/// selected completion item bar, progress bars, spinners, toggles, context meter.
public enum SidraGradient {
    public static let stops: [Gradient.Stop] = [
        .init(color: Color(hex: 0xd6b6f2), location: 0.0),
        .init(color: Color(hex: 0xf2a487), location: 0.4),
        .init(color: Color(hex: 0xe8894f), location: 0.7),
        .init(color: Color(hex: 0xb8983a), location: 1.0),
    ]
    public static let horizontal = LinearGradient(gradient: Gradient(stops: stops), startPoint: .leading, endPoint: .trailing)
    public static let angular = AngularGradient(gradient: Gradient(stops: stops), center: .center)
}

public enum SidraRadius {
    public static let pane: CGFloat = 14
    public static let tab: CGFloat = 10
    public static let tabStrip: CGFloat = 13
    public static let popup: CGFloat = 10
    public static let sheet: CGFloat = 18
    public static let pill: CGFloat = 9
    public static let icon: CGFloat = 6
    public static let card: CGFloat = 12
}

public enum SidraSpace {
    public static let gap: CGFloat = 12
    /// A split never squeezes a pane below this many points.
    public static let minPaneLength: CGFloat = 160
    public static let titleBarHeight: CGFloat = 60
    public static let paneHeaderHeight: CGFloat = 42
    public static let paneFooterHeight: CGFloat = 30
    public static let workspaceInset = EdgeInsets(top: 4, leading: 14, bottom: 14, trailing: 14)
}

public enum SidraFont {
    public static let uiFamily = "Inter"
    public static let monoFamily = "JetBrains Mono"

    public static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "Inter-Regular" : "Inter-Bold", size: size)
            .weight(weight)
    }
    public static func mono(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .custom("JetBrainsMono-Regular", fixedSize: size).weight(weight)   // code does not follow Dynamic Type (spec); Inter above does
    }
    public static let monoSize: CGFloat = 13
    public static let monoLineHeight: CGFloat = 20
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

#if canImport(UIKit)
import UIKit
public extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: alpha)
    }
}
#endif

/// Thermal state used by redraw throttling and build pausing. `-sidra.thermal serious|critical`
/// (the argument domain of UserDefaults) simulates it: the Simulator always reports nominal.
public enum ThermalPolicy {
    public static var state: ProcessInfo.ThermalState {
        switch UserDefaults.standard.string(forKey: "sidra.thermal") {
        case "fair": .fair
        case "serious": .serious
        case "critical": .critical
        default: ProcessInfo.processInfo.thermalState
        }
    }
    /// Seconds between redraws of the terminal and plotter; 0 means no limit (spec: 10 Hz at serious).
    public static var redrawInterval: TimeInterval { state.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? 0.1 : 0 }
}

/// Coalesces redraw requests to at most one per `interval`. Interval 0 draws every request.
@MainActor
public final class RedrawGate {
    private var last = Date.distantPast
    private var pending = false
    private let interval: () -> TimeInterval
    public init(interval: @escaping () -> TimeInterval = { ThermalPolicy.redrawInterval }) { self.interval = interval }
    public func request(_ draw: @escaping @MainActor () -> Void) {
        let gap = interval()
        guard gap > 0 else { draw(); return }
        guard !pending else { return }
        let wait = gap - Date().timeIntervalSince(last)
        if wait <= 0 { last = Date(); draw(); return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false; self.last = Date(); draw()
            }
        }
    }
}
