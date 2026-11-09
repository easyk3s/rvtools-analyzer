// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RVToolsAnalyzer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RVToolsAnalyzer", targets: ["RVToolsAnalyzer"]),
        .executable(name: "rvtools-cli", targets: ["rvtools-cli"]),
        .executable(name: "rvtools-decks-server", targets: ["rvtools-decks-server"]),
    ],
    targets: [
        // Parsing (xlsx / csv), correlation engine, rollups and findings. No UI, no dependencies.
        .target(name: "RVToolsCore"),
        // The SwiftUI dashboard app.
        .executableTarget(name: "RVToolsAnalyzer", dependencies: ["RVToolsCore"]),
        .testTarget(name: "RVToolsCoreTests", dependencies: ["RVToolsCore"]),
        // Headless runner: prints the same analysis to the terminal (handy for testing / scripting).
        .executableTarget(name: "rvtools-cli", dependencies: ["RVToolsCore"]),
        // A small web page, served from this Mac, where people upload an RVTools export and get a recipe's decks back as a .zip.
        .executableTarget(name: "rvtools-decks-server", dependencies: ["RVToolsCore"]),
    ]
)
