import SwiftUI
import SidraDesign
import SidraTheasa

/// New tab, Theasa…: pick a saved server or add one (address + token), test it, open it as a tab.
struct TheasaConnectSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var store = TheasaStore.shared
    @State private var editing: TheasaConnection?
    @State private var name = "Theasa"
    @State private var url = TheasaConnectSheet.defaultURL
    @State private var token = ""
    @State private var testing = false
    @State private var health: Health?
    @State private var testError: String?

    #if targetEnvironment(simulator)
    static let defaultURL = "http://127.0.0.1:4747"
    #else
    static let defaultURL = ""
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    ProcessIcon(.theasa, size: 30)
                    Text("Connect to Theasa").font(SidraFont.ui(19, weight: .bold)).foregroundStyle(SidraColor.text)
                }
                Text("Theasa records every Claude Code and Codex turn and writes a summary of each. It needs its token for everything except the health check.")
                    .font(SidraFont.ui(13)).foregroundStyle(SidraColor.muted).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
                if !store.connections.isEmpty {
                    SectionLabel("Saved servers").padding(.top, 16)
                    VStack(spacing: 8) { ForEach(store.connections) { saved($0) } }.padding(.top, 8)
                }
                SectionLabel(editing == nil ? "Add a server" : "Edit \(editing!.name)").padding(.top, 18)
                VStack(alignment: .leading, spacing: 10) {
                    field("Name", text: $name, placeholder: "Theasa")
                    field("Server address", text: $url, placeholder: "https://devbox.example.ts.net:4747", id: "theasa-url")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Token").font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted)
                        SecureField("Paste the output of theasa token", text: $token)
                            .modifier(FieldStyle()).accessibilityIdentifier("theasa-token")
                        Text("Stored in this device's Keychain. Theasa shows nothing without it.").font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim)
                    }
                    testResult
                }
                .padding(.top, 8)
                HStack(spacing: 10) {
                    Button(testing ? "Testing…" : "Test") { Task { await test() } }.buttonStyle(.sidraSecondary).disabled(testing || TheasaClient.normalize(url) == nil)
                        .accessibilityIdentifier("theasa-test")
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(.sidraSecondary)
                    Button(editing == nil ? "Save and open" : "Save") { saveAndOpen() }.buttonStyle(.sidraPrimary)
                        .disabled(TheasaClient.normalize(url) == nil || token.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("theasa-open")
                }
                .padding(.top, 18)
            }
            .padding(24)
        }
        .frame(width: 600)
        .frame(maxHeight: 700)
        .fixedSize(horizontal: false, vertical: true)
        .background(SidraColor.panel)
        .presentationBackground(SidraColor.panel)
        .onChange(of: url) { health = nil; testError = nil }
    }

    @ViewBuilder private var testResult: some View {
        if let h = health {
            HStack(spacing: 6) {
                FooterChip([.init(h.version, label: "Theasa", color: SidraColor.jade)])
                FooterChip([.init("\(h.turns)", label: "turns")])
                FooterChip([.init("\(h.queue)", label: "queued"), .init("\(h.failed)", label: "failed", color: h.failed > 0 ? SidraColor.red : SidraColor.text)])
                FooterChip([.init(TFormat.bytes(h.db_bytes), label: "database")])
            }
            .accessibilityIdentifier("theasa-health")
        } else if let e = testError {
            Text(e).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.yellow).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, id: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted)
            TextField(placeholder, text: text).modifier(FieldStyle())
                .plainTextEntry().autocorrectionDisabled().urlKeyboard(label != "Name")
                .accessibilityIdentifier(id)
        }
    }

    private func saved(_ c: TheasaConnection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack").font(.system(size: 15)).foregroundStyle(SidraColor.muted)
                .frame(width: 34, height: 34).background(SidraColor.tabActive, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(c.name).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text)
                FooterChip([.init(c.url, color: SidraColor.muted), .init(store.token(c) == nil ? "no token" : "token saved", color: store.token(c) == nil ? SidraColor.yellow : SidraColor.muted)]
                           + (store.active?.id == c.id ? [.init("in use", color: SidraColor.jade)] : []))
            }
            Spacer()
            IconButton("pencil", label: "Edit \(c.name)", size: 30) {
                editing = c; name = c.name; url = c.url; token = store.token(c) ?? ""; health = nil; testError = nil
            }
            IconButton("trash", label: "Remove \(c.name)", size: 30) { store.remove(c.id); if editing?.id == c.id { editing = nil } }
            Button("Use") { use(c.id) }.buttonStyle(.sidraPrimary)
        }
        .padding(12)
        .theasaCard()
    }

    private func test() async {
        guard let base = TheasaClient.normalize(url) else { return }
        testing = true; health = nil; testError = nil
        defer { testing = false }
        do { health = try await TheasaClient(base: base, token: nil).health() }
        catch { testError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }

    /// That server becomes the one the pill shows; Theasa opens once the sheet has gone.
    private func use(_ id: UUID) {
        TheasaStore.shared.activeID = id
        app.afterSheetDismiss = { [app] in TheasaStore.shared.open(app) }
        dismiss()
    }

    private func saveAndOpen() {
        guard let base = TheasaClient.normalize(url) else { return }
        var c = editing ?? TheasaConnection(name: "", url: "")
        c.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? (base.host ?? "Theasa") : name
        c.url = base.absoluteString
        store.save(c, token: token)
        if editing == nil { use(c.id) } else { dismiss() }
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.font(SidraFont.ui(14)).foregroundStyle(SidraColor.text)
            .padding(.horizontal, 10).frame(height: 36)
            .background(SidraColor.ground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(SidraColor.hairline2))
    }
}
