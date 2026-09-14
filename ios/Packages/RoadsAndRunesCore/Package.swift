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
    ],
    targets: [
        .target(
            name: "RoadsAndRunesCore",
            path: "Sources/RoadsAndRunesCore"
        ),
        .testTarget(
            name: "RoadsAndRunesCoreTests",
            dependencies: ["RoadsAndRunesCore"],
            path: "Tests/RoadsAndRunesCoreTests",
            resources: [.copy("Resources")]
        ),
    ]
)
