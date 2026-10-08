// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RoadsAndRunesCore",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RoadsAndRunesCore", targets: ["RoadsAndRunesCore"]),
        // Faces drawn in code (docs/ROADMAP.md, 0.6.0): runes, crests, creature
        // sigils, chests, coins and frames. Shared by the app and the Watch.
        .library(name: "RoadsAndRunesArt", targets: ["RoadsAndRunesArt"]),
    ],
    targets: [
        .target(
            name: "RoadsAndRunesCore",
            path: "Sources/RoadsAndRunesCore"
        ),
        .target(
            name: "RoadsAndRunesArt",
            path: "Sources/RoadsAndRunesArt"
        ),
        .testTarget(
            name: "RoadsAndRunesCoreTests",
            dependencies: ["RoadsAndRunesCore"],
            path: "Tests/RoadsAndRunesCoreTests",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "RoadsAndRunesArtTests",
            dependencies: ["RoadsAndRunesArt"],
            path: "Tests/RoadsAndRunesArtTests"
        ),
    ]
)
