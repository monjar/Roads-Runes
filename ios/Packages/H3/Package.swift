// swift-tools-version: 5.9
// Vendored uber/h3 v4.1.0 (Apache 2.0) as a Swift Package C target: the
// upstream repository ships no Package.swift. Public API: include/h3api.h.
import PackageDescription

let package = Package(
    name: "H3",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "H3", targets: ["H3"]),
    ],
    targets: [
        .target(
            name: "H3",
            path: "Sources/H3",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
    ]
)
