import UIKit
import UniformTypeIdentifiers
import os

/// "Sidra" in the Share sheet: keeps the shared image in the App Group's Inbox, then opens Sidra on the Send
/// screenshot sheet with sidra://screenshot. If iPadOS does not let the extension open the app, the image
/// still waits in the Inbox and Sidra shows it the next time it comes to the front.
final class ShareViewController: UIViewController {
    /// Also in Sidra/Screenshot/ScreenshotInbox.swift.
    static let group = "group.nl.sadiq.sidra"

    private var started = false
    private let log = Logger(subsystem: "nl.sadiq.sidra.share", category: "share")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        note("loaded, \((extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }.map(\.registeredTypeIdentifiers))")
    }

    /// Each step goes to the unified log and to share.log in the App Group (the last 200 lines), so a failed
    /// share can be read back from the device: Share needed two or three taps (2026-11-20).
    private func note(_ s: String) {
        log.info("\(s, privacy: .public)")
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?.appendingPathComponent("share.log") else { return }
        let old = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").suffix(199).joined(separator: "\n") ?? ""
        try? (old + "\n" + Date().ISO8601Format(.iso8601.time(includingFractionalSeconds: true)) + " " + s).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Starts once the view is on screen: before that the responder chain does not reach the application,
    /// and opening Sidra did nothing, so Share needed a second or third tap (2026-11-20).
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        // Never left hanging, but long enough for a large image's save plus a refused first open (3 s cut
        // those off, so Share sometimes still needed another tap, 2026-11-20).
        note("appeared")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.note("gave up after 8 s"); self?.finish() }
        Task { @MainActor in
            let t = Date()
            let since = { String(format: "%.2f s", Date().timeIntervalSince(t)) }
            // The screenshot editor may still be rendering the marked-up image when Share is tapped, and then hands
            // over nothing: ask again for up to 3 s instead of closing (2026-11-20).
            var saved = false
            for attempt in 1...10 where !saved {
                saved = await save()
                if !saved { note("no image yet (attempt \(attempt), \(since()))"); try? await Task.sleep(for: .milliseconds(300)) }
            }
            guard saved else { note("no image, closing"); return finish() }
            note("saved after \(since())")
            let opened = await open(URL(string: "sidra://screenshot")!)
            note("open \(opened ? "succeeded" : "failed") after \(since())")
            finish()
        }
    }

    private var finished = false
    private func finish() {
        guard !finished else { return }
        finished = true
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func save() async -> Bool {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }),
              let png = await Self.png(from: provider),
              let inbox = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?.appendingPathComponent("Inbox")
        else { return false }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return (try? png.write(to: inbox.appendingPathComponent(UUID().uuidString + ".png"))) != nil
    }

    /// The screenshot editor hands over a UIImage, Photos and Files a file URL, others raw data.
    private static func png(from provider: NSItemProvider) async -> Data? {
        let item: NSSecureCoding? = await withCheckedContinuation { done in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in done.resume(returning: item) }
        }
        switch item {
        case let image as UIImage: return image.pngData()
        case let url as URL: return (try? Data(contentsOf: url)).flatMap { UIImage(data: $0)?.pngData() }
        case let data as Data: return UIImage(data: data)?.pngData()
        default:
            // Some hosts only answer the data representation.
            return await withCheckedContinuation { done in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    done.resume(returning: data.flatMap { UIImage(data: $0)?.pngData() })
                }
            }
        }
    }

    /// A share extension may not call UIApplication.open, so it is called by selector on the application
    /// found up the responder chain.
    // Unofficial (Waseem chose auto-open over switching by hand, 2026-11-19): iPadOS has no API for this. If a
    // later iPadOS closes it, the image still waits in the Inbox for Sidra's next activation.
    /// Returns once iPadOS opens Sidra (the extension closes only then). Tries again for about 2 s while the
    /// application is not on the responder chain yet or iPadOS refuses the open (it ignored the answer before).
    private func open(_ url: URL) async -> Bool {
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        for attempt in 0..<12 {
            var r: UIResponder? = self
            while let next = r, !(next.responds(to: sel) && next.isKind(of: NSClassFromString("UIApplication")!)) { r = next.next }
            if let app = r {
                typealias Open = @convention(c) (AnyObject, Selector, URL, NSDictionary, AnyObject?) -> Void
                let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                    let completion: @convention(block) (Bool) -> Void = { done.resume(returning: $0) }
                    unsafeBitCast(app.method(for: sel), to: Open.self)(app, sel, url, [:], completion as AnyObject)
                }
                if ok { return true }
                note("open refused (attempt \(attempt + 1))")
            } else {
                note("no application on the responder chain (attempt \(attempt + 1))")
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }
}
