import UserNotifications
import SidraDesign
#if canImport(UIKit)
import UIKit
#endif
import OSLog

/// Local notifications for long-running things finishing while Sidra is in the background:
/// build or flash done, agent waiting for approval. Foreground: nothing, the UI already shows it.
/// Tapping one opens where it came from (`AppModel.open(_:)`).
enum Notifier {
    private static let log = Logger(subsystem: "nl.sadiq.sidra", category: "notify")
    enum Route: Equatable {
        case pane(UUID)
        var userInfo: [String: String] { switch self { case .pane(let id): ["pane": id.uuidString] } }
        init?(userInfo: [AnyHashable: Any]) {
            if let s = userInfo["pane"] as? String, let id = UUID(uuidString: s) { self = .pane(id) }
            else { return nil }
        }
    }

    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        // The completion form: UIKit asserts when the async form completes off the main thread.
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
            let route = Route(userInfo: response.notification.request.content.userInfo)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if let route { Notifier.pending = route } }
                done()
            }
        }
    }
    static let delegate = Delegate()
    /// A tapped route waiting for a scene; SceneRoot consumes it, also after a cold launch.
    @MainActor static var pending: Route? { didSet { if pending != nil { NotificationCenter.default.post(name: .sidraNotificationRoute, object: nil) } } }

    static func start() {
        UNUserNotificationCenter.current().delegate = delegate
        // -sidra.requestNotifications (UI tests): iPadOS only shows the prompt in the foreground.
        if CommandLine.arguments.contains("-sidra.requestNotifications") { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    @MainActor static func notify(_ title: String, _ body: String, route: Route? = nil) {
        log.log("notify \(title, privacy: .public) active=\(Platform.isAppActive)")
        guard !Platform.isAppActive else { return }
        // The build's own background grace ends as it finishes; this keeps the app awake until the post is queued.
        let task = Platform.beginBackgroundTask("sidra.notify")
        let finish = { DispatchQueue.main.async { Platform.endBackgroundTask(task) } }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            log.log("authorized=\(ok)")
            guard ok else { finish(); return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.sound = .default
            if let route { c.userInfo = route.userInfo }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { _ in finish() }
        }
    }
}

extension Notification.Name { static let sidraNotificationRoute = Notification.Name("sidra.notificationRoute") }
