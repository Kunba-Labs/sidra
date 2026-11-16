import SwiftUI
import SidraDesign
import SidraSSH
import SidraTerminal

/// Hosts, the Sidra SSH identity, terminal engine.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editing: SSHHostProfile?
    @State private var password = ""
    @State private var alert: SidraAlert?
    @State private var query = ""

    /// Search matches a row when any of its texts contains the query.
    private func show(_ texts: String...) -> Bool { query.isEmpty || texts.contains { $0.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        @Bindable var app = app
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Settings").font(SidraFont.ui(19, weight: .bold)).foregroundStyle(SidraColor.text)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(SidraColor.dim)
                    TextField("Search settings", text: $query).textFieldStyle(.plain).font(SidraFont.ui(13)).foregroundStyle(SidraColor.text)
                        .autocorrectionDisabled().accessibilityLabel("Search settings")
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(SidraColor.dim) }.buttonStyle(.plain) }
                }
                .padding(.horizontal, 10).padding(.vertical, 7).frame(width: 260)
                .background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
            }

            if show("Terminal", "engine", "libghostty", "SwiftTerm") { SectionLabel("Terminal") }
            if show("Terminal engine", "libghostty", "SwiftTerm", "terminal") {
                SettingRow("Terminal engine", detail: "libghostty-vt is the default; SwiftTerm is the fallback", isDefault: app.terminalEngine == .ghostty, reset: { app.terminalEngine = .ghostty }) {
                    Picker("Engine", selection: $app.terminalEngine) {
                        Text("libghostty-vt").tag(TerminalEngineKind.ghostty)
                        Text("SwiftTerm").tag(TerminalEngineKind.swiftTerm)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }

            TerminalKeysSection(query: query)

            if show("Keys", "SSH", "key", "identity", "fingerprint") || SSHKeyManager.keys().contains(where: { show($0.name) }) {
                KeysSection(alert: $alert, query: query)
            }

            if show("Hosts", "SSH", "host") || app.hosts.hosts.contains(where: { show($0.alias, $0.host, $0.user) }) {
            SectionLabel("Hosts")
            VStack(spacing: 0) {
                ForEach(app.hosts.hosts.filter { show("Hosts", "host", $0.alias, $0.host, $0.user) }) { h in
                    HStack(spacing: 10) {
                        ProcessIcon(.ssh, size: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.alias).font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text)
                            HStack(spacing: 6) {
                                Text("\(h.user)@\(h.host):\(h.port)").font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted)
                                FooterChip([.init(h.auth == .key ? (SSHKeyManager.record(id: h.keyID)?.name ?? "key") : "password", label: "auth", color: SidraColor.muted)]
                                           + (h.startupCommand.isEmpty ? [] : [.init(h.startupCommand, label: "runs", color: SidraColor.muted)])
                                           + (KnownHosts.entry(host: h.host, port: h.port) == nil ? [] : [.init("pinned", color: SidraColor.jade)]))
                            }
                        }
                        Spacer()
                        Button("Edit") { editing = h; password = "" }.buttonStyle(.sidraSecondary)
                        Button("Remove") { app.hosts.remove(h.id) }.buttonStyle(.sidraSecondary)
                    }
                    .padding(.vertical, 8)
                    Rectangle().fill(SidraColor.hairline).frame(height: 1)
                }
                HStack { Spacer(); Button("Add host") { editing = SSHHostProfile(alias: "", host: "", user: "", auth: .key, startupCommand: "", trustOnFirstUse: false) }.buttonStyle(.sidraSecondary) }
                    .padding(.top, 8)
            }
            }

            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.sidraPrimary) }
        }
        .padding(24)
        }
        .frame(width: 720, height: 680)
        .background(SidraColor.panel)
        .presentationBackground(SidraColor.panel)
        .sheet(item: $editing) { h in HostEditor(profile: h, password: $password) { saved, pw in
            app.hosts.upsert(saved, password: pw.isEmpty ? nil : pw)
            editing = nil
            _ = app.connection(for: saved)   // a cached shell connection picks up the new profile now
        } }
        .keyUseConfirmation()
        .sidraAlert($alert)
    }
}

struct HostEditor: View {
    @State var profile: SSHHostProfile
    @Binding var password: String
    let onSave: (SSHHostProfile, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var keys = SSHKeyManager.keys()
    @State private var testing = false
    @State private var testResult: String?
    @State private var alert: SidraAlert?
    @State private var prompter = HostKeyPrompter.shared
    @Environment(AppModel.self) private var app
    @State private var configNote: String?
    @State private var copiedKeyID: String?   // the key whose public half is on the clipboard
    private var hosts: [SSHHostProfile] { app.hosts.hosts }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.alias.isEmpty ? "New host" : profile.alias).font(SidraFont.ui(19, weight: .bold)).foregroundStyle(SidraColor.text)
            field("Alias", $profile.alias)
            HStack { field("Host", $profile.host); field("Port", Binding(get: { String(profile.port) }, set: { profile.port = Int($0) ?? 22 })).frame(width: 110) }
            field("User", $profile.user)
            Picker("Auth", selection: $profile.auth) {
                Text("Sidra key").tag(SSHHostProfile.Auth.key)
                Text("Password").tag(SSHHostProfile.Auth.password)
            }.pickerStyle(.segmented)
            if profile.auth == .password {
                SecureField("Password (stored in the Keychain)", text: $password)
                    .textFieldStyle(.plain).font(SidraFont.mono(13)).foregroundStyle(SidraColor.text)
                    .padding(8).background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack {
                    Picker("Key", selection: Binding(get: { profile.keyID ?? keys.first?.id }, set: { profile.keyID = $0 })) {
                        ForEach(keys) { k in Text("\(k.name)  \(k.fingerprint.prefix(19))…").tag(Optional(k.id)) }
                    }.pickerStyle(.menu).tint(SidraColor.text)
                    Spacer()
                    // The host's ~/.ssh/authorized_keys needs this line before key sign-in works.
                    if let k = keys.first(where: { $0.id == (profile.keyID ?? keys.first?.id) }) {
                        Button(copiedKeyID == "\(k.id)" ? "Copied" : "Copy public key", systemImage: copiedKeyID == "\(k.id)" ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = k.publicKey; copiedKeyID = "\(k.id)"
                        }.buttonStyle(.sidraSecondary)
                    }
                }
            }
            field("Run on connect (e.g. tmux new -A -s sidra)", $profile.startupCommand)
            Toggle("Ask before trusting the host key on first connection", isOn: Binding(get: { !profile.trustOnFirstUse }, set: { profile.trustOnFirstUse = !$0 }))
                .toggleStyle(GradientToggleStyle()).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
            if let pinned = KnownHosts.entry(host: profile.host, port: profile.port) {
                HStack {
                    FooterChip([.init(KnownHosts.fingerprint(pinned), label: "pinned", color: SidraColor.jade)])
                    Button("Forget host key") { KnownHosts.forget(host: profile.host, port: profile.port) }.buttonStyle(.sidraSecondary)
                }
            }
            hostExtras
            HStack {
                Button(testing ? "Testing…" : "Test connection") { Task { await test() } }.buttonStyle(.sidraSecondary).disabled(testing || profile.host.isEmpty || profile.user.isEmpty)
                if testing { GradientSpinner(size: 14) }
                if let testResult { FooterChip([.init(testResult, color: SidraColor.jade)]) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.sidraSecondary)
                Button("Save") { onSave(profile, password); dismiss() }.buttonStyle(.sidraPrimary)
                    .disabled(profile.alias.isEmpty || profile.host.isEmpty || profile.user.isEmpty)
            }
        }
        .padding(24)
        }
        .frame(width: 520)
        .frame(maxHeight: 680)
        .background(SidraColor.panel)
        .presentationBackground(SidraColor.panel)
        .sidraAlert($alert)
        .sheet(item: Binding(get: { prompter.pending.map { PromptBox(prompt: $0) } }, set: { _ in })) { box in
            HostKeySheet(prompt: box.prompt) { prompter.decide($0) }
        }
        .onAppear { prompter.install() }
    }

    private struct PromptBox: Identifiable { let prompt: HostKeyPrompt; var id: String { "\(prompt.host):\(prompt.port)" } }

    /// Connects with the unsaved profile, runs `echo ok`, disconnects. A typed password is used through a throwaway Keychain entry.
    private func test() async {
        testing = true; testResult = nil
        defer { testing = false }
        var p = profile
        if p.auth == .password, !password.isEmpty {
            p.id = UUID()
            do { try KeychainStore.set(password, for: p.passwordKey) } catch { alert = SidraAlert.from(error, title: "Keychain refused the password"); return }
        }
        defer { if p.id != profile.id { KeychainStore.remove(p.passwordKey) } }
        let c = SSHConnection(profile: p, jump: p.jumpHostID.flatMap { id in hosts.first { $0.id == id } })
        do {
            let r = try await c.run("echo ok")
            await c.disconnect()
            testResult = r.stdoutText.contains("ok") ? "connected as \(p.user)" : "connected, shell answered \(r.exitCode)"
        } catch {
            await c.disconnect()
            let d = SSHFailure.describe(error, host: p.host)
            var a = SidraAlert(title: d.title, detail: d.detail, rawOutput: describeError(error), primaryLabel: "Retry") { Task { await test() } }
            if let changed = error as? HostKeyChanged {
                a.primaryLabel = "Accept new key"
                a.primary = { KnownHosts.record(host: changed.host, port: changed.port, publicKey: changed.newKey); Task { await test() } }
            }
            alert = a
        }
    }

    /// mosh-compatible transport, jump host and pasted ssh_config.
    @ViewBuilder private var hostExtras: some View {
        Toggle("Use a mosh-compatible session (survives network changes)", isOn: Binding(get: { profile.mosh != nil }, set: { profile.mosh = $0 ? MoshSettings() : nil }))
            .toggleStyle(GradientToggleStyle()).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
        if profile.mosh != nil {
            HStack {
                field("mosh-server path (empty: on PATH)", Binding(get: { profile.mosh?.serverPath ?? "" }, set: { profile.mosh?.serverPath = $0 }))
                field("UDP ports", Binding(get: { profile.mosh?.portRange ?? "" }, set: { profile.mosh?.portRange = $0 })).frame(width: 150)
            }
        }
        Picker("Jump host", selection: $profile.jumpHostID) {
            Text("No jump host").tag(UUID?.none)
            ForEach(hosts.filter { $0.id != profile.id }) { h in Text(h.alias).tag(Optional(h.id)) }
        }.pickerStyle(.menu).tint(SidraColor.text)
        TextField("Paste ssh_config (HostName, User, Port, ProxyJump)", text: Binding(get: { profile.rawConfig ?? "" }, set: { profile.rawConfig = $0.isEmpty ? nil : $0 }), axis: .vertical)
            .lineLimit(2...5).textFieldStyle(.plain).font(SidraFont.mono(12)).foregroundStyle(SidraColor.text)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .padding(8).background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
        if profile.rawConfig != nil {
            HStack {
                Button("Apply to fields") {
                    let ignored = SSHConfigText.apply(profile.rawConfig ?? "", to: &profile, hosts: hosts)
                    configNote = ignored.isEmpty ? "Applied." : "Not used: \(ignored.joined(separator: ", "))"
                }.buttonStyle(.sidraSecondary)
                if let configNote { Text(configNote).font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.muted).lineLimit(2) }
            }
        }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain).font(SidraFont.mono(13)).foregroundStyle(SidraColor.text)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .padding(8).background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
    }
}


/// Defaults the Reset buttons return to.
enum SettingDefaults {
    static let projectRoot = "/home/sidra/projects/blinky-rs"
}

/// One setting: title, detail, a "default" marker when at its default or a Reset (↺) when not,
/// and the control underneath. Shared by Settings sections so search and reset look the same.
struct SettingRow<Content: View>: View {
    let title: String
    let detail: String
    let isDefault: Bool
    let reset: () -> Void
    @ViewBuilder let content: () -> Content

    init(_ title: String, detail: String, isDefault: Bool, reset: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.detail = detail; self.isDefault = isDefault; self.reset = reset; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(SidraFont.ui(13, weight: .bold)).foregroundStyle(SidraColor.text)
                Text(detail).font(SidraFont.ui(12)).foregroundStyle(SidraColor.dim).lineLimit(1)
                Spacer()
                if isDefault {
                    Text("default").font(SidraFont.ui(10.5, weight: .bold)).foregroundStyle(SidraColor.dim)
                        .padding(.horizontal, 6).padding(.vertical, 2).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SidraColor.hairline2))
                } else {
                    Button { reset() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(SidraColor.muted).accessibilityLabel("Reset \(title) to default")
                }
            }
            content()
        }
    }
}

/// Terminal keyboard options. "⌘ acts as Ctrl" is read by the terminal views from UserDefaults.
struct TerminalKeysSection: View {
    var query = ""
    @AppStorage("sidra.cmdAsCtrl") private var cmdAsCtrl = false
    private func show(_ texts: String...) -> Bool { query.isEmpty || texts.contains { $0.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        if show("Terminal", "⌘ acts as Ctrl", "cmd", "ctrl", "command", "keyboard") {
            SettingRow("⌘ acts as Ctrl in terminals", detail: "Cmd-C sends Ctrl-C; copy stays on the key row", isDefault: !cmdAsCtrl, reset: { cmdAsCtrl = false }) {
                Toggle("", isOn: $cmdAsCtrl).toggleStyle(GradientToggleStyle()).labelsHidden().fixedSize()
            }
        }
        if show("Terminal", "Caps Lock", "Esc", "escape", "keyboard") {
            SettingRow("Caps Lock as Esc", detail: "An iPadOS setting: Settings → General → Keyboard → Hardware Keyboard → Modifier Keys", isDefault: true, reset: {}) {
                Button("Open Settings") { PlatformStatus.openSettings() }.buttonStyle(.sidraSecondary)
            }
        }
    }
}
