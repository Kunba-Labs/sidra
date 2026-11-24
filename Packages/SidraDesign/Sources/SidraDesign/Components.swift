import SwiftUI

// MARK: - Process icon

/// Flat solid square with a dark glyph. No tint, no transparency, no glow.
public struct ProcessIcon: View {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case code, cargo, serial, ssh, mosh, agent, git, herdr, theasa, hackertab, pipelines, chess, claude, vnc, substrate

        public var fill: Color {
            switch self {
            case .code: SidraColor.Process.code
            case .cargo: SidraColor.Process.cargo
            case .serial: SidraColor.Process.serial
            case .ssh, .mosh: SidraColor.Process.mosh
            case .agent: SidraColor.Process.agent
            case .git: SidraColor.Process.git
            case .herdr: .white
            case .theasa: SidraColor.Process.theasa
            case .hackertab: SidraColor.Process.hackertab
            case .pipelines: SidraColor.Process.pipelines
            case .chess: SidraColor.Process.chess
            case .claude: Color(hex: 0xf0eee6)   // Claude's cream, under its spark
            case .vnc: SidraColor.Process.mosh
            case .substrate: .black
            }
        }
        public var symbol: String {
            switch self {
            case .code: "chevron.left.forwardslash.chevron.right"
            case .cargo: "shippingbox"
            case .serial: "cpu"
            case .ssh, .mosh: "terminal"
            case .agent: "sparkle"
            case .git: "arrow.triangle.branch"
            case .herdr: "terminal"
            case .theasa: "eye"
            case .hackertab: "y.square.fill"   // menus; the tile draws Hacker News's Y
            case .pipelines: "point.3.connected.trianglepath.dotted"
            case .claude: "globe"
            case .vnc: "display"
            case .chess: "crown.fill"   // SF Symbols has no knight; the tile draws ♞ instead, menus use this
            case .substrate: "circle.fill"   // menus; the tile draws Substrate's orb
            }
        }
    }

    let kind: Kind
    let size: CGFloat

    public init(_ kind: Kind, size: CGFloat = 20) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        if kind == .herdr || kind == .substrate {
            // herdr's and Substrate's own marks, unaltered (app-target assets)
            Image(kind == .herdr ? "brand-herdr" : "brand-substrate").resizable().scaledToFill().frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .accessibilityHidden(true)
        } else {
            tile
        }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(kind.fill)
            .frame(width: size, height: size)
            .overlay {
                if kind == .hackertab {
                    // Hacker News's mark, as asked (2026-11-15): a white Y on its orange, in its Verdana.
                    Text("Y").font(.custom("Verdana-Bold", size: size * 0.68)).foregroundStyle(.white)
                } else if kind == .claude {
                    ClaudeSpark().fill(Color(hex: 0xd97757)).padding(size * 0.16)   // Claude's mark (2026-11-15)
                } else if kind == .chess {
                    Text("\u{265E}\u{FE0E}").font(.system(size: size * 0.72)).foregroundStyle(SidraColor.Process.glyph)
                } else {
                    Image(systemName: kind.symbol)
                        .font(.system(size: size * 0.55, weight: .bold))
                        .foregroundStyle(SidraColor.Process.glyph)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Claude's spark, drawn: twelve rounded rays of alternating length around the centre.
public struct ClaudeSpark: Shape {
    public init() {}
    public func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY), R = min(r.width, r.height) / 2, w = R * 0.17
        for i in 0..<12 {
            let a = Double(i) / 12 * 2 * .pi + 0.13
            let len = R * (i % 2 == 0 ? 1 : 0.78)
            let ray = Path(roundedRect: CGRect(x: -w / 2, y: -len, width: w, height: len), cornerRadius: w / 2)
            p.addPath(ray, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a))
        }
        return p
    }
}

// MARK: - Gradient border

/// A 1 pt border drawn with the Sidra gradient. Used for the active tab and the focused pane.
public struct GradientBorder: ViewModifier {
    let radius: CGFloat
    let active: Bool
    let inactive: Color

    public func body(content: Content) -> some View {
        content.overlay {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            if active {
                // 1.5 pt: at 1 pt the ochre end of the gradient vanishes against the dark pane.
                shape.strokeBorder(SidraGradient.horizontal, lineWidth: 1.5)
            } else {
                shape.strokeBorder(inactive, lineWidth: 1)
            }
        }
    }
}

public extension View {
    func gradientBorder(radius: CGFloat, active: Bool, inactive: Color = SidraColor.hairline) -> some View {
        modifier(GradientBorder(radius: radius, active: active, inactive: inactive))
    }
}

// MARK: - Pill tab

public struct PillTab: View {
    let icon: ProcessIcon.Kind
    let title: String
    let subtitle: String?
    let active: Bool
    let dot: Bool
    let accessory: AnyView?
    let action: () -> Void
    let close: (() -> Void)?

    /// `dot`: a small blue dot after the title, for a tab with something new in it. `accessory`: a mark or
    /// count after it (Substrate's waiting count, its mark on a herdr tab).
    public init(icon: ProcessIcon.Kind, title: String, subtitle: String? = nil, active: Bool, dot: Bool = false, accessory: AnyView? = nil,
                action: @escaping () -> Void, close: (() -> Void)? = nil) {
        self.dot = dot
        self.accessory = accessory
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.active = active
        self.action = action
        self.close = close
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ProcessIcon(icon, size: 24)
                Text(title)
                    .font(SidraFont.ui(13.5, weight: active ? .bold : .regular))
                    .foregroundStyle(active ? SidraColor.text : SidraColor.muted)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(SidraFont.ui(13.5))
                        .foregroundStyle(active ? SidraColor.muted : SidraColor.dim)
                        .lineLimit(1)
                }
                if dot { Circle().fill(SidraColor.blue).frame(width: 7, height: 7).accessibilityHidden(true) }
                if let accessory { accessory }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .frame(height: 34)
            .frame(maxWidth: 330)
            .background(
                RoundedRectangle(cornerRadius: SidraRadius.tab, style: .continuous)
                    .fill(active ? SidraColor.tabActive : .clear)
                    .shadow(color: active ? .black.opacity(0.4) : .clear, radius: 5, y: 3)
            )
            .gradientBorder(radius: SidraRadius.tab, active: active, inactive: .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text((subtitle.map { "\(title) \($0)" } ?? title) + (dot ? ", new" : "")))
        .accessibilityAddTraits(active ? .isSelected : [])
        .contextMenu {
            if let close {
                Button("Close Tab", systemImage: "xmark", role: .destructive, action: close)
            }
        }
    }
}

// MARK: - Status pill (title bar right side)

public struct StatusPill: View {
    public enum Lead { case dot(Color), symbol(String, Color) }
    let lead: Lead
    let text: String
    let value: String?

    public init(_ text: String, value: String? = nil, lead: Lead) {
        self.text = text
        self.value = value
        self.lead = lead
    }

    public var body: some View {
        HStack(spacing: 7) {
            switch lead {
            case .dot(let color):
                Circle().fill(color).frame(width: 7, height: 7)
            case .symbol(let name, let color):
                Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            }
            Text(text).font(SidraFont.ui(12.5)).foregroundStyle(value == nil ? SidraColor.text : SidraColor.muted)
            if let value { Text(value).font(SidraFont.ui(12.5, weight: .bold)).foregroundStyle(SidraColor.text) }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous).strokeBorder(SidraColor.hairline))
    }
}

// MARK: - Buttons

public struct SidraButtonStyle: ButtonStyle {
    /// dark: solid ground with light text, for an action on a raised surface (Reconnect on a lost terminal).
    public enum Role { case primary, secondary, dark }
    let role: Role
    public init(_ role: Role) { self.role = role }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SidraFont.ui(13, weight: .bold))
            .foregroundStyle(role == .primary ? Color(hex: 0x06140e) : role == .dark ? SidraColor.text : SidraColor.muted)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(role == .primary ? SidraColor.jade : role == .dark ? SidraColor.ground : .clear, in: RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous))
            .overlay {
                if role != .primary {
                    RoundedRectangle(cornerRadius: SidraRadius.pill, style: .continuous).strokeBorder(role == .dark ? SidraColor.hairline2 : SidraColor.hairline)
                }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

public extension ButtonStyle where Self == SidraButtonStyle {
    static var sidraPrimary: SidraButtonStyle { .init(.primary) }
    static var sidraSecondary: SidraButtonStyle { .init(.secondary) }
    static var sidraDark: SidraButtonStyle { .init(.dark) }
}

// MARK: - Icon button (pane header controls)

public struct IconButton: View {
    let symbol: String
    let label: String
    let size: CGFloat
    let action: () -> Void

    public init(_ symbol: String, label: String, size: CGFloat = 24, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.size = size
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SidraColor.dim)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(iOS) || os(visionOS)
        .hoverEffect(.highlight)
        #endif
        .accessibilityLabel(label)
    }
}

// MARK: - Gradient progress

public struct GradientProgress: View {
    let fraction: Double
    public init(_ fraction: Double) { self.fraction = min(max(fraction, 0), 1) }
    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0x232831))
                Capsule().fill(SidraGradient.horizontal).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(Text("\(Int(fraction * 100)) percent"))
    }
}

/// Spinner drawn with the gradient, for in-progress steps.
public struct GradientSpinner: View {
    @State private var spin = false
    let size: CGFloat
    public init(size: CGFloat = 20) { self.size = size }
    public var body: some View {
        Circle()
            .trim(from: 0.2, to: 1)
            .stroke(SidraGradient.angular, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
            .accessibilityLabel("In progress")
    }
}

// MARK: - Toggle in the gradient

public struct GradientToggleStyle: ToggleStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer()
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? AnyShapeStyle(SidraGradient.horizontal) : AnyShapeStyle(Color(hex: 0x232831)))
                        .frame(width: 40, height: 24)
                    Circle().fill(.white).frame(width: 20, height: 20).padding(2)
                }
                .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section label

public struct SectionLabel: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(SidraFont.ui(11, weight: .bold))
            .kerning(0.8)
            .foregroundStyle(SidraColor.dim)
    }
}

// MARK: - Footer chip

/// One grouped chip for a pane footer: segments separated by hairlines, each an optional icon,
/// a muted label and a bold value. Replaces "a · b · c" strings (chosen 2026-11-08).
public struct FooterChip: View {
    public struct Segment {
        public var icon: String?
        public var label: String?
        public var value: String
        public var valueColor: Color
        public init(_ value: String, icon: String? = nil, label: String? = nil, color: Color = SidraColor.text) {
            self.value = value; self.icon = icon; self.label = label; self.valueColor = color
        }
    }
    let segments: [Segment]
    public init(_ segments: [Segment]) { self.segments = segments }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { i, s in
                if i > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 18) }
                HStack(spacing: 5) {
                    if let icon = s.icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(SidraColor.muted) }
                    if let label = s.label { Text(label).font(SidraFont.ui(11)).foregroundStyle(SidraColor.muted) }
                    Text(s.value).font(SidraFont.ui(11, weight: .bold)).foregroundStyle(s.valueColor)
                }
                .padding(.horizontal, 7)
                .lineLimit(1)
            }
        }
        .frame(height: 18)
        .background(Color(hex: 0x1b2028), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }
}

// MARK: - Drag to reorder

/// Long-press an item, drag it over another and it takes that one's place while you drag;
/// `commit` runs on drop (for a store that should hear one move, not every step).
public struct ReorderDrop<ID: Hashable>: DropDelegate {
    let target: ID
    @Binding var dragging: ID?
    let move: (ID, ID) -> Void
    let commit: (ID) -> Void

    public func dropEntered(info: DropInfo) {
        if let d = dragging, d != target { withAnimation(.easeOut(duration: 0.15)) { move(d, target) } }
    }
    public func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    public func performDrop(info: DropInfo) -> Bool {
        if let d = dragging { commit(d) }
        dragging = nil
        return true
    }
}

public extension View {
    /// Makes a tab draggable among its siblings. `move(dragged, over)` reorders; `commit(dragged)` on drop.
    func reorderable<ID: Hashable & CustomStringConvertible>(_ id: ID, dragging: Binding<ID?>,
                                                             move: @escaping (ID, ID) -> Void,
                                                             commit: @escaping (ID) -> Void = { _ in }) -> some View {
        onDrag {
            dragging.wrappedValue = id
            return NSItemProvider(object: id.description as NSString)
        }
        .onDrop(of: [.text], delegate: ReorderDrop(target: id, dragging: dragging, move: move, commit: commit))
    }
}
