import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import SidraDesign
import SidraWorkspace

@main
struct SidraApp: App {
    @State private var app = AppModel()

    init() {
        Notifier.start()
        #if DEBUG
        DemoMode.registerProtocol()
        #endif
        DataLayout.apply()
        #if os(macOS)
        _ = AppUpdater.controller   // starts the scheduled update checks
        #endif
        // -sidra.forceCrash, -sidra.killAfter N (tests): a real crash and a real SIGKILL.
        if CommandLine.arguments.contains("-sidra.forceCrash") { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { fatalError("sidra.forceCrash") } }
        let killAfter = UserDefaults.standard.double(forKey: "sidra.killAfter")
        if killAfter > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + killAfter) { kill(getpid(), SIGKILL) } }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            SceneRoot()
                .environment(app)
        }
        #if os(macOS)
        .defaultSize(width: 1440, height: 920)
        .windowStyle(.hiddenTitleBar)   // Sidra's tab bar is the title bar; the traffic lights sit in it (WindowChrome)
        #endif
        .commands {
            WorkspaceCommands(app: app)
            #if os(macOS)
            UpdateCommands()
            #endif
        }
    }
}
