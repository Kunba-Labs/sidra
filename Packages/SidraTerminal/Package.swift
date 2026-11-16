// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidraTerminal",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "SidraTerminal", targets: ["SidraTerminal"])],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3"), .package(path: "../SidraDesign")],
    targets: [
        .binaryTarget(name: "GhosttyVt", path: "Vendor/ghostty-vt.xcframework"),
        .target(name: "SidraTerminal", dependencies: ["SidraDesign", "GhosttyVt", .product(name: "SwiftTerm", package: "SwiftTerm")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SidraTerminalTests", dependencies: ["SidraTerminal"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
