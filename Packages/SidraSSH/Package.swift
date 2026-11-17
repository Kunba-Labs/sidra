// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SidraSSH",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "SidraSSH", targets: ["SidraSSH"])],
    dependencies: [.package(url: "https://github.com/orlandos-nl/Citadel", exact: "0.12.1"), .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"), .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"), .package(path: "../SidraTerminal/Vendor/swift-mosh"), .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.3")],
    targets: [
        .target(name: "SidraSSH", dependencies: [.product(name: "Citadel", package: "Citadel"), .product(name: "Crypto", package: "swift-crypto"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "MoshCore", package: "swift-mosh"), .product(name: "MoshBootstrap", package: "swift-mosh"),
                // This Mac's own shell (LocalShell.swift) runs on SwiftTerm's forkpty LocalProcess.
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS]))], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SidraSSHTests", dependencies: ["SidraSSH"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
