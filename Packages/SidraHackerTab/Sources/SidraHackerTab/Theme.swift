import SwiftUI
import SidraDesign

/// HackerTab's palette on Sidra's tokens. Orange is HackerTab's own colour (counts, links, the
/// discussion's first rail); selection uses Sidra's gradient.
enum T {
    static let bg = SidraColor.pane, panel = SidraColor.panel, article = SidraColor.ground2, deep = SidraColor.ground
    static let text = SidraColor.textBright, body = SidraColor.text, dim = SidraColor.muted, faint = SidraColor.dim, read = SidraColor.muted
    static let rule = SidraColor.hairline2, hair = SidraColor.hairline
    static let accent = SidraColor.orange, sel = SidraColor.raised, selRule = SidraColor.hairline2
    static let ok = SidraColor.jade, warm = Color(hex: 0x8a5a36), idle = SidraColor.raised
    static let rails = [accent, SidraColor.blue, SidraColor.jade, SidraColor.violet]
    static let tiles = [SidraColor.blue, SidraColor.jade, SidraColor.violet, SidraColor.gold, Color(hex: 0x7fd4c1), Color(hex: 0xf29b9b)]

    static func mono(_ size: CGFloat, bold: Bool = false) -> Font { SidraFont.mono(size, weight: bold ? .bold : .regular) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { SidraFont.ui(size, weight: weight) }
}

/// A flat text button in the mono face, 44 pt tall.
struct MonoButton: View {
    let label: String
    var on = false
    var size: CGFloat = 12
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label).font(T.mono(size, bold: on)).foregroundStyle(on ? T.accent : T.dim)
                .lineLimit(1).fixedSize().frame(minWidth: 28, minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct Rule: View {
    var color = T.rule
    var body: some View { color.frame(height: 1) }
}
struct VRule: View {
    var color = T.rule
    var body: some View { color.frame(width: 1) }
}
