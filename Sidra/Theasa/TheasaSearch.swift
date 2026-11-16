import SwiftUI
import SidraDesign
import SidraTheasa

struct TheasaSearchView: View {
    let query: String
    @Environment(\.theasaOpen) private var open

    var body: some View {
        let q = query
        TheasaLoad(key: "search-\(q)", load: { c in try await c.get("/api/search?q=\(TheasaClient.query(q))", as: [SearchHit].self) }) { rows in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Text(rows.isEmpty ? "No turns match “\(q)”." : "\(TFormat.plural(rows.count, "turn")) for “\(q)”\(rows.count == 50 ? ", the first 50" : "")")
                            .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.dim)
                            .accessibilityIdentifier("theasa-search-count")
                    }
                    ItemRows(data: rows) { r in
                        Button { open(.turn(r.id)) } label: { hit(r).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("theasa-hit-\(r.id)")
                    }
                    .frame(maxWidth: 920, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }

    private func hit(_ r: SearchHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProjectIconView(r.project, size: 18)
                Text(r.headline.map(inlineMD) ?? AttributedString(String(r.prompt.prefix(120))))
                    .font(SidraFont.ui(14, weight: .bold)).foregroundStyle(SidraColor.text).multilineTextAlignment(.leading)
            }
            Text(snippet(r.snippet)).font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).lineLimit(4).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(r.project.name)
                Text("·")
                AgentTag(agent: r.agent)
                Text("· " + TFormat.stampShort(r.started_at))
                if r.verdict != nil { Text("·"); VerdictLabel(verdict: r.verdict).font(SidraFont.ui(12)) }
            }
            .font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hits (between [[ and ]]) in bold.
    private func snippet(_ s: String) -> AttributedString {
        var out = AttributedString()
        for (text, hit) in snippetRuns(s.replacingOccurrences(of: "\n", with: " ")) {
            var part = AttributedString(text)
            if hit { part.foregroundColor = SidraColor.textBright; part.font = SidraFont.ui(13, weight: .bold) }   // colour stays on dots
            out += part
        }
        return out
    }
}
