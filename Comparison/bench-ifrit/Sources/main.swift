// Ifrit (Fuse) benchmark harness
// NOTE: Ifrit is very slow compared to other matchers. Use --iterations 1 (default).

import Ifrit
import Foundation

// MARK: - Data Structures

struct Instrument {
    let symbol: String
    let name: String
    let isin: String
}

struct Query {
    let text: String
    let field: String
    let category: String
}

// MARK: - Load Queries from TSV

func loadQueries(from path: String) -> [Query] {
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    let content = String(decoding: data, as: UTF8.self)
    var queries: [Query] = []
    for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
        if cols.count >= 3 {
            queries.append(Query(text: String(cols[0]), field: String(cols[1]), category: String(cols[2])))
        }
    }
    return queries
}

// MARK: - Timing

func now() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

func msFrom(_ start: UInt64, to end: UInt64) -> Double {
    Double(end - start) / 1_000_000.0
}

// MARK: - Main

// Parse arguments
let tsvPath: String
if let idx = CommandLine.arguments.firstIndex(of: "--tsv"), idx + 1 < CommandLine.arguments.count {
    tsvPath = CommandLine.arguments[idx + 1]
} else {
    tsvPath = "../../Resources/instruments-export.tsv"
}
let queriesPath: String
if let idx = CommandLine.arguments.firstIndex(of: "--queries"), idx + 1 < CommandLine.arguments.count {
    queriesPath = CommandLine.arguments[idx + 1]
} else {
    queriesPath = "../../Resources/queries.tsv"
}
// Default to 1 iteration — Ifrit is too slow for multiple iterations
let iterationsArg: Int
if let idx = CommandLine.arguments.firstIndex(of: "--iterations"), idx + 1 < CommandLine.arguments.count,
   let count = Int(CommandLine.arguments[idx + 1]), count > 0 {
    iterationsArg = count
} else {
    iterationsArg = 1
}

// Load queries from TSV
let queries = loadQueries(from: queriesPath)

// Load corpus from TSV
print("Loading corpus from \(tsvPath)...", terminator: "")
fflush(stdout)
let data = try! Data(contentsOf: URL(fileURLWithPath: tsvPath))
let content = String(decoding: data, as: UTF8.self)
print(" done (\(data.count) bytes)")
let lines = content.split(separator: "\n", omittingEmptySubsequences: false)

var instruments: [Instrument] = []
instruments.reserveCapacity(272_000)
for (i, line) in lines.enumerated() {
    if i == 0 { continue } // skip header
    let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
    if cols.count >= 3 {
        instruments.append(Instrument(symbol: String(cols[0]), name: String(cols[1]), isin: String(cols[2])))
    }
}
print("Loaded \(instruments.count) instruments")
print("Running \(queries.count) queries")
print("")

// Pre-extract candidate arrays
let symbolCandidates = instruments.map(\.symbol)
let nameCandidates = instruments.map(\.name)
let isinCandidates = instruments.map(\.isin)

let fuse = Fuse(threshold: 0.6)
let iterations = iterationsArg

// Warmup
do {
    let warmupQuery = queries.first ?? Query(text: "test", field: "name", category: "other")
    let candidates = warmupQuery.field == "symbol" ? symbolCandidates
                   : warmupQuery.field == "isin" ? isinCandidates
                   : nameCandidates
    _ = fuse.searchSync(warmupQuery.text, in: candidates)
    print("Warmup complete")
}

// Per-query timing storage
var queryTimingsMs: [[Double]] = Array(repeating: [], count: queries.count)
var queryMatchCounts: [Int] = Array(repeating: 0, count: queries.count)
var iterationTotalsMs: [Double] = []

print("")
print("=== Benchmark: Ifrit (Fuse) scoring \(queries.count) queries x \(instruments.count) candidates ===")
print("")

for iter in 0..<iterations {
    let iterStart = now()

    for (qi, q) in queries.enumerated() {
        let candidates = q.field == "symbol" ? symbolCandidates
                       : q.field == "isin" ? isinCandidates
                       : nameCandidates
        let qStart = now()

        let results = fuse.searchSync(q.text, in: candidates)

        let qEnd = now()
        let qMs = msFrom(qStart, to: qEnd)
        queryTimingsMs[qi].append(qMs)
        if iter == 0 {
            queryMatchCounts[qi] = results.count
        }
    }

    let iterEnd = now()
    let iterMs = msFrom(iterStart, to: iterEnd)
    iterationTotalsMs.append(iterMs)
    print("Iteration \(iter + 1): \(String(format: "%.1f", iterMs))ms total")
}

// Results
print("")
print("=== Results ===")
print("")

let medianTotal = iterationTotalsMs.sorted()[iterations / 2]
let minTotal = iterationTotalsMs.min()!
let maxTotal = iterationTotalsMs.max()!
print("Total time for \(queries.count) queries (min/median/max): \(String(format: "%.1f", minTotal))ms / \(String(format: "%.1f", medianTotal))ms / \(String(format: "%.1f", maxTotal))ms")

let candidatesPerQuery = Double(instruments.count)
let totalCandidatesScored = candidatesPerQuery * Double(queries.count)
let medianThroughput = totalCandidatesScored / (medianTotal / 1000.0)
print("Throughput (median): \(String(format: "%.0f", medianThroughput / 1_000_000.0))M candidates/sec")
print("Per-query average (median): \(String(format: "%.2f", medianTotal / Double(queries.count)))ms")
print("")

// Per-category summary
let categorySet = Set(queries.map(\.category))
let categories = ["exact_symbol", "exact_name", "exact_isin", "prefix",
                   "typo", "substring", "multi_word", "symbol_spaces", "abbreviation"]
    .filter { categorySet.contains($0) }

func pad(_ str: String, _ width: Int, right: Bool = false) -> String {
    if str.count >= abs(width) { return str }
    let padding = String(repeating: " ", count: abs(width) - str.count)
    return right ? padding + str : str + padding
}

func fmtD(_ val: Double, _ decimals: Int) -> String {
    String(format: "%.\(decimals)f", val)
}

print("\(pad("Category", 22)) \(pad("Queries", 8, right: true)) \(pad("Med(ms)", 8, right: true)) \(pad("Min(ms)", 8, right: true)) \(pad("Matches", 8, right: true))")
print(String(repeating: "-", count: 60))

for cat in categories {
    let indices = queries.indices.filter { queries[$0].category == cat }
    if indices.isEmpty { continue }

    let medians = indices.map { qi -> Double in
        queryTimingsMs[qi].sorted()[iterations / 2]
    }
    let totalMedian = medians.reduce(0, +)
    let totalMin = indices.map { qi in queryTimingsMs[qi].min()! }.reduce(0, +)
    let totalMatches = indices.map { queryMatchCounts[$0] }.reduce(0, +)

    print("\(pad(cat, 22)) \(pad("\(indices.count)", 8, right: true)) \(pad(fmtD(totalMedian, 2), 8, right: true)) \(pad(fmtD(totalMin, 2), 8, right: true)) \(pad("\(totalMatches)", 8, right: true))")
}

print("")
print("=== Per-Query Detail (sorted by median time, descending) ===")
print("")
print("\(pad("Query", 32)) \(pad("Field", 8)) \(pad("Category", 16)) \(pad("Med(ms)", 8, right: true)) \(pad("Min(ms)", 8, right: true)) \(pad("Matches", 8, right: true))")
print(String(repeating: "-", count: 96))

let sortedIndices = queries.indices.sorted { a, b in
    let medA = queryTimingsMs[a].sorted()[iterations / 2]
    let medB = queryTimingsMs[b].sorted()[iterations / 2]
    return medA > medB
}

for qi in sortedIndices {
    let q = queries[qi]
    let med = queryTimingsMs[qi].sorted()[iterations / 2]
    let minMs = queryTimingsMs[qi].min()!
    let displayQuery = q.text.count > 30 ? String(q.text.prefix(27)) + "..." : q.text
    print("\(pad(displayQuery, 32)) \(pad(q.field, 8)) \(pad(q.category, 16)) \(pad(fmtD(med, 2), 8, right: true)) \(pad(fmtD(minMs, 2), 8, right: true)) \(pad("\(queryMatchCounts[qi])", 8, right: true))")
}
