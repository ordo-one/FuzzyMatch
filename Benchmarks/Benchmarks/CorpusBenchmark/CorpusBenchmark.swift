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
import Foundation
import FuzzyMatch
import Synchronization

// MARK: - Data Structures

struct Instrument {
    let symbol: String
    let name: String
    let isin: String
}

struct TestQuery {
    let text: String
    let field: String
    let category: String
}

// MARK: - Corpus Holder

final class CorpusHolder: Sendable {
    private struct State {
        var instruments: [Instrument]?
        var queries: [TestQuery]?
        var symbolCandidates: [String]?
        var nameCandidates: [String]?
        var isinCandidates: [String]?
        var queriesByCategory: [String: [TestQuery]]?
    }

    private let state = Mutex(State())

    static let shared = CorpusHolder()

    private static let resourcesDir: String = {
        // #filePath → .../Benchmarks/Benchmarks/CorpusBenchmark/CorpusBenchmark.swift
        // Go up 3 levels to repo root, then into Resources/
        let sourceFile = #filePath
        let repoRoot = URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent() // CorpusBenchmark/
            .deletingLastPathComponent() // Benchmarks/
            .deletingLastPathComponent() // Benchmarks/
            .deletingLastPathComponent() // repo root
        return repoRoot.appendingPathComponent("Resources").path
    }()

    private init() {}

    private func ensureLoaded(_ state: inout State) {
        guard state.instruments == nil else { return }

        // Load instruments
        let instrumentsPath = "\(Self.resourcesDir)/instruments-export.tsv"
        let instrumentsData: String
        do {
            instrumentsData = try String(contentsOfFile: instrumentsPath, encoding: .utf8)
        } catch {
            fatalError("Failed to load instruments: \(error)")
        }
        var instruments: [Instrument] = []
        instruments.reserveCapacity(272_000)

        for (index, line) in instrumentsData.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index == 0 { continue } // skip header
            if line.isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            instruments.append(Instrument(
                symbol: String(fields[0]),
                name: String(fields[1]),
                isin: String(fields[2])
            ))
        }
        state.instruments = instruments
        state.symbolCandidates = instruments.map(\.symbol)
        state.nameCandidates = instruments.map(\.name)
        state.isinCandidates = instruments.map(\.isin)

        // Load queries
        let queriesPath = "\(Self.resourcesDir)/queries.tsv"
        let queriesData: String
        do {
            queriesData = try String(contentsOfFile: queriesPath, encoding: .utf8)
        } catch {
            fatalError("Failed to load queries: \(error)")
        }
        var queries: [TestQuery] = []
        queries.reserveCapacity(200)

        for line in queriesData.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            queries.append(TestQuery(
                text: String(fields[0]),
                field: String(fields[1]),
                category: String(fields[2])
            ))
        }
        state.queries = queries
        state.queriesByCategory = Dictionary(grouping: queries, by: \.category)
    }

    var allQueries: [TestQuery] {
        state.withLock { state in
            ensureLoaded(&state)
            return state.queries!
        }
    }

    func queries(forCategory category: String) -> [TestQuery] {
        state.withLock { state in
            ensureLoaded(&state)
            return state.queriesByCategory![category] ?? []
        }
    }

    func candidates(for field: String) -> [String] {
        state.withLock { state in
            ensureLoaded(&state)
            switch field {
            case "symbol": return state.symbolCandidates!
            case "name": return state.nameCandidates!
            case "isin": return state.isinCandidates!
            default: fatalError("Unknown query field '\(field)' in queries.tsv")
            }
        }
    }

    var categories: [String] {
        state.withLock { state in
            ensureLoaded(&state)
            return state.queriesByCategory!.keys.sorted()
        }
    }
}

// MARK: - Helpers

/// Cycles through queries × candidates, calling `score` for each scaled iteration.
/// All corpus benchmarks share this pattern — they differ only in the scoring closure.
func runCycling(
    _ benchmark: Benchmark,
    pools: [[String]],
    queryCount: Int,
    score: (String, Int) -> ScoredMatch?
) {
    let candidateCount = pools[0].count
    var qi = 0
    var ci = 0
    for _ in benchmark.scaledIterations {
        blackHole(score(pools[qi][ci], qi))
        ci &+= 1
        if ci >= candidateCount {
            ci = 0
            qi &+= 1
            if qi >= queryCount {
                qi = 0
            }
        }
    }
}

// MARK: - Benchmark Suite

let benchmarks: @Sendable () -> Void = {
    let holder = CorpusHolder.shared

    // MARK: - Per-Category Edit Distance Benchmarks

    for category in holder.categories {
        Benchmark(
            "ED - \(category)",
            configuration: .init(
                metrics: [.instructions, .mallocCountTotal, .objectAllocCount, .retainCount, .releaseCount],
                // metrics: [.cpuTotal, .wallClock, .throughput],  // Local profiling (wallclock)
                warmupIterations: 1,
                scalingFactor: .mega
            )
        ) { benchmark in
            let queries = holder.queries(forCategory: category)
            let matcher = FuzzyMatcher()
            var buffer = matcher.makeBuffer()

            let prepared = queries.map { matcher.prepare($0.text) }
            let pools = queries.map { holder.candidates(for: $0.field) }

            runCycling(benchmark, pools: pools, queryCount: prepared.count) { candidate, qi in
                matcher.score(candidate, against: prepared[qi], buffer: &buffer)
            }
        }
    }

    // MARK: - Aggregate Benchmarks

    Benchmark(
        "ED - all queries",
        configuration: .init(
            metrics: [.instructions, .mallocCountTotal, .objectAllocCount, .retainCount, .releaseCount],
            // metrics: [.cpuTotal, .wallClock, .throughput],  // Local profiling (wallclock)
            warmupIterations: 1,
            scalingFactor: .mega
        )
    ) { benchmark in
        let queries = holder.allQueries
        let matcher = FuzzyMatcher()
        var buffer = matcher.makeBuffer()

        let prepared = queries.map { matcher.prepare($0.text) }
        let pools = queries.map { holder.candidates(for: $0.field) }

        runCycling(benchmark, pools: pools, queryCount: prepared.count) { candidate, qi in
            matcher.score(candidate, against: prepared[qi], buffer: &buffer)
        }
    }

    Benchmark(
        "ED - all queries (convenience)",
        configuration: .init(
            metrics: [.instructions, .mallocCountTotal, .objectAllocCount, .retainCount, .releaseCount],
            warmupIterations: 1,
            scalingFactor: .mega
        )
    ) { benchmark in
        let queries = holder.allQueries
        let matcher = FuzzyMatcher()

        let queryTexts = queries.map(\.text)
        let pools = queries.map { holder.candidates(for: $0.field) }

        runCycling(benchmark, pools: pools, queryCount: queryTexts.count) { candidate, qi in
            matcher.score(candidate, against: queryTexts[qi])
        }
    }

    // MARK: - Aggregate Benchmarks (UTF-8 API)

    Benchmark(
        "ED - all queries (UTF-8)",
        configuration: .init(
            metrics: [.instructions, .mallocCountTotal, .objectAllocCount, .retainCount, .releaseCount],
            warmupIterations: 1,
            scalingFactor: .mega
        )
    ) { benchmark in
        let queries = holder.allQueries
        let matcher = FuzzyMatcher()
        var buffer = matcher.makeBuffer()

        let prepared = queries.map { matcher.prepare($0.text) }
        let pools = queries.map { holder.candidates(for: $0.field) }

        let candidateCount = pools[0].count
        var qi = 0
        var ci = 0
        for _ in benchmark.scaledIterations {
            var c = pools[qi][ci]
            c.withUTF8 { utf8 in
                blackHole(matcher.score(utf8: utf8, against: prepared[qi], buffer: &buffer))
            }
            ci &+= 1
            if ci >= candidateCount {
                ci = 0
                qi &+= 1
                if qi >= prepared.count {
                    qi = 0
                }
            }
        }
    }

    Benchmark(
        "SW - all queries (UTF-8)",
        configuration: .init(
            metrics: [.instructions, .mallocCountTotal, .objectAllocCount, .retainCount, .releaseCount],
            warmupIterations: 1,
            scalingFactor: .mega
        )
    ) { benchmark in
        let queries = holder.allQueries
        let matcher = FuzzyMatcher(config: .smithWaterman)
        var buffer = matcher.makeBuffer()

        let prepared = queries.map { matcher.prepare($0.text) }
        let pools = queries.map { holder.candidates(for: $0.field) }

        let candidateCount = pools[0].count
        var qi = 0
        var ci = 0
        for _ in benchmark.scaledIterations {
            var c = pools[qi][ci]
            c.withUTF8 { utf8 in
                blackHole(matcher.score(utf8: utf8, against: prepared[qi], buffer: &buffer))
            }
            ci &+= 1
            if ci >= candidateCount {
                ci = 0
                qi &+= 1
                if qi >= prepared.count {
                    qi = 0
                }
            }
        }
    }

    Benchmark(
        "SW - all queries",
        configuration: .init(
            metrics: [.instructions, .mallocCountTotal, .objectAllocCount, .retainCount, .releaseCount],
            // metrics: [.cpuTotal, .wallClock, .throughput],  // Local profiling (wallclock)
            warmupIterations: 1,
            scalingFactor: .mega
        )
    ) { benchmark in
        let queries = holder.allQueries
        let matcher = FuzzyMatcher(config: .smithWaterman)
        var buffer = matcher.makeBuffer()

        let prepared = queries.map { matcher.prepare($0.text) }
        let pools = queries.map { holder.candidates(for: $0.field) }

        runCycling(benchmark, pools: pools, queryCount: prepared.count) { candidate, qi in
            matcher.score(candidate, against: prepared[qi], buffer: &buffer)
        }
    }
}
