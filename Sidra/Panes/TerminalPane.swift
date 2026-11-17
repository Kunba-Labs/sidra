import SwiftUI
import SidraDesign
import SidraWorkspace
import SidraTerminal
import SidraSSH

extension PTYSession: PaneSession {}
extension MoshPTY: PaneSession {}

/// What a terminal pane needs beyond the byte pipe.
protocol PaneSession: TerminalIO {
    var exit: AsyncStream<Int?> { get }
    var endReason: String? { get }
}

/// A terminal pane bound to a VM shell or an SSH host. Opens the PTY on appear, shows the
/// reason when it cannot, offers reconnect when the session ends.
struct TerminalPane: View {
    let pane: Pane
    let target: TerminalTarget
    /// Run this in the shell instead of the target's default (a herdr pane runs herdr).
    var command: String? = nil
    /// Runs before the PTY opens (a herdr pane writes its attach script); a throw shows as the pane's error.
    var prepare: (() async throws -> Void)? = nil
    @Environment(AppModel.self) private var app
    /// Session and connection state live per pane, outside the view: a tab switch keeps them.
    private var link: TerminalLink { TerminalLink.of(pane.id) }
    @Environment(\.scenePhase) private var scenePhase
    @State private var alert: SidraAlert?
    @State private var viewing: ViewedImage?
    @State private var prompter = HostKeyPrompter.shared
    @State private var ownsPrompt = false
    @State private var showFind = false
    /// A pasted image on its way to the host: 0…1, nil when none.
    @State private var pasteProgress: Double?
    @State private var findText = ""
    @State private var findStep = 0
    @State private var findTotal = 0
    @State private var findIndex: Int?
    @FocusState private var findFocused: Bool

    var body: some View {
        ZStack {
            if let session = link.session {
                TerminalPaneView(io: session, engine: app.terminalEngine, focusToken: app.workspace.focusedPane?.id == pane.id ? 1 : 0,
                                 searchQuery: showFind && !findText.isEmpty ? findText : nil, searchStep: findStep,
                                 onFind: { showFind = true; findFocused = true },
                                 onSearchResult: { total, index in findTotal = total; findIndex = index },
                                 onPasteImage: { data in await uploadPastedImage(data) }, pasteLabel: pasteLabel,
                                 onFetchImage: { path in await fetchImage(path) }, onOpenImage: { path, image in viewing = ViewedImage(path: path, image: image) },
                                 onOpenLink: { [app] url in app.openLink(url) },
                                 lost: link.ended && link.exitCode == nil)
                    .id("\(link.attempt)-\(app.terminalEngine.rawValue)")  // a new surface when the engine setting changes
                if showFind { findBar }
                if let p = pasteProgress { pasteCard(p) }
            } else if let error = link.error {
                statusView(symbol: "exclamationmark.triangle", title: link.failure?.title ?? "Could not open shell", detail: link.failure?.detail ?? error)
            } else {
                statusView(symbol: "terminal", title: "Connecting…", detail: targetDescription)
            }
            if link.ended {
                ConnectionLostCard(title: link.exitCode.map { $0 == 0 ? "Session ended" : "Session ended with status \($0)" } ?? "Connection lost",
                                   detail: link.exitCode == nil ? link.endReason : nil, lost: link.exitCode == nil, reconnect: reconnect)
            }
        }
        // One open per attempt: a Reconnect while one is in flight starts the next attempt, and the old one closes what it gets.
        .task(id: link.attempt) { if link.session == nil, link.error == nil, link.openingAttempt != link.attempt { await open() } }
        .task { await learnPasteLabel() }
        .onReceive(NotificationCenter.default.publisher(for: .sidraTerminalFind)) { _ in
            if app.workspace.focusedPane?.id == pane.id, link.session != nil { showFind = true; findFocused = true }
        }
        .onChange(of: paneExists) { _, exists in if !exists { TerminalLink.close(pane.id); BusyPanes.shared.set(pane.id, busy: false) } }
        .onChange(of: link.session != nil && !link.ended, initial: true) { _, live in BusyPanes.shared.set(pane.id, busy: live) }
        .onDisappear { if !paneExists { TerminalLink.close(pane.id); BusyPanes.shared.set(pane.id, busy: false) } }
        .onChange(of: scenePhase) { _, phase in
            guard let mosh = link.session as? MoshPTY else { return }
            if phase == .background { mosh.suspend() } else if phase == .active { mosh.resume() }
        }
        .keyUseConfirmation()
        .sidraAlert($alert)
        .sheet(item: $viewing) { ImageViewer(item: $0, machine: app.herdrMachineName(target)) }
        .sheet(item: Binding(get: { ownsPrompt ? prompter.pending.map { PromptBox(prompt: $0) } : nil }, set: { _ in })) { box in
            HostKeySheet(prompt: box.prompt) { prompter.decide($0) }
        }
    }

    private struct PromptBox: Identifiable { let prompt: HostKeyPrompt; var id: String { "\(prompt.host):\(prompt.port)" } }

    /// Scrollback search: Enter steps forward, Shift-Enter back, Esc closes.
    private var findBar: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(SidraColor.muted)
                TextField("Find in scrollback", text: $findText)
                    .textFieldStyle(.plain).font(SidraFont.mono(12.5)).foregroundStyle(SidraColor.text)
                    .autocorrectionDisabled().focused($findFocused)
                    .onSubmit { findStep += 1 }
                    .onKeyPress(.escape) { showFind = false; findText = ""; return .handled }
                    .onKeyPress(.return, phases: .down) { p in if p.modifiers.contains(.shift) { findStep -= 1; return .handled }; return .ignored }
                    .frame(width: 220)
                Text(findText.isEmpty ? "" : (findTotal == 0 ? "No matches" : "\((findIndex ?? 0) + 1) of \(findTotal)"))
                    .font(SidraFont.ui(11.5)).foregroundStyle(findTotal == 0 && !findText.isEmpty ? SidraColor.yellow : SidraColor.muted)
                    .frame(minWidth: 70, alignment: .leading)
                IconButton("chevron.up", label: "Previous match") { findStep -= 1 }
                IconButton("chevron.down", label: "Next match") { findStep += 1 }
                IconButton("xmark", label: "Close find") { showFind = false; findText = "" }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SidraColor.hairline2))
            .padding(10)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// False once the pane was closed (its tab may still exist); the PTY goes with it.
    private var paneExists: Bool { app.workspace.tabs.contains { $0.panes.contains { $0.id == pane.id } } }

    private var hostName: String {
        switch target {
        case .ssh(let id): app.hosts.host(id)?.host ?? "host"
        }
    }

    private var targetDescription: String {
        switch target {
        case .ssh(let id): app.hosts.host(id)?.alias ?? "host"
        }
    }

    private func statusView(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(SidraColor.dim)
            Text(title).font(SidraFont.ui(13.5, weight: .bold)).foregroundStyle(SidraColor.text)
            Text(detail).font(SidraFont.mono(12)).foregroundStyle(SidraColor.muted).multilineTextAlignment(.center)
            if link.failure == nil, let hint = link.error.flatMap(NetworkHints.hint) {
                Text(hint).font(SidraFont.ui(12.5)).foregroundStyle(SidraColor.yellow).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if let raw = link.error {
                HStack(spacing: 8) {
                    Button { reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon) }
                        .buttonStyle(.sidraDark).accessibilityIdentifier("Reconnect")
                    if let changed = link.changedKey {
                        Button("Accept new key") { KnownHosts.record(host: changed.host, port: changed.port, publicKey: changed.newKey); reconnect() }.buttonStyle(.sidraSecondary)
                    }
                    Button("Details") { alert = SidraAlert(title: link.failure?.title ?? "Could not open shell", detail: link.failure?.detail ?? raw, rawOutput: raw, primaryLabel: "Reconnect") { reconnect() } }.buttonStyle(.sidraSecondary)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reconnect() {
        let l = link
        if let s = l.session { TerminalPaneView.forget(s); s.close() }
        l.session = nil
        l.error = nil
        l.failure = nil
        l.changedKey = nil
        l.ended = false
        l.exitCode = nil
        l.endReason = nil
        l.attempt += 1
    }

    /// Claude Code and friends read the remote machine's clipboard, which never has the iPad's image.
    /// So the image goes to /tmp there and its path is pasted instead; they attach an image path.
    /// ⌘V for a Mac on the far side, ^V for Linux (the VM is Linux). Learned once per host per launch.
    @State private var pasteLabel = "⌘V"
    @MainActor private static var hostIsMac: [UUID: Bool] = [:]
    private func learnPasteLabel() async {
        switch target {
        case .ssh(let id):
            if Self.hostIsMac[id] == nil, let r = try? await app.herdrRun(target, "uname -s") {
                Self.hostIsMac[id] = r.stdoutText.contains("Darwin")
            }
            pasteLabel = Self.hostIsMac[id] == false ? "^V" : "⌘V"
        }
    }

    /// An image path printed on screen, read from the far side for its thumbnail (8 MB at most).
    private func fetchImage(_ path: String) async -> Data? {
        guard !path.contains("'"), !path.contains("\\") else { return nil }
        let quoted = path.hasPrefix("~/") ? "\"$HOME\"/'\(path.dropFirst(2))'" : "'\(path)'"
        guard let r = try? await app.herdrRun(target, "[ -f \(quoted) ] && [ $(wc -c < \(quoted)) -le 8000000 ] && base64 < \(quoted)"),
              r.exitCode == 0 else { return nil }
        return Data(base64Encoded: r.stdoutText, options: .ignoreUnknownCharacters)
    }

    private func uploadPastedImage(_ data: Data) async -> String? {
        var dir = ""
        do {
            // A private directory made by mktemp (0700, created exclusively), so nothing else in /tmp can
            // plant the file or a symlink. Only folders Sidra made on this machine are cleaned, a day later.
            let stale = PasteFolders.stale(for: target).map { "'\($0)'" }.joined(separator: " ")
            let made = try await app.herdrRun(target, (stale.isEmpty ? "" : "rm -rf \(stale); ") + "mktemp -d /tmp/sidra-paste-XXXXXXXX")
            PasteFolders.forget(PasteFolders.stale(for: target), for: target)
            dir = made.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard made.exitCode == 0, dir.hasPrefix("/tmp/sidra-paste-"), !dir.contains("'") else { throw AppError.message("could not make a folder in /tmp") }
            PasteFolders.remember(dir, for: target)
            let path = dir + "/image.png"
            pasteProgress = 0
            defer { pasteProgress = nil }
            // ponytail: 64 KiB base64 per command keeps under every ARG_MAX; an SFTP upload if big pastes feel slow
            var offset = 0
            while offset < data.count {
                let end = min(offset + 48 * 1024, data.count)
                let b64 = data[data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: end)].base64EncodedString()
                let r = try await app.herdrRun(target, "printf %s '\(b64)' | base64 -d >> '\(path)'")
                guard r.exitCode == 0 else { throw AppError.message("the upload stopped with status \(r.exitCode)") }
                offset = end
                pasteProgress = Double(offset) / Double(max(data.count, 1))
            }
            app.toast("Image pasted as \(path)")
            return path
        } catch {
            if !dir.isEmpty, (try? await app.herdrRun(target, "rm -rf '\(dir)'")) != nil { PasteFolders.forget([dir], for: target) }
            alert = .from(error, title: "Could not paste the image")
            return nil
        }
    }

    /// While a pasted image uploads: its size, the share sent and a progress bar (the gradient is progress).
    private func pasteCard(_ p: Double) -> some View {
        VStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    GradientSpinner(size: 12)
                    Text("Pasting image").font(SidraFont.ui(12.5, weight: .bold)).foregroundStyle(SidraColor.text)
                    Spacer()
                    Text("\(Int(p * 100))%").font(SidraFont.mono(12)).foregroundStyle(SidraColor.muted)
                }
                GradientProgress(p)
            }
            .padding(12)
            .frame(width: 260)
            .background(SidraColor.popup, in: RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous).strokeBorder(SidraColor.hairline2))
            .padding(12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Pasting image, \(Int(p * 100)) percent")
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .allowsHitTesting(false)
    }

    private func open() async {
        prompter.install()
        // The link and attempt this open belongs to: a Reconnect or a closed pane while it awaits makes it stale.
        let link = link
        let mine = link.attempt
        link.openingAttempt = mine
        defer { if link.openingAttempt == mine { link.openingAttempt = nil } }
        do {
            try await prepare?()
            let s: any PaneSession
            switch target {
            case .ssh(let id):
                guard let profile = app.hosts.host(id) else { throw AppError.message("No host profile") }
                #if DEBUG
                if DemoMode.isOn, id == DemoMode.hostID {
                    let demo = DemoMode.session(herdr: command != nil)
                    link.session = demo
                    return
                }
                #endif
                ownsPrompt = true
                defer { ownsPrompt = false }
                let connection = app.connection(for: profile)
                if profile.mosh != nil, !profile.isThisMac, command == nil { s = try await connection.openMosh(cols: 80, rows: 24) }
                else { s = try await connection.openShell(cols: 80, rows: 24, command: command) }
            }
            guard link.attempt == mine, TerminalLink.isCurrent(link, for: pane.id) else { s.close(); return }
            link.session = s
            Task {
                var code: Int?
                for await c in s.exit { code = c }
                await MainActor.run {
                    guard link.attempt == mine else { return }   // a session that was replaced has nothing to report
                    link.exitCode = code
                    link.endReason = s.endReason
                    link.ended = true
                }
            }
        } catch {
            // A tab switch cancels this view's task: no error, the next appearance opens the link again.
            if error is CancellationError || Task.isCancelled { return }
            guard link.attempt == mine, TerminalLink.isCurrent(link, for: pane.id) else { return }
            link.error = describeError(error)
            link.failure = SSHFailure.describe(error, host: hostName)
            link.changedKey = error as? HostKeyChanged
        }
    }
}

/// A terminal pane's session and connection state, kept per pane while the pane exists, so switching
/// tabs neither drops the SSH session nor reconnects (the surface is kept by `TerminalPaneView`).
@MainActor @Observable
final class TerminalLink {
    var session: (any PaneSession)?
    var endReason: String?
    var error: String?
    var ended = false
    var exitCode: Int?
    var attempt = 0
    var failure: SSHFailure.Description?
    var changedKey: HostKeyChanged?
    /// The attempt an open is in flight for, if any.
    var openingAttempt: Int?

    @ObservationIgnored private static var all: [UUID: TerminalLink] = [:]
    static func of(_ pane: UUID) -> TerminalLink {
        if let l = all[pane] { return l }
        let l = TerminalLink()
        all[pane] = l
        return l
    }
    static func isCurrent(_ link: TerminalLink, for pane: UUID) -> Bool { all[pane] === link }

    /// The pane closed: end its session and drop its surface.
    static func close(_ pane: UUID) {
        guard let l = all.removeValue(forKey: pane), let s = l.session else { return }
        TerminalPaneView.forget(s)
        s.close()
    }

    /// Closes the links of panes no window holds any more (a tab closed while hidden never runs its view's handlers).
    static func prune(live: Set<UUID>) {
        for id in all.keys where !live.contains(id) { close(id) }
    }
}

enum AppError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m } else { return nil } }
}

func describeError(_ error: Error) -> String {
    if let l = error as? LocalizedError, let d = l.errorDescription { return d }
    return String(describing: error)
}

/// Plain-language hints for the two iPad network failures that look like bugs.
enum NetworkHints {
    static func hint(_ error: String) -> String? {
        let e = error.lowercased()
        if e.contains("local network") || e.contains("-65570") || e.contains("nodatareceived") || e.contains("not permitted") {
            return "iPadOS blocked local network access. Settings → Privacy & Security → Local Network → allow Sidra, then retry."
        }
        if e.contains("no route") || e.contains("unreachable") || e.contains("timed out") || e.contains("timeout") {
            return "The host did not answer. A VPN or Tailscale profile can hide LAN hosts; turn it off or add the host to the split tunnel."
        }
        return nil
    }
}

/// The /tmp folders Sidra made for pasted images, per machine, so cleanup never touches anyone else's.
/// Kept across launches; a folder is removed a day after it was made, on the next paste to that machine.
enum PasteFolders {
    private static let key = "sidra.pasteFolders"
    private static func all() -> [String: [String: Double]] { UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Double]] ?? [:] }
    private static func machine(_ t: TerminalTarget) -> String {
        switch t { case .ssh(let id): id.uuidString }
    }
    static func remember(_ dir: String, for t: TerminalTarget) {
        var a = all(); a[machine(t), default: [:]][dir] = Date().timeIntervalSince1970
        UserDefaults.standard.set(a, forKey: key)
    }
    static func stale(for t: TerminalTarget) -> [String] {
        let cutoff = Date().timeIntervalSince1970 - 86_400
        return (all()[machine(t)] ?? [:]).filter { $0.value < cutoff }.map(\.key).filter { $0.hasPrefix("/tmp/sidra-paste-") && !$0.contains("'") }
    }
    static func forget(_ dirs: [String], for t: TerminalTarget) {
        guard !dirs.isEmpty else { return }
        var a = all(); for d in dirs { a[machine(t)]?[d] = nil }
        UserDefaults.standard.set(a, forKey: key)
    }
}

struct ViewedImage: Identifiable {
    let path: String
    let image: PlatformImage
    var id: String { path }
}

/// A terminal image full size: its name and machine, Share (Copy and Save to Files live there), Close.
struct ImageViewer: View {
    let item: ViewedImage
    let machine: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text((item.path as NSString).lastPathComponent).font(SidraFont.ui(14, weight: .semibold)).foregroundStyle(SidraColor.text)
                    .lineLimit(1).truncationMode(.middle)
                FooterChip([.init("\(Int(item.image.size.width))×\(Int(item.image.size.height))", icon: "photo"), .init(machine, icon: "desktopcomputer")])
                Spacer(minLength: 8)
                ShareLink(item: Image(platformImage: item.image), preview: SharePreview((item.path as NSString).lastPathComponent, image: Image(platformImage: item.image))) {
                    Label("Share", systemImage: "square.and.arrow.up").font(SidraFont.ui(13))
                }
                .buttonStyle(.bordered)
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(.bordered).accessibilityLabel("Close")
            }
            Image(platformImage: item.image).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(item.path).font(SidraFont.mono(11)).foregroundStyle(SidraColor.dim).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(SidraColor.popup)
        .presentationDetents([.large])
    }
}

/// The card at a pane's bottom when its connection ends: what happened, why, and Reconnect.
/// Terminal, herdr and Screen Sharing panes share it.
struct ConnectionLostCard: View {
    let title: String
    var detail: String?
    var lost = true
    let reconnect: () -> Void

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(SidraFont.ui(12.5, weight: .bold)).foregroundStyle(lost ? SidraColor.orange : SidraColor.muted)
                    if let detail { Text(detail).font(SidraFont.ui(12)).foregroundStyle(SidraColor.muted) }
                }
                Button { reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon) }
                    .buttonStyle(.sidraDark).accessibilityIdentifier("Reconnect")
            }
            .padding(10)
            .background(SidraColor.raised, in: RoundedRectangle(cornerRadius: SidraRadius.card, style: .continuous))
            .padding(12)
        }
    }
}
