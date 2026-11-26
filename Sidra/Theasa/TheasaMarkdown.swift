import SwiftUI
import SidraDesign
import SidraTheasa

/// An agent's reply as Markdown: blocks from SidraTheasa's parser, inline syntax through
/// AttributedString(markdown:). Agent text is untrusted; links open only on a tap, nothing loads.
struct MarkdownView: View {
    let text: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ForEach(Array(markdownBlocks(text).enumerated()), id: \.offset) { _, b in block(b) }
        }
        .font(SidraFont.ui(14))
        .foregroundStyle(Color(hex: 0xC4C4CA))
        .textSelection(.enabled)
        .tint(SidraColor.textBright)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let level, let t):
            Text(inlineMD(t)).font(SidraFont.ui(level == 1 ? 17 : level == 2 ? 16 : 15, weight: .bold)).foregroundStyle(SidraColor.textBright)
                .padding(.top, compact ? 0 : 6)
        case .paragraph(let t):
            Text(inlineMD(t)).fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(i + 1)." : "•").foregroundStyle(SidraColor.dim).frame(minWidth: 14, alignment: .trailing)
                        Text(inlineMD(it)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .code(let c):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(c).font(SidraFont.mono(12.5)).foregroundStyle(SidraColor.terminalText).padding(12)
            }
            .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline))
        case .quote(let t):
            Text(inlineMD(t)).foregroundStyle(SidraColor.muted).padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(SidraColor.hairline2).frame(width: 2) }
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { ri, r in
                        GridRow {
                            ForEach(Array(r.enumerated()), id: \.offset) { _, cell in
                                Text(inlineMD(cell)).font(SidraFont.ui(13, weight: ri == 0 ? .bold : .regular))
                                    .foregroundStyle(ri == 0 ? SidraColor.text : Color(hex: 0xC4C4CA))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .frame(maxWidth: 360, alignment: .leading)
                                    .background(ri == 0 ? SubstrateStyle.chip : .clear)
                                    .border(SidraColor.hairline2, width: 0.5)
                            }
                        }
                    }
                }
            }
        case .rule:
            Rectangle().fill(SidraColor.hairline).frame(height: 1)
        }
    }
}
