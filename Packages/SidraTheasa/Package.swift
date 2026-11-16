// swift-tools-version: 6.0
import PackageDescription

// Theasa client: response models, the HTTP + SSE client and the formatting the web UI uses.
// Foundation only, so `swift test` runs it on the Mac; the views live in the app target.
let package = Package(
    name: "SidraTheasa",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "SidraTheasa", targets: ["SidraTheasa"])],
    targets: [
        .target(name: "SidraTheasa", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SidraTheasaTests", dependencies: ["SidraTheasa"], resources: [.copy("Fixtures")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
