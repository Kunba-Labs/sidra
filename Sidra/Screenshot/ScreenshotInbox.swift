#if os(iOS) || os(visionOS)
import SwiftUI
import UIKit
import AppIntents
import UniformTypeIdentifiers

/// A screenshot waiting for the Send screenshot sheet. It arrives from the share extension (a PNG in the
/// App Group's Inbox, then sidra://screenshot) or from the Shortcuts action below (2026-11-19).
@MainActor @Observable final class ScreenshotInbox {
    static let shared = ScreenshotInbox()
    /// Also in SidraShare/ShareViewController.swift.
    static let group = "group.nl.sadiq.sidra"
    var pending: UIImage?

    private var inbox: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?.appendingPathComponent("Inbox")
    }

    /// The newest image the share extension left (from the last ten minutes); older ones are dropped.
    func collect() {
        guard let inbox, let files = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        if let (url, date) = dated.max(by: { $0.1 < $1.1 }), Date().timeIntervalSince(date) < 600,
           let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            pending = image
        }
        for (url, _) in dated { try? FileManager.default.removeItem(at: url) }
    }
}

/// "Send Screenshot to Sidra" in Shortcuts. Set up once: Take Screenshot, then this action with the
/// screenshot as its input. Without an input it uses the image on the clipboard, for shortcuts that
/// copy the screenshot first.
struct SendScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Screenshot to Sidra"
    static let description = IntentDescription("Opens Sidra on the Send screenshot sheet: pick a session, draw around the part that matters, and send it.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screenshot", supportedContentTypes: [.image])
    var screenshot: IntentFile?

    func perform() async throws -> some IntentResult {
        let data = screenshot?.data ?? UIPasteboard.general.image?.pngData()
        guard let data, let image = UIImage(data: data) else {
            throw AppIntentError.message("No screenshot came with the action, and the clipboard has no image.")
        }
        await MainActor.run { ScreenshotInbox.shared.pending = image }
        return .result()
    }
}

enum AppIntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)
    var localizedStringResource: LocalizedStringResource { switch self { case .message(let m): "\(m)" } }
}

struct SidraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendScreenshotIntent(), phrases: ["Send screenshot to \(.applicationName)", "Screenshot to \(.applicationName)"],
                    shortTitle: "Send Screenshot", systemImageName: "camera.viewfinder")
    }
}
#endif
