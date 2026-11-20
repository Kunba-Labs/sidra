import UIKit
import UniformTypeIdentifiers

/// "Sidra" in the Share sheet: keeps the shared image in the App Group's Inbox, then opens Sidra on the Send
/// screenshot sheet with sidra://screenshot. If iPadOS does not let the extension open the app, the image
/// still waits in the Inbox and Sidra shows it the next time it comes to the front.
final class ShareViewController: UIViewController {
    /// Also in Sidra/Screenshot/ScreenshotInbox.swift.
    static let group = "group.nl.sadiq.sidra"

    private var started = false

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish() }   // never left hanging
        Task { @MainActor in
            guard await save() else { return finish() }
            await open(URL(string: "sidra://screenshot")!)
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
    /// Returns once iPadOS answers the open (the extension closes only then), trying again a few times if
    /// the application is not on the responder chain yet.
    private func open(_ url: URL) async {
        let sel = NSSelectorFromString("openURL:options:completionHandler:")
        for _ in 0..<5 {
            var r: UIResponder? = self
            while let next = r {
                if next.responds(to: sel), next.isKind(of: NSClassFromString("UIApplication")!) {
                    typealias Open = @convention(c) (AnyObject, Selector, URL, NSDictionary, AnyObject?) -> Void
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let completion: @convention(block) (Bool) -> Void = { _ in done.resume() }
                        unsafeBitCast(next.method(for: sel), to: Open.self)(next, sel, url, [:], completion as AnyObject)
                    }
                    return
                }
                r = next.next
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}
