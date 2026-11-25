#if os(iOS) || os(visionOS)
import UIKit
import UserNotifications

/// Server pushes for Substrate approvals (2026-11-20): Sidra's /live stream stops once iPadOS suspends the
/// app, so Substrate itself sends an APNs alert for each request that starts waiting, with the same
/// Approve and Reject as the local one (Notifier.approvalCategory). The token goes to every signed-in account.
@MainActor enum SubstratePush {
    private static let key = "sidra.apnsToken"
    static var token: String? { UserDefaults.standard.string(forKey: key) }

    /// Asks for permission (once; iPadOS remembers the answer) and registers with APNs. Also on every
    /// launch, as Apple asks: the token can change.
    static func enable() {
        #if DEBUG
        if CommandLine.arguments.contains("-sidra.substrateEditorDemo") { return }   // a screenshot without the permission prompt over it
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            guard ok else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    static func received(_ data: Data) {
        let t = data.map { String(format: "%02x", $0) }.joined()
        guard t != token else { return }
        UserDefaults.standard.set(t, forKey: key)
        for c in SubstrateHub.shared.connections {
            guard let s = SubstrateHub.shared.store(c.id), s.signedIn else { continue }
            Task { await s.registerDevice(t) }
        }
    }

    /// Development-signed builds (Xcode, the Tailscale page) get sandbox tokens; TestFlight and the App Store
    /// carry no embedded profile and get production ones.
    static let sandbox: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url), let text = String(data: raw, encoding: .isoLatin1) else { return false }
        return text.range(of: #"<key>aps-environment</key>\s*<string>development</string>"#, options: .regularExpression) != nil
    }()
}

final class SidraAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { SubstratePush.received(deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("Sidra: APNs registration failed: \(error.localizedDescription)")
    }
}
#endif
