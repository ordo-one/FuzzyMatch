// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FuzzyMatch",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .visionOS(.v26),
        .watchOS(.v26)
    ],
    products: [
        .library(
            name: "FuzzyMatch",
            targets: ["FuzzyMatch"]
        )
    ],
    targets: [
        .target(
            name: "FuzzyMatch",
            path: "Sources/FuzzyMatch"
        ),
        .testTarget(
            name: "FuzzyMatchTests",
            dependencies: ["FuzzyMatch"],
            path: "Tests/FuzzyMatchTests"
        )
    ]
)
