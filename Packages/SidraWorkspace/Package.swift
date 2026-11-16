// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidraWorkspace",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "SidraWorkspace", targets: ["SidraWorkspace"])],
    dependencies: [.package(path: "../SidraDesign")],
    targets: [
        .target(name: "SidraWorkspace", dependencies: ["SidraDesign"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SidraWorkspaceTests", dependencies: ["SidraWorkspace"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
