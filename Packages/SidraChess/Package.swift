// swift-tools-version: 6.0
import PackageDescription

// Chess against Sidra's own engine (F20). Rules, SAN and FEN come from chesskit-swift (MIT);
// the engine is ours (Engine.swift). Resources/openings.tsv is the Lichess opening book
// (github.com/lichess-org/chess-openings, CC0), copied from checkerspromax.
let package = Package(
    name: "SidraChess",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [.library(name: "SidraChess", targets: ["SidraChess"])],
    dependencies: [
        .package(path: "../SidraDesign"),
        .package(url: "https://github.com/chesskit-app/chesskit-swift", .upToNextMinor(from: "0.17.0")),
    ],
    targets: [
        // Engine, book and the store: no UI, so `swift test` runs it on the Mac.
        .target(name: "SidraChessCore",
                dependencies: [.product(name: "ChessKit", package: "chesskit-swift")],
                resources: [.copy("Resources/openings.tsv")],
                // ponytail: the engine is optimised even in Debug, else a Simulator build plays 20x weaker than a release one.
                swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-O"])]),
        .target(name: "SidraChess", dependencies: ["SidraChessCore", "SidraDesign", .product(name: "ChessKit", package: "chesskit-swift")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SidraChessTests", dependencies: ["SidraChessCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
