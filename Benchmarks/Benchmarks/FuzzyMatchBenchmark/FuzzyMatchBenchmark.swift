// ===----------------------------------------------------------------------===//
//
// This source file is part of the FuzzyMatch open source project
//
// Copyright (c) 2026 Ordo One, AB. and the FuzzyMatch project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
// ===----------------------------------------------------------------------===//

import Benchmark
import FuzzyMatch
import Synchronization

// MARK: - Dataset Generation

/// Deterministic random number generator for reproducible benchmarks
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // xorshift64* algorithm
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }
}

/// Word components for generating realistic code identifiers
private let prefixes = [
    "get", "set", "is", "has", "can", "should", "will", "did", "do",
    "make", "create", "build", "parse", "load", "save", "fetch", "send",
    "update", "delete", "remove", "add", "insert", "find", "search",
    "validate", "check", "verify", "process", "handle", "compute",
    "calculate", "convert", "transform", "format", "render", "display"
]

private let nouns = [
    "user", "data", "item", "list", "array", "string", "value", "result",
    "response", "request", "config", "option", "setting", "param", "arg",
    "file", "path", "name", "id", "key", "index", "count", "size", "length",
    "buffer", "cache", "queue", "stack", "map", "set", "tree", "node",
    "json", "xml", "html", "url", "api", "db", "sql", "http", "tcp",
    "error", "status", "state", "event", "action", "message", "token"
]

private let suffixes = [
    "by", "with", "from", "to", "for", "at", "in", "on", "of",
    "async", "sync", "all", "one", "many", "first", "last",
    "id", "name", "type", "value", "count", "index", "key"
]

/// Generates a camelCase identifier
private func generateCamelCase(rng: inout SeededRandomNumberGenerator) -> String {
    let wordCount = Int(rng.next() % 4) + 2  // 2-5 words
    var result = ""

    // First word (lowercase)
    let prefixIdx = Int(rng.next() % UInt64(prefixes.count))
    result += prefixes[prefixIdx]

    // Middle words (capitalized)
    for i in 1..<wordCount {
        let word: String
        if i == wordCount - 1 && rng.next().isMultiple(of: 3) {
            let suffixIdx = Int(rng.next() % UInt64(suffixes.count))
            word = suffixes[suffixIdx]
        } else {
            let nounIdx = Int(rng.next() % UInt64(nouns.count))
            word = nouns[nounIdx]
        }
        // Capitalize first letter
        result += word.prefix(1).uppercased() + word.dropFirst()
    }

    return result
}

/// Generates a snake_case identifier
private func generateSnakeCase(rng: inout SeededRandomNumberGenerator) -> String {
    let wordCount = Int(rng.next() % 4) + 2  // 2-5 words
    var parts: [String] = []

    // First word
    let prefixIdx = Int(rng.next() % UInt64(prefixes.count))
    parts.append(prefixes[prefixIdx])

    // Middle words
    for i in 1..<wordCount {
        if i == wordCount - 1 && rng.next().isMultiple(of: 3) {
            let suffixIdx = Int(rng.next() % UInt64(suffixes.count))
            parts.append(suffixes[suffixIdx])
        } else {
            let nounIdx = Int(rng.next() % UInt64(nouns.count))
            parts.append(nouns[nounIdx])
        }
    }

    return parts.joined(separator: "_")
}

/// Generates a dataset of synthetic code identifiers
private func generateDataset(count: Int, seed: UInt64 = 12_345) -> [String] {
    var rng = SeededRandomNumberGenerator(seed: seed)
    var dataset: [String] = []
    dataset.reserveCapacity(count)

    for i in 0..<count {
        // 50% camelCase, 50% snake_case
        let identifier: String
        if i.isMultiple(of: 2) {
            identifier = generateCamelCase(rng: &rng)
        } else {
            identifier = generateSnakeCase(rng: &rng)
        }
        dataset.append(identifier)
    }

    return dataset
}

/// Dictionary for generating long text strings
private let documentWords = [
    // Common words
    "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
    "have", "has", "had", "do", "does", "did", "will", "would", "could", "should",
    "may", "might", "must", "shall", "can", "need", "dare", "ought", "used", "to",
    "and", "but", "or", "nor", "for", "yet", "so", "either", "neither", "not",
    "only", "own", "same", "than", "too", "very", "just", "also", "now", "here",
    // Technical terms
    "user", "data", "system", "file", "process", "thread", "memory", "buffer",
    "cache", "queue", "stack", "array", "list", "map", "set", "tree", "graph",
    "node", "edge", "path", "route", "request", "response", "server", "client",
    "database", "table", "column", "row", "index", "key", "value", "query",
    "function", "method", "class", "object", "instance", "variable", "constant",
    "parameter", "argument", "return", "void", "null", "undefined", "error",
    "exception", "handler", "callback", "promise", "async", "await", "sync",
    "config", "configuration", "setting", "option", "preference", "default",
    "input", "output", "stream", "reader", "writer", "parser", "formatter",
    "encoder", "decoder", "serializer", "deserializer", "validator", "checker",
    // Domain words
    "underlying", "isin", "security", "portfolio", "position", "trade", "order",
    "price", "quantity", "amount", "total", "balance", "account", "customer",
    "transaction", "payment", "transfer", "deposit", "withdrawal", "statement"
]

/// Generates a long string of approximately the specified byte size from the dictionary
private func generateLongString(approximateBytes: Int, seed: UInt64) -> String {
    var rng = SeededRandomNumberGenerator(seed: seed)
    var result = ""
    result.reserveCapacity(approximateBytes + 100)

    while result.utf8.count < approximateBytes {
        let wordIndex = Int(rng.next() % UInt64(documentWords.count))
        let word = documentWords[wordIndex]

        // Occasionally capitalize for variety
        if rng.next().isMultiple(of: 10) {
            result += word.prefix(1).uppercased() + word.dropFirst()
        } else {
            result += word
        }

        // Add separator (space, newline, or punctuation)
        let separator = rng.next() % 20
        switch separator {
        case 0:
            result += "\n"
        case 1:
            result += ". "
        case 2:
            result += ", "
        default:
            result += " "
        }
    }

    return result
}

/// Generates a dataset of long strings
private func generateLongStringDataset(count: Int, bytesPerString: Int, seed: UInt64 = 54_321) -> [String] {
    var dataset: [String] = []
    dataset.reserveCapacity(count)

    for i in 0..<count {
        let stringSeed = seed &+ UInt64(i)
        dataset.append(generateLongString(approximateBytes: bytesPerString, seed: stringSeed))
    }

    return dataset
}

// MARK: - Dataset Storage

/// Thread-safe dataset holder that generates datasets lazily
final class DatasetHolder: Sendable {
    private struct State {
        var fullDataset: [String]?
        var smallDataset: [String]?
        var longStrings32KB: [String]?
        var longStrings64KB: [String]?
    }

    private let state = Mutex(State())

    static let shared = DatasetHolder()

    private init() {}

    var fullDataset: [String] {
        state.withLock { state in
            if state.fullDataset == nil {
                state.fullDataset = generateDataset(count: 1_000_000)
            }
            return state.fullDataset!
        }
    }

    var smallDataset: [String] {
        state.withLock { state in
            if state.smallDataset == nil {
                if let full = state.fullDataset {
                    state.smallDataset = Array(full.prefix(10_000))
                } else {
                    state.smallDataset = generateDataset(count: 10_000)
                }
            }
            return state.smallDataset!
        }
    }

    /// 20 strings of ~32KB each (for benchmarking long text search)
    var longStrings32KB: [String] {
        state.withLock { state in
            if state.longStrings32KB == nil {
                state.longStrings32KB = generateLongStringDataset(count: 20, bytesPerString: 32 * 1_024)
            }
            return state.longStrings32KB!
        }
    }

    /// 10 strings of ~64KB each (for benchmarking very long text search)
    var longStrings64KB: [String] {
        state.withLock { state in
            if state.longStrings64KB == nil {
                state.longStrings64KB = generateLongStringDataset(count: 10, bytesPerString: 64 * 1_024)
            }
            return state.longStrings64KB!
        }
    }
}

// MARK: - Test Queries

/// Realistic queries of varying lengths
private let realisticQueries5Char = ["getUs", "setDa", "loadF", "saveD", "pars"]
private let realisticQueries10Char = ["getUserByI", "parseJsonR", "loadFromCa", "saveToFile", "validateUs"]

// MARK: - Helper Functions

/// Runs concurrent scoring using Swift TaskGroup
private func runConcurrentScoring(
    dataset: [String],
    matcher: FuzzyMatcher,
    query: FuzzyQuery,
    workerCount: Int,
    chunkSize: Int
) async -> Int {
    await withTaskGroup(of: Int.self, returning: Int.self) { group in
        for workerIndex in 0..<workerCount {
            group.addTask {
                var buffer = matcher.makeBuffer()
                var localMatches = 0

                let startIndex = workerIndex * chunkSize
                let endIndex = workerIndex == workerCount - 1
                    ? dataset.count
                    : startIndex + chunkSize

                for i in startIndex..<endIndex {
                    if matcher.score(dataset[i], against: query, buffer: &buffer) != nil {
                        localMatches += 1
                    }
                }

                return localMatches
            }
        }

        var total = 0
        for await count in group {
            total += count
        }
        return total
    }
}

// MARK: - Benchmark Suite

let benchmarks: @Sendable () -> Void = {
    // MARK: - Shared Configuration

    let metrics: [BenchmarkMetric] = [
        .instructions, .mallocCountTotal, .objectAllocCount, .retainCount, .releaseCount
    ]

    let configMega = Benchmark.Configuration(
        metrics: metrics, warmupIterations: 1, scalingFactor: .mega
    )

    let configKilo = Benchmark.Configuration(
        metrics: metrics, warmupIterations: 1, scalingFactor: .kilo
    )

    let configOne = Benchmark.Configuration(
        metrics: metrics, warmupIterations: 1, scalingFactor: .one
    )

    let concurrentThreshold: BenchmarkThresholds = .init(relative: [.p25: 15.0, .p50: 15.0, .p75: 15.0])
    let configOneConcurrent = Benchmark.Configuration(
        metrics: metrics, warmupIterations: 1, scalingFactor: .one,
        thresholds: [
            .instructions: concurrentThreshold,
            .mallocCountTotal: concurrentThreshold,
            .objectAllocCount: concurrentThreshold,
            .retainCount: concurrentThreshold,
            .releaseCount: concurrentThreshold
        ]
    )

    // MARK: - Query Preparation Benchmark

    Benchmark(
        "Query preparation throughput",
        configuration: configMega
    ) { benchmark in
        let matcher = FuzzyMatcher()
        let testQueries = realisticQueries5Char + realisticQueries10Char

        for _ in benchmark.scaledIterations {
            for query in testQueries {
                blackHole(matcher.prepare(query))
            }
        }
    }

    // MARK: - Prefilter-Only Benchmarks

    Benchmark(
        "Prefilter rejection (best case - no matches)",
        configuration: configKilo
    ) { benchmark in
        let smallDataset = DatasetHolder.shared.smallDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("xyzqw")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in smallDataset {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    Benchmark(
        "Prefilter pass-through (worst case - many potential matches)",
        configuration: configKilo
    ) { benchmark in
        let smallDataset = DatasetHolder.shared.smallDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("get")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in smallDataset {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    // MARK: - Full Scoring Benchmarks (Single-threaded)

    Benchmark(
        "Full scoring - 1 char query",
        configuration: configKilo
    ) { benchmark in
        let smallDataset = DatasetHolder.shared.smallDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("g")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in smallDataset {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    Benchmark(
        "Full scoring - 3 char query",
        configuration: configKilo
    ) { benchmark in
        let smallDataset = DatasetHolder.shared.smallDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("usr")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in smallDataset {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    Benchmark(
        "Full scoring - 5 char query",
        configuration: configKilo
    ) { benchmark in
        let smallDataset = DatasetHolder.shared.smallDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("getUs")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in smallDataset {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    Benchmark(
        "Full scoring - 10 char query",
        configuration: configKilo
    ) { benchmark in
        let smallDataset = DatasetHolder.shared.smallDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("getUserByI")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in smallDataset {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    // MARK: - Full Dataset Single-threaded Benchmark

    Benchmark(
        "Full dataset scoring (1M candidates, single-threaded)",
        configuration: configOne
    ) { benchmark in
        let fullDataset = DatasetHolder.shared.fullDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("getUserById")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            var matchCount = 0
            for candidate in fullDataset {
                if matcher.score(candidate, against: query, buffer: &buffer) != nil {
                    matchCount += 1
                }
            }
            blackHole(matchCount)
        }
    }

    // MARK: - Concurrent Benchmarks

    Benchmark(
        "Concurrent scoring (4 workers, 1M candidates)",
        configuration: configOneConcurrent
    ) { benchmark in
        let fullDataset = DatasetHolder.shared.fullDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("getUserById")
        let workerCount = 4
        let chunkSize = fullDataset.count / workerCount

        for _ in benchmark.scaledIterations {
            let totalMatches = await runConcurrentScoring(
                dataset: fullDataset,
                matcher: matcher,
                query: query,
                workerCount: workerCount,
                chunkSize: chunkSize
            )
            blackHole(totalMatches)
        }
    }

    Benchmark(
        "Concurrent scoring (8 workers, 1M candidates)",
        configuration: configOneConcurrent
    ) { benchmark in
        let fullDataset = DatasetHolder.shared.fullDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("getUserById")
        let workerCount = 8
        let chunkSize = fullDataset.count / workerCount

        for _ in benchmark.scaledIterations {
            let totalMatches = await runConcurrentScoring(
                dataset: fullDataset,
                matcher: matcher,
                query: query,
                workerCount: workerCount,
                chunkSize: chunkSize
            )
            blackHole(totalMatches)
        }
    }

    Benchmark(
        "Concurrent scoring (16 workers, 1M candidates)",
        configuration: configOneConcurrent
    ) { benchmark in
        let fullDataset = DatasetHolder.shared.fullDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("getUserById")
        let workerCount = 16
        let chunkSize = fullDataset.count / workerCount

        for _ in benchmark.scaledIterations {
            let totalMatches = await runConcurrentScoring(
                dataset: fullDataset,
                matcher: matcher,
                query: query,
                workerCount: workerCount,
                chunkSize: chunkSize
            )
            blackHole(totalMatches)
        }
    }

    // MARK: - Best vs Worst Case Comparison

    Benchmark(
        "Best case - early rejection (uncommon query)",
        configuration: configKilo
    ) { benchmark in
        let smallDataset = DatasetHolder.shared.smallDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("zqxwj")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in smallDataset {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    Benchmark(
        "Worst case - many matches (common query)",
        configuration: configKilo
    ) { benchmark in
        let smallDataset = DatasetHolder.shared.smallDataset
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("getData")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in smallDataset {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    // MARK: - Long String Benchmarks (32KB+ candidates)

    Benchmark(
        "Long strings (32KB) - short query (3 char)",
        configuration: configOne
    ) { benchmark in
        let longStrings = DatasetHolder.shared.longStrings32KB
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("usr")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in longStrings {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    Benchmark(
        "Long strings (32KB) - medium query (6 char)",
        configuration: configOne
    ) { benchmark in
        let longStrings = DatasetHolder.shared.longStrings32KB
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("und is")  // "underlying isin" abbreviation
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in longStrings {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    Benchmark(
        "Long strings (32KB) - long query (12 char)",
        configuration: configOne
    ) { benchmark in
        let longStrings = DatasetHolder.shared.longStrings32KB
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("underlying i")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in longStrings {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    Benchmark(
        "Long strings (64KB) - medium query (6 char)",
        configuration: configOne
    ) { benchmark in
        let longStrings = DatasetHolder.shared.longStrings64KB
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("und is")
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in longStrings {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    Benchmark(
        "Long strings (32KB) - no match query",
        configuration: configOne
    ) { benchmark in
        let longStrings = DatasetHolder.shared.longStrings32KB
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("xyzqw")  // Should be rejected by prefilter
        var buffer = matcher.makeBuffer()

        for _ in benchmark.scaledIterations {
            for candidate in longStrings {
                blackHole(matcher.score(candidate, against: query, buffer: &buffer))
            }
        }
    }

    // MARK: - Concurrent Long String Benchmarks

    Benchmark(
        "Long strings (32KB) - concurrent 4 workers",
        configuration: configOneConcurrent
    ) { benchmark in
        let longStrings = DatasetHolder.shared.longStrings32KB
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("und is")
        let workerCount = 4
        let chunkSize = max(1, longStrings.count / workerCount)

        for _ in benchmark.scaledIterations {
            let totalMatches = await runConcurrentScoring(
                dataset: longStrings,
                matcher: matcher,
                query: query,
                workerCount: workerCount,
                chunkSize: chunkSize
            )
            blackHole(totalMatches)
        }
    }

    Benchmark(
        "Long strings (32KB) - concurrent 8 workers",
        configuration: configOneConcurrent
    ) { benchmark in
        let longStrings = DatasetHolder.shared.longStrings32KB
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("und is")
        let workerCount = 8
        let chunkSize = max(1, longStrings.count / workerCount)

        for _ in benchmark.scaledIterations {
            let totalMatches = await runConcurrentScoring(
                dataset: longStrings,
                matcher: matcher,
                query: query,
                workerCount: workerCount,
                chunkSize: chunkSize
            )
            blackHole(totalMatches)
        }
    }

    Benchmark(
        "Long strings (64KB) - concurrent 4 workers",
        configuration: configOneConcurrent
    ) { benchmark in
        let longStrings = DatasetHolder.shared.longStrings64KB
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("und is")
        let workerCount = 4
        let chunkSize = max(1, longStrings.count / workerCount)

        for _ in benchmark.scaledIterations {
            let totalMatches = await runConcurrentScoring(
                dataset: longStrings,
                matcher: matcher,
                query: query,
                workerCount: workerCount,
                chunkSize: chunkSize
            )
            blackHole(totalMatches)
        }
    }

    Benchmark(
        "Long strings (64KB) - concurrent 8 workers",
        configuration: configOneConcurrent
    ) { benchmark in
        let longStrings = DatasetHolder.shared.longStrings64KB
        let matcher = FuzzyMatcher()
        let query = matcher.prepare("und is")
        let workerCount = 8
        let chunkSize = max(1, longStrings.count / workerCount)

        for _ in benchmark.scaledIterations {
            let totalMatches = await runConcurrentScoring(
                dataset: longStrings,
                matcher: matcher,
                query: query,
                workerCount: workerCount,
                chunkSize: chunkSize
            )
            blackHole(totalMatches)
        }
    }
}
