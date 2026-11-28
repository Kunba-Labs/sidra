import SwiftUI
import SidraDesign
import SidraSSH

/// Settings → Keys: every Sidra SSH identity with fingerprint, copy, install, confirm-on-use, delete.
struct KeysSection: View {
    @Environment(AppModel.self) private var app
    @Binding var alert: SidraAlert?
    var query = ""
    @State private var keys: [SSHKeyRecord] = []
    @State private var naming = false
    @State private var newName = ""
    @State private var importing = false
    @State private var copiedID: UUID?
    @State private var deleting: SSHKeyRecord?

    var body: some View {
        SectionLabel("Keys")
        VStack(spacing: 0) {
            ForEach(keys.filter { query.isEmpty || "keys ssh key".localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query) }) { k in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "key.horizontal.fill").foregroundStyle(SidraColor.gold).frame(width: 20).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        // iPhone: the chips go under the name; beside it they ran off the screen.
                        (Platform.isPhone ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 8))) {
                            Text(k.name).font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text)
                            FooterChip([.init(k.isSecureEnclave ? "P-256, Secure Enclave" : "ed25519", color: k.isSecureEnclave ? SidraColor.jade : SidraColor.muted), .init(k.created.formatted(date: .abbreviated, time: .omitted), label: "created", color: SidraColor.muted)])
                            if usedBy(k).count > 0 { FooterChip([.init("\(usedBy(k).count)", label: "hosts", color: SidraColor.jade)]) }
                        }
                        Text(k.fingerprint).font(SidraFont.mono(11.5)).foregroundStyle(SidraColor.dim).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button(copiedID == k.id ? "Copied" : "Copy public key") { Platform.pasteString = k.publicKey; copiedID = k.id }.buttonStyle(.sidraSecondary)
                            Toggle("Confirm on use", isOn: Binding(get: { k.confirmOnUse }, set: { SSHKeyManager.setConfirmOnUse(k.id, $0); reload() }))
                                .toggleStyle(GradientToggleStyle()).font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted).fixedSize()
                            Spacer()
                            Button("Delete", role: .destructive) { deleting = k }.buttonStyle(.sidraSecondary).disabled(keys.count == 1)
                        }.padding(.top, 2)
                    }
                }
                .padding(.vertical, 8)
                Rectangle().fill(SidraColor.hairline).frame(height: 1)
            }
            HStack(spacing: 8) {
                Text("Confirm on use asks for Face ID or the passcode before the key signs a login or a request from the VM. Agent in VM lets anything running there, the coding agent included, request signatures. A key copied into the VM for git has no confirmation there.").font(SidraFont.ui(11.5)).foregroundStyle(SidraColor.dim)
                Spacer()
                if SSHKeyManager.secureEnclaveAvailable {
                    Button("Secure Enclave key") {
                        do { try SSHKeyManager.generateSecureEnclave(name: ""); reload() }
                        catch { alert = SidraAlert.from(error, title: "Could not create the key") }
                    }.buttonStyle(.sidraSecondary)
                } else {
                    FooterChip([.init("Secure Enclave", color: SidraColor.muted), .init("device only", color: SidraColor.muted)])
                }
                Button("Import key…") { importing = true }.buttonStyle(.sidraSecondary)
                Button("Generate key…") { newName = ""; naming = true }.buttonStyle(.sidraSecondary)
            }.padding(.top, 8)
        }
        .onAppear(perform: reload)
        .alert("New Ed25519 key", isPresented: $naming) {
            TextField("Name (e.g. work laptop, GitHub)", text: $newName)
            Button("Generate") {
                do { try SSHKeyManager.generate(name: newName); reload() }
                catch { alert = SidraAlert.from(error, title: "Could not generate the key") }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete \(deleting?.name ?? "key")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let d = deleting { delete(d) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let d = deleting, !usedBy(d).isEmpty {
                let next = keys.first(where: { $0.id != d.id })
                Text("\(usedBy(d).map(\.alias).joined(separator: ", ")) use this key. " + (next.map { "They will be switched to \($0.name); install that key on those hosts first or their logins will fail." } ?? "They will have no key left and their logins will fail until you generate or import one."))
            } else {
                Text("The private key leaves the Keychain. Any host that trusts only this key will reject Sidra until another key is installed.")
            }
        }
        .sheet(isPresented: $importing) { ImportKeySheet { text, name in
            do { try SSHKeyManager.importOpenSSH(text, name: name); reload(); return nil }
            catch { return SidraAlert.from(error, title: "Could not import the key") }
        } }
}

    /// Deletes the key and moves its hosts to the next key explicitly, so nothing falls back by accident.
    private func delete(_ k: SSHKeyRecord) {
        let affected = usedBy(k)
        let next = keys.first(where: { $0.id != k.id })
        SSHKeyManager.delete(k.id)
        for var h in affected {
            h.keyID = next?.id
            app.hosts.upsert(h)
            _ = app.connection(for: h)
        }
        reload()
        if !affected.isEmpty { app.toast(next.map { "\(affected.count) host(s) now use \($0.name)" } ?? "\(affected.count) host(s) have no key") }
    }

    private func usedBy(_ k: SSHKeyRecord) -> [SSHHostProfile] {
        app.hosts.hosts.filter { $0.auth == .key && ($0.keyID ?? keys.first?.id) == k.id }
    }

    private func reload() { keys = SSHKeyManager.keys() }

}

struct ImportKeySheet: View {
    /// Returns nil on success or the alert to show.
    let onImport: (String, String) -> SidraAlert?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = ""
    @State private var alert: SidraAlert?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import a private key").font(SidraFont.ui(19, weight: .bold)).foregroundStyle(SidraColor.text)
            Text("Paste an OpenSSH Ed25519 private key. It goes straight into the Keychain; nothing is written to disk. Passphrase-protected keys must be decrypted first.")
                .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
            TextField("Name", text: $name).textFieldStyle(.plain).font(SidraFont.mono(13)).foregroundStyle(SidraColor.text)
                .padding(8).background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
            TextEditor(text: $text).font(SidraFont.mono(11.5)).foregroundStyle(SidraColor.text).scrollContentBackground(.hidden)
                .autocorrectionDisabled().plainTextEntry()
                .frame(height: 220).padding(6).background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Paste") { text = Platform.pasteString ?? "" }.buttonStyle(.sidraSecondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.sidraSecondary)
                Button("Import") {
                    if let a = onImport(text, name) { alert = a } else { dismiss() }
                }.buttonStyle(.sidraPrimary).disabled(text.isEmpty)
            }
        }
        .padding(24).frame(maxWidth: 560).sidraSheetBackground()
        .sidraAlert($alert)
    }
}

/// Fingerprint confirmation for an unknown host (profiles without trust-on-first-use).
@MainActor
@Observable
final class HostKeyPrompter {
    static let shared = HostKeyPrompter()
    /// Prompts queue up; each answer resumes exactly the connection that asked.
    private var queue: [(prompt: HostKeyPrompt, continuation: CheckedContinuation<Bool, Never>)] = []
    var pending: HostKeyPrompt? { queue.first?.prompt }
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        SSHConnection.setHostKeyPrompt { prompt in
            await withCheckedContinuation { c in
                Task { @MainActor in HostKeyPrompter.shared.queue.append((prompt, c)) }
            }
        }
    }

    func decide(_ accept: Bool) {
        guard !queue.isEmpty else { return }
        let entry = queue.removeFirst()
        entry.continuation.resume(returning: accept)
    }
}

struct HostKeySheet: View {
    let prompt: HostKeyPrompt
    let decide: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("First connection to \(prompt.host)").font(SidraFont.ui(17, weight: .bold)).foregroundStyle(SidraColor.text)
            Text("The server identifies itself with this key. Compare the fingerprint with one you trust (for example `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the host) before accepting.")
                .font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.muted)
            Text(prompt.fingerprint).font(SidraFont.mono(12.5)).foregroundStyle(SidraColor.text).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: 0x0f1216), in: RoundedRectangle(cornerRadius: 8))
            HStack { Spacer(); Button("Refuse") { decide(false) }.buttonStyle(.sidraSecondary); Button("Trust this host") { decide(true) }.buttonStyle(.sidraPrimary) }
        }
        .padding(22).frame(maxWidth: 480).sidraSheetBackground()
        .interactiveDismissDisabled()
    }
}

/// Confirm-on-use fallback when the device has no passcode or Face ID: an explicit in-app
/// confirmation instead of a silent pass. Shown by whichever view installed `.keyUseConfirmation()`.
@MainActor
@Observable
final class KeyUsePrompter {
    static let shared = KeyUsePrompter()
    var pendingHost: String?
    private var continuation: CheckedContinuation<Bool, Never>?

    func ask(_ host: String) async -> Bool {
        if let c = continuation { continuation = nil; c.resume(returning: false) }   // one at a time
        pendingHost = host
        return await withCheckedContinuation { continuation = $0 }
    }

    func decide(_ ok: Bool) {
        pendingHost = nil
        let c = continuation
        continuation = nil
        c?.resume(returning: ok)
    }
}

struct KeyUseConfirmationModifier: ViewModifier {
    @State private var prompter = KeyUsePrompter.shared
    func body(content: Content) -> some View {
        content.alert("Use the Sidra SSH key?", isPresented: Binding(get: { prompter.pendingHost != nil }, set: { if !$0 { prompter.decide(false) } })) {
            Button("Use key") { prompter.decide(true) }
            Button("Cancel", role: .cancel) { prompter.decide(false) }
        } message: {
            Text("This key is marked confirm-on-use and this device has no passcode or Face ID to check. Log in to \(prompter.pendingHost ?? "the host") with it?")
        }
    }
}

extension View {
    func keyUseConfirmation() -> some View { modifier(KeyUseConfirmationModifier()) }
}
