import SwiftUI
import SidraDesign

/// Every command and its binding, grouped by area, searchable. The same names feed the Cmd-hold HUD.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var query = ""
    private let reg = CommandRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard shortcuts").font(SidraFont.ui(19, weight: .bold)).foregroundStyle(SidraColor.text)
                Spacer()
                TextField("Search", text: $query).textFieldStyle(.plain).font(SidraFont.ui(13)).foregroundStyle(SidraColor.text)
                    .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 220)
                    .background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(reg.areas, id: \.self) { area in
                        let items = reg.commands.filter { $0.area == area && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.keyLabel.localizedCaseInsensitiveContains(query)) }
                        if !items.isEmpty {
                            SectionLabel(area)
                            ForEach(items) { c in
                                HStack {
                                    Text(c.title).font(SidraFont.ui(13)).foregroundStyle(SidraColor.text)
                                    Spacer()
                                    Text(c.keyLabel.isEmpty ? "—" : c.keyLabel).font(SidraFont.mono(12)).foregroundStyle(c.keyLabel.isEmpty ? SidraColor.dim : SidraColor.muted)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Color(hex: 0x1b2028), in: RoundedRectangle(cornerRadius: 4))
                                }.frame(height: 24)
                            }
                        }
                    }
                    Text("Editor keys handled by the text view: ⌘S save, ⌘F find, ⌥⌘F replace, ⌘/ comment, ⌥↑ ⌥↓ move line, ⇧⌥↓ duplicate, ⇧⌘K delete line, ⌘D select next, ⌘] ⌘[ indent, F8 ⇧F8 diagnostics, ⇧F12 references, ⌘. code actions, ⌃Space complete, ⌘K hover.")
                        .font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim).padding(.top, 6)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.sidraPrimary) }
        }
        .padding(24).frame(maxWidth: 620, maxHeight: 620).background(SidraColor.panel).presentationBackground(SidraColor.panel)
        .onAppear { if reg.commands.isEmpty { reg.replaceAll(WorkspaceCommands.all(app)) } }
    }
}
