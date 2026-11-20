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
    }

    /// Starts once the view is on screen: before that the responder chain does not reach the application,
    /// and opening Sidra did nothing, so Share needed a second or third tap (2026-11-20).
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        // Never left hanging, but long enough for a large image's save plus a refused first open (3 s cut
        // those off, so Share sometimes still needed another tap, 2026-11-20).
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.log.error("gave up after 6 s"); self?.finish() }
        Task { @MainActor in
            let t = Date()
            guard await save() else { log.error("no image saved"); return finish() }
            log.info("saved in \(Date().timeIntervalSince(t), format: .fixed(precision: 2)) s")
            let opened = await open(URL(string: "sidra://screenshot")!)
            log.info("open \(opened ? "succeeded" : "failed") after \(Date().timeIntervalSince(t), format: .fixed(precision: 2)) s")
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
        await withCheckedContinuation { done in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                switch item {
                case let image as UIImage: done.resume(returning: image.pngData())
                case let url as URL: done.resume(returning: (try? Data(contentsOf: url)).flatMap { UIImage(data: $0)?.pngData() })
                case let data as Data: done.resume(returning: UIImage(data: data)?.pngData())
                default: done.resume(returning: nil)
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
                log.info("open refused (attempt \(attempt + 1))")
            } else {
                log.info("no application on the responder chain (attempt \(attempt + 1))")
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }
}
