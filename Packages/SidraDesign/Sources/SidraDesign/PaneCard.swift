import SwiftUI

/// Pane chrome: header (icon, title, `| project`, extras, split right / split down / maximize / close),
/// content, and a thin mono footer. Focus is drawn with the gradient border.
public struct PaneCard<Content: View, Extra: View, Footer: View>: View {
    @Environment(\.paneHeaderTrailingInset) private var headerTrailingInset
    public struct Actions {
        public var splitRight: () -> Void
        public var splitDown: () -> Void
        public var maximize: () -> Void
        public var close: () -> Void
        public init(splitRight: @escaping () -> Void, splitDown: @escaping () -> Void,
                    maximize: @escaping () -> Void, close: @escaping () -> Void) {
            self.splitRight = splitRight
            self.splitDown = splitDown
            self.maximize = maximize
            self.close = close
        }
    }

    let icon: ProcessIcon.Kind
    let title: String
    let project: String?
    let focused: Bool
    let maximized: Bool
    let actions: Actions
    let onFocus: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let extra: () -> Extra
    @ViewBuilder let footer: () -> Footer

    public init(icon: ProcessIcon.Kind, title: String, project: String?, focused: Bool, maximized: Bool = false,
                actions: Actions, onFocus: @escaping () -> Void,
                @ViewBuilder content: @escaping () -> Content,
                @ViewBuilder extra: @escaping () -> Extra = { EmptyView() },
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.project = project
        self.focused = focused
        self.maximized = maximized
        self.actions = actions
        self.onFocus = onFocus
        self.content = content
        self.extra = extra
        self.footer = footer
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            footerBar
        }
        .background(SidraColor.pane, in: RoundedRectangle(cornerRadius: SidraRadius.pane, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: SidraRadius.pane, style: .continuous))
        .gradientBorder(radius: SidraRadius.pane, active: focused)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(project.map { "\(title) pane, \($0)" } ?? "\(title) pane"))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProcessIcon(icon, size: 20)
            HStack(spacing: 6) {
                Text(title).font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text)
                if let project {
                    Text("|").foregroundStyle(SidraColor.dim)
                    Text(project).font(SidraFont.ui(13.5)).foregroundStyle(SidraColor.muted)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            extra()
            HStack(spacing: 4) {
                IconButton("rectangle.split.2x1", label: "Split right", action: actions.splitRight)
                IconButton("rectangle.split.1x2", label: "Split down", action: actions.splitDown)
                IconButton(maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           label: maximized ? "Restore" : "Maximize", action: actions.maximize)
                IconButton("xmark", label: "Close pane", action: actions.close)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10 + headerTrailingInset)
        .frame(height: SidraSpace.paneHeaderHeight)
    }

    @ViewBuilder private var footerBar: some View {
        let f = footer()
        HStack(spacing: 14) { f }
            .font(SidraFont.mono(11.5))
            .foregroundStyle(SidraColor.dim)
            .padding(.horizontal, 14)
            .frame(height: SidraSpace.paneFooterHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Footer helper: `✓ rust-analyzer` style status item.
public struct FooterItem: View {
    let text: String
    let color: Color
    public init(_ text: String, color: Color = SidraColor.dim) {
        self.text = text
        self.color = color
    }
    public var body: some View { Text(text).foregroundStyle(color) }
}

public extension EnvironmentValues {
    /// Room kept free at the right of pane headers, for the floating tab orb while the top bar is hidden.
    @Entry var paneHeaderTrailingInset: CGFloat = 0
}
