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

            // The Mac always runs libghostty-vt: SwiftTerm is the iPad's fallback only.
            if !Platform.isMac, show("Terminal", "engine", "libghostty", "SwiftTerm") { SectionLabel("Terminal") }
            if !Platform.isMac, show("Terminal engine", "libghostty", "SwiftTerm", "terminal") {
                SettingRow("Terminal engine", detail: "libghostty-vt is the default; SwiftTerm is the fallback", isDefault: app.terminalEngine == .ghostty, reset: { app.terminalEngine = .ghostty }) {
                    Picker("Engine", selection: $app.terminalEngine) {
                        Text("libghostty-vt").tag(TerminalEngineKind.ghostty)
                        Text("SwiftTerm").tag(TerminalEngineKind.swiftTerm)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }

            #if os(macOS)
            TerminalFontSection(query: query)
            NotificationsSection(query: query)
            #endif
            VoiceSection(query: query)
            #if os(iOS) || os(visionOS)
            ScreenshotSection(query: query)
            #endif

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
        .frame(maxWidth: 720, maxHeight: 680)
        .sidraSheetBackground()
        .sheet(item: $editing) { h in HostEditor(profile: h, password: $password) { saved, pw in
            app.hosts.upsert(saved, password: pw.isEmpty ? nil : pw)
            editing = nil
            _ = app.connection(for: saved)   // a cached shell connection picks up the new profile now
        }.environment(app) }
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
    /// Host key, mosh, jump host and ssh_config sit under "More options"; open when one is in use.
    @State private var showMore = false
    private var hosts: [SSHHostProfile] { app.hosts.hosts }
    private var usesExtras: Bool { profile.trustOnFirstUse || profile.mosh != nil || profile.jumpHostID != nil || profile.rawConfig != nil }
    /// localhost on a Mac runs its shell directly: user, keys and SSH options do not apply.
    private var local: Bool { profile.isThisMac }
    @FocusState private var hostFocused: Bool

    /// "host:port", or "[v6]:port" for IPv6, typed into Host: the port moves to its own field. A bare
    /// IPv6 address (more than one colon, no brackets) is left alone.
    private func splitHostPort() {
        let v = profile.host.trimmingCharacters(in: .whitespaces)
        var host: Substring, port: Substring
        if v.hasPrefix("["), let close = v.firstIndex(of: "]"), v[v.index(after: close)...].hasPrefix(":") {
            host = v[v.index(after: v.startIndex)..<close]; port = v[v.index(close, offsetBy: 2)...]
        } else if v.filter({ $0 == ":" }).count == 1, let c = v.firstIndex(of: ":") {
            host = v[..<c]; port = v[v.index(after: c)...]
        } else { return }
        guard !host.isEmpty, let n = Int(port), (1...65535).contains(n) else { return }
        profile.host = String(host); profile.port = n
        if profile.isLocalhost { profile.viaSSH = true }
    }

    /// The "Connect over SSH" switch: only for localhost on a Mac.
    private var showsSSHSwitch: Bool { Platform.isMac && profile.isLocalhost }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.alias.isEmpty ? "New host" : profile.alias).font(SidraFont.ui(19, weight: .bold)).foregroundStyle(SidraColor.text)
            field("Alias", $profile.alias)
            HStack {
                // "localhost:45" or "[::1]:45" splits into host and port when editing ends; a typed port means SSH.
                field("Host", $profile.host)
                    .focused($hostFocused)
                    .onSubmit(splitHostPort)
                    .onChange(of: hostFocused) { _, on in if !on { splitHostPort() } }
                if !local {
                    field("Port", Binding(get: { String(profile.port) }, set: { v in
                        profile.port = Int(v) ?? 22
                        if profile.isLocalhost, profile.port != 22 { profile.viaSSH = true }
                    })).frame(width: 110)
                }
            }
            if showsSSHSwitch {
                Toggle("Connect over SSH", isOn: Binding(get: { !local }, set: { profile.viaSSH = $0 }))
                    .toggleStyle(GradientToggleStyle()).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
                    .accessibilityHint("Off runs this Mac's shell directly. On connects through an SSH server, such as a tunnel on another port.")
            }
            if local {
                field("Run on connect (e.g. tmux new -A -s sidra)", $profile.startupCommand)
            } else {
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
                #if os(visionOS)
                // The menu picker is a tall glass pill here; the key gets its own rows, with Share for AirDrop or
                // Mail and the key itself selectable, so it reaches the machine's authorized_keys somehow.
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Key", selection: Binding(get: { profile.keyID ?? keys.first?.id }, set: { profile.keyID = $0 })) {
                        ForEach(keys) { k in Text(k.name).tag(Optional(k.id)) }
                    }.pickerStyle(.menu)
                    if let k = keys.first(where: { $0.id == (profile.keyID ?? keys.first?.id) }) {
                        HStack(spacing: 10) {
                            Button(copiedKeyID == "\(k.id)" ? "Copied" : "Copy public key", systemImage: copiedKeyID == "\(k.id)" ? "checkmark" : "doc.on.doc") {
                                Platform.pasteString = k.publicKey; copiedKeyID = "\(k.id)"
                            }
                            ShareLink(item: k.publicKey) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                        Text(k.publicKey).font(SidraFont.mono(10)).foregroundStyle(SidraColor.muted)
                            .lineLimit(4).textSelection(.enabled)
                    }
                }
                #else
                HStack {
                    Picker("Key", selection: Binding(get: { profile.keyID ?? keys.first?.id }, set: { profile.keyID = $0 })) {
                        ForEach(keys) { k in Text("\(k.name)  \(k.fingerprint.prefix(19))…").tag(Optional(k.id)) }
                    }.pickerStyle(.menu).tint(SidraColor.text)
                    Spacer()
                    // The host's ~/.ssh/authorized_keys needs this line before key sign-in works.
                    if let k = keys.first(where: { $0.id == (profile.keyID ?? keys.first?.id) }) {
                        Button(copiedKeyID == "\(k.id)" ? "Copied" : "Copy public key", systemImage: copiedKeyID == "\(k.id)" ? "checkmark" : "doc.on.doc") {
                            Platform.pasteString = k.publicKey; copiedKeyID = "\(k.id)"
                        }.buttonStyle(.sidraSecondary)
                    }
                }
                #endif
            }
            field("Run on connect (e.g. tmux new -A -s sidra)", $profile.startupCommand)
            Button { withAnimation(.easeOut(duration: 0.15)) { showMore.toggle() } } label: {
                Label("More options", systemImage: showMore ? "chevron.down" : "chevron.right")
                    .font(SidraFont.ui(12.5, weight: .bold)).foregroundStyle(SidraColor.muted)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Host key, mosh, jump host and ssh_config")
            if showMore {
                Toggle("Ask before trusting the host key on first connection", isOn: Binding(get: { !profile.trustOnFirstUse }, set: { profile.trustOnFirstUse = !$0 }))
                    .toggleStyle(GradientToggleStyle()).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
                if let pinned = KnownHosts.entry(host: profile.host, port: profile.port) {
                    HStack {
                        FooterChip([.init(KnownHosts.fingerprint(pinned), label: "pinned", color: SidraColor.jade)])
                        Button("Forget host key") { KnownHosts.forget(host: profile.host, port: profile.port) }.buttonStyle(.sidraSecondary)
                    }
                }
                hostExtras
            }
            }
            HStack {
                Button(testing ? "Testing…" : "Test connection") { Task { await test() } }.buttonStyle(.sidraSecondary).disabled(testing || profile.host.isEmpty || (profile.user.isEmpty && !local))
                if testing { GradientSpinner(size: 14) }
                if let testResult { FooterChip([.init(testResult, color: SidraColor.jade)]) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.sidraSecondary)
                Button("Save") {
                    // Split first, then check again: "localhost:45" turns SSH on, which needs a user.
                    splitHostPort()
                    guard !(profile.user.isEmpty && !local) else { return }
                    onSave(profile, password); dismiss()
                }.buttonStyle(.sidraPrimary)
                    .disabled(profile.alias.isEmpty || profile.host.isEmpty || (profile.user.isEmpty && !local))
            }
        }
        .padding(24)
        }
        .frame(maxWidth: 520)
        .frame(maxHeight: 680)
        .sidraSheetBackground()
        .sidraAlert($alert)
        .sheet(item: Binding(get: { prompter.pending.map { PromptBox(prompt: $0) } }, set: { _ in })) { box in
            HostKeySheet(prompt: box.prompt) { prompter.decide($0) }
        }
        .onAppear { prompter.install(); showMore = usesExtras }
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
            testResult = !r.stdoutText.contains("ok") ? "connected, shell answered \(r.exitCode)" : p.isThisMac ? "this Mac's shell answered" : "connected as \(p.user)"
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
            .autocorrectionDisabled().plainTextEntry()
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
            .autocorrectionDisabled().plainTextEntry()
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
        #if os(iOS) || os(visionOS)
        if show("Sidra keyboard", "keyboard", "floating", "swipe") {
            SettingRow("Sidra keyboard", detail: "A floating developer keyboard in place of Apple's, in terminals. Hides when a hardware keyboard is attached. The SwiftTerm engine keeps Apple's keyboard", isDefault: FloatingKeyboard.shared.enabled, reset: { FloatingKeyboard.shared.enabled = true }) {
                Toggle("", isOn: Binding(get: { FloatingKeyboard.shared.enabled }, set: { FloatingKeyboard.shared.enabled = $0 }))
                    .toggleStyle(GradientToggleStyle()).labelsHidden().fixedSize()
            }
        }
        #endif
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

#if os(macOS)
/// Terminal font and size for every pane. The default is the user's Ghostty font when there is one.
struct TerminalFontSection: View {
    let query: String
    @AppStorage(TerminalFont.familyKey) private var family: String?
    @AppStorage(TerminalFont.sizeKey) private var size: Double = 0
    private func show(_ words: String...) -> Bool { query.isEmpty || words.contains { $0.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        if show("Terminal", "font", "size", "text") {
            SectionLabel("Terminal")
            let d = TerminalFont.defaults
            SettingRow("Font", detail: "Default: \(d.family)", isDefault: family == nil, reset: { family = nil }) {
                SidraMenu([
                    SidraMenuSection(nil, [SidraMenuItem("Default (\(d.family))") { family = nil }]),
                    SidraMenuSection("Monospaced", TerminalFont.monospacedFamilies.map { f in SidraMenuItem(f) { family = f } }),
                ]) {
                    HStack(spacing: 6) {
                        Text(family ?? d.family).font(SidraFont.ui(13)).foregroundStyle(SidraColor.text).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(SidraColor.muted)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Terminal font")
            }
            SettingRow("Size", detail: "⌘+ and ⌘− change it from any terminal; ⌘0 resets it", isDefault: size == 0, reset: { size = 0 }) {
                HStack(spacing: 8) {
                    Button { TerminalFont.step(-1) } label: { Image(systemName: "minus") }.buttonStyle(.sidraSecondary).accessibilityLabel("Smaller text")
                    Text("\(Int(TerminalFont.size)) pt").font(SidraFont.mono(13)).foregroundStyle(SidraColor.text).frame(width: 52)
                    Button { TerminalFont.step(1) } label: { Image(systemName: "plus") }.buttonStyle(.sidraSecondary).accessibilityLabel("Bigger text")
                }
            }
        }
    }
}
#endif

#if os(iOS) || os(visionOS)
/// How to send a screenshot to a session: the Shortcuts action and the Share sheet (2026-11-19).
struct ScreenshotSection: View {
    let query: String
    var body: some View {
        if query.isEmpty || ["Screenshot", "Shortcut", "Share", "image"].contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
            SectionLabel("Screenshots")
            SettingRow("Send a screenshot", detail: "In Shortcuts, make a shortcut with Take Screenshot, then Send Screenshot to Sidra. Add it to Control Center, ask Siri, or set Apple Pencil Pro's squeeze to run it. Or take a screenshot and share it to Sidra.",
                       isDefault: true, reset: {}) { EmptyView() }
        }
    }
}
#endif

#if os(macOS)
/// How Substrate approvals reach the Mac desktop: Sidra's cards, the system banner, or nothing.
struct NotificationsSection: View {
    let query: String
    @AppStorage(SubstrateDesktop.modeKey) private var mode = SubstrateDesktop.Mode.cards.rawValue
    private let names: [SubstrateDesktop.Mode: String] = [.cards: "Sidra cards", .system: "System banner", .off: "Off"]

    var body: some View {
        if query.isEmpty || ["Notifications", "Substrate", "approval", "banner"].contains(where: { $0.localizedCaseInsensitiveContains(query) }) {
            let current = SubstrateDesktop.Mode(rawValue: mode) ?? .cards
            SectionLabel("Notifications")
            SettingRow("Substrate approvals", detail: current == .cards ? "Cards top-right over every app, with Approve, Reject and Edit. Touch ID first."
                       : current == .system ? "The macOS banner, only while Sidra is in the background." : "No notice. The Substrate pill still counts what waits.",
                       isDefault: current == .cards, reset: { mode = SubstrateDesktop.Mode.cards.rawValue }) {
                SidraMenu([SidraMenuSection(nil, SubstrateDesktop.Mode.allCases.map { m in SidraMenuItem(names[m] ?? m.rawValue) { mode = m.rawValue } })]) {
                    HStack(spacing: 6) {
                        Text(names[current] ?? "").font(SidraFont.ui(13)).foregroundStyle(SidraColor.text)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(SidraColor.muted)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Substrate approvals, \(names[current] ?? "")")
            }
        }
    }
}
#endif

/// Dictation: Apple's on-device model by default; Whisper large-v3 as an optional download.
struct VoiceSection: View {
    let query: String
    @State private var voice = VoiceInput.shared
    @AppStorage(MicInputs.key) private var micChoice: String?
    private func show(_ words: String...) -> Bool { query.isEmpty || words.contains { $0.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        if show("Voice", "dictation", "dictate", "Whisper", "speech", "microphone", "input") {
            SectionLabel("Voice")
            SettingRow("Dictation", detail: Platform.isMac ? "Hold the green mic, or ⌥⌘V. Speech stays on this Mac." : "Hold the green mic. Speech stays on this \(Platform.deviceName).", isDefault: voice.engine == .apple, reset: { voice.engine = .apple }) {
                SidraMenu([SidraMenuSection(nil, [
                    SidraMenuItem("Apple dictation") { voice.engine = .apple },
                    voice.whisperOnDisk
                        ? SidraMenuItem("Whisper large-v3") { voice.engine = .whisper }
                        : SidraMenuItem("Download Whisper large-v3 (\(VoiceInput.whisperSize))", systemImage: "arrow.down.circle") { voice.downloadWhisper() },
                ])]) {
                    HStack(spacing: 6) {
                        Text(voice.engine == .whisper && voice.whisperOnDisk ? "Whisper large-v3" : "Apple dictation").font(SidraFont.ui(13)).foregroundStyle(SidraColor.text)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(SidraColor.muted)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Dictation engine")
            }
            let inputs = MicInputs.all()
            let picked = inputs.first { $0.id == micChoice }
            SettingRow("Microphone", detail: micChoice != nil && picked == nil ? "The chosen microphone is not connected; the default is used." : "What dictation listens to.",
                       isDefault: micChoice == nil, reset: { micChoice = nil }) {
                SidraMenu([
                    SidraMenuSection(nil, [SidraMenuItem("System default", systemImage: "mic") { micChoice = nil }]),
                    SidraMenuSection("Inputs", inputs.map { d in SidraMenuItem(d.name) { micChoice = d.id } }),
                ]) {
                    HStack(spacing: 6) {
                        Text(picked?.name ?? "System default").font(SidraFont.ui(13)).foregroundStyle(SidraColor.text).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(SidraColor.muted)
                    }
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("Microphone, \(picked?.name ?? "system default")")
            }
            SettingRow("Whisper model", detail: voice.downloadError ?? "Optional. Better with code words and mixed languages. \(VoiceInput.whisperSize), downloaded once.",
                       isDefault: !voice.whisperOnDisk, reset: { voice.removeWhisper() }) {
                if let p = voice.downloadProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: p).frame(width: 120).tint(SidraColor.jade)
                        Text(p >= 1 ? "Preparing…" : "\(Int(p * 100))%").font(SidraFont.mono(12)).foregroundStyle(SidraColor.muted)
                    }
                } else if voice.whisperOnDisk {
                    Button("Remove") { voice.removeWhisper() }.buttonStyle(.sidraSecondary).disabled(voice.isActive)
                } else {
                    Button("Download \(VoiceInput.whisperSize)") { voice.downloadWhisper() }.buttonStyle(.sidraSecondary)
                }
            }
        }
    }
}
