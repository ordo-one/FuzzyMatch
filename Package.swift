// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FuzzyMatch",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
        .watchOS(.v10)
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
