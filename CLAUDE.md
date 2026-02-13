# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FuzzyMatcher is a high-performance fuzzy string matching library for Swift. It provides two matching modes — **Damerau-Levenshtein edit distance** (default, penalty-driven) and **Smith-Waterman local alignment** (bonus-driven) — both with multi-stage prefiltering and zero-allocation hot paths.

**Requirements:** Swift 6.2+, macOS 26+

## Build Commands

```bash
swift build                    # Debug build
swift build -c release         # Release build
swift test                     # Run all tests
swift test --filter TestName   # Run specific test (e.g., --filter EditDistanceTests)
swift package --package-path Benchmarks benchmark  # Run benchmarks (builds release first)
```

## Architecture

### Matching Modes

The library supports two matching algorithms selected via `MatchConfig.algorithm`:

- **Edit Distance** (default) — Penalty-driven scoring using Damerau-Levenshtein. Multi-phase pipeline: exact → prefix → substring → subsequence → acronym. Best for typo tolerance, prefix-aware search, and short queries.
- **Smith-Waterman** — Bonus-driven local alignment (similar to nucleo/fzf). Single DP pass + acronym fallback. Best for multi-word queries, high throughput, and code/file search.

Both modes share the same API surface, zero-allocation hot path, and `score(_:against:buffer:)` entry point. See `MATCHING_MODES.md` for a detailed comparison.

### Core Components

The library follows a pipeline architecture:

1. **Query Preparation** (`FuzzyQuery.swift`) - Precomputes lowercased form, character bitmask, trigrams, and `containsSpaces` flag for the query
2. **Prefiltering** (`Prefilters.swift`) - Three-stage fast rejection: length bounds (O(1)), 37-bit character bitmask (O(1)), trigram similarity (O(n))
3. **Edit Distance** (`EditDistance.swift`) - Damerau-Levenshtein with prefix and substring variants using rolling array optimization
4. **Smith-Waterman** (`SmithWaterman.swift`, `FuzzyMatcher+SmithWaterman.swift`) - Local alignment DP with tiered boundary bonuses, multi-word atom splitting, and integer arithmetic
5. **Scoring** (`ScoringBonuses.swift`, `WordBoundary.swift`) - Position-based bonuses for word boundaries, consecutive matches, and gap penalties (edit distance mode)
6. **Acronym Matching** (`FuzzyMatcher.swift`) - Word-initial character matching for abbreviations (e.g., "bms" → "Bristol-Myers Squibb") — used by both modes
7. **Result** (`ScoredMatch.swift`, `MatchKind.swift`) - Final score (0.0-1.0) with match type (exact/prefix/substring/acronym)

### Key Design Patterns

- **Zero-allocation hot path**: `ScoringBuffer` provides reusable arrays for the score() method
- **Thread safety**: All types are `Sendable`; each thread uses its own buffer
- **UTF-8 processing**: Direct byte operations via `withContiguousStorageIfAvailable` for performance
- **Prepare-once pattern**: Query preparation is separate from scoring for repeated use

### Main Entry Point

`FuzzyMatcher.swift` orchestrates the edit distance scoring pipeline via decomposed phase methods (`checkExactMatch`, `scorePrefix`, `scoreSubstring`, `scoreSubsequence`, `scoreAcronym`) coordinated through a `ScoringState` struct. `FuzzyMatcher+SmithWaterman.swift` handles Smith-Waterman scoring with a single DP pass and optional atom splitting. `FuzzyMatcher+Convenience.swift` provides convenience wrappers. The `score(_:against:buffer:)` method dispatches to the appropriate implementation based on `MatchConfig.algorithm`.

**High-performance API** (zero allocations — use for hot paths):
```swift
// Edit distance (default)
let matcher = FuzzyMatcher()
// Smith-Waterman mode
let swMatcher = FuzzyMatcher(config: .smithWaterman)

let query = matcher.prepare("searchTerm")
var buffer = matcher.makeBuffer()
if let match = matcher.score(candidate, against: query, buffer: &buffer) { ... }
```

**Convenience API** (allocates internally — use for quick use or small sets):
```swift
let matcher = FuzzyMatcher()
if let match = matcher.score("candidate", against: "search") { ... }
let top5 = matcher.topMatches(candidates, against: query, limit: 5)
let all = matcher.matches(candidates, against: query)
```

### Configuration

`MatchConfig.swift` selects the matching algorithm and contains shared + mode-specific parameters:

**Shared:** `minScore` (default: 0.3)

**Edit Distance** (`EditDistanceConfig`):
- `maxEditDistance` (2), `longQueryMaxEditDistance` (3), `longQueryThreshold` (13)
- `prefixWeight` (1.5), `substringWeight` (1.0), `acronymWeight` (1.0)
- `wordBoundaryBonus` (0.1), `consecutiveBonus` (0.05)
- `gapPenalty` (`.affine(open: 0.03, extend: 0.005)`)
- `firstMatchBonus` (0.15), `firstMatchBonusRange` (10), `lengthPenalty` (0.003)

**Smith-Waterman** (`SmithWatermanConfig`):
- `scoreMatch` (16), `penaltyGapStart` (3), `penaltyGapExtend` (1)
- `bonusConsecutive` (4), `bonusBoundary` (8), `bonusBoundaryWhitespace` (10), `bonusBoundaryDelimiter` (9), `bonusCamelCase` (5)
- `bonusFirstCharMultiplier` (2), `splitSpaces` (true)

## Testing

Tests use Swift Testing framework (`@Test` macro, `#expect()` assertions). Test files mirror source structure:
- `EditDistanceTests.swift` - Core edit distance algorithm tests
- `SmithWatermanTests.swift` - Smith-Waterman alignment and scoring tests
- `PrefilterTests.swift` / `TrigramTests.swift` - Fast rejection tests
- `ScoringBonusTests.swift` / `WordBoundaryTests.swift` - Ranking tests (edit distance mode)
- `AcronymMatchTests.swift` - Word-initial abbreviation matching tests
- `EdgeCaseTests.swift` - Boundary conditions

## Performance

**Always benchmark before and after any performance-related change.** Do not speculatively optimize without measuring.

For **iterative performance work**, use the comparison benchmark suite against nucleo (Rust) — this gives realistic per-category timings against a real competitor on the full 271K instrument corpus:

```bash
bash Comparison/run-benchmarks.sh --fm-ed --nucleo  # Quick: FuzzyMatch(ED) vs nucleo only
bash Comparison/run-benchmarks.sh                # Full: all matchers
```

The Swift Package Benchmarks (`swift package --package-path Benchmarks benchmark`) measure micro-benchmarks and concurrency scenarios, but the comparison suite is the primary tool for evaluating real-world performance during development.

Compare results before and after your change. If a "performance optimization" shows no improvement or causes a regression, roll it back.

When updating tables in `COMPARISON.md`, always re-run both scripts and update from their output:

```bash
bash Comparison/run-benchmarks.sh   # Performance comparison (nucleo, RapidFuzz, FuzzyMatch)
python3 Comparison/run-quality.py   # Quality comparison (FuzzyMatcher, nucleo, RapidFuzz, fzf)
```

Update the hardware/OS info block in `COMPARISON.md` each time. Take numbers directly from script output — do not hand-edit the tables.

## Comparison Suite Prerequisites

Running the comparison benchmarks and quality scripts (`Comparison/run-benchmarks.sh`, `Comparison/run-quality.py`) requires:

- **Rust** (for nucleo benchmarks): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- **rapidfuzz-cpp** (for RapidFuzz benchmarks): `brew install rapidfuzz-cpp`
- **fzf** (for quality comparison): `brew install fzf`

## Fuzzing

The `Fuzz/` directory contains a libFuzzer-based fuzz target that validates invariants (score range, self-match, buffer reuse, etc.) over random inputs. **Linux only** — Swift's `-sanitize=fuzzer` requires the open-source toolchain, not Xcode.

```bash
bash Fuzz/run.sh              # build only
bash Fuzz/run.sh run          # build + run (Ctrl-C to stop)
bash Fuzz/run.sh run -max_total_time=300  # run for 5 minutes
```

## Adding Test Queries

See [Agents/ADDING_TEST_QUERIES.md](Agents/ADDING_TEST_QUERIES.md) for the full query format, ground truth rules, and category definitions. Read that file when adding queries to `Resources/queries.tsv`.

## Documentation

- `DAMERAU_LEVENSHTEIN.md` - Detailed Damerau-Levenshtein algorithm documentation with pseudocode and complexity analysis
- `SMITH_WATERMAN.md` - Smith-Waterman local alignment algorithm documentation
- `MATCHING_MODES.md` - High-level comparison of both matching modes

## Prepare Release

See [Agents/PREPARE_RELEASE.md](Agents/PREPARE_RELEASE.md) for the full release preparation workflow (benchmarks, quality runs, documentation review, fuzzygrep benchmarks). Read that file when asked to "prepare release".

## Agent Usage

Always use subagents (the Task tool) when possible and beneficial. Prefer launching parallel subagents for independent work such as:
- Exploring multiple files or directories simultaneously
- Running research queries that don't depend on each other
- Investigating separate parts of the codebase in parallel

This maximizes throughput and keeps the main context window focused.
