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
        /// A Substrate request waiting for approval: its account and message.
        case substrate(UUID, String)
        var userInfo: [String: String] {
            switch self {
            case .pane(let id): ["pane": id.uuidString]
            case .substrate(let c, let m): ["substrateConnection": c.uuidString, "substrateMessage": m]
            }
        }
        init?(userInfo: [AnyHashable: Any]) {
            if let s = userInfo["pane"] as? String, let id = UUID(uuidString: s) { self = .pane(id) }
            else if let c = (userInfo["substrateConnection"] as? String).flatMap(UUID.init(uuidString:)), let m = userInfo["substrateMessage"] as? String { self = .substrate(c, m) }
            else { return nil }
        }
    }

    /// Approve and Reject on a Substrate approval notification; tapping the card opens the request.
    static let approvalCategory = "substrate.approval"

    final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        // The completion form: UIKit asserts when the async form completes off the main thread.
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
            let route = Route(userInfo: response.notification.request.content.userInfo)
            let action = response.actionIdentifier
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if case .substrate(let c, let m) = route, action == "approve" || action == "reject" {
                        // Acted on in the background: no window opens. A failure comes back as a notification.
                        let task = Platform.beginBackgroundTask("sidra.substrate.act")
                        Task { @MainActor in
                            do {
                                guard let store = SubstrateHub.shared.store(c) else { throw Substrate.Failure(status: 0, text: "That Substrate account is gone.") }
                                if action == "approve" { try await store.approve(m) } else { try await store.reject(m) }
                            } catch {
                                Notifier.notify("Substrate did not take it", error.localizedDescription, route: route)
                            }
                            Platform.endBackgroundTask(task)
                            done()
                        }
                        return
                    }
                    if let route { Notifier.pending = route }
                    done()
                }
            }
        }
    }
    static let delegate = Delegate()
    /// A tapped route waiting for a scene; SceneRoot consumes it, also after a cold launch.
    @MainActor static var pending: Route? { didSet { if pending != nil { NotificationCenter.default.post(name: .sidraNotificationRoute, object: nil) } } }

    static func start() {
        UNUserNotificationCenter.current().delegate = delegate
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: approvalCategory, actions: [
                UNNotificationAction(identifier: "approve", title: "Approve", options: [.authenticationRequired]),
                UNNotificationAction(identifier: "reject", title: "Reject", options: [.authenticationRequired, .destructive]),
            ], intentIdentifiers: []),
        ])
        // -sidra.requestNotifications (UI tests): iPadOS only shows the prompt in the foreground.
        if CommandLine.arguments.contains("-sidra.requestNotifications") { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    @MainActor static func notify(_ title: String, _ body: String, route: Route? = nil, category: String? = nil, id: String = UUID().uuidString) {
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
            if let category { c.categoryIdentifier = category }
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { _ in finish() }
        }
    }
}

extension Notification.Name { static let sidraNotificationRoute = Notification.Name("sidra.notificationRoute") }
