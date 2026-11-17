import SwiftUI
import WebKit
import SidraDesign

/// Reader / web: the lit one is the view you are in, the other takes you there.
struct ArticleControls: View {
    @AppStorage("hackertab.reader") private var reader = true
    @AppStorage("hackertab.textScale") private var scale = 1.0
    var body: some View {
        HStack(spacing: 10) {
            MonoButton(label: "reader", on: reader) { reader = true }
            MonoButton(label: "web", on: !reader) { reader = false }
            if reader {
                Menu {
                    Picker("Text size", selection: $scale) {
                        Text("Small").tag(0.9); Text("Default").tag(1.0); Text("Large").tag(1.15); Text("Larger").tag(1.3)
                    }
                } label: {
                    Text("Aa").font(T.mono(12)).foregroundStyle(T.dim).frame(width: 32, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Text size")
            }
        }
    }
}

struct ArticleView: View {
    let story: Story
    @AppStorage("hackertab.reader") private var reader = true
    @AppStorage("hackertab.textScale") private var scale = 1.0
    @State private var loading = false

    var body: some View {
        WebPane(story: story, reader: reader, scale: scale, loading: $loading)
            .id(story.id)
            .overlay(alignment: .top) {
                if loading { ProgressView().progressViewStyle(.linear).tint(T.accent).accessibilityLabel("Loading article") }
            }
            .background(T.article)
    }
}

/// Two web views on top of each other. `page` loads the article as it is. When it has loaded,
/// Mozilla's Readability extracts the article, and `reader` shows that in the app's style.
/// Switching between reader and web only changes which one is visible, so nothing reloads.
/// When Readability finds no article (a PDF, an app, a video), the page is shown in both modes.
/// ponytail: the reader uses the system font; the app's fonts are not visible to web content.
struct WebPane: PlatformViewRepresentable {
    let story: Story
    let reader: Bool
    let scale: Double
    @Binding var loading: Bool

    /// The last article's web views, kept while the pane is rebuilt (a tab switch): coming back to the
    /// same story shows the loaded page, its reader version and its scroll position, without loading again.
    @MainActor private static var kept: (story: Int, coordinator: Coordinator)?

    func makeCoordinator() -> Coordinator {
        // Reused only while not on screen elsewhere: a second window showing the same story gets its own views.
        if let k = Self.kept, k.story == story.id, k.coordinator.box?.window == nil { k.coordinator.parent = self; return k.coordinator }
        let c = Coordinator(self)
        Self.kept = (story.id, c)
        return c
    }

    #if os(iOS)
    func makeUIView(context: Context) -> UIView { makeBox(context) }
    func updateUIView(_ box: UIView, context: Context) { updateBox(context) }
    #else
    func makeNSView(context: Context) -> NSView { makeBox(context) }
    func updateNSView(_ box: NSView, context: Context) { updateBox(context) }
    #endif

    private func makeBox(_ context: Context) -> PlatformView {
        let c = context.coordinator
        if let box = c.box { return box }
        let box = PlatformView()
        c.box = box
        for w in [c.page, c.reader] {
            w.navigationDelegate = c
            #if os(iOS)
            w.isOpaque = false
            w.backgroundColor = UIColor(T.article)
            w.scrollView.backgroundColor = UIColor(T.article)
            #else
            w.underPageBackgroundColor = NSColor(T.article)
            #endif
            w.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(w)
            NSLayoutConstraint.activate([
                w.topAnchor.constraint(equalTo: box.topAnchor), w.bottomAnchor.constraint(equalTo: box.bottomAnchor),
                w.leadingAnchor.constraint(equalTo: box.leadingAnchor), w.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            ])
        }
        c.start()
        return box
    }

    private func updateBox(_ context: Context) {
        let c = context.coordinator
        c.parent = self
        c.show()
        c.reader.evaluateJavaScript("document.documentElement.style.setProperty('--s','\(scale)')")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebPane
        var box: PlatformView?
        let page = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let reader = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        /// pending: the page or the reader is still loading. found: the reader shows the page's article.
        enum Extract { case pending, found, none }
        var extract = Extract.pending
        /// Counts page navigations, so a Readability result or reader load meant for an earlier page is dropped.
        var gen = 0, readerGen = -1
        init(_ parent: WebPane) { self.parent = parent }

        static let readability = Bundle.module.url(forResource: "Readability", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        struct Article: Decodable { let t: String?; let b: String?; let c: String }

        func setLoading(_ on: Bool) { DispatchQueue.main.async { self.parent.loading = on } }

        func start() {
            let s = parent.story
            guard let url = s.url else {
                // A text post (Ask HN and the like): the post itself is the article, in both modes.
                // It counts as found when the reader has loaded it.
                readerGen = gen
                reader.loadHTMLString(html(title: s.title, byline: "\(s.by) · \(s.age)", content: s.text ?? ""), baseURL: nil)
                page.loadHTMLString(html(title: s.title, byline: "\(s.by) · \(s.age)", content: s.text ?? ""), baseURL: nil)
                show()
                return
            }
            setLoading(true)
            page.load(URLRequest(url: url))
            show()
        }

        /// Reader mode shows the reader once it is ready; until then nothing, behind the loading bar.
        func show() {
            let wantReader = parent.reader && extract != .none
            reader.isHidden = !wantReader || extract != .found
            page.isHidden = wantReader
        }

        /// Each new page in the page view (a link followed in web mode, say) needs its own reader version.
        func webView(_ w: WKWebView, didCommit navigation: WKNavigation!) {
            guard w === page, parent.story.url != nil else { return }
            gen += 1
            extract = .pending
            setLoading(true)
            show()
        }

        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            if w === reader {
                // The reader is shown, and loading ends, only when its page has loaded, for the current page.
                guard readerGen == gen, extract == .pending else { return }
                extract = .found
                setLoading(false)
                show()
                return
            }
            guard extract == .pending, parent.story.url != nil else { return }
            let js = Self.readability + ";(function(){try{var a=new Readability(document.cloneNode(true)).parse();return a&&a.content&&a.textContent.length>400?JSON.stringify({t:a.title,b:a.byline,c:a.content}):null}catch(e){return null}})()"
            let base = page.url, g = gen
            page.evaluateJavaScript(js) { result, _ in
                guard g == self.gen else { return }
                if let json = result as? String, let x = try? JSONDecoder().decode(Article.self, from: Data(json.utf8)) {
                    self.readerGen = g
                    self.reader.loadHTMLString(self.html(title: x.t ?? self.parent.story.title, byline: x.b ?? "", content: x.c), baseURL: base)
                } else {
                    self.extract = .none
                    self.setLoading(false)
                    self.show()
                }
            }
        }

        func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(w, error) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(w, error) }
        private func failed(_ w: WKWebView, _ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            if w === reader {
                // No reader version: show the original page.
                extract = .none
                setLoading(false)
                show()
                return
            }
            setLoading(false)
            extract = .none
            page.loadHTMLString(html(title: "Could not load the page", byline: parent.story.url?.absoluteString ?? "", content: "<p>\(esc(error.localizedDescription))</p>"), baseURL: nil)
            show()
        }

        func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard w === reader, action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            // The link at the top of the reader goes to the original page.
            if url.scheme == "h4xor" {
                UserDefaults.standard.set(false, forKey: "hackertab.reader")
                return .cancel
            }
            // Other links leave the app; the reader stays on its article.
            await Platform.open(url)
            return .cancel
        }

        private func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        }

        private func html(title: String, byline: String, content: String) -> String {
            """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>
            :root{--s:\(parent.scale);color-scheme:dark}
            body{margin:0;padding:20px 40px 80px;background:#121417;color:#d9d6ce;font:calc(17px*var(--s))/1.6 -apple-system,system-ui,sans-serif;-webkit-text-size-adjust:none;overflow-wrap:break-word}
            main{max-width:700px;margin:0 auto}
            .mode{display:flex;justify-content:space-between;gap:12px;margin:0 0 18px;padding:8px 12px;border:1px solid #272b30;border-radius:6px;font:12px ui-monospace,Menlo,monospace;color:#9b978d}
            .mode a{text-decoration:none}
            h1{font-size:1.55em;line-height:1.18;letter-spacing:-.015em;margin:0;color:#e7e4dc}
            .by{font:11.5px ui-monospace,Menlo,monospace;color:#9b978d;margin:10px 0 20px}
            h2,h3,h4{color:#e7e4dc;line-height:1.3}h2{font-size:1.15em}h3,h4{font-size:1em}
            a{color:#ff8a3d}
            img,video,svg,iframe{max-width:100%;height:auto;border-radius:6px}
            img,video{display:block;margin:1em auto;width:auto;max-width:min(100%,560px);max-height:60vh;object-fit:contain}
            li img{display:inline-block;margin:0 .2em;vertical-align:middle;max-height:2em}
            pre,code{font:.8em/1.6 ui-monospace,Menlo,monospace}
            pre{background:#0b0d0e;border:1px solid #272b30;border-radius:6px;padding:12px 14px;overflow-x:auto}
            blockquote{margin:1em 0;padding-left:14px;border-left:2px solid #ff8a3d;color:#c9c6be}
            table{display:block;overflow-x:auto;border-collapse:collapse}td,th{border:1px solid #272b30;padding:4px 8px}
            figure{margin:1em 0}figcaption{font-size:.8em;color:#9b978d}
            @media(max-width:600px){body{padding:16px 20px 80px}}
            </style></head><body><main>\(parent.story.url == nil ? "" : "<div class=\"mode\"><span>reader view</span><a href=\"h4xor://web\">show original page ›</a></div>")<h1>\(esc(title))</h1><div class="by">\(esc(byline))</div>\(content)</main></body></html>
            """
        }
    }
}
