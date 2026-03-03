// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Benchmarks",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .visionOS(.v2)
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/ordo-one/package-benchmark.git", from: "1.0.0")
    ],
    targets: [
        .executableTarget(
            name: "FuzzyMatchBenchmark",
            dependencies: [
                .product(name: "FuzzyMatch", package: "FuzzyMatch"),
                .product(name: "Benchmark", package: "package-benchmark")
            ],
            path: "Benchmarks/FuzzyMatchBenchmark",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        ),
        .executableTarget(
            name: "CorpusBenchmark",
            dependencies: [
                .product(name: "FuzzyMatch", package: "FuzzyMatch"),
                .product(name: "Benchmark", package: "package-benchmark")
            ],
            path: "Benchmarks/CorpusBenchmark",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
            ]
        )
    ]
)
