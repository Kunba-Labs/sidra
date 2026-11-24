import SwiftUI
import Network
import OSLog
import SidraDesign

/// iPadOS conditions that change what Sidra may do: heat, local network permission, VPN.
@MainActor
@Observable
final class PlatformStatus {
    static let shared = PlatformStatus()
    var thermal = ThermalPolicy.state
    var buildsPaused = false
    /// The user tapped Resume while still critical; do not pause again until it cools.
    var resumedWhileCritical = false
    /// -sidra.localNetworkDenied (UI tests): the Simulator does not enforce this permission.
    var localNetworkDenied = UserDefaults.standard.bool(forKey: "sidra.localNetworkDenied")
    private var browser: NWBrowser?
    enum LocalNetworkAnswer { case notAsked, asking, allowed, denied }
    var localNetwork: LocalNetworkAnswer = UserDefaults.standard.bool(forKey: "sidra.localNetworkDenied") ? .denied : .notAsked
    /// Set once the iPadOS prompt has been triggered: from then on a probe shows no prompt.
    var localNetworkAsked: Bool { UserDefaults.standard.bool(forKey: "sidra.localNetworkAsked") }
    private var probeListener: NWListener?
    private var probeBrowser: NWBrowser?
    private var probeDeadline: Task<Void, Never>?
    private var denyCheck: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PlatformStatus.shared.thermal = ThermalPolicy.state }
        }
    }

    /// A Bonjour browse answers PolicyDenied when Local Network is off. It needs no known host, and
    /// a connection's `.localNetworkDenied` path reason is the same permission seen per connection.
    func watchLocalNetwork() {
        guard browser == nil, !UserDefaults.standard.bool(forKey: "sidra.localNetworkDenied") else { return }
        let b = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: nil), using: .tcp)
        b.stateUpdateHandler = { state in
            let denied = Self.isDenied(state)
            Task { @MainActor in if let denied { PlatformStatus.shared.localNetworkDenied = denied } }
        }
        b.start(queue: .main)
        browser = b
    }

    /// iPadOS has no call that reads this permission and no call that asks for it. Advertising a
    /// Bonjour service and browsing for it does both: the first use raises the prompt, and seeing our
    /// own service come back proves access.
    func askLocalNetwork() {
        guard !UserDefaults.standard.bool(forKey: "sidra.localNetworkDenied") else { localNetwork = .denied; return }
        if localNetwork == .denied { stopProbe() }   // back from Settings: look again
        guard probeListener == nil, let listener = try? NWListener(using: .tcp) else { return }
        UserDefaults.standard.set(true, forKey: "sidra.localNetworkAsked")
        let type = "_sidra-probe._tcp", name = UUID().uuidString
        listener.service = NWListener.Service(name: name, type: type)
        listener.newConnectionHandler = { $0.cancel() }
        let b = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { results, _ in
            let found = results.contains { if case .service(name, _, _, _) = $0.endpoint { true } else { false } }
            if found { Task { @MainActor in PlatformStatus.shared.finishProbe(.allowed) } }
        }
        b.stateUpdateHandler = { state in
            if Self.isDenied(state) == true { Task { @MainActor in PlatformStatus.shared.confirmDenied() } }
        }
        probeListener = listener; probeBrowser = b
        localNetwork = .asking
        listener.start(queue: .main); b.start(queue: .main)
        probeDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            if !Task.isCancelled, let self { self.finishProbe(self.localNetwork == .denied ? .denied : .notAsked) }
        }
    }

    /// The browser reports PolicyDenied while the prompt is still on screen, so this waits for the app
    /// to be active again. The probe keeps running afterwards: if the prompt was still up and the user
    /// allows access, the browser finds the service and the card turns to Done.
    private func confirmDenied() {
        denyCheck?.cancel()
        denyCheck = Task { [weak self] in
            repeat { try? await Task.sleep(for: .seconds(3)) } while !Task.isCancelled && !Platform.isAppActive
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, self?.localNetwork == .asking { self?.localNetwork = .denied; self?.localNetworkDenied = true }
        }
    }

    private func finishProbe(_ answer: LocalNetworkAnswer) {
        guard probeListener != nil else { return }
        stopProbe()
        localNetwork = answer
        if answer == .allowed { localNetworkDenied = false } else if answer == .denied { localNetworkDenied = true }
    }

    private func stopProbe() {
        probeDeadline?.cancel(); denyCheck?.cancel()
        probeListener?.cancel(); probeBrowser?.cancel()
        probeListener = nil; probeBrowser = nil
    }

    nonisolated static func isDenied(_ state: NWBrowser.State) -> Bool? {
        switch state {
        case .waiting(.dns(let code)) where code == -65570: true   // kDNSServiceErr_PolicyDenied
        case .ready: false
        default: nil
        }
    }

    /// iPadOS exposes active VPN interfaces through the proxy settings' scoped keys.
    nonisolated static func vpnActive(scoped: [String]) -> Bool {
        scoped.contains { key in ["tap", "tun", "ppp", "ipsec"].contains { key.hasPrefix($0) } }
    }
    nonisolated static var vpnActive: Bool {
        if UserDefaults.standard.bool(forKey: "sidra.vpnActive") { return true }
        guard let all = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
              let scoped = all["__SCOPED__"] as? [String: Any] else { return false }
        return vpnActive(scoped: Array(scoped.keys))
    }

    /// `App-prefs:` is private, which is fine for a build that never goes to the App Store. iPadOS may
    /// stop honouring it, so a refusal falls back to Sidra's own page in Settings.
    static func openSystemSettings(_ link: String) {
        #if os(iOS) || os(visionOS)
        guard let u = URL(string: link) else { return openSettings() }
        UIApplication.shared.open(u) { ok in if !ok { Task { @MainActor in openSettings() } } }
        #else
        openSettings()
        #endif
    }

    static func openSettings() {
        #if os(iOS) || os(visionOS)
        if let u = URL(string: UIApplication.openSettingsURLString) { Platform.open(u) }
        #else
        // Local Network and other privacy switches live under Privacy & Security on the Mac.
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security") { Platform.open(u) }
        #endif
    }
}

/// Banners under the title bar for conditions the user has to act on.
struct PlatformBanners: View {
    @Environment(AppModel.self) private var app
    @State private var status = PlatformStatus.shared

    var body: some View {
        VStack(spacing: 6) {
            if status.localNetworkDenied {
                banner("Local Network is off for Sidra. Hosts on your network cannot be reached.", color: SidraColor.yellow) {
                    Button("Open Settings") { PlatformStatus.openSettings() }.buttonStyle(BannerButton())
                }
            }
        }
        .padding(.top, 52)
        // Only once there is a host to reach: the probe can raise the Local Network prompt.
        .task(id: app.hosts.hosts.isEmpty) { if !app.hosts.hosts.isEmpty { status.watchLocalNetwork() } }
    }

    private func banner<A: View>(_ text: String, color: Color, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 10) {
            Text(text).font(SidraFont.ui(12.5, weight: .bold))
            action()
        }
        .foregroundStyle(Color(hex: 0x141414))
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(color, in: Capsule())
    }

    private struct BannerButton: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.font(SidraFont.ui(12, weight: .bold))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Color.black.opacity(configuration.isPressed ? 0.3 : 0.18), in: Capsule())
        }
    }
}

/// Folders that must stay out of iCloud backup. Documents stays backed up.
enum DataLayout {
    static func folder(_ name: String) -> URL? {
        guard let base = FileManager.default.sidraSupport else { return nil }
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static let excluded = ["VM", "Toolchains", "Models", "Caches"]

    /// The flag sits on each folder; it is lost when a folder is replaced, so this also runs after writes.
    static func apply() {
        for name in excluded { if let f = folder(name) { exclude(f) } }
    }
    static func exclude(_ url: URL) {
        var u = url
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }
}

/// os_log export for bug reports: the last hour of this process, as a text file.
enum LogExport {
    nonisolated static func write() throws -> URL {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: Date().addingTimeInterval(-3600)))
        var text = ""
        var n = 0
        for case let e as OSLogEntryLog in entries where n < 20_000 {   // ponytail: cap so an export stays shareable
            text += "\(e.date.ISO8601Format()) [\(e.subsystem)/\(e.category)] \(e.composedMessage)\n"
            n += 1
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidra-log.txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }
}

extension View {
    /// Sidra's dark panel behind a sheet. On Apple Vision Pro only as the sheet's own background: a panel-sized
    /// slab inside the glass sheet left glass edges around it, and plain glass washes out Sidra's greys (2026-11-24).
    func sidraSheetBackground() -> some View {
        #if os(visionOS)
        presentationBackground(SidraColor.panel)
        #else
        background(SidraColor.panel).presentationBackground(SidraColor.panel)
        #endif
    }
}
