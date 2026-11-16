import SwiftUI
import UIKit
import SidraWorkspace

/// Resolves the hosting scene's session id, then shows RootView with that scene's WorkspaceStore.
/// Whenever this scene becomes active, its store becomes `app.workspace` so menu commands, Quick
/// Open and project switches act on the window the user is in.
struct SceneRoot: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: WorkspaceStore?

    var body: some View {
        if let store {
            RootView()
                .environment(store)
                .onAppear { app.workspace = store }
                .onChange(of: scenePhase) { _, phase in 
                    if phase == .active { app.workspace = store; DataLayout.apply(); BusyPanes.shared.endGrace() }
                    if phase == .background { BusyPanes.shared.beginGrace() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .sidraNotificationRoute)) { _ in consumeRoute() }
                .task { consumeRoute() }
        } else {
            SceneProbe { id in store = app.workspace(forScene: id) }
                .background(SidraBackground())
        }
    }
}

private extension SceneRoot {
    func consumeRoute() { if let r = Notifier.pending { Notifier.pending = nil; app.open(r) } }
}

private struct SidraBackground: View {
    var body: some View { Color(red: 0x0c / 255, green: 0x0e / 255, blue: 0x12 / 255).ignoresSafeArea() }
}

/// Reads `window.windowScene.session.persistentIdentifier` once the view is in a window.
private struct SceneProbe: UIViewRepresentable {
    let resolved: (String) -> Void
    func makeUIView(context: Context) -> ProbeView { let v = ProbeView(); v.resolved = resolved; return v }
    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var resolved: ((String) -> Void)?
        private var done = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !done, let id = window?.windowScene?.session.persistentIdentifier else { return }
            done = true
            let cb = resolved
            DispatchQueue.main.async { cb?(id) }
        }
    }
}
