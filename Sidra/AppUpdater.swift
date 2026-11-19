#if os(macOS)
import Sparkle
import SwiftUI

/// Mac updates from GitHub releases (.github/workflows/release-mac.yml). The Info.plist carries `SUFeedURL`
/// and the public half of the EdDSA key that signs each release; Sparkle refuses anything else.
/// Only a copy under /Applications updates itself, so Xcode runs from DerivedData never do.
@MainActor enum AppUpdater {
    static let controller: SPUStandardUpdaterController? =
        Bundle.main.bundlePath.contains("/Applications/")
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
}

struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { AppUpdater.controller?.checkForUpdates(nil) }
                .disabled(AppUpdater.controller == nil)
        }
    }
}
#endif
