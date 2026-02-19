import FuzzyMatch
import Foundation
import HeapModule

// MARK: - Data Structures

struct Instrument {
    let symbol: String
    let name: String
    let isin: String
}

struct Query {
    let text: String
    let field: String // "symbol", "name", or "isin"
    let category: String
}

struct ScoredResult: Comparable {
    let score: Double
    let index: Int

    static func < (lhs: ScoredResult, rhs: ScoredResult) -> Bool {
        lhs.score < rhs.score
    }
}

// MARK: - App

@main
struct App {
    static let topK = 100

    static let categoryOrder = [
        "exact_symbol", "exact_name", "exact_isin", "prefix",
        "typo", "substring", "multi_word", "symbol_spaces", "abbreviation",
    ]

    static func main() {
        let config = parseArgs()
        let queries = loadQueries(from: config.queriesPath)
        let instruments = loadCorpus(from: config.tsvPath)

        let matchConfig: MatchConfig = config.useSmithWaterman ? .smithWaterman : MatchConfig()
        let matcher = FuzzyMatcher(config: matchConfig)
        let modeName = config.useSmithWaterman ? "Smith-Waterman" : "Edit Distance"

        let symbolCandidates = instruments.map(\.symbol)
        let nameCandidates = instruments.map(\.name)
        let isinCandidates = instruments.map(\.isin)

        func candidates(for field: String) -> [String] {
            switch field {
            case "symbol": symbolCandidates
            case "isin": isinCandidates
            default: nameCandidates
            }
        }

        print("Running \(queries.count) queries")
        print("")

        // Warmup
        do {
            var buffer = matcher.makeBuffer()
            for q in queries {
                let prepared = matcher.prepare(q.text)
                let pool = candidates(for: q.field)
                for candidate in pool {
                    _ = matcher.score(candidate, against: prepared, buffer: &buffer)
                }
            }
            print("Warmup complete")
        }

        // Timed iterations
        var queryTimingsMs: [[Double]] = Array(repeating: [], count: queries.count)
        var queryMatchCounts: [Int] = Array(repeating: 0, count: queries.count)
        var iterationTotalsMs: [Double] = []

        print("")
        print("=== Benchmark: FuzzyMatch (\(modeName)) scoring \(queries.count) queries x \(instruments.count) candidates ===")
        print("")

        for iter in 0..<config.iterations {
            var buffer = matcher.makeBuffer()
            let iterStart = now()

            for (qi, q) in queries.enumerated() {
                let pool = candidates(for: q.field)
                let prepared = matcher.prepare(q.text)
                let qStart = now()
                let (matchCount, _) = scoreQuery(matcher: matcher, prepared: prepared, buffer: &buffer, candidates: pool)
                let qEnd = now()
                queryTimingsMs[qi].append(msFrom(qStart, to: qEnd))
                if iter == 0 {
                    queryMatchCounts[qi] = matchCount
                }
            }

            let iterMs = msFrom(iterStart, to: now())
            iterationTotalsMs.append(iterMs)
            print("Iteration \(iter + 1): \(String(format: "%.1f", iterMs))ms total")
        }

        printResults(
            queries: queries,
            queryTimingsMs: queryTimingsMs,
            queryMatchCounts: queryMatchCounts,
            iterationTotalsMs: iterationTotalsMs,
            iterations: config.iterations,
            candidateCount: instruments.count
        )
    }

    // MARK: - Scoring

    static func scoreQuery(
        matcher: FuzzyMatcher,
        prepared: FuzzyQuery,
        buffer: inout ScoringBuffer,
        candidates: [String]
    ) -> (matchCount: Int, top: [ScoredResult]) {
        var matchCount = 0
        var heap = Heap<ScoredResult>()

        for (ci, candidate) in candidates.enumerated() {
            if let match = matcher.score(candidate, against: prepared, buffer: &buffer) {
                matchCount += 1
                heap.insert(ScoredResult(score: match.score, index: ci))
                if heap.count > topK {
                    _ = heap.popMin()
                }
            }
        }

        var results: [ScoredResult] = []
        results.reserveCapacity(heap.count)
        while let item = heap.popMax() {
            results.append(item)
        }
        return (matchCount, results)
    }

    // MARK: - Argument Parsing

    struct Config {
        let tsvPath: String
        let queriesPath: String
        let iterations: Int
        let useSmithWaterman: Bool
    }

    static func parseArgs() -> Config {
        let args = CommandLine.arguments
        let tsvPath = argValue(for: "--tsv", in: args) ?? "../../Resources/instruments-export.tsv"
        let queriesPath = argValue(for: "--queries", in: args) ?? "../../Resources/queries.tsv"
        let iterations = argValue(for: "--iterations", in: args).flatMap(Int.init) ?? 5
        let useSmithWaterman = args.contains("--sw")
        return Config(tsvPath: tsvPath, queriesPath: queriesPath, iterations: max(1, iterations), useSmithWaterman: useSmithWaterman)
    }

    static func argValue(for flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    // MARK: - Data Loading

    static func loadQueries(from path: String) -> [Query] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        let content = String(decoding: data, as: UTF8.self)
        return content.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { return nil }
            return Query(text: String(cols[0]), field: String(cols[1]), category: String(cols[2]))
        }
    }

    static func loadCorpus(from path: String) -> [Instrument] {
        print("Loading corpus from \(path)...", terminator: "")
        fflush(stdout)
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        let content = String(decoding: data, as: UTF8.self)
        print(" done (\(data.count) bytes)")
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

        var instruments: [Instrument] = []
        instruments.reserveCapacity(272_000)
        for (i, line) in lines.enumerated() {
            if i == 0 { continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            if cols.count >= 3 {
                instruments.append(Instrument(symbol: String(cols[0]), name: String(cols[1]), isin: String(cols[2])))
            }
        }
        print("Loaded \(instruments.count) instruments")
        return instruments
    }

    // MARK: - Timing

    static func now() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    static func msFrom(_ start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000.0
    }

    // MARK: - Output

    static func printResults(
        queries: [Query],
        queryTimingsMs: [[Double]],
        queryMatchCounts: [Int],
        iterationTotalsMs: [Double],
        iterations: Int,
        candidateCount: Int
    ) {
        print("")
        print("=== Results ===")
        print("")

        let medianTotal = iterationTotalsMs.sorted()[iterations / 2]
        let minTotal = iterationTotalsMs.min()!
        let maxTotal = iterationTotalsMs.max()!
        print("Total time for \(queries.count) queries (min/median/max): \(String(format: "%.1f", minTotal))ms / \(String(format: "%.1f", medianTotal))ms / \(String(format: "%.1f", maxTotal))ms")

        let totalScored = Double(candidateCount) * Double(queries.count)
        let throughput = totalScored / (medianTotal / 1000.0)
        print("Throughput (median): \(String(format: "%.0f", throughput / 1_000_000.0))M candidates/sec")
        print("Per-query average (median): \(String(format: "%.2f", medianTotal / Double(queries.count)))ms")
        print("")

        printCategorySummary(queries: queries, queryTimingsMs: queryTimingsMs, queryMatchCounts: queryMatchCounts, iterations: iterations)
        print("")
        printPerQueryDetail(queries: queries, queryTimingsMs: queryTimingsMs, queryMatchCounts: queryMatchCounts, iterations: iterations)
    }

    static func printCategorySummary(
        queries: [Query],
        queryTimingsMs: [[Double]],
        queryMatchCounts: [Int],
        iterations: Int
    ) {
        let present = Set(queries.map(\.category))
        let categories = categoryOrder.filter { present.contains($0) }

        print("\(pad("Category", 22)) \(pad("Queries", 8, right: true)) \(pad("Med(ms)", 8, right: true)) \(pad("Min(ms)", 8, right: true)) \(pad("Matches", 8, right: true))")
        print(String(repeating: "-", count: 60))

        for cat in categories {
            let indices = queries.indices.filter { queries[$0].category == cat }
            guard !indices.isEmpty else { continue }

            let medians = indices.map { qi in queryTimingsMs[qi].sorted()[iterations / 2] }
            let totalMedian = medians.reduce(0, +)
            let totalMin = indices.map { qi in queryTimingsMs[qi].min()! }.reduce(0, +)
            let totalMatches = indices.map { queryMatchCounts[$0] }.reduce(0, +)

            print("\(pad(cat, 22)) \(pad("\(indices.count)", 8, right: true)) \(pad(fmtD(totalMedian, 2), 8, right: true)) \(pad(fmtD(totalMin, 2), 8, right: true)) \(pad("\(totalMatches)", 8, right: true))")
        }
    }

    static func printPerQueryDetail(
        queries: [Query],
        queryTimingsMs: [[Double]],
        queryMatchCounts: [Int],
        iterations: Int
    ) {
        print("=== Per-Query Detail (sorted by median time, descending) ===")
        print("")
        print("\(pad("Query", 32)) \(pad("Field", 8)) \(pad("Category", 16)) \(pad("Med(ms)", 8, right: true)) \(pad("Min(ms)", 8, right: true)) \(pad("Matches", 8, right: true))")
        print(String(repeating: "-", count: 96))

        let sorted = queries.indices.sorted { a, b in
            queryTimingsMs[a].sorted()[iterations / 2] > queryTimingsMs[b].sorted()[iterations / 2]
        }

        for qi in sorted {
            let q = queries[qi]
            let med = queryTimingsMs[qi].sorted()[iterations / 2]
            let minMs = queryTimingsMs[qi].min()!
            let display = q.text.count > 30 ? String(q.text.prefix(27)) + "..." : q.text
            print("\(pad(display, 32)) \(pad(q.field, 8)) \(pad(q.category, 16)) \(pad(fmtD(med, 2), 8, right: true)) \(pad(fmtD(minMs, 2), 8, right: true)) \(pad("\(queryMatchCounts[qi])", 8, right: true))")
        }
    }

    // MARK: - Formatting Helpers

    static func pad(_ str: String, _ width: Int, right: Bool = false) -> String {
        if str.count >= width { return str }
        let padding = String(repeating: " ", count: width - str.count)
        return right ? padding + str : str + padding
    }

    static func fmtD(_ val: Double, _ decimals: Int) -> String {
        String(format: "%.\(decimals)f", val)
    }
}
