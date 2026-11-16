// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidraDesign",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "SidraDesign", targets: ["SidraDesign"])],
    dependencies: [],
    targets: [
        .target(name: "SidraDesign", dependencies: [], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SidraDesignTests", dependencies: ["SidraDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
