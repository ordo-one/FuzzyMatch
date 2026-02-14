# FuzzyMatch

A high-performance fuzzy string matching library for Swift.

[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fordo-one%2FFuzzyMatch%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/ordo-one/FuzzyMatch)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fordo-one%2FFuzzyMatch%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/ordo-one/FuzzyMatch)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![codecov](https://codecov.io/gh/ordo-one/FuzzyMatch/branch/main/graph/badge.svg)](https://codecov.io/gh/ordo-one/FuzzyMatch)
[![Documentation](https://img.shields.io/badge/Documentation-DocC-blue.svg)](https://swiftpackageindex.com/ordo-one/FuzzyMatch/documentation)

FuzzyMatch was developed for searching financial instrument databases — stock tickers, fund names, ISINs — where typo tolerance, prefix-aware ranking, and sub-millisecond latency matter. The same qualities make it well suited to any domain with a large, heterogeneous candidate set: code identifiers, file names, product catalogs, contact lists, or anything else a user might search with imprecise input.

Full [API documentation](https://swiftpackageindex.com/ordo-one/FuzzyMatch/documentation) is available on the [Swift Package Index](https://swiftpackageindex.com).

## Features

- **Two Matching Modes** - Damerau-Levenshtein edit distance (default, best typo handling) and Smith-Waterman local alignment (~1.7x faster, multi-word AND semantics)
- **Multi-Stage Prefiltering** - Fast rejection of non-matching candidates using length bounds, character bitmasks, and trigrams
- **Zero Dependencies** - Pure Swift implementation with no external dependencies
- **Zero-Allocation Hot Path** - Reusable buffers eliminate allocations during scoring
- **Thread-Safe** - Full `Sendable` compliance for concurrent usage
- **Configurable Scoring** - Adjustable edit distance thresholds, score weights, and match preferences
- **Word Boundary Bonuses** - Intelligent scoring that rewards matches at camelCase and snake_case boundaries
- **Subsequence Matching** - Match abbreviations like "gubi" to "getUserById"
- **Acronym Matching** - Match word-initial abbreviations like "bms" to "Bristol-Myers Squibb"

## Installation

### Swift Package Manager

Add FuzzyMatch to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ordo-one/FuzzyMatch.git", from: "1.0.0")
]
```

Then add it to your target dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: ["FuzzyMatch"]
)
```

## Quick Start

```swift
import FuzzyMatch

let matcher = FuzzyMatcher()

// One-shot scoring — simplest API
if let match = matcher.score("getUserById", against: "getUser") {
    print("score=\(match.score), kind=\(match.kind)")
}

// Top-N matching — returns sorted results
let query = matcher.prepare("config")
let top3 = matcher.topMatches(
    ["appConfig", "configManager", "database", "userConfig"],
    against: query,
    limit: 3
)
for result in top3 {
    print("\(result.candidate): \(result.match.score)")
}
```

## Usage

### Convenience API

For quick exploration, prototyping, or when scoring a small number of candidates:

```swift
let matcher = FuzzyMatcher()

// One-shot: prepare + score in a single call
if let match = matcher.score("getUserById", against: "usr") {
    print("Score: \(match.score)")
}

// Top-N: returns the best matches sorted by score
let query = matcher.prepare("config")
let top5 = matcher.topMatches(candidates, against: query, limit: 5)

// All matches: returns every match sorted by score
let all = matcher.matches(candidates, against: query)
```

> **Note:** Convenience methods allocate a new buffer per call. For high-throughput
> or latency-sensitive use, see **High-Performance API** below.

### High-Performance API (Zero-Allocation Hot Path)

For scoring many candidates against the same query — the recommended path for production use, interactive search, and batch processing:

```swift
let matcher = FuzzyMatcher()

// 1. Prepare the query once (precomputes bitmask, trigrams, etc.)
let query = matcher.prepare("getUser")

// 2. Create a reusable buffer (eliminates allocations in the scoring loop)
var buffer = matcher.makeBuffer()

// 3. Score candidates — zero heap allocations per call
let candidates = ["getUserById", "getUsername", "setUser", "fetchData"]
for candidate in candidates {
    if let match = matcher.score(candidate, against: query, buffer: &buffer) {
        print("\(candidate): score=\(match.score), kind=\(match.kind)")
    }
}
```

**Output:**
```
getUserById: score=0.9988, kind=prefix
getUsername: score=0.9988, kind=prefix
setUser: score=0.9047619047619048, kind=prefix
```

### Custom Configuration

```swift
// Edit distance mode with custom tuning
let config = MatchConfig(
    minScore: 0.5,
    algorithm: .editDistance(EditDistanceConfig(
        maxEditDistance: 3,        // Allow up to 3 edits (default: 2)
        prefixWeight: 2.0,        // Boost prefix matches (default: 1.5)
        substringWeight: 0.8,     // Weight for substring matches (default: 1.0)
        wordBoundaryBonus: 0.12,  // Bonus for word boundary matches (default: 0.1)
        consecutiveBonus: 0.06,   // Bonus for consecutive matches (default: 0.05)
        gapPenalty: .affine(open: 0.04, extend: 0.01)  // Gap penalty model
    ))
)
let matcher = FuzzyMatcher(config: config)

// Smith-Waterman mode with custom tuning
let swConfig = MatchConfig(
    algorithm: .smithWaterman(SmithWatermanConfig(
        penaltyGapStart: 5,
        bonusBoundary: 10,
        bonusCamelCase: 7
    ))
)
let swMatcher = FuzzyMatcher(config: swConfig)
```

### Scoring Bonuses

FuzzyMatcher uses intelligent scoring bonuses to improve ranking quality:

- **Word Boundary Bonus**: Matches at camelCase transitions (`getUserById`), snake_case boundaries (`get_user`), and after digits receive a bonus
- **Consecutive Bonus**: Characters that match consecutively in the candidate receive a bonus
- **Gap Penalty**: Gaps between matched characters incur a penalty. Two models available:
  - `.affine(open:extend:)` (default) - Starting a gap costs more than continuing one
  - `.linear(perCharacter:)` - Each gap character costs the same
- **First Match Bonus**: Matches starting early in the candidate receive a bonus that decays with position

This means queries like "gubi" will rank "getUserById" higher than "debugging" because the query characters match at word boundaries.

```swift
// Disable bonuses for pure edit-distance scoring
let noBonusConfig = MatchConfig(
    algorithm: .editDistance(EditDistanceConfig(
        wordBoundaryBonus: 0.0,
        consecutiveBonus: 0.0,
        gapPenalty: .none,
        firstMatchBonus: 0.0
    ))
)

// Use linear gap penalty instead of affine
let linearConfig = MatchConfig(
    algorithm: .editDistance(EditDistanceConfig(
        gapPenalty: .linear(perCharacter: 0.01)
    ))
)
```

### Concurrent Usage

FuzzyMatcher is fully thread-safe. Each task should use its own buffer:

```swift
let matcher = FuzzyMatcher()
let query = matcher.prepare("getData")
let candidates = loadLargeCandidateList()

// Process concurrently using Swift TaskGroup
let workerCount = 8
let chunkSize = (candidates.count + workerCount - 1) / workerCount

await withTaskGroup(of: [ScoredMatch].self) { group in
    for start in stride(from: 0, to: candidates.count, by: chunkSize) {
        let end = min(start + chunkSize, candidates.count)
        let chunk = candidates[start..<end]
        group.addTask {
            var buffer = matcher.makeBuffer()  // Each task gets its own buffer
            return chunk.compactMap { candidate in
                matcher.score(candidate, against: query, buffer: &buffer)
            }
        }
    }

    // Collect results from all tasks
    for await taskMatches in group {
        // Handle matches...
    }
}
```

### Filtering and Sorting Results

Using the convenience API:

```swift
let matcher = FuzzyMatcher()
let query = matcher.prepare("config")

// Get all matches sorted by score (highest first)
let sorted = matcher.matches(
    ["configuration", "ConfigManager", "user_config", "settings"],
    against: query
)
for result in sorted {
    print("\(result.candidate): \(result.match.score)")
}
```

Or using the high-performance API for zero-allocation control:

```swift
let matcher = FuzzyMatcher()
let query = matcher.prepare("config")
var buffer = matcher.makeBuffer()

let candidates = ["configuration", "ConfigManager", "user_config", "settings"]

let results = candidates.compactMap { candidate -> (String, ScoredMatch)? in
    guard let match = matcher.score(candidate, against: query, buffer: &buffer) else {
        return nil
    }
    return (candidate, match)
}

let sorted = results.sorted { $0.1.score > $1.1.score }
for (candidate, match) in sorted {
    print("\(candidate): \(match.score)")
}
```

## Match Kinds

FuzzyMatcher distinguishes between five types of matches:

| Kind | Description | Example |
|------|-------------|---------|
| `.exact` | Query exactly equals candidate (case-insensitive) | "user" matches "User" |
| `.prefix` | Query matches the beginning of candidate | "get" matches "getUserById" |
| `.substring` | Query matches somewhere within candidate | "user" matches "getCurrentUser" |
| `.acronym` | Query matches word-initial characters | "bms" matches "Bristol-Myers Squibb" |
| `.alignment` | Query matched via Smith-Waterman local alignment | "gubi" matches "getUserById" |

In edit distance mode, prefix matches receive a configurable bonus (`prefixWeight`), and acronym matches use `acronymWeight`. In Smith-Waterman mode, all non-exact, non-acronym matches return as `.alignment`.

## Quality

Tested against [fzf](https://github.com/junegunn/fzf), [nucleo](https://github.com/helix-editor/nucleo), and [RapidFuzz](https://github.com/rapidfuzz/rapidfuzz-cpp) on a 272K financial instruments corpus (197 queries across 9 categories):

| Metric | FuzzyMatch (ED) | FuzzyMatch (SW) | nucleo | fzf |
|--------|-------------|---------|--------|-----|
| Hit rate | **197/197** | 187/197 | 190/197 | 186/197 |
| Top-1 agreement with fzf | **65%** (128/197) | 42% | 44% | — |
| Typo handling | Best | None | Decent | None |
| Abbreviations (e.g., "bms" → Bristol-Myers Squibb) | **7/12** | **7/12** | 2/12 | 2/12 |

FuzzyMatch (ED) agrees with fzf on all exact symbol, ISIN, symbol-with-spaces, and most prefix and substring queries. Its Damerau-Levenshtein foundation handles typos that fzf and nucleo miss entirely ("Voeing", "Gokdman Sachs"), and its acronym matching pass significantly outperforms all other matchers on abbreviation queries.

See [COMPARISON.md](Documentation/COMPARISON.md) for detailed results, per-category breakdowns, and top-3 analysis.

### Smith-Waterman Mode Quality

In Smith-Waterman mode, FuzzyMatch trades typo tolerance for higher throughput and nucleo-compatible rankings:

| Metric | FuzzyMatch (ED) | FuzzyMatch (SW) | nucleo |
|--------|---------|---------|--------|
| Hit rate | **197/197** | 187/197 | 190/197 |
| Top-1 agreement with nucleo | 77/197 | **182/197** | — |
| Throughput | 26M/sec | 44M/sec | 86M/sec |

FuzzyMatch (SW) agrees with nucleo on 92% of top-1 rankings (182/197), making it a drop-in replacement for nucleo-style matching in pure Swift with no FFI overhead. The 10 missing queries are typo-heavy inputs that require edit distance to resolve.

## Performance

### Prefiltering Pipeline

FuzzyMatcher uses a three-stage prefiltering pipeline to quickly reject non-matching candidates before computing expensive edit distance:

1. **Length Bounds** - Rejects candidates that are too short (no upper limit to support subsequence matching)
2. **Character Bitmask** - 64-bit bloom filter checks that the number of distinct missing character types is within an adaptive tolerance (`popcount(queryMask & ~candidateMask) <= bitmaskTolerance`). The tolerance is strict (0) for very short queries (≤3 chars) — blocking substitution typos but still allowing transpositions (same character set) — and equals `effectiveMaxEditDistance` for longer ones, allowing substitution typos while still quickly rejecting candidates that are too different.
3. **Trigrams** - Verifies shared 3-character sequences

### Benchmarks

Run benchmarks with:

```bash
swift package --package-path Benchmarks benchmark
```

Typical performance on Apple Silicon (M4 Max):

| Scenario | Time |
|----------|------|
| Query preparation | ~2.2μs |
| 1M dataset (single-threaded) | ~36ms |
| 1M dataset (8 workers) | ~4.8ms |
| 1M dataset (16 workers) | ~3.8ms |

### Comparison Throughput

On a 272K candidate corpus (M4 Max), FuzzyMatcher processes ~26M candidates/sec in edit distance mode and ~44M candidates/sec in Smith-Waterman mode — both comfortably interactive. nucleo (Rust) is faster at ~86M/sec but uses a different language runtime. Perhaps surprisingly, FuzzyMatch is also significantly faster than a naive `lowercased().contains()` baseline (~3M candidates/sec) — fuzzy matching with prefiltering can outperform brute-force substring search while delivering far better results for real-world user input. See [COMPARISON.md](Documentation/COMPARISON.md) for full performance comparison.

### Zero-Allocation Scoring

The hot path (`score` method) performs zero heap allocations when using prepared queries and reusable buffers. This is critical for responsive UI and high-throughput batch processing.

### fuzzygrep

The `Examples/` directory includes `fuzzygrep`, a parallel grep-like tool built on FuzzyMatch. It reads stdin, distributes lines round-robin across all available cores, and writes ordered results to stdout.

```bash
fuzzygrep color -score 0.99 < /usr/share/dict/words
```

Measured on Apple Silicon (M4 Max, 16 cores), release build, query `1235321 -score 0.5` against lines of the form "line NNNNN", reading from a pre-generated file to eliminate I/O bottlenecks:

**Edit Distance mode:**

| Input size | Wall time | CPU time | CPU utilization |
|------------|-----------|----------|-----------------|
| 10M lines | 0.24s | 2.1s | ~870% |
| 100M lines | 2.4s | 24s | ~990% |
| 1B lines | 25s | 267s | ~1,050% |

**Smith-Waterman mode:**

| Input size | Wall time | CPU time | CPU utilization |
|------------|-----------|----------|-----------------|
| 10M lines | 0.25s | 0.55s | ~220% |
| 100M lines | 2.4s | 6.2s | ~260% |
| 1B lines | 25s | 74s | ~290% |

Wall times are I/O-bound (single-threaded stdin reader); both modes achieve ~40M lines/sec throughput. The CPU time difference shows Smith-Waterman's ~3.6x lower per-line matching cost. Memory footprint stays under 200 MB even at 1B lines (14 GB input).

## Fuzz Testing

FuzzyMatcher includes a [libFuzzer](https://llvm.org/docs/LibFuzzer.html)-based fuzz target that validates scoring invariants over randomized inputs. The fuzzer generates arbitrary (query, candidate, config) combinations and checks that key properties always hold.

> **Linux only** — Swift's `-sanitize=fuzzer` requires the open-source Swift toolchain. It is not available in the Xcode toolchain on macOS.

**Requirements:** Swift 6.2+ open-source toolchain on Linux.

```bash
# Build only (release)
bash Fuzz/run.sh

# Build and run (Ctrl-C to stop)
bash Fuzz/run.sh run

# Run for 60 seconds
bash Fuzz/run.sh run -max_total_time=60

# Debug build for lldb
bash Fuzz/run.sh debug run
```

The fuzz target cycles through ten `MatchConfig` variants — five edit distance (default, exact-only, strict, lenient, picker-style) and five Smith-Waterman (default, lenient, strict, high gap penalty, no space splitting) — and validates five invariants on every input:

1. **No crash** — scoring never panics or traps
2. **Score range** — results are in [0.0, 1.0] and >= `minScore`
3. **Self-match** — every non-empty string scores 1.0 against itself with `.exact` kind
4. **Empty query** — empty queries always match with score 1.0
5. **Buffer reuse** — scoring the same pair twice with the same buffer produces identical results

A 60-second run typically covers 670K+ inputs at ~11,000 exec/s on an x86_64 Linux machine.

See `Fuzz/FuzzyMatchFuzz.swift` for the full fuzz harness and [DAMERAU_LEVENSHTEIN.md](Documentation/DAMERAU_LEVENSHTEIN.md#fuzz-testing) for detailed invariant documentation.

## Unicode Support

FuzzyMatcher operates on raw UTF-8 bytes for performance and supports case-insensitive matching for **ASCII**, **Latin-1 Supplement** (Ä→ä, Ö→ö, Å→å), **Greek** (Α→α, Σ→σ, Ω→ω), and **basic Cyrillic** (А→а, Я→я, Ё→ё).

The primary corpus and use case has been financial instruments (stock tickers, fund names, ISINs), which are predominantly ASCII and Latin-1. Greek and Cyrillic support is provided as a courtesy for users who need these scripts, but they are not a primary target for the package.

Custom byte-level case folding is used instead of Swift's `String.lowercased()` to avoid per-call allocations and iterator overhead in the hot scoring path. An ASCII fast path (checking `String.isASCII` once per candidate) skips all multi-byte dispatch for the vast majority of candidates, keeping throughput at ~26M candidates/sec even with extended script support.

Edit distance and trigrams operate at the byte level. See [DAMERAU_LEVENSHTEIN.md](Documentation/DAMERAU_LEVENSHTEIN.md#unicode-support) for details on what is and isn't supported.

### Limitations

- **No full Unicode normalization (NFC/NFD)** — precomposed characters (e.g., `é` U+00E9) and their decomposed forms (`e` + `◌́` U+0065 U+0301) will still match because basic combining diacritical marks (U+0300–U+036F) are stripped during matching, but full NFC/NFD normalization is not performed
- **CJK, Arabic, Hebrew, Thai, and other complex scripts** — matching operates on raw bytes but case folding is not applied; results may be unpredictable
- **Byte-level operations** — trigrams and edit distance count UTF-8 bytes, not grapheme clusters; multi-byte characters cost more edit distance than ASCII

## Matching Modes

FuzzyMatch offers two matching algorithms:

| | Edit Distance (default) | Smith-Waterman |
|---|---|---|
| Philosophy | Penalty-driven (count errors) | Bonus-driven (reward alignments) |
| Typo handling | Native transposition support | No transposition operation |
| Prefix awareness | Explicit prefix scoring | No prefix concept |
| Multi-word queries | Monolithic | Word-by-word AND semantics |
| Throughput | ~26M candidates/sec | ~44M candidates/sec |

The **default edit distance mode** is designed for interactive search where users type imprecisely. It handles transposition typos ("Berkhsire" for Berkshire), progressive typing, and short symbol lookups better than any other matcher tested. **Smith-Waterman mode** excels at multi-word product search, offers ~1.7x higher throughput, and agrees with nucleo on 92% of top-1 rankings.

```swift
// Default: Edit Distance (recommended for most use cases)
let matcher = FuzzyMatcher()

// Smith-Waterman mode
let matcher = FuzzyMatcher(config: .smithWaterman)
```

For a detailed comparison of strengths, weaknesses, and per-category quality results, see [MATCHING_MODES.md](Documentation/MATCHING_MODES.md). For algorithm internals, see [DAMERAU_LEVENSHTEIN.md](Documentation/DAMERAU_LEVENSHTEIN.md) and [SMITH_WATERMAN.md](Documentation/SMITH_WATERMAN.md).

## API Reference

### Core Types

| Type | Description |
|------|-------------|
| `FuzzyMatcher` | Main entry point for fuzzy matching |
| `FuzzyQuery` | Prepared query optimized for repeated matching |
| `ScoringBuffer` | Reusable buffer for zero-allocation scoring |
| `MatchConfig` | Configuration selecting algorithm and minimum score |
| `MatchingAlgorithm` | Enum: `.editDistance(EditDistanceConfig)` or `.smithWaterman(SmithWatermanConfig)` |
| `EditDistanceConfig` | Configuration for edit distance scoring (weights, bonuses, penalties) |
| `SmithWatermanConfig` | Configuration for Smith-Waterman scoring (integer constants) |
| `GapPenalty` | Enum: `.none`, `.linear(perCharacter:)`, or `.affine(open:extend:)` |
| `ScoredMatch` | Result containing score and match kind |
| `MatchResult` | A matched candidate paired with its `ScoredMatch` |
| `MatchKind` | Enum: `.exact`, `.prefix`, `.substring`, `.acronym`, or `.alignment` |

### FuzzyMatcher Methods

```swift
// Create a matcher
init(config: MatchConfig = .init())

// Prepare a query for repeated use
func prepare(_ query: String) -> FuzzyQuery

// Create a reusable scoring buffer
func makeBuffer() -> ScoringBuffer

// High-performance scoring (zero allocations — use this for hot paths)
func score(_ candidate: String, against query: FuzzyQuery,
           buffer: inout ScoringBuffer) -> ScoredMatch?

// Convenience: one-shot scoring (allocates internally)
func score(_ candidate: String, against query: String) -> ScoredMatch?

// Convenience: top-N matches sorted by score
func topMatches(_ candidates: some Sequence<String>,
                against query: FuzzyQuery, limit: Int = 10) -> [MatchResult]

// Convenience: all matches sorted by score
func matches(_ candidates: some Sequence<String>,
             against query: FuzzyQuery) -> [MatchResult]
```

## Requirements

- Swift 6.2+ (requires span support)
- macOS 26+ / iOS 26+ / visionOS 26+
- Likely works with Linux / Windows / WASM with Swift 6.2+ toolchain (pure Swift, no Foundation dependency)

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request.

## Acknowledgments

- Default high quality matching algorithm based on Damerau-Levenshtein distance
- Smith-Waterman implementation heavily inspired by [nucleo](https://github.com/helix-editor/nucleo) and [fzf](https://github.com/junegunn/fzf)
- Prefiltering techniques inspired by database fuzzy search implementations
- Benchmark infrastructure powered by [swift-benchmark](https://github.com/ordo-one/package-benchmark)
- Entirely built with [Claude Code](https://claude.ai/code) with careful guidance and coaching
