// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "bench-contains",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "bench-contains",
            dependencies: [
                .product(name: "HeapModule", package: "swift-collections"),
            ],
            path: "Sources"
        ),
    ]
)
