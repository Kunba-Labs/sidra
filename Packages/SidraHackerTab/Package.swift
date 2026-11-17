// swift-tools-version: 6.0
import PackageDescription

// HackerTab: a comments-first Hacker News reader as a Sidra pane. Data (Firebase + Algolia),
// on-device thread summaries (Foundation Models), the reader (Readability.js, Apache 2.0) and the views.
// iOS and macOS (WKWebView behind PlatformViewRepresentable); its tests run in the Simulator through the Sidra scheme.
let package = Package(
    name: "SidraHackerTab",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "SidraHackerTab", targets: ["SidraHackerTab"])],
    dependencies: [.package(path: "../SidraDesign")],
    targets: [
        .target(name: "SidraHackerTab", dependencies: ["SidraDesign"], resources: [.copy("Resources/Readability.js")],
                swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("BareSlashRegexLiterals")]),
        .testTarget(name: "SidraHackerTabTests", dependencies: ["SidraHackerTab"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
